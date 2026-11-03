import 'dart:convert';
import 'dart:io' show Platform, exit;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:window_manager/window_manager.dart';

import 'float_window.dart';
import 'ui/home_page.dart';
import 'win32_float_window.dart';
import 'win32_autostart.dart';

Future<void> main(List<String> args) async {
  WidgetsFlutterBinding.ensureInitialized();

  // desktop_multi_window 0.3 拉起的子窗口引擎：
  // args = ['multi_window', <windowId>, <configuration.arguments>]
  if (args.length >= 3 && args[0] == 'multi_window') {
    Map<String, dynamic>? cfg;
    try {
      cfg = jsonDecode(args[2]) as Map<String, dynamic>?;
    } catch (_) {}
    if (cfg?['entry'] == 'float_window' && cfg?['db'] is String) {
      await floatWindowMain(cfg!['db'] as String);
      return;
    }
    return; // 未知子窗口参数，不渲染任何东西
  }

  // 单实例：已有实例（托盘/悬浮窗常驻）运行时，二次启动直接退出
  if (defaultTargetPlatform == TargetPlatform.windows &&
      !Win32FloatWindow.acquireSingleInstance('TodoAppWinInstance')) {
    exit(0);
  }

  // 开机自启（注册表里带 --startup）：主窗口不弹出，只留托盘图标 + 自动开悬浮窗
  final startInTray =
      !kIsWeb && Platform.isWindows && args.contains(Win32AutoStart.startupArg);

  await _initMainWindow(startInTray: startInTray);
  runApp(ProviderScope(child: TodoApp(startInTray: startInTray)));
}

Future<void> _initMainWindow({bool startInTray = false}) async {
  if (kIsWeb || defaultTargetPlatform != TargetPlatform.windows) return;
  try {
    // 开机自启默认开启（注册表 Run 键；用户可在设置里关闭，关闭状态不会被覆盖）
    Win32AutoStart.ensureDefault();
  } catch (_) {}
  try {
    await windowManager.ensureInitialized();
    await windowManager.waitUntilReadyToShow(
      const WindowOptions(
        size: Size(430, 780),
        minimumSize: Size(360, 620),
        title: '任务清单',
      ),
      () async {
        if (startInTray) {
          // 开机自启：不亮主窗口，直接藏起来（托盘与悬浮窗在 HomePage 里起）
          await windowManager.hide();
        } else {
          await windowManager.show();
          await windowManager.focus();
        }
      },
    );
  } catch (_) {
    // 测试环境或窗口管理不可用时静默跳过
  }
}

class TodoApp extends StatelessWidget {
  const TodoApp({super.key, this.startInTray = false});

  final bool startInTray;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: '任务清单',
      theme: ThemeData(
        useMaterial3: true,
        colorSchemeSeed: const Color(0xFF4F6DF5),
        brightness: Brightness.light,
      ),
      darkTheme: ThemeData(
        useMaterial3: true,
        colorSchemeSeed: const Color(0xFF4F6DF5),
        brightness: Brightness.dark,
      ),
      home: HomePage(startInTray: startInTray),
    );
  }
}
