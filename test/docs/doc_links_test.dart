import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

/// GitHub's anchor for a heading: lower case; everything that is not a
/// letter, a number, a space, a dash or an underscore dropped; spaces to
/// dashes. The docs are written in Chinese, so a letter is what `\p{L}`
/// covers, not just what A-Z covers.
String anchorOf(String heading) {
  final stripped = heading
      .trim()
      .toLowerCase()
      .replaceAll(RegExp(r'[^\p{L}\p{N}\s\-_]', unicode: true), '');
  return stripped.replaceAll(RegExp(r'\s+'), '-');
}

/// The text with its fenced blocks gone: a heading or a link written as
/// an example inside a fence is neither.
String withoutFences(String markdown) {
  final kept = StringBuffer();
  var fenced = false;
  for (final line in markdown.split('\n')) {
    final left = line.trimLeft();
    if (left.startsWith('```') || left.startsWith('~~~')) {
      fenced = !fenced;
      continue;
    }
    if (fenced) continue;
    kept.writeln(line);
  }
  return kept.toString();
}

/// The text as prose: fenced blocks gone, inline code gone as well. A link
/// shown between backticks is an example, not a link.
String proseOf(String markdown) =>
    withoutFences(markdown).replaceAll(RegExp(r'`[^`\n]*`'), '');

/// The headings of a markdown text, as GitHub anchors them. The backticks
/// of inline code go, the text between them stays: `### 5.2 `latest.json``
/// anchors as `52-latestjson-`, not as `52-`.
Set<String> anchorsOf(String markdown) => {
  for (final line in withoutFences(markdown).split('\n'))
    if (RegExp(r'^#{1,6}\s').hasMatch(line))
      anchorOf(
        line.replaceFirst(RegExp(r'^#+\s*'), '').replaceAll(RegExp('`'), ''),
      ),
};

final _link = RegExp(r'\]\(([^)\s]+)\)');

/// The anchor as a URL spells it, so that `%E6%9C%8D` and `服` are the
/// same one.
String decode(String anchor) {
  try {
    return Uri.decodeFull(anchor);
  } on ArgumentError {
    return anchor;
  }
}

/// Where the markdown that people read lives: the repository's own, plus
/// the release notes and the site. What sits under `packages/` is left out
/// on purpose: the editor's grammars and their fixtures come with their
/// own files and their own links.
const _roots = ['docs', 'release-notes', 'site', '.github', 'lib', 'tool'];

void main() {
  final root = Directory.current.absolute.path;
  final files = <String>[
    for (final file in Directory(root).listSync().whereType<File>())
      if (file.path.endsWith('.md')) file.path,
    for (final name in _roots)
      for (final entity in Directory(p.join(root, name)).listSync(recursive: true))
        if (entity is File && entity.path.endsWith('.md')) entity.path,
  ]..sort();

  final anchors = <String, Set<String>>{
    for (final path in files) path: anchorsOf(File(path).readAsStringSync()),
  };
  final prose = <String, String>{
    for (final path in files) path: proseOf(File(path).readAsStringSync()),
  };

  test('the markdown was found, and the docs have headings to point at', () {
    expect(files, isNotEmpty);
    expect(
      Directory(p.join(root, 'docs'))
          .listSync(recursive: true)
          .whereType<File>()
          .where((file) => file.path.endsWith('.md'))
          .where((file) => anchors[file.path]!.isEmpty)
          .map((file) => p.relative(file.path, from: root)),
      isEmpty,
    );
  });

  test('every link points at something that is there', () {
    final broken = <String>[];
    for (final entry in prose.entries) {
      final from = p.relative(entry.key, from: root);
      for (final match in _link.allMatches(entry.value)) {
        final target = match.group(1)!;
        if (target.startsWith('http://') ||
            target.startsWith('https://') ||
            target.startsWith('mailto:')) {
          continue;
        }
        final hash = target.indexOf('#');
        final path_ = hash < 0 ? target : target.substring(0, hash);
        final anchor = hash < 0 ? '' : decode(target.substring(hash + 1));
        final resolved = path_.isEmpty
            ? entry.key
            : p.normalize(p.join(p.dirname(entry.key), path_));
        if (FileSystemEntity.typeSync(resolved) ==
            FileSystemEntityType.notFound) {
          broken.add('$from -> $target (no such file)');
          continue;
        }
        if (anchor.isEmpty) continue;
        final known = anchors[resolved];
        // A link into a file that is not a doc has nothing to anchor to.
        if (known == null) continue;
        if (!known.contains(anchor.toLowerCase())) {
          broken.add('$from -> $target (no such heading)');
        }
      }
    }
    expect(broken, isEmpty, reason: 'Broken doc links:\n${broken.join('\n')}');
  });
}
