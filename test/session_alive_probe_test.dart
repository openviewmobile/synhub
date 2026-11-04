// `SYNO.Core.Desktop.Timeout / check` v1 —— **会话存活探针**（DSfile APK 实证）。
//
// ## 这个 API 是"机械对差"挖出来的
// 重跑 `docs/dsfile-apk-parity.md` 的机械对差（扫 DSfile dex 的 `SYNO.*`，
// 逐个 grep 我方 `lib/`）时它仍显示未命中。老文档判定它"不是 DSfile 调的 API"，
// 依据是探针打 `avoid` 方法拿到 v1 `103` —— **但那只证明 `avoid` 不是方法**。
//
// 回到 APK 的 smali 才看清真相（`WebApiConnectionManager.smali`）：
// ```text
// :3458  doWebApiQuery("SYNO.Core.Desktop.Timeout", "check", 1, emptyList())
// :7764  mKnownAPIs.containsKey("SYNO.Core.Desktop.Timeout")
//          … 不在表里 ⇒ new WebApiLoginException(-100)     ← 还是**登录闸门**
// ```
// **方法名是 `check`**。⇒ 老结论被我自己的复核证伪，这是真缺口。
//
// ## 真机契约（本会话只读探针，普通用户，不带 maxVersion）
// ```text
// check v1 + _sid      → {"success":true}          （只有 success，没有 data）
// check v1 匿名        → {"error":{"code":119}}
// ```
import 'package:flutter_test/flutter_test.dart';

import 'package:synhub/src/dsm/webapi.dart';

import '../tool/mock_dsm/mock_dsm_core.dart';
import 'support/mock_dsm_transport.dart';

void main() {
  group('T1. 目录事实（权威 .lib / mock catalog）', () {
    late DsmCatalog catalog;

    setUpAll(() => catalog = DsmCatalog.load());

    test('SYNO.Core.Desktop.Timeout 存在，v1 有 check，且**普通用户可及**', () {
      final spec = catalog['SYNO.Core.Desktop.Timeout'];
      expect(spec, isNotNull, reason: 'DSfile APK 真的调它，目录里必须有');
      expect(spec!.versionsWith('check'), contains(1));
      expect(
        spec.normal,
        isTrue,
        reason: 'allowUser 里有 normal.* ⇒ 普通用户可及（真机普通用户也实测通了）',
      );
      expect(spec.path, 'entry.cgi');
    });

    test('★ 只有 v1（v2 会 103/104 —— 别按 maxVersion 乱协商）', () {
      final spec = catalog['SYNO.Core.Desktop.Timeout']!;
      expect(spec.maxVersion, 1);
      expect(spec.versionsWith('check'), isNot(contains(2)));
    });
  });

  group('T2. 真实 DsmWebApi × Mock Server：组合必须通过权威校验', () {
    late DsmCatalog catalog;
    late MockDsmBackend backend;
    late MockDsmTransport transport;

    setUp(() {
      catalog = DsmCatalog.load();
      backend = MockDsmBackend(catalog: catalog);
      backend.login(username: 'u', admin: false);
      transport = MockDsmTransport(backend);
    });

    test('checkSessionAlive() 发出 v1 的 check，且不被 mock 判 103', () async {
      final web = DsmWebApi(transport);
      await web.discover();
      await web.login(account: 'u', password: 'x');

      final alive = await web.checkSessionAlive();
      expect(alive, isTrue);
      expect(transport.last!.errorCode, isNot(103));

      final req = backend.requests.lastWhere(
        (r) => r.params['api'] == 'SYNO.Core.Desktop.Timeout',
      );
      expect(req.params['method'], 'check');
      expect('${req.params['version']}', '1');
    });

    test('★ 会话失效（119）⇒ false，且**不**触发重登重放', () async {
      final web = DsmWebApi(transport);
      await web.discover();
      await web.login(account: 'u', password: 'x');

      // 让后端对 check 回 119（`sessions` 是只读 Iterable，不能 clear）。
      backend.fixture(
        'SYNO.Core.Desktop.Timeout',
        'check',
        (_) => {
          'success': false,
          'error': {'code': 119},
        },
      );

      final alive = await web.checkSessionAlive();
      expect(alive, isFalse, reason: '119 必须被翻译成"会话没了"');
      // `check` 应当在**本方法内**被消化掉，不会再冒出异常。
      expect(web.session, isNotNull, reason: '探测不该把会话对象清空');
    });

    test('能力表里没有这个 API ⇒ true（旧机器上不误杀好会话）', () async {
      // 构造一份**不含** Timeout 的目录（模拟旧 DSM）。
      final full = DsmCatalog.load();
      final bare = DsmCatalog(
        apis: {
          for (final e in full.apis.entries)
            if (e.key != 'SYNO.Core.Desktop.Timeout') e.key: e.value,
        },
        apiCount: full.apiCount - 1,
      );
      final b2 = MockDsmBackend(catalog: bare);
      b2.login(username: 'u', admin: false);
      final web = DsmWebApi(MockDsmTransport(b2));
      await web.discover();
      expect(await web.checkSessionAlive(), isTrue, reason: '无法判定 ≠ 会话失效');
      expect(
        b2.requests.where(
          (r) => r.params['api'] == 'SYNO.Core.Desktop.Timeout',
        ),
        isEmpty,
        reason: '压根不该发请求',
      );
    });

    test('其他错误（103/104/网络）也返回 true —— 不能拿它当会话判决', () async {
      final web = DsmWebApi(transport);
      await web.discover();
      await web.login(account: 'u', password: 'x');

      // 让后端对这个方法回 103（版本里没这个方法）。
      backend.fixture(
        'SYNO.Core.Desktop.Timeout',
        'check',
        (_) => {
          'success': false,
          'error': {'code': 103},
        },
      );
      expect(await web.checkSessionAlive(), isTrue);
    });
  });
}
