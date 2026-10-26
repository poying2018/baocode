import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:baocode/chat/widgets/bao_wordmark.dart';

/// The mark the app shows: BaoCode's, and the codex product's, which says
/// its own name.
void main() {
  testWidgets('the mark says the product\'s name', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(home: BaoWordmark(color: Colors.white)),
    );
    // The name is in capitals, with no space: it is drawn in cells.
    expect(BaoWordmark.word, 'BAOCODECLAUDE');
    // The label says it as it is written.
    expect(
      tester.getSemantics(find.byType(BaoWordmark)).label,
      'BaoCode Claude',
    );
  });

  testWidgets('the mark is drawn in cells, wide as its name', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(home: BaoWordmark(color: Colors.white, cell: 2)),
    );
    // The size the mark asks for: the mark (8), the gap (4) and the
    // letters (5 + 2 each, less the tracking after the last).
    expect(
      tester.widget<CustomPaint>(
        find.descendant(
          of: find.byType(BaoWordmark),
          matching: find.byType(CustomPaint),
        ),
      ).size,
      const Size((8 + 4 + 13 * 7 - 2) * 2, 6 * 2),
    );
  });
}
