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

/// The pages the site has.
Iterable<File> _pages() =>
    Directory('site')
        .listSync(recursive: true)
        .whereType<File>()
        .where((file) => file.path.endsWith('.html'));

/// A page as its links are read: the prose's examples and code samples out
/// (a prompt written for a site's owner shows a link in a `data-template`).
String _pageOf(File file) => file
    .readAsStringSync()
    .replaceAll(RegExp(r'<pre[\s\S]*?</pre>'), '')
    .replaceAll(RegExp(r'<code[\s\S]*?</code>'), '');

/// The file the site serves [path] as, from [from]'s page: null when it is
/// not on the site.
File? _fileOf(String path, {required File from}) {
  String? existing(String candidate) {
    for (final option in [
      candidate,
      '$candidate.html',
      p.join(candidate, 'index.html'),
    ]) {
      if (File(option).existsSync()) return option;
    }
    return null;
  }

  if (path.startsWith('/')) {
    final target = _target(path);
    if (Uri.tryParse(target)?.hasScheme == true) return null;
    final found = existing(
      p.join('site', target.startsWith('/') ? target.substring(1) : target),
    );
    return found == null ? null : File(found);
  }
  final found = existing(p.join(p.dirname(from.path), path));
  return found == null ? null : File(found);
}

void main() {
  test('every file a page links to is one the site serves', () {
    var checked = 0;
    final missing = <String>[];

    for (final file in Directory(
      'site',
    ).listSync(recursive: true).whereType<File>()) {
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
        if (RegExp(r'^(https?:|mailto:|#|data:|javascript:|\{\{|\$)')
            .hasMatch(url)) {
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
            : _served(
                // From the site's folder: a relative path, whatever the
                // machine's separators are.
                p.relative(p.join(p.dirname(file.path), path), from: 'site'),
              );
        if (!served) missing.add('${p.basename(file.path)}: $url');
      }
    }

    expect(missing, isEmpty, reason: 'links to files the site does not have');
    // The pages were read, and this is not passing on none of them.
    expect(checked, greaterThan(200), reason: 'links read: $checked');
  });

  test('every anchor a page jumps to is one the page it goes to has', () {
    final ids = <String, Set<String>>{};
    Set<String> idsOf(File file) => ids[file.path] ??= {
      for (final match in RegExp(
        r'(?<![\w-])id="([^"]+)"',
      ).allMatches(file.readAsStringSync()))
        match.group(1)!,
    };

    var checked = 0;
    final missing = <String>[];

    for (final page in _pages()) {
      for (final match in RegExp(
        r'(?<![\w-])href="([^"]*#[^"]+)"',
      ).allMatches(_pageOf(page))) {
        final url = match.group(1)!;
        // Elsewhere's, or a name the page's script writes (an anchor made
        // of an entry's id, `/upstreams#style-<id>`).
        if (RegExp(r'^(https?:|mailto:)').hasMatch(url)) continue;
        if (url.contains('{{') || url.contains(r'$')) continue;
        checked++;

        final hash = url.indexOf('#');
        final target = hash == 0
            ? page
            : _fileOf(url.substring(0, hash), from: page);
        if (target == null) {
          missing.add('${p.basename(page.path)}: $url (no such page)');
          continue;
        }
        if (!idsOf(target).contains(url.substring(hash + 1))) {
          missing.add('${p.basename(page.path)}: $url');
        }
      }
    }

    expect(missing, isEmpty, reason: 'anchors the pages do not have');
    expect(checked, greaterThan(200), reason: 'anchors read: $checked');
  });

  test('each page is written in both languages', () {
    Set<String> names(Directory directory) => {
      for (final file in directory.listSync().whereType<File>())
        if (file.path.endsWith('.html')) p.basename(file.path),
    };
    final english = names(Directory('site'));
    final chinese = names(Directory(p.join('site', 'zh')));
    // The language switch and the hreflang links go to the other language's
    // page of the same name: one without its pair is a link to nothing.
    expect(chinese.difference(english), isEmpty, reason: 'in site/zh only');
    expect(english.difference(chinese), isEmpty, reason: 'in site/ only');
  });
}
