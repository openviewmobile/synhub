// ★ r699：Linux 的 **MPRIS**（`org.mpris.MediaPlayer2`）—— 媒体键与系统媒体面板。
//
// 为什么要有这个（`DA339` 的背景）：
//   * `audio_service` 在 Linux 上**没有**平台实现，`AudioService.init` 失败后被
//     try/catch 降级 ⇒ 安卓/iOS/macOS 有的「系统媒体卡 + 蓝牙/键盘媒体键」在
//     Linux 上是**没有**的（降级不崩 ≠ 功能存在）；
//   * Linux 桌面（GNOME/KDE/各家的 media-keys 守护）调媒体键的唯一公共契约就是
//     D-Bus 上的 `org.mpris.MediaPlayer2`：它读 `PlaybackStatus`/`Metadata`，
//     调 `PlayPause`/`Next`/`Previous`/`Seek`；
//   * 所以这里**自己实现**那套接口（`dbus` 包，纯 Dart，不需要额外 apt 依赖），
//     把系统来的调用接到 App 自己的播放器上 —— 单向：系统 → 我们。
//
// 三条纪律：
//   ① **失败一律降级，不许崩**：没有会话总线 / 名字被别人占了 / 接口注册失败 ⇒
//      返回 `null`，App 照常播放（与 `audio_service` 降级同一个姿势）；
//   ② **不摆假控件**：`Volume`/`Rate` 只读（面板上拖不动就拖不动，我们不去
//      假装接受），`CanControl` 等能力位由**当前真实状态**算出来；
//   ③ **元数据要带身份**：`mpris:trackid` 用曲目 id（不是"正在播放"这种话），
//      `mpris:length` 只在**知道**时长时给，不知道就不给（`null` ≠ 0）。
import 'dart:async';

import 'package:dbus/dbus.dart';
import 'package:flutter/foundation.dart';

/// 系统侧能调到的动作（全部可选：没有接的那路就不动）。
class MprisCallbacks {
  const MprisCallbacks({
    this.play,
    this.pause,
    this.next,
    this.previous,
    this.stop,
    this.seek,
  });

  final Future<void> Function()? play;
  final Future<void> Function()? pause;
  final Future<void> Function()? next;
  final Future<void> Function()? previous;
  final Future<void> Function()? stop;
  final Future<void> Function(Duration position)? seek;
}

/// 往 MPRIS 上推的一份**快照**（每次播放状态变化推一次）。
@immutable
class MprisPlaybackSnapshot {
  const MprisPlaybackSnapshot({
    required this.stopped,
    required this.playing,
    this.trackId,
    this.title,
    this.artist,
    this.album,
    this.artUrl,
    this.duration,
    this.position,
    this.canNext = false,
    this.canPrevious = false,
  });

  /// 「没有在播的东西」（队列空 / 已 stop）：`PlaybackStatus=Stopped`。
  final bool stopped;
  final bool playing;
  final String? trackId;
  final String? title;
  final String? artist;
  final String? album;

  /// `file://…` 封面（系统媒体面板显示用）。
  final String? artUrl;
  final Duration? duration;

  /// 未知位置就传 null（**不**用 `Duration.zero` 冒充）。
  final Duration? position;
  final bool canNext;
  final bool canPrevious;

  String get playbackStatus {
    if (stopped) return 'Stopped';
    return playing ? 'Playing' : 'Paused';
  }
}

/// `Metadata` 的编码（**纯函数**，与 D-Bus 会话无关 ⇒ 用例可离线断言）。
///
/// 三条判据：
/// ① `mpris:trackid` 必须是 **object path**（曲目 id 里的非法字符换成 `_`）；
/// ② 时长**不知道就不给**（`mpris:length` 缺失 ≠ 0）；
/// ③ `xesam:artist` 是**数组**（MPRIS 规定），空字符串不写。
DBusValue mprisMetadataOf(MprisPlaybackSnapshot s) {
  final m = <String, DBusValue>{};
  final id = (s.trackId ?? '').replaceAll(RegExp(r'[^A-Za-z0-9_]'), '_');
  m['mpris:trackid'] = DBusObjectPath(
    '/org/mpris/MediaPlayer2/Track/${id.isEmpty ? 'none' : id}',
  );
  if (s.title != null && s.title!.isNotEmpty) {
    m['xesam:title'] = DBusString(s.title!);
  }
  if (s.artist != null && s.artist!.isNotEmpty) {
    m['xesam:artist'] = DBusArray.string([s.artist!]);
  }
  if (s.album != null && s.album!.isNotEmpty) {
    m['xesam:album'] = DBusString(s.album!);
  }
  if (s.artUrl != null && s.artUrl!.isNotEmpty) {
    m['mpris:artUrl'] = DBusString(s.artUrl!);
  }
  final length = s.duration;
  if (length != null) {
    m['mpris:length'] = DBusInt64(length.inMicroseconds);
  }
  return DBusDict.stringVariant(m);
}

