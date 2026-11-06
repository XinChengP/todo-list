/// 周期任务规则引擎（全项目唯一实现，Kotlin 侧不重复）。
///
/// 规则以 JSON 存进 `tasks.repeat_rule`，例如：
///   {"unit":"week","n":1,"weekdays":[1,3,5]}                 每周一/三/五
///   {"unit":"week","n":2,"weekdays":[2]}                      每两周的周二
///   {"unit":"month","n":1,"monthMode":"dom","anchorDay":31}   每月 31 号（月末夹紧且不漂移）
///   {"unit":"month","n":1,"monthMode":"last"}                每月最后一天
///   {"unit":"month","n":1,"monthMode":"dow","dowIndex":2,"weekdays":[3]}  每月第 2 个周三
///   {"unit":"day","n":3}                                     每 3 天
///   {"unit":"year","n":1,"month":5,"anchorDay":1}            每年 5 月 1 日
/// 结束条件（可选）："until":<毫秒> / "max":<次数>
///
/// 兼容旧数据：老版本只存 repeat_unit + repeat_interval，
/// 读取时用 [RepeatRule.fromLegacy] 合成规则，不做破坏性迁移。
library;

import 'dart:convert';

/// 逾期策略：勾选周期任务时如何安排下一次（本地设置，不参与同步）
enum RepeatCatchup {
  /// 直接滚到未来（默认，任务不会长期显示逾期）
  skip,

  /// 只前进一个周期（仍显示逾期，强调"欠了几次"）
  once,

  /// 滚到今天或之后
  today,
}

class RepeatRule {
  const RepeatRule({
    required this.unit,
    this.n = 1,
    this.weekdays = const [],
    this.monthMode = 'dom',
    this.dowIndex,
    this.anchorDay,
    this.month,
    this.until,
    this.max,
  });

  /// day / week / month / year
  final String unit;

  /// 间隔，≥1
  final int n;

  /// week / dow 模式的星期几（1=周一 … 7=周日）
  final List<int> weekdays;

  /// month 模式：'dom' 指定日 / 'last' 月末 / 'dow' 第 N 个周几
  final String monthMode;

  /// monthMode == 'dow' 时的第几个（1..4；-1 表示最后一个）
  final int? dowIndex;

  /// 锚点日（1..31）。月末夹紧但**不漂移**：1/31 → 2/28 → 3/31
  final int? anchorDay;

  /// year 模式的月份（1..12）
  final int? month;

  /// 结束条件：到某时刻为止（毫秒）
  final int? until;

  /// 结束条件：总共完成多少次
  final int? max;

  bool get hasEnd => until != null || max != null;

  static const _units = {'day', 'week', 'month', 'year'};
  static bool isValidUnit(String? u) => u != null && _units.contains(u);

  RepeatRule copyWith({int? until, int? max, int? anchorDay}) => RepeatRule(
        unit: unit,
        n: n,
        weekdays: weekdays,
        monthMode: monthMode,
        dowIndex: dowIndex,
        anchorDay: anchorDay ?? this.anchorDay,
        month: month,
        until: until ?? this.until,
        max: max ?? this.max,
      );

  // ---------- 编解码 ----------

  Map<String, dynamic> toJson() => {
        'unit': unit,
        'n': n,
        if (weekdays.isNotEmpty) 'weekdays': weekdays,
        if (unit == 'month') 'monthMode': monthMode,
        if (dowIndex != null) 'dowIndex': dowIndex,
        if (anchorDay != null) 'anchorDay': anchorDay,
        if (month != null) 'month': month,
        if (until != null) 'until': until,
        if (max != null) 'max': max,
      };

  String encode() => jsonEncode(toJson());

  static RepeatRule? parse(String? raw) {
    if (raw == null || raw.trim().isEmpty) return null;
    try {
      final map = jsonDecode(raw);
      if (map is! Map) return null;
      final unit = map['unit'] as String?;
      if (!isValidUnit(unit)) return null;
      return RepeatRule(
        unit: unit!,
        n: (_int(map['n']) ?? 1).clamp(1, 99),
        weekdays: [
          for (final w in (map['weekdays'] as List? ?? const []))
            if ((_int(w) ?? 0) >= 1 && (_int(w) ?? 0) <= 7) _int(w)!,
        ],
        monthMode: (map['monthMode'] as String?) ?? 'dom',
        dowIndex: _int(map['dowIndex']),
        anchorDay: _int(map['anchorDay'])?.clamp(1, 31),
        month: _int(map['month'])?.clamp(1, 12),
        until: _int(map['until']),
        max: _int(map['max']),
      );
    } catch (_) {
      return null;
    }
  }

