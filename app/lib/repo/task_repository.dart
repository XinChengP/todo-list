import 'package:drift/drift.dart';
import 'package:uuid/uuid.dart';

import '../db/database.dart';
import '../db/sync_fields.dart';
import 'reminder_time.dart';
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
    RepeatRule? repeat,
  }) async {
    final now = nowMs();
    final ts = FieldTs.empty.withWrites({
      'title': now,
      'notes': now,
      'priority': now,
      if (dueAt != null) 'due_at': now,
      if (listId != null) 'list_id': now,
      if (repeat != null) 'repeat_rule': now,
      if (repeat != null) 'repeat_done': now,
      if (repeat != null) 'repeat_unit': now,
      if (repeat != null) 'repeat_interval': now,
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
            repeatUnit: Value(repeat?.unit),
            repeatInterval: Value(repeat?.n),
            repeatRule: Value(repeat?.encode()),
            repeatDone: Value(repeat == null ? null : 0),
            fieldTs: Value(ts.encode()),
            dirty: const Value(true),
          ),
        );
    return (await _db.getTaskById(id))!;
  }

  /// 任务当前的周期规则（新字段优先，回退旧字段）
  static RepeatRule? ruleOf(Task t) =>
      RepeatRule.parse(t.repeatRule) ??
      RepeatRule.fromLegacy(t.repeatUnit, t.repeatInterval);

  static const catchupKey = 'repeat_catchup';

  /// 逾期策略（本地设置，不参与同步）：
  /// - skip：勾选时直接滚到未来（默认）
  /// - once：只前进一个周期，仍显示逾期
  /// - today：滚到今天或之后
  Future<RepeatCatchup> catchupPolicy() async {
    final row = await (_db.select(_db.settings)
          ..where((s) => s.key.equals(catchupKey)))
        .getSingleOrNull();
    return switch (row?.value) {
      'once' => RepeatCatchup.once,
      'today' => RepeatCatchup.today,
      _ => RepeatCatchup.skip,
    };
  }

  Future<void> setCatchupPolicy(RepeatCatchup p) async {
    await _db.into(_db.settings).insertOnConflictUpdate(
          SettingsCompanion.insert(key: catchupKey, value: p.name),
        );
  }

  /// 勾选/取消完成。
  ///
  /// 周期任务：**原地滚到下一次**，同时写一条完成日志、累加 repeat_done；
  /// 达到「共 N 次 / 至某日」后自动结束重复，并把这一次正常标记为已完成。
  /// 返回推进后的新 dueAt（非周期或周期结束返回 null）。
  Future<int?> setCompleted(Task t, {required bool done}) async {
    final now = nowMs();
    final rule = ruleOf(t);

    if (done && rule != null) {
      final policy = await catchupPolicy();
      final from = DateTime.fromMillisecondsSinceEpoch(t.dueAt ?? now);
      final next = _nextWithPolicy(rule, from, DateTime.fromMillisecondsSinceEpoch(now), policy);
      final doneCount = (t.repeatDone ?? 0) + 1;

      final overMax = rule.max != null && doneCount >= rule.max!;
      final overUntil = rule.until != null &&
          next != null &&
          next.millisecondsSinceEpoch > rule.until!;
      final ended = overMax || overUntil || next == null;

      // 日志：记录"这一次完成"
      await _logCompletion(t, now);

      final fts = _nextTs(t, {
        'completed_at': now,
        if (!ended) 'due_at': now,
        'repeat_done': now,
        if (ended) 'repeat_rule': now,
        if (ended) 'repeat_unit': now,
        if (ended) 'repeat_interval': now,
      });
      await _write(
        t.id,
        TasksCompanion(
          // 结束时这次真的完成；否则保持未完成等下一次
          completedAt: Value(ended ? now : null),
          dueAt: Value(ended ? t.dueAt : next.millisecondsSinceEpoch),
          // 提醒跟着新的 due 走（周期任务完成一次后自动重排下一次）
          remindAt: Value(ended
              ? null
              : reminderAtMs(
                  dueAt: next.millisecondsSinceEpoch,
                  offsetMinutes: t.remindOffset,
                  completed: false,
                )),
          repeatDone: Value(doneCount),
          repeatRule: Value(ended ? null : t.repeatRule),
          repeatUnit: Value(ended ? null : t.repeatUnit),
          repeatInterval: Value(ended ? null : t.repeatInterval),
          fieldTs: Value(fts.encode()),
          updatedAt: Value(now),
          dirty: const Value(true),
        ),
      );
      return ended ? null : next.millisecondsSinceEpoch;
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

  DateTime? _nextWithPolicy(RepeatRule r, DateTime from, DateTime now, RepeatCatchup p) {
    return switch (p) {
      RepeatCatchup.once => nextAfter(r, from: from, catchUp: false),
      RepeatCatchup.today => nextAfter(
          r,
          from: from,
          now: DateTime(now.year, now.month, now.day),
          catchUp: true,
        ),
      RepeatCatchup.skip => nextAfter(r, from: from, now: now, catchUp: true),
    };
  }

  /// 跳过这一次：前进到下一次，但不记完成、不累加次数
  Future<int?> skipOccurrence(Task t) async {
    final rule = ruleOf(t);
    if (rule == null) return null;
    final now = nowMs();
    final next = nextAfter(
      rule,
      from: DateTime.fromMillisecondsSinceEpoch(t.dueAt ?? now),
      now: DateTime.fromMillisecondsSinceEpoch(now),
      catchUp: true,
    );
    if (next == null) return null;
    final fts = _nextTs(t, {'due_at': now});
    await _write(t.id, TasksCompanion(
      dueAt: Value(next.millisecondsSinceEpoch),
      remindAt: Value(reminderAtMs(
        dueAt: next.millisecondsSinceEpoch,
        offsetMinutes: t.remindOffset,
        completed: false,
      )),
      fieldTs: Value(fts.encode()),
      updatedAt: Value(now),
      dirty: const Value(true),
    ));
    return next.millisecondsSinceEpoch;
  }

  Future<void> _logCompletion(Task t, int at) async {
    final fts = FieldTs.empty.withWrites({
      'task_id': at,
      'title': at,
      'due_at': at,
      'completed_at': at,
    });
    await _db.into(_db.taskLogs).insert(
          TaskLogsCompanion.insert(
            id: _uuid.v7(),
            taskId: t.id,
            title: Value(t.title),
            dueAt: Value(t.dueAt),
            completedAt: at,
            createdAt: at,
            updatedAt: at,
            fieldTs: Value(fts.encode()),
            dirty: const Value(true),
          ),
        );
  }

  /// 设置/清除周期规则（null = 不重复）
  Future<void> setRepeat(Task t, RepeatRule? rule) async {
    final now = nowMs();
    final fts = _nextTs(t, {
      'repeat_rule': now,
      'repeat_done': now,
      'repeat_unit': now,
      'repeat_interval': now,
    });
    await _write(
      t.id,
      TasksCompanion(
        repeatRule: Value(rule?.encode()),
        repeatDone: Value(rule == null ? null : 0),
        repeatUnit: Value(rule?.unit),
        repeatInterval: Value(rule?.n),
        fieldTs: Value(fts.encode()),
        updatedAt: Value(now),
        dirty: const Value(true),
      ),
    );
  }

  /// 补推进周期任务：桌面卡片的原生接收器只写 completed_at，算不了"下一次"。
  Future<int> reconcileRecurring() async {
    final rows = await (_db.select(_db.tasks)
          ..where((t) =>
              t.deletedAt.isNull() &
              t.completedAt.isNotNull() &
              (t.repeatRule.isNotNull() | t.repeatUnit.isNotNull())))
        .get();
    for (final t in rows) {
      await setCompleted(t, done: true);
    }
    return rows.length;
  }

  // ---- 完成日志 / 统计 ----

  Stream<List<TaskLog>> watchLogs() =>
      (_db.select(_db.taskLogs)
            ..where((l) => l.deletedAt.isNull())
            ..orderBy([(l) => OrderingTerm(expression: l.completedAt, mode: OrderingMode.desc)]))
          .watch();

  Future<void> rename(Task t, String title) => _editField(t, 'title', (c) => c.copyWith(title: Value(title)));
  Future<void> setNotes(Task t, String notes) => _editField(t, 'notes', (c) => c.copyWith(notes: Value(notes)));
  Future<void> setPriority(Task t, int priority) => _editField(t, 'priority', (c) => c.copyWith(priority: Value(priority)));

  /// 截止日期；传 null 表示清除（清除同样盖时间戳，保证 LWW 语义）。
  /// 设置了提醒时同步重算 remind_at。
  Future<void> setDue(Task t, int? dueAt) async {
    final now = nowMs();
    final fts = _nextTs(t, {'due_at': now, 'remind_at': now});
    await _write(
      t.id,
      TasksCompanion(
        dueAt: Value(dueAt),
        remindAt: Value(reminderAtMs(
          dueAt: dueAt,
          offsetMinutes: t.remindOffset,
          completed: t.completedAt != null,
        )),
        fieldTs: Value(fts.encode()),
        updatedAt: Value(now),
        dirty: const Value(true),
      ),
    );
  }

  /// 设置/关闭提醒（提前分钟数，null = 关闭）
  Future<void> setReminder(Task t, int? minutesBefore) async {
    final now = nowMs();
    final offset = minutesBefore?.clamp(0, 10080);
    final fts = _nextTs(t, {'remind_offset': now, 'remind_at': now});
    await _write(
      t.id,
      TasksCompanion(
        remindOffset: Value(offset),
        remindAt: Value(reminderAtMs(
          dueAt: t.dueAt,
          offsetMinutes: offset,
          completed: t.completedAt != null,
        )),
        fieldTs: Value(fts.encode()),
        updatedAt: Value(now),
        dirty: const Value(true),
      ),
    );
  }

  Future<void> setList(Task t, String? listId) => _editField(t, 'list_id', (c) => c.copyWith(listId: Value(listId)));

  /// 软删除：写 deleted_at 墓碑，行保留（同步契约）
  Future<void> delete(Task t) => _editField(t, 'deleted_at', (c) => c.copyWith(deletedAt: Value(nowMs())));

  /// 撤销删除：清掉墓碑（清除同样盖新时间戳，LWW 语义保证撤销赢过删除）
  Future<void> restore(Task t) =>
      _editField(t, 'deleted_at', (c) => c.copyWith(deletedAt: const Value<int?>(null)));

  // ---- 清单 ----

  /// 未删除的清单，按 sort_order、创建时间排序
  Stream<List<TaskList>> watchLists() {
    final q = _db.select(_db.taskLists)..where((l) => l.deletedAt.isNull());
    q.orderBy([
      (l) => OrderingTerm(expression: l.sortOrder),
      (l) => OrderingTerm(expression: l.createdAt),
    ]);
    return q.watch();
  }

  Future<TaskList> addList(String name) async {
    final now = nowMs();
    // 排在末尾
    final last = await (_db.selectOnly(_db.taskLists)
          ..addColumns([_db.taskLists.sortOrder.max()]))
        .map((r) => r.read(_db.taskLists.sortOrder.max()))
        .getSingleOrNull();
    final id = _uuid.v7();
    await _db.into(_db.taskLists).insert(
          TaskListsCompanion.insert(
            id: id,
            createdAt: now,
            updatedAt: now,
            name: Value(name),
            sortOrder: Value((last ?? 0) + 1),
            fieldTs: Value(FieldTs.empty
                .withWrites({'name': now, 'sort_order': now})
                .encode()),
            dirty: const Value(true),
          ),
        );
    return (await (_db.select(_db.taskLists)..where((l) => l.id.equals(id)))
        .getSingle());
  }

  Future<void> renameList(TaskList l, String name) async {
    final now = nowMs();
    await (_db.update(_db.taskLists)..where((x) => x.id.equals(l.id))).write(
      TaskListsCompanion(
        name: Value(name),
        fieldTs: Value(FieldTs.parse(l.fieldTs).withWrites({'name': now}).encode()),
        updatedAt: Value(now),
        dirty: const Value(true),
      ),
    );
  }

  /// 软删除清单（墓碑同步）。清单下的任务不连带删除，只是失去归属。
  Future<void> deleteList(TaskList l) async {
    final now = nowMs();
    await (_db.update(_db.taskLists)..where((x) => x.id.equals(l.id))).write(
      TaskListsCompanion(
        deletedAt: Value(now),
        fieldTs: Value(
            FieldTs.parse(l.fieldTs).withWrites({'deleted_at': now}).encode()),
        updatedAt: Value(now),
        dirty: const Value(true),
      ),
    );
  }

  /// 按名字找清单（快捷添加里 #家务 自动匹配）
  Future<TaskList?> findListByName(String name) {
    final q = _db.select(_db.taskLists)
      ..where((l) => l.deletedAt.isNull() & l.name.equals(name))
      ..limit(1);
    return q.getSingleOrNull();
  }

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
