import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../chat/chat_models.dart';
import '../agent_kernel.dart';
import '../kernel_event.dart';
import '../kernel_types.dart';
import 'codex_transport.dart';

/// Adapts `codex app-server` to [AgentKernel]. Codex keeps no background
/// commands and cannot put files back, so it does not declare
/// [RunsBackgroundTasks] or [RevertsChanges]: those parts of the UI are not
/// shown for it.
class CodexKernel
    with KernelEventSource
    implements
        AgentKernel,
        SelectsModel,
        SelectsMode,
        ProvidesCommands,
        ReportsContext,
        RewindsConversation,
        AcceptsImages {
  CodexKernel(this.descriptor, this._transport, {KernelContext? context}) {
    _context = context;
    _subscription = _transport.messages.listen(_receive);
  }

  @override
  final KernelDescriptor descriptor;
  final CodexTransport _transport;
  late final StreamSubscription<Map<String, Object?>> _subscription;

  /// Where it works: the project directory it is to run in.
  KernelContext? _context;

  @override
  late final KernelChoiceSource model = LocalChoice(
    _fallbackModels,
    onChanged: (_) => emitInfoChanged(),
  );

  @override
  late final KernelChoiceSource mode = LocalChoice(
    _modes,
    onChanged: (_) => emitInfoChanged(),
  );

  @override
  KernelHealth get health => _health;

  KernelHealth _health = KernelHealth.ready;

  /// What went wrong, for the user; the last lines it printed, with it.
  void _failed(String message, [String? detail]) {
    _health = KernelHealth(
      KernelHealthStatus.failed,
      message: message,
      detail: detail ??
          (() {
            final lines = _transport.stderr;
            return lines.isEmpty ? null : lines.join('\n');
          })(),
    );
    emitInfoChanged();
  }

  @override
  String? get sessionId => null;

  @override
  Future<void> get stopped => _transport.exited;

  @override
  void prepare() {}

  @override
  void release() {}

  @override
  void restart() {
    // What it was doing is over: the server is gone, and a new one
    // starts with the next message.
    _transport.restart();
    _initialized = false;
    _threadId = null;
    _serverTurn = null;
    _serverTurns.clear();
    _health = KernelHealth.ready;
    emitInfoChanged();
  }

  /// What the model picker offers until the server says what it has.
  static const _fallbackModels = [
    KernelOption(
      'gpt-5.5-codex',
      'GPT-5.5 Codex',
      Icons.bolt_rounded,
      'Tuned for coding',
    ),
    KernelOption('gpt-5.5', 'GPT-5.5', Icons.bolt_rounded, 'General purpose'),
    KernelOption('gpt-5.5-mini', 'GPT-5.5 mini', Icons.bolt_rounded, 'Fastest'),
  ];

  /// Modes are its approval and sandbox policies.
  static const _modes = [
    KernelOption(
      'agent',
      'Agent',
      Icons.all_inclusive_rounded,
      'Edit the workspace, ask before commands',
    ),
    KernelOption(
      'ask',
      'Ask',
      Icons.chat_bubble_outline_rounded,
      'Read-only: answer questions',
    ),
  ];

  @override
  final List<KernelCommand> commands = const [
    KernelCommand(
      'review',
      'Review uncommitted changes',
      Icons.rate_review_outlined,
    ),
    KernelCommand(
      'compact',
      'Summarize the conversation',
      Icons.compress_rounded,
    ),
    KernelCommand(
      'init',
      'Write an AGENTS.md for this project',
      Icons.description_outlined,
    ),
    KernelCommand('diff', 'Show the git diff', Icons.difference_outlined),
    KernelCommand('new', 'Start a new chat', Icons.add_comment_outlined),
  ];

  @override
  int get contextWindow => 272000;

  bool _initialized = false;
  String? _threadId;

  /// Ours, and the server's for the same turn once it says.
  String? _turn;
  String? _serverTurn;

  /// The server's turns, ours, in the order they came: the one before a
  /// message of ours, for the rewind (`thread/revert` wants the turn to
  /// go on from).
  final List<String> _serverTurns = [];

  /// Our turns, in the order they were sent: the nth is the nth turn
  /// of the conversation, for the rewind.
  final List<String> _ourTurns = [];

  /// When [_turn] began, to time it.
  DateTime? _turnStarted;
  final Set<String> _sentTurns = {};

  final Map<String, int> _textLength = {};
  final Map<String, StringBuffer> _reasoning = {};
  final Map<String, Stopwatch> _reasoningClock = {};

  /// The part of each summary streaming in.
  final Map<String, int> _reasoningPart = {};
  final Map<String, DateTime> _startedAt = {};

  /// Commands started and not completed yet, as they started.
  final Map<String, Map<String, Object?>> _commands = {};

  /// Pending approvals: our request id → the server's JSON-RPC id.
  final Map<String, Object?> _approvals = {};

  // --- Commands -------------------------------------------------------------

  Future<Map<String, Object?>> _request(
    String method,
    Map<String, Object?> params,
  ) => _transport.request(method, params);

  @override
  void send(KernelTurn turn) {
    if (!_sentTurns.add(turn.id)) return;
    _turn = turn.id;
    _ourTurns.add(turn.id);
    _turnStarted = DateTime.now();
    emit(TurnStarted(nextSeq, turn.id));
    emit(
      ItemUpserted(
        nextSeq,
        turn.id,
        UserMessageItem(text: turn.text, images: turn.images),
      ),
    );
    unawaited(_start(turn));
  }

  Future<void> _start(KernelTurn turn) async {
    if (!_initialized) {
      _initialized = true;
      // The transport has said hello already (the server waits for the
      // client to speak first); what is left is the notification the
      // server expects, and the models it has.
      _transport.write({'method': 'initialized'});
      // The models it has: the picker shows what it can run on, not
      // what was guessed.
      unawaited(_loadModels());
    }
    _threadId ??= await _startThread();
    final readOnly = mode.selected == 'ask';
    final started = await _request('turn/start', {
      'threadId': _threadId,
      'input': [
        {'type': 'text', 'text': turn.text},
        for (final note in turn.notes) {'type': 'text', 'text': note},
        // The pictures the user attached: the model must see them.
        for (final image in turn.images) {
          {
            'type': 'image',
            'url': 'data:${image.mediaType};base64,${base64Encode(image.bytes)}',
          },
        },
      ],
      'model': model.selected,
      'approvalPolicy': readOnly ? 'never' : 'on-request',
      'sandboxPolicy': {'type': readOnly ? 'readOnly' : 'workspaceWrite'},
    });
    // The turn the server gave us: the same one its `turn/started`
    // notification names, but known before it.
    final serverTurn = (started['turn'] as Map)['id'] as String;
    if (_serverTurn == null) {
      _serverTurn = serverTurn;
      _serverTurns.add(serverTurn);
    }
    // Stopped before the server knew the turn: stop it there too.
    if (_turn != turn.id) _interrupt();
  }

  /// The thread this conversation is on: the one it goes on from, when
  /// it is a conversation the user had before, or a new one.
  Future<String> _startThread() async {
    final resumed = _context?.resume;
    if (resumed != null && resumed.id.isNotEmpty) {
      try {
        final answer = await _request('thread/resume', {'threadId': resumed.id});
        final thread = answer['thread'];
        if (thread is Map && thread['id'] is String) {
          return thread['id'] as String;
        }
      } on CodexRequestError {
        // It is gone: a new one is started instead.
      }
    }
    final started = await _request('thread/start', {
      'model': model.selected,
      // The project it works in: without it, the agent would work in
      // the app's own directory.
      'cwd': ?_context?.cwd,
    });
    return (started['thread'] as Map)['id'] as String;
  }

  void _interrupt() {
    final serverTurn = _serverTurn;
    if (serverTurn == null || _threadId == null) return;
    unawaited(
      _request('turn/interrupt', {'threadId': _threadId, 'turnId': serverTurn}),
    );
  }

  /// The models the server has: what the picker offers. A server that
  /// does not say (no catalog, or an error) keeps what it had.
  Future<void> _loadModels() async {
    Map<String, Object?>? answer;
    try {
      answer = await _request('model/list', {});
    } on Object {
      return;
    }
    final listed = answer['models'];
    if (listed is! List) return;
    final options = <KernelOption>[];
    for (final raw in listed) {
      if (raw is! Map) continue;
      final id = raw['id'];
      if (id is! String || id.isEmpty) continue;
      final label = raw['displayName'];
      final efforts = raw['supportedReasoningEfforts'];
      options.add(
        KernelOption(
          id,
          label is String && label.isNotEmpty ? label : id,
          Icons.bolt_rounded,
          efforts is List && efforts.isNotEmpty
              ? 'Effort: ${efforts.join(', ')}'
              : 'Coding model',
        ),
      );
    }
    if (options.isEmpty) return;
    final choice = model;
    if (choice is LocalChoice) {
      final was = choice.selected;
      choice.options = options;
      // The one in effect stays, when the server still has it.
      choice.reported =
          options.any((option) => option.id == was) ? was : options.first.id;
    }
    emitInfoChanged();
  }

  @override
  void answer(String requestId, InteractionAnswer answer) {
    if (!_approvals.containsKey(requestId)) return;
    final rpcId = _approvals.remove(requestId);
    emit(InteractionResolved(nextSeq, requestId));
    final decision = switch (answer) {
      ApprovalAnswer(decision: ApprovalDecision.allowOnce) => 'accept',
      ApprovalAnswer(decision: ApprovalDecision.allowAlways) =>
        'acceptForSession',
      _ => 'decline',
    };
    _transport.write({
      'id': rpcId,
      'result': {'decision': decision},
    });
  }

  @override
  void cancel() {
    final turn = _turn;
    if (turn == null) return;
    _interrupt();
    _endTurn(turn, interrupted: true);
  }

  /// The server's turn to go on from, for the message of ours at
  /// [index]: the turn before it. Null when it is not known, or when
  /// there is no turn before it.
  String? _turnBefore(int index) {
    if (index < 0 || index >= _ourTurns.length) return null;
    // The turn before it: the server's own, one for each of ours. The
    // turn of the message itself is the one to go on from; the one
    // before it is where the conversation is cut.
    return index == 0 ? null : _serverTurns[index - 1];
  }

  @override
  Future<bool> rewind({
    required String itemId,
    required int index,
    required int turns,
    String? lastSeen,
  }) async {
    final threadId = _threadId;
    if (threadId == null) return false;
    // The turn to go on from: the one before the message of ours that is
    // rewound to. The server's `thread/revert` wants the turn to start
    // from, not a number of turns to drop.
    final before = _turnBefore(index);
    if (before == null) return false;
    try {
      await _request('thread/revert', {
        'threadId': threadId,
        'beforeTurnId': before,
      });
    } on CodexRequestError catch (error) {
      // It did not: said, not swallowed.
      _failed('The conversation could not be rewound', error.message);
      return false;
    }
    emit(Rewound(nextSeq, itemId: itemId, index: index));
    return true;
  }

  @override
  void dispose() {
    unawaited(_subscription.cancel());
    _transport.close();
    closeEvents();
  }

  // --- Translation ------------------------------------------------------------

  void _receive(Map<String, Object?> message) {
    final method = message['method'] as String?;
    final params = (message['params'] as Map?)?.cast<String, Object?>();
    if (method == null) {
      // An answer to a request: the transport has it already.
      return;
    }
    if (message.containsKey('id')) {
      _serverRequest(message['id'], method, params ?? const {});
      return;
    }
    switch (method) {
      case 'turn/started':
        _serverTurn = (params!['turn'] as Map)['id'] as String;
        _serverTurns.add(_serverTurn!);
      case 'turn/completed':
        final turn = params!['turn'] as Map;
        if (turn['id'] != _serverTurn) return;
        _serverTurn = null;
        if (_turn case final ours?) {
          final failed = turn['status'] == 'failed';
          if (failed) {
            final error = turn['error'];
            _failed(
              'The turn failed',
              error is Map ? '${error['message'] ?? error}' : null,
            );
          }
          _endTurn(ours, interrupted: turn['status'] == 'interrupted');
        }
      case 'error':
        final error = params!['error'];
        _failed(
          'Codex reported an error',
          error is Map ? '${error['message'] ?? error}' : '$error',
        );
      case 'item/started':
        _itemStarted((params!['item'] as Map).cast<String, Object?>());
      case 'item/completed':
        _itemCompleted((params!['item'] as Map).cast<String, Object?>());
      case 'item/reasoning/summaryTextDelta':
        final id = params!['itemId'] as String;
        final buffer = _reasoning[id];
        if (buffer == null) return;
        // Each part of the summary (its own bold title and text) apart from
        // the one before.
        final part = params['summaryIndex'] as int?;
        final separate =
            part != null && buffer.isNotEmpty && part != _reasoningPart[id];
        if (part != null) _reasoningPart[id] = part;
        final delta = '${separate ? '\n\n' : ''}${params['delta'] as String}';
        final offset = buffer.length;
        buffer.write(delta);
        emit(TextDelta(nextSeq, id, offset, delta, tokens: buffer.length));
      case 'item/agentMessage/delta':
        final id = params!['itemId'] as String;
        final offset = _textLength[id];
        if (offset == null) return;
        final delta = params['delta'] as String;
        _textLength[id] = offset + delta.length;
        emit(TextDelta(nextSeq, id, offset, delta));
      case 'thread/tokenUsage/updated':
        final usage = params!['tokenUsage'] as Map;
        emit(
          UsageReported(
            nextSeq,
            ContextUsage(
              window: usage['modelContextWindow'] as int? ?? contextWindow,
              // The last request's, which is what the context holds; the
              // total adds up every request, and never drops on compacting.
              used: (usage['last'] as Map)['totalTokens'] as int,
            ),
          ),
        );
    }
  }

  void _serverRequest(
    Object? rpcId,
    String method,
    Map<String, Object?> params,
  ) {
    final (title, preview) = switch (method) {
      'item/commandExecution/requestApproval' => (
        'Run command',
        CommandPreview('${params['command']}') as ApprovalPreview?,
      ),
      'item/fileChange/requestApproval' => ('Apply changes', null),
      'item/permissions/requestApproval' => ('Allow permissions', null),
      _ => (null, null),
    };
    if (title == null) {
      // One it does not know: told, so the server is not left waiting
      // for an answer that will not come.
      _transport.write({
        'id': rpcId,
        'error': {'code': -32601, 'message': 'Not supported by this client'},
      });
      return;
    }
    final id = 'approval:$rpcId';
    _approvals[id] = rpcId;
    emit(
      InteractionRequested(
        nextSeq,
        ApprovalRequest(
          id: id,
          title: title,
          toolName: method.split('/')[1],
          reason: params['reason'] as String?,
          preview: preview,
          alwaysAllowLabel: 'Approve for this session',
        ),
      ),
    );
  }

  void _itemStarted(Map<String, Object?> item) {
    final id = item['id'] as String;
    switch (item['type']) {
      case 'reasoning':
        _reasoning[id] = StringBuffer();
        _reasoningClock[id] = Stopwatch()..start();
        emit(
          ItemUpserted(
            nextSeq,
            id,
            ThinkingItem(text: '', tokens: 0, startedAt: DateTime.now()),
            streaming: true,
          ),
        );
      case 'agentMessage':
        _textLength[id] = 0;
        emit(
          ItemUpserted(
            nextSeq,
            id,
            const AssistantTextItem(''),
            streaming: true,
          ),
        );
      case 'commandExecution':
        _startedAt[id] = DateTime.now();
        _commands[id] = item;
        emit(ItemUpserted(nextSeq, id, _commandItem(item)));
    }
  }

  void _itemCompleted(Map<String, Object?> item) {
    final id = item['id'] as String;
    switch (item['type']) {
      case 'reasoning':
        final buffer = _reasoning.remove(id);
        final clock = _reasoningClock.remove(id)?..stop();
        _reasoningPart.remove(id);
        final text =
            buffer?.toString() ??
            (item['summary'] as List<Object?>? ?? const []).join('\n\n');
        emit(
          ItemCompleted(
            nextSeq,
            id,
            item: ThinkingItem(
              text: text,
              tokens: text.length,
              seconds: math.max(
                1,
                ((clock?.elapsedMilliseconds ?? 0) / 1000).round(),
              ),
            ),
          ),
        );
      case 'agentMessage':
        _textLength.remove(id);
        emit(
          ItemCompleted(
            nextSeq,
            id,
            item: AssistantTextItem(item['text'] as String),
          ),
        );
      case 'commandExecution':
        emit(ItemUpserted(nextSeq, id, _commandItem(item)));
        _startedAt.remove(id);
        _commands.remove(id);
      case 'fileChange':
        final changes = item['changes'] as List<Object?>;
        for (final (index, raw) in changes.indexed) {
          final change = raw as Map;
          _fileChange(
            '$id:$index',
            change['path'] as String,
            change['diff'] as String,
            kind: (change['kind'] as Map?)?['type'] as String?,
          );
        }
    }
  }

  /// A command as the history shows it: reads and searches as tool rows,
  /// anything else as a terminal.
  ChatItem _commandItem(Map<String, Object?> item) {
    final actions = [
      for (final action in item['commandActions'] as List<Object?>? ?? const [])
        (action as Map).cast<String, Object?>(),
    ];
    final output = item['aggregatedOutput'] as String?;
    final done = item['status'] == 'completed' || item['status'] == 'failed';
    if (actions.isNotEmpty && actions.every((a) => a['type'] == 'read')) {
      final path = actions.first['path'] as String;
      return ToolCallItem(
        kind: ToolKind.read,
        target: path.split('/').last,
        path: path,
      );
    }
    if (actions.isNotEmpty && actions.every((a) => a['type'] == 'search')) {
      final matches = [
        for (final line in (output ?? '').split('\n'))
          if (line.isNotEmpty) line.split(':').take(2).join(':'),
      ];
      return ToolCallItem(
        kind: ToolKind.grep,
        target: actions.first['query'] as String,
        detail: done ? '${matches.length} results' : null,
        results: matches,
      );
    }
    return TerminalItem(
      command: item['command'] as String,
      output: output ?? '',
      status: !done
          ? CommandStatus.running
          : item['exitCode'] == 0
          ? CommandStatus.succeeded
          : CommandStatus.failed,
      startedAt: _startedAt[item['id']],
    );
  }

  /// A unified diff as a diff card and a pending change. A file added or
  /// deleted ([kind]) has its whole text for a diff.
  void _fileChange(String id, String path, String diff, {String? kind}) {
    final lines = <DiffLine>[];
    var added = 0;
    var removed = 0;
    var oldLine = 1;
    var newLine = 1;
    final hunk = RegExp(r'^@@ -(\d+)(?:,\d+)? \+(\d+)(?:,\d+)? @@');
    for (final line in diff.split('\n')) {
      if (hunk.firstMatch(line) case final match?) {
        oldLine = int.parse(match.group(1)!);
        newLine = int.parse(match.group(2)!);
        continue;
      }
      if (line.isEmpty) continue;
      final text = line.substring(1);
      switch (line[0]) {
        case '+':
          lines.add(DiffLine(DiffLineType.added, newLine++, text));
          added++;
        case '-':
          lines.add(DiffLine(DiffLineType.removed, oldLine++, text));
          removed++;
        default:
          lines.add(DiffLine(DiffLineType.context, newLine++, text));
          oldLine++;
      }
    }
    emit(
      ItemUpserted(
        nextSeq,
        id,
        CodeDiffItem(
          fileName: fileNameOf(path),
          directory: directoryOf(path),
          lines: lines,
        ),
      ),
    );
    emit(
      FileEdited(
        nextSeq,
        FileChange(path: path, added: added, removed: removed),
        original: switch (kind) {
          'add' => const OriginalText(null),
          'delete' => OriginalText(diff),
          _ => OriginalByPatch(diff),
        },
      ),
    );
  }

  void _endTurn(String turn, {required bool interrupted}) {
    _turn = null;
    for (final id in [..._reasoning.keys]) {
      _itemCompleted({'type': 'reasoning', 'id': id});
    }
    for (final id in [..._textLength.keys]) {
      _textLength.remove(id);
      emit(ItemCompleted(nextSeq, id));
    }
    // A command stopped with its turn: it will not report its end.
    for (final item in [..._commands.values]) {
      _itemCompleted({...item, 'status': 'failed'});
    }
    for (final id in _approvals.keys) {
      emit(InteractionResolved(nextSeq, id));
    }
    _approvals.clear();
    emit(
      TurnEnded(
        nextSeq,
        turn,
        interrupted: interrupted,
        worked: switch (_turnStarted) {
          final started? => DateTime.now().difference(started),
          null => null,
        },
      ),
    );
  }
}
