@TestOn('mac-os || linux || windows')
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:baocode/kernel/kernel_registry.dart';

/// Each product runs on its own kernel first: the codex product on codex,
/// BaoCode (the Claude Code one) on Claude Code. The other is there in
/// both, for a user who wants it.
void main() {
  test('the kernels on offer start with the product\'s own', () {
    final kernels = KernelRegistry.all;
    expect(kernels, isNotEmpty);
    // The test host is not a product of its own, so it is BaoCode's order.
    expect(kernels.first.id, 'claude-code');
    expect(
      kernels.map((kernel) => kernel.id),
      containsAll(<String>['claude-code', 'codex']),
    );
  });
}
