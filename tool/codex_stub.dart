// A fake `codex app-server`: the app-server OpenAI's Codex CLI runs, as
// far as this app speaks it (JSON-RPC 2.0 over stdio, one message per
// line). It is for trying the app without a Codex of one's own, and for
// testing the adapter against a real process (a pipe, a process that
// ends, a request of the server's that carries a number of its own).
//
//   dart tool/codex_stub.dart              the app-server, on stdio
//   dart tool/codex_stub.dart --version    what a version check asks for
//
// The app runs it when the environment says which Codex to run:
//
//   $env:BAOCODE_CODEX_COMMAND = 'dart F:\Projects\baocode\tool\codex_stub.dart'
//
// What it answers: the handshake, the models, a thread, a turn (with a
// thought, a command that has to be approved, and a reply), the history,
// the MCP servers, the account's limits.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

/// The thread every conversation is on.
const _threadId = 'thr_stub';

/// The turn's own id, counted up.
int _turns = 0;

Future<void> main(List<String> arguments) async {
  if (arguments.contains('--version')) {
    stdout.writeln('codex-stub 0.1.0');
    return;
  }
  final lines = stdin
      .transform(const Utf8Decoder(allowMalformed: true))
      .transform(const LineSplitter());
  await for (final line in lines) {
    if (line.trim().isEmpty) continue;
    final Object? decoded;
    try {
      decoded = jsonDecode(line);
    } on FormatException {
      continue;
    }
    if (decoded is! Map) continue;
    final message = decoded.cast<String, Object?>();
    final id = message['id'];
    final method = message['method'] as String?;
    if (method == null) {
      // The client's answer to a request of ours.
      _answerReceived(id, message);
      continue;
    }
    final params = message['params'];
    await _handle(
      id,
      method,
      params is Map ? params.cast<String, Object?>() : const {},
    );
  }
}

/// The client's answer to the approval this server asked for.
void _answerReceived(Object? id, Map<String, Object?> message) {
  if (id == null) return;
  final decision = (message['result'] as Map?)?['decision'] as String?;
  if (decision == null) return;
  _approved = decision;
  unawaited(_finishTurn());
}

/// The decision the client gave, and the turn waiting for it.
String? _approved;
String? _pendingTurn;

/// The request the client has to answer before the turn goes on: the
/// server's own request, with a number of its own — the numbers the
/// server counts are of the same space as the client's, and a client that
/// takes a number for an answer mixes the two up.
const _approvalId = 1;

void _write(Map<String, Object?> message) {
  stdout.writeln(jsonEncode(message));
}

void _respond(Object? id, Map<String, Object?> result) =>
    _write({'id': id, 'result': result});

void _notify(String method, Map<String, Object?> params) =>
    _write({'method': method, 'params': params});

Future<void> _handle(
  Object? id,
  String method,
  Map<String, Object?> params,
) async {
  switch (method) {
    case 'initialize':
      _respond(id, {
        'userAgent': 'codex-stub',
        'capabilities': {'experimentalApi': true},
      });
    case 'initialized':
      // Nothing to answer.
      break;
    case 'model/list':
      _respond(id, {
        'data': [
          {
            'id': 'gpt-5.5-codex',
            'displayName': 'GPT-5.5 Codex',
            'description': 'Tuned for coding',
            'defaultReasoningEffort': 'medium',
            'isDefault': true,
            'inputModalities': ['text', 'image'],
            'supportedReasoningEfforts': [
              {'reasoningEffort': 'low', 'description': ''},
              {'reasoningEffort': 'medium', 'description': ''},
              {'reasoningEffort': 'high', 'description': ''},
            ],
            'serviceTiers': <Object?>[],
          },
        ],
        'nextCursor': null,
      });
    case 'thread/start':
      _respond(id, {
        'thread': {'id': _threadId, 'name': 'Stub conversation'},
        'model': 'gpt-5.5-codex',
        'modelProvider': 'openai',
        'reasoningEffort': 'medium',
      });
    case 'thread/resume':
      _respond(id, {
        'thread': {'id': _threadId, 'name': 'Stub conversation'},
        'model': 'gpt-5.5-codex',
      });
    case 'thread/name/set':
      _respond(id, {});
    case 'thread/fork':
      _respond(id, {
        'thread': {'id': 'thr_stub_fork', 'path': '/tmp/thr_stub_fork'},
      });
    case 'thread/revert':
      _respond(id, {'thread': {'id': _threadId}});
    case 'thread/turns/list':
      _respond(id, {'data': <Object?>[], 'nextCursor': null});
    case 'thread/list':
      _respond(id, {
        'data': [
          {
            'id': _threadId,
            'name': 'Stub conversation',
            'cwd': Directory.current.path,
            'updatedAt': 1800000000,
          },
        ],
        'nextCursor': null,
      });
    case 'turn/start':
      final turnId = 'turn_${++_turns}';
      _respond(id, {'turn': {'id': turnId, 'status': 'inProgress'}});
      unawaited(_runTurn(turnId, params));
    case 'turn/interrupt':
      _respond(id, {});
      final turn = _pendingTurn;
      if (turn != null) {
        _pendingTurn = null;
        _notify('turn/completed', {
          'threadId': _threadId,
          'turn': {'id': turn, 'status': 'interrupted'},
        });
      }
    case 'review/start':
      final turnId = 'turn_${++_turns}';
      _respond(id, {
        'turn': {'id': turnId, 'status': 'inProgress'},
        'reviewThreadId': _threadId,
      });
    case 'thread/compact/start':
      _respond(id, {});
    case 'mcpServerStatus/list':
      _respond(id, {'data': <Object?>[]});
    case 'account/rateLimits/read':
      _respond(id, {'rateLimits': <String, Object?>{}});
    case 'fuzzyFileSearch':
      _respond(id, {'files': <Object?>[]});
    default:
      _write({
        'id': id,
        'error': {'code': -32601, 'message': 'Unknown method $method'},
      });
  }
}

