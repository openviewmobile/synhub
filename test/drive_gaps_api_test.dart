// Drive wave1「可直接做」剩余项的**接口层**离线测试（不依赖任何 widget / Office）。
//
// 与 `drive_gaps_wave1_test.dart`（界面层）分开，原因很实际：界面层要 import
// `drive_browse_view.dart`，它会连带编译 Office 模块；接口层只碰
// `drive_api.dart` + provider，能独立于 Office 批次跑。
//
// 覆盖：
//   * D19 排序（`sort_by`/`sort_direction` 一路透传）
//   * D18 网格视图（`Files/list` 的 `field=thumbnail` + DTO 解析）
//   * D60 createTextFile（`type=file` + `text_content`）
//   * D43 createFileRequest identifier
//   * 相机备份 `Photos/upload` 的 `path` = 目录 + 文件名（真机 A/B 2026-09-22）
import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:synhub/src/data/drive_api.dart';
import 'package:synhub/src/data/dto/drive_entry_dto.dart';
import 'package:synhub/src/dsm/webapi.dart';
import 'package:synhub/src/features/files/drive_providers.dart';

import 'support/chat_harness.dart' show FakeTransport;

const _table = {
  'SYNO.API.Info': {'path': 'query.cgi', 'minVersion': 1, 'maxVersion': 1},
  'SYNO.SynologyDrive.Files': {
    'path': 'entry.cgi',
    'minVersion': 1,
    'maxVersion': 11,
  },
  'SYNO.SynologyDrive.Photos': {
    'path': 'entry.cgi',
    'minVersion': 1,
    'maxVersion': 3,
  },
  'SYNO.SynologyDrive.FileRequest': {
    'path': 'entry.cgi',
    'minVersion': 1,
    'maxVersion': 1,
  },
};

Map<String, dynamic> _item({
  required String id,
  required String name,
  String type = 'file',
  String? thumbnail,
}) => {
  'file_id': id,
  'name': name,
  'type': type,
  'path': '/$name',
  'display_path': '/mydrive/$name',
  'parent_id': '900',
  'size': type == 'dir' ? 0 : 2048,
  'modified_time': 1789739500,
  'created_time': 1789739400,
  'content_type': type == 'dir' ? 'dir' : 'document',
  'starred': false,
  'shared': false,
  'owner': {'display_name': 'demo_user', 'name': 'demo_user'},
  'capabilities': {
    'can_download': true,
    'can_preview': true,
    'can_write': true,
  },
  if (thumbnail != null) 'thumbnail': thumbnail,
};

Future<({FakeTransport t, DsmWebApi api})> _loggedIn(FakeTransport t) async {
  final api = DsmWebApi(t);
  await api.discover();
  await api.login(account: 'a', password: 'b');
  return (t: t, api: api);
}

FakeTransport _transport({
  Map<String, Map<String, dynamic>> responses = const {},
}) {
  final t = FakeTransport(responses, {...FakeTransport.table, ..._table});
  t.onCall = (params) {
    final key = '${params['api']}.${params['method']}';
    return {...?responses[key], 'success': true};
  };
  return t;
}

Map<String, dynamic> _listCall(FakeTransport t) =>
    t.calls.lastWhere((c) => c['method'] == 'list');

ProviderContainer _container(FakeTransport t, DsmWebApi api) {
  final c = ProviderContainer(
    overrides: [driveApiProvider.overrideWithValue(DriveApi(api))],
  );
  addTearDown(c.dispose);
  return c;
}

