import 'package:code_assets/code_assets.dart';
import 'package:hooks/hooks.dart';
import 'package:native_toolchain_c/native_toolchain_c.dart';

import 'windows_vswhere.dart';

/// Builds the sampler (native/bao_sampler.c) for Windows and Linux, for an
/// app and for `flutter test` alike. macOS has `/usr/bin/sample` instead;
/// the phones and the web have none.
void main(List<String> arguments) async {
  await build(arguments, (input, output) async {
    if (!input.config.buildCodeAssets) return;
    final os = input.config.code.targetOS;
    if (os != OS.windows && os != OS.linux) return;
    if (os == OS.windows) await configureWindowsCompiler(input.config);
    await CBuilder.library(
      name: 'bao_sampler',
      assetName: 'src/sampler_native.dart',
      sources: const ['native/bao_sampler.c'],
      frameworks: const [],
      libraries: os == OS.linux ? const ['pthread', 'dl'] : const [],
      std: os == OS.windows ? null : 'gnu11',
      flags: os == OS.windows
          ? const ['/W3', '/utf-8', '/D_CRT_SECURE_NO_WARNINGS']
          : const ['-Wall', '-Wextra', '-fvisibility=hidden'],
    ).run(input: input, output: output);
  });
}
