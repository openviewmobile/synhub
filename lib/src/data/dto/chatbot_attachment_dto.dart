// 机器人消息里的「附件 + 交互按钮」。
//
// 官方文档（NAS 自带 `ui/help/enu/chat_integration.html`，2.4.7 包内）：
//
//   机器人/入站 webhook 发消息时可以带 `attachments`：
//     {"text": "Hello World", "user_ids": [3],
//      "attachments": [{"callback_id": "abc", "text": "attachment",
//                       "actions": [{"type": "button", "name": "resp",
//                                    "value": "ok", "text": "OK", "style": "green"}]}]}
//   * `callback_id` 是机器人自定义的串，用户点按钮时会原样回给机器人的 outgoing URL；
//   * `style` 只有 green / gray / red / orange / blue / teal 六种（`Common.java` 的
//     `ARG_*`），其它值一律按 gray 画（原版 `ActionAdapter.onBindViewHolder` 的 switch）。
//
// 服务端把它存进 `PostVo.prop.attachments`（`AttachmentVo`/`ActionVo`），
// 客户端从 `Post.props.attachments` 读。点按钮 → `SYNO.Chat.Post.Attachment / trigger`。
//
// 颜色取自 APK 资源（`res/values/colors.xml` 的 `colorButton*`，
// 按钮是 1px 描边 + 14dp 圆角的**描边按钮**，见 `res/drawable/chatbot_button_*.xml`）。
import 'dart:convert';

import 'package:flutter/material.dart';

/// 按钮样式（`Action.style`）
enum ChatbotActionStyle {
  green(Color(0xFF5FB86D)),
  blue(Color(0xFF189AF4)),
  orange(Color(0xFFFA8E4B)),
  teal(Color(0xFF1EB9C7)),
  red(Color(0xFFF0645A)),
  gray(Color(0xFF7A7C80));

  const ChatbotActionStyle(this.color);

  final Color color;

  /// `style` 字符串 → 样式；认不出的（含空）按原版落到 [gray]
  static ChatbotActionStyle parse(Object? raw) {
    return switch ('$raw'.toLowerCase()) {
      'green' => green,
      'blue' => blue,
      'orange' => orange,
      'teal' => teal,
      'red' => red,
      _ => gray,
    };
  }
}

/// 一个可点按钮（`ActionVo`）
class ChatbotActionDto {
  const ChatbotActionDto({
    this.type = 'button',
    this.text = '',
    this.name = '',
    this.value = '',
    this.style,
  });

  /// 目前服务端只支持 `button`（文档：Currently, buttons are offered）
  final String type;
  final String text;
  final String name;
  final String value;

  /// null = 服务端没给，按 gray 画
  final ChatbotActionStyle? style;

  ChatbotActionStyle get resolvedStyle => style ?? ChatbotActionStyle.gray;

  /// 按钮上显示的文案（服务端可能只给 name）
  String get label => text.isNotEmpty ? text : name;

  factory ChatbotActionDto.fromJson(Map<String, dynamic> json) =>
      ChatbotActionDto(
        type: '${json['type'] ?? 'button'}',
        text: '${json['text'] ?? ''}',
        name: '${json['name'] ?? ''}',
        value: '${json['value'] ?? ''}',
        style: json['style'] == null
            ? null
            : ChatbotActionStyle.parse(json['style']),
      );

  static List<ChatbotActionDto> parseList(Object? v) {
    if (v is! List) return const [];
    return v
        .whereType<Map>()
        .map((e) => ChatbotActionDto.fromJson(Map<String, dynamic>.from(e)))
        .toList();
  }
}

/// 一条附件（`AttachmentVo`）：一段文本 + 若干按钮
class ChatbotAttachmentDto {
  const ChatbotAttachmentDto({
    this.callbackId = '',
    this.text = '',
    this.actions = const [],
  });

  final String callbackId;
  final String text;
  final List<ChatbotActionDto> actions;

  factory ChatbotAttachmentDto.fromJson(Map<String, dynamic> json) =>
      ChatbotAttachmentDto(
        callbackId: '${json['callback_id'] ?? ''}',
        text: '${json['text'] ?? ''}',
        actions: ChatbotActionDto.parseList(json['actions']),
      );

  /// `props.attachments` 可能是数组，也可能（单个时）是对象或 JSON 字符串
  static List<ChatbotAttachmentDto> parseList(Object? v) {
    var list = v;
    if (list is String) {
      if (list.isEmpty) return const [];
      try {
        list = jsonDecode(list);
      } catch (_) {
        return const [];
      }
    }
    if (list is Map) list = [list];
    if (list is! List) return const [];
    return list
        .whereType<Map>()
        .map((e) => ChatbotAttachmentDto.fromJson(Map<String, dynamic>.from(e)))
        .toList();
  }
}
