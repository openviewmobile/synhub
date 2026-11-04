// NoteStation 的 DTO（对照反编译 DS note 1.12.0 的 `vos/api/*Vo.java` 字段名）。
//
// 服务端这些接口的字段**经常缺省**（列表接口不返回 `content`、共享笔记没有
// `owner`…），所以解析一律走容错取值：缺了就是默认值，不抛。
import 'package:meta/meta.dart';

import '../../core/i18n/data_text.dart';
import 'note_acl_dto.dart';

/// 笔记本（`SYNO.NoteStation.Notebook/list`）
@immutable
class NotebookDto {
  const NotebookDto({
    required this.objectId,
    required this.title,
    this.parentId,
    this.archive = false,
    this.preset = false,
    this.stack,
    this.mtime = 0,
    this.ctime = 0,
    this.ver = '',
    this.individualShared = false,
    this.ownerName,
  });

  final String objectId;
  final String title;
  final String? parentId;

  /// 归档笔记本（默认列表用 `filter={"archive":false}` 过滤掉）
  final bool archive;

  /// 系统预置（"我的笔记本"之类，不允许删）
  final bool preset;
  final String? stack;
  final int mtime;
  final int ctime;
  final String ver;
  final bool individualShared;
  final String? ownerName;

  /// 界面上显示的笔记本名。
  ///
  /// 真机实测：**"预设"（preset）笔记本的 `title` 是空串**（服务端只给
  /// `preset: true`），官方客户端用语言包里的 `[notebook] default` 显示
  /// —— 中文是「我的记事本」（`ui/texts/chs/strings`）。
  ///
  /// 数据层走 `data_text.dart`（docs §4.6）；没装翻译器回落中文原文。
  String get displayTitle {
    if (title.trim().isNotEmpty) return title.trim();
    return preset
        ? dataText('dtoNotebookPreset', '我的记事本')
        : dataText('dtoNotebookUntitled', '未命名记事本');
  }

  static NotebookDto fromJson(Map<String, dynamic> j) => NotebookDto(
    objectId: asText(j['object_id']),
    title: asText(j['title']),
    parentId: asTextOrNull(j['old_parent_id']) ?? asTextOrNull(j['parent_id']),
    archive: asBool(j['archive']),
    preset: asBool(j['preset']),
    stack: asTextOrNull(j['stack']),
    mtime: asEpoch(j['mtime']),
    ctime: asEpoch(j['ctime']),
    ver: asText(j['ver']),
    individualShared: asBool(j['individual_shared']),
    ownerName: ownerNameOf(j['owner']),
  );
}

/// 笔记附件（`NoteVo.data.attachment` 里的一项，键是 `file_id`）
///
/// 字段照反编译的 `AttachmentVo`：name/size/md5/type/width/height/ref/extra…
/// 图片附件在正文里是 `<img …>`，靠 `ref`（Web 端保存过的是 `content_id`）
/// 指到这里的 `file_id`。
@immutable
class NoteAttachmentDto {
  const NoteAttachmentDto({
    required this.fileId,
    required this.name,
    this.size = 0,
    this.md5 = '',
    this.type = '',
    this.width = 0,
    this.height = 0,
    this.ref = '',
    this.extra = '',
    this.ctime = 0,
    this.mtime = 0,
  });

  final String fileId;
  final String name;
  final int size;
  final String md5;

  /// MIME（服务端可能不回；那时按扩展名猜）
  final String type;
  final int width;
  final int height;

  /// 上传时编辑器用的占位 ref（服务端一般会把它换成 `content_id`）
  final String ref;
  final String extra;
  final int ctime;
  final int mtime;

  static const _imageExt = {
    '.png',
    '.jpg',
    '.jpeg',
    '.gif',
    '.bmp',
    '.webp',
    '.heic',
    '.heif',
  };

  bool get isImage {
    if (type.startsWith('image/')) return true;
    final lower = name.toLowerCase();
    return _imageExt.any(lower.endsWith);
  }

  /// 人读的大小
  String get displaySize {
    if (size < 1024) return '$size B';
    if (size < 1024 * 1024) return '${(size / 1024).toStringAsFixed(1)} KB';
    return '${(size / 1024 / 1024).toStringAsFixed(1)} MB';
  }

