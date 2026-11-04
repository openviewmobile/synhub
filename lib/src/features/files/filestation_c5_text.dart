// File Station C5（远程挂载 / 虚拟卷）与文件侧剩余 P1 缺口新增界面文案：
// **key + 中文原文**。
//
// 约定与 `filestation_p0a_text.dart` / `filestation_p0b_text.dart` 一致：
// `.arb` 与 `lib/l10n/gen/**` 在本批次**禁碰**，所以新文案一律
// `key + 中文原文`，走 `dataText`（`lib/src/core/i18n/data_text.dart`）。
// ARB 里补上同名 key 后，`setCurrentText` 注入的翻译表会自动把中文原文换成
// 当前语言译文；没补上时回落中文原文。
//
// 现有 key 清单（交给父 agent 并入 ARB，见本批报告 §⑦）：
//   * `fsC5MountTitle`           —— 页面标题：远程挂载
//   * `fsC5MountIsoSection`      —— ISO 镜像卷分组
//   * `fsC5MountRemoteSection`   —— 远程卷（CIFS）分组
//   * `fsC5MountEmpty`           —— 空态：还没有挂载
//   * `fsC5MountAdd`             —— 新增挂载入口
//   * `fsC5MountAddCifs`         —— 新增 CIFS 挂载标题
//   * `fsC5MountAddIso`          —— 新增 ISO 挂载标题
//   * `fsC5MountServer`          —— 服务器地址
//   * `fsC5MountServerHint`      —— 服务器地址占位符（`{example}`）
//   * `fsC5MountAccount`         —— 账号
//   * `fsC5MountPassword`        —— 密码
//   * `fsC5MountMountPoint`      —— 挂载点
//   * `fsC5MountPointHint`       —— 挂载点提示（`{example}`）
//   * `fsC5MountSource`          —— ISO 源文件
//   * `fsC5MountAutoMount`       —— 开机自动挂载
//   * `fsC5MountActor`           —— 挂载者
//   * `fsC5MountAutoMountFailed` —— 开机自动挂载失败
//   * `fsC5MountIsoReadOnly`     —— ISO 卷只读说明
//   * `fsC5MountUnmount`         —— 卸载
//   * `fsC5MountUnmountConfirm`  —— 卸载二次确认（`{name}`）
//   * `fsC5MountUnmounted`       —— 已卸载
//   * `fsC5MountReconnect`       —— 重新连接
//   * `fsC5MountRemount`         —— 重新挂载
//   * `fsC5MountBrowse`          —— 浏览
//   * `fsC5MountSubmitted`       —— 已提交挂载
//   * `fsC5MountPermissionDenied`—— 权限不足（105/160）提示
//   * `fsC5MountUnavailable`     —— 服务器没有挂载接口时的提示
//   * `fsC5MountVirtualSection`  —— 虚拟文件夹分组
//   * `fsC5MountRequired`        —— 必填项为空
//   * `fsC5FilterHint`           —— 目录内筛选框
//   * `fsC5FilterClear`          —— 清除筛选
//   * `fsC5FilterNoMatch`        —— 筛选无结果
//   * `fsC5ReadOnly`             —— 只读角标
//   * `fsC5WormLocked`           —— WORM 已锁定角标
//   * `fsC5WormBlocked`          —— 锁定文件禁止某动作（`{action}`）
//   * `fsC5CompressFormat`       —— 压缩格式
//   * `fsC5CompressLevel`        —— 压缩级别
//   * `fsC5LevelStore`           —— 级别：仅存储
//   * `fsC5LevelFastest`         —— 级别：最快
//   * `fsC5LevelModerate`        —— 级别：标准
//   * `fsC5LevelBest`            —— 级别：最好
//   * `fsC5ExtractCodepage`      —— 解压文件名编码
//   * `fsC5ExtractCodepageHint`  —— 编码说明
//   * `fsC5TaskDetail`           —— 后台任务详情
//   * `fsC5TaskDetailParams`     —— 任务参数分组
//   * `fsC5TaskDetailErrors`     —— 任务错误分组
//   * `fsC5TaskNoError`          —— 没有错误
//   * `fsC5FavoriteRename`       —— 重命名收藏
//   * `fsC5FavoriteClearBroken`  —— 清理失效收藏
//   * `fsC5FavoriteClearBrokenConfirm` —— 清理失效收藏二次确认
//   * `fsC5FavoriteCleared`      —— 已清理失效收藏
//   * `fsC5FavoriteRenamed`      —— 收藏已重命名
//
// ⚠️ `fsC5MountVirtualEmpty` 已**删除**（曾是未被引用的死代码，W1-3 收尾判定）：
//   挂载页只在虚拟文件夹**非空**时才渲染「虚拟文件夹」分组，而"一个挂载/虚拟卷
//   都没有"由页面级空态 `fsC5MountEmpty` 覆盖；且 `fileVirtualFoldersProvider`
//   把"服务端确实为空"和"105 无权限"**折叠成同一个 `[]`**，所以单独的
//   "虚拟文件夹为空"文案在无权限场景会**说谎**。逐 key 判定表见
//   `docs/small-gaps-closeout.md` §3。
//   `fsC5TaskDetail` 则是**本该有 UI** → 已接到任务详情弹层的标题上
//   （`file_sheets.dart` 的 `showFileTaskDetailSheet`）。
import '../../core/i18n/data_text.dart';

