import 'dart:async';
import 'dart:convert';
import 'dart:io' show exit;

import 'package:desktop_multi_window/desktop_multi_window.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter/services.dart';
import 'package:home_widget/home_widget.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:tray_manager/tray_manager.dart';
import 'package:window_manager/window_manager.dart';

import '../db/database.dart' show Task;
import '../providers.dart';
import '../repo/task_repository.dart';
import '../widget_bridge.dart';
import 'edit_task_dialog.dart';
import 'settings_dialog.dart';
import 'task_tile.dart';

class HomePage extends ConsumerStatefulWidget {
  const HomePage({super.key});

  @override
  ConsumerState<HomePage> createState() => _HomePageState();
}

class _HomePageState extends ConsumerState<HomePage>
    with WindowListener, TrayListener, WidgetsBindingObserver {
  /// 与 MainActivity 通信：消费掉卡片启动 Intent，避免重复执行
  static const _intentChannel = MethodChannel('todo/widget_intent');

  WindowController? _floatController;
  Timer? _floatNotifyDebounce;
  StreamSubscription<Uri?>? _widgetClickSub;
  DateTime? _lastResumeSync;

  bool get _isWindows =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.windows;
  bool get _isAndroid =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.android;

  @override
  void initState() {
    super.initState();
    // 启动自动同步一次（未配置则静默跳过）
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) ref.read(syncControllerProvider.notifier).run(auto: true);
    });
    if (_isAndroid) {
      WidgetsBinding.instance.addObserver(this);
      _lastResumeSync = DateTime.now(); // 启动同步已在上面触发，首次 resume 不重复
      // 圆点在桌面直接写库，原生需要知道 drift 库文件路径
      WidgetBridge.ensureDbPath();
      // 桌面卡片：旧版卡片点击会带 toggle 深链接进来（兼容兜底，新版走广播）
      () async {
        try {
          final initial = await HomeWidget.initiallyLaunchedFromHomeWidget();
          if (initial != null) {
            _handleWidgetUri(initial);
            // 同一个启动 Intent 只消费一次（进程被系统重建时不会把状态翻回去）
            await _intentChannel.invokeMethod<void>('consumeInitialIntent');
          }
        } catch (_) {}
        _widgetClickSub = HomeWidget.widgetClicked.listen(_handleWidgetUri);
      }();
    }
    if (_isWindows) {
      // ✕/主界面返回 → 隐藏到托盘（进程常驻，悬浮窗不受影响）
      unawaited(windowManager.setPreventClose(true));
      TrayManager.instance.addListener(this);
      _initTray();
      // 悬浮窗勾选任务后通知主窗口刷新
      () async {
        try {
          final me = await WindowController.fromCurrentEngine();
          await me.setWindowMethodHandler((call) async {
            if (call.method == 'refresh') ref.invalidate(tasksProvider);
            return null;
          });
        } catch (_) {
          // 桌面多窗口不可用时静默跳过
        }
      }();
      // 主窗口重新聚焦时强制刷新（悬浮窗可能改过数据库）
      windowManager.addListener(this);
    }
  }

  /// 桌面卡片圆点点击：切换该任务完成状态并静默同步
  void _handleWidgetUri(Uri? uri) {
    if (uri == null || uri.host != 'widget-toggle') return;
    final id = uri.queryParameters['id'];
    if (id == null || id.isEmpty) return;
    () async {
      try {
        final t = await ref.read(databaseProvider).getTaskById(id);
        if (t == null || t.deletedAt != null) return;
        await ref
            .read(taskRepoProvider)
            .setCompleted(t, done: t.completedAt == null);
        ref.invalidate(tasksProvider);
        ref.invalidate(activeTasksProvider);
        await ref.read(syncControllerProvider.notifier).run(auto: true);
      } catch (_) {}
    }();
  }

  // ---- 托盘（Windows）：✕ 最小化到托盘，托盘菜单控制 ----
  Future<void> _initTray() async {
    try {
      await TrayManager.instance.setIcon('assets/icon/tray_icon.ico');
      await TrayManager.instance.setToolTip('任务清单');
      final menu = Menu(items: [
        MenuItem(label: '显示主窗口', onClick: (menuItem) => _showMainWindow()),
        MenuItem(label: '显示/隐藏悬浮窗', onClick: (menuItem) => _toggleFloatWindow()),
        MenuItem.separator(),
        MenuItem(label: '退出', onClick: (menuItem) => _exitApp()),
      ]);
      await TrayManager.instance.setContextMenu(menu);
    } catch (_) {}
  }

  Future<void> _showMainWindow() async {
    await windowManager.show();
    await windowManager.focus();
  }

  /// 托盘「退出」：结束进程（悬浮窗随进程一并关闭）
  void _exitApp() {
    TrayManager.instance.removeListener(this);
    exit(0);
  }

  @override
  void onWindowClose() {
    // ✕ → 隐藏到托盘而不是退出（悬浮窗因此持续可用）
    windowManager.hide();
  }

  @override
  void onTrayIconMouseDown() {
    _showMainWindow();
  }

  @override
  void onTrayIconRightMouseDown() {
    // Windows 原生不自动弹菜单，需手动触发
    TrayManager.instance.popUpContextMenu();
  }

  @override
  void dispose() {
    if (_isAndroid) WidgetsBinding.instance.removeObserver(this);
    if (_isWindows) {
      TrayManager.instance.removeListener(this);
      _floatNotifyDebounce?.cancel();
      windowManager.removeListener(this);
      () async {
        try {
          final me = await WindowController.fromCurrentEngine();
          await me.setWindowMethodHandler(null); // 注销跨窗口 handler，释放闭包引用
        } catch (_) {}
      }();
    }
    _widgetClickSub?.cancel();
    super.dispose();
  }

  @override
  void onWindowFocus() {
    ref.invalidate(tasksProvider);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed) return;
    // 桌面圆点是在原生侧直接改库的，App 的查询流收不到通知：
    // 回到前台时重新查询一次，避免列表显示旧状态
    ref.invalidate(tasksProvider);
    ref.invalidate(activeTasksProvider);
    // 顺带补一次同步（60 秒内只触发一次，避免频繁切 App 造成无谓请求）
    final now = DateTime.now();
    final last = _lastResumeSync;
    if (last == null || now.difference(last) > const Duration(seconds: 60)) {
      _lastResumeSync = now;
      ref.read(syncControllerProvider.notifier).run(auto: true);
    }
  }

  /// 任务变化后主动通知悬浮窗刷新（防抖：一批变化只通知一次）。
  /// 悬浮窗自身有数据签名去重，重复通知无害。
  void _notifyFloatRefresh() {
    if (!_isWindows || _floatController == null) return;
    _floatNotifyDebounce?.cancel();
    _floatNotifyDebounce = Timer(const Duration(milliseconds: 800), () async {
      try {
        await _floatController?.invokeMethod('refresh');
      } catch (_) {
        _floatController = null; // 悬浮窗已销毁，下次重建
      }
    });
  }

  /// 打开/聚焦悬浮窗。数据库绝对路径随窗口参数传入
  /// （子引擎不注册任何 Flutter 插件，必须避免它自己解析路径）。
  Future<void> _toggleFloatWindow() async {
    if (_floatController == null) {
      final docs = await getApplicationDocumentsDirectory();
      final dbPath = p.join(docs.path, 'todo_app.sqlite');
      final controller = await WindowController.create(
        WindowConfiguration(
          arguments: jsonEncode({'entry': 'float_window', 'db': dbPath}),
        ),
      );
      _floatController = controller;
      await controller.show();
    } else {
      try {
        await _floatController!.invokeMethod('show');
      } catch (_) {
        _floatController = null; // 悬浮窗已被销毁，下次重建
      }
    }
  }

  /// 删除（软删除）+ 撤销入口
  Future<void> _deleteWithUndo(TaskRepository repo, Task t) async {
    await repo.delete(t);
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('已删除「${t.title}」'),
        behavior: SnackBarBehavior.floating,
        action: SnackBarAction(
          label: '撤销',
          onPressed: () => repo.restore(t),
        ),
      ),
    );
  }

  Future<void> _manualSync() async {
    final ok = await ref.read(syncControllerProvider.notifier).run();
    if (!ok && mounted) {
      final msg = ref.read(syncControllerProvider).message;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(msg ?? '同步失败'), width: 420),
      );
    }
  }

  Future<void> _openSettings() async {
    final saved = await showSettingsDialog(context, ref);
    if (saved && mounted) await _manualSync();
  }

  @override
  Widget build(BuildContext context) {
    final filter = ref.watch(taskFilterProvider);
    final tasksAsync = ref.watch(tasksProvider);
    final repo = ref.watch(taskRepoProvider);
    final syncState = ref.watch(syncControllerProvider);

    // 任务变化 → 更新荣耀桌面卡片快照 + 通知悬浮窗刷新
    ref.listen(activeTasksProvider, (_, next) {
      next.whenData((tasks) {
        WidgetBridge.update(tasks);
        _notifyFloatRefresh();
      });
    });

    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, result) {
        // 主页一级返回：直接结束应用回桌面（一步到位）
        if (!didPop) SystemNavigator.pop();
      },
      child: Scaffold(
      resizeToAvoidBottomInset: false, // 避让交给 QuickAddBar 手动处理（ROM 兼容）
      appBar: AppBar(
        automaticallyImplyLeading: false, // 隐藏误导性的返回箭头
        title: const Text('任务清单'),
        actions: [
          if (_isWindows)
            IconButton(
              onPressed: _toggleFloatWindow,
              tooltip: '悬浮窗（桌面常驻）',
              icon: const Icon(Icons.picture_in_picture_alt_outlined),
            ),
          IconButton(
            onPressed: syncState.phase == SyncPhase.syncing ? null : _manualSync,
            tooltip: switch (syncState.phase) {
              SyncPhase.syncing => '同步中…',
              SyncPhase.success => '已同步（点此再次同步）',
              SyncPhase.error => '同步失败：${syncState.message ?? ''}',
              SyncPhase.authError => syncState.message ?? '未配置同步',
              SyncPhase.idle => '同步',
            },
            icon: switch (syncState.phase) {
              SyncPhase.syncing =>
                const SizedBox.square(
                    dimension: 18, child: CircularProgressIndicator(strokeWidth: 2)),
              SyncPhase.success => const Icon(Icons.cloud_done_outlined),
              SyncPhase.error => Icon(Icons.cloud_off,
                  color: Theme.of(context).colorScheme.error),
              SyncPhase.authError => const Icon(Icons.cloud_off_outlined),
              SyncPhase.idle => const Icon(Icons.sync),
            },
          ),
          IconButton(
            onPressed: _openSettings,
            tooltip: '同步设置',
            icon: const Icon(Icons.settings_outlined),
          ),
          const SizedBox(width: 4),
        ],
      ),
      body: Column(
        children: [
          const QuickAddBar(),
          Expanded(
            child: tasksAsync.when(
              loading: () => const Center(child: CircularProgressIndicator()),
              error: (e, _) => Center(child: Text('加载失败：$e')),
              data: (tasks) => tasks.isEmpty
                  ? const Center(
                      child: Text('空空如也，在上方添加一个任务吧 ✨'),
                    )
                  : ListView.builder(
                      padding: const EdgeInsets.only(bottom: 24),
                      itemCount: tasks.length,
                      itemBuilder: (_, i) {
                        final t = tasks[i];
                        return TaskTile(
                          task: t,
                          onToggle: (done) => repo.setCompleted(t, done: done),
                          onDelete: () => _deleteWithUndo(repo, t),
                          onTap: () => showEditTaskDialog(context, ref, t),
                        );
                      },
                    ),
            ),
          ),
          Padding(
            // 底部叠加系统手势区高度，防导航键/手势条遮挡
            padding: EdgeInsets.fromLTRB(
                16, 4, 16, 12 + MediaQuery.paddingOf(context).bottom),
            child: SegmentedButton<TaskFilter>(
              segments: const [
                ButtonSegment(value: TaskFilter.all, label: Text('全部')),
                ButtonSegment(value: TaskFilter.active, label: Text('进行中')),
                ButtonSegment(value: TaskFilter.done, label: Text('已完成')),
              ],
              selected: {filter},
              onSelectionChanged: (s) =>
                  ref.read(taskFilterProvider.notifier).state = s.first,
            ),
          ),
        ],
      ),
      ),
    );
  }
}

/// 底部快速添加栏：输入标题回车即建任务
class QuickAddBar extends ConsumerStatefulWidget {
  const QuickAddBar({super.key});

  @override
  ConsumerState<QuickAddBar> createState() => _QuickAddBarState();
}

class _QuickAddBarState extends ConsumerState<QuickAddBar> {
  final _controller = TextEditingController();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _submit() {
    final text = _controller.text.trim();
    if (text.isEmpty) return;
    ref.read(taskRepoProvider).add(title: text);
    _controller.clear();
  }

  @override
  Widget build(BuildContext context) {
    // 顶部常驻：键盘物理上盖不到顶部输入框，任何机型/输入法都不遮挡
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
      child: TextField(
        controller: _controller,
        decoration: InputDecoration(
          hintText: '添加任务，回车确认',
          prefixIcon: const Icon(Icons.add_task),
          suffixIcon: IconButton(
            icon: const Icon(Icons.send),
            tooltip: '添加',
            onPressed: _submit,
          ),
          border: const OutlineInputBorder(),
        ),
        onSubmitted: (_) => _submit(),
        textInputAction: TextInputAction.done,
      ),
    );
  }
}
