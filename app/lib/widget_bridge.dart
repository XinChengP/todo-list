import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:home_widget/home_widget.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'db/database.dart';
import 'db/sync_fields.dart';
import 'repo/repeat.dart';
import 'ui/format.dart' show isOverdue;

/// 荣耀/MagicOS 服务卡片的数据桥：
/// 任务变化时把"未完成任务快照"写进 home_widget 的
/// SharedPreferences（HomeWidgetPreferences），并触发卡片重渲染。
///
/// 耗电设计（重要）：
/// - 内容级去重：任务内容没变绝不写盘、不广播（同步回写本地行时
///   任务流会连续发射多次，不去重会把同样的快照写 N 遍）
/// - 800ms 防抖：一次同步/一批操作只产生最后一次写入
/// - 写失败不记账：pending 保留，下次任务变化自动重试
/// - 无后台轮询：卡片自身 30 分钟周期刷新只做本地渲染，不碰网络
class WidgetBridge {
  WidgetBridge._();

  /// 每种卡片尺寸一个 Provider（MagicOS 卡片选择器按 Provider 区分尺寸）
  static const _qualifiedProviderNames = [
    'io.github.xinchengp.todo_app.TodoWidgetProvider', // 4x2
    'io.github.xinchengp.todo_app.TodoWidgetProvider2x2', // 2x2
    'io.github.xinchengp.todo_app.TodoWidgetProvider4x4', // 4x4（最多 5 条）
  ];
  static Timer? _debounce;
  static String? _lastContent; // 最近一次成功写入的内容（用于去重）
  static String? _pendingContent; // 待写入内容
  static List<Task>? _pendingTasks;

  /// 把数据库绝对路径交给原生侧。
  ///
  /// 卡片圆点的"完成"由 WidgetToggleReceiver 直接在桌面处理（不打开 App），
  /// 原生代码需要知道 drift 库文件在哪；路径以 Flutter 的 path_provider
  /// 解析结果为准，Kotlin 里不硬编码 /data/user/0/... 这类内部路径。
  static Future<void> ensureDbPath() async {
    if (!Platform.isAndroid) return;
    try {
      final docs = await getApplicationDocumentsDirectory();
      await HomeWidget.saveWidgetData<String>(
        'todo_db_path',
        p.join(docs.path, 'todo_app.sqlite'),
      );
    } catch (_) {
      // 插件不可用时忽略：圆点点击会退化为无操作，不影响 App 内操作
    }
  }

  static void update(List<Task> activeTasks) {
    if (!Platform.isAndroid) return;
    // 对比"内容"（不含时间戳）：数据没变就什么都不做
    final content = jsonEncode(_contentMap(activeTasks));
    if (content == _lastContent) return;
    _pendingContent = content;
    _pendingTasks = activeTasks;
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 800), _flush);
  }

  static Future<void> _flush() async {
    final tasks = _pendingTasks;
    final content = _pendingContent;
    if (tasks == null || content == null) return;
    try {
      final payload = jsonEncode({
        'updatedAt': nowMs(),
        ..._contentMap(tasks),
      });
      await HomeWidget.saveWidgetData<String>('todo_snapshot', payload);
      for (final name in _qualifiedProviderNames) {
        await HomeWidget.updateWidget(qualifiedAndroidName: name);
      }
      _lastContent = content;
      if (_pendingContent == content) {
        _pendingContent = null;
        _pendingTasks = null;
      }
    } catch (_) {
      // 失败保留 pending，下次任务变化自动重试
    }
  }

  /// 卡片内容（不含时间戳，时间戳只在落盘时生成）
  static Map<String, dynamic> _contentMap(List<Task> activeTasks) => {
        'activeCount': activeTasks.length,
        'tasks': [
          for (final t in activeTasks.take(5))
            {
              'id': t.id,
              'title': t.title,
              'done': t.completedAt != null,
              'due': _dueLabel(t.dueAt),
              'priority': t.priority,
              // 周期标签（"每天"/"每 3 周"），空串表示不重复
              'repeat': repeatLabel(t.repeatUnit, t.repeatInterval),
              'overdue': t.dueAt != null &&
                  isOverdue(t.dueAt!) &&
                  t.completedAt == null,
            },
        ],
      };

  static String _dueLabel(int? ms) {
    if (ms == null) return '';
    final d = DateTime.fromMillisecondsSinceEpoch(ms);
    return '${d.month}/${d.day}';
  }
}
