// Names the Dart code's frames of a jank sample from a diagnostics upload
// (logs/hangs/jank-*.txt; lib/diagnostics/jank_sample.dart), with the
// symbols of the build that took it: CI's `symbols-<platform>` artifact of
// the run that built that version.
//
//   dart run tool/symbolize_jank_sample.dart <sample.txt> --app <symbols>
//       [--engine <FlutterMacOS symbols>] [--out <file>]
//
// - macOS (`sample`'s own report): its `??? (in App) load address … +
//   0x…` frames, with App.macos.symbols (tool/build_macos.dart), by `atos`,
//   so on a Mac; and, given its symbols too, the engine's, `??? (in
//   FlutterMacOS)`. Those are in the engine's framework.zip, for the
//   Flutter that built that version (FLUTTER_VERSION in
//   .github/workflows/release.yml; its engine hash is
//   bin/internal/engine.version there): storage.googleapis.com/
//   flutter_infra_release/flutter/<engine hash>/darwin-x64-release/
//   framework.zip, FlutterMacOS.xcframework/macos-arm64_x86_64/dSYMs/
//   FlutterMacOS.framework.dSYM/Contents/Resources/DWARF/FlutterMacOS.
// - Windows and Linux (package:bao_sampler's): its `app.so+0x…` or
//   `libapp.so+0x…` frames, with app.windows-<arch>.symbols or
//   app.linux-<arch>.symbols, by `llvm-symbolizer` (LLVM's; on PATH, or
//   Homebrew's llvm). A hang report's (windows/runner/hang_watchdog.cpp)
//   too.
//
// Writes <sample>.symbolized.txt (or --out): the sample as it was, each such
// frame named, e.g. `FrameWatch._ended  (in App) + 4  [0x10a2b65f0]`, or
// `app.so+0x196ca2  busyInner  package:baocode/….dart:9`.
import 'dart:convert';
import 'dart:io';

final _macFrame = RegExp(
  r'\?\?\?  \(in (App|FlutterMacOS)\)  load address (0x[0-9a-f]+) \+ '
  r'0x[0-9a-f]+  \[(0x[0-9a-f]+)\]',
);

/// A frame of the Dart code, by its offset in the ELF file of it.
final _elfFrame = RegExp(r'\b(?:lib)?app\.so\+0x([0-9a-f]+)\b');

Future<void> main(List<String> arguments) async {
  String? option(String name) {
    final at = arguments.indexOf(name);
    return at < 0 || at + 1 >= arguments.length ? null : arguments[at + 1];
  }

  final options = {'--app', '--engine', '--out'};
  final inputs = [
    for (var i = 0; i < arguments.length; i++)
      if (options.contains(arguments[i]))
        null
      else if (i > 0 && options.contains(arguments[i - 1]))
        null
      else
        arguments[i],
  ].nonNulls.toList();
  final app = option('--app');
  if (inputs.length != 1 || app == null) {
    stderr.writeln(
      'Usage: dart run tool/symbolize_jank_sample.dart <sample.txt> '
      '--app <symbols> [--engine <FlutterMacOS symbols>] [--out <file>]',
    );
    exit(64);
  }
  final input = File(inputs.single);
  final text = input.readAsStringSync();
  final (out, named, total) = _macFrame.hasMatch(text)
      ? await _mac(text, {'App': app, 'FlutterMacOS': ?option('--engine')})
      : await _elf(text, app);
  final path = option('--out') ?? '${input.path}.symbolized.txt';
  File(path).writeAsStringSync(out);
  stdout.writeln('Named $named of $total frames: $path');
}

