import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../db/database.dart' show TaskList;
import '../providers.dart';

/// 清单管理：新建 / 改名 / 删除（软删除，走同步）
Future<void> showManageListsDialog(BuildContext context, WidgetRef ref) {
  return showDialog(
    context: context,
    builder: (_) => const _ManageListsDialog(),
  );
}

class _ManageListsDialog extends ConsumerStatefulWidget {
  const _ManageListsDialog();

  @override
  ConsumerState<_ManageListsDialog> createState() => _ManageListsDialogState();
}

class _ManageListsDialogState extends ConsumerState<_ManageListsDialog> {
  final _controller = TextEditingController();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _add() async {
    final name = _controller.text.trim();
    if (name.isEmpty) return;
    final repo = ref.read(taskRepoProvider);
    if (await repo.findListByName(name) != null) {
      _controller.clear();
      return; // 已存在，静默忽略
    }
    await repo.addList(name);
    _controller.clear();
  }

  Future<void> _rename(TaskList l) async {
    final ctrl = TextEditingController(text: l.name);
    final name = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('重命名清单'),
        content: TextField(
          controller: ctrl,
          autofocus: true,
          decoration: const InputDecoration(labelText: '名称'),
          onSubmitted: (v) => Navigator.pop(ctx, v.trim()),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('取消')),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, ctrl.text.trim()),
            child: const Text('保存'),
          ),
        ],
      ),
    );
    ctrl.dispose();
    if (name != null && name.isNotEmpty && name != l.name) {
      await ref.read(taskRepoProvider).renameList(l, name);
    }
  }

  Future<void> _delete(TaskList l) async {
    await ref.read(taskRepoProvider).deleteList(l);
    // 如果当前正筛这个清单，回到「全部」
    if (ref.read(listFilterProvider) == l.id) {
      ref.read(listFilterProvider.notifier).state = null;
    }
  }

  @override
  Widget build(BuildContext context) {
    final listsAsync = ref.watch(allListsProvider);
    return AlertDialog(
      title: const Text('管理清单'),
      content: SizedBox(
        width: double.infinity,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: _controller,
                      decoration: const InputDecoration(
                        labelText: '新清单名称',
                        isDense: true,
                      ),
                      onSubmitted: (_) => _add(),
                    ),
                  ),
                  const SizedBox(width: 8),
                  FilledButton(onPressed: _add, child: const Text('添加')),
                ],
              ),
              const SizedBox(height: 12),
              listsAsync.when(
                loading: () => const Padding(
                  padding: EdgeInsets.all(16),
                  child: Center(child: CircularProgressIndicator()),
                ),
                error: (e, _) => Text('加载失败：$e'),
                data: (lists) => lists.isEmpty
                    ? const Padding(
                        padding: EdgeInsets.symmetric(vertical: 16),
                        child: Text('还没有清单，先在上面加一个'),
                      )
                    : Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          for (final l in lists)
                            ListTile(
                              dense: true,
                              contentPadding: EdgeInsets.zero,
                              leading: const Icon(Icons.folder_outlined, size: 20),
                              title: Text(l.name),
                              onTap: () => _rename(l),
                              trailing: IconButton(
                                icon: const Icon(Icons.delete_outline, size: 20),
                                tooltip: '删除清单（任务保留）',
                                onPressed: () => _delete(l),
                              ),
                            ),
                        ],
                      ),
              ),
            ],
          ),
        ),
      ),
      actions: [
        FilledButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('完成'),
        ),
      ],
    );
  }
}
