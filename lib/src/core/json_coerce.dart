/// 服务端 JSON 的**宽松取值**助手。
///
/// ★ 为什么需要这一层（第 257/259 轮两次真实代价）：
///
/// DSM/Drive/Office 各模块对同一个字段的类型**并不统一**，同一份代码在不同
/// 机型/版本上会拿到不同的 JSON 类型：
///
/// * 第 257 轮真机缺陷：`SYNO.Office.Template:list` 的 `ver` 是**字符串哈希**
///   （`"f26e4bacf7a3…"`），旧代码写 `(json['ver'] as num?)?.toInt()`
///   ⇒ `type 'String' is not a subtype of type 'num'?` ⇒ **整页模板库白屏**；
/// * 布尔同理：`SYNO.Core.*` 有的版本回 `true`，有的回 `1` / `"true"` / `"yes"`；
/// * 计数/大小类字段有的回 `"123"`（字符串数字）。
///
/// 所以**凡是服务端回包进 DTO 的地方，一律走这里，不要裸写 `as num?` /
/// `as bool`** —— 裸转只在"这一步崩掉、用户看到的是整页加载失败"时才暴露，
/// 而单测里 Mock 喂的都是规规矩矩的数字 ⇒ **Mock 全绿、真机崩**。
///
/// 注意：这里**只做类型容错，不做业务兜底**。"字段缺失"与"字段是 0"
/// 是两件事，要不要给默认值由调用方决定（本仓的规矩：用 `containsKey` 判存在性）。
library;

/// `int` / `double` / 数字字符串 → `int`；其余（含 `null`、哈希串、布尔）→ `null`。
int? jsonInt(Object? value) {
  if (value == null) return null;
  if (value is int) return value;
  if (value is num) return value.toInt();
  if (value is String) return int.tryParse(value.trim());
  if (value is bool) return value ? 1 : 0;
  return null;
}

/// 同 [jsonInt]，但给不出结果时用 [fallback]。
int jsonIntOr(Object? value, int fallback) => jsonInt(value) ?? fallback;

/// `double` / `int` / 数字字符串 → `double`；其余 → `null`。
double? jsonDouble(Object? value) {
  if (value == null) return null;
  if (value is double) return value;
  if (value is num) return value.toDouble();
  if (value is String) return double.tryParse(value.trim());
  return null;
}

/// 宽松布尔：`true` / `1` / `"1"` / `"true"` / `"yes"` / `"on"` → `true`；
/// `false` / `0` / `"0"` / `"false"` / `"no"` / `"off"` → `false`；其余 → `null`。
///
/// ★ 刻意**不**把"任何非空字符串"当成 `true`（`"0"` / `"false"` 就是假）。
bool? jsonBool(Object? value) {
  if (value == null) return null;
  if (value is bool) return value;
  if (value is num) return value != 0;
  if (value is String) {
    switch (value.trim().toLowerCase()) {
      case '1':
      case 'true':
      case 'yes':
      case 'on':
        return true;
      case '0':
      case 'false':
      case 'no':
      case 'off':
      case '':
        return false;
    }
    return null;
  }
  return null;
}

/// 任何值 → 字符串（`null` → `''`）；对象/列表按 Dart 的 `toString()`。
///
/// 与 `'${json['x'] ?? ''}'` 等价，但**意图更明确**，且能统一处理
/// "服务端把 id 回成数字"这种情况（`id: 123` → `'123'`）。
String jsonStr(Object? value) => value == null ? '' : '$value';

/// 取一个对象；不是 `Map` 时返回**空 map**（永不抛）。
///
/// 服务端偶发把空对象回成 `null`、或把数组回成 `{}`，
/// 这里一律降级成空 map，避免 `as Map` 直接崩掉整个列表。
Map<String, dynamic> jsonMap(Object? value) {
  if (value is Map) return value.cast<String, dynamic>();
  return const <String, dynamic>{};
}

/// 取一个数组；不是 `List` 时返回**空列表**（永不抛）。
List<dynamic> jsonList(Object? value) => value is List ? value : const <dynamic>[];

/// 把数组里的每一项映射成 `Map<String, dynamic>`，**逐项 try/catch**：
/// 坏了一条只丢那一条，不连累整页（本仓 M 类缺陷的通用修法）。
List<Map<String, dynamic>> jsonMapList(Object? value) {
  final out = <Map<String, dynamic>>[];
  for (final item in jsonList(value)) {
    if (item is Map) out.add(item.cast<String, dynamic>());
  }
  return out;
}
