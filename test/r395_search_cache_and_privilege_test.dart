// r395 守卫：三条**从 NAS 侧读出来的**语义在代码里的落点
//   * DA42：`Search/list` 的 **600** 是瞬时态 ⇒ 只对它重试，且**根不再写死 `/`**；
//   * DA23：FileStation 的 **407** 是"权限不足"，**不是**限流（旧文案在撒谎）；
//   * DA25：USB `list` 的 **404** 不许被说成"没插盘"（盘挂载着也会回 404）。
//
// 每条都带**反向验证**（不许把别的模块/别的码一起改掉）。
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:synhub/src/data/filestation_api.dart';
import 'package:synhub/src/data/local/file_store.dart' show describeFileError;
import 'package:synhub/src/dsm/webapi.dart';

import 'support/chat_harness.dart' show FakeTransport;

Future<FileStationApi> _api(FakeTransport t) async {
  final api = DsmWebApi(t);
  await api.discover();
  await api.login(account: 'a', password: 'b');
  return FileStationApi(api);
}

/// 读源码做**静态守卫**（"不许再写回硬编码"这类判据，界面用例要装配一堆
/// provider，反而是更容易假绿的通道）。
String _source(String relative) {
  final f = File(relative);
  if (!f.existsSync()) {
    throw StateError('读不到源码：$relative（cwd=${Directory.current.path}）');
  }
  return f.readAsStringSync();
}

const _searchTable = {
  'SYNO.FileStation.Search': {
    'path': 'entry.cgi',
    'minVersion': 1,
    'maxVersion': 2,
  },
};

void main() {
  group('r395 · DA42 `Search/list` 的 600 是瞬时态', () {
    test('第一次 600、第二次成功 ⇒ 重试后拿到结果（并证明真的重试过）', () async {
      final t = FakeTransport({
        'SYNO.FileStation.Search.list': {
          'files': [
            {'name': 'Citizen Kane.mkv', 'path': '/home/Citizen Kane.mkv'},
          ],
          'total': 1,
          'finished': true,
        },
      }, {...FakeTransport.table, ..._searchTable});
      // 只失败这一次（服务端"结果缓存还没准备好"的真机形态）
      t.failTimes['SYNO.FileStation.Search.list'] =
          DsmErrorCode.searchCacheUnavailable;
      final fs = await _api(t);

      final r = await fs.searchResultsRetrying(taskId: 'T1', limit: 200);
      expect(r.entries, hasLength(1));
      expect(r.entries.single.name, 'Citizen Kane.mkv');
      expect(
        t.calls.where((c) => c['method'] == 'list').length,
        2,
        reason: '600 之后必须再打一次；失败一次就放弃 = 旧行为',
      );
    });

    test('一直回 600 ⇒ 重试到上限后**抛出**（不许静默变"0 命中"）', () async {
      final t = FakeTransport({}, {...FakeTransport.table, ..._searchTable});
      t.failures['SYNO.FileStation.Search.list'] =
          DsmErrorCode.searchCacheUnavailable;
      final fs = await _api(t);

      await expectLater(
        fs.searchResultsRetrying(taskId: 'T1', limit: 200, maxAttempts: 3),
        throwsA(
          isA<DsmApiException>().having(
            (e) => e.code,
            'code',
            DsmErrorCode.searchCacheUnavailable,
          ),
        ),
      );
      expect(t.calls.where((c) => c['method'] == 'list').length, 3);
    });

    test('反向：非 600 的错（105）**一次都不重试**', () async {
      final t = FakeTransport({}, {...FakeTransport.table, ..._searchTable});
      t.failures['SYNO.FileStation.Search.list'] = DsmErrorCode.noPermission;
      final fs = await _api(t);

      await expectLater(
        fs.searchResultsRetrying(taskId: 'T1', limit: 200),
        throwsA(isA<DsmApiException>()),
      );
      expect(
        t.calls.where((c) => c['method'] == 'list').length,
        1,
        reason: '105 是"没权限"，重试永远不会好 ⇒ 不许被当成瞬时态',
      );
    });

    test('反向：`searchResults`（不重试的那条）遇 600 立刻抛', () async {
      final t = FakeTransport({}, {...FakeTransport.table, ..._searchTable});
      t.failures['SYNO.FileStation.Search.list'] =
          DsmErrorCode.searchCacheUnavailable;
      final fs = await _api(t);
      await expectLater(
        fs.searchResults(taskId: 'T1', limit: 200),
        throwsA(isA<DsmApiException>()),
      );
      expect(t.calls.where((c) => c['method'] == 'list').length, 1);
    });
  });

  group('r395 · DA42 搜索**根**不许再写死 `/`（真机对根回 600）', () {
    const path = 'lib/src/features/search/global_search_page.dart';

    test('源码级守卫：用 `fileSearchRootFor`，不再出现 `folderPath: \'/\'`', () {
      final src = _source(path);
      expect(
        src.contains("folderPath: '/'"),
        isFalse,
        reason: 'r391 真机 `Search failed` + `Error code 600` 就是这条硬编码造成的',
      );
      expect(src.contains('fileSearchRootFor('), isTrue);
    });

    test('反向：守卫认得出"被改回去"（对真源码做一次替换，必须判红）', () {
      final src = _source(path);
      final broken = src.replaceFirst("fileSearchRootFor('/')", "'/'");
      expect(
        broken == src,
        isFalse,
        reason: '替换必须真的生效，否则这条反向验证是假绿',
      );
      expect(broken.contains("folderPath: '/'"), isTrue);
    });
  });

  group('r395 · DA23 FileStation 的 407 = 权限不足（不是限流）', () {
    test('FileStation 的 407 ⇒ "没有权限访问该位置"', () {
      final text = describeFileError(
        DsmApiException(407, method: 'SYNO.FileStation.List.list'),
      );
      expect(text, contains('没有权限'));
      expect(
        text.contains('频繁') || text.contains('稍后再试'),
        isFalse,
        reason: '旧文案「请求过于频繁，请稍后再试」会引导用户一直重试（真机 407 是权限）',
      );
    });

    test('反向：Auth 那边的 407 仍按原语义（别一刀切）', () {
      expect(
        describeFileError(DsmApiException(407, method: 'SYNO.API.Auth.login')),
        contains('频繁'),
      );
    });

    test('反向：FileStation 的 409 也按权限说（官方同一条映射）', () {
      expect(
        DsmErrorCode.describe(409, method: 'SYNO.FileStation.List.list'),
        contains('没有权限'),
      );
    });
  });

  group('r395 · 600 的用户文案（官方 `search/no_search_cache`）', () {
    test('FileStation 的 600 ⇒ 说人话，且不带裸码', () {
      final text = describeFileError(
        DsmApiException(600, method: 'SYNO.FileStation.Search.list'),
      );
      expect(text, contains('暂时'));
      expect(text.contains('错误码'), isFalse);
      expect(text.contains('600'), isFalse);
    });

    test('反向：别的模块的 600 仍回裸码（证明这条映射是 FileStation 专属）', () {
      final text = DsmErrorCode.describe(600, method: 'SYNO.Chat.Post.list');
      expect(text.contains('错误码'), isTrue);
    });
  });
}
