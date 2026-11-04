// 在线字幕源的**离线**测试：假 HTTP + 临时目录，不碰网络、不碰平台通道。
//
// 覆盖四块：
//   1. 文件名解析（电影/剧集/中文/无标签）与"首尾 64KB"哈希
//      （参考值用 python 的独立实现算出来硬编，**交叉实现**校验，不是自证）；
//   2. 两个源的请求形态（URL 参数 / 头部 / 语言与 hash 的映射）与失败分类
//      （403 无 key → keyMissing、403 有 key → keyRejected、503 → rateLimited）；
//   3. zip / 纯文本字幕的识别（OpenSubtitles 回 zip、gestdown 回 srt 正文）；
//   4. 缓存：确定性文件名、`.part` 落盘、读回、列举、清空、下载即存。
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:synhub/src/features/media/media_subtitle_search.dart';
import 'package:synhub/src/features/media/media_subtitles.dart';

/// 假 HTTP：记录每次请求，按 handler 回包
class FakeSubtitleHttp implements SubtitleHttp {
  FakeSubtitleHttp(this.handler);

  final Future<SubtitleHttpResponse> Function(
    Uri uri,
    Map<String, String> headers,
  )
  handler;

  final List<({Uri uri, Map<String, String> headers})> calls = [];

  Uri get lastUri => calls.last.uri;

  @override
  Future<SubtitleHttpResponse> get(
    Uri uri, {
    Map<String, String> headers = const {},
    Duration timeout = const Duration(seconds: 20),
  }) {
    calls.add((uri: uri, headers: headers));
    return handler(uri, headers);
  }
}

SubtitleHttpResponse _res(int code, String body, {String ct = 'application/json'}) =>
    SubtitleHttpResponse(
      statusCode: code,
      body: Uint8List.fromList(utf8.encode(body)),
      contentType: ct,
    );

/// 造一个 zip（模仿 OpenSubtitles 下载口：`.nfo` + `.srt`）
List<int> _zipWith({
  required Map<String, String> files,
}) {
  final archive = Archive();
  files.forEach((name, content) {
    final bytes = Uint8List.fromList(utf8.encode(content));
    archive.addFile(ArchiveFile(name, bytes.length, bytes));
  });
  // archive 4.x 的 `encode()` 是非空返回（`?? const []` 是死代码，analyzer 会报）
  return ZipEncoder().encode(archive);
}

const String _sampleSrt = '1\n'
    '00:00:01,000 --> 00:00:04,000\n'
    '第一句\n'
    '\n'
    '2\n'
    '00:00:05,000 --> 00:00:08,000\n'
    'second line\n';

const String _sampleAss = '[Script Info]\n'
    'Title: demo\n'
    '[Events]\n'
    'Format: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, '
    'Effect, Text\n'
    'Dialogue: 0,0:00:01.00,0:00:04.00,Default,,0,0,0,,{\\i1}你好，世界\n';

