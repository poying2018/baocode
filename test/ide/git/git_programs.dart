import 'dart:async';
import 'dart:io';

import 'package:path/path.dart' as p;

/// Whether Git's own work that runs a program of Git's (`push` over a
/// local path runs `sh`, an interactive rebase its editor sequence) can
/// run at all. On a machine where it cannot (an msys runtime object the
/// process may not create, 0xC0000022), the tests that need it are
/// skipped; Git's plain commands still run there.
///
/// The answer waits at the first read, as the probe runs a real `push`
/// on a throwaway repository. Never throws.
final Future<bool> canGitRunPrograms = Platform.isWindows ? _probe() : _yes;

final Future<bool> _yes = Future.value(true);

Future<bool> _probe() async {
  Directory? folder;
  try {
    folder = await Directory.systemTemp.createTemp('git_probe_');
    final repo = p.join(folder.path, 'repo');
    final server = p.join(folder.path, 'server.git');
    Directory(repo).createSync();
    Future<void> git(List<String> arguments, String where) async {
      final result = await Process.run(
        'git',
        arguments,
        workingDirectory: where,
      );
      if (result.exitCode != 0) throw 'git failed: ${result.stderr}';
    }

    await git(['init', '-q', '--bare', server], folder.path);
    await git(['init', '-q'], repo);
    await git(['config', 'user.email', 'a@b.c'], repo);
    await git(['config', 'user.name', 'A'], repo);
    await git(['commit', '-q', '--allow-empty', '-m', 'first'], repo);
    await git(['tag', 'v1'], repo);
    await git(['remote', 'add', 'origin', server], repo);
    await git(['push', '-q', 'origin', 'refs/tags/v1'], repo);
    return true;
  } on Object {
    return false;
  } finally {
    try {
      await folder?.delete(recursive: true);
    } on FileSystemException {
      // Left behind, a temp folder.
    }
  }
}