  static NoteAttachmentDto fromJson(String fileId, Map<String, dynamic> j) =>
      NoteAttachmentDto(
        fileId: fileId,
        name: asText(j['name']),
        size: asEpoch(j['size']),
        md5: asText(j['md5']),
        type: asText(j['type']),
        width: asEpoch(j['width']),
        height: asEpoch(j['height']),
        ref: asText(j['ref']),
        extra: asText(j['extra']),
        ctime: asEpoch(j['ctime']),
        mtime: asEpoch(j['mtime']),
      );
}

/// 笔记封面缩略图（列表里的 `thumb`）
///
/// 真机实测（有图片附件的笔记）：`{name:"thumb", type:"image", ext:"png",
/// width:200, height:434, size:128657, md5:"…", thumb_source:"<附件 file_id>"}`。
/// 取图方式和正文图片一样：`Note/download`（`file_id = thumb_source`，`thumb=true`）。
@immutable
class NoteThumbDto {
  const NoteThumbDto({
    required this.source,
    this.type = '',
    this.ext = '',
    this.size = 0,
    this.width = 0,
    this.height = 0,
    this.md5 = '',
  });

  /// 对应的附件 `file_id`（服务端字段名就是 `thumb_source`）
  final String source;
  final String type;
  final String ext;
  final int size;
  final int width;
  final int height;
  final String md5;

  bool get isImage => type.startsWith('image');

  static NoteThumbDto? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final source = asText(raw['thumb_source']);
    if (source.isEmpty) return null;
    return NoteThumbDto(
      source: source,
      type: asText(raw['type']),
      ext: asText(raw['ext']),
      size: asEpoch(raw['size']),
      width: asEpoch(raw['width']),
      height: asEpoch(raw['height']),
      md5: asText(raw['md5']),
    );
  }
}

/// 笔记。
///
/// `content` 是**净化后的 HTML**（NoteStation 的编辑器就是 WebView + execCommand），
/// 列表接口不一定带 `content`，打开时才 `get` 全量；列表里会带一个 `thumb`
/// （封面缩略图，`thumb_source` 就是对应的附件 `file_id`）。
@immutable
class NoteDto {
  const NoteDto({
    required this.objectId,
    required this.title,
    this.parentId = '',
    this.content = '',
    this.brief = '',
    this.ctime = 0,
    this.mtime = 0,
    this.ver = '',
    this.encrypt = false,
    this.tags = const [],
    this.recycle = false,
    this.latitude,
    this.longitude,
    this.location,
    this.sourceUrl,
    this.ownerName,
    this.individualShared = false,
    this.individualJoined = false,
    this.hasContent = false,
    this.linkId = '',
    this.attachments = const {},
    this.thumb,
    this.acl = NoteAcl.none,
  });

  final String objectId;
  final String title;

  /// 所属笔记本 id（`parent_id`；老版本字段叫 `old_parent_id`）
  final String parentId;
  final String content;
  final String brief;
  final int ctime;
  final int mtime;

  /// 版本号，`set` 时必须回传（乐观锁）
  final String ver;
  final bool encrypt;
  final List<String> tags;
  final bool recycle;
  final double? latitude;
  final double? longitude;
  final String? location;
  final String? sourceUrl;
  final String? ownerName;
  final bool individualShared;
  final bool individualJoined;

  /// 本次响应里到底有没有 `content`（列表接口常常没有）
  final bool hasContent;

  /// `link_id`（Web 端附件直链 `/ns/dv/<link_id>/<ver>/<file_id>/<name>` 用）
  final String linkId;

  /// 附件表：`file_id` → 附件（官方 `NoteVo.data.attachment` 就是这个结构）
  final Map<String, NoteAttachmentDto> attachments;

  /// 列表里的封面缩略图（有图片附件的笔记才有）
  final NoteThumbDto? thumb;

  /// 共享 ACL（`acl` JSON 列；没共享时是空的 [NoteAcl.none]）
  final NoteAcl acl;

  /// 图片附件（正文插图渲染/相册式预览用）
  List<NoteAttachmentDto> get imageAttachments =>
      attachments.values.where((a) => a.isImage).toList(growable: false);

  /// 标题为空时界面上的占位（NoteStation 允许空标题）
  String get displayTitle =>
      title.trim().isEmpty ? dataText('dtoNoteUntitled', '无标题笔记') : title;

