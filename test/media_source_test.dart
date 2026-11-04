// 「可播放 URL」解析层（`lib/src/features/media/media_source.dart`）的离线测试。
//
// 这一层是**纯逻辑**（不 import flutter/l10n，也不碰界面），要钉死四件事：
//   1. URL 拼装：`_sid` / `SynoToken` 真的在**查询串**里（原生播放器只吃 URL）；
//   2. 空 URL / 隧道空串 → **拒绝**（枚举原因，不把空串塞给播放器）；
//   3. Drive 写死 `Accept-Ranges: none` → `supportsRange=false`，视频直接降级；
//   4. Photos 的取流方法名是 **`streaming`**（`stream` 是 bug，本批修正）。
//
// 事实来源：docs/native-media-playback-research.md §3.1 / §3.3 / §3.4 / §5.4。
import 'package:flutter_test/flutter_test.dart';

import 'package:synhub/src/data/drive_api.dart';
import 'package:synhub/src/data/dto/file_entry_dto.dart';
import 'package:synhub/src/data/filestation_api.dart';
import 'package:synhub/src/data/foto_api.dart';
import 'package:synhub/src/dsm/webapi.dart';
import 'package:synhub/src/features/media/media_source.dart';

import 'support/chat_harness.dart' show FakeTransport;

/// 能力表里补上本批要用的几个 API（其余沿用脚手架的表）
const _mediaTable = <String, Map<String, dynamic>>{
  'SYNO.FileStation.Download': {
    'path': 'entry.cgi',
    'minVersion': 1,
    'maxVersion': 2,
  },
  'SYNO.SynologyDrive.Files': {
    'path': 'entry.cgi',
    'minVersion': 1,
    'maxVersion': 11,
  },
  'SYNO.Foto.Streaming': {
    'path': 'entry.cgi',
    'minVersion': 1,
    'maxVersion': 2,
  },
  'SYNO.FotoTeam.Streaming': {
    'path': 'entry.cgi',
    'minVersion': 1,
    'maxVersion': 2,
  },
  'SYNO.Foto.Download': {'path': 'entry.cgi', 'minVersion': 1, 'maxVersion': 2},
  'SYNO.FotoTeam.Download': {
    'path': 'entry.cgi',
    'minVersion': 1,
    'maxVersion': 2,
  },
};

Map<String, Map<String, dynamic>> get _table => {
  ...FakeTransport.table,
  ..._mediaTable,
};

/// 与**真实** `DirectTransport` 同形的假传输：`_sid` / `SynoToken` 都拼进查询串。
///
/// 脚手架的 `FakeTransport` 少了 `SynoToken`，测不出"鉴权只靠查询串、播放器不需要
/// 自定义头"这件事（那正是本方案能原生 seek 的前提）。
class _MediaTransport extends FakeTransport {
  _MediaTransport([super.responses, super.apiTable]);

  @override
  String authenticatedUrl(
    String path,
    Map<String, String> params, {
    String? sid,
  }) {
    final qp = <String, String>{
      ...params,
      if (sid != null && sid.isNotEmpty) '_sid': sid,
      if (synoToken != null && synoToken!.isNotEmpty) 'SynoToken': synoToken!,
    };
    final q = qp.entries
        .map((e) => '${e.key}=${Uri.encodeQueryComponent(e.value)}')
        .join('&');
    return 'https://fake.test/webapi/$path?$q';
  }
}

/// `authenticatedUrl` 返回空串的传输（模拟"没登录 / 服务端不给直链"）
class _EmptyUrlTransport extends _MediaTransport {
  _EmptyUrlTransport([super.responses, super.apiTable]);

  @override
  String authenticatedUrl(
    String path,
    Map<String, String> params, {
    String? sid,
  }) => '';
}

/// 真正的隧道传输：`TunnelTransport.authenticatedUrl` 在 `tcpPort == 0` 时返回空串
class _TunnelTransport extends _EmptyUrlTransport {
  _TunnelTransport([super.responses, super.apiTable]);

  @override
  String get describeKind => 'tunnel(127.0.0.1:0)';
}

/// **承重**假传输：登录/能力表沿用脚手架，但 `authenticatedUrl` 直接调用
/// **生产代码**（`DirectTransport.authenticatedQueryUrl`）。
///
/// 为什么不能只用 `_MediaTransport` 那种手抄一份的假实现：测试自己抄的拼装
/// 永远不会红 —— 把 `webapi.dart` 里的 `_sid` / `SynoToken` 拼装改坏，手抄的
/// 假实现照样"通过"。这里断言的是生产代码，回退即失败（falsification）。
class _RealUrlTransport extends FakeTransport {
  _RealUrlTransport([super.responses, super.apiTable]);

