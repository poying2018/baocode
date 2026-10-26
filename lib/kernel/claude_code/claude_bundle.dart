import 'dart:io';

import 'package:bao_remote/local.dart' show BundledClaude;
import 'package:path/path.dart' as p;

/// Where the Claude Code the app carries is looked for.
///
/// The app ships one in its bundle, so that a machine with no Claude Code
/// of its own needs no download: it is run as it is, and a newer one is
/// downloaded only when it is too old for what BaoCode asks of it (see
/// [ClaudeRuntime.rejectTooOld]).
///
/// It is looked for where the app's other carried files are (see
/// `bundledServerBinaries` in lib/remote/remote_binaries.dart): in the
/// bundle's resources on macOS, beside the executable elsewhere, and in the
/// checkout's `build/` in a development run.
abstract final class ClaudeBundle {
  /// The environment variable that says where it is, whatever the platform.
  static const directoryVariable = 'BAOCODE_CLAUDE_BUNDLE_DIR';

  /// The copy the app carries, if it carries one; null for none.
  static BundledClaude? find({
    Map<String, String>? environment,
    String? executable,
    String? current,
  }) {
    environment ??= Platform.environment;
    executable ??= Platform.resolvedExecutable;
    current ??= Directory.current.path;
    final exeDir = p.dirname(executable);
    final directories = [
      ?environment[directoryVariable],
      if (Platform.isMacOS) p.join(p.dirname(exeDir), 'Resources', 'claude'),
      p.join(exeDir, 'claude'),
      p.join(exeDir, 'data', 'claude'),
      p.join(current, 'build', 'claude'),
      // A debug build's executable is under the checkout's build/.
      for (var dir = exeDir, i = 0; i < 10; dir = p.dirname(dir), i++)
        if (p.basename(dir) == 'build') p.join(dir, 'claude'),
    ];
    for (final directory in directories) {
      if (BundledClaude.at(directory) case final found?) return found;
    }
    return null;
  }
}
