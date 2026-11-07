import 'package:flutter_test/flutter_test.dart';

import 'package:todo_app/repo/reminder_time.dart';

void main() {
  group('reminderAt 提醒时刻', () {
    test('未设置提醒 / 无截止日期 → null', () {
      expect(
          reminderAt(dueAt: 1000, offsetMinutes: null, completed: false), isNull);
      expect(reminderAt(dueAt: null, offsetMinutes: 0, completed: false), isNull);
    });

    test('已完成的任务不排提醒', () {
      final due = DateTime(2026, 5, 20, 18).millisecondsSinceEpoch;
      expect(
          reminderAt(dueAt: due, offsetMinutes: 0, completed: true), isNull);
    });

    test('有具体时间：准时 / 提前 10 分钟 / 提前 1 小时', () {
      final due = DateTime(2026, 5, 20, 18, 30).millisecondsSinceEpoch;
      expect(reminderAt(dueAt: due, offsetMinutes: 0, completed: false),
          DateTime(2026, 5, 20, 18, 30));
      expect(reminderAt(dueAt: due, offsetMinutes: 10, completed: false),
          DateTime(2026, 5, 20, 18, 20));
      expect(reminderAt(dueAt: due, offsetMinutes: 60, completed: false),
          DateTime(2026, 5, 20, 17, 30));
    });

    test('日期型任务（00:00）按当天 09:00 起算，不会半夜响', () {
      final due = DateTime(2026, 5, 20).millisecondsSinceEpoch;
      expect(reminderAt(dueAt: due, offsetMinutes: 0, completed: false),
          DateTime(2026, 5, 20, 9));
      expect(reminderAt(dueAt: due, offsetMinutes: 60, completed: false),
          DateTime(2026, 5, 20, 8));
      // 提前一天 = 前一天 09:00
      expect(reminderAt(dueAt: due, offsetMinutes: 1440, completed: false),
          DateTime(2026, 5, 19, 9));
    });

    test('展示文案', () {
      expect(reminderLabel(null), '关闭');
      expect(reminderLabel(0), '准时');
      expect(reminderLabel(60), '提前 1 小时');
      expect(reminderLabel(1440), '提前 1 天');
      expect(reminderLabel(25), '提前 25 分钟');
    });
  });
}
