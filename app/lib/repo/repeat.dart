/// 周期任务的日期推进规则（全项目唯一实现，Kotlin 侧不重复实现）。
///
/// 语义：任务完成后**原地滚到下一次**——`due_at` 推到下一次、`completed_at` 清空，
/// 不产生历史行。桌面卡片上的原生勾选只写 `completed_at`，
/// 由 App 侧的 reconcile 补齐推进（见 TaskRepository.reconcileRecurring）。
library;

/// 支持的周期单位（存库用字符串，与同步契约一致）
class RepeatUnit {
  const RepeatUnit._();

  static const day = 'day';
  static const week = 'week';
  static const month = 'month';
  static const year = 'year';

  static const all = [day, week, month, year];

  static bool isValid(String? unit) => unit != null && all.contains(unit);
}

/// 单位对应的中文名（"天/周/月/年"）
String repeatUnitName(String unit) => switch (unit) {
      RepeatUnit.day => '天',
      RepeatUnit.week => '周',
      RepeatUnit.month => '月',
      RepeatUnit.year => '年',
      _ => '',
    };

/// 列表/卡片上的短标签：每 1 天 → "每天"，每 3 周 → "每 3 周"
String repeatLabel(String? unit, int? interval) {
  if (!RepeatUnit.isValid(unit)) return '';
  final n = (interval == null || interval < 1) ? 1 : interval;
  final name = repeatUnitName(unit!);
  return n == 1 ? '每$name' : '每 $n$name';
}

/// 加 N 个月：目标月天数不足时夹到当月最后一天
/// （1/31 + 1 月 = 2/28 或 2/29，而不是溢出到 3 月）
DateTime addMonths(DateTime d, int months) {
  final total = d.month - 1 + months;
  final year = d.year + (total ~/ 12);
  final month = total % 12 + 1;
  final lastDay = DateTime(year, month + 1, 0).day;
  return DateTime(
    year,
    month,
    d.day > lastDay ? lastDay : d.day,
    d.hour,
    d.minute,
    d.second,
    d.millisecond,
  );
}

/// 从 [fromMs] 按规则向前推一次
DateTime _advance(DateTime from, String unit, int interval) => switch (unit) {
      RepeatUnit.day => from.add(Duration(days: interval)),
      RepeatUnit.week => from.add(Duration(days: 7 * interval)),
      RepeatUnit.month => addMonths(from, interval),
      RepeatUnit.year => addMonths(from, 12 * interval),
      _ => from,
    };

/// 计算下一次的 dueAt（毫秒）。
///
/// - [fromMs] 为当前的截止时间；为 null 时以"现在"为基准（首次完成就排下一次）
/// - 结果保证**严格晚于 nowMs**：任务拖了很久才勾选也不会停在过去
///   （循环推进，最多 400 次防御性上限）
/// - 非周期任务返回 null
int? nextDueAt({
  required int? fromMs,
  required String? unit,
  required int? interval,
  required int nowMs,
}) {
  if (!RepeatUnit.isValid(unit)) return null;
  final step = (interval == null || interval < 1) ? 1 : interval;
  var cursor = DateTime.fromMillisecondsSinceEpoch(fromMs ?? nowMs);
  var next = _advance(cursor, unit!, step);
  var guard = 0;
  while (next.millisecondsSinceEpoch <= nowMs && guard < 400) {
    cursor = next;
    next = _advance(cursor, unit, step);
    guard++;
  }
  return next.millisecondsSinceEpoch;
}
