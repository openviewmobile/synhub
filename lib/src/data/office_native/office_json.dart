// `jsonDecode` 结果的小工具（纯 Dart）。
//
// 背景：`jsonDecode` 产出 `Map<String, dynamic>` / `List<dynamic>`，而本目录的模型
// 统一用 `Map<String, Object?>` / `List<Object?>`；这里集中做安全的窄化，避免每个
// 模型文件各写一份 cast。

Map<String, Object?>? asJsonMap(Object? v) {
  if (v is Map) return v.cast<String, Object?>();
  return null;
}

List<Object?>? asJsonList(Object? v) {
  if (v is List) return v.cast<Object?>();
  return null;
}

int? asJsonInt(Object? v) {
  if (v is int) return v;
  if (v is double) return v.toInt();
  return null;
}

double? asJsonDouble(Object? v) {
  if (v is double) return v;
  if (v is int) return v.toDouble();
  return null;
}

String? asJsonString(Object? v) => v is String ? v : null;

/// 把单元格/标量值转成展示文本；`null` → `null`（不是空串）。
String? asJsonScalarText(Object? v) {
  if (v == null) return null;
  if (v is String) return v;
  if (v is bool) return v ? 'TRUE' : 'FALSE';
  return v.toString();
}

/// 深度优先找第一个 `{"type": type}` 的 ProseMirror 节点（只看 `content`）。
Map<String, Object?>? findFirstNodeByType(Object? node, String type) {
  if (node is List) {
    for (final n in node) {
      final hit = findFirstNodeByType(n, type);
      if (hit != null) return hit;
    }
    return null;
  }
  final map = asJsonMap(node);
  if (map == null) return null;
  if (asJsonString(map['type']) == type) return map;
  return findFirstNodeByType(map['content'], type);
}

/// 深度优先收集全部 `{"type": type}` 的 ProseMirror 节点（只看 `content`）。
List<Map<String, Object?>> findNodesByType(Object? node, String type) {
  final out = <Map<String, Object?>>[];
  void walk(Object? n) {
    if (n is List) {
      for (final x in n) {
        walk(x);
      }
      return;
    }
    final map = asJsonMap(n);
    if (map == null) return;
    if (asJsonString(map['type']) == type) out.add(map);
    walk(map['content']);
  }

  walk(node);
  return out;
}
