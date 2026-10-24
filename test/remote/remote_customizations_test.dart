@TestOn('mac-os || linux || windows')
library;

import 'dart:convert';
import 'dart:io';

import 'package:bao_remote/files.dart' show IdeFileExistsException;
import 'package:baocode/customize/customization_store.dart';
import 'package:baocode/customize/customizations.dart';
import 'package:baocode/remote/remote_customization_disk.dart';
import 'package:baocode/remote/ssh_host.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import 'remote_harness.dart';

/// Customize on a remote host: the customizations its agents read, its
/// own `~/.claude` and its projects', through its server.
void main() {
  late Directory dataDir;
  late Directory temp;
  late String home;
  late String config;
  late String project;
  late SshHost host;
  late CustomizationStore store;

  void write(String path, String text) {
    File(path)
      ..parent.createSync(recursive: true)
      ..writeAsStringSync(text);
  }

  setUp(() {
    dataDir = Directory.systemTemp.createTempSync('baocode-remote-data-');
    temp = Directory.systemTemp.createTempSync('baocode-remote-custom-');
    // The host's paths are the host's own: a POSIX one, the host the
    // server runs on is (the server there is run with `sh`).
    final root = temp.resolveSymbolicLinksSync().replaceAll(r'\', '/');
    home = p.posix.join(root, 'home');
    config = p.posix.join(home, '.claude');
    project = p.posix.join(root, 'project');
    Directory(project).createSync(recursive: true);
    host = SshHost('dev', connect: MemoryConnector(dataDir.path).call);
    store = CustomizationStore(
      configDir: config,
      homeDir: home,
      disk: RemoteCustomizationDisk(host),
    );
  });
  tearDown(() async {
    host.close();
    temp.deleteSync(recursive: true);
    dataDir.deleteSync(recursive: true);
  });

  test("the host's skills, the user's, synced and its project's", () async {
    write(
      p.posix.join(config, 'skills', 'pdf', 'SKILL.md'),
      '---\nname: pdf\ndescription: Reads PDF files\n---\n',
    );
    write(p.posix.join(config, 'skills', 'synced', 'a', 'web', 'SKILL.md'), 'Web');
    write(p.posix.join(project, '.claude', 'skills', 'ship', 'SKILL.md'), 'Ships');
    // A skill linked in from elsewhere, as installers do. Windows needs a
    // privilege to make a link; without it, the link is left out.
    write(p.posix.join(home, 'shared', 'lint', 'SKILL.md'), 'Lints');
    var linked = true;
    try {
      Link(
        p.posix.join(config, 'skills', 'lint'),
      ).createSync(p.posix.join(home, 'shared', 'lint'));
    } on FileSystemException {
      linked = false;
    }

    final skills = await store.list(
      CustomizationKind.skills,
      project: project,
    );
    expect([for (final skill in skills) (skill.scope, skill.name)], [
      if (linked) (CustomizationScope.user, 'lint'),
      (CustomizationScope.user, 'pdf'),
      (CustomizationScope.synced, 'web'),
      (CustomizationScope.project, 'ship'),
    ]);
    expect(
      skills.firstWhere((skill) => skill.name == 'pdf').description,
      'Reads PDF files',
    );
  });

  test('made there, folders and all; edited and deleted there', () async {
    final path = await store.create(
      CustomizationKind.subagents,
      CustomizationScope.project,
      'reviewer',
      project: project,
    );
    expect(path, p.posix.join(project, '.claude', 'agents', 'reviewer.md'));
    expect(File(path).existsSync(), isTrue);
    await expectLater(
      store.create(
        CustomizationKind.subagents,
        CustomizationScope.project,
        'reviewer',
        project: project,
      ),
      throwsA(isA<IdeFileExistsException>()),
    );

    await store.write(path, 'Reviews');
    expect(File(path).readAsStringSync(), 'Reviews');
    expect(await store.read(path), 'Reviews');
    expect(await store.exists(path), isTrue);

    final [agent] = await store.list(
      CustomizationKind.subagents,
      project: project,
    );
    await store.delete(agent);
    expect(File(path).existsSync(), isFalse);
  });

  test('its MCP servers, from its ~/.claude.json and the project', () async {
    write(
      p.posix.join(home, '.claude.json'),
      jsonEncode({
        'mcpServers': {
          'docs': {'command': 'docs-server'},
        },
        'projects': {
          project: {
            'mcpServers': {
              'db': {'url': 'http://localhost:5432'},
            },
          },
        },
      }),
    );
    final servers = await store.list(
      CustomizationKind.mcps,
      project: project,
    );
    expect([for (final server in servers) (server.scope, server.name)], [
      (CustomizationScope.user, 'docs'),
      (CustomizationScope.local, 'db'),
    ]);
    expect(store.isLocal, isFalse);
  });
}
