import 'codex_transport.dart';

abstract final class ProcessCodexTransport {
  static Future<CodexTransport> start(CodexLaunch launch) async =>
      throw const CodexUnavailable(
        'Codex runs in the desktop app',
        detail: 'The browser cannot start local processes.',
      );
}
