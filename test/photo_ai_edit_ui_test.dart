// 相册 AI 美化（图生图）批次②：**UI / 接线 / 隐私前置 / 保存 / 能力表补缺**离线测试。
//
// 全部离线：Fake client（`_FakeClient` 覆写 `ImageEditClient.edit`）+ Fake
// `NetworkTypeProbe` + `MemoryCloudKeyStore` + FakeTransport（不连 NAS、不联网、
// 不动设备、不构建）。照片字节走 `photoAiEditBytesLoaderProvider` 的夹具。
//
// 覆盖（对应任务/方案 §8）：
//   1. 入口可见性（未配后端 / 总开关关闭 → 隐藏；并发中 → 禁用）；
//   2. 隐私前置（同意/拒绝零请求、横幅含 host、撤销同意）；
//   3. 预览（长按看原图）/ 默认主操作 = 保存为新照片（保留 mtime）/ 保存到本机；
//   4. 能力表补缺：缺 `SYNO.Foto.Upload.Item` → 隐藏"保存到相册"、本机保存仍可用；
//      **未检测 → fail-open 仍显示**（反例）；
//   5. 状态矩阵：无网 / 仅 WiFi 移动数据 / 无 key / 额度用尽 / 非法结果不落盘 /
//      保存 105 / 保存 119·106 / 取消不显示成功。
import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart' show CancelToken;
import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;

import 'package:synhub/src/core/theme/app_theme.dart';
import 'package:synhub/src/core/net/network_type.dart';
import 'package:synhub/src/core/services/service_availability.dart';
import 'package:synhub/src/core/services/service_registry.dart'
    show AvailabilityState, StationService, kFotoUploadApi;
import 'package:synhub/src/core/settings/app_settings.dart';
import 'package:synhub/src/core/settings/cloud_key_store.dart';
import 'package:synhub/src/data/ai/cloud_pricing.dart';
import 'package:synhub/src/data/ai/image_edit_client.dart';
import 'package:synhub/src/data/ai/image_edit_pricing.dart';
import 'package:synhub/src/data/dto/foto_dto.dart';
import 'package:synhub/src/data/foto_api.dart';
import 'package:synhub/src/data/local/database.dart';
import 'package:synhub/src/dsm/webapi.dart';
import 'package:synhub/src/features/ai/cloud_settings.dart';
import 'package:synhub/src/features/chat/chat_session_controller.dart'
    show chatDatabaseProvider;
import 'package:synhub/src/features/notifications/notification_service.dart'
    show networkTypeProbeProvider;
import 'package:synhub/src/features/photos/image_edit_providers.dart';
import 'package:synhub/src/features/photos/photo_ai_edit_sheet.dart';
import 'package:synhub/src/features/photos/photo_ai_edit_settings.dart';
import 'package:synhub/src/features/photos/photo_ai_edit_settings_page.dart';
import 'package:synhub/src/features/photos/photo_providers.dart';
import 'package:synhub/src/features/photos/photo_viewer_page.dart';
import 'package:synhub/src/features/photos/photo_widgets.dart';

import 'support/chat_harness.dart' show FakeTransport;

/// 4×4 JPEG 夹具：既能过 `prepareImageForEdit`（解码 → 重编码 JPEG），
/// 也能被 `Image.memory` 渲染。（**必须**能被 `image` 包解码 —— 1×1 PNG
/// 夹具过不了预检，用它会得到"无法解码"，那是夹具问题不是产品问题。）
final Uint8List _png = Uint8List.fromList(
  img.encodeJpg(img.Image(width: 4, height: 4)),
);

const _table = {
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
  'SYNO.Foto.Thumbnail': {
    'path': 'entry.cgi',
    'minVersion': 1,
    'maxVersion': 2,
  },
  'SYNO.Foto.Upload.Item': {
    'path': 'entry.cgi',
    'minVersion': 1,
    'maxVersion': 8,
  },
};

Map<String, dynamic> _item(String id) => {
  'id': id,
  'filename': 'IMG_$id.jpg',
  'filesize': 2048,
  // 拍摄时间（秒）——保存时 mtime 必须原样带过去
  'time': 1758189600,
  'folder_id': '10',
  'type': 'photo',
  'additional': {
    'thumbnail': {'sm': 'sm_$id', 'm': 'm_$id', 'cache_key': 'ck_$id'},
  },
};

