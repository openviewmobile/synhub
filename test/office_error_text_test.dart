// 真机缺陷回归（2026-09-22）：Office 错误横幅**不得**把内部细节甩给用户。
//
// ## 缺陷原文（真机截图，打开 `Dynamic.oslides` 时页面顶部红条）
// ```
// 协作会话未建立：OfficeCollabPermissionDeniedException: Permission denied:
// {"message":"Permission denied"} (the handshake objectId must be the Office
// object_id and linkId the Drive permanent_link)
// ```
//
// ## 根因
// 三个 Office 页（doc / sheet / slides）的 `_describeError` 兜底都是 `return '$error'`
// ⇒ 任何未显式识别的异常都被整体 `toString()` 进界面。
//
// ## 本用例锁住的不变量
// 1. `officeUserFacingError` 的输出**永远不含** Dart 类型名（`Exception` 等）；
// 2. **永远不含** JSON 报文片段（`{`、`message:`、`objectId`）；
// 3. **永远不含**实现者注释（`handshake`、`linkId`）；
// 4. 长度可控（横幅放得下，不超过 40 字）。

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:synhub/src/data/office_collab/office_collab_client.dart';
import 'package:synhub/src/dsm/webapi.dart' show DsmApiException;
import 'package:synhub/src/features/office/office_error_text.dart';

/// 这些片段**任何一个**出现在用户文案里都是缺陷。
const _forbidden = <String>[
  'Exception', // Dart 类型名
  'Error', // Dart 类型名
  'objectId',
  'linkId',
  'handshake',
  'permanent_link',
  '{', // JSON 报文
  '}',
  'message',
  'null',
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
    lessThanOrEqualTo(40),
    reason: '$label 的用户文案要能放进横幅；实际(${text.length}) = $text',
  );
  expect(text.trim(), isNotEmpty, reason: '$label 不得给空文案');
}

void main() {
  group('Office 用户语言映射：绝不泄露内部细节', () {
    test('★ 真机缺陷原文：权限拒绝 → 只说"没有编辑权限"', () {
      // 与真机截到的完全同型：detail 里带原始 JSON。
      final e = OfficeCollabPermissionDeniedException(
        '{"message":"Permission denied"}',
      );
      final text = officeUserFacingError(e);
      _assertUserLanguage(text, label: '权限拒绝');
      expect(text, contains('权限'));

      // 反向确认：这个异常的 `toString()` **确实**含有那些内部细节
      //（证明我们用例禁止的片段是真的会被泄露的，不是空断言）。
      final raw = e.toString();
      expect(raw.contains('OfficeCollabPermissionDeniedException'), isTrue);
      expect(raw.contains('objectId'), isTrue);
    });

    test('协作类其余分支都是用户语言', () {
      for (final e in <Object>[
        OfficeCollabProtocolException('bad frame 42["x"]'),
        OfficeCollabConfigException('empty namespace'),
        OfficeCollabDisconnectedException('socket closed'),
        OfficeCollabTimeoutException('sync', const Duration(seconds: 60)),
      ]) {
        _assertUserLanguage(
          officeUserFacingError(e),
          label: e.runtimeType.toString(),
        );
      }
    });

    test('DSM 错误码保留码值（用户报障有用），但不带报文', () {
      final text = officeUserFacingError(
        DsmApiException(
          102,
          method: 'Office.x',
          raw: <String, dynamic>{'message': 'raw body text'},
        ),
      );
      _assertUserLanguage(text, label: 'DSM 102');
      expect(text, contains('102'));
      expect(text.contains('raw body text'), isFalse);
    });

    test('★ 完全不认识的异常也绝不 toString 进界面', () {
      // 故意造一个"最脏"的异常：类型名 + JSON + 实现者注释。
      final e = StateError(
        'OfficeCollabPermissionDeniedException: Permission denied '
        '{"message":"Permission denied"} (the handshake objectId must be the '
        'Office object_id and linkId the Drive permanent_link)',
      );
      final text = officeUserFacingError(e);
      _assertUserLanguage(text, label: '未知异常兜底');
      expect(text, isNot(contains('StateError')));
    });

    test('空异常/字符串异常也不崩，且仍是用户语言', () {
      for (final e in <Object>[Exception(''), 'plain string', 42]) {
        _assertUserLanguage(officeUserFacingError(e), label: '$e');
      }
    });
  });

  // ★ 只读横幅缺陷（`docs/office-readonly-banner-defect.md`）：闸门已用**信息样式**
  // 表达"只读打开"这一终态，协作的权限拒绝只是其**必然推论** ⇒ 不再重复报红。
  // 反向要求：闸门判可写时、以及只读时的**其它**协作故障，一律照常报错。
  group('只读闸门 + 协作 PermissionDenied 的静音边界（纯函数）', () {
    test('★ 只读（gateAllowsEditing=false）+ PermissionDenied → 冗余（不报红）', () {
      expect(
        officeSessionNoteRedundant(
          OfficeCollabPermissionDeniedException('Permission denied'),
          gateAllowsEditing: false,
        ),
        isTrue,
      );
    });

    test('★ 反向：闸门判可写 + PermissionDenied → 必须仍报错', () {
      expect(
        officeSessionNoteRedundant(
          OfficeCollabPermissionDeniedException('Permission denied'),
          gateAllowsEditing: true,
        ),
        isFalse,
      );
    });

    test('只读 + 其它协作故障（超时/未就绪/断连/协议）→ 全部仍报错', () {
      final others = <Object>[
        OfficeCollabTimeoutException('sync', const Duration(seconds: 60)),
        OfficeCollabNotReadyException('fetch', OfficeCollabState.connecting),
        OfficeCollabDisconnectedException('socket closed'),
        OfficeCollabProtocolException('bad frame'),
        OfficeCollabConfigException('empty namespace'),
        OfficeCollabException('generic'),
        Exception('plain'),
      ];
      for (final e in others) {
        expect(
          officeSessionNoteRedundant(e, gateAllowsEditing: false),
          isFalse,
          reason: '只读时 $e 不是"权限拒绝的必然推论"，必须照常报错',
        );
      }
    });
  });

  _registerOfficeLoadTextTests();
}


