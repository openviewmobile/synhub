// Drive「收藏夹 / 收藏集」（官方 `DriveCategory.Collection`）的 VO 与类型枚举。
//
// ## 权威事实（全部照原文，不臆造）
//
// **1. 收藏集不是独立 API 族，它整个建在 `SYNO.SynologyDrive.Labels` 上。**
// 反编译 `Android-SynologyDrive.3.9.0-1113.ww.apk`：
//   * `ApiSynoDriveLabels.setAsListCollection(FileGroup)`（`ApiSynoDriveLabels.java:117`）
//     就是 `Labels/list`，只多一个参数
//     `putParam("type", group.getLabelTypeValue())`，版本
//     `Math.min(2, api.getMaxVersion())`（同文件 `setAsListCollection$lambda$1`）；
//   * `setAsCreateCollection(group, name, color)` = `Labels/create` +
//     `type` + `name`（+ 可选 `color`），版本同样 `Math.min(2, …)`；
//   * `setAsUpdate` / `setAsDelete` 与普通标签**共用**（`update` 带
//     `label_id`/`name`/`color`，`delete` 只带 `label_id`）。
//
// **2. 四个收藏集类型字符串**（`model/data/LabelImpl.java:39-42` 逐字常量，
// 注意**语义与 UI 名相反**：`document_folder` 是"文档收藏集"而非文件夹）：
//   * `photo_album`    — 照片
//   * `document_folder`— 文档
//   * `audio_playlist` — 音乐
//   * `video_playlist` — 视频
// 另有 `personal_label` / `shared_label`（普通标签，不是收藏集）、
// `add_collection` / `any_label`（UI 占位项，`LabelImpl.java:37-38`）。
//
// **3. 「加入 / 移出收藏」不是 Collections 的方法**，而是
// `Files/label`：`FileRepositoryNet.labelFiles(...)` → `FileLabelWork` →
// `ApiSynoDriveFiles.setAsLabelFiles(...)`（`ApiSynoDriveFiles.java:614-632`），
// 参数形状 `files`（`id:<id>` 数组）+ `labels`
// （`[{"action":"add"|"delete","label_id":<int>}]`）。也就是说收藏集成员
// 与标签成员**同一套存储**，所以我们直接复用既有的 `DriveApi.setLabels`。
//
// **4. 真机只读实测**（本批，2026；普通用户，DSM 7.2）：
// ```text
// Labels:list v3 {"type":"photo_album"}     → {"items":[],"total":0} success
// Labels:list v3 {"type":"document_folder"} → {"items":[],"total":0} success
// Labels:list v3 {"type":"audio_playlist"}  → {"items":[],"total":0} success
// Labels:list v3 {"type":"video_playlist"}  → {"items":[],"total":0} success
// Labels:list v2 {"type":"photo_album"}     → {"items":[],"total":0} success
// ```
// ⇒ 四个类型服务端**都认**，`items` 空是"本机还没有收藏集"的真实业务结果
// （不是接口失败，也不是 1077）。
//
// ⚠️ **没验证到的**（如实登记，见报告"未完成清单"）：
//   * `create` / `update` / `delete` 是**写方法**，按 §5.1 **本批一次都没调**
//     ⇒ 收藏集的建 / 改名 / 删只在代码层按官方参数形状实现，**没有真机样本**；
//   * 有收藏集时 `items[]` 里到底有没有 `file_count`、封面等字段**无样本**
//     —— 下面按 `LabelVo`（官方 `api/response/LabelVo.java`）已声明的字段解析，
//     缺失一律回落默认值，**不新造字段**。

/// 收藏集的四个类型（`LabelImpl.TYPE_COLLECTION_*` 逐字）
enum DriveCollectionType {
  photo('photo_album'),
  document('document_folder'),
  audio('audio_playlist'),
  video('video_playlist');

  const DriveCollectionType(this.apiValue);

  /// 上行给 `Labels/list|create` 的 `type` 原值
  final String apiValue;

  /// 反解；不是收藏集类型时回 `null`（`personal_label` 等走标签页）
  static DriveCollectionType? fromApiValue(String? value) {
    for (final t in DriveCollectionType.values) {
      if (t.apiValue == value) return t;
    }
    return null;
  }
}

/// 一个收藏集（`Labels/list` 回包 `items[]` 的一项）
class DriveCollectionDto {
  const DriveCollectionDto({
    required this.collectionId,
    required this.name,
    required this.type,
    required this.color,
    required this.position,
    required this.fileCount,
  });

  /// 服务端 `label_id`（收藏集与标签共用一套 id 空间）
  final String collectionId;
  final String name;

  /// 原始类型串（`photo_album` / `document_folder` / …）；未知串原样保留，
  /// **不猜测**成某个已知类型。
  final String type;

  /// `#rrggbb`
  final String color;

  /// 服务端排序位
  final int position;

  /// 条目数；服务端没给就是 `0`（不是"未知"的另一种画法）
  final int fileCount;

  /// 映射回枚举；未知类型回 `null`
  DriveCollectionType? get collectionType =>
      DriveCollectionType.fromApiValue(type);

  /// 给 Flutter 用的颜色（解析失败退中性灰，与 [DriveLabelDto] 一致）
  int get colorValue {
    final hex = color.replaceFirst('#', '');
    final v = int.tryParse(hex, radix: 16);
    if (v == null) return 0xFF8A8A8E;
    return hex.length <= 6 ? 0xFF000000 | v : v;
  }

  static List<DriveCollectionDto> listFromJson(Map<String, dynamic> data) {
    final raw = (data['items'] as List?) ?? const [];
    return raw
        .whereType<Map>()
        .map((e) => DriveCollectionDto.fromJson(e.cast<String, dynamic>()))
        .toList(growable: false);
  }

  static DriveCollectionDto fromJson(Map<String, dynamic> json) {
    // 容错：服务端有时把 id / 计数回成数字，有时回成字符串（LabelVo 也是这德行）
    return DriveCollectionDto(
      collectionId: '${json['label_id'] ?? ''}',
      name: '${json['name'] ?? ''}',
      type: '${json['type'] ?? ''}',
      color: '${json['color'] ?? '#8a8a8e'}',
      position: _int(json['position']),
      fileCount: _int(json['file_count']),
    );
  }
}

int _int(Object? v) {
  if (v is int) return v;
  if (v is num) return v.toInt();
  return int.tryParse('$v') ?? 0;
}
