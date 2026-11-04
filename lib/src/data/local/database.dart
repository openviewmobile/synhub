// 本地持久化 —— drift 数据库定义。
//
// 三张表分别镜像 [ChannelDto] / [UserDto] / [PostDto]，列名与字段一一对应：
//   * 时间戳（*_at / *time）统一为「毫秒时间戳」INTEGER；
//   * 布尔量用 BOOLEAN；
//   * `unreadThread` / `subscribes` / `members` 这类列表型字段以 JSON 文本存储，
//     具体编解码在 ChatStore 的映射函数里（见 chat_store.dart）。
//
// 这里只负责「表结构 + 连接」，业务语义（upsert / 合并）全部收在 ChatStore。
library;

import 'package:drift/drift.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:drift_flutter/drift_flutter.dart';

import '../../core/platform/app_paths.dart';

part 'database.g.dart';

/// 频道表 —— 对应 [ChannelDto]。
///
/// `unreadThread` 存 `{"threadId": count}`，`subscribes` / `members` 存
/// `[id, ...]` 的 JSON 文本。
@DataClassName('ChannelRow')
class ChannelRows extends Table {
  IntColumn get channelId => integer()();
  TextColumn get name => text().withDefault(const Constant(''))();
  TextColumn get purpose => text().withDefault(const Constant(''))();
  TextColumn get type => text().withDefault(const Constant(''))();
  BoolColumn get encrypted => boolean().withDefault(const Constant(false))();
  BoolColumn get isJoined => boolean().withDefault(const Constant(false))();
  BoolColumn get isStar => boolean().withDefault(const Constant(false))();

  IntColumn get unread => integer().withDefault(const Constant(0))();
  IntColumn get unreadMention => integer().withDefault(const Constant(0))();
  IntColumn get unreadComment => integer().withDefault(const Constant(0))();
  IntColumn get unreadMentionComment =>
      integer().withDefault(const Constant(0))();

  /// thread_id → 未读数，JSON 文本
  TextColumn get unreadThread => text().withDefault(const Constant('{}'))();

  /// 订阅的 thread/post id，JSON 数组文本
  TextColumn get subscribes => text().withDefault(const Constant('[]'))();

  /// 成员 user_id 列表，JSON 数组文本
  TextColumn get members => text().withDefault(const Constant('[]'))();

  /// 在这个频道里解不开消息的成员 user_id，JSON 数组文本
  /// （`client.channel.brokenuser` 加、`channel.rescue` 减）
  TextColumn get brokenUsers => text().withDefault(const Constant('[]'))();

  TextColumn get channelKeyEnc => text().withDefault(const Constant(''))();
  IntColumn get totalMemberCount => integer().withDefault(const Constant(0))();
  IntColumn get creatorId => integer().withDefault(const Constant(0))();

  IntColumn get lastPostAt => integer().withDefault(const Constant(0))();
  IntColumn get lastViewAt => integer().withDefault(const Constant(0))();
  IntColumn get lastViewCommentAt => integer().withDefault(const Constant(0))();
  IntColumn get channelOrderTime => integer().withDefault(const Constant(0))();
  IntColumn get hideGlobalAt => integer().withDefault(const Constant(0))();
  IntColumn get lastHideAt => integer().withDefault(const Constant(0))();

  TextColumn get notificationDesktop =>
      text().withDefault(const Constant(''))();
  TextColumn get notificationMobile => text().withDefault(const Constant(''))();
  BoolColumn get notificationMute =>
      boolean().withDefault(const Constant(false))();

  /// 频道里用过的标签，JSON 数组文本。
  ///
  /// 对应原版 `ChatChannel.hashtags`：进频道时（`enter` 成功后）由
  /// `Channel.Hashtag/list` 拉回来落库（`AccountManager.lambda$fetchChannelHashtag$10`
  /// → `DatabaseHelper.setChannelHashtags`），发消息时输入框的 `#` 联想就读这一列。
  TextColumn get hashtags => text().withDefault(const Constant('[]'))();

  @override
  Set<Column> get primaryKey => {channelId};
}

