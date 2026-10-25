@TestOn('mac-os || linux || windows')
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:baocode/platform/app_paths.dart';
import 'package:baocode/platform/data_dir.dart';
import 'package:path/path.dart' as p;

/// A copy of the app with an identity of its own keeps its data apart from
/// the others: a development build (BAOCODE_APP_ID) from the installed app,
/// and the codex product (whose executable is named for it) from the
/// Claude Code one.
void main() {
  const withId = {'BAOCODE_APP_ID': 'dev'};
  const without = <String, String>{};
  const platform = {
    'APPDATA': '/appdata',
    'USERPROFILE': '/home',
    'HOME': '/home',
  };

  test('the data folder of a copy with an id is its own', () {
    expect(p.basename(DataDirectory.defaultPath(withId)), 'baocode-dev');
    expect(p.basename(DataDirectory.defaultPath(without)), 'baocode');
  });

  test('the pointer of a copy with an id is its own', () {
    expect(
      DataDirectoryPointer.fileIn('/home', withId),
      p.join('/home', '.baocode-dev', 'config-dir.json'),
    );
    expect(
      DataDirectoryPointer.fileIn('/home', without),
      p.join('/home', '.baocode', 'config-dir.json'),
    );
  });

  test('a copy with an id does not follow the installed one\'s pointer', () {
    final resolution = resolveDataDirectory(
      environment: {...withId, ...platform},
      home: '/home',
    );
    // The pointer the installed one wrote is not this copy's: it goes to
    // its own folder, the one the platform has for it.
    expect(resolution.source, DataDirectorySource.defaultLocation);
    expect(resolution.path, p.join('/appdata', 'baocode-dev'));
  });

  test('a product named by its executable keeps its data apart', () {
    // The codex product's executable is baocode-codex.exe, so its folders
    // are its own: the Claude Code product's are untouched.
    expect(
      AppPaths.dataDir(platform, executable: 'baocode-codex.exe'),
      p.join('/appdata', 'baocode-codex'),
    );
    expect(
      AppPaths.dataDir(platform, executable: 'baocode.exe'),
      p.join('/appdata', 'baocode'),
    );
    // A name belonging to no product (a test host, a build named
    // otherwise) is BaoCode's.
    expect(
      AppPaths.dataDir(platform, executable: 'flutter_tester.exe'),
      p.join('/appdata', 'baocode'),
    );
  });

  test('the names a product shows are told apart', () {
    expect(AppPaths.product('baocode.exe'), 'baocode');
    expect(AppPaths.product('baocode-codex.exe'), 'baocode-codex');
    expect(AppPaths.displayName(without, executable: 'baocode'), 'BaoCode');
    expect(
      AppPaths.displayName(without, executable: 'baocode-codex'),
      'BaoCode Codex',
    );
    // A development copy of BaoCode says so.
    expect(
      AppPaths.displayName(withId, executable: 'baocode'),
      'BaoCode Dev',
    );
    // A name with a space in it is no product's: BaoCode's is.
    expect(AppPaths.product('BaoCode Codex'), 'baocode');
    expect(AppPaths.product('BaoCode Codex.app/Contents/MacOS/BaoCode'),
        'baocode');
  });

  test('the pointer of the codex product is its own', () {
    expect(
      DataDirectoryPointer.fileIn('/home', without, 'baocode-codex.exe'),
      p.join('/home', '.baocode-codex', 'config-dir.json'),
    );
    expect(
      DataDirectoryPointer.fileIn('/home', without, 'baocode.exe'),
      p.join('/home', '.baocode', 'config-dir.json'),
    );
  });

  test('only BaoCode carries Claude Code', () {
    // The codex product has no Claude Code to carry, and says nothing of
    // it: the two products are separate programs.
    expect(AppPaths.hasClaudeCode('baocode.exe'), isTrue);
    expect(AppPaths.hasClaudeCode('baocode-codex.exe'), isFalse);
    // A name belonging to no product (a test host, a build named
    // otherwise) is BaoCode's.
    expect(AppPaths.hasClaudeCode('flutter_tester.exe'), isTrue);
  });
}
