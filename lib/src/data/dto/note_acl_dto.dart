// 笔记/笔记本的**共享 ACL**（`note.acl` / `notebook.acl` JSON 列）。
//
// 权威依据（NAS 上实际装的 NoteStation 2.6.10-3938）：
//   * `scripts/create_table.sql`：`note` 与 `notebook` 表都有
//     `acl JSON` + `individual_shared BOOLEAN` **两列**；
//   * 官方 Web 前端 `ui/notestation.js` 的共享对话框读的正是这个结构：
//     ```js
//     Ext.iterate(objectData.acl.dsm_user, function(uid, o){
//        uid_map[o.name] = parseInt(uid, 10);      // ← key 是 uid，值里才有用户名
//        …o.perm…
//     });
//     Ext.iterate(objectData.acl.dsm_group, function(gid, o){ … });
//     "public" in acl && Ext.isString(acl.public.perm)
//     ```
//     权限值是**字符串枚举** `"ro"` / `"rw"`（同一份 JS 里的 combobox
//     `data:[{perm:"ro"},{perm:"rw"}]`）。
import 'package:meta/meta.dart';

import '../../core/i18n/data_text.dart';

/// 笔记共享权限（官方 `perm` 枚举：`ro` / `rw`）
enum NoteSharePerm {
  readOnly('ro', '只读'),
  readWrite('rw', '可编辑');

  const NoteSharePerm(this.code, this.label);

  /// 官方字符串值
  final String code;

  /// 中文回落（界面侧读 [labelText]；`lib/src/features/**` 本轮不在迁移范围内）
  final String label;

  /// ARB key（多语言用；数据层不能碰 `AppText`）
  String get labelKey => switch (this) {
    NoteSharePerm.readOnly => 'dtoNotePermReadOnly',
    NoteSharePerm.readWrite => 'dtoCanEdit',
  };

  /// 当前语言文案（走 `data_text.dart` 的 [dataText]；没装翻译器时回落 [label]）
  String labelText() => dataText(labelKey, label);

  static NoteSharePerm? fromCode(Object? raw) {
    final code = '${raw ?? ''}'.trim();
    for (final p in NoteSharePerm.values) {
      if (p.code == code) return p;
    }
    return null;
  }
}

/// 一条共享授权（用户或群组）
@immutable
class NoteAclEntry {
  const NoteAclEntry({
    required this.name,
    required this.perm,
    this.id = '',
    this.inherit = true,
    this.isGroup = false,
  });

  /// 用户名 / 群组名
  final String name;
  final NoteSharePerm perm;

  /// `uid` / `gid`（ACL 里的 **key**；官方删除时也可只带名字）
  final String id;

  /// 继承自上层（笔记本）而不是单独授权 —— 官方用 `inherit` 区分
  final bool inherit;
  final bool isGroup;

  static NoteAclEntry? fromJsonEntry(
    Object? key,
    Object? value, {
    required bool isGroup,
  }) {
    final map = value is Map ? value.cast<String, dynamic>() : const {};
    final perm = NoteSharePerm.fromCode(map['perm']);
    final name = '${map['name'] ?? ''}'.trim();
    if (perm == null || name.isEmpty) return null;
    return NoteAclEntry(
      name: name,
      perm: perm,
      id: '${key ?? ''}'.trim(),
      inherit: map['inherit'] != false,
      isGroup: isGroup,
    );
  }
}

/// 一份完整的 ACL（`acl` JSON）
@immutable
class NoteAcl {
  const NoteAcl({
    this.enabled = false,
    this.publicPerm,
    this.publicInherit = true,
    this.users = const [],
    this.groups = const [],
  });

  /// 服务端的 `enabled`：false = 这份对象的共享总开关没开
  final bool enabled;

  /// 公开（任何人可看/可改）分享的权限；`null` = 没开公开分享
  final NoteSharePerm? publicPerm;
  final bool publicInherit;
  final List<NoteAclEntry> users;
  final List<NoteAclEntry> groups;

  bool get hasPublic => publicPerm != null;

  /// 有没有"单独授权"（官方 `isIndividualSharedAcl`：public / 用户 / 群组里
  /// 任意一条 `inherit === false`）
  bool get hasIndividual =>
      (hasPublic && !publicInherit) ||
      users.any((e) => !e.inherit) ||
      groups.any((e) => !e.inherit);

  bool get isEmpty => !hasPublic && users.isEmpty && groups.isEmpty;

  static const NoteAcl none = NoteAcl();

  static NoteAcl fromJson(Object? raw) {
    if (raw is! Map) return none;
    final map = raw.cast<String, dynamic>();
    final public = map['public'];
    final publicMap = public is Map
        ? public.cast<String, dynamic>()
        : const <String, dynamic>{};
    List<NoteAclEntry> entries(Object? rawList, {required bool isGroup}) {
      if (rawList is! Map) return const [];
      final out = <NoteAclEntry>[];
      rawList.forEach((k, v) {
        final e = NoteAclEntry.fromJsonEntry(k, v, isGroup: isGroup);
        if (e != null) out.add(e);
      });
      out.sort((a, b) => a.name.compareTo(b.name));
      return out;
    }

    return NoteAcl(
      enabled: map['enabled'] == true,
      publicPerm: NoteSharePerm.fromCode(publicMap['perm']),
      publicInherit: publicMap['inherit'] != false,
      users: entries(map['dsm_user'], isGroup: false),
      groups: entries(map['dsm_group'], isGroup: true),
    );
  }
}
