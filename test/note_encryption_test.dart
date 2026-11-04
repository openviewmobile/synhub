// 加密笔记的接口层 + 服务层测试（离线，假传输）。
//
// 权威对照：
//   * `SYNO.NoteStation.Note.Encrypt` v1 的 create/check/delete
//     （DS note 1.12.0-346 `net/ApiNSNoteEncrypt.java`）
//   * 参数走 DSM CGI 参数加密（`SYNO.API.Encryption getinfo` + CgiEncryption，
//     官方 Android `SetNoteOperation.createToken`），duration=600
//   * `Note/set` 带 `encrypt` + `token`、`brief=""`（官方 Web 端 setNote）
import 'package:flutter_test/flutter_test.dart';
import 'package:synhub/src/data/dto/note_dto.dart';
import 'package:synhub/src/data/note_api.dart';
import 'package:synhub/src/data/note_crypto.dart';
import 'package:synhub/src/dsm/webapi.dart';
import 'package:synhub/src/features/notes/note_encryption.dart';

import 'support/chat_harness.dart' show FakeTransport;

const _table = {
  'SYNO.API.Info': {'path': 'query.cgi', 'minVersion': 1, 'maxVersion': 1},
  'SYNO.NoteStation.Note': {
    'path': 'entry.cgi',
    'minVersion': 1,
    'maxVersion': 4,
  },
  'SYNO.NoteStation.Note.Encrypt': {
    'path': 'entry.cgi',
    'minVersion': 1,
    'maxVersion': 1,
  },
  'SYNO.API.Encryption': {
    'path': 'entry.cgi',
    'minVersion': 1,
    'maxVersion': 1,
  },
};

/// `getinfo` 要回一个真的 RSA 公钥（SPKI DER base64）。
/// 下面是测试专用的 2048 位公钥（对应私钥没有出现在仓库里，也不需要）。
const _fakePublicKey =
    'MIIBIjANBgkqhkiG9w0BAQEFAAOCAQ8AMIIBCgKCAQEAqxY83fb0w7ovfj8+PV9u'
    'gVIz1BIZQAzWq1gQ8IrM79dfcvyc3aHymatCidV2UqQhzc6rxQF4uTgngSIAWqXV'
    'r3hD+uXA0IQUVt/HImZAwQKNN9dKFYGwduo/84tOVjnIFGC+hfazgm7UNsgymQ2'
    'wL7lm6B/2A3tloHKXXzk0yMOwqrUz1vZ4UW8R2cjHBCmcrfDZRBDhrmPGRVlYJhM'
    'TRFBeOBV3buZ/1/Mms+loFOV7WgXI4F4Fxtu5g5YMAAyPOVRJdEimhYLftmASQkd'
    '0Coz7HbFhSxW01Dn8kGPS2Rj2kEYKXd8w8KyfX2Loqryqxw4X6tPA3MAZ/OmKSwu'
    '9QIDAQAB';

Future<({FakeTransport t, DsmWebApi api, NoteStationApi notes})> _boot() async {
  final t = FakeTransport(
    {
      'SYNO.API.Encryption.getinfo': {
        'cipherkey': 'test-cipher-key',
        'ciphertoken': 'test-cipher-token',
        'public_key': _fakePublicKey,
        'server_time': 1700000000,
      },
      'SYNO.NoteStation.Note.Encrypt.create': {'token': 'TK-1'},
      'SYNO.NoteStation.Note.Encrypt.check': <String, dynamic>{},
      'SYNO.NoteStation.Note.Encrypt.delete': <String, dynamic>{},
      'SYNO.NoteStation.Note.set': {
        'data': [
          {'object_id': 'N1', 'ver': 'v2'},
        ],
      },
    },
    {...FakeTransport.table, ..._table},
  );
  final api = DsmWebApi(t);
  await api.discover();
  await api.login(account: 'a', password: 'b');
  return (t: t, api: api, notes: NoteStationApi(api));
}

