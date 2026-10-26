// The two products are separate programs: each keeps its data, its
// windows, its registration, its update channel and its links to itself
// apart, so that neither disturbs the other.
//
// The product is said by the name of the executable the build produced —
// one fact, from which everything else follows. These are the tests of
// that: the table the rest follows from, and the places that take the
// product's name.
import 'package:baocode/platform/app_paths.dart';
import 'package:baocode/update/update_manifest.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('the product a build is', () {
    test('is said by the name of its executable', () {
      expect(
        AppPaths.product(r'C:\Program Files\BaoCode\baocode-claude.exe'),
        'baocode',
      );
      expect(
        AppPaths.product(r'C:\Program Files\BaoCode\baocode-codex.exe'),
        'baocode-codex',
      );
      // The name it had before the rename still names it: a copy of the
      // old program is the same product.
      expect(
        AppPaths.product(r'C:\Program Files\BaoCode\baocode.exe'),
        'baocode',
      );
    });

    test('of a name belonging to no product is the Claude Code one\'s', () {
      // A test host, a build named otherwise.
      expect(AppPaths.product(r'C:\tmp\flutter_tester.exe'), 'baocode');
      // A name with a space in it is no product's (macOS's ".app" folder).
      expect(AppPaths.product('/Applications/BaoCode Codex.app'), 'baocode');
    });

    test('keeps each product\'s own identity', () {
      final baocode = AppPaths.productOf(r'C:\BaoCode\baocode-claude.exe');
      final codex = AppPaths.productOf(r'C:\BaoCode\baocode-codex.exe');
      expect(baocode.displayName, 'BaoCode Claude');
      expect(codex.displayName, 'BaoCode Codex');
      // The scheme, the registration, the update channel: each product's
      // own, so that a link, an install and a release of one do not touch
      // the other.
      expect(baocode.scheme, 'baocode');
      expect(codex.scheme, 'baocode-codex');
      expect(baocode.appId, isNot(codex.appId));
      expect(baocode.registryKey, isNot(codex.registryKey));
      expect(baocode.manifestName, 'latest.json');
      expect(codex.manifestName, 'latest-codex.json');
      expect(baocode.installerName, 'BaoCodeClaude');
      expect(codex.installerName, 'BaoCodeCodex');
      // The folder it is installed in does not change with the name: an
      // upgrade installs over the one before it.
      expect(baocode.directoryName, 'BaoCode');
      expect(codex.directoryName, 'BaoCodeCodex');
      expect(baocode.browserHost, 'dev.baocode.browser');
      expect(codex.browserHost, 'dev.baocode-codex.browser');
      // The Claude Code is BaoCode's alone.
      expect(baocode.hasClaudeCode, isTrue);
      expect(codex.hasClaudeCode, isFalse);
    });

    test('is named the same by every place that asks', () {
      // The build scripts say the products "baocode" and "codex"; the
      // app says "baocode" and "baocode-codex". Both mean the same two.
      expect(Product.byId('codex')?.id, 'baocode-codex');
      expect(Product.byId('baocode-codex')?.id, 'baocode-codex');
      expect(Product.byId('baocode')?.id, 'baocode');
      expect(Product.byId('baocode-claude')?.id, 'baocode');
      expect(Product.byId('nothing'), isNull);
    });

    test(
      'the name a release is asked for lands on the name the app answers',
      () {
        // The update manifest carries the product's id, and an installed app
        // asks whether that release is for the product it knows itself to be
        // (AppPaths.product, the name its data folder carries). A release is
        // asked for by whichever name its caller uses — the build matrix
        // says "baocode-claude" — so the two have to meet at the id. Passed
        // through as it was said, every installed copy of this product would
        // be told it is up to date, forever, and nothing would say so.
        for (final name in ['baocode', 'baocode-claude', 'claude']) {
          final published = Product.byId(name)!.id;
          final asking = AppPaths.product(
            r'C:\Program Files\BaoCode\' + Product.byId(name)!.binary + '.exe',
          );
          expect(asking, published, reason: 'a release asked for by "$name"');
        }
        // And the codex product never answers to the other's name.
        expect(Product.byId('codex')!.id, isNot(Product.baocode.id));
      },
    );
  });

  group('the update channel', () {
    test('is each product\'s own manifest', () {
      expect(manifestUrlFor('baocode'), defaultManifestUrl);
      expect(manifestUrlFor('baocode-codex'), contains('latest-codex.json'));
      expect(
        manifestUrlFor('baocode-codex'),
        isNot(defaultManifestUrl),
        reason: 'a release of one product is not an update of the other',
      );
    });
  });
}
