// Download Station **wave5** 离线验证：
//   * A. `SYNO.DownloadStation2.Captcha` —— 下载任务的验证码
//     （`list` v2 / `set {task_id, code}` v2 / `download {task_id}` v2 直链）；
//   * B. `SYNO.DownloadStation2.Task.List` —— 清单读取/删除 + `download` 降级路径。
//
// 事实来源（本文件的断言全部对着它们写，**不猜**）：
//   * SPK `webapi/SYNO.DownloadStation2.Captcha.lib`：`list`/`set`/`download`
//     全在 **v1–v2**，`normal.local` 可用；
//   * SPK `webapi/SYNO.DownloadStation2.Task.lib`：`Task.List` `get`/`download`/
//     `delete` **v1–v2**，而 `Task.List.Polling` **minVersion=2**；
//   * 官方 `ui/download.js` 的 `DLM.CaptchaEnterDialog`（逐字）：`webapiList`/
//     `webapiSet{params:{task_id,code}}`/`webapiDownload{params:{task_id,t}}`、
//     错误码 `2301 = download_error_wrong_captcha`；
//   * 真机只读探针（2026-09-22，普通用户）：
//       `Captcha:list v2`         → `{"data":{"task_ids":[]}}`
//       `Captcha:list v1`         → `{"data":[]}`（裸数组）
//       `Captcha:download v2 {}`  → `120 {"name":"task_id"}`
//       `Captcha:set v2 {}`       → `120 {"name":"code"}`
//       `Task.List:get v2 {}`     → `120 {"name":"list_id"}`
//       `Task.List:get v2 {list_id:"bogus"}` → `1910`
//       `Task.List:download v2 {list_id:"bogus"}` → `120 {"name":"destination"}`
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:synhub/src/data/download_station.dart';
import 'package:synhub/src/data/dto/download_task_dto.dart';
import 'package:synhub/src/dsm/webapi.dart';
import 'package:synhub/src/features/downloads/download_captcha_page.dart';
import 'package:synhub/src/features/downloads/download_page.dart';
import 'package:synhub/src/features/downloads/download_providers.dart';

import 'package:synhub/src/core/theme/app_theme.dart';
import 'support/chat_harness.dart' show FakeTransport;

/// 1×1 PNG（合法图片，避免 `Image.memory` 解码失败污染测试）。
const _pngB64 =
    'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR4nGP4z8DwHwAFAAH/'
    'iZk9HQAAAABJRU5ErkJggg==';

/// 这台 NAS 的真实能力表条目（`SYNO.API.Info` 实测 + `.lib` 版本区间）。
Map<String, Map<String, dynamic>> _table({List<String> drop = const []}) => {
  ...FakeTransport.table,
  'SYNO.API.Info': {'path': 'query.cgi', 'minVersion': 1, 'maxVersion': 1},
  'SYNO.DownloadStation2.Task': {
    'path': 'entry.cgi',
    'minVersion': 1,
    'maxVersion': 2,
  },
  'SYNO.DownloadStation2.Task.Statistic': {
    'path': 'entry.cgi',
    'minVersion': 1,
    'maxVersion': 1,
  },
  'SYNO.DownloadStation2.Task.List': {
    'path': 'entry.cgi',
    'minVersion': 1,
    'maxVersion': 2,
  },
  'SYNO.DownloadStation2.Task.List.Polling': {
    'path': 'entry.cgi',
    'minVersion': 2,
    'maxVersion': 2,
  },
  // 真机：`path=entry.cgi`、v1–2、`requestFormat:"JSON"`
  'SYNO.DownloadStation2.Captcha': {
    'path': 'entry.cgi',
    'minVersion': 1,
    'maxVersion': 2,
  },
  'SYNO.DownloadStation2.Settings.Location': {
    'path': 'entry.cgi',
    'minVersion': 1,
    'maxVersion': 1,
  },
}..removeWhere((k, _) => drop.contains(k));

/// 假传输：`Captcha.list` 走**二进制通道**（真机 v2 是 Map、v1 是裸数组），
/// 验证码图片走 `getBytes`（`bytesByUrl['method=download']`）。
class _CaptchaTransport extends FakeTransport {
  _CaptchaTransport(super.responses, super.apiTable);

  List<String> captchaIds = const [];

  /// true = 模拟**只提供 v1** 的 NAS（`data` 是裸数组）。
  bool bareList = false;

  /// 非空 → `Captcha.list` 回**错误信封**（验"不许静默成空"）。
  int? listErrorCode;

