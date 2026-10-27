import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;

import '../../chat/chat_models.dart';
import '../../workspace/editor_launcher.dart' show openExternal;
import '../../remote/remote_location.dart';
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
        StartsPlans,
        SelectsPermission,
        SelectsEffort,
        SelectsFast,
        ProvidesCommands,
        SuggestsFiles,
        ReportsContext,
        ReportsUsage,
        ReportsUsageLimit,
        QueuesMessages,
        ForksConversation,
        RenamesSession,
        ManagesMcpServers,
        SuggestsPrompts,
        LoadsHistory,
        RewindsConversation,
        AcceptsImages {
  CodexKernel(this.descriptor, this._transport, {KernelContext? context}) {
    _context = context ?? const KernelContext();
    final settings = _context.settings;
    _threadId = _context.resume?.id;
    _resumeAttempted = _context.resume == null;
    _work = _modeId(settings[KernelChoiceKind.mode.name]);
    _permission = _permissionId(settings[KernelChoiceKind.permission.name]);
    _pickedEffort = settings[KernelChoiceKind.effort.name];
    _pickedTier = settings[KernelChoiceKind.fast.name];
    for (final MapEntry(:key, :value) in settings.entries) {
      const effortPrefix = 'effort@';
      const fastPrefix = 'fast@';
      if (key.startsWith(effortPrefix)) {
        _effortsByModel[key.substring(effortPrefix.length)] = value;
      } else if (key.startsWith(fastPrefix)) {
        _tiersByModel[key.substring(fastPrefix.length)] = value;
      }
    }
    if (_pickedEffort == null) {
      if (settings[KernelChoiceKind.model.name] case final initialModel?) {
        _pickedEffort = _effortsByModel[initialModel];
        _pickedTier ??= _tiersByModel[initialModel];
      }
    }
    _subscription = _transport.messages.listen(
      _receive,
      onError: _streamError,
      onDone: _streamDone,
    );
    if (_context.resume case final session?) {
      _loadingHistory = true;
      _history = _readInitialHistory(session);
    }
    _live.add(this);
  }

  @override
  final KernelDescriptor descriptor;
  final CodexTransport _transport;
  late final StreamSubscription<Map<String, Object?>> _subscription;

  /// Where it works: the project directory it is to run in.
  late final KernelContext _context;

  @override
  late final LocalChoice model = LocalChoice(
    [
      ..._fallbackModels,
      if (_context.settings[KernelChoiceKind.model.name] case final model?
          when !_fallbackModels.any((option) => option.id == model))
        KernelOption(
          model,
          model,
          Icons.bolt_rounded,
          'Chosen for this conversation',
        ),
    ],
    onChanged: (_) {
      _effortChanged();
      _tierChanged();
      emitInfoChanged();
    },
  )..reported = _context.settings[KernelChoiceKind.model.name];

  @override
  late final LocalChoice mode = LocalChoice(
    _modes,
    onChanged: (id) {
      _work = id;
      emitInfoChanged();
    },
  )..reported = _work;

  @override
  late final LocalChoice permission = LocalChoice(
    _permissions,
    onChanged: (id) {
      _permission = id;
      emitInfoChanged();
    },
  )..reported = _permission;

  @override
  late final ModelSetting effort = _CodexModelSetting(this);

  @override
  late final ModelSetting fast = _CodexServiceTierSetting(this);

  String _work = 'agent';
  String _permission = 'ask';
  String? _pickedEffort;
  final Map<String, String> _effortsByModel = {};
  String? _pickedTier;
  final Map<String, String> _tiersByModel = {};
  final Map<String, _ModelInfo> _models = {};
  bool _modelsLoaded = false;

  @override
  KernelHealth get health => _health;

  KernelHealth _health = KernelHealth.idle;

  /// What went wrong, for the user; the last lines it printed, with it.
  void _failed(String message, [String? detail]) {
    _health = KernelHealth(
      KernelHealthStatus.failed,
      message: message,
      detail:
          detail ??
          (() {
            final lines = _transport.stderr;
            return lines.isEmpty ? null : lines.join('\n');
          })(),
    );
    emitInfoChanged();
  }

  @override
  String? get sessionId => _threadId;

  @override
  Future<void> get stopped => _stopped.future;
  final Completer<void> _stopped = Completer<void>();

  @override
  void prepare() {
    if (_missingFolder case final folder?) {
      _health = KernelHealth(
        KernelHealthStatus.failed,
        message: 'The project folder is gone',
        missingFolder: folder,
      );
      // A view attaches while it is being built. Saying so now would make
      // the workspace notify its listeners during that build.
      unawaited(
        Future<void>.microtask(() {
          emitInfoChanged();
        }).catchError((Object _) {}),
      );
      return;
    }
    // A view attaches while it is being built. Reporting "starting" now
    // would make the workspace notify its listeners during that build.
    unawaited(
      Future<void>.microtask(_initialize).catchError((Object _) {}),
    );
  }

  @override
  void release() {
    // The app-server is shared by every conversation: freeing this one's
    // view must not stop the others. It stays up until the app does.
  }

  @override
  void restart() {
    _transport.restart();
    _ready = false;
    _preparing = null;
    _threadId = null;
    _resumeAttempted = _context.resume == null;
    _serverTurn = null;
    _turn = null;
    _turnStarted = null;
    _turnUsageStart = null;
    _turnUsage = null;
    _serverTurns.clear();
    _ourTurns.clear();
    _textLength.clear();
    _reasoning.clear();
    _reasoningClock.clear();
    _reasoningPart.clear();
    _startedAt.clear();
    _commands.clear();
    _planText.clear();
    _fileItems.clear();
    _rejectInteractions(cancel: true);
    _removeQueued();
    _health = KernelHealth.idle;
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
    KernelOption(
      'plan',
      'Plan',
      Icons.account_tree_outlined,
      'Research and plan before changing anything',
    ),
  ];

  static const _permissions = [
    KernelOption(
      'ask',
      'Ask first',
      Icons.how_to_reg_outlined,
      'Write in the workspace and ask before commands',
    ),
    KernelOption(
      'readOnly',
      'Read only',
      Icons.visibility_outlined,
      'Read the workspace, never change it',
    ),
    KernelOption(
      'auto',
      'Auto',
      Icons.play_circle_outline_rounded,
      'Write in the workspace without asking; no access outside it',
    ),
    KernelOption(
      'fullAccess',
      'Full access',
      Icons.warning_amber_rounded,
      'Change files and run commands without asking',
      caution: true,
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
  int get contextWindow => _contextWindow;
  int _contextWindow = 272000;

  bool _ready = false;
  Future<void>? _preparing;
  String? _threadId;
  bool _resumeAttempted = false;
  bool get _resumePending => _resumeSession != null && !_resumeAttempted;
  SessionRecord? get _resumeSession => _context.resume;

  Future<void> _history = Future.value();
  bool _loadingHistory = false;
  Future<void>? _earlierLoad;
  String? _earlierCursor;
  static const _historyTurns = 10;
  static const _earlierHistoryTurns = 20;

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

  /// The reasoning itself, where the model gives it and not only a summary
  /// of it: a card of its own, so that the two do not mix.
  final Map<String, StringBuffer> _reasoningContent = {};
  final Map<String, Stopwatch> _reasoningClock = {};

  /// The part of each summary streaming in.
  final Map<String, int> _reasoningPart = {};
  final Map<String, DateTime> _startedAt = {};

  /// Commands started and not completed yet, as they started.
  final Map<String, Map<String, Object?>> _commands = {};

  /// Messages sent while busy, waiting for the running turn to end.
  final List<KernelTurn> _queuedTurns = [];
  bool _cancelPending = false;
  Timer? _drainTimer;

  /// Pending interactions by our id: the server's request, and what an
  /// answer has to be shaped as.
  final Map<String, _PendingInteraction> _interactions = {};

  /// Plans streaming in, by item id.
  final Map<String, StringBuffer> _planText = {};

  /// File-change items by id, for the approval that follows.
  final Map<String, Map<String, Object?>> _fileItems = {};

  String? _pendingTitle;
  String? _awaitingPlanId;
  int _planRounds = 0;

  /// The last token count, and the count when this turn began: their
  /// difference is what the turn itself spent.
  Map<String, Object?>? _turnUsageStart;
  Map<String, Object?>? _turnUsage;
  CacheTokens _cacheConversation = const CacheTokens();
  CacheTokens _cacheAtTurnStart = const CacheTokens();
  CacheTokens? _lastCache;

  static List<RateLimitWindow> _accountLimits = const [];
  static LimitsState _limitsState = LimitsState.idle;
  static DateTime? _limitsFetchedAt;
  static Future<void>? _fetchingLimits;
  static final Set<CodexKernel> _live = {};
  DateTime? _usageLimitResetsAt;

  List<McpServer>? _servers;
  String? _suggestion;

  // --- Commands -------------------------------------------------------------

  Future<Map<String, Object?>> _request(
    String method,
    Map<String, Object?> params,
  ) => _transport.request(method, params);

  String get _cwd =>
      _context.cwd ?? _context.resume?.cwd ?? Directory.current.path;
  String get _protocolCwd => RemoteLocation.pathOf(_cwd);

  KernelWorkspace? get _workspace => _context.workspace?.call();

  String? get _missingFolder {
    if (RemoteLocation.isRemote(_cwd)) return null;
    return Directory(_cwd).existsSync() ? null : _cwd;
  }

  Future<void> _initialize() {
    if (_ready) return Future.value();
    return _preparing ??= _doInitialize().whenComplete(() {
      _preparing = null;
    });
  }

  Future<void> _doInitialize() async {
    _health = const KernelHealth(KernelHealthStatus.starting);
    emitInfoChanged();
    try {
      await _loadModels();
      _health = KernelHealth.ready;
      emitInfoChanged();
    } on Object catch (error) {
      if (error is CodexUnavailable) {
        _failed(error.message, error.detail);
      } else {
        _failed('Codex could not be reached', '$error');
      }
      rethrow;
    }
  }

  @override
  void send(KernelTurn turn) {
    if (!_sentTurns.add(turn.id)) return;
    if (_suggestion != null) {
      _suggestion = null;
      emitInfoChanged();
    }
    if (_awaitingPlanId != null) _markPlanSentBack(turn.text);
    // The plan was started: the agent is told to build it, not to plan it
    // again.
    var sent = turn;
    if (_startsPlan) {
      _startsPlan = false;
      sent = KernelTurn(
        id: turn.id,
        text: turn.text,
        mentions: turn.mentions,
        images: turn.images,
        now: turn.now,
        notes: [...turn.notes, _buildNote],
      );
    }
    if (_turn != null || _cancelPending) {
      if (sent.now) {
        _queuedTurns.insert(0, sent);
      } else {
        _queuedTurns.add(sent);
      }
      emit(
        ItemUpserted(
          nextSeq,
          sent.id,
          UserMessageItem(text: sent.text, images: sent.images, queued: true),
        ),
      );
      if (sent.now) {
        cancel();
      } else if (_cancelPending) {
        _waitForCancelledTurn();
      }
      return;
    }
    _begin(sent);
  }

  void _begin(KernelTurn turn) {
    _turn = turn.id;
    _ourTurns.add(turn.id);
    _turnStarted = DateTime.now();
    _turnUsageStart = _turnUsage;
    _turnUsage = null;
    _cacheAtTurnStart = _cacheConversation;
    _lastCache = null;
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
    try {
      if (_missingFolder case final folder?) {
        _health = KernelHealth(
          KernelHealthStatus.failed,
          message: 'The project folder is gone',
          missingFolder: folder,
        );
        emitInfoChanged();
        _failTurn(turn.id, 'The project folder is gone: $folder');
        return;
      }
      await _history;
      await _initialize();
      await _ensureThread();
      final readOnly = _work == 'ask' || _work == 'plan';
      final (method, params) = _turnRequest(turn, readOnly: readOnly);
      final started = await _request(method, params);
      if (!started.containsKey('turn')) {
        if (method == 'thread/compact/start') return;
        throw const CodexRequestError('Codex did not start a turn');
      }
      // The turn the server gave us: the same one its `turn/started`
      // notification names, but known before it.
      final serverTurn = (started['turn'] as Map)['id'] as String;
      _registerServerTurn(serverTurn);
      // Stopped before the server knew the turn: stop it there too.
      if (_turn == turn.id) {
        _serverTurn ??= serverTurn;
      } else {
        _interrupt(serverTurn: serverTurn);
      }
    } on Object catch (error) {
      if (error is CodexUnavailable) {
        _failed(error.message, error.detail);
      } else if (error is! CodexRequestError) {
        _failed('Codex could not start the turn', '$error');
      }
      _failTurn(turn.id, '$error');
    }
  }

  (String, Map<String, Object?>) _turnRequest(
    KernelTurn turn, {
    required bool readOnly,
  }) {
    if (turn.text.trim().toLowerCase() == '/compact') {
      return ('thread/compact/start', {'threadId': _threadId});
    }
    final command = RegExp(
      r'^/review(?:\s+([\s\S]+))?$',
      caseSensitive: false,
    ).firstMatch(turn.text.trim());
    if (command != null) {
      final instructions = command.group(1)?.trim();
      return (
        'review/start',
        {
          'threadId': _threadId,
          'delivery': 'inline',
          'target': instructions == null || instructions.isEmpty
              ? {'type': 'uncommittedChanges'}
              : {'type': 'custom', 'instructions': instructions},
        },
      );
    }
    return (
      'turn/start',
      {
        'threadId': _threadId,
        'clientUserMessageId': turn.id,
        'input': [
          {'type': 'text', 'text': turn.text},
          for (final note in turn.notes) {'type': 'text', 'text': note},
          // The pictures the user attached: the model must see them.
          for (final image in turn.images)
            {
              'type': 'image',
              'url':
                  'data:${image.mediaType};base64,'
                  '${base64Encode(image.bytes)}',
            },
          // The app-server has no mode of its own to plan in (there is no
          // such parameter), so the way of working travels with the
          // message: the agent is told to plan, and the sandbox keeps it
          // from changing anything while it does.
          if (_work == 'plan')
            {
              'type': 'text',
              'text': _planNote,
            },
        ],
        'model': model.selected,
        'effort': ?_effortFor(model.selected ?? ''),
        'serviceTierForTurn': ?_tierFor(model.selected ?? ''),
        'approvalPolicy': readOnly
            ? 'never'
            : switch (_permission) {
                'fullAccess' => 'never',
                'readOnly' => 'never',
                'auto' => 'never',
                _ => 'on-request',
              },
        'sandboxPolicy': readOnly || _permission == 'readOnly'
            ? {'type': 'readOnly', 'networkAccess': false}
            : switch (_permission) {
                'fullAccess' => {'type': 'dangerFullAccess'},
                _ => {
                  'type': 'workspaceWrite',
                  'networkAccess': false,
                  'writableRoots': _writableRoots,
                },
              },
      },
    );
  }

  /// What the agent is told when the user asked it to plan: a plan, and
  /// nothing changed yet.
  static const _planNote =
      'Work out the plan for this, and stop there: do not change any file '
      'yet. Say what you would do, step by step.';

  /// What the agent is told when the user started the plan it made: build
  /// it, rather than plan it again.
  static const _buildNote =
      'The plan above is approved. Carry it out now, step by step.';

  Future<void> _ensureThread() async {
    if (_threadId != null && !_resumePending) return;
    await _startThread();
  }

  /// The thread this conversation is on: the one it goes on from, when
  /// it is a conversation the user had before, or a new one.
  Future<String> _startThread() async {
    final resumed = _context.resume;
    if (resumed != null && resumed.id.isNotEmpty && !_resumeAttempted) {
      _resumeAttempted = true;
      try {
        final answer = await _request('thread/resume', {
          'threadId': resumed.id,
          // The history is read from the server's own turns afterwards:
          // hydrating it here as well would read it twice.
          'excludeTurns': true,
          ..._threadParameters(),
        });
        if (_applyThreadResult(answer)) {
          return _threadId!;
        }
      } on CodexRequestError {
        // It is gone: a new one is started instead.
      }
    }
    _resumeAttempted = true;
    final started = await _request('thread/start', _threadParameters());
    if (!_applyThreadResult(started)) {
      throw const CodexRequestError('Codex did not return a thread');
    }
    final title = _pendingTitle;
    if (title != null) {
      _pendingTitle = null;
      rename(title);
    }
    return _threadId!;
  }

  Map<String, Object?> _threadParameters() => {
    'cwd': _protocolCwd,
    'model': model.selected,
    'serviceTier': ?_tierFor(model.selected ?? ''),
    'developerInstructions': ?_developerInstructions,
  };

  List<String> get _workspaceFolders => [
    _cwd,
    ...?_workspace?.folders,
  ].where((folder) => folder.isNotEmpty).toSet().toList();

  List<String> get _protocolWorkspaceFolders =>
      _workspaceFolders.map(RemoteLocation.pathOf).toList();

  List<String> get _extraProtocolFolders => [
    for (final folder in _protocolWorkspaceFolders)
      if (folder != _protocolCwd) folder,
  ];

  List<String> get _writableRoots => _extraProtocolFolders;

  String? get _developerInstructions {
    final workspace = _workspace;
    final parts = <String>[
      if (workspace?.instructions.trim() case final text? when text.isNotEmpty)
        text,
      if ((workspace?.folders ?? const []).isNotEmpty)
        'This workspace has these folders: '
            '${workspace!.folders.join(', ')}. '
            'Treat all of them as part of the same project.',
    ];
    return parts.isEmpty ? null : parts.join('\n\n');
  }

  bool _applyThreadResult(Map<String, Object?> result) {
    final thread = result['thread'];
    if (thread is! Map || thread['id'] is! String) return false;
    _threadId = thread['id'] as String;
    final reportedModel = result['model'] ?? thread['model'];
    if (reportedModel is String && reportedModel.isNotEmpty) {
      model.reported = reportedModel;
    }
    final provider = result['modelProvider'] ?? thread['modelProvider'];
    if (provider is String && provider.isNotEmpty) {
      _modelProvider = provider;
    }
    final reportedEffort =
        result['reasoningEffort'] ?? thread['reasoningEffort'];
    if (reportedEffort is String && reportedEffort.isNotEmpty) {
      _pickedEffort = reportedEffort;
      _effortsByModel[model.selected ?? ''] = reportedEffort;
    }
    if (result['serviceTier'] case final String tier when tier.isNotEmpty) {
      _pickedTier = tier;
      _tiersByModel[model.selected ?? ''] = tier;
    }
    final collaboration = result['collaborationMode'];
    if (collaboration is Map && collaboration['mode'] is String) {
      _setReportedMode(collaboration['mode'] as String);
    }
    if (thread['name'] case final String name when name.isNotEmpty) {
      emit(SessionRenamed(nextSeq, name));
    }
    emitInfoChanged();
    return true;
  }

  void _registerServerTurn(String id) {
    if (_serverTurns.contains(id)) return;
    _serverTurns.add(id);
  }

  void _interrupt({String? serverTurn}) {
    final turn = serverTurn ?? _serverTurn;
    if (turn == null || _threadId == null) return;
    unawaited(
      _request('turn/interrupt', {'threadId': _threadId, 'turnId': turn}),
    );
  }

  /// The models the server has: what the picker offers. A server that
  /// does not say (no catalog, or an error) keeps what it had.
  Future<void> _loadModels() async {
    if (_modelsLoaded) return;
    final listed = <Object?>[];
    String? cursor;
    for (var page = 0; page < 20; page++) {
      final answer = await _request('model/list', {
        'limit': 200,
        'cursor': ?cursor,
      });
      final data = answer['data'];
      if (data is! List) {
        throw const CodexRequestError('Codex did not list its models');
      }
      listed.addAll(data);
      cursor = answer['nextCursor'] as String?;
      if (cursor == null || cursor.isEmpty) break;
    }
    _models.clear();
    final options = <KernelOption>[];
    for (final raw in listed) {
      if (raw is! Map) continue;
      if (raw['hidden'] == true) continue;
      final id = raw['id'];
      if (id is! String || id.isEmpty) continue;
      final label = raw['displayName'];
      final efforts = raw['supportedReasoningEfforts'];
      final effortOptions = <KernelOption>[
        for (final effort in efforts as List? ?? const [])
          if (effort is Map && effort['reasoningEffort'] is String)
            KernelOption(
              effort['reasoningEffort'] as String,
              _titleCase(effort['reasoningEffort'] as String),
              Icons.speed_rounded,
              effort['description'] as String? ?? '',
            ),
      ];
      final info = _ModelInfo(
        id: id,
        label: label is String && label.isNotEmpty ? label : id,
        description: raw['description'] as String? ?? '',
        efforts: effortOptions,
        defaultEffort: raw['defaultReasoningEffort'] as String?,
        inputModalities: [
          for (final modality in raw['inputModalities'] as List? ?? const [])
            if (modality is String) modality,
        ],
        serviceTiers: [
          for (final tier in raw['serviceTiers'] as List? ?? const [])
            if (tier is Map && tier['id'] is String && tier['id'] != 'default')
              KernelOption(
                tier['id'] as String,
                tier['name'] as String? ?? tier['id'] as String,
                Icons.bolt_rounded,
                tier['description'] as String? ?? '',
              ),
        ],
        defaultServiceTier: raw['defaultServiceTier'] as String?,
        isDefault: raw['isDefault'] == true,
      );
      _models[id] = info;
      final provider = _providerOf(id, info.label);
      options.add(
        KernelOption(
          id,
          info.label,
          Icons.bolt_rounded,
          info.description.isNotEmpty
              ? info.description
              : effortOptions.isNotEmpty
              ? 'Effort: ${effortOptions.map((option) => option.label).join(', ')}'
              : 'Coding model',
          group: provider == null
              ? null
              : KernelOptionGroup(provider, provider),
        ),
      );
    }
    if (options.isEmpty) {
      throw const CodexRequestError('Codex listed no models');
    }
    final was = model.selected;
    final kept = options.where((option) => option.id == was).firstOrNull;
    final preferred =
        kept ??
        options
            .where((option) => _models[option.id]?.isDefault == true)
            .firstOrNull ??
        options.first;
    model.options = options;
    model.reported = preferred.id;
    _modelsLoaded = true;
    emitInfoChanged();
  }

  /// Set by [startBuilding]: the next message carries the plan out, rather
  /// than the agent planning it again.
  bool _startsPlan = false;

  static String _titleCase(String value) =>
      value.isEmpty ? value : '${value[0].toUpperCase()}${value.substring(1)}';

  static String? _providerOf(String id, String label) {
    final slash = id.indexOf('/');
    if (slash > 0) return id.substring(0, slash);
    final dot = label.lastIndexOf(' · ');
    if (dot >= 0) return label.substring(dot + 3);
    return null;
  }

  String? _effortFor(String modelId) {
    final available = _effortsFor(modelId);
    String? supported(String? value) =>
        value != null && available.any((option) => option.id == value)
        ? value
        : null;
    return supported(_effortsByModel[modelId]) ??
        (model.selected == modelId ? supported(_pickedEffort) : null) ??
        supported(_models[modelId]?.defaultEffort) ??
        available.firstOrNull?.id;
  }

  List<KernelOption> _effortsFor(String modelId) =>
      _models[modelId]?.efforts ?? const [];

  void _effortChanged() {
    final selected = model.selected;
    if (selected == null) return;
    final available = _effortsFor(selected);
    if (available.isEmpty) return;
    final current = _effortFor(selected);
    if (current == null || !available.any((option) => option.id == current)) {
      _pickedEffort = available.first.id;
    } else {
      _pickedEffort = current;
    }
  }

  String? _tierFor(String modelId) {
    final available = _tiersFor(modelId);
    String? supported(String? value) =>
        value != null && available.any((option) => option.id == value)
        ? value
        : null;
    return supported(_tiersByModel[modelId]) ??
        (model.selected == modelId ? supported(_pickedTier) : null) ??
        supported(_models[modelId]?.defaultServiceTier);
  }

  List<KernelOption> _tiersFor(String modelId) =>
      _models[modelId]?.serviceTiers ?? const [];

  void _tierChanged() {
    final selected = model.selected;
    if (selected == null) return;
    final available = _tiersFor(selected);
    if (available.isEmpty) return;
    final current = _tierFor(selected);
    _pickedTier = current;
  }

  @override
  bool get loadingHistory => _loadingHistory;

  @override
  bool get hasEarlierHistory =>
      _earlierCursor != null && !_loadingHistory && _earlierLoad == null;

  @override
  bool get loadingEarlier => _earlierLoad != null;

  @override
  Future<void> loadEarlier() {
    final cursor = _earlierCursor;
    if (cursor == null || _loadingHistory) return Future.value();
    return _earlierLoad ??= _loadEarlier(cursor).whenComplete(() {
      _earlierLoad = null;
    });
  }

  Future<void> _loadEarlier(String cursor) async {
    emitInfoChanged();
    try {
      final answer = await _request('thread/turns/list', {
        'threadId': _context.resume?.id ?? _threadId,
        'limit': _earlierHistoryTurns,
        'cursor': cursor,
        'itemsView': 'full',
        'sortDirection': 'desc',
      });
      final items = _historyItems(answer, prepend: true);
      if (items.isNotEmpty) emit(HistoryPrepended(nextSeq, items));
      _earlierCursor = answer['nextCursor'] as String?;
    } on Object catch (error) {
      _notice(
        'Could not read earlier history: $error',
        kind: NoticeKind.warning,
      );
    } finally {
      emitInfoChanged();
    }
  }

  Future<void> _readInitialHistory(SessionRecord session) async {
    try {
      final answer = await _request('thread/turns/list', {
        'threadId': session.id,
        'limit': _historyTurns,
        'itemsView': 'full',
        'sortDirection': 'desc',
      });
      final items = _historyItems(answer);
      if (items.isNotEmpty) emit(HistoryPrepended(nextSeq, items));
      _earlierCursor = answer['nextCursor'] as String?;
    } on CodexUnavailable catch (error) {
      _failed(error.message, error.detail);
    } on Object {
      // A missing session is reported when its first message is sent, and
      // an old server may not page history at all.
    } finally {
      _loadingHistory = false;
      emitInfoChanged();
    }
  }

  List<(String, ChatItem)> _historyItems(
    Map<String, Object?> answer, {
    bool prepend = false,
  }) {
    final turns = [
      for (final raw in answer['data'] as List? ?? const [])
        if (raw is Map) raw.cast<String, Object?>(),
    ].reversed;
    final items = <(String, ChatItem)>[];
    final turnIds = <String>[];
    final userIds = <String>[];
    for (final turn in turns) {
      final turnId = turn['id'] as String? ?? '';
      if (turnId.isNotEmpty) turnIds.add(turnId);
      final startedAt = switch (turn['startedAt']) {
        final int seconds => DateTime.fromMillisecondsSinceEpoch(
          seconds * 1000,
        ),
        _ => null,
      };
      final worked = switch (turn['durationMs']) {
        final int milliseconds when milliseconds > 0 => Duration(
          milliseconds: milliseconds,
        ),
        _ => null,
      };
      for (final raw in turn['items'] as List? ?? const []) {
        if (raw is! Map) continue;
        final item = raw.cast<String, Object?>();
        final id = item['id'] as String? ?? '${items.length}';
        if (item['type'] == 'userMessage') {
          userIds.add(id);
        }
        final chat = _historyItem(item, worked: worked, startedAt: startedAt);
        if (chat != null) items.add((id, chat));
      }
    }
    final newTurns = [
      for (final id in turnIds)
        if (!_serverTurns.contains(id)) id,
    ];
    final newUsers = [
      for (final id in userIds)
        if (!_ourTurns.contains(id)) id,
    ];
    if (prepend) {
      _serverTurns.insertAll(0, newTurns);
      _ourTurns.insertAll(0, newUsers);
    } else {
      _serverTurns.addAll(newTurns);
      _ourTurns.addAll(newUsers);
    }
    return items;
  }

  ChatItem? _historyItem(
    Map<String, Object?> item, {
    required Duration? worked,
    required DateTime? startedAt,
  }) {
    switch (item['type']) {
      case 'userMessage':
        final text = StringBuffer();
        final images = <ImageAttachment>[];
        for (final raw in item['content'] as List? ?? const []) {
          if (raw is! Map) continue;
          if (raw['type'] == 'text' && raw['text'] is String) {
            if (text.isNotEmpty) text.write('\n');
            text.write(raw['text']);
          } else if (raw['type'] == 'image' && raw['url'] is String) {
            final image = _historyImage(raw['url'] as String);
            if (image != null) images.add(image);
          }
        }
        return UserMessageItem(
          text: text.toString(),
          images: images,
          worked: worked,
        );
      case 'agentMessage':
        return _historicalAssistantItem(item['text'] as String? ?? '');
      case 'reasoning':
        final text = [
          ...?item['summary'] as List?,
          ...?item['content'] as List?,
        ].whereType<String>().join('\n\n');
        return ThinkingItem(text: text, tokens: text.length);
      case 'commandExecution':
        if (startedAt != null) {
          _startedAt[item['id'] as String] = startedAt;
        }
        final chat = _commandItem(item);
        _startedAt.remove(item['id']);
        return chat;
      case 'fileChange':
        final changes = [
          for (final raw in item['changes'] as List? ?? const [])
            if (raw is Map) raw,
        ];
        if (changes.isEmpty) return null;
        final first = changes.first;
        return _diffItem(
          first['path'] as String? ?? 'unknown',
          first['diff'] as String? ?? '',
        );
      case 'mcpToolCall':
        return _mcpToolItem(item);
      case 'webSearch':
        return ToolCallItem(
          kind: ToolKind.web,
          target: item['query'] as String? ?? 'Search',
          output: _jsonText(item['results']),
        );
      case 'collabAgentToolCall':
        return _collabAgentItem(item);
      case 'imageGeneration':
        return _imageGenerationItem(item);
      case 'dynamicToolCall':
      case 'functionCallOutput':
        return _otherToolItem(item, completed: true);
      case 'plan':
        return AssistantTextItem(item['text'] as String? ?? '');
      case 'contextCompaction':
        return const NoticeItem(
          NoticeKind.compaction,
          'The conversation was compacted',
        );
      default:
        return null;
    }
  }

  ChatItem _historicalAssistantItem(String text) {
    final match = RegExp(
      r'<proposed_plan>\s*([\s\S]*?)\s*</proposed_plan>',
      caseSensitive: false,
    ).firstMatch(text);
    final plan = match?.group(1)?.trim();
    if (plan == null || plan.isEmpty) return AssistantTextItem(text);
    return PlanItem(
      path: 'codex://plan/history-${nextSeq + 1}',
      round: 1,
      title: PlanItem.titleOf(plan),
      text: plan,
      status: PlanStatus.approved,
      writes: 1,
    );
  }

  static ImageAttachment? _historyImage(String url) {
    if (!url.startsWith('data:')) return null;
    final comma = url.indexOf(',');
    if (comma < 0) return null;
    final header = url.substring(5, comma);
    if (!header.endsWith(';base64')) return null;
    final mediaType = header.substring(0, header.length - 7);
    try {
      return ImageAttachment(
        bytes: base64Decode(url.substring(comma + 1)),
        mediaType: mediaType,
      );
    } on FormatException {
      return null;
    }
  }

  @override
  void answer(String requestId, InteractionAnswer answer) {
    final pending = _interactions.remove(requestId);
    if (pending == null) return;
    emit(InteractionResolved(nextSeq, requestId));
    switch (pending.kind) {
      case _InteractionKind.approval:
        final decision = switch (answer) {
          ApprovalAnswer(decision: ApprovalDecision.allowOnce) => 'accept',
          ApprovalAnswer(decision: ApprovalDecision.allowAlways) =>
            'acceptForSession',
          _ => 'decline',
        };
        _respond(pending.rpcId, {'decision': decision});
      case _InteractionKind.permissions:
        final allowed =
            answer is ApprovalAnswer &&
            answer.decision != ApprovalDecision.deny;
        _respond(pending.rpcId, {
          'permissions': allowed
              ? pending.params['permissions'] ?? const {}
              : const {},
          'scope':
              answer is ApprovalAnswer &&
                  answer.decision == ApprovalDecision.allowAlways
              ? 'session'
              : 'turn',
        });
      case _InteractionKind.question:
        final picks = answer is QuestionAnswer
            ? answer.picks
            : const <List<String>>[];
        _respond(pending.rpcId, {
          'answers': {
            for (final (index, id) in pending.questionIds.indexed)
              id: {
                'answers': index < picks.length
                    ? picks[index]
                    : const <String>[],
              },
          },
        });
      case _InteractionKind.elicitation:
        if (answer is! QuestionAnswer) {
          _respond(pending.rpcId, {'action': 'cancel'});
          return;
        }
        if (answer.skipped) {
          _respond(pending.rpcId, {'action': 'decline'});
          return;
        }
        _respond(pending.rpcId, {
          'action': 'accept',
          'content': _elicitationContent(pending.fields, answer.picks),
        });
      case _InteractionKind.url:
        final allowed =
            answer is ApprovalAnswer &&
            answer.decision != ApprovalDecision.deny;
        if (allowed && pending.params['url'] is String) {
          unawaited(openExternal(pending.params['url'] as String));
        }
        _respond(pending.rpcId, {'action': allowed ? 'accept' : 'decline'});
    }
  }

  @override
  void cancel() {
    final turn = _turn;
    if (turn == null) return;
    _interrupt();
    _rejectInteractions(cancel: true);
    _cancelPending = true;
    _endTurn(turn, interrupted: true, drain: false);
    _waitForCancelledTurn();
  }

  @override
  Future<bool> cancelQueued(String turnId) async {
    final index = _queuedTurns.indexWhere((turn) => turn.id == turnId);
    if (index < 0) return false;
    _queuedTurns.removeAt(index);
    if (_queuedTurns.isEmpty) {
      _drainTimer?.cancel();
      _drainTimer = null;
    }
    emit(ItemRemoved(nextSeq, turnId));
    return true;
  }

  @override
  void sendQueuedNow(String turnId) {
    final index = _queuedTurns.indexWhere((turn) => turn.id == turnId);
    if (index < 0) return;
    final turn = _queuedTurns.removeAt(index);
    _queuedTurns.insert(0, turn);
    if (_turn != null) {
      cancel();
    } else if (!_cancelPending) {
      _begin(_queuedTurns.removeAt(0));
    }
  }

  @override
  void startBuilding() {
    _startsPlan = true;
    _work = 'agent';
    mode.reported = 'agent';
    _approveAwaitingPlan();
    emitInfoChanged();
  }

  void _approveAwaitingPlan() {
    final id = _awaitingPlanId;
    if (id == null) return;
    final text = _planText[id]?.toString();
    if (text != null) {
      emit(
        ItemCompleted(
          nextSeq,
          id,
          item: PlanItem(
            path: 'codex://plan/$id',
            round: _planRounds,
            title: PlanItem.titleOf(text),
            text: text,
            status: PlanStatus.approved,
            writes: 1,
          ),
        ),
      );
    }
    _planText.remove(id);
    _awaitingPlanId = null;
  }

  void _markPlanSentBack(String feedback) {
    final id = _awaitingPlanId;
    if (id == null) return;
    final text = _planText[id]?.toString();
    if (text != null) {
      emit(
        ItemCompleted(
          nextSeq,
          id,
          item: PlanItem(
            path: 'codex://plan/$id',
            round: _planRounds,
            title: PlanItem.titleOf(text),
            text: text,
            status: PlanStatus.sentBack,
            writes: 1,
            feedback: feedback,
          ),
        ),
      );
    }
    _planText.remove(id);
    _awaitingPlanId = null;
  }

  @override
  bool get canFork => _threadId != null;

  @override
  Future<SessionRecord?> fork({String? before, required String title}) async {
    final threadId = _threadId;
    if (threadId == null) return null;
    String? lastTurnId;
    if (before != null) {
      final index = _ourTurns.indexOf(before);
      if (index < 0 || index == 0) {
        _notice('Could not fork before the first message');
        return null;
      }
      lastTurnId = _serverTurns[index - 1];
    }
    try {
      final answer = await _request('thread/fork', {
        'threadId': threadId,
        'lastTurnId': ?lastTurnId,
        'cwd': _protocolCwd,
        'excludeTurns': true,
      });
      final thread = answer['thread'];
      if (thread is! Map || thread['id'] is! String) {
        throw const CodexRequestError('Codex did not return the fork');
      }
      final id = thread['id'] as String;
      try {
        await _request('thread/name/set', {'threadId': id, 'name': title});
      } on Object {
        // A fork without its requested title is still a usable fork.
      }
      return SessionRecord(
        id: id,
        title: title,
        updatedAt: DateTime.now(),
        cwd: _cwd,
        path: thread['path'] as String?,
      );
    } on Object catch (error) {
      _notice('Could not fork the conversation: $error');
      return null;
    }
  }

  @override
  void rename(String title) {
    final threadId = _threadId;
    if (threadId == null) {
      _pendingTitle = title;
      return;
    }
    unawaited(
      _request('thread/name/set', {'threadId': threadId, 'name': title})
          .then((_) {
            emit(SessionRenamed(nextSeq, title));
          })
          .catchError((Object error) {
            _notice('Could not rename the conversation: $error');
          }),
    );
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
    final turnIndex = _ourTurns.indexOf(itemId);
    if (turnIndex == 0) {
      try {
        final started = await _request('thread/start', _threadParameters());
        if (!_applyThreadResult(started)) return false;
        _serverTurns.clear();
        _ourTurns.clear();
        _earlierCursor = null;
        _cacheConversation = const CacheTokens();
        _cacheAtTurnStart = const CacheTokens();
        _lastCache = null;
        emit(Rewound(nextSeq, itemId: itemId, index: index));
        return true;
      } on Object catch (error) {
        _notice('The conversation could not be rewound: $error');
        return false;
      }
    }
    final before = turnIndex >= 0 ? _turnBefore(turnIndex) : _turnBefore(index);
    if (before == null) return false;
    try {
      await _request('thread/revert', {
        'threadId': threadId,
        'beforeTurnId': before,
      });
    } on CodexRequestError catch (error) {
      // It did not: said, not swallowed.
      _notice('The conversation could not be rewound: ${error.message}');
      return false;
    }
    emit(Rewound(nextSeq, itemId: itemId, index: index));
    return true;
  }

  @override
  List<McpServer>? get mcpServers => _servers;

  @override
  String? get promptSuggestion => _suggestion;

  @override
  void refreshMcpServers() {
    unawaited(_loadMcpServers());
  }

  Future<void> _loadMcpServers() async {
    try {
      // The thread, when there is one: without it the server reports the
      // state of no runtime, and every server looks like it is waiting.
      final answer = await _request('mcpServerStatus/list', {
        if (_threadId != null) 'threadId': _threadId,
      });
      _servers = [
        for (final raw in answer['data'] as List? ?? const [])
          if (raw is Map) _mcpServer(raw.cast<String, Object?>()),
      ];
      emitInfoChanged();
    } on Object {
      // Unavailable status is not a failed conversation.
    }
  }

  static McpServer _mcpServer(Map<String, Object?> raw) {
    final info = raw['serverInfo'];
    final runtime = raw['runtimeStatus'];
    final auth = raw['authStatus'];
    final error = raw['toolsError'] as String?;
    final status = switch (runtime) {
      'connected' => McpServerStatus.connected,
      'disabled' => McpServerStatus.disabled,
      'failed' || 'cancelled' => McpServerStatus.failed,
      'authenticationRequired' => McpServerStatus.needsAuth,
      _ when auth == 'notLoggedIn' => McpServerStatus.needsAuth,
      _ => error == null ? McpServerStatus.pending : McpServerStatus.failed,
    };
    return McpServer(
      name: '${raw['name']}',
      status: status,
      error: error,
      version: info is Map ? info['version'] as String? : null,
      tools: [
        for (final name in (raw['tools'] as Map? ?? const {}).keys) '$name',
      ],
    );
  }

  @override
  void setMcpServerEnabled(String name, bool enabled) {
    _setMcpStatus(
      name,
      enabled ? McpServerStatus.pending : McpServerStatus.disabled,
    );
    unawaited(() async {
      try {
        await _request('config/value/write', {
          'keyPath': 'mcp_servers.$name.enabled',
          'mergeStrategy': 'upsert',
          'value': enabled,
        });
        await _request('config/mcpServer/reload', {});
      } on Object catch (error) {
        _notice('Could not change $name: $error');
      }
      await _loadMcpServers();
    }());
  }

  @override
  void reconnectMcpServer(String name) {
    _setMcpStatus(name, McpServerStatus.pending);
    unawaited(() async {
      try {
        await _request('config/mcpServer/reload', {});
      } on Object catch (error) {
        _notice('Could not reconnect $name: $error');
      }
      await _loadMcpServers();
    }());
  }

  @override
  Future<Uri?> authenticateMcpServer(String name) async {
    try {
      final answer = await _request('mcpServer/oauth/login', {
        'name': name,
        'threadId': _threadId,
      });
      final url = Uri.tryParse('${answer['authorizationUrl'] ?? ''}');
      return url != null && url.hasScheme ? url : null;
    } on Object catch (error) {
      _notice('Could not sign in to $name: $error');
      return null;
    }
  }

  void _setMcpStatus(String name, McpServerStatus status) {
    final servers = _servers;
    if (servers == null) return;
    _servers = [
      for (final server in servers)
        server.name == name
            ? McpServer(
                name: server.name,
                status: status,
                error: server.error,
                scope: server.scope,
                version: server.version,
                tools: server.tools,
              )
            : server,
    ];
    emitInfoChanged();
  }

  @override
  Future<List<FileSuggestion>> suggestFiles(String query) async {
    try {
      final answer = await _request('fuzzyFileSearch', {
        'query': query,
        'roots': _protocolWorkspaceFolders,
      });
      final suggestions = <FileSuggestion>[];
      final seen = <String>{};
      for (final raw in answer['files'] as List? ?? const []) {
        if (raw is! Map || raw['path'] is! String) continue;
        var path = raw['path'] as String;
        final paths = RemoteLocation.pathsOf(_cwd);
        if (paths.isAbsolute(path)) {
          path = paths.relative(path, from: _protocolCwd);
        }
        path = path.replaceAll('\\', '/');
        if (raw['match_type'] == 'directory' && !path.endsWith('/')) {
          path = '$path/';
        }
        if (path.isEmpty || !seen.add(path)) continue;
        suggestions.add(FileSuggestion(path));
      }
      return suggestions;
    } on Object {
      return const [];
    }
  }

  @override
  List<RateLimitWindow> get accountLimits => _accountLimits;

  @override
  Future<void> refreshUsage() {
    if (_limitsFetchedAt case final at?
        when DateTime.now().difference(at) < const Duration(seconds: 30)) {
      return Future.value();
    }
    return _fetchingLimits ??= _fetchUsage().whenComplete(() {
      _fetchingLimits = null;
    });
  }

  Future<void> _fetchUsage() async {
    _limitsState = LimitsState.checking;
    _reportStats();
    try {
      final answer = await _request('account/rateLimits/read', {});
      final limits = _parseLimits(answer);
      if (limits.isNotEmpty) {
        final byLabel = {for (final limit in limits) limit.label: limit};
        _accountLimits = [
          for (final old in _accountLimits) byLabel.remove(old.label) ?? old,
          ...byLabel.values,
        ];
      }
      _limitsState = LimitsState.idle;
      _limitsFetchedAt = DateTime.now();
    } on Object {
      _limitsState = LimitsState.unavailable;
    }
    _reportStats();
    _reportAllStats();
  }

  static List<RateLimitWindow> _parseLimits(Map<String, Object?> answer) {
    final snapshots = <Map>[];
    if (answer['rateLimitsByLimitId'] case final Map byId) {
      snapshots.addAll(byId.values.whereType<Map>());
    }
    if (answer['rateLimits'] case final Map single) snapshots.add(single);
    final windows = <RateLimitWindow>[];
    for (final snapshot in snapshots) {
      final name =
          snapshot['limitName'] as String? ??
          snapshot['limitId'] as String? ??
          'Codex';
      for (final (slot, key) in const [(1, 'primary'), (2, 'secondary')]) {
        final raw = snapshot[key];
        if (raw is! Map || raw['usedPercent'] is! int) continue;
        final minutes = raw['windowDurationMins'] as int?;
        final resets = raw['resetsAt'] as int?;
        final suffix = switch (minutes) {
          null => slot == 1 ? 'primary' : 'secondary',
          <= 360 => '${minutes ~/ 60}h',
          <= 10080 => '${minutes ~/ 1440}d',
          _ => '${minutes ~/ 1440}d',
        };
        windows.add(
          RateLimitWindow(
            '$name $suffix'.trim(),
            (raw['usedPercent'] as int) / 100,
            resetsAt: resets == null
                ? null
                : DateTime.fromMillisecondsSinceEpoch(
                    resets * 1000,
                    isUtc: true,
                  ),
          ),
        );
      }
    }
    final unique = <String, RateLimitWindow>{
      for (final window in windows) window.label: window,
    };
    return unique.values.toList();
  }

  void _reportStats() {
    emit(
      StatsReported(
        nextSeq,
        UsageStats(
          limits: _accountLimits,
          limitsState: _limitsState,
          cache: _lastCache == null
              ? null
              : PromptCache(
                  last: _lastCache!,
                  conversation: _cacheAtTurnStart + _lastCache!,
                ),
        ),
      ),
    );
  }

  static CacheTokens _cacheTokens(Map<Object?, Object?> usage) {
    int value(String key) => switch (usage[key]) {
      final int value => value,
      _ => 0,
    };
    final input = value('inputTokens');
    final cached = value('cachedInputTokens');
    final written = value('cacheWriteInputTokens');
    return CacheTokens(
      read: cached,
      written: written,
      uncached: math.max(0, input - cached - written),
    );
  }

  static void _reportAllStats() {
    for (final kernel in _live) {
      kernel._reportStats();
    }
  }

  @override
  DateTime? get usageLimitResetsAt => _usageLimitResetsAt;

  @override
  bool get usageLimitApplies => _modelProvider == 'openai';

  @override
  bool usageLimitAppliesTo(String model) => usageLimitApplies;

  String? _modelProvider;

  @override
  void dispose() {
    _drainTimer?.cancel();
    _rejectInteractions(cancel: true);
    _removeQueued();
    if (_turn case final turn?) {
      _interrupt();
      _endTurn(turn, interrupted: true);
    }
    _live.remove(this);
    unawaited(_subscription.cancel());
    closeEvents();
    if (!_stopped.isCompleted) _stopped.complete();
  }

  // --- Translation ------------------------------------------------------------

  void _receive(Map<String, Object?> message) {
    final method = message['method'] as String?;
    final params = (message['params'] as Map?)?.cast<String, Object?>();
    if (method == null) {
      // An answer to a request: the transport has it already.
      return;
    }
    if (!_forThisThread(params)) return;
    if (message.containsKey('id')) {
      _serverRequest(message['id'], method, params ?? const {});
      return;
    }
    switch (method) {
      case 'turn/started':
        final id = (params!['turn'] as Map)['id'] as String;
        _registerServerTurn(id);
        _serverTurn = id;
      case 'turn/completed':
        final turn = params!['turn'] as Map;
        final id = turn['id'] as String;
        if (_serverTurn != null && id != _serverTurn) return;
        _serverTurn = null;
        if (_turn case final ours?) {
          final failed = turn['status'] == 'failed';
          if (failed) {
            final error = turn['error'];
            _noteError(error);
          }
          _endTurn(ours, interrupted: turn['status'] == 'interrupted');
        } else if (_cancelPending) {
          _cancelPending = false;
          _drainTimer?.cancel();
          _drainTimer = null;
          _startNextQueued();
        }
      case 'error':
        final error = params!['error'];
        if (params['willRetry'] == true) {
          _notice(
            'Codex is retrying: '
            '${error is Map ? error['message'] ?? error : error}',
            kind: NoticeKind.warning,
          );
        } else {
          _noteError(error);
        }
      case 'thread/name/updated':
        final title = params!['threadName'];
        if (title is String && title.isNotEmpty) {
          emit(SessionRenamed(nextSeq, title));
        }
      case 'serverRequest/resolved':
        // The server settled a request of its own (an approval it gave
        // itself): the card is closed, and nothing is answered — it is
        // answered already, and answering again would be noise.
        _resolveServerRequest(params?['requestId']);
      case 'thread/deleted' || 'thread/closed':
        _failed(
          'The conversation is gone',
          'Codex closed or deleted this conversation.',
        );
        if (_turn case final turn?) _failTurn(turn, 'The conversation is gone');
      case 'thread/settings/updated':
        if (params!['threadSettings'] case final Map settings) {
          _applyThreadSettings(settings.cast<String, Object?>());
        }
      case 'turn/plan/updated':
        emit(
          TodosReported(nextSeq, [
            for (final raw in params!['plan'] as List? ?? const [])
              if (raw is Map && raw['step'] is String)
                TodoEntry(raw['step'] as String, switch (raw['status']) {
                  'completed' => TodoStatus.completed,
                  'inProgress' => TodoStatus.inProgress,
                  _ => TodoStatus.pending,
                }),
          ]),
        );
      case 'thread/goal/updated':
        if (params!['goal'] case final Map goal) {
          emit(GoalReported(nextSeq, _goal(goal)));
        }
      case 'thread/goal/cleared':
        emit(GoalReported(nextSeq, null));
      case 'thread/prediction/updated':
        final result = params!['result'];
        _suggestion = switch (result) {
          {'type': 'completed', 'text': final String text}
              when text.trim().isNotEmpty =>
            text,
          _ => null,
        };
        emitInfoChanged();
      case 'item/started':
        _itemStarted((params!['item'] as Map).cast<String, Object?>());
      case 'item/completed':
        _itemCompleted((params!['item'] as Map).cast<String, Object?>());
      case 'item/plan/delta':
        final id = params!['itemId'] as String;
        final buffer = _planText[id] ??= StringBuffer();
        final offset = _textLength[id] ?? buffer.length;
        final delta = params['delta'] as String;
        buffer.write(delta);
        _textLength[id] = offset + delta.length;
        emit(TextDelta(nextSeq, id, offset, delta));
      case 'item/commandExecution/outputDelta':
        final id = params!['itemId'] as String;
        final item = _commands[id];
        if (item == null) return;
        _commands[id] = {
          ...item,
          'aggregatedOutput':
              '${item['aggregatedOutput'] as String? ?? ''}'
              '${params['delta'] as String}',
        };
        emit(ItemUpserted(nextSeq, id, _commandItem(_commands[id]!)));
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
      case 'item/reasoning/textDelta':
        // The reasoning itself, where the model gives it (not only a
        // summary of it): it is the same item, and the card shows it.
        final id = params!['itemId'] as String;
        final buffer = _reasoningContent[id];
        if (buffer == null) return;
        final delta = params['delta'] as String;
        final offset = buffer.length;
        buffer.write(delta);
        emit(TextDelta(nextSeq, id, offset, delta));
      case 'item/agentMessage/delta':
        final id = params!['itemId'] as String;
        final offset = _textLength[id];
        if (offset == null) return;
        final delta = params['delta'] as String;
        _textLength[id] = offset + delta.length;
        emit(TextDelta(nextSeq, id, offset, delta));
      case 'thread/tokenUsage/updated':
        final usage = params!['tokenUsage'] as Map;
        final window = usage['modelContextWindow'] as int?;
        if (window != null) _contextWindow = window;
        _turnUsage = (usage['total'] as Map).cast<String, Object?>();
        if (usage['last'] case final Map last) {
          _lastCache = _cacheTokens(last);
        }
        emit(
          UsageReported(
            nextSeq,
            ContextUsage(
              window: window ?? contextWindow,
              // The last request's, which is what the context holds; the
              // total adds up every request, and never drops on compacting.
              used: (usage['last'] as Map)['totalTokens'] as int,
            ),
          ),
        );
        _reportStats();
      case 'account/rateLimits/updated':
        // The server says what the account may do now: the numbers are
        // read as they are, rather than waited for.
        _applyLimits(_parseLimits(params ?? const {}));
      case 'warning' || 'guardianWarning' || 'deprecationNotice':
        final warning = params?['message'] ?? params?['warning'];
        if (warning != null) {
          _notice(
            '$warning',
            kind: method == 'deprecationNotice'
                ? NoticeKind.warning
                : NoticeKind.error,
          );
        }
      case 'mcpServer/startupStatus/updated' || 'mcpServerStatus/updated':
        _mcpServerUpdated(params);
    }
  }

  /// The server told what the account may do now: the windows are read as
  /// they are, and the ones that are gone go.
  void _applyLimits(List<RateLimitWindow> limits) {
    if (limits.isEmpty) return;
    final byLabel = {for (final limit in limits) limit.label: limit};
    _accountLimits = [
      for (final old in _accountLimits) byLabel.remove(old.label) ?? old,
      ...byLabel.values,
    ];
    _reportAllStats();
  }

  /// One MCP server changed its state: the list is told, and nothing is
  /// asked for again — every conversation sharing the app-server would ask
  /// for the whole list, each of them.
  void _mcpServerUpdated(Map<String, Object?>? params) {
    final name = params?['name'];
    final status = params?['status'];
    final servers = _servers;
    if (name is! String || status is! String || servers == null) {
      refreshMcpServers();
      return;
    }
    final known = switch (status) {
      'connected' => McpServerStatus.connected,
      'starting' => McpServerStatus.pending,
      'failed' || 'cancelled' => McpServerStatus.failed,
      'authenticationRequired' => McpServerStatus.needsAuth,
      'disabled' => McpServerStatus.disabled,
      _ => null,
    };
    if (known == null) {
      refreshMcpServers();
      return;
    }
    _servers = [
      for (final server in servers)
        if (server.name == name)
          McpServer(
            name: server.name,
            status: known,
            error: server.error,
            version: server.version,
            tools: server.tools,
          )
        else
          server,
    ];
    emitInfoChanged();
  }

  bool _forThisThread(Map<String, Object?>? params) {
    final threadId = params?['threadId'];
    if (threadId is! String) return true;
    final ours = _threadId;
    return ours != null && threadId == ours;
  }

  static KernelGoal _goal(Map goal) {
    final status = '${goal['status'] ?? 'active'}';
    return KernelGoal(
      '${goal['objective'] ?? ''}',
      state: switch (status) {
        'complete' => GoalState.met,
        'blocked' => GoalState.failed,
        _ => GoalState.active,
      },
      lastReason: switch (status) {
        'paused' => 'Paused',
        'usageLimited' => 'Paused by the usage limit',
        'budgetLimited' => 'Paused by the token budget',
        _ => null,
      },
      setAt: switch (goal['createdAt']) {
        final int seconds => DateTime.fromMillisecondsSinceEpoch(
          seconds * 1000,
        ),
        _ => null,
      },
      duration: switch (goal['timeUsedSeconds']) {
        final int seconds => Duration(seconds: seconds),
        _ => null,
      },
      tokens: goal['tokensUsed'] as int?,
    );
  }

  void _applyThreadSettings(Map<String, Object?> settings) {
    if (settings['model'] case final String value when value.isNotEmpty) {
      model.reported = value;
    }
    if (settings['modelProvider'] case final String provider) {
      _modelProvider = provider;
    }
    if (settings['effort'] case final String value when value.isNotEmpty) {
      _pickedEffort = value;
      _effortsByModel[model.selected ?? ''] = value;
    }
    if (settings['serviceTier'] case final String value when value.isNotEmpty) {
      _pickedTier = value;
      _tiersByModel[model.selected ?? ''] = value;
    }
    if (settings['collaborationMode'] case final Map collaboration) {
      if (collaboration['mode'] case final String value) {
        _setReportedMode(value);
      }
    }
    final sandbox = settings['sandboxPolicy'];
    if (sandbox is Map) {
      _permission = switch (sandbox['type']) {
        'readOnly' => 'readOnly',
        'dangerFullAccess' => 'fullAccess',
        'workspaceWrite' when settings['approvalPolicy'] == 'never' => 'auto',
        _ => 'ask',
      };
      permission.reported = _permission;
    }
    emitInfoChanged();
  }

  void _setReportedMode(String value) {
    _work = value == 'plan' ? 'plan' : 'agent';
    mode.reported = _work;
  }

  void _noteError(Object? error) {
    final message = error is Map ? '${error['message'] ?? error}' : '$error';
    final info = error is Map ? error['codexErrorInfo'] : null;
    if (info == 'usageLimitExceeded' || info == 'rateLimitExceeded') {
      _usageLimitResetsAt = _accountLimits
          .where((limit) => limit.resetsAt != null)
          .map((limit) => limit.resetsAt!)
          .where((at) => at.isAfter(DateTime.now()))
          .firstOrNull;
    }
    _notice(message, kind: NoticeKind.error);
  }

  void _streamError(Object error) {
    final message = error is CodexUnavailable
        ? error.message
        : 'Codex stopped unexpectedly';
    final detail = error is CodexUnavailable ? error.detail : '$error';
    _failed(message, detail);
    if (_turn case final turn?) _failTurn(turn, message);
  }

  void _streamDone() {
    if (_health.status == KernelHealthStatus.failed) return;
    _failed('Codex stopped', 'Start it again to continue this conversation.');
    if (_turn case final turn?) _failTurn(turn, 'Codex stopped');
  }

  void _serverRequest(
    Object? rpcId,
    String method,
    Map<String, Object?> params,
  ) {
    switch (method) {
      case 'item/commandExecution/requestApproval':
        _requestApproval(
          rpcId,
          kind: _InteractionKind.approval,
          method: method,
          params: params,
          title: params['kind'] == 'writeStdin'
              ? 'Send input to the command'
              : 'Run command',
          preview: CommandPreview(
            params['command'] as String? ?? 'command',
            description: params['reason'] as String?,
          ),
          alwaysAllowLabel: 'Approve for this session',
        );
      case 'item/fileChange/requestApproval':
        final files = _fileItems[params['itemId']];
        final changes = files?['changes'] as List?;
        final paths = [
          for (final change in changes ?? const [])
            if (change is Map && change['path'] is String)
              change['path'] as String,
        ];
        final first = changes?.whereType<Map>().firstOrNull;
        final preview = switch (first) {
          final change? when change['path'] is String => DiffPreview(
            change['path'] as String,
            _diffItem(
              change['path'] as String,
              change['diff'] as String? ?? '',
            ).lines,
          ),
          _ when paths.isNotEmpty => TextPreview(paths.join('\n')),
          _ => null,
        };
        _requestApproval(
          rpcId,
          kind: _InteractionKind.approval,
          method: method,
          params: params,
          title: 'Apply changes',
          preview: preview,
          alwaysAllowLabel: 'Accept for this session',
        );
      case 'item/permissions/requestApproval':
        _requestApproval(
          rpcId,
          kind: _InteractionKind.permissions,
          method: method,
          params: params,
          title: 'Allow extra permissions',
          preview: TextPreview(
            'Folder: ${params['cwd'] ?? _cwd}\n'
            '${params['reason'] ?? 'The agent needs access for this step.'}',
          ),
          alwaysAllowLabel: 'Allow for this session',
        );
      case 'item/tool/requestUserInput':
        final questions = <Question>[];
        final ids = <String>[];
        for (final raw in params['questions'] as List? ?? const []) {
          if (raw is! Map) continue;
          final id = raw['id'] as String? ?? '${ids.length + 1}';
          ids.add(id);
          questions.add(
            Question(
              prompt: raw['question'] as String? ?? '',
              header: raw['header'] as String? ?? '',
              allowOther: raw['isOther'] == true,
              options: [
                for (final option in raw['options'] as List? ?? const [])
                  if (option is Map && option['label'] is String)
                    QuestionOption(
                      option['label'] as String,
                      description: option['description'] as String? ?? '',
                    ),
              ],
            ),
          );
        }
        if (questions.isEmpty) {
          _respond(rpcId, {'answers': const {}});
          return;
        }
        final id = 'question:$rpcId';
        _interactions[id] = _PendingInteraction(
          rpcId: rpcId,
          kind: _InteractionKind.question,
          params: params,
          questionIds: ids,
        );
        emit(
          InteractionRequested(
            nextSeq,
            QuestionRequest(
              id: id,
              title: 'Codex needs an answer',
              questions: questions,
            ),
          ),
        );
      case 'mcpServer/elicitation/request':
        _mcpElicitation(rpcId, params);
      case 'item/tool/call':
        // A tool the server wants this client to run. This app runs none
        // of its own for the server, so it says so — as an answer, which
        // the model reads, rather than as a protocol error, which ends
        // the turn.
        _respond(rpcId, {
          'success': false,
          'contentItems': [
            {
              'type': 'text',
              'text':
                  'This client runs no tools of its own for the server; '
                  '${params['tool'] ?? 'the tool'} was not run.',
            },
          ],
        });
      case 'account/chatgptAuthTokens/refresh':
        // The server asks the client for ChatGPT tokens to refresh. This
        // app holds none: the server keeps its own account in its own
        // folder. It is told so, and the turn goes on.
        _transport.write({
          'id': rpcId,
          'error': {
            'code': -32601,
            'message': 'This client holds no ChatGPT tokens',
          },
        });
      default:
        // One it does not know: told, so the server is not left waiting
        // for an answer that will not come.
        _transport.write({
          'id': rpcId,
          'error': {'code': -32601, 'message': 'Not supported by this client'},
        });
    }
  }

  void _requestApproval(
    Object? rpcId, {
    required _InteractionKind kind,
    required String method,
    required Map<String, Object?> params,
    required String title,
    required ApprovalPreview? preview,
    String? alwaysAllowLabel,
  }) {
    final id = '${kind.name}:$rpcId';
    _interactions[id] = _PendingInteraction(
      rpcId: rpcId,
      kind: kind,
      params: params,
    );
    emit(
      InteractionRequested(
        nextSeq,
        ApprovalRequest(
          id: id,
          title: title,
          toolName: method.split('/')[1],
          reason: params['reason'] as String?,
          preview: preview,
          alwaysAllowLabel: alwaysAllowLabel,
        ),
      ),
    );
  }

  /// The server settled a request of its own: the card is closed, and
  /// nothing is answered — it is answered already, and answering again
  /// would be a second answer to a request nobody waits for.
  void _resolveServerRequest(Object? requestId) {
    if (requestId == null) return;
    for (final entry in _interactions.entries.toList()) {
      if (entry.value.rpcId != requestId) continue;
      _interactions.remove(entry.key);
      emit(InteractionResolved(nextSeq, entry.key));
    }
  }

  void _mcpElicitation(Object? rpcId, Map<String, Object?> params) {
    final server = params['serverName'] as String? ?? 'MCP';
    final message = params['message'] as String? ?? 'MCP needs input';
    if (params['mode'] == 'url') {
      final id = 'url:$rpcId';
      _interactions[id] = _PendingInteraction(
        rpcId: rpcId,
        kind: _InteractionKind.url,
        params: params,
      );
      emit(
        InteractionRequested(
          nextSeq,
          ApprovalRequest(
            id: id,
            title: '$server needs you to sign in',
            toolName: 'MCP',
            reason: message,
            preview: TextPreview('${params['url'] ?? ''}'),
          ),
        ),
      );
      return;
    }

    final schema = params['requestedSchema'];
    final properties = schema is Map ? schema['properties'] : null;
    if (properties is! Map || properties.isEmpty) {
      // The schema is not one this app can put fields on (some servers
      // send only "there is a form"). Asking the user with a free text
      // field is better than answering for them: an empty answer is
      // accepted by the server as if the user had said yes to nothing.
      final id = 'elicitation:$rpcId';
      final field = _ElicitationField(
        id: 'answer',
        type: 'string',
        multiple: false,
        values: const {},
        question: Question(
          prompt: message,
          header: server,
          options: const [],
        ),
      );
      _interactions[id] = _PendingInteraction(
        rpcId: rpcId,
        kind: _InteractionKind.elicitation,
        params: params,
        fields: [field],
      );
      emit(
        InteractionRequested(
          nextSeq,
          QuestionRequest(
            id: id,
            title: '$server: $message',
            questions: [field.question],
          ),
        ),
      );
      return;
    }
    final fields = <_ElicitationField>[];
    final questions = <Question>[];
    for (final MapEntry(:key, :value) in properties.entries) {
      if (value is! Map) continue;
      final field = _ElicitationField.from('$key', value);
      fields.add(field);
      questions.add(field.question);
    }
    final id = 'elicitation:$rpcId';
    _interactions[id] = _PendingInteraction(
      rpcId: rpcId,
      kind: _InteractionKind.elicitation,
      params: params,
      fields: fields,
    );
    emit(
      InteractionRequested(
        nextSeq,
        QuestionRequest(
          id: id,
          title: '$server: $message',
          questions: questions,
        ),
      ),
    );
  }

  static Map<String, Object?> _elicitationContent(
    List<_ElicitationField> fields,
    List<List<String>> picks,
  ) {
    final content = <String, Object?>{};
    for (final (index, field) in fields.indexed) {
      final picked = index < picks.length ? picks[index] : const <String>[];
      content[field.id] = field.valueFor(picked);
    }
    return content;
  }

  void _itemStarted(Map<String, Object?> item) {
    final id = item['id'] as String;
    switch (item['type']) {
      case 'reasoning':
        _reasoning[id] = StringBuffer();
        _reasoningContent[id] = StringBuffer();
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
      case 'plan':
        _planText[id] = StringBuffer();
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
      case 'fileChange':
        _fileItems[id] = item;
      case 'mcpToolCall':
        emit(ItemUpserted(nextSeq, id, _mcpToolItem(item)));
      case 'webSearch':
        emit(
          ItemUpserted(
            nextSeq,
            id,
            ToolCallItem(
              kind: ToolKind.web,
              target: item['query'] as String? ?? 'Search',
              status: ToolStatus.running,
            ),
          ),
        );
      case 'collabAgentToolCall':
        emit(ItemUpserted(nextSeq, id, _collabAgentItem(item)));
      case 'imageGeneration':
        emit(ItemUpserted(nextSeq, id, _imageGenerationItem(item)));
      case 'dynamicToolCall':
      case 'functionCallOutput':
        emit(ItemUpserted(nextSeq, id, _otherToolItem(item)));
    }
  }

  void _itemCompleted(Map<String, Object?> item) {
    final id = item['id'] as String;
    switch (item['type']) {
      case 'reasoning':
        final buffer = _reasoning.remove(id);
        final streamed = _reasoningContent.remove(id);
        final clock = _reasoningClock.remove(id)?..stop();
        _reasoningPart.remove(id);
        // The summary, where the model gave one; the reasoning itself,
        // where it gave that instead.
        final summary = (item['summary'] as List<Object?>? ?? const [])
            .join('\n\n');
        final given = switch (item['content']) {
          final String text => text,
          final List<Object?> parts => parts.join('\n\n'),
          _ => '',
        };
        final live = buffer?.toString() ?? streamed?.toString() ?? '';
        final text = live.isNotEmpty
            ? live
            : summary.isNotEmpty
            ? summary
            : given;
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
            item: _assistantItem(id, item['text'] as String? ?? ''),
          ),
        );
      case 'plan':
        final text =
            _planText.remove(id)?.toString() ?? item['text'] as String? ?? '';
        _textLength.remove(id);
        emit(ItemCompleted(nextSeq, id, item: AssistantTextItem(text)));
      case 'commandExecution':
        emit(ItemUpserted(nextSeq, id, _commandItem(item)));
        emit(FilesMayHaveChanged(nextSeq));
        _startedAt.remove(id);
        _commands.remove(id);
      case 'fileChange':
        _fileItems[id] = item;
        final changes = item['changes'] as List<Object?>? ?? const [];
        for (final (index, raw) in changes.indexed) {
          if (raw is! Map) continue;
          final change = raw;
          _fileChange(
            '$id:$index',
            change['path'] as String? ?? 'unknown',
            change['diff'] as String? ?? '',
            kind: (change['kind'] as Map?)?['type'] as String?,
          );
        }
      case 'mcpToolCall':
        emit(ItemCompleted(nextSeq, id, item: _mcpToolItem(item)));
      case 'webSearch':
        emit(
          ItemCompleted(
            nextSeq,
            id,
            item: ToolCallItem(
              kind: ToolKind.web,
              target: item['query'] as String? ?? 'Search',
              output: _jsonText(item['results']),
            ),
          ),
        );
      case 'collabAgentToolCall':
        emit(ItemCompleted(nextSeq, id, item: _collabAgentItem(item)));
      case 'imageGeneration':
        emit(ItemCompleted(nextSeq, id, item: _imageGenerationItem(item)));
      case 'dynamicToolCall':
      case 'functionCallOutput':
        emit(
          ItemCompleted(
            nextSeq,
            id,
            item: _otherToolItem(item, completed: true),
          ),
        );
      case 'contextCompaction':
        emit(
          ItemCompleted(
            nextSeq,
            id,
            item: const NoticeItem(
              NoticeKind.compaction,
              'The conversation was compacted',
            ),
          ),
        );
    }
  }

  ChatItem _assistantItem(String id, String text) {
    final match = RegExp(
      r'<proposed_plan>\s*([\s\S]*?)\s*</proposed_plan>',
      caseSensitive: false,
    ).firstMatch(text);
    final plan = match?.group(1)?.trim();
    if (plan == null || plan.isEmpty) return AssistantTextItem(text);
    _planText[id] = StringBuffer(plan);
    _awaitingPlanId = id;
    _planRounds++;
    return PlanItem(
      path: 'codex://plan/$id',
      round: _planRounds,
      title: PlanItem.titleOf(plan),
      text: plan,
      status: PlanStatus.awaiting,
      writes: 1,
    );
  }

  ToolCallItem _mcpToolItem(Map<String, Object?> item) {
    final running = item['status'] == 'inProgress';
    final failed = item['status'] == 'failed';
    final result = item['result'];
    return ToolCallItem(
      kind: ToolKind.mcp,
      target: '${item['server'] ?? 'MCP'}.${item['tool'] ?? 'tool'}',
      label: item['tool'] as String?,
      tool: item['tool'] as String?,
      status: running
          ? ToolStatus.running
          : failed
          ? ToolStatus.failed
          : ToolStatus.succeeded,
      output: _jsonText(item['error'] ?? result),
    );
  }

  static AgentItem _collabAgentItem(Map<String, Object?> item) {
    final statuses = item['agentsStates'];
    final messages = [
      if (statuses is Map)
        for (final state in statuses.values)
          if (state is Map && state['message'] is String)
            state['message'] as String,
    ];
    return AgentItem(
      description: switch (item['prompt']) {
        final String prompt when prompt.isNotEmpty => oneLineExcerpt(prompt),
        _ => '${item['tool'] ?? 'Agent'}',
      },
      id: item['id'] as String?,
      prompt: item['prompt'] as String?,
      status: switch (item['status']) {
        'completed' => CommandStatus.succeeded,
        'failed' || 'interrupted' => CommandStatus.failed,
        _ => CommandStatus.running,
      },
      lastTool: item['tool'] as String?,
      model: item['model'] as String?,
      result: messages.isEmpty ? null : messages.join('\n\n'),
    );
  }

  static ToolCallItem _imageGenerationItem(Map<String, Object?> item) {
    final saved = item['savedPath'];
    return ToolCallItem(
      kind: ToolKind.image,
      target: switch (item['revisedPrompt']) {
        final String prompt when prompt.isNotEmpty => oneLineExcerpt(prompt),
        _ => 'Generated image',
      },
      status: switch (item['status']) {
        'completed' => ToolStatus.succeeded,
        'failed' => ToolStatus.failed,
        _ => ToolStatus.running,
      },
      output: saved is String ? saved : null,
      imageFiles: [if (saved is String) saved],
    );
  }

  static ToolCallItem _otherToolItem(
    Map<String, Object?> item, {
    bool completed = false,
  }) {
    final status = '${item['status'] ?? ''}';
    return ToolCallItem(
      kind: ToolKind.other,
      target: '${item['name'] ?? item['tool'] ?? item['type'] ?? 'Tool'}',
      label: item['name'] as String? ?? item['tool'] as String?,
      status: switch (status) {
        'completed' || 'succeeded' => ToolStatus.succeeded,
        'failed' => ToolStatus.failed,
        'interrupted' || 'cancelled' => ToolStatus.denied,
        _ => completed ? ToolStatus.succeeded : ToolStatus.running,
      },
      output: _jsonText(item['output'] ?? item['result']),
    );
  }

  static String? _jsonText(Object? value) {
    if (value == null) return null;
    if (value is String) return value;
    try {
      return const JsonEncoder.withIndent('  ').convert(value);
    } on Object {
      return '$value';
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
    // A command the user declined is over: it never runs, and the card
    // must not go on showing it as running.
    final declined = item['status'] == 'declined';
    final done =
        declined ||
        item['status'] == 'completed' ||
        item['status'] == 'failed';
    if (actions.isNotEmpty && actions.every((a) => a['type'] == 'read')) {
      final path = actions.first['path'] as String? ?? '';
      return ToolCallItem(
        kind: ToolKind.read,
        target: p.basename(path),
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
        target: actions.first['query'] as String? ?? '',
        detail: done ? '${matches.length} results' : null,
        results: matches,
      );
    }
    return TerminalItem(
      command: item['command'] as String,
      // A command the user declined never ran: it says so, rather than
      // showing an empty result as if it had.
      output: declined && (output == null || output.isEmpty)
          ? 'Declined'
          : output ?? '',
      description: item['description'] as String?,
      status: declined
          ? CommandStatus.failed
          : !done
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
    final item = _diffItem(path, diff);
    emit(ItemUpserted(nextSeq, id, item));
    final added = item.added;
    final removed = item.removed;
    emit(
      FileEdited(
        nextSeq,
        FileChange(path: path, added: added, removed: removed),
        turnId: _turn,
        original: switch (kind) {
          'add' => const OriginalText(null),
          'delete' => OriginalText(diff),
          _ => OriginalByPatch(diff),
        },
      ),
    );
  }

  static CodeDiffItem _diffItem(String path, String diff) {
    final lines = <DiffLine>[];
    var oldLine = 1;
    var newLine = 1;
    final hunk = RegExp(r'^@@ -(\d+)(?:,\d+)? \+(\d+)(?:,\d+)? @@');
    for (final raw in diff.split('\n')) {
      final line = raw.endsWith('\r') ? raw.substring(0, raw.length - 1) : raw;
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
        case '-':
          lines.add(DiffLine(DiffLineType.removed, oldLine++, text));
        default:
          lines.add(DiffLine(DiffLineType.context, newLine++, text));
          oldLine++;
      }
    }
    return CodeDiffItem(
      fileName: fileNameOf(path),
      directory: directoryOf(path),
      lines: lines,
    );
  }

  void _endTurn(String turn, {required bool interrupted, bool drain = true}) {
    _turn = null;
    for (final id in [..._reasoning.keys]) {
      _itemCompleted({'type': 'reasoning', 'id': id});
    }
    // A plan still streaming when the turn ended: it is closed with what
    // it said, not with nothing.
    for (final id in [..._planText.keys]) {
      final text = _planText.remove(id)?.toString() ?? '';
      _textLength.remove(id);
      emit(ItemCompleted(nextSeq, id, item: AssistantTextItem(text)));
    }
    for (final id in [..._textLength.keys]) {
      _textLength.remove(id);
      emit(ItemCompleted(nextSeq, id));
    }
    // A command stopped with its turn: it will not report its end.
    for (final item in [..._commands.values]) {
      _itemCompleted({...item, 'status': 'failed'});
    }
    _fileItems.clear();
    _rejectInteractions(cancel: interrupted);
    final worked = switch (_turnStarted) {
      final started? => DateTime.now().difference(started),
      null => null,
    };
    final usage = _usageForTurn(worked);
    final cache = _lastCache;
    if (!interrupted && cache != null) {
      _cacheConversation = _cacheAtTurnStart + cache;
    }
    if (!interrupted) _usageLimitResetsAt = null;
    _reportStats();
    emit(
      TurnEnded(
        nextSeq,
        turn,
        interrupted: interrupted,
        worked: worked,
        usage: usage,
      ),
    );
    _turnStarted = null;
    _turnUsageStart = null;
    _turnUsage = null;
    if (drain && !interrupted) _startNextQueued();
  }

  TurnUsage? _usageForTurn(Duration? worked) {
    final end = _turnUsage;
    if (end == null) return null;
    int value(Map<String, Object?>? map, String key) {
      final value = map?[key];
      return value is int ? value : 0;
    }

    final start = _turnUsageStart;
    final input = (value(end, 'inputTokens') - value(start, 'inputTokens'))
        .clamp(0, 1 << 62);
    final output = (value(end, 'outputTokens') - value(start, 'outputTokens'))
        .clamp(0, 1 << 62);
    if (input == 0 && output == 0) return null;
    final seconds = worked?.inMilliseconds == 0
        ? null
        : (worked?.inMilliseconds ?? 0) / 1000;
    return TurnUsage(
      inputTokens: input,
      outputTokens: output,
      tokensPerSecond: seconds == null || seconds <= 0
          ? null
          : output / seconds,
    );
  }

  void _startNextQueued() {
    if (_turn != null || _queuedTurns.isEmpty) return;
    final next = _queuedTurns.removeAt(0);
    _begin(next);
  }

  void _waitForCancelledTurn() {
    if (_queuedTurns.isEmpty) return;
    _drainTimer?.cancel();
    _drainTimer = Timer(const Duration(seconds: 2), () {
      _drainTimer = null;
      if (!_cancelPending) return;
      _cancelPending = false;
      _startNextQueued();
    });
  }

  void _removeQueued() {
    for (final turn in _queuedTurns) {
      emit(ItemRemoved(nextSeq, turn.id));
    }
    _queuedTurns.clear();
  }

  void _failTurn(String turn, String message) {
    _notice(message, kind: NoticeKind.error);
    if (_turn == turn) {
      _endTurn(turn, interrupted: false);
    }
  }

  void _notice(String text, {NoticeKind kind = NoticeKind.error}) {
    final seq = nextSeq;
    emit(ItemUpserted(seq, 'notice:$seq', NoticeItem(kind, text)));
  }

  void _respond(Object? rpcId, Map<String, Object?> result) {
    _transport.write({'id': rpcId, 'result': result});
  }

  void _rejectInteractions({required bool cancel}) {
    for (final entry in _interactions.entries) {
      final pending = entry.value;
      switch (pending.kind) {
        case _InteractionKind.approval:
          _respond(pending.rpcId, {'decision': cancel ? 'cancel' : 'decline'});
        case _InteractionKind.permissions:
          _respond(pending.rpcId, {'permissions': const {}, 'scope': 'turn'});
        case _InteractionKind.question:
          _respond(pending.rpcId, {'answers': const {}});
        case _InteractionKind.elicitation:
        case _InteractionKind.url:
          _respond(pending.rpcId, {'action': cancel ? 'cancel' : 'decline'});
      }
      emit(InteractionResolved(nextSeq, entry.key));
    }
    _interactions.clear();
  }

  static String _modeId(String? value) => switch (value) {
    'ask' || 'plan' || 'agent' => value!,
    _ => 'agent',
  };

  static String _permissionId(String? value) => switch (value) {
    'readOnly' || 'auto' || 'fullAccess' || 'ask' => value!,
    _ => 'ask',
  };
}

enum _InteractionKind { approval, permissions, question, elicitation, url }

class _PendingInteraction {
  const _PendingInteraction({
    required this.rpcId,
    required this.kind,
    required this.params,
    this.questionIds = const [],
    this.fields = const [],
  });

  final Object? rpcId;
  final _InteractionKind kind;
  final Map<String, Object?> params;
  final List<String> questionIds;
  final List<_ElicitationField> fields;
}

class _ModelInfo {
  const _ModelInfo({
    required this.id,
    required this.label,
    required this.description,
    required this.efforts,
    required this.defaultEffort,
    required this.inputModalities,
    required this.serviceTiers,
    required this.defaultServiceTier,
    required this.isDefault,
  });

  final String id;
  final String label;
  final String description;
  final List<KernelOption> efforts;
  final String? defaultEffort;
  final List<String> inputModalities;
  final List<KernelOption> serviceTiers;
  final String? defaultServiceTier;
  final bool isDefault;
}

class _CodexModelSetting implements ModelSetting {
  const _CodexModelSetting(this.kernel);

  final CodexKernel kernel;

  @override
  List<KernelOption> optionsFor(String model) => kernel._effortsFor(model);

  @override
  String? get selected => kernel._effortFor(kernel.model.selected ?? '');

  @override
  String? selectedFor(String model) => kernel._effortFor(model);

  @override
  void select(String model, String id) {
    if (kernel.model.selected != model) kernel.model.reported = model;
    kernel._pickedEffort = id;
    kernel._effortsByModel[model] = id;
    kernel.emitInfoChanged();
  }

  @override
  bool get toggle => false;
}

class _CodexServiceTierSetting implements ModelSetting {
  const _CodexServiceTierSetting(this.kernel);

  final CodexKernel kernel;

  @override
  List<KernelOption> optionsFor(String model) => kernel._tiersFor(model);

  @override
  String? get selected => kernel._tierFor(kernel.model.selected ?? '');

  @override
  String? selectedFor(String model) => kernel._tierFor(model);

  @override
  void select(String model, String id) {
    if (kernel.model.selected != model) kernel.model.reported = model;
    kernel._pickedTier = id;
    kernel._tiersByModel[model] = id;
    kernel.emitInfoChanged();
  }

  @override
  bool get toggle => false;
}

class _ElicitationField {
  _ElicitationField({
    required this.id,
    required this.question,
    required this.type,
    required this.multiple,
    required this.values,
  });

  factory _ElicitationField.from(String id, Map schema) {
    final title = schema['title'] as String? ?? id;
    final description = schema['description'] as String? ?? '';
    final type = '${schema['type'] ?? 'string'}';
    final multiple = type == 'array';
    final optionSchema = multiple && schema['items'] is Map
        ? schema['items'] as Map
        : schema;
    final options = <QuestionOption>[];
    final values = <String, String>{};
    void add(String label, String value) {
      values[label] = value;
      options.add(QuestionOption(label));
    }

    if (type == 'boolean') {
      add('Yes', 'true');
      add('No', 'false');
    } else if (optionSchema['enum'] case final List choices) {
      for (final choice in choices) {
        add('$choice', '$choice');
      }
    } else if (optionSchema['oneOf'] case final List choices) {
      for (final choice in choices) {
        if (choice is! Map) continue;
        final value = '${choice['const'] ?? ''}';
        add(choice['title'] as String? ?? value, value);
      }
    } else if (optionSchema['anyOf'] case final List choices) {
      for (final choice in choices) {
        if (choice is! Map) continue;
        final value = '${choice['const'] ?? ''}';
        add(choice['title'] as String? ?? value, value);
      }
    }
    final choicesOnly =
        ['boolean', 'array'].contains(type) || options.isNotEmpty;
    return _ElicitationField(
      id: id,
      type: type,
      multiple: multiple,
      values: values,
      question: Question(
        prompt: description.isEmpty ? title : '$title\n$description',
        header: id,
        options: options,
        allowMultiple: multiple,
        allowOther: !choicesOnly || type == 'array' && options.isEmpty,
      ),
    );
  }

  final String id;
  final String type;
  final bool multiple;
  final Map<String, String> values;
  final Question question;

  Object? valueFor(List<String> picked) {
    if (multiple) {
      return [for (final value in picked) values[value] ?? value];
    }
    final raw = picked.firstOrNull;
    if (raw == null) return null;
    final value = values[raw] ?? raw;
    return switch (type) {
      'boolean' => value == 'true',
      'integer' => int.tryParse(value) ?? value,
      'number' => num.tryParse(value) ?? value,
      _ => value,
    };
  }
}
