import 'package:drift/drift.dart';
import 'package:uuid/uuid.dart';

import '../db/database.dart';
import '../db/sync_fields.dart';
import 'repeat.dart';

enum TaskFilter { all, active, done }

/// 内存筛选（不查库）。入参已按 [TaskRepository.sortTasks] 排好序，
/// 过滤不改变相对顺序，因此界面切换筛选时零 SQL 开销。
List<Task> filterTasks(List<Task> rows, TaskFilter filter) {
  switch (filter) {
    case TaskFilter.all:
      return rows;
    case TaskFilter.active:
      return [
        for (final t in rows)
          if (t.completedAt == null) t,
      ];
    case TaskFilter.done:
      return [
        for (final t in rows)
          if (t.completedAt != null) t,
      ];
  }
}

/// 本地任务仓库。
///
/// 所有写操作都按"字段级"记账：改了哪些可同步字段，就在 field_ts 里给哪些
/// 字段盖上当前毫秒时间戳并置 dirty —— M3 同步层因此能直接从行数据构造
/// 推送 payload，并与服务器的字段级 Last-Write-Wins 对齐。
class TaskRepository {
  TaskRepository(this._db);

  final AppDatabase _db;
  static const Uuid _uuid = Uuid();

  /// 监听未删除的任务，按 [filter] 过滤
  Stream<List<Task>> watch({TaskFilter filter = TaskFilter.all}) {
    final query = _db.select(_db.tasks)..where((t) => t.deletedAt.isNull());
    switch (filter) {
      case TaskFilter.active:
        query.where((t) => t.completedAt.isNull());
      case TaskFilter.done:
        query.where((t) => t.completedAt.isNotNull());
      case TaskFilter.all:
        break;
    }
    return query.watch().map(sortTasks);
  }

  /// 排序：已完成沉底 → 优先级高在前 → 截止日期早在前 → 新建在前
  static List<Task> sortTasks(List<Task> rows) {
    final list = [...rows];
    list.sort((a, b) {
      final aDone = a.completedAt != null;
      final bDone = b.completedAt != null;
      if (aDone != bDone) return aDone ? 1 : -1;
      final p = b.priority.compareTo(a.priority);
      if (p != 0) return p;
      final ad = a.dueAt;
      final bd = b.dueAt;
      if (ad == null && bd != null) return 1;
      if (ad != null && bd == null) return -1;
      if (ad != null && bd != null && ad != bd) return ad.compareTo(bd);
      return b.createdAt.compareTo(a.createdAt);
    });
    return list;
  }

  /// 新建任务：id 用 UUIDv7（同步契约），所有初始字段盖同一时间戳
  Future<Task> add({
    required String title,
    String notes = '',
    int? dueAt,
    int priority = 0,
    String? listId,
    String? repeatUnit,
    int? repeatInterval,
  }) async {
    final now = nowMs();
    final unit = RepeatUnit.isValid(repeatUnit) ? repeatUnit : null;
    final ts = FieldTs.empty.withWrites({
      'title': now,
      'notes': now,
      'priority': now,
      if (dueAt != null) 'due_at': now,
      if (listId != null) 'list_id': now,
      if (unit != null) 'repeat_unit': now,
      if (unit != null) 'repeat_interval': now,
    });
    final id = _uuid.v7();
    await _db.into(_db.tasks).insert(
          TasksCompanion.insert(
            id: id,
            createdAt: now,
            updatedAt: now, // = max(created_at, max field_ts)，两者此刻相等
            title: Value(title),
            notes: Value(notes),
            dueAt: Value(dueAt),
            priority: Value(priority),
            listId: Value(listId),
            repeatUnit: Value(unit),
            repeatInterval: Value(unit == null ? null : _normInterval(repeatInterval)),
            fieldTs: Value(ts.encode()),
            dirty: const Value(true),
          ),
        );
    return (await _db.getTaskById(id))!;
  }

