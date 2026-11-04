// SYNO.Entry.Request / request —— DSM 的批量（compound）调用
//
// 逆向依据（APK）：
//   data/remote/api/EntryRequest.java   API="SYNO.Entry.Request" METHOD="request" VERSION=2
//                                       ARG "compound" / "mode", VALUE "parallel"
//   data/AccountManager.java#createParallelRequestMap:
//       map.put("compound", compoundJsonable.toString());  // 一个 **JSON 数组字符串**
//       map.put("mode", "parallel");
//   data/remote/api/CompoundJsonable.java#toJsonArray → 每项 {api, method, version, ...params}
//
// 实测（NAS nas.example.com，见 test/fixtures/compound_users.json）：
//   响应 data = {"has_fail": false, "result": [ {api, method, version, success, data} ... ]}
//   注意每段自带 success —— 整体请求成功不代表每一段都成功。
library;

import 'dart:convert';

import '../../core/i18n/data_text.dart';
import '../../dsm/webapi.dart';

/// compound 里的一个子请求。
class ApiRequest {
  const ApiRequest(
    this.api,
    this.method, {
    this.version = 1,
    this.params = const {},
  });

  final String api;
  final String method;
  final int version;
  final Map<String, Object?> params;

  Map<String, Object?> toJson() => {
    'api': api,
    'method': method,
    'version': version,
    ...params,
  };

  @override
  String toString() => '$api.$method v$version $params';
}

/// compound 的一段响应。
class CompoundResult {
  const CompoundResult({
    required this.api,
    required this.method,
    required this.version,
    required this.success,
    this.data,
    this.errorCode,
  });

  final String api;
  final String method;
  final int version;
  final bool success;

  /// 该段自己的 `data`
  final Map<String, dynamic>? data;

  /// 该段自己的 `error.code`（只在 success=false 时有意义）
  final int? errorCode;

  factory CompoundResult.fromJson(Map<String, dynamic> json) {
    final err = json['error'];
    return CompoundResult(
      api: (json['api'] as String?) ?? '',
      method: (json['method'] as String?) ?? '',
      version: _int(json['version']),
      success: json['success'] == true,
      data: json['data'] is Map
          ? Map<String, dynamic>.from(json['data'] as Map)
          : null,
      errorCode: err is Map ? _intOrNull(err['code']) : null,
    );
  }

  /// 该段失败时抛出，便于调用方统一处理
  void ensureOk() {
    if (!success) {
      throw DsmApiException(
        errorCode ?? DsmErrorCode.unknown,
        method: '$api.$method',
      );
    }
  }

  @override
  String toString() => 'CompoundResult($api.$method, success=$success)';
}

extension DsmCompound on DsmWebApi {
  /// 并发执行一组请求。返回顺序与 [requests] 一致。
  ///
  /// `mode=parallel` 时服务端并发执行；单次 HTTP 往返即可完成 N 个调用。
  Future<List<CompoundResult>> compound(
    List<ApiRequest> requests, {
    int preferredVersion = 2,
  }) async {
    if (requests.isEmpty) return const [];

    final data = await call(
      'SYNO.Entry.Request',
      'request',
      preferredVersion: preferredVersion,
      params: {
        'compound': jsonEncode(requests.map((r) => r.toJson()).toList()),
        'mode': 'parallel',
      },
    );

    final raw = data['result'];
    if (raw is! List) {
      throw DsmTransportException(
        dataText(
          'apiCompoundMissingResult',
          'SYNO.Entry.Request: 响应缺少 result 数组',
        ),
      );
    }
    return raw
        .whereType<Map>()
        .map((e) => CompoundResult.fromJson(Map<String, dynamic>.from(e)))
        .toList();
  }
}

int _int(Object? v) => _intOrNull(v) ?? 0;

int? _intOrNull(Object? v) {
  if (v is int) return v;
  if (v is num) return v.toInt();
  if (v is String) return int.tryParse(v);
  return null;
}
