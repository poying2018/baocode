// A page's `/dl/<name>` link is answered by the Worker (site-worker/index.js),
// which reads a build out of a manifest and redirects to it. A name the Worker
// does not know is a 404 to the reader who clicks it before site.js has
// swapped the link, or with the script blocked — which is the reason the
// routes exist at all.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

/// The names the Worker answers: those its sets list, and those it compares
/// with `os`.
Set<String> _served(String script) => {
  for (final match in RegExp(r'new Set\(\[([^\]]*)\]\)').allMatches(script))
    for (final name in RegExp(
      r"'([^']+)'",
    ).allMatches(match.group(1)!).map((m) => m.group(1)!))
      name,
  for (final match in RegExp(
    r"\bos\s*===\s*'([^']+)'",
  ).allMatches(script))
    match.group(1)!,
};

/// The `/dl/<name>` links the site has: its pages', and its script's.
Map<String, Set<String>> _linked() {
  final found = <String, Set<String>>{};
  final files = [
    ...Directory('site')
        .listSync(recursive: true)
        .whereType<File>()
        .where((file) => file.path.endsWith('.html')),
    File(p.join('site', 'site.js')),
  ];
  for (final file in files) {
    for (final match in RegExp(
      r'/dl/([a-z0-9-]+)',
    ).allMatches(file.readAsStringSync())) {
      (found[p.basename(file.path)] ??= {}).add(match.group(1)!);
    }
  }
  return found;
}

void main() {
  final served = _served(File(p.join('site-worker', 'index.js')).readAsStringSync());
  final linked = _linked();

  test('every /dl route a page links is one the Worker answers', () {
    expect(linked, isNotEmpty);
    for (final MapEntry(key: page, value: names) in linked.entries) {
      for (final name in names) {
        expect(served, contains(name), reason: '$page links /dl/$name');
      }
    }
  });

  test("the Worker's own routes are the platform names the manifests use", () {
    // The desktop ones are the app's platform keys (docs/release.md); a route
    // renamed on one side alone sends the reader to a 404 or to a build of
    // another platform.
    expect(
      served,
      containsAll(['windows', 'linux-x64', 'linux-arm64']),
    );
    expect(served, containsAll(['android', 'ios']));
    expect(served, containsAll(['browser-extension', 'chrome-web-store']));
  });
}
