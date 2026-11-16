import 'dart:async';
import 'dart:io' show Platform;

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/services.dart' show PlatformException;
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_timezone/flutter_timezone.dart';
import 'package:local_notifier/local_notifier.dart';
import 'package:timezone/data/latest_all.dart' as tzdata;
import 'package:timezone/timezone.dart' as tz;

import 'db/database.dart' show Task;
import 'repo/reminder_time.dart';

/// 提醒服务的运行状态（设置里的「提醒诊断」用）
class ReminderStatus {
  bool notificationsEnabled = false;

  /// 是否允许精确闹钟（Android 12+ 需用户在系统设置里给"闹钟和提醒"权限）
  bool exactAlarmsAllowed = false;

  /// 实际排上的条数
  int scheduled = 0;

  /// 是否因缺少精确闹钟权限而降级为"非精确"（仍会响，可能延迟几分钟）
  bool usingInexact = false;

  String timezone = '';
  String? lastError;
  int updatedAt = 0;
}

/// 到点提醒（Android 系统通知 / Windows 通知中心）
///
/// 设计：
/// - 数据只存 `remind_offset`（提前分钟数），绝对时刻由 `due_at - offset` 推导，
///   周期任务滚动后提醒自动跟着走
/// - 日期型任务（due 为 00:00）按当天 09:00 提醒
/// - 任务变化后整体重排（cancelAll + 未来 60 天），1.5s 防抖
/// - **Android 关键**：没有精确闹钟权限时不能用 exactAllowWhileIdle（会抛
///   exact_alarms_not_permitted，一条都排不上），这里自动降级为 inexact，
///   并把能力状态暴露给「提醒诊断」，不再静默失败
class ReminderService {
  ReminderService._();

  static final FlutterLocalNotificationsPlugin _plugin =
      FlutterLocalNotificationsPlugin();
  static bool _ready = false;
  static Timer? _debounce;
  static bool _hasScheduled = false;
  static bool _askedStartup = false;
  static const _channelId = 'todo_reminders';

