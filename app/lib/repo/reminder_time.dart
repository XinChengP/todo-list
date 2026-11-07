import '../db/database.dart' show Task;

/// 提醒时刻计算（纯函数，可单测；不依赖通知插件）
///
/// 规则：提醒时刻 = 截止时间 - 提前分钟数。
/// 日期型任务（due 恰好 00:00）按当天 09:00 起算，避免半夜弹通知。
DateTime? reminderAt({
  required int? dueAt,
  required int? offsetMinutes,
  required bool completed,
}) {
  if (dueAt == null || offsetMinutes == null || completed) return null;
  var base = DateTime.fromMillisecondsSinceEpoch(dueAt);
  if (base.hour == 0 && base.minute == 0) {
    base = DateTime(base.year, base.month, base.day, 9);
  }
  return base.subtract(Duration(minutes: offsetMinutes));
}

int? reminderAtMs({
  required int? dueAt,
  required int? offsetMinutes,
  required bool completed,
}) =>
    reminderAt(dueAt: dueAt, offsetMinutes: offsetMinutes, completed: completed)
        ?.millisecondsSinceEpoch;

/// 常用档位（分钟）
const kReminderPresets = <int, String>{
  0: '准时',
  10: '提前 10 分钟',
  60: '提前 1 小时',
  1440: '提前 1 天',
};

/// 提醒时刻的展示文案：null → 关闭
String reminderLabel(int? offsetMinutes) {
  if (offsetMinutes == null) return '关闭';
  return kReminderPresets[offsetMinutes] ?? '提前 $offsetMinutes 分钟';
}

/// 任务是否设了提醒
bool hasReminder(Task t) => t.remindOffset != null && t.dueAt != null;
