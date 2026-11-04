// G1 批次（相册未实现功能补齐）—— **接口层 / 状态层**离线测试。
//
// 覆盖 8 行的接口与纯逻辑（全部离线，不连 NAS、不碰平台通道）：
//   * P4  网格密度：列数收敛/编解码 + 落盘 notifier；
//   * P15 HEIC：`RegeneratePreview` v1 `list_regenerating`（只读）/
//          `regenerate_preview_by_nas`（写，仅用户确认后）请求形状 + 格式判定；
//   * P16 RAW/AVIF：扩展名分类 + 兜底文案；
//   * P24 最近搜索：去重/裁剪/编解码 + 落盘 notifier；
//   * P25 全局搜索照片：`Search.Search/list_item` v7 请求形状；
//   * P29 删除撤销：延迟删除状态机（撤销 = **零请求**）+ 真删走的接口形状；
//   * P48 播放设置：URL 改写纯函数 + 落盘 notifier + `fotoSpaceApiProvider` 端到端；
//   * P49 幻灯片：顺序/随机序列 + 设置收敛 + 落盘 notifier。
//
// 变更动词声明：本文件**没有**在探测/用例循环里调用任何服务端写接口；
// `regenerate_preview_by_nas` 与 `Browse.Item/delete` 只出现在"断言它被调了 /
// 没被调"的断言里，且全部打在 `FakeTransport` 上（没有真实 NAS 流量）。
import 'dart:convert';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:synhub/l10n/gen/app_localizations_en.dart';
import 'package:synhub/l10n/gen/app_localizations_zh.dart';
import 'package:synhub/src/core/i18n/l10n.dart';
import 'package:synhub/src/data/foto_api.dart';
import 'package:synhub/src/data/foto_c2_api.dart';
import 'package:synhub/src/dsm/webapi.dart';
import 'package:synhub/src/features/photos/photo_delete_undo.dart';
import 'package:synhub/src/features/photos/photo_format_support.dart';
import 'package:synhub/src/features/photos/photo_grid_density.dart';
import 'package:synhub/src/features/photos/photo_playback_settings.dart';
import 'package:synhub/src/features/photos/photo_prefs_store.dart';
import 'package:synhub/src/features/photos/photo_providers.dart';
import 'package:synhub/src/features/photos/photo_search_history.dart';
import 'package:synhub/src/features/photos/photo_slideshow.dart';

import 'support/chat_harness.dart' show FakeTransport;

// ---------------------------------------------------------------- 测试脚手架

/// 内存版本地偏好存储（绝不碰 `flutter_secure_storage` 的平台通道）。
class _MemPrefs implements PhotoPrefsStore {
  final Map<String, String> data = {};

  @override
  Future<String?> read(String key) async => data[key];

  @override
  Future<void> write(String key, String value) async => data[key] = value;

  @override
  Future<void> delete(String key) async => data.remove(key);
}

/// 固定播放设置的 notifier。
class _FixedPlayback extends PhotoPlaybackSettingsNotifier {
  _FixedPlayback(this.value);
  final PhotoPlaybackSettings value;

  @override
  PhotoPlaybackSettings build() => value;
}

const _fotoTable = {
  'SYNO.API.Info': {'path': 'query.cgi', 'minVersion': 1, 'maxVersion': 1},
  'SYNO.Foto.RegeneratePreview': {
    'path': 'entry.cgi',
    'minVersion': 1,
    'maxVersion': 1,
  },
  'SYNO.Foto.Search.Search': {
    'path': 'entry.cgi',
    'minVersion': 1,
    'maxVersion': 7,
  },
  'SYNO.Foto.Download': {'path': 'entry.cgi', 'minVersion': 1, 'maxVersion': 2},
  'SYNO.Foto.Streaming': {
    'path': 'entry.cgi',
    'minVersion': 1,
    'maxVersion': 2,
  },
  'SYNO.Foto.Browse.Item': {
    'path': 'entry.cgi',
    'minVersion': 1,
    'maxVersion': 7,
  },
};

Future<DsmWebApi> _loggedIn(FakeTransport t) async {
  final api = DsmWebApi(t);
  await api.discover();
  await api.login(account: 'a', password: 'b');
  return api;
}