/// A turn: a thought, a command that has to be approved, and a reply.
Future<void> _runTurn(String turnId, Map<String, Object?> params) async {
  _pendingTurn = turnId;
  _notify('turn/started', {
    'threadId': _threadId,
    'turn': {'id': turnId, 'status': 'inProgress'},
  });
  // The thought, in pieces, the way the server sends it.
  const thought = '**Looking at it**\n\nThe file is small enough to read.';
  _notify('item/started', {
    'item': {'type': 'reasoning', 'id': 'r1', 'summary': <Object?>[]},
  });
  for (final part in thought.split(' ')) {
    _notify('item/reasoning/summaryTextDelta', {
      'threadId': _threadId,
      'turnId': turnId,
      'itemId': 'r1',
      'summaryIndex': 0,
      'delta': '$part ',
    });
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
  _notify('item/completed', {
    'item': {'type': 'reasoning', 'id': 'r1', 'summary': [thought]},
  });

  // The command: the server asks whether it may run it.
  _write({
    'id': _approvalId,
    'method': 'item/commandExecution/requestApproval',
    'params': {
      'threadId': _threadId,
      'turnId': turnId,
      'itemId': 'c1',
      'command': 'flutter test',
      'reason': 'Run the tests to check the change',
      'cwd': Directory.current.path,
    },
  });
}

/// The turn goes on once the client has answered the approval.
Future<void> _finishTurn() async {
  final turnId = _pendingTurn;
  if (turnId == null) return;
  _pendingTurn = null;
  final declined = _approved == 'decline';
  _notify('item/started', {
    'item': {
      'type': 'commandExecution',
      'id': 'c1',
      'command': 'flutter test',
      'cwd': '.',
      'status': 'inProgress',
      'commandActions': [
        {'type': 'unknown', 'command': 'flutter test'},
      ],
    },
  });
  _notify('item/completed', {
    'item': {
      'type': 'commandExecution',
      'id': 'c1',
      'command': 'flutter test',
      'cwd': '.',
      'status': declined ? 'declined' : 'completed',
      'aggregatedOutput': declined ? '' : 'All tests passed!',
      'exitCode': declined ? null : 0,
      'commandActions': [
        {'type': 'unknown', 'command': 'flutter test'},
      ],
    },
  });
  const reply = 'The tests pass.';
  _notify('item/started', {
    'item': {'type': 'agentMessage', 'id': 'm1', 'text': ''},
  });
  _notify('item/agentMessage/delta', {
    'threadId': _threadId,
    'turnId': turnId,
    'itemId': 'm1',
    'delta': reply,
  });
  _notify('item/completed', {
    'item': {'type': 'agentMessage', 'id': 'm1', 'text': reply},
  });
  _notify('thread/tokenUsage/updated', {
    'threadId': _threadId,
    'tokenUsage': {
      'total': {'totalTokens': 1200},
      'last': {'totalTokens': 1200},
      'modelContextWindow': 272000,
    },
  });
  _notify('turn/completed', {
    'threadId': _threadId,
    'turn': {'id': turnId, 'status': 'completed'},
  });
}