/// macOS's `sample`: its unnamed frames, by `atos`.
Future<(String, int, int)> _mac(
  String text,
  Map<String, String> symbols,
) async {
  final arch = switch (RegExp(
    r'^Code Type:\s+(\S+)',
    multiLine: true,
  ).firstMatch(text)?[1]) {
    'ARM64' => 'arm64',
    'X86-64' || 'X86_64' => 'x86_64',
    final other => _fail('The sample is for $other: not arm64 nor x86_64.'),
  };

  // Each module's addresses, by its load address: atos names them at once.
  final wanted = <(String, String), Set<String>>{};
  for (final match in _macFrame.allMatches(text)) {
    if (!symbols.containsKey(match[1])) continue;
    (wanted[(match[1]!, match[2]!)] ??= {}).add(match[3]!);
  }
  final names = <(String, String), String>{};
  for (final MapEntry(key: (module, load), value: addresses)
      in wanted.entries) {
    final list = addresses.toList();
    for (var from = 0; from < list.length; from += 500) {
      final chunk = list.sublist(from, (from + 500).clamp(0, list.length));
      final result = await Process.run('atos', [
        '-o',
        symbols[module]!,
        '-arch',
        arch,
        '-l',
        load,
        ...chunk,
      ]);
      if (result.exitCode != 0) {
        _fail('atos failed for $module: ${result.stderr}');
      }
      final lines = '${result.stdout}'.trimRight().split('\n');
      for (var i = 0; i < chunk.length && i < lines.length; i++) {
        // An address atos cannot name comes back as it went.
        if (lines[i].startsWith('0x')) continue;
        // "FrameWatch._ended (in App.macos.symbols) + 4": the module as
        // the sample names it.
        names[(module, chunk[i])] = lines[i].replaceFirst(
          RegExp(r' \(in [^)]*\)'),
          '  (in $module)',
        );
      }
    }
  }

  var named = 0;
  final out = text.replaceAllMapped(_macFrame, (match) {
    final name = names[(match[1]!, match[3]!)];
    if (name == null) return match[0]!;
    named++;
    return '$name  [${match[3]}]';
  });
  return (out, named, _macFrame.allMatches(text).length);
}

/// package:bao_sampler's (and a hang report's): `app.so+0x…`, by
/// `llvm-symbolizer`.
Future<(String, int, int)> _elf(String text, String symbols) async {
  final lines = const LineSplitter().convert(text);
  // A stack's first frame is where its thread was; the rest are return
  // addresses, named by the call just before them.
  final wanted = <int>{};
  final queried = <int, int>{};
  var first = true;
  for (final (at, line) in lines.indexed) {
    final match = _elfFrame.firstMatch(line);
    if (match == null) {
      first = !line.trim().startsWith('...');
      continue;
    }
    final offset = int.parse(match[1]!, radix: 16);
    queried[at] = first ? offset : offset - 1;
    wanted.add(queried[at]!);
    first = false;
  }
  final names = <int, String>{};
  final addresses = wanted.toList();
  final symbolizer = _llvmSymbolizer();
  for (var from = 0; from < addresses.length; from += 500) {
    final chunk = addresses.sublist(
      from,
      (from + 500).clamp(0, addresses.length),
    );
    final result = await Process.run(symbolizer, [
      '--obj=$symbols',
      '--output-style=JSON',
      for (final address in chunk) '0x${address.toRadixString(16)}',
    ]);
    if (result.exitCode != 0) _fail('llvm-symbolizer failed: ${result.stderr}');
    for (final entry in jsonDecode('${result.stdout}') as List) {
      final address = int.parse(
        (entry['Address'] as String).substring(2),
        radix: 16,
      );
      // Innermost first: the functions inlined into the one that was
      // called.
      final frames = [
        for (final symbol in entry['Symbol'] as List)
          if ((symbol['FunctionName'] as String?)?.isNotEmpty ?? false)
            '${symbol['FunctionName']}  '
                '${symbol['FileName']}:${symbol['Line']}',
      ];
      if (frames.isNotEmpty) names[address] = frames.join('  <- inlined in ');
    }
  }

  var named = 0;
  final out = StringBuffer();
  for (final (at, line) in lines.indexed) {
    final name = switch (queried[at]) {
      final address? => names[address],
      null => null,
    };
    if (name != null) named++;
    out.writeln(name == null ? line : '$line  $name');
  }
  return (out.toString(), named, queried.length);
}

String _llvmSymbolizer() {
  for (final candidate in [
    'llvm-symbolizer',
    '/opt/homebrew/opt/llvm/bin/llvm-symbolizer',
    '/usr/local/opt/llvm/bin/llvm-symbolizer',
  ]) {
    try {
      if (Process.runSync(candidate, ['--version']).exitCode == 0) {
        return candidate;
      }
    } on ProcessException {
      // Not there.
    }
  }
  _fail('No llvm-symbolizer: install LLVM (brew install llvm).');
}

Never _fail(String message) {
  stderr.writeln(message);
  exit(1);
}
