/// The session's own file: it is read back on the branch the session
/// ended on, not on the one the file happens to end with.
library;

import 'dart:convert';
import 'dart:io';

import 'package:bao_agent/src/engine/session_store.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

void main() {
  late Directory root;
  late String file;

  setUp(() {
    root = Directory.systemTemp.createTempSync('bao_agent_store');
    file = p.join(root.path, 'session.jsonl');
  });
  tearDown(() => root.deleteSync(recursive: true));

  SessionStore store() => SessionStore(
    sessionId: 's',
    cwd: root.path,
    file: file,
  );

  test('a session is read back on the branch it ended on', () {
    final first = store();
    final prompt = first.append({'type': 'user', 'message': {'role': 'user'}});
    final answer = first.append({
      'type': 'assistant',
      'message': {'role': 'assistant'},
    });
    // The user goes back to before the answer: it and what followed are
    // left on a branch of their own.
    expect(first.rewindTo(answer['uuid'] as String), isTrue);
    final again = first.append({
      'type': 'user',
      'message': {'role': 'user'},
    });

    final resumed = SessionStore.resume(
      sessionId: 's',
      cwd: root.path,
      file: file,
    );
    expect(resumed.chain.map((entry) => entry['uuid']), [
      prompt['uuid'],
      again['uuid'],
    ]);
  });

  test('a branch that was left is not the one the session ends on', () {
    final first = store();
    final prompt = first.append({'type': 'user', 'message': {'role': 'user'}});
    final answer = first.append({
      'type': 'assistant',
      'message': {'role': 'assistant'},
    });
    // The user goes back to before the answer, and says nothing yet: the
    // file still ends with the answer, on the branch that was left.
    first.rewindTo(answer['uuid'] as String);

    final resumed = SessionStore.resume(
      sessionId: 's',
      cwd: root.path,
      file: file,
    );
    expect(resumed.chain.map((entry) => entry['uuid']), [prompt['uuid']]);
    expect(resumed.chain.any((e) => e['uuid'] == answer['uuid']), isFalse);
  });

  test('the file is one object a line', () {
    final first = store();
    first.append({'type': 'user', 'message': {'role': 'user'}});
    first.note({'type': 'custom-title', 'customTitle': 'Mine'});
    final lines = const LineSplitter()
        .convert(File(file).readAsStringSync())
        .where((line) => line.trim().isNotEmpty)
        .toList();
    expect(lines, hasLength(3));
    for (final line in lines) {
      expect(() => jsonDecode(line), returnsNormally);
    }
  });

  test('a message replaced is left out of the conversation', () {
    final first = store();
    first.append({'type': 'user', 'message': {'role': 'user'}});
    final old = first.append({
      'type': 'user',
      'message': {
        'role': 'user',
        'content': [
          {'type': 'text', 'text': 'the old answer'},
        ],
      },
      'isMeta': true,
    });
    first.replace(old['uuid'] as String, {
      'type': 'user',
      'message': {
        'role': 'user',
        'content': [
          {'type': 'text', 'text': 'the new answer'},
        ],
      },
      'isMeta': true,
    });

    // In the conversation now: the new one, in the old one's place.
    final messages = first.apiMessages();
    final texts = [
      for (final message in messages)
        for (final block in (message['content'] as List))
          if (block['type'] == 'text') block['text'],
    ];
    expect(texts, contains('the new answer'));
    expect(texts, isNot(contains('the old answer')));

    // And after the file is read back.
    final resumed = SessionStore.resume(
      sessionId: 's',
      cwd: root.path,
      file: file,
    );
    final reread = [
      for (final message in resumed.apiMessages())
        for (final block in (message['content'] as List))
          if (block['type'] == 'text') block['text'],
    ];
    expect(reread, contains('the new answer'));
    expect(reread, isNot(contains('the old answer')));
  });
}
