import 'codex_transport.dart';
import 'codex_process_transport_stub.dart'
    if (dart.library.io) 'codex_process_transport_io.dart'
    as platform;

/// Starts Codex as a local process; on the web, where there are no
/// processes, fails saying so.
Future<CodexTransport> startCodexProcess(CodexLaunch launch) =>
    platform.ProcessCodexTransport.start(launch);
