// docs/release.md's table is how a maintainer tells the two products apart:
// the installer's name, the update manifest, the remote server's. Each of
// them is written there, and again in code (the product table, the server
// binaries) or in this repository's workflow. A rename that reaches one of
// them is not an error anywhere — the release guide just tells the wrong
// story, and the next release follows it.
import 'dart:convert';
import 'dart:io';

import 'package:baocode/platform/app_paths.dart';
import 'package:baocode/remote/remote_binaries.dart';
import 'package:flutter_test/flutter_test.dart';

/// The cells of the row of docs/release.md's table whose first is [first],
/// backticks off: null for no such row.
List<String>? _row(String markdown, String first) {
  for (final line in const LineSplitter().convert(markdown)) {
    if (!line.startsWith('|')) continue;
    final cells = [
      for (final cell
          in line.split('|').skip(1).take(line.split('|').length - 2))
        cell.replaceAll('`', '').trim(),
    ];
    if (cells.isNotEmpty && cells.first == first) return cells;
  }
  return null;
}

void main() {
  final doc = File('docs/release.md').readAsStringSync();
  final workflow = File('.github/workflows/release.yml').readAsStringSync();

  test("the installers' names are the guide's", () {
    final row = _row(doc, '安装包');
    expect(row, isNotNull, reason: 'the table in docs/release.md');
    expect(row![1], '${Product.baocode.installerName}-<版本>-setup.exe');
    expect(row[2], '${Product.codex.installerName}-<版本>-setup.exe');
  });

  test("the update manifests' names are the guide's", () {
    final row = _row(doc, '更新清单');
    expect(row, isNotNull);
    expect(row![1], Product.baocode.manifestName);
    expect(row[2], Product.codex.manifestName);
  });

  test("the remote servers' names are the guide's", () {
    final row = _row(doc, '远端服务端');
    expect(row, isNotNull);
    expect(row![1], '${DirectoryServerBinaries.serverPrefix('baocode')}-*');
    expect(
      row[2],
      '${DirectoryServerBinaries.serverPrefix('baocode-codex')}-*',
    );
  });

  test('the guide names the executables the table does', () {
    for (final product in Product.all) {
      expect(doc, contains('`${product.binary}.exe`'), reason: product.id);
    }
  });

  test('the workflow builds and publishes the product the guide says', () {
    // "CI 只构建、发布本仓库的那一个（矩阵写死 product: [baocode-claude]，
    // publish 里是 PRODUCT: baocode-claude）".
    expect(workflow, contains('product: [${Product.baocode.binary}]'));
    expect(workflow, contains('PRODUCT: ${Product.baocode.binary}'));
  });
}
