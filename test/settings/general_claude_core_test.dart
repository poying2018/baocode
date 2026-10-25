import 'package:baocode/l10n/l10n.dart';
import 'package:baocode/settings/pages/general_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// Settings → General: the Claude Code group is in BaoCode (the Claude
/// Code one) and not in the codex product, which has no Claude Code.
void main() {
  Future<void> pump(WidgetTester tester, {required bool hasClaudeCode}) async {
    tester.view.physicalSize = const Size(1000, 2600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: GeneralSettingsPage(
            hasClaudeCode: hasClaudeCode,
            claudeStatus: () async => null,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('BaoCode shows the Claude Code group', (tester) async {
    await pump(tester, hasClaudeCode: true);
    expect(find.text('Claude Code'), findsOneWidget);
  });

  testWidgets('the codex product shows no Claude Code', (tester) async {
    await pump(tester, hasClaudeCode: false);
    // The group is gone: the product has no Claude Code, and says nothing
    // of it.
    expect(find.text('Claude Code'), findsNothing);
    expect(
      find.text(englishLocalizations.generalSettingsClaudeCore),
      findsNothing,
    );
  });
}