/// 用户表 —— 对应 [UserDto]。
@DataClassName('UserRow')
class UserRows extends Table {
  IntColumn get userId => integer()();
  TextColumn get username => text().withDefault(const Constant(''))();
  TextColumn get nickname => text().withDefault(const Constant(''))();
  TextColumn get type => text().withDefault(const Constant(''))();
  TextColumn get status => text().withDefault(const Constant(''))();
  TextColumn get humanType => text().withDefault(const Constant(''))();
  TextColumn get botType => text().withDefault(const Constant(''))();
  IntColumn get appId => integer().withDefault(const Constant(0))();
  IntColumn get dsmUid => integer().withDefault(const Constant(0))();
  IntColumn get avatarVersion => integer().withDefault(const Constant(0))();
  TextColumn get avatarColor => text().withDefault(const Constant(''))();
  TextColumn get email => text().withDefault(const Constant(''))();
  TextColumn get description => text().withDefault(const Constant(''))();
  TextColumn get publicKey => text().withDefault(const Constant(''))();
  TextColumn get privateKeyEnc => text().withDefault(const Constant(''))();
  BoolColumn get isDisabled => boolean().withDefault(const Constant(false))();
  BoolColumn get isDeleted => boolean().withDefault(const Constant(false))();
  BoolColumn get hasUrl => boolean().withDefault(const Constant(false))();

  /// 机器人附加信息 JSON：`slash_props` / `chatbot_props` / `bot_props`
  /// （`bot_type = slash` 的斜杠命令、chatbot 的欢迎语都在这里）。
  /// 原来只建了 botType 一列，斜杠命令读回来就没了 —— 跟消息的 props 同一类坑。
  TextColumn get botProps => text().withDefault(const Constant('{}'))();

  BoolColumn get isAlwaysOffline =>
      boolean().withDefault(const Constant(false))();
  IntColumn get createAt => integer().withDefault(const Constant(0))();
  IntColumn get updateAt => integer().withDefault(const Constant(0))();
  IntColumn get deleteAt => integer().withDefault(const Constant(0))();

  @override
  Set<Column> get primaryKey => {userId};
}

/// 消息表 —— 对应 [PostDto]。
///
/// `reactions` / `url_props` / `file_props` / `system_props` 这类嵌套结构原样存
/// JSON 文本：Phase 3 只需要展示与分页，建模成表反而绑死手（Phase 4/5 再抽）。
@DataClassName('PostRow')
class PostRows extends Table {
  /// 本地自增主键：乐观发送时 `post_id` 还是 0，只有 `tmp_post_id` 可用，
  /// 不能拿 post_id 当主键。
  IntColumn get id => integer().autoIncrement()();

  IntColumn get postId => integer().withDefault(const Constant(0))();
  IntColumn get channelId => integer()();
  IntColumn get creatorId => integer().withDefault(const Constant(0))();
  IntColumn get threadId => integer().withDefault(const Constant(0))();
  TextColumn get type => text().withDefault(const Constant('normal'))();
  TextColumn get message => text().withDefault(const Constant(''))();

  IntColumn get createAt => integer().withDefault(const Constant(0))();
  IntColumn get updateAt => integer().withDefault(const Constant(0))();
  IntColumn get deleteAt => integer().withDefault(const Constant(0))();
  IntColumn get lastCommentAt => integer().withDefault(const Constant(0))();
  IntColumn get lastPinAt => integer().withDefault(const Constant(0))();
  IntColumn get commentCount => integer().withDefault(const Constant(0))();

  BoolColumn get isStar => boolean().withDefault(const Constant(false))();
  BoolColumn get isSticky => boolean().withDefault(const Constant(false))();
  BoolColumn get encrypted => boolean().withDefault(const Constant(false))();
  BoolColumn get safeUrl => boolean().withDefault(const Constant(false))();
  BoolColumn get staticUrl => boolean().withDefault(const Constant(false))();
  TextColumn get forwardType => text().withDefault(const Constant('none'))();

  TextColumn get hashtags => text().withDefault(const Constant('[]'))();
  TextColumn get hashtagsAdditional =>
      text().withDefault(const Constant('[]'))();
  TextColumn get mentions => text().withDefault(const Constant('[]'))();
  TextColumn get reactions => text().withDefault(const Constant('[]'))();
  TextColumn get urlProps => text().withDefault(const Constant('[]'))();
  TextColumn get fileProps => text().withDefault(const Constant(''))();
  TextColumn get systemProps => text().withDefault(const Constant(''))();

