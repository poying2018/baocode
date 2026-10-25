// Says which product this build of the app is, by the name of the
// executable it builds: baocode.exe is BaoCode (the Claude Code one) and
// baocode-codex.exe is the codex one. The name decides the folder the
// product's data goes in, the window it has and the registration Windows
// keeps for it (see windows/runner/app_identity.cpp), so the two products
// keep apart and neither disturbs the other.
//
// The name is in windows/CMakeLists.txt, as the `set(BINARY_NAME "...")` the
// Flutter tool reads to find the executable to run. This tool writes it.
//
//   dart run tool/set_product.dart            the codex product
//   dart run tool/set_product.dart baocode    BaoCode (the Claude Code one)
//
// It changes only that one line, so the build that follows is a rebuild of
// the app, not of the native assets.
import 'dart:io';

void main(List<String> arguments) {
  final product = arguments.isEmpty ? 'codex' : arguments.first;
  const products = {
    'baocode': 'baocode',
    'codex': 'baocode-codex',
  };
  final binaryName = products[product];
  if (binaryName == null) {
    stderr.writeln(
      'Unknown product "$product". It is baocode (BaoCode, the Claude Code '
      'one) or codex (the codex one).',
    );
    exit(2);
  }

  final file = File('windows/CMakeLists.txt');
  if (!file.existsSync()) {
    stderr.writeln('Run this from the repository\'s root.');
    exit(2);
  }
  final text = file.readAsStringSync();
  final pattern = RegExp(r'set\(BINARY_NAME\s*"[^"]*"\s*\)');
  if (!pattern.hasMatch(text)) {
    stderr.writeln(
      'windows/CMakeLists.txt has no set(BINARY_NAME "...") line to write.',
    );
    exit(1);
  }
  final written = text.replaceAll(
    pattern,
    'set(BINARY_NAME "$binaryName")',
  );
  if (written == text) {
    stdout.writeln('The product is already $product ($binaryName).');
    return;
  }
  file.writeAsStringSync(written);
  stdout.writeln('The product is now $product ($binaryName).');
}
