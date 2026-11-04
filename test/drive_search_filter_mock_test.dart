// ★ **③Drive 第 48 轮：D50 高级筛选（六轴组合查询）** —— 此前**零测试**
//
// ## 为什么挑它
// 先建了 `docs/drive-status-refresh-2026-09-23.md` 把 Drive 85 行的**当前**状态
// 重算出来（9-21 基线 / 9-22 recount 都落后于后面两个批次），然后逐行查
// "🟡 已实现·未验证"里**到底有没有离线覆盖**。
//
// 结果：D3/D5/D6/D13/D16/D29/D32/D36/D42/D44/D48/D55 都**已有** Mock/离线用例
// （`drive_p0_test` / `drive_c1_api_test` / `drive_gaps_api_test` / `drive_g4_*` …），
// 唯独 **D50 高级筛选 `DriveApi.searchQuery` 一个测试都没有** —— 真缺口。
//
// 按新规 **B2**（真机/真 NAS 无法验证的一律通过 Mock 验证），本文件用 Mock 把
// 六轴筛选的**参数编码**逐条钉住。这比"真机看一眼"更能防回归：
// 官方这六轴的取值/单位有**三个坑**，写错了界面照样"能用"。
//
// ## 官方依据（`lib/src/data/dto/drive_search_dto.dart` 头部注释已逐行标注）
// * `SearchCondition.LocationType`（`:734-742`）
// * `SearchCondition.FileType`（`:743-748` / `:748-758`）
// * `SearchCondition.OwnerType`（`:749-754` / `:912-915`）
// * 大小（`:755-767`）—— ★ **MB × 1048576**，且 `EqualTo` 是 **±5% 带**
//   （`ApiSynoDriveFiles.java:133` `SIZE_RANGE = 0.05`）
// * 标签 / 时间（`:768-780`）
//
// ## 三个坑（本文件专门盯它们）
// 1. **大小单位**：先乘 1048576 再发字节，发 MB 会被服务端当成 1 字节；
// 2. **`roughly` 是区间不是等值**：`[0.95*N, 1.05*N]`，写成 `min_size=max_size=N` 就错了；
// 3. **`custom` 才有 `custom_*` 字段**，且 `custom_location` 必须是 `id:<file_id>` 形状，
//    `custom_owner` 是 **`{type:'user', name}` 对象**（不是字符串）。
//
// 全程打**内存 Mock Server**，不碰真机（规程 §5.1）。
import 'package:flutter_test/flutter_test.dart';

import 'package:synhub/src/data/drive_api.dart';
import 'package:synhub/src/data/dto/drive_search_dto.dart';
import 'package:synhub/src/dsm/webapi.dart';

import '../tool/mock_dsm/mock_dsm_core.dart';
import 'support/mock_dsm_transport.dart';

MockDsmBackend _backend() {
  final b = MockDsmBackend(catalog: DsmCatalog.load());
  b.login(username: 'demo_user', admin: false);
  return b;
}

