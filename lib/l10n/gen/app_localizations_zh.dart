// ignore: unused_import
import 'package:intl/intl.dart' as intl;
import 'app_localizations.dart';

// ignore_for_file: type=lint

/// The translations for Chinese (`zh`).
class AppTextZh extends AppText {
  AppTextZh([String locale = 'zh']) : super(locale);

  @override
  String get appName => '星枢';

  @override
  String get navChat => '聊天';

  @override
  String get navFiles => '文件';

  @override
  String get navPhotos => '相册';

  @override
  String get navWorkspace => '工作台';

  @override
  String get navMe => '我的';

  @override
  String get wsFiles => '文件';

  @override
  String get wsNotes => '笔记';

  @override
  String get wsPhotos => '相册';

  @override
  String get wsContacts => '联系人';

  @override
  String get wsCalendar => '日历';

  @override
  String get wsTasks => '后台任务';

  @override
  String wsTasksRunning(int n) {
    return '$n 个进行中';
  }

  @override
  String get wsTasksNone => '暂无任务';

  @override
  String get wsTasksDone => '全部完成';

  @override
  String get wsSearchFiles => '搜索文件';

  @override
  String get wsSearchFilesHint => '按文件名搜索有权限的文件夹';

  @override
  String get wsSearchFilesShort => '按文件名搜索';

  @override
  String wsHiddenCount(int n) {
    return '已收起 $n 个没用过的模块';
  }

  @override
  String get wsShowAll => '显示全部';

  @override
  String get wsSearchHint => '搜索模块，回车搜文件';

  @override
  String get wsNoMatch => '没有匹配的模块';

  @override
  String wsSearchInFiles(String q) {
    return '在文件里搜索「$q」';
  }

  @override
  String get meAccount => '账号';

  @override
  String get meApp => '应用';

  @override
  String get meNotLoggedIn => '未登录';

  @override
  String get meProfile => '个人资料';

  @override
  String get meProfileHint => '昵称 / 头像';

  @override
  String get meNotifications => '通知与免打扰';

  @override
  String get meNotificationsHint => '免打扰时段、时区';

  @override
  String get meE2ee => '端到端加密';

  @override
  String get meE2eeHint => '私密会话的密钥与解密尝试次数';

  @override
  String get meSettings => '设置';

  @override
  String get meSettingsHint => '主题 / 字体 / 消息 / 存储';

  @override
  String get meCertificates => '证书信任';

  @override
  String get meCertificatesHint => '自签名证书指纹管理';

  @override
  String get meArchives => '归档频道';

  @override
  String get meArchivesHint => '已归档的加密会话';

  @override
  String get setTitle => '设置';

  @override
  String get setSectionAppearance => '外观';

  @override
  String get setSectionMedia => '消息与媒体';

  @override
  String get setSectionSecurity => '安全与后台';

  @override
  String get setSectionPrivacy => '隐私与数据';

  @override
  String get setSectionAbout => '关于';

  @override
  String get setTheme => '主题';

  @override
  String get themeSystem => '跟随系统';

  @override
  String get themeLight => '浅色';

  @override
  String get themeDark => '深色';

  @override
  String get setDynamicColor => '动态取色';

  @override
  String get setDynamicColorHint => '跟随系统壁纸（Material You），关掉就用品牌蓝';

  @override
  String setDynamicColorSource(String source, String hex) {
    return '当前取自壁纸：$source（$hex）';
  }

  @override
  String get setDynamicColorUnavailable => '本机取不到壁纸色（不是 Material You 设备），暂用品牌蓝';

  @override
  String get setChatGrid => '聊天页网格底纹';

  @override
  String get setChatGridHint => '座舱 HUD 氛围；关掉就是纯色背景';

  @override
  String get setPerfMode => '性能模式';

  @override
  String get setPerfModeHint => '关掉毛玻璃等昂贵效果，低端机更省电';

  @override
  String get setReducedMotion => '减少动效';

  @override
  String get setReducedMotionHint => '所有过渡立即完成（系统「移除动画」也会自动生效）';

  @override
  String setAutoHint(String on) {
    return '自动（按设备性能默认$on）';
  }

  @override
  String setManualHint(String on, String dflt) {
    return '已手动$on（设备默认$dflt）';
  }

  @override
  String get setOn => '开启';

  @override
  String get setOff => '关闭';

  @override
  String get setRestoreAuto => '恢复自动';

  @override
  String setDeviceTier(String tier) {
    return '设备性能档位：$tier';
  }

  @override
  String setDeviceTierSpec(String spec, String blur, String motion) {
    return '$spec\n自动判定：毛玻璃$blur · 动效$motion';
  }

  @override
  String get setMotionFull => '完整';

  @override
  String get setMotionReduced => '减少';

  @override
  String get setLanguage => '语言';

  @override
  String get setLanguageHint => '界面语言（跟随系统 / 简体中文 / English）';

  @override
  String get langSystem => '跟随系统';

  @override
  String get langZh => '简体中文';

  @override
  String get langEn => 'English';

  @override
  String get setImageQuality => '发送图片质量';

  @override
  String get qualityOriginal => '原图';

  @override
  String get qualityOriginalHint => '不重新编码，保留原始画质';

  @override
  String get qualityStandard => '标准';

  @override
  String get qualityStandardHint => '压到 1080p 再发';

  @override
  String get setSendByEnter => '回车发送';

  @override
  String get setSendByEnterOn => '按回车直接发送';

  @override
  String get setSendByEnterOff => '回车换行，点发送按钮才发';

  @override
  String get setCacheLimit => '缓存上限';

  @override
  String get cacheUnlimited => '不限制';

  @override
  String get setClearCache => '清理已下载的文件';

  @override
  String get cacheCounting => '正在统计…';

  @override
  String get cacheCountFailed => '统计失败';

  @override
  String get cacheNone => '暂无缓存';

  @override
  String cacheUsed(String size, int n) {
    return '已用 $size · $n 个文件';
  }

  @override
  String get dialogClearCacheTitle => '清空缓存';

  @override
  String get dialogClearCacheBody =>
      '会删掉本机缓存的附件、缩略图与预览图（视频首帧、Office 图片与模板缩略图、PDF 渲染缓存），下次打开会重新下载或重建。离线保存的内容、在线字幕、聊天记录与设置都不受影响。';

  @override
  String cacheCleared(String size) {
    return '已清空 $size';
  }

  @override
  String get actionCancel => '取消';

  @override
  String get actionClear => '清空';

  @override
  String get setPostPreview => '收到消息通知时预加载消息';

  @override
  String get setSort => '频道和对话排序方式';

  @override
  String get setCertificates => '证书信任';

  @override
  String get setCertificatesHint => '查看/删除已信任的服务器证书';

  @override
  String get setNasManageHint => '查看本机保存的 NAS 与账号，切换当前连接';

  @override
  String get setNotifications => '通知与后台';

  @override
  String get setForegroundRunning => '前台服务运行中';

  @override
  String get setForegroundStopped => '前台服务未运行';

  @override
  String get setSnooze => '免打扰';

  @override
  String get setE2ee => '端到端加密';

  @override
  String get setOnDeviceAi => 'AI 服务';

  @override
  String get setOnDeviceAiHint => '云端/端侧模型、key 与模型选择（端侧可不下模型）';

  @override
  String get setUsageAnalytics => '使用分析';

  @override
  String get setUsageAnalyticsHint => '本地使用日志 + 习惯结论（可导出/清空）';

  @override
  String get setVersion => '版本';

  @override
  String get setSrcDirect => '直连';

  @override
  String get setSrcLan => '局域网';

  @override
  String get setSrcDdns => 'DDNS';

  @override
  String get setSrcExternal => '外网';

  @override
  String get setSrcFqdn => '域名';

  @override
  String get setSrcSmartDns => 'SmartDNS';

  @override
  String get setSrcRelay => '中继';

  @override
  String get setSrcOther => '其它方式';

  @override
  String get setSrcUnknown => '连接方式未知';

  @override
  String get setServer => '服务器';

  @override
  String get setMyAccount => '我的账号';

  @override
  String get setAdminSuffix => '（管理员）';

  @override
  String get setRoleAdmin => '管理员';

  @override
  String get setRoleMember => '普通账号';

  @override
  String get setDiagnostics => '连接诊断';

  @override
  String get setNotConnected => '未连接';

  @override
  String get setAppLock => '应用锁';

  @override
  String get setAppLockLoading => '读取中…';

  @override
  String get setGapProfileEntry => '账号信息';

  @override
  String get setGapProfileEntryHint => '昵称 / 邮箱 / 账号类型（只读）';

  @override
  String get setGapProfileTitle => '账号信息';

  @override
  String get setGapProfileNickname => '昵称';

  @override
  String get setGapProfileEmail => '邮箱';

  @override
  String get setGapProfileOtherEmails => '其他邮箱';

  @override
  String get setGapProfileAccountType => '账号类型';

  @override
  String get setGapProfileGuest => '访客账号';

  @override
  String get setGapProfileMember => '普通账号';

  @override
  String get setGapProfileUnset => '未设置';

  @override
  String get setGapProfileNoEmail => '未绑定邮箱';

  @override
  String get setGapProfileLoadFailed => '资料加载失败';

  @override
  String get setGapProfileRetry => '重试';

  @override
  String get setGapProfileNotLoggedIn => '未登录，无法读取个人资料';

  @override
  String get setGapProfileGuestHint => '当前登录的是访客账号，可用功能以管理员授权为准。';

  @override
  String get fsGap5ThumbInfoSection => '照片元数据';

  @override
  String get fsGap5ThumbInfoEmpty => '该文件不含 EXIF / IPTC / XMP 元数据';

  @override
  String get fsGap5ThumbInfoLoading => '正在读取元数据…';

  @override
  String get fsGap5ThumbInfoExif => 'EXIF';

  @override
  String get fsGap5ThumbInfoIptc => 'IPTC';

  @override
  String get fsGap5ThumbInfoXmp => 'XMP';

  @override
  String get fsGap5ThumbInfoCamera => '相机型号';

  @override
  String get fsGap5ThumbInfoLens => '镜头';

  @override
  String get fsGap5ThumbInfoTakenAt => '拍摄时间';

  @override
  String get fsGap5ThumbInfoAperture => '光圈';

  @override
  String get fsGap5ThumbInfoIso => 'ISO';

  @override
  String get fsGap5ThumbInfoExposure => '曝光时间';

  @override
  String get fsGap5ThumbInfoFocalLength => '焦距';

  @override
  String get fsGap5ThumbInfoGps => 'GPS 位置';

  @override
  String get fsGap5ThumbInfoSoftware => '软件';

  @override
  String get fsGap5ThumbInfoMake => '相机制造商';

  @override
  String get fsGap5ThumbInfoOrientation => '方向';

  @override
  String setAppLockOn(int n) {
    return '已开启：$n 位数字口令';
  }

  @override
  String get setAppLockOff => '开启后每次打开都要输口令';

  @override
  String unlockReason(String label, String app) {
    return '用$label解锁 $app';
  }

  @override
  String keepAliveTitle(String app) {
    return '$app';
  }

  @override
  String get keepAliveText => '正在保持连接';

  @override
  String get previewModeClose => '关闭';

  @override
  String get previewModeWifi => '仅在使用 Wi-Fi 时';

  @override
  String get previewModeWifiAndData => '使用 Wi-Fi 或移动数据时';

  @override
  String get sortByName => '名称';

  @override
  String get sortByTime => '接收时间';

  @override
  String get sortTargetFavorite => '已加星标';

  @override
  String get sortTargetChannel => '频道';

  @override
  String get sortTargetConversation => '会话';

  @override
  String get sortTargetChatbot => '机器人';

  @override
  String sortSummaryMixed(
    String favorite,
    String channel,
    String conversation,
    String chatbot,
  ) {
    return '已加星标 $favorite · 频道 $channel · 会话 $conversation · 机器人 $chatbot';
  }

  @override
  String get notifForegroundSection => '前台服务';

  @override
  String get notifForegroundService => '前台常驻服务';

  @override
  String get notifForegroundRunningHint => '正在跑（退到后台也会保持连接）';

  @override
  String get notifForegroundStoppedHint => '未运行（只在 App 前台收消息）';

  @override
  String get notifBootSection => '启动';

  @override
  String get notifBoot => '开机自启';

  @override
  String get notifBootHint => '开机后拉起常驻服务（Dart 引擎要等 App 打开才恢复连接）';

  @override
  String get notifBootOpenApp => '开机后直接打开 App';

  @override
  String get notifBootOpenAppHint => '部分系统会拦截开机启动界面，失败也不影响服务';

  @override
  String get notifSelfTestSection => '通知自检';

  @override
  String get notifSendTest => '发一条测试通知';

  @override
  String get notifSendTestHint => '验证通知权限与「回复/已读/贪睡」按钮';

  @override
  String get notifSendTestHintWindows =>
      '验证通知权限与通知身份（Windows 上不提供「回复 / 已读 / 贪睡」按钮）';

  @override
  String get notifTestBody => '这是一条测试通知 🙂';

  @override
  String get notifTestSent => '已发送（看通知栏）';

  @override
  String get notifTestFailed => '发送失败：当前平台没有原生实现或没给通知权限';

  @override
  String get notifClearAll => '清掉所有通知';

  @override
  String get notifSnooze => '免打扰';

  @override
  String get notifLinkOk => '本机链路正常：后台服务在跑，实时通道已连接。';

  @override
  String get notifLinkOkChannelOnly => '本机链路正常：实时通道已连接（本平台没有常驻后台服务）。';

  @override
  String get notifLinkWarnChannelOnly => '本机链路未就绪：实时通道没有连上，请检查网络。';

  @override
  String get notifLinkWarn => '本机链路未完全就绪：请检查后台服务与网络。';

  @override
  String get notifLinkSection => '后台链路';

  @override
  String get notifRealtimeChannel => '实时通道';

  @override
  String get notifNativeService => '原生后台服务';

  @override
  String get snoozeDisable => '关闭免打扰';

  @override
  String get snooze20Minutes => '20 分钟';

  @override
  String get snooze1Hour => '1 小时';

  @override
  String get snooze2Hours => '2 小时';

  @override
  String get snooze4Hours => '4 小时';

  @override
  String get snooze8Hours => '8 小时';

  @override
  String get snooze24Hours => '24 小时';

  @override
  String snoozeSubtitleSchedule(String start, String end) {
    return '定时 $start–$end';
  }

  @override
  String snoozeSubtitleScheduleManual(String start, String end, String left) {
    return '定时 $start–$end，手动剩 $left';
  }

  @override
  String snoozeSubtitleRemaining(String left) {
    return '剩余 $left';
  }

  @override
  String get snoozeStatusOff => '关闭';

  @override
  String get snoozeDisabledToast => '已关闭免打扰';

  @override
  String snoozeEnabledToast(String label) {
    return '已开启免打扰：$label';
  }

  @override
  String get snoozeScheduleTitle => '定时免打扰';

  @override
  String snoozeScheduleOn(String start, String end) {
    return '已开启 $start–$end';
  }

  @override
  String get snoozeTimezone => '时区';

  @override
  String get snoozeTimezoneUnset => '设备时区（服务端未下发 timezoneUTC）';

  @override
  String get snoozeTimezoneDevice => '设备时区';

  @override
  String get snoozeFootnote =>
      '免打扰期间不再弹出新消息通知（消息仍会正常收到并入库）。免打扰状态保存在服务端，换设备也生效。';

  @override
  String get snoozeScheduleSameTime => '起始与结束时间不能相同';

  @override
  String get snoozeScheduleHint => '在这个时间段内不弹通知（跨午夜也支持）';

  @override
  String get snoozeStartTime => '起始时间';

  @override
  String get snoozeEndTime => '结束时间';

  @override
  String get actionSave => '保存';

  @override
  String get actionSaved => '已保存';

  @override
  String actionSaveFailed(String error) {
    return '保存失败：$error';
  }

  @override
  String actionSetFailed(String error) {
    return '设置失败：$error';
  }

  @override
  String get actionOk => '确定';

  @override
  String get actionContinue => '继续';

  @override
  String get profileEditNotConnected => '还没连上 Chat Server';

  @override
  String get profileEditInvalidNickname => '昵称里有不允许的字符';

  @override
  String get profileEditInvalidEmail => '邮箱格式不对';

  @override
  String get profileEditFromGallery => '从相册选';

  @override
  String get profileEditTakePhoto => '拍照';

  @override
  String get profileEditRemoveAvatar => '移除头像';

  @override
  String get profileEditNickname => '昵称';

  @override
  String get profileEditEmail => '邮箱';

  @override
  String get profileEditDesc => '简介';

  @override
  String get profileEditReadonly => '管理员已设为只读';

  @override
  String get profileEditDescHint => '最多 3 行，所有人可见';

  @override
  String profileEditAccountLine(String account, int id) {
    return '账号：$account　ID：#$id';
  }

  @override
  String get botsTitle => '机器人';

  @override
  String botsLoadFailed(String error) {
    return '加载失败：$error';
  }

  @override
  String get botsEmpty => '没有可用的机器人';

  @override
  String get botsKindSynobot => '系统助手';

  @override
  String get botsKindBroadcast => '通知机器人';

  @override
  String get botsKindChatbot => '聊天机器人';

  @override
  String get botsOpenFailed => '打不开这个机器人的会话';

  @override
  String get e2eeDisabledBanner => '服务端已关闭端到端加密：可以继续查看已建好的加密频道，但新建加密频道会被拒绝。';

  @override
  String get e2eeSetupPasscode => '设置加密口令';

  @override
  String get e2eeSetupPasscodeHint => '生成密钥对；口令用来保护私钥，忘了就找不回';

  @override
  String get e2eeUnlock => '解锁';

  @override
  String get e2eeUnlockHint => '输入口令解出私钥，才能收发加密消息';

  @override
  String get e2eeLock => '锁定';

  @override
  String get e2eeLockHint => '把私钥和频道密钥从内存里清掉';

  @override
  String get e2eeChangePasscode => '修改口令';

  @override
  String get e2eeSyncMembers => '从服务端同步成员状态';

  @override
  String get e2eeSyncMembersHint => '重新拉取成员名单，以及谁无法解密消息的标记';

  @override
  String e2eeSyncedChannels(int n) {
    return '已同步 $n 个加密频道';
  }

  @override
  String get e2eeRenewKey => '更换密钥对';

  @override
  String get e2eeRenewKeyHint => '私钥可能泄露时用：生成新密钥对，把所有加密频道密钥改封给新公钥';

  @override
  String get e2eeReuploadKeys => '重新上传我的频道密钥';

  @override
  String get e2eeReuploadKeysHint => '本地换过密钥对 / 服务端副本丢了时用';

  @override
  String get e2eeUploaded => '已上传';

  @override
  String get e2eeUploadFailed => '上传失败';

  @override
  String get e2eeResetIdentity => '清除本机加密身份';

  @override
  String get e2eeResetIdentityHint => '会丢失已加密频道的历史消息解密能力';

  @override
  String get e2eeChannelsSection => '加密频道';

  @override
  String get e2eeNoChannels => '还没有频道';

  @override
  String e2eeBrokenUsers(String names) {
    return '$names 解不开（可修复）';
  }

  @override
  String e2eeConversationNumbered(int id) {
    return '会话 #$id';
  }

  @override
  String get e2eeFix => '修复';

  @override
  String get e2eeNoneEncrypted => '这台服务器上还没有加密频道';

  @override
  String get e2eeNoneEncryptedHint => '在 Synology Chat 客户端里开启一个 —— 这台服务器目前还没有';

  @override
  String get e2eeKeyStateReady => '频道密钥已就绪';

  @override
  String get e2eeKeyStateLocked => '已锁定：先输口令解锁';

  @override
  String get e2eeKeyStateMissing => '解不开：密钥对变了或不是封给你的';

  @override
  String get e2eeKeyStateNotEncrypted => '未加密';

  @override
  String get e2eeEnabled => '加密已开启';

  @override
  String get e2eeEnterPasscode => '输入加密口令';

  @override
  String get e2eeUnlocked => '已解锁';

  @override
  String get e2eeUnlockFailed => '解锁失败';

  @override
  String get e2eeCurrentPasscode => '当前口令';

  @override
  String get e2eeNewPasscode => '新口令';

  @override
  String get e2eePasscodeUpdated => '口令已更新';

  @override
  String get e2eeChangeFailedOld => '修改失败：旧口令不对';

  @override
  String get e2eeRenewKeyConfirmTitle => '更换密钥对？';

  @override
  String get e2eeRenewKeyConfirmBody =>
      '会生成一对新的密钥，并把所有加密频道/归档的密钥改成封给新公钥。旧私钥作废后无法再解密\"只用旧私钥封过\"的内容；其它设备需要重新同步密钥。\n\n换完之后仍要继续使用之前的加密频道。';

  @override
  String get e2eeRenewedOk => '已更换密钥对并重新登记';

  @override
  String get e2eeRenewFailed => '更换失败（口令不对或服务端拒绝）';

  @override
  String get e2eeResetConfirmTitle => '清除本机加密身份？';

  @override
  String get e2eeResetConfirmBody =>
      '清掉之后需要重新设置口令；已经加过密的频道如果没人能再分发密钥，历史消息就永远解不开了。';

  @override
  String get e2eeResetAction => '清除';

  @override
  String get e2eeNoPublicKeys => '没有查到任何成员的公钥';

  @override
  String e2eeRescueWho(int id) {
    return '把频道密钥重新封给谁？（频道 #$id）';
  }

  @override
  String get e2eeRescueBrokenTag => '  ⚠ 解不开';

  @override
  String get e2eeKeysResent => '已重发密钥';

  @override
  String get e2eeRescueFailed => '修复失败';

  @override
  String get e2eePasscode => '口令';

  @override
  String get e2eePasscodeRequired => '口令不能为空';

  @override
  String get e2eeStatusOff => '未开启端到端加密';

  @override
  String get e2eeStatusLocked => '已开启，当前锁定';

  @override
  String get e2eeStatusUnlocked => '已开启并解锁';

  @override
  String e2eePublicKey(String key) {
    return '我的公钥：$key';
  }

  @override
  String get e2eeCopyPublicKey => '复制公钥';

  @override
  String get e2eePublicKeyCopied => '已复制公钥';

  @override
  String e2eeBrokenChannelCount(int n) {
    return '有 $n 个频道解不开';
  }

  @override
  String get e2eeUndecryptable => '🔒 无法解密（缺少频道密钥）';

  @override
  String get e2eeEncryptedFile => '加密文件';

  @override
  String get e2eeServerIdentityExists => '服务端已有加密身份，请用原口令解锁而不是重新设置';

  @override
  String e2eeBadPasscodeOrKey(String error) {
    return '口令不对，或私钥已损坏（$error）';
  }

  @override
  String get e2eeWrongOldPasscode => '旧口令不对';

  @override
  String e2eeRenewKeyFailed(String error) {
    return '更换密钥对失败：$error';
  }

  @override
  String get e2eeNoRecipientKey => '对方还没有公钥，修不了';

  @override
  String get passcodeRepeat => '再输一遍';

  @override
  String get passcodeMismatch => '两次输入不一致';

  @override
  String get passcodeWrong => '口令不对';

  @override
  String get passcodeFieldLabel4 => '口令（4 位数字）';

  @override
  String get passcodeMust4Digits => '必须是 4 位数字';

  @override
  String get passcodeSetTitle => '设置应用锁口令';

  @override
  String get passcodeEnterToDisable => '输入当前口令以关闭';

  @override
  String get passcodeEnabledToast => '应用锁已开启';

  @override
  String passcodeEnableBioTitle(String label) {
    return '启用$label解锁？';
  }

  @override
  String passcodeEnableBioBody(String app, String label) {
    return '开启后，打开 $app 时可以直接用$label解锁，不用每次输入 4 位口令。口令依然有效。';
  }

  @override
  String get passcodeNotNow => '暂不';

  @override
  String get passcodeEnable => '启用';

  @override
  String passcodeUnlockWithLabel(String label) {
    return '$label解锁';
  }

  @override
  String get passcodeBioHint => '开锁时可以直接用生物识别，口令仍可随时使用';

  @override
  String get passcodeReauthInterval => '重新认证间隔';

  @override
  String get passcodeLockNow => '立即锁定';

  @override
  String get passcodeBiometric => '生物识别';

  @override
  String get passcodeFace => '面容';

  @override
  String get passcodeFingerprint => '指纹';

  @override
  String get passcodeLocked => '已锁定';

  @override
  String get passcodeBiometricFailed => '生物识别未通过，请输入口令';

  @override
  String passcodeEnterDigits(int n) {
    return '输入 $n 位数字口令';
  }

  @override
  String passcodeUnlockWith(String label) {
    return '用$label解锁';
  }

  @override
  String get notifyNewMessage => '新消息';

  @override
  String get notifyEmptyMessage => '（空消息）';

  @override
  String notifyAttachment(String label) {
    return '[附件] $label';
  }

  @override
  String notifyPollOptions(int n) {
    return '[投票] $n 个选项';
  }

  @override
  String get notifyReminderTitle => '提醒';

  @override
  String notifyAggTitle(int n) {
    return '$n 条新消息';
  }

  @override
  String notifyAggTitleChannel(int n, String channel) {
    return '$n 条新消息 | $channel';
  }

  @override
  String get notifyReminderBody => '嗨！以下是您关于这条消息的提醒。';

  @override
  String notifyReminderBodyWith(String preview) {
    return '嗨！以下是您关于「$preview」的提醒。';
  }

  @override
  String get devTierLow => '入门';

  @override
  String get devTierMedium => '中端';

  @override
  String get devTierHigh => '高端';

  @override
  String devCoresCount(int n) {
    return '$n 核';
  }

  @override
  String get devSpecUnknown => '规格未知';

  @override
  String get errUnknown => '未知错误';

  @override
  String get errBadRequest => '请求无效';

  @override
  String get errApiNotFound => 'API 不存在';

  @override
  String get errMethodNotFound => '方法不存在';

  @override
  String get errApiVersionUnsupported => 'API 版本不支持';

  @override
  String get errNoPermission => '无权限';

  @override
  String get errSessionTimeout => '会话超时，请重新登录';

  @override
  String get errSessionInterrupted => '会话被中断';

  @override
  String get errHandleUpload => '上传处理失败';

  @override
  String get errProcessRelay => '中继处理失败';

  @override
  String get errProcessEntry => '入口处理失败';

  @override
  String get errProcessLib => '模块处理失败';

  @override
  String get errCompoundStop => '复合请求中止';

  @override
  String get errCompoundReject => '复合请求被拒';

  @override
  String get errNoRequiredParam => '缺少必需参数';

  @override
  String get errNotAllowUpload => '不允许上传';

  @override
  String get errNotAllowDemo => '演示模式不允许该操作';

  @override
  String get errInternal => '服务端内部错误';

  @override
  String get errProcessName => '进程名错误';

  @override
  String get errSidNotFound => '会话不存在，请重新登录';

  @override
  String get errRequestParameterInvalid => '请求参数无效';

  @override
  String get errNoMatchLibEntry => '找不到对应的模块入口';

  @override
  String get errNoAppPrivilege => '没有该应用的权限';

  @override
  String get errAuthInvalidPassword => '账号或密码错误';

  @override
  String get errAuthAccountDisabled => '账号已停用';

  @override
  String get errAuthPermissionDenied => '权限被拒';

  @override
  String get errAuthOtpRequired => '需要两步验证码';

  @override
  String get errAuthOtpInvalid => '验证码错误';

  @override
  String get errAuthPortalPortInvalid => '门户端口无效';

  @override
  String get errAuthOtpEnforced => '该账号被强制要求两步验证';

  @override
  String get errAuthMaxTries => '尝试次数过多，请稍后再试';

  @override
  String get errAuthPasswordExpiredCantChange => '密码已过期且不允许自行修改';

  @override
  String get errAuthPasswordExpired => '密码已过期，需修改';

  @override
  String get errAuthPasswordMustChange => '必须先修改密码';

  @override
  String get errAuthAccountLocked => '账号已锁定';

  @override
  String get chatErrNoSuchUser => '没有这个用户（CHAT_ERR_NO_SUCH_USER）';

  @override
  String get chatErrNotInChannel => '不在该频道（CHAT_ERR_NOT_IN_CHANNEL）';

  @override
  String get chatErrPostNotFound => '消息不存在（CHAT_ERR_POST_NOT_FOUND）';

  @override
  String get chatErrChannelNotFound => '频道不存在（CHAT_ERR_CHANNEL_NOT_FOUND）';

  @override
  String get chatErrNoPermission => '无权限（CHAT_ERR_NO_PERMISSION）';

  @override
  String get chatErrDuplicatedTag => '标签重复（CHAT_ERR_DUPLICATED_TAG）';

  @override
  String get chatErrInvalidAvatar => '头像无效（CHAT_ERR_INVALID_AVATAR）';

  @override
  String get chatErrInvalidRecord => '记录无效（CHAT_ERR_INVALID_RECORD）';

  @override
  String get chatErrKeyPairNotExist => '密钥对不存在（CHAT_ERR_KEY_PAIR_NOT_EXIST）';

  @override
  String get chatErrExceedMaxFileSize =>
      '文件超过大小上限（CHAT_ERR_EXCEED_MAX_FILE_SIZE）';

  @override
  String get chatErrSendTooFrequently => '发送过于频繁（CHAT_ERR_SEND_TOO_FREQUENTLY）';

  @override
  String get chatErrChannelGlobalHide =>
      '频道被全局隐藏（CHAT_ERR_CHANNEL_GLOBAL_HIDE）';

  @override
  String get chatErrServerDbMigrate => '服务端数据库迁移中（CHAT_ERR_SERVER_DB_MIGRATE）';

  @override
  String get chatErrDuplicatedChannelName =>
      '频道名重复（CHAT_ERR_DUPLICATED_CHANNEL_NAME）';

  @override
  String get chatErrChannelKeyNotExist =>
      '频道密钥不存在（CHAT_ERR_CHANNEL_KEY_NOT_EXIST）';

  @override
  String get chatErrNotAllowEncryption =>
      '不允许加密（CHAT_ERR_NOT_ALLOW_ENCRYPTION）';

  @override
  String get chatErrChannelEncrypted => '频道已加密（CHAT_ERR_CHANNEL_ENCRYPTED）';

  @override
  String get chatErrUserDuplicated => '用户重复（CHAT_ERR_USER_DUPLICATED）';

  @override
  String get chatErrUserInvalid => '用户无效（CHAT_ERR_USER_INVALID）';

  @override
  String get chatErrAccountTypeInvalid =>
      '账号类型无效（CHAT_ERR_ACCOUNT_TYPE_INVALID）';

  @override
  String get chatErrNotAllowHttp => '不允许 HTTP（CHAT_ERR_NOT_ALLOW_HTTP）';

  @override
  String get chatErrNotAllowGuestLogin =>
      '不允许访客登录（CHAT_ERR_NOT_ALLOW_GUEST_LOGIN）';

  @override
  String apiUnknownErrorCode(int code) {
    return '错误码 $code';
  }

  @override
  String get apiRequestFailed => '请求失败';

  @override
  String get apiDownloadFailed => '下载失败';

  @override
  String get apiEmptyDownload => '空下载';

  @override
  String get apiEmptyResponse => '空响应';

  @override
  String get apiNonTextResponse => '非文本响应';

  @override
  String get apiTunnelNotStarted => '隧道未启动（tcpPort == 0）';

  @override
  String get apiTunnelRequestFailed => '隧道请求失败';

  @override
  String get apiTunnelUploadFailed => '隧道上传失败';

  @override
  String get apiTunnelDownloadFailed => '隧道下载失败';

  @override
  String apiResponseNotJsonObject(String what) {
    return '$what: 响应不是 JSON 对象';
  }

  @override
  String apiResponseNotJson(String what, String preview) {
    return '$what: 响应不是合法 JSON（前 120 字节: $preview）';
  }

  @override
  String apiX509ExpectedSequence(String got) {
    return '期望 SEQUENCE，得到 0x$got';
  }

  @override
  String apiX509ExpectedBitString(String got) {
    return '期望 BIT STRING，得到 0x$got';
  }

  @override
  String get apiX509NotSequence => 'RSA 公钥内容不是 SEQUENCE';

  @override
  String get apiX509NoNOrE => 'RSA 公钥里没找到 n / e 两个 INTEGER';

  @override
  String get errNoCompressPermission =>
      '这个账号没有压缩权限（DSM → 控制面板 → 应用程序权限 → File Station）';

  @override
  String get errNoExtractPermission =>
      '这个账号没有解压权限（DSM → 控制面板 → 应用程序权限 → File Station）';

  @override
  String get errNoPathPermission => '没有权限访问该位置';

  @override
  String get errTargetNotFound => '目标位置不存在（可能已被移动或删除）';

  @override
  String get errSearchUnavailable => '搜索结果暂时不可用，请稍后再试';

  @override
  String get errTooManyRequests => '请求过于频繁，请稍后再试';

  @override
  String get errNoFileService => '这台 NAS 没有开启文件服务';

  @override
  String get errFileServiceVersionMismatch => '这台 NAS 的文件服务版本不兼容';

  @override
  String get errBadPathOrName => '参数不被接受（可能是路径或文件名）';

  @override
  String get errLoginExpired => '登录已过期，请重新登录';

  @override
  String chatSearchFromUsers(int count) {
    return '来自 $count 人';
  }

  @override
  String chatSearchInChannels(int count) {
    return '在 $count 个频道';
  }

  @override
  String chatSearchMentions(int count) {
    return '提到 $count 人';
  }

  @override
  String get chatSearchByTime => '按时间';

  @override
  String get chatFilterStar => '星标';

  @override
  String get chatFilterUrl => '链接';

  @override
  String get chatFilterFile => '文件';

  @override
  String get chatFilterReaction => '表情回应';

  @override
  String get chatFilterPin => '置顶';

  @override
  String get chatFilterVote => '投票';

  @override
  String get apiSetReactionNeedsSticker =>
      'setReaction 需要 stickerId 或 stickerName';

  @override
  String get apiAnonymousPromoteUnsupported =>
      '这台服务器的 SYNO.Chat.Channel.Anonymous 不支持 promote';

  @override
  String get apiFileIdOrObjectIdRequired => 'fileId 与 objectId 至少要给一个';

  @override
  String get apiNodeVersionListNoParamShape => '这个版本的服务端不支持查看节点版本列表';

  @override
  String get apiRenameNeedsObjectId => '重命名前需要先定位这个文件，请重试一次';

  @override
  String get officeFormatMs => 'Office 文件';

  @override
  String get fotoSpacePersonal => '个人空间';

  @override
  String get fotoSpaceTeam => '共享空间';

  @override
  String get noteWrongPasscode => '口令不对，或这段内容不是加密笔记';

  @override
  String get noteNotBase64 => '这段内容不是 Base64，不是加密笔记';

  @override
  String get noteNoSaltedHeader => '没有 \"Salted__\" 容器头，不是本方案的密文';

  @override
  String get e2eeNoIdentity => '还没有设置 E2EE 身份';

  @override
  String get e2eeNoChannelKeySeal => '本地没有这个频道的密钥，封不了';

  @override
  String get e2eeNoChannelKeyToEncrypt => '没有频道密钥，不能发到加密频道';

  @override
  String get e2eeNoChannelKey => '没有频道密钥';

  @override
  String get apiCompoundMissingResult => 'SYNO.Entry.Request: 响应缺少 result 数组';

  @override
  String get apiSocketDisconnected => '连接已断开';

  @override
  String apiPingTimeout(String duration) {
    return 'ping 超时（$duration 未收到 ping/pong）';
  }

  @override
  String get dtoActionUpload => '上传';

  @override
  String get dtoActionDownload => '下载';

  @override
  String get dtoActionCopy => '复制';

  @override
  String get dtoActionMove => '移动';

  @override
  String get dtoActionDelete => '删除';

  @override
  String get dtoTaskGeneric => '任务';

  @override
  String dtoTaskTitleMore(String label, String name, int count) {
    return '$label · $name 等 $count 项';
  }

  @override
  String get dtoFileTaskCompress => '压缩';

  @override
  String get dtoFileTaskExtract => '解压';

  @override
  String get dtoFileTaskSize => '统计大小';

  @override
  String get dtoFileTaskChecksum => '计算校验值';

  @override
  String get dtoShareRoleViewer => '仅查看';

  @override
  String get dtoShareRolePreviewer => '仅预览';

  @override
  String get dtoShareRoleCommenter => '可评论';

  @override
  String get dtoShareRolePreviewComment => '仅预览+评论';

  @override
  String get dtoShareRoleOrganizer => '可管理';

  @override
  String get dtoCanEdit => '可编辑';

  @override
  String get dtoNotePermReadOnly => '只读';

  @override
  String get dtoNotebookPreset => '我的记事本';

  @override
  String get dtoNotebookUntitled => '未命名记事本';

  @override
  String get dtoNoteUntitled => '无标题笔记';

  @override
  String get dtoPriorityLow => '低';

  @override
  String get dtoPriorityMedium => '中';

  @override
  String get dtoPriorityHigh => '高';

  @override
  String get dtoPriorityNone => '无';

  @override
  String get dtoVersionUntitled => '未命名版本';

  @override
  String get dtoEditorDeleted => '已删除用户';

  @override
  String get dtoCalEveryDay => '每天';

  @override
  String get dtoCalEveryWeek => '每周';

  @override
  String get dtoCalEveryMonth => '每月';

  @override
  String get dtoCalEveryYear => '每年';

  @override
  String get dtoCalRepeat => '重复';

  @override
  String dtoCalEvery(int interval, String unit) {
    return '每 $interval $unit';
  }

  @override
  String get dtoCalMonthWeekday => '按月内第几个星期几';

  @override
  String dtoCalEndCount(int count) {
    return '共 $count 次';
  }

  @override
  String dtoCalEndDate(String date) {
    return '到 $date';
  }

  @override
  String get dtoCalUnitDay => '天';

  @override
  String get dtoCalUnitWeek => '周';

  @override
  String get dtoCalUnitMonth => '个月';

  @override
  String get dtoCalUnitYear => '年';

  @override
  String get dtoCalUnitTimes => '次';

  @override
  String get dtoCalWeekdaySunday => '周日';

  @override
  String get dtoCalWeekdayMonday => '周一';

  @override
  String get dtoCalWeekdayTuesday => '周二';

  @override
  String get dtoCalWeekdayWednesday => '周三';

  @override
  String get dtoCalWeekdayThursday => '周四';

  @override
  String get dtoCalWeekdayFriday => '周五';

  @override
  String get dtoCalWeekdaySaturday => '周六';

  @override
  String get dtoCalWeekdaySep => '、';

  @override
  String get regionUnitMetric => '公制';

  @override
  String get regionUnitImperial => '英制';

  @override
  String get regionUnitUk => '英制（英国）';

  @override
  String get regionUnitAuto => '跟随地区';

  @override
  String get regionWindForce => '级';

  @override
  String get regionBeaufort0 => '无风';

  @override
  String get regionBeaufort1 => '软风';

  @override
  String get regionBeaufort2 => '轻风';

  @override
  String get regionBeaufort3 => '微风';

  @override
  String get regionBeaufort4 => '和风';

  @override
  String get regionBeaufort5 => '清风';

  @override
  String get regionBeaufort6 => '强风';

  @override
  String get regionBeaufort7 => '疾风';

  @override
  String get regionBeaufort8 => '大风';

  @override
  String get regionBeaufort9 => '烈风';

  @override
  String get regionBeaufort10 => '狂风';

  @override
  String get regionBeaufort11 => '暴风';

  @override
  String get regionBeaufort12 => '飓风';

  @override
  String regionWindText(int level, String name) {
    return '$level 级（$name）';
  }

  @override
  String get regionUnknown => '未确定';

  @override
  String get regionSourceManual => '手动指定';

  @override
  String get regionSourceDeviceLocation => '手机定位';

  @override
  String get regionSourceEventGps => '日程地点（GPS）';

  @override
  String get regionSourceEventAddress => '日程地点（文字）';

  @override
  String get regionSourceCalendarTimezone => '日历时区';

  @override
  String get regionSourceDeviceLocale => '设备地区';

  @override
  String regionLabel(String where, String source) {
    return '$where（$source）';
  }

  @override
  String get wxProviderNwsName => 'NWS（美国官方）';

  @override
  String get wxProviderNwsNote => '美国国家气象局，官方源、免 key';

  @override
  String get wxProviderQweatherName => '和风天气 QWeather';

  @override
  String get wxProviderQweatherNote => '中国境内体验最好（要自己的 key）';

  @override
  String get wxProviderMetNoName => 'MET Norway';

  @override
  String get wxProviderMetNoNote => '挪威气象局，欧洲数据好、免 key';

  @override
  String get wxProviderOpenMeteoName => 'Open-Meteo';

  @override
  String get wxProviderOpenMeteoNote => '全球、免 key、一次拿当前+逐日+逐小时';

  @override
  String get wxProviderWttrName => 'wttr.in';

  @override
  String get wxProviderWttrNote => '兜底源（列表里最后一个）';

  @override
  String get wxErrNwsNoForecast => 'NWS 没返回预报地址（这个点可能不在覆盖范围内）';

  @override
  String get wxErrQweatherNoKey => '和风天气需要 API Key（在设置里填）';

  @override
  String wxErrHttpStatus(int code) {
    return '天气接口返回 $code';
  }

  @override
  String wxErrHttpStatusBody(int code, String body) {
    return '天气接口返回 $code：$body';
  }

  @override
  String get wxErrNotJson => '天气接口返回的不是 JSON（可能被网关拦了）';

  @override
  String get wxErrNoData => '天气接口没有返回数据';

  @override
  String wxErrConnectTimeout(String host) {
    return '连接 $host 超时（检查网络）';
  }

  @override
  String wxErrSlowResponse(String host) {
    return '$host 响应太慢';
  }

  @override
  String wxErrNoConnection(String host) {
    return '连不上 $host（国内可能需要代理）';
  }

  @override
  String wxErrRequestFailed(String url, String error) {
    return '请求 $url 失败：$error';
  }

  @override
  String get wxWindN => '北';

  @override
  String get wxWindNe => '东北';

  @override
  String get wxWindE => '东';

  @override
  String get wxWindSe => '东南';

  @override
  String get wxWindS => '南';

  @override
  String get wxWindSw => '西南';

  @override
  String get wxWindW => '西';

  @override
  String get wxWindNw => '西北';

  @override
  String wxWindDir(String dir) {
    return '$dir风';
  }

  @override
  String get wxCodeClear => '晴';

  @override
  String get wxCodeMainlyClear => '少云';

  @override
  String get wxCodePartlyCloudy => '多云';

  @override
  String get wxCodeOvercast => '阴';

  @override
  String get wxCodeFog => '雾';

  @override
  String get wxCodeDrizzle => '毛毛雨';

  @override
  String get wxCodeLightRain => '小雨';

  @override
  String get wxCodeModerateRain => '中雨';

  @override
  String get wxCodeFreezingRain => '冻雨';

  @override
  String get wxCodeHeavyRain => '大雨';

  @override
  String get wxCodeLightSnow => '小雪';

  @override
  String get wxCodeModerateSnow => '中雪';

  @override
  String get wxCodeHeavySnow => '大雪';

  @override
  String get wxCodeSnowGrains => '雪粒';

  @override
  String get wxCodeRainShowers => '阵雨';

  @override
  String get wxCodeModerateRainShowers => '中阵雨';

  @override
  String get wxCodeViolentRainShowers => '强阵雨';

  @override
  String get wxCodeSnowShowers => '阵雪';

  @override
  String get wxCodeThunderstorm => '雷阵雨';

  @override
  String get wxCodeThunderstormHail => '雷阵雨伴冰雹';

  @override
  String get wxCodeUnknown => '未知';

  @override
  String get holidayKindPublic => '法定节假日';

  @override
  String get holidayKindTraditional => '传统节日';

  @override
  String get holidayKindSolarTerm => '节气';

  @override
  String get holidayKindObservance => '纪念日';

  @override
  String get holidayKindWorkday => '调休上班';

  @override
  String get holidayKindReligious => '宗教节日';

  @override
  String get holidaySourceOpenHolidays => 'OpenHolidays';

  @override
  String get holidaySourceNager => 'Nager.Date';

  @override
  String get holidaySourceLunar => '本地农历';

  @override
  String holidaySourceFailed(String source, String error) {
    return '$source 取数失败：$error';
  }

  @override
  String holidayNoPublicSource(String cc) {
    return '$cc 没有公开的法定节假日数据源，这里只有农历与传统节日';
  }

  @override
  String get holidayNoRegion => '还没有确定地区，先只显示农历信息';

  @override
  String holidayNoSourceFor(String country) {
    return '暂时没有 $country 的公开节假日数据源';
  }

  @override
  String get holidayRegionGeneric => '该地区';

  @override
  String get holidayNewYear => '元旦';

  @override
  String get holidayLabour => '劳动节';

  @override
  String get holidayChristmas => '圣诞节';

  @override
  String get holidayGoodFriday => '耶稣受难日';

  @override
  String get holidayEasterMonday => '复活节星期一';

  @override
  String get holidayEasterSunday => '复活节';

  @override
  String get holidayNationalDay => '国庆节';

  @override
  String get holidayMidAutumn => '中秋节';

  @override
  String get holidayDragonBoat => '端午节';

  @override
  String get holidayQingming => '清明节';

  @override
  String get holidaySpringFestival => '春节';

  @override
  String get holidayAllSaints => '万圣节';

  @override
  String get holidayAssumption => '圣母升天节';

  @override
  String get holidayEpiphany => '主显节';

  @override
  String get holidayWomensDay => '国际妇女节';

  @override
  String get holidayAllSouls => '万灵节';

  @override
  String get regionCountryCN => '中国';

  @override
  String get regionCountryHK => '中国香港';

  @override
  String get regionCountryMO => '中国澳门';

  @override
  String get regionCountryTW => '中国台湾';

  @override
  String get regionCountryJP => '日本';

  @override
  String get regionCountryKR => '韩国';

  @override
  String get regionCountryKP => '朝鲜';

  @override
  String get regionCountrySG => '新加坡';

  @override
  String get regionCountryMY => '马来西亚';

  @override
  String get regionCountryTH => '泰国';

  @override
  String get regionCountryVN => '越南';

  @override
  String get regionCountryID => '印度尼西亚';

  @override
  String get regionCountryPH => '菲律宾';

  @override
  String get regionCountryIN => '印度';

  @override
  String get regionCountryAE => '阿联酋';

  @override
  String get regionCountrySA => '沙特阿拉伯';

  @override
  String get regionCountryIL => '以色列';

  @override
  String get regionCountryTR => '土耳其';

  @override
  String get regionCountryGB => '英国';

  @override
  String get regionCountryIE => '爱尔兰';

  @override
  String get regionCountryFR => '法国';

  @override
  String get regionCountryDE => '德国';

  @override
  String get regionCountryES => '西班牙';

  @override
  String get regionCountryIT => '意大利';

  @override
  String get regionCountryNL => '荷兰';

  @override
  String get regionCountryBE => '比利时';

  @override
  String get regionCountryAT => '奥地利';

  @override
  String get regionCountryCH => '瑞士';

  @override
  String get regionCountrySE => '瑞典';

  @override
  String get regionCountryNO => '挪威';

  @override
  String get regionCountryDK => '丹麦';

  @override
  String get regionCountryFI => '芬兰';

  @override
  String get regionCountryPL => '波兰';

  @override
  String get regionCountryCZ => '捷克';

  @override
  String get regionCountryHU => '匈牙利';

  @override
  String get regionCountryPT => '葡萄牙';

  @override
  String get regionCountryGR => '希腊';

  @override
  String get regionCountryRU => '俄罗斯';

  @override
  String get regionCountryUA => '乌克兰';

  @override
  String get regionCountryUS => '美国';

  @override
  String get regionCountryCA => '加拿大';

  @override
  String get regionCountryMX => '墨西哥';

  @override
  String get regionCountryBR => '巴西';

  @override
  String get regionCountryAR => '阿根廷';

  @override
  String get regionCountryCL => '智利';

  @override
  String get regionCountryCO => '哥伦比亚';

  @override
  String get regionCountryPE => '秘鲁';

  @override
  String get regionCountryEG => '埃及';

  @override
  String get regionCountryZA => '南非';

  @override
  String get regionCountryNG => '尼日利亚';

  @override
  String get regionCountryKE => '肯尼亚';

  @override
  String get regionCountryAU => '澳大利亚';

  @override
  String get regionCountryNZ => '新西兰';

  @override
  String get holidayNoteSep => '；';

  @override
  String get photoSectionTimeline => '时间轴';

  @override
  String get photoSectionFolders => '文件夹';

  @override
  String get photoSectionFavorites => '收藏';

  @override
  String get photoNewAlbum => '新建相册';

  @override
  String get photoCreateFolder => '创建文件夹';

  @override
  String get photoRefresh => '刷新';

  @override
  String get photoSwitchSpace => '切换空间';

  @override
  String get photoEmptyTimelineTitle => '还没有照片';

  @override
  String get photoEmptyTimelineMessage =>
      '个人空间里还没有被索引的照片。\n用 DSM 的「Synology Photos」或手机备份上传后，这里就会出现。';

  @override
  String get photoEmptyAlbumsTitle => '还没有相册';

  @override
  String get photoEmptyAlbumsMessage =>
      '点右下角「新建相册」，或打开一张照片用「加入相册」。\n（自动备份不在本 App 范围内）';

  @override
  String photoItemCount(int count) {
    return '$count 项';
  }

  @override
  String get photoConditionalAlbum => '条件相册';

  @override
  String get photoShare => '共享';

  @override
  String get photoShared => '已共享';

  @override
  String get photoEmptyFoldersTitle => '没有可见的文件夹';

  @override
  String get photoEmptyFoldersMessage =>
      '相册的「文件夹」视图跟 DSM 里 photo 共享的目录结构一致，普通用户默认只能看到自己的 home/Photos。';

  @override
  String get photoMore => '更多';

  @override
  String get photoRename => '重命名';

  @override
  String get photoDeleteFolder => '删除文件夹';

  @override
  String get photoSharedWithMe => '共享给我的';

  @override
  String get photoEmptyFavoritesTitle => '还没有收藏';

  @override
  String get photoEmptyFavoritesMessage => '在大图页点右下角的星标就能收藏，收藏会同步到 NAS。';

  @override
  String get photoAlbumActions => '相册操作';

  @override
  String get photoDeleteAlbum => '删除相册';

  @override
  String get photoEmptyAlbumTitle => '这个相册是空的';

  @override
  String get photoEmptyAlbumMessage => '在时间轴里打开一张照片，用「加入相册」把它放进来。';

  @override
  String get photoRenameAlbum => '重命名相册';

  @override
  String get photoAlbumNameHint => '相册名字';

  @override
  String photoAlbumCreateHelper(int count) {
    return '会把当前 $count 张放进新相册';
  }

  @override
  String get photoCreate => '创建';

  @override
  String get photoAlbumNameRequired => '相册名不能为空';

  @override
  String photoAlbumCreated(String name) {
    return '已创建「$name」';
  }

  @override
  String photoAlbumCreateFailed(String error) {
    return '建相册失败：$error';
  }

  @override
  String photoAddToAlbumTitle(int count) {
    return '加入相册（$count 张）';
  }

  @override
  String get photoClose => '关闭';

  @override
  String get photoNewAlbumAndAdd => '新建相册并加入';

  @override
  String get photoNoNormalAlbums => '还没有普通相册（条件相册不能手动加照片）';

  @override
  String get photoAddedToAlbum => '已加入相册';

  @override
  String photoAddedPartial(int count) {
    return '已加入，$count 张没加进去（可能已在别的相册）';
  }

  @override
  String photoAddToAlbumFailed(String error) {
    return '加入相册失败：$error';
  }

  @override
  String photoRenamed(String name) {
    return '已改名为「$name」';
  }

  @override
  String photoRenameFailed(String error) {
    return '改名失败：$error';
  }

  @override
  String get photoDeleteAlbumConfirm => '删除相册？';

  @override
  String photoDeleteAlbumMessage(String name) {
    return '「$name」会被删掉，里面的照片仍然留在照片库里。';
  }

  @override
  String photoAlbumDeleted(String name) {
    return '已删除「$name」';
  }

  @override
  String photoDeleteFailed(String error) {
    return '删除失败：$error';
  }

  @override
  String get photoFolderNameHint => '文件夹名称';

  @override
  String get photoFolderNameRequired => '文件夹名称不能为空';

  @override
  String photoFolderCreated(String name) {
    return '文件夹「$name」已创建';
  }

  @override
  String photoFolderCreateFailed(String error) {
    return '建文件夹失败：$error';
  }

  @override
  String get photoNewFolder => '新文件夹';

  @override
  String get photoRenameFolder => '重命名文件夹';

  @override
  String get photoDeleteFolderConfirm => '删除文件夹？';

  @override
  String photoDeleteFolderMessage(String name) {
    return '「$name」会被删除并移入回收站（可在 Drive 里恢复）。';
  }

  @override
  String photoFolderDeleted(String name) {
    return '已删除「$name」';
  }

  @override
  String get photoFavorited => '已加入收藏';

  @override
  String get photoUnfavorited => '已取消收藏';

  @override
  String photoFavoriteFailed(String error) {
    return '收藏失败：$error';
  }

  @override
  String get photoCoverSet => '已设为封面';

  @override
  String photoCoverFailed(String error) {
    return '设封面失败：$error';
  }

  @override
  String get photoRemovedFromAlbum => '已移出相册';

  @override
  String photoRemoveFailed(String error) {
    return '移出失败：$error';
  }

  @override
  String photoOpenedWith(String name) {
    return '已交给系统应用打开：$name';
  }

  @override
  String photoDownloaded(String name) {
    return '已下载：$name';
  }

  @override
  String photoDownloadFailed(String error) {
    return '下载失败：$error';
  }

  @override
  String get photoTakenAt => '拍摄时间';

  @override
  String get photoFileSize => '大小';

  @override
  String get photoKind => '类型';

  @override
  String get photoVideo => '视频';

  @override
  String get photoKindPhoto => '照片';

  @override
  String get photoFolder => '所在文件夹';

  @override
  String get photoYes => '是';

  @override
  String get photoNo => '否';

  @override
  String get photoAddToAlbum => '加入相册';

  @override
  String get photoSetAsCover => '设为相册封面';

  @override
  String photoRemoveFromAlbumNamed(String name) {
    return '移出「$name」';
  }

  @override
  String get photoInfo => '信息';

  @override
  String get photoOpenWithOther => '用其他应用打开';

  @override
  String get photoNotConnected => '还没连上 NAS';

  @override
  String get photoUnfavorite => '取消收藏';

  @override
  String get photoOpenInPlayer => '用系统播放器打开';

  @override
  String photoOpenVideoFailed(String error) {
    return '打不开这个视频：$error';
  }

  @override
  String get photoDecodeFailed => '解不开这张图';

  @override
  String get photoErrSpacePermission =>
      '没有这个空间的权限（Synology Photos 的「共享空间」权限由管理员分配）';

  @override
  String get photoErrNotFound => '这个照片/相册不存在或已被删除';

  @override
  String get photoErrAccount => '这个账号没有 Synology Photos 权限';

  @override
  String get photoErrDsmDenied =>
      'DSM 拒绝了相册应用权限（控制面板 → 应用程序权限 → Synology Photos）';

  @override
  String get photoErrNotInstalled => '这台 NAS 没有安装 Synology Photos';

  @override
  String get photoErrApiVersion => '这台 NAS 的相册接口版本不支持这个功能';

  @override
  String photoGroupMonth(int year, int month) {
    return '$year 年 $month 月';
  }

  @override
  String photoGroupDay(int year, int month, int day) {
    return '$year 年 $month 月 $day 日';
  }

  @override
  String get photoLoadFailed => '加载失败';

  @override
  String get photoRetry => '重试';

  @override
  String get calWeekdayMinSun => '日';

  @override
  String get calWeekdayMinMon => '一';

  @override
  String get calWeekdayMinTue => '二';

  @override
  String get calWeekdayMinWed => '三';

  @override
  String get calWeekdayMinThu => '四';

  @override
  String get calWeekdayMinFri => '五';

  @override
  String get calWeekdayMinSat => '六';

  @override
  String get calToday => '今天';

  @override
  String get calEventFab => '日程';

  @override
  String get calSubtitle => 'Synology Calendar';

  @override
  String get calBack => '返回';

  @override
  String get calCalendarGroups => '日历分组';

  @override
  String get calMonthView => '月';

  @override
  String get calWeekView => '周';

  @override
  String get calDayView => '日';

  @override
  String get calPrevMonth => '上个月';

  @override
  String get calNextMonth => '下个月';

  @override
  String get calPrevWeek => '上一周';

  @override
  String get calNextWeek => '下一周';

  @override
  String get calPrevDay => '前一天';

  @override
  String get calNextDay => '后一天';

  @override
  String calMonthTitle(int year, int month) {
    return '$year年$month月';
  }

  @override
  String calWeekRangeTitle(int month, int day) {
    return '$month月$day日 那一周';
  }

  @override
  String calDayTitle(int month, int day, String weekday) {
    return '$month月$day日 · 周$weekday';
  }

  @override
  String calDayHeader(int month, int day, String weekday) {
    return '$month 月 $day 日 · 周$weekday';
  }

  @override
  String get calEmptyCell => '空';

  @override
  String get calNoTitle => '(无标题)';

  @override
  String get calAllDay => '全天';

  @override
  String get calTimeUnknown => '时间未知';

  @override
  String calDueDate(String date) {
    return '截止 $date';
  }

  @override
  String calCreator(String name) {
    return '创建者 $name';
  }

  @override
  String calTimezone(String tz) {
    return '时区 $tz';
  }

  @override
  String get calOccurrenceSuffix => '（这是其中一次）';

  @override
  String calTodoSection(int open) {
    return '待办（$open）';
  }

  @override
  String calTodoSectionDone(int open, int done) {
    return '待办（$open）· 已完成 $done';
  }

  @override
  String get calMarkDone => '标记完成';

  @override
  String get calMarkUndone => '标记未完成';

  @override
  String get calCleanDone => '清空已完成';

  @override
  String get calNew => '新建';

  @override
  String get calNewTodo => '新建待办';

  @override
  String get calEditTodo => '编辑待办';

  @override
  String get calEditEvent => '编辑日程';

  @override
  String get calNewEvent => '新建日程';

  @override
  String get calEditThis => '编辑本次';

  @override
  String get calEditAll => '编辑整个';

  @override
  String get calOnlyThis => '仅此日程';

  @override
  String get calAllEvents => '所有日程';

  @override
  String get calReadOnlyCalendar => '只读日历';

  @override
  String get calCanWrite => '可写';

  @override
  String get calSelectAll => '全选';

  @override
  String get calDayNoEventsTitle => '这一天没有日程';

  @override
  String get calDayNoEventsMessage => '点右下角「日程」新建，或换一天看看';

  @override
  String get calLoadFailed => '日历加载失败';

  @override
  String get calNoWritableCalendar => '没有可写入的日历';

  @override
  String get calNoWritableTodoCalendar => '没有可写入的待办日历';

  @override
  String get calEventTitleLabel => '标题';

  @override
  String get calStartLabel => '开始';

  @override
  String get calEndLabel => '结束';

  @override
  String get calDescriptionOptional => '描述（可选）';

  @override
  String get calTitleRequired => '标题不能为空';

  @override
  String get calRepeatNever => '不重复';

  @override
  String get calRepeatForever => '永不结束';

  @override
  String get calRepeatCountLabel => '重复次数';

  @override
  String get calRepeatUntilDate => '到某一天';

  @override
  String get calRepeatUntil => '重复到';

  @override
  String get calPickDate => '选择日期';

  @override
  String calRepeatIntervalLabel(String unit) {
    return '间隔（每 N $unit）';
  }

  @override
  String calRepeatPrefixed(String rule) {
    return '重复：$rule';
  }

  @override
  String get calRepeatLockedHint => '改这里只作用于这一天，其它几次不受影响';

  @override
  String calDeletedOnce(String summary) {
    return '已删除这一次「$summary」';
  }

  @override
  String calDeletedSeries(String summary) {
    return '已删除整个重复日程「$summary」';
  }

  @override
  String calDeleted(String summary) {
    return '已删除「$summary」';
  }

  @override
  String calCreated(String summary) {
    return '已创建「$summary」';
  }

  @override
  String calUpdatedOnce(String summary) {
    return '已更新这一次「$summary」';
  }

  @override
  String calUpdatedSeries(String summary) {
    return '已更新整个重复日程「$summary」';
  }

  @override
  String calUpdated(String summary) {
    return '已更新「$summary」';
  }

  @override
  String calCreatedTodo(String summary) {
    return '已创建待办「$summary」';
  }

  @override
  String get calTodoSaved => '已保存待办';

  @override
  String get calCleanedDone => '已清空已完成待办';

  @override
  String calDeleteFailed(String error) {
    return '删除失败：$error';
  }

  @override
  String calCreateFailed(String error) {
    return '创建失败：$error';
  }

  @override
  String calUpdateFailed(String error) {
    return '更新失败：$error';
  }

  @override
  String calTodoActionFailed(String error) {
    return '操作失败：$error';
  }

  @override
  String calToggleFailed(String error) {
    return '标记失败：$error';
  }

  @override
  String calClearFailed(String error) {
    return '清空失败：$error';
  }

  @override
  String get calTodoContent => '待办内容';

  @override
  String get calTodoContentRequired => '待办内容不能为空';

  @override
  String get calTodoCalendar => '待办日历';

  @override
  String get calDone => '已完成';

  @override
  String get calDueTime => '截止时间';

  @override
  String get calNotSet => '未设置';

  @override
  String get calClearDue => '清除截止时间';

  @override
  String get calTodoNoteOptional => '备注（可选）';

  @override
  String get calDeleteTodo => '删除待办';

  @override
  String get calEnvTitle => '天气与节假日';

  @override
  String get calEnvRegionPending => '地区判定中';

  @override
  String get calEnvRegionPendingDots => '地区判定中…';

  @override
  String get calEnvAutoLocate => '跟随手机定位';

  @override
  String get calEnvLocating => '正在定位…';

  @override
  String get calEnvLocateButton => '定位中…';

  @override
  String get calEnvNoFix => '没拿到位置（定位开关关着？）';

  @override
  String get calEnvNoPermission => '还没授权 —— 点下面的「用当前位置」授权';

  @override
  String calEnvLocated(String coords) {
    return '已定位：$coords';
  }

  @override
  String calEnvAccuracy(String m) {
    return '精度 ${m}m';
  }

  @override
  String get calEnvLocateOff => '关着，用下面的手选地点/时区推算';

  @override
  String get calEnvUseCurrent => '用当前位置';

  @override
  String get calEnvPlaceLabel => '地点（天气按这里的坐标取）';

  @override
  String get calEnvPlaceHint => '城市或地名，如 杭州';

  @override
  String get calEnvSearch => '搜索';

  @override
  String get calEnvSearching => '搜索中…';

  @override
  String get calEnvPlaceNotFound => '没找到这个地名（不编一个给你）';

  @override
  String calEnvSearchFailed(String error) {
    return '搜索失败：$error';
  }

  @override
  String calEnvPlaceCurrent(String name, String lat, String lon) {
    return '当前地点：$name（$lat, $lon）';
  }

  @override
  String get calEnvClear => '清除';

  @override
  String get calEnvRegion => '地区';

  @override
  String get calEnvAuto => '自动';

  @override
  String get calEnvWeatherBg => '日历背景显示天气动画';

  @override
  String get calEnvWeatherBgHint => '按选中那天的天气（雨/雪/云/日光/星空），已虚化，不挡文字';

  @override
  String get calEnvUnitsLabel => '单位（默认按地区自动）';

  @override
  String get calEnvUnitsByRegion => '按地区';

  @override
  String calEnvUnitsSummary(
    String temp,
    String wind,
    String precip,
    String pressure,
    String vis,
  ) {
    return '当前：温度 $temp · 风 $wind · 降水 $precip · 气压 $pressure · 能见度 $vis';
  }

  @override
  String get calEnvWeatherSource => '天气源';

  @override
  String get calEnvNoProvider => '当前地区没有可用天气源';

  @override
  String calEnvUsingProvider(String provider) {
    return '当前会用：$provider';
  }

  @override
  String get calEnvQweatherKeyLabel => '和风天气 API Key（可选，存系统安全存储）';

  @override
  String get calEnvQweatherKeyHint => '只有用和风源时才需要';

  @override
  String get calEnvQweatherKeySaved => '和风 key 已保存';

  @override
  String get calEnvSaveKey => '保存 key';

  @override
  String get calEnvKeyConfigured => '已配置（内容不回显）';

  @override
  String get calEnvKeyMissing => '未配置';

  @override
  String get calEnvHolidaySources => '节假日数据源';

  @override
  String get calEnvHolidaySourcesNote =>
      '公历法定假日来自在线假日库（欧洲含州省），农历、节气与中国法定调休在本地算（离线可用）。宗教节日按观月宣布，会标「预计」。';

  @override
  String get calEnvRefetch => '重新获取';

  @override
  String get calEnvDone => '完成';

  @override
  String get calEnvBadgeRest => '休';

  @override
  String get calEnvBadgeWork => '班';

  @override
  String calEnvWeatherFailed(String error) {
    return '天气取不到：$error';
  }

  @override
  String get calEnvWeatherLoading => '正在取天气…';

  @override
  String get calEnvNoPlace => '天气要位置 —— 点这里授权';

  @override
  String calEnvFeelsLike(String temp) {
    return ' 体感 $temp°';
  }

  @override
  String get calEnvTodayForecast => '当天预报';

  @override
  String calEnvPrecip(String value, String unit) {
    return '降水 $value$unit';
  }

  @override
  String calEnvSunrise(String time) {
    return '日出 $time';
  }

  @override
  String calEnvSunset(String time) {
    return '日落 $time';
  }

  @override
  String get calEnvNowLabel => '此刻';

  @override
  String calEnvHumidity(String value) {
    return '湿度 $value%';
  }

  @override
  String calEnvWind(String text) {
    return '风 $text';
  }

  @override
  String calEnvPressure(String value, String unit) {
    return '气压 $value$unit';
  }

  @override
  String calEnvDaily(String text) {
    return '当日 $text';
  }

  @override
  String get calEnvHourNow => '现在';

  @override
  String calEnvHour(int hour) {
    return '$hour时';
  }

  @override
  String calEnvApprox(String name) {
    return '预计 $name';
  }

  @override
  String get calEnvWorkdaySuffix => '（上班）';

  @override
  String calEnvSourceWeather(String name) {
    return '天气 $name';
  }

  @override
  String calEnvSourceHoliday(String sources) {
    return '节假日 $sources';
  }

  @override
  String get calEditLabel => '编辑';

  @override
  String get noteErrNoPermission =>
      '这个账号没有 Note Station 权限（DSM → 控制面板 → 应用程序权限 → Note Station）';

  @override
  String get noteErrAppDenied => 'DSM 拒绝了 Note Station 应用权限（同上）';

  @override
  String get noteErrParam => '参数不被接受（笔记接口要求 JSON 编码的参数）';

  @override
  String get noteErrNotInstalled => '这台 NAS 没有安装 / 没开启 Note Station';

  @override
  String get noteErrVersion => '这台 NAS 的 Note Station 版本不兼容';

  @override
  String noteConflictBanner(int n) {
    return '$n 条笔记两边都改过，点这里选保留哪一份';
  }

  @override
  String notePendingCount(int n) {
    return '$n 条改动待同步';
  }

  @override
  String get noteOfflineCached => '离线 · 显示上次同步的内容';

  @override
  String noteOfflineCachedPending(int n) {
    return '离线 · 显示缓存内容 · $n 条改动待同步';
  }

  @override
  String get noteSyncing => '正在同步…';

  @override
  String get noteSyncNow => '立即同步';

  @override
  String get noteAll => '全部';

  @override
  String get noteNoNotebooks => '还没有笔记本';

  @override
  String get noteEncrypted => '加密';

  @override
  String get noteSearchHint => '搜索标题 / 摘要 / 标签';

  @override
  String get noteCloseSearch => '关闭搜索';

  @override
  String get noteSearchNotes => '搜索笔记';

  @override
  String get noteSyncMenu => '同步（拉取+推送）';

  @override
  String get noteTodoTitle => '待办';

  @override
  String get noteTags => '标签';

  @override
  String get noteRecycle => '回收站';

  @override
  String get noteNewNotebook => '新建笔记本';

  @override
  String get noteNewNote => '新建笔记';

  @override
  String get noteOpenNotesFailed => '打不开笔记';

  @override
  String get noteEmptySearch => '没有匹配的笔记';

  @override
  String get noteEmptyNotebook => '这个笔记本还是空的';

  @override
  String get noteEmptyAll => '还没有笔记';

  @override
  String get noteEmptyGeneric => '这里是空的';

  @override
  String get noteNotebookName => '笔记本名';

  @override
  String noteNotebookCreateFailed(String error) {
    return '建不了：$error';
  }

  @override
  String get noteRenameNotebook => '重命名笔记本';

  @override
  String get noteDeleteNotebookWithNotes => '删除（里面的笔记一起删）';

  @override
  String noteNotebookUpdateFailed(String error) {
    return '改不了：$error';
  }

  @override
  String get noteDeleteNotebook => '删除笔记本';

  @override
  String noteDeleteNotebookConfirm(String title) {
    return '「$title」和里面的笔记都会被删除。';
  }

  @override
  String noteNotebookDeleteFailed(String error) {
    return '删不了：$error';
  }

  @override
  String get noteEmptyCreateHint => '点右下角「新建笔记」写第一条';

  @override
  String get noteShare => '共享';

  @override
  String get noteVersionHistory => '版本历史';

  @override
  String get noteUnlockPrompt => '输入口令';

  @override
  String get noteOpenFailed => '打不开这条笔记';

  @override
  String noteModifiedAt(String time) {
    return '修改于 $time';
  }

  @override
  String get noteEncryptedAes => '加密笔记（AES256）';

  @override
  String get noteOfflineCacheNotice => '离线 · 这是本机缓存的内容';

  @override
  String get noteWrongPasswordRetry => '口令不对，再试一次';

  @override
  String noteUnlockFailed(String error) {
    return '解锁失败：$error';
  }

  @override
  String get noteIsEncrypted => '这条笔记已加密';

  @override
  String get notePasswordLocalOnly => '正文在服务端是密文，口令只在本地内存里用（不会上传、不会落盘）';

  @override
  String get notePasscode => '口令';

  @override
  String get noteUnlockTitle => '输入口令解锁';

  @override
  String get noteWrongPassword => '口令不对';

  @override
  String get noteLocked => '已锁定';

  @override
  String noteTagFailed(String error) {
    return '改标签失败：$error';
  }

  @override
  String get noteUnlockToEdit => '先解锁才能编辑';

  @override
  String get noteDeleteTitle => '删除笔记';

  @override
  String noteDeleteConfirm(String title) {
    return '「$title」会放进回收站，可以再恢复。';
  }

  @override
  String get noteDeletedOffline => '已离线删除，联网后同步';

  @override
  String get noteMovedToRecycle => '已放进回收站';

  @override
  String noteDeleteFailed(String error) {
    return '删除失败：$error';
  }

  @override
  String get noteHistoryFailed => '读不到版本历史';

  @override
  String get noteNoVersions => '还没有历史版本';

  @override
  String noteVersionN(String n) {
    return '版本 $n';
  }

  @override
  String get noteVersionRestored => '已恢复该版本';

  @override
  String noteRestoreFailed(String error) {
    return '恢复失败：$error';
  }

  @override
  String get noteRestore => '恢复';

  @override
  String get noteNewTagHint => '新建标签';

  @override
  String get noteAddTag => '添加标签';

  @override
  String get noteNoTagsYet => '还没有标签';

  @override
  String get noteTagsUnavailable => '标签列表没取到（网络或权限）；可能有标签没显示出来';

  @override
  String get noteRecycleEmpty => '回收站是空的';

  @override
  String get noteRecycleEmptyMessage => '删掉的笔记会先来这里，30 天后由 NAS 自动清';

  @override
  String get noteUntitled => '未命名笔记';

  @override
  String get noteActions => '操作';

  @override
  String get noteRecycleRestore => '还原';

  @override
  String get notePurge => '彻底删除';

  @override
  String noteRecycleActionFailed(String error) {
    return '操作失败：$error';
  }

  @override
  String get noteRestored => '已还原';

  @override
  String notePurgeConfirm(String title) {
    return '「$title」将被永久删除，无法恢复。';
  }

  @override
  String get notePurged => '已彻底删除';

  @override
  String get noteRecycleCleanTitle => '清空回收站';

  @override
  String noteRecycleCleanConfirm(int count) {
    return '$count 条笔记将被永久删除，无法恢复。';
  }

  @override
  String noteRecycleCleanFailed(String error) {
    return '清空失败：$error';
  }

  @override
  String get noteOpenTagsFailed => '打不开标签';

  @override
  String get noteTagCreateHint => '打开一条笔记 → 右上角「标签」→ 输入新名字，标签就会出现在这里';

  @override
  String noteTagCount(int n) {
    return '$n 条笔记';
  }

  @override
  String get noteTagNameHint => '标签名';

  @override
  String get noteRenameTag => '重命名标签';

  @override
  String get noteDeleteTag => '删除标签';

  @override
  String noteDeleteTagConfirm(String title) {
    return '「$title」会从所有笔记上摘掉（笔记本身不动）。';
  }

  @override
  String get noteTodoOpen => '未完成';

  @override
  String get noteOpenTodosFailed => '打不开待办';

  @override
  String get noteNoTodos => '没有待办';

  @override
  String get noteNoTodosMessage => '在 NoteStation 里建的任务会出现在这里';

  @override
  String noteTodoSaved(String title) {
    return '已保存「$title」';
  }

  @override
  String get noteTodoOfflineChecked => '已离线勾选，联网后同步';

  @override
  String noteTodoUpdateFailed(String error) {
    return '改不了：$error';
  }

  @override
  String get noteExpandSubtasks => '展开子任务';

  @override
  String get noteCollapseSubtasks => '收起子任务';

  @override
  String notePriorityLabel(String priority) {
    return '$priority优先级';
  }

  @override
  String noteDue(String date) {
    return '截止 $date';
  }

  @override
  String get noteSubtask => '子任务';

  @override
  String get noteAddSubtask => '加子任务';

  @override
  String get noteNewSubtask => '新建子任务';

  @override
  String get noteTaskHint => '要做什么';

  @override
  String get noteDueDate => '截止日期';

  @override
  String get noteClearDueDate => '清除截止日期';

  @override
  String get notePriority => '优先级';

  @override
  String get noteStar => '加星标';

  @override
  String get noteComment => '备注';

  @override
  String get noteOptional => '可选';

  @override
  String get notePriorityHint => '提示：优先级取值是服务端枚举（无/低/中/高），乱传会被判成\"缺少参数\"';

  @override
  String notePriorityValue(String priority) {
    return '优先级：$priority';
  }

  @override
  String get noteTaskNameRequired => '任务名不能为空';

  @override
  String noteTodoSaveFailed(String error) {
    return '保存失败：$error';
  }

  @override
  String get noteDeleteTodo => '删除待办';

  @override
  String noteDeleteTodoConfirm(String title) {
    return '「$title」会被删除。';
  }

  @override
  String noteTodoDeleteFailed(String error) {
    return '删除失败：$error';
  }

  @override
  String get noteFromNas => '从 NAS 选图片';

  @override
  String get noteInsert => '插入';

  @override
  String noteInsertCount(int n) {
    return '插入 $n';
  }

  @override
  String get noteUpOneLevel => '上一级';

  @override
  String noteFolderOpenFailed(String error) {
    return '打不开这个文件夹\n$error';
  }

  @override
  String get noteNoImagesHere => '这里没有图片';

  @override
  String get noteEmptyBody => '这条笔记还是空的';

  @override
  String get noteImageAttachment => '图片附件';

  @override
  String noteImageOpenFailed(String name) {
    return '$name 打不开';
  }

  @override
  String get noteImageInNote => '笔记里的图片';

  @override
  String noteImageOpenError(String error) {
    return '打不开这张图：$error';
  }

  @override
  String get noteConflictTitle => '同步冲突';

  @override
  String get noteNoConflicts => '没有冲突了';

  @override
  String get noteNoConflictsMessage => '两边的内容现在是一致的。';

  @override
  String noteConflictUntitled(int n) {
    return '未命名 $n';
  }

  @override
  String get noteConflictExplain => '这条笔记在你离线修改之后，服务端也变了。选一边保留，另一个版本会被丢弃。';

  @override
  String get noteConflictLocal => '我的改动';

  @override
  String get noteConflictServer => '服务端版本';

  @override
  String get noteConflictLocalEmpty => '（本地内容为空）';

  @override
  String get noteConflictServerEmpty => '（服务端内容是空的）';

  @override
  String get noteConflictServerFetchFailed =>
      '没抓到服务端正文（离线或加密）。\n选「用服务端的」会再抓一次。';

  @override
  String get noteConflictKeepLocal => '保留我的';

  @override
  String get noteConflictUseServer => '用服务端的';

  @override
  String get noteConflictUsedLocal => '已用本地内容覆盖服务端';

  @override
  String get noteConflictUsedServer => '已改为服务端版本';

  @override
  String noteConflictMore(int n) {
    return '有 $n 条冲突，先显示前 5 条';
  }

  @override
  String notePendingSyncFailed(String error) {
    return '有未同步的改动：$error';
  }

  @override
  String noteOverwriteFailed(String error) {
    return '覆盖失败：$error';
  }

  @override
  String noteDiscardFailed(String error) {
    return '放弃本地改动失败：$error';
  }

  @override
  String get notePasscodeRequired => '口令不能为空';

  @override
  String notePasscodeTooLong(int n) {
    return '口令最长 $n 个字符（与官方一致）';
  }

  @override
  String noteShareFailed(String error) {
    return '失败：$error';
  }

  @override
  String get notePublicShareOff => '已关闭公开分享';

  @override
  String notePublicShareOn(String perm) {
    return '公开分享：$perm';
  }

  @override
  String noteShareLinkFailed(String error) {
    return '取分享链接失败：$error';
  }

  @override
  String noteSharedWithGroup(String name, String perm) {
    return '群组「$name」：$perm';
  }

  @override
  String noteSharedWithUser(String name, String perm) {
    return '用户「$name」：$perm';
  }

  @override
  String noteShareRemoved(String name) {
    return '已取消「$name」的共享';
  }

  @override
  String get noteEncryptedNoShare => '加密笔记不能共享';

  @override
  String get noteEncryptedNoShareMessage =>
      'Synology Note Station 的加密笔记不支持公开分享或共享给他人。\n取消加密后再来。';

  @override
  String get notePublicShare => '公开分享';

  @override
  String get noteAnyoneWithLink => '拿到链接的任何人都能打开';

  @override
  String noteCurrentPerm(String perm) {
    return '当前权限：$perm';
  }

  @override
  String get notePublicOffHint => '关闭时只有被单独分享的账号能看';

  @override
  String get noteGettingLink => '正在取链接…';

  @override
  String get noteNoLink => '还没有链接';

  @override
  String get noteCopyLink => '复制链接';

  @override
  String get noteLinkCopied => '链接已复制';

  @override
  String get noteRefetchLink => '重新取链接';

  @override
  String get noteSharedWith => '已分享给';

  @override
  String get noteSharedTitle => '我分享的';

  @override
  String get noteSharedEmpty => '还没有你分享出去的内容';

  @override
  String get noteSharedNotebooks => '分享出去的笔记本';

  @override
  String get noteSharedNotes => '分享出去的笔记';

  @override
  String get noteBackgroundSyncTitle => '后台同步';

  @override
  String get noteBackgroundSyncHint =>
      'Android 会每隔一段时间在后台拉取一次笔记改动；关掉只停后台，不影响你在 App 里手动同步';

  @override
  String get noteBackgroundSyncEnable => '允许后台同步';

  @override
  String get noteBackgroundSyncNow => '立即同步一次';

  @override
  String get noteBackgroundSyncQueued => '已排队，稍后自动同步';

  @override
  String get noteBackgroundSyncFailed => '设置失败';

  @override
  String get noteNoIndividualShare => '还没有单独分享给任何账号';

  @override
  String get noteUser => '用户';

  @override
  String get noteGroup => '群组';

  @override
  String get noteInherited => '继承自笔记本';

  @override
  String get noteStopSharing => '取消共享';

  @override
  String get noteAddUserGroup => '添加用户或群组';

  @override
  String get noteSearchDsmAccount => '搜索 DSM 用户或群组';

  @override
  String noteAccountSearchFailed(String error) {
    return '搜不到账号：$error';
  }

  @override
  String get noteNoMatchingAccount => '没有匹配的账号';

  @override
  String get notePermReadOnlyDesc => '只能查看，不能改';

  @override
  String get notePermReadWriteDesc => '可以编辑内容';

  @override
  String get noteEditNote => '编辑笔记';

  @override
  String get noteAiAssistant => 'AI 助手';

  @override
  String get noteMarkdownImageHint => 'Markdown 模式用 `![说明](图片链接)` 插图';

  @override
  String get noteInsertImage => '插入图片';

  @override
  String get noteEncryptNote => '加密这条笔记';

  @override
  String get noteStopEncrypt => '取消加密';

  @override
  String get notePreview => '预览';

  @override
  String get noteContinueEditing => '继续编辑';

  @override
  String get noteUseMarkdown => '用 Markdown 编辑';

  @override
  String get noteBackToRich => '切回富文本编辑';

  @override
  String get noteEncryptionOffToast => '已取消加密（保存时按明文存）';

  @override
  String get noteEncryptionOnToast => '保存后这条笔记将被加密（口令只在本地用于加解密）';

  @override
  String get noteSetPasscode => '设置加密口令';

  @override
  String get notePasscodeConfirm => '确认口令';

  @override
  String get notePasscodeMismatch => '两次输入的口令不一致';

  @override
  String get notePasscodeMissing => '缺少口令';

  @override
  String get notePickFromLibrary => '从相册选';

  @override
  String get noteTakePhoto => '拍一张';

  @override
  String get notePickFromFiles => '从文件选';

  @override
  String get notePickFromNas => '从 NAS 选';

  @override
  String get noteFileStationImages => 'FileStation 里的图片';

  @override
  String noteImagePickFailed(String error) {
    return '选图失败：$error';
  }

  @override
  String get noteThisNote => '这条笔记';

  @override
  String get noteSummaryEmpty => '笔记还是空的，先写点内容再总结';

  @override
  String get notePassageBody => '正文';

  @override
  String get noteUseMarkdownTitle => '用 Markdown 编辑？';

  @override
  String get noteUseMarkdownKeepSource =>
      '这条笔记会按 Markdown 保存：正文存渲染后的 HTML，源码放在 HTML 注释里（官方 App / 网页端看排版，我们这边能继续改源码）。';

  @override
  String get noteUseMarkdownImport =>
      '当前内容会**原样**放进 Markdown 源码框（Markdown 允许直接嵌 HTML），格式不会丢；你可以再慢慢改写成 Markdown 语法。\n\n保存后这条笔记就是 Markdown 笔记了。';

  @override
  String get noteBackToRichTitle => '切回富文本？';

  @override
  String get noteBackToRichMessage =>
      '会把 Markdown **渲染后**载入富文本编辑器（图片/表格等会按渲染结果出现）。\n\n注意：保存之后这条笔记不再带 Markdown 源码，之后打开就是普通富文本笔记。';

  @override
  String get noteSelectNotebookFirst => '先选一个笔记本';

  @override
  String get noteSaveEncryptNeedsPasscode => '保存失败：加密笔记需要口令（先解锁）';

  @override
  String get noteSavedOffline => '已离线保存，联网后自动同步';

  @override
  String get noteMdHint =>
      '# 标题\n\n**粗体**、*斜体*、`行内代码`\n\n- 列表\n- [ ] 待办\n\n> 引用\n\n```\n代码块\n```\n\n| 表格 | 列 |\n| --- | --- |\n| 1 | 2 |\n';

  @override
  String get noteMdBold => '粗体';

  @override
  String get noteMdList => '列表';

  @override
  String get noteMdQuote => '引用';

  @override
  String get noteMdCode => '代码块';

  @override
  String get noteMdTable => '表格';

  @override
  String get noteMdLink => '链接';

  @override
  String get noteMdH1Tip => '# 标题';

  @override
  String get noteMdBoldTip => '**粗体**';

  @override
  String get noteMdListTip => '- 条目';

  @override
  String get noteMdTodoTip => '- [ ] 待办';

  @override
  String get noteMdQuoteTip => '> 引用';

  @override
  String get noteMdLinkTip => '[文字](url)';

  @override
  String get noteMdH1Text => '# 标题\n';

  @override
  String get noteMdBoldText => '**粗体**';

  @override
  String get noteMdListText => '- 条目\n- 条目\n';

  @override
  String get noteMdTodoText => '- [ ] 待办\n';

  @override
  String get noteMdQuoteText => '> 引用\n';

  @override
  String get noteMdCodeText => '```\n代码\n```\n';

  @override
  String get noteMdLinkText => '[文字](https://)';

  @override
  String noteConflictTitleCount(int n) {
    return '同步冲突（$n）';
  }

  @override
  String get noteOpenRecycleFailed => '打不开回收站';

  @override
  String get noteBackToRichConfirm => '切回富文本';

  @override
  String noteSaveFailed(String error) {
    return '保存失败：$error';
  }

  @override
  String get noteMdTodo => '待办';

  @override
  String get fileOfficeNoService => '这台 NAS 上没有 Synology Office（或还没连上）';

  @override
  String get fileOfficeNeedsPassword => '这份文档有口令，需要先输入口令';

  @override
  String fileOfficeConvertUnsupported(int code) {
    return '这个文件转不了（服务端错误码 $code）';
  }

  @override
  String get fileOfficeUnrecognized =>
      'Synology Office 不认这个文件：它多半不是 Office 原生文档（.odoc/.osheet/.oslides），先用「转换为 Office 文档」转一次';

  @override
  String get fileOfficePasswordTitle => '需要文档口令';

  @override
  String get fileOfficePasswordBody => '这份文档有打开口令，转换前要先解开。';

  @override
  String fileOfficePasswordBodyNamed(String name) {
    return '「$name」有打开口令，转换前要先解开。';
  }

  @override
  String get fileOfficePasswordField => '口令';

  @override
  String get fileFavorited => '已收藏';

  @override
  String get fileMoreActions => '更多操作';

  @override
  String get fileSharedFolder => '共享文件夹';

  @override
  String fileTodayAt(String time) {
    return '今天 $time';
  }

  @override
  String get fileYesterday => '昨天';

  @override
  String get bookTocTitle => '目录';

  @override
  String get bookTocUnit => '章';

  @override
  String bookTocCount(int n, String source) {
    return '$n 条 · $source';
  }

  @override
  String bookTocCountFiltered(int shown, int total) {
    return '$shown/$total 条';
  }

  @override
  String bookTocNoMatch(String query) {
    return '目录里没有「$query」';
  }

  @override
  String get bookTocFilterHint => '在目录里找章节';

  @override
  String get bookUnsupportedFormat => '这个格式还不支持内嵌阅读';

  @override
  String get bookReasonEncrypted => '带密码（加密）';

  @override
  String get bookReasonMultiVolume => '分卷包（要全部卷才能解）';

  @override
  String get bookReasonDrm => '带 DRM 保护';

  @override
  String get bookReasonCompression => '这种压缩/编码变体本阅读器还没实现';

  @override
  String get bookReasonMissingParts => '缺配套文件（散装书要把正文文件一起传）';

  @override
  String get bookParseFailed => '这本书解析失败（文件可能损坏或带 DRM）';

  @override
  String bookChapterN(int n) {
    return '第 $n 章';
  }

  @override
  String bookSectionN(int n) {
    return '第 $n 节';
  }

  @override
  String bookPageN(int n) {
    return '第 $n 页';
  }

  @override
  String pdfPageOutOfRange(int n) {
    return '页码越界（共 $n 页）';
  }

  @override
  String pdfTooShortBytes(int n) {
    return 'PDF 太短（$n 字节）';
  }

  @override
  String pdfExtractFailed(String error) {
    return '抽取失败：$error';
  }

  @override
  String pdfTocParseFailed(String error) {
    return '解析失败：$error';
  }

  @override
  String get pdfEncrypted => 'PDF 已加密，不尝试解密';

  @override
  String get pdfNoCatalog => '找不到 /Catalog';

  @override
  String get pdfNoPages => '页树里没有页面';

  @override
  String get pdfNoTextStreams => '内容流里没有文字（可能是扫描件/纯图形）';

  @override
  String get fileOpen => '打开';

  @override
  String get fileOpenFolder => '打开文件夹';

  @override
  String get fileDownloadToDevice => '下载到本机';

  @override
  String get fileDownloadForbidden => '管理员禁止了下载';

  @override
  String get fileManage => '管理';

  @override
  String get fileCopyTo => '复制到…';

  @override
  String get fileMoveTo => '移动到…';

  @override
  String get fileExtractHere => '解压到此处';

  @override
  String get fileAddFavorite => '加入收藏';

  @override
  String get fileProperties => '属性';

  @override
  String fileExtFile(String ext) {
    return '$ext 文件';
  }

  @override
  String get filePropPath => '路径';

  @override
  String filePropSizeWithBytes(String size, String bytes) {
    return '$size（$bytes 字节）';
  }

  @override
  String get filePropModified => '修改时间';

  @override
  String get filePropCreated => '创建时间';

  @override
  String get filePropOwner => '属主';

  @override
  String get filePropGroup => '属组';

  @override
  String get filePropMountType => '挂载类型';

  @override
  String get filePropRealPath => '真实路径';

  @override
  String get filePropPerm => '可读 / 可写';

  @override
  String get filePropNoDownload => '禁止下载';

  @override
  String get fileWormProtected => '受保护（不可改）';

  @override
  String get fileServerProbe => '服务端实测';

  @override
  String get filePropDiskSize => '占盘大小';

  @override
  String get fileLoading => '读取中…';

  @override
  String get filePropRealModified => '真实修改时间';

  @override
  String fileOwnerUnavailable(String error) {
    return '看不到（$error）';
  }

  @override
  String get fileMd5FailedSome => '有文件算不了（可能没有读取权限）';

  @override
  String get fileMd5LostResult => '服务端没保住结果（这台 DSM 上 MD5 任务只活几十毫秒），请重试';

  @override
  String get fileCalculating => '正在计算…';

  @override
  String get fileCopied => '已复制';

  @override
  String get fileMd5Hint => '未计算 · 由服务端算，大文件要等一会儿';

  @override
  String get fileCalculate => '计算';

  @override
  String get fileUploading => '正在上传…';

  @override
  String get fileContinueInBackground => '后台继续';

  @override
  String get filePropOwnerName => '所有者';

  @override
  String get driveTeamFolders => '团队文件夹';

  @override
  String get driveSharedWithMe => '共享给我';

  @override
  String get driveMoreTitle => 'Drive 更多';

  @override
  String driveSectionHud(String section) {
    return 'Synology Drive · $section';
  }

  @override
  String drivePersonalLabels(int n) {
    return '$n 个个人标签';
  }

  @override
  String get driveManageLabels => '管理标签';

  @override
  String get driveLabelsLoadFailed => '读不到标签';

  @override
  String get driveNoLabelsMessage =>
      '标签是 Drive 里的\"多对多分类\"。\n点右上角「管理标签」新建，或在文件的「⋮ → 标签」里加。';

  @override
  String get driveSharedLabel => '共享标签';

  @override
  String get drivePersonalLabel => '个人标签';

  @override
  String get driveTrashEmpty => '回收站是空的';

  @override
  String driveTrashCount(int n) {
    return '$n 项';
  }

  @override
  String driveTrashUsage(String size) {
    return '占用 $size';
  }

  @override
  String get driveEmptyTrashBody => '回收站里的文件会被彻底删除，这个操作不能撤销。';

  @override
  String get driveEmptyTrashAction => '清空';

  @override
  String get driveTrashEmptied => '已清空回收站';

  @override
  String driveEmptyTrashFailed(String error) {
    return '清空失败：$error';
  }

  @override
  String get driveTrashEmptyMessage => '从「我的 Drive」删掉的文件会先放到这里，\n清空之后才真的没了。';

  @override
  String get driveNoStarredTitle => '还没有星标文件';

  @override
  String get driveNoStarredMessage => '在「我的 Drive」里给文件加星标，这里就能快速找到。';

  @override
  String get driveNoSharedTitle => '没有人共享给你';

  @override
  String get driveNoSharedMessage => '别人通过 Drive 共享给你的文件会出现在这里。';

  @override
  String get driveNoTeamTitle => '没有团队文件夹';

  @override
  String get driveNoTeamMessage => '团队文件夹由管理员在 Drive 管理控制台创建，普通用户可见的部分会出现在这里。';

  @override
  String get driveListOpenFailed => '打不开这个列表';

  @override
  String get driveDeleted => '已删除';

  @override
  String get driveEmptyTrashConfirm => '清空回收站？';

  @override
  String driveLabelCreated(String name) {
    return '已新建标签「$name」';
  }

  @override
  String driveLabelRenamed(String name) {
    return '已改名为「$name」';
  }

  @override
  String get driveLabelColorUpdated => '颜色已更新';

  @override
  String get driveDeleteLabelConfirm => '删除标签？';

  @override
  String driveDeleteLabelBody(String name) {
    return '「$name」会从所有文件上移除（文件本身不受影响）。';
  }

  @override
  String driveLabelDeleted(String name) {
    return '已删除「$name」';
  }

  @override
  String get driveLabelsHud => 'Synology Drive · 个人标签';

  @override
  String get driveNoLabelsManageMessage =>
      '标签是 Drive 里的\"多对多分类\"：\n一个文件可以有多个标签，点右上角新建。';

  @override
  String get driveChangeColor => '改颜色';

  @override
  String get driveLabelsHudFiles => 'Synology Drive · 标签下的文件';

  @override
  String get driveLabelOpenFailed => '打不开这个标签';

  @override
  String get driveLabelNoFiles => '这个标签下还没有文件';

  @override
  String get driveLabelNoFilesMessage => '在文件的「⋮ → 标签」里把它加到这个标签上。';

  @override
  String get driveLabelsUpdated => '标签已更新';

  @override
  String driveLabelPickerTitle(String name) {
    return '标签 · $name';
  }

  @override
  String driveLabelPickerReadFailed(String error) {
    return '读不到标签：$error';
  }

  @override
  String get driveCreateLabelAndCheck => '新建标签并勾选';

  @override
  String get driveChooseColor => '选择颜色';

  @override
  String get fileTasksLoadFailed => '读任务失败';

  @override
  String get fileNoTasks => '没有后台任务';

  @override
  String get driveTasksEmptyMessage =>
      'Synology Drive 的上传/下载/转存任务会出现在这里。\nNAS 目录里的复制、压缩任务在「NAS 文件」那一侧。';

  @override
  String get driveTaskRemove => '从列表移除';

  @override
  String get driveTaskStopAndRemove => '停止并移除';

  @override
  String driveTaskDeleteFailed(String error) {
    return '删除任务失败：$error';
  }

  @override
  String driveSharedWith(String name) {
    return '已共享给 $name';
  }

  @override
  String driveRoleChanged(String name, String role) {
    return '$name 的权限已改为「$role」';
  }

  @override
  String get driveRemoveShareConfirm => '移除共享？';

  @override
  String driveRemoveShareBody(String name, String entry) {
    return '移除后 $name 就不能再访问「$entry」了。';
  }

  @override
  String get driveRemoveShareAction => '移除';

  @override
  String driveRemovedShare(String name) {
    return '已移除 $name';
  }

  @override
  String get driveInvite => '邀请';

  @override
  String get drivePublicLink => '公开链接';

  @override
  String get drivePermanentLink => '永久打开链接';

  @override
  String get drivePermanentLinkNote =>
      '这是文件的永久入口，本页关不掉它。要停止匿名访问，请在「公开分享管理」里关闭公开链接。';

  @override
  String get driveManagePublicSharing => '公开分享管理';

  @override
  String get driveNoPublicLink => '拿不到文件链接（可能没有分享权限）';

  @override
  String get driveOpenInBrowser => '在浏览器打开';

  @override
  String get driveRefreshForLink => '点右上角刷新可以重新获取链接';

  @override
  String get driveSharedWithSection => '已共享给';

  @override
  String get driveSharesLoadFailed => '读不到共享成员';

  @override
  String get driveNoShares => '还没有共享给谁';

  @override
  String get driveNoSharesMessage => '只有你自己能访问。\n点右上角「邀请」把文件共享给 NAS 上的其他账号。';

  @override
  String get driveInheritedFromParent => '继承自上级目录';

  @override
  String get driveChangePermission => '改权限';

  @override
  String get driveSearchPrincipalsHint => '搜索用户或群组';

  @override
  String driveSearchPrincipalsFailed(String error) {
    return '搜不到账号：$error';
  }

  @override
  String get driveNoMatchingAccount => '没有匹配的账号';

  @override
  String get driveChoosePermission => '选择权限';

  @override
  String drivePrincipalWithNickname(String name, String nickname) {
    return '$name（$nickname）';
  }

  @override
  String fileDownloadFailed(String error) {
    return '下载失败：$error';
  }

  @override
  String driveDownloaded(String name) {
    return '已下载：$name';
  }

  @override
  String get driveRestoreConfirm => '恢复到这个版本？';

  @override
  String driveRestoreRevBody(String time, String size) {
    return '$time 的版本（$size）会被恢复成当前内容。\n恢复本身会再生成一个新版本，旧版本不会丢。';
  }

  @override
  String get driveRestore => '恢复';

  @override
  String get driveRestoredPending => '已恢复，稍等几秒生效';

  @override
  String get driveRevisionsOpenFailed => '打不开版本历史';

  @override
  String get driveNoRevisionsMessage => '这个文件只有一份当前内容。\nDrive 会在文件被覆盖修改后保留旧版本。';

  @override
  String get driveVersionCurrent => '当前版本';

  @override
  String driveVersionId(String id) {
    return '版本号 $id';
  }

  @override
  String get driveDownloadVersion => '下载这个版本';

  @override
  String get driveRestoreVersion => '恢复到这个版本';

  @override
  String get driveOfficeNoRevisionsMessage =>
      'Synology Office 文档会在每次编辑保存后记录一个版本。';

  @override
  String driveOfficeHud(String name) {
    return 'Synology Office · $name';
  }

  @override
  String driveFileHud(String name) {
    return 'Synology Drive · $name';
  }

  @override
  String driveOfficeRestoreBody(String label) {
    return '「$label」会变成当前内容；恢复本身也会留下记录，旧版本不会丢。';
  }

  @override
  String driveOfficeRestoreBodyAt(String label, String time) {
    return '「$label」会变成当前内容；（$time）恢复本身也会留下记录，旧版本不会丢。';
  }

  @override
  String driveRestoreFailed(String error) {
    return '恢复失败：$error';
  }

  @override
  String get driveNoNodeId => '服务端没给出这份文档的内部 id，暂时不能命名版本';

  @override
  String get driveVersionNameEdit => '更改版本名称';

  @override
  String get driveVersionNameNew => '创建版本名称';

  @override
  String get driveVersionNameHint => '版本名称';

  @override
  String get driveVersionNameHelper => '命名后这个版本不会被自动清理（空名称 = 恢复成自动版本）';

  @override
  String get driveVersionAutoRestored => '已恢复为自动版本';

  @override
  String driveVersionNamed(String name) {
    return '已命名为「$name」';
  }

  @override
  String driveVersionRenameFailed(String error) {
    return '命名失败：$error';
  }

  @override
  String driveVersionEditors(int n) {
    return '共 $n 人编辑';
  }

  @override
  String get driveVersionFirst => '初始版本';

  @override
  String get driveNameVersion => '命名这个版本';

  @override
  String get driveExportVersion => '导出这个版本';

  @override
  String driveExported(String name) {
    return '已导出：$name';
  }

  @override
  String driveExportFailed(String error) {
    return '导出失败：$error';
  }

  @override
  String get fileSearchTitle => '搜索文件';

  @override
  String get fileSearchHint => '文件名关键词，例如 report';

  @override
  String get fileSearchFailed => '搜索失败';

  @override
  String get fileNoMatches => '没有找到匹配的文件';

  @override
  String get fileNoMatchesHint => '没找到你要的文件？服务端文件索引可能滞后 —— 试试上面的「全局搜索」。';

  @override
  String get fileSearchPrompt => '输入关键词开始搜索';

  @override
  String get fileSearchScope => '搜索范围：你有权限的共享文件夹';

  @override
  String get fileSearchStillRunning => '搜索仍在进行';

  @override
  String get fileSearchStillRunningMessage =>
      '服务端还没搜完这个范围。点「重试」继续等待 —— 结果可能稍后出现。';

  @override
  String get fileFavoritesLoadFailed => '读收藏失败';

  @override
  String get fileNoFavoritesMessage => '在文件的操作菜单里选「加入收藏」';

  @override
  String get fileShareLinksTitle => '分享链接';

  @override
  String get fileCleanInvalidLinks => '清理失效链接';

  @override
  String get fileShareLinksLoadFailed => '读分享链接失败';

  @override
  String get fileNoShareLinks => '没有分享链接';

  @override
  String get fileNoShareLinksMessage => '在文件的操作菜单里选「创建分享链接」';

  @override
  String get fileLinkInvalid => '已失效';

  @override
  String get fileLinkHasPassword => '有密码';

  @override
  String fileLinkExpiresAt(String date) {
    return '至 $date';
  }

  @override
  String get fileDeleteLink => '删除链接';

  @override
  String get fileLinkDetail => '分享链接详情';

  @override
  String get fileLinkDetailServer => '服务端详情';

  @override
  String fileLinkDetailFailed(String reason) {
    return '取不了详情：$reason';
  }

  @override
  String get fileLinkDetailRetry => '重试';

  @override
  String get fileLinkDetailMissing => '服务端没有返回这条链接的详情';

  @override
  String get fileLinkCopyLink => '复制链接';

  @override
  String get fileLinkCopied => '链接已复制';

  @override
  String get fileLinkQrcode => '二维码';

  @override
  String get fileLinkStatus => '状态';

  @override
  String get fileLinkValid => '有效';

  @override
  String get fileLinkStartAt => '生效时间';

  @override
  String get fileLinkOwner => '所有者';

  @override
  String get fileLinkId => '链接 ID';

  @override
  String get fileLinkKindFolder => '文件夹';

  @override
  String get fileLinkKindFile => '文件';

  @override
  String get fileLinkYes => '有';

  @override
  String get fileLinkExpiryLabel => '有效期';

  @override
  String get fileLinkFieldUnknown => '服务端未返回';

  @override
  String get fileLinkNo => '没有';

  @override
  String get fileCleanFinished => '清理已完成';

  @override
  String get fileNoTasksMessage => '压缩 / 解压 / 复制移动 / 统计大小都会出现在这里';

  @override
  String fileTasksFailedCount(int n) {
    return '$n 个文件失败';
  }

  @override
  String fileTaskElapsedMinutes(int n) {
    return '已运行 $n 分钟';
  }

  @override
  String fileTaskElapsedHours(int h, int m) {
    return '已运行 $h 小时 $m 分';
  }

  @override
  String get fileArchiveContents => '查看压缩包内容';

  @override
  String get fileArchiveContentsEmpty => '压缩包里没有条目';

  @override
  String fileArchiveContentsFailed(String reason) {
    return '读不了压缩包：$reason';
  }

  @override
  String get fileArchiveContentsPasswordRetry => '输入密码后重试';

  @override
  String fileArchiveContentsCount(int n) {
    return '共 $n 个条目';
  }

  @override
  String get fileStopTask => '停止任务';

  @override
  String get driveConnectHint => '连上 NAS 就能看「我的 Drive」';

  @override
  String get fileOpenDirFailed => '打不开这个目录';

  @override
  String get fileEmptyDir => '这个目录是空的';

  @override
  String get driveEmptyPersonal => '个人空间（/mydrive）里还没有文件';

  @override
  String get driveMyDrive => '我的 Drive';

  @override
  String get driveStar => '星标';

  @override
  String get driveUnstar => '取消星标';

  @override
  String driveDownloadAs(String format) {
    return '下载为 $format';
  }

  @override
  String get driveConvertToOffice => '转换为 Office 文档';

  @override
  String driveRenamed(String name) {
    return '已重命名为 $name';
  }

  @override
  String get driveDeleteConfirm => '删除？';

  @override
  String driveDeleteBody(String name) {
    return '「$name」会进 Drive 回收站，之后还能恢复。';
  }

  @override
  String driveDeletedItem(String name) {
    return '已删除 $name';
  }

  @override
  String driveConverted(String name) {
    return '已转换为 $name（稍后出现在列表里）';
  }

  @override
  String driveConvertFailed(String error) {
    return '转换失败：$error';
  }

  @override
  String get fileNewFolderHint => '普通文件夹';

  @override
  String get fileNewFolder => '新建文件夹';

  @override
  String get driveUploadFileTitle => '上传文件';

  @override
  String get driveUploadSheetSubtitle => '放进个人空间，Drive 会在一两秒内索引到';

  @override
  String driveCreateInPath(String path) {
    return '创建在「$path」下';
  }

  @override
  String driveCreated(String name) {
    return '已创建 $name';
  }

  @override
  String get driveUploadNotPersonal => '这个位置不是个人空间，暂时不能从这里上传';

  @override
  String driveUploadedIndexing(String name) {
    return '已上传 $name（Drive 索引需要一两秒）';
  }

  @override
  String get fileCacheReadFailed => '读缓存失败';

  @override
  String get fileNewUpload => '新建 / 上传';

  @override
  String get fileNewUploadSemantic => '新建或上传';

  @override
  String get fileOpenLocationFailed => '打不开这个位置';

  @override
  String get fileNoSharedFolders => '没有可访问的共享文件夹';

  @override
  String get fileNoSharedFoldersMessage => '这台 NAS 上没有授予你权限的共享文件夹';

  @override
  String get fileEmptyFolder => '这个文件夹是空的';

  @override
  String get fileWideEmptyTitle => '还没有选中任何项目';

  @override
  String get fileWideEmptyMessage => '在左侧单击选中；双击（或按 Enter）打开。这里显示它的详情';

  @override
  String get fileWideOpenPreview => '打开预览';

  @override
  String get fileWideOpenFolder => '打开文件夹';

  @override
  String fileWideFolderItems(int n) {
    return '$n 项';
  }

  @override
  String get fileWideContentsFailed => '读不到这个文件夹的内容';

  @override
  String fileDownloadCount(int n) {
    return '下载 $n 项';
  }

  @override
  String get fileDownloadCountMessage => '将依次下载到应用的 downloads 目录，可能耗时较长。';

  @override
  String get fileStartDownload => '开始下载';

  @override
  String get fileRenameHelper => '不能包含 / 字符';

  @override
  String get fileTargetFolderHint => '目标文件夹的完整路径';

  @override
  String get fileTargetFolderExample => '例如 /home/Drive/备份';

  @override
  String get fileTaskSubmitted => '任务已提交';

  @override
  String get fileTaskSubmittedWithTip => '任务已提交，可在「任务」里看进度';

  @override
  String get fileArchiveDefaultName => '压缩包';

  @override
  String get fileStartCompress => '开始压缩';

  @override
  String get fileArchiveNameHint => '压缩包文件名';

  @override
  String get fileCreateInCurrentDir => '会创建在当前目录下';

  @override
  String get fileCompressSubmitted => '压缩任务已提交，可在「任务」里看进度';

  @override
  String fileExtractConfirmBody(String name) {
    return '把 $name 解压到当前目录下的同名文件夹？';
  }

  @override
  String get fileExtractSubmitted => '解压任务已提交';

  @override
  String get fileDirSize => '计算文件夹大小';

  @override
  String get fileDirSizeSubmitted => '统计任务已提交';

  @override
  String fileDirSizeSubmittedId(String id) {
    return '统计任务已提交（$id）';
  }

  @override
  String fileDeleteCount(int n) {
    return '删除 $n 项';
  }

  @override
  String fileDeleteOneConfirm(String name) {
    return '确定删除「$name」？此操作不可撤销。';
  }

  @override
  String fileDeleteManyConfirm(int n) {
    return '确定删除这 $n 项？此操作不可撤销。';
  }

  @override
  String get fileDeleted => '已删除';

  @override
  String get fileDownloadedToDownloads => '已下载到 downloads 目录';

  @override
  String fileUploadFromDevice(String target) {
    return '从本机选文件传到「$target」';
  }

  @override
  String fileUploaded(String name) {
    return '已上传 $name';
  }

  @override
  String get fileSortTitle => '排序方式';

  @override
  String fileSelectedCount(int n) {
    return '已选 $n 项';
  }

  @override
  String get fileSelectAll => '全选/取消';

  @override
  String get fileGridViewSwitch => '切换为列表视图';

  @override
  String get fileListViewSwitch => '切换为缩略图视图';

  @override
  String get fileSourceNas => 'NAS 文件';

  @override
  String get fileShareDisabled => '未开启共享链接';

  @override
  String fileStaleCache(String detail) {
    return '显示的是缓存内容：$detail';
  }

  @override
  String get fileSharedFoldersRoot => '共享文件夹';

  @override
  String get sortBySize => '大小';

  @override
  String get sortByModified => '修改时间';

  @override
  String get sortByOwner => '属主';

  @override
  String get sortByGroup => '属组';

  @override
  String get sortByType => '类型';

  @override
  String get sortByCreated => '创建时间';

  @override
  String get fileOfficeExport => 'Office 导出';

  @override
  String get fileUnknownReason => '未知原因';

  @override
  String get fileEmptyFile => '这个文件是空的';

  @override
  String get fileImageDecodeFailed => '解不开这张图';

  @override
  String get fileImageGestureHint => '双击放大 / 再双击复位 · 双指可缩放';

  @override
  String fileImageTooBig(String size) {
    return '这张图 $size，太大了不内嵌显示';
  }

  @override
  String get fileImageTooBigHint => '用右上角的「下载」或「用其他应用打开」看原图';

  @override
  String fileTextHeadOnly(int kb, String size) {
    return '只显示开头 $kb KB（文件共 $size）';
  }

  @override
  String get fileMediaPause => '暂停';

  @override
  String get fileMediaPlay => '播放';

  @override
  String get fileOfficeExtractHint =>
      '（Office 正文由服务端抽取，需要这台 NAS 装了 Synology Office 并且文件在 Drive 索引里）';

  @override
  String get fileOfficeEmptyBody =>
      '服务端抽取到的是空正文：这份文档本身是空的，或者正文全是图片。Synology Office 文档（.odoc/.osheet/.oslides）可以下载后用官方 Office 打开';

  @override
  String fileOfficeReadonlyBody(int n) {
    return '只读 · 服务端抽取的正文（$n 字）';
  }

  @override
  String get fileOfficeNotIndexed =>
      '这台 NAS 上的 Office 正文抽取只认 Drive 索引里的文件。把文件放进「我的 Drive」（或把所在文件夹纳入 Synology Drive）就能在这里直接看正文，现在先交给系统里的 Office 打开。';

  @override
  String get fileWhyVideo => '视频用系统播放器看最稳（不内嵌解码）';

  @override
  String get fileWhyPdf => 'PDF 交给系统/第三方阅读器';

  @override
  String get fileWhyOffice => 'Office 文档交给系统里的 WPS/Office 打开';

  @override
  String get fileWhyArchive => '压缩包要先解开才能看里面的东西';

  @override
  String get fileWhyOther => '这类文件交给系统应用打开';

  @override
  String get fileOpenFailed => '打不开这个文件';

  @override
  String get pdfNoExtractableText => '这份 PDF 没有可提取的文字（可能是扫描件），AI 读不了';

  @override
  String get pdfPrevPage => '上一页';

  @override
  String get pdfNextPage => '下一页';

  @override
  String pdfPageOfTotal(int page, int total) {
    return '第 $page / $total 页';
  }

  @override
  String get pdfLinuxNoPoppler =>
      '这台电脑还没有 PDF 渲染器：装上 poppler-utils（提供 pdftoppm）后重新打开这个文件。';

  @override
  String pdfPageN(int n) {
    return '第 $n 页';
  }

  @override
  String get pdfAskTitle => '问这份 PDF';

  @override
  String get pdfAskHint => '就这份 PDF 提问，例如\"结论是什么\"';

  @override
  String pdfParseFailed(String error) {
    return 'PDF 解析失败：$error';
  }

  @override
  String get pdfParsing => '正在解析 PDF…';

  @override
  String pdfOpenFailedDetail(String error) {
    return '打不开这个 PDF\n$error';
  }

  @override
  String get readerPrevPage => '上一页';

  @override
  String get readerNextPage => '下一页';

  @override
  String pdfPageOf(int page, int total) {
    return '第 $page / $total 页';
  }

  @override
  String get pdfBookmark => '书签';

  @override
  String get pdfLoading => '正在取 PDF…';

  @override
  String get pdfOpenFailed => '打不开这个 PDF';

  @override
  String get bookOpenFailed => '打不开这本书';

  @override
  String get bookServerNoContent => '服务器没有返回内容。';

  @override
  String get bookCannotRead => '这本书暂时不能内嵌阅读';

  @override
  String get bookDownloadHint => '右上角可以下载后用其他应用打开。';

  @override
  String get bookUntitled => '未命名';

  @override
  String bookAiLabel(String title, int n) {
    return '《$title》 · 第 $n 章';
  }

  @override
  String bookAiLabelNamed(String title, int n, String chapter) {
    return '《$title》 · 第 $n 章 $chapter';
  }

  @override
  String get bookThisBook => '本书';

  @override
  String bookChapterOf(String format, int n, int total) {
    return '$format · 第 $n/$total 章';
  }

  @override
  String get bookTools => '阅读工具';

  @override
  String get bookPrevChapter => '上一章';

  @override
  String get bookNextChapter => '下一章';

  @override
  String get bookSearchTool => '书内搜索';

  @override
  String get bookSearchToolSubtitle => '在整本书里找词；点结果跳到那段';

  @override
  String get bookMarks => '书签 / 划线';

  @override
  String get bookMarksSubtitle => '当前位置加书签，或看已存的';

  @override
  String get readerPrefsTitle => '阅读设置';

  @override
  String get readerPrefsSubtitle => '字号 / 行距 / 背景';

  @override
  String get bookSearchHint => '搜书名里的词（支持中文）';

  @override
  String bookSearchHits(int n) {
    return '$n 处';
  }

  @override
  String get bookSearchPrompt => '输入词开始搜索（这一章 / 整本书都在本机）';

  @override
  String bookSearchNoMatch(String query) {
    return '没找到「$query」';
  }

  @override
  String bookChapterTitleLine(int n, String title) {
    return '第 $n 章 · $title';
  }

  @override
  String get bookNoteTitle => '批注';

  @override
  String get bookNoteHint => '写点自己的话（可留空）';

  @override
  String bookMarksCount(int n) {
    return '$n 条';
  }

  @override
  String bookAddMarkAt(int n, int pct) {
    return '在第 $n 章当前位置加书签（$pct%）';
  }

  @override
  String get bookNoMarks => '还没有书签';

  @override
  String get bookNoExcerpt => '（无摘录）';

  @override
  String bookNotePrefix(String note) {
    return '批注：$note';
  }

  @override
  String get bookMarkActions => '书签操作';

  @override
  String get bookEditNote => '改批注';

  @override
  String get bookWriteNote => '写批注';

  @override
  String get readerPrefsGlobal => '全文生效';

  @override
  String get readerFontSize => '字号';

  @override
  String get readerFontSmaller => '小一点';

  @override
  String get readerFontBigger => '大一点';

  @override
  String get readerLineHeight => '行距';

  @override
  String readerLineHeightValue(String n) {
    return '$n 倍';
  }

  @override
  String get readerBackground => '背景';

  @override
  String get readerThemeFollow => '跟随主题';

  @override
  String get readerThemeSepia => '护眼';

  @override
  String get readerThemeNight => '夜间';

  @override
  String get readerJustify => '两端对齐';

  @override
  String get readerJustifySubtitle => '中文长段落可能出现大空隙，默认关';

  @override
  String get bookOwnToc => '原书目录';

  @override
  String get aiExplain => '解释';

  @override
  String get aiTranslate => '翻译';

  @override
  String get bookMissingImage => '（插图缺失）';

  @override
  String bookMissingImageNamed(String path) {
    return '（插图缺失：$path）';
  }

  @override
  String get bookBodyText => '正文';

  @override
  String get driveRenameHelper => '重命名只会把改动的字段发给服务端（官方 v2 行为）';

  @override
  String get fileSortTooltip => '排序';

  @override
  String get chatSystemMessage => '系统消息';

  @override
  String chatSystemMessageEvent(String event) {
    return '系统消息（$event）';
  }

  @override
  String chatSysJoined(String names) {
    return '$names 加入了此频道。';
  }

  @override
  String chatSysGuestJoined(String actor, String guest, String suffix) {
    return '$actor的访客$guest$suffix 加入了此频道。';
  }

  @override
  String chatSysInvited(String actor, String names) {
    return '$actor 已邀请 $names 进入此频道。';
  }

  @override
  String chatSysLeft(String names) {
    return '$names 离开了此频道。';
  }

  @override
  String chatSysMemberRemoved(String actor, String names) {
    return '$actor 已将 $names 从成员列表中删除。';
  }

  @override
  String chatSysYouRemoved(String channel) {
    return '您已从 $channel 的成员列表中被删除。';
  }

  @override
  String chatSysGuestInvited(String actor, String email) {
    return '$actor 已邀请访客 $email。';
  }

  @override
  String chatSysChannelRenamed(String name) {
    return '频道名称已更改为 $name。';
  }

  @override
  String chatSysChannelDescChanged(String name) {
    return '频道描述已更改为 $name。';
  }

  @override
  String get chatSysConversationPromoted => '会话已转换为专用频道。';

  @override
  String get chatSysChannelUpdated => '频道信息已更新。';

  @override
  String chatSysChannelArchived(String channel, String who) {
    return '频道 $channel 已被 $who 存档。';
  }

  @override
  String chatSysChannelClosed(String channel, String reason) {
    return '频道 $channel 已关闭。原因：$reason';
  }

  @override
  String chatSysYouRevived(String actor, String channel) {
    return '您已被 $actor 恢复。您现在可回到 $channel。';
  }

  @override
  String chatSysRevived(String names, String actor) {
    return '$names 已被 $actor 恢复。';
  }

  @override
  String chatSysGuestKicked(String actor, String names) {
    return '$actor 已将访客 $names 移出此频道。';
  }

  @override
  String chatSysEncryptEnabled(String app) {
    return '哈啰！已在 $app 中启用频道加密。加密频道可让您使用私人密码短语对储存在 Synology NAS 上的信息进行加密。加密频道中的所有信息将安全存储在服务器上，且管理员无法读取。若要开始使用加密频道，您需要设置密码短语。单击此处可设置您自己的密码短语。';
  }

  @override
  String get chatSysEncryptDisabled => '加密频道已由管理员禁用。所有加密频道都已归档并关闭。';

  @override
  String chatSysEncryptInvited(String who) {
    return '哈啰！$who 邀请您使用频道加密。单击此处可设置您自己的密码短语。';
  }

  @override
  String get chatSysUserBroken => '无法进入此频道且其权限必须由另一用户恢复。';

  @override
  String get chatSysKeyReset => '您的私钥已重置。';

  @override
  String get chatSysThreadCreated => '已创建一篇帖子。';

  @override
  String chatSysCommentCreated(String actor) {
    return '$actor 已在帖子中留言。';
  }

  @override
  String get chatSysPostPinned => '已锁定此消息';

  @override
  String get chatSysVoteClosed => '投票现已关闭。';

  @override
  String get chatSysVoteUpdated => '投票已更新。';

  @override
  String chatSysBotAdded(String actor, String names) {
    return '$actor 已添加整合 $names';
  }

  @override
  String chatSysBotDeleted(String actor, String names) {
    return '$actor 已删除整合 $names。';
  }

  @override
  String chatSysBotReset(String names) {
    return '$names 已經重置';
  }

  @override
  String get chatSysUser => '系统用户';

  @override
  String chatSysBotDisabled(String who, String names) {
    return '$who 已禁用集成 $names。';
  }

  @override
  String chatSysBotEnabled(String names, String who) {
    return '集成 $names 已被 $who 启用。';
  }

  @override
  String chatSysWelcome(String who) {
    return '您好，$who，\n这是您的私密空间，您可在此写信息或保留您将来可能会用到的任何文件和链接。';
  }

  @override
  String get chatSysCommandFailed => '命令执行失败。';

  @override
  String chatUserFallback(int id) {
    return '用户 $id';
  }

  @override
  String chatGuestSuffix(String name) {
    return '$name 访客';
  }

  @override
  String get chatSomeUser => '某个用户';

  @override
  String chatConversationMembers(int count) {
    return '会话（$count 人）';
  }

  @override
  String chatChannelHash(int id) {
    return '频道 #$id';
  }

  @override
  String get chatThisChannel => '此频道';

  @override
  String get chatSysCloseAllUserBroken => '所有的用户都无法进入此频道。';

  @override
  String chatSysCloseUserDeleted(String user) {
    return '用户 $user 已删除。';
  }

  @override
  String get chatSysCloseAdminToggle => '此操作由管理员触发。';

  @override
  String chatSysCloseByUser(String user) {
    return '$user已关闭此频道。';
  }

  @override
  String get chatSubjectMessage => '消息';

  @override
  String chatSysPostDeleted(
    String who,
    String channel,
    String subject,
    String what,
  ) {
    return '$who 已删除您在通道 $channel 中的$subject $what。';
  }

  @override
  String get chatNameRequired => '频道名称 不可为空。';

  @override
  String get chatNameInvalid => '不可用空格和特殊字符。';

  @override
  String get chatErrNotLoggedIn => '未登录，无法建立实时通道';

  @override
  String chatErrRealtimeNotReady(String error) {
    return '实时通道未就绪：$error';
  }

  @override
  String get chatErrNoConnId => '实时通道还没连上，现在关不了这个频道，请稍后重试。';

  @override
  String chatErrEncryptAttachmentFailed(String error) {
    return '加密附件失败：$error';
  }

  @override
  String chatLoadMessagesFailed(String error) {
    return '加载消息失败：$error';
  }

  @override
  String chatLoadOlderFailed(String error) {
    return '翻页失败：$error';
  }

  @override
  String get chatSendFailedKept => '发送失败（已留在列表里，可长按重发）';

  @override
  String chatSlashCommandNotFound(String command) {
    return '没有找到 /$command 这个命令';
  }

  @override
  String get chatStickerSendFailed => '贴纸发送失败';

  @override
  String get chatAddHashtag => '加标签';

  @override
  String get chatHashtagNameHint => '标签名（不含 #）';

  @override
  String get chatAdd => '添加';

  @override
  String get chatAddHashtagFailed => '加标签失败';

  @override
  String get chatRemoveHashtagWhich => '移除哪个标签？';

  @override
  String get chatRemoveHashtagFailed => '移除标签失败';

  @override
  String get chatReminderFuture => '提醒时间要在未来';

  @override
  String get chatSetReminderFailed => '设置提醒失败';

  @override
  String get chatCreateVoteFailed => '建投票失败（可能是发送过于频繁）';

  @override
  String chatScheduledOk(String time) {
    return '已定时（$time）';
  }

  @override
  String get chatScheduleFailed => '定时失败（可能是发送过于频繁）';

  @override
  String get chatVoiceSendFailed => '语音发送失败（可能是发送过于频繁，稍后再试）';

  @override
  String get chatRealtimeNotReady => '实时通道未就绪';

  @override
  String get chatAddToConversation => '添加到会话';

  @override
  String get chatAttachGallery => '相册图片';

  @override
  String chatFileTooLarge(int limit) {
    return '文件大小超出限制（上限 $limit MB）。';
  }

  @override
  String chatUploading(String name) {
    return '上传 $name';
  }

  @override
  String get chatUploadFailed => '上传失败（可能是发送过于频繁，稍后再试）';

  @override
  String get chatResendFailedAttachmentGone => '重新发送失败（附件可能已不在本地）';

  @override
  String get chatOperationFailed => '操作失败，稍后再试';

  @override
  String get chatConnectionStatus => '连接状态';

  @override
  String get chatRealtimeConnected => '实时通道已连接';

  @override
  String get chatRealtimeDisconnected => '实时通道未连接';

  @override
  String get chatRealtimePushHint => '消息仍可发送，但收不到实时推送';

  @override
  String get chatSyncSyncing => '同步中';

  @override
  String get chatSyncDone => '同步完成';

  @override
  String get chatSyncDegraded => '已降级（列表仍可用）';

  @override
  String chatSyncCounts(int channels, int users) {
    return '$channels 个频道 · $users 个用户';
  }

  @override
  String get chatLastError => '最近一次错误';

  @override
  String get chatResyncNow => '立即重新同步';

  @override
  String get chatDiagnostics => '打洞诊断工具';

  @override
  String get chatResendFailed => '重新发送失败';

  @override
  String get chatClearReminderFailed => '取消提醒失败';

  @override
  String get chatDeleteFailed => '删除失败';

  @override
  String chatSavedToDownloads(String name) {
    return '已保存到「下载」：$name';
  }

  @override
  String get chatForwardTo => '转发到';

  @override
  String get chatForward => '转发';

  @override
  String get chatForwarded => '已转发';

  @override
  String get chatForwardFailed => '转发失败';

  @override
  String get chatNoInvitableUsers => '没有可邀请的用户';

  @override
  String chatInvitedUser(String name) {
    return '已邀请 $name';
  }

  @override
  String get chatInviteFailed => '邀请失败';

  @override
  String chatChannelSemantic(String name) {
    return '频道：$name';
  }

  @override
  String get chatSearchInChannel => '在频道内搜索';

  @override
  String get chatNoMessages => '还没有消息';

  @override
  String get chatNoMessagesHint => '发送第一条消息，开始这段会话';

  @override
  String get chatBackToLatest => '回到最新';

  @override
  String chatBackToLatestUnread(int count) {
    return '回到最新，下方还有 $count 条新消息';
  }

  @override
  String get chatTypePublic => '公开';

  @override
  String get chatTypePrivate => '私有';

  @override
  String get chatTypeAnonymous => '匿名';

  @override
  String get chatTypeBot => '机器人';

  @override
  String get chatChannel => '频道';

  @override
  String get chatDayBeforeYesterday => '前天';

  @override
  String chatWeekday(String name) {
    return '星期$name';
  }

  @override
  String get chatWeekdayMon => '一';

  @override
  String get chatWeekdayTue => '二';

  @override
  String get chatWeekdayWed => '三';

  @override
  String get chatWeekdayThu => '四';

  @override
  String get chatWeekdayFri => '五';

  @override
  String get chatWeekdaySat => '六';

  @override
  String get chatWeekdaySun => '日';

  @override
  String chatDateMonthDay(int month, int day) {
    return '$month月$day日';
  }

  @override
  String chatDateFull(int year, int month, int day) {
    return '$year年$month月$day日';
  }

  @override
  String get chatNewMessagesBelow => '以下为新消息';

  @override
  String chatTypingUser(String name) {
    return '$name 正在输入';
  }

  @override
  String get chatTypingOne => '1 个人正在输入';

  @override
  String chatTypingMany(int count) {
    return '$count 个人正在输入';
  }

  @override
  String get chatRealtimeDegraded => '实时通道已降级，点开查看';

  @override
  String get chatRealtimeOffline => '实时未连接';

  @override
  String get chatSearchThisChannel => '搜索此频道';

  @override
  String get chatMembersBroken => '成员（有人解不开加密）';

  @override
  String get chatInvite => '邀请';

  @override
  String get chatMediaPhotosVideos => '图片与视频';

  @override
  String get chatPinnedMessages => '置顶的消息';

  @override
  String get chatAllFiles => '所有文件';

  @override
  String get chatAllLinks => '所有链接';

  @override
  String get chatMentions => '提及我';

  @override
  String get chatScheduledInfo => '计划信息';

  @override
  String get chatHashtags => '主题标签';

  @override
  String get chatNotifications => '通知';

  @override
  String get chatChannelManage => '频道管理';

  @override
  String get chatE2eeUnlocked => '端到端加密（已解锁）';

  @override
  String get chatE2eeLockedHint => '加密频道已锁定，输口令才能读';

  @override
  String get chatE2eeKeyUnreadable => '这个频道的密钥解不开（密钥对换过 / 不是封给你的）';

  @override
  String chatAvatarSemantic(String name) {
    return '$name 的头像';
  }

  @override
  String get chatThreadReply => '↳ 话题回复';

  @override
  String get chatSendFailedRetry => '发送失败 · 重试';

  @override
  String get chatPinned => '已置顶';

  @override
  String chatReplyCount(int count) {
    return '$count 条回复';
  }

  @override
  String chatHashtagTapHint(String tag) {
    return '话题 $tag（Phase 6 接入搜索）';
  }

  @override
  String get chatEdited => '已编辑';

  @override
  String get chatStarred => '已星标';

  @override
  String get chatSending => '发送中';

  @override
  String get chatSendFailed => '发送失败';

  @override
  String get chatRead => '已读';

  @override
  String get chatSent => '已发送';

  @override
  String chatReactionSemantics(String label, int count) {
    return '$label 共 $count 个';
  }

  @override
  String chatReactionSemanticsMine(String label, int count) {
    return '$label 共 $count 个（含我）';
  }

  @override
  String get chatSendPhotoFile => '发送图片 / 文件';

  @override
  String get chatStickersEmoji => '贴纸 / 表情';

  @override
  String get chatEmojiPanelTitle => '表情';

  @override
  String get emojiCatPeople => '表情';

  @override
  String get emojiCatNature => '自然';

  @override
  String get emojiCatFood => '食物';

  @override
  String get emojiCatActivity => '活动';

  @override
  String get emojiCatTravel => '出行';

  @override
  String get emojiCatObjects => '物品';

  @override
  String get emojiCatSymbols => '符号';

  @override
  String get emojiCatFlags => '旗帜';

  @override
  String get chatEmojiAll => '全部表情';

  @override
  String get chatMessageHint => '发消息…';

  @override
  String get chatSend => '发送';

  @override
  String chatRecordVoice(int seconds) {
    return '录语音（最长 $seconds 秒）';
  }

  @override
  String get chatSlashJitsiDesc => '发起 Jitsi 视频会议';

  @override
  String get chatSlashJumpchatDesc => '发起 JumpChat 会议';

  @override
  String get chatContent => '内容';

  @override
  String get chatErrNoServerPost => '还没有拿到服务端的消息';

  @override
  String chatErrNoAppForTypeSaved(String path) {
    return '没有能打开这个类型的应用（已下载到 $path）';
  }

  @override
  String chatErrNoAppForTypeAt(String path) {
    return '没有能打开这个类型的应用（文件在 $path）';
  }

  @override
  String get chatErrNoAppForType => '没有能打开这个类型的应用';

  @override
  String chatErrOpenFailed(String error) {
    return '打开失败：$error';
  }

  @override
  String chatErrDownloadFailed(String error) {
    return '下载失败：$error';
  }

  @override
  String get chatErrDecryptKey => '解密失败（频道密钥没解锁？）';

  @override
  String get chatErrDecrypt => '解密失败';

  @override
  String get chatErrPlaybackFailed => '播放失败';

  @override
  String get chatStreamEncryptedTitle => '这条视频是加密的';

  @override
  String get chatStreamUntrustedCertTitle => '服务器证书不受信任';

  @override
  String get chatStreamEncryptedHint => '外部播放器拿不到频道的密钥。要先下载并解密才能观看，点「确定」开始下载。';

  @override
  String get chatStreamUntrustedCertHint =>
      '外部播放器不认这台服务器的证书。要先下载才能观看，点「确定」开始下载。';

  @override
  String get chatSkipAgain => '不再提示';

  @override
  String get chatOpenAsTitle => '打开方式';

  @override
  String get chatOpenAsText => '文本';

  @override
  String get chatOpenFile => '打开文件';

  @override
  String get chatSaveToDownloads => '保存到下载';

  @override
  String get chatShare => '分享';

  @override
  String get chatOpenWithOtherApp => '用其它应用打开';

  @override
  String get chatImageActions => '图片操作';

  @override
  String get chatImageLoadFailed => '图片加载失败';

  @override
  String get chatVoiceMessage => '语音消息';

  @override
  String get chatDownloading => '正在下载…';

  @override
  String get chatErrNoAttachment => '这条消息没有附件';

  @override
  String get chatErrPageClosed => '页面已关闭';

  @override
  String get chatErrSaveToDownloadsFailed => '保存到「下载」失败';

  @override
  String get chatErrNoShareTarget => '没有能接收分享的应用';

  @override
  String get chatErrChannelNotInList => '这个频道不在你的列表里（可能是私密频道或未加入）';

  @override
  String chatErrCannotOpenLink(String url) {
    return '打不开这个链接：$url';
  }

  @override
  String get chatErrNoAppForLink => '没有能打开这个链接的应用';

  @override
  String get chatLinkRisky => '链接可能有风险';

  @override
  String get chatUnsafeWebsiteConfirmOpen =>
      '以下网站可能由 Google 安全浏览归类为恶意网站。我们建议您不要访问它。是否确定要打开它？';

  @override
  String get chatUnsafeWebsiteOpen => '仍然打开';

  @override
  String get chatUnsafeWebsiteCancel => '取消';

  @override
  String get chatErrNoMicPermission => '没有麦克风权限';

  @override
  String chatErrRecordFailed(String error) {
    return '录音失败：$error';
  }

  @override
  String get chatRecording => '录音';

  @override
  String get chatVoiceStop => '停止录音';

  @override
  String get chatVoicePreview => '试听';

  @override
  String get chatVoicePreviewPause => '暂停';

  @override
  String get chatVoiceDiscard => '放弃';

  @override
  String get chatVoiceRerecord => '重录';

  @override
  String get chatVoiceReviewHint => '试听后决定是否发送';

  @override
  String chatVoiceMaxSeconds(int seconds) {
    return '最长 $seconds 秒';
  }

  @override
  String get chatNewChannel => '新建频道';

  @override
  String chatChannelCount(int count) {
    return '$count 个频道';
  }

  @override
  String chatUserCount(int count) {
    return '$count 个用户';
  }

  @override
  String get chatLinkReady => '实时已连接';

  @override
  String get chatLinkReconnecting => '重连中';

  @override
  String get chatLinkOffline => '离线';

  @override
  String get chatLinkSyncFailed => '同步失败';

  @override
  String get chatLinkDisconnected => '已断开';

  @override
  String get chatChannelsTitle => '频道';

  @override
  String get chatSearchMessages => '搜索消息';

  @override
  String get chatLogout => '退出登录';

  @override
  String get chatStatusWaitingSync => '等待同步';

  @override
  String get chatStatusSyncing => '同步中…';

  @override
  String chatStatusConnSuffix(String connId) {
    return ' · $connId';
  }

  @override
  String get chatStatusRealtimeDown => '实时通道未连接（列表仍可用）';

  @override
  String get chatSyncingChannels => '正在同步频道…';

  @override
  String get chatNoChannels => '还没有频道';

  @override
  String chatManageFailed(String label, String error) {
    return '$label失败：$error';
  }

  @override
  String get chatManageNameRequired => '请填写频道名称';

  @override
  String chatManagePromoted(String name) {
    return '已把会话转换为专用频道「$name」';
  }

  @override
  String chatManagePromoteFailed(String error) {
    return '转换失败：$error';
  }

  @override
  String chatManageTitle(String name) {
    return '频道管理 · $name';
  }

  @override
  String get chatManageLoading => '正在读取…';

  @override
  String get chatManageEncryptedSuffix => ' · 加密';

  @override
  String chatManageLocalPosts(int count) {
    return ' · 本地 $count 条消息';
  }

  @override
  String get chatFavoriteChannel => '收藏频道';

  @override
  String get chatFavoriteAction => '收藏';

  @override
  String get chatLeaveChannel => '退出频道';

  @override
  String chatLeaveConfirm(String name) {
    return '确认退出「$name」？退出后消息将不再显示。';
  }

  @override
  String chatArchiveConfirm(String name) {
    return '确认归档「$name」？归档后可在「归档频道」里查看。';
  }

  @override
  String get chatArchiveUnsupported => '服务端没有归档这个频道（当前账号/频道类型不支持）';

  @override
  String chatArchiveFailed(String error) {
    return '归档频道失败：$error';
  }

  @override
  String get chatPromoteTitle => '将会话转换为专用频道';

  @override
  String chatCloseConfirm(String name) {
    return '确认关闭「$name」？关闭后不可恢复。';
  }

  @override
  String get chatManageNoActions => '这个频道没有可管理的操作';

  @override
  String chatConvTitle(int channelId) {
    return '会话 #$channelId';
  }

  @override
  String chatPublicChannelTitle(int channelId) {
    return '公开频道 #$channelId';
  }

  @override
  String chatPrivateChannelTitle(int channelId) {
    return '私有频道 #$channelId';
  }

  @override
  String get chatChannelName => '频道名称';

  @override
  String get chatChannelNameHelper => '不可用空格和特殊字符';

  @override
  String get chatPromoteAction => '转换';

  @override
  String chatCreatedEncrypted(int channelId) {
    return '加密频道 #$channelId 已创建';
  }

  @override
  String chatCreated(int channelId) {
    return '频道 #$channelId 已创建';
  }

  @override
  String get chatChannelNameHint => '例如：项目讨论';

  @override
  String get chatChannelPurposeOptional => '用途（可选）';

  @override
  String get chatChannelPrivate => '私有频道';

  @override
  String get chatChannelPrivateHint => '只有被邀请的成员能加入';

  @override
  String get chatChannelPublic => '公开频道';

  @override
  String get chatChannelPublicHint => '服务器上所有人都能看到并加入';

  @override
  String get chatCreateE2eeDisabled => '服务端已关闭端到端加密，无法创建加密频道。';

  @override
  String get chatCreateE2eeHint =>
      '消息只在成员设备上加密/解密，服务端看不到明文。创建后无法关闭，也无法给没有加密密钥的人发消息。';

  @override
  String get chatCreateE2eeIrreversible => '创建后无法切换，请先确认';

  @override
  String get chatSectionMembers => '成员';

  @override
  String get chatCreateNoInvitableUsers => '没有可邀请的用户（或还没同步完）';

  @override
  String get chatUserNoE2eeKey => '该用户还没有端到端加密密钥';

  @override
  String get chatCreateNameRequired => '频道名不能为空';

  @override
  String get chatCreateNoE2eeIdentity => '还没有端到端加密身份，先去「端到端加密」里设置';

  @override
  String chatCreateMemberNoKey(String name) {
    return '$name 还没有端到端加密密钥，加不进来';
  }

  @override
  String get chatCreateNoChannelId => '服务端没有返回频道标识，创建可能没有成功。';

  @override
  String get chatNotificationAll => '全部消息';

  @override
  String get chatNotificationMentionSubscribe => '@我，以及我订阅的话题';

  @override
  String get chatNotificationMention => '只有 @我';

  @override
  String get chatNotificationNone => '不提醒';

  @override
  String chatNotificationChanged(String label) {
    return '通知已改为「$label」';
  }

  @override
  String get chatNotificationSaveFailed => '保存失败';

  @override
  String get chatNotificationTitle => '通知设置';

  @override
  String get chatRescueKeyTitle => '修复加密密钥';

  @override
  String chatRescueKeyConfirm(int channelId, String name) {
    return '把#$channelId 的频道密钥重新封一份给$name？\n\n对方要有公钥才修得了。';
  }

  @override
  String get chatRescueKeyDone => '已重发频道密钥';

  @override
  String get chatRescueKeyFailed => '修复失败（对方可能没有公钥）';

  @override
  String get chatKickTitle => '移出频道';

  @override
  String chatKickConfirm(String names) {
    return '把 $names 移出这个频道？';
  }

  @override
  String get chatKickAction => '移出';

  @override
  String get chatKickDone => '已移出';

  @override
  String get chatPostsDeletedByAdmin => '部分帖子已被管理员删除。此页面将在一分钟后刷新。';

  @override
  String get chatKickFailed => '移出失败（只有群主/管理员能踢人）';

  @override
  String get chatInviteSkippedNoPassphrase => '这些成员都没有设置口令，已跳过邀请';

  @override
  String get chatInviteDone => '已邀请';

  @override
  String chatMembersTitle(int count) {
    return '成员 ($count)';
  }

  @override
  String get chatInviteTitle => '邀请成员';

  @override
  String get chatSearchMembers => '搜索成员';

  @override
  String chatBrokenMembersBanner(int count) {
    return '有 $count 位成员解不开这个频道里的消息，点他们的名字可以重发频道密钥。';
  }

  @override
  String get chatNoMembers => '没有成员';

  @override
  String chatMemberMe(String name) {
    return '$name（我）';
  }

  @override
  String get chatMemberNoE2eeKey => '该成员还没有端到端加密密钥';

  @override
  String get chatMemberBrokenHint => '解不开这个频道的消息，点击修复';

  @override
  String chatStartChatFailed(String error) {
    return '开不了会话：$error';
  }

  @override
  String chatStartChatNoChannel(String name) {
    return '服务端没有返回会话（$name）';
  }

  @override
  String chatProfileAccount(String username, int userId) {
    return '账号：$username　ID：#$userId';
  }

  @override
  String chatProfileEmail(String email) {
    return '邮箱：$email';
  }

  @override
  String chatProfileBio(String description) {
    return '简介：$description';
  }

  @override
  String get chatProfileE2eeUnset => '端到端加密：未设置口令';

  @override
  String get chatProfileE2eeSet => '端到端加密：已设置口令';

  @override
  String get chatProfileInChannelBroken => '在这个频道里：解不开（可修复）';

  @override
  String get chatProfileInChannelOk => '在这个频道里：正常';

  @override
  String chatProfileTimezone(String tz) {
    return '时区：$tz';
  }

  @override
  String get chatProfileUnavailable => '资料不可用（服务端没有这个用户，仅显示提及的名字）';

  @override
  String get chatEditProfile => '编辑资料';

  @override
  String get chatSendMessage => '发消息';

  @override
  String chatInviteCount(int count) {
    return '邀请 ($count)';
  }

  @override
  String get chatSearchUsers => '搜索用户';

  @override
  String get chatInviteNoPassphraseHint => '加密频道里没设置口令（⚠）的成员不会被加进来，邀请时会再问一次。';

  @override
  String get chatRowNameSeparator => '、';

  @override
  String get chatRowNoMessages => '无消息';

  @override
  String get chatRowJustNow => '刚刚';

  @override
  String chatRowMinutesAgo(int n) {
    return '$n 分钟前';
  }

  @override
  String chatRowHoursAgo(int n) {
    return '$n 小时前';
  }

  @override
  String chatRowDaysAgo(int n) {
    return '$n 天前';
  }

  @override
  String chatRowMembers(int count) {
    return '$count 人';
  }

  @override
  String chatRowUnreadThreads(int count) {
    return '$count 个未读话题';
  }

  @override
  String get chatRowHasFailed => '有发送失败的消息';

  @override
  String get chatRowHasBrokenMembers => '有成员无法解密';

  @override
  String get chatRowMuted => '已静音';

  @override
  String get chatRowBotChannel => '机器人频道';

  @override
  String get chatMySpace => '我的空间';

  @override
  String get chatHashtagsEmpty => '这个频道还没有标签';

  @override
  String get chatContentMentions => '@我';

  @override
  String chatContentEmpty(String kind) {
    return '这个频道还没有$kind内容';
  }

  @override
  String get chatAuthorMe => '我';

  @override
  String get chatMediaImage => '图片';

  @override
  String get chatMediaAudio => '音频';

  @override
  String chatMediaTitle(String name) {
    return '$name · 媒体与文件';
  }

  @override
  String get chatMediaEmpty => '这里还没有内容';

  @override
  String get chatMediaLoadEarlier => '加载更早的';

  @override
  String chatMediaAttachmentCount(int count) {
    return '$count 个附件';
  }

  @override
  String get chatArchiveEmpty => '没有归档频道。\n归档后的加密会话会出现在这里。';

  @override
  String get chatArchiveReadable => '可读';

  @override
  String get chatArchiveLocked => '已锁定';

  @override
  String get chatArchiveUnlockHint => '先设置加密密钥才能打开这个频道';

  @override
  String get chatArchiveKeyUnavailable => '密钥解不开';

  @override
  String chatArchiveHashId(int id) {
    return '归档 #$id';
  }

  @override
  String chatArchiveMemberCount(int count) {
    return '$count 位成员';
  }

  @override
  String get chatScheduledTitle => '定时消息';

  @override
  String get chatAttachSchedule => '定时';

  @override
  String get chatScheduledEmpty => '没有待发的定时消息';

  @override
  String chatScheduledSendAt(String time) {
    return '发送时间 $time';
  }

  @override
  String get chatRemindersEmpty => '没有提醒';

  @override
  String get chatPostNoBody => '(无正文)';

  @override
  String chatReminderAt(String time) {
    return '提醒时间 $time';
  }

  @override
  String get chatReminderCancel => '取消提醒';

  @override
  String get chatCloseConversation => '关闭会话';

  @override
  String get chatCloseChannel => '关闭频道';

  @override
  String get chatVoteClosed => '已结束';

  @override
  String chatVoteTotalVotes(int total) {
    return '$total 票';
  }

  @override
  String get chatVoteEditTitle => '编辑投票';

  @override
  String get chatVoteCloseAction => '结束投票';

  @override
  String get chatVoteDeleteTitle => '删除投票';

  @override
  String get chatVoteDeleted => '投票已删除';

  @override
  String get chatVoteFailed => '投票失败';

  @override
  String get chatVoteRefreshFailed => '刷新失败';

  @override
  String get chatVoteViewResults => '看结果';

  @override
  String get chatVoteResultsTitle => '投票结果';

  @override
  String get chatVoteNoVotes => '还没有人投票';

  @override
  String get chatVoteAddOption => '添加选项';

  @override
  String get chatVoteAddOptionFailed => '添加选项失败';

  @override
  String get chatVoteEditFailed => '编辑投票失败';

  @override
  String get chatVoteCloseFailed => '结束投票失败';

  @override
  String get chatVoteDeleteFailed => '删除投票失败';

  @override
  String get chatVoteDeleteConfirm => '删除投票？消息本身会保留。';

  @override
  String get chatVoteAnonymous => '匿名';

  @override
  String chatVoteEndsAt(String time) {
    return '截止 $time';
  }

  @override
  String get chatVoteChoiceHint => '选项内容';

  @override
  String get chatVoteCreateTitle => '发起投票';

  @override
  String get chatVoteCreateSubmit => '发起';

  @override
  String get chatVoteErrQuestionEmpty => '问题不能为空';

  @override
  String get chatVoteErrChoiceEmpty => '选项不能为空';

  @override
  String get chatVoteErrChoiceDuplicate => '选项不能重复';

  @override
  String get chatVoteErrTooFewChoices => '至少两个选项';

  @override
  String get chatVoteErrExpireFuture => '截止时间要在未来';

  @override
  String get chatVoteQuestionLabel => '问题';

  @override
  String get chatVoteChoiceLabel => '选项';

  @override
  String get chatVoteAllowMultiple => '允许多选';

  @override
  String get chatVoteAnonymousVote => '匿名投票';

  @override
  String get chatVoteAllowAddOption => '允许添加选项';

  @override
  String get chatVoteSetExpire => '设置截止时间';

  @override
  String get chatVoteClearExpire => '不设截止时间';

  @override
  String get chatVoteLockedHint => '已经有人投过票了：只能改「允许添加选项」和截止时间';

  @override
  String get chatActionReplyThread => '回复话题';

  @override
  String get chatActionReact => '表情回应';

  @override
  String get chatActionUnpin => '取消置顶';

  @override
  String get chatActionPin => '置顶';

  @override
  String get chatActionRemindMe => '提醒我';

  @override
  String get chatActionRemoveHashtag => '移除标签';

  @override
  String get chatActionCopyText => '复制文字';

  @override
  String get chatActionReadUsers => '已读成员';

  @override
  String get chatActionUnreadUsers => '未读成员';

  @override
  String get chatActionSheetTitle => '消息操作';

  @override
  String get chatReadStatusSection => '已读状态';

  @override
  String get chatTempResend => '重新发送';

  @override
  String get chatEditMessageTitle => '编辑消息';

  @override
  String get chatThreadTitle => '话题';

  @override
  String get chatThreadMarkAllRead => '全部标为已读';

  @override
  String get chatThreadUnsubscribe => '取消订阅';

  @override
  String get chatThreadSubscribe => '订阅';

  @override
  String get chatThreadUnsubscribed => '已取消订阅';

  @override
  String get chatActionFailed => '操作失败';

  @override
  String get chatThreadOriginalMessage => '原消息';

  @override
  String get chatThreadNoReplies => '还没有回复';

  @override
  String get chatThreadReplyHint => '回复话题…';

  @override
  String chatReadStatusLoadFailed(String error) {
    return '查不到已读状态：\n$error';
  }

  @override
  String get chatReadStatusNoReaders => '还没有人读过';

  @override
  String get chatReadStatusAllRead => '所有人都读过了';

  @override
  String chatReadStatusReadCount(int count) {
    return '已读 $count 人';
  }

  @override
  String chatReadStatusUnreadCount(int count) {
    return '未读 $count 人';
  }

  @override
  String get chatReadStatusNoMatch => '没有匹配的成员';

  @override
  String chatReadStatusAccountInfo(String account, int id) {
    return '账号：$account　ID：#$id';
  }

  @override
  String chatReadStatusUserStatus(String status) {
    return '状态：$status';
  }

  @override
  String get chatNoPassphraseTitle => '错误';

  @override
  String chatNoPassphraseBody(int count) {
    return '选中的成员里有 $count 位还没有设置端到端加密口令。点「确定」会把这些人移出名单，继续加密频道。';
  }

  @override
  String get chatNoPassphraseNotify => '通知他们去设置口令';

  @override
  String get chatMentionChannelDesc => '通知频道里的所有人';

  @override
  String get chatMentionHereDesc => '通知当前在线的人';

  @override
  String get chatStickerNoCatalog => '这个服务器没有贴纸目录';

  @override
  String get chatStickerCategoryEmpty => '这个分类是空的';

  @override
  String get chatBotActionFailed => '按钮触发失败';

  @override
  String get chatBotProcessing => '处理中...';

  @override
  String chatBotWelcomeDefault(String bot) {
    return '这是您与 $bot 之间进行的一对一会话。';
  }

  @override
  String get chatBotFallbackName => '机器人';

  @override
  String get contactHeaderTagline => '通讯录 · 标签 · CardDAV';

  @override
  String get contactImportVcfCsv => '导入 vCard / CSV';

  @override
  String get contactManageBooksLabels => '通讯录与标签管理';

  @override
  String get contactCarddavSync => 'CardDAV 与同步';

  @override
  String get contactSortByName => '按姓名排序';

  @override
  String get contactSortByCompany => '按公司排序';

  @override
  String get contactSortAsc => '改为升序';

  @override
  String get contactSortDesc => '改为降序';

  @override
  String get contactSearchHint => '搜索姓名 / 单位 / 邮箱 / 电话';

  @override
  String get contactStarredChip => '★ 星标';

  @override
  String get contactOpenFailed => '打不开通讯录';

  @override
  String contactNoMatch(String keyword) {
    return '没找到「$keyword」';
  }

  @override
  String get contactNoMatchHint => '换个关键词，或清空搜索框看全部。';

  @override
  String get contactEmptyTitle => '还没有联系人';

  @override
  String get contactEmptyBody =>
      'Synology Contacts 里的联系人会出现在这里。\n点右下角「新建」加一个，或从「更多 → 导入」导入 vCard。';

  @override
  String get contactNoBooks => '没有可用的通讯录';

  @override
  String get contactPickBookTitle => '新建到哪个通讯录？';

  @override
  String contactSharedFrom(String name) {
    return '共享自 $name';
  }

  @override
  String get contactUnnamed => '(未命名)';

  @override
  String get contactUnstarred => '已取消星标';

  @override
  String get contactErrNotInstalled => '这台 NAS 没有装 Synology Contacts';

  @override
  String get contactErrVersionUnsupported => '这台 NAS 的 Contacts 版本不支持这个操作';

  @override
  String get contactErrNoPermission => '当前账号没有权限做这个操作';

  @override
  String get contactErrParamRejected => '参数被服务端拒绝了（多半是这一版 Contacts 不支持）';

  @override
  String get contactErrBookNotFound => '找不到这个通讯录';

  @override
  String get contactErrOffline => '连上 NAS 就能看联系人';

  @override
  String get contactErrNetwork => '网络不通，检查一下 NAS 是否在线';

  @override
  String get contactErrNoStarredLabel => '这台 NAS 没有 Starred 标签';

  @override
  String contactExportBookName(String name) {
    return '通讯录_$name';
  }

  @override
  String contactExportLabelName(String name) {
    return '标签_$name';
  }

  @override
  String get contactBooksAndLabels => '通讯录与标签';

  @override
  String get contactAddressBooks => '通讯录';

  @override
  String get contactNewAddressBook => '新建通讯录';

  @override
  String get contactNoBooksYet => '还没有通讯录';

  @override
  String get contactBookPublic => '公开（同 NAS 的其他用户可见）';

  @override
  String get contactBookCreated => '已创建';

  @override
  String contactMemberCount(int count) {
    return '$count 位联系人';
  }

  @override
  String get contactBookPersonal => '个人';

  @override
  String get contactBookTeamPublic => '团队/公开';

  @override
  String get contactBookSuggested => '建议';

  @override
  String contactSharedTo(String names) {
    return '共享给 $names';
  }

  @override
  String get contactExportVCard => '导出 vCard';

  @override
  String contactSharePrincipals(String principals) {
    return '可共享主体：$principals\n（改共享关系请到网页版 Contacts，本页只读）';
  }

  @override
  String get contactRenameAddressBook => '重命名通讯录';

  @override
  String get contactRenamed => '已改名';

  @override
  String contactExportingBook(String name) {
    return '正在导出「$name」…';
  }

  @override
  String contactExportedTo(String path) {
    return '已导出到 $path';
  }

  @override
  String get contactDeleteAddressBook => '删除通讯录';

  @override
  String contactDeleteBookConfirm(String name, int count) {
    return '确定删除「$name」？里面的 $count 位联系人会一起没。';
  }

  @override
  String get contactBookDeleted => '已删除';

  @override
  String get contactLabelsHelp =>
      '标签是\"一份联系人名单\"，导出它就是组地址簿；星标是系统内置标签（type=1），不能改名或删除。';

  @override
  String get contactEditLabel => '编辑标签';

  @override
  String contactSystemLabelMembers(int count) {
    return '系统标签 · $count 位';
  }

  @override
  String get contactLabelDeleted => '已删除标签';

  @override
  String get contactRenameRecolor => '改名 / 换色';

  @override
  String get contactExportVCardGroup => '导出 vCard（组地址簿）';

  @override
  String get contactCarddavIntro =>
      '手机自带通讯录 / macOS / 其他客户端都能连进来；iOS 那条地址只在 https 下可用。';

  @override
  String get contactCarddavBindBook => '绑定的通讯录（决定 general 地址）';

  @override
  String get contactCarddavIosHint => '系统设置 → 通讯录 → 账户 → 添加 CardDAV 账户';

  @override
  String get contactCarddavOtherClients => '其他客户端（绑定具体通讯录）';

  @override
  String get contactCarddavNoUuid => '没取到通讯录 uuid，先看第一条';

  @override
  String get contactExternalSources => '外部通讯录（含 CardDAV 账号）';

  @override
  String get contactNoExternalSources =>
      '还没有外部通讯录。添加一个 CardDAV 账号，或在网页端连 Google/Outlook。';

  @override
  String get contactExternalSource => '外部源';

  @override
  String contactBookHash(String id) {
    return '通讯录 #$id';
  }

  @override
  String get contactExternalSourceNote =>
      '说明：服务端没有提供\"删除外部源\"的接口（只有 建/改/同步），要删请到网页版 Contacts 里删。';

  @override
  String get contactSyncTriggered => '已触发同步';

  @override
  String contactSyncFailed(String error) {
    return '同步失败：$error';
  }

  @override
  String get contactAddedSyncing => '已添加，正在同步（可能要一会儿）';

  @override
  String contactAddFailed(String error) {
    return '添加失败：$error';
  }

  @override
  String get contactCopyUrl => '复制地址';

  @override
  String get contactUrlCopied => '已复制地址';

  @override
  String get contactAddCarddavAccount => '添加 CardDAV 账号';

  @override
  String get contactServerUrl => '服务器地址';

  @override
  String get contactUsername => '用户名';

  @override
  String get contactPassword => '密码';

  @override
  String contactDetailNickname(String name) {
    return '昵称：$name';
  }

  @override
  String contactDetailAddressBook(String name) {
    return '通讯录：$name';
  }

  @override
  String get contactReadOnlyNote => '这是通讯录同步过来的用户记录，只能看不能改';

  @override
  String contactCopiedValue(String value) {
    return '已复制 $value';
  }

  @override
  String get contactCopyMove => '复制/移动';

  @override
  String get contactHide => '隐藏';

  @override
  String get contactUnhide => '取消隐藏';

  @override
  String get contactHidden => '已隐藏';

  @override
  String get contactUnhidden => '已取消隐藏';

  @override
  String get contactDeleteTitle => '删除联系人';

  @override
  String contactDeleteConfirm(String name) {
    return '确定删除「$name」？删除后无法恢复。';
  }

  @override
  String contactLabelsUpdateFailed(String error) {
    return '标签更新失败：$error';
  }

  @override
  String get contactNoOtherBook => '没有别的通讯录可以放';

  @override
  String get contactPickTargetBook => '选择目标通讯录（长按 = 移动）';

  @override
  String get contactMoved => '已移动';

  @override
  String contactCopyFailed(String error) {
    return '复制失败：$error';
  }

  @override
  String contactMoveFailed(String error) {
    return '移动失败：$error';
  }

  @override
  String get contactLabelPickerTitle => '给联系人打标签';

  @override
  String get contactNoLabelsHint => '还没有标签，先去「管理 → 标签」建一个';

  @override
  String get contactNameRequired => '姓名不能为空';

  @override
  String get contactEditTitle => '编辑联系人';

  @override
  String get contactNewTitle => '新建联系人';

  @override
  String get contactAddPhoto => '添加头像';

  @override
  String get contactChangePhoto => '更换头像';

  @override
  String get contactSectionBasic => '基本信息';

  @override
  String get contactFieldFullName => '姓名';

  @override
  String get contactFieldCompany => '公司';

  @override
  String get contactFieldDepartment => '部门';

  @override
  String get contactFieldJobTitle => '职务';

  @override
  String get contactSectionNameParts => '姓名构成（官方会把它们拼进 姓名）';

  @override
  String get contactFieldGivenName => '名';

  @override
  String get contactFieldFamilyName => '姓';

  @override
  String get contactFieldPrefix => '称谓前缀';

  @override
  String get contactFieldSuffix => '称谓后缀';

  @override
  String get contactFieldMiddleName => '中间名';

  @override
  String get contactFieldPhone => '电话';

  @override
  String get contactPhoneHint => '手机 / 座机';

  @override
  String get contactFieldUrl => '网址';

  @override
  String get contactFieldIm => '即时通讯';

  @override
  String get contactImHint => 'IM 账号';

  @override
  String get contactFieldDate => '日期（生日/纪念日等）';

  @override
  String get contactFieldAddress => '地址';

  @override
  String get contactAddressHint => '街道, 城市, 邮编, 国家';

  @override
  String get contactSectionOther => '其他';

  @override
  String get contactFieldBirthday => '生日';

  @override
  String get contactFieldNote => '备注';

  @override
  String contactAddRow(String title) {
    return '添加一行$title';
  }

  @override
  String get contactRemoveRow => '删除这一行';

  @override
  String get contactImportTitle => '导入联系人';

  @override
  String get contactImportHelp =>
      '支持 .vcf（vCard）/ .csv / .txt。选好文件会先给一份预览，确认后再导入。';

  @override
  String get contactImportTargetBook => '导入到哪个通讯录';

  @override
  String get contactPickFile => '选择文件';

  @override
  String contactPreviewCount(int count) {
    return '预览：共 $count 条';
  }

  @override
  String contactPreviewDuplicates(int count) {
    return '$count 条可能已存在';
  }

  @override
  String get contactImportBusy => '正在处理…';

  @override
  String get contactImportToThisBook => '导入到该通讯录';

  @override
  String get contactNoFilePath => '这个平台没给出文件路径，换一个文件选择器再试';

  @override
  String get contactNoContactsInFile => '这个文件里没有解析出联系人';

  @override
  String contactPreviewFailed(String error) {
    return '预览失败：$error';
  }

  @override
  String get contactImportDone => '导入完成';

  @override
  String contactImportedCount(int count) {
    return '导入了 $count 位联系人';
  }

  @override
  String contactImportFailed(String error) {
    return '导入失败：$error';
  }

  @override
  String get searchMessagesHint => '搜索消息…';

  @override
  String get searchFilter => '筛选';

  @override
  String searchTotalCount(int count) {
    return '共 $count 条';
  }

  @override
  String get searchPrompt => '输入关键词或选择筛选条件后搜索';

  @override
  String get searchNoMatch => '没有匹配的消息';

  @override
  String get searchKeyword => '关键词';

  @override
  String get searchHashtagHint => 'hashtag（空格分隔，不带 #）';

  @override
  String get searchFileTypeHint => '文件类型（如 png jpg pdf）';

  @override
  String get searchAuthor => '作者';

  @override
  String get searchTimeRange => '时间范围';

  @override
  String get searchStartDate => '起始日期';

  @override
  String get searchEndDate => '结束日期';

  @override
  String get searchApply => '应用';

  @override
  String searchLoadMoreFailed(String error) {
    return '加载更多失败：$error';
  }

  @override
  String get srvNoAddress => '没有可用的地址';

  @override
  String srvConnected(String url, String source) {
    return '连上 $url ($source)';
  }

  @override
  String srvAllUnreachable(String tried) {
    return '所有地址都不可达：$tried';
  }

  @override
  String srvUnreachable(String url, String source, String error) {
    return '$url ($source) 不可达：$error';
  }

  @override
  String srvCertWaiting(String url, String hash) {
    return '$url 的证书未受信任，等待确认（SHA-256 $hash）';
  }

  @override
  String srvCertRejected(String url) {
    return '$url 的证书被拒绝，连接中止';
  }

  @override
  String srvCertTrusted(String host) {
    return '已信任 $host 的证书，重试连接';
  }

  @override
  String srvRetryFailed(String url, String error) {
    return '$url 重试仍失败：$error';
  }

  @override
  String srvUseDirect(String url) {
    return '使用直连地址 $url';
  }

  @override
  String srvQueryingQc(String id) {
    return '查询 QuickConnect：$id';
  }

  @override
  String srvServicePort(int port, String host, String region) {
    return '服务端口 $port，来路 $host/$region';
  }

  @override
  String srvCandidate(String url, String source) {
    return '候选 $url ($source)';
  }

  @override
  String srvQcFailedRetry(String error) {
    return 'QuickConnect 查询失败，稍后重试：$error';
  }

  @override
  String get srvConnect => '连接';

  @override
  String get srvRestoring => '恢复中';

  @override
  String get srvRestoringSemantics => '正在恢复上次登录';

  @override
  String get srvRestoringHint => '正在恢复上次登录…';

  @override
  String srvLastAccount(String account, String server) {
    return '上次：$account@$server';
  }

  @override
  String get srvConnectToNas => '连接到你的 NAS';

  @override
  String srvOfflineBrowse(String account) {
    return '离线浏览缓存（上次：$account）';
  }

  @override
  String get srvDirectAddress => '直接地址';

  @override
  String get srvHostOrAddress => '主机或地址';

  @override
  String get srvQuickConnectExample => '例如 abc123-qq';

  @override
  String get srvHostExample => '例如 nas.example.com:5001';

  @override
  String get srvDesignPreview => '设计预览';

  @override
  String srvLoadFailed(String error) {
    return '读取失败：$error';
  }

  @override
  String get srvCertEmpty => '还没有信任任何服务器证书。\n首次连接自签证书的服务器时，会弹出证书详情让你确认。';

  @override
  String get srvCertUntrustTitle => '删除信任';

  @override
  String srvCertUntrustMessage(String host) {
    return '删除后，下次连接 $host 会重新让你确认证书指纹。';
  }

  @override
  String srvCertForgotten(String host) {
    return '已删除 $host 的信任';
  }

  @override
  String srvCertTrustedAt(String date) {
    return '信任于 $date';
  }

  @override
  String get srvCertChangedTitle => '服务器证书已变更';

  @override
  String get srvCertUntrustedTitle => '不受信任的证书';

  @override
  String srvCertChangedBody(String host) {
    return '$host 的证书与上次信任的不一致。如果服务器没有更换证书，这可能意味着有人在窃听，请勿继续。';
  }

  @override
  String srvCertUntrustedBody(String host) {
    return '$host 使用自签或不受系统信任的证书。确认这是你自己的服务器后再信任。';
  }

  @override
  String get srvCertOldFingerprint => '原指纹';

  @override
  String get srvCertFingerprint => '指纹 (SHA-256)';

  @override
  String get srvCertSubject => '主体';

  @override
  String get srvCertIssuer => '签发者';

  @override
  String get srvCertValidity => '有效期';

  @override
  String get srvCertSelfSigned => '自签名证书（常见于群晖 NAS）';

  @override
  String get srvCertTrustAnyway => '仍然信任';

  @override
  String get srvCertTrustAndContinue => '信任并继续';

  @override
  String get srvNotConnected => '尚未连接服务器';

  @override
  String get srvSavedCredentialsLocked => '已找到上次的服务器与账号，但本机保存的凭据无法解开，请重新输入密码';

  @override
  String get loginOtpLabel => '一次性验证码 (OTP)';

  @override
  String get loginOtpHint => '该账号开启了双重验证，请输入 6 位动态码';

  @override
  String get loginAction => '登录';

  @override
  String get loginTrustDevice => '信任此设备';

  @override
  String get loginTrustDeviceHint => '下次登录免验证码';

  @override
  String get usageModReader => '阅读';

  @override
  String get usageActLabel => '打标签';

  @override
  String get usageActSwitchSection => '切换板块';

  @override
  String get usageActOpenExternal => '外部打开';

  @override
  String get usageActBookmark => '收藏';

  @override
  String get usageActExport => '导出';

  @override
  String get usageActSync => '同步';

  @override
  String get usageActFailure => '失败';

  @override
  String get usageKindVolume => '数据量';

  @override
  String get usageKindPeakHour => '活跃时段';

  @override
  String get usageKindWeekdayPattern => '作息规律';

  @override
  String get usageKindTopModule => '最常用模块';

  @override
  String get usageKindTopAction => '主要行为';

  @override
  String get usageKindUnusedModule => '几乎没用的模块';

  @override
  String get usageKindModuleMix => '模块分布';

  @override
  String get usageKindFileTypePref => '文件类型偏好';

  @override
  String get usageKindTransferMix => '上传/下载';

  @override
  String get usageKindSizeMix => '文件体量';

  @override
  String get usageKindSearchQuality => '搜索命中率';

  @override
  String get usageKindEditCadence => '编辑活跃度';

  @override
  String get usageKindSessionLength => '单次使用时长';

  @override
  String get usageKindFailureHotspot => '失败集中点';

  @override
  String get usageKindFeatureGap => '功能空白';

  @override
  String get usageBandLateNight => '深夜(0-6)';

  @override
  String get usageBandMorning => '早晨(6-9)';

  @override
  String get usageBandForenoon => '上午(9-12)';

  @override
  String get usageBandNoon => '中午(12-14)';

  @override
  String get usageBandAfternoon => '下午(14-18)';

  @override
  String get usageBandEvening => '晚上(18-22)';

  @override
  String get usageBandNight => '夜里(22-24)';

  @override
  String usageTitleVolume(int count) {
    return '已有 $count 条使用记录';
  }

  @override
  String get usageBodyNoRecords => '还没有记录。用几天之后，这里会自动出现关于你使用习惯的结论。';

  @override
  String usageBodyVolume(int days, int sessions, int avg) {
    return '覆盖 $days 天、$sessions 段使用（平均 $avg 分钟/段）。';
  }

  @override
  String usageTitlePeakHour(String band) {
    return '你主要在$band用这个 App';
  }

  @override
  String usageBodyPeakHour(int pct, String band) {
    return '$pct% 的操作集中在$band。';
  }

  @override
  String usageBodyPeakHourWithHour(int pct, String band, int hour) {
    return '$pct% 的操作集中在$band，最忙的是 $hour:00 前后。';
  }

  @override
  String usageSugPeakHour(String band) {
    return '可以把「$band」最常用的入口做成时段推荐，其它时段把不常用模块收进第二屏。';
  }

  @override
  String get usageTitleWeekdayTool => '基本是\"工作日工具\"';

  @override
  String get usageTitleWeekendMore => '周末用得更多';

  @override
  String get usageTitleWeekdayMixed => '工作日/周末都有在用';

  @override
  String usageBodyWeekday(int wd, int rest) {
    return '工作日占 $wd%，周末占 $rest%。';
  }

  @override
  String get usageSugWeekend => '周末可以弱化办公模块，突出相册/笔记/阅读。';

  @override
  String usageTitleTopModule(String module, int share) {
    return '最常用：$module（$share%）';
  }

  @override
  String usageBodyTopModule(String list) {
    return '前三是 $list。';
  }

  @override
  String usageSugTopModule(String module) {
    return '第一屏优先放$module，并把它内部最常用的动作做成快捷入口。';
  }

  @override
  String usageTitleUnused(int count) {
    return '$count 个模块从没打开过';
  }

  @override
  String usageBodyUnused(String list) {
    return '$list 还没有使用记录。';
  }

  @override
  String get usageSugUnused =>
      '要么把这些入口从第一屏撤下（降低噪声），要么在对应场景给一次轻提示（比如打开 Office 文档时提示可以在「笔记」里归档）。';

  @override
  String usageTitleTopAction(String action) {
    return '主要在做：$action';
  }

  @override
  String usageActionCount(String action, int count) {
    return '$action $count 次';
  }

  @override
  String usageTitleFileType(String ext, int share) {
    return '最常处理 $ext（$share%）';
  }

  @override
  String usageBodyFileType(String list) {
    return '其次是 $list。';
  }

  @override
  String usageSugFileType(String ext) {
    return '把 $ext 的默认打开方式（预览/编辑）设成首选，并在打开后直接给出\"下一步\"动作。';
  }

  @override
  String get usageTitleUploadMain => '以\"上传\"为主';

  @override
  String get usageTitleDownloadMain => '以\"下载/预览\"为主';

  @override
  String get usageTitleTransferEven => '上传下载差不多';

  @override
  String usageBodyTransfer(int up, int down) {
    return '上传 $up 次，下载 $down 次。';
  }

  @override
  String get usageSugUploadMain => '上传是高频路径：默认落点目录、断点/并发、上传后自动索引提示值得加强。';

  @override
  String get usageSugDownloadMain => '读取为主：缩略图/首屏预览速度与离线缓存更值得投入。';

  @override
  String usageTitleSizeMix(String bucket) {
    return '上传体量集中在 $bucket';
  }

  @override
  String usageSizeEntry(String bucket, int count) {
    return '$bucket: $count 次';
  }

  @override
  String usageTitleSearchLow(int pct) {
    return '搜索\"搜不到\"的比例偏高（$pct%）';
  }

  @override
  String get usageTitleSearchGood => '搜索命中率不错';

  @override
  String usageBodySearch(int count, int empty) {
    return '共搜索 $count 次，其中 $empty 次没有结果。';
  }

  @override
  String get usageSugSearchLow => '可以考虑：搜索历史/建议词、把上次搜索范围默认带上、放宽文件名与内容的匹配。';

  @override
  String usageTitleEditHeavy(int pct) {
    return '用得比较\"重\"（编辑占比 $pct%）';
  }

  @override
  String usageTitleEditLight(int pct) {
    return '偏浏览（编辑占比 $pct%）';
  }

  @override
  String usageBodyEdit(int open, int edit) {
    return '打开 $open 次、编辑 $edit 次。';
  }

  @override
  String get usageSugEditHeavy => '编辑是核心：自动保存、版本历史（Drive 已有）、冲突提示要稳。';

  @override
  String get usageSugEditLight => '浏览是核心：首屏加载、缩略图、左右滑动切换更值得优化。';

  @override
  String usageTitleSession(int avg) {
    return '单次平均 $avg 分钟';
  }

  @override
  String usageBodySession(int count, int max) {
    return '一共 $count 段使用，最长 $max 分钟。';
  }

  @override
  String get usageSugSessionLong => '单次停留长：值得做\"继续上次的工作\"（最近文件/笔记）入口。';

  @override
  String get usageSugSessionShort => '单次停留短：把常用动作压到 1–2 次点击内更重要。';

  @override
  String usageTitleFailure(String key, int count) {
    return '失败最多：$key（$count 次）';
  }

  @override
  String usageFailureEntry(String key, int count) {
    return '$key $count';
  }

  @override
  String get usageSugFailure => '这些路径优先做错误文案、重试与降级（本地缓存兜底）。';

  @override
  String usageLocalLog(int count) {
    return '本地日志 · $count 条事件';
  }

  @override
  String get usageRefresh => '刷新分析';

  @override
  String usageExported(int count) {
    return '已复制 $count 字符的 JSON 到剪贴板';
  }

  @override
  String get usageClearTitle => '清空使用记录？';

  @override
  String get usageClearBody => '会删掉本机所有的原始使用事件和结论，不可恢复。\n（清空后重新积累几天，结论会再次出现。）';

  @override
  String get usageCleared => '已清空';

  @override
  String get usageEnableTitle => '记录本地使用日志';

  @override
  String get usageEnableSubtitle => '只记\"用了哪个模块的哪个动作\"和数量；不记文件名、标题、正文，也不上传。';

  @override
  String get usageSectionInsights => '结论';

  @override
  String get usageInsightsFailed => '算不出结论';

  @override
  String get usageInsightsEmptyTitle => '还没有结论';

  @override
  String get usageInsightsEmptyMessage => '用几天之后再回来看，这里会有基于你真实使用习惯的分析。';

  @override
  String get usageSectionData => '数据';

  @override
  String usageChipEvents(int count) {
    return '事件 $count';
  }

  @override
  String usageChipDays(int count) {
    return '天 $count';
  }

  @override
  String usageChipSessions(int count) {
    return '段 $count';
  }

  @override
  String usageChipAvg(int count) {
    return '平均 $count 分钟/段';
  }

  @override
  String usageChipSearch(int count) {
    return '搜索 $count';
  }

  @override
  String usageChipUpload(int count) {
    return '上传 $count';
  }

  @override
  String usageChipDownload(int count) {
    return '下载 $count';
  }

  @override
  String usageChipEdit(int count) {
    return '编辑 $count';
  }

  @override
  String usageDisabledNote(int count) {
    return '已关闭：不再记录新的事件；已有的 $count 条仍然在本机，可以导出或清空。';
  }

  @override
  String get usageShowRaw => '看原始事件';

  @override
  String get usageHideRaw => '收起原始事件';

  @override
  String get usageExportJson => '导出 JSON';

  @override
  String usageHidEntries(int count) {
    return '已把 $count 个入口收进第二屏（工作台里可「显示全部」还原）';
  }

  @override
  String usageHideAction(int count) {
    return '收起这 $count 个入口';
  }

  @override
  String usageHiddenCount(int count) {
    return '已收起 $count 个 · 显示全部';
  }

  @override
  String get usageHowToChange => '可以怎么改';

  @override
  String get usageEvidence => '统计口径';

  @override
  String usageMetaKind(String kind) {
    return '类型 $kind';
  }

  @override
  String usageMetaConfidence(int pct) {
    return '可信度 $pct%';
  }

  @override
  String usageMetaSource(String source) {
    return '来源 $source';
  }

  @override
  String get usageSourceHeuristic => '本地规则';

  @override
  String usageMetaModel(String model) {
    return '模型 $model';
  }

  @override
  String usageMetaStrategy(String key) {
    return '对应策略 $key';
  }

  @override
  String get usageNoEvents => '还没有事件';

  @override
  String get diagTitle => '空洞穿透诊断';

  @override
  String get diagRerunTooltip => '重跑';

  @override
  String get diagRerun => '重跑诊断';

  @override
  String get diagRunFirst => '运行诊断';

  @override
  String get diagNotRun => '尚未运行诊断 —— 点下方能量核开始';

  @override
  String get diagQcIdLabel => 'QuickConnect ID';

  @override
  String get diagQcIdHelper => '可留空，仅跑前两步';

  @override
  String get diagPassed => '通过';

  @override
  String get diagStepNativeLoad => '① 原生库加载';

  @override
  String get diagStepCApi => '② C ABI 调用';

  @override
  String get diagStepEchoList => '③ echo 列表（真实服务器）';

  @override
  String get diagStepTunnel => '④ 打洞建隧道';

  @override
  String get diagStepCandidates => '④-1 打洞候选';

  @override
  String get diagStepTunnelUp => '④-2 建立隧道';

  @override
  String get diagStepTunnelOk => '⑤ 隧道可用';

  @override
  String diagNativeFound(String lib) {
    return '找到 $lib';
  }

  @override
  String diagCApiDetail(int port, String running, String err) {
    return 'tcpPort=$port running=$running lastError=\"$err\" 设置/清空候选与 echo 均正常';
  }

  @override
  String diagEchoOk(int errno, String sites, int mss, int ms) {
    return 'errno=$errno sites=$sites udt_tx_mss=$mss 用时 ${ms}ms';
  }

  @override
  String get diagNativeUnavailable => '原生库不可用，跳过';

  @override
  String get diagNoQcId => '未填 QuickConnect ID —— 建隧道需真实凭据';

  @override
  String get diagEchoEmpty => 'echo 列表为空';

  @override
  String diagHostNoRecord(String host) {
    return '$host 无记录';
  }

  @override
  String diagHostResolveFailed(String host) {
    return '$host 解析失败';
  }

  @override
  String diagAllResolveFailed(String host) {
    return '全部解析失败，硬试 $host';
  }

  @override
  String diagCandidatesPicked(
    int count,
    String host,
    int port,
    String source,
    String tried,
  ) {
    return '$count 个，选 $host:$port ($source) | $tried';
  }

  @override
  String diagTunnelStart(int rc, String name, String err, int port, int ms) {
    return 'rc=$rc($name) lastError=\"$err\" tcpPort=$port 用时 ${ms}ms';
  }

  @override
  String get dpTitle => '设计预览 · HUD';

  @override
  String get dpSecSwitches => '效果开关（可现场对比）';

  @override
  String get dpSecScifi => '科幻层 · 深空座舱（本次新增）';

  @override
  String get dpSecPalette => '调色板 / 动态取色';

  @override
  String get dpSecBubbles => '消息气泡（分组 + 遥测时间 + 状态）';

  @override
  String get dpSecChips => '系统消息 / 日期分隔 / 新消息分隔';

  @override
  String get dpSecComposer => '输入区（玻璃胶囊 + 变身按钮）';

  @override
  String get dpSecRows => '会话列表行';

  @override
  String get dpSecIdentity => '头像 / 徽标 / 状态点';

  @override
  String get dpSecOrbs => '球按钮与铬部件';

  @override
  String get dpSecStates => '空态 / 错误态 / 骨架屏';

  @override
  String get dpSecSheet => '底部操作面板 + 快速回应';

  @override
  String get dpCommandTooltip => '命令台（示意）';

  @override
  String get dpCommandSnack => '命令台：模糊搜索频道与动作（后续批次）';

  @override
  String get dpDynamicColor => 'Material You 动态取色';

  @override
  String get dpDynamicColorHint => 'DYNAMIC COLOR · 跟随系统壁纸';

  @override
  String dpDeviceTier(String tier, String spec) {
    return '设备档位 $tier · $spec';
  }

  @override
  String get dpPerfModeHint => 'PERF · 关闭毛玻璃';

  @override
  String get dpPerfDefaultOffHigh => '默认关（高端机）';

  @override
  String get dpPerfDefaultOnLow => '默认开（中低端机）';

  @override
  String get dpReducedMotionHint => 'REDUCED MOTION · 无障碍 / 省电';

  @override
  String get dpMotionDefaultOnEntry => '默认开（入门机）';

  @override
  String get dpMotionDefaultOff => '默认关';

  @override
  String get dpChatGrid => '网格底纹';

  @override
  String get dpChatGridHint => 'GRID · 聊天页座舱氛围';

  @override
  String get dpGridDefaultOn => '默认开';

  @override
  String get dpGridDefaultOffEntry => '默认关（入门机）';

  @override
  String get dpConnectSemantics => '连接（示意）';

  @override
  String get dpEnergySnack => '能量核：主行动（示意）';

  @override
  String get dpEnergyOrbCaption => 'ENERGY ORB · 光环 + 反向轨道弧 + 进度环';

  @override
  String get dpReplayBoot => '重播启动自检';

  @override
  String get dpMaterialYouCaption => 'MATERIAL YOU · 主色跟随系统壁纸 · 状态永不只靠色相';

  @override
  String get dpBubble1 => '这个设计语言叫 HUD（座舱玻璃）—— 玻璃面 + 边缘高光 + 等宽遥测字。';

  @override
  String get dpBubble2 => '同一个人连续发消息时，内侧圆角收成 6，看起来是一\"段\"而不是一堵墙。';

  @override
  String get dpBubble3 => '时间/状态收进气泡右下角，省掉每行多占的那 16dp。';

  @override
  String get dpBubble4 => '我发的消息用主色玻璃，文字用 onPrimary 保证对比度。';

  @override
  String get dpBubble5 => '这条正在发送：环形扫描 + 遥测小字。';

  @override
  String get dpBubble6 => '这条发送失败，气泡下方直接给\"重试\"，不用长按。';

  @override
  String get dpBubble7 => '回应做成可点的 chip（点一下切换自己的回应）。';

  @override
  String get dpBubbleQuoted => '同一个人连续发消息时，内侧圆角收成 6…';

  @override
  String dpAvatarSemantics(String name) {
    return '$name 的头像';
  }

  @override
  String get dpResendHint => '点击重发';

  @override
  String dpSwitchReaction(String reaction) {
    return '切换回应：$reaction';
  }

  @override
  String get dpNewMessages => '以下为新消息';

  @override
  String get dpChannelCreated => '频道已创建';

  @override
  String get dpE2eeOn => '端到端加密已开启';

  @override
  String get dpAttachTooltip => '发送图片 / 文件';

  @override
  String get dpComposerTyped => '输入点东西试试…';

  @override
  String get dpComposerHint => '发消息…';

  @override
  String get dpHoldToTalk => '按住说话';

  @override
  String get dpSchedule => '定时';

  @override
  String get dpDemoChannel1 => '产品设计组';

  @override
  String get dpDemoPreview1 => '小林：HUD 那版气泡我把内角收到 6 了，你看下';

  @override
  String get dpDemoPreview2 => '刚才那条我重发了';

  @override
  String get dpDemoChannel2 => '运维告警';

  @override
  String get dpDemoPreview3 => '机器人：NAS 温度 41°C，正常范围';

  @override
  String get dpDemoChannel3 => '发布频道';

  @override
  String get dpDemoPreview4 => '发送失败 · 点击重试';

  @override
  String get dpDegraded => '已降级';

  @override
  String get dpToBottom => '到底部';

  @override
  String get dpStartConversation => '发送第一条消息，开始这段会话';

  @override
  String get dpCannotConnectNas => '无法连接到 NAS，请检查网络或重新登录';

  @override
  String get dpRetryDemo => '重试（示意）';

  @override
  String get dpMessageActions => '消息操作';

  @override
  String dpReactSnack(String emoji) {
    return '回应 $emoji';
  }

  @override
  String get dpReplyInThread => '在话题中回复';

  @override
  String get dpReplyInThreadDesc => '原版的话题制保持不动';

  @override
  String get dpCopyText => '复制文本';

  @override
  String get dpDownloadAttachment => '下载附件';

  @override
  String get dpDangerZone => '危险操作';

  @override
  String get dpDeleteMessage => '删除消息';

  @override
  String get dpBottomSheet => '底部操作面板';

  @override
  String get dpAttachGrid => '附件网格';

  @override
  String get dpFollowSystem => '跟随';

  @override
  String get dpLight => '亮';

  @override
  String get dpDark => '暗';

  @override
  String dpPick(String label) {
    return '选择：$label';
  }

  @override
  String get aiTaskSummary => '总结';

  @override
  String get aiTaskExplain => '解释';

  @override
  String get aiTaskTranslate => '翻译';

  @override
  String get aiTaskAskBook => '问这本书';

  @override
  String get aiEngineCloud => '云端模型';

  @override
  String get aiEngineOnDevice => '端侧模型';

  @override
  String get aiEngineExtractive => '内置摘要（无模型）';

  @override
  String get aiReadinessUnsupported => '这台设备不支持端侧推理';

  @override
  String get aiReadinessNeedsModel => '还没下载端侧模型';

  @override
  String get aiReadinessNeedsCloud => '云端还没配置';

  @override
  String get aiReadinessInstalling => '正在安装模型';

  @override
  String get aiReadinessReady => '模型就绪';

  @override
  String get aiNoteLfm => '体积最小（约 170MB），装得进任何机器；中文一般，适合先跑通。';

  @override
  String get aiNoteQwen => '推荐：中文好、答得像话，约 475MB，8GB 内存的机器跑得动。';

  @override
  String get aiTierCloud => '云端大模型';

  @override
  String aiSelectedChars(int count) {
    return '选中 $count 字';
  }

  @override
  String aiSheetTitle(String kind) {
    return 'AI 助手 · $kind';
  }

  @override
  String get aiAskHintDefault => '就这本书提问，例如\"作者的核心观点是什么\"';

  @override
  String get aiAskAction => '提问';

  @override
  String get aiCloudNoAnswer => '云端模型没答上来';

  @override
  String get aiNoAnswer => '这次没答上来';

  @override
  String aiCloudErrorDetail(String error) {
    return '$error\n\n检查「设置 → AI 服务」里的厂商地址、API Key 与模型 id；推理模型可把「最大长度」调大些。';
  }

  @override
  String aiOnDeviceErrorDetail(String error) {
    return '$error\n\n模型在手机上跑，内存紧张时会失败；可以稍后重试，或者换个更小的模型档位。';
  }

  @override
  String get aiThinking => '模型在思考…';

  @override
  String get aiCloudGenerating => '云端模型正在生成…';

  @override
  String get aiOnDeviceGenerating => '端侧模型正在生成…';

  @override
  String get aiExtracting => '正在提取要点…';

  @override
  String get aiPickAction => '选一个动作开始';

  @override
  String get aiPickActionHint => '总结 / 提问 / 解释选中，全部在本机完成。';

  @override
  String get aiEmptyAnswer => '模型没有给出内容';

  @override
  String get aiCloudEmptyDetail =>
      '云端返回了空回答。推理模型常见原因是「最大长度」太小，把思考过程用光了；去「AI 服务 → 高级参数」调大后重试。';

  @override
  String get aiOnDeviceEmptyDetail => '模型这次没输出内容，重试一次或换个小一点的模型档位。';

  @override
  String get aiGenerating => '生成中…';

  @override
  String aiBudgetRaised(int budget) {
    return '模型把长度用在了思考上，已自动加大到 $budget 重试（并已记住这个长度，下次直接用）';
  }

  @override
  String get aiCitedSource => '依据的原文';

  @override
  String aiInputTruncated(int chars) {
    return '原文太长，只取了前面 $chars 字';
  }

  @override
  String get aiStop => '停止';

  @override
  String get aiCopy => '复制';

  @override
  String get aiInstallOnDeviceModel => '装端侧模型';

  @override
  String get aiPickProvider => '选择厂商';

  @override
  String get aiPickProviderHint => '内置十几家常见服务；也可以选「自定义」填自己的中转地址';

  @override
  String get aiBaseUrlExample => '例如 https://api.deepseek.com/v1';

  @override
  String get aiDefault => '默认';

  @override
  String get aiKeyHintFallback => '按服务商要求填写';

  @override
  String get aiShow => '显示';

  @override
  String get aiKeyStored => 'key 存在系统安全存储（Android Keystore），不进普通偏好表';

  @override
  String get aiNoKeyCheck => '这家是本地/自建服务，通常不校验 key';

  @override
  String get aiWhereToGetKey => '去哪拿 key';

  @override
  String get aiModelLabel => '模型';

  @override
  String get aiModelExample => '例如 deepseek-chat';

  @override
  String get aiFetchModels => '获取模型列表';

  @override
  String get aiNoModelListInterface => '这家没有模型列表接口，手填即可';

  @override
  String aiAllModels(int count) {
    return '全部 $count 个';
  }

  @override
  String get aiCommonModels => '常见模型（拉不到列表时也能选）';

  @override
  String get aiTestConnection => '测试连接';

  @override
  String get aiCollapseAdvanced => '收起高级';

  @override
  String get aiAdvancedParams => '高级参数';

  @override
  String aiTemperature(String value) {
    return '温度 $value（越低越稳，越高越发散）';
  }

  @override
  String get aiMaxOutputTokens => '最大输出 tokens';

  @override
  String get aiProtocol => '协议';

  @override
  String get aiIntlService => '国际服务';

  @override
  String get aiChinaService => '国内服务';

  @override
  String get aiSelfHosted => '自建 / 本地';

  @override
  String aiSearchModels(int count) {
    return '搜索模型（共 $count 个）';
  }

  @override
  String get aiServiceTitle => 'AI 服务';

  @override
  String get aiEnable => '启用 AI 助手';

  @override
  String get aiEnableHint => '阅读器、笔记、文档里的 AI 入口';

  @override
  String get aiWifiOnly => '只在 WiFi 下载模型';

  @override
  String get aiWifiOnlyHint => '模型是几百 MB 级文件，别吃流量';

  @override
  String get aiWhichTier => '用哪一档';

  @override
  String aiTierCloudConfigured(String provider) {
    return '云端：$provider（原文会发到该服务商，注意隐私与费用）';
  }

  @override
  String aiTierCloudConfiguredModel(String provider, String model) {
    return '云端：$provider · $model（原文会发到该服务商，注意隐私与费用）';
  }

  @override
  String get aiTierCloudNotConfigured =>
      '还没配好云端：选厂商 + 填 key + 选模型，现在会自动用端侧/内置摘要兜底';

  @override
  String get aiTierOnDeviceDesc => '端侧：模型跑在本机，原文不出手机';

  @override
  String get aiTierExtractiveDesc => '内置摘要：从原文里挑句子，完全离线、零配置';

  @override
  String get aiCloudConfig => '云端配置';

  @override
  String get aiOnDeviceConfig => '端侧配置';

  @override
  String get aiExtractiveTitle => '内置摘要';

  @override
  String get aiChecking => '正在检查…';

  @override
  String aiCheckFailed(String error) {
    return '检查失败：$error';
  }

  @override
  String aiCurrentModel(String model) {
    return '当前模型：$model';
  }

  @override
  String aiCurrentModelBackend(String model, String backend) {
    return '当前模型：$model · 后端 $backend';
  }

  @override
  String get aiInstalled => '已安装';

  @override
  String get aiModelLocalOnly => '模型跑在本机，不需要联网。';

  @override
  String get aiUnsupportedHint => '这台设备用「内置摘要」：从原文里挑句子，不上模型。';

  @override
  String get aiModelTiers => '模型档位';

  @override
  String get aiWhyLocal => '为什么放在本机';

  @override
  String get aiTextStaysLocal => '原文不出手机';

  @override
  String get aiTextStaysLocalBody =>
      '选中/章节的文本只在这台手机上做推理，不上传服务器、不写远端日志。下载走 HTTPS，来自 Hugging Face 的 litert-community 组织。';

  @override
  String get aiNoConfigNeeded => '不需要任何配置';

  @override
  String get aiNoConfigNeededBody =>
      '内置摘要用纯 Dart 的抽取式算法（挑出原文里信息量最大的句子），不联网、不下载模型。适合\"就想快速看要点\"，复杂问题会力不从心。';

  @override
  String get aiTryIt => '试用';

  @override
  String get aiTryHint => '贴一段文字，看它能不能总结出要点';

  @override
  String get aiTryAction => '试一句';

  @override
  String get aiCloudReady => '云端模型就绪';

  @override
  String get aiOnDeviceReady => '端侧模型就绪';

  @override
  String get aiExtractiveReady => '内置摘要可用';

  @override
  String aiProbeFailed(String error) {
    return '失败：$error';
  }

  @override
  String get aiOrphanFiles => '本机上的其它模型文件';

  @override
  String get aiOrphanBody => '不在当前模型目录里（换过版本留下的旧文件）';

  @override
  String get aiRecommended => '推荐';

  @override
  String aiDownloading(int percent) {
    return '下载中 $percent%';
  }

  @override
  String aiDownloadingMirror(int percent) {
    return '下载中 $percent%（直连不通，走 hf-mirror 镜像）';
  }

  @override
  String aiDownload(String size) {
    return '下载（$size）';
  }

  @override
  String get aiInUse => '当前使用';

  @override
  String get aiSetCurrent => '设为当前';

  @override
  String get aiAssistant => 'AI 助手';

  @override
  String get aiExpandAssistant => '展开 AI 助手';

  @override
  String get aiNotProbed => '还没探测';

  @override
  String get aiPlatformExtractive => '这个平台用内置摘要（端侧模型只支持 Android/iOS）';

  @override
  String get aiPlatformUnsupported => '这个平台不支持端侧模型，功能会自动用内置摘要';

  @override
  String get aiDownloadFailedNetwork => '下载失败：直连与镜像都不通（几百 MB 的模型建议连 WiFi 再试）';

  @override
  String get aiDownloadFailedStorage => '下载失败：存储空间不够';

  @override
  String get aiDownloadFailedAuth => '下载失败：这个模型需要授权（换一个档位试试）';

  @override
  String aiDownloadFailed(String error) {
    return '下载失败：$error';
  }

  @override
  String aiNoModelListNamed(String provider) {
    return '$provider没有模型列表接口，直接手填或点下面的常见模型';
  }

  @override
  String get aiPickProviderFirst => '先选厂商或填 base URL';

  @override
  String get aiNoModelListReturned => '这家没返回模型列表，手填模型 id 吧';

  @override
  String get aiTestIncomplete => '还没填完（base URL + 模型）';

  @override
  String get aiTestNoText => '通了（服务端没回文本，可能这个模型不支持这条提示）';

  @override
  String aiTestOk(String text) {
    return '通了：$text';
  }

  @override
  String get aiEngineReadyNoModel => '引擎已就绪，但还没下载模型';

  @override
  String get aiDownloadFailedShort => '下载失败';

  @override
  String get aiExtractiveNotFound => '原文里没有提到。';

  @override
  String get aiExtractivePassagesHeader => '原文最相关的几段（未上模型，直接摘录）：\n';

  @override
  String get aiExtractiveTooShort => '这段内容太短，没什么可总结的。';

  @override
  String get aiCloudNotConfiguredHint => '云端还没配好：填上 base URL 和模型就行';

  @override
  String get aiCloudNotConfigured => '云端还没配好：去「设置 → AI 服务」填厂商与模型';

  @override
  String aiBudgetExhausted(String error, int from, int to) {
    return '$error；已自动把最大长度从 $from 加大到 $to 重试，仍然没写出正文。可以继续调大长度，或者换一个非推理模型。';
  }

  @override
  String get aiExtractiveEngineDetail => '不上模型：从原文里挑句子';

  @override
  String get chatSectionUnread => '未读';

  @override
  String get dictPosNoun => '名词';

  @override
  String get dictPosVerb => '动词';

  @override
  String get dictPosAdjective => '形容词';

  @override
  String get dictPosAdverb => '副词';

  @override
  String get dictPosPronoun => '代词';

  @override
  String get dictPosPreposition => '介词';

  @override
  String get dictPosConjunction => '连词';

  @override
  String get dictPosInterjection => '感叹词';

  @override
  String get dictPosNumeral => '数词';

  @override
  String get dictPosPhrase => '短语';

  @override
  String get dictPosOther => '其他';

  @override
  String get bookDictTitle => '查词';

  @override
  String get bookDictLookup => '查词';

  @override
  String bookDictNotFound(String word) {
    return '内置词表里没有「$word」';
  }

  @override
  String get bookDictNotFoundHint => '可以退回选中菜单，用「解释」让 AI 讲这段';

  @override
  String bookDictSource(int count) {
    return '内置词表 · $count 词';
  }

  @override
  String get bookTtsReadAloud => '朗读';

  @override
  String get bookExportNote => '导出到笔记';

  @override
  String get bookTtsTitle => '朗读本章';

  @override
  String get bookTtsPause => '暂停';

  @override
  String get bookTtsResume => '继续';

  @override
  String get bookTtsStop => '停止';

  @override
  String get bookTtsNext => '下一段';

  @override
  String get bookTtsPrev => '上一段';

  @override
  String bookTtsState(int n, int total) {
    return '第 $n/$total 段';
  }

  @override
  String get bookTtsIdle => '点「播放」从本段开始朗读';

  @override
  String get bookTtsResumeHint => '继续会从本段开头重读（系统语音不支持断点续读）';

  @override
  String get bookTtsUnsupported => '这台设备没有可用的语音引擎';

  @override
  String bookTtsFailed(String error) {
    return '朗读失败：$error';
  }

  @override
  String bookExportTitle(String book, int n) {
    return '《$book》· 第 $n 章 摘录';
  }

  @override
  String get bookExportTagReader => '读书笔记';

  @override
  String bookExportTagChapter(int n) {
    return '第$n章';
  }

  @override
  String bookExportWhere(String book, int n) {
    return '《$book》第 $n 章';
  }

  @override
  String bookExportWherePercent(String book, int n, int percent) {
    return '《$book》第 $n 章 · 位置 $percent%';
  }

  @override
  String bookExportSource(String where, int total) {
    return '$where（共 $total 章）';
  }

  @override
  String bookExportSourceNamed(String where, String chapter, int total) {
    return '$where $chapter（共 $total 章）';
  }

  @override
  String get bookExportNotebook => '读书笔记';

  @override
  String bookExportNotebookReady(String notebook) {
    return '已存到「$notebook」';
  }

  @override
  String bookExportFailed(String error) {
    return '导出失败：$error';
  }

  @override
  String get bookExportTagFailed => '笔记已建好，但标签没写上（版本号取不到）';

  @override
  String get bookLinkBack => '返回原处';

  @override
  String get bookLinkNotFound => '这个链接指向的内容不在书里';

  @override
  String bookLinkExternalFailed(String url) {
    return '打不开这个链接：$url';
  }

  @override
  String get bookSendChapterTitle => '把整章发给 AI？';

  @override
  String bookSendChapterBody(int chars) {
    return '这一章约 $chars 字。只有在「AI 设置」里配好模型后才发得出去；云端档会把正文发到网上，端侧/内置档不出机器。只发送这一章。';
  }

  @override
  String get bookSendChapterConfirm => '发送整章';

  @override
  String get bookAiNoKey => '还没配 AI：设置 → AI 助手 → 云端大模型，填地址与 key';

  @override
  String get bookAiNoKeyShort => 'AI 还没配好';

  @override
  String get aiProtoOpenai => 'OpenAI 兼容';

  @override
  String get aiProvOpenaiNote => '国内直连通常不通，需要代理或中转地址';

  @override
  String get aiProvAnthropicNote =>
      'Messages 协议：鉴权用 x-api-key，必须带 anthropic-version 头';

  @override
  String get aiProvGeminiNote => 'key 走查询串；国内直连通常需要代理';

  @override
  String get aiProvDeepseekName => 'DeepSeek 深度求索';

  @override
  String get aiProvDeepseekNote =>
      '中文/代码能力强、价格低（官方示例用 api.deepseek.com，/v1 也兼容）';

  @override
  String get aiProvMoonshotNote => '长文本见长';

  @override
  String get aiProvZhipuName => '智谱 GLM';

  @override
  String get aiProvZhipuKeyHint => '形如 id.secret';

  @override
  String get aiProvZhipuNote => 'base URL 带 /api/paas/v4；没有模型列表接口，模型 id 手填';

  @override
  String get aiProvDashscopeName => '阿里云百炼（通义千问）';

  @override
  String get aiProvDashscopeNote =>
      '必须用 compatible-mode 这段路径；官方未记载列表接口，模型 id 手填；新域名带 WorkspaceId 且 key 按地域绑定（北京 key 调新加坡会 401）';

  @override
  String get aiProvSiliconflowName => '硅基流动 SiliconFlow';

  @override
  String get aiProvSiliconflowNote => '一个 key 能调很多开源模型';

  @override
  String get aiProvVolcesName => '火山方舟（豆包）';

  @override
  String get aiProvVolcesKeyHint => '形如 uuid';

  @override
  String get aiProvVolcesNote =>
      '模型 id 要填\"推理接入点\"（ep-…）；官方文档站是 JS 渲染，base URL 没能逐字核实，连不上就换中转地址';

  @override
  String get aiProvOpenrouterNote => '一个 key 转发几百个模型';

  @override
  String get aiProvQianfanName => '百度千帆';

  @override
  String get aiProvQianfanNote => 'base URL 带 /v2；key 是 bce-v3 那种长串';

  @override
  String get aiProvHunyuanName => '腾讯混元';

  @override
  String get aiProvHunyuanNote => '官方未给模型列表接口，模型 id 手填；后续会迁到 TokenHub';

  @override
  String get aiProvOllamaName => 'Ollama（本机/局域网）';

  @override
  String get aiProvOllamaKeyHint => 'Ollama 不校验，留空也行';

  @override
  String get aiProvOllamaNote =>
      '默认端口 11434；手机连电脑要把 localhost 换成电脑的局域网 IP。OpenAI 兼容层要求带 key 字段但会忽略它，我们会自动补一个占位值';

  @override
  String get aiProvLmstudioName => 'LM Studio（本机/局域网）';

  @override
  String get aiProvLmstudioKeyHint => '不校验，随便填或留空';

  @override
  String get aiProvLmstudioNote => '默认端口 1234';

  @override
  String get aiProvVllmName => 'vLLM / 自建 OpenAI 服务';

  @override
  String get aiProvVllmKeyHint => '看服务端配置';

  @override
  String get aiProvVllmNote => '默认端口 8000；one-api / new-api / LiteLLM 这类网关也走这条';

  @override
  String get aiProvCustomName => '自定义 / 中转地址';

  @override
  String get aiProvCustomKeyHint => '按服务商要求填写';

  @override
  String get aiProvCustomNote => '填完整的 base URL（带版本路径），可选协议类型';

  @override
  String get aiModelPickerManual => '直接手填模型 id';

  @override
  String get aiModelPickerCommon => '也可以从下面这些常见模型里挑';

  @override
  String aiErrRequestRejected(String tail) {
    return '请求被拒绝（400）$tail';
  }

  @override
  String aiErrKeyInvalid(String tail) {
    return 'API Key 无效或已过期（401）$tail';
  }

  @override
  String aiErrInsufficientBalance(String tail) {
    return '余额不足（402）$tail';
  }

  @override
  String aiErrNoPermission(String tail) {
    return '没有权限或被区域限制（403）$tail';
  }

  @override
  String aiErrNotFound(String tail, String url) {
    return '地址或模型不存在（404）$tail —— 检查 base URL 与模型 id$url';
  }

  @override
  String aiErrBodyTooLarge(String tail) {
    return '请求体太大（413）$tail';
  }

  @override
  String aiErrParamsRejected(String tail) {
    return '参数不被接受（422）$tail';
  }

  @override
  String aiErrRateLimited(String tail) {
    return '触发限流或额度用尽（429），等一会儿再试$tail';
  }

  @override
  String aiErrServer(int code, String tail) {
    return '服务端错误（$code）$tail';
  }

  @override
  String aiErrRequestFailed(int code, String tail) {
    return '请求失败（$code）$tail';
  }

  @override
  String aiErrNotJson(String error) {
    return '服务端返回的不是 JSON（可能被网关或登录页拦截了）：$error';
  }

  @override
  String get aiErrNoStream => '服务端没有返回内容（可能这个模型不支持流式）';

  @override
  String aiErrModelError(String message) {
    return '模型返回了错误：$message';
  }

  @override
  String get aiErrNoContent => '模型没有返回任何内容（网关可能忽略了流式请求；换个模型或检查地址）';

  @override
  String get aiTruncatedNote => '\n\n（回答已达长度上限被截断，可在「AI 服务 → 高级参数」调大最大长度）';

  @override
  String aiReasoningOnlyBudget(int budget, int chars, String reason) {
    return '模型把 $budget token 全用在思考上，没写出正文（收到 $chars 字思考内容）';
  }

  @override
  String aiReasoningOnlyPlain(int chars) {
    return '模型只回了思考过程，没有正文（收到 $chars 字思考内容）';
  }

  @override
  String aiErrConnectTimeout(String host) {
    return '连接超时：连不上 $host（检查网络、代理或地址）';
  }

  @override
  String get aiErrWaitTimeout => '等待响应超时：模型太久没回数据（可以换个更快的模型）';

  @override
  String get aiErrBadCertificate => '证书校验失败（自签名证书需要信任后才能连）';

  @override
  String get aiErrCancelled => '已取消';

  @override
  String aiErrLocalService(String host) {
    return '连不上 $host：如果这是本机服务，手机要填电脑/服务器的局域网 IP，不能用 localhost';
  }

  @override
  String aiErrUnreachable(String host) {
    return '连不上 $host：网络不通或被拦截（国内直连国外服务通常需要代理）';
  }

  @override
  String aiErrUnknown(String error) {
    return '请求出错：$error';
  }

  @override
  String get aiCancelReason => '用户取消';

  @override
  String get aiCompleteSystemDefault => '你是简洁的助手。';

  @override
  String get aiCompleteUserDefault => '只回三个字：连接成功';

  @override
  String get aiProfileNeedProvider => '先选一个厂商再保存配置';

  @override
  String get aiProfileKeepOne => '至少要留一套配置';

  @override
  String get aiProfileUntitled => '未命名配置';

  @override
  String get aiProfilesTitle => '配置方案';

  @override
  String aiProfileCount(int n) {
    return '共 $n 套';
  }

  @override
  String get aiProfileKeyNote => 'key 仍只放在系统安全存储里，不进配置表';

  @override
  String get aiProfileEmpty => '还没有保存的配置';

  @override
  String get aiProfileSaveAs => '存为新配置';

  @override
  String get aiProfileSaveAsHint => '把当前配置另存为一套，随时一键切换（同一家可以并存多套）';

  @override
  String aiProfileSaved(String name) {
    return '已保存为「$name」';
  }

  @override
  String get aiProfileRename => '重命名';

  @override
  String get aiProfileDelete => '删除配置';

  @override
  String aiProfileDeleteConfirm(String name) {
    return '删除「$name」？它的 key 也会从安全存储里删掉。';
  }

  @override
  String aiProfileDeleted(String name) {
    return '已删除「$name」';
  }

  @override
  String get aiProfileNameHint => '例如：公司中转 / 家里的 Ollama';

  @override
  String get aiProfileSwitch => '切换';

  @override
  String get aiProfileNone => '还没有配置';

  @override
  String get aiUsageTitle => '用量与费用';

  @override
  String get usageObjTask => '任务';

  @override
  String get usageObjOther => '其它';

  @override
  String get usageObjVoice => '语音';

  @override
  String get usageObjTemplate => '模板';

  @override
  String get usageObjRss => 'RSS';

  @override
  String get usageObjNote => '笔记';

  @override
  String get usageObjEmule => '电驴';

  @override
  String get usageObjVideoFrame => '视频帧';

  @override
  String get usageObjSong => '歌曲';

  @override
  String get usageObjFolder => '文件夹';

  @override
  String get usageObjEvent => '日程';

  @override
  String get usageObjDm => '私聊';

  @override
  String get usageObjSystem => '系统';

  @override
  String get usageObjMessage => '消息';

  @override
  String get usageObjMessages => '多条消息';

  @override
  String get usageObjFindme => '查找我的设备';

  @override
  String get usageObjFile => '文件';

  @override
  String get usageObjBeep => '蜂鸣';

  @override
  String get usageObjUrl => '链接';

  @override
  String get usageObjMagnet => '磁力链接';

  @override
  String get usageObjTts => '语音合成';

  @override
  String get usageObjTodo => '待办';

  @override
  String get usageObjText => '文本';

  @override
  String get usageObjSnooze => '暂停提醒';

  @override
  String get usageObjSnoozeSchedule => '暂停计划';

  @override
  String get usageObjProfile => '个人资料';

  @override
  String get usageObjPollResults => '投票结果';

  @override
  String get usageObjMonth => '月份';

  @override
  String get usageObjMail => '邮件';

  @override
  String get usageObjContact => '联系人';

  @override
  String get usageObjChapter => '章节';

  @override
  String get usageObjCamera => '摄像头';

  @override
  String get usageObjBt => '蓝牙';

  @override
  String get usageObjBackup => '备份';

  @override
  String get usageObjAlbumSort => '相册排序';

  @override
  String get usageObjAiSelect => 'AI 选择';

  @override
  String get usageObjNas => 'File Station';

  @override
  String get usageFailOther => '未归类';

  @override
  String get aiServerChannelDesc => '已检测到服务端生成能力：聊天可以改用 NAS 的算力回答（原文会发到 NAS）';

  @override
  String get aiServerChannelTitle => 'NAS 端 AI 通道';

  @override
  String get aiUsageEntry => '本地估算的用量与费用';

  @override
  String get aiUsageEstimateNote =>
      '以下数字由本机按调用记录估算：token 优先用服务端返回的 usage，缺失时按字符数折算；费用按内置单价表折算。这不是服务商的账单，请以官方后台为准。';

  @override
  String aiUsagePriceNote(String date) {
    return '单价表更新于 $date，只覆盖常见模型；认不出单价的按「未知」处理，自建/本地服务按 0 计。';
  }

  @override
  String get aiUsageRangeAll => '全部';

  @override
  String get aiUsageRange7 => '近 7 天';

  @override
  String get aiUsageRange30 => '近 30 天';

  @override
  String get aiUsageEmpty => '还没有云端调用记录';

  @override
  String get aiUsageEmptyHint => '用云端模型跑一次总结，这里就会有数据';

  @override
  String aiUsageCalls(int n) {
    return '$n 次调用';
  }

  @override
  String aiUsagePromptTokens(int n) {
    return '输入 token：$n';
  }

  @override
  String aiUsageCompletionTokens(int n) {
    return '输出 token：$n';
  }

  @override
  String aiUsageTotalTokens(int n) {
    return '合计 token：$n';
  }

  @override
  String aiUsageReasoningTokens(int n) {
    return '其中思考 token：$n';
  }

  @override
  String aiUsageEstimatedCalls(int n) {
    return '其中 $n 次的 token 是估算';
  }

  @override
  String aiUsageUnpriced(int n) {
    return '$n 次未计价（单价未知）';
  }

  @override
  String aiUsageCost(String amount) {
    return '约 $amount';
  }

  @override
  String get aiUsageByModel => '按模型';

  @override
  String get aiUsageByDay => '按日期';

  @override
  String get aiUsageClear => '清空统计';

  @override
  String get aiUsageClearConfirm => '清空本机的用量记录？（不影响服务商那边的账单）';

  @override
  String get aiUsageCleared => '已清空用量记录';

  @override
  String get aiThinkingFold => '展开思考过程';

  @override
  String get aiThinkingCollapse => '收起思考过程';

  @override
  String aiThinkingChars(int n) {
    return '$n 字';
  }

  @override
  String get aiThinkingCopy => '复制思考内容';

  @override
  String get aiThinkingCopied => '思考内容已复制';

  @override
  String get aiUsageCostUnknown => '单价未知';

  @override
  String get wsRecentTitle => '最近常用';

  @override
  String get bookContinueTitle => '继续阅读';

  @override
  String bookContinuePercent(int pct) {
    return '已读 $pct%';
  }

  @override
  String bookContinueProgress(int n, int total, int pct) {
    return '第 $n/$total 章 · $pct%';
  }

  @override
  String get dsTitle => '下载';

  @override
  String get dsStatusDownloading => '下载中';

  @override
  String get dsStatusError => '错误';

  @override
  String get dsStatusWaiting => '等待中';

  @override
  String get dsStatusPaused => '已暂停';

  @override
  String get dsStatusSeeding => '做种中';

  @override
  String get dsStatusPreSeeding => '准备做种';

  @override
  String get dsStatusHashChecking => '校验中';

  @override
  String get dsStatusFinishing => '完成中';

  @override
  String get dsStatusExtracting => '解压中';

  @override
  String get dsStatusPreprocessing => '预处理中';

  @override
  String get dsStatusPostprocessing => '后处理中';

  @override
  String get dsStatusDownloaded => '已下载';

  @override
  String get dsStatusCaptchaNeeded => '需要验证码';

  @override
  String get dsStatusFilehostingWaiting => '等待文件托管';

  @override
  String dsStatusCode(int code) {
    return '状态 $code';
  }

  @override
  String get dsStatusErrBrokenLink => '链接已失效';

  @override
  String get dsStatusErrDestNotExist => '下载目录不存在';

  @override
  String get dsStatusErrDestDeny => '下载目录无权限';

  @override
  String get dsStatusErrDiskFull => '磁盘空间不足';

  @override
  String get dsStatusErrQuota => '超出存储配额';

  @override
  String get dsStatusErrTimeout => '下载超时';

  @override
  String get dsStatusErrFileSize => '超出文件系统大小上限';

  @override
  String get dsStatusErrTorrentDuplicate => '这个种子已在任务列表里';

  @override
  String get dsStatusErrFileNotExist => '文件不存在';

  @override
  String get dsStatusErrExtractFailed => '解压失败';

  @override
  String get dsStatusErrExtractPassword => '解压密码错误';

  @override
  String get dsStatusErrExtractInvalid => '压缩包已损坏';

  @override
  String get dsStatusErrTorrentInvalid => '种子文件无效';

  @override
  String get dsStatusErrRequiredAccount => '需要账号信息';

  @override
  String get dsStatusErrTryLater => '服务端繁忙，请稍后再试';

  @override
  String get dsStatusErrNameTooLong => '文件名过长';

  @override
  String get dsLoadFailed => '下载任务加载失败';

  @override
  String get dsEmptyTitle => '还没有下载任务';

  @override
  String get dsEmptyMessage => '点「新建任务」添加链接、磁力或种子文件';

  @override
  String get dsEmptyFiltered => '这个分类下暂无任务';

  @override
  String get dsErrNotInstalled => '这台 NAS 没有安装 Download Station';

  @override
  String get dsErrNoPrivilege => '这个账号没有使用 Download Station 的权限';

  @override
  String get dsErrNetwork => '网络连接失败，请检查网络后重试';

  @override
  String get dsErrLoadDetail => '任务详情加载失败';

  @override
  String get dsErrTaskNotFound => '任务不存在（可能已被删除）';

  @override
  String get dsErrNoDefaultDest => '还没有设置默认下载目录，请先填写下载目录';

  @override
  String get dsErrUploadFailed => '种子文件上传失败';

  @override
  String get dsErrReachLimit => '任务数量已达上限';

  @override
  String get dsErrRequestInvalid => '请求参数不被接受';

  @override
  String get dsErrJsonParse => '服务端无法解析请求数据';

  @override
  String get dsErrActionFailed => '操作失败';

  @override
  String get dsErrSystem => 'Download Station 服务异常';

  @override
  String get dsErrPathNotExist => '路径不存在';

  @override
  String get dsErrUnlinkFailed => '删除文件失败（任务可能仍已移除）';

  @override
  String get dsErrDemo => '演示模式下不允许这个操作';

  @override
  String dsErrUnknown(int code) {
    return '未知错误（$code）';
  }

  @override
  String get dsPause => '暂停';

  @override
  String get dsResume => '继续';

  @override
  String get dsDeleteTitle => '删除任务？';

  @override
  String get dsDeleteBody => '任务会从下载列表中移除，此操作无法恢复。';

  @override
  String dsDeleteBodyN(int n) {
    return '选中的 $n 个任务会从下载列表中移除，此操作无法恢复。';
  }

  @override
  String get dsDeleted => '已删除';

  @override
  String dsDeleteFailed(String msg) {
    return '删除失败：$msg';
  }

  @override
  String dsPauseFailed(String msg) {
    return '暂停失败：$msg';
  }

  @override
  String dsResumeFailed(String msg) {
    return '继续失败：$msg';
  }

  @override
  String get dsStatusLabel => '状态';

  @override
  String get dsProgress => '进度';

  @override
  String get dsSize => '大小';

  @override
  String get dsDownloadSpeed => '下载速度';

  @override
  String get dsUploadSpeed => '上传速度';

  @override
  String get dsEta => '剩余时间';

  @override
  String get dsDestination => '下载目录';

  @override
  String get dsType => '类型';

  @override
  String get dsHash => '哈希';

  @override
  String get dsPeers => '连接数';

  @override
  String get dsCreator => '创建者';

  @override
  String get dsAddedTime => '添加时间';

  @override
  String get dsCompletedTime => '完成时间';

  @override
  String get dsDetail => '任务详情';

  @override
  String get dsTaskId => '任务 ID';

  @override
  String dsTotalDown(String rate) {
    return '下载 $rate';
  }

  @override
  String dsTotalUp(String rate) {
    return '上传 $rate';
  }

  @override
  String dsTotalTasks(int count) {
    return '共 $count 个任务';
  }

  @override
  String get dsNewTask => '新建任务';

  @override
  String get dsCreateUrl => '链接';

  @override
  String get dsCreateFile => '种子文件';

  @override
  String get dsUrlHint => '支持 HTTP／FTP／磁力／迅雷等链接，每行一个';

  @override
  String get dsUrlRequired => '请输入至少一个链接';

  @override
  String get dsTooManyUrls => '一次最多添加 50 个链接';

  @override
  String get dsPickTorrent => '选择 .torrent／.nzb 文件';

  @override
  String get dsFileTooLarge => '文件不能超过 100 MB';

  @override
  String get dsChooseDestination => '下载目录（留空用默认目录）';

  @override
  String dsDefaultDestination(String path) {
    return '默认：$path';
  }

  @override
  String get dsExtractPassword => '解压密码';

  @override
  String get dsExtractPasswordHint => '可选，压缩包加密时填写';

  @override
  String get dsCreated => '任务已创建';

  @override
  String dsCreateFailed(String msg) {
    return '创建任务失败：$msg';
  }

  @override
  String get dsCreateList => '创建后先选择要下载的文件';

  @override
  String get dsCreateListHint => '适合只想下载部分文件的种子';

  @override
  String get dsBtSettings => 'BT 设置';

  @override
  String get dsBtMaxDownload => '最大下载速度（KB/s）';

  @override
  String get dsBtMaxUpload => '最大上传速度（KB/s）';

  @override
  String get dsBtSeedingRatio => '做种率';

  @override
  String get dsBtSeedingInterval => '做种时间（分钟）';

  @override
  String get dsBtMaxPeers => '最大连接数';

  @override
  String get dsBtUnlimited => '不限';

  @override
  String get dsBtRateHint => '0 表示不限速';

  @override
  String get dsBtSaved => 'BT 设置已保存';

  @override
  String dsBtSaveFailed(String msg) {
    return '保存失败：$msg';
  }

  @override
  String get dsBtLoadFailed => 'BT 设置加载失败';

  @override
  String get dsBtNotSupported => '这个任务不是 BT 任务';

  @override
  String get dsNotInstalledHint => '在 DSM「套件中心」安装 Download Station 后即可使用';

  @override
  String get dsNoPrivilegeHint => '请联系管理员为这个账号授予 Download Station 权限';

  @override
  String get pbTitle => '手机备份';

  @override
  String get pbAutoBackup => '自动备份';

  @override
  String get pbAutoBackupHint => '打开后进入本页即可一键增量备份';

  @override
  String get pbCancel => '取消';

  @override
  String pbCountFailed(int n) {
    return '失败 $n';
  }

  @override
  String pbCountPending(int n) {
    return '待传 $n';
  }

  @override
  String pbCountSkipped(int n) {
    return '跳过 $n';
  }

  @override
  String get pbErrorTitle => '备份失败';

  @override
  String get pbFailedTitle => '失败的文件';

  @override
  String get pbFolderPickTitle => '选择目标相册';

  @override
  String get pbGrant => '去授权';

  @override
  String get pbIncludeVideos => '备份视频';

  @override
  String pbLastFinished(String time) {
    return '上次完成：$time';
  }

  @override
  String get pbNeverFinished => '还没备份过';

  @override
  String get pbNotConnected => '还没有连接 NAS';

  @override
  String get pbNothingToDo => '没有需要备份的新照片';

  @override
  String get pbPause => '暂停';

  @override
  String get pbPermissionDenied => '没有权限读不到本机照片，请允许访问「照片和视频」后再试';

  @override
  String get pbPermissionGranted => '已获得相册读取权限';

  @override
  String get pbPermissionPartial => '只授权了选中的照片，备份会不完整；请改成「允许全部」';

  @override
  String get pbPermissionTitle => '相册读取权限';

  @override
  String get pbPreparing => '正在扫描本机相册并比对 NAS…';

  @override
  String pbProgress(int done, int total) {
    return '已备份 $done/$total';
  }

  @override
  String get pbResume => '继续';

  @override
  String get pbRetryFailed => '重试失败项';

  @override
  String get pbStart => '开始备份';

  @override
  String get pbTargetCreate => '新建目标相册';

  @override
  String get pbTargetNone => '还没有选择目标相册';

  @override
  String pbTargetReady(String name) {
    return '目标：$name';
  }

  @override
  String get pbTargetTitle => '目标相册';

  @override
  String get pbWifiBlocked => '当前不是 Wi-Fi，已按「仅 Wi-Fi」暂停';

  @override
  String get pbWifiOnly => '仅 Wi-Fi 时备份';

  @override
  String get ptClearSelection => '取消全选';

  @override
  String get ptExitSelection => '退出多选';

  @override
  String get ptSelectAll => '全选';

  @override
  String ptSelectedCount(int n) {
    return '已选 $n 张';
  }

  @override
  String ptSelectedTags(int n) {
    return '已选 $n 个标签';
  }

  @override
  String get ptTag => '标签';

  @override
  String ptTagApplied(int n) {
    return '已给 $n 张照片打上标签';
  }

  @override
  String ptTagApplyFailed(String msg) {
    return '打标签失败：$msg';
  }

  @override
  String ptTagCreate(String name) {
    return '新建标签「$name」';
  }

  @override
  String ptTagCreateFailed(String msg) {
    return '新建标签失败：$msg';
  }

  @override
  String ptTagFailed(int n) {
    return '$n 个操作失败';
  }

  @override
  String get ptTagLoadFailed => '标签加载失败，仍可以新建标签';

  @override
  String get ptTagNone => '还没有标签';

  @override
  String get ptTagSearchHint => '输入标签名搜索或新建';

  @override
  String ptTagSheetTitle(int n) {
    return '标签（已选 $n 张）';
  }

  @override
  String ptTagUpdated(int n) {
    return '已更新 $n 张照片的标签';
  }

  @override
  String pbAllDone(int done, int skipped) {
    return '备份完成：新增 $done，跳过 $skipped';
  }

  @override
  String get asTitle => '音乐';

  @override
  String get asTabSongs => '歌曲';

  @override
  String get asTabAlbums => '专辑';

  @override
  String get asTabArtists => '艺术家';

  @override
  String get asTabGenres => '流派';

  @override
  String get asTabFolders => '文件夹';

  @override
  String get asTabPlaylists => '播放列表';

  @override
  String get asSearchTitle => '搜索音乐';

  @override
  String get asSearchHint => '搜索歌曲、专辑或艺术家';

  @override
  String get asSearchEmpty => '没有找到匹配的音乐';

  @override
  String get asSearchFailed => '搜索失败';

  @override
  String get asSearchGroupSongs => '歌曲';

  @override
  String get asSearchGroupAlbums => '专辑';

  @override
  String get asSearchGroupArtists => '艺术家';

  @override
  String get asSearchGroupGenres => '流派';

  @override
  String get asSearchGroupComposers => '作曲家';

  @override
  String get asEmptySongs => '音乐库里还没有歌曲';

  @override
  String get asEmptyAlbums => '还没有专辑';

  @override
  String get asEmptyArtists => '还没有艺术家';

  @override
  String get asEmptyGenres => '还没有流派';

  @override
  String get asEmptyFolders => '这个文件夹是空的';

  @override
  String get asEmptyPlaylists => '还没有播放列表';

  @override
  String get asLoadFailed => '音乐库加载失败';

  @override
  String get asErrNotInstalled => '这台 NAS 没有安装 Audio Station';

  @override
  String get asNotInstalledHint => '在 DSM「套件中心」安装 Audio Station 后即可使用';

  @override
  String get asErrNoPrivilege => '这个账号没有使用 Audio Station 的权限';

  @override
  String get asNoPrivilegeHint => '请联系管理员授予 Audio Station 的访问权限';

  @override
  String get asErrLoadMoreFailed => '加载更多失败';

  @override
  String get asErrNetwork => '网络连接失败，请检查网络后重试';

  @override
  String get asErrPlaylistNameInvalid => '播放列表名称不被接受';

  @override
  String get asErrRadioBadRequest => '电台请求未被服务端接受';

  @override
  String get asErrFileExists => '同名文件已存在';

  @override
  String get asErrTooManySongs => '歌曲数量已达上限';

  @override
  String get asErrDuplicateSongs => '有重复的歌曲';

  @override
  String get asErrPlaylistNotExists => '播放列表不存在（DSM 可能正在重建索引）';

  @override
  String get asErrSharedPlaylistRating => '共享列表里不能复制带评分规则的歌曲';

  @override
  String get asErrPinExists => '这个项目已经收藏过了';

  @override
  String get asErrPinNotExists => '这个收藏不存在';

  @override
  String get asErrPinTargetNotExists => '要收藏的内容不存在';

  @override
  String get asErrInvalidPassword => '密码不正确';

  @override
  String asErrUnknown(int code) {
    return '未知错误（$code）';
  }

  @override
  String asSongCount(int n) {
    return '$n 首';
  }

  @override
  String asAlbumCount(int n) {
    return '$n 张专辑';
  }

  @override
  String asArtistCount(int n) {
    return '$n 位艺术家';
  }

  @override
  String get asDetailAlbums => '专辑';

  @override
  String get asDetailSongs => '歌曲';

  @override
  String get asDetailArtists => '艺术家';

  @override
  String get asDetailFolders => '文件夹';

  @override
  String get asEmptyDetailSongs => '这里还没有歌曲';

  @override
  String get asEmptyDetailAlbums => '这里还没有专辑';

  @override
  String get asEmptyDetailArtists => '这里还没有艺术家';

  @override
  String get asPlaylistLoadFailed => '播放列表加载失败';

  @override
  String get asSmartPlaylist => '智能播放列表';

  @override
  String get asSharedPlaylist => '共享';

  @override
  String get asPersonalPlaylist => '个人';

  @override
  String get asFolderUp => '上一级';

  @override
  String get asPinsTitle => '我的收藏';

  @override
  String get asPinEmpty => '还没有收藏';

  @override
  String get asPinEmptyHint => '在专辑、艺术家、流派或播放列表上点「收藏」就会出现在这里';

  @override
  String get asPinAdd => '收藏';

  @override
  String get asPinAdded => '已加入收藏';

  @override
  String asPinAddFailed(String e) {
    return '收藏失败：$e';
  }

  @override
  String get asPinRemove => '取消收藏';

  @override
  String get asPinRemoved => '已取消收藏';

  @override
  String asPinRemoveFailed(String e) {
    return '取消收藏失败：$e';
  }

  @override
  String get asPinUnsupported => '这个收藏暂时无法打开';

  @override
  String get asPinsLoadFailed => '收藏加载失败';

  @override
  String get asSongInfo => '歌曲信息';

  @override
  String get asLyrics => '歌词';

  @override
  String get asLyricsEmpty => '这首歌没有歌词';

  @override
  String get asLyricsLoadFailed => '歌词加载失败';

  @override
  String get asLyricsSearch => '联网搜索歌词';

  @override
  String get asLyricsSearchEmpty => '联网也没有找到歌词';

  @override
  String get asLyricsSearchFailed => '联网搜索歌词失败';

  @override
  String get asRating => '评分';

  @override
  String get asRatingUnset => '未评分';

  @override
  String get asRatingSet => '已设置评分';

  @override
  String get asRatingCleared => '已清除评分';

  @override
  String asRatingFailed(String e) {
    return '设置评分失败：$e';
  }

  @override
  String get asStreamUrl => '流式播放地址';

  @override
  String get asStreamUrlCopied => '播放地址已复制';

  @override
  String get asStreamUrlMaskedNote => '地址里的会话凭据已打码；点复制拿到的是完整地址（含会话凭据，别外发）。';

  @override
  String get asStreamUrlCopiedWithToken => '已复制完整串流地址（含会话凭据，别外发）';

  @override
  String get asCopy => '复制';

  @override
  String get asPlay => '播放';

  @override
  String get asClosePlayer => '关闭播放';

  @override
  String get asPause => '暂停';

  @override
  String asPlayFailed(String e) {
    return '播放失败：$e';
  }

  @override
  String get asSongLoadFailed => '歌曲信息加载失败';

  @override
  String get asFieldArtist => '艺术家';

  @override
  String get asFieldAlbum => '专辑';

  @override
  String get asFieldAlbumArtist => '专辑艺术家';

  @override
  String get asFieldComposer => '作曲家';

  @override
  String get asFieldGenre => '流派';

  @override
  String get asFieldYear => '年份';

  @override
  String get asFieldTrack => '音轨';

  @override
  String get asFieldDisc => '碟号';

  @override
  String get asFieldDuration => '时长';

  @override
  String get asFieldBitrate => '码率';

  @override
  String get asFieldFrequency => '采样率';

  @override
  String get asFieldChannels => '声道';

  @override
  String get asFieldFilesize => '文件大小';

  @override
  String get asFieldCodec => '编码';

  @override
  String get asFieldPath => '路径';

  @override
  String get asOpenFailed => '打开失败';

  @override
  String get mediaPrevious => '上一个';

  @override
  String get mediaNext => '下一个';

  @override
  String get mediaBackward10 => '快退 10 秒';

  @override
  String get mediaForward10 => '快进 10 秒';

  @override
  String get mediaVolume => '音量';

  @override
  String get mediaMute => '静音';

  @override
  String get mediaUnmute => '取消静音';

  @override
  String get mediaAspect => '画面比例';

  @override
  String get mediaAspectFit => '适应（留黑边）';

  @override
  String get mediaAspectFill => '铺满（裁切）';

  @override
  String get mediaAspectZoom => '放大（裁切更多）';

  @override
  String get mediaAspectStretch => '拉伸（铺满）';

  @override
  String get mediaAudioTrack => '音轨';

  @override
  String get mediaSubtitle => '字幕';

  @override
  String get mediaSubtitleOff => '关闭字幕';

  @override
  String get mediaSubtitleAuto => '自动匹配';

  @override
  String get mediaNoTracks => '没有可选项';

  @override
  String get mediaRotate => '旋转屏幕';

  @override
  String get mediaFullscreen => '全屏';

  @override
  String get mediaExitFullscreen => '退出全屏';

  @override
  String get mediaErrCodecUnsupported => '系统解码器不支持这个文件的编码';

  @override
  String mediaAudioUnsupported(String codec) {
    return '这台设备播不了这条音轨（$codec），会有画面没声音。';
  }

  @override
  String get mediaAudioUnsupportedSwitch => '换一条音轨';

  @override
  String get mediaTrackUnsupported => '本机不支持';

  @override
  String get mediaPip => '画中画';

  @override
  String get mediaErrNetworkFailed => '连不上文件地址（网络中断或登录已过期）';

  @override
  String get photoSectionPersons => '人物';

  @override
  String get photoSectionConcepts => '场景';

  @override
  String get photoEmptyPersonsTitle => '还没有识别到人物';

  @override
  String get photoEmptyPersonsMessage =>
      'Synology Photos 会从已索引的照片里自动识别人物。\n刚开启人脸识别时，需要等 NAS 把索引跑完。';

  @override
  String get photoEmptyPersonsDisabledTitle => '未开启人脸识别';

  @override
  String get photoEmptyPersonsDisabledMessage =>
      '需要在 DSM 的「Synology Photos → 设置 → 人物」里开启人脸识别（由管理员配置），开启后这里才会出现人物。';

  @override
  String get photoPersonsMigratingTitle => '人脸识别正在整理';

  @override
  String get photoPersonsMigratingMessage => 'NAS 正在整理已索引照片里的人脸，完成后这里会出现人物。';

  @override
  String get photoErrPersonMigrating =>
      '人脸识别还没整理完（Synology Photos 正在做迁移），请稍后再试';

  @override
  String get photoEmptyPersonTitle => '这个人名下还没有照片';

  @override
  String get photoEmptyPersonMessage => '照片可能已从这个人物的分组里移出。';

  @override
  String get photoPersonUntitled => '未命名人物';

  @override
  String get photoEmptyConceptsTitle => '还没有识别到场景';

  @override
  String get photoEmptyConceptsMessage =>
      '场景（主题）由 Synology Photos 按照片内容自动归类，需要等索引完成。';

  @override
  String get photoEmptyConceptsDisabledTitle => '未开启场景识别';

  @override
  String get photoEmptyConceptsDisabledMessage =>
      '需要在 DSM 的「Synology Photos → 设置」里开启分类/场景识别，开启后这里才会出现场景。';

  @override
  String get photoEmptyConceptTitle => '这个场景下还没有照片';

  @override
  String get photoEmptyConceptMessage => '照片可能已从这个场景的归类里移出。';

  @override
  String photoPhotoCount(int count) {
    return '$count 张照片';
  }

  @override
  String get photoErrConceptClustering =>
      '场景识别还没完成（Synology Photos 正在整理），请稍后再试';

  @override
  String get mailTitle => '邮件';

  @override
  String get survTitle => '监控';

  @override
  String get survStatusLive => '直播中';

  @override
  String get survStatusSetting => '配置中';

  @override
  String get survStatusDisabled => '未启用';

  @override
  String get survStatusDisconnected => '已断开';

  @override
  String get survStatusUnknown => '状态未知';

  @override
  String survCameraCount(int count) {
    return '共 $count 路';
  }

  @override
  String get survEmptyTitle => '还没有摄像机';

  @override
  String get survEmptyMessage => '在 Surveillance Station 里添加摄像机后，就能在这里查看';

  @override
  String get survErrNotInstalled => '这台 NAS 没有安装 Surveillance Station';

  @override
  String get survNotInstalledHint => '在 DSM「套件中心」安装 Surveillance Station 后即可使用';

  @override
  String get survErrNoPrivilege => '这个账号没有使用 Surveillance Station 的权限';

  @override
  String get survNoPrivilegeHint => '请联系管理员为这个账号授予 Surveillance Station 权限';

  @override
  String get survLoadFailed => '摄像机列表加载失败';

  @override
  String get survStatusOffline => '离线';

  @override
  String survStatusOther(int code) {
    return '状态（$code）';
  }

  @override
  String get survCameraDetailTitle => '摄像机';

  @override
  String get survDetailLoadFailed => '摄像机信息加载失败';

  @override
  String get survLiveSection => '实时画面';

  @override
  String get survLiveHint => '实时画面由外部播放器播放；下面是可以直接使用的流地址';

  @override
  String get survLiveUnavailable => '这台摄像机当前不在线，暂时取不到实时画面';

  @override
  String get survSnapshot => '快照';

  @override
  String get survOpenSnapshot => '打开快照';

  @override
  String get survRtspUrl => 'RTSP 地址';

  @override
  String get survMjpegUrl => 'MJPEG 地址';

  @override
  String get survCopyUrl => '复制地址';

  @override
  String get survCopyDone => '地址已复制';

  @override
  String get survPtzSection => '云台控制';

  @override
  String get survPtzUp => '上';

  @override
  String get survPtzDown => '下';

  @override
  String get survPtzLeft => '左';

  @override
  String get survPtzRight => '右';

  @override
  String get survPtzHome => '回到起始位置';

  @override
  String get survPtzZoomIn => '放大';

  @override
  String get survPtzZoomOut => '缩小';

  @override
  String get survPtzPresetTitle => '预置位';

  @override
  String get survPtzPresetEmpty => '这台摄像机没有预置位';

  @override
  String get survPtzPresetFailed => '预置位加载失败';

  @override
  String survPresetPosition(int n) {
    return '预置位 $n';
  }

  @override
  String survPtzMoveFailed(String reason) {
    return '云台操作失败：$reason';
  }

  @override
  String get survRecordingsSection => '录像';

  @override
  String get survRecordingsEmpty => '最近没有录像';

  @override
  String get survRecordingsFailed => '录像加载失败';

  @override
  String survRecordingCount(int count) {
    return '共 $count 段';
  }

  @override
  String survRecordingDuration(String duration) {
    return '时长 $duration';
  }

  @override
  String get survRecordingEncrypted => '已加密';

  @override
  String get mailEmptyTitle => '没有邮件';

  @override
  String get mailEmptyMessage => '这个信箱里暂时没有邮件';

  @override
  String get mailErrNotInstalled => '这台 NAS 没有安装 MailPlus';

  @override
  String get mailNotInstalledHint =>
      '在 DSM「套件中心」安装 MailPlus（并先装好 MailPlus Server）后即可使用';

  @override
  String get mailErrNoPrivilege => '这个账号没有使用 MailPlus 的权限';

  @override
  String get mailNoPrivilegeHint => '请联系管理员为这个账号授予 MailPlus 权限';

  @override
  String get mailLoadFailed => '邮箱列表加载失败';

  @override
  String get mailThreadsFailed => '邮件列表加载失败';

  @override
  String get mailDetailFailed => '邮件内容加载失败';

  @override
  String get mailRetry => '重试';

  @override
  String get mailNoSubject => '（无主题）';

  @override
  String mailThreadCount(int count) {
    return '共 $count 封';
  }

  @override
  String get mailUnread => '未读';

  @override
  String get mailFlagged => '已加星标';

  @override
  String get mailHasAttachment => '有附件';

  @override
  String get mailLoadMore => '加载更多';

  @override
  String get mailRefreshed => '已刷新';

  @override
  String get mailFrom => '发件人';

  @override
  String get mailTo => '收件人';

  @override
  String get mailDate => '时间';

  @override
  String get mailAttachments => '附件';

  @override
  String get mailNoBody => '这封邮件没有可显示的正文';

  @override
  String get mailMarkRead => '标为已读';

  @override
  String get mailMarkUnread => '标为未读';

  @override
  String get mailStar => '加星标';

  @override
  String get mailUnstar => '取消星标';

  @override
  String get mailMoveTo => '移动到…';

  @override
  String get mailActionDone => '已完成';

  @override
  String mailActionFailed(String reason) {
    return '操作失败：$reason';
  }

  @override
  String get mailUnreadInMailbox => '未读邮件';

  @override
  String get mailCompose => '写邮件';

  @override
  String get mailSubject => '主题';

  @override
  String get mailCc => '抄送';

  @override
  String get mailBcc => '密送';

  @override
  String get mailBody => '正文';

  @override
  String get mailSend => '发送';

  @override
  String get mailSendDone => '邮件已发送';

  @override
  String get mailSendFailed => '发送失败';

  @override
  String get mailNeedRecipient => '请至少填写一个收件人';

  @override
  String get mailRecipientHint => '多个地址用逗号分隔';

  @override
  String get mailQuotaFailed => '取不到邮箱配额';

  @override
  String mailQuota(String used, String total) {
    return '已用 $used / $total';
  }

  @override
  String get survErrCamDisabled => '这台摄像机已被停用';

  @override
  String get survErrClientBlocked => '该客户端已被管理员锁定';

  @override
  String get survErrCmsClosed => '录像服务器已关闭，请重新加载';

  @override
  String get survErrExecuteFailed => '操作执行失败';

  @override
  String get survErrLicense => '摄像机许可不足，请联系管理员';

  @override
  String get survErrNameRepeated => '名称重复';

  @override
  String get survErrNetwork => '网络连接失败，请检查网络后重试';

  @override
  String get survErrObjectNotExist => '对象不存在（可能已被删除）';

  @override
  String get survErrParamInvalid => '请求参数不被接受';

  @override
  String get survErrRecordingEncrypted => '这段录像已加密，无法直接播放';

  @override
  String get survErrServiceDisabled => 'Surveillance Station 服务当前不可用';

  @override
  String get mailErrAttachmentDisabled => '附件存储已被管理员停用';

  @override
  String get mailErrAuthRequired => '需要先完成账号认证';

  @override
  String get mailErrDailyFlow => '已超出当日流量上限';

  @override
  String get mailErrDatabase => '服务端数据库操作失败';

  @override
  String get mailErrDraftNotExist => '草稿不存在（可能已发送或删除）';

  @override
  String get mailErrIllegalAttachment => '邮件包含不被允许的附件';

  @override
  String get mailErrImapConnection => '连接收信服务器失败';

  @override
  String get mailErrInvalid => '请求无效';

  @override
  String get mailErrInvalidAccount => '邮箱账号无效';

  @override
  String get mailErrLabelDuplicated => '标签名重复';

  @override
  String get mailErrLabelNameTooLong => '标签名过长';

  @override
  String get mailErrLabelNotExist => '标签不存在';

  @override
  String get mailErrMailboxDuplicated => '邮箱名重复';

  @override
  String get mailErrMailboxNameTooLong => '邮箱名过长';

  @override
  String get mailErrMailboxNotExist => '邮箱不存在';

  @override
  String get mailErrNetwork => '网络连接失败，请检查网络后重试';

  @override
  String get mailErrNoSpace => '存储空间不足';

  @override
  String get mailErrRecipientUnavailable => '收件人不可用';

  @override
  String get mailErrSendLocalOnly => '当前配置只允许向本域发送邮件';

  @override
  String get mailErrSendQuota => '已达到发送配额上限';

  @override
  String get mailErrSharedDisabled => '共享邮箱已被管理员停用';

  @override
  String get mailErrSmtpAuth => '发信服务器认证失败';

  @override
  String get mailErrSmtpConnection => '连接发信服务器失败';

  @override
  String get mailErrUnknownDesc => 'MailPlus 返回了未知错误';

  @override
  String get mailErrUpgrading => 'MailPlus 正在升级，请稍后再试';

  @override
  String get mailErrVersionMismatch => '客户端与服务端版本不匹配';

  @override
  String get navHome => '首页';

  @override
  String get navDrive => 'Drive';

  @override
  String get chatErrNotInstalled => '这台 NAS 没有安装 Synology Chat';

  @override
  String get fileErrNotInstalled => '这台 NAS 没有开启 File Station';

  @override
  String get calErrNotInstalled => '这台 NAS 没有安装 Calendar';

  @override
  String get driveErrNotInstalled => '这台 NAS 没有安装 Synology Drive';

  @override
  String get officeErrNotInstalled => '这台 NAS 没有安装 Synology Office';

  @override
  String get aiNotNasService => 'AI 不是 NAS 服务，不受影响';

  @override
  String get serviceCheckTitle => '服务检测';

  @override
  String get serviceCheckSubtitle => '查看各服务是否可用、原因，并重新检测';

  @override
  String get serviceRecheck => '重新检测';

  @override
  String get serviceRechecking => '正在检测…';

  @override
  String get serviceNeverChecked => '尚未检测';

  @override
  String get serviceShowHidden => '临时显示隐藏的模块';

  @override
  String get serviceShowHiddenHint => '未安装 / 无权限的模块默认隐藏，打开后临时恢复可见';

  @override
  String get serviceStateAvailable => '可用';

  @override
  String get serviceStatePartial => '部分可用';

  @override
  String get serviceStateAbsent => '未安装';

  @override
  String get serviceStateUnauthorized => '无权限';

  @override
  String get serviceStateSessionExpired => '会话失效';

  @override
  String get serviceStateUnreachable => '网络异常';

  @override
  String get serviceStateUnknown => '未检测';

  @override
  String get serviceStateAvailableReason => '服务正常';

  @override
  String get serviceStatePartialReason => '服务可用（部分功能在你的 NAS 上不可用）';

  @override
  String get serviceStateUnknownReason => '尚未检测（登录后会自动检测）';

  @override
  String get serviceUnauthorizedDetail => '已安装，但当前账号无权使用该服务';

  @override
  String get serviceSessionExpiredTitle => '会话已过期';

  @override
  String get serviceRelogin => '重新登录';

  @override
  String get serviceUnreachableTitle => '无法连接 NAS';

  @override
  String get serviceRetry => '重试';

  @override
  String get serviceRestrictedHint => '仍可使用下面的可用服务；也可以重新检测一次。';

  @override
  String get serviceRestrictedNone => '暂时没有检测到其它可用服务。';

  @override
  String get serviceEntryUnauthorized => '当前账号无权使用该服务';

  @override
  String get serviceEntryUnreachable => '网络不可用，请重试';

  @override
  String get serviceEntrySessionExpired => '会话已过期，请重新登录';

  @override
  String serviceLastCheckedAt(String time) {
    return '上次检测：$time';
  }

  @override
  String serviceSessionExpiredDetail(String reason) {
    return '$reason（这不是服务被删除，重新登录即可）';
  }

  @override
  String serviceUnreachableDetail(String reason) {
    return '$reason（服务未被隐藏，可重试）';
  }

  @override
  String serviceRestrictedAbsent(String services) {
    return '这台 NAS 未提供 $services 服务';
  }

  @override
  String serviceRestrictedNoAccess(String services) {
    return '当前无法使用 $services 服务';
  }

  @override
  String serviceRestrictedReason(String label, String reason) {
    return '· $label：$reason';
  }

  @override
  String get photoVideoUnavailable => '此 NAS 未提供视频播放能力，无法播放该视频';

  @override
  String get asStreamUnavailable => '此 NAS 未提供音频串流能力，无法内嵌播放';

  @override
  String get capabilityMissingHint => '此功能在你的 NAS 上不可用';

  @override
  String get mediaErrStreamRejected => '服务器拒绝了这一条取流请求（HTTP 4xx/5xx 或返回的不是媒体）';

  @override
  String mediaAutoContinueNoPicture(String name) {
    return '已自动播放到下一集「$name」：当前条目无法内嵌播放，可切换到系统播放器打开';
  }

  @override
  String get globalSearchEntry => '在 NAS 全局搜索';

  @override
  String get globalSearchEngine => 'Universal Search';

  @override
  String get globalSearchTitle => '全局搜索';

  @override
  String get mediaErrFormatUnsupported =>
      '这种格式通常不被系统解码器支持（WMA/ASF、APE、WavPack、DSD 等）；可交给其它应用打开，音乐库里的文件会自动改用服务端转码';

  @override
  String get asTranscodeFallbackHint => '该格式系统解码器通常不支持，已自动改用服务端转码（mp3/wav）播放';

  @override
  String get asTranscodeFailedHint => '重试的仍是服务端转码流；若持续失败，可在其它应用中打开原始文件';

  @override
  String get photoC2Hub => '照片增强';

  @override
  String get photoC2HubTitle => '更多相册功能';

  @override
  String get photoC2HubSubtitle => '共享 · 地点 · 搜索 · 标签 · 人物 · 条件相册 · 相似照片';

  @override
  String get photoC2Sharing => '共享相册';

  @override
  String get photoC2SharingEntry => '与我共享 / 我共享的；看成员、改角色、开关外链';

  @override
  String get photoC2SharedWithMe => '与我共享';

  @override
  String get photoC2SharedByMe => '我共享的';

  @override
  String get photoC2SharedEmpty => '还没有人共享相册给你';

  @override
  String get photoC2SharedByMeEmpty => '你还没有共享过相册';

  @override
  String photoC2SharedFrom(String owner) {
    return '来自 $owner';
  }

  @override
  String photoC2ShareModifiedAt(String count) {
    return '$count 项 · 已共享';
  }

  @override
  String get photoC2Members => '成员';

  @override
  String get photoC2MembersEmpty => '还没有成员；只有打开外链后访客才能看到';

  @override
  String get photoC2AddMember => '添加成员';

  @override
  String get photoC2AddMemberEmpty => '没有可添加的用户或群组';

  @override
  String get photoC2RemoveMember => '移除成员';

  @override
  String get photoC2RemoveMemberConfirm => '移除成员？';

  @override
  String photoC2RemoveMemberBody(String name) {
    return '移除后 $name 将不再能看到这个相册。';
  }

  @override
  String photoC2MemberRemoved(String name) {
    return '已移除 $name';
  }

  @override
  String photoC2MemberAdded(String name) {
    return '已添加 $name';
  }

  @override
  String get photoC2RoleView => '仅查看';

  @override
  String get photoC2RoleDownload => '可下载';

  @override
  String get photoC2RoleUpload => '可上传';

  @override
  String get photoC2RoleManage => '可管理';

  @override
  String get photoC2RoleUpdated => '权限已更新';

  @override
  String get photoC2ShareLink => '共享链接';

  @override
  String get photoC2ShareLinkNone => '还没有链接';

  @override
  String get photoC2CopyLink => '复制链接';

  @override
  String get photoC2LinkCopied => '链接已复制';

  @override
  String get photoC2LinkEnabled => '外链分享已打开';

  @override
  String get photoC2DisableLink => '关闭外链分享';

  @override
  String get photoC2DisableLinkConfirm => '关闭外链分享？';

  @override
  String get photoC2DisableLinkBody => '关闭后，拿到链接的人将无法再访问这个相册。';

  @override
  String get photoC2LinkClosed => '外链分享已关闭';

  @override
  String get photoC2PasswordPending => '口令分享暂不支持（需 CGI 加密通道）';

  @override
  String get photoC2PhotoRequest => '照片请求';

  @override
  String get photoC2PhotoRequestEntry => '管理你发出的收图链接（删除会让链接立刻失效）';

  @override
  String get photoC2PhotoRequestEmpty => '还没有照片请求';

  @override
  String get photoC2PhotoRequestDelete => '删除请求';

  @override
  String get photoC2PhotoRequestDeleteConfirm => '删除照片请求？';

  @override
  String get photoC2PhotoRequestDeleteBody => '删除后这个收图链接立刻失效，外部访客不能再通过它上传。';

  @override
  String get photoC2PhotoRequestDeleted => '照片请求已删除';

  @override
  String get photoC2PhotoRequestNeverExpires => '永不过期';

  @override
  String photoC2PhotoRequestExpires(String count) {
    return '$count 秒后过期';
  }

  @override
  String get photoC2Geocoding => '地点';

  @override
  String get photoC2GeocodingEntry => '按地理坐标 / 地点浏览照片（地点名依赖 NAS 端地理编码服务）';

  @override
  String get photoC2GeocodingEmpty => '还没有带地点的照片';

  @override
  String get photoC2GeocodingServiceHint =>
      '地点名由 NAS 端的地理编码服务生成；没开这项服务时只会显示坐标分组。';

  @override
  String photoC2GeocodingItemCount(String count) {
    return '$count 张照片';
  }

  @override
  String get photoC2Search => '搜索照片';

  @override
  String get photoC2SearchEntry => '按关键词检索照片，点开复用大图查看器';

  @override
  String get photoC2SearchHint => '搜索文件名 / 地点 / 标签 / 人物 / 相机';

  @override
  String get photoC2SearchEmpty => '没有匹配的照片';

  @override
  String get photoC2SearchNoKeyword => '输入关键词开始搜索';

  @override
  String photoC2SearchResultCount(String count) {
    return '找到 $count 张照片';
  }

  @override
  String get photoC2SearchKeywordOnly => '本批只发 keyword（其余筛选项的字段名已逐字取证，界面后续再接）。';

  @override
  String get photoC2ConditionAlbum => '条件相册';

  @override
  String get photoC2ConditionAlbumEntry => '按时间 / 地点 / 人物 / 标签等条件自动成册';

  @override
  String get photoC2ConditionAlbumEmpty => '还没有条件相册';

  @override
  String get photoC2ConditionAlbumDelete => '删除条件相册';

  @override
  String get photoC2ConditionAlbumDeleteConfirm => '删除条件相册？';

  @override
  String photoC2ConditionAlbumDeleteBody(String name) {
    return '「$name」会被移入回收站（照片本身不受影响）。';
  }

  @override
  String get photoC2ConditionAlbumDeleted => '条件相册已删除';

  @override
  String photoC2ConditionSummary(String summary) {
    return '条件：$summary';
  }

  @override
  String get photoC2ConditionNone => '空条件';

  @override
  String get photoC2ConditionInvalid => '条件已失效';

  @override
  String get photoC2ConditionPeek => '预览命中张数';

  @override
  String photoC2ConditionPeekCount(String count) {
    return '命中 $count 张照片';
  }

  @override
  String get photoC2ConditionKindTime => '时间';

  @override
  String get photoC2ConditionKindPlace => '地点';

  @override
  String get photoC2ConditionKindPerson => '人物';

  @override
  String get photoC2ConditionKindTag => '标签';

  @override
  String get photoC2ConditionKindKeyword => '关键词';

  @override
  String get photoC2ConditionKindOther => '其它条件';

  @override
  String get photoC2Similar => '相似照片';

  @override
  String get photoC2SimilarEntry => '官方相似分组（依赖 NAS 端的相似索引）';

  @override
  String get photoC2SimilarDisabled => '相似照片未启用';

  @override
  String get photoC2SimilarDisabledHint => '在 Photos 设置里打开「相似照片」后，这里才会出现分组。';

  @override
  String get photoC2SimilarIndexing => '相似索引还在跑';

  @override
  String photoC2SimilarIndexingHint(String count, String stage) {
    return '还有 $count 张待索引（阶段 $stage）。';
  }

  @override
  String get photoC2SimilarReady => '相似索引已完成';

  @override
  String get photoC2SimilarEmpty => '还没有相似分组';

  @override
  String get photoC2NoPermission => '没有权限';

  @override
  String get photoC2NoPermissionHint => '部分功能当前账号没有权限，已从列表里隐藏。';

  @override
  String get photoC2SessionHint => '登录状态已失效，请重新登录后重试。';

  @override
  String get photoC2EntryHidden => '该功能已隐藏';

  @override
  String get photoC2ActionFailed => '操作失败';

  @override
  String get photoC2NotConnected => '未连接';

  @override
  String get photoC2NoPermissionBody => '当前账号没有权限访问这个功能。';

  @override
  String get officeDocsEntry => 'Office 文档';

  @override
  String get officeDocsEntryHint => '只看 Drive 里的 .odoc / .osheet / .oslides';

  @override
  String get officeDocsEmptyTitle => '这个目录里没有 Office 文档';

  @override
  String officeDocsEmptyDetail(String path) {
    return '「$path」里没有 .odoc / .osheet / .oslides；可以返回上一层，或从「文件 → Drive」浏览全部内容';
  }

  @override
  String get officeDocsNoPermission => '无权限访问 Synology Office（Office 文档入口已隐藏）';

  @override
  String get officeViewerReadonlyBadge => '只读预览';

  @override
  String get officeViewerNoEdit => '本批不支持编辑';

  @override
  String get officeViewerParsing => '正在解析 Office 文档…';

  @override
  String get officeViewerLoadFailedTitle => '打不开这个 Office 文档';

  @override
  String get officeViewerLoadFailedHint =>
      '文件可能已损坏，或不是有效的 Synology Office 原生文档（.odoc/.osheet/.oslides）。';

  @override
  String get officeViewerNotNativeDetail =>
      '这不是 Synology Office 原生文档（.odoc/.osheet/.oslides）。';

  @override
  String get officeViewerDownloadFailedTitle => '读取文件字节失败';

  @override
  String get officeViewerPasswordTitle => '需要文档密码';

  @override
  String get officeViewerEncryptedSectionTitle => '部分内容已加密';

  @override
  String get officeViewerEncryptedSectionDetail => '只能显示未加密的部分，解密排期在后续阶段。';

  @override
  String get officeViewerTranscodedTitle => '拿到的是转换后的文件';

  @override
  String get officeViewerTranscodedDetail =>
      '这条下载链路把 Office 原生文档转成了别的格式（内容不再是 .odoc/.osheet/.oslides 原生字节），所以打不开。';

  @override
  String get officeViewerNoPermissionTitle => '无权限读取这份文档';

  @override
  String get officeViewerNoPermissionDetail => '当前账号没有读取/下载该文件的权限。';

  @override
  String get officeViewerSessionTitle => '会话已过期';

  @override
  String get officeViewerSessionDetail => '登录状态已失效，请重新登录后再试。';

  @override
  String get officeViewerTooBigTitle => '文档太大，未内嵌解析';

  @override
  String officeViewerTooBig(String size) {
    return '这份文档有 $size，超过内嵌解析上限。';
  }

  @override
  String get officeViewerTooBigHint => '可以下载后再读，或换一台网络更快的设备重试。';

  @override
  String get officeViewerEmptyModel => '没有可显示的内容。';

  @override
  String officeViewerSheetCount(String n) {
    return '$n 张工作表';
  }

  @override
  String get officeViewerSheetEmpty => '这个工作簿没有工作表';

  @override
  String get officeViewerSheetStyleNote => '表头与单元格样式按文件中的实际设置显示。';

  @override
  String officeViewerSheetTruncated(String rows, String cols) {
    return '只显示前 $rows 行 × $cols 列（表格更大，已按可视范围显示）。';
  }

  @override
  String officeViewerSheetMerges(String n) {
    return '表格里有 $n 处合并单元格。';
  }

  @override
  String officeViewerDocChars(String n) {
    return '$n 字';
  }

  @override
  String get officeViewerDocEmpty => '这份文档没有可显示的正文块';

  @override
  String get officeViewerDocLayoutNote =>
      '只读渲染：标题/段落/列表/表格/图片引用。页眉页脚、分页、字体颜色等版式从简。';

  @override
  String get officeViewerDocImageNote => '图片：本批不解码内嵌图片字节，以下按引用（附件 id）占位显示。';

  @override
  String officeViewerDocImagePlaceholder(String id) {
    return '图片（附件 id：$id）';
  }

  @override
  String get officeViewerDocImageNoId => '图片（无附件 id）';

  @override
  String officeViewerSlideCount(String n) {
    return '$n 页';
  }

  @override
  String get officeViewerSlidesEmpty => '这份演示文稿没有幻灯片';

  @override
  String get officeViewerSlidesLayoutNote =>
      '仅展示每页的文本与图片，版式从简（不做母版继承/动画/版式还原）。';

  @override
  String officeViewerSlidePage(String n, String total) {
    return '第 $n / $total 页';
  }

  @override
  String officeViewerSlidePageNo(String n) {
    return '第 $n 页';
  }

  @override
  String get officeViewerSlidesHidden => '（隐藏页）';

  @override
  String get officeViewerSlideEmptyBody => '这一页没有文本内容';

  @override
  String get officeViewerSlidesNotes => '演讲者备注';

  @override
  String officeDownloadConvertedNotice(String name) {
    return '已转换为 Office 格式：保存为 $name';
  }

  @override
  String get noteC3Export => '导出';

  @override
  String get noteC3ExportTitle => '导出笔记';

  @override
  String get noteC3ExportWord => '导出为 Word 文档';

  @override
  String get noteC3ExportWordHint => '服务端生成 .docx';

  @override
  String get noteC3ExportNote => '导出为归档 .nsx';

  @override
  String get noteC3ExportNoteHint => 'NoteStation 自己的归档格式（可再导入）';

  @override
  String get noteC3ExportNotebook => '导出笔记本到 NAS';

  @override
  String get noteC3ExportDest => '目标目录';

  @override
  String get noteC3ExportDestHint => '例如 /notes';

  @override
  String get noteC3ExportSaveConfig => '同时导出应用设置';

  @override
  String get noteC3ExportTodo => '同时导出待办';

  @override
  String get noteC3ExportStarted => '正在导出…';

  @override
  String noteC3ExportOpened(String name) {
    return '已导出并打开 $name';
  }

  @override
  String get noteC3ExportEmpty => '导出结果为空文件';

  @override
  String noteC3ExportFailed(String error) {
    return '导出失败：$error';
  }

  @override
  String get noteC3ExportNotebookDone => '已导出到 NAS 目录';

  @override
  String get noteC3Import => '导入';

  @override
  String get noteC3ImportTitle => '导入笔记';

  @override
  String get noteC3ImportEnex => '从 Evernote .enex 导入';

  @override
  String get noteC3ImportEnexHint => 'Evernote 导出的 .enex 文件';

  @override
  String get noteC3ImportNotebook => '从 .nsx 导入';

  @override
  String get noteC3ImportNotebookHint => 'NoteStation 归档文件';

  @override
  String get noteC3ImportEvernote => '从 Evernote 账号导入';

  @override
  String get noteC3ImportEvernoteHint => '连接 Evernote 账号后选择笔记本';

  @override
  String get noteC3Importing => '正在导入…';

  @override
  String noteC3ImportProgress(String percent) {
    return '正在导入… $percent%';
  }

  @override
  String get noteC3ImportApplying => '准备笔记本';

  @override
  String get noteC3ImportDone => '导入完成';

  @override
  String noteC3ImportFailed(String error) {
    return '导入失败：$error';
  }

  @override
  String get noteC3ImportCancelled => '已取消';

  @override
  String get noteC3ImportStop => '取消导入';

  @override
  String get noteC3ImportOverwriteHint => '导入会把文件里的笔记本/笔记并入当前账号，可能产生同名内容。确定继续？';

  @override
  String get noteC3ImportFileMissing => '找不到要导入的文件';

  @override
  String get noteC3VersionTitle => '版本历史';

  @override
  String get noteC3VersionLabel => '版本';

  @override
  String get noteC3VersionEmpty => '没有历史版本';

  @override
  String get noteC3VersionRestore => '恢复';

  @override
  String get noteC3VersionRestoreConfirm => '恢复到这个版本？';

  @override
  String noteC3VersionRestoreBody(String version) {
    return '当前内容会被版本 $version 覆盖（旧内容仍保留在历史里）。确定恢复？';
  }

  @override
  String get noteC3VersionRestored => '已恢复到该版本';

  @override
  String noteC3VersionRestoreFailed(String error) {
    return '恢复失败：$error';
  }

  @override
  String get noteC3VersionCopyToNew => '复制为新笔记';

  @override
  String get noteC3Clip => '网页剪藏';

  @override
  String get noteC3ClipTitle => '剪藏网页';

  @override
  String get noteC3ClipUrl => '网页地址';

  @override
  String get noteC3ClipName => '标题';

  @override
  String get noteC3ClipNotebook => '保存到笔记本';

  @override
  String get noteC3ClipHint => '由 NAS 抓取网页正文，并保存来源网址';

  @override
  String get noteC3ClipInvalidUrl => '请输入以 http:// 或 https:// 开头的网址';

  @override
  String get noteC3ClipSaved => '已保存剪藏';

  @override
  String get noteC3NoPermission => '没有权限使用这个功能';

  @override
  String get noteC3NoPermissionHint => '当前账号没有这个功能的权限';

  @override
  String get noteC3SessionHint => '会话已过期，请重新登录';

  @override
  String get noteC3NotConnected => '尚未连接到 NAS';

  @override
  String get noteC3ActionFailed => '操作失败';

  @override
  String mailErrUnknown(String code) {
    return '未知错误（$code）';
  }

  @override
  String get survErrCodec => '缺少播放所需的多媒体解码器（需 Advanced Media Extensions）';

  @override
  String survErrUnknown(String code) {
    return '未知错误（$code）';
  }

  @override
  String get serviceStateUncertain => '信号矛盾（保守显示）';

  @override
  String get serviceStateUncertainReason =>
      '应用权限显示该模块已安装，但没有检测到它注册的接口 —— 按保守策略显示，不隐藏。';

  @override
  String get contactGroupsTab => '分组';

  @override
  String get contactGroupsSection => '联系人分组';

  @override
  String get contactNoGroups => '这个通讯录里还没有分组。';

  @override
  String get contactNoGroupMembers => '这个分组没有成员。';

  @override
  String get contactOuSection => '组织单位（只读）';

  @override
  String get contactNoOu => '没有组织单位（或这台 NAS 未接入目录服务）。';

  @override
  String get contactSyncStatus => '同步状态';

  @override
  String get contactSyncStatusFailed => '失败';

  @override
  String get contactSyncStatusProcessing => '正在处理';

  @override
  String get contactLastUpdate => '上次更新';

  @override
  String get calNoCalendars => '这个账号还没有日历。';

  @override
  String get calPickerLoadFailed => '日历列表加载失败，请先返回重试。';

  @override
  String get calExternalCalendars => '外部日历（Google 等）';

  @override
  String get calExternalCalendarsUnsupported => '暂不支持：请先在官方网页端连接这个日历。';

  @override
  String get calErrInvalidParameter => '服务端不接受这次请求，可能是参数和服务端版本不匹配。可以点重试再试一次。';

  @override
  String get calErrNoPermission => '这个账号没有执行该操作的权限。';

  @override
  String get calErrServerCondition => '服务端暂时无法完成这个操作（117）。可以点重试再试一次。';

  @override
  String get calErrVersionUnsupported => '服务端不支持这个操作（版本不匹配）。';

  @override
  String calErrCode(String code) {
    return '请求失败（错误码 $code）';
  }

  @override
  String calErrGeneric(String error) {
    return '加载失败：$error';
  }

  @override
  String get chatAttachVideo => '相册视频';

  @override
  String get chatAttachRecordVideo => '录制视频';

  @override
  String get chatVideoRecordPermissionDenied => '无法访问相机或麦克风，请在系统设置里允许权限后重试。';

  @override
  String get chatVideoGalleryPermissionDenied => '无法读取相册视频，请检查系统权限后重试。';

  @override
  String get chatCameraUnavailable => '这台设备没有可用的相机，请改用「相册」选择图片。';

  @override
  String get chatImagePickFailed => '选择图片失败，请重试。';

  @override
  String get profileAvatarPickFailed => '选择头像失败，请重试。';

  @override
  String get driveScanPickFailed => '取页失败，请重试。';

  @override
  String get chatVideoPickFailed => '选择视频失败，请重试。';

  @override
  String get chatJoinPublicChannel => '加入公开频道';

  @override
  String get chatJoinPublicFailed => '加入频道失败，请稍后再试。';

  @override
  String get chatJoinPublicEmpty => '没有可以加入的公开频道。';

  @override
  String get chatShareToChannel => '分享到频道';

  @override
  String get chatSharedToChannel => '已分享到频道。';

  @override
  String get chatShareFailed => '分享失败，请重试。';

  @override
  String get chatShareExceedMaxFiles => '一次最多分享 50 个文件，已忽略多余的。';

  @override
  String get noteC3ClipModeSimple => '简化正文';

  @override
  String get noteC3ClipModeFull => '完整网页';

  @override
  String noteC3ImportEvernoteBrowserFailed(String url) {
    return '打不开浏览器，请手动访问：$url';
  }

  @override
  String get noteC3ImportEvernoteMerge => '合并同名笔记本';

  @override
  String get noteC3ImportEvernoteMergeHint => '导入 Evernote 时是否把多本笔记本合并成一本';

  @override
  String noteC3ImportEvernoteLock(String lock) {
    return '服务端导入被锁定：$lock';
  }

  @override
  String get noteAEditorFormatBlock => '段落样式';

  @override
  String get noteAEditorContent => '正文';

  @override
  String get noteAEditorFontSize => '字号';

  @override
  String get noteAEditorNoteLink => '笔记链接';

  @override
  String get noteAEditorNoteLinkTitle => '链接到笔记';

  @override
  String get noteAEditorNoteLinkEmpty => '没有可链接的其它笔记';

  @override
  String get noteAEditorHorizontalRule => '分割线';

  @override
  String get noteAEditorFileAttachment => '添加文件附件';

  @override
  String get noteAEditorFilePickFailed => '选择文件失败';

  @override
  String get noteAEditorAttachments => '附件';

  @override
  String get noteAEditorAttachmentDelete => '删除附件';

  @override
  String noteAEditorAttachmentDeleteConfirm(String name) {
    return '确定删除附件「$name」吗？';
  }

  @override
  String get noteAEditorAttachmentDeleteFailed => '附件删除失败';

  @override
  String get noteAEditorAttachmentDownload => '下载并打开';

  @override
  String get noteAEditorAttachmentDownloadFailed => '附件下载失败';

  @override
  String get noteAEditorAttachmentEmpty => '这条笔记还没有附件';

  @override
  String get chatBookmarks => '书签';

  @override
  String get chatBookmarkRemoveFailed => '取消星标失败，请重试。';

  @override
  String get chatNoBookmarks => '还没有星标消息';

  @override
  String get chatSubscribedThreadsTitle => '订阅话题';

  @override
  String get chatNoSubscribedThreads => '还没有订阅的话题';

  @override
  String get chatGlobalPanelTitle => '跨频道内容';

  @override
  String get chatGlobalTabThreads => '话题';

  @override
  String get chatGlobalTabReminders => '提醒';

  @override
  String get chatGlobalTabScheduled => '定时';

  @override
  String get chatGlobalFanoutNote => '本页由本机逐个频道汇总（服务端该接口按频道查询）';

  @override
  String get fsP0ConflictTitle => '同名文件已存在';

  @override
  String fsP0ConflictBody(String name) {
    return '$name 已存在于该目录。请选择处理方式。';
  }

  @override
  String get fsP0ConflictOverwrite => '覆盖';

  @override
  String get fsP0ConflictRename => '重命名';

  @override
  String get fsP0ConflictSkip => '跳过';

  @override
  String fsP0UploadRenamed(String name) {
    return '已重命名为 $name';
  }

  @override
  String get fsP0RecycleBin => '回收站';

  @override
  String get fsP0RecycleEmpty => '清空回收站';

  @override
  String get fsP0RecycleEmptyConfirm => '回收站中的全部内容将被永久删除且不可恢复。是否确定继续？';

  @override
  String get fsP0RecycleEmptyDone => '回收站已清空';

  @override
  String get fsP0RecycleRestore => '还原';

  @override
  String get fsP0RecycleRestoreConfirm => '将所选项目还原到原位置？';

  @override
  String get fsP0RecycleRestored => '已还原';

  @override
  String get fsP0DeleteForever => '永久删除';

  @override
  String get fsP0DeleteForeverConfirm => '此操作将永久删除所选项目，无法恢复。是否继续？';

  @override
  String get fsP0ShareAdd => '创建分享链接';

  @override
  String get fsP0ShareCreateTitle => '创建分享链接';

  @override
  String get fsP0SharePasswordEnable => '启用密码保护';

  @override
  String get fsP0SharePasswordLabel => '密码';

  @override
  String get fsP0ShareValidity => '有效期';

  @override
  String get fsP0SharePermanent => '永久';

  @override
  String fsP0ShareDays(int days) {
    return '$days 天';
  }

  @override
  String get fsP0ShareCreatedTitle => '已创建分享链接';

  @override
  String get fsP0ShareCopyUrl => '复制链接';

  @override
  String get fsP0ShareCreateFailed => '创建分享链接失败';

  @override
  String get asShuffle => '随机播放';

  @override
  String get asPrevious => '上一首';

  @override
  String get asNext => '下一首';

  @override
  String get asRepeatOff => '顺序播放';

  @override
  String get asRepeatAll => '循环全部';

  @override
  String get asRepeatOne => '单曲循环';

  @override
  String get asQuality => '音质';

  @override
  String get asPinRename => '重命名';

  @override
  String get asPinRenameTitle => '重命名收藏';

  @override
  String get asPinName => '名称';

  @override
  String get asPinRenameConfirm => '保存';

  @override
  String get asPinRenamed => '已重命名收藏';

  @override
  String get asPinRenameFailed => '重命名失败';

  @override
  String get asPinReorderFailed => '收藏排序失败';

  @override
  String asQualityKbps(int kbps) {
    return '$kbps kbps';
  }

  @override
  String asQueuePosition(int index, int total) {
    return '$index/$total';
  }

  @override
  String get dsBatchActions => '批量操作';

  @override
  String dsBatchFailed(String msg) {
    return '操作失败：$msg';
  }

  @override
  String get dsPauseAll => '全部暂停';

  @override
  String get dsResumeAll => '全部恢复';

  @override
  String get dsClearFinished => '清除已完成';

  @override
  String get dsClearFinishedConfirm => '已完成的任务会从下载列表中移除，此操作无法恢复。';

  @override
  String get dsClearedFinished => '已清除已完成任务';

  @override
  String get dsRemoveErrors => '删除错误任务';

  @override
  String get dsRemoveErrorsConfirm => '要删除所有错误任务吗？此操作无法恢复。';

  @override
  String get dsRemovedErrors => '已删除错误任务';

  @override
  String get dsMoreActions => '更多操作';

  @override
  String get dsForceComplete => '结束任务';

  @override
  String get dsForceCompleteConfirm => '结束后无法再恢复下载，已下载的文件会保留在目标文件夹。';

  @override
  String get dsForceCompleted => '已结束任务';

  @override
  String get dsSearchHint => '搜索任务名称';

  @override
  String get dsSortBy => '排序';

  @override
  String get dsSortDefault => '默认排序';

  @override
  String get dsSortAsc => '升序';

  @override
  String get dsSortDesc => '降序';

  @override
  String get dsSortName => '名称';

  @override
  String get dsSortSize => '大小';

  @override
  String get dsSortDownloaded => '已下载';

  @override
  String get dsSortStatus => '状态';

  @override
  String get dsSortSpeedDown => '下载速度';

  @override
  String get dsSortSpeedUp => '上传速度';

  @override
  String get dsSortStarted => '添加时间';

  @override
  String get dsPriority => '优先级';

  @override
  String get dsPriorityHigh => '高';

  @override
  String get dsPriorityNormal => '普通';

  @override
  String get dsPriorityLow => '低';

  @override
  String get dsPriorityAuto => '自动';

  @override
  String get dsTrackerList => 'Tracker 列表';

  @override
  String get dsTrackerEmpty => '没有 Tracker 信息';

  @override
  String get dsPeerList => 'Peer 列表';

  @override
  String get dsPeerEmpty => '没有 Peer 信息';

  @override
  String get dsFtpAuth => '需要 FTP/HTTP 账号密码';

  @override
  String get dsFtpUsername => '用户名';

  @override
  String get dsFtpPassword => '密码';

  @override
  String get dsSelectFiles => '选择要下载的文件';

  @override
  String get dsSelectFilesHint => '取消勾选不想下载的文件';

  @override
  String get dsStartDownload => '开始下载';

  @override
  String get dsFilesStarted => '已开始下载选中的文件';

  @override
  String get dsFileSelectFailed => '文件清单加载失败';

  @override
  String get dsCreateListUnavailable => '任务已创建，但服务端没有返回文件清单，无法先选文件';

  @override
  String get dsFileListEmpty => '这个种子没有文件清单';

  @override
  String get photoP0ActionDownload => '下载';

  @override
  String get photoP0ActionFavorite => '收藏';

  @override
  String get photoP0ActionUnfavorite => '取消收藏';

  @override
  String get photoP0ActionAddToAlbum => '加入相册';

  @override
  String get photoP0ActionRemoveFromAlbum => '移出相册';

  @override
  String get photoP0DeleteTitle => '删除所选项？';

  @override
  String get photoP0DeleteBody => '删除后会移入 DSM 回收站；能否还原取决于共享文件夹是否已启用回收站。';

  @override
  String photoP0DeletedCount(String count) {
    return '已删除 $count 项';
  }

  @override
  String photoP0BatchResult(String ok, String fail) {
    return '成功 $ok 项，失败 $fail 项';
  }

  @override
  String photoP0BatchAllFailed(String fail) {
    return '全部失败（$fail 项）';
  }

  @override
  String photoP0DownloadZipReady(String name) {
    return '已保存 $name';
  }

  @override
  String get photoP0DownloadZipEmpty => '服务端没有返回内容，这些照片可能无法打包下载';

  @override
  String get photoP0VideoQuality => '画质';

  @override
  String get photoP0VideoQualityAuto => '自动';

  @override
  String get photoP0VideoQualityFirst => '画质优先';

  @override
  String get photoP0VideoSpeedFirst => '速度优先';

  @override
  String photoP0VideoQualityApplied(String name) {
    return '画质偏好：$name';
  }

  @override
  String photoP0PersonMigratingProgress(String message, String percent) {
    return '$message（已整理 $percent%）';
  }

  @override
  String get fsP0bDownloadPause => '暂停';

  @override
  String get fsP0bDownloadResume => '继续';

  @override
  String get fsP0bDownloadPausedTip => '已暂停。已下载的部分会保留，可继续下载。';

  @override
  String fsP0bDownloadResumed(String size) {
    return '已从 $size 处继续下载。';
  }

  @override
  String get fsP0bDownloadRestarted => '服务端不支持断点续传，已重新完整下载。';

  @override
  String fsP0bDownloadIncomplete(String detail) {
    return '下载不完整：$detail';
  }

  @override
  String get fsP0bRestoreConflictTitle => '目标位置已有同名项目';

  @override
  String fsP0bRestoreConflictBody(String count) {
    return '$count 个项目在还原目标位置已存在同名项目。请选择处理方式。';
  }

  @override
  String get fsP0bRestoreOverwrite => '覆盖';

  @override
  String get fsP0bRestoreSkip => '跳过';

  @override
  String get fsP0bCompressPasswordEnable => '启用密码保护';

  @override
  String get fsP0bCompressPasswordLabel => '密码';

  @override
  String get fsP0bPasswordConfirmLabel => '确认密码';

  @override
  String get fsP0bPasswordMismatch => '两次输入的密码不一致';

  @override
  String get fsP0bPasswordEmpty => '密码不能为空';

  @override
  String get fsP0bExtractPasswordLabel => '密码';

  @override
  String get fsP0bExtractPasswordHint => '加密压缩包才需要填；留空表示没有密码';

  @override
  String get fsP0bSearchFilter => '筛选';

  @override
  String get fsP0bSearchFilterActive => '已启用筛选';

  @override
  String get fsP0bSearchType => '类型';

  @override
  String get fsP0bSearchTypeAny => '任意';

  @override
  String get fsP0bSearchTypeFolder => '文件夹';

  @override
  String get fsP0bSearchTypeFile => '任意文件';

  @override
  String get fsP0bSearchTypeDocuments => '文档';

  @override
  String get fsP0bSearchTypeVideos => '视频';

  @override
  String get fsP0bSearchTypePictures => '图片';

  @override
  String get fsP0bSearchTypeAudio => '音频';

  @override
  String get fsP0bSearchTypeExtension => '自定义扩展名';

  @override
  String get fsP0bSearchExtensionHint => '扩展名（逗号分隔）';

  @override
  String get fsP0bSearchSize => '大小（MB）';

  @override
  String get fsP0bSearchSizeFrom => '最小';

  @override
  String get fsP0bSearchSizeTo => '最大';

  @override
  String get fsP0bSearchSizeInvalid => '最小大小不能大于最大大小';

  @override
  String get fsP0bSearchDate => '修改时间';

  @override
  String get fsP0bSearchDateFrom => '起始';

  @override
  String get fsP0bSearchDateTo => '结束';

  @override
  String get fsP0bSearchDateInvalid => '起始日期不能晚于结束日期';

  @override
  String get fsP0bSearchOwner => '所有者';

  @override
  String get fsP0bSearchOwnerHint => '账号名，留空表示不限';

  @override
  String get fsP0bSearchApply => '应用';

  @override
  String get fsP0bSearchClear => '清除筛选';

  @override
  String get noteBReminder => '提醒';

  @override
  String get noteBReminderOff => '不提醒';

  @override
  String get noteBReminderOnTime => '正点提醒';

  @override
  String noteBReminderBefore(String value, String unit) {
    return '提前 $value $unit';
  }

  @override
  String get noteBReminderCustom => '自定义';

  @override
  String get noteBReminderUnitMinute => '分钟';

  @override
  String get noteBReminderUnitHour => '小时';

  @override
  String get noteBReminderUnitDay => '天';

  @override
  String get noteBReminderUnitWeek => '周';

  @override
  String get noteBReminderNeedsDueDate => '先设置截止日期';

  @override
  String get noteBOverdueSettings => '逾期提醒';

  @override
  String get noteBOverdueEnable => '每日逾期汇总';

  @override
  String get noteBOverdueTime => '提醒时间';

  @override
  String get noteBOverdueTitle => '逾期提醒';

  @override
  String noteBOverdueCount(String count) {
    return '$count 条任务已逾期';
  }

  @override
  String get noteBOverdueShow => '逾期列表可在待办页「未完成」筛选里查看';

  @override
  String get noteBOverdueHint => '到点把当天已逾期、未完成的任务汇总成一条提醒';

  @override
  String get noteBNotifyUnsupported => '当前版本仅在应用打开时提醒（系统级提醒需要额外依赖）';

  @override
  String get noteBSmart => '智能笔记本';

  @override
  String get noteBSmartNew => '新建智能笔记本';

  @override
  String get noteBSmartEdit => '编辑智能笔记本';

  @override
  String get noteBSmartEmpty => '还没有智能笔记本';

  @override
  String get noteBSmartName => '名称';

  @override
  String get noteBSmartKeyword => '关键词';

  @override
  String get noteBSmartNoteTitle => '标题包含';

  @override
  String get noteBSmartNotebooks => '限定笔记本';

  @override
  String get noteBSmartTags => '标签（逗号分隔）';

  @override
  String get noteBSmartTagAnd => '标签：同时包含';

  @override
  String get noteBSmartTagOr => '标签：包含任一';

  @override
  String get noteBSmartDateFrom => '修改时间从';

  @override
  String get noteBSmartDateTo => '修改时间到';

  @override
  String get noteBSmartDelete => '删除智能笔记本';

  @override
  String noteBSmartDeleteConfirm(String name) {
    return '确定删除「$name」吗？';
  }

  @override
  String get noteBSmartSaved => '智能笔记本已保存';

  @override
  String noteBSmartFailed(String error) {
    return '保存失败：$error';
  }

  @override
  String get noteBSmartNameRequired => '请填写名称';

  @override
  String get noteBSmartNoConditions => '没有筛选条件';

  @override
  String get noteBShelf => 'Shelf 分层';

  @override
  String get noteBShelfAdd => '加入 Shelf';

  @override
  String get noteBShelfRemove => '移出 Shelf';

  @override
  String get noteBShelfName => 'Shelf 名称';

  @override
  String get noteBShelfEmpty => '还没有笔记本';

  @override
  String get noteBShelfDone => '已更新 Shelf';

  @override
  String get noteBJoined => '共享给我';

  @override
  String get noteBJoinedNotebooks => '加入的笔记本';

  @override
  String get noteBJoinedNotes => '加入的笔记';

  @override
  String get noteBJoinedEmpty => '还没有别人分享给你的内容';

  @override
  String noteBJoinedOwner(String owner) {
    return '来自 $owner';
  }

  @override
  String get noteBCopy => '复制';

  @override
  String get noteBCopySuffix => '（副本）';

  @override
  String get noteBCopyToEncrypt => '复制到加密';

  @override
  String get noteBCopyToPlaintext => '复制到明文';

  @override
  String get noteBCopyPassword => '输入笔记口令';

  @override
  String get noteBCopyDone => '已复制';

  @override
  String noteBCopyFailed(String error) {
    return '复制失败：$error';
  }

  @override
  String get noteBCopyTitle => '无标题笔记';

  @override
  String get fsC5MountTitle => '远程挂载';

  @override
  String get fsC5MountChip => '挂载';

  @override
  String get fsC5MountIsoSection => 'ISO 镜像卷';

  @override
  String get fsC5MountRemoteSection => '远程卷（CIFS）';

  @override
  String get fsC5MountEmpty => '还没有挂载任何远程卷或 ISO 镜像。';

  @override
  String get fsC5MountAdd => '新增挂载';

  @override
  String get fsC5MountAddCifs => '挂载远程文件夹（CIFS）';

  @override
  String get fsC5MountAddIso => '挂载 ISO 镜像';

  @override
  String get fsC5MountServer => '服务器地址';

  @override
  String fsC5MountServerHint(String example) {
    return '形如 $example';
  }

  @override
  String get fsC5MountAccount => '账号';

  @override
  String get fsC5MountPassword => '密码';

  @override
  String get fsC5MountMountPoint => '挂载点';

  @override
  String fsC5MountPointHint(String example) {
    return '如 $example';
  }

  @override
  String get fsC5MountSource => 'ISO 源文件';

  @override
  String get fsC5MountAutoMount => '开机自动挂载';

  @override
  String get fsC5MountActor => '挂载者';

  @override
  String get fsC5MountAutoMountFailed => '开机自动挂载失败';

  @override
  String get fsC5MountIsoReadOnly => 'ISO 卷是只读的';

  @override
  String get fsC5MountUnmount => '卸载';

  @override
  String fsC5MountUnmountConfirm(String name) {
    return '确定要卸载 $name 吗？';
  }

  @override
  String get fsC5MountUnmounted => '已卸载';

  @override
  String get fsC5MountReconnect => '重新连接';

  @override
  String get fsC5MountRemount => '重新挂载';

  @override
  String get fsC5MountBrowse => '浏览';

  @override
  String get fsC5MountSubmitted => '已提交挂载';

  @override
  String get fsC5MountPermissionDenied =>
      '这个账号没有挂载/卸载远程卷的权限（DSM → 控制面板 → 应用程序权限 → File Station）';

  @override
  String get fsC5MountUnavailable => '无法管理远程挂载';

  @override
  String get fsC5MountServerDisabled =>
      '这台服务器没有为这个账号开启挂载能力，所以没有可新增的类型。请联系管理员在 File Station 里开启远程挂载或 ISO 挂载。';

  @override
  String get fsC5MountNeedsHome => '非管理员只能在用户主目录（home）里挂载远程文件夹；这个账号没有启用用户主目录。';

  @override
  String get fsC5MountVirtualSection => '虚拟文件夹';

  @override
  String get fsC5MountRequired => '服务器地址与挂载点不能为空';

  @override
  String get fsC5FilterHint => '在目录内筛选';

  @override
  String get fsC5FilterChip => '筛选';

  @override
  String get fsC5FilterClear => '清除筛选';

  @override
  String get fsC5FilterNoMatch => '没有匹配项';

  @override
  String get fsC5ReadOnly => '只读';

  @override
  String get fsC5WormLocked => 'WORM 已锁定';

  @override
  String fsC5WormBlocked(String action) {
    return '该文件已被 WriteOnce 锁定，不能$action';
  }

  @override
  String get fsC5CompressFormat => '压缩格式';

  @override
  String get fsC5CompressLevel => '压缩级别';

  @override
  String get fsC5LevelStore => '仅存储';

  @override
  String get fsC5LevelFastest => '最快';

  @override
  String get fsC5LevelModerate => '标准';

  @override
  String get fsC5LevelBest => '最好';

  @override
  String get fsC5ExtractCodepage => '文件名编码';

  @override
  String get fsC5ExtractCodepageHint => '解压出来的文件名乱码时选择对应编码';

  @override
  String get fsC5TaskDetailParams => '任务参数';

  @override
  String get fsC5TaskDetailErrors => '任务错误';

  @override
  String get fsC5TaskNoError => '没有错误';

  @override
  String get fsC5FavoriteRename => '重命名收藏';

  @override
  String get fsC5FavoriteClearBroken => '清理失效收藏';

  @override
  String get fsC5FavoriteClearBrokenConfirm => '将删除所有指向已不存在路径的收藏记录。';

  @override
  String get fsC5FavoriteCleared => '已清理失效收藏';

  @override
  String get fsC5FavoriteRenamed => '收藏已重命名';

  @override
  String get noteBNotifySystemReady => '系统级提醒已开启：应用未打开时也会按闹钟提醒';

  @override
  String get noteBNotifyPermissionNeeded => '系统级提醒需要通知权限：未授权时仅在应用打开时提醒';

  @override
  String get noteBNotifyExactAlarmDenied => '精确闹钟未授权：提醒可能延迟（已降级为不精确闹钟）';

  @override
  String get noteBNotifyGrant => '去授权';

  @override
  String photoP1PersonCount(String count) {
    return '共 $count 人';
  }

  @override
  String photoP1ConceptCount(String count) {
    return '共 $count 个场景';
  }

  @override
  String photoP1LoadMoreRemaining(String count) {
    return '加载更多（还有 $count 个）';
  }

  @override
  String get photoP1CountUnavailable => '数量拿不到';

  @override
  String photoP1DetailSummary(String count) {
    return '共 $count 张照片';
  }

  @override
  String get photoP1CreateShareLink => '生成共享链接';

  @override
  String get photoP1CreateShareLinkHint => '此时只生成链接，还不会对访客开放';

  @override
  String get photoP1EnableShareLink => '打开外链分享';

  @override
  String get photoP1EnableShareLinkConfirm => '打开外链分享？';

  @override
  String get photoP1EnableShareLinkBody => '打开后，任何拿到链接的人都能浏览这个相册（除非设置了口令）。';

  @override
  String get photoP1ShareLinkCreated => '共享链接已生成';

  @override
  String get photoP1PasswordTitle => '口令保护';

  @override
  String get photoP1PasswordEnabled => '已开启口令保护';

  @override
  String get photoP1PasswordOff => '未设口令';

  @override
  String get photoP1PasswordField => '访问口令';

  @override
  String get photoP1PasswordClearHint => '留空表示清除口令';

  @override
  String get photoP1PasswordSaved => '口令已更新';

  @override
  String get photoP1ExpirationField => '有效期（天）';

  @override
  String get photoP1ExpirationNever => '留空表示不过期';

  @override
  String get photoP1LinkNeedsPassphrase => '先生成共享链接再设口令';

  @override
  String get photoP1InviteRole => '角色';

  @override
  String get photoP1InviteConfirm => '邀请';

  @override
  String photoP1InviteSelected(String count) {
    return '已选 $count 人';
  }

  @override
  String photoP1MemberInvited(String count) {
    return '已邀请 $count 位成员';
  }

  @override
  String photoP1SearchSuggestTitle(String type) {
    return '建议 · $type';
  }

  @override
  String get photoP1SearchSuggestEmpty => '没有搜索建议';

  @override
  String get photoP1SimilarLoadMore => '加载更多';

  @override
  String get photoP1ConditionCreate => '新建条件相册';

  @override
  String get photoP1ConditionEdit => '编辑条件';

  @override
  String get photoP1ConditionName => '相册名称';

  @override
  String get photoP1ConditionNameEmpty => '请填写相册名称';

  @override
  String get photoP1ConditionType => '条件类型';

  @override
  String photoP1ConditionValue(String count) {
    return '已选 $count 项';
  }

  @override
  String get photoP1ConditionValueEmpty => '还没有选值';

  @override
  String get photoP1ConditionValueSearch => '搜索条件值';

  @override
  String get photoP1ConditionNoPreview => '还没有预览';

  @override
  String get photoP1ConditionPolicyAnd => '同时满足';

  @override
  String get photoP1ConditionPolicyOr => '任一满足';

  @override
  String get photoP1ConditionPeek => '预览符合条件的照片数';

  @override
  String photoP1ConditionPeekResult(String count) {
    return '符合条件的照片：$count 张';
  }

  @override
  String get photoP1ConditionPeekFailed => '预览失败';

  @override
  String get photoP1ConditionCreated => '条件相册已创建';

  @override
  String get photoP1ConditionUpdated => '条件相册已更新';

  @override
  String get photoP1ConditionNeedOne => '至少要选一个条件';

  @override
  String get photoP1ConditionSuggestEmpty => '没有可选值';

  @override
  String get photoP1ConditionSuggestFailed => '条件值加载失败';

  @override
  String get photoP1ConditionItemType => '媒体类型';

  @override
  String get photoP1ConditionItemTypeAll => '全部';

  @override
  String get photoP1ConditionItemTypePhoto => '照片';

  @override
  String get photoP1ConditionItemTypeVideo => '视频';

  @override
  String get photoP1ConditionKeyword => '关键词（逗号分隔）';

  @override
  String get photoP1ConditionUserIdMissing => '读不到当前用户 id';

  @override
  String get photoP1UploadToTimeline => '上传到时间轴';

  @override
  String get photoP1UploadPickFailed => '选择文件失败';

  @override
  String photoP1UploadDone(String count) {
    return '已上传 $count 项';
  }

  @override
  String photoP1UploadFailed(String ok, String failed) {
    return '成功 $ok 项，失败 $failed 项';
  }

  @override
  String get photoP1PlaceItemsEmpty => '这个地点还没有照片';

  @override
  String get photoP1EditorTitle => '旋转照片';

  @override
  String get photoP1EditorRotateCw => '顺时针旋转 90°';

  @override
  String get photoP1EditorRotateCcw => '逆时针旋转 90°';

  @override
  String get photoP1EditorRotate180 => '旋转 180°';

  @override
  String get photoP1EditorSaved => '已保存旋转结果';

  @override
  String get photoMapOpen => '在地图中打开';

  @override
  String photoMapSheetTitle(String name) {
    return '在地图中打开「$name」';
  }

  @override
  String get photoMapNameOnlyHint => '这条地点只有地名、没有经纬度：地图应用会按「地名搜索」，不保证落在精确位置。';

  @override
  String photoMapPreciseHint(String lat, String lon) {
    return '使用坐标 $lat, $lon（WGS-84）。';
  }

  @override
  String get photoMapNothingHint => '既没有地名也没有坐标，无法打开地图。';

  @override
  String get photoMapServiceLabel => '地图服务';

  @override
  String get photoMapServiceAuto => '自动（跟随地区）';

  @override
  String get photoMapServiceGoogle => 'Google 地图';

  @override
  String get photoMapServiceAmap => '高德地图';

  @override
  String get photoMapServiceTencent => '腾讯地图';

  @override
  String get photoMapServiceBaidu => '百度地图';

  @override
  String photoMapAutoResolved(String service) {
    return '当前判定为：$service';
  }

  @override
  String get photoMapRegionHint => '区域判定只看设备地区/时区，可能不准——上面可以手动改，改完会记住。';

  @override
  String get photoMapOpenAction => '打开';

  @override
  String get photoMapCopyName => '复制地名';

  @override
  String get photoMapCopied => '已复制';

  @override
  String get photoMapFailed => '没能打开地图：请确认设备装了对应地图应用或浏览器。';

  @override
  String photoMapFallbackNote(String service, String fallback) {
    return '$service 没有免 key 的网页版；打不开时会回落到 $fallback 网页。';
  }

  @override
  String get photoMapPreciseBadge => '精确坐标';

  @override
  String get photoMapNameSearchBadge => '按地名搜索';

  @override
  String get driveP0EntryDenied => '这个账号没有访问该功能的权限（入口已隐藏）';

  @override
  String get driveP0EntryUnavailable =>
      '这台 NAS 没有提供该功能（Synology Drive Server 版本可能过低）';

  @override
  String get driveP0EntrySessionExpired => '登录已过期，请重新登录';

  @override
  String get driveP0RecentTitle => '最近';

  @override
  String get driveP0RecentEmptyTitle => '还没有最近记录';

  @override
  String get driveP0RecentEmptyMessage => '在 Drive 里打开或修改过的文件会出现在这里';

  @override
  String get driveP0SharedByMeTitle => '我共享的';

  @override
  String get driveP0SharedByMeEmptyTitle => '还没有分享出去的内容';

  @override
  String get driveP0SharedByMeEmptyMessage => '你在 Drive 里共享给他人的文件会出现在这里';

  @override
  String get driveP0FolderEmptyTitle => '这个文件夹是空的';

  @override
  String get driveP0FolderEmptyMessage => '这里还没有任何文件或子文件夹';

  @override
  String get driveP0FolderOpenFailed => '打不开这个文件夹';

  @override
  String get driveP0SearchTitle => '搜索';

  @override
  String get driveP0SearchHint => '搜索文件与文件夹';

  @override
  String get driveP0SearchEmptyTitle => '没有找到匹配项';

  @override
  String get driveP0SearchEmptyMessage => '换个关键词或放宽筛选条件再试';

  @override
  String get driveP0SearchFailed => '搜索失败';

  @override
  String get driveP0SearchNeedCondition => '请输入关键词，或至少选择一个筛选条件';

  @override
  String get driveP0SearchLocation => '位置';

  @override
  String get driveP0SearchLocationAny => '任意位置';

  @override
  String get driveP0SearchLocationMyDrive => '我的文件';

  @override
  String get driveP0SearchLocationTeamFolders => '团队文件夹';

  @override
  String get driveP0SearchLocationSharedWithMe => '共享给我';

  @override
  String get driveP0SearchLocationSharedByMe => '我共享的';

  @override
  String get driveP0SearchLocationStarred => '星标';

  @override
  String get driveP0SearchLocationCurrent => '当前文件夹';

  @override
  String get driveP0SearchType => '类型';

  @override
  String get driveP0SearchTypeAny => '任意类型';

  @override
  String get driveP0SearchTypeFolder => '文件夹';

  @override
  String get driveP0SearchTypeFile => '文件';

  @override
  String get driveP0SearchTypeOdoc => 'Synology 文档';

  @override
  String get driveP0SearchTypeOsheet => 'Synology 表格';

  @override
  String get driveP0SearchTypeOslide => 'Synology 幻灯片';

  @override
  String get driveP0SearchTypeDocument => '文档';

  @override
  String get driveP0SearchTypeImage => '图片';

  @override
  String get driveP0SearchTypeAudio => '音频';

  @override
  String get driveP0SearchTypeVideo => '视频';

  @override
  String get driveP0SearchOwner => '拥有者';

  @override
  String get driveP0SearchOwnerAny => '任何人';

  @override
  String get driveP0SearchOwnerMe => '我';

  @override
  String get driveP0SearchOwnerNotMe => '不是我';

  @override
  String get driveP0SearchSize => '大小';

  @override
  String get driveP0SearchSizeAny => '不限';

  @override
  String get driveP0SearchSizeGreater => '大于';

  @override
  String get driveP0SearchSizeLess => '小于';

  @override
  String get driveP0SearchSizeEqual => '约等于';

  @override
  String get driveP0SearchSizeUnit => 'MB';

  @override
  String get driveP0SearchDate => '时间';

  @override
  String get driveP0SearchDateAny => '不限时间';

  @override
  String get driveP0SearchDateModified => '修改时间';

  @override
  String get driveP0SearchDateCreated => '创建时间';

  @override
  String get driveP0SearchLabel => '标签';

  @override
  String get driveP0CopyTo => '复制到…';

  @override
  String get driveP0MoveTo => '移动到…';

  @override
  String get driveP0CopyMovePick => '没有子文件夹可以进；可以直接用右上角的目标';

  @override
  String get driveP0CopyHere => '复制到这里';

  @override
  String get driveP0MoveHere => '移动到这里';

  @override
  String get driveP0CopyMoveSameFolder => '不能选择自己作为目标位置';

  @override
  String get driveP0CopyMoveConflictTitle => '目标位置有同名文件';

  @override
  String driveP0CopyMoveConflictBody(String count) {
    return '$count 个文件与目标位置重名，请选择处理方式。';
  }

  @override
  String get driveP0ConflictAutorename => '自动重命名';

  @override
  String get driveP0ConflictOverwrite => '覆盖';

  @override
  String get driveP0ConflictStop => '跳过';

  @override
  String driveP0CopyMoveDone(String count) {
    return '已完成：$count 项';
  }

  @override
  String driveP0CopyMoveFailed(String error) {
    return '操作失败：$error';
  }

  @override
  String get driveP0InfoTitle => '信息';

  @override
  String get driveP0InfoType => '文件类型';

  @override
  String get driveP0InfoTypeFile => '文件';

  @override
  String get driveP0InfoFolder => '文件夹';

  @override
  String get driveP0InfoLocation => '位置';

  @override
  String get driveP0InfoCreated => '创建时间';

  @override
  String get driveP0InfoModified => '修改时间';

  @override
  String get driveP0InfoOwner => '拥有者';

  @override
  String get driveP0InfoSize => '大小';

  @override
  String get driveP0InfoLabels => '标签';

  @override
  String get driveP0InfoPermission => '权限';

  @override
  String get driveP0InfoCanDownload => '可下载';

  @override
  String get driveP0InfoCanWrite => '可编辑';

  @override
  String get driveP0InfoCanPreview => '可预览';

  @override
  String get driveP0InfoShared => '已共享';

  @override
  String get driveP0InfoStarred => '已加星标';

  @override
  String get driveP0InfoLocked => '已锁定';

  @override
  String driveP0InfoLockedBy(String name) {
    return '被 $name 锁定';
  }

  @override
  String get driveP0InfoNone => '无';

  @override
  String get driveP0InfoClose => '关闭';

  @override
  String get driveP0EncryptedTitle => '输入密码';

  @override
  String get driveP0EncryptedOfficeBody => '此文件已加密。请输入密码。';

  @override
  String get imageEditBackendOpenai => 'OpenAI 兼容 · images/edits';

  @override
  String get imageEditBackendGemini => 'Google Gemini · generateContent';

  @override
  String get imageEditBackendA1111 => 'A1111 · sdapi/v1/img2img';

  @override
  String get imageEditStrengthWeak => '弱';

  @override
  String get imageEditStrengthMedium => '中';

  @override
  String get imageEditStrengthStrong => '强';

  @override
  String get imageEditPresetEnhance => '提升清晰度';

  @override
  String get imageEditPresetEnhancePrompt => '提升清晰度与细节，去除模糊，保留原始构图与人物特征';

  @override
  String get imageEditPresetDenoise => '去噪/降噪';

  @override
  String get imageEditPresetDenoisePrompt => '去除噪点与压缩痕迹，保留纹理与文字细节';

  @override
  String get imageEditPresetRealistic => '风格化（写实）';

  @override
  String get imageEditPresetRealisticPrompt => '转为通透的写实摄影风格，自然光，保留原场景';

  @override
  String get imageEditPresetIllustration => '风格化（插画）';

  @override
  String get imageEditPresetIllustrationPrompt => '转为柔和手绘插画风格，保留主体姿态与配色';

  @override
  String get imageEditPresetIdPhoto => '证件照换底';

  @override
  String get imageEditPresetIdPhotoPrompt => '保持人物面部与发型不变，将背景替换为纯色背景';

  @override
  String get imageEditPresetIdPhotoNotice => '结果不保证符合证件照规格，请勿直接用于正式办理';

  @override
  String get imageEditPresetRestore => '老照片修复';

  @override
  String get imageEditPresetRestorePrompt => '修复划痕与褪色，适度锐化，不改变人物长相';

  @override
  String get imageEditPresetCustom => '自定义';

  @override
  String get imageEditPresetCustomPrompt => '';

  @override
  String get imgEditErrNoNetwork => '当前没有网络，无法使用 AI 美化';

  @override
  String get imgEditErrNetworkUnknown => '当前网络类型未知，已按非 WiFi 保守处理';

  @override
  String get imgEditErrWifiOnly => '仅 WiFi 上传已开启；当前是移动数据，会消耗流量';

  @override
  String get imgEditErrNoBackend => '还没配置图生图后端，先去「AI 服务」里配好';

  @override
  String get imgEditErrNoKey => '还没填 API Key';

  @override
  String get imgEditErrConsent => '需要先同意「照片会发送到你配置的服务」';

  @override
  String get imgEditErrDisabled => 'AI 美化已关闭';

  @override
  String imgEditErrQuota(String used, String cap) {
    return '今日 AI 美化额度已用尽（$used/$cap），明日 00:00 恢复';
  }

  @override
  String get imgEditErrBusy => '正在美化中，请稍候';

  @override
  String imgEditErrPromptTooLong(String chars, String limit) {
    return '提示词太长（$chars 字，上限 $limit 字）';
  }

  @override
  String get imgEditErrPromptEmpty => '先写一句想怎么美化';

  @override
  String imgEditErrRequestRejected(String tail) {
    return '该服务不接受这些参数或尺寸（400）$tail';
  }

  @override
  String imgEditErrNotFoundHost(String host) {
    return '地址或模型不存在（404），检查「$host」的地址与模型 id';
  }

  @override
  String imgEditErrGenerateTimeout(String seconds) {
    return '等生成太久没回数据（已 $seconds 秒），可重试或改用更小尺寸';
  }

  @override
  String imgEditErrLocalUnreachable(String host) {
    return '连不上你的本地服务（$host）';
  }

  @override
  String get imgEditErrCancelledBilling => '已请求停止；服务端可能仍会计费';

  @override
  String imgEditErrServerBody(String tail) {
    return '服务端在响应里返回了错误：$tail';
  }

  @override
  String imgEditErrBlocked(String tail) {
    return '服务拒绝生成这幅图（可能触发内容安全策略）$tail';
  }

  @override
  String get imgEditErrNotImage => '服务返回的数据不是图片，已丢弃（未保存任何内容）';

  @override
  String get imgEditErrEmptyImage => '服务返回的图片为空或被截断（未保存任何内容）';

  @override
  String get imgEditErrUrlOnly => '服务只返回了图片链接（本功能不接受链接，未保存任何内容）';

  @override
  String imgEditErrPartial(String ok, String failed) {
    return '成功 $ok 张，失败 $failed 张（结果不完整）';
  }

  @override
  String get imgEditErrInputNotImage => '这张照片无法解码（可能不是图片或已损坏）';

  @override
  String imgEditErrTooLarge(String mb, String limit) {
    return '照片过大（$mb MB），上限约 $limit MB';
  }

  @override
  String get imgEditErrExifNotStripped => '内部错误：未能移除照片的 EXIF 信息（已阻止外发）';

  @override
  String get imgEditErrUrlRefused => '内部安全策略：只发 base64，不把图片链接发给自建后端';

  @override
  String get imgEditErrSaveDenied => '没有权限保存到相册；已可保存到本机';

  @override
  String get imgEditErrUploadUnsupported => '这台 NAS 不支持从 App 上传照片';

  @override
  String get imgEditErrSessionExpired => '会话已过期，请重新登录';

  @override
  String get imgEditErrDisabledMidFlight => '已关闭 AI 美化；本次结果仍可保存';

  @override
  String get officeDocReadOnly => '只读渲染';

  @override
  String get officeDocRenderPartial => '本页有部分内容只以受限方式呈现（见下方标记）。';

  @override
  String get officeDocRenderNotADoc => '不是可渲染的文档树（顶层不是对象）';

  @override
  String officeDocUnsupportedType(String name) {
    return '暂不支持渲染的类型：$name';
  }

  @override
  String officeDocUnsupportedUnknown(String name) {
    return '暂不支持渲染的类型（schema 未声明）：$name';
  }

  @override
  String get officeDocUnsupportedInline => '不支持的内联类型';

  @override
  String get officeDocEmpty => '这份文档没有可显示的正文块';

  @override
  String get officeDocSettingsRow => '文档设置（本批只登记，不渲染版式）';

  @override
  String officeDocStyleEditorTitle(String count) {
    return '样式定义（$count）';
  }

  @override
  String officeDocStyleHeading(String name) {
    return '标题样式 $name';
  }

  @override
  String get officeDocStyleBody => '正文';

  @override
  String get officeDocPageDecorate => '页面装饰';

  @override
  String get officeDocHeader => '页眉';

  @override
  String get officeDocFooter => '页脚';

  @override
  String get officeDocPageNum => '页码';

  @override
  String get officeDocPageNumToken => '#';

  @override
  String get officeDocPageBreak => '分页';

  @override
  String get officeDocTitle => '文档';

  @override
  String get officeDocLoading => '正在读取文档…';

  @override
  String get officeDocLoadFailed => '打开失败';

  @override
  String get officeDocSessionExpired => '登录会话已失效';

  @override
  String get officeDocNoContent => '没有可显示的内容';

  @override
  String get officeDocRetry => '重试';

  @override
  String get officeDocFallbackPreview => '改用只读预览';

  @override
  String get officeDocSave => '保存快照';

  @override
  String get officeDocSaveOk => '已保存快照';

  @override
  String officeDocSaveFailed(String name) {
    return '保存失败：$name';
  }

  @override
  String get officeDocSaveNoSession => '协作会话未建立，无法保存';

  @override
  String officeDocSessionUnavailable(String name) {
    return '协作会话未建立：$name';
  }

  @override
  String get officeDocEditNextBatch => '编辑（下一批接入）';

  @override
  String get officeDocGatePending => '正在确认写权限…（暂以只读方式打开）';

  @override
  String get officeDocGateAllowed => '（无正文；仅 key）';

  @override
  String get officeDocGateNoPermission => '这个账号对该文件没有写入或评论权限：以只读方式打开。';

  @override
  String get officeDocGateUnresolved =>
      '还没能解析到这个文档的 Office 标识（新建后服务端可能尚未就绪）：本次以只读方式打开，可点「重新检查」再试。';

  @override
  String get officeDocGateNotProvisioned =>
      '这个文档的 Office 数据还没就绪（刚新建的文件服务端需要一点时间）：本次以只读方式打开，可点「重新检查」再试。';

  @override
  String get officeDocGateRecheck => '重新检查';

  @override
  String officeDocGateSchemaTooOld(String value) {
    return '服务端 Office 移动端 schema 为 $value，低于编辑器所需的 2000：以只读方式打开。';
  }

  @override
  String get officeDocGateRelogin => '登录会话已失效：请重新登录后重试（本次仍以只读方式打开）。';

  @override
  String get officeDocGateUnverified => '无法确认这个文件的写权限，已按只读方式打开。';

  @override
  String get pbDestinationTitle => '备份目标';

  @override
  String get pbDestinationDrive => 'Synology Drive';

  @override
  String get pbDestinationPhotos => 'Synology Photos';

  @override
  String get pbDestinationDriveDesc => '官方相机备份落点：/mydrive/PhotoBackup/<设备名>/';

  @override
  String get pbDestinationPhotosDesc => '备份进 Synology Photos 的「手机备份」相册';

  @override
  String pbDestinationSwitched(String name) {
    return '已切换到$name；两个落点各自记账，不会互相影响';
  }

  @override
  String pbTargetPathLabel(String path) {
    return '落点路径：$path';
  }

  @override
  String get pbTargetDriveMissing => '这台 NAS 上没装/不支持 Synology Drive 照片上传';

  @override
  String get pbTargetPhotosMissing => '这台 NAS 上没装/不支持 Synology Photos 备份上传';

  @override
  String get pbTargetNoPermission => '当前账号没有这个备份落点的权限';

  @override
  String get pbTargetUnavailable => '当前没有可用的备份落点';

  @override
  String get pbDcimOnly => '只备份 DCIM（相机）';

  @override
  String get pbDcimOnlyHint => '官方相机备份的范围恒为 DCIM；关掉会把截图/下载目录也传上去';

  @override
  String get pbChargeOnly => '仅充电时备份';

  @override
  String get pbChargeOnlyHint => '官方同款约束：插上电源才跑（后台交给系统约束，前台立即生效）';

  @override
  String get pbChargeBlocked => '当前未在充电，已按「仅充电时备份」暂停';

  @override
  String get pbScreenOffOnly => '仅息屏时备份';

  @override
  String get pbScreenOffOnlyHint => '屏幕熄灭后才开始，亮屏时后台会退避重试';

  @override
  String get pbBackgroundTitle => '后台备份';

  @override
  String get pbBackgroundScheduled => '已开启系统级后台排程（约每小时一次）';

  @override
  String get pbBackgroundNotScheduled => '未排程：打开「自动备份」后由系统调度';

  @override
  String get pbBackgroundCharging => '正在充电';

  @override
  String get pbBackgroundNotCharging => '未在充电';

  @override
  String get pbBackgroundScreenOn => '屏幕亮着（若开了「仅息屏」会等到息屏再跑）';

  @override
  String get pbBackgroundScreenOff => '屏幕已熄（满足「仅息屏」条件）';

  @override
  String get pbBackgroundBatteryHint => '系统电池优化可能掐断后台备份，建议加入白名单';

  @override
  String get pbBackgroundGrantBattery => '去加入白名单';

  @override
  String pbBackgroundLastResult(String result) {
    return '上次后台结果：$result';
  }

  @override
  String get pbBackgroundRunNow => '立即排队跑一次';

  @override
  String get pbBackgroundUnsupported => '这台设备不支持系统级后台排程：备份只在应用打开时进行';

  @override
  String pbBackgroundDevice(String name) {
    return '本机设备名：$name';
  }

  @override
  String get imageEditEntryTitle => 'AI 美化';

  @override
  String get imageEditEntryTooltip => 'AI 美化（图生图）';

  @override
  String get imageEditBusyTooltip => '正在美化中，请稍候';

  @override
  String get imageEditSingleOnly => 'AI 美化一次只能处理 1 张，请只选 1 张';

  @override
  String imageEditSendBanner(String host) {
    return '这张照片将被发送到 <你配置的服务>（$host）';
  }

  @override
  String get imageEditSendBannerLocalNote => '若该地址不是本机/局域网，照片仍会离开设备';

  @override
  String imageEditSendSummary(String count) {
    return '$count 张 · 已移除 EXIF（含 GPS）';
  }

  @override
  String imageEditSendSummaryBytes(String count, String kb) {
    return '$count 张 · 已移除 EXIF（含 GPS）· 约 $kb KB';
  }

  @override
  String get imageEditConsentTitle => '使用前请确认';

  @override
  String get imageEditConsentBody =>
      '· 照片本体（已移除 EXIF，含 GPS）会发送到你配置的服务；<br>· 不经过本应用的任何服务器；<br>· 可能产生费用；<br>· 可随时在「AI 服务 → AI 美化」里关闭或撤销同意。';

  @override
  String get imageEditConsentAgree => '我理解并同意';

  @override
  String get imageEditConsentRefuse => '不同意';

  @override
  String get imageEditPanelTitle => 'AI 美化';

  @override
  String get imageEditPresetLabel => '预设';

  @override
  String get imageEditPromptLabel => '提示词';

  @override
  String get imageEditPromptHint => '想怎么美化？例如：提升清晰度';

  @override
  String imageEditPromptCounter(String chars, String limit) {
    return '$chars/$limit';
  }

  @override
  String get imageEditStrengthLabel => '强度';

  @override
  String get imageEditVariantsLabel => '变体数';

  @override
  String imageEditVariantsCostUnknown(String count) {
    return '将生成 $count 张 · 预计费用：单价未知（将如实记账，无法预估）';
  }

  @override
  String imageEditVariantsCostLocal(String count) {
    return '将生成 $count 张 · 预计费用：0（自建/局域网）';
  }

  @override
  String imageEditVariantsCostKnown(String count, String usd) {
    return '将生成 $count 张 · 预计费用：$usd USD';
  }

  @override
  String imageEditQuotaLine(String remaining, String cap) {
    return '今日剩余 $remaining/$cap 张';
  }

  @override
  String get imageEditStart => '开始美化';

  @override
  String get imageEditAllowMobile => '仍然使用流量';

  @override
  String get imageEditRunning => '正在美化…';

  @override
  String imageEditRunningElapsed(String seconds) {
    return '已等待 $seconds 秒';
  }

  @override
  String get imageEditStop => '停止';

  @override
  String get imageEditResultTitle => '美化结果';

  @override
  String imageEditVariantOf(String index, String total) {
    return '第 $index/$total 张';
  }

  @override
  String get imageEditHoldToCompare => '按住查看原图';

  @override
  String get imageEditSaveAsNewPhoto => '保存为新照片';

  @override
  String get imageEditSaveToDevice => '保存到本机';

  @override
  String imageEditSavedToTimeline(String count) {
    return '已保存为 $count 张新照片';
  }

  @override
  String imageEditSavedToDeviceOpened(String name) {
    return '已保存到本机并打开：$name';
  }

  @override
  String imageEditSaveFailed(String error) {
    return '保存失败：$error';
  }

  @override
  String get imageEditSettingsTitle => 'AI 美化（图生图）';

  @override
  String get imageEditSettingsEnable => '启用 AI 美化';

  @override
  String get imageEditSettingsEnableHint => '默认关闭；照片会发送到你配置的服务（不经过本应用服务器）';

  @override
  String get imageEditSettingsBackend => '后端';

  @override
  String get imageEditSettingsBaseUrl => '服务地址';

  @override
  String get imageEditSettingsModel => '模型';

  @override
  String get imageEditSettingsKey => 'API Key';

  @override
  String get imageEditSettingsDailyCap => '单日上限（张）';

  @override
  String get imageEditSettingsCapOff => '关闭（0 张/日）';

  @override
  String imageEditSettingsCapValue(String count) {
    return '$count 张/日';
  }

  @override
  String get imageEditSettingsWifiOnly => '仅 WiFi 上传';

  @override
  String get imageEditSettingsConsentDone => '已同意（可随时撤销）';

  @override
  String get imageEditSettingsConsentMissing => '尚未同意（首次使用时询问）';

  @override
  String get imageEditSettingsRevoke => '撤销同意';

  @override
  String get imageEditSettingsRevoked => '已撤销同意并关闭 AI 美化';

  @override
  String get photoMapPreciseNoNumbersHint =>
      '这条照片带精确坐标（WGS-84），会直接定位到拍摄点；为保护隐私，默认不显示坐标数字（可点「复制坐标」）。';

  @override
  String get photoMapCopyCoord => '复制坐标';

  @override
  String get photoMapOverseasConsentTitle => '把坐标发送给境外地图服务？';

  @override
  String photoMapOverseasConsentBody(String service) {
    return '坐标将发送给 $service（境外服务，属数据出境）。同意后才会打开，且只告知这一次。';
  }

  @override
  String get photoMapOverseasConsentAgree => '同意并继续';

  @override
  String get photoMapOverseasConsentRefuse => '取消';

  @override
  String get officeDocEditNeedSelection => '请先选中要设置格式的文本。';

  @override
  String get officeDocEditNeedParagraph => '请先把光标放到一个段落里。';

  @override
  String get officeDocEditNoSession => '协作会话未建立，无法编辑。';

  @override
  String officeDocEditFailed(String name) {
    return '编辑失败：$name';
  }

  @override
  String officeDocEditStepDropped(String name) {
    return '这一步没有生效（服务器判定无效）：$name';
  }

  @override
  String officeDocEditRolledBack(String name) {
    return '这一步没有被服务器确认，已回退：$name';
  }

  @override
  String get officeDocEditDropped => '未能与服务器对齐，未确认的本地修改已丢弃。';

  @override
  String officeDocEditUnavailable(String name) {
    return '当前文档无法编辑：$name';
  }

  @override
  String get officeDocAligning => '版本不一致，正在与服务器对齐…';

  @override
  String get officeDocAligned => '已与服务器对齐并重发本地修改。';

  @override
  String get officeDocReconnecting => '连接已恢复，正在重新读取文档…';

  @override
  String officeDocPendingCount(String count) {
    return '$count 步未确认';
  }

  @override
  String get officeDocLeaveTitle => '还有未确认的修改';

  @override
  String officeDocLeavePending(String count) {
    return '还有 $count 步修改没被服务器确认；现在离开可能丢失这些修改。';
  }

  @override
  String get officeDocLeaveStay => '留在本页';

  @override
  String get officeDocLeaveConfirm => '仍然离开';

  @override
  String get officeDocBold => '加粗';

  @override
  String officeDocMarkApplied(Object count, Object label) {
    return '已对 $count 个字符设置$label';
  }

  @override
  String officeDocMarkRemoved(Object label) {
    return '已取消$label';
  }

  @override
  String get officeDocItalic => '斜体';

  @override
  String get officeDocUnderline => '下划线';

  @override
  String get officeDocHeading => '标题级别';

  @override
  String get officeDocHeadingBody => '正文';

  @override
  String officeDocHeadingLevel(String level) {
    return '标题 $level';
  }

  @override
  String get officeDocList => '列表';

  @override
  String get officeDocUndo => '撤销';

  @override
  String officeDocUndoOf(String name) {
    return '撤销：$name';
  }

  @override
  String get officeDocRedo => '重做';

  @override
  String get calParticipantsLabel => '参与者';

  @override
  String get calParticipantAdd => '添加';

  @override
  String get calParticipantEmpty => '还没有参与者';

  @override
  String get calAddParticipant => '添加参与者';

  @override
  String get calParticipantEmailHint => '输入邮箱';

  @override
  String get calParticipantAddEmail => '加为外部参与者';

  @override
  String get calParticipantUnsupported => '这台 NAS 的日历没有用户列表接口，只能手动输入邮箱。';

  @override
  String get calParticipantPickUser => '从 NAS 用户选择';

  @override
  String get calParticipantUsersFailed => '用户列表加载失败，可以手动输入邮箱。';

  @override
  String get calParticipantNoUsers => '没有可选的 NAS 用户，可以手动输入邮箱。';

  @override
  String get calParticipantBadEmail => '请输入有效的邮箱地址';

  @override
  String get calParticipantAccepted => '已接受';

  @override
  String get calParticipantDeclined => '已拒绝';

  @override
  String get calParticipantTentative => '暂定';

  @override
  String get calParticipantNeedsAction => '待回复';

  @override
  String get noteDrawEntry => '手绘';

  @override
  String get noteDrawEntryHint => '画一张图并作为手绘附件插入';

  @override
  String get noteDrawTitle => '手绘';

  @override
  String get noteDrawBrush => '画笔';

  @override
  String get noteDrawEraser => '橡皮';

  @override
  String get noteDrawColor => '颜色';

  @override
  String get noteDrawWidth => '粗细';

  @override
  String get noteDrawUndo => '撤销';

  @override
  String get noteDrawRedo => '重做';

  @override
  String get noteDrawClear => '清空';

  @override
  String get noteDrawBackground => '背景';

  @override
  String get noteDrawBackgroundWhite => '白底';

  @override
  String get noteDrawBackgroundTransparent => '透明';

  @override
  String get noteDrawHint => '单指绘制；双指手势不参与绘制。';

  @override
  String get noteDrawHintDesktop => '拖拽绘制；用工具栏的撤销/重做回退。';

  @override
  String get noteDrawInsert => '插入';

  @override
  String get noteDrawEmpty => '画布还是空的';

  @override
  String noteDrawExportFailed(String error) {
    return '手绘导出失败：$error';
  }

  @override
  String noteDrawInsertFailed(String error) {
    return '手绘插入失败：$error';
  }

  @override
  String get noteDrawUnavailable => '手绘不可用';

  @override
  String get noteDrawUnavailableHint => '当前服务器缺少笔记附件接口，无法上传手绘';

  @override
  String get mediaSessionReconnected => '已重新连接，从原位置继续播放';

  @override
  String get mediaSessionResumeFailed => '会话已过期，自动续播失败；可点「重试」重新连接';

  @override
  String get officeSheetTitle => '表格';

  @override
  String get officeSheetLoading => '正在读取表格…';

  @override
  String get officeSheetLoadFailed => '打开失败';

  @override
  String get officeSheetSessionExpired => '登录会话已失效';

  @override
  String get officeSheetRetry => '重试';

  @override
  String get officeSheetFallbackPreview => '改用只读预览';

  @override
  String get officeSheetNoContent => '没有可显示的表格内容';

  @override
  String get officeSheetEditNextBatch => '编辑（下一批接入）';

  @override
  String officeSheetSessionUnavailable(String name) {
    return '协作会话未建立：$name';
  }

  @override
  String officeSheetModelFailed(String name) {
    return '无法重建表格模型：$name';
  }

  @override
  String get officeSheetEmpty => '这张工作簿里没有可显示的工作表';

  @override
  String get officeSheetNoRows => '这张工作表没有行列（rowCount/colCount 为 0）';

  @override
  String officeSheetRenderPartial(String count) {
    return '此表格有 $count 处内容未能完整显示。';
  }

  @override
  String get mediaCoverUnavailable => '暂无封面';

  @override
  String get fsDownloadTaskListTitle => '下载任务';

  @override
  String get fsDownloadTaskQueued => '等待中';

  @override
  String get fsDownloadTaskDownloading => '下载中';

  @override
  String get fsDownloadTaskPaused => '已暂停';

  @override
  String get fsDownloadTaskDone => '已完成';

  @override
  String get fsDownloadTaskFailed => '下载失败';

  @override
  String get fsDownloadTaskCancelled => '已取消';

  @override
  String get fsDownloadTaskOpen => '打开';

  @override
  String get fsDownloadTaskRetry => '重试';

  @override
  String get fsDownloadTaskClose => '关闭';

  @override
  String get fsDownloadTaskBackground => '后台继续';

  @override
  String get fsDownloadTaskQueuedHint => '排队中：前面的任务完成后自动开始';

  @override
  String get fsDownloadTaskActiveHint => '任务在后台继续；重新发起下载可再次打开此列表';

  @override
  String fsDownloadTaskSummary(String done, String total) {
    return '$done/$total 已完成';
  }

  @override
  String get officeSheetEditHint => '点按单元格即可编辑（改动会即时同步）。';

  @override
  String get officeSheetEditNoSession => '协作会话未建立，当前只读。';

  @override
  String get officeSheetPendingNone => '所有改动已确认';

  @override
  String officeSheetPendingCount(String count, String cells) {
    return '待确认改动：$count 项（$cells 格）';
  }

  @override
  String get officeSheetEditRetry => '重试';

  @override
  String officeSheetEditFailedCell(String cell, String reason) {
    return '「$cell」的改动未生效：$reason';
  }

  @override
  String get officeSheetEditReasonRejected => '服务端拒绝了这次改动（status 0）';

  @override
  String officeSheetEditReasonStale(String count) {
    return '服务端版本一直过期，已重放 $count 次';
  }

  @override
  String officeSheetEditReasonTransport(String detail) {
    return '发送失败：$detail';
  }

  @override
  String officeSheetEditReasonUnknown(String detail) {
    return '无法确认服务端结果：$detail';
  }

  @override
  String get fsDownloadTaskEmpty => '还没有下载任务';

  @override
  String get fsDownloadTaskEntry => '下载任务';

  @override
  String fsDownloadTaskEntryActive(String count, String percent) {
    return '下载任务 · $count 个进行中 · $percent%';
  }

  @override
  String get fsDownloadDisabled => '服务器未提供文件下载功能';

  @override
  String asQueueRestoreSkipped(String count) {
    return '播放队列里有 $count 首已不可用（被删除或无权限），已跳过';
  }

  @override
  String get fsC5TaskDetail => '后台任务详情';

  @override
  String get officeSlidesTitle => '演示文稿';

  @override
  String get officeSlidesLoading => '正在读取演示文稿…';

  @override
  String get officeSlidesLoadFailed => '打开失败';

  @override
  String get officeSlidesSessionExpired => '登录会话已失效';

  @override
  String get officeSlidesRetry => '重试';

  @override
  String get officeSlidesFallbackPreview => '改用只读预览';

  @override
  String get officeSlidesNoContent => '没有可显示的演示文稿内容';

  @override
  String get officeSlidesEditNextBatch => '编辑（下一批接入）';

  @override
  String officeSlidesSessionUnavailable(String name) {
    return '协作会话未建立：$name';
  }

  @override
  String officeSlidesModelFailed(String name) {
    return '无法重建演示文稿模型：$name';
  }

  @override
  String get officeSlidesEmpty => '这份演示文稿里没有可显示的幻灯片';

  @override
  String officeSlidesRenderPartial(String count) {
    return '本页有部分内容只以受限方式呈现（$count 处未登记/未渲染，见下方标记）。';
  }

  @override
  String officeSlidesSlidePage(String index) {
    return '第 $index 页';
  }

  @override
  String officeSlidesSlideCount(String count) {
    return '幻灯片 $count 页';
  }

  @override
  String officeSlidesLayoutCount(String count) {
    return '版式 $count 个';
  }

  @override
  String officeSlidesImageCount(String count) {
    return '图片 $count 张';
  }

  @override
  String get officeSlidesHiddenSlide => '隐藏页';

  @override
  String get officeSlidesSlideEmpty => '这一页没有可显示的正文';

  @override
  String get officeSlidesNotes => '备注';

  @override
  String officeSlidesMaster(String count) {
    return '母版（不并入各页正文，$count 段）';
  }

  @override
  String get officeSlidesMasterEmpty => '母版没有文本';

  @override
  String get officeSlidesReadOnly => '只读渲染';

  @override
  String get officeSlidesPageNumberToken => '页码';

  @override
  String get officeSlidesDateTimeToken => '日期时间';

  @override
  String officeSlidesUnsupportedType(String name) {
    return '暂不支持渲染的类型：$name';
  }

  @override
  String officeSlidesUnsupportedUnknown(String name) {
    return '暂不支持渲染的类型（schema 未声明）：$name';
  }

  @override
  String get officeSlidesUnsupportedInline => '不支持的内联类型';

  @override
  String get asQuickCast => '投送';

  @override
  String get asQuickEffects => '音效';

  @override
  String get asEqGroupMaster => '总开关';

  @override
  String get asEqGroupPresets => '预设';

  @override
  String get asCastDlnaHint => '可以改用同网段的 DLNA 投送（见「远程播放器」）。';

  @override
  String get asCastGroupDevices => '可投送设备';

  @override
  String get asPlayCountOne => '播放 1 次';

  @override
  String get asMinutesAgoOne => '1 分钟前';

  @override
  String get asHoursAgoOne => '1 小时前';

  @override
  String get asDaysAgoOne => '1 天前';

  @override
  String get asMoreSources => '媒体源';

  @override
  String get asMorePlayback => '播放与投送';

  @override
  String get asUnnamedName => '未命名';

  @override
  String get asLyricsFullscreen => '全屏歌词';

  @override
  String get asLyricsCopied => '已复制这一句';

  @override
  String get asLyricsFontSmaller => '缩小字号';

  @override
  String get asLyricsFontLarger => '放大字号';

  @override
  String get asQualityHint => '仅在服务端转码时生效；直传播放的是原文件';

  @override
  String get asRadioInfo => '电台信息';

  @override
  String get asRadioStop => '停止';

  @override
  String get asRadioOpenPlayer => '打开播放器';

  @override
  String get asRadioNowPlaying => '正在播放';

  @override
  String get asRadioPaused => '已暂停';

  @override
  String get asRadioDesc => '描述';

  @override
  String get asRadioDescEmpty => '（电台未提供描述）';

  @override
  String get asRadioTechHint => '地址与编码由电台服务端决定；需要修改请到「编辑电台」。';

  @override
  String get asQueueEntry => '播放队列';

  @override
  String asQueueEntryActive(String count) {
    return '播放队列 · $count 首';
  }

  @override
  String get asQueueEmpty => '播放队列还是空的（当前是单曲播放）';

  @override
  String get chatAvailableChannelsTitle => '公开频道';

  @override
  String get chatAvailableChannelsSearch => '搜索频道名';

  @override
  String get chatAvailableChannelsNoPrivilege => '没有查看公开频道的权限';

  @override
  String get chatAvailableChannelsLoadFailed => '公开频道加载失败';

  @override
  String get chatAvailableChannelsLoadFailedDetail => '请检查网络后重试';

  @override
  String chatAvailableChannelsMembers(String count) {
    return '$count 名成员';
  }

  @override
  String get chatAvailableChannelsJoin => '加入';

  @override
  String get chatAvailableChannelsNoMatch => '没有匹配的频道';

  @override
  String get officeSlidesEditNoSession => '协作会话未建立，当前只读。';

  @override
  String get officeSlidesEditHint => '点按幻灯片里的文字即可编辑（改动会即时同步）。';

  @override
  String get officeSlidesEditNoBlocks => '这份演示文稿里没有可编辑的文本';

  @override
  String get officeSlidesEditEmptyBlock => '（空文本块）';

  @override
  String get officeSlidesEditHintShort => '输入文本';

  @override
  String get officeSlidesEditCancel => '取消';

  @override
  String get officeSlidesEditSave => '保存';

  @override
  String get officeSlidesEditRetry => '重试';

  @override
  String get officeSlidesPendingNone => '所有改动已确认';

  @override
  String officeSlidesPendingCount(String count, String blocks) {
    return '待确认改动：$count 项（$blocks 段）';
  }

  @override
  String get officeSlidesEditReasonRejected => '服务端拒绝了这次改动（status 411）';

  @override
  String officeSlidesEditReasonStale(String count) {
    return '服务端版本一直过期，已重放 $count 次';
  }

  @override
  String officeSlidesEditReasonHistory(String detail) {
    return '拉取远端增量失败：$detail';
  }

  @override
  String officeSlidesEditReasonTransport(String detail) {
    return '发送失败：$detail';
  }

  @override
  String officeSlidesEditReasonUnknown(String detail) {
    return '无法确认服务端结果：$detail';
  }

  @override
  String officeSlidesEditFailedBlock(String block, String reason) {
    return '「$block」的改动未生效：$reason';
  }

  @override
  String get officeAttachmentMissingId => '缺少文件标识，取不到图片';

  @override
  String get officeAttachmentEmpty => '服务端返回了空图片';

  @override
  String get officeAttachmentTimeout => '取图片超时';

  @override
  String get officeAttachmentNotFound => '附件不存在（404）';

  @override
  String get officeAttachmentUnresolvable => '服务端取不出这张图片的附件（120）';

  @override
  String get officeAttachmentNoPermission => '没有权限查看这个附件（105）';

  @override
  String officeAttachmentSessionExpired(String code) {
    return '会话已失效（$code）';
  }

  @override
  String officeAttachmentHttpFailed(String status) {
    return '请求失败（HTTP $status）';
  }

  @override
  String get officeAttachmentListNeedsObjectId => '缺少文件标识，列不出附件';

  @override
  String get officeDocImageFailed => '图片加载失败';

  @override
  String officeDocImageFailedNamed(String name) {
    return '图片加载失败：$name';
  }

  @override
  String get officeDocImageRetry => '重试';

  @override
  String get officeDocImageReasonMissing => '这张图片没有可用的引用';

  @override
  String get officeDocImageReasonNotFound => '服务器上找不到这张图片';

  @override
  String get officeDocImageReasonNoPermission => '没有查看这张图片的权限';

  @override
  String get officeDocImageReasonSession => '登录状态已过期，重新登录后可重试';

  @override
  String get officeDocImageReasonTimeout => '网络超时';

  @override
  String get officeDocImageReasonNetwork => '网络连接失败';

  @override
  String get officeDocImageReasonEmpty => '服务器返回了空图片';

  @override
  String get officeDocImageReasonUnknown => '暂时无法显示';

  @override
  String get fsGapNoMore => '没有更多了';

  @override
  String get fsGapLoadingMore => '正在加载更多…';

  @override
  String get fsGapLoadMoreFailed => '加载更多失败';

  @override
  String get fsGapRetry => '重试';

  @override
  String get fsGapEditShareLink => '编辑分享链接';

  @override
  String get fsGapShareNewPassword => '新密码';

  @override
  String get fsGapSharePasswordKeep => '留空 = 保持当前密码';

  @override
  String get fsGapSharePasswordRemove => '保存后将移除密码';

  @override
  String get fsGapShareValidityKeep => '保持当前';

  @override
  String get fsGapShareEdited => '分享链接已更新';

  @override
  String get fsGapShareSend => '发送';

  @override
  String get fsGapShareSendFailed => '发送失败（没有可用的应用）';

  @override
  String get fsGapReadOnlyShare => '只读共享';

  @override
  String get driveGapSortTitle => '排序';

  @override
  String get driveGapSortDefault => '默认排序';

  @override
  String get driveGapSortName => '名称';

  @override
  String get driveGapSortSize => '大小';

  @override
  String get driveGapSortModified => '修改时间';

  @override
  String get driveGapSortCreated => '创建时间';

  @override
  String get driveGapSortAscending => '升序';

  @override
  String get driveGapSortDescending => '降序';

  @override
  String get driveGapViewList => '列表视图';

  @override
  String get driveGapViewGrid => '网格视图';

  @override
  String get driveGapSearchHistoryTitle => '最近搜索';

  @override
  String get driveGapSearchHistoryClear => '清除';

  @override
  String get driveGapRequestIdentifierTitle => '上传的文件怎么归类？';

  @override
  String get driveGapRequestIdentifierCreateFolder => '为每个上传者建一个文件夹';

  @override
  String get driveGapRequestIdentifierAddPrefix => '在文件名前加上传者名字';

  @override
  String get driveGapNewTextFile => '文本文件';

  @override
  String get driveGapNewTextFileHint => '纯文本（.txt），可直接编辑';

  @override
  String get driveGapTextEditorTitle => '编辑文本';

  @override
  String driveGapTextEditorLoadFailed(String error) {
    return '打不开这个文本文件：$error';
  }

  @override
  String get driveGapTextEditorSave => '保存';

  @override
  String get driveGapTextEditorHint => '开始输入…';

  @override
  String get driveGapTextEditorSaved => '已保存';

  @override
  String driveGapTextEditorSaveFailed(String error) {
    return '保存失败：$error';
  }

  @override
  String get driveGapTextEditorNotEditable => '这个位置不支持在应用内保存（目前只支持个人空间）';

  @override
  String get driveGapTextEditorReadOnly => '只读：你没有修改这个文件的权限';

  @override
  String get driveGapEditText => '编辑文本';

  @override
  String driveGapTextCreated(String name) {
    return '已创建「$name」';
  }

  @override
  String get driveGapScopeTitle => '这是你的「我的文件」，按范围分成三块';

  @override
  String get driveGapScopeIntro => '在「更多」里可以切换到另外两块范围：';

  @override
  String get driveGapScopeMyDriveTitle => '我的文件';

  @override
  String get driveGapScopeMyDriveBody => '你自己的文件，只有你能看见。';

  @override
  String get driveGapScopeSharedTitle => '与我共享';

  @override
  String get driveGapScopeSharedBody => '别人分享给你的单个文件或文件夹。';

  @override
  String get driveGapScopeTeamTitle => '团队文件夹';

  @override
  String get driveGapScopeTeamBody => '整个团队共用的空间，成员按权限读写。';

  @override
  String get driveGapScopeDismiss => '知道了';

  @override
  String get officeDocChartPlaceholder => '图表（暂无数据可渲染）';

  @override
  String get mediaSessionRenewFailedPaused =>
      '会话已过期且自动续期失败，已暂停播放；请回到 App 重新登录后重试';

  @override
  String get photoWave1TimelineViewDay => '日';

  @override
  String get photoWave1TimelineViewMonth => '月';

  @override
  String get photoWave1TimelineViewYear => '年';

  @override
  String get photoWave1TimelineViewMode => '时间刻度';

  @override
  String photoWave1GroupYear(String year) {
    return '$year 年';
  }

  @override
  String get photoWave1LoadMore => '加载更多';

  @override
  String get photoWave1LoadingMore => '正在加载…';

  @override
  String photoWave1AllLoaded(int count) {
    return '已全部加载（$count 张）';
  }

  @override
  String photoWave1LoadMoreFailed(String error) {
    return '加载下一页失败：$error';
  }

  @override
  String get photoWave1AlbumSort => '相册排序';

  @override
  String get photoWave1AlbumSortBy => '排序方式';

  @override
  String get photoWave1AlbumSortDirection => '排序方向';

  @override
  String get photoWave1AlbumSortAsc => '升序';

  @override
  String get photoWave1AlbumSortDesc => '降序';

  @override
  String get photoWave1AlbumSortName => '名称';

  @override
  String get photoWave1AlbumSortCreateTime => '创建时间';

  @override
  String get photoWave1AlbumSortStartTime => '开始时间';

  @override
  String get photoWave1AlbumSortType => '类型';

  @override
  String get photoWave1AlbumSortSharingStatus => '共享状态';

  @override
  String get photoWave1AlbumSortShareModTime => '共享修改时间';

  @override
  String get photoWave1AlbumSortSaved => '排序已保存';

  @override
  String photoWave1AlbumSortFailed(String error) {
    return '排序保存失败：$error';
  }

  @override
  String get photoWave1MoveToFolder => '移到文件夹';

  @override
  String get photoWave1CopyToFolder => '复制到文件夹';

  @override
  String get photoWave1MoveCopyPickFolder => '选择目标文件夹';

  @override
  String get photoWave1MoveCopyNoFolders => '没有可选择的文件夹';

  @override
  String photoWave1MovedCount(int count) {
    return '已移动 $count 项';
  }

  @override
  String photoWave1CopiedCount(int count) {
    return '已复制 $count 项';
  }

  @override
  String photoWave1MoveCopyFailed(String error) {
    return '操作失败：$error';
  }

  @override
  String get chatActionCopyDesc => '复制描述';

  @override
  String get chatMentionButton => '提及某人';

  @override
  String get noteGapsSelectAll => '全选';

  @override
  String get noteGapsInvertSelection => '反选';

  @override
  String noteGapsSelectedCount(int count) {
    return '已选 $count 项';
  }

  @override
  String get noteGapsBatchDelete => '批量删除';

  @override
  String noteGapsBatchDeleteConfirm(int count) {
    return '确定删除选中的 $count 条笔记吗？';
  }

  @override
  String get noteGapsBatchMove => '批量移动';

  @override
  String get noteGapsBatchMoveTitle => '移动到笔记本';

  @override
  String noteGapsBatchDeleted(int count) {
    return '已删除 $count 条笔记';
  }

  @override
  String noteGapsBatchMoved(int count) {
    return '已移动 $count 条笔记';
  }

  @override
  String noteGapsBatchPartial(int ok, int fail) {
    return '已删除 $ok 条，失败 $fail 条';
  }

  @override
  String noteGapsBatchFailed(String error) {
    return '批量操作失败：$error';
  }

  @override
  String get noteGapsSort => '排序';

  @override
  String get noteGapsSortByTitle => '按标题';

  @override
  String get noteGapsSortByCtime => '按创建时间';

  @override
  String get noteGapsSortByMtime => '按修改时间';

  @override
  String get noteGapsSortAsc => '升序';

  @override
  String get noteGapsSortDesc => '降序';

  @override
  String get noteGapsAttachmentSearch => '搜索附件文本';

  @override
  String get noteGapsAttachmentView => '查看文本';

  @override
  String get noteGapsAttachmentTextEmpty => '（没有可预览的文本）';

  @override
  String noteGapsAttachmentTextFailed(String error) {
    return '读取附件文本失败：$error';
  }

  @override
  String get noteGapsDefaultFontSize => '默认字号';

  @override
  String get noteGapsDefaultFontSizeSet => '默认字号已保存';

  @override
  String get noteGapsRecordAudio => '录音';

  @override
  String get noteGapsRecordAudioStart => '正在录音…';

  @override
  String get noteGapsRecordAudioStop => '完成';

  @override
  String get noteGapsRecordAudioDenied => '没有麦克风权限，无法录音';

  @override
  String noteGapsRecordAudioFailed(String error) {
    return '录音失败：$error';
  }

  @override
  String get noteGapsRecordAudioFileName => '录成 .3gp 作为附件';

  @override
  String get noteGapsRecordVideo => '录像';

  @override
  String get noteGapsShareClip => '剪藏到笔记';

  @override
  String get noteGapsShareClipNoNotebook => '没有可用的笔记本，无法剪藏到笔记。';

  @override
  String get noteGapsShareClipDone => '已剪藏到笔记。';

  @override
  String get noteGapsShareClipFailed => '分享剪藏失败，请稍后再试。';

  @override
  String get noteGapsShareClipTitle => '分享的文本';

  @override
  String get officeSlidesShapeUnsupported => '这个形状暂不支持显示';

  @override
  String get dsFileList => '文件列表';

  @override
  String get dsFileEmpty => '没有文件信息';

  @override
  String get dsFileSkipped => '跳过';

  @override
  String get dsLoadMore => '加载更多';

  @override
  String dsFilesTotal(int n) {
    return '共 $n 个文件';
  }

  @override
  String get dsFilesInactive => '任务未激活或已完成，暂无文件列表';

  @override
  String get dsExportTorrent => '导出 .torrent';

  @override
  String dsTorrentExported(String name) {
    return '已导出 $name';
  }

  @override
  String dsTorrentExportFailed(String msg) {
    return '导出失败：$msg';
  }

  @override
  String get dsSettings => '下载设置';

  @override
  String get dsSettingsLoadFailed => '设置加载失败';

  @override
  String dsSettingsSaveFailed(String msg) {
    return '保存失败：$msg';
  }

  @override
  String get dsAutoExtraction => '自动解压';

  @override
  String get dsUnzipToPath => '指定文件夹路径';

  @override
  String get dsUnzipToPathHint => '例如 /volume1/downloads';

  @override
  String get dsUnzipToPathSave => '保存路径';

  @override
  String get dsUnzipCreateSubfolder => '解压后创建子文件夹';

  @override
  String get dsUnzipOverwrite => '覆盖同名文件';

  @override
  String get dsUnzipDeleteArchive => '解压完成后删除压缩包';

  @override
  String get dsUnzipNeedPath => '请先填写目标文件夹路径';

  @override
  String get dsAutoExtractionHint => '下载完成后自动解压压缩文件（服务端设置）';

  @override
  String get dsAutoExtractionSaved => '自动解压设置已保存';

  @override
  String get dsAutoExtractionUnsupported =>
      '这台 NAS 的 Download Station 不支持自动解压设置';

  @override
  String get dsUnzipLocation => '解压位置';

  @override
  String get dsErrSourceNotAvailable => '这个任务没有可导出的源文件';

  @override
  String get dsErrNoThumbnail => '这个任务暂无缩略图';

  @override
  String get dsErrFileListInactive => '任务未激活或已完成，暂无文件列表';

  @override
  String get fsGap2PickFolder => '选择此文件夹';

  @override
  String get fsGap2Up => '上一级';

  @override
  String get fsGap2NoSubfolder => '此文件夹下没有子文件夹';

  @override
  String get fsGap2LoadFailed => '目录加载失败';

  @override
  String get fsGap2Root => '根目录';

  @override
  String get fsGap2CompressMode => '更新模式';

  @override
  String get fsGap2ModeAdd => '添加（新建）';

  @override
  String get fsGap2ModeUpdate => '更新（添加并替换）';

  @override
  String get fsGap2ModeFreshen => '刷新（仅更新已有）';

  @override
  String get fsGap2ModeSynchronize => '同步';

  @override
  String get fsGap2FavoriteReorder => '重排收藏';

  @override
  String get fsGap2FavoriteReorderSave => '保存顺序';

  @override
  String get fsGap2FavoriteReordered => '收藏顺序已保存';

  @override
  String get fsGap2MoveUp => '上移';

  @override
  String get fsGap2MoveDown => '下移';

  @override
  String get fsGap2PersonalFolder => '个人文件夹';

  @override
  String get fsGap2TaskRetry => '重试';

  @override
  String get fsGap2TaskRetryNoPlan => '该任务缺少参数快照，无法重试';

  @override
  String get fsGap2TaskRetrySubmitted => '已重新提交任务';

  @override
  String get fsGap2TaskParamSecretMasked => '已隐藏（口令类参数不显示明文）';

  @override
  String get fsGap2Shortcut => '创建桌面快捷方式';

  @override
  String get fsGap2ShortcutDone => '已请求创建快捷方式';

  @override
  String get fsGap2ShortcutFailed => '这台设备不支持创建快捷方式';

  @override
  String get fsGap2FavoriteReorderFailed => '收藏顺序保存失败';

  @override
  String get fsGap2FavoriteReorderRejected => '服务端拒绝了这组参数';

  @override
  String get officeLibraryNtypePresentation => '演示文稿';

  @override
  String get officeLibraryNtypeDoc => '文档';

  @override
  String get officeLibraryNtypeSheet => '表格';

  @override
  String get officeTemplateLibraryEmpty => '服务端没有返回可用模板';

  @override
  String get officeTemplateFilterAll => '全部';

  @override
  String get officeTemplateCanPreview => '可预览';

  @override
  String get officeTemplatePreview => '详情 / 预览';

  @override
  String get officeTemplateMake => '从模板新建';

  @override
  String get officeTemplateMakeDialogTitle => '从模板新建';

  @override
  String get officeTemplateMakeTitleLabel => '文件名（可留空）';

  @override
  String get officeTemplateMakeCancel => '取消';

  @override
  String get officeTemplateMakeConfirm => '创建';

  @override
  String officeTemplateMakeCreated(Object name) {
    return '已从模板「$name」新建';
  }

  @override
  String officeTemplateMakeFailed(Object error) {
    return '从模板新建失败：$error';
  }

  @override
  String get officeTemplatePreviewAction => '预览';

  @override
  String get officeTemplatePreviewClose => '关闭';

  @override
  String get officeTemplatePreviewNote => '这是官方缩略图预览，不是正文渲染；要查看正文请用此模板新建后打开';

  @override
  String officeTemplatePreviewCounter(Object index, Object total) {
    return '$index / $total';
  }

  @override
  String get officeTemplatePreviewPrev => '上一个';

  @override
  String get officeTemplatePreviewNext => '下一个';

  @override
  String get officeTemplatePreviewShowBody => '看正文';

  @override
  String get officeTemplatePreviewShowThumb => '看缩略图';

  @override
  String get officeTemplatePreviewBodyNote =>
      '正文由服务端导出后本地渲染（只读）；导出失败会如实回落官方缩略图';

  @override
  String get officeTemplateBodyEncrypted => '这是加密模板，需要口令才能导出正文';

  @override
  String get officeTemplateBodyUnknownType => '这种类型的模板没有可用的正文导出';

  @override
  String officeTemplateBodyFailed(Object error) {
    return '正文导出失败：$error';
  }

  @override
  String get officeTemplateBodyFetching => '正在获取模板正文…';

  @override
  String get officeTemplateBodyRendering => '正在排版…';

  @override
  String get officeTemplateBodyReasonMissingId => '这个模板缺少标识，取不到正文';

  @override
  String get officeTemplateBodyReasonNotFound => '服务端说这个模板的正文不在了（可能已被删除）';

  @override
  String get officeTemplateBodyReasonNoPermission => '当前账号没有导出这个模板正文的权限';

  @override
  String get officeTemplateBodyReasonSession => '登录状态已失效，重新连接后再试';

  @override
  String get officeTemplateBodyReasonTimeout => '取模板正文超时，可以重试';

  @override
  String get officeTemplateBodyReasonNetwork => '网络不通，取不到模板正文';

  @override
  String get officeTemplateBodyReasonEmpty => '服务端回了空正文（这个模板可能没有内容）';

  @override
  String get officeTemplateBodyNotOoxml => '服务端返回的不是标准表格文件，无法预览';

  @override
  String officeTemplateBodyParseFailed(Object error) {
    return '这份模板解析失败：$error';
  }

  @override
  String get officeTemplateExportMissingId => '缺少模板标识，取不到模板正文';

  @override
  String get officeTemplateExportEmpty => '服务端返回了空正文';

  @override
  String get officeTemplateExportTimeout => '取模板正文超时';

  @override
  String get officeTemplateExportUnavailable => '这条通道在当前连接上不可用';

  @override
  String get officeTemplateUse => '使用此模板';

  @override
  String get officeTemplateUseEncrypted => '加密新建';

  @override
  String get officeTemplateSourceSystem => '系统';

  @override
  String get officeTemplateSourceMine => '我的';

  @override
  String get officeTemplateMoreActions => '更多操作';

  @override
  String get officeTemplateThumbMissingId => '缺少模板标识，取不到缩略图';

  @override
  String get officeTemplateThumbEmpty => '服务端返回了空缩略图';

  @override
  String get officeTemplateThumbTimeout => '取缩略图超时';

  @override
  String get officeThemeEmpty => '这个类型没有可用主题';

  @override
  String get officeThemeApply => '应用主题';

  @override
  String officeThemeApplyFailed(Object error) {
    return '应用主题失败：$error';
  }

  @override
  String officeThemeApplied(Object name) {
    return '已请求服务端应用主题「$name」';
  }

  @override
  String get officeVersionEmpty => '还没有版本记录';

  @override
  String get officeVersionFirst => '初始版本';

  @override
  String officeSheetConditionalFormats(Object count) {
    return '已套用的条件格式规则（$count 条）';
  }

  @override
  String officeSheetConditionalFormatLine(Object formula, Object ranges) {
    return '$ranges · $formula';
  }

  @override
  String get dsBtSearchTitle => 'BT 搜索';

  @override
  String get dsBtBack => '返回';

  @override
  String get dsBtSearchHint => '输入关键词搜索种子';

  @override
  String get dsBtSearchAction => '搜索';

  @override
  String get dsBtSourceLabel => '数据源';

  @override
  String get dsBtSourceAll => '全部数据源';

  @override
  String get dsBtIdleTitle => '搜索种子';

  @override
  String get dsBtIdleMessage => '输入关键词，从 NAS 上已启用的搜索数据源里查找。';

  @override
  String get dsBtSearching => '正在搜索…';

  @override
  String get dsBtIncompleteHint => '部分搜索数据源无法连接，结果可能不完整。';

  @override
  String get dsBtCategoryAll => '全部分类';

  @override
  String get dsBtSortTooltip => '排序';

  @override
  String get dsBtSortFieldTitle => '名称';

  @override
  String get dsBtSortFieldSize => '大小';

  @override
  String get dsBtSortFieldDate => '时间';

  @override
  String get dsBtSortFieldSeeds => '种子数';

  @override
  String get dsBtSortFieldPeers => '连接数';

  @override
  String get dsBtSortAsc => '升序';

  @override
  String get dsBtSortDesc => '降序';

  @override
  String get dsBtLoadMore => '加载更多';

  @override
  String get dsBtEndOfResults => '已经到底了';

  @override
  String get dsBtDownload => '下载';

  @override
  String get dsBtDownloadAdded => '已添加到下载任务';

  @override
  String dsBtDownloadFailed(Object error) {
    return '添加下载失败：$error';
  }

  @override
  String get dsBtUntitled => '（无标题）';

  @override
  String get dsBtUnknown => '未知';

  @override
  String get dsBtSizeLabel => '大小';

  @override
  String get dsBtSeedsLabel => '种子';

  @override
  String get dsBtPeersLabel => '连接';

  @override
  String get dsLabelSep => '：';

  @override
  String get dsBtNeedDest => '未能取到默认下载目录：请在「新建任务」里确认目录后再创建';

  @override
  String get dsBtErrorTitle => '搜索失败';

  @override
  String get dsBtNoResultsTitle => '没有找到结果';

  @override
  String get dsBtNoResultsMessage => '换个关键词或数据源再试试。';

  @override
  String get dsBtUnavailableTitle => 'BT 搜索暂不可用';

  @override
  String get dsBtUnavailableApiMissing => '还没有连接 NAS。';

  @override
  String get dsBtUnavailableNotInstalled => '这台 NAS 没有安装 Download Station。';

  @override
  String get dsBtUnavailableNoPrivilege => '这个账号没有使用 BT 搜索的权限。';

  @override
  String get dsBtUnavailableIdNotFound => '这台 NAS 未启用 BT 搜索，或搜索会话已失效。';

  @override
  String get dsBtUnavailableNoPlugins => '这台 NAS 未启用 BT 搜索，或没有可用的搜索数据源。';

  @override
  String get dsBtUnavailableSources => '没有读取到可用的搜索数据源。';

  @override
  String get dsBtUnavailableOffline => '网络连接失败，请检查网络后重试。';

  @override
  String get dsErrBtSearchUnavailable => '这台 NAS 未启用 BT 搜索或没有可用数据源';

  @override
  String get photoWave2SearchFilter => '筛选';

  @override
  String get photoWave2SearchFilterTitle => '筛选条件';

  @override
  String get photoWave2SearchFilterApply => '应用';

  @override
  String get photoWave2SearchFilterClear => '清空';

  @override
  String get photoWave2SearchFilterUnavailable => '筛选项暂时不可用';

  @override
  String photoWave2SearchFilterActive(Object count) {
    return '已启用 $count 组筛选';
  }

  @override
  String get photoWave2Tags => '标签';

  @override
  String get photoWave2TagsEntry => '按标签浏览照片（标签由 NAS 端索引）';

  @override
  String get photoWave2TagsEmpty => '还没有标签';

  @override
  String photoWave2TagItemCount(Object count) {
    return '$count 张照片';
  }

  @override
  String get photoWave2TagPhotosEmpty => '这个标签还没有照片';

  @override
  String get photoWave2TagsLocalNote => '服务端标签列表当前为空，以下为本机见过的标签';

  @override
  String photoWave2TagLoaded(Object count) {
    return '已加载 $count 张';
  }

  @override
  String photoWave2TagTotal(Object count) {
    return '共 $count 个标签';
  }

  @override
  String get photoWave2Persons => '人物';

  @override
  String get photoWave2PersonsEntry => '按人物浏览照片（需 NAS 端已开启人脸识别）';

  @override
  String get photoWave2PersonSearchHint => '按名字前缀找人';

  @override
  String get photoWave2PersonSuggestEmpty => '没有匹配的人物';

  @override
  String photoWave2PersonFaces(Object count) {
    return '本页识别到 $count 张人脸';
  }

  @override
  String get photoWave2PersonFacesFailed => '人脸信息暂时取不到';

  @override
  String get photoWave2PartialUnavailable => '这部分内容暂时取不到，可稍后重试。';

  @override
  String get calSettingsTitle => '日历设置';

  @override
  String get calSettingsSubtitle => '配色 / 时区 / 共享日历 / 用户设置（只读）';

  @override
  String get calEventColorsSection => '日程配色（服务端）';

  @override
  String get calEventColor => '日程配色';

  @override
  String get calColorDefault => '默认色';

  @override
  String get calNoServerColors => '这台 NAS 没有返回可用配色（需要更高的服务端版本）。';

  @override
  String get calTimezoneSection => '时区';

  @override
  String get calTimezoneCurrent => '新建日程的时区';

  @override
  String get calTimezonePick => '选择时区';

  @override
  String get calTimezoneEmpty => '这台 NAS 没有返回时区表。';

  @override
  String get calUserSettingsSection => '用户设置（只读）';

  @override
  String get calDateFormat => '日期格式';

  @override
  String get calTimeFormat => '时间格式';

  @override
  String get calWeekStart => '每周起始日';

  @override
  String get calDefaultView => '默认视图';

  @override
  String get calShowWeekNumbers => '显示周数';

  @override
  String get calYes => '是';

  @override
  String get calNo => '否';

  @override
  String get calWeekdaySun => '周日';

  @override
  String get calWeekdayMon => '周一';

  @override
  String get calWeekdayTue => '周二';

  @override
  String get calWeekdayWed => '周三';

  @override
  String get calWeekdayThu => '周四';

  @override
  String get calWeekdayFri => '周五';

  @override
  String get calWeekdaySat => '周六';

  @override
  String get calSharingSection => '共享日历';

  @override
  String get calSharingManage => '查看 / 设置共享成员';

  @override
  String get calSharingNone => '这个日历没有共享给任何人。';

  @override
  String get calSharingAdd => '添加成员';

  @override
  String get calSharingSaved => '共享设置已更新';

  @override
  String get calSharingSaveFailed => '共享设置保存失败';

  @override
  String get calSaving => '正在保存…';

  @override
  String get calRemove => '移除';

  @override
  String get calImportSection => '导入';

  @override
  String get calIcsImport => 'ICS 导入';

  @override
  String get calIcsImportUnavailable =>
      'ICS 导入暂不支持：服务端接口的参数还没有核实清楚，硬接上去会变成「点了就失败」的入口。';

  @override
  String get calInviteMail => '邀请邮件';

  @override
  String get calInviteMailUnavailable =>
      '邀请邮件需要 NAS 上的邮件套件（MailPlus 或邮件服务器）配合，且需要管理员账号。此功能当前不可用。';

  @override
  String get calLoading => '加载中…';

  @override
  String get officeLibraryNotConnected => '未连接';

  @override
  String get officeLibraryRefresh => '刷新';

  @override
  String get officeLibraryRetry => '重试';

  @override
  String get officeTemplateLibraryTitle => '模板库';

  @override
  String officeTemplateLibraryLoadFailed(Object error) {
    return '模板库加载失败：$error';
  }

  @override
  String get officeTemplateMakeUnopened => '已新建，但服务端没有返回可打开的节点';

  @override
  String get officeThemeTitle => '主题';

  @override
  String get officeThemeEntry => '主题';

  @override
  String get officeThemeNoObjectId => '解析不到文档内部 id，未发送应用请求';

  @override
  String officeThemeLoadFailed(Object error) {
    return '主题加载失败：$error';
  }

  @override
  String get officeVersionReadOnlyTitle => '版本记录（只读）';

  @override
  String get officeVersionReadOnlyEntry => '版本记录（只读）';

  @override
  String officeVersionLoadFailed(Object error) {
    return '版本记录加载失败：$error';
  }

  @override
  String get fsGap3ShareWithMe => '共享给我的';

  @override
  String get fsGap3NoSharedWithMe => '还没有人分享给你';

  @override
  String get fsGap3NoSharedWithMeMessage => '别人分享给你的文件会出现在这里。';

  @override
  String get fsGap3SharedWithMeLoadFailed => '共享给我的列表加载失败';

  @override
  String get fsGap3SharedWithMeUnavailable => '服务器不支持\"共享给我的\"';

  @override
  String get fsGap3SharedBy => '来自';

  @override
  String get fsGap3StatusExpired => '已过期';

  @override
  String get fsGap3StatusInactive => '未生效';

  @override
  String get fsGap3StatusOk => '有效';

  @override
  String get fsGap3TypeSharingLinks => '分享链接';

  @override
  String get fsGap3TypeRequestLink => '文件请求';

  @override
  String get fsGap3TypeDocumentLink => '文档链接';

  @override
  String noteBTodoTimeoutChip(Object count) {
    return '已超时 $count';
  }

  @override
  String get noteBTodoTimeoutEmpty => '没有已超时的待办';

  @override
  String get noteBTodoTimeoutHint => '所有待办都还在截止时间内';

  @override
  String get noteBShortcut => '快捷方式';

  @override
  String get noteBShortcutEmpty => '还没有快捷方式';

  @override
  String get noteBShortcutEmptyHint => '服务端还没有为这个账号保存任何快捷方式';

  @override
  String get noteBShortcutLoadFailed => '快捷方式加载失败';

  @override
  String get noteBShortcutCategoryNotebook => '笔记本';

  @override
  String get noteBShortcutCategoryNote => '笔记';

  @override
  String get noteBShortcutCategoryTag => '标签';

  @override
  String get noteBShortcutCategoryStack => '分层';

  @override
  String get noteBShortcutCategorySmart => '智能笔记本';

  @override
  String get noteBShortcutCategoryOther => '其它';

  @override
  String get driveWave2QuotaTitle => '存储空间';

  @override
  String get driveWave2QuotaEntry => '查看 Drive 的已用空间与配额';

  @override
  String get driveWave2QuotaMyDrive => '我的文件';

  @override
  String get driveWave2QuotaUnlimited => '不限额';

  @override
  String driveWave2QuotaUsed(Object used) {
    return '已使用 $used';
  }

  @override
  String driveWave2QuotaUsedOf(Object total, Object used) {
    return '$total 中已使用 $used';
  }

  @override
  String driveWave2QuotaPercent(Object percent) {
    return '已用 $percent%';
  }

  @override
  String get driveWave2QuotaEmpty => '没有可显示的空间配额信息';

  @override
  String get driveWave2QuotaLoadFailed => '读取存储空间失败';

  @override
  String get driveWave2QuotaRefresh => '刷新';

  @override
  String get driveWave2QuotaOtherShares => '其它文件夹';

  @override
  String get driveWave2ConvertTitle => '转成 Office 格式';

  @override
  String get driveWave2ConvertEntry => '转成 Office 格式';

  @override
  String get driveWave2ConvertTarget => '目标格式';

  @override
  String get driveWave2ConvertTargetDocx => 'Word 文档（.docx）';

  @override
  String get driveWave2ConvertSubmit => '开始转换';

  @override
  String get driveWave2ConvertSubmitting => '正在提交转换…';

  @override
  String get driveWave2ConvertSubmitted => '已提交转换，正在后台处理。完成后会出现在原文件夹中。';

  @override
  String get driveWave2ConvertFinished => '转换完成';

  @override
  String get driveWave2ConvertFailed => '转换失败，请稍后重试';

  @override
  String get driveWave2ConvertUnavailable => '这台 NAS 没有提供该转换服务';

  @override
  String get driveWave2ConvertClose => '关闭';

  @override
  String get calExportSection => '导出';

  @override
  String get calExportIcs => '导出为 .ics 文件';

  @override
  String get calExportDone => '已导出';

  @override
  String get calExportOpen => '打开 / 分享';

  @override
  String get calExportFailed => '导出失败';

  @override
  String get calTodoSearchTitle => '搜索待办';

  @override
  String get calTodoSearchHint => '输入关键字';

  @override
  String get calTodoSearchAction => '搜索';

  @override
  String get calTodoSearchPrompt => '输入关键字后点「搜索」。';

  @override
  String get calTodoSearchEmpty => '没有找到匹配的待办。';

  @override
  String get dsRssTitle => 'RSS 订阅';

  @override
  String get dsRssBack => '返回';

  @override
  String get dsRssUpdateAll => '全部更新';

  @override
  String get dsRssAdd => '添加订阅';

  @override
  String get dsRssAddQueued => '已提交订阅，正在抓取。';

  @override
  String get dsRssAddSubmit => '添加';

  @override
  String get dsRssAutoDownload => '自动下载新条目';

  @override
  String get dsRssCancel => '取消';

  @override
  String get dsRssClearItems => '清空条目';

  @override
  String get dsRssClearItemsConfirm => '要清空这个订阅源已抓取的条目吗？';

  @override
  String get dsRssConfirm => '确定';

  @override
  String get dsRssDelete => '删除';

  @override
  String get dsRssDeleteConfirm => '要删除这个订阅源吗？该源的条目也会一并移除。';

  @override
  String get dsRssDeleteTitle => '删除订阅';

  @override
  String get dsRssDestHint => '留空用默认目录';

  @override
  String get dsRssDestLabel => '下载目录（可选）';

  @override
  String get dsRssEmptyMessage => '点右下角添加一个 RSS 订阅地址。';

  @override
  String get dsRssEmptyTitle => '还没有订阅源';

  @override
  String get dsRssEndOfItems => '已经到底了';

  @override
  String get dsRssErrorTitle => '加载订阅失败';

  @override
  String get dsRssFilterAdd => '新建规则';

  @override
  String get dsRssFilterDeleteConfirm => '要删除这条自动下载规则吗？';

  @override
  String get dsRssFilterDeleteTitle => '删除规则';

  @override
  String get dsRssFilterDest => '下载到';

  @override
  String get dsRssFilterEditTitle => '编辑规则';

  @override
  String get dsRssFilterMatch => '包含';

  @override
  String get dsRssFilterMatched => '规则匹配成功';

  @override
  String get dsRssFilterName => '规则名称';

  @override
  String get dsRssFilterNameRequired => '请填写规则名称';

  @override
  String get dsRssFilterNotMatch => '排除';

  @override
  String get dsRssFilterNotMatched => '规则不匹配';

  @override
  String get dsRssFilterRegex => '按正则表达式解析';

  @override
  String get dsRssFilterSaved => '规则已保存';

  @override
  String get dsRssFilterTest => '试跑';

  @override
  String get dsRssFilterTestString => '试跑文本';

  @override
  String get dsRssFiltersEmptyMessage => '规则按关键词匹配新条目，命中后自动下载到指定目录。';

  @override
  String get dsRssFiltersEmptyTitle => '还没有自动下载规则';

  @override
  String get dsRssFiltersErrorTitle => '加载过滤器失败';

  @override
  String get dsRssItemNew => '新';

  @override
  String get dsRssItemUntitled => '（无标题）';

  @override
  String get dsRssItemsEmptyMessage => '这个订阅源还没有抓到条目，稍后刷新试试。';

  @override
  String get dsRssItemsEmptyTitle => '还没有条目';

  @override
  String get dsRssItemsErrorTitle => '加载条目失败';

  @override
  String get dsRssLastUpdate => '上次更新';

  @override
  String get dsRssLoadMore => '加载更多';

  @override
  String get dsRssNeverUpdated => '尚未更新';

  @override
  String get dsRssSave => '保存';

  @override
  String get dsRssTabFilters => '自动下载';

  @override
  String get dsRssTabItems => '条目';

  @override
  String get dsRssTestRequired => '请填写试跑文本';

  @override
  String get dsRssUnavailableApiMissing => '还没有连接 NAS。';

  @override
  String get dsRssUnavailableNoPrivilege => '这个账号没有使用 RSS 订阅的权限。';

  @override
  String get dsRssUnavailableNotInstalled => '这台 NAS 没有安装 Download Station。';

  @override
  String get dsRssUnavailableOffline => '网络连接失败，请检查网络后重试。';

  @override
  String get dsRssUnavailableTitle => 'RSS 暂不可用';

  @override
  String get dsRssUntitled => '（未命名订阅）';

  @override
  String get dsRssUpdate => '立即更新';

  @override
  String get dsRssUpdating => '更新中…';

  @override
  String get dsRssUpdatingHint => '订阅源正在更新，列表会自动刷新。';

  @override
  String get dsRssUrlLabel => 'RSS 地址';

  @override
  String get dsRssUrlRequired => '请填写 RSS 地址';

  @override
  String get photoWave3ExifTitle => '拍摄信息';

  @override
  String get photoWave3ExifCamera => '相机';

  @override
  String get photoWave3ExifAperture => '光圈';

  @override
  String get photoWave3ExifExposureTime => '曝光时间';

  @override
  String get photoWave3ExifFocalLength => '焦距';

  @override
  String get photoWave3ExifIso => 'ISO';

  @override
  String get photoWave3ExifLens => '镜头';

  @override
  String get photoWave3ExifEmpty => '这张照片没有可显示的拍摄信息';

  @override
  String get photoWave3ExifFailed => '拍摄信息暂时取不到';

  @override
  String get photoWave3AlbumSettings => '相册设置';

  @override
  String get photoWave3Cache => '相册缓存';

  @override
  String get photoWave3CacheStatus => '缓存状态';

  @override
  String get photoWave3CacheStatusDone => '已完成';

  @override
  String get photoWave3CacheStatusProcessing => '正在处理';

  @override
  String get photoWave3CacheStatusUnknown => '状态未知';

  @override
  String get photoWave3CacheSize => '缓存占用';

  @override
  String photoWave3CacheSizeValue(Object size) {
    return 'NAS 上的图片缓存占用了 $size';
  }

  @override
  String get photoWave3CacheSizeUnavailable => '暂时取不到缓存大小';

  @override
  String get photoWave3CacheReadOnly => '本版本只展示缓存状态与占用，不提供清理操作。';

  @override
  String get photoWave3AlbumListDisplay => '相册列表显示偏好';

  @override
  String get photoWave3AlbumDisplayAll => '所有相册';

  @override
  String get photoWave3AlbumDisplayMine => '我的相册';

  @override
  String get photoWave3AlbumDisplayUnknown => '服务端返回了未识别的显示偏好';

  @override
  String get photoWave3Refresh => '重新读取';

  @override
  String chatErrUnknownCode(Object code) {
    return '未知错误（$code）';
  }

  @override
  String get apiDeleteReactionNeedsSticker =>
      'deleteReaction 需要 stickerId 或 stickerName';

  @override
  String get dsBtPollingHint => '正在搜索数据源，结果会持续增加…';

  @override
  String get dsBtNoResultsFilteredMessage => '所选数据源没有结果，或换个关键词再试试。';

  @override
  String get dsBtSourceUnnamed => '未命名数据源';

  @override
  String get asRadioTitle => '网络电台';

  @override
  String get asRadioSearchTitle => '搜台';

  @override
  String get asRadioSearchHint => '输入关键字搜索网络电台';

  @override
  String get asRadioSearchEmpty => '没有匹配的电台';

  @override
  String get asAddToPlaylist => '加入播放列表';

  @override
  String get asChoosePlaylist => '选择播放列表';

  @override
  String get asChoosePlaylistEmpty => '还没有播放列表，请先在音频首页新建一个';

  @override
  String asPlaylistAdded(Object name) {
    return '已加入「$name」';
  }

  @override
  String get asRadioSearchUnsupported => '这台 NAS 的 Audio Station 不支持关键字搜台';

  @override
  String get asRadioEmpty => '还没有电台';

  @override
  String get asRadioLoadFailed => '电台加载失败';

  @override
  String get asRadioContainerBadge => '电台分类';

  @override
  String get asRadioStationBadge => '电台';

  @override
  String get asRadioListNote => '点分类进入下一层，点电台开始播放。部分电台要先解析播放列表，起播会慢一拍。';

  @override
  String get asEmptyComposers => '还没有作曲家';

  @override
  String get asEmptyDetailComposers => '这里还没有作曲家';

  @override
  String asComposerCount(int n) {
    return '$n 位作曲家';
  }

  @override
  String get asWebQueueTitle => '播放队列';

  @override
  String get asWebQueueEmpty => '服务端播放队列是空的';

  @override
  String get asWebQueueLoadFailed => '播放队列加载失败';

  @override
  String get asWebQueueUnsupported => '这台 NAS 的 Audio Station 不支持播放队列';

  @override
  String get asWebQueueShuffleOn => '随机播放：开';

  @override
  String get asWebQueueShuffleOff => '随机播放：关';

  @override
  String get asWebQueueModeNormal => '顺序播放';

  @override
  String get noteWave4FtsEntry => '全文检索';

  @override
  String get noteWave4FtsTitle => '全文检索';

  @override
  String get noteWave4FtsHint => '按标题、正文、附件文本检索';

  @override
  String get noteWave4FtsPrompt => '输入关键词开始检索';

  @override
  String get noteWave4FtsEmpty => '没有匹配的笔记';

  @override
  String get noteWave4FtsEmptyHint => '换个关键词试试；若服务端未启用全文检索，可回到列表页按标题过滤';

  @override
  String get noteWave4FtsFailed => '检索失败';

  @override
  String get noteWave4ShortcutAdd => '加入快捷方式';

  @override
  String get noteWave4ShortcutRemove => '取消快捷方式';

  @override
  String get noteWave4ShortcutAdded => '已加入快捷方式';

  @override
  String get noteWave4ShortcutRemoved => '已取消快捷方式';

  @override
  String noteWave4ShortcutFailed(Object error) {
    return '快捷方式操作失败：$error';
  }

  @override
  String noteWave4ShortcutDeleteConfirm(Object name) {
    return '确定取消「$name」这个快捷方式吗？';
  }

  @override
  String get noteWave4ShortcutNoTarget => '这个快捷方式没有可跳转的目标';

  @override
  String get noteWave4NewFromCamera => '拍照新建';

  @override
  String get noteWave4NewFromVideo => '录像新建';

  @override
  String get noteWave4ExportSubmitted => '已提交导出任务，正在服务端生成…';

  @override
  String noteWave4ExportSaved(Object name) {
    return '已导出到 $name';
  }

  @override
  String get noteWave4ExportSubsystem =>
      '这台 NAS 的导出子系统报错（导出产物依赖 Synology Drive）';

  @override
  String get noteWave5ChangePassword => '改口令';

  @override
  String get noteWave5ChangePasswordTitle => '修改笔记口令';

  @override
  String get noteWave5OldPassword => '当前口令';

  @override
  String get noteWave5NewPassword => '新口令';

  @override
  String get noteWave5ConfirmPassword => '确认新口令';

  @override
  String get noteWave5ChangePasswordDone => '口令已修改';

  @override
  String noteWave5ChangePasswordFailed(Object error) {
    return '改口令失败：$error';
  }

  @override
  String noteWave5UnlockFailed(Object error) {
    return '操作失败：$error';
  }

  @override
  String get noteWave5PasswordMismatch => '两次输入的新口令不一致';

  @override
  String get noteWave5PasswordRequired => '请输入当前口令';

  @override
  String get noteWave5NewPasswordRequired => '请输入新口令';

  @override
  String get noteWave5PasswordUnchanged => '新口令和当前口令一样';

  @override
  String get noteWave5ChangePasswordNoContent => '笔记正文还没同步下来，暂时不能改口令';

  @override
  String get noteWave5InfoTitle => '笔记信息';

  @override
  String get noteWave5InfoSize => '大小（近似）';

  @override
  String get noteWave5InfoCreated => '创建时间';

  @override
  String get noteWave5InfoModified => '修改时间';

  @override
  String get noteWave5InfoSource => '来源链接';

  @override
  String get noteWave5InfoNotebook => '笔记本';

  @override
  String get noteWave5InfoTags => '标签';

  @override
  String get noteWave5InfoOwner => '所有者';

  @override
  String get noteWave5InfoEncrypted => '加密';

  @override
  String get noteWave5InfoUnset => '—';

  @override
  String get noteWave5TopLevel => '（顶层）';

  @override
  String get noteWave5SourceUrlEdit => '编辑来源链接';

  @override
  String get noteWave5SourceUrlHint => 'https://…';

  @override
  String get noteWave5SourceUrlSaved => '来源链接已保存';

  @override
  String get noteWave5SourceUrlInvalid => '链接格式不对';

  @override
  String get noteWave5SourceUrlOpenFailed => '打不开这个链接';

  @override
  String noteWave5SourceUrlOpenFailedDetail(Object error) {
    return '打不开这个链接：$error';
  }

  @override
  String get noteWave5SourceUrlOpen => '打开链接';

  @override
  String get noteWave5Archive => '归档';

  @override
  String get noteWave5Unarchive => '取消归档';

  @override
  String get noteWave5Archived => '已归档';

  @override
  String get noteWave5Unarchived => '已取消归档';

  @override
  String get noteWave5ShowArchived => '显示已归档笔记本';

  @override
  String noteWave5ArchiveFailed(Object error) {
    return '归档失败：$error';
  }

  @override
  String noteWave5EmptyRecycleDone(Object count) {
    return '已清空回收站（$count 条）';
  }

  @override
  String noteWave5EmptyRecyclePartial(Object ok, Object fail) {
    return '已清空 $ok 条，$fail 条失败';
  }

  @override
  String get noteWave5ViewList => '列表视图';

  @override
  String get noteWave5ViewGrid => '网格视图';

  @override
  String get noteWave5ShowSubTags => '显示子标签';

  @override
  String get noteWave5SubTagOf => '父标签';

  @override
  String get noteWave5TagOperatorOr => '任一标签（OR）';

  @override
  String get noteWave5TagOperatorAnd => '全部标签（AND）';

  @override
  String get noteWave5FilterByTags => '按标签筛选';

  @override
  String get noteWave5ClearTagFilter => '清除标签筛选';

  @override
  String get fsGap4WormSection => 'WriteOnce';

  @override
  String get fsGap4WormMode => '模式';

  @override
  String get fsGap4WormAutoLock => '自动锁定';

  @override
  String get fsGap4WormEnabled => '已启用';

  @override
  String get fsGap4WormNotEnabled => '未启用';

  @override
  String get fsGap4WormLockWaitTime => '自动锁定时间设置';

  @override
  String get fsGap4WormRetention => '锁定期间';

  @override
  String get fsGap4WormLockState => '锁定状态';

  @override
  String get fsGap4WormUnset => '—';

  @override
  String get fsGap4WormSubvolNormal => 'Normal';

  @override
  String get fsGap4WormSubvolEnterprise => 'Enterprise';

  @override
  String get fsGap4WormSubvolCompliance => 'Compliance';

  @override
  String get fsGap4WormSubvolNormalPlus => 'Normal+';

  @override
  String get fsGap4WormStateOpen => '开放';

  @override
  String get fsGap4WormStateLocked => '锁定';

  @override
  String get fsGap4WormStateImmutable => '不可变';

  @override
  String get fsGap4WormStateAppendOnly => '可附加';

  @override
  String get fsGap4WormStateExpired => '已过期';

  @override
  String get fsGap4WormStateUnknown => '未知';

  @override
  String get fsGap4WormUnitYear => '年';

  @override
  String get fsGap4WormUnitDay => '天';

  @override
  String get fsGap4WormUnitHour => '小时';

  @override
  String get fsGap4WormUnitMinute => '分';

  @override
  String get fsGap4WormUnitSecond => '秒';

  @override
  String get fsGap4WormForever => '永久锁定';

  @override
  String get dsCaptchaTitle => '输入验证码';

  @override
  String get dsCaptchaHint => '这台 NAS 要求输入验证码才能继续这个下载任务，请输入图片里的字符。';

  @override
  String dsCaptchaProgress(Object cur, Object total) {
    return '第 $cur/$total 个';
  }

  @override
  String get dsCaptchaImageFailed => '验证码图片加载失败，请重试';

  @override
  String get dsCaptchaRetryImage => '重新加载图片';

  @override
  String get dsCaptchaCodeLabel => '验证码';

  @override
  String get dsCaptchaSubmit => '提交';

  @override
  String get dsCaptchaSkip => '跳过这个任务';

  @override
  String get dsCaptchaCodeRequired => '请输入验证码';

  @override
  String get dsCaptchaAccepted => '验证码已提交';

  @override
  String get dsCaptchaLoadFailed => '验证码任务读取失败';

  @override
  String get dsCaptchaNoneTitle => '没有需要验证码的任务';

  @override
  String get dsCaptchaNoneMessage => '需要验证码的任务都已经处理完了。';

  @override
  String dsCaptchaBanner(Object count) {
    return '$count 个任务需要输入验证码才能继续';
  }

  @override
  String get dsCaptchaEnter => '输入验证码';

  @override
  String get dsErrWrongCaptcha => '验证码不正确，请重新输入';

  @override
  String get dsErrEmuleEd2kNotConnected => 'eMule 未连接到 ED2K 服务器';

  @override
  String get dsErrEmuleKadNotConnected => 'eMule 未连接到 Kad 网络';

  @override
  String get dsErrListNotFound => '文件清单已过期，请重新添加这个任务';

  @override
  String get photoRecentTitle => '最近添加';

  @override
  String get photoRecentEntry => '按加入时间浏览最近入库的照片与视频';

  @override
  String get photoRecentEmptyTitle => '还没有最近添加的内容';

  @override
  String get photoRecentEmptyMessage => 'NAS 端索引完成后，最近加入的照片会出现在这里。';

  @override
  String get driveWave2FolderItemCount => '包含条目';

  @override
  String get driveWave2FolderItemCountUnavailable => '暂时取不到';

  @override
  String get driveWave2RequestAccess => '申请访问权';

  @override
  String get driveWave2RequestAccessConfirmTitle => '申请访问权';

  @override
  String get driveWave2RequestAccessConfirmMessage => '向该条目的拥有者发送访问权申请？';

  @override
  String get driveWave2RequestAccessCancel => '取消';

  @override
  String get driveWave2RequestAccessConfirm => '发送申请';

  @override
  String get driveWave2RequestAccessSent => '已发送访问权申请';

  @override
  String driveWave2FolderItemCountValue(int count) {
    return '$count 项';
  }

  @override
  String driveWave2RequestAccessFailed(String error) {
    return '申请失败：$error';
  }

  @override
  String get noteN4DeleteGps => '删除 GPS 信息';

  @override
  String get noteN4DeleteGpsMessage => '已成功删除 GPS 信息';

  @override
  String get noteN4Location => '位置';

  @override
  String get noteN4LocationNameHint => '地点名称';

  @override
  String get noteN4LocationPermissionDenied => '没有定位权限，无法获取当前位置';

  @override
  String get noteN4LocationSaved => '位置已保存';

  @override
  String get noteN4LocationUnavailable => '现在取不到当前位置';

  @override
  String get noteN4LocationUnsupported => '当前设备不支持定位';

  @override
  String get noteN4NoSearchResult => '未找到相符项目。';

  @override
  String noteN4SaveFailed(String error) {
    return '操作失败：$error';
  }

  @override
  String get noteN4SearchNeedsCenter => '先设置或获取一个位置，才能搜索附近地点';

  @override
  String get noteN4SearchPlace => '搜索地点';

  @override
  String get noteN4SearchPlaceHint => '搜索地点或地址';

  @override
  String get noteN4Searching => '搜索中…';

  @override
  String get noteN4SetLocation => '设置位置';

  @override
  String get noteN4UseCurrentLocation => '用当前位置';

  @override
  String get noteN4UseThisPlace => '用这条';

  @override
  String get fsTaskClearConfirmFinished => '已完成的任务会被清除。您确定要继续吗？';

  @override
  String get officeSlidesDeckEmpty => '这份演示文稿里没有可显示的幻灯片';

  @override
  String get officeSlidesDeckNotes => '备注';

  @override
  String get officeSlidesDeckNoNotes => '这一页没有备注';

  @override
  String get officeSlidesDeckFullscreen => '全屏放映';

  @override
  String get officeSlidesDeckExitFullscreen => '退出放映';

  @override
  String get officeSlidesDeckInfoTitle => '演示文稿信息';

  @override
  String get officeSlidesDeckVectorNote =>
      'SVG 矢量图已由内置渲染器绘制；EMF / WMF 等格式暂不显示。';

  @override
  String get officeSlidesDeckUnsupported => '这张幻灯片包含暂不支持的对象';

  @override
  String get officeSlidesDeckBlank => '这张幻灯片没有可显示的内容';

  @override
  String get officeSlidesDeckImageFailed => '这张图片没能显示';

  @override
  String get officeSlidesDeckFallbackNote => '这份演示文稿的版式没有读到，下面按文字内容显示。';

  @override
  String officeSlidesDeckInfoSize(String w, String h, String ratio) {
    return '画布 $w×$h（$ratio）';
  }

  @override
  String officeSlidesDeckInfoPages(String n) {
    return '幻灯片 $n 页';
  }

  @override
  String officeSlidesDeckInfoLayouts(String n) {
    return '版式 $n 套';
  }

  @override
  String officeSlidesDeckUnsupportedSummary(String n) {
    return '有 $n 个对象（表格/图表/图示）暂不支持显示。';
  }

  @override
  String get officeSheetEmptyHint => '可以重试打开，或在官方 Synology Drive 应用里查看这个文件。';

  @override
  String get officeSheetFitWidth => '适宽';

  @override
  String get officeSheetZoomOut => '缩小';

  @override
  String get officeSheetZoomIn => '放大';

  @override
  String get officeSheetChart => '图表';

  @override
  String get officeSheetChartUnavailable => '图表内容暂不能显示';

  @override
  String officeSheetRenderTruncated(String rows, String cols) {
    return '只显示前 $rows 行 × $cols 列（表格更大，已按可视范围显示）。';
  }

  @override
  String get officeSheetFallbackNotOoxml =>
      '这个文件不是标准表格格式，已按兼容方式打开，部分版式可能未完全还原。';

  @override
  String get officeSheetFallbackParseFailed =>
      '标准表格版式解析失败，已按兼容方式打开，部分版式可能未完全还原。';

  @override
  String get officeSheetFallbackEmpty => '没有取到文件字节，已按兼容方式打开，部分版式可能未完全还原。';

  @override
  String get noteMailSendToEmail => '发送到邮件';

  @override
  String get noteMailShareOut => '分享到其他应用';

  @override
  String get noteMailUnavailable => '没有可用的邮件应用。';

  @override
  String get driveG4ComputersTitle => '我的电脑';

  @override
  String get driveG4ComputersEntry => '电脑';

  @override
  String get driveG4ComputersEntrySubtitle => '查看登录过同一账号的电脑及其同步文件夹';

  @override
  String get driveG4ComputersEmpty => '还没有已连接的电脑';

  @override
  String get driveG4ComputersEmptyBody =>
      '在电脑上装 Synology Drive 客户端并登录同一账号后，这里就会出现它。';

  @override
  String get driveG4ComputersLoadFailed => '暂时取不到电脑列表';

  @override
  String driveG4ComputersCount(String count) {
    return '共 $count 台';
  }

  @override
  String get driveG4ComputersDevice => '设备';

  @override
  String get driveG4LocalFilesTitle => '本机文件';

  @override
  String get driveG4LocalFilesEntry => '本机文件';

  @override
  String get driveG4LocalFilesEntrySubtitle => '从手机/电脑本地选文件上传到 Drive';

  @override
  String get driveG4LocalFilesEmpty => '这个目录是空的';

  @override
  String get driveG4LocalFilesEmptyBody => '换个目录看看，或用右上角的刷新。';

  @override
  String get driveG4LocalFilesUnavailable => '这台设备上没有可浏览的本机文件';

  @override
  String get driveG4LocalFilesUnavailableBody =>
      '只有 Android 手机可以浏览本机存储；当前平台暂不支持。';

  @override
  String get driveG4LocalFilesUpload => '上传到 Drive';

  @override
  String driveG4LocalFilesUploading(String name) {
    return '正在上传 $name';
  }

  @override
  String driveG4LocalFilesUploaded(String name) {
    return '已上传 $name';
  }

  @override
  String driveG4LocalFilesUploadFailed(String error) {
    return '上传失败：$error';
  }

  @override
  String get driveG4LocalFilesNotConnected => '未连接 NAS，先连上再上传。';

  @override
  String driveG4LocalFilesTarget(String path) {
    return '上传到 $path';
  }

  @override
  String get driveG4ArchiveTitle => '压缩并下载';

  @override
  String get driveG4ArchiveDownload => '打包下载';

  @override
  String get driveG4ArchiveDownloading => '正在打包…';

  @override
  String get driveG4ArchiveNameLabel => '压缩包文件名';

  @override
  String driveG4ArchiveSaveFailed(String error) {
    return '操作失败：$error';
  }

  @override
  String driveG4ArchiveSaved(String name) {
    return '已保存 $name';
  }

  @override
  String get driveG4ArchiveShare => '打包并分享';

  @override
  String driveG4ArchiveShareFailed(String error) {
    return '分享失败：$error';
  }

  @override
  String get driveG4ArchiveNoHandler => '系统没有可接收该分享的应用';

  @override
  String get driveG4ArchiveNoSelection => '先选中要打包的文件';

  @override
  String get driveG4SendCopy => '发送副本';

  @override
  String driveG4SendCopySaved(String name) {
    return '已发送 $name';
  }

  @override
  String get driveG4PasswordVerifyTitle => '这个分享需要密码';

  @override
  String get driveG4PasswordVerifyHint => '输入分享密码';

  @override
  String get driveG4PasswordVerifyAction => '验证';

  @override
  String get driveG4PasswordVerifyOk => '密码正确';

  @override
  String get driveG4PasswordVerifyBad => '密码不对，再试一次';

  @override
  String get driveG4PasswordVerifyEmpty => '先输入密码';

  @override
  String get fsG4ToolsTitle => '文件工具';

  @override
  String get fsG4ToolsSection => '更多';

  @override
  String get fsG4VolumeFirstTitle => '这是分卷压缩包的第 1 卷';

  @override
  String fsG4VolumeFirstBody(String kind) {
    return '$kind：NAS 会自动读取同目录下的其余分卷。';
  }

  @override
  String fsG4VolumeLaterTitle(String n) {
    return '这是第 $n 卷，不能单独解压';
  }

  @override
  String fsG4VolumeLaterBody(String kind, String first) {
    return '$kind：请改选第 1 卷 “$first” 再解压。';
  }

  @override
  String get fsG4VolumeKindRarPart => 'RAR 分卷（.partN.rar）';

  @override
  String get fsG4VolumeKindRarOld => 'RAR 老式分卷（.rNN）';

  @override
  String get fsG4VolumeKindNumeric => '数字分卷（.001/.002…）';

  @override
  String get fsG4VolumeKindZip => 'ZIP 分卷（.z01/.z02…）';

  @override
  String get fsG4UsbTitle => '外接设备';

  @override
  String get fsG4UsbEntry => '查看插在 NAS 上的 U 盘 / 移动硬盘，并安全弹出（需要管理员）';

  @override
  String get fsG4UsbEmpty => '没有检测到 USB 设备';

  @override
  String get fsG4UsbEmptyBody => '把 U 盘或移动硬盘插到 NAS 的 USB 口后，点右上角刷新。';

  @override
  String get fsG4UsbNoDeviceTitle => '服务端没有返回外接设备（404）';

  @override
  String get fsG4UsbNoDeviceBody =>
      '这不代表 NAS 上没有 U 盘：本机实测 U 盘已挂载、「文件」里能看到它时，这个列表仍然回 404。在 DSM 上它通常只对管理员开放——想用盘请直接在「文件」里打开它。';

  @override
  String get fsG4UsbLoadFailed => '暂时取不到外接设备';

  @override
  String get fsG4UsbEject => '安全弹出';

  @override
  String get fsG4UsbEjectConfirmTitle => '安全弹出设备？';

  @override
  String fsG4UsbEjectConfirmBody(String name) {
    return '将停止对 “$name” 的所有读写。正在进行的传输会失败，请先确认没有任务在跑。';
  }

  @override
  String get fsG4UsbEjectDone => '已弹出设备';

  @override
  String fsG4UsbEjectFailed(String error) {
    return '弹出失败：$error';
  }

  @override
  String get fsG4UsbPartition => '分区';

  @override
  String fsG4UsbStatus(String status) {
    return '状态：$status';
  }

  @override
  String fsG4UsbUsedOfTotal(String used, String total) {
    return '已用 $used / 共 $total';
  }

  @override
  String get fsG4OfflineTitle => '离线文件';

  @override
  String get fsG4OfflineEntry => '离线文件';

  @override
  String get fsG4OfflineEntrySubtitle => '你标记为离线可用的文件（会缓存到本机，占用本机空间）';

  @override
  String get fsG4OfflineEmpty => '还没有离线文件';

  @override
  String get fsG4OfflineEmptyBody => '在文件菜单里选「加入离线文件」，之后就能在这里找到它。';

  @override
  String get fsG4OfflinePin => '加入离线文件';

  @override
  String get fsG4OfflineUnpin => '移出离线文件';

  @override
  String get fsG4OfflinePinned => '已加入离线文件，正在缓存到本机…';

  @override
  String get fsG4OfflineUnpinned => '已移出离线文件';

  @override
  String get fsG4OfflineRemove => '移出离线';

  @override
  String get fsG4OfflineOnlyFiles => '只有文件可以加入离线';

  @override
  String fsG4OfflineCount(String count) {
    return '共 $count 项';
  }

  @override
  String fsG4OfflineTotal(String size) {
    return '合计 $size';
  }

  @override
  String fsG4OfflineTotalPartial(String size, String count) {
    return '合计 $size（另有 $count 项大小未知）';
  }

  @override
  String fsG4OfflineCached(String size) {
    return '已缓存到本机（$size）';
  }

  @override
  String fsG4OfflineCacheFailed(String reason) {
    return '已登记，但缓存失败：$reason';
  }

  @override
  String get fsG4OfflineCacheNow => '缓存到本机';

  @override
  String get fsG4OfflineNotCached => '未缓存';

  @override
  String get fsWebDavTitle => 'WebDAV 连接';

  @override
  String get fsWebDavEntry => '用 WebDAV 协议连接 NAS 并浏览目录（只读；官方 DSM 7 起标废弃）';

  @override
  String get fsWebDavEntryDescription =>
      '用 WebDAV 协议连接 NAS（官方 DS file 的另一条传输路径）';

  @override
  String get fsWebDavHost => '主机';

  @override
  String get fsWebDavHostHint => 'NAS 的 IP 或域名';

  @override
  String get fsWebDavPort => '端口';

  @override
  String get fsWebDavAccount => '账号';

  @override
  String get fsWebDavPassword => '密码';

  @override
  String get fsWebDavSecure => 'HTTPS';

  @override
  String get fsWebDavSecureHint => 'https 端口通常是 5006';

  @override
  String get fsWebDavConnect => '连接';

  @override
  String get fsWebDavConnecting => '正在连接…';

  @override
  String get fsWebDavMissingHost => '请填写主机地址（IP 或域名）';

  @override
  String get fsWebDavDeprecated =>
      '官方 DS file 在 DSM 7 起已把 WebDAV 模式标为废弃（WebDavConnectionManager: DEPRECATED_DSM_VERSION = 7）。它仍然能连，但已不是官方支持的路径。';

  @override
  String get fsWebDavReadOnly => 'WebDAV 目前为只读：可以浏览目录、下载文件；上传、新建文件夹、删除、改名暂不支持。';

  @override
  String get fsWebDavEmpty => '这个目录是空的';

  @override
  String get fsWebDavEmptyBody => '服务端连上了，但目录里没有任何条目。';

  @override
  String fsWebDavError(String error) {
    return '连接失败：$error';
  }

  @override
  String fsWebDavCapability(String dav, String allow) {
    return 'DAV：$dav · 支持：$allow';
  }

  @override
  String fsWebDavPath(String path) {
    return '当前位置：$path';
  }

  @override
  String get fsWebDavUp => '上一级';

  @override
  String get fsWebDavNotConnected => '还没连接 NAS，无法预填地址';

  @override
  String get fsWebDavServer => '服务端';

  @override
  String get officeSlidesFallbackPlain => '用文字方式打开';

  @override
  String get photoGridDensity => '缩略图密度';

  @override
  String get photoGridDensityLarge => '大';

  @override
  String get photoGridDensityMedium => '中';

  @override
  String get photoGridDensitySmall => '小';

  @override
  String get photoGridDensityTiny => '密';

  @override
  String photoGridDensityApplied(String label) {
    return '缩略图密度：$label';
  }

  @override
  String get photoHeicPreviewTitle => '这张 HEIC 照片还没有预览';

  @override
  String get photoHeicPreviewBody =>
      'HEIC/HEIF 需要 NAS 的 Image Assistant 转成 JPEG 预览后才能在应用内显示。';

  @override
  String get photoHeicPreviewAction => '让 NAS 生成预览';

  @override
  String get photoHeicPreviewConfirmTitle => '让 NAS 生成预览？';

  @override
  String get photoHeicPreviewConfirmBody => '会在 NAS 上重新生成预览图，可能占用一些时间与算力。';

  @override
  String get photoHeicPreviewRequested => '已请求 NAS 生成预览，稍后回到这里刷新。';

  @override
  String photoHeicPreviewFailed(String reason) {
    return '请求失败：$reason';
  }

  @override
  String photoHeicRegenerating(String count) {
    return 'NAS 正在生成 $count 个预览';
  }

  @override
  String get photoFormatUnsupportedRaw => '这个 RAW/DNG 文件暂时无法在应用内显示';

  @override
  String get photoFormatUnsupportedAvif => '这个 AVIF 文件暂时无法在应用内显示';

  @override
  String get photoFormatUnsupportedGeneric => '这个格式暂时无法在应用内显示，可以下载后用其他应用打开';

  @override
  String get photoFormatUnsupportedBody =>
      '与官方一致：RAW / DNG / AVIF 不在应用内解码；可下载后用其他应用打开，或在 NAS 上启用 Image Assistant。';

  @override
  String get photoFormatUnsupportedBadge => '格式不支持';

  @override
  String get photoSearchHistoryTitle => '最近搜索';

  @override
  String get photoSearchHistoryClear => '清除历史';

  @override
  String get photoSearchHistoryCleared => '已清除搜索历史';

  @override
  String get photoGlobalSearchGroup => '照片';

  @override
  String photoGlobalSearchFailed(String reason) {
    return '照片搜索失败：$reason';
  }

  @override
  String photoGlobalSearchCount(String count) {
    return '$count 张照片';
  }

  @override
  String photoDeleteUndoPending(String seconds, String count) {
    return '将在 $seconds 秒后删除 $count 项';
  }

  @override
  String get photoDeleteUndoAction => '撤销';

  @override
  String get photoDeleteUndone => '已撤销，未删除';

  @override
  String get photoPlaybackSettings => '播放设置';

  @override
  String get photoPlaybackHttp => '用 HTTP 播放';

  @override
  String get photoPlaybackHttpDesc => '自签证书导致视频播不出来时，改用 HTTP 直链取流。';

  @override
  String get photoPlaybackHttpPort => 'HTTP 端口';

  @override
  String get photoPlaybackPortInvalid => '端口不正确（应为 1–65535）';

  @override
  String get photoPlaybackCert => '忽略证书错误';

  @override
  String get photoPlaybackCertDesc => '自签证书时忽略证书校验错误（视频由本应用取流后再播放）。';

  @override
  String get photoSlideshow => '幻灯片';

  @override
  String get photoSlideshowSettings => '幻灯片设置';

  @override
  String get photoSlideshowSpeed => '速度';

  @override
  String get photoSlideshowOrder => '播放顺序';

  @override
  String get photoSlideshowShuffle => '随机';

  @override
  String get photoSlideshowSequential => '顺序';

  @override
  String get photoSlideshowStart => '幻灯片播放';

  @override
  String get photoSlideshowStop => '停止幻灯片';

  @override
  String get photoSlideshowNoPhotos => '这个列表里没有可放映的照片';

  @override
  String photoSlideshowSeconds(String seconds) {
    return '$seconds 秒';
  }

  @override
  String photoSlideshowInterval(String seconds, String order) {
    return '每 $seconds 秒 · $order';
  }

  @override
  String get photoSlideshowStarted => '幻灯片播放中';

  @override
  String get officeViewerSlidesImage => '图片';

  @override
  String get driveG6ConnectionsTitle => '已连接的设备';

  @override
  String get driveG6ConnectionsEntry => '已连接的设备';

  @override
  String get driveG6ConnectionsEntryHint => '查看哪些客户端 / 设备正连着这台 NAS 的 Drive';

  @override
  String get driveG6ConnectionsSubtitle => '正在用 Drive 客户端连着这台 NAS 的设备';

  @override
  String get driveG6ConnectionsEmptyTitle => '当前没有已连接的设备';

  @override
  String get driveG6ConnectionsEmptyBody =>
      '在电脑或手机上用 Synology Drive 客户端登录这台 NAS 后，这里会列出该设备。';

  @override
  String get driveG6ConnectionsLoadFailed => '暂时取不到已连接的设备';

  @override
  String get driveG6ConnectionStatusConnected => '已连接';

  @override
  String get driveG6ConnectionStatusOffline => '离线';

  @override
  String get driveG6ConnectionUnknownDevice => '未知设备';

  @override
  String get driveG6FileRequestDisabled =>
      '这台 NAS 没有开启「文件请求」功能，请在 DSM 的 Drive 管理控制台中启用后重试。';

  @override
  String driveG6ActionFailed(String error) {
    return '操作失败：$error';
  }

  @override
  String get driveG6GenericFailure => '操作失败，请稍后重试';

  @override
  String get photoG6TasksTitle => '后台任务';

  @override
  String get photoG6TasksEntry => '后台任务';

  @override
  String get photoG6TasksEntryHint => '查看相册里正在进行的复制 / 移动等任务';

  @override
  String get photoG6TasksEmptyTitle => '当前没有正在进行的后台任务';

  @override
  String get photoG6TasksEmptyBody => '相册里发起的复制 / 移动等操作会在这里显示进度。';

  @override
  String get photoG6TaskOperationCopy => '复制';

  @override
  String get photoG6TaskOperationMove => '移动';

  @override
  String get photoG6TaskStatusWaiting => '排队中';

  @override
  String get photoG6TaskStatusProcessing => '进行中';

  @override
  String get photoG6TaskStatusAborting => '正在中止';

  @override
  String get photoG6TaskStatusDone => '已完成';

  @override
  String photoG6TaskProgress(String done, String total) {
    return '$done/$total';
  }

  @override
  String photoG6TaskErrors(String count) {
    return '$count 项失败';
  }

  @override
  String get photoG6TaskUnknownType => '相册任务';

  @override
  String get photoG6MigrationTitle => '迁移状态';

  @override
  String get photoG6MigrationEntry => '迁移状态';

  @override
  String get photoG6MigrationEntryHint =>
      'Photo Station / Moments 到 Synology Photos 的迁移进度';

  @override
  String get photoG6MigrationStatusDone => '迁移已完成';

  @override
  String get photoG6MigrationStatusRunning => '正在迁移';

  @override
  String get photoG6MigrationStatusFailed =>
      '迁移失败，请在 DSM 的 Synology Photos 中查看详情';

  @override
  String get photoG6MigrationStatusUnknown => '暂时读不到迁移状态，请稍后重试';

  @override
  String get photoG6MigrationStagePhotoStation => '正在迁移 Photo Station 的照片';

  @override
  String get photoG6MigrationStageMomentsPersonal => '正在迁移 Moments 的个人照片';

  @override
  String get photoG6MigrationStageBoth => '正在迁移 Photo Station 与 Moments 的照片';

  @override
  String photoG6MigrationProgress(String current, String total) {
    return '第 $current / $total 步';
  }

  @override
  String get photoG6MigrationIdleTitle => '当前没有正在进行的迁移';

  @override
  String get photoG6MigrationIdleBody =>
      'Photo Station / Moments 的照片迁移完成后，这里会显示结果。';

  @override
  String get photoFreeUpTitle => '释放手机空间';

  @override
  String get photoFreeUpEntry => '释放手机空间';

  @override
  String get photoFreeUpEntryHint => '删掉已备份到 NAS 的本地照片，腾出手机存储；没备份的一张都不会动';

  @override
  String get photoFreeUpExplainTitle => '只删除已备份的照片';

  @override
  String get photoFreeUpExplainBody =>
      '我们会逐张核对：只有 NAS 上已经备份过的照片才会进入可删除列表，没备份的照片一律保留。删除前系统会弹出确认框，你也可以随时取消；NAS 上的备份不受影响。';

  @override
  String photoFreeUpReclaimable(String size) {
    return '可释放 $size';
  }

  @override
  String photoFreeUpCounts(String backedUp, String kept) {
    return '已备份 $backedUp 张 · 未备份 $kept 张不会删除';
  }

  @override
  String get photoFreeUpRescan => '重新核对';

  @override
  String get photoFreeUpScanning => '正在核对本机照片与 NAS 备份…';

  @override
  String photoFreeUpProgress(String done, String total) {
    return '已处理 $done/$total';
  }

  @override
  String get photoFreeUpStart => '释放空间';

  @override
  String get photoFreeUpCancelled => '已取消，没有删除任何照片';

  @override
  String photoFreeUpDeleted(String size, String count) {
    return '已释放 $size（$count 张）';
  }

  @override
  String photoFreeUpDeletedSomeFailed(String count) {
    return '有 $count 张没能删除，其余已释放';
  }

  @override
  String get photoFreeUpFailed => '删除没有完成，一张都没有删掉，请稍后重试';

  @override
  String get photoFreeUpNothingToFree => '当前没有可释放的照片';

  @override
  String get photoFreeUpCacheCleared => '应用上传时留下的临时文件已清理';

  @override
  String get photoFreeUpNoPermissionTitle => '读不到本机照片，无法核对备份';

  @override
  String get photoFreeUpNotConnected => '还没连接 NAS，无法核对哪些照片已经备份；请先连接后重新核对';

  @override
  String get photoFreeUpNoTarget => '还没设置备份目标，只能依据本机备份记录判断';

  @override
  String get photoFreeUpNothingTitle => '没有可释放的照片';

  @override
  String get photoFreeUpNothingBody => '本机照片都还没有备份，或已经核对完毕、没有多余的本地副本。';

  @override
  String get photoFreeUpUnsupportedTitle => '这台设备不能由应用删除照片';

  @override
  String get photoFreeUpUnsupportedBody =>
      '当前环境没有可用的删除能力。你可以到系统设置里手动清理；NAS 上的备份都还在，什么都没被删除。';

  @override
  String get photoFreeUpSettingsOnlyTitle => '这台设备需要你手动清理';

  @override
  String get photoFreeUpSettingsOnlyBody =>
      '当前系统不支持由应用发起删除确认。请到系统设置的应用存储里手动清理，或在系统相册里手动删除上面列出的照片；NAS 上的备份都还在。';

  @override
  String get photoFreeUpOpenSettings => '去系统设置手动清理';

  @override
  String get photoFreeUpSettingsFailed => '没能打开系统设置，请手动进入「设置 → 应用 → 存储」清理';

  @override
  String get photoFreeUpItemReasonLedger => '已备份（本机备份记录）';

  @override
  String get photoFreeUpItemReasonRemote => '已备份（NAS 上已有同名文件）';

  @override
  String get photoFreeUpItemStatePending => '待删除';

  @override
  String get photoFreeUpItemStateDeleted => '已删除';

  @override
  String get photoFreeUpItemStateKept => '已保留';

  @override
  String get widgetPlaceholderNotLoggedIn => '打开 App 登录后，这里会显示最近的照片、笔记和待办';

  @override
  String get widgetPlaceholderNotConnected => '还没连接 NAS，连接后这里会显示内容';

  @override
  String get widgetPlaceholderNoPhotos => '相册里还没有照片';

  @override
  String get widgetPlaceholderNoNotes => '还没有笔记，点一下就能新建';

  @override
  String get widgetPlaceholderNoTodos => '没有未完成的待办';

  @override
  String get widgetTodosTitle => '待办';

  @override
  String get widgetNewNote => '新建笔记';

  @override
  String get noteAdvSearchEntry => '高级搜索';

  @override
  String get noteAdvSearchTitle => '高级搜索';

  @override
  String get noteAdvSearchKeyword => '关键词';

  @override
  String get noteAdvSearchKeywordHint => '在标题、正文和附件文字里查找';

  @override
  String get noteAdvSearchTitleLabel => '标题包含';

  @override
  String get noteAdvSearchTitleHint => '例如：周报';

  @override
  String get noteAdvSearchTags => '标签';

  @override
  String get noteAdvSearchTagsAny => '不限';

  @override
  String get noteAdvSearchTagAnd => '同时包含所选标签';

  @override
  String get noteAdvSearchTagOr => '包含任一标签';

  @override
  String get noteAdvSearchIncludeSubTags => '包含子标签';

  @override
  String get noteAdvSearchIncludeSubTagsHint => '关闭后只显示恰好带有所选标签的笔记';

  @override
  String get noteAdvSearchExcludeTags => '排除标签';

  @override
  String get noteAdvSearchExcludeTagsHint => '被排除的标签连同它的子标签一起排除';

  @override
  String get noteAdvSearchNotebooks => '笔记本';

  @override
  String get noteAdvSearchNotebooksAny => '全部笔记本';

  @override
  String get noteAdvSearchTimeModified => '修改时间';

  @override
  String get noteAdvSearchTimeCreated => '创建时间';

  @override
  String get noteAdvSearchDateFrom => '起始日期';

  @override
  String get noteAdvSearchDateTo => '结束日期';

  @override
  String get noteAdvSearchDateInvalid => '起始日期不能晚于结束日期';

  @override
  String get noteAdvSearchRun => '搜索';

  @override
  String get noteAdvSearchClear => '清空条件';

  @override
  String get noteAdvSearchPrompt => '设置条件后开始搜索';

  @override
  String get noteAdvSearchPromptHint => '至少设置一个条件';

  @override
  String get noteAdvSearchEmpty => '没有符合条件的笔记';

  @override
  String get noteAdvSearchEmptyHint => '换个关键词或放宽条件试试';

  @override
  String get noteAdvSearchFailed => '搜索失败';

  @override
  String noteAdvSearchSelectedCount(Object count) {
    return '已选 $count 个';
  }

  @override
  String noteAdvSearchResultsCount(Object count) {
    return '$count 条结果';
  }

  @override
  String get driveD8CollectionTitle => '收藏集';

  @override
  String get driveD8CollectionEmptyTitle => '还没有收藏集';

  @override
  String driveD8CollectionCount(String count) {
    return '$count 个收藏集';
  }

  @override
  String get driveD8CollectionLoadFailed => '暂时取不到收藏集';

  @override
  String get driveD8CollectionEmptyBody =>
      '收藏集能把散在不同目录的文件聚在一起（照片 / 文档 / 音乐 / 视频四类）。';

  @override
  String get driveD8CollectionCreate => '新建收藏集';

  @override
  String driveD8CollectionCreated(String name) {
    return '已新建「$name」';
  }

  @override
  String driveD8CollectionActionFailed(String error) {
    return '操作失败：$error';
  }

  @override
  String get driveD8CollectionAll => '全部';

  @override
  String get driveD8CollectionRename => '重命名 / 改颜色';

  @override
  String get driveD8CollectionDelete => '删除收藏集';

  @override
  String driveD8CollectionRenamed(String name) {
    return '已改名为「$name」';
  }

  @override
  String get driveD8CollectionDeleteConfirm => '删除这个收藏集？';

  @override
  String driveD8CollectionDeleteBody(String name) {
    return '「$name」会被删除；里面的文件本身不会被删除。';
  }

  @override
  String get driveD8CollectionDeleted => '收藏集已删除';

  @override
  String get driveD8CollectionFilesLoadFailed => '暂时取不到收藏集里的文件';

  @override
  String get driveD8CollectionFilesEmptyTitle => '这个收藏集还是空的';

  @override
  String get driveD8CollectionFilesEmptyBody => '在文件列表里选择「加入收藏集」把文件放进来。';

  @override
  String get driveD8CollectionRemoveFromCollection => '移出收藏集';

  @override
  String get driveD8CollectionRemoveConfirm => '移出这个收藏集？';

  @override
  String driveD8CollectionRemoveBody(String name) {
    return '「$name」会从收藏集里移出；文件本身不会被删除。';
  }

  @override
  String get driveD8CollectionRemoved => '已移出收藏集';

  @override
  String get driveD8CollectionRenameTitle => '重命名收藏集';

  @override
  String get driveD8CollectionCreateTitle => '新建收藏集';

  @override
  String get driveD8CollectionNameHint => '收藏集名字';

  @override
  String get driveD8CollectionTypePhoto => '照片收藏集';

  @override
  String get driveD8CollectionTypeDocument => '文档收藏集';

  @override
  String get driveD8CollectionTypeAudio => '音乐收藏集';

  @override
  String get driveD8CollectionTypeVideo => '视频收藏集';

  @override
  String get driveD8CollectionEntry => '收藏集';

  @override
  String get driveD8CollectionEntryHint => '把散在不同目录的文件聚成照片 / 文档 / 音乐 / 视频四类收藏集';

  @override
  String get driveD12TeamTrashEntry => '团队文件夹回收站';

  @override
  String get driveD12TeamTrashPickFolder => '选一个团队文件夹，查看并还原里面误删的文件';

  @override
  String get driveD12TeamTrashTitle => '团队文件夹回收站';

  @override
  String get driveD12TeamTrashNoTeamFolders => '没有团队文件夹';

  @override
  String driveD12TeamTrashCount(String count) {
    return '$count 个团队文件夹';
  }

  @override
  String get driveD12TeamTrashLoadFailed => '暂时取不到团队文件夹';

  @override
  String get driveD12TeamTrashNoTeamFoldersBody =>
      '这个账号还没有可用的团队文件夹，所以没有团队文件夹回收站可看。';

  @override
  String get driveD12TeamTrashEmptyTitle => '回收站是空的';

  @override
  String driveD12TeamTrashItemCount(String count) {
    return '$count 个已删除项';
  }

  @override
  String get driveD12TeamTrashNoEmptyAction =>
      '团队文件夹回收站不支持\"清空\"（与官方一致）；可以逐条还原或彻底删除。';

  @override
  String get driveD12TeamTrashEmptyBody => '这个团队文件夹里没有被删除的文件。';

  @override
  String get driveD8CollectionAddToCollection => '加入收藏集';

  @override
  String get photoMediaLiveBadge => '实况照片';

  @override
  String get photoMediaMotionBadge => '动态照片';

  @override
  String get photoMediaLivePlayTooltip => '播放实况短视频';

  @override
  String get photoMediaLiveStopTooltip => '停止实况播放';

  @override
  String get photoMediaLiveUnavailable => '这段实况短视频不可用（服务端没有给出可播放的视频）。';

  @override
  String get photoMediaPanoPhotoHint => '点按并拖动查看 360 照片。';

  @override
  String get photoMediaPanoPhotoFailed => '无法载入 360 照片。';

  @override
  String get photoMediaPanoResetView => '回到初始视角';

  @override
  String get photoMediaPanoVideoFlatNotice =>
      '这是 360 全景视频。本版播放器暂不支持球面视角（只能按普通平面视频播放）。';

  @override
  String get photoMediaEditDateTitle => '编辑日期时间';

  @override
  String get photoMediaEditDateMenuAction => '编辑日期时间';

  @override
  String get photoMediaEditDateAction => '保存';

  @override
  String get photoMediaEditDateField => '日期';

  @override
  String get photoMediaEditTimeField => '时间';

  @override
  String get photoMediaEditDateConfirmTitle => '修改拍摄时间？';

  @override
  String photoMediaEditDateConfirmBody(String from, String to) {
    return '这会把这张照片的拍摄时间从 $from 改为 $to。原文件不会被重新编码，但相册里的时间轴与排序会随之变化。';
  }

  @override
  String get photoMediaEditDateSaved => '已修改拍摄时间。';

  @override
  String photoMediaEditDateFailed(String error) {
    return '修改拍摄时间失败：$error';
  }

  @override
  String get photoMediaEditDateInvalid => '时间没有变化 —— 请先改日期或时刻。';

  @override
  String get loginGuestMode => '以访客身份登录';

  @override
  String get loginGuestEmailLabel => '访客邮箱';

  @override
  String get loginGuestQuerying => '正在查询访客账号…';

  @override
  String loginGuestFound(Object name) {
    return '访客账号：$name';
  }

  @override
  String get loginGuestNotFound => '未找到该邮箱对应的访客账号';

  @override
  String get loginGuestHint => '访客登录需先在 NAS 上开启访客访问权限';

  @override
  String get driveScanTitle => '扫描件';

  @override
  String get driveScanCapture => '拍一页';

  @override
  String get driveScanDone => '生成 PDF 并上传';

  @override
  String driveScanPages(Object n) {
    return '已拍 $n 页';
  }

  @override
  String driveScanSaved(Object name) {
    return '已上传扫描件：$name';
  }

  @override
  String get driveScanUploadFailed => '扫描件上传失败';

  @override
  String get driveScanNeedPage => '先至少拍一页';

  @override
  String get aiVaultBadge => '已存离线缓存 · 复用免下载';

  @override
  String get aiVaultReused => '用的是本机离线缓存，没走网络';

  @override
  String get aiVaultPurge => '清空离线缓存';

  @override
  String aiVaultPurged(String size) {
    return '已释放 $size';
  }

  @override
  String get aiVaultHint =>
      '端侧模型会另存一份在本机：App 里删掉模型、覆盖安装新版本都不用重新下载。卸载 App 会清空这份副本 —— 装回后用电脑上的备份恢复即可，同样不用重下。';

  @override
  String aiVaultLocation(String path) {
    return '缓存位置：$path';
  }

  @override
  String get aiDeviceCapabilityTitle => '本机能力';

  @override
  String get aiDeviceCapabilityHint => '端侧模型按本机算力推荐：换了手机，这里看到的模型也会不同。';

  @override
  String get aiDeviceTierLabel => '算力档位';

  @override
  String get aiDeviceTierUnsupported => '不适用';

  @override
  String get aiDeviceTierEntry => '入门';

  @override
  String get aiDeviceTierMainstream => '主流';

  @override
  String get aiDeviceHostUnknown => '桌面宿主：这里不探测手机硬件，端侧档位只在 Android/iOS 上判定';

  @override
  String get aiDeviceSyntheticProfile => '★ 本机能力＝合成画像（QA 诊断下发，不是真实硬件）';

  @override
  String get aiDeviceProbeUnknown => '本机硬件信息读取失败：该平台没有提供硬件接口，因此无法判断是否支持端侧模型。';

  @override
  String get aiDeviceTierHigh => '高端';

  @override
  String get aiDeviceTierFlagship => '旗舰';

  @override
  String get aiDeviceSocLabel => '处理器';

  @override
  String get aiDeviceRamLabel => '内存';

  @override
  String get aiDeviceStorageLabel => '可用存储';

  @override
  String get aiDeviceGpuLabel => 'GPU';

  @override
  String get aiDeviceGpuNone => '未检测到 OpenCL，按 CPU 门槛判断';

  @override
  String get aiDeviceNpuLabel => 'NPU';

  @override
  String get aiDeviceNpuNone => '无 NNAPI';

  @override
  String get aiDeviceNpuNnapi => '有 NNAPI';

  @override
  String get aiDeviceNpuVendor => '厂商 NPU（已知可用）';

  @override
  String get aiDeviceModuleHidden => '端侧大模型已在本机隐藏';

  @override
  String aiDeviceModuleHiddenBody(String reason) {
    return '本机硬件不满足端侧大模型的最低要求（$reason），端侧档位与模型目录已隐藏；云端模型与内置摘要不受影响。';
  }

  @override
  String get aiDeviceVetoLowRam => '系统判定为低内存设备';

  @override
  String aiDeviceVetoCores(int n) {
    return 'CPU 核心太少（$n 核）';
  }

  @override
  String get aiDeviceVetoAbi => '不是 arm64 设备';

  @override
  String aiDeviceVetoRam(String gb) {
    return '内存 $gb GB，低于端侧模型最低要求';
  }

  @override
  String aiBlockedModelsTitle(int n) {
    return '本机不适用的模型（$n）';
  }

  @override
  String aiBlockedReasonRam(String need, String have) {
    return '内存不足（需 $need GB，本机 $have GB）';
  }

  @override
  String get aiBlockedReasonTier => '机器档位不足';

  @override
  String aiBlockedReasonStorage(String need, String have) {
    return '存储空间不足（需 $need，可用 $have）';
  }

  @override
  String get aiBlockedReasonNpu => '需要本机没有的厂商 NPU';

  @override
  String get aiBlockedReasonModuleHidden => '端侧模块已隐藏';

  @override
  String get aiDeviceModelBlocked => '本机硬件不满足该模型要求，已取消';

  @override
  String get apiObjectIdRequired => '缺少文件标识，操作无法继续';

  @override
  String get apiTemplateMakeNeedsIds => '从模板新建时缺少目标位置信息，请回到目标文件夹再试';

  @override
  String get asAlphaAll => '全部';

  @override
  String asBatchRatingSet(Object count) {
    return '已为 $count 首设置评分';
  }

  @override
  String get asCastConnect => '连接';

  @override
  String get asCastConnectFailed => '连接失败';

  @override
  String get asCastCurrent => '投送当前曲目';

  @override
  String get asCastDisconnect => '断开连接';

  @override
  String get asCastPlayFailed => '投送失败';

  @override
  String get asCastTitle => '投送到 Chromecast';

  @override
  String get asCastUnsupported => '本机不支持 Chromecast';

  @override
  String get asCastUnsupportedHint => '需要设备具备 Google Play 服务与 Cast 能力。';

  @override
  String asDaysAgo(Object n) {
    return '$n 天前';
  }

  @override
  String get asDownload => '下载';

  @override
  String get asDownloadDisabled => '服务端未开启下载，请在 NAS 上的下载套件里开启后重试';

  @override
  String get asDownloadFailed => '下载失败：无法写入本地';

  @override
  String get asDownloadNoContent => '服务端没有返回下载内容';

  @override
  String asDownloadOk(Object n) {
    return '已下载 $n 字节到本机';
  }

  @override
  String get asDownloadedLocal => '已下载到本机';

  @override
  String get asEqEnable => '启用均衡器';

  @override
  String get asEqGaplessHint => '开启均衡器会影响无缝播放';

  @override
  String get asEqUnsupported => '均衡器当前不可用';

  @override
  String get asEqUnsupportedHint => '需要正在播放音频时才能调节（效果挂在当前播放会话上）。';

  @override
  String get asEqNoPresets =>
      '本机原生均衡器只暴露开关：平台没有给出预设名，所以这里没有预设列表；开/关立即作用于当前播放输出。';

  @override
  String get asEqualizer => '均衡器';

  @override
  String asHoursAgo(Object n) {
    return '$n 小时前';
  }

  @override
  String get asJustNow => '刚刚';

  @override
  String get asLibraryAll => '全部（默认）';

  @override
  String get asLibraryPersonal => '个人音乐库';

  @override
  String get asLibraryShared => '共享音乐库';

  @override
  String get asLibrarySwitch => '音乐库';

  @override
  String asMinutesAgo(Object n) {
    return '$n 分钟前';
  }

  @override
  String get asMoreLists => '更多列表';

  @override
  String get asMostPlayed => '最常播放';

  @override
  String get asMostPlayedEmpty => '还没有播放记录';

  @override
  String get asNewPlaylist => '新建播放列表';

  @override
  String get asOnlineTag => '在线标签';

  @override
  String asPlayCount(Object count) {
    return '播放 $count 次';
  }

  @override
  String get asPlaylistCreated => '已新建播放列表';

  @override
  String asPlaylistDeleteBody(Object name) {
    return '确定删除「$name」？';
  }

  @override
  String get asPlaylistDeleteTitle => '删除播放列表';

  @override
  String get asRadioAdd => '新建电台';

  @override
  String get asRadioBatchDelete => '删除所选';

  @override
  String asRadioBatchDeleteBody(Object count) {
    return '确定删除所选的 $count 个电台？此操作不可撤销。';
  }

  @override
  String asRadioBatchDeleted(Object count) {
    return '已删除 $count 个电台';
  }

  @override
  String get asRadioNameRequired => '请填写电台名称';

  @override
  String get asRadioSelectAll => '全选';

  @override
  String get asRadioSelectMode => '多选';

  @override
  String get asRadioSelectNone => '取消全选';

  @override
  String asRadioSelectionCount(Object count) {
    return '已选 $count';
  }

  @override
  String get asRadioBatchDeleteTitle => '删除所选电台';

  @override
  String get asRadioUrlRequired => '请填写电台地址（URL）';

  @override
  String get asRadioDeleteTitle => '删除电台';

  @override
  String get asRadioEdit => '编辑';

  @override
  String get asRadioFavAdded => '已加入收藏';

  @override
  String get asRadioFavAdd => '加入收藏';

  @override
  String get asRadioFavRemove => '取消收藏';

  @override
  String get asRandom100 => '随机 100 首';

  @override
  String get asRandom100Failed => '随机列表加载失败';

  @override
  String get asRandom100Refresh => '换一批';

  @override
  String get asRatingClear => '清除评分';

  @override
  String get asRecentlyAdded => '最近添加';

  @override
  String get asRecentlyAddedEmpty => '还没有最近添加的专辑';

  @override
  String get asRecentlyAddedFailed => '最近添加加载失败';

  @override
  String get asRecentlyPlayed => '最近播放';

  @override
  String get asRecentlyPlayedEmpty => '还没有播放记录';

  @override
  String get asRemoteEmpty => '没有发现远程播放器';

  @override
  String get asRemoteEmptyHint => 'NAS 没有发现可控制的播放设备（DLNA/UPnP 渲染器等）。';

  @override
  String get asRemoteNoPrivilege => '此账号没有远程播放权限';

  @override
  String get asRemoteNoPrivilegeHint =>
      '本账号在 Audio Station 里没有「远程播放」权限（由 DSM 管理员分配），因此服务端不返回任何播放设备。';

  @override
  String get asRemoteUpnpDisabled => '服务端已关闭 DLNA / UPnP';

  @override
  String get asRemoteUpnpDisabledHint =>
      'NAS 上的 Audio Station 关掉了 UPnP／DLNA（设置 → 高级 → DLNA），所以它不会去发现播放设备 —— 与手机端无关。';

  @override
  String get asRemoteLoadFailed => '远程播放器加载失败';

  @override
  String get asRemoteNoCurrent => '本机当前没有正在播放的曲目';

  @override
  String get asRemotePushCurrent => '把当前曲目推到该设备';

  @override
  String get asRemoteTitle => '远程播放器';

  @override
  String get asRemoteTypeBt => '蓝牙';

  @override
  String get asRemoteUnnamed => '未命名播放器';

  @override
  String get asSelectionCancel => '退出多选';

  @override
  String asSelectionCount(Object count) {
    return '已选 $count 首';
  }

  @override
  String get asShare => '分享';

  @override
  String get asShareDisable => '关闭共享';

  @override
  String get asShareEnable => '开启共享';

  @override
  String get asShareNoPrivilege => '服务端未开启共享，请在 NAS 上开启后重试';

  @override
  String get asShareNone => '这首歌还没有共享链接';

  @override
  String get asShowInFiles => '在 File Station 中显示';

  @override
  String get asSleepTimer => '睡眠定时';

  @override
  String get asSleepTimerCancel => '取消';

  @override
  String get asSleepTimerOff => '关闭定时';

  @override
  String get asSleepTimerDone => '睡眠定时到点，已暂停播放';

  @override
  String asSleepTimerMinutes(Object m) {
    return '$m 分钟';
  }

  @override
  String asSleepTimerRemaining(Object left) {
    return '睡眠定时 · $left';
  }

  @override
  String get asSleepTimerSet => '设置睡眠定时';

  @override
  String get asSmartRulesMissing => '智能列表规则获取失败，未改名';

  @override
  String get asSongMenu => '更多';

  @override
  String get asTagEmpty => '没有查到在线标签';

  @override
  String asTagFailed(Object e) {
    return '在线标签查询失败：$e';
  }

  @override
  String get asTagHint => '联网查询该专辑的标签信息（Discogs）';

  @override
  String get asTagQuery => '查询';

  @override
  String get asTagRefresh => '重新查询';

  @override
  String get audioLyricsBadResponse => '歌词返回的数据看不懂（歌词源可能改版了）';

  @override
  String audioLyricsSourceLine(Object x) {
    return '歌词来源：$x';
  }

  @override
  String get audioLyricsSourceNas => 'NAS 歌词库';

  @override
  String get audioLyricsSourcePublic => 'lrclib.net 公开歌词库';

  @override
  String get audioLyricsCached => '已用本地缓存';

  @override
  String get audioLyricsNotFound => '没有找到这首歌的歌词';

  @override
  String get audioLyricsOffline => '网络不可用，无法联网搜歌词';

  @override
  String get audioLyricsPick => '换一个歌词版本';

  @override
  String get audioLyricsPlain => '这份歌词不会自动滚动（只显示，可手动滑）';

  @override
  String get audioLyricsJumpToActive => '回到正在唱的那句';

  @override
  String get audioLyricsRetry => '重试';

  @override
  String get audioLyricsSearchHint => '搜歌词';

  @override
  String get audioLyricsServer => '歌词服务返回错误，稍后可重试';

  @override
  String get audioLyricsTimeout => '歌词服务响应超时';

  @override
  String get audioVisualizerCaption => '律动动效';

  @override
  String get audioVisualizerCaptionSpectrum => '真实频谱（来自本机播放输出）';

  @override
  String get cancel => '取消';

  @override
  String get chatActionStickThread => '话题内置顶';

  @override
  String get chatActionUnstickThread => '取消话题内置顶';

  @override
  String get chatStickFailed => '话题内置顶失败，请重试。';

  @override
  String get chatStickUnsupported => '服务端未开启话题内置顶';

  @override
  String get delete => '删除';

  @override
  String get dsBack => '返回';

  @override
  String get dsBrowserAdd => '添加到下载';

  @override
  String get dsBrowserAdded => '已添加到下载任务';

  @override
  String get dsBrowserFound => '发现下载链接';

  @override
  String get dsBrowserGo => '打开';

  @override
  String get dsBrowserTitle => '下载链接浏览器';

  @override
  String get dsBrowserUrl => '网址';

  @override
  String get dsBtCatAll => '全部分类';

  @override
  String get dsBtSort => '排序';

  @override
  String get dsBtSortDate => '按日期';

  @override
  String get dsBtSortDefault => '默认顺序';

  @override
  String get dsBtSortSeeds => '按做种数';

  @override
  String get dsBtSortSize => '按大小';

  @override
  String get dsBtSortTitle => '按名称';

  @override
  String get dsCancel => '取消';

  @override
  String get dsCapBtPreview => 'BT 预览';

  @override
  String get dsCapEmule => 'eMule';

  @override
  String get dsCapUnzip => '自动解压';

  @override
  String get dsCapUnzipService => '解压服务';

  @override
  String get dsCatActive => '进行中';

  @override
  String dsCreateOptionsFailed(Object msg) {
    return '任务已创建，但选项未生效：$msg';
  }

  @override
  String get dsCreateOptionsNotApplied => '任务已创建，但「立即开始/限速」未能应用（列表尚未刷新）';

  @override
  String get dsDelete => '删除';

  @override
  String get dsDestinationHint => '例如 /volume1/downloads';

  @override
  String dsDestinationSaveFailed(Object msg) {
    return '修改失败：$msg';
  }

  @override
  String get dsDestinationSaved => '下载目的地已修改';

  @override
  String get dsEditDestination => '修改下载目的地';

  @override
  String get dsEmuleAddServer => '添加服务器';

  @override
  String get dsEmuleAdded => '已创建下载任务';

  @override
  String get dsEmuleConnect => '连接';

  @override
  String get dsEmuleConnectKad => '连接 Kad';

  @override
  String get dsEmuleDeleteSelected => '删除选中';

  @override
  String get dsEmuleDisconnect => '断开全部';

  @override
  String get dsEmuleDownloadN => '下载选中';

  @override
  String get dsEmuleDownloads => 'eMule 下载任务';

  @override
  String get dsEmuleEmpty => '没有 eMule 任务。';

  @override
  String get dsEmuleExtension => '扩展名';

  @override
  String get dsEmuleFileType => '文件类型';

  @override
  String get dsEmuleKeyword => '关键字';

  @override
  String get dsEmuleMaxSize => '最大大小(MB)';

  @override
  String get dsEmuleMethod => '搜索方式';

  @override
  String get dsEmuleMinSize => '最小大小(MB)';

  @override
  String get dsEmuleMinSource => '最小来源数';

  @override
  String get dsEmuleNoResult => '没有找到结果';

  @override
  String get dsEmuleNoServer => '还没有 eMule 服务器。';

  @override
  String get dsEmuleSearch => 'eMule 搜索';

  @override
  String get dsEmuleServerIp => 'IP / 主机名';

  @override
  String get dsEmuleServerName => '名称（可选）';

  @override
  String get dsEmuleServerPort => '端口';

  @override
  String get dsEmuleServerRequired => '请填写 IP 与端口';

  @override
  String get dsEmuleServers => 'eMule 服务器';

  @override
  String get dsEmuleTitle => 'eMule';

  @override
  String get dsEmuleUnnamed => '（未命名文件）';

  @override
  String get dsEmuleUploads => 'eMule 上传';

  @override
  String get dsEmuleUploadsEmpty => '当前没有上传。';

  @override
  String get dsFileCopied => '已开始复制文件';

  @override
  String dsFileCopyFailed(Object msg) {
    return '复制失败：$msg';
  }

  @override
  String get dsFileCopyTo => '复制到…';

  @override
  String dsFileOptionFailed(Object msg) {
    return '操作失败：$msg';
  }

  @override
  String get dsFileOptionSaved => '已提交';

  @override
  String get dsFilePriority => '优先级';

  @override
  String get dsFileSkip => '跳过';

  @override
  String get dsFileUnskip => '恢复下载';

  @override
  String get dsLoading => '加载中…';

  @override
  String get dsMaxDownloadRate => '下载限速 (KB/s)';

  @override
  String get dsMaxUploadRate => '上传限速 (KB/s)';

  @override
  String get dsModules => '模块';

  @override
  String get dsNotify => '任务完成提醒';

  @override
  String get dsNotifyComplete => '任务完成时提醒';

  @override
  String get dsNotifyCompleteHint => '任务下载完成或失败时在应用内提示（服务端没有完成事件推送，由客户端轮询检测）';

  @override
  String dsNotifyFailed(Object name) {
    return '下载失败：$name';
  }

  @override
  String dsNotifyFinished(Object name) {
    return '下载完成：$name';
  }

  @override
  String get dsNzbFileEmpty => '没有 NZB 文件信息';

  @override
  String get dsNzbFiles => 'NZB 文件列表';

  @override
  String dsNzbFilesTotal(Object n) {
    return '共 $n 个文件';
  }

  @override
  String get dsNzbLog => 'NZB 日志';

  @override
  String get dsNzbLogEmpty => '暂无 NZB 日志';

  @override
  String get dsNzbUnavailable => '这个任务没有可用的 NZB 信息';

  @override
  String get dsPackageInfo => 'Download Station 套件信息';

  @override
  String get dsRssEditFeed => '编辑订阅';

  @override
  String get dsRssFeedSaved => '订阅已更新';

  @override
  String get dsRssTitleLabel => '名称';

  @override
  String get dsSave => '保存';

  @override
  String get dsStartImmediately => '立即开始下载';

  @override
  String get dsStartImmediatelyHint => '关闭则创建后加入队列（暂停）';

  @override
  String get dsVersion => '版本';

  @override
  String get dsVersionUnknown => '版本未知';

  @override
  String get dtoNotifBackgroundTask => '后台任务';

  @override
  String get dtoNotifComment => '评论';

  @override
  String get dtoNotifCommentReply => '评论回复';

  @override
  String get dtoNotifLabelOwnerTransfer => '标签所有者转移';

  @override
  String get dtoNotifMention => '@提到';

  @override
  String get dtoNotifRequest => '访问请求';

  @override
  String get dtoNotifRequestOfficeTemplate => 'Office 模板请求';

  @override
  String get dtoNotifRequestUnlock => '解锁请求';

  @override
  String get dtoNotifShareWithMe => '分享给我';

  @override
  String get dtoNotifSharedLabel => '共享标签';

  @override
  String get dtoShortcutUntitled => '未命名';

  @override
  String get dtoSmartUntitled => '未命名智能笔记本';

  @override
  String get noteConflictKeepBoth => '两个都保留';

  @override
  String noteConflictKeepBothFailed(Object error) {
    return '保留副本失败：$error';
  }

  @override
  String get noteConflictKeptBoth => '两边都保留了';

  @override
  String get noteConflictSuffix => 'Conflict';

  @override
  String get noteStorageExternal => '外置存储（应用专属目录）';

  @override
  String get noteStorageExternalShort => '外置';

  @override
  String get noteStorageInternal => '内部存储（应用私有）';

  @override
  String get noteStorageTitle => '存储位置（附件/离线数据）';

  @override
  String get noteThemeTitle => '主题';

  @override
  String get officeDocTocTitle => '目录';

  @override
  String get officeTemplateLibraryEncryptedTitle => '从模板新建（加密）';

  @override
  String get rename => '重命名';

  @override
  String get widgetNotebooksTitle => '笔记本';

  @override
  String get widgetPlaceholderNoNotebooks => '还没有笔记本';

  @override
  String get ok => '好';

  @override
  String get asSleepTimerCancelLong => '取消睡眠定时';

  @override
  String get audioLyricsInstrumental => '♪';

  @override
  String get audioLyricsLoading => '正在搜索歌词…';

  @override
  String get audioLyricsNoTimeline => '不会自动滚动';

  @override
  String get audioLyricsNotLoaded => '还没有这首歌的歌词';

  @override
  String get audioUpNext => '接下来播放';

  @override
  String get audioPrevious => '上一首';

  @override
  String get audioNext => '下一首';

  @override
  String get audioRepeatOne => '单曲循环';

  @override
  String get carddavAccountLoadFailed => '账号信息读取失败';

  @override
  String get carddavSourcesLoadFailed => '外部源加载失败';

  @override
  String get contactShareeEveryone => '所有人';

  @override
  String get contactGroupsLoadFailed => '分组加载失败';

  @override
  String get contactMembersLoadFailed => '成员加载失败';

  @override
  String get contactOuLoadFailed => '组织单位加载失败';

  @override
  String get mediaSubtitleSourceGestdownNote =>
      '免密钥；只覆盖剧集（文件名需含 S01E02 这类季集），实测语言以英/法为主';

  @override
  String get mediaSubtitleSourceOpenSubtitlesNote =>
      '免密钥可用（匿名有配额）；填 API Key 后更稳、语言更全';

  @override
  String get mediaSubtitleSourceOpenSubtitlesRestNote =>
      '免密钥；中文简体/繁体/双语都能搜到（按片名匹配，不支持哈希匹配）';

  @override
  String mediaSubtitleRestHttp(Object code) {
    return 'OpenSubtitles 老接口返回 HTTP $code';
  }

  @override
  String get mediaSubtitleRestLanguageUnsupported =>
      '这个语言组合在 OpenSubtitles 老接口上没有对应的语言码';

  @override
  String get mediaSubtitleEpisodeUnknown => '集号未知';

  @override
  String noteConflictResolveFailed(Object error) {
    return '处理失败：$error';
  }

  @override
  String get noteConflictRetry => '重试';

  @override
  String get nasTitle => '我的 NAS';

  @override
  String get nasAdd => '添加 NAS';

  @override
  String get nasPartialLoad => '部分已保存的服务器信息读不出来，已跳过；其余不受影响。';

  @override
  String get nasFootnote =>
      '本机可保存多个 NAS 与账号；切换后文件、相册、笔记、音乐、下载与网盘都会连到当前这一个。移除只影响被选中的那一个。';

  @override
  String get nasEmpty => '还没有保存任何 NAS';

  @override
  String get nasNameLabel => '名称';

  @override
  String get nasNameHint => '例如：家里的 NAS';

  @override
  String get nasRemoveTitle => '移除这个 NAS？';

  @override
  String nasRemoveActiveBody(String name) {
    return '「$name」是当前 NAS，移除会先断开它，并切到其他已保存的 NAS。只会删除这一条，其他 NAS 的配置不受影响。';
  }

  @override
  String nasRemoveBody(String name) {
    return '只会从本机删除「$name」这一条，其他 NAS 的配置不受影响。';
  }

  @override
  String get nasRemovedNone => '已移除，当前没有已保存的 NAS。';

  @override
  String nasRemovedSwitched(String name) {
    return '已移除，已切到「$name」。';
  }

  @override
  String nasSwitched(String name) {
    return '已切换到「$name」';
  }

  @override
  String get nasConnectFailed => '暂时连接不上这台 NAS';

  @override
  String get nasRecordGone => '这条记录已经不在了';

  @override
  String get nasNotSignedIn => '尚未登录';

  @override
  String nasAccount(String account) {
    return '账号：$account';
  }

  @override
  String get nasCurrent => '当前';

  @override
  String get nasSwitchTo => '切换到此 NAS';

  @override
  String get nasRemove => '移除';

  @override
  String get nasNameOptional => '名称（可选）';

  @override
  String get nasDirectAddress => '直接地址';

  @override
  String get nasHostOrAddress => '主机或地址';

  @override
  String get nasAddAndConnect => '添加并连接';

  @override
  String get nasSaved => '已保存的 NAS';

  @override
  String nasSelectN(int n) {
    return '选择 NAS（$n 个）';
  }

  @override
  String get nasManage => '管理 NAS';

  @override
  String nasLabelNotSignedIn(String name) {
    return '$name（未登录）';
  }

  @override
  String nasCurrentLabel(String name) {
    return '当前：$name';
  }

  @override
  String get adminPermissionRequired => '需要管理员权限';

  @override
  String get photoAdminTitle => '照片（管理员）';

  @override
  String photoAdminLoadFailed(String error) {
    return '管理设置读取失败：$error';
  }

  @override
  String get photoAdminSettingsTitle => '管理端设置';

  @override
  String get photoAdminSettingsEmpty => '这台 NAS 没有返回任何管理端字段';

  @override
  String get photoAdminRefetch => '重新地理编码';

  @override
  String get photoAdminRefetchHint => '让 NAS 重新解析照片坐标对应的地方名（会占用一定的 NAS 资源）';

  @override
  String get photoAdminRefetchTitle => '重新地理编码？';

  @override
  String get photoAdminRefetchBody => 'NAS 会重新解析所有照片的位置名称，可能持续一段时间。';

  @override
  String get photoAdminRefetchQueued => '已请求重新地理编码';

  @override
  String photoAdminRefetchFailed(String error) {
    return '请求失败：$error';
  }

  @override
  String get photoAdminEntrySubtitle => '管理端设置与重新地理编码；只对管理员显示';

  @override
  String get photoMapTitle => '照片地图';

  @override
  String photoMapLayerTooltip(String name) {
    return '切换图层（$name）';
  }

  @override
  String get photoMapMyLocation => '我的位置';

  @override
  String photoMapLoadFailed(String error) {
    return '地图加载失败：$error';
  }

  @override
  String get photoMapNoGeotagged => '还没有带位置信息的照片';

  @override
  String get photoMapTilesUnavailable =>
      '底图加载失败：可能是本机网络访问不到这个图源。点这里重试，或用右上角图层按钮换一个图源。';

  @override
  String photoMapNPhotos(int n) {
    return '$n 张';
  }

  @override
  String photoMapClusterN(int n) {
    return '这一带 $n 张';
  }

  @override
  String get photoMapNoLocationSupport => '本机没有可用的定位能力';

  @override
  String get photoMapLocationDenied => '没有定位权限，无法显示我的位置';

  @override
  String get photoMapLocationFailed => '暂时定不到位';

  @override
  String get sleepBackupTitle => '专注备份和同步';

  @override
  String sleepBackupRemaining(int n) {
    return '还剩 $n 个文件待备份';
  }

  @override
  String sleepBackupCountdown(int n) {
    return '屏幕将在 $n 秒内后变暗。';
  }

  @override
  String get sleepBackupOutdated => '还有未完成的任务：启用后在闲置时间自动跑。';

  @override
  String get sleepBackupEnablingTitle => '启用后：';

  @override
  String get sleepBackupEnable => '启用';

  @override
  String get sleepBackupDisable => '停用';

  @override
  String get sleepBackupEnabledState => '已启用（状态会带给提醒调度）';

  @override
  String get sleepBackupDisabledState => '未启用';

  @override
  String get sleepBackupTestReminder => '试用提醒';

  @override
  String sleepBackupReminderTitleLine(String title) {
    return '提醒标题：$title';
  }

  @override
  String sleepBackupScheduleLine(int interval) {
    return '大约每 $interval 分钟检查一次未完成的任务；提醒间隔从 24 小时起逐步放宽，最长隔 3 天才提醒一次。';
  }

  @override
  String get sleepBackupTestNotDue => '此刻不该提醒（未到点，或任务没在过时状态），决策已按官方规则算出。';

  @override
  String get sleepBackupTestSent => '已按官方提醒文案发出本地通知。';

  @override
  String get sleepBackupTestNoPerm => '系统没给通知权限：文案已在页面内展示，未发系统通知。';

  @override
  String get sleepBackupStatusProcessing => '正在备份和同步...';

  @override
  String get sleepBackupStatusFinished => '备份和同步已完成';

  @override
  String get sleepBackupStatusStopped => '备份和同步已停止';

  @override
  String get sleepBackupNotificationTitle => 'SynHub 提醒';

  @override
  String get sleepBackupNotificationMessage =>
      '还有未完成的任务。前往更多 > 备份和同步任务，启用专注备份和同步以利用闲置时间运行任务。';

  @override
  String get sleepBackupGuideRunning => '本应用会在屏幕变暗的状态下运行任务，该流程可能需要一段时间才能完成。';

  @override
  String get sleepBackupGuideForeground => '请让本应用保留在前台，以便继续这个流程。';

  @override
  String get sleepBackupGuideNoLock => '请勿锁定屏幕或退出应用程序。';

  @override
  String get sleepBackupStopDesc => '发生错误。请前往主页 > 后台任务以检查以下任务：';

  @override
  String get sleepBackupWorkerTitle => 'SynHub 休眠备份';

  @override
  String get sleepBackupWorkerText => '为了让备份继续，请保持 App 在前台并让屏幕常亮。';

  @override
  String get photoSleepBackupSubtitle => '屏幕变暗时跑未完成的备份任务，并按 24 小时退避提醒';

  @override
  String photoSimilarGroupN(int n) {
    return '这一组共 $n 张';
  }

  @override
  String get photoSimilarSingle => '这一张';

  @override
  String get photoSimilarNotActionable => '这台服务器没有返回分组信息，只能查看。';

  @override
  String get photoSimilarUngroup => '解散堆叠';

  @override
  String get photoSimilarHint => '点某一张 = 设为主推；点右上角 × = 把它移出这一组。';

  @override
  String get photoSimilarRemoved => '已移出该组';

  @override
  String get photoSimilarTopPickSet => '已设为主推';

  @override
  String get photoSimilarUngrouped => '已解散';

  @override
  String get photoSimilarRemoveTitle => '把它移出这一组？';

  @override
  String get photoSimilarRemoveBody => '只是不再归到这一组，照片本身不会被删除。';

  @override
  String get photoSimilarUngroupTitle => '解散这一组？';

  @override
  String get photoSimilarUngroupBody => '组里的照片都会保留，只是不再作为一组重复项。';

  @override
  String photoSimilarTotalN(int n) {
    return '共 $n 张';
  }

  @override
  String get photoTopPickSelected => '已选主推';

  @override
  String get photoFaceRemove => '移出该人物';

  @override
  String get photoFaceSeparate => '拆分为新人物';

  @override
  String get photoFaceRemoveTitle => '把这张脸移出该人物？';

  @override
  String get photoFaceSeparateTitle => '拆成新人物？';

  @override
  String get photoFaceRemoveBody => '只是不再归到这个人名下，照片本身不会被删除。';

  @override
  String get photoFaceSeparateBody => '会以这张脸为线索新建一个未命名人物。';

  @override
  String get photoFaceRemoved => '已移出';

  @override
  String get photoFaceSeparated => '已拆分';

  @override
  String get photoPersonMergeTooltip => '合并到…';

  @override
  String get photoPersonMergePickerTitle => '合并到哪个人物？';

  @override
  String photoPersonMergeConfirmTitle(String name) {
    return '把这个人合并到「$name」？';
  }

  @override
  String get photoPersonMergeConfirmBody => '合并后这组人脸会归到目标人物名下，操作不可自动撤销。';

  @override
  String get photoPersonMergeAction => '合并';

  @override
  String get photoPersonMerged => '已合并';

  @override
  String get photoCastStopped => '已停止投送';

  @override
  String get photoCastNoDevices => '没有找到可投送的设备';

  @override
  String get photoCastPickDevice => '投送到哪台设备？';

  @override
  String get photoCastConnectFailed => '投送连接失败';

  @override
  String get photoRequestDescription => '说明（可选）';

  @override
  String get photoRequestTeamLibrary => '团队空间';

  @override
  String get photoRequestTeamLibraryHint => '关闭 = 个人空间';

  @override
  String get photoRequestMaxFileSize => '单个文件上限（MB，留空 = 不限）';

  @override
  String get photoMapEntry => '地图';

  @override
  String photoWave2SearchFilterApplyCount(int n) {
    return '应用（$n）';
  }

  @override
  String photoPersonsMigratingLine(String title, String message) {
    return '$title：$message';
  }

  @override
  String photoCacheLocalSize(String size, int n) {
    return '$size MB · $n 个文件';
  }

  @override
  String get driveAdminTitle => 'Drive（管理员）';

  @override
  String get driveAdminNoFields => '服务端没有返回字段';

  @override
  String get driveAdminNoUsers => '服务端没有返回用户';

  @override
  String get driveAdminEntryTitle => '管理（管理员）';

  @override
  String get driveAdminEntrySubtitle => 'Drive 设置 / 数据库用量 / 用户权限（只读）';

  @override
  String driveScanLayoutStats(int lines, int words) {
    return '版面：$lines 行 / $words 词块';
  }

  @override
  String driveScanLayoutFailPart(int n) {
    return ' · 失败 $n 页';
  }

  @override
  String driveScanOcrStats(int chars) {
    return ' · 自研识别（点阵印刷体）：$chars 字';
  }

  @override
  String driveScanUnknownPart(int n) {
    return ' · 认不出 $n 处';
  }

  @override
  String driveScanProcessedStats(int n, int detected) {
    return '已处理 $n 页 · 检测到边界 $detected 页';
  }

  @override
  String get driveScanEnhance => '自动裁边并增强';

  @override
  String get driveScanLines => '文字行分析';

  @override
  String get driveScanMovePrev => '前移';

  @override
  String get driveScanMoveNext => '后移';

  @override
  String get driveScanRemovePage => '删除本页';

  @override
  String get driveScanGallery => '相册导入';

  @override
  String driveSyncFailedDetail(String error) {
    return '失败：$error';
  }

  @override
  String driveSyncCheckFailedDetail(String error) {
    return '检查失败：$error';
  }

  @override
  String get driveSyncLocalHint => '/storage/emulated/0/Documents/项目';

  @override
  String get driveSyncRemoteHint => '/mydrive/项目';

  @override
  String get driveSyncTasksTooltip => '同步任务';

  @override
  String get driveCategoryPhoto => '照片';

  @override
  String get driveCategoryVideo => '视频';

  @override
  String get driveCategoryAudio => '音频';

  @override
  String get driveCategoryDocument => '文档';

  @override
  String driveCategoryChip(String label, int count) {
    return '$label（$count）';
  }

  @override
  String drivePdfTextSelectedDetail(String text) {
    return '已按文字行高亮：$text';
  }

  @override
  String driveSearchFilterActive(String label, String value) {
    return '$label：$value';
  }

  @override
  String safOnDemandConfiguredStatus(String account) {
    return '已保存：系统「文件」可以访问这台 NAS；账号 $account';
  }

  @override
  String safOnDemandUnconfiguredStatus(String account) {
    return '尚未设置：系统「文件」里还没有这台 NAS 的账号；账号 $account';
  }

  @override
  String get safOnDemandUnknownAccount => '（未知）';

  @override
  String get safOnDemandNativeNote => '按需下载由安卓系统的文档提供程序处理：文件在你打开时才下载。';

  @override
  String get driveAdminSectionSettings => '设置（Settings/list v1）';

  @override
  String get driveAdminSectionDatabase => '数据库（Config/get v1 + DBUsage/get v1）';

  @override
  String get driveAdminSectionPrivilege => '权限（Privilege/list v1）';

  @override
  String driveAdminReadFailed(String section) {
    return '读取失败（$section）';
  }

  @override
  String get fieldName => '名称';

  @override
  String get fieldDescription => '描述';

  @override
  String get listSeparator => '、';

  @override
  String get asRadioPlayFailed => '这个电台没能开始播放，可以换一个电台或重试。';

  @override
  String get asRadioPlayFailedShort => '没能播放';

  @override
  String get asRadioPlayRetry => '重试';

  @override
  String get audioRadioNew => '新建电台';

  @override
  String get audioRadioEdit => '编辑电台';

  @override
  String audioRadioDeleteBody(String title) {
    return '确定删除「$title」？';
  }

  @override
  String get officeEmptyDocTitle => '这份文档还没有内容';

  @override
  String get officeEmptyDocBody =>
      '在 Synology Office / WPS / Microsoft Word 里写点什么并保存，再回到这里下拉刷新即可看到。';

  @override
  String dsRssFilterMatchLine(String value) {
    return '包含：$value';
  }

  @override
  String dsRssFilterNotMatchLine(String value) {
    return '排除：$value';
  }

  @override
  String dsRssFilterDestLine(String value) {
    return '下载到：$value';
  }

  @override
  String asPinReorderFailedDetail(String error) {
    return '收藏排序失败：$error';
  }

  @override
  String asPinRenameFailedDetail(String error) {
    return '重命名失败：$error';
  }

  @override
  String get dsUnzipLocationCurrentFolder => '下载文件夹';

  @override
  String get dsUnzipLocationSpecifiedFolder => '指定文件夹';

  @override
  String dsUnzipLocationLine(String path) {
    return '解压位置：$path';
  }

  @override
  String dsModulesLine(String list) {
    return '模块：$list';
  }

  @override
  String get appPageNotFound => '页面不存在';

  @override
  String chatUserWithAccount(String display, String username) {
    return '$display（$username）';
  }

  @override
  String get officeNotConnectedDsm => '未连接 DSM';

  @override
  String mailSendFailedDetail(String message, String error) {
    return '$message：$error';
  }

  @override
  String get noteConflictResolveIncomplete => '冲突处理未能完成，请稍后重试';

  @override
  String textAiPassageLabel(String name, int n, String title) {
    return '$name（$n）· $title';
  }

  @override
  String get filePdfMarkupEntry => '批注 / 签名';

  @override
  String officeViewerImageRef(String label, String id) {
    return '$label：$id';
  }

  @override
  String bookSlidesHeading(int n) {
    return '幻灯片 $n';
  }

  @override
  String calendarLunarMonthDay(Object d, Object m, Object zh) {
    return '$zh';
  }

  @override
  String calendarLunarMonthOnly(Object m, Object zh) {
    return '$zh月';
  }

  @override
  String calendarLunarDayOnly(Object d, Object zh) {
    return '$zh';
  }

  @override
  String get bookChmNoHtml => '这本书里没有可读的 HTML 正文';

  @override
  String get bookChmParseFailed => '这本 CHM 解析失败（文件可能损坏）';

  @override
  String get bookDjvuNoPages => '这本 DJVU 里没有可读的页（既没有位图也没有文本层）';

  @override
  String get bookDjvuParseFailed => '这本 DJVU 解析失败（文件可能损坏）';

  @override
  String get bookParseFailedDrm => '这本书解析失败（文件可能损坏或带 DRM）';

  @override
  String bookFootnoteWrap(String inner) {
    return '（$inner）';
  }

  @override
  String bookSheetN(String n) {
    return '工作表 $n';
  }

  @override
  String get bookWorkbookTitle => '工作簿';

  @override
  String get bookListSeparator => '、';

  @override
  String get bookSearchHitOpen => '「';

  @override
  String get bookSearchHitClose => '」';

  @override
  String bookXpsVectorUnrendered(String count) {
    return '（本页含 $count 个矢量图形，未渲染）';
  }

  @override
  String get bookXpsNoContent => '（本页没有可提取的文字或位图）';

  @override
  String get driveOnDemandNotEnabled => '按需下载未开启';

  @override
  String get driveOnDemandMissingFileId => '缺少 fileId';

  @override
  String driveOnDemandTooLarge(String size, String limit) {
    return '文件 $size 超过\"打开即下\"上限 $limit，请先在 App 里选择\"离线可用\"';
  }

  @override
  String get driveOnDemandEmptyContent => '服务端返回空内容';

  @override
  String driveOnDemandRejected(String code) {
    return '下载被拒绝（DSM 错误码 $code）';
  }

  @override
  String driveOnDemandActualTooLarge(String size, String limit) {
    return '实际大小 $size 超过上限 $limit，已丢弃';
  }

  @override
  String driveOnDemandFailed(String error) {
    return '下载失败：$error';
  }

  @override
  String get driveSafOfflineRootTitle => 'Synology Drive · 离线文件';

  @override
  String get driveSafRemoteRootTitle => 'Synology Drive · 云端文件';

  @override
  String get driveOfficeCreateDoc => 'Synology Office 文档';

  @override
  String get driveOfficeCreateSheet => 'Synology Office 电子表格';

  @override
  String get driveOfficeCreateSlides => 'Synology Office 演示文稿';

  @override
  String officeViewerTranscodedKind(String kind) {
    return '（识别为 $kind）';
  }

  @override
  String get fsGap2ErrorDetailSeparator => '：';

  @override
  String get officeDocStepEmptyEdit => '空编辑';

  @override
  String officeDocStepDeleteText(String from, String to) {
    return '删除文本（位置 $from..$to）';
  }

  @override
  String officeDocStepInsertText(String text) {
    return '插入文本“$text”';
  }

  @override
  String officeDocStepReplaceText(String text) {
    return '替换文本为“$text”';
  }

  @override
  String officeDocStepAddMark(String mark) {
    return '添加格式 $mark';
  }

  @override
  String officeDocStepRemoveMark(String mark) {
    return '取消格式 $mark';
  }

  @override
  String get officeDocTocLevel1 => '1 级标题';

  @override
  String get officeDocTocLevel2 => '2 级标题';

  @override
  String get officeDocTocLevel3 => '3 级标题';

  @override
  String get officeDocTocLevel4 => '4 级标题';

  @override
  String get officeDocTocLevel5 => '5 级标题';

  @override
  String get officeDocTocLevel6 => '6 级标题';

  @override
  String officeDocStepSetHeading(String level) {
    return '设置标题级别 $level';
  }

  @override
  String get officeDocStepSetList => '设置列表';

  @override
  String officeDocStepSetParagraphAttrs(String attrs) {
    return '设置段落属性 $attrs';
  }

  @override
  String officeDocStepSetDocAttrs(String attrs) {
    return '设置文档属性 $attrs';
  }

  @override
  String officeDocStepEdit(String type) {
    return '编辑（$type）';
  }

  @override
  String officeDocTolerantMarks(String nodes, String marks) {
    return '文档里有 $nodes 处图片被附带了 $marks 条文字格式标记（marks）；这类标记写在图片上本来就不生效，已忽略，正文与图片内容完整。';
  }

  @override
  String get officeCollabErrNoPermission => '该账号对此文件没有编辑权限';

  @override
  String get officeCollabErrNotReady => '协作服务尚未就绪';

  @override
  String get officeCollabErrTimeout => '协作服务响应超时';

  @override
  String get officeCollabErrDisconnected => '协作服务连接已断开';

  @override
  String get officeCollabErrUnavailable => '协作服务暂时不可用';

  @override
  String officeSheetChartSeries(String n) {
    return '系列 $n';
  }

  @override
  String officeDocHeadingLevelLabel(String level) {
    return '标题级别 $level';
  }

  @override
  String get officeDocListOff => '取消列表';

  @override
  String officeDocUndoLabel(String label) {
    return '撤销 $label';
  }

  @override
  String officeDocRedoLabel(String label) {
    return '重做 $label';
  }

  @override
  String get officeSlidesBlockUnknown => '(未知位置)';

  @override
  String officeSlidesBlockLabel(String block) {
    return '块 $block';
  }

  @override
  String get driveWatchTaskDeleted => '任务已删除';

  @override
  String get driveWatchAutoSyncDisabled => '未启用自动同步';

  @override
  String driveWatchTooSoon(String minutes) {
    return '距上次同步不足 $minutes 分钟';
  }

  @override
  String driveWatchFailed(String error) {
    return '失败：$error';
  }

  @override
  String get driveGapLabelSep => '：';

  @override
  String get drivePdfWrittenSuffix => '_写回';

  @override
  String get drivePdfAnnotSuffix => '_批注';

  @override
  String get drivePdfTextLayerUnsupportedFilter => '内容流滤镜不支持（只做 /FlateDecode）';

  @override
  String drivePdfTextLayerNoWidths(String name, String subtype) {
    return '字体 `$name`（$subtype）没有 /Widths，坐标不可靠 ⇒ 不解码';
  }

  @override
  String drivePdfTextLayerUnknownOp(String op) {
    return '遇到不支持的算子 `$op`（坐标可能不全）';
  }

  @override
  String driveSyncConflictDupName(
    String dir,
    String base,
    String stamp,
    String ext,
  ) {
    return '$dir$base (冲突 $stamp)$ext';
  }

  @override
  String get driveSyncNeedLocalFolder => '请选择本地文件夹';

  @override
  String get driveSyncNeedRemoteFolder => '请选择远端文件夹';

  @override
  String get driveSyncRemoteMustStartSlash => '远端路径要以 / 开头';

  @override
  String get driveSyncIntervalPositive => '自动同步间隔要大于 0 分钟';

  @override
  String get driveSyncLocalNewer => '本地较新';

  @override
  String get driveSyncRemoteNewer => '远端较新';

  @override
  String get photoC2GroupAperture => '光圈';

  @override
  String get photoC2GroupCamera => '相机';

  @override
  String get photoC2GroupLens => '镜头';

  @override
  String get photoC2GroupFlash => '闪光灯';

  @override
  String get photoC2GroupExposureTime => '曝光时间';

  @override
  String get photoC2GroupFocalLength => '焦距';

  @override
  String get photoC2GroupGeocoding => '地点';

  @override
  String get photoC2GroupPerson => '人物';

  @override
  String get photoC2GroupTag => '标签';

  @override
  String get photoC2GroupConcept => '场景';

  @override
  String get photoC2GroupRating => '评分';

  @override
  String get photoC2GroupFavorite => '收藏';

  @override
  String get photoC2GroupTime => '时间';

  @override
  String get photoC2GroupItemType => '媒体类型';

  @override
  String get photoP0PersonShow => '显示';

  @override
  String get photoP0PersonHide => '隐藏';

  @override
  String get photoP0CastUnknownDevice => '未知设备';

  @override
  String get photoP0CastToScreen => '投送到大屏';

  @override
  String get photoP0CastStop => '停止投送';

  @override
  String get photoWave3CacheCleared => '已清理';

  @override
  String get photoP0RemoveSmartDone => '已从该场景移除';

  @override
  String get asPlaylistNameHint => '名称';

  @override
  String get mediaAudioChannelName => '播放控制';

  @override
  String get mediaCtlPrevious => '上一首';

  @override
  String get mediaCtlNext => '下一首';

  @override
  String get mediaCtlPlay => '播放';

  @override
  String get mediaCtlPause => '暂停';

  @override
  String get mediaCtlStop => '停止播放并清除通知';

  @override
  String get mediaHideControls => '隐藏控件';

  @override
  String get mediaMore => '更多';

  @override
  String get mediaSubtitleSearchEllipsis => '搜索在线字幕…';

  @override
  String mediaSpeedValue(String speed) {
    return '倍速 ${speed}x';
  }

  @override
  String get mediaSpeed => '倍速';

  @override
  String get mediaSubtitleSearch => '搜索在线字幕';

  @override
  String mediaBackwardN(String n) {
    return '快退 $n 秒';
  }

  @override
  String mediaForwardN(String n) {
    return '快进 $n 秒';
  }

  @override
  String get mediaHoldBoost => '松手恢复原速 · 2×';

  @override
  String get mediaSubtitleSize => '字幕大小';

  @override
  String get mediaSubtitleTranscript => '字幕全文';

  @override
  String get mediaSubtitleSmaller => '字幕小一点';

  @override
  String get mediaSubtitleLarger => '字幕大一点';

  @override
  String get mediaSubtitlePosition => '字幕位置';

  @override
  String get mediaSubtitlePositionDefault => '默认';

  @override
  String get mediaSubtitleHigher => '字幕往上';

  @override
  String get mediaSubtitleLower => '字幕往下';

  @override
  String get mediaSubtitleBackground => '字幕背景条';

  @override
  String get mediaCast => 'Cast';

  @override
  String get mediaCastTitle => 'Cast to TV';

  @override
  String get mediaCastSearching =>
      'Looking for TVs and projectors on your network…';

  @override
  String get mediaCastEmpty => 'No castable device found';

  @override
  String get mediaCastEmptyHint =>
      'Make sure the TV is on, on the same Wi-Fi as this phone, and has screen casting / DLNA enabled.';

  @override
  String get mediaCastSearch => 'Search again';

  @override
  String get mediaCastStop => 'Stop casting';

  @override
  String get mediaCastFailed => 'Casting failed';

  @override
  String get mediaCastReasonNoRenderer =>
      'No device on this network accepts casting.';

  @override
  String get mediaCastReasonUnreachable =>
      'The device is unreachable (turned off, or not on this network).';

  @override
  String get mediaCastReasonRejected =>
      'The TV refused this video (unsupported format, or blocked by its policy).';

  @override
  String get mediaCastReasonPlaybackFailed =>
      'The TV got the address but could not play it — it cannot reach the video on your NAS. Check the network or the certificate.';

  @override
  String get mediaCastPauseRemote => 'Pause on TV';

  @override
  String get mediaCastRemotePlaying => '电视正在播放';

  @override
  String get mediaCastResumeRemote => 'Resume on TV';

  @override
  String get mediaCastRemotePaused => 'Paused on TV';

  @override
  String mediaVolumePercent(String n) {
    return '音量 $n%';
  }

  @override
  String mediaBrightnessPercent(String n) {
    return '亮度 $n%';
  }

  @override
  String mediaSubtitleSearchFailed(String err) {
    return '搜索失败：$err';
  }

  @override
  String mediaSubtitleSourceUnavailable(String source) {
    return '这个源已经不可用了（$source）';
  }

  @override
  String mediaSubtitleDownloadFailed(String err) {
    return '下载失败：$err';
  }

  @override
  String get mediaSubtitleTitleField => '片名';

  @override
  String get mediaSubtitleTitleHint => '剧集请带 S01E02';

  @override
  String get mediaSubtitleLangChinese => '中文优先';

  @override
  String get mediaSubtitleLangEnglish => '英文优先';

  @override
  String get mediaSubtitleLangAny => '任意';

  @override
  String get mediaSubtitleApiKeyLabel => 'OpenSubtitles API Key（可选）';

  @override
  String get mediaSubtitleKeyMissing => '未配置字幕服务密钥：会先尝试免密钥的来源；部分字幕源需要 API key。';

  @override
  String mediaSubtitleHash(String hash) {
    return '已算媒体指纹 $hash…（支持按首尾 64KB 匹配）';
  }

  @override
  String mediaSubtitleFailureLine(String source, String message) {
    return '$source：$message';
  }

  @override
  String get mediaSubtitleOnline => '在线字幕';

  @override
  String mediaSubtitleOpenSubtitlesAnonymousRejected(String code) {
    return 'OpenSubtitles 拒绝了匿名请求（HTTP $code）：请在下方填写 API Key 后重试';
  }

  @override
  String mediaSubtitleOpenSubtitlesRejected(String code) {
    return 'OpenSubtitles 拒绝了这次请求（HTTP $code）：API Key 可能无效或已超额';
  }

  @override
  String get mediaSubtitleHearingImpaired => '听障';

  @override
  String mediaSubtitlePartsCount(String n) {
    return '$n 段（只取第 1 段）';
  }

  @override
  String get mediaSubtitleProofread => '已校对';

  @override
  String mediaSubtitleGestdownHttp(String code) {
    return 'Gestdown 返回 HTTP $code';
  }

  @override
  String mediaSubtitleGestdownShowFailed(String code) {
    return 'Gestdown 剧集检索失败（HTTP $code）';
  }

  @override
  String mediaSubtitleBadJson(String code) {
    return '字幕源返回的不是合法 JSON（HTTP $code）';
  }

  @override
  String get mediaSubtitleKeySaveFailed => '密钥保存失败（安全存储不可用）';

  @override
  String get mediaSubtitleUnreadableContent => '这条字幕解析不出内容（可能不是文本字幕）';

  @override
  String get mediaSubtitleAllSourcesFailed => '所有在线字幕源都失败了，见上面的原因';

  @override
  String get mediaSubtitleNoMatch => '没有找到匹配的字幕（可以改片名或换语言再试）';

  @override
  String get mediaSubtitleTimeout => '请求超时';

  @override
  String mediaSubtitleServerUnreachable(String err) {
    return '连不上字幕服务器（$err）';
  }

  @override
  String mediaSubtitleTlsFailed(String err) {
    return 'TLS 握手失败（$err）';
  }

  @override
  String get mediaSubtitleNoTitleFromFileName => '文件名里推不出片名，请在搜索框里手动输入片名';

  @override
  String mediaSubtitleOpenSubtitlesUnavailable(String code) {
    return 'OpenSubtitles 暂时不可用（HTTP $code），稍后重试';
  }

  @override
  String mediaSubtitleOpenSubtitlesUnexpectedStatus(String code) {
    return 'OpenSubtitles 返回了意外的状态码 HTTP $code';
  }

  @override
  String get mediaSubtitleNoDownloadFileId => '这条结果没有可下载的文件 id';

  @override
  String mediaSubtitleFileDownloadFailed(String code) {
    return '字幕文件下载失败（HTTP $code）';
  }

  @override
  String get mediaSubtitleUnrecognizedSubtitle => '下载回来的不是可识别的字幕（可能是压缩包结构变了）';

  @override
  String get mediaSubtitleGestdownEpisodesOnly =>
      'Gestdown 只支持剧集：文件名里需要有 S01E02 这样的季集号';

  @override
  String get mediaSubtitleNoDownloadUri => '这条结果没有下载地址';

  @override
  String mediaSubtitleGestdownDownloadFailed(String code) {
    return 'Gestdown 字幕下载失败（HTTP $code）';
  }

  @override
  String get mediaSubtitleUnrecognizedContent => '下载回来的内容不是可识别的字幕';

  @override
  String mediaSubtitleParseResultFailed(String source, String err) {
    return '解析 $source 的结果失败：$err';
  }

  @override
  String calParticipantNameStatus(String name, String status) {
    return '$name（$status）';
  }

  @override
  String get calWeatherClearDay => '晴天';

  @override
  String get calWeatherClearNight => '晴夜';

  @override
  String get calWeatherCloudy => '多云';

  @override
  String get calWeatherRain => '雨';

  @override
  String get calWeatherSnow => '雪';

  @override
  String get calWeatherThunder => '雷雨';

  @override
  String get calWeatherFog => '雾';

  @override
  String get chatChannelGeneral => '常规';

  @override
  String get chatChannelRandom => '随机';

  @override
  String chatMentionSent(String name) {
    return '已提及 @$name';
  }

  @override
  String contactLabelValue(String label, String value) {
    return '$label：$value';
  }

  @override
  String noteC3ErrorCodeSuffix(String code) {
    return '（$code）';
  }

  @override
  String noteC3MessageWithError(String message, String error) {
    return '$message：$error';
  }

  @override
  String get widgetNotebookUntitled => '未命名笔记本';

  @override
  String get widgetTodoUntitled => '未命名待办';

  @override
  String adminGapStoragePoolsLine(String vol, String n) {
    return '$vol（$n 个存储池）';
  }

  @override
  String get adminGapEnabled => '已启用';

  @override
  String get adminGapDisabled => '未启用';

  @override
  String adminGapAuthCount(String n) {
    return '共 $n 个验证器';
  }

  @override
  String adminGapHddCount(String n) {
    return '共 $n 块';
  }

  @override
  String adminGapUserCount(String n) {
    return '共 $n 个用户';
  }

  @override
  String adminGapGroupCount(String n) {
    return '共 $n 个群组';
  }

  @override
  String adminGapAppPrivCount(String n) {
    return '共 $n 条规则';
  }

  @override
  String adminGapDiskCount(String n) {
    return '共 $n 块磁盘';
  }

  @override
  String adminGapPackageCount(String n) {
    return '共 $n 个：';
  }

  @override
  String get adminGapUpgradeAvailable => '有可用更新';

  @override
  String get adminGapUpgradeLatest => '已是最新';

  @override
  String adminGapServiceCount(String n) {
    return '共 $n 项服务';
  }

  @override
  String get aiModelLfmName => 'LFM2.5 230M（int4）';

  @override
  String get dsNotifyDownloadFailed => '下载失败';

  @override
  String get dsNotifyDownloadDone => '下载完成';

  @override
  String dsRssLastUpdateLine(String when) {
    return '上次更新：$when';
  }

  @override
  String setGapServerLabel(String base, String source) {
    return '$base（$source）';
  }

  @override
  String chatSearchKeyword(String x) {
    return '「$x」';
  }

  @override
  String officeSectionEncryptedNotice(String x) {
    return '已加密 section：$x（zlib+AES-256-CBC+base64）→ 阶段 2a 不解密，需阶段 2b';
  }

  @override
  String officeSectionOpaqueNotice(String x) {
    return '不可解释 section：$x';
  }

  @override
  String get officeSlidesGraphicChart => '图表';

  @override
  String get officeSlidesGraphicDiagram => 'SmartArt 图示';

  @override
  String get officeSlidesGraphicTable => '表格';

  @override
  String get officeSlidesGraphicOle => '嵌入对象';

  @override
  String get officeSlidesGraphicObject => '对象';

  @override
  String fsGap2FavoriteReorderRejectedDetail(String head, String detail) {
    return '$head（$detail）';
  }

  @override
  String get usageModMedia => '影音';

  @override
  String get usageModAi => 'AI 助手';

  @override
  String get usageModDownloads => '下载';

  @override
  String get usageModAdmin => '管理';

  @override
  String get usageModSurveillance => '监控';

  @override
  String get usageActView => '进入页面';

  @override
  String get usageActSwitchView => '切换视图';

  @override
  String get usageActFilter => '筛选';

  @override
  String get usageActSort => '排序';

  @override
  String get usageActSelect => '选择';

  @override
  String get usageActComplete => '完成';

  @override
  String get usageActAbandon => '中断';

  @override
  String get usageActStart => '开始';

  @override
  String get usageActPause => '暂停';

  @override
  String get usageActResume => '继续';

  @override
  String get usageActAudition => '试听';

  @override
  String get usageActVote => '投票';

  @override
  String get usageActSwitchLanguage => '切换语言';

  @override
  String get usageFailUnknown => '未知原因';

  @override
  String get usageFailOffline => '离线或未连接';

  @override
  String get usageFailNetwork => '网络错误';

  @override
  String get usageFailTimeout => '超时';

  @override
  String get usageFailAuth => '认证失败';

  @override
  String get usageFailPermission => '无权限';

  @override
  String get usageFailNotFound => '不存在';

  @override
  String get usageFailUnsupported => '不支持';

  @override
  String get usageFailDecode => '解码或渲染失败';

  @override
  String get usageFailTls => '证书或加密失败';

  @override
  String get usageFailStorage => '存储空间不足';

  @override
  String get usageFailConflict => '冲突';

  @override
  String get usageFailServer => '服务端错误';

  @override
  String get usageFailCancelled => '已取消';

  @override
  String get usageSectionModules => '按模块使用';

  @override
  String get usageSectionAdoption => '功能采用';

  @override
  String get usageSectionViewPrefs => '视图与选项偏好';

  @override
  String get usageSectionFailures => '失败原因';

  @override
  String get usageSectionDurations => '使用时长';

  @override
  String get usageNoViewPrefs => '还没有视图或选项切换记录';

  @override
  String get usageNoFailures => '没有失败记录';

  @override
  String get usageNoDurations => '还没有可统计的时长记录';

  @override
  String get usageAdoptAll => '所有模块都至少用过一次';

  @override
  String usageRange(String from, String to) {
    return '统计范围 $from → $to';
  }

  @override
  String usageModuleRow(String name, int count, int share) {
    return '$name · $count 次 · $share%';
  }

  @override
  String usageAdoptTitle(int used, int total) {
    return '已采用 $used/$total 个模块';
  }

  @override
  String usageAdoptBody(String unused) {
    return '还没用过：$unused';
  }

  @override
  String usageViewPrefRow(String view, int count) {
    return '$view · $count 次';
  }

  @override
  String usageFailReasonRow(String reason, int count) {
    return '$reason · $count 次';
  }

  @override
  String usageDurationRow(String action, int avgMin, int count) {
    return '$action · 平均 $avgMin 分钟 · $count 次';
  }

  @override
  String get usageKindViewPref => '视图偏好';

  @override
  String get usageKindFailureReason => '失败原因';

  @override
  String get usageSugViewPref => '可以把偏好视图设为默认，少切几次。';

  @override
  String usageTitleViewPref(String view, int share) {
    return '偏好视图：$view（占 $share%）';
  }

  @override
  String usageBodyViewPref(String list) {
    return '其它视图：$list';
  }

  @override
  String usageTitleFailureReason(String reason, int count) {
    return '主要失败原因：$reason（$count 次）';
  }

  @override
  String usageBodyFailureReason(String list) {
    return '其它原因：$list';
  }

  @override
  String get usageViewGrid => '栅格';

  @override
  String get usageViewList => '列表';

  @override
  String get usageViewTimeline => '时间线';

  @override
  String get usageViewMonth => '月视图';

  @override
  String get usageViewWeek => '周视图';

  @override
  String get usageViewAgenda => '日程';

  @override
  String get usageViewLyrics => '歌词';

  @override
  String get usageViewVisualizer => '可视化';

  @override
  String get usageViewPlayer => '播放器';

  @override
  String get usageViewOther => '其它';

  @override
  String get trafficTitle => '网络流量';

  @override
  String get trafficSubtitle => '按模块与时段统计（精确 + 估算）';

  @override
  String get trafficRangeDay => '近 24 小时';

  @override
  String get trafficRangeWeek => '近 7 天';

  @override
  String get trafficTotal => '合计';

  @override
  String get trafficExact => '精确';

  @override
  String get trafficEstimated => '估算';

  @override
  String get trafficExactHint => 'Dart HTTP 客户端实测（请求 + 响应字节）';

  @override
  String get trafficEstimatedHint => '原生播放器绕过 Dart，按系统 UID 计数在活动会话窗口估算';

  @override
  String get trafficUnattributed => '未归属';

  @override
  String trafficUnattributedShare(String percent) {
    return '未归属 $percent%';
  }

  @override
  String get trafficDirectionAll => '合计';

  @override
  String get trafficDirectionDown => '下载';

  @override
  String get trafficDirectionUp => '上传';

  @override
  String get trafficSectionRanking => '模块流量排行';

  @override
  String get trafficSectionHours => '时段分布（24 小时）';

  @override
  String trafficRankRow(String name, String bytes, String share) {
    return '$name · $bytes · $share%';
  }

  @override
  String get trafficOsSection => '与系统计数对比';

  @override
  String trafficOsTotal(String bytes) {
    return '系统 UID 合计 $bytes';
  }

  @override
  String trafficOsAttributed(String bytes) {
    return '本 App 已归属 $bytes';
  }

  @override
  String trafficOsUnaccounted(String bytes) {
    return '未计入 $bytes';
  }

  @override
  String trafficOsSince(String time) {
    return '自 $time';
  }

  @override
  String get trafficOsUnavailable => '本机读不到系统流量计数，估算档不可用';

  @override
  String get trafficEmptyTitle => '还没有流量数据';

  @override
  String get trafficEmptyMessage => '用一会儿再回来看。精确档从 Dart 请求开始记；估算档要一次完整播放会话。';

  @override
  String get trafficPrivacyNote => '只记模块、方向、字节数与小时；不记网址、主机、文件名';

  @override
  String get trafficExactPaths =>
      '精确档覆盖：登录 / 列表 / 元数据 / 缩略图 / 下载 / 上传 / 导出等全部 Dart 请求';

  @override
  String get trafficEstimatedPaths => '估算档覆盖：视频与音频播放、原生抽帧与原生流（活动会话窗口内的差分）';

  @override
  String get trafficModUnattributed => '未归属';

  @override
  String get trafficLoadFailed => '流量数据读取失败';

  @override
  String get trafficStorageNote => '本地保存 90 天的小时聚合桶（最多 10 万行），不上传';

  @override
  String get oemKeepaliveTitle => '后台保活设置';

  @override
  String get oemKeepaliveIntro => '本 App 不走系统推送：只有系统允许它在后台运行，聊天与新消息通知才收得到。';

  @override
  String get oemKeepaliveNoFcm => '下面的放行项建议全部打开——后台被限制时，通知会静默收不到。';

  @override
  String get oemKeepaliveRowSummary => '厂商省电与自启动放行，否则后台收不到通知';

  @override
  String get oemKillAggressive => '该厂商的省电策略较激进，未经设置通常几十分钟内就会被清理';

  @override
  String get oemKillModerate => '该厂商的省电策略中等，长时间不用可能被清理';

  @override
  String get oemKillStandard => '系统级省电（Doze／待机分桶），正常使用不易被清理';

  @override
  String get oemStepAutostart => '允许「自启动／应用启动管理」';

  @override
  String get oemStepBackgroundActivity => '允许「后台活动／关联启动」';

  @override
  String get oemStepBatteryUnrestricted => '电池优化设为「不限制／允许后台高耗电」';

  @override
  String get oemStepLockRecents => '在最近任务里锁定本 App，避免被「一键清理」';

  @override
  String get oemOpenAutostart => '打开自启动管理';

  @override
  String get oemOpenBattery => '打开电池优化白名单';

  @override
  String get oemOpenAppDetails => '打开应用详情';

  @override
  String get oemAutostartMissing => '本机没找到该厂商的自启动设置页，请按下面的路径手动操作';

  @override
  String get oemPathLabel => '手动路径';

  @override
  String get oemBatteryIgnored => '已加入电池优化白名单';

  @override
  String get oemBatteryNotIgnored => '尚未加入电池优化白名单';

  @override
  String get oemDeviceLabel => '本机';

  @override
  String get oemPathXiaomi => '设置 → 应用设置 → 应用管理 → 星枢 → 自启动；返回后进「省电策略」选「无限制」';

  @override
  String get oemPathHuawei =>
      '设置 → 应用和服务 → 应用启动管理 → 星枢 → 关闭「自动管理」，勾选允许自启动／关联启动／后台活动';

  @override
  String get oemPathHonor =>
      '设置 → 应用 → 应用启动管理 → 星枢 → 关闭「自动管理」，勾选允许自启动／关联启动／后台活动';

  @override
  String get oemPathOppo =>
      '设置 → 应用 → 应用管理 → 星枢 → 允许自启动／关联启动／后台活动 → 耗电管理选「允许后台运行」';

  @override
  String get oemPathVivo => '设置 → 应用与权限 → 权限管理 → 自启动 → 允许星枢；再进「电池」→ 后台高耗电 → 允许';

  @override
  String get oemPathOneplus => '设置 → 应用 → 应用管理 → 星枢 → 耗电管理 → 允许后台运行；再关掉「智能省电」';

  @override
  String get oemPathSamsung =>
      '设置 → 电池和设备维护 → 电池 → 后台使用限制 → 把星枢从「休眠应用／深度休眠应用」里移除';

  @override
  String get oemPathMeizu => '设置 → 应用管理 → 权限管理 → 后台管理 → 允许星枢后台运行';

  @override
  String get oemPathRealme =>
      '设置 → 应用 → 应用管理 → 星枢 → 允许自启动／关联启动／后台活动 → 耗电管理选「允许后台运行」';

  @override
  String get oemPathTranssion =>
      '设置 → 应用 → 应用管理 → 星枢 → 允许自启动与后台活动 → 电池 → 关闭省电优化';

  @override
  String get oemPathGoogle => '设置 → 应用 → 星枢 → 电池 → 选「无限制」';

  @override
  String get oemPathOther => '设置 → 应用 → 星枢 → 电池 → 允许后台活动；再到「电池优化」里把星枢设为「不优化」';

  @override
  String get oemNoteHuawei => '华为／荣耀没装谷歌服务不影响本 App，但「应用启动管理」默认是自动管理，必须手动改。';

  @override
  String get oemNoteHonor => '荣耀 MagicOS 的「应用启动管理」默认自动管理；不手动放行时前台服务也可能被冻结。';

  @override
  String get oemNoteXiaomi => 'HyperOS／MIUI 还会在「最近任务」里清后台，建议同时锁定卡片。';

  @override
  String get oemNoteOppo => 'ColorOS 的「智能省电」与「深度睡眠」会冻结后台，两个都要放行。';

  @override
  String get oemNoteVivo => 'OriginOS／FuntouchOS 的「后台高耗电」默认关闭，需手动允许。';

  @override
  String get oemNoteSamsung => 'One UI 的「休眠应用／深度休眠应用」会自动把不常用的 App 加进去，需手动移出。';

  @override
  String get oemNoteMeizu => 'Flyme 的「后台管理」默认限制后台运行，需手动允许。';

  @override
  String get oemNoteRealme => 'realme UI 与 ColorOS 同源，「智能省电」同样会冻结后台。';

  @override
  String get oemNoteTranssion =>
      '传音机型（Tecno／Infinix／itel）的省电管理较激进，且通常没有系统级推送通道。';

  @override
  String get oemNoteOneplus => 'OxygenOS 在 ColorOS 合并后也带「智能省电」，建议一并关闭。';

  @override
  String get oemNoteGoogle => '原生／AOSP 只有 Doze 与待机分桶，没有厂商白名单；仍建议允许不受限后台。';

  @override
  String get oemNoteOther => '未见过的厂商：按通用步骤放行后台即可。';

  @override
  String get oemOpenFailed => '本机打不开这个系统设置页，请按下面的手动路径操作';

  @override
  String get capReasonOk => '可用';

  @override
  String get capReasonNotSupported => '此平台不支持';

  @override
  String get capReasonNotImplemented => '此平台尚未实现';

  @override
  String get capReasonNeedsMobile => '需要手机设备';

  @override
  String get capReasonBridgeMissing => '原生模块缺失';

  @override
  String get capReasonProbing => '正在探测';

  @override
  String get capReasonTimeout => '探测超时';

  @override
  String get capReasonProbeError => '探测失败';

  @override
  String get capReasonDeviceNo => '本机不支持';

  @override
  String get capReasonUnknown => '原因未知';

  @override
  String get errGenericFailed => '操作未能完成';

  @override
  String get errConnectFailed => '连接失败：请检查服务器地址与网络后重试';

  @override
  String get errConnectTimeout => '连接超时：服务器没有及时响应，请检查网络后重试';

  @override
  String get errCannotReachServer => '无法连接到服务器：请检查地址与网络';

  @override
  String get errBadCertificate => '服务器证书校验未通过';

  @override
  String get errAbnormalResponse => '服务器返回了异常的响应';

  @override
  String errHttpStatus(Object code) {
    return '服务器返回 HTTP $code';
  }

  @override
  String get errCancelled => '操作已取消';

  @override
  String get errNetworkConnectFailed => '网络连接失败：请检查网络后重试';

  @override
  String get errNetworkUnreachable => '网络不可达：请检查 Wi-Fi 或移动数据';

  @override
  String get errTlsHandshakeFailed => '与服务器的 TLS 握手失败（证书或代理问题）';

  @override
  String get errNetworkRequestFailed => '网络请求失败：请稍后重试';

  @override
  String get errBadDataFormat => '数据格式不正确，无法处理';

  @override
  String get errFileIoFailed => '文件读写失败：请检查存储空间与权限';

  @override
  String get errOperationTimeout => '操作超时：请稍后重试';

  @override
  String errDsmCodeWithDetail(Object code, Object detail) {
    return 'DSM $code：$detail';
  }

  @override
  String get fsG4SafOnDemandTitle => '系统选择器 · 按需下载';

  @override
  String get fsG4SafOnDemandSection => '系统「文件」集成';

  @override
  String get fsG4SafOnDemandTurnOn => '启用按需下载';

  @override
  String get fsG4SafOnDemandTurnOff => '关闭按需下载';

  @override
  String fsG4SafOnDemandOnDesc(String cachedBytes) {
    return '已配置：打开云端文件时会自动登录并下载（缓存 $cachedBytes 字节）';
  }

  @override
  String get fsG4SafOnDemandOffDesc => '没配置时，系统「文件」里只有已下载的离线文件能打开';

  @override
  String get fsG4SafOnDemandClearCache => '清理按需下载缓存';

  @override
  String fsG4SafOnDemandCacheCleared(String freed) {
    return '已释放缓存（约 $freed 字节）';
  }

  @override
  String get fsG4SafOnDemandClearCacheDesc => '删除“打开那一刻下载”临时落盘的文件（不影响已标为离线的文件）';

  @override
  String get fsG4SafOnDemandNeedPassword => '这条记录没有保存密码（或密码解不开）⇒ 无法让系统选择器自己登录。';

  @override
  String get fsG4SafOnDemandEnabled => '已启用：系统「文件」里打开 Drive 的云端文件时会自动下载';

  @override
  String get fsG4SafOnDemandDisabled => '已关闭并清除已保存的账号';

  @override
  String get fsG4SafOnDemandNotConfigured => '系统「文件」里仍显示未设置';

  @override
  String get adminGapAppPrivTitle => '应用权限';

  @override
  String get adminGapAuth2faTitle => '两步验证器';

  @override
  String get adminGapBeepBeeping => '正在蜂鸣';

  @override
  String get adminGapBeepNotBeeping => '未在蜂鸣';

  @override
  String get adminGapBeepStop => '停止';

  @override
  String get adminGapBeepStopped => '已停止蜂鸣';

  @override
  String get adminGapBeepTitle => '蜂鸣';

  @override
  String get adminGapBeepUnknown => '状态未知';

  @override
  String get adminGapDiskHealthTitle => '磁盘健康';

  @override
  String get adminGapEmptyList => '（空）';

  @override
  String get adminGapFindMeSupported => '本机支持';

  @override
  String get adminGapFindMeTitle => 'FindMe（定位我的 NAS）';

  @override
  String get adminGapFindMeUnknown => '状态未知';

  @override
  String get adminGapFindMeUnsupported => '本机不支持';

  @override
  String get adminGapGroupTitle => '群组';

  @override
  String get adminGapHddTitle => '硬盘管理';

  @override
  String get adminGapLoading => '读取中…';

  @override
  String get adminGapNeedsAdmin => '需要管理员权限才能查看此页面。';

  @override
  String get adminGapNetworkTitle => '网络';

  @override
  String get adminGapPackageTitle => '套件';

  @override
  String get adminGapPwdPolicyTitle => '密码策略';

  @override
  String get adminGapReadFailed => '读取失败。';

  @override
  String get adminGapServiceTitle => '服务状态';

  @override
  String get adminGapStorageTitle => '存储';

  @override
  String get adminGapSysInfoTitle => '系统信息';

  @override
  String get adminGapSysInfoUnknown => '系统信息未知';

  @override
  String get adminGapToolsEntryHint => '仅管理员可见';

  @override
  String get adminGapToolsTitle => '管理工具';

  @override
  String get adminGapUpgradeTitle => 'DSM 升级';

  @override
  String get adminGapUserTitle => '用户';

  @override
  String driveC1ActionFailed(String error) {
    return '操作失败：$error';
  }

  @override
  String get driveC1AdvanceSharing => '高级共享';

  @override
  String get driveC1AdvanceSharingEmpty => '还没有公开链接';

  @override
  String get driveC1AdvanceSharingIntro => '匿名公开链接：拿到链接的人无需账号即可访问；成员共享请用「分享」。';

  @override
  String get driveC1ClearLinkPassword => '清除访问密码？';

  @override
  String get driveC1ClearLinkPasswordHint => '清除后，任何拿到链接的人都能直接访问。';

  @override
  String get driveC1ClearNotifications => '清空通知';

  @override
  String get driveC1ClearNotificationsConfirm => '清空全部通知？';

  @override
  String get driveC1CloseLink => '关闭链接';

  @override
  String get driveC1CloseLinkBody => '关闭后该公开链接立即失效，拿到链接的人将无法访问。';

  @override
  String get driveC1CloseLinkConfirm => '关闭公开链接？';

  @override
  String get driveC1CloseRequest => '关闭';

  @override
  String get driveC1DeleteForever => '永久删除';

  @override
  String driveC1DeleteForeverBody(String name) {
    return '「$name」会被彻底删除，无法恢复。';
  }

  @override
  String get driveC1DeleteForeverConfirm => '永久删除？';

  @override
  String driveC1DeleteForeverFailed(String error) {
    return '永久删除失败：$error';
  }

  @override
  String get driveC1DeletedAt => '删除于';

  @override
  String get driveC1FileRequests => '请求文件';

  @override
  String get driveC1FileRequestsEmpty => '还没有请求文件链接';

  @override
  String get driveC1FileRequestsEntry => '管理你发出的\"请求文件\"链接：查看、关闭、重开、删除';

  @override
  String get driveC1LinkClosed => '已关闭链接';

  @override
  String driveC1LinkExpiry(String time) {
    return '有效期至 $time';
  }

  @override
  String get driveC1LinkExpiryAdd => '添加有效期';

  @override
  String get driveC1LinkExpiryClear => '取消有效期';

  @override
  String get driveC1LinkExpiryCleared => '已取消有效期';

  @override
  String get driveC1LinkExpiryEdit => '修改有效期';

  @override
  String get driveC1LinkExpiryNone => '不过期';

  @override
  String get driveC1LinkExpirySaved => '有效期已保存';

  @override
  String get driveC1LinkPassword => '访问密码';

  @override
  String get driveC1LinkPasswordCleared => '已清除访问密码';

  @override
  String get driveC1LinkPasswordHint => '留空并保存 = 不设密码';

  @override
  String get driveC1LinkPasswordOn => '已设置访问密码';

  @override
  String get driveC1LinkPasswordSaved => '访问密码已保存';

  @override
  String get driveC1Lock => '锁定';

  @override
  String driveC1LockFailed(String error) {
    return '操作失败：$error';
  }

  @override
  String get driveC1Locked => '已锁定';

  @override
  String get driveC1NewFileRequest => '请求文件';

  @override
  String get driveC1Notifications => '通知';

  @override
  String get driveC1NotificationsCleared => '已清空通知';

  @override
  String get driveC1NotificationsEmpty => '没有通知';

  @override
  String get driveC1NotificationsEntry => 'Drive 的上传/同步事件通知';

  @override
  String get driveC1OriginalPath => '原位置';

  @override
  String get driveC1ReopenRequest => '重开';

  @override
  String get driveC1RequestClosed => '已关闭';

  @override
  String driveC1RequestCreated(String url) {
    return '已创建请求链接：$url';
  }

  @override
  String driveC1RequestDeleteBody(String name) {
    return '「$name」的链接会失效。';
  }

  @override
  String get driveC1RequestDeleteConfirm => '删除这个请求文件链接？';

  @override
  String get driveC1RequestDeleted => '已删除';

  @override
  String get driveC1RequestReopened => '已重开';

  @override
  String get driveC1RequestTitleHint => '例如：交作业';

  @override
  String get driveC1RequestUnlock => '请求解锁';

  @override
  String driveC1RestoreOneFailed(String error) {
    return '恢复失败：$error';
  }

  @override
  String get driveC1Restored => '已恢复';

  @override
  String driveC1RoleUpdated(String role) {
    return '权限已更新为「$role」';
  }

  @override
  String get driveC1TeamMembers => '团队成员';

  @override
  String get driveC1TeamMembersEmpty => '看不到成员';

  @override
  String get driveC1TeamMembersEntry => '查看团队文件夹里有哪些成员、各自什么角色';

  @override
  String get driveC1TeamMembersPick => '选一个团队文件夹查看成员';

  @override
  String get driveC1Unlock => '解锁';

  @override
  String get driveC1UnlockRequested => '已请求解锁';

  @override
  String get driveC1Unlocked => '已解锁';

  @override
  String get driveG4LocalFilesListFailed => '目录读取失败';

  @override
  String get driveGapEncryptedDoc => '加密的文档';

  @override
  String get driveGapEncryptedPassword => '口令';

  @override
  String get driveGapEncryptedPasswordConfirm => '确认口令';

  @override
  String get driveGapEncryptedPasswordEmpty => '口令不能为空';

  @override
  String get driveGapEncryptedPasswordMismatch => '两次输入的口令不一致';

  @override
  String get driveGapEncryptedPasswordTitle => '设置文档口令';

  @override
  String get driveGapEncryptedSheet => '加密的电子表格';

  @override
  String get driveGapEncryptedSlides => '加密的演示文稿';

  @override
  String get driveGapEncryptedTemplate => '从模板新建（加密）';

  @override
  String get driveGapNewEncrypted => '加密新建…';

  @override
  String get driveGapNewEncryptedHint => '文档 / 表格 / 演示文稿 / 模板 · 需设口令';

  @override
  String get driveGapNewFromTemplate => '从模板新建…';

  @override
  String get driveGapNewFromTemplateHint => '从官方模板库开始';

  @override
  String get driveGapNewOfficeDoc => 'Synology Office 文档';

  @override
  String get driveGapNewOfficeDocHint => '在线文档，可在任何设备继续编辑';

  @override
  String get driveGapNewOfficeSheet => 'Synology Office 电子表格';

  @override
  String get driveGapNewOfficeSheetHint => '在线表格，支持公式与协作';

  @override
  String get driveGapNewOfficeSlides => 'Synology Office 演示文稿';

  @override
  String get driveGapNewOfficeSlidesHint => '在线幻灯片，支持演示与协作';

  @override
  String driveGapOfficeNodeCreated(String name) {
    return '已创建「$name」';
  }

  @override
  String get driveGapOfficeNodeNoFolderId => '无法解析当前目录，新建未执行';

  @override
  String get driveGapTemplateParentUnresolved => '无法定位当前文件夹，模板创建已取消';

  @override
  String get driveP0PasswordLabel => '密码';

  @override
  String get driveP0PasswordSubmit => '打开';

  @override
  String get driveP0PasswordWrong => '密码错误。请再试一次。';

  @override
  String get fsC5Up => '上一级';

  @override
  String get fsGapSharePermanentEditNote =>
      '官方端编辑时不发送\"取消到期\"字段（该链接现有到期时间会被保留）；如需真正不过期，请删除后重新创建';

  @override
  String get imageEditSettingsEntry => 'AI 美化（图生图）';

  @override
  String get imageEditSettingsEntryOff => '已关闭（照片不会被发送）';

  @override
  String imageEditSettingsEntryOn(String backend, String count) {
    return '已启用 · $backend · $count';
  }

  @override
  String get imageEditSettingsLoadFailed => 'AI 美化设置读取失败';

  @override
  String get imageEditSettingsPageIntro =>
      '这里只配置「照片 AI 美化（图生图）」这一条通道：选中的照片会发往你填写的服务地址做重绘，不经过本应用的服务器。';

  @override
  String get imageEditSettingsSeparateNote =>
      '与「AI 服务」里的大语言模型档位（云端 / 端侧 / 内置摘要）各自独立，互不影响：改这里的后端与额度，不会动聊天用的模型。';

  @override
  String get pbStructure => '按日期分目录';

  @override
  String get pbStructureNone => '不建日期目录（none）：全部文件放在设备目录下';

  @override
  String get pbStructureYear => '按年（year）：设备目录 / 2026';

  @override
  String get pbStructureYearMonth => '按年 + 月（官方默认）：设备目录 / 2026 / 09';

  @override
  String get pbUploadQuality => '上传质量';

  @override
  String get pbUploadQualityHigh => '高（长边 2048）';

  @override
  String get pbUploadQualityHint => '压缩在手机本地完成（原图不压缩）；HEIC/RAW/视频一律原样上传';

  @override
  String get pbUploadQualityLow => '低（长边 1280）';

  @override
  String get pbUploadQualityMedium => '中（长边 1600）';

  @override
  String get pbUploadQualityOriginal => '原图';

  @override
  String get photoC2PhotoRequestCreate => '新建';

  @override
  String get photoC2PhotoRequestCreateHint => '建一个收图链接，外部访客无需账号即可上传';

  @override
  String get photoC2PhotoRequestEdit => '编辑照片请求';

  @override
  String get photoC2PhotoRequestSaved => '照片请求已保存';

  @override
  String get photoP0ActionRemoveSmart => '从该场景移除';

  @override
  String get photoP0ActionSetCover => '设为封面';

  @override
  String get photoP0ActionShare => '发送到';

  @override
  String get photoP0CoverSet => '封面已更新';

  @override
  String get photoP0PersonRename => '重命名人物';

  @override
  String get photoP0PersonRenamed => '人物已重命名';

  @override
  String get photoP0RemoveSmartBody => '只影响这个场景的归类，照片本身不会被删除，之后仍可在时间轴里看到。';

  @override
  String get photoP0RemoveSmartConfirm => '从该场景移除选中的照片？';

  @override
  String get photoP0ShareDone => '已交给系统分享';

  @override
  String get photoWave3CacheClear => '清理本机缓存';

  @override
  String get photoWave3CacheClearDesc =>
      '只清这台手机上的图片缓存，NAS 上的照片不会被删除；下次浏览会重新下载。';

  @override
  String get photoWave3CacheLimit => '本机缓存上限';

  @override
  String get photoWave3CacheLocalReading => '正在统计本机缓存…';

  @override
  String get common_cancel => '取消';

  @override
  String get common_save => '保存';

  @override
  String get deselectAll => '取消全选';

  @override
  String get driveCategoryEmpty => '这个分类里还没有文件';

  @override
  String get driveCategoryEmptyHint =>
      '分类按文件扩展名在本地归类（官方 Home 的分类图标同款做法），只统计\"最近\"里的文件';

  @override
  String get driveCategoryEntry => '分类浏览';

  @override
  String get driveCategoryError => '读取最近文件失败';

  @override
  String get driveCategoryTitle => '分类浏览';

  @override
  String get driveTaskDetailStale => '拿不到最新状态，上面是列表里的快照';

  @override
  String get driveTaskFieldCreated => '创建';

  @override
  String get driveTaskFieldErrors => '错误';

  @override
  String get driveTaskFieldFiles => '文件';

  @override
  String get driveTaskFieldFinished => '完成';

  @override
  String get driveTaskFieldId => '任务 ID';

  @override
  String get driveTaskFieldMessage => '说明';

  @override
  String get driveTaskFieldProgress => '进度';

  @override
  String get driveTaskFieldSize => '大小';

  @override
  String get driveTaskFieldStatus => '状态';

  @override
  String get driveTaskRemoveDoneBody =>
      '只是把记录从任务列表里清掉（Tasks/delete），不影响已经传好的文件。';

  @override
  String get driveTaskRemoveDoneTitle => '移除这条已完成任务？';

  @override
  String get driveTaskRemoveRunningBody =>
      '这条任务还在跑。Tasks/delete 只删记录，不会中止服务端正在进行的传输 —— 想真正停掉，要在源端处理。';

  @override
  String get driveTaskRemoveRunningTitle => '从列表移除这条任务？';

  @override
  String get driveTaskStatusFailed => '失败';

  @override
  String get driveTaskStatusFinished => '已完成';

  @override
  String get driveTaskStatusRunning => '进行中';

  @override
  String get driveTaskStatusUnknown => '未知';

  @override
  String get drive_pdf_export => '导出批注版 PDF';

  @override
  String get drive_pdf_export_failed => '导出失败';

  @override
  String get drive_pdf_highlight => '高亮';

  @override
  String get drive_pdf_ink => '手写/签名';

  @override
  String get drive_pdf_marks => '条批注';

  @override
  String get drive_pdf_no_page => '这份 PDF 没有可渲染的页面';

  @override
  String get drive_pdf_no_text_layer => '本页文字层不可用，按矩形高亮';

  @override
  String get drive_pdf_note => '便签';

  @override
  String get drive_pdf_pages => '页';

  @override
  String get drive_pdf_render_failed => '渲染失败';

  @override
  String get drive_pdf_save_drive => '保存到 Drive';

  @override
  String get drive_pdf_saved_drive => '已存回 Drive';

  @override
  String get drive_pdf_saved_local => '已导出';

  @override
  String get drive_pdf_undo => '撤销上一条';

  @override
  String get drive_pdf_writeback => '写回原文件（增量更新）';

  @override
  String get drive_pdf_writeback_failed => '写回失败';

  @override
  String get drive_pdf_written_drive => '已写回原文件（Drive 新版本）';

  @override
  String get drive_pdf_written_local => '已写回';

  @override
  String get drive_sync_add => '新建同步任务';

  @override
  String get drive_sync_auto => '自动同步';

  @override
  String get drive_sync_check => '立即检查';

  @override
  String get drive_sync_check_title => '同步检查结果';

  @override
  String get drive_sync_conflict => '冲突';

  @override
  String get drive_sync_delete => '删除';

  @override
  String get drive_sync_download => '待下载';

  @override
  String get drive_sync_edit => '编辑';

  @override
  String get drive_sync_empty => '还没有同步任务。新建后可以对照本地文件夹与 Drive 的差异。';

  @override
  String get drive_sync_execute => '立即执行';

  @override
  String get drive_sync_executed => '已执行';

  @override
  String get drive_sync_failed => '失败';

  @override
  String get drive_sync_ignore_remove => '忽略本地删除（不删远端）';

  @override
  String get drive_sync_interval => '间隔';

  @override
  String get drive_sync_load_failed => '读不到同步任务';

  @override
  String get drive_sync_local => '本地文件夹';

  @override
  String get drive_sync_no_execute => '这里只做差异检查：不会搬运文件，也没有后台常驻同步。';

  @override
  String get drive_sync_remote => '远端文件夹';

  @override
  String get drive_sync_remove => '待删除';

  @override
  String get drive_sync_title => '同步任务';

  @override
  String get drive_sync_upload => '待上传';

  @override
  String get drive_sync_watch_no_native =>
      '已开始监听本地变化（App 存活期间）；系统未允许后台常驻监听，App 被杀后需重新开启';

  @override
  String get drive_sync_watch_ran => '自动同步';

  @override
  String get drive_sync_watch_skip => '跳过';

  @override
  String get drive_sync_watch_start => '监听本地变化';

  @override
  String get drive_sync_watch_started => '已开始监听本地变化（App 在前台/后台存活期间）';

  @override
  String get drive_sync_watch_stop => '停止监听';

  @override
  String get drive_sync_watch_stopped => '已停止监听';

  @override
  String get fsDownloadTaskSaveFailed => '存入系统「下载」目录失败';

  @override
  String get fsDownloadTaskSaveOk => '已存到系统「下载」目录，可在系统「文件」App 里找到';

  @override
  String get fsDownloadTaskSaveToLocal => '存到本机';

  @override
  String fsDownloadTaskSavedToPath(Object path) {
    return '已保存到 $path';
  }

  @override
  String get fsDownloadTaskSaveLocalFailed => '保存到本机失败';

  @override
  String get fsDownloadTaskSaveToDownloads => '存到系统「下载」';

  @override
  String get fsDownloadTaskSaveUnsupported => '这台设备不支持直接写入系统「下载」目录';

  @override
  String get fsLocalPhotosEmpty => '这台手机上没有找到照片';

  @override
  String get fsLocalPhotosNeedPermission => '需要相册权限才能读取本机照片，请到系统设置里授权';

  @override
  String get fsLocalPhotosPickFailed => '读取本机照片失败';

  @override
  String get fsLocalPhotosTitle => '上传本机照片到当前目录';

  @override
  String fsLocalPhotosUploaded(String name) {
    return '已上传 $name';
  }

  @override
  String fsLocalPhotosUploading(String name) {
    return '正在上传 $name';
  }

  @override
  String get noteLeaveEncryptCancel => '取消';

  @override
  String get noteLeaveEncryptOk => '确定';

  @override
  String get officeDocEnterEdit => '编辑';

  @override
  String get officeDocExitEdit => '完成编辑（回到标准排版）';

  @override
  String get officeDocLayoutFallback =>
      '未能读取标准 Office 格式，已改用兼容排版——字号、缩进、列宽可能与原版有差异。';

  @override
  String get officeDocNoContentHint =>
      '在 Synology Office / WPS / Microsoft Word 里写点什么并保存，再回来下拉刷新即可看到。';

  @override
  String get officeDocNoteDismiss => '知道了';

  @override
  String get officeDocOpenInOffice => '用官方 Office 应用打开';

  @override
  String get officeSlidesDeckHideThumbs => '隐藏幻灯片列表';

  @override
  String get officeSlidesDeckShowThumbs => '显示幻灯片列表';

  @override
  String get selectAll => '全选';

  @override
  String selectedCount(String n) {
    return '已选 $n 项';
  }

  @override
  String get sortResetOnError => '重置排序为「默认排序」并重试';

  @override
  String aiBlockedModelsTitleUndetermined(int n) {
    return '无法验证是否适配的模型（$n）';
  }

  @override
  String get aiBlockedReasonUndetermined =>
      '无法验证是否适配：未能读取本机硬件信息（本平台尚无硬件探测桥），因此不发起下载。';

  @override
  String get aiDeviceModelUnverifiable => '无法验证该模型是否适配本机，已取消下载';

  @override
  String get officeLoadErrNoLinkId => '打不开这个文档：服务端没有返回它的永久链接。';

  @override
  String get officeLoadErrNotConnected => '打不开这个文档：尚未连接到服务器。';

  @override
  String get officeLoadErrShape => '打不开这个文档：服务端返回的内容格式无法识别。可以试试「只读预览」。';

  @override
  String get officeLoadErrFetchAck => '打不开这个文档：服务端回包不完整。';

  @override
  String get officeLoadErrNoObjectId => '打不开这个文档：缺少文档内部 id。';

  @override
  String fileUploadLocalPhotoFromDevice(String target) {
    return '从本机相册选照片传到「$target」';
  }

  @override
  String get passcodeReauthAlways => '每次都要求';

  @override
  String passcodeReauthMinutes(int minutes) {
    return '$minutes 分钟后';
  }

  @override
  String mediaResumedFrom(String time) {
    return '已从 $time 继续播放';
  }

  @override
  String get mediaStartOver => '从头播放';

  @override
  String get trayShowMainWindow => '显示主窗口';
}
