// Drive 标签（`SYNO.SynologyDrive.Labels`）与"给文件打标签"（`Files/label` v2）的 VO。
//
// 权威来源：真机实测（`tool/drive_p3_probe.dart` / `drive_p3_shape2.dart`，
// 2026-09-19，全部现场跑过）：
//   * `Labels/list` v1 `{}` → `{items:[{label_id,name,color,position,type,update_time}],
//     total}`；`type` 是 **`personal_label`**（不是 `label`！传 `{type:'label'}` 回空）；
//   * `Labels/create` v1 `{name:'"<名字>"'}` → 回建出来的标签；名字要 **Gson 引号串**；
//   * `Labels/update` v1 `{label_id:'"<id>"', name:'"<新名>"', color:'"#rrggbb"'}` → 回标签；
//   * `Labels/delete` v1 `{label_id:'"<id>"'}` → `{}`（裸串回 1006）；
//   * `Files/label` v2 是**动作数组**，不是 id 列表（踩过：传 `["1"]` 一律 1000）：
//       `{files:'["id:<file_id>"]',
//         labels:'[{"action":"add"|"delete","label_id":<int>}]'}` → `{}`；
//     打完 `Files/list_labelled` v2（`{label_id:'"<id>"',offset,limit}`）能查到。

/// 一个 Drive 标签
class DriveLabelDto {
  const DriveLabelDto({
    required this.labelId,
    required this.name,
    required this.color,
    required this.position,
    required this.type,
  });

  final String labelId;
  final String name;

  /// `#rrggbb`（服务端带 `#`；官方 Web 端用时会去掉再拼 class 名）
  final String color;
  final int position;
  final String type;

  bool get isShared => type == 'shared_label';

  /// 给 Flutter 用的颜色值（解析失败退到中性灰）
  int get colorValue {
    final hex = color.replaceFirst('#', '');
    final v = int.tryParse(hex, radix: 16);
    if (v == null) return 0xFF8A8A8E;
    return hex.length <= 6 ? 0xFF000000 | v : v;
  }

  static List<DriveLabelDto> listFromJson(Map<String, dynamic> data) {
    final raw = (data['items'] as List?) ?? const [];
    return raw
        .whereType<Map>()
        .map((e) => DriveLabelDto.fromJson(e.cast<String, dynamic>()))
        .toList(growable: false);
  }

  static DriveLabelDto fromJson(Map<String, dynamic> json) => DriveLabelDto(
    labelId: '${json['label_id'] ?? ''}',
    name: '${json['name'] ?? ''}',
    color: '${json['color'] ?? '#8a8a8e'}',
    position: _int(json['position']),
    type: '${json['type'] ?? 'personal_label'}',
  );
}

/// 给文件打/去标签的一条动作（`Files/label` v2 的 `labels` 数组元素）
class DriveLabelChange {
  const DriveLabelChange.add(this.labelId) : remove = false;
  const DriveLabelChange.remove(this.labelId) : remove = true;

  final String labelId;
  final bool remove;

  Map<String, dynamic> toJson() => {
    'action': remove ? 'delete' : 'add',
    // 真机验证：这里必须是**数字**（`label_id` 传字符串会 1000）
    'label_id': int.tryParse(labelId) ?? 0,
  };
}

int _int(Object? v) {
  if (v is int) return v;
  if (v is num) return v.toInt();
  return int.tryParse('$v') ?? 0;
}
