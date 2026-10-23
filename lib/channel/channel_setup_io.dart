import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import '../platform/app_links.dart';
import '../update/version.dart';
import 'channel_setup.dart';

const _timeout = Duration(seconds: 8);

/// Asks the stats server what it kept for an install: 200 with it, 404
/// while none.
Future<ChannelAttribution?> lookUpChannel(Uri url) async {
  final body = await _get(url);
  if (body == null) return null;
  final told = ChannelAttribution.fromJson(jsonDecode(utf8.decode(body)));
  if (told == null) throw FormatException('not an attribution');
  return told;
}

/// Where the channels the site lists are read from instead (`…/channels.json`
/// and their logos), to try a channel's welcome before the site has it:
/// `site/` served locally, say.
const channelsUrlVariable = 'BAOCODE_CHANNELS_URL';

/// The site's: this repository's own, as the files in it are in the
/// repository (site/).
final channelsBase = AppLinks.siteBase;

/// The channel [id]'s entry as the site lists it (site/channels.json),
/// its logo with it; null for one not listed. Throws when the site could
/// not be read.
Future<ChannelEntry?> channelEntry(String id) async {
  final override = Platform.environment[channelsUrlVariable]?.trim() ?? '';
  final base = override.isEmpty ? channelsBase : Uri.parse(override);
  // The site's own base carries the folder the files are in, so the list
  // is beside it; one named in the environment is a server's root.
  final body = await _get(
    base.resolve(override.isEmpty ? 'channels.json' : '/channels.json'),
  );
  if (body == null) return null;
  final json = switch (jsonDecode(utf8.decode(body))) {
    final Map<String, Object?> channels => channels[id],
    _ => throw const FormatException('not a list of channels'),
  };
  if (json == null) return null;
  Uint8List? logo;
  if (ChannelInfo.parse(json, 'en')?.logo case final path?) {
    try {
      logo = await _get(base.resolve(path));
    } on Object {
      // Without it, then.
    }
  }
  return (id: id, json: json, logo: logo);
}

/// [url]'s body; null on a 404. Throws on anything else.
Future<Uint8List?> _get(Uri url) async {
  final client = HttpClient()
    ..connectionTimeout = _timeout
    ..userAgent = 'BaoCode/$currentAppVersion (${Platform.operatingSystem})';
  try {
    final request = await client.getUrl(url).timeout(_timeout);
    final response = await request.close().timeout(_timeout);
    final builder = BytesBuilder(copy: false);
    await response.forEach(builder.add).timeout(_timeout);
    if (response.statusCode == HttpStatus.notFound) return null;
    if (response.statusCode != HttpStatus.ok) {
      throw HttpException('HTTP ${response.statusCode}', uri: url);
    }
    return builder.takeBytes();
  } finally {
    client.close(force: true);
  }
}
