// 视频投屏的**状态机**（r655 · DA264）。真正的网络动作在 `upnp_cast.dart`，
// 这一层只负责"用户看到什么、下一步能做什么"，因此可以用假实现逐条断言。
//
// 状态只有五种，**每一种都必须有话说**（`DA260` 的教训：静默失败比报错更伤人）：
//   * [VideoCastPhase.idle]      还没开始（按钮上写着「投屏」）；
//   * [VideoCastPhase.searching] 正在找设备（**必须**有可中断的等待态，不能白屏）；
//   * [VideoCastPhase.ready]     找到了，等用户挑（列表 + 「重新搜索」）；
//   * [VideoCastPhase.casting]   正在某台设备上放（显示设备名 + 「停止投屏」）；
//   * [VideoCastPhase.failed]    失败了，带**原因**与「重试」。
//
// 为什么"推上去"和"起播"分开两步：设备认了 URI 但它自己拉不到 NAS 直链
// （跨网段 / 不信任证书）是**最常见**的一种失败，把它和"压根不认这个格式"混成
// 一句"投屏失败"，用户就没法判断该换电视还是该换网络。
import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'media_source.dart';
import 'upnp_cast.dart';

enum VideoCastPhase { idle, searching, ready, casting, failed }

/// 投屏的**不可变快照**（界面只读它；每次变化整份替换，避免"半个状态"）
class VideoCastSnapshot {
  const VideoCastSnapshot({
    this.phase = VideoCastPhase.idle,
    this.renderers = const [],
    this.renderer,
    this.failure,
    this.remotePlaying = false,
    this.remoteState,
  });

  final VideoCastPhase phase;
  final List<UpnpRenderer> renderers;
  final UpnpRenderer? renderer;
  final UpnpCastFailure? failure;

  /// 远端是不是在播（决定「停止/继续」按钮；问不到时保持上一次的值）
  final bool remotePlaying;

  /// 远端 `CurrentTransportState` 原文（诊断用；界面**不**直接显示它）
  final String? remoteState;

  VideoCastSnapshot copyWith({
    VideoCastPhase? phase,
    List<UpnpRenderer>? renderers,
    UpnpRenderer? renderer,
    UpnpCastFailure? failure,
    bool? remotePlaying,
    String? remoteState,
    bool clearFailure = false,
    bool clearRenderer = false,
  }) {
    return VideoCastSnapshot(
      phase: phase ?? this.phase,
      renderers: renderers ?? this.renderers,
      renderer: clearRenderer ? null : (renderer ?? this.renderer),
      failure: clearFailure ? null : (failure ?? this.failure),
      remotePlaying: remotePlaying ?? this.remotePlaying,
      remoteState: clearRenderer ? null : (remoteState ?? this.remoteState),
    );
  }
}

/// 投屏能力的最小接口（**测试注入点**）
abstract class VideoCast {
  /// 搜一轮渲染器；返回空列表 = 同一网络里没有（**不是**失败）
  Future<List<UpnpRenderer>> search();

  /// 推一条视频上去并起播。返回 null = 成功。
  Future<UpnpCastFailure?> cast(
    UpnpRenderer renderer,
    MediaSource source, {
    Duration position = Duration.zero,
    bool playing = true,
  });

  /// 停止投屏（会先 Stop 再清状态；设备已经不在了也算成功）
  Future<void> stop();

  Future<UpnpCastFailure?> pause();

  Future<UpnpCastFailure?> resume();

  /// 问远端状态（`PLAYING` 等）；null = 问不到
  Future<String?> remoteTransportState();
}

/// 真实现：SSDP 发现 + AVTransport 推送
class UpnpVideoCast implements VideoCast {
  UpnpVideoCast({UpnpDiscovery? discovery, UpnpAvTransport Function(String)? transportOf})
      : _discovery = discovery ?? UpnpDiscovery(),
        _transportOf = transportOf ?? ((url) => UpnpAvTransport(controlUrl: url));

  final UpnpDiscovery _discovery;
  final UpnpAvTransport Function(String controlUrl) _transportOf;

  UpnpAvTransport? _transport;

  @override
  Future<List<UpnpRenderer>> search() => _discovery.discover();