  /// 老字段（repeat_unit / repeat_interval）→ 规则
  static RepeatRule? fromLegacy(String? unit, int? interval) {
    if (!isValidUnit(unit)) return null;
    return RepeatRule(unit: unit!, n: (interval ?? 1).clamp(1, 99));
  }

  // ---------- 展示 ----------

  static const _wdNames = ['一', '二', '三', '四', '五', '六', '日'];

  String describe() {
    final buf = StringBuffer();
    switch (unit) {
      case 'day':
        buf.write(n == 1 ? '每天' : '每 $n 天');
      case 'week':
        final days =
            weekdays.isEmpty ? '' : weekdays.map((w) => '周${_wdNames[w - 1]}').join('、');
        if (n == 1) {
          buf.write(days.isEmpty ? '每周' : days);
        } else {
          buf.write('每 $n 周${days.isEmpty ? '' : '（$days）'}');
        }
      case 'month':
        final prefix = n == 1 ? '每月' : '每 $n 月';
        switch (monthMode) {
          case 'last':
            buf.write('$prefix最后一天');
          case 'dow':
            final idx = dowIndex == -1 ? '最后一个' : '第 $dowIndex 个';
            final wd = weekdays.isEmpty ? '' : '周${_wdNames[weekdays.first - 1]}';
            buf.write('$prefix$idx$wd');
          default:
            buf.write('$prefix${anchorDay ?? 1} 号');
        }
      case 'year':
        buf.write('每年 ${month ?? 1} 月 ${anchorDay ?? 1} 日');
    }
    if (max != null) buf.write(' · 共 $max 次');
    if (until != null) {
      final d = DateTime.fromMillisecondsSinceEpoch(until!);
      buf.write(' · 至 ${d.month}/${d.day}');
    }
    return buf.toString();
  }
}

// ---------- 兼容旧 API（旧调用点仍在用） ----------

class RepeatUnit {
  const RepeatUnit._();
  static const day = 'day';
  static const week = 'week';
  static const month = 'month';
  static const year = 'year';
  static const all = [day, week, month, year];
  static bool isValid(String? unit) => RepeatRule.isValidUnit(unit);
}

String repeatUnitName(String unit) => switch (unit) {
      RepeatUnit.day => '天',
      RepeatUnit.week => '周',
      RepeatUnit.month => '月',
      RepeatUnit.year => '年',
      _ => '',
    };

/// 从行里的两个来源解析规则（新 JSON 优先，回退旧字段）
RepeatRule? resolveRule(String? ruleJson, String? legacyUnit, int? legacyInterval) =>
    RepeatRule.parse(ruleJson) ?? RepeatRule.fromLegacy(legacyUnit, legacyInterval);

/// 列表/卡片短标签（旧字段形态 → 文案）
String repeatLabel(String? unit, int? interval) {
  final rule = RepeatRule.fromLegacy(unit, interval);
  return rule?.describe() ?? '';
}

/// 旧接口：单步推进（不带结束条件/日志）
int? nextDueAt({
  required int? fromMs,
  required String? unit,
  required int? interval,
  required int nowMs,
}) {
  final rule = RepeatRule.fromLegacy(unit, interval);
  if (rule == null) return null;
  final from = DateTime.fromMillisecondsSinceEpoch(fromMs ?? nowMs);
  final next = nextAfter(rule, from: from, now: DateTime.fromMillisecondsSinceEpoch(nowMs));
  return next?.millisecondsSinceEpoch;
}

// ---------- 日期计算 ----------

