import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'db/database.dart';
import 'repo/task_repository.dart';
import 'sync/api_client.dart';
import 'sync/settings_repository.dart';
import 'sync/sync_engine.dart';

final databaseProvider = Provider<AppDatabase>((ref) {
  final db = AppDatabase();
  ref.onDispose(db.close);
  return db;
});

final taskRepoProvider =
    Provider<TaskRepository>((ref) => TaskRepository(ref.watch(databaseProvider)));

final taskFilterProvider = StateProvider<TaskFilter>((ref) => TaskFilter.all);

final tasksProvider = StreamProvider<List<Task>>((ref) {
  return ref
      .watch(taskRepoProvider)
      .watch(filter: ref.watch(taskFilterProvider));
});

/// 全部未完成任务（不受界面筛选影响）——荣耀卡片数据源
final activeTasksProvider = StreamProvider<List<Task>>((ref) {
  return ref.watch(taskRepoProvider).watch(filter: TaskFilter.active);
});

// ---------- 同步 ----------

final settingsRepoProvider = Provider<SettingsRepository>(
    (ref) => SettingsRepository(ref.watch(databaseProvider)));

/// 直连 IP 默认值：CF 任播节点，绕过设备 DNS。清空设置里的值可禁用。
const kDefaultDirectIp = '104.21.68.252';

/// 直连 IP 解析规则：没设置过 → 默认启用；显式清空 → 禁用
String? _resolveDirectIp(String? stored) {
  if (stored == null) return kDefaultDirectIp;
  final t = stored.trim();
  return t.isEmpty ? null : t;
}

/// 当前同步配置；未配置时为 null
final syncConfigProvider = FutureProvider<SyncConfig?>((ref) async {
  final s = ref.watch(settingsRepoProvider);
  final baseUrl = await s.get('base_url');
  final token = await s.get('token');
  if (baseUrl == null || baseUrl.isEmpty || token == null || token.isEmpty) {
    return null;
  }
  final fallbacks = (await s.get('fallback_urls') ?? '')
      .split(RegExp(r'[\n,]'))
      .map((e) => e.trim())
      .where((e) => e.isNotEmpty)
      .toList();
  return SyncConfig(
    baseUrl: baseUrl,
    fallbackUrls: fallbacks,
    preferredEndpoint: await s.get('last_good_endpoint'),
    directIp: _resolveDirectIp(await s.get('direct_ip')),
    token: token,
  );
});

final syncEngineProvider = Provider<SyncEngine>(
    (ref) => SyncEngine(ref.watch(databaseProvider), ref.watch(settingsRepoProvider)));

enum SyncPhase { idle, syncing, success, error, authError }

class SyncUiState {
  const SyncUiState(this.phase, [this.message]);
  final SyncPhase phase;
  final String? message;
}

class SyncController extends Notifier<SyncUiState> {
  bool _running = false;
  bool _queued = false; // 同步进行中又被请求一次：结束后补跑

  @override
  SyncUiState build() => const SyncUiState(SyncPhase.idle);

  /// 把底层网络异常翻译成人话（原始堆栈对用户没意义）
  static String _friendlyError(Object e) {
    final s = e.toString();
    // 连接链诊断：三级路径（直连/DoH/系统）各自失败原因已内嵌
    if (s.contains('连接链全部失败')) {
      return '无法连接服务器，各备用路径诊断：$s';
    }
    if (s.contains('Failed host lookup') ||
        s.contains('No address associated') ||
        s.contains('UnknownHostException')) {
      return '域名解析失败：设备网络/DNS 问题。可在设置里填「直连 IP」（如 104.21.68.252）绕过 DNS，或改 DNS 为 223.5.5.5 后重试';
    }
    if (s.contains('timed out') ||
        s.contains('TimeoutException') ||
        s.contains('Connection refused') ||
        s.contains('Connection closed') ||
        s.contains('Network is unreachable')) {
      return '连接超时或被拒绝：设备当前网络不可用，请检查网络后重试';
    }
    if (s.contains('1016') || s.contains('non-JSON response')) {
      return '连接被网络劫持或直连 IP 已失效：请更换「直连 IP」（设置里，如 172.67.200.136）或换网络后重试';
    }
    if (s.contains('SSL') || s.contains('Handshake') || s.contains('handshake')) {
      return '安全连接失败：当前网络对 HTTPS 有干扰，请换网络重试';
    }
    return s;
  }

  /// 执行一次同步。[auto] 为 true 时未配置则静默跳过（用于启动时自动同步），
  /// 且使用轻量网络参数（更短超时、更少重试）。
  Future<bool> run({bool auto = false}) async {
    if (_running) {
      // 同步进行中：记一笔，本轮成功结束后补跑一次。
      // 场景：启动自动同步还没结束，用户就在桌面卡片上勾了任务——
      // 直接丢弃会导致这次修改要等到下次启动/手动同步才上传。
      _queued = true;
      return false;
    }
    final config = await ref.read(syncConfigProvider.future);
    if (config == null) {
      if (!auto) {
        state = const SyncUiState(SyncPhase.authError, '尚未配置同步：点右上角设置，填入服务器地址与令牌');
      }
      return false;
    }
    _running = true;
    state = const SyncUiState(SyncPhase.syncing);
    var ok = false;
    try {
      await ref.read(syncEngineProvider).sync(config, light: auto);
      state = const SyncUiState(SyncPhase.success);
      ok = true;
      return true;
    } on SyncAuthException catch (e) {
      state = SyncUiState(SyncPhase.authError, e.message);
    } catch (e) {
      state = SyncUiState(SyncPhase.error, _friendlyError(e));
    } finally {
      _running = false;
      if (_queued) {
        _queued = false;
        // 本轮失败说明网络不通，补跑也只会再失败一次，留给下次同步
        if (ok) unawaited(run());
      }
    }
    return false;
  }
}

final syncControllerProvider =
    NotifierProvider<SyncController, SyncUiState>(SyncController.new);
