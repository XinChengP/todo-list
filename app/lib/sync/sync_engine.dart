import 'package:drift/drift.dart';
import 'package:http/http.dart' as http;

import '../db/database.dart';
import '../db/sync_fields.dart';
import 'api_client.dart';
import 'settings_repository.dart';
import 'sync_models.dart';

/// 同步引擎：push dirty → 用响应覆盖本地 → pull 增量 → 字段级合并 → 存游标。
///
/// 契约见 server/README。核心不变量：
/// - 本地行 = 服务器已确认状态 + 本地未推送（dirty）的字段修改
/// - 任何一次 sync 后，两端对非 dirty 内容必然收敛
/// - 推送响应是服务器的最终裁决，必须整体覆盖本地对应行（含输掉的写入）
class SyncEngine {
  SyncEngine(this._db, this._settings);

  final AppDatabase _db;
  final SettingsRepository _settings;
  static const _cursorKey = 'sync_cursor';
  static const _lastGoodEndpointKey = 'last_good_endpoint';

  /// 服务端是否支持单次往返的 /v1/sync：
  /// null/未知 = 先试一次；'1' = 支持；'0' = 老服务端，永久走 push+pull
  static const _combinedKey = 'combined_sync';

  ApiClient? _cachedApi;
  String? _cachedSig;

  Future<void> sync(
    SyncConfig config, {
    http.Client? client,
    bool light = false,
  }) async {
    // 常驻连接复用：配置未变时跨同步复用 TLS 连接（省去每次 1-3 秒的握手）。
    // light 模式（启动自动同步）：更短超时 + 更少重试，按次传参。
    final timeout = Duration(seconds: light ? 10 : 15);
    final retries = light ? 1 : 3;
    final sig =
        '${config.baseUrl}|${config.fallbackUrls.join(',')}|${config.directIp ?? ''}|${config.token}';
    final ApiClient api;
    if (client != null) {
      api = ApiClient(config: config, client: client);
    } else {
      if (_cachedApi == null || _cachedSig != sig) {
        _cachedApi?.close();
        _cachedApi = ApiClient(config: config);
        _cachedSig = sig;
      }
      api = _cachedApi!;
    }
    try {
      await _syncOnce(api, timeout: timeout, retries: retries);
      // 记住成功的端点，下次优先尝试（CF 国内可达性按时段波动）
      final good = api.lastGoodEndpoint;
      if (good != null && good != await _settings.get(_lastGoodEndpointKey)) {
        await _settings.set(_lastGoodEndpointKey, good);
      }
    } catch (_) {
      // 失败时丢弃缓存连接（可能已损坏），下次重建
      if (client == null && identical(api, _cachedApi)) {
        _cachedApi = null;
        _cachedSig = null;
      }
      rethrow;
    }
  }

  /// 一次完整同步：服务端支持 /v1/sync 时只花一个往返，否则回退 push + pull。
  Future<void> _syncOnce(
    ApiClient api, {
    required Duration timeout,
    required int retries,
  }) async {
    if (await _settings.get(_combinedKey) != '0') {
      if (await _tryCombined(api, timeout: timeout, retries: retries)) return;
    }
    await _push(api, timeout: timeout, retries: retries);
    await _pull(api, timeout: timeout, retries: retries);
  }

