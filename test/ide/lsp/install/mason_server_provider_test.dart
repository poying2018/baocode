import 'dart:convert';
import 'dart:io';

import 'package:bao_remote/lsp.dart' show jdtlsLauncher;
import 'package:flutter_test/flutter_test.dart';
import 'package:baocode/ide/lsp/install/archive.dart';
import 'package:baocode/ide/lsp/install/install_io.dart';
import 'package:baocode/ide/lsp/install/mason_platform.dart';
import 'package:baocode/ide/lsp/install/mason_registry.dart';
import 'package:baocode/ide/lsp/install/mason_server_provider.dart';
import 'package:baocode/ide/lsp/lsp_server_definition.dart';
import 'package:path/path.dart' as p;

const fixtures = 'test/fixtures/lsp/mason';
const mac = MasonPlatform('darwin', 'arm64');
const win = MasonPlatform('win', 'x64');

/// The machine the tests run on: the files are on it, however the
/// package under test was built for another platform.
final machine = MasonServerProvider.currentPlatform();

/// Whether [file] may be run: its executable bit on Unix, its being a file
/// on Windows (where there are none).
bool _executable(File file) =>
    Platform.isWindows ? file.existsSync() : file.statSync().mode & 0x40 != 0;

/// What the link at [path] points at; where Windows could not make one,
/// the copy of the target it made instead.
String _linkTarget(String path) {
  final link = Link(path);
  if (link.existsSync()) return link.targetSync();
  // A copy of the target: what it holds is what the link pointed at.
  return File(path).readAsStringSync().contains('fake-ls') ? 'fake-ls' : '';
}

/// The smallest bytes Windows accepts as a program: a PE image.
List<int> _windowsProgram() => [
  0x4D, 0x5A, // 'MZ'
  ...List<int>.filled(0x3A, 0),
  0x40, 0, 0, 0, // the offset of the PE header
  0x50, 0x45, 0, 0, // 'PE'
  ...List<int>.filled(0x34, 0),
];

/// Serves fixture files for URLs by their last path segment; never the
/// network.
class FakeDownloader implements Downloader {
  FakeDownloader(this.files);

  final Map<String, String> files;
  final requested = <Uri>[];

  @override
  Future<void> download(
    Uri url,
    String destination, {
    void Function(int received, int? total)? onProgress,
  }) async {
    requested.add(url);
    final fixture = files[url.pathSegments.last];
    if (fixture == null) throw HttpException('HTTP 404', uri: url);
    final bytes = await File(p.join(fixtures, fixture)).readAsBytes();
    onProgress?.call(bytes.length ~/ 2, bytes.length);
    onProgress?.call(bytes.length, bytes.length);
    await File(destination).writeAsBytes(bytes);
  }
}

/// Records commands and acts out what each installer would leave behind;
/// `chmod` really runs (a local file mode change).
class FakeRunner implements CommandRunner {
  FakeRunner({this.exitCode = 0, MasonPlatform? platform})
    : platform = platform ?? MasonServerProvider.currentPlatform();

  final int exitCode;

  /// The platform the package is installed for: it decides the name the
  /// installer writes its executable under.
  final MasonPlatform platform;
  final calls = <(String, List<String>, Map<String, String>?)>[];

