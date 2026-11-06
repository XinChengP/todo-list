import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../providers.dart';
import '../repo/repeat.dart';
import 'stats_dialog.dart';
import '../win32_autostart.dart';

const kAppVersion = '1.1.5'; // 与 pubspec.yaml 的 version 保持一致
const kDefaultBaseUrl = 'https://todoapi.example.com';
const kDefaultFallbackUrls = 'https://todoapi.example.com:8443';
// kDefaultDirectIp 来自 providers.dart

/// 返回 true 表示已保存（调用方随后触发一次同步）
Future<bool> showSettingsDialog(BuildContext context, WidgetRef ref) async {
  final s = ref.read(settingsRepoProvider);
  final savedUrl = await s.get('base_url') ?? kDefaultBaseUrl;
  final savedToken = await s.get('token') ?? '';
  final savedFallbacks = await s.get('fallback_urls') ?? kDefaultFallbackUrls;
  final savedDirectIp = await s.get('direct_ip') ?? kDefaultDirectIp;
  if (!context.mounted) return false;

  final saved = await showDialog<bool>(
    context: context,
    builder: (_) => _SettingsDialog(
      initialUrl: savedUrl,
      initialToken: savedToken,
      initialFallbacks: savedFallbacks,
      initialDirectIp: savedDirectIp,
    ),
  );
  return saved ?? false;
}

class _SettingsDialog extends ConsumerStatefulWidget {
  const _SettingsDialog({
    required this.initialUrl,
    required this.initialToken,
    required this.initialFallbacks,
    required this.initialDirectIp,
  });

  final String initialUrl;
  final String initialToken;
  final String initialFallbacks;
  final String initialDirectIp;

  @override
  ConsumerState<_SettingsDialog> createState() => _SettingsDialogState();
}

class _SettingsDialogState extends ConsumerState<_SettingsDialog> {
  late final TextEditingController _url =
      TextEditingController(text: widget.initialUrl);
  late final TextEditingController _token =
      TextEditingController(text: widget.initialToken);
  late final TextEditingController _fallbacks =
      TextEditingController(text: widget.initialFallbacks);
  late final TextEditingController _directIp =
      TextEditingController(text: widget.initialDirectIp);
  bool _obscure = true;
  late bool _autostart = Win32AutoStart.isEnabled();
  RepeatCatchup _catchup = RepeatCatchup.skip;

  @override
  void initState() {
    super.initState();
    ref.read(taskRepoProvider).catchupPolicy().then((p) {
      if (mounted) setState(() => _catchup = p);
    });
  }

  @override
  void dispose() {
    _url.dispose();
    _token.dispose();
    _fallbacks.dispose();
    _directIp.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final url = _url.text.trim();
    final token = _token.text.trim();
    if (url.isEmpty || token.isEmpty) return;
    final s = ref.read(settingsRepoProvider);
    await s.set('base_url', url);
    await s.set('token', token);
    await s.set('fallback_urls', _fallbacks.text.trim());
    await s.set('direct_ip', _directIp.text.trim());
    ref.invalidate(syncConfigProvider); // 让配置变更立即生效
    if (mounted) Navigator.pop(context, true);
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('同步设置 v$kAppVersion'),
      content: SizedBox(
        width: double.infinity,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: _url,
                key: const ValueKey('setting-url'),
                decoration: const InputDecoration(
                  labelText: '服务器地址',
                  helperText: 'Cloudflare Workers 自定义域名',
                ),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _fallbacks,
                key: const ValueKey('setting-fallbacks'),
                decoration: const InputDecoration(
                  labelText: '备用地址（选填，每行一个）',
                  helperText: '主地址连不上时自动切换，如 :8443 端口',
                ),
                maxLines: 2,
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _directIp,
                key: const ValueKey('setting-direct-ip'),
                decoration: const InputDecoration(
                  labelText: '直连 IP（选填）',
                  helperText: '域名解析失败时 TCP 直连此 IP，证书仍按域名校验；清空则走系统 DNS',
                ),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _token,
                key: const ValueKey('setting-token'),
                obscureText: _obscure,
                decoration: InputDecoration(
                  labelText: '同步令牌',
                  helperText: '即服务端 SYNC_TOKEN',
                  suffixIcon: IconButton(
                    icon: Icon(_obscure ? Icons.visibility : Icons.visibility_off),
                    onPressed: () => setState(() => _obscure = !_obscure),
                  ),
                ),
              ),
              if (Win32AutoStart.isSupported)
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('开机自启'),
                  subtitle: const Text('登录后只启动托盘与悬浮窗，主窗口不弹出'),
                  value: _autostart,
                  onChanged: (v) {
                    Win32AutoStart.setEnabled(v);
                    setState(() => _autostart = v);
                  },
                ),
              const Divider(height: 8),
              ListTile(
                contentPadding: EdgeInsets.zero,
                leading: const Icon(Icons.insights, size: 20),
                title: const Text('统计与回顾'),
                subtitle: const Text('今天/近 7 天/本月完成数、连续天数'),
                onTap: () => showStatsDialog(context, ref),
              ),
              const SizedBox(height: 4),
              // 逾期策略：勾选周期任务时怎么安排下一次
              Align(
                alignment: Alignment.centerLeft,
                child: Text('周期任务逾期时',
                    style: Theme.of(context).textTheme.bodySmall),
              ),
              const SizedBox(height: 4),
              Wrap(
                spacing: 8,
                children: [
                  for (final (policy, label) in const [
                    (RepeatCatchup.skip, '滚到未来'),
                    (RepeatCatchup.once, '只前进一次'),
                    (RepeatCatchup.today, '对齐今天'),
                  ])
                    ChoiceChip(
                      label: Text(label),
                      selected: _catchup == policy,
                      onSelected: (_) async {
                        await ref.read(taskRepoProvider).setCatchupPolicy(policy);
                        if (mounted) setState(() => _catchup = policy);
                      },
                    ),
                ],
              ),
              const SizedBox(height: 16),
              // 按钮放进滚动区：ROM 键盘 inset 处理不可靠时仍可触达
              Row(
                children: [
                  const Spacer(),
                  TextButton(
                    onPressed: () => Navigator.pop(context, false),
                    child: const Text('取消'),
                  ),
                  const SizedBox(width: 8),
                  FilledButton(onPressed: _save, child: const Text('保存并同步')),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}
