// 相册 P0：**删除（进回收站）** 与 **视频画质三档选档** 的离线承重。
//
// 事实来源（逐条给原文，不猜）：
//   * 服务端方法表 `usr/webapi/SYNO.Foto.lib`（SynologyPhotos 1.9.1-10928）：
//     `SYNO.Foto.Browse.Item` 的 `delete` 在 v1..v7 都在；`get` 同。
//   * 官方 Android 2.4.0-644（jadx 1.5.3）：
//     - `ApiBrowseItem.API_VERSION = 7`，`DeleteParameters{api,method:"delete",version,id}`；
//     - `VideoInfoHelper`：`CONTAINER_WHITELIST={"mp4"}`、`CODEC_WHITELIST={"h264","hevc"}`、
//       `NO_HEVC_VIDEO_CODEC_WHITELIST={"h264"}`、`FRAME_RATE_THRESHOLD=50.0`、
//       `QUALITY_ORIGIN_PREFIX="orig"`；`QualityBias{QUALITY("quality"),SPEED("speed"),AUTO("auto")}`；
//       候选档过滤掉 `orig*`，按 `metadata.video_bitrate` 取最高/最低；空候选/ORIGINAL → Download。
//   * 官方 APK `resources.arsc`：`array/video_quality_value=[auto|quality|speed]`。
//   * 官方 Web（同 SPK `ui/react_bundle.js`）：批量下载 `{force_download:!0,item_id:[…]}`；
//     `"raw"` 档走 Download、**永不进 Streaming**。
import 'package:flutter_test/flutter_test.dart';

import 'package:synhub/src/data/dto/foto_dto.dart';
import 'package:synhub/src/data/foto_api.dart';
import 'package:synhub/src/dsm/webapi.dart';

import 'support/chat_harness.dart' show FakeTransport;

const _fotoTable = {
  'SYNO.API.Info': {'path': 'query.cgi', 'minVersion': 1, 'maxVersion': 1},
  'SYNO.Foto.Browse.Item': {
    'path': 'entry.cgi',
    'minVersion': 1,
    'maxVersion': 9,
  },
  'SYNO.Foto.Download': {'path': 'entry.cgi', 'minVersion': 1, 'maxVersion': 2},
  'SYNO.FotoTeam.Browse.Item': {
    'path': 'entry.cgi',
    'minVersion': 1,
    'maxVersion': 9,
  },
};

Future<FotoApi> _api(
  FakeTransport t, {
  FotoSpace space = FotoSpace.personal,
}) async {
  final api = DsmWebApi(t);
  await api.discover();
  await api.login(account: 'a', password: 'b');
  return FotoApi(api, space: space);
}

FakeTransport _transport({
  Map<String, Map<String, dynamic>> byApi = const {},
  Map<String, int> failures = const {},
}) {
  final t = FakeTransport(const {}, {...FakeTransport.table, ..._fotoTable});
  t.onCall = (params) {
    // 只有浏览类 API 用 canonical 键；Download 是 URL 拼接、不经 onCall
    final api = '${params['api']}';
    final method = '${params['method']}';
    return byApi['$api.$method'];
  };
  t.failures.addAll(failures);
  return t;
}

Map<String, dynamic> _lastFor(FakeTransport t, String api) =>
    t.calls.lastWhere((c) => c['api'] == api);

FotoVideoConvertDto _convert(
  String quality,
  int bitrate, {
  String codec = 'h264',
}) => FotoVideoConvertDto(
  quality: quality,
  metadata: FotoVideoMetaDto(
    containerType: 'mp4',
    videoCodec: codec,
    width: 1920,
    height: 1080,
    framerate: 30,
    videoBitrate: bitrate,
  ),
);