  @override
  String authenticatedUrl(
    String path,
    Map<String, String> params, {
    String? sid,
  }) => DirectTransport.authenticatedQueryUrl(
    'https://nas.example.com:5001/webapi/$path',
    params,
    sid: sid,
    synoToken: synoToken,
  );
}

/// 复刻**修复前**的隧道传输：`synoToken` 有值，但拼 URL 时**不往查询串放
/// `SynoToken`**（老的 `TunnelTransport` 就是这样）。媒体层必须把它拦成
/// [MediaUnavailableReason.sessionExpired]，而不是把裸 URL 交给 Media3。
class _LegacyTunnelUrlTransport extends _RealUrlTransport {
  _LegacyTunnelUrlTransport([super.responses, super.apiTable]);

  @override
  String authenticatedUrl(
    String path,
    Map<String, String> params, {
    String? sid,
  }) => DirectTransport.authenticatedQueryUrl(
    'https://127.0.0.1:8443/webapi/$path',
    params,
    sid: sid,
    // 故意丢掉 CSRF：模拟隧道漏 SynoToken 的旧行为
    synoToken: null,
  );
}

/// `authenticatedUrl` 有 token 但**没有 `_sid`**（会话丢了 / 还没登录）
class _NoSidUrlTransport extends _RealUrlTransport {
  _NoSidUrlTransport([super.responses, super.apiTable]);

  @override
  String authenticatedUrl(
    String path,
    Map<String, String> params, {
    String? sid,
  }) => DirectTransport.authenticatedQueryUrl(
    'https://nas.example.com:5001/webapi/$path',
    params,
    sid: null,
    synoToken: synoToken,
  );
}

FileEntryDto _entry(String name, {String? path, int size = 1024}) =>
    FileEntryDto(
      name: name,
      path: path ?? '/home/$name',
      isDir: false,
      size: size,
      mtime: 1758100000,
    );

Future<DsmWebApi> _boot(FakeTransport t) async {
  final api = DsmWebApi(t);
  await api.discover();
  await api.login(account: 'a', password: 'b');
  return api;
}

Future<DsmWebApi> _api() => _boot(_MediaTransport(const {}, _table));

