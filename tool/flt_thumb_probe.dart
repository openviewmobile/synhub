// ignore_for_file: avoid_print
// 只读探测：缩略图（SYNO.FileStation.Thumb.get）、下载、以及 Range 支持。
//
// 实测结论（NAS: DSM 7.4.1-90080）：
//   * Thumb          entry.cgi，v1..v3，GET，path 是**原始路径字符串**（不是 JSON 数组），
//                    size = small|medium|large，返回**真图字节**（1.9MB PNG →
//                    small 12.9KB / medium 96.5KB / large 779.9KB，都是 PNG）
//   * Download       path 必须是 **JSON 数组**（`["/home/x.png"]`），mode=download|open
//   * Range          **支持**：`Range: bytes=0-63` → HTTP 206 + content-range
//                    → 文本预览可以"只取前 64KB"
//   * 文件不存在时  Thumb → HTTP 404、Download → HTTP 502，正文都是一张 DSM 的
//                    HTML 错误页（所以 getBytes 必须检查状态码，否则会把 HTML 当图片/文件）
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:synhub/src/core/net/dio_factory.dart';
import 'package:synhub/src/data/dto/file_entry_dto.dart';
import 'package:synhub/src/data/filestation_api.dart';
import 'package:synhub/src/dsm/webapi.dart';

Future<void> main() async {
  final env = Platform.environment;
  final dio = DioFactory.create(allowSelfSigned: true);
  final api = DsmWebApi(DirectTransport.url(env['SYNO_NAS_URL']!, dio: dio));
  await api.discover();
  await api.login(
    account: env['SYNO_ACCOUNT']!,
    password: env['SYNO_PASSWORD']!,
    session: 'FileStation',
  );
  final fs = FileStationApi(api);

  // 先找一个**真实存在的图片**，别再拿不存在的路径当基准（踩过：404/502 都是"文件没了"）
  final folder = env['SYNO_TEST_FOLDER'] ?? '/home';
  final listing = await api.call(
    'SYNO.FileStation.List',
    'list',
    preferredVersion: 2,
    params: {
      'folder_path': folder,
      'additional': FileEntryDto.encodePaths(['size']),
    },
  );
  final images = (listing['files'] as List)
      .cast<Map>()
      .where(
        (f) => RegExp(
          r'\.(png|jpe?g|gif|webp|bmp)$',
          caseSensitive: false,
        ).hasMatch('${f['name']}'),
      )
      .toList();
  if (images.isEmpty) {
    print('$folder 下没有图片，先放一张再跑');
    return;
  }
  final image = images.first;
  final path = '${image['path']}';
  print('样本 $path (${image['additional']?['size']}B)，目录共 ${images.length} 张图');

  for (final size in ['small', 'medium', 'large']) {
    try {
      final bytes = await api.getBytes(fs.thumbnailUrl(path, size: size));
      final png = bytes.length > 8 && bytes[0] == 0x89 && bytes[1] == 0x50;
      print('Thumb[$size] ${bytes.length}B png=$png');
    } catch (e) {
      print('Thumb[$size] 失败: $e');
    }
  }

  final url = fs.downloadUrl([path]);
  final range = await dio.get<List<int>>(
    url,
    options: Options(
      responseType: ResponseType.bytes,
      headers: {'Range': 'bytes=0-63'},
      validateStatus: (_) => true,
    ),
  );
  print(
    'Range → HTTP ${range.statusCode} ${(range.data ?? []).length}B '
    'content-range=${range.headers.value('content-range')}',
  );
  print('Download 全量 ${(await api.getBytes(url)).length}B');

  // 不存在的文件长什么样（getBytes 必须能识别出来）
  const ghost = '/home/definitely-not-here-9f3a.png';
  try {
    final bytes = await api.getBytes(fs.thumbnailUrl(ghost, size: 'small'));
    print(
      '不存在的文件 → ${bytes.length}B（没抛异常，正文是 HTML？'
      '${String.fromCharCodes(bytes.take(15))}）',
    );
  } catch (e) {
    print('不存在的文件 → 抛异常: $e');
  }
}
