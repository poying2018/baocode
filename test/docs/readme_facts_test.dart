// The five READMEs say which Dart SDK they need, and point at files in the
// repository. Both are facts of the code's, in five languages: an SDK bumped
// in pubspec alone leaves a builder on an older one reading an error, and a
// file moved alone leaves a link to nothing.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

const _readmes = [
  'README.md',
  'README_CN.md',
  'README_JA.md',
  'README_FR.md',
  'README_ES.md',
];

/// The source folders a README may name: the ones that are in the repository
/// rather than made by a build.
const _sources = [
  'tool',
  'lib',
  'docs',
  'packages',
  'site',
  'windows',
  'linux',
  '.github',
];

void main() {
  final pubspec = File('pubspec.yaml').readAsStringSync();
  final sdk = RegExp(
    r'^environment:\s*\n\s+sdk:\s*(\S+)',
    multiLine: true,
  ).firstMatch(pubspec)?.group(1);

  test('the SDK the READMEs promise is the one pubspec requires', () {
    expect(sdk, isNotNull, reason: 'pubspec.yaml has no environment: sdk:');
    for (final name in _readmes) {
      expect(
        File(name).readAsStringSync(),
        contains('`$sdk`'),
        reason: '$name names a Dart SDK other than $sdk',
      );
    }
  });

  test('the files the READMEs name are there', () {
    final pattern = RegExp(
      '(?:${_sources.join('|')})/[A-Za-z0-9_./-]+',
    );
    final missing = <String>{};
    for (final name in _readmes) {
      for (final match in pattern.allMatches(File(name).readAsStringSync())) {
        final path = match.group(0)!.replaceAll(RegExp(r'[.,;:]+$'), '');
        // `<version>` and `*` are placeholders, not paths.
        if (path.contains('<') || path.contains('*')) continue;
        if (!FileSystemEntity.isFileSync(path) &&
            !FileSystemEntity.isDirectorySync(path)) {
          missing.add('$name: $path');
        }
      }
    }
    expect(missing, isEmpty);
  });

  test('the five READMEs are the five languages', () {
    for (final name in _readmes) {
      expect(File(name).existsSync(), isTrue, reason: name);
    }
    expect(
      Directory('.')
          .listSync()
          .whereType<File>()
          .map((file) => p.basename(file.path))
          .where((name) => name.startsWith('README') && name.endsWith('.md'))
          .toSet(),
      _readmes.toSet(),
      reason: 'a README language was added or dropped',
    );
  });
}
