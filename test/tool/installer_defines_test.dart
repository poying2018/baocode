// The installer's script is written once for both products. What tells them
// apart comes in as defines (tool/build_windows.dart), and every define has a
// default so that the script still compiles on its own.
//
// A name that stops matching is not an error Inno reports: a define the
// script uses but does not declare, or one the builder stops passing, quietly
// leaves the default standing — and the installer of one product writes the
// other's identity. These are the tests of that handoff, and of the
// uninstaller's key, which the app reads back by a name Setup wrote.
import 'dart:io';

import 'package:baocode/update/installer_io.dart' show windowsUninstallKey;
import 'package:flutter_test/flutter_test.dart';

String _read(String path) => File(path).readAsStringSync();

/// The defines the script declares: those it gives a default to (`#ifndef`)
/// and those it works out itself (`#define`).
Set<String> _declared(String iss) => {
  for (final match
      in RegExp(r'^\s*#(?:ifndef|define)\s+(\w+)', multiLine: true).allMatches(
        iss,
      ))
    match.group(1)!,
};

/// The defines the script gives a default to (`#ifndef Name`, then its
/// `#define`): these are the builder's to pass, and a default left standing is
/// the product's identity left standing. The ones the script works out itself
/// (`ArchSuffix` from `Arch`, `VersionNumber` from `AppVersion`) are not.
Set<String> _defaulted(String iss) => {
  for (final match
      in RegExp(r'^\s*#ifndef\s+(\w+)', multiLine: true).allMatches(iss))
    match.group(1)!,
};

/// The defines the script uses, as `{#Name}`.
Set<String> _used(String iss) => {
  for (final match in RegExp(r'\{#(\w+)\}').allMatches(iss))
    match.group(1)!,
};

/// The defines the builder passes, as `/DName=`.
Set<String> _passed(String builder) => {
  for (final match in RegExp(r"'/D(\w+)=").allMatches(builder))
    match.group(1)!,
};

void main() {
  final iss = _read('tool/baocode.iss');
  final builder = _read('tool/build_windows.dart');

  test('the script uses no define it does not declare', () {
    // One it does not declare is Inno's own, or a typo the default hides.
    expect(_used(iss).difference(_declared(iss)), isEmpty);
  });

  test('the builder passes every define the script has a default for', () {
    // The channel build's, which only that build passes.
    final needed = _defaulted(iss)..remove('Edition');
    expect(
      needed.difference(_passed(builder)),
      isEmpty,
      reason: 'a default left standing installs as BaoCode',
    );
  });

  test('the builder passes no define the script does not declare', () {
    // Inno would say nothing: an unused define is not an error.
    expect(_passed(builder).difference(_declared(iss)), isEmpty);
  });

  test('the identity Setup writes is the product the builder was given', () {
    expect(builder, contains('final productId = spec.appId;'));
    // One brace for Setup, as it reads a leading "{" as a constant's.
    expect(
      builder,
      contains(r"productId.replaceAll('{', '{{')"),
    );
    expect(builder, contains(r"'/DProductId=$installerAppId',"));
    expect(builder, contains(r"'/DProductDir=${spec.directoryName}',"));
    expect(builder, contains(r"'/DProductExe=$binaryName.exe',"));
    expect(builder, contains(r"'/DProductScheme=$productScheme',"));
    // Setup keeps the installed app under the AppId it was given.
    expect(iss, contains('AppId={#ProductId}'));
  });

  test('the uninstall key the app reads is the one Setup writes', () {
    // Setup's own default, spelled as it spells a GUID: { { for one brace.
    final defaultId = RegExp(r'#define ProductId "(\S+)"')
        .firstMatch(iss)!
        .group(1)!
        .replaceAll('{{', '{');
    expect(
      windowsUninstallKey('baocode'),
      'Software\\Microsoft\\Windows\\CurrentVersion\\Uninstall\\${defaultId}_is1',
    );
    // Each product has one of its own: one does not read the other's install.
    expect(
      windowsUninstallKey('baocode-codex'),
      isNot(windowsUninstallKey('baocode')),
    );
  });
}
