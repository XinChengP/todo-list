import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:todo_app/db/database.dart';
import 'package:todo_app/repo/repeat.dart';
import 'package:todo_app/repo/task_repository.dart';

/// 周期任务：日期推进规则 + 完成即滚到下一次 + 桌面勾选的补推进
void main() {
  group('nextDueAt 日期推进', () {
    test('非周期任务返回 null', () {
      expect(nextDueAt(fromMs: 1000, unit: null, interval: 1, nowMs: 0), isNull);
      expect(nextDueAt(fromMs: 1000, unit: 'bogus', interval: 1, nowMs: 0), isNull);
    });

    test('每天 / 每周按固定天数推进', () {
      final base = DateTime(2026, 3, 10, 9).millisecondsSinceEpoch;
      final day = nextDueAt(fromMs: base, unit: 'day', interval: 1, nowMs: base)!;
      expect(DateTime.fromMillisecondsSinceEpoch(day), DateTime(2026, 3, 11, 9));

      final three = nextDueAt(fromMs: base, unit: 'day', interval: 3, nowMs: base)!;
      expect(DateTime.fromMillisecondsSinceEpoch(three), DateTime(2026, 3, 13, 9));

      final week = nextDueAt(fromMs: base, unit: 'week', interval: 2, nowMs: base)!;
      expect(DateTime.fromMillisecondsSinceEpoch(week), DateTime(2026, 3, 24, 9));
    });

    test('每月：目标月天数不足时夹到月末，不溢出到下个月', () {
      // 1/31 + 1 月 = 2/28（2026 非闰年）
      final jan31 = DateTime(2026, 1, 31, 8).millisecondsSinceEpoch;
      final feb = nextDueAt(fromMs: jan31, unit: 'month', interval: 1, nowMs: jan31)!;
      expect(DateTime.fromMillisecondsSinceEpoch(feb), DateTime(2026, 2, 28, 8));

      // 闰年 1/31 + 1 月 = 2/29
      final jan31Leap = DateTime(2028, 1, 31, 8).millisecondsSinceEpoch;
      final febLeap = nextDueAt(fromMs: jan31Leap, unit: 'month', interval: 1, nowMs: jan31Leap)!;
      expect(DateTime.fromMillisecondsSinceEpoch(febLeap), DateTime(2028, 2, 29, 8));
    });

    test('每年按 12 个月推进', () {
      final d = DateTime(2026, 6, 15, 20).millisecondsSinceEpoch;
      final next = nextDueAt(fromMs: d, unit: 'year', interval: 1, nowMs: d)!;
      expect(DateTime.fromMillisecondsSinceEpoch(next), DateTime(2027, 6, 15, 20));
    });

    test('拖了很久才勾选：一直追到未来，不停在过去', () {
      // 每天的任务，截止日期是 10 天前
      final now = DateTime(2026, 5, 20, 12).millisecondsSinceEpoch;
      final past = DateTime(2026, 5, 10, 12).millisecondsSinceEpoch;
      final next = nextDueAt(fromMs: past, unit: 'day', interval: 1, nowMs: now)!;
      expect(DateTime.fromMillisecondsSinceEpoch(next), DateTime(2026, 5, 21, 12));
      expect(next, greaterThan(now));
    });

    test('没有截止日期时以"现在"为基准', () {
      final now = DateTime(2026, 5, 20, 12).millisecondsSinceEpoch;
      final next = nextDueAt(fromMs: null, unit: 'week', interval: 1, nowMs: now)!;
      expect(DateTime.fromMillisecondsSinceEpoch(next), DateTime(2026, 5, 27, 12));
    });

    test('标签文案', () {
      expect(repeatLabel('day', 1), '每天');
      expect(repeatLabel('week', 1), '每周');
      expect(repeatLabel('day', 3), '每 3天');
      expect(repeatLabel('month', 2), '每 2月');
      expect(repeatLabel(null, 1), '');
      expect(repeatLabel('bogus', 1), '');
    });
  });

  group('仓库层：完成即滚到下一次', () {
    late AppDatabase db;
    late TaskRepository repo;

    setUp(() {
      db = AppDatabase.forTesting(NativeDatabase.memory());
      repo = TaskRepository(db);
    });
    tearDown(() async => db.close());

    test('周期任务完成后：due_at 前进、completed_at 保持空、不产生新行', () async {
      final due = DateTime.now().add(const Duration(days: 1));
      final t = await repo.add(
        title: '浇花',
        dueAt: due.millisecondsSinceEpoch,
        repeatUnit: 'day',
        repeatInterval: 1,
      );
      expect(t.repeatUnit, 'day');
      expect(t.repeatInterval, 1);

      final next = await repo.setCompleted(t, done: true);

      final after = (await db.getTaskById(t.id))!;
      expect(after.completedAt, isNull, reason: '周期任务不应停留在已完成状态');
      expect(next, isNotNull);
      expect(after.dueAt, next);
      expect(after.dueAt! > due.millisecondsSinceEpoch, isTrue);
      expect(after.dirty, isTrue);
      expect((await db.select(db.tasks).get()).length, 1, reason: '不应产生历史行');
    });

    test('非周期任务完成行为不变', () async {
      final t = await repo.add(title: '一次性');
      final next = await repo.setCompleted(t, done: true);
      expect(next, isNull);
      final after = (await db.getTaskById(t.id))!;
      expect(after.completedAt, isNotNull);
      expect(after.dueAt, isNull);
    });

    test('取消完成不受周期影响', () async {
      final t = await repo.add(title: '一次性2');
      await repo.setCompleted(t, done: true);
      final again = (await db.getTaskById(t.id))!;
      final next = await repo.setCompleted(again, done: false);
      expect(next, isNull);
      expect((await db.getTaskById(t.id))!.completedAt, isNull);
    });

    test('桌面卡片勾选（只写 completed_at）由 reconcileRecurring 补齐', () async {
      final t = await repo.add(
        title: '拖地',
        dueAt: DateTime.now().millisecondsSinceEpoch,
        repeatUnit: 'week',
        repeatInterval: 1,
      );
      // 模拟原生接收器：直接写 completed_at，不算下一次
      await (db.update(db.tasks)..where((x) => x.id.equals(t.id))).write(
        TasksCompanion(completedAt: Value(DateTime.now().millisecondsSinceEpoch)),
      );

      final n = await repo.reconcileRecurring();
      expect(n, 1);

      final after = (await db.getTaskById(t.id))!;
      expect(after.completedAt, isNull, reason: '补推进后应回到未完成');
      expect(after.dueAt! > t.dueAt!, isTrue);

      // 幂等：再跑一次没有待处理的
      expect(await repo.reconcileRecurring(), 0);
    });

    test('setRepeat 可设置与清除规则', () async {
      final t = await repo.add(title: '体检');
      await repo.setRepeat(t, 'year', 1);
      var after = (await db.getTaskById(t.id))!;
      expect(after.repeatUnit, 'year');
      expect(after.repeatInterval, 1);

      await repo.setRepeat(after, null, 1);
      after = (await db.getTaskById(t.id))!;
      expect(after.repeatUnit, isNull);
      expect(after.repeatInterval, isNull);
    });
  });
}
