// ★★ r371（DA12 / DA14）：**Drive 文本文件的"新建 / 保存"接线**。
//
// 两条真机缺陷（r359 记录）：
//   DA12 新建文本文件：驱动器里建不出来 —— 报文发的是 `text_content`，
//        而服务端 `create` 只认 `file_content`（**base64**），参数名不匹配 ⇒
//        服务端建出的是一条**空文件**（用户看到"建了但没内容"）。
//   DA14 编辑已有文本保存：走 FileStation 临时文件 + 上传，
//        真机 **2/2** 失败（`Save failed: DSM 401: Account disabled`，
//        文件字节数全程未变）；同轮对照：同一条 FileStation 上传通道在
//        文件浏览页**成功** ⇒ 不是账号问题，是"编辑器这条保存"形态不对。
//
// 修法：两条都落到**同一条已取证的报文**上 —— Drive 自己的 `Files/create`
// （`path` + `type=file` + `file_content`(base64) + `conflict_action`）：
//   * 新建：官方 APK 是 `AddTextFile → checkDraftExist()` = **先开空草稿编辑器**、
//     保存时才落盘 ⇒ 我们照办（保存用 `conflict_action: 'autorename'`）；
//   * 编辑：`conflict_action: 'version'`（官方对已存在文件的默认策略 = 建新版本）。
//
// 报文级断言在 `test/drive_gaps_api_test.dart`（真的发出 `file_content`）；
// 本文件补的是**接线**：界面上那两处到底把哪个策略传下去、有没有偷偷退回
// 临时文件那条通道。
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// 取 `src` 里 [from]（含）到 [to]（不含）之间的一段；找不到就抛，
/// **不许**静默返回空串（那种断言恒为假绿）。
String slice(String src, String from, String to) {
  final i = src.indexOf(from);
  expect(i, greaterThanOrEqualTo(0), reason: '切片起点没找到：$from');
  final j = src.indexOf(to, i + from.length);
  expect(j, greaterThan(i), reason: '切片终点没找到：$to');
  return src.substring(i, j);
}

void main() {
  late String src;
  late String api;

  setUpAll(() {
    src = File(
      'lib/src/features/files/drive_browse_view.dart',
    ).readAsStringSync();
    api = File('lib/src/data/drive_api.dart').readAsStringSync();
  });

  group('DA14 · 编辑已有文本 → Files/create(conflict_action=version)', () {
    test('保存回调真的调 `createTextFile`，且策略是 version', () {
      final body = slice(src, 'Future<void> _editText(', '/// 「下载为 …」');
      expect(body, contains('createTextFile('));
      expect(
        body,
        contains("conflictAction: 'version'"),
        reason: '★ 覆盖保存 = 官方对"已存在文件"的默认策略（建新版本）',
      );
      // ★ 反向：不许再借 FileStation 的"临时文件 + 上传"那条通道
      expect(body, isNot(contains('FileStation')));
      expect(body, isNot(contains('systemTemp')));
      expect(body, isNot(contains('fs.upload')));
    });
  });

  group('DA12 · 新建文本 → 先开草稿编辑器，保存时才 create', () {
    test('case 文本：推编辑器 + 空草稿 + conflict_action=autorename', () {
      // `case 'text'` 是新建面板 switch 的**最后一个分支** ⇒ 终点取下一位成员
      final body = slice(src, "case 'text':", '/// 加密新建的');
      expect(
        body,
        contains('DriveTextEditorPage('),
        reason: '★ 官方 `AddTextFile → checkDraftExist()`：新建立刻进编辑器',
      );
      expect(
        body,
        contains("loadText: () async => ''"),
        reason: '★ 草稿：保存之前服务端不该有文件',
      );
      expect(body, contains('createTextFile('));
      expect(body, contains("conflictAction: 'autorename'"));
      // ★ 反向：新建这条**不许**在推编辑器之前就落盘（那正是 DA12 的形态）
      final beforePush = body.substring(
        0,
        body.indexOf('DriveTextEditorPage('),
      );
      expect(beforePush, isNot(contains('createTextFile(')));
    });
  });

  group('参数名：全仓线上代码不许再出现 `text_content`', () {
    test('`lib/` 里没有把它当**报文参数**用（注释里的历史说明不算）', () {
      final offenders = <String>[];
      for (final f in Directory('lib').listSync(recursive: true)) {
        if (f is! File || !f.path.endsWith('.dart')) continue;
        final s = f.readAsStringSync();
        if (s.contains("'text_content'") || s.contains('"text_content"')) {
          offenders.add(f.path);
        }
      }
      expect(
        offenders,
        isEmpty,
        reason: '★★ DA12 根因就是它：服务端 `create` 只认 `file_content`',
      );
      // 正向：真正的参数名在 API 层（`file_content` + base64）
      expect(api, contains("'file_content': base64Encode("));
    });
  });

  // ★ r379（DA16）：**点行**也要按官方的 1 MiB 分流进编辑器。
  //   这条守的是"路由接线"，防的是"有人把 `_open` 里那段分流删掉、又退回
  //   一律进阅读器"——纯函数 `driveTapOpenMode` 的正确性由
  //   `drive_gaps_wave1_test.dart` 的单测保证。
  group('DA16 · 点行落点：≤1 MiB 的 .txt/.md 要进编辑器', () {
    test('`_open` 里真的按 `driveTapOpenMode` 分流，且只读时不放保存', () {
      final body = slice(
        src,
        'Future<void> _open(',
        '/// Office 原生文档的**原生字节**直链',
      );
      expect(
        body,
        contains('driveTapOpenMode(name: entry.name, size: entry.size)'),
        reason: r'★ 判据必须挂在"后缀 + 体积"上（官方 openFile$lambda$5）',
      );
      expect(body, contains('DriveTapOpen.editor'));
      expect(
        body,
        contains('_editText(context, ref, readOnly: !entry.canWrite)'),
        reason: '★ 官方不看写权限：只读文件也进编辑器，只是不给保存',
      );
      // 顺序：分流必须发生在通用 `openFilePreview` **之前**，否则永远走不到
      final i = body.indexOf('DriveTapOpen.editor');
      final j = body.indexOf('openFilePreview(');
      expect(i, greaterThanOrEqualTo(0));
      expect(j, greaterThan(i), reason: '★ 分流要挡在 openFilePreview 前面');
    });

    test('编辑器把 readOnly 传下去（否则保存按钮会骗人）', () {
      final body = slice(src, 'Future<void> _editText(', '/// 「下载为 …」');
      expect(body, contains('readOnly: readOnly,'));
    });
  });
}
