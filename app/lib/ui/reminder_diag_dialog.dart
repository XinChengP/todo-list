import 'dart:io' show Platform;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show MethodChannel;

import '../reminders.dart';

/// 提醒诊断：把"为什么不响"的每个环节摊开显示，并提供一键授权/测试。
Future<void> showReminderDiagDialog(BuildContext context) {
  return showDialog(
    context: context,
    builder: (_) => const _ReminderDiagDialog(),
  );
}

class _ReminderDiagDialog extends StatefulWidget {
  const _ReminderDiagDialog();

  @override
  State<_ReminderDiagDialog> createState() => _ReminderDiagDialogState();
}

class _ReminderDiagDialogState extends State<_ReminderDiagDialog> {
  ReminderStatus? _s;
  String? _testResult;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _refresh();
  }

  Future<void> _refresh() async {
    final s = await ReminderService.refreshStatus();
    if (mounted) setState(() => _s = s);
  }

  Future<void> _requestAll() async {
    setState(() => _busy = true);
    await ReminderService.requestPermissions();
    await _refresh();
    if (mounted) setState(() => _busy = false);
  }

  Future<void> _test() async {
    setState(() => _busy = true);
    final r = await ReminderService.testNotification();
    await _refresh();
    if (mounted) {
      setState(() {
        _busy = false;
        _testResult = r;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final s = _s;
    return AlertDialog(
      title: const Row(
        children: [
          Icon(Icons.notifications_active_outlined, size: 20),
          SizedBox(width: 8),
          Text('提醒诊断'),
        ],
      ),
      content: SizedBox(
        width: double.infinity,
        child: s == null
            ? const SizedBox(
                height: 100, child: Center(child: CircularProgressIndicator()))
            : SingleChildScrollView(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (Platform.isAndroid) ...[
                      _kv('提醒方式', s.systemAlarm ? '应用闹钟（全屏响铃）' : '应用通知'),
                      if (!s.systemAlarm) ...[
                        _row('通知权限', s.notificationsEnabled),
                        _row('精确闹钟', s.exactAlarmsAllowed),
                      ],
                    ] else
                      _row('通知权限', s.notificationsEnabled),
                    const SizedBox(height: 8),
                    _kv(s.systemAlarm ? '已登记闹钟' : '已排程', '${s.scheduled} 条'),
                    if (Platform.isAndroid) _kv('时区', s.timezone.isEmpty ? '未知' : s.timezone),
                    if (s.usingInexact)
                      Padding(
                        padding: const EdgeInsets.only(top: 4),
                        child: Text(
                          '⚠ 缺少精确闹钟权限：已降级为非精确排程，'
                          '提醒仍会响，但可能延迟几分钟。',
                          style: theme.textTheme.bodySmall
                              ?.copyWith(color: theme.colorScheme.error),
                        ),
                      ),
                    if (s.lastError != null)
                      Padding(
                        padding: const EdgeInsets.only(top: 4),
                        child: Text('上次错误：${s.lastError}',
                            style: theme.textTheme.bodySmall
                                ?.copyWith(color: theme.colorScheme.error)),
                      ),
                    if (_testResult != null)
                      Padding(
                        padding: const EdgeInsets.only(top: 8),
                        child: Text(_testResult!,
                            style: theme.textTheme.bodySmall
                                ?.copyWith(color: theme.colorScheme.primary)),
                      ),
                    const SizedBox(height: 12),
                    Wrap(
                      spacing: 8,
                      runSpacing: 4,
                      children: [
                        OutlinedButton.icon(
                          onPressed: _busy ? null : _refresh,
                          icon: const Icon(Icons.refresh, size: 16),
                          label: const Text('重新检测'),
                        ),
                        OutlinedButton.icon(
                          onPressed: _busy ? null : _requestAll,
                          icon: const Icon(Icons.lock_open, size: 16),
                          label: const Text('去授权'),
                        ),
                        FilledButton.tonalIcon(
                          onPressed: _busy ? null : _test,
                          icon: const Icon(Icons.alarm, size: 16),
                          label: const Text('测试提醒'),
                        ),
                        if (Platform.isAndroid)
                          OutlinedButton.icon(
                            onPressed: () async {
                              try {
                                await const MethodChannel('todo/system_alarm')
                                    .invokeMethod('openAlarmApp');
                              } catch (_) {}
                            },
                            icon: const Icon(Icons.access_time, size: 16),
                            label: const Text('打开系统闹钟'),
                          ),
                      ],
                    ),
                    const Divider(height: 24),
                    Text('提醒方式说明：',
                        style: theme.textTheme.titleSmall
                            ?.copyWith(fontWeight: FontWeight.w700)),
                    const SizedBox(height: 4),
                    for (final t in const [
                      'Android 用系统闹钟 API（setAlarmClock）：Doze/省电模式下也准时',
                      '到点会全屏亮起（锁屏也行）、循环响铃 + 震动，直到你点"知道了"',
                      '可点「稍后 5 分钟」推迟；关机重启后会自动重新登记',
                      '荣耀务必允许：设置 → 应用 → 任务清单 → 耗电管理 → 允许后台活动',
                    ])
                      Padding(
                        padding: const EdgeInsets.only(bottom: 2),
                        child: Text('· $t',
                            style: theme.textTheme.bodySmall?.copyWith(
                                color: theme.colorScheme.outline)),
                      ),
                    const SizedBox(height: 6),
                    Text(
                      '提示：这是应用自己的闹钟，不会写进「时钟」App 的闹钟列表；'
                      '响铃时按音量键只影响本次播放，不会改系统闹钟音量。',
                      style: theme.textTheme.labelSmall
                          ?.copyWith(color: theme.colorScheme.outline),
                    ),
                  ],
                ),
              ),
      ),
      actions: [
        FilledButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('关闭'),
        ),
      ],
    );
  }

  Widget _row(String label, bool ok) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 2),
        child: Row(
          children: [
            Icon(ok ? Icons.check_circle : Icons.cancel,
                size: 16,
                color: ok ? Colors.green : Theme.of(context).colorScheme.error),
            const SizedBox(width: 6),
            Text(label),
            const Spacer(),
            Text(ok ? '已开启' : '未开启',
                style: TextStyle(
                    color: ok
                        ? Colors.green
                        : Theme.of(context).colorScheme.error,
                    fontSize: 12)),
          ],
        ),
      );

  Widget _kv(String k, String v) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 2),
        child: Row(
          children: [
            Text(k, style: const TextStyle(fontSize: 13)),
            const Spacer(),
            Text(v,
                style: TextStyle(
                    fontSize: 12,
                    color: Theme.of(context).colorScheme.outline)),
          ],
        ),
      );
}