class _FixedAvailability extends ServiceAvailabilityNotifier {
  _FixedAvailability(this.snapshot);

  final ServiceAvailabilitySnapshot snapshot;

  @override
  ServiceAvailabilitySnapshot build() => snapshot;
}

class _Net implements NetworkTypeProbe {
  _Net(this.value);

  NetworkType value;

  @override
  Future<NetworkType> current() async => value;
}

class _FakeClient extends ImageEditClient {
  _FakeClient({this.results, this.error, this.onEdit});

  final List<Uint8List>? results;
  final ImageEditException? error;

  /// 让用例在"请求进行中"做点事（例如点停止）
  final Future<void> Function(CancelToken? cancel)? onEdit;

  int calls = 0;
  ImageEditConfig? lastCfg;
  int? lastBytes;

  @override
  Future<ImageEditOutcome> edit({
    required ImageEditConfig cfg,
    required Uint8List imageBytes,
    String fileName = 'image.jpg',
    String mimeType = 'image/jpeg',
    CancelToken? cancel,
  }) async {
    calls++;
    lastCfg = cfg;
    lastBytes = imageBytes.length;
    if (onEdit != null) await onEdit!(cancel);
    if (error != null) throw error!;
    return ImageEditOutcome(
      images: results ?? [_png],
      requested: cfg.variantCount,
    );
  }
}

Future<void> _settle(WidgetTester tester) async {
  for (var i = 0; i < 10; i++) {
    await tester.pump(const Duration(milliseconds: 50));
  }
}

typedef _Harness = ({
  FakeTransport t,
  ProviderContainer c,
  Directory dir,
  _FakeClient client,
});

