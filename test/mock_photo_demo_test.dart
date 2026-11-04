// `tool/mock_dsm/mock_photo_demo.dart`（可写内存相册库）的离线用例。
//
// 为什么要有这一档（第 325 轮）：相册模块在 Mock Server 上**原来一条夹具都没有**
// ⇒ 「上传照片」成功没有**跨进程**意义上的判据。这个文件把内存库的语义逐条钉住
// （字段名对得上客户端 DTO、上传的**字节数/时间**真的进了列表、被拒的请求
// 不许留下半条、同名三种 `duplicate` 语义、分页与排序、缩略图走二进制夹具），
// 它是 macOS 集成测试那一档的**前置证据**。
import 'package:flutter_test/flutter_test.dart';
import 'package:synhub/src/data/dto/foto_dto.dart';

import '../tool/mock_dsm/mock_dsm_core.dart';
import '../tool/mock_dsm/mock_photo_demo.dart';

/// 起一台装了相册内存库的 backend + 取库引用。
({
  MockDsmBackend b,
  MockPhotoLibrary db,
  String sid,
  MockDsmResponse Function(String, String, Map<String, dynamic>) call,
})
_boot({MockPhotoLibrary? seeded, bool smart = false}) {
  final b = MockDsmBackend(catalog: DsmCatalog.load());
  // ★ 走 `backend.handle(...)`（与真机同一条入口：目录校验 + 版本 + 方法表 +
  //   authLevel 都过一遍），**不要**直接摸 `fixtures` —— 那样"夹具注册对了但
  //   目录里版本对不上"这类缺陷就测不出来。
  final sid = b.login(username: 'mockuser', admin: false);
  final db = b.installPhotoDemo(library: seeded, smartAlbumDemo: smart);

  /// ★ 版本按目录协商（`Browse.Item` 的 maxVersion 是 7、`Upload.Item` 是 8、
  ///   `Thumbnail` 是 2）—— 仪器自己也要按方法表谈版本（AGENTS §2.0.15 的同族）。
  int versionFor(String api, String method) {
    final spec = b.catalog.apis[api];
    if (spec == null) return 1;
    for (var v = spec.maxVersion; v >= spec.minVersion; v--) {
      if (spec.methods[v]?.contains(method) ?? false) return v;
    }
    return spec.maxVersion;
  }

  MockDsmResponse call(
    String api,
    String method,
    Map<String, dynamic> p, {
    int? version,
  }) => b.handle('entry.cgi', {
    'api': api,
    'method': method,
    'version': version ?? versionFor(api, method),
    '_sid': sid,
    ...p,
  });
  return (b: b, db: db, sid: sid, call: call);
}

Map<String, dynamic> _data(MockDsmResponse r) =>
    Map<String, dynamic>.from(r.json['data'] as Map);

List<Map<String, dynamic>> _items(MockDsmResponse r) => [
  for (final e in (_data(r)['list'] as List)) Map<String, dynamic>.from(e as Map),
];

