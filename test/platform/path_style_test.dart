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

  test('a path of this machine is read the machine\'s way', () {
    expect(PathStyle.of(r'C:\p\a.dart').style, p.windows.style);
    expect(PathStyle.join(r'C:\p', 'lib/a.dart'), r'C:\p\lib\a.dart');
  });
}