  @override
  Future<List<int>> postBytes(
    String path,
    Map<String, dynamic> params, {
    void Function(int received, int total)? onProgress,
    DownloadCancelToken? cancelToken,
    String? module,
  }) async {
    if (params['api'] == DownloadStationApi.apiCaptcha &&
        params['method'] == 'list') {
      postDownloads.add(
        '$path?${params.entries.map((e) => '${e.key}=${e.value}').join('&')}',
      );
      if (listErrorCode != null) {
        return utf8.encode(
          jsonEncode({
            'success': false,
            'error': {'code': listErrorCode},
          }),
        );
      }
      return utf8.encode(
        jsonEncode({
          'success': true,
          'data': bareList ? captchaIds : {'task_ids': captchaIds},
        }),
      );
    }
    return super.postBytes(
      path,
      params,
      onProgress: onProgress,
      cancelToken: cancelToken,
    );
  }
}

Future<(_CaptchaTransport, DownloadStationApi)> _boot({
  Map<String, Map<String, dynamic>> responses = const {},
  List<String> dropApis = const [],
  void Function(_CaptchaTransport t)? setup,
}) async {
  final t = _CaptchaTransport(responses, _table(drop: dropApis));
  t.bytesByUrl['method=download'] = base64Decode(_pngB64);
  setup?.call(t);
  final api = DsmWebApi(t);
  await api.discover();
  await api.login(account: 'a', password: 'b');
  return (t, DownloadStationApi(api));
}

Map<String, dynamic> _call(FakeTransport t, String method) =>
    t.calls.lastWhere((c) => c['method'] == method);

/// 挂 `DownloadPage`（假传输 + 只覆盖下载模块的 API provider）。
Future<({FakeTransport t, ProviderContainer c})> _pumpPage(
  WidgetTester tester, {
  List<String> captchaIds = const [],
  int? listErrorCode,
  bool bareList = false,
  Map<String, int> failures = const {},
  Map<String, Map<String, dynamic>> responses = const {},
  List<String> dropApis = const [],
}) async {
  final t = _CaptchaTransport(responses, _table(drop: dropApis))
    ..captchaIds = captchaIds
    ..listErrorCode = listErrorCode
    ..bareList = bareList
    ..bytesByUrl['method=download'] = base64Decode(_pngB64);
  t.failures.addAll(failures);
  final api = DsmWebApi(t);
  await api.discover();
  final c = ProviderContainer(
    overrides: [downloadApiProvider.overrideWithValue(DownloadStationApi(api))],
  );
  addTearDown(c.dispose);
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: c,
      child: MaterialApp(theme: AppTheme.dark(), home: DownloadPage()),
    ),
  );
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 200));
  return (t: t, c: c);
}

