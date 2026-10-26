@TestOn('mac-os || linux || windows')
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:baocode/platform/data_dir.dart';
import 'package:path/path.dart' as p;

/// Where the data folder is found: `BAOCODE_DATA_DIR`, else the pointer in
/// `~/.baocode`, else the platform's place. Every home is a temporary one.
void main() {
  late Directory home;
  late Map<String, String> environment;

  setUp(() {
    home = Directory.systemTemp.createTempSync('baocode-home');
    environment = {'HOME': home.path};
  });
  tearDown(() {
    // Undo a read-only folder's mode, so it can go.
    if (!Platform.isWindows) {
      for (final entity in home.listSync(recursive: true)) {
        if (entity is Directory) {
          Process.runSync('chmod', ['755', entity.path]);
        }
      }
    }
    home.deleteSync(recursive: true);
  });

  File pointer() =>
      File(p.join(home.path, '.baocode', 'config-dir.json'))
        ..parent.createSync(recursive: true);

  /// The pointer saying [dataDir], written as JSON (a Windows path has
  /// backslashes, which JSON escapes).
  void pointAt(String dataDir) =>
      pointer().writeAsStringSync(jsonEncode({'dataDir': dataDir}));

  Directory folder(String name) =>
      Directory(p.join(home.path, name))..createSync(recursive: true);

  DataDirectoryResolution resolve() =>
      resolveDataDirectory(environment: environment, home: home.path);

  test('the platform default without a variable or pointer', () {
    final resolution = resolve();
    expect(resolution.ok, isTrue);
    expect(resolution.source, DataDirectorySource.defaultLocation);
    expect(resolution.path, DataDirectory.defaultPath(environment));
    expect(
      resolution.path,
      startsWith(home.path),
      reason: 'under the home it was given',
    );
    expect(
      resolution.pointerFile,
      p.join(home.path, '.baocode', 'config-dir.json'),
    );
  });

  test('the pointer, then the variable, win', () {
    final pointed = folder('Pointed');
    final variable = folder('Variable');
    pointAt(pointed.path);
    expect(
      (resolve().path, resolve().source),
      (pointed.path, DataDirectorySource.pointer),
    );

    environment['BAOCODE_DATA_DIR'] = variable.path;
    expect(
      (resolve().path, resolve().source),
      (variable.path, DataDirectorySource.environment),
    );
    expect(resolve().directory.path, variable.path);
  });

  test('~ is the home, in the pointer and the variable', () {
    folder('Data/baocode');
    pointer().writeAsStringSync('{"dataDir": "~/Data/baocode"}');
    expect(resolve().path, p.join(home.path, 'Data', 'baocode'));
    environment['BAOCODE_DATA_DIR'] = '~';
    expect(resolve().path, home.path);
    expect(expandDataDirectory(r'~\x', '/h'), p.join('/h', 'x'));
    expect(expandDataDirectory('/a/~', '/h'), '/a/~');
  });

  test('a pointer without dataDir (only the folder moved from) is the '
      'default', () {
    pointer().writeAsStringSync('{"previousDataDir": "/old"}');
    expect(resolve().source, DataDirectorySource.defaultLocation);
    expect(resolve().ok, isTrue);
  });

  test('an invalid pointer is reported, and left as it is', () {
    for (final text in [
      'not json',
      '[]',
      '{"dataDir": 3}',
      '{"dataDir": "relative/path"}',
    ]) {
      pointer().writeAsStringSync(text);
      final resolution = resolve();
      expect(resolution.ok, isFalse, reason: text);
      expect(resolution.problem, DataDirectoryProblem.invalidPointer);
      expect(resolution.error, contains('config-dir.json'));
      expect(resolution.path, resolution.defaultPath);
      expect(pointer().readAsStringSync(), text);
    }
  });

  test('a folder that is missing or read-only is reported, not replaced '
      'by the default', () {
    final gone = p.join(home.path, 'Volumes', 'D', 'BaoCode');
    pointAt(gone);
    var resolution = resolve();
    expect(resolution.ok, isFalse);
    expect(resolution.problem, DataDirectoryProblem.missing);
    expect(resolution.path, gone);
    expect(resolution.source, DataDirectorySource.pointer);
    expect(Directory(gone).existsSync(), isFalse, reason: 'not made');

    final file = File(p.join(home.path, 'file'))..writeAsStringSync('');
    environment['BAOCODE_DATA_DIR'] = file.path;
    expect(resolve().problem, DataDirectoryProblem.missing);

    final readOnly = folder('ReadOnly');
    if (!Platform.isWindows) {
      // Windows has no such permission: the folder is writable there.
      Process.runSync('chmod', ['555', readOnly.path]);
      environment['BAOCODE_DATA_DIR'] = readOnly.path;
      resolution = resolve();
      expect(resolution.problem, DataDirectoryProblem.notWritable);
      expect(resolution.source, DataDirectorySource.environment);
    }
  });

  test('the layout', () {
    const dir = DataDirectory('/data');
    // The paths are the machine's own: the data folder is a local one.
    String at(String parts) => p.joinAll(['/data', ...parts.split('/')]);
    expect(dir.settingsFile, at('User/settings.json'));
    expect(dir.keybindingsFile, at('User/keybindings.json'));
    expect(dir.lspSettingsFile, at('User/lsp.json'));
    expect(dir.argvFile, at('argv.json'));
    expect(dir.keymapsDir, at('keymaps'));
    expect(dir.stateFile, at('state/state.json'));
    expect(dir.storageFile, at('state/storage.json'));
    expect(
      dir.processRegistryFile('claude'),
      at('state/claude-processes.json'),
    );
    expect(dir.serversDir, at('servers'));
    expect(dir.languagePacksDir, at('language-packs'));
  });

  test('under test, the current one is never the user\'s', () {
    expect(
      DataDirectory.current.path,
      isNot(DataDirectory.defaultPath(Platform.environment)),
    );
    expect(DataDirectory.current.path, startsWith(Directory.systemTemp.path));
  });

  test('the pointer is written whole, and removed when empty', () async {
    final file = pointer();
    await const DataDirectoryPointer(
      dataDir: '/new',
      previousDataDir: '/old',
    ).write(file);
    final read = DataDirectoryPointer.read(file)!;
    expect((read.dataDir, read.previousDataDir), ('/new', '/old'));
    expect(file.parent.listSync(), hasLength(1), reason: 'nothing aside');
    await const DataDirectoryPointer().write(file);
    expect(file.existsSync(), isFalse);
  });

  group('the pointer planted for the name this program is to be called', () {
    /// The environment such a build starts in: the home the test made. It
    /// is a function, not a value: `home` is only there once the setUp of
    /// the file has run, which is later than this group is declared.
    Map<String, String> claude() => {'HOME': home.path};

    /// The pointer such a plant lands on, named as that build would name it.
    File planted({String? id}) => File(
      p.join(
        home.path,
        '.baocode-claude${id == null ? '' : '-$id'}',
        'config-dir.json',
      ),
    );

    Future<File> plant({String? id}) => plantRenamedPointer(
      environment: {...claude(), 'BAOCODE_APP_ID': ?id},
      executable: 'baocode-claude.exe',
      dataDir: '/data/lives/here',
    ).then((_) => planted(id: id));

    test(
      'names the folder the renamed build reads, and where the data is',
      () async {
        final file = await plant();
        expect(file.existsSync(), isTrue);
        // The name is the one such a build's own executable answers to: its
        // binary, under the home, the same file the user's own move writes.
        expect(
          file.path,
          p.join(home.path, '.baocode-claude', 'config-dir.json'),
        );
        // And it is a pointer that build can read, saying this run's folder.
        expect(DataDirectoryPointer.read(file)?.dataDir, '/data/lives/here');
      },
    );

    test('a development copy plants beside its own pointer, not the '
        'installed one\'s', () async {
      final file = await plant(id: 'dev');
      expect(
        file.path,
        p.join(home.path, '.baocode-claude-dev', 'config-dir.json'),
      );
      expect(
        DataDirectoryPointer.read(planted())?.dataDir,
        isNull,
        reason: 'the installed one is none of its business',
      );
    });

    test(
      'a pointer from an earlier run follows the data to where it went',
      () async {
        // Planted when the data was in the old place; the user has since
        // moved it (Settings → Data directory), and this run reads and writes
        // where it went. Left as it was, it would send the renamed build to a
        // folder the data has left — the failure this exists to prevent.
        final there = planted()
          ..parent.createSync(recursive: true)
          ..writeAsStringSync(jsonEncode({'dataDir': '/moved/from'}));
        await plant();
        expect(DataDirectoryPointer.read(there)?.dataDir, '/data/lives/here');
      },
    );

    test(
      'a pointer that cannot be read is left for the app to report',
      () async {
        final broken =
            File(p.join(home.path, '.baocode-claude', 'config-dir.json'))
              ..parent.createSync(recursive: true)
              ..writeAsStringSync('not JSON');
        await plant();
        expect(broken.readAsStringSync(), 'not JSON');
      },
    );

    test(
      'nothing to plant for a product whose id already is its name',
      () async {
        await plantRenamedPointer(
          environment: claude(),
          executable: 'baocode-codex.exe',
          dataDir: '/data/lives/here',
        );
        expect(
          File(p.join(home.path, '.baocode-codex', 'config-dir.json'))
              .existsSync(),
          isFalse,
          reason: 'the codex product is not renamed, and writes nothing',
        );
      },
    );

    test('a test run never points the home at a folder that is gone by '
        'morning', () async {
      await plantRenamedPointer(
        environment: {...claude(), 'FLUTTER_TEST': 'true'},
        executable: 'baocode-claude.exe',
        dataDir: '/data/lives/here',
      );
      expect(
        File(p.join(home.path, '.baocode-claude', 'config-dir.json'))
            .existsSync(),
        isFalse,
      );
    });
  });
}
