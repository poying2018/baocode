import 'package:bao_markdown/bao_markdown.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

/// An input method that composes is left alone: told of the text again
/// while it composes, Windows ends what it composes, and the pinyin goes
/// in as it was — apostrophes and all.
void main() {
  late MarkdownController controller;

  setUp(() => controller = MarkdownController(text: ''));

  Future<void> pump(WidgetTester tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: MarkdownEditor(
            controller: controller,
            shrinkWrap: true,
            style: const MarkdownEditorStyle(text: TextStyle()),
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.tap(find.byType(MarkdownEditor));
    await tester.pump();
  }

  /// The pinyin an input method composes, as it sends it: the segments
  /// apart by an apostrophe.
  const pinyin = "du'qu'gai'ye'mian";

  /// What the app told the platform since [log] was cleared.
  List<MethodCall> toldSince(WidgetTester tester) => tester.testTextInput.log
      .where((call) => call.method == 'TextInput.setEditingState')
      .toList();

  testWidgets('what an input method composes is not pushed back to it', (
    tester,
  ) async {
    await pump(tester);
    tester.testTextInput.log.clear();

    // The pinyin, composed: the text of it and where it is composed.
    tester.testTextInput.updateEditingValue(
      TextEditingValue(
        text: pinyin,
        selection: TextSelection.collapsed(offset: pinyin.length),
        composing: TextRange(start: 0, end: pinyin.length),
      ),
    );
    await tester.pump();

    // The platform is told nothing: told again, it ends what it composes.
    expect(toldSince(tester), isEmpty);
    // What it composes is in the editor, marked as composed.
    expect(controller.text, pinyin);
    expect(controller.isComposing, isTrue);
  });

  testWidgets('what an input method commits replaces the pinyin', (
    tester,
  ) async {
    await pump(tester);

    tester.testTextInput.updateEditingValue(
      TextEditingValue(
        text: pinyin,
        selection: TextSelection.collapsed(offset: pinyin.length),
        composing: TextRange(start: 0, end: pinyin.length),
      ),
    );
    await tester.pump();

    // The candidate picked: the pinyin is gone, the characters are there.
    const chinese = '读取该页面';
    tester.testTextInput.updateEditingValue(
      TextEditingValue(
        text: chinese,
        selection: TextSelection.collapsed(offset: chinese.length),
      ),
    );
    await tester.pump();

    expect(controller.text, chinese);
    expect(controller.isComposing, isFalse);
    expect(controller.text, isNot(contains("'")));
  });
}
