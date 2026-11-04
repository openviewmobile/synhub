// **可写的内存相册**：让 Mock 也能"记住"相册模块的写动词（照片上传）。
//
// 为什么需要它（第 325 轮，macOS 写侧第四档）：
//   r319/r320–r324 已经把**文件站 / 下载站 / 笔记**的写动词接到可写内存上；
//   相册模块（`SYNO.Foto.*`）在 Mock Server 上**一条夹具都没有**
//   ⇒ 相册页只能走"未注册夹具 ⇒ `{'success':true,'data':{}}`"（§2.0.38 的契约），
//   于是「上传照片」成功没有**跨进程**意义上的判据（列表里永远 0 条）。
//
// 做法：把 `Browse.Item.list` 与 `Upload.Item.upload` 接到**同一个内存库**上，
//   于是「时间轴有种子照片 → 界面选文件上传 → 另一个 HTTP 客户端回读
//   `Browse.Item/list` 看到新条目、且 `filesize` 等于真字节数」是一条真链路。
//
// ★ 字段名逐字对齐客户端消费方 `lib/src/data/dto/foto_dto.dart`
//   （`FotoItemDto.fromJson` / `FotoThumbDto.fromJson`）：
//   条目根键是 `id` / `filename` / `filesize` / `time`(秒) / `indexed_time` /
//   `folder_id` / `type` / `owner_user_id` / `album_ids` / `live_type`，
//   缩略图状态在 **`additional.thumbnail`**（`sm`/`m`/`xl`/`preview`/`cache_key`
//   /`unit_id`），收藏在 `additional.favorite`、评分在 `additional.rating`；
//   **列表根键是 `list`**（`FotoApi._list` 逐字读 `data['list']`）。
// ★ `Upload.Item/upload` 的请求体是 `multipart/form-data`（服务端已解析，
//   文件挂在 `__files` 上），字段值是**官方 `RO` 规则**：除 api/method/version
//   外每个值都 `JSON.stringify` ⇒ `name` 是**带引号的 JSON 串**，
//   `mtime` 是**秒**（`Math.round(lastModified/1e3)`）。
// ★ 时间轴还需要缩略图才画得出格子：`Thumbnail:get` 走**二进制**夹具
//   （`rawFixture`），这里回一张 1×1 的确定性 PNG（够证明"取图这条路通了"）。
// ★ 一切都在内存里，进程退出即消失；**不碰**真 NAS、不碰磁盘。
import 'dart:convert';

import 'mock_ds_demo.dart';
import 'mock_dsm_core.dart';

/// 内存库里的一张照片/一段视频。
class MockPhotoItem {
  MockPhotoItem({
    required this.id,
    required this.filename,
    required this.filesize,
    required this.time,
    this.type = 'photo',
    this.folderId = '',
    this.ownerUserId = 'mock-user',
    this.favorite = false,
    this.rating = 0,
    this.bytes,
    this.personId = '',
  });

  final String id;
  final String filename;
  final int filesize;
  final int time;
  final String type;
  final String folderId;
  final String ownerUserId;
  final bool favorite;
  final int rating;

  /// ★ r436：这张照片被索引到哪个人物下（`Browse.Person` 的 `id` 文本）。
  /// 空串 = 没有人物标签（人物页里的"未分类"就是这一档）。
  final String personId;

  /// **真实收到的字节**（只有上传进来的条目才有；种子条目为 `null`）。
  ///
  /// 判据用它：接口回读的 `filesize` 是我们记的账，真伪靠单测直接比字节。
  final List<int>? bytes;
}

/// 一个极小的内存相册库。
class MockPhotoLibrary {
  MockPhotoLibrary._(this._items, this._seq);

  /// 种子里放**两张照片 + 一段视频**（时间轴要能画出格子，也能看到类型差异）。
  factory MockPhotoLibrary.seeded() {
    final now =
        DateTime.now().millisecondsSinceEpoch ~/
        Duration.millisecondsPerSecond;
    return MockPhotoLibrary._(<MockPhotoItem>[
      MockPhotoItem(
        id: 'photo_1',
        filename: 'mock seeded photo.jpg',
        filesize: 2048,
        time: now - 7200,
        folderId: 'folder_1',
      ),
      MockPhotoItem(
        id: 'photo_2',
        filename: 'mock seeded video.mp4',
        filesize: 4096,
        time: now - 3600,
        type: 'video',
        folderId: 'folder_1',
      ),
    ], 2);
  }

