/// 截止日期的简短展示：今天 / 明天 / 昨天 / M/d
String dueLabel(int ms) {
  final d = DateTime.fromMillisecondsSinceEpoch(ms);
  final today = DateTime.now();
  final diff = DateTime(d.year, d.month, d.day)
      .difference(DateTime(today.year, today.month, today.day))
      .inDays;
  if (diff == 0) return '今天';
  if (diff == 1) return '明天';
  if (diff == -1) return '昨天';
  return '${d.month}/${d.day}';
}

bool isOverdue(int ms) {
  final d = DateTime.fromMillisecondsSinceEpoch(ms);
  final today = DateTime.now();
  return DateTime(d.year, d.month, d.day)
      .isBefore(DateTime(today.year, today.month, today.day));
}
