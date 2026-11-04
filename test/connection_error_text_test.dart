// 真机缺陷回归（2026-09-22）：**连接页**（用户看到的第一屏）不得把
// 三方库/内部异常原文当用户文案。
//
// ## 缺陷原文（真机截屏，QuickConnect 查询超时后出现在 `LINK LOG`）
// ```
// QuickConnect 查询失败，稍后重试：
//   DioException [connection timeout]: The request connection took longer …
// DioException [connection timeout]: The request connection took longer than
//   0:00:30.000000 and it was aborted. To get rid … exception, try …
// ```
//
// ## 三个问题（都是从用户角度不可接受）
// 1. 暴露 `DioException` 这个三方库**内部类型名**；
// 2. 暴露 `0:00:30.000000` 这种**内部超时字面量**；
// 3. 把**给开发者看的建议**（"To get rid of this exception, try…"）甩给用户。
//
// ## 根因
// `session_controller.dart` 里 4 处 `steps.add(ConnectStep('$e', …))` /
// `error: '$e'` —— 任何异常被整体 `toString()` 进界面。
//
// ## 本用例锁住的不变量
// 1. 输出**永远不含** Dart / dio 的类型名（`Exception` / `DioException` / `Error`）；
// 2. **永远不含**内部时长字面量（`0:00:`、`.000000`）；
// 3. **永远不含**三方库的开发者提示（`To get rid`、`aborted`、`uri=`）；
// 4. 长度可控（`LINK LOG` 每行放得下，不超过 60 字）；
// 5. DSM 错误码**保留**（用户报障要靠它）。

import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/widgets.dart' show Locale;
import 'package:flutter_test/flutter_test.dart';
import 'package:synhub/src/core/i18n/l10n.dart';
import 'package:synhub/src/dsm/webapi.dart';
import 'package:synhub/src/features/servers/connection_error_text.dart';

/// 这些片段**任何一个**出现在用户文案里都是缺陷。
const _forbidden = <String>[
  'Exception',
  'Error',
  'DioException',
  '0:00:',
  '.000000',
  'To get rid',
  'aborted',
  'uri=',
  'package:',
  'StackTrace',
  '#0',
];

void _assertUserLanguage(String text, {required String label}) {
  for (final bad in _forbidden) {
    expect(
      text.contains(bad),
      isFalse,
      reason: '$label 的用户文案不得包含「$bad」；实际 = $text',
    );
  }
  expect(
    text.length,
    lessThanOrEqualTo(60),
    reason: '$label 的用户文案要能放进 LINK LOG；实际(${text.length}) = $text',
  );
  expect(text.trim(), isNotEmpty, reason: '$label 不得给空文案');
}

/// 造一个与真机**完全同型**的 dio 超时异常。
DioException _timeoutLike() {
  final options = RequestOptions(path: 'https://demo_admin-qq.quickconnect.cn');
  return DioException(
    requestOptions: options,
    type: DioExceptionType.connectionTimeout,
    // 真机那条 message 逐字长这样（含内部时长字面量与开发者提示）。
    message:
        'The request connection took longer than 0:00:30.000000 and it was '
        'aborted. To get rid of this exception, try reducing the timeout.',
  );
}

