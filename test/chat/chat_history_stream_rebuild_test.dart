import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:baocode/chat/chat_feed.dart';
import 'package:baocode/chat/chat_history_view.dart';
import 'package:baocode/chat/chat_models.dart';
import 'package:baocode/chat/chat_session.dart';
import 'package:baocode/chat/composer/composer_draft.dart';
import 'package:baocode/theme/app_theme.dart';

class _StreamFeed extends ChangeNotifier implements ChatFeed {
  _StreamFeed(this.items, {this.streaming = false});

  List<ChatItem> items;
  bool streaming;

  /// A turn the agent took up on its own: none here, the user's message
  /// starts every turn these tests have.
  bool unprompted = false;

  @override
  int get itemCount => items.length;

  @override
  ChatItem itemAt(int index) => items[index];

  @override
  bool get isStreaming => streaming;

  @override
  bool get isUnprompted => unprompted;

  @override
  bool get canEditMessages => false;

  @override
  ({int index, ComposerDraft draft})? get editing => null;

  @override
  set editing(({int index, ComposerDraft draft})? value) {}

  @override
  void editMessage(int index, ComposerMessage message) {}

  @override
  VoidCallback? moveToBackgroundAt(int index) => null;

  @override
  VoidCallback? stopAt(int index) => null;

  /// A word of the reply the agent is streaming: the last item grows.
  void word(String text) {
    final last = items.last;
    items = [
      ...items.take(items.length - 1),
      if (last is AssistantTextItem)
        AssistantTextItem('${last.text}$text')
      else
        last,
    ];
    notifyListeners();
  }

  /// A step of the turn changing state: the last item's status.
  void step(ToolStatus status) {
    final last = items.last as ToolCallItem;
    items = [
      ...items.take(items.length - 1),
      ToolCallItem(kind: last.kind, target: last.target, status: status),
    ];
    notifyListeners();
  }
}

/// Mounts the conversation and returns the feed behind it.
Future<_StreamFeed> _mount(WidgetTester tester, {bool streaming = false}) async {
  tester.view.physicalSize = const Size(1000, 700);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final feed = _StreamFeed(
    [
      UserMessageItem(text: 'Where is it?', worked: const Duration(seconds: 3)),
      const AssistantTextItem('Looking'),
    ],
    streaming: streaming,
  );
  await tester.pumpWidget(
    MaterialApp(
      theme: buildAppTheme(),
      home: Scaffold(body: ChatHistoryView(feed: feed)),
    ),
  );
  await tester.pumpAndSettle();
  return feed;
}

/// Counts the rebuilds of the conversation itself while set up.
int Function() _countRebuilds(WidgetTester tester) {
  var builds = 0;
  debugOnRebuildDirtyWidget = (element, builtOnce) {
    if (element.widget is ChatHistoryView) builds++;
  };
  addTearDown(() => debugOnRebuildDirtyWidget = null);
  return () {
    final now = builds;
    builds = 0;
    return now;
  };
}

void main() {
  testWidgets("a streamed reply's words rebuild the conversation no nearer "
      'together than a frame, and all of them at last', (tester) async {
    final feed = await _mount(tester);
    final take = _countRebuilds(tester);

    // The turn the user's message started is news: built at once.
    feed.streaming = true;
    feed.notifyListeners();
    await tester.pump();
    expect(take(), greaterThanOrEqualTo(1), reason: 'a turn starting is news');

    // Three words of that same turn, all within one frame's worth of time:
    // no rebuild a word, the words joining the one frame that comes.
    for (final word in [' there', ' it', ' is']) {
      feed.word(word);
      await tester.pump();
    }
    // The frame being made may have been so slow a real machine had run out
    // the gap by the first word, so one rebuild there is no fault; never one
    // a word.
    expect(
      take(),
      lessThanOrEqualTo(1),
      reason: 'words in one frame ask for no rebuild each',
    );

    await tester.pump(const Duration(milliseconds: 80));
    expect(take(), 1, reason: 'the words all show, in one rebuild');
    expect(
      find.textContaining('Looking there it is', findRichText: true),
      findsOneWidget,
    );
  });

  testWidgets('a turn ending is built at once, no wait', (tester) async {
    final feed = await _mount(tester, streaming: true);
    final take = _countRebuilds(tester);

    feed.word(' the end');
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 80));
    take();

    feed.streaming = false;
    feed.notifyListeners();
    await tester.pump();
    expect(take(), 1, reason: 'a turn ending is news, not a streamed word');
  });

  testWidgets("a step's news is built at once, though the reply streams", (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1000, 700);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final feed = _StreamFeed(
      const [
        UserMessageItem(text: 'Fix the bug'),
        AssistantTextItem('Reading'),
        ToolCallItem(kind: ToolKind.read, target: 'a.dart'),
      ],
      streaming: true,
    );
    await tester.pumpWidget(
      MaterialApp(
        theme: buildAppTheme(),
        home: Scaffold(body: ChatHistoryView(feed: feed)),
      ),
    );
    await tester.pumpAndSettle();
    final take = _countRebuilds(tester);

    // The count is the same and the last item is no text: not a word.
    feed.step(ToolStatus.succeeded);
    await tester.pump();
    expect(take(), 1, reason: "a step's news waits for no frame");
  });

  testWidgets("behind another window's, the words come a fourth as often", (
    tester,
  ) async {
    final feed = await _mount(tester);
    final take = _countRebuilds(tester);

    // The turn starting is news, as ever.
    feed.streaming = true;
    feed.notifyListeners();
    await tester.pump();
    take();

    // Another window in front: what changes is barely watched, and the CPU
    // is the agents' — a fourth as often (250 ms, not 66).
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    addTearDown(
      () => tester.binding.handleAppLifecycleStateChanged(
        AppLifecycleState.resumed,
      ),
    );

    feed.word(' one');
    await tester.pump();
    expect(take(), 0, reason: 'a word asks for no rebuild of its own');

    await tester.pump(const Duration(milliseconds: 100));
    expect(take(), 0, reason: 'not yet: a quarter as often as in front');

    await tester.pump(const Duration(milliseconds: 200));
    expect(take(), 1, reason: 'the words show, once, 250 ms on');
  });
}
