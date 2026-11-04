// Mock NAS 测试脚手架 —— 把 `tool/mock_nas/` 的**有状态后端**接进 `flutter test`。
//
// 关键点：测试里跑的是**真实客户端代码**（`DsmWebApi` + 各模块 Api 类），
// 走 **loopback HTTP**（`DirectTransport.url`）打到进程内的 mock server。
// 因此这是**离线端到端**证据：真的发了 HTTP 请求、真的解析了响应、真的改了
// mock 的内存状态 —— 但**没有也不可能**碰任何真实 NAS（见 §5.1）。
//
// 用法：
// ```dart
// final h = await startMockNasHarness(declaredApis: {'file', 'note'});
// addTearDown(h.dispose);
// final note = NoteStationApi(h.api);
// ...
// ```
//
// `h.store` 是 mock 的内存后端，可直接断言"写操作之后状态对不对"；
// `h.api` 是 App 侧真实客户端；`h.url` 是 mock 的 baseUrl。

import 'package:synhub/src/dsm/webapi.dart';

import '../../tool/mock_nas/mock_nas_server.dart';
import '../../tool/mock_nas/mock_nas_store.dart';

/// 一次测试用的 mock 实例 + 已登录的 App 客户端。
class MockNasHarness {
  MockNasHarness._(this.instance, this.api);

  final MockNasInstance instance;
  final DsmWebApi api;

  /// mock 的内存后端（断言"操作后状态"用）。
  MockNasStore get store => instance.store;

  /// mock 的 baseUrl（如 `http://127.0.0.1:54321`）。
  String get url => instance.url;

  int get port => instance.port;

  Future<void> dispose() async {
    await api.transport.close();
    await instance.close();
  }
}

/// 起一个进程内 mock NAS，并让**真实客户端**登录成功。
///
/// [declaredApis] 决定 `SYNO.API.Info` 声明哪些服务（`file` / `note` /
/// `download` / `photo` / `chat` / …）；核心 API 恒在。
Future<MockNasHarness> startMockNasHarness({
  Set<String> declaredApis = const {'file', 'note', 'download', 'photo'},
  bool rangeEnabled = true,
  int downloadBytes = 4096,
  bool verbose = false,
}) async {
  final instance = await startMockNas(
    declaredApis: declaredApis,
    rangeEnabled: rangeEnabled,
    downloadBytes: downloadBytes,
    verbose: verbose,
  );
  final api = DsmWebApi(DirectTransport.url(instance.url));
  await api.discover();
  await api.login(account: 'mock', password: 'mock', session: 'FileStation');
  return MockNasHarness._(instance, api);
}
