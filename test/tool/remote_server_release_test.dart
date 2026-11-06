import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import '../../tool/fetch_remote_server.dart'
    show compareVersions, newestPublishedVersion, versionNumbers;

/// Where the remote server's builds are published.
///
/// `servers.json` names a release tagged with the build's VERSION, and an app
/// built months ago downloads the server it was built with from it
/// (docs/ssh-remote.md, 9.3). The workflows uploaded the builds to the app's
/// release instead, so every version from 1.6.0 on carried URLs for a release
/// that was never made, and every download of a server was a 404. These tests
/// keep the workflows saying what tool/build_remote_server.dart prints.
void main() {
  List<String> linesOf(String name) =>
      File('.github/workflows/$name')
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

    test('the Windows release waits for no macOS runner', () {
      // The app is Windows-only, and macOS runners are scarce enough to
      // leave a release queued indefinitely. The Linux server builds are
      // cross-compiled on Ubuntu; the standalone server-* workflow remains
      // the place that builds macOS servers on a Mac.
      expect(
        lines,
        isNot(contains('uses: ./.github/workflows/remote.yml')),
      );
      expect(
        lines.where((line) => line.startsWith('runs-on: macos-')),
        isEmpty,
      );
      expect(lines, contains('runs-on: windows-latest'));
      expect(
        lines,
        contains(
          'run: dart run tool/build_remote_server.dart --out build/remote '
          '--product "$PRODUCT"',
        ),
      );
    });

    test('the server\'s builds go to the release servers.json names', () {
      final upload = serverUpload(lines);
      // The VERSION the files were built at: read back from the file the
      // build wrote, so the tag is the one servers.json's URLs name.
      expect(lines, contains(r'version=$(cat dist/remote-$PRODUCT/VERSION)'));
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
          (line) =>
              line.contains('Check the builds are where servers.json says'),
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
            line.startsWith('gh release edit') &&
            line.contains('--latest=true'),
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

  group('tool/fetch_remote_server.dart', () {
    test('the newest build is the one with the newest version', () {
      // The API lists the releases by their tags, so the order says nothing
      // about the numbers in a VERSION: the servers of 1.6.0 and 1.5.x were
      // published a week after 1.9.5's, and the first one listed is 1.9.5's
      // only because its tag is the newest.
      final listed = [
        '1.9.5.31-3bb062c7fa29',
        '1.9.3.29-8d868c2d8d86',
        '1.5.1.16-0180fa898f62',
        '1.9.0.26-032817dec99a',
        '1.6.2.20-2dcee4c965b5',
      ];
      expect(newestPublishedVersion(listed), '1.9.5.31-3bb062c7fa29');
      expect(newestPublishedVersion(listed.reversed), '1.9.5.31-3bb062c7fa29');
      // A backfill of an old build, made today, still names the old build.
      expect(
        newestPublishedVersion(['1.5.1.16-0180fa898f62', ...listed]),
        '1.9.5.31-3bb062c7fa29',
      );
    });

    test('only a remote server VERSION is chosen', () {
      // The app's own releases are tagged v…, the test ones test-…: neither
      // is a build to package an installer around.
      expect(newestPublishedVersion(['v1.9.5', 'test-1.9.5-abc']), isNull);
      expect(
        newestPublishedVersion(['v1.9.5', '1.9.5.31-3bb062c7fa29']),
        '1.9.5.31-3bb062c7fa29',
      );
      expect(newestPublishedVersion(const []), isNull);
    });

    test('the numbers of a version, compared in order', () {
      expect(versionNumbers('1.9.5.31-3bb062c7fa29'), [1, 9, 5, 31]);
      // Each number counts on its own: 31 builds past 1.9.5 is newer than
      // 1.9.5, and 1.10.0 is newer than 1.9.5 although '10' sorts first as
      // text.
      expect(
        compareVersions('1.9.5.31-aaaaaaaaaaaa', '1.9.5.30-bbbbbbbbbbbb'),
        greaterThan(0),
      );
      expect(
        compareVersions('1.10.0.32-aaaaaaaaaaaa', '1.9.5.31-bbbbbbbbbbbb'),
        greaterThan(0),
      );
      expect(
        compareVersions('1.9.5.31-aaaaaaaaaaaa', '1.9.5.31-bbbbbbbbbbbb'),
        0,
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