  /// ★ r436：**人物面**用的种子。与 [seeded] 的唯一差别是 **id 形态**：
  /// `Person/list_face` 的 `item_id` 官方是**数字数组**，客户端 `_intIds`
  /// 会把 `photo_1` 这种非数字 id **静默丢掉** ⇒ 人脸条数显示 `0`，
  /// 看起来像产品缺陷，其实是夹具不诚实（**仪器123**）。
  /// 真机上 NAS 的照片 id 本来就是数字，所以这里用 `9001…`。
  factory MockPhotoLibrary.seededPersons() {
    final now =
        DateTime.now().millisecondsSinceEpoch ~/
        Duration.millisecondsPerSecond;
    return MockPhotoLibrary._(<MockPhotoItem>[
      MockPhotoItem(
        id: '9001',
        filename: 'mock seeded photo.jpg',
        filesize: 2048,
        time: now - 7200,
        folderId: 'folder_1',
        personId: '1',
      ),
      MockPhotoItem(
        id: '9002',
        filename: 'mock seeded person extra.jpg',
        filesize: 1024,
        time: now - 5400,
        folderId: 'folder_1',
        personId: '1',
      ),
      MockPhotoItem(
        id: '9003',
        filename: 'mock seeded video.mp4',
        filesize: 4096,
        time: now - 3600,
        type: 'video',
        folderId: 'folder_1',
        personId: '2',
      ),
    ], 3);
  }

  /// 只有库、没有任何条目（"列表里没有"要从空这个起点判）。
  factory MockPhotoLibrary.empty() => MockPhotoLibrary._(<MockPhotoItem>[], 0);

  final List<MockPhotoItem> _items;
  int _seq;

  /// 相册文件夹（`Browse.Folder/list` 的根目录内容）。
  ///
  /// ★ 第 328 轮新增：`Upload.Item/upload_to_folder` 需要**真实存在的目标目录 id**
  /// 才谈得上"落进哪个文件夹"这条判据（之前连一条文件夹夹具都没有）。
  static const Map<String, String> seedFolders = {
    'folder_1': 'Backup',
    'folder_2': 'Trips',
  };

  /// 目标目录是否存在（`upload_to_folder` 的合法性闸门）。
  bool hasFolder(String id) => seedFolders.containsKey(id);

  /// 删掉这些 id（`Browse.Item/delete` 的服务端语义：**只动点名的那些**）。
  ///
  /// 返回真正删掉的条数（未知 id 不计；官方对"删不存在的 id"也是静默成功）。
  int removeIds(Iterable<String> ids) {
    final want = ids.toSet();
    final before = _items.length;
    _items.removeWhere((i) => want.contains(i.id));
    return before - _items.length;
  }

  /// 时间轴的默认序（拍摄时间**降序**，与官方 `sort_direction=desc` 一致）。
  List<MockPhotoItem> get items {
    final out = List<MockPhotoItem>.from(_items);
    out.sort((a, b) => b.time.compareTo(a.time));
    return out;
  }

  List<MockPhotoItem> get all => List<MockPhotoItem>.unmodifiable(_items);

  bool hasName(String filename) => _items.any((i) => i.filename == filename);

  /// 落一条**上传**进来的照片。
  ///
  /// [duplicate] 照官方语义：`rename`（默认，同名改 `name (1).ext`）/
  /// `overwrite`（替换同名）/ `ignore`（同名就丢弃）。
  MockPhotoItem? add({
    required String filename,
    required List<int> bytes,
    required int time,
    String duplicate = 'rename',
    String type = 'photo',
    String folderId = 'folder_1',
  }) {
    if (filename.isEmpty) return null;
    final existing = _items.indexWhere((i) => i.filename == filename);
    if (existing >= 0) {
      switch (duplicate) {
        case 'ignore':
          return null;
        case 'overwrite':
          _items.removeAt(existing);
        default:
          filename = _renamed(filename);
      }
    }
    _seq++;
    final made = MockPhotoItem(
      id: 'photo_up$_seq',
      filename: filename,
      filesize: bytes.length,
      time: time,
      type: type,
      folderId: folderId,
      bytes: List<int>.from(bytes),
    );
    _items.add(made);
    return made;
  }

  /// `a.jpg` → `a (1).jpg`（官方 `duplicate:rename` 的形态；不覆盖原文件）。
  String _renamed(String name) {
    final dot = name.lastIndexOf('.');
    final base = dot > 0 ? name.substring(0, dot) : name;
    final ext = dot > 0 ? name.substring(dot) : '';
    var n = 1;
    while (hasName('$base ($n)$ext')) {
      n++;
    }
    return '$base ($n)$ext';
  }
}

