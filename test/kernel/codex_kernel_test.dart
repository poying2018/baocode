import 'dart:async';
import 'dart:io';

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
  test('a project folder that is gone is said after the view is built', () async {
    final folder = '${Directory.systemTemp.path}\\baocode-codex-gone';
    final kernel = CodexKernel(
      const KernelDescriptor(
        id: 'codex',
        label: 'Codex',
        icon: Icons.code,
        description: 'Codex',
        create: _never,
      ),
      _SilentTransport(),
      context: KernelContext(cwd: folder),
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
  });
}

AgentKernel _never(KernelContext context) => throw UnimplementedError();
