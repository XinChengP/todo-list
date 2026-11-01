// 真实端到端同步测试（对接线上 todoapi）。
// 默认跳过；带参数运行：
//   flutter test test/live_e2e_test.dart \
//     --dart-define=LIVE_E2E=true \
//     --dart-define=LIVE_URL=https://todoapi.example.com \
//     --dart-define=LIVE_TOKEN=<SYNC_TOKEN>
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:todo_app/db/database.dart';
import 'package:todo_app/repo/task_repository.dart';
import 'package:todo_app/sync/api_client.dart';
import 'package:todo_app/sync/settings_repository.dart';
import 'package:todo_app/sync/sync_engine.dart';

void main() {
  if (!const bool.fromEnvironment('LIVE_E2E')) return;

  final url = const String.fromEnvironment('LIVE_URL');
  final token = const String.fromEnvironment('LIVE_TOKEN');
  final config = SyncConfig(baseUrl: url, token: token);

  test('端到端：A 设备新增→推送；B 设备拉取可见；A 删除→B 收敛到墓碑', () async {
    final dbA = AppDatabase.forTesting(NativeDatabase.memory());
    final dbB = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(dbA.close);
    addTearDown(dbB.close);

    final engineA = SyncEngine(dbA, SettingsRepository(dbA));
    final engineB = SyncEngine(dbB, SettingsRepository(dbB));
    final title = 'E2E-${DateTime.now().millisecondsSinceEpoch}';

    // A 设备建任务并推送
    await TaskRepository(dbA).add(title: title);
    await engineA.sync(config);

    // B 设备拉取应看到
    await engineB.sync(config);
    final seen = await (dbB.select(dbB.tasks)..where((t) => t.title.equals(title))).get();
    expect(seen, hasLength(1), reason: 'B 设备应拉到 A 推送的任务');
    expect(seen.first.dirty, isFalse);

    // B 设备勾选完成并推送，A 再拉取应看到完成状态（跨端字段级同步）
    await TaskRepository(dbB).setCompleted(seen.first, done: true);
    await engineB.sync(config);
    await engineA.sync(config);
    final onA = await (dbA.select(dbA.tasks)..where((t) => t.title.equals(title))).getSingle();
    expect(onA.completedAt, isNotNull);

    // A 设备删除并推送，B 收敛到墓碑
    await TaskRepository(dbA).delete(onA);
    await engineA.sync(config);
    await engineB.sync(config);
    final onB = await dbB.getTaskById(seen.first.id);
    expect(onB!.deletedAt, isNotNull);
  }, timeout: const Timeout(Duration(minutes: 5)));
}
