// Synology Office（`SYNO.Office.*`）的最小只读封装（batch ③ Office L1）。
//
// 权威事实（两条腿，都实际跑过）：
//   1. **NAS 上装的 Office SPK 3.8.0-22711**（`/tmp/spk/export_Office`）：
//      `webapi/SYNO.Office.lib` 的方法表 + `ui/dist/ui.doc.js` 里的调用点；
//   2. **真机实测**（`tool/office_probe.dart`，2026-09-18）：
//      `SYNO.Office.File.extract`（v1）收 `{link_id}`，回 `{data: "<正文纯文本>"}`；
//      `link_id` = Drive 条目的 `permanent_link`（形如 `19wEMJG0KyQTlkshZgwjHzL48cT9JYKR`）。
//
// ⚠️ 只认 `link_id`：`path` / `display_path` / `id:<file_id>` / `object_id` 四种写法
// 真机全失败（`114/1000`）。所以「服务端抽取正文」这条路**只对已在 Drive 索引里的
// 文件有效**——NAS 目录里的 Office 文档要先把所在文件夹纳入 Synology Drive。
//
// 为什么不走 `Office.Export/download`（导出 PDF，再用现成的 PDF 渲染器显示）：
// 真机实测这条 POST 表单接口对**直接上传的 .docx**回 Office 私有错误码
// `57350`（`link_id`）/ `57351`（`object_id`）——Synology Office 的文件必须先用
// `Office.Import.start/convert` **转换成 Office 原生文档**才导得出来，那是写操作（L2）。
//
// ★ **写入批次真机结论**（`docs/live-write-verification.md`，2026-09-21，权威）：
//   * `SYNO.Office.Node` 族**没有 `list` 方法**（`Node:list` → `103`）——本文件
//     从来没调过它，调用点也一个都没有（别再加）；
//   * `Node:get` 的真参数是 **`path`**（官方白名单 `vol_path,…,path,…`）；
//     传 `object_id` → **`1000`**。所以本文件的 `Node/get` 只发
//     `{path:'id:<file_id>', basic:'true'}`，**不再把 `object_id` 当入参形态**；
//   * `Office.Export/download` **唯一可用形状** =
//     `{path:"id:<file_id>", format:"xlsx"}` → `200` + OOXML(ZIP)；
//     `link_id`→`57350`、`object_id`→`57351`、`Excel.save`→`57383` 全是错的；
//     产物文件名取 `Content-Disposition` 的 **basename 且不带扩展名**，
//     扩展名必须由客户端自己补（见 [officeExportFileName]）；
//   * 普通用户「写内容」的正路是
//     **`Import:start {files:[{format:"drive", path:"/mydrive/…", viewonly}]}`**
//     （转换）或 `Node:create {path,title,ntype}`（建**空白**原生节点）。
//     `Node:create` 的 `content` 参数**被服务端静默忽略**（传了 cells 仍建出空
//     工作簿）→ 本文件不调用 `Node:create`，也不依赖它写内容；
//   * `Snapshot:create` 对我们上传的 `.xlsx`/`.txt` **全版本回 `57391`**
//     （目标不是 Office 原生文档）→ 它**不是**普通用户写入口。本文件只用
//     `Snapshot:get`（读），不用 `Snapshot:create`（写）。
import '../core/json_coerce.dart';
import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import '../core/i18n/data_text.dart';
import '../core/net/traffic_meter.dart';
import '../dsm/webapi.dart';
import 'dto/office_version_dto.dart';
// 只读通道的产物是**原生内容树**，要接到已定稿的原生解析层（只调用不修改）。
import 'office_native/office_json.dart' show asJsonMap;
import 'office_native/office_native_reader.dart' show OfficeNativeFormat;

/// `SYNO.Office.*` 的协议层
class OfficeApi {
  OfficeApi(DsmWebApi api) : api = api.withModule(TrafficModules.office);

  final DsmWebApi api;

  static const _v1 = [1];

  /// `SYNO.Office.Snapshot:get` 真机只取证过 **v4**（见 [snapshotGet]），
  /// 所以候选只放 v4：不在客户端猜 v1–v3 的形态。
  static const _v4 = [4];

  /// `SYNO.Office.Node.Attachment:get` 真机取证过的是 **v2**（见 [attachmentGet]）。
  static const _v2 = [2];

  /// 按"方法出现在哪些版本"选候选，绝不照 `maxVersion` 协商
  /// （`SYNO.Office.File` 只有 v1；照 maxVersion 会撞 `103 方法不存在`）
  int _negotiate(String apiName, List<int> candidates) {
    final entry = api.apiTable?[apiName];
    final max = entry?.maxVersion ?? candidates.last;
    final min = entry?.minVersion ?? 1;
    for (final v in candidates) {
      if (v >= min && v <= max) return v;
    }
    return candidates.last;
  }

  /// `Office.File/extract`（v1）→ 文档正文纯文本。
  ///
  /// [linkId] 必须是 Drive 条目的 `permanent_link`。
  Future<String> extract({required String linkId}) async {
    final data = await api.call(
      'SYNO.Office.File',
      'extract',
      preferredVersion: _negotiate('SYNO.Office.File', _v1),
      params: {'link_id': linkId},
    );
    // 真机回包：`{"data":"office probe 2026-09-18"}`（就是纯字符串）
    final raw = data['data'] ?? data['text'] ?? '';
    return raw is String ? raw.trim() : jsonEncode(raw);
  }

  /// `Office.Info/get`（v1）：套件在不在、当前用户能不能用。
  Future<OfficeInfo> info() async {
    final data = await api.call(
      'SYNO.Office.Info',
      'get',
      preferredVersion: _negotiate('SYNO.Office.Info', _v1),
    );
    return OfficeInfo.fromJson(data);
  }

  // ------------------------------------------- Office.Snapshot/get（只读原生树）
  //
  // **真机取证纠正**（`docs/live-nas-verification.md` §⑦，只读批次）：
  //   * `SYNO.Office.Sheet.Snapshot:create` / `Doc.Snapshot:create` /
  //     `Presentation.Snapshot:create` 真机**全部回 `103`（方法不存在）** ——
  //     研究文档里"普通用户可用 Sheet.Snapshot.create"的说法被真机推翻，
  //     所以本文件**不调用任何 `*.Snapshot.create`**（一个都没有）；
  //   * 真正的只读入口是 **`SYNO.Office.Snapshot:get` v4**：对 `.odoc`(schema13)、
  //     `.osheet`、`.oslides`(presentation) 全部回 200 + 原生内容树，**不需要先
  //     convert**（convert 是写操作，本批不做）；
  //   * 参数只有 `link_id`，且 `link_id` = Drive 的 `permanent_link`
  //     （取法见 [DriveApi.permanentLinkForPath]，`Files:get` + `/mydrive/...`）；
  //   * ⚠️ **写侧别用它**：`SYNO.Office.Snapshot:create`（v1/v2）对我们上传的
  //     `.xlsx`/`.txt` **全版本回 `57391`**（写入批次真机证据）——它不是普通用户
  //     写入口，本文件也从不调用它。

  /// `SYNO.Office.Snapshot/create`（**v2**，官方 Web 客户端用的版本）——
  /// **读 `.odoc`/`.oslides` 内容前的必调步骤**。
  ///
  /// ## ★★ 第 309 轮：真机缺陷"新建的空白 `.odoc` 打不开"的根因
  ///
  /// 真机 LGE-AN10：本 App **新建** `.odoc`（14:37）后打开报
  /// `Snapshot:get 的内容树与 @C_text/content 形态对不上`；
  /// **21 分钟后从列表再点同一文件，仍然同一句失败** ⇒ 服务端**从未**为它产生快照，
  /// 不是"索引延迟"。
  ///
  /// 官方 Web 客户端（SPK `Office-3.8.0-22711`）在**读内容前必调它**，
  /// 且**只对 `odoc`/`oslides`、不对 `osheet`**，失败一律 `catch{}`：
  /// ```js
  /// async function ey(e,t){let{iconKey:n}=t;if("odoc"===n||"oslides"===n)try{
  ///   await em().request({api:"SYNO.Office.Snapshot",method:"create",version:2,
  ///                       params:{link_id:e}})}catch{}return(0,q.Mv)(e)}
  /// ```
  /// 另一处（读主题来源）是严格的 `create → get` **相邻**（`ui/dist/ui.presentation.js`）。
  /// `.lib`（权威）：`SYNO.Office.Snapshot` v1 `create,get`、**v2 `create,get`**、
  /// v3/v4 只有 `get` ⇒ 候选里只能有 v1/v2，照 `maxVersion`(=4) 会撞 `103`。
  ///
  /// ★ 与本文档早前"写侧别用它"的结论**不矛盾**：那次是拿 **`.xlsx`/`.txt`**（非原生
  /// 格式）去调，全版本回 `57391`；官方的调用点**只出现在 `odoc`/`oslides`**
  /// ⇒ 这是**按类型**的语义（原生格式才有快照），不是"普通用户不可用"。
  ///
  /// 失败**如实抛出**（不在数据层吞）；调用方按官方 `catch{}` 吞掉并继续 —— 这样
  /// 老路径的行为**逐字不变**（最坏情况与今天一样）。
  Future<void> snapshotCreate({required String linkId}) async {
    await api.call(
      'SYNO.Office.Snapshot',
      'create',
      preferredVersion: _negotiate('SYNO.Office.Snapshot', _v2),
      params: {'link_id': linkId},
    );
  }

  /// `SYNO.Office.Snapshot/get`（**v4**）→ 原生内容树。
  ///
  /// [linkId] 必须是 Drive 条目的 `permanent_link`（真机实测：给别的形态报域错误）。
  /// 回包键：`['comment','content','file','ntype','object_id']`；`content` 是
  /// 文档内容树（odoc/oslides 与 OFile `@C_text/content` section 同形）。
  ///
  /// 失败（缺能力位 / `103` / `105` / `119` / 域错误）由调用方**回落到下一跳**，
  /// 这里只如实抛出，不吞。
  /// ## ★★ 第 65 轮 D58：**补上 `password`（此前完全没发）**
  ///
  /// 仓库里原先写着"本 App 拿不到能用于解密的凭据通道，所以只能提示
  /// 请到服务器访问"。**那句话是错的** —— 官方 `Snapshot/get`
  /// 本来就收密码：
  ///
  /// * `ApiSynoOfficeSnapshot.setAsGet(linkId, password)`（`:53-64`）
  ///   **总是** `putParam("password", password)`（空串也发，同
  ///   `AdvanceSharing` 的 `protect_password` 语义）；
  /// * 版本按 `min(getCurrentGetVersion(), api.getMaxVersion())` 选，
  ///   服务端 `.lib` 里 `get` 在 **v1–v4 都有**
  ///   （`SYNO.Office.Snapshot` `min=1 max=4`，v2 起 `create` 消失）；
  /// * 配合 `Office.Node.Encrypt/check`（**v1**，只有这一个方法，
  ///   `password` 同样是**明文** `putParam`）：先 `check` 验密码，
  ///   再用同一个密码 `Snapshot/get` 取**已解密**的内容。
  ///
  /// ⇒ 密码是有用的，只是以前没有把这条通道接起来。
  /// UI 侧的密码框见 `features/drive/drive_encrypt_gate.dart`。
  Future<Map<String, dynamic>> snapshotGet({
    required String linkId,
    String password = '',
  }) async {
    return api.call(
      'SYNO.Office.Snapshot',
      'get',
      preferredVersion: _negotiate('SYNO.Office.Snapshot', _v4),
      params: {
        'link_id': linkId,
        // 官方："总是发"（空串代表未加密/不传密码）
        'password': password,
      },
    );
  }

