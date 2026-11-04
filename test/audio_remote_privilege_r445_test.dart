// r445：远程播放器页的**服务端原因态**（`DA99`）。
//
// 缺陷：`RemotePlayer.list` 在两种**与服务端画像有关**的情形下返回 `{"players": []}` ——
//   ① `settings.disable_upnp == true`（NAS 侧那颗 UPnP/DLNA 总开关关着）；
//   ② `privilege.remote_player == false`（本账号没有 Audio Station 远程播放权限）。
// 修前这两种都和"NAS 上真的没有设备"共用同一句空态文案
// （`asRemoteEmptyHint`：`NAS 没有发现可控制的播放设备…`）⇒ 用户照着提示去开电视
// 永远修不好（仪器138：服务端不给的原因必须自己给）。
//
// 事实来源（本轮真 NAS 取证，见 `docs/android-ui-audit-r445.md` §S3）：
//   * `SYNO.AudioStation.Info/getinfo` **v2+** 才返回整张画像
//     （v1 只有 `{path, version}` —— 真机逐版实测）；
//   * 官方 Web 前端在 `!settings.disable_upnp && privilege.upnp_browse` 之外
//     不显示 DLNA 入口（`AudioStation-7.2.1-6006` 包 `app/audio-common.js`）；
//   * 本轮把一台自造 DLNA MediaRenderer 挂进同一 /24，NAS 侧发现链路全通
//     （SSDP/设备描述/SCPD/SUBSCRIBE＋初始事件/`GetProtocolInfo`），
//     而 `demo_user`（`privilege.remote_player=false`）的 `list` 仍是空。
//
// 四组判据：① 画像三态解析（缺键 = 不知道 ≠ false）② `remotePlayerDenial` 真值表
// ③ 页面三态（无权限 / 服务端关 UPnP / 真·没设备）④ 反向：画像说"有权限"时不许乱报原因。
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:synhub/src/core/theme/app_theme.dart';
import 'package:synhub/src/data/audio_station.dart';
import 'package:synhub/src/data/dto/audio_station_dto.dart';
import 'package:synhub/src/dsm/webapi.dart';
import 'package:synhub/src/features/audio/audio_player.dart';
import 'package:synhub/src/features/audio/audio_providers.dart';
import 'package:synhub/src/features/audio/audio_remote_page.dart';

import 'support/chat_harness.dart' show FakeTransport;

const _as = 'SYNO.AudioStation';

const _asTable = {
  'SYNO.API.Info': {'path': 'query.cgi', 'minVersion': 1, 'maxVersion': 1},
  '$_as.RemotePlayer': {
    'path': 'AudioStation/remote_player.cgi',
    'minVersion': 1,
    'maxVersion': 3,
  },
  '$_as.Info': {
    'path': 'AudioStation/info.cgi',
    'minVersion': 1,
    'maxVersion': 6,
  },
};

/// 只给远程播放器页需要的两只 provider；`Info.getinfo` 的响应由用例给。
Future<void> _pump(
  WidgetTester tester, {
  Map<String, Map<String, dynamic>> responses = const {},
}) async {
  final t = FakeTransport(responses, {...FakeTransport.table, ..._asTable});
  final web = DsmWebApi(t);
  await web.discover();
  await web.login(account: 'a', password: 'b');
  final c = ProviderContainer(
    overrides: [
      audioApiProvider.overrideWithValue(AudioStationApi(web)),
      audioStationPlayerProvider.overrideWithValue(_NullPlayer()),
    ].cast(),
  );
  addTearDown(c.dispose);
  tester.view.physicalSize = const Size(800, 1400);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: c,
      child: MaterialApp(theme: AppTheme.dark(), home: const AudioRemotePage()),
    ),
  );
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 300));
  await tester.pump(const Duration(milliseconds: 300));
}

