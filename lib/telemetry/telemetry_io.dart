import 'dart:convert';
import 'dart:ffi' show Abi;
import 'dart:io';

import 'package:flutter/foundation.dart';

import '../update/version.dart';
import 'telemetry_service.dart';

/// Where to send the reports instead, to try a server: also turns them on
/// in a debug build.
const telemetryUrlVariable = 'BAOCODE_TELEMETRY_URL';

/// What the app reports with where it runs; null where it reports nothing:
/// a debug build (unless [telemetryUrlVariable] is set), and a release
/// build with no server of this build's own to report to.
PlatformTelemetry? platformTelemetry() {
  final environment = Platform.environment;
  final override = environment[telemetryUrlVariable]?.trim() ?? '';
  if (!kReleaseMode && override.isEmpty) return null;
  // This build has no server of its own to report to: the reports would
  // go to the upstream's, which is not this build's business. A server of
  // this build's own can be named in the environment.
  final url = Uri.tryParse(override);
  if (url == null) return null;
  final os = Platform.operatingSystem;
  final arch = abiArch(Abi.current());
  return PlatformTelemetry(
    url: url,
    os: os,
    arch: arch,
    sender: IoTelemetrySender(userAgent: 'BaoCode/$currentAppVersion ($os)'),
  );
}

/// `arm64`, `x64`, …: [abi]'s processor (`macos_arm64` → `arm64`).
String abiArch(Abi abi) => '$abi'.split('_').last;

/// What the app reports with ([platformTelemetry]).
class PlatformTelemetry {
  const PlatformTelemetry({
    required this.url,
    required this.os,
    required this.arch,
    required this.sender,
  });

  final Uri url;
  final String os;
  final String arch;
  final TelemetrySender sender;
}

/// A JSON POST over HTTPS.
class IoTelemetrySender implements TelemetrySender {
  IoTelemetrySender({
    this.userAgent = 'BaoCode',
    this.timeout = const Duration(seconds: 15),
    HttpClient Function()? client,
  }) : _client = client ?? HttpClient.new;

  final String userAgent;
  final Duration timeout;
  final HttpClient Function() _client;

  @override
  Future<int> send(Uri url, Map<String, Object?> body) async {
    final client = _client()
      ..connectionTimeout = timeout
      ..userAgent = userAgent;
    try {
      final request = await client.postUrl(url).timeout(timeout);
      request.headers.contentType = ContentType.json;
      request.add(utf8.encode(jsonEncode(body)));
      final response = await request.close().timeout(timeout);
      await response.drain<void>().timeout(timeout);
      return response.statusCode;
    } finally {
      client.close(force: true);
    }
  }
}