  // ------------------------------------------- Office.Node.Attachment（图片字节）
  //
  // **真机取证（`docs/office-doc-render-design.md` §2 E5/E6，只读探针）**：
  //   * 文档里的图片不是 URL，而是**文档内部的附件引用**（`picture` 节点
  //     `attrs.config.file_id`，32 hex）；`src` 在真实文档里出现 0 次；
  //   * 取字节的唯一通道 = **`SYNO.Office.Node.Attachment:get` v2**，且
  //     `object_id` 与 `file_id` **必须同时给**：
  //       - 只给 `file_id` → **404**；
  //       - 把 Drive 的 `permanent_link` 当 `object_id` → **57351**；
  //       - `Attachment:list` v1 缺 `object_id` → **120（required: object_id）**；
  //   * 成功回包：`http=200` + `Content-Type: image/png` + 真 PNG 魔数；
  //     `logo_2.png` 13,909 B、`icon.png` 1,026 B（离线夹具同字节，含 sha256）。
  //
  // `object_id` 的唯一权威来源是 **`Snapshot:get` 回包的 `data.object_id`**
  // （形如 `1028_35AO…`），调用方拿到后必须一路带到 [attachmentGet]。

  /// `Office.Node/create`（**v1**）→ 在 [parentId] 下新建**空白**原生
  /// 文档 / 电子表格（D56）。
  ///
  /// ## ★★ 为什么候选里**只能有 v1**（这是个会静默失败的坑）
  /// 服务端 `.lib`（`export_Office/webapi/SYNO.Office.lib`，权威）：
  /// ```
  /// SYNO.Office.Node   min 1  max 2
  ///   v1: get, set, create, delete, copy
  ///   v2: touch, copy          ← ★ 没有 create！
  /// ```
  /// 即**照 `maxVersion`(=2) 请求 `create` 会回 `103 方法不存在`**。
  /// 所以这里显式 `_negotiate('SYNO.Office.Node', _v1)`。
  ///
  /// ## `path` 是**父文件夹**，不是新文件的路径
  /// 官方 `OfficeNodeCreateWork.byFileId`：
  /// `UtilsForApi.computePathById(parentFileId)` ⇒ `id:<父文件夹 file_id>`，
  /// `title` 单独一个参数（`ApiSynoOfficeNode.setAsCreate(path, type, title)`，
  /// `ApiSynoOfficeNode.java:115-121`）。
  ///
  /// ## ⚠️ 不要指望用它写内容
  /// `content` 参数**被服务端静默忽略**（传了 cells 仍建出空工作簿）——
  /// 写内容的正路是 `Import:start`。本方法只用于**建空白节点**，
  /// 返回的 `file_id` 交给后续打开/编辑流程。
  ///
  /// 返回：`{fileId, linkId, displayPath, perm}`（官方
  /// `OfficeNodeCreateResponseVo.OfficeTemplateInfoVo` 的字段）。
  /// ## ★ 第 257 轮：支持**加密新建**（`encrypt` + `password`）
  ///
  /// 官方 Web 客户端（SPK `ui.doc.js` `Office.WebAPI.createOfficeNode`）逐字：
  /// ```js
  /// api:"SYNO.Office.Node", version:1, method:"create", timeout:18e5,
  /// params: copyTo({commit_msg:{device:"desktop"}}, e.params,
  ///         "path,title,ctime,mtime,password,encrypt,ntype,content"),
  /// encryption: getEncryptionOpts(e.params)   // 有 password 就 ["password"]
  /// ```
  /// 即：**空白三类型 + `encrypt:true` + `password`** 都在同一个 `create` 里。
  ///
  /// ★ 关于 `encryption:["password"]`：官方前端那句是
  /// `if (u(t.encryption) && !this.env.isSecure()) encryptParams(...)`
  /// （`ui/dist/lib/synowebapi.min.js`）—— **只在非 HTTPS 时才做参数级加密**。
  /// 我方与官方 App 对 NAS 一律 HTTPS（含 QuickConnect），所以照官方
  /// 在安全连接下的行为：`password` 明文进表单，由 TLS 保护。
  Future<({String fileId, String linkId, String displayPath, String perm})>
  createNode({
    required String parentId,
    required OfficeNodeType type,
    required String title,
    bool encrypt = false,
    String password = '',
  }) async {
    final data = await api.call(
      'SYNO.Office.Node',
      'create',
      preferredVersion: _negotiate('SYNO.Office.Node', _v1),
      params: {
        // 官方：`id:<父文件夹>`（computePathById）
        'path': parentId.startsWith('id:') ? parentId : 'id:$parentId',
        'ntype': type.value,
        'title': title,
        // 官方默认值逐字：`{commit_msg: Ext.apply({device:"desktop"}, …)}`
        'commit_msg': jsonEncode({'device': 'desktop'}),
        if (encrypt) 'encrypt': 'true',
        if (encrypt && password.isNotEmpty) 'password': password,
      },
    );
    return (
      fileId: '${data['file_id'] ?? ''}',
      linkId: '${data['link_id'] ?? ''}',
      displayPath: '${data['display_path'] ?? ''}',
      perm: '${data['perm'] ?? ''}',
    );
  }

  /// `SYNO.Office.Node.Attachment/get`（**v2**）→ 附件（图片）真实字节。
  ///
  /// 参数**逐字**是 `object_id` + `file_id`（真机：缺任一个都取不到，见上）。
  /// 走带鉴权的 GET（`authenticatedUrl` + `getBytes`）——`_sid`/`SynoToken`
  /// 都进查询串，这也是真机 `http=200` 的那条形态。
  ///
  /// 失败**分类抛出** [OfficeAttachmentException]（可 `catch`、可判定），
  /// 不再一律 `Exception`：404=附件不存在、105=无权限、119/106=会话失效、
  /// 超时/网络分别一类。UI 据此给"能懂的原因 + 重试"，且**绝不显示
  /// file_id/ref/路径**。
  Future<Uint8List> attachmentGet({
    required String objectId,
    required String fileId,
  }) async {
    final negotiated = _negotiate('SYNO.Office.Node.Attachment', _v2);
    try {
      return await _attachmentGetAt(objectId, fileId, negotiated);
    } on OfficeAttachmentException catch (first) {
      // ★ DA197（真机 2026-10-22）：同一份 `.odoc` 里 10 张图有 2 张在 **v2**
      //   回 `120`，另外 8 张 v2 正常。官方 `.lib` 里
      //   `SYNO.Office.Node.Attachment` 的 **v1 与 v2 都有 `get`** ⇒
      //   v2 的 120 不等于"这张图不存在"，先按 v1 再问一次。
      //   只对 120/103 降级一次；105（无权限）/119/106（会话）不重试。
      if (!(first.dsmCode == 120 || first.dsmCode == 103) || negotiated == 1) {
        rethrow;
      }
      try {
        return await _attachmentGetAt(objectId, fileId, 1);
      } on OfficeAttachmentException {
        // 降级也没取到 ⇒ 报**第一次**（v2）的原因：v1 的次生错误容易把人
        // 带到"这个版本不行"的错误方向（`rethrow` 抛的是 v1 那条）。
        throw first;
      }
    }
  }

  Future<Uint8List> _attachmentGetAt(
    String objectId,
    String fileId,
    int v,
  ) async {
    if (objectId.isEmpty || fileId.isEmpty) {
      throw OfficeAttachmentException(
        OfficeAttachmentErrorKind.missingParam,
        detail: dataText(
          'officeAttachmentMissingId',
          '缺少 object_id 或 file_id，取不到图片',
        ),
      );
    }
    final uri = api.authenticatedUrl(
      api.apiPath('SYNO.Office.Node.Attachment'),
      <String, String>{
        'api': 'SYNO.Office.Node.Attachment',
        'version': '$v',
        'method': 'get',
        // 真机铁律：这两个**必须同时出现**（只剩 file_id → 404）
        'object_id': objectId,
        'file_id': fileId,
      },
    );
    try {
      final bytes = await api.getBytes(uri);
      if (bytes.isEmpty) {
        throw OfficeAttachmentException(
          OfficeAttachmentErrorKind.empty,
          detail: dataText('officeAttachmentEmpty', '服务端返回了空图片'),
        );
      }
      return Uint8List.fromList(bytes);
    } on OfficeAttachmentException {
      rethrow;
    } on DsmApiException catch (e) {
      // ★ DA197（真机 2026-10-22）：参数齐全（object_id + file_id）仍回 **120**，
      //   且 v1/v2 都一样 ⇒ 这张图在这个对象上就是取不出来。落到 `unknown`
      //   会让界面说"暂时不可用 + 可重试"（点几次也不会好）；归 `notFound`
      //   （"服务器上找不到这张图片"）才是真的。
      //   ★ 只在这条通道特判：模板缩略图那条通道的 120 是"ver 不对"，
      //     它的退路依赖 `unknown`（见 `templateThumbBytes`）。
      if (e.code == kOfficeAttachmentServerGone) {
        throw OfficeAttachmentException(
          OfficeAttachmentErrorKind.notFound,
          dsmCode: e.code,
          cause: e,
          detail: dataText(
            'officeAttachmentUnresolvable',
            '服务端取不出这张图片的附件（120）',
          ),
        );
      }
      throw officeAttachmentExceptionFor(code: e.code, cause: e);
    } on DsmTransportException catch (e) {
      throw officeAttachmentExceptionFor(
        httpStatus: e.statusCode,
        networkMessage: e.message,
        cause: e,
      );
    } on TimeoutException catch (e) {
      throw OfficeAttachmentException(
        OfficeAttachmentErrorKind.timeout,
        cause: e,
        detail: dataText('officeAttachmentTimeout', '取图片超时'),
      );
    }
  }

  /// `SYNO.Office.Node.Attachment/list`（**v1**）→ 附件条目（原始回包）。
  ///
  /// ⚠️ **未取证**：真机只验到"缺 `object_id` → `120（required: object_id）`"，
  /// 成功回包的**根键名与条目字段名都没有取证**。所以本方法**不编字段名**：
  /// 只把回包里第一个数组的原始 `Map` 元素透传出去（调用方自己判形态）。
  /// 排序/过滤/文件名都留给未来取证后的批次。
  Future<List<Map<String, dynamic>>> attachmentList({
    required String objectId,
  }) async {
    if (objectId.isEmpty) {
      throw OfficeAttachmentException(
        OfficeAttachmentErrorKind.missingParam,
        detail: dataText(
          'officeAttachmentListNeedsObjectId',
          '缺少 object_id，列不出附件',
        ),
      );
    }
    final Map<String, dynamic> data;
    try {
      data = await api.call(
        'SYNO.Office.Node.Attachment',
        'list',
        preferredVersion: _negotiate('SYNO.Office.Node.Attachment', _v1),
        params: {'object_id': objectId},
      );
    } on DsmApiException catch (e) {
      throw officeAttachmentExceptionFor(code: e.code, cause: e);
    } on DsmTransportException catch (e) {
      throw officeAttachmentExceptionFor(
        httpStatus: e.statusCode,
        networkMessage: e.message,
        cause: e,
      );
    }
    for (final value in data.values) {
      if (value is List) {
        return <Map<String, dynamic>>[
          for (final e in value)
            if (e is Map) e.cast<String, dynamic>(),
        ];
      }
    }
    return const <Map<String, dynamic>>[];
  }