/// 取 C5 新文案的译文；[zh] 是中文原文（回落值）。
String fsC5(String key, String zh) => dataText(key, zh);

/// 带 `{name}` / `{example}` / `{action}` 占位符的文案填充助手。
String fsC5Fill(String key, String zh, Map<String, String> values) {
  var out = fsC5(key, zh);
  values.forEach((k, v) => out = out.replaceAll('{$k}', v));
  return out;
}

/// 本批次新增的 ARB key（下一步直接照抄进 `app_zh.arb` / `app_en.arb`）。
abstract final class FsC5TextKeys {
  // ---- C5：远程挂载 / 虚拟卷 ----
  static const mountTitle = 'fsC5MountTitle';
  /// D17：芯片位用的短标签（长标签在小窗口被 ellipsis 截成 `Remote mo…`）
  static const mountChip = 'fsC5MountChip';
  static const mountIsoSection = 'fsC5MountIsoSection';
  static const mountRemoteSection = 'fsC5MountRemoteSection';
  static const mountEmpty = 'fsC5MountEmpty';
  /// 服务端 `mountConfig` 两类都为 false（官方 `error_privilege_not_enough`）
  static const mountServerDisabled = 'fsC5MountServerDisabled';
  /// 服务端开了远程卷，但非管理员且没有 home（官方 `err_remote_no_home`）
  static const mountNeedsHome = 'fsC5MountNeedsHome';
  static const mountAdd = 'fsC5MountAdd';
  static const mountAddCifs = 'fsC5MountAddCifs';
  static const mountAddIso = 'fsC5MountAddIso';
  static const mountServer = 'fsC5MountServer';
  static const mountServerHint = 'fsC5MountServerHint';
  static const mountAccount = 'fsC5MountAccount';
  static const mountPassword = 'fsC5MountPassword';
  static const mountMountPoint = 'fsC5MountMountPoint';
  static const mountPointHint = 'fsC5MountPointHint';
  static const mountSource = 'fsC5MountSource';
  static const mountAutoMount = 'fsC5MountAutoMount';
  static const mountActor = 'fsC5MountActor';
  static const mountAutoMountFailed = 'fsC5MountAutoMountFailed';
  static const mountIsoReadOnly = 'fsC5MountIsoReadOnly';
  static const mountUnmount = 'fsC5MountUnmount';
  static const mountUnmountConfirm = 'fsC5MountUnmountConfirm';
  static const mountUnmounted = 'fsC5MountUnmounted';
  static const mountReconnect = 'fsC5MountReconnect';
  static const mountRemount = 'fsC5MountRemount';
  static const mountBrowse = 'fsC5MountBrowse';
  static const mountSubmitted = 'fsC5MountSubmitted';
  static const mountPermissionDenied = 'fsC5MountPermissionDenied';
  static const mountUnavailable = 'fsC5MountUnavailable';
  static const mountVirtualSection = 'fsC5MountVirtualSection';
  static const mountRequired = 'fsC5MountRequired';

  // ---- P1：文件侧剩余缺口 ----
  static const filterHint = 'fsC5FilterHint';
  /// D17：芯片位用的短标签（长标签在小窗口被 ellipsis 截成 `Filter in fol…`）
  static const filterChip = 'fsC5FilterChip';

  /// ★ 第 259 轮：返回上一级（真机“进了子目录回不去”的修复入口）
  static const up = 'fsC5Up';
  static const filterClear = 'fsC5FilterClear';
  static const filterNoMatch = 'fsC5FilterNoMatch';
  static const readOnly = 'fsC5ReadOnly';
  static const wormLocked = 'fsC5WormLocked';
  static const wormBlocked = 'fsC5WormBlocked';
  static const compressFormat = 'fsC5CompressFormat';
  static const compressLevel = 'fsC5CompressLevel';
  static const levelStore = 'fsC5LevelStore';
  static const levelFastest = 'fsC5LevelFastest';
  static const levelModerate = 'fsC5LevelModerate';
  static const levelBest = 'fsC5LevelBest';
  static const extractCodepage = 'fsC5ExtractCodepage';
  static const extractCodepageHint = 'fsC5ExtractCodepageHint';
  static const taskDetail = 'fsC5TaskDetail';
  static const taskDetailParams = 'fsC5TaskDetailParams';
  static const taskDetailErrors = 'fsC5TaskDetailErrors';
  static const taskNoError = 'fsC5TaskNoError';

  /// P1-7：收藏重命名 / 清理失效收藏
  static const favoriteRename = 'fsC5FavoriteRename';
  static const favoriteClearBroken = 'fsC5FavoriteClearBroken';
  static const favoriteClearBrokenConfirm = 'fsC5FavoriteClearBrokenConfirm';
  static const favoriteCleared = 'fsC5FavoriteCleared';
  static const favoriteRenamed = 'fsC5FavoriteRenamed';
}
