import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../plugins/events.dart';
import '../plugins/webhook_plugin.dart';
import '../providers.dart';

/// 插件与自动化：目前内置 Webhook 推送插件，管理其配置。
/// 事件与 payload 说明见仓库 PLUGINS.md。
Future<void> showPluginsDialog(BuildContext context, WidgetRef ref) {
  return showDialog(
    context: context,
    builder: (_) => const _PluginsDialog(),
  );
}

class _PluginsDialog extends ConsumerStatefulWidget {
  const _PluginsDialog();

  @override
  ConsumerState<_PluginsDialog> createState() => _PluginsDialogState();
}

class _PluginsDialogState extends ConsumerState<_PluginsDialog> {
  late final WebhookPlugin _webhook =
      WebhookPlugin(ref.read(databaseProvider));
  List<WebhookConfig> _configs = [];
  Map<String, WebhookResult> _results = {};
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _reload();
  }

  Future<void> _reload() async {
    final configs = await _webhook.loadConfigs();
    final results = await _webhook.loadResults();
    if (!mounted) return;
    setState(() {
      _configs = configs;
      _results = results;
      _loading = false;
    });
  }

  Future<void> _save(List<WebhookConfig> configs) async {
    await _webhook.saveConfigs(configs);
    await _reload();
  }

  Future<void> _edit([WebhookConfig? initial]) async {
    final result = await showDialog<WebhookConfig>(
      context: context,
      builder: (_) => _WebhookEditor(initial: initial),
    );
    if (result == null) return;
    final list = [..._configs];
    final i = list.indexWhere((c) => c.id == result.id);
    if (i >= 0) {
      list[i] = result;
    } else {
      list.add(result);
    }
    await _save(list);
  }

  Future<void> _test(WebhookConfig c) async {
    final r = await _webhook.test(c);
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(r.ok ? '测试成功：${r.detail}' : '测试失败：${r.detail}'),
        duration: const Duration(seconds: 2),
      ),
    );
    await _reload();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return AlertDialog(
      title: const Text('插件与自动化'),
      content: SizedBox(
        width: double.infinity,
        child: _loading
            ? const SizedBox(
                height: 120, child: Center(child: CircularProgressIndicator()))
            : SingleChildScrollView(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Row(
                      children: [
                        const Icon(Icons.webhook, size: 18),
                        const SizedBox(width: 6),
                        Expanded(
                          child: Text('Webhook 推送',
                              style: theme.textTheme.titleSmall
                                  ?.copyWith(fontWeight: FontWeight.w700)),
                        ),
                        TextButton.icon(
                          onPressed: () => _edit(),
                          icon: const Icon(Icons.add, size: 16),
                          label: const Text('添加'),
                        ),
                      ],
                    ),
                    Text(
                      '任务事件发生时，向配置的地址 POST JSON：'
                      '{"event":"task.completed","at":…,"task":{…}}。'
                      '事件与字段说明见仓库 PLUGINS.md。',
                      style: theme.textTheme.bodySmall
                          ?.copyWith(color: theme.colorScheme.outline),
                    ),
                    const SizedBox(height: 8),
                    if (_configs.isEmpty)
                      const Padding(
                        padding: EdgeInsets.symmetric(vertical: 12),
                        child: Text('还没有配置 Webhook'),
                      ),
                    for (final c in _configs)
                      ListTile(
                        dense: true,
                        contentPadding: EdgeInsets.zero,
                        leading: Switch(
                          value: c.enabled,
                          onChanged: (v) => _save([
                            for (final x in _configs)
                              if (x.id == c.id)
                                WebhookConfig(
                                  id: x.id,
                                  name: x.name,
                                  url: x.url,
                                  token: x.token,
                                  events: x.events,
                                  enabled: v,
                                )
                              else
                                x,
                          ]),
                        ),
                        title: Text(c.name, maxLines: 1, overflow: TextOverflow.ellipsis),
                        subtitle: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(c.url,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: theme.textTheme.bodySmall),
                            Text(
                              _eventsSummary(c),
                              style: theme.textTheme.labelSmall
                                  ?.copyWith(color: theme.colorScheme.outline),
                            ),
                            if (_results[c.id] != null)
                              Text(
                                '${_results[c.id]!.ok ? "✓" : "✗"} '
                                '${_results[c.id]!.detail} · '
                                '${_fmt(_results[c.id]!.at)}',
                                style: theme.textTheme.labelSmall?.copyWith(
                                    color: _results[c.id]!.ok
                                        ? theme.colorScheme.primary
                                        : theme.colorScheme.error),
                              ),
                          ],
                        ),
                        onTap: () => _edit(c),
                        trailing: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            IconButton(
                              icon: const Icon(Icons.play_arrow, size: 18),
                              tooltip: '发送测试事件',
                              onPressed: () => _test(c),
                            ),
                            IconButton(
                              icon: const Icon(Icons.delete_outline, size: 18),
                              tooltip: '删除',
                              onPressed: () => _save(
                                  [for (final x in _configs) if (x.id != c.id) x]),
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

  String _eventsSummary(WebhookConfig c) {
    if (c.events.isEmpty) return '全部事件';
    return c.events.map((e) => e.label).join('、');
  }

  String _fmt(int at) {
    final d = DateTime.fromMillisecondsSinceEpoch(at);
    return '${d.month}/${d.day} ${d.hour.toString().padLeft(2, '0')}:${d.minute.toString().padLeft(2, '0')}';
  }
}

class _WebhookEditor extends StatefulWidget {
  const _WebhookEditor({this.initial});

  final WebhookConfig? initial;

  @override
  State<_WebhookEditor> createState() => _WebhookEditorState();
}

class _WebhookEditorState extends State<_WebhookEditor> {
  late final _name = TextEditingController(text: widget.initial?.name ?? '');
  late final _url = TextEditingController(text: widget.initial?.url ?? '');
  late final _token = TextEditingController(text: widget.initial?.token ?? '');
  late final List<TaskEventType> _events = [...(widget.initial?.events ?? const <TaskEventType>[])];

  @override
  void dispose() {
    _name.dispose();
    _url.dispose();
    _token.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(widget.initial == null ? '添加 Webhook' : '编辑 Webhook'),
      content: SizedBox(
        width: double.infinity,
        child: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: _name,
                decoration: const InputDecoration(labelText: '名称'),
              ),
              const SizedBox(height: 10),
              TextField(
                controller: _url,
                decoration: const InputDecoration(labelText: 'URL（POST JSON）'),
              ),
              const SizedBox(height: 10),
              TextField(
                controller: _token,
                decoration: const InputDecoration(
                  labelText: '令牌（可选，随 X-Todo-Token 头发送）',
                ),
              ),
              const SizedBox(height: 10),
              const Text('订阅事件（不选 = 全部）'),
              const SizedBox(height: 4),
              Wrap(
                spacing: 6,
                children: [
                  for (final t in TaskEventType.values)
                    FilterChip(
                      label: Text(t.label),
                      selected: _events.contains(t),
                      onSelected: (on) => setState(() {
                        if (on) {
                          _events.add(t);
                        } else {
                          _events.remove(t);
                        }
                      }),
                    ),
                ],
              ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: () {
            final url = _url.text.trim();
            if (url.isEmpty || Uri.tryParse(url) == null) return;
            Navigator.pop(
              context,
              WebhookConfig(
                id: widget.initial?.id ??
                    DateTime.now().microsecondsSinceEpoch.toString(),
                name: _name.text.trim().isEmpty ? 'Webhook' : _name.text.trim(),
                url: url,
                token: _token.text.trim().isEmpty ? null : _token.text.trim(),
                events: _events,
                enabled: true,
              ),
            );
          },
          child: const Text('保存'),
        ),
      ],
    );
  }
}
