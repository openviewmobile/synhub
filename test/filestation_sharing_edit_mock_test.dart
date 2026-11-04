// M36（分享链接编辑）/ M58（后台任务重试）的 **Mock Server 验证**。
//
// ## 为什么这两条走 Mock 而不是真机
// 它们的取证都需要**变更动词**：`Sharing/edit` 要先把链接改成别的密码，
// `BackgroundTask` 重试要重发 `CopyMove/start` 这类写操作。
// §5.1 禁止在**用户真 NAS** 上调用变更动词（会在用户数据上留下真实副作用，
// `Sharing/create` 更是会生成一个真实公开 URL）。
//
// ⇒ 正是新规 B1/B2 的场景：**"真机/真 NAS 无法验证的，一律通过 Mock Server 验证"**。
// 下面的变更调用**全部打在内存里的假服务器上**，一个字节都没发到用户 NAS。
//
// ## 关于 `id` 形状的 A/B 说明（诚实边界）
// Mock 只校验 **api / method / version 三元组是否合法**（对照权威 `.lib`），
// **不校验参数值的形状** —— 所以"`id` 该发裸串还是数组"这件事，
// Mock **证明不了**。它是由**反编译 APK** 定案的：
//   `editShareLink`/`getShareLink` 用 `SingleApiParameter("id", p1)`（裸值），
//   `deleteShareLinks(List)` 用 `CompositeApiParameter`（数组）。
// 本文件里的 Mock 只负责证明：**改对形状之后，这个调用组合仍然完全合法。**
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:synhub/src/data/filestation_api.dart';
import 'package:synhub/src/dsm/webapi.dart';

import '../tool/mock_dsm/mock_dsm_core.dart';
import 'support/mock_dsm_transport.dart';

