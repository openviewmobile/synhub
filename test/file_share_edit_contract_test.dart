// `SYNO.FileStation.Sharing / edit` 的**报文契约** —— 走自建 **Mock Server**
// （`tool/mock_dsm/mock_dsm_core.dart` 的真实后端，不是自造假传输）。
//
// ## 为什么有这个文件（第 251 轮）
//
// 台账行 161（M36 分享链接编辑）此前挂着一个"未取证"的子项：
//
// > 「移除密码 / 改为永久」在 `edit` 上是不是发**空串**？
//
// 第 251 轮把**一级来源**补齐了（官方 DS file 4.17.2-609 反编译 smali）：
//
// ```text
// WebApiConnectionManager.editShareLinkV3(String id, String pwd, String avail, String exp)
//   add(SingleApiParameter("id", id))                    // 裸字符串
//   if (pwd != null) {
//       if (TextUtils.isEmpty(pwd))
//           add(SingleApiParameter("protect_type", "none"));   // ★ 清空密码
//       add(SingleApiParameter("password", pwd));              // ★ 空串也照发
//   }
//   if (!isEmpty(avail)) add(("date_available", avail));
//   if (!isEmpty(exp))   add(("date_expired", exp));           // ★ 空 = **不发**
//   doWebApiQuery("SYNO.FileStation.Sharing", "edit", 3, …)
// ```
//
// 调用方 `ShareFragmentDSM6$12`：编辑模式关掉"密码保护"开关时传的是**空串**
// （不是 null）⇒ 上面两个 `isEmpty` 语义正好命中；日期不勾选时传空串 ⇒
// `date_expired` **根本不发**（官方没有"清空有效期"的报文）。
//
// 服务端侧佐证（FileStation 1.5.1-2410 SPK 的 `webapi/SYNO.FileStation.Sharing.so`）：
// 时间格式只认 `%Y-%m-%d` / `%Y-%m-%d %H:%M:%S`，并且带
// `"%s:%d Failed to convert input time to tm struct"` ⇒ 发一个空时间串
// 很可能直接报错，所以本仓**删掉了自创的 `date_expired:""`**。
//
// 本文件就是把这些契约**逐条钉死在 Mock Server 的请求日志上**。
import 'package:flutter_test/flutter_test.dart';

import 'package:synhub/src/data/filestation_api.dart';
import 'package:synhub/src/dsm/webapi.dart';

import '../tool/mock_dsm/mock_dsm_core.dart';
import 'support/mock_dsm_transport.dart';

void main() {
  late MockDsmBackend backend;
  late MockDsmTransport transport;
  late DsmWebApi web;
  late FileStationApi api;

  setUp(() async {
    backend = MockDsmBackend(catalog: DsmCatalog.load());
    backend.login(username: 'u', admin: false);
    // `edit` 的回包形状与 `list` 同族：`{links:[…]}`（服务端 `.so` 里的
    // `links` 字符串就是这条）；给一个最小但字段齐全的链接。
    backend.fixture('SYNO.FileStation.Sharing', 'edit', (p) {
      return {
        'success': true,
        'data': {
          'links': [
            {
              'id': p['id'],
              'path': '/home/a.txt',
              'name': 'a.txt',
              'url': 'https://nas.example.com:5001/sharing/abc',
              'isFolder': false,
              'status': 'valid',
              'has_password': p.containsKey('password'),
              'date_available': p['date_available'] ?? '',
              'date_expired': p['date_expired'] ?? '',
              'protect_type': p['protect_type'] ?? 'none',
              'link_owner': 'u',
            },
          ],
        },
      };
    });
    transport = MockDsmTransport(backend);
    web = DsmWebApi(transport);
    await web.discover();
    await web.login(account: 'u', password: 'x');
    api = FileStationApi(web);
  });

  /// 最近一次 `Sharing/edit` 请求的参数（含 `_sid`，断言时只挑业务键）。
  Map<String, dynamic> lastEditParams() {
    final req = backend.requests.lastWhere(
      (r) => r.params['api'] == 'SYNO.FileStation.Sharing',
    );
    return req.params;
  }

  test('清空密码：`protect_type:"none"` 与 `password:""` **两个字段一起发**（官方逐字）', () async {
    await api.editShareLink(id: 'LINK-1', clearPassword: true);
    final p = lastEditParams();
    expect(p['method'], 'edit');
    expect('${p['version']}', '3', reason: '官方 editShareLinkV3 固定 v3');
    expect(p['protect_type'], 'none', reason: '清空密码的关键字段（此前漏发）');
    expect(
      p.containsKey('password'),
      isTrue,
      reason: '官方在 pwd 非 null 时**总是**发 password，空串也发',
    );
    expect(p['password'], '');
    expect(p.containsKey('date_expired'), isFalse, reason: '没传日期就不该出现');
    expect(transport.last!.json['success'], isTrue);
  });

  test('设新密码：只发 `password`，**不发** `protect_type`（官方分支）', () async {
    await api.editShareLink(id: 'LINK-1', password: 's3cret');
    final p = lastEditParams();
    expect(p['password'], 's3cret');
    expect(
      p.containsKey('protect_type'),
      isFalse,
      reason: '官方只在 isEmpty(pwd) 时才补 protect_type=none',
    );
  });

  test('什么都不动（保持密码）：`password` / `protect_type` 都不发', () async {
    await api.editShareLink(id: 'LINK-1');
    final p = lastEditParams();
    expect(p.containsKey('password'), isFalse);
    expect(p.containsKey('protect_type'), isFalse);
    expect(p.containsKey('date_available'), isFalse);
    expect(p.containsKey('date_expired'), isFalse);
  });

  test('`id` 是**裸字符串**（不是 JSON 数组）—— 回归守卫', () async {
    await api.editShareLink(id: 'LINK-42');
    expect(lastEditParams()['id'], 'LINK-42');
    expect(
      lastEditParams()['id'],
      isNot(contains('[')),
      reason: '曾照抄 delete 发 encodePaths([id])，是错的',
    );
  });

  test('改有效期：`date_expired` 原样发；`date_available` 非空才发', () async {
    await api.editShareLink(
      id: 'LINK-1',
      dateAvailable: '2026-09-01',
      dateExpired: '2026-12-31',
    );
    final p = lastEditParams();
    expect(p['date_available'], '2026-09-01');
    expect(p['date_expired'], '2026-12-31');
  });

  test('「永久」= **省略** `date_expired`（与官方同形，不再自创空串）', () async {
    await api.editShareLink(id: 'LINK-1', dateExpired: null);
    final p = lastEditParams();
    expect(p.containsKey('date_expired'), isFalse);
    // 也绝不能是空串：服务端 `.so` 的时间解析只认 `%Y-%m-%d`，
    // 空串会走到 "Failed to convert input time to tm struct"。
    expect(p['date_expired'], isNot(''));
  });

  test('空串日期同样是"省略"（API 层的 isEmpty 守卫）', () async {
    await api.editShareLink(id: 'LINK-1', dateExpired: '');
    expect(lastEditParams().containsKey('date_expired'), isFalse);
  });

  test('edit 必须走 Mock Server 的目录校验：v3 在册（不是 103）', () async {
    final entry = web.apiTable?['SYNO.FileStation.Sharing'];
    expect(entry, isNotNull, reason: 'SYNO.API.Info 里应有 Sharing');
    expect(entry!.maxVersion, greaterThanOrEqualTo(3));
    // 上一次请求没有被 Mock 判为"方法不存在"（103）/"未登录"（119）。
    expect(transport.last!.json['success'], isTrue);
    expect(transport.last!.note, isNot(contains('103')));
  });
}
