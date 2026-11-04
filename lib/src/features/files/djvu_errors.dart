// DJVU 解析/解码的异常类型 —— 纯 Dart，零 flutter / l10n 依赖。
//
// 之所以单独一个文件：容器（`djvu_archive.dart`）、BZZ（`djvu_bzz.dart`）、
// JB2（`djvu_jb2.dart`）、IW44（`djvu_iw44.dart`）互相引用，异常定义放在
// 叶子文件里可以避免循环 import 的语义纠缠。
//
// 两类错误**必须分开**（对齐 `chm_archive.dart` 的口径）：
//   * [DjvuUnsupportedException]：格式认识，但这个变体我们做不到（加密、
//     未实现的编码分支、缺字典…）—— "换别的工具还有救"；
//   * [DjvuFormatException]：文件坏了 / 截断 / 结构自相矛盾 —— 数据本身的问题。
//
// 两者最终都会被 `book_djvu.dart` 翻译成界面上的"这本书打不开"。

/// 能力边界：格式认识、但这个变体做不到。
class DjvuUnsupportedException implements Exception {
  DjvuUnsupportedException(this.message);
  final String message;
  @override
  String toString() => 'DJVU 不支持：$message';
}

/// 文件损坏 / 截断 / 结构自相矛盾 / 越界。
class DjvuFormatException implements Exception {
  DjvuFormatException(this.message);
  final String message;
  @override
  String toString() => 'DJVU 解析失败：$message';
}
