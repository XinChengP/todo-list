import 'dart:async';
import 'dart:io';

import 'package:desktop_multi_window/desktop_multi_window.dart';
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'db/database.dart';
import 'repo/task_repository.dart';
import 'win32_float_window.dart';

/// Windows 悬浮窗：半透明、无边框、始终置顶的紧凑小窗，展示进行中的任务
/// 并可直接勾选完成。
///
/// 重要约束：desktop_multi_window 的子引擎不注册任何 Flutter 插件，
/// 因此这里：
/// - 数据库用 NativeDatabase 直连主窗口传入的文件路径（不走 path_provider）
/// - 窗口样式/置顶/拖动用 Win32FloatWindow（FFI 直调 user32/dwmapi）
/// - 跨窗口通信只用 desktop_multi_window 自带通道（show/refresh）
class FloatWindowApp extends StatefulWidget {
  const FloatWindowApp({super.key, required this.dbPath});

  final String dbPath;

  @override
  State<FloatWindowApp> createState() => _FloatWindowAppState();
}

class _FloatWindowAppState extends State<FloatWindowApp> {
  late final AppDatabase _db = AppDatabase.forTesting(
    NativeDatabase.createInBackground(
      File(widget.dbPath),
      setup: (db) => db.execute('PRAGMA busy_timeout = 3000'),
    ),
  );
  late final TaskRepository _repo = TaskRepository(_db);
  WindowController? _me;
  int? _hwnd;
  List<Task> _tasks = [];
  String _signature = ''; // 数据签名：无变化不 setState，避免无效重建
  bool _alwaysOnTop = true;
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    _configure();
    _load();
    _startTimer();
    () async {
      try {
        final me = await WindowController.fromCurrentEngine();
        _me = me; // 必须赋给字段，否则 hide/show 全是空操作
        await me.setWindowMethodHandler((call) async {
          if (call.method == 'show') {
            await _show();
          } else if (call.method == 'refresh') {
            await _load();
          }
          return null;
        });
      } catch (_) {
        // 通道不可用时依赖低频轮询
      }
    }();
  }

  @override
  void dispose() {
    _timer?.cancel();
    () async {
      try {
        final me = await WindowController.fromCurrentEngine();
        await me.setWindowMethodHandler(null);
      } catch (_) {}
    }();
    _db.close(); // 显式释放数据库连接
    super.dispose();
  }

  Future<void> _configure() async {
    // FFI 直调 Win32：无边框 + 分层半透明 + 置顶 + 右上角停靠 + Win11 圆角
    _hwnd = Win32FloatWindow.applyCompactTopRight();
    final hwndNow = _hwnd;
    if (hwndNow != null) {
      Win32FloatWindow.hideFromTaskbar(hwndNow); // 不进任务栏
    }
  }

  /// 取当前窗口控制器：优先用缓存，否则现场获取（保证关闭/唤起永远可用）
  Future<WindowController> _currentController() async {
    return _me ??= await WindowController.fromCurrentEngine();
  }

  Future<void> _hide() async {
    _timer?.cancel(); // 隐藏即停轮询（不等系统事件）
    try {
      await (await _currentController()).hide();
    } catch (_) {}
  }

  Future<void> _show() async {
    try {
      await (await _currentController()).show();
    } catch (_) {}
    if (_hwnd != null) {
      Win32FloatWindow.setTopmost(_hwnd!, _alwaysOnTop);
    }
    await _load();
  }

  // 低频兜底轮询：实时性主要靠 主窗口主动通知 + 打开/聚焦时刷新 + 手动刷新按钮。
  // 生命周期由自己的调用点管理：
  //   创建/被主窗口唤起 → 启动；点关闭（隐藏）/引擎销毁 → 停止
  void _startTimer() {
    _timer?.cancel();
    _timer = Timer.periodic(const Duration(minutes: 10), (_) => _load());
  }

  Future<void> _load() async {
    // 悬浮窗只列未完成任务：勾掉的任务立刻消失（主窗口仍可看已完成）
    final rows = (await _repo.watch().first)
        .where((t) => t.completedAt == null)
        .toList();
    final sig = rows
        .map((t) => '${t.id}:${t.completedAt != null}:${t.title}')
        .join('|');
    if (!mounted || sig == _signature) return; // 数据没变不重建
    _signature = sig;
    setState(() => _tasks = rows);
  }

  // ---- 手动拖动：FFI 读光标 + SetWindowPos 跟随（不用系统模态循环，跨线程安全） ----
  bool _dragging = false;
  int _dragStartCursorX = 0, _dragStartCursorY = 0;
  int _dragStartWinX = 0, _dragStartWinY = 0;

  void _dragBegin() {
    final hwnd = _hwnd;
    if (hwnd == null) return;
    final cursor = Win32FloatWindow.cursorPos();
    final win = Win32FloatWindow.windowRectPos(hwnd);
    _dragStartCursorX = cursor.x;
    _dragStartCursorY = cursor.y;
    _dragStartWinX = win.x;
    _dragStartWinY = win.y;
    _dragging = true;
  }

  void _dragMove() {
    if (!_dragging) return;
    final hwnd = _hwnd;
    if (hwnd == null) return;
    final cursor = Win32FloatWindow.cursorPos();
    Win32FloatWindow.moveWindow(
      hwnd,
      _dragStartWinX + cursor.x - _dragStartCursorX,
      _dragStartWinY + cursor.y - _dragStartCursorY,
    );
  }

  void _dragEnd() {
    _dragging = false;
  }

  /// 主窗口 id = 窗口列表里除自己以外的那个
  Future<String?> _mainWindowId() async {
    try {
      final me = await WindowController.fromCurrentEngine();
      for (final w in await WindowController.getAll()) {
        if (w.windowId != me.windowId) return w.windowId;
      }
    } catch (_) {}
    return null;
  }

  Future<void> _toggle(Task t) async {
    await _repo.setCompleted(t, done: t.completedAt == null);
    await _load();
    // 主窗口立即刷新
    final mainId = await _mainWindowId();
    if (mainId != null) {
      try {
        await WindowController.fromWindowId(mainId).invokeMethod('refresh');
      } catch (_) {}
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = ThemeData(
      useMaterial3: true,
      colorSchemeSeed: const Color(0xFF4F6DF5),
      brightness: Brightness.dark,
    );
    return MaterialApp(
      theme: theme,
      debugShowCheckedModeBanner: false,
      home: Scaffold(
        backgroundColor: const Color(0xD9141820), // 深色卡片，整窗再叠加系统级半透明
        body: Column(
          children: [
            // 标题栏：拖动区（原始指针事件 + FFI 移动窗口）+ 刷新 + 置顶 + 关闭
            Listener(
              onPointerDown: (_) => _dragBegin(),
              onPointerMove: (_) => _dragMove(),
              onPointerUp: (_) => _dragEnd(),
              onPointerCancel: (_) => _dragEnd(),
              child: Container(
                height: 28,
                decoration: const BoxDecoration(
                  color: Color(0x26FFFFFF),
                  borderRadius: BorderRadius.vertical(top: Radius.circular(12)),
                ),
                padding: const EdgeInsets.symmetric(horizontal: 8),
                child: Row(
                  children: [
                    const Icon(Icons.fact_check_outlined,
                        size: 12, color: Color(0xFF8AB4F8)),
                    const SizedBox(width: 5),
                    const Expanded(
                      child: Text('任务清单',
                          style: TextStyle(
                              fontSize: 11, fontWeight: FontWeight.w600)),
                    ),
                    _MiniButton(
                      icon: Icons.refresh,
                      tooltip: '立即刷新',
                      onTap: _load,
                    ),
                    _MiniButton(
                      icon: Icons.push_pin,
                      active: _alwaysOnTop,
                      tooltip: _alwaysOnTop ? '取消置顶' : '置顶',
                      onTap: () {
                        _alwaysOnTop = !_alwaysOnTop;
                        final hwnd = _hwnd;
                        if (hwnd != null) {
                          Win32FloatWindow.setTopmost(hwnd, _alwaysOnTop);
                        }
                        if (mounted) setState(() {});
                      },
                    ),
                    _MiniButton(
                      icon: Icons.close,
                      tooltip: '隐藏（主窗口可再次打开）',
                      onTap: _hide,
                    ),
                  ],
                ),
              ),
            ),
            Expanded(
              child: _tasks.isEmpty
                  ? const Center(
                      child: Text('今天没有待办 ✨',
                          style:
                              TextStyle(fontSize: 11, color: Colors.white38)),
                    )
                  : ListView.builder(
                      padding: const EdgeInsets.symmetric(vertical: 2),
                      itemCount: _tasks.length,
                      itemBuilder: (_, i) {
                        final t = _tasks[i];
                        final done = t.completedAt != null;
                        return InkWell(
                          onTap: () => _toggle(t),
                          child: Padding(
                            padding: const EdgeInsets.symmetric(
                                horizontal: 10, vertical: 5),
                            child: Row(
                              children: [
                                Icon(
                                  done
                                      ? Icons.check_circle
                                      : Icons.circle_outlined,
                                  size: 13,
                                  color: done
                                      ? const Color(0xFF8AB4F8)
                                      : Colors.white38,
                                ),
                                const SizedBox(width: 7),
                                Expanded(
                                  child: Text(
                                    t.title,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: TextStyle(
                                      fontSize: 12,
                                      color: done
                                          ? Colors.white30
                                          : Colors.white70,
                                      decoration: done
                                          ? TextDecoration.lineThrough
                                          : null,
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          ),
                        );
                      },
                    ),
            ),
            Container(
              height: 18,
              decoration: const BoxDecoration(
                color: Color(0x26FFFFFF),
                borderRadius:
                    BorderRadius.vertical(bottom: Radius.circular(12)),
              ),
              alignment: Alignment.centerLeft,
              padding: const EdgeInsets.only(left: 8),
              child: Text(
                '${_tasks.where((t) => t.completedAt == null).length} 项进行中 · 点击即完成',
                style: const TextStyle(fontSize: 9, color: Colors.white24),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _MiniButton extends StatelessWidget {
  const _MiniButton({
    required this.icon,
    required this.onTap,
    this.active = false,
    this.tooltip,
  });

  final IconData icon;
  final VoidCallback onTap;
  final bool active;
  final String? tooltip;

  @override
  Widget build(BuildContext context) {
    final button = InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(6),
      child: Padding(
        padding: const EdgeInsets.all(3),
        child: Icon(
          icon,
          size: 13,
          color: active ? const Color(0xFF8AB4F8) : Colors.white38,
        ),
      ),
    );
    if (tooltip == null) return button;
    return Tooltip(message: tooltip, child: button);
  }
}

/// 悬浮窗引擎入口（desktop_multi_window 以 'float_window' 参数拉起）
@pragma('vm:entry-point')
Future<void> floatWindowMain(String dbPath) async {
  if (!Platform.isWindows) return;
  runApp(ProviderScope(child: FloatWindowApp(dbPath: dbPath)));
}
