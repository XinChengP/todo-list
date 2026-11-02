import 'package:flutter/material.dart';

import 'settings_dialog.dart' show kAppVersion;

/// 使用说明（右上角问号按钮）
///
/// 目的是把"光看界面看不出来"的能力集中写在一处：
/// 快捷添加语法、清单与筛选、周期任务、桌面卡片、同步、数据语义。
Future<void> showHelpDialog(BuildContext context) {
  return showDialog(
    context: context,
    builder: (_) => const _HelpDialog(),
  );
}

class _HelpDialog extends StatelessWidget {
  const _HelpDialog();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return AlertDialog(
      title: Row(
        children: [
          const Icon(Icons.menu_book_outlined, size: 20),
          const SizedBox(width: 8),
          const Text('使用说明'),
          const Spacer(),
          Text('v$kAppVersion',
              style: theme.textTheme.bodySmall
                  ?.copyWith(color: theme.colorScheme.outline)),
        ],
      ),
      content: SizedBox(
        width: double.infinity,
        child: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: const [
              _Section(
                icon: Icons.bolt,
                title: '快捷添加（最省事的方式）',
                body: '在顶部输入框一行写完，边打边有预览，回车即成。',
                samples: [
                  ('买牛奶 明天18点', '标题「买牛奶」+ 明天 18:00 截止'),
                  ('写周报 !高 #工作', '优先级=高，归到「工作」清单'),
                  ('喝水 每3天', '周期任务：每 3 天一次'),
                  ('复盘 周五 下午3点 每周', '周五 15:00 截止，每周重复'),
                ],
                tips: [
                  '#名称 → 清单（不存在会自动创建）',
                  '!高 / !中 / !低 / !1-3 → 优先级',
                  '每天 / 每周 / 每月 / 每年 / 每3天 → 重复',
                  '今天 / 明天 / 后天 / 周X / 下周X / 11月5日 / 11/5 → 日期',
                  '18:30 / 18点 / 9点半 / 下午3点 → 时间（不写默认 09:00）',
                ],
              ),
              _Section(
                icon: Icons.folder_outlined,
                title: '清单与筛选',
                body: '顶部横向条切换清单（数字＝该清单未完成条数）；点「清单」可以新建 / 改名 / 删除。'
                    '删除清单不会删任务，任务只是失去归属，仍能在「全部」里看到。',
              ),
              _Section(
                icon: Icons.filter_alt_outlined,
                title: '搜索与高级筛选',
                body: '右上角放大镜搜索标题和备注；漏斗图标里可多选条件：'
                    '已逾期、今天到期、7 天内、重要、有日期、无日期、周期。'
                    '筛选条件之间是「同时满足」，可与状态（全部/进行中/已完成）叠加。',
              ),
              _Section(
                icon: Icons.repeat,
                title: '周期任务',
                body: '编辑任务时选「重复」= 每天/每周/每月/每年 + 间隔。'
                    '完成时不会留一堆历史行，而是**原地滚到下一次**（弹提示「已完成，下次 X」）。'
                    '月末会夹紧：1/31 加一个月 = 2/28（闰年 2/29）；拖很久才勾选会自动追到未来。',
              ),
              _Section(
                icon: Icons.widgets_outlined,
                title: '桌面卡片（Android）',
                body: '长按桌面 → 添加小部件 → 任务清单，有 2×2 / 4×2 / 4×4 三种。'
                    '点圆点＝本地直接完成（不会打开 App）；点任务名或空白处＝打开 App。'
                    '勾选后任务会先在卡片上保留（打勾变灰），App 下次刷新卡片时才消失。',
              ),
              _Section(
                icon: Icons.desktop_windows_outlined,
                title: 'Windows 端',
                body: '关闭窗口＝最小化到托盘（托盘右键可退出）；'
                    '工具栏第一个按钮打开常驻悬浮窗，可置顶、可拖动，点标题即完成；'
                    '默认开机自启，可在同步设置里关掉。',
              ),
              _Section(
                icon: Icons.sync,
                title: '多端同步',
                body: '本地优先：断网照常用，联网后自动合并。冲突按「字段级 Last-Write-Wins」裁决，'
                    '粒度为单个字段（两台设备分别改标题和备注不会互相覆盖）。'
                    '服务器地址与令牌在右上角设置里填，令牌等于服务器端的 SYNC_TOKEN。',
              ),
              _Section(
                icon: Icons.safety_check_outlined,
                title: '数据与安全',
                body: '删除是软删除（保留墓碑），所以撤销和多端同步都可靠；'
                    '数据全部存在本地 SQLite，同步只是副本上传，服务器挂了你本地也不丢。',
              ),
            ],
          ),
        ),
      ),
      actions: [
        FilledButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('知道了'),
        ),
      ],
    );
  }
}

class _Section extends StatelessWidget {
  const _Section({
    required this.icon,
    required this.title,
    required this.body,
    this.samples = const [],
    this.tips = const [],
  });

  final IconData icon;
  final String title;
  final String body;

  /// (输入示例, 效果说明)
  final List<(String, String)> samples;
  final List<String> tips;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: 18),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(icon, size: 18, color: theme.colorScheme.primary),
              const SizedBox(width: 6),
              Expanded(
                child: Text(title,
                    style: theme.textTheme.titleSmall
                        ?.copyWith(fontWeight: FontWeight.w600)),
              ),
            ],
          ),
          const SizedBox(height: 4),
          Text(body, style: theme.textTheme.bodySmall?.copyWith(height: 1.5)),
          if (samples.isNotEmpty) ...[
            const SizedBox(height: 8),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: theme.colorScheme.surfaceContainerHighest,
                borderRadius: BorderRadius.circular(8),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  for (final (input, effect) in samples)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 4),
                      child: RichText(
                        text: TextSpan(
                          style: theme.textTheme.bodySmall,
                          children: [
                            TextSpan(
                              text: input,
                              style: TextStyle(
                                fontFamily: 'monospace',
                                color: theme.colorScheme.primary,
                              ),
                            ),
                            TextSpan(
                              text: '  →  $effect',
                              style: TextStyle(color: theme.colorScheme.outline),
                            ),
                          ],
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ],
          if (tips.isNotEmpty) ...[
            const SizedBox(height: 6),
            for (final t in tips)
              Padding(
                padding: const EdgeInsets.only(left: 2, bottom: 2),
                child: Text('· $t',
                    style: theme.textTheme.bodySmall
                        ?.copyWith(color: theme.colorScheme.outline)),
              ),
          ],
        ],
      ),
    );
  }
}
