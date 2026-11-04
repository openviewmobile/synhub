// 投票模型（Phase 6）。
//
// 服务端把投票放在 **`post.props.vote`** 里（不在顶层 `vote`）：
//
//   "props": {"vote": {
//      "choices": [{"count": 1, "id": "<uuid>", "text": "X"}],   // Post/list
//      "options": {"add_option": false, "anonymous": false,
//                  "expire_at": 0, "multiple": false},
//      "state": "open" | "close" | "delete",
//      "cronjob_id": 0
//   }}
//
// `Vote/get_choices` 会多给 `voters`（投过的 user_id 列表）。
// 反编译出处：`data/model/Vote.java`（STATE_OPEN/CLOSE/DELETE、voteFor/unVotefor）、
// `data/model/VoteChoice.java`（count/id/text/voters）、`VoteOptions.java`
// （`@SerializedName("add_option")` / `("expire_at")` —— 建投票时必须发这两个下划线名）。
import 'dart:convert';

class VoteChoiceDto {
  const VoteChoiceDto({
    required this.id,
    required this.text,
    this.count = 0,
    this.voters = const [],
  });

  final String id;
  final String text;
  final int count;

  /// 投过这个选项的用户（只有 `Vote/get_choices` 会给）
  final List<int> voters;

  bool votedBy(int userId) => voters.contains(userId);

  factory VoteChoiceDto.fromJson(Map<String, dynamic> json) => VoteChoiceDto(
    id: '${json['id'] ?? ''}',
    text: '${json['text'] ?? ''}',
    count: _int(json['count']) ?? 0,
    voters:
        (json['voters'] as List?)
            ?.map((e) => _int(e) ?? 0)
            .where((e) => e > 0)
            .toList() ??
        const [],
  );

  Map<String, dynamic> toJson() => {
    'id': id,
    'text': text,
    'count': count,
    if (voters.isNotEmpty) 'voters': voters,
  };
}

class VoteDto {
  const VoteDto({
    this.choices = const [],
    this.multiple = false,
    this.anonymous = false,
    this.addOption = false,
    this.expireAt = 0,
    this.state = VoteState.open,
    this.cronjobId = 0,
  });

  final List<VoteChoiceDto> choices;
  final bool multiple;
  final bool anonymous;
  final bool addOption;
  final int expireAt;
  final VoteState state;
  final int cronjobId;

  bool get isOpen => state == VoteState.open;
  int get totalVotes => choices.fold(0, (sum, c) => sum + c.count);

  /// 我投了哪些选项
  Set<String> chosenBy(int userId) => {
    for (final c in choices)
      if (c.votedBy(userId)) c.id,
  };

  /// 某个选项的占比（0..1，用于画条）
  double ratioOf(VoteChoiceDto c) {
    final total = totalVotes;
    if (total <= 0) return 0;
    return c.count / total;
  }

  VoteDto withChoices(List<VoteChoiceDto> next) => VoteDto(
    choices: next,
    multiple: multiple,
    anonymous: anonymous,
    addOption: addOption,
    expireAt: expireAt,
    state: state,
    cronjobId: cronjobId,
  );

  static VoteDto? tryParse(Object? raw) {
    Map<String, dynamic>? map;
    if (raw is Map) {
      map = Map<String, dynamic>.from(raw);
    } else if (raw is String && raw.isNotEmpty) {
      try {
        final decoded = jsonDecode(raw);
        if (decoded is Map) map = Map<String, dynamic>.from(decoded);
      } catch (_) {
        return null;
      }
    }
    if (map == null) return null;
    return VoteDto.fromJson(map);
  }

  factory VoteDto.fromJson(Map<String, dynamic> json) {
    final options = json['options'] is Map
        ? Map<String, dynamic>.from(json['options'] as Map)
        : const <String, dynamic>{};
    return VoteDto(
      choices:
          (json['choices'] as List?)
              ?.whereType<Map>()
              .map((e) => VoteChoiceDto.fromJson(Map<String, dynamic>.from(e)))
              .toList() ??
          const [],
      multiple: _bool(options['multiple']),
      anonymous: _bool(options['anonymous']),
      addOption: _bool(options['add_option']),
      expireAt: _int(options['expire_at']) ?? 0,
      state: VoteState.parse('${json['state'] ?? 'open'}'),
      cronjobId: _int(json['cronjob_id']) ?? 0,
    );
  }

  Map<String, dynamic> toJson() => {
    'choices': [for (final c in choices) c.toJson()],
    'options': {
      'multiple': multiple,
      'anonymous': anonymous,
      'add_option': addOption,
      'expire_at': expireAt,
    },
    'state': state.wire,
    if (cronjobId > 0) 'cronjob_id': cronjobId,
  };
}

enum VoteState {
  open('open'),
  closed('close'),
  deleted('delete');

  const VoteState(this.wire);
  final String wire;

  static VoteState parse(String s) => switch (s) {
    'close' => VoteState.closed,
    'delete' => VoteState.deleted,
    _ => VoteState.open,
  };
}

int? _int(Object? v) {
  if (v is int) return v;
  if (v is num) return v.toInt();
  if (v is bool) return v ? 1 : 0;
  if (v is String) return int.tryParse(v);
  return null;
}

bool _bool(Object? v) {
  if (v is bool) return v;
  if (v is num) return v != 0;
  if (v is String) return v == 'true' || v == '1';
  return false;
}

/// 定时消息（`SYNO.Chat.Post.Schedule / list` → `{cronjob_id, message, send_at}`）
class ScheduledPostDto {
  const ScheduledPostDto({
    required this.cronjobId,
    required this.channelId,
    required this.message,
    required this.sendAt,
  });

  final int cronjobId;
  final int channelId;
  final String message;
  final int sendAt;

  bool get isPending => sendAt > DateTime.now().millisecondsSinceEpoch;

  factory ScheduledPostDto.fromJson(Map<String, dynamic> json) =>
      ScheduledPostDto(
        cronjobId: _int(json['cronjob_id']) ?? 0,
        channelId: _int(json['channel_id']) ?? 0,
        message: '${json['message'] ?? ''}',
        sendAt: _int(json['send_at']) ?? 0,
      );
}