Future<_Harness> _pump(
  WidgetTester tester,
  Widget page, {
  bool enabled = true,
  bool consent = true,
  bool configured = true,
  bool uploadPresent = true,
  AvailabilityState photoState = AvailabilityState.available,
  NetworkType net = NetworkType.wifi,
  bool wifiOnly = false,
  int cap = 3,
  int seedImages = 0,
  String key = 'sk-test',
  String backend = 'openai_images_edits',
  String baseUrl = 'https://api.example.com/v1',
  List<Uint8List>? results,
  ImageEditException? error,
  Future<void> Function(CancelToken? cancel)? onEdit,
  Map<String, int> failures = const {},

  /// false = **一个偏好都不写**（用来验"默认关闭"等出厂默认值）
  bool seedSettings = true,
}) async {
  // 面板内容较高：放大画布，避免懒构建/溢出干扰点击
  tester.view.physicalSize = const Size(1200, 2600);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);

  final t = FakeTransport(const {}, {...FakeTransport.table, ..._table});
  t.downloadBytes = _png;
  t.failures.addAll(failures);
  t.onCall = (params) {
    final k = '${params['api']}.${params['method']}';
    if (k == 'SYNO.Foto.Setting.User.get') {
      return {
        'team_space_permission': 'none',
        'enable_similar': true,
        'enable_person': true,
        'enable_concept': true,
        'timeline_group_unit': 'day',
      };
    }
    return const <String, dynamic>{};
  };
  final api = DsmWebApi(t);
  await api.discover();
  await api.login(account: 'a', password: 'b');

  final db = ChatDatabase(NativeDatabase.memory());
  final dir = Directory.systemTemp.createTempSync('photo_ai_edit_ui');
  addTearDown(() {
    try {
      dir.deleteSync(recursive: true);
    } catch (_) {}
  });
  final keys = MemoryCloudKeyStore();
  final client = _FakeClient(results: results, error: error, onEdit: onEdit);

  final apis = <String>{
    'SYNO.Foto.Browse.Item',
    'SYNO.Foto.Browse.Album',
    'SYNO.Foto.Thumbnail',
    // 能力位补缺：这张表就是"统一检测"的事实来源
    if (uploadPresent) kFotoUploadApi,
  };
  final c = ProviderContainer(
    overrides: [
      chatDatabaseProvider.overrideWithValue(db),
      cloudKeyStoreProvider.overrideWithValue(keys),
      fotoApiProvider.overrideWithValue(FotoApi(api)),
      serviceAvailabilityProvider.overrideWith(
        () => _FixedAvailability(
          ServiceAvailabilitySnapshot(
            states: {
              for (final s in StationService.values)
                s: s == StationService.photo
                    ? photoState
                    : AvailabilityState.available,
            },
            apis: apis,
            checkedAt: DateTime(2026, 9, 22),
          ),
        ),
      ),
      networkTypeProbeProvider.overrideWithValue(_Net(net)),
      imageEditClientProvider.overrideWithValue(client),
      photoAiEditBytesLoaderProvider.overrideWithValue((item) async => _png),
      photoDownloadDirectoryProvider.overrideWithValue(() async => dir),
    ],
  );
  addTearDown(c.dispose);
  addTearDown(db.close);

  final svc = c.read(settingsServiceProvider);
  if (seedSettings) {
    await svc.setImageEditEnabled(enabled);
    await svc.setImageEditWifiOnly(wifiOnly);
    await svc.setImageEditDailyCap(cap);
    if (consent) await svc.setImageEditConsentV1('granted');
    if (configured) {
      await svc.setImageEditBackend(backend);
      await svc.setImageEditBaseUrl(baseUrl);
      await svc.setImageEditModel('gpt-image-1');
    }
    await keys.write(SettingsService.kImageEditKeySlot, key);
  }
  if (seedImages > 0) {
    await c
        .read(cloudSettingsProvider.notifier)
        .recordUsage(
          CloudUsageRecord(
            atMs: DateTime.now().millisecondsSinceEpoch,
            usage: CloudTokenUsage.zero,
            kind: kImageEditUsageKind,
            imageCount: seedImages,
          ),
        );
  }

  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: c,
      // ★ r332：**必须带产品主题**。裸 `MaterialApp` 没有 `minimumSize: Size.fromHeight(48)`，
      // 于是"主题 × Row/Wrap 子项"这类缺陷在这里**恒不可见**（r330 的 D32 就是这么漏掉的，
      // 见 AGENTS §2.0.61②/§2.0.63②）。带上主题后，本文件里所有 `TextButton`/`FilledButton`
      // 的父容器形状都会真的参与布局。
      child: MaterialApp(theme: AppTheme.dark(), home: page),
    ),
  );
  await _settle(tester);
  return (t: t, c: c, dir: dir, client: client);
}

Future<void> _tap(WidgetTester tester, String key) async {
  await tester.tap(find.byKey(Key(key)));
  await _settle(tester);
}

/// 打开 AI 美化面板并点一个预设填好提示词
Future<_Harness> _openPanel(
  WidgetTester tester, {
  required FotoItemDto item,
  bool consent = true,
  String preset = 'enhance',
  Future<void> Function(CancelToken?)? onEdit,
  ImageEditException? error,
  List<Uint8List>? results,
  Map<String, int> failures = const {},
  bool uploadPresent = true,
  AvailabilityState photoState = AvailabilityState.available,
  NetworkType net = NetworkType.wifi,
  bool wifiOnly = false,
  int cap = 3,
  int seedImages = 0,
  String key = 'sk-test',
  bool configured = true,
  bool enabled = true,
  String backend = 'openai_images_edits',
  String baseUrl = 'https://api.example.com/v1',
}) async {
  final r = await _pump(
    tester,
    PhotoViewerPage(items: [item]),
    enabled: enabled,
    consent: consent,
    configured: configured,
    uploadPresent: uploadPresent,
    photoState: photoState,
    net: net,
    wifiOnly: wifiOnly,
    cap: cap,
    seedImages: seedImages,
    key: key,
    backend: backend,
    baseUrl: baseUrl,
    onEdit: onEdit,
    error: error,
    results: results,
    failures: failures,
  );
  await _tap(tester, 'photo-ai-edit');
  if (consent && preset.isNotEmpty) {
    await _tap(tester, 'photo-ai-edit-preset-$preset');
  }
  return r;
}

