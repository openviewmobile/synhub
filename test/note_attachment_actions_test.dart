// ★★★ 第 120 轮：笔记附件的两个本地动作 ——
//   * 点 = 用其他应用打开（系统选择器）
//   * 长按 = 保存到"下载"（原生 saveToDownloads）
// 都要**先落盘**（`Note/download` v1），且结果**如实回报**（不假装成功）。
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:synhub/src/data/dto/note_dto.dart';
import 'package:synhub/src/data/note_api.dart';
import 'package:synhub/src/dsm/webapi.dart';
import 'package:synhub/src/features/files/file_link_share.dart'
    show TextShareBridge;
import 'package:synhub/src/features/notes/note_attachment_actions.dart';

import 'support/chat_harness.dart' show FakeTransport;

const _table = {
  'SYNO.API.Info': {'path': 'query.cgi', 'minVersion': 1, 'maxVersion': 1},
  'SYNO.NoteStation.Note': {
    'path': 'entry.cgi',
    'minVersion': 1,
    'maxVersion': 4,
  },
};

/// 记录调用的假桥（**真类方法**才能被这样覆盖，第 111 轮的教训）。
class _RecordingBridge extends TextShareBridge {
  _RecordingBridge({this.saveResult = true});

  final bool saveResult;
  final List<List<String>> shared = [];
  final List<Map<String, String>> saved = [];

  @override
  Future<bool> shareFiles({
    required List<String> paths,
    String text = '',
    String subject = '',
    String mime = '*/*',
  }) async {
    shared.add(paths);
    return true;
  }

  @override
  Future<bool> saveToDownloads({
    required String path,
    required String name,
    String mime = '*/*',
  }) async {
    saved.add({'path': path, 'name': name});
    return saveResult;
  }
}

void main() {
  late FakeTransport t;
  late NoteStationApi api;
  late Directory dir;

  Future<void> boot() async {
    t = FakeTransport(const {}, {...FakeTransport.table, ..._table});
    t.downloadBytes = List<int>.filled(16, 3);
    final web = DsmWebApi(t);
    await web.discover();
    await web.login(account: 'a', password: 'b');
    api = NoteStationApi(web);
    dir = Directory.systemTemp.createTempSync('note-att-actions');
    addTearDown(() => dir.deleteSync(recursive: true));
  }

  NoteAttachmentDto att() => const NoteAttachmentDto(
    fileId: 'f1',
    name: '报表 2024.xlsx',
    type: 'application/vnd.ms-excel',
  );

  test('★ 打开：先落盘再交选择器；路径是刚下载的那个文件', () async {
    await boot();
    final bridge = _RecordingBridge();
    final actions = NoteAttachmentActions(
      bridge: bridge,
      platformTouching: true,
    );
    final outcome = await actions.openWith(
      api: api,
      noteId: 'n1',
      attachment: att(),
      rootDir: dir.path,
    );
    expect(outcome, NoteAttachmentActionOutcome.ok);
    expect(bridge.shared, hasLength(1));
    final path = bridge.shared.single.single;
    expect(File(path).existsSync(), isTrue, reason: '必须先落盘再打开');
    expect(path, contains('报表 2024.xlsx'), reason: '中文名要留住');
    expect(t.downloads, hasLength(1));
    expect(t.downloads.single, contains('method=download'));
  });

  test('★ 保存到"下载"：文件名净化后才交给原生', () async {
    await boot();
    final bridge = _RecordingBridge();
    final actions = NoteAttachmentActions(
      bridge: bridge,
      platformTouching: true,
    );
    final outcome = await actions.saveToDownloads(
      api: api,
      noteId: 'n1',
      attachment: att(),
      rootDir: dir.path,
    );
    expect(outcome, NoteAttachmentActionOutcome.ok);
    expect(bridge.saved.single['name'], '报表 2024.xlsx');
  });

  test('★ 原生拒绝 ⇒ noBridge（不报"已保存"）', () async {
    await boot();
    final actions = NoteAttachmentActions(
      bridge: _RecordingBridge(saveResult: false),
      platformTouching: true,
    );
    expect(
      await actions.saveToDownloads(
        api: api,
        noteId: 'n1',
        attachment: att(),
        rootDir: dir.path,
      ),
      NoteAttachmentActionOutcome.noBridge,
    );
  });

  test('★ 下载失败 ⇒ failed（不会拿一个不存在的路径去打开）', () async {
    await boot();
    t.failures['method=download'] = 500;
    final bridge = _RecordingBridge();
    final actions = NoteAttachmentActions(
      bridge: bridge,
      platformTouching: true,
    );
    expect(
      await actions.openWith(
        api: api,
        noteId: 'n1',
        attachment: att(),
        rootDir: dir.path,
      ),
      NoteAttachmentActionOutcome.failed,
    );
    expect(bridge.shared, isEmpty, reason: '下载失败就不该弹选择器');
  });

  test('★ 测试环境默认不碰平台通道（与 note_mail 同一道门）', () async {
    await boot();
    final actions = NoteAttachmentActions(bridge: _RecordingBridge());
    expect(
      await actions.saveToDownloads(
        api: api,
        noteId: 'n1',
        attachment: att(),
        rootDir: dir.path,
      ),
      NoteAttachmentActionOutcome.noBridge,
    );
  });
}
