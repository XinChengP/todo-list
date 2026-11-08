import 'dart:async';

import '../db/database.dart' show Task;
import '../repo/task_repository.dart';
import 'events.dart';

/// 插件接口：想扩展任务清单，实现这个类并注册到 [PluginHost]。
///
/// 典型用法（见 webhook_plugin.dart）：
/// ```dart
/// class MyPlugin extends TodoPlugin {
///   @override
///   String get name => 'my_plugin';
///   @override
///   String get title => '我的插件';
///   @override
///   Future<void> onTaskEvent(TaskEvent e) async { /* ... */ }
/// }
/// PluginHost.register(MyPlugin());
/// ```
abstract class TodoPlugin {
  /// 唯一标识（设置存储的 key 之一）
  String get name;

  /// 界面展示名
  String get title;

  /// 一句话说明（设置里显示）
  String get description => '';

  /// App 启动后调用一次（插件可在此读配置/初始化）
  Future<void> onInit() async {}

  /// 任务事件（已合并：连续的"修改"会合并成一条）
  Future<void> onTaskEvent(TaskEvent event) async {}

  /// 插件被注销/应用退出
  Future<void> onDispose() async {}
}

/// 插件宿主：订阅仓库事件流，分发给所有插件。
///
/// 合并规则：同一任务的连续 `updated` 事件在 800ms 静默后合并成一条
/// （编辑弹窗一次保存会写多个字段，不去重的话 webhook 会连发好几条）；
/// 其它事件立即分发，分发前先冲掉该任务挂起的 updated，保证顺序。
class PluginHost {
  PluginHost._();

  static final List<TodoPlugin> _plugins = <TodoPlugin>[];
  static StreamSubscription<TaskEvent>? _sub;
  static bool _inited = false;

  /// 注册插件（必须在 [init] 之前或任意时刻；init 后注册的会在下个事件生效）
  static void register(TodoPlugin plugin) {
    if (_plugins.any((p) => p.name == plugin.name)) return;
    _plugins.add(plugin);
    unawaited(plugin.onInit());
  }

  static List<TodoPlugin> get plugins => List.unmodifiable(_plugins);

  /// 订阅仓库事件并启动插件。幂等：重复调用只初始化一次。
  static Future<void> init(TaskRepository repo) async {
    if (_inited) return;
    _inited = true;
    _sub = repo.events.listen(_handle);
    for (final p in _plugins) {
      try {
        await p.onInit();
      } catch (_) {}
    }
  }

  static Future<void> dispose() async {
    await _sub?.cancel();
    _sub = null;
    _inited = false;
    for (final p in _plugins) {
      try {
        await p.onDispose();
      } catch (_) {}
    }
  }

  static final Map<String, TaskEvent> _pendingUpdated = {};
  static final Map<String, Timer> _timers = {};

  static void _handle(TaskEvent e) {
    if (e.type == TaskEventType.updated) {
      _pendingUpdated[e.task.id] = e;
      _timers[e.task.id] ??=
          Timer(const Duration(milliseconds: 800), () => _flush(e.task.id));
      return;
    }
    _flush(e.task.id);
    _dispatch(e);
  }

  static void _flush(String taskId) {
    _timers.remove(taskId)?.cancel();
    final e = _pendingUpdated.remove(taskId);
    if (e != null) _dispatch(e);
  }

  static void _dispatch(TaskEvent e) {
    for (final p in _plugins) {
      unawaited(() async {
        try {
          await p.onTaskEvent(e);
        } catch (_) {
          // 插件出错绝不影响主流程
        }
      }());
    }
  }
}

/// 供测试注入假时钟/直接构造
typedef TaskEventSink = void Function(TaskEvent event);

/// 任务 → 事件便捷包装（仓库内部用）
TaskEvent taskEventOf(TaskEventType type, Task task, int at) =>
    TaskEvent(type, task, at);
