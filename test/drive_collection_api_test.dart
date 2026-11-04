// D8（收藏集 / 收藏夹）协议层测试。
//
// 每条断言都能对回**原文证据**（文件 + 位置写在 `drive_api.dart` /
// `drive_collection_dto.dart` 的注释里）：
//   * 反编译 `Android-SynologyDrive.3.9.0-1113.ww.apk`：
//     `ApiSynoDriveLabels.setAsListCollection(FileGroup)`（`:117`）=
//     `Labels/list` + `type`，版本 `Math.min(2, api.getMaxVersion())`；
//     `setAsCreateCollection` 同版本；`setAsUpdate` / `setAsDelete` 与标签共用；
//   * `LabelImpl.java:39-42` 的四个类型串（`photo_album` / `document_folder` /
//     `audio_playlist` / `video_playlist`）；
//   * `ApiSynoDriveFiles.setAsLabelFiles(...)`（`:614-632`）：成员关系走
//     `Files/label` + `labels:[{action:"add"|"delete", label_id:<int>}]`；
//   * 本批**真机只读实测**：四个类型 `Labels:list v3` 都回
//     `{"items":[],"total":0} success`。
//
// ⚠️ `create` / `update` / `delete` 是**写方法**，按 §5.1 本批**一次都没调**；
// 下面只断言"我们组出来的参数形状与官方逐字一致"，不产生任何网络副作用
// （全部走 FakeTransport）。
import 'package:flutter_test/flutter_test.dart';

import 'package:synhub/src/data/drive_api.dart';
import 'package:synhub/src/data/dto/drive_collection_dto.dart';
import 'package:synhub/src/dsm/webapi.dart';

import 'support/chat_harness.dart' show FakeTransport;

const _table = {
  'SYNO.API.Info': {'path': 'query.cgi', 'minVersion': 1, 'maxVersion': 1},
  'SYNO.SynologyDrive.Labels': {
    'path': 'entry.cgi',
    'minVersion': 1,
    'maxVersion': 3,
  },
  'SYNO.SynologyDrive.Files': {
    'path': 'entry.cgi',
    'minVersion': 1,
    'maxVersion': 11,
  },
};

Future<DsmWebApi> _loggedIn(FakeTransport t) async {
  final api = DsmWebApi(t);
  await api.discover();
  await api.login(account: 'a', password: 'b');
  return api;
}

/// 一次调用就够的假服务器：记录所有请求，回包里补 `success:true`
FakeTransport _transport(
  Map<String, Map<String, dynamic>> responses, {
  Map<String, Map<String, dynamic>>? table,
}) {
  final t = FakeTransport(responses, {
    ...FakeTransport.table,
    ..._table,
    ...?table,
  });
  t.onCall = (params) {
    final key = '${params['api']}.${params['method']}';
    return {...?responses[key], 'success': true};
  };
  return t;
}

