// ★ 第 260 轮：**"两路都失败 = 空相册 + 永远没有重试"** 的回归用例。
//
// 缺陷（由"错误态审计"子代理核实、本轮修）：
//   `photoAlbumsProvider` 对 `Browse.Album/list`（条件相册）与
//   `NormalAlbum/list`（普通相册）**两路都** `.catchError((_) => [])`。
//   两条都失败时 provider 返回**空列表** ⇒ 相册页渲染"还没有相册"，
//   而重试入口 `onRetry` **只在 error 态**才出现
//   （`photo_browse_page.dart`）⇒ **失败被当成空，用户永远点不到重试**。
//
// 判据：只失败一路仍降级（条件相册是补充）；**两路都失败必须抛**。
import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:synhub/src/data/dto/foto_dto.dart';
import 'package:synhub/src/data/foto_api.dart';
import 'package:synhub/src/dsm/webapi.dart';
import 'package:synhub/src/features/photos/photo_providers.dart';

/// 可编程的假 `FotoApi`：两路各失败一次也各记一次调用。
class _FakeFoto extends FotoApi {
  _FakeFoto(super.api, {this.failAlbums = false, this.failNormal = false});

  bool failAlbums;
  bool failNormal;
  int albumCalls = 0;
  int normalCalls = 0;

  @override
  Future<List<FotoAlbumDto>> albums({
    int offset = 0,
    int limit = 100,
    String? sortBy,
    String? sortDirection,
  }) async {
    albumCalls++;
    if (failAlbums) {
      throw DsmApiException(105, method: 'SYNO.Foto.Browse.Album.list');
    }
    return const [
      FotoAlbumDto(id: '1', name: '旅行', itemCount: 3),
    ];
  }

  @override
  Future<List<FotoAlbumDto>> normalAlbums({
    int offset = 0,
    int limit = 100,
  }) async {
    normalCalls++;
    if (failNormal) {
      throw DsmApiException(105, method: 'SYNO.Foto.Browse.NormalAlbum.list');
    }
    return const [
      FotoAlbumDto(id: '2', name: '普通相册', itemCount: 1),
    ];
  }
}

/// 给出一个能构造 `FotoApi` 的壳：`albums`/`normalAlbums` 全被覆盖，
/// 这个 `Dio` 永远不会被用到（不联网）。
DsmWebApi _shellApi() =>
    DsmWebApi(DirectTransport.url('https://fake.test', dio: Dio()));

void main() {
  Future<ProviderContainer> boot(_FakeFoto foto) async {
    final c = ProviderContainer(
      overrides: [fotoApiProvider.overrideWithValue(foto)],
    );
    addTearDown(c.dispose);
    return c;
  }

  test('① 两路都失败 ⇒ **抛错**（相册页才会出现重试入口，而不是"还没有相册"）', () async {
    final foto = _FakeFoto(_shellApi(), failAlbums: true, failNormal: true);
    final c = await boot(foto);
    await expectLater(
      c.read(photoAlbumsProvider.future),
      throwsA(isA<DsmApiException>()),
    );
    expect(foto.albumCalls, 1);
    expect(foto.normalCalls, 1);
  });

  test('② 只失败条件相册 ⇒ 降级返回普通相册（不抛）', () async {
    final foto = _FakeFoto(_shellApi(), failAlbums: true);
    final c = await boot(foto);
    final albums = await c.read(photoAlbumsProvider.future);
    expect(albums.map((a) => a.name), ['普通相册']);
  });

  test('③ 只失败普通相册 ⇒ 降级返回条件相册（不抛）', () async {
    final foto = _FakeFoto(_shellApi(), failNormal: true);
    final c = await boot(foto);
    final albums = await c.read(photoAlbumsProvider.future);
    expect(albums.map((a) => a.name), ['旅行']);
  });

  test('④ 两路都成功 ⇒ 合并去重（保持既有语义）', () async {
    final foto = _FakeFoto(_shellApi());
    final c = await boot(foto);
    final albums = await c.read(photoAlbumsProvider.future);
    expect(albums.map((a) => a.name), ['旅行', '普通相册']);
  });

  test('⑤ 反向验证：还原"两路都吞掉"的旧写法 ⇒ 得到空列表（证明这条用例真能抓到现象）', () async {
    // 旧写法的等价物：两路 catchError → []，再合并。
    final foto = _FakeFoto(_shellApi(), failAlbums: true, failNormal: true);
    final all = await foto
        .albums()
        .catchError((_) => <FotoAlbumDto>[]);
    final normal = await foto.normalAlbums().catchError((_) => <FotoAlbumDto>[]);
    expect([...all, ...normal], isEmpty,
        reason: '旧写法在两条都失败时确实回空列表 —— 这正是用户看到的"还没有相册"');
    expect(foto.albumCalls, 1);
    expect(foto.normalCalls, 1);
  });
}