/// 不播放任何东西的播放器（断言都在空态/原因态上；列表态只验渲染）。
class _NullPlayer implements AudioStationPlayer {
  @override
  String? get currentUrl => null;
  @override
  bool get playing => false;
  @override
  int get currentIndex => -1;
  @override
  int get queueLength => 0;
  @override
  List<AudioQueueEntry> get queue => const [];
  @override
  bool get shuffleEnabled => false;
  @override
  AudioRepeatMode get repeatMode => AudioRepeatMode.off;
  @override
  Duration get position => Duration.zero;
  @override
  Duration? get duration => null;
  @override
  Stream<void> get changes => const Stream<void>.empty();
  @override
  Stream<Duration> get positionStream => const Stream<Duration>.empty();
  @override
  Stream<Duration?> get durationStream => const Stream<Duration?>.empty();
  @override
  Future<void> play(String url) async {}
  @override
  Future<void> playQueue(List<AudioQueueEntry> entries, {int startIndex = 0}) async {}
  @override
  Future<void> pause() async {}
  @override
  Future<void> resume() async {}
  @override
  Future<void> stop() async {}
  @override
  Future<void> next() async {}
  @override
  Future<void> previous() async {}
  @override
  Future<void> seek(Duration position) async {}
  @override
  Future<void> setShuffle(bool enabled) async {}
  @override
  Future<void> setRepeat(AudioRepeatMode mode) async {}
}

AudioInfoDto _info({bool? remotePlayer, bool? disableUpnp}) => AudioInfoDto(
  remotePlayerPrivilege: remotePlayer,
  disableUpnp: disableUpnp,
);