  // ------------------------------------------------- Office 原生版本历史
  //
  // 权威事实（两条腿）：
  //   1. NAS 上装的 **Office 3.8.0-22711**（`/tmp/spk/export_Office`）：
  //      `webapi/SYNO.Office.lib` → `SYNO.Office.Node.Version` **v1** =
  //      `get list restore rename`，`allowUser` 含 `normal.*`（普通用户可用）；
  //      `webapi/mgr/version/SYNO.Office.Node.Version.so` 的内联键确认了
  //      `object_id path offset limit additional password to_parent_folder
  //       overwrite ver_name versions author commit_msg editors first_version
  //       listable total ver_name` 这些参数/字段名；
  //   2. 官方 Web 前端的**调用形态**（`ui/dist/ui.doc.js` / `ui.sheet.js` /
  //      `ui.presentation.js` 三份完全一致）：
  //      * 列表：`{object_id, additional:{uid:true,name:true,nickname:bool}}` +
  //        `limit`（首批 30）/`offset`，回包根是 `versions`；
  //      * 恢复：`{object_id, ver, password?, path?, to_parent_folder?}`；
  //      * 命名：`{object_id, ver, ver_name, overwrite:true}`；
  //      * 导出某个版本：`Office.Export/download {path|object_id, format, ver}`。
  //
  // `object_id` 是什么（**真机纠错，2026-09-20；写入批次复核 2026-09-21**）：
  //   ❌ 之前把 Drive 的 `permanent_link` 当 `object_id` 用 —— 列表回 `57351`
  //      （Office 私有码），命名回 `114 缺少必需参数`。两者在 Office 库里是
  //      **两列**：`libsynoffice.so` 的 schema 是
  //      `node(object_id, version, …, link_id, ntype)` + `link(id, object_id…)`；
  //      `object_id` 形如 `1028_35AO5B4V1P53DFEPKM2O8`（官方 `getUidByObjectId`
  //      取 `_` 前当 uid），而 `link_id` 才是 Drive 的 `permanent_link`；
  //   ✅ 官方 Drive 页的取法：`Office.Node/get`（v1）响应里就带 `object_id`
  //      —— `ui/dist/ui.doc.js` 的 `loadDocDone` 直接读 `t.object_id`；
  //   ⚠️ 但 `Node:get` **不认 `object_id` 入参**：写入批次真机
  //      `Node:get {object_id:…}` → **`1000`**；真参数是 **`path`**，且**只有
  //      `path`**（`Node:list` → `103`，该族根本没有 `list`）。
  //      ⇒ 取内部 id 只能靠 `{path:'id:<file_id>', basic:'true'}`，本文件的
  //      [resolveObjectId] 据此**只发 path**（`object_id` 形态已删）。
  //
  // 各方法接受的形态（官方 `GetAction` 的 `copyTo` 白名单，逐字）：
  //   * `list`    : `object_id, offset, limit, additional…`，且 **`path` 也可**
  //                 （真机：`path=id:<file_id>` 通，`object_id=permanent_link` 不通）；
  //   * `restore` : `object_id, ver, password, path, to_parent_folder` —— 两种都收；
  //     真机只在 `list` 上验过 `path=id:<file_id>`，所以本文件 restore 也统一走
  //     `path`（`object_id` 只会来自一个已被真机否掉的 `Node:get` 形态）；
  //   * `rename`  : `object_id, ver, ver_name, overwrite` —— **只有 `object_id`**，
  //                 这就是"缺参数"的根因（[renameNodeVersion] 仍只发 object_id）。
  //
  // ⚠️ **未验证边界**：`Node:get {path}` 本身在写入批次里**没有被真机复跑**
  //（§10 仍开项），依据是官方参数白名单 + `path` 在 `Node.Version:list` 上已验。
  // 所以 [resolveObjectId] 失败时只会让"命名版本"不可用（UI 已有回落），
  // 不会让读取/导出这些已验路径出错。

  /// 文档内部 id：**按 `file_id` 分别缓存**（`Office.Node/get` 解析一次后缓存）。
  ///
  /// ★★★ 第 314 轮真机缺陷（已修）：这里以前是**一个不带 key 的字段**
  /// `String? _resolvedObjectId`，而 `OfficeApi` 是从 `officeApiProvider`
  /// 来的**会话级单例** ⇒ **一个会话里所有 Office 文件共用第一次解析出的
  /// `object_id`**。真机证据：先开 `r314sheet.osheet` 再开
  /// `Sales tracker.osheet`（两个不同的表），`[office:sheet-gate]` 两次都打印
  /// **同一个** `object=1028_OMV…34….sh`，而 `link` 各不相同 ⇒
  /// `Permission:check` 因"object_id 与 link_id 不是同一份文件"而回
  /// **`readable/writable/commentable` 全 false**，界面据此说
  /// "No write/comment permission: opened read-only."（**假话**），协作握手
  /// 也被拒（`Permission denied`）。所以缓存必须**按文件**分开。
  final Map<String, String> _resolvedObjectIds = <String, String>{};

  /// `Office.Node/get`（v1）→ 文档内部 `object_id`（形如 `1028_35AO…`）。
  ///
  /// 发出去的参数**只有** `{path:'id:<file_id>', basic:'true'}`：
  ///   * `basic:true` 是官方第一次拿节点信息时传的；
  ///   * **不发 `object_id`**：写入批次真机 `Node:get {object_id}` → `1000`；
  ///   * 也**不存在** `Node:list`（`103`），别去找"列节点"的方法。
  ///
  /// 拿不到就返回 `null`（调用方据此降级，不要瞎发参数）。
  Future<String?> resolveObjectId({String fileId = ''}) async {
    if (fileId.isEmpty) return null;
    final cached = _resolvedObjectIds[fileId];
    if (cached != null) return cached;
    try {
      final data = await api.call(
        'SYNO.Office.Node',
        'get',
        preferredVersion: _negotiate('SYNO.Office.Node', _v1),
        params: {'path': 'id:$fileId', 'basic': 'true'},
      );
      // 官方 `loadDocDone` 读的就是 `object_id`（同时读 `encrypt`）
      final id = '${data['object_id'] ?? ''}'.trim();
      if (id.isNotEmpty) {
        _resolvedObjectIds[fileId] = id;
        return id;
      }
    } on DsmApiException catch (e) {
      if (!_paramStyleCodes.contains(e.code)) rethrow;
    }
    return null;
  }

  /// 服务端"参数形态不对"的私有码（Office 57350/57351 是
  /// "link_id/object_id 形式不被接受"，120/114 是通用参数错）
  static const Set<int> _paramStyleCodes = {114, 120, 57350, 57351};

  /// `Office.Node.Version/list`（v1）：Office 文档自己的版本列表。
  ///
  /// 只有 Synology Office 原生文档（`.odoc/.osheet/.oslides`）有；对普通文件
  /// 服务端回 `1000`（官方 Web 也是先判扩展名再走这条路）。
  ///
  /// **只发 `path=id:<file_id>`**（官方 Drive 页 `Utils.getPathId` 的形态，
  /// 真机验证可用）。`object_id` 形态已删：它唯一可能的来源是 `Node:get`
  /// 的 `object_id` 入参，而那个形态真机回 `1000`（见 [resolveObjectId]）。
  Future<List<OfficeVersionDto>> nodeVersions({
    required String fileId,
    int offset = 0,
    int limit = 30,
  }) async {
    if (fileId.isEmpty) {
      throw ArgumentError(
        dataText('apiFileIdOrObjectIdRequired', 'fileId 与 objectId 至少要给一个'),
      );
    }
    final data = await api.call(
      'SYNO.Office.Node.Version',
      'list',
      preferredVersion: _negotiate('SYNO.Office.Node.Version', _v1),
      params: {
        'path': 'id:$fileId',
        'offset': '$offset',
        'limit': '$limit',
        // 少了它回包里 `author` 只有 uid、没有名字（官方前端三个字段都开）
        'additional': jsonEncode(const {
          'uid': true,
          'name': true,
          'nickname': true,
        }),
      },
    );
    return OfficeVersionDto.listFromJson(data);
  }

  /// `Office.Node.Version/restore`（v1）→ 把某个历史版本恢复成当前内容。
  ///
  /// 官方白名单里 `path` 与 `object_id` 都收；这里**统一发 `path=id:<file_id>`**
  /// —— 它在 `Node.Version:list` 上真机验证可用，而 `object_id` 的来源
  /// （`Node:get` 的 `object_id` 入参）已被真机否掉（`1000`）。
  Future<void> restoreNodeVersion({
    required String fileId,
    required String version,
    String? password,
  }) async {
    await api.call(
      'SYNO.Office.Node.Version',
      'restore',
      preferredVersion: _negotiate('SYNO.Office.Node.Version', _v1),
      params: {
        'path': 'id:$fileId',
        'ver': version,
        if (password != null && password.isNotEmpty) 'password': password,
      },
    );
  }

  /// `Office.Node.Version/rename`（v1）→ 给版本命名（空名字 = 取消命名）。
  ///
  /// ⚠️ 官方白名单是 `object_id, ver, ver_name, overwrite` —— **不认 `path`**，
  /// 所以 [objectId] 必须是 [resolveObjectId] 解析出来的内部 id
  /// （真机实测：少了它就是 `114 缺少必需参数`）。
  Future<void> renameNodeVersion({
    required String objectId,
    required String version,
    required String verName,
  }) async {
    if (objectId.isEmpty) {
      throw ArgumentError(
        dataText(
          'apiRenameNeedsObjectId',
          'rename 只认 object_id：先调用 resolveObjectId()',
        ),
      );
    }
    await api.call(
      'SYNO.Office.Node.Version',
      'rename',
      preferredVersion: _negotiate('SYNO.Office.Node.Version', _v1),
      params: {
        'object_id': objectId,
        'ver': version,
        'ver_name': verName,
        'overwrite': 'true',
      },
    );
  }

  /// 导出**某个版本**的下载直链（`Office.Export/download` v1）。
  ///
  /// 官方 Drive 的版本面板是 `downloadOffice({format:'ms', ver})` →
  /// `exportNode` → `Office.Export/download {path:'id:<file_id>', format, ver}`。
  /// `format` 是**服务端要的产物格式码** —— 这里把 `'ms'` 按源扩展名换成
  /// 目标扩展名（真机唯一跑通的 `xlsx` 就是这种码），见
  /// [officeExportServerFormat]。
  String nodeVersionDownloadUrl({
    required String fileId,
    required String version,
    required String fileName,
    String format = 'ms',
  }) => exportDownloadUrl(
    fileId: fileId,
    format: officeExportServerFormat(fileName, format),
    version: version,
    fileName: fileName,
  );

  /// `Office.Export/download` v1 的下载直链（**带鉴权参数**，直接 `getBytes` 即可）。
  ///
  /// 官方 `exportNode` 的参数白名单逐字是 `path,object_id,password,format,ver`
  /// （`ui.doc.js` 的 `SYNO.SDS.Office.Action.superclass.exportNode`），
  /// 默认还会塞一个 `password`（全局口令，没有就是空）。
  ///
  /// ⚠️ **真机只验过 `path` 这一种 id 形态**（`docs/live-write-verification.md` §3）：
  /// `{path:"id:<file_id>", format:"xlsx"}` → `200` + OOXML(ZIP)；
  /// 而 `link_id` → `57350`、`object_id` → `57351`、`Excel.save` → `57383`。
  /// 所以本文件**只发 `path`**（`exportBytes`/本方法都不再接受 `object_id`）。
  ///
  /// [format] 传**服务端格式码**（用 [officeExportServerFormat] 从
  /// `ms`/`odf` 映射）。[version] 为空 = 导**当前版本**（官方平时下载不带 `ver`）。
  String exportDownloadUrl({
    required String fileId,
    required String format,
    String? version,
    String? fileName,
    String password = '',
  }) {
    final v = _negotiate('SYNO.Office.Export', _v1);
    return api.authenticatedUrl(api.apiPath('SYNO.Office.Export'), {
      'api': 'SYNO.Office.Export',
      'version': '$v',
      'method': 'download',
      'path': 'id:$fileId',
      'format': format,
      if (version != null && version.isNotEmpty) 'ver': version,
      // 官方总会带这个键（没有口令时是空串）——照官方给上，别省
      'password': password,
      // 官方会把导出文件名带上（服务端据此定 Content-Disposition）
      if (fileName != null && fileName.isNotEmpty)
        'filename': officeExportFileName(fileName, format),
    });
  }

