// 相册（P2 · SynologyPhotos）：页面层离线测试。
//
// 覆盖：
//   * 时间轴按天分组（`timeline_group_unit`）· 相册/文件夹/收藏三段；
//   * **共享空间权限**：`team_space_permission = 'none'` 时空间切换**不出现**
//     （普通用户真机就是这个值，硬显示只会吃 801）；
//   * 大图页：读原图用 `Thumbnail/get size=xl`、收藏走
//     `Browse.Item/set_favorite`（`id` 是 JSON 数组字符串）；
//   * 错误态说人话（这里是"没装 Synology Photos"的 103）。
import 'dart:async';
import 'dart:convert';

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:synhub/src/data/dto/foto_dto.dart';
import 'package:synhub/src/data/foto_api.dart';
import 'package:synhub/src/data/local/database.dart';
import 'package:synhub/src/dsm/webapi.dart';
import 'package:synhub/src/features/chat/chat_session_controller.dart'
    show chatDatabaseProvider;
import 'package:synhub/src/features/media/media_player.dart'
    show mediaPlayerAdapterFactoryProvider, MediaPlayerAdapter;
import 'package:synhub/src/features/media/media_player_view.dart'
    show MediaPlayerPage, MediaFallbackPanel;
import 'package:synhub/src/features/media/media_source.dart'
    show MediaChannel, MediaSource;
import 'package:synhub/src/features/photos/photo_browse_page.dart';
import 'package:synhub/src/features/photos/photo_providers.dart';
import 'package:synhub/src/core/media/zoom_stage.dart';
import 'package:synhub/src/features/photos/photo_viewer_page.dart';

import 'package:synhub/src/core/theme/app_theme.dart';
import 'support/chat_harness.dart' show FakeTransport;

/// 1×1 透明 PNG（够 Flutter 解码；相册缩略图现在走**字节**链路，
/// 没有真字节就只会画占位图标）
final _png = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8DwHwAFAAH/'
  'q842iQAAAABJRU5ErkJggg==',
);

const _fotoTable = {
  'SYNO.API.Info': {'path': 'query.cgi', 'minVersion': 1, 'maxVersion': 1},
  'SYNO.Foto.Setting.User': {
    'path': 'entry.cgi',
    'minVersion': 1,
    'maxVersion': 4,
  },
  'SYNO.Foto.Browse.Item': {
    'path': 'entry.cgi',
    'minVersion': 1,
    'maxVersion': 9,
  },
  'SYNO.Foto.Browse.Album': {
    'path': 'entry.cgi',
    'minVersion': 1,
    'maxVersion': 5,
  },
  'SYNO.Foto.Browse.Folder': {
    'path': 'entry.cgi',
    'minVersion': 1,
    'maxVersion': 5,
  },
  'SYNO.Foto.Thumbnail': {
    'path': 'entry.cgi',
    'minVersion': 1,
    'maxVersion': 2,
  },
  // 视频流播：方法名是 `streaming`（v1-2），不是 `stream`
  'SYNO.Foto.Streaming': {
    'path': 'entry.cgi',
    'minVersion': 1,
    'maxVersion': 2,
  },
  'SYNO.FotoTeam.Setting.User': {
    'path': 'entry.cgi',
    'minVersion': 1,
    'maxVersion': 4,
  },
};

/// `authenticatedUrl` 永远返回空串（模拟"没登录 / 服务端不给直链"）
class _NoUrlTransport extends FakeTransport {
  _NoUrlTransport([super.responses, super.apiTable]);

  @override
  String authenticatedUrl(
    String path,
    Map<String, String> params, {
    String? sid,
  }) => '';
}

/// 最小假播放器适配器（**不**实现 `MediaPlayerFullControls`）：只保证内嵌播放页
/// 不碰平台通道。播放列表的接线直接从 `MediaPlayerPage` 的字段断言。
class _FakeVideoAdapter implements MediaPlayerAdapter {
  final _changes = StreamController<void>.broadcast();