  /// `props` 原文 JSON：投票（`vote`）、提醒（`remind_at`）等都在里面。
  /// 之前只挑了 encrypted/safe_url 几个字段建列，投票就没地方放了。
  TextColumn get props => text().withDefault(const Constant('{}'))();

  IntColumn get tmpPostId => integer().withDefault(const Constant(0))();

  /// 0 = 已同步；1 = 发送中；2 = 发送失败
  IntColumn get state => integer().withDefault(const Constant(0))();

  /// 去重键：服务端消息 `p:<post_id>`，本地待发消息 `t:<tmp_post_id>`。
  ///
  /// 为什么不直接对 `(channel_id, post_id)` 建唯一索引：**待发消息的 post_id 是 0**，
  /// 同一频道里两条待发消息会互撞（真踩过 UNIQUE constraint failed）。
  TextColumn get dedupeKey => text().unique()();

  @override
  Set<Column> get primaryKey => {id};
}

/// 文件条目表 —— 对应 [FileEntryDto]（File Station 的目录列表缓存）。
///
/// 跨家族架构：一个 sid 覆盖所有模块，但**服务器未必随时可达**
/// （外网/休眠/QuickConnect 打洞失败），所以目录列表要落库做 local-first。
///
/// * `path` 是服务端唯一键（`/home/Photos` 这种带共享名前缀的绝对路径），直接当主键；
/// * `parentPath` 用于"按目录分桶"：刷新时整桶替换，删掉的文件不会留在缓存里；
/// * `additional` 里的嵌套结构（`perm`/`time`/`owner`）拆成列存，
///   反正我们只关心 is_writable / mtime / owner 这几个。
@DataClassName('FileEntryRow')
class FileEntryRows extends Table {
  TextColumn get path => text()();

  /// 所属目录（列表接口的 `folder_path`）
  TextColumn get parentPath => text().withDefault(const Constant(''))();

  TextColumn get name => text().withDefault(const Constant(''))();
  BoolColumn get isDir => boolean().withDefault(const Constant(false))();

  IntColumn get size => integer().withDefault(const Constant(0))();

  /// 秒级时间戳（FileStation 给的就是秒）
  IntColumn get mtime => integer().withDefault(const Constant(0))();
  IntColumn get crtime => integer().withDefault(const Constant(0))();

  TextColumn get owner => text().withDefault(const Constant(''))();
  TextColumn get group => text().withDefault(const Constant(''))();
  TextColumn get realPath => text().withDefault(const Constant(''))();
  TextColumn get mountPointType => text().withDefault(const Constant(''))();
  TextColumn get description => text().withDefault(const Constant(''))();

  BoolColumn get canRead => boolean().withDefault(const Constant(false))();
  BoolColumn get canWrite => boolean().withDefault(const Constant(false))();
  BoolColumn get canExecute => boolean().withDefault(const Constant(false))();
  BoolColumn get disableDownload =>
      boolean().withDefault(const Constant(false))();
  BoolColumn get isWormShare => boolean().withDefault(const Constant(false))();

  /// WORM 状态线上值（`additional.worm_state`，0..9 的下标）。
  ///
  /// 为什么不直接存 `wormLocked` 布尔：官方 `WormVo.State` 里"锁定"只是
  /// `value & 32` 的一位，过期态（64/65）同样不可删改但语义不同，缓存原文比
  /// 缓存推导结果更抗变化。空串 = **未知**（老库升上来 / 服务端没给这个字段），
  /// 读取时还原成 `FileEntryDto.wormState == null` → [FileEntryDto.wormLocked]
  /// 为 false，保持 C5 的 fail-open（未知不拦）。
  TextColumn get wormState => text().withDefault(const Constant(''))();

  /// 这行是什么时候抓下来的（毫秒）—— UI 用它显示"缓存于 …"
  IntColumn get cachedAt => integer().withDefault(const Constant(0))();

  @override
  Set<Column> get primaryKey => {path};
}

