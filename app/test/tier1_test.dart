import 'package:flutter_test/flutter_test.dart';
import 'package:drift/native.dart';

import 'package:todo_app/db/database.dart';
import 'package:todo_app/repo/quick_add.dart';
import 'package:todo_app/repo/task_filters.dart';
import 'package:todo_app/repo/repeat.dart';
import 'package:todo_app/repo/task_repository.dart';

/// 第一梯队：组合筛选 + 快捷添加语法
void main() {
  // 固定"现在"：2026-05-20（周三）10:00
  final now = DateTime(2026, 5, 20, 10);

  group('parseQuickAdd 快捷语法', () {
    test('纯标题：不做任何解析', () {
      final r = parseQuickAdd('买牛奶', now: now);
      expect(r.title, '买牛奶');
      expect(r.hasExtras, isFalse);
    });

    test('清单 + 优先级 + 周期 + 日期时间可组合', () {
      final r = parseQuickAdd('买牛奶 明天18点 !高 #家务 每周', now: now);
      expect(r.title, '买牛奶');
      expect(r.priority, 3);
      expect(r.listName, '家务');
      expect(r.repeat?.unit, 'week');
      expect(r.repeat?.n, 1);
      final d = DateTime.fromMillisecondsSinceEpoch(r.dueAt!);
      expect(d, DateTime(2026, 5, 21, 18, 0));
    });

    test('周期支持自定义间隔', () {
      expect(parseQuickAdd('喝水 每3天', now: now).repeat?.unit, 'day');
      expect(parseQuickAdd('喝水 每3天', now: now).repeat?.n, 3);
      expect(parseQuickAdd('复盘 每2周', now: now).repeat?.n, 2);
    });

    test('优先级支持数字与中文', () {
      expect(parseQuickAdd('a !1', now: now).priority, 1);
      expect(parseQuickAdd('a !2', now: now).priority, 2);
      expect(parseQuickAdd('a !中', now: now).priority, 2);
      expect(parseQuickAdd('a !低', now: now).priority, 1);
    });

    test('日期关键词', () {
      int ms(String s) => parseQuickAdd(s, now: now).dueAt!;
      expect(DateTime.fromMillisecondsSinceEpoch(ms('今天')), DateTime(2026, 5, 20, 9));
      expect(DateTime.fromMillisecondsSinceEpoch(ms('明天')), DateTime(2026, 5, 21, 9));
      expect(DateTime.fromMillisecondsSinceEpoch(ms('后天')), DateTime(2026, 5, 22, 9));
      expect(DateTime.fromMillisecondsSinceEpoch(ms('大后天')), DateTime(2026, 5, 23, 9));
      // 2026-05-20 是周三 → 周五 = 5/22
      expect(DateTime.fromMillisecondsSinceEpoch(ms('周五')), DateTime(2026, 5, 22, 9));
      // 下周一 = 5/25
      expect(DateTime.fromMillisecondsSinceEpoch(ms('下周一')), DateTime(2026, 5, 25, 9));
      // 本周一 = 5/18（可能已过去，但语义是"本周那天"）
      expect(DateTime.fromMillisecondsSinceEpoch(ms('本周一')), DateTime(2026, 5, 18, 9));
    });

    test('月份日期与 M/D，过去则顺延到明年', () {
      expect(DateTime.fromMillisecondsSinceEpoch(parseQuickAdd('11月5日', now: now).dueAt!),
          DateTime(2026, 11, 5, 9));
      expect(DateTime.fromMillisecondsSinceEpoch(parseQuickAdd('11/5', now: now).dueAt!),
          DateTime(2026, 11, 5, 9));
      // 5/1 已过 → 2027
      expect(DateTime.fromMillisecondsSinceEpoch(parseQuickAdd('5/1', now: now).dueAt!),
          DateTime(2027, 5, 1, 9));
    });

    test('时间解析：冒号 / 点 / 点半 / 下午', () {
      int h(String s) => DateTime.fromMillisecondsSinceEpoch(
              parseQuickAdd(s, now: now).dueAt!).hour;
      int m(String s) => DateTime.fromMillisecondsSinceEpoch(
              parseQuickAdd(s, now: now).dueAt!).minute;
      expect(h('开会 18:30'), 18);
      expect(m('开会 18:30'), 30);
      expect(h('开会 9点'), 9);
      expect(m('开会 9点半'), 30);
      expect(h('开会 下午3点'), 15);
      expect(h('开会 晚上8点'), 20);
    });

    test('只有语法没有标题时 title 为空', () {
      expect(parseQuickAdd('#家务 明天', now: now).title, '');
    });
  });

  group('applyTaskFilters 组合筛选', () {
    late AppDatabase db;
    late TaskRepository repo;

    setUp(() {
      db = AppDatabase.forTesting(NativeDatabase.memory());
      repo = TaskRepository(db);
    });
    tearDown(() async => db.close());

    test('状态 + 清单 + 搜索 + 快捷条件叠加', () async {
      final work = await repo.addList('工作');
      final home = await repo.addList('家务');
      final overdue = DateTime.now().subtract(const Duration(days: 2)).millisecondsSinceEpoch;
      final today = DateTime.now().millisecondsSinceEpoch;

      final t1 = await repo.add(title: '写周报', listId: work.id, dueAt: overdue, priority: 3);
      final t2 = await repo.add(title: '买菜', listId: home.id, dueAt: today);
      await repo.add(title: '洗衣服', listId: home.id);
      await repo.setCompleted(t2, done: true);

      final all = await db.select(db.tasks).get();

      // 只看工作清单
      final byList = applyTaskFilters(all, status: TaskFilter.all, listId: work.id);
      expect(byList.map((t) => t.title), ['写周报']);

      // 只看未完成 + 家务
      final homeActive = applyTaskFilters(all,
          status: TaskFilter.active, listId: home.id);
      expect(homeActive.map((t) => t.title), ['洗衣服']);

      // 搜索
      final searched = applyTaskFilters(all, status: TaskFilter.all, query: '菜');
      expect(searched.map((t) => t.title), ['买菜']);

      // 逾期
      final overdueOnly = applyTaskFilters(all,
          status: TaskFilter.all, quick: {QuickFilter.overdue});
      expect(overdueOnly.map((t) => t.title), ['写周报']);

      // 重要
      final important = applyTaskFilters(all,
          status: TaskFilter.all, quick: {QuickFilter.highPriority});
      expect(important.map((t) => t.title), ['写周报']);

      // 有日期 + 未完成
      final withDue = applyTaskFilters(all,
          status: TaskFilter.active, quick: {QuickFilter.hasDue});
      expect(withDue.map((t) => t.title), ['写周报']);

      // 周期筛选（t1 设成周期后应命中）
      await repo.setRepeat(t1, const RepeatRule(unit: 'week'));
      final repeated = applyTaskFilters(await db.select(db.tasks).get(),
          status: TaskFilter.all, quick: {QuickFilter.repeating});
      expect(repeated.map((t) => t.title), ['写周报']);
    });

    test('隐藏已完成：只影响"全部"视图，不影响"已完成"视图', () async {
      final a = await repo.add(title: '做完了');
      await repo.add(title: '还没做');
      await repo.setCompleted(a, done: true);
      final all = await db.select(db.tasks).get();

      final hidden = applyTaskFilters(all,
          status: TaskFilter.all, hideCompleted: true);
      expect(hidden.map((t) => t.title), ['还没做']);

      // 「已完成」视图下不能被藏空
      final doneView = applyTaskFilters(all,
          status: TaskFilter.done, hideCompleted: true);
      expect(doneView.map((t) => t.title), ['做完了']);

      // 「进行中」本来就不含已完成，开关无副作用
      final activeView = applyTaskFilters(all,
          status: TaskFilter.active, hideCompleted: true);
      expect(activeView.map((t) => t.title), ['还没做']);
    });

    test('activeCountByList 只数未完成', () async {
      final l = await repo.addList('工作');
      final a = await repo.add(title: 'A', listId: l.id);
      await repo.add(title: 'B', listId: l.id);
      await repo.setCompleted(a, done: true);
      final counts = activeCountByList(await db.select(db.tasks).get());
      expect(counts[l.id], 1);
    });
  });

  group('清单 CRUD', () {
    late AppDatabase db;
    late TaskRepository repo;

    setUp(() {
      db = AppDatabase.forTesting(NativeDatabase.memory());
      repo = TaskRepository(db);
    });
    tearDown(() async => db.close());

    test('新增 / 重名查找 / 改名 / 软删除后不再出现在流里', () async {
      final l = await repo.addList('工作');
      expect(l.name, '工作');
      expect((await repo.findListByName('工作'))?.id, l.id);

      await repo.renameList(l, '公司');
      final renamed = (await db.select(db.taskLists).get()).single;
      expect(renamed.name, '公司');
      expect(renamed.dirty, isTrue);

      await repo.deleteList(renamed);
      expect(await repo.watchLists().first, isEmpty);
      // 墓碑保留
      final rows = await db.select(db.taskLists).get();
      expect(rows.single.deletedAt, isNotNull);
    });
  });
}
