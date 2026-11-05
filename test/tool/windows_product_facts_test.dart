// The Windows build keeps the product's facts in two places Dart's product
// table does not write: windows/CMakeLists.txt (the executable's name, the
// name Explorer shows, the browser host's manifest file) and
// windows/runner/app_identity.cpp (the key the settings live under).
//
// A rename in the table that does not reach them is not an error anything
// reports: the build goes through, and the executable shows the old name —
// or the extension looks for a host manifest the build no longer writes.
import 'dart:io';

import 'package:baocode/platform/app_paths.dart';
import 'package:flutter_test/flutter_test.dart';

/// The value of `set([name] "...")` in a CMake file: the first there is.
/// The branches are written product by product, the Claude Code one first.
String? _set(String cmake, String name) =>
    RegExp('set\\($name\\s+"([^"]*)"').firstMatch(cmake)?.group(1);

void main() {
  final cmake = File('windows/CMakeLists.txt').readAsStringSync();
  final native = File('windows/runner/app_identity.cpp').readAsStringSync();

  test('this repository builds the Claude Code product', () {
    // tool/set_product.dart writes this line; the table says what it is.
    expect(_set(cmake, 'BINARY_NAME'), Product.baocode.binary);
    // "baocode-claude" is how the build scripts and the release manifest
    // name the product: the same one as "baocode".
    expect(Product.byId('baocode-claude'), same(Product.baocode));
  });

  test('the name Explorer shows is the product\'s own', () {
    expect(_set(cmake, 'APP_PRODUCT_NAME'), Product.baocode.displayName);
    expect(
      cmake,
      contains('set(APP_PRODUCT_NAME "${Product.codex.displayName}")'),
    );
  });

  test('the browser host manifest is the one the app writes', () {
    expect(
      _set(cmake, 'BROWSER_HOST_MANIFEST'),
      Product.baocode.browserManifest,
    );
    // The other product's is worked out there from its name, and says what
    // the table says it does.
    expect(
      cmake,
      contains(r'set(BROWSER_HOST_MANIFEST "dev.${BINARY_NAME}.browser.json")'),
    );
    expect(
      'dev.${Product.codex.binary}.browser.json',
      Product.codex.browserManifest,
    );
  });

  test('the native side keeps the settings where the table says', () {
    // The Claude Code product keeps the key it always had; the codex one is
    // that key with the product's name on it, which app_identity.cpp works
    // out from the executable's name.
    expect(
      native,
      contains('L"${Product.baocode.registryKey.replaceAll('\\', r'\\')}"'),
    );
    // The name the native side looks for is what both executables start
    // with: the suffix it reads from there says the product.
    expect(native, contains('kAppName[] = L"baocode"'));
    for (final product in Product.all) {
      expect(product.binary, startsWith('baocode'), reason: product.id);
    }
  });
}
