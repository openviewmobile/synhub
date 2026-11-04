// `SYNO.FileStation.Worm`（get / get_share_info，v1）+ `SYNO.FileStation.PhotoUpload`
// （upload，v2/v3）+ `additional` 的**版本相关编码**。
//
// 这三块的真机证据与逐字回包见 `docs/filestation-worm-photoupload-wave.md`。
//
// 本文件**自带**假传输（含"服务端原始错误体"能力），不动
// `test/support/chat_harness.dart`（那是多模块共用件）。
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:synhub/src/data/dto/file_entry_dto.dart';
import 'package:synhub/src/data/dto/file_photo_upload_dto.dart';
import 'package:synhub/src/data/dto/file_worm_dto.dart';
import 'package:synhub/src/data/filestation_api.dart';
import 'package:synhub/src/dsm/webapi.dart';

class _Fake extends WebApiTransport {
  _Fake(this.apiTable);

  final Map<String, Map<String, dynamic>> apiTable;
  final List<Map<String, dynamic>> calls = [];
  final List<Map<String, dynamic>> uploads = [];
  final Map<String, Map<String, dynamic>> responses = {};

  /// (api.method) → **完整错误信封**（能带 `errors[]`，`failures` 只给 code 做不到）
  final Map<String, Map<String, dynamic>> errorBodies = {};

  @override
  String get describeKind => 'fake-worm';

  @override
  String get baseUrl => 'https://nas.example.com:5001/';

  @override
  Future<String> describe({String? module}) async =>
      jsonEncode({'success': true, 'data': apiTable});

  @override
  Future<String> postForm(
    String path,
    Map<String, dynamic> params, {
    String? module,
  }) async {
    calls.add({...params});
    final key = '${params['api']}.${params['method']}';
    final err = errorBodies[key];
    if (err != null) return jsonEncode(err);
    return jsonEncode({'success': true, 'data': responses[key] ?? const {}});
  }

  @override
  Future<String> postMultipart(
    String path, {
    required Map<String, dynamic> query,
    required Map<String, String> fields,
    String? fileField,
    String? filePath,
    String? fileName,
    String? mimeType,
    String? module,
    List<MultipartUploadFile>? files,
    void Function(int sent, int total)? onProgress,
    Map<String, String>? headers,
  }) async {
    uploads.add({
      'path': path,
      'query': {...query},
      'fields': {...fields},
      'fileField': fileField,
      'filePath': filePath,
      'fileName': fileName,
      'mimeType': mimeType,
      'files': files == null
          ? null
          : [for (final f in files) '${f.field}:${f.fileName}'],
    });
    final key = '${fields['api']}.${fields['method']}';
    final err = errorBodies[key];
    if (err != null) return jsonEncode(err);
    return jsonEncode({'success': true, 'data': responses[key] ?? const {}});
  }

  @override
  Future<void> close() async {}

  @override
  String authenticatedUrl(
    String path,
    Map<String, String> params, {
    String? sid,
  }) => 'https://nas.example.com:5001/webapi/$path';
}

/// 真机 `SYNO.API.Info` 的形状（Worm 声明 v1–2，**但方法只在 v1**；
/// PhotoUpload 只声明 v2–3）。
const _table = <String, Map<String, dynamic>>{
  'SYNO.API.Info': {'path': 'query.cgi', 'minVersion': 1, 'maxVersion': 1},
  'SYNO.FileStation.List': {
    'path': 'entry.cgi',
    'minVersion': 1,
    'maxVersion': 2,
  },
  'SYNO.FileStation.VirtualFolder': {
    'path': 'entry.cgi',
    'minVersion': 1,
    'maxVersion': 2,
  },
  'SYNO.FileStation.Favorite': {
    'path': 'entry.cgi',
    'minVersion': 1,
    'maxVersion': 2,
  },
  'SYNO.FileStation.Search': {
    'path': 'entry.cgi',
    'minVersion': 1,
    'maxVersion': 2,
  },
  'SYNO.FileStation.Upload': {
    'path': 'entry.cgi',
    'minVersion': 2,
    'maxVersion': 3,
  },
  'SYNO.FileStation.PhotoUpload': {
    'path': 'entry.cgi',
    'minVersion': 2,
    'maxVersion': 3,
  },
  'SYNO.FileStation.Worm': {
    'path': 'entry.cgi',
    'minVersion': 1,
    'maxVersion': 2,
  },
  // 真机 `API.Info`：Search.History v1（get/set/delete 都在 v1 段）
  'SYNO.FileStation.Search.History': {
    'path': 'entry.cgi',
    'minVersion': 1,
    'maxVersion': 1,
  },
};