/// 笔记正文缓存（P1 · NoteStation 的 local-first）。
///
/// 官方 DS note 是"全量同步进 SQLite + 本地查询"（`SyncPullCallable` 把
/// `Note/list` 的元数据全量 diff 进库，再补齐变化的正文）。我们照这个思路：
/// 列表元数据 + 正文都落库，断网时照样能看/搜。
@DataClassName('NoteCacheRow')
class NoteCacheRows extends Table {
  /// ★ N5（236 轮）：这条缓存属于**哪个 NAS 账号**（多 NAS 共用同一个库文件，
  /// 不隔离就会出现 A 的笔记在 B 登录时被 diff 当成「服务端删了」或被同 id 覆盖）。
  /// 默认空串 = 老库 / 未登录（兼容 v13 及以前）。
  TextColumn get accountKey => text().withDefault(const Constant(''))();
  TextColumn get objectId => text()();
  TextColumn get notebookId => text().withDefault(const Constant(''))();
  TextColumn get title => text().withDefault(const Constant(''))();
  TextColumn get brief => text().withDefault(const Constant(''))();

  /// 明文正文；加密笔记这里是**密文**（解密只在内存里做）
  /// 明文正文；加密笔记这里是**密文**（解密只在内存里做）
  TextColumn get content => text().withDefault(const Constant(''))();

  /// 正文是否已抓过（空字符串 ≠ "没有正文"，比如空笔记）
  BoolColumn get hasContent => boolean().withDefault(const Constant(false))();
  TextColumn get tagsJson => text().withDefault(const Constant('[]'))();
  TextColumn get attachmentsJson => text().withDefault(const Constant('{}'))();

  BoolColumn get encrypt => boolean().withDefault(const Constant(false))();
  BoolColumn get recycle => boolean().withDefault(const Constant(false))();
  TextColumn get ver => text().withDefault(const Constant(''))();
  IntColumn get ctime => integer().withDefault(const Constant(0))();
  IntColumn get mtime => integer().withDefault(const Constant(0))();
  TextColumn get ownerName => text().withDefault(const Constant(''))();

  /// 本地有未上传的改动（离线编辑过）
  BoolColumn get dirty => boolean().withDefault(const Constant(false))();

  /// 这行是什么时候同步下来的（毫秒）
  IntColumn get syncedAt => integer().withDefault(const Constant(0))();

  /// 主键 = (账号, id)：不同账号允许同 id 而不互相踩。
  @override
  Set<Column> get primaryKey => {accountKey, objectId};
}

/// 笔记本缓存
@DataClassName('NotebookCacheRow')
class NotebookCacheRows extends Table {
  /// ★ N5（236 轮）：这条缓存属于**哪个 NAS 账号**（多 NAS 共用同一个库文件，
  /// 不隔离就会出现 A 的笔记在 B 登录时被 diff 当成「服务端删了」或被同 id 覆盖）。
  /// 默认空串 = 老库 / 未登录（兼容 v13 及以前）。
  TextColumn get accountKey => text().withDefault(const Constant(''))();
  TextColumn get objectId => text()();
  TextColumn get title => text().withDefault(const Constant(''))();
  BoolColumn get preset => boolean().withDefault(const Constant(false))();
  BoolColumn get archive => boolean().withDefault(const Constant(false))();
  TextColumn get ver => text().withDefault(const Constant(''))();
  IntColumn get mtime => integer().withDefault(const Constant(0))();
  IntColumn get syncedAt => integer().withDefault(const Constant(0))();

  /// 主键 = (账号, id)：不同账号允许同 id 而不互相踩。
  @override
  Set<Column> get primaryKey => {accountKey, objectId};
}