  /// 单往返同步：推送 + 拉取合并成一次请求。
  /// 返回 false 表示服务端不支持（已记住并切回老路径），true 表示本轮已完成。
  Future<bool> _tryCombined(
    ApiClient api, {
    required Duration timeout,
    required int retries,
  }) async {
    final dirtyTasks =
        await (_db.select(_db.tasks)..where((t) => t.dirty.equals(true))).get();
    final dirtyLists =
        await (_db.select(_db.taskLists)..where((l) => l.dirty.equals(true))).get();
    // 超过单批上限时交给分块 push 路径（正常使用不会触发）
    if (dirtyTasks.length > _pushChunkSize || dirtyLists.length > _pushChunkSize) {
      return false;
    }

    final cursor = int.tryParse(await _settings.get(_cursorKey) ?? '') ?? 0;
    final Map<String, dynamic> resp;
    try {
      resp = await api.postJson(
        '/v1/sync',
        {
          'since': cursor,
          'tasks': [for (final t in dirtyTasks) taskToProtocol(t)],
          'lists': [for (final l in dirtyLists) listToProtocol(l)],
        },
        timeout: timeout,
        retries: retries,
      );
    } on SyncRequestException catch (e) {
      // 404/405/501 = 老服务端没有这个端点：记住，以后不再试错
      if (e.status == 404 || e.status == 405 || e.status == 501) {
        await _settings.set(_combinedKey, '0');
        return false;
      }
      rethrow;
    }

    if (resp['ok'] != true || resp['pull'] is! Map) {
      await _settings.set(_combinedKey, '0');
      return false;
    }
    await _settings.set(_combinedKey, '1');

    // 推送裁决结果必须整体覆盖本地（与 /v1/sync/push 语义一致）
    for (final row in _rows(resp, 'tasks')) {
      await _overwriteTaskFromServer(row);
    }
    for (final row in _rows(resp, 'lists')) {
      await _overwriteListFromServer(row);
    }

    // 拉取部分：先应用随响应带回的增量，再按 has_more 续拉
    final pull = (resp['pull'] as Map).cast<String, dynamic>();
    for (final row in _rows(pull, 'tasks')) {
      await _mergeTask(row);
    }
    for (final row in _rows(pull, 'lists')) {
      await _mergeList(row);
    }
    var next = ((pull['cursor'] as num?) ?? cursor).toInt();
    var hasMore = pull['has_more'] == true;
    while (hasMore) {
      final more = await api.getJson('/v1/sync/pull?since=$next',
          timeout: timeout, retries: retries);
      for (final row in _rows(more, 'tasks')) {
        await _mergeTask(row);
      }
      for (final row in _rows(more, 'lists')) {
        await _mergeList(row);
      }
      next = ((more['cursor'] as num?) ?? next).toInt();
      hasMore = more['has_more'] == true;
    }
    await _settings.set(_cursorKey, '$next');
    return true;
  }

  // ---------- push ----------

  static const _pushChunkSize = 200; // 服务器单次限 500 行，客户端按 200 一批更稳

  Future<void> _push(ApiClient api, {required Duration timeout, required int retries}) async {
    final dirtyTasks =
        await (_db.select(_db.tasks)..where((t) => t.dirty.equals(true))).get();
    final dirtyLists = await (_db.select(_db.taskLists)
          ..where((l) => l.dirty.equals(true)))
        .get();
    if (dirtyTasks.isEmpty && dirtyLists.isEmpty) return;

    for (var i = 0;
        i < dirtyTasks.length || i < dirtyLists.length;
        i += _pushChunkSize) {
      final taskChunk = dirtyTasks.skip(i).take(_pushChunkSize).toList();
      final listChunk = dirtyLists.skip(i).take(_pushChunkSize).toList();
      if (taskChunk.isEmpty && listChunk.isEmpty) break;

      final resp = await api.postJson('/v1/sync/push', {
        'tasks': [for (final t in taskChunk) taskToProtocol(t)],
        'lists': [for (final l in listChunk) listToProtocol(l)],
      });

      for (final row in _rows(resp, 'tasks')) {
        await _overwriteTaskFromServer(row);
      }
      for (final row in _rows(resp, 'lists')) {
        await _overwriteListFromServer(row);
      }
    }
  }

  /// 用服务器最终状态整体覆盖本地行（新增或已存在都适用）
  Future<void> _overwriteTaskFromServer(Map<String, dynamic> remote) async {
    final f = parseProtocolFields(remote, kTaskFields);
    final ts = fieldTsFromProtocol(f);
    await _db.into(_db.tasks).insertOnConflictUpdate(
          TasksCompanion.insert(
            id: remote['id'] as String,
            createdAt: ((remote['created_at'] as num?) ?? ts.maxTs).toInt(),
            updatedAt: ((remote['updated_at'] as num?) ?? ts.maxTs).toInt(),
            title: Value(((f['title']!.v) as String?) ?? ''),
            notes: Value(((f['notes']!.v) as String?) ?? ''),
            listId: Value(f['list_id']!.v as String?),
            dueAt: Value((f['due_at']!.v as num?)?.toInt()),
            remindAt: Value((f['remind_at']!.v as num?)?.toInt()),
            priority: Value((f['priority']!.v as num?)?.toInt() ?? 0),
            completedAt: Value((f['completed_at']!.v as num?)?.toInt()),
            deletedAt: Value((f['deleted_at']!.v as num?)?.toInt()),
            fieldTs: Value(ts.encode()),
            dirty: const Value(false),
          ),
        );
  }

