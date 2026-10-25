@TestOn('mac-os || linux || windows')
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:baocode/kernel/kernel_registry.dart';

/// Each product carries its own core only: BaoCode (the Claude Code one)
/// runs on Claude Code, the codex product on codex. The two products are
/// separate programs: one does not carry the other's core.
void main() {
  test('the kernels on offer are the product\'s own', () {
    // The tests run with the mock kernels (see flutter_test_config.dart);
    // the product's own are asked for by name.
    expect(KernelRegistry.kernelsOf('baocode').length, 1);
    expect(KernelRegistry.kernelsOf('baocode').first.id, 'claude-code');
  });

  test('the codex product carries codex, and no Claude Code', () {
    final kernels = KernelRegistry.kernelsOf('baocode-codex');
    expect(kernels.length, 1);
    expect(kernels.first.id, 'codex');
    // The Claude Code core is not in it: the two products are separate
    // programs, and one does not carry the other's core.
    expect(
      kernels.map((kernel) => kernel.id),
      isNot(contains('claude-code')),
    );
  });

  test('BaoCode carries Claude Code, and no codex', () {
    final kernels = KernelRegistry.kernelsOf('baocode');
    expect(kernels.length, 1);
    expect(kernels.first.id, 'claude-code');
    expect(kernels.map((kernel) => kernel.id), isNot(contains('codex')));
  });
}
