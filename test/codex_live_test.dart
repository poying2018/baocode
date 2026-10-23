// Whole turns, history, naming and forking against the real server.
//
// Run it with:
//   flutter test test/codex_live_test.dart --plain-name "a turn"
//
// It is skipped unless CODEX_LIVE=1, for the server it needs.
import 'dart:async';
import 'dart:io';

import 'package:baocode/kernel/agent_kernel.dart';
import 'package:baocode/kernel/codex/codex_kernel.dart';
import 'package:baocode/kernel/codex/codex_process_transport_io.dart';
import 'package:baocode/kernel/codex/codex_transport.dart';
import 'package:baocode/kernel/kernel_event.dart';
import 'package:baocode/kernel/kernel_registry.dart';
import 'package:baocode/kernel/kernel_types.dart';
import 'package:baocode/chat/chat_models.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('a turn', () async {
    if (Platform.environment['CODEX_LIVE'] != '1') {
      markTestSkipped('needs CODEX_LIVE=1 and a Codex that runs');
      return;
    }
    // Its own state, in the app's own folder: the Codex Desktop app
    // holds the user's `~/.codex` while it runs, and a second server
    // cannot start at all while it does.
    final home =
        Platform.environment['CODEX_LIVE_HOME'] ??
        '${Directory.systemTemp.path}\\baocode-codex-live';
    Directory(home).createSync(recursive: true);
    for (final name in const [
      'config.toml',
      'magpie-models.json',
      'hooks.json',
      'cc-switch-model-catalog.json',
    ]) {
      final from = File(
        '${Platform.environment['USERPROFILE']}\\.codex\\$name',
      );
      if (from.existsSync()) {
        from.copySync('$home\\$name');
      }
    }
    final transport = await ProcessCodexTransport.start(
      CodexLaunch(cwd: Directory.current.path, home: home),
    );
    final kernel = CodexKernel(
      KernelRegistry.codex,
      transport,
      context: const KernelContext(cwd: r'F:\Projects'),
    );
    final events = <String>[];
    final texts = <String>[];
    final deltas = <String>[];
    final ended = Completer<void>();
    final renames = <String>[];
    kernel.events.listen((e) {
      events.add(e.runtimeType.toString());
      if (e is ItemCompleted && e.item is AssistantTextItem) {
        final item = e.item as AssistantTextItem;
        if (item.text.isNotEmpty) texts.add(item.text);
      }
      if (e is TextDelta) deltas.add(e.text);
      if (e is TurnEnded) ended.complete();
      if (e is SessionRenamed) renames.add(e.title);
    });
    kernel.send(const KernelTurn(id: 't1', text: 'Reply with exactly: PONG'));
    await ended.future.timeout(const Duration(seconds: 90));
    // ignore: avoid_print
    print('events: ${events.toSet().toList()}');
    // ignore: avoid_print
    print('deltas: $deltas');
    // The text comes in pieces, as it does in the chat.
    expect(deltas.join(), contains('PONG'));
    expect(texts, isNotEmpty, reason: 'the reply is on the transcript');

    final threadId = kernel.sessionId;
    expect(threadId, isNotNull);
    kernel.rename('Live probe');
    for (var attempt = 0; attempt < 20; attempt++) {
      if (renames.contains('Live probe')) break;
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
    expect(renames, contains('Live probe'));
    final forked = await kernel.fork(title: 'Live probe fork');
    expect(forked?.id, isNot(threadId));
    expect(forked?.title, 'Live probe fork');
    kernel.dispose();

    final historyEvents = <KernelEvent>[];
    final historyLoaded = Completer<List<(String, ChatItem)>>();
    final history = CodexKernel(
      KernelRegistry.codex,
      transport,
      context: KernelContext(
        cwd: r'F:\Projects',
        resume: SessionRecord(
          id: threadId!,
          title: 'Live probe',
          updatedAt: DateTime.now(),
          cwd: r'F:\Projects',
        ),
      ),
    );
    history.events.listen((event) {
      historyEvents.add(event);
      if (event is HistoryPrepended && !historyLoaded.isCompleted) {
        historyLoaded.complete(event.items);
      }
    });
    final items = await historyLoaded.future.timeout(
      const Duration(seconds: 20),
    );
    expect([
      for (final (_, item) in items)
        if (item is UserMessageItem) item.text,
    ], contains('Reply with exactly: PONG'));
    expect([
      for (final (_, item) in items)
        if (item is AssistantTextItem) item.text,
    ], contains('PONG'));
    history.dispose();
    transport.close();
    await transport.exited.timeout(const Duration(seconds: 5));
  }, timeout: const Timeout(Duration(minutes: 2)));
}
