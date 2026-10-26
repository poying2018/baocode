// Takes a remote server build already published (by
// tool/build_remote_server.dart, in a release of this repository tagged
// with the build's VERSION) instead of building one: its VERSION and
// servers.json, all the installers carry. An app packaged with them
// downloads the builds published, not ones only this machine has. Run from
// anywhere in the repository:
//
//   dart run tool/fetch_remote_server.dart                the newest
//   dart run tool/fetch_remote_server.dart <VERSION>      that one
//   dart run tool/fetch_remote_server.dart ... --out <dir>
//                                     into <dir> (build/remote-release/)
//
// The newest is found through GitHub's API, which wants a token for more
// than a few requests an hour: export GH_TOKEN=$(gh auth token) when that
// fails.
//
// tool/build_windows.dart runs it with --remote-release [VERSION].
import 'dart:convert';
import 'dart:io';

/// The repository the builds are published in.
const _repository = 'poying2018/baocode';

/// Where they are downloaded from: a release tagged with the build's
/// VERSION, its assets the gzipped builds and `servers.json`
/// (`<base>/<VERSION>/<file>`).
const _downloadsBase =
    'https://github.com/$_repository/releases/download';

/// Its releases, newest first: what names the newest published build.
const _releases = 'https://api.github.com/repos/$_repository/releases';

/// A published build's VERSION, as tool/build_remote_server.dart writes it:
/// the app's version with its dots, a dash, and a hash of what it carries
/// (`1.3.0.16-4f0b6b0a1c2d`). App releases are tagged `v…`, test ones
/// `test-…`, so a tag of this shape is a remote server's.
final _versionTag = RegExp(r'^\d+\.\d+\.\d+\.\d+-[0-9a-f]{12}$');

Future<void> main(List<String> arguments) async {
  final root = File.fromUri(Platform.script).parent.parent.absolute;
  final at = arguments.indexOf('--out');
  final out = Directory(
    at >= 0 && at + 1 < arguments.length
        ? arguments[at + 1]
        : '${root.path}/build/remote-release',
  );
  final named = [
    for (final (i, argument) in arguments.indexed)
      if (!argument.startsWith('--') && (i == 0 || arguments[i - 1] != '--out'))
        argument,
  ];
  final client = HttpClient()..connectionTimeout = const Duration(seconds: 30);
  try {
    var version = named.firstOrNull ?? 'latest';
    if (version == 'latest') {
      _step('Finding the newest remote server');
      version = await _newest(client);
      stdout.writeln('  $version');
    }
    if (version.contains(RegExp(r'[^A-Za-z0-9._+-]'))) {
      _fail('$version is not a remote server version.');
    }

    _step('Taking servers.json of $version');
    final servers =
        await _getJson(
              client,
              Uri.parse('$_downloadsBase/$version/servers.json'),
            )
            as Map<String, Object?>;
    if (servers['version'] != version) {
      _fail('$_downloadsBase/$version/servers.json is for ${servers['version']}.');
    }
    final files = servers['files'] as Map<String, Object?>;
    for (final MapEntry(key: platform, :value) in files.entries) {
      final file = value as Map<String, Object?>;
      final url = Uri.parse('${file['url']}');
      final request = await client.headUrl(url);
      final response = await request.close();
      await response.drain<void>();
      if (response.statusCode != HttpStatus.ok ||
          response.contentLength != file['size']) {
        _fail(
          '$url is not served as servers.json says '
          '(HTTP ${response.statusCode}, ${response.contentLength} bytes, '
          'not ${file['size']}).',
        );
      }
      stdout.writeln('  $platform: $url');
    }

    // Nothing else there: a build left in it would be taken as this one.
    if (out.existsSync()) out.deleteSync(recursive: true);
    out.createSync(recursive: true);
    File('${out.path}/VERSION').writeAsStringSync('$version\n');
    File('${out.path}/servers.json').writeAsStringSync(
      '${const JsonEncoder.withIndent('  ').convert(servers)}\n',
    );
    _step('Done: ${out.path} ($version)');
  } finally {
    client.close(force: true);
  }
}

Future<Object?> _getJson(
  HttpClient client,
  Uri url, {
  String? token,
}) async {
  final request = await client.getUrl(url);
  if (token != null) request.headers.set('authorization', 'Bearer $token');
  final response = await request.close();
  final text = await response.transform(utf8.decoder).join();
  if (response.statusCode != HttpStatus.ok) {
    _fail(
      '$url: HTTP ${response.statusCode}'
      '${response.statusCode == HttpStatus.notFound ? ' (not published)' : ''}.',
    );
  }
  try {
    return jsonDecode(text);
  } on Object {
    _fail('$url is not what was published (not JSON).');
  }
}

/// The newest published build's VERSION: the first release tagged with one.
///
/// The releases are read through the API, which without a token allows only
/// a few requests an hour from one address; `GH_TOKEN` (or `GITHUB_TOKEN`,
/// as `gh auth token` prints) raises that. Naming a VERSION needs no token:
/// the assets themselves are public.
Future<String> _newest(HttpClient client) async {
  final token =
      Platform.environment['GH_TOKEN'] ?? Platform.environment['GITHUB_TOKEN'];
  final releases = await _getJson(
    client,
    Uri.parse('$_releases?per_page=100'),
    token: token,
  );
  if (releases is! List) _fail('$_releases is not what was published.');
  for (final release in releases) {
    final tag = '${(release as Map)['tag_name']}';
    if (_versionTag.hasMatch(tag)) return tag;
  }
  _fail(
    'No remote server is published in $_repository'
    '${token == null ? ' (the API may have refused: set GH_TOKEN from `gh auth token`)' : ''}.',
  );
}

void _step(String message) => stdout.writeln('\n==> $message');

Never _fail(String message) {
  stderr.writeln('\n$message');
  exit(1);
}
