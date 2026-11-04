// M50：收藏**重排**的纯客户端部分。
//
// 官方 DS file 的 `Favorite` 有 `replace_all`（`api-server-authoritative.md:103`，
// 普通用户 v1-2）；DSM 网页端的收藏重排就是"把当前顺序整体覆盖回去"。
//
// ⚠️ `replace_all` 的**参数名/形状在 docs 全库与官方 APK 证据里都没有记录**
// （见 `docs/filestation-gaps-wave2.md` §4 取证清单）→ 按任务要求**不臆造**：
// 网络那一层先留骨架（`FileStationApi.replaceAllFavorites` 返回 `false`）。
// 这里只做**与协议无关**的本地排序编辑，参数形态拿到即可直接接上。
import '../../data/dto/file_entry_dto.dart';

/// 把 [items] 里第 [from] 项挪到第 [to] 项（越界返回**原顺序的副本**）。
List<FileEntryDto> moveFavorite(
  List<FileEntryDto> items, {
  required int from,
  required int to,
}) {
  final out = List<FileEntryDto>.from(items);
  if (from < 0 || from >= out.length) return out;
  if (to < 0 || to >= out.length) return out;
  if (from == to) return out;
  final item = out.removeAt(from);
  out.insert(to, item);
  return out;
}

/// 上移一位（已在首位则原样）。
List<FileEntryDto> moveFavoriteUp(List<FileEntryDto> items, int index) =>
    moveFavorite(items, from: index, to: index - 1);

/// 下移一位（已在末位则原样）。
List<FileEntryDto> moveFavoriteDown(List<FileEntryDto> items, int index) =>
    moveFavorite(items, from: index, to: index + 1);