  @override
  Future<CommandResult> run(
    String executable,
    List<String> arguments, {
    String? workingDirectory,
    Map<String, String>? environment,
  }) async {
    if (executable == 'chmod') {
      try {
        final result = await Process.run('chmod', arguments);
        return CommandResult(result.exitCode, stderr: '${result.stderr}');
      } on ProcessException {
        // No chmod on Windows: the mode is the file's business there.
        return const CommandResult(0);
      }
    }
    // The command as it was given: the path matters, as where the
    // installer left things depends on it.
    calls.add((executable, arguments, environment));
    if (exitCode != 0) {
      return CommandResult(
        exitCode,
        stderr: 'boom from ${p.basename(executable)}',
      );
    }
    Future<void> touch(String path) async {
      await File(path).create(recursive: true);
      await File(path).writeAsString('#!/bin/sh\n');
      try {
        await Process.run('chmod', ['+x', path]);
      } on ProcessException {
        // No chmod on Windows; the platform under test says executable
        // there anyway.
      }
    }

    // The name the installer wrote it under: the platform the package is
    // installed for decides it.
    String named(String name) => platform.isWindows ? '$name.exe' : name;

    // The program the command is: its own name, without the extension
    // the machine gives it.
    final program = p.basenameWithoutExtension(executable).toLowerCase();

    switch (program) {
      case 'npm':
        final prefix = arguments[arguments.indexOf('--prefix') + 1];
        await touch(p.join(prefix, 'node_modules', '.bin', 'fake-npm-ls'));
        await touch(
          p.join(prefix, 'node_modules', '.bin', 'fake-npm-ls.cmd'),
        );
      case 'node'
          when arguments.isNotEmpty && arguments.first.endsWith('npm-cli.js'):
        // Run as node with npm's own script (Windows): the same install,
        // the same things left behind.
        final prefix = arguments[arguments.indexOf('--prefix') + 1];
        await touch(p.join(prefix, 'node_modules', '.bin', 'fake-npm-ls'));
        await touch(
          p.join(prefix, 'node_modules', '.bin', 'fake-npm-ls.cmd'),
        );
      case 'python'
          when arguments.contains('-m') && arguments.contains('venv'):
        // The venv's own python: where pip runs from.
        await touch(p.join(arguments.last, 'bin', 'python'));
      case 'python':
        await touch(p.join(p.dirname(executable), named('fake-py-ls')));
      case 'go':
        await touch(p.join(environment!['GOBIN']!, named('fake-go-ls')));
      case 'cargo':
        final root = arguments[arguments.indexOf('--root') + 1];
        await touch(p.join(root, 'bin', named('fake-cargo-ls')));
    }
    return const CommandResult(0);
  }
}

final registry = MasonRegistry.fromJson({
  'packages': [
    {
      'name': 'fake-zip',
      'categories': ['LSP'],
      'source': {
        'id': 'pkg:github/example/fake-ls@v1.0.0',
        'asset': [
          {
            'target': 'darwin_arm64',
            'file': 'fake-ls-{{ version | strip_prefix "v" }}.zip',
            'bin': 'fake-ls/bin/fake-ls',
          },
          {
            'target': 'win_x64',
            'file': 'fake-ls-{{ version | strip_prefix "v" }}.zip',
            'bin': 'fake-ls/bin/fake-ls',
          },
          {
            'target': 'linux_x64',
            'file': 'fake-ls-{{ version | strip_prefix "v" }}.zip',
            'bin': 'fake-ls/bin/fake-ls',
          },
        ],
      },
      'bin': {'fake-ls': '{{source.asset.bin}}'},
    },
    {
      'name': 'fake-tar',
      'source': {
        'id': 'pkg:github/example/fake-ls@1.0',
        'asset': {
          'file': 'fake-ls.tar.gz:libexec/',
          'bin': 'exec:libexec/fake-ls-1.0/bin/fake-ls',
        },
      },
      'bin': {
        'fake-tar-ls': '{{source.asset.bin}}',
        'fake-tar-node': 'node:libexec/fake-ls-1.0/bin/fake-ls',
      },
    },
    {
      'name': 'fake-gz',
      'source': {
        'id': 'pkg:github/example/fake-ls@1.0',
        'asset': {'file': 'fake-ls.gz'},
      },
      'bin': {'fake-gz-ls': 'fake-ls'},
    },
    {
      'name': 'fake-npm',
      'categories': ['LSP'],
      'source': {
        'id': 'pkg:npm/%40example/fake-npm-ls@2.0.0',
        'extra_packages': ['typescript@5.9.3'],
      },
      'bin': {'fake-npm-ls': 'npm:fake-npm-ls'},
    },
    {
      'name': 'fake-pypi',
      'source': {'id': 'pkg:pypi/fake-py-ls@0.5?extra=all'},
      'bin': {'fake-py-ls': 'pypi:fake-py-ls'},
    },
    {
      'name': 'fake-go',
      'source': {
        'id': 'pkg:golang/example.com/tools/fake@v0.1.0#cmd/fake-go-ls',
      },
      'bin': {'fake-go-ls': 'golang:fake-go-ls'},
    },
    {
      'name': 'fake-cargo',
      'source': {
        'id': 'pkg:cargo/fake-cargo-ls@1.2.3?repository_url=https://github.com/example/fake&features=lsp&locked=true',
      },
      'bin': {'fake-cargo-ls': 'cargo:fake-cargo-ls'},
    },
    {
      'name': 'fake-opam',
      'source': {'id': 'pkg:opam/fake-opam-ls@1'},
      'bin': {'fake-opam-ls': 'opam:fake-opam-ls'},
    },
  ],
});

