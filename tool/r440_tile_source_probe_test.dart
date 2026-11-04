// r440 · 「地图底图源到底能不能用」的**只读探针**（跑法 = `flutter test tool/…`，
// 仪器91：不放进 `test/` ⇒ 不会被全量闸门② 收走，也不需要 NAS 凭据）。
//
// 为什么需要它（`DA94` 的教训，见 `docs/android-ui-audit-r440.md` §S3）：
//   * **HTTP 200 ≠ 有数据**：Esri `World_Street_Map` 在 z14 的上海返回 **200**，
//     但内容是服务端自带的「Map data not yet available」占位图（2,521 B）；
//     Carto 的 light/voyager 在 z14 返回**逐字节相同**的 2,049 B 占位图。
//     只判"请求成功"会把这两种都算成"可用" ⇒ 真机上就是"没有报错、还是一片灰"。
//   * 所以本探针按**瓦片内容**报读数：字节数 ＋ 前 4 字节（PNG/JPEG 魔数）＋
//     内容指纹（FNV-1a 前 8 字节十六进制，不引依赖）。**同一张占位图会跨图层撞指纹**
//     ⇒ 一眼看出"这不是这个图层画出来的图"。
//
// 判据（人工判，不写成断言）：**真街道/影像瓦片在本区域 z14 至少 10 KB**；
// 明显小于 4 KB 的去比对指纹 —— 两个图层指纹相同 = 同一张占位图。
//
// 坐标：上海人民广场一带 `lon=121.4737 lat=31.2304`（与真机相册地图的落点同一处）：
//   z10 ⇒ 857/418    z12 ⇒ 3429/1673   z14 ⇒ 13718/6694   z17 ⇒ 109763/53556
// ignore_for_file: avoid_print
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:synhub/src/features/photos/photo_map_tiles.dart';

/// 探几个缩放级：地图页初始 zoom 是 **14**（`PhotoTileMap.initialZoom`）。
const List<int> zooms = [10, 14];

/// 经纬度 → 瓦片号（直接复用生产投影，别另写一套公式）。
({int x, int y}) tileAt(double lat, double lng, int z) =>
    PhotoMapProjection.tile(lat, lng, z);

/// FNV-1a 64 位，取低 32 位打印（只用来判"两坨字节是不是同一坨"）。
String fingerprint(Uint8List b) {
  var h = 0xcbf29ce484222325;
  for (final x in b) {
    h ^= x;
    h = (h * 0x100000001b3) & 0xFFFFFFFFFFFFFFFF;
  }
  return h.toRadixString(16).padLeft(16, '0').substring(8);
}

void main() {
  test('r440 底图源内容探针（只读，无需凭据）', () async {
    const lat = 31.2304;
    const lng = 121.4737;
    final fetcher = HttpPhotoMapTileFetcher();
    final seen = <String, List<String>>{}; // 指纹 → 哪些图层给过它

    for (final src in kPhotoMapTileSources) {
      final isDefault = identical(src, kPhotoDefaultTileSource);
      final host = Uri.parse(src.urlTemplate).host;
      print('--- ${src.name}${isDefault ? '  ★默认' : ''}  host=$host');
      for (final z in zooms) {
        final t = tileAt(lat, lng, z);
        final uri = src.tileUri(z, t.x, t.y);
        final bytes = await fetcher.fetch(uri);
        if (bytes == null || bytes.isEmpty) {
          print('  z$z  ${uri.path}  ⇒ **抓不到**（0 字节 / 非 200）');
          continue;
        }
        final fp = fingerprint(bytes);
        (seen[fp] ??= []).add('${src.name}@z$z');
        final magic = bytes
            .take(4)
            .map((b) => b.toRadixString(16).padLeft(2, '0'))
            .join();
        final kind = magic.startsWith('89504e47')
            ? 'PNG'
            : (magic.startsWith('ffd8ff') ? 'JPEG' : '未知($magic)');
        final flag = bytes.length < 4096 ? '  ⚠️ 疑似占位图' : '';
        print('  z$z  ${uri.path}  ${bytes.length}B  $kind  fp=$fp$flag');
      }
    }

    print('--- 指纹撞车的图层（撞 ⇒ 是同一坨字节，不是各图层各自渲染）');
    seen.forEach((fp, who) {
      if (who.length > 1) print('  fp=$fp  ← ${who.join(' , ')}');
    });

    print('--- 只做对照、**没有出厂**的候选源（用来证明"200 ≠ 有数据"）');
    const rejected = [
      PhotoMapTileSource(
        name: 'Esri World Street Map（未出厂）',
        urlTemplate:
            'https://server.arcgisonline.com/ArcGIS/rest/services/'
            'World_Street_Map/MapServer/tile/{z}/{y}/{x}',
        attribution: '-',
      ),
      PhotoMapTileSource(
        name: 'Carto light_all（未出厂）',
        urlTemplate: 'https://basemaps.cartocdn.com/light_all/{z}/{x}/{y}.png',
        attribution: '-',
      ),
    ];
    for (final src in rejected) {
      final t = tileAt(lat, lng, 14);
      final uri = src.tileUri(14, t.x, t.y);
      final bytes = await fetcher.fetch(uri);
      // ★ 注意：这两个都是"HTTP 200 但内容是服务端占位图"⇒ `fetch` **不返回 null**。
      print(
        '  ${src.name}  z14  '
        '${bytes == null ? "抓不到" : "${bytes.length}B  fp=${fingerprint(bytes)}"}',
      );
    }

    final d = tileAt(lat, lng, 14);
    final db = await fetcher.fetch(
      kPhotoDefaultTileSource.tileUri(14, d.x, d.y),
    );
    expect(db, isNotNull, reason: '默认源在初始 zoom(z14) 必须真的抓到字节');
    print(
      '★ 默认源（${kPhotoDefaultTileSource.name}）z14 ⇒ ${db!.length}B '
      '（判据：真图 ≥ 10 KB）',
    );
  }, timeout: const Timeout(Duration(minutes: 5)));
}
