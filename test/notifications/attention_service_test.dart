import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:baocode/chat/chat_session.dart';
import 'package:baocode/kernel/kernel_types.dart';
import 'package:baocode/l10n/l10n.dart';
import 'package:baocode/notifications/attention_host.dart';
import 'package:baocode/notifications/attention_service.dart';
import 'package:baocode/notifications/attention_settings.dart';
import 'package:baocode/workspace/workspace.dart';

/// Records what the service asks of the system.
class _FakeHost implements AttentionHost {
  final List<({String id, String title, String body})> notifications = [];
  final List<Object> sounds = [];
  int attentionRequests = 0;
  int? badge;
  final List<TrayState?> trays = [];
  void Function(String? id)? openHandler;

  @override
  Future<void> notify({
    required String id,
    required String title,
    required String body,
  }) async => notifications.add((id: id, title: title, body: body));

  @override
  Future<void> playSound({String? path, Uint8List? bytes}) async =>
      sounds.add(path ?? bytes!);

  @override
  Future<void> requestAttention() async => attentionRequests++;

  @override
  Future<void> setBadge(int count) async => badge = count;

  @override
  Future<void> setTray(TrayState? state) async => trays.add(state);

  @override
  Future<void> quit() async {}

  @override
  Future<String?> pickSound() async => null;

  @override
  set onOpen(void Function(String? id)? handler) => openHandler = handler;
}

AgentThread _thread(Workspace workspace, String title) =>
    workspace.threads.firstWhere((thread) => thread.title == title);

