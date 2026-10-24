import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:path/path.dart' as p;

import '../files/ide_file.dart';
import '../files/recursive_watch.dart';
import 'git_types.dart';

const _gitEnvironment = {
  'GIT_TERMINAL_PROMPT': '0',
  'GIT_EDITOR': 'true',
  'GIT_OPTIONAL_LOCKS': '0',
};

List<String> _gitArguments(List<String> arguments) => [
  '--no-optional-locks',
  '-c',
  'core.fsmonitor=false',
  ...arguments,
];

/// The options that make Git run a program of the caller's: they are not
/// passed on, whoever asked for them.
const _forbiddenGitOptions = {
  '--exec-path',
  '--upload-pack',
  '--receive-pack',
  '--ssh-command',
  '--super-prefix',
};

/// The settings of `-c` that make Git run a program of the caller's.
const _forbiddenGitSettings = {
  'core.sshcommand',
  'core.pager',
  'core.editor',
  'core.gitproxy',
  'gpg.program',
  'diff.external',
  'diff.tool',
  'credential.helper',
  'sequence.editor',
};

/// Whether [arguments] are Git's own and safe to run: the ones that make
/// it run a program (`-c core.sshCommand=…`, `--upload-pack …`) are not.
bool gitArgumentsAreSafe(List<String> arguments) {
  for (var i = 0; i < arguments.length; i++) {
    final argument = arguments[i];
    // `--upload-pack=…` and the like, in one word.
    final equals = argument.indexOf('=');
    if (equals > 0) {
      final name = argument.substring(0, equals);
      if (_forbiddenGitOptions.contains(name)) return false;
      if (name == '-c' &&
          _forbiddenGitSettings.any(
            argument.substring(equals + 1).toLowerCase().startsWith,
          )) {
        return false;
      }
      continue;
    }
    if (_forbiddenGitOptions.contains(argument)) return false;
    // `-c` takes what follows as its own.
    if (argument == '-c' &&
        i + 1 < arguments.length &&
        _forbiddenGitSettings.any(arguments[i + 1].toLowerCase().startsWith)) {
      return false;
    }
  }
  return true;
}

/// Runs the local `git` without a shell, prompts or an editor, and without
/// optional index refreshes or a configured fsmonitor hook.
///
/// The options that make Git run a program of the caller's are refused:
/// they would run it with the user's own rights.
///
/// With [limit], the output is NUL-terminated records (`-z`) of which only
/// the first [limit] are read: Git is stopped at the one after, and the
/// output is [IdeGitOutput.truncated] (VS Code's `git.statusLimit`).
Future<IdeGitOutput> runGit(
  List<String> arguments, {
  required String workingDirectory,
  int? limit,
}) async {
  if (!gitArgumentsAreSafe(arguments)) {
    throw const IdeGitException('That Git command is not allowed.');
  }
  try {
    if (limit != null) {
      return await _runLimited(arguments, workingDirectory, limit);
    }
    final result = await Process.run(
      'git',
      _gitArguments(arguments),
      workingDirectory: workingDirectory,
      environment: _gitEnvironment,
      stdoutEncoding: utf8,
      stderrEncoding: utf8,
    ).timeout(const Duration(seconds: 60));
    return IdeGitOutput(
      result.exitCode,
      result.stdout as String,
      result.stderr as String,
    );
  } on ProcessException catch (error) {
    // Started in a folder there is not, the error is the same as for no Git.
    if (!Directory(workingDirectory).existsSync()) {
      throw IdeGitException('No such folder to run Git in: $workingDirectory');
    }
    throw IdeGitException(
      'Git is not installed or could not be started: ${error.message}',
    );
  } on TimeoutException {
    throw const IdeGitException('Git did not respond within 60 seconds.');
  } on FormatException {
    throw const IdeGitException('Git returned text that is not UTF-8.');
  }
}