  @override
  Future<void> load(MediaSource source) async {}

  @override
  Future<void> play() async {}

  @override
  Future<void> pause() async {}

  @override
  Future<void> seekTo(Duration position) async {}

  @override
  Future<void> setSpeed(double speed) async {}

  @override
  Future<void> dispose() async {
    if (!_changes.isClosed) await _changes.close();
  }

  @override
  Duration get position => Duration.zero;

  @override
  Duration? get duration => null;

  @override
  bool get playing => false;

  @override
  bool get ready => true;

  @override
  double get speed => 1;

  @override
  String? get error => null;

  @override
  double get aspectRatio => 16 / 9;

  @override
  Widget buildSurface(BuildContext context) =>
      const ColoredBox(color: Colors.black);

  @override
  Stream<void> get changes => _changes.stream;
}

Map<String, dynamic> _item(String id, int day, {bool video = false}) => {
  'id': id,
  'filename': 'IMG_$id.jpg',
  'filesize': 1024 * 512,
  'time': DateTime(2026, 9, day, 10).millisecondsSinceEpoch ~/ 1000,
  'indexed_time': DateTime(2026, 9, day, 11).millisecondsSinceEpoch ~/ 1000,
  'folder_id': '10',
  'type': video ? 'video' : 'photo',
  'additional': {
    'thumbnail': {
      // 真机的尺寸值是**状态串**，只有 `ready` 才代表"能取到图"
      // （非 ready 例：`ame_defect`/`broken`，见 `docs/thumbnail-apis.md` §1.8）。
      // 这里用 `ready` 表示"正常照片"，本文件既有断言
      // （3 张 Image + 3 次 Thumbnail/get）一个字没改；
      // 旧写法 `sm_$id` 是假状态值，会让"非 ready 不发请求"的门控失去意义。
      'sm': 'ready',
      'm': 'ready',
      'xl': 'ready',
      'cache_key': 'ck_$id',
    },
    'favorite': id == '1',
    'album': ['a1'],
  },
};

Future<DsmWebApi> _loggedIn(FakeTransport t) async {
  final api = DsmWebApi(t);
  await api.discover();
  await api.login(account: 'a', password: 'b');
  return api;
}

/// 挂相册页（只覆盖相册自己的 provider，不依赖真实会话装配）
Future<({FakeTransport t, ProviderContainer c})> _pump(
  WidgetTester tester, {
  Map<String, Map<String, dynamic>> byMethod = const {},
  String teamPermission = 'none',
  bool fails = false,
  Widget? page,
  FakeTransport? transport,
}) async {
  final t =
      transport ??
      FakeTransport(const {}, {...FakeTransport.table, ..._fotoTable});
  // 相册缩略图/原图都走 `getBytes` → 给它一份**能解码的真 PNG**
  t.downloadBytes = _png;
  t.onCall = (params) {
    final method = '${params['method']}';
    if (method == 'get' && '${params['api']}'.contains('Setting.User')) {
      return {
        'team_space_permission': teamPermission,
        'enable_person': false,
        'timeline_group_unit': 'day',
        'item_sort_by': 'takentime',
        'sort_direction': 'desc',
      };
    }
    return byMethod[method] ?? const <String, dynamic>{};
  };
  if (fails) {
    // 102 = API 不存在（没装 Synology Photos）
    t.failures['SYNO.Foto.Browse.Item.list'] = 102;
    t.failures['SYNO.Foto.Setting.User.get'] = 102;
  }
  final api = await _loggedIn(t);
  final db = ChatDatabase(NativeDatabase.memory());
  final c = ProviderContainer(
    overrides: [
      chatDatabaseProvider.overrideWithValue(db),
      fotoApiProvider.overrideWithValue(FotoApi(api)),
      // 内嵌播放器：假适配器，绝不碰平台通道（`video_player` 在单测里起不来）
      mediaPlayerAdapterFactoryProvider.overrideWithValue(
        () => _FakeVideoAdapter(),
      ),
    ],
  );
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: c,
      child: MaterialApp(theme: AppTheme.dark(), home: page ?? const PhotoBrowsePage()),
    ),
  );
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 300));
  return (t: t, c: c);
}

