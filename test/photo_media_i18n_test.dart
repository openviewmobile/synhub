// P13/P14/P36 数据层文案的**中英切换**守护。
//
// 为什么单独一个文件：这三项文案走的是
// `photoMedia()` / `photoMediaFill()`（`photo_media_text.dart`）
// → `dataText(key, 中文原文)` → `lib/src/core/i18n/l10n.dart` 的 `dataTextMap`。
//
// 🔴 **这条链最容易断在最后一环**：`dataTextMap` 里少一条，界面就**永远显示中文回落**，
// 而 `flutter analyze` 与任何"能不能渲染"的用例都**不会报错**。
// 所以这里直接断言"切到英文后**逐字**变成英文值"，而不是断言"不是 null"。
//
// 另守一条**曾经真出过的错**：`photoMediaEditDateAction` 一度被
// 入口标题（「编辑日期时间」）与提交按钮（「保存」）**共用同一个 key** ——
// 一个 key 两个含义，任何译文都会让其中一处显示错的意思。
// 这里用断言把两个 key **钉成必须不同**。
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:synhub/l10n/gen/app_localizations_en.dart';
import 'package:synhub/l10n/gen/app_localizations_zh.dart';
import 'package:synhub/src/core/i18n/data_text.dart';
import 'package:synhub/src/core/i18n/l10n.dart';
import 'package:synhub/src/features/photos/photo_media_text.dart';

Map<String, String> _arb(String locale) {
  final raw = File('lib/l10n/app_$locale.arb').readAsStringSync();
  final map = jsonDecode(raw) as Map<String, dynamic>;
  return {
    for (final e in map.entries)
      if (!e.key.startsWith('@')) e.key: '${e.value}',
  };
}

/// 真正被界面调用的 key（**有调用方**的那些）。
const List<String> _used = [
  'photoMediaLiveBadge',
  'photoMediaMotionBadge',
  'photoMediaLivePlayTooltip',
  'photoMediaLiveStopTooltip',
  'photoMediaLiveUnavailable',
  'photoMediaPanoPhotoHint',
  'photoMediaPanoPhotoFailed',
  'photoMediaPanoResetView',
  'photoMediaPanoVideoFlatNotice',
  'photoMediaEditDateTitle',
  'photoMediaEditDateMenuAction',
  'photoMediaEditDateAction',
  'photoMediaEditDateField',
  'photoMediaEditTimeField',
  'photoMediaEditDateConfirmTitle',
  'photoMediaEditDateConfirmBody',
  'photoMediaEditDateSaved',
  'photoMediaEditDateFailed',
  'photoMediaEditDateInvalid',
];