/// Linux MPRIS 服务。`start()` 拿不到会话总线时返回 `null`（调用方照常跑）。
class MprisLinuxService {
  MprisLinuxService._(this._client, this._object);

  final DBusClient _client;
  final _MprisObject _object;

  static const String busName = 'org.mpris.MediaPlayer2.synhub';
  static const String objectPath = '/org/mpris/MediaPlayer2';
  static const String playerInterface = 'org.mpris.MediaPlayer2.Player';
  static const String rootInterface = 'org.mpris.MediaPlayer2';

  /// 起服务。**任何失败都退化成 `null`**（没有总线 / 名字被占 / 权限）。
  ///
  /// [sessionFactory] 只为用例而存在：判"没有会话总线时降级为 null"这条
  /// 不能靠宿主有没有总线（macOS 没有、Linux CI 却有），否则用例在两边
  /// 会得出相反的结论。默认就是 `DBusClient.session`。
  static Future<MprisLinuxService?> start({
    required MprisCallbacks callbacks,
    String identity = 'SynHub',
    String desktopEntry = 'synhub',
    DBusClient Function()? sessionFactory,
  }) async {
    DBusClient? client;
    try {
      client = (sessionFactory ?? DBusClient.session)();
      final reply = await client.requestName(
        busName,
        flags: {DBusRequestNameFlag.doNotQueue},
      );
      if (reply != DBusRequestNameReply.primaryOwner &&
          reply != DBusRequestNameReply.alreadyOwner) {
        await client.close();
        return null;
      }
      final object = _MprisObject(
        callbacks: callbacks,
        identity: identity,
        desktopEntry: desktopEntry,
      );
      await client.registerObject(object);
      return MprisLinuxService._(client, object);
    } catch (e) {
      debugPrint('[mpris] 不可用（降级为没有系统媒体键）：$e');
      try {
        await client?.close();
      } catch (_) {
        // 关都关不掉就算了，别把异常再抛给播放链路
      }
      return null;
    }
  }

  /// 推一份快照（异步发 `PropertiesChanged`；失败不影响播放）。
  Future<void> update(MprisPlaybackSnapshot snapshot) async {
    try {
      await _object.update(snapshot);
    } catch (e) {
      debugPrint('[mpris] 推状态失败（忽略）：$e');
    }
  }

  Future<void> dispose() async {
    try {
      await _client.releaseName(busName);
    } catch (_) {
      // 名字没释放成功也不影响进程退出
    }
    try {
      await _client.close();
    } catch (_) {}
  }
}

/// `/org/mpris/MediaPlayer2` 这一个对象（含两个接口）。
class _MprisObject extends DBusObject {
  _MprisObject({
    required this.callbacks,
    required this.identity,
    required this.desktopEntry,
  }) : super(DBusObjectPath(MprisLinuxService.objectPath));

  final MprisCallbacks callbacks;
  final String identity;
  final String desktopEntry;

  MprisPlaybackSnapshot _snapshot = const MprisPlaybackSnapshot(
    stopped: true,
    playing: false,
  );

  Future<void> update(MprisPlaybackSnapshot next) async {
    final before = _snapshot;
    _snapshot = next;
    final changed = <String, DBusValue>{};
    if (before.playbackStatus != next.playbackStatus) {
      changed['PlaybackStatus'] = DBusString(next.playbackStatus);
    }
    if (before.canNext != next.canNext) {
      changed['CanGoNext'] = DBusBoolean(next.canNext);
    }
    if (before.canPrevious != next.canPrevious) {
      changed['CanGoPrevious'] = DBusBoolean(next.canPrevious);
    }
    if (before.trackId != next.trackId ||
        before.title != next.title ||
        before.artist != next.artist ||
        before.album != next.album ||
        before.artUrl != next.artUrl ||
        before.duration != next.duration) {
      changed['Metadata'] = _metadata();
    }
    if (changed.isNotEmpty) {
      await emitPropertiesChanged(
        MprisLinuxService.playerInterface,
        changedProperties: changed,
      );
    }
  }

  DBusValue _metadata() => mprisMetadataOf(_snapshot);

  DBusValue _positionMicros() =>
      DBusInt64((_snapshot.position ?? Duration.zero).inMicroseconds);

