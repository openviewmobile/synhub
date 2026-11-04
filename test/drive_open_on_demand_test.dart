// ★★ ③Drive 第 246 轮：**D66「打开那一刻真去下载」** 的 Mock 验证。
//
// 用**本地 Mock Server**（规则 B）：登录拿 sid → `Files/download` 直链的
// api/version/method/files 全部走目录校验 → 二进制夹具回字节（246 轮给
// mock 补的 `handleRaw`）→ 断言缓存落盘、命中缓存不再发请求、超限拒绝。
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:synhub/src/data/drive_api.dart';
import 'package:synhub/src/dsm/webapi.dart';
import 'package:synhub/src/features/files/drive_open_on_demand.dart';

import '../tool/mock_dsm/mock_dsm_core.dart';
import 'support/chat_harness.dart' show FakeTransport;

/// 假传输：JSON 走 mock 的 `handle`，**二进制**走 mock 的 `handleRaw`
/// （`getBytes` 收到的就是下载直链 ⇒ 解析成 params 再喂给 mock，
/// 这样校验的仍然是真实的 api/version/method/参数）。
class _MockTransport extends FakeTransport {
  _MockTransport(this.backend);

  final MockDsmBackend backend;
  /// 当前会话（用例里直接改它来模拟"会话过期"）
  String sid = '';
  final List<String> seen = [];

  @override
  String authenticatedUrl(
    String path,
    Map<String, String> params, {
    String? sid,
  }) {
    final p = Map<String, String>.from(params);
    p['_sid'] = sid ?? this.sid;
    return Uri.parse(
      'https://mock.local/$path',
    ).replace(queryParameters: p).toString();
  }

  @override
  Future<String> postForm(
    String path,
    Map<String, dynamic> params, {
    String? module,
  }) async {
    final r = backend.handle(path, {...params, '_sid': sid});
    return jsonEncode(r.json);
  }

  @override
  Future<List<int>> getBytes(
    String url, {
    void Function(int received, int total)? onProgress,
    DownloadCancelToken? cancelToken,
    int? maxBytes,
    int? tailBytes,
    String? module,
  }) async {
    seen.add(url);
    final u = Uri.parse(url);
    final r = backend.handleRaw(u.path.replaceFirst('/', ''), u.queryParameters);
    if (!r.ok) throw StateError('HTTP ${r.errorCode}');
    return r.bytes;
  }
}

