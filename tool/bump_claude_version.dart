// Keeps the Claude Code the Windows bundle carries current: the version and
// the SHA-256 of the build it is, pinned in tool/build_windows.dart so that
// a build carries that one build and no other.
//
// The bundle carries Claude Code itself, so that a machine with none of its
// own needs no install and no download. That copy cannot update itself (it
// would put another in the user's ~/.local), so the pin is what a release
// carries: this is what keeps the pin at the current build.
//
//   dart tool/bump_claude_version.dart            say what stands, and whether
//                                                it is behind the release
//                                                channel (exit 1 when it is)
//   dart tool/bump_claude_version.dart --write    put the current build in
//
// The channel is Anthropic's own (downloads.claude.ai/claude-code-releases),
// and the checksum comes from the release's manifest: the binary itself is
// not downloaded to be checked here — the build does that, against the pin.
//
// BAOCODE_CLAUDE_RELEASES says another place to read the releases from, for
// a test.
import 'dart:convert';
import 'dart:io';

/// Where the releases are.
const _defaultBase = 'https://downloads.claude.ai/claude-code-releases';

/// The environment variable that says another place to read them from.
const _baseVariable = 'BAOCODE_CLAUDE_RELEASES';

/// The build the Windows bundle carries.
const _platform = 'win32-x64';

/// The file the pin is in.
const _pinFile = 'tool/build_windows.dart';

/// The name of the pinned version's constant.
const _versionConstant = '_claudeVersion';

/// The name of the pinned checksum's constant.
const _sha256Constant = '_claudeSha256';

Future<void> main(List<String> arguments) async {
  final write = arguments.contains('--write');
  final root = File.fromUri(Platform.script).parent.parent.absolute.path;
  final file = File('$root/$_pinFile');
  if (!file.existsSync()) {
    stderr.writeln('No $_pinFile in $root: run it from the repository.');
    exit(2);
  }
  final text = file.readAsStringSync();
  final pinned = pinnedFrom(text);
  if (pinned == null) {
    stderr.writeln('No $_versionConstant in $_pinFile: the pin is not there.');
    exit(2);
  }
  stdout.writeln('Claude Code carried: ${pinned.version}');

  final latest = await _current();
  if (latest == null) {
    // The channel could not be read: not a reason to fail, only to say so.
    // The pin stands, and a release carries it as it is.
    stderr.writeln('The release channel could not be read: not checked.');
    exit(0);
  }
  stdout.writeln('Claude Code current: $latest');
  if (latest == pinned.version) {
    stdout.writeln('It is the current one.');
    exit(0);
  }
  if (compareVersions(latest, pinned.version) < 0) {
    // The pin is ahead of the channel (a build of their own): not behind it.
    stdout.writeln('The pin is ahead of the channel: not behind it.');
    exit(0);
  }

  final checksum = await _checksum(latest);
  if (checksum == null) {
    stderr.writeln('No $_platform build in the manifest of $latest.');
    exit(2);
  }
  stdout.writeln('It is out: $latest.');
  stdout.writeln("  const $_versionConstant = '$latest';");
  stdout.writeln("  const $_sha256Constant =");
  stdout.writeln("    '$checksum';");
  if (!write) {
    stderr.writeln('Not written: run it with --write.');
    exit(1);
  }
  file.writeAsStringSync(writtenWithPin(text, latest, checksum));
  stdout.writeln('Written to $_pinFile.');
}

/// The version the pin holds, and the checksum beside it; null when the
/// text has no version in it.
({String version, String? sha256})? pinnedFrom(String text) {
  final version = RegExp(
    "const $_versionConstant = '([^']*)';",
  ).firstMatch(text)?.group(1);
  if (version == null) return null;
  final sha256 = RegExp(
    "const $_sha256Constant =\\s*'([^']*)';",
  ).firstMatch(text)?.group(1);
  return (version: version, sha256: sha256);
}

/// [text] with the pin at [version] and [checksum]. The checksum is written
/// the way `dart format` writes it: on its own line, as the line it is on
/// is too long for one.
String writtenWithPin(String text, String version, String checksum) => text
    .replaceAll(
      RegExp("const $_versionConstant = '[^']*';"),
      "const $_versionConstant = '$version';",
    )
    .replaceAll(
      RegExp("const $_sha256Constant =\\s*'[^']*';"),
      "const $_sha256Constant =\n    '$checksum';",
    );

/// The version the release channel is at; null when it could not be read.
Future<String?> _current() async {
  final text = await _get('$_base/stable');
  final version = text?.trim();
  if (version == null || version.isEmpty) return null;
  if (!RegExp(r'^\d+\.\d+\.\d+[A-Za-z0-9.+-]*$').hasMatch(version)) return null;
  return version;
}

/// The checksum of the [version]'s build for [_platform], as the release's
/// manifest says it; null when there is none.
Future<String?> _checksum(String version) async {
  final text = await _get('$_base/$version/manifest.json');
  if (text == null) return null;
  try {
    final json = jsonDecode(text);
    if (json is! Map) return null;
    final platforms = json['platforms'];
    if (platforms is! Map) return null;
    final entry = platforms[_platform];
    if (entry is! Map) return null;
    final checksum = entry['checksum'];
    if (checksum is! String) return null;
    if (!RegExp(r'^[a-f0-9]{64}$').hasMatch(checksum)) return null;
    return checksum;
  } on FormatException {
    return null;
  }
}

/// Where the releases are.
String get _base =>
    Platform.environment[_baseVariable]?.trim().isNotEmpty == true
    ? Platform.environment[_baseVariable]!.trim()
    : _defaultBase;

/// The text at [url]; null when it could not be read.
Future<String?> _get(String url) async {
  final client = HttpClient();
  try {
    final request = await client.getUrl(Uri.parse(url)).timeout(
      const Duration(seconds: 30),
    );
    final response = await request.close().timeout(const Duration(seconds: 30));
    if (response.statusCode != HttpStatus.ok) {
      await response.drain<void>();
      return null;
    }
    // Awaited here, not returned: a future returned from a try is awaited
    // outside it, and what it throws would not be caught here.
    return await response.transform(utf8.decoder).join();
  } on Object {
    return null;
  } finally {
    client.close(force: true);
  }
}

/// Two versions, compared number by number: the newer of the two is the
/// greater one.
int compareVersions(String a, String b) {
  final pa = _parts(a);
  final pb = _parts(b);
  for (var i = 0; i < 3; i++) {
    final c = pa[i].compareTo(pb[i]);
    if (c != 0) return c;
  }
  return 0;
}

/// The three numbers of a version; what it does not say is zero.
List<int> _parts(String version) {
  final match = RegExp(r'^(\d+)\.(\d+)\.(\d+)').firstMatch(version);
  return [
    for (var i = 1; i <= 3; i++) int.tryParse(match?.group(i) ?? '') ?? 0,
  ];
}
