import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:todo_app/db/database.dart';
import 'package:todo_app/repo/repeat.dart';
import 'package:todo_app/repo/task_filters.dart';
import 'package:todo_app/repo/task_repository.dart';
import 'package:todo_app/ui/format.dart';

void main() {
  group('截止时间精确到分钟', () {
    test('展示：日期型只显示日期，带时间显示 HH:mm', () {
      final now = DateTime.now();
      final dayOnly = DateTime(now.year, now.month, now.day);
      expect(dueLabel(dayOnly.millisecondsSinceEpoch), '今天');

      final withTime = DateTime(now.year, now.month, now.day, 18, 30);
      expect(dueLabel(withTime.millisecondsSinceEpoch), '今天 18:30');

      final tomorrow = dayOnly
          .add(const Duration(days: 1))
          .add(const Duration(hours: 9, minutes: 5));
      expect(dueLabel(tomorrow.millisecondsSinceEpoch), '明天 09:05');
    });

    test('逾期判定：带时间按时间点，日期型按天', () {
      final now = DateTime.now();
      // 昨天中午（带时间）→ 一定已过
      final y = now.subtract(const Duration(days: 1));
      final pastWithTime = DateTime(y.year, y.month, y.day, 12);
      expect(isOverdue(pastWithTime.millisecondsSinceEpoch), isTrue);

      // 日期型（00:00）今天不算逾期
      final dayOnly = DateTime(now.year, now.month, now.day);
      expect(isOverdue(dayOnly.millisecondsSinceEpoch), isFalse);
    });
  });

  group('打卡撤销', () {
    late AppDatabase db;
    late TaskRepository repo;
    setUp(() {
      db = AppDatabase.forTesting(NativeDatabase.memory());
      repo = TaskRepository(db);
    });
    tearDown(() async => db.close());

    test('周期任务完成 → 撤销：due 还原、次数回退、日志作废', () async {
      final due = DateTime.now().add(const Duration(days: 1)).millisecondsSinceEpoch;
      final t = await repo.add(
        title: '打卡',
        dueAt: due,
        repeat: const RepeatRule(unit: 'day', n: 1),
      );
      final r = await repo.setCompleted(t, done: true);

      var after = (await db.getTaskById(t.id))!;
      expect(after.dueAt, isNot(due));
      expect(after.repeatDone, 1);
      expect((await db.select(db.taskLogs).get()).single.deletedAt, isNull);

      await repo.undoCompletion(t, r);
      after = (await db.getTaskById(t.id))!;
      expect(after.dueAt, due, reason: '撤销后回到原来的截止时间');
      expect(after.repeatDone, 0);
      expect(after.completedAt, isNull);
      final log = (await db.select(db.taskLogs).get()).single;
      expect(log.deletedAt, isNotNull, reason: '日志作废但不物理删除');
    });

    test('普通任务完成也会记日志（统计覆盖全部任务）', () async {
      final t = await repo.add(title: '一次性');
      await repo.setCompleted(t, done: true);
      final logs = await db.select(db.taskLogs).get();
      expect(logs, hasLength(1));
      expect(logs.single.taskId, t.id);

      // 取消完成 → 最近日志作废
      await repo.setCompleted(t, done: false);
      final logs2 = await db.select(db.taskLogs).get();
      expect(logs2.single.deletedAt, isNotNull);
    });
  });

  group('手动排序', () {
    late AppDatabase db;
    late TaskRepository repo;
    setUp(() {
      db = AppDatabase.forTesting(NativeDatabase.memory());
      repo = TaskRepository(db);
    });
    tearDown(() async => db.close());

    test('reorder 写入 sort_order，sortManual 按它排序，null 排后面', () async {
      final a = await repo.add(title: 'A');
      final b = await repo.add(title: 'B');
      final c = await repo.add(title: 'C');

      await repo.reorder([c.id, a.id, b.id]);
      final rows = await db.select(db.tasks).get();
      final sorted = sortManual(rows);
      expect(sorted.map((t) => t.title), ['C', 'A', 'B']);
      expect(sorted.first.sortOrder, 0);
      expect(sorted.last.sortOrder, 2);
    });

    test('isManualSort 持久化到本地设置', () async {
      expect(await repo.isManualSort(), isFalse);
      await repo.setManualSort(true);
      expect(await repo.isManualSort(), isTrue);
      await repo.setManualSort(false);
      expect(await repo.isManualSort(), isFalse);
    });
  });
}
