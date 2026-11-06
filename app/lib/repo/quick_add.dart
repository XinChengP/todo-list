/// 快捷添加语法解析（纯函数，可单测）。
///
/// 输入：`买牛奶 明天18点 !高 #家务 每周`
/// 输出：标题「买牛奶」+ 明天 18:00 截止 + 优先级 3 + 清单「家务」+ 每周重复
///
/// 支持：
///   清单  `#家务`（不存在时按名字新建）
///   优先级 `!高` `!中` `!低` `!1` `!2` `!3`
///   周期  `每天` `每周` `每月` `每年` `每3天` `每2周`
///   日期  `今天` `明天` `后天` `大后天` `周三` `下周三` `本周三` `11月5日` `11/5`
///   时间  `18点` `18:30` `下午3点` `晚上8点` `9点半`
library;

import 'repeat.dart';

class QuickAddResult {
  const QuickAddResult({
    required this.title,
    this.dueAt,
    this.priority = 0,
    this.listName,
    this.repeat,
  });

  final String title;
  final int? dueAt;
  final int priority;
  final String? listName;
  final RepeatRule? repeat;

  bool get hasExtras =>
      dueAt != null || priority > 0 || listName != null || repeat != null;
}

const _unitMap = {'天': 'day', '周': 'week', '月': 'month', '年': 'year'};
const _weekdayMap = {
  '一': 1, '二': 2, '三': 3, '四': 4, '五': 5, '六': 6, '日': 7, '天': 7,
};
const _periodMap = {'上午': 0, '早上': 0, '下午': 12, '晚上': 12};

/// 解析输入；[now] 可注入，便于测试
QuickAddResult parseQuickAdd(String input, {DateTime? now}) {
  final clock = now ?? DateTime.now();
  var text = input;

  String? listName;
  var priority = 0;
  RepeatRule? repeat;
  DateTime? date;
  int? hour;
  int? minute;

  // 清单 #名称
  final listMatch = RegExp(r'#([^\s#]+)').firstMatch(text);
  if (listMatch != null) {
    listName = listMatch.group(1);
    text = text.replaceRange(listMatch.start, listMatch.end, ' ');
  }

  // 优先级 !高/!中/!低/!1-3
  final priMatch = RegExp(r'!([高中低1-3])').firstMatch(text);
  if (priMatch != null) {
    priority = switch (priMatch.group(1)!) {
      '高' || '3' => 3,
      '中' || '2' => 2,
      _ => 1,
    };
    text = text.replaceRange(priMatch.start, priMatch.end, ' ');
  }

  // 周期：工作日 / 每月最后一天 / 每周一三五 / 每月5号 / 每3天 …
  final workday = RegExp(r'工作日').firstMatch(text);
  if (workday != null) {
    repeat = const RepeatRule(unit: 'week', weekdays: [1, 2, 3, 4, 5]);
    text = text.replaceRange(workday.start, workday.end, ' ');
  }

  if (repeat == null) {
    final lastDay = RegExp(r'每月(?:的)?最后一[天日]').firstMatch(text);
    if (lastDay != null) {
      repeat = const RepeatRule(unit: 'month', monthMode: 'last');
      text = text.replaceRange(lastDay.start, lastDay.end, ' ');
    }
  }

  if (repeat == null) {
    // 每周一、三、五 / 每星期一三五
    final wk = RegExp(r'每(?:周|星期)([一二三四五六日天、,，\s]+)').firstMatch(text);
    if (wk != null) {
      final days = <int>[];
      for (final ch in wk.group(1)!.split('')) {
        final d = _weekdayMap[ch];
        if (d != null && !days.contains(d)) days.add(d);
      }
      if (days.isNotEmpty) {
        days.sort();
        repeat = RepeatRule(unit: 'week', weekdays: days);
        text = text.replaceRange(wk.start, wk.end, ' ');
      }
    }
  }

  if (repeat == null) {
    // 每月 5 号
    final md = RegExp(r'每月(\d{1,2})[号日]').firstMatch(text);
    if (md != null) {
      final day = int.tryParse(md.group(1)!);
      if (day != null && day >= 1 && day <= 31) {
        repeat = RepeatRule(unit: 'month', monthMode: 'dom', anchorDay: day);
        text = text.replaceRange(md.start, md.end, ' ');
      }
    }
  }

  if (repeat == null) {
    final repMatch = RegExp(r'每(\d{1,2})?(天|周|月|年)').firstMatch(text);
    if (repMatch != null) {
      final unit = _unitMap[repMatch.group(2)!];
      var n = int.tryParse(repMatch.group(1) ?? '1') ?? 1;
      if (n < 1) n = 1;
      if (n > 99) n = 99;
      repeat = RepeatRule(unit: unit!, n: n);
      text = text.replaceRange(repMatch.start, repMatch.end, ' ');
    }
  }

  // 时间 18:30 / 18点 / 9点半 / 下午3点
  final timeMatch = RegExp(r'(上午|早上|下午|晚上)?\s*(\d{1,2})\s*(?:[:：](\d{2})|点(半)?)')
      .firstMatch(text);
  if (timeMatch != null) {
    var h = int.parse(timeMatch.group(2)!);
    final period = timeMatch.group(1);
    if (period != null && h < 12) h += _periodMap[period]!;
    if (h >= 0 && h <= 23) {
      hour = h;
      minute = timeMatch.group(4) == '半' ? 30 : (int.tryParse(timeMatch.group(3) ?? '') ?? 0);
      text = text.replaceRange(timeMatch.start, timeMatch.end, ' ');
    }
  }

  // 日期
  // 注意：(下|本)? 而不是 (下周|本周)?——中文写法是「下」+「周一」，
  // 不是「下周」+「一」，写成后者会匹配失败退化成「周一」。
  final dateMatch = RegExp(
    r'(大后天|后天|明天|今天|(下|本)?(?:周|星期)([一二三四五六日天])|(\d{1,2})月(\d{1,2})[日号]?|(\d{1,2})/(\d{1,2}))',
  ).firstMatch(text);
  if (dateMatch != null) {
    date = _parseDate(dateMatch, clock);
    text = text.replaceRange(dateMatch.start, dateMatch.end, ' ');
  }

  int? dueAt;
  if (date != null || hour != null) {
    final base = date ?? DateTime(clock.year, clock.month, clock.day);
    // 未写时间时用 09:00（逾期判定按天，时间只影响未来提醒）
    dueAt = DateTime(base.year, base.month, base.day, hour ?? 9, minute ?? 0)
        .millisecondsSinceEpoch;
  }

  final title = text.replaceAll(RegExp(r'\s+'), ' ').trim();
  return QuickAddResult(
    title: title,
    dueAt: dueAt,
    priority: priority,
    listName: listName,
    repeat: repeat,
  );
}

