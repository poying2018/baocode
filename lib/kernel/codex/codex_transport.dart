/// Codex's side of the adapter (the Adaptee): JSON-RPC 2.0 with
/// `codex app-server` over stdio, one message per line.
abstract interface class CodexTransport {
  /// Responses (`id` + `result`), notifications (`method` + `params`) and
  /// server requests (`id` + `method` + `params`, e.g. approvals).
  Stream<Map<String, Object?>> get messages;

  /// Writes a request, or the response to a server request.
  void write(Map<String, Object?> message);

  /// Completes once the app-server is gone: it cannot answer any more.
  Future<void> get exited;

  /// The lines it printed on stderr, the last few: what it says when it
  /// could not start, or why it ended.
  List<String> get stderr;

  /// Starts it afresh: the process it had is gone, and a new one is
  /// started for the next write.
  void restart();

  void close();
}

/// How Codex is started: the project it works in, and the environment it
/// runs with.
class CodexLaunch {
  const CodexLaunch({
    required this.cwd,
    this.model,
    this.environment,
    this.home,
  });

  /// The project directory it works in.
  final String cwd;

  /// The model it starts with; the server's own default when none.
  final String? model;

  /// What it runs with, over the app's own.
  final Map<String, String>? environment;

  /// The folder its state is kept in, when it is not the user's own:
  /// the Codex Desktop app holds `~/.codex` while it runs, and a second
  /// server cannot start at all while it does.
  final String? home;

  /// The arguments `codex app-server` is started with.
  List<String> get arguments => const ['app-server', '--stdio'];
}

/// A request the server refused: its error, said.
class CodexRequestError implements Exception {
  const CodexRequestError(this.message);

  final String message;

  @override
  String toString() => message;
}

/// Codex is not there, or could not be run.
class CodexUnavailable implements Exception {
  const CodexUnavailable(this.message, {this.detail});

  final String message;
  final String? detail;

  @override
  String toString() => detail == null ? message : '$message\n$detail';
}
