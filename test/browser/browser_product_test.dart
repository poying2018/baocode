@TestOn('mac-os || linux || windows')
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:baocode/browser/browser_bridge.dart';
import 'package:baocode/platform/app_paths.dart';

/// The two products (BaoCode Claude, the Claude Code one, and the codex
/// one) keep apart: their data, their discovery files and
/// their names.
void main() {
  test('the product is said by the program\'s own name', () {
    expect(AppPaths.product('baocode-claude.exe'), 'baocode');
    expect(AppPaths.product('baocode-codex.exe'), 'baocode-codex');
    // A name of no product (a test host) is the Claude Code one's.
    expect(AppPaths.product('flutter_tester.exe'), 'baocode');
    expect(AppPaths.product('baocode-codex-codex.exe'), 'baocode-codex-codex');
  });

  test('the two products\' names are told apart', () {
    expect(
      AppPaths.displayName(const {}, executable: 'baocode-claude.exe'),
      'BaoCode Claude',
    );
    expect(
      AppPaths.displayName(const {}, executable: 'baocode-codex.exe'),
      'BaoCode Codex',
    );
  });

  test('the browser bridge\'s files are the product\'s own', () {
    // The port and lock files: each product has its own, so that one does
    // not take the browsers from the other.
    expect(BrowserBridge.portPathFor('baocode'), 'baocode-browser.port');
    expect(
      BrowserBridge.portPathFor('baocode-codex'),
      'baocode-codex-browser.port',
    );
    expect(
      BrowserBridge.portPathFor('baocode'),
      isNot(BrowserBridge.portPathFor('baocode-codex')),
    );
  });

  test('Windows discovery does not depend on the temporary directory', () {
    expect(
      BrowserBridge.windowsDiscoveryFolder(
        environment: const {
          'TEMP': r'C:\WINDOWS\TEMP',
          'TMP': r'C:\WINDOWS\TEMP',
        },
        localAppData: r'C:\Users\me\AppData\Local',
      ),
      r'C:\Users\me\AppData\Local\baocode-browser',
    );
    expect(
      BrowserBridge.windowsDiscoveryFolder(
        environment: const {
          'TEMP': r'E:\Temp',
          'TMP': r'E:\Temp',
          'BAOCODE_BROWSER_DISCOVERY_DIR': r'F:\discovery',
        },
        localAppData: r'C:\Users\me\AppData\Local',
      ),
      r'F:\discovery',
    );
    expect(
      BrowserBridge.windowsDiscoveryFolder(
        environment: const {
          'TEMP': r'C:\WINDOWS\TEMP',
          'TMP': r'C:\WINDOWS\TEMP',
          'LOCALAPPDATA': r'C:\Users\me\AppData\Local',
        },
      ),
      r'C:\Users\me\AppData\Local\baocode-browser',
    );
    expect(
      () => BrowserBridge.windowsDiscoveryFolder(
        environment: const {
          'TEMP': r'C:\WINDOWS\TEMP',
          'TMP': r'C:\WINDOWS\TEMP',
        },
      ),
      throwsA(isA<BrowserBridgeUnsupported>()),
    );
  });
}
