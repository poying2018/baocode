/// The products this app is built as: BaoCode Claude (the Claude Code one)
/// and BaoCode Codex (the codex one). They are separate programs that
/// happen to come from one source tree: each keeps its data, its windows,
/// its registration, its update channel and its links to itself apart, so
/// that neither disturbs the other.
///
/// The product is said by the name of the executable the build produced
/// (`baocode-claude.exe`, `baocode-codex.exe`) — one fact, from which
/// everything else follows. The native side reads the same name
/// (windows/runner/app_identity.cpp), so the two cannot disagree about
/// which product this is.
///
/// What does not change with the names: the install (its id and its
/// folder), the data folder, the update channel, the links and the
/// keychain. A release of a renamed product is an upgrade of the one
/// before it, not a new program beside it.
///
/// This table is where the rest of that follows from: one place that says
/// what each product's identity is, instead of a rule per place.
library;

/// One product: what tells it apart from the other.
class Product {
  const Product({
    required this.id,
    required this.binary,
    required this.displayName,
    required this.scheme,
    required this.appId,
    required this.registryKey,
    required this.manifestName,
    required this.installerName,
    required this.directoryName,
    required this.browserHost,
    required this.browserManifest,
    required this.keychainService,
    required this.hasClaudeCode,
  });

  /// BaoCode Claude: the Claude Code one. Its identity is the one it
  /// always had: the same install, the same data folder, the same update
  /// channel, so that this release is an upgrade of it and not a new
  /// program beside it. Only its names are new.
  static const baocode = Product(
    id: 'baocode',
    binary: 'baocode-claude',
    displayName: 'BaoCode Claude',
    scheme: 'baocode',
    appId: '{6fdd732b-95c6-4c37-af6f-ff574358deb5}',
    registryKey: r'Software\BaoCode',
    manifestName: 'latest.json',
    installerName: 'BaoCodeClaude',
    directoryName: 'BaoCode',
    browserHost: 'dev.baocode.browser',
    browserManifest: 'dev.baocode.browser.json',
    keychainService: 'BaoCode',
    hasClaudeCode: true,
  );

  /// BaoCode Codex: the codex one. It has no Claude Code to carry, and
  /// says nothing of it.
  static const codex = Product(
    id: 'baocode-codex',
    binary: 'baocode-codex',
    displayName: 'BaoCode Codex',
    scheme: 'baocode-codex',
    appId: '{3c9e2b14-7f56-4d1a-9b2e-6d5f8a71c40}',
    registryKey: r'Software\BaoCodeCodex',
    manifestName: 'latest-codex.json',
    installerName: 'BaoCodeCodex',
    directoryName: 'BaoCodeCodex',
    browserHost: 'dev.baocode-codex.browser',
    browserManifest: 'dev.baocode-codex.browser.json',
    keychainService: 'BaoCode Codex',
    hasClaudeCode: false,
  );

  /// Every product, in the order they are named.
  static const all = [baocode, codex];

  /// The product's id: "baocode" or "baocode-codex". It names the data
  /// folder and the manifest, and is what the release manifest carries.
  final String id;

  /// The name of the executable this product is built as, without its
  /// folder or its extension: the Flutter tool reads it from
  /// windows/CMakeLists.txt, and the native side reads it back from the
  /// running program.
  final String binary;

  /// The name the app shows itself as: "BaoCode", "BaoCode Codex".
  final String displayName;

  /// The URL scheme the installer registers for it: a link
  /// (`baocode://provider/import`) opens this product and no other.
  final String scheme;

  /// The identity Windows keeps for the installed app (the installer's
  /// AppId). It never changes between versions — an upgrade installs over
  /// the old one — and differs between the products, so that one does not
  /// install over the other.
  final String appId;

  /// Where Windows keeps this product's own settings (the window's frame,
  /// the folder the logs go in).
  final String registryKey;

  /// The name of the update manifest published for it, in the release.
  final String manifestName;

  /// The installer's file name, without the version and the edition: the
  /// release's assets are named after it, and they must not have a space in
  /// them.
  final String installerName;

  /// The folder the program is installed in, under Program Files or beside
  /// the user's own programs. It does not change between versions: an
  /// upgrade installs over the one before it, in the same folder.
  final String directoryName;

  /// The name the browsers know the app's native messaging host by: each
  /// product's own, so that the two do not take each other's away.
  final String browserHost;

  /// The file the browsers find that host by.
  final String browserManifest;

  /// The name the OS keychain keeps this product's secrets under: each
  /// product's own, so that re-keying in one does not touch the other.
  final String keychainService;

  /// Whether this product carries Claude Code.
  final bool hasClaudeCode;

  /// The product [id] names, or null when it names none. The ids are
  /// "baocode" and "baocode-codex"; "baocode-claude" and "claude" name
  /// the first one too, as the build scripts and the release manifest say
  /// it, and "codex" the second, as they have always said it.
  static Product? byId(String id) {
    final name = id.trim().toLowerCase();
    for (final product in all) {
      if (product.id == name) return product;
    }
    return switch (name) {
      'codex' => codex,
      'baocode-claude' || 'claude' => baocode,
      _ => null,
    };
  }

  /// The product an executable of that name is: the name says it
  /// ("baocode-claude.exe" is the Claude Code one, "baocode-codex.exe" the
  /// codex one). A name belonging to no product (a test host, a build named
  /// otherwise) is the Claude Code one's.
  static Product byExecutable(String executable) {
    final name = executable
        .split(RegExp(r'[/\\]'))
        .last
        .replaceFirst(RegExp(r'\.[^.]*$'), '')
        .toLowerCase();
    if (!name.startsWith('baocode')) return baocode;
    // The name is the product's, with no space in it: "baocode-claude" or
    // "baocode-codex". A name with a space in it (macOS's ".app" folder)
    // belongs to no product.
    if (name.contains(' ')) return baocode;
    return byId(name) ?? baocode;
  }
}
