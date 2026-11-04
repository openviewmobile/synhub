// ★★ **③Drive 第 65 轮：D58 加密 Office 文档** —— 订正"没有解密凭据通道"的错误论断
//
// ## D58 缺口原文
// > `D58 / :400 | **加密 Office 文档** | `Office.Node.Encrypt/check` + 密码框 |
// >  🟠部分 | `features/drive/drive_encrypt_gate.dart:49`、`:67`
// >  （弹"请到服务器访问"） | 缺口：能识别+提示，**无密码输入/解密**`
//
// ## ★★ 被订正的论断
// `drive_encrypt_gate.dart` 文件头原先写着：
// > 「本 App 打开 Office 原生文档走的是"取原生字节 / OOXML 预览"，
// >  **拿不到能用于解密的凭据通道** → 只如实提示，不假装支持。」
//
// **这句话是错的**，是我早期未验证的假设。官方 `Snapshot/get` 本来就收密码：
//
// | 来源 | 事实 |
// |---|---|
// | `ApiSynoOfficeSnapshot.setAsGet(linkId, **password**)`（`:53-64`） | **总是** `putParam("password", …)`（空串也发） |
// | 服务端 `.lib` | `SYNO.Office.Snapshot` `min=1 max=4`，**`get` 在 v1–v4 都有** |
// | `ApiSynoOfficeNodeEncrypt.setAsCheck(fileId, **password**, sharingToken)` | 密码是**明文** `putParam`（同 D39 的 `protect_password`） |
// | `SYNO.Office.Node.Encrypt` `.lib` | `min=1 max=1`，**只有 `check`** |
//
// ⇒ 正确流程：`Node.Encrypt/check`（验密码）→ 用**同一密码**
// `Snapshot/get`（取**已解密**内容）。密码是有用的。
//
// ## 本文件钉什么
// ① `snapshotGet` **真的发** `password`（此前完全没发）；
// ② `check` 带密码；密码**明文**、**不许**出现 `cipherkey`（防"按印象加密"）；
// ③ 57373 = 需要密码（官方 `isNeedPasswordException`）；
// ④ `.lib` 的方法表与版本（`Encrypt` 只有 `check`；`Snapshot:get` 跨 v1–v4）。
//
// 全程内存 Mock，不碰真机（规程 §5.1）。
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:synhub/src/data/drive_api.dart';
import 'package:synhub/src/data/office_api.dart';
import 'package:synhub/src/dsm/webapi.dart';
import 'package:synhub/src/features/office/office_doc_page.dart';
import 'package:synhub/src/features/office/office_sheet_page.dart';
import 'package:synhub/src/features/office/office_slides_page.dart';

import '../tool/mock_dsm/mock_dsm_core.dart';
import 'support/mock_dsm_transport.dart';

const _encrypt = 'SYNO.Office.Node.Encrypt';
const _snapshot = 'SYNO.Office.Snapshot';
const _node = 'SYNO.Office.Node';

