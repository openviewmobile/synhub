// 歌词模块（`audio_lyrics.dart`）的**离线**单测。
//
// 覆盖三块，全部不碰网络（真源用假 `LyricsHttp` / 假 `LyricsSource`）：
//   ① LRC 解析（多标签一行 / 1–3 位毫秒 / offset / 元数据标签 / 纯文本退化）；
//   ② 文件名 → 查询（音轨号、`歌手 - 曲名`）、候选排序、宽松 JSON 解析；
//   ③ 编排（缓存命中 / 自动挑最优 / 失败五分类 / 手动选版本 / 本地缓存往返）。
//
// ★ 后者不是"为了覆盖率"：`LyricCandidate.fromJson` 的宽松性有**真实依据** ——
// 实测 lrclib 的 `duration` 是 `211.109025`、`id` 可能是字符串
// （见 `audio_lyrics.dart` 文件头 ④），裸 `as num?` 会整页崩（AGENTS §2.2 教训）。
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:synhub/src/features/media/audio_lyrics.dart';

// ─────────────────────────────────────────────────────────────── 测试替身

/// 假 HTTP 出口：按 URL 返回预置响应，**完全不联网**。
class _FakeHttp implements LyricsHttp {
  _FakeHttp(this.handler);

  final LyricsHttpResponse Function(Uri uri) handler;
  final calls = <Uri>[];

  @override
  Future<LyricsHttpResponse> get(Uri uri) async {
    calls.add(uri);
    return handler(uri);
  }
}

/// 假歌词源（记录请求，便于断言"只查一次/回退查询"等行为）。
class _FakeSource implements LyricsSource {
  _FakeSource({
    this.results = const [],
    this.byId = const {},
    this.failWith,
    this.failByIdWith,
  });

  List<LyricCandidate> results;

  /// id → 候选（`choose()`/`fetchById` 用）
  Map<int, LyricCandidate> byId;

  LyricsFailureKind? failWith;
  LyricsFailureKind? failByIdWith;

  /// 前 N 次 `search` 抛 **5xx**（模拟源站过载 `ServerOverloaded`），之后正常
  int serverOverloadTimes = 0;

  final searched = <LyricsQuery>[];
  final fetchedIds = <int>[];

  @override
  Future<List<LyricCandidate>> search(LyricsQuery query) async {
    searched.add(query);
    if (serverOverloadTimes > 0) {
      serverOverloadTimes--;
      throw LyricsFetchException(LyricsFailureKind.server);
    }
    final f = failWith;
    if (f != null) throw LyricsFetchException(f);
    return results;
  }

  @override
  Future<LyricCandidate?> fetchById(int id) async {
    fetchedIds.add(id);
    final f = failByIdWith;
    if (f != null) throw LyricsFetchException(f);
    return byId[id];
  }
}

LyricCandidate _cand({
  required int id,
  required String track,
  String artist = '',
  String album = '',
  Duration? duration,
  bool instrumental = false,
  String? synced,
  String? plain,
}) => LyricCandidate(
  id: id,
  trackName: track,
  artistName: artist,
  albumName: album,
  duration: duration,
  instrumental: instrumental,
  syncedLyrics: synced,
  plainLyrics: plain,
);

