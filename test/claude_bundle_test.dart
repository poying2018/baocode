import 'dart:convert';
import 'dart:io';

import 'package:bao_remote/local.dart';
import 'package:baocode/kernel/claude_code/claude_bundle.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

/// The Claude Code the app carries in its bundle: found where it is put,
/// run where the user has none of their own, and replaced by a newer one
/// when it is too old for what BaoCode asks of it.
void main() {
  late Directory home;

  setUp(() {
    home = Directory.systemTemp.createTempSync('baocode-bundle-');
  });
  tearDown(() {
    home.deleteSync(recursive: true);
  });

  /// A folder holding the Claude Code the app carries: the binary and the
  /// VERSION file naming it.
  Directory bundle({String version = '2.1.308', String name = 'claude.exe'}) {
    final directory = Directory(p.join(home.path, 'bundle'))
      ..createSync(recursive: true);
    File(p.join(directory.path, name)).writeAsStringSync('not a program');
    File(p.join(directory.path, 'VERSION')).writeAsStringSync('$version\n');
    return directory;
  }

  group('the copy in the bundle', () {
    test('is found by its VERSION and its binary', () {
      final found = BundledClaude.at(bundle().path);
      expect(found, isNotNull);
      expect(found!.version, '2.1.308');
      expect(p.basename(found.binary.path), 'claude.exe');
    });

    test('is the one the platform names, the .exe on Windows', () {
      final found = BundledClaude.at(bundle(name: 'claude').path);
      expect(found, isNotNull);
      expect(p.basename(found!.binary.path), 'claude');
    });

    test('is nothing without its VERSION', () {
      final directory = bundle();
      File(p.join(directory.path, 'VERSION')).deleteSync();
      expect(BundledClaude.at(directory.path), isNull);
    });

    test('is nothing without its binary', () {
      final directory = bundle();
      File(p.join(directory.path, 'claude.exe')).deleteSync();
      expect(BundledClaude.at(directory.path), isNull);
    });

    test('is nothing when its VERSION names a path', () {
      final directory = bundle();
      File(p.join(directory.path, 'VERSION')).writeAsStringSync('..\\evil\n');
      expect(BundledClaude.at(directory.path), isNull);
    });
  });

  group('where the app looks for it', () {
    test('where the environment says', () {
      final directory = bundle();
      final found = ClaudeBundle.find(
        environment: {ClaudeBundle.directoryVariable: directory.path},
        executable: p.join(home.path, 'nowhere', 'baocode.exe'),
        current: home.path,
      );
      expect(found?.version, '2.1.308');
    });

    test('beside the executable', () {
      final app = Directory(p.join(home.path, 'app'))..createSync();
      // The bundle sits in `claude\` beside the executable, as the
      // installer puts it.
      final carried = Directory(p.join(app.path, 'claude'))
        ..createSync(recursive: true);
      File(p.join(carried.path, 'claude.exe')).writeAsStringSync('not a program');
      File(p.join(carried.path, 'VERSION')).writeAsStringSync('2.1.308\n');
      final found = ClaudeBundle.find(
        environment: const {},
        executable: p.join(app.path, 'baocode.exe'),
        current: home.path,
      );
      expect(found?.version, '2.1.308');
    });

    test('nowhere, when the app carries none', () {
      final found = ClaudeBundle.find(
        environment: const {},
        executable: p.join(home.path, 'nowhere', 'baocode.exe'),
        current: home.path,
      );
      expect(found, isNull);
    });
  });

  group('running it', () {
    late _FakeReleases releases;
    late Directory data;

    setUp(() async {
      // flutter_test answers every HttpClient request with a 400.
      HttpOverrides.global = null;
      releases = await _FakeReleases.start('win32-x64');
      ClaudeRelease.baseOverride = releases.base;
      data = Directory(p.join(home.path, 'data'))..createSync();
      CliLocator.candidatesOverride = (_) => const [];
      CliLocator.use({'PATH': '', 'HOME': home.path});
    });
    tearDown(() async {
      ClaudeRelease.baseOverride = null;
      CliLocator.candidatesOverride = null;
      CliLocator.use(null);
      await releases.close();
    });

    ClaudeRuntime runtimeWith(BundledClaude? bundled) => ClaudeRuntime(
      managed: ManagedClaude(p.join(data.path, 'claude')),
      platform: 'win32-x64',
      bundled: bundled,
    );

    test('the copy the app carries is run, and nothing is downloaded', () async {
      final carried = BundledClaude.at(bundle().path)!;
      final runtime = runtimeWith(carried);
      final cli = await runtime.locate();
      expect(cli.executable, carried.binary.path);
      // Its updater off: it would put another in the user's `~/.local`.
      expect(cli.environment['DISABLE_AUTOUPDATER'], '1');
      // Nothing was downloaded for it.
      expect(releases.served, isEmpty);
      expect(runtime.isBundled(cli), isTrue);
      expect(runtime.isInstalled(cli), isFalse);
    });

    test('the newer of the two is run, the app\'s and the downloaded one', () async {
      final carried = BundledClaude.at(bundle().path)!;
      final runtime = runtimeWith(carried);
      // The one BaoCode downloaded is newer: it is run.
      final managed = runtime.managed;
      managed.binaryOf('2.5.0')
        ..createSync(recursive: true)
        ..writeAsStringSync('not a program');
      File(p.join(managed.directory, 'CURRENT')).writeAsStringSync('2.5.0\n');
      final cli = await runtime.locate();
      expect(cli.executable, managed.installed);
      expect(runtime.isBundled(cli), isFalse);
    });

    test('the app\'s is run where the downloaded one is older', () async {
      final carried = BundledClaude.at(bundle().path)!;
      final runtime = runtimeWith(carried);
      final managed = runtime.managed;
      managed.binaryOf('2.0.0')
        ..createSync(recursive: true)
        ..writeAsStringSync('not a program');
      File(p.join(managed.directory, 'CURRENT')).writeAsStringSync('2.0.0\n');
      final cli = await runtime.locate();
      expect(cli.executable, carried.binary.path);
    });

    test('a copy too old is left for a newer one, downloaded', () async {
      final carried = BundledClaude.at(bundle(version: '1.0.0').path)!;
      final runtime = runtimeWith(carried);
      // The copy in the bundle refused an option BaoCode starts it with.
      final again = await runtime.rejectTooOld(carried.binary.path);
      expect(again, isTrue);
      // A newer one was downloaded, and is run from then on.
      expect(releases.served, contains('/stable'));
      expect(runtime.managed.version, '9.9.9');
      final cli = await runtime.locate();
      expect(cli.executable, runtime.managed.installed);
    });

    test('a copy too old, with no newer one to be had, stays', () async {
      final carried = BundledClaude.at(bundle(version: '1.0.0').path)!;
      final runtime = runtimeWith(carried);
      releases.refuse = true;
      expect(await runtime.rejectTooOld(carried.binary.path), isFalse);
    });
  });
}

