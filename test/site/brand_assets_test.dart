// site/brand/'s files are handed to other sites' owners, who write their file
// names into their own pages, and the docs promise they may be added to but
// never renamed or removed (docs/upstream-import.md). Three places have to
// agree on the list: tool/make_brand_assets.py makes it, site/brand/ holds it,
// and the guide tells the owners what to write. A size added to one and not
// the others is a broken picture on somebody else's site.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

/// The numbers of a Python list in [script]: `NAME = [1, 2]`.
List<int> _list(String script, String name) {
  final match = RegExp(
    '$name\\s*=\\s*\\[([^\\]]*)\\]',
  ).firstMatch(script);
  expect(match, isNotNull, reason: '$name in tool/make_brand_assets.py');
  return [
    for (final number in match!.group(1)!.split(','))
      if (number.trim().isNotEmpty) int.parse(number.trim()),
  ];
}

/// The numbers of the guide's sentence that says them: `数字、数字、…`.
List<int> _numbersAfter(String text, Pattern pattern) {
  final match = pattern.allMatches(text).firstOrNull;
  final listing = RegExp(
    r'([0-9]+(?:、[0-9]+)*)',
  ).firstMatch(text.substring(match!.start))!.group(1)!;
  return [for (final number in listing.split('、')) int.parse(number)];
}

void main() {
  final script = File(p.join('tool', 'make_brand_assets.py')).readAsStringSync();
  final doc = File(p.join('docs', 'upstream-import.md')).readAsStringSync();
  final files = {
    for (final file in Directory(p.join('site', 'brand')).listSync())
      if (file is File) p.basename(file.path),
  };

  test('the guide lists the sizes the maker makes', () {
    expect(_numbersAfter(doc, '所以高度有'), _list(script, 'MARK_HEIGHTS'));
    expect(_numbersAfter(doc, '应用图标'), _list(script, 'ICON_SIZES'));
  });

  test('the site has every file the maker makes, and nothing else', () {
    final expected = {
      for (final height in _list(script, 'MARK_HEIGHTS'))
        for (final color in ['black', 'white'])
          'baocode-mark-$color-$height.webp',
      for (final size in _list(script, 'ICON_SIZES')) 'baocode-icon-$size.png',
    };
    expect(files, expected, reason: 'site/brand/');
  });

  test('the files a page names are ones the site has', () {
    // The guide's own examples, and every page that shows them.
    for (final page in Directory('site')
        .listSync(recursive: true)
        .whereType<File>()
        .where((file) => file.path.endsWith('.html'))) {
      final html = page.readAsStringSync();
      for (final match in RegExp(
        r'brand/(baocode-[a-z]+-[a-z0-9-]+\.[a-z]+)',
      ).allMatches(html)) {
        expect(
          files,
          contains(match.group(1)),
          reason: '${p.basename(page.path)} names it',
        );
      }
    }
  });
}
