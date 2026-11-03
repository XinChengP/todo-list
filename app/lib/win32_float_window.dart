import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';

/// 悬浮窗引擎的 Win32 窗口控制（FFI 直调，不依赖任何插件）。
///
/// 背景：desktop_multi_window 的子引擎不注册任何 Flutter 插件，
/// window_manager / path_provider 等在其中全部不可用，只能 FFI 直调。
/// 目标窗口定位：进程内类名为 FLUTTER_MULTI_WINDOW_WIN32_WINDOW 的
/// 顶层窗口（主窗口是 runner 自己的类，不会误匹配）。
class Win32FloatWindow {
  Win32FloatWindow._();

  static bool get isSupported => Platform.isWindows;

  static const _className = 'FLUTTER_MULTI_WINDOW_WIN32_WINDOW';
  static const _gwlpStyle = -16;
  static const _gwlpExStyle = -20;
  static const _wsCaption = 0x00C00000;
  static const _wsThickframe = 0x00040000;
  static const _wsPopup = 0x80000000;
  static const _wsExLayered = 0x00080000;
  static const _swpNosize = 0x0001;
  static const _swpNomove = 0x0002;
  static const _swpNoActivate = 0x0010;
  static const _wsExToolwindow = 0x00000080;
  static const _wsExAppwindow = 0x00040000;
  static const _swpFrameChanged = 0x0020;
  static const _swpShowWindow = 0x0040;
  static const _hwndTopmost = -1;
  static const _hwndNotopmost = -2;
  static const _lwaAlpha = 0x2;
  static const _wmNcLButtonDown = 0xA1;
  static const _htCaption = 2;
  static const _spiGetWorkArea = 0x0030;
  static const _dwmwaCornerPreference = 33; // DWMWA_WINDOW_CORNER_PREFERENCE
  static const _dwmwcpRound = 2; // DWMWCP_ROUND

  static final _user32 = DynamicLibrary.open('user32.dll');
  static final _dwmapi = DynamicLibrary.open('dwmapi.dll');
  static final _kernel32 = DynamicLibrary.open('kernel32.dll');

  static final _createMutexW = _kernel32.lookupFunction<
      Pointer<Void> Function(Pointer<Void>, Int32, Pointer<Utf16>),
      Pointer<Void> Function(Pointer<Void>, int,
          Pointer<Utf16>)>('CreateMutexW');
  static final _getLastError = _kernel32.lookupFunction<Uint32 Function(),
      int Function()>('GetLastError');
  static final _getCurrentProcessId = _kernel32.lookupFunction<
      Uint32 Function(), int Function()>('GetCurrentProcessId');
  static final _getWindowThreadProcessId = _user32.lookupFunction<
      Uint32 Function(IntPtr, Pointer<Uint32>),
      int Function(int, Pointer<Uint32>)>('GetWindowThreadProcessId');
  static final _getWindowLongPtr = _user32.lookupFunction<
      IntPtr Function(IntPtr, Int32),
      int Function(int, int)>('GetWindowLongPtrW');
  static final _setWindowLongPtr = _user32.lookupFunction<
      IntPtr Function(IntPtr, Int32, IntPtr),
      int Function(int, int, int)>('SetWindowLongPtrW');
  static final _setWindowPos = _user32.lookupFunction<
      Int32 Function(IntPtr, IntPtr, Int32, Int32, Int32, Int32, Uint32),
      int Function(
          int, int, int, int, int, int, int)>('SetWindowPos');
  static final _setLayeredWindowAttributes = _user32.lookupFunction<
      Int32 Function(IntPtr, Uint32, Uint8, Uint32),
      int Function(int, int, int, int)>('SetLayeredWindowAttributes');
  static final _sendMessage = _user32.lookupFunction<
      Int32 Function(IntPtr, Uint32, IntPtr, IntPtr),
      int Function(int, int, int, int)>('SendMessageW');
  static final _getCursorPos = _user32.lookupFunction<
      Int32 Function(Pointer<PointStruct>),
      int Function(Pointer<PointStruct>)>('GetCursorPos');
  static final _getWindowRect = _user32.lookupFunction<
      Int32 Function(IntPtr, Pointer<RectStruct>),
      int Function(int, Pointer<RectStruct>)>('GetWindowRect');
  static final _systemParametersInfo = _user32.lookupFunction<
      Int32 Function(Uint32, Uint32, Pointer<Void>, Uint32),
      int Function(int, int, Pointer<Void>, int)>('SystemParametersInfoW');
  static final _dwmSetWindowAttribute = _dwmapi.lookupFunction<
      Int32 Function(IntPtr, Int32, Pointer<Void>, Uint32),
      int Function(int, int, Pointer<Void>, int)>('DwmSetWindowAttribute');

