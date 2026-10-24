import 'dart:io';

/// Ends the process [pid] and every process it started, as a program's
/// children go on when only it is killed.
///
/// [force] ends them at once, without asking first; [windows] says how
/// the machine ends a tree (where this runs, when not given).
Future<void> killTree(int pid, {bool force = false, bool? windows}) async {
  if (windows ?? Platform.isWindows) {
    try {
      await Process.run('taskkill', ['/T', '/F', '/PID', '$pid']);
    } on ProcessException {
      // No taskkill on this machine: the process alone goes.
      try {
        Process.killPid(pid, force ? ProcessSignal.sigkill : ProcessSignal.sigterm);
      } on Object {
        // It is already gone.
      }
    }
    return;
  }
  final tree = <int>[pid, ...await _descendants(pid)];
  final signal = force ? ProcessSignal.sigkill : ProcessSignal.sigterm;
  // The children first, so none is left orphaned to go on.
  for (final id in tree.reversed) {
    Process.killPid(id, signal);
  }
  if (force) return;
  // What does not end on being asked is made to.
  Future<void>.delayed(const Duration(seconds: 2), () {
    for (final id in tree) {
      Process.killPid(id, ProcessSignal.sigkill);
    }
  });
}

/// The processes [pid] started, and what they started.
Future<List<int>> _descendants(int pid) async {
  try {
    final result = await Process.run('ps', ['-A', '-o', 'pid=,ppid=']);
    final children = <int, List<int>>{};
    for (final line in '${result.stdout}'.split('\n')) {
      final parts = line.trim().split(RegExp(r'\s+'));
      if (parts.length != 2) continue;
      final child = int.tryParse(parts[0]);
      final parent = int.tryParse(parts[1]);
      if (child == null || parent == null) continue;
      (children[parent] ??= []).add(child);
    }
    final out = <int>[];
    final pending = [pid];
    while (pending.isNotEmpty) {
      final next = pending.removeLast();
      for (final child in children[next] ?? const <int>[]) {
        if (out.contains(child)) continue;
        out.add(child);
        pending.add(child);
      }
    }
    return out;
  } on ProcessException {
    return const [];
  }
}
