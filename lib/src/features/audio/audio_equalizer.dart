// B10：均衡器（官方 `EqualizerChooserFragment` / `EqualizerSettings`）。
//
// 官方事实（反编译，见 `docs/admin-parity-requirement.md` §81/§83）：
//   * 开关是本机偏好 `AudioPreference.PREFERENCE_ENABLE_EQUALIZER`（`:46`）；
//   * `SettingsFragment.java:323/395/400`：设置页可用性、可切换、
//     **弹窗提示"开均衡器会影响无缝播放"**；
//   * `playing/EqualizerSettings.java`：直接持 `android.media.audiofx.Equalizer`，
//     频段数 / 中心频率 / 电平上下限 / 预设名**全部运行时从平台枚举**，
//     **官方没有硬编码任何段数或预设表**；
//   * `Utilities.java:140`：`supportGapless() = !EqualizerSettings.enableEqualizer()`。
//
// 本文件实现的是**客户端可测的那一半**：偏好持久化 + 开关 + 平台通道契约。
// DSP 真正生效需要真机 `android.media.audiofx.Equalizer`（平台通道另一侧），
// 因此**不硬编码预设/频段**：预设列表由通道给出，给不出就如实显示"当前不可用"。
//
// ★ 第 368 轮订正（真机 + 源码双证据）：效果**必须挂在正在播放的 audio session**
// 上，写死 `session 0`（全局输出混音）在这台 HONOR / Android 12 上回
// `RuntimeException … Error: -3`（= `AudioEffect.ERROR_NO_INIT`），
// 而本机**确实带着** equalizer（`/system/etc/audio_effects.conf` 声明 +
// `libbundlewrapper.so` 在 + `audio_flinger` 列出 `Equalizer / NXP`）。
// 会话 id 取自 [AudioSpectrumSession.androidAudioSessionId]（真频谱桥同源），
// 没在播时回落 0，行为与改动前一致。
import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/platform/app_platform.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/i18n/data_text.dart';
import '../../core/settings/app_settings.dart';
import '../../core/ui/app_states.dart';
import '../../design/design_palette.dart';
import '../../design/kit/design_kit.dart';
import 'audio_player.dart';

/// 平台通道契约（另一侧是 Android 的 `android.media.audiofx.Equalizer`）。
///
/// * `caps({session})` → `{'available': bool, 'presets': [String], 'bands': int,
///   'minLevel': int, 'maxLevel': int}`；
/// * `apply({session, enabled, preset, bands})`。
///
/// `session` = 播放器的 audio session id（`0` = 没在播 ⇒ 平台侧回落全局混音）。
abstract class AudioEqualizerBridge {
  Future<Map<String, dynamic>> caps({int session = 0});

  Future<void> apply({
    required bool enabled,
    String? preset,
    List<int>? bandLevels,
    int session = 0,
  });
}

/// 真实实现：MethodChannel `synhub/equalizer`。
///
/// ★ 通道另一侧若未实现，`MissingPluginException` 会被
/// [AudioEqualizerController] 收敛成"本机不支持"（**不假装成功**）。
class MethodChannelEqualizerBridge implements AudioEqualizerBridge {
  MethodChannelEqualizerBridge({MethodChannel? channel})
    : _channel = channel ?? const MethodChannel('synhub/equalizer');

  final MethodChannel _channel;

  /// 第 55 轮：`synhub/equalizer` 只有 Kotlin 一份 ⇒ 宿主上不碰通道。
  static bool get _allowed =>
      capabilityGateAllows(AppCapability.audioEqualizer);

  static void _logBlocked(String what) =>
      debugPrint(capabilityGateLog(AppCapability.audioEqualizer, 'equalizer.$what'));

  @override
  Future<Map<String, dynamic>> caps({int session = 0}) async {
    if (!_allowed) {
      _logBlocked('caps');
      return {
        'available': false,
        'reason': capabilityGateReason(AppCapability.audioEqualizer),
      };
    }
    final raw = await _channel.invokeMethod<Object?>('caps', {
      'session': session,
    });
    if (raw is Map) return Map<String, dynamic>.from(raw);
    return const {'available': false};
  }