void main() {
  group('D19 排序参数透传', () {
    test('选 name + 降序 → list 带 sort_by/sort_direction', () async {
      final t = _transport(
        responses: {
          'SYNO.SynologyDrive.Files.list': {
            'items': [_item(id: '1', name: 'a.txt')],
            'total': 1,
          },
        },
      );
      final s = await _loggedIn(t);
      final c = _container(t, s.api);
      c
          .read(driveSortProvider.notifier)
          .set(DriveSortBy.name, descending: true);
      final keep = c.listen(driveListProvider(kDriveRoot), (_, __) {});
      addTearDown(keep.close);
      await c.read(driveListProvider(kDriveRoot).future);
      final call = _listCall(t);
      expect(call['sort_by'], 'name');
      expect(call['sort_direction'], 'desc');
    });

    test('默认状态不发 sort_by（保持老行为）', () async {
      final t = _transport(
        responses: {
          'SYNO.SynologyDrive.Files.list': {'items': const [], 'total': 0},
        },
      );
      final s = await _loggedIn(t);
      final c = _container(t, s.api);
      final keep = c.listen(driveListProvider(kDriveRoot), (_, __) {});
      addTearDown(keep.close);
      await c.read(driveListProvider(kDriveRoot).future);
      expect(_listCall(t).containsKey('sort_by'), isFalse);
    });
  });

  group('D18 网格视图缩略图字段', () {
    test('网格模式 → list 带 field=thumbnail；列表模式不带', () async {
      final t = _transport(
        responses: {
          'SYNO.SynologyDrive.Files.list': {
            'items': [_item(id: '1', name: 'a.jpg')],
            'total': 1,
          },
        },
      );
      final s = await _loggedIn(t);
      final c = _container(t, s.api);
      final keep = c.listen(driveListProvider(kDriveRoot), (_, __) {});
      addTearDown(keep.close);
      await c.read(driveListProvider(kDriveRoot).future);
      expect(_listCall(t).containsKey('field'), isFalse);

      c.read(driveViewModeProvider.notifier).set(DriveViewMode.grid);
      await c.read(driveListProvider(kDriveRoot).future);
      expect(_listCall(t)['field'], 'thumbnail');
    });

    test('DTO 解析服务端可能回的 thumbnail 字段', () {
      final e = DriveEntryDto.fromJson(
        _item(id: '1', name: 'a.jpg', thumbnail: 'https://x/y.jpg'),
      );
      expect(e.thumbnail, 'https://x/y.jpg');
    });
  });

  group('D60/D43 新建通道与 identifier', () {
    test('createTextFile 发 type=file + file_content(base64) —— 不是 text_content', () async {
      final t = _transport(
        responses: {
          'SYNO.SynologyDrive.Files.create': _item(id: '1', name: 'a.txt'),
        },
      );
      final s = await _loggedIn(t);
      await DriveApi(s.api).createTextFile(
        path: '/mydrive/notes/a.txt',
        textContent: 'hi',
      );
      final call = t.calls.lastWhere((c) => c['method'] == 'create');
      expect(call['type'], 'file');
      expect(call['path'], '/mydrive/notes/a.txt');
      // ★★ r371（DA12）：服务端 `create.cpp` 认的参数名是 `file_content`，
      //    内容是 base64（"length of file content is not multiple of 4" /
      //    "failed to decode base64 string"）—— 所以两条都要钉死。
      expect(call['file_content'], base64Encode(utf8.encode('hi')));
      expect(call.containsKey('text_content'), isFalse, reason: '那是 AppendTextWork 的参数名');
      // 新建默认的冲突策略（官方 Web 端建节点那条传 autorename）
      expect(call['conflict_action'], 'autorename');
    });

    test('createTextFile 覆盖保存 → conflict_action=version（Drive 的版本语义）', () async {
      final t = _transport(
        responses: {
          'SYNO.SynologyDrive.Files.create': _item(id: '1', name: 'a.txt'),
        },
      );
      final s = await _loggedIn(t);
      await DriveApi(s.api).createTextFile(
        path: '/mydrive/notes/a.txt',
        textContent: '',
        conflictAction: 'version',
      );
      final call = t.calls.lastWhere((c) => c['method'] == 'create');
      expect(call['file_content'], '');
      expect(call['conflict_action'], 'version');
    });

    test('createFileRequest 透传 identifier=add_prefix', () async {
      final t = _transport(
        responses: {
          'SYNO.SynologyDrive.FileRequest.create': {
            'title': 't',
            'sharing_link': 'sl',
          },
        },
      );
      final s = await _loggedIn(t);
      await DriveApi(
        s.api,
      ).createFileRequest(folderId: '1', title: 't', identifier: 'add_prefix');
      final call = t.calls.lastWhere((c) => c['method'] == 'create');
      expect(call['identifier'], 'add_prefix');
    });
  });

  group('相机备份 Photos/upload 落点', () {
    test('path = 目录 + 文件名（不是目录本身）', () async {
      final t = _transport(
        responses: {
          'SYNO.SynologyDrive.Photos.upload': {'file_id': '9'},
        },
      );
      final s = await _loggedIn(t);
      await DriveApi(s.api).uploadPhotoForBackup(
        folderPath: '/mydrive/PhotoBackup/LGE-AN10',
        filePath: '/tmp/whatever.png',
        fileName: 'PROBE_V2.png',
        modifiedTimeMs: 0,
      );
      final call = t.calls.lastWhere((c) => c['method'] == 'upload');
      expect(call['path'], '/mydrive/PhotoBackup/LGE-AN10/PROBE_V2.png');
      expect(call['path'], isNot('/mydrive/PhotoBackup/LGE-AN10'));
    });

    test('目录以 / 结尾不产生双斜杠', () async {
      final t = _transport(
        responses: {
          'SYNO.SynologyDrive.Photos.upload': {'file_id': '9'},
        },
      );
      final s = await _loggedIn(t);
      await DriveApi(s.api).uploadPhotoForBackup(
        folderPath: '/mydrive/PhotoBackup/LGE-AN10/',
        filePath: '/tmp/x.png',
        fileName: 'x.png',
        modifiedTimeMs: 0,
      );
      expect(
        t.calls.lastWhere((c) => c['method'] == 'upload')['path'],
        '/mydrive/PhotoBackup/LGE-AN10/x.png',
      );
    });

    test('同一目录多张照片 → 各自独立路径（互不覆盖）', () async {
      final t = _transport(
        responses: {
          'SYNO.SynologyDrive.Photos.upload': {'file_id': '9'},
        },
      );
      final s = await _loggedIn(t);
      final api = DriveApi(s.api);
      for (final name in ['IMG_1.jpg', 'IMG_2.jpg']) {
        await api.uploadPhotoForBackup(
          folderPath: '/mydrive/PhotoBackup/Pixel',
          filePath: '/tmp/$name',
          fileName: name,
          modifiedTimeMs: 0,
        );
      }
      final paths = [
        for (final c in t.calls)
          if (c['method'] == 'upload') c['path'],
      ];
      expect(paths, [
        '/mydrive/PhotoBackup/Pixel/IMG_1.jpg',
        '/mydrive/PhotoBackup/Pixel/IMG_2.jpg',
      ]);
      expect(paths.toSet().length, 2);
    });
  });
}
