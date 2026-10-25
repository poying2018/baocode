import 'dart:async';
import 'dart:convert';

import 'package:bao_remote/client.dart';

import '../kernel/codex/codex_transport.dart';
import 'remote_location.dart';
import 'ssh_host.dart';

/// Codex on the host of a remote project: the same JSON-RPC app-server,
/// reached through that host's BaoCode server.
Future<CodexTransport> startRemoteCodex(
  SshHost host,
  CodexLaunch launch,
) async {
  final RemoteClient client;
  try {
    client = await host.ready;
  } on Object catch (error) {
    throw CodexUnavailable(
      'Could not connect to ${host.host}',
      detail: '$error',
    );
  }
  final cwd = RemoteLocation.pathOf(launch.cwd);
  try {
    final process = await client.start(
      'codex',
      launch.arguments,
      cwd: cwd,
      environment: launch.environment,
    );
    return await RemoteCodexTransport.start(process);
  } on CodexUnavailable {
    rethrow;
  } on Object catch (error) {
    throw CodexUnavailable(
      'Codex is not available on ${host.host}',
      detail:
          '$error\n\nInstall it there with '
          '"npm install -g @openai/codex".',
    );
  }
}

/// `codex app-server` on a remote host: NDJSON over a remote process.
class RemoteCodexTransport implements CodexTransport {
  RemoteCodexTransport._(this._process) {
    _process.stdout
        .transform(const Utf8Decoder(allowMalformed: true))
        .transform(const LineSplitter())
        .listen(_line, onError: _undecodable, onDone: _stdoutDone);
    _process.stderr
        .transform(const Utf8Decoder(allowMalformed: true))
        .transform(const LineSplitter())
        .listen(_stderrLine, onError: _undecodable);
    unawaited(
      _process.exitCode.then((code) {
        _exitCode = code;
        for (final waiting in _waiting.values) {
          if (!waiting.isCompleted) {
            waiting.completeError(
              const CodexRequestError('Codex on the remote host stopped'),
            );
          }
        }
        _waiting.clear();
        if (!_started.isCompleted) {
          _started.completeError(
            const CodexUnavailable('Codex on the remote host did not start'),
          );
        }
        if (!_finished.isCompleted) _finished.complete();
      }),
    );
  }

  static Future<RemoteCodexTransport> start(RemoteProcess process) async {
    final transport = RemoteCodexTransport._(process);
    transport.write({
      'id': 0,
      'method': 'initialize',
      'params': {
        'clientInfo': {'name': 'baocode', 'version': '1.0.0'},
        'capabilities': {'experimentalApi': true},
      },
    });
    await transport._started.future.timeout(
      const Duration(seconds: 10),
      onTimeout: () {
        transport.close();
        throw const CodexUnavailable('Codex on the remote host did not start');
      },
    );
    return transport;
  }

  final RemoteProcess _process;
  final Completer<void> _started = Completer<void>();
  final Completer<void> _finished = Completer<void>();
  final StreamController<Map<String, Object?>> _messages =
      StreamController.broadcast();
  final Map<Object, Completer<Map<String, Object?>>> _waiting = {};
  final List<String> _stderr = [];
  int _requests = 0;
  int? _exitCode;

  @override
  Stream<Map<String, Object?>> get messages => _messages.stream;

  @override
  Future<void> get exited => _finished.future;

  @override
  List<String> get stderr => List.unmodifiable(_stderr);

  void _line(String line) {
    if (line.trim().isEmpty) return;
    try {
      final decoded = jsonDecode(line);
      if (decoded is Map<String, Object?> && !_messages.isClosed) {
        _messages.add(decoded);
      }
      // An answer to a request of ours — and only that: a message with a
      // "method" is the server's own (a notification, or a request it
      // makes of us, e.g. an approval), and it may carry the very id one
      // of our requests has. The server's ids and ours are of the same
      // space, so what tells them apart is the shape, not the number.
      if (decoded is Map &&
          !decoded.containsKey('method') &&
          (decoded.containsKey('result') || decoded.containsKey('error'))) {
        final id = decoded['id'];
        final waiting = id == null ? null : _waiting.remove(id);
        if (waiting != null && !waiting.isCompleted) {
          if (decoded['error'] case final Map error) {
            waiting.completeError(
              CodexRequestError('${error['message'] ?? 'failed'}'),
            );
          } else {
            waiting.complete(
              (decoded['result'] as Map?)?.cast<String, Object?>() ?? const {},
            );
          }
        }
      }
      if (decoded is Map &&
          decoded['id'] == 0 &&
          !_started.isCompleted &&
          (decoded.containsKey('result') || decoded.containsKey('error'))) {
        if (decoded['error'] case final Map error) {
          _started.completeError(
            CodexUnavailable(
              'Codex could not be initialized',
              detail: '${error['message'] ?? error}',
            ),
          );
        } else if (decoded.containsKey('result')) {
          write({'method': 'initialized'});
          _started.complete();
        }
      }
    } on FormatException {
      _stderrLine(line);
    }
  }

  void _stderrLine(String line) {
    _stderr.add(line);
    if (_stderr.length > 30) _stderr.removeAt(0);
  }

  void _undecodable(Object error) => _stderrLine('$error');

  void _stdoutDone() {
    if (!_messages.isClosed) unawaited(_messages.close());
  }

  @override
  void write(Map<String, Object?> message) {
    if (_exitCode != null) return;
    _process.write(utf8.encode('${jsonEncode(message)}\n'));
  }

  @override
  Future<Map<String, Object?>> request(
    String method, [
    Map<String, Object?> params = const {},
  ]) {
    // The id is a string of our own: the server counts its own ids, and
    // they are of the same space as ours — a number of ours could be the
    // number of a request it makes of us, and then its answer and its
    // request would be mixed up.
    final id = 'baocode-${++_requests}';
    final answer = Completer<Map<String, Object?>>();
    _waiting[id] = answer;
    write({'id': id, 'method': method, 'params': params});
    return answer.future.timeout(
      const Duration(seconds: 60),
      onTimeout: () {
        _waiting.remove(id);
        throw CodexRequestError('$method timed out');
      },
    );
  }

  @override
  void restart() => close();

  @override
  void close() {
    if (_exitCode != null) return;
    unawaited(_process.closeStdin());
    _process.kill();
  }
}
