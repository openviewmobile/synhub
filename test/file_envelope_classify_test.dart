// R6-4a 收口：`HTTP 200 + JSON 错误信封` 被 `DsmTransport._bytesOf` 还原成
// `DsmApiException(error.code)` 之后，"哪一类提示 / 要不要隐藏模块"完全由**既有
// 统一错误分类**决定（`classifyErrorCode` / `hidesModule` / `describeFileError`）。
//
// 这条用例把"信封 → 分类"的映射钉死，防止以后有人把 119 误判成隐藏、或把
// 105/102 混为一谈（任务书 R6-4 的核心对照：119 只提示、绝不隐藏）。
import 'package:flutter_test/flutter_test.dart';

import 'package:synhub/src/core/services/service_registry.dart';
import 'package:synhub/src/data/local/file_store.dart'
    show describeFileError;
import 'package:synhub/src/dsm/webapi.dart';

void main() {
  group('错误信封 code → 统一分类（classifyErrorCode / hidesModule）', () {
    test('119 / 106 → sessionExpired：提示 + 重试，**绝不隐藏**', () {
      for (final code in [
        DsmErrorCode.sidNotFound,
        DsmErrorCode.sessionTimeout,
      ]) {
        expect(classifyErrorCode(code), AvailabilityState.sessionExpired);
        expect(
          hidesModule(AvailabilityState.sessionExpired),
          isFalse,
          reason: '$code 会话失效不允许隐藏模块（R6-4）',
        );
      }
      expect(
        describeFileError(DsmApiException(DsmErrorCode.sidNotFound)),
        contains('登录已过期'),
      );
      expect(
        describeFileError(DsmApiException(DsmErrorCode.sessionTimeout)),
        contains('登录已过期'),
      );
    });

    test('105 / 160 → unauthorized：无权限（可隐藏）', () {
      for (final code in [
        DsmErrorCode.noPermission,
        DsmErrorCode.noAppPrivilege,
      ]) {
        expect(classifyErrorCode(code), AvailabilityState.unauthorized);
        expect(hidesModule(AvailabilityState.unauthorized), isTrue);
      }
      expect(
        describeFileError(DsmApiException(DsmErrorCode.noPermission)),
        contains('没有权限'),
      );
    });

    test('102 → absent：未安装（可隐藏），文案是"没有开启文件服务"', () {
      expect(
        classifyErrorCode(DsmErrorCode.apiNotFound),
        AvailabilityState.absent,
      );
      expect(hidesModule(AvailabilityState.absent), isTrue);
      expect(
        describeFileError(DsmApiException(DsmErrorCode.apiNotFound)),
        contains('文件服务'),
      );
    });

    test('其它码 → unknown（不动状态）但文案明确、非空', () {
      expect(classifyErrorCode(500), AvailabilityState.unknown);
      expect(hidesModule(AvailabilityState.unknown), isFalse);
      expect(
        describeFileError(DsmApiException(500)).isNotEmpty,
        isTrue,
        reason: '其它码也要给明确错误，不能空着',
      );
    });
  });
}
