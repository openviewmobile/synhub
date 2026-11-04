// ★★ **③Drive 第 58 轮：D53「任务重试/暂停/取消」的重新裁决**
//
// ## D53 缺口原文
// `D53 / :395 | 任务进度 / 失败重试 / 并发干预 | 🟠部分 |
//  实现：`drive_tasks_page.dart` 只读进度 | 缺口：不能重试/暂停/取消`
//
// ## 取证结论：**服务端没有这些操作**
// `ApiSynoDriveTasks.java:13-15`（官方 APK）：
// ```java
// METHOD_NAME__LIST   = "list"
// METHOD_NAME__GET    = "get"
// METHOD_NAME__DELETE = "delete"
// ```
// 只有这三个。服务端 `.lib` 侧交叉确认（`tool/mock_dsm/catalog.json`，
// `source: "spk"`）：`maxVersion=1`、`methods["1"] = [delete, get, list]`。
//
// ⇒ 把"不能重试/暂停/取消"记成**客户端缺口**是**口径错误**：
//   官方 App 也做不到，因为服务端没有对应方法。
//
// ## 本文件要钉的两件事
// ① **正证**：`list` / `get` / `delete` 三个逐版本允许的方法都在，
//    且**普通用户可用**（不是 admin-only）；
// ② **反证**：`retry` / `pause` / `resume` / `cancel` 一律 **103（方法不存在）**
//    —— 这条反证防止以后有人"凭印象"实现一个服务端不认的接口，
//    那会得到一个**永远失败**的功能（比不做更糟）。
//
// 把反证写成用例是有意的：**"官方没有这个能力"本身是需要证据的结论**，
// 不能只写在注释里。
//
// 全程内存 Mock，不碰真机（规程 §5.1）。
import 'package:flutter_test/flutter_test.dart';

import 'package:synhub/src/dsm/webapi.dart';

import '../tool/mock_dsm/mock_dsm_core.dart';
import 'support/mock_dsm_transport.dart';

const _api = 'SYNO.SynologyDrive.Tasks';

void main() {
  late MockDsmBackend backend;
  late DsmWebApi web;

  setUp(() async {
    backend = MockDsmBackend(catalog: DsmCatalog.load());
    backend.login(username: 'demo_user', admin: false);
    web = DsmWebApi(MockDsmTransport(backend));
    await web.discover();
    await web.login(account: 'demo_user', password: 'x');
  });

  group('DT-1. ★★ 官方方法表：**只有** list / get / delete', () {
    test('★★ 服务端 `.lib` 里就是这三个（逐版本）', () {
      final spec = backend.catalog[_api];
      expect(spec, isNotNull, reason: '这个 API 必须在权威目录里');
      expect(
        spec!.methods[1],
        containsAll(<String>['list', 'get', 'delete']),
        reason: '★ 官方 `ApiSynoDriveTasks.java:13-15` 的三个常量',
      );
      expect(spec.methods[1]!.length, 3, reason: '★★ **正好三个** —— 多出来的就说明我在编接口');
      expect(spec.minVersion, 1);
      expect(spec.maxVersion, 1);
    });

    test('★★ **普通用户**可用（不是 admin-only）—— 名字像管理但名字不算数', () {
      final spec = backend.catalog[_api]!;
      expect(spec.adminOnly, isFalse);
      expect(
        spec.allowUser.any((u) => u.startsWith('normal.')),
        isTrue,
        reason:
            '★ 就像 `SYNO.Chat.Admin.Setting` 一样：'
            '**名字里有 Admin 不代表是管理员专属**，要看 allowUser',
      );
    });
  });

  group('DT-2. ★★★ 反证：retry / pause / resume / cancel **一律 103**', () {
    for (final m in ['retry', 'pause', 'resume', 'cancel', 'stop', 'start']) {
      test('★★★ `$m` 不存在 ⇒ 103（不是 105、不是 114）', () async {
        // 显式 try/catch：要断言的是**具体错误码**，这样写失败信息更好读。
        // （一开始用了 `isA<...>().having(...)`，本仓库的 matcher 版本
        //   需要 3 个位置参数，编译不过 —— 换成直白写法。）
        var code = -1;
        try {
          await web.call(
            _api,
            m,
            preferredVersion: 1,
            params: const {'task_id': 't1'},
          );
        } on DsmApiException catch (e) {
          code = e.code;
        }
        expect(
          code,
          103,
          reason:
              '★★★ 103 = 方法不存在。若这里返回别的码，说明我钉错了前提。'
              '这条就是"服务端没有暂停/取消任务"的**证据** —— '
              '没有它，"不能重试/暂停/取消"就只是我的说法',
        );
      });
    }

    test('★★ 对照：`get` / `delete` **不**返回 103（否则反证无意义）', () async {
      for (final m in ['get', 'delete', 'list']) {
        try {
          await web.call(
            _api,
            m,
            preferredVersion: 1,
            params: const {'task_id': 't1'},
          );
        } on DsmApiException catch (e) {
          expect(
            e.code,
            isNot(103),
            reason:
                '★ `$m` 是官方方法，必须**存在**；否则说明上面的'
                '反证只是"整个 API 都不可用"的假象',
          );
        }
      }
    });
  });

  group('DT-3. ★ 版本议价：只有 v1', () {
    test('★ 请求 v5 时服务端仍按 v1 解析（不报"版本不支持"）', () async {
      // `resolveMethodVersion` 取 ≤ 请求版本的最近一个已列版本 ⇒ v1
      try {
        await web.call(_api, 'list', preferredVersion: 5);
      } on DsmApiException catch (e) {
        expect(
          e.code,
          isNot(103),
          reason: '★ 官方 `maxVersion=1`；请求更高版本不应变成"方法不存在"',
        );
      }
    });
  });
}
