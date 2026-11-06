import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:baocode/network/proxy_settings.dart';
import 'package:baocode/network/windows_internet_settings.dart';

/// What a proxy is compared by: its address and whether it has credentials.
(Object?, Object?) _address(ProxyServer? server) =>
    server == null ? (null, null) : ('${server.host}:${server.port}', server.username != null);

void main() {
  group("Windows' Internet Settings, at the values themselves", () {
    test('on: one server for both schemes, its overrides', () {
      final route = windowsInternetSettingsRoute(
        enabled: true,
        server: '127.0.0.1:7890',
        override: 'localhost;127.*;<local>',
        autoConfigUrl: '',
      );
      expect(route.source, ProxySource.system);
      expect(_address(route.http), ('127.0.0.1:7890', false));
      expect(_address(route.https), ('127.0.0.1:7890', false));
      expect(route.bypass, containsAll(['localhost', '127.*']));
      expect(route.bypassSimpleHostnames, isTrue, reason: '<local>');
      expect(route.autoConfig, isFalse);
    });

    test('per scheme: each its own', () {
      final route = windowsInternetSettingsRoute(
        enabled: true,
        server: 'http=127.0.0.1:8080;https=127.0.0.1:8443',
        override: '',
        autoConfigUrl: '',
      );
      expect(_address(route.http), ('127.0.0.1:8080', false));
      expect(_address(route.https), ('127.0.0.1:8443', false));
      expect(route.bypass, isEmpty);
      expect(route.bypassSimpleHostnames, isFalse);
    });

    test('off: straight to the internet, whatever the server says', () {
      final route = windowsInternetSettingsRoute(
        enabled: false,
        server: '127.0.0.1:7890',
        override: 'localhost',
        autoConfigUrl: '',
      );
      expect(route.http, isNull);
      expect(route.https, isNull);
      expect(route.source, ProxySource.none);
      expect(route.autoConfig, isFalse);
    });

    test('a PAC file alone: said, not followed', () {
      final route = windowsInternetSettingsRoute(
        enabled: false,
        server: '',
        override: '',
        autoConfigUrl: 'http://wpad.example/wpad.dat',
      );
      expect(route.http, isNull);
      expect(route.source, ProxySource.none);
      expect(route.autoConfig, isTrue);
    });
  });

  // The read itself: the registry through advapi32, against reg.exe's own
  // answer for the same key. Windows only, and skipped where there is no
  // reg.exe to hold it to.
  test('the registry read agrees with reg.exe', () async {
    final result = await Process.run('reg.exe', const [
      'query',
      r'HKCU\Software\Microsoft\Windows\CurrentVersion\Internet Settings',
    ]);
    expect(result.exitCode, 0, reason: '${result.stderr}');
    final fromReg = parseWindowsInternetSettings('${result.stdout}');
    final fromRegistry = readWindowsInternetSettings();
    expect(_address(fromRegistry.http), _address(fromReg.http));
    expect(_address(fromRegistry.https), _address(fromReg.https));
    expect(fromRegistry.bypass, fromReg.bypass);
    expect(fromRegistry.bypassSimpleHostnames, fromReg.bypassSimpleHostnames);
    expect(fromRegistry.autoConfig, fromReg.autoConfig);
  }, skip: Platform.isWindows ? false : 'reg.exe is Windows only');
}