/// 待办缓存
@DataClassName('TodoCacheRow')
class TodoCacheRows extends Table {
  /// ★ N5（236 轮）：这条缓存属于**哪个 NAS 账号**（多 NAS 共用同一个库文件，
  /// 不隔离就会出现 A 的笔记在 B 登录时被 diff 当成「服务端删了」或被同 id 覆盖）。
  /// 默认空串 = 老库 / 未登录（兼容 v13 及以前）。
  TextColumn get accountKey => text().withDefault(const Constant(''))();
  TextColumn get objectId => text()();
  TextColumn get title => text().withDefault(const Constant(''))();
  TextColumn get comment => text().withDefault(const Constant(''))();
  BoolColumn get done => boolean().withDefault(const Constant(false))();
  BoolColumn get star => boolean().withDefault(const Constant(false))();
  IntColumn get priority => integer().withDefault(const Constant(-1))();
  IntColumn get dueDate => integer().withDefault(const Constant(-1))();
  IntColumn get reminderOffset => integer().withDefault(const Constant(0))();
  TextColumn get noteId => text().withDefault(const Constant(''))();
  TextColumn get parentId => text().withDefault(const Constant(''))();
  BoolColumn get dirty => boolean().withDefault(const Constant(false))();
  IntColumn get syncedAt => integer().withDefault(const Constant(0))();

  /// 主键 = (账号, id)：不同账号允许同 id 而不互相踩。
  @override
  Set<Column> get primaryKey => {accountKey, objectId};
}

/// 「离线时做的写操作」队列 —— 联网后按顺序重放。
///
/// 官方 DS note 有一个 `SyncProvider` 的 pending 表（`SyncCallable` 推本地改动，
/// 失败就留在库里下次再推）。我们只队列**写**：新建 / 保存 / 删除 / 待办勾选。
@DataClassName('NotePendingRow')
class NotePendingRows extends Table {
  IntColumn get id => integer().autoIncrement()();

  /// ★ N5：这条待推送动作属于**哪个 NAS 账号**（推错账号 = 把 A 的改动写到 B）
  TextColumn get accountKey => text().withDefault(const Constant(''))();

  /// `create` / `set` / `delete` / `todo_set` / `todo_create` / `todo_delete`
  TextColumn get kind => text()();
  TextColumn get objectId => text().withDefault(const Constant(''))();

  /// 请求参数（JSON）
  TextColumn get payloadJson => text().withDefault(const Constant('{}'))();
  IntColumn get createdAt => integer().withDefault(const Constant(0))();
}

/// 电子书阅读进度 —— 每本书记一行（key = 文件路径或 Drive 的 link_id）。
///
/// 存"读到第几章 + 章内位置（0..1）"两件事：章内位置用滚动百分比而不是
/// 字符偏移，因为正文是 Quill 渲染的、章节切分（锚点会把一章切开）会变，
/// 偏移量在不同版本的书上对不上，百分比总能落在"附近"。
@DataClassName('BookProgressRow')
class BookProgressRows extends Table {
  TextColumn get bookKey => text()();

  /// 书名（只为了在"继续阅读"里显示；不参与逻辑）
  TextColumn get title => text().withDefault(const Constant(''))();

  /// 文件扩展名 / 来源，用来恢复时挑对渲染器
  TextColumn get format => text().withDefault(const Constant(''))();

  IntColumn get chapter => integer().withDefault(const Constant(0))();
  RealColumn get scroll => real().withDefault(const Constant(0))();
  IntColumn get chapterCount => integer().withDefault(const Constant(0))();

  /// 最后读的时间（毫秒）
  IntColumn get updatedAt => integer().withDefault(const Constant(0))();

  /// "这本书怎么再打开"的定位串（v11）。
  ///
  /// FileStation 来源的书不用它（`bookKey` 里的路径就够了）；Drive 来源的书
  /// 需要它 —— 进阅读器时由 `FileBookStage.bytesUrl` 把现成的鉴权直链记下来，
  /// 工作台「继续阅读」才能不查目录、直接恢复到上次那一章。
  TextColumn get sourceUrl => text().withDefault(const Constant(''))();

  @override
  Set<Column> get primaryKey => {bookKey};
}

/// 电子书书签 / 划线（同一张表：有批注文字就是划线，没有就是书签）
@DataClassName('BookMarkRow')
class BookMarkRows extends Table {
  IntColumn get id => integer().autoIncrement()();
  TextColumn get bookKey => text()();
  IntColumn get chapter => integer().withDefault(const Constant(0))();

  /// 章内滚动百分比（0..1）
  RealColumn get scroll => real().withDefault(const Constant(0))();

