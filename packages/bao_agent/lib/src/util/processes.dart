import 'dart:async';
import 'dart:io';

import 'package:path/path.dart' as p;

/// The output of a process, read as it comes.
///
/// A child that outlives the process can hold the pipes open, so [ended]
/// stops reading after [grace] instead of waiting for the pipes to close.
class ProcessOutput {
  ProcessOutput(
    this.process, {
    required this.stdout,
    required this.stderr,
  }) {
    _reading = [
      process.stdout.listen(stdout),
      process.stderr.listen(stderr),
    ];
    _ended = Future.wait([for (final read in _reading) read.asFuture<void>()]);
  }

  final Process process;
  final void Function(List<int> bytes) stdout;
  final void Function(List<int> bytes) stderr;

  late final List<StreamSubscription<List<int>>> _reading;
  late final Future<void> _ended;

  /// Waits for the output to close, for [grace] at most.
  Future<void> ended({
    Duration grace = const Duration(seconds: 2),
  }) async {
    try {
      await _ended.timeout(grace);
    } on TimeoutException {
      await Future.wait([for (final read in _reading) read.cancel()]);
    } on Object {
      // A broken pipe: all that came was read.
    }
  }
}

/// Ends the process [pid] and every process it started, as a command's
/// shell leaves its children running when only it is killed. [windows]
/// for Windows' way of it (where this runs, when not given).
Future<void> killTree(int pid, {bool force = false, bool? windows}) async {
  if (windows ?? Platform.isWindows) {
    try {
      await Process.run('taskkill', ['/T', '/F', '/PID', '$pid']);
    } on ProcessException {
      Process.killPid(pid);
    }
    return;
  }
  final tree = <int>[pid, ...await _descendants(pid)];
  final signal = force ? ProcessSignal.sigkill : ProcessSignal.sigterm;
  // The children first, so none is left orphaned to go on.
  for (final id in tree.reversed) {
    Process.killPid(id, signal);
  }
  if (force) return;
  // What does not end on being asked is made to.
  unawaited(
    Future<void>.delayed(const Duration(seconds: 2), () {
      for (final id in tree) {
        Process.killPid(id, ProcessSignal.sigkill);
      }
    }),
  );
}

/// [environment] as a process is given it on Windows (when [windows];
/// where this runs, when not given), where a name is the same in any case:
/// of names that differ only in case, the last, as it is spelled. Both in
/// one environment (`NO_PROXY` and `no_proxy`) break .NET Framework's
/// programs, MSBuild among them (#976).
Map<String, String> caseFoldedEnvironment(
  Map<String, String> environment, {
  bool? windows,
}) {
  if (!(windows ?? Platform.isWindows)) return environment;
  final names = <String, String>{};
  final folded = <String, String>{};
  for (final MapEntry(:key, :value) in environment.entries) {
    if (names[key.toUpperCase()] case final earlier? when earlier != key) {
      folded.remove(earlier);
    }
    names[key.toUpperCase()] = key;
    folded[key] = value;
  }
  return folded;
}

Future<List<int>> _descendants(int pid) async {
  try {
    final result = await Process.run('ps', ['-A', '-o', 'pid=,ppid=']);
    final children = <int, List<int>>{};
    for (final line in '${result.stdout}'.split('\n')) {
      final parts = line.trim().split(RegExp(r'\s+'));
      if (parts.length != 2) continue;
      final child = int.tryParse(parts[0]);
      final parent = int.tryParse(parts[1]);
      if (child == null || parent == null) continue;
      (children[parent] ??= []).add(child);
    }
    final out = <int>[];
    final pending = [pid];
    while (pending.isNotEmpty) {
      final next = pending.removeLast();
      for (final child in children[next] ?? const <int>[]) {
        if (out.contains(child)) continue;
        out.add(child);
        pending.add(child);
      }
    }
    return out;
  } on ProcessException {
    return const [];
  }
}

/// How a [Shell] takes a command.
enum ShellKind {
  /// bash, zsh, sh: `-c`.
  posix,

  /// cmd.exe: `/d /s /c`.
  cmd,

  /// Windows PowerShell or PowerShell 7 (`pwsh`): `-Command`.
  powershell;

  /// What [executable] is, by its file name.
  static ShellKind of(String executable) {
    final name = p.windows.basename(executable).toLowerCase();
    return switch (name) {
      'cmd.exe' || 'cmd' => cmd,
      'powershell.exe' || 'powershell' || 'pwsh.exe' || 'pwsh' => powershell,
      _ => posix,
    };
  }
}

