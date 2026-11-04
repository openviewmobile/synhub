// 媒体缓存键的**唯一**摘要实现（第 335 轮）。
//
// 为什么要有这个文件：
//   * 原来 `thumb_cache.dart` 与 `video_frame_thumb.dart` **各写了一份** FNV-1a 64
//     哈希（§2.0.26「同一语义被造成两份表示」）——两份必然会漂移；
//   * 两份都用了 `0xcbf29ce484222325`、`0xFFFFFFFFFFFFFFFF` 这类**64 位字面量**，
//     而 dart2js 的 `int` 是 JS number（2^53 精确上限）⇒ `flutter build web` 直接
//     `Error: The integer literal … can't be represented exactly in JavaScript`。
//
// ★ 修法选择（不是"糊过去"）：**保留 FNV-1a 64 的精确语义**，但用
//   **4 个 16 位 limb** 做乘法（每个中间量 ≤ 2^34，JS 也精确）⇒
//   输出与原实现**逐字节相同** ⇒ 缓存文件名不变（用户无感，老缩略图不作废），
//   而 web/native 得到**同一套**名字（不是"两个平台两套算法"）。
//
// ★ 输入语义照旧：按 Dart 的 `String.codeUnits`（UTF-16 码元）逐个混入，
//   **不是** UTF-8 字节 —— 改这个会让所有非 ASCII 键的缓存名变化。
library;

/// FNV-1a 64（输入 = Dart `String.codeUnits`），渲染形态见文件尾的说明。
String fnv1a64Hex(String key) => _fnv1a64HexOfUnits(key.codeUnits);

/// FNV-1a 64，但输入是**原始字节**（r434 新增：PDF 本地副本的内容摘要）。
///
/// ★ 语义与 [fnv1a64Hex] 是**两个命名空间**（一个混 UTF-16 码元、一个混 0..255 字节），
///   所以同内容的字节与字符串**不保证**同摘要 —— 这就是它单独一个函数名的原因，
///   调用方别把两者互换（那会让缓存名漂移）。
String fnv1a64HexBytes(List<int> bytes) => _fnv1a64HexOfUnits(bytes);

String _fnv1a64HexOfUnits(Iterable<int> units) {
  // ★ limb 一律**低位在前**，两处都别写反（第 335 轮第一次实现就是这里反了，
  //   低 32 位对、高 32 位错 —— 单测的 oracle 向量当场抓到）。
  // 偏移基准 0xcbf29ce484222325 → (0x2325, 0x8422, 0x9ce4, 0xcbf2)
  var h0 = 0x2325, h1 = 0x8422, h2 = 0x9ce4, h3 = 0xcbf2;
  // 质数 0x100000001b3 → (0x01b3, 0x0000, 0x0100, 0x0000)
  const p0 = 0x01b3, p2 = 0x0100;

  for (final unit in units) {
    // ① 异或：只影响最低 16 位
    h0 ^= unit & 0xFFFF;
    // ② 乘质数：q_i = Σ h_{i-j} * p_j（p1 = p3 = 0 已省略）。
    //    每项 ≤ 2^32、加一个进位 ⇒ 每个 q ≤ 2^33，远在 2^53 内（web 也精确）。
    final q0 = h0 * p0;
    final q1 = h1 * p0 + (q0 >> 16);
    final q2 = h2 * p0 + h0 * p2 + (q1 >> 16);
    final q3 = h3 * p0 + h1 * p2 + (q2 >> 16);
    h0 = q0 & 0xFFFF;
    h1 = q1 & 0xFFFF;
    h2 = q2 & 0xFFFF;
    h3 = q3 & 0xFFFF; // mod 2^64：超出第 4 个 limb 的部分丢掉
  }

  // ★★★ 第 337 轮（D35）：**渲染形态必须与老实现/真机逐字节相同**。
  //   老实现是 Dart 的 64 位**有符号** `int` 直接 `toRadixString(16)`：
  //     * 最高位为 1 ⇒ 输出 `-` + **补码绝对值**（例如 `-375289b992ca068d`）；
  //     * **不补零**（`0deadd0591d160be` 会渲染成 `deadd0591d160be`）。
  //   真机 logcat 里的 `path=-375289b992ca068d_57.bin` 就是这一形态（见
  //   `test/video_frame_thumb_failure_test.dart` ①-7）。r335 曾改成"无符号 + 固定 16 位 +
  //   左补零"⇒ **缓存名全体漂移**（旧缩略图/封面全部作废、再下一次）——按 §2.0.26
  //   "同一语义不许有两种表示"，这里只保留**一种**渲染。
  //   ★ 负数走"逐 limb 取反加一"，全程 ≤ 2^16 ⇒ web 上也精确（不碰 2^64）。
  final neg = (h3 & 0x8000) != 0;
  if (!neg) return _hexNoPad(h0, h1, h2, h3);
  var m0 = (~h0) & 0xFFFF;
  var m1 = (~h1) & 0xFFFF;
  var m2 = (~h2) & 0xFFFF;
  var m3 = (~h3) & 0xFFFF;
  m0 += 1;
  if (m0 > 0xFFFF) {
    m0 &= 0xFFFF;
    m1 += 1;
    if (m1 > 0xFFFF) {
      m1 &= 0xFFFF;
      m2 += 1;
      if (m2 > 0xFFFF) {
        m2 &= 0xFFFF;
        m3 += 1;
        m3 &= 0xFFFF;
      }
    }
  }
  return '-${_hexNoPad(m0, m1, m2, m3)}';
}

/// 4 个 16 位 limb（**低位在前**）→ 十六进制串，**高位零不补**（与 `int.toRadixString(16)` 同形）。
String _hexNoPad(int l0, int l1, int l2, int l3) {
  final buf = StringBuffer();
  var started = false;
  for (final limb in [l3, l2, l1, l0]) {
    final s = limb.toRadixString(16).padLeft(4, '0');
    if (started) {
      buf.write(s);
      continue;
    }
    final t = s.replaceFirst(RegExp(r'^0+'), '');
    if (t.isEmpty) continue;
    buf.write(t);
    started = true;
  }
  return started ? buf.toString() : '0';
}
