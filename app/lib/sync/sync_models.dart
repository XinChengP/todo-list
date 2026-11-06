import 'package:drift/drift.dart';

import '../db/database.dart';
import '../db/sync_fields.dart';

typedef FieldValue = ({Object? v, int at});

/// 可同步字段与本地列的映射（与服务端 model.ts 的字段规格一致）
const kTaskFields = [
  'title',
  'notes',
  'list_id',
  'due_at',
  'remind_at',
  'priority',
  'completed_at',
  'deleted_at',
  'repeat_unit',
  'repeat_interval',
  'repeat_rule',
  'repeat_done',
];
const kListFields = ['name', 'sort_order', 'deleted_at'];

/// 本地任务行 → 协议行（server/README「数据行格式」）
Map<String, dynamic> taskToProtocol(Task t) {
  final fts = FieldTs.parse(t.fieldTs);
  return {
    'id': t.id,
    'created_at': t.createdAt,
    'fields': {
      for (final f in kTaskFields)
        f: {
          'v': _localValue(t, f),
          'at': fts[f],
        },
    },
  };
}

Object? _localValue(Task t, String f) => switch (f) {
      'title' => t.title,
      'notes' => t.notes,
      'list_id' => t.listId,
      'due_at' => t.dueAt,
      'remind_at' => t.remindAt,
      'priority' => t.priority,
      'completed_at' => t.completedAt,
      'deleted_at' => t.deletedAt,
      'repeat_unit' => t.repeatUnit,
      'repeat_interval' => t.repeatInterval,
      'repeat_rule' => t.repeatRule,
      'repeat_done' => t.repeatDone,
      _ => null,
    };

/// 本地清单行 → 协议行
Map<String, dynamic> listToProtocol(TaskList l) {
  final fts = FieldTs.parse(l.fieldTs);
  return {
    'id': l.id,
    'created_at': l.createdAt,
    'fields': {
      for (final f in kListFields)
        f: {
          'v': switch (f) {
            'name' => l.name,
            'sort_order' => l.sortOrder,
            'deleted_at' => l.deletedAt,
            _ => null,
          },
          'at': fts[f],
        },
    },
  };
}

/// 解析协议行的 fields：{ 字段: (v, at) }。
/// 服务器总是返回全部字段；缺失字段按 (null, 0) 兜底。
Map<String, FieldValue> parseProtocolFields(
    Map<String, dynamic> remote, List<String> fieldNames) {
  final raw = (remote['fields'] as Map?)?.cast<String, dynamic>() ?? const {};
  final out = <String, FieldValue>{
    for (final e in raw.entries)
      e.key: (
        v: (e.value as Map?)?['v'],
        at: ((e.value as Map?)?['at'] as num?)?.toInt() ?? 0,
      ),
  };
  for (final f in fieldNames) {
    out.putIfAbsent(f, () => (v: null, at: 0));
  }
  return out;
}

FieldTs fieldTsFromProtocol(Map<String, FieldValue> fields) =>
    FieldTs({for (final e in fields.entries) e.key: e.value.at});

/// 把协议字段值落到 TasksCompanion（类型收敛与服务器校验规则一致）
TasksCompanion applyTaskField(TasksCompanion c, String f, Object? v) =>
    switch (f) {
      'title' => c.copyWith(title: Value((v as String?) ?? '')),
      'notes' => c.copyWith(notes: Value((v as String?) ?? '')),
      'list_id' => c.copyWith(listId: Value(v as String?)),
      'due_at' => c.copyWith(dueAt: Value((v as num?)?.toInt())),
      'remind_at' => c.copyWith(remindAt: Value((v as num?)?.toInt())),
      'priority' => c.copyWith(priority: Value((v as num?)?.toInt() ?? 0)),
      'completed_at' => c.copyWith(completedAt: Value((v as num?)?.toInt())),
      'deleted_at' => c.copyWith(deletedAt: Value((v as num?)?.toInt())),
      'repeat_unit' => c.copyWith(repeatUnit: Value(v as String?)),
      'repeat_interval' => c.copyWith(repeatInterval: Value((v as num?)?.toInt())),
      'repeat_rule' => c.copyWith(repeatRule: Value(v as String?)),
      'repeat_done' => c.copyWith(repeatDone: Value((v as num?)?.toInt())),
      _ => throw StateError('tasks 未知字段：$f'),
    };

/// 把协议字段值落到 TaskListsCompanion
TaskListsCompanion applyListField(TaskListsCompanion c, String f, Object? v) =>
    switch (f) {
      'name' => c.copyWith(name: Value((v as String?) ?? '')),
      'sort_order' => c.copyWith(sortOrder: Value((v as num?)?.toInt() ?? 0)),
      'deleted_at' => c.copyWith(deletedAt: Value((v as num?)?.toInt())),
      _ => throw StateError('lists 未知字段：$f'),
    };

// ---------- 完成日志 ----------

const kLogFields = ['task_id', 'title', 'due_at', 'completed_at', 'deleted_at'];

Map<String, dynamic> logToProtocol(TaskLog l) {
  final fts = FieldTs.parse(l.fieldTs);
  return {
    'id': l.id,
    'created_at': l.createdAt,
    'fields': {
      for (final f in kLogFields)
        f: {
          'v': switch (f) {
            'task_id' => l.taskId,
            'title' => l.title,
            'due_at' => l.dueAt,
            'completed_at' => l.completedAt,
            'deleted_at' => l.deletedAt,
            _ => null,
          },
          'at': fts[f],
        },
    },
  };
}

TaskLogsCompanion applyLogField(TaskLogsCompanion c, String f, Object? v) =>
    switch (f) {
      'task_id' => c.copyWith(taskId: Value((v as String?) ?? '')),
      'title' => c.copyWith(title: Value((v as String?) ?? '')),
      'due_at' => c.copyWith(dueAt: Value((v as num?)?.toInt())),
      'completed_at' =>
        c.copyWith(completedAt: Value(((v as num?) ?? 0).toInt())),
      'deleted_at' => c.copyWith(deletedAt: Value((v as num?)?.toInt())),
      _ => throw StateError('logs 未知字段：$f'),
    };
