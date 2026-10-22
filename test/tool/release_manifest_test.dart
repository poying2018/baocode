import 'package:flutter_test/flutter_test.dart';

import '../../tool/release_manifest.dart';

void main() {
  group('release_manifest', () {
    test('the options the usage tells of are all known', () {
      // The tool's own usage (tool/release_manifest.dart) tells of these;
      // a parser that knows no such option fails with "Unknown argument".
      final options = parseReleaseManifestArguments([
        '--encrypt-key',
        'seed.txt',
        '--out',
        'seed.enc',
      ]);
      expect(options['encrypt-key'], 'seed.txt');
      expect(options['out'], 'seed.enc');
    });

    test('the DPAPI options are known, so a key may be encrypted and read', () {
      // The upstream's parser knows no such option: a merge that takes
      // it would leave the private key unreadable in its encrypted form,
      // though _readKey and the usage still speak of it.
      final options = parseReleaseManifestArguments([
        '--decrypt-key',
        'seed.enc',
        '--out',
        'seed.txt',
      ]);
      expect(options['decrypt-key'], 'seed.enc');
      expect(options['out'], 'seed.txt');
    });

    test('the release options are known, each with its edition', () {
      final options = parseReleaseManifestArguments([
        '--windows',
        'setup.exe',
        '--windows-channel',
        'setup-channel.exe',
        '--notes-en',
        'notes.en.md',
        '--notes-zh',
        'notes.zh.md',
        '--minimum-version',
        '1.0.0',
        '--version',
        '1.5.2+17',
        '--manifest',
        'latest.json',
      ]);
      expect(options['windows'], 'setup.exe');
      expect(options['windows-channel'], 'setup-channel.exe');
      expect(options['notes-en'], 'notes.en.md');
      expect(options['notes-zh'], 'notes.zh.md');
      expect(options['minimum-version'], '1.0.0');
      expect(options['version'], '1.5.2+17');
      expect(options['manifest'], 'latest.json');
    });

    test('a flag alone has no value', () {
      final options = parseReleaseManifestArguments(['--public-key']);
      expect(options.containsKey('public-key'), isTrue);
      expect(options['public-key'], isNull);
    });
  });
}
