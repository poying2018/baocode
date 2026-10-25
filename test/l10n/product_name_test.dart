import 'package:baocode/l10n/l10n.dart';
import 'package:flutter_test/flutter_test.dart';

/// The strings name the app: the product's own name, not the one the
/// strings were written with.
void main() {
  test('the strings name the product', () {
    // The test host is not a product of its own, so it is BaoCode's.
    expect(productName, 'BaoCode');
    expect(englishLocalizations.menuAboutBaoCode(productName), 'About BaoCode');
    expect(englishLocalizations.trayShow(productName), 'Show BaoCode');
  });

  test('the strings that name the app take its name', () {
    // Every string that names the app says the product's name.
    expect(
      englishLocalizations.languageSettingsDescription(productName),
      contains(productName),
    );
    expect(
      englishLocalizations.quitConfirmMessage(productName),
      contains(productName),
    );
  });
}