DateTime? _parseDate(RegExpMatch m, DateTime now) {
  final whole = m.group(1)!;
  final base = DateTime(now.year, now.month, now.day);
  switch (whole) {
    case '今天':
      return base;
    case '明天':
      return base.add(const Duration(days: 1));
    case '后天':
      return base.add(const Duration(days: 2));
    case '大后天':
      return base.add(const Duration(days: 3));
  }
  // M月D日 / M/D
  final md1 = m.group(4);
  if (md1 != null) {
    final month = int.parse(md1);
    final day = int.parse(m.group(5)!);
    var d = _safeDate(now.year, month, day);
    if (d.isBefore(base)) d = _safeDate(now.year + 1, month, day);
    return d;
  }
  final md2 = m.group(6);
  if (md2 != null) {
    final month = int.parse(md2);
    final day = int.parse(m.group(7)!);
    var d = _safeDate(now.year, month, day);
    if (d.isBefore(base)) d = _safeDate(now.year + 1, month, day);
    return d;
  }
  // 周X / 本周X / 下周X
  final wd = _weekdayMap[m.group(3)!]!;
  final prefix = m.group(2);
  final monday0 = base.subtract(Duration(days: base.weekday - 1));
  if (prefix == '下') return monday0.add(Duration(days: 7 + wd - 1));
  if (prefix == '本') return monday0.add(Duration(days: wd - 1));
  // 只写「周X」：取最近一次（含今天）
  var d = base.add(Duration(days: (wd - base.weekday) % 7));
  return d;
}

DateTime _safeDate(int year, int month, int day) {
  final lastDay = DateTime(year, month + 1, 0).day;
  return DateTime(year, month, day > lastDay ? lastDay : day);
}
