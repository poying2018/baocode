/// Helpers for running [fake_lsp_server.dart] under an [LspManager].
library;

import 'dart:async';
import 'dart:io';

import 'package:baocode/ide/lsp/lsp_protocol.dart';
import 'package:baocode/ide/lsp/lsp_server_definition.dart';
import 'package:path/path.dart' as p;

/// The fake server's source, run by `dart` directly (it starts in a
/// fraction of a second).
final String fakeServerScript = p.absolute(
  'test',
  'fixtures',
  'lsp',
  'fake_lsp_server.dart',
);

/// An absolute `dart`, so starting does not depend on the child's PATH.
final String dartExecutable = () {
  if (Platform.environment['FLUTTER_ROOT'] case final root?) {
    // Windows spells it `dart.exe`; the extensionless path is not there.
    for (final name in ['dart', 'dart.exe']) {
      final dart = p.join(root, 'bin', 'cache', 'dart-sdk', 'bin', name);
      if (File(dart).existsSync()) return dart;
    }
  }
  final found = _which('dart');
  return found.isEmpty ? 'dart' : found;
}();

/// [name]'s own path, as the machine's `where` or `which` says it.
String _which(String name) {
  final result = Platform.isWindows
      ? Process.runSync('where', [name])
      : Process.runSync('which', [name]);
  if (result.exitCode != 0) return '';
  return '${result.stdout}'.split('\n').first.trim();
}

LspServerDefinition fakeServer(
  String id, {
  JsonMap options = const {},
  JsonMap? settings,
  List<String> rootMarkers = const [],
  bool requiredRoot = false,
  Set<LspFeature>? onlyFeatures,
  Set<LspFeature>? exceptFeatures,
  String? masonPackage,
  List<String> args = const [],
}) => LspServerDefinition(
  id: id,
  command: 'dart',
  args: [fakeServerScript, ...args],
  initializationOptions: {'name': id, ...options},
  settings: settings,
  rootMarkers: rootMarkers,
  requiredRoot: requiredRoot,
  onlyFeatures: onlyFeatures,
  exceptFeatures: exceptFeatures,
  masonPackage: masonPackage,
);

/// Files ending in `.fake` are the `fake` language, served by [servers].
class FakeCatalog implements LspCatalog {
  FakeCatalog(
    List<LspServerDefinition> definitions, {
    List<String>? servers,
    this.rootMarkers = const [],
  }) : definitions = {for (final d in definitions) d.id: d},
       servers = servers ?? [for (final d in definitions) d.id];

  final Map<String, LspServerDefinition> definitions;
  final List<String> servers;
  final List<String> rootMarkers;

  @override
  LspLanguage? languageFor(String path, {String? firstLine}) =>
      path.endsWith('.fake')
      ? LspLanguage(
          id: 'fake',
          fileTypes: const ['fake'],
          servers: servers,
          rootMarkers: rootMarkers,
        )
      : null;

  @override
  LspServerDefinition? server(String id) => definitions[id];
}

/// Finds `dart` for every server, unless it is [missing] (until installed).
class FakeProvider implements LspServerProvider {
  FakeProvider({Set<String>? missing, this.missingRuntime, this.failInstall})
    : missing = missing ?? {};

  final Set<String> missing;
  final String? missingRuntime;
  final String? failInstall;
  final installs = <String>[];
  Completer<void>? installGate;

  @override
  Future<LspServerLocation> locate(LspServerDefinition server) async =>
      missing.contains(server.id)
      ? LspServerMissing(
          package: server.masonPackage,
          missingRuntime: missingRuntime,
        )
      : LspServerFound(dartExecutable);

  @override
  Future<void> install(
    String package, {
    void Function(String message)? onProgress,
  }) async {
    installs.add(package);
    onProgress?.call('Downloading $package');
    if (installGate case final gate?) await gate.future;
    if (failInstall case final message?) {
      throw LspInstallException(message, detail: 'exit 1');
    }
    onProgress?.call('Installed $package');
    missing.removeWhere((id) => id == package || '$id-pkg' == package);
  }
}

/// Waits until [condition] holds, polling.
Future<void> until(
  FutureOr<bool> Function() condition, {
  Duration timeout = const Duration(seconds: 15),
  String? reason,
}) async {
  final deadline = DateTime.now().add(timeout);
  while (!await condition()) {
    if (DateTime.now().isAfter(deadline)) {
      throw TimeoutException(reason ?? 'condition not met', timeout);
    }
    await Future<void>.delayed(const Duration(milliseconds: 20));
  }
}

/// Whether process [pid] still runs (a zombie counts as gone).
bool processRunning(int pid) {
  if (Platform.isWindows) {
    // The task list says of it, and its name.
    final result = Process.runSync('tasklist', ['/FI', 'PID eq $pid', '/NH']);
    if (result.exitCode != 0) return false;
    final text = '${result.stdout}';
    return text.contains(' $pid ') || text.contains('\t$pid\t');
  }
  final result = Process.runSync('ps', ['-o', 'stat=', '-p', '$pid']);
  final stat = '${result.stdout}'.trim();
  return result.exitCode == 0 && stat.isNotEmpty && !stat.startsWith('Z');
}
