// ignore_for_file: avoid_print
//
// ★ 只读探针（D10 定性用）：把 NoteStation 列表里每条 note 的 `brief` **逐字符**打出来。
//
// 为什么需要它：`docs/android-ui-screenshot-audit.md` 的 D10（`note_10.png` 第 4 行
// "附件行行距与 1–3 行不一致"）已经用像素量到"多出的 52.7px ≈ 16.97dp = 恰好一个
// `bodySmall` 行盒"，代码里两侧用的是**同一个** `SizedBox(height: 4)`
// （`note_widgets.dart:377`）⇒ 只可能是 `brief` 被排成了两个行盒。
// `note_widgets.dart:368` 只做 `brief.trim()`，而 `\u200b`（零宽空格）**不属于**
// Dart 的 White_Space ⇒ `"a\n\u200b"` 这种 brief 会留下一个**看不见的第二行**。
// 这一步就是"读原始 brief"，把"可能"变成"是/不是"。
//
//   . /tmp/nas_cred.env
//   SYNO_NAS_URL="$NAS_URL" SYNO_NAS_ACCOUNT="$NAS_ACCOUNT" \
//   SYNO_NAS_PASSWORD="$NAS_PASSWORD" dart run tool/note_brief_probe.dart
//
// ★ 本探针**只调读方法**（`Note:list` / `Note:get`），不调用任何
//   `create/set/delete/update/add/upload`；结束时 `logout`。
import 'dart:convert';
import 'dart:io';

import 'package:synhub/src/core/net/dio_factory.dart';
import 'package:synhub/src/dsm/webapi.dart';

/// 一个字符是不是"看不见但占位"的（零宽 / 格式控制 / BOM / 软连字符…）
bool _invisible(int u) =>
    (u >= 0x200b && u <= 0x200f) || // 零宽空格/连接符/方向标记
    u == 0xfeff || // BOM
    u == 0x00ad || // 软连字符
    (u >= 0x202a && u <= 0x202e) ||
    (u >= 0x2060 && u <= 0x2064);

/// 把一段文本的"可疑字符"逐个列出来（只列不可见字符与换行/制表）
String _scan(String s) {
  final out = <String>[];
  for (var i = 0; i < s.length; i++) {
    final u = s.codeUnitAt(i);
    if (u == 0x0a || u == 0x0d || u == 0x09 || _invisible(u) || u < 0x20) {
      out.add('[$i]=U+${u.toRadixString(16).toUpperCase().padLeft(4, '0')}');
    }
  }
  return out.isEmpty ? '(无可疑字符)' : out.join(' ');
}

Future<void> main() async {
  final url = Platform.environment['SYNO_NAS_URL'];
  final account = Platform.environment['SYNO_NAS_ACCOUNT'];
  final password = Platform.environment['SYNO_NAS_PASSWORD'];
  if (url == null || account == null || password == null) {
    print('缺少 SYNO_NAS_URL / SYNO_NAS_ACCOUNT / SYNO_NAS_PASSWORD');
    exit(2);
  }
  final api = DsmWebApi(
    DirectTransport.url(url, dio: DioFactory.create(allowSelfSigned: true)),
  );
  await api.discover();
  await api.login(account: account, password: password, session: 'Chat');
  print('登录 OK（只读探针）');

  // 只读：笔记列表（v1，字段开关与 App 列表一致）
  final list = await api.call(
    'SYNO.NoteStation.Note',
    'list',
    preferredVersion: 1,
    params: {
      'field': jsonEncode({
        'old_parent_id': true,
        'individual_joined': true,
        'individual_shared': true,
      }),
    },
  );
  final notes = (list['notes'] as List?) ?? const [];
  print('笔记 ${notes.length} 条\n');

  var suspicious = 0;
  for (final raw in notes) {
    final n = Map<String, dynamic>.from(raw as Map);
    final brief = '${n['brief'] ?? ''}';
    final trimmed = brief.trim();
    final lines = trimmed.isEmpty ? 0 : '\n'.allMatches(trimmed).length + 1;
    final thumb = n['thumb_source'];
    final hasThumb = thumb is Map && (thumb['id'] ?? '').toString().isNotEmpty;
    final scan = _scan(brief);
    final bad = scan != '(无可疑字符)';
    if (bad) suspicious++;
    print('── ${n['object_id']}  ${jsonEncode(n['title'])}');
    print('   thumb=${hasThumb ? jsonEncode(thumb) : '—'}  brief.length=${brief.length}');
    print('   brief=${jsonEncode(brief)}');
    print('   trim 后行盒数=$lines（maxLines: 2 ⇒ 上限 2）');
    print('   可疑字符：$scan');
  }
  print('\n含可疑字符的笔记：$suspicious / ${notes.length}');

  // 对这些笔记再做一次**只读** get：看它是不是"附件行"（有 attachment / thumb_source）
  print('\n── 可疑 brief 的笔记，逐条 get（只读）看附件形态 ──');
  for (final raw in notes) {
    final n = Map<String, dynamic>.from(raw as Map);
    final brief = '${n['brief'] ?? ''}';
    if (!brief.contains('\n')) continue;
    final id = '${n['object_id']}';
    try {
      final one = await api.call(
        'SYNO.NoteStation.Note',
        'get',
        preferredVersion: 1,
        params: {
          'object_id': jsonEncode(id),
          'field': jsonEncode({'individual_shared': true}),
        },
      );
      final note = Map<String, dynamic>.from((one['note'] ?? one) as Map);
      final att = note['attachment'];
      final thumb = note['thumb_source'];
      print('${jsonEncode(note['title'])}：attachment='
          '${att is Map ? jsonEncode(att) : att}  '
          'thumb_source=${thumb is Map ? jsonEncode(thumb) : thumb}');
    } catch (e) {
      print('$id get 失败：$e');
    }
  }
  print('说明：`note_widgets.dart:365` 是 `if (brief.trim().isNotEmpty)`，'
      '行盒数 ≥ 2 且第 2 行只有零宽字符 ⇒ 渲染出"看不见的第二行"，'
      '在像素上就是 1–3 行**没有**、附件行才有的那多出来的一个 bodySmall 行盒。');

  await api.logout();
  exit(0);
}