  /// 从任务栏隐藏窗口（TOOLWINDOW + 去 APPWINDOW），用于悬浮窗
  static void hideFromTaskbar(int hwnd) {
    final ex = _getWindowLongPtr(hwnd, _gwlpExStyle);
    _setWindowLongPtr(
        hwnd, _gwlpExStyle, (ex | _wsExToolwindow) & ~_wsExAppwindow);
    _setWindowPos(hwnd, 0, 0, 0, 0, 0,
        _swpNomove | _swpNosize | _swpNoActivate | _swpFrameChanged);
  }

  /// 进程级单实例互斥：已有实例运行时返回 false（二次启动应直接退出）
  static bool acquireSingleInstance(String mutexName) {
    final name = mutexName.toNativeUtf16();
    try {
      _createMutexW(nullptr, 0, name);
      return _getLastError() != 183; // ERROR_ALREADY_EXISTS
    } catch (_) {
      return true; // 无法判断时按首实例处理
    } finally {
      calloc.free(name);
    }
  }

  /// 把本进程的主窗口藏起来（等价"最小化到托盘"）。
  ///
  /// 不用 windowManager.hide()：它内部懒解析窗口句柄，开机自启场景我们从未
  /// 调用过 show()，句柄可能还没缓存 → hide() 静默无效（实测主窗口仍然可见）。
  /// 这里直接按「本进程 + 有标题」定位主窗口（悬浮窗是无标题的），ShowWindow(SW_HIDE)。
  static bool hideMainWindow() {
    if (!isSupported) return false;
    final pid = _getCurrentProcessId();
    var hidden = false;
    final callback = NativeCallable<EnumWindowsProcNative>.isolateLocal(
      (int hwnd, int lParam) {
        final pidBuf = calloc<Uint32>();
        try {
          _getWindowThreadProcessId(hwnd, pidBuf);
          if (pidBuf.value != pid) return 1;
          // 不加 IsWindowVisible 前置判断：首帧时主窗口可能还没被 runner 显示，
          // 判断会把"稍后才出现"的主窗口漏掉（踩过）。ShowWindow 对已隐藏窗口无害。
          if (_getWindowTextLengthW(hwnd) <= 0) return 1; // 无标题 = 悬浮窗
          _showWindow(hwnd, 0); // SW_HIDE
          hidden = true;
        } finally {
          calloc.free(pidBuf);
        }
        return 1;
      },
      exceptionalReturn: 0,
    );
    try {
      _enumWindows(callback.nativeFunction, 0);
    } catch (_) {
    } finally {
      callback.close();
    }
    return hidden;
  }

  static final _getWindowTextLengthW = _user32.lookupFunction<
      Int32 Function(IntPtr), int Function(int)>('GetWindowTextLengthW');
  static final _showWindow = _user32.lookupFunction<
      Int32 Function(IntPtr, Int32), int Function(int, int)>('ShowWindow');

  /// 找悬浮窗的 HWND。
  ///
  /// 关键：主窗口与悬浮窗**同进程、同类名**（都是 Flutter 的多窗口顶层窗口），
  /// 只按类名+pid 匹配会命中主窗口，随后 applyCompactTopRight 的
  /// SetWindowPos(..., SWP_SHOWWINDOW) 会把主窗口重新显示出来（踩过）。
  /// 区分依据：主窗口有标题（"任务清单"），悬浮窗没有标题。
  static int? findHwnd() {
    final pid = _getCurrentProcessId();
    int? found;
    final callback = NativeCallable<EnumWindowsProcNative>.isolateLocal(
      (int hwnd, int lParam) {
        final classBuf = calloc<Uint16>(64);
        try {
          _getClassName(hwnd, classBuf, 64);
          final cls = classBuf.cast<Utf16>().toDartString();
          if (cls == _className) {
            final pidBuf = calloc<Uint32>();
            try {
              _getWindowThreadProcessId(hwnd, pidBuf);
              if (pidBuf.value == pid && _getWindowTextLengthW(hwnd) == 0) {
                found = hwnd;
                return 0; // 找到即停
              }
            } finally {
              calloc.free(pidBuf);
            }
          }
        } finally {
          calloc.free(classBuf);
        }
        return 1; // 继续枚举
      },
      exceptionalReturn: 0,
    );
    try {
      _enumWindows(callback.nativeFunction, 0);
    } catch (_) {
      return null;
    } finally {
      callback.close();
    }
    return found;
  }

