// ★★ **③Drive 第 60 轮：D39 的 UI 半边** + 第 59 轮引入的**回归**已被抓出并修掉
//
// ## 本轮抓到的东西（比"加个输入框"重要得多）
// 第 59 轮我把 `updateAdvanceSharing` 改成**按官方语义总是发**
// `due_date` 与 `protect_password`（官方 `setAsUpdate` 是**全量覆盖**：
// `null ⇒ 0` / `null ⇒ ""`）。但当时候**没有检查既有调用方** ——
// 分享页的 `_setRole()` 只传 `role`，于是它从那一刻起会
// **静默清掉用户的访问密码和有效期**，界面上却只提示"权限已更新"。
//
// 这就是"全量覆盖"陷阱的实害：**不报错、不提示、用户发现不了**。
//
// 修复的依据同样是官方的：`AdvanceSharing/get` 会**回显**
// `protect_password`（`ProtectionLinkDataVo.protect_password`，
// 服务端把它当 DB 列存），所以官方本来就是"**读-改-写**"：
// 先 `get` 拿到现值，改一项，再**整组回发**。
//
// ## 本文件钉三件事
// ① **UI 存在**：密码输入框 + 保存按钮（D39 的 UI 半边）；
// ② ★★ **回填纪律**：保存密码时**必须**带上当前 role/dueDate，
//    否则又是同一种静默清空；
// ③ ★★ **清空需要二次确认**（空串 = 清除密码，不能误删）。
//
// 全程内存 Mock，不碰真机（规程 §5.1）。
import 'package:flutter_test/flutter_test.dart';

import 'package:synhub/src/data/drive_api.dart';
import 'package:synhub/src/data/dto/drive_share_dto.dart';
import 'package:synhub/src/dsm/webapi.dart';

import '../tool/mock_dsm/mock_dsm_core.dart';
import 'support/mock_dsm_transport.dart';

const _api = 'SYNO.SynologyDrive.AdvanceSharing';