  /// 能不能共享。
  ///
  /// 加密笔记**不能**共享 —— 官方 Web 把笔记的加密状态一路传进右键菜单
  /// （`isEncryptedNote: !isMultiSelected && note.encrypt`）并对加密笔记走
  /// 单独的菜单分支，共享/公开分享都不提供（正文在服务端是密文，分享出去
  /// 别人也解不开）。这里照同一条规则在客户端挡住。
  bool get canShare => !encrypt;

  static NoteDto fromJson(Map<String, dynamic> j) {
    final tags = j['tag'];
    return NoteDto(
      objectId: asText(j['object_id']),
      title: asText(j['title']),
      parentId:
          asTextOrNull(j['parent_id']) ??
          asTextOrNull(j['old_parent_id']) ??
          '',
      content: asText(j['content']),
      brief: asText(j['brief']),
      ctime: asEpoch(j['ctime']),
      mtime: asEpoch(j['mtime']),
      ver: asText(j['ver']),
      encrypt: asBool(j['encrypt']),
      tags: tags is List
          ? tags.map(asText).where((e) => e.isNotEmpty).toList()
          : const [],
      recycle: asBool(j['recycle']),
      latitude: asDoubleOrNull(j['latitude']),
      longitude: asDoubleOrNull(j['longitude']),
      location: asTextOrNull(j['location']),
      sourceUrl: asTextOrNull(j['source_url']),
      ownerName: ownerNameOf(j['owner']),
      individualShared: asBool(j['individual_shared']),
      individualJoined: asBool(j['individual_joined']),
      hasContent: j.containsKey('content') && j['content'] != null,
      linkId: asText(j['link_id']),
      attachments: attachmentsOf(j['attachment']),
      thumb: NoteThumbDto.fromJson(j['thumb']),
      acl: NoteAcl.fromJson(j['acl']),
    );
  }

  NoteDto copyWith({
    String? title,
    String? parentId,
    String? content,
    String? ver,
    List<String>? tags,
    int? mtime,
    bool? hasContent,
    bool? encrypt,
    Map<String, NoteAttachmentDto>? attachments,
    NoteAcl? acl,
  }) => NoteDto(
    objectId: objectId,
    title: title ?? this.title,
    parentId: parentId ?? this.parentId,
    content: content ?? this.content,
    brief: brief,
    ctime: ctime,
    mtime: mtime ?? this.mtime,
    ver: ver ?? this.ver,
    encrypt: encrypt ?? this.encrypt,
    tags: tags ?? this.tags,
    recycle: recycle,
    latitude: latitude,
    longitude: longitude,
    location: location,
    sourceUrl: sourceUrl,
    ownerName: ownerName,
    individualShared: individualShared,
    individualJoined: individualJoined,
    hasContent: hasContent ?? this.hasContent,
    linkId: linkId,
    attachments: attachments ?? this.attachments,
    thumb: thumb,
    acl: acl ?? this.acl,
  );
}

/// 解 `attachment`（`{file_id: {…}}`）；容错老字段名
Map<String, NoteAttachmentDto> attachmentsOf(Object? raw) {
  if (raw is! Map) return const {};
  final out = <String, NoteAttachmentDto>{};
  raw.forEach((key, value) {
    if (value is! Map) return;
    final id = asTextOrNull(value['file_id']) ?? asText('$key');
    if (id.isEmpty) return;
    out[id] = NoteAttachmentDto.fromJson(id, Map<String, dynamic>.from(value));
  });
  return out;
}

/// 标签（`SYNO.NoteStation.Tag/list`）
@immutable
class TagDto {
  const TagDto({
    required this.tagId,
    required this.title,
    this.category = '',
    this.itemIds = const [],
    this.count = 0,
  });

  final String tagId;
  final String title;
  final String category;

  /// ⚠️ 服务端 `items` 是**用了这个标签的笔记 id 数组**，不是数字 —— 真机实测：
  /// `Tag/list` → `{tag_id: tag@1028, title: tag, items: [1028_R9e9u0SSQfyWJYplAK9h5]}`
  /// （见 `docs/api-server-authoritative.md` §6）。以前这里按 `int` 解析，
  /// `int.tryParse('[… ]')` 恒为 null → 0，于是标签页**永远显示"0 条笔记"**。
  final List<String> itemIds;