  @override
  Future<void> apply({
    required bool enabled,
    String? preset,
    List<int>? bandLevels,
    int session = 0,
  }) async {
    if (!_allowed) {
      _logBlocked('apply');
      return;
    }
    await _channel.invokeMethod<void>('apply', {
      'session': session,
      'enabled': enabled,
      'preset': ?preset,
      'bands': ?bandLevels,
    });
  }
}

final audioEqualizerBridgeProvider = Provider<AudioEqualizerBridge>(
  (ref) => MethodChannelEqualizerBridge(),
);

/// 上屏状态：**本机能力 + 用户选择**分开，能力拿不到就如实说。
class AudioEqualizerState {
  const AudioEqualizerState({
    this.loaded = false,
    this.available = false,
    this.presets = const [],
    this.enabled = false,
    this.preset,
  });

  final bool loaded;

  /// 本机（平台通道）是否真的有 EQ 能力。
  final bool available;
  final List<String> presets;
  final bool enabled;
  final String? preset;

  AudioEqualizerState copyWith({
    bool? loaded,
    bool? available,
    List<String>? presets,
    bool? enabled,
    String? preset,
    bool clearPreset = false,
  }) => AudioEqualizerState(
    loaded: loaded ?? this.loaded,
    available: available ?? this.available,
    presets: presets ?? this.presets,
    enabled: enabled ?? this.enabled,
    preset: clearPreset ? null : (preset ?? this.preset),
  );
}

final audioEqualizerProvider =
    NotifierProvider<AudioEqualizerController, AudioEqualizerState>(
      AudioEqualizerController.new,
    );

class AudioEqualizerController extends Notifier<AudioEqualizerState> {
  /// 当前播放器**如果**提供了会话（实现 [AudioSpectrumSession]），否则 null。
  ///
  /// ⚠️ 两个接口**互不继承**（`AudioStationPlayer` vs `AudioSpectrumSession`），
  /// 所以 `is` 判断**不会**自动提升类型，必须显式转换。
  AudioSpectrumSession? _sessionSource() {
    try {
      final p = ref.read(audioStationPlayerProvider);
      if (p is AudioSpectrumSession) return p as AudioSpectrumSession;
    } catch (_) {
      // 播放器还没建 / 未登录 / 平台没有 —— 不是错误
    }
    return null;
  }

  /// 原生均衡器能力（`just_audio` 的播放管道）—— 拿得到就**首选**这条路。
  ///
  /// 同样两个接口互不继承 ⇒ 必须显式转换（不能靠 `is` 提升）。
  AudioEqualizerControls? _nativeControls() {
    try {
      final p = ref.read(audioStationPlayerProvider);
      if (p is AudioEqualizerControls) return p as AudioEqualizerControls;
    } catch (_) {
      // 同上：拿不到就走平台通道那条旧路
    }
    return null;
  }

  @override
  AudioEqualizerState build() {
    // ★ r368：EQ 要挂在**正在播放的那一路**上，而会话是"按播放才建"的
    // ⇒ 订阅会话流：一出现真会话就重新探一次能力，用户不用退页重进。
    final src = _sessionSource();
    if (src != null) {
      final sub = src.androidAudioSessionIdStream.listen((id) {
        if (id != null && id > 0) unawaited(preload());
      });
      ref.onDispose(sub.cancel);
    }
    return const AudioEqualizerState();
  }

  /// `preload()` 判定出的**可用路线**：true = 原生管道（`just_audio`）。
  ///
  /// 为什么要记住：`_apply()` 不许"再猜一次" —— 原生探针可能因为**没起播**
  /// 而超时（那时可用性来自平台通道那条回落路），若 `_apply()` 再按"对象存在"
  /// 就优先原生，会出现"探测走通道、下发走原生"的两把尺子。
  bool _nativeMode = false;

  /// 当前播放会话 id（`just_audio` 暴露的那个）；没在播 / 拿不到 → `0`。
  int _session() {
    final id = _sessionSource()?.androidAudioSessionId;
    return (id != null && id > 0) ? id : 0;
  }