  /// 摘录的原文（书签本身也存一段上下文，列表里能认出来）
  TextColumn get excerpt => text().withDefault(const Constant(''))();

  /// 用户写的批注（空 = 纯书签）
  TextColumn get note => text().withDefault(const Constant(''))();
  IntColumn get createdAt => integer().withDefault(const Constant(0))();
}

/// 相册「手机自动备份」的**每落点游标**（v12 新增）。
///
/// 为什么不能让两个落点共用一份游标：官方相机备份的落点是 Drive
/// （`/mydrive/PhotoBackup/<设备名>/`，`docs/drive-parity-audit.md:264`），
/// 我们历史上只支持 Synology Photos（`docs/photo-parity-audit.md` §4.2）。
/// 用户在本 App 里可以**选**落点 —— 两个落点各自的目标目录/去重集完全不同，
/// 若共用一份 `doneKeys`，切到 Drive 后就会认为"都备份过了"而**一张都不传**
/// （反向也一样）。所以每个落点一行、主键就是落点本身。
///
/// 选项（是否备份视频/仅 Wi-Fi/仅充电/息屏…）是**全局**的，仍留在既有
/// `key_value_rows` 的那份 JSON 里（`photo_backup_state`），不进这张表 ——
/// 这样"切换落点"只换游标，不丢用户偏好。
@DataClassName('PhotoBackupTargetRow')
class PhotoBackupTargetRows extends Table {
  /// `drive` / `synology_photos`
  TextColumn get destination => text()();

  /// 已成功备份的 `DeviceMediaAsset.stableKey` / 抽样 MD5，JSON 数组文本
  TextColumn get doneKeys => text().withDefault(const Constant('[]'))();

  /// 上次跑完的时间（毫秒；0 = 这个落点从没跑完过）
  IntColumn get lastFinishedAt => integer().withDefault(const Constant(0))();

  /// 目标定位串：Photos = `Browse.Folder` 的真实 id；Drive = 目录路径
  TextColumn get targetRef => text().withDefault(const Constant(''))();

  /// 给人看的目标名（相册名 / 目录名）
  TextColumn get targetName => text().withDefault(const Constant(''))();

  /// 这一行最后改动时间（毫秒）
  IntColumn get updatedAt => integer().withDefault(const Constant(0))();

  @override
  Set<Column> get primaryKey => {destination};
}

/// 简单键值表 —— 存那些不成表的小状态（E2EE 身份、口令标记等）。
///
/// E2EE 的身份是「一台机器一份」，不是聊天数据，所以没塞进 UserRows：
/// 服务器上的 `user_props.key_pair` 才是权威副本，这里只是本机缓存。
@DataClassName('KeyValueRow')
class KeyValueRows extends Table {
  TextColumn get key => text()();
  TextColumn get value => text().withDefault(const Constant(''))();

  @override
  Set<Column> get primaryKey => {key};
}

/// 应用本地库。`synhub.sqlite` 落在应用文档目录下。
@DriftDatabase(
  tables: [
    ChannelRows,
    UserRows,
    PostRows,
    KeyValueRows,
    FileEntryRows,
    NoteCacheRows,
    NotebookCacheRows,
    TodoCacheRows,
    NotePendingRows,
    BookProgressRows,
    BookMarkRows,
    PhotoBackupTargetRows,
  ],
)
class ChatDatabase extends _$ChatDatabase {
  ChatDatabase(super.e);

  @override
  int get schemaVersion => 14;