  /// 用了这个标签的笔记数（列表长度；个别版本直接给数字时用那个数字）
  final int count;

  static TagDto fromJson(Map<String, dynamic> j) {
    final raw = j['items'];
    final ids = raw is List
        ? [for (final e in raw) '$e'].where((e) => e.isNotEmpty).toList()
        : const <String>[];
    return TagDto(
      tagId: asText(j['tag_id']),
      title: asText(j['title']),
      category: asText(j['category']),
      itemIds: ids,
      count: raw is num ? raw.toInt() : ids.length,
    );
  }
}

/// 快捷方式（`SYNO.NoteStation.Shortcut/list` v1）。
///
/// 字段逐字来自官方 Android `vos/api/ShortcutListVo.java` 的
/// `ShortcutsDataVo.ShortcutVo`：`id` / `category` / `title` / `items` /
/// `owner` / `acl`。`category` 取值（`daos/ShortcutDao.Category`）：
/// `notebook` / `note` / `tag` / `stack` / `smart`。
///
/// ⚠️ `id` 是**服务端对象 id**（内部 id），只允许出现在 Key 与测试断言里，
/// 界面上一律用 [title]。
@immutable
class ShortcutDto {
  const ShortcutDto({
    required this.id,
    required this.category,
    required this.title,
    this.itemIds = const [],
    this.ownerName,
    this.acl = NoteAcl.none,
  });

  final String id;
  final String category;
  final String title;

  /// `items` 是"这个快捷方式指向的条目数组"（笔记/笔记本/标签 id）
  final List<String> itemIds;

  final String? ownerName;
  final NoteAcl acl;

  int get itemCount => itemIds.length;

  String get displayTitle =>
      title.trim().isEmpty ? dataText('dtoShortcutUntitled', '未命名') : title;

  static ShortcutDto fromJson(Map<String, dynamic> j) {
    final raw = j['items'];
    final ids = raw is List
        ? [for (final e in raw) '$e'].where((e) => e.isNotEmpty).toList()
        : const <String>[];
    return ShortcutDto(
      id: asText(j['id']),
      category: asText(j['category']).toLowerCase(),
      title: asText(j['title']),
      itemIds: ids,
      ownerName: ownerNameOf(j['owner']),
      acl: NoteAcl.fromJson(j['acl']),
    );
  }
}

/// 智能 / 条件笔记本的查询条件。
///
/// 字段逐字来自官方 [E2] `vos/api/SmartVo.java` 的内部类 `QueryVo`：
/// `parent_id(List<String>)` / `tag(List<String>)` / `mtime_end` / `mtime_start`
/// / `ctime_end` / `ctime_start` / `title` / `keyword` / `tag_operator`（`and`/`or`）。
///
/// 两个官方行为照抄：
/// * `tag` 里的每一项会把 `@<uid>` 后缀去掉（`QueryVo.getTag` 的
///   `lastIndexOf(64)` 截断，64 就是 `'@'`）；
/// * `tag_operator` 由布尔值决定：`true → "and"`，`false → "or"`
///   （`createQueryVo(..., z)`）。
/// ★★★ 第 316 轮真机缺陷：NoteStation 的时间字段一律 **epoch 秒**。
///
/// 真机自证（本次新建笔记）：`Note/create` 曾发
/// `DateTime.now().millisecondsSinceEpoch`（13 位），服务端把它当 **32 位整型**
/// 截断成 `1791483240000 % 2^32 = 481877568`，回读时按**秒**渲染 ⇒
/// 列表里这条笔记显示 **1985-04-10**（本应是今天）。
/// 同口径的另两边都按秒：显示侧 `formatFileTime(int seconds)`、
/// 高级搜索 `startOfDaySeconds`（官方 `AdvancedSearchTask#getTimeInMillis()/1000`）
/// ⇒ **写入侧必须同口径**，否则同一条笔记在不同页面显示不同年份。
///
/// 别再直接写 `.millisecondsSinceEpoch`（守卫 `test/note_epoch_seconds_test.dart`）。
int noteEpochSeconds([DateTime? at]) =>
    (at ?? DateTime.now()).millisecondsSinceEpoch ~/ 1000;