  /// 走 `Office.Export/download` 真取字节。
  ///
  /// ⚠️ **必须 POST 表单**（官方 `SYNO.API.Utils.download` 的语义）。真机实测
  /// （2026-09-20，`OFFICE_PROBE`）：把 `format=pdf` 放**查询串**上服务端**不认**，
  /// 回的是默认导出（`.docx`，`PK` 头，2947 B）；同样的参数放 form body 里
  /// 才拿到真 PDF（`%PDF-1.7`）。所以这条路不能用 [exportDownloadUrl] + GET。
  ///
  /// 参数形态（写入批次真机，`docs/live-write-verification.md` §3）：**只发
  /// `path=id:<file_id>`**（`object_id` 形态真机回 `57351`，已删）。
  /// ⚠️ 产物文件名来自服务端 `Content-Disposition` 的 basename，**不带扩展名**
  /// —— 落盘时用 [officeExportFileName] 自己补（调用方已这么做）。
  Future<List<int>> exportBytes({
    required String fileId,
    required String format,
    String? version,
    String? fileName,
    String password = '',
  }) async {
    final v = _negotiate('SYNO.Office.Export', _v1);
    return api.postBytesForm(api.apiPath('SYNO.Office.Export'), {
      'api': 'SYNO.Office.Export',
      'version': '$v',
      'method': 'download',
      // 真机唯一可用形态：`path=id:<file_id>`（`link_id`→57350、`object_id`→57351）
      'path': 'id:$fileId',
      'format': format,
      if (version != null && version.isNotEmpty) 'ver': version,
      'password': password,
      if (fileName != null && fileName.isNotEmpty)
        'filename': officeExportFileName(fileName, format),
    });
  }

  /// 模板正文导出要的产物格式码。
  ///
  /// 官方导出菜单是 `getExportItems() => ["ms","odf","pdf"]`（`ui.doc.js`，
  /// 偏移 **3104147**，逐字），落到 `Office.Export/download {format}`。
  /// 真机（第 265 轮，只读 POST 表单）对 `object_id = <模板 id>` 的实测：
  /// `ms` → 真 OOXML（docx/xlsx/pptx，`Content-Disposition` 带真实标题）；
  /// `odf` → ODF 包；`pdf` → 服务端回的是 **ODF 源**（转换没做，纯字节仍是
  /// `PK` + `mimetype application/vnd.oasis.*`，只把 Content-Type 写成
  /// `application/pdf`）⇒ 本仓**只用 `ms`**，交给既有 OOXML 阅读器。
  static const String kOfficeTemplateExportFormatMs = 'ms';

  /// `Office.Export/download` v1 → **模板正文的真实字节**（只读）。
  ///
  /// 这是官方 Web 客户端"预览模板"的真实机制（第 265 轮 SPK 取证）：
  /// 模板卡片的右键菜单第一项 `itemId:"open"` 文案就是 `cf.preview`，
  /// 处理函数 `openTemplate()` → `LocalStorage.WindowLaunch({url:
  /// getOfficeURL(template.link_id)})`，即**在 Office 阅读器里打开模板本体**；
  /// 而 `downloadOffice()` 对 `Env.is_template` 走的分支逐字是
  /// `e = Ext.apply({object_id: SYNO.SDS.Office.Env.objectId}, e)`
  /// ⇒ `Export/download` 支持用**模板 object_id** 导出（不是 `path=id:`）。
  ///
  /// 真机（第 265 轮，`https://nas.example.com:5001`，普通用户 `demo_user`）
  /// 53 个系统模板全部可导：`{object_id, format:"ms"}` → HTTP 200 + 真 OOXML
  /// （doc 13,039 B / sheet 14,536 B / presentation 29,008 B），
  /// `Content-Disposition` 分别是 `Meeting minutes.docx` / `Project timeline.xlsx`
  /// / `Countryside.pptx` ⇒ 与 `object_id` 对应的模板正文一致。
  ///
  /// ⚠️ 形态差异（别混）：**普通节点**的导出真机只认 `path=id:<file_id>`
  /// （`object_id` → `57351`，见 [exportBytes] 的注释）；**模板**恰好相反 ——
  /// 它不在 node 表里，只能用 `object_id`。两条都是实测结论，不互相替代。
  ///
  /// ⚠️ **必须 POST 表单**：`format` 放查询串上服务端会忽略（[postBytesForm] 的
  /// 文件头有 2026-09-20 的真机证据）。参数白名单逐字照官方
  /// `exportNode`：`path,object_id,password,format,ver`（这里只发 `object_id`
  /// + `format` + 官方默认的空 `password`）。
  ///
  /// 失败分类抛 [OfficeAttachmentException]（105/119/574xx/超时/网络各一类），
  /// UI 据此**如实回落**到缩略图并打印原因（AGENTS §2.0.17 ②）。
  Future<Uint8List> templateExportBytes({
    required String objectId,
    String format = kOfficeTemplateExportFormatMs,
  }) async {
    if (objectId.isEmpty) {
      throw OfficeAttachmentException(
        OfficeAttachmentErrorKind.missingParam,
        detail: dataText(
          'officeTemplateExportMissingId',
          '缺少 object_id，取不到模板正文',
        ),
      );
    }
    final v = _negotiate('SYNO.Office.Export', _v1);
    try {
      final bytes = await api.postBytesForm(
        api.apiPath('SYNO.Office.Export'),
        <String, dynamic>{
          'api': 'SYNO.Office.Export',
          'version': '$v',
          'method': 'download',
          'object_id': objectId,
          'format': format,
          // 官方默认总会带这个键（没有口令时是空串）——照官方给上。
          'password': '',
        },
      );
      if (bytes.isEmpty) {
        throw OfficeAttachmentException(
          OfficeAttachmentErrorKind.empty,
          detail: dataText('officeTemplateExportEmpty', '服务端返回了空正文'),
        );
      }
      return Uint8List.fromList(bytes);
    } on OfficeAttachmentException {
      rethrow;
    } on DsmApiException catch (e) {
      throw officeAttachmentExceptionFor(code: e.code, cause: e);
    } on DsmTransportException catch (e) {
      throw officeAttachmentExceptionFor(
        httpStatus: e.statusCode,
        networkMessage: e.message,
        cause: e,
      );
    } on TimeoutException catch (e) {
      throw OfficeAttachmentException(
        OfficeAttachmentErrorKind.timeout,
        cause: e,
        detail: dataText('officeTemplateExportTimeout', '取模板正文超时'),
      );
    } catch (e) {
      // 传输层不支持这条通道（例如测试里的假传输没有 POST 二进制）也要
      // 归一类，界面才能如实说"这条路不通"而不是崩掉（不吞原因：进 detail）。
      throw OfficeAttachmentException(
        OfficeAttachmentErrorKind.unknown,
        cause: e,
        detail: dataText('officeTemplateExportUnavailable', '这条通道在当前连接上不可用'),
      );
    }
  }

  /// `Office.Import/check`（v1）：转换前的校验。
  ///
  /// 官方调用点（两处，形状一致）：
  /// * `checkImportOffice` → `{files:[{path:'id:<file_id>'}]}`；
  /// * 带口令重试 → `{path:'id:<file_id>', password:'…'}`（`GenPasswordWindow` 分支）。
  ///
  /// 回包是 `{errors:[{code, path, file_id, name}]}`；**`57373` = 需要口令**
  /// （官方只挑这个码去弹口令窗），其它码是"这个文件转不了"。
  /// 空 `errors` = 可以转。
  Future<List<OfficeImportIssue>> importCheck({
    required String fileId,
    String password = '',
  }) async {
    final params = password.isEmpty
        ? <String, dynamic>{
            'files': jsonEncode([
              {'path': 'id:$fileId'},
            ]),
          }
        : <String, dynamic>{'path': 'id:$fileId', 'password': password};
    final data = await api.call(
      'SYNO.Office.Import',
      'check',
      preferredVersion: _negotiate('SYNO.Office.Import', _v1),
      params: params,
    );
    final errors = data['errors'];
    if (errors is! List) return const [];
    return [
      for (final e in errors)
        if (e is Map) OfficeImportIssue.fromJson(e.cast<String, dynamic>()),
    ];
  }

  /// `Office.Import/convert`（v1）：把上传的 Office 文件**转换成 Office 原生文档**。
  ///
  /// 官方 `convertOffice` 的参数白名单逐字是 `files,conflict_action,to_parent_folder`
  /// （`ui.doc.js` 的 `SYNO.SDS.Office.Action.superclass.convertOffice`），
  /// 调用方固定带 `conflict_action:'autorename'`，目标文件夹由"转换为…"对话框选。
  /// 转换结果**不在回包里消费**（官方只刷新列表），所以这里也不依赖回包形状。
  ///
  /// [password] 非空时按官方 `additional_passwords` 形态带上（`[{path, password}]`）。
  Future<Map<String, dynamic>> importConvert({
    required String fileId,
    String conflictAction = 'autorename',
    String? toParentFolderId,
    String password = '',
  }) async {
    final params = <String, dynamic>{
      'files': jsonEncode([
        {'path': 'id:$fileId'},
      ]),
      'conflict_action': conflictAction,
      if (toParentFolderId != null && toParentFolderId.isNotEmpty)
        'to_parent_folder': 'id:$toParentFolderId',
      if (password.isNotEmpty)
        'additional_passwords': jsonEncode([
          {'path': 'id:$fileId', 'password': password},
        ]),
    };
    return api.call(
      'SYNO.Office.Import',
      'convert',
      preferredVersion: _negotiate('SYNO.Office.Import', _v1),
      params: params,
    );
  }

  // ------------------------------- Office.Template / Theme（服务端模板库 / 主题）
  //
  // 权威事实（`docs/office-sample-corpus.md` §9，2026-09-22）：
  //   * 方法名来自 NAS 上装的 `webapi/SYNO.Office.lib`（纯 JSON，逐字）：
  //     `Template` v1 = `publish save make list get set delete request`；
  //     `Template.Thumb` = `get`；`Theme` v1 = `apply list`；`Theme.Thumb` = `get`；
  //   * 参数名来自官方 Web 前端的白名单（`ui/dist/ui.drive.js` / `ui.presentation.js`）：
  //       - `listTemplate` / `listTheme` 只 `copyTo({}, params, "ntype")`；
  //       - `makeTemplate` `copyTo(..., "object_id,title,default_title,password,encrypt,parent_id,ver")`；
  //       - `applyTheme` `copyTo(..., "ntype,object_id,password,theme_id,source_object_id,source_password,source_file_ids")`；
  //       - `Theme.Thumb:get` 前端传 `{ntype, id, retina}`；
  //   * 真机实测（同文档 §7.1/§7.2/§9.1）：
  //       - `Template:list` v1 **无参** → 53 条（presentation 24 / doc 16 / sheet 13）；
  //       - `Theme:list` v1 `{ntype:"presentation"}` → 17 条；
  //       - **`Template:make v1 {parent_id:"/mydrive", object_id:"1_invoice.tpl.doc"}` → 成功**，
  //         回完整 Drive 节点，正文 40 531 B（含 68 处 colspan）；
  //       - `Node:create` **不支持**从模板建（静默忽略模板参数）→ 两者别混。
  //   ⚠️ **成功回包未取**：`Theme:apply` / `Theme.Thumb:get` 的成功响应体没有取到
  //   → 本层只发**已钉的参数名**、把原始 `data` 透传给调用方，
  //   **不编字段名、不假装写成功**（失败如实抛出）。
  //   ★ 第 260 轮更新：`Template.Thumb:get` 的**成功回包已真机取证**——
  //   回的是 PNG 字节（不是 JSON 信封），1x/2x 可用，见 [templateThumbBytes]。

  /// `Office.Template/list` v1 → 服务端官方模板列表（真机 53 条）。
  ///
  /// [ntype] 可选（`presentation`/`doc`/`sheet`，官方 `listTemplate` 的白名单）；
  /// [mode]/[limit] 是官方"最近使用"store 用过的标量参数（真机未逐项复跑）。
  Future<List<OfficeTemplateDto>> templateList({
    String? ntype,
    String? mode,
    int? limit,
  }) async {
    final data = await api.call(
      'SYNO.Office.Template',
      'list',
      preferredVersion: _negotiate('SYNO.Office.Template', _v1),
      params: {
        if (ntype != null && ntype.isNotEmpty) 'ntype': ntype,
        if (mode != null && mode.isNotEmpty) 'mode': mode,
        if (limit != null) 'limit': '$limit',
      },
    );
    return OfficeTemplateDto.listFromJson(data);
  }

