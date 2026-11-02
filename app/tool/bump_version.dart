// 版本号唯一维护入口：改版本只跑这一条命令，别手改两处。
//
//   dart run tool/bump_version.dart 1.0.22      # 指定版本
//   dart run tool/bump_version.dart patch       # 按当前版本 +1（patch/minor/major）
//
// 规则：
//   versionName = MAJOR.MINOR.PATCH（语义化）
//   versionCode = MAJOR*10000 + MINOR*100 + PATCH（单调递增、人类可读）
//
// 会同步改写：
//   pubspec.yaml            version: X.Y.Z+code
//   lib/ui/settings_dialog.dart  const kAppVersion = 'X.Y.Z';
// 并由 test/version_test.dart 兜底校验两处一致、code 符合公式。
import 'dart:io';

const _pubspec = 'pubspec.yaml';
const _settings = 'lib/ui/settings_dialog.dart';

void main(List<String> args) {
  final current = _readCurrent();
  final target = args.isEmpty ? _bumpKind(current.name, 'patch') : args.first;

  final String name;
  if (RegExp(r'^\d+\.\d+\.\d+$').hasMatch(target)) {
    name = target;
  } else if (target == 'major' || target == 'minor' || target == 'patch') {
    name = _bumpKind(current.name, target);
  } else {
    stderr.writeln('用法: dart run tool/bump_version.dart <X.Y.Z|major|minor|patch>');
    exit(2);
  }

  final parts = name.split('.').map(int.parse).toList();
  if (parts[1] > 99 || parts[2] > 99) {
    stderr.writeln('MINOR/PATCH 必须 < 100（否则 versionCode 公式会撞车）');
    exit(2);
  }
  final code = parts[0] * 10000 + parts[1] * 100 + parts[2];

  _write(_pubspec, RegExp(r'^version:.*$', multiLine: true), 'version: $name+$code');
  _write(_settings, RegExp(r"^const kAppVersion = '.*';$", multiLine: true),
      "const kAppVersion = '$name';");

  stdout.writeln('版本: ${current.name}+${current.code}  ->  $name+$code');
  stdout.writeln('下一步：flutter analyze && flutter test');
  stdout.writeln('构建：flutter build apk --release --target-platform android-arm64');
}

class _Ver {
  _Ver(this.name, this.code);
  final String name;
  final int code;
}

_Ver _readCurrent() {
  final line = RegExp(r'^version:\s*(\S+)$', multiLine: true)
      .firstMatch(File(_pubspec).readAsStringSync())!
      .group(1)!;
  final seg = line.split('+');
  return _Ver(seg.first, int.parse(seg.last));
}

String _bumpKind(String name, String kind) {
  final p = name.split('.').map(int.parse).toList();
  switch (kind) {
    case 'major':
      return '${p[0] + 1}.0.0';
    case 'minor':
      return '${p[0]}.${p[1] + 1}.0';
    default:
      return '${p[0]}.${p[1]}.${p[2] + 1}';
  }
}

void _write(String path, RegExp pattern, String replacement) {
  final f = File(path);
  final src = f.readAsStringSync();
  if (!pattern.hasMatch(src)) {
    stderr.writeln('找不到要替换的行：$path ${pattern.pattern}');
    exit(1);
  }
  f.writeAsStringSync(src.replaceFirst(pattern, replacement));
}
