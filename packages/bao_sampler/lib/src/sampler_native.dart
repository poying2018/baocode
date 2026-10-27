/// The sampler's native half on Windows and Linux: native/bao_sampler.c,
/// built by hook/build.dart.
@DefaultAsset('package:bao_sampler/src/sampler_native.dart')
library;

import 'dart:ffi';

@Native<Int32 Function()>(symbol: 'bao_sampler_init')
external int samplerInit();

/// [path] is UTF-8, ending in a 0: a Uint8List's `address` (a leaf call).
@Native<Int32 Function(Pointer<Uint8>, Int32, Int32)>(
  symbol: 'bao_sampler_start',
  isLeaf: true,
)
external int samplerStart(Pointer<Uint8> path, int millis, int interval);
