// 使用分析的**可本地化标签**（分析引擎与「使用分析」页共用）。
//
// `usage_event.dart` 是纯 Dart（不依赖 Flutter），枚举上的 `label` 只作**中文回落**
// （落库常量、老测试、无 context 的地方还用得上）；要按语言取文案时统一走这里。
import '../../core/i18n/l10n.dart';
import 'usage_event.dart';

extension UsageModuleLabelX on UsageModule {
  /// 本地化模块名；`drive`/`office`/`audio`/`media`/`mailplus` 是品牌/专有名词，
  /// 沿用 [label] 原样。
  String labelIn(AppText t) => switch (this) {
    UsageModule.workspace => t.navWorkspace,
    UsageModule.files => t.navFiles,
    UsageModule.drive => label,
    UsageModule.notes => t.wsNotes,
    UsageModule.photos => t.navPhotos,
    UsageModule.calendar => t.wsCalendar,
    UsageModule.contacts => t.wsContacts,
    UsageModule.chat => t.navChat,
    UsageModule.search => t.calEnvSearch,
    UsageModule.reader => t.usageModReader,
    UsageModule.office => label,
    UsageModule.settings => t.meSettings,
    UsageModule.audio => label,
    UsageModule.media => t.usageModMedia,
    UsageModule.ai => t.usageModAi,
    UsageModule.downloads => t.usageModDownloads,
    UsageModule.admin => t.usageModAdmin,
    UsageModule.surveillance => t.usageModSurveillance,
    UsageModule.mailplus => label,
    UsageModule.unattributed => t.trafficModUnattributed,
  };
}

extension UsageActionLabelX on UsageAction {
  /// 本地化动作名
  String labelIn(AppText t) => switch (this) {
    UsageAction.open => t.fileOpen,
    UsageAction.preview => t.notePreview,
    UsageAction.search => t.calEnvSearch,
    UsageAction.upload => t.dtoActionUpload,
    UsageAction.download => t.dtoActionDownload,
    UsageAction.create => t.calNew,
    UsageAction.edit => t.calEditLabel,
    UsageAction.delete => t.dtoActionDelete,
    UsageAction.share => t.noteShare,
    UsageAction.addLabel => t.usageActLabel,
    UsageAction.star => t.driveStar,
    UsageAction.switchSection => t.usageActSwitchSection,
    UsageAction.openExternal => t.usageActOpenExternal,
    UsageAction.bookmark => t.usageActBookmark,
    UsageAction.play => t.fileMediaPlay,
    UsageAction.exportFile => t.usageActExport,
    UsageAction.restore => t.noteRestore,
    UsageAction.move => t.dtoActionMove,
    UsageAction.rename => t.photoRename,
    UsageAction.sync => t.usageActSync,
    UsageAction.copy => t.dtoActionCopy,
    UsageAction.failure => t.usageActFailure,
    UsageAction.view => t.usageActView,
    UsageAction.switchView => t.usageActSwitchView,
    UsageAction.filter => t.usageActFilter,
    UsageAction.sort => t.usageActSort,
    UsageAction.select => t.usageActSelect,
    UsageAction.complete => t.usageActComplete,
    UsageAction.abandon => t.usageActAbandon,
    UsageAction.start => t.usageActStart,
    UsageAction.pause => t.usageActPause,
    UsageAction.resume => t.usageActResume,
    UsageAction.audition => t.usageActAudition,
    UsageAction.vote => t.usageActVote,
    UsageAction.switchLanguage => t.usageActSwitchLanguage,
  };
}

/// `hourBand()` 的返回值是**聚合用的中文常量**（`UsageStats.byHourBand` 的 key，
/// 老测试直接断言中文），显示时用这个映射取译文；认不出的**原样返回**。
String usageHourBandLabel(String band, AppText t) => switch (band) {
  '深夜(0-6)' => t.usageBandLateNight,
  '早晨(6-9)' => t.usageBandMorning,
  '上午(9-12)' => t.usageBandForenoon,
  '中午(12-14)' => t.usageBandNoon,
  '下午(14-18)' => t.usageBandAfternoon,
  '晚上(18-22)' => t.usageBandEvening,
  '夜里(22-24)' => t.usageBandNight,
  _ => band,
};