void main() {
  late MockDsmBackend backend;
  late _MockTransport transport;
  late Directory cache;
  late DriveOpenOnDemand svc;

  final payload = Uint8List.fromList(List<int>.generate(4096, (i) => i % 251));

  setUp(() {
    backend = MockDsmBackend(catalog: DsmCatalog.load());
    backend.rawFixture('SYNO.SynologyDrive.Files', 'download', (p) {
      // 只允许下"存在的文件"：mock 里就是一个白名单
      final files = '${p['files'] ?? ''}';
      if (!files.contains('id:file-ok') && !files.contains('id:file-big')) {
        return const MockRawResponse.error(408, note: '文件不存在（408）');
      }
      return MockRawResponse(payload, note: 'drive download bytes');
    });
    transport = _MockTransport(backend);
    transport.sid = backend.login(username: 'u', admin: false);
    cache = Directory.systemTemp.createTempSync('saf_ondemand_test');
    svc = DriveOpenOnDemand(
      api: DriveApi(DsmWebApi(transport)),
      fetchBytes: transport.getBytes,
      cacheDir: cache,
      policy: DriveOnDemandPolicy(maxBytes: 8 << 10, cacheLimitBytes: 64 << 10),
    );
  });

  tearDown(() {
    if (cache.existsSync()) cache.deleteSync(recursive: true);
  });

  test('★ 首次打开：走 Mock 的 Files/download 并落盘（原子写）', () async {
    final r = await svc.open(fileId: 'file-ok', name: '报表.xlsx');
    expect(r.status, DriveOnDemandStatus.downloaded);
    expect(r.bytes, payload.length);
    expect(File(r.path).readAsBytesSync(), payload);
    expect(File('${r.path}.part').existsSync(), isFalse);
    // 走的是真的下载直链（方法/参数在 URL 里）
    expect(transport.seen, hasLength(1));
    final u = Uri.parse(transport.seen.single);
    expect(u.queryParameters['api'], 'SYNO.SynologyDrive.Files');
    expect(u.queryParameters['method'], 'download');
    expect(u.queryParameters['version'], '2');
    expect(u.queryParameters['files'], '["id:file-ok"]');
    expect(u.queryParameters['force_download'], 'true');
    expect(u.queryParameters['is_preview'], 'false');
    expect(u.queryParameters['_sid'], transport.sid);
    // mock 也确实收到了这次二进制请求
    expect(
      backend.requests.map((q) => '${q.params['method']}'),
      contains('download'),
    );
  });

  test('★ 第二次打开：命中缓存，**零网络请求**', () async {
    final first = await svc.open(fileId: 'file-ok', name: 'a.bin');
    transport.seen.clear();
    final second = await svc.open(fileId: 'file-ok', name: 'a.bin');
    expect(second.status, DriveOnDemandStatus.cached);
    expect(second.path, first.path);
    expect(transport.seen, isEmpty);
  });

  test('★ 服务端回 HTTP 200 + DSM 错误信封 ⇒ failed，**不把错误 JSON 当文件存**', () async {
    // 247 轮真机同款：mock 用 200 承载 `{"success":false,"error":{"code":119}}`
    backend.rawFixture('SYNO.SynologyDrive.Files', 'download', (p) {
      return MockRawResponse(
        utf8.encode('{"success":false,"error":{"code":119}}'),
        contentType: 'application/json',
        note: '会话过期但 HTTP 200',
      );
    });
    final r = await svc.open(fileId: 'file-ok', name: 'x.bin');
    expect(r.status, DriveOnDemandStatus.failed);
    expect(r.reason, contains('119'));
    // 关键：缓存里**不能**出现这份"文件"（真机抓到过 38 字节的假副本）
    expect(cache.listSync(), isEmpty);
  });

  test('★ 内容恰好是 JSON 但 `success` 不是 false ⇒ 照常当文件（不误判）', () async {
    const body = '{"hello":"world","success":true}';
    backend.rawFixture('SYNO.SynologyDrive.Files', 'download', (p) {
      return MockRawResponse(utf8.encode(body), contentType: 'application/json');
    });
    final r = await svc.open(fileId: 'file-ok', name: 'conf.json');
    expect(r.status, DriveOnDemandStatus.downloaded);
    expect(File(r.path).readAsStringSync(), body);
  });

  test('★ 信封识别只认"整段是 JSON 对象且 success=false"', () {
    expect(dsmErrorCodeFromBytes(utf8.encode('{"success":false,"error":{"code":119}}')), 119);
    expect(dsmErrorCodeFromBytes(utf8.encode('  {"success":false,"error":{"code":407}}')), 407);
    expect(dsmErrorCodeFromBytes(utf8.encode('{"success":false}')), -1);
    expect(dsmErrorCodeFromBytes(utf8.encode('{"success":true,"data":{}}')), isNull);
    expect(dsmErrorCodeFromBytes(utf8.encode('hello')), isNull);
    expect(dsmErrorCodeFromBytes(const []), isNull);
    // 大文件（>64KB）一律不检查，避免为内容全量解析 JSON
    expect(dsmErrorCodeFromBytes(List<int>.filled(70 * 1024, 0x61)), isNull);
  });

  test('★ 已知超限 ⇒ tooLarge，且**不发请求**（不偷偷下大文件）', () async {
    final r = await svc.open(
      fileId: 'file-big',
      name: 'movie.mkv',
      sizeBytes: 200 << 20,
    );
    expect(r.status, DriveOnDemandStatus.tooLarge);
    expect(r.reason, contains('超过'));
    expect(transport.seen, isEmpty);
  });

  test('★ 服务端没有这个文件（Mock 408）⇒ failed 带原因，不留半个缓存', () async {
    final r = await svc.open(fileId: 'file-missing', name: 'x.bin');
    expect(r.status, DriveOnDemandStatus.failed);
    expect(r.reason, contains('408'));
    expect(cache.listSync(), isEmpty);
  });

  test('★ 未登录（sid 无效）⇒ Mock 回 119，客户端如实失败', () async {
    transport.sid = 'bogus';
    final r = await svc.open(fileId: 'file-ok', name: 'x.bin');
    expect(r.status, DriveOnDemandStatus.failed);
    expect(r.reason, contains('119'));
    expect(cache.listSync(), isEmpty);
  });

  test('★ 版本不对（客户端发 v7）⇒ Mock 目录校验拒绝（证明 mock 在管事）', () {
    final raw = backend.handleRaw('entry.cgi', {
      'api': 'SYNO.SynologyDrive.Files',
      'method': 'download',
      'version': '7',
      'files': '["id:file-ok"]',
      '_sid': transport.sid,
    });
    // v7 也有 download，所以这条应当通过 —— 用来证明"不是一律拒绝"
    expect(raw.ok, isTrue);
    // 而 v99 会撞版本区间
    final bad = backend.handleRaw('entry.cgi', {
      'api': 'SYNO.SynologyDrive.Files',
      'method': 'download',
      'version': '99',
      '_sid': transport.sid,
    });
    expect(bad.ok, isFalse);
    expect(bad.errorCode, 103);
    // 方法名写错同样 103
    final wrong = backend.handleRaw('entry.cgi', {
      'api': 'SYNO.SynologyDrive.Files',
      'method': 'download_typo',
      'version': '2',
      '_sid': transport.sid,
    });
    expect(wrong.errorCode, 103);
  });

  test('★ 下完才发现超限 ⇒ tooLarge 且**不落盘**（如实说明浪费）', () async {
    final small = DriveOpenOnDemand(
      api: DriveApi(DsmWebApi(transport)),
      fetchBytes: transport.getBytes,
      cacheDir: cache,
      // 上限 1KB < 4KB 载荷
      policy: const DriveOnDemandPolicy(maxBytes: 1024),
    );
    final r = await small.open(fileId: 'file-ok', name: 'b.bin');
    expect(r.status, DriveOnDemandStatus.tooLarge);
    expect(r.reason, contains('已丢弃'));
    expect(cache.listSync(), isEmpty);
  });

  test('★ 路径穿越的名字被消毒（`../` 不会跳目录）', () async {
    final r = await svc.open(fileId: 'file-ok', name: '../../evil.sh');
    expect(r.status, DriveOnDemandStatus.downloaded);
    expect(r.path, startsWith(cache.path));
    expect(r.path.contains('..'), isFalse);
    expect(r.path.contains('/evil'), isFalse);
  });

  test('★ 缓存清理：超软上限删最旧的，且不动当前文件', () async {
    // 先塞两个旧文件
    for (final n in ['old1.bin', 'old2.bin']) {
      final f = File('${cache.path}/$n')
        ..writeAsBytesSync(List<int>.filled(40 << 10, 7));
      f.setLastModifiedSync(DateTime(2020));
    }
    expect(await svc.cacheBytes(), greaterThan(64 << 10));
    final r = await svc.open(fileId: 'file-ok', name: 'new.bin');
    expect(r.status, DriveOnDemandStatus.downloaded);
    expect(File(r.path).existsSync(), isTrue);
    // 至少删掉一个旧的
    expect(File('${cache.path}/old1.bin').existsSync(), isFalse);
  });

  test('★ 关闭开关 ⇒ failed（明确拒绝，不是"静默不下"）', () async {
    final off = DriveOpenOnDemand(
      api: DriveApi(DsmWebApi(transport)),
      fetchBytes: transport.getBytes,
      cacheDir: cache,
      policy: DriveOnDemandPolicy.off,
    );
    final r = await off.open(fileId: 'file-ok', name: 'c.bin');
    expect(r.status, DriveOnDemandStatus.failed);
    expect(r.reason, contains('未开启'));
    expect(transport.seen, isEmpty);
  });

  test('★ 缓存文件名约定与 Dart/Kotlin 共用（`<fileId>_<消毒名>`）', () {
    expect(
      safOnDemandFileName(fileId: 'f1', name: 'a/b c.txt'),
      'f1_a_b c.txt',
    );
    expect(safOnDemandFileName(fileId: 'f2', name: ''), 'f2_f2');
    expect(kSafOnDemandDirName, 'saf_ondemand');
  });

  test('★ UI 预览判断：已缓存/超限/未知大小三种情形', () {
    expect(safOnDemandNeedsDownload(cached: true, sizeBytes: 1 << 30), isFalse);
    expect(safOnDemandNeedsDownload(cached: false, sizeBytes: 1 << 30), isFalse);
    expect(safOnDemandNeedsDownload(cached: false, sizeBytes: 1024), isTrue);
    expect(safOnDemandNeedsDownload(cached: false, sizeBytes: null), isTrue);
    expect(
      safOnDemandNeedsDownload(
        cached: false,
        sizeBytes: 1024,
        policy: DriveOnDemandPolicy.off,
      ),
      isFalse,
    );
  });
}