  /// 读本机偏好 + 平台能力（一次）。
  Future<void> preload() async {
    var enabled = false;
    String? preset;
    String? raw;
    try {
      raw = await ref.read(settingsServiceProvider).equalizerJson();
    } catch (_) {
      // 设置服务不可用（如未初始化）→ 用默认值，**不让整页卡在加载中**
      raw = null;
    }
    if (raw != null && raw.isNotEmpty) {
      try {
        final j = jsonDecode(raw) as Map<String, dynamic>;
        enabled = j['enabled'] == true;
        preset = j['preset'] as String?;
      } catch (_) {
        // 坏数据当没存过，不猜
      }
    }
    var available = false;
    var presets = const <String>[];
    var nativeRoute = false;
    // ★ 368：首选**原生**均衡器（不依赖 Dart 拿到会话 id）。
    final native = _nativeControls();
    if (native != null) {
      try {
        // 平台的频段/上下限只在播放器接上平台后才回 ⇒ 自己加超时，
        // 没起播时如实按"当前不可用"处理（不假装）。
        final info = await native
            .equalizerInfo()
            .timeout(const Duration(seconds: 4));
        if (info != null && info.bands > 0) {
          nativeRoute = true;
          available = true;
          presets = const <String>[]; // 原生管道不暴露平台预设名（不编造）
        }
      } on TimeoutException {
        // 还没起播 —— 按不可用处理
      } catch (_) {
        // 平台没有该能力 —— 按不可用处理
      }
    }
    if (!nativeRoute) {
      try {
        final caps = await ref
            .read(audioEqualizerBridgeProvider)
            .caps(session: _session());
        available = caps['available'] == true;
        final p = caps['presets'];
        if (p is List) {
          presets = [for (final e in p) if (e is String && e.isNotEmpty) e];
        }
      } on MissingPluginException {
        available = false;
      } catch (_) {
        available = false;
      }
    }
    _nativeMode = nativeRoute;
    if (!ref.mounted) return;
    state = AudioEqualizerState(
      loaded: true,
      available: available,
      presets: presets,
      enabled: enabled,
      preset: preset,
    );
    // 原生管道要把落盘的开关状态**推给平台**，否则界面与实际不一致。
    if (nativeRoute && enabled) {
      try {
        await native!.setEqualizerEnabled(true);
      } catch (_) {
        // 推不动不改偏好：界面照实显示用户的选择
      }
    }
  }

  /// 落本地偏好。**存不下也不能崩**（设置服务不可用时只是不持久化）。
  Future<void> _persist() async {
    try {
      await ref
          .read(settingsServiceProvider)
          .setEqualizerJson(
            jsonEncode({'enabled': state.enabled, 'preset': state.preset}),
          );
    } catch (_) {
      // 忽略：内存里的选择仍然有效
    }
  }

  /// 开关。官方语义：开着会影响无缝播放（界面需如实提示）。
  Future<void> setEnabled(bool enabled) async {
    state = state.copyWith(enabled: enabled);
    await _persist();
    await _apply();
  }

  Future<void> selectPreset(String? preset) async {
    state = preset == null
        ? state.copyWith(clearPreset: true)
        : state.copyWith(preset: preset);
    await _persist();
    await _apply();
  }

  Future<void> _apply() async {
    if (!state.available) return; // 没能力就不发，不假装
    // ★ 368：首选原生管道（会话 id 由插件自己管）——只走 preload 认定的那条。
    final native = _nativeMode ? _nativeControls() : null;
    if (native != null) {
      try {
        await native.setEqualizerEnabled(state.enabled);
        return;
      } catch (_) {
        // 落回平台通道再试一次（不吞：下面那条路有自己的错误处理）
      }
    }
    try {
      await ref
          .read(audioEqualizerBridgeProvider)
          .apply(
            enabled: state.enabled,
            preset: state.preset,
            session: _session(),
          );
    } on MissingPluginException {
      if (ref.mounted) state = state.copyWith(available: false);
    } catch (_) {
      // 应用失败不改偏好：界面仍显示用户的选择，避免"看起来生效了"
    }
  }
}

