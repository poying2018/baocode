import 'dart:io';

import 'package:path/path.dart' as p;

import 'product.dart';

export 'product.dart';

/// Where the app and the user keep their files: what the platforms call
/// the same three places.
abstract final class AppPaths {
  /// The environment variable that tells this copy of the app from another
  /// one of the same program running at the same time. A development build
  /// (`BAOCODE_APP_ID=dev`) keeps its data folder, its windows and its
  /// title to itself, so that it does not disturb the installed one (and
  /// the installed one does not disturb it).
  static const appIdVariable = 'BAOCODE_APP_ID';

  /// This copy's id: [environment]'s, empty when it is not set.
  static String appId(Map<String, String> environment) =>
      (environment[appIdVariable] ?? '').trim();

  /// The product a build of the app is, as the program's own name says:
  /// BaoCode (the Claude Code one) or the codex one. The two are separate
  /// products: they keep their data apart, their windows apart and their
  /// registration apart, and neither disturbs the other.
  ///
  /// The name is the one source of it: the native side reads the same name
  /// (windows/runner/app_identity.cpp), so the two cannot disagree.
  ///
  /// A name that belongs to no product but says "baocode" (a build named
  /// otherwise, "baocode-codex-codex") keeps its own name: it is a
  /// product of its own, and its data folder is its own too.
  static String product([String? executable]) {
    // Split on both separators, as Product.byExecutable does: the path style
    // says nothing about the platform here — a Windows path may be named on
    // Linux (a test, a remote host's argument), where `p.basename` reads it
    // as one long name starting with `c:`.
    final name = (executable ?? Platform.resolvedExecutable)
        .split(RegExp(r'[/\\]'))
        .last
        .replaceFirst(RegExp(r'\.[^.]*$'), '')
        .toLowerCase();
    if (!name.startsWith('baocode')) return 'baocode';
    // A name with a space in it belongs to no product (macOS's ".app").
    if (name.contains(' ')) return 'baocode';
    return Product.byId(name)?.id ?? name;
  }

  /// The product a build of the app is, with what tells it apart: its
  /// name, its links, its registration, its update channel.
  static Product productOf([String? executable]) =>
      Product.byExecutable(executable ?? Platform.resolvedExecutable);

  /// The URL scheme this product answers to: a link with it opens this
  /// product, and no other.
  static String scheme([String? executable]) => productOf(executable).scheme;

  /// The name [product]'s folders carry, with this copy's id (see
  /// [appIdVariable]) when it has one: "baocode", "baocode-codex", or
  /// "baocode-dev" for a development copy of the first.
  static String appName(
    Map<String, String> environment, {
    String? executable,
  }) {
    final base = product(executable);
    final id = appId(environment);
    return id.isEmpty ? base : '$base-$id';
  }

  /// The name the app shows itself as: the product's own name
  /// ("BaoCode Claude", "BaoCode Codex"), with this copy's id (see
  /// [appIdVariable]) when it has one ("BaoCode Claude Dev").
  ///
  /// The name is the product's own (see [Product.displayName]), not one
  /// made up from its id: the id names the data folder and stays as it
  /// was, while the name the user sees is the one the product says.
  static String displayName(
    Map<String, String> environment, {
    String? executable,
  }) {
    final name = productOf(executable).displayName;
    final id = appId(environment);
    if (id.isEmpty) return name;
    String capitalised(String part) =>
        part[0].toUpperCase() + part.substring(1);
    return '$name ${capitalised(id)}';
  }

  /// Whether this product carries Claude Code: BaoCode does, the codex one
  /// does not — it has no Claude Code to carry, and says nothing of it.
  static bool hasClaudeCode([String? executable]) =>
      productOf(executable).hasClaudeCode;

  /// The user's home directory as [environment] says: `USERPROFILE` on
  /// Windows, `HOME` elsewhere.
  static String home(Map<String, String> environment) {
    for (final name
        in Platform.isWindows
            ? const ['USERPROFILE', 'HOME']
            : const ['HOME', 'USERPROFILE']) {
      if (environment[name] case final dir? when dir.isNotEmpty) return dir;
    }
    return '';
  }

  /// The platform's place for the app's data: `%APPDATA%\baocode` on
  /// Windows, `~/Library/Application Support/baocode` on macOS,
  /// `~/.config/baocode` elsewhere. The user may move it: the folder in use is
  /// `DataDirectory.current`. Each product keeps its own (see [product]),
  /// and so does a copy with an id of its own (see [appIdVariable]).
  static String dataDir(Map<String, String> environment, {String? executable}) {
    final homeDir = home(environment);
    final name = appName(environment, executable: executable);
    if (Platform.isWindows) {
      final appData = environment['APPDATA'] ?? '';
      return p.join(appData.isEmpty ? homeDir : appData, name);
    }
    return Platform.isMacOS
        ? p.join(homeDir, 'Library', 'Application Support', name)
        : p.join(homeDir, '.config', name);
  }

  /// Where what a session's tasks print is kept: `/tmp`, where that is
  /// where Claude Code puts it, and the system's own folder on Windows.
  static String get tempDir =>
      Platform.isWindows ? Directory.systemTemp.path : '/tmp';

  /// [path] with a leading `~` spelled out, as the shell would: a path the
  /// user typed, or an agent printed, may start at their home.
  static String expandHome(String path) {
    if (!path.startsWith('~/') && !path.startsWith(r'~\')) return path;
    final homeDir = home(Platform.environment);
    return homeDir.isEmpty ? path : '$homeDir${path.substring(1)}';
  }
}