void main() {
  // ─────────────────────────────────────────────────────── ① LRC 解析

  group('LRC 解析', () {
    test('标准逐行 + 毫秒两位', () {
      final doc = parseLrc(
        '[00:12.88] 你問我愛你有多深\n[00:19.15] 我愛你有幾分',
      );
      expect(doc.timed, isTrue);
      expect(doc.lines, hasLength(2));
      expect(doc.lines[0].text, '你問我愛你有多深');
      expect(doc.lines[0].time, const Duration(seconds: 12, milliseconds: 880));
      expect(doc.lines[1].time, const Duration(seconds: 19, milliseconds: 150));
    });

    test('一行多个时间标签 → 展开成多行（歌词会重复出现，LRC 就是这么定义的）', () {
      final doc = parseLrc('[00:01.00][01:20.00]副歌');
      expect(doc.lines, hasLength(2));
      expect(doc.lines[0].time, const Duration(seconds: 1));
      expect(doc.lines[1].time, const Duration(seconds: 80));
      expect(doc.lines.every((l) => l.text == '副歌'), isTrue);
    });

    test('毫秒位 1 / 2 / 3 位都按十进制位权解释', () {
      final doc = parseLrc('[00:01.5]a\n[00:02.50]b\n[00:03.500]c');
      expect(doc.lines[0].time, const Duration(seconds: 1, milliseconds: 500));
      expect(doc.lines[1].time, const Duration(seconds: 2, milliseconds: 500));
      expect(doc.lines[2].time, const Duration(seconds: 3, milliseconds: 500));
    });

    test('`[mm:ss]`（无毫秒）也要能解析', () {
      final doc = parseLrc('[01:05]整段');
      expect(doc.lines.single.time, const Duration(minutes: 1, seconds: 5));
    });

    test('元数据标签（ti/ar/al/by）不算歌词行', () {
      final doc = parseLrc(
        '[ti:Hey Jude]\n[ar:The Beatles]\n[al:Blue]\n[by:x]\n[00:00.35] Hey Jude',
      );
      expect(doc.lines, hasLength(1));
      expect(doc.lines.single.text, 'Hey Jude');
      // 标签不能混进正文
      expect(doc.lines.single.text.contains('ti:'), isFalse);
    });

    test('`[offset:]` 整体平移（正数 = 提前，与 LRC 惯例一致）', () {
      final doc = parseLrc('[offset:500]\n[00:10.00]a');
      expect(doc.lines.single.time, const Duration(seconds: 9, milliseconds: 500));
    });

    test('offset 平移后不会出现负时间（钳到 0）', () {
      final doc = parseLrc('[offset:5000]\n[00:01.00]a');
      expect(doc.lines.single.time, Duration.zero);
    });

    test('文件里时间顺序乱了（少见但存在）→ 结果按时间升序排好', () {
      // 注意：`offset` 是**整体平移**（单调），它**不可能**让顺序乱掉；
      // 真会乱的是文件本身写反了时间戳。
      final doc = parseLrc('[00:10.00]a\n[00:05.00]b');
      expect(doc.lines.map((l) => l.text).toList(), ['b', 'a']);
    });

    test('完全没有时间戳 → 退化成纯文本（**照实显示**，不假装能高亮）', () {
      final doc = parseLrc('第一行\n\n第二行');
      expect(doc.timed, isFalse);
      expect(doc.lines, isEmpty);
      expect(doc.plainText, contains('第一行'));
      expect(doc.plainText, contains('第二行'));
    });

    test('空串 / 纯空白 → 空文档', () {
      expect(parseLrc('').isEmpty, isTrue);
      expect(parseLrc('   \n  \n').isEmpty, isTrue);
    });

    test('带时间戳的空行**保留**（LRC 里是间奏标记，界面画成 ♪）；纯空白文本不算歌词', () {
      final doc = parseLrc('[00:49.81] \n[00:52.87] real');
      expect(doc.lines, hasLength(2));
      expect(doc.lines[0].time, const Duration(seconds: 49, milliseconds: 810));
      // 空正文 ⇒ 空串（界面据此画 ♪，而不是"歌词突然少一段"）
      expect(doc.lines[0].text, isEmpty);
      expect(doc.lines[1].text, 'real');
      // 完全没有时间戳的空白文本 → 不成文档
      expect(parseLrc('   \n  ').isEmpty, isTrue);
    });
  });

  group('当前高亮行（二分查找）', () {
    final lines = parseLrc(
      '[00:01.00]A\n[00:05.00]B\n[00:09.00]C',
    ).lines;

    test('还没到第一行 → -1（不高亮任何一行）', () {
      expect(activeLyricIndex(lines, Duration.zero), -1);
      expect(activeLyricIndex(lines, const Duration(milliseconds: 900)), -1);
    });

    test('正好落在某一行 → 那一行', () {
      expect(activeLyricIndex(lines, const Duration(seconds: 1)), 0);
      expect(activeLyricIndex(lines, const Duration(seconds: 5)), 1);
      expect(activeLyricIndex(lines, const Duration(seconds: 9)), 2);
    });

    test('两行之间 → 前一行', () {
      expect(activeLyricIndex(lines, const Duration(seconds: 4)), 0);
      expect(activeLyricIndex(lines, const Duration(seconds: 8)), 1);
    });

    test('超过最后一行 → 最后一行（不越界）', () {
      expect(activeLyricIndex(lines, const Duration(minutes: 10)), 2);
    });

    test('空列表 → -1', () {
      expect(activeLyricIndex(const [], const Duration(seconds: 3)), -1);
    });
  });

  // ─────────────────────────────────────────────────── ② 查询与候选

  group('文件名 → 歌词查询', () {
    test('`歌手 - 曲名` 形态拆成 artist + title', () {
      final q = lyricsQueryForFileName('The Beatles - Hey Jude.mp3');
      expect(q.artist, 'The Beatles');
      expect(q.title, 'Hey Jude');
    });

    test('前导音轨号被剥掉（`01 - `）', () {
      final q = lyricsQueryForFileName('01 - The Beatles - Hey Jude.mp3');
      expect(q.artist, 'The Beatles');
      expect(q.title, 'Hey Jude');
    });

    test('`01. 曲名` / `07_曲名` / `[03] 曲名` 都剥掉音轨号', () {
      expect(lyricsQueryForFileName('01. Hey Jude.mp3').title, 'Hey Jude');
      expect(lyricsQueryForFileName('07_Hey Jude.flac').title, 'Hey Jude');
      expect(lyricsQueryForFileName('[03] Hey Jude.m4a').title, 'Hey Jude');
    });

    test('没有歌手信息时 artist 留空（不猜）', () {
      final q = lyricsQueryForFileName('Hey Jude.mp3');
      expect(q.artist, isEmpty);
      expect(q.title, 'Hey Jude');
    });

    test('两段以上的连字符**不拆**（别把曲名拆坏）', () {
      final q = lyricsQueryForFileName('Love - Hate - Remix.mp3');
      expect(q.artist, isEmpty);
      expect(q.title, 'Love - Hate - Remix');
    });

    test('扩展名只剥最后一个点', () {
      expect(lyricsQueryForFileName('Hey Jude (Remastered).mp3').title,
          'Hey Jude (Remastered)');
    });

    test('缓存 key 含时长与文件名（不同版本不互相覆盖），且不含凭据', () {
      final a = lyricsQueryForFileName('x.mp3', duration: const Duration(seconds: 100));
      final b = lyricsQueryForFileName('x.mp3', duration: const Duration(seconds: 200));
      expect(a.cacheKey, isNot(b.cacheKey));
      expect(a.cacheKey.contains('_sid'), isFalse);
    });
  });

  group('候选宽松解析（真机字段可能不是数字）', () {
    test('duration 是字符串小数（实测 `211.109025`）也要解析', () {
      final c = LyricCandidate.fromJson(
        jsonDecode(
          '{"id":27214605,"trackName":"月亮代表我的心","artistName":"邓丽君",'
          '"duration":"211.109025","instrumental":false,'
          '"syncedLyrics":"[00:12.88] 你問我愛你有多深"}',
        ),
      );
      expect(c, isNotNull);
      expect(c!.duration!.inMilliseconds, 211109);
    });

    test('id 是字符串、instrumental 是 "1" 也不崩', () {
      final c = LyricCandidate.fromJson(
        jsonDecode(
          '{"id":"36839770","trackName":"Hey Jude","artistName":"The Beatles",'
          '"duration":426.0,"instrumental":"1"}',
        ),
      );
      expect(c!.id, 36839770);
      expect(c.instrumental, isTrue);
    });

    test('缺 trackName 时回退 name 字段；两者都缺 → null（不编一条）', () {
      expect(
        LyricCandidate.fromJson(jsonDecode('{"id":1,"name":"FromName"}'))!
            .trackName,
        'FromName',
      );
      expect(LyricCandidate.fromJson(jsonDecode('{"id":1}')), isNull);
      expect(LyricCandidate.fromJson('not a map'), isNull);
      expect(LyricCandidate.fromJson(null), isNull);
    });

    test('优先 syncedLyrics；没有则用 plainLyrics；两者都空 → 文档为空', () {
      final withSynced = _cand(
        id: 1,
        track: 't',
        synced: '[00:01.00]a',
        plain: 'plain 版本',
      );
      expect(withSynced.toDocument().timed, isTrue);
      final plainOnly = _cand(id: 2, track: 't', plain: 'plain 版本');
      expect(plainOnly.toDocument().timed, isFalse);
      expect(plainOnly.toDocument().plainText, 'plain 版本');
      expect(_cand(id: 3, track: 't').toDocument().isEmpty, isTrue);
    });

    test('时长显示：未知给 --:--，已知给 m:ss', () {
      expect(_cand(id: 1, track: 't').durationLabel(), '--:--');
      expect(
        _cand(id: 2, track: 't', duration: const Duration(seconds: 206)).durationLabel(),
        '3:26',
      );
    });
  });

  group('候选排序（决定"自动给哪一份歌词"）', () {
    test('时长最接近的排第一（实测同一歌名有 20 条候选，时长差 25 秒）', () {
      final ranked = rankLyricCandidates(
        [
          _cand(id: 1, track: 'x', duration: const Duration(seconds: 231), synced: 'a'),
          _cand(id: 2, track: 'x', duration: const Duration(seconds: 206), synced: 'a'),
        ],
        duration: const Duration(seconds: 207),
      );
      expect(ranked.first.id, 2);
    });

    test('歌手对得上的加分（同曲不同歌手时不会选错人）', () {
      final ranked = rankLyricCandidates(
        [
          _cand(id: 1, track: 'x', artist: '王小帅', synced: 'a'),
          _cand(id: 2, track: 'x', artist: '邓丽君', synced: 'a'),
        ],
        artist: '邓丽君',
      );
      expect(ranked.first.id, 2);
    });

    test('纯器乐条目的分数被压低', () {
      final ranked = rankLyricCandidates(
        [
          _cand(id: 1, track: 'x', instrumental: true, synced: 'a'),
          _cand(id: 2, track: 'x', synced: 'a'),
        ],
      );
      expect(ranked.first.id, 2);
    });

    test('没有时长/歌手线索时保持源站顺序（稳定）', () {
      final ranked = rankLyricCandidates(
        [
          _cand(id: 1, track: 'x', synced: 'a'),
          _cand(id: 2, track: 'y', synced: 'a'),
        ],
      );
      expect(ranked.map((c) => c.id).toList(), [1, 2]);
    });
  });

  // ─────────────────────────────────────────────── LRCLIB 端点与响应

  group('lrclib 端点（参数逐字对齐实测 curl）', () {
    test('/api/search?q= 且中文正确 URL 编码', () {
      final uri = LrclibLyricsSource.searchUri('月亮代表我的心');
      expect(uri.host, 'lrclib.net');
      expect(uri.path, '/api/search');
      expect(uri.queryParameters['q'], '月亮代表我的心');
      expect(uri.toString(), contains('%E6%9C%88'));
    });

    test('/api/get/<id>（实测可用）', () {
      final uri = LrclibLyricsSource.getUri(13781);
      expect(uri.toString(), 'https://lrclib.net/api/get/13781');
    });
  });

  group('LrclibLyricsSource 的状态码语义', () {
    test('search 200 + 数组 → 候选（`[]` = 搜索无结果，不是失败）', () async {
      final http = _FakeHttp(
        (_) => const LyricsHttpResponse(
          statusCode: 200,
          body: '[{"id":1,"trackName":"a","duration":10.0,'
              '"syncedLyrics":"[00:01.00]x"}]',
        ),
      );
      final source = LrclibLyricsSource(http: http);
      final list = await source.search(const LyricsQuery(title: 'a'));
      expect(list, hasLength(1));
      expect(list.single.id, 1);

      final empty = LrclibLyricsSource(
        http: _FakeHttp((_) => const LyricsHttpResponse(statusCode: 200, body: '[]')),
      );
      expect(await empty.search(const LyricsQuery(title: 'zzz')), isEmpty);
    });

    test('search 只有标题没结果、但知道歌手 → 用「歌手 标题」再试一次', () async {
      final http = _FakeHttp(
        (uri) => uri.queryParameters['q'] == 'a b'
            ? const LyricsHttpResponse(
                statusCode: 200,
                body: '[{"id":9,"trackName":"b"}]',
              )
            : const LyricsHttpResponse(statusCode: 200, body: '[]'),
      );
      final source = LrclibLyricsSource(http: http);
      final list = await source.search(
        const LyricsQuery(title: 'b', artist: 'a'),
      );
      expect(list.single.id, 9);
      expect(http.calls, hasLength(2));
      expect(http.calls[1].queryParameters['q'], 'a b');
    });

    test('/api/get 404 + TrackNotFound → null（**明确的"没这首歌"**）', () async {
      final source = LrclibLyricsSource(
        http: _FakeHttp(
          (_) => const LyricsHttpResponse(
            statusCode: 404,
            body: '{"message":"Failed to find specified track",'
                '"name":"TrackNotFound","statusCode":404}',
          ),
        ),
      );
      expect(await source.fetchById(123), isNull);
    });

    test('5xx → server 失败（不是"没找到"）', () async {
      final source = LrclibLyricsSource(
        http: _FakeHttp((_) => const LyricsHttpResponse(statusCode: 502, body: 'oops')),
      );
      await expectLater(
        () => source.search(const LyricsQuery(title: 'a')),
        throwsA(
          isA<LyricsFetchException>().having(
            (e) => e.kind,
            'kind',
            LyricsFailureKind.server,
          ),
        ),
      );
    });

    test('正文不是 JSON / JSON 不是数组 → badResponse（不说"没找到"骗人）', () async {
      final notJson = LrclibLyricsSource(
        http: _FakeHttp((_) => const LyricsHttpResponse(statusCode: 200, body: '<html>')),
      );
      await expectLater(
        () => notJson.search(const LyricsQuery(title: 'a')),
        throwsA(
          isA<LyricsFetchException>().having(
            (e) => e.kind,
            'kind',
            LyricsFailureKind.badResponse,
          ),
        ),
      );
      final notList = LrclibLyricsSource(
        http: _FakeHttp((_) => const LyricsHttpResponse(statusCode: 200, body: '{"a":1}')),
      );
      await expectLater(
        () => notList.search(const LyricsQuery(title: 'a')),
        throwsA(isA<LyricsFetchException>()),
      );
    });

    test('SocketException → offline；TimeoutException → timeout（分开报）', () async {
      final offline = LrclibLyricsSource(
        http: _FakeHttp((_) => throw const SocketException('no network')),
      );
      await expectLater(
        () => offline.search(const LyricsQuery(title: 'a')),
        throwsA(
          isA<LyricsFetchException>().having(
            (e) => e.kind,
            'kind',
            LyricsFailureKind.offline,
          ),
        ),
      );
      final slow = LrclibLyricsSource(
        http: _FakeHttp((_) => throw TimeoutException('slow')),
      );
      await expectLater(
        () => slow.search(const LyricsQuery(title: 'a')),
        throwsA(
          isA<LyricsFetchException>().having(
            (e) => e.kind,
            'kind',
            LyricsFailureKind.timeout,
          ),
        ),
      );
    });
  });

  // ─────────────────────────────────────────────────────────── ③ 编排

  group('LyricsLookup：缓存 → 搜索 → 选最优 → 写缓存', () {
    const query = LyricsQuery(
      title: 'Hey Jude',
      artist: 'The Beatles',
      identity: 'song.mp3',
    );

    test('搜索命中：自动挑时长最接近的，并把结果写进缓存（下次离线可用）', () async {
      final source = _FakeSource(
        results: [
          _cand(
            id: 1,
            track: 'Hey Jude',
            artist: 'Someone',
            duration: const Duration(seconds: 240),
            synced: '[00:01.00]wrong',
          ),
          _cand(
            id: 2,
            track: 'Hey Jude',
            artist: 'The Beatles',
            duration: const Duration(seconds: 431),
            synced: '[00:00.35] Hey Jude',
          ),
        ],
      );
      final cache = InMemoryLyricsCache();
      final lookup = LyricsLookup(source: source, cache: cache);
      final result = await lookup.search(
        const LyricsQuery(
          title: 'Hey Jude',
          artist: 'The Beatles',
          duration: Duration(seconds: 431),
          identity: 'song.mp3',
        ),
      );
      expect(result.hasLyrics, isTrue);
      expect(result.chosen!.id, 2);
      expect(result.candidates, hasLength(2));

      // 命中缓存 → **不再**联网
      final again = await lookup.fromCache(
        const LyricsQuery(
          title: 'Hey Jude',
          artist: 'The Beatles',
          duration: Duration(seconds: 431),
          identity: 'song.mp3',
        ),
      );
      expect(again.fromCache, isTrue);
      expect(again.document!.lines.single.text, 'Hey Jude');
    });

    test('缓存为空时不编造：返回空结果（界面据此去联网）', () async {
      final lookup = LyricsLookup(source: _FakeSource());
      final result = await lookup.fromCache(query);
      expect(result.hasLyrics, isFalse);
      expect(result.fromCache, isFalse);
    });

    test('搜索无结果 → notFound（"没这首歌"，与网络失败分开）', () async {
      final lookup = LyricsLookup(source: _FakeSource());
      final result = await lookup.search(query);
      expect(result.failure, LyricsFailureKind.notFound);
      expect(result.hasLyrics, isFalse);
    });

    test('搜到条目但源站没有歌词正文 → 也给 notFound，并保留候选（可换版本）',
        () async {
      final lookup = LyricsLookup(
        source: _FakeSource(results: [_cand(id: 1, track: 'Hey Jude')]),
      );
      final result = await lookup.search(query);
      expect(result.failure, LyricsFailureKind.notFound);
      expect(result.candidates, hasLength(1));
      expect(result.chosen, isNull);
    });

    test('网络失败 → 原样上报（离线/超时都在这里透出去）', () async {
      for (final kind in [
        LyricsFailureKind.offline,
        LyricsFailureKind.timeout,
        LyricsFailureKind.server,
        LyricsFailureKind.badResponse,
      ]) {
        final lookup = LyricsLookup(
          source: _FakeSource(failWith: kind),
          retryDelay: Duration.zero,
        );
        final result = await lookup.search(query);
        expect(result.failure, kind, reason: '$kind 必须如实上报');
      }
    });

    test('★ 源站过载（5xx）自动重试一次；其它失败**不**重试', () async {
      // 实测依据：lrclib 会回 503 ServerOverloaded，隔几秒就好（见文件头 ③'）
      const tick = Duration(milliseconds: 1); // >0 才启用自动重试
      final overloaded = _FakeSource()..serverOverloadTimes = 99;
      final serverResult = await LyricsLookup(
        source: overloaded,
        retryDelay: tick,
      ).search(query);
      expect(serverResult.failure, LyricsFailureKind.server);
      expect(overloaded.searched, hasLength(2), reason: '5xx 应该自动再试一次');

      for (final kind in [
        LyricsFailureKind.offline,
        LyricsFailureKind.timeout,
        LyricsFailureKind.badResponse,
      ]) {
        final src = _FakeSource(failWith: kind);
        await LyricsLookup(source: src, retryDelay: tick).search(query);
        expect(src.searched, hasLength(1), reason: '$kind 不该重试');
      }
    });

    test('★ retryDelay = 0 → 关掉自动重试（单测默认不白等）', () async {
      final src = _FakeSource()..serverOverloadTimes = 99;
      final r = await LyricsLookup(
        source: src,
        retryDelay: Duration.zero,
      ).search(query);
      expect(r.failure, LyricsFailureKind.server);
      expect(src.searched, hasLength(1));
    });

    test('★ 第一次 5xx、重试成功 → 用户看到的是歌词（不是错误）', () async {
      final flaky = _FakeSource()
        ..serverOverloadTimes = 1
        ..results = [
          _cand(id: 1, track: 'Hey Jude', synced: '[00:01.00]ok'),
        ];
      final r = await LyricsLookup(
        source: flaky,
        retryDelay: const Duration(milliseconds: 1),
      ).search(query);
      expect(flaky.searched, hasLength(2));
      expect(r.hasLyrics, isTrue);
      expect(r.failure, isNull);
      expect(r.document!.lines.single.text, 'ok');
    });

    test('曲名为空 → 不发请求（不瞎猜）', () async {
      final source = _FakeSource();
      final lookup = LyricsLookup(source: source);
      final result = await lookup.search(const LyricsQuery(title: '  '));
      expect(source.searched, isEmpty);
      expect(result.hasLyrics, isFalse);
    });

    test('手动选一个：候选自带正文时**不再**发第二次请求', () async {
      final source = _FakeSource();
      final lookup = LyricsLookup(source: source);
      final cand = _cand(
        id: 7,
        track: 'Hey Jude',
        synced: '[00:01.00]hi',
      );
      final result = await lookup.choose(query, cand);
      expect(result.hasLyrics, isTrue);
      expect(source.fetchedIds, isEmpty);
    });

    test('手动选一个：候选没有正文 → 按 id 去取；取回来仍为空 → notFound', () async {
      final source = _FakeSource(
        byId: {
          7: _cand(id: 7, track: 'Hey Jude', synced: '[00:01.00]fetched'),
        },
      );
      final lookup = LyricsLookup(source: source);
      final result = await lookup.choose(query, _cand(id: 7, track: 'Hey Jude'));
      expect(source.fetchedIds, [7]);
      expect(result.document!.lines.single.text, 'fetched');

      final emptySource = _FakeSource(byId: {8: _cand(id: 8, track: 'x')});
      final emptyLookup = LyricsLookup(source: emptySource);
      final empty = await emptyLookup.choose(query, _cand(id: 8, track: 'x'));
      expect(empty.failure, LyricsFailureKind.notFound);
    });

    test('手动选一个：按 id 取的时候网络失败 → 如实上报', () async {
      final lookup = LyricsLookup(
        source: _FakeSource(failByIdWith: LyricsFailureKind.offline),
      );
      final result = await lookup.choose(query, _cand(id: 7, track: 'x'));
      expect(result.failure, LyricsFailureKind.offline);
    });

    test('坏缓存（不是 JSON / 没有 chosen）当没有，不抛异常', () async {
      final cache = InMemoryLyricsCache();
      await cache.write(query.cacheKey, 'not json');
      expect(
        (await LyricsLookup(source: _FakeSource(), cache: cache).fromCache(query))
            .hasLyrics,
        isFalse,
      );
      await cache.write(query.cacheKey, jsonEncode({'chosen': 'oops'}));
      expect(
        (await LyricsLookup(source: _FakeSource(), cache: cache).fromCache(query))
            .hasLyrics,
        isFalse,
      );
    });

    test('clear() 之后缓存不再命中', () async {
      final cache = InMemoryLyricsCache();
      final lookup = LyricsLookup(source: _FakeSource(), cache: cache);
      await lookup.choose(query, _cand(id: 1, track: 'x', plain: '词'));
      expect((await lookup.fromCache(query)).hasLyrics, isTrue);
      await lookup.clear(query);
      expect((await lookup.fromCache(query)).hasLyrics, isFalse);
    });
  });

  group('FileLyricsCache（应用文档目录 JSON）', () {
    test('写进去的歌词下次读得到（跨实例）', () async {
      final dir = await Directory.systemTemp.createTemp('lyrics-cache-test');
      addTearDown(() => dir.delete(recursive: true));
      final cache = FileLyricsCache(dirResolver: () async => dir);
      const key = 'Hey Jude|the beatles|431|song.mp3';
      await cache.write(key, '{"hello":1}');
      // 另一个实例（模拟"下次打开 App"）
      final reopened = FileLyricsCache(dirResolver: () async => dir);
      expect(await reopened.read(key), '{"hello":1}');
      await reopened.remove(key);
      expect(await reopened.read(key), isNull);
      // 文件名是稳定散列，不含原始 key（路径安全、无凭据）
      expect(FileLyricsCache.fileNameFor(key), startsWith('lyrics-'));
      expect(FileLyricsCache.fileNameFor(key).contains('Jude'), isFalse);
      expect(
        FileLyricsCache.fileNameFor(key),
        FileLyricsCache.fileNameFor(key),
      );
    });

    test('拿不到目录（纯测试/无平台通道）→ 退回内存，**不抛**', () async {
      final cache = FileLyricsCache(dirResolver: () async => null);
      await cache.write('k', 'v');
      expect(await cache.read('k'), 'v');
    });
  });
  // ─────────────────────────────────── ★ DA53/DA54（r403：真机实证的歌词张冠李戴）

  group('★ DA53：歌词不许"张冠李戴"（真机实证 Demo Song / Demo Artist）', () {
    test('带歌手 → 用 track_name + artist_name 结构化搜（不再只按标题搜）', () async {
      final uris = <Uri>[];
      final http = _FakeHttp((uri) {
        uris.add(uri);
        return const LyricsHttpResponse(
          statusCode: 200,
          body:
              '[{"id":7,"trackName":"Demo Song","artistName":"Demo Artist",'
              '"duration":231.0,"syncedLyrics":"[00:01.00]Sample lyric line one"}]',
        );
      });
      final list = await LrclibLyricsSource(http: http).search(
        const LyricsQuery(title: 'Demo Song', artist: 'Demo Artist'),
      );
      expect(uris, hasLength(1));
      expect(uris.single.queryParameters['track_name'], 'Demo Song');
      expect(uris.single.queryParameters['artist_name'], 'Demo Artist');
      expect(uris.single.queryParameters.containsKey('q'), isFalse);
      expect(list.single.artistName, 'Demo Artist');
    });

    test('结构化搜不到 → 退回"歌手 标题"（只多一次请求）', () async {
      final uris = <Uri>[];
      final http = _FakeHttp((uri) {
        uris.add(uri);
        final isStructured = uri.queryParameters.containsKey('track_name');
        return LyricsHttpResponse(
          statusCode: 200,
          body: isStructured
              ? '[]'
              : '[{"id":8,"trackName":"Demo Song","artistName":"Demo Artist",'
                    '"duration":231.0,"syncedLyrics":"[00:01.00]x"}]',
        );
      });
      final list = await LrclibLyricsSource(http: http).search(
        const LyricsQuery(title: 'Demo Song', artist: 'Demo Artist'),
      );
      expect(uris, hasLength(2));
      expect(uris.first.queryParameters['track_name'], 'Demo Song');
      expect(uris.last.queryParameters['q'], 'Demo Artist Demo Song');
      expect(list, hasLength(1));
    });

    test('源站里全是别人的歌 ⇒ 如实说"没有"，不许把别人的歌词当本曲显示', () async {
      // 真机实测：`q=Demo Song` 的 20 条**没有 Demo Artist**，排第一的是
      // `On Demo Song / Mia Love`（223 s，歌词就是屏上那份 "(That's on my love)"）
      final source = _FakeSource(
        results: [
          _cand(
            id: 1,
            track: 'On Demo Song',
            artist: 'Mia Love',
            duration: const Duration(seconds: 223),
            synced: "[00:01.00]Now I don't need the time to make up my mind",
          ),
          _cand(
            id: 2,
            track: 'Left Demo Song',
            artist: 'East Love',
            duration: const Duration(seconds: 225),
            synced: '[00:01.00]x',
          ),
        ],
      );
      final r = await LyricsLookup(source: source).search(
        const LyricsQuery(
          title: 'Demo Song',
          artist: 'Demo Artist',
          duration: Duration(seconds: 231),
          identity: 'music_28045',
        ),
      );
      expect(
        r.hasLyrics,
        isFalse,
        reason: '修前：Mia Love 的《On Demo Song》被当成本曲歌词显示',
      );
      expect(r.failure, LyricsFailureKind.notFound);
      expect(r.candidates, hasLength(2), reason: '候选仍带出去，留给"换一个"入口');
    });

    test('歌手对得上的那条仍照常选出来（门槛 ≠ 一律不显示）', () async {
      final source = _FakeSource(
        results: [
          _cand(
            id: 1,
            track: 'Demo Song',
            artist: 'Demo Artist',
            duration: const Duration(seconds: 231),
            synced: '[00:01.00]Sample lyric line one',
          ),
          _cand(
            id: 2,
            track: 'On Demo Song',
            artist: 'Mia Love',
            duration: const Duration(seconds: 223),
            synced: '[00:01.00]wrong',
          ),
        ],
      );
      final r = await LyricsLookup(source: source).search(
        const LyricsQuery(title: 'Demo Song', artist: 'Demo Artist'),
      );
      expect(r.hasLyrics, isTrue);
      expect(r.chosen!.id, 1);
      expect(r.document!.lines.single.text, 'Sample lyric line one');
    });

    test('旧版本号的缓存不许再用（DA53 的旧缓存整代作废）', () async {
      final cache = InMemoryLyricsCache();
      const q = LyricsQuery(
        title: 'Demo Song',
        artist: 'Demo Artist',
        identity: 'music_28045',
      );
      await cache.write(
        q.cacheKey,
        jsonEncode({
          'version': 1, // 旧格式（= 可能存着别人的歌词）
          'chosen': const LyricCandidate(
            id: 9,
            trackName: 'On Demo Song',
            artistName: 'Mia Love',
            syncedLyrics: '[00:01.00]wrong',
          ).toJson(),
        }),
      );
      final r = await LyricsLookup(
        source: _FakeSource(),
        cache: cache,
      ).fromCache(q);
      expect(r.fromCache, isFalse);
      expect(r.hasLyrics, isFalse);
    });
  });

  group('★ DA54：缓存 round-trip 不许把时长放大 1000 倍', () {
    test('写缓存 → 读缓存，时长与曲名/歌手完全一致', () async {
      final cache = InMemoryLyricsCache();
      final lookup = LyricsLookup(
        source: _FakeSource(
          results: [
            _cand(
              id: 5,
              track: 'Hey Jude',
              artist: 'The Beatles',
              duration: const Duration(seconds: 431),
              synced: '[00:00.35] Hey Jude',
            ),
          ],
        ),
        cache: cache,
      );
      const q = LyricsQuery(
        title: 'Hey Jude',
        artist: 'The Beatles',
        duration: Duration(seconds: 431),
        identity: 'song.mp3',
      );
      await lookup.search(
        const LyricsQuery(
          title: 'Hey Jude',
          artist: 'The Beatles',
          duration: Duration(seconds: 431),
          identity: 'song.mp3',
        ),
      );
      final again = await lookup.fromCache(q);
      expect(again.fromCache, isTrue);
      expect(again.chosen!.duration, const Duration(seconds: 431));
      expect(again.chosen!.durationLabel(), '7:11');
    });
  });

}
