// Signs a release's installers and writes the manifest the app reads to
// update itself (https://dl.baocode.dev/releases/latest.json; see
// docs/auto-update.md). Run from anywhere in the repository:
//
//   dart run tool/release_manifest.dart \
//     --windows build/installers/BaoCode-1.2.0-setup.exe \
//     --macos-arm64 build/installers/BaoCode-1.2.0-mac-arm64.zip \
//     --macos-x64 build/installers/BaoCode-1.2.0-mac-x64.zip \
//     [--dmg-arm64 build/installers/BaoCode-1.2.0-arm64.dmg] \
//     [--dmg-x64 build/installers/BaoCode-1.2.0-x64.dmg] \
//     [--notes-en <text or file>] [--notes-zh <text or file>] \
//     [--minimum-version 1.0.0] [--version 1.2.0+12] \
//     [--manifest build/installers/latest.json]
//
//   dart run tool/release_manifest.dart --generate-key <file>
//   dart run tool/release_manifest.dart --public-key
//
// The private key is a file holding 32 random bytes, base64; its path is
// in BAOCODE_UPDATE_SIGNING_KEY. Never in the repository: whoever has it
// can make every installed BaoCode run their program.
//
// The version is pubspec.yaml's unless given. A manifest already there for
// the same version keeps the other platforms' entries, so the Windows and the
// macOS installers can be signed on their own machines one after the other.
//
// Each link is the release asset of the version's GitHub release:
// https://github.com/poying2018/baocode/releases/download/v<version>/<file>.
// The app names a download by the path alone.
//
// Besides what the app reads, `downloads` gives the download page
// (site/site.js) what it offers: the disk images (--dmg-arm64, --dmg-x64),
// which the app does not update from, and the Windows installer.
import 'dart:convert';
import 'dart:io';

import 'package:baocode/update/update_manifest.dart';
import 'package:baocode/update/update_signature.dart';
import 'package:baocode/update/version.dart';
import 'package:crypto/crypto.dart' as crypto;

/// Where the downloads go: a release asset of this fork's GitHub releases.
const _releasesBase = 'https://github.com/poying2018/baocode/releases/download';

/// [name]'s link: the release of [version] carries it.
Uri _link(AppVersion version, String name) =>
    Uri.parse('$_releasesBase/v$version/$name');

/// The Macs built for, each its own download (tool/build_macos.dart), and
/// the app takes its processor's (lib/update/installer_io.dart).
const _macArchitectures = ['arm64', 'x64'];

/// Where the private key's path is given.
const _keyVariable = 'BAOCODE_UPDATE_SIGNING_KEY';

/// What an encrypted key file starts with: DPAPI (CurrentUser) over the
/// seed, base64.
const _dpapiPrefix = 'dpapi:';

const _usage = '''
Usage:
  dart run tool/release_manifest.dart [--windows <setup.exe>]
      [--macos-arm64 <mac-arm64.zip>] [--macos-x64 <mac-x64.zip>]
      [--dmg-arm64 <arm64.dmg>] [--dmg-x64 <x64.dmg>]
      [--notes-en <text|file>] [--notes-zh <text|file>]
      [--minimum-version <version>] [--version <version>]
      [--manifest <latest.json>]
  dart run tool/release_manifest.dart --generate-key <file>
  dart run tool/release_manifest.dart --encrypt-key <file> --out <file>
  dart run tool/release_manifest.dart --decrypt-key <file> --out <file>
  dart run tool/release_manifest.dart --public-key

The private key's path is read from \$$_keyVariable. An encrypted key
(DPAPI, CurrentUser) works too: signing decrypts it in memory.''';

