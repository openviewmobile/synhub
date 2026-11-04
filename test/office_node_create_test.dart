// ★★ **③Drive 第 63 轮：D56「Office 新建」** —— 实现 `Office.Node/create`
//
// ## D56 缺口原文
// > `D56 / :398 | **Office 新建** | `Office.Node/create {path,ntype,title}`，
// >  `ntype∈{doc,sheet}` | 🟠部分（刷新：❌→🟠） |
// >  `data/office_api.dart:32-34` 仍**不调用** `Node:create`；
// >  但模板新建已可达 | 缺口：空白 doc/sheet 新建分支仍缺；仅模板路径`
//
// ## ★★ 本轮最重要的发现：**`create` 只存在于 v1**
// 服务端 `.lib`（`export_Office/webapi/SYNO.Office.lib`，权威 JSON）：
// ```
// SYNO.Office.Node   min 1  max 2
//   v1: get, set, create, delete, copy
//   v2: touch, copy          ← ★ 没有 create！
// ```
// ⇒ **照 `maxVersion`(=2) 去请求 `create` 会回 `103 方法不存在`**。
// 这不是理论担心：本仓库别处就有"照 maxVersion 协商"踩 103 的先例
// （`office_api.dart` 的 `_negotiate` 注释里记着 `SYNO.Office.File` 的事故）。
// 所以 `createNode` 显式走 `_v1`，并且本文件用用例把它钉住。
//
// ## 另外两个易错点（都会"静默错误"）
// * `path` 是**父文件夹**（`id:<父 file_id>`），**不是**新文件的路径 ——
//   官方 `OfficeNodeCreateWork.byFileId` → `computePathById(parentFileId)`；
// * `ntype` 官方**只有 `doc`/`sheet`，没有 `slide`**；
//   服务端对未知 `ntype` **不报错**，会建出一个你以为不存在的类型。
//
// 全程内存 Mock，不碰真机（规程 §5.1）。
import 'package:flutter_test/flutter_test.dart';

import 'package:synhub/src/data/office_api.dart';
import 'package:synhub/src/dsm/webapi.dart';

import '../tool/mock_dsm/mock_dsm_core.dart';
import 'support/mock_dsm_transport.dart';

const _api = 'SYNO.Office.Node';