  /// v1 → v2：新增消息表（老库直接建表，不丢频道/用户数据）
  /// v2 → v3：消息表加 `props` 列（投票 / 提醒要用）
  /// v3 → v4：用户表加 `botProps` 列（斜杠命令 / chatbot 信息要用）
  /// v4 → v5：新增键值表（E2EE 身份：公钥 + 口令加密的私钥）
  /// v5 → v6：频道表加 `brokenUsers` 列（这个频道里谁能解开/解不开）
  /// v6 → v7：频道表加 `hashtags` 列（输入框 `#` 联想要用）
  /// v7 → v8：新增文件条目表（文件模块的目录缓存，local-first）
  /// v8 → v9：新增笔记 / 笔记本 / 待办 缓存表 + 离线写队列（笔记模块 local-first）
  /// v9 → v10：新增电子书阅读进度 / 书签表（阅读器 E1）
  /// v10 → v11：进度表加 `sourceUrl` 列（工作台「继续阅读」要能重开 Drive 的书）
  /// v11 → v12：新增相册备份**每落点游标**表（Drive / Synology Photos 各自独立，
  ///            切换落点不会复用对方游标；老库升上来表是空的，由 Dart 侧把
  ///            既有 `photo_backup_state` 里的旧游标迁进 Photos 落点）
  /// v12 → v13：文件条目表加 `worm_state` 列（WORM 锁定态要能跨"内存 → 缓存
  ///            表 → 浏览页"往返；以前只存了 `isWormShare`，老库升上来这一列
  ///            默认空串 = 未知，不改变 C5 的 fail-open 语义）
  /// v13 → v14：四张笔记表加 `account_key`（**多 NAS 隔离**，N5）。
  ///            笔记/笔记本/待办主键改成 (account_key, object_id) ⇒ 只能
  ///            `alterTable` 重建；待推送队列主键不变 ⇒ `addColumn`。
  ///            老行 `account_key` 用 SQL 补成**当前激活的 NAS id**
  ///            （读同库 `key_value_rows`），读不到留空串。
  /// 某张表当前**实际**有没有这一列。
  ///
  /// 迁移里为什么需要它：伪造老库的用例（以及某些手工改过的库）只把
  /// `user_version` 改小、列却还在 ⇒ 无条件 `addColumn`/`alterTable` 会
  /// "duplicate column name" 直接把打开库炸掉（236 轮实测）。
  /// 幂等判断比"猜测老库长什么样"可靠。
  Future<bool> _hasColumn(String table, String column) async {
    final rows = await customSelect("PRAGMA table_info('$table')").get();
    return rows.any((r) => r.read<String>('name') == column);
  }

  @override
  MigrationStrategy get migration => MigrationStrategy(
    onCreate: (m) async => m.createAll(),
    onUpgrade: (m, from, to) async {
      if (from < 2) await m.createTable(postRows);
      if (from < 3) {
        await m.addColumn(postRows, postRows.props);
      }
      if (from < 4) {
        await m.addColumn(userRows, userRows.botProps);
      }
      if (from < 5) {
        await m.createTable(keyValueRows);
      }
      // ⚠️ 这两条以前漏了：v6 的 `brokenUsers` 只写了版本号没写迁移，
      // 老库（v5）升上来会 "no such column: broken_users"。
      if (from < 6) {
        await m.addColumn(channelRows, channelRows.brokenUsers);
      }
      if (from < 7) {
        await m.addColumn(channelRows, channelRows.hashtags);
      }
      if (from < 8) {
        await m.createTable(fileEntryRows);
      }
      if (from < 9) {
        await m.createTable(noteCacheRows);
        await m.createTable(notebookCacheRows);
        await m.createTable(todoCacheRows);
        await m.createTable(notePendingRows);
      }
      if (from < 10) {
        await m.createTable(bookProgressRows);
        await m.createTable(bookMarkRows);
      }
      if (from < 11 && from >= 10) {
        // 从 v9 及更早升上来时，上面的 `createTable` 已经是当前 schema（含这一列），
        // 只有真正的 v10 老库才需要补列。
        await m.addColumn(bookProgressRows, bookProgressRows.sourceUrl);
      }
      // v12：相册备份的每落点游标表。纯新增表，老库的数据一行都不动；
      // 老 `photo_backup_state`（JSON）里的旧游标由 Dart 侧
      // `DriftPhotoBackupStore` 在首次读取时**补种**到 Photos 落点。
      if (from < 12) {
        await m.createTable(photoBackupTargetRows);
      }
      // v13：文件条目表补 `worm_state`。递增版本 + addColumn —— **不 drop/recreate**，
      // 老缓存行原样保留（旧行的新列取默认空串 = 未知态）。
      // ⚠️ `from >= 8`：文件条目表是 v8 才建的，`from < 8` 时上面的
      // `createTable(fileEntryRows)` 已经建出**当前 schema**（含这一列），
      // 再 addColumn 会 "duplicate column name"。只有真正 v8..v12 的老库才补列。
      if (from < 13 && from >= 8) {
        await m.addColumn(fileEntryRows, fileEntryRows.wormState);
      }
      // v14（N5 多账号隔离）：三张表主键变化只能重建；队列表主键没变。
      // ⚠️ `from >= 9`：这几张表 v9 才建，`from < 9` 时上面的 createTable
      // 已建出**当前 schema**（含 account_key），再 alter 会 duplicate column。
      if (from < 14 && from >= 9) {
        // ⚠️ 幂等守卫：见 [_hasColumn] 的说明。三张表的主键变化只能重建，
        // 但"已经是新 schema"的库绝不能重建（会丢数据/报重复列）。
        if (!await _hasColumn('note_cache_rows', 'account_key')) {
          await m.alterTable(
            TableMigration(
              noteCacheRows,
              newColumns: [noteCacheRows.accountKey],
            ),
          );
        }
        if (!await _hasColumn('notebook_cache_rows', 'account_key')) {
          await m.alterTable(
            TableMigration(
              notebookCacheRows,
              newColumns: [notebookCacheRows.accountKey],
            ),
          );
        }
        if (!await _hasColumn('todo_cache_rows', 'account_key')) {
          await m.alterTable(
            TableMigration(todoCacheRows, newColumns: [todoCacheRows.accountKey]),
          );
        }
        if (!await _hasColumn('note_pending_rows', 'account_key')) {
          await m.addColumn(notePendingRows, notePendingRows.accountKey);
        }
        // 老行归属：补成当前激活的 NAS id（同库键值表），读不到留空。
        for (final table in [
          'note_cache_rows',
          'notebook_cache_rows',
          'todo_cache_rows',
          'note_pending_rows',
        ]) {
          await customStatement(
            'UPDATE $table SET account_key = COALESCE('
            "(SELECT value FROM key_value_rows WHERE key = 'nas_active_id'), '') "
            "WHERE account_key = ''",
          );
        }
      }
    },
  );

