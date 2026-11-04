// 离线用例用的 **进程内 Mock transport**：把 `WebApiTransport` 直接接到
// `MockDsmBackend`，不碰 socket。
//
// 为什么不走真 HTTP：`flutter_test` 的 binding 会把 `HttpClient` 换成一个
// "一律 400"的替身，真 socket 在 widget 用例里不可靠；而进程内调用是
// **确定性**的，还能直接看请求日志。需要真 HTTP 的场景（真机指向电脑、
// curl、端到端验传输层）用 `mock_dsm_server.dart` 那台。
import 'dart:convert';

import 'package:synhub/src/dsm/webapi.dart';

import '../../tool/mock_dsm/mock_dsm_core.dart';

/// 把请求交给 [backend] 的 `WebApiTransport`。
class MockDsmTransport extends WebApiTransport {
  MockDsmTransport(this.backend) {
    synoToken = 'mock-token';
  }

  final MockDsmBackend backend;

  /// 最近一次响应（用例要断言错误码时用）。
  MockDsmResponse? last;

  /// 打开后：响应回放为"真 HTTP 200 + JSON 字符串"，与线上一致。
  @override
  String get baseUrl => 'http://mock-dsm.invalid/';

  @override
  String get describeKind => 'mock-dsm(${backend.catalog.apiCount} APIs)';

  @override
  Future<String> postForm(
    String path,
    Map<String, dynamic> params, {
    String? module,
  }) async {
    // `_sid` 在真实链路由 DsmWebApi 注入；这里也走它的会话表，
    // 所以用例必须先 login（或让 backend 预置一个会话）。
    final r = backend.handle(path, params);
    last = r;
    return jsonEncode(r.json);
  }

  /// multipart 上传：把**查询串 + 表单字段**合起来交给后端（文件字节不参与校验）。
  ///
  /// 真实链路里元数据（`api`/`method`/`version`/`path`…）拼在**查询串**上、
  /// 业务字段在 body 里（见 `WebApiTransport.postMultipart` 的契约），
  /// 这里合并不冲突：两边同名的键以表单字段为准。
  @override
  Future<String> postMultipart(
    String path, {
    required Map<String, dynamic> query,
    required Map<String, String> fields,
    String? fileField,
    String? filePath,
    String? fileName,
    String? mimeType,
    String? module,
    List<MultipartUploadFile>? files,
    void Function(int sent, int total)? onProgress,
    Map<String, String>? headers,
  }) async {
    final params = <String, dynamic>{...query, ...fields};
    // 让"最后一次上传"可被断言。
    // ★ `headers` 必须一起记下来：Drive 的分片续传把 `X-TMP-FILE` /
    // `X-TYPE-NAME` / `X-FILE-CHUNK-END` 放在**真 HTTP 头**上
    // （`ApiSynoDriveFiles.java:52-54,459-467`），不像元数据那样在查询串里。
    // 不记它就**无法断言**续传请求到底对不对 —— 而"发错头"在真机上
    // 只会表现为普通上传成功（静默走错分支），不会有任何报错。
    lastUpload = (
      path: path,
      query: Map<String, dynamic>.from(query),
      fields: Map<String, String>.from(fields),
      fileName: fileName,
      headers: headers == null ? const {} : Map<String, String>.from(headers),
    );
    final r = backend.handle(path, params);
    last = r;
    return jsonEncode(r.json);
  }

  /// 最近一次 multipart 上传的入参（用例断言"到底发了哪个 api/method/version"）。
  ({
    String path,
    Map<String, dynamic> query,
    Map<String, String> fields,
    String? fileName,
    /// ★ 真 HTTP 头（含 Drive 续传的 `X-TMP-FILE` 等）
    Map<String, String> headers,
  })?
  lastUpload;

  @override
  Future<String> describe({String? module}) => postForm('query.cgi', {
    'api': 'SYNO.API.Info',
    'method': 'Query',
    'version': 1,
    'query': 'all',
  });

  @override
  String authenticatedUrl(
    String path,
    Map<String, String> params, {
    String? sid,
  }) {
    final q = <String, String>{...params, if (sid != null) '_sid': sid};
    return Uri.parse('$baseUrl$path').replace(queryParameters: q).toString();
  }

  @override
  Future<void> close() async {}
}
