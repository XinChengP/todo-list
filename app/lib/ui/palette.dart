import 'package:flutter/material.dart';

/// 全项目配色唯一来源（App / 桌面卡片 / 悬浮窗 / 托盘共用同一品牌色）。
///
/// 品牌色沿用桌面卡片的主色 `#66CCFF`（浅蓝）。
/// 浅色界面里直接用它做文字/按钮对比度不够，所以另给一个同色相深调
/// `brandInk` 用于前景；两者同源，视觉上是一套色。
class AppPalette {
  AppPalette._();

  /// 品牌色（大面积/强调/卡片圆点/悬浮窗选中态）
  static const brand = Color(0xFF66CCFF);

  /// 品牌色的深调（浅色模式的按钮、链接、选中文字）
  static const brandInk = Color(0xFF0B7FB8);

  /// 品牌色深底上的文字色（深色模式按钮文字）
  static const onBrand = Color(0xFF00232F);

  // 语义色（优先级/逾期/成功）
  static const danger = Color(0xFFE05252);
  static const warning = Color(0xFFF2A03D);
  static const info = Color(0xFF4C9AFF);

  // Windows 悬浮窗（深色半透明叠加层）
  static const floatBg = Color(0xD9141820);
  static const floatHairline = Color(0x26FFFFFF);
  static const floatText = Color(0xB3FFFFFF); // ≈70%
  static const floatTextMuted = Color(0x61FFFFFF); // ≈38%
}
