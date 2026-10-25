// The adapter against a real process: tool/codex_stub.dart speaks the
// app-server's protocol over a pipe, the way the Codex CLI does, and this
// drives the kernel against it — the handshake, a turn, the approval the
// server asks for, the reply.
//
// It is what tells that the adapter and the protocol agree, without a
// Codex of one's own: the mock (lib/kernel/codex/mock_codex_transport.dart)
// is written by the same hand as the adapter, and agrees with it by
// construction; this one is a process with pipes, and the protocol's own
// rules about ids apply to it.
import 'dart:async';
import 'dart:io';

import 'package:baocode/chat/chat_models.dart';
import 'package:baocode/kernel/agent_kernel.dart';
import 'package:baocode/kernel/codex/codex_kernel.dart';
import 'package:baocode/kernel/codex/codex_process_transport_io.dart';
import 'package:baocode/kernel/codex/codex_transport.dart';
import 'package:baocode/kernel/codex/codex_transport_factory.dart';
import 'package:baocode/kernel/kernel_event.dart';
import 'package:baocode/kernel/kernel_registry.dart';
import 'package:baocode/kernel/kernel_types.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

/// The Dart that runs the stub: the SDK of the Flutter that runs this.
String? _dart() {
  final root = Platform.environment['FLUTTER_ROOT'];
  if (root == null || root.isEmpty) return null;
  final name = Platform.isWindows ? 'dart.exe' : 'dart';
  final dart = p.join(root, 'bin', 'cache', 'dart-sdk', 'bin', name);
  return File(dart).existsSync() ? dart : null;
}

void main() {
  test('a turn goes through a real app-server process', () async {
    final dart = _dart();
    if (dart == null) {
      markTestSkipped('no Dart SDK beside the Flutter that runs this');
      return;
    }
    final stub = p.join(Directory.current.path, 'tool', 'codex_stub.dart');
    if (!File(stub).existsSync()) {
      markTestSkipped('the stub of an app-server is not there');
      return;
    }
    ProcessCodexTransport.command = CodexExecutable(
      dart,
      arguments: [stub],
    );
    addTearDown(() => ProcessCodexTransport.command = null);

    final transport = await ProcessCodexTransport.start(
      CodexLaunch(cwd: Directory.current.path, home: Directory.current.path),
    );
    addTearDown(() async {
      transport.close();
      await transport.exited.timeout(
        const Duration(seconds: 5),
        onTimeout: () {},
      );
    });

    final kernel = CodexKernel(
      KernelRegistry.codex,
      transport,
      context: KernelContext(cwd: Directory.current.path),
    );
    addTearDown(kernel.dispose);

    final events = <KernelEvent>[];
    final ended = Completer<void>();
    kernel.events.listen((event) {
      events.add(event);
      if (event is TurnEnded && !ended.isCompleted) ended.complete();
    });

    // The models the server has: the server's answer to our own request,
    // which carries an id of ours — the server counts ids of its own, and
    // one of them may be the same number.
    kernel.prepare();
    for (
      var i = 0;
      i < 100 && kernel.health.status != KernelHealthStatus.ready;
      i++
    ) {
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }
    expect(kernel.health.status, KernelHealthStatus.ready);
    expect(
      kernel.model.options.map((option) => option.id),
      ['gpt-5.5-codex'],
      reason: 'the server answered the request for its models',
    );

    kernel.send(const KernelTurn(id: 't1', text: 'run the tests'));
    await Future<void>.delayed(const Duration(milliseconds: 200));

    // The server asks whether the command may run: the card is shown, and
    // the answer goes back in the shape the server expects.
    ApprovalRequest? approval;
    for (var i = 0; i < 100 && approval == null; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 50));
      for (final event in events) {
        if (event is InteractionRequested &&
            event.request is ApprovalRequest) {
          approval = event.request as ApprovalRequest;
        }
      }
    }
    expect(approval, isNotNull, reason: 'the command was to be approved');
    expect(approval!.title, 'Run command');
    kernel.answer(
      approval.id,
      const ApprovalAnswer(ApprovalDecision.allowOnce),
    );

    await ended.future.timeout(const Duration(seconds: 30));

    final texts = [
      for (final event in events)
        if (event is ItemCompleted && event.item is AssistantTextItem)
          (event.item as AssistantTextItem).text,
    ];
    expect(texts.join(), contains('The tests pass'));
    final commands = [
      for (final event in events)
        if (event is ItemUpserted && event.item is TerminalItem)
          event.item as TerminalItem,
    ];
    expect(
      commands.map((command) => command.status),
      contains(CommandStatus.succeeded),
      reason: 'the command that was approved ran',
    );
    final reasoning = [
      for (final event in events)
        if (event is ItemCompleted && event.item is ThinkingItem)
          (event.item as ThinkingItem).text,
    ];
    expect(reasoning.join(), contains('Looking at it'));
  }, timeout: const Timeout(Duration(minutes: 2)));
}
