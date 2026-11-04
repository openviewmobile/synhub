// 归档 VO —— 对齐 APK 的 `data/vo/chat/ArchiveVo.java` 与 `ArchivesVo.java`。
//
// `SYNO.Chat.Archive / list` 的响应（真机实测）：
//   {"archives":[{"archive_id":3,"props":{"channel":{...ChannelVo...}}}]}
//
// 归档的是一个**加密频道**：`props.channel` 里带着 `channel_key_enc`（封给我的
// 那一份），所以归档消息能不能读，取决于这把钥匙解不解得开。
library;

import 'channel_dto.dart';

class ArchiveDto {
  const ArchiveDto({required this.archiveId, required this.channel});

  final int archiveId;

  /// 被归档的频道（`props.channel`）
  final ChannelDto channel;

  static ArchiveDto? tryParse(Map<String, dynamic> json) {
    final id = _int(json['archive_id']);
    final props = json['props'];
    final channel = props is Map ? props['channel'] : null;
    if (id == 0 || channel is! Map) return null;
    return ArchiveDto(
      archiveId: id,
      channel: ChannelDto.fromJson(Map<String, dynamic>.from(channel)),
    );
  }

  static List<ArchiveDto> parseList(dynamic raw) {
    if (raw is! List) return const [];
    return [
      for (final e in raw)
        if (e is Map) ?tryParse(Map<String, dynamic>.from(e)),
    ];
  }

  static int _int(Object? v) {
    if (v is int) return v;
    if (v is num) return v.toInt();
    return int.tryParse('$v') ?? 0;
  }
}
