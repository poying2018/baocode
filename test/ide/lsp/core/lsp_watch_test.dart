/// The watcher under a workspace root: it sees what changes, a folder
/// deep, and a root that is gone is no news rather than an error.
///
/// It runs on every platform: Linux's inotify watches one folder at a
/// time, so the tree is watched folder by folder there, and the platform
/// watches it as a whole elsewhere.
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:baocode/ide/lsp/lsp_process.dart';
import 'package:path/path.dart' as p;

import '../../../fixtures/lsp/fake_lsp.dart';

void main() {
  late Directory dir;

  setUp(() {
    dir = Directory.systemTemp.createTempSync('baocode-lsp-watch');
  });
  tearDown(() {
    if (dir.existsSync()) dir.deleteSync(recursive: true);
  });

  test('a folder that is gone is watched as nothing, not as an error', () async {
    final events = watchLspDirectory(p.join(dir.path, 'no-such-folder'));
    expect(events, emitsDone);
  });

  test('a change under a folder is seen, a folder deep', () async {
    final deep = Directory(p.join(dir.path, 'a', 'b'))
      ..createSync(recursive: true);
    final seen = <String>[];
    final subscription = watchLspDirectory(dir.path).listen(
      (event) => seen.add(event.path),
    );
    addTearDown(subscription.cancel);
    final file = File(p.join(deep.path, 'written.txt'));
    // The watcher may not be in place yet: the change is made again
    // until it is seen.
    final deadline = DateTime.now().add(const Duration(seconds: 20));
    while (!seen.any((path) => path.endsWith('written.txt'))) {
      if (DateTime.now().isAfter(deadline)) {
        fail('the change was never seen: $seen');
      }
      file.writeAsStringSync('hello ${DateTime.now()}');
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
  });
}
