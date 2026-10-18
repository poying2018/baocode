import 'dart:io';
import 'dart:typed_data';

import 'package:path/path.dart' as p;

import '../ide/lsp/install/install_io.dart' show HttpDownloader;
import '../platform/data_dir.dart';
import 'emoji_sheet.dart';

/// [DataDirectory.cacheDir]'s `emoji/<version>`.
class CacheEmojiSheetStore implements EmojiSheetStore {
  String get _dir =>
      p.join(DataDirectory.current.cacheDir, 'emoji', EmojiSheet.version);

  File _file(String name) => File(p.join(_dir, p.basename(name)));

  @override
  Future<bool> has(String name) => _file(name).exists();

  @override
  Future<Uint8List?> read(String name) async {
    try {
      return await _file(name).readAsBytes();
    } on Object {
      return null;
    }
  }

  /// Into a temporary file, renamed once whole.
  @override
  Future<void> download(Uri url, String name) async {
    await Directory(_dir).create(recursive: true);
    // Other versions' sheets, the Google set alone as kept before the
    // others were among them: their catalog is not this one's, and 45 MB
    // apiece is worth taking out.
    final root = Directory(
      p.join(DataDirectory.current.cacheDir, 'emoji'),
    );
    try {
      await for (final entry in root.list(followLinks: false)) {
        if (entry is Directory &&
            p.basename(entry.path) != EmojiSheet.version) {
          await entry.delete(recursive: true);
        }
      }
    } on Object {
      // Nothing there yet.
    }
    await HttpDownloader().download(url, _file(name).path);
  }

  @override
  Future<void> delete(String name) async {
    try {
      await _file(name).delete();
    } on Object {
      // Gone already.
    }
  }
}
