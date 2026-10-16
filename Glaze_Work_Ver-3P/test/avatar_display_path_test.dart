import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:glaze_flutter/core/utils/platform_paths.dart';
import 'package:path/path.dart' as p;

void main() {
  late Directory root;

  setUp(() {
    root = Directory.systemTemp.createTempSync('glaze_avatar_test_');
    Directory(p.join(root.path, 'avatars')).createSync(recursive: true);
    Directory(p.join(root.path, 'thumbnails')).createSync(recursive: true);
  });

  tearDown(() {
    if (root.existsSync()) root.deleteSync(recursive: true);
  });

  test('existing avatar is returned untouched', () {
    final f = File(p.join(root.path, 'avatars', 'a.png'))
      ..writeAsBytesSync([1, 2, 3]);
    expect(resolveGlazeDisplayPath(f.path), f.path);
  });

  test('missing avatar falls back to same id with another extension', () {
    final jpg = File(p.join(root.path, 'avatars', 'a.jpg'))
      ..writeAsBytesSync([1, 2, 3]);
    final missing = p.join(root.path, 'avatars', 'a.png');
    expect(resolveGlazeDisplayPath(missing), jpg.path);
  });

  test('missing avatar is restored from its thumbnail', () {
    File(p.join(root.path, 'thumbnails', 'b.jpg')).writeAsBytesSync([9, 9, 9]);
    final avatar = p.join(root.path, 'avatars', 'b.png');
    final resolved = resolveGlazeDisplayPath(avatar);
    expect(resolved, avatar);
    expect(File(avatar).readAsBytesSync(), [9, 9, 9]);
  });

  test('nothing recoverable returns the plain path', () {
    final missing = p.join(root.path, 'avatars', 'zzz.png');
    expect(resolveGlazeDisplayPath(missing), missing);
    expect(resolveGlazeDisplayPath(null), isNull);
    expect(resolveGlazeDisplayPath(''), '');
  });
}