DateTime addMonths(DateTime d, int months) {
  final total = d.month - 1 + months;
  final year = d.year + (total ~/ 12);
  final month = total % 12 + 1;
  final lastDay = DateTime(year, month + 1, 0).day;
  return DateTime(year, month, d.day > lastDay ? lastDay : d.day, d.hour,
      d.minute, d.second, d.millisecond);
}

DateTime _withDay(DateTime base, int year, int month, int day) {
  final lastDay = DateTime(year, month + 1, 0).day;
  return DateTime(year, month, day > lastDay ? lastDay : day, base.hour,
      base.minute, base.second, base.millisecond);
}

DateTime _lastDayOf(DateTime base, int year, int month) {
  final last = DateTime(year, month + 1, 0);
  return DateTime(last.year, last.month, last.day, base.hour, base.minute,
      base.second, base.millisecond);
}

DateTime? _nthWeekday(DateTime base, int year, int month, int wd, int index) {
  if (index == -1) {
    final last = DateTime(year, month + 1, 0);
    final delta = (last.weekday - wd + 7) % 7;
    return DateTime(year, month, last.day - delta, base.hour, base.minute,
        base.second, base.millisecond);
  }
  final first = DateTime(year, month, 1);
  final delta = (wd - first.weekday + 7) % 7;
  final day = 1 + delta + (index - 1) * 7;
  final lastDay = DateTime(year, month + 1, 0).day;
  if (day > lastDay) return null;
  return DateTime(year, month, day, base.hour, base.minute, base.second,
      base.millisecond);
}

/// 从 [from] 之后按规则找下一次。
/// [catchUp] 为 true（默认）会一直推进到严格晚于 [now]，避免停在过去。
DateTime? nextAfter(
  RepeatRule r, {
  required DateTime from,
  DateTime? now,
  bool catchUp = true,
}) {
  final deadline = now ?? DateTime.now();
  var cursor = from;
  for (var guard = 0; guard < 500; guard++) {
    final next = _step(r, cursor, from);
    if (next == null) return null;
    cursor = next;
    if (!catchUp || cursor.isAfter(deadline)) return cursor;
  }
  return cursor;
}

DateTime? _step(RepeatRule r, DateTime cursor, DateTime origin) {
  switch (r.unit) {
    case 'day':
      return cursor.add(Duration(days: r.n));

    case 'week':
      final days =
          r.weekdays.isEmpty ? [origin.weekday] : (r.weekdays.toList()..sort());
      final originMonday = origin.subtract(Duration(days: origin.weekday - 1));
      var d = cursor.add(const Duration(days: 1));
      for (var i = 0; i < 400; i++) {
        final monday = d.subtract(Duration(days: d.weekday - 1));
        final weeks = monday.difference(originMonday).inDays ~/ 7;
        if (weeks >= 0 && weeks % r.n == 0 && days.contains(d.weekday)) return d;
        d = d.add(const Duration(days: 1));
      }
      return null;

    case 'month':
      final anchor = r.anchorDay ?? origin.day;
      // k 从 0 开始：本月里还没到的那个日期也算"下一次"
      // （2/10 的"每月月末"应该是 2/28，而不是跳到 3/31）
      for (var k = 0; k <= 24; k++) {
        final probe = addMonths(DateTime(origin.year, origin.month, 1), r.n * k);
        DateTime? candidate;
        switch (r.monthMode) {
          case 'last':
            candidate = _lastDayOf(cursor, probe.year, probe.month);
          case 'dow':
            final wd = r.weekdays.isEmpty ? origin.weekday : r.weekdays.first;
            candidate =
                _nthWeekday(cursor, probe.year, probe.month, wd, r.dowIndex ?? 1);
          default:
            candidate = _withDay(cursor, probe.year, probe.month, anchor);
        }
        if (candidate != null && candidate.isAfter(cursor)) return candidate;
      }
      return null;

    case 'year':
      final m = r.month ?? origin.month;
      final d = r.anchorDay ?? origin.day;
      for (var k = 1; k <= 20; k++) {
        final candidate = _withDay(cursor, origin.year + k * r.n, m, d);
        if (candidate.isAfter(cursor)) return candidate;
      }
      return null;

    default:
      return null;
  }
}

int? _int(Object? v) => v is int ? v : (v is num ? v.toInt() : int.tryParse('$v'));
