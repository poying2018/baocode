import 'dart:convert';
import 'dart:io';

import 'package:baocode/browser/extension_store.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

void main() {
  late Directory cache;
  late HttpServer site;
  late Object? answer;

  setUp(() async {
    // flutter test answers every request 400; the site here is real.
    HttpOverrides.global = null;
    cache = await Directory.systemTemp.createTemp('extension_store');
    answer = null;
    site = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    site.listen((request) {
      final response = request.response;
      if (answer == null) {
        response.statusCode = HttpStatus.notFound;
      } else {
        response.write(jsonEncode(answer));
      }
      response.close();
    });
    ExtensionStore.reset();
  });

  tearDown(() async {
    ExtensionStore.reset();
    await site.close(force: true);
    await cache.delete(recursive: true);
  });

  Future<Uri> fetch() {
    ExtensionStore.reset();
    return ExtensionStore.fetch(
      from: Uri.http('127.0.0.1:${site.port}', '/latest.json'),
      cacheDir: cache.path,
    );
  }

  test("the store's page is the site's, kept for when it does not answer, "
      'and by the id before it ever did', () async {
    expect(await fetch(), ExtensionStore.fallback);
    expect(
      '${ExtensionStore.fallback}',
      'https://chromewebstore.google.com/detail/'
          'jfjagocghaaheooicmdnhcholmgdkngk',
    );

    const listed =
        'https://chromewebstore.google.com/detail/baocode/'
        'jfjagocghaaheooicmdnhcholmgdkngk';
    answer = {'version': '0.1.0', 'store': listed};
    expect('${await fetch()}', listed);
    expect('${ExtensionStore.page}', listed);

    // The site down: the page kept.
    answer = null;
    expect('${await fetch()}', listed);

    // Not the store's: not taken.
    answer = {'store': 'https://example.com/extension'};
    expect('${await fetch()}', listed);
    answer = {'store': null};
    expect('${await fetch()}', listed);
  });

  test('the zip to load unpacked is the manifest\'s, kept with the page',
      () async {
    const zip =
        'https://dl.baocode.dev/releases/extension/0.1.0/'
        'BaoCode-browser-0.1.0.zip?sha256=a2fb423de253d496';
    // Nothing named yet: the click has no address to give, and says so.
    expect(ExtensionStore.zip, isNull);

    answer = {
      'version': '0.1.0',
      'store': null,
      'downloads': {
        'browser-extension': {'url': zip, 'size': 14196, 'sha256': 'a2fb…'},
      },
    };
    // The manifest names the zip and not the page: each stands on its own,
    // and the page is still the one the id makes.
    expect(await fetch(), ExtensionStore.fallback);
    expect('${ExtensionStore.zip}', zip);

    // The site down: still named, from what was kept.
    answer = null;
    await fetch();
    expect('${ExtensionStore.zip}', zip);

    // Not the site's to name: not taken.
    answer = {
      'downloads': {
        'browser-extension': {'url': 'https://example.com/x.zip'},
      },
    };
    await fetch();
    expect('${ExtensionStore.zip}', zip);
  });

  test('what a run kept before the zip was read is still the page', () async {
    const listed =
        'https://chromewebstore.google.com/detail/baocode/'
        'jfjagocghaaheooicmdnhcholmgdkngk';
    final kept = File(p.join(cache.path, 'browser', 'store'));
    await kept.parent.create(recursive: true);
    await kept.writeAsString(listed);

    // The site answers nothing: the page kept in the old shape is read, and
    // there is no zip — which is where the old runs stood.
    expect('${await fetch()}', listed);
    expect(ExtensionStore.zip, isNull);
  });

  test('the manifest read is the one the extension\'s workflow writes', () {
    // The extension is published apart from the app: its own workflow, its
    // own bucket (docs/extensions.md, release.md 11). The app reads that
    // manifest — the app's releases are not where the extension lives, and
    // an address there is a 404 nobody sees until a click.
    expect(
      '${ExtensionStore.manifest}',
      'https://dl.baocode.dev/releases/extension/latest.json',
    );
    final workflow = File('.github/workflows/extension.yml').readAsStringSync();
    expect(workflow, contains('releases/extension/latest.json'));
    expect(workflow, contains('s3://\$R2_BUCKET/releases/extension/\$VERSION/'));
    expect(
      workflow,
      contains('url="https://${ExtensionStore.manifest.host}/releases/extension/'),
    );
  });
}