/// downloads.claude.ai as the app reads it: `/stable`, a version's
/// `manifest.json`, and its build for the platform.
class _FakeReleases {
  _FakeReleases._(this._server, this.platform);

  static Future<_FakeReleases> start(String platform) async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final releases = _FakeReleases._(server, platform);
    server.listen(releases._serve);
    return releases;
  }

  final HttpServer _server;
  final String platform;
  final List<String> served = [];
  final List<int> binary = utf8.encode('not a program');

  /// Every request refused, as for a machine without the internet.
  bool refuse = false;

  String get base => 'http://127.0.0.1:${_server.port}';

  Future<void> _serve(HttpRequest request) async {
    final path = request.uri.path;
    final response = request.response;
    if (refuse) {
      response.statusCode = HttpStatus.serviceUnavailable;
      await response.close();
      return;
    }
    served.add(path);
    if (path == '/stable') {
      response.write('9.9.9\n');
    } else if (path == '/9.9.9/manifest.json') {
      response.write(
        jsonEncode({
          'version': '9.9.9',
          'platforms': {
            platform: {
              'checksum': sha256.convert(binary).toString(),
              'size': binary.length,
            },
          },
        }),
      );
    } else if (path == '/9.9.9/$platform/claude.exe') {
      response.add(binary);
    } else {
      response.statusCode = HttpStatus.notFound;
    }
    await response.close();
  }

  Future<void> close() => _server.close(force: true);
}
