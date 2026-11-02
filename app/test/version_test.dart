import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:todo_app/ui/settings_dialog.dart' show kAppVersion;

/// 版本号规范的机器校验：手改版本很容易漏掉某一处或写错 versionCode，
/// 这两条一旦挂掉，CI/本地测试会立刻拦住。
void main() {
  final raw = RegExp(r'^version:\s*(\S+)$', multiLine: true)
      .firstMatch(File('pubspec.yaml').readAsStringSync())!
      .group(1)!;
  final seg = raw.split('+');
  final name = seg.first;
  final code = int.parse(seg.last);

  test('kAppVersion 与 pubspec 的 versionName 一致', () {
    expect(kAppVersion, name, reason: '改版本请用 dart run tool/bump_version.dart');
  });

  test('versionName 是 MAJOR.MINOR.PATCH', () {
    expect(RegExp(r'^\d+\.\d+\.\d+$').hasMatch(name), isTrue, reason: '实际: $name');
  });

  test('versionCode = MAJOR*10000 + MINOR*100 + PATCH', () {
    final p = name.split('.').map(int.parse).toList();
    expect(p[1], lessThan(100), reason: 'MINOR 必须 < 100');
    expect(p[2], lessThan(100), reason: 'PATCH 必须 < 100');
    expect(code, p[0] * 10000 + p[1] * 100 + p[2], reason: '实际: $name+$code');
  });
}