void main() {
  test('① 种子时间轴：根键是 `list`、字段名与客户端 DTO 一致、默认降序', () {
    final h = _boot();
    final r = h.call('SYNO.Foto.Browse.Item', 'list', {
      'offset': '0',
      'limit': '100',
    });
    expect(r.ok, isTrue);
    final list = _items(r);
    expect(list, hasLength(2), reason: '种子是两张（一图一视频）');
    // 逐字核对客户端 `FotoItemDto.fromJson` **真的会读**的那些键
    final first = list.first;
    expect(first['id'], isNotEmpty);
    expect(first['filename'], isNotEmpty);
    expect(first['filesize'], isA<int>());
    expect(first['time'], isA<int>());
    expect(first['folder_id'], isNotEmpty);
    expect(first['type'], isA<String>());
    final thumb = (first['additional'] as Map)['thumbnail'] as Map;
    expect(thumb['sm'], 'ready', reason: '不 ready 客户端就不会去取图');
    expect(thumb['cache_key'], isNotEmpty);
    expect(thumb['unit_id'], first['id']);
    // 默认降序：`time` 从大到小
    expect(
      (list[0]['time'] as int) >= (list[1]['time'] as int),
      isTrue,
      reason: '默认 sort_direction=desc',
    );
  });

  test('② 夹具能被**真 DTO** 解析（字段名写错这条会红）', () {
    final h = _boot();
    final r = h.call('SYNO.Foto.Browse.Item', 'list', {});
    final dto = FotoItemDto.fromJson(_items(r).first);
    expect(dto.id, isNotEmpty);
    expect(dto.filename, isNotEmpty);
    expect(dto.filesize, greaterThan(0));
    expect(dto.thumb.sm, 'ready');
    expect(dto.thumb.hasAny, isTrue);
    expect(dto.kind, isNotNull);
  });

  test('③ `Upload.Item/upload` 之后**列表里多一条**，且 filesize/time 是记账值', () {
    final h = _boot();
    final before = _items(h.call('SYNO.Foto.Browse.Item', 'list', {})).length;
    final bytes = List<int>.generate(1234, (i) => (i * 31) % 256);
    final up = h.call('SYNO.Foto.Upload.Item', 'upload', {
      'name': '"r325 上传.jpg"',
      'mtime': '1700000123',
      'duplicate': '"rename"',
      'uploadDestination': '"timeline"',
      'folder': '["PhotoLibrary"]',
      '__files': [
        {'name': 'r325 上传.jpg', 'bytes': bytes},
      ],
    });
    expect(up.ok, isTrue);
    expect(_data(up)['id'], isNotEmpty, reason: '客户端读 id/item_id/unit_id');
    final after = _items(h.call('SYNO.Foto.Browse.Item', 'list', {}));
    expect(after, hasLength(before + 1), reason: '判据取 list 回读，不取响应体');
    final made = after.firstWhere((e) => e['filename'] == 'r325 上传.jpg');
    expect(made['filesize'], bytes.length);
    expect(made['time'], 1700000123, reason: '`mtime` 是秒，服务端按秒记账');
    expect(made['folder_id'], 'folder_1');
  });

  test('④ 收到的**字节**与发出的一致（含 0x00/0xFF，二进制安全）', () {
    final h = _boot();
    final bytes = <int>[0, 255, 13, 10, 0, 26, 45, 45, 255];
    h.call('SYNO.Foto.Upload.Item', 'upload', {
      'name': '"bin.png"',
      'mtime': '1700000200',
      '__files': [
        {'name': 'bin.png', 'bytes': bytes},
      ],
    });
    final made = h.db.all.firstWhere((i) => i.filename == 'bin.png');
    expect(made.bytes, equals(bytes), reason: '内存库里的字节必须逐字节相等');
    expect(made.filesize, bytes.length);
  });

  test('⑤ 缺 `name` / 缺文件 ⇒ 114，且**不留下半条**', () {
    final h = _boot();
    final before = h.db.all.length;
    final noName = h.call('SYNO.Foto.Upload.Item', 'upload', {
      'mtime': '1700000300',
      '__files': [
        {'name': 'x.png', 'bytes': <int>[1, 2, 3]},
      ],
    });
    expect(noName.ok, isFalse);
    expect(noName.errorCode, 114);
    final noFile = h.call('SYNO.Foto.Upload.Item', 'upload', {
      'name': '"x.png"',
      'mtime': '1700000300',
    });
    expect(noFile.errorCode, 114);
    // `mtime` 缺失/为 0 也是参数不全（时间戳是服务端排序的依据）
    final noTime = h.call('SYNO.Foto.Upload.Item', 'upload', {
      'name': '"x.png"',
      '__files': [
        {'name': 'x.png', 'bytes': <int>[1, 2, 3]},
      ],
    });
    expect(noTime.errorCode, 114);
    expect(h.db.all, hasLength(before), reason: '被拒的请求不许改状态');
  });

  test('⑥ `duplicate` 三种语义：rename 改名 / overwrite 替换 / ignore 丢弃', () {
    final h = _boot();
    List<int> bytes(int n) => List<int>.filled(n, 7);
    Map<String, dynamic> req(String dup, int n, int mtime) => {
      'name': '"dup.png"',
      'mtime': '$mtime',
      'duplicate': '"$dup"',
      '__files': [
        {'name': 'dup.png', 'bytes': bytes(n)},
      ],
    };
    expect(h.call('SYNO.Foto.Upload.Item', 'upload', req('rename', 10, 1700000400)).ok, isTrue);
    expect(h.call('SYNO.Foto.Upload.Item', 'upload', req('rename', 20, 1700000401)).ok, isTrue);
    final renamed = h.db.all.where((i) => i.filename.startsWith('dup')).toList();
    expect(renamed.map((i) => i.filename), containsAll(<String>['dup.png', 'dup (1).png']));
    // overwrite：同名替换（总数不涨，字节换成新的）
    final n1 = h.db.all.length;
    expect(h.call('SYNO.Foto.Upload.Item', 'upload', req('overwrite', 33, 1700000402)).ok, isTrue);
    expect(h.db.all, hasLength(n1), reason: 'overwrite 不新增条目');
    final dup = h.db.all.where((i) => i.filename == 'dup.png').toList();
    expect(dup, hasLength(1));
    expect(dup.first.filesize, 33);
    // ignore：同名 ⇒ 官方视为"已存在"
    final n2 = h.db.all.length;
    final ignored = h.call('SYNO.Foto.Upload.Item', 'upload', req('ignore', 44, 1700000403));
    expect(ignored.ok, isFalse);
    expect(ignored.errorCode, 414);
    expect(h.db.all, hasLength(n2));
  });

  test('⑦ `offset`/`limit` 分页与 `sort_direction=asc`', () {
    final h = _boot();
    final all = _items(h.call('SYNO.Foto.Browse.Item', 'list', {}));
    final page = _items(
      h.call('SYNO.Foto.Browse.Item', 'list', {'offset': '1', 'limit': '1'}),
    );
    expect(page, hasLength(1));
    expect(page.first['id'], all[1]['id'], reason: 'offset 是"已加载条数"');
    final asc = _items(
      h.call('SYNO.Foto.Browse.Item', 'list', {'sort_direction': '"asc"'}),
    );
    expect(asc.first['id'], all.last['id']);
  });

  test('⑧ `empty()` 的起点是"列表为空"（0 条也要能判）', () {
    final h = _boot(seeded: MockPhotoLibrary.empty());
    final r = h.call('SYNO.Foto.Browse.Item', 'list', {});
    expect(_items(r), isEmpty);
    expect(_data(r)['total'], 0);
  });

  test('⑩ `Setting.User/get` 下发 desc（不注册的话客户端 DTO 回落 asc）', () {
    final h = _boot();
    final r = h.call('SYNO.Foto.Setting.User', 'get', {});
    expect(r.ok, isTrue);
    final dto = FotoSettingDto.fromJson(_data(r));
    expect(dto.itemSortBy, 'takentime');
    expect(
      dto.sortDirection,
      'desc',
      reason: '仪器约定：新上传的照片要排在最前（否则像素上看不出变化）',
    );
    expect(dto.canViewTeamSpace, isFalse, reason: '普通用户的 team_space 是 none');
  });

  test('⑨ 缩略图走**二进制**夹具：回真 PNG 字节（不是 JSON 信封）', () {
    final h = _boot();
    final spec = h.b.catalog.apis['SYNO.Foto.Thumbnail'];
    expect(spec, isNotNull, reason: '目录里没有这条就说明 api 名写错了');
    final raw = h.b.handleRaw('entry.cgi', {
      'api': 'SYNO.Foto.Thumbnail',
      'method': 'get',
      'version': '2',
      '_sid': h.sid, // ★ 真实会话（0.38/119 的教训：二进制接口同样要过 authLevel）
      'id': 'photo_1',
      'type': 'unit',
      'size': 'sm',
    });
    expect(raw.ok, isTrue, reason: 'errorCode=${raw.errorCode} note=${raw.note}');
    expect(raw.contentType, 'image/png');
    // PNG 魔数：89 50 4E 47 0D 0A 1A 0A
    expect(raw.bytes.take(4).toList(), <int>[0x89, 0x50, 0x4E, 0x47]);
    expect(raw.bytes.length, greaterThan(50));
  });

  // ---- ★ 第 328 轮：`upload_to_folder` 与 `Browse.Folder/list` ----
  //
  // 为什么补：r325 只接了时间轴的 `upload`，`upload_to_folder` 在 Mock 上
  // **没有夹具** ⇒ "落进哪个文件夹"无从判定。这一组把目标目录语义钉住：
  // 合法目录 ⇒ 条目带对的 `folder_id`；缺目录 ⇒ 114；目录不存在 ⇒ 117。
  test('⑪ `Browse.Folder/list` 回的 id 是**真存在**的目录（upload_to_folder 的闸门）', () {
    final h = _boot();
    final r = h.call('SYNO.Foto.Browse.Folder', 'list', {'id': '0'});
    final folders = _items(r);
    expect(folders, isNotEmpty, reason: '根目录必须有文件夹夹具');
    for (final f in folders) {
      expect(
        h.db.hasFolder('${f['id']}'),
        isTrue,
        reason: '`${f['id']}` 必须通过 hasFolder（否则上传会被 117 拒）',
      );
    }
    // 真 DTO 解析（字段名写错这条会红）
    final dto = FotoFolderDto.fromJson(folders.first);
    expect(dto.id, isNotEmpty);
    expect(dto.name, isNotEmpty);
    expect(dto.covers, isNotEmpty, reason: 'D26：封面候选要在 additional.thumbnail 里');
  });

  test('⑫ `upload_to_folder` 落进**指定**目录（判据是回读的 folder_id）', () {
    final h = _boot();
    final bytes = List<int>.generate(57, (i) => (i * 7) % 256);
    final up = h.call('SYNO.Foto.Upload.Item', 'upload_to_folder', {
      'name': '"r328 folder.jpg"',
      'mtime': '1700000456',
      'duplicate': '"rename"',
      // 客户端把数字串按**裸数字**发（官方状态里 folder id 是 number）
      'target_folder_id': 'folder_2',
      '__files': [
        {'name': 'r328 folder.jpg', 'bytes': bytes},
      ],
    });
    expect(up.ok, isTrue);
    // ① 只在该目录的回读里出现
    final inFolder = _items(
      h.call('SYNO.Foto.Browse.Item', 'list', {'folder_id': '"folder_2"'}),
    );
    final made = inFolder.where((e) => e['filename'] == 'r328 folder.jpg').toList();
    expect(made, hasLength(1), reason: '★ 判据取 list 回读');
    expect(made.first['filesize'], bytes.length);
    expect(made.first['folder_id'], 'folder_2', reason: '★ 必须落进**指定**目录');
    // ② 反向：另一个目录的回读里**不该**有它（否则判据是假的）
    final other = _items(
      h.call('SYNO.Foto.Browse.Item', 'list', {'folder_id': '"folder_1"'}),
    );
    expect(
      other.where((e) => e['filename'] == 'r328 folder.jpg'),
      isEmpty,
      reason: '★ 成对断言：别的目录里不许出现（过滤真的生效）',
    );
  });

  test('⑬ `upload_to_folder` 的拒绝：缺目录 ⇒ 114、目录不存在 ⇒ 117、都不留半条', () {
    final h = _boot();
    final before = h.db.all.length;
    final missing = h.call('SYNO.Foto.Upload.Item', 'upload_to_folder', {
      'name': '"no-folder.jpg"',
      'mtime': '1700000457',
      '__files': [
        {'name': 'no-folder.jpg', 'bytes': <int>[1, 2, 3]},
      ],
    });
    expect(missing.ok, isFalse);
    expect(missing.json['error'], {'code': 114});

    final unknown = h.call('SYNO.Foto.Upload.Item', 'upload_to_folder', {
      'name': '"ghost.jpg"',
      'mtime': '1700000458',
      'target_folder_id': '"folder_nope"',
      '__files': [
        {'name': 'ghost.jpg', 'bytes': <int>[1, 2, 3]},
      ],
    });
    expect(unknown.ok, isFalse);
    expect(unknown.json['error'], {'code': 117});

    expect(h.db.all.length, before, reason: '★ 被拒的请求不许留下半条');
  });


  // ---- ★ 第 328 轮：`Browse.Item/delete`（相册删除的服务端语义）----
  //
  // 产品侧真有这条链（`photo_delete_undo.dart` → `FotoApi.deleteItems`），
  // 而 Mock 上它原来只是"未注册夹具 ⇒ 空 data" ⇒ 删除**没有机制量**。
  test('⑭ `Browse.Item/delete` 只删点名的那些（成对断言）', () {
    final h = _boot();
    final before = _items(h.call('SYNO.Foto.Browse.Item', 'list', {}));
    expect(before, hasLength(2), reason: '种子两条');
    final victim = '${before.first['id']}';
    final keep = '${before.last['id']}';

    final r = h.call('SYNO.Foto.Browse.Item', 'delete', {
      'id': '["$victim"]',
    });
    expect(r.ok, isTrue);
    final after = _items(h.call('SYNO.Foto.Browse.Item', 'list', {}));
    expect(after, hasLength(1), reason: '★ 只该少一条');
    expect(
      after.map((e) => '${e['id']}'),
      isNot(contains(victim)),
      reason: '被点名的必须没了',
    );
    expect(
      after.map((e) => '${e['id']}'),
      contains(keep),
      reason: '★ 成对断言：没点名的**必须还在**（否则是"删了全部"）',
    );

    // 未知 id：静默成功、一条都不少（官方对"删不存在的 id"不报错）
    final ghost = h.call('SYNO.Foto.Browse.Item', 'delete', {
      'id': '["photo_nope"]',
    });
    expect(ghost.ok, isTrue);
    expect(_items(h.call('SYNO.Foto.Browse.Item', 'list', {})), hasLength(1));

    // 空 id ⇒ 114（参数不全），且依然一条都不少
    final empty = h.call('SYNO.Foto.Browse.Item', 'delete', {'id': '[]'});
    expect(empty.ok, isFalse);
    expect(empty.json['error'], {'code': 114});
    expect(_items(h.call('SYNO.Foto.Browse.Item', 'list', {})), hasLength(1));
  });

  // ============================================================ ★ r436：人物 / 场景面
  //
  // 这一组钉的是 `--smart-album-demo` 这条**仪器画像**：`enable_person` /
  // `enable_concept` 为 true 时的请求形状与条目形态。它存在的理由有两个：
  //   ① 真 NAS 上人脸 / 场景识别是**管理员在 DSM 侧**的开关（本 App 无写入入口）
  //      ⇒ 这两个页面原来只能记"当前配置不可达"；画像可由本机 Mock 下发。
  //   ② **仪器123**：夹具 id 的**形态**必须与真机一致 —— `Person/list_face`
  //      的 `item_id` 官方是**数字数组**（客户端 `_intIds` 会把 `photo_1`
  //      这种非数字 id 静默丢掉 ⇒ 界面上人脸条数永远 `0`，看起来像产品缺陷）。
  //      下面 ⑰ 就是这条的守卫。

  test('⑮ 默认（未开画像）：`enable_person` / `enable_concept` 都是 false', () {
    final h = _boot();
    final d = _data(h.call('SYNO.Foto.Setting.User', 'get', {}));
    expect(d['enable_person'], isFalse);
    expect(d['enable_concept'], isFalse);
  });

  test('⑯ 开画像：人物名册形状能被**真 DTO** 解析，且 id 是数字文本', () {
    final h = _boot(smart: true);
    final d = _data(h.call('SYNO.Foto.Setting.User', 'get', {}));
    expect(d['enable_person'], isTrue, reason: '画像没切过来的话整条路验不到');
    expect(d['enable_concept'], isTrue);

    final people = _items(
      h.call('SYNO.Foto.Browse.Person', 'list', {
        'offset': '0',
        'limit': '30',
        'show_more': 'false',
        'show_hidden': 'false',
        'additional': '["thumbnail"]',
      }),
    );
    expect(people, hasLength(2));
    final dto = FotoPersonDto.fromJson(people.first);
    expect(dto.id, matches(RegExp(r'^\d+$')), reason: '人物 id 官方是数字文本');
    expect(dto.name, isNotEmpty);
    expect(dto.itemCount, greaterThan(0));
    expect(dto.cover, isNotNull, reason: '封面缩略对象要能被 DTO 认出');

    expect(_data(h.call('SYNO.Foto.Browse.Person', 'count', {}))['count'], 2);
  });

  test('⑰ ★ 仪器123：人物种子的条目 id **必须全是数字**（非数字 ⇒ 人脸条数静默 0）', () {
    final h = _boot(smart: true);
    final items = _items(
      h.call('SYNO.Foto.Browse.Item', 'list', {'person_id': '1'}),
    );
    expect(items, isNotEmpty);
    for (final e in items) {
      expect(
        '${e['id']}',
        matches(RegExp(r'^\d+$')),
        reason:
            '客户端 `personFaces` 会把 id 过 `_intIds`；夹具用 `photo_1` '
            '会让「人脸条数」永远 0 —— 那是**仪器不诚实**，不是产品缺陷',
      );
    }
    final faces = _items(
      h.call('SYNO.Foto.Browse.Person', 'list_face', {
        'person_id': '1',
        'item_id': '["9001","9002"]',
      }),
    );
    expect(faces, hasLength(2), reason: '客户端只取 `list.length`');
  });

  test('⑱ `person_id` / `concept_id` 都是**可选过滤**，互不串味', () {
    final h = _boot(smart: true);
    final all = _items(h.call('SYNO.Foto.Browse.Item', 'list', {}));
    final person = _items(
      h.call('SYNO.Foto.Browse.Item', 'list', {'person_id': '2'}),
    );
    expect(person, hasLength(1), reason: 'B. Li 名下 1 张');
    final scene = _items(
      h.call('SYNO.Foto.Browse.Item', 'list', {'concept_id': '1'}),
    );
    expect(scene, hasLength(2), reason: 'Beach 名下 2 张');
    expect(all, hasLength(3), reason: '不带过滤时是全部');
  });

  test('⑲ 场景名册形状能被真 DTO 解析；前缀联想只按前缀', () {
    final h = _boot(smart: true);
    final scenes = _items(
      h.call('SYNO.Foto.Browse.Concept', 'list', {
        'offset': '0',
        'limit': '30',
        'show_hidden': 'false',
        'additional': '["thumbnail"]',
      }),
    );
    expect(scenes, hasLength(1));
    final dto = FotoConceptDto.fromJson(scenes.first);
    expect(dto.name, 'Beach');
    expect(dto.type, 'concept');
    expect(dto.cover, isNotNull);

    expect(
      _items(h.call('SYNO.Foto.Browse.Person', 'suggest', {'name_prefix': 'A'})),
      hasLength(1),
    );
    expect(
      _items(
        h.call('SYNO.Foto.Browse.Person', 'suggest', {'name_prefix': 'zzz'}),
      ),
      isEmpty,
      reason: '成对断言：不匹配的前缀必须回空',
    );
  });
}
