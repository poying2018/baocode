// What the app reads from the repository itself, over raw.githubusercontent:
// the channels the site lists (site/channels.json) and the featured upstreams
// beside it (site/featured/upstreams.json). No deploy stands between a change
// and the users — merging to main is publishing — and nothing but the app at
// run time reads these files: a channel that stops parsing, a logo that moved,
// shows as a card without a picture and says nothing.
import 'dart:convert';
import 'dart:io';

import 'package:baocode/channel/channel_setup.dart';
import 'package:baocode/models/featured_upstreams.dart';
import 'package:baocode/platform/app_links.dart';
import 'package:baocode/update/update_manifest.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

/// The file [path] names, as the site serves it: `/channels/a.svg` is
/// `site/channels/a.svg`.
File _served(String path) =>
    File(p.join('site', path.startsWith('/') ? path.substring(1) : path));

void main() {
  test('the app reads this repository, on this branch', () {
    expect(AppLinks.siteBase.path, endsWith('/poying2018/baocode/main/site/'));
    expect(AppLinks.siteBase.path, endsWith('/'));
  });

  test('the site offers the version the app checks for', () {
    // The download page fills in what it says from the site's own manifest:
    // the app's, in this repository's releases. Two addresses, one fact.
    final script = File(p.join('site', 'site.js')).readAsStringSync();
    final own = RegExp(r"const OWN_MANIFEST = '([^']+)'")
        .firstMatch(script)
        ?.group(1);
    expect(own, isNotNull, reason: 'site/site.js');
    expect(Uri.parse(own!), Uri.parse(defaultManifestUrl));
  });

  test("the channels' list is one every channel in it parses", () {
    final file = File(p.join('site', 'channels.json'));
    expect(file.existsSync(), isTrue, reason: file.path);
    final channels =
        jsonDecode(file.readAsStringSync()) as Map<String, Object?>;
    expect(channels, isNotEmpty);

    for (final MapEntry(key: id, value: entry) in channels.entries) {
      final info = ChannelInfo.parse(entry, 'en');
      expect(info, isNotNull, reason: id);
      // The app asks in the user's language, and falls back to English: a
      // channel with one of them alone is told in the other.
      expect(ChannelInfo.parse(entry, 'zh'), isNotNull, reason: id);
      if (info?.logo case final logo?) {
        expect(
          _served(logo).existsSync(),
          isTrue,
          reason: '$id: ${_served(logo).path}',
        );
      }
    }
  });

  test("the featured upstreams' list parses, logos and all", () {
    final file = File(p.join('site', 'featured', 'upstreams.json'));
    expect(file.existsSync(), isTrue, reason: file.path);
    final json = jsonDecode(file.readAsStringSync()) as Map<String, Object?>;
    expect(json['version'], 1);
    final list = json['upstreams'];
    expect(list, isA<List<Object?>>());

    final ids = <String>[];
    for (final entry in list as List<Object?>) {
      final upstream = FeaturedUpstream.fromJson(entry);
      expect(upstream, isNotNull, reason: '$entry');
      ids.add(upstream!.id);
      // Where a reader is sent: a plain http(s) address, nothing else.
      expect(upstream.url.isScheme('https'), isTrue, reason: upstream.id);
      expect(upstream.name.trim(), isNotEmpty);
      if (upstream.logo case final logo?) {
        final shot = File(p.join('site', 'featured', logo));
        expect(shot.existsSync(), isTrue, reason: '${upstream.id}: $logo');
      }
    }
    // Each once: the id names it on the page.
    expect(ids.toSet(), hasLength(ids.length), reason: '$ids');
  });
}