/// 1×1 的深蓝色 PNG（67 B）—— `Thumbnail:get` 的二进制夹具用它。
///
/// 为什么不是"随便回点字节"：相册网格会把它交给 `Image` 解码，
/// 回非图片字节会在界面上变成 decode 失败（那种"渲染失败"会污染像素判据）。
const String _kOnePxPngB64 =
    'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNk'
    'YPhfDwAChwGA60e6kgAAAABJRU5ErkJggg==';

extension MockPhotoLibraryDemo on MockDsmBackend {
  /// 装上内存相册库并注册夹具；返回库本体（服务端横幅/用例可读）。
  MockPhotoLibrary installPhotoDemo({
    MockPhotoLibrary? library,
    bool smartAlbumDemo = false,
  }) {
    final db =
        library ??
        (smartAlbumDemo
            ? MockPhotoLibrary.seededPersons()
            : MockPhotoLibrary.seeded());

    Map<String, dynamic> itemJson(MockPhotoItem i) => {
      'id': i.id,
      'filename': i.filename,
      'filesize': i.filesize,
      'time': i.time,
      // ★ `indexed_time` 官方单位是**毫秒**（客户端 `fInt` 直读；见
      //   `docs/photo-api-live.md` 的真机回包 1789950462 / 1789950898959）
      'indexed_time': i.time * Duration.millisecondsPerSecond,
      'folder_id': i.folderId,
      'type': i.type,
      'owner_user_id': i.ownerUserId,
      'album_ids': <int>[],
      'live_type': '',
      'additional': {
        // 三档都给 `ready` ⇒ 客户端 `bestSize` 取 `sm`，会真去请求缩略图
        'thumbnail': {
          'sm': 'ready',
          'm': 'ready',
          'xl': 'ready',
          'preview': 'broken',
          'cache_key': 'cache_${i.id}',
          'unit_id': i.id,
        },
        'favorite': i.favorite,
        'rating': i.rating,
      },
    };

    // ★ r436：场景表要**先于** `Item/list` 夹具声明（`concept_id` 过滤要读它）。
    const scenes = <String, String>{'1': 'Beach'};
    const sceneItems = <String, List<String>>{
      '1': ['9001', '9002'],
    };

    fixture('SYNO.Foto.Browse.Item', 'list', (p) {
      final offset = int.tryParse('${p['offset'] ?? '0'}') ?? 0;
      final limit = int.tryParse('${p['limit'] ?? '100'}') ?? 100;
      final direction = unquoteJson('${p['sort_direction'] ?? ''}');
      // `folder_id` 是**可选**过滤（`upload_to_folder` 的判据要看"落进了哪个文件夹"）。
      final wantFolder = unquoteJson('${p['folder_id'] ?? ''}');
      // ★ r436：`person_id` 也是可选过滤（人物相册页走 `Browse.Item/list{person_id}`）。
      final wantPerson = unquoteJson('${p['person_id'] ?? ''}');
      var rows = wantFolder.isEmpty
          ? db.items
          : db.items.where((i) => i.folderId == wantFolder).toList();
      if (wantPerson.isNotEmpty) {
        rows = rows.where((i) => i.personId == wantPerson).toList();
      }
      // ★ r436：`concept_id` 同理（场景相册页走 `Browse.Item/list{concept_id}`）。
      final wantConcept = unquoteJson('${p['concept_id'] ?? ''}');
      if (wantConcept.isNotEmpty) {
        final ids = sceneItems[wantConcept] ?? const <String>[];
        rows = rows.where((i) => ids.contains(i.id)).toList();
      }
      if (direction == 'asc') {
        rows = rows.reversed.toList();
      }
      final total = rows.length;
      final page = rows.skip(offset < 0 ? 0 : offset).take(limit < 0 ? 0 : limit);
      return {
        'success': true,
        'data': {
          'list': [for (final i in page) itemJson(i)],
          'total': total,
        },
      };
    });

    // ---- ★ 第 328 轮：`Browse.Item/delete`（相册删除）----
    //
    // 为什么必须补：产品侧**真的有**这条链（`photo_delete_undo.dart` →
    // `FotoApi.deleteItems`），而 Mock 上它是"未注册夹具 ⇒ 空 data"⇒
    // 「删掉的照片服务端不再返回」**在跨进程意义上不可判定**，
    // 而且残留会跨轮累积，破坏别的用例的前置条件（r328 实测：时间轴涨到 4 条后，
    // `photo-timeline-all-loaded` 锚点再也不出现 —— 看起来像相册缺陷，其实是仪器）。
    // `id` 与官方一样是 **JSON 数组文本**；未知 id 静默成功（只删点名的那些）。
    fixture('SYNO.Foto.Browse.Item', 'delete', (p) {
      final ids = stringList(p['id']);
      if (ids.isEmpty) {
        return {
          'success': false,
          'error': {'code': 114},
        };
      }
      db.removeIds(ids);
      return {
        'success': true,
        'data': {},
      };
    });

    fixture('SYNO.Foto.Upload.Item', 'upload', (p) {
      if (p['__multipartBroken'] == true) {
        // 体坏了 = 参数不全（不许回"空上传成功"）
        return {
          'success': false,
          'error': {'code': 114},
        };
      }
      final files = (p['__files'] as List?) ?? const [];
      if (files.isEmpty) {
        return {
          'success': false,
          'error': {'code': 114},
        };
      }
      // `name` 是官方 `RO` 规则下的 **JSON 串**（带引号）；缺了就是参数不全。
      final rawName = '${p['name'] ?? ''}';
      if (rawName.isEmpty) {
        return {
          'success': false,
          'error': {'code': 114},
        };
      }
      final name = unquoteJson(rawName);
      if (name.isEmpty) {
        return {
          'success': false,
          'error': {'code': 114},
        };
      }
      final mtime = int.tryParse('${p['mtime'] ?? ''}') ?? 0;
      if (mtime <= 0) {
        return {
          'success': false,
          'error': {'code': 114},
        };
      }
      final duplicate = unquoteJson('${p['duplicate'] ?? ''}');
      final made = db.add(
        filename: name,
        bytes: (files.first as Map)['bytes'] as List<int>? ?? const [],
        time: mtime,
        duplicate: duplicate.isEmpty ? 'rename' : duplicate,
      );
      if (made == null) {
        // `duplicate:ignore` + 同名 ⇒ 官方视为"已存在"，回 414
        return {
          'success': false,
          'error': {'code': 414},
        };
      }
      // 客户端读 `unit_id | item_id | id` 三选一
      // ★ 字段逐字对照官方 `UploadVo$UploadResult`（APK
      //   `com/synology/projectkailash/datasource/network/vo/UploadVo$UploadResult.smali`）：
      //   `id` / `unit_id` / `action` / `thumb_version` / `duplicate_hash`。
      //   客户端 `_uploadItem` 只读 `unit_id | item_id | id`，其余是**保真**用的。
      //   `item_id` 不是官方键（我方客户端的兜底名），留着不影响。
      return {
        'success': true,
        'data': {
          'id': made.id,
          'item_id': made.id,
          'unit_id': made.id,
          'action': 'upload',
          'thumb_version': 1,
          'duplicate_hash': '',
        },
      };
    });

    // ---- ★ 第 328 轮：`Upload.Item/upload_to_folder`（相册"上传到指定文件夹"）----
    //
    // 为什么补这一条：r325 只接了时间轴的 `Upload.Item/upload`，
    // `upload_to_folder` **在 Mock 上没有夹具** ⇒ 目标目录与"落进哪个文件夹"
    // 这条判据无从判定（R325 evidence §99 就明写"本轮不涉及"）。
    // 形态逐字对齐客户端 `FotoApi.uploadToFolder`（official `RO`+`RM`）：
    // `{file, duplicate, name, mtime(秒), target_folder_id}` —— 每个值都过 JSON.stringify，
    // 所以 `target_folder_id` 可能是**裸数字**、也可能是**带引号字符串**，
    // 判据一律先过 `unquoteJson`。
    fixture('SYNO.Foto.Upload.Item', 'upload_to_folder', (p) {
      if (p['__multipartBroken'] == true || (p['__files'] as List?)?.isEmpty != false) {
        return {
          'success': false,
          'error': {'code': 114},
        };
      }
      final rawName = '${p['name'] ?? ''}';
      final name = unquoteJson(rawName);
      final mtime = int.tryParse('${p['mtime'] ?? ''}') ?? 0;
      if (name.isEmpty || mtime <= 0) {
        return {
          'success': false,
          'error': {'code': 114},
        };
      }
      final rawFolder = '${p['target_folder_id'] ?? ''}';
      final folderId = unquoteJson(rawFolder);
      if (folderId.isEmpty) {
        // 少了目标目录 = 参数不全（**不是**"默认放根目录"）
        return {
          'success': false,
          'error': {'code': 114},
        };
      }
      if (!db.hasFolder(folderId)) {
        // 目标目录不存在 ⇒ 未知 id（与契约里"unknown id ⇒ 117"一致）
        return {
          'success': false,
          'error': {'code': 117},
        };
      }
      final duplicate = unquoteJson('${p['duplicate'] ?? ''}');
      final made = db.add(
        filename: name,
        bytes: (p['__files'] as List).first['bytes'] as List<int>? ?? const [],
        time: mtime,
        duplicate: duplicate.isEmpty ? 'rename' : duplicate,
        folderId: folderId,
      );
      if (made == null) {
        return {
          'success': false,
          'error': {'code': 414},
        };
      }
      return {
        'success': true,
        'data': {
          'id': made.id,
          'unit_id': made.id,
          'action': 'upload',
          'thumb_version': 1,
          'duplicate_hash': '',
        },
      };
    });

    // `Browse.Folder/list`（v1–2）：根目录下的相册文件夹。
    // ★ 夹具**必须是真实存在的 id**（`upload_to_folder` 的 117 闸门按它判）。
    //   封面（`additional.thumbnail`）给一条 `ready` 候选，用来同时覆盖
    //   D26 的"文件夹封面要真画出来"那条链（客户端 `pickFolderCover` 会选中它）。
    fixture('SYNO.Foto.Browse.Folder', 'list', (p) {
      final parent = unquoteJson('${p['id'] ?? '0'}');
      final rows = [
        for (final e in MockPhotoLibrary.seedFolders.entries)
          if (parent == '0' || parent.isEmpty)
            {
              'id': e.key,
              'name': e.value,
              'parent': '0',
              'shared': false,
              'owner_user_id': 'mock-user',
              'item_count': db.items.where((i) => i.folderId == e.key).length,
              'additional': {
                'thumbnail': [
                  {
                    'sm': 'ready',
                    'm': 'ready',
                    'xl': 'ready',
                    'preview': 'broken',
                    'cache_key': 'ck_${e.key}',
                    'unit_id':
                        db.items
                            .where((i) => i.folderId == e.key)
                            .map((i) => i.id)
                            .firstOrNull ??
                        '',
                  },
                ],
              },
            },
      ];
      return {
        'success': true,
        'data': {'list': rows, 'total': rows.length},
      };
    });

    // ★ 仪器约定（不是 DSM 契约的推断，是**本仪器主动给的一个明确值**）：
    //   官方 `Setting.User/get` 下发 `item_sort_by` / `sort_direction`；
    //   未注册夹具时客户端 DTO 会**回落到 `asc`**（`foto_dto.dart` 的默认值）
    //   ⇒ 时间轴会把最旧的排在最前面（新上传的照片沉到底部，像素看不出来）。
    //   这里下发官方的常见取值 `takentime` + `desc`，让"最新上传在最上"可判。
    fixture('SYNO.Foto.Setting.User', 'get', (p) {
      return {
        'success': true,
        'data': {
          'team_space_permission': 'none',
          // ★ r436：`--smart-album-demo` 时才置 true —— 于是"人物页在人脸识别关闭时
          //   只给引导态、开启后才请求 `Browse.Person`"这条**两态**都能在真机上验。
          'enable_person': smartAlbumDemo,
          'enable_concept': smartAlbumDemo,
          'enable_similar': false,
          'item_sort_by': 'takentime',
          'sort_direction': 'desc',
          'auto_generate_thumbnail': true,
          'date_format': 'yyyy-MM-dd',
        },
      };
    });

    // ---- ★ r436：`--smart-album-demo`：人物 / 场景这一面 ----
    //
    // 为什么要有它：真 NAS 的 `Setting.User/enable_person = false`（人脸识别是
    // **管理员在 DSM 侧**的开关，本 App 没有写入入口）⇒ `PhotoPersonAlbumPage`
    // 一直是"当前配置不可达"。r433 的做法**复用**在这里：换一条授权内的腿
    // （本机 Mock 下发画像），把"**开启之后**人物页与人物相册页到底画成什么样"
    // 这件事在真机上验掉。★ 真 NAS 零写入（只发生登录/登出，收尾还原）。
    if (smartAlbumDemo) {
      // 人物名册：id 是**数字文本**（`personItems` 会把 id 转 int 去请求）。
      const people = <String, String>{'1': 'A. Chen', '2': 'B. Li'};

      Map<String, dynamic> personJson(String id, String name) => {
        'id': id,
        'name': name,
        'item_count': db.items.where((i) => i.personId == id).length,
        'show': true,
        'type': 'person',
        'additional': {
          'thumbnail': {
            'sm': 'ready',
            'm': 'ready',
            'xl': 'ready',
            'preview': 'broken',
            'cache_key': 'ck_person_$id',
            'unit_id':
                db.items
                    .where((i) => i.personId == id)
                    .map((i) => i.id)
                    .firstOrNull ??
                '',
          },
        },
      };

      fixture('SYNO.Foto.Browse.Person', 'list', (p) {
        final rows = people.entries
            .map((e) => personJson(e.key, e.value))
            .toList();
        return {
          'success': true,
          'data': {'list': rows, 'total': rows.length},
        };
      });

      fixture('SYNO.Foto.Browse.Person', 'count', (p) {
        return {
          'success': true,
          'data': {'count': people.length},
        };
      });

      fixture('SYNO.Foto.Browse.Person', 'get', (p) {
        final want = stringList(p['id']).toSet();
        final rows = [
          for (final e in people.entries)
            if (want.isEmpty || want.contains(e.key))
              personJson(e.key, e.value),
        ];
        return {
          'success': true,
          'data': {'list': rows},
        };
      });

      // 前缀联想（官方钉死 v3）：只按**前缀**匹配，大小写不敏感。
      fixture('SYNO.Foto.Browse.Person', 'suggest', (p) {
        final prefix = unquoteJson('${p['name_prefix'] ?? ''}').toLowerCase();
        final rows = [
          for (final e in people.entries)
            if (prefix.isEmpty || e.value.toLowerCase().startsWith(prefix))
              personJson(e.key, e.value),
        ];
        return {
          'success': true,
          'data': {'list': rows},
        };
      });

      // 人脸条数（客户端只取 `list.length`）：为请求里点名的每张照片回一条脸。
      // ---- 场景（`Browse.Concept`）：官方与人物同形，只是 `type = concept` ----
      // ★ 场景与人物**同一档**：`enable_concept` 为 true 时才请求
      //   （关着的时候 `Scenes` 芯片根本不出现）。
      Map<String, dynamic> sceneJson(String id, String name) => {
        'id': id,
        'name': name,
        'item_count': (sceneItems[id] ?? const <String>[]).length,
        'show': true,
        'type': 'concept',
        'additional': {
          'thumbnail': {
            'sm': 'ready',
            'm': 'ready',
            'xl': 'ready',
            'preview': 'broken',
            'cache_key': 'ck_concept_$id',
            'unit_id': (sceneItems[id] ?? const <String>[]).firstOrNull ?? '',
          },
        },
      };

      fixture('SYNO.Foto.Browse.Concept', 'list', (p) {
        final rows = scenes.entries
            .map((e) => sceneJson(e.key, e.value))
            .toList();
        return {
          'success': true,
          'data': {'list': rows, 'total': rows.length},
        };
      });

      fixture('SYNO.Foto.Browse.Concept', 'count', (p) {
        return {
          'success': true,
          'data': {'count': scenes.length},
        };
      });

      fixture('SYNO.Foto.Browse.Concept', 'get', (p) {
        final want = stringList(p['id']).toSet();
        final rows = [
          for (final e in scenes.entries)
            if (want.isEmpty || want.contains(e.key)) sceneJson(e.key, e.value),
        ];
        return {
          'success': true,
          'data': {'list': rows},
        };
      });

      fixture('SYNO.Foto.Browse.Person', 'list_face', (p) {
        final ids = stringList(p['item_id']);
        final pid = '${p['person_id'] ?? ''}';
        return {
          'success': true,
          'data': {
            'list': [
              for (final id in ids)
                {'face_id': '$pid-$id', 'item_id': id},
            ],
          },
        };
      });
    }

    // 缩略图（`type=unit` / `type=sm` …）：回一张 1×1 PNG。
    // ★ 这是**二进制**接口 ⇒ 必须走 `rawFixture`，走 JSON 夹具会被 `Image` 当坏图。
    rawFixture('SYNO.Foto.Thumbnail', 'get', (p) {
      return MockRawResponse(
        base64Decode(_kOnePxPngB64),
        contentType: 'image/png',
      );
    });

    return db;
  }
}
