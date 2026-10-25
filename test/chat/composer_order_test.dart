import 'package:bao_markdown/bao_markdown.dart';
import 'package:baocode/chat/composer/composer_controller.dart';
import 'package:baocode/chat/composer/composer_embeds.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// The composer's text: what is typed goes where the caret is, and the
/// characters keep their order — with a file reference in it, which the
/// platform is told of as one character.
void main() {
  late ComposerController controller;

  setUp(() => controller = ComposerController(text: 'hello world'));

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

  /// Types [text] where the caret is, as the platform's input sends it.
  Future<void> type(WidgetTester tester, String text) async {
    final value = tester.testTextInput.editingState!;
    final old = value['text'] as String;
    final start = value['selectionBase'] as int;
    final end = value['selectionExtent'] as int;
    final (a, b) = start <= end ? (start, end) : (end, start);
    tester.testTextInput.updateEditingValue(
      TextEditingValue(
        text: old.replaceRange(a, b, text),
        selection: TextSelection.collapsed(offset: a + text.length),
      ),
    );
    await tester.pump();
  }

  testWidgets('the characters keep their order as they are typed', (
    tester,
  ) async {
    await pump(tester);
    for (final character in 'abcdef'.split('')) {
      await type(tester, character);
    }
    expect(controller.text, 'hello worldabcdef');
  });

  testWidgets('the platform is told of the text as it is now', (tester) async {
    await pump(tester);
    await type(tester, 'a');
    // The platform's text is what the editor makes of what it typed: what
    // it types next is told against that text.
    expect(tester.testTextInput.editingState!['text'], 'hello worlda');
    expect(tester.testTextInput.editingState!['selectionBase'], 12);
  });

  testWidgets('a file reference is told as one character', (tester) async {
    // The composer turns what it knows into atoms (a file reference), and
    // the platform is told of each as one character.
    controller = ComposerController(
      text: 'see ${ComposerTokenEmbed.file('src/main.dart').atom} here',
    );
    await pump(tester);
    // The file reference is one character to the platform.
    final value = tester.testTextInput.editingState!;
    expect((value['text'] as String).contains('￼'), isTrue);
    expect((value['text'] as String).contains('main.dart'), isFalse);
  });
}
