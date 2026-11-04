// C3（NoteStation 补齐）的 provider 层：版本历史 / 导出 / 导入 / 网页剪藏。
//
// 与既有笔记模块同一套约定：
//   * API 从会话里取（未连接 → null），数据一律 `autoDispose` + **关掉自动重试**；
//   * 写操作后只 invalidate，不做乐观更新（服务端是唯一事实来源）；
//   * 能力位缺失 / `105`/`160` → **该入口隐藏**；`119`/`106` → 会话提示、
//     **绝不隐藏**；未检测 → fail-open（见 [ServiceAvailabilitySnapshot.hasApi]）。
//
// 可用性探针的取舍：导出/导入接口**没有**"空跑"的只读入口，所以探针统一打
// 它们最便宜的 `status`（官方本来就在轮询它，读操作、不改状态）。服务端在
// 进入方法前就做 API 级鉴权（`authLevel`），所以 `105`/`160` 一定能在这一枪上
// 冒出来；参数层面的 114/101 等则归 `unknown` → fail-open（不隐藏）。
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/i18n/l10n.dart';
import '../../core/services/service_availability.dart';
import '../../core/services/service_registry.dart';
import '../../data/dto/note_c3_dto.dart';
import '../../data/note_api.dart';
import '../../dsm/webapi.dart';
import 'note_providers.dart';

Duration? _noRetry(int retryCount, Object error) => null;

NoteStationApi _require(Ref ref) {
  final api = ref.read(noteApiProvider);
  if (api == null) throw StateError(currentText().setNotConnected);
  return api;
}

// ---------------------------------------------------------------- 版本历史

/// 某个笔记的历史版本（`Note.Version/list` v2）
final noteVersionsTypedProvider = FutureProvider.autoDispose
    .family<List<NoteVersionDto>, String>((ref, objectId) async {
      final rows = await _require(ref).listVersions(objectId);
      return rows
          .map((e) => NoteVersionDto.fromJson(e))
          .where((v) => v.version.isNotEmpty)
          .toList();
    }, retry: _noRetry);

/// 某个**历史版本**的正文。
///
/// 官方预览就是 `Note/get` + `ver`（见 `note_api.dart` 的 `listVersions` 注释），
/// 所以这里复用 [noteDetailProvider] 之外再单开一个 family —— key 是
/// `(objectId, ver)`，`NoteDetail` 与详情页同类型，渲染路径完全一致。
final noteVersionDetailProvider = FutureProvider.autoDispose
    .family<NoteDetail, ({String objectId, String ver})>((ref, key) async {
      final api = _require(ref);
      final note = await api.getNote(key.objectId, ver: key.ver);
      return NoteDetail(note);
    }, retry: _noRetry);

// ---------------------------------------------------------------- 入口可用性

/// C3 的功能入口（每个对应一个**可选能力位**）。
enum NoteC3Feature {
  version(kNoteVersionApi),
  exportWord(kNoteExportWordApi),
  exportNote(kNoteExportNoteApi),
  exportNotebook(kNoteExportNotebookApi),
  importEnex(kNoteImportEnexApi),
  importNotebook(kNoteImportNotebookApi),
  importEvernote(kNoteImportEvernoteApi),
  // 剪藏没有独立 API：浏览器扩展借 `Note/create`/`Note/set` 写入（证据见
  // `note_api.dart` 的 `clipperParams`）。所以它的能力位就是**必需**的
  // `SYNO.NoteStation.Note` —— 模块在，入口就在（fail-open）。
  clipper('SYNO.NoteStation.Note');

  const NoteC3Feature(this.apiName);

  /// `service_registry.dart` 里 `StationService.note` 的必需/可选能力位。
  final String apiName;
}

/// 入口可用性快照。
///
/// [visible] 之外的入口**不渲染**；[denied] 用来给"没有权限"提示；
/// [sessionExpired] 只提示会话失效，**不动任何入口**。
class NoteC3Availability {
  const NoteC3Availability({
    this.visible = const {},
    this.denied = const {},
    this.sessionExpired = false,
  });