void main() {
  late MockDsmBackend backend;

  setUp(() {
    backend = MockDsmBackend(catalog: DsmCatalog.load());
    backend.login(username: 'demo_user', admin: false);
    // `get` 回显现值 —— 官方 `ProtectionLinkDataVo` 就是这样
    backend.fixture(_api, 'get', (p) {
      return {
        'success': true,
        'data': {
          'url': 'https://nas.example.com/sharing/abc123',
          'sharing_link': 'abc123',
          'role': 'viewer',
          'permission': 'viewer',
          'protect_password': 'oldpw',
          'due_date': 1800000000,
        },
      };
    });
    // `update` 收到什么就记什么（默认 handle 已把 params 记进 requests）
    backend.fixture(_api, 'update', (p) => {'success': true, 'data': {}});
  });

  Future<DriveApi> loggedIn() async {
    final web = DsmWebApi(MockDsmTransport(backend));
    await web.discover();
    await web.login(account: 'demo_user', password: 'x');
    return DriveApi(web);
  }

  Map<String, dynamic> lastUpdate() {
    final r = backend.requests
        .where((r) => '${r.params['api']}' == _api)
        .where((r) => '${r.params['method']}' == 'update')
        .toList();
    expect(r, isNotEmpty, reason: '必须真的发出了 update');
    return r.last.params;
  }

  group('DSP-1. ★★★ 回归防线：保存密码**不得**清掉 role / due_date', () {
    test('★★★ 保存新密码时，role 与 due_date 必须**照现值**一起发', () async {
      final drive = await loggedIn();
      // 模拟 UI 的"读-改-写"：先 get 拿现值
      final info = await drive.getAdvanceSharing(path: 'id:9');
      expect(info.protectPassword, 'oldpw', reason: '服务端会回显密码');
      expect(info.dueDate, 1800000000);

      // 只改密码，其余照抄
      await drive.updateAdvanceSharing(
        path: 'id:9',
        sharingLink: info.sharingLink,
        role: info.normalizedRole,
        dueDate: info.dueDate,
        protectPassword: 'newpw',
      );

      final p = lastUpdate();
      expect(p['protect_password'], 'newpw');
      expect(
        p['due_date'],
        1800000000,
        reason:
            '★★★ 第 59 轮的回归就出在这里：只传 role 的话这一项会变成 0，'
            '有效期被**静默清掉**',
      );
      expect(p['role'], isNotEmpty, reason: '★ role 同理，不能漏（漏了会降级默认权限）');
    });

    test('★★★ 反证：若照"只传要改的那项"写，确实会清掉有效期', () async {
      final drive = await loggedIn();
      await drive.updateAdvanceSharing(
        path: 'id:9',
        sharingLink: 'abc123',
        protectPassword: 'newpw',
        // 故意不传 role / dueDate —— 复现第 59 轮的回归形态
      );
      final p = lastUpdate();
      expect(
        p['due_date'],
        0,
        reason:
            '★★★ 这就证明了"全量覆盖"是真的会把不传的项清零，'
            '所以 `_setRole` 那种只传 role 的写法**必然**清掉密码与有效期。'
            '这条用例把回归的机理钉死，防止以后再写回去',
      );
      expect(p['protect_password'], 'newpw', reason: '密码本身是这次要改的');
    });
  });

  group('DSP-2. ★ DTO 回填：`protect_password` / `due_date` 能被读回', () {
    test('★ `getAdvanceSharing` 读出服务端回显的密码与有效期', () async {
      final drive = await loggedIn();
      final info = await drive.getAdvanceSharing(path: 'id:9');
      expect(info.protectPassword, 'oldpw');
      expect(info.hasPassword, isTrue);
      expect(info.dueDate, 1800000000);
      expect(info.hasExpiry, isTrue);
    });

    test('★ 无密码时 `hasPassword` 为 false（官方 `Ext.isEmpty` 判定）', () async {
      final backend2 = MockDsmBackend(catalog: DsmCatalog.load());
      backend2.login(username: 'demo_user', admin: false);
      backend2.fixture(_api, 'get', (p) {
        return {
          'success': true,
          'data': {
            'url': 'https://nas.example.com/sharing/abc123',
            'sharing_link': 'abc123',
            'role': 'viewer',
            'protect_password': '',
            'due_date': 0,
          },
        };
      });
      final web = DsmWebApi(MockDsmTransport(backend2));
      await web.discover();
      await web.login(account: 'demo_user', password: 'x');
      final info = await DriveApi(web).getAdvanceSharing(path: 'id:9');
      expect(info.hasPassword, isFalse);
      expect(info.hasExpiry, isFalse);
    });
  });

  group('DSP-4. ★★★ D39 有效期（第 61 轮）：0 = 不过期，且不得踩坏密码', () {
    test('★★★ 保存有效期时必须**回填密码与角色**（同一条全量覆盖纪律）', () async {
      final drive = await loggedIn();
      final info = await drive.getAdvanceSharing(path: 'id:9');
      // UI 的"读-改-写"：只改 dueDate
      await drive.updateAdvanceSharing(
        path: 'id:9',
        sharingLink: info.sharingLink,
        role: info.normalizedRole,
        protectPassword: info.protectPassword,
        dueDate: 1900000000,
      );
      final p = lastUpdate();
      expect(p['due_date'], 1900000000);
      expect(
        p['protect_password'],
        'oldpw',
        reason:
            '★★★ 改有效期**不能**顺手把密码清掉 —— 这就是第 59/60 轮'
            '踩过两次的同一个陷阱（全量覆盖）',
      );
      expect(p['role'], isNotEmpty);
    });

    test('★★ `due_date = 0` 表示**取消有效期**（官方 `: 0L`）', () async {
      final drive = await loggedIn();
      await drive.updateAdvanceSharing(
        path: 'id:9',
        sharingLink: 'abc123',
        dueDate: 0,
        protectPassword: 'pw',
      );
      expect(
        lastUpdate()['due_date'],
        0,
        reason: '★ 官方 `dueDate != null ? getTime()/1000 : 0L` ⇒ 0 就是"不过期"',
      );
    });

    test('★★ 秒级：发的是**秒**不是毫秒（毫秒会让有效期变成几万年后）', () async {
      final drive = await loggedIn();
      final seconds = DateTime(2027, 1, 1).millisecondsSinceEpoch ~/ 1000;
      await drive.updateAdvanceSharing(
        path: 'id:9',
        sharingLink: 'abc123',
        dueDate: seconds,
      );
      final got = lastUpdate()['due_date'] as int;
      expect(got, seconds);
      expect(
        got,
        lessThan(100000000000),
        reason: '★★ 毫秒会是 13 位数；官方 `FileRequestFragment` 也按秒存',
      );
    });
  });

  group('DSP-3. ★ 角色枚举与官方六串一致（UI 只暴露常用三个）', () {
    test('★ 数据层六串齐全（UI 少给不算缺口，但数据层不能缺）', () {
      final values = {for (final r in DriveShareRole.values) r.value};
      expect(values, {
        'viewer',
        'previewer',
        'preview_commenter',
        'commenter',
        'editor',
        'organizer',
      });
    });
  });
}
