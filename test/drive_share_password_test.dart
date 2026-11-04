// ★★ **③Drive 第 59 轮：D39 分享链接密码** —— 订正一个**错误假设**并钉住事实
//
// ## 被订正的说法
// 仓库里原先写着：
// > 官方对 `protect_password` 额外挂了 `encryption:["protect_password"]`，
// > 本仓库 `DsmWebApi.call` 不支持 `encryption` 参数，所以只能不发密码。
//
// **这句话是错的**，是我早期未经验证的假设。三条独立证据否掉它：
//
// | # | 来源 | 事实 |
// |---|---|---|
// | 1 | APK `ApiSynoDriveAdvanceSharing.java:92` | 裸 `putParam(PROTECT_PASSWORD, …)`，无加密属性（对比登录 `passwd` 才走 `DsmCgiEncryption`） |
// | 2 | 服务端 `.lib`（权威 JSON） | `SYNO.SynologyDrive.lib` 里 **`encryption` 出现 0 次**；`AdvanceSharing` 方法表只有 `grant*`/`allowDemo` |
// | 3 | 服务端二进制 `libsynosyncservercore.so` | `protect_password` 是 **DB 列**（`SELECT … protect_password, due_date …`），无 `cipherkey` 解密路径 |
//
// ⇒ 密码与 `due_date`/`role` 同级，是**普通表单字段**（HTTPS 保护）。
//
// ## 本文件钉什么
// ① **正证**：`update` 把密码**原样**发在 `protect_password` 里；
// ② **反证**：请求里**不出现** `cipherkey`（否则说明有人又"按印象加密"了 ——
//    那会让服务端把密文当密码存进 DB，用户**永远验不过**）；
// ③ 官方取值：`due_date` 是**秒**、`role` 六个官方串、
//    `create` **只传 `path`**（保护设置走 `update`）。
//
// 全程内存 Mock，不碰真机（规程 §5.1）。
import 'package:flutter_test/flutter_test.dart';

import 'package:synhub/src/data/drive_api.dart';
import 'package:synhub/src/data/dto/drive_share_dto.dart';
import 'package:synhub/src/dsm/webapi.dart';

import '../tool/mock_dsm/mock_dsm_core.dart';
import 'support/mock_dsm_transport.dart';

void main() {
  late MockDsmBackend backend;
  late MockDsmTransport transport;
  late DsmWebApi web;
  late DriveApi drive;

  setUp(() async {
    backend = MockDsmBackend(catalog: DsmCatalog.load());
    backend.login(username: 'demo_user', admin: false);
    transport = MockDsmTransport(backend);
    web = DsmWebApi(transport);
    await web.discover();
    await web.login(account: 'demo_user', password: 'x');
    drive = DriveApi(web);
  });

  Map<String, dynamic> last(String method) {
    final req = backend.requests
        .where(
          (r) => '${r.params['api']}' == 'SYNO.SynologyDrive.AdvanceSharing',
        )
        .where((r) => '${r.params['method']}' == method)
        .toList();
    expect(req, isNotEmpty, reason: '必须真的发出了 $method');
    return req.last.params;
  }

  group('DS-1. ★★★ 密码是**明文**字段（订正错误假设）', () {
    test('★★★ 密码原样出现在 `protect_password`', () async {
      await drive.updateAdvanceSharing(
        path: 'id:123',
        sharingLink: 'abc123',
        role: DriveShareRole.viewer,
        protectPassword: 'hunter2',
      );
      expect(
        last('update')['protect_password'],
        'hunter2',
        reason: '★ 官方 `putParam(PROTECT_PASSWORD, getPassword())` 就是原样发',
      );
    });

    test('★★★ **不许**出现 `cipherkey`（否则服务端会把密文当密码存）', () async {
      await drive.updateAdvanceSharing(
        path: 'id:123',
        sharingLink: 'abc123',
        role: DriveShareRole.viewer,
        protectPassword: 'hunter2',
      );
      final p = last('update');
      expect(
        p.containsKey('cipherkey'),
        isFalse,
        reason:
            '★★★ 若这里出现 cipherkey，说明有人"按印象加密"了密码 ——'
            ' 服务端会把密文原样存进 DB，用户**永远验不过**，'
            '而且**不会报错**（存进去的就是个字符串）',
      );
    });

    test('★ 空密码 ⇒ 空串（官方 `? : ""` 语义）', () async {
      await drive.updateAdvanceSharing(
        path: 'id:123',
        sharingLink: 'abc123',
        role: DriveShareRole.viewer,
        protectPassword: '',
      );
      expect(last('update')['protect_password'], '');
    });
  });

  group('DS-2. ★★ 官方取值：`due_date` 秒 / `role` 六串 / create 只传 path', () {
    test('★ `due_date` 是**秒**（不是毫秒、不是字符串日期）', () async {
      await drive.updateAdvanceSharing(
        path: 'id:123',
        sharingLink: 'abc123',
        role: DriveShareRole.viewer,
        dueDate: 1800000000,
      );
      final v = last('update')['due_date'];
      expect(
        '$v',
        '1800000000',
        reason:
            '★ 官方 `dueDate.getTime() / 1000`；发毫秒会让有效期变成'
            '"几万年后"，发字符串会让服务端解析失败',
      );
    });

    test('★★ `role` 只认官方那 6 个串（枚举全覆盖）', () {
      // 官方 `ApiSynoDriveAdvanceSharing.java:23-29` +
      // `convertPermissionTypeToRole`
      const official = {
        'viewer',
        'previewer',
        'preview_commenter',
        'commenter',
        'editor',
        'organizer',
      };
      final ours = {for (final r in DriveShareRole.values) r.value};
      expect(
        ours,
        official,
        reason:
            '★★ 多一个就是编的，少一个就是漏的；'
            '服务端对未知 role 的处理**不是报错**，而是降级成默认权限',
      );
    });

    test('★★ `create` **只传 `path`**（保护设置走 update）', () async {
      await drive.createAdvanceSharing(path: 'id:123');
      final p = last('create');
      expect(p['path'], 'id:123');
      for (final k in [
        'role',
        'protect_password',
        'due_date',
        'sharing_link',
      ]) {
        expect(
          p.containsKey(k),
          isFalse,
          reason:
              '★ 官方 `setAsCreate(fileId)` 只 `putParam("path", …)`；'
              '在 create 里带保护参数服务端**不认**（静默忽略）',
        );
      }
    });
  });
}
