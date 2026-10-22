// The user's hands, for the perf app: pointer events into the gesture
// binding as the engine delivers them (hit tested, through the same
// listeners and recognizers), keys into the hardware keyboard (the focus
// tree, shortcuts, the editor's own handling), and what a key that is not
// handled types into the text input client, as the platform's input
// method would.

import 'dart:async';

import 'package:flutter/gestures.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import 'perf_probe.dart';

/// The text input client the focus is in (the editor's state is one): what
/// the platform's input method types into. Found from the focus, not by a
/// [TextInputControl] of this app's, which would take the platform's place
/// and spare the app the messages it sends it at each key.
TextInputClient? _focusedClient() {
  final context = FocusManager.instance.primaryFocus?.context;
  if (context == null) return null;
  if (context case StatefulElement(:final TextInputClient state)) return state;
  TextInputClient? found;
  context.visitAncestorElements((element) {
    if (element case StatefulElement(:final TextInputClient state)) {
      found = state;
      return false;
    }
    return true;
  });
  return found;
}

class PerfInput {
  final Stopwatch _clock = Stopwatch()..start();
  Duration get _now => _clock.elapsed;

  int get _viewId =>
      WidgetsBinding.instance.platformDispatcher.implicitView?.viewId ?? 0;

  static const _mouse = 1;
  static const _trackpad = 2;
  int _pointer = 100;
  bool _mouseAdded = false;
  Offset _mouseAt = Offset.zero;

  void _send(PointerEvent event) =>
      GestureBinding.instance.handlePointerEvent(event);

  void _addMouse(Offset at) {
    if (_mouseAdded) return;
    _mouseAdded = true;
    _send(
      PointerAddedEvent(
        viewId: _viewId,
        timeStamp: _now,
        kind: PointerDeviceKind.mouse,
        device: _mouse,
        position: at,
      ),
    );
  }

  void hover(Offset at) {
    _addMouse(at);
    _send(
      PointerHoverEvent(
        viewId: _viewId,
        timeStamp: _now,
        kind: PointerDeviceKind.mouse,
        device: _mouse,
        position: at,
        delta: at - _mouseAt,
      ),
    );
    _mouseAt = at;
  }

  /// A left click at [at], the button held for a frame.
  Future<void> click(Offset at) async {
    hover(at);
    final pointer = ++_pointer;
    _send(
      PointerDownEvent(
        viewId: _viewId,
        timeStamp: _now,
        pointer: pointer,
        kind: PointerDeviceKind.mouse,
        device: _mouse,
        position: at,
        buttons: kPrimaryMouseButton,
      ),
    );
    await Future<void>.delayed(const Duration(milliseconds: 30));
    _send(
      PointerUpEvent(
        viewId: _viewId,
        timeStamp: _now,
        pointer: pointer,
        kind: PointerDeviceKind.mouse,
        device: _mouse,
        position: at,
      ),
    );
  }

  /// The left button pressed at [from], moved to [to] in [steps] moves
  /// [every] apart (a mouse reports at 125Hz or more), held [hold] there,
  /// released: a sash dragged, text selected, an agent moved. Each move is
  /// marked ([PerfMark.drag]).
  Future<void> drag(
    Offset from,
    Offset to, {
    int steps = 60,
    Duration every = const Duration(milliseconds: 8),
    Duration hold = Duration.zero,
  }) async {
    await dragAlong(
      [for (var i = 0; i <= steps; i++) Offset.lerp(from, to, i / steps)!],
      every: every,
      hold: hold,
    );
  }

  /// The left button pressed at the first of [points], moved through the
  /// rest, released at the last.
  Future<void> dragAlong(
    List<Offset> points, {
    Duration every = const Duration(milliseconds: 8),
    Duration hold = Duration.zero,
  }) async {
    hover(points.first);
    final pointer = ++_pointer;
    _send(
      PointerDownEvent(
        viewId: _viewId,
        timeStamp: _now,
        pointer: pointer,
        kind: PointerDeviceKind.mouse,
        device: _mouse,
        position: points.first,
        buttons: kPrimaryMouseButton,
      ),
    );
    var at = points.first;
    for (final point in points.skip(1)) {
      await Future<void>.delayed(every);
      PerfProbe.instance.mark(PerfMark.drag);
      _send(
        PointerMoveEvent(
          viewId: _viewId,
          timeStamp: _now,
          pointer: pointer,
          kind: PointerDeviceKind.mouse,
          device: _mouse,
          position: point,
          delta: point - at,
          buttons: kPrimaryMouseButton,
        ),
      );
      at = point;
    }
    if (hold > Duration.zero) await Future<void>.delayed(hold);
    _send(
      PointerUpEvent(
        viewId: _viewId,
        timeStamp: _now,
        pointer: pointer,
        kind: PointerDeviceKind.mouse,
        device: _mouse,
        position: at,
      ),
    );
    _mouseAt = at;
  }

