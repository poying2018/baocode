import 'package:bao_markdown/bao_markdown.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

/// The characters keep their order: what is typed goes where the caret is,
/// and what is there keeps its place.
void main() {
  late MarkdownController controller;

  setUp(() => controller = MarkdownController(text: 'hello world'));

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

  /// Puts the caret at [offset], as a tap there does.
  Future<void> caret(WidgetTester tester, int offset) async {
    final state = tester.state<MarkdownEditorState>(
      find.byType(MarkdownEditor),
    );
    final rect = state.caretRect(offset);
    if (rect != null) {
      await tester.tapAt(rect.center + const Offset(0.5, 0));
      await tester.pump();
      if (controller.selection.baseOffset == offset) return;
    }
    // The tap did not land where the caret is: it is put where it is
    // wanted, and the platform told of it.
    controller.selection = TextSelection.collapsed(offset: offset);
    await tester.pump();
    final value = tester.testTextInput.editingState!;
    tester.testTextInput.updateEditingValue(
      TextEditingValue(
        text: value['text'] as String,
        selection: TextSelection.collapsed(offset: offset),
      ),
    );
    await tester.pump();
  }

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

  testWidgets('what is typed in the middle goes where the caret is', (
    tester,
  ) async {
    await pump(tester);
    // The caret between "hello" and " world".
    await caret(tester, 5);
    await type(tester, 'XY');
    expect(controller.text, 'helloXY world');
  });

  testWidgets('Chinese typed in the middle keeps its order', (tester) async {
    await pump(tester);
    await caret(tester, 5);
    // What an input method sends: the characters as they are composed.
    await type(tester, '你好世界');
    expect(controller.text, 'hello你好世界 world');
  });

  testWidgets('characters typed one by one keep their order', (tester) async {
    await pump(tester);
    await caret(tester, 0);
    for (final character in 'abcdef'.split('')) {
      await type(tester, character);
    }
    expect(controller.text, 'abcdefhello world');
  });

  testWidgets('text typed over a selection replaces it', (tester) async {
    await pump(tester);
    final value = tester.testTextInput.editingState!;
    tester.testTextInput.updateEditingValue(
      TextEditingValue(
        text: value['text'] as String,
        selection: const TextSelection(baseOffset: 0, extentOffset: 5),
      ),
    );
    await tester.pump();
    await type(tester, 'Z');
    expect(controller.text, 'Z world');
  });
}