  final Set<NoteC3Feature> visible;
  final Set<NoteC3Feature> denied;
  final bool sessionExpired;

  bool shows(NoteC3Feature f) => visible.contains(f);
  bool isDenied(NoteC3Feature f) => denied.contains(f);

  NoteC3Availability copyWith({
    Set<NoteC3Feature>? visible,
    Set<NoteC3Feature>? denied,
    bool? sessionExpired,
  }) => NoteC3Availability(
    visible: visible ?? this.visible,
    denied: denied ?? this.denied,
    sessionExpired: sessionExpired ?? this.sessionExpired,
  );
}

/// 八个入口的可用性：**能力位 + 一次轻探针**（纪律与 `classifyErrorCode` 一致）。
///
///   * 能力位缺失 → 直接不进 `visible`，**不发请求**（`partial`，不隐藏模块）；
///   * `105`/`160` → `denied`（入口隐藏 + 无权限提示）；
///   * `119`/`106` → `sessionExpired = true`，入口**保留**；
///   * 其它错误（含网络失败）→ 入口**保留**（fail-open，不因不确定而隐藏）。
final noteC3AvailabilityProvider =
    FutureProvider.autoDispose<NoteC3Availability>((ref) async {
      final api = ref.watch(noteApiProvider);
      if (api == null) return const NoteC3Availability();
      final snapshot = ref.watch(serviceAvailabilityProvider);

      final visible = <NoteC3Feature>{};
      final denied = <NoteC3Feature>{};
      var sessionExpired = false;

      Future<void> probe(
        NoteC3Feature feature,
        Future<void> Function() call,
      ) async {
        if (!snapshot.hasApi(StationService.note, feature.apiName)) return;
        try {
          await call();
          visible.add(feature);
        } on DsmApiException catch (e) {
          switch (classifyErrorCode(e.code)) {
            case AvailabilityState.sessionExpired:
              sessionExpired = true;
              visible.add(feature);
            case AvailabilityState.unauthorized:
            case AvailabilityState.absent:
              denied.add(feature);
            default:
              visible.add(feature);
          }
        } catch (_) {
          visible.add(feature);
        }
      }

      // 版本：能力位在位就算可见（真正取列表要 object_id，不适合在这里探）；
      // 会话/权限错误在打开版本面板时按同一套码处理（见 `_showVersions`）。
      await probe(NoteC3Feature.version, () async {});
      await probe(NoteC3Feature.exportWord, () => api.wordExportStatus(''));
      await probe(NoteC3Feature.exportNote, () => api.noteExportStatus(''));
      await probe(
        NoteC3Feature.exportNotebook,
        () => api.notebookExportStatus(),
      );
      await probe(NoteC3Feature.importEnex, () => api.enexImportStatus());
      await probe(
        NoteC3Feature.importNotebook,
        () => api.notebookImportStatus(),
      );
      await probe(NoteC3Feature.importEvernote, () => api.evernoteStatus());
      // 剪藏：能力位 = 必需的 `SYNO.NoteStation.Note`，不发探针请求。
      if (snapshot.hasApi(StationService.note, NoteC3Feature.clipper.apiName)) {
        visible.add(NoteC3Feature.clipper);
      }

      return NoteC3Availability(
        visible: visible,
        denied: denied,
        sessionExpired: sessionExpired,
      );
    }, retry: _noRetry);

/// 版本预览/回滚要用到的 `notePerm`（官方 `perm_from`/`smart_id`）。
///
/// 本客户端目前只对"自己笔记本里的笔记"做版本回滚，`perm_from`/`smart_id`
/// 留空即可（官方对共享笔记才带）。这里保留一个空实现，方便后续接共享上下文。
const String? noteVersionPermFrom = null;
const String? noteVersionSmartId = null;

/// 模型别名：方便页面写 `NoteC3Version`。
typedef NoteC3Version = NoteVersionDto;