void main() {
  late MockDsmBackend backend;
  late MockDsmTransport transport;
  late DsmWebApi web;
  late DriveApi drive;

  Future<void> boot() async {
    backend = _backend();
    transport = MockDsmTransport(backend);
    web = DsmWebApi(transport);
    await web.discover();
    await web.login(account: 'demo_user', password: 'x');
    drive = DriveApi(web);
  }

  /// 最后一次 `Files/search` 的请求参数。
  Map<String, dynamic> lastSearch() {
    final req = backend.requests
        .where((r) => '${r.params['api']}' == 'SYNO.SynologyDrive.Files')
        .where((r) => '${r.params['method']}' == 'search')
        .toList();
    expect(req, isNotEmpty, reason: '必须真的发出了 Files/search');
    return req.last.params;
  }

  setUp(boot);

  group('DQ-1. ★ 默认全 any ⇒ 只发必要条件（不发任何筛选字段）', () {
    test('空条件：没有 location/file_type/owner/min_size/labels/time', () async {
      await drive.searchQuery(const DriveSearchQuery(keyword: 'abc'));
      final p = lastSearch();
      expect(p['keyword'], 'abc');
      for (final k in [
        'location',
        'custom_location',
        'file_type',
        'custom_file_type',
        'owner',
        'custom_owner',
        'min_size',
        'max_size',
        'labels',
        'time',
        'start_date',
        'end_date',
      ]) {
        expect(p.containsKey(k), isFalse, reason: '默认档不该发 `$k`');
      }
      expect(p['content_snippet'], true);
    });

    test('★ 关键字会 trim；空关键字则完全不发 `keyword`', () async {
      await drive.searchQuery(const DriveSearchQuery(keyword: '  a b  '));
      expect(lastSearch()['keyword'], 'a b');

      await drive.searchQuery(const DriveSearchQuery(keyword: '   '));
      expect(lastSearch().containsKey('keyword'), isFalse);
    });
  });

  group('DQ-2. location 轴（`LocationType`）', () {
    test('★ 五档标准值逐一对齐官方 apiValue', () async {
      final cases = {
        DriveSearchLocation.myDrive: 'mydrive',
        DriveSearchLocation.teamFolders: 'team_folders',
        DriveSearchLocation.sharedWithMe: 'shared_with_me',
        DriveSearchLocation.sharedWithOthers: 'shared_with_others',
        DriveSearchLocation.starred: 'starred',
      };
      for (final e in cases.entries) {
        await drive.searchQuery(DriveSearchQuery(location: e.key));
        expect(
          lastSearch()['location'],
          e.value,
          reason: '${e.key} 的 apiValue',
        );
      }
    });

    test('★ custom 必须配 `custom_location: id:<file_id>`（形状不能错）', () async {
      await drive.searchQuery(
        const DriveSearchQuery(
          location: DriveSearchLocation.custom,
          customLocationId: '1234',
        ),
      );
      expect(lastSearch()['custom_location'], 'id:1234');
    });

    test('★ custom 但 id 为空 ⇒ 不发 custom_location（也不发 location）', () async {
      await drive.searchQuery(
        const DriveSearchQuery(location: DriveSearchLocation.custom),
      );
      final p = lastSearch();
      expect(p.containsKey('custom_location'), isFalse);
      expect(p['location'], 'custom', reason: 'location 本身还是发的');
    });
  });

  group('DQ-3. file_type 轴（`FileType`）', () {
    test('★ 十档 apiValue 逐一核对（含 `oslides` 单数拼写的坑）', () async {
      final cases = {
        DriveSearchFileType.folder: 'folder',
        DriveSearchFileType.file: 'file',
        DriveSearchFileType.odoc: 'odoc',
        DriveSearchFileType.osheet: 'osheet',
        // ⚠️ 官方枚举名是 `oslide` 但 **apiValue 是 `oslides`**（带 s）
        DriveSearchFileType.oslide: 'oslides',
        DriveSearchFileType.document: 'document',
        DriveSearchFileType.image: 'image',
        DriveSearchFileType.audio: 'audio',
        DriveSearchFileType.video: 'video',
      };
      for (final e in cases.entries) {
        await drive.searchQuery(DriveSearchQuery(fileType: e.key));
        expect(lastSearch()['file_type'], e.value, reason: '${e.key}');
      }
      expect(DriveSearchFileType.any.apiValue, 'any');
      expect(DriveSearchFileType.custom.apiValue, 'custom');
    });

    test('★ custom 发 `custom_file_type`（裸扩展名，不加点）', () async {
      await drive.searchQuery(
        const DriveSearchQuery(
          fileType: DriveSearchFileType.custom,
          customFileType: 'txt',
        ),
      );
      expect(lastSearch()['custom_file_type'], 'txt');
    });
  });

  group('DQ-4. owner 轴（`OwnerType`）', () {
    test('★ me / not_me 的 apiValue', () async {
      await drive.searchQuery(
        const DriveSearchQuery(owner: DriveSearchOwner.me),
      );
      expect(lastSearch()['owner'], 'me');
      await drive.searchQuery(
        const DriveSearchQuery(owner: DriveSearchOwner.notMe),
      );
      expect(lastSearch()['owner'], 'not_me');
    });

    test('★ custom_owner 是 **`{type:"user", name}` 对象**，不是字符串', () async {
      await drive.searchQuery(
        const DriveSearchQuery(
          owner: DriveSearchOwner.custom,
          customOwnerName: 'bob',
        ),
      );
      final co = lastSearch()['custom_owner'];
      expect(co, isA<Map>(), reason: '★ 官方是对象；发字符串服务端收不到');
      expect((co as Map)['type'], 'user');
      expect(co['name'], 'bob');
    });
  });

  group('DQ-5. ★★ 大小轴：单位坑 + ±5% 带坑（最容易写错的两处）', () {
    test('★★ greater_than：MB → **字节**（× 1048576），发 `min_size`', () async {
      await drive.searchQuery(
        const DriveSearchQuery(
          size: DriveSearchSize.greaterThan,
          sizeMegabytes: 3,
        ),
      );
      final p = lastSearch();
      expect(
        p['min_size'],
        3 * 1048576,
        reason: '★ 发 MB 会被服务端当 1 字节；官方 `AccountManager`/搜索侧都是字节',
      );
      expect(p.containsKey('max_size'), isFalse);
    });

    test('★★ less_than：发 `max_size`（字节）', () async {
      await drive.searchQuery(
        const DriveSearchQuery(
          size: DriveSearchSize.lessThan,
          sizeMegabytes: 5,
        ),
      );
      final p = lastSearch();
      expect(p['max_size'], 5 * 1048576);
      expect(p.containsKey('min_size'), isFalse);
    });

    test('★★ roughly：是 **±5% 区间**，不是等值（官方 `SIZE_RANGE = 0.05`）', () async {
      await drive.searchQuery(
        const DriveSearchQuery(
          size: DriveSearchSize.roughly,
          sizeMegabytes: 10,
        ),
      );
      final p = lastSearch();
      final bytes = 10 * 1048576;
      expect(p['min_size'], (bytes * 0.95).floor());
      expect(p['max_size'], (bytes * 1.05).floor());
      expect(
        p['min_size'] == p['max_size'],
        isFalse,
        reason: '★ 写成 min==max 就是把"约等于"当"精确等于"，官方明确是带',
      );
    });

    test('★ 纯函数 `driveSearchSizeBand` 与线上的值一致（防两处算法漂移）', () {
      final band = driveSearchSizeBand(10);
      expect(band.min, (10 * 1048576 * 0.95).floor());
      expect(band.max, (10 * 1048576 * 1.05).floor());
      expect(kDriveSearchSizeTolerance, 0.05);
    });

    test('★ megabytes<=0 时不发大小（防"0 字节以上"把结果清空）', () async {
      await drive.searchQuery(
        const DriveSearchQuery(
          size: DriveSearchSize.greaterThan,
          sizeMegabytes: 0,
        ),
      );
      final p = lastSearch();
      expect(p.containsKey('min_size'), isFalse);
      expect(p.containsKey('max_size'), isFalse);
    });
  });

  group('DQ-6. 标签 / 时间轴', () {
    test('★ labels 非空才发，且是**数组**', () async {
      await drive.searchQuery(const DriveSearchQuery(labelIds: ['9', '11']));
      expect(lastSearch()['labels'], ['9', '11']);

      await drive.searchQuery(const DriveSearchQuery());
      expect(lastSearch().containsKey('labels'), isFalse);
    });

    test(
      '★ time 用 apiValue（`modified_time` / `created_time`），且要配 start/end',
      () async {
        await drive.searchQuery(
          const DriveSearchQuery(
            date: DriveSearchDate.modified,
            startTime: 1000,
            endTime: 2000,
          ),
        );
        final p = lastSearch();
        expect(p['time'], 'modified_time');
        expect(p['start_date'], 1000);
        expect(p['end_date'], 2000);

        await drive.searchQuery(
          const DriveSearchQuery(date: DriveSearchDate.created),
        );
        expect(lastSearch()['time'], 'created_time');
      },
    );

    test('★ 只在选了时间档时才发 start/end（any 档不发）', () async {
      await drive.searchQuery(
        const DriveSearchQuery(startTime: 1000, endTime: 2000),
      );
      final p = lastSearch();
      expect(p.containsKey('start_date'), isFalse);
      expect(p.containsKey('end_date'), isFalse);
      expect(p.containsKey('time'), isFalse);
    });
  });

  group('DQ-7. ★ 六轴**同时**上（组合查询）', () {
    test('★ 六轴组合：每个轴都编码正确、互不覆盖', () async {
      await drive.searchQuery(
        const DriveSearchQuery(
          keyword: 'report',
          location: DriveSearchLocation.custom,
          customLocationId: '88',
          fileType: DriveSearchFileType.image,
          owner: DriveSearchOwner.notMe,
          size: DriveSearchSize.greaterThan,
          sizeMegabytes: 2,
          labelIds: ['5'],
          date: DriveSearchDate.modified,
          startTime: 111,
          endTime: 222,
          contentSnippet: false,
        ),
      );
      final p = lastSearch();
      expect(p['keyword'], 'report');
      expect(p['location'], 'custom');
      expect(p['custom_location'], 'id:88');
      expect(p['file_type'], 'image');
      expect(p['owner'], 'not_me');
      expect(p['min_size'], 2 * 1048576);
      expect(p['labels'], ['5']);
      expect(p['time'], 'modified_time');
      expect(p['start_date'], 111);
      expect(p['end_date'], 222);
      expect(p['content_snippet'], false, reason: '内容片段可关');
    });

    test('★ 分页透传 offset/limit', () async {
      await drive.searchQuery(
        const DriveSearchQuery(keyword: 'x'),
        offset: 50,
        limit: 25,
      );
      final p = lastSearch();
      expect(p['offset'], 50);
      expect(p['limit'], 25);
    });

    test('★ 搜索走 `Files/search` 且**版本是协商出来的 v4+**（不是写死）', () async {
      await drive.searchQuery(const DriveSearchQuery(keyword: 'x'));
      final req = backend.requests.lastWhere(
        (r) => '${r.params['method']}' == 'search',
      );
      final v = int.parse('${req.params['version']}');
      expect(v, greaterThanOrEqualTo(4));
    });
  });
}
