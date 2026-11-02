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

  // Windows 与 Android 版本号必须完全对齐（用户要求：方便管理）
  group('Windows exe 版本号与 Android 一致', () {
    final header = File('windows/runner/version.h').readAsStringSync();
    String define(String key) =>
        RegExp('^#define $key (.+)\$', multiLine: true)
            .firstMatch(header)!
            .group(1)!
            .trim();
    final parts = name.split('.').map(int.parse).toList();

    test('APP_VERSION_MAJOR/MINOR/PATCH 与 pubspec 一致', () {
      expect(define('APP_VERSION_MAJOR'), '${parts[0]}');
      expect(define('APP_VERSION_MINOR'), '${parts[1]}');
      expect(define('APP_VERSION_PATCH'), '${parts[2]}');
    });

    test('APP_VERSION_BUILD 等于 Android versionCode', () {
      expect(define('APP_VERSION_BUILD'), '$code');
    });

    test('APP_VERSION_STRING 是 MAJOR.MINOR.PATCH.CODE', () {
      expect(define('APP_VERSION_STRING'), '"$name.$code"');
    });

    test('Runner.rc 引用 version.h 而不是 FLUTTER_VERSION 宏', () {
      final rc = File('windows/runner/Runner.rc').readAsStringSync();
      expect(rc.contains('#include "version.h"'), isTrue);
      expect(rc.contains('APP_VERSION_STRING'), isTrue);
      // 精确断言：不能再用宏拼版本字符串（那个是 "1.0.22+10022"，带 + 后缀）
      expect(
        RegExp(r'#define\s+VERSION_AS_STRING\s+FLUTTER_VERSION').hasMatch(rc),
        isFalse,
      );
      expect(
        RegExp(r'#define\s+VERSION_AS_NUMBER\s+FLUTTER_VERSION').hasMatch(rc),
        isFalse,
      );
    });
  });
}