void main() {
  group('连接页用户语言映射：绝不泄露内部细节', () {
    test('★ 真机缺陷原文：dio 连接超时 → 只说"超时 + 检查网络"', () {
      final e = _timeoutLike();
      final text = connectionUserFacingError(e);
      _assertUserLanguage(text, label: 'dio 超时');
      expect(text, contains('超时'));
      expect(text, contains('网络'));

      // 反向确认：这个异常的 `toString()` **确实**含有那些内部细节
      //（证明用例禁止的片段是真的会被泄露的，不是空断言）。
      final raw = e.toString();
      expect(raw.contains('DioException'), isTrue);
      expect(raw.contains('0:00:30'), isTrue);
      expect(raw.contains('To get rid'), isTrue);
    });

    test('dio 各类型都有用户语言，且互不相同', () {
      final options = RequestOptions(path: 'https://x');
      final seen = <String>{};
      for (final type in <DioExceptionType>[
        DioExceptionType.connectionTimeout,
        DioExceptionType.sendTimeout,
        DioExceptionType.receiveTimeout,
        DioExceptionType.transformTimeout,
        DioExceptionType.connectionError,
        DioExceptionType.badCertificate,
        DioExceptionType.cancel,
        DioExceptionType.unknown,
      ]) {
        final e = DioException(requestOptions: options, type: type);
        final text = connectionUserFacingError(e);
        _assertUserLanguage(text, label: 'dio ${type.name}');
        seen.add(text);
      }
      // unknown 与 connectionError 都是"连不上"，允许同文案；
      // 但"超时 / 证书 / 取消"必须各说各的。
      expect(seen.length, greaterThanOrEqualTo(3));
    });

    test('badResponse 带 HTTP 码', () {
      final e = DioException(
        requestOptions: RequestOptions(path: 'https://x'),
        type: DioExceptionType.badResponse,
        response: Response<void>(
          requestOptions: RequestOptions(path: 'https://x'),
          statusCode: 502,
        ),
      );
      final text = connectionUserFacingError(e);
      _assertUserLanguage(text, label: 'HTTP 502');
      expect(text, contains('502'));
    });

    test('本仓 DsmTransportException：不给内部 message，给 HTTP 码或通用话', () {
      final withCode = DsmTransportException('socket hang up', statusCode: 503);
      _assertUserLanguage(
        connectionUserFacingError(withCode),
        label: 'HTTP 503',
      );
      expect(connectionUserFacingError(withCode), contains('503'));

      final noCode = DsmTransportException('socket hang up');
      final t = connectionUserFacingError(noCode);
      _assertUserLanguage(t, label: '无码传输异常');
      // 不得把 'socket hang up' 这种英文内部话透出去
      expect(t.contains('socket hang up'), isFalse);
    });

    test('★ DSM 错误码**保留**（用户报障要靠它）', () {
      final text = connectionUserFacingError(
        DsmApiException(402, method: 'SYNO.API.Auth', raw: const {}),
      );
      _assertUserLanguage(text, label: 'DSM 402');
      expect(text, contains('402'));
    });

    test('系统网络异常走用户语言', () {
      for (final e in <Object>[
        const SocketException(
          'Failed host lookup: demo_admin-qq.quickconnect.cn',
        ),
        const HandshakeException('CERTIFICATE_VERIFY_FAILED'),
        const HttpException(
          'Connection closed before full header was received',
        ),
      ]) {
        _assertUserLanguage(
          connectionUserFacingError(e),
          label: e.runtimeType.toString(),
        );
      }
    });

    test('★ 完全不认识的异常也绝不 toString 进界面', () {
      final e = StateError(
        'DioException [connection timeout]: The request connection took longer '
        'than 0:00:30.000000 and it was aborted. To get rid of this exception…',
      );
      final text = connectionUserFacingError(e);
      _assertUserLanguage(text, label: '未知异常兜底');
      expect(text, isNot(contains('StateError')));
    });

    // ★ r677（`DA309`）：iOS 模拟器把界面语言切成 `ja-JP` 时，整屏是英文，但
    //   "未知异常"这一支蹦出**中文** —— `DUMP` 实证：
    //   `连接失败：请检查服务器地址与网络后重试`。根因是这条兜底文案是**硬编码中文**，
    //   绕过了 `dataText`。判据：英文界面下这个函数**一个汉字都不许有**。
    test('DA309：英文界面下未知异常的兜底不许出现中文', () {
      addTearDown(() => setCurrentText(lookupAppTextSafe(const Locale('zh'))));
      setCurrentText(lookupAppTextSafe(const Locale('en')));
      for (final e in <Object>[
        StateError('boom'),
        Exception('whatever'),
        Object(),
      ]) {
        final text = connectionUserFacingError(e);
        expect(
          RegExp(r'[\u4e00-\u9fff]').hasMatch(text),
          isFalse,
          reason: '英文界面下兜底文案里出现了汉字：$text',
        );
        _assertUserLanguage(text, label: 'en 兜底 $e');
      }
      // 反向保证：中文界面下仍是中文（不把这条修成"一律英文"）
      setCurrentText(lookupAppTextSafe(const Locale('zh')));
      expect(
        RegExp(r'[\u4e00-\u9fff]').hasMatch(connectionUserFacingError(StateError('x'))),
        isTrue,
      );
    });

    test('空异常 / 字符串 / 数字也不崩，且仍是用户语言', () {
      for (final e in <Object>[Exception(''), 'plain string', 42, Object()]) {
        _assertUserLanguage(connectionUserFacingError(e), label: '$e');
      }
    });
  });
}