/// 显式传入的 epoch 值归一：**毫秒（≥ 1e11）截到秒**。
///
/// 写入边界再兜一层：调用方就算还在传 `DateTime.now().millisecondsSinceEpoch`，
/// 上线也一定是秒（服务端按 32 位整型存，毫秒会被截成 1985 那种垃圾值）。
int noteEpochSecondsNormalize(int epoch) =>
    epoch.abs() >= 100000000000 ? epoch ~/ 1000 : epoch;

@immutable
class NoteSmartQuery {
  const NoteSmartQuery({
    this.parentIds = const [],
    this.tags = const [],
    this.title,
    this.keyword,
    this.mtimeStart,
    this.mtimeEnd,
    this.ctimeStart,
    this.ctimeEnd,
    this.tagAndOperator = false,
  });

  /// 限定笔记本（`parent_id` 数组）
  final List<String> parentIds;
  final List<String> tags;
  final String? title;
  final String? keyword;
  final int? mtimeStart;
  final int? mtimeEnd;
  final int? ctimeStart;
  final int? ctimeEnd;

  /// `true` = 标签取交集（`and`），`false` = 并集（`or`）
  final bool tagAndOperator;

  static const String tagOperatorAnd = 'and';
  static const String tagOperatorOr = 'or';

  String get tagOperator => tagAndOperator ? tagOperatorAnd : tagOperatorOr;

  bool get isEmpty =>
      parentIds.isEmpty &&
      tags.isEmpty &&
      (title ?? '').isEmpty &&
      (keyword ?? '').isEmpty &&
      mtimeStart == null &&
      mtimeEnd == null &&
      ctimeStart == null &&
      ctimeEnd == null;

  /// Gson 形态（`null` 字段**不发** —— Gson 默认忽略 null）
  Map<String, dynamic> toJson() => {
    if (parentIds.isNotEmpty) 'parent_id': parentIds,
    if (tags.isNotEmpty) 'tag': tags,
    if (mtimeEnd != null) 'mtime_end': mtimeEnd,
    if (mtimeStart != null) 'mtime_start': mtimeStart,
    if (ctimeEnd != null) 'ctime_end': ctimeEnd,
    if (ctimeStart != null) 'ctime_start': ctimeStart,
    if ((title ?? '').isNotEmpty) 'title': title,
    if ((keyword ?? '').isNotEmpty) 'keyword': keyword,
    // 官方 `createQueryVo` **总是**写 tag_operator（and/or）
    'tag_operator': tagOperator,
  };

  static NoteSmartQuery fromJson(Object? raw) {
    if (raw is! Map) return const NoteSmartQuery();
    final op = asText(raw['tag_operator']);
    return NoteSmartQuery(
      parentIds: _stringList(raw['parent_id']),
      tags: _stringList(raw['tag']).map(normalizeTagId).toList(),
      title: asTextOrNull(raw['title']),
      keyword: asTextOrNull(raw['keyword']),
      mtimeStart: _intOrNull(raw['mtime_start']),
      mtimeEnd: _intOrNull(raw['mtime_end']),
      ctimeStart: _intOrNull(raw['ctime_start']),
      ctimeEnd: _intOrNull(raw['ctime_end']),
      tagAndOperator: op == tagOperatorAnd,
    );
  }

  /// 本地匹配（官方 App 就是"把条件存本地、在本地库里筛"）。
  ///
  /// 语义：所有**已设置**的条件都命中才算命中；标签按 [tagAndOperator]
  /// 决定"全含"还是"含任意一个"。未设置的条件不参与。
  bool matches(NoteDto note) {
    final kw = (keyword ?? '').trim().toLowerCase();
    if (kw.isNotEmpty) {
      final haystack = '${note.title}\n${note.brief}\n${note.tags.join(' ')}'
          .toLowerCase();
      if (!haystack.contains(kw)) return false;
    }
    final t = (title ?? '').trim().toLowerCase();
    if (t.isNotEmpty && !note.title.toLowerCase().contains(t)) return false;
    if (parentIds.isNotEmpty && !parentIds.contains(note.parentId)) {
      return false;
    }
    if (tags.isNotEmpty) {
      final noteTags = note.tags.map(normalizeTagId).toSet();
      final wanted = tags.map(normalizeTagId).toSet();
      final hit = tagAndOperator
          ? wanted.every(noteTags.contains)
          : wanted.any(noteTags.contains);
      if (!hit) return false;
    }
    if (mtimeStart != null && note.mtime < mtimeStart!) return false;
    if (mtimeEnd != null && note.mtime > mtimeEnd!) return false;
    if (ctimeStart != null && note.ctime < ctimeStart!) return false;
    if (ctimeEnd != null && note.ctime > ctimeEnd!) return false;
    return true;
  }

