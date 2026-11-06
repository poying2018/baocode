// The browsers' native messaging host: a browser reads the manifest its
// registry key names (tool/baocode.iss), the manifest names the host beside
// it and the one extension it lets in. The three have to agree with the
// product table, and nothing reports it when they do not: the browser simply
// never finds BaoCode — or finds the other product's host.
import 'dart:convert';
import 'dart:io';

import 'package:baocode/platform/app_paths.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';

/// The extension's id, as Chrome makes it from its manifest's "key": the
/// digest's first 16 bytes in hex, each digit 0-9 a-f mapped to a-p.
String _extensionId(String key) {
  final hex = sha256.convert(base64.decode(key)).toString();
  return String.fromCharCodes([
    for (final unit in hex.substring(0, 32).codeUnits)
      0x61 + int.parse(String.fromCharCode(unit), radix: 16),
  ]);
}

/// The value of `#define [name] "…"` in the installer's script.
String? _define(String iss, String name) =>
    RegExp('#define\\s+$name\\s+"([^"]*)"').firstMatch(iss)?.group(1);

void main() {
  final extension = jsonDecode(
    File('browser_extension/manifest.json').readAsStringSync(),
  ) as Map<String, Object?>;
  final id = _extensionId(extension['key']! as String);
  final iss = File('tool/baocode.iss').readAsStringSync();
  final builder = File('tool/build_windows.dart').readAsStringSync();

  for (final product in Product.all) {
    test("${product.id}: the manifest names its host and the extension", () {
      final file = File('windows/BrowserBridge/${product.browserManifest}');
      expect(file.existsSync(), isTrue, reason: file.path);
      final manifest =
          jsonDecode(file.readAsStringSync()) as Map<String, Object?>;
      expect(manifest['name'], product.browserHost);
      expect(manifest['description'], product.displayName);
      expect(manifest['type'], 'stdio');
      // Beside the manifest: on Windows the browsers read a relative path
      // as the manifest's folder's.
      expect(manifest['path'], '${product.id}-browser-host.exe');
      expect(manifest['allowed_origins'], ['chrome-extension://$id/']);
    });
  }

  test("the installer's defaults are the Claude Code product's", () {
    expect(_define(iss, 'ProductBrowserHost'), Product.baocode.browserHost);
    expect(
      _define(iss, 'ProductBrowserManifest'),
      Product.baocode.browserManifest,
    );
  });

  test('the installer points every browser at that manifest, by that name', () {
    final pointed = {
      for (final match in RegExp(
        r'ValueData:\s*"\{app\}\\\{#(\w+)\}"',
      ).allMatches(iss))
        match.group(1)!,
    };
    expect(pointed, {'ProductBrowserManifest'});
    final named = {
      for (final match in RegExp(
        r'NativeMessagingHosts\\\{#(\w+)\}',
      ).allMatches(iss))
        match.group(1)!,
    };
    expect(named, {'ProductBrowserHost'});
  });

  test('the build looks for the host its id names, and the manifest', () {
    expect(builder, contains(r"'${spec.id}-browser-host.exe'"));
    expect(builder, contains('productBrowserManifest'));
    expect(builder, contains('/DProductBrowserHost=\$productBrowserHost'));
  });

  test('the extension is the one the manifests let in', () {
    expect(id, hasLength(32));
    expect(RegExp(r'^[a-p]{32}$').hasMatch(id), isTrue);
  });

  test('the extension asks for the hosts the products register', () {
    // The names it knows are written into it, and it is published on its own
    // (extension-v* tags): a product whose host is renamed without it never
    // being published again would find no host, silently.
    final background = File('browser_extension/background.js')
        .readAsStringSync();
    final list = RegExp(r'const HOSTS = \[([^\]]*)\]')
        .firstMatch(background)!
        .group(1)!;
    final hosts = {
      for (final match in RegExp(r"'([^']+)'").allMatches(list))
        match.group(1)!,
    };
    expect(hosts, {for (final product in Product.all) product.browserHost});
  });

  test('the host finds BaoCode without inheriting the same TEMP', () {
    final host = File('windows/BrowserBridge/host.cpp').readAsStringSync();
    expect(
      host,
      contains('SHGetKnownFolderPath'),
      reason:
          'A browser can start the host with a different TEMP/TMP than '
          'BaoCode, so the host must use Windows\' known local app data '
          'folder for the port file.',
    );
    expect(
      host,
      isNot(contains('GetTempPathW')),
      reason: 'TEMP/TMP are not a shared discovery point.',
    );
    expect(
      host,
      contains('L"LOCALAPPDATA"'),
      reason:
          'When Windows known folders are unavailable, the host must use '
          'the same LOCALAPPDATA fallback as the Dart bridge.',
    );
  });
}
