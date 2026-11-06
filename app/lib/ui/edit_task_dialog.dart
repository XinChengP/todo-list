import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../db/database.dart' show Task;
import '../providers.dart';
import '../repo/repeat.dart';
import 'format.dart';
import 'repeat_rule_dialog.dart';

Future<void> showEditTaskDialog(BuildContext context, WidgetRef ref, Task task) {
  return showDialog(
    context: context,
    builder: (_) => _EditTaskDialog(task: task),
  );
}

class _EditTaskDialog extends ConsumerStatefulWidget {
  const _EditTaskDialog({required this.task});

  final Task task;

  @override
  ConsumerState<_EditTaskDialog> createState() => _EditTaskDialogState();
}

class _EditTaskDialogState extends ConsumerState<_EditTaskDialog> {
  late final TextEditingController _title = TextEditingController(text: widget.task.title);
  late final TextEditingController _notes = TextEditingController(text: widget.task.notes);
  late int? _dueAt = widget.task.dueAt;
  late int _priority = widget.task.priority;
  late RepeatRule? _repeat = resolveRule(
      widget.task.repeatRule, widget.task.repeatUnit, widget.task.repeatInterval);
  late String? _listId = widget.task.listId;

  @override
  void dispose() {
    _title.dispose();
    _notes.dispose();
    super.dispose();
  }

  Future<void> _pickDue() async {
    final initial = _dueAt != null
        ? DateTime.fromMillisecondsSinceEpoch(_dueAt!)
        : DateTime.now();
    final picked = await showDatePicker(
      context: context,
      initialDate: initial,
      firstDate: DateTime(2020),
      lastDate: DateTime(2100),
    );
    if (picked != null) {
      setState(() {
        _dueAt =
            DateTime(picked.year, picked.month, picked.day).millisecondsSinceEpoch;
      });
    }
  }

  void _save() {
    final repo = ref.read(taskRepoProvider);
    final t = widget.task;
    final title = _title.text.trim();
    if (title.isNotEmpty && title != t.title) repo.rename(t, title);
    if (_notes.text != t.notes) repo.setNotes(t, _notes.text);
    if (_dueAt != t.dueAt) repo.setDue(t, _dueAt);
    if (_priority != t.priority) repo.setPriority(t, _priority);
    if (_repeat?.encode() !=
        resolveRule(t.repeatRule, t.repeatUnit, t.repeatInterval)?.encode()) {
      repo.setRepeat(t, _repeat);
    }
    if (_listId != t.listId) repo.setList(t, _listId);
    Navigator.pop(context);
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('编辑任务'),
      // 宽度填满对话框可用空间（受 insetPadding 约束）：
      // 手机窄屏不溢出，桌面端也不会超宽
      content: SizedBox(
        width: double.infinity,
        // 按钮放进滚动区内：部分 ROM 的键盘 inset 处理不可靠，
        // 键盘遮挡时滚动仍可触达按钮，任何机型都不会被挡死
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: _title,
                key: const ValueKey('edit-title'),
                decoration: const InputDecoration(labelText: '标题'),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _notes,
                decoration: const InputDecoration(labelText: '备注'),
                maxLines: 3,
              ),
              const SizedBox(height: 12),
              // 清单归属
              Consumer(
                builder: (context, ref, _) {
                  final lists = ref.watch(allListsProvider).valueOrNull ?? const [];
                  if (lists.isEmpty) return const SizedBox.shrink();
                  return Row(
                    children: [
                      const Text('清单'),
                      const SizedBox(width: 12),
                      DropdownButton<String?>(
                        value: lists.any((l) => l.id == _listId) ? _listId : null,
                        items: [
                          const DropdownMenuItem<String?>(
                              value: null, child: Text('无')),
                          for (final l in lists)
                            DropdownMenuItem<String?>(
                                value: l.id, child: Text(l.name)),
                        ],
                        onChanged: (v) => setState(() => _listId = v),
                      ),
                    ],
                  );
                },
              ),
              const SizedBox(height: 12),
              Row(
                children: [
                  OutlinedButton.icon(
                    onPressed: _pickDue,
                    icon: const Icon(Icons.event),
                    label: Text(_dueAt == null ? '截止日期' : dueLabel(_dueAt!)),
                  ),
                  if (_dueAt != null)
                    IconButton(
                      icon: const Icon(Icons.clear),
                      tooltip: '清除截止日期',
                      onPressed: () => setState(() => _dueAt = null),
                    ),
                ],
              ),
              const SizedBox(height: 12),
              // 周期规则（支持每周多选 / 月末 / 第 N 个周几 / 结束条件）
              Row(
                children: [
                  const Icon(Icons.repeat, size: 18),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(_repeat?.describe() ?? '不重复',
                        style: TextStyle(
                          color: _repeat == null
                              ? Theme.of(context).colorScheme.outline
                              : null,
                        )),
                  ),
                  TextButton(
                    onPressed: () async {
                      final res = await showRepeatRuleDialog(
                        context,
                        initial: _repeat,
                        dueAt: _dueAt,
                      );
                      if (res != null && res.changed) {
                        setState(() => _repeat = res.rule);
                      }
                    },
                    child: const Text('设置'),
                  ),
                ],
              ),
              if (_repeat != null)
                Padding(
                  padding: const EdgeInsets.only(left: 26, bottom: 4),
                  child: Text(
                    () {
                      final next = nextAfter(
                        _repeat!,
                        from: DateTime.fromMillisecondsSinceEpoch(
                            _dueAt ?? DateTime.now().millisecondsSinceEpoch),
                      );
                      return next == null ? '' : '下次：${dueLabel(next.millisecondsSinceEpoch)}';
                    }(),
                    style: Theme.of(context)
                        .textTheme
                        .bodySmall
                        ?.copyWith(color: Theme.of(context).colorScheme.primary),
                  ),
                ),
              if (_repeat != null && widget.task.completedAt == null)
                Align(
                  alignment: Alignment.centerLeft,
                  child: TextButton.icon(
                    onPressed: () async {
                      await ref.read(taskRepoProvider).skipOccurrence(widget.task);
                      if (context.mounted) {
                        Navigator.pop(context);
                        ScaffoldMessenger.of(context).showSnackBar(
                          const SnackBar(content: Text('已跳过这一次')),
                        );
                      }
                    },
                    icon: const Icon(Icons.skip_next, size: 18),
                    label: const Text('跳过这一次'),
                  ),
                ),
              const SizedBox(height: 12),
              SegmentedButton<int>(
                segments: const [
                  ButtonSegment(value: 0, label: Text('无')),
                  ButtonSegment(value: 1, label: Text('低')),
                  ButtonSegment(value: 2, label: Text('中')),
                  ButtonSegment(value: 3, label: Text('高')),
                ],
                selected: {_priority},
                onSelectionChanged: (s) => setState(() => _priority = s.first),
              ),
              const SizedBox(height: 16),
              // 取消/保存放进滚动区：ROM 键盘 inset 处理不可靠时仍可触达
              Row(
                children: [
                  const Spacer(),
                  TextButton(
                    onPressed: () => Navigator.pop(context),
                    child: const Text('取消'),
                  ),
                  const SizedBox(width: 8),
                  FilledButton(onPressed: _save, child: const Text('保存')),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}