void main() {
  group('Note.Encrypt 接口层', () {
    test(
      'createEncryptToken：拿 getinfo → CgiEncryption 加密参数 → 回 token',
      () async {
        final b = await _boot();
        final token = await b.notes.createEncryptToken(
          objectId: 'N1',
          password: 'pw',
        );
        expect(token, 'TK-1');
        final create = b.t.calls.lastWhere(
          (c) => c['api'] == 'SYNO.NoteStation.Note.Encrypt',
        );
        expect(create['method'], 'create');
        // 参数必须是**一个** cipherkey 字段（Android 就是这么发的），
        // 而不是明文 object_id/password/duration
        expect(create.containsKey('object_id'), isFalse);
        expect(create.containsKey('password'), isFalse);
        // 除 api/version/method/_sid 外**只能有 1 个**字段，就是 cipherkey
        final extra = create.keys
            .where(
              (k) => !const ['api', 'version', 'method', '_sid'].contains(k),
            )
            .toList();
        expect(
          extra,
          hasLength(1),
          reason: 'Android 就是这么发的：整个参数串加密后挂 cipherkey 一个字段',
        );
        expect(create[extra.single], isA<String>());
        expect(
          b.t.calls.any((c) => c['api'] == 'SYNO.API.Encryption'),
          isTrue,
          reason: '先 getinfo 拿公钥',
        );
      },
    );

    test('checkEncryptToken：成功=true，服务端报错=false（官方语义）', () async {
      final b = await _boot();
      expect(
        await b.notes.checkEncryptToken(objectId: 'N1', token: 'TK'),
        isTrue,
      );
      final call = b.t.calls.lastWhere((c) => c['method'] == 'check');
      expect(call['object_id'], '"N1"');
      expect(call['token'], '"TK"');

      b.t.failures['SYNO.NoteStation.Note.Encrypt.check'] = 101;
      expect(
        await b.notes.checkEncryptToken(objectId: 'N1', token: 'TK'),
        isFalse,
        reason: '令牌失效时接口报错 → 视为未解锁',
      );
      // 空 token 不必打网络
      final before = b.t.calls.length;
      expect(
        await b.notes.checkEncryptToken(objectId: 'N1', token: ''),
        isFalse,
      );
      expect(b.t.calls.length, before);
    });

    test('deleteEncryptToken：带 object_id + token', () async {
      final b = await _boot();
      await b.notes.deleteEncryptToken(objectId: 'N1', token: 'TK');
      final call = b.t.calls.lastWhere((c) => c['method'] == 'delete');
      expect(call['object_id'], '"N1"');
      expect(call['token'], '"TK"');
    });

    test('setNote 支持 encrypt + token（解密后的保存形态）', () async {
      final b = await _boot();
      final cipher = NoteCrypto.encryptContent('<p>x</p>', 'pw');
      await b.notes.setNote(
        objectId: 'N1',
        ver: 'v1',
        html: cipher,
        encrypt: true,
        token: 'TK-2',
        brief: '',
      );
      final set = b.t.calls.lastWhere((c) => c['method'] == 'set');
      expect(set['encrypt'], 'true');
      expect(set['token'], '"TK-2"');
      expect(set['brief'], '""');
      expect(set['content'], contains('U2FsdGVkX1'), reason: '存进去的必须是密文');
    });
  });

  group('NoteEncryptionService（口令与令牌）', () {
    test('unlock：本地解密 + 换令牌 + 记住口令', () async {
      final b = await _boot();
      final cipher = NoteCrypto.encryptContent('<p>机密</p>', 'pw');
      final note = NoteDto(
        objectId: 'N1',
        title: 't',
        content: cipher,
        ver: 'v1',
        encrypt: true,
        hasContent: true,
      );
      final store = NoteUnlockStore();
      final service = NoteEncryptionService(b.notes, store);
      final plain = await service.unlock(note, 'pw');
      expect(plain, '<p>机密</p>');
      expect(store.contains('N1'), isTrue);
      expect(store['N1']!.password, 'pw');
      expect(store['N1']!.token, 'TK-1');
    });

    test('unlock：口令不对 → NotePasswordException（不碰网络）', () async {
      final b = await _boot();
      final cipher = NoteCrypto.encryptContent('<p>机密</p>', 'right');
      final note = NoteDto(
        objectId: 'N1',
        title: 't',
        content: cipher,
        ver: 'v1',
        encrypt: true,
        hasContent: true,
      );
      final service = NoteEncryptionService(b.notes, NoteUnlockStore());
      final before = b.t.calls.length;
      await expectLater(
        service.unlock(note, 'wrong'),
        throwsA(isA<NotePasswordException>()),
      );
      expect(b.t.calls.length, before, reason: '本地就能判定口令错，不必打网络');
    });

    test('ensureToken：check 失败 → 重新 create', () async {
      final b = await _boot();
      final store = NoteUnlockStore();
      final service = NoteEncryptionService(b.notes, store);
      store.keep(
        'N1',
        NoteUnlock(password: 'pw', token: 'OLD', expiresAt: DateTime.now()),
      );
      b.t.responses['SYNO.NoteStation.Note.Encrypt.create'] = {'token': 'NEW'};
      final token = await service.ensureToken('N1');
      expect(token, 'NEW');
    });

    test('lock：清本地口令并通知服务端', () async {
      final b = await _boot();
      final store = NoteUnlockStore();
      final service = NoteEncryptionService(b.notes, store);
      store.keep(
        'N1',
        NoteUnlock(password: 'pw', token: 'TK', expiresAt: DateTime.now()),
      );
      await service.lock('N1');
      expect(store.contains('N1'), isFalse);
      expect(
        b.t.calls.any(
          (c) =>
              c['api'] == 'SYNO.NoteStation.Note.Encrypt' &&
              c['method'] == 'delete',
        ),
        isTrue,
      );
    });

    test('口令长度校验与官方一致（1~32）', () {
      expect(NoteEncryptionService.validatePassword(''), isNotNull);
      expect(NoteEncryptionService.validatePassword('a'), isNull);
      expect(NoteEncryptionService.validatePassword('a' * 32), isNull);
      expect(NoteEncryptionService.validatePassword('a' * 33), isNotNull);
    });
  });
}
