import 'dart:async';
import 'dart:io' show Platform;

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/services.dart' show MethodChannel;
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

  /// 实际登记到系统闹钟的条数
  int scheduled = 0;

  /// Android 上是否走"系统闹钟"模式（而非自建通知）
  bool systemAlarm = false;

  /// 是否因缺少精确闹钟权限而降级为"非精确"（仍会响，可能延迟几分钟）
  bool usingInexact = false;

  /// 是否允许全屏弹出（Android 14+ 单独权限；没有也能弹横幅）
  bool fullScreenAllowed = false;

  String timezone = '';
  String? lastError;
  int updatedAt = 0;
}

// 渠道属性建过就固定，改配置必须换新 id（1.4.2 及之前的老渠道只有基础通知）
const _channelId = 'todo_alarm_v2';

/// 与 Kotlin 侧 AlarmChannel 通信（Android 走系统闹钟）
const _alarmChannel = MethodChannel('todo/system_alarm');

/// Android 闹钟通知的统一样式：高优先级 + 响铃 + 震动 + 全屏弹出 + 持续提醒，
/// 这里集中一份，避免各处写法不一致（渠道属性建过就固定，改动必须换 channelId）
AndroidNotificationDetails _alarmDetails({String? subText}) =>
    AndroidNotificationDetails(
      _channelId,
      '到点闹钟',
      channelDescription: '任务到点时的闹钟式提醒（响铃、震动、全屏）',
      importance: Importance.max,
      priority: Priority.max,
      category: AndroidNotificationCategory.alarm,
      // 响铃 + 震动（渠道首次创建时生效）
      playSound: true,
      enableVibration: true,
      // 弹出式横幅，锁屏也可见
      fullScreenIntent: true,
      visibility: NotificationVisibility.public,
      // 用户没点掉就一直留在通知栏
      ongoing: false,
      autoCancel: true,
      // 只响一次，不做循环闹钟（避免打扰；想更强可开 additionalFlags）
      onlyAlertOnce: false,
      ticker: '任务到点',
      styleInformation: BigTextStyleInformation(''),
      subText: subText,
    );

/// 到点提醒（Android 闹钟通知 / Windows 通知中心）
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
      try {
        await android?.requestFullScreenIntentPermission();
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
    await refreshStatus();
    _status
      ..lastError = null
      ..usingInexact = false;

    // Android：用 AlarmManager.setAlarmClock 登记（系统认定的闹钟，
    // Doze/省电模式下也准时；触发后拉起全屏 AlarmActivity 响铃震动）
    try {
      _status.systemAlarm = await _alarmChannel.invokeMethod<bool>('isSupported') ?? false;
    } catch (_) {
      _status.systemAlarm = false;
    }

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


      if (_status.systemAlarm) {
        try {
          final ok = await _alarmChannel.invokeMethod<bool>('setAlarm', {
            'atMs': when.millisecondsSinceEpoch,
            'label': t.title,
            'requestCode': _idFor(t.id),
            'mirrorToClockApp': false,
          });
          if (ok == true) {
            scheduled++;
            continue;
          }
          _status.lastError = '系统闹钟登记失败';
        } catch (e) {
          _status.lastError = '系统闹钟登记失败：$e';
        }
      }

      // 系统没有闹钟应用 → 退回自建通知
      try {
        await _plugin.zonedSchedule(
          _idFor(t.id),
          '该做「${t.title}」了',
          '点开查看任务清单',
          tz.TZDateTime.from(when, tz.local),
          NotificationDetails(android: _alarmDetails()),
          uiLocalNotificationDateInterpretation:
              UILocalNotificationDateInterpretation.absoluteTime,
          androidScheduleMode: _scheduleMode,
          payload: t.id,
        );
        scheduled++;
      } catch (e) {
        _status.lastError = '通知排程失败：$e';
      }
    }
    _status
      ..scheduled = scheduled
      ..updatedAt = DateTime.now().millisecondsSinceEpoch;
    _hasScheduled = scheduled > 0;
  }

  /// 诊断用：Android 登记 1 分钟后的系统闹钟；Windows 立即弹通知
  static Future<String> testNotification() async {
    await ensureInit();
    if (!_ready) return '提醒服务未初始化';
    if (Platform.isWindows) {
      await LocalNotification(title: '测试提醒', body: '看到这条说明提醒正常').show();
      return '已发出（Windows 通知中心）';
    }
    await refreshStatus();
    final supported = _status.systemAlarm;
    if (supported) {
      final when = DateTime.now().add(const Duration(seconds: 10));
      try {
        final ok = await _alarmChannel.invokeMethod<bool>('setAlarm', {
          'atMs': when.millisecondsSinceEpoch,
          'label': '任务清单测试提醒',
          'requestCode': 424242,
        });
        return ok == true
            ? '已登记闹钟：10 秒后全屏响铃（可锁屏测试）'
            : '登记闹钟失败';
      } catch (e) {
        return '登记闹钟失败：$e';
      }
    }
    // 没有闹钟应用 → 立即弹通知验证通道
    try {
      await _plugin.show(
        424242,
        '测试提醒',
        '系统无闹钟应用，已改用通知（请检查通知权限）',
        NotificationDetails(android: _alarmDetails()),
      );
      return '已立即弹出测试通知';
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