/// 失败原因码 → **用户文案**。
///
/// ★★ r343 **D47**：这里原来对认不出的码 `_ => id` **原样返回**，设计意图是
/// "仍是稳定码，能分组统计" —— 但本函数的输出是**用户文案**，于是真机逐字看到
/// `其它原因：聊天·load_posts`（snake_case 方法名，§2.0.47）。
/// ⇒ **稳定码归稳定码（`UsageDetailKeys.reason`／`evidence`／DB 里原样保留，照样能分组），
///   用户文案归用户文案**：认不出的一律落 [AppText.usageFailOther]（「其它原因」）。
/// ★ 为什么不落 `usageFailUnknown`：「不知道」与「有码但还没写专文」是**两回事**，
///   前者是 `unknown` 这个码本身，后者是本分支（§2.0.26 同型：别把两种语义并成一句）。
String usageFailureReasonLabel(String id, AppText t) => switch (id) {  'unknown' => t.usageFailUnknown,
  'offline' => t.usageFailOffline,
  'network' => t.usageFailNetwork,
  'timeout' => t.usageFailTimeout,
  'auth' => t.usageFailAuth,
  'permission' => t.usageFailPermission,
  'not_found' => t.usageFailNotFound,
  'unsupported' => t.usageFailUnsupported,
  'decode' => t.usageFailDecode,
  'tls' => t.usageFailTls,
  'storage' => t.usageFailStorage,
  'conflict' => t.usageFailConflict,
  'server' => t.usageFailServer,
  'cancelled' => t.usageFailCancelled,
  _ => t.usageFailOther,
};

/// 视图/模式 id → 文案（`grid`/`list`/`timeline`/`lyrics`/`visualizer`/`month`…）
String usageViewModeLabel(String id, AppText t) => switch (id) {
  'grid' => t.usageViewGrid,
  'list' => t.usageViewList,
  'timeline' => t.usageViewTimeline,
  'month' => t.usageViewMonth,
  'week' => t.usageViewWeek,
  'agenda' => t.usageViewAgenda,
  'lyrics' => t.usageViewLyrics,
  'visualizer' => t.usageViewVisualizer,
  'player' => t.usageViewPlayer,
  _ => id.isEmpty ? t.usageViewOther : id,
};

/// 聚合键 `module.view` / `module.screen` → 可读标签（`相册·时间线`）。
/// 认不出模块/视图时原样返回 id（宁可显示稳定 id，也不猜）。
String usageModuleKeyLabel(String key, AppText t) {
  final i = key.indexOf('.');
  if (i <= 0) return key;
  final mod = UsageModule.byId(key.substring(0, i))?.labelIn(t) ?? key.substring(0, i);
  final rest = key.substring(i + 1);
  return '$mod · ${usageViewModeLabel(rest, t)}';
}

/// 事件 `objectType`（**对象类型**）→ 用户文案（r343 D47）。
///
/// ★ 这个位是**混合**的：既可能是**真扩展名**（文件的 `.pdf`/`.jpg`），
///   也可能是 `UsageModule` 的 id（`settings`/`drive`/`ai`），
///   还可能是各功能自己的**内部对象码**（`task`/`voice`/`rss`/`snooze_schedule`…，实测 35 种）。
///   原来「使用分析 → 最常处理」卡**直接把键印上屏** ⇒ 真机逐字
///   `最常处理 settings（95%）`、`其次是 folder、drive。`
///   —— 而同一屏「最常用」卡却是对的（`最常用：设置（95%）`）⇒ **一个语义两种口径**。
///
/// 兜底顺序（**每层都有理由**）：
///   ① 空 → 其它；
///   ② `UsageModule` 认得 → **复用模块本地化名**（与「最常用」卡同一口径，★ 不许再写第二份）；
///   ③ 内部对象码表 → 专门文案；
///   ④ `.pdf` 这种**带点真扩展名** → 去点大写（`PDF`）；
///   ⑤ 不认得的**扩展名形状**（`^[A-Za-z0-9]{1,5}$`）→ 原样大写（如 `heic`）；
///   ⑥ 其余（不认得的内部码，多半是 snake_case）→ 其它 —— **绝不把内部码印给用户**。
String objectTypeLabel(String id, AppText t) {
  if (id.isEmpty) return t.usageObjOther;
  final mod = UsageModule.byId(id);
  if (mod != null) return mod.labelIn(t);
  final known = _objectKindLabels[id];
  if (known != null) return known(t);
  if (id.startsWith('.')) return id.substring(1).toUpperCase();
  if (RegExp(r'^[A-Za-z0-9]{1,5}$').hasMatch(id)) return id.toUpperCase();
  return t.usageObjOther;
}