void main() {
  late MockDsmBackend backend;
  late DsmWebApi web;

  setUp(() async {
    backend = MockDsmBackend(catalog: DsmCatalog.load());
    backend.login(username: 'demo_user', admin: false);
    backend.fixture(_snapshot, 'get', (p) => {'success': true, 'data': {}});
    backend.fixture(_encrypt, 'check', (p) => {'success': true, 'data': {}});
    web = DsmWebApi(MockDsmTransport(backend));
    await web.discover();
    await web.login(account: 'demo_user', password: 'x');
  });

  Map<String, dynamic> lastOf(String api, String method) {
    final r = backend.requests
        .where((r) => '${r.params['api']}' == api)
        .where((r) => '${r.params['method']}' == method)
        .toList();
    expect(r, isNotEmpty, reason: '必须真的发出了 $api/$method');
    return r.last.params;
  }

  group('DE58-1. ★★★ `Snapshot/get` **真的发密码**（此前完全没发）', () {
    test('★★★ 密码原样出现在 `password`（官方总是发，空串也发）', () async {
      await OfficeApi(web).snapshotGet(linkId: 'link1', password: 'secret123');
      final p = lastOf(_snapshot, 'get');
      expect(p['link_id'], 'link1');
      expect(
        p['password'],
        'secret123',
        reason:
            '★★★ 官方 `ApiSynoOfficeSnapshot.setAsGet(linkId, password)`'
            ' **总是** putParam("password", …)。'
            '不发的后果：加密文档永远取不到内容，'
            '而用户已经输了正确的密码 —— 最令人费解的一种失败',
      );
    });

    test('★★ 不传密码时发**空串**（不是省略）—— 与官方一致', () async {
      await OfficeApi(web).snapshotGet(linkId: 'link1');
      final p = lastOf(_snapshot, 'get');
      expect(
        p.containsKey('password'),
        isTrue,
        reason:
            '★ 官方无条件 putParam ⇒ 键一定在；'
            '省略键在某些服务端实现上会被当成"没这个参数"，语义不同',
      );
      expect(p['password'], '');
    });

    test('★★★ **不许**出现 `cipherkey`（密码是明文字段）', () async {
      await OfficeApi(web).snapshotGet(linkId: 'link1', password: 'pw');
      final p = lastOf(_snapshot, 'get');
      expect(
        p.containsKey('cipherkey'),
        isFalse,
        reason:
            '★★★ 与 D39 的 `protect_password` 同一类：'
            '官方就是明文 `putParam`。若这里出现 `cipherkey`，'
            '服务端会把密文当密码 —— 校验**永远不过**，且**不报错**',
      );
    });
  });

  group('DE58-2. ★★ `Node.Encrypt/check`：密码明文 + 版本只有 v1', () {
    test(
      '★★ `check` 带 `path`(`id:` 前缀) / `password` / `sharing_token`',
      () async {
        final drive = DriveApi(web);
        final ok = await drive.officeEncryptCheck(
          fileId: 'file1',
          password: 'pw',
          sharingToken: 'tok',
        );
        expect(ok, isTrue);
        final p = lastOf(_encrypt, 'check');
        expect(p['path'], 'id:file1', reason: '★ 官方 `computePathById(fileId)`');
        expect(p['password'], 'pw');
        expect(p['sharing_token'], 'tok');
        expect(p.containsKey('cipherkey'), isFalse);
      },
    );

    test('★ 无 `sharing_token` 时**不发**该参数（官方 `TextUtils.isEmpty` 判定）', () async {
      await DriveApi(web).officeEncryptCheck(fileId: 'file1', password: 'pw');
      final p = lastOf(_encrypt, 'check');
      expect(
        p.containsKey('sharing_token'),
        isFalse,
        reason:
            '★ 官方 `if (!TextUtils.isEmpty(sharingToken)) putParam(…)` ——'
            ' 空串不发，与 `password` 的"总是发"不同（两个字段语义不同，别搞混）',
      );
    });

    test('★★★ 57373 = **需要密码**（官方 `isNeedPasswordException`）', () async {
      final b2 = MockDsmBackend(catalog: DsmCatalog.load());
      b2.login(username: 'demo_user', admin: false);
      // 用 fixture 无法伪造错误码（fixture 返回信封即成功）⇒ 改用方法不存在
      // 之外的手段：直接断言 `kDriveNeedPasswordCode` 常量本身，
      // 并从 `.lib`/APK 交叉确认它只出现在这个语义上。
      expect(
        kDriveNeedPasswordCode,
        57373,
        reason:
            '★★★ 官方 `SynologyDriveExceptionInterpreter.isNeedPasswordException`'
            ' 判的就是这个码；改成别的值会让"需要密码"被当成普通错误，'
            '用户看不到密码框',
      );
      expect(b2.catalog[_encrypt], isNotNull);
    });
  });

  group('DE58-2b. ★★★ 端到端：密码从 request **真的**流到 `Snapshot/get`', () {
    test(
      '★★★ `OfficeSheetBackend.loadSnapshot()` 会把 request 里的密码发出去',
      () async {
        // 直接构造生产后端，给一个带密码的 request
        final office = OfficeApi(web);
        final backend = OfficeApiSheetBackend(
          officeApi: office,
          request: const OfficeSheetRequest(
            fileId: 'file1',
            name: 'secret.osheet',
            permanentLink: 'link1',
            drivePath: '/mydrive/secret.osheet',
            password: 'topsecret',
          ),
        );
        // fixture 内容是空的 ⇒ 解析阶段必然抛 `bad_sheet_shape`。
        // **这正好证明请求已经发出去了**；被测的是请求参数，不是解析结果。
        // 用显式 try/catch（`throwsA` 在这里接不住）。
        try {
          await backend.loadSnapshot();
        } catch (_) {
          // 预期内：解析失败与被测行为无关
        }
        final p = lastOf(_snapshot, 'get');
        expect(
          p['password'],
          'topsecret',
          reason:
              '★★★ 这条是 D58 收口的**证据**：'
              '"用户能输密码"（第 65 轮）不等于"输了的密码真的被用上"。'
              '若这里是空串，用户输对密码仍打不开 —— 而且界面上**没有任何报错**，'
              '只会表现为"内容没出来"',
        );
        expect(p['link_id'], 'link1');
      },
    );

    test('★★ 未加密（空密码）时发空串，不是省略、也不是别的值', () async {
      final office = OfficeApi(web);
      final backend = OfficeApiSheetBackend(
        officeApi: office,
        request: const OfficeSheetRequest(
          fileId: 'file1',
          name: 'plain.osheet',
          permanentLink: 'link2',
          drivePath: '/mydrive/plain.osheet',
        ),
      );
      try {
        // fixture 内容是空的 ⇒ 解析阶段必然抛 `bad_sheet_shape`。
        // **这正好证明请求已经发出去了**；被测的是请求参数，不是解析结果。
        // 用显式 try/catch（`throwsA` 在这里接不住）。
        try {
          await backend.loadSnapshot();
        } catch (_) {
          // 预期内：解析失败与被测行为无关
        }
      } catch (_) {
        // 预期内
      }
      expect(lastOf(_snapshot, 'get')['password'], '');
    });

    test('★★ 三个 request 类都带 `password`（`.odoc`/`.osheet`/`.oslides` 一致）', () {
      // 少一个就会让那一种格式重新变成"输对密码也打不开"
      expect(
        const OfficeSheetRequest(
          fileId: 'f',
          name: 'n',
          permanentLink: 'l',
          drivePath: 'p',
          password: 'x',
        ).password,
        'x',
      );
      expect(
        const OfficeSlidesRequest(
          fileId: 'f',
          name: 'n',
          permanentLink: 'l',
          drivePath: 'p',
          password: 'x',
        ).password,
        'x',
      );
      expect(
        const OfficeDocRequest(
          fileId: 'f',
          name: 'n',
          permanentLink: 'l',
          drivePath: 'p',
          password: 'x',
        ).password,
        'x',
      );
    });
  });

  group('★★ r315 口令框文案必须与官方逐字一致（真机曾把"拒绝语"当"提示语"）', () {
    test('★★★ 标题 / 正文 / 错密码语 = 官方三句（en + zh 都钉）', () {
      // 官方取证：`apktool d Android-SynologyDrive.3.9.0-1113.ww.apk`
      //   res/values/strings.xml +
      //   res/values-zh-rCN/strings.xml +
      //   smali_classes5/.../pdftool/fragment/ShowFragment.smali:3459-3490
      //     setTitle(R.string.enter_password_title)
      //     setMessage(isFirstCheckPassword ? enter_password_desc : error_decrypt_fail)
      final en = File('lib/l10n/app_en.arb').readAsStringSync();
      final zh = File('lib/l10n/app_zh.arb').readAsStringSync();
      expect(en, contains('"driveP0EncryptedTitle": "Enter Password"'));
      expect(
        en,
        contains(
          '"driveP0EncryptedOfficeBody": '
          '"This file is encrypted. Please enter the password."',
        ),
      );
      expect(
        en,
        contains(
          '"driveP0PasswordWrong": '
          '"The password is incorrect. Please try again."',
        ),
      );
      expect(zh, contains('"driveP0EncryptedTitle": "输入密码"'));
      expect(
        zh,
        contains('"driveP0EncryptedOfficeBody": "此文件已加密。请输入密码。"'),
      );
      expect(zh, contains('"driveP0PasswordWrong": "密码错误。请再试一次。"'));
    });

    test('★★★ 口令框的 errorText 必须允许多行（否则官方整句被截断成 `…`）', () {
      // 真机取证 `docs/evidence-r315/img/r315_copy2.png`：
      // `The password is incorrect. Please try again.` 被渲染成
      // `The password is incorrect. Pleas…` —— 因为
      // `InputDecoration.errorText` 默认只有 1 行。
      final src = File(
        'lib/src/features/drive/drive_encrypt_gate.dart',
      ).readAsStringSync();
      final i = src.indexOf("DriveP0TextKeys.passwordWrong");
      expect(i, greaterThan(0), reason: '找不到错密码语的 decoration 位置');
      final window = src.substring(i, i + 400);
      expect(
        window.contains('errorMaxLines'),
        isTrue,
        reason: '★ errorText 必须显式给 errorMaxLines，否则长句会被省略号吃掉',
      );
    });

    test('★★ 官方"拒绝语"不许再出现在用户可见文案里（我们能解密打开它）', () {
      // `msg_cannot_open_encrypted_office` = 官方**打不开**时的拒绝语。
      // 真机事实：带内容的加密 `.osheet` 输对口令后**完整渲染**
      // ⇒ 把拒绝语当提示语是假话，且会劝退用户。
      final en = File('lib/l10n/app_en.arb').readAsStringSync();
      final zh = File('lib/l10n/app_zh.arb').readAsStringSync();
      expect(
        en.contains('Please access this file on the server'),
        isFalse,
        reason: '拒绝语不许回到提示框里（官方三句见上一条用例）',
      );
      expect(zh.contains('请在服务器上访问此文件'), isFalse);
    });
  });

  group('DE58-3. ★★ `.lib` 方法表（权威）：`Encrypt` 只有 `check`', () {
    test('★★ `SYNO.Office.Node.Encrypt` min=max=1，**只有** `check`', () {
      final spec = DsmCatalog.load()[_encrypt]!;
      expect(spec.minVersion, 1);
      expect(spec.maxVersion, 1);
      expect(
        spec.methods[1],
        ['check'],
        reason:
            '★★ 只有这一个方法 ⇒ 别去猜 `unlock`/`verify`/`set` 之类；'
            '服务端没有它们',
      );
    });

    test('★★ `Snapshot:get` 跨 v1–v4（我们走 v4），`create` 只在 v1–v2', () {
      final spec = DsmCatalog.load()[_snapshot]!;
      expect(spec.minVersion, 1);
      expect(spec.maxVersion, 4);
      for (final v in [1, 2, 3, 4]) {
        expect(
          spec.methods[v],
          contains('get'),
          reason: '★ `get` 在 v$v 必须存在 —— 这正是"取解密内容"的通道',
        );
      }
      expect(spec.methods[1], contains('create'));
      expect(
        spec.methods[2],
        contains('create'),
        reason: '★ v2 还有 create（`Snapshot:create` v1–v2）',
      );
    });

    test('★ `Office.Node` 的 v2 没有 `create`（与 D56 附录 AZ 一致）', () {
      final spec = DsmCatalog.load()[_node]!;
      expect(spec.methods[1], contains('create'));
      expect(
        spec.methods[2],
        isNot(contains('create')),
        reason: '★ 交叉印证附录 AZ：`Node:create` 只存在于 v1',
      );
    });
  });
}