  /// 一句话描述条件（界面副标题/无障碍文案用；不参与匹配）
  String describe({String Function(String) tagLabel = _identity}) {
    final parts = <String>[];
    if ((keyword ?? '').isNotEmpty) parts.add(keyword!);
    if ((title ?? '').isNotEmpty) parts.add(title!);
    if (tags.isNotEmpty) {
      parts.add(tags.map(tagLabel).join(tagAndOperator ? ' & ' : ' | '));
    }
    if (parentIds.isNotEmpty) parts.add('${parentIds.length} notebooks');
    if (mtimeStart != null ||
        mtimeEnd != null ||
        ctimeStart != null ||
        ctimeEnd != null) {
      parts.add('date');
    }
    return parts.join(' · ');
  }

  static String _identity(String v) => v;

  @override
  bool operator ==(Object other) =>
      other is NoteSmartQuery &&
      _listEq(other.parentIds, parentIds) &&
      _listEq(other.tags, tags) &&
      other.title == title &&
      other.keyword == keyword &&
      other.mtimeStart == mtimeStart &&
      other.mtimeEnd == mtimeEnd &&
      other.ctimeStart == ctimeStart &&
      other.ctimeEnd == ctimeEnd &&
      other.tagAndOperator == tagAndOperator;

  @override
  int get hashCode => Object.hash(
    Object.hashAll(parentIds),
    Object.hashAll(tags),
    title,
    keyword,
    mtimeStart,
    mtimeEnd,
    ctimeStart,
    ctimeEnd,
    tagAndOperator,
  );

  static bool _listEq(List<String> a, List<String> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }

  static List<String> _stringList(Object? raw) {
    if (raw is! List) return const [];
    return [for (final e in raw) '$e'].where((e) => e.isNotEmpty).toList();
  }

  static int? _intOrNull(Object? raw) {
    if (raw == null) return null;
    if (raw is num) return raw.toInt();
    return int.tryParse('$raw');
  }
}

/// 去掉标签 id 的 `@<uid>` 后缀（官方 `QueryVo.getTag`）。
String normalizeTagId(String raw) {
  final at = raw.lastIndexOf('@');
  return at == -1 ? raw : raw.substring(0, at);
}

/// 智能笔记本（`SYNO.NoteStation.Smart/list`）
///
/// 字段照官方 `SmartVo.SmartDataVo`：`object_id/title/query/ctime/mtime/
/// category/link_id/perm/owner/acl`。
@immutable
class SmartNotebookDto {
  const SmartNotebookDto({
    required this.objectId,
    required this.title,
    this.query = const NoteSmartQuery(),
    this.ctime = 0,
    this.mtime = 0,
    this.category = '',
    this.linkId = '',
    this.perm = '',
    this.ownerName,
    this.acl = NoteAcl.none,
  });

  final String objectId;
  final String title;
  final NoteSmartQuery query;
  final int ctime;
  final int mtime;
  final String category;
  final String linkId;
  final String perm;
  final String? ownerName;
  final NoteAcl acl;

  String get displayTitle =>
      title.trim().isEmpty ? dataText('dtoSmartUntitled', '未命名智能笔记本') : title;

  static SmartNotebookDto fromJson(Map<String, dynamic> j) => SmartNotebookDto(
    objectId: asText(j['object_id']),
    title: asText(j['title']),
    query: NoteSmartQuery.fromJson(j['query']),
    ctime: asEpoch(j['ctime']),
    mtime: asEpoch(j['mtime']),
    category: asText(j['category']),
    linkId: asText(j['link_id']),
    perm: asText(j['perm']),
    ownerName: ownerNameOf(j['owner']),
    acl: NoteAcl.fromJson(j['acl']),
  );
}

