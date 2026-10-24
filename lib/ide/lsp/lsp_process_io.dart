import 'dart:async';
import 'dart:io';

import 'package:bao_remote/local.dart' show WatchChange, watchRecursively;
import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:path/path.dart' as p;

import '../../kernel/claude_code/claude_environment.dart';
import '../../platform/data_dir.dart';
import '../../platform/child_process_registry.dart';
import 'lsp_process.dart';

/// A language server as a child process.
class _IoLspProcess implements LspProcess {
  _IoLspProcess(this._process) {
    LspProcesses._live.add(this);
    // Writes to a server that died fail here, not as uncaught errors.
    _process.stdin.done.then<void>((_) {}, onError: (Object _) {});
    unawaited(LspProcesses.registry.add(_process.pid));
    unawaited(
      _process.exitCode.then((_) {
        LspProcesses._live.remove(this);
        unawaited(LspProcesses.registry.remove(_process.pid));
      }),
    );
  }

  final Process _process;
  bool _stopRequested = false;
  bool _stdinClosed = false;

  @override
  int get pid => _process.pid;

  @override
  Stream<List<int>> get stdout => _process.stdout;

  @override
  Stream<List<int>> get stderr => _process.stderr;

  @override
  Future<int> get exitCode => _process.exitCode;

  @override
  bool get stopRequested => _stopRequested;

  @override
  void write(List<int> bytes) {
    if (_stdinClosed) return;
    _process.stdin.add(bytes);
  }

  @override
  Future<void> closeStdin() async {
    if (_stdinClosed) return;
    _stdinClosed = true;
    try {
      await _process.stdin.close();
    } on Object {
      // Gone already.
    }
  }

  @override
  void kill({bool force = false}) {
    _stopRequested = true;
    unawaited(closeStdin());
    if (Platform.isWindows) {
      // Killing a `.cmd` kills cmd.exe alone: the node it started goes on
      // serving. The tree goes with it, as taskkill's /T does.
      unawaited(_killTree(force: force));
      return;
    }
    _process.kill(force ? ProcessSignal.sigkill : ProcessSignal.sigterm);
  }

  /// Windows ends a killed process alone: a server started by its `.cmd`
  /// (npm's) would go on running node under the `cmd.exe` killed. Given
  /// time, it ends on its own; only a tree that holds on is taken hard.
  Future<void> _killTree({required bool force}) async {
    if (!force) {
      // Polite first, as on Unix: the server's own stdin close, then its
      // own exit; only its tree is killed hard, when it holds on.
      try {
        await _process.exitCode.timeout(const Duration(milliseconds: 500));
        return;
      } on TimeoutException {
        // Still running: take the tree.
      }
    }
    try {
      await Process.run('taskkill', ['/pid', '${_process.pid}', '/T', '/F']);
    } on ProcessException {
      // No taskkill on this machine: the process alone goes.
      try {
        _process.kill();
      } on Object {
        // It is already gone.
      }
    }
  }

  Future<void> _stop(Duration timeout) async {
    kill();
    try {
      await _process.exitCode.timeout(timeout);
    } on TimeoutException {
      kill(force: true);
      await _process.exitCode.timeout(timeout, onTimeout: () => 0);
    }
  }
}

abstract final class LspProcesses {
  /// Where the running servers are kept track of across runs.
  @visibleForTesting
  static ChildProcessRegistry registry = ChildProcessRegistry(
    file: File(DataDirectory.current.processRegistryFile('lsp')),
  );

  static final Set<_IoLspProcess> _live = {};

  static Future<LspProcess> start(LspLaunch launch) async {
    await registry.reaped;
    if (!Directory(launch.workingDirectory).existsSync()) {
      throw LspStartException(
        'The folder is gone',
        detail: launch.workingDirectory,
      );
    }
    final environment = {
      ...await ClaudeEnvironment.of(),
      ...launch.environment,
    };
    final executable = launch.executable;
    try {
      final process = await Process.start(
        executable,
        launch.arguments,
        workingDirectory: launch.workingDirectory,
        environment: environment,
        // As for Claude Code: the login shell's environment is the whole of
        // it, except on Windows.
        includeParentEnvironment: Platform.isWindows,
        // Not through the shell, even for a `.cmd`: Windows runs a batch
        // file itself, and the shell would split a path or an argument
        // that has a space in it (a folder under Program Files, a user
        // name with a space) — the server would not start at all.
      );
      return _IoLspProcess(process);
    } on ProcessException catch (error) {
      throw LspStartException(
        '${launch.serverId} could not start',
        detail: error.message,
      );
    }
  }

  /// Ends every server this run started, and waits (up to [timeout] each):
  /// polite first, then killed.
  static Future<void> stopAll({
    Duration timeout = const Duration(seconds: 2),
  }) async {
    await Future.wait([
      for (final process in [..._live]) process._stop(timeout),
    ]);
    // Their entries gone from the list before the app is.
    await registry.flush();
  }

  static Future<void> reapLeftovers() => registry.reaped;

  static Stream<LspFileEvent> watch(String root) {
    if (!FileSystemEntity.isWatchSupported) return const Stream.empty();
    // Linux's inotify watches one folder at a time, so the tree is
    // watched folder by folder there; elsewhere the platform watches it
    // as a whole. A root that is gone is no news: the watcher is empty
    // rather than an error thrown at the caller.
    return watchRecursively(root)
        .map(
          (event) => LspFileEvent(
            event.path,
            switch (event.change) {
              WatchChange.created => LspFileChangeType.created,
              WatchChange.modified => LspFileChangeType.changed,
              WatchChange.deleted => LspFileChangeType.deleted,
            },
          ),
        )
        .handleError((Object _) {});
  }

  static bool exists(String path) =>
      FileSystemEntity.typeSync(path) != FileSystemEntityType.notFound;

  static List<String> list(String path) {
    try {
      return [
        for (final entity in Directory(path).listSync())
          p.basename(entity.path),
      ];
    } on FileSystemException {
      return const [];
    }
  }

  static int? get ownPid => pid;
}