  /// `Office.Template/get` v1（需 `object_id`）→ 原始回包（含 `link_id`）。
  Future<Map<String, dynamic>> templateGet({required String objectId}) async {
    if (objectId.isEmpty) {
      throw ArgumentError(dataText('apiObjectIdRequired', '需要 object_id'));
    }
    return api.call(
      'SYNO.Office.Template',
      'get',
      preferredVersion: _negotiate('SYNO.Office.Template', _v1),
      params: {'object_id': objectId},
    );
  }

  /// `Office.Template/make` v1 —— **从模板新建**（真机已实测成功）。
  ///
  /// 参数逐字：`parent_id`（目标目录，真机给的是 **`"/mydrive"` 路径形态**）
  /// + `object_id`（模板 id，如 `1_invoice.tpl.doc`）；`title` 可选（不给则服务端
  /// 生成 `Untitled.odoc`）。`link_id` **不是**这里的参数（传了仍回 `120 缺 object_id`）。
  ///
  /// 回包是**完整 Drive 节点**（形如 `{capabilities, ctime, display_path, …}`），
  /// 调用方据此刷新目录/打开新文档。
  Future<Map<String, dynamic>> templateMake({
    required String parentId,
    required String objectId,
    String? title,
    String? defaultTitle,
    String password = '',
    bool encrypt = false,
  }) async {
    if (parentId.isEmpty || objectId.isEmpty) {
      throw ArgumentError(
        dataText('apiTemplateMakeNeedsIds', '从模板新建需要 parent_id 与 object_id'),
      );
    }
    return api.call(
      'SYNO.Office.Template',
      'make',
      preferredVersion: _negotiate('SYNO.Office.Template', _v1),
      params: {
        'parent_id': parentId,
        'object_id': objectId,
        if (title != null && title.isNotEmpty) 'title': title,
        if (defaultTitle != null && defaultTitle.isNotEmpty)
          'default_title': defaultTitle,
        if (password.isNotEmpty) 'password': password,
        if (encrypt) 'encrypt': 'true',
      },
    );
  }

  /// `Office.Theme/list` v1 + `ntype` → 主题列表（真机 `presentation` 17 套）。
  ///
  /// ⚠️ `ntype=doc` 真机回 114（**未取证此路不通**）→ 调用方按空/错误如实处理。
  Future<List<OfficeThemeDto>> themeList({required String ntype}) async {
    final data = await api.call(
      'SYNO.Office.Theme',
      'list',
      preferredVersion: _negotiate('SYNO.Office.Theme', _v1),
      params: {'ntype': ntype},
    );
    return OfficeThemeDto.listFromJson(data);
  }

  /// `Office.Theme/apply` v1 —— 应用主题（参数白名单逐字见官方 `applyTheme`）。
  ///
  /// ⚠️ **成功回包未取证**：本方法只发送已钉的参数并把原始 `data` 透传，
  /// **不把"调用没抛错"当成"主题写成功了"**（调用方需自行判定/如实提示）。
  Future<Map<String, dynamic>> themeApply({
    required String objectId,
    String? ntype,
    String? themeId,
    String? password,
    String? sourceObjectId,
    String? sourcePassword,
    String? sourceFileIds,
  }) async {
    if (objectId.isEmpty) {
      throw ArgumentError(dataText('apiObjectIdRequired', '需要 object_id'));
    }
    return api.call(
      'SYNO.Office.Theme',
      'apply',
      preferredVersion: _negotiate('SYNO.Office.Theme', _v1),
      params: {
        'object_id': objectId,
        if (ntype != null && ntype.isNotEmpty) 'ntype': ntype,
        if (themeId != null && themeId.isNotEmpty) 'theme_id': themeId,
        if (password != null && password.isNotEmpty) 'password': password,
        if (sourceObjectId != null && sourceObjectId.isNotEmpty)
          'source_object_id': sourceObjectId,
        if (sourcePassword != null && sourcePassword.isNotEmpty)
          'source_password': sourcePassword,
        if (sourceFileIds != null && sourceFileIds.isNotEmpty)
          'source_file_ids': sourceFileIds,
      },
    );
  }

  /// `Office.Template.Thumb/get` v1 的**带鉴权直链**。
  ///
  /// 官方 Web 端（`ui/dist/ui.doc.js` 的 `getThumbImg`）走
  /// `SYNO.API.GetBaseURL`（浏览器带 cookie）；我们不是浏览器，所以用
  /// [DsmWebApi.authenticatedUrl]（`_sid` 进查询串）。
  ///
  /// 参数**逐字对齐官方**：`api / version / method / object_id / ver / retina`
  /// （`retina=false` → 1x，`true` → 2x；真机 2x = 384×216 PNG）。
  /// [ver] 由调用方给（生产走 [OfficeTemplateDto.thumbVer]，**官方语义** =
  /// 系统模板不发 / 用户模板发 `publish_version`；**不是**内容哈希）。
  String templateThumbUrl({
    required String objectId,
    String? ver,
    bool retina = false,
  }) {
    final v = _negotiate('SYNO.Office.Template.Thumb', _v1);
    return api.authenticatedUrl(api.apiPath('SYNO.Office.Template.Thumb'), {
      'api': 'SYNO.Office.Template.Thumb',
      'version': '$v',
      'method': 'get',
      'object_id': objectId,
      if (ver != null && ver.isNotEmpty) 'ver': ver,
      // 官方两个值都发（探针实测同款）：'true' = 2x、'false' = 1x。
      'retina': retina ? 'true' : 'false',
    });
  }

  /// `Office.Template.Thumb/get` v1 → **缩略图 PNG 字节**。
  ///
  /// ★ 第 260 轮真机实测：该接口 `allowDownload: true` ⇒ 回的**是图片本身**，
  /// 不是 JSON 信封（`api.call` 解不了，必须走 [DsmWebApi.getBytes]）。
  /// 1x/2x 都是真 PNG、retina 尺寸翻倍。
  ///
  /// ★ 第 263 轮加固：`ver` 只是官方的缓存钩子，**发错了会被服务端整条拒**
  /// （真机 4/53 个模板的 40 位哈希 `ver` 回
  /// `120 {"name":"ver","reason":"type"}`）。所以带 `ver` 失败且失败形态像
  /// "服务端不接受这个 `ver`"（120 → [OfficeAttachmentErrorKind.unknown]／空字节）
  /// 时，**去掉 `ver` 再试一次**（只一次）：真机实测去掉后 53/53 都出图。
  /// 会话失效/超时/网络类失败**不**走这条退路（重试同一死因没意义，见
  /// AGENTS §2.0.8 ②的"别吞掉可诊断的原因"）。
  ///
  /// 失败按 [OfficeAttachmentException] 分类抛出（404/105/119/超时/网络…），
  /// UI 只给"缩略图暂不可用"的占位，**不弹错误码**。
  Future<Uint8List> templateThumbBytes({
    required String objectId,
    String? ver,
    bool retina = false,
  }) async {
    if (objectId.isEmpty) {
      throw OfficeAttachmentException(
        OfficeAttachmentErrorKind.missingParam,
        detail: dataText('officeTemplateThumbMissingId', '缺少 object_id，取不到缩略图'),
      );
    }
    try {
      return await _templateThumbOnce(
        objectId: objectId,
        ver: ver,
        retina: retina,
      );
    } on OfficeAttachmentException catch (e) {
      // 没发 ver → 没有可退的东西，原样抛。
      if (ver == null || ver.isEmpty) rethrow;
      // 只有"服务端嫌这个 ver 不对"才值得去掉 ver 重试；
      // 网络/超时/无权限/会话失效重试同一路径没意义（且可能放大负载）。
      final worthRetrying =
          e.kind == OfficeAttachmentErrorKind.unknown ||
          e.kind == OfficeAttachmentErrorKind.empty;
      if (!worthRetrying) rethrow;
      return _templateThumbOnce(objectId: objectId, ver: null, retina: retina);
    }
  }

  /// [templateThumbBytes] 的**单次**取图（一次 URL 构造 + 一次 `getBytes`），
  /// 把传输层/Dio 异常统一翻译成 [OfficeAttachmentException]。
  Future<Uint8List> _templateThumbOnce({
    required String objectId,
    required String? ver,
    required bool retina,
  }) async {
    final uri = templateThumbUrl(objectId: objectId, ver: ver, retina: retina);
    try {
      final bytes = await api.getBytes(uri);
      if (bytes.isEmpty) {
        throw OfficeAttachmentException(
          OfficeAttachmentErrorKind.empty,
          detail: dataText('officeTemplateThumbEmpty', '服务端返回了空缩略图'),
        );
      }
      return Uint8List.fromList(bytes);
    } on OfficeAttachmentException {
      rethrow;
    } on DsmApiException catch (e) {
      throw officeAttachmentExceptionFor(code: e.code, cause: e);
    } on DsmTransportException catch (e) {
      throw officeAttachmentExceptionFor(
        httpStatus: e.statusCode,
        networkMessage: e.message,
        cause: e,
      );
    } on TimeoutException catch (e) {
      throw OfficeAttachmentException(
        OfficeAttachmentErrorKind.timeout,
        cause: e,
        detail: dataText('officeTemplateThumbTimeout', '取缩略图超时'),
      );
    }
  }

  /// `Office.Theme.Thumb/get` v1 的**带鉴权直链**；参数逐字 `{ntype, id, retina}`。
  ///
  /// ⚠️ 成功回包未取证 → 同上，UI 默认无图回落。
  String themeThumbUrl({
    required String ntype,
    required String id,
    bool retina = false,
  }) {
    final v = _negotiate('SYNO.Office.Theme.Thumb', _v1);
    return api.authenticatedUrl(api.apiPath('SYNO.Office.Theme.Thumb'), {
      'api': 'SYNO.Office.Theme.Thumb',
      'version': '$v',
      'method': 'get',
      'ntype': ntype,
      'id': id,
      if (retina) 'retina': 'true',
    });
  }
}

/// 服务端模板条目（`Office.Template/list` 的 `items[]`）。
///
/// 字段名逐字来自真机回包（`docs/office-sample-corpus.md` §7.1）：
/// `object_id` / `ntype` / `title`(i18n key) / `capabilities{can_read,can_preview,…}`。
class OfficeTemplateDto {
  const OfficeTemplateDto({
    required this.objectId,
    required this.ntype,
    required this.titleKey,
    required this.capabilities,
    this.category,
    this.perm = '',
    this.isTemplate = false,
    this.system = false,
    this.encrypt = false,
    this.ctime,
    this.mtime,
    this.ver,
    this.publishVersion,
    this.sortOrder,
  });

  final String objectId;
  final String ntype;

  /// 服务端给的 **i18n key**（如 `theme_presentation:opinion` / `template_doc:invoice`）。
  /// **绝不直接上屏**——UI 要用 `officeTemplateTitleFromKey()`（查官方双语表）；
  /// 数据层拿不到当前语言，所以 [title] 只给一个 ASCII 可读回落。
  final String titleKey;

  final Map<String, Object?> capabilities;
  final String? category;

  /// 权限串（真机是 `"ro"` = 只读）。
  final String perm;

  final bool isTemplate;
  final bool system;
  final bool encrypt;
  final int? ctime;
  final int? mtime;

  /// 模板版本 —— **服务端给的是哈希字符串**（真机
  /// `"f26e4bacf7a38332c3f078c399c2bacdc8a198f6"`），不是序号。
  /// ⚠️ 别改回 `int`：那会让 `Template:list` 的整个列表抛类型错、页面全灭。
  /// 缩略图接口把这一串当 `ver` 参数原样发（官方 `getThumbImg` 同款）。
  final String? ver;

  /// `Template:get` 才回的发布版本（`Template:list` 上多数没有）。
  /// 缩略图 `ver` 的兜底：有些服务端只认这一串。
  final String? publishVersion;