/// 待办的优先级（Web 端 `Utils.getPriorityCode`：不是 1/2/3，传错服务端会回

/// `114 缺少必需参数` 这种完全对不上的错误码）
abstract final class TodoPriority {
  static const int none = -1;
  static const int low = 100;
  static const int medium = 200;
  static const int high = 300;

  /// `-1/100/200/300` → 界面文案
  ///
  /// 数据层走 `data_text.dart`（docs §4.6）；没装翻译器回落中文原文。
  static String label(int code) => switch (code) {
    low => dataText('dtoPriorityLow', '低'),
    medium => dataText('dtoPriorityMedium', '中'),
    high => dataText('dtoPriorityHigh', '高'),
    _ => dataText('dtoPriorityNone', '无'),
  };
}

/// 待办（`SYNO.NoteStation.Todo/list`）
@immutable
class TodoDto {
  const TodoDto({
    required this.objectId,
    required this.title,
    this.comment = '',
    this.done = false,
    this.star = false,
    this.priority = 0,
    this.dueDate = 0,
    this.reminderOffset = 0,
    this.noteId = '',
    this.parentId = '',
  });

  final String objectId;
  final String title;
  final String comment;
  final bool done;
  final bool star;
  final int priority;
  final int dueDate;
  final int reminderOffset;
  final String noteId;
  final String parentId;

  TodoDto copyWith({
    String? title,
    String? comment,
    bool? done,
    bool? star,
    int? priority,
    int? dueDate,
    int? reminderOffset,
    String? noteId,
    String? parentId,
  }) => TodoDto(
    objectId: objectId,
    title: title ?? this.title,
    comment: comment ?? this.comment,
    done: done ?? this.done,
    star: star ?? this.star,
    priority: priority ?? this.priority,
    dueDate: dueDate ?? this.dueDate,
    reminderOffset: reminderOffset ?? this.reminderOffset,
    noteId: noteId ?? this.noteId,
    parentId: parentId ?? this.parentId,
  );

  static TodoDto fromJson(Map<String, dynamic> j) => TodoDto(
    objectId: asText(j['object_id']),
    title: asText(j['title']),
    comment: asText(j['comment']),
    done: asBool(j['done']),
    star: asBool(j['star']),
    priority: asEpoch(j['priority']),
    dueDate: asEpoch(j['due_date']),
    reminderOffset: asEpoch(j['reminder_offset']),
    noteId: asText(j['note_id']),
    parentId: asText(j['parent_id']),
  );
}

/// `SYNO.NoteStation.Todo / list_timeout` 的回包。
///
/// 字段来自官方 Android `vos/api/TodoListVo.java` 的
/// `TodoListDataVo`：`count` / `offset` / `total` / `todos`（`todos` 与
/// `Todo/list` 同形）。**空回包没有 `todos` 键**——真机逐字：
/// `{"data":{"count":0,"offset":0,"total":0}}`。
@immutable
class NoteTimeoutTodos {
  const NoteTimeoutTodos({
    this.todos = const [],
    this.count = 0,
    this.total = 0,
  });

  final List<TodoDto> todos;
  final int count;
  final int total;

  bool get isEmpty => todos.isEmpty && count == 0;

  static NoteTimeoutTodos fromJson(Map<String, dynamic> data) {
    final raw = data['todos'];
    final todos = raw is List
        ? raw
              .whereType<Map>()
              .map((e) => TodoDto.fromJson(Map<String, dynamic>.from(e)))
              .toList(growable: false)
        : const <TodoDto>[];
    return NoteTimeoutTodos(
      todos: todos,
      count: asEpoch(data['count']),
      total: asEpoch(data['total']),
    );
  }
}

/// NoteStation 用户信息（`SYNO.NoteStation.Info/get`）
@immutable
class NoteInfoDto {
  const NoteInfoDto({
    required this.username,
    this.uid = 0,
    this.isAdmin = false,
    this.hash = '',
    this.version = '',
    this.allowShare = true,
    this.searchPrecisely = false,
  });

  final String username;
  final int uid;
  final bool isAdmin;
  final String hash;
  final String version;

  /// 服务端是否允许共享笔记
  final bool allowShare;
  final bool searchPrecisely;