void main() {
  group('真实传输的鉴权形态（原生播放器只吃 URL）', () {
    test('DirectTransport：_sid + SynoToken 都在查询串，不是自定义头', () {
      final t = DirectTransport.url('https://nas.example.com:5001/');
      t.synoToken = 'FAKE-TOKEN';
      final url = t.authenticatedUrl('entry.cgi', {
        'api': 'SYNO.FileStation.Download',
        'version': '2',
        'method': 'download',
        'path': '["/home/a.mp3"]',
        'mode': 'download',
      }, sid: 'SID-1');
      expect(Uri.parse(url).queryParameters['_sid'], 'SID-1');
      expect(Uri.parse(url).queryParameters['SynoToken'], 'FAKE-TOKEN');
      expect(url, contains('api=SYNO.FileStation.Download'));
      // 没有 token 时不要发一个空的 SynoToken（服务端把空值当"没带"）
      final t2 = DirectTransport.url('https://nas.example.com:5001/');
      expect(
        t2.authenticatedUrl('entry.cgi', const {}, sid: 'S'),
        isNot(contains('SynoToken')),
      );
    });

    test('直连与隧道**共用**同一个拼装函数：隧道形态的 base 也带 _sid+SynoToken', () {
      // `TunnelTransport.authenticatedUrl` 现在只做一件事：把
      // `https://127.0.0.1:<port>` 这个 base 交给
      // `DirectTransport.authenticatedQueryUrl`。所以这里断言那个共享函数，
      // 等价于断言隧道（SynoPunch 起不来，无法直接构造 TunnelTransport）。
      // 修复回退：把 synoToken 那行删掉 → 这条立刻红。
      final url = DirectTransport.authenticatedQueryUrl(
        'https://127.0.0.1:8443/webapi/entry.cgi',
        const {'api': 'SYNO.FileStation.Download', 'method': 'download'},
        sid: 'SID-T',
        synoToken: 'TOKEN-T',
      );
      expect(Uri.parse(url).queryParameters['_sid'], 'SID-T');
      expect(Uri.parse(url).queryParameters['SynoToken'], 'TOKEN-T');
      expect(url, startsWith('https://127.0.0.1:8443/webapi/entry.cgi?'));
    });
  });

  group('三条通道的直链都带完整查询串鉴权（承重：跑的是生产拼装）', () {
    Future<DsmWebApi> realApi() => _boot(_RealUrlTransport(const {}, _table));

    test('FileStation Download：_sid + SynoToken', () async {
      final api = await realApi();
      final src = resolveFileStationSource(
        displayName: 'song.mp3',
        kind: MediaKind.audio,
        fs: FileStationApi(api),
        path: '/home/song.mp3',
      );
      expect(src.playable, isTrue);
      expect(urlHasSid(src.uri), isTrue, reason: '缺 _sid 服务端回 119');
      expect(
        urlHasSynoToken(src.uri),
        isTrue,
        reason: '原生播放器发不了 X-SYNO-TOKEN，CSRF 必须在查询串里',
      );
    });

    test('Drive download：_sid + SynoToken', () async {
      final api = await realApi();
      final src = resolveDriveSource(
        displayName: 'song.mp3',
        kind: MediaKind.audio,
        fileId: '7788',
        drive: DriveApi(api),
      );
      expect(src.uri, isNotEmpty);
      expect(urlHasSid(src.uri), isTrue);
      expect(urlHasSynoToken(src.uri), isTrue);
    });

    test('Photos streaming：_sid + SynoToken', () async {
      final api = await realApi();
      final src = resolvePhotosSource(
        displayName: 'IMG_0001.MOV',
        kind: MediaKind.video,
        itemId: '9317',
        foto: FotoApi(api),
      );
      expect(src.playable, isTrue);
      expect(urlHasSid(src.uri), isTrue);
      expect(urlHasSynoToken(src.uri), isTrue);
    });

    test('falsification：隧道漏 SynoToken（修复前的行为）→ 拦成 sessionExpired', () async {
      final api = await _boot(_LegacyTunnelUrlTransport(const {}, _table));
      final src = resolveFileStationSource(
        displayName: 'clip-h264.mp4',
        kind: MediaKind.video,
        fs: FileStationApi(api),
        path: '/home/clip-h264.mp4',
      );
      // 关键：绝不把"有 _sid 但没 SynoToken"的 URL 交给 Media3（那会回 119，
      // 然后被误报成"编码不支持"）
      expect(src.playable, isFalse);
      expect(src.uri, isEmpty);
      expect(src.reason, MediaUnavailableReason.sessionExpired);
      expect(src.reason!.text, isNot(contains('编码')), reason: '不许再误报编码不支持');
    });

    test('会话过期（没有 _sid 的直链）→ sessionExpired，不是 codecUnsupported', () async {
      final api = await _boot(_NoSidUrlTransport(const {}, _table));
      final src = resolveFileStationSource(
        displayName: 'a.mp4',
        kind: MediaKind.video,
        fs: FileStationApi(api),
        path: '/home/a.mp4',
      );
      expect(src.playable, isFalse);
      expect(src.reason, MediaUnavailableReason.sessionExpired);
    });
  });

  group('URL 鉴权自检（纯函数）', () {
    test('urlHasSid / urlHasSynoToken 只认查询串里的**非空**值', () {
      expect(urlHasSid('https://n/w?api=x&_sid=S'), isTrue);
      expect(urlHasSid('https://n/w?api=x&_sid='), isFalse);
      expect(urlHasSid('https://n/w?api=x'), isFalse);
      expect(urlHasSid(''), isFalse);
      // 假阳性：`path` 参数的值里恰好有 `_sid=`——按查询串解析就不会误判
      expect(
        urlHasSid('https://n/w?path=${Uri.encodeQueryComponent('x_sid=y')}'),
        isFalse,
      );
      expect(urlHasSynoToken('https://n/w?SynoToken=T'), isTrue);
      expect(urlHasSynoToken('https://n/w?SynoToken='), isFalse);
    });
  });

  group('Drive path 约定', () {
    test('driveFileIdOf 只认 drive: 前缀', () {
      expect(driveFileIdOf('drive:12345'), '12345');
      expect(driveFileIdOf('/home/a.mp3'), isNull);
      expect(driveFileIdOf('drive:'), '');
    });
  });

  group('FileStation（主通道：实测支持 Range）', () {
    test('URL 在查询串里带 _sid + SynoToken，且标 supportsRange=true', () async {
      final api = await _api();
      final src = resolveFileStationSource(
        displayName: 'song.mp3',
        kind: MediaKind.audio,
        fs: FileStationApi(api),
        path: '/home/song.mp3',
      );
      expect(src.playable, isTrue);
      expect(src.seekable, isTrue, reason: '真机实测 206 → 进度条能拖');
      expect(src.fallbackReason, isNull);
      expect(src.uri, contains('api=SYNO.FileStation.Download'));
      expect(src.uri, contains('method=download'));
      expect(src.uri, contains('mode=download'));
      // 鉴权只在查询串（原生播放器不给自定义头）
      expect(src.uri, contains('_sid=FAKE-SID'));
      expect(src.uri, contains('SynoToken=FAKE-TOKEN'));
      // path 是 JSON 数组串
      expect(Uri.parse(src.uri).queryParameters['path'], '["/home/song.mp3"]');
      expect(src.headers, isNull, reason: '本项目通道不需要自定义头');
    });

    test('未连接（没有 FileStationApi）→ notConnected，不产生 URL', () {
      final src = resolveFileStationSource(
        displayName: 'song.mp3',
        kind: MediaKind.audio,
        fs: null,
        path: '/home/song.mp3',
      );
      expect(src.playable, isFalse);
      expect(src.reason, MediaUnavailableReason.notConnected);
      expect(src.uri, isEmpty);
    });

    test('通道给了空 URL → emptyUrl（绝不把空串塞给播放器）', () async {
      final api = await _boot(_EmptyUrlTransport(const {}, _table));
      final src = resolveFileStationSource(
        displayName: 'a.mp4',
        kind: MediaKind.video,
        fs: FileStationApi(api),
        path: '/home/a.mp4',
      );
      expect(src.playable, isFalse);
      expect(src.reason, MediaUnavailableReason.emptyUrl);
      expect(src.uri, isEmpty);
    });

    test('隧道传输（tcpPort == 0 → 空串）→ tunnelUnavailable', () async {
      final api = await _boot(_TunnelTransport(const {}, _table));
      final src = resolveFileStationSource(
        displayName: 'a.mp4',
        kind: MediaKind.video,
        fs: FileStationApi(api),
        path: '/home/a.mp4',
        tunnelTransport: true,
      );
      expect(src.reason, MediaUnavailableReason.tunnelUnavailable);
      expect(api.transport.describeKind, startsWith('tunnel('));
      expect(isTunnelTransport(api.transport.describeKind), isTrue);
      expect(isTunnelTransport('direct(https://nas:5001/)'), isFalse);
    });

    test('自签证书被固定 → certificateUntrusted（Media3 走系统信任链必失败）', () async {
      final api = await _api();
      final src = resolveFileStationSource(
        displayName: 'a.mp4',
        kind: MediaKind.video,
        fs: FileStationApi(api),
        path: '/home/a.mp4',
        certPinned: true,
      );
      expect(src.playable, isFalse);
      expect(src.reason, MediaUnavailableReason.certificateUntrusted);
    });
  });

  group('Drive（写死 Accept-Ranges: none）', () {
    test('自己有 DriveApi 时能拼出直链（files=["id:…"]）', () async {
      final api = await _api();
      final src = resolveDriveSource(
        displayName: 'clip.mp4',
        kind: MediaKind.video,
        fileId: '7788',
        drive: DriveApi(api),
      );
      expect(src.uri, contains('api=SYNO.SynologyDrive.Files'));
      expect(src.uri, contains('method=download'));
      expect(src.uri, contains('_sid=FAKE-SID'));
      expect(src.uri, contains('SynoToken=FAKE-TOKEN'));
      expect(Uri.parse(src.uri).queryParameters['files'], '["id:7788"]');
    });

    test('视频：supportsRange=false → 不内嵌（从头顺序缓冲 ≡ 不能拖）', () async {
      final api = await _api();
      final src = resolveDriveSource(
        displayName: 'clip.mp4',
        kind: MediaKind.video,
        fileId: '7788',
        drive: DriveApi(api),
      );
      expect(src.supportsRange, isFalse);
      expect(src.playable, isFalse);
      expect(src.fallbackReason, MediaUnavailableReason.rangeUnsupported);
    });

    test('音频：仍能播，但滑块必须置灰（streamingOnly）', () async {
      final api = await _api();
      final src = resolveDriveSource(
        displayName: 'song.mp3',
        kind: MediaKind.audio,
        fileId: '7788',
        drive: DriveApi(api),
      );
      expect(src.playable, isTrue, reason: '能听');
      expect(src.seekable, isFalse, reason: '拖不动（服务端不给 206）');
      expect(src.streamingOnly, isTrue);
      expect(src.uri, isNotEmpty);
    });

    test('调用方已拼好的直链优先（file_id 为空也能用）', () async {
      final api = await _api();
      final src = resolveDriveSource(
        displayName: 'clip.mp4',
        kind: MediaKind.video,
        url: '${api.baseUrl}webapi/entry.cgi?api=SYNO.SynologyDrive.Files',
      );
      expect(src.uri, contains('SYNO.SynologyDrive.Files'));
      expect(src.fallbackReason, MediaUnavailableReason.rangeUnsupported);
    });

    test('什么都没有 → notConnected', () {
      final src = resolveDriveSource(
        displayName: 'clip.mp4',
        kind: MediaKind.video,
      );
      expect(src.reason, MediaUnavailableReason.notConnected);
    });
  });

  group('Photos（Download 优先 + Streaming 回退）', () {
    test('个人空间：主通道 = SYNO.Foto.Download + item_id（官方 u9 的 Item 形态）', () async {
      final api = await _api();
      final src = resolvePhotosSource(
        displayName: 'IMG_0001.MOV',
        kind: MediaKind.video,
        itemId: '9317',
        foto: FotoApi(api),
      );
      // ① 主通道是官方对"原生 mp4/h264"（`quality="raw"`）实际使用的 Download：
      //    `u9`（react_bundle.js 偏移 2544763）对 Item 种类发 `item_id=[id]`。
      expect(src.uri, contains('api=SYNO.Foto.Download'));
      expect(src.uri, contains('method=download'));
      expect(
        Uri.parse(src.uri).queryParameters['item_id'],
        '[9317]',
        reason: '官方 u9：type===Zk.Item ? {item_id:[id]} : {unit_id:[id]}',
      );
      expect(
        Uri.parse(src.uri).queryParameters.keys,
        isNot(contains('unit_id')),
        reason: 'item id 不许塞进 unit_id（官方证据是 item_id）',
      );
      // 版本走协商：本机 [设备表] Download 是 minVersion 1 / maxVersion 2 → v2
      expect(Uri.parse(src.uri).queryParameters['version'], '2');
      // 鉴权**只在查询串**里（原生播放器只吃 URL，不需要任何自定义头）
      expect(Uri.parse(src.uri).queryParameters['_sid'], 'FAKE-SID');
      expect(Uri.parse(src.uri).queryParameters['SynoToken'], 'FAKE-TOKEN');
      expect(src.channel, MediaChannel.photos);

      // ② 回退是 Streaming（转码档兜底）：`type=item` 必填、不猜 `quality`、
      //    不带 `use_mov`（非 iOS），id 是裸 id。
      final fb = src.fallback;
      expect(fb, isNotNull, reason: 'Download 失败必须能回退 Streaming');
      expect(fb!.uri, contains('api=SYNO.Foto.Streaming'));
      expect(fb.uri, contains('method=streaming'));
      expect(
        fb.uri,
        isNot(contains('method=stream&')),
        reason: '`stream` 是错的（原来是这个），必须是 `streaming`',
      );
      expect(Uri.parse(fb.uri).queryParameters['method'], 'streaming');
      expect(Uri.parse(fb.uri).queryParameters['id'], '9317');
      final fbParams = Uri.parse(fb.uri).queryParameters;
      expect(fbParams['type'], 'item', reason: '官方 `U` 每次都带 type');
      expect(fbParams.keys, isNot(contains('use_mov')), reason: 'Android 不带');
      expect(fbParams.keys, isNot(contains('quality')), reason: '不猜转码档');
      expect(fbParams['_sid'], 'FAKE-SID');
      expect(fbParams['SynoToken'], 'FAKE-TOKEN');
      // Range 语义**按通道分别标注**（真机只证了 Download）：
      //   * Download 腿（主源）：206 + Content-Range 已证 → true（可拖/可定位）；
      //   * Streaming 腿（回退）：零字节、未取证 → 恒 false。
      expect(
        src.supportsRange,
        isTrue,
        reason: 'Download：2026-09-22 真机 206 + Content-Range（live-nas §4.3）',
      );
      expect(
        fb.supportsRange,
        isFalse,
        reason: 'Streaming：必填 quality 未解、零字节 → 未取证，不许跟着 true',
      );
    });

    test('URL 形态与官方证据逐字一致（type/quality 都按官方 `U`）', () async {
      final api = await _api();
      final foto = FotoApi(api);
      // 官方 `U(e)`：`{id, type, quality}` + 可选 `album_id`/`passphrase`；
      // 这里钉死我们可以构造出的那一部分（本仓库还没有 album_id/passphrase 需求）。
      final plain = Uri.parse(foto.streamingUrl(itemId: '9317'));
      expect(plain.queryParameters['api'], 'SYNO.Foto.Streaming');
      expect(plain.queryParameters['version'], '2');
      expect(plain.queryParameters['method'], 'streaming');
      expect(plain.queryParameters['id'], '9317');
      expect(plain.queryParameters['type'], 'item');
      expect(plain.queryParameters.keys, isNot(contains('quality')));

      // 需要"服务端转码产物"时按白名单档位显式给 `quality`（官方只给**存在的**
      // 档位；照着白名单给值时形态才与官方 `U` 一致）。
      final converted = Uri.parse(
        foto.streamingUrl(
          itemId: '9317',
          type: kFotoStreamingTypeUnit,
          quality: 'orig_h264',
        ),
      );
      expect(converted.queryParameters['type'], 'unit');
      expect(converted.queryParameters['quality'], 'orig_h264');
      expect(kFotoStreamingQualities, contains('orig_h264'));
      expect(kFotoStreamingQualities, contains('convert_mp4'));
      // 白名单逐字来自 `SYNO.Foto.Streaming.so` 的 rodata（不许凭记忆加值）
      expect(kFotoStreamingQualities, hasLength(11));
    });

    test('Photos 直链缺 SynoToken → 拦成 sessionExpired，不进播放器', () async {
      // 用 `_LegacyTunnelUrlTransport`：`synoToken` 有值（媒体层因此知道"这条
      // URL **必须**带令牌"），但 `authenticatedUrl` 返回的串里**没有** `SynoToken`
      //（= DSM 7.4 上的典型取流缺陷；服务端回 119，Media3 把 JSON 119 当"没有
      // extractor 能读的流"→ 误报"编码不支持"）。媒体层必须**在进播放器前**
      // 拦下来，并且既不是 codecUnsupported 也不是 streamRejected。
      final api = await _boot(_LegacyTunnelUrlTransport(const {}, _table));
      final src = resolvePhotosSource(
        displayName: 'clip-h264.mp4',
        kind: MediaKind.video,
        itemId: '9317',
        foto: FotoApi(api),
      );
      expect(src.playable, isFalse);
      expect(src.uri, isEmpty);
      expect(src.reason, MediaUnavailableReason.sessionExpired);
      expect(src.reason, isNot(MediaUnavailableReason.codecUnsupported));
      expect(src.reason, isNot(MediaUnavailableReason.streamRejected));
    });

    test('共享空间：Download 与回退的 Streaming 都换 SYNO.FotoTeam.*', () async {
      final api = await _api();
      final src = resolvePhotosSource(
        displayName: 'IMG_0001.MOV',
        kind: MediaKind.video,
        itemId: '42',
        foto: FotoApi(api),
        team: true,
      );
      expect(src.uri, contains('api=SYNO.FotoTeam.Download'));
      expect(src.fallback?.uri, contains('api=SYNO.FotoTeam.Streaming'));
      expect(src.channel, MediaChannel.photosTeam);
    });

    test('Range 真机已证（Download 206）→ 视频内嵌且可 seek；Streaming 腿仍 false', () async {
      final api = await _api();
      final video = resolvePhotosSource(
        displayName: 'a.mov',
        kind: MediaKind.video,
        itemId: '1',
        foto: FotoApi(api),
      );
      // 2026-09-22 真机：`Download:download` + `Range: bytes=0-1023` →
      // `206` + `Content-Range: bytes 0-1023/1876693`（docs/live-nas-verification.md
      // §4.3）→ 主源 supportsRange 默认 true：滑块可用、可定位。
      expect(video.supportsRange, isTrue);
      expect(video.fallbackReason, isNull);
      expect(video.playable, isTrue);
      expect(video.seekable, isTrue);
      expect(video.streamingOnly, isFalse);
      // 但回退的 Streaming 腿**未取证**（必填 quality 未解、零字节）→ 仍置灰
      expect(video.fallback, isNotNull);
      expect(video.fallback!.supportsRange, isFalse);
      expect(video.fallback!.streamingOnly, isTrue);

      // 音频同理：主源（Download）也能拖
      final audio = resolvePhotosSource(
        displayName: 'a.m4a',
        kind: MediaKind.audio,
        itemId: '1',
        foto: FotoApi(api),
      );
      expect(audio.playable, isTrue);
      expect(audio.seekable, isTrue);
    });

    test('对照（falsification 口）：downloadRangeProven=false → 退回不可拖', () async {
      // 这条只是"证据开关还在"的对照：把它关掉必须回到旧行为。
      // 生产默认值是 true（真机证据），见上一条。
      final api = await _api();
      final src = resolvePhotosSource(
        displayName: 'a.mov',
        kind: MediaKind.video,
        itemId: '1',
        foto: FotoApi(api),
        downloadRangeProven: false,
      );
      expect(src.supportsRange, isFalse);
      expect(src.seekable, isFalse);
      expect(src.streamingOnly, isTrue);
      expect(src.fallbackReason, isNull);
      // Streaming 腿**不受这个开关影响**：永远 false（未取证）
      expect(src.fallback!.supportsRange, isFalse);
    });

    test('相册 Download 腿（可 seek）**已接 renewer** → 能原地续期续播', () async {
      // Download 腿 Range 真机已证 → 可 seek；W1-1 起接上"轻量鉴权 ping
      // （`Browse.Item/get`）+ 用新 `_sid` 重拼直链"的 renewer →
      // `shouldRenewSession` 为真（会话失效时原地续播，不回面板）。
      final api = await _api();
      final src = resolvePhotosSource(
        displayName: 'a.mov',
        kind: MediaKind.video,
        itemId: '1',
        foto: FotoApi(api),
      );
      expect(src.supportsRange, isTrue, reason: '可 seek');
      expect(src.renew, isNotNull, reason: '可 seek 的 Download 腿必须能续期');
      expect(
        shouldRenewSession(src, MediaUnavailableReason.sessionExpired),
        isTrue,
        reason: '会话失效 → 能原地续播',
      );
      // 网络中断仍然不续期（复用同一判定）
      expect(
        shouldRenewSession(src, MediaUnavailableReason.networkFailed),
        isFalse,
      );
      // Streaming 腿（不可 seek）**不接** renewer：不能 seek 就没有原位置可回
      final streaming = resolvePhotosSource(
        displayName: 'a.mov',
        kind: MediaKind.video,
        itemId: '1',
        foto: FotoApi(api),
        streamingPrimary: true,
        streamingQuality: 'high',
      );
      expect(streaming.supportsRange, isFalse, reason: 'Streaming 腿 Range 未取证');
      expect(streaming.renew, isNull, reason: '不可 seek → 不接 renewer');
      expect(
        shouldRenewSession(streaming, MediaUnavailableReason.sessionExpired),
        isFalse,
      );
    });

    test('证书固定 → certificateUntrusted（自签证书 Media3 握手必失败）', () async {
      final api = await _api();
      expect(
        resolvePhotosSource(
          displayName: 'a.mov',
          kind: MediaKind.video,
          itemId: '1',
          foto: FotoApi(api),
          certPinned: true,
        ).reason,
        MediaUnavailableReason.certificateUntrusted,
      );
    });

    test('隧道 tcpPort==0（URL 空串）→ tunnelUnavailable，不是笼统 emptyUrl', () async {
      final api = await _boot(_TunnelTransport(const {}, _table));
      final src = resolvePhotosSource(
        displayName: 'a.mov',
        kind: MediaKind.video,
        itemId: '1',
        foto: FotoApi(api),
        tunnelTransport: true,
      );
      expect(src.uri, isEmpty);
      expect(src.reason, MediaUnavailableReason.tunnelUnavailable);
    });

    test(
      '没有 FotoApi → notConnected；有 API 但 unitId 空 → unsupportedSource',
      () async {
        expect(
          resolvePhotosSource(
            displayName: 'a.mov',
            kind: MediaKind.video,
            itemId: '1',
          ).reason,
          MediaUnavailableReason.notConnected,
        );
        final api = await _api();
        expect(
          resolvePhotosSource(
            displayName: 'a.mov',
            kind: MediaKind.video,
            itemId: '',
            foto: FotoApi(api),
          ).reason,
          MediaUnavailableReason.unsupportedSource,
        );
      },
    );
  });

  group('预览页统一入口（按来源分流）', () {
    test('FileStation 条目 → 走 Download 直链，可拖', () async {
      final api = await _api();
      final src = resolveEntryMediaSource(
        entry: _entry('song.mp3'),
        kind: MediaKind.audio,
        fs: FileStationApi(api),
      );
      expect(src.channel, MediaChannel.fileStation);
      expect(src.seekable, isTrue);
    });

    test('drive: 条目 → Drive 通道（视频降级、音频能播不能拖）', () async {
      final api = await _api();
      final url = DriveApi(api).downloadUrl(fileId: '5');
      final video = resolveEntryMediaSource(
        entry: _entry('clip.mp4', path: 'drive:5'),
        kind: MediaKind.video,
        drive: DriveApi(api),
        bytesUrl: url,
      );
      expect(video.channel, MediaChannel.drive);
      expect(video.fallbackReason, MediaUnavailableReason.rangeUnsupported);
      final audio = resolveEntryMediaSource(
        entry: _entry('song.mp3', path: 'drive:5'),
        kind: MediaKind.audio,
        drive: DriveApi(api),
        bytesUrl: url,
      );
      expect(audio.channel, MediaChannel.drive);
      expect(audio.streamingOnly, isTrue);
    });

    test('非 FileStation 来源给了直链 → other（Range 未知，不假装能拖）', () {
      final src = resolveEntryMediaSource(
        entry: _entry('a.mp4'),
        kind: MediaKind.video,
        bytesUrl: 'https://nas/webapi/entry.cgi?api=SYNO.Chat.Post.File',
      );
      expect(src.channel, MediaChannel.other);
      expect(src.supportsRange, isFalse);
      expect(src.uri, contains('SYNO.Chat.Post.File'));
    });

    test('聊天附件视频 → other + rangeUnsupported（未证实 Range）', () {
      final src = resolveOtherSource(
        displayName: 'a.mp4',
        kind: MediaKind.video,
        url: 'https://nas/webapi/entry.cgi?api=SYNO.Chat.Post.File',
      );
      expect(src.channel, MediaChannel.chat);
      expect(src.fallbackReason, MediaUnavailableReason.rangeUnsupported);
    });
  });

  group('失败原因是枚举（不是字符串）', () {
    test('每个原因都有稳定 code + 既有 ARB key + 中文回落', () {
      final codes = <String>{};
      for (final r in MediaUnavailableReason.values) {
        expect(r.code, isNotEmpty);
        expect(r.arbKey, isNotEmpty);
        expect(r.zh, isNotEmpty);
        // 没装数据层翻译器 → 回落中文原文
        expect(r.text, r.zh);
        codes.add(r.code);
      }
      expect(codes, hasLength(MediaUnavailableReason.values.length));
    });
  });

  // ───────────────── R7-13-B：会话语义复核 + 通道回退判定（纯逻辑） ──────
  group('会话复核与会话/回退判定（R7-13-B / R7 P0）', () {
    test('probeMediaSessionCode：JSON 信封里的 119/106 被还原，其余一律 null', () async {
      Future<int?> probe(Object error) => probeMediaSessionCode(
        'https://nas/webapi/entry.cgi?api=SYNO.FileStation.Download',
        (url, {int? maxBytes}) async => throw error,
      );
      expect(await probe(DsmApiException(119)), 119);
      expect(await probe(DsmApiException(106)), 106);
      expect(
        await probe(DsmApiException(105)),
        105,
        reason: '原样返回，由 isMediaSessionCode 判定',
      );
      // 真媒体字节（没抛）→ null
      expect(
        await probeMediaSessionCode(
          'https://nas/x',
          (url, {int? maxBytes}) async => const [0, 0, 0, 24],
        ),
        isNull,
      );
      // 网络层异常 → null（不篡改既有分类）
      expect(
        await probeMediaSessionCode(
          'https://nas/x',
          (url, {int? maxBytes}) async => throw StateError('boom'),
        ),
        isNull,
      );
    });

    test('isMediaSessionCode 只认 119/106', () {
      expect(isMediaSessionCode(DsmErrorCode.sidNotFound), isTrue);
      expect(isMediaSessionCode(DsmErrorCode.sessionTimeout), isTrue);
      expect(isMediaSessionCode(105), isFalse);
      expect(isMediaSessionCode(0), isFalse);
      expect(isMediaSessionCode(null), isFalse);
    });

    test('shouldTryFallbackSource：会话/网络两类不换通道，其余换', () {
      MediaSource src({MediaSource? fallback}) => MediaSource(
        uri:
            'https://nas/webapi/entry.cgi?api=SYNO.Foto.Streaming&id=1&type=item',
        channel: MediaChannel.photos,
        kind: MediaKind.video,
        displayName: 'clip.mp4',
        fallback: fallback,
      );
      final withFallback = src(fallback: src());
      expect(
        shouldTryFallbackSource(
          withFallback,
          MediaUnavailableReason.streamRejected,
        ),
        isTrue,
      );
      expect(
        shouldTryFallbackSource(
          withFallback,
          MediaUnavailableReason.codecUnsupported,
        ),
        isTrue,
      );
      expect(
        shouldTryFallbackSource(
          withFallback,
          MediaUnavailableReason.sessionExpired,
        ),
        isFalse,
        reason: '会话层先走自动续期；相册没有 renewer 时换通道也是同一个会话错误',
      );
      expect(
        shouldTryFallbackSource(
          withFallback,
          MediaUnavailableReason.networkFailed,
        ),
        isFalse,
        reason: 'TCP/DNS 层换 URL 不会更好',
      );
      expect(
        shouldTryFallbackSource(src(), MediaUnavailableReason.streamRejected),
        isFalse,
        reason: '没有下一跳就不许空转',
      );
    });

    test('生产拼装：FileStation/Drive/相册都把会话复核接出来', () async {
      final api = await _boot(_RealUrlTransport(const {}, _table));
      final fs = resolveFileStationSource(
        displayName: 'v.mp4',
        kind: MediaKind.video,
        fs: FileStationApi(api),
        path: '/home/v.mp4',
      );
      expect(fs.playable, isTrue);
      expect(
        fs.probeSessionCode,
        isNotNull,
        reason: 'R7-13-B：119 藏在 JSON 信封里，必须能复核应答体',
      );
      expect(fs.renew, isNotNull, reason: 'FileStation 有续期能力');

      final photo = resolvePhotosSource(
        displayName: 'clip.mp4',
        kind: MediaKind.video,
        itemId: '9317',
        foto: FotoApi(api),
      );
      expect(photo.fallback, isNotNull, reason: '相册两跳：Download → Streaming');
      expect(
        photo.probeSessionCode,
        isNotNull,
        reason: '相册同样要能还原 119（只是没有 renewer，先回退再面板）',
      );
    });
  });
}
