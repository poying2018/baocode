import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:bao_remote/client.dart';
import 'package:baocode/remote/remote_codex.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'the remote app-server is initialized and asked over its stdio',
    () async {
      final process = _FakeRemoteProcess();
      final transport = await RemoteCodexTransport.start(process);

      expect(process.written.first['method'], 'initialize');
      expect((process.written.first['params'] as Map)['capabilities'], {
        'experimentalApi': true,
      });
      expect(process.written[1], {'method': 'initialized'});

      final answer = await transport.request('model/list');
      expect((answer['data'] as List).single, {'id': 'gpt-test'});

      transport.close();
      await transport.exited;
      expect(process.killed, isTrue);
    },
  );
}

class _FakeRemoteProcess implements RemoteProcess {
  final StreamController<List<int>> _stdout = StreamController();
  final StreamController<List<int>> _stderr = StreamController();
  final Completer<int> _exitCode = Completer();
  final List<Map<String, Object?>> written = [];
  bool killed = false;

  @override
  int get pid => 41;

  @override
  Stream<List<int>> get stdout => _stdout.stream;

  @override
  Stream<List<int>> get stderr => _stderr.stream;

  @override
  Future<int> get exitCode => _exitCode.future;

  void _reply(Map<String, Object?> message) {
    _stdout.add(Uint8List.fromList(utf8.encode('${jsonEncode(message)}\n')));
  }

  @override
  void write(List<int> bytes) {
    final message = (jsonDecode(utf8.decode(bytes)) as Map)
        .cast<String, Object?>();
    written.add(message);
    switch (message['method']) {
      case 'initialize':
        _reply({
          'id': message['id'],
          'result': {'codexHome': '/home/user/.codex'},
        });
      case 'model/list':
        _reply({
          'id': message['id'],
          'result': {
            'data': [
              {'id': 'gpt-test'},
            ],
          },
        });
    }
  }

  @override
  Future<void> closeStdin() async {}

  @override
  void kill({bool force = false}) {
    if (killed) return;
    killed = true;
    unawaited(_stdout.close());
    unawaited(_stderr.close());
    _exitCode.complete(0);
  }
}
