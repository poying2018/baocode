// The download page and the README promise Windows 10 or later, and Flutter's
// Windows build needs it — but the installer said nothing, so it installed on
// 8.1 and the app then did not start. What Setup refuses is held to what the
// pages say here.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

String _setup(String script) =>
    RegExp(r'^\[Setup\]$', multiLine: true).firstMatch(script) == null
    ? ''
    : script.substring(
        RegExp(r'^\[Setup\]$', multiLine: true).firstMatch(script)!.end,
      );

void main() {
  final script = File('tool/baocode.iss').readAsStringSync();
  final setup = _setup(script);

  test('Setup refuses Windows below 10', () {
    final match = RegExp(
      r'^MinVersion=([0-9]+)\.([0-9]+)',
      multiLine: true,
    ).firstMatch(setup);
    expect(match, isNotNull, reason: 'tool/baocode.iss has no MinVersion');
    final major = int.parse(match!.group(1)!);
    final minor = int.parse(match.group(2)!);
    // 10.0 is Windows 10, and 11 reports itself as 10.0.22000.
    expect(major, 10);
    expect(minor, 0);
  });

  test("the pages' promise is the installer's", () {
    for (final name in [
      'README.md',
      'site/index.html',
      'site/zh/index.html',
      'site/download.html',
      'site/zh/download.html',
    ]) {
      expect(
        File(name).readAsStringSync(),
        contains('Windows 10'),
        reason: name,
      );
    }
  });
}