  /// `Template:get` 才回的 `sort_order`（官方按它排组内顺序）。
  final int? sortOrder;

  /// 缩略图接口要的 `ver` —— **严格照官方 `getThumbImg` 的语义**：
  ///
  /// ```js
  /// ver: e.system ? SYNO.SDS.Config.FnMap["SYNO.SDS.Office.Doc.Application"]
  ///                  .config.version          // 系统模板 = Office 应用版本
  ///               : e.publish_version           // 用户模板 = publish_version
  /// ```
  /// （`~/synology_samples/spk/Office-3.8.0-22711.spk` 的 `ui/dist/ui.doc.js`，
  /// 偏移 3984557，逐字。）
  ///
  /// ★ 第 263 轮真机缺陷：**内容哈希 `ver` 不是这个参数该发的值**。
  /// 把 [ver]（`Template:list` 的 40 位哈希）当缩略图 `ver` 发时，真机 53 个
  /// 模板里有 **4 个**被服务端硬拒：
  /// `{"error":{"code":120,"errors":{"name":"ver","reason":"type"}}}`（HTTP 200）
  /// ⇒ 取不到图（原始证据见 `docs/office-template-gallery.md` §8）。
  /// 这 4 个哈希**对任意 `object_id` 都被拒**（是"值"的问题，不是某个模板的
  /// 问题），而换任意别的字符串就出图 ⇒ 只能是不该把内容哈希当 `ver` 发。
  ///
  /// 我们拿不到官方的"应用版本"（它来自 DSM 的
  /// `SYNO.SDS.Config.FnMap['SYNO.SDS.Office.Doc.Application'].config.version`，
  /// 移动端没有这份配置；真机把 SPK 版本串 `3.8.0-22711` 当 `ver` 发同样被
  /// `120 type` 拒），所以系统模板**不发 `ver`**：真机实测"不发 ⇒ 53/53 出
  /// PNG"，且服务端的静态缩略图处理器（`SYNO.Office.Template.Thumb.so`）根本
  /// 不按 `ver` 取文件（它读 `template/<ntype>/…/1x.png|2x.png`）。
  ///
  /// 用户模板仍按官方发 `publish_version`（没有就不发）。
  String? get thumbVer {
    if (system) return null;
    final p = publishVersion;
    if (p != null && p.isNotEmpty) return p;
    return null;
  }

  /// 只读权限判定（`perm == "ro"`）——与能力位 [canRead] 互补，
  /// **不单独决定能不能用模板**（能力位才是服务端授权结论）。
  bool get readOnly => perm.toLowerCase() == 'ro';

  bool get canRead => jsonBool(capabilities['can_read']) ?? false;
  bool get canPreview => jsonBool(capabilities['can_preview']) ?? false;
  bool get canDownload => jsonBool(capabilities['can_download']) ?? false;

  /// 可读名（**不是** i18n key）。官方随包没有 `theme_presentation` /
  /// `template_doc` / `template_sheet` 的译文资源，所以这里用
  /// [officeLibraryTitleFromKey] 从 key 派生可读名；报告已登记。
  String get title => officeLibraryTitleFromKey(titleKey);

  /// i18n key 的 section（`:` 前）；无 `:` → 按 `ntype` 推断。
  String? get titleSection {
    final i = titleKey.indexOf(':');
    return i > 0 ? titleKey.substring(0, i) : null;
  }

  static OfficeTemplateDto fromJson(Map<String, dynamic> json) {
    // ★ AGENTS §2.0.12：服务端字段类型不保证（布尔可能是 1/"true"，id 可能是数字），
    // 一律走宽松助手。**不许**再写裸 `as bool` / `as num?`。
    final verRaw = jsonStr(json['ver']);
    final publishRaw = jsonStr(json['publish_version']);
    final categoryRaw = json['category'];
    return OfficeTemplateDto(
      objectId: jsonStr(json['object_id']),
      ntype: jsonStr(json['ntype']),
      titleKey: jsonStr(json['title']),
      capabilities: jsonMap(json['capabilities']),
      category: categoryRaw == null || jsonStr(categoryRaw).isEmpty
          ? null
          : jsonStr(categoryRaw),
      perm: jsonStr(json['perm']),
      isTemplate: jsonBool(json['is_template']) ?? false,
      system: jsonBool(json['system']) ?? false,
      encrypt: jsonBool(json['encrypt']) ?? false,
      ctime: jsonInt(json['ctime']),
      mtime: jsonInt(json['mtime']),
      // 服务端给的是**哈希字符串**（真机 `"f26e4bac…"`）⇒ 用 String 建模，
      // 不再硬转 int（旧写法会让整个列表崩掉，见 [officeJsonInt]）。
      ver: verRaw.isEmpty ? null : verRaw,
      publishVersion: publishRaw.isEmpty ? null : publishRaw,
      sortOrder: jsonInt(json['sort_order']),
    );
  }

  /// ★ 真机实测（第 260 轮）：`SYNO.Office.Template:list` 的顶层键是
  /// **`items`**（`{items, offset, total}`）——不是 `list`。
  /// 按 `list` 读会**静默 0 条**（看着像"服务器没有模板"）。
  static List<OfficeTemplateDto> listFromJson(Map<String, dynamic> data) {
    return <OfficeTemplateDto>[
      for (final e in jsonMapList(data['items'])) OfficeTemplateDto.fromJson(e),
    ];
  }
}

/// 宽松整数解析：`int`/`double`/数字字符串 → `int`，其余（含 `null`、哈希串）→ `null`。
///
/// ★ 第 257 轮真机缺陷（`docs/drive-office-create.md`）：
/// `SYNO.Office.Template:list` 的 `ver` 在真机上是**字符串哈希**
/// （`"f26e4bacf7a3…"`），而旧代码写 `(json['ver'] as num?)?.toInt()`
/// ⇒ `type 'String' is not a subtype of type 'num'?` ⇒ **整页模板库加载失败**。
/// 服务端字段类型不保证 ⇒ 一律用这里，别裸 `as num?`。
int? officeJsonInt(Object? value) => jsonInt(value);

/// 主题条目（`Office.Theme/list` 的 `tpl[]`）。
///
/// 字段名逐字来自真机回包（§7.2）：`{id, order, title_key, title_section}`。
class OfficeThemeDto {
  const OfficeThemeDto({
    required this.id,
    required this.order,
    required this.titleKey,
    required this.titleSection,
  });

  final String id;
  final int order;
  final String titleKey;
  final String titleSection;

  /// 可读名（不是 key）；见 [OfficeTemplateDto.title] 的说明。
  String get title => officeLibraryTitleFromKey(
    titleSection.isEmpty ? titleKey : '$titleSection:$titleKey',
  );

  static OfficeThemeDto fromJson(Map<String, dynamic> json) => OfficeThemeDto(
    id: '${json['id'] ?? ''}',
    order: officeJsonInt(json['order']) ?? 0,
    titleKey: '${json['title_key'] ?? ''}',
    titleSection: '${json['title_section'] ?? ''}',
  );

  static List<OfficeThemeDto> listFromJson(Map<String, dynamic> data) {
    final tpl = data['tpl'];
    if (tpl is! List) return const <OfficeThemeDto>[];
    final out = <OfficeThemeDto>[
      for (final e in tpl)
        if (e is Map) OfficeThemeDto.fromJson(e.cast<String, dynamic>()),
    ]..sort((a, b) => a.order.compareTo(b.order));
    return out;
  }
}

/// 把服务端 i18n key（`section:key`）派生为**可读名**（`Opinion` / `Todo List`）。
///
/// 为什么不是真译文：官方随包（SPK 3.8.0-22711）**没有** `theme_presentation` /
/// `template_doc` / `template_sheet` 三个 section 的译文资源（`ui/locale/` 下无匹配），
/// 服务端也只回 key。这里去掉 section 前缀、把 `_` 拆词并首字母大写作为**可读回落**，
/// 让界面**不把 i18n key 当名字显示**；官方译文到位后替换本函数即可。
String officeLibraryTitleFromKey(String? titleKey) {
  var key = (titleKey ?? '').trim();
  if (key.isEmpty) return '';
  final colon = key.indexOf(':');
  if (colon >= 0) key = key.substring(colon + 1);
  final words = key
      .split(RegExp(r'[_\-\s]+'))
      .where((w) => w.isNotEmpty)
      .toList();
  if (words.isEmpty) return key;
  return words
      .map(
        (w) => w.length == 1
            ? w.toUpperCase()
            : '${w[0].toUpperCase()}${w.substring(1)}',
      )
      .join(' ');
}

/// `Office.Import/check` 回包 `errors[]` 的一条。
///
/// 真机/官方出处：官方只对 **`57373`（需要口令）** 弹口令窗，其余码按文案报错
/// （`ui.doc.js` 的 `checkImportOfficeDone`）。
class OfficeImportIssue {
  const OfficeImportIssue({
    required this.code,
    this.name = '',
    this.path = '',
    this.fileId = '',
  });

  final int code;
  final String name;
  final String path;
  final String fileId;

  /// 需要文档口令（官方常量 `57373`）
  bool get needsPassword => code == 57373;

  static OfficeImportIssue fromJson(Map<String, dynamic> json) =>
      OfficeImportIssue(
        code: officeJsonInt(json['code']) ?? 0,
        name: '${json['name'] ?? ''}',
        path: '${json['path'] ?? ''}',
        fileId: '${json['file_id'] ?? ''}',
      );
}

/// `Office.Node.Attachment` 取字节失败的可分类原因（UI 据此给"能懂的重试"）。
enum OfficeAttachmentErrorKind {
  /// 入参不全（`object_id`/`file_id` 至少缺一个）——客户端错误，重试无用。
  missingParam,

  /// `404`：附件不存在 / 该文档没有这个 `file_id`（真机：只给 `file_id` 就是这个）。
  notFound,

  /// `105 noPermission`：账号没被授权看这个附件。
  noPermission,

  /// `119 sidNotFound` / `106 sessionTimeout`：会话失效，重登后可重试。
  sessionExpired,

  /// 请求超时（[kOfficeAttachmentTimeoutCode] / 传输层超时）。
  timeout,

  /// 其它网络/传输失败（连接断了、DNS、非 2xx 的其它码）。
  network,

  /// 服务端回了**空字节**（拿到了 200 但没有内容）。
  empty,

  /// 其它未归类的失败（Office 私有码等）。
  unknown,
}

/// 需求给定的"超时"分类码。
///
/// ⚠️ 本批**没有在 `Attachment:get` 上对 `code=6` 复跑取证**（真机只验了
/// 404/105/119），这里只把它当作分类兜底：真出现 6 就归到 [timeout]，
/// 不给用户弹出"未知错误"。
const int kOfficeAttachmentTimeoutCode = 6;

/// `Office.Node.Attachment` 的失败（**可区分**，不吞成通用 `Exception`）。
class OfficeAttachmentException implements Exception {
  const OfficeAttachmentException(
    this.kind, {
    this.dsmCode,
    this.httpStatus,
    this.detail = '',
    this.cause,
  });

  final OfficeAttachmentErrorKind kind;

  /// DSM 业务错误码（105/119/6/Office 私有码…）；HTTP 层的 404 为 null。
  final int? dsmCode;

  /// HTTP 状态码（404 在这里）；DSM 信封错误为 null。
  final int? httpStatus;

  /// 面向日志/报告的补充说明（**不直接上屏**；UI 有自己的文案映射）。
  final String detail;

  /// 原始异常（便于日志与测试断言因果）。
  final Object? cause;

  /// 会话失效 → 调用方可以重登后重试。
  bool get isSessionExpired => kind == OfficeAttachmentErrorKind.sessionExpired;

  /// 附件不存在 → 重试无意义（UI 只给"换一张/联系管理员"级别的说明）。
  bool get isNotFound => kind == OfficeAttachmentErrorKind.notFound;

