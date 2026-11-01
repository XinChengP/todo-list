import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';

/// Windows 开机自启：FFI 直调 advapi32 写 HKCU Run 键（无插件依赖）。
/// 状态以注册表值为准：
/// - 值不存在 = 从未设置（首次运行 ensureDefault 会默认开启）
/// - 值为 DISABLED = 用户显式关闭（启动时不会覆盖）
class Win32AutoStart {
  Win32AutoStart._();

  static bool get isSupported => Platform.isWindows;

  static const int _hkeyCurrentUser = -2147483647; // 0x80000001
  static const int _keyQueryValue = 0x0001;
  static const int _keySetValue = 0x0002;
  static const int _regSz = 1;
  static const String _runKeyPath =
      r'Software\Microsoft\Windows\CurrentVersion\Run';
  static const String _valueName = 'TodoApp';

  static final _advapi32 = DynamicLibrary.open('advapi32.dll');
  static final _regOpenKeyExW = _advapi32.lookupFunction<
      Int32 Function(IntPtr, Pointer<Utf16>, Uint32, Int32, Pointer<IntPtr>),
      int Function(int, Pointer<Utf16>, int, int,
          Pointer<IntPtr>)>('RegOpenKeyExW');
  static final _regCreateKeyExW = _advapi32.lookupFunction<
      Int32 Function(IntPtr, Pointer<Utf16>, Uint32, Pointer<Utf16>, Uint32,
          Int32, Pointer<Void>, Pointer<IntPtr>, Pointer<Uint32>),
      int Function(int, Pointer<Utf16>, int, Pointer<Utf16>, int, int,
          Pointer<Void>, Pointer<IntPtr>, Pointer<Uint32>)>('RegCreateKeyExW');
  static final _regQueryValueExW = _advapi32.lookupFunction<
      Int32 Function(IntPtr, Pointer<Utf16>, Pointer<Uint32>, Pointer<Uint32>,
          Pointer<Uint8>, Pointer<Uint32>),
      int Function(int, Pointer<Utf16>, Pointer<Uint32>, Pointer<Uint32>,
          Pointer<Uint8>, Pointer<Uint32>)>('RegQueryValueExW');
  static final _regSetValueExW = _advapi32.lookupFunction<
      Int32 Function(IntPtr, Pointer<Utf16>, Uint32, Uint32, Pointer<Uint8>,
          Uint32),
      int Function(int, Pointer<Utf16>, int, int, Pointer<Uint8>,
          int)>('RegSetValueExW');
  static final _regDeleteValueW = _advapi32.lookupFunction<
      Int32 Function(IntPtr, Pointer<Utf16>),
      int Function(int, Pointer<Utf16>)>('RegDeleteValueW');
  static final _regCloseKey = _advapi32.lookupFunction<
      Int32 Function(IntPtr), int Function(int)>('RegCloseKey');

  static String get _exeCommand => '"${Platform.resolvedExecutable}"';

  static Pointer<Utf16> _u16(String s) => s.toNativeUtf16();

  /// 当前是否已启用（Run 键存在且为可执行命令）
  static bool isEnabled() {
    if (!isSupported) return false;
    final key = calloc<IntPtr>();
    final name = _u16(_runKeyPath);
    try {
      if (_regOpenKeyExW(_hkeyCurrentUser, name, 0, _keyQueryValue, key) != 0) {
        return false;
      }
      final data = calloc<Uint8>(512);
      final cb = calloc<Uint32>()..value = 512;
      try {
        final ok = _regQueryValueExW(key.value, _u16(_valueName), nullptr,
                nullptr, data, cb) ==
            0;
        if (!ok) return false;
        final s = data.cast<Utf16>().toDartString();
        return s.startsWith('"');
      } finally {
        calloc.free(data);
        calloc.free(cb);
      }
    } catch (_) {
      return false;
    } finally {
      if (key.value != 0) _regCloseKey(key.value);
      calloc.free(key);
      calloc.free(name);
    }
  }

  /// 首次运行时调用：从未设置过才默认开启（用户关闭后不覆盖）
  static void ensureDefault() {
    if (!isSupported) return;
    final key = calloc<IntPtr>();
    final name = _u16(_runKeyPath);
    final sub = _u16(_runKeyPath);
    try {
      if (_regOpenKeyExW(_hkeyCurrentUser, sub, 0, _keyQueryValue, key) != 0) {
        // 键不存在 → 首次 → 默认开启
        setEnabled(true);
      } else {
        // 键存在：检查值是否存在，不存在（首次）→ 开启；DISABLED 不动
        final valueName = _u16(_valueName);
        final cb = calloc<Uint32>();
        try {
          final exists = _regQueryValueExW(key.value, valueName, nullptr,
                  nullptr, nullptr, cb) ==
              0;
          if (!exists) setEnabled(true);
        } finally {
          calloc.free(cb);
          calloc.free(valueName);
        }
      }
    } catch (_) {
    } finally {
      if (key.value != 0) _regCloseKey(key.value);
      calloc.free(key);
      calloc.free(sub);
      calloc.free(name);
    }
  }

  static void setEnabled(bool on) {
    if (!isSupported) return;
    final key = calloc<IntPtr>();
    final name = _u16(_runKeyPath);
    try {
      if (_regCreateKeyExW(_hkeyCurrentUser, name, 0, nullptr, 0,
              _keySetValue, nullptr, key, nullptr) !=
          0) {
        return;
      }
      if (on) {
        final valueName = _u16(_valueName);
        final data = _u16(_exeCommand);
        try {
          _regSetValueExW(key.value, valueName, 0, _regSz, data.cast<Uint8>(),
              _exeCommand.length * 2 + 2);
        } finally {
          calloc.free(valueName);
          calloc.free(data);
        }
      } else {
        final valueName = _u16(_valueName);
        try {
          _regDeleteValueW(key.value, valueName); // 用户显式关闭
        } finally {
          calloc.free(valueName);
        }
      }
    } catch (_) {
    } finally {
      if (key.value != 0) _regCloseKey(key.value);
      calloc.free(key);
      calloc.free(name);
    }
  }
}
