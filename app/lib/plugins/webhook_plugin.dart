import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import '../db/database.dart';
import '../sync/settings_repository.dart';
import 'events.dart';
import 'plugin_api.dart';

/// 一个 Webhook 配置：任务事件发生时向 [url] POST JSON。
class WebhookConfig {
  const WebhookConfig({
    required this.id,
    required this.name,
    required this.url,
    this.token,
    this.events = const [],
    this.enabled = true,
  });

  final String id;
  final String name;
  final String url;

  /// 放在请求头 `X-Todo-Token` 里，接收方可校验
  final String? token;

  /// 订阅的事件；空 = 全部事件
  final List<TaskEventType> events;

  final bool enabled;

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'url': url,
        if (token != null && token!.isNotEmpty) 'token': token,
        'events': [for (final e in events) e.name],
        'enabled': enabled,
      };

  static WebhookConfig fromJson(Map<String, dynamic> m) => WebhookConfig(
        id: (m['id'] as String?) ?? '',
        name: (m['name'] as String?) ?? '未命名',
        url: (m['url'] as String?) ?? '',
        token: m['token'] as String?,
        events: [
          for (final e in (m['events'] as List? ?? const []))
            TaskEventType.values.firstWhere(
              (t) => t.name == e,
              orElse: () => TaskEventType.updated,
            ),
        ],
        enabled: (m['enabled'] as bool?) ?? true,
      );

  static List<WebhookConfig> listFromJson(String? raw) {
    if (raw == null || raw.trim().isEmpty) return [];
    try {
      final v = jsonDecode(raw);
      if (v is! List) return [];
      return [
        for (final e in v)
          if (e is Map) WebhookConfig.fromJson(e.cast<String, dynamic>()),
      ];
    } catch (_) {
      return [];
    }
  }

  static String listToJson(List<WebhookConfig> list) =>
      jsonEncode([for (final c in list) c.toJson()]);
}

/// 最近一次发送结果（设置里展示用）
class WebhookResult {
  const WebhookResult(this.ok, this.detail, this.at);
  final bool ok;
  final String detail;
  final int at;

  Map<String, dynamic> toJson() => {'ok': ok, 'detail': detail, 'at': at};

  static WebhookResult fromJson(Map<String, dynamic> m) => WebhookResult(
        (m['ok'] as bool?) ?? false,
        (m['detail'] as String?) ?? '',
        (m['at'] as num?)?.toInt() ?? 0,
      );
}

/// 内置插件：把任务事件以 JSON POST 到用户配置的地址。
///
/// payload 结构（字段级快照，见 PLUGINS.md）：
/// ```json
/// {"event":"task.completed","at":1794...,
///  "task":{"id":"...","title":"...","due_at":...,"completed_at":...}}
/// ```
class WebhookPlugin extends TodoPlugin {
  WebhookPlugin(this._db, {http.Client? client})
      : _client = client ?? http.Client();

  final AppDatabase _db;
  final http.Client _client;
  List<WebhookConfig> _configs = [];

  static const _configsKey = 'webhook_configs';
  static const _resultsKey = 'webhook_results';

  @override
  String get name => 'webhook';

  @override
  String get title => 'Webhook 推送';

  @override
  String get description => '任务事件发生时向你配置的地址 POST JSON';

  Future<List<WebhookConfig>> loadConfigs() async {
    final settings = SettingsRepository(_db);
    _configs = WebhookConfig.listFromJson(await settings.get(_configsKey));
    return _configs;
  }

  Future<void> saveConfigs(List<WebhookConfig> configs) async {
    final settings = SettingsRepository(_db);
    _configs = configs;
    await settings.set(_configsKey, WebhookConfig.listToJson(configs));
  }

  Future<Map<String, WebhookResult>> loadResults() async {
    final settings = SettingsRepository(_db);
    final raw = await settings.get(_resultsKey);
    if (raw == null || raw.isEmpty) return {};
    try {
      final v = jsonDecode(raw);
      if (v is! Map) return {};
      return {
        for (final e in v.entries)
          e.key as String: WebhookResult.fromJson((e.value as Map).cast<String, dynamic>()),
      };
    } catch (_) {
      return {};
    }
  }

  Future<void> _saveResult(String id, WebhookResult r) async {
    final settings = SettingsRepository(_db);
    final all = await loadResults();
    all[id] = r;
    await settings.set(_resultsKey, jsonEncode({
          for (final e in all.entries) e.key: e.value.toJson(),
        }));
  }

  @override
  Future<void> onInit() async {
    await loadConfigs();
  }

  @override
  Future<void> onTaskEvent(TaskEvent event) async {
    final matches = _configs.where((c) =>
        c.enabled &&
        c.url.isNotEmpty &&
        (c.events.isEmpty || c.events.contains(event.type)));
    for (final c in matches) {
      final r = await _post(c.url, c.token, event.toJson());
      await _saveResult(c.id, r);
    }
  }

  /// 发送测试事件（设置界面「测试」按钮）
  Future<WebhookResult> test(WebhookConfig c) async {
    final r = await _post(c.url, c.token,
        {'event': 'test', 'at': DateTime.now().millisecondsSinceEpoch});
    await _saveResult(c.id, r);
    return r;
  }

  Future<WebhookResult> _post(
      String url, String? token, Map<String, dynamic> payload) async {
    try {
      final resp = await _client
          .post(
            Uri.parse(url),
            headers: {
              'Content-Type': 'application/json',
              if (token != null && token.isNotEmpty) 'X-Todo-Token': token,
            },
            body: jsonEncode(payload),
          )
          .timeout(const Duration(seconds: 10));
      return WebhookResult(
          resp.statusCode >= 200 && resp.statusCode < 300,
          'HTTP ${resp.statusCode}',
          DateTime.now().millisecondsSinceEpoch);
    } catch (e) {
      return WebhookResult(false, '失败：$e'.substring(0, 120.clamp(0, '失败：$e'.length)),
          DateTime.now().millisecondsSinceEpoch);
    }
  }
}