  @override
  String toString() =>
      'OfficeAttachmentException(${kind.name}'
      '${dsmCode == null ? '' : ', code=$dsmCode'}'
      '${httpStatus == null ? '' : ', http=$httpStatus'}'
      '${detail.isEmpty ? '' : ', $detail'})';
}

/// 把"HTTP 状态码 / DSM 错误码 / 传输层消息"归一到 [OfficeAttachmentException]。
///
/// 纯函数（无副作用）→ 离线用例可以直接断言每种失败落到哪一类。
/// 真机 2026-10-22 实测：`Node.Attachment:get` 在参数齐全（object_id + file_id）
/// 的情况下仍可能回 **120** —— 见 `attachmentGet` 与 DA197。
const int kOfficeAttachmentServerGone = 120;

OfficeAttachmentException officeAttachmentExceptionFor({
  int? code,
  int? httpStatus,
  String? networkMessage,
  Object? cause,
}) {
  if (httpStatus == 404 || code == 404) {
    return OfficeAttachmentException(
      OfficeAttachmentErrorKind.notFound,
      httpStatus: httpStatus,
      dsmCode: code,
      cause: cause,
      detail: dataText('officeAttachmentNotFound', '附件不存在（404）'),
    );
  }
  switch (code) {
    case DsmErrorCode.noPermission: // 105
      return OfficeAttachmentException(
        OfficeAttachmentErrorKind.noPermission,
        dsmCode: code,
        httpStatus: httpStatus,
        cause: cause,
        detail: dataText('officeAttachmentNoPermission', '没有权限查看这个附件（105）'),
      );
    case DsmErrorCode.sidNotFound: // 119
    case DsmErrorCode.sessionTimeout: // 106
      return OfficeAttachmentException(
        OfficeAttachmentErrorKind.sessionExpired,
        dsmCode: code,
        httpStatus: httpStatus,
        cause: cause,
        detail: dataText(
          'officeAttachmentSessionExpired',
          '会话已失效（$code）',
        ).replaceAll('{code}', '$code'),
      );
    case kOfficeAttachmentTimeoutCode:
      return OfficeAttachmentException(
        OfficeAttachmentErrorKind.timeout,
        dsmCode: code,
        httpStatus: httpStatus,
        cause: cause,
        detail: dataText('officeAttachmentTimeout', '取图片超时'),
      );
  }
  if (httpStatus != null && httpStatus >= 400) {
    return OfficeAttachmentException(
      OfficeAttachmentErrorKind.network,
      dsmCode: code,
      httpStatus: httpStatus,
      cause: cause,
      detail: dataText(
        'officeAttachmentHttpFailed',
        '请求失败（HTTP $httpStatus）',
      ).replaceAll('{status}', '$httpStatus'),
    );
  }
  // 传输层超时在 Dio 里没有状态码，只有消息（中英文都可能）。
  final msg = (networkMessage ?? '').toLowerCase();
  if (msg.contains('timeout') ||
      msg.contains('timed out') ||
      msg.contains('超时')) {
    return OfficeAttachmentException(
      OfficeAttachmentErrorKind.timeout,
      dsmCode: code,
      httpStatus: httpStatus,
      cause: cause,
      detail: dataText('officeAttachmentTimeout', '取图片超时'),
    );
  }
  return OfficeAttachmentException(
    OfficeAttachmentErrorKind.unknown,
    dsmCode: code,
    httpStatus: httpStatus,
    cause: cause,
    detail: networkMessage ?? '',
  );
}

/// Synology Office 原生文档的三种扩展名（官方 `isOfficeFile` 就判这三个）
const Set<String> officeNativeExtensions = {'odoc', 'osheet', 'oslides'};

/// **可选**能力位：`SYNO.Office.Snapshot`（只读原生内容树通道）。
///
/// 缺位 = 该通道跳过并回落（见 `office_viewer_page.dart` 的三跳优先级），
/// 只让服务降级成 `partial`，**绝不隐藏 Office 模块**。
const String kOfficeSnapshotApi = 'SYNO.Office.Snapshot';

/// 是否是 Synology Office 原生文档（按扩展名，大小写不敏感）
bool isOfficeNativeName(String name) {
  final dot = name.lastIndexOf('.');
  if (dot < 0 || dot == name.length - 1) return false;
  return officeNativeExtensions.contains(name.substring(dot + 1).toLowerCase());
}

/// 官方 `EXPORT_EXTENSION` 的对应关系（`ui.doc.js`）：
/// doc→docx、sheet→xlsx、slides→pptx。导出时把 `.odoc` 换成目标扩展名。
String exportFileName(String name) {
  final dot = name.lastIndexOf('.');
  if (dot <= 0) return name;
  final base = name.substring(0, dot);
  final ext = name.substring(dot + 1).toLowerCase();
  final target = switch (ext) {
    'odoc' => 'docx',
    'osheet' => 'xlsx',
    'oslides' => 'pptx',
    _ => ext,
  };
  return '$base.$target';
}

/// `Office.Export/download` 的 `format` 取值。
///
/// 早期真机实测（2026-09-20，`OFFICE_PROBE` 探针，NAS = DSM 7.4 + Office 3.8.0-22711）：
///
/// | 发出去的 `format` | `.odoc` 回包 | `.osheet` 回包 |
/// |---|---|---|
/// | `ms`（默认） | 9175 B，docx（OOXML） | 6260 B，xlsx（OOXML） |
/// | `odf` | 2947 B，`mimetype application/vnd.oasis.opendocument.text` | 3540 B，`…spreadsheet` |
/// | `pdf` | 2948 B，**还是 odt** | — |
/// | `csv` | — | 6260 B，**还是 xlsx** |
///
/// 写入批次真机（`docs/live-write-verification.md` §3，**权威**）只验了一种形状：
/// `{path:"id:<file_id>", format:"xlsx"}` → `200` + OOXML(ZIP)，且明确
/// 「**产物格式由 `format` 参数决定**」——`xlsx` 就是**目标扩展名**。
/// ⇒ 保守起见，微软格式这一档按源扩展名换成目标扩展名发（[officeExportServerFormat]）；
/// `odf` 原样透传（只有早期探针验过，本批未复跑 → 见文档「未验证边界」）。
///
/// 所以**服务端只有「微软」与「OpenDocument」两种导出**：
/// * 「导出 PDF」在官方 Web 端是**浏览器打印**（`ui.doc.js` 的 `downloadOffice`
///   一看到 `format:'pdf'` 就改调 `editorPanel.print()`，根本不发这个接口）；
/// * 「导出 CSV」是**前端自己拼的**（`ui.sheet.js` 的 `downloadCsv` 从工作簿
///   读出全部单元格文本再 join），服务端不认。
///
/// ⚠️ 这两个值留着只是为了让"官方有、我们不做"的事实可查；`officeExportFormatsFor`
/// **不会**把它们列给用户 —— 发了也是白拿一份格式不对的文件（名字叫 .pdf 其实是 odt）。
enum OfficeExportFormat {
  /// 微软格式：odoc→docx / osheet→xlsx / oslides→pptx（官方 `EXPORT_EXTENSION`）
  ms('ms', 'Office 文件'),

  /// OpenDocument：odoc→odt / osheet→ods / oslides→odp（官方 `to_odf` 文案 + 后缀）
  odf('odf', 'OpenDocument'),

  /// 服务端不产出 PDF（会静默回落到 ODF），只在文档/文件名映射里保留
  pdf('pdf', 'PDF'),

  /// 服务端不产出 CSV（官方是前端生成），同上
  csv('csv', 'CSV');

  const OfficeExportFormat(this.code, this.label);

  final String code;

  /// 中文回落（界面侧读 [labelText]；`lib/src/features/**` 本轮不在迁移范围内）
  final String label;

  /// ARB key（`odf`/`pdf`/`csv` 是格式缩写，与语言无关 → null）
  String? get labelKey =>
      this == OfficeExportFormat.ms ? 'officeFormatMs' : null;

  /// 当前语言文案；数据层不能碰 `AppText`，走 `data_text.dart` 的 [dataText]
  String labelText() {
    final k = labelKey;
    return k == null ? label : dataText(k, label);
  }
}

/// 某个 Office 原生文档能导出哪些格式（**只列服务端真能产出的**）。
///
/// 顺序＝菜单顺序：先把"给别人看的 Office 文件"放前面，再是 ODF。
List<OfficeExportFormat> officeExportFormatsFor(String name) {
  if (!isOfficeNativeName(name)) return const [];
  return const [OfficeExportFormat.ms, OfficeExportFormat.odf];
}

/// 导出后的文件名（`format` 决定后缀，微软格式按官方 `EXPORT_EXTENSION` 映射）。
String officeExportFileName(String name, String format) {
  final dot = name.lastIndexOf('.');
  final base = dot <= 0 ? name : name.substring(0, dot);
  final ext = dot <= 0 ? '' : name.substring(dot + 1).toLowerCase();
  return switch (format) {
    'pdf' => '$base.pdf',
    'csv' => '$base.csv',
    'odf' => switch (ext) {
      'odoc' => '$base.odt',
      'osheet' => '$base.ods',
      'oslides' => '$base.odp',
      _ => '$base.odt',
    },
    _ => exportFileName(name),
  };
}

/// `Office.Export/download` 要发出去的 **`format` 参数**（服务端格式码）。
///
/// 真机证据（`docs/live-write-verification.md` §3）：唯一跑通并落成合法 OOXML 的
/// 形状是 `{path:"id:<file_id>", format:"xlsx"}` → `HTTP 200` +
/// `application/octet-stream` + `PK\x03\x04`；且结论写明「**产物格式由 `format`
/// 参数决定**」——所以服务端认的就是**目标扩展名**，不是 `ms` 这种档位名。
///
/// * `ms` → 按源扩展名换成目标扩展名：`.osheet`→`xlsx`（**真机已验**）、
///   `.odoc`→`docx`、`.oslides`→`pptx`；
/// * 其它（`odf`/`pdf`/`csv`）原样透传（早期探针验过 `odf`，本批未复跑）。
///
/// ⚠️ 产物文件名来自服务端 `Content-Disposition` 的 basename 且**不带扩展名**
/// —— 落盘名要用 [officeExportFileName] 自己补。
String officeExportServerFormat(String name, String format) {
  if (format != 'ms') return format;
  final dot = name.lastIndexOf('.');
  final ext = dot <= 0 ? '' : name.substring(dot + 1).toLowerCase();
  return switch (ext) {
    'osheet' => 'xlsx',
    'oslides' => 'pptx',
    _ => 'docx',
  };
}

/// 能"转换成 Office 文档"的扩展名。
///
/// ⚠️ 这是**客户端提示**（决定菜单项显不显示），权威判定在服务端：
/// `Office.Import/check` 会用 `errors[].code` 回答这个文件到底能不能转。
/// 依据：Office 包的 `SYNO.Office.Import.so` 里有
/// `IsSupportDocType/IsSupportSheetType/IsSupportSlideType/IsSupportMSOfficeXMLType`
/// 四组判定（文档/表格/演示/MS XML），覆盖面就是下面这几类。
const Set<String> officeConvertibleExtensions = {
  // 文档 → odoc
  'doc', 'docx', 'odt', 'rtf', 'txt', 'html', 'htm',
  // 表格 → osheet
  'xls', 'xlsx', 'ods', 'csv', 'tsv',
  // 演示 → oslides
  'ppt', 'pptx', 'odp',
};

/// 是不是"可以试着转成 Office 文档"的文件（不含已经是原生格式的）
bool isOfficeConvertibleName(String name) {
  final dot = name.lastIndexOf('.');
  if (dot < 0 || dot == name.length - 1) return false;
  final ext = name.substring(dot + 1).toLowerCase();
  if (officeNativeExtensions.contains(ext)) return false;
  return officeConvertibleExtensions.contains(ext);
}

/// 转换后会得到哪种 Office 原生文档（扩展名）
String officeConvertedExtension(String name) {
  final dot = name.lastIndexOf('.');
  final ext = dot < 0 ? '' : name.substring(dot + 1).toLowerCase();
  return switch (ext) {
    'xls' || 'xlsx' || 'ods' || 'csv' || 'tsv' => 'osheet',
    'ppt' || 'pptx' || 'odp' => 'oslides',
    _ => 'odoc',
  };
}

