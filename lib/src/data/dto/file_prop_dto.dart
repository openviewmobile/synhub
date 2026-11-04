// `Post/list` 带 `has=["file_props"]` 时随消息一起下发的附件信息。
//
// 反编译出处：`com/synology/dschat/data/model/FileProp.java`（字段名一致）、
// `PostVo.fileProps`。
import 'dart:convert';

/// 能当图片显示的扩展名（`file_props.type` 就是扩展名）
const kImageExtensions = <String>{
  'jpg',
  'jpeg',
  'png',
  'gif',
  'webp',
  'bmp',
  'heic',
  'heif',
  'tif',
  'tiff',
};

/// 一个附件（图片 / 文件 / 语音）。
///
/// ⚠️ 真机实测（docs/phase5-protocol.md §2）：
///   * `file_props` 在 Post VO 里是**单个对象**，不是数组；
///   * `type` 只是**扩展名**（`png` / `txt`），不是 MIME；
///   * 语音标志位字段名是 `is_voice_msg`（`is_voice_message` 是猜的，兼容保留）；
///   * 文本/代码附件会带 `snippet_preview`（服务端截好的预览文本）。
class FilePropDto {
  const FilePropDto({
    this.name = '',
    this.displayName = '',
    this.type,
    this.source,
    this.size = 0,
    this.mtime = 0,
    this.ownerId = 0,
    this.isImage = false,
    this.isSnippet = false,
    this.isVoiceMessage = false,
    this.imageWidth = 0,
    this.imageHeight = 0,
    this.voiceMsgLength = 0,
    this.snippetPreview = '',
    this.snippetLines = 0,
    this.snippetPreviewMore = false,
  });

  /// 服务端给的文件类型（一般就是扩展名：`png` / `txt` / `aac`）
  String get extension => (type ?? '').toLowerCase();

  /// 能当图片显示吗：`is_image` 标志，或者扩展名在白名单里
  /// （实测上传 png 时 `is_image` 仍是 false，只能靠扩展名）
  bool get showsThumbnail {
    if (isImage) return true;
    if ((type ?? '').startsWith('image/')) return true;
    return kImageExtensions.contains(extension);
  }

  /// 服务端截的文本预览（代码/文本附件用）
  final String snippetPreview;
  final int snippetLines;
  final bool snippetPreviewMore;

  /// 录音时长（秒）
  final int voiceMsgLength;
  final int ownerId;

  /// 服务端文件名（下载时用的名字）
  final String name;

  /// 界面上显示的名字（原始文件名）
  final String displayName;

  /// MIME（服务端可能给 `image/jpeg` 这种）
  final String? type;

  /// 图片的原图地址（外链图片消息用）
  final String? source;
  final int size;
  final int mtime;

  final bool isImage;
  final bool isSnippet;

  /// 录音消息（文件名以 `voiceMessage` 开头，create 时带 `voice_msg_length`）
  final bool isVoiceMessage;

  final int imageWidth;
  final int imageHeight;

  /// 界面上优先显示的名字
  String get label => displayName.isNotEmpty ? displayName : name;

  String get humanSize {
    if (size <= 0) return '';
    const units = ['B', 'KB', 'MB', 'GB', 'TB'];
    var value = size.toDouble();
    var unit = 0;
    while (value >= 1024 && unit < units.length - 1) {
      value /= 1024;
      unit++;
    }
    final text = unit == 0
        ? value.toStringAsFixed(0)
        : value.toStringAsFixed(value >= 10 ? 0 : 1);
    return '$text ${units[unit]}';
  }

  factory FilePropDto.fromJson(Map<String, dynamic> json) {
    // 有些接口把 file_props 的每一项包成 {"file_prop": {...}}
    final raw = json['file_prop'] is Map
        ? Map<String, dynamic>.from(json['file_prop'] as Map)
        : json;
    return FilePropDto(
      name: '${raw['name'] ?? ''}',
      displayName: '${raw['display_name'] ?? ''}',
      type: raw['type'] == null ? null : '${raw['type']}',
      source: raw['source'] == null ? null : '${raw['source']}',
      size: _int(raw['size']),
      mtime: _int(raw['mtime']),
      isImage: raw['is_image'] == true,
      isSnippet: raw['is_snippet'] == true,
      isVoiceMessage:
          raw['is_voice_msg'] == true || raw['is_voice_message'] == true,
      // ⚠️ 真机把尺寸放在嵌套的 `image: {width, height}` 里
      //（老接口的扁平 `image_width` 也认，见 docs/phase5-protocol.md §2）
      imageWidth: raw['image'] is Map
          ? _int((raw['image'] as Map)['width'])
          : _int(raw['image_width']),
      imageHeight: raw['image'] is Map
          ? _int((raw['image'] as Map)['height'])
          : _int(raw['image_height']),
      voiceMsgLength: _int(raw['voice_msg_length']),
      ownerId: _int(raw['owner_id']),
      snippetPreview: '${raw['snippet_preview'] ?? ''}',
      snippetLines: _int(raw['snippet_lines']),
      snippetPreviewMore: raw['snippet_preview_more'] == true,
    );
  }

  /// 解析 `file_props`：真机给的是**单个对象**，但数组 / JSON 字符串也一并容忍
  static List<FilePropDto> parseList(dynamic value) {
    var v = value;
    if (v is String) {
      if (v.isEmpty) return const [];
      try {
        v = jsonDecode(v);
      } catch (_) {
        return const [];
      }
    }
    if (v is Map) return [FilePropDto.fromJson(Map<String, dynamic>.from(v))];
    if (v is! List) return const [];
    return v
        .whereType<Map>()
        .map((e) => FilePropDto.fromJson(Map<String, dynamic>.from(e)))
        .toList();
  }

  static int _int(dynamic v) {
    if (v is int) return v;
    if (v is num) return v.toInt();
    return int.tryParse('$v') ?? 0;
  }
}
