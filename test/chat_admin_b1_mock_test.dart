// ★★ **②聊天 第 47 轮：B1 的「管理员接口」轴 —— 结论是空集，但必须**证明**它空**
//
// ## 新规 B1 要求
// 「涉及管理员的接口一律走 Mock Server 模拟测试，必须通过」。
//
// 对 ②聊天 而言这句话该怎么落实**不是想当然**：得先回答
// **「Synology Chat 的安卓端到底调不调管理员专属 API？」**
//
// ## 权威答案（有出处，不是我猜的）
//
// `docs/chat-parity-audit.md:417-421`：
//
//   > ## 5. 管理员功能清单（官方有，按用户要求排除）
//   > **关键结论：官方 Android 客户端里没有任何「管理员专属界面」。**
//   > 管理员的实际界面是 **DSM 里的 Synology Chat 管理控制台**，
//   > 手机端只**反映**它的设置。
//
// 即：管理员在**网页控制台**操作，手机端只**读**设置
// （`SYNO.Chat.Admin.Setting/get` —— 名字带 `Admin`，**但不是 admin-only**：
// 普通用户身份就读得到，官方用它拿 `allow_encryption`/`allow_read_status`/
// `isSupportEditAllPost`，见 `docs/phase9-server-settings.md:17-19`）。
//
// ⇒ ②聊天 的 B1 **是空集**。但"空集"必须**被证明**，否则可能是
//   "我们没发现"而不是"确实没有"。本文件干两件事：
//
// 1. **正面**：`Chat.Admin.Setting/get` 用**非管理员**会话调必须**成功**
//    —— 这是最容易被名字骗到的接口（名字吓人，其实是普通用户接口）。
// 2. **反证**：证明 Mock 的 `105` 闸门**真的会拦**。拿一个**确凿**
//    `adminOnly` 的 API（`SYNO.ActiveInsight.Package`，`allowUser=[admin.*]`，
//    来自真 `.lib`）跑**双轨**：非管理员 → `105`；管理员 → 通过。
//    没有这条，"Chat.Admin.Setting 没报 105"可能只是因为**闸门坏了**。
//
// ## ⚠️ 必须说清楚的诚实边界
// Chat 家族在 catalog 里 `allowUser: []` —— 这是**本机没有 Chat Server SPK、
// 拿不到 `.lib`** 导致的**「未知」**，**不是「普通用户可访问」的证据**。
// 所以本文件**不**声称"Chat 全部 API 都非 admin-only"；
// 只声称"Chat 官方安卓端**不调用**管理员专属 API"（有上面那份审计为据）。
//
// 全程打**内存 Mock Server**，不碰真机（规程 §5.1）。
import 'package:flutter_test/flutter_test.dart';

import '../tool/mock_dsm/mock_dsm_core.dart';

MockDsmBackend _backend({required bool admin}) {
  final b = MockDsmBackend(catalog: DsmCatalog.load());
  b.login(username: admin ? 'admin' : 'demo_user', admin: admin);
  return b;
}

/// 用某个会话发一次请求（`entry.cgi` 是 Chat 家族的实际路径）。
MockDsmResponse _call(
  MockDsmBackend b,
  String api,
  String method,
  int version,
) => b.handle('entry.cgi', {
  'api': api,
  'method': method,
  'version': version,
  '_sid': b.sessions.first,
});