void main() {
  final zhArb = _arb('zh');
  final enArb = _arb('en');

  group('两套 ARB 与调用点对齐', () {
    test('每个有调用方的 key 在 zh/en 两套 ARB 里都存在', () {
      for (final k in _used) {
        expect(zhArb.containsKey(k), isTrue, reason: 'zh 缺 $k');
        expect(enArb.containsKey(k), isTrue, reason: 'en 缺 $k');
      }
    });

    test('英文值必须与中文值【不同】—— 否则等于没翻', () {
      for (final k in _used) {
        expect(enArb[k], isNot(zhArb[k]), reason: '$k 的中英值相同');
      }
    });

    test('{from}/{to}/{error} 占位符在两套 ARB 里都保留', () {
      for (final p in ['{from}', '{to}']) {
        expect(zhArb['photoMediaEditDateConfirmBody'], contains(p));
        expect(enArb['photoMediaEditDateConfirmBody'], contains(p));
      }
      expect(zhArb['photoMediaEditDateFailed'], contains('{error}'));
      expect(enArb['photoMediaEditDateFailed'], contains('{error}'));
    });

    test('声明在 PhotoMediaTextKeys 的常量值与 _used 一致（防漏接线）', () {
      // 有调用方的常量 → 其字符串值必须在 _used 里
      final declared = <String>{
        PhotoMediaTextKeys.liveBadge,
        PhotoMediaTextKeys.motionBadge,
        PhotoMediaTextKeys.livePlayTooltip,
        PhotoMediaTextKeys.liveStopTooltip,
        PhotoMediaTextKeys.liveUnavailable,
        PhotoMediaTextKeys.panoPhotoHint,
        PhotoMediaTextKeys.panoPhotoFailed,
        PhotoMediaTextKeys.panoResetView,
        PhotoMediaTextKeys.panoVideoFlatNotice,
        PhotoMediaTextKeys.editDateTitle,
        PhotoMediaTextKeys.editDateMenuAction,
        PhotoMediaTextKeys.editDateAction,
        PhotoMediaTextKeys.editDateField,
        PhotoMediaTextKeys.editTimeField,
        PhotoMediaTextKeys.editDateConfirmTitle,
        PhotoMediaTextKeys.editDateConfirmBody,
        PhotoMediaTextKeys.editDateSaved,
        PhotoMediaTextKeys.editDateFailed,
        PhotoMediaTextKeys.editDateInvalid,
      };
      expect(declared, _used.toSet());
    });

    test('🔴 入口标题与提交按钮【必须是两个不同的 key】', () {
      // 回归：曾经两者共用 photoMediaEditDateAction，
      // 导致「保存」与「编辑日期时间」互相覆盖。
      expect(
        PhotoMediaTextKeys.editDateMenuAction,
        isNot(PhotoMediaTextKeys.editDateAction),
      );
      expect(zhArb[PhotoMediaTextKeys.editDateMenuAction], '编辑日期时间');
      expect(zhArb[PhotoMediaTextKeys.editDateAction], '保存');
    });
  });

  group('中英切换：数据层文案跟着走', () {
    tearDown(() => setCurrentText(AppTextZh()));

    test('实况/动态照片', () {
      setCurrentText(AppTextZh());
      expect(photoMedia(PhotoMediaTextKeys.liveBadge, '实况照片'), '实况照片');
      expect(photoMedia(PhotoMediaTextKeys.motionBadge, '动态照片'), '动态照片');
      setCurrentText(AppTextEn());
      expect(photoMedia(PhotoMediaTextKeys.liveBadge, '实况照片'), 'Live Photo');
      expect(
        photoMedia(PhotoMediaTextKeys.motionBadge, '动态照片'),
        'Motion Photo',
      );
      expect(
        photoMedia(PhotoMediaTextKeys.livePlayTooltip, '播放实况短视频'),
        'Play Live Photo',
      );
      expect(
        photoMedia(PhotoMediaTextKeys.liveStopTooltip, '停止实况播放'),
        'Stop Live Photo',
      );
      expect(
        photoMedia(
          PhotoMediaTextKeys.liveUnavailable,
          '这段实况短视频不可用（服务端没有给出可播放的视频）。',
        ),
        contains('unavailable'),
      );
    });

    test('360 全景（含"平面降级"的如实说明）', () {
      setCurrentText(AppTextEn());
      expect(
        photoMedia(PhotoMediaTextKeys.panoPhotoHint, '点按并拖动查看 360 照片。'),
        'Tap and drag to view the 360 photo.',
      );
      expect(
        photoMedia(PhotoMediaTextKeys.panoPhotoFailed, '无法载入 360 照片。'),
        'Unable to load the 360 photo.',
      );
      expect(
        photoMedia(PhotoMediaTextKeys.panoResetView, '回到初始视角'),
        'Reset view',
      );
      final flat = photoMedia(
        PhotoMediaTextKeys.panoVideoFlatNotice,
        '这是 360 全景视频。本版播放器暂不支持球面视角（只能按普通平面视频播放）。',
      );
      expect(flat, contains('flat video'));
      // 不许把"降级"翻译成"球面正常播放"
      expect(
        flat.toLowerCase(),
        isNot(contains('spherical view is supported')),
      );
    });

    test('编辑日期：字段/确认/结果，占位符逐字替换', () {
      setCurrentText(AppTextZh());
      expect(
        photoMediaFill(
          PhotoMediaTextKeys.editDateConfirmBody,
          '这会把这张照片的拍摄时间从 {from} 改为 {to}。原文件不会被重新编码，但相册里的时间轴与排序会随之变化。',
          const {'from': '2026-09-18 10:00', 'to': '2026-09-19 11:30'},
        ),
        '这会把这张照片的拍摄时间从 2026-09-18 10:00 改为 2026-09-19 11:30。'
        '原文件不会被重新编码，但相册里的时间轴与排序会随之变化。',
      );

      setCurrentText(AppTextEn());
      expect(photoMedia(PhotoMediaTextKeys.editDateField, '日期'), 'Date');
      expect(photoMedia(PhotoMediaTextKeys.editTimeField, '时间'), 'Time');
      expect(
        photoMedia(PhotoMediaTextKeys.editDateSaved, '已修改拍摄时间。'),
        'Capture time updated.',
      );
      final body = photoMediaFill(
        PhotoMediaTextKeys.editDateConfirmBody,
        '这会把这张照片的拍摄时间从 {from} 改为 {to}。原文件不会被重新编码，但相册里的时间轴与排序会随之变化。',
        const {'from': 'A', 'to': 'B'},
      );
      expect(body, contains('from A to B'));
      expect(body, isNot(contains('{from}')));
      expect(body, isNot(contains('{to}')));

      final failed = photoMediaFill(
        PhotoMediaTextKeys.editDateFailed,
        '修改拍摄时间失败：{error}',
        const {'error': 'permission denied (105)'},
      );
      expect(failed, 'Failed to change capture time: permission denied (105)');
      expect(failed, isNot(contains('{error}')));

      expect(
        photoMedia(PhotoMediaTextKeys.editDateInvalid, '时间没有变化 —— 请先改日期或时刻。'),
        contains('did not change'),
      );
    });

    test('入口与按钮在英文下也必须是两个不同的字符串', () {
      setCurrentText(AppTextEn());
      final menu = photoMedia(PhotoMediaTextKeys.editDateMenuAction, '编辑日期时间');
      final action = photoMedia(PhotoMediaTextKeys.editDateAction, '保存');
      expect(menu, 'Edit date and time');
      expect(action, 'Save');
      expect(menu, isNot(action));
    });

    test('没装翻译器（纯 Dart 探针）时回落中文原文', () {
      // `setCurrentText` 只接受非空 `AppText`；要模拟"没装翻译器"必须
      // 走 `data_text.dart` 的卸载入口 —— 那正是 `tool/` 下纯 Dart 探针的形态。
      setDataTextResolver(null);
      expect(photoMedia(PhotoMediaTextKeys.liveBadge, '实况照片'), '实况照片');
      setCurrentText(AppTextZh());
      expect(photoMedia(PhotoMediaTextKeys.liveBadge, '实况照片'), '实况照片');
    });
  });
}
