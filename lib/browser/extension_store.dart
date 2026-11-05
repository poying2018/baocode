import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

import '../platform/data_dir.dart';
import '../workspace/editor_launcher.dart' show openExternal;
import 'browser_bridge.dart';

/// Where BaoCode's extension is got: its page in the store, and the zip to
/// load unpacked when the store is not the way.
///
/// Both are the extension's own release's to say: `.github/workflows/
/// extension.yml` publishes the extension on its own (`extension-v*` tags),
/// writes the manifest read here, and names the store's page and the zip in
/// it. Not the app's releases — those are the app's, and the extension is
/// published apart from it.
///
/// The manifest is fetched once a run, kept in the cache for when the site
/// does not answer, and before the first answer the page the extension's id
/// makes.
abstract final class ExtensionStore {
  /// The manifest the extension's workflow writes: its version, the store's
  /// page (when it is not the one the id makes), and the zip's address.
  static final manifest = Uri.parse(
    'https://dl.baocode.dev/releases/extension/latest.json',
  );

  /// The extension's page, by its id: the store's address for it.
  static final fallback = Uri.https(
    'chromewebstore.google.com',
    '/detail/${BrowserBridge.extensionIds.first}',
  );

  /// The store's page as last known: fetched, or kept; [fallback] before.
  static Uri get page => _page ?? fallback;
  static Uri? _page;

  /// The zip to load unpacked as last known: fetched, or kept; null before
  /// the first answer — there is then no address to give, see [openZip].
  static Uri? get zip => _zip;
  static Uri? _zip;

  static Future<Uri>? _fetched;

  /// Fetches the manifest, once a run (again after [reset]); [page] is it
  /// once done. Never fails: what was kept, or [fallback].
  static Future<Uri> fetch({
    @visibleForTesting Uri? from,
    @visibleForTesting String? cacheDir,
  }) => _fetched ??= _fetch(from ?? manifest, cacheDir);

  /// [fetch]'s page, waiting for it [patience] at most: a click opens the
  /// page then, the one known so far if the site is slow.
  static Future<Uri> resolve({
    Duration patience = const Duration(seconds: 2),
  }) => fetch().timeout(patience, onTimeout: () => page);

  /// Opens the store's page in the user's browser.
  static Future<void> openPage() async => openExternal('${await resolve()}');

  /// Opens [zip]: the browser downloads it. With no zip named yet — the
  /// manifest does not answer, and none was kept — the store's page itself,
  /// where the extension is installed from instead.
  static Future<void> openZip() async {
    await resolve();
    await openExternal('${_zip ?? page}');
  }

  @visibleForTesting
  static void reset() {
    _page = null;
    _zip = null;
    _fetched = null;
  }

  static Future<Uri> _fetch(Uri from, String? cacheDir) async {
    final kept = File(
      p.join(cacheDir ?? DataDirectory.current.cacheDir, 'browser', 'store'),
    );
    try {
      final known = _known(await kept.readAsString());
      if (known != null) {
        _page = known.$1 ?? _page;
        _zip = known.$2 ?? _zip;
      }
    } on FileSystemException {
      // None kept yet.
    }
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 5);
    try {
      final request = await client.getUrl(from).timeout(_timeout);
      final response = await request.close().timeout(_timeout);
      if (response.statusCode != HttpStatus.ok) {
        await response.drain<void>();
        return page;
      }
      final text = await response
          .transform(utf8.decoder)
          .join()
          .timeout(_timeout);
      final (store, zip) = _listed(text);
      if ((store != null && store != _page) || (zip != null && zip != _zip)) {
        _page = store ?? _page;
        _zip = zip ?? _zip;
        await kept.parent.create(recursive: true);
        await writeFileAtomically(
          kept,
          jsonEncode({
            'store': ?_page?.toString(),
            'zip': ?_zip?.toString(),
          }),
        );
      }
    } on Object catch (error) {
      debugPrint('extension store: $error');
    } finally {
      client.close(force: true);
    }
    return page;
  }

  static const _timeout = Duration(seconds: 8);

  /// [text] as the manifest lists them: the store's page and the zip's
  /// address, each only if it is the one it should be.
  static (Uri?, Uri?) _listed(String text) {
    final Object? json;
    try {
      json = jsonDecode(text);
    } on FormatException {
      return (null, null);
    }
    if (json is! Map<String, Object?>) return (null, null);
    final store = switch (json['store']) {
      final String store => _valid(store),
      _ => null,
    };
    final zip = switch (json['downloads']) {
      {'browser-extension': {'url': final String url}} => _validZip(url),
      _ => null,
    };
    return (store, zip);
  }

  /// [text] as what a run kept: the page and the zip, as written last, or
  /// the page alone from before the zip was read.
  static (Uri?, Uri?)? _known(String text) {
    final trimmed = text.trim();
    if (!trimmed.startsWith('{')) {
      final page = _valid(trimmed);
      return page == null ? null : (page, null);
    }
    final Object? json;
    try {
      json = jsonDecode(trimmed);
    } on FormatException {
      return null;
    }
    if (json is! Map<String, Object?>) return null;
    return (
      switch (json['store']) {
        final String store => _valid(store),
        _ => null,
      },
      switch (json['zip']) {
        final String zip => _validZip(zip),
        _ => null,
      },
    );
  }

  /// [text] as the store's page: https, on the store's own hosts.
  static Uri? _valid(String text) => switch (Uri.tryParse(text.trim())) {
    final url?
        when url.scheme == 'https' &&
            (url.host == 'chromewebstore.google.com' ||
                url.host == 'chrome.google.com') =>
      url,
    _ => null,
  };

  /// [text] as the zip to load unpacked: https, on the site the extension is
  /// published to.
  static Uri? _validZip(String text) => switch (Uri.tryParse(text.trim())) {
    final url? when url.scheme == 'https' && url.host == _published => url,
    _ => null,
  };

  static const _published = 'dl.baocode.dev';
}
