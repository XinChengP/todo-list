import 'package:flutter/foundation.dart' show defaultTargetPlatform, TargetPlatform;
import 'package:flutter/material.dart';

import 'palette.dart';

/// 全局主题：圆角卡片 + 柔和底色 + 轻量输入框，双端一致。
///
/// 设计取向：信息密度不变，只把"方块感"去掉——
/// 任务变成圆角卡片、输入框填色去边框、分隔线尽量用留白代替。
ThemeData buildAppTheme(Brightness brightness) {
  final isDark = brightness == Brightness.dark;
  // 品牌色只有一个来源（AppPalette.brand = #66CCFF，与桌面卡片一致）；
  // 浅色模式把 primary 换成同色相深调，保证按钮/链接的对比度
  final scheme = ColorScheme.fromSeed(
    seedColor: AppPalette.brand,
    brightness: brightness,
  ).copyWith(
    primary: isDark ? AppPalette.brand : AppPalette.brandInk,
    onPrimary: isDark ? AppPalette.onBrand : Colors.white,
    error: AppPalette.danger,
  );
  // Windows 上显式指定中文字体：默认 Segoe UI 的中文是回退字体，
  // 中英混排时字号/基线会不齐；雅黑 UI 原生支持中文。
  final isWindows = defaultTargetPlatform == TargetPlatform.windows;
  final fontFamily = isWindows ? 'Microsoft YaHei UI' : null;
  final fontFallback =
      isWindows ? const ['Microsoft YaHei', 'Segoe UI'] : null;

  final canvas = isDark ? scheme.surface : const Color(0xFFF6F7FB);
  // 浅色下不要用纯白：对话框/卡片本身也是白色，输入框会"消失"
  final fieldFill = isDark
      ? scheme.surfaceContainerHighest.withValues(alpha: 0.45)
      : scheme.surfaceContainerHighest.withValues(alpha: 0.40);
  final hairline = scheme.outlineVariant.withValues(alpha: isDark ? 0.35 : 0.55);

  OutlineInputBorder border(Color color, [double width = 1]) => OutlineInputBorder(
        borderRadius: BorderRadius.circular(14),
        borderSide: BorderSide(color: color, width: width),
      );

  // 字体只使用真实存在的字重：雅黑只有 Regular/Bold，
  // 用 w500/w600 会触发合成加粗（笔画糊、发虚）。因此正文 w400、标题 w700。
  final base = ThemeData(
    useMaterial3: true,
    colorScheme: scheme,
    fontFamily: fontFamily,
    fontFamilyFallback: fontFallback,
    scaffoldBackgroundColor: canvas,
    visualDensity: VisualDensity.standard,
    appBarTheme: AppBarTheme(
      backgroundColor: canvas,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      scrolledUnderElevation: 0,
      centerTitle: false,
      // 不单独写字重/字距：交给 textTheme.titleLarge（w700 = 雅黑真 Bold）
      titleTextStyle: TextStyle(
        fontSize: 20,
        fontWeight: FontWeight.w700,
        color: scheme.onSurface,
      ),
    ),
    cardTheme: CardThemeData(
      elevation: 0,
      margin: EdgeInsets.zero,
      color: isDark ? scheme.surfaceContainerLow : Colors.white,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: BorderSide(color: hairline),
      ),
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: fieldFill,
      isDense: true,
      contentPadding:
          const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      border: border(Colors.transparent),
      enabledBorder: border(Colors.transparent),
      focusedBorder: border(scheme.primary, 1.6),
      hintStyle: TextStyle(color: scheme.outline, fontSize: 14),
      helperStyle: TextStyle(color: scheme.outline, fontSize: 11),
      labelStyle: TextStyle(color: scheme.outline),
    ),
    chipTheme: ChipThemeData(
      side: BorderSide.none,
      shape: const StadiumBorder(),
      showCheckmark: false,
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      labelStyle: TextStyle(fontSize: 13, color: scheme.onSurface),
      selectedColor: scheme.primaryContainer,
      backgroundColor: isDark
          ? scheme.surfaceContainerHighest.withValues(alpha: 0.5)
          : Colors.white,
    ),
    segmentedButtonTheme: SegmentedButtonThemeData(
      style: ButtonStyle(
        visualDensity: VisualDensity.compact,
        side: WidgetStatePropertyAll(BorderSide(color: hairline)),
        shape: WidgetStatePropertyAll(
          RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        ),
        // 选中态显式绑品牌色：默认的 secondaryContainer 在浅色下偏灰，
        // 看起来像禁用；这里用品牌蓝浅底 + 深蓝字
        backgroundColor: WidgetStateProperty.resolveWith(
          (states) => states.contains(WidgetState.selected)
              ? (isDark
                  ? AppPalette.brand.withValues(alpha: 0.22)
                  : AppPalette.brand.withValues(alpha: 0.28))
              : Colors.transparent,
        ),
        foregroundColor: WidgetStateProperty.resolveWith(
          (states) => states.contains(WidgetState.selected)
              ? (isDark ? AppPalette.brand : AppPalette.brandInk)
              : scheme.onSurfaceVariant,
        ),
      ),
    ),
    snackBarTheme: SnackBarThemeData(
      behavior: SnackBarBehavior.floating,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      insetPadding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
    ),
    dialogTheme: DialogThemeData(
      backgroundColor: isDark ? scheme.surfaceContainerLow : Colors.white,
      surfaceTintColor: Colors.transparent,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
    ),
    dividerTheme: DividerThemeData(color: hairline, thickness: 1, space: 24),
    listTileTheme: ListTileThemeData(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
      iconColor: scheme.outline,
    ),
    checkboxTheme: CheckboxThemeData(
      shape: const CircleBorder(),
      side: BorderSide(color: scheme.outline, width: 1.6),
      fillColor: WidgetStateProperty.resolveWith(
        (states) => states.contains(WidgetState.selected)
            ? scheme.primary
            : Colors.transparent,
      ),
    ),
    // 顶栏动作较多（搜索/筛选/悬浮窗/同步/说明/设置），紧凑密度保证
    // 360dp 窄屏也不会把标题挤没
    iconButtonTheme: IconButtonThemeData(
      style: ButtonStyle(
        visualDensity: VisualDensity.compact,
        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
      ),
    ),
    bottomSheetTheme: BottomSheetThemeData(
      backgroundColor: isDark ? scheme.surfaceContainerLow : Colors.white,
      surfaceTintColor: Colors.transparent,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
    ),
  );

  // 统一字号/字重阶梯（避免各控件里散落 fontSize: 11/13 这类硬编码）
  return base.copyWith(
    textTheme: base.textTheme.copyWith(
      titleLarge: const TextStyle(fontSize: 20, fontWeight: FontWeight.w700),
      titleMedium: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700),
      titleSmall: const TextStyle(fontSize: 13.5, fontWeight: FontWeight.w700),
      bodyLarge: const TextStyle(fontSize: 15, fontWeight: FontWeight.w400),
      bodyMedium: const TextStyle(fontSize: 13.5, fontWeight: FontWeight.w400),
      bodySmall: const TextStyle(fontSize: 12, fontWeight: FontWeight.w400),
      labelSmall: const TextStyle(fontSize: 11.5, fontWeight: FontWeight.w400),
      labelMedium: const TextStyle(fontSize: 12.5, fontWeight: FontWeight.w500),
    ),
  );
}
