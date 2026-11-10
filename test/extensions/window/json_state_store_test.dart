import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:baocode/extensions/window/json_state_store.dart';
import 'package:path/path.dart' as p;

/// The state file is written aside and renamed over: changes kept, nothing
/// left aside, and two writers of the same file do not collide.
void main() {
  late Directory dir;
  late String path;

  setUp(() {
    dir = Directory.systemTemp.createTempSync('baocode-state');
    path = p.join(dir.path, 'debug.json');
  });
  tearDown(() => dir.deleteSync(recursive: true));

  List<String> names() =>
      [for (final entity in dir.listSync()) p.basename(entity.path)]..sort();

  test('changes reach the file, and load reads them back', () async {
    final store = JsonStateStore(path);
    final changes = <JsonStateChange>[];
    store.changes.listen(changes.add);
    await store.load();
    store.set('breakpoints', 'a');
    await store.flush();
    store.setJson('launch', {'name': 'run'});
    await store.dispose();

    expect(names(), ['debug.json']);
    expect(jsonDecode(File(path).readAsStringSync()), {
      'breakpoints': 'a',
      'launch': '{"name":"run"}',
    });
    expect(changes.map((change) => change.key), ['breakpoints', 'launch']);

    final loaded = JsonStateStore(path);
    await loaded.load();
    expect(loaded.get('breakpoints'), 'a');
    expect(loaded.getJson('launch'), {'name': 'run'});
    await loaded.dispose();
  });

  test('writers of one file at once keep it whole, nothing aside', () async {
    await Future.wait([
      for (var writer = 0; writer < 20; writer++)
        writeAtomically(path, jsonEncode({'writer': writer})),
    ]);
    expect(names(), ['debug.json']);
    expect(
      (jsonDecode(File(path).readAsStringSync()) as Map)['writer'],
      inInclusiveRange(0, 19),
    );
  });
}
