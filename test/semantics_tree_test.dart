import 'package:flutter_test/flutter_test.dart';

import 'semantics_tree.dart';

/// The desktop engines' tree, as the check every widget test runs models it.
void main() {
  test('takes a tree, and a node moved with all it holds', () {
    final tree = DesktopSemanticsTree();
    expect(
      tree.commit([
        (0, [1, 2]),
        (1, [3]),
        (2, []),
        (3, [4]),
        (4, []),
      ]),
      isNull,
    );
    // 3 moves from 1 to 2: the engine deletes it and 4 first, so both come
    // again, as the framework sends nodes it detached.
    expect(
      tree.commit([
        (1, []),
        (2, [3]),
        (3, [4]),
        (4, []),
      ]),
      isNull,
    );
  });

  test('a child it does not have may be another view\'s, its ids counted '
      'its own', () {
    final tree = DesktopSemanticsTree()
      ..commit([
        (0, [1]),
        (1, [2]),
        (2, []),
      ]);
    // 1 goes, and 2 with it; 1 comes back without 2. Another view's tree may
    // have a 2 of its own: the update is taken as that.
    expect(tree.commit([(0, [])]), isNull);
    expect(
      tree.commit([
        (0, [1]),
        (1, [2]),
      ]),
      isNull,
    );
  });

  test('a node without its parent is another view\'s root', () {
    final tree = DesktopSemanticsTree()
      ..commit([
        (0, [1]),
        (1, [2]),
        (2, []),
      ]);
    expect(tree.commit([(0, [])]), isNull);
    // 2's id is the other view's, whose root the update is.
    expect(tree.commit([(2, [])]), isNull);
  });

  test('a root named as a child is another view\'s root too', () {
    final tree = DesktopSemanticsTree()
      ..commit([
        (0, [1]),
        (1, []),
      ]);
    expect(
      tree.commit([
        (1, [0]),
      ]),
      isNull,
    );
  });
}
