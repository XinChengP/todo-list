import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../db/database.dart' show TaskLog;
import '../providers.dart';

/// 统计与回顾：基于完成日志（同步来的，多端一致）
Future<void> showStatsDialog(BuildContext context, WidgetRef ref) {
  return showDialog(
    context: context,
    builder: (_) => const _StatsDialog(),
  );
}

class _StatsDialog extends ConsumerWidget {
  const _StatsDialog();

  DateTime _day(DateTime d) => DateTime(d.year, d.month, d.day);

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final logsAsync = ref.watch(repoLogsProvider);
    final now = DateTime.now();
    final today = _day(now);

    return AlertDialog(
      title: const Row(
        children: [
          Icon(Icons.insights, size: 20),
          SizedBox(width: 8),
          Text('统计与回顾'),
        ],
      ),
      content: SizedBox(
        width: double.infinity,
        child: logsAsync.when(
          loading: () => const SizedBox(
              height: 120, child: Center(child: CircularProgressIndicator())),
          error: (e, _) => Text('加载失败：$e'),
          data: (logs) {
            final byDay = <DateTime, int>{};
            for (final l in logs) {
              final d = _day(DateTime.fromMillisecondsSinceEpoch(l.completedAt));
              byDay[d] = (byDay[d] ?? 0) + 1;
            }
            final todayCount = byDay[today] ?? 0;
            final week = [for (var i = 6; i >= 0; i--) today.subtract(Duration(days: i))];
            final weekCount = week.fold<int>(0, (s, d) => s + (byDay[d] ?? 0));
            final monthCount = byDay.entries
                .where((e) => e.key.year == today.year && e.key.month == today.month)
                .fold<int>(0, (s, e) => s + e.value);

            // 连续天数：从今天（或昨天）往前数
            var streak = 0;
            var cursor = (byDay[today] ?? 0) > 0 ? today : today.subtract(const Duration(days: 1));
            while ((byDay[cursor] ?? 0) > 0) {
              streak++;
              cursor = cursor.subtract(const Duration(days: 1));
            }

            final maxBar = week
                .map((d) => byDay[d] ?? 0)
                .fold<int>(1, (m, v) => v > m ? v : m);

            return SingleChildScrollView(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Row(
                    children: [
                      _Metric(label: '今天', value: '$todayCount'),
                      _Metric(label: '近 7 天', value: '$weekCount'),
                      _Metric(label: '本月', value: '$monthCount'),
                      _Metric(label: '连续天数', value: '$streak'),
                    ],
                  ),
                  const SizedBox(height: 16),
                  Text('最近 7 天', style: theme.textTheme.titleSmall),
                  const SizedBox(height: 8),
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.end,
                    children: [
                      for (final d in week)
                        Expanded(
                          child: Padding(
                            padding: const EdgeInsets.symmetric(horizontal: 3),
                            child: Column(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Text('${byDay[d] ?? 0}',
                                    style: theme.textTheme.labelSmall),
                                const SizedBox(height: 2),
                                Container(
                                  height: 8 + 56 * ((byDay[d] ?? 0) / maxBar),
                                  decoration: BoxDecoration(
                                    color: (byDay[d] ?? 0) > 0
                                        ? theme.colorScheme.primary
                                        : theme.colorScheme.surfaceContainerHighest,
                                    borderRadius: BorderRadius.circular(4),
                                  ),
                                ),
                                const SizedBox(height: 2),
                                Text('${d.month}/${d.day}',
                                    style: theme.textTheme.labelSmall),
                              ],
                            ),
                          ),
                        ),
                    ],
                  ),
                  const SizedBox(height: 16),
                  if (logs.isEmpty)
                    Text('还没有完成记录。勾选任务后这里会有数据。',
                        style: theme.textTheme.bodySmall
                            ?.copyWith(color: theme.colorScheme.outline)),
                  if (logs.isNotEmpty) ...[
                    Text('最近完成', style: theme.textTheme.titleSmall),
                    const SizedBox(height: 4),
                    for (final l in logs.take(8))
                      Padding(
                        padding: const EdgeInsets.symmetric(vertical: 2),
                        child: Row(
                          children: [
                            Icon(Icons.check_circle_outline,
                                size: 14, color: theme.colorScheme.primary),
                            const SizedBox(width: 6),
                            Expanded(
                              child: Text(l.title,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: theme.textTheme.bodySmall),
                            ),
                            Text(
                              _short(DateTime.fromMillisecondsSinceEpoch(
                                  l.completedAt)),
                              style: theme.textTheme.labelSmall
                                  ?.copyWith(color: theme.colorScheme.outline),
                            ),
                          ],
                        ),
                      ),
                  ],
                ],
              ),
            );
          },
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

  String _short(DateTime d) {
    final now = DateTime.now();
    if (d.year == now.year && d.month == now.month && d.day == now.day) {
      return '今天 ${d.hour.toString().padLeft(2, '0')}:${d.minute.toString().padLeft(2, '0')}';
    }
    return '${d.month}/${d.day}';
  }
}

class _Metric extends StatelessWidget {
  const _Metric({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Expanded(
      child: Column(
        children: [
          Text(value,
              style: theme.textTheme.headlineSmall
                  ?.copyWith(color: theme.colorScheme.primary, fontWeight: FontWeight.w600)),
          Text(label,
              style: theme.textTheme.labelSmall
                  ?.copyWith(color: theme.colorScheme.outline)),
        ],
      ),
    );
  }
}

/// 完成日志流（统计页用）
final repoLogsProvider = StreamProvider<List<TaskLog>>((ref) {
  return ref.watch(taskRepoProvider).watchLogs();
});
