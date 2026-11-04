// ★★ **③Drive 第 54 轮：D49 内容搜索命中片段**（`content_snippet`）
//
// ## 被测物
// 1. `DriveEntryDto.snippet` ← 回包字段 **`content_snippet`**；
// 2. 请求侧的 `content_snippet` 开关（**同名的另一个东西**）；
// 3. 结果行的渲染：**有片段才多一行**。
//
// ## 字段名证据（不靠猜）
// 官方 `/tmp/drive-apk/jadx/sources/com/synology/dsdrive/api/response/FileInfoVo.java:19`
// ```java
// String content_snippet;
// ```
// 无 `@SerializedName` ⇒ Gson 按字段名映射 ⇒ 线上字段名就是 `content_snippet`。
//
// ## ★ 最容易混的一点：**同名两用**
// * **请求参数** `content_snippet` 是**布尔开关**
//   （`ApiSynoDriveFiles.java:130` `SEARCH_KEY__SNIPPET_QUERY="content_snippet"`）；
// * **回包字段** `content_snippet` 是**高亮后的文本**。
//
// 一个是 boolean、一个是 String。历史上我在这类"同名不同义"上栽过
// （见 `drive-search` 的 `custom_location` 是 `id:<file_id>` 而非布尔），
// 所以这里两侧都钉。
//
// 全程内存 Mock，不碰真机（规程 §5.1）。
import 'package:flutter_test/flutter_test.dart';

import 'package:synhub/src/data/drive_api.dart';
import 'package:synhub/src/data/dto/drive_entry_dto.dart';
import 'package:synhub/src/data/dto/drive_search_dto.dart';
import 'package:synhub/src/dsm/webapi.dart';

import '../tool/mock_dsm/mock_dsm_core.dart';
import 'support/mock_dsm_transport.dart';

void main() {
  late MockDsmBackend backend;
  late MockDsmTransport transport;
  late DsmWebApi web;
  late DriveApi drive;

  setUp(() async {
    backend = MockDsmBackend(catalog: DsmCatalog.load());
    backend.login(username: 'demo_user', admin: false);
    transport = MockDsmTransport(backend);
    web = DsmWebApi(transport);
    await web.discover();
    await web.login(account: 'demo_user', password: 'x');
    drive = DriveApi(web);
  });

  /// 让 `Files/search` 回一条带 / 不带片段的记录。
  void fixtureSearch({required String name, String? snippet}) =>
      backend.fixture(
        'SYNO.SynologyDrive.Files',
        'search',
        (_) => {
          'success': true,
          'data': {
            'total': 1,
            'items': [
              {
                'file_id': 'fid-1',
                'name': name,
                'type': 'file',
                'size': 100,
                if (snippet != null) 'content_snippet': snippet,
              },
            ],
          },
        },
      );

  Map<String, dynamic> lastSearch() {
    final req = backend.requests
        .where((r) => '${r.params['api']}' == 'SYNO.SynologyDrive.Files')
        .where((r) => '${r.params['method']}' == 'search')
        .toList();
    expect(req, isNotEmpty, reason: '必须真的发出了 Files/search');
    return req.last.params;
  }

  group('DS-1. ★ 回包 `content_snippet` ⇒ DTO.snippet', () {
    test('★ 有片段 ⇒ 解析出来', () async {
      fixtureSearch(name: 'report.docx', snippet: '…本季度**营收**同比增长 12%…');
      final r = await drive.searchQuery(const DriveSearchQuery(keyword: '营收'));
      expect(r.items, hasLength(1));
      expect(
        r.items.first.snippet,
        '…本季度**营收**同比增长 12%…',
        reason: '★ 字段名是 `content_snippet`（FileInfoVo.java:19），不是 `snippet`',
      );
    });

    test('★ **没有**该字段 ⇒ 空串（不是 null、不是 "null"）', () async {
      fixtureSearch(name: 'a.txt');
      final r = await drive.searchQuery(const DriveSearchQuery(keyword: 'a'));
      expect(
        r.items.first.snippet,
        '',
        reason: '★ UI 判据是 `isNotEmpty`，必须是空串而不是 "null" 之类',
      );
    });

    test('★ 回包给 `snippet`（**不带前缀**）不该被当片段 —— 那是另一个字段', () {
      // 纯 DTO 层：确认只认 `content_snippet`
      final e = DriveEntryDto.fromJson(const {
        'file_id': '1',
        'name': 'x',
        'type': 'file',
        'snippet': '这是 FileInfo 的 parcelable key，不是线上字段',
      });
      expect(
        e.snippet,
        '',
        reason:
            '★ `FileInfo.PARAM_KEY__SNIPPET="snippet"` 是 **Bundle key**'
            '（parcelable 用），不是回包字段 —— 认错就会永远拿不到片段',
      );
    });
  });

  group('DS-2. ★★ 请求侧 `content_snippet` 是**布尔开关**（实测：bool 不是 String）', () {
    test('★★ 内容搜索必须发 `content_snippet: true`', () async {
      fixtureSearch(name: 'a');
      await drive.searchQuery(const DriveSearchQuery(keyword: 'a'));
      // ⚠️ 我第一版断言写成 `'true'`（字符串）—— 实测是**布尔** `true`。
      // 这里如实按实测写（`call` 收 `Map<String,dynamic>`，
      // 布尔值由传输层序列化）。
      expect(
        lastSearch()['content_snippet'],
        isTrue,
        reason: '★ 不发这个开关，服务端**不会**去读文件内容 ⇒ 永远没有片段',
      );
    });

    test('★ 它是 `true`（字符串），**不是**文本 —— 同名不同义', () async {
      fixtureSearch(name: 'a');
      await drive.searchQuery(const DriveSearchQuery(keyword: 'a'));
      final v = lastSearch()['content_snippet'];
      expect(v, isA<bool>(), reason: '★ 请求侧是开关：布尔，不是文本');
      expect(
        v,
        isNot('…高亮片段…'),
        reason: '★ 请求侧只有 true/false；把回包的片段文本塞进请求会 101',
      );
    });
  });
}
