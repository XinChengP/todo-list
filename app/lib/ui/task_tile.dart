import 'package:flutter/material.dart';

import '../db/database.dart' show Task;
import 'format.dart';

class TaskTile extends StatelessWidget {
  const TaskTile({
    super.key,
    required this.task,
    required this.onToggle,
    required this.onDelete,
    required this.onTap,
  });

  final Task task;
  final ValueChanged<bool> onToggle;
  final VoidCallback onDelete;
  final VoidCallback onTap;

  static const _priorityColors = [Colors.grey, Colors.blue, Colors.orange, Colors.red];

  @override
  Widget build(BuildContext context) {
    final done = task.completedAt != null;
    final theme = Theme.of(context);
    return ListTile(
      leading: Checkbox(value: done, onChanged: (v) => onToggle(v ?? false)),
      title: Text(
        task.title,
        style: TextStyle(
          decoration: done ? TextDecoration.lineThrough : null,
          color: done ? theme.colorScheme.outline : null,
        ),
      ),
      subtitle: _subtitle(context),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (task.priority > 0)
            Padding(
              padding: const EdgeInsets.only(right: 4),
              child: Icon(
                Icons.flag,
                size: 18,
                color: _priorityColors[task.priority.clamp(0, 3)],
              ),
            ),
          IconButton(
            icon: const Icon(Icons.delete_outline),
            tooltip: '删除',
            onPressed: onDelete,
          ),
        ],
      ),
      onTap: onTap,
    );
  }

  Widget? _subtitle(BuildContext context) {
    final theme = Theme.of(context);
    final due = task.dueAt;
    final hasNotes = task.notes.isNotEmpty;
    if (due == null && !hasNotes) return null;
    return Row(
      children: [
        if (due != null)
          Text(
            dueLabel(due),
            style: TextStyle(
              fontSize: 12,
              color: task.completedAt == null && isOverdue(due)
                  ? theme.colorScheme.error
                  : theme.colorScheme.outline,
            ),
          ),
        if (due != null && hasNotes) const SizedBox(width: 8),
        if (hasNotes)
          Icon(Icons.notes, size: 14, color: theme.colorScheme.outline),
      ],
    );
  }
}