void main() {
  group('文件名解析', () {
    test('电影：标题 / 年份 / 画质标签被切掉', () {
      final p = parseMediaFileName('Inception.2010.1080p.BluRay.x264-Grym.mp4');
      expect(p.title, 'Inception');
      expect(p.year, 2010);
      expect(p.season, isNull);
      expect(p.episode, isNull);
    });

    test('剧集：S01E02 与 1x02 两种写法', () {
      final a = parseMediaFileName('Breaking.Bad.S01E02.720p.HDTV.mkv');
      expect(a.title, 'Breaking Bad');
      expect(a.season, 1);
      expect(a.episode, 2);
      expect(a.isEpisode, isTrue);

      final b = parseMediaFileName('Show.Name.1x02.WEB-DL.avi');
      expect(b.season, 1);
      expect(b.episode, 2);
      expect(b.title, 'Show Name');
    });

    // DA41（r391 真机抓到）：季集号**紧贴在标题后面**（没有 `.`/`_`/`-`/空格
    // 分隔）是最常见的中文命名法之一（真机上就是 `60招基础街球S01E01.AVI`）。
    // 旧实现只认"整个 token 恰好等于 S01E02"，于是这类文件被判"不是剧集"，
    // 唯一免密钥的在线字幕源（gestdown）直接拒服务，而界面还说
    // "文件名里需要有 S01E02 这样的季集号" —— **对着一个明明含 S01E01 的文件撒谎**。
    test('剧集：季集号紧贴标题（无分隔符）也要认', () {
      final a = parseMediaFileName('60招基础街球S01E01.AVI');
      expect(a.season, 1);
      expect(a.episode, 1);
      expect(a.title, '60招基础街球');
      expect(a.isEpisode, isTrue);
      // 免密钥源的门禁判据就是它（`GestdownSource.supportsFileName`）
      expect(GestdownSource.supportsFileName('60招基础街球S01E01.AVI'), isTrue);

      final b = parseMediaFileName('BreakingBadS01E02.720p.mkv');
      expect(b.season, 1);
      expect(b.episode, 2);
      expect(b.title, 'BreakingBad');

      final c = parseMediaFileName('街球1x02.mp4');
      expect(c.season, 1);
      expect(c.episode, 2);
      expect(c.title, '街球');
    });

    // ★ 反向验证：修的是"紧贴尾部"，**不许**把本来正确的分隔写法搞坏，
    //   也不许把电影名/别的名字误判成剧集（`S01E02` 必须出现在 token 的**尾部**）。
    test('反向：分隔写法与电影名不受影响', () {
      final dotted = parseMediaFileName('Breaking.Bad.S01E02.720p.HDTV.mkv');
      expect(dotted.title, 'Breaking Bad');
      expect(dotted.season, 1);
      expect(dotted.episode, 2);
      expect(dotted.year, isNull);

      final movie = parseMediaFileName(
        'Inception.2010.1080p.BluRay.x264-Grym.mp4',
      );
      expect(movie.season, isNull);
      expect(movie.episode, isNull);

      // 季集号在**中间**（后面还有别的 token）时不许把它当"紧贴尾部"
      final middle = parseMediaFileName('ShowS01E02Extras.mp4');
      expect(middle.season, isNull);
      expect(middle.episode, isNull);

      // ★ 分辨率 token 不算季集号（`1920x1080` 的尾部子串 `20x1080` 差点被认成
      //   S20E1080 —— 前置字符是数字 ⇒ 必须拒绝）
      final res = parseMediaFileName('Movie.1920x1080.mkv');
      expect(res.season, isNull);
      expect(res.episode, isNull);
      final res2 = parseMediaFileName('Movie.1280x720.mkv');
      expect(res2.season, isNull);
      expect(res2.episode, isNull);

      final cjk = parseMediaFileName('流浪地球_2019_2160p.mkv');
      expect(cjk.season, isNull);
      expect(cjk.episode, isNull);
      expect(cjk.title, '流浪地球');
    });

    test('中文标题与下划线分隔照样能认', () {
      final p = parseMediaFileName('流浪地球_2019_2160p.mkv');
      expect(p.title, '流浪地球');
      expect(p.year, 2019);
      expect(p.title, isNot(contains('2160p')));
    });

    test('没有标签时标题就是整个基名', () {
      final p = parseMediaFileName('holiday clip.mp4');
      expect(p.title, 'holiday clip');
    });
  });

  group('首尾 64KB 哈希（与 python 独立实现交叉校验）', () {
    // 参考值由 python 的 struct.unpack('<Q') 累加实现算出（见文件头工具说明）
    final head = Uint8List.fromList(
      List<int>.generate(65536, (i) => (i * 7 + 3) % 256),
    );
    final tail = Uint8List.fromList(
      List<int>.generate(65536, (i) => (i * 13 + 11) % 256),
    );

    test('OpenSubtitles 64bit 小端累加哈希', () {
      expect(
        openSubtitlesHashHex(head: head, tail: tail, fileSize: 123456789),
        'e060df5fe6bb8d15',
      );
    });

    test('短文件（整份当 head、tail 空）', () {
      final small = Uint8List.fromList(utf8.encode('hello open subtitles hash'));
      expect(
        openSubtitlesHashHex(head: small, tail: const [], fileSize: small.length),
        '4d44eb0552f240c2',
      );
    });

    test('SubDB 的 md5(head+tail)', () {
      expect(
        subDbHashHex(head: head, tail: tail),
        '0d5984845f1740df4bb5a3399abc8cc0',
      );
    });

    test('文件多小算"整份当 head"', () {
      expect(hashNeedsWholeFile(64 * 1024), isTrue);
      expect(hashNeedsWholeFile(128 * 1024), isTrue);
      expect(hashNeedsWholeFile(128 * 1024 + 1), isFalse);
    });
  });

  group('下载字节 → 字幕', () {
    test('zip（含 .nfo）里挑出 .srt', () {
      final zip = _zipWith(files: {
        'inception.nfo': 'noise',
        'Inception.srt': _sampleSrt,
      });
      final d = decodeSubtitlePayload(zip, contentType: 'application/zip');
      expect(d, isNotNull);
      expect(d!.format, SubtitleFormat.srt);
      expect(d.fileName, 'Inception.srt');
      expect(d.toTrack()!.cues, hasLength(2));
    });

    test('纯文本：靠 --> 判 srt、靠 [Events] 判 ass', () {
      final srt = decodeSubtitlePayload(utf8.encode(_sampleSrt), contentType: 'text/srt');
      expect(srt!.format, SubtitleFormat.srt);

      final ass = decodeSubtitlePayload(utf8.encode(_sampleAss), contentType: 'text/plain');
      expect(ass!.format, SubtitleFormat.ass);
      expect(ass.toTrack()!.cues.single.text, '你好，世界');
    });

    test('WEBVTT 头 → vtt；垃圾字节 → null（不假装）', () {
      final vtt = decodeSubtitlePayload(
        utf8.encode('WEBVTT\n\n00:00.000 --> 00:02.000\nhi\n'),
      );
      expect(vtt!.format, SubtitleFormat.vtt);
      expect(decodeSubtitlePayload(const [1, 2, 3, 4]), isNull);
      expect(decodeSubtitlePayload(const []), isNull);
    });
  });

  group('OpenSubtitles 源', () {
    String searchBody() => '''
{"total_pages":1,"total_count":2,"page":1,"data":[
 {"id":"1","attributes":{"subtitle_id":"1","language":"en","download_count":10,
   "ratings":7.5,"legacy_subtitle_id":111,"release":"Inception.2010.1080p",
   "files":[{"file_id":222,"cd_number":1}],"hd":true,"hearing_impaired":false}},
 {"id":"2","attributes":{"subtitle_id":"2","language":"zh-cn","download_count":99,
   "ratings":9.0,"legacy_subtitle_id":333,"release":"Inception.2010.中英",
   "files":[{"file_id":444,"cd_number":2}],"nb_cd":2}}
]}''';

    test('匿名 + 只要 en → languages=en，结果按下载量排序', () async {
      final http = FakeSubtitleHttp((_, __) async => _res(200, searchBody()));
      final source = OpenSubtitlesSource(http: http);
      final hits = await source.search(
        const SubtitleSearchQuery(
          fileName: 'Inception.2010.1080p.mp4',
          languages: ['en'],
        ),
      );
      expect(http.lastUri.queryParameters['languages'], 'en');
      expect(http.lastUri.queryParameters['query'], 'Inception');
      expect(http.lastUri.queryParameters.containsKey('moviehash'), isFalse);
      expect(hits, hasLength(1), reason: '只要 en，zh 那条被过滤掉');
      expect(hits.single.payload['legacy_subtitle_id'], '111');
      expect(hits.single.note, contains('HD'));
    });

    test('要中文 → languages=all 并在客户端过滤；多段如实标注', () async {
      final http = FakeSubtitleHttp((_, __) async => _res(200, searchBody()));
      final source = OpenSubtitlesSource(http: http);
      final hits = await source.search(
        const SubtitleSearchQuery(
          fileName: 'Inception.2010.mp4',
          languages: ['zh-cn', 'en'],
        ),
      );
      expect(http.lastUri.queryParameters['languages'], 'all');
      expect(hits, hasLength(2));
      final zh = hits.firstWhere((h) => h.language == 'zh-cn');
      expect(zh.note, contains('2 段'));
      expect(hits.first.downloads, 99, reason: '下载多的排前面');
    });

    test('有 hash → 带 moviehash 参数（哈希匹配走同一条搜索）', () async {
      final http = FakeSubtitleHttp((_, __) async => _res(200, searchBody()));
      final source = OpenSubtitlesSource(http: http);
      await source.search(
        const SubtitleSearchQuery(
          fileName: 'Inception.mp4',
          languages: ['en'],
          hash: 'e060df5fe6bb8d15',
        ),
      );
      expect(http.lastUri.queryParameters['moviehash'], 'e060df5fe6bb8d15');
    });

    test('403 且没填 key → keyMissing（界面据此提示填密钥）', () async {
      final http = FakeSubtitleHttp(
        (_, __) async =>
            _res(403, '{"message":"You cannot consume this service"}'),
      );
      final source = OpenSubtitlesSource(http: http);
      await expectLater(
        source.search(
          const SubtitleSearchQuery(fileName: 'a.mp4', languages: ['en']),
        ),
        throwsA(
          isA<SubtitleSearchFailure>()
              .having((e) => e.kind, 'kind', SubtitleSearchFailureKind.keyMissing)
              .having((e) => e.statusCode, 'status', 403),
        ),
      );
    });

    test('403 且填了 key → keyRejected；Api-Key 头真的发出去了', () async {
      final http = FakeSubtitleHttp((_, __) async => _res(403, '{}'));
      final source = OpenSubtitlesSource(http: http);
      await expectLater(
        source.search(
          const SubtitleSearchQuery(fileName: 'a.mp4', languages: ['en']),
          apiKey: 'k-123',
        ),
        throwsA(
          isA<SubtitleSearchFailure>().having(
            (e) => e.kind,
            'kind',
            SubtitleSearchFailureKind.keyRejected,
          ),
        ),
      );
      expect(http.calls.single.headers['Api-Key'], 'k-123');
    });

    test('503 → rateLimited；非 JSON → badResponse', () async {
      final http503 = FakeSubtitleHttp(
        (_, __) async => _res(503, '{"message":"Service unavailable"}'),
      );
      await expectLater(
        OpenSubtitlesSource(http: http503).search(
          const SubtitleSearchQuery(fileName: 'a.mp4', languages: ['en']),
        ),
        throwsA(
          isA<SubtitleSearchFailure>().having(
            (e) => e.kind,
            'kind',
            SubtitleSearchFailureKind.rateLimited,
          ),
        ),
      );

      final httpHtml = FakeSubtitleHttp(
        (_, __) async => _res(200, '<html>nope</html>', ct: 'text/html'),
      );
      await expectLater(
        OpenSubtitlesSource(http: httpHtml).search(
          const SubtitleSearchQuery(fileName: 'a.mp4', languages: ['en']),
        ),
        throwsA(
          isA<SubtitleSearchFailure>().having(
            (e) => e.kind,
            'kind',
            SubtitleSearchFailureKind.badResponse,
          ),
        ),
      );
    });

    test('下载走 dl.opensubtitles.org/en/download/sub/<legacy>，zip 里取 srt', () async {
      final zip = _zipWith(files: {'Inception.nfo': 'x', 'Inception.srt': _sampleSrt});
      final http = FakeSubtitleHttp(
        (_, __) async => SubtitleHttpResponse(
          statusCode: 200,
          body: Uint8List.fromList(zip),
          contentType: 'application/zip',
        ),
      );
      final source = OpenSubtitlesSource(http: http);
      final hit = SubtitleSearchHit(
        sourceId: 'opensubtitles',
        sourceLabel: 'OpenSubtitles',
        id: '7803094',
        title: 'Inception',
        language: 'en',
        payload: const {'legacy_subtitle_id': '7803094'},
      );
      final d = await source.download(hit);
      expect(
        http.lastUri.toString(),
        'https://dl.opensubtitles.org/en/download/sub/7803094',
      );
      expect(d.format, SubtitleFormat.srt);
      expect(d.toTrack()!.cues, hasLength(2));
    });
  });

  group('OpenSubtitles 老 REST 口（r456：免密钥中文源）', () {
    // 字段子集**逐字照抄**真实应答（`docs/evidence-r456/host/r456_subtitle_sources_probe.txt`），
    // 不改名、不美化 —— 守的就是"解析器认不认真实字段"。
    String restRow({
      String language = 'chi',
      String name =
          'Inception.2010.BluRay.1080p.x264-10bit.DTS-HD.MA-HDTime.chs.srt',
      int downloads = 8744,
      String id = '5956328',
      String format = 'srt',
      int season = 0,
      int episode = 0,
      String link =
          'https://dl.opensubtitles.org/en/download/src-api/vrf-19d00c53/filead/1958464311.gz',
      String release = 'Inception.2010.BluRay.1080p.x264-10bit.DTS-HD.MA-HDTime',
    }) => jsonEncode({
      'SubLanguageID': language,
      'SubFileName': name,
      'SubFormat': format,
      'SubEncoding': 'UTF-8',
      'SubDownloadsCnt': downloads,
      'IDSubtitle': id,
      'IDSubtitleFile': '1958464311',
      'MovieReleaseName': release,
      'MovieName': 'Inception',
      'MovieYear': 2010,
      'SeriesSeason': season,
      'SeriesEpisode': episode,
      'SubDownloadLink': link,
    });

    String restBody(List<String> rows) => '[${rows.join(',')}]';

    test('① 请求契约：路径**全小写**、`+` 连接、没有点/空格（大写会撞那条坏 302）', () async {
      final http = FakeSubtitleHttp((_, __) async => _res(200, '[]'));
      await OpenSubtitlesRestSource(http: http).search(
        const SubtitleSearchQuery(
          fileName: 'Inception.2010.1080p.BluRay.x264.mp4',
          languages: ['en'],
        ),
      );
      // ★ 实测边界：`query-Inception+2010` = 302（location `https://_/…`）、
      //   `query-inception` = 200。所以这里**必须**断言全小写与"只留片名 token"。
      expect(
        http.lastUri.toString(),
        'https://rest.opensubtitles.org/search/query-inception/sublanguageid-eng',
      );
      // 只对**路径**断言"没有点/百分号编码"（域名里当然有点）
      expect(http.lastUri.path, '/search/query-inception/sublanguageid-eng');
      expect(http.lastUri.path, isNot(contains('%20')));
      expect(http.lastUri.path, isNot(contains('.')));
      expect(
        http.lastUri.path,
        equals(http.lastUri.path.toLowerCase()),
        reason: '路径里出现大写 ⇒ 服务端 302 到 `https://_/…`（坏重定向）',
      );
    });

    test('② 中文优先档 → chi/zhe/zht/eng 各一次（去重、保序、每语言一次请求）', () async {
      final http = FakeSubtitleHttp((_, __) async => _res(200, '[]'));
      await OpenSubtitlesRestSource(http: http).search(
        const SubtitleSearchQuery(
          fileName: 'Inception.mp4',
          languages: ['zh-cn', 'zh', 'zh-tw', 'en'],
        ),
      );
      expect(
        http.calls.map((c) => c.uri.pathSegments.last).toList(),
        [
          'sublanguageid-chi',
          'sublanguageid-zhe',
          'sublanguageid-zht',
          'sublanguageid-eng',
        ],
        reason: 'zh-cn→chi、zh→zhe（简英双语）、zh-tw→zht、en→eng；逗号多语言实测 400',
      );
    });

    test('③ 解析：chi→zh-cn / zht→zh-tw、按下载量排序、字段照实带回', () async {
      // 假 HTTP 按**请求里那个 legacy 语言码**回包 —— 真实端点就是按 sublanguageid
      // 过滤后再回的（所以"混合语言"场景在生产里不会出现，这里不伪造它）。
      final http = FakeSubtitleHttp((uri, __) async {
        final code = uri.pathSegments.last.replaceFirst('sublanguageid-', '');
        if (code == 'chi') {
          return _res(
            200,
            restBody([
              restRow(language: 'chi', id: 'low', downloads: 5, name: 'x.chs.ass', format: 'ass'),
              restRow(language: 'chi', id: 'top', downloads: 8744),
            ]),
          );
        }
        if (code == 'zht') {
          return _res(200, restBody([
            restRow(language: 'zht', id: 'trad', downloads: 12, name: 'x.cht.srt'),
          ]));
        }
        return _res(200, '[]');
      });
      final source = OpenSubtitlesRestSource(http: http);
      final zh = await source.search(
        const SubtitleSearchQuery(fileName: 'Inception.mp4', languages: ['zh-cn']),
      );
      expect(zh.map((h) => h.id).toList(), ['top', 'low'], reason: '下载量高的排前面');
      expect(zh.first.language, 'zh-cn');
      expect(zh.first.downloads, 8744);
      expect(zh.first.payload['file_name'], contains('.chs.srt'));
      expect(zh.first.payload['download_link'], contains('filead/'));
      expect(zh.first.note, contains('srt'));
      expect(zh.last.note, contains('ass'));

      final tw = await source.search(
        const SubtitleSearchQuery(fileName: 'Inception.mp4', languages: ['zh-tw']),
      );
      expect(tw.single.id, 'trad');
      expect(tw.single.language, 'zh-tw', reason: 'zht → zh-tw');
    });

    test('③-b 排序与上限：中文命中先排，每源最多 40 条（英文太多不许把中文挤掉）', () async {
      final http = FakeSubtitleHttp((uri, __) async {
        final code = uri.pathSegments.last.replaceFirst('sublanguageid-', '');
        if (code == 'chi') {
          return _res(200, restBody([
            restRow(language: 'chi', id: 'zh-1', downloads: 7, name: 'a.chs.srt'),
          ]));
        }
        // 英文像真实端点那样"慷慨"：45 条，且下载量都比中文高
        return _res(200, restBody([
          for (var i = 0; i < 45; i++)
            restRow(language: 'eng', id: 'en-$i', downloads: 9000 + i, name: 'e$i.srt'),
        ]));
      });
      final hits = await OpenSubtitlesRestSource(http: http).search(
        const SubtitleSearchQuery(
          fileName: 'Inception.mp4',
          languages: ['zh-cn', 'en'],
        ),
      );
      expect(hits, hasLength(40), reason: '每源上限 40（46 条里切掉 6 条）');
      expect(hits.first.id, 'zh-1', reason: '★ 中文先排（否则被 45 条英文挤到中段）');
      expect(hits.first.language, 'zh-cn');
      expect(hits[1].downloads, 9044, reason: '英文内部仍按下载量降序');
    });

    test('③-c 与聚合服务对得上：每条命中的 sourceId 都必须能被 sourceById 解析', () async {
      // ★ 这条是**真机 r456 抓到的坑**的回归：命中里的 `sourceId` 一度写成"字幕行号"
      //   （局部变量遮蔽了 `SubtitleOnlineSource.id`），于是真机点下载时
      //   `service.sourceById(hit.sourceId)` 返回 null ⇒ 界面报
      //   「这个源已经不可用了（OpenSubtitles REST）」。宿主用例当时没做这条往返。
      final service = SubtitleSearchService.defaults(
        http: FakeSubtitleHttp((uri, __) async {
          if (!uri.host.startsWith('rest.')) return _res(200, '{}');
          final code = uri.pathSegments.last.replaceFirst('sublanguageid-', '');
          if (code != 'chi') return _res(200, '[]');
          return _res(200, restBody([restRow(language: 'chi', id: '5956328')]));
        }),
      );
      final hits = await service
          .sources
          .firstWhere((s) => s.id == 'opensubtitles-rest')
          .search(
            const SubtitleSearchQuery(
              fileName: 'Inception.mp4',
              languages: ['zh-cn'],
            ),
          );
      expect(hits, hasLength(1));
      expect(hits.single.sourceId, 'opensubtitles-rest');
      final found = service.sourceById(hits.single.sourceId);
      expect(found, isNotNull, reason: '查不到 ⇒ 真机上点下载就是"这个源已经不可用了"');
      expect(found!.id, 'opensubtitles-rest');
    });

    test('④ 剧集：路径只带 `season-`，集号在**客户端**过滤（`episode-` 会 302）', () async {
      final http = FakeSubtitleHttp(
        (_, __) async => _res(
          200,
          restBody([
            restRow(id: 'e1', name: 'Breaking.Bad.S01E01.chs.srt', season: 1, episode: 1),
            restRow(id: 'e2', name: 'Breaking.Bad.S01E02.chs.srt', season: 1, episode: 2),
            restRow(id: 'e4', name: 'Breaking.Bad.S01E04.chs.srt', season: 1, episode: 4),
          ]),
        ),
      );
      final hits = await OpenSubtitlesRestSource(http: http).search(
        const SubtitleSearchQuery(
          fileName: 'Breaking.Bad.S01E02.720p.BluRay.mkv',
          languages: ['zh-cn'],
        ),
      );
      expect(
        http.lastUri.path,
        '/search/query-breaking+bad/season-1/sublanguageid-chi',
      );
      expect(http.lastUri.path.contains('episode'), isFalse, reason: '带 episode- 实测 302');
      expect(hits, hasLength(1));
      expect(hits.single.id, 'e2');
      expect(hits.single.note, contains('S01E02'));
    });

    test('⑤ 302 / 404 都当"这个语言没结果"，**不是**失败（别把界面吓成网络错）', () async {
      for (final code in [302, 404]) {
        final http = FakeSubtitleHttp((_, __) async => _res(code, ''));
        final hits = await OpenSubtitlesRestSource(http: http).search(
          const SubtitleSearchQuery(fileName: 'Inception.mp4', languages: ['zh-cn']),
        );
        expect(hits, isEmpty, reason: 'HTTP $code');
      }
    });

    test('⑥ 500 → badResponse 带状态码；推不出片名 → unsupported', () async {
      final http500 = FakeSubtitleHttp((_, __) async => _res(500, 'boom'));
      await expectLater(
        OpenSubtitlesRestSource(http: http500).search(
          const SubtitleSearchQuery(fileName: 'Inception.mp4', languages: ['zh-cn']),
        ),
        throwsA(
          isA<SubtitleSearchFailure>()
              .having((e) => e.kind, 'kind', SubtitleSearchFailureKind.badResponse)
              .having((e) => e.statusCode, 'status', 500),
        ),
      );

      final httpOk = FakeSubtitleHttp((_, __) async => _res(200, '[]'));
      await expectLater(
        OpenSubtitlesRestSource(http: httpOk).search(
          // 只有分隔符、没有字母数字 ⇒ 真的推不出片名
          // （`1080p.mkv` 不算：解析器在"全是标签"时会如实回落到原始文件名，
          //   于是会真发一次 `query-1080p`；那是既有行为，不在本用例口径里）
          const SubtitleSearchQuery(fileName: '-.-', languages: ['zh-cn']),
        ),
        throwsA(
          isA<SubtitleSearchFailure>().having(
            (e) => e.kind,
            'kind',
            SubtitleSearchFailureKind.unsupported,
          ),
        ),
      );
      expect(httpOk.calls, isEmpty, reason: '连请求都不该发');
    });

    test('⑦ 下载：裸 gzip（`.gz`，不是 zip）要自己解，解出真 srt；文件名用回源文件名', () async {
      final gz = gzip.encode(utf8.encode(_sampleSrt));
      final http = FakeSubtitleHttp(
        (_, __) async => SubtitleHttpResponse(
          statusCode: 200,
          body: Uint8List.fromList(gz),
          contentType: 'application/force-download',
        ),
      );
      final hit = SubtitleSearchHit(
        sourceId: 'opensubtitles-rest',
        sourceLabel: 'OpenSubtitles REST',
        id: '5956328',
        title: 'Inception.2010.chs.srt',
        language: 'zh-cn',
        payload: const {
          'download_link':
              'https://dl.opensubtitles.org/en/download/src-api/vrf-19d00c53/filead/1958464311.gz',
          'file_name': 'Inception.2010.chs.srt',
        },
      );
      final d = await OpenSubtitlesRestSource(http: http).download(hit);
      expect(
        http.lastUri.toString(),
        'https://dl.opensubtitles.org/en/download/src-api/vrf-19d00c53/filead/1958464311.gz',
      );
      expect(d.fileName, 'Inception.2010.chs.srt');
      expect(d.format, SubtitleFormat.srt);
      expect(d.toTrack()!.cues, hasLength(2));
    });

    test('⑧ 没有下载地址 / 下载口 500 → 都如实报错（不静默）', () async {
      final http = FakeSubtitleHttp((_, __) async => _res(500, 'boom'));
      const bare = SubtitleSearchHit(
        sourceId: 'opensubtitles-rest',
        sourceLabel: 'OpenSubtitles REST',
        id: 'x',
        title: 'x',
        language: 'zh-cn',
      );
      await expectLater(
        OpenSubtitlesRestSource(http: http).download(
          const SubtitleSearchHit(
            sourceId: 'opensubtitles-rest',
            sourceLabel: 'OpenSubtitles REST',
            id: 'x',
            title: 'x',
            language: 'zh-cn',
            payload: {'download_link': 'https://dl.opensubtitles.org/x.gz'},
          ),
        ),
        throwsA(
          isA<SubtitleSearchFailure>().having(
            (e) => e.kind,
            'kind',
            SubtitleSearchFailureKind.badResponse,
          ),
        ),
      );
      await expectLater(
        OpenSubtitlesRestSource(http: http).download(bare),
        throwsA(
          isA<SubtitleSearchFailure>().having(
            (e) => e.kind,
            'kind',
            SubtitleSearchFailureKind.badResponse,
          ),
        ),
      );
    });
  });

  group('Gestdown 源', () {
    test('剧集名 → 先查 show 再拉语言列表；非法语言不请求', () async {
      final http = FakeSubtitleHttp((uri, _) async {
        if (uri.path.contains('/shows/search/')) {
          return _res(
            200,
            '{"shows":[{"id":"show-1","name":"Breaking Bad"}]}',
          );
        }
        return _res(
          200,
          '{"matchingSubtitles":[{"subtitleId":"sub-1","version":"0tv",'
          '"language":"English","downloadUri":"/subtitles/download/sub-1",'
          '"hd":true,"corrected":true,"hearingImpaired":false}]}',
        );
      });
      final source = GestdownSource(http: http);
      final hits = await source.search(
        const SubtitleSearchQuery(
          fileName: 'Breaking.Bad.S01E02.720p.mkv',
          languages: ['en', 'zh-cn'],
        ),
      );
      expect(hits, hasLength(1));
      expect(hits.single.payload['download_uri'], '/subtitles/download/sub-1');
      expect(hits.single.note, contains('已校对'));
      // 只问了 en：中文（gestdown 没有词条）没有被翻译成非法码去撞 423
      final subCalls = http.calls
          .where((c) => c.uri.path.contains('/subtitles/get/'))
          .toList();
      expect(subCalls, hasLength(1));
      expect(subCalls.single.uri.path, contains('/1/2/en'));
      expect(subCalls.single.uri.path, contains('show-1'));
    });

    test('电影文件名（没有季集）→ unsupported，不发请求', () async {
      final http = FakeSubtitleHttp((_, __) async => _res(200, '{}'));
      await expectLater(
        GestdownSource(http: http).search(
          const SubtitleSearchQuery(fileName: 'Inception.2010.mp4'),
        ),
        throwsA(
          isA<SubtitleSearchFailure>().having(
            (e) => e.kind,
            'kind',
            SubtitleSearchFailureKind.unsupported,
          ),
        ),
      );
      expect(http.calls, isEmpty);
    });

    test('该语言没词条（423）→ 空结果，不是失败', () async {
      final http = FakeSubtitleHttp((uri, _) async {
        if (uri.path.contains('/shows/search/')) {
          return _res(200, '{"shows":[{"id":"show-1","name":"Breaking Bad"}]}');
        }
        return _res(423, '');
      });
      final hits = await GestdownSource(http: http).search(
        const SubtitleSearchQuery(
          fileName: 'Breaking.Bad.S01E02.mkv',
          languages: ['fr'],
        ),
      );
      expect(hits, isEmpty);
    });

    test('下载：downloadUri 拼到 base 上，正文就是 srt', () async {
      final http = FakeSubtitleHttp(
        (_, __) => Future.value(
          _res(200, _sampleSrt, ct: 'text/srt'),
        ),
      );
      final hit = SubtitleSearchHit(
        sourceId: 'gestdown',
        sourceLabel: 'Gestdown',
        id: 'sub-1',
        title: 'English · S01E02',
        language: 'en',
        payload: const {'download_uri': '/subtitles/download/sub-1'},
      );
      final d = await GestdownSource(http: http).download(hit);
      expect(
        http.lastUri.toString(),
        'https://api.gestdown.info/subtitles/download/sub-1',
      );
      expect(d.format, SubtitleFormat.srt);
    });
  });

  group('多源聚合', () {
    test('一个源失败不影响另一个；失败原因照实带回', () async {
      final good = _StubSource(id: 'good', hits: const [
        SubtitleSearchHit(
          sourceId: 'good',
          sourceLabel: 'Good',
          id: '1',
          title: 'x',
          language: 'en',
        ),
      ]);
      final bad = _StubSource(
        id: 'bad',
        failure: const SubtitleSearchFailure(
          SubtitleSearchFailureKind.network,
          '连不上',
        ),
      );
      final outcome = await SubtitleSearchService(
        sources: [good, bad],
      ).search(const SubtitleSearchQuery(fileName: 'a.mkv'));
      expect(outcome.hits, hasLength(1));
      expect(outcome.failures, hasLength(1));
      expect(outcome.failures.single.sourceId, 'bad');
      expect(outcome.allFailed, isFalse);
      expect(outcome.sourcesTried, 2);
    });

    test('全部源失败 → allFailed（界面给"失败 + 重试"）', () async {
      final outcome = await SubtitleSearchService(
        sources: [
          _StubSource(
            id: 'a',
            failure: const SubtitleSearchFailure(
              SubtitleSearchFailureKind.network,
              '连不上',
            ),
          ),
          _StubSource(
            id: 'b',
            failure: const SubtitleSearchFailure(
              SubtitleSearchFailureKind.rateLimited,
              '限流',
            ),
          ),
        ],
      ).search(const SubtitleSearchQuery(fileName: 'a.mkv'));
      expect(outcome.hits, isEmpty);
      expect(outcome.allFailed, isTrue);
    });

    test('没找到（源都成功但空）→ allFailed 为 false', () async {
      final outcome = await SubtitleSearchService(
        sources: [_StubSource(id: 'a')],
      ).search(const SubtitleSearchQuery(fileName: 'a.mkv'));
      expect(outcome.isEmpty, isTrue);
      expect(outcome.allFailed, isFalse);
    });
  });

  group('缓存', () {
    late Directory dir;
    late SubtitleCacheStore store;

    setUp(() async {
      dir = await Directory.systemTemp.createTemp('sub-cache-test');
      store = SubtitleCacheStore(directory: () async => dir);
    });

    tearDown(() async {
      if (await dir.exists()) await dir.delete(recursive: true);
    });

    test('文件名确定且被消毒（不含空格/斜杠）', () {
      final a = SubtitleCacheStore.fileNameFor(
        mediaFileName: 'My Movie (2019).mp4',
        sourceId: 'opensubtitles',
        hitId: '7803094',
        format: SubtitleFormat.srt,
      );
      final b = SubtitleCacheStore.fileNameFor(
        mediaFileName: 'My Movie (2019).mp4',
        sourceId: 'opensubtitles',
        hitId: '7803094',
        format: SubtitleFormat.srt,
      );
      expect(a, b, reason: '同一个 hit 必须落到同一个文件名（记忆才靠得住）');
      expect(a, startsWith(kSubtitleCachePrefix));
      expect(a, endsWith('.srt'));
      expect(a, isNot(contains(' ')));
      expect(a, isNot(contains('/')));
      expect(a, isNot(contains('(')));
    });

    test('写 → 读 → 列举 → 清空（只动自己的前缀）', () async {
      final name = SubtitleCacheStore.fileNameFor(
        mediaFileName: 'clip.mp4',
        sourceId: 'gestdown',
        hitId: 'sub-1',
        format: SubtitleFormat.srt,
      );
      await store.write(fileName: name, bytes: utf8.encode(_sampleSrt));
      // 别人的文件不许被清掉
      await File('${dir.path}/other.txt').writeAsString('keep me');

      final loaded = await store.load(name);
      expect(loaded, isNotNull);
      expect(loaded!.toTrack()!.cues, hasLength(2));

      final entries = await store.list();
      expect(entries.map((e) => e.fileName), [name]);
      expect(entries.single.size, greaterThan(0));

      expect(await store.clear(), 1);
      expect(await store.load(name), isNull);
      expect(await File('${dir.path}/other.txt').exists(), isTrue);
      expect(await File('${dir.path}/$name.part').exists(), isFalse);
    });

    test('读不到的缓存 → null（如实降级，不伪造）', () async {
      expect(await store.load('subtitle_missing.opensubtitles.1.srt'), isNull);
      expect(await store.load(''), isNull);
    });

    test('fetchAndStore：下载一次到位，返回落盘名', () async {
      final zip = _zipWith(files: {'Inception.srt': _sampleSrt});
      final http = FakeSubtitleHttp(
        (_, __) async => SubtitleHttpResponse(
          statusCode: 200,
          body: Uint8List.fromList(zip),
          contentType: 'application/zip',
        ),
      );
      final source = OpenSubtitlesSource(http: http);
      final hit = SubtitleSearchHit(
        sourceId: 'opensubtitles',
        sourceLabel: 'OpenSubtitles',
        id: '111',
        title: 'Inception',
        language: 'en',
        payload: const {'legacy_subtitle_id': '111'},
      );
      final result = await store.fetchAndStore(
        source: source,
        hit: hit,
        mediaFileName: 'Inception.2010.mp4',
      );
      expect(result.fileName, contains('opensubtitles'));
      expect(result.fileName, endsWith('.srt'));
      expect(await File('${dir.path}/${result.fileName}').exists(), isTrue);
      expect(result.download.toTrack()!.cues, hasLength(2));
    });
  });

  group('默认源集合', () {
    test('默认三个源、id 稳定、各自的能力声明如实', () {
      final service = SubtitleSearchService.defaults(
        http: FakeSubtitleHttp((_, __) async => _res(200, '{}')),
      );
      expect(service.sources.map((s) => s.id), [
        'opensubtitles',
        'opensubtitles-rest',
        'gestdown',
      ]);
      expect(service.sourceById('gestdown')!.supportsHash, isFalse);
      expect(service.sourceById('opensubtitles')!.supportsHash, isTrue);
      // ★ r456：老 REST 口**免密钥**（这是它存在的理由），
      //   但它的哈希搜索实测是坏的 ⇒ 必须如实标 false（不许为了"看起来更强"标 true）
      final rest = service.sourceById('opensubtitles-rest')!;
      expect(rest.requiresKey, isFalse);
      expect(rest.supportsHash, isFalse);
      expect(rest.label, 'OpenSubtitles REST');
      expect(OpenSubtitlesRestSource.supportsFileName('Inception.2010.mp4'), isTrue);
      expect(service.sourceById('nope'), isNull);
      expect(
        GestdownSource.supportsFileName('Breaking.Bad.S01E02.mkv'),
        isTrue,
      );
      expect(GestdownSource.supportsFileName('Inception.2010.mp4'), isFalse);
    });
  });
}

/// 只用来验证聚合逻辑的桩源
class _StubSource implements SubtitleOnlineSource {
  _StubSource({required this.id, this.hits = const [], this.failure});

  @override
  final String id;
  final List<SubtitleSearchHit> hits;
  final SubtitleSearchFailure? failure;

  @override
  String get label => id;

  @override
  String get note => '';

  @override
  bool get requiresKey => false;

  @override
  bool get supportsHash => false;

  @override
  Future<List<SubtitleSearchHit>> search(
    SubtitleSearchQuery query, {
    String? apiKey,
  }) async {
    final f = failure;
    if (f != null) throw f;
    return hits;
  }

  @override
  Future<SubtitleDownload> download(
    SubtitleSearchHit hit, {
    String? apiKey,
  }) async => throw const SubtitleSearchFailure(
    SubtitleSearchFailureKind.unsupported,
    'stub 不下载',
  );
}
