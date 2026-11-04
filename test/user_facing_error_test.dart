// 全仓唯一「异常 → 用户文案」出口 `userFacingError` 的回归锁。
//
// 背景与不变量见 `lib/src/core/user_facing_error.dart` 顶部注释。本用例把
// **同一个真机缺陷**（连接页 LINK LOG 泄露 `DioException` / 内部时长 /
// 开发者提示）锁在**通用**出口上，避免任何 feature 再各自实现一遍时漏掉。
//
// 写法沿用 `test/connection_error_text_test.dart`：
//  * 禁止片段表覆盖所有已知泄露形态；
//  * ★ 反向确认：被测异常的 `toString()` **确实含**那些片段（证明不是空断言）；
//  * 长度上限：能放进 SnackBar / 一行；
//  * DSM 码保留：用户报障靠它；
//  * 未知异常兜底：绝不透类型名；
//  * 空/字符串/数字/`Object()` 不崩。

import 'dart:async';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:synhub/src/core/user_facing_error.dart';
import 'package:synhub/l10n/gen/app_localizations_en.dart';
import 'package:synhub/l10n/gen/app_localizations_zh.dart';
import 'package:synhub/src/core/i18n/l10n.dart';
import 'package:synhub/src/dsm/webapi.dart';

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
    reason: '$label 的用户文案要能放进 SnackBar / 一行；实际(${text.length}) = $text',
  );
  expect(text.trim(), isNotEmpty, reason: '$label 不得给空文案');
}

/// 造一个与真机**完全同型**的 dio 超时异常（含全部三种泄露）。
DioException _timeoutLike() {
  final options = RequestOptions(path: 'https://demo_admin-qq.quickconnect.cn');
  return DioException(
    requestOptions: options,
    type: DioExceptionType.connectionTimeout,
    message:
        'The request connection took longer than 0:00:30.000000 and it was '
        'aborted. To get rid of this exception, try reducing the timeout.',
  );
}