void main() {
  late MockDsmBackend backend;
  late DsmWebApi web;
  late OfficeApi office;

  setUp(() async {
    backend = MockDsmBackend(catalog: DsmCatalog.load());
    backend.login(username: 'demo_user', admin: false);
    backend.fixture(_api, 'create', (p) {
      return {
        'success': true,
        'data': {
          'file_id': 'newfile123',
          'link_id': 'newlink456',
          'display_path': '/mydrive/未命名文档.odoc',
          'perm': 'rw',
        },
      };
    });
    web = DsmWebApi(MockDsmTransport(backend));
    await web.discover();
    await web.login(account: 'demo_user', password: 'x');
    office = OfficeApi(web);
  });

  Map<String, dynamic> lastCreate() {
    final r = backend.requests
        .where((r) => '${r.params['api']}' == _api)
        .where((r) => '${r.params['method']}' == 'create')
        .toList();
    expect(r, isNotEmpty, reason: '必须真的发出了 create');
    return r.last.params;
  }

  group('DO56-1. ★★★ `create` 只能走 v1（v2 根本没有这个方法）', () {
    test('★★★ 服务端 `.lib`：v1 有 create、v2 没有', () {
      final spec = DsmCatalog.load()[_api]!;
      expect(spec.minVersion, 1);
      expect(spec.maxVersion, 2, reason: '★ maxVersion 是 2 —— 这正是坑所在');
      expect(
        spec.methods[1],
        contains('create'),
        reason: '★ 官方 `ApiSynoOfficeNode.METHOD_NAME__CREATE` 在 v1',
      );
      expect(
        spec.methods[2],
        isNot(contains('create')),
        reason:
            '★★★ v2 只有 `touch`/`copy`。**没有 create** ——'
            ' 所以"照 maxVersion 协商"必然撞 103',
      );
    });

    test('★★★ 我方请求的版本是 **1**（不是 maxVersion=2）', () async {
      await office.createNode(
        parentId: 'folder99',
        type: OfficeNodeType.doc,
        title: '未命名文档',
      );
      final ver = lastCreate()['version'];
      expect(
        '$ver',
        '1',
        reason:
            '★★★ 若这里是 2，服务端会回 `103 方法不存在`，'
            '而 UI 上表现成"新建失败" —— 用户根本猜不到是版本协商错了',
      );
    });
  });

  group('DO56-1b. ★★★ 反证：真的用 v2 请求 ⇒ 103（证明防线不是空的）', () {
    test('★★★ `create` + version=2 ⇒ 103 方法不存在', () async {
      // 直接绕过 `createNode`，模拟"照 maxVersion 协商"的写法
      var code = -1;
      try {
        await web.call(
          _api,
          'create',
          preferredVersion: 2,
          params: const {'path': 'id:f', 'ntype': 'doc', 'title': 't'},
        );
      } on DsmApiException catch (e) {
        code = e.code;
      }
      expect(
        code,
        103,
        reason:
            '★★★ 这条**就是**"必须走 v1"的证据。'
            '没有它，`version == 1` 那条断言只说明"我们发了 1"，'
            '证明不了"发 2 会坏"。'
            '★ 对照组：`touch` 在 v2 里**是**存在的（下面那条）',
      );
    });

    test('★★ 对照：v2 里**存在**的 `touch` 不会 103（否则反证无意义）', () async {
      var code = -1;
      try {
        await web.call(
          _api,
          'touch',
          preferredVersion: 2,
          params: const {'path': 'id:f'},
        );
      } on DsmApiException catch (e) {
        code = e.code;
      }
      expect(
        code,
        isNot(103),
        reason:
            '★ 若这里也 103，说明"v2 全部方法都不可用"，'
            '那上面那条反证就只是假象',
      );
    });
  });

  group('DO56-2. ★★ 参数语义：`path` 是**父文件夹**，`ntype` 只有两个值', () {
    test('★★ `path` = `id:<父文件夹>`（不是新文件的路径）', () async {
      await office.createNode(
        parentId: 'folder99',
        type: OfficeNodeType.doc,
        title: '未命名文档',
      );
      final p = lastCreate();
      expect(
        p['path'],
        'id:folder99',
        reason:
            '★★ 官方 `computePathById(parentFileId)` ⇒ `id:<父 file_id>`；'
            '若误当成"新文件的完整路径"，会在**错误的位置**建出文件'
            '（或报 102），而路径拼接错误在我们这里最容易发生',
      );
      expect(
        p['path'],
        isNot(contains('未命名')),
        reason: '★ 标题**不进** path —— 它是独立的 `title` 参数',
      );
    });

    test('★ 已带前缀的 `id:` 不会被重复加前缀', () async {
      await office.createNode(
        parentId: 'id:folder99',
        type: OfficeNodeType.sheet,
        title: 't',
      );
      expect(
        lastCreate()['path'],
        'id:folder99',
        reason: '★ 幂等：避免出现 `id:id:folder99` 这种 102',
      );
    });

    test('★★ `ntype` 是三种：`doc` / `sheet` / `presentation`', () {
      // ★★ 第 257 轮更正：旧用例写的是 {'doc','sheet'} + "**没有 slide**"，
      // 依据只有安卓 APK（`ApiSynoOfficeNode:22-23`）。**那个结论是错的**：
      // APK 只是官方 Web 客户端的子集。
      // 官方 Office Web 客户端（SPK `Office-3.8.0-22711` `ui.doc.js`）里
      // 三种都给：`createNode({ntype:"doc"|"sheet"|"presentation"})`，
      // 「加密新建」子菜单同样四种（含模板）。契约全文见
      // `docs/drive-office-create.md`。
      final values = {for (final t in OfficeNodeType.values) t.value};
      expect(
        values,
        {'doc', 'sheet', 'presentation'},
        reason: '★★ 少一个 = 用户建不出那一类（演示文稿此前就漏了整轮）',
      );
    });

    test('★★ 服务端 `ntype` **不是** `slide`/`slides`（那只在后缀里）', () {
      // `getNTypeByObjectId` 把 `.slide` → `"presentation"`；把 object_id 的
      // 后缀当 `ntype` 发，服务端**不报错**（会安静地建出别的东西）⇒ 守住。
      for (final t in OfficeNodeType.values) {
        expect(t.value, isNot(anyOf('slide', 'slides', 'pptx', 'odoc')));
      }
      expect(
        officeNodeTypeFromObjectId('7_deck.tpl.slide'),
        OfficeNodeType.presentation,
        reason: 'object_id 的 `.slide` 后缀 → ntype `presentation`（官方映射）',
      );
    });

    test('★ `title` 单独传（与官方 `putParam("title", …)` 一致）', () async {
      await office.createNode(
        parentId: 'folder99',
        type: OfficeNodeType.doc,
        title: '季度报告',
      );
      expect(lastCreate()['title'], '季度报告');
    });
  });

  group('DO56-3. ★ 返回字段按官方 VO 解出', () {
    test('★ 解出 `fileId`/`linkId`/`displayPath`/`perm`', () async {
      final r = await office.createNode(
        parentId: 'folder99',
        type: OfficeNodeType.doc,
        title: '未命名文档',
      );
      expect(r.fileId, 'newfile123');
      expect(r.linkId, 'newlink456');
      expect(r.displayPath, '/mydrive/未命名文档.odoc');
      expect(r.perm, 'rw');
    });

    test('★ 缺字段时回落空串（不抛，调用方自己判断）', () async {
      final b2 = MockDsmBackend(catalog: DsmCatalog.load());
      b2.login(username: 'demo_user', admin: false);
      b2.fixture(_api, 'create', (p) => {'success': true, 'data': {}});
      final w2 = DsmWebApi(MockDsmTransport(b2));
      await w2.discover();
      await w2.login(account: 'demo_user', password: 'x');
      final r = await OfficeApi(
        w2,
      ).createNode(parentId: 'f', type: OfficeNodeType.doc, title: 't');
      expect(r.fileId, '');
      expect(r.linkId, '');
    });
  });
}