  // EnumWindows / GetClassNameW 的 native 签名
  static final _enumWindows = _user32.lookupFunction<
      Int32 Function(Pointer<NativeFunction<EnumWindowsProcNative>>, IntPtr),
      int Function(
          Pointer<NativeFunction<EnumWindowsProcNative>>, int)>('EnumWindows');
  static final _getClassName = _user32.lookupFunction<
      Int32 Function(IntPtr, Pointer<Uint16>, Int32),
      int Function(int, Pointer<Uint16>, int)>('GetClassNameW');

  /// 无边框 + 分层半透明 + 置顶 + 右上角停靠 + Win11 圆角。
  /// 返回悬浮窗 HWND（找不到返回 null）。
  static int? applyCompactTopRight({
    int width = 270,
    int height = 380,
    int alpha = 228, // 0-255，约 89% 不透明
  }) {
    if (!isSupported) return null;
    final hwnd = findHwnd();
    if (hwnd == null) return null;

    // 去边框：剥掉 CAPTION/THICKFRAME，改 POPUP
    var style = _getWindowLongPtr(hwnd, _gwlpStyle);
    style = (style & ~(_wsCaption | _wsThickframe)) | _wsPopup;
    _setWindowLongPtr(hwnd, _gwlpStyle, style);

    // 分层窗口 → 整窗半透明
    final ex = _getWindowLongPtr(hwnd, _gwlpExStyle);
    _setWindowLongPtr(hwnd, _gwlpExStyle, ex | _wsExLayered);
    _setLayeredWindowAttributes(hwnd, 0, alpha, _lwaAlpha);

    // 右上角停靠（工作区内）
    final rect = calloc<RectStruct>();
    try {
      _systemParametersInfo(_spiGetWorkArea, 0, rect.cast<Void>(), 0);
      final x = rect.ref.right - width - 12;
      final y = rect.ref.top + 12;
      _setWindowPos(hwnd, _hwndTopmost, x, y, width, height,
          _swpFrameChanged | _swpShowWindow | _swpNoActivate);
    } finally {
      calloc.free(rect);
    }

    // Win11 圆角（失败静默，Win10 方角可接受）
    final pref = calloc<Uint32>()..value = _dwmwcpRound;
    try {
      _dwmSetWindowAttribute(hwnd, _dwmwaCornerPreference, pref.cast<Void>(), 4);
    } catch (_) {} finally {
      calloc.free(pref);
    }
    return hwnd;
  }

  static void setTopmost(int hwnd, bool on) {
    _setWindowPos(
        hwnd,
        on ? _hwndTopmost : _hwndNotopmost,
        0, 0, 0, 0,
        _swpNomove | _swpNosize | _swpNoActivate);
  }

  /// 开始拖动：伪装标题栏点击交给系统模态循环。
  /// 仅在同线程窗口模型下可靠；子引擎跨线程场景请用
  /// cursorPos/windowRect/moveWindow 手动跟随（见 FloatWindowApp）。
  static void startDrag(int hwnd) {
    _sendMessage(hwnd, _wmNcLButtonDown, _htCaption, 0);
  }

  /// 当前光标位置（屏幕坐标）
  static ({int x, int y}) cursorPos() {
    final pt = calloc<PointStruct>();
    try {
      if (_getCursorPos(pt) == 0) return (x: 0, y: 0);
      return (x: pt.ref.x, y: pt.ref.y);
    } finally {
      calloc.free(pt);
    }
  }

  /// 窗口当前位置（屏幕坐标）
  static ({int x, int y}) windowRectPos(int hwnd) {
    final rect = calloc<RectStruct>();
    try {
      if (_getWindowRect(hwnd, rect) == 0) return (x: 0, y: 0);
      return (x: rect.ref.left, y: rect.ref.top);
    } finally {
      calloc.free(rect);
    }
  }

  /// 移动窗口到指定屏幕坐标（不改大小、不抢焦点）
  static void moveWindow(int hwnd, int x, int y) {
    _setWindowPos(hwnd, 0, x, y, 0, 0,
        _swpNosize | _swpNoActivate | 0x0004 /*SWP_NOZORDER*/);
  }
}

typedef EnumWindowsProcNative = Int32 Function(IntPtr hwnd, IntPtr lParam);

final class PointStruct extends Struct {
  @Int32()
  external int x;

  @Int32()
  external int y;
}

final class RectStruct extends Struct {
  @Int32()
  external int left;

  @Int32()
  external int top;

  @Int32()
  external int right;

  @Int32()
  external int bottom;
}