// ---------------------------------------------------------------------------
// ★★ 第 308 轮：**装载失败（Load）文案也曾漏出实现者诊断串**（真机 LGE-AN10）
//
// 真机原文（英文环境、点开一个刚由本 App 新建的 `.odoc`）：
// ```
// Failed to open
// Snapshot:get 的内容树与 @C_text/content 形态对不上
// ```
// 根因：三个页的 `_describeError` 写成 `if (error is OfficeXLoadException)
// return error.message;` —— `message` 是诊断串（section 名 + 只有中文），
// **绕过了** `officeUserFacingError` 那条"原文只进日志"的规矩。
//
// 现在统一走 [officeLoadFailureText]，本组用例锁住：
// 1. 每个已知 reason 都是**用户语言**，且不含 `@C_text` / `Snapshot:get` /
//    `permanent_link` / `object_id` / `socket` 这类实现者术语；
// 2. 不认识的 reason 落到全仓唯一兜底，**不把 reason 原文顶上去**；
// 3. ★ 静态守卫：三个页**不许**再出现 `return error.message;`。
// ---------------------------------------------------------------------------
void _registerOfficeLoadTextTests() {
  group('★ r308：装载失败文案必须本地化（不许把诊断串顶到界面）', () {
    const reasons = <String>[
      'no_link_id',
      'not_connected',
      'bad_content_shape',
      'bad_sheet_shape',
      'bad_fetch_ack',
      'no_object_id',
    ];
    // 这些串只配待在 logcat / `debugPrint` 里。
    const forbidden = <String>[
      '@C_text',
      'Snapshot:get',
      'permanent_link',
      'object_id',
      'objectId',
      'linkId',
      'socket',
      'Exception',
      'null',
    ];

    test('六个已知 reason → 本地化人话，且不含任何实现者术语', () {
      for (final r in reasons) {
        final text = officeLoadFailureText(r);
        expect(text.trim(), isNotEmpty, reason: '$r 文案为空');
        for (final bad in forbidden) {
          expect(
            text,
            isNot(contains(bad)),
            reason: '$r 的文案里漏出了「$bad」：$text',
          );
        }
        // 长度可控（横幅/说明行放得下）。
        expect(text.length, lessThan(60), reason: '$r 文案过长：$text');
      }
    });

    test('★ 不认识的 reason → 全仓唯一兜底，绝不把 reason 原文顶上去', () {
      final text = officeLoadFailureText('some_new_reason_from_server');
      expect(text, isNot(contains('some_new_reason_from_server')));
      expect(text.trim(), isNotEmpty);
    });

    test('★ 静态守卫：三个 Office 页不许再 `return error.message;`', () {
      const files = <String>[
        'lib/src/features/office/office_doc_page.dart',
        'lib/src/features/office/office_sheet_page.dart',
        'lib/src/features/office/office_slides_page.dart',
      ];
      for (final f in files) {
        final src = File(f).readAsStringSync();
        expect(
          src.contains('return error.message;'),
          isFalse,
          reason: '$f 又把诊断串直接返回给界面了（应走 officeLoadFailureText）',
        );
        expect(
          src.contains('officeLoadFailureText(error.reason)'),
          isTrue,
          reason: '$f 没有走 officeLoadFailureText',
        );
      }
    });
  });
}
