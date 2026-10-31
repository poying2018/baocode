import 'dart:io';

import 'package:baocode/platform/path_style.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

void main() {
  test('a POSIX-rooted path keeps the POSIX spelling', () {
    expect(PathStyle.of('/p/lib/a.dart'), p.posix);
    expect(PathStyle.join('/p', 'lib/a.dart'), '/p/lib/a.dart');
    expect(PathStyle.join('/p', '/p/lib/a.dart'), '/p/lib/a.dart');
    expect(PathStyle.isWithin('/p', '/p/lib/a.dart'), isTrue);
    expect(PathStyle.isWithin('/p', '/q/lib/a.dart'), isFalse);
  });

  test("a path of this machine is read the machine's way", () {
    // Where the machine's own root is a drive's (Windows), a path rooted at
    // `C:\` is spelled the machine's way. Where it is not — POSIX machines,
    // whose root is `/` — a `C:\` path is a relative one, and read the
    // machine's way just the same: POSIX.
    final expected = Platform.isWindows ? p.windows.style : p.posix.style;
    expect(PathStyle.of(r'C:\p\a.dart').style, expected);
    if (Platform.isWindows) {
      expect(PathStyle.join(r'C:\p', 'lib/a.dart'), r'C:\p\lib\a.dart');
    }
  });
}