void main() {
  group('相册浏览页', () {
    testWidgets('时间轴按天分组 + 缩略图走 Thumbnail/get', (tester) async {
      final boot = await _pump(
        tester,
        byMethod: {
          'list': {
            'list': [
              _item('1', 18),
              _item('2', 18),
              _item('3', 17, video: true),
            ],
            'total': 3,
          },
        },
      );
      await tester.pump(const Duration(milliseconds: 200));

      expect(find.text('2026 年 9 月 18 日'), findsOneWidget);
      expect(find.text('2026 年 9 月 17 日'), findsOneWidget);
      expect(find.text('日 3'), findsNothing, reason: '分组里的计数是纯数字');
      // 三张照片的缩略图都**经鉴权字节链路**取回来了（`Image.network` 在
      // 自签证书的 NAS 上不工作，见 photo_providers.dart）
      expect(find.byType(Image), findsNWidgets(3));
      final thumbs = boot.t.downloads
          .where((u) => u.contains('SYNO.Foto.Thumbnail'))
          .toList();
      expect(thumbs.length, 3, reason: '每张照片一次 Thumbnail/get');
      expect(thumbs.first, contains('method=get'));
      expect(thumbs.first, contains('size=%22sm%22'));

      // 相册列表请求带的参数（官方语义）
      final list = boot.t.calls.firstWhere(
        (c) => c['api'] == 'SYNO.Foto.Browse.Item' && c['method'] == 'list',
      );
      expect(list['sort_by'], 'takentime');
      expect(list['sort_direction'], 'desc');
      expect(list['offset'], '0');
    });

    testWidgets('共享空间无权限 → 空间切换整块不显示', (tester) async {
      await _pump(
        tester,
        byMethod: {
          'list': {
            'list': [_item('1', 18)],
            'total': 1,
          },
        },
      );
      await tester.pump(const Duration(milliseconds: 200));
      expect(find.text('共享空间'), findsNothing);
      expect(find.text('个人空间'), findsNothing);
    });

    testWidgets('共享空间有权限 → 显示当前空间并可切换', (tester) async {
      await _pump(
        tester,
        teamPermission: 'readwrite',
        byMethod: {
          'list': {
            'list': [_item('1', 18)],
            'total': 1,
          },
        },
      );
      await tester.pump(const Duration(milliseconds: 200));
      expect(find.text('个人空间'), findsOneWidget);
      await tester.tap(find.text('个人空间'));
      await tester.pumpAndSettle();
      expect(find.text('共享空间'), findsWidgets);
    });

    testWidgets('相册段列出普通/条件相册', (tester) async {
      await _pump(
        tester,
        byMethod: {
          'list': {
            'list': [
              {
                'id': 'a1',
                'name': '旅行',
                'item_count': 12,
                'type': 'normal',
                'additional': {
                  'thumbnail': {'unit_id': 'u1', 'cache_key': 'ck'},
                },
              },
            ],
            'total': 1,
          },
        },
      );
      await tester.tap(find.text('相册').last);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      // 切段现在走分页容器（懒构建）：多给一帧让该段的请求落地
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.text('旅行'), findsOneWidget);
      expect(find.textContaining('12 项'), findsOneWidget);
    });

    testWidgets('文件夹段列出根层文件夹', (tester) async {
      await _pump(
        tester,
        byMethod: {
          'list': {
            'list': [
              {'id': '10', 'name': 'Photos', 'parent_id': '0'},
            ],
            'total': 1,
          },
        },
      );
      await tester.tap(find.text('文件夹'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.text('Photos'), findsOneWidget);
    });

    testWidgets('四段之间能左右滑动切换（左滑到下一段、右滑回上一段）', (tester) async {
      await _pump(tester);
      // 默认在时间轴
      expect(find.text('还没有照片'), findsOneWidget);

      final pager = find.byKey(const Key('photo-section-pager'));
      // 左滑 → 相册段
      await tester.fling(pager, const Offset(-600, 0), 1200);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.text('还没有相册'), findsOneWidget);

      // 左滑 → 文件夹段
      await tester.fling(pager, const Offset(-600, 0), 1200);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.text('没有可见的文件夹'), findsOneWidget);

      // 右滑 → 回到相册段
      await tester.fling(pager, const Offset(600, 0), 1200);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.text('还没有相册'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('收藏段：`Browse.Item/list` + `favorite=true` 过滤 '
        '（真机实证：list_all 只回 item_id，不可直接渲染）', (tester) async {
      final boot = await _pump(
        tester,
        byMethod: {
          'list': {
            'list': [_item('2', 18)],
            'total': 1,
          },
        },
      );
      await tester.tap(find.text('收藏'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.text('IMG_2.jpg'), findsNothing, reason: '网格不显示文件名');
      final call = boot.t.calls.lastWhere((c) => c['favorite'] == 'true');
      expect(call['api'], 'SYNO.Foto.Browse.Item');
      expect(call['additional'], contains('favorite'));
    });

    testWidgets('没装 Synology Photos（102）→ 说人话 + 可重试', (tester) async {
      await _pump(tester, fails: true);
      await tester.pump(const Duration(milliseconds: 200));
      expect(find.textContaining('没有安装 Synology Photos'), findsOneWidget);
      expect(find.text('重试'), findsOneWidget);
    });

    testWidgets('空时间轴 → 引导文案（不是白屏）', (tester) async {
      await _pump(
        tester,
        byMethod: {
          'list': {'list': const [], 'total': 0},
        },
      );
      await tester.pump(const Duration(milliseconds: 200));
      expect(find.text('还没有照片'), findsOneWidget);
    });
  });

  group('大图页', () {
    testWidgets('读原图用 size=xl；收藏写回 set_favorite（id 是数字 JSON 数组）', (
      tester,
    ) async {
      // 第 0 张用**未收藏**的 id=2（id=1 在 fixture 里已收藏）
      final items = [
        FotoItemDto.fromJson(_item('2', 18)),
        FotoItemDto.fromJson(_item('1', 18)),
      ];
      final boot = await _pump(
        tester,
        page: PhotoViewerPage(items: items),
        byMethod: {
          'get': {'success': true},
        },
      );
      await tester.pump(const Duration(milliseconds: 200));

      // 原图请求里带 size=xl（官方 App 同款），且走鉴权字节链路
      final url = boot.t.downloads.firstWhere(
        (u) => u.contains('SYNO.Foto.Thumbnail'),
      );
      expect(find.byType(Image), findsWidgets, reason: '真字节要能解码成图');
      expect(url, contains('SYNO.Foto.Thumbnail'));
      expect(url, contains('method=get'));
      // 注意：`type`/`size`/`cache_key` 都是 **JSON 编码的字符串**（官方同款，
      // 所以 URL 里是 `size=%22xl%22` 而不是 `size=xl`）
      expect(url, contains('size=%22xl%22'));
      expect(url, contains('type=%22item%22'));
      expect(url, contains('cache_key=%22ck_2%22'));

      // 收藏
      await tester.tap(find.byType(FloatingActionButton));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      final fav = boot.t.calls.firstWhere((c) => c['method'] == 'set_favorite');
      expect(fav['api'], 'SYNO.Foto.Browse.Item');
      // 真机取证：id 必须是**数字** JSON 数组（`["9547"]` → 120 参数无效，
      // `[9547]` 成功；服务端回的 id 也是 int）—— 见 tool/photo_param_probe.dart
      expect(fav['id'], '[2]');
      expect(fav['favorite'], 'true', reason: 'DSM 的参数都是字符串');
      expect(find.text('已加入收藏'), findsOneWidget);
    });

    testWidgets('左右滑翻页 + 标题里的 1/2', (tester) async {
      final items = [
        FotoItemDto.fromJson(_item('1', 18)),
        FotoItemDto.fromJson(_item('2', 18)),
      ];
      await _pump(tester, page: PhotoViewerPage(items: items));
      await tester.pump(const Duration(milliseconds: 200));
      expect(find.textContaining('1/2'), findsOneWidget);
      await tester.fling(find.byType(PageView), const Offset(-400, 0), 1200);
      await tester.pumpAndSettle(const Duration(seconds: 1));
      expect(find.textContaining('2/2'), findsOneWidget);
    });

    testWidgets('双击放大：可缩放，放大后不再横滑翻页；再双击复位后恢复翻页', (tester) async {
      final items = [
        FotoItemDto.fromJson(_item('1', 18)),
        FotoItemDto.fromJson(_item('2', 18)),
      ];
      await _pump(tester, page: PhotoViewerPage(items: items));
      await tester.pump(const Duration(milliseconds: 200));
      expect(find.byType(ZoomStage), findsWidgets, reason: '原图走可缩放舞台');

      PageView pager() => tester.widget<PageView>(find.byType(PageView));
      expect(pager().physics, isA<PageScrollPhysics>(), reason: '未放大时能翻页');

      final center = tester.getCenter(find.byType(ZoomStage).first);
      await tester.tapAt(center);
      await tester.pump(const Duration(milliseconds: 40));
      await tester.tapAt(center);
      await tester.pumpAndSettle();
      expect(
        pager().physics,
        isA<NeverScrollableScrollPhysics>(),
        reason: '放大后单指横滑要让给平移，不能切页',
      );
      await tester.fling(
        find.byType(ZoomStage).first,
        const Offset(-400, 0),
        1200,
      );
      await tester.pumpAndSettle(const Duration(seconds: 1));
      expect(find.textContaining('1/2'), findsOneWidget, reason: '放大状态下不翻页');

      // 再双击复位 → 翻页恢复
      await tester.tapAt(center);
      await tester.pump(const Duration(milliseconds: 40));
      await tester.tapAt(center);
      await tester.pumpAndSettle();
      expect(pager().physics, isA<PageScrollPhysics>());
      await tester.fling(find.byType(PageView), const Offset(-400, 0), 1200);
      await tester.pumpAndSettle(const Duration(seconds: 1));
      expect(find.textContaining('2/2'), findsOneWidget);
    });

    testWidgets('视频格：点"播放"→ 自研内嵌播放器（Download 直链 + 同类型视频播放列表）', (tester) async {
      final items = [
        FotoItemDto.fromJson(_item('9', 18, video: true)),
        FotoItemDto.fromJson(_item('7', 17, video: true)),
        FotoItemDto.fromJson(_item('1', 18)),
      ];
      final boot = await _pump(tester, page: PhotoViewerPage(items: items));
      await tester.pump(const Duration(milliseconds: 200));

      // 能播 → 播放按钮（不再是"用系统播放器打开"）
      expect(find.text('播放'), findsOneWidget);
      expect(find.text('用系统播放器打开'), findsNothing);
      expect(find.byType(Image), findsNothing, reason: '视频格不画原图');

      await tester.tap(find.text('播放'));
      await tester.pumpAndSettle();

      final page = tester.widget<MediaPlayerPage>(find.byType(MediaPlayerPage));
      expect(page.source.channel, MediaChannel.photos);
      // R7 P0：主通道 = Download + item_id（官方 `u9` 的 Item 分支，`quality="raw"`）
      expect(
        Uri.parse(page.source.uri).queryParameters['api'],
        'SYNO.Foto.Download',
        reason: '官方对原生 mp4/h264 走 Download，不是转码档 Streaming',
      );
      expect(Uri.parse(page.source.uri).queryParameters['method'], 'download');
      expect(
        Uri.parse(page.source.uri).queryParameters['item_id'],
        '[9]',
        reason: 'Browse.Item/list 给的是 item id → item_id=[…]（不是 unit_id）',
      );
      // 第二跳 = Streaming（转码档兜底，type=item）
      expect(page.source.fallback, isNotNull);
      final fbParams = Uri.parse(page.source.fallback!.uri).queryParameters;
      expect(fbParams['method'], 'streaming');
      expect(fbParams['type'], 'item');
      // Range **真机已证**（2026-09-22：Download + Range: bytes=0-1023 →
      // 206 + Content-Range，docs/live-nas-verification.md §4.3）→ 主源可 seek；
      // 回退的 Streaming 腿未取证 → 恒 false（不许跟着变 true）。
      expect(page.source.supportsRange, isTrue);
      expect(page.source.seekable, isTrue);
      expect(page.source.fallback!.supportsRange, isFalse);
      expect(page.source.fallback!.streamingOnly, isTrue);
      expect(page.source.fallbackReason, isNull);
      expect(page.source.playable, isTrue);
      expect(page.source.streamingOnly, isFalse);

      // 播放列表 = 同一时间轴里的同类型视频（照片不进列表），当前项在 0
      expect(page.playlist, isNotNull);
      expect(page.playlist!.length, 2);
      expect(page.playlistIndex, 0);
      expect(
        page.playlist!.every(
          (s) => Uri.parse(s.uri).queryParameters['method'] == 'download',
        ),
        isTrue,
      );
      expect(
        page.playlist!.every((s) => s.fallback != null),
        isTrue,
        reason: '每一条都带 Streaming 兜底',
      );
      // 内嵌播放**不再整段下载**
      expect(boot.t.downloads.where((u) => u.contains('Streaming')), isEmpty);
    });

    testWidgets('视频格：拿不到流地址 → 回退面板（用其他应用打开/下载），不硬撑播放器', (tester) async {
      final items = [
        FotoItemDto.fromJson(_item('9', 18, video: true)),
        FotoItemDto.fromJson(_item('7', 17, video: true)),
      ];
      await _pump(
        tester,
        transport: _NoUrlTransport(const {}, {
          ...FakeTransport.table,
          ..._fotoTable,
        }),
        page: PhotoViewerPage(items: items),
      );
      await tester.pump(const Duration(milliseconds: 200));

      // 复用媒体层既有回退面板（`MediaFallbackPanel`），不是新造一套
      expect(find.byType(MediaFallbackPanel), findsOneWidget);
      expect(find.text('用其他应用打开'), findsOneWidget);
      expect(find.text('下载'), findsOneWidget);
      expect(find.text('播放'), findsNothing);
      expect(find.byType(MediaPlayerPage), findsNothing);
    });

    testWidgets('图片格零行为变化：仍走可缩放原图，无播放按钮/回退面板', (tester) async {
      final items = [FotoItemDto.fromJson(_item('1', 18))];
      final boot = await _pump(tester, page: PhotoViewerPage(items: items));
      await tester.pump(const Duration(milliseconds: 200));

      expect(find.byType(ZoomStage), findsWidgets, reason: '原图仍走可缩放舞台');
      expect(find.byType(Image), findsOneWidget);
      expect(find.text('播放'), findsNothing);
      expect(find.byType(MediaFallbackPanel), findsNothing);
      // 原图依旧经 `Thumbnail/get` 的鉴权字节链路（不是 Image.network）
      expect(
        boot.t.downloads.where((u) => u.contains('SYNO.Foto.Thumbnail')),
        isNotEmpty,
      );
    });
  });
}
