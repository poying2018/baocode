import 'package:baocode/chat/chat_models.dart';
import 'package:baocode/kernel/agent_kernel.dart';
import 'package:baocode/kernel/claude_code/claude_code_kernel.dart';
import 'package:baocode/kernel/mock/mock_kernels.dart';
import 'package:baocode/kernel/transcript.dart';
import 'package:baocode/models/model_provider.dart';
import 'package:baocode/models/model_providers.dart';
import 'package:bao_remote/claude.dart' show ClaudeHistoryPage;
import 'package:flutter_test/flutter_test.dart';

import '../kernel_test.dart' show FakeCli;

// Two upstreams with a model of one id, as relays often have.
const _first = ModelProvider(
  id: 'ap',
  name: 'apicc',
  protocol: ProviderProtocol.openaiResponses,
  baseUrl: 'https://ap.example.com/v1',
  models: [ProviderModel(id: 'gpt-6.1-sol', label: 'apicc GPT-6.1')],
);

const _second = ModelProvider(
  id: 'fx',
  name: 'fluxapi',
  protocol: ProviderProtocol.openaiResponses,
  baseUrl: 'https://fx.example.com/v1',
  models: [
    ProviderModel(id: 'gpt-6.1-sol', label: 'fluxapi GPT-6.1'),
    ProviderModel(id: 'gpt-6.1-mini'),
  ],
);

const _providers = [_first, _second];

void agent(FakeCli cli, String id) => cli.push({
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

void said(FakeCli cli, String parent, String model) => cli.push({
  'type': 'assistant',
  'parent_tool_use_id': parent,
  'message': {
    'id': 'msg-$parent',
    'role': 'assistant',
    'model': model,
    'content': [
      {'type': 'text', 'text': 'looking'},
    ],
  },
});

String? modelOf(Transcript transcript, String id) => [
  for (final (key, item) in transcript.liveItems)
    if (key == id && item is AgentItem) item.model,
].single;

void main() {
  test('a subagent\'s model, a bare id, is the upstream\'s the session is '
      'on, not the first with a model of that id', () async {
    late FakeCli cli;
    final kernel = ClaudeCodeKernel(
      MockKernels.claudeCode,
      const KernelContext(cwd: '/p', settings: {'model': '@fx/gpt-6.1-sol'}),
      start: (_) async => cli = FakeCli(),
      providers: ModelProviders.memory(providers: _providers),
      providerEnvironment: (provider, model) async => {
        'ANTHROPIC_BASE_URL': 'http://proxy/${provider.id}',
      },
    );
    addTearDown(kernel.dispose);
    final transcript = Transcript();
    kernel.events.listen(transcript.apply);
    kernel.prepare();
    await pumpEventQueue();

    agent(cli, 'a1');
    said(cli, 'a1', 'gpt-6.1-sol');
    // Another upstream's, set for subagents: the proxy sent it there.
    agent(cli, 'a2');
    said(cli, 'a2', '@ap/gpt-6.1-sol');
    // None of the session's upstream: as it is.
    agent(cli, 'a3');
    said(cli, 'a3', 'glm-5.3');
    await pumpEventQueue();

    expect(modelOf(transcript, 'a1'), '@fx/gpt-6.1-sol');
    expect(modelOf(transcript, 'a2'), '@ap/gpt-6.1-sol');
    expect(modelOf(transcript, 'a3'), 'glm-5.3');
  });

  test('a kept session replays with the same subagent model', () async {
    final history = <Map<String, Object?>>[
      {
        'type': 'assistant',
        'parent_tool_use_id': null,
        'message': {
          'id': 'msg-a1',
          'role': 'assistant',
          'content': [
            {
              'type': 'tool_use',
              'id': 'a1',
              'name': 'Agent',
              'input': {'description': 'Look a1', 'prompt': 'look'},
            },
          ],
        },
      },
      {
        'type': 'assistant',
        'parent_tool_use_id': 'a1',
        'message': {
          'id': 'msg-a1',
          'role': 'assistant',
          'model': 'gpt-6.1-sol',
          'content': [
            {'type': 'text', 'text': 'looking'},
          ],
        },
      },
    ];
    final kernel = ClaudeCodeKernel(
      MockKernels.claudeCode,
      KernelContext(
        cwd: '/p',
        settings: const {'model': '@fx/gpt-6.1-sol'},
        resume: SessionRecord(
          id: 's',
          title: 't',
          updatedAt: DateTime(2026),
          cwd: '/p',
        ),
      ),
      start: (_) async => FakeCli(),
      providers: ModelProviders.memory(providers: _providers),
      readHistoryPage: (session, {required turns, before}) async =>
          ClaudeHistoryPage(history),
    );
    addTearDown(kernel.dispose);
    final transcript = Transcript();
    kernel.events.listen(transcript.apply);
    await pumpEventQueue();

    expect(modelOf(transcript, 'a1'), '@fx/gpt-6.1-sol');
  });
}