Future<void> main(List<String> arguments) async {
  final options = _parse(arguments);
  if (options.containsKey('help')) {
    stdout.writeln(_usage);
    return;
  }
  if (options['generate-key'] case final path?) return _generateKey(path);
  if (options['encrypt-key'] case final path?) {
    return _encryptKey(path, options['out']);
  }
  if (options['decrypt-key'] case final path?) {
    return _decryptKey(path, options['out']);
  }
  final seed = _readKey();
  final publicKey = UpdateSignature.publicKeyOf(seed);
  if (options.containsKey('public-key')) {
    stdout.writeln(publicKey);
    return;
  }
  if (publicKey != updatePublicKey) {
    _fail(
      'The key in \$$_keyVariable is not the one the app checks against.\n'
      '  its public key:   $publicKey\n'
      '  the app expects:  $updatePublicKey (lib/update/update_signature.dart)\n'
      'Releases signed with it would be refused by every installed BaoCode.',
    );
  }

  final root = File.fromUri(Platform.script).parent.parent.absolute;
  final version = AppVersion.parse(
    options['version'] ?? _pubspecVersion(File('${root.path}/pubspec.yaml')),
  );
  final files = {
    if (options['windows'] case final path?) 'windows-x64': File(path),
    for (final arch in _macArchitectures)
      if (options['macos-$arch'] case final path?) 'macos-$arch': File(path),
  };
  if (files.isEmpty) {
    _fail(
      'Nothing to sign: give --windows, --macos-arm64 or --macos-x64.\n\n'
      '$_usage',
    );
  }
  final manifestFile = File(
    options['manifest'] ?? '${root.path}/build/installers/latest.json',
  );

  // The other platform's entry, signed before for the same version.
  var previous = <String, UpdateAsset>{};
  var notes = <String, String>{};
  var downloads = <String, Object?>{};
  AppVersion? minimum;
  if (manifestFile.existsSync()) {
    final text = manifestFile.readAsStringSync();
    final old = UpdateManifest.parse(text);
    if (old.version == version) {
      previous = {
        for (final platform in old.platforms) platform: old.assetFor(platform)!,
      };
      notes = {...old.notes};
      minimum = old.minimumVersion;
      if (jsonDecode(text) case {'downloads': final Map<String, Object?> d}) {
        downloads = {...d};
      }
    }
  }
  for (final language in ['en', 'zh']) {
    if (options['notes-$language'] case final value?) {
      notes[language] = _textOrFile(value);
    }
  }
  if (options['minimum-version'] case final value?) {
    minimum = AppVersion.parse(value);
  }

  final assets = {...previous};
  for (final MapEntry(key: platform, value: file) in files.entries) {
    if (!file.existsSync()) _fail('No such file: ${file.path}');
    stdout.writeln('Signing ${file.path} for $platform');
    final size = file.lengthSync();
    final sha256 = '${await crypto.sha256.bind(file.openRead()).first}';
    final payload = UpdateSignature.payload(
      version: '$version',
      platform: platform,
      size: size,
      sha256: sha256,
    );
    final signature = UpdateSignature.sign(payload: payload, seed: seed);
    if (!UpdateSignature.verify(payload: payload, signature: signature)) {
      _fail('The signature does not check out against the app\'s key.');
    }
    final name = file.uri.pathSegments.last;
    assets[platform] = UpdateAsset(
      url: _link(version, name),
      size: size,
      sha256: sha256,
      signature: signature,
    );
  }
  if (assets['windows-x64'] case final installer?) {
    downloads['windows'] = {
      'url': '${installer.url}',
      'size': installer.size,
      'sha256': installer.sha256,
    };
  }
  final dmgs = {
    for (final arch in _macArchitectures)
      if (options['dmg-$arch'] case final path?) 'macos-$arch': File(path),
  };
  for (final MapEntry(key: platform, value: dmg) in dmgs.entries) {
    if (!dmg.existsSync()) _fail('No such file: ${dmg.path}');
    final sha256 = '${await crypto.sha256.bind(dmg.openRead()).first}';
    downloads[platform] = {
      'url': '${_link(version, dmg.uri.pathSegments.last)}',
      'size': dmg.lengthSync(),
      'sha256': sha256,
    };
  }

  final manifest = UpdateManifest(
    version: version,
    pubDate: DateTime.now().toUtc(),
    notes: notes,
    minimumVersion: minimum,
    platforms: assets,
  );
  final json = {
    ...manifest.toJson(),
    if (downloads.isNotEmpty) 'downloads': downloads,
  };
  final text = '${const JsonEncoder.withIndent('  ').convert(json)}\n';
  // What the app will read: it has to read it back the same.
  UpdateManifest.parse(text);
  manifestFile.parent.createSync(recursive: true);
  manifestFile.writeAsStringSync(text);

  stdout
    ..writeln()
    ..writeln('Wrote ${manifestFile.path}')
    ..writeln()
    ..writeln('Upload, the installers first, the manifest last:');
  for (final MapEntry(key: platform, value: file) in files.entries) {
    stdout.writeln('  ${file.path}\n    -> ${assets[platform]!.url}');
  }
  for (final MapEntry(key: platform, value: dmg) in dmgs.entries) {
    stdout.writeln(
      '  ${dmg.path}\n    -> ${(downloads[platform] as Map)['url']}',
    );
  }
  stdout.writeln('  ${manifestFile.path}\n    -> $defaultManifestUrl');
  final missing = {
    'windows-x64',
    for (final arch in _macArchitectures) 'macos-$arch',
  }.difference(assets.keys.toSet());
  if (missing.isNotEmpty) {
    stdout.writeln(
      '\nNo download for ${missing.join(', ')} yet: those users are not '
      'offered $version until it is signed into this manifest too.',
    );
  }
}

/// Writes a new private key to [path] (never over one) and prints its
/// public half, for lib/update/update_signature.dart.
void _generateKey(String path) {
  final file = File(path);
  if (file.existsSync()) _fail('$path exists: not overwritten.');
  file.parent.createSync(recursive: true);
  final seed = UpdateSignature.generateSeed();
  file.writeAsStringSync('$seed\n');
  if (!Platform.isWindows) Process.runSync('chmod', ['600', path]);
  stdout
    ..writeln('Wrote the private key to $path. Keep it safe, and out of the')
    ..writeln('repository; point \$$_keyVariable at it to sign releases.')
    ..writeln()
    ..writeln('Its public key, for updatePublicKey in')
    ..writeln('lib/update/update_signature.dart:')
    ..writeln()
    ..writeln('  ${UpdateSignature.publicKeyOf(seed)}');
}