  /// 打开（或创建）磁盘上的默认库。
  ///
  /// ★★ P0-2（Linux 站，第 109 轮）：`driftDatabase` 的默认实现用
  /// `getApplicationDocumentsDirectory()`；容器 / 最小 Linux 上没装
  /// `xdg-user-dirs`（没有 `~/.config/user-dirs.dirs`）⇒ 它抛
  /// `MissingPlatformDirectoryException` ⇒ **本地库在 Linux 上根本建不起来**
  /// （原始堆栈见 `docs/platform-linux.md` §8.4 缺陷 2）。
  /// 改走 [AppPaths.documentsDirectory]：非 Linux 与原来完全等价
  /// （异常原样重抛），Linux 按 XDG（`$XDG_DATA_HOME` → `~/.local/share` →
  /// `<home>`）回落并**降级不抛**。
  ///
  /// ★★ 第 336 轮（web 首屏 D34 的第三发）：**web 上必须把 `web:` 传上**。
  /// `drift_flutter` 在 web 上不给 `web:` 会**抛**
  /// `Invalid argument(s): When compiling to the web, the `web` parameter needs to be set.`
  /// （`drift_flutter-0.3.1/lib/src/web.dart:13`）—— 这是**启动期** provider
  /// 打开数据库的路径 ⇒ 整个 provider 进错误态、界面退化。
  /// 两个资产随包发：`web/sqlite3.wasm`（706,316 B）、`web/drift_worker.dart.js`（357,220 B）。
  /// `kIsWeb ? … : null` 里那个 `DriftWebOptions` 由 `drift_flutter` **自己**导出，
  /// 所以这里**不需要**条件导入（`drift/wasm.dart` 才需要）。
  factory ChatDatabase.open() => ChatDatabase(
    driftDatabase(
      name: 'synhub',
      native: DriftNativeOptions(
        databaseDirectory: AppPaths.documentsDirectory,
      ),
      web: kIsWeb
          ? DriftWebOptions(
              sqlite3Wasm: Uri.parse('sqlite3.wasm'),
              driftWorker: Uri.parse('drift_worker.dart.js'),
            )
          : null,
    ),
  );
}
