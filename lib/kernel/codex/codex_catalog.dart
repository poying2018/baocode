import '../agent_kernel.dart';
import 'codex_transport.dart';

/// The conversations Codex has kept, as its server lists them.
///
/// The server keeps them in its own folder (`~/.codex`, or the app's own
/// when the Desktop app holds the user's), and knows them by thread id.
class CodexCatalog implements SessionCatalog {
  const CodexCatalog({required this.transport});

  /// The transport the server is reached over. The server is started for
  /// the first question, so the catalog needs one it can start.
  final CodexTransport transport;

  @override
  Future<List<ProjectRecord>> projects() async {
    final threads = await _threads();
    if (threads.isEmpty) return const [];
    // By the directory they ran in, the newest first.
    final byCwd = <String, List<SessionRecord>>{};
    for (final thread in threads) {
      final cwd = thread['cwd'];
      if (cwd is! String || cwd.isEmpty) continue;
      (byCwd[cwd] ??= []).add(_record(thread));
    }
    final projects = <ProjectRecord>[];
    for (final entry in byCwd.entries) {
      final sessions = entry.value
        ..sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
      projects.add(ProjectRecord(path: entry.key, sessions: sessions));
    }
    projects.sort((a, b) {
      final at = a.updatedAt;
      final bt = b.updatedAt;
      if (at == null || bt == null) return (bt == null ? 1 : 0);
      return bt.compareTo(at);
    });
    return projects;
  }

  @override
  Future<List<SessionRecord>> sessionsIn(String cwd) async {
    final threads = await _threads(cwd: cwd);
    final sessions = [
      for (final thread in threads)
        if (thread['cwd'] == cwd) _record(thread),
    ];
    sessions.sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
    return sessions;
  }

  @override
  Future<void> delete(String id) async {
    await transport.request('thread/delete', {'threadId': id});
  }

  /// The threads the server has, newest first.
  Future<List<Map<String, Object?>>> _threads({String? cwd}) async {
    final answer = await transport.request('thread/list', {
      'cwd': ?cwd,
      'limit': 200,
      'sortKey': 'updatedAt',
      'sortDirection': 'desc',
    });
    final data = answer['data'];
    if (data is! List) return const [];
    return [
      for (final raw in data)
        if (raw is Map) raw.cast<String, Object?>(),
    ];
  }

  /// The thread as a session of the conversation: its title is what it
  /// was named, or the first thing said in it.
  SessionRecord _record(Map<String, Object?> thread) {
    final id = thread['id'];
    final cwd = thread['cwd'];
    final name = thread['name'];
    final preview = thread['preview'];
    final updated = thread['updatedAt'];
    return SessionRecord(
      id: id is String ? id : '',
      title: switch (name) {
        final String name when name.isNotEmpty => name,
        _ => preview is String ? preview : '',
      },
      updatedAt: DateTime.fromMillisecondsSinceEpoch(
        updated is int ? updated * 1000 : 0,
      ),
      cwd: cwd is String ? cwd : '',
    );
  }
}
