import 'package:flutter/material.dart';

/// 字阶：中文正文行高比 Material 默认更松（1.35~1.45），标题收字距。
///
/// 两套东西：
///   * 常规 UI 字阶（`textTheme` 覆盖）；
///   * **遥测字**（[telemetry]）—— 等宽 + 字距 + tabular figures，用来排时间、
///     人数、连接状态、分隔标签。这是 HUD 风格的签名之一：信息本身即装饰。
abstract final class AppType {
  /// 正文（消息正文用 `chatBody`，比 UI 正文略大）
  static const String mono = 'monospace';

  static TextTheme textTheme() {
    return const TextTheme(
      // 大标题（页面标题/登录标题）
      displaySmall: TextStyle(
        fontSize: 30,
        height: 1.2,
        fontWeight: FontWeight.w700,
        letterSpacing: -0.5,
      ),
      headlineSmall: TextStyle(
        fontSize: 24,
        height: 1.25,
        fontWeight: FontWeight.w700,
        letterSpacing: -0.3,
      ),
      // AppBar / 卡片标题
      titleLarge: TextStyle(
        fontSize: 19,
        height: 1.25,
        fontWeight: FontWeight.w700,
        letterSpacing: -0.2,
      ),
      titleMedium: TextStyle(
        fontSize: 16,
        height: 1.3,
        fontWeight: FontWeight.w600,
      ),
      titleSmall: TextStyle(
        fontSize: 14.5,
        height: 1.3,
        fontWeight: FontWeight.w600,
      ),
      // 正文
      bodyLarge: TextStyle(fontSize: 15.5, height: 1.42),
      bodyMedium: TextStyle(fontSize: 14, height: 1.4),
      bodySmall: TextStyle(fontSize: 12.5, height: 1.34),
      // 标签/按钮
      labelLarge: TextStyle(
        fontSize: 13.5,
        height: 1.25,
        fontWeight: FontWeight.w600,
      ),
      labelMedium: TextStyle(
        fontSize: 12,
        height: 1.2,
        fontWeight: FontWeight.w600,
        letterSpacing: 0.2,
      ),
      labelSmall: TextStyle(
        fontSize: 11,
        height: 1.2,
        fontWeight: FontWeight.w500,
        letterSpacing: 0.3,
      ),
    ).apply(bodyColor: null, displayColor: null);
  }

  /// 消息正文（比 UI 正文大一号，中文长文更好读）
  static const TextStyle chatBody = TextStyle(fontSize: 15.5, height: 1.42);

  /// 遥测小字：时间、人数、状态、分隔标签。
  ///
  /// 用 `monospace` 是刻意的（Android 上映射到 Roboto Mono/Droid Sans Mono），
  /// 不需要打包字体；`fontFeatures` 保证数字等宽不跳动。
  static TextStyle telemetry({
    double size = 11.5,
    FontWeight weight = FontWeight.w500,
    double letterSpacing = 0.6,
    Color? color,
  }) => TextStyle(
    fontFamily: mono,
    fontSize: size,
    height: 1.2,
    fontWeight: weight,
    letterSpacing: letterSpacing,
    color: color,
    fontFeatures: const [FontFeature.tabularFigures()],
  );
}

/// 代码/等宽块（链接预览里的 snippet、诊断页）
const TextStyle kCodeStyle = TextStyle(
  fontFamily: AppType.mono,
  fontSize: 12,
  height: 1.35,
  fontFeatures: [FontFeature.tabularFigures()],
);
