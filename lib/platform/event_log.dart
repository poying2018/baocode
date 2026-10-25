import 'dart:io';

import 'package:path/path.dart' as p;

import '../l10n/l10n.dart';
import '../update/version.dart';

/// What the app went through, one line each, in `logs/events.log`
/// (`DataDirectory.logsDir`), beside [ErrorLog]'s errors.log: its windows
/// and views, coming to the front and going, the color theme, the stash's
/// panel. A release build fails silently at times — a window that draws
/// nothing, with no error — and what led to it is then read here, in the
/// diagnostics a user uploads (Settings → Updates).
///
/// Only what happened, never what the user wrote: no text, no titles.
///
/// A run's first line names the app's version and the system. Past
/// [maxBytes], the file becomes `events.1.log` and a new one starts, so the
/// latest events are always kept.
class EventLog {
  EventLog(
    this.directory, {
    this.maxBytes = 1024 * 1024,
    DateTime Function()? clock,
  }) : _clock = clock ?? DateTime.now;

  /// The app's, once `main` has made it; none under test.
  static EventLog? current;

  /// The folder of the log files.
  final String directory;

  final int maxBytes;

  final DateTime Function() _clock;

  String get path => p.join(directory, 'events.log');

  /// The file before it, moved aside.
  String get previousPath => p.join(directory, 'events.1.log');

  bool _started = false;
  int _size = 0;

  /// What is written, one write after another, off the thread that draws:
  /// a write to the disk takes milliseconds here, and the events come in
  /// bursts (a window dragged, views laid out).
  Future<void> _writing = Future.value();

  /// Writes [message] under [category] (`window`, `theme`…), timed.
  void record(String category, String message) {
    try {
      _write('${_clock().toIso8601String()} [$category] $message\n');
    } catch (_) {
      // The log is no reason to fail: a disk full, a folder gone.
    }
  }

  /// What has been written, once it is: a test reading the file, or the
  /// last events before the app goes.
  Future<void> flush() => _writing;

  void _write(String line) {
    if (!_started) {
      _started = true;
      Directory(directory).createSync(recursive: true);
      final file = File(path);
      _size = file.existsSync() ? file.lengthSync() : 0;
      _rollIfFull(0);
      _append(
        '--- $productName $appVersionString · ${Platform.operatingSystem} '
        '${Platform.operatingSystemVersion} · pid $pid ---\n',
      );
    }
    _rollIfFull(line.length);
    _append(line);
  }

  void _rollIfFull(int adding) {
    if (_size == 0 || _size + adding <= maxBytes) return;
    _size = 0;
    _writing = _writing.then<void>((_) async {
      final previous = File(previousPath);
      if (await previous.exists()) await previous.delete();
      await File(path).rename(previousPath);
    }).catchError((Object _) {
      // A folder gone, a file in use: the next events start a new file.
    });
  }

  void _append(String text) {
    // No flush: each one is a flush to the disk. What is written is there
    // for a reader at once; only a power cut before the system writes it
    // out loses it.
    _size += text.length;
    _writing = _writing.then<void>((_) async {
      await File(path).writeAsString(text, mode: FileMode.append);
    }).catchError((Object _) {
      // The log is no reason to fail.
    });
  }
}

/// Writes [message] to [EventLog.current], if there is one.
void appEvent(String category, String message) =>
    EventLog.current?.record(category, message);