  static NoteInfoDto fromJson(Map<String, dynamic> j) {
    final v = j['version'];
    final ver = v is Map
        ? '${asText(v['major'])}.${asText(v['minor'])}.${asText(v['build'])}'
        : '';
    return NoteInfoDto(
      username: asText(j['username']),
      uid: asEpoch(j['uid']),
      isAdmin: asBool(j['is_admin']),
      hash: asText(j['hash']),
      version: ver,
      allowShare: j['allow_share'] == null ? true : asBool(j['allow_share']),
      searchPrecisely: asBool(j['search_precisely']),
    );
  }
}

// ------------------------------------------------------------------ 容错取值

String asText(Object? v) => v == null ? '' : '$v';

String? asTextOrNull(Object? v) {
  if (v == null) return null;
  final s = '$v';
  return s.isEmpty ? null : s;
}

bool asBool(Object? v) {
  if (v is bool) return v;
  if (v is num) return v != 0;
  final s = '$v'.toLowerCase();
  return s == 'true' || s == '1';
}

int asEpoch(Object? v) {
  if (v is int) return v;
  if (v is num) return v.toInt();
  if (v == null) return 0;
  return int.tryParse('$v') ?? 0;
}

double? asDoubleOrNull(Object? v) {
  if (v == null) return null;
  if (v is num) return v.toDouble();
  return double.tryParse('$v');
}

/// `owner` 字段可以是 `{username: …}`，也可能是裸字符串
String? ownerNameOf(Object? v) {
  if (v == null) return null;
  if (v is Map) {
    final n = asTextOrNull(v['username']) ?? asTextOrNull(v['user']);
    return n;
  }
  return asTextOrNull(v);
}

/// `searchplace` 的 `location` 线参形态：**"纬度,经度"**（纬度在前）。
///
/// 逐字对齐官方 Web `Map.Panel.getSearchStore().listeners.beforeload`：
/// `t.setBaseParam("location", center.lat()+","+center.lng())`。
String noteLatLng(double latitude, double longitude) => '$latitude,$longitude';

/// `SYNO.NoteStation.Info / searchplace` 回包 `data[]` 的一条地点。
///
/// 字段逐字来自官方 Web `Map.Panel.getSearchStore()` 的
/// `new Ext.data.JsonReader({fields:["name","address","gps","placeID","type"]})`：
///   * `gps` 是 `{lat, lng}`（官方模板 `e.get("gps").lat`）；
///   * `type` ∈ `"search"`（地理编码命中）/ `"local"`（用户当前输入的原文，
///     官方在 `load` 里补一条 `{name:baseParams.query, address:"", gps:"",
///     placeID:"", type:"local"}`）。
///
/// ⚠️ `placeID` 只用于**数据层去重/测试断言**，**不上屏**（同内部 id 纪律）。
@immutable
class NotePlaceDto {
  const NotePlaceDto({
    required this.name,
    this.address = '',
    this.latitude,
    this.longitude,
    this.placeId = '',
    this.type = '',
  });

  final String name;
  final String address;
  final double? latitude;
  final double? longitude;
  final String placeId;
  final String type;

  /// 官方模板里的两个 `type` 字面量
  static const String typeSearch = 'search';
  static const String typeLocal = 'local';

  bool get isLocal => type == typeLocal;

  /// 这条结果带不带可用坐标（官方只有非空 `gps` 才会移动地图/落点）
  bool get hasGps => latitude != null && longitude != null;

  static NotePlaceDto fromJson(Map<String, dynamic> j) {
    final gps = j['gps'];
    double? lat;
    double? lng;
    if (gps is Map) {
      lat = asDoubleOrNull(gps['lat']);
      lng = asDoubleOrNull(gps['lng']);
    } else if (gps is List && gps.length >= 2) {
      // 容错：个别版本把 `gps` 发成 `[lat, lng]`
      lat = asDoubleOrNull(gps[0]);
      lng = asDoubleOrNull(gps[1]);
    }
    // 容错：坐标也可能直挂在结果对象上
    lat ??= asDoubleOrNull(j['latitude']);
    lng ??= asDoubleOrNull(j['longitude']);
    return NotePlaceDto(
      name: asText(j['name']),
      address: asText(j['address']),
      latitude: lat,
      longitude: lng,
      placeId: asText(j['placeID']),
      type: asText(j['type']),
    );
  }
}