  /// 勾选/取消完成。
  ///
  /// 周期任务完成时**原地滚到下一次**：`due_at` 推到下一次、`completed_at` 保持为空，
  /// 不产生历史行（同一行循环使用，也就没有"重复行被多端各建一份"的竞态）。
  /// 返回值是推进后的新 dueAt（非周期任务返回 null），界面可据此提示"下次 X"。
  Future<int?> setCompleted(Task t, {required bool done}) async {
    final now = nowMs();
    if (done && RepeatUnit.isValid(t.repeatUnit)) {
      final next = nextDueAt(
        fromMs: t.dueAt,
        unit: t.repeatUnit,
        interval: t.repeatInterval,
        nowMs: now,
      );
      final fts = _nextTs(t, {'completed_at': now, 'due_at': now});
      await _write(
        t.id,
        TasksCompanion(
          completedAt: const Value<int?>(null),
          dueAt: Value(next),
          fieldTs: Value(fts.encode()),
          updatedAt: Value(now),
          dirty: const Value(true),
        ),
      );
      return next;
    }

    final fts = _nextTs(t, {'completed_at': now});
    await _write(t.id, TasksCompanion(
      completedAt: Value(done ? now : null),
      fieldTs: Value(fts.encode()),
      updatedAt: Value(now),
      dirty: const Value(true),
    ));
    return null;
  }

  /// 设置/清除周期规则。[unit] 传 null 表示不重复。
  Future<void> setRepeat(Task t, String? unit, int interval) async {
    final now = nowMs();
    final valid = RepeatUnit.isValid(unit) ? unit : null;
    final fts = _nextTs(t, {'repeat_unit': now, 'repeat_interval': now});
    await _write(
      t.id,
      TasksCompanion(
        repeatUnit: Value(valid),
        repeatInterval: Value(valid == null ? null : _normInterval(interval)),
        fieldTs: Value(fts.encode()),
        updatedAt: Value(now),
        dirty: const Value(true),
      ),
    );
  }

  /// 补推进周期任务：桌面卡片的原生接收器只写 `completed_at`，算不了"下一次"。
  /// App 启动 / 回前台 / 同步结束后调用，把「已完成但仍带周期规则」的任务滚到下一次。
  /// 返回被推进的条数（0 表示无需处理）。
  Future<int> reconcileRecurring() async {
    final rows = await (_db.select(_db.tasks)
          ..where((t) =>
              t.deletedAt.isNull() &
              t.completedAt.isNotNull() &
              t.repeatUnit.isNotNull()))
        .get();
    for (final t in rows) {
      await setCompleted(t, done: true);
    }
    return rows.length;
  }

  static int _normInterval(int? v) => (v == null || v < 1) ? 1 : (v > 99 ? 99 : v);

  Future<void> rename(Task t, String title) => _editField(t, 'title', (c) => c.copyWith(title: Value(title)));
  Future<void> setNotes(Task t, String notes) => _editField(t, 'notes', (c) => c.copyWith(notes: Value(notes)));
  Future<void> setPriority(Task t, int priority) => _editField(t, 'priority', (c) => c.copyWith(priority: Value(priority)));

  /// 截止日期；传 null 表示清除（清除同样盖时间戳，保证 LWW 语义）
  Future<void> setDue(Task t, int? dueAt) => _editField(t, 'due_at', (c) => c.copyWith(dueAt: Value(dueAt)));

  Future<void> setList(Task t, String? listId) => _editField(t, 'list_id', (c) => c.copyWith(listId: Value(listId)));

  /// 软删除：写 deleted_at 墓碑，行保留（同步契约）
  Future<void> delete(Task t) => _editField(t, 'deleted_at', (c) => c.copyWith(deletedAt: Value(nowMs())));

  /// 撤销删除：清掉墓碑（清除同样盖新时间戳，LWW 语义保证撤销赢过删除）
  Future<void> restore(Task t) =>
      _editField(t, 'deleted_at', (c) => c.copyWith(deletedAt: const Value<int?>(null)));

  // ---- 内部 ----

  FieldTs _nextTs(Task t, Map<String, int> writes) => FieldTs.parse(t.fieldTs).withWrites(writes);

  /// 单字段写入的公共路径：在字段列变化之上合并盖时间戳 + 置 dirty + 推进 updated_at。
  /// 三件套与字段列必须一次 write 落库，缺一不可（否则该修改永远不会同步）。
  Future<void> _editField(Task t, String field, TasksCompanion Function(TasksCompanion c) apply) async {
    final now = nowMs();
    final fts = _nextTs(t, {field: now});
    final companion = apply(
      TasksCompanion(
        fieldTs: Value(fts.encode()),
        updatedAt: Value(now),
        dirty: const Value(true),
      ),
    );
    await _write(t.id, companion);
  }

  Future<void> _write(String id, TasksCompanion c) async {
    await (_db.update(_db.tasks)..where((x) => x.id.equals(id))).write(c);
  }
}