Future<({FileStationApi fs, _Fake t})> _api({
  Map<String, Map<String, dynamic>>? table,
}) async {
  final t = _Fake(table ?? _table);
  final web = DsmWebApi(t);
  await web.discover();
  return (fs: FileStationApi(web), t: t);
}

/// 只把某 API 的上限压到 1（模拟"只提供 v1 的老 NAS"）。
Map<String, Map<String, dynamic>> _v1Table() {
  final t = Map<String, Map<String, dynamic>>.from(_table);
  for (final k in [
    'SYNO.FileStation.List',
    'SYNO.FileStation.VirtualFolder',
    'SYNO.FileStation.Favorite',
    'SYNO.FileStation.Search',
  ]) {
    t[k] = {'path': 'entry.cgi', 'minVersion': 1, 'maxVersion': 1};
  }
  return t;
}

File _tmpFile(String name, int bytes) {
  final dir = Directory.systemTemp.createTempSync('flt-worm');
  final f = File('${dir.path}/$name')
    ..writeAsBytesSync(List<int>.filled(bytes, 3));
  addTearDown(() {
    try {
      dir.deleteSync(recursive: true);
    } catch (_) {}
  });
  return f;
}

void main() {
  group('Worm · get_share_info（v1，真机契约）', () {
    test('发 v1 + 单值 path；解析真机回包（def_lock_mode=2 ⇒ 未启用）', () async {
      final (:fs, :t) = await _api();
      // 真机逐字回包（DSM 7.x / DS923+，path:"/docker"）
      t.responses['SYNO.FileStation.Worm.get_share_info'] = const {
        'def_lock_duration': -1,
        'def_lock_mode': 2,
        'lock_wait_time': -1,
        'subvol_mode': 1,
      };
      final info = await fs.wormShareInfo('/docker');

      final c = t.calls.single;
      expect(c['api'], 'SYNO.FileStation.Worm');
      expect(c['method'], 'get_share_info');
      // ⚠️ 必须钉 v1：真机 v2 恒 103（方法只在 "1" 段）
      expect('${c['version']}', '1');
      expect(c['path'], '/docker', reason: '必需参数名是单值 path');

      expect(info, isNotNull);
      expect(info!.subvolMode, FileWormSubVolMode.normal);
      expect(info.defLockMode, FileWormDefLockMode.normal);
      expect(info.defLockDuration, -1, reason: '真机未设置时回 -1，不是 0');
      expect(info.lockWaitTime, -1);
      expect(
        info.autoLockEnabled,
        isFalse,
        reason: '官方 setWormShareInfo：只有 Immutable/Appendable 才算启用',
      );
    });

    test('即便 API 表宣称 maxVersion=2，也照样发 v1（v2 是空方法段）', () async {
      final (:fs, :t) = await _api();
      t.responses['SYNO.FileStation.Worm.get_share_info'] = const {
        'def_lock_mode': 3,
        'subvol_mode': 3,
        'lock_wait_time': 3600,
        'def_lock_duration': 604800,
      };
      final info = await fs.wormShareInfo('/home');
      expect('${t.calls.single['version']}', '1');
      expect(info!.autoLockEnabled, isTrue);
      expect(info.lockWaitTime, 3600);
      expect(info.defLockDuration, 604800);
    });

    test('服务端没给 def_lock_mode ⇒ 返回 null（别硬凑默认值）', () async {
      final (:fs, :t) = await _api();
      t.responses['SYNO.FileStation.Worm.get_share_info'] = const {};
      expect(await fs.wormShareInfo('/home'), isNull);
    });
  });

  group('Worm · get（外层恒 1500，判别力在内层 errors[])', () {
    test('内层 code=0 ⇒ "没有 WORM"，**不抛异常**', () async {
      final (:fs, :t) = await _api();
      // 真机逐字回包
      t.errorBodies['SYNO.FileStation.Worm.get'] = const {
        'error': {
          'code': 1500,
          'errors': [
            {'code': 0, 'path': '/home'},
          ],
        },
        'success': false,
      };
      final st = await fs.wormGet('/home');

      final c = t.calls.single;
      expect('${c['version']}', '1');
      expect(c['path'], '/home');
      expect(c['path'], isA<String>(), reason: '只认单值 path，不发 JSON 数组');

      expect(st.code, FileWormPathCode.noWorm);
      expect(st.notInWorm, isTrue);
      expect(st.hasState, isFalse);
      expect(st.isLocked, isFalse);
    });

    test('无参/空 path 的内层 400 ⇒ **照常抛**（不静默成"未启用"）', () async {
      final (:fs, :t) = await _api();
      t.errorBodies['SYNO.FileStation.Worm.get'] = const {
        'error': {
          'code': 1500,
          'errors': [
            {'code': 400, 'path': ''},
          ],
        },
        'success': false,
      };
      await expectLater(
        fs.wormGet(''),
        throwsA(isA<DsmApiException>().having((e) => e.code, 'code', 1500)),
      );
    });

    test('内层 408（路径不存在）⇒ **照常抛**', () async {
      final (:fs, :t) = await _api();
      t.errorBodies['SYNO.FileStation.Worm.get'] = const {
        'error': {
          'code': 1500,
          'errors': [
            {'code': 408, 'path': '/mydrive'},
          ],
        },
        'success': false,
      };
      await expectLater(
        fs.wormGet('/mydrive'),
        throwsA(isA<DsmApiException>()),
      );
    });

    test('其它外层码（103）不被当内层解析，原样抛', () async {
      final (:fs, :t) = await _api();
      t.errorBodies['SYNO.FileStation.Worm.get'] = const {
        'error': {'code': 103},
        'success': false,
      };
      await expectLater(fs.wormGet('/home'), throwsA(isA<DsmApiException>()));
    });

    test('success:true 分支按官方字段名解析（本机无正向样本，宽松解析）', () async {
      final (:fs, :t) = await _api();
      t.responses['SYNO.FileStation.Worm.get'] = const {
        'worm_state': 4,
        'lock_time': 1789000000,
        'unlock_time': 1800000000,
        'lock_duration': 11000000,
        'last_update_time': 1788990000,
        'ds_current_time': 1788900000,
      };
      final st = await fs.wormGet('/home/locked.txt');
      expect(st.hasState, isTrue);
      expect(st.notInWorm, isFalse);
      expect(
        st.isLocked,
        isTrue,
        reason: 'wire 4 = IMMUTABLE_LOCKED（value&32）',
      );
      expect(st.lockTime, 1789000000);
      expect(st.unlockTime, 1800000000);
      expect(st.serverTime, 1788900000);
    });
  });

  group('Worm DTO · 官方枚举数值', () {
    test('DefLockMode / SubVolMode 数值逐字来自官方 FileBrowserUtil.js', () {
      expect(FileWormSubVolMode.normal, 1);
      expect(FileWormSubVolMode.enterprise, 2);
      expect(FileWormSubVolMode.compliance, 3);
      expect(FileWormSubVolMode.normalPlus, 4);
      expect(FileWormDefLockMode.manual, 1);
      expect(FileWormDefLockMode.normal, 2);
      expect(FileWormDefLockMode.immutable, 3);
      expect(FileWormDefLockMode.appendable, 4);
      expect(FileWormDefLockMode.autoLockEnabled(1), isFalse);
      expect(FileWormDefLockMode.autoLockEnabled(2), isFalse);
      expect(FileWormDefLockMode.autoLockEnabled(3), isTrue);
      expect(FileWormDefLockMode.autoLockEnabled(4), isTrue);
    });

    test('parseInner 只在 1500 + errors[] 时给结果', () {
      expect(
        FileWormPathStatus.parseInner(const {
          'error': {
            'code': 1500,
            'errors': [
              {'code': 0, 'path': '/x'},
            ],
          },
        }, outerCode: 1500)!.code,
        0,
      );
      expect(
        FileWormPathStatus.parseInner(const {
          'error': {'code': 1500},
        }, outerCode: 1500),
        isNull,
        reason: '没有 errors[] 就不是逐路径结果',
      );
      expect(
        FileWormPathStatus.parseInner(const {
          'error': {
            'code': 1500,
            'errors': [
              {'code': 0},
            ],
          },
        }, outerCode: 103),
        isNull,
        reason: '外层不是 1500 就不该走内层解析',
      );
    });
  });

  group('additional 编码 · v1 逗号 / v2 JSON 数组', () {
    // 真机（本会话，同一接口只改编码）：
    //   v1 + JSON 数组 → 502 + 11939 字节 HTML 错误页（不是错误码！）
    //   v2 + 逗号     → 200 但整块 additional 缺失（静默忽略）
    //   v1 + 逗号     → ✅ ；v2 + JSON 数组 → ✅
    List<String> jsonList(_Fake t) =>
        (jsonDecode(t.calls.last['additional'] as String) as List)
            .map((e) => '$e')
            .toList();

    test('v2：additional 是 JSON 数组（当前主路径）', () async {
      final (:fs, :t) = await _api();
      await fs.listFolder(folderPath: '/home');
      expect('${t.calls.last['version']}', '2');
      expect(t.calls.last['additional'], startsWith('['));
      expect(
        jsonList(t),
        containsAll([FileAdditional.size, FileAdditional.time]),
      );
    });

    test('v1：additional 必须逗号分隔、**不含 `[`**（v1 拒 JSON 数组）', () async {
      final (:fs, :t) = await _api(table: _v1Table());
      await fs.listFolder(folderPath: '/home');
      expect('${t.calls.last['version']}', '1');
      final a = t.calls.last['additional'] as String;
      expect(a, isNot(contains('[')), reason: 'v1 见 JSON 数组就回 HTML 错误页');
      expect(a, isNot(contains('"')));
      expect(
        a.split(','),
        containsAll([FileAdditional.size, FileAdditional.time]),
      );
    });

    test('六个调用点逐个：v1 一律逗号、v2 一律 JSON 数组', () async {
      final (fs: v1, t: t1) = await _api(table: _v1Table());
      final (fs: v2, t: t2) = await _api();

      Future<void> all(FileStationApi fs) async {
        await fs.listFolder(folderPath: '/home');
        await fs.listShares();
        await fs.getInfo('/home');
        await fs.listVirtualFolders();
        await fs.listFavorites();
        await fs.searchResults(taskId: 'bogus');
      }

      await all(v1);
      final v1Additional = [
        for (final c in t1.calls) c['additional'] as String,
      ];
      expect(v1Additional, hasLength(6));
      for (final a in v1Additional) {
        expect(a, isNot(contains('[')), reason: 'v1 只认逗号分隔');
      }

      await all(v2);
      final v2Additional = [
        for (final c in t2.calls) c['additional'] as String,
      ];
      expect(v2Additional, hasLength(6));
      for (final a in v2Additional) {
        expect(a, startsWith('['), reason: 'v2 只认 JSON 数组（逗号会被静默忽略）');
      }
    });
  });

  group('D · Search.History 补缺（v1）', () {
    test('searchHistory 的"无参 get"形态真机已验证（保留）', () async {
      final (:fs, :t) = await _api();
      t.responses['SYNO.FileStation.Search.History.get'] = const {
        'history': ['report', 'photo'],
        'total': 2,
      };
      expect(await fs.searchHistory(), ['report', 'photo']);
      final c = t.calls.single;
      expect(c['method'], 'get');
      expect('${c['version']}', '1');
      // 真机：补 offset/limit/search_type 后回包逐字不变 ⇒ 不补
      expect(c.containsKey('offset'), isFalse);
      expect(c.containsKey('search_type'), isFalse);
    });

    test('clearSearchHistory 发官方 search_type（simple/advance）', () async {
      final (:fs, :t) = await _api();
      await fs.clearSearchHistory();
      expect(t.calls.last['method'], 'delete');
      expect('${t.calls.last['version']}', '1');
      expect(t.calls.last['search_type'], 'simple');

      await fs.clearSearchHistory(type: FileSearchHistoryType.advance);
      expect(t.calls.last['search_type'], 'advance');
    });
  });

  group('PhotoUpload · upload（APK 线参 + 真机复核）', () {
    test('参数形态逐字来自 DSfile 4.17.2-609 uploadInternal', () async {
      final (:fs, :t) = await _api();
      t.responses['SYNO.FileStation.PhotoUpload.upload'] = const {
        'blSkip': false,
        'file': 'p.jpg',
        'pid': 31101,
        'progress': 1,
      };
      final f = _tmpFile('p.jpg', 24);
      final res = await fs.photoUpload(
        folderPath: '/home/Photos',
        filePath: f.path,
        fileName: 'p.jpg',
        mimeType: 'image/jpeg',
        mtimeMs: 1789000000000,
      );

      final u = t.uploads.single;
      expect(u['path'], contains('entry.cgi'));
      // `_sid` 挂查询串（multipart 表单体里放 _sid 不认 → 119）
      expect((u['query'] as Map).containsKey('_sid'), isTrue);
      final fields = u['fields'] as Map;
      expect(fields['api'], 'SYNO.FileStation.PhotoUpload');
      expect(fields['method'], 'upload');
      expect('${fields['version']}', '3');
      expect(fields['path'], '/home/Photos');
      expect(fields['create_parents'], 'false', reason: '官方发字符串 "false"');
      expect('${fields['size']}', '24');
      expect('${fields['mtime']}', '1789000000000');
      // PhotoUpload 永不发 v1 的 `dest_folder_path`
      expect(fields.containsKey('dest_folder_path'), isFalse);
      expect(u['fileField'], 'file', reason: '字段名逐字是 "file"');
      expect(u['mimeType'], 'image/jpeg');

      expect(res.fileName, 'p.jpg');
      expect(res.pid, 31101);
      expect(res.progress, 1);
      expect(res.skipped, isFalse);
    });

    test('冲突策略按版本给枚举串（v3 = overwrite/skip/rename）', () async {
      final (:fs, :t) = await _api();
      final f = _tmpFile('p.jpg', 8);
      await fs.photoUpload(
        folderPath: '/home',
        filePath: f.path,
        fileName: 'p.jpg',
        conflict: UploadConflictPolicy.skip,
      );
      expect(
        (t.uploads.single['fields'] as Map)['overwrite'],
        UploadConflictPolicy.skip.v3Value,
      );
      // 没有冲突时整段不发（与既有 upload 的约定一致）
      await fs.photoUpload(
        folderPath: '/home',
        filePath: f.path,
        fileName: 'p.jpg',
      );
      expect(
        (t.uploads.last['fields'] as Map).containsKey('overwrite'),
        isFalse,
      );
    });

    test('缩略图部分按各自的 field 名追加（官方 appendThumbnailBody）', () async {
      final (:fs, :t) = await _api();
      final f = _tmpFile('p.jpg', 8);
      final th = _tmpFile('thumb.png', 4);
      await fs.photoUpload(
        folderPath: '/home',
        filePath: f.path,
        fileName: 'p.jpg',
        thumbnailFiles: [
          MultipartUploadFile(
            field: 'thumb',
            path: th.path,
            fileName: 'thumb.png',
          ),
        ],
      );
      expect(t.uploads.single['files'], ['thumb:thumb.png']);
    });

    test('读不到本地文件 ⇒ 明确报错，不是静默', () async {
      final (:fs, :t) = await _api();
      await expectLater(
        fs.photoUpload(
          folderPath: '/home',
          filePath: '/definitely/not/here.jpg',
          fileName: 'x.jpg',
        ),
        throwsA(isA<DsmApiException>()),
      );
      expect(t.uploads, isEmpty);
    });

    test('FilePhotoUploadResult 的解析与默认值', () {
      expect(FilePhotoUploadResult.fromJson(const {}).pid, isNull);
      expect(FilePhotoUploadResult.fromJson(const {}).skipped, isFalse);
      final r = FilePhotoUploadResult.fromJson(const {
        'blSkip': true,
        'file': 'a.jpg',
        'pid': '7',
        'progress': '2',
      });
      expect(r.skipped, isTrue);
      expect(r.fileName, 'a.jpg');
      expect(r.pid, isNull, reason: '字符串 pid 不硬解析（真机回数字）');
    });
  });
}
