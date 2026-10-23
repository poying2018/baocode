/// Where this build's world is: its repository, its releases, and the
/// pages it points the user at.
///
/// The upstream (baocode-dev/baocode) has a site of its own
/// (baocode.dev) and the services behind it: the browser extension's
/// store, the channel accounts, the telemetry and the diagnostics
/// upload. This fork has none of those — it publishes to its own
/// releases and keeps the user's data to itself — so every address here
/// is the fork's own, and the upstream's services are left alone.
library;

/// This build's own addresses.
abstract final class AppLinks {
  /// The repository this build is made in, and where a bug is told of.
  static final Uri repository = Uri.parse(
    'https://github.com/poying2018/baocode',
  );

  /// The releases: where an update is downloaded from, and what the
  /// about page offers as the place to get the app.
  static final Uri releases = repository.replace(
    path: '${repository.path}/releases',
  );

  /// The release's notes: what changed in each version.
  static final Uri changelog = releases;

  /// The repository's issues: where a problem is told of.
  static final Uri issues = repository.replace(
    path: '${repository.path}/issues',
  );

  /// The site of this repository, as the files in it are served: the
  /// channels' list, the featured upstreams.
  ///
  /// The files are in the repository (site/), and the worker that serves
  /// them upstream has no counterpart here, so they are read from the
  /// repository itself. The path ends in a slash, so a file's name
  /// resolves beside it rather than in place of the last part.
  static final Uri siteBase = Uri.parse(
    'https://raw.githubusercontent.com/poying2018/baocode/main/site/',
  );
}
