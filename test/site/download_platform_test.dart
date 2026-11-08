// The download page's version and link come from the release manifest, and so
// does the app's update: two readers of one file, in two languages. The app
// names its platform key itself (windowsUpdatePlatform), the page spells it out
// (site/site.js), and the page's links are keyed by names of its own
// (`data-file="windows"`). Renamed on one side alone, the page shows a version
// and no link — or the app finds no download — and nothing says so.
import 'dart:io';

import 'package:baocode/update/installer_io.dart' show windowsUpdatePlatform;
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

Iterable<File> _pages() =>
    Directory('site')
        .listSync(recursive: true)
        .whereType<File>()
        .where((file) => file.path.endsWith('.html'));

void main() {
  final script = File(p.join('site', 'site.js')).readAsStringSync();

  test("the page's platform key is the app's own", () {
    final key = RegExp(r"platforms\?\.\[?'([^']+)'\]?")
        .firstMatch(script)
        ?.group(1);
    expect(key, isNotNull, reason: 'site/site.js');
    // The x64 build is the one this repository makes (docs/release.md): an
    // x64 Windows on Arm runs it emulated, and picks Arm's from the site.
    expect(key, windowsUpdatePlatform(arm64: false));
  });

  test("the page's links are keyed as the script fills them", () {
    // The script gathers the desktop's under `windows` (the page's own name),
    // and passes upstream's other entries through as they come. A page naming
    // the manifest's key instead (`windows-x64`) is never filled in.
    expect(script, contains('windows: mine?.platforms'));

    var links = 0;
    for (final page in _pages()) {
      for (final match in RegExp(
        r'data-file="([^"]+)"',
      ).allMatches(page.readAsStringSync())) {
        final name = match.group(1)!;
        links++;
        expect(
          name,
          isNot(startsWith('windows-')),
          reason: '${p.basename(page.path)}: a manifest key, not a link name',
        );
      }
    }
    // Read some, so that a page that names none is not a pass.
    expect(links, greaterThan(4));

    // The pages that offer the desktop build name it.
    for (final name in [
      'index.html',
      'download.html',
      'zh/index.html',
      'zh/download.html',
    ]) {
      expect(
        File(p.join('site', name)).readAsStringSync(),
        contains('data-file="windows"'),
        reason: name,
      );
    }
  });

  test('the download page offers the architecture the build makes', () {
    // This fork builds and publishes the Windows build for x64 alone
    // (docs/release.md). A page promising Arm64 too sends that reader to the
    // same x64 installer, which runs emulated at best. The workflow's Arm64
    // is the remote server's Linux build, which no installer ever is: the
    // job that builds the installer is the one that must not name it.
    final workflow = File(p.join('.github', 'workflows', 'release.yml'))
        .readAsStringSync();
    final windows = RegExp(
      r'^  windows:.*?(?=^  \w+:)',
      multiLine: true,
      dotAll: true,
    ).firstMatch(workflow)?.group(0);
    expect(windows, isNotNull, reason: 'the workflow\'s windows job');
    expect(windows!, isNot(contains('arm64')), reason: 'x64 alone is built');
    for (final name in ['download.html', 'zh/download.html']) {
      final html = File(p.join('site', name)).readAsStringSync();
      final section = RegExp(
        r'<section[^>]*data-os="windows".*?</section>',
        dotAll: true,
      ).firstMatch(html)?.group(0);
      expect(section, isNotNull, reason: name);
      expect(section, contains('x64'), reason: name);
      expect(
        section!.toLowerCase(),
        isNot(contains('arm64')),
        reason: '$name: no Arm64 build is published',
      );
    }
  });
}
