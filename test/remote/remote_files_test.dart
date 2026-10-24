@TestOn('mac-os || linux || windows')
library;

import 'dart:io';

import 'package:bao_remote/client.dart';
import 'package:bao_remote/files.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import 'remote_harness.dart';

/// The server's files, through the client, against folders of this
/// machine: what a remote project's files do, without SSH. The parts
/// that need a POSIX shell are in `remote_server_test.dart`; these run
/// everywhere.
void main() {
  late RemoteHarness remote;
  late Directory project;
  late String root;

  setUp(() async {
    remote = await RemoteHarness.start();
    project = Directory.systemTemp.createTempSync('baocode-remote-files-');
    root = project.resolveSymbolicLinksSync();
  });
  tearDown(() async {
    await remote.close();
    if (project.existsSync()) project.deleteSync(recursive: true);
  });

  RemoteClient client() => remote.client;
  String at(String relative) => p.join(root, relative);

  test('listed folders first, read, and saved over what was read', () async {
    File(at('b.txt')).writeAsStringSync('one\r\ntwo\r\n');
    Directory(at('src')).createSync();
    final listed = await client().list(root, root);
    expect(
      [for (final f in listed) (f.name, f.isDirectory)],
      [('src', true), ('b.txt', false)],
    );

    expect(await client().read(root, at('b.txt')), 'one\r\ntwo\r\n');
    await client().write(root, at('b.txt'), 'one\ntwo\nthree\n');
    // The file's own line endings are kept.
    expect(File(at('b.txt')).readAsStringSync(), 'one\r\ntwo\r\nthree\r\n');
  });

  test('a file changed on disk since it was read is not saved', () async {
    File(at('a.txt')).writeAsStringSync('mine');
    await client().read(root, at('a.txt'));
    File(at('a.txt')).writeAsStringSync('theirs');
    await expectLater(
      client().write(root, at('a.txt'), 'mine, edited'),
      throwsA(isA<IdeFileConflictException>()),
    );
    expect(File(at('a.txt')).readAsStringSync(), 'theirs');
  });

  test('missing, binary and taken files fail by type', () async {
    await expectLater(
      client().read(root, at('nope.txt')),
      throwsA(isA<IdeFileNotFoundException>()),
    );
    File(at('bin.dat')).writeAsBytesSync([0, 1, 2, 3]);
    await expectLater(
      client().read(root, at('bin.dat')),
      throwsA(isA<IdeBinaryFileException>()),
    );
    expect(await client().read(root, at('bin.dat'), force: true), isNotEmpty);
    await client().create(root, at('new.txt'));
    await expectLater(
      client().create(root, at('new.txt')),
      throwsA(isA<IdeFileExistsException>()),
    );
  });

  test('the bytes of a file are read whole, and in a range', () async {
    final bytes = List.generate(1000, (i) => i % 251);
    File(at('a.bin')).writeAsBytesSync(bytes);
    expect(await client().readBytes(root, at('a.bin')), bytes);
    final range = await client().readRange(root, at('a.bin'), 10, 5);
    expect(range.bytes, bytes.sublist(10, 15));
    expect(range.size, 1000);
  });

  test('the bytes of a file that is not there are not read', () async {
    await expectLater(
      client().readBytes(root, at('nope.bin')),
      throwsA(isA<IdeFileNotFoundException>()),
    );
    await expectLater(
      client().readRange(root, at('nope.bin'), 0, 1),
      throwsA(isA<IdeFileNotFoundException>()),
    );
  });

  test('a file is copied, renamed and deleted', () async {
    File(at('a.txt')).writeAsStringSync('a');
    await client().copy(root, at('a.txt'), at('b.txt'));
    expect(File(at('b.txt')).readAsStringSync(), 'a');
    await client().rename(root, at('b.txt'), at('c.txt'));
    expect(File(at('c.txt')).existsSync(), isTrue);
    expect(File(at('b.txt')).existsSync(), isFalse);
    await client().delete(root, at('c.txt'));
    expect(File(at('c.txt')).existsSync(), isFalse);
  });

  test('the sizes of files are told', () async {
    File(at('a.txt')).writeAsStringSync('12345');
    File(at('b.txt')).writeAsStringSync('123');
    expect(await client().sizeOf([at('a.txt'), at('b.txt')]), 8);
  });
}