/// 内部对象码 → 文案。★ 新增 `objectType: 'xxx'` 字面量时**必须**在这里给文案：
/// `test/analytics_label_coverage_test.dart` 会扫真仓强制它（否则红）。
const Map<String, String Function(AppText)> _objectKindLabels = {
  'task': _objTask,
  'voice': _objVoice,
  'template': _objTemplate,
  'rss': _objRss,
  'note': _objNote,
  'emule': _objEmule,
  'video_frame': _objVideoFrame,
  'song': _objSong,
  'folder': _objFolder,
  'event': _objEvent,
  'dm': _objDm,
  'system': _objSystem,
  'message': _objMessage,
  'messages': _objMessages,
  'findme': _objFindme,
  'file': _objFile,
  'beep': _objBeep,
  'url': _objUrl,
  'magnet': _objMagnet,
  'tts': _objTts,
  'todo': _objTodo,
  'text': _objText,
  'snooze': _objSnooze,
  'snooze_schedule': _objSnoozeSchedule,
  'profile': _objProfile,
  'poll_results': _objPollResults,
  'month': _objMonth,
  'mail': _objMail,
  'contact': _objContact,
  'chapter': _objChapter,
  'camera': _objCamera,
  'bt': _objBt,
  'backup': _objBackup,
  'album_sort': _objAlbumSort,
  'ai_select': _objAiSelect,
  'nas': _objNas,
};

String _objTask(AppText t) => t.usageObjTask;
String _objVoice(AppText t) => t.usageObjVoice;
String _objTemplate(AppText t) => t.usageObjTemplate;
String _objRss(AppText t) => t.usageObjRss;
String _objNote(AppText t) => t.usageObjNote;
String _objEmule(AppText t) => t.usageObjEmule;
String _objVideoFrame(AppText t) => t.usageObjVideoFrame;
String _objSong(AppText t) => t.usageObjSong;
String _objFolder(AppText t) => t.usageObjFolder;
String _objEvent(AppText t) => t.usageObjEvent;
String _objDm(AppText t) => t.usageObjDm;
String _objSystem(AppText t) => t.usageObjSystem;
String _objMessage(AppText t) => t.usageObjMessage;
String _objMessages(AppText t) => t.usageObjMessages;
String _objFindme(AppText t) => t.usageObjFindme;
String _objFile(AppText t) => t.usageObjFile;
String _objBeep(AppText t) => t.usageObjBeep;
String _objUrl(AppText t) => t.usageObjUrl;
String _objMagnet(AppText t) => t.usageObjMagnet;
String _objTts(AppText t) => t.usageObjTts;
String _objTodo(AppText t) => t.usageObjTodo;
String _objText(AppText t) => t.usageObjText;
String _objSnooze(AppText t) => t.usageObjSnooze;
String _objSnoozeSchedule(AppText t) => t.usageObjSnoozeSchedule;
String _objProfile(AppText t) => t.usageObjProfile;
String _objPollResults(AppText t) => t.usageObjPollResults;
String _objMonth(AppText t) => t.usageObjMonth;
String _objMail(AppText t) => t.usageObjMail;
String _objContact(AppText t) => t.usageObjContact;
String _objChapter(AppText t) => t.usageObjChapter;
String _objCamera(AppText t) => t.usageObjCamera;
String _objBt(AppText t) => t.usageObjBt;
String _objBackup(AppText t) => t.usageObjBackup;
String _objAlbumSort(AppText t) => t.usageObjAlbumSort;
String _objAiSelect(AppText t) => t.usageObjAiSelect;
String _objNas(AppText t) => t.usageObjNas;
