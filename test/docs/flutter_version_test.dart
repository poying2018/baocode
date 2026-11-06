// The CI builds with a pinned Flutter version, and docs/windows.md says which
// one this machine runs — both are the same fact. A bump of one without the
// other leaves the builder on a different Flutter than the one the docs
// describe, and the app is compiled with the engine the build uses.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  final docs = File('docs/windows.md').readAsStringSync();
  final workflows = Directory('.github/workflows')
      .listSync()
      .whereType<File>()
      .where((file) => file.path.endsWith('.yml'));

  test('the Flutter version the docs name is the one CI pins', () {
    final documented = RegExp(
      r'stable ([0-9]+\.[0-9]+\.[0-9]+)',
    ).firstMatch(docs)?.group(1);
    expect(
      documented,
      isNotNull,
      reason: 'docs/windows.md names no Flutter version',
    );

    final pinned = <String>{
      for (final file in workflows)
        for (final match in RegExp(
          r'FLUTTER_VERSION:\s*([0-9]+\.[0-9]+\.[0-9]+)',
        ).allMatches(file.readAsStringSync()))
          match.group(1)!,
    };
    expect(pinned, isNotEmpty, reason: 'no workflow pins FLUTTER_VERSION');
    expect(pinned, {documented}, reason: 'docs and CI disagree on Flutter');
  });

  test('every workflow pins the same Flutter version', () {
    final pinned = <String>{
      for (final file in workflows)
        for (final match in RegExp(
          r'FLUTTER_VERSION:\s*([0-9]+\.[0-9]+\.[0-9]+)',
        ).allMatches(file.readAsStringSync()))
          match.group(1)!,
    };
    expect(pinned, hasLength(1), reason: 'workflows disagree: $pinned');
  });
}