/// 转换后的文件名（`报告.docx` → `报告.odoc`；服务端 `autorename` 可能再加 ` (2)`）
String officeConvertedFileName(String name) {
  final dot = name.lastIndexOf('.');
  final base = dot <= 0 ? name : name.substring(0, dot);
  return '$base.${officeConvertedExtension(name)}';
}

/// `Office.Info/get` 的可用信息（真机实测字段）
class OfficeInfo {
  const OfficeInfo({
    required this.uid,
    required this.username,
    required this.version,
    required this.schemaDoc,
    required this.schemaSheet,
    required this.schemaSlide,
  });

  final int uid;
  final String username;

  /// 形如 `3.7.2`（`version.major.minor` + `hotfix`）
  final String version;
  final int schemaDoc;
  final int schemaSheet;
  final int schemaSlide;

  static OfficeInfo fromJson(Map<String, dynamic> json) {
    final v = (json['version'] as Map?)?.cast<String, dynamic>() ?? const {};
    String part(Object? x) => '${x ?? ''}'.trim();
    final version = [
      part(v['major']),
      part(v['minor']),
      if (part(v['hotfix']).isNotEmpty) part(v['hotfix']),
    ].where((s) => s.isNotEmpty).join('.');
    int num_(Object? x) => x is num ? x.toInt() : int.tryParse('$x') ?? 0;
    return OfficeInfo(
      uid: num_(json['uid']),
      username: '${json['username'] ?? ''}',
      version: version,
      schemaDoc: num_(json['schema_doc']),
      schemaSheet: num_(json['schema_sheet']),
      schemaSlide: num_(json['schema_slide']),
    );
  }
}

// ------------------------------------------------ Snapshot 内容树 → 原生解析层

/// `Snapshot:get` 通道**这次用不了**的信号（触发回落到下一跳，不弹错误面板）。
///
/// 区别于网络/权限错误：这是"拿到了回包，但形态对不上解析层"的确定性降级。
class OfficeSnapshotUnavailableException implements Exception {
  OfficeSnapshotUnavailableException(this.reason);

  final String reason;

  @override
  String toString() => 'OfficeSnapshotUnavailableException: $reason';
}

/// 把 `Office.Snapshot:get v4` 的**内容树**适配成原生解析层的 section 字典。
///
/// 接的是已定稿的 `OfficeNativeReader.parseSections`（`lib/src/data/office_native/**`，
/// **只调用不修改**）。真机回包形态（`docs/live-nas-verification.md` §⑦）：
///
/// ```json
/// {"data": {"comment": null,
///           "content": {"data": {"attrs": {"schema": 13, "type": "document"},
///                                "content": [ ... ]}},
///           "file": [...], "ntype": ..., "object_id": ...}}
/// ```
///
/// * `.odoc` / `.oslides`：`data.content` 与 OFile `@C_text/content` section 同形
///   → 直接包成 `{'content': data.content}`；
/// * `.osheet`：内容树与原生 section（`index`/`style`/`sh_*`）的对应关系**未取证**
///   —— 只有回包本身长得像 section 字典才敢用，否则返回 `null`，由调用方回落。
///
/// 返回 `null` = 这条路读不了（**不猜形态、不伪造空文档**）。
Map<String, Object?>? officeSectionsFromSnapshot(
  Map<String, dynamic> data, {
  required OfficeNativeFormat format,
}) {
  final content = asJsonMap(data['content']);
  if (content == null) return null;
  switch (format) {
    case OfficeNativeFormat.osheet:
      return _looksLikeNativeSectionMap(content) ? content : null;
    case OfficeNativeFormat.odoc:
    case OfficeNativeFormat.oslides:
      if (content['data'] != null) return {'content': content};
      return _looksLikeNativeSectionMap(content) ? content : null;
  }
}

/// ★★ 第 309 轮：快照回包里**根本没有内容**吗？（官方"回落空白文档"的判据）
///
/// 官方逐字（`ui/dist/ui.doc.js` `cbWebAPIGetNode`）：
/// ```js
/// var a = o.content?.data || this.getDefaultDocJson()   // getPresetJson()
/// ```
/// 即 `content` 为空、或 `content.data` 为空 ⇒ **用预设空白文档**，**不报错**；
/// `ui.presentation.js initProseMirror` 同款（`sourceInfo.content ? … : preset`）。
///
/// 判据（**故意只判"缺"，不判"怪"**）：
/// * `content` 缺键 / `null` / 空 map ⇒ `true`（缺内容）；
/// * `content` 是 map 且 `data` 为 `null` ⇒ `true`（官方同判：`?.data` 为假）；
/// * `data` 存在（哪怕是字符串/数字这种怪形态）⇒ `false` —— 交给调用方按
///   **"形态确实对不上 ⇒ 报错"** 处置（不许把怪形态伪装成空文档）。
bool officeSnapshotContentMissing(Map<String, Object?> data) {
  final content = data['content'];
  if (content == null) return true;
  if (content is! Map) return false;
  if (content.isEmpty) return true;
  return content['data'] == null;
}

/// 空白 `.odoc` 的内容树（`Snapshot:get` 取不到内容时的回落值）。
///
/// ## 与官方的差异（第 312 轮已更正过一次错的记述）
/// ⚠️ 曾经这里写着"官方 preset 是 `doc→[invisible, style_editor]`，**没有可写的正文块**"。
/// **那是错的**：那段来自 schema **迁移器**的 preset（`ui.doc.js` 里紧邻 `migrate` 的
/// `preset:e=>{…length:7…}`）。**运行时** preset（`getPresetJson()`）逐字包含 `edit_area`：
/// `doc.content = "settings style_editor invisible edit_area page_decorate"`
/// （已复核：`grep -oaF 'settings style_editor invisible edit_area page_decorate' ui.doc.js`
/// = **1** 命中；`edit_area` 在 `ui.doc.js` 命中 **18** 次；官方 16 个 doc 模板
/// `template/doc/*/text.json` 也**全部**含 `edit_area`）。
/// 官方 caret 就落在 `edit_area` 里：`getInitialSelection` 取
/// `queryChildOffset("edit_area", !0) + 1`，首次输入的步是
/// `{stepType:'replace', from:21, to:21, slice:{content:[{type:'text',text:'a'}]}}`
/// —— `from == to` ⇒ **插入**。
/// 我方此处回落成 `doc → edit_area → paragraph`：**节点类型对得上**，
/// 但**少了 4 个顶层兄弟**（`settings` / `style_editor` / `invisible` / `page_decorate`）。
/// 照抄整份 preset 需要视图能把 `style_editor` / `page_decorate` 渲染成只读装饰
/// （本仓已能渲染，见 `office_doc_view.dart`），差异记在此处、
/// `docs/evidence-r311/README.md` 与 `AGENTS.md §2.0.47③`。
const Map<String, Object?> kOfficeBlankDocTree = <String, Object?>{
  'type': 'doc',
  'attrs': <String, Object?>{'schema': 13},
  'content': <Object?>[
    <String, Object?>{
      'type': 'edit_area',
      'attrs': <String, Object?>{},
      'content': <Object?>[
        <String, Object?>{
          'type': 'paragraph',
          'attrs': <String, Object?>{},
          'content': <Object?>[],
        },
      ],
    },
  ],
};

/// 长得像原生 section 字典（`.osheet` 的 `sh_*` / `style`+`define`）。
bool _looksLikeNativeSectionMap(Map<String, Object?> sections) =>
    sections.keys.any((k) => k.startsWith('sh_')) ||
    (sections.containsKey('style') && sections.containsKey('define'));

/// `Office.Node/create` 的 `ntype` 取值 —— **三种**：`doc` / `sheet` /
/// `presentation`。
///
/// ## ★ 第 257 轮更正：演示文稿**可以**空白新建（此前判断是错的）
///
/// 旧注释写"官方 `ApiSynoOfficeNode` 只有 doc/sheet ⇒ 演示文稿只能走
/// `Template:make`"。**安卓 APK 只有两个类型是对的**，但它不是全集：
/// 官方把创建入口做在 **Office Web 客户端**里，那里三种都给。
///
/// 证据（`Office-3.8.0-22711` SPK，`ui/dist/` 是官方前端）：
/// * `ui.doc.js` / `ui.drive.js` 的「新建」菜单逐个类型调
///   `createNode({ntype:"doc"})` / `({ntype:"sheet"})` /
///   `({ntype:"presentation"})`；
/// * `SYNO.SDS.Office.Utils.getNTypeByObjectId`（`ui.presentation.js`）：
///   `.doc`→`doc`、`.sh`→`sheet`、`.slide`→`presentation`；
/// * 服务端 `webapi/mgr/node/SYNO.Office.Node.so` 里 `ntype` 与
///   `encrypt` / `password` / `passwords` 同级出现。
///
/// 而且**加密新建**的菜单同样是这三种类型：
/// `new SYNO.SDS.Office.Encrypt.Window({ntype:"doc"|"sheet"|"presentation"})`。
///
/// ⚠️ 仍留一句旧警告：服务端对**未知** `ntype` 不报错 ⇒ 别把没证据的类型
/// 往里塞（`slide` / `slides` 都不是服务端取值，`.slide` 只是 object_id 后缀）。
enum OfficeNodeType {
  doc('doc'),
  sheet('sheet'),
  presentation('presentation');

  const OfficeNodeType(this.value);
  final String value;
}

/// `Permission:check` 的 `ntype` 取值 —— **必须**用官方映射，不能直接抄后缀。
///
/// ★★★ 第 314 轮真机缺陷（已修）：三个页面的 `loadGate()` 一直把 `object_id`
/// 的**原始后缀**当 `ntype` 发出去。doc 的后缀恰好就是官方取值 `doc`，所以文档页
/// 一直正常；**表格**的后缀是 `sh`（官方 `getNTypeByObjectId` 明确 `sh → sheet`），
/// 于是我们发 `ntype=sh` ⇒ `Permission:check` 回
/// `{readable:false, writable:false, commentable:false}`（真机读数），界面据此说
/// "No write/comment permission: opened read-only."（**假话**），写通道整条锁死。
/// 演示文稿同理（后缀 `slide` → 官方 `presentation`）。
///
/// 认不出来时**如实返回原后缀**（`_` 分支的官方行为也是 `default: return n`），
/// 不猜。
String officePermissionNtype(String objectId) {
  final mapped = officeNodeTypeFromObjectId(objectId);
  if (mapped != null) return mapped.value;
  final dot = objectId.lastIndexOf('.');
  return dot == -1 ? '' : objectId.substring(dot + 1);
}

/// 服务端模板 `object_id` → [OfficeNodeType]。
///
/// 逐字照官方 `SYNO.SDS.Office.Utils.getNTypeByObjectId`
/// （SPK `Office-3.8.0-22711` 的 `ui/dist/ui.presentation.js`）：
/// ```js
/// var t = e.match(/\.[a-z]*$/g);  // 取最后一个 .xxx 后缀
/// switch (n) { case "sh": return "sheet"; case "slide": return "presentation";
///              case "doc": return "doc"; default: return n; }
/// ```
/// 模板的 `object_id` 形如 `1_invoice.tpl.doc` / `….tpl.sh` / `….tpl.slide`
/// （真机 53 条：presentation 24 / doc 16 / sheet 13）。
/// 认不出来返回 `null` —— **不猜**（宁可让调用方按"全部类型"处理）。
OfficeNodeType? officeNodeTypeFromObjectId(String objectId) {
  final dot = objectId.lastIndexOf('.');
  if (dot < 0 || dot == objectId.length - 1) return null;
  return switch (objectId.substring(dot + 1).toLowerCase()) {
    'doc' => OfficeNodeType.doc,
    'sh' => OfficeNodeType.sheet,
    'slide' => OfficeNodeType.presentation,
    _ => null,
  };
}