/// [runGit] reading at most [limit] NUL-terminated records.
Future<IdeGitOutput> _runLimited(
  List<String> arguments,
  String workingDirectory,
  int limit,
) async {
  assert(limit > 0);
  final process = await Process.start(
    'git',
    _gitArguments(arguments),
    workingDirectory: workingDirectory,
    environment: _gitEnvironment,
  );
  final stdout = BytesBuilder(copy: false);
  final stderr = BytesBuilder(copy: false);
  var records = 0;
  // Where the [limit]th record ends.
  var end = -1;
  final more = Completer<bool>();
  late final StreamSubscription<List<int>> reading;
  reading = process.stdout.listen(
    (chunk) {
      var at = 0;
      while (true) {
        at = chunk.indexOf(0, at);
        if (at < 0) break;
        records++;
        if (records == limit) end = stdout.length + at + 1;
        if (records > limit) {
          stdout.add(chunk);
          unawaited(reading.cancel());
          process.kill();
          more.complete(true);
          return;
        }
        at++;
      }
      stdout.add(chunk);
    },
    onDone: () {
      if (!more.isCompleted) more.complete(false);
    },
    onError: (Object error) {
      if (!more.isCompleted) more.completeError(error);
    },
    cancelOnError: true,
  );
  final errors = process.stderr.listen(stderr.add).asFuture<void>();
  try {
    final truncated = await more.future.timeout(const Duration(seconds: 60));
    if (truncated) {
      final bytes = stdout.takeBytes();
      return IdeGitOutput.truncated(
        utf8.decode(Uint8List.sublistView(bytes, 0, end)),
      );
    }
    final exitCode = await process.exitCode.timeout(
      const Duration(seconds: 60),
    );
    await errors.timeout(const Duration(seconds: 5), onTimeout: () {});
    return IdeGitOutput(
      exitCode,
      utf8.decode(stdout.takeBytes()),
      utf8.decode(stderr.takeBytes(), allowMalformed: true),
    );
  } on TimeoutException {
    process.kill();
    unawaited(reading.cancel());
    rethrow;
  }
}

/// File changes under [repositoryRoot] that can change the status: the
/// working tree, and the index, HEAD and refs of `.git` (not its objects
/// or logs). An error (changes lost) is passed on.
Stream<void> watchRepository(String repositoryRoot) {
  final gitDir = p.join(repositoryRoot, '.git');
  bool relevant(String path) {
    if (!p.isWithin(gitDir, path)) return true;
    final inside = p.split(p.relative(path, from: gitDir));
    return switch (inside.first) {
      'index' || 'HEAD' || 'refs' || 'packed-refs' || 'MERGE_HEAD' => true,
      _ => false,
    };
  }

  try {
    return Directory(repositoryRoot)
        .watch(recursive: true)
        .where(
          (event) =>
              relevant(event.path) ||
              // `index.lock` renamed to `index`, as Git writes it.
              (event is FileSystemMoveEvent &&
                  event.destination != null &&
                  relevant(event.destination!)),
        )
        .map((_) {});
  } on FileSystemException {
    return const Stream.empty();
  } on UnsupportedError {
    return const Stream.empty();
  }
}

/// [watchRepository] where a tree cannot be watched whole (Linux): each
/// folder on its own, but not those of `.git` other than `refs`, nor the
/// dependency and build folders Quick Open skips.
Stream<void> watchRepositoryRecursively(String repositoryRoot) {
  final gitDir = p.join(repositoryRoot, '.git');
  bool relevant(String path) {
    if (!p.isWithin(gitDir, path)) return true;
    final inside = p.split(p.relative(path, from: gitDir));
    return switch (inside.first) {
      'index' || 'HEAD' || 'refs' || 'packed-refs' || 'MERGE_HEAD' => true,
      _ => false,
    };
  }

  return watchRecursively(
    repositoryRoot,
    skip: (dir) {
      if (p.isWithin(gitDir, dir)) {
        return p.split(p.relative(dir, from: gitDir)).first != 'refs';
      }
      return dir != gitDir &&
          ideIndexExcludedDirectories.contains(p.basename(dir));
    },
  ).where((event) => relevant(event.path)).map((_) {});
}