FakeTransport _transport({
  Map<String, Map<String, dynamic>> responses = const {},
  Map<String, int> failures = const {},
}) {
  final t = FakeTransport(
    {...responses},
    {...FakeTransport.table, ..._fotoTable},
  );
  t.onCall = (params) =>
      responses['${params['api']}.${params['method']}'] ??
      const <String, dynamic>{};
  t.failures.addAll(failures);
  return t;
}

int _calls(FakeTransport t, String api, String method) =>
    t.calls.where((c) => c['api'] == api && c['method'] == method).length;

Map<String, dynamic> _last(FakeTransport t, String api, String method) =>
    t.calls.lastWhere((c) => c['api'] == api && c['method'] == method);

void main() {
  // ================================================================ P4 网格密度

  group('P4 网格密度（纯逻辑 + 落盘）', () {
    test('normalize：非法值收敛到最近合法档，认不出回默认 3', () {
      expect(normalizePhotoGridColumns(4), 4);
      expect(normalizePhotoGridColumns(99), 5);
      expect(normalizePhotoGridColumns(0), 2);
      expect(normalizePhotoGridColumns(null), 3);
      expect(normalizePhotoGridColumns('abc'), 3);
      expect(normalizePhotoGridColumns('5'), 5);
    });

    test('encode/decode：往返一致，坏值回落默认', () {
      expect(decodePhotoGridColumns(encodePhotoGridColumns(4)), 4);
      expect(decodePhotoGridColumns(null), 3);
      expect(decodePhotoGridColumns(''), 3);
      expect(decodePhotoGridColumns('oops'), 3);
    });

    test('notifier：写入落盘 + 启动时读回落盘值', () async {
      final store = _MemPrefs();
      final c = ProviderContainer(
        overrides: [photoPrefsStoreProvider.overrideWithValue(store)],
      );
      addTearDown(c.dispose);
      expect(c.read(photoGridColumnsProvider), 3);
      await c.read(photoGridColumnsProvider.notifier).setColumns(5);
      expect(c.read(photoGridColumnsProvider), 5);
      expect(store.data[kPhotoGridColumnsSlot], '5');

      // 新容器（模拟下次启动）→ 读回落盘值
      final c2 = ProviderContainer(
        overrides: [photoPrefsStoreProvider.overrideWithValue(store)],
      );
      addTearDown(c2.dispose);
      c2.read(photoGridColumnsProvider);
      await Future<void>.delayed(Duration.zero);
      expect(c2.read(photoGridColumnsProvider), 5);
    });
  });

  // ================================================================ P15 HEIC

  group('P15 HEIC 生成预览（RegeneratePreview v1）', () {
    test('list_regenerating：v1 + 只读，返回 list', () async {
      final t = _transport(
        responses: {
          'SYNO.Foto.RegeneratePreview.list_regenerating': {
            'list': [
              {'id': 1},
            ],
          },
        },
      );
      final api = await _loggedIn(t);
      final list = await FotoApi(api).listRegeneratingPreviews();
      expect(list, hasLength(1));
      final call = _last(t, 'SYNO.Foto.RegeneratePreview', 'list_regenerating');
      expect(call['version'], '1');
    });

    test('list_regenerating：回包没有 list → 空列表（不抛）', () async {
      final t = _transport();
      final api = await _loggedIn(t);
      expect(await FotoApi(api).listRegeneratingPreviews(), isEmpty);
    });

    test('regenerate_preview_by_nas：v1，无参（参数未取证 → 不猜）', () async {
      final t = _transport();
      final api = await _loggedIn(t);
      await FotoApi(api).regeneratePreviewByNas();
      final call = _last(
        t,
        'SYNO.Foto.RegeneratePreview',
        'regenerate_preview_by_nas',
      );
      expect(call['version'], '1');
      expect(call.containsKey('id'), isFalse);
    });

    test('格式判定：HEIC/HEIF 需要服务端预览，其它不需要', () {
      expect(photoNeedsServerPreview('IMG_0001.HEIC'), isTrue);
      expect(photoNeedsServerPreview('a.heif'), isTrue);
      expect(photoNeedsServerPreview('a.jpg'), isFalse);
      expect(photoNeedsServerPreview('a'), isFalse);
    });
  });

  // ================================================================ P16 RAW/AVIF

  group('P16 RAW / DNG / AVIF 兜底', () {
    test('RAW 家族 / AVIF 判为"官方不承诺"，普通格式不是', () {
      for (final n in ['a.dng', 'A.ARW', 'b.CR3', 'c.nef', 'd.raf', 'e.orf']) {
        expect(photoFormatNotPromised(n), isTrue, reason: n);
      }
      expect(photoFormatNotPromised('x.avif'), isTrue);
      expect(photoFormatNotPromised('x.jpg'), isFalse);
      expect(photoFormatNotPromised('x.mp4'), isFalse);
    });

    test('兜底文案按扩展名区分，且都非空', () {
      expect(photoFormatFallbackText('a.dng'), contains('RAW'));
      expect(photoFormatFallbackText('a.avif'), contains('AVIF'));
      expect(photoFormatFallbackText('a.heic'), isNotEmpty);
      expect(photoFormatFallbackText('a.unknown'), isNotEmpty);
      expect(photoFormatFallbackText('a.jpg'), isNull);
    });

    test('扩展名解析：大小写、无扩展名、尾点', () {
      expect(photoFileExtension('A.JPEG'), 'jpeg');
      expect(photoFileExtension('noext'), '');
      expect(photoFileExtension('trailing.'), '');
    });
  });

  // ================================================================ P24 最近搜索

  group('P24 最近搜索（纯逻辑 + 落盘）', () {
    test('add：去空白、去重（大小写不敏感）、提到最前、裁剪上限', () {
      expect(addPhotoSearchKeyword(const [], '  '), isEmpty);
      expect(addPhotoSearchKeyword(const ['a'], 'b'), ['b', 'a']);
      expect(addPhotoSearchKeyword(const ['a', 'b'], 'A'), ['A', 'b']);
      final many = [for (var i = 0; i < kPhotoSearchHistoryLimit; i++) 'k$i'];
      final out = addPhotoSearchKeyword(many, 'new');
      expect(out.first, 'new');
      expect(out, hasLength(kPhotoSearchHistoryLimit));
      expect(out.contains('k${kPhotoSearchHistoryLimit - 1}'), isFalse);
    });

    test('remove / encode / decode', () {
      expect(removePhotoSearchKeyword(['a', 'b'], 'A'), ['b']);
      final enc = encodePhotoSearchHistory(['x', 'y']);
      expect(decodePhotoSearchHistory(enc), ['x', 'y']);
      expect(decodePhotoSearchHistory('not json'), isEmpty);
      expect(decodePhotoSearchHistory('[1,2]'), isEmpty);
    });

    test('notifier：record / remove / clear 都落盘', () async {
      final store = _MemPrefs();
      final c = ProviderContainer(
        overrides: [photoPrefsStoreProvider.overrideWithValue(store)],
      );
      addTearDown(c.dispose);
      final n = c.read(photoSearchHistoryProvider.notifier);
      await n.record('cat');
      await n.record('dog');
      await n.record('cat');
      expect(c.read(photoSearchHistoryProvider), ['cat', 'dog']);
      expect(decodePhotoSearchHistory(store.data[kPhotoSearchHistorySlot]), [
        'cat',
        'dog',
      ]);
      await n.remove('cat');
      expect(c.read(photoSearchHistoryProvider), ['dog']);
      await n.clear();
      expect(c.read(photoSearchHistoryProvider), isEmpty);
      expect(store.data.containsKey(kPhotoSearchHistorySlot), isFalse);
    });
  });

  // ================================================================ P25 全局搜索照片

  group('P25 全局搜索含照片（Search.Search v7）', () {
    test('searchItems：api/method/version 与 keyword 参数', () async {
      final t = _transport(
        responses: {
          'SYNO.Foto.Search.Search.list_item': {
            'list': [
              {'id': '7', 'filename': 'IMG_1.jpg', 'type': 'photo'},
            ],
          },
        },
      );
      final api = await _loggedIn(t);
      final items = await FotoC2Api(
        FotoApi(api),
      ).searchItems({'keyword': 'IMG'}, limit: 30);
      expect(items, hasLength(1));
      expect(items.first.filename, 'IMG_1.jpg');
      final call = _last(t, 'SYNO.Foto.Search.Search', 'list_item');
      expect(call['version'], '7');
      expect(call['keyword'], 'IMG');
      expect(call['limit'], '30');
      expect(call['offset'], '0');
    });
  });

  // ================================================================ P29 删除撤销

  group('P29 删除后撤销（延迟删除状态机）', () {
    test('撤销：一个删除请求都不发', () async {
      final t = _transport();
      final api = await _loggedIn(t);
      final c = ProviderContainer(
        overrides: [
          fotoApiProvider.overrideWithValue(FotoApi(api)),
          photoDeleteGraceProvider.overrideWithValue(
            const Duration(milliseconds: 30),
          ),
        ],
      );
      addTearDown(c.dispose);
      final n = c.read(photoDeleteUndoProvider.notifier);
      final fut = n.begin(['1', '2']);
      expect(c.read(photoDeleteUndoProvider), ['1', '2']);
      expect(n.undo(), isTrue);
      final r = await fut;
      expect(r.undone, isTrue);
      expect(r.deletedCount, 0);
      expect(_calls(t, 'SYNO.Foto.Browse.Item', 'delete'), 0);
      expect(c.read(photoDeleteUndoProvider), isEmpty);
    });

    test('不撤销：窗口到点才真删，走 Browse.Item/delete v7 + id 数组', () async {
      final t = _transport(
        responses: {
          'SYNO.Foto.Browse.Item.delete': {'id': []},
        },
      );
      final api = await _loggedIn(t);
      final c = ProviderContainer(
        overrides: [
          fotoApiProvider.overrideWithValue(FotoApi(api)),
          photoDeleteGraceProvider.overrideWithValue(
            const Duration(milliseconds: 10),
          ),
        ],
      );
      addTearDown(c.dispose);
      final fut = c.read(photoDeleteUndoProvider.notifier).begin(['3']);
      final r = await fut;
      expect(r.undone, isFalse);
      expect(r.deletedCount, 1);
      expect(r.failed, isEmpty);
      final call = _last(t, 'SYNO.Foto.Browse.Item', 'delete');
      expect(call['version'], '7');
      expect(jsonDecode(call['id'] as String), [3]);
    });

    test('空 id：立刻返回"撤销"结果，不发请求', () async {
      final t = _transport();
      final api = await _loggedIn(t);
      final c = ProviderContainer(
        overrides: [fotoApiProvider.overrideWithValue(FotoApi(api))],
      );
      addTearDown(c.dispose);
      final r = await c.read(photoDeleteUndoProvider.notifier).begin(const []);
      expect(r.undone, isTrue);
      expect(_calls(t, 'SYNO.Foto.Browse.Item', 'delete'), 0);
    });
  });

  // ================================================================ P48 播放设置

  group('P48 播放设置（URL 改写 + 落盘 + 接线）', () {
    test('apply：useHttp / 端口 / 非法端口 / 非 URL 全覆盖', () {
      const none = FotoMediaUrlOverride();
      expect(none.isNoop, isTrue);
      const https =
          'https://nas.example.com:5001/webapi/entry.cgi?api=X&_sid=abc';
      expect(none.apply(https), https);

      const httpOnly = FotoMediaUrlOverride(useHttp: true);
      expect(
        httpOnly.apply(https),
        'http://nas.example.com:5001/webapi/entry.cgi?api=X&_sid=abc',
      );

      const withPort = FotoMediaUrlOverride(useHttp: true, httpPort: 8080);
      expect(
        withPort.apply(https),
        'http://nas.example.com:8080/webapi/entry.cgi?api=X&_sid=abc',
      );

      // 非法端口 → 只换 scheme，端口不动（绝不把好 URL 弄坏）
      const badPort = FotoMediaUrlOverride(useHttp: true, httpPort: 70000);
      expect(
        badPort.apply(https),
        'http://nas.example.com:5001/webapi/entry.cgi?api=X&_sid=abc',
      );

      // 解析不出来 / 空 → 原样
      expect(httpOnly.apply('not a url'), 'not a url');
      expect(httpOnly.apply(''), '');
      expect(FotoMediaUrlOverride.validatePort(0), isNotNull);
      expect(FotoMediaUrlOverride.validatePort(65536), isNotNull);
      expect(FotoMediaUrlOverride.validatePort(5000), isNull);
    });

    test('PhotoPlaybackSettings：JSON 往返 + 端口解析 + 校验', () {
      const s = PhotoPlaybackSettings(
        useHttp: true,
        httpPort: 8080,
        ignoreCert: true,
      );
      final back = PhotoPlaybackSettings.parse(s.encode());
      expect(back, s);
      expect(back.portError, isNull);
      expect(const PhotoPlaybackSettings(httpPort: 0).portError, isNotNull);
      expect(
        PhotoPlaybackSettings.parse('garbage'),
        const PhotoPlaybackSettings(),
      );
      expect(PhotoPlaybackSettings.parsePortInput(''), isNull);
      expect(PhotoPlaybackSettings.parsePortInput('abc'), -1);
      expect(PhotoPlaybackSettings.parsePortInput('5000'), 5000);
    });

    test('notifier：开关/端口落盘；非法端口不落盘且返回 false', () async {
      final store = _MemPrefs();
      final c = ProviderContainer(
        overrides: [photoPrefsStoreProvider.overrideWithValue(store)],
      );
      addTearDown(c.dispose);
      final n = c.read(photoPlaybackSettingsProvider.notifier);
      expect(await n.setHttpPort('99999'), isFalse);
      expect(c.read(photoPlaybackSettingsProvider).httpPort, isNull);
      expect(await n.setHttpPort('5000'), isTrue);
      await n.setUseHttp(true);
      await n.setIgnoreCert(true);
      expect(
        PhotoPlaybackSettings.parse(store.data[kPhotoPlaybackSettingsSlot]),
        const PhotoPlaybackSettings(
          useHttp: true,
          httpPort: 5000,
          ignoreCert: true,
        ),
      );
      expect(
        c.read(photoPlaybackSettingsProvider).preferBufferedPlayback,
        isTrue,
      );
      expect(await n.setHttpPort(''), isTrue);
      expect(c.read(photoPlaybackSettingsProvider).httpPort, isNull);
    });

    test('接线：fotoSpaceApiProvider 按设置改写 Download/Streaming 直链', () async {
      final t = _transport();
      final api = await _loggedIn(t);
      final c = ProviderContainer(
        overrides: [
          fotoApiProvider.overrideWithValue(FotoApi(api)),
          photoPlaybackSettingsProvider.overrideWith(
            () => _FixedPlayback(
              const PhotoPlaybackSettings(useHttp: true, httpPort: 8080),
            ),
          ),
        ],
      );
      addTearDown(c.dispose);
      final foto = c.read(fotoSpaceApiProvider)!;
      expect(
        foto.downloadUrl(itemId: '12'),
        startsWith('http://fake.test:8080/webapi/'),
      );
      expect(
        foto.streamingUrl(itemId: '12', quality: 'high'),
        startsWith('http://fake.test:8080/webapi/'),
      );
      // 缩略图**不**受播放设置影响（走应用自己的证书信任链）
      expect(
        foto.thumbnailUrl(itemId: '12', cacheKey: 'ck'),
        startsWith('https://fake.test/webapi/'),
      );
    });
  });

  // ================================================================ P49 幻灯片

  group('P49 幻灯片播放（纯逻辑 + 落盘）', () {
    test('顺序模式保序；随机模式可复现且集合不变', () {
      const idx = [3, 1, 4, 0];
      expect(slideshowSequence(idx), idx);
      final a = slideshowSequence(idx, order: PhotoSlideshowOrder.shuffle);
      final b = slideshowSequence(idx, order: PhotoSlideshowOrder.shuffle);
      expect(a, b);
      expect(a..sort(), [0, 1, 3, 4]);
    });

    test('秒档收敛 + 设置 JSON 往返', () {
      expect(normalizeSlideshowSeconds(null), kPhotoSlideshowDefaultSeconds);
      expect(normalizeSlideshowSeconds(4), 3);
      expect(normalizeSlideshowSeconds(100), 15);
      expect(normalizeSlideshowSeconds(10), 10);
      const s = PhotoSlideshowSettings(
        seconds: 10,
        order: PhotoSlideshowOrder.shuffle,
      );
      expect(PhotoSlideshowSettings.parse(s.encode()), s);
      expect(PhotoSlideshowSettings.parse('x'), const PhotoSlideshowSettings());
    });

    test('notifier：设置落盘', () async {
      final store = _MemPrefs();
      final c = ProviderContainer(
        overrides: [photoPrefsStoreProvider.overrideWithValue(store)],
      );
      addTearDown(c.dispose);
      final n = c.read(photoSlideshowSettingsProvider.notifier);
      await n.setSeconds(15);
      await n.setOrder(PhotoSlideshowOrder.shuffle);
      expect(
        PhotoSlideshowSettings.parse(store.data[kPhotoSlideshowSettingsSlot]),
        const PhotoSlideshowSettings(
          seconds: 15,
          order: PhotoSlideshowOrder.shuffle,
        ),
      );
    });
  });

  _i18nGuard();
}

