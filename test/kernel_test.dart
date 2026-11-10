import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart' show ChangeNotifier, Icons;
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:bao_remote/claude.dart'
    show ClaudeHistoryPage, ClaudeNotInstalled;
import 'package:baocode/chat/chat_models.dart';
import 'package:baocode/chat/widgets/agent_step.dart' show AgentStep;
import 'package:baocode/models/model_provider.dart' show ModelProvider;
import 'package:baocode/models/model_providers.dart' show ModelProviders;
import 'package:baocode/chat/widgets/tool_call_row.dart';
import 'package:baocode/chat/chat_session.dart';
import 'package:baocode/kernel/agent_kernel.dart';
import 'package:baocode/kernel/claude_code/claude_code_kernel.dart';
import 'package:baocode/kernel/claude_code/claude_code_transport.dart';
import 'package:baocode/kernel/claude_code/claude_code_translator.dart';
import 'package:baocode/kernel/claude_code/claude_environment.dart';
import 'package:baocode/kernel/claude_code/claude_sdk_tools.dart';
import 'package:baocode/kernel/claude_code/claude_storage_io.dart';
import 'package:baocode/kernel/claude_code/cli_locator.dart';
import 'package:baocode/kernel/claude_code/control_channel.dart';
import 'package:baocode/kernel/claude_code/turn_stats.dart';
import 'package:baocode/kernel/commit_attribution.dart';
import 'package:baocode/kernel/extension_switches.dart';
import 'package:baocode/kernel/kernel_event.dart';
import 'package:baocode/kernel/kernel_types.dart';
import 'package:baocode/kernel/mock/mock_kernels.dart';
import 'package:baocode/kernel/queued_messages.dart';
import 'package:baocode/kernel/transcript.dart';
import 'package:baocode/link/chat_codec.dart' show ChatCodec;
import 'package:baocode/usage/usage_ledger.dart';
import 'package:baocode/usage/usage_prices.dart';

/// Lines Claude Code 2.1.311 printed (recorded, with paths and account
/// details replaced).
List<Map<String, Object?>> recorded(String name) => [
  for (final line in File(
    'test/fixtures/claude_code/$name.jsonl',
  ).readAsLinesSync())
    if (line.trim().isNotEmpty)
      (jsonDecode(line) as Map).cast<String, Object?>(),
];

/// The smallest bytes [CliLocator] asks of a program Windows can run.
Uint8List _windowsProgram() => Uint8List(0x48)
  ..setAll(0, 'MZ'.codeUnits)
  ..[0x3C] = 0x40
  ..setAll(0x40, [0x50, 0x45, 0, 0]);

/// The payload of the recorded response to [subtype], e.g. `initialize`.
Map<String, Object?> recordedResponse(String name, bool Function(Map) match) {
  for (final message in recorded(name)) {
    if (message['type'] != 'control_response') continue;
    final payload = (message['response'] as Map)['response'];
    if (payload is Map && match(payload)) return payload.cast();
  }
  throw StateError('no such response in $name');
}

/// Claude Code as the test speaks it: answers control requests the way the
/// CLI does (from recordings), and records what the kernel wrote.
/// A CLI that answers nothing: one that exits before it does.
class _SilentCli extends FakeCli {
  @override
  void write(Map<String, Object?> message) => written.add(message);
}

class FakeCli implements ClaudeCodeTransport {
  FakeCli({this.answers = const {}});

  /// Responses by control request subtype; `initialize` and
  /// `get_context_usage` default to the recorded ones.
  final Map<String, Map<String, Object?>> answers;
  final StreamController<Map<String, Object?>> _out =
      StreamController.broadcast();
  final List<Map<String, Object?>> written = [];
  bool closed = false;

  static final _initialize = recordedResponse(
    'question',
    (payload) => payload.containsKey('commands'),
  );
  static final _context = recordedResponse(
    'question',
    (payload) => payload.containsKey('categories'),
  );

  @override
  Stream<Map<String, Object?>> get messages => _out.stream;

  void push(Map<String, Object?> message) => _out.add(message);

  /// Control requests written, by subtype.
  List<Map<String, Object?>> requests(String subtype) => [
    for (final message in written)
      if (message['type'] == 'control_request' &&
          (message['request'] as Map)['subtype'] == subtype)
        (message['request'] as Map).cast<String, Object?>(),
  ];

  List<Map<String, Object?>> get users => [
    for (final message in written)
      if (message['type'] == 'user') message,
  ];

  List<Map<String, Object?>> get responses => [
    for (final message in written)
      if (message['type'] == 'control_response')
        ((message['response'] as Map)['response'] as Map)
            .cast<String, Object?>(),
  ];

  @override
  void write(Map<String, Object?> message) {
    written.add(message);
    if (message['type'] != 'control_request') return;
    final subtype = (message['request'] as Map)['subtype'] as String;
    final payload =
        answers[subtype] ??
        switch (subtype) {
          'initialize' => _initialize,
          'get_context_usage' => _context,
          _ => const <String, Object?>{},
        };
    // As the CLI does: the message cancelled is told of before the answer.
    if (subtype == 'cancel_async_message' && payload['cancelled'] == true) {
      push({
        'type': 'command_lifecycle',
        'command_uuid': (message['request'] as Map)['message_uuid'],
        'state': 'cancelled',
      });
    }
    push({
      'type': 'control_response',
      'response': {
        'subtype': 'success',
        'request_id': message['request_id'],
        'response': payload,
      },
    });
  }

  @override
  void close() => closed = true;

  @override
  Future<void> get exited async {}
}

/// A CLI whose answers to `get_usage` are [replies], in turn (the last

/// A CLI that answers `initialize` only once [initialized] is called.
class _SlowStartCli extends FakeCli {
  Map<String, Object?>? _initialize;

  void initialized() {
    if (_initialize case final message?) super.write(message);
  }

  @override
  void write(Map<String, Object?> message) {
    final request = message['request'];
    if (request is Map && request['subtype'] == 'initialize') {
      _initialize = message;
      return;
    }
    super.write(message);
  }
}

/// A kernel on [cli], with its events applied to a transcript.
({ClaudeCodeKernel kernel, Transcript transcript, List<KernelEvent> events})
claude(FakeCli cli, {KernelContext context = const KernelContext(cwd: '/p')}) {
  final kernel = ClaudeCodeKernel(
    MockKernels.claudeCode,
    context,
    start: (_) async => cli,
  );
  final transcript = Transcript();
  final events = <KernelEvent>[];
  kernel.events.listen((event) {
    events.add(event);
    transcript.apply(event);
  });
  return (kernel: kernel, transcript: transcript, events: events);
}

/// What the history shows of [transcript], one line an item; thoughts,
/// which only a live session streams, left out.
List<String> shown(Transcript transcript) => [
  for (var i = 0; i < transcript.length; i++)
    switch (transcript.itemAt(i)) {
      UserMessageItem(:final text) => 'user: ${text.split('\n').first}',
      AssistantTextItem(:final text) => 'text: ${text.split('\n').first}',
      ThinkingItem() => '',
      ToolCallItem(:final kind, :final label, :final target) =>
        'tool: ${label ?? kind.name} $target',
      TerminalItem(:final command, :final background) =>
        'terminal: $command${background ? ' (background)' : ''}',
      CodeDiffItem(:final fileName, :final lines) =>
        'diff: $fileName +${lines.length}',
      AgentItem(:final description) => 'agent: $description',
      NoticeItem(:final kind, :final text) => 'notice ${kind.name}: $text',
      PlanItem(:final round, :final status, :final writes) =>
        'plan v$round ${status.name} ×$writes',
      LiveStatusItem(:final label) => 'status: $label',
    },
].where((line) => line.isNotEmpty).toList();