  @override
  List<DBusIntrospectInterface> introspect() => [
    DBusIntrospectInterface(
      MprisLinuxService.rootInterface,
      methods: [
        DBusIntrospectMethod('Raise'),
        DBusIntrospectMethod('Quit'),
      ],
      properties: [
        DBusIntrospectProperty('CanQuit', DBusSignature('b'),
            access: DBusPropertyAccess.read),
        DBusIntrospectProperty('CanRaise', DBusSignature('b'),
            access: DBusPropertyAccess.read),
        DBusIntrospectProperty('HasTrackList', DBusSignature('b'),
            access: DBusPropertyAccess.read),
        DBusIntrospectProperty('Identity', DBusSignature('s'),
            access: DBusPropertyAccess.read),
        DBusIntrospectProperty('DesktopEntry', DBusSignature('s'),
            access: DBusPropertyAccess.read),
        DBusIntrospectProperty('SupportedUriSchemes', DBusSignature('as'),
            access: DBusPropertyAccess.read),
        DBusIntrospectProperty('SupportedMimeTypes', DBusSignature('as'),
            access: DBusPropertyAccess.read),
      ],
    ),
    DBusIntrospectInterface(
      MprisLinuxService.playerInterface,
      methods: [
        DBusIntrospectMethod('Next'),
        DBusIntrospectMethod('Previous'),
        DBusIntrospectMethod('Pause'),
        DBusIntrospectMethod('PlayPause'),
        DBusIntrospectMethod('Stop'),
        DBusIntrospectMethod('Play'),
        DBusIntrospectMethod('Seek', args: [
          DBusIntrospectArgument(DBusSignature('x'),
              DBusArgumentDirection.in_, name: 'Offset'),
        ]),
        DBusIntrospectMethod('SetPosition', args: [
          DBusIntrospectArgument(DBusSignature('o'),
              DBusArgumentDirection.in_, name: 'TrackId'),
          DBusIntrospectArgument(DBusSignature('x'),
              DBusArgumentDirection.in_, name: 'Position'),
        ]),
        DBusIntrospectMethod('OpenUri', args: [
          DBusIntrospectArgument(DBusSignature('s'),
              DBusArgumentDirection.in_, name: 'Uri'),
        ]),
      ],
      properties: [
        DBusIntrospectProperty('PlaybackStatus', DBusSignature('s'),
            access: DBusPropertyAccess.read),
        DBusIntrospectProperty('LoopStatus', DBusSignature('s'),
            access: DBusPropertyAccess.read),
        DBusIntrospectProperty('Rate', DBusSignature('d'),
            access: DBusPropertyAccess.read),
        DBusIntrospectProperty('Shuffle', DBusSignature('b'),
            access: DBusPropertyAccess.read),
        DBusIntrospectProperty('Metadata', DBusSignature('a{sv}'),
            access: DBusPropertyAccess.read),
        DBusIntrospectProperty('Position', DBusSignature('x'),
            access: DBusPropertyAccess.read),
        DBusIntrospectProperty('CanGoNext', DBusSignature('b'),
            access: DBusPropertyAccess.read),
        DBusIntrospectProperty('CanGoPrevious', DBusSignature('b'),
            access: DBusPropertyAccess.read),
        DBusIntrospectProperty('CanPlay', DBusSignature('b'),
            access: DBusPropertyAccess.read),
        DBusIntrospectProperty('CanPause', DBusSignature('b'),
            access: DBusPropertyAccess.read),
        DBusIntrospectProperty('CanSeek', DBusSignature('b'),
            access: DBusPropertyAccess.read),
        DBusIntrospectProperty('CanControl', DBusSignature('b'),
            access: DBusPropertyAccess.read),
      ],
    ),
  ];

  @override
  Future<DBusMethodResponse> handleMethodCall(DBusMethodCall call) async {
    if (call.interface == MprisLinuxService.playerInterface) {
      switch (call.name) {
        case 'Play':
          await callbacks.play?.call();
          return DBusMethodSuccessResponse();
        case 'Pause':
          await callbacks.pause?.call();
          return DBusMethodSuccessResponse();
        case 'PlayPause':
          if (_snapshot.playing) {
            await callbacks.pause?.call();
          } else {
            await callbacks.play?.call();
          }
          return DBusMethodSuccessResponse();
        case 'Next':
          // 能力位只影响面板上的灰/亮；真被调到时照做（队列到头时播放器自己不动）。
          await callbacks.next?.call();
          return DBusMethodSuccessResponse();
        case 'Previous':
          await callbacks.previous?.call();
          return DBusMethodSuccessResponse();
        case 'Stop':
          await callbacks.stop?.call();
          return DBusMethodSuccessResponse();
        case 'Seek':
          final offset = call.values[0].asInt64();
          final base = _snapshot.position ?? Duration.zero;
          await callbacks.seek
              ?.call(base + Duration(microseconds: offset));
          return DBusMethodSuccessResponse();
        case 'SetPosition':
          // 第一个参数是 trackid：**不是这条**就不动（MPRIS 规定要忽略）。
          final track = call.values[0].asObjectPath().value;
          final want = (_snapshot.trackId ?? '')
              .replaceAll(RegExp(r'[^A-Za-z0-9_]'), '_');
          if (want.isNotEmpty &&
              !track.endsWith(want)) {
            return DBusMethodSuccessResponse();
          }
          await callbacks.seek
              ?.call(Duration(microseconds: call.values[1].asInt64()));
          return DBusMethodSuccessResponse();
        case 'OpenUri':
          // 不支持外部 URI 打开：能力位如实报 false，这里回错误而不是假成功。
          return DBusMethodErrorResponse.notSupported();
      }
    }
    if (call.interface == MprisLinuxService.rootInterface) {
      switch (call.name) {
        case 'Raise':
        case 'Quit':
          // 无窗口管理接口：如实 no-op（`CanRaise`/`CanQuit` 都报 false）。
          return DBusMethodSuccessResponse();
      }
    }
    return DBusMethodErrorResponse.unknownMethod();
  }

