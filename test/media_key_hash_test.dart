// 媒体缓存键摘要的唯一实现（第 335 轮）。
//
// 期望值来自**独立 oracle**：Python 用任意精度整数算的 FNV-1a 64
// （`h ^= codeUnit; h = (h * 0x100000001b3) & 0xFFFFFFFFFFFFFFFF`，按 UTF-16 码元）。
// ⇒ 这不是"照着我自己的实现抄一遍"，而是拿另一套语言的结果对表（§2.0.31）。
//
// ★★★ 第 337 轮（D35）订正：**渲染形态也是有契约的**。老实现/真机用的是
// Dart 64 位**有符号** `int.toRadixString(16)` ⇒ 最高位为 1 时带 `-` 前缀、
// 且**不补零**（真机 logcat 的 `-375289b992ca068d_57.bin` 即此形）。
// r335 的"无符号 + 固定 16 位 + 左补零"曾让**缓存名全体漂移**，被
// `test/video_frame_thumb_failure_test.dart` ①-7（真机文件名逐字节）当场抓到。
// 这里的期望值仍是 Python oracle 算的，只是**按有符号形态**渲染。
import 'package:flutter_test/flutter_test.dart';
import 'package:synhub/src/core/media/media_key_hash.dart';

void main() {
  test('① 标准 FNV-1a 64 公开向量', () {
    expect(fnv1a64Hex(''), '-340d631b7bdddcdb'); // 无符号 cbf29ce484222325
    expect(fnv1a64Hex('a'), '-509c23b379fe1374'); // 无符号 af63dc4c8601ec8c
    expect(fnv1a64Hex('foobar'), '-7a6bbe8e08c69818'); // 无符号 85944171f73967e8
  });

  test('② 真实缓存键（Python oracle 对表）', () {
    expect(
      fnv1a64Hex('vframe|photos:personal:9659|1749238389|1876693'),
      'deadd0591d160be', // 高位零不补
    );
    expect(
      fnv1a64Hex('vframe|/home/Video/x.mp4|1|2048'),
      '-7de081bb935deee3',
    );
    expect(fnv1a64Hex('thumb|a.jpg|1|2'), '-f0e8b3e44360a30');
    expect(
      fnv1a64Hex('vframe|photos:personal:1|100|10'),
      '-5c7e027df06e30e',
    );
  });

  test('③ 非 ASCII 键按**码元**（不是 UTF-8 字节）混入 ⇒ 与旧实现一致', () {
    // 若改成 UTF-8 字节，这条会变（缓存名会全体漂移）——所以专门钉住。
    expect(fnv1a64Hex('照片目录/春节.jpg|1|2'), '3ae4f19e272fa314');
  });

  test('④ 形态 = `int.toRadixString(16)`（可有 `-`、不补零、小写），且不同键不同值', () {
    for (final k in ['', 'a', 'x' * 300, '照片', 'vframe|a|1|2']) {
      final h = fnv1a64Hex(k);
      expect(h.length, lessThanOrEqualTo(17), reason: k);
      expect(RegExp(r'^-?[0-9a-f]{1,16}$').hasMatch(h), isTrue, reason: h);
      expect(h, isNot(startsWith('0')), reason: '高位零必须去掉：$h');
    }
    expect(fnv1a64Hex('a'), isNot(fnv1a64Hex('b')));
    // ★ 反向：低字节非零的键不能被"截断"（limb 实现最容易在这里出错）
    expect(fnv1a64Hex('a').endsWith('00'), isFalse);
  });
}