void main() {
  group('收藏集：列（Labels/list，真机只读验过）', () {
    test('photo_album → Labels/list v2 + type，解析出收藏集字段', () async {
      final t = _transport({
        'SYNO.SynologyDrive.Labels.list': {
          'items': [
            {
              'label_id': '7',
              'name': '旅行照片',
              'type': 'photo_album',
              'color': '#1a73e8',
              'position': 3,
              'file_count': 12,
            },
          ],
          'total': 1,
        },
      });
      final api = await _loggedIn(t);
      final list = await DriveApi(
        api,
      ).listCollections(type: DriveCollectionType.photo);
      final call = t.calls.last;
      expect(call['api'], 'SYNO.SynologyDrive.Labels');
      expect(call['method'], 'list');
      // 官方 `setAsListCollection` 的 VersionComputer = Math.min(2, maxVersion)
      expect(call['version'], '2');
      expect(call['type'], 'photo_album');

      final c = list.single;
      expect(c.collectionId, '7');
      expect(c.name, '旅行照片');
      expect(c.type, 'photo_album');
      expect(c.collectionType, DriveCollectionType.photo);
      expect(c.fileCount, 12);
      expect(c.position, 3);
      expect(c.colorValue, 0xFF1A73E8);
    });

    test('四个官方类型串都原样上行（LabelImpl.TYPE_COLLECTION_*）', () async {
      const expected = {
        DriveCollectionType.photo: 'photo_album',
        DriveCollectionType.document: 'document_folder',
        DriveCollectionType.audio: 'audio_playlist',
        DriveCollectionType.video: 'video_playlist',
      };
      for (final e in expected.entries) {
        final t = _transport({
          'SYNO.SynologyDrive.Labels.list': {'items': [], 'total': 0},
        });
        final api = await _loggedIn(t);
        await DriveApi(api).listCollections(type: e.key);
        expect(t.calls.last['type'], e.value);
      }
    });

    test('服务端空表 ⇒ 空列表（真机四个类型都是这个形态，不是错误）', () async {
      final t = _transport({
        'SYNO.SynologyDrive.Labels.list': {'items': [], 'total': 0},
      });
      final api = await _loggedIn(t);
      final list = await DriveApi(
        api,
      ).listCollections(type: DriveCollectionType.document);
      expect(list, isEmpty);
    });

    test('老服务器 Labels 只到 v1 ⇒ 协商到 v1（不写死 maxVersion）', () async {
      final t = _transport(
        {
          'SYNO.SynologyDrive.Labels.list': {'items': [], 'total': 0},
        },
        table: {
          'SYNO.SynologyDrive.Labels': {
            'path': 'entry.cgi',
            'minVersion': 1,
            'maxVersion': 1,
          },
        },
      );
      final api = await _loggedIn(t);
      await DriveApi(api).listCollections(type: DriveCollectionType.photo);
      expect(t.calls.last['version'], '1');
    });

    test('未知类型串不硬套成已知枚举', () {
      expect(DriveCollectionType.fromApiValue('personal_label'), isNull);
      expect(DriveCollectionType.fromApiValue('weird_type'), isNull);
      final dto = DriveCollectionDto.fromJson({
        'label_id': '1',
        'name': 'x',
        'type': 'weird_type',
      });
      expect(dto.collectionType, isNull);
      // 默认值不崩
      expect(dto.fileCount, 0);
      expect(dto.color, '#8a8a8e');
    });
  });

  group('收藏集：建 / 改名 / 删（写方法，本批不真调）', () {
    test(
      'createCollection → Labels/create v2 + type + Gson 引号串 name',
      () async {
        final t = _transport({
          'SYNO.SynologyDrive.Labels.create': {
            'label_id': '9',
            'name': '我的专辑',
            'type': 'photo_album',
          },
        });
        final api = await _loggedIn(t);
        final c = await DriveApi(api).createCollection(
          name: '我的专辑',
          type: DriveCollectionType.photo,
          color: '#ff0000',
        );
        final call = t.calls.last;
        expect(call['api'], 'SYNO.SynologyDrive.Labels');
        expect(call['method'], 'create');
        expect(call['version'], '2');
        expect(call['type'], 'photo_album');
        // 与已真机验证过的 `Labels/create` 同 API 同参数：name 是 Gson 引号串
        expect(call['name'], '"我的专辑"');
        expect(call['color'], '"#ff0000"');
        expect(c.collectionId, '9');
      },
    );

    test('createCollection 不给 color 时不下发该参数', () async {
      final t = _transport({
        'SYNO.SynologyDrive.Labels.create': {'label_id': '1', 'name': 'n'},
      });
      final api = await _loggedIn(t);
      await DriveApi(
        api,
      ).createCollection(name: 'n', type: DriveCollectionType.document);
      expect(t.calls.last.containsKey('color'), isFalse);
      expect(t.calls.last['type'], 'document_folder');
    });

    test('updateCollection → Labels/update v2 + 引号串 label_id / name', () async {
      final t = _transport({
        'SYNO.SynologyDrive.Labels.update': {'label_id': '7', 'name': '新名'},
      });
      final api = await _loggedIn(t);
      await DriveApi(api).updateCollection(collectionId: '7', name: '新名');
      final call = t.calls.last;
      expect(call['method'], 'update');
      expect(call['version'], '2');
      expect(call['label_id'], '"7"');
      expect(call['name'], '"新名"');
      expect(call.containsKey('color'), isFalse);
    });

    test('deleteCollection → Labels/delete v2 + 引号串 label_id', () async {
      final t = _transport({'SYNO.SynologyDrive.Labels.delete': {}});
      final api = await _loggedIn(t);
      await DriveApi(api).deleteCollection('7');
      final call = t.calls.last;
      expect(call['method'], 'delete');
      expect(call['version'], '2');
      expect(call['label_id'], '"7"');
    });
  });

  group('收藏集成员：加入 / 移出走 Files/label（不是 Collections 方法）', () {
    test(
      'addFilesToCollection → files 是 id: 路径 + action:add 的数字 label_id',
      () async {
        final t = _transport({'SYNO.SynologyDrive.Files.label': {}});
        final api = await _loggedIn(t);
        await DriveApi(
          api,
        ).addFilesToCollection(fileIds: ['5'], collectionId: '7');
        final call = t.calls.last;
        expect(call['api'], 'SYNO.SynologyDrive.Files');
        expect(call['method'], 'label');
        expect(call['version'], '2');
        expect(call['files'], '["id:5"]');
        // 官方 `setAsLabelFiles`：add 分支逐字是 {"action":"add","label_id":<int>}
        expect(call['labels'], '[{"action":"add","label_id":7}]');
      },
    );

    test('removeFilesFromCollection → action:delete 逐字', () async {
      final t = _transport({'SYNO.SynologyDrive.Files.label': {}});
      final api = await _loggedIn(t);
      await DriveApi(
        api,
      ).removeFilesFromCollection(fileIds: ['5'], collectionId: '7');
      expect(t.calls.last['labels'], '[{"action":"delete","label_id":7}]');
    });

    test(
      'listCollectionFiles → Files/list_labelled v2 + Gson 引号串 label_id',
      () async {
        final t = _transport({
          'SYNO.SynologyDrive.Files.list_labelled': {
            'items': [
              {'file_id': '3', 'name': 'a.jpg', 'type': 'file', 'size': 100},
            ],
            'total': 1,
          },
        });
        final api = await _loggedIn(t);
        final files = await DriveApi(
          api,
        ).listCollectionFiles(collectionId: '7');
        final call = t.calls.last;
        expect(call['method'], 'list_labelled');
        expect(call['label_id'], '"7"');
        expect(files.items.single.name, 'a.jpg');
        expect(files.total, 1);
      },
    );
  });
}
