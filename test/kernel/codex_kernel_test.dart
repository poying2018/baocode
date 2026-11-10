import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:baocode/kernel/agent_kernel.dart';
import 'package:baocode/kernel/codex/codex_kernel.dart';
import 'package:baocode/kernel/codex/codex_transport.dart';
import 'package:baocode/kernel/kernel_event.dart';
import 'package:baocode/kernel/kernel_types.dart';

/// A transport that answers nothing: the kernel is not asked to work.
class _SilentTransport implements CodexTransport {
  @override
  Stream<Map<String, Object?>> get messages => const Stream.empty();

  @override
  void write(Map<String, Object?> message) {}

  @override
  Future<Map<String, Object?>> request(
    String method, [
    Map<String, Object?> params = const {},
  ]) => Future.value(const {});

  @override
  Future<void> get exited => Completer<void>().future;

  @override
  List<String> get stderr => const [];

  @override
  void restart() {}

  @override
  void close() {}
}

/// The kernel's own state, and when it says so.
void main() {
  test(
    'a project folder that is gone is said after the view is built',
    () async {
      final kernel = CodexKernel(
        const KernelDescriptor(
          id: 'codex',
          label: 'Codex',
          icon: Icons.code,
          description: 'Codex',
          create: _never,
        ),
        _SilentTransport(),
      );
      addTearDown(kernel.closeEvents);
      final told = <KernelEvent>[];
      kernel.events.listen(told.add);

      // A view attaches while it is being built: saying the folder is gone
      // now would make the workspace notify its listeners during that
      // build, and the framework would have none of it.
      kernel.prepare();
      expect(told.whereType<KernelInfoChanged>(), isEmpty);
      expect(kernel.health.status, KernelHealthStatus.failed);

      await Future<void>.delayed(Duration.zero);
      expect(told.whereType<KernelInfoChanged>(), isNotEmpty);
    },
    skip:
        'The Codex product and its richer kernel live in '
        'poying2018/baocode-codex; this repository ships BaoCode Claude.',
  );
}

AgentKernel _never(KernelContext context) => throw UnimplementedError();
