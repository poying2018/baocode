// The site names the app's version itself, in the text its script fills in
// (site/site.js): a reader without the script, or a search engine, sees what
// is written there. It said 1.6.0 on one page and 1.7.0 on another, releases
// apart — the tool that bumps the version writes these too now
// (tool/bump_version.dart), and this holds the pages to the version the app
// is.
import 'dart:io';

import 'package:baocode/update/version.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../tool/bump_version.dart';

/// The versions a page names as the app's: `data-version`'s, and the
/// download link's.
List<String> _versionsOf(String html) => [
  for (final match in RegExp(
    r'data-version>([^<]*?)(\d+\.\d+\.\d+)',
  ).allMatches(html))
    match.group(2)!,
  for (final match in RegExp(r'>BaoCode (\d+\.\d+\.\d+)<').allMatches(html))
    match.group(1)!,
];

void main() {
  test('the site names the version the app is', () {
    for (final name in siteVersionPages) {
      final versions = _versionsOf(File(name).readAsStringSync());
      expect(versions, isNotEmpty, reason: name);
      for (final version in versions) {
        expect(version, currentAppVersion.marketing, reason: name);
      }
    }
  });

  test('a bump rewrites them, and nothing else', () {
    const page = '''
<span data-version>版本 1.6.0</span>
<span>Linux 1.6.0</span>
<a data-name href="x">BaoCode 1.6.0</a>
''';
    final rewritten = rewriteSiteVersion(page, '2.0.0');
    expect(rewritten, contains('版本 2.0.0'));
    expect(rewritten, contains('>BaoCode 2.0.0<'));
    // A version the page says of something else is its own.
    expect(rewritten, contains('Linux 1.6.0'));
  });
}