  /// [count] clicks at [at], as quick as a double (or triple) click.
  Future<void> clicks(Offset at, int count) async {
    for (var i = 0; i < count; i++) {
      PerfProbe.instance.mark(PerfMark.action);
      await click(at);
      await Future<void>.delayed(const Duration(milliseconds: 40));
    }
  }

  /// A mouse wheel's notch at [at]: [dy] down (negative, up), [dx] right
  /// (a tilted wheel, or shift held).
  void wheel(Offset at, double dy, {double dx = 0}) {
    if (_mouseAt != at) hover(at);
    PerfProbe.instance.mark(PerfMark.scroll);
    _send(
      PointerScrollEvent(
        viewId: _viewId,
        timeStamp: _now,
        kind: PointerDeviceKind.mouse,
        device: _mouse,
        position: at,
        scrollDelta: Offset(dx, dy),
      ),
    );
  }

  /// [notches] wheel notches of [dy], [every] apart: a wheel spun.
  Future<void> spin(
    Offset at,
    double dy,
    int notches, {
    double dx = 0,
    Duration every = const Duration(milliseconds: 40),
  }) async {
    for (var i = 0; i < notches; i++) {
      wheel(at, dy, dx: dx);
      await Future<void>.delayed(every);
    }
  }

  /// Two fingers on a trackpad at [at], moving the content by [deltas]
  /// (one each [every], the macOS trackpad's 120Hz), then lifted: the
  /// views fling on from the last moves' speed.
  Future<void> swipe(
    Offset at,
    List<double> deltas, {
    Duration every = const Duration(microseconds: 8333),
  }) async {
    final pointer = ++_pointer;
    _send(
      PointerPanZoomStartEvent(
        viewId: _viewId,
        timeStamp: _now,
        device: _trackpad,
        pointer: pointer,
        position: at,
      ),
    );
    var pan = Offset.zero;
    for (final dy in deltas) {
      await Future<void>.delayed(every);
      pan += Offset(0, dy);
      PerfProbe.instance.mark(PerfMark.scroll);
      _send(
        PointerPanZoomUpdateEvent(
          viewId: _viewId,
          timeStamp: _now,
          device: _trackpad,
          pointer: pointer,
          position: at,
          pan: pan,
          panDelta: Offset(0, dy),
        ),
      );
    }
    _send(
      PointerPanZoomEndEvent(
        viewId: _viewId,
        timeStamp: _now,
        device: _trackpad,
        pointer: pointer,
        position: at,
      ),
    );
  }

  // --- Keys ------------------------------------------------------------------

  /// [event] where the engine's go: the hardware keyboard's handlers, then
  /// the focus tree (shortcuts, the focused widget's own handling), which
  /// has its keys from the key event manager, not from those handlers
  /// (deprecated, but how FocusManager still takes them).
  // ignore_for_file: deprecated_member_use
  bool _key(KeyEvent event) {
    final keyboard = HardwareKeyboard.instance.handleKeyEvent(event);
    final focus =
        ServicesBinding.instance.keyEventManager.keyMessageHandler?.call(
          KeyMessage([event], null),
        ) ??
        false;
    return keyboard || focus;
  }

  static PhysicalKeyboardKey _physicalFor(String character) {
    final unit = character.toLowerCase().codeUnitAt(0);
    if (unit >= 0x61 && unit <= 0x7a) {
      // USB HID usage page 7: a is 4.
      return PhysicalKeyboardKey(0x00070004 + unit - 0x61);
    }
    return switch (character) {
      ' ' => PhysicalKeyboardKey.space,
      '\n' => PhysicalKeyboardKey.enter,
      _ => PhysicalKeyboardKey.keyA,
    };
  }

  /// Presses [logical] (with the modifiers held), as a key not typing
  /// anything; what is not handled does what the platform would of the
  /// few keys [_unhandled] knows.
  void press(
    LogicalKeyboardKey logical, {
    PhysicalKeyboardKey? physical,
    bool meta = false,
    bool shift = false,
  }) {
    final key = physical ?? _physicalOf[logical] ?? PhysicalKeyboardKey.keyA;
    PerfProbe.instance.mark(PerfMark.key);
    final modifiers = [
      if (meta) (PhysicalKeyboardKey.metaLeft, LogicalKeyboardKey.metaLeft),
      if (shift) (PhysicalKeyboardKey.shiftLeft, LogicalKeyboardKey.shiftLeft),
    ];
    for (final (p, l) in modifiers) {
      _key(KeyDownEvent(physicalKey: p, logicalKey: l, timeStamp: _now));
    }
    final handled = _key(
      KeyDownEvent(physicalKey: key, logicalKey: logical, timeStamp: _now),
    );
    if (!handled && modifiers.isEmpty) _unhandled(logical);
    _key(KeyUpEvent(physicalKey: key, logicalKey: logical, timeStamp: _now));
    for (final (p, l) in modifiers.reversed) {
      _key(KeyUpEvent(physicalKey: p, logicalKey: l, timeStamp: _now));
    }
  }

