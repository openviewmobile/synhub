// `SYNO.Office.Node.Version/list` 的版本条目（Office 原生文档自己的版本历史）。
//
// 字段名来自 **官方 Office 3.8.0-22711 的 Web 前端**（`ui/dist/ui.doc.js` 的
// `SYNO.SDS.Office.History.Store`）：
//
// ```js
// getReader: new Ext.data.JsonReader({root:"versions", idProperty:"version",
//             fields:["author","version","mtime","editors","last_version","ver_name"]})
// getBaseParams: { object_id: Env.objectId,
//                  additional: {uid:true, name:true, nickname:<useNickname>} }
// ```
//
// 也和服务端 `.so` 的内联键吻合（`webapi/mgr/version/SYNO.Office.Node.Version.so`：
// `versions author commit_msg editors first_version count listable total version_info
// requester is_admin title users nickname`）。
//
// ⚠️ 与 Drive 的 `Revisions/*` **不是一回事**：`Revisions` 的 `version_id` 是服务端
// 全局变更号、只有"文件被覆盖"才有；Office 文档的版本是 Office 自己按"保存/命名版本"
// 记的，`version` 是 Office 的版本号（可命名、可恢复、可单独导出）。
import '../../core/i18n/data_text.dart';

class OfficeVersionDto {
  const OfficeVersionDto({
    required this.version,
    required this.author,
    required this.modifiedTime,
    required this.editors,
    required this.verName,
    required this.commitMsg,
    required this.firstVersion,
    required this.listable,
    required this.title,
  });

  /// Office 的版本号（`ver`，恢复/命名都用它）
  final String version;

  /// 作者显示名（`additional.name/nickname` 决定是昵称还是用户名）
  final String author;

  final DateTime? modifiedTime;

  /// 参与编辑的人（≥2 时 UI 显示"等人协作"）
  final List<String> editors;

  /// 命名版本的名称（空 = 自动版本）
  final String verName;

  /// 版本备注（把某个版本"命名"时填的备注；`.so` 里叫 `commit_msg`）
  final String commitMsg;

  /// 是否"第一个版本"（官方用它标"创建"）
  final bool firstVersion;

  /// 是否可下载/导出（服务端权限位；false 时不给下载入口）
  /// 服务端字段（`libsynoffice.so`）：官方前端**不用它控界面**，只做记录
  final bool listable;

  final String title;

  bool get hasName => verName.trim().isNotEmpty;

  /// 「保存的版本」列表里显示的名字：命名版本优先，否则版本号
  ///
  /// 数据层走 `data_text.dart`（docs §4.6）；没装翻译器回落中文原文。
  String get label =>
      hasName ? verName : dataText('dtoVersionUntitled', '未命名版本');

  static OfficeVersionDto fromJson(Map<String, dynamic> json) {
    final editors = <String>[];
    final rawEditors = json['editors'];
    if (rawEditors is List) {
      for (final e in rawEditors) {
        if (e is String && e.trim().isNotEmpty) {
          editors.add(e);
        } else if (e is Map) {
          final label = '${e['nickname'] ?? e['name'] ?? e['uid'] ?? ''}'
              .trim();
          if (label.isNotEmpty) editors.add(label);
        }
      }
    }
    // ⚠️ 真机（2026-09-20，Untitled.odoc）：`commit_msg` 回的是 **map**
    // （`{device: desktop, first_version: true, listable: …}`），不是人写的备注。
    // 直接 `${json['commit_msg']}` 会把 Dart 的 map 打印串摆到界面上（已修）。
    // `first_version`/`listable` 也可能挂在里面，所以两处都读。
    final commitRaw = json['commit_msg'];
    final commitMap = commitRaw is Map
        ? commitRaw.cast<String, dynamic>()
        : const <String, dynamic>{};
    return OfficeVersionDto(
      version: '${json['version'] ?? ''}',
      author: _authorLabel(json['author']),
      modifiedTime: _time(json['mtime']),
      editors: editors,
      verName: '${json['ver_name'] ?? ''}',
      commitMsg: _commitText(commitRaw),
      firstVersion:
          json['first_version'] == true || commitMap['first_version'] == true,
      listable: json['listable'] != false && commitMap['listable'] != false,
      title: '${json['title'] ?? commitMap['title'] ?? ''}',
    );
  }

  /// 备注只取**人写的文本**：官方把 `commit_msg` 当"提交信息"对象用，
  /// 里面除了文本还有 `device`/`first_version` 这类元数据。
  static String _commitText(Object? raw) {
    if (raw is String) return raw;
    if (raw is Map) {
      for (final key in const [
        'text',
        'msg',
        'message',
        'comment',
        'metatext',
      ]) {
        final v = raw[key];
        if (v is String && v.trim().isNotEmpty) return v.trim();
      }
    }
    return '';
  }

  static List<OfficeVersionDto> listFromJson(Map<String, dynamic> data) {
    final raw = data['versions'];
    if (raw is! List) return const [];
    return [
      for (final e in raw)
        if (e is Map) OfficeVersionDto.fromJson(e.cast<String, dynamic>()),
    ];
  }

  /// `author` 可能是字符串，也可能是 `{uid,name,nickname}`（`additional.uid/name/nickname`）
  static String _authorLabel(Object? raw) {
    if (raw is String) return raw;
    if (raw is Map) {
      return '${raw['nickname'] ?? raw['name'] ?? raw['uid'] ?? ''}'.trim();
    }
    return '';
  }

  /// `mtime` 官方给的是**秒**（Ext reader 直接喂给 `Date`，不是毫秒）
  static DateTime? _time(Object? raw) {
    if (raw is num) {
      final n = raw.toInt();
      if (n <= 0) return null;
      return DateTime.fromMillisecondsSinceEpoch(
        n < 100000000000 ? n * 1000 : n,
      );
    }
    if (raw is String && raw.isNotEmpty) return DateTime.tryParse(raw);
    return null;
  }
}
