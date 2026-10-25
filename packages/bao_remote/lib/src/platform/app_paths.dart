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
  static String product([String? executable]) =>
      productOf(executable).id;

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

  /// The name [appName] shows: "BaoCode", "BaoCode Codex", "BaoCode Dev".
  static String displayName(
    Map<String, String> environment, {
    String? executable,
  }) {
    final parts = appName(environment, executable: executable)
        .split(RegExp('[-_]'))
        .where((part) => part.isNotEmpty)
        .toList();
    if (parts.isEmpty) return 'BaoCode';
    String capitalised(String part) =>
        part[0].toUpperCase() + part.substring(1);
    // "baocode" is one word with two capitals, not "Baocode".
    final first = parts.first == 'baocode' ? 'BaoCode' : capitalised(parts.first);
    return [first, ...parts.skip(1).map(capitalised)].join(' ');
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
