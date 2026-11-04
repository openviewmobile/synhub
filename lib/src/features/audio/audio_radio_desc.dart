// 电台「人话」清洗：**纯函数**，不含任何 UI（r631 立规，r653 搬家）。
//
// 为什么单独一个文件：r653 真机发现**通知栏**把 SHOUTcast 的 `desc` 原样当副标题
// （`MP3 (192 kbps)`），而迷你条与播放面板早就清洗成人话了 —— "同一个东西两处
// 两种读数"。清洗规则要能被**任意层**复用（现在 `media/audio_handler.dart` 在
// 发通知栏 `MediaItem` 时也调它），所以它不能再住在某个页面文件里。
//
final RegExp _codecParen = RegExp(
  r'\(\s*[^)]*(?:kbps|kb/s|kHz|bit|AAC|MP3|OGG|FLAC|WMA|HE-|HLS)[^)]*\)',
  caseSensitive: false,
);

/// 裸编码名（不带括号、单独成词）。
final RegExp _bareCodecWord = RegExp(
  r'\b(?:MP3|AAC\+?|OGG|FLAC|WMA|HLS|HE-AAC|AAC)\b',
  caseSensitive: false,
);

final RegExp _bareCodec = RegExp(
  r'^\s*(?:MP3|AAC|AAC\+|OGG|FLAC|WMA|HLS|MP3\s*\(?[0-9]*\s*kbps\)?)\s*$',
  caseSensitive: false,
);

/// 把电台 `desc` 里**纯技术**的片段摘掉，只留人话（r631）。
///
/// SHOUTcast / Icecast 目录里大量电台的 `desc` 就是 `MP3 (192 kbps)` 这种
/// 编码串 —— 旧版把它当列表行副标题、播放条副标题原样画出来。
/// 返回空串表示"这条描述里没有人话"，由调用方决定回落到什么。
String asRadioHumanDesc(String raw) {
  var s = raw.replaceAll(_codecParen, ' ');
  // 括号被摘掉之后常留下**裸编码名**（`Jazz 24/7 · MP3`），一并摘掉，
  // 否则行尾会挂一个没有信息量的 `MP3`。
  s = s.replaceAll(_bareCodecWord, ' ');
  s = s.replaceAll(RegExp(r'\s{2,}'), ' ').trim();
  s = s.replaceAll(RegExp(r'^[\s·,;|-]+|[\s·,;|-]+$'), '').trim();
  if (s.isEmpty) return '';
  if (_bareCodec.hasMatch(s)) return '';
  // 只剩分隔符/数字也算"没有人话"
  if (!RegExp(r'[A-Za-z\u4e00-\u9fff]').hasMatch(s)) return '';
  return s;
}