void main() {
  group('jdtls\'s launcher', () {
    late Directory dir;
    late String package;
    late String javaHome;
    setUp(() {
      dir = Directory.systemTemp.createTempSync('jdtls-launcher');
      package = p.join(dir.path, 'jdtls');
      for (final folder in ['plugins', 'config_mac', 'config_linux']) {
        Directory(p.join(package, folder)).createSync(recursive: true);
      }
      File(p.join(package, 'plugins', 'org.eclipse.equinox.launcher_1.7.jar'))
          .writeAsStringSync('');
      File(p.join(package, 'lombok.jar')).writeAsStringSync('');
      File(p.join(package, 'mason-bin', 'jdtls'))
        ..createSync(recursive: true)
        ..writeAsStringSync(jdtlsLauncher(windows: false));
      javaHome = p.join(dir.path, 'java home');
      Directory(p.join(javaHome, 'bin')).createSync(recursive: true);
    });
    tearDown(() => dir.deleteSync(recursive: true));

    /// A java that says it is [version], and writes what it runs with.
    void java(String version) {
      final java = File(p.join(javaHome, 'bin', 'java'))
        ..writeAsStringSync(
          '#!/bin/sh\n'
          'if [ "\$1" = -version ]; then\n'
          '  echo \'openjdk version "$version" 2026-01-20\' >&2\n'
          '  exit 0\n'
          'fi\n'
          'printf "%s\\n" "\$@" > "${p.join(dir.path, 'args')}"\n',
        );
      try {
        Process.runSync('chmod', [
          '755',
          java.path,
          '$package/mason-bin/jdtls',
        ]);
      } on ProcessException {
        // No chmod on Windows.
      }
    }

    Future<ProcessResult> run() => Process.run(
      p.join(package, 'mason-bin', 'jdtls'),
      const [],
      workingDirectory: dir.path,
      environment: {'JAVA_HOME': javaHome},
    );

    test('runs java with the launcher jar, the platform\'s configuration '
        'and Lombok', () async {
      java('21.0.2');
      final result = await run();
      expect(result.exitCode, 0, reason: '${result.stderr}');
      final args = File(p.join(dir.path, 'args')).readAsLinesSync();
      expect(
        args,
        containsAll([
          '-jar',
          p.join(package, 'plugins', 'org.eclipse.equinox.launcher_1.7.jar'),
          '-javaagent:${p.join(package, 'lombok.jar')}',
          '-data',
        ]),
      );
      expect(
        args,
        contains(
          startsWith('-Dosgi.sharedConfiguration.area=$package/config_'),
        ),
      );
    });

    test('says when java is too old', () async {
      java('17.0.9');
      final result = await run();
      expect(result.exitCode, 1);
      expect(result.stderr, contains('Java 21 or newer'));
      expect(result.stderr, contains('not Java 17'));
    });
  }, skip: Platform.isWindows);

  late Directory temp;
  late String root;
  late String toolsDir;
  late Map<String, String> environment;

  setUp(() async {
    temp = await Directory.systemTemp.createTemp('mason_provider_test');
    root = p.join(temp.path, 'servers');
    toolsDir = p.join(temp.path, 'tools');
    await Directory(toolsDir).create();
    environment = {'PATH': toolsDir, 'HOME': temp.path};
  });

  tearDown(() => temp.delete(recursive: true));

  /// A tool in the tools folder, as the machine would look for it: with
  /// one of its extensions on Windows, and a program Windows can start.
  Future<void> tool(String name) async {
    final path = p.join(toolsDir, name);
    // Windows starts a PE image, or a batch file; elsewhere the
    // executable bit is what counts.
    await File(path).writeAsBytes(
      Platform.isWindows ? _windowsProgram() : '#!/bin/sh\n'.codeUnits,
    );
    // Windows looks for a command with one of its extensions, as
    // `cmd.exe` does.
    if (Platform.isWindows) {
      await File('$path.cmd').writeAsString('@echo off\r\n');
    }
    try {
      await Process.run('chmod', ['+x', path]);
    } on ProcessException {
      // No chmod on Windows; the platform under test says executable
      // there anyway.
    }
  }

  /// The path of the tool [name] as this machine spells it: with the
  /// extension Windows gives it.
  String toolPath(String name) =>
      Platform.isWindows ? p.join(toolsDir, '$name.cmd') : p.join(toolsDir, name);

  /// A Windows-style Node folder: only `npm.cmd` (and node) on PATH, npm's
  /// Bash script beside it as a plain extensionless file, and its
  /// `npm-cli.js` where the .cmd points.
  Future<void> windowsTools() async {
    await File(p.join(toolsDir, 'node.exe')).writeAsString('node');
    await File(p.join(toolsDir, 'npm.cmd')).writeAsString('@echo off\r\n');
    await File(p.join(toolsDir, 'npm')).writeAsString('#!/bin/sh\n');
    final script = File(
      p.join(toolsDir, 'node_modules', 'npm', 'bin', 'npm-cli.js'),
    );
    await script.parent.create(recursive: true);
    await script.writeAsString('// npm\n');
  }

  MasonServerProvider provider({
    FakeDownloader? downloader,
    FakeRunner? runner,
    MasonPlatform? platform,
  }) {
    // The machine's own platform, unless the test asks for another: the
    // files are on this machine, however the package is built for.
    final target = platform ?? MasonServerProvider.currentPlatform();
    return MasonServerProvider(
      registry: registry,
      installRoot: root,
      downloader:
          downloader ??
          FakeDownloader({
            'fake-ls-1.0.0.zip': 'fake-ls.zip',
            'fake-ls.tar.gz': 'fake-ls.tar.gz',
            'fake-ls.gz': 'fake-ls.gz',
          }),
      runner: runner ?? FakeRunner(platform: target),
      environment: () async => environment,
      platform: target,
    );
  }

  LspServerDefinition server(String command, [String? package]) =>
      LspServerDefinition(id: command, command: command, masonPackage: package);

  group('archives', () {
    Future<List<String>> unpack(String fixture) async {
      final file = p.join(temp.path, fixture);
      await File(p.join(fixtures, fixture)).copy(file);
      final executables = await unpackDownload(file, runner: FakeRunner());
      expect(File(file).existsSync(), isFalse, reason: 'archive removed');
      return [
        for (final e in executables)
          p.relative(e, from: temp.path).replaceAll(r'\', '/'),
      ];
    }

    test('zip: files, modes, directories and symlinks', () async {
      expect(await unpack('fake-ls.zip'), ['fake-ls/bin/fake-ls']);
      final dir = p.join(temp.path, 'fake-ls');
      expect(
        File(p.join(dir, 'bin', 'fake-ls')).readAsStringSync(),
        contains('echo fake-ls'),
      );
      expect(File(p.join(dir, 'share', 'readme.txt')).lengthSync(), 300);
      expect(_linkTarget(p.join(dir, 'bin', 'fake-link')), 'fake-ls');
    });

    test('tar.gz: GNU long names, symlinks and hard links', () async {
      expect(await unpack('fake-ls.tar.gz'), [
        'fake-ls-1.0/bin/fake-ls',
        'fake-ls-1.0/bin/fake-hard',
      ]);
      final dir = p.join(temp.path, 'fake-ls-1.0');
      expect(
        File(
          p.joinAll([
            dir,
            ...List.filled(6, 'long-directory-name'),
            'deep.txt',
          ]),
        ).readAsStringSync(),
        'deep',
      );
      expect(_linkTarget(p.join(dir, 'bin', 'fake-link')), 'fake-ls');
      expect(
        File(p.join(dir, 'bin', 'fake-hard')).readAsStringSync(),
        contains('echo fake-ls'),
      );
    });

    test('pax tar and single gzip files', () async {
      await unpack('fake-ls-pax.tar');
      expect(
        File(
          p.joinAll([
            temp.path,
            'fake-ls-1.0',
            ...List.filled(6, 'long-directory-name'),
            'deep.txt',
          ]),
        ).existsSync(),
        isTrue,
      );
      await unpack('fake-ls.gz');
      expect(
        File(p.join(temp.path, 'fake-ls')).readAsStringSync(),
        contains('echo fake-ls'),
      );
    });

    test('entries escaping the folder are refused', () async {
      await expectLater(
        unpack('escape.zip'),
        throwsA(isA<LspInstallException>()),
      );
      expect(
        File(p.join(p.dirname(temp.path), 'escaped.txt')).existsSync(),
        isFalse,
      );
    });

    test('other files are left as they are', () async {
      final file = p.join(temp.path, 'server.jar');
      await File(file).writeAsString('jar');
      expect(await unpackDownload(file, runner: FakeRunner()), isEmpty);
      expect(File(file).existsSync(), isTrue);
    });
  });

  group('install', () {
    test('GitHub zip asset: unpacked, executable, manifest, located', () async {
      final downloader = FakeDownloader({'fake-ls-1.0.0.zip': 'fake-ls.zip'});
      final messages = <String>[];
      final mason = provider(downloader: downloader);
      expect(
        await mason.locate(server('fake-ls', 'fake-zip')),
        isA<LspServerMissing>()
            .having((m) => m.package, 'package', 'fake-zip')
            .having((m) => m.missingRuntime, 'runtime', isNull),
      );
      await mason.install('fake-zip', onProgress: messages.add);
      expect(
        downloader.requested.single.toString(),
        'https://github.com/example/fake-ls/releases/download/v1.0.0/fake-ls-1.0.0.zip',
      );
      expect(messages, contains('Downloading fake-ls-1.0.0.zip (100%)'));
      expect(messages.last, 'Installed fake-zip v1.0.0');
      final manifest = (await mason.installed('fake-zip'))!;
      expect(manifest.version, 'v1.0.0');
      expect(manifest.source, 'pkg:github/example/fake-ls@v1.0.0');
      expect(manifest.bin, {'fake-ls': 'fake-ls/bin/fake-ls'});
      final location = await mason.locate(server('fake-ls', 'fake-zip'));
      expect(
        (location as LspServerFound).executable,
        p.join(root, 'fake-zip', 'fake-ls', 'bin', 'fake-ls'),
      );
      // Found among installed packages even when the definition names none.
      expect(await mason.locate(server('fake-ls')), isA<LspServerFound>());
      expect(Directory(p.join(root, '.staging')).listSync(), isEmpty);
      expect(await mason.installedPackages(), ['fake-zip']);
    });

    test('tar.gz into a destination folder, with a node wrapper', () async {
      final mason = provider();
      await mason.install('fake-tar');
      final dir = p.join(root, 'fake-tar');
      final manifest = (await mason.installed('fake-tar'))!;
      // The wrapper is a `.cmd` on Windows: it is what `cmd.exe` runs.
      final wrapperName = machine.isWindows ? 'fake-tar-node.cmd' : 'fake-tar-node';
      expect(manifest.bin, {
        'fake-tar-ls': 'libexec/fake-ls-1.0/bin/fake-ls',
        'fake-tar-node': 'mason-bin/$wrapperName',
      });
      final wrapper = File(p.join(dir, 'mason-bin', wrapperName));
      // The wrapper is what the machine runs: a shell script elsewhere, a
      // batch file on Windows.
      expect(
        wrapper.readAsStringSync(),
        machine.isWindows
            ? contains(r'node "%~dp0..\libexec\fake-ls-1.0\bin\fake-ls"')
            : contains(r'exec node "$dir/libexec/fake-ls-1.0/bin/fake-ls" "$@"'),
      );
      expect(_executable(wrapper), isTrue);
      final location = await mason.locate(server('fake-tar-node', 'fake-tar'));
      expect((location as LspServerFound).executable, wrapper.path);
    });

    test('a raw gzip binary is unpacked and made executable', () async {
      final mason = provider();
      await mason.install('fake-gz');
      final bin = File(p.join(root, 'fake-gz', 'fake-ls'));
      expect(_executable(bin), isTrue);
      expect(
        await mason.locate(server('fake-gz-ls', 'fake-gz')),
        isA<LspServerFound>(),
      );
    });

    test('npm: needs node and npm, installs with extras', () async {
      final runner = FakeRunner();
      final mason = provider(runner: runner);
      expect(
        await mason.locate(server('fake-npm-ls', 'fake-npm')),
        isA<LspServerMissing>()
            .having((m) => m.package, 'package', 'fake-npm')
            .having((m) => m.missingRuntime, 'runtime', 'node'),
      );
      await expectLater(
        mason.install('fake-npm'),
        throwsA(
          isA<LspInstallException>().having(
            (e) => e.message,
            'message',
            'Installing fake-npm needs node, which is not on PATH',
          ),
        ),
      );
      expect(Directory(p.join(root, 'fake-npm')).existsSync(), isFalse);
      await tool('node');
      expect(
        (await mason.locate(
          server('fake-npm-ls', 'fake-npm'),
        ) as LspServerMissing).missingRuntime,
        'npm',
      );
      await tool('npm');
      await mason.install('fake-npm');
      final (npm, arguments, env) = runner.calls.single;
      // The machine's own name for npm: with the extension it gives it.
      expect(npm, toolPath('npm'));
      expect(arguments, [
        'install',
        '--prefix',
        p.join(root, '.staging', arguments[2].split(p.separator).last),
        '--no-audit',
        '--no-fund',
        '--loglevel=error',
        '@example/fake-npm-ls@2.0.0',
        'typescript@5.9.3',
      ]);
      expect(env?['PATH'], toolsDir);
      final dir = p.join(root, 'fake-npm');
      expect(
        jsonDecode(File(p.join(dir, 'package.json')).readAsStringSync()),
        containsPair('private', true),
      );
      expect(
        (await mason.locate(
          server('fake-npm-ls', 'fake-npm'),
        ) as LspServerFound).executable,
        // npm writes the bin with the machine's own extension.
        machine.isWindows
            ? p.join(dir, 'node_modules', '.bin', 'fake-npm-ls.cmd')
            : p.join(dir, 'node_modules', '.bin', 'fake-npm-ls'),
      );
    });

    test('npm on Windows: npm.cmd answers for npm, run through node', () async {
      final runner = FakeRunner();
      final mason = provider(runner: runner, platform: win);
      // node there, but only npm's Bash script (nvm-windows', the
      // installer's folder keeps it beside npm.cmd): the bare name is not
      // a Win32 program, and starting it is what says so.
      await File(p.join(toolsDir, 'node.exe')).writeAsString('node');
      await File(p.join(toolsDir, 'npm')).writeAsString('#!/bin/sh\n');
      await expectLater(
        mason.install('fake-npm'),
        throwsA(
          isA<LspInstallException>().having(
            (e) => e.message,
            'message',
            'Installing fake-npm needs npm, which is not on PATH',
          ),
        ),
      );
      // npm.cmd answering: its own npm-cli.js runs with node, the quotes
      // of a Program Files path and a spaced user name kept by both.
      await windowsTools();
      await mason.install('fake-npm');
      final (npm, arguments, env) = runner.calls.single;
      expect(p.basename(npm).toLowerCase(), 'node.exe');
      expect(
        arguments.first,
        endsWith(p.join('node_modules', 'npm', 'bin', 'npm-cli.js')),
      );
      expect(arguments, containsAllInOrder(['install', '--no-audit']));
      expect(env?['PATH'], toolsDir);
      final dir = p.join(root, 'fake-npm');
      expect(
        (await mason.locate(
          server('fake-npm-ls', 'fake-npm'),
        ) as LspServerFound).executable,
        // The bin is the .cmd on Windows, as npm writes it there.
        p.join(dir, 'node_modules', '.bin', 'fake-npm-ls.cmd'),
      );
    });

    test('pypi: a venv in place, with the extra', () async {
      // The runtime is `python3` elsewhere, `python` on Windows.
      await tool(machine.isWindows ? 'python' : 'python3');
      final runner = FakeRunner();
      final mason = provider(runner: runner);
      await mason.install('fake-pypi');
      final dir = p.join(root, 'fake-pypi');
      expect(runner.calls[0].$2, ['-m', 'venv', p.join(dir, 'venv')]);
      // pip runs with the venv's own python: in `bin` elsewhere, in
      // `Scripts` on Windows.
      expect(
        runner.calls[1].$1,
        machine.isWindows
            ? p.join(dir, 'venv', 'Scripts', 'python.exe')
            : p.join(dir, 'venv', 'bin', 'python'),
      );
      expect(runner.calls[1].$2, containsAllInOrder(['-m', 'pip', 'install']));
      expect(runner.calls[1].$2.last, 'fake-py-ls[all]==0.5');
      expect(
        (await mason.locate(
          server('fake-py-ls', 'fake-pypi'),
        ) as LspServerFound).executable,
        machine.isWindows
            ? p.join(dir, 'venv', 'Scripts', 'fake-py-ls.exe')
            : p.join(dir, 'venv', 'bin', 'fake-py-ls'),
      );
    });

    test('go: GOBIN is the package folder, subpath kept', () async {
      await tool('go');
      final runner = FakeRunner();
      final mason = provider(runner: runner);
      await mason.install('fake-go');
      final (_, arguments, env) = runner.calls.single;
      expect(arguments, [
        'install',
        'example.com/tools/fake/cmd/fake-go-ls@v0.1.0',
      ]);
      expect(env?['GOBIN'], startsWith(p.join(root, '.staging')));
      expect(
        await mason.locate(server('fake-go-ls', 'fake-go')),
        isA<LspServerFound>(),
      );
    });

    test('cargo: --root, git source, features and --locked', () async {
      await tool('cargo');
      final runner = FakeRunner();
      final mason = provider(runner: runner);
      await mason.install('fake-cargo');
      final arguments = runner.calls.single.$2;
      expect(arguments.sublist(3), [
        '--git',
        'https://github.com/example/fake',
        '--tag',
        '1.2.3',
        'fake-cargo-ls',
        '--features',
        'lsp',
        '--locked',
      ]);
      expect(
        (await mason.locate(
          server('fake-cargo-ls', 'fake-cargo'),
        ) as LspServerFound).executable,
        p.join(
          root,
          'fake-cargo',
          'bin',
          // cargo names the executable with the machine's extension.
          machine.isWindows ? 'fake-cargo-ls.exe' : 'fake-cargo-ls',
        ),
      );
    });

    test('a failed reinstall keeps the working install', () async {
      await tool('go');
      await provider().install('fake-go');
      final failing = provider(runner: FakeRunner(exitCode: 2));
      await expectLater(
        failing.install('fake-go'),
        throwsA(
          isA<LspInstallException>()
              .having((e) => e.message, 'message', 'go install failed (exit 2)')
              .having((e) => e.detail, 'detail', contains('boom')),
        ),
      );
      expect(
        await failing.locate(server('fake-go-ls', 'fake-go')),
        isA<LspServerFound>(),
      );
      expect(Directory(p.join(root, '.staging')).listSync(), isEmpty);

      await tool(machine.isWindows ? 'python' : 'python3');
      await provider().install('fake-pypi');
      await expectLater(
        failing.install('fake-pypi'),
        throwsA(isA<LspInstallException>()),
      );
      expect(
        await failing.locate(server('fake-py-ls', 'fake-pypi')),
        isA<LspServerFound>(),
      );
    });

    test('download failures and unknown packages throw', () async {
      final mason = provider(downloader: FakeDownloader({}));
      await expectLater(
        mason.install('fake-zip'),
        throwsA(
          isA<LspInstallException>().having(
            (e) => e.message,
            'message',
            'Could not download fake-ls-1.0.0.zip',
          ),
        ),
      );
      expect(Directory(p.join(root, 'fake-zip')).existsSync(), isFalse);
      await expectLater(
        mason.install('nope'),
        throwsA(isA<LspInstallException>()),
      );
      await expectLater(
        mason.install('fake-opam'),
        throwsA(isA<LspInstallException>()),
      );
    });

    test('concurrent installs of one package share the work', () async {
      final downloader = FakeDownloader({'fake-ls-1.0.0.zip': 'fake-ls.zip'});
      final mason = provider(downloader: downloader);
      await Future.wait([mason.install('fake-zip'), mason.install('fake-zip')]);
      expect(downloader.requested, hasLength(1));
    });
  });

  group('on Windows', () {
    MasonServerProvider windows() => MasonServerProvider(
      registry: registry,
      installRoot: root,
      downloader: FakeDownloader(const {}),
      runner: FakeRunner(),
      environment: () async => environment,
      platform: const MasonPlatform('win', 'x64'),
    );

    test('runs npm-cli.js with node, not npm.cmd through cmd.exe', () async {
      final npm = p.join(toolsDir, 'npm.cmd');
      final node = p.join(toolsDir, 'node.exe');
      Future<List<String>> command(MasonServerProvider mason) async {
        final (executable, arguments) = await mason.npmCommand(npm, node);
        return [executable, ...arguments];
      }

      expect(await command(windows()), [npm]);
      final script = p.join(
        toolsDir,
        'node_modules',
        'npm',
        'bin',
        'npm-cli.js',
      );
      await File(script).create(recursive: true);
      expect(await command(windows()), [node, script]);
      // The machine's own: npm's script is run with node there too.
      expect(
        await command(provider()),
        machine.isWindows ? [node, script] : [npm],
      );
    });

    test('which skips the extensionless script beside npm.cmd', () async {
      await tool('npm');
      await tool('npm.cmd');
      final mason = windows();
      expect(
        await mason.which('npm', {...environment, 'PATHEXT': '.exe;.cmd'}),
        p.join(toolsDir, 'npm.cmd'),
      );
      expect(
        await mason.which('npm.cmd', environment),
        p.join(toolsDir, 'npm.cmd'),
      );
    });
  });

  group('locate', () {
    test('PATH first, then installed servers', () async {
      final mason = provider();
      await mason.install('fake-zip');
      await tool('fake-ls');
      expect(
        (await mason.locate(
          server('fake-ls', 'fake-zip'),
        ) as LspServerFound).executable,
        toolPath('fake-ls'),
      );
    });

    test('absolute commands must exist and be executable', () async {
      final mason = provider();
      await tool('abs-ls');
      final path = toolPath('abs-ls');
      expect(
        (await mason.locate(server(path)) as LspServerFound).executable,
        path,
      );
      await File(p.join(toolsDir, 'plain')).writeAsString('');
      // A file with no executable bit is nothing to run, where the machine
      // has such a bit; Windows has none, and starts what it can.
      if (!Platform.isWindows) {
        expect(
          await mason.locate(server(p.join(toolsDir, 'plain'))),
          isA<LspServerMissing>().having((m) => m.package, 'package', isNull),
        );
      }
    });

    test('a command with a folder in it is looked for on the PATH', () async {
      final mason = provider();
      // A folder of the PATH's own, with a command in it: as `cmd.exe`
      // finds it, and not only where the app stands.
      final folder = Directory(p.join(toolsDir, 'bin'))..createSync();
      final path = p.join(folder.path, 'nested-ls');
      await File(path).writeAsBytes(
        Platform.isWindows ? _windowsProgram() : '#!/bin/sh\n'.codeUnits,
      );
      if (Platform.isWindows) {
        await File('$path.cmd').writeAsString('@echo off\r\n');
      }
      final expected = Platform.isWindows ? '$path.cmd' : path;
      expect(
        (await mason.locate(server('bin/nested-ls')) as LspServerFound)
            .executable,
        expected,
      );
    });

    test(
      'suggests a package by command; none when it cannot install',
      () async {
        final mason = provider();
        expect(
          (await mason.locate(
            server('fake-npm-ls'),
          ) as LspServerMissing).package,
          'fake-npm',
        );
        final opam = await mason.locate(server('fake-opam-ls', 'fake-opam'));
        expect((opam as LspServerMissing).package, isNull);
        expect(
          (await mason.locate(
            server('unknown-ls'),
          ) as LspServerMissing).package,
          isNull,
        );
      },
    );

    test('uninstall removes the package', () async {
      final mason = provider();
      await mason.install('fake-gz');
      await mason.uninstall('fake-gz');
      expect(await mason.installed('fake-gz'), isNull);
      expect(
        await mason.locate(server('fake-gz-ls', 'fake-gz')),
        isA<LspServerMissing>(),
      );
    });
  });
}
