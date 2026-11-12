import '../db/database.dart';
import '../ui/format.dart';
import 'task_repository.dart';

/// 快捷筛选条件（可与状态筛选、清单筛选、搜索叠加）
enum QuickFilter { overdue, today, week, highPriority, hasDue, noDue, repeating }

String quickFilterLabel(QuickFilter f) => switch (f) {
      QuickFilter.overdue => '已逾期',
      QuickFilter.today => '今天到期',
      QuickFilter.week => '7 天内',
      QuickFilter.highPriority => '重要',
      QuickFilter.hasDue => '有日期',
      QuickFilter.noDue => '无日期',
      QuickFilter.repeating => '周期',
    };

DateTime _dayOf(int ms) {
  final d = DateTime.fromMillisecondsSinceEpoch(ms);
  return DateTime(d.year, d.month, d.day);
}

/// 组合筛选：状态 → 清单 → 快捷条件 → 搜索。
/// 纯内存计算（入参已排序），不触发任何 SQL。
List<Task> applyTaskFilters(
  List<Task> rows, {
  required TaskFilter status,
  String? listId,
  String query = '',
  Set<QuickFilter> quick = const {},
  bool hideCompleted = false,
  DateTime? now,
}) {
  var out = filterTasks(rows, status);

  // 「隐藏已完成」只作用于"全部"视图；切到"已完成"时不能把它也藏了
  if (hideCompleted && status == TaskFilter.all) {
    out = [
      for (final t in out)
        if (t.completedAt == null) t,
    ];
  }

  if (listId != null) {
    out = [
      for (final t in out)
        if (t.listId == listId) t,
    ];
  }

  if (quick.isNotEmpty) {
    final today = now ?? DateTime.now();
    final today0 = DateTime(today.year, today.month, today.day);
    final weekEnd = today0.add(const Duration(days: 7));
    final q = query.trim().toLowerCase();
    out = [
      for (final t in out)
        if (_matchAll(t, quick, today0, weekEnd, q)) t,
    ];
  }

  final q = query.trim().toLowerCase();
  if (q.isNotEmpty) {
    out = [
      for (final t in out)
        if (t.title.toLowerCase().contains(q) || t.notes.toLowerCase().contains(q)) t,
    ];
  }
  return out;
}

bool _matchAll(
  Task t,
  Set<QuickFilter> quick,
  DateTime today0,
  DateTime weekEnd,
  String query,
) {
  for (final f in quick) {
    final ok = switch (f) {
      QuickFilter.overdue =>
        t.dueAt != null && t.completedAt == null && isOverdue(t.dueAt!),
      QuickFilter.today =>
        t.dueAt != null && _dayOf(t.dueAt!).isAtSameMomentAs(today0),
      QuickFilter.week => t.dueAt != null &&
          !_dayOf(t.dueAt!).isBefore(today0) &&
          _dayOf(t.dueAt!).isBefore(weekEnd),
      QuickFilter.highPriority => t.priority >= 2,
      QuickFilter.hasDue => t.dueAt != null,
      QuickFilter.noDue => t.dueAt == null,
      QuickFilter.repeating => t.repeatUnit != null,
    };
    if (!ok) return false;
  }
  return true;
}

/// 每个清单还有多少条未完成（用于 chips 上的角标）
Map<String, int> activeCountByList(List<Task> rows) {
  final out = <String, int>{};
  for (final t in rows) {
    final id = t.listId;
    if (id == null || t.completedAt != null) continue;
    out[id] = (out[id] ?? 0) + 1;
  }
  return out;
}

/// 手动排序：按 sort_order 升序；未设置（null）的排后面，
/// 并保持它们原有的相对顺序（输入已经按智能规则排好）
List<Task> sortManual(List<Task> rows) {
  final indexed = [for (var i = 0; i < rows.length; i++) (rows[i], i)];
  indexed.sort((a, b) {
    final ao = a.$1.sortOrder;
    final bo = b.$1.sortOrder;
    if (ao == null && bo == null) return a.$2 - b.$2;
    if (ao == null) return 1;
    if (bo == null) return -1;
    final c = ao.compareTo(bo);
    return c != 0 ? c : a.$2 - b.$2;
  });
  return [for (final e in indexed) e.$1];
}