/// 设置页：开关 + 预设列表（预设来自平台枚举，不硬编码）。
class AudioEqualizerPage extends ConsumerStatefulWidget {
  const AudioEqualizerPage({super.key});

  @override
  ConsumerState<AudioEqualizerPage> createState() => _AudioEqualizerPageState();
}

class _AudioEqualizerPageState extends ConsumerState<AudioEqualizerPage> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      ref.read(audioEqualizerProvider.notifier).preload();
    });
  }

  @override
  Widget build(BuildContext context) {
    final eq = ref.watch(audioEqualizerProvider);
    return DesignScaffold(
      appBar: AppBar(title: Text(dataText('asEqualizer', '均衡器'))),
      body: !eq.loaded
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: const EdgeInsets.only(bottom: 24),
              children: [
                // ★ r479：这一页原来整页是 `SwitchListTile` + `ListTile` 的
                //   裸 Material 默认样式，与设置页/单曲页不是一套语言。
                //   改成设计组分（组标题 + 行卡 + 说明卡），键位一个没动。
                DesignSectionHeader(dataText('asEqGroupMaster', '总开关')),
                DesignSwitchRow(
                  key: const Key('as-eq-enable'),
                  value: eq.enabled,
                  enabled: eq.available,
                  onChanged: eq.available
                      ? (v) =>
                            ref.read(audioEqualizerProvider.notifier).setEnabled(v)
                      : null,
                  title: Text(dataText('asEqEnable', '启用均衡器')),
                ),
                // 官方逐字提示：开 EQ 会影响无缝播放（`SettingsFragment:400`）
                KeyedSubtree(
                  key: const Key('as-eq-gapless-hint'),
                  child: DesignNote(
                    dataText('asEqGaplessHint', '开启均衡器会影响无缝播放'),
                    icon: Icons.info_outline,
                  ),
                ),
                if (!eq.available)
                  Padding(
                    key: const Key('as-eq-unsupported'),
                    padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                    child: AppEmptyState(
                      icon: Icons.graphic_eq,
                      title: dataText('asEqUnsupported', '均衡器当前不可用'),
                      message: dataText(
                        'asEqUnsupportedHint',
                        '需要正在播放音频时才能调节（效果挂在当前播放会话上）。',
                      ),
                    ),
                  )
                else ...[
                  // 原生管道不暴露平台预设名 ⇒ 如实说明"只有开关"，
                  // 不硬编码一张假预设表。
                  DesignSectionHeader(dataText('asEqGroupPresets', '预设')),
                  if (eq.presets.isEmpty)
                    Padding(
                      key: const Key('as-eq-no-presets'),
                      padding: const EdgeInsets.fromLTRB(20, 0, 20, 12),
                      child: Text(
                        dataText(
                          'asEqNoPresets',
                          '本机原生均衡器只暴露开关：平台没有给出预设名，'
                              '所以这里没有预设列表；开/关立即作用于当前播放输出。',
                        ),
                        style: TextStyle(
                          color: DesignPalette.of(context).muted,
                          fontSize: 12.5,
                          height: 1.4,
                        ),
                      ),
                    ),
                  for (final p in eq.presets)
                    DesignRowTile(
                      key: Key('as-eq-preset-$p'),
                      title: Text(p),
                      selected: eq.preset == p,
                      trailing: eq.preset == p
                          ? const Icon(Icons.check, size: 20)
                          : null,
                      onTap: () => ref
                          .read(audioEqualizerProvider.notifier)
                          .selectPreset(eq.preset == p ? null : p),
                    ),
                ],
                // spec 的「频段」5 条滑块这条**平台给不了**：
                // 原生只暴露开关、没有逐频段读写 ⇒ 不画一排假滑块。
                // 诚实的做法是在 spec 偏差表里记一笔，而不是造一个能拖但没有效果的 UI。
              ],
            ),
    );
  }
}
