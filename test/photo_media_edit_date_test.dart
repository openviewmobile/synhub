// P36 · 编辑拍摄日期时间 —— 接口层 + 页面层离线用例。
//
// ⚠️ **写操作**：`Browse.Item/set` + `time`。本文件**全部离线**（FakeTransport），
// 不连 NAS、不发真请求；断言的是**请求长什么样**与**什么时候才允许发**。
//
// 逐字证据（官方 APK 2.4.0-644，jadx 1.5.3，`ApiBrowseItem.java`）：
//   * `KEY_TIME = "time"`（`:77`）
//   * `SetParamBuilder.build():1192-1195`
//     `map.put(KEY_TIME, String.valueOf(l.longValue()))`
//     —— 值是**绝对 epoch 秒的十进制字符串、不套 JSON 引号**
//     （和同文件里 `rotate_action` 走 `gson.toJson` 得到的 `"clockwise"` 不同）；
//   * `:489` `getSetPhotoTimeResponse(list, j, …)` → `.time(j)`；id 是 `List<Long>`
//     → 序列化成 **JSON 数字数组**；
//   * `shift_time` 虽然存在于 `build():1196-1199`，但**全 APK 无调用者** → 不用；
//   * `API_VERSION = 7`（`:100`）→ 版本候选交给 `negotiate` 收敛，不硬编码。
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:synhub/src/data/dto/foto_dto.dart';
import 'package:synhub/src/data/foto_media_kinds.dart';
import 'package:synhub/src/dsm/webapi.dart';
import 'package:synhub/src/features/photos/photo_edit_date_sheet.dart';
import 'package:synhub/src/features/photos/photo_viewer_page.dart';

import 'photo_media_harness.dart';
import 'package:synhub/src/core/theme/app_theme.dart';
import 'support/chat_harness.dart' show FakeTransport;

