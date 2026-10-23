import 'dart:async';
import 'dart:io';

import 'package:path/path.dart' as p;

import '../agent_kernel.dart';
import '../../platform/data_dir.dart';
import 'codex_transport.dart';
import 'codex_process_transport.dart';

/// The transport a Codex kernel talks over: the app-server as a local
/// process.
abstract final class CodexTransportFactory {
  /// The transport for a kernel that works in [context]'s directory.
  static CodexTransport of(KernelContext context) =>
      _StartingCodexTransport(
        CodexLaunch(
          cwd: context.cwd ?? Directory.current.path,
          home: _home(),
        ),
      );

  /// Where the server keeps its state: the app's own folder, not the
  /// user's `~/.codex`. The Codex Desktop app holds that one while it
  /// runs, and a second server cannot start at all while it does.
  static String _home() => p.join(DataDirectory.current.path, 'codex');
}

/// A transport that starts the app-server when the first message is
/// written: the process is not started for a kernel that is never used.
class _StartingCodexTransport implements CodexTransport {
  _StartingCodexTransport(this._launch);

  final CodexLaunch _launch;
  final StreamController<Map<String, Object?>> _messages =
      StreamController<Map<String, Object?>>.broadcast();
  final Completer<void> _exited = Completer<void>();

  CodexTransport? _transport;
  Future<CodexTransport>? _starting;

  @override
  Stream<Map<String, Object?>> get messages => _messages.stream;

  @override
  Future<void> get exited => _exited.future;

  @override
  List<String> get stderr => _transport?.stderr ?? const [];

  @override
  void restart() {
    // The process it had is gone: the next write starts a new one.
    _transport?.close();
    _transport = null;
    _starting = null;
  }

  @override
  void write(Map<String, Object?> message) {
    // The process starts on the first write: the initialize request.
    unawaited(
      _started().then(
        (transport) {
          transport.write(message);
        },
        onError: (Object error) {
          if (!_messages.isClosed) _messages.addError(error);
        },
      ),
    );
  }

  @override
  void close() {
    final transport = _transport;
    if (transport == null) {
      if (!_exited.isCompleted) _exited.complete();
      if (!_messages.isClosed) unawaited(_messages.close());
      return;
    }
    transport.close();
  }

  /// The process, started: its messages are ours, and its end is ours.
  Future<CodexTransport> _started() {
    if (_transport case final transport?) return Future.value(transport);
    return _starting ??= _start();
  }

  Future<CodexTransport> _start() async {
    final transport = await startCodexProcess(_launch);
    _transport = transport;
    transport.messages.listen(
      (message) {
        if (!_messages.isClosed) _messages.add(message);
      },
      onError: (Object error) {
        if (!_messages.isClosed) _messages.addError(error);
      },
      onDone: () {
        if (!_messages.isClosed) unawaited(_messages.close());
      },
    );
    unawaited(
      transport.exited.then((_) {
        if (!_exited.isCompleted) _exited.complete();
      }),
    );
    return transport;
  }
}
