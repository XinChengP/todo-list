import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:todo_app/db/database.dart';
import 'package:todo_app/repo/repeat.dart';
import 'package:todo_app/repo/task_repository.dart';

/// 周期任务：新规则引擎（周几多选 / 月末 / 第 N 个周几 / 结束条件）+ 完成日志
void main() {
  RepeatRule rule(String json) => RepeatRule.parse(json)!;

  group('规则编解码与文案', () {
    test('空值/坏 JSON 返回 null', () {
      expect(RepeatRule.parse(null), isNull);
      expect(RepeatRule.parse(''), isNull);
      expect(RepeatRule.parse('{"unit":"bogus"}'), isNull);
      expect(RepeatRule.parse('not json'), isNull);
    });

    test('往返编码不丢字段', () {
      const r = RepeatRule(
        unit: 'week',
        n: 2,
        weekdays: [1, 3, 5],
        until: 1799999999999,
        max: 12,
      );
      final back = RepeatRule.parse(r.encode())!;
      expect(back.unit, 'week');
      expect(back.n, 2);
      expect(back.weekdays, [1, 3, 5]);
      expect(back.until, 1799999999999);
      expect(back.max, 12);
    });

    test('文案', () {
      expect(rule('{"unit":"day","n":1}').describe(), '每天');
      expect(rule('{"unit":"day","n":3}').describe(), '每 3 天');
      expect(rule('{"unit":"week","n":1,"weekdays":[1,3,5]}').describe(),
          '周一、周三、周五');
      expect(rule('{"unit":"week","n":2,"weekdays":[2]}').describe(), '每 2 周（周二）');
      expect(
          rule('{"unit":"month","n":1,"monthMode":"dom","anchorDay":31}')
              .describe(),
          '每月31 号');
      expect(rule('{"unit":"month","n":1,"monthMode":"last"}').describe(),
          '每月最后一天');
      expect(
          rule('{"unit":"month","n":1,"monthMode":"dow","dowIndex":2,"weekdays":[3]}')
              .describe(),
          '每月第 2 个周三');
      expect(rule('{"unit":"year","n":1,"month":5,"anchorDay":1}').describe(),
          '每年 5 月 1 日');
    });
  });

  group('日期推进', () {
    final base = DateTime(2026, 5, 20, 9); // 周三

    test('每天 / 每 3 天', () {
      expect(nextAfter(rule('{"unit":"day","n":1}'), from: base, catchUp: false),
          DateTime(2026, 5, 21, 9));
      expect(nextAfter(rule('{"unit":"day","n":3}'), from: base, catchUp: false),
          DateTime(2026, 5, 23, 9));
    });

    test('每周多选：从周三跳到周五，再跳到下周一', () {
      final r = rule('{"unit":"week","n":1,"weekdays":[1,3,5]}');
      final fri = nextAfter(r, from: base, catchUp: false)!;
      expect(fri, DateTime(2026, 5, 22, 9));
      final mon = nextAfter(r, from: fri, catchUp: false)!;
      expect(mon, DateTime(2026, 5, 25, 9));
    });

    test('每两周：跳过中间那一周', () {
      final r = rule('{"unit":"week","n":2,"weekdays":[3]}');
      final next = nextAfter(r, from: base, catchUp: false)!;
      expect(next, DateTime(2026, 6, 3, 9)); // 5/20 + 2 周
    });

    test('每月 31 号：月末夹紧但不漂移（1/31 → 2/28 → 3/31）', () {
      final r = rule('{"unit":"month","n":1,"monthMode":"dom","anchorDay":31}');
      final jan = DateTime(2026, 1, 31, 8);
      final feb = nextAfter(r, from: jan, catchUp: false)!;
      expect(feb, DateTime(2026, 2, 28, 8));
      final mar = nextAfter(r, from: feb, catchUp: false)!;
      expect(mar, DateTime(2026, 3, 31, 8), reason: '不能漂移成 3/28');
    });

    test('每月最后一天', () {
      final r = rule('{"unit":"month","n":1,"monthMode":"last"}');
      final next = nextAfter(r, from: DateTime(2026, 2, 10, 8), catchUp: false)!;
      expect(next, DateTime(2026, 2, 28, 8));
    });

    test('每月第 2 个周三', () {
      final r = rule(
          '{"unit":"month","n":1,"monthMode":"dow","dowIndex":2,"weekdays":[3]}');
      final next = nextAfter(r, from: DateTime(2026, 5, 1, 9), catchUp: false)!;
      expect(next, DateTime(2026, 5, 13, 9));
    });

    test('每年：2/29 在平年夹到 2/28', () {
      final r = rule('{"unit":"year","n":1,"month":2,"anchorDay":29}');
      final next = nextAfter(r, from: DateTime(2028, 2, 29, 9), catchUp: false)!;
      expect(next, DateTime(2029, 2, 28, 9));
    });

    test('catchUp=false 只前进一次；true 追到未来', () {
      final r = rule('{"unit":"day","n":1}');
      final old = DateTime(2026, 5, 10, 9);
      final now = DateTime(2026, 5, 20, 10);
      expect(nextAfter(r, from: old, catchUp: false), DateTime(2026, 5, 11, 9));
      expect(nextAfter(r, from: old, now: now), DateTime(2026, 5, 21, 9));
    });
  });

  group('仓库：完成 / 日志 / 结束条件 / 跳过', () {
    late AppDatabase db;
    late TaskRepository repo;

    setUp(() {
      db = AppDatabase.forTesting(NativeDatabase.memory());
      repo = TaskRepository(db);
    });
    tearDown(() async => db.close());

    test('完成周期任务：推进 + 记日志 + 次数 +1，不产生新任务行', () async {
      final due = DateTime.now().add(const Duration(days: 1)).millisecondsSinceEpoch;
      final t = await repo.add(
        title: '浇花',
        dueAt: due,
        repeat: const RepeatRule(unit: 'day', n: 1),
      );
      expect(t.repeatRule, isNotNull);

      final next = await repo.setCompleted(t, done: true);

      final after = (await db.getTaskById(t.id))!;
      expect(after.completedAt, isNull, reason: '周期任务滚到下一次');
      expect(next, isNotNull);
      expect(after.repeatDone, 1);
      expect(after.dueAt, next);
      expect((await db.select(db.tasks).get()).length, 1, reason: '不产生历史任务行');

      final logs = await db.select(db.taskLogs).get();
      expect(logs, hasLength(1));
      expect(logs.single.taskId, t.id);
      expect(logs.single.dueAt, due);
    });

    test('共 N 次：完成后自动结束重复并标记为已完成', () async {
      final t = await repo.add(
        title: '打卡',
        dueAt: DateTime.now().millisecondsSinceEpoch,
        repeat: const RepeatRule(unit: 'day', n: 1, max: 2),
      );
      final r1 = await repo.setCompleted(t, done: true);
      expect(r1, isNotNull);

      final t2 = (await db.getTaskById(t.id))!;
      final r2 = await repo.setCompleted(t2, done: true);

      final after = (await db.getTaskById(t.id))!;
      expect(r2, isNull, reason: '达到次数上限不再返回下一次');
      expect(after.completedAt, isNotNull, reason: '这一次应当正常完成');
      expect(after.repeatRule, isNull, reason: '规则已清除');
      expect(after.repeatDone, 2);
      expect((await db.select(db.taskLogs).get()).length, 2);
    });

    test('到某日结束：下一次超过截止日就不再排', () async {
      final now = DateTime.now();
      final t = await repo.add(
        title: '限时',
        dueAt: now.millisecondsSinceEpoch,
        repeat: RepeatRule(
          unit: 'day',
          n: 1,
          until: now.add(const Duration(hours: 1)).millisecondsSinceEpoch,
        ),
      );
      await repo.setCompleted(t, done: true);
      final after = (await db.getTaskById(t.id))!;
      expect(after.completedAt, isNotNull);
      expect(after.repeatRule, isNull);
    });

    test('跳过这一次：due 前进，但不记完成、不累加次数', () async {
      final due = DateTime.now().millisecondsSinceEpoch;
      final t = await repo.add(
        title: '跳过一次',
        dueAt: due,
        repeat: const RepeatRule(unit: 'day', n: 1),
      );
      final next = await repo.skipOccurrence(t);
      final after = (await db.getTaskById(t.id))!;
      expect(next, isNotNull);
      expect(after.dueAt, next);
      expect(after.repeatDone, 0);
      expect(await db.select(db.taskLogs).get(), isEmpty);
    });

    test('逾期策略 once：只前进一个周期，仍可能逾期', () async {
      final t = await repo.add(
        title: '拖延',
        dueAt: DateTime.now()
            .subtract(const Duration(days: 10))
            .millisecondsSinceEpoch,
        repeat: const RepeatRule(unit: 'day', n: 1),
      );
      await repo.setCatchupPolicy(RepeatCatchup.once);
      final next = await repo.setCompleted(t, done: true);
      expect(await repo.catchupPolicy(), RepeatCatchup.once);
      // 只前进一天 → 仍在过去
      expect(next! < DateTime.now().millisecondsSinceEpoch, isTrue);
    });

    test('旧字段仍可识别（无 repeat_rule 时回退）', () async {
      final now = DateTime.now().millisecondsSinceEpoch;
      await db.into(db.tasks).insert(TasksCompanion.insert(
            id: 'legacy-1',
            createdAt: now,
            updatedAt: now,
            title: const Value('老数据'),
            repeatUnit: const Value('week'),
            repeatInterval: const Value(2),
            fieldTs: Value(const {'repeat_unit': 1, 'repeat_interval': 1}.isEmpty
                ? '{}'
                : '{"repeat_unit":1,"repeat_interval":1}'),
          ));
      final t = (await db.getTaskById('legacy-1'))!;
      final r = TaskRepository.ruleOf(t);
      expect(r?.unit, 'week');
      expect(r?.n, 2);
    });
  });
}
