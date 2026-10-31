// The site's live configs are read by installed apps straight from this
// repository (`AppLinks.siteBase`, raw.githubusercontent on main): a schema
// break here shows up on users' machines, and no CI runs the tests to catch
// it. So these read the files as they are in the repository and parse them
// with the app's own code.
@TestOn('vm')
library;

import 'dart:convert';
import 'dart:io';

import 'package:baocode/channel/channel_setup.dart';
import 'package:baocode/models/featured_upstreams.dart' show FeaturedUpstream;
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

void main() {
  final site = Directory(p.join(Directory.current.path, 'site'));

  group('site/channels.json, read from the repository', () {
    late Map<String, Object?> channels;

    setUpAll(() {
      final text = File(
        p.join(site.path, 'channels.json'),
      ).readAsStringSync();
      channels = (jsonDecode(text) as Map).cast<String, Object?>();
    });

    test("parses with the app's own code, for both languages", () {
      expect(channels, isNotEmpty);
      for (final language in ['zh', 'en']) {
        for (final entry in channels.values) {
          final info = ChannelInfo.parse(entry, language);
          expect(
            info,
            isNotNull,
            reason: 'a channel entry that parses to nothing in $language',
          );
          expect(info!.name, isNotEmpty);
        }
      }
    });

    test('every logo it names is a file in the repository', () {
      for (final entry in channels.values) {
        final info = ChannelInfo.parse(entry, 'en');
        final logo = info?.logo;
        if (logo == null) continue;
        // The logo is `/channels/<file>` under the site's root, wherever the
        // site is served from; the test reads it out of this repository.
        final file = File(
          p.join(site.path, logo.substring(1).replaceAll('/', p.separator)),
        );
        expect(file.existsSync(), isTrue, reason: '${file.path} is missing');
      }
    });
  });

  group('site/featured/upstreams.json, read from the repository', () {
    test("parses with the app's own code", () {
      final text = File(
        p.join(site.path, 'featured', 'upstreams.json'),
      ).readAsStringSync();
      final listed = FeaturedUpstream.parseList(text);
      // The list may be empty; it must not fail to parse.
      expect(listed, isA<List<FeaturedUpstream>>());
      for (final upstream in listed) {
        expect(upstream.name, isNotEmpty);
      }
    });
  });
}