  Future<void> _overwriteListFromServer(Map<String, dynamic> remote) async {
    final f = parseProtocolFields(remote, kListFields);
    final ts = fieldTsFromProtocol(f);
    await _db.into(_db.taskLists).insertOnConflictUpdate(
          TaskListsCompanion.insert(
            id: remote['id'] as String,
            createdAt: ((remote['created_at'] as num?) ?? ts.maxTs).toInt(),
            updatedAt: ((remote['updated_at'] as num?) ?? ts.maxTs).toInt(),
            name: Value(((f['name']!.v) as String?) ?? ''),
            sortOrder: Value((f['sort_order']!.v as num?)?.toInt() ?? 0),
            deletedAt: Value((f['deleted_at']!.v as num?)?.toInt()),
            fieldTs: Value(ts.encode()),
            dirty: const Value(false),
          ),
        );
  }

  // ---------- pull ----------

  Future<void> _pull(ApiClient api, {required Duration timeout, required int retries}) async {
    var cursor = int.tryParse(await _settings.get(_cursorKey) ?? '') ?? 0;
    var hasMore = true;
    while (hasMore) {
      final resp =
          await api.getJson('/v1/sync/pull?since=$cursor', timeout: timeout, retries: retries);
      for (final row in _rows(resp, 'tasks')) {
        await _mergeTask(row);
      }
      for (final row in _rows(resp, 'lists')) {
        await _mergeList(row);
      }
      cursor = ((resp['cursor'] as num?) ?? cursor).toInt();
      hasMore = resp['has_more'] == true;
    }
    await _settings.set(_cursorKey, '$cursor');
  }

  /// 字段级 LWW 合并：服务器更新的字段采纳；本地更新的字段保留并保持 dirty；
  /// 相同时间戳视为已同步（推送平局由服务器裁决，本地 field_ts 已反映裁决结果）。
  Future<void> _mergeTask(Map<String, dynamic> remote) async {
    final id = remote['id'] as String;
    final local = await _db.getTaskById(id);
    if (local == null) {
      await _overwriteTaskFromServer(remote);
      return;
    }

    final localTs = FieldTs.parse(local.fieldTs);
    final remoteFields = parseProtocolFields(remote, kTaskFields);
    final remoteUpdated = ((remote['updated_at'] as num?) ?? 0).toInt();

    var c = const TasksCompanion();
    final adoptedTs = <String, int>{};
    var keepDirty = false;
    for (final e in remoteFields.entries) {
      final at = e.value.at;
      if (at > localTs[e.key]) {
        c = applyTaskField(c, e.key, e.value.v);
        adoptedTs[e.key] = at;
      } else if (localTs[e.key] > at) {
        keepDirty = true; // 本地该字段比服务器新（未推送的修改），保留
      }
    }
    if (!keepDirty) {
      c = c.copyWith(dirty: const Value(false));
    }
    c = c.copyWith(
      fieldTs: Value(FieldTs({...localTs.map, ...adoptedTs}).encode()),
      updatedAt: Value(remoteUpdated > local.updatedAt ? remoteUpdated : local.updatedAt),
    );
    await (_db.update(_db.tasks)..where((x) => x.id.equals(id))).write(c);
  }

  Future<void> _mergeList(Map<String, dynamic> remote) async {
    final id = remote['id'] as String;
    final local = await (_db.select(_db.taskLists)..where((l) => l.id.equals(id)))
        .getSingleOrNull();
    if (local == null) {
      await _overwriteListFromServer(remote);
      return;
    }

    final localTs = FieldTs.parse(local.fieldTs);
    final remoteFields = parseProtocolFields(remote, kListFields);
    final remoteUpdated = ((remote['updated_at'] as num?) ?? 0).toInt();

    var c = const TaskListsCompanion();
    final adoptedTs = <String, int>{};
    var keepDirty = false;
    for (final e in remoteFields.entries) {
      final at = e.value.at;
      if (at > localTs[e.key]) {
        c = applyListField(c, e.key, e.value.v);
        adoptedTs[e.key] = at;
      } else if (localTs[e.key] > at) {
        keepDirty = true;
      }
    }
    if (!keepDirty) {
      c = c.copyWith(dirty: const Value(false));
    }
    c = c.copyWith(
      fieldTs: Value(FieldTs({...localTs.map, ...adoptedTs}).encode()),
      updatedAt: Value(remoteUpdated > local.updatedAt ? remoteUpdated : local.updatedAt),
    );
    await (_db.update(_db.taskLists)..where((x) => x.id.equals(id))).write(c);
  }

  // ---------- 工具 ----------

  static List<Map<String, dynamic>> _rows(Map<String, dynamic> resp, String key) =>
      ((resp[key] as List?) ?? const [])
          .whereType<Map>()
          .map((e) => e.cast<String, dynamic>())
          .toList();
}
