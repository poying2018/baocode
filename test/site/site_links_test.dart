// The site in site/ is deployed as it is (Cloudflare Pages, .github/
// workflows/site.yml or the deploy job), and its pages link to files that go
// with them: another page, a stylesheet, an icon, the brand's images. A page
// moved or a file renamed leaves a link that 404s, and the deploy goes through
// all the same — nothing in the repository reads the pages but the browser.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

/// The site's redirects (site/_redirects): a path, to where it goes — another
/// path on the site, or an address elsewhere.
final _redirects = <String, String>{
  for (final line in File(p.join('site', '_redirects')).readAsLinesSync())
    if (line.trim().isNotEmpty && !line.trim().startsWith('#'))
      for (final parts in [line.trim().split(RegExp(r'\s+'))])
        if (parts.length >= 2 && parts.first.startsWith('/'))
          parts.first: parts[1],
};

/// Where the site sends [url], a root path: its redirect's target, or itself.
String _target(String url) {
  if (_redirects[url] case final to?) return to;
  for (final MapEntry(key: from, value: to) in _redirects.entries) {
    if (!from.endsWith('/*')) continue;
    if (!url.startsWith(from.substring(0, from.length - 1))) continue;
    return to.replaceAll(':splat', url.substring(from.length - 1));
  }
  return url;
}

/// Whether the site serves [path] (no query, no fragment): the file itself,
/// its `.html` (the pages are written so), or a folder's index.
bool _served(String path) {
  final file = p.join('site', path);
  return File(file).existsSync() ||
      File('$file.html').existsSync() ||
      File(p.join(file, 'index.html')).existsSync();
}

void main() {
  test('every file a page links to is one the site serves', () {
    var checked = 0;
    final missing = <String>[];

    for (final file in Directory('site')
        .listSync(recursive: true)
        .whereType<File>()) {
      if (!file.path.endsWith('.html')) continue;
      // Examples in the pages' own prose and code samples are not links
      // (a prompt written for a site's owner shows one in a `data-template`).
      final html = file
          .readAsStringSync()
          .replaceAll(RegExp(r'<pre[\s\S]*?</pre>'), '')
          .replaceAll(RegExp(r'<code[\s\S]*?</code>'), '');

      for (final match in RegExp(
        r'(?<![\w-])(?:href|src)="([^"]+)"',
      ).allMatches(html)) {
        final url = match.group(1)!;
        // Elsewhere, or this page's own: neither is the site's to serve.
        if (RegExp(
          r'^(https?:|mailto:|#|data:|javascript:|\{\{|\$)',
        ).hasMatch(url)) {
          continue;
        }
        final path = url.split(RegExp(r'[?#]')).first;
        if (path.isEmpty) continue;
        checked++;

        final target = path.startsWith('/') ? _target(path) : null;
        if (target != null && Uri.tryParse(target)?.hasScheme == true) {
          continue; // A redirect off the site.
        }
        final served = target != null
            ? _served(target.startsWith('/') ? target.substring(1) : target)
            : _served(p.join(p.dirname(file.path).substring('site'.length), path));
        if (!served) missing.add('${p.basename(file.path)}: $url');
      }
    }

    expect(missing, isEmpty, reason: 'links to files the site does not have');
    // The pages were read, and this is not passing on none of them.
    expect(checked, greaterThan(200), reason: 'links read: $checked');
  });
}
