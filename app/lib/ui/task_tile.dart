import 'package:flutter/material.dart';

import '../db/database.dart' show Task;
import '../repo/repeat.dart';
import 'format.dart';

/// 任务卡片：圆角卡片 + 圆形勾选 + 元信息小药丸
///
/// 保留 Checkbox / 旗帜图标等既有语义控件（测试与无障碍都依赖它们），
/// 只重做视觉层级：标题为主、元信息收敛成低对比小标签。
class TaskTile extends StatelessWidget {
  const TaskTile({
    super.key,
    required this.task,
    required this.onToggle,
    required this.onDelete,
    required this.onTap,
    this.listName,
  });

  final Task task;

  /// 任务所属清单名（"全部"视图下显示；为空则不显示）
  final String? listName;

  final ValueChanged<bool> onToggle;
  final VoidCallback onDelete;
  final VoidCallback onTap;

  static const _priorityColors = [
    Colors.grey,
    Color(0xFF4C9AFF),
    Color(0xFFFFA53E),
    Color(0xFFF25F5C),
  ];

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final done = task.completedAt != null;
    final flagColor = _priorityColors[task.priority.clamp(0, 3)];

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 3.5),
      child: Card(
        child: InkWell(
          borderRadius: BorderRadius.circular(16),
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(6, 7, 2, 7),
            child: Row(
              children: [
                Checkbox(
                  value: done,
                  onChanged: (v) => onToggle(v ?? false),
                ),
                const SizedBox(width: 2),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        task.title,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.bodyLarge?.copyWith(
                          fontWeight: FontWeight.w500,
                          decoration: done ? TextDecoration.lineThrough : null,
                          color: done ? scheme.outline : scheme.onSurface,
                        ),
                      ),
                      if (_meta(done).isNotEmpty) ...[
                        const SizedBox(height: 5),
                        Wrap(
                          spacing: 5,
                          runSpacing: 3,
                          crossAxisAlignment: WrapCrossAlignment.center,
                          children: _meta(done),
                        ),
                      ],
                    ],
                  ),
                ),
                if (task.priority > 0)
                  Padding(
                    padding: const EdgeInsets.only(left: 4),
                    child: Icon(Icons.flag, size: 17, color: flagColor),
                  ),
                IconButton(
                  visualDensity: VisualDensity.compact,
                  iconSize: 18,
                  color: scheme.outline.withValues(alpha: 0.75),
                  icon: const Icon(Icons.delete_outline),
                  tooltip: '删除',
                  onPressed: onDelete,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  List<Widget> _meta(bool done) {
    final out = <Widget>[];
    final due = task.dueAt;
    final repeat =
        resolveRule(task.repeatRule, task.repeatUnit, task.repeatInterval)
            ?.describe() ??
        '';
    final list = listName;

    if (due != null) {
      out.add(_Pill(
        icon: Icons.event_outlined,
        text: dueLabel(due),
        tone: !done && isOverdue(due) ? _Tone.danger : _Tone.muted,
      ));
    }
    if (repeat.isNotEmpty) {
      out.add(_Pill(icon: Icons.repeat, text: repeat, tone: _Tone.accent));
    }
    if (list != null && list.isNotEmpty) {
      out.add(_Pill(icon: Icons.folder_outlined, text: list, tone: _Tone.muted));
    }
    if (task.notes.isNotEmpty) {
      out.add(const _Pill(icon: Icons.notes, text: '', tone: _Tone.muted));
    }
    return out;
  }
}

enum _Tone { muted, accent, danger }

class _Pill extends StatelessWidget {
  const _Pill({required this.icon, required this.text, required this.tone});

  final IconData icon;
  final String text;
  final _Tone tone;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final (fg, bg) = switch (tone) {
      _Tone.accent => (scheme.primary, scheme.primary.withValues(alpha: 0.10)),
      _Tone.danger => (scheme.error, scheme.error.withValues(alpha: 0.10)),
      _Tone.muted => (scheme.outline, scheme.outline.withValues(alpha: 0.08)),
    };
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(color: bg, borderRadius: BorderRadius.circular(6)),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 11, color: fg),
          if (text.isNotEmpty) ...[
            const SizedBox(width: 3),
            Text(text, style: TextStyle(fontSize: 11, color: fg)),
          ],
        ],
      ),
    );
  }
}
