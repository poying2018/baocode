@TestOn('mac-os || linux || windows')
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:baocode/platform/data_dir.dart';
import 'package:path/path.dart' as p;

/// A copy of the app with an id of its own (BAOCODE_APP_ID) keeps its data
/// apart from the installed one: a development build does not write into
/// the folder the user's own app has, nor follow the pointer that says
/// where that folder went.
void main() {
  const withId = {'BAOCODE_APP_ID': 'dev'};
  const without = <String, String>{};

  test('the data folder of a copy with an id is its own', () {
    expect(
      p.basename(DataDirectory.defaultPath(withId)),
      'baocode-dev',
    );
    expect(p.basename(DataDirectory.defaultPath(without)), 'baocode');
  });

  test('the pointer of a copy with an id is its own', () {
    expect(
      DataDirectoryPointer.fileIn('/home', withId),
      p.join('/home', '.baocode-dev', 'config-dir.json'),
    );
    expect(
      DataDirectoryPointer.fileIn('/home', without),
      p.join('/home', '.baocode', 'config-dir.json'),
    );
  });

  test('a copy with an id does not follow the installed one\'s pointer', () {
    final resolution = resolveDataDirectory(
      environment: {
        ...withId,
        'APPDATA': p.join('/appdata'),
        'USERPROFILE': '/home',
        'HOME': '/home',
      },
      home: '/home',
    );
    // The pointer the installed one wrote is not this copy's: it goes to
    // its own folder, the one the platform has for it.
    expect(resolution.source, DataDirectorySource.defaultLocation);
    expect(resolution.path, p.join('/appdata', 'baocode-dev'));
  });
}
