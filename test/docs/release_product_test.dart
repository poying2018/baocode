// This repository builds and publishes the Claude Code product alone. That
// fact is written in three places that have to agree: the release workflow's
// matrix (product: [baocode-claude], once, in the windows job that builds
// the installer), the PRODUCT the remote server and publish steps carry
// (baocode-claude), and the release guide's sentence that names them.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  final workflow = File('.github/workflows/release.yml').readAsStringSync();
  final guide = File('docs/release.md').readAsStringSync();

  test('the workflow builds the Claude Code product', () {
    // The matrix says so, in the one job that builds the installer.
    expect(
      RegExp(r'product: \[baocode-claude\]').allMatches(workflow).length,
      1,
      reason: '.github/workflows/release.yml matrix',
    );
    // And the PRODUCT the remote server and publish steps carry, which
    // names the same product.
    expect(
      workflow,
      contains('PRODUCT: baocode-claude'),
      reason: '.github/workflows/release.yml publish step',
    );
  });

  test('the guide names what the workflow does', () {
    // The sentence quotes both, so a change in the matrix that does not
    // reach the guide leaves the reader building the wrong product.
    expect(
      guide,
      contains('`product: [baocode-claude]`'),
      reason: 'docs/release.md',
    );
    expect(
      guide,
      contains('`PRODUCT: baocode-claude`'),
      reason: 'docs/release.md',
    );
  });
}