void main() {
  late DsmCatalog catalog;
  late MockDsmBackend backend;
  late MockDsmTransport transport;
  late FileStationApi fs;

  setUp(() async {
    catalog = DsmCatalog.load();
    backend = MockDsmBackend(catalog: catalog);
    backend.login(username: 'u', admin: false);
    transport = MockDsmTransport(backend);
    final web = DsmWebApi(transport);
    await web.discover();
    await web.login(account: 'u', password: 'x');
    fs = FileStationApi(web);
  });

  ({String api, String method, String version, Map<String, dynamic> params})
  lastSharingCall() {
    final r = backend.requests.lastWhere(
      (r) => r.params['api'] == 'SYNO.FileStation.Sharing',
    );
    return (
      api: '${r.params['api']}',
      method: '${r.params['method']}',
      version: '${r.params['version']}',
      params: r.params,
    );
  }

  group('M36 分享链接编辑 —— Mock Server（变更动词只打假服务器）', () {
    test('★ editShareLink 的 api/method/version 组合合法，且 id 是裸字符串', () async {
      await fs.editShareLink(
        id: 'L-1',
        password: 'pw2',
        dateExpired: '2026-12-31',
      );
      final c = lastSharingCall();
      expect(c.api, 'SYNO.FileStation.Sharing');
      expect(c.method, 'edit');
      // 权威 `.lib`：Sharing v1–3 都有 edit
      expect(
        catalog['SYNO.FileStation.Sharing']!.versionsWith('edit'),
        contains(3),
      );
      expect(int.parse(c.version), 3);
      expect(
        transport.last!.errorCode,
        isNull,
        reason: 'Mock 没拒绝 ⇒ 这个组合在权威表里是合法的',
      );
      // ★ 裸串（不是 `["L-1"]`）
      expect(c.params['id'], 'L-1');
      expect(c.params['password'], 'pw2');
      expect(c.params['date_expired'], '2026-12-31');
    });

    test('保持原样时**不发**可选字段（不是发空串）', () async {
      await fs.editShareLink(id: 'L-1');
      final c = lastSharingCall();
      expect(c.params.containsKey('password'), isFalse);
      expect(c.params.containsKey('date_available'), isFalse);
      expect(c.params.containsKey('date_expired'), isFalse);
    });

    // ★ 第 251 轮**订正**：此前这条断言的是"清空密码只发 `password:""`、
    //   改为永久发 `date_expired:""`"，那是**我当时没取证就写的猜测**。
    //   反编译官方 DS file 4.17.2-609 后事实是：
    //     * 清空密码 = `protect_type:"none"` **和** `password:""` 一起发
    //       （`WebApiConnectionManager.editShareLinkV3`）；
    //     * 日期为空 ⇒ **不发** `date_expired`（服务端 `.so` 只认 `%Y-%m-%d`）。
    //   完整逐字段契约见 `test/file_share_edit_contract_test.dart`（8 条）。
    test('清除密码 ⇒ `protect_type:"none"` + `password:""`；日期为空 ⇒ 不发', () async {
      await fs.editShareLink(id: 'L-1', clearPassword: true);
      final c = lastSharingCall();
      expect(c.params['protect_type'], 'none', reason: '此前漏发，已按官方 smali 补上');
      expect(c.params['password'], '');
      expect(
        c.params.containsKey('date_expired'),
        isFalse,
        reason: '官方 edit 在日期为空时直接省略（不是发空串）',
      );
    });

    test('getinfo 同样发裸 id（与 delete 的数组形状**不同**）', () async {
      await fs.shareLinkInfo(['L-9']);
      final c = lastSharingCall();
      expect(c.method, 'getinfo');
      expect(c.params['id'], 'L-9');
      // 反证：delete 走的是数组形状 —— 两者在真机/APK 上确实不一样
      await fs.deleteShareLinks(['L-9']);
      final d = lastSharingCall();
      expect(d.method, 'delete');
      expect(d.params['id'], isNot('L-9'));
    });

    test('空 id 列表直接返回空，不发请求（不制造无意义调用）', () async {
      final before = backend.requests.length;
      expect(await fs.shareLinkInfo([]), isEmpty);
      expect(backend.requests.length, before);
    });
  });

  group('M58 后台任务重试 —— Mock Server', () {
    test('★ retryTask 重发原任务的 api/method，且组合合法', () async {
      // 重试的语义是"把原任务那条请求再发一次"：api/method 来自任务本身，
      // 参数原样透传（不重命名）—— 见 `filestation_api.dart` 的 retryTask。
      await fs.retryTask(
        apiName: 'SYNO.FileStation.CopyMove',
        method: 'start',
        params: const {
          'path': '["/home/a.txt"]',
          'dest_folder_path': '/home/b',
        },
      );
      final r = backend.requests.lastWhere(
        (r) => r.params['api'] == 'SYNO.FileStation.CopyMove',
      );
      expect(r.params['method'], 'start');
      expect(
        catalog['SYNO.FileStation.CopyMove']!.versionsWith('start'),
        isNotEmpty,
        reason: '权威表里 CopyMove.start 必须存在，否则重试打的是幻想方法',
      );
      expect(transport.last!.errorCode, isNull);
    });

    test('重试用任务自己 API 的 maxVersion 协商（不套用别的家族版本）', () async {
      await fs.retryTask(
        apiName: 'SYNO.FileStation.CopyMove',
        method: 'start',
        params: const {
          'path': '["/home/a.txt"]',
          'dest_folder_path': '/home/b',
        },
      );
      final r = backend.requests.lastWhere(
        (r) => r.params['api'] == 'SYNO.FileStation.CopyMove',
      );
      final maxV = catalog['SYNO.FileStation.CopyMove']!.maxVersion;
      expect(int.parse('${r.params['version']}'), lessThanOrEqualTo(maxV));
    });

    test('发明的方法名会被 Mock 抓住（证明这组用例不是必过）', () {
      final r = backend.handle('entry.cgi', {
        'api': 'SYNO.FileStation.CopyMove',
        'method': 'retry',
        'version': 2,
        '_sid': backend.sessions.first,
      });
      expect(r.errorCode, 103);
    });
  });

  group('接线守卫：UI 真的能走到这两个能力', () {
    test('分享管理页真的经 controller 调用 editShareLink（不是只画了个按钮）', () {
      final src = _read('lib/src/features/files/file_pages.dart');
      // ⚠️ 锚点必须精确：`indexOf('editShareLink')` 会命中文件里更早的
      // 文案键 `FsGapTextKeys.editShareLink`（我第一次就是这么错的）。
      // 真正调用点长这样：`await ref.read(fileActionsProvider).editShareLink(`
      final anchor = 'fileActionsProvider).editShareLink(';
      final i = src.indexOf(anchor);
      expect(i, greaterThan(0), reason: '管理页必须真的调用编辑');
      // `showEditShareLinkSheet`（弹编辑面板）在**上一行**，所以窗口要往前带一点。
      final call = src.substring(i - 220, i + 320);
      expect(call, contains('showEditShareLinkSheet'), reason: '得先能弹出编辑面板');
      expect(call, contains('id: link.id'));
      expect(call, contains('dateExpired:'));
      expect(
        call,
        contains('dateExpired:'),
        reason: '编辑面板必须把用户选的到期日传下去',
      );
      expect(
        call,
        isNot(contains('clearExpiry:')),
        reason: '第 251 轮：官方 edit 没有"取消有效期"的报文，参数已移除',
      );
    });

    test('目录 API 里 edit/getinfo 都发裸 id，只有 delete 发数组', () {
      final src = _read('lib/src/data/filestation_api.dart');
      // ⚠️ `indexOf("'edit',")` 会命中第 570 行**另一个 API** 的 edit 方法名
      // （我踩了两次），所以这里用**无歧义**的字面量断言。
      expect(
        src,
        contains("params: {'id': ids.first}"),
        reason: 'getinfo 发裸 id',
      );
      expect(src, contains("        'id': id,"), reason: 'edit 的参数表里是裸 id');
      // delete 是唯一还发数组的地方 —— 计数为 1 才说明"只有它"
      final arrayUses = 'encodePaths(ids)'.allMatches(src).length;
      expect(arrayUses, 1, reason: '只有 delete 发 JSON 数组');
      expect(
        src,
        contains("'id': FileEntryDto.encodePaths(ids)"),
        reason: '那唯一一处就是 delete',
      );
    });
  });
}

String _read(String p) => File(p).readAsStringSync();