void main() {
  group('① 接口层：setItemTime 的请求形态（逐字对齐官方 SetParamBuilder）', () {
    test('time 是**纯十进制 epoch 秒**（不套 JSON 引号）；id 是 JSON 数字数组', () async {
      final r = await photoMediaApi();
      final when = DateTime(2019, 7, 4, 13, 45, 30);
      await r.api.setItemTime(itemIds: ['9659'], time: when);
      final call = photoMediaLastCall(r.t, 'SYNO.Foto.Browse.Item.set');
      expect(call['api'], 'SYNO.Foto.Browse.Item');
      expect(call['method'], 'set');
      // 关键：值是普通整数字符串 —— **不是** '"1562247930"'
      expect(call['time'], '${when.millisecondsSinceEpoch ~/ 1000}');
      expect(call['time'], matches(RegExp(r'^\d+$')));
      // id 走 js()：官方是 `List<Long>` → JSON 数字数组
      expect(call['id'], '[9659]');
      // 官方 API_VERSION = 7（`FakeTransport.calls` 记录的是已字符串化的请求参数）
      expect(call['version'], '7');
    });

    test('多张照片一次改：id 数组带全部 id，顺序不乱', () async {
      final r = await photoMediaApi();
      await r.api.setItemTime(
        itemIds: ['3', '1', '2'],
        time: DateTime(2020, 1, 2, 3, 4, 5),
      );
      final call = photoMediaLastCall(r.t, 'SYNO.Foto.Browse.Item.set');
      expect(jsonDecode(call['id'] as String), [3, 1, 2]);
    });

    test('空 id 列表 → **一个请求都不发**（不发空 set）', () async {
      final r = await photoMediaApi();
      await r.api.setItemTime(itemIds: const [], time: DateTime(2020));
      expect(photoMediaCallCount(r.t, 'SYNO.Foto.Browse.Item.set'), 0);
    });

    test('版本协商：服务器只到 v3 → 用 v3，不硬编码 7', () async {
      final r = await photoMediaApi(
        apiTable: {
          'SYNO.Foto.Browse.Item': {
            'path': 'entry.cgi',
            'minVersion': 1,
            'maxVersion': 3,
          },
        },
      );
      await r.api.setItemTime(itemIds: ['1'], time: DateTime(2020));
      final call = photoMediaLastCall(r.t, 'SYNO.Foto.Browse.Item.set');
      expect(call['version'], '3');
    });
  });

  group('② 接口层：motion_photo 能力位（v3+）与 additional 裁剪', () {
    test(
      'maxVersion >= 3 → supportsMotionPhoto，additional 里带上 motion_photo',
      () async {
        final r = await photoMediaApi();
        expect(r.api.supportsMotionPhoto, isTrue);
        expect(r.api.itemAdditional(), contains(kFotoAdditionalMotionPhoto));
      },
    );

    test(
      'maxVersion < 3 → 不带 motion_photo（官方 SUPPORT_MOTION_PHOTO_VERSION=3）',
      () async {
        final r = await photoMediaApi(
          apiTable: {
            'SYNO.Foto.Browse.Item': {
              'path': 'entry.cgi',
              'minVersion': 1,
              'maxVersion': 2,
            },
          },
        );
        expect(r.api.supportsMotionPhoto, isFalse);
        expect(
          r.api.itemAdditional(),
          isNot(contains(kFotoAdditionalMotionPhoto)),
        );
      },
    );

    test('能力位**缺失**（老 Photos 不报这个 API）→ fail-closed，不带 motion_photo', () async {
      final r = await photoMediaApi(
        apiTable: {'SYNO.Foto.Browse.Item': <String, dynamic>{}},
      );
      expect(r.api.supportsMotionPhoto, isFalse);
      expect(
        r.api.itemAdditional(),
        isNot(contains(kFotoAdditionalMotionPhoto)),
      );
    });

    test('调用方给的自定义 additional 会被保留，motion_photo 追加在后面', () async {
      final r = await photoMediaApi();
      final out = r.api.itemAdditional(const ['thumbnail']);
      expect(out, contains('thumbnail'));
      expect(out, contains(kFotoAdditionalMotionPhoto));
    });
  });

  group('③ 接口层：动态照片的解析（DTO 侧，键存在性判据）', () {
    test('additional 带 motion_photo → 认成动态照片且"有视频"', () {
      final item = FotoItemDto.fromJson(
        photoMediaItem(
          '1',
          type: 'motion_photo',
          motionPhoto: motionPhotoMeta(),
        ),
      );
      expect(item.kind, FotoMediaKind.motionPhoto);
      expect(item.isMotionPhoto, isTrue);
      expect(item.hasMotionPhotoVideo, isTrue);
      expect(item.isLiveOrMotion, isTrue);
      // 动态照片是**静图**（短视频是附属层），不是 video 条目
      expect(item.isVideo, isFalse);
    });

    test(
      'type=motion_photo 但 additional **没有** motion_photo → 不可播（官方此处返回 Uri.EMPTY）',
      () {
        final item = FotoItemDto.fromJson(
          photoMediaItem('1', type: 'motion_photo'),
        );
        expect(item.isMotionPhoto, isTrue);
        expect(item.hasMotionPhotoVideo, isFalse);
      },
    );

    test('live_type 解析成角色：photo / video / live / none', () {
      FotoItemDto withLive(String? v) =>
          FotoItemDto.fromJson(photoMediaItem('1', type: 'live', liveType: v));
      expect(withLive('photo').liveTypeRole, FotoLiveType.photo);
      expect(withLive('video').liveTypeRole, FotoLiveType.video);
      expect(withLive('live').liveTypeRole, FotoLiveType.live);
      expect(withLive(null).liveTypeRole, FotoLiveType.none);
      // 只有 `live_type == video` 的成员才算"那一段短视频"
      expect(withLive('video').isLiveVideoMember, isTrue);
      expect(withLive('photo').isLiveVideoMember, isFalse);
    });

    test('普通照片不会被误判成实况/动态', () {
      final item = FotoItemDto.fromJson(photoMediaItem('1', type: 'photo'));
      expect(item.isLiveOrMotion, isFalse);
      expect(item.hasMotionPhotoVideo, isFalse);
    });
  });

  group('④ 页面层：sheet 只在**确认之后**才允许发写请求', () {
    /// 在用户点「保存」之前，**任何时刻**都不该有 set 请求。
    testWidgets('① 取消 sheet → 一个写请求都不发', (tester) async {
      final t = FakeTransport(const {}, {
        ...FakeTransport.table,
        ...kPhotoMediaTable,
      });
      final api = DsmWebApi(t);
      await api.discover();
      await api.login(account: 'a', password: 'b');
      final item = FotoItemDto.fromJson(photoMediaItem('1', type: 'photo'));
      DateTime? result;
      await tester.pumpWidget(
        MaterialApp(theme: AppTheme.dark(), 
          home: Builder(
            builder: (context) => Scaffold(
              body: Center(
                child: TextButton(
                  onPressed: () async {
                    result = await showPhotoEditDateSheet(context, item: item);
                  },
                  child: const Text('open'),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('open'));
      await settlePhotoMedia(tester);
      expect(find.byKey(const Key('photo-edit-date-sheet')), findsOne);
      await tester.tap(find.byKey(const Key('photo-edit-date-cancel')));
      await settlePhotoMedia(tester);
      expect(result, isNull);
      expect(find.byKey(const Key('photo-edit-date-sheet')), findsNothing);
      expect(photoMediaCallCount(t, 'SYNO.Foto.Browse.Item.set'), 0);
    });

    testWidgets('② 时间没改就点保存 → 提示"没有变化"，**不弹确认框、不发请求**', (tester) async {
      final t = FakeTransport(const {}, {
        ...FakeTransport.table,
        ...kPhotoMediaTable,
      });
      final api = DsmWebApi(t);
      await api.discover();
      await api.login(account: 'a', password: 'b');
      final item = FotoItemDto.fromJson(photoMediaItem('1', type: 'photo'));
      await tester.pumpWidget(
        MaterialApp(theme: AppTheme.dark(), 
          home: Builder(
            builder: (context) => Scaffold(
              body: Center(
                child: TextButton(
                  onPressed: () => showPhotoEditDateSheet(context, item: item),
                  child: const Text('open'),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('open'));
      await settlePhotoMedia(tester);
      await tester.tap(find.byKey(const Key('photo-edit-date-save')));
      await settlePhotoMedia(tester);
      expect(find.byKey(const Key('photo-edit-date-invalid')), findsOne);
      expect(
        find.byKey(const Key('photo-edit-date-confirm-dialog')),
        findsNothing,
      );
      expect(photoMediaCallCount(t, 'SYNO.Foto.Browse.Item.set'), 0);
    });

    testWidgets('③ 确认框里点"取消" → sheet 不关、结果仍是 null、无请求', (tester) async {
      final t = FakeTransport(const {}, {
        ...FakeTransport.table,
        ...kPhotoMediaTable,
      });
      final api = DsmWebApi(t);
      await api.discover();
      await api.login(account: 'a', password: 'b');
      final item = FotoItemDto.fromJson(photoMediaItem('1', type: 'photo'));
      DateTime? result;
      await tester.pumpWidget(
        MaterialApp(theme: AppTheme.dark(), 
          home: Builder(
            builder: (context) => Scaffold(
              body: Center(
                child: TextButton(
                  onPressed: () async {
                    result = await showPhotoEditDateSheet(context, item: item);
                  },
                  child: const Text('open'),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('open'));
      await settlePhotoMedia(tester);
      // 改一天 → 保存 → 弹确认框
      await tester.tap(find.byKey(const Key('photo-edit-date-date')));
      await settlePhotoMedia(tester);
      await tester.tap(find.text('15'));
      await tester.tap(find.text('OK'));
      await settlePhotoMedia(tester);
      await tester.tap(find.byKey(const Key('photo-edit-date-save')));
      await settlePhotoMedia(tester);
      expect(find.byKey(const Key('photo-edit-date-confirm-dialog')), findsOne);
      // 确认框还在的时候：**依然**没有请求（写操作没确认就是不发）
      expect(photoMediaCallCount(t, 'SYNO.Foto.Browse.Item.set'), 0);
      await tester.tap(find.byKey(const Key('photo-edit-date-confirm-cancel')));
      await settlePhotoMedia(tester);
      expect(
        find.byKey(const Key('photo-edit-date-confirm-dialog')),
        findsNothing,
      );
      expect(find.byKey(const Key('photo-edit-date-sheet')), findsOne);
      expect(result, isNull);
      expect(photoMediaCallCount(t, 'SYNO.Foto.Browse.Item.set'), 0);
    });
  });

  group('⑤ 页面层：查看器接线（入口可见性 + 确认后发请求 + 失败提示）', () {
    testWidgets('① 照片有「编辑日期时间」入口', (tester) async {
      await pumpPhotoMedia(
        tester,
        PhotoViewerPage(
          items: photoMediaItems([
            photoMediaItem('1', type: 'photo', filename: 'IMG_1.jpg'),
          ]),
        ),
      );
      expect(find.byKey(const Key('photo-edit-date')), findsOne);
    });

    testWidgets('①b 视频**没有**这个入口（官方 btn_edit_date 只在照片详情里）', (tester) async {
      await pumpPhotoMedia(
        tester,
        PhotoViewerPage(
          items: photoMediaItems([
            photoMediaItem('2', type: 'video', filename: 'VID_2.mp4'),
          ]),
        ),
      );
      expect(find.byKey(const Key('photo-edit-date')), findsNothing);
    });

    testWidgets('② 改日期 → 确认 → 发出 set（time = 新的 epoch 秒）；并提示已保存', (
      tester,
    ) async {
      final items = photoMediaItems([
        photoMediaItem('1', type: 'photo', filename: 'IMG_1.jpg'),
      ]);
      final r = await pumpPhotoMedia(
        tester,
        PhotoViewerPage(items: items),
        responses: {'SYNO.Foto.Browse.Item.set': <String, dynamic>{}},
      );
      await tapPhotoMediaKey(tester, 'photo-edit-date');
      expect(find.byKey(const Key('photo-edit-date-sheet')), findsOne);

      // 用真实的 Material 日期选择器把 18 号改成 15 号
      await tester.tap(find.byKey(const Key('photo-edit-date-date')));
      await settlePhotoMedia(tester);
      await tester.tap(find.text('15'));
      await tester.tap(find.text('OK'));
      await settlePhotoMedia(tester);

      await tapPhotoMediaKey(tester, 'photo-edit-date-save');
      expect(find.byKey(const Key('photo-edit-date-confirm-dialog')), findsOne);
      // 确认框出现时还没发请求
      expect(photoMediaCallCount(r.t, 'SYNO.Foto.Browse.Item.set'), 0);

      await tapPhotoMediaKey(tester, 'photo-edit-date-confirm-ok');
      await settlePhotoMedia(tester);
      final call = photoMediaLastCall(r.t, 'SYNO.Foto.Browse.Item.set');
      expect(
        call['time'],
        '${DateTime(2026, 9, 15, 10).millisecondsSinceEpoch ~/ 1000}',
      );
      expect(call['id'], '[1]');
    });

    testWidgets('③ 写失败（105 权限）→ 明确失败提示，不装作成功', (tester) async {
      final items = photoMediaItems([
        photoMediaItem('1', type: 'photo', filename: 'IMG_1.jpg'),
      ]);
      final r = await pumpPhotoMedia(
        tester,
        PhotoViewerPage(items: items),
        failures: const {'SYNO.Foto.Browse.Item.set': 105},
      );
      await tapPhotoMediaKey(tester, 'photo-edit-date');
      await tester.tap(find.byKey(const Key('photo-edit-date-date')));
      await settlePhotoMedia(tester);
      await tester.tap(find.text('15'));
      await tester.tap(find.text('OK'));
      await settlePhotoMedia(tester);
      await tapPhotoMediaKey(tester, 'photo-edit-date-save');
      await tapPhotoMediaKey(tester, 'photo-edit-date-confirm-ok');
      await settlePhotoMedia(tester);
      expect(photoMediaCallCount(r.t, 'SYNO.Foto.Browse.Item.set'), 1);
      expect(find.byKey(const Key('photo-edit-date-failed')), findsOne);
      // 失败时**不能**出现"已修改"的成功提示
      expect(find.textContaining('已修改拍摄时间'), findsNothing);
    });
  });
}