// ---------------------------------------------------------------- 文案接线自查
//
// G1 的文案全部走 `photoG1(key, 中文原文)`（`data_text.dart`）。这里守两件事：
//   1. `photo_format_support.dart` 里声明的**每个** photo* key 都在两套 ARB 里、
//      且 `dataTextMap` 的 zh/en 与 ARB 逐字一致（防"某批次重写 ARB 把我的 key
//      冲掉"——本批次确实被并行批次冲掉过一次，所以必须有断言锁住）；
//   2. zh 与 en 的键集合对 G1 的 key 完全一致。
void _i18nGuard() {
  final zhArb = _arbFile('zh');
  final enArb = _arbFile('en');
  final src = File(
    'lib/src/features/photos/photo_format_support.dart',
  ).readAsStringSync();
  final keys = <String>{
    for (final m in RegExp(r"'(photo[A-Za-z0-9_]+)'").allMatches(src))
      m.group(1)!,
  };

  group('G1 文案接线（ARB / 中英切换）', () {
    test('声明的每个 key 都在两套 ARB 里，且 zh/en 不同', () {
      expect(keys.length, greaterThanOrEqualTo(40));
      for (final k in keys) {
        expect(zhArb.containsKey(k), isTrue, reason: 'zh ARB 缺 $k');
        expect(enArb.containsKey(k), isTrue, reason: 'en ARB 缺 $k');
        expect(enArb[k], isNot(zhArb[k]), reason: 'en/$k 没翻');
      }
    });

    test('两套 ARB：G1 的 key 集合一致', () {
      final zhKeys = zhArb.keys.where(keys.contains).toSet();
      final enKeys = enArb.keys.where(keys.contains).toSet();
      expect(zhKeys, enKeys);
      expect(zhKeys.length, keys.length);
    });

    test('切换语言：photoG1 出 zh / en 的 ARB 值（不回落中文）', () {
      addTearDown(() => setCurrentText(AppTextZh()));
      setCurrentText(AppTextZh());
      for (final k in keys) {
        final zh = photoG1(k, '中文兜底');
        expect(zh, isNot('中文兜底'), reason: 'zh/$k 没接线');
        expect(zh, zhArb[k], reason: 'zh/$k');
      }
      setCurrentText(AppTextEn());
      for (final k in keys) {
        final en = photoG1(k, '中文兜底');
        expect(en, isNot('中文兜底'), reason: 'en/$k 没接线');
        expect(en, isNot(zhArb[k]), reason: 'en/$k 回落了中文');
        expect(en, enArb[k], reason: 'en/$k');
      }
    });
  });
}

Map<String, String> _arbFile(String locale) {
  final raw = File('lib/l10n/app_$locale.arb').readAsStringSync();
  final map = jsonDecode(raw) as Map<String, dynamic>;
  return {
    for (final e in map.entries)
      if (!e.key.startsWith('@')) e.key: '${e.value}',
  };
}
