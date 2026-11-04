// ★★★ 第 98 轮：官方 `SynologyDrive 3.9.0-1113` 取证补齐的 **5 族 API** 的
// Mock 验证（契约级）。取证依据见 `docs/drive-apk391113-evidence.md` §1.1。
//
// ## 为什么这 5 族此前没有
// 旧对照用的是更老的 APK；第 97 轮把样例库里的 3.9.0-1113 全量解开后
// 发现了 `Users`/`Profiles`/`SCIM.User`/`SCIM.Photo`/`Authentication`。
// 目录（SPK `.lib`）里**早已**有这 5 族的 methodsVerified 方法表 ——
// 本轮把**客户端 API 层**补上，并逐条验证 wire 契约。
//
// ## 合规
// * 全部打内存 Mock（`MockDsmBackend`），§5.1 零真机调用。
// * ⚠️ **门控按目录（.lib 权威）判定，不按 authLevel 猜**：
//   * `SCIM.*`/`Authentication`：authLevel=2 但 `allowUser` 含 `normal.*`、
//     `adminOnly=false` ⇒ 非管理员**也允许**；
//   * `Profiles`：`adminOnly=true`（allowUser 只有 admin.*）⇒ 非管理员 **105**。
//   我最初按"authLevel=2 ⇒ 管理员"推断写了断言，被 Mock 实测当场打回。
import 'package:flutter_test/flutter_test.dart';

import 'package:synhub/src/data/drive_api.dart';
import 'package:synhub/src/dsm/webapi.dart';

import '../tool/mock_dsm/mock_dsm_core.dart';
import 'support/mock_dsm_transport.dart';