void main() {
  group('A · Captcha API 层', () {
    test('list v2 → 解析 task_ids；走路径 entry.cgi + version=2', () async {
      final (t, ds) = await _boot(
        setup: (t) => t.captchaIds = const ['T1', 'T2'],
      );
      final ids = await ds.captchaTaskIds();
      expect(ids, ['T1', 'T2']);
      final req = t.postDownloads.single;
      expect(req, contains('entry.cgi'));
      expect(req, contains('api=SYNO.DownloadStation2.Captcha'));
      expect(req, contains('method=list'));
      expect(req, contains('version=2'));
      // **内部 id 只在请求参数里**（不在任何展示文案里）
      expect(ids.first, 'T1');
    });

    test('list v1（只提供 v1 的 NAS）→ 裸数组也能解析，不静默成空', () async {
      final t =
          _CaptchaTransport({}, {
              ..._table(),
              'SYNO.DownloadStation2.Captcha': {
                'path': 'entry.cgi',
                'minVersion': 1,
                'maxVersion': 1,
              },
            })
            ..captchaIds = const ['T9']
            ..bareList = true;
      final api = DsmWebApi(t);
      await api.discover();
      await api.login(account: 'a', password: 'b');
      final ids = await DownloadStationApi(api).captchaTaskIds();
      expect(ids, ['T9'], reason: 'v1 的 data 是裸数组，必须解析出来');
      expect(t.postDownloads.last, contains('version=1'));
    });

    test('list 回错误信封 → 抛 DsmApiException（不静默成空表）', () async {
      final (_, ds) = await _boot(
        setup: (t) => t.listErrorCode = DsmErrorCode.noPermission,
      );
      await expectLater(
        ds.captchaTaskIds(),
        throwsA(
          isA<DsmApiException>().having(
            (e) => e.code,
            'code',
            DsmErrorCode.noPermission,
          ),
        ),
      );
    });

    test('set v2 参数名逐字是 task_id + code（不是 captcha）', () async {
      final (t, ds) = await _boot();
      await ds.setCaptcha(taskId: 'T1', code: ' ab12 ');
      final c = _call(t, 'set');
      expect(c['api'], 'SYNO.DownloadStation2.Captcha');
      expect(c['version'], '2');
      expect(c['task_id'], 'T1');
      expect(c['code'], 'ab12'); // 已 trim
      expect(c.containsKey('captcha'), isFalse);
    });

    test('set 缺 code → 本地先报 120（不白跑一次真机写）', () async {
      final (t, ds) = await _boot();
      await expectLater(
        ds.setCaptcha(taskId: 'T1', code: '   '),
        throwsA(
          isA<DsmApiException>().having(
            (e) => e.code,
            'code',
            DsmErrorCode.noRequiredParam,
          ),
        ),
      );
      expect(t.calls.where((c) => c['method'] == 'set'), isEmpty);
    });

    test('download 直链：method=download + task_id + t 防缓存', () async {
      final (_, ds) = await _boot();
      final url = ds.captchaImageUrl('T1', cacheBuster: '123');
      expect(url, contains('api=SYNO.DownloadStation2.Captcha'));
      expect(url, contains('method=download'));
      expect(url, contains('version=2'));
      expect(url, contains('task_id=T1'));
      expect(url, contains('t=123'));
    });

    test('2301 / 1910 的错误文案（不吞、不编）', () {
      expect(
        describeDownloadError(
          DsmApiException(DownloadStationApi.errWrongCaptcha),
        ),
        '验证码不正确，请重新输入',
      );
      expect(
        describeDownloadError(
          DsmApiException(DownloadStationApi.errTaskListNotFound),
        ),
        '文件清单已过期，请重新添加这个任务',
      );
    });
  });

  group('B · Task.List API 层', () {
    test('get 必带 list_id（真机 120 报的就是这个名字）', () async {
      final (t, ds) = await _boot(
        responses: {
          'SYNO.DownloadStation2.Task.List.get': {
            'files': [
              {'index': 0, 'name': 'a.mkv', 'size': 10, 'enable': true},
            ],
            'total': 1,
          },
        },
      );
      final list = await ds.getCreateList('L1');
      expect(list.files.single.name, 'a.mkv');
      expect(_call(t, 'get')['list_id'], 'L1');
    });

    test('delete 必带 list_id', () async {
      final (t, ds) = await _boot();
      await ds.deleteCreateList('L1');
      expect(_call(t, 'delete')['list_id'], 'L1');
    });

    test('download（降级路径）带 list_id + destination，回包 task_id 宽容解析', () async {
      final (t, ds) = await _boot(
        responses: {
          'SYNO.DownloadStation2.Task.List.download': {'task_id': 'TASK-9'},
        },
      );
      final taskId = await ds.taskListDownload(
        listId: 'L1',
        destination: '/volume1/downloads',
        selected: const [0, 2],
      );
      expect(taskId, 'TASK-9');
      final c = _call(t, 'download');
      expect(c['list_id'], 'L1');
      // 真机：缺 destination → `120 {"name":"destination"}`
      expect(c['destination'], contains('/volume1/downloads'));
      expect('${c['selected']}', contains('0'));
    });

    test('能力位只到 v1 时按 v1 发（Task.List 是 v1–v2）', () async {
      final t = _CaptchaTransport({}, {
        ..._table(),
        'SYNO.DownloadStation2.Task.List': {
          'path': 'entry.cgi',
          'minVersion': 1,
          'maxVersion': 1,
        },
      });
      final api = DsmWebApi(t);
      await api.discover();
      await api.login(account: 'a', password: 'b');
      await DownloadStationApi(
        api,
      ).taskListDownload(listId: 'L1', destination: '/d');
      expect(_call(t, 'download')['version'], '1');
    });
  });

  group('B · 降级选择（startCreateList）', () {
    test('有 Polling 能力位 → 走官方 Web UI 的 Polling.download', () async {
      final (t, ds) = await _boot();
      await DownloadActions(
        ds,
      ).startCreateList(listId: 'L1', destination: '/d');
      final c = _call(t, 'download');
      expect(c['api'], 'SYNO.DownloadStation2.Task.List.Polling');
      expect(c['list_id'], 'L1');
    });

    test('没有 Polling（老 NAS）→ 降级 Task.List.download，且补默认目录', () async {
      final (t, ds) = await _boot(
        dropApis: const ['SYNO.DownloadStation2.Task.List.Polling'],
        responses: {
          'SYNO.DownloadStation2.Settings.Location.get': {
            'default_destination': '/volume1/downloads',
          },
        },
      );
      await DownloadActions(ds).startCreateList(listId: 'L1');
      final c = _call(t, 'download');
      expect(c['api'], 'SYNO.DownloadStation2.Task.List');
      expect(c['list_id'], 'L1');
      expect(c['destination'], contains('/volume1/downloads'));
      expect(c['version'], '2');
    });

    test('没有 Polling 且没有默认目录 → 明确报 406，不静默', () async {
      final (t, ds) = await _boot(
        dropApis: const ['SYNO.DownloadStation2.Task.List.Polling'],
      );
      await expectLater(
        DownloadActions(ds).startCreateList(listId: 'L1'),
        throwsA(isA<DsmApiException>().having((e) => e.code, 'code', 406)),
      );
      expect(t.calls.where((c) => c['method'] == 'download'), isEmpty);
    });
  });

  group('C · 页面：验证码入口（不许静默失败）', () {
    testWidgets('有验证码任务 → 列表页出现入口条 + 提交按钮', (tester) async {
      await _pumpPage(
        tester,
        responses: const {
          'SYNO.DownloadStation2.Task.list': {'task': [], 'total': 0},
        },
        captchaIds: const ['SECRET-TASK-1'],
      );
      expect(find.byKey(const Key('ds-captcha-banner')), findsOneWidget);
      expect(find.byKey(const Key('ds-captcha-open')), findsOneWidget);
      expect(find.textContaining('1 个任务需要输入验证码'), findsOneWidget);
      // 内部 id 绝不上屏
      expect(find.textContaining('SECRET-TASK-1'), findsNothing);
    });

    testWidgets('没有验证码任务 → 不出现入口（也不出现假入口）', (tester) async {
      await _pumpPage(
        tester,
        responses: const {
          'SYNO.DownloadStation2.Task.list': {'task': [], 'total': 0},
        },
      );
      expect(find.byKey(const Key('ds-captcha-banner')), findsNothing);
    });

    testWidgets('能力表没有 Captcha → 不出现入口（缺失即隐藏）', (tester) async {
      await _pumpPage(
        tester,
        responses: const {
          'SYNO.DownloadStation2.Task.list': {'task': [], 'total': 0},
        },
        captchaIds: const ['SECRET-TASK-1'],
        dropApis: const ['SYNO.DownloadStation2.Captcha'],
      );
      expect(find.byKey(const Key('ds-captcha-banner')), findsNothing);
    });

    testWidgets('任务状态 15（captchaNeeded）→ 即使 Captcha:list 为空也有入口', (
      tester,
    ) async {
      await _pumpPage(
        tester,
        responses: const {
          'SYNO.DownloadStation2.Task.list': {
            'task': [
              {
                'id': 'SECRET-TASK-1',
                'title': 'a.iso',
                'type': 'bt',
                'status': DsTaskStatus.captchaNeeded,
                'size': 10,
              },
            ],
            'total': 1,
          },
        },
      );
      expect(find.byKey(const Key('ds-captcha-banner')), findsOneWidget);
      expect(find.textContaining('SECRET-TASK-1'), findsNothing);
    });

    testWidgets('点入口 → 验证码页：有图片、有 code 输入框、无内部 id', (tester) async {
      final (:t, :c) = await _pumpPage(
        tester,
        responses: const {
          'SYNO.DownloadStation2.Task.list': {'task': [], 'total': 0},
        },
        captchaIds: const ['SECRET-TASK-1'],
      );
      await tester.tap(find.byKey(const Key('ds-captcha-open')));
      await tester.pumpAndSettle();
      expect(find.byType(DownloadCaptchaPage), findsOneWidget);
      expect(find.byKey(const Key('ds-captcha-code')), findsOneWidget);
      expect(find.byKey(const Key('ds-captcha-submit')), findsOneWidget);
      // 图片走 `method=download` 直链（URL 里的 task_id 不上屏）
      expect(t.downloads.any((u) => u.contains('method=download')), isTrue);
      expect(find.textContaining('SECRET-TASK-1'), findsNothing);
      expect(c, isNotNull);
    });

    testWidgets('提交验证码 → 发 set{task_id, code}（参数名逐字）', (tester) async {
      final (:t, :c) = await _pumpPage(
        tester,
        responses: const {
          'SYNO.DownloadStation2.Task.list': {'task': [], 'total': 0},
        },
        captchaIds: const ['SECRET-TASK-1'],
      );
      await tester.tap(find.byKey(const Key('ds-captcha-open')));
      await tester.pumpAndSettle();
      await tester.enterText(find.byKey(const Key('ds-captcha-code')), 'ab12');
      await tester.tap(find.byKey(const Key('ds-captcha-submit')));
      await tester.pumpAndSettle();
      final sent = _call(t, 'set');
      expect(sent['api'], 'SYNO.DownloadStation2.Captcha');
      expect(sent['task_id'], 'SECRET-TASK-1');
      expect(sent['code'], 'ab12');
      expect(sent.containsKey('captcha'), isFalse);
      expect(c, isNotNull);
    });

    testWidgets('提交被拒（2301）→ 明确显示"验证码不正确"，不静默', (tester) async {
      await _pumpPage(
        tester,
        responses: const {
          'SYNO.DownloadStation2.Task.list': {'task': [], 'total': 0},
        },
        captchaIds: const ['SECRET-TASK-1'],
        failures: const {'SYNO.DownloadStation2.Captcha.set': 2301},
      );
      await tester.tap(find.byKey(const Key('ds-captcha-open')));
      await tester.pumpAndSettle();
      await tester.enterText(find.byKey(const Key('ds-captcha-code')), 'zz');
      await tester.tap(find.byKey(const Key('ds-captcha-submit')));
      await tester.pumpAndSettle();
      expect(find.text('验证码不正确，请重新输入'), findsOneWidget);
      expect(find.textContaining('SECRET-TASK-1'), findsNothing);
    });

    // ---- DA81（r423 真机发现）：入口与验证码页**必须同判据**

    test('DA81 · captchaPendingIds：Captcha:list 优先，为空才回落任务状态 15', () {
      const tasks = [
        DownloadTaskDto(
          id: 'BY-STATUS',
          title: 'a.iso',
          type: 'bt',
          status: DsTaskStatus.captchaNeeded,
        ),
        DownloadTaskDto(id: 'BUSY', title: 'b.iso', type: 'http', status: 2),
      ];
      // ① 服务端给了就以它为准（哪怕任务状态还是 15）
      expect(captchaPendingIds(const ['FROM-LIST'], tasks), ['FROM-LIST']);
      // ② 服务端为空 ⇒ 回落到状态 15，且只挑 15 的那些
      expect(captchaPendingIds(const [], tasks), ['BY-STATUS']);
      // ③ 两边都空 ⇒ 空（不许凭空造一条）
      expect(captchaPendingIds(const [], const []), isEmpty);
    });

    testWidgets(
      'DA81 · 入口靠"任务状态 15"兜底出现时，验证码页必须也认它（不许说"没有任务"）',
      (tester) async {
        // 真机现场：队列还是空的时候 `Captcha:list` 已经取过一次并被缓存住
        // （= 这里 captchaIds 保持空），随后新建了一个等待验证码的任务。
        final (:t, :c) = await _pumpPage(
          tester,
          responses: const {
            'SYNO.DownloadStation2.Task.list': {
              'task': [
                {
                  'id': 'SECRET-TASK-1',
                  'title': 'a.iso',
                  'type': 'bt',
                  'status': DsTaskStatus.captchaNeeded,
                  'size': 10,
                },
              ],
              'total': 1,
            },
          },
          captchaIds: const [], // ★ 与真机同款：server 侧为空
        );
        // 入口出现（本来就是靠兜底判据）
        expect(find.byKey(const Key('ds-captcha-banner')), findsOneWidget);

        await tester.tap(find.byKey(const Key('ds-captcha-open')));
        await tester.pumpAndSettle();

        // ★ 修前：这里是 `ds-captcha-none`（"没有需要验证码的任务"）
        expect(find.byKey(const Key('ds-captcha-none')), findsNothing);
        expect(find.byKey(const Key('ds-captcha-code')), findsOneWidget);
        expect(find.byKey(const Key('ds-captcha-submit')), findsOneWidget);
        // 取图仍然走真直链（用的是同一个内部 id）
        expect(t.downloads.any((u) => u.contains('method=download')), isTrue);
        expect(t.downloads.any((u) => u.contains('task_id=SECRET-TASK-1')), isTrue);
        expect(find.textContaining('SECRET-TASK-1'), findsNothing);
        expect(c, isNotNull);
      },
    );

    testWidgets('DA81 · 两边都为空时仍走空态（不许为了"不空"编一条出来）', (tester) async {
      await _pumpPage(
        tester,
        responses: const {
          'SYNO.DownloadStation2.Task.list': {'task': [], 'total': 0},
        },
      );
      expect(find.byKey(const Key('ds-captcha-banner')), findsNothing);
      // 判据本身：两边都空 ⇒ 空表（页面据此走 `ds-captcha-none`）
      expect(captchaPendingIds(const [], const []), isEmpty);
    });
  });
}