void main() {
  group('Browse.Item/delete（P0-1）', () {
    test('方法名/版本/参数：delete + v7 + 数字数组 JSON 串的 id', () async {
      final t = _transport(
        byApi: {
          'SYNO.Foto.Browse.Item.delete': {'error_list': <dynamic>[]},
        },
      );
      final api = await _api(t);
      final failed = await api.deleteItems(['7', '8']);
      expect(failed, isEmpty);

      final call = _lastFor(t, 'SYNO.Foto.Browse.Item');
      expect(call['method'], 'delete');
      expect('${call['version']}', '7');
      // id 必须是"数字数组的 JSON 串"（字符串数组服务端回 120）
      expect(call['id'], '[7,8]');
    });

    test('非数字 id 被丢掉，不发改一个必然 120 的请求', () async {
      final t = _transport();
      final api = await _api(t);
      final failed = await api.deleteItems(['abc', '']);
      expect(failed, isEmpty);
      expect(
        t.calls.where((c) => c['api'] == 'SYNO.Foto.Browse.Item'),
        isEmpty,
      );
    });

    test('error_list 的失败项原样回给调用方（部分失败不静默）', () async {
      final t = _transport(
        byApi: {
          'SYNO.Foto.Browse.Item.delete': {
            'error_list': [
              {'id': 8},
              {'id': 9},
            ],
          },
        },
      );
      final api = await _api(t);
      expect(await api.deleteItems(['7', '8', '9']), ['8', '9']);
    });

    test('整批失败（非会话错）→ 全批 id 都算失败，不静默', () async {
      final t = _transport(failures: {'SYNO.Foto.Browse.Item.delete': 500});
      final api = await _api(t);
      expect(await api.deleteItems(['7', '8']), ['7', '8']);
    });

    test('共享空间走 SYNO.FotoTeam 前缀（同一删除能力）', () async {
      final t = _transport(
        byApi: {
          'SYNO.FotoTeam.Browse.Item.delete': {'error_list': <dynamic>[]},
        },
      );
      final api = await _api(t, space: FotoSpace.team);
      await api.deleteItems(['3']);
      expect(_lastFor(t, 'SYNO.FotoTeam.Browse.Item')['method'], 'delete');
    });
  });

  group('批量下载 URL（P0-2）', () {
    test('多张 → item_id 数组 + force_download（官方 iD 的形态）', () async {
      final t = _transport();
      final api = await _api(t);
      final url = api.downloadManyUrl(itemIds: ['11', '12']);
      expect(url, contains('api=SYNO.Foto.Download'));
      expect(url, contains('method=download'));
      expect(url, contains('force_download=true'));
      expect(
        url.contains('[11,12]') || url.contains('%5B11%2C12%5D'),
        isTrue,
        reason: url,
      );
    });
  });

  group('视频画质三档选档（P0-3，官方 VideoInfoHelper 逐条）', () {
    const native = FotoVideoMetaDto(
      containerType: 'mp4',
      videoCodec: 'h264',
      width: 1920,
      height: 1080,
      framerate: 30,
    );

    test('quality：原文件本身是 mp4+h264 → Download 原文件（不进 Streaming）', () {
      final plan = chooseFotoVideoPlayback(
        info: FotoVideoInfoDto(
          meta: native,
          converts: [_convert('high', 5000000)],
        ),
        bias: FotoVideoQualityBias.quality,
        onWifi: true,
      );
      expect(plan.isOriginal, isTrue);
      expect(plan.streamingQuality, isNull);
    });

    test('quality：原文件不可直放 → 码率最高的非 orig 档', () {
      final plan = chooseFotoVideoPlayback(
        info: FotoVideoInfoDto(
          meta: const FotoVideoMetaDto(
            containerType: 'mkv',
            videoCodec: 'h264',
          ),
          converts: [
            _convert('orig_h264', 9000000),
            _convert('high', 5000000),
            _convert('low', 1000000),
          ],
        ),
        bias: FotoVideoQualityBias.quality,
        onWifi: true,
      );
      expect(plan.isOriginal, isFalse);
      expect(plan.streamingQuality, 'high');
    });

    test('speed：永远取码率最低档（即使原文件能直放）', () {
      final plan = chooseFotoVideoPlayback(
        info: FotoVideoInfoDto(
          meta: native,
          converts: [_convert('high', 5000000), _convert('low', 1000000)],
        ),
        bias: FotoVideoQualityBias.speed,
        onWifi: true,
      );
      expect(plan.streamingQuality, 'low');
    });

    test('auto：非 Wi-Fi → 码率最低档', () {
      final plan = chooseFotoVideoPlayback(
        info: FotoVideoInfoDto(
          meta: native,
          converts: [_convert('high', 5000000), _convert('low', 1000000)],
        ),
        bias: FotoVideoQualityBias.auto,
        onWifi: false,
      );
      expect(plan.streamingQuality, 'low');
    });

    test('auto：Wi-Fi + 原文件 h264/不到 FHD/帧率<50 → Download 原文件', () {
      final plan = chooseFotoVideoPlayback(
        info: FotoVideoInfoDto(
          meta: native,
          converts: [_convert('high', 5000000)],
        ),
        bias: FotoVideoQualityBias.auto,
        onWifi: true,
      );
      expect(plan.isOriginal, isTrue);
    });

    test('auto：Wi-Fi + 原文件 4K/60fps → 不直放，取最高档', () {
      final plan = chooseFotoVideoPlayback(
        info: FotoVideoInfoDto(
          meta: const FotoVideoMetaDto(
            containerType: 'mp4',
            videoCodec: 'h264',
            width: 3840,
            height: 2160,
            framerate: 60,
          ),
          converts: [_convert('high', 5000000), _convert('low', 1000000)],
        ),
        bias: FotoVideoQualityBias.auto,
        onWifi: true,
      );
      expect(plan.streamingQuality, 'high');
    });

    test('没有可用转码档 → 回落 Download 原文件（官方同款分支）', () {
      final plan = chooseFotoVideoPlayback(
        info: FotoVideoInfoDto(
          meta: native,
          converts: [_convert('orig_h264', 9000000)],
        ),
        bias: FotoVideoQualityBias.speed,
        onWifi: true,
      );
      expect(plan.isOriginal, isTrue);
      expect(plan.streamingQuality, isNull);
    });

    test('`raw` 永不作为 Streaming 的 quality（被结构挡回 Download）', () {
      final plan = chooseFotoVideoPlayback(
        info: FotoVideoInfoDto(
          meta: const FotoVideoMetaDto(containerType: 'mkv'),
          converts: [_convert('raw', 9000000)],
        ),
        bias: FotoVideoQualityBias.quality,
        onWifi: true,
      );
      expect(plan.isOriginal, isTrue);
      expect(plan.streamingQuality, isNot('raw'));
    });

    test('三档 × 任意输入，streamingQuality 都不是 raw/original', () {
      final info = FotoVideoInfoDto(
        meta: const FotoVideoMetaDto(containerType: 'mkv', videoCodec: 'vp9'),
        converts: [
          _convert('raw', 9000000),
          _convert('original', 8000000),
          _convert('high', 5000000),
        ],
      );
      for (final bias in FotoVideoQualityBias.values) {
        for (final wifi in [true, false]) {
          final plan = chooseFotoVideoPlayback(
            info: info,
            bias: bias,
            onWifi: wifi,
          );
          expect(plan.streamingQuality, isNot('raw'));
          expect(plan.streamingQuality, isNot('original'));
        }
      }
    });
  });

  group('videoPlaybackInfo（P0-3 素材）', () {
    test(
      'Browse.Item/get v7 + additional 带 video_convert/video_meta',
      () async {
        final t = _transport(
          byApi: {
            'SYNO.Foto.Browse.Item.get': {
              'list': [
                {
                  'id': 5,
                  'additional': {
                    'video_meta': {
                      'container_type': 'mp4',
                      'video_codec': 'h264',
                      'resolution': {'width': 1280, 'height': 720},
                      'framerate': 29.97,
                    },
                    'video_convert': [
                      {
                        'quality': 'high',
                        'metadata': {'video_bitrate': 4000000},
                      },
                    ],
                  },
                },
              ],
            },
          },
        );
        final api = await _api(t);
        final info = await api.videoPlaybackInfo('5');
        expect(info.meta.containerType, 'mp4');
        expect(info.meta.videoCodec, 'h264');
        expect(info.meta.width, 1280);
        expect(info.converts.single.quality, 'high');
        expect(info.converts.single.videoBitrate, 4000000);

        final call = _lastFor(t, 'SYNO.Foto.Browse.Item');
        expect(call['method'], 'get');
        expect('${call['version']}', '7');
        expect('${call['additional']}', contains('video_convert'));
        expect(call['id'], '[5]');
      },
    );

    test('非数字 id / 响应缺字段都不抛（按 Download 原文件回落）', () async {
      final t = _transport();
      final api = await _api(t);
      final info = await api.videoPlaybackInfo('abc');
      expect(info.converts, isEmpty);
      final plan = chooseFotoVideoPlayback(
        info: info,
        bias: FotoVideoQualityBias.auto,
        onWifi: true,
      );
      expect(plan.isOriginal, isTrue);
    });
  });
}
