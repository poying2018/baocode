// The repository's own addresses are written in two places that have to agree:
// lib/platform/app_links.dart (the app's) and site/site.js (the site's own
// manifest, which the site reads to fill in version and download links).
// A rename of the repository on one side alone sends the app to a 404 for its
// channels list and the site to a manifest that does not exist.
import 'dart:io';

import 'package:baocode/platform/app_links.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final appLinks = File('lib/platform/app_links.dart').readAsStringSync();
  final siteJs = File('site/site.js').readAsStringSync();

  test('the repository the app reads is the one the site names', () {
    // AppLinks.repository and site.js's OWN_MANIFEST share the same owner
    // and repository name.
    final appRepo = RegExp(
      r"'https://github\.com/([^/]+/[^']+)'",
    ).firstMatch(appLinks)?.group(1);
    expect(appRepo, isNotNull, reason: 'AppLinks.repository');

    final ownManifest = RegExp(
      r"const OWN_MANIFEST = 'https://github\.com/([^/]+/[^/]+)/",
    ).firstMatch(siteJs)?.group(1);
    expect(ownManifest, isNotNull, reason: 'site/site.js OWN_MANIFEST');
    expect(ownManifest, appRepo);
  });

  test('the repository the app reads is the one its manifest names', () {
    // defaultManifestUrl and OWN_MANIFEST point at the same repository.
    final manifestRepo = RegExp(
      r"'https://github\.com/([^/]+/[^/]+)/releases",
    ).firstMatch(
      File('lib/update/update_manifest.dart').readAsStringSync(),
    )?.group(1);
    expect(manifestRepo, isNotNull, reason: 'defaultManifestUrl');
    expect(manifestRepo, 'poying2018/baocode');
  });

  test('the site reads from the repository the app names', () {
    expect(
      AppLinks.siteBase.toString(),
      contains('poying2018/baocode'),
      reason: 'AppLinks.siteBase',
    );
    expect(
      siteJs,
      contains('poying2018/baocode'),
      reason: 'site/site.js',
    );
  });
}