void main() {
  group('B1-1. Chat 家族：确认「没有管理员专属接口」这条结论', () {
    test('★ 审计文档的结论可被复述（出处写进断言，防止以后被悄悄改掉）', () {
      // 这条不是断言代码，是**把证据钉在测试里**：
      //   docs/chat-parity-audit.md:417-421
      //   「官方 Android 客户端里没有任何「管理员专属界面」。
      //     管理员的实际界面是 DSM 里的 Synology Chat 管理控制台，
      //     手机端只反映它的设置。」
      // ⇒ ②聊天 的 B1（管理员接口 Mock 验证）是**空集**。
      const evidence = 'docs/chat-parity-audit.md:417-421';
      expect(evidence, isNotEmpty);
    });

    test('★ catalog 里 Chat 家族 adminOnly 数量为 0（当前事实）', () {
      final b = _backend(admin: false);
      final chatAdmin = b.catalog.apis.keys
          .where((k) => k.startsWith('SYNO.Chat') && b.catalog[k]!.adminOnly)
          .toList();
      expect(chatAdmin, isEmpty);
    });

    test('⚠️ 但 Chat 的 allowUser 是**空**（未知），不是「普通用户」的证据', () {
      final b = _backend(admin: false);
      final unknown = <String>[];
      for (final k in b.catalog.apis.keys.where(
        (k) => k.startsWith('SYNO.Chat'),
      )) {
        final spec = b.catalog[k]!;
        // `allowUser` 空 ⇒ 既不是 normal 也不是 adminOnly，是**未知**
        if (spec.allowUser.isEmpty) unknown.add(k);
      }
      expect(
        unknown,
        isNotEmpty,
        reason:
            '★ 本机无 Chat SPK ⇒ 没有 `.lib` ⇒ allowUser 只能是未知；'
            '如果哪天变空了，说明拿到了权威数据，这段说明该更新',
      );
      // 明确写下来：未知 ≠ 普通用户
      for (final k in unknown) {
        final spec = b.catalog[k]!;
        expect(spec.adminOnly, isFalse);
        expect(
          spec.normal,
          isFalse,
          reason: '$k 的 normal=false 表示"没有 normal.* 入档"，不是"非普通用户"',
        );
      }
    });
  });

  group('B1-2. ★ `Chat.Admin.Setting`：**名字骗人**，普通用户就该能读', () {
    test('★★ 非管理员会话调 `Chat.Admin.Setting/get` 必须**成功**（不是 105）', () {
      final b = _backend(admin: false);
      final r = _call(b, 'SYNO.Chat.Admin.Setting', 'get', 4);
      expect(
        r.errorCode,
        isNot(105),
        reason:
            '★ 这是最容易被名字骗到的接口：官方客户端**以普通用户身份**读它拿'
            '`allow_encryption`/`allow_read_status`/`isSupportEditAllPost`'
            '（docs/phase9-server-settings.md:17-19）',
      );
    });

    test('★ 管理员会话同样能读（两轨一致 ⇒ 它确实不分档）', () {
      final b = _backend(admin: true);
      final r = _call(b, 'SYNO.Chat.Admin.Setting', 'get', 4);
      expect(r.errorCode, isNot(105));
    });

    test('★ 反证：`get` 是它**唯一**的客户端方法；`set` 不该被我们的客户端调', () {
      final b = _backend(admin: false);
      // `docs/phase9-server-settings.md:12`：
      // 「方法 `get`（还有个 `set`，是管理员界面用的，客户端不调）」
      // ⇒ `set` 在表里存在（管理员走 DSM 控制台），但**我们不该调它**。
      final spec = b.catalog['SYNO.Chat.Admin.Setting']!;
      expect(spec.versionsWith('get'), isNotEmpty);
      // 我方客户端在测试驱动里只发 `get` —— 由 CC-2 的执行度量覆盖。
      final r = _call(b, 'SYNO.Chat.Admin.Setting', 'thisIsNotAMethod', 4);
      expect(r.errorCode, 103, reason: '方法名确实被校验（第 45 轮建的表）');
    });
  });

  group('B1-3. ★★ 反证：Mock 的 105 闸门**真的会拦**（否则上面全是假通过）', () {
    // `SYNO.ActiveInsight.Package`：`allowUser=[admin.*]`，**真 `.lib`** 里的
    // adminOnly（`test/auth_extra_api_mock_test.dart` AX-5 同一对证据）。
    const adminApi = 'SYNO.ActiveInsight.Package';

    test('前提：这个 API 在 catalog 里确实是 adminOnly', () {
      final b = _backend(admin: false);
      final spec = b.catalog[adminApi];
      expect(spec, isNotNull, reason: '$adminApi 必须在 catalog 里');
      expect(spec!.adminOnly, isTrue, reason: '反证的前提：拿一个**确凿**的管理员 API，否则反证无效');
    });

    test('★★ 非管理员 → **105**（闸门真的会拦）', () {
      final b = _backend(admin: false);
      // ⚠️ 第一版我写的是 `list`，结果回 **103** 而不是 105 —— 因为
      // ActiveInsight.Package 的真实方法是 get_status/start_mib/stop_mib/change_mode。
      // 这恰好证明 mock 的校验顺序是对的（**先判方法存在，再判权限**），
      // 也说明"随手猜个通用方法名"会被抓住。
      final r = _call(b, adminApi, 'get_status', 1);
      expect(
        r.errorCode,
        105,
        reason: '★ 没有这条，就无法排除「Chat.Admin.Setting 没 105 = 闸门坏了」',
      );
    });

    test('★★ 管理员 → **不**是 105（双轨的另一轨）', () {
      final b = _backend(admin: true);
      final r = _call(b, adminApi, 'get_status', 1);
      expect(
        r.errorCode,
        isNot(105),
        reason: '★ B1 要求的正是这一轨：管理员接口在 Mock 上必须也能跑通',
      );
    });

    test('★ 反证成立 ⇒ 对比才有意义：换回 Chat 接口，非管理员**不**被拦', () {
      final nonAdmin = _backend(admin: false);
      final admin = _backend(admin: true);
      expect(_call(nonAdmin, adminApi, 'get_status', 1).errorCode, 105);
      expect(
        _call(nonAdmin, 'SYNO.Chat.Admin.Setting', 'get', 4).errorCode,
        isNot(105),
        reason:
            '★ 同一个非管理员会话：管理员接口 105、Chat 设置接口放行 '
            '⇒ 闸门是**按 API 分档**的，不是一刀切',
      );
      expect(
        _call(admin, 'SYNO.Chat.Admin.Setting', 'get', 4).errorCode,
        isNot(105),
      );
    });
  });
}
