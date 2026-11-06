// Two channels, and one of them is not the app's. This fork publishes the app
// in its own GitHub Releases, and the browser extension (with the phone app)
// through Cloudflare R2 at dl.baocode.dev (docs/extensions.md). The guides said
// so, but auto-update.md once said the fork used neither — a fork reading it
// would move the app's manifest to a channel it does not own. The words and
// the code are held together here.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  final autoUpdate = File('docs/auto-update.md').readAsStringSync();
  final extensions = File('docs/extensions.md').readAsStringSync();
  final workflow = File('.github/workflows/extension.yml').readAsStringSync();
  final manifest = File('lib/update/update_manifest.dart').readAsStringSync();

  test("the app's updates are not on the extension's channel", () {
    // The app's manifest comes from this repository's releases.
    expect(manifest, contains('github.com/poying2018/baocode/releases'));
    expect(
      manifest,
      isNot(contains('dl.baocode.dev')),
      reason: "the app's updates are not the extension's to serve",
    );
    // The extension's still does: its workflow uploads there.
    expect(workflow, contains('dl.baocode.dev'));
    expect(extensions, contains('dl.baocode.dev'));
  });

  test("the guides say which channel is whose", () {
    // Where the app updates from, said in so many words.
    expect(autoUpdate, contains('releases/latest/download/latest.json'));
    // And that the other channel is not the app's, pointing at the one that
    // says whose it is.
    expect(autoUpdate, contains('extensions.md'));
    expect(
      autoUpdate,
      contains('dl.baocode.dev'),
      reason: 'the extension and phone channel is named, and scoped',
    );
  });
}
