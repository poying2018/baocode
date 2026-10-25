import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:path/path.dart' as p;

import 'codex_transport.dart';

/// `codex app-server` as a local process: JSON-RPC 2.0 over its stdio, one
/// message per line.
class ProcessCodexTransport implements CodexTransport {
  ProcessCodexTransport._(this._process, {required this.executable}) {
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
            waiting.completeError(const CodexRequestError('Codex stopped'));
          }
        }
        _waiting.clear();
        // It ended before it was up: the one waiting to talk to it is
        // told, rather than waiting for nothing.
        if (!_started.isCompleted) {
          _started.completeError(
            const CodexUnavailable(
              'Codex ended before it was ready',
              detail: 'Another Codex may be running and holding its folder.',
            ),
          );
        }
        if (!_finished.isCompleted) _finished.complete();
      }),
    );
  }

  /// Starts `codex app-server` for [launch].
  static Future<ProcessCodexTransport> start(CodexLaunch launch) async {
    final cli = await locateCodex();
    final transport = await _start(cli, launch);
    // The server waits for the client to speak first: the initialize
    // request. It is said here, so that the server being up is known
    // and the kernel's own initialize is the second one (the server
    // answers it too).
    transport.write({
      'id': 0,
      'method': 'initialize',
      'params': {
        'clientInfo': {'name': 'baocode', 'version': '1.0.0'},
        // Some of the methods the adapter uses (collaboration modes,
        // permission profiles) are behind this switch.
        'capabilities': {'experimentalApi': true},
      },
    });
    // The server may not come up: another app may hold its home (the
    // Codex Desktop app does), and it says so and ends. The user would
    // wait for nothing, so it is said now.
    await transport._started.future.timeout(
      const Duration(seconds: 10),
      onTimeout: () {
        transport.close();
        throw const CodexUnavailable(
          'Codex did not start',
          detail:
              'Another Codex may be running and holding its folder. Close '
              'it and try again.',
        );
      },
    );
    return transport;
  }

  static Future<ProcessCodexTransport> _start(
    CodexExecutable cli,
    CodexLaunch launch,
  ) async {
    try {
      final process = await Process.start(
        cli.executable,
        [...?cli.arguments, ...launch.arguments],
        workingDirectory: launch.cwd,
        environment: {
          ...?cli.environment,
          // Its own state, when it was given one: the user's own
          // folder may be held by another Codex.
          'CODEX_HOME': ?launch.home,
        },
        // The app's own environment: the child needs HOME and PATH for
        // its login, MCP servers and tools, and on Windows also COMSPEC
        // and PATHEXT for the commands it runs.
        includeParentEnvironment: true,
        // Never through the shell: the npm shim is a `.cmd`, and the
        // shell concatenates its arguments rather than escaping them, so
        // a path with a space in it is split and the server never starts.
      );
      return ProcessCodexTransport._(process, executable: cli.executable);
    } on ProcessException catch (error) {
      throw CodexUnavailable(
        'Codex could not start',
        detail: '${cli.executable}\n${error.message}',
      );
    }
  }

  /// The `codex` to run: the real binary, not the npm shim.
  ///
  /// The shim (`codex.cmd`) is a batch file, and the shell concatenates
  /// its arguments rather than escaping them: a path with a space in it
  /// is split, and the server never starts. The binary behind it is
  /// found and run directly.
  static Future<CodexExecutable> locateCodex() async {
    // The Codex the user says to run, if they say one: a wrapper of
    // their own, a Codex of another version, or a stub of ours.
    if (command case final chosen?) return chosen;
    final configured = _configured();
    if (configured != null) return configured;
    for (final candidate in await _candidates()) {
      if (await _runs(candidate)) return candidate;
    }
    throw const CodexUnavailable(
      'Codex is not installed',
      detail:
          'Install it with "npm install -g @openai/codex", or run '
          '"codex app-server" yourself.',
    );
  }

  /// The environment variable that says which Codex to run: a command
  /// line, the way the user would type it.
  static const commandVariable = 'BAOCODE_CODEX_COMMAND';

  /// The Codex to run, whatever the search finds: for a test, and for a
  /// build that carries one of its own.
  @visibleForTesting
  static CodexExecutable? command;

  /// The command of the environment, when it is one that runs.
  static CodexExecutable? _configured() {
    final line = Platform.environment[commandVariable]?.trim();
    if (line == null || line.isEmpty) return null;
    final parts = line.split(RegExp(r'\s+'));
    return CodexExecutable(parts.first, arguments: parts.skip(1).toList());
  }

  /// Where the Codex CLI may be, best first.
  static Future<List<CodexExecutable>> _candidates() async {
    final found = <CodexExecutable>[];
    // The binary behind the npm shim: the one to actually run, and the
    // one the user installed for their terminal.
    for (final root in await _npmRoots()) {
      final binary = _vendorBinary(root);
      if (binary != null) found.add(CodexExecutable(binary));
    }
    // The one the user has, on the PATH.
    for (final directory in _pathDirectories()) {
      for (final name in const ['codex.exe', 'codex']) {
        final file = File(p.join(directory, name));
        if (await file.exists()) {
          found.add(CodexExecutable(file.path));
        }
      }
    }
    return found;
  }

  /// The `codex.exe` under a npm `@openai/codex` install, if there is one.
  static String? _vendorBinary(String root) {
    // The Desktop app's own copy: `<root>/codex.exe`.
    final direct = File(p.join(root, 'codex.exe'));
    if (direct.existsSync()) return direct.path;
    final package = Directory(p.join(root, '@openai', 'codex'));
    if (!package.existsSync()) return null;
    final vendor = Directory(p.join(package.path, 'node_modules', '@openai'));
    if (!vendor.existsSync()) return null;
    for (final platform in vendor.listSync()) {
      if (platform is! Directory) continue;
      if (!platform.path.contains('codex-')) continue;
      final found = _exesUnder(Directory(p.join(platform.path, 'vendor')));
      if (found != null) return found;
    }
    return null;
  }

  /// The `codex.exe` under [folder], the one that is the CLI itself (not
  /// the code-mode host or the sandbox setup).
  static String? _exesUnder(Directory folder) {
    if (!folder.existsSync()) return null;
    for (final entity in folder.listSync(recursive: true)) {
      if (entity is! File) continue;
      final name = p.basename(entity.path);
      if (name != 'codex.exe' && name != 'codex') continue;
      return entity.path;
    }
    return null;
  }

  /// The folders of the npm roots, where a global install lives.
  static Future<List<String>> _npmRoots() async {
    final roots = <String>{};
    for (final directory in _pathDirectories()) {
      // `<root>/node_modules/@openai/codex` is where npm puts a global
      // install; the shim beside it is `<root>/codex.cmd`.
      if (Directory(p.join(directory, 'node_modules', '@openai'))
          .existsSync()) {
        roots.add(p.join(directory, 'node_modules'));
      }
      // A local install, as a project has it.
      if (Directory(p.join(directory, '@openai')).existsSync()) {
        roots.add(directory);
      }
      // A Unix global install: `<prefix>/bin` is on the PATH while the
      // package lives in `<prefix>/lib/node_modules` or `<prefix>/node_modules`.
      final prefix = Directory(directory).parent.path;
      for (final modules in [
        p.join(prefix, 'lib', 'node_modules'),
        p.join(prefix, 'node_modules'),
      ]) {
        if (Directory(p.join(modules, '@openai')).existsSync()) {
          roots.add(modules);
        }
      }
    }
    for (final home in _homeDirectories()) {
      final roaming = p.join(home, 'AppData', 'Roaming');
      final npm = p.join(roaming, 'npm', 'node_modules');
      if (Directory(p.join(npm, '@openai')).existsSync()) {
        roots.add(npm);
      }
      final local = p.join(home, '.npm-global', 'lib', 'node_modules');
      if (Directory(p.join(local, '@openai')).existsSync()) {
        roots.add(local);
      }
      final usr = p.join(home, '.local', 'share');
      if (Directory(p.join(usr, '@openai')).existsSync()) {
        roots.add(usr);
      }
      // The Desktop app's own copy, under its own folder.
      final desktop = p.join(
        home,
        'AppData',
        'Local',
        'OpenAI',
        'Codex',
        'bin',
      );
      if (Directory(desktop).existsSync()) {
        for (final entry in Directory(desktop).listSync()) {
          if (entry is! Directory) continue;
          if (File(p.join(entry.path, 'codex.exe')).existsSync()) {
            roots.add(entry.path);
          }
        }
      }
    }
    return roots.toList();
  }

  static List<String> _pathDirectories() {
    final path = Platform.environment['PATH'] ?? '';
    return path
        .split(Platform.isWindows ? ';' : ':')
        .where((entry) => entry.isNotEmpty)
        .toList();
  }

  static List<String> _homeDirectories() {
    final home =
        Platform.environment['HOME'] ??
        Platform.environment['USERPROFILE'] ??
        '';
    return home.isEmpty ? const [] : [home];
  }

  /// Whether [candidate] is a CLI that answers: it prints its version.
  static Future<bool> _runs(CodexExecutable candidate) async {
    try {
      final result = await Process.run(
        candidate.executable,
        [...?candidate.arguments, '--version'],
        environment: candidate.environment,
        runInShell: false,
      );
      return result.exitCode == 0;
    } on ProcessException {
      return false;
    }
  }

  final Process _process;

  /// The CLI run, to name in a report of its failing.
  final String executable;

  final Completer<void> _finished = Completer<void>();
  final Completer<void> _started = Completer<void>();

  /// The requests under way, by their id: their answers.
  final Map<Object, Completer<Map<String, Object?>>> _waiting = {};
  int _requests = 0;
  final StreamController<Map<String, Object?>> _messages =
      StreamController.broadcast();

  /// The last lines it printed on stderr, to say why it failed.
  final List<String> _stderr = [];
  static const _stderrLines = 30;

  int? _exitCode;

  @override
  Stream<Map<String, Object?>> get messages => _messages.stream;

  @override
  Future<void> get exited => _finished.future;

  @override
  List<String> get stderr => List.unmodifiable(_stderr);

  /// A read error on either stream: kept as a stderr line, so that it is
  /// in the report when the process ends.
  void _undecodable(Object error) => _stderrLine('$error');

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
          final error = decoded['error'];
          if (error is Map) {
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
      // The server is up when it answers the initialize request. The
      // notification is sent before anyone else can write: the server
      // refuses every other method until it has it.
      if (decoded is Map &&
          decoded['id'] == 0 &&
          !_started.isCompleted &&
          (decoded.containsKey('result') || decoded.containsKey('error'))) {
        if (decoded['error'] case final error?) {
          final message = error is Map
              ? '${error['message'] ?? 'initialization failed'}'
              : '$error';
          _started.completeError(
            CodexUnavailable('Codex could not be initialized', detail: message),
          );
        } else if (decoded.containsKey('result')) {
          write({'method': 'initialized'});
          _started.complete();
        }
      }
    } on FormatException {
      // Not protocol (e.g. a warning printed on stdout): kept for the
      // failure report.
      _stderrLine(line);
    }
  }

  void _stderrLine(String line) {
    _stderr.add(line);
    if (_stderr.length > _stderrLines) _stderr.removeAt(0);
  }

  void _stdoutDone() {
    if (!_messages.isClosed) unawaited(_messages.close());
  }

  @override
  void write(Map<String, Object?> message) {
    if (_exitCode != null) return;
    try {
      _process.stdin.writeln(jsonEncode(message));
    } on StateError {
      // Closed under us: the exit follows.
    } on SocketException {
      // The process is gone: the exit follows.
    }
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
  void close() {
    if (_exitCode != null) return;
    unawaited(_process.stdin.close().catchError((_) {}));
    if (Platform.isWindows) {
      // Killing it alone leaves the MCP servers it started running.
      unawaited(_endTree());
    } else {
      _process.kill();
    }
  }

  @override
  void restart() {
    // The process is gone: a new one is started for the next write.
    close();
  }

  /// Windows ends a killed process alone: a server started by it (an MCP
  /// server) would go on running. Given a moment to end them itself, its
  /// input closed, then ended with all it started.
  Future<void> _endTree() async {
    final ended = await _process.exitCode
        .timeout(const Duration(seconds: 1))
        .then((_) => true, onError: (Object _) => false);
    if (ended) return;
    try {
      await Process.run('taskkill', ['/pid', '${_process.pid}', '/T', '/F']);
    } on ProcessException {
      _process.kill();
    }
  }
}

/// The `codex` to run, and the environment it runs with.
class CodexExecutable {
  const CodexExecutable(this.executable, {this.environment, this.arguments});

  final String executable;
  final Map<String, String>? environment;

  /// The arguments before the app-server's own, when the command is more
  /// than the program itself (a wrapper of the user's, say).
  final List<String>? arguments;
}
