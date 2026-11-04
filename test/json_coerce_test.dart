// 服务端 JSON 的**宽松取值**助手回归用例（第 259 轮）。
//
// 背景：本仓真实吃过两次亏 ——
//  * 第 257 轮 `SYNO.Office.Template:list` 的 `ver` 是字符串哈希，
//    旧代码 `(json['ver'] as num?)?.toInt()` ⇒ 整页模板库白屏（真机缺陷）；
//  * 第 259 轮审计又找到 `SYNO.Chat.Post:list_editable` 的 `post_id`
//    同样裸 `as num?`。
//
// 这些用例钉的是"宽松助手本身的行为"，**以及"Mock 喂整数、真机回字符串"这种
// 真实差异不会再把整页打崩**。注意：Mock 全绿 ≠ 真机不崩 ——
// 所以这里刻意用**字符串/布尔/奇怪类型**当输入。

import 'package:flutter_test/flutter_test.dart';
import 'package:synhub/src/core/json_coerce.dart';

void main() {
  group('jsonInt：服务端可能回字符串数字', () {
    test('int / double / 数字字符串都能取到', () {
      expect(jsonInt(7), 7);
      expect(jsonInt(7.9), 7); // 截断（服务端偶尔回 7.0）
      expect(jsonInt('7'), 7);
      expect(jsonInt(' 7 '), 7); // 带空白
      expect(jsonInt('-3'), -3);
    });

    test('哈希串 / 普通串 / null / 容器 → null（不是抛异常）', () {
      // ★ 第 257 轮那个真机字段：`"f26e4bacf7a3…"`
      expect(jsonInt('f26e4bacf7a3d1c0'), isNull);
      expect(jsonInt('abc'), isNull);
      expect(jsonInt(null), isNull);
      expect(jsonInt(<int>[1, 2]), isNull);
      expect(jsonInt(<String, dynamic>{'a': 1}), isNull);
    });

    test('bool → 0/1（有的接口把开关回成布尔）', () {
      expect(jsonInt(true), 1);
      expect(jsonInt(false), 0);
    });

    test('jsonIntOr：取不到时用兜底', () {
      expect(jsonIntOr('12', 0), 12);
      expect(jsonIntOr('哈希', 0), 0);
      expect(jsonIntOr(null, -1), -1);
    });
  });

  group('jsonBool：四套服务端写法', () {
    test('真：true / 1 / "1" / "true" / "yes" / "on"', () {
      for (final v in <Object>[
        true,
        1,
        1.5,
        '1',
        'true',
        'TRUE',
        ' yes ',
        'on',
      ]) {
        expect(jsonBool(v), isTrue, reason: '输入 $v 应判真');
      }
    });

    test('假：false / 0 / "0" / "false" / "no" / "off" / 空串', () {
      for (final v in <Object>[false, 0, '0', 'false', 'no', 'off', '']) {
        expect(jsonBool(v), isFalse, reason: '输入 $v 应判假');
      }
    });

    test('不认识的值 → null（"不知道"必须与"假"分开）', () {
      expect(jsonBool('maybe'), isNull);
      expect(jsonBool(null), isNull);
      expect(jsonBool(<int>[1]), isNull);
    });
  });

  group('jsonStr / jsonMap / jsonList / jsonMapList', () {
    test('jsonStr：null → 空串；数字 id → 字符串', () {
      expect(jsonStr(null), '');
      expect(jsonStr(123), '123'); // 服务端偶尔把 id 回成数字
      expect(jsonStr('abc'), 'abc');
    });

    test('jsonMap：非 Map → 空 map（永不抛）', () {
      expect(jsonMap(<String, dynamic>{'a': 1}), {'a': 1});
      expect(jsonMap(null), isEmpty);
      expect(jsonMap(<int>[1]), isEmpty);
      expect(jsonMap('x'), isEmpty);
    });

    test('jsonList：非 List → 空列表（永不抛）', () {
      expect(jsonList(<int>[1, 2]), [1, 2]);
      expect(jsonList(null), isEmpty);
      expect(jsonList(<String, dynamic>{}), isEmpty);
    });

    test('jsonMapList：**逐项**过滤坏数据，不连累整页', () {
      final raw = <dynamic>[
        <String, dynamic>{'id': 1},
        'not-a-map', // 服务端偶发的脏数据
        null,
        <String, dynamic>{'id': 2},
      ];
      expect(jsonMapList(raw).map((e) => e['id']), [1, 2]);
      expect(jsonMapList(null), isEmpty);
    });
  });

  group('★ 真机缺陷回归：Mock 回整数、真机回字符串都不许崩', () {
    test('Office 模板 ver（第 257 轮）：字符串哈希不再抛类型错', () {
      // 旧写法 `(json['ver'] as num?)?.toInt()` 在这里会抛
      // `type 'String' is not a subtype of type 'num'?`
      final json = <String, dynamic>{'ver': 'f26e4bacf7a3d1c0'};
      expect(() => jsonInt(json['ver']), returnsNormally);
      expect(jsonInt(json['ver']), isNull);
    });

    test('Chat list_editable 的 post_id（第 259 轮）：字符串数字也能读', () {
      // 服务端回 "123"（字符串）时，旧写法抛类型错 ⇒ 整个"能否编辑"判定失败
      expect(jsonInt(<String, dynamic>{'post_id': '123'}['post_id']), 123);
      // 回 null / 缺失 → 0（调用方的既有语义）
      expect(jsonInt(<String, dynamic>{}['post_id']) ?? 0, 0);
    });
  });
}
