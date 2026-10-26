import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import '../../tool/bump_claude_version.dart';

/// The pin the bundle carries: the version and the SHA-256 of the Claude
/// Code build it is, in tool/build_windows.dart. The Claude Code version
/// workflow keeps it at the current build; a pin that cannot be read, or
/// written wrongly, would ship an agent nobody asked for.
void main() {
  const checksum =
      'c9796ba22a9221586b36371b36f5b66198d66eb4badf6a4cf4a5f7b07becea53';

  /// A file with a pin in it, as tool/build_windows.dart has it.
  String pin({String version = '2.1.308', String sha = checksum}) => '''
/// The Claude Code the bundle carries, its version and its SHA-256.
const _claudeVersion = '$version';
const _claudeSha256 =
    '$sha';

/// Where that build is: the release's own file for Windows x64.
const _claudeUrl =
    'https://downloads.claude.ai/claude-code-releases/\$_claudeVersion/win32-x64/claude.exe';
''';

  group('reading the pin', () {
    test('the version and the checksum beside it', () {
      final found = pinnedFrom(pin());
      expect(found, isNotNull);
      expect(found!.version, '2.1.308');
      expect(found.sha256, checksum);
    });

    test('the version alone, when the checksum is not there', () {
      final found = pinnedFrom("const _claudeVersion = '2.1.308';\n");
      expect(found?.version, '2.1.308');
      expect(found?.sha256, isNull);
    });

    test('nothing, when there is no version in it', () {
      expect(pinnedFrom('const somethingElse = 1;\n'), isNull);
    });

    test('the pin the build script has', () {
      // The tool and the file it writes have to agree: the tool rewrites
      // what is there, and the build reads what the tool wrote.
      final text = File('tool/build_windows.dart').readAsStringSync();
      final found = pinnedFrom(text);
      expect(found, isNotNull, reason: 'the pin is in tool/build_windows.dart');
      expect(found!.version, isNotEmpty);
      expect(found.sha256, matches(RegExp(r'^[a-f0-9]{64}$')));
    });
  });

  group('writing the pin', () {
    test('the version and the checksum are put in', () {
      final written = writtenWithPin(pin(), '2.1.400', 'a' * 64);
      final found = pinnedFrom(written);
      expect(found?.version, '2.1.400');
      expect(found?.sha256, 'a' * 64);
    });

    test('what is written is read the same way', () {
      final written = writtenWithPin(pin(), '2.1.400', 'a' * 64);
      expect(pinnedFrom(written), pinnedFrom(written));
    });

    test('writing it twice changes nothing the second time', () {
      final once = writtenWithPin(pin(), '2.1.400', 'a' * 64);
      final twice = writtenWithPin(once, '2.1.400', 'a' * 64);
      expect(twice, once);
    });

    test('the rest of the file is left alone', () {
      final text = pin();
      final written = writtenWithPin(text, '2.1.400', 'a' * 64);
      expect(written, contains('downloads.claude.ai'));
      expect(written, contains('/// The Claude Code the bundle carries'));
    });
  });

  group('two versions', () {
    test('the greater one is the newer', () {
      expect(compareVersions('2.1.400', '2.1.308'), greaterThan(0));
      expect(compareVersions('2.1.308', '2.1.400'), lessThan(0));
      expect(compareVersions('2.1.308', '2.1.308'), isZero);
      expect(compareVersions('2.2.0', '2.1.999'), greaterThan(0));
      expect(compareVersions('3.0.0', '2.99.99'), greaterThan(0));
    });

    test('what a version does not say is zero', () {
      expect(compareVersions('2.1.308', '2.1'), greaterThan(0));
    });
  });
}