void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;

  final item = FotoItemDto.fromJson(_item('1'));

  group('入口可见性（只加按钮；未配后端/总开关关闭 → 隐藏）', () {
    testWidgets('① 已配置 + 已开启 → 大图页 AppBar 显示"AI 美化"；旋转按钮仍在', (tester) async {
      await _pump(tester, PhotoViewerPage(items: [item]));
      expect(find.byKey(const Key('photo-ai-edit')), findsOne);
      // 既有旋转入口不倒退
      expect(find.byKey(const Key('photo-rotate')), findsOne);
    });

    testWidgets('② 未配后端 → 隐藏入口（不是禁用）', (tester) async {
      await _pump(tester, PhotoViewerPage(items: [item]), configured: false);
      expect(find.byKey(const Key('photo-ai-edit')), findsNothing);
      // 其余入口照常
      expect(find.byKey(const Key('photo-rotate')), findsOne);
      expect(find.byIcon(Icons.info_outline), findsOne);
    });

    testWidgets('③ 总开关关闭（默认态）→ 隐藏入口', (tester) async {
      await _pump(tester, PhotoViewerPage(items: [item]), enabled: false);
      expect(find.byKey(const Key('photo-ai-edit')), findsNothing);
      expect(find.byKey(const Key('photo-rotate')), findsOne);
    });

    testWidgets('④ 并发中 → 入口禁用（不是隐藏）', (tester) async {
      final r = await _pump(tester, PhotoViewerPage(items: [item]));
      expect(find.byKey(const Key('photo-ai-edit')), findsOne);
      r.c.read(imageEditBusyProvider.notifier).set(true);
      await tester.pump();
      final btn = tester.widget<IconButton>(
        find.byKey(const Key('photo-ai-edit')),
      );
      expect(btn.onPressed, isNull);
    });

    testWidgets('⑤ 多选栏：选 1 张可用，选 2 张置灰并写明原因', (tester) async {
      final ctl = PhotoSelectionController()..enter('1');
      await _pump(
        tester,
        Scaffold(
          body: PhotoSelectionBar(
            items: [item],
            space: FotoSpace.personal,
            onClear: ctl.clear,
            onAddToAlbum: () {},
          ),
        ),
      );
      expect(find.byKey(const Key('photo-selection-ai-edit')), findsOne);
      expect(
        tester
            .widget<TextButton>(
              find.byKey(const Key('photo-selection-ai-edit')),
            )
            .onPressed,
        isNotNull,
      );

      final two = [item, FotoItemDto.fromJson(_item('2'))];
      await _pump(
        tester,
        Scaffold(
          body: PhotoSelectionBar(
            items: two,
            space: FotoSpace.personal,
            onClear: () {},
            onAddToAlbum: () {},
          ),
        ),
      );
      expect(
        tester
            .widget<TextButton>(
              find.byKey(const Key('photo-selection-ai-edit')),
            )
            .onPressed,
        isNull,
        reason: 'V1 只支持单选：多选置灰',
      );
      expect(find.byKey(const Key('photo-selection-ai-edit-hint')), findsOne);
      expect(find.textContaining('只能处理 1 张'), findsWidgets);
    });
  });

  group('隐私前置（硬要求，逐条）', () {
    testWidgets('① 未同意 → 阻断式同意页；拒绝 → 零请求且不留痕', (tester) async {
      final r = await _openPanel(
        tester,
        item: item,
        consent: false,
        preset: '',
      );
      expect(find.byKey(kPhotoAiEditConsentKey), findsOne);
      // 同意页里没有 checkbox / 不再提示
      expect(find.byType(Checkbox), findsNothing);
      expect(find.textContaining('不再提示'), findsNothing);
      await _tap(tester, 'photo-ai-edit-consent-refuse');
      expect(r.client.calls, 0, reason: '拒绝同意必须零请求');
      expect(
        await r.c.read(settingsServiceProvider).imageEditConsentV1(),
        isNull,
        reason: '拒绝不留痕：偏好键必须仍未写入',
      );
      expect(find.byKey(kPhotoAiEditConsentKey), findsNothing);
    });

    testWidgets('② 显式点"我理解并同意" → 写入同意，随后可发起', (tester) async {
      final r = await _openPanel(
        tester,
        item: item,
        consent: false,
        preset: '',
      );
      expect(find.byKey(kPhotoAiEditConsentKey), findsOne);
      await _tap(tester, 'photo-ai-edit-consent-agree');
      expect(
        await r.c.read(settingsServiceProvider).imageEditConsentV1(),
        'granted',
      );
      expect(find.byKey(kPhotoAiEditConsentKey), findsNothing);
      expect(find.byKey(kPhotoAiEditStartKey), findsOne);
    });

    testWidgets('③ 每次发送前固定横幅，逐字含目标主机名（不可折叠）', (tester) async {
      await _openPanel(
        tester,
        item: item,
        baseUrl: 'https://api.example.com/v1',
      );
      expect(find.byKey(kPhotoAiEditBannerKey), findsOne);
      expect(find.textContaining('这张照片将被发送到'), findsOne);
      expect(find.textContaining('api.example.com'), findsWidgets);
    });

    testWidgets('④ 自建后端：横幅额外提示"照片仍会离开设备"', (tester) async {
      await _openPanel(
        tester,
        item: item,
        baseUrl: 'http://192.168.1.9:7860',
        backend: 'a1111_img2img',
        key: '',
      );
      expect(find.textContaining('192.168.1.9'), findsWidgets);
      expect(find.textContaining('仍会离开设备'), findsOne);
    });

    testWidgets('⑤ 证件照预设必须显示"不保证符合证件照规格"', (tester) async {
      await _openPanel(tester, item: item, preset: 'idPhoto');
      expect(find.textContaining('不保证符合证件照规格'), findsOne);
    });

    testWidgets('⑥ 撤销同意：清同意 + 关总开关 + 入口消失', (tester) async {
      final r = await _openPanel(tester, item: item);
      // 关闭面板，回到大图页
      await tester.tapAt(const Offset(4, 4));
      await _settle(tester);
      final rev = r.c.read(photoAiEditSettingsProvider).value!;
      expect(rev.consent, isTrue);
      await r.c.read(settingsServiceProvider).clearImageEditConsent();
      await r.c.read(settingsServiceProvider).setImageEditEnabled(false);
      r.c.invalidate(photoAiEditSettingsProvider);
      await _settle(tester);
      expect(find.byKey(const Key('photo-ai-edit')), findsNothing);
    });
  });

  group('发起前门控（每条都给确定文案，不许静默）', () {
    testWidgets('① 无网 → 拦截且零请求', (tester) async {
      final r = await _openPanel(tester, item: item, net: NetworkType.none);
      await _tap(tester, 'photo-ai-edit-start');
      expect(r.client.calls, 0);
      expect(find.textContaining('当前没有网络'), findsOne);
    });

    testWidgets('② 仅 WiFi + 移动数据 → 拦截；点"仍然使用流量"后放行', (tester) async {
      final r = await _openPanel(
        tester,
        item: item,
        net: NetworkType.mobile,
        wifiOnly: true,
      );
      await _tap(tester, 'photo-ai-edit-start');
      expect(r.client.calls, 0);
      expect(find.textContaining('仅 WiFi'), findsWidgets);
      await _tap(tester, 'photo-ai-edit-allow-mobile');
      expect(r.client.calls, 1, reason: '显式确认后必须能继续');
      expect(find.byKey(kPhotoAiEditResultKey), findsOne);
    });

    testWidgets('③ 缺 API Key → 拦截且零请求', (tester) async {
      final r = await _openPanel(tester, item: item, key: '');
      await _tap(tester, 'photo-ai-edit-start');
      expect(r.client.calls, 0);
      expect(find.textContaining('还没填 API Key'), findsOne);
    });

    testWidgets('④ 额度用尽 → 按钮禁用 + "今日剩余 0/3" 文案', (tester) async {
      final r = await _openPanel(tester, item: item, seedImages: 3, cap: 3);
      expect(find.textContaining('今日剩余 0/3'), findsOne);
      expect(
        tester.widget<FilledButton>(find.byKey(kPhotoAiEditStartKey)).onPressed,
        isNull,
      );
      // 点了也没请求（按钮禁用）
      await tester.tap(find.byKey(kPhotoAiEditStartKey), warnIfMissed: false);
      await _settle(tester);
      expect(r.client.calls, 0);
    });

    testWidgets('⑤a 变体数 >1：显示张数与"单价未知"（不猜数字）', (tester) async {
      await _openPanel(tester, item: item);
      expect(find.textContaining('单价未知'), findsNothing);
      await _tap(tester, 'photo-ai-edit-variant-plus');
      expect(find.textContaining('将生成 2 张'), findsOne);
      expect(find.textContaining('单价未知'), findsOne);
    });

    testWidgets('⑤b 自建/局域网 → 预计费用 0', (tester) async {
      await _openPanel(
        tester,
        item: item,
        baseUrl: 'http://127.0.0.1:7860',
        backend: 'a1111_img2img',
        key: '',
      );
      await _tap(tester, 'photo-ai-edit-variant-plus');
      expect(find.textContaining('0（自建/局域网）'), findsOne);
    });
  });

  group('预览 / 结果 / 保存', () {
    testWidgets('① 结果页：默认主操作是"保存为新照片"，"覆盖"不出现', (tester) async {
      final r = await _openPanel(tester, item: item);
      await _tap(tester, 'photo-ai-edit-start');
      expect(r.client.calls, 1);
      expect(find.byKey(kPhotoAiEditResultKey), findsOne);
      expect(find.byKey(kPhotoAiEditSaveTimelineKey), findsOne);
      expect(find.byKey(kPhotoAiEditSaveDeviceKey), findsOne);
      expect(find.textContaining('覆盖'), findsNothing);
      expect(find.textContaining('按住查看原图'), findsOne);
    });

    testWidgets('② 保存为新照片：Upload.Item/upload，名字带 _ai_，mtime 保留', (
      tester,
    ) async {
      final r = await _openPanel(tester, item: item, results: [_png, _png]);
      await _tap(tester, 'photo-ai-edit-start');
      await _tap(tester, 'photo-ai-edit-save-timeline');
      final call = r.t.calls.lastWhere(
        (c) => '${c['api']}.${c['method']}' == 'SYNO.Foto.Upload.Item.upload',
      );
      expect(
        '${call['name']}',
        matches(RegExp(r'^"IMG_1_ai_\d{8}_\d{6}\.jpg"$')),
      );
      expect(
        call['file_name'],
        matches(RegExp(r'^IMG_1_ai_\d{8}_\d{6}\.jpg$')),
      );
      // 保留原 mtime（`item.time` 是秒）
      expect('${call['mtime']}', '${item.time}');
      expect(call['file_bytes'], _png);
      expect(call['uploadDestination'], '"timeline"');
    });

    testWidgets('③ 保存到本机：落既有多媒体下载目录（不落 NAS）', (tester) async {
      final r = await _openPanel(tester, item: item);
      await _tap(tester, 'photo-ai-edit-start');
      await _tap(tester, 'photo-ai-edit-save-device');
      final files = r.dir.listSync().whereType<File>().toList();
      expect(files, hasLength(1));
      expect(files.first.path, contains('IMG_1_ai_'));
      expect(files.first.readAsBytesSync(), _png);
    });
  });

  group('能力表补缺：SYNO.Foto.Upload.Item（fail-open 反例）', () {
    testWidgets('① 能力表明确没有该位 → 隐藏"保存到相册"，本机保存仍可用', (tester) async {
      final r = await _openPanel(
        tester,
        item: item,
        uploadPresent: false,
        photoState: AvailabilityState.partial,
      );
      await _tap(tester, 'photo-ai-edit-start');
      expect(r.client.calls, 1);
      expect(find.byKey(kPhotoAiEditSaveTimelineKey), findsNothing);
      expect(find.byKey(kPhotoAiEditSaveDeviceKey), findsOne);
      expect(find.textContaining('这台 NAS 不支持'), findsOne);
    });

    testWidgets('② fail-open 反例：**未检测**（photo unknown）→ 保存按钮仍显示', (
      tester,
    ) async {
      final r = await _openPanel(
        tester,
        item: item,
        uploadPresent: false,
        photoState: AvailabilityState.unknown,
      );
      await _tap(tester, 'photo-ai-edit-start');
      expect(r.client.calls, 1);
      expect(
        find.byKey(kPhotoAiEditSaveTimelineKey),
        findsOne,
        reason: '不确定一律 fail-open，不能因为没检测就隐藏功能',
      );
    });

    testWidgets('③ 105 → 只隐藏"保存到相册"，"保存到本机"仍在（不隐藏模块）', (tester) async {
      final r = await _openPanel(
        tester,
        item: item,
        failures: const {'SYNO.Foto.Upload.Item.upload': 105},
      );
      await _tap(tester, 'photo-ai-edit-start');
      await _tap(tester, 'photo-ai-edit-save-timeline');
      expect(find.byKey(kPhotoAiEditSaveTimelineKey), findsNothing);
      expect(find.byKey(kPhotoAiEditSaveDeviceKey), findsOne);
      expect(find.textContaining('没有权限保存到相册'), findsOne);
      expect(r.client.calls, 1);
    });

    testWidgets('④a 106 → 提示会话过期，但保存按钮**不隐藏**', (tester) async {
      final r = await _openPanel(
        tester,
        item: item,
        failures: const {'SYNO.Foto.Upload.Item.upload': 106},
      );
      await _tap(tester, 'photo-ai-edit-start');
      await _tap(tester, 'photo-ai-edit-save-timeline');
      expect(find.byKey(kPhotoAiEditSaveTimelineKey), findsOne);
      expect(find.textContaining('会话已过期'), findsWidgets);
      expect(r.client.calls, 1);
      await tester.pump(const Duration(seconds: 5));
    });

    testWidgets('④b 119 → 提示会话过期，但保存按钮**不隐藏**', (tester) async {
      final r = await _openPanel(
        tester,
        item: item,
        failures: const {'SYNO.Foto.Upload.Item.upload': 119},
      );
      await _tap(tester, 'photo-ai-edit-start');
      await _tap(tester, 'photo-ai-edit-save-timeline');
      expect(find.byKey(kPhotoAiEditSaveTimelineKey), findsOne);
      expect(find.textContaining('会话已过期'), findsWidgets);
      expect(r.client.calls, 1);
      await tester.pump(const Duration(seconds: 5));
    });
  });

  group('非法结果 / 取消（不许落盘、不许静默成功）', () {
    testWidgets('① 非法结果 → 文案 + 保存目录为空（零落盘）', (tester) async {
      final r = await _openPanel(
        tester,
        item: item,
        error: ImageEditException(ImageEditErrorKind.invalidImageResult),
      );
      await _tap(tester, 'photo-ai-edit-start');
      expect(find.textContaining('服务返回的数据不是图片'), findsOne);
      expect(find.byKey(kPhotoAiEditResultKey), findsNothing);
      expect(r.dir.listSync(), isEmpty, reason: '非法结果不得落盘（保存目录必须为空）');
    });

    testWidgets('② 取消（已发出）→ 不显示成功；如实说"可能仍会计费"', (tester) async {
      final hold = Completer<void>();
      final r = await _openPanel(
        tester,
        item: item,
        onEdit: (cancel) async {
          await hold.future;
          if (cancel?.isCancelled ?? false) {
            throw ImageEditException(ImageEditErrorKind.cancelledBilling);
          }
        },
      );
      await _tap(tester, 'photo-ai-edit-start');
      expect(find.byKey(kPhotoAiEditStopKey), findsOne);
      await _tap(tester, 'photo-ai-edit-stop');
      expect(r.client.calls, 1);
      hold.complete();
      await _settle(tester);
      expect(find.byKey(kPhotoAiEditResultKey), findsNothing);
      expect(find.textContaining('服务端可能仍会计费'), findsOne);
    });
  });

  // ══════════════════════════════════════════════════════════════════════
  // 第 255 轮：图生图设置**独立成页**（用户 2026-09-25 要求）
  //
  // 用户原话：「目前图生图设置怎么和大语言模型设置混在一起了？能否拆开独立配置？」
  // ⇒ 本组钉两件事：① 独立页可用（控件、开关、撤销同意都还在）；
  //   ② 大语言模型页（`ai_model_page.dart`）里**不再**出现图生图卡片
  //      （后者在 `ai_device_fit_page_test.dart` 里断言，那边本来就 pump 了那页）。
  // ══════════════════════════════════════════════════════════════════════
  group('第 255 轮：图生图设置独立成页', () {
    testWidgets('① 独立页 = 标题 + 卡片 + "与大语言模型互不影响"说明', (tester) async {
      await _pump(tester, const PhotoAiEditSettingsPage());
      expect(
        find.byKey(const Key('image-edit-settings-card')),
        findsOne,
        reason: '★ 图生图设置卡必须能在**自己的页**里完整出现',
      );
      expect(find.text('AI 美化（图生图）'), findsWidgets);
      expect(
        find.textContaining('各自独立，互不影响'),
        findsOne,
        reason: '★★ 用户就是被"混在一起"搞糊涂的 ⇒ 页面要明说两者独立',
      );
      // 四个关键控件都还在（拆页不许把功能拆丢）
      for (final k in const [
        'image-edit-settings-enable',
        'image-edit-settings-backend',
        'image-edit-settings-model',
        'image-edit-settings-cap',
      ]) {
        expect(find.byKey(Key(k)), findsOne, reason: '$k 不该在拆页时丢失');
      }
    });

    testWidgets('② 在独立页里改设置照旧落库（开关 + 单日上限）', (tester) async {
      final r = await _pump(
        tester,
        const PhotoAiEditSettingsPage(),
        enabled: false,
        consent: false,
      );
      await _tap(tester, 'image-edit-settings-enable');
      expect(await r.c.read(settingsServiceProvider).imageEditEnabled(), isTrue);
      expect(
        await r.c.read(settingsServiceProvider).imageEditDailyCap(),
        isNot(0),
        reason: '★ 拆页不该影响偏好键（`imageEdit*` 一个都没换）',
      );
    });

    testWidgets('③ 撤销同意仍然只清同意 + 关开关（独立页里也一样）', (tester) async {
      final r = await _pump(tester, const PhotoAiEditSettingsPage());
      await _tap(tester, 'image-edit-settings-revoke');
      final svc = r.c.read(settingsServiceProvider);
      expect(await svc.imageEditConsentV1(), isNull);
      expect(await svc.imageEditEnabled(), isFalse);
    });
  });

  group('设置页 AI 卡片 + 出厂默认（默认关闭）', () {
    testWidgets('① 一个偏好都不写：enabled=false / 未同意 / 仅 WiFi / 上限 3；入口隐藏', (
      tester,
    ) async {
      final r = await _pump(
        tester,
        PhotoViewerPage(items: [item]),
        seedSettings: false,
      );
      final svc = r.c.read(settingsServiceProvider);
      expect(await svc.imageEditEnabled(), isFalse);
      expect(await svc.imageEditConsentV1(), isNull);
      expect(await svc.imageEditWifiOnly(), isTrue);
      expect(await svc.imageEditDailyCap(), kImageEditDefaultDailyCap);
      expect(find.byKey(const Key('photo-ai-edit')), findsNothing);
    });

    testWidgets('② 撤销同意 → 清同意 + 关总开关', (tester) async {
      final r = await _pump(
        tester,
        const Scaffold(body: PhotoAiEditSettingsCard()),
      );
      expect(find.byKey(const Key('image-edit-settings-card')), findsOne);
      expect(find.textContaining('已同意'), findsOne);
      await _tap(tester, 'image-edit-settings-revoke');
      final svc = r.c.read(settingsServiceProvider);
      expect(await svc.imageEditConsentV1(), isNull);
      expect(await svc.imageEditEnabled(), isFalse);
    });

    testWidgets('③ 总开关会落库', (tester) async {
      final r = await _pump(
        tester,
        const Scaffold(body: PhotoAiEditSettingsCard()),
        enabled: false,
        consent: false,
      );
      await _tap(tester, 'image-edit-settings-enable');
      expect(
        await r.c.read(settingsServiceProvider).imageEditEnabled(),
        isTrue,
      );
    });
  });
}
