// 按**真实比例**摆图片（不裁切）—— 文件列表、网格、相册共用这一条规则。
//
// 为什么要有它：实测服务端给的缩略图就是原比例
// （`SYNO.FileStation.Thumb.get` 直接回原图字节、`SYNO.Foto.Thumbnail.get` 按短边
// 缩 —— 见 `docs/book-covers-and-pdf-toc.md` §1.5），方形是客户端 `BoxFit.cover`
// 裁出来的。裁切会丢内容：2:3 的封面被砍两侧、16:9 的照片被砍上下、
// 手机截图（0.46）被砍掉一大半。
//
// 用法：把一张 `fit: BoxFit.contain` 的图交给它，
//   * [aspect] 已知（文件头解析得到）→ 用 `AspectRatio` 把框收成图片比例，
//     视觉上是"贴着框"，而不是"留黑边"；
//   * [aspect] 未知（HEIC/AVIF、字节坏了）→ 原样返回，靠 `contain` 兜底，
//     **同样不裁**。
library;

import 'dart:typed_data';

import 'package:flutter/widgets.dart';

import 'image_size.dart';

/// 见文件头注释。
class AspectImage extends StatelessWidget {
  const AspectImage({super.key, required this.child, this.aspect});

  /// 内容（通常是 `Image(fit: BoxFit.contain)`）
  final Widget child;

  /// 宽 / 高；null 或非法值 → 直接返回 [child]
  final double? aspect;

  @override
  Widget build(BuildContext context) {
    final a = aspect;
    if (a == null || !a.isFinite || a <= 0) return child;
    return Center(
      child: AspectRatio(aspectRatio: a, child: child),
    );
  }
}

/// 一张图的宽高比（只读文件头，不解码）；读不出来返回 null。
double? aspectOfImageBytes(List<int>? bytes) {
  if (bytes == null || bytes.isEmpty) return null;
  final data = bytes is Uint8List ? bytes : Uint8List.fromList(bytes);
  final pixels = imageSizeFromBytes(data);
  if (pixels == null || pixels.height == 0) return null;
  final a = pixels.width / pixels.height;
  return (a.isFinite && a > 0) ? a : null;
}
