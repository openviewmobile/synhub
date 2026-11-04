// 加密笔记的**服务端语义**探针（只读 + 自建自删）。
//
// 目的：把"哪些字段服务端认、token 到底是不是必需的、错误码是什么"钉死。
// 对照两处官方实现：
//   * Web（NoteStation 2.6.10-3938 `ui/notestation.js`）：明文 password +
//     `duration:120` → `Note.Encrypt/create`，30s 轮询 `check`；
//   * Android（DS note 1.12.0-346 `SetNoteOperation.createToken`）：
//     `SYNO.API.Encryption getinfo` → CgiEncryption 加密 `object_id/password/
//     duration:600` → `Note.Encrypt/create`，保存时 `Note.Polling/set` 带 token。
//
// 运行：
//   SYNO_NAS_URL=… SYNO_ACCOUNT=… SYNO_PASSWORD=… dart run tool/note_encrypt_probe.dart
// ignore_for_file: avoid_print
import 'dart:convert';
import 'dart:io';

import 'package:synhub/src/core/net/dio_factory.dart';
import 'package:synhub/src/data/note_api.dart';
import 'package:synhub/src/data/note_crypto.dart';
import 'package:synhub/src/dsm/webapi.dart';

const nsApi = 'SYNO.NoteStation.Note';
const encApi = 'SYNO.NoteStation.Note.Encrypt';
const pw = 'probe-pw-123';

Future<void> main() async {
  final api = DsmWebApi(
    DirectTransport.url(
      Platform.environment['SYNO_NAS_URL']!,
      dio: DioFactory.create(allowSelfSigned: true),
    ),
  );
  await api.discover();
  await api.login(
    account: Platform.environment['SYNO_ACCOUNT']!,
    password: Platform.environment['SYNO_PASSWORD']!,
    session: 'Chat',
  );
  final notes = NoteStationApi(api);
  final plain = '<p>机密：藏宝图在沙发底下</p>';
  final cipher = NoteCrypto.encryptContent(plain, pw);
  print('本地密文（前 24 字符）：${cipher.substring(0, 24)}…');

  final book = (await notes.listNotebooks()).first;
  final created = await notes.createNote(
    title: 'enc-probe',
    parentId: book.objectId,
    html: cipher,
    encrypt: true,
  );
  print(
    '① Note/create(encrypt=true, content=密文) → '
    'object_id=${created.objectId} ver=${created.ver}',
  );

  final got = await notes.getNote(created.objectId);
  print(
    '② Note/get → encrypt=${got.encrypt} '
    'contentIsCipher=${got.content == cipher} '
    'brief=${got.brief.isEmpty ? '(空)' : got.brief}',
  );
  print('   本地解密回正文：${NoteCrypto.decryptContent(got.content, pw)}');

  // ③ Web 端做法：明文 password + duration=120（服务端也收，用来对照）
  try {
    final r = await api.call(
      encApi,
      'create',
      preferredVersion: 1,
      params: {
        'object_id': jsonEncode(created.objectId),
        'password': jsonEncode(pw),
        'duration': '120',
      },
    );
    print(
      '③ Encrypt/create 明文 duration=120 → token=${'${r['token']}'.substring(0, 8)}…',
    );
  } catch (e) {
    print('③ Encrypt/create 明文 → $e');
  }

  // ④ Android 做法（我们采用）：CgiEncryption 加密参数，duration=600
  String? token;
  try {
    token = await notes.createEncryptToken(
      objectId: created.objectId,
      password: pw,
    );
    print(
      '④ createEncryptToken（加密参数, duration=600）→ '
      'token=${token.substring(0, 8)}…',
    );
  } catch (e) {
    print('④ createEncryptToken → $e');
  }

  // ⑤ check：有效 token / 乱写的 token
  if (token != null) {
    print(
      '⑤ check(有效 token) → ${await notes.checkEncryptToken(objectId: created.objectId, token: token)}',
    );
  }
  print(
    '⑤ check(假 token) → ${await notes.checkEncryptToken(objectId: created.objectId, token: 'deadbeef')}',
  );

  // ⑥ 保存：不带 token / 带 token
  try {
    await notes.setNote(
      objectId: created.objectId,
      ver: got.ver,
      html: NoteCrypto.encryptContent('<p>改了</p>', pw),
      encrypt: true,
    );
    print('⑥ set(encrypt=true, 不带 token) → 通过（服务端不强制 token）');
  } catch (e) {
    print('⑥ set(不带 token) → $e');
  }
  final again = await notes.getNote(created.objectId);
  if (token != null) {
    try {
      await notes.setNote(
        objectId: created.objectId,
        ver: again.ver,
        html: NoteCrypto.encryptContent('<p>带 token 改的</p>', pw),
        encrypt: true,
        token: token,
      );
      final after = await notes.getNote(created.objectId);
      print(
        '⑥ set(带 token) → 通过；回读解密='
        '${NoteCrypto.decryptContent(after.content, pw)}',
      );
    } catch (e) {
      print('⑥ set(带 token) → $e');
    }
  }

  // ⑦ 主动丢弃解锁令牌，之后 check 应该变 false
  if (token != null) {
    try {
      await notes.deleteEncryptToken(objectId: created.objectId, token: token);
      print(
        '⑦ deleteEncryptToken → check='
        '${await notes.checkEncryptToken(objectId: created.objectId, token: token)}',
      );
    } catch (e) {
      print('⑦ deleteEncryptToken → $e');
    }
  }

  // 收尾：彻底删掉探针笔记
  await notes.deleteNote(created.objectId, recycle: false);
  print('⑧ 探针笔记已彻底删除（recycle=false）');
  api.transport.close();
  exit(0);
}
