import 'package:path/path.dart' as p;

/// How a path is spelled: this machine's way, or POSIX's.
///
/// A path that starts at the root the POSIX way (`/p/lib/a.dart`) is POSIX
/// wherever it is read: on Windows, where the machine's own root is
/// `C:\`, such a path is not absolute at all, and joining it with the
/// machine's way would spell it `\p\lib\a.dart` — a path that names
/// nothing. Paths that come from a remote host, or that a test writes
/// with a POSIX root, keep the POSIX spelling.
abstract final class PathStyle {
  /// The style [path] is written in: POSIX's when it starts at the POSIX
  /// root and this machine's own root is not it, the machine's otherwise.
  static p.Context of(String path) {
    if (_posixRooted(path)) {
      return p.posix;
    }
    return p.context;
  }

  /// Whether [path] starts at the POSIX root (`/p/lib/a.dart`) rather than
  /// at this machine's own root: on Windows, where the machine's root is
  /// `C:\`, such a path is not absolute at all, and reading it the
  /// machine's way would spell it `\p\lib\a.dart` — a path that names
  /// nothing.
  static bool _posixRooted(String path) {
    if (!path.startsWith('/')) return false;
    // A UNC path (`//server/share`) is the machine's own.
    if (path.startsWith('//')) return false;
    // A drive's root (`C:/…`) is the machine's own too.
    if (path.length > 1 && path[1] == ':') return false;
    return true;
  }

  /// [path] in the style it is written in: the POSIX root kept, the
  /// machine's own otherwise.
  static String normalize(String path) => of(path).normalize(path);

  /// [path] in [root]'s folder, in the style [root] is written in: a
  /// relative path joined to it, an absolute one left as it is.
  static String join(String root, String path) {
    final paths = of(root);
    if (paths.isAbsolute(path)) return paths.normalize(path);
    return paths.normalize(paths.join(root, path));
  }

  /// Whether [path] is inside [root], in the style [root] is written in.
  static bool isWithin(String root, String path) {
    final paths = of(root);
    return paths.isWithin(root, paths.normalize(path));
  }
}
