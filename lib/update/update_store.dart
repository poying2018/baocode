import 'dart:async';

import 'package:flutter/foundation.dart';

import '../settings/user_settings.dart';
import 'update_service.dart';

/// What the updates keep across runs, in the app's global storage
/// (state/storage.json): the version the user skipped, when the app last
/// looked, the version an install was started for as it quit, and the
/// newest version this installation has run or installed.
class GlobalUpdateStore implements UpdateStore {
  GlobalUpdateStore(this.storage);

  final GlobalStorage storage;

  static const skippedKey = 'update.skippedVersion';
  static const lastCheckedKey = 'update.lastChecked';
  static const installingKey = 'update.installingVersion';
  static const highWaterKey = 'update.highWaterVersion';

  @override
  String? get skippedVersion => storage.get<String>(skippedKey);

  @override
  set skippedVersion(String? version) => _set(skippedKey, version);

  @override
  DateTime? get lastChecked => switch (storage.get<String>(lastCheckedKey)) {
    final text? => DateTime.tryParse(text)?.toLocal(),
    null => null,
  };

  @override
  set lastChecked(DateTime? time) =>
      _set(lastCheckedKey, time?.toUtc().toIso8601String());

  @override
  String? get installingVersion => storage.get<String>(installingKey);

  @override
  Future<void> setInstallingVersion(String? version) =>
      storage.set(installingKey, version);

  @override
  String? get highWaterVersion => storage.get<String>(highWaterKey);

  @override
  set highWaterVersion(String? version) => _set(highWaterKey, version);

  void _set(String key, Object? value) => unawaited(
    storage.set(key, value).catchError((Object error) {
      debugPrint('$key not kept: $error');
    }),
  );
}