void main() {
  late MockDsmBackend backend;
  late DsmWebApi web;
  late DriveApi drive;

  Future<void> boot({required bool admin}) async {
    backend = MockDsmBackend(catalog: DsmCatalog.load());
    backend.login(username: 'u', admin: admin);
    web = DsmWebApi(MockDsmTransport(backend));
    await web.discover();
    await web.login(account: 'u', password: 'x');
    drive = DriveApi(web);
  }

  Map<String, dynamic> lastCall(String apiName) =>
      backend.requests.lastWhere((r) => '${r.params['api']}' == apiName).params;

  group('DR8. ★★★ 5 族新 API 的 wire 契约（普通接口）', () {
    test('★★★ Users:get —— v1、无业务参数', () async {
      await boot(admin: false);
      backend.fixture('SYNO.SynologyDrive.Users', 'get', (p) {
        return {
          'success': true,
          'data': {
            'users': [
              {'uid': 1026, 'name': 'admin', 'display_name': '管理员'},
            ],
          },
        };
      });
      final users = await drive.usersGet();
      expect(users, hasLength(1));
      final p = lastCall('SYNO.SynologyDrive.Users');
      expect('${p['method']}', 'get');
      expect('${p['version']}', '1');
      final extra = p.keys.toSet()
        ..removeAll({'api', 'method', 'version', '_sid'});
      expect(extra, isEmpty, reason: '官方 setAsGet() 不带任何业务参数');
    });

    test(
      '★★★ Profiles:get_sync_profiles —— **必须 v2**（官方 VERSION_SUPPORT_SYNC=2）',
      () async {
        // ⚠️ 目录：`Profiles` 是 **adminOnly=true** ⇒ 非管理员会 105
        await boot(admin: true);
        backend.fixture('SYNO.SynologyDrive.Profiles', 'get_sync_profiles', (
          p,
        ) {
          return {
            'success': true,
            'data': {
              'profiles': [
                {'profile_id': 1, 'name': 'Default'},
              ],
            },
          };
        });
        final profiles = await drive.syncProfiles();
        expect(profiles, hasLength(1));
        final p = lastCall('SYNO.SynologyDrive.Profiles');
        expect('${p['method']}', 'get_sync_profiles');
        expect(
          '${p['version']}',
          '2',
          reason: '★ 官方 smali `VERSION_SUPPORT_SYNC = 0x2`',
        );
      },
    );
  });

  group('DR9. ★★★ SCIM.*（authLevel=2 ⇒ 管理员接口）', () {
    test('★★★ SCIM.User:get —— 管理员可用，param `user` 是列表', () async {
      await boot(admin: true);
      backend.fixture('SYNO.SynologyDrive.SCIM.User', 'get', (p) {
        return {
          'success': true,
          'data': {
            'users': [
              {'name': 'demo_user', 'email': 'k@x.com'},
            ],
          },
        };
      });
      final users = await drive.scimUsers(['demo_user']);
      expect(users, hasLength(1));
      final p = lastCall('SYNO.SynologyDrive.SCIM.User');
      expect('${p['method']}', 'get');
      expect(p['user'], isA<List<dynamic>>());
      expect('${p['version']}', '1');
    });

    test('★★★ SCIM.User —— **非管理员也允许**（目录 allowUser 含 normal.*）', () async {
      // ⚠️ 第一次写这条时我断言"非管理员必须 105"——**错了**：
      //    目录（.lib 权威）里 allowUser 明确含 normal.*，adminOnly=false。
      //    "authLevel=2 ⇒ 一定是管理员接口"是错误推断。
      //    （对照组：`Profiles` 才是 adminOnly=true ⇒ 105。）
      await boot(admin: false);
      backend.fixture('SYNO.SynologyDrive.SCIM.User', 'get', (p) {
        return {
          'success': true,
          'data': {
            'users': [
              {'name': 'demo_user'},
            ],
          },
        };
      });
      final users = await drive.scimUsers(['demo_user']);
      expect(users, hasLength(1));
    });

    test('★★★ 对照组：Profiles（adminOnly=true）非管理员**确实被 105 拒**', () async {
      await boot(admin: false);
      Object? err;
      try {
        await drive.syncProfiles();
      } catch (e) {
        err = e;
      }
      expect(
        '$err'.contains('105'),
        isTrue,
        reason: '★ 目录 adminOnly=true ⇒ 非管理员 105。实际：$err',
      );
    });

    test('★★★ SCIM.Photo:get —— 按名与按 uid 两条分支互斥', () async {
      await boot(admin: true);
      backend.fixture('SYNO.SynologyDrive.SCIM.Photo', 'get', (p) {
        return {
          'success': true,
          'data': {
            'photos': [
              {'id': 7, 'name': 'a.jpg'},
            ],
          },
        };
      });
      await drive.scimPhotos(name: 'a.jpg');
      expect(lastCall('SYNO.SynologyDrive.SCIM.Photo')['name'], 'a.jpg');

      await drive.scimPhotos(uid: 42);
      expect(lastCall('SYNO.SynologyDrive.SCIM.Photo')['uid'], 42);
      // 不该同时带 name+uid（官方 setAsGet / setAsGetByUID 是两个方法）
      expect(
        lastCall('SYNO.SynologyDrive.SCIM.Photo').containsKey('name'),
        isFalse,
      );
    });
  });

  group('DR10. ★★★ Authentication:authenticate_by_dsm（v2 + 设备参数）', () {
    test('★★★ v2、5 个参数逐项对齐官方常量', () async {
      await boot(admin: true);
      backend.fixture(
        'SYNO.SynologyDrive.Authentication',
        'authenticate_by_dsm',
        (p) {
          return {
            'success': true,
            'data': {'token': 'drv-token', 'remote_wipe': false},
          };
        },
      );
      final data = await drive.authenticateByDsm(
        accessToken: 'acc',
        deviceName: 'LGE-AN10',
        deviceUuid: 'uuid-1',
      );
      expect(data['token'], 'drv-token');
      final p = lastCall('SYNO.SynologyDrive.Authentication');
      expect('${p['method']}', 'authenticate_by_dsm');
      expect('${p['version']}', '2');
      expect('${p['access_token']}', 'acc');
      expect('${p['device_name']}', 'LGE-AN10');
      expect('${p['device_uuid']}', 'uuid-1');
      expect('${p['platform']}', 'Android');
      expect('${p['client_version']}', '2');
    });

    test('★★★ 非管理员**也允许**（目录 allowUser 含 normal.*，adminOnly=false）', () async {
      await boot(admin: false);
      backend.fixture(
        'SYNO.SynologyDrive.Authentication',
        'authenticate_by_dsm',
        (p) {
          return {
            'success': true,
            'data': {'token': 't'},
          };
        },
      );
      final data = await drive.authenticateByDsm(
        accessToken: 'acc',
        deviceName: 'd',
        deviceUuid: 'u',
      );
      expect(data['token'], 't');
    });

    test('★★★ 目录守卫：5 族的 Mock 真会拒不存在的方法', () async {
      final catalog = DsmCatalog.load();
      final cases = {
        'SYNO.SynologyDrive.Users': 'set',
        'SYNO.SynologyDrive.Profiles': 'get_sync',
        'SYNO.SynologyDrive.SCIM.User': 'list',
        'SYNO.SynologyDrive.SCIM.Photo': 'put',
        'SYNO.SynologyDrive.Authentication': 'authenticate',
      };
      for (final e in cases.entries) {
        expect(
          catalog.apis[e.key]!.hasMethod(1, e.value),
          isFalse,
          reason: '${e.key} 不该有 ${e.value}',
        );
      }
      // 实际打一发验证 Mock 校验（而非只查表）。
      // 注：`handle` 是同步的（我一开始多写了 await + try/catch，纯属多余）。
      await boot(admin: true);
      final bad = backend.handle('/webapi/entry.cgi', {
        'api': 'SYNO.SynologyDrive.Authentication',
        'method': 'authenticate',
        'version': '2',
      });
      expect('$bad'.contains('103'), isTrue, reason: '★ 应回 103：$bad');
    });
  });
}
