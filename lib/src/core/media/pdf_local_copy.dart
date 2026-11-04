// PDF 的**本地副本**落盘（r434）。
//
// 背景（真机只读枚举 + 插件源码，两条腿都在）：
//   * 真机 `/data/data/com.openviewai.synhub/cache/` **根层**躺着 18 个
//     `<32 位十六进制>.pdf`（962 B 那份的正文就是 r344 的 `ai_report_en.pdf`）；
//   * 根因 = `pdfx-2.11.0` 的 `openDataDocument`：
//     `File(binding.applicationContext.cacheDir, "$randomFilename.pdf")`
//     （`Messages.kt:360`，`randomFilename` = UUID 去横线 ⇒ 32 位十六进制）。
//     凡走 `PdfDocument.openData` 的路径，插件都会把**整份 PDF** 写到缓存根层。
//
// 为什么这是缺陷（不是"插件的事"）：
//   * 我们的 `CacheService` 按**目录**登记（`kRegenerableCacheDirs`）⇒ 根层文件
//     ① 用量统计看不到、②「清空缓存」删不掉、③ 上限淘汰也不会碰它；
//     而对话框明说会删"cached attachments, thumbnails and previews"；
//   * `randomFilename` **每次新名字** ⇒ 打开一次 PDF 就多一份，不设上限。
//
// 修法（源头 + 兜底，两层）：
//   * 源头：我们**自己**把字节写到**已登记**的 `pdf_renderer_cache/`，
//     文件名叫**内容摘要**（同一份 PDF 复用同一个文件），再 `openFile` ⇒
//     插件不再落根层，副本天然被"用量 / 清理 / 上限淘汰"覆盖；
//   * 兜底：`CacheService.kCacheRootRegenerablePatterns` 仍认根层那种名字，
//     把历史遗留（以及别的插件若同样写根层）一并回收。
library;

import 'dart:io';
import 'dart:typed_data';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'media_key_hash.dart';

/// 字节 → 本地副本的绝对路径（可注入 ⇒ 离线用例不碰平台通道）。
typedef PdfLocalCopy = Future<String> Function(Uint8List bytes);

/// 落盘目录名。**必须**是 [kRegenerableCacheDirs] 里登记过的那一个：
/// 只有这样副本才会被统计、被「清空缓存」删掉、被上限淘汰。
const String kPdfLocalCopyDirName = 'pdf_renderer_cache';

/// 生产实现（见文件头的"修法 · 源头"）。
///
/// [root] 只是给用例注入临时根（生产不传 ⇒ `path_provider` 的缓存目录）。
Future<String> defaultPdfLocalCopy(Uint8List bytes, {Directory? root}) async {
  final base = root ?? await getApplicationCacheDirectory();
  final dir = Directory(p.join(base.path, kPdfLocalCopyDirName));
  if (!await dir.exists()) await dir.create(recursive: true);
  final name = '${fnv1a64HexBytes(bytes)}.pdf';
  final file = File(p.join(dir.path, name));
  // 同名同长度 = 同一份内容 ⇒ 直接复用（不重写、不刷 mtime）。
  // 摘要碰撞或内容变了但长度相同 —— 后者会留下**旧内容**，所以再比一次首尾字节。
  if (!await file.exists() || !await _sameContent(file, bytes)) {
    await file.writeAsBytes(bytes, flush: false);
  }
  return file.path;
}

Future<bool> _sameContent(File file, Uint8List bytes) async {
  try {
    final st = await file.stat();
    if (st.size != bytes.length) return false;
    if (bytes.isEmpty) return true;
    final head = await file.openRead(0, bytes.length < 512 ? bytes.length : 512).first;
    final tailStart = bytes.length < 512 ? 0 : bytes.length - 512;
    // 头部一致 + 长度一致就认为复用（全量比对对大 PDF 不划算；错判只是重写一次）。
    return _sameSlice(head, bytes, 0, head.length) &&
        (tailStart == 0 ||
            _sameSlice(
              await file.openRead(tailStart).first,
              bytes,
              tailStart,
              bytes.length - tailStart,
            ));
  } catch (_) {
    return false;
  }
}

bool _sameSlice(List<int> a, Uint8List b, int offset, int len) {
  if (a.length < len) return false;
  for (var i = 0; i < len; i++) {
    if (a[i] != b[offset + i]) return false;
  }
  return true;
}
