// Surveillance Station（DS cam）**界面文案**。
//
// ★ 为什么是「扩展」而不是直接 `context.t.survXxx`：
//   本批（阶段二 A 最后两个模块）与**其它批次并发写** `lib/l10n/*.arb`，
//   直接改 ARB 会丢 key（任务书的硬约束：本批**不动 ARB**）。为了既遵守该约束、
//   又让代码**现在就能编译/跑测试**，这里用 Dart 扩展给 [AppText] 挂上
//   **与计划 ARB key 同名**的 getter/method。
//
//   等父 agent 把下面这批 key 追加进 ARB 并 `flutter gen-l10n` 后：
//     * 生成类里的**实例成员会遮蔽扩展**（Dart 规则：实例成员优先），
//       调用点 `context.t.survXxx` 自动切到真正的 ARB 文案，
//       **本文件可以整份删除**，调用点一行都不用改；
//     * 计划 key 名 / 中文 / 英文 / 占位符见本文件每条的 `zh:`/`en:`。
//
// 语言判定：`AppTextEn` → 英文，其余（含无 delegate 时的 `AppTextZh`）→ 中文。
import '../../../l10n/gen/app_localizations_en.dart';
import '../../core/i18n/l10n.dart';

String _pick(AppText t, {required String zh, required String en}) =>
    t is AppTextEn ? en : zh;

/// 见文件头：与计划 ARB key 同名的扩展文案。
extension SurvAppTextX on AppText {
  // ---- 列表页 ----
  String get survTitle => _pick(this, zh: '监控', en: 'Surveillance');
  String survCameraCount(int count) =>
      _pick(this, zh: '共 $count 路', en: '$count cameras');
  String get survEmptyTitle => _pick(this, zh: '还没有摄像机', en: 'No cameras yet');
  String get survEmptyMessage => _pick(
    this,
    zh: '在 Surveillance Station 里添加摄像机后，就能在这里查看',
    en: 'Add cameras in Surveillance Station to view them here',
  );
  String get survErrNotInstalled => _pick(
    this,
    zh: '这台 NAS 没有安装 Surveillance Station',
    en: 'Surveillance Station is not installed on this NAS',
  );
  String get survNotInstalledHint => _pick(
    this,
    zh: '在 DSM「套件中心」安装 Surveillance Station 后即可使用',
    en: 'Install Surveillance Station from DSM Package Center to use it',
  );
  String get survErrNoPrivilege => _pick(
    this,
    zh: '这个账号没有使用 Surveillance Station 的权限',
    en: 'This account has no permission to use Surveillance Station',
  );
  String get survNoPrivilegeHint => _pick(
    this,
    zh: '请联系管理员为这个账号授予 Surveillance Station 权限',
    en: 'Ask an administrator to grant this account Surveillance Station access',
  );
  String get survLoadFailed =>
      _pick(this, zh: '摄像机列表加载失败', en: 'Failed to load cameras');

  // ---- 状态 ----
  String get survStatusLive => _pick(this, zh: '正常', en: 'Live');
  String get survStatusOffline => _pick(this, zh: '离线', en: 'Offline');
  String get survStatusDisabled => _pick(this, zh: '已停用', en: 'Disabled');
  String get survStatusDisconnected =>
      _pick(this, zh: '连接中断', en: 'Disconnected');
  String get survStatusSetting => _pick(this, zh: '设置中', en: 'Setting up');
  String get survStatusUnknown => _pick(this, zh: '状态未知', en: 'Unknown');
  String survStatusOther(int code) =>
      _pick(this, zh: '状态（$code）', en: 'Status ($code)');

  // ---- 详情页 ----
  String get survCameraDetailTitle => _pick(this, zh: '摄像机', en: 'Camera');
  String get survDetailLoadFailed =>
      _pick(this, zh: '摄像机信息加载失败', en: 'Failed to load camera');
  String get survLiveSection => _pick(this, zh: '实时画面', en: 'Live view');
  String get survLiveHint => _pick(
    this,
    zh: '实时画面由外部播放器播放；下面是可以直接使用的流地址',
    en: 'Live streams play in an external player; use the URLs below',
  );
  String get survLiveUnavailable => _pick(
    this,
    zh: '这台摄像机当前不在线，暂时取不到实时画面',
    en: 'This camera is offline, so there is no live view right now',
  );
  String get survSnapshot => _pick(this, zh: '快照', en: 'Snapshot');
  String get survOpenSnapshot => _pick(this, zh: '打开快照', en: 'Open snapshot');
  String get survRtspUrl => _pick(this, zh: 'RTSP 地址', en: 'RTSP URL');
  String get survMjpegUrl => _pick(this, zh: 'MJPEG 地址', en: 'MJPEG URL');
  String get survCopyUrl => _pick(this, zh: '复制地址', en: 'Copy URL');
  String get survCopyDone => _pick(this, zh: '地址已复制', en: 'URL copied');

  // ---- PTZ ----
  String get survPtzSection => _pick(this, zh: '云台控制', en: 'PTZ');
  String get survPtzUp => _pick(this, zh: '上', en: 'Up');
  String get survPtzDown => _pick(this, zh: '下', en: 'Down');
  String get survPtzLeft => _pick(this, zh: '左', en: 'Left');
  String get survPtzRight => _pick(this, zh: '右', en: 'Right');
  String get survPtzHome => _pick(this, zh: '回到起始位置', en: 'Home');
  String get survPtzZoomIn => _pick(this, zh: '放大', en: 'Zoom in');
  String get survPtzZoomOut => _pick(this, zh: '缩小', en: 'Zoom out');
  String get survPtzPresetTitle => _pick(this, zh: '预置位', en: 'Presets');
  String get survPtzPresetEmpty =>
      _pick(this, zh: '这台摄像机没有预置位', en: 'No presets on this camera');
  String get survPtzPresetFailed =>
      _pick(this, zh: '预置位加载失败', en: 'Failed to load presets');
  String survPresetPosition(int n) =>
      _pick(this, zh: '预置位 $n', en: 'Preset $n');
  String survPtzMoveFailed(String reason) =>
      _pick(this, zh: '云台操作失败：$reason', en: 'PTZ failed: $reason');

  // ---- 录像 ----
  String get survRecordingsSection => _pick(this, zh: '录像', en: 'Recordings');
  String get survRecordingsEmpty =>
      _pick(this, zh: '最近没有录像', en: 'No recent recordings');
  String get survRecordingsFailed =>
      _pick(this, zh: '录像加载失败', en: 'Failed to load recordings');
  String survRecordingCount(int count) =>
      _pick(this, zh: '共 $count 段', en: '$count clips');
  String survRecordingDuration(String duration) =>
      _pick(this, zh: '时长 $duration', en: 'Duration $duration');
  String get survRecordingEncrypted => _pick(this, zh: '已加密', en: 'Encrypted');
}