Future<void> _runUntilQuestion(WidgetTester tester, ChatSession session) async {
  for (var i = 0; i < 400 && session.pendingInteraction == null; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
  expect(session.pendingInteraction, isNotNull);
}

Future<void> _runUntilDone(WidgetTester tester, ChatSession session) async {
  for (var i = 0; i < 200 && session.isStreaming; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
  expect(session.isStreaming, isFalse);
}

const _answer = QuestionAnswer([
  ['随内容自动增高，最多 8 行'],
]);

void main() {
  late Workspace workspace;
  late _FakeHost host;
  late AttentionService service;
  var settings = const AttentionSettings();
  var focused = true;
  final opened = <AgentThread>[];

  void start() {
    workspace = Workspace.mock();
    host = _FakeHost();
    service = AttentionService(
      workspace: workspace,
      host: host,
      settings: () => settings,
      l10n: () => englishLocalizations,
      onOpen: opened.add,
      focused: () => focused,
    )..start();
  }

  setUp(() {
    settings = const AttentionSettings();
    focused = true;
    opened.clear();
  });

  tearDown(() {
    service.dispose();
  });

  testWidgets('notifies of a background agent that asks, then finishes', (
    tester,
  ) async {
    start();
    // One mock agent starts unread.
    expect(host.badge, 1);
    expect(host.trays.last!.dot, isTrue);

    final background = _thread(workspace, 'Rate limit per API key');
    background.session.send(const ComposerMessage(text: '加一个限流'));
    await tester.pump();
    expect(host.trays.last!.labels['running'], '1 running');

    await _runUntilQuestion(tester, background.session);
    expect(host.notifications, hasLength(1));
    final asked = host.notifications.single;
    expect(asked.title, 'Rate limit per API key');
    expect(asked.body, startsWith('Needs your input'));
    expect(host.attentionRequests, 1);
    expect(host.sounds, hasLength(1));
    expect(host.sounds.single, isA<Uint8List>());
    expect(host.badge, 2);
    expect(host.trays.last!.waiting.single.title, 'Rate limit per API key');

    background.session.answer(_answer);
    await _runUntilDone(tester, background.session);
    expect(background.status, ThreadStatus.unread);
    expect(host.notifications, hasLength(2));
    expect(host.notifications.last.body, startsWith('Finished'));
    // A finish does not bounce the Dock icon.
    expect(host.attentionRequests, 1);
    expect(host.badge, 2);
    expect(host.trays.last!.waiting, isEmpty);

    // Clicked: the agent opens.
    host.openHandler!(asked.id);
    expect(opened, [background]);
    await tester.pump(const Duration(seconds: 5));
  });

  testWidgets('the agent in view notifies only while the window is not in '
      'front', (tester) async {
    start();
    final shown = workspace.selected;
    shown.session.send(const ComposerMessage(text: '加一个限流'));
    await _runUntilQuestion(tester, shown.session);
    expect(host.notifications, isEmpty);
    expect(host.sounds, isEmpty);

    // Away from the window: its turn ends unseen, and is told of.
    focused = false;
    service.refresh();
    workspace.windowActive = false;
    shown.session.answer(_answer);
    await _runUntilDone(tester, shown.session);
    expect(host.notifications, hasLength(1));
    expect(shown.status, ThreadStatus.unread);

    // Back at the window, what is in view is seen.
    focused = true;
    workspace.windowActive = true;
    expect(shown.status, ThreadStatus.idle);
    await tester.pump(const Duration(seconds: 5));
  });

  testWidgets('follows the settings', (tester) async {
    settings = const AttentionSettings(
      events: {AttentionEvent.finished},
      sound: NotificationSoundValue.none,
      when: NotifyWhen.always,
      tray: false,
    );
    start();
    expect(host.trays, isEmpty);
    final shown = workspace.selected;
    shown.session.send(const ComposerMessage(text: '加一个限流'));
    await _runUntilQuestion(tester, shown.session);
    // Not for a question; no Dock bounce.
    expect(host.notifications, isEmpty);
    expect(host.attentionRequests, 0);
    shown.session.answer(_answer);
    await _runUntilDone(tester, shown.session);
    // Always: even the agent in view; without a sound.
    expect(host.notifications, hasLength(1));
    expect(host.sounds, isEmpty);

    // Off: the count stays.
    settings = const AttentionSettings(enabled: false);
    final background = _thread(workspace, 'Rate limit per API key');
    background.session.send(const ComposerMessage(text: '加一个限流'));
    await _runUntilQuestion(tester, background.session);
    expect(host.notifications, hasLength(1));
    expect(host.badge, 2);
    // The tray, now on, shows it waiting.
    expect(host.trays.last!.waiting.single.title, 'Rate limit per API key');
    background.session.stop();
    await tester.pump(const Duration(seconds: 5));
  });

  test('settings from settings.json', () {
    final defaults = AttentionSettings.parse(const {});
    expect(defaults.enabled, isTrue);
    expect(defaults.sound, NotificationSoundValue.microwave);
    expect(defaults.when, NotifyWhen.unfocused);
    expect(defaults.events, AttentionEvent.values.toSet());
    expect(defaults.tray, isTrue);

    final set = AttentionSettings.parse(const {
      'notifications.enabled': false,
      'notifications.sound': 'system:Glass',
      'notifications.when': 'always',
      'notifications.events': ['finished', 'bogus'],
      'tray.enabled': false,
    });
    expect(set.enabled, isFalse);
    expect(NotificationSoundValue.systemName(set.sound), 'Glass');
    expect(set.when, NotifyWhen.always);
    expect(set.events, {AttentionEvent.finished});
    expect(set.tray, isFalse);
    expect(set.notifies(AttentionEvent.finished), isFalse);

    expect(AttentionSettings.encodeEvents(AttentionEvent.values.toSet()), null);
    expect(AttentionSettings.encodeEvents({}), isEmpty);
    expect(NotificationSoundValue.isFile('/tmp/a.wav'), isTrue);
    expect(NotificationSoundValue.isFile('microwave'), isFalse);
    expect(
      NotificationSoundValue.isFile(NotificationSoundValue.manOhYeah),
      isFalse,
    );
    expect(
      NotificationSoundValue.isFile(NotificationSoundValue.gulpGulpGulpGulp),
      isFalse,
    );
  });

  test('the tray icon is put up as the app starts, with no agent in it', () {
    // The tray icon is how the user finds the app when its window is
    // closed (app_windows.dart's _quitIfNoneShows: with a tray, the app
    // stays; without one, it goes with its last window). It must not wait
    // for an agent to change something, or the app has no way back for as
    // long as none does.
    workspace = Workspace();
    host = _FakeHost();
    service = AttentionService(
      workspace: workspace,
      host: host,
      settings: () => settings,
      l10n: () => englishLocalizations,
      onOpen: opened.add,
      focused: () => focused,
    )..start();

    expect(workspace.threads, isEmpty);
    expect(host.trays, hasLength(1));
    expect(host.trays.single, isNotNull);
    expect(host.trays.single!.dot, isFalse);
    expect(host.trays.single!.tooltip, 'BaoCode');
    expect(host.trays.single!.labels['show'], isNotEmpty);
    expect(host.trays.single!.labels['quit'], isNotEmpty);
  });

  test('the tray icon is put up again after the app lost it', () {
    // The host may have refused it (the tray was not there yet): the
    // service asks again, so the icon comes back rather than the app
    // losing its way back to itself.
    workspace = Workspace.mock();
    host = _FakeHost();
    service = AttentionService(
      workspace: workspace,
      host: host,
      settings: () => settings,
      l10n: () => englishLocalizations,
      onOpen: opened.add,
      focused: () => focused,
    )..start();
    expect(host.trays, hasLength(1));

    // The settings change (the language, say): the tray is asked for
    // again, with the new words.
    settings = const AttentionSettings(
      when: NotifyWhen.always,
      events: {AttentionEvent.finished},
    );
    service.refresh();
    expect(host.trays, hasLength(2));
    expect(host.trays.last, isNotNull);
  });
}