/// The shell commands are run in: the user's, when it is bash or zsh;
/// else bash; on Windows, the one the app's settings name
/// ([chosenVariable]), else the one set by `CLAUDE_CODE_GIT_BASH_PATH`,
/// else BaoCode Bash where the app installed it ([baoBashVariable]), else
/// Git's bash where it is installed, else cmd.exe.
class Shell {
  const Shell(
    this.executable, {
    this.kind = ShellKind.posix,
    this.baoBash = false,
    this.msys = false,
  });

  /// The variable the app names BaoCode Bash's `bash.exe` in
  /// (github.com/baocode-dev/bash-exe): bash 5.3 with `rg`, `grep`, `sed`,
  /// `awk`, `find`, `jq` and the like built in, that takes `C:\x` and
  /// `/c/x` alike.
  static const baoBashVariable = 'BAOCODE_BASH';

  /// The variable the app names the shell picked in its settings in
  /// (Windows): bash, cmd.exe or PowerShell, told apart by the file's
  /// name ([ShellKind.of]).
  static const chosenVariable = 'BAOCODE_SHELL';

  /// What a model is told of BaoCode Bash, which it would not expect of
  /// Windows: the tools it has, and the paths it takes. Short, the tools it
  /// might doubt named, and how to ask of any other.
  static const baoBashNote =
      'The shell is bash (BaoCode Bash), with the usual Unix tools built in: '
      '`rg`, `grep`, `sed`, `awk`, `find`, `xargs`, `jq`, `tar`, `diff`, '
      '`timeout`, `sha256sum`, the coreutils and more (`type -t NAME` says '
      '`builtin` for one). Paths print as `C:/x` (`pwd`, `\$PWD`, `\$HOME`, '
      '`realpath`); write them that way too, as bash and Windows programs '
      'both read it. `C:\\x` and `/c/x` name the same file, `/tmp` is the '
      'temporary folder, `cygpath -w`/`-u` converts, and '
      '`PATH="\$PATH:/c/tools"` adds a folder. Windows programs on the PATH '
      'run as usual and write UTF-8.';

  /// What a model is told of PowerShell, where it would write bash.
  static const powershellNote =
      'The shell is PowerShell, not bash: write PowerShell (`;` between '
      'commands, `\$env:NAME` for a variable, `Get-ChildItem`, '
      '`Select-String`).';

  final String executable;

  final ShellKind kind;

  /// Whether it takes POSIX shell commands (not cmd.exe or PowerShell).
  bool get posix => kind == ShellKind.posix;

  /// Whether it is BaoCode Bash, its tools there whatever is installed.
  final bool baoBash;

  /// Whether it says its paths the MSYS way (Git's bash on Windows:
  /// `/c/Users/me` where the machine has `C:\Users\me`).
  final bool msys;

  /// [path] as the machine spells it, when the shell does not: null for
  /// a shell that says its paths as they are.
  String? nativePath(String path) {
    if (!msys || !path.startsWith('/')) return null;
    final rest = path.substring(1);
    final slash = rest.indexOf('/');
    final drive = slash < 0 ? rest : rest.substring(0, slash);
    if (drive.length != 1) return null;
    final tail = slash < 0 ? '' : rest.substring(slash);
    final parts = [
      for (final part in tail.split('/'))
        if (part.isNotEmpty) part,
    ];
    if (parts.isEmpty) return '${drive.toUpperCase()}:\\';
    return p.windows.joinAll(['${drive.toUpperCase()}:', ...parts]);
  }