  @override
  Future<DBusMethodResponse> getProperty(String interface, String name) async {
    final s = _snapshot;
    if (interface == MprisLinuxService.rootInterface) {
      switch (name) {
        case 'CanQuit':
          return DBusGetPropertyResponse(const DBusBoolean(false));
        case 'CanRaise':
          return DBusGetPropertyResponse(const DBusBoolean(false));
        case 'HasTrackList':
          return DBusGetPropertyResponse(const DBusBoolean(false));
        case 'Identity':
          return DBusGetPropertyResponse(DBusString(identity));
        case 'DesktopEntry':
          return DBusGetPropertyResponse(DBusString(desktopEntry));
        case 'SupportedUriSchemes':
          return DBusGetPropertyResponse(DBusArray.string(const []));
        case 'SupportedMimeTypes':
          return DBusGetPropertyResponse(DBusArray.string(const []));
      }
    }
    if (interface == MprisLinuxService.playerInterface) {
      switch (name) {
        case 'PlaybackStatus':
          return DBusGetPropertyResponse(DBusString(s.playbackStatus));
        case 'LoopStatus':
          return DBusGetPropertyResponse(const DBusString('None'));
        case 'Rate':
          return DBusGetPropertyResponse(const DBusDouble(1.0));
        case 'Shuffle':
          return DBusGetPropertyResponse(const DBusBoolean(false));
        case 'Metadata':
          return DBusGetPropertyResponse(_metadata());
        case 'Position':
          return DBusGetPropertyResponse(_positionMicros());
        case 'CanGoNext':
          return DBusGetPropertyResponse(DBusBoolean(s.canNext));
        case 'CanGoPrevious':
          return DBusGetPropertyResponse(DBusBoolean(s.canPrevious));
        case 'CanPlay':
          return DBusGetPropertyResponse(DBusBoolean(!s.stopped));
        case 'CanPause':
          return DBusGetPropertyResponse(DBusBoolean(!s.stopped));
        case 'CanSeek':
          return DBusGetPropertyResponse(
            DBusBoolean(callbacks.seek != null && s.duration != null),
          );
        case 'CanControl':
          return DBusGetPropertyResponse(const DBusBoolean(true));
      }
    }
    return DBusMethodErrorResponse.unknownProperty();
  }

  @override
  Future<DBusMethodResponse> getAllProperties(String interface) async => DBusGetAllPropertiesResponse({
    if (interface == MprisLinuxService.rootInterface) ...{
      'CanQuit': const DBusBoolean(false),
      'CanRaise': const DBusBoolean(false),
      'HasTrackList': const DBusBoolean(false),
      'Identity': DBusString(identity),
      'DesktopEntry': DBusString(desktopEntry),
      'SupportedUriSchemes': DBusArray.string(const []),
      'SupportedMimeTypes': DBusArray.string(const []),
    },
    if (interface == MprisLinuxService.playerInterface) ...{
      'PlaybackStatus': DBusString(_snapshot.playbackStatus),
      'LoopStatus': const DBusString('None'),
      'Rate': const DBusDouble(1.0),
      'Shuffle': const DBusBoolean(false),
      'Metadata': _metadata(),
      'Position': _positionMicros(),
      'CanGoNext': DBusBoolean(_snapshot.canNext),
      'CanGoPrevious': DBusBoolean(_snapshot.canPrevious),
      'CanPlay': DBusBoolean(!_snapshot.stopped),
      'CanPause': DBusBoolean(!_snapshot.stopped),
      'CanSeek': DBusBoolean(callbacks.seek != null && _snapshot.duration != null),
      'CanControl': const DBusBoolean(true),
    },
  });

  @override
  Future<DBusMethodResponse> setProperty(
    String interface,
    String name,
    DBusValue value,
  ) async =>
      // 所有属性都只读：系统面板拖音量/改循环模式时**明确报错**，
      // 而不是"接受了但没生效"（假控件比没控件更坏）。
      DBusMethodErrorResponse.propertyReadOnly();
}