  @override
  Future<UpnpCastFailure?> cast(
    UpnpRenderer renderer,
    MediaSource source, {
    Duration position = Duration.zero,
    bool playing = true,
  }) async {
    final t = _transportOf(renderer.controlUrl);
    _transport = t;
    final setFailure = await t.setVideo(
      source: source,
      title: source.displayName,
    );
    if (setFailure != null) return setFailure;
    if (position > Duration.zero) {
      // 续投：位置回填是"尽力而为"（设备不支持 REL_TIME 时从头发，仍然能看）
      await t.seek(position);
    }
    if (playing) {
      final playFailure = await t.play();
      if (playFailure != null) return playFailure;
    }
    // "推成功但设备拉不到流"的现场判据：SetAVTransportURI 是异步的，
    // 设备要自己发 GET。给它一点时间再问状态 —— 不是靠猜，是靠它自己说。
    await Future<void>.delayed(const Duration(milliseconds: 600));
    final state = await t.transportState();
    if (state == null) return UpnpCastFailure.playbackFailed;
    return null;
  }

  @override
  Future<void> stop() async {
    final t = _transport;
    _transport = null;
    if (t == null) return;
    await t.stop();
  }

  @override
  Future<UpnpCastFailure?> pause() async => await _transport?.pause();

  @override
  Future<UpnpCastFailure?> resume() async => await _transport?.play();

  @override
  Future<String?> remoteTransportState() async =>
      await _transport?.transportState();
}

/// 控制器：页面持有一份，快照变化推给界面。
class VideoCastController {
  VideoCastController({required this.cast});

  final VideoCast cast;

  final _changes = StreamController<VideoCastSnapshot>.broadcast();
  VideoCastSnapshot _snapshot = const VideoCastSnapshot();

  VideoCastSnapshot get snapshot => _snapshot;

  Stream<VideoCastSnapshot> get changes => _changes.stream;

  void _emit(VideoCastSnapshot next) {
    _snapshot = next;
    if (!_changes.isClosed) _changes.add(next);
  }

  /// 搜设备。**已经连着设备时不重搜**（会把用户正在投的那台挤掉）。
  Future<void> search() async {
    if (_snapshot.phase == VideoCastPhase.casting) return;
    _emit(
      _snapshot.copyWith(
        phase: VideoCastPhase.searching,
        clearFailure: true,
      ),
    );
    List<UpnpRenderer> found;
    try {
      found = await cast.search();
    } catch (_) {
      found = const [];
    }
    if (found.isEmpty) {
      _emit(
        _snapshot.copyWith(
          phase: VideoCastPhase.failed,
          renderers: const [],
          failure: UpnpCastFailure.noRenderer,
        ),
      );
      return;
    }
    _emit(
      _snapshot.copyWith(phase: VideoCastPhase.ready, renderers: found),
    );
  }

  /// 投到某台设备
  Future<void> start(
    UpnpRenderer renderer,
    MediaSource source, {
    Duration position = Duration.zero,
    bool playing = true,
  }) async {
    _emit(
      _snapshot.copyWith(
        phase: VideoCastPhase.casting,
        renderer: renderer,
        clearFailure: true,
        remotePlaying: playing,
      ),
    );
    UpnpCastFailure? failure;
    try {
      failure = await cast.cast(
        renderer,
        source,
        position: position,
        playing: playing,
      );
    } catch (_) {
      failure = UpnpCastFailure.unreachable;
    }
    if (failure != null) {
      _emit(
        _snapshot.copyWith(phase: VideoCastPhase.failed, failure: failure),
      );
      return;
    }
    _emit(_snapshot.copyWith(phase: VideoCastPhase.casting, remotePlaying: true));
  }

  /// 停止投屏：**界面立刻回到"没在投"，不等设备回包**（设备已拔电时不能卡住）
  Future<void> stop() async {
    _emit(
      const VideoCastSnapshot(phase: VideoCastPhase.idle),
    );
    try {
      await cast.stop();
    } catch (_) {
      // 设备不在了也算停成功（这正是"停止"该有的语义）
    }
  }

  Future<void> toggleRemotePlayback() async {
    if (_snapshot.phase != VideoCastPhase.casting) return;
    final wantPlay = !_snapshot.remotePlaying;
    UpnpCastFailure? failure;
    try {
      failure = wantPlay ? await cast.resume() : await cast.pause();
    } catch (_) {
      failure = UpnpCastFailure.unreachable;
    }
    if (failure != null) {
      _emit(_snapshot.copyWith(failure: failure));
      return;
    }
    _emit(_snapshot.copyWith(remotePlaying: wantPlay, clearFailure: true));
  }

  Future<void> dispose() async {
    try {
      await cast.stop();
    } catch (_) {}
    if (!_changes.isClosed) await _changes.close();
  }
}


/// 界面取一个投屏实现（测试里覆盖成假实现 ⇒ 不需要真设备也能断言全部分支）
final videoCastFactoryProvider = Provider<VideoCast Function()>(
  (ref) => UpnpVideoCast.new,
);