void main() {
  group('Claude Code translator (recorded)', () {
    test('tools, a background command and a subagent', () {
      final transcript = Transcript();
      var seq = 0;
      final translator = ClaudeTranslator(
        emit: transcript.apply,
        nextSeq: () => ++seq,
      )..turnId = '11111111-1111-4111-8111-111111111111';
      for (final message in recorded('tasks')) {
        translator.translate(message);
        if ((message['tool_use_result'] as Map?)?['backgroundTaskId'] != null) {
          final task = transcript.tasks
              .where((task) => task.kind == KernelTaskKind.command)
              .single;
          expect(task.status, CommandStatus.running);
          expect(task.outputFile, endsWith('/tasks/bft071fdo.output'));
        }
      }
      expect(
        transcript.tasks
            .where((task) => task.kind == KernelTaskKind.command)
            .single
            .outputFile,
        endsWith('/tasks/bft071fdo.output'),
      );
      expect(shown(transcript), [
        'user: Do these steps in order: 1) Write file a.txt containing '
            "'one'. 2) Run `sleep 4; echo bg-done` with the Bash tool using "
            'run_in_background true. 3) Use the Agent/Task tool with '
            'subagent_type general-purpose to read a.txt and report its '
            'content in one word. 4) Record a 2-item todo list with your '
            "todo tool. 5) Reply 'ok'.",
        'diff: a.txt +1',
        'terminal: sleep 4; echo bg-done (background)',
        'tool: Looked up tools todo list write',
        'tool: Looked up tools TodoWrite',
        'agent: Read a.txt content',
        startsWith('text: No dedicated todo tool is available'),
      ]);

      final items = [
        for (var i = 0; i < transcript.length; i++) transcript.itemAt(i),
      ];
      // The background command settled after its turn went on.
      final terminal = items.whereType<TerminalItem>().single;
      expect(terminal.status, CommandStatus.succeeded);
      expect(terminal.output, contains('completed (exit code 0)'));
      // The subagent's own steps are nested in it, with its report.
      final agent = items.whereType<AgentItem>().single;
      expect(agent.status, CommandStatus.succeeded);
      expect(agent.agentType, 'general-purpose');
      expect(agent.children.whereType<ToolCallItem>().single.target, 'a.txt');
      expect(agent.result, contains('One'));
      // Tasks, as last reported.
      expect(
        {
          for (final task in transcript.tasks)
            task.kind: (task.status, task.background),
        },
        {
          KernelTaskKind.command: (CommandStatus.succeeded, true),
          KernelTaskKind.agent: (CommandStatus.succeeded, false),
        },
      );
      // The file written is a pending change of the turn.
      expect(transcript.edits.single.change.path, '/tmp/project/a.txt');
      expect(transcript.edits.single.turnId, startsWith('11111111'));
    });

    test('what a call wrote is let go of once it is answered', () {
      final transcript = Transcript();
      var seq = 0;
      final translator = ClaudeTranslator(
        emit: transcript.apply,
        nextSeq: () => ++seq,
      );
      // A call that writes a whole file: its input holds the file.
      translator.translate({
        'type': 'assistant',
        'message': {
          'id': 'm1',
          'role': 'assistant',
          'content': [
            {
              'type': 'tool_use',
              'id': 'w1',
              'name': 'Write',
              'input': {'file_path': '/p/a.txt', 'content': 'x' * 100000},
            },
          ],
        },
      });
      // Its answer: the call is done, and the file it wrote is not needed
      // any more. What says what it did is kept.
      translator.translate({
        'type': 'user',
        'message': {
          'role': 'user',
          'content': [
            {'type': 'tool_result', 'tool_use_id': 'w1', 'content': 'ok'},
          ],
        },
      });
    });



    test('the summary a compacted conversation goes on from is not shown '
        'as a message: live or kept', () {
      final transcript = Transcript();
      var seq = 0;
      final translator = ClaudeTranslator(
        emit: transcript.apply,
        nextSeq: () => ++seq,
      );
      Map<String, Object?> user(String uuid, Map<String, Object?> marks) => {
        'type': 'user',
        'uuid': uuid,
        'parent_tool_use_id': null,
        'message': {
          'role': 'user',
          'content':
              'This session is being continued from a previous '
              'conversation that ran out of context.',
        },
        ...marks,
      };
      translator
        ..translate(user('live', {'isSynthetic': true, 'isReplay': false}))
        ..translate(
          user('kept', {
            'isCompactSummary': true,
            'isVisibleInTranscriptOnly': true,
          }),
        )
        ..translate(user('typed', {}));
      expect(
        [for (var i = 0; i < transcript.length; i++) transcript.itemAt(i)]
            .whereType<UserMessageItem>(),
        hasLength(1),
      );
    });

    test('a question answered for the user shows as skipped', () {
      final transcript = Transcript();
      var seq = 0;
      final translator = ClaudeTranslator(
        emit: transcript.apply,
        nextSeq: () => ++seq,
      )..turnId = '11111111-1111-4111-8111-111111111111';
      void ask(String id, String answer) => translator
        ..translate({
          'type': 'assistant',
          'parent_tool_use_id': null,
          'message': {
            'id': 'msg-$id',
            'role': 'assistant',
            'content': [
              {
                'type': 'tool_use',
                'id': id,
                'name': 'AskUserQuestion',
                'input': {
                  'questions': [
                    {'question': 'Red or blue?', 'header': 'Color'},
                  ],
                },
              },
            ],
          },
        })
        ..translate({
          'type': 'user',
          'parent_tool_use_id': null,
          'message': {
            'role': 'user',
            'content': [
              {
                'type': 'tool_result',
                'tool_use_id': id,
                'content': answer,
                'is_error': true,
              },
            ],
          },
        });
      ask('q1', ClaudeTranslator.unattendedAnswer);
      ask('q2', 'The user dismissed the questions without answering.');
      final items = [
        for (var i = 0; i < transcript.length; i++) transcript.itemAt(i),
      ].whereType<ToolCallItem>();
      expect(items.map((item) => (item.kind, item.target, item.status)), [
        (ToolKind.question, 'Color', ToolStatus.denied),
        (ToolKind.question, 'Color', ToolStatus.failed),
      ]);
      expect(
        toolVerb(ToolKind.question, status: ToolStatus.denied),
        'Skipped question',
      );
      expect(toolVerb(ToolKind.question), 'Asked');
    });


    test('a message sent to an agent reads on its line, in full opened', () {
      final transcript = Transcript();
      var seq = 0;
      final translator = ClaudeTranslator(
        emit: transcript.apply,
        nextSeq: () => ++seq,
      )..turnId = '11111111-1111-4111-8111-111111111111';
      void send(String id, Object message, {bool failed = false}) => translator
        ..translate({
          'type': 'assistant',
          'parent_tool_use_id': null,
          'message': {
            'id': 'msg-$id',
            'role': 'assistant',
            'content': [
              {
                'type': 'tool_use',
                'id': id,
                'name': 'SendMessage',
                'input': {
                  'to': 'a6adebf0ce09d0049',
                  'summary': 'Say hello',
                  'message': message,
                },
              },
            ],
          },
        })
        ..translate({
          'type': 'user',
          'parent_tool_use_id': null,
          'message': {
            'role': 'user',
            'content': [
              {
                'type': 'tool_result',
                'tool_use_id': id,
                'content': failed ? 'No such agent.' : 'Message sent.',
                'is_error': failed,
              },
            ],
          },
        });
      send('m1', 'Return the text:\n  hello');
      send('m2', 'Return hello', failed: true);
      send('m3', {'type': 'shutdown_request'});
      final items = [
        for (var i = 0; i < transcript.length; i++) transcript.itemAt(i),
      ].whereType<ToolCallItem>();
      expect(items.map((item) => (item.kind, item.target, item.output)), [
        (
          ToolKind.message,
          'Return the text: hello',
          'Return the text:\n  hello',
        ),
        (ToolKind.message, 'Return hello', 'No such agent.'),
        (ToolKind.message, 'Say hello', 'Message sent.'),
      ]);
      // It says it in words of its own: "Said …".
      expect(items.map((item) => item.label), everyElement(isNull));
      expect(toolVerb(ToolKind.message), 'Said');
    });

    test('todos written read as a step: the list its text', () {
      final transcript = Transcript();
      var seq = 0;
      final translator = ClaudeTranslator(
        emit: transcript.apply,
        nextSeq: () => ++seq,
      )..turnId = '11111111-1111-4111-8111-111111111111';
      void call(
        String id,
        String name,
        Map<String, Object?> input,
        String result, {
        Map<String, Object?>? structured,
      }) => translator
        ..translate({
          'type': 'assistant',
          'parent_tool_use_id': null,
          'message': {
            'id': 'msg-$id',
            'role': 'assistant',
            'content': [
              {'type': 'tool_use', 'id': id, 'name': name, 'input': input},
            ],
          },
        })
        ..translate({
          'type': 'user',
          'parent_tool_use_id': null,
          'message': {
            'role': 'user',
            'content': [
              {'type': 'tool_result', 'tool_use_id': id, 'content': result},
            ],
          },
          'tool_use_result': ?structured,
        });
      call('t1', 'TodoWrite', {
        'todos': [
          {
            'content': 'Read it',
            'status': 'completed',
            'activeForm': 'Reading',
          },
          {
            'content': 'Fix it',
            'status': 'in_progress',
            'activeForm': 'Fixing',
          },
          {'content': 'Test it', 'status': 'pending', 'activeForm': 'Testing'},
        ],
      }, 'Todos have been modified successfully.');
      call(
        't2',
        'TaskCreate',
        {'subject': 'Ship it'},
        'Task #1 created successfully: Ship it',
        structured: {
          'task': {'id': '1', 'subject': 'Ship it'},
        },
      );
      call('t3', 'TaskUpdate', {
        'taskId': '1',
        'status': 'completed',
      }, 'Updated task #1 status');
      call('t4', 'TaskUpdate', {
        'taskId': '7',
        'status': 'deleted',
      }, 'Updated task #7 deleted');
      final items = [
        for (var i = 0; i < transcript.length; i++) transcript.itemAt(i),
      ].whereType<ToolCallItem>().toList();
      expect(items.map((item) => (item.kind, item.target, item.output)), [
        (ToolKind.todo, 'Fix it', '☒ Read it\n◐ Fix it\n☐ Test it'),
        (ToolKind.todo, 'Ship it', 'Task #1 created successfully: Ship it'),
        (ToolKind.todo, 'Ship it', 'Updated task #1 status'),
        (ToolKind.todo, '#7', 'Updated task #7 deleted'),
      ]);
      // What each did, said by its line.
      expect(
        [
          for (final item in items)
            todoStep(item.tool, item.input, item.target),
        ],
        [
          (verb: 'Todos 1/3', object: 'Fix it', detail: null),
          (verb: 'Added todo', object: 'Ship it', detail: null),
          (verb: 'Completed todo', object: 'Ship it', detail: null),
          (verb: 'Removed todo', object: '#7', detail: null),
        ],
      );
      expect(
        todoStep('TodoWrite', {
          'todos': [
            {'content': 'Read it', 'status': 'completed'},
          ],
        }, ''),
        (verb: 'Todos 1/1', object: 'All done', detail: null),
      );
      // A list read: from the lines it returned.
      const listed =
          '#1 [completed] Ship it\n'
          '#2 [in_progress] Tag it (alice)\n'
          '#3 [pending] Tell them [blocked by #2]';
      expect(todoItems('TaskList', const {}, listed), [
        (content: 'Ship it', status: 'completed'),
        (content: 'Tag it (alice)', status: 'in_progress'),
        (content: 'Tell them [blocked by #2]', status: 'pending'),
      ]);
      expect(todoStep('TaskList', const {}, '', output: listed), (
        verb: 'Checked todos',
        object: 'Tag it (alice)',
        detail: '1/3',
      ));
      expect(
        todoStep('TaskList', const {}, '', output: '#1 [completed] Ship it'),
        (verb: 'Checked todos', object: 'All done', detail: '1/1'),
      );
      expect(todoStep('TaskList', const {}, '', output: 'No tasks found'), (
        verb: 'Checked todos',
        object: 'List empty',
        detail: null,
      ));
    });

    test('a subagent shows the model its messages ran on, as it runs; '
        'the one the CLI resolved only without them', () {
      final transcript = Transcript();
      var seq = 0;
      final translator = ClaudeTranslator(
        emit: transcript.apply,
        nextSeq: () => ++seq,
      )..turnId = '11111111-1111-4111-8111-111111111111';
      void start(String id) => translator.translate({
        'type': 'assistant',
        'parent_tool_use_id': null,
        'message': {
          'id': 'msg-$id',
          'role': 'assistant',
          'content': [
            {
              'type': 'tool_use',
              'id': id,
              'name': 'Agent',
              'input': {'description': 'Look $id', 'prompt': 'look'},
            },
          ],
        },
      });
      void said(String parent, String model) => translator.translate({
        'type': 'assistant',
        'parent_tool_use_id': parent,
        'message': {
          'id': 'msg-$parent-$model',
          'role': 'assistant',
          'model': model,
          'content': [
            {'type': 'text', 'text': 'looking'},
          ],
        },
      });
      void done(String id) => translator.translate({
        'type': 'user',
        'parent_tool_use_id': null,
        'message': {
          'role': 'user',
          'content': [
            {'type': 'tool_result', 'tool_use_id': id, 'content': 'ok'},
          ],
        },
        'tool_use_result': {'resolvedModel': 'claude-sonnet-5-5'},
      });
      String? model(String id) => [
        for (final (key, item) in transcript.liveItems)
          if (key == id && item is AgentItem) item.model,
      ].single;

      start('a1');
      expect(model('a1'), isNull);
      said('a1', 'claude-haiku-5-5');
      expect(model('a1'), 'claude-haiku-5-5');
      // A synthetic message (an error) is no model's.
      said('a1', '<synthetic>');
      done('a1');
      expect(model('a1'), 'claude-haiku-5-5');

      start('a2');
      done('a2');
      expect(model('a2'), 'claude-sonnet-5-5');
    });

    test('a subagent\'s model reads as people read it', () {
      final providers = ModelProviders.memory(
        providers: [
          ModelProvider.fromJson({
            'id': 'od',
            'name': 'open-design',
            'protocol': 'openai',
            'baseUrl': 'https://example.com/v1',
            'models': [
              {'id': 'deepseek-v4.1-flash', 'label': 'DeepSeek V4.1 Flash'},
            ],
          })!,
        ],
      );
      ({String label, String? upstream}) name(String model) =>
          AgentStep.modelName(model, providers: providers);
      expect(name('deepseek-v4.1-flash'), (
        label: 'DeepSeek V4.1 Flash',
        upstream: 'open-design',
      ));
      expect(name('@od/deepseek-v4.1-flash').label, 'DeepSeek V4.1 Flash');
      expect(name('claude-opus-5-5'), (label: 'Opus 5.5', upstream: null));
      expect(name('claude-haiku-4-5-20251001').label, 'Haiku 4.5');
      expect(name('claude-3-5-sonnet-20241022').label, 'Sonnet 3.5');
      expect(name('claude-sonnet-4-20250514[1m]').label, 'Sonnet 4');
      expect(name('glm-5.3').label, 'glm-5.3');
    });

    test('a notebook edit shows its cell changed, line by line', () {
      final transcript = Transcript();
      var seq = 0;
      final translator = ClaudeTranslator(
        emit: transcript.apply,
        nextSeq: () => ++seq,
      )..turnId = '11111111-1111-4111-8111-111111111111';
      void edit(String id, Map<String, Object?> result) {
        translator
          ..translate({
            'type': 'assistant',
            'parent_tool_use_id': null,
            'message': {
              'id': 'msg-$id',
              'role': 'assistant',
              'content': [
                {
                  'type': 'tool_use',
                  'id': id,
                  'name': 'NotebookEdit',
                  'input': {'notebook_path': '/p/demo.ipynb'},
                },
              ],
            },
          })
          ..translate({
            'type': 'user',
            'parent_tool_use_id': null,
            'message': {
              'role': 'user',
              'content': [
                {
                  'type': 'tool_result',
                  'tool_use_id': id,
                  'content': 'Updated cell',
                },
              ],
            },
            'tool_use_result': {'notebook_path': '/p/demo.ipynb', ...result},
          });
      }

      edit('t1', {
        'edit_mode': 'replace',
        'old_source': 'import os\nx = 1\nprint(x)',
        'new_source': 'import os\nx = 2\nprint(x)',
      });
      edit('t2', {'edit_mode': 'insert', 'new_source': 'a\nb'});
      edit('t3', {
        'edit_mode': 'delete',
        'old_source': 'gone',
        'new_source': '',
      });

      final diffs = [
        for (var i = 0; i < transcript.length; i++)
          if (transcript.itemAt(i) case final CodeDiffItem diff) diff,
      ];
      String marked(DiffLine line) =>
          '${switch (line.type) {
            DiffLineType.added => '+',
            DiffLineType.removed => '-',
            DiffLineType.context => ' ',
          }}${line.lineNumber} ${line.text}';
      expect(diffs.map((diff) => diff.fileName).toSet(), {'demo.ipynb'});
      expect(diffs[0].lines.map(marked), [
        ' 1 import os',
        '-2 x = 1',
        '+2 x = 2',
        ' 3 print(x)',
      ]);
      expect((diffs[0].added, diffs[0].removed), (1, 1));
      expect((diffs[1].added, diffs[1].removed), (2, 0));
      expect((diffs[2].added, diffs[2].removed), (0, 1));
      expect(transcript.edits, hasLength(3));
    });

    test("an edit tells what its file was before, a subagent's too", () {
      final events = <KernelEvent>[];
      var seq = 0;
      final translator = ClaudeTranslator(
        emit: events.add,
        nextSeq: () => ++seq,
      );
      void edit(
        String id,
        String name,
        Map<String, Object?> result, {
        String? parent,
      }) {
        translator
          ..translate({
            'type': 'assistant',
            'parent_tool_use_id': parent,
            'message': {
              'id': 'msg-$id',
              'role': 'assistant',
              'content': [
                {
                  'type': 'tool_use',
                  'id': id,
                  'name': name,
                  'input': {'file_path': result['filePath']},
                },
              ],
            },
          })
          ..translate({
            'type': 'user',
            'parent_tool_use_id': parent,
            'message': {
              'role': 'user',
              'content': [
                {'type': 'tool_result', 'tool_use_id': id, 'content': 'ok'},
              ],
            },
            'tool_use_result': {
              ...result,
              'structuredPatch': [
                {
                  'oldStart': 1,
                  'oldLines': 1,
                  'newStart': 1,
                  'newLines': 1,
                  'lines': ['-a', '+b'],
                },
              ],
            },
          });
      }

      edit('e1', 'Edit', {
        'filePath': '/p/a.txt',
        'oldString': 'a',
        'originalFile': 'a\n',
      });
      edit('w1', 'Write', {
        'type': 'create',
        'filePath': '/p/new.txt',
        'content': 'b\n',
        'originalFile': null,
      });
      edit('e2', 'Edit', {
        'filePath': '/p/sub.txt',
        'oldString': 'a',
        'originalFile': 'a\n',
      }, parent: 'agent-1');
      edit('e3', 'Edit', {'filePath': '/p/untold.txt', 'oldString': 'a'});
      final edits = {
        for (final event in events.whereType<FileEdited>())
          event.change.path: event.original,
      };
      expect(edits.keys, [
        '/p/a.txt',
        '/p/new.txt',
        '/p/sub.txt',
        '/p/untold.txt',
      ]);
      expect((edits['/p/a.txt']! as OriginalText).text, 'a\n');
      expect((edits['/p/new.txt']! as OriginalText).text, isNull);
      expect((edits['/p/sub.txt']! as OriginalText).text, 'a\n');
      expect(edits['/p/untold.txt'], isNull);
    });

    test("a subagent's edits, sent without their patches, are told from "
        'their input', () {
      final events = <KernelEvent>[];
      var seq = 0;
      final translator = ClaudeTranslator(
        emit: events.add,
        nextSeq: () => ++seq,
      );
      void call(
        String id,
        String name,
        Map<String, Object?> input, {
        String? parent,
        Object? result,
      }) {
        translator
          ..translate({
            'type': 'assistant',
            'parent_tool_use_id': parent,
            'message': {
              'id': 'msg-$id',
              'role': 'assistant',
              'content': [
                {'type': 'tool_use', 'id': id, 'name': name, 'input': input},
              ],
            },
          })
          ..translate({
            'type': 'user',
            'parent_tool_use_id': parent,
            'message': {
              'role': 'user',
              'content': [
                {'type': 'tool_result', 'tool_use_id': id, 'content': 'ok'},
              ],
            },
            'tool_use_result': ?result,
          });
      }

      translator.translate({
        'type': 'assistant',
        'parent_tool_use_id': null,
        'message': {
          'id': 'msg-agent',
          'role': 'assistant',
          'content': [
            {
              'type': 'tool_use',
              'id': 'agent-1',
              'name': 'Agent',
              'input': {'description': 'Make files', 'prompt': 'make them'},
            },
          ],
        },
      });
      call('w1', 'Write', {
        'file_path': '/p/a.txt',
        'content': 'one\ntwo\n',
      }, parent: 'agent-1');
      call('e1', 'Edit', {
        'file_path': '/p/b.txt',
        'old_string': 'x',
        'new_string': 'y\nz',
      }, parent: 'agent-1');
      expect(
        [
          for (final event in events.whereType<FileEdited>())
            (event.change.path, event.change.added, event.change.removed),
        ],
        [('/p/a.txt', 2, 0), ('/p/b.txt', 2, 1)],
      );
      // A Write's file before is not known; an Edit's, by its texts.
      final originals = [
        for (final event in events.whereType<FileEdited>()) event.original,
      ];
      expect(originals.first, isNull);
      expect((originals.last! as OriginalByEdits).edits, [
        (before: 'x', after: 'y\nz'),
      ]);

      // A kept session's, replayed: nothing to review.
      events.clear();
      translator.replaying = true;
      call('w2', 'Write', {'file_path': '/p/d.txt', 'content': 'd'});
      expect(events.whereType<FileEdited>(), isEmpty);
    });

    test("a subagent's message shows as its, by what it was given to do", () {
      final transcript = Transcript();
      var seq = 0;
      final translator = ClaudeTranslator(
        emit: transcript.apply,
        nextSeq: () => ++seq,
      );
      translator
        ..translate({
          'type': 'assistant',
          'parent_tool_use_id': null,
          'message': {
            'id': 'msg-agent',
            'role': 'assistant',
            'content': [
              {
                'type': 'tool_use',
                'id': 'agent-1',
                'name': 'Agent',
                'input': {
                  'description': 'Count entries',
                  'prompt': 'count them',
                  'run_in_background': true,
                },
              },
            ],
          },
        })
        ..translate({
          'type': 'user',
          'parent_tool_use_id': null,
          'message': {
            'role': 'user',
            'content': [
              {
                'type': 'tool_result',
                'tool_use_id': 'agent-1',
                'content': 'launched',
              },
            ],
          },
          'tool_use_result': {
            'status': 'async_launched',
            'agentId': 'amup9hacc',
          },
        });
      void say(String uuid, String text) => translator.translate({
        'type': 'user',
        'parent_tool_use_id': null,
        'uuid': uuid,
        'message': {'role': 'user', 'content': text},
      });
      say(
        'm1',
        '<agent-message from="amup9hacc">\nB is done.\n</agent-message>',
      );
      say('m2', '<agent-message from="zz9">\nHi\n</agent-message>');
      final messages = [
        for (var i = 0; i < transcript.length; i++)
          if (transcript.itemAt(i) case final UserMessageItem message) message,
      ];
      expect(
        [for (final m in messages) (m.fromAgent, m.text)],
        [('Count entries', 'B is done.'), ('zz9', 'Hi')],
      );
      // As the phone gets it.
      final decoded =
          ChatCodec.decode(ChatCodec.encode(messages.first)) as UserMessageItem;
      expect(decoded.fromAgent, 'Count entries');
    });

    test("a Windows path's file shows by its name", () {
      final transcript = Transcript();
      var seq = 0;
      final translator = ClaudeTranslator(
        emit: transcript.apply,
        nextSeq: () => ++seq,
      );
      void call(
        String id,
        String name,
        Map<String, Object?> input, {
        Object? result,
      }) => translator
        ..translate({
          'type': 'assistant',
          'parent_tool_use_id': null,
          'message': {
            'id': 'msg-$id',
            'role': 'assistant',
            'content': [
              {'type': 'tool_use', 'id': id, 'name': name, 'input': input},
            ],
          },
        })
        ..translate({
          'type': 'user',
          'parent_tool_use_id': null,
          'message': {
            'role': 'user',
            'content': [
              {'type': 'tool_result', 'tool_use_id': id, 'content': 'ok'},
            ],
          },
          'tool_use_result': ?result,
        });

      call('r1', 'Read', {'file_path': r'C:\p\lib\a.dart'});
      call('l1', 'LS', {'path': r'C:\p\lib'});
      call(
        'e1',
        'Edit',
        {'file_path': r'C:\p\lib\b.dart', 'old_string': 'x', 'new_string': 'y'},
        result: {
          'filePath': r'C:\p\lib\b.dart',
          'structuredPatch': [
            {
              'oldStart': 1,
              'oldLines': 1,
              'newStart': 1,
              'newLines': 1,
              'lines': ['-x', '+y'],
            },
          ],
        },
      );
      expect(shown(transcript), [
        'tool: read a.dart',
        'tool: listDir lib',
        'diff: b.dart +2',
      ]);
      final diff = transcript.itemAt(2) as CodeDiffItem;
      expect(diff.directory, r'C:\p\lib');
    });

    test('each round of planning is one card; a plan sent back gives way '
        'to the next', () {
      final transcript = Transcript();
      var seq = 0;
      final translator = ClaudeTranslator(
        emit: transcript.apply,
        nextSeq: () => ++seq,
      );
      final paths = <String, Object?>{};
      void use(String id, String name, Map<String, Object?> input) {
        paths[id] = input['file_path'];
        translator.translate({
          'type': 'assistant',
          'parent_tool_use_id': null,
          'message': {
            'id': 'msg-$id',
            'role': 'assistant',
            'content': [
              {'type': 'tool_use', 'id': id, 'name': name, 'input': input},
            ],
          },
        });
      }

      void result(String id, {String content = 'ok', bool error = false}) =>
          translator.translate({
            'type': 'user',
            'parent_tool_use_id': null,
            'message': {
              'role': 'user',
              'content': [
                {
                  'type': 'tool_result',
                  'tool_use_id': id,
                  'content': content,
                  'is_error': error,
                },
              ],
            },
            'tool_use_result': {
              'filePath': paths[id],
              'structuredPatch': [
                {
                  'oldStart': 1,
                  'oldLines': 0,
                  'newStart': 1,
                  'newLines': 1,
                  'lines': ['+x'],
                },
              ],
            },
          });
      void streamedStart(String id, String name) {
        for (final event in [
          {
            'type': 'message_start',
            'message': {'id': 'msg-$id'},
          },
          {
            'type': 'content_block_start',
            'index': 0,
            'content_block': {'type': 'tool_use', 'id': id, 'name': name},
          },
        ]) {
          translator.translate({
            'type': 'stream_event',
            'parent_tool_use_id': null,
            'event': event,
          });
        }
      }

      PlanItem card(int i) => transcript.itemAt(i) as PlanItem;
      const plan = '/Users/me/.claude/plans/quiet-river.md';
      use('t1', 'Write', {
        'file_path': plan,
        'content': '# Grow the input\n\n1. Do it',
      });
      result('t1');
      expect(shown(transcript), ['plan v1 drafting ×1']);
      expect(card(0).title, 'Grow the input');
      expect(transcript.plan?.path, plan);

      // Written again (its row streamed first): the same card.
      streamedStart('t2', 'Edit');
      use('t2', 'Edit', {
        'file_path': plan,
        'old_string': 'Do it',
        'new_string': 'Do it well',
      });
      result('t2');
      // Its text, the edit made to it.
      expect(card(0).text, '# Grow the input\n\n1. Do it well');
      use('t3', 'Write', {'file_path': '/p/lib/a.dart', 'content': 'x'});
      result('t3');
      use('t4', 'ExitPlanMode', {'plan': '# Grow the input\n\n1. Do it'});
      expect(shown(transcript), ['plan v1 awaiting ×2', 'diff: a.dart +1']);
      result(
        't4',
        error: true,
        content: 'The user wants to keep planning: Keep it to five lines',
      );
      expect(card(0).status, PlanStatus.sentBack);
      expect(card(0).feedback, 'Keep it to five lines');

      // Written after it was sent back: a new round, a new card.
      use('t5', 'Edit', {
        'file_path': plan,
        'old_string': 'a',
        'new_string': 'b',
      });
      result('t5');
      use('t6', 'ExitPlanMode', {'plan': '# Five lines\n\n1. Do it'});
      result('t6');
      expect(shown(transcript), [
        'plan v1 sentBack ×2',
        'diff: a.dart +1',
        'plan v2 approved ×1',
      ]);
      expect(card(2).title, 'Five lines');
      expect(card(2).text, '# Five lines\n\n1. Do it');
      // Not a change to keep or undo.
      expect(transcript.edits.map((edit) => edit.change.path), [
        '/p/lib/a.dart',
      ]);

      // Put again unchanged after it was sent back: a round of its own.
      use('t7', 'ExitPlanMode', {'plan': '# Five lines'});
      expect(shown(transcript).last, 'plan v3 awaiting ×0');
    });

    test('a plan put to the user awaits their next message: sent back by '
        'one, started by the one that says so', () {
      const plan = '/Users/me/.claude/plans/quiet-river.md';
      final transcript = Transcript();
      var seq = 0;
      final translator = ClaudeTranslator(
        emit: transcript.apply,
        nextSeq: () => ++seq,
      );
      void use(String id, String name, Map<String, Object?> input) =>
          translator.translate({
            'type': 'assistant',
            'parent_tool_use_id': null,
            'message': {
              'id': 'msg-$id',
              'role': 'assistant',
              'content': [
                {'type': 'tool_use', 'id': id, 'name': name, 'input': input},
              ],
            },
          });
      void result(String id, {String content = 'ok', bool error = false}) =>
          translator.translate({
            'type': 'user',
            'parent_tool_use_id': null,
            'message': {
              'role': 'user',
              'content': [
                {
                  'type': 'tool_result',
                  'tool_use_id': id,
                  'content': content,
                  'is_error': error,
                },
              ],
            },
          });
      void prompt(String id, List<String> texts) => translator.translate({
        'type': 'user',
        'uuid': id,
        'parent_tool_use_id': null,
        'message': {
          'role': 'user',
          'content': [
            for (final text in texts) {'type': 'text', 'text': text},
          ],
        },
      });
      void putPlan(String id, String text) {
        use('w$id', 'Write', {'file_path': plan, 'content': text});
        result('w$id');
        use('x$id', 'ExitPlanMode', {'plan': text});
        result('x$id', content: ClaudeTranslator.planPresented, error: true);
      }

      putPlan('1', '# Grow the input');
      expect(shown(transcript), ['plan v1 awaiting ×1']);
      expect(translator.awaitingPlan?.round, 1);

      // A message: what should change.
      prompt('u1', ['Keep it short']);
      expect(shown(transcript), ['plan v1 sentBack ×1', 'user: Keep it short']);
      expect((transcript.itemAt(0) as PlanItem).feedback, 'Keep it short');
      expect(translator.awaitingPlan, isNull);

      // The next round, started: the note marks it, and is not shown.
      putPlan('2', '# Grow the input a little');
      expect(translator.awaitingPlan?.round, 2);
      prompt('u2', [
        'Carry out the plan',
        ClaudeTranslator.planStartedNote(plan),
      ]);
      expect(shown(transcript), [
        'plan v1 sentBack ×1',
        'user: Keep it short',
        'plan v2 approved ×1',
        'user: Carry out the plan',
      ]);
      expect(translator.awaitingPlan, isNull);
    });

    test('a plan said, not written, is its card all the same (no file)', () {
      final transcript = Transcript();
      var seq = 0;
      ClaudeTranslator(emit: transcript.apply, nextSeq: () => ++seq).translate({
        'type': 'assistant',
        'parent_tool_use_id': null,
        'message': {
          'id': 'msg-1',
          'role': 'assistant',
          'content': [
            {
              'type': 'tool_use',
              'id': 't1',
              'name': 'ExitPlanMode',
              'input': {'plan': '1. Do it'},
            },
          ],
        },
      });
      // Its card is all of it: put to the user, it awaits them (see the
      // kernel), with nothing else to start it by.
      final plan = transcript.itemAt(0) as PlanItem;
      expect(plan.text, '1. Do it');
      expect(plan.path, isEmpty);
      expect(transcript.plan, isNull);
    });

    test('the classifier billing warning is not shown, others are', () {
      final transcript = Transcript();
      var seq = 0;
      final translator = ClaudeTranslator(
        emit: transcript.apply,
        nextSeq: () => ++seq,
      );
      for (final (uuid, content) in [
        (
          'w1',
          "We're changing auto mode to no longer charge for classifier "
              'requests in Claude Code. To fix it, ask your gateway to '
              'implement: https://code.claude.com/docs/en/'
              'auto-mode-classifier-billing',
        ),
        ('w2', 'Something else'),
      ]) {
        translator.translate({
          'type': 'system',
          'subtype': 'informational',
          'level': 'warning',
          'uuid': uuid,
          'content': content,
        });
      }
      expect(transcript.length, 1);
      expect((transcript.itemAt(0) as NoticeItem).text, 'Something else');
    });

    test('replaying the kept session shows what streaming showed', () async {
      List<String> run(Iterable<Map<String, Object?>> messages, bool replay) {
        final transcript = Transcript();
        var seq = 0;
        final translator = ClaudeTranslator(
          emit: transcript.apply,
          nextSeq: () => ++seq,
        )..replaying = replay;
        messages.forEach(translator.translate);
        // Only the live run knows a background command's outcome.
        return shown(transcript)
            .map((line) => line.replaceAll(' (background)', ''))
            .toList();
      }

      final kept = await ClaudeStorage.read(
        SessionRecord(
          id: 'eafc328b',
          title: '',
          updatedAt: DateTime(2026),
          cwd: '/tmp/project',
          path: 'test/fixtures/claude_code/history.jsonl',
        ),
      );
      expect(run(kept, true), run(recorded('tasks'), false));
    });

    test('replaying times each turn, from its prompt to its last line', () {
      final transcript = Transcript();
      var seq = 0;
      final translator = ClaudeTranslator(
        emit: transcript.apply,
        nextSeq: () => ++seq,
      )..replaying = true;
      Map<String, Object?> line(
        String type,
        String uuid,
        int second,
        Object content,
      ) => {
        'type': type,
        'uuid': uuid,
        'timestamp': DateTime.utc(2026, 10, 1, 10, 0, second).toIso8601String(),
        'message': {'role': type, 'id': 'm-$uuid', 'content': content},
      };
      Map<String, Object?> said(String uuid, int second) =>
          line('assistant', uuid, second, [
            {'type': 'text', 'text': 'Said $uuid'},
          ]);
      for (final message in [
        line('user', 'p1', 0, 'Fix it'),
        said('a1', 5),
        said('a2', 45),
        line('user', 'p2', 50, 'And this'),
        said('a3', 52),
        line('user', 'stop', 53, '[Request interrupted by user]'),
        line('user', 'p3', 55, 'Then that'),
        said('a4', 58),
      ]) {
        translator.translate(message);
      }
      translator.endReplay();
      Duration? worked(String id) => (transcript.itemAt(
        transcript.indexOf(id)!,
      ) as UserMessageItem).worked;
      expect(worked('p1'), const Duration(seconds: 45));
      // Stopped: to where it was, and said so.
      expect(worked('p2'), const Duration(seconds: 3));
      expect(
        (transcript.itemAt(
          transcript.indexOf('p2')!,
        ) as UserMessageItem).stopped,
        isTrue,
      );
      expect(worked('p3'), const Duration(seconds: 3));
      // When each was sent, as kept: for a chat app's times.
      expect(
        (transcript.itemAt(
          transcript.indexOf('p2')!,
        ) as UserMessageItem).sentAt,
        DateTime.utc(2026, 10, 1, 10, 0, 50).toLocal(),
      );
    });

    test('translating a message twice changes nothing', () {
      final once = Transcript();
      final twice = Transcript();
      var a = 0;
      var b = 0;
      final first = ClaudeTranslator(emit: once.apply, nextSeq: () => ++a);
      final second = ClaudeTranslator(emit: twice.apply, nextSeq: () => ++b);
      for (final message in recorded('question')) {
        first.translate(message);
        if (message['type'] == 'assistant') second.translate(message);
        second.translate(message);
      }
      expect(shown(twice), shown(once));
    });

    test("a Windows path's file shows by its name", () {
      final transcript = Transcript();
      var seq = 0;
      final translator = ClaudeTranslator(
        emit: transcript.apply,
        nextSeq: () => ++seq,
      );
      void call(
        String id,
        String name,
        Map<String, Object?> input, {
        Object? result,
      }) {
        translator.translate({
          'type': 'assistant',
          'parent_tool_use_id': null,
          'message': {
            'id': 'msg-$id',
            'role': 'assistant',
            'content': [
              {'type': 'tool_use', 'id': id, 'name': name, 'input': input},
            ],
          },
        });
        translator.translate({
          'type': 'user',
          'parent_tool_use_id': null,
          'message': {
            'role': 'user',
            'content': [
              {'type': 'tool_result', 'tool_use_id': id, 'content': 'ok'},
            ],
          },
          'tool_use_result': ?result,
        });
      }

      call('r1', 'Read', {'file_path': r'C:\p\lib\a.dart'});
      call('l1', 'LS', {'path': r'C:\p\lib'});
      call(
        'e1',
        'Edit',
        {'file_path': r'C:\p\lib\b.dart', 'old_string': 'x', 'new_string': 'y'},
        result: {
          'filePath': r'C:\p\lib\b.dart',
          'structuredPatch': [
            {
              'oldStart': 1,
              'oldLines': 1,
              'newStart': 1,
              'newLines': 1,
              'lines': ['-x', '+y'],
            },
          ],
        },
      );
      expect(shown(transcript), [
        'tool: read a.dart',
        'tool: listDir lib',
        'diff: b.dart +2',
      ]);
      final diff = transcript.itemAt(2) as CodeDiffItem;
      expect(diff.directory, r'C:\p\lib');
    });

    group('a stream Claude Code gave up on and asked again', () {
      late Transcript transcript;
      late ClaudeTranslator translator;
      setUp(() {
        transcript = Transcript();
        var seq = 0;
        translator = ClaudeTranslator(
          emit: transcript.apply,
          nextSeq: () => ++seq,
        );
      });
      void event(
        Map<String, Object?> event, {
        Map<String, Object?>? abandoned,
      }) => translator.translate({
        'type': 'stream_event',
        'parent_tool_use_id': null,
        'event': event,
        'abandoned_blocks': ?abandoned,
      });
      void streamText(String messageId, int index, String text) {
        event({
          'type': 'content_block_start',
          'index': index,
          'content_block': {'type': 'text', 'text': ''},
        });
        event({
          'type': 'content_block_delta',
          'index': index,
          'delta': {'type': 'text_delta', 'text': text},
        });
        event({'type': 'content_block_stop', 'index': index});
      }

      Map<String, Object?> whole(
        String uuid,
        String messageId,
        List<Map<String, Object?>> content,
      ) => {
        'type': 'assistant',
        'uuid': uuid,
        'parent_tool_use_id': null,
        'message': {'id': messageId, 'role': 'assistant', 'content': content},
      };

      test('what streamed with no whole message goes; the answer asked '
          'again shows once', () {
        event({
          'type': 'message_start',
          'message': {'id': 'msg-1'},
        });
        streamText('msg-1', 0, 'The answer');
        event({
          'type': 'content_block_start',
          'index': 1,
          'content_block': {'type': 'tool_use', 'id': 'call-1', 'name': 'Read'},
        });
        expect(shown(transcript), ['text: The answer', 'tool: read ']);
        event(
          {'type': 'message_stop'},
          abandoned: {'api_message_id': 'msg-1', 'from_block_index': 0},
        );
        expect(shown(transcript), isEmpty);
        // Asked again without streaming: its whole messages, another id.
        translator.translate(
          whole('u-2', 'msg-2', [
            {'type': 'text', 'text': 'The answer'},
          ]),
        );
        expect(shown(transcript), ['text: The answer']);
      });

      test('a block a whole message brought stays', () {
        event({
          'type': 'message_start',
          'message': {'id': 'msg-1'},
        });
        streamText('msg-1', 0, 'Kept');
        translator.translate(
          whole('u-1', 'msg-1', [
            {'type': 'text', 'text': 'Kept'},
          ]),
        );
        streamText('msg-1', 1, 'Cut');
        event(
          {'type': 'message_stop'},
          abandoned: {'api_message_id': 'msg-1', 'from_block_index': 0},
        );
        expect(shown(transcript), ['text: Kept']);
      });

      test('a whole message taken back goes', () {
        event({
          'type': 'message_start',
          'message': {'id': 'msg-1'},
        });
        streamText('msg-1', 0, 'The answer');
        final first = whole('u-1', 'msg-1', [
          {'type': 'text', 'text': 'The answer'},
        ]);
        translator.translate(first);
        expect(shown(transcript), ['text: The answer']);
        translator.translate({
          'type': 'tombstone',
          'message': first,
          'uuid': 'u-t',
          'session_id': 's',
        });
        expect(shown(transcript), isEmpty);
        translator.translate(
          whole('u-2', 'msg-2', [
            {'type': 'text', 'text': 'The answer'},
          ]),
        );
        expect(shown(transcript), ['text: The answer']);
      });

      test('a message_stop of its own takes nothing', () {
        event({
          'type': 'message_start',
          'message': {'id': 'msg-1'},
        });
        streamText('msg-1', 0, 'The answer');
        event({'type': 'message_stop'});
        expect(shown(transcript), ['text: The answer']);
      });
    });
  });

  group('Claude Code kernel', () {
    test(
      'a message that is not whole does not take the session down',
      () async {
        final cli = FakeCli();
        final (:kernel, :transcript, events: _) = claude(cli);
        kernel.send(const KernelTurn(id: 'u1', text: 'hi'));
        await pumpEventQueue();
        // What a CLI or a proxy may send: an event with no index, a block
        // with no id, a task with no id of its own.
        for (final message in [
          {
            'type': 'stream_event',
            'event': {'type': 'content_block_start'},
          },
          {
            'type': 'stream_event',
            'event': {
              'type': 'content_block_start',
              'index': 0,
              'content_block': {'type': 'tool_use'},
            },
          },
          {'type': 'system', 'subtype': 'task_started'},
          {
            'type': 'assistant',
            'message': {
              'role': 'assistant',
              'content': [
                {'type': 'tool_use', 'id': 't1'},
              ],
            },
          },
        ]) {
          cli.push(message);
          await pumpEventQueue();
        }
        // The session is still there, and takes the next turn.
        cli.push({
          'type': 'result',
          'subtype': 'success',
          'is_error': false,
          'duration_ms': 100,
        });
        await pumpEventQueue();
        final message = transcript.itemAt(0) as UserMessageItem;
        expect(message.text, 'hi');
        expect(message.worked, const Duration(milliseconds: 100));
        kernel.dispose();
      },
    );

    test('a turn is timed as the CLI says it took', () async {
      final cli = FakeCli();
      final (:kernel, :transcript, events: _) = claude(cli);
      kernel.send(const KernelTurn(id: 'u1', text: 'hi'));
      await pumpEventQueue();
      cli.push({
        'type': 'result',
        'subtype': 'success',
        'is_error': false,
        'duration_ms': 65400,
      });
      await pumpEventQueue();
      final message = transcript.itemAt(0) as UserMessageItem;
      expect(message.worked, const Duration(milliseconds: 65400));
      expect(message.text, 'hi');
      kernel.dispose();
    });

    test('a turn failed with nothing to say still says why', () async {
      final cli = FakeCli();
      final (:kernel, :transcript, events: _) = claude(cli);
      kernel.send(const KernelTurn(id: 'u1', text: 'hi'));
      await pumpEventQueue();
      // As Claude Code ends a turn whose upstream answered with nothing
      // visible: an error, and no words of its own to show.
      cli.push({
        'type': 'result',
        'subtype': 'error_during_execution',
        'is_error': true,
        'result': '',
      });
      await pumpEventQueue();
      final notices = [
        for (var i = 0; i < transcript.length; i++)
          if (transcript.itemAt(i) case NoticeItem(:final kind, :final text))
            (kind, text),
      ];
      expect(notices, hasLength(1));
      expect(notices.single.$1, NoticeKind.error);
      expect(notices.single.$2, contains('did not reply'));
      expect(transcript.activeTurn, isNull);
      kernel.dispose();
    });



    test(
      'a turn the user stopped is not given an error after the fact',
      () async {
        final cli = FakeCli();
        final (:kernel, :transcript, events: _) = claude(cli);
        kernel.send(const KernelTurn(id: 'u1', text: 'hi'));
        await pumpEventQueue();
        kernel.cancel();
        await pumpEventQueue();
        // The CLI says the turn failed after all, with nothing to show.
        cli.push({
          'type': 'result',
          'subtype': 'error_during_execution',
          'is_error': true,
          'result': '',
        });
        await pumpEventQueue();
        final notices = [
          for (var i = 0; i < transcript.length; i++)
            if (transcript.itemAt(i) is NoticeItem) transcript.itemAt(i),
        ];
        expect(notices, isEmpty);
        kernel.dispose();
      },
    );

    test('a turn ended keeps its id, not its words or images', () async {
      final cli = FakeCli();
      final (:kernel, transcript: _, events: _) = claude(cli);
      kernel.send(
        KernelTurn(
          id: 'u1',
          text: 'hi',
          images: [
            ImageAttachment(
              bytes: Uint8List(64 * 1024),
              mediaType: 'image/png',
            ),
          ],
        ),
      );
      await pumpEventQueue();
      cli.push({'type': 'result', 'subtype': 'success', 'is_error': false});
      await pumpEventQueue();
      expect(kernel.sentTurn('u1')?.text, isEmpty);
      expect(kernel.sentTurn('u1')?.images, isEmpty);
      // Still remembered as sent: the same turn again runs once.
      kernel.send(const KernelTurn(id: 'u1', text: 'again'));
      await pumpEventQueue();
      expect(cli.users, hasLength(1));
      kernel.dispose();
    });

    test('a turn waiting its turn keeps what it is to send', () async {
      final cli = FakeCli();
      final (:kernel, transcript: _, events: _) = claude(cli);
      kernel.send(const KernelTurn(id: 'u1', text: 'first'));
      await pumpEventQueue();
      kernel.send(const KernelTurn(id: 'u2', text: 'second'));
      await pumpEventQueue();
      cli.push({'type': 'result', 'subtype': 'success', 'is_error': false});
      await pumpEventQueue();
      expect(kernel.sentTurn('u1')?.text, isEmpty);
      expect(kernel.sentTurn('u2')?.text, 'second');
      kernel.dispose();
    });


    test('a turn done is kept by its session and prompt, for its footer '
        'later; one stopped too, its work to fold', () async {
      final kept = _KeptTurns();
      ClaudeCodeKernel.turnStats = kept;
      addTearDown(() => ClaudeCodeKernel.turnStats = null);
      final cli = FakeCli();
      final (:kernel, :transcript, events: _) = claude(cli);
      kernel.send(const KernelTurn(id: 'u1', text: 'hi'));
      await pumpEventQueue();
      cli.push({'type': 'system', 'subtype': 'init', 'session_id': 's1'});
      cli.push({
        'type': 'result',
        'subtype': 'success',
        'is_error': false,
        'duration_ms': 65400,
        'total_cost_usd': 0.5,
      });
      await pumpEventQueue();
      final record = kept.sessions['s1']!['u1']!;
      expect(record.worked, const Duration(milliseconds: 65400));
      expect(record.usage?.costUsd, closeTo(0.5, 1e-9));

      kernel.send(const KernelTurn(id: 'u2', text: 'again'));
      await pumpEventQueue();
      kernel.cancel();
      await pumpEventQueue();
      expect(kept.sessions['s1']!.keys, ['u1', 'u2']);
      final stopped =
          transcript.itemAt(transcript.indexOf('u2')!) as UserMessageItem;
      expect(stopped.stopped, isTrue);
      expect(stopped.worked, isNotNull);
      kernel.dispose();
    });

    test(
      "a turn keeps its own tokens and cost, what it wrote shown live",
      () async {
        final cli = FakeCli();
        final (:kernel, :transcript, events: _) = claude(cli);
        kernel.send(const KernelTurn(id: 'u1', text: 'hi'));
        await pumpEventQueue();
        Future<void> stream(Map<String, Object?> event) async {
          cli.push({'type': 'stream_event', 'event': event});
          await pumpEventQueue();
        }

        Future<void> request(int output) async {
          await stream({
            'type': 'message_start',
            'message': {
              'id': 'm$output',
              'usage': {
                'input_tokens': 10,
                'cache_read_input_tokens': 1000,
                'output_tokens': 1,
              },
            },
          });
          await stream({
            'type': 'content_block_start',
            'index': 0,
            'content_block': {'type': 'text', 'text': ''},
          });
          await Future<void>.delayed(const Duration(milliseconds: 20));
          await stream({
            'type': 'content_block_delta',
            'index': 0,
            'delta': {'type': 'text_delta', 'text': 'Hi.'},
          });
          await stream({'type': 'content_block_stop', 'index': 0});
          await stream({
            'type': 'message_delta',
            'usage': {'output_tokens': output},
          });
          await stream({'type': 'message_stop'});
        }

        // The session's cost so far, before and after.
        cli.push({
          'type': 'result',
          'subtype': 'success',
          'total_cost_usd': 1.0,
        });
        await pumpEventQueue();
        kernel.send(const KernelTurn(id: 'u2', text: 'again'));
        await pumpEventQueue();
        // Timed from its start as it goes.
        expect(transcript.turnStartedAt, isNotNull);
        await request(40);
        expect(transcript.output?.tokens, 40);
        await request(60);
        expect(transcript.output?.tokens, 100);
        cli.push({
          'type': 'result',
          'subtype': 'success',
          'total_cost_usd': 1.25,
          'duration_api_ms': 999999,
        });
        await pumpEventQueue();
        final usage = (transcript.itemAt(
          transcript.indexOf('u2')!,
        ) as UserMessageItem).usage!;
        expect(usage.inputTokens, 2020);
        expect(usage.outputTokens, 100);
        expect(usage.costUsd, closeTo(0.25, 1e-9));
        // Its messages too short to time.
        expect(usage.tokensPerSecond, isNull);
        expect(transcript.output, isNull);
        expect(transcript.turnStartedAt, isNull);
        kernel.dispose();
      },
    );

    test(
      "a model's usage given as strings reads without a broken session",
      () async {
        final cli = FakeCli();
        final (:kernel, :transcript, events: _) = claude(cli);
        kernel.send(const KernelTurn(id: 'u1', text: 'hi'));
        await pumpEventQueue();
        Future<void> stream(Map<String, Object?> event) async {
          cli.push({'type': 'stream_event', 'event': event});
          await pumpEventQueue();
        }

        await stream({
          'type': 'message_start',
          'message': {
            'id': 'm1',
            'usage': {
              'input_tokens': '10',
              'cache_creation_input_tokens': '300',
              'cache_read_input_tokens': '1000',
              'output_tokens': 'n/a',
            },
          },
        });
        await stream({
          'type': 'content_block_start',
          'index': '0',
          'content_block': {'type': 'text', 'text': ''},
        });
        await stream({
          'type': 'content_block_delta',
          'index': '0',
          'delta': {'type': 'text_delta', 'text': 'Hi.'},
        });
        await stream({'type': 'content_block_stop', 'index': '0'});
        await stream({
          'type': 'message_delta',
          'usage': {'output_tokens': '40'},
        });
        await stream({'type': 'message_stop'});
        expect(transcript.output?.tokens, 40);

        cli.push({
          'type': 'result',
          'subtype': 'success',
          'duration_ms': '100',
          'usage': {'input_tokens': '10', 'output_tokens': '40'},
        });
        await pumpEventQueue();
        final message =
            transcript.itemAt(transcript.indexOf('u1')!) as UserMessageItem;
        expect(message.worked, const Duration(milliseconds: 100));
        expect(message.usage?.inputTokens, 1310);
        expect(message.usage?.outputTokens, 40);
        expect([
          for (final (_, item) in transcript.liveItems)
            if (item is NoticeItem && item.kind == NoticeKind.error) item,
        ], isEmpty);
        kernel.dispose();
      },
    );

    test('starts on first send, then writes the message', () async {
      final cli = FakeCli();
      final (:kernel, :transcript, events: _) = claude(cli);
      expect(kernel.health.status, KernelHealthStatus.idle);
      kernel.send(const KernelTurn(id: 'u1', text: 'hi'));
      expect(transcript.activeTurn, 'u1');
      expect(shown(transcript), ['user: hi']);
      await pumpEventQueue();
      expect(kernel.health.status, KernelHealthStatus.ready);
      expect(cli.requests('initialize'), hasLength(1));
      expect(cli.users.single['uuid'], 'u1');
      // Offers what the CLI said it has.
      expect(kernel.model.options.map((m) => m.label), contains('Sonnet'));
      expect(kernel.commands.map((c) => c.name), contains('compact'));
      expect(
        kernel.commands.map((c) => c.name),
        isNot(contains('doctor')),
        reason: 'terminal-only commands are left out',
      );
      kernel.dispose();
    });

    test(
      'an exit mid-turn takes the turn up again on a resumed process',
      () async {
        final clis = [FakeCli(), FakeCli()];
        var next = 0;
        final kernel = ClaudeCodeKernel(
          MockKernels.claudeCode,
          const KernelContext(cwd: '/p'),
          start: (_) async => clis[next++],
        );
        final transcript = Transcript();
        kernel.events.listen(transcript.apply);
        kernel.send(const KernelTurn(id: 'u1', text: 'hi'));
        await pumpEventQueue();
        // The CLI says the session it runs, as `init` does.
        clis[0].push({'type': 'system', 'subtype': 'init', 'session_id': 's1'});
        await pumpEventQueue();
        expect(transcript.activeTurn, 'u1');

        // The process dies with the turn under way: a fluke, not a setup
        // that cannot work — the turn says so, and goes again.
        clis[0].push(ClaudeExit.message(1, 'socket hang up'));
        await pumpEventQueue();
        final notices = [
          for (var i = 0; i < transcript.length; i++)
            if (transcript.itemAt(i) case NoticeItem(:final kind, :final text))
              (kind, text),
        ];
        expect(notices.single.$1, NoticeKind.retry);
        expect(notices.single.$2, contains('taken up again'));
        // The turn is not over: only its process died. It stays open, and
        // the transcript keeps streaming as if the stop never came.
        expect(transcript.activeTurn, 'u1');

        // The second process is started, resumed over the same session, and
        // takes the message again whole.
        await pumpEventQueue();
        expect(clis[1].users.single['uuid'], 'u1');
        // And answers, ending the turn as any process would.
        clis[1].push({
          'type': 'result',
          'subtype': 'success',
          'is_error': false,
          'duration_ms': 5,
        });
        await pumpEventQueue();
        expect(transcript.activeTurn, isNull);
        kernel.dispose();
      },
    );

    test('the resumed process is started over the kept session', () async {
      final clis = [FakeCli(), FakeCli()];
      final launches = <ClaudeLaunch>[];
      ClaudeLaunch? seen;
      final kernel = ClaudeCodeKernel(
        MockKernels.claudeCode,
        const KernelContext(cwd: '/p'),
        start: (launch) async {
          seen = launch;
          launches.add(launch);
          return clis[launches.length - 1];
        },
      );
      final transcript = Transcript();
      kernel.events.listen(transcript.apply);
      kernel.send(const KernelTurn(id: 'u1', text: 'hi'));
      await pumpEventQueue();
      clis[0].push({'type': 'system', 'subtype': 'init', 'session_id': 's1'});
      await pumpEventQueue();
      clis[0].push(ClaudeExit.message(1, 'socket hang up'));
      await pumpEventQueue();
      await pumpEventQueue();
      expect(launches, hasLength(2));
      expect(launches.first.resume, isNull);
      expect(launches.last.resume, 's1');
      expect(seen, isNotNull);
      kernel.dispose();
    });

    test('a process that dies again mid the retry is failed plainly', () async {
      final clis = [FakeCli(), FakeCli(), FakeCli()];
      var next = 0;
      final kernel = ClaudeCodeKernel(
        MockKernels.claudeCode,
        const KernelContext(cwd: '/p'),
        start: (_) async => clis[next++],
      );
      final transcript = Transcript();
      kernel.events.listen(transcript.apply);
      kernel.send(const KernelTurn(id: 'u1', text: 'hi'));
      await pumpEventQueue();
      clis[0].push({'type': 'system', 'subtype': 'init', 'session_id': 's1'});
      await pumpEventQueue();

      clis[0].push(ClaudeExit.message(1, 'socket hang up'));
      await pumpEventQueue();
      await pumpEventQueue();
      // The retry ran; it dies too. No second chance: the turn ends
      // stopped with the plain word, and the health says failed.
      clis[1].push({'type': 'system', 'subtype': 'init', 'session_id': 's1'});
      await pumpEventQueue();
      clis[1].push(ClaudeExit.message(1, 'socket hang up'));
      await pumpEventQueue();
      final kinds = [
        for (var i = 0; i < transcript.length; i++)
          if (transcript.itemAt(i) case NoticeItem(:final kind)) kind,
      ];
      expect(kinds, [NoticeKind.retry, NoticeKind.error]);
      expect(kernel.health.status, KernelHealthStatus.failed);
      expect(next, 2); // a third process was never started
      kernel.dispose();
    });

    test('a turn that ended whole spends no retry: the next dies once, '
        'is taken up once', () async {
      final clis = [FakeCli(), FakeCli(), FakeCli()];
      var next = 0;
      final kernel = ClaudeCodeKernel(
        MockKernels.claudeCode,
        const KernelContext(cwd: '/p'),
        start: (_) async => clis[next++],
      );
      final transcript = Transcript();
      kernel.events.listen(transcript.apply);
      kernel.send(const KernelTurn(id: 'u1', text: 'first'));
      await pumpEventQueue();
      clis[0].push({'type': 'system', 'subtype': 'init', 'session_id': 's1'});
      await pumpEventQueue();
      clis[0].push({
        'type': 'result',
        'subtype': 'success',
        'is_error': false,
        'duration_ms': 10,
      });
      await pumpEventQueue();
      expect(transcript.activeTurn, isNull);

      // A second turn on the same process; its mid-turn exit is the
      // process's first death, so it is taken up again.
      kernel.send(const KernelTurn(id: 'u2', text: 'second'));
      await pumpEventQueue();
      clis[0].push(ClaudeExit.message(1, 'socket hang up'));
      await pumpEventQueue();
      await pumpEventQueue();
      expect(transcript.activeTurn, 'u2');
      expect(clis[1].users.single['uuid'], 'u2');
      kernel.dispose();
    });

    test('an exit that says not logged in is failed, not retried', () async {
      final clis = [FakeCli(), FakeCli()];
      var next = 0;
      final kernel = ClaudeCodeKernel(
        MockKernels.claudeCode,
        const KernelContext(cwd: '/p'),
        start: (_) async => clis[next++],
      );
      final transcript = Transcript();
      kernel.events.listen(transcript.apply);
      kernel.send(const KernelTurn(id: 'u1', text: 'hi'));
      await pumpEventQueue();
      clis[0].push({'type': 'system', 'subtype': 'init', 'session_id': 's1'});
      await pumpEventQueue();
      clis[0].push(ClaudeExit.message(1, 'Please login again'));
      await pumpEventQueue();
      final kinds = [
        for (var i = 0; i < transcript.length; i++)
          if (transcript.itemAt(i) case NoticeItem(:final kind)) kind,
      ];
      expect(kinds, [NoticeKind.error]);
      expect(transcript.activeTurn, isNull);
      expect(kernel.health.status, KernelHealthStatus.failed);
      kernel.dispose();
    });

    test(
      'a result come late for a stopped turn does not end the next',
      () async {
        final cli = FakeCli();
        final (:kernel, :transcript, events: _) = claude(cli);
        kernel.send(const KernelTurn(id: 'u1', text: 'first'));
        await pumpEventQueue();
        cli.push({'type': 'system', 'subtype': 'init', 'session_id': 's1'});
        await pumpEventQueue();
        kernel.cancel();
        await pumpEventQueue();
        expect(transcript.activeTurn, isNull);

        kernel.send(const KernelTurn(id: 'u2', text: 'second'));
        await pumpEventQueue();
        expect(transcript.activeTurn, 'u2');
        // The CLI's last word for u1, which it had not finished answering:
        // it comes after u2 began, and must not end it.
        cli.push({
          'type': 'result',
          'subtype': 'error_during_execution',
          'is_error': false,
          'duration_ms': 240000,
        });
        await pumpEventQueue();
        expect(transcript.activeTurn, 'u2');
        kernel.dispose();
      },
    );

    test('an exit whose stderr only says a proxy wants its own login is '
        'taken up again', () async {
      final clis = [FakeCli(), FakeCli()];
      var next = 0;
      final kernel = ClaudeCodeKernel(
        MockKernels.claudeCode,
        const KernelContext(cwd: '/p'),
        start: (_) async => clis[next++],
      );
      final transcript = Transcript();
      kernel.events.listen(transcript.apply);
      kernel.send(const KernelTurn(id: 'u1', text: 'hi'));
      await pumpEventQueue();
      clis[0].push({'type': 'system', 'subtype': 'init', 'session_id': 's1'});
      await pumpEventQueue();
      // A proxy's challenge, not the account being out: the process is
      // started again over the session, as any fluke is.
      clis[0].push(ClaudeExit.message(1, 'Proxy Authentication Required'));
      await pumpEventQueue();
      await pumpEventQueue();
      expect(transcript.activeTurn, 'u1');
      expect(clis[1].users.single['uuid'], 'u1');
      kernel.dispose();
    });

    test(
      'a started for a turn already over does not end the one running',
      () async {
        final cli = FakeCli();
        final (:kernel, :transcript, events: _) = claude(cli);
        kernel.send(const KernelTurn(id: 'u1', text: 'first'));
        await pumpEventQueue();
        cli.push({'type': 'system', 'subtype': 'init', 'session_id': 's1'});
        await pumpEventQueue();
        cli.push({
          'type': 'result',
          'subtype': 'success',
          'is_error': false,
          'duration_ms': 10,
        });
        await pumpEventQueue();
        expect(transcript.activeTurn, isNull);

        kernel.send(const KernelTurn(id: 'u2', text: 'second'));
        await pumpEventQueue();
        expect(transcript.activeTurn, 'u2');
        // u1's word that it started, long after it ended: not a turn taken
        // up now, and none to end u2 over.
        cli.push({
          'type': 'command_lifecycle',
          'command_uuid': 'u1',
          'state': 'started',
        });
        await pumpEventQueue();
        expect(transcript.activeTurn, 'u2');
        kernel.dispose();
      },
    );

    test('a question comes as can_use_tool and is answered in kind', () async {
      final cli = FakeCli();
      final (:kernel, :transcript, events: _) = claude(cli);
      kernel.send(const KernelTurn(id: 'u1', text: 'red or blue?'));
      await pumpEventQueue();
      cli.push(
        recorded('question').firstWhere((m) => m['type'] == 'control_request'),
      );
      await pumpEventQueue();
      final request = transcript.pendingInteraction as QuestionRequest;
      final question = request.questions.single;
      expect(question.header, 'Color');
      expect(question.options.map((o) => o.label), ['Red', 'Blue']);
      expect(question.allowOther, isTrue);

      kernel
        ..answer(
          request.id,
          const QuestionAnswer([
            ['Blue'],
          ]),
        )
        ..answer(
          request.id,
          const QuestionAnswer([
            ['Red'],
          ]),
        );
      expect(transcript.pendingInteraction, isNull);
      final response = cli.responses.single;
      expect(response['behavior'], 'allow');
      expect((response['updatedInput'] as Map)['answers'], {
        'Do you prefer red or blue?': 'Blue',
      });
      kernel.dispose();
    });

    test("one of the app's tools asks the user itself: on the "
        "conversation, answered to it; the CLI's leave not asked for it", () async {
      ClaudeSdkTools.register(
        ClaudeSdkTool(
          name: 'ask_me',
          description: 'Asks.',
          inputSchema: const {'type': 'object'},
          asksItself: true,
          run: (input, call) async =>
              '${await call.ask!(const ApprovalRequest(id: '', title: 'Run it here?', toolName: 'mcp__baocode__ask_me', alwaysAllowLabel: 'Always for this host'))}',
        ),
      );
      addTearDown(() => ClaudeSdkTools.unregister('ask_me'));
      final cli = FakeCli();
      final (:kernel, :transcript, events: _) = claude(cli);
      kernel.send(const KernelTurn(id: 'u1', text: 'go'));
      await pumpEventQueue();
      cli.push({
        'type': 'control_request',
        'request_id': 'p1',
        'request': {
          'subtype': 'can_use_tool',
          'tool_name': 'mcp__baocode__ask_me',
          'input': <String, Object?>{},
        },
      });
      await pumpEventQueue();
      expect(cli.responses.last, {
        'behavior': 'allow',
        'updatedInput': <String, Object?>{},
      });
      expect(transcript.pendingInteraction, isNull);

      cli.push({
        'type': 'control_request',
        'request_id': 'm1',
        'request': {
          'subtype': 'mcp_message',
          'server_name': 'baocode',
          'message': {
            'jsonrpc': '2.0',
            'id': 5,
            'method': 'tools/call',
            'params': {'name': 'ask_me', 'arguments': <String, Object?>{}},
          },
        },
      });
      await pumpEventQueue();
      final request = transcript.pendingInteraction as ApprovalRequest;
      expect(request.title, 'Run it here?');
      expect(request.alwaysAllowLabel, 'Always for this host');
      kernel.answer(
        request.id,
        const ApprovalAnswer(ApprovalDecision.allowAlways),
      );
      await pumpEventQueue();
      expect(transcript.pendingInteraction, isNull);
      final mcp = cli.responses.last['mcp_response']! as Map;
      expect(((mcp['result'] as Map)['content'] as List).single, {
        'type': 'text',
        'text': 'ApprovalDecision.allowAlways',
      });
      kernel.dispose();
    });

    test('a tool asks leave; always allowing sends its rules', () async {
      final cli = FakeCli();
      final (:kernel, :transcript, events: _) = claude(cli);
      kernel.send(const KernelTurn(id: 'u1', text: 'write it'));
      await pumpEventQueue();
      cli.push(
        recorded('permission')
            .firstWhere((m) => m['type'] == 'control_request'),
      );
      await pumpEventQueue();
      final request = transcript.pendingInteraction as ApprovalRequest;
      expect(request.title, 'Write hello.txt?');
      expect(request.alwaysAllowLabel, 'Accept edits for this session');
      final preview = request.preview as DiffPreview;
      expect(preview.lines.single.text, 'hi');

      kernel.answer(
        request.id,
        const ApprovalAnswer(ApprovalDecision.allowAlways),
      );
      expect(cli.responses.single, {
        'behavior': 'allow',
        'updatedInput': {
          'file_path': '/tmp/project/hello.txt',
          'content': 'hi',
        },
        'updatedPermissions': [
          {'type': 'setMode', 'mode': 'acceptEdits', 'destination': 'session'},
        ],
      });
      kernel.dispose();
    });

    test(
      'a turn the CLI takes up while another runs does not orphan it',
      () async {
        final cli = FakeCli();
        final (:kernel, :transcript, :events) = claude(cli);
        kernel.send(const KernelTurn(id: 'u1', text: 'first'));
        await pumpEventQueue();
        // A second message, queued: the CLI takes it up while the first is
        // still running.
        kernel.send(const KernelTurn(id: 'u2', text: 'second'));
        await pumpEventQueue();
        cli.push({
          'type': 'command_lifecycle',
          'command_uuid': 'u2',
          'state': 'started',
        });
        await pumpEventQueue();
        // The first turn is ended, not left running under the second.
        final ended = events.whereType<TurnEnded>().map(
          (event) => event.turnId,
        );
        expect(ended, contains('u1'));
        // And the second is the one running.
        final started = events.whereType<TurnStarted>().map(
          (event) => event.turnId,
        );
        expect(started.where((id) => id == 'u2'), hasLength(1));
        kernel.dispose();
      },
    );

    test(
      'denying says why; a plan is put to the user, who starts it',
      () async {
        final cli = FakeCli();
        final (:kernel, :transcript, events: _) = claude(cli);
        kernel.send(const KernelTurn(id: 'u1', text: 'go'));
        await pumpEventQueue();
        void ask(String id, String tool, Map<String, Object?> input) =>
            cli.push({
              'type': 'control_request',
              'request_id': id,
              'request': {
                'subtype': 'can_use_tool',
                'tool_name': tool,
                'input': input,
              },
            });

        ask('r1', 'Bash', {'command': 'rm -rf build', 'description': 'Clean'});
        await pumpEventQueue();
        final bash = transcript.pendingInteraction as ApprovalRequest;
        expect((bash.preview as CommandPreview).command, 'rm -rf build');
        expect(bash.alwaysAllowLabel, isNull);
        kernel.answer(
          'r1',
          const ApprovalAnswer(
            ApprovalDecision.deny,
            message: 'Keep the build',
          ),
        );
        expect(cli.responses.last, {
          'behavior': 'deny',
          'message': 'Keep the build',
        });

        // A plan is put to the user at once, and the turn left to end: the
        // user starts it later, with the approvals picked.
        kernel.mode.select('plan');
        kernel.permission.select('acceptEdits');
        const planFile = '/home/me/.claude/plans/small-steps.md';
        void said(String id, String name, Map<String, Object?> input) =>
            cli.push({
              'type': 'assistant',
              'parent_tool_use_id': null,
              'message': {
                'id': 'msg-$id',
                'role': 'assistant',
                'content': [
                  {'type': 'tool_use', 'id': id, 'name': name, 'input': input},
                ],
              },
            });
        void result(String id, String content, {bool error = false}) =>
            cli.push({
              'type': 'user',
              'parent_tool_use_id': null,
              'message': {
                'role': 'user',
                'content': [
                  {
                    'type': 'tool_result',
                    'tool_use_id': id,
                    'content': content,
                    'is_error': error,
                  },
                ],
              },
            });
        said('w1', 'Write', {'file_path': planFile, 'content': '1. Small'});
        result('w1', 'ok');
        said('x1', 'ExitPlanMode', {'plan': '1. Small'});
        ask('r2', 'ExitPlanMode', {'plan': '1. Small'});
        await pumpEventQueue();
        expect(transcript.pendingInteraction, isNull);
        expect(cli.responses.last, {
          'behavior': 'deny',
          'message': ClaudeTranslator.planPresented,
        });
        result('x1', ClaudeTranslator.planPresented, error: true);
        await pumpEventQueue();
        expect(transcript.plan?.path, planFile);
        expect(
          transcript.liveItems
              .map((entry) => entry.$2)
              .whereType<PlanItem>()
              .map((plan) => plan.status),
          [PlanStatus.awaiting],
        );
        // Still planning until the user starts it.
        expect(kernel.mode.selected, 'plan');

        kernel.startBuilding();
        expect(kernel.mode.selected, 'agent');
        expect(kernel.permission.selected, 'acceptEdits');
        expect(cli.requests('set_permission_mode').last['mode'], 'acceptEdits');
        kernel.send(const KernelTurn(id: 'u2', text: 'Carry out the plan'));
        await pumpEventQueue();
        final content = (cli.users.last['message'] as Map)['content'] as List;
        expect(content, [
          {'type': 'text', 'text': ClaudeTranslator.planStartedNote(planFile)},
          {'type': 'text', 'text': 'Carry out the plan'},
        ]);
        // Only the message that starts it says so.
        kernel.send(const KernelTurn(id: 'u3', text: 'And test it'));
        cli.push({
          'type': 'command_lifecycle',
          'command_uuid': 'u2',
          'state': 'started',
        });
        await pumpEventQueue();
        expect((cli.users.last['message'] as Map)['content'], [
          {'type': 'text', 'text': 'And test it'},
        ]);
        kernel.dispose();
      },
    );

    test('a plan sent rather than written, in plan mode the model entered '
        'from Agent, is put to the user all the same', () async {
      // As the CLI tells it: the plan in the call alone, no file named,
      // and asked about with no input.
      final cli = FakeCli();
      final (:kernel, :transcript, events: _) = claude(cli);
      kernel.permission.select('bypassPermissions');
      kernel.send(const KernelTurn(id: 'u1', text: 'go'));
      await pumpEventQueue();
      void said(String id, String name, Map<String, Object?> input) =>
          cli.push({
            'type': 'assistant',
            'parent_tool_use_id': null,
            'message': {
              'id': 'msg-$id',
              'role': 'assistant',
              'content': [
                {'type': 'tool_use', 'id': id, 'name': name, 'input': input},
              ],
            },
          });
      said('e1', 'EnterPlanMode', {});
      cli.push({
        'type': 'system',
        'subtype': 'status',
        'status': null,
        'permissionMode': 'plan',
      });
      said('x1', 'ExitPlanMode', {'plan': '# Hello\n\n1. Add hello.txt'});
      cli.push({
        'type': 'control_request',
        'request_id': 'r1',
        'request': {
          'subtype': 'can_use_tool',
          'tool_name': 'ExitPlanMode',
          'input': <String, Object?>{},
          'requires_user_interaction': true,
        },
      });
      await pumpEventQueue();
      expect(cli.responses.last['message'], ClaudeTranslator.planPresented);
      final plan = transcript.liveItems
          .map((entry) => entry.$2)
          .whereType<PlanItem>()
          .single;
      expect(plan.status, PlanStatus.awaiting);
      expect(plan.title, 'Hello');
      expect(plan.path, isEmpty);
      expect(kernel.mode.selected, 'plan');

      kernel.startBuilding();
      expect(kernel.mode.selected, 'agent');
      kernel.send(const KernelTurn(id: 'u2', text: 'Carry out the plan'));
      await pumpEventQueue();
      final content = (cli.users.last['message'] as Map)['content'] as List;
      expect(
        (content.first as Map)['text'],
        ClaudeTranslator.planStartedNote(''),
      );
      expect(
        ClaudeTranslator.planStartedNote(''),
        contains('Carry out the plan you put to them now.'),
      );
      kernel.dispose();
    });

    test('full access with no one to ask approves what the CLI would ask '
        'all the same', () async {
      final cli = FakeCli();
      final (:kernel, :transcript, events: _) = claude(
        cli,
        context: KernelContext(
          cwd: '/p',
          settings: const {'permission': 'bypassPermissions'},
          workspace: () =>
              const KernelWorkspace(folders: [], approvesAll: true),
        ),
      );
      kernel.send(const KernelTurn(id: 'u1', text: 'go'));
      await pumpEventQueue();
      const command = {'command': 'rm -rf build', 'description': 'Clean'};
      for (final (i, why) in const [
        {'decision_reason_type': 'safetyCheck'},
        {'decision_reason_type': 'safetyCheck', 'classifier_approvable': false},
        {
          'decision_reason_type': 'rule',
          'matched_ask_rule': {'toolName': 'Bash'},
        },
        {'decision_reason_code': 'outside_reads_blocked'},
      ].indexed) {
        cli.push({
          'type': 'control_request',
          'request_id': 'r$i',
          'request': {
            'subtype': 'can_use_tool',
            'tool_name': 'Bash',
            'input': command,
            ...why,
          },
        });
        await pumpEventQueue();
        expect(transcript.pendingInteraction, isNull);
        expect(cli.responses.last, {
          'behavior': 'allow',
          'updatedInput': command,
        });
      }
      // A question no one would answer: asked in its words instead.
      cli.push({
        'type': 'control_request',
        'request_id': 'q',
        'request': {
          'subtype': 'can_use_tool',
          'tool_name': 'AskUserQuestion',
          'input': {
            'questions': [
              {
                'question': 'Which language?',
                'header': 'Language',
                'options': [
                  {'label': 'English'},
                  {'label': 'Chinese'},
                ],
              },
            ],
          },
        },
      });
      await pumpEventQueue();
      expect(transcript.pendingInteraction, isNull);
      expect(cli.responses.last['behavior'], 'deny');
      expect(
        cli.responses.last['message'],
        contains('Ask them in your reply instead'),
      );
      kernel.dispose();
    });

    test('full access answers questions itself; Don\'t ask refuses what '
        'it would ask', () async {
      final cli = FakeCli();
      final (:kernel, :transcript, events: _) = claude(cli);
      kernel.send(const KernelTurn(id: 'u1', text: 'go'));
      await pumpEventQueue();
      void ask(
        String id,
        String tool,
        Map<String, Object?> input, [
        Map<String, Object?> why = const {},
      ]) => cli.push({
        'type': 'control_request',
        'request_id': id,
        'request': {
          'subtype': 'can_use_tool',
          'tool_name': tool,
          'input': input,
          ...why,
        },
      });
      const question = {
        'questions': [
          {
            'question': 'Red or blue?',
            'header': 'Color',
            'options': [
              {'label': 'Red'},
              {'label': 'Blue'},
            ],
          },
        ],
      };
      const command = {'command': 'npm test', 'description': 'Test'};

      // Full access approves what it does, not what it asks: a question is
      // the user's in any mode.
      kernel.permission.select('bypassPermissions');
      for (final mode in ['agent', 'plan', 'ask']) {
        kernel.mode.select(mode);
        ask('r1-$mode', 'AskUserQuestion', question);
        await pumpEventQueue();
        expect(transcript.pendingInteraction, isA<QuestionRequest>());
        kernel.answer('r1-$mode', const QuestionAnswer([], skipped: true));
      }
      kernel.mode.select('agent');
      // Approved here, the CLI only accepting edits.
      expect(cli.requests('set_permission_mode').last['mode'], 'acceptEdits');
      ask('r2', 'Bash', command, {'decision_reason_type': 'mode'});
      await pumpEventQueue();
      expect(transcript.pendingInteraction, isNull);
      expect(cli.responses.last['behavior'], 'allow');
      expect(cli.responses.last['updatedInput'], command);
      // Protected paths may be classifier-approved in Accept edits; full
      // access allows them without prompting, including inside compound Bash.
      const protectedCommand = {
        'command': "sed -E 's/token/***/g' ~/.claude/settings.local.json",
        'description': 'Inspect local settings',
      };
      for (final (i, why) in const [
        {
          'decision_reason_type': 'safetyCheck',
          'classifier_approvable': true,
          'decision_reason':
              'Claude requested permissions to write to '
              '~/.claude/settings.local.json, but you haven\'t granted it yet.',
        },
        {
          'decision_reason_type': 'subcommandResults',
          'classifier_approvable': true,
        },
      ].indexed) {
        ask('r2-protected-$i', 'Bash', protectedCommand, why);
        await pumpEventQueue();
        expect(transcript.pendingInteraction, isNull);
        expect(cli.responses.last, {
          'behavior': 'allow',
          'updatedInput': protectedCommand,
        });
      }
      // Manual-only safety checks, explicit ask rules and the plan remain
      // the user's decisions, even when a protected-path check is approvable.
      for (final (i, why) in const [
        {'decision_reason_type': 'safetyCheck'},
        {'decision_reason_type': 'safetyCheck', 'classifier_approvable': false},
        {
          'decision_reason_type': 'subcommandResults',
          'classifier_approvable': false,
        },
        {
          'decision_reason_type': 'rule',
          'matched_ask_rule': {'toolName': 'Bash'},
        },
        {
          'decision_reason_type': 'safetyCheck',
          'classifier_approvable': true,
          'matched_ask_rule': {'toolName': 'Bash'},
        },
        {'requires_user_interaction': true},
        {'decision_reason_code': 'outside_reads_blocked'},
      ].indexed) {
        ask('r2-$i', 'Bash', command, why);
        await pumpEventQueue();
        expect(transcript.pendingInteraction, isA<ApprovalRequest>());
        kernel.answer(
          'r2-$i',
          const ApprovalAnswer(ApprovalDecision.allowOnce),
        );
      }
      // The plan is put to the user, not asked about.
      ask('r3', 'ExitPlanMode', {'plan': '1. Do it'});
      await pumpEventQueue();
      expect(transcript.pendingInteraction, isNull);
      expect(cli.responses.last, {
        'behavior': 'deny',
        'message': ClaudeTranslator.planPresented,
      });

      // Don't ask: what it would ask about is refused; questions are
      // asked.
      kernel.permission.select('dontAsk');
      final answered = cli.responses.length;
      ask('r4', 'Bash', command);
      await pumpEventQueue();
      expect(transcript.pendingInteraction, isNull);
      expect(cli.responses, hasLength(answered + 1));
      expect(cli.responses.last['behavior'], 'deny');
      ask('r5', 'AskUserQuestion', question);
      await pumpEventQueue();
      expect(transcript.pendingInteraction, isA<QuestionRequest>());
      kernel.answer('r5', const QuestionAnswer([], skipped: true));
      ask('r6', 'ExitPlanMode', {'plan': '1. Do it'});
      await pumpEventQueue();
      expect(transcript.pendingInteraction, isNull);
      expect(cli.responses.last['message'], ClaudeTranslator.planPresented);
      kernel.dispose();
    });

    test('an MCP server\'s request for input is asked, in any mode', () async {
      final cli = FakeCli();
      final opened = <String>[];
      final kernel = ClaudeCodeKernel(
        MockKernels.claudeCode,
        const KernelContext(cwd: '/p'),
        start: (_) async => cli,
        openLink: (url) async {
          opened.add(url);
          return true;
        },
      );
      final transcript = Transcript();
      kernel.events.listen(transcript.apply);
      kernel.send(const KernelTurn(id: 'u1', text: 'go'));
      await pumpEventQueue();
      void elicit(String id, Map<String, Object?> request) => cli.push({
        'type': 'control_request',
        'request_id': id,
        'request': {
          'subtype': 'elicitation',
          'mcp_server_name': 'github',
          ...request,
        },
      });

      for (final approval in ['bypassPermissions', 'dontAsk']) {
        kernel.permission.select(approval);
        elicit('e-$approval', {
          'message': 'Pick a repository',
          'requested_schema': {
            'type': 'object',
            'properties': {
              'repo': {
                'type': 'string',
                'title': 'Repository',
                'enum': ['a/one', 'b/two'],
              },
              'private': {'type': 'boolean', 'title': 'Private'},
              'count': {'type': 'integer', 'title': 'How many'},
            },
            'required': ['repo', 'count'],
          },
        });
        await pumpEventQueue();
        final asked = transcript.pendingInteraction! as QuestionRequest;
        expect(asked.title, 'github asks for input');
        expect(asked.questions.first.prompt, startsWith('Pick a repository'));
        expect(asked.questions.first.options.map((o) => o.label), [
          'a/one',
          'b/two',
        ]);
        expect(asked.questions[1].options.map((o) => o.label), [
          'Yes',
          'No',
          'Leave blank',
        ]);
        expect(asked.questions[2].allowOther, isTrue);
        kernel.answer(
          'e-$approval',
          const QuestionAnswer([
            ['b/two'],
            ['Leave blank'],
            ['3'],
          ]),
        );
        expect(transcript.pendingInteraction, isNull);
        expect(cli.responses.last, {
          'action': 'accept',
          'content': {'repo': 'b/two', 'count': 3},
        });
      }

      // Dismissed: cancelled.
      elicit('e2', {
        'message': 'Name?',
        'requested_schema': {
          'type': 'object',
          'properties': {
            'name': {'type': 'string'},
          },
        },
      });
      await pumpEventQueue();
      kernel.answer('e2', const QuestionAnswer([], skipped: true));
      expect(cli.responses.last, {'action': 'cancel'});

      // A link to visit: opened when allowed.
      elicit('e3', {
        'mode': 'url',
        'message': 'Authorize GitHub',
        'url': 'https://github.com/login/oauth?x=1',
        'elicitation_id': 'el-1',
      });
      await pumpEventQueue();
      final link = transcript.pendingInteraction! as ApprovalRequest;
      expect(link.title, 'github wants you to open a link');
      expect(link.reason, 'Authorize GitHub');
      expect(
        (link.preview! as TextPreview).text,
        'https://github.com/login/oauth?x=1',
      );
      kernel.answer('e3', const ApprovalAnswer(ApprovalDecision.allowOnce));
      expect(cli.responses.last, {'action': 'accept'});
      expect(opened, ['https://github.com/login/oauth?x=1']);
      elicit('e4', {'mode': 'url', 'message': 'Again', 'url': 'https://x'});
      await pumpEventQueue();
      kernel.answer('e4', const ApprovalAnswer(ApprovalDecision.deny));
      expect(cli.responses.last, {'action': 'decline'});
      expect(opened, hasLength(1));

      // Withdrawn by the CLI: no longer shown.
      elicit('e5', {'message': 'Sure?'});
      await pumpEventQueue();
      expect(transcript.pendingInteraction, isA<QuestionRequest>());
      cli.push({'type': 'control_cancel_request', 'request_id': 'e5'});
      await pumpEventQueue();
      expect(transcript.pendingInteraction, isNull);
      kernel.dispose();
    });

    test('skills, MCP servers and tools switched off: given at start, and '
        'again whole as they change', () async {
      final changes = ChangeNotifier();
      var switches = const ExtensionSwitches(
        disabledSkills: {'review'},
        disabledServers: {'my.server'},
      );
      ExtensionSwitches.current = () => switches;
      ExtensionSwitches.changes = changes;
      addTearDown(() {
        ExtensionSwitches.current = () => ExtensionSwitches.none;
        ExtensionSwitches.changes = null;
      });
      final cli = FakeCli();
      final launches = <ClaudeLaunch>[];
      final kernel = ClaudeCodeKernel(
        MockKernels.claudeCode,
        const KernelContext(cwd: '/p'),
        start: (launch) async {
          launches.add(launch);
          return cli;
        },
      );
      kernel.prepare();
      await pumpEventQueue();
      final started = launches.single.settings;
      final allow = (started['permissions'] as Map)['allow'];
      expect((started['permissions'] as Map)['deny'], ['mcp__my_server']);
      expect(started['skillOverrides'], {'review': 'off'});
      expect(cli.requests('apply_flag_settings'), isEmpty);

      // One back on, a tool off: all of it sent (the rules it started with
      // kept), what is on now left out.
      switches = switches
          .withSkills(['review'], true)
          .withServer('my.server', true)
          .withTool('git', 'push', false);
      changes.notifyListeners();
      await pumpEventQueue();
      expect(cli.requests('apply_flag_settings').single['settings'], {
        'permissions': {
          'allow': allow,
          'deny': ['mcp__git__push'],
        },
        'skillOverrides': <String, String>{},
      });
      // The same again: nothing sent.
      changes.notifyListeners();
      await pumpEventQueue();
      expect(cli.requests('apply_flag_settings'), hasLength(1));
      kernel.dispose();
      changes.dispose();
    });

    test('Plan\'s commands are left to the classifier with the approvals '
        'that approve for the user', () async {
      final cli = FakeCli();
      final launches = <ClaudeLaunch>[];
      final kernel = ClaudeCodeKernel(
        MockKernels.claudeCode,
        const KernelContext(cwd: '/p', settings: {'permission': 'auto'}),
        start: (launch) async {
          launches.add(launch);
          return cli;
        },
      );
      List<Object?> sent() => [
        for (final request in cli.requests('apply_flag_settings'))
          (request['settings'] as Map)['useAutoModeDuringPlan'],
      ];
      kernel.prepare();
      await pumpEventQueue();
      expect(launches.single.autoModeDuringPlan, isTrue);

      kernel.permission.select('default');
      kernel.permission.select('acceptEdits');
      kernel.permission.select('bypassPermissions');
      await pumpEventQueue();
      expect(sent(), [false, true]);
      // As when the CLI takes up another mode itself.
      cli.push({
        'type': 'system',
        'subtype': 'status',
        'permissionMode': 'dontAsk',
      });
      await pumpEventQueue();
      expect(sent(), [false, true, false]);
      kernel.dispose();
    });

    test(
      'a queued message sent now while the process starts is not lost',
      () async {
        final cli = FakeCli();
        final started = Completer<ClaudeCodeTransport>();
        final kernel = ClaudeCodeKernel(
          MockKernels.claudeCode,
          const KernelContext(cwd: '/p'),
          start: (_) => started.future,
        );
        addTearDown(kernel.dispose);
        final transcript = Transcript();
        kernel.events.listen(transcript.apply);
        kernel
          ..send(const KernelTurn(id: 'u1', text: 'first'))
          ..send(const KernelTurn(id: 'u2', text: 'second'));
        await pumpEventQueue();
        expect(kernel.health.status, KernelHealthStatus.starting);
        expect(transcript.queued.single.$1, 'u2');

        // The queue is already shown, even though the process is not ready.
        // Pressing twice must not send the message or interrupt twice.
        kernel
          ..sendQueuedNow('u2')
          ..sendQueuedNow('u2');
        started.complete(cli);
        await pumpEventQueue();

        expect(cli.users.map((message) => message['uuid']), ['u1', 'u2']);
        expect(cli.requests('interrupt'), hasLength(1));
        expect(transcript.activeTurn, isNull);
        cli.push({
          'type': 'command_lifecycle',
          'command_uuid': 'u2',
          'state': 'started',
        });
        await pumpEventQueue();
        expect(transcript.activeTurn, 'u2');
        expect(transcript.queued, isEmpty);
      },
    );

    test(
      'a queued message sent now while initialization waits is not lost',
      () async {
        final cli = _SilentCli();
        final (:kernel, :transcript, events: _) = claude(cli);
        addTearDown(kernel.dispose);
        kernel
          ..send(const KernelTurn(id: 'u1', text: 'first'))
          ..send(const KernelTurn(id: 'u2', text: 'second'));
        await pumpEventQueue();
        expect(kernel.health.status, KernelHealthStatus.starting);
        final initialize = cli.written.single;

        kernel.sendQueuedNow('u2');
        cli.push({
          'type': 'control_response',
          'response': {
            'subtype': 'success',
            'request_id': initialize['request_id'],
            'response': FakeCli._initialize,
          },
        });
        await pumpEventQueue();

        expect(cli.users.map((message) => message['uuid']), ['u1', 'u2']);
        expect(cli.requests('interrupt'), hasLength(1));
        expect(transcript.activeTurn, isNull);
      },
    );

    test('messages sent while busy queue, start in turn, or are taken '
        'back', () async {
      final cli = FakeCli(
        answers: {
          'cancel_async_message': {'cancelled': true},
        },
      );
      final (:kernel, :transcript, events: _) = claude(cli);
      kernel
        ..send(const KernelTurn(id: 'u1', text: 'first'))
        ..send(const KernelTurn(id: 'u2', text: 'second'))
        ..send(const KernelTurn(id: 'u3', text: 'third'))
        ..send(const KernelTurn(id: 'u4', text: 'fourth'));
      await pumpEventQueue();
      // One waits in the CLI at a time: it takes up all it queued as one
      // turn.
      expect(cli.users.map((m) => m['uuid']), ['u1', 'u2']);
      // Each after the turn before it, not folded into it.
      expect(cli.users.map((m) => m['priority']), everyElement('later'));
      List<String> queued() => [for (final (id, _) in transcript.queued) id];
      // Waiting apart, not in the conversation yet.
      expect(queued(), ['u2', 'u3', 'u4']);
      expect(transcript.indexOf('u2'), isNull);
      cli.push({
        'type': 'assistant',
        'message': {
          'id': 'm1',
          'role': 'assistant',
          'content': [
            {'type': 'text', 'text': 'working on it'},
          ],
        },
      });
      await pumpEventQueue();

      // Not given the CLI yet: taken back here.
      expect(await kernel.cancelQueued('u4'), isTrue);
      expect(cli.requests('cancel_async_message'), isEmpty);
      expect(queued(), ['u2', 'u3']);

      cli
        ..push({'type': 'result', 'subtype': 'success', 'is_error': false})
        ..push({
          'type': 'command_lifecycle',
          'command_uuid': 'u2',
          'state': 'started',
        });
      await pumpEventQueue();
      expect(queued(), ['u3']);
      // The next given the CLI once the one before it is taken up.
      expect(cli.users.map((m) => m['uuid']), ['u1', 'u2', 'u3']);
      // Taken up: after what the turn before it said while it waited.
      expect(transcript.indexOf('u2'), 2);
      expect(transcript.length, 3);
      expect(transcript.activeTurn, 'u2');

      expect(await kernel.cancelQueued('u3'), isTrue);
      expect(cli.requests('cancel_async_message').single['message_uuid'], 'u3');
      expect(queued(), isEmpty);

      kernel
        ..cancel()
        ..cancel();
      await pumpEventQueue();
      expect(cli.requests('interrupt'), hasLength(1));
      expect(transcript.activeTurn, isNull);
      kernel.dispose();
    });

    test(
      'messages sent while busy join the turn running when set to',
      () async {
        QueuedMessages.current = () => QueuedMessages.duringTurn;
        addTearDown(
          () => QueuedMessages.current = () => QueuedMessages.fallback,
        );
        final cli = FakeCli();
        final (:kernel, transcript: _, events: _) = claude(cli);
        kernel
          ..send(const KernelTurn(id: 'u1', text: 'first'))
          ..send(const KernelTurn(id: 'u2', text: 'second'));
        await pumpEventQueue();
        expect(cli.users.map((m) => m['priority']), ['next', 'next']);
        kernel.dispose();
      },
    );

    test(
      'a queued message sent now while the process starts is not lost',
      () async {
        final cli = FakeCli();
        final started = Completer<ClaudeCodeTransport>();
        final kernel = ClaudeCodeKernel(
          MockKernels.claudeCode,
          const KernelContext(cwd: '/p'),
          start: (_) => started.future,
        );
        addTearDown(kernel.dispose);
        final transcript = Transcript();
        kernel.events.listen(transcript.apply);
        kernel
          ..send(const KernelTurn(id: 'u1', text: 'first'))
          ..send(const KernelTurn(id: 'u2', text: 'second'));
        await pumpEventQueue();
        expect(kernel.health.status, KernelHealthStatus.starting);
        expect(transcript.queued.single.$1, 'u2');

        // The queue is already shown, even though the process is not ready.
        // Pressing twice must not send the message or interrupt twice.
        kernel
          ..sendQueuedNow('u2')
          ..sendQueuedNow('u2');
        started.complete(cli);
        await pumpEventQueue();

        expect(cli.users.map((message) => message['uuid']), ['u1', 'u2']);
        expect(cli.requests('interrupt'), hasLength(1));
        expect(transcript.activeTurn, isNull);
        cli.push({
          'type': 'command_lifecycle',
          'command_uuid': 'u2',
          'state': 'started',
        });
        await pumpEventQueue();
        expect(transcript.activeTurn, 'u2');
        expect(transcript.queued, isEmpty);
      },
    );

    test(
      'a queued message sent now while initialization waits is not lost',
      () async {
        final cli = _SilentCli();
        final (:kernel, :transcript, events: _) = claude(cli);
        addTearDown(kernel.dispose);
        kernel
          ..send(const KernelTurn(id: 'u1', text: 'first'))
          ..send(const KernelTurn(id: 'u2', text: 'second'));
        await pumpEventQueue();
        expect(kernel.health.status, KernelHealthStatus.starting);
        final initialize = cli.written.single;

        kernel.sendQueuedNow('u2');
        cli.push({
          'type': 'control_response',
          'response': {
            'subtype': 'success',
            'request_id': initialize['request_id'],
            'response': FakeCli._initialize,
          },
        });
        await pumpEventQueue();

        expect(cli.users.map((message) => message['uuid']), ['u1', 'u2']);
        expect(cli.requests('interrupt'), hasLength(1));
        expect(transcript.activeTurn, isNull);
      },
    );

    test('a queued message sent now goes before those queued ahead of it, '
        'the turn running stopped for it', () async {
      final cli = FakeCli(
        answers: {
          'cancel_async_message': {'cancelled': true},
        },
      );
      final (:kernel, :transcript, events: _) = claude(cli);
      kernel
        ..send(const KernelTurn(id: 'u1', text: 'first'))
        ..send(const KernelTurn(id: 'u2', text: 'second'))
        ..send(const KernelTurn(id: 'u3', text: 'third'));
      await pumpEventQueue();

      // The next anyway, the one after it held: only the turn running is
      // stopped, and it is taken up alone.
      kernel.sendQueuedNow('u2');
      await pumpEventQueue();
      expect(cli.requests('interrupt'), hasLength(1));
      expect(cli.requests('cancel_async_message'), isEmpty);
      expect(cli.users.map((m) => m['uuid']), ['u1', 'u2']);

      cli.push({
        'type': 'command_lifecycle',
        'command_uuid': 'u2',
        'state': 'started',
      });
      await pumpEventQueue();
      expect(cli.users.map((m) => m['uuid']), ['u1', 'u2', 'u3']);
      kernel.send(const KernelTurn(id: 'u4', text: 'fourth'));
      await pumpEventQueue();
      kernel.sendQueuedNow('u4');
      await pumpEventQueue();
      // Held, it is taken back here; the one in the CLI there.
      expect(
        cli.requests('cancel_async_message').map((r) => r['message_uuid']),
        ['u3'],
      );
      // Sent again, in its new place: it first, the turn stopped for it,
      // the other held until it is taken up.
      List<Object?> contents() => [
        for (final m in cli.users.skip(3)) (m['message'] as Map)['content'],
      ];
      expect(contents(), [
        [
          {'type': 'text', 'text': 'fourth'},
        ],
      ]);
      expect(cli.requests('interrupt'), hasLength(2));
      expect(
        [for (final (_, item) in transcript.queued) item.text],
        ['fourth', 'third'],
      );

      cli.push({
        'type': 'command_lifecycle',
        'command_uuid': cli.users.last['uuid'],
        'state': 'started',
      });
      await pumpEventQueue();
      expect(contents(), [
        [
          {'type': 'text', 'text': 'fourth'},
        ],
        [
          {'type': 'text', 'text': 'third'},
        ],
      ]);
      expect([for (final (_, item) in transcript.queued) item.text], ['third']);
      kernel.dispose();
    });

    test('a queued message moved among those held here is reordered there, '
        'the CLI left as it is', () async {
      final cli = FakeCli(
        answers: {
          'cancel_async_message': {'cancelled': true},
        },
      );
      final (:kernel, :transcript, events: _) = claude(cli);
      kernel
        ..send(const KernelTurn(id: 'u1', text: 'first'))
        ..send(const KernelTurn(id: 'u2', text: 'second'))
        ..send(const KernelTurn(id: 'u3', text: 'third'))
        ..send(const KernelTurn(id: 'u4', text: 'fourth'));
      await pumpEventQueue();
      // One waits in the CLI at a time: the rest are held here.
      expect(cli.users.map((m) => m['uuid']), ['u1', 'u2']);
      List<String> queued() => [for (final (id, _) in transcript.queued) id];
      expect(queued(), ['u2', 'u3', 'u4']);

      kernel.moveQueued('u4', 1);
      await pumpEventQueue();
      expect(queued(), ['u2', 'u4', 'u3']);
      // Nothing taken back or sent again: it waits here either way.
      expect(cli.requests('cancel_async_message'), isEmpty);
      expect(cli.requests('interrupt'), isEmpty);
      expect(cli.users.map((m) => m['uuid']), ['u1', 'u2']);
      kernel.dispose();
    });

    test('a queued message moved before the one given the CLI is sent '
        'before it, the turn running not stopped', () async {
      final cli = FakeCli(
        answers: {
          'cancel_async_message': {'cancelled': true},
        },
      );
      final (:kernel, :transcript, events: _) = claude(cli);
      kernel
        ..send(const KernelTurn(id: 'u1', text: 'first'))
        ..send(const KernelTurn(id: 'u2', text: 'second'))
        ..send(const KernelTurn(id: 'u3', text: 'third'))
        ..send(const KernelTurn(id: 'u4', text: 'fourth'));
      await pumpEventQueue();

      kernel.moveQueued('u4', 0);
      await pumpEventQueue();
      // The one in the CLI taken back; all sent again in the new order,
      // the first waiting in the CLI, the rest held here.
      expect(
        cli.requests('cancel_async_message').map((r) => r['message_uuid']),
        ['u2'],
      );
      expect(cli.requests('interrupt'), isEmpty);
      expect(
        [for (final m in cli.users.skip(2)) (m['message'] as Map)['content']],
        [
          [
            {'type': 'text', 'text': 'fourth'},
          ],
        ],
      );
      expect(
        [for (final (_, item) in transcript.queued) item.text],
        ['fourth', 'second', 'third'],
      );

      cli.push({
        'type': 'command_lifecycle',
        'command_uuid': cli.users.last['uuid'],
        'state': 'started',
      });
      await pumpEventQueue();
      // The next held given the CLI once the one before it is taken up.
      expect((cli.users.last['message'] as Map)['content'], [
        {'type': 'text', 'text': 'second'},
      ]);
      expect(
        [for (final (_, item) in transcript.queued) item.text],
        ['second', 'third'],
      );
      kernel.dispose();
    });

    test('a queued message sent now with a task in the background does not '
        'interrupt, which would end the task too: the CLI takes it up '
        'next', () async {
      final cli = FakeCli(
        answers: {
          'cancel_async_message': {'cancelled': true},
        },
      );
      final (:kernel, :transcript, events: _) = claude(cli);
      kernel.send(const KernelTurn(id: 'u1', text: 'first'));
      await pumpEventQueue();
      cli.push({
        'type': 'system',
        'subtype': 'task_started',
        'task_id': 'a1',
        'task_type': 'local_agent',
        'description': 'Watch',
        'is_backgrounded': true,
      });
      kernel.send(const KernelTurn(id: 'u2', text: 'second'));
      await pumpEventQueue();

      kernel.sendQueuedNow('u2');
      await pumpEventQueue();
      expect(cli.requests('interrupt'), isEmpty);
      expect(
        cli.requests('cancel_async_message').map((r) => r['message_uuid']),
        ['u2'],
      );
      final resent = cli.users.last;
      expect(resent['priority'], 'now');
      expect((resent['message'] as Map)['content'], [
        {'type': 'text', 'text': 'second'},
      ]);
      expect(
        [for (final (_, item) in transcript.queued) item.text],
        ['second'],
      );
      kernel.dispose();
    });

    test('with a task in the background, a CLI that sends a queued message '
        'now itself is asked to, the message left where it is', () async {
      final cli = FakeCli(
        answers: {
          'interrupt': {'still_queued': <String>[], 'send_now': 'delivering'},
        },
      );
      final (:kernel, :transcript, events: _) = claude(cli);
      kernel.send(const KernelTurn(id: 'u1', text: 'first'));
      await pumpEventQueue();
      cli
        ..push({
          'type': 'system',
          'subtype': 'init',
          'session_id': 's1',
          'capabilities': ['interrupt_send_now_v1'],
        })
        ..push({
          'type': 'system',
          'subtype': 'task_started',
          'task_id': 'a1',
          'task_type': 'local_bash',
          'description': 'Serve',
          'is_backgrounded': true,
        });
      kernel.send(const KernelTurn(id: 'u2', text: 'second'));
      await pumpEventQueue();
      final sent = cli.users.length;

      kernel.sendQueuedNow('u2');
      await pumpEventQueue();
      expect(cli.requests('interrupt'), [
        {'subtype': 'interrupt', 'send_now': true, 'message_uuid': 'u2'},
      ]);
      expect(cli.requests('cancel_async_message'), isEmpty);
      expect(cli.users, hasLength(sent));
      expect(transcript.activeTurn, 'u1');
      expect(
        [for (final (_, item) in transcript.queued) item.text],
        ['second'],
      );
      kernel.dispose();
    });

    test('where the CLI does not take a queued message now itself, it is '
        'sent again', () async {
      final cli = FakeCli(
        answers: {
          'interrupt': {},
          'cancel_async_message': {'cancelled': true},
        },
      );
      final (:kernel, :transcript, events: _) = claude(cli);
      kernel.send(const KernelTurn(id: 'u1', text: 'first'));
      await pumpEventQueue();
      cli
        ..push({
          'type': 'system',
          'subtype': 'init',
          'session_id': 's1',
          'capabilities': ['interrupt_send_now_v1'],
        })
        ..push({
          'type': 'system',
          'subtype': 'task_started',
          'task_id': 'a1',
          'task_type': 'local_bash',
          'description': 'Serve',
          'is_backgrounded': true,
        });
      kernel.send(const KernelTurn(id: 'u2', text: 'second'));
      await pumpEventQueue();

      kernel.sendQueuedNow('u2');
      await pumpEventQueue();
      expect(cli.requests('interrupt'), [
        {'subtype': 'interrupt', 'send_now': true, 'message_uuid': 'u2'},
      ]);
      expect(cli.users.last['uuid'], isNot('u3'));
      expect(cli.users.last['priority'], 'later');
      expect(cli.users, hasLength(2));
      expect(
        [for (final (_, item) in transcript.queued) item.text],
        ['second'],
      );
      kernel.dispose();
    });

    test('a turn stopped as soon as sent stays stopped; the CLI\'s notes of '
        'the interruption do not show', () async {
      final cli = FakeCli();
      final (:kernel, :transcript, events: _) = claude(cli);
      Map<String, Object?> interruption(String uuid) => {
        'type': 'user',
        'uuid': uuid,
        'message': {
          'role': 'user',
          'content': [
            {'type': 'text', 'text': '[Request interrupted by user]'},
          ],
        },
      };

      kernel.send(const KernelTurn(id: 'u1', text: 'look at my code'));
      await pumpEventQueue();
      kernel.cancel();
      expect(transcript.activeTurn, isNull);
      // The CLI takes it up after all (the interrupt came first).
      cli.push({
        'type': 'command_lifecycle',
        'command_uuid': 'u1',
        'state': 'started',
      });
      await pumpEventQueue();
      expect(transcript.activeTurn, isNull);
      kernel.cancel();
      await pumpEventQueue();
      expect(cli.requests('interrupt'), hasLength(1));

      cli
        ..push(interruption('i1'))
        ..push(interruption('i2'));
      await pumpEventQueue();
      expect(transcript.length, 1);
      expect(transcript.itemAt(0), isA<UserMessageItem>());
      kernel.dispose();
    });

    test('a stopped turn\'s calls left unanswered show as failed, but a '
        'subagent in the background and its calls go on', () async {
      final cli = FakeCli();
      final (:kernel, :transcript, events: _) = claude(cli);
      Map<String, Object?> call(
        String id,
        String name,
        Map<String, Object?> input, {
        String? parent,
      }) => {
        'type': 'assistant',
        'uuid': 'm-$id',
        'parent_tool_use_id': parent,
        'message': {
          'id': 'msg-$id',
          'role': 'assistant',
          'content': [
            {'type': 'tool_use', 'id': id, 'name': name, 'input': input},
          ],
        },
      };

      kernel.send(const KernelTurn(id: 'u1', text: 'look at my code'));
      await pumpEventQueue();
      cli
        ..push(call('a1', 'Agent', {'description': 'Look', 'prompt': 'look'}))
        ..push(call('r1', 'Read', {'file_path': '/a.dart'}, parent: 'a1'))
        ..push(
          call('a2', 'Agent', {
            'description': 'Watch',
            'prompt': 'watch',
            'run_in_background': true,
          }),
        )
        ..push(call('r2', 'Read', {'file_path': '/b.dart'}, parent: 'a2'))
        ..push(call('b1', 'Bash', {'command': 'sleep 9'}));
      await pumpEventQueue();
      final before = [...transcript.liveItems.map((e) => e.$2)];
      expect(
        before.whereType<AgentItem>().map((a) => a.status),
        everyElement(CommandStatus.running),
      );

      kernel.cancel();
      final items = {for (final (id, item) in transcript.liveItems) id: item};
      final look = items['a1']! as AgentItem;
      expect(look.status, CommandStatus.failed);
      expect((look.children.single as ToolCallItem).status, ToolStatus.failed);
      expect((items['b1']! as TerminalItem).status, CommandStatus.failed);
      final watch = items['a2']! as AgentItem;
      expect(watch.status, CommandStatus.running);
      expect(
        (watch.children.single as ToolCallItem).status,
        ToolStatus.running,
      );
      kernel.dispose();
    });

    test('a turn the CLI takes up of its own (a background command done) '
        'shows as under way, and stops', () async {
      final cli = FakeCli();
      final (:kernel, :transcript, events: _) = claude(cli);
      Map<String, Object?> requesting(String uuid) => {
        'type': 'system',
        'subtype': 'status',
        'status': 'requesting',
        'uuid': uuid,
      };
      const result = {
        'type': 'result',
        'subtype': 'success',
        'is_error': false,
      };
      Future<void> notified(String id) async {
        cli
          ..push({
            'type': 'user',
            'uuid': 'n$id',
            'isReplay': true,
            'origin': {'kind': 'task-notification'},
            'parent_tool_use_id': null,
            'message': {
              'role': 'user',
              'content':
                  '<task-notification>\n<task-id>b1</task-id>\n'
                  '<status>completed</status>\n</task-notification>',
            },
          })
          ..push(requesting('s$id'));
        await pumpEventQueue();
      }

      kernel.send(const KernelTurn(id: 'u1', text: 'run the tests'));
      await pumpEventQueue();
      cli
        ..push(requesting('s1'))
        ..push(result);
      await pumpEventQueue();
      expect(transcript.activeTurn, isNull);

      await notified('2');
      expect(transcript.activeTurn, 's2');
      // A message meanwhile waits its turn, as the CLI has it.
      kernel.send(const KernelTurn(id: 'u2', text: 'and lint'));
      expect(transcript.queued.single.$1, 'u2');
      cli.push(result);
      await pumpEventQueue();
      expect(transcript.activeTurn, isNull);
      cli.push({
        'type': 'command_lifecycle',
        'command_uuid': 'u2',
        'state': 'started',
      });
      await pumpEventQueue();
      expect(transcript.activeTurn, 'u2');
      cli
        ..push(requesting('s3'))
        ..push(result);
      await pumpEventQueue();
      expect(transcript.activeTurn, isNull);

      await notified('4');
      expect(transcript.activeTurn, 's4');
      kernel.cancel();
      await pumpEventQueue();
      expect(cli.requests('interrupt'), hasLength(1));
      expect(transcript.activeTurn, isNull);
      kernel.dispose();
    });

    test('out of view, a process with work in the background is kept until '
        'it is done; its tasks end with it', () async {
      final cli = FakeCli();
      final (:kernel, :transcript, events: _) = claude(cli);
      const result = {
        'type': 'result',
        'subtype': 'success',
        'is_error': false,
      };
      Future<void> backgrounded(String turn, String task) async {
        kernel.send(KernelTurn(id: turn, text: 'run the tests'));
        await pumpEventQueue();
        cli
          ..push({
            'type': 'system',
            'subtype': 'task_started',
            'task_id': task,
            'task_type': 'local_bash',
            'description': 'Run the tests',
            'is_backgrounded': true,
          })
          ..push(result);
        await pumpEventQueue();
      }

      await backgrounded('u1', 'b1');
      expect(transcript.activeTurn, isNull);
      kernel.release();
      expect(cli.closed, isFalse, reason: 'the agent awaits its notice');
      cli.push({
        'type': 'system',
        'subtype': 'task_notification',
        'task_id': 'b1',
        'status': 'completed',
      });
      await pumpEventQueue();
      kernel.release();
      expect(cli.closed, isTrue);

      // A process that exits takes its tasks along: they hold nothing up.
      cli.closed = false;
      await backgrounded('u2', 'b2');
      cli.push(ClaudeExit.message(0, ''));
      await pumpEventQueue();
      expect(
        transcript.tasks.last,
        isA<KernelTask>()
            .having((t) => t.id, 'id', 'b2')
            .having((t) => t.status, 'status', CommandStatus.failed),
      );
      cli.closed = false;
      kernel.send(const KernelTurn(id: 'u3', text: 'again'));
      await pumpEventQueue();
      cli.push(result);
      await pumpEventQueue();
      kernel.release();
      expect(cli.closed, isTrue);
      kernel.dispose();
    });

    test(
      'renamed in the CLI (/rename): told; the names sent, not (#171)',
      () async {
        final cli = FakeCli();
        final (:kernel, transcript: _, :events) = claude(cli);
        Future<void> titled(String title) async {
          cli.push({
            'type': 'system',
            'subtype': 'session_title_changed',
            'title': title,
          });
          await pumpEventQueue();
        }

        kernel.send(const KernelTurn(id: 'u1', text: 'hi'));
        await pumpEventQueue();
        kernel
          ..rename('First')
          ..rename('Second');
        await pumpEventQueue();
        expect(cli.requests('rename_session'), hasLength(2));
        await titled('First');
        await titled('Second');
        await titled(' Mine ');
        expect(
          [
            for (final event in events)
              if (event is SessionRenamed) event.title,
          ],
          ['Mine'],
        );
        kernel.dispose();
      },
    );

    test('out of view while busy, the process is freed once the CLI says it '
        'is idle; back in view, it is kept', () async {
      final cli = FakeCli();
      final (:kernel, transcript: _, :events) = claude(cli);
      Map<String, Object?> state(String value) => {
        'type': 'system',
        'subtype': 'session_state_changed',
        'state': value,
      };
      const result = {
        'type': 'result',
        'subtype': 'success',
        'is_error': false,
      };
      Future<void> push(Map<String, Object?> message) async {
        cli.push(message);
        await pumpEventQueue();
      }

      kernel.send(const KernelTurn(id: 'u1', text: 'hi'));
      await pumpEventQueue();
      await push(state('running'));
      await push(result);
      // The turn is over, but the CLI may take up what it queued meanwhile.
      kernel.release();
      expect(cli.closed, isFalse);
      await push(state('idle'));
      expect(cli.closed, isTrue);

      // A task in the background: freed only once the agent has had its
      // notice, in a turn of the CLI's own.
      cli.closed = false;
      kernel.send(const KernelTurn(id: 'u2', text: 'run the tests'));
      await pumpEventQueue();
      await push(state('running'));
      await push({
        'type': 'system',
        'subtype': 'task_started',
        'task_id': 'b1',
        'task_type': 'local_bash',
        'description': 'Run the tests',
        'is_backgrounded': true,
      });
      await push(result);
      await push(state('idle'));
      kernel.release();
      expect(cli.closed, isFalse);
      await push({
        'type': 'system',
        'subtype': 'task_notification',
        'task_id': 'b1',
        'status': 'completed',
      });
      expect(cli.closed, isFalse, reason: 'its notice is not taken up yet');
      await push(state('running'));
      await push({
        'type': 'system',
        'subtype': 'status',
        'status': 'requesting',
        'uuid': 's1',
      });
      // Taken up by the agent on its own, not sent by the user.
      expect(
        {
          for (final started in events.whereType<TurnStarted>())
            started.turnId: started.unprompted,
        },
        {'u1': false, 'u2': false, 's1': true},
      );
      await push(result);
      expect(cli.closed, isFalse);
      await push(state('idle'));
      expect(cli.closed, isTrue);

      // Shown again before the CLI is idle: it stays.
      cli.closed = false;
      kernel.send(const KernelTurn(id: 'u3', text: 'again'));
      await pumpEventQueue();
      await push(state('running'));
      await push(result);
      kernel
        ..release()
        ..prepare();
      await push(state('idle'));
      expect(cli.closed, isFalse);
      kernel.dispose();
    });

    test('out of view while it starts, the process is freed once started; '
        'a title waiting is taken first, a message sent meanwhile answered '
        'first', () async {
      const result = {
        'type': 'result',
        'subtype': 'success',
        'is_error': false,
      };
      ({ClaudeCodeKernel kernel, _SlowStartCli cli, Completer<void> spawned})
      starting() {
        final cli = _SlowStartCli();
        final spawned = Completer<void>();
        final kernel = ClaudeCodeKernel(
          MockKernels.claudeCode,
          const KernelContext(cwd: '/p'),
          start: (_) async {
            await spawned.future;
            return cli;
          },
        );
        return (kernel: kernel, cli: cli, spawned: spawned);
      }

      // Out of view before the process is there.
      var (:kernel, :cli, :spawned) = starting();
      kernel
        ..rename('Named')
        ..prepare()
        ..release();
      spawned.complete();
      await pumpEventQueue();
      expect(cli.closed, isFalse, reason: 'not yet initialized');
      cli.initialized();
      await pumpEventQueue();
      expect(cli.requests('rename_session').single['title'], 'Named');
      expect(cli.closed, isTrue);
      kernel.dispose();

      // Out of view while it initializes.
      (:kernel, :cli, :spawned) = starting();
      spawned.complete();
      kernel.prepare();
      await pumpEventQueue();
      kernel.release();
      expect(cli.closed, isFalse);
      cli.initialized();
      await pumpEventQueue();
      expect(cli.closed, isTrue);
      kernel.dispose();

      // Back in view before it is ready: it stays.
      (:kernel, :cli, :spawned) = starting();
      spawned.complete();
      kernel
        ..prepare()
        ..release()
        ..prepare();
      await pumpEventQueue();
      cli.initialized();
      await pumpEventQueue();
      expect(cli.closed, isFalse);
      kernel.dispose();

      // A message sent as it started: freed once it is answered.
      (:kernel, :cli, :spawned) = starting();
      spawned.complete();
      kernel
        ..send(const KernelTurn(id: 'u1', text: 'hi'))
        ..release();
      await pumpEventQueue();
      cli.initialized();
      await pumpEventQueue();
      expect(cli.users, hasLength(1));
      expect(cli.closed, isFalse);
      cli.push(result);
      await pumpEventQueue();
      cli.push({
        'type': 'system',
        'subtype': 'session_state_changed',
        'state': 'idle',
      });
      await pumpEventQueue();
      expect(cli.closed, isTrue);
      kernel.dispose();
    });

    test('undo rewinds the files since the turn; a rewind lands before '
        'the next message', () async {
      final cli = FakeCli(
        answers: {
          'rewind_files': {'canRewind': true, 'filesChanged': <String>[]},
          'rewind_conversation': {'rewound': true},
        },
      );
      final (:kernel, :transcript, :events) = claude(cli);
      kernel.revertChanges(sinceTurn: 'u1');
      await pumpEventQueue();
      expect(cli.requests('rewind_files').single['user_message_id'], 'u1');
      expect(events.whereType<ChangesReverted>(), hasLength(1));

      final rewound = kernel.rewind(
        itemId: 'u1',
        index: 0,
        turns: 1,
        lastSeen: 'u3',
      );
      kernel.send(const KernelTurn(id: 'u2', text: 'again'));
      await pumpEventQueue();
      expect(await rewound, isTrue);
      expect(cli.requests('rewind_conversation').single, {
        'subtype': 'rewind_conversation',
        'target_message_uuid': 'u1',
        'interrupt_if_running': true,
        'last_seen_user_message_uuid': 'u3',
      });
      expect(events.whereType<Rewound>().single.itemId, 'u1');
      final order = [
        for (final message in cli.written)
          if (message['type'] == 'user')
            'user'
          else if ((message['request'] as Map?)?['subtype']
              case 'rewind_conversation')
            'rewind',
      ];
      expect(order, ['rewind', 'user']);
      kernel.dispose();
    });

    test('a rewind the CLI turns down leaves the conversation as it was, '
        'and says why', () async {
      final cli = FakeCli(
        answers: {
          'rewind_conversation': {
            'rewound': false,
            'prefillText': null,
            'precedingAssistantUuid': null,
            'error': 'stale target',
            'reason': 'stale_target',
          },
        },
      );
      final (:kernel, :transcript, :events) = claude(cli);
      kernel.send(const KernelTurn(id: 'u1', text: 'one'));
      await pumpEventQueue();
      final before = transcript.length;
      expect(await kernel.rewind(itemId: 'u1', index: 0, turns: 1), isFalse);
      expect(events.whereType<Rewound>(), isEmpty);
      expect(transcript.length, before + 1);
      expect(
        transcript.itemAt(transcript.length - 1),
        isA<NoticeItem>().having(
          (notice) => notice.text,
          'text',
          contains('stale target'),
        ),
      );
      kernel.dispose();
    });

    test('an edit goes back past the later messages seen, and is sent only '
        'once the CLI has gone back', () async {
      Future<ChatSession> open(FakeCli cli) async {
        final descriptor = KernelDescriptor(
          id: 'claude-code',
          label: 'Claude Code',
          icon: Icons.auto_awesome_rounded,
          description: '',
          create: (context) => ClaudeCodeKernel(
            MockKernels.claudeCode,
            context,
            start: (_) async => cli,
          ),
        );
        final session = ChatSession(
          kernel: descriptor,
          kernels: [descriptor],
          historyCount: 0,
        );
        addTearDown(session.dispose);
        for (final text in ['one', 'two']) {
          session.send(ComposerMessage(text: text));
          await pumpEventQueue();
          cli.push({
            'type': 'result',
            'subtype': 'success',
            'is_error': false,
            'session_id': 's',
          });
          await pumpEventQueue();
        }
        return session;
      }

      List<String> said(ChatSession session) => [
        for (var i = 0; i < session.itemCount; i++)
          if (session.itemAt(i) case UserMessageItem(:final text)) text,
      ];

      final cli = FakeCli(
        answers: {
          'rewind_conversation': {'rewound': true},
        },
      );
      final session = await open(cli);
      final [first, second] = [
        for (final user in cli.users) user['uuid'] as String,
      ];
      session.editMessage(0, const ComposerMessage(text: 'ONE'));
      await pumpEventQueue();
      final request = cli.requests('rewind_conversation').single;
      expect(request['target_message_uuid'], first);
      expect(request['last_seen_user_message_uuid'], second);
      expect(said(session), ['ONE']);
      expect(cli.users, hasLength(3));

      final refusing = FakeCli(
        answers: {
          'rewind_conversation': {
            'rewound': false,
            'error': 'turn running',
            'reason': 'turn_running',
          },
        },
      );
      final kept = await open(refusing);
      kept.editMessage(0, const ComposerMessage(text: 'ONE'));
      await pumpEventQueue();
      expect(said(kept), ['one', 'two']);
      expect(refusing.users, hasLength(2), reason: 'the edit is not sent');
    });

    test('reports cost, limits and what fills the context', () async {
      final cli = FakeCli();
      final (:kernel, :transcript, events: _) = claude(cli);
      kernel.send(const KernelTurn(id: 'u1', text: 'hi'));
      await pumpEventQueue();
      for (final message in recorded('question')) {
        if (message['type'] case 'rate_limit_event' || 'result') {
          cli.push(message);
        }
      }
      await pumpEventQueue();
      expect(transcript.stats!.costUsd, greaterThan(0));
      expect(transcript.stats!.limits.map((l) => l.label), [
        '5-hour limit',
        'Weekly limit',
      ]);
      final usage = transcript.usage!;
      expect(usage.window, 1000000);
      expect(
        usage.segments.map((s) => s.kind).toSet(),
        containsAll([ContextKind.used, ContextKind.free, ContextKind.buffer]),
      );
      kernel.dispose();
    });

    test('the context is as much as the model told, its parts as the CLI '
        'counted them', () async {
      final cli = FakeCli(
        answers: {
          'get_context_usage': {
            'totalTokens': 4000,
            'maxTokens': 10000,
            'categories': [
              {'name': 'System prompt', 'tokens': 1000},
              {'name': 'Messages', 'tokens': 3000},
              {'name': 'Free space', 'tokens': 5000, 'kind': 'free'},
              {'name': 'Autocompact buffer', 'tokens': 1000, 'kind': 'buffer'},
            ],
          },
        },
      );
      final (:kernel, :transcript, events: _) = claude(cli);
      kernel.send(const KernelTurn(id: 'u1', text: 'hi'));
      await pumpEventQueue();
      expect(transcript.usage!.used, 4000, reason: 'the CLI count, at first');

      Map<String, Object?> reply(String id, Map<String, Object?> usage) => {
        'type': 'assistant',
        'parent_tool_use_id': null,
        'message': {
          'id': id,
          'model': 'gpt-5',
          'role': 'assistant',
          'content': [
            {'type': 'text', 'text': 'ok'},
          ],
          'usage': usage,
        },
      };
      cli.push(
        reply('m1', {
          'input_tokens': 300,
          'cache_read_input_tokens': 1500,
          'output_tokens': 200,
        }),
      );
      // A subagent's is not the conversation's.
      cli.push({
        ...reply('s1', {'input_tokens': 9000, 'output_tokens': 1}),
        'parent_tool_use_id': 'task1',
      });
      await pumpEventQueue();
      var usage = transcript.usage!;
      expect(usage.used, 2000);
      int tokens(String label) =>
          usage.segments.firstWhere((s) => s.label == label).tokens;
      expect(tokens('System prompt'), 500);
      expect(tokens('Messages'), 1500);
      expect(tokens('Free space'), 7000);
      expect(tokens('Autocompact buffer'), 1000);

      // Compacted: what it told is gone; the CLI's count until it tells
      // again.
      cli.push({
        'type': 'system',
        'subtype': 'compact_boundary',
        'compact_metadata': {'trigger': 'auto', 'pre_tokens': 2000},
      });
      await pumpEventQueue();
      usage = transcript.usage!;
      expect(usage.used, 4000);
      expect(tokens('Messages'), 3000);
      kernel.dispose();
    });

    group("the tools' results are counted here, an image as one", () {
      // As Claude Code counts them: a screenshot's base64 as text.
      final told = {
        'totalTokens': 4000,
        'maxTokens': 10000,
        'categories': [
          {'name': 'Messages', 'tokens': 4000},
        ],
        'messageBreakdown': {
          'userMessageTokens': 50,
          'toolCallTokens': 10,
          'toolResultTokens': 100000,
          'toolCallsByType': [
            {'name': 'Screenshot', 'callTokens': 10, 'resultTokens': 100000},
          ],
        },
      };
      Map<String, Object?> use(String id, String name) => {
        'type': 'assistant',
        'uuid': 'a-$id',
        'parent_tool_use_id': null,
        'message': {
          'id': 'm-$id',
          'role': 'assistant',
          'model': 'gpt-5',
          'content': [
            {'type': 'tool_use', 'id': id, 'name': name, 'input': const {}},
          ],
          'usage': {'input_tokens': 1000, 'output_tokens': 10},
        },
      };
      Map<String, Object?> result(String id, Object content) => {
        'type': 'user',
        'uuid': 'r-$id',
        'parent_tool_use_id': null,
        'message': {
          'role': 'user',
          'content': [
            {'type': 'tool_result', 'tool_use_id': id, 'content': content},
          ],
        },
      };
      final screenshot = [
        {
          'type': 'image',
          'source': {
            'type': 'base64',
            'media_type': 'image/png',
            'data': 'A' * 400000,
          },
        },
      ];

      test('as they come', () async {
        final cli = FakeCli(answers: {'get_context_usage': told});
        final (:kernel, :transcript, events: _) = claude(cli);
        kernel.send(const KernelTurn(id: 'u1', text: 'look'));
        await pumpEventQueue();
        cli.push(use('t1', 'Screenshot'));
        cli.push(result('t1', screenshot));
        cli.push(use('t2', 'Read'));
        await pumpEventQueue();
        var detail = transcript.usage!.detail!;
        expect(detail.toolResults, 1500);
        expect(
          detail.toolUses.map((item) => (item.name, item.results)),
          [('Screenshot', 1500)],
        );

        cli.push({'type': 'system', 'subtype': 'compact_boundary'});
        await pumpEventQueue();
        detail = transcript.usage!.detail!;
        expect(detail.toolResults, 0);
        kernel.dispose();
      });

      test("a resumed session's, read from its start", () async {
        final whole = [
          use('t1', 'Screenshot'),
          result('t1', screenshot),
          use('t2', 'Read'),
          result('t2', 'x' * 400),
        ];
        final kernel = ClaudeCodeKernel(
          MockKernels.claudeCode,
          KernelContext(
            cwd: '/p',
            resume: SessionRecord(
              id: 's',
              title: 't',
              updatedAt: DateTime(2026),
              cwd: '/p',
            ),
          ),
          start: (_) async => FakeCli(answers: {'get_context_usage': told}),
          // Its first page has only the last call's.
          readHistoryPage: (session, {required turns, before}) async =>
              ClaudeHistoryPage(whole.sublist(2), earlier: 'a-t1'),
          readHistory: (session) async => whole,
        );
        final transcript = Transcript();
        kernel.events.listen(transcript.apply);
        kernel.prepare();
        await pumpEventQueue();
        final detail = transcript.usage!.detail!;
        expect(detail.toolResults, 1600);
        expect(
          {for (final item in detail.toolUses) item.name: item.results},
          {'Screenshot': 1500, 'Read': 100},
        );
        kernel.dispose();
      });
    });

    test("keeps the calls on Claude Code's own models, timed, and priced "
        "at Anthropic's as the CLI prices them", () async {
      final ledger = UsageLedger.current = UsageLedger(MemoryUsageStorage());
      addTearDown(
        () => UsageLedger.current = UsageLedger(MemoryUsageStorage()),
      );
      final cli = FakeCli();
      final (:kernel, transcript: _, events: _) = claude(cli);
      kernel.send(const KernelTurn(id: 'u1', text: 'hi'));
      await pumpEventQueue();
      final messages = recorded('question');
      final result = messages.indexWhere((m) => m['type'] == 'result');
      for (final message in messages.take(result + 1)) {
        if (message['type'] case 'control_response' || 'control_request') {
          continue;
        }
        cli.push(message);
      }
      await pumpEventQueue();
      ledger.flush();
      final calls = await ledger.range();
      // Its two requests; the CLI's totals no more than theirs.
      expect(calls, hasLength(2));
      expect(calls.map((c) => (c.provider, c.model)).toSet(), {
        ('claude-code', 'claude-sonnet-5'),
      });
      expect(calls.map((c) => c.output), [122, 5]);
      expect(calls.first.cacheWriteLong, 6455);
      expect(calls.first.stopReason, 'tool_use');
      expect(calls.first.firstToken, isNotNull);
      expect(calls.first.toolCalls, isNotEmpty);
      // The plan's limits, told between them.
      expect(calls.last.quota, isNotEmpty);
      // What the CLI said they cost (its modelUsage's costUSD).
      expect(
        UsagePrices().costOf(calls).byCurrency['USD'],
        closeTo(0.0425954, 1e-9),
      );
      kernel.dispose();
    });

    test('says it is loading the history until it is read', () async {
      final read = Completer<List<Map<String, Object?>>>();
      final kernel = ClaudeCodeKernel(
        MockKernels.claudeCode,
        KernelContext(
          cwd: '/p',
          resume: SessionRecord(
            id: 's',
            title: 't',
            updatedAt: DateTime(2026),
            cwd: '/p',
          ),
        ),
        start: (_) async => FakeCli(),
        readHistory: (_) => read.future,
      );
      var told = 0;
      kernel.events.listen((event) {
        if (event is KernelInfoChanged) told++;
      });
      expect(kernel.loadingHistory, isTrue);
      await pumpEventQueue();
      expect(kernel.loadingHistory, isTrue);

      read.complete(const []);
      await pumpEventQueue();
      expect(kernel.loadingHistory, isFalse);
      expect(told, greaterThan(0));
      kernel.dispose();
    });

    test('is done loading the history when it could not be read', () async {
      final kernel = ClaudeCodeKernel(
        MockKernels.claudeCode,
        KernelContext(
          cwd: '/p',
          resume: SessionRecord(
            id: 's',
            title: 't',
            updatedAt: DateTime(2026),
            cwd: '/p',
          ),
        ),
        start: (_) async => FakeCli(),
        readHistory: (_) async => throw StateError('host unreachable'),
      );
      await pumpEventQueue();
      expect(kernel.loadingHistory, isFalse);
      kernel.dispose();
    });

    test('loads no history for a new session', () {
      final kernel = ClaudeCodeKernel(
        MockKernels.claudeCode,
        const KernelContext(cwd: '/p'),
        start: (_) async => FakeCli(),
        readHistory: (_) async => const [],
      );
      expect(kernel.loadingHistory, isFalse);
      kernel.dispose();
    });

    group('a long session is read from its end', () {
      Map<String, Object?> prompt(String id) => {
        'type': 'user',
        'uuid': id,
        'message': {'role': 'user', 'content': id},
      };

      Map<String, Object?> answer(String id, int written) => {
        'type': 'assistant',
        'uuid': 'a-$id',
        'message': {
          'id': 'm-$id',
          'role': 'assistant',
          'model': 'claude-opus-5-5',
          'content': [
            {'type': 'text', 'text': 'answer $id'},
          ],
          'usage': {
            'input_tokens': 1,
            'cache_read_input_tokens': 0,
            'cache_creation_input_tokens': written,
          },
        },
      };

      ClaudeCodeKernel open(ClaudeHistoryPager pager) => ClaudeCodeKernel(
        MockKernels.claudeCode,
        KernelContext(
          cwd: '/p',
          resume: SessionRecord(
            id: 's',
            title: 't',
            updatedAt: DateTime(2026),
            cwd: '/p',
          ),
        ),
        start: (_) async => FakeCli(),
        readHistoryPage: pager,
      );

      List<String> prompts(Transcript transcript) => [
        for (final (_, item) in transcript.liveItems)
          if (item is UserMessageItem) item.text,
      ];

      test(
        'replays the first page, and the earlier ones go before it',
        () async {
          final asked = <(int, String?)>[];
          final kernel = open((session, {required turns, before}) async {
            asked.add((turns, before));
            return before == null
                ? ClaudeHistoryPage([
                    prompt('u3'),
                    answer('u3', 300),
                    prompt('u4'),
                    answer('u4', 400),
                  ], earlier: 'u3')
                : ClaudeHistoryPage([
                    prompt('u1'),
                    answer('u1', 100),
                    prompt('u2'),
                    answer('u2', 200),
                  ]);
          });
          final transcript = Transcript();
          kernel.events.listen(transcript.apply);
          await pumpEventQueue();
          expect(asked, [(10, null)]);
          expect(prompts(transcript), ['u3', 'u4']);
          expect(kernel.hasEarlierHistory, isTrue);
          expect(transcript.stats!.cache!.conversation.written, 700);
          final lastSeq = transcript.lastSeq;

          await kernel.loadEarlier();
          await pumpEventQueue();
          expect(asked.last, (20, 'u3'));
          expect(prompts(transcript), ['u1', 'u2', 'u3', 'u4']);
          expect(transcript.lastSeq, greaterThan(lastSeq));
          expect(kernel.hasEarlierHistory, isFalse);
          expect(kernel.loadingEarlier, isFalse);
          // Counted once each, not again for the page read later.
          expect(transcript.stats!.cache!.conversation.written, 1000);

          // Nothing before: nothing is read.
          await kernel.loadEarlier();
          expect(asked, hasLength(2));
          kernel.dispose();
        },
      );

      test("reads a model's usage given as strings", () async {
        final kernel = open(
          (session, {required turns, before}) async => ClaudeHistoryPage([
            prompt('u1'),
            {
              ...answer('u1', 0),
              'message': {
                ...answer('u1', 0)['message']! as Map<String, Object?>,
                'usage': {
                  'input_tokens': '1',
                  'cache_read_input_tokens': 'none',
                  'cache_creation_input_tokens': '300',
                },
              },
            },
            // As some write the stream too.
            {
              'type': 'stream_event',
              'event': {
                'type': 'message_start',
                'message': {
                  'id': 'm-x',
                  'usage': {'input_tokens': '1', 'output_tokens': '2'},
                },
              },
            },
            {
              'type': 'stream_event',
              'event': {'type': 'message_stop'},
            },
          ]),
        );
        final transcript = Transcript();
        kernel.events.listen(transcript.apply);
        await pumpEventQueue();
        expect(prompts(transcript), ['u1']);
        expect([
          for (final (_, item) in transcript.liveItems)
            if (item is NoticeItem) item.text,
        ], isEmpty);
        expect(transcript.stats!.cache!.conversation.written, 300);
        kernel.dispose();
      });

      test('turns kept show as their footers did, on every page; those '
          'not kept as before', () async {
        const usage = TurnUsage(
          inputTokens: 1200,
          outputTokens: 300,
          tokensPerSecond: 61.25,
          costUsd: 0.04,
        );
        final kept = _KeptTurns()
          ..sessions['s'] = {
            'u1': (worked: const Duration(seconds: 5), usage: null),
            'u3': (worked: const Duration(seconds: 9), usage: usage),
          };
        ClaudeCodeKernel.turnStats = kept;
        addTearDown(() => ClaudeCodeKernel.turnStats = null);
        final kernel = open(
          (session, {required turns, before}) async => before == null
              ? ClaudeHistoryPage([
                  prompt('u3'),
                  answer('u3', 1),
                  prompt('u4'),
                  answer('u4', 1),
                ], earlier: 'u3')
              : ClaudeHistoryPage([prompt('u1'), answer('u1', 1)]),
        );
        final transcript = Transcript();
        kernel.events.listen(transcript.apply);
        await pumpEventQueue();
        UserMessageItem message(String id) =>
            transcript.itemAt(transcript.indexOf(id)!) as UserMessageItem;
        expect(message('u3').worked, const Duration(seconds: 9));
        expect(message('u3').usage?.tokensPerSecond, 61.25);
        expect(message('u3').usage?.totalTokens, 1500);
        expect(message('u4').usage, isNull);

        await kernel.loadEarlier();
        await pumpEventQueue();
        expect(transcript.itemAt(0), isA<UserMessageItem>());
        expect(
          (transcript.itemAt(0) as UserMessageItem).worked,
          const Duration(seconds: 5),
        );
        kernel.dispose();
      });

      test('a turn cut between pages is timed to where it ends, on the later '
          'page; as kept, where it was', () async {
        Map<String, Object?> at(Map<String, Object?> line, int seconds) => {
          ...line,
          'timestamp': DateTime.utc(
            2026,
            1,
            1,
            10,
            0,
            seconds,
          ).toIso8601String(),
        };
        Map<String, Object?> said(String id) => {
          'type': 'assistant',
          'uuid': id,
          'message': {
            'id': 'm-$id',
            'role': 'assistant',
            'content': [
              {'type': 'text', 'text': id},
            ],
          },
        };
        ClaudeHistoryPage page(String? before) => before == null
            ? ClaudeHistoryPage([
                at(said('a2'), 30),
                at(said('a3'), 50),
              ], earlier: 'a2')
            : ClaudeHistoryPage([at(prompt('u1'), 0), at(said('a1'), 10)]);
        UserMessageItem u1(Transcript transcript) =>
            transcript.itemAt(transcript.indexOf('u1')!) as UserMessageItem;

        var kernel = open((session, {required turns, before}) async {
          return page(before);
        });
        var transcript = Transcript();
        kernel.events.listen(transcript.apply);
        await pumpEventQueue();
        await kernel.loadEarlier();
        await pumpEventQueue();
        expect(u1(transcript).worked, const Duration(seconds: 50));
        kernel.dispose();

        ClaudeCodeKernel.turnStats = _KeptTurns()
          ..sessions['s'] = {
            'u1': (worked: const Duration(seconds: 7), usage: null),
          };
        addTearDown(() => ClaudeCodeKernel.turnStats = null);
        kernel = open((session, {required turns, before}) async {
          return page(before);
        });
        transcript = Transcript();
        kernel.events.listen(transcript.apply);
        await pumpEventQueue();
        await kernel.loadEarlier();
        await pumpEventQueue();
        expect(u1(transcript).worked, const Duration(seconds: 7));
        kernel.dispose();
      });

      test('asked again while it is read, it is the same reading', () async {
        final read = Completer<ClaudeHistoryPage>();
        var reads = 0;
        final kernel = open((session, {required turns, before}) {
          if (before == null) {
            return Future.value(
              ClaudeHistoryPage([prompt('u2'), answer('u2', 1)], earlier: 'u2'),
            );
          }
          reads++;
          return read.future;
        });
        final transcript = Transcript();
        kernel.events.listen(transcript.apply);
        await pumpEventQueue();

        final first = kernel.loadEarlier();
        final second = kernel.loadEarlier();
        expect(kernel.loadingEarlier, isTrue);
        expect(reads, 1);
        read.complete(ClaudeHistoryPage([prompt('u1'), answer('u1', 1)]));
        await Future.wait([first, second]);
        await pumpEventQueue();
        expect(reads, 1);
        expect(prompts(transcript), ['u1', 'u2']);
        expect(kernel.loadingEarlier, isFalse);
        kernel.dispose();
      });

      test('a reading that fails can be tried again', () async {
        var fail = true;
        final kernel = open((session, {required turns, before}) async {
          if (before == null) {
            return ClaudeHistoryPage([prompt('u2')], earlier: 'u2');
          }
          if (fail) throw StateError('host unreachable');
          return ClaudeHistoryPage([prompt('u1')]);
        });
        final transcript = Transcript();
        kernel.events.listen(transcript.apply);
        await pumpEventQueue();

        await kernel.loadEarlier();
        await pumpEventQueue();
        expect(kernel.hasEarlierHistory, isTrue);
        expect(
          transcript.liveItems.map((e) => e.$1),
          contains('history-error'),
        );

        fail = false;
        await kernel.loadEarlier();
        await pumpEventQueue();
        expect(prompts(transcript), ['u1', 'u2']);
        expect(kernel.hasEarlierHistory, isFalse);
        kernel.dispose();
      });
    });

    test('reports the prompt cache, from the session file then live', () async {
      Map<String, Object?> assistant(
        String id,
        int read,
        int written, {
        int uncached = 2,
        String model = 'claude-opus-5-5',
        Object? parent,
        bool sidechain = false,
        bool withCache = true,
      }) => {
        'type': 'assistant',
        'parent_tool_use_id': ?parent,
        if (sidechain) 'isSidechain': true,
        'message': {
          'id': id,
          'role': 'assistant',
          'model': model,
          'content': const [],
          'usage': {
            'input_tokens': uncached,
            // As the proxy gives a provider's: only what was cached.
            if (withCache && (read > 0 || !model.startsWith('p/')))
              'cache_read_input_tokens': read,
            if (withCache && (written > 0 || !model.startsWith('p/')))
              'cache_creation_input_tokens': written,
          },
        },
      };
      final cli = FakeCli();
      final kernel = ClaudeCodeKernel(
        MockKernels.claudeCode,
        KernelContext(
          cwd: '/p',
          resume: SessionRecord(
            id: 's',
            title: 't',
            updatedAt: DateTime(2026),
            cwd: '/p',
          ),
        ),
        start: (_) async => cli,
        readHistory: (_) async => [
          // A message comes a content block a line, its usage completed by
          // the last one; identical lines still count once.
          assistant('m1', 0, 0, uncached: 20002),
          assistant('m1', 0, 20000),
          assistant('m1', 0, 20000),
          assistant('sub', 900, 900, sidechain: true),
          // Resumed elsewhere: all written again.
          assistant('m2', 0, 30000),
        ],
      );
      final transcript = Transcript();
      var statsReports = 0;
      kernel.events.listen((event) {
        if (event is StatsReported) statsReports++;
      });
      kernel.events.listen(transcript.apply);
      await pumpEventQueue();
      var cache = transcript.stats!.cache!;
      expect(cache.last.written, 30000);
      expect(cache.conversation.written, 50000);
      expect(cache.conversation.uncached, 4);

      kernel.send(const KernelTurn(id: 'u1', text: 'hi'));
      await pumpEventQueue();
      cli
        ..push(assistant('m3', 0, 0, uncached: 30502))
        ..push(assistant('m3', 30000, 500))
        // A partial line after the complete one leaves the cache intact.
        ..push(assistant('m3', 0, 0, withCache: false))
        ..push(assistant('agent', 5000, 5000, parent: 'toolu_1'))
        // An API error's: no usage of the model's.
        ..push(assistant('err', 0, 0, uncached: 0));
      await pumpEventQueue();
      cache = transcript.stats!.cache!;
      expect(cache.last.read, 30000);
      expect(cache.last.hitRate, closeTo(30000 / 30502, 1e-9));
      expect(cache.conversation.read, 30000);
      expect(cache.conversation.written, 50500);

      // An identical line does not report the same stats again.
      final beforeDuplicate = statsReports;
      cli.push(assistant('m3', 30000, 500));
      await pumpEventQueue();
      expect(statsReports, beforeDuplicate);

      // A provider's model that never says what was cached: not shown,
      // rather than all uncached.
      cli.push(assistant('p1', 0, 0, uncached: 31000, model: 'p/plain'));
      await pumpEventQueue();
      expect(transcript.stats!.cache, isNull);
      // One that does, once it is cached.
      cli
        ..push(assistant('p2', 0, 0, uncached: 31000, model: 'p/caching'))
        ..push(assistant('p3', 30000, 0, uncached: 1000, model: 'p/caching'));
      await pumpEventQueue();
      expect(transcript.stats!.cache!.last.read, 30000);
      cli.push(assistant('p4', 0, 0, uncached: 31000, model: 'p/caching'));
      await pumpEventQueue();
      expect(transcript.stats!.cache!.last.hitRate, 0);
      kernel.dispose();
    });

    test('the account limits one session hears of show in every one', () async {
      ClaudeCodeKernel.forgetAccount();
      final first = claude(FakeCli());
      final cli = FakeCli();
      final second = claude(cli);
      second.kernel.send(const KernelTurn(id: 'u1', text: 'hi'));
      await pumpEventQueue();
      cli.push({
        'type': 'rate_limit_event',
        'rate_limit_info': {
          'status': 'allowed',
          'unifiedWindows': {
            'five_hour': {'utilization': 0.4, 'resetsAt': 1790540400},
            'seven_day': {'utilization': 0.2, 'resetsAt': 1790845200},
          },
        },
      });
      await pumpEventQueue();
      String shown(Transcript transcript) => [
        for (final limit in transcript.stats!.limits)
          '${limit.label} ${(limit.utilization * 100).round()}%',
      ].join(', ');
      // The other session, never started, shows them too.
      expect(shown(first.transcript), '5-hour limit 40%, Weekly limit 20%');
      final later = claude(FakeCli());
      expect(later.kernel.accountLimits.map((l) => l.label), [
        '5-hour limit',
        'Weekly limit',
      ]);

      // Near a limit, without the windows: that window alone is updated.
      cli.push({
        'type': 'rate_limit_event',
        'rate_limit_info': {
          'status': 'allowed_warning',
          'rateLimitType': 'five_hour',
          'utilization': 0.98,
          'resetsAt': 1790540400,
        },
      });
      await pumpEventQueue();
      expect(shown(second.transcript), '5-hour limit 98%, Weekly limit 20%');
      for (final session in [first, second, later]) {
        session.kernel.dispose();
      }
    });


  test('full access is not the CLI\'s, which root cannot have', () async {
    final cli = FakeCli();
    final launches = <ClaudeLaunch>[];
    final kernel = ClaudeCodeKernel(
      MockKernels.claudeCode,
      const KernelContext(
        cwd: '/p',
        settings: {'permission': 'bypassPermissions'},
      ),
      start: (launch) async {
        launches.add(launch);
        return cli;
      },
    );
    kernel.prepare();
    await pumpEventQueue();
    expect(launches.single.permissionMode, 'acceptEdits');
    expect(
      launches.single.arguments.where((a) => a.contains('dangerously')),
      isEmpty,
    );
    expect(kernel.permission.selected, 'bypassPermissions');
    kernel.dispose();
  });

  test('Claude Code is asked to cite code in the chat\'s format', () {
    final arguments = const ClaudeLaunch(cwd: '/p').arguments;
    final at = arguments.indexOf('--append-system-prompt');
    expect(at, isNot(-1));
    expect(arguments[at + 1], contains(ClaudeLaunch.citingCode));
    expect(ClaudeLaunch.citingCode, contains('```startLine:endLine:filepath'));
  });

  test('some of Claude Code\'s tools: the app\'s MCP servers alone, or the '
      'user\'s too', () {
    List<String> arguments({bool userServers = false}) => ClaudeLaunch(
      cwd: '/p',
      tools: const ['Bash', 'Read'],
      userServers: userServers,
    ).arguments;
    final only = arguments();
    expect(only[only.indexOf('--tools') + 1], 'Bash,Read');
    expect(only, contains('--strict-mcp-config'));
    final theirs = arguments(userServers: true);
    expect(theirs[theirs.indexOf('--tools') + 1], 'Bash,Read');
    expect(theirs, isNot(contains('--strict-mcp-config')));
    });
  });

  group('commit attribution', () {
    /// What `--settings` gives Claude Code besides the environment always
    /// unset, if anything.
    Object? flagSettings(ClaudeLaunch launch) {
      final at = launch.arguments.indexOf('--settings');
      final settings = Map.of(
        jsonDecode(launch.arguments[at + 1]) as Map<String, Object?>,
      );
      if (jsonEncode(settings['env']) ==
          jsonEncode(ClaudeLaunch.unsetEnvironment)) {
        settings.remove('env');
      }
      return settings.isEmpty ? null : settings;
    }

    test('is the setting\'s, BaoCode when unset or unknown', () {
      expect(CommitAttribution.parse(null), CommitAttribution.baocode);
      expect(CommitAttribution.parse('none'), CommitAttribution.none);
      expect(CommitAttribution.parse('agent'), CommitAttribution.agent);
      expect(CommitAttribution.parse('claude'), CommitAttribution.baocode);
      expect(CommitAttribution.parse(1), CommitAttribution.baocode);
    });

    test('is passed as Claude Code\'s attribution setting, but for the '
        'agent\'s own', () {
      ClaudeLaunch launch(CommitAttribution attribution) =>
          ClaudeLaunch(cwd: '/p', attribution: attribution);
      expect(flagSettings(launch(CommitAttribution.baocode)), {
        'attribution': {
          'commit': 'Co-Authored-By: BaoCode <noreply@poying2018.com>',
          'pr': '🤖 Generated with [BaoCode](https://github.com/poying2018/baocode)',
        },
      });
      expect(flagSettings(launch(CommitAttribution.none)), {
        'attribution': {'commit': '', 'pr': ''},
      });
      expect(flagSettings(launch(CommitAttribution.agent)), isNull);
      expect(flagSettings(const ClaudeLaunch(cwd: '/p')), isNull);
      expect(
        flagSettings(
          const ClaudeLaunch(
            cwd: '/p',
            attribution: CommitAttribution.none,
            autoModeDuringPlan: false,
          ),
        ),
        {
          'attribution': {'commit': '', 'pr': ''},
          'useAutoModeDuringPlan': false,
        },
      );
    });

    test('is read as each session starts', () async {
      addTearDown(
        () => CommitAttribution.current = () => CommitAttribution.fallback,
      );
      final launches = <ClaudeLaunch>[];
      ClaudeCodeKernel start() => ClaudeCodeKernel(
        MockKernels.claudeCode,
        const KernelContext(cwd: '/p'),
        start: (launch) async {
          launches.add(launch);
          return FakeCli();
        },
      )..prepare();

      CommitAttribution.current = () => CommitAttribution.none;
      final first = start();
      await pumpEventQueue();
      CommitAttribution.current = () => CommitAttribution.agent;
      final second = start();
      await pumpEventQueue();

      expect(launches.map((launch) => launch.attribution), [
        CommitAttribution.none,
        CommitAttribution.agent,
      ]);
      first.dispose();
      second.dispose();
    });
  });

  group('claude locator', () {
    tearDown(() => CliLocator.use(null));

    test('BAOCODE_CLAUDE_PATH in the environment is not read: the build '
        'to run is a setting now', () async {
      final root = await Directory.systemTemp.createTemp('baocode-locator-');
      addTearDown(() => root.delete(recursive: true));
      final variant = File('${root.path}/claude-variant')
        ..writeAsStringSync('#!/bin/sh\n');
      final installed =
          File(
              p.join(
                root.path,
                'bin',
                Platform.isWindows ? 'claude.exe' : 'claude',
              ),
            )
            ..createSync(recursive: true)
            ..writeAsBytesSync(
              Platform.isWindows
                  ? _windowsProgram()
                  : Uint8List.fromList('#!/bin/sh\n'.codeUnits),
            );
      CliLocator.use({
        'BAOCODE_CLAUDE_PATH': variant.path,
        'PATH': p.join(root.path, 'bin'),
      });

      final cli = await CliLocator.locate();
      expect(cli.executable, installed.path);
    });

    // What npm leaves at bin/claude.exe when its postinstall did not run.
    const placeholder =
        'echo "Error: claude native binary not installed." >&2\nexit 1\n';

    group('on the PATH', () {
      late Directory root;
      setUp(() async {
        root = await Directory.systemTemp.createTemp('baocode-locator-');
        for (final dir in ['first', 'second']) {
          Directory('${root.path}/$dir').createSync();
        }
      });
      tearDown(() => root.delete(recursive: true));

      void use() => CliLocator.use({
        'PATH': '${root.path}/first:${root.path}/second',
        'HOME': root.path,
      });

      test(
        'an install that did not finish is passed over for the next',
        () async {
          File('${root.path}/first/claude').writeAsStringSync(placeholder);
          File('${root.path}/second/claude').writeAsStringSync('#!/bin/sh\n');
          use();

          final cli = await CliLocator.locate();
          expect(cli.executable, '${root.path}/second/claude');
        },
        skip: Platform.isWindows,
      );

      test('looked for again once the one found is gone', () async {
        File('${root.path}/first/claude').writeAsStringSync('#!/bin/sh\n');
        File('${root.path}/second/claude').writeAsStringSync('#!/bin/sh\n');
        use();
        expect(
          (await CliLocator.locate()).executable,
          '${root.path}/first/claude',
        );

        File('${root.path}/first/claude').deleteSync();
        expect(
          (await CliLocator.locate()).executable,
          '${root.path}/second/claude',
        );
      }, skip: Platform.isWindows);

      test('looked for again once forgotten, as after it failed to '
          'start', () async {
        File('${root.path}/second/claude').writeAsStringSync('#!/bin/sh\n');
        use();
        expect(
          (await CliLocator.locate()).executable,
          '${root.path}/second/claude',
        );

        File('${root.path}/first/claude').writeAsStringSync('#!/bin/sh\n');
        expect(
          (await CliLocator.locate()).executable,
          '${root.path}/second/claude',
        );
        CliLocator.forget();
        expect(
          (await CliLocator.locate()).executable,
          '${root.path}/first/claude',
        );
      }, skip: Platform.isWindows);
    });

    test(
      'none that runs: not installed, naming the ones that do not',
      () async {
        final root = await Directory.systemTemp.createTemp('baocode-locator-');
        addTearDown(() => root.delete(recursive: true));
        addTearDown(() => CliLocator.candidatesOverride = null);
        final broken = File('${root.path}/claude')
          ..writeAsStringSync(placeholder);
        CliLocator.candidatesOverride = (_) => [broken.path];
        CliLocator.use({'PATH': '/nowhere', 'HOME': root.path});

        await expectLater(
          CliLocator.locate(),
          throwsA(
            isA<ClaudeNotInstalled>().having(
              (error) => error.detail,
              'detail',
              contains(broken.path),
            ),
          ),
        );
      },
    );

    test('Volta\'s shim is passed over for its package\'s build', () async {
      final root = await Directory.systemTemp.createTemp('baocode-locator-');
      addTearDown(() => root.delete(recursive: true));
      final volta = p.join(root.path, 'Volta');
      final bin = p.join(volta, 'bin');
      final environment = {'LOCALAPPDATA': root.path};

      // No build in Volta's image: the shim is left to the PATH's turn.
      expect(CliLocator.behindVolta(bin, environment), isNull);

      final exe = File(
        p.join(
          volta,
          'tools',
          'image',
          'packages',
          '@anthropic-ai',
          'claude-code',
          'node_modules',
          '@anthropic-ai',
          'claude-code',
          'bin',
          'claude.exe',
        ),
      )..createSync(recursive: true);
      expect(CliLocator.behindVolta(bin, environment), exe.path);
      expect(CliLocator.behindVolta(bin, {'VOLTA_HOME': volta}), exe.path);
      // Another PATH directory is no Volta's.
      expect(CliLocator.behindVolta(root.path, environment), isNull);
    });

    test('a program is told from a script left in its place', () async {
      final root = await Directory.systemTemp.createTemp('baocode-locator-');
      addTearDown(() => root.delete(recursive: true));
      File file(String name, List<int> bytes) =>
          File('${root.path}/$name')..writeAsBytesSync(bytes);
      // A PE image: MZ, and at 0x40, as offset 0x3C says, PE\0\0.
      final pe = Uint8List(0x48)
        ..setAll(0, 'MZ'.codeUnits)
        ..[0x3C] = 0x40
        ..setAll(0x40, [0x50, 0x45, 0, 0, 0x64, 0x86]);
      final dosOnly = Uint8List.fromList(pe)..[0x41] = 0;

      expect(
        CliLocator.runnable(file('pe.exe', pe).path, windows: true),
        isTrue,
      );
      expect(
        CliLocator.runnable(file('dos.exe', dosOnly).path, windows: true),
        isFalse,
      );
      expect(
        CliLocator.runnable(
          file('claude.exe', utf8.encode(placeholder)).path,
          windows: true,
        ),
        isFalse,
      );
      expect(
        CliLocator.runnable(file('claude.cmd', const []).path, windows: true),
        isTrue,
      );

      for (final (name, bytes) in [
        ('script', utf8.encode('#!/bin/sh\n')),
        ('elf', [0x7F, 0x45, 0x4C, 0x46, 2]),
        ('macho', [0xCF, 0xFA, 0xED, 0xFE, 7]),
        ('universal', [0xCA, 0xFE, 0xBA, 0xBE, 0]),
      ]) {
        expect(
          CliLocator.runnable(file(name, bytes).path, windows: false),
          isTrue,
          reason: name,
        );
      }
      expect(
        CliLocator.runnable(
          file('placeholder', utf8.encode(placeholder)).path,
          windows: false,
        ),
        isFalse,
      );
      expect(
        CliLocator.runnable(file('empty', const []).path, windows: false),
        isFalse,
      );
    });

    test('under WSL, Windows\' own build is passed over', () {
      // As WSL 2 mounts the drives.
      const mounts =
          'none /dev/shm tmpfs rw,nosuid,nodev 0 0\n'
          'drivers /usr/lib/wsl/drivers 9p ro,aname=drivers;fmask=222 0 0\n'
          'C:\\134 /mnt/c 9p rw,noatime,aname=drvfs;path=C:\\;uid=1000 0 0\n'
          'E: /mnt/e drvfs rw,noatime 0 0\n';
      final drives = CliLocator.windowsDrivesIn(mounts);
      expect(drives, ['/mnt/c', '/mnt/e']);
      expect(
        CliLocator.onWindowsDrive(
          '/mnt/c/Users/me/AppData/Roaming/npm/claude',
          drives: drives,
        ),
        isTrue,
      );
      expect(
        CliLocator.onWindowsDrive('/home/me/.local/bin/claude', drives: drives),
        isFalse,
      );
      expect(
        CliLocator.onWindowsDrive('/mnt/cache/claude', drives: drives),
        isFalse,
      );
      expect(CliLocator.onWindowsDrive('/mnt/c/claude', drives: []), isFalse);
    });
  });

  group('the shell environment', () {
    late Directory root;
    setUp(() async {
      root = await Directory.systemTemp.createTemp('baocode-shell-');
      ClaudeEnvironment.use(null);
    });
    tearDown(() async {
      ClaudeEnvironment.shellOverride = null;
      ClaudeEnvironment.use(null);
      await root.delete(recursive: true);
    });

    /// A shell that says how it was asked (ASKED: its first flag), running
    /// the command it is given after [rc].
    void shell(String rc) {
      final file = File('${root.path}/shell')
        ..writeAsStringSync('''
#!/bin/sh
ASKED="\$1"; export ASKED
eval "command=\\\${\$#}"
$rc
exec /bin/sh -c "\$command"
''');
      Process.runSync('chmod', ['+x', file.path]);
      ClaudeEnvironment.shellOverride = file.path;
    }

    test('is asked as a terminal window is, interactive', () async {
      shell('echo "rc says hi"');
      expect((await ClaudeEnvironment.of())['ASKED'], '-i');
    }, skip: Platform.isWindows);

    test('is asked as a login shell alone when interactive fails', () async {
      shell('[ "\$ASKED" = -i ] && exit 1');
      expect((await ClaudeEnvironment.of())['ASKED'], '-l');
    }, skip: Platform.isWindows);

    test('is read up to its end, not up to what an rc file left running '
        'with its output', () async {
      shell('sleep 10 &');
      final asked = await ClaudeEnvironment.of().timeout(
        const Duration(seconds: 5),
      );
      expect(asked['ASKED'], '-i');
    }, skip: Platform.isWindows);

    // A function bash exports (environment modules' `ml`) is a value of
    // more than one line: cut at the first, the terminal's bash fails to
    // read it in.
    const function = '() {  eval "\$(lmod)"\n  x=1\n}';
    const exportFunction = r'''
FUNC="$(printf '() {  eval "$(lmod)"\n  x=1\n}')"; export FUNC''';

    test('keeps a value of more than one line whole', () async {
      shell(exportFunction);
      final asked = await ClaudeEnvironment.of();
      expect(asked['FUNC'], function);
      expect(asked.keys.where((name) => name.contains(' ')), isEmpty);
    }, skip: Platform.isWindows);

    test('keeps it whole from an env that cannot print NUL-separated '
        '(BusyBox\'s)', () async {
      final bin = Directory('${root.path}/bin')..createSync();
      final env = File('${bin.path}/env')
        ..writeAsStringSync('''
#!/bin/sh
[ "\$1" = -0 ] && exit 1
exec /usr/bin/env "\$@"
''');
      Process.runSync('chmod', ['+x', env.path]);
      shell('$exportFunction; PATH="${bin.path}:\$PATH"; export PATH');
      final asked = await ClaudeEnvironment.of();
      expect(asked['FUNC'], function);
      expect(asked.keys.where((name) => name.contains(' ')), isEmpty);
      expect(asked['PATH'], startsWith(bin.path));
    }, skip: Platform.isWindows);
  });

  group('Claude Code storage', () {
    test('reads the sessions where the login shell keeps them', () async {
      final root = await Directory.systemTemp.createTemp('baocode-storage-');
      addTearDown(() => root.delete(recursive: true));
      addTearDown(() => ClaudeEnvironment.use(null));
      final config = '${root.path}/config';
      final cwd = '${root.path}/project';
      Directory(cwd).createSync(recursive: true);
      File('$config/projects/-p/session-1.jsonl')
        ..createSync(recursive: true)
        ..writeAsStringSync(
          '${jsonEncode({
            'type': 'user',
            'uuid': 'aaaaaaaa-1111-4111-8111-111111111111',
            'cwd': cwd,
            'message': {'role': 'user', 'content': 'list the files'},
          })}\n',
        );
      ClaudeEnvironment.use({'CLAUDE_CONFIG_DIR': config});

      final projects = await const ClaudeStorage().projects();
      expect(projects.map((project) => project.path), [cwd]);
      expect(projects.single.sessions.single.title, 'list the files');
    });

    test('a session is titled as the user named it, else as Claude Code '
        'did, else after its first message', () async {
      final root = await Directory.systemTemp.createTemp('baocode-storage-');
      addTearDown(() => root.delete(recursive: true));
      final config = '${root.path}/config';
      final cwd = '${root.path}/project';
      Directory(cwd).createSync(recursive: true);
      void session(String id, List<Map<String, Object?>> titles) =>
          File('$config/projects/-p/$id.jsonl')
            ..createSync(recursive: true)
            ..writeAsStringSync(
              [
                {
                  'type': 'user',
                  'uuid': 'aaaaaaaa-1111-4111-8111-111111111111',
                  'cwd': cwd,
                  'message': {'role': 'user', 'content': 'list the files'},
                },
                ...titles,
              ].map((line) => '${jsonEncode(line)}\n').join(),
            );
      session('generated', [
        {'type': 'ai-title', 'aiTitle': 'List files', 'sessionId': 'g'},
        {'type': 'ai-title', 'aiTitle': 'List project files', 'sessionId': 'g'},
      ]);
      session('named', [
        {'type': 'custom-title', 'customTitle': 'Files', 'sessionId': 'n'},
        {'type': 'ai-title', 'aiTitle': 'List files', 'sessionId': 'n'},
      ]);
      session('untitled', [
        {'type': 'ai-title', 'aiTitle': '  ', 'sessionId': 'u'},
      ]);

      final projects = await ClaudeStorage(configDir: config).projects();
      expect(
        {
          for (final session in projects.single.sessions)
            session.id: session.title,
        },
        {
          'generated': 'List project files',
          'named': 'Files',
          'untitled': 'list the files',
        },
      );
    });

    test('a session is dated by its last message, and titled past the '
        'placeholders its images are sent with', () async {
      final root = await Directory.systemTemp.createTemp('baocode-storage-');
      addTearDown(() => root.delete(recursive: true));
      final config = '${root.path}/config';
      final cwd = '${root.path}/project';
      Directory(cwd).createSync(recursive: true);
      const image = {
        'type': 'image',
        'source': {'type': 'base64', 'media_type': 'image/png', 'data': ''},
      };
      void session(String id, List<Object?> content) =>
          File('$config/projects/-p/$id.jsonl')
            ..createSync(recursive: true)
            ..writeAsStringSync(
              [
                {
                  'type': 'user',
                  'uuid': 'aaaaaaaa-1111-4111-8111-111111111111',
                  'cwd': cwd,
                  'timestamp': '2026-09-27T08:00:00.000Z',
                  'message': {'role': 'user', 'content': content},
                },
                {
                  'type': 'assistant',
                  'cwd': cwd,
                  'timestamp': '2026-09-27T08:05:00.000Z',
                  'message': {'role': 'assistant', 'content': []},
                },
                // Written after: not a message.
                {'type': 'ai-title', 'aiTitle': '  ', 'sessionId': id},
              ].map((line) => '${jsonEncode(line)}\n').join(),
            );
      session('captioned', [
        {'type': 'text', 'text': '[Image #1]'},
        image,
        {'type': 'text', 'text': 'what is wrong here'},
      ]);
      session('images', [
        {'type': 'text', 'text': '[Image #1]'},
        image,
      ]);

      final sessions = (await ClaudeStorage(
        configDir: config,
      ).projects()).single.sessions;
      expect(
        {for (final s in sessions) s.id: s.title},
        {'captioned': 'what is wrong here', 'images': ''},
      );
      expect(
        sessions.map((s) => s.updatedAt),
        everyElement(DateTime.utc(2026, 9, 27, 8, 5).toLocal()),
      );
    });

    test('a session is listed past the notes sent ahead of what was typed, '
        'and by a command typed with what it is to do', () async {
      final root = await Directory.systemTemp.createTemp('baocode-storage-');
      addTearDown(() => root.delete(recursive: true));
      final config = '${root.path}/config';
      final cwd = '${root.path}/project';
      Directory(cwd).createSync(recursive: true);
      void session(String id, Object content) =>
          File('$config/projects/-p/$id.jsonl')
            ..createSync(recursive: true)
            ..writeAsStringSync(
              '${jsonEncode({
                'type': 'user',
                'uuid': 'aaaaaaaa-1111-4111-8111-111111111111',
                'cwd': cwd,
                'message': {'role': 'user', 'content': content},
              })}\n',
            );
      // As the app sends them: the notes first, what was typed last.
      session('editor', [
        {
          'type': 'text',
          'text':
              '<system-reminder>The user has lib/a.dart open in the '
              'editor. This may or may not be related to the current '
              'task.</system-reminder>',
        },
        {'type': 'text', 'text': 'fix the crash'},
      ]);
      session('phone', [
        {'type': 'text', 'text': '[Image #1]'},
        {
          'type': 'image',
          'source': {'type': 'base64', 'media_type': 'image/png', 'data': ''},
        },
        {
          'type': 'text',
          'text':
              '<system-reminder>The user is now writing to you from the '
              'BaoCode app on their phone.</system-reminder>',
        },
        {'type': 'text', 'text': 'why is this red\n[Image #1]'},
      ]);
      session('goal', [
        {
          'type': 'text',
          'text':
              '<command-name>/goal</command-name>\n'
              '            <command-message>goal</command-message>\n'
              '            <command-args>fix #149 and #148</command-args>',
        },
      ]);
      session(
        'design',
        '<command-message>design</command-message>\n'
            '<command-name>/design</command-name>\n'
            '<command-args>a settings page</command-args>',
      );
      // Not what the user asked: no conversation to list.
      session(
        'model',
        '<command-name>/model</command-name>\n'
            '<command-args></command-args>',
      );
      session('notes', [
        {
          'type': 'text',
          'text':
              '<system-reminder>The user no longer has a file open in the '
              'editor.</system-reminder>',
        },
      ]);

      final sessions = (await ClaudeStorage(
        configDir: config,
        cacheFile: '${root.path}/cache.json',
      ).projects()).single.sessions;
      expect(
        {for (final s in sessions) s.id: s.title},
        {
          'editor': 'fix the crash',
          'phone': 'why is this red',
          'goal': '/goal fix #149 and #148',
          'design': '/design a settings page',
        },
      );
    });

    test('a session file is read again only once it changes, and the cache '
        'keeps only the files still there', () async {
      final root = await Directory.systemTemp.createTemp('baocode-storage-');
      addTearDown(() => root.delete(recursive: true));
      final config = p.join(root.path, 'config');
      final cwd = p.join(root.path, 'project');
      final cacheFile = p.join(root.path, 'cache', 'claude-sessions.json');
      Directory(cwd).createSync(recursive: true);
      File write(String id, String prompt) =>
          File(p.join(config, 'projects', '-p', '$id.jsonl'))
            ..createSync(recursive: true)
            ..writeAsStringSync(
              '${jsonEncode({
                'type': 'user',
                'uuid': 'aaaaaaaa-1111-4111-8111-111111111111',
                'cwd': cwd,
                'timestamp': '2026-09-27T08:00:00.000Z',
                'message': {'role': 'user', 'content': prompt},
              })}\n',
            );
      final storage = ClaudeStorage(configDir: config, cacheFile: cacheFile);
      Future<Map<String, String>> titles() async => {
        for (final s in (await storage.projects()).single.sessions)
          s.id: s.title,
      };

      final first = write('one', 'aaaa');
      final modified = first.lastModifiedSync();
      write('two', 'gone soon');
      expect(await titles(), {'one': 'aaaa', 'two': 'gone soon'});

      // Same size, same time: taken as unchanged.
      write('one', 'bbbb').setLastModifiedSync(modified);
      File(p.join(config, 'projects', '-p', 'two.jsonl')).deleteSync();
      expect(await titles(), {'one': 'aaaa'});
      final kept = jsonDecode(File(cacheFile).readAsStringSync()) as Map;
      expect((kept['files'] as Map).keys, [first.path]);

      write('one', 'grown longer');
      expect(await titles(), {'one': 'grown longer'});

      // One not to trust is started over.
      File(cacheFile).writeAsStringSync('{not json');
      expect(await titles(), {'one': 'grown longer'});
    });

    test('a session file appended to is read on from where it was read, '
        'its titles and last message taken from what came', () async {
      final root = await Directory.systemTemp.createTemp('baocode-storage-');
      addTearDown(() => root.delete(recursive: true));
      final config = '${root.path}/config';
      final cwd = '${root.path}/project';
      final cacheFile = '${root.path}/cache/claude-sessions.json';
      Directory(cwd).createSync(recursive: true);
      final file = File('$config/projects/-p/one.jsonl')
        ..createSync(recursive: true);
      void append(List<Map<String, Object?>> lines) => file.writeAsStringSync(
        lines.map((line) => '${jsonEncode(line)}\n').join(),
        mode: FileMode.append,
      );
      final storage = ClaudeStorage(configDir: config, cacheFile: cacheFile);
      Future<SessionRecord> session() async =>
          (await storage.projects()).single.sessions.single;

      append([
        {
          'type': 'user',
          'message': {'role': 'user', 'content': 'first'},
          'cwd': cwd,
          'timestamp': '2026-09-27T08:00:00.000Z',
        },
      ]);
      expect((await session()).title, 'first');

      // Changed where it was read already, not at its end: not read again.
      final read = file.readAsStringSync();
      file.writeAsStringSync(read.replaceFirst('first', 'xxxxx'));
      append([
        {
          'type': 'assistant',
          'cwd': cwd,
          'timestamp': '2026-09-27T09:00:00.000Z',
          'message': {'role': 'assistant', 'content': []},
        },
      ]);
      var kept = await session();
      expect(kept.title, 'first');
      expect(kept.updatedAt, DateTime.utc(2026, 9, 27, 9).toLocal());

      append([
        {'type': 'ai-title', 'aiTitle': 'Generated', 'sessionId': 'one'},
      ]);
      expect((await session()).title, 'Generated');
      append([
        {'type': 'custom-title', 'customTitle': 'Named', 'sessionId': 'one'},
      ]);
      expect((await session()).title, 'Named');

      append([
        {'type': 'ai-title', 'aiTitle': 'Generated again', 'sessionId': 'one'},
      ]);
      expect((await session()).title, 'Named');
      append([
        {'type': 'custom-title', 'customTitle': ' ', 'sessionId': 'one'},
      ]);
      expect((await session()).title, 'Generated again');

      // Written over from the start, not appended to: read whole again.
      file.writeAsStringSync(
        '${jsonEncode({
          'type': 'user',
          'cwd': cwd,
          'timestamp': '2026-09-27T10:00:00.000Z',
          'message': {'role': 'user', 'content': 'rewritten from the start, '
              'longer than it was before'},
        })}\n',
      );
      kept = await session();
      expect(kept.title, 'rewritten from the start, longer than it was before');
      expect(kept.updatedAt, DateTime.utc(2026, 9, 27, 10).toLocal());
    });

    test(
      'the app\'s data path wins, and the CLI is told to keep state there',
      () async {
        final root = await Directory.systemTemp.createTemp('baocode-storage-');
        addTearDown(() => root.delete(recursive: true));
        addTearDown(() => ClaudeEnvironment.use(null));
        final mine = '${root.path}/mine';
        final theirs = '${root.path}/theirs';
        final cwd = '${root.path}/project';
        Directory(cwd).createSync(recursive: true);
        File('$mine/projects/-p/session-1.jsonl')
          ..createSync(recursive: true)
          ..writeAsStringSync(
            '${jsonEncode({
              'type': 'user',
              'uuid': 'aaaaaaaa-1111-4111-8111-111111111111',
              'cwd': cwd,
              'message': {'role': 'user', 'content': 'mine'},
            })}\n',
          );
        final environment = {
          'BAOCODE_CLAUDE_DATA_PATH': mine,
          'CLAUDE_CONFIG_DIR': theirs,
        };
        ClaudeEnvironment.use(environment);

        final projects = await const ClaudeStorage().projects();
        expect(projects.map((project) => project.path), [cwd]);
        expect(projects.single.sessions.single.title, 'mine');
        expect(ClaudeEnvironment.stateDirectory(environment), {
          'CLAUDE_CONFIG_DIR': mine,
        });
      },
    );

    test(
      'deleting a session removes all of it, and only it, idempotently',
      () async {
        final root = await Directory.systemTemp.createTemp('baocode-storage-');
        addTearDown(() => root.delete(recursive: true));
        final config = '${root.path}/config';
        final temp = '${root.path}/tmp';
        const id = 'aaaaaaaa-1111-4111-8111-111111111111';
        const other = 'bbbbbbbb-2222-4222-8222-222222222222';
        final kept = [
          for (final session in [id, other]) ...[
            '$config/projects/-p/$session.jsonl',
            '$config/projects/-p/$session/subagents/agent-1.jsonl',
            '$config/file-history/$session/1@v1',
            '$config/session-env/$session/env',
            '$temp/claude-501/-p/$session/tasks/t.output',
          ],
        ];
        for (final path in kept) {
          File(path).createSync(recursive: true);
        }
        final storage = ClaudeStorage(configDir: config, tempDir: temp);

        await storage.delete(id);
        await storage.delete(id);
        final left = [
          for (final entity in Directory(root.path).listSync(recursive: true))
            if (entity is File) entity.path,
        ];
        expect(left.where((path) => path.contains(id)), isEmpty);
        expect(left.where((path) => path.contains(other)), hasLength(5));
        expect(
          storage.delete('../projects'),
          throwsArgumentError,
          reason: 'only a session id names what goes',
        );
      },
    );

    test('a fork copies the conversation up to a message, apart', () async {
      final root = await Directory.systemTemp.createTemp('baocode-storage-');
      addTearDown(() => root.delete(recursive: true));
      final config = p.join(root.path, 'config');
      const id = 'aaaaaaaa-1111-4111-8111-111111111111';
      const into = 'bbbbbbbb-2222-4222-8222-222222222222';
      Map<String, Object?> line(String type, String uuid, String? parent) => {
        'type': type,
        'uuid': uuid,
        'parentUuid': parent,
        'sessionId': id,
        'message': {'role': type, 'content': uuid},
      };
      final original = File(p.join(config, 'projects', '-p', '$id.jsonl'))
        ..createSync(recursive: true)
        ..writeAsStringSync(
          [
            line('user', 'u1', null),
            line('assistant', 'a1', 'u1'),
            // A branch left by a rewind: not on the way to the end.
            line('user', 'old', 'a1'),
            line('user', 'u2', 'a1'),
            line('assistant', 'a2', 'u2'),
            {'type': 'custom-title', 'customTitle': 'Mine', 'sessionId': id},
          ].map((line) => '${jsonEncode(line)}\n').join(),
        );
      final before = original.readAsStringSync();
      final storage = ClaudeStorage(configDir: config);
      List<Map<String, Object?>> read(String path) => [
        for (final line in File(path).readAsLinesSync())
          (jsonDecode(line) as Map).cast<String, Object?>(),
      ];

      final path = await storage.fork(id, into, title: 'Mine (fork)');
      expect(path, p.join(config, 'projects', '-p', '$into.jsonl'));
      final all = read(path);
      expect(all.map((e) => e['uuid'] ?? e['customTitle']), [
        'u1',
        'a1',
        'u2',
        'a2',
        'Mine (fork)',
      ]);
      expect(all.map((e) => e['sessionId']), everyElement(into));
      expect(original.readAsStringSync(), before);

      final cut = await storage.fork(id, into, before: 'u2', title: 'Cut');
      expect(read(cut).map((e) => e['uuid'] ?? e['customTitle']), [
        'u1',
        'a1',
        'Cut',
      ]);
      expect(storage.fork(id, into, before: 'nope'), throwsStateError);
      expect(storage.fork('../p', into), throwsArgumentError);
    });

    test('a folder\'s sessions move to another\'s, with what is kept beside '
        'them and its memory; a folder dashed alike keeps its own', () async {
      final root = await Directory.systemTemp.createTemp('baocode-move-');
      addTearDown(() => root.delete(recursive: true));
      final config = '${root.path}/config';
      final from = '${root.path}/old/app';
      final alike = '${root.path}/old-app';
      final to = '${root.path}/new/app';
      Directory(to).createSync(recursive: true);
      String dir(String cwd) =>
          '$config/projects/${cwd.replaceAll(RegExp('[^a-zA-Z0-9]'), '-')}';
      void session(String id, String cwd) => File('${dir(from)}/$id.jsonl')
        ..createSync(recursive: true)
        ..writeAsStringSync(
          [
            {'type': 'custom-title', 'customTitle': 'T', 'sessionId': id},
            {
              'type': 'user',
              'cwd': cwd,
              'message': {'role': 'user', 'content': 'hi'},
            },
            {'type': 'assistant', 'cwd': '$cwd/lib', 'message': {}},
          ].map((line) => '${jsonEncode(line)}\n').join(),
        );
      session('mine', from);
      session('theirs', alike);
      File('${dir(from)}/mine/subagents/a.jsonl').createSync(recursive: true);
      File('${dir(from)}/memory/MEMORY.md').createSync(recursive: true);

      final moved = await ClaudeStorage(configDir: config)
          .moveSessions(from, to);

      expect(moved, 1);
      final file = File('${dir(to)}/mine.jsonl');
      final lines = [
        for (final line in file.readAsLinesSync())
          (jsonDecode(line) as Map).cast<String, Object?>(),
      ];
      // The child path joined the way this machine joins it: a Windows one
      // has its own separator between the folder and `lib`.
      expect(lines.map((line) => line['cwd']), [null, to, p.join(to, 'lib')]);
      expect(lines.first['customTitle'], 'T');
      expect(File('${dir(to)}/mine/subagents/a.jsonl').existsSync(), isTrue);
      expect(File('${dir(to)}/memory/MEMORY.md').existsSync(), isTrue);
      expect(File('${dir(from)}/mine.jsonl').existsSync(), isFalse);
      expect(File('${dir(from)}/theirs.jsonl').existsSync(), isTrue);
    });
  });

  group('control channel', () {
    test('matches responses to requests, and fails the rest', () async {
      final written = <Map<String, Object?>>[];
      final channel = ControlChannel(written.add);
      final ok = channel.request('get_plan');
      final refused = channel.request('mcp_status');
      final orphan = channel.request('interrupt');
      String id(int i) => written[i]['request_id'] as String;
      channel
        ..receive({
          'type': 'control_response',
          'response': {
            'subtype': 'success',
            'request_id': id(0),
            'response': {'exists': false},
          },
        })
        ..receive({
          'type': 'control_response',
          'response': {
            'subtype': 'error',
            'request_id': id(1),
            'error': 'nope',
          },
        })
        ..failAll('gone');
      expect(await ok, {'exists': false});
      await expectLater(refused, throwsA(isA<ControlError>()));
      await expectLater(orphan, throwsA(isA<ControlError>()));
      expect(channel.receive({'type': 'user'}), isFalse);
    });

    test(
      'a request that times out is refused, so the CLI lets it go',
      () async {
        final written = <Map<String, Object?>>[];
        final channel = ControlChannel(written.add);
        await expectLater(
          channel.request(
            'mcp_status',
            const {},
            const Duration(milliseconds: 20),
          ),
          throwsA(isA<ControlError>()),
        );
        // The CLI is still waiting for an answer: told, so it does not
        // hold the turn open for ever.
        final refusal = written.last;
        expect(refusal['type'], 'control_response');
        final response = refusal['response'] as Map;
        expect(response['subtype'], 'error');
        expect(response['request_id'], written.first['request_id']);
      },
    );
  });

}


/// Turns kept in memory, by session and prompt.
class _KeptTurns implements TurnStats {
  final Map<String, Map<String, TurnRecord>> sessions = {};

  @override
  void write(String sessionId, String turnId, TurnRecord record) =>
      (sessions[sessionId] ??= {})[turnId] = record;

  @override
  Future<Map<String, TurnRecord>> read(String sessionId) async =>
      sessions[sessionId] ?? const {};
}