/// Wraps the plain key at [path] with Windows DPAPI, for the current user
/// and this machine only, and writes it to [out] (required).
void _encryptKey(String path, String? out) {
  if (out == null) _fail('--encrypt-key needs --out <file>.');
  if (!Platform.isWindows) {
    _fail('DPAPI encryption is Windows-only.');
  }
  final seed = _seedOf(File(path).readAsStringSync().trim(), path);
  final file = File(out);
  file.parent.createSync(recursive: true);
  file.writeAsStringSync('$_dpapiPrefix${_dpapi(seed, protect: true)}\n');
  stdout
    ..writeln('Wrote the encrypted key to $out.')
    ..writeln('Point \$$_keyVariable at it to sign releases; it reads only')
    ..writeln('under this Windows account, on this machine.');
}

/// Writes the plain key [path] holds (an encrypted one included) to [out].
void _decryptKey(String path, String? out) {
  if (out == null) _fail('--decrypt-key needs --out <file>.');
  final text = File(path).readAsStringSync().trim();
  final seed = text.startsWith(_dpapiPrefix)
      ? _dpapi(text.substring(_dpapiPrefix.length), protect: false)
      : text;
  final file = File(out);
  file.parent.createSync(recursive: true);
  file.writeAsStringSync('$seed\n');
  stdout.writeln('Wrote the plain key to $out. Keep it safe.');
}

/// [text] as a key seed: 32 bytes, base64. [path] names it in errors.
String _seedOf(String text, String path) {
  try {
    if (base64.decode(text).length == 32) return text;
  } on FormatException {
    // Below.
  }
  _fail('$path does not hold a key (32 bytes, base64).');
}

/// Windows DPAPI (CurrentUser) over [seed], base64; or back.
String _dpapi(String seed, {required bool protect}) {
  final call = protect ? 'Protect' : 'Unprotect';
  final script = [
    'Add-Type -AssemblyName System.Security',
    "\$in = [Convert]::FromBase64String('$seed')",
    "\$out = [Security.Cryptography.ProtectedData]::$call(\$in, \$null, 'CurrentUser')",
    '[Convert]::ToBase64String(\$out)',
  ].join('; ');
  final result = Process.runSync('powershell', [
    '-NoProfile',
    '-NonInteractive',
    '-Command',
    script,
  ]);
  if (result.exitCode != 0) {
    _fail(
      'PowerShell could not ${protect ? 'protect' : 'unprotect'} the key:\n'
      '${result.stderr}',
    );
  }
  return '${result.stdout}'.trim();
}

String _readKey() {
  final path = Platform.environment[_keyVariable];
  if (path == null || path.isEmpty) {
    _fail('\$$_keyVariable is not set: it is the private key file\'s path.');
  }
  final file = File(path);
  if (!file.existsSync()) _fail('No key at $path (\$$_keyVariable).');
  final text = file.readAsStringSync().trim();
  if (!text.startsWith(_dpapiPrefix)) return _seedOf(text, path);
  if (!Platform.isWindows) {
    _fail(
      '$path is DPAPI-encrypted: only the Windows account that wrote it '
      'can read it.',
    );
  }
  return _seedOf(
    _dpapi(text.substring(_dpapiPrefix.length), protect: false),
    path,
  );
}

String _pubspecVersion(File pubspec) {
  final match = RegExp(
    r'^version:\s*(\S+)',
    multiLine: true,
  ).firstMatch(pubspec.readAsStringSync());
  if (match == null) _fail('No "version:" line in ${pubspec.path}');
  return match.group(1)!;
}

/// [value] itself, or the file it names.
String _textOrFile(String value) {
  final file = File(value);
  return file.existsSync() ? file.readAsStringSync().trim() : value;
}

/// `--name value` pairs; `--flag` alone for those without one.
Map<String, String?> _parse(List<String> arguments) {
  const flags = {'public-key', 'help'};
  const valued = {
    'windows',
    'macos-arm64',
    'macos-x64',
    'dmg-arm64',
    'dmg-x64',
    'notes-en',
    'notes-zh',
    'minimum-version',
    'version',
    'manifest',
    'generate-key',
    'encrypt-key',
    'decrypt-key',
    'out',
  };
  final options = <String, String?>{};
  for (var i = 0; i < arguments.length; i++) {
    final argument = arguments[i];
    final name = argument.startsWith('--') ? argument.substring(2) : null;
    if (name == null || !(flags.contains(name) || valued.contains(name))) {
      _fail('Unknown argument: $argument\n\n$_usage');
    }
    if (flags.contains(name)) {
      options[name] = null;
    } else if (i + 1 < arguments.length) {
      options[name] = arguments[++i];
    } else {
      _fail('--$name needs a value.\n\n$_usage');
    }
  }
  return options;
}

Never _fail(String message) {
  stderr.writeln('\n$message');
  exit(1);
}
