/// 截止时间的展示与判定（支持精确到分钟）
library;

/// 是否带具体时间（00:00 视为"只选了日期"）
bool hasTimeOfDay(int ms) {
  final d = DateTime.fromMillisecondsSinceEpoch(ms);
  return d.hour != 0 || d.minute != 0;
}

String _two(int v) => v.toString().padLeft(2, '0');

String _datePart(DateTime d) {
  final today = DateTime.now();
  final diff = DateTime(d.year, d.month, d.day)
      .difference(DateTime(today.year, today.month, today.day))
      .inDays;
  if (diff == 0) return '今天';
  if (diff == 1) return '明天';
  if (diff == -1) return '昨天';
  return '${d.month}/${d.day}';
}

/// 截止时间展示：`今天 18:30` / `明天` / `11/5`
String dueLabel(int ms) {
  final d = DateTime.fromMillisecondsSinceEpoch(ms);
  final base = _datePart(d);
  return hasTimeOfDay(ms) ? '$base ${_two(d.hour)}:${_two(d.minute)}' : base;
}

/// 是否逾期。
/// - 带具体时间：按时间点比较（今天 09:00 的任务 09:01 就算逾期）
/// - 只选日期：过了当天才算逾期（不因为"今天还没过完"就标红）
bool isOverdue(int ms) {
  final d = DateTime.fromMillisecondsSinceEpoch(ms);
  if (hasTimeOfDay(ms)) return d.isBefore(DateTime.now());
  final today = DateTime.now();
  return DateTime(d.year, d.month, d.day)
      .isBefore(DateTime(today.year, today.month, today.day));
}

/// 桌面卡片用的短标签：`11/5 18:30` / `11/5`
String dueShort(int ms) {
  final d = DateTime.fromMillisecondsSinceEpoch(ms);
  return hasTimeOfDay(ms)
      ? '${d.month}/${d.day} ${_two(d.hour)}:${_two(d.minute)}'
      : '${d.month}/${d.day}';
}