  static final ReminderStatus _status = ReminderStatus();
  static ReminderStatus get status => _status;

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
      _status.timezone = info.identifier;
    } catch (e) {
      _status.lastError = '时区获取失败（可能按 UTC 计算）：$e';
    }
    try {
      await _plugin.initialize(
        const InitializationSettings(
          android: AndroidInitializationSettings('@mipmap/ic_launcher'),
        ),
      );
      _ready = true;
    } catch (e) {
      _ready = false;
      _status.lastError = '通知初始化失败：$e';
    }
  }

  static AndroidFlutterLocalNotificationsPlugin? _android() =>
      Platform.isAndroid
          ? _plugin.resolvePlatformSpecificImplementation<
              AndroidFlutterLocalNotificationsPlugin>()
          : null;

  /// 读取系统当前权限状态（诊断页/排程前都会调用）
  static Future<ReminderStatus> refreshStatus() async {
    if (!supported) return _status;
    await ensureInit();
    if (Platform.isWindows) {
      _status
        ..notificationsEnabled = true
        ..exactAlarmsAllowed = true
        ..updatedAt = DateTime.now().millisecondsSinceEpoch;
      return _status;
    }
    final android = _android();
    try {
      _status.notificationsEnabled =
          await android?.areNotificationsEnabled() ?? false;
    } catch (_) {}
    try {
      _status.exactAlarmsAllowed =
          await android?.canScheduleExactNotifications() ?? false;
    } catch (_) {}
    _status.updatedAt = DateTime.now().millisecondsSinceEpoch;
    return _status;
  }

  /// 请求权限：通知（Android 13+ 弹窗）+ 精确闹钟（跳系统设置页）
  static Future<bool> requestPermissions({bool askExact = true}) async {
    if (!supported) return false;
    await ensureInit();
    if (Platform.isWindows) return true;
    final android = _android();
    var granted = false;
    try {
      granted = await android?.requestNotificationsPermission() ?? false;
    } catch (e) {
      _status.lastError = '通知权限请求失败：$e';
    }
    if (askExact) {
      try {
        await android?.requestExactAlarmsPermission();
      } catch (_) {}
    }
    await refreshStatus();
    return granted;
  }

  /// 启动时：只要存在提醒任务，就确保通知权限（不主动跳精确闹钟设置页，
  /// 那个页面会打断用户；缺权限时会走非精确降级）
  static Future<void> ensureStartupPermissions(List<Task> activeTasks) async {
    if (!Platform.isAndroid || _askedStartup) return;
    _askedStartup = true;
    final any = activeTasks.any((t) =>
        t.remindOffset != null && t.dueAt != null && t.completedAt == null);
    if (!any) return;
    await ensureInit();
    final android = _android();
    try {
      final enabled = await android?.areNotificationsEnabled() ?? false;
      if (!enabled) await android?.requestNotificationsPermission();
    } catch (_) {}
    await refreshStatus();
  }

  static int _idFor(String id) => id.hashCode & 0x7fffffff;

  /// 任务变化后调用：防抖后整体重排
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

  static AndroidScheduleMode get _scheduleMode => _status.exactAlarmsAllowed
      ? AndroidScheduleMode.exactAllowWhileIdle
      : AndroidScheduleMode.inexactAllowWhileIdle;

  static Future<void> _rescheduleAll(List<Task> tasks) async {
    await ensureInit();
    if (!_ready) return;
    if (Platform.isWindows) {
      _rescheduleWindows(tasks);
      return;
    }
    // 每次重排前刷新能力：用户可能在系统设置里刚给了权限
    await refreshStatus();
    _status
      ..lastError = null
      ..usingInexact = !_status.exactAlarmsAllowed;

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
          androidScheduleMode: _scheduleMode,
          payload: t.id,
        );
        scheduled++;
      } on PlatformException catch (e) {
        // 缺少精确闹钟权限：降级为 inexact 再试一次（仍然会响，可能延迟）
        if (e.code == 'exact_alarms_not_permitted') {
          _status
            ..exactAlarmsAllowed = false
            ..usingInexact = true;
          try {
            await _plugin.zonedSchedule(
              _idFor(t.id),
              '该做「${t.title}」了',
              '点开查看任务清单',
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
              androidScheduleMode: AndroidScheduleMode.inexactAllowWhileIdle,
              payload: t.id,
            );
            scheduled++;
          } catch (e2) {
            _status.lastError = '排程失败：$e2';
          }
        } else {
          _status.lastError = '排程失败（${e.code}）：${e.message}';
        }
      } catch (e) {
        _status.lastError = '排程失败：$e';
      }
    }
    _status
      ..scheduled = scheduled
      ..updatedAt = DateTime.now().millisecondsSinceEpoch;
    _hasScheduled = scheduled > 0;
  }

  /// 立即排一条 5 秒后的测试通知（诊断用）
  static Future<String> testNotification() async {
    await ensureInit();
    if (!_ready) return '通知服务未初始化';
    if (Platform.isWindows) {
      await LocalNotification(title: '测试提醒', body: '如果你看到这条，说明提醒正常')
          .show();
      return '已发出（Windows 通知中心）';
    }
    await refreshStatus();
    try {
      if (_status.exactAlarmsAllowed) {
        await _plugin.zonedSchedule(
          424242,
          '测试提醒',
          '看到这条说明提醒正常（5 秒后触发）',
          tz.TZDateTime.now(tz.local).add(const Duration(seconds: 5)),
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
        );
        return '已排程：5 秒后弹出';
      }
      // 没有精确闹钟权限：直接弹一条，至少能验证通知通道是否可用
      await _plugin.show(
        424242,
        '测试提醒',
        '精确闹钟未开启，这次是立即弹出；请到系统设置允许"闹钟和提醒"',
        const NotificationDetails(
          android: AndroidNotificationDetails(
            _channelId,
            '到点提醒',
            channelDescription: '任务截止时间提醒',
            importance: Importance.high,
            priority: Priority.high,
          ),
        ),
      );
      return '精确闹钟未开启：已立即弹出测试通知';
    } catch (e) {
      return '测试失败：$e';
    }
  }

  /// Windows：进程内定时（App 常驻托盘，关闭后就收不到提醒）
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
      if (count++ >= 20) break;
      _winTimers.add(Timer(when.difference(now), () {
        LocalNotification(
          title: '该做「${t.title}」了',
          body: t.repeatRule == null && t.repeatUnit == null
              ? '点开查看任务清单'
              : '周期任务 · 完成后自动排下一次',
        ).show();
      }));
    }
    _status
      ..scheduled = count
      ..notificationsEnabled = true
      ..exactAlarmsAllowed = true
      ..usingInexact = false
      ..updatedAt = DateTime.now().millisecondsSinceEpoch;
    _hasScheduled = count > 0;
  }

  /// Windows 用进程内 Timer（悬浮窗/托盘常驻，进程活着就能弹）
  static final List<Timer> _winTimers = [];
}
