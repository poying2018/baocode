// The Windows bundle carries a pinned Claude Code: its version and checksum
// are in tool/build_windows.dart (_claudeVersion, _claudeSha256). Three other
// files name that same version — the doc, the mock transport's comment, the
// test's header — and each of them said 2.1.281 while the pin was 2.1.311.
// They say the pin's version now, and this holds them to it.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  final pin = File('tool/build_windows.dart').readAsStringSync();
  final version = RegExp(
    r"const _claudeVersion = '([^']*)';",
  ).firstMatch(pin)?.group(1);

  group('the Claude Code pin', () {
    test('the pin exists', () {
      expect(version, isNotNull, reason: 'tool/build_windows.dart has no pin');
    });

    test('the doc names the version the pin carries', () {
      expect(
        File('docs/claude-code-kernel.md').readAsStringSync(),
        contains(version!),
        reason: 'docs/claude-code-kernel.md names another Claude Code',
      );
    });

    test('the mock transport names the version the pin carries', () {
      expect(
        File(
          'lib/kernel/claude_code/mock_claude_code_transport.dart',
        ).readAsStringSync(),
        contains(version!),
        reason: 'mock_claude_code_transport.dart names another Claude Code',
      );
    });

    test('the test header names the version the pin carries', () {
      expect(
        File('test/kernel_test.dart').readAsStringSync(),
        contains(version!),
        reason: 'test/kernel_test.dart names another Claude Code',
      );
    });
  });
}