  /// The shell for [environment]'s user, on Windows when [windows] (where
  /// this runs, when not given); [exists] says whether a file is there.
  static Shell find(
    Map<String, String> environment, {
    bool? windows,
    bool Function(String path)? exists,
  }) {
    exists ??= (path) => File(path).existsSync();
    if (windows ?? Platform.isWindows) {
      final bao = environment[baoBashVariable];
      if (environment[chosenVariable] case final chosen?
          when chosen.isNotEmpty && (exists(chosen) || _onPath(chosen))) {
        return Shell(
          chosen,
          kind: ShellKind.of(chosen),
          baoBash: chosen == bao,
        );
      }
      if (environment['CLAUDE_CODE_GIT_BASH_PATH'] case final set?
          when exists(set)) {
        // Git's bash says its paths the MSYS way.
        return Shell(set);
      }
      if (bao != null && exists(bao)) return Shell(bao, baoBash: true);
      if (gitBash(environment, exists: exists) case final git?) {
        return Shell(git);
      }
      return Shell(environment['COMSPEC'] ?? 'cmd.exe', kind: ShellKind.cmd);
    }
    final user = environment['SHELL'];
    if (user != null &&
        (user.endsWith('/bash') || user.endsWith('/zsh')) &&
        exists(user)) {
      return Shell(user);
    }
    for (final candidate in const ['/bin/bash', '/usr/bin/bash', '/bin/zsh']) {
      if (exists(candidate)) return Shell(candidate);
    }
    return const Shell('/bin/sh');
  }

  /// A bare program name (`powershell.exe`), which Windows looks for on
  /// the PATH.
  static bool _onPath(String executable) =>
      !executable.contains(r'\') && !executable.contains('/');

  /// Git for Windows' `bash.exe` (by the git on [environment]'s PATH, else
  /// where its installer puts it); null where it is not installed.
  static String? gitBash(
    Map<String, String> environment, {
    bool Function(String path)? exists,
  }) {
    exists ??= (path) => File(path).existsSync();
    final path = p.windows;
    final candidates = [
      // Git's own, by the git on the PATH (`Git\cmd\git.exe`).
      for (final dir
          in (environment['PATH'] ?? environment['Path'] ?? '').split(';'))
        if (dir.isNotEmpty && exists(path.join(dir, 'git.exe')))
          path.normalize(path.join(dir, '..', 'bin', 'bash.exe')),
      r'C:\Program Files\Git\bin\bash.exe',
      r'C:\Program Files (x86)\Git\bin\bash.exe',
      if (environment['LOCALAPPDATA'] case final local?)
        path.join(local, 'Programs', 'Git', 'bin', 'bash.exe'),
    ];
    return candidates.where(exists).firstOrNull;
  }

  /// The arguments that run [command] once, as hooks and helpers are.
  List<String> run(String command) => switch (kind) {
    ShellKind.posix => ['-c', command],
    ShellKind.cmd => ['/d', '/s', '/c', command],
    ShellKind.powershell => _powershell(command, null),
  };

  /// The arguments that run [command], then write the folder it ended in
  /// to [cwdFile] (so that a `cd` holds for the next command).
  List<String> arguments(String command, String cwdFile) {
    if (kind == ShellKind.cmd) return run(command);
    if (kind == ShellKind.powershell) return _powershell(command, cwdFile);
    const script =
        r'eval "$1" < /dev/null; __bao_status=$?; '
        r'pwd -P >| "$2" 2>/dev/null; exit $__bao_status';
    return ['-c', script, p.basename(executable), command, cwdFile];
  }

  /// PowerShell's arguments for [command]: run as a string
  /// (`Invoke-Expression`, so that it parses as written), writing UTF-8,
  /// then the folder it ended in written to [cwdFile]. The status is the
  /// last program's, else 1 where a command failed. `-Command`, not
  /// `-EncodedCommand`: with that, Windows PowerShell writes its errors as
  /// CLIXML.
  static List<String> _powershell(String command, String? cwdFile) {
    String quoted(String text) => "'${text.replaceAll("'", "''")}'";
    final script = [
      r"$ProgressPreference = 'SilentlyContinue'",
      r'[Console]::OutputEncoding = [Text.Encoding]::UTF8',
      r'$OutputEncoding = [Text.Encoding]::UTF8',
      r'$global:LASTEXITCODE = 0',
      r'$__bao_errors = $Error.Count',
      'Invoke-Expression ${quoted(command)}',
      r'$__bao_ok = $? -and $Error.Count -eq $__bao_errors',
      r'$__bao_code = $global:LASTEXITCODE',
      if (cwdFile != null)
        'try { [IO.File]::WriteAllText(${quoted(cwdFile)}, '
            '(Get-Location).ProviderPath) } catch {}',
      r'if ($__bao_code) { exit $__bao_code }',
      r'if (-not $__bao_ok) { exit 1 }',
    ].join('\n');
    return [
      '-NoProfile',
      '-NonInteractive',
      '-ExecutionPolicy',
      'Bypass',
      '-Command',
      script,
    ];
  }
}
