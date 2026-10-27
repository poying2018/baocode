import 'package:baocode/stash/stash_disk.dart';
import 'package:baocode/stash/stash_store.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('a note written in the tick it was made in is not a draft', () async {
    // The clock does not move: what separates a draft from a note that
    // was written is the write, not the time.
    final now = DateTime(2026, 10, 27, 9, 0);
    final store = StashStore(MemoryStashDisk(), clock: () => now);
    final note = await store.create(body: '');
    expect(note.isDraft, isTrue);

    await store.update(note.id, (n) => n.body = 'written');
    await store.update(note.id, (n) => n.body = '');
    final emptied = store.byId(note.id)!;
    expect(emptied.isBlank, isTrue);
    // Written, so not the draft the panel goes on with any more.
    expect(emptied.isDraft, isFalse);
    expect(emptied.updated.isAfter(emptied.created), isTrue);
  });
}