void main() {
  group('userFacingError：绝不泄露内部细节', () {
    test('★ 真机缺陷原文：dio 连接超时 → 只说"超时 + 检查网络"', () {
      final e = _timeoutLike();
      final text = userFacingError(e);
      _assertUserLanguage(text, label: 'dio 超时');
      expect(text, contains('超时'));
      expect(text, contains('网络'));

      // 反向确认：这个异常的 `toString()` **确实**含有那些内部细节
      //（证明用例禁止的片段是真的会被泄露的，不是空断言）。
      final raw = e.toString();
      expect(raw.contains('DioException'), isTrue);
      expect(raw.contains('0:00:30'), isTrue);
      expect(raw.contains('To get rid'), isTrue);
      expect(raw.contains('aborted'), isTrue);
    });

    test('dio 各类型都有用户语言，且覆盖 5.x 的 transformTimeout', () {
      final options = RequestOptions(path: 'https://x');
      final seen = <String>{};
      for (final type in DioExceptionType.values) {
        final e = DioException(requestOptions: options, type: type);
        final text = userFacingError(e);
        _assertUserLanguage(text, label: 'dio ${type.name}');
        seen.add(text);
      }
      // 超时 / 证书 / 取消 / 连不上 必须各说各的。
      expect(seen.length, greaterThanOrEqualTo(3));
      // transformTimeout 不能掉进兜底后丢掉"超时"关键词。
      expect(
        userFacingError(
          DioException(
            requestOptions: options,
            type: DioExceptionType.transformTimeout,
          ),
        ),
        contains('超时'),
      );
    });

    test('badResponse 带 HTTP 码（可报障）', () {
      final e = DioException(
        requestOptions: RequestOptions(path: 'https://x'),
        type: DioExceptionType.badResponse,
        response: Response<void>(
          requestOptions: RequestOptions(path: 'https://x'),
          statusCode: 502,
        ),
      );
      final text = userFacingError(e);
      _assertUserLanguage(text, label: 'HTTP 502');
      expect(text, contains('502'));
    });

    test('本仓 DsmTransportException：给 HTTP 码或通用话，不透内部 message', () {
      final withCode = DsmTransportException('socket hang up', statusCode: 503);
      _assertUserLanguage(userFacingError(withCode), label: 'HTTP 503');
      expect(userFacingError(withCode), contains('503'));

      final noCode = DsmTransportException('socket hang up');
      final t = userFacingError(noCode);
      _assertUserLanguage(t, label: '无码传输异常');
      expect(t.contains('socket hang up'), isFalse);
    });

    test('★ DSM 错误码**保留**（用户报障要靠它），且不带报文', () {
      final known = userFacingError(
        DsmApiException(105, method: 'SYNO.API.Auth', raw: const {}),
      );
      _assertUserLanguage(known, label: 'DSM 105');
      expect(known, contains('105'));

      final unknown = userFacingError(
        DsmApiException(402, method: 'SYNO.API.Auth', raw: const {}),
      );
      _assertUserLanguage(unknown, label: 'DSM 402');
      expect(unknown, contains('402'));

      // 原始报文绝不透出（`raw` 里的东西只在诊断日志里）。
      final raw = userFacingError(
        DsmApiException(
          102,
          method: 'Office.x',
          raw: <String, dynamic>{'message': 'raw body text'},
        ),
      );
      _assertUserLanguage(raw, label: 'DSM 102');
      expect(raw.contains('raw body text'), isFalse);
    });

    test('系统 / dart 核心异常都走用户语言', () {
      final cases = <Object>[
        const SocketException(
          'Failed host lookup: demo_admin-qq.quickconnect.cn',
        ),
        const HandshakeException('CERTIFICATE_VERIFY_FAILED'),
        const HttpException(
          'Connection closed before full header was received',
        ),
        const FormatException('Unexpected character in JSON at 0:00:30.000000'),
        const FileSystemException(
          'Cannot open file',
          '/tmp/x',
          OSError('denied'),
        ),
        TimeoutException('took 0:00:30.000000', const Duration(seconds: 30)),
      ];
      for (final e in cases) {
        _assertUserLanguage(
          userFacingError(e),
          label: e.runtimeType.toString(),
        );
      }
    });

    test('★ 完全不认识的异常也绝不 toString 进界面', () {
      final e = StateError(
        'DioException [connection timeout]: The request connection took longer '
        'than 0:00:30.000000 and it was aborted. To get rid of this exception…',
      );
      final text = userFacingError(e);
      _assertUserLanguage(text, label: '未知异常兜底');
      expect(text, isNot(contains('StateError')));
      // 反向确认：原文确实脏。
      expect(e.toString().contains('DioException'), isTrue);
      expect(e.toString().contains('0:00:30.000000'), isTrue);
    });

    test('兜底文案可定制，但仍是用户语言', () {
      final text = userFacingError(Object(), fallback: '连接失败：请检查服务器地址与网络后重试');
      _assertUserLanguage(text, label: '自定义兜底');
      expect(text, contains('连接失败'));
    });

    test('空异常 / 字符串 / 数字 / Object() 不崩，且仍是用户语言', () {
      for (final e in <Object>[Exception(''), 'plain string', 42, Object()]) {
        _assertUserLanguage(userFacingError(e), label: '$e');
      }
    });
  });


  // 第 281 轮新增：**英文模式下不许出现中日韩字符**。
  //
  // 真机缺陷（第 280 轮 macOS 像素，逐字）：
  //   `Realtime channel not ready: 操作未能完成`
  // 根因：`chatErrRealtimeNotReady('{error}')` 这个 **en 模板**拼进了
  // `userFacingError(e)` 的**硬编码中文兜底**。本出口曾是整文件 i18n 豁免，
  // 所以守卫咬不到 ⇒ 现在这批用例直接盯"英文字符串里有没有 CJK"。
  group('英文模式：用户文案里不许有中文（中英混排回归锁）', () {
    setUp(() => setCurrentText(AppTextEn()));
    tearDown(() => setCurrentText(AppTextZh()));

    final cjk = RegExp(r'[\u4e00-\u9fff]');

    test('兜底 + 已知异常类型都不含 CJK', () {
      final samples = <Object>[
        StateError('boom'),
        ArgumentError('bad'),
        Object(),
        'plain string',
        42,
        const SocketException('no route'),
        DsmApiException(402, method: 'SYNO.Core.System'),
      ];
      for (final e in samples) {
        final text = userFacingError(e);
        expect(cjk.hasMatch(text), isFalse, reason: '英文模式出现中文：$text');
        expect(text.trim(), isNotEmpty);
      }
    });

    test('★ 真机同形状：Chat 实时通道失败那条不再中英混排', () {
      final msg = currentText().chatErrRealtimeNotReady(userFacingError(StateError('x')));
      expect(cjk.hasMatch(msg), isFalse, reason: '中英混排回归：$msg');
      expect(msg.toLowerCase(), contains('realtime'));
    });

    test('中文模式仍然是中文（证明上面不是把文案删了）', () {
      setCurrentText(AppTextZh());
      final msg = currentText().chatErrRealtimeNotReady(userFacingError(StateError('x')));
      expect(cjk.hasMatch(msg), isTrue, reason: '中文模式不该退化成空/英文：$msg');
    });
  });

  group('logErrorForDiagnostics：原文只进日志', () {
    test('不抛异常，且把原文与堆栈打到日志', () {
      expect(
        () => logErrorForDiagnostics('test', Exception('boom')),
        returnsNormally,
      );
      expect(
        () => logErrorForDiagnostics(
          'test',
          Exception('boom'),
          StackTrace.current,
        ),
        returnsNormally,
      );
    });
  });
}
