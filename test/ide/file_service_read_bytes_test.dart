@TestOn('mac-os || linux || windows')
library;

import 'dart:io';
import 'dart:typed_data';

import 'package:baocode/ide/file_service_io.dart';
import 'package:bao_remote/files.dart' show IdeFileNotFoundException;
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

/// This machine's files: the bytes of a file, whole or in a range — the
/// same calls the remote host's files answer.
void main() {
  late Directory project;
  late LocalIdeFileService files;

  setUp(() {
    project = Directory.systemTemp.createTempSync('baocode-read-bytes-');
    files = LocalIdeFileService(project.path);
  });
  tearDown(() => project.deleteSync(recursive: true));

  String at(String name) => p.join(project.path, name);

  test('the bytes of a file, whole', () async {
    final bytes = Uint8List.fromList(List.generate(70000, (i) => i % 251));
    File(at('shot.png')).writeAsBytesSync(bytes);
    expect(await files.readBytes(at('shot.png')), bytes);
  });

  test('a range of the bytes, and the size of the file', () async {
    File(at('a.bin')).writeAsBytesSync(List.generate(100, (i) => i));
    final range = await files.readRange(at('a.bin'), 10, 5);
    expect(range.bytes, [10, 11, 12, 13, 14]);
    expect(range.size, 100);
  });

  test('a range past the end is empty, and the size is told', () async {
    File(at('a.bin')).writeAsBytesSync([1, 2, 3]);
    final range = await files.readRange(at('a.bin'), 10, 5);
    expect(range.bytes, isEmpty);
    expect(range.size, 3);
  });

  test('a file that is not there is not read', () async {
    await expectLater(
      files.readBytes(at('none.bin')),
      throwsA(isA<IdeFileNotFoundException>()),
    );
    await expectLater(
      files.readRange(at('none.bin'), 0, 1),
      throwsA(isA<IdeFileNotFoundException>()),
    );
  });
}