void main() {
  // ---------------------------------------------------- ① 画像三态
  group('DA99 ①：画像三态（缺键 = 不知道 ≠ false）', () {
    test('privilege.remote_player 给了 false/true ⇒ 如实转成 false/true', () {
      expect(
        AudioInfoDto.fromJson(const {
          'privilege': {'remote_player': false},
        }).remotePlayerPrivilege,
        isFalse,
      );
      expect(
        AudioInfoDto.fromJson(const {
          'privilege': {'remote_player': true},
        }).remotePlayerPrivilege,
        isTrue,
      );
    });

    test('privilege 里没有 remote_player 键 ⇒ null（不许当成"没权限"）', () {
      expect(
        AudioInfoDto.fromJson(const {
          'privilege': {'upnp_browse': false},
        }).remotePlayerPrivilege,
        isNull,
      );
      expect(AudioInfoDto.fromJson(const {}).remotePlayerPrivilege, isNull);
    });

    test('settings.disable_upnp 同款三态', () {
      expect(
        AudioInfoDto.fromJson(const {
          'settings': {'disable_upnp': true},
        }).disableUpnp,
        isTrue,
      );
      expect(
        AudioInfoDto.fromJson(const {
          'settings': {'enable_download': true},
        }).disableUpnp,
        isNull,
      );
    });

    test('真机画像逐字（demo_user / AS 7.2.1-6006）：remote_player=false、disable_upnp=false', () {
      final dto = AudioInfoDto.fromJson(const {
        'privilege': {
          'playlist_edit': false,
          'remote_player': false,
          'sharing': false,
          'tag_edit': false,
          'upnp_browse': false,
        },
        'settings': {
          'audio_show_virtual_library': true,
          'disable_upnp': false,
          'enable_download': false,
          'prefer_using_html5': true,
          'transcode_to_mp3': true,
        },
      });
      expect(dto.remotePlayerPrivilege, isFalse);
      expect(dto.disableUpnp, isFalse);
    });
  });

  // ---------------------------------------------------- ② 真值表
  group('DA99 ②：remotePlayerDenial 真值表', () {
    test('画像缺失 ⇒ 不下结论（null）', () {
      expect(remotePlayerDenial(null), isNull);
      expect(remotePlayerDenial(const AudioInfoDto()), isNull);
    });

    test('disable_upnp 优先于 remote_player（服务端总开关是最外层原因）', () {
      expect(
        remotePlayerDenial(_info(remotePlayer: false, disableUpnp: true)),
        RemotePlayerDenial.upnpDisabled,
      );
    });

    test('remote_player=false ⇒ noPrivilege；=true ⇒ 不是原因', () {
      expect(
        remotePlayerDenial(_info(remotePlayer: false, disableUpnp: false)),
        RemotePlayerDenial.noPrivilege,
      );
      expect(
        remotePlayerDenial(_info(remotePlayer: true, disableUpnp: false)),
        isNull,
      );
    });
  });

  // ---------------------------------------------------- ③④ 页面
  group('DA99 ③④：页面三态 + 反向', () {
    testWidgets('③ noPrivilege：remote_player=false ⇒ 说"没有权限"，不再说"NAS 上没设备"', (
      tester,
    ) async {
      await _pump(
        tester,
        responses: {
          '$_as.RemotePlayer.list': const {'players': []},
          '$_as.Info.getinfo': const {
            'privilege': {'remote_player': false, 'upnp_browse': false},
            'settings': {'disable_upnp': false},
          },
        },
      );
      expect(find.byKey(const Key('as-remote-no-privilege')), findsOneWidget);
      expect(find.text('此账号没有远程播放权限'), findsOneWidget);
      expect(
        find.byKey(const Key('as-remote-empty')),
        findsNothing,
        reason: '授权原因不许再说成"NAS 没有发现设备"',
      );
    });

    testWidgets('③ upnpDisabled：settings.disable_upnp=true ⇒ 说服务端关了 DLNA', (tester) async {
      await _pump(
        tester,
        responses: {
          '$_as.RemotePlayer.list': const {'players': []},
          '$_as.Info.getinfo': const {
            'privilege': {'remote_player': true, 'upnp_browse': true},
            'settings': {'disable_upnp': true},
          },
        },
      );
      expect(find.byKey(const Key('as-remote-upnp-disabled')), findsOneWidget);
      expect(find.byKey(const Key('as-remote-no-privilege')), findsNothing);
      expect(find.byKey(const Key('as-remote-empty')), findsNothing);
    });

    testWidgets('③ 真·没设备（有权限、UPnP 开着）⇒ 保持原空态', (tester) async {
      await _pump(
        tester,
        responses: {
          '$_as.RemotePlayer.list': const {'players': []},
          '$_as.Info.getinfo': const {
            'privilege': {'remote_player': true, 'upnp_browse': true},
            'settings': {'disable_upnp': false},
          },
        },
      );
      expect(find.byKey(const Key('as-remote-empty')), findsOneWidget);
      expect(find.text('没有发现远程播放器'), findsOneWidget);
      expect(find.byKey(const Key('as-remote-no-privilege')), findsNothing);
      expect(find.byKey(const Key('as-remote-upnp-disabled')), findsNothing);
    });

    testWidgets('④ 反向：画像缺键（老固件 / 只回 path+version）⇒ 不许乱报原因', (tester) async {
      await _pump(
        tester,
        responses: {
          '$_as.RemotePlayer.list': const {'players': []},
          // v1 形态：真机实测只有 path/version（没有 privilege/settings）
          '$_as.Info.getinfo': const {
            'path': '/webman/3rdparty/AudioStation',
            'version': {'major': '7', 'minor': '2', 'build': '6006'},
          },
        },
      );
      expect(find.byKey(const Key('as-remote-empty')), findsOneWidget);
      expect(find.byKey(const Key('as-remote-no-privilege')), findsNothing);
      expect(find.byKey(const Key('as-remote-upnp-disabled')), findsNothing);
    });

    testWidgets('④ 反向：有权限且有设备 ⇒ 照旧出列表（原因态不许吞掉正常路径）', (tester) async {
      await _pump(
        tester,
        responses: {
          '$_as.RemotePlayer.list': const {
            'players': [
              {'id': 'p1', 'name': 'Living Room TV', 'type': 'upnp'},
            ],
          },
          '$_as.Info.getinfo': const {
            'privilege': {'remote_player': true, 'upnp_browse': true},
            'settings': {'disable_upnp': false},
          },
        },
      );
      expect(find.byKey(const Key('as-remote-list')), findsOneWidget);
      expect(find.text('Living Room TV'), findsOneWidget);
      expect(find.text('DLNA / UPnP'), findsOneWidget);
      expect(find.byKey(const Key('as-remote-no-privilege')), findsNothing);
    });
  });
}
