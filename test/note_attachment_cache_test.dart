// ★★★ 第 119 轮 / 台账 J9（UI 一半）：笔记附件的本地缓存落点。
//
// 要守的性质：
//   ① 文件名**净化**（防目录穿越/怪异字符）；
//   ② 同名冲突靠 fileId 后缀区分（两条附件不能互相覆盖）；
//   ③ 一批附件里单个失败 ⇒ **跳过**，成功的仍返回（与官方
//      `prepareMailContent` 同口径：能带就带）；
//   ④ 真下载走的是 `Note/download`（第 118 轮）。
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:synhub/src/data/dto/note_dto.dart';
import 'package:synhub/src/dsm/webapi.dart';
import 'package:synhub/src/data/note_api.dart';
import 'package:synhub/src/features/notes/note_attachment_cache.dart';

import 'support/chat_harness.dart' show FakeTransport;

const _table = {
  'SYNO.API.Info': {'path': 'query.cgi', 'minVersion': 1, 'maxVersion': 1},
  'SYNO.NoteStation.Note': {
    'path': 'entry.cgi',
    'minVersion': 1,
    'maxVersion': 4,
  },
};

NoteAttachmentDto _att(String fileId, String name) =>
    NoteAttachmentDto(fileId: fileId, name: name);

void main() {
  group('119. 笔记附件缓存（J9 的 UI 一半）', () {
    test('★ 文件名净化：只留安全字符，空结果回落 attachment', () {
      // ★ 中文/空格必须**留住**（首版净化过度把中文吃掉了，属真 bug）
      expect(safeAttachmentName('报表 2024.xlsx'), '报表 2024.xlsx');
      expect(safeAttachmentName('../../etc/passwd'), 'etc_passwd');
      expect(safeAttachmentName('a/b/c.png'), 'a_b_c.png');
      expect(safeAttachmentName('   '), 'attachment');
      expect(safeAttachmentName('正常-名字_1.pdf'), '正常-名字_1.pdf');
      expect(safeAttachmentName('a:b*c?.png'), 'a_b_c_.png');
    });

    test('★ 目标路径：noteId 也净化 + fileId 后缀区分同名', () {
      final a = attachmentCachePath(
        rootDir: '/root',
        noteId: 'n/1',
        fileId: 'f9a8b7c6d5',
        name: '报表.xlsx',
      );
      final b = attachmentCachePath(
        rootDir: '/root',
        noteId: 'n/1',
        fileId: 'ffffffff00',
        name: '报表.xlsx',
      );
      expect(a, '/root/n_1/报表.xlsx-f9a8b7c6');
      expect(a == b, isFalse, reason: '同名附件不能互相覆盖');
    });

    test('★ fileId 全是非法字符 ⇒ 退回纯名字（不产生空后缀破折号）', () {
      expect(
        attachmentCachePath(
          rootDir: '/r',
          noteId: 'n1',
          fileId: '---',
          name: 'x.pdf',
        ),
        '/r/n1/x.pdf',
      );
    });

    test('★ 一批附件里有失败的 ⇒ 跳过它，其余仍返回', () async {
      final t = FakeTransport(const {}, {...FakeTransport.table, ..._table});
      t.downloadBytes = List<int>.filled(8, 1);
      // 只让 file_id=bad 的那条失败（URL 里含 file_id=bad）
      t.failures['file_id=bad'] = 404;
      final api = DsmWebApi(t);
      await api.discover();
      await api.login(account: 'a', password: 'b');
      final dir = Directory.systemTemp.createTempSync('note-att');
      addTearDown(() => dir.deleteSync(recursive: true));

      final note = NoteDto(
        objectId: 'n1',
        title: 't',
        hasContent: true,
        attachments: {
          'ok': _att('f1', 'ok.txt'),
          'bad': _att('bad', 'bad.txt'),
        },
      );
      final errors = <String?>[];
      final paths = await downloadNoteAttachments(
        api: NoteStationApi(api),
        note: note,
        rootDir: dir.path,
        onError: errors.add,
      );
      expect(paths, hasLength(1), reason: '坏的跳过、好的照下');
      expect(File(paths.single).existsSync(), isTrue);
      expect(File(paths.single).lengthSync(), 8);
      expect(errors, hasLength(1), reason: '失败要有回调（页面可提示）');
    });
  });
}
