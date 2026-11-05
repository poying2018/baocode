import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Where the remote server's builds are published.
///
/// `servers.json` names a release tagged with the build's VERSION, and an app
/// built months ago downloads the server it was built with from it
/// (docs/ssh-remote.md, 9.3). The workflows uploaded the builds to the app's
/// release instead, so every version from 1.6.0 on carried URLs for a release
/// that was never made, and every download of a server was a 404. These tests
/// keep the workflows saying what tool/build_remote_server.dart prints.
void main() {
  List<String> linesOf(String name) => File('.github/workflows/$name')
      .readAsStringSync()
      .replaceAll('\r\n', '\n')
      .split('\n')
      .map((line) => line.trim())
      .toList();

  /// The upload of the server's files: the `gh release upload` a
  /// `for file in dist/remote` loop runs.
  String serverUpload(List<String> lines) {
    for (var i = 0; i < lines.length - 1; i++) {
      if (lines[i].startsWith('for file in dist/remote') &&
          lines[i + 1].startsWith('gh release upload')) {
        return lines[i + 1];
      }
    }
    return fail('no upload of dist/remote');
  }

  /// The upload of the record of which build was published.
  String recordUpload(List<String> lines) => lines.firstWhere(
    (line) =>
        line.startsWith('gh release upload') && line.contains('remote-latest'),
    orElse: () => fail(r'the upload of remote-latest-$PRODUCT.json is gone'),
  );

  group('release.yml', () {
    final lines = linesOf('release.yml');

    test('the server\'s builds go to the release servers.json names', () {
      final upload = serverUpload(lines);
      // The VERSION the files were built at: read back from the file the
      // build wrote, so the tag is the one servers.json's URLs name.
      expect(
        lines,
        contains(r'version=$(cat dist/remote-$PRODUCT/VERSION)'),
      );
      expect(upload, contains(r'"$version"'));
    });

    test('the record of the build goes there too', () {
      expect(recordUpload(lines), contains(r'"$version"'));
    });

    test('their release is never the latest', () {
      // The app reads its update manifest from releases/latest: a release of
      // the server's builds must not take that place from the app's release.
      expect(
        RegExp(r'gh release create "\$version"[\s\S]*?--latest=false')
            .hasMatch(lines.join('\n')),
        isTrue,
      );
    });

    test('the addresses are probed before the manifest goes up', () {
      // A release that cannot hand a host its server must not become the one
      // apps update to: the probe sits between the two uploads.
      final builds = lines.indexWhere(
        (line) => line.startsWith(r'gh release upload "$version"'),
      );
      final probe = lines.indexWhere((line) => line.contains('.files[].url'));
      final manifest = lines.indexWhere(
        (line) =>
            line.startsWith('gh release upload') &&
            line.contains('out/latest.json'),
      );
      expect(builds, isNonNegative);
      expect(probe, greaterThan(builds));
      expect(manifest, greaterThan(probe));
      expect(
        lines.any(
          (line) => line.contains('Check the builds are where servers.json says'),
        ),
        isTrue,
      );
    });
    test('the place releases/latest points at stays the app\'s', () {
      // --latest=false on create was not enough on its own: a release made
      // that way took the place from the app's release, and releases/latest
      // then answered with a release that has no manifest in it. It is taken
      // back, and the app's release is marked again after the manifest is up.
      bool edit(String flag) => lines.any(
        (line) => line.startsWith('gh release edit') && line.contains(flag),
      );
      expect(edit('--latest=false'), isTrue);
      expect(edit('--latest=true'), isTrue);
      final manifest = lines.indexWhere(
        (line) =>
            line.startsWith('gh release upload') &&
            line.contains('out/latest.json'),
      );
      final remark = lines.lastIndexWhere(
        (line) =>
            line.startsWith('gh release edit') && line.contains('--latest=true'),
      );
      expect(remark, greaterThan(manifest));
    });
  });

  group('remote.yml', () {
    final lines = linesOf('remote.yml');

    test('the server\'s builds go to the release servers.json names', () {
      expect(serverUpload(lines), contains(r'"$VERSION"'));
    });

    test('the record of the build goes there too', () {
      expect(recordUpload(lines), contains(r'"$VERSION"'));
    });

    test('their release is never the latest', () {
      expect(
        RegExp(r'gh release create "\$VERSION"[\s\S]*?--latest=false')
            .hasMatch(lines.join('\n')),
        isTrue,
      );
    });

    test('the addresses are probed after the upload', () {
      final builds = lines.indexWhere(
        (line) => line.startsWith(r'gh release upload "$VERSION"'),
      );
      final probe = lines.indexWhere((line) => line.contains('.files[].url'));
      expect(builds, isNonNegative);
      expect(probe, greaterThan(builds));
    });

    test('it does not take the place from the app\'s release', () {
      // --latest=false on create was not enough on its own: the release took
      // the place anyway, and releases/latest then answered without a
      // manifest. Publishing a server alone must take it back.
      expect(
        lines.any(
          (line) =>
              line.startsWith('gh release edit') &&
              line.contains('--latest=false'),
        ),
        isTrue,
      );
    });
  });

  group('tool/build_remote_server.dart', () {
    final source = File('tool/build_remote_server.dart').readAsStringSync();

    test('servers.json names a release tagged with the build VERSION', () {
      // The URL's tag and the file's name are the same string: what the app
      // downloads is what this build was made with.
      expect(source, contains(r"'url': '$_downloadsBase/$name/$file',"));
      expect(
        source,
        contains(r"File('${out.path}/VERSION').writeAsStringSync('$name\n');"),
      );
      // A release of this repository, which is the one the workflows publish
      // to.
      expect(source, contains("const _repository = 'poying2018/baocode';"));
    });
  });
}