  static final Map<LogicalKeyboardKey, PhysicalKeyboardKey> _physicalOf = {
    LogicalKeyboardKey.enter: PhysicalKeyboardKey.enter,
    LogicalKeyboardKey.backspace: PhysicalKeyboardKey.backspace,
    LogicalKeyboardKey.arrowUp: PhysicalKeyboardKey.arrowUp,
    LogicalKeyboardKey.arrowDown: PhysicalKeyboardKey.arrowDown,
    LogicalKeyboardKey.arrowLeft: PhysicalKeyboardKey.arrowLeft,
    LogicalKeyboardKey.arrowRight: PhysicalKeyboardKey.arrowRight,
    LogicalKeyboardKey.pageDown: PhysicalKeyboardKey.pageDown,
    LogicalKeyboardKey.pageUp: PhysicalKeyboardKey.pageUp,
    LogicalKeyboardKey.keyZ: PhysicalKeyboardKey.keyZ,
    LogicalKeyboardKey.keyA: PhysicalKeyboardKey.keyA,
    LogicalKeyboardKey.keyC: PhysicalKeyboardKey.keyC,
    LogicalKeyboardKey.escape: PhysicalKeyboardKey.escape,
    LogicalKeyboardKey.home: PhysicalKeyboardKey.home,
    LogicalKeyboardKey.end: PhysicalKeyboardKey.end,
  };

  void _unhandled(LogicalKeyboardKey key) {
    final value = _focusedClient()?.currentTextEditingValue;
    if (value == null || !value.selection.isValid) return;
    final selection = value.selection;
    if (key == LogicalKeyboardKey.enter) {
      _replace(value, '\n');
    } else if (key == LogicalKeyboardKey.backspace) {
      final start = selection.isCollapsed
          ? (selection.start - 1).clamp(0, value.text.length)
          : selection.start;
      TextInput.updateEditingValue(
        TextEditingValue(
          text: value.text.replaceRange(start, selection.end, ''),
          selection: TextSelection.collapsed(offset: start),
        ),
      );
    }
  }

  void _replace(TextEditingValue value, String text) {
    final selection = value.selection;
    TextInput.updateEditingValue(
      TextEditingValue(
        text: value.text.replaceRange(selection.start, selection.end, text),
        selection: TextSelection.collapsed(
          offset: selection.start + text.length,
        ),
      ),
    );
  }

  /// Types [character]: its key goes down; unless handled, the input
  /// method inserts it in the client attached (the focused editor); the key
  /// comes up.
  void typeCharacter(String character) {
    if (character == '\n') {
      press(LogicalKeyboardKey.enter);
      return;
    }
    final physical = _physicalFor(character);
    final logical = LogicalKeyboardKey(character.toLowerCase().codeUnitAt(0));
    PerfProbe.instance.mark(PerfMark.key);
    final handled = _key(
      KeyDownEvent(
        physicalKey: physical,
        logicalKey: logical,
        character: character,
        timeStamp: _now,
      ),
    );
    if (!handled) {
      if (_focusedClient()?.currentTextEditingValue case final value?
          when value.selection.isValid) {
        _replace(value, character);
      }
    }
    _key(
      KeyUpEvent(physicalKey: physical, logicalKey: logical, timeStamp: _now),
    );
  }

  /// [key] pressed [times] times, [every] apart: a key held down repeats
  /// every 33ms.
  Future<void> repeat(
    LogicalKeyboardKey key,
    int times, {
    bool shift = false,
    bool meta = false,
    Duration every = const Duration(milliseconds: 33),
  }) async {
    for (var i = 0; i < times; i++) {
      press(key, shift: shift, meta: meta);
      await Future<void>.delayed(every);
    }
  }

  /// Types [text], a character each [every]: 33ms is a key held down
  /// repeating, 80–120ms a fast typist.
  Future<void> type(
    String text, {
    Duration every = const Duration(milliseconds: 33),
  }) async {
    for (final rune in text.runes) {
      typeCharacter(String.fromCharCode(rune));
      await Future<void>.delayed(every);
    }
  }

  /// Whether a text input client is attached: something has focus to type
  /// into.
  bool get canType => _focusedClient() != null;
}

/// The next frame, scheduled if none is; or a second, when none comes
/// (the window out of sight).
Future<void> nextFrame() {
  final done = Completer<void>();
  SchedulerBinding.instance.addPostFrameCallback((_) {
    if (!done.isCompleted) done.complete();
  });
  SchedulerBinding.instance.scheduleFrame();
  return done.future.timeout(const Duration(seconds: 1), onTimeout: () {});
}
