import 'dart:async';
import 'dart:io';

import 'package:path/path.dart' as p;

import '../agent_kernel.dart';
import '../../platform/data_dir.dart';
import '../../remote/remote_codex.dart';
import '../../remote/remote_location.dart';
import '../../remote/ssh_host.dart';
import 'codex_transport.dart';
import 'codex_process_transport.dart';

/// The transport a Codex kernel talks over: the app-server as a local
/// process.
abstract final class CodexTransportFactory {
  /// The transports in use, by the folder their server keeps its state
  /// in: one server for the app, not one for every question.
  static final Map<String, CodexTransport> _shared = {};
  static final Set<String> _seeded = {};

  /// App-servers actually started: none before the first request.
  static int get running => _shared.values
      .whereType<_StartingCodexTransport>()
      .where((transport) => transport.running)
      .length;

  /// The servers of remote hosts, whose end with the app matters there.
  static int get remoteRunning => _shared.entries
      .where((entry) => entry.key.startsWith('remote:'))
      .map((entry) => entry.value)
      .whereType<_StartingCodexTransport>()
      .where((transport) => transport.running)
      .length;

  /// Ends every app-server, local and remote: for when the app quits.
  static Future<void> stopAll() async {
    final live = [
      for (final transport in _shared.values)
        if (transport is _StartingCodexTransport && transport.running)
          transport,
    ];
    for (final transport in live) {
      transport.close();
    }
    await Future.wait([
      for (final transport in live)
        transport.exited.timeout(const Duration(seconds: 3), onTimeout: () {}),
    ]);
    _shared.clear();
  }

  /// The transport for a kernel that works in [context]'s directory.
  static CodexTransport of(KernelContext context) {
    final cwd = context.cwd ?? Directory.current.path;
    if (RemoteLocation.hostOf(cwd) case final host?) {
      return _shared.putIfAbsent(
        'remote:$host',
        () => _StartingCodexTransport(
          () =>
              startRemoteCodex(SshHosts.instance[host], CodexLaunch(cwd: cwd)),
        ),
      );
    }
    final home = _home();
    _seed(home);
    return _shared.putIfAbsent(
      home,
      () => _StartingCodexTransport(
        () => startCodexProcess(CodexLaunch(cwd: cwd, home: home)),
      ),
    );
  }

  /// Where the server keeps its state: the app's own folder, not the
  /// user's `~/.codex`. The Codex Desktop app holds that one while it
  /// runs, and a second server cannot start at all while it does.
  static String _home() => p.join(DataDirectory.current.path, 'codex');

  /// The user's Codex settings, copied into the app's own folder: models,
  /// login, providers and hooks are what make the installed CLI work the
  /// same way here. Its sessions and live state are left where they are.
  static void _seed(String home) {
    if (!_seeded.add(home)) return;
    final source = switch (Platform.environment['CODEX_HOME']) {
      final configured? when configured.trim().isNotEmpty => configured,
      _ => p.join(
        Platform.environment['USERPROFILE'] ??
            Platform.environment['HOME'] ??
            '',
        '.codex',
      ),
    };
    if (source.isEmpty || p.equals(source, home)) return;
    try {
      Directory(home).createSync(recursive: true);
    } on FileSystemException {
      return;
    }
    for (final name in const [
      'config.toml',
      'auth.json',
      'magpie-models.json',
      'models.json',
      'hooks.json',
      'cc-switch-model-catalog.json',
      'instructions.md',
      'AGENTS.md',
    ]) {
      final from = File(p.join(source, name));
      if (!from.existsSync()) continue;
      final to = File(p.join(home, name));
      if (name == 'auth.json' && to.existsSync()) continue;
      try {
        from.copySync(to.path);
      } on FileSystemException {
        // A file another Codex has open is not a reason to refuse to
        // start: the copy already there, if any, is used.
      }
    }
  }
}

/// A transport that starts the app-server when the first message is
/// written: the process is not started for a kernel that is never used.
class _StartingCodexTransport implements CodexTransport {
  _StartingCodexTransport(this._startTransport);

  final Future<CodexTransport> Function() _startTransport;
  final StreamController<Map<String, Object?>> _messages =
      StreamController<Map<String, Object?>>.broadcast();
  final Completer<void> _exited = Completer<void>();

  CodexTransport? _transport;
  Future<CodexTransport>? _starting;
  bool _closing = false;

  bool get running => _transport != null;

  @override
  Stream<Map<String, Object?>> get messages => _messages.stream;

  @override
  Future<void> get exited => _exited.future;

  @override
  List<String> get stderr => _transport?.stderr ?? const [];

  @override
  void restart() {
    // The process it had is gone: the next write starts a new one.
    _closing = true;
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
  Future<Map<String, Object?>> request(
    String method, [
    Map<String, Object?> params = const {},
  ]) async {
    final transport = await _started();
    return transport.request(method, params);
  }

  @override
  void close() {
    _closing = true;
    final transport = _transport;
    if (transport == null) {
      if (!_exited.isCompleted) _exited.complete();
      if (!_messages.isClosed) unawaited(_messages.close());
      return;
    }
    transport.close();
    unawaited(
      transport.exited.whenComplete(() {
        if (!_exited.isCompleted) _exited.complete();
        if (!_messages.isClosed) unawaited(_messages.close());
      }),
    );
  }

  /// The process, started: its messages are ours, and its end is ours.
  Future<CodexTransport> _started() {
    if (_transport case final transport?) return Future.value(transport);
    return _starting ??= _start();
  }

  Future<CodexTransport> _start() async {
    _closing = false;
    final transport = await _startTransport();
    _transport = transport;
    transport.messages.listen(
      (message) {
        if (!_messages.isClosed) _messages.add(message);
      },
      onError: (Object error) {
        if (!_messages.isClosed) _messages.addError(error);
      },
      onDone: () {
        // A process ending is not the end of the transport: the next
        // request may start another. Only close() closes the stream.
        _transport = null;
        _starting = null;
        if (!_closing && !_messages.isClosed) {
          _messages.addError(
            const CodexUnavailable(
              'Codex stopped',
              detail: 'Start it again to continue this conversation.',
            ),
          );
        }
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
