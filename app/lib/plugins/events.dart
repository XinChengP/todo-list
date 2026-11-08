import '../db/database.dart' show Task;

/// 任务事件类型。对外（webhook/插件）的 wire 名是 `task.<type>`。
enum TaskEventType { created, updated, completed, uncompleted, deleted, restored }

extension TaskEventTypeX on TaskEventType {
  /// 对外事件名（webhook payload 里的 event 字段）
  String get wireName => 'task.$name';

  /// 中文说明（设置界面用）
  String get label => switch (this) {
        TaskEventType.created => '新建任务',
        TaskEventType.updated => '修改任务',
        TaskEventType.completed => '完成任务',
        TaskEventType.uncompleted => '取消完成',
        TaskEventType.deleted => '删除任务',
        TaskEventType.restored => '恢复任务',
      };
}

/// 任务事件：插件/webhook 的统一输入。
/// [task] 是**事件发生后的最终状态**（本地库里的当前值）。
class TaskEvent {
  const TaskEvent(this.type, this.task, this.at);

  final TaskEventType type;
  final Task task;
  final int at;

  Map<String, dynamic> taskJson() => {
        'id': task.id,
        'title': task.title,
        'notes': task.notes,
        'list_id': task.listId,
        'due_at': task.dueAt,
        'priority': task.priority,
        'completed_at': task.completedAt,
        'deleted_at': task.deletedAt,
        'repeat_rule': task.repeatRule,
        'repeat_unit': task.repeatUnit,
        'repeat_interval': task.repeatInterval,
        'remind_offset': task.remindOffset,
        'remind_at': task.remindAt,
      };

  Map<String, dynamic> toJson() => {
        'event': type.wireName,
        'at': at,
        'task': taskJson(),
      };
}
