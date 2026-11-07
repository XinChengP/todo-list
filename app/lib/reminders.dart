import 'dart:async';
import 'dart:io' show Platform;

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:local_notifier/local_notifier.dart';
import 'package:flutter_timezone/flutter_timezone.dart';
import 'package:timezone/data/latest_all.dart' as tzdata;
import 'package:timezone/timezone.dart' as tz;

import 'db/database.dart' show Task;
import 'repo/reminder_time.dart';

/// 到点提醒（Android 系统通知 / Windows 通知中心）
///
/// 设计：
/// - 数据只存 `remind_offset`（提前分钟数），绝对时刻由 `due_at - offset` 推导，
///   所以周期任务滚动到下一次后，提醒会自动跟着走
/// - 日期型任务（due 为 00:00）按当天 09:00 提醒，避免半夜弹通知
/// - 每次任务变化后整体重排（先 cancelAll 再排未来 30 天内的），做 1.5s 防抖
/// - 所有平台调用都吞异常：通知失败绝不能影响主流程
class ReminderService {
  ReminderService._();

  static final FlutterLocalNotificationsPlugin _plugin =
      FlutterLocalNotificationsPlugin();
  static bool _ready = false;
  static Timer? _debounce;
  static bool _hasScheduled = false;

  /// Windows 用进程内 Timer（悬浮窗/托盘常驻，进程活着就能弹）
  static final List<Timer> _winTimers = [];
  static const _channelId = 'todo_reminders';

  static bool get supported =>
      !kIsWeb && (Platform.isAndroid || Platform.isWindows);

  static Future<void> ensureInit() async {
    if (_ready || !supported) return;
    if (Platform.isWindows) {
      try {
        await localNotifier.setup(appName: '任务清单');
        _ready = true;
      } catch (_) {
        _ready = false;
      }
      return;
    }
    tzdata.initializeTimeZones();
    try {
      final info = await FlutterTimezone.getLocalTimezone();
      tz.setLocalLocation(tz.getLocation(info.identifier));
    } catch (_) {
      // 拿不到时区就退回 UTC：提醒时间可能偏，但不至于崩
    }
    try {
      // v18 只支持 Android/iOS/macOS/Linux；Windows 端用 local_notifier
      await _plugin.initialize(
        const InitializationSettings(
          android: AndroidInitializationSettings('@mipmap/ic_launcher'),
        ),
      );
      _ready = true;
    } catch (_) {
      _ready = false;
    }
  }

  /// 请求通知权限（Android 13+ 运行时权限 + 精确闹钟）。返回是否可用。
  static Future<bool> requestPermission() async {
    if (!supported) return false;
    await ensureInit();
    if (Platform.isWindows) return true;
    try {
      final android = _plugin.resolvePlatformSpecificImplementation<
          AndroidFlutterLocalNotificationsPlugin>();
      final granted = await android?.requestNotificationsPermission() ?? true;
      try {
        await android?.requestExactAlarmsPermission();
      } catch (_) {}
      return granted;
    } catch (_) {
      return false;
    }
  }

  static int _idFor(String id) => id.hashCode & 0x7fffffff;

  /// 任务变化后调用：防抖后整体重排（先清空再排未来 60 天）。
  ///
  /// 没有任何提醒时直接返回：既省电，也避免为无关变化反复 cancelAll/重排
  /// （清理最后一条提醒时会走一次 cancelAll，见 _rescheduleAll）。
  static void schedule(List<Task> activeTasks) {
    if (!supported) return;
    final anyReminder = activeTasks.any((t) =>
        t.remindOffset != null && t.dueAt != null && t.completedAt == null);
    if (!anyReminder && !_hasScheduled) return;
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 1500), () {
      unawaited(_rescheduleAll(activeTasks));
    });
  }

  static Future<void> _rescheduleAll(List<Task> tasks) async {
    await ensureInit();
    if (!_ready) return;
    if (Platform.isWindows) {
      _rescheduleWindows(tasks);
      return;
    }
    try {
      await _plugin.cancelAll();
    } catch (_) {}
    var scheduled = 0;
    final now = DateTime.now();
    final horizon = now.add(const Duration(days: 60));
    for (final t in tasks) {
      final when = reminderAt(
        dueAt: t.dueAt,
        offsetMinutes: t.remindOffset,
        completed: t.completedAt != null || t.deletedAt != null,
      );
      if (when == null || !when.isAfter(now) || when.isAfter(horizon)) continue;
      try {
        await _plugin.zonedSchedule(
          _idFor(t.id),
          '该做「${t.title}」了',
          t.repeatRule == null && t.repeatUnit == null
              ? '点开查看任务清单'
              : '周期任务 · 完成后自动排下一次',
          tz.TZDateTime.from(when, tz.local),
          const NotificationDetails(
            android: AndroidNotificationDetails(
              _channelId,
              '到点提醒',
              channelDescription: '任务截止时间提醒',
              importance: Importance.high,
              priority: Priority.high,
            ),
          ),
          uiLocalNotificationDateInterpretation:
              UILocalNotificationDateInterpretation.absoluteTime,
          androidScheduleMode: AndroidScheduleMode.exactAllowWhileIdle,
          payload: t.id,
        );
        scheduled++;
      } catch (_) {
        // 单条失败不影响其它任务
      }
    }
    _hasScheduled = scheduled > 0;
  }

  /// Windows：进程内定时（App 常驻托盘，关闭后就收不到提醒——这是已知取舍）
  static void _rescheduleWindows(List<Task> tasks) {
    for (final t in _winTimers) {
      t.cancel();
    }
    _winTimers.clear();
    final now = DateTime.now();
    final horizon = now.add(const Duration(days: 60));
    var count = 0;
    for (final t in tasks) {
      final when = reminderAt(
        dueAt: t.dueAt,
        offsetMinutes: t.remindOffset,
        completed: t.completedAt != null || t.deletedAt != null,
      );
      if (when == null || !when.isAfter(now) || when.isAfter(horizon)) continue;
      if (count++ >= 20) break; // 最多挂 20 个，避免无意义堆积
      _winTimers.add(Timer(when.difference(now), () {
        LocalNotification(
          title: '该做「${t.title}」了',
          body: t.repeatRule == null && t.repeatUnit == null
              ? '点开查看任务清单'
              : '周期任务 · 完成后自动排下一次',
        ).show();
      }));
    }
    _hasScheduled = count > 0;
  }
}
