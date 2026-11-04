// Download Station 新建任务页（普通用户）：URL/磁力/迅雷 与 种子文件上传。
//
// 两条建任务路径（`docs/stage2-audio-download-api.md` §3.3 A-2b，逐字）：
//   * URL：`Task.create` v2，`type="url"`、`url=[...]`（数组）、`destination`、
//     `create_list=false`；FTP 认证的 `username`/`password` 需 `encodeURIComponent`。
//   * 文件：POST 到 **`webapi/entry.cgi/SYNO.DownloadStation2.Task`**，multipart
//     字段 `file`（值 `["torrent"]`）+ 文件块字段名 `torrent` + `type`/`destination`/
//     `create_list`/`extract_password`。
//
// §5 U2（`type` 值的两种官方形态）在接口层做成可切换（`DsCreateValueShape`），
// 页面用各自官方路径的默认形态；真机确认后只改接口层默认值即可。
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../design/kit/design_kit.dart';
import '../../core/i18n/data_text.dart';
import '../../core/i18n/l10n.dart';
import '../../core/theme/app_tokens.dart';
import '../../data/download_station.dart';
import '../analytics/analytics_track.dart';
import '../analytics/usage_event.dart';
import 'download_file_select_page.dart';
import 'download_providers.dart';
import '../../core/user_facing_error.dart';

class DownloadCreatePage extends ConsumerStatefulWidget {
  const DownloadCreatePage({super.key, this.initialUrl});

  /// 从别的入口带过来的链接（r388/DA35：BT 搜索结果在"取不到默认目录"时
  /// 带着 `download_uri` 来这里让用户确认目录）。**只预填一次**，用户改过不覆盖。
  final String? initialUrl;

  @override
  ConsumerState<DownloadCreatePage> createState() => _DownloadCreatePageState();
}

class _DownloadCreatePageState extends ConsumerState<DownloadCreatePage> {
  final _urls = TextEditingController();
  bool _urlSeeded = false;
  final _dest = TextEditingController();
  final _password = TextEditingController();
  final _username = TextEditingController();
  final _ftpPassword = TextEditingController();
  // C12：新建任务后的「立即开始/排队」与**单任务**限速（KB/s）。
  final _maxDown = TextEditingController();
  final _maxUp = TextEditingController();
  bool _startImmediately = true;
  bool _createList = false;
  // FTP/HTTP 需要认证（官方 TaskCreateActivity 的 `dlauth` 开关 +
  // `username`/`password`，见 C2）。原 DC-1：接口层有这两个形参、页面从不传。
  bool _ftpAuth = false;
  bool _submitting = false;
  bool _defaultFilled = false;
  String? _filePath;
  String? _fileName;
  String? _error;

  @override
  void dispose() {
    _urls.dispose();
    _dest.dispose();
    _password.dispose();
    _username.dispose();
    _ftpPassword.dispose();
    _maxDown.dispose();
    _maxUp.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    // 外部带进来的链接（BT 搜索结果）只填一次。
    final seed = widget.initialUrl?.trim() ?? '';
    if (!_urlSeeded && seed.isNotEmpty) {
      _urlSeeded = true;
      _urls.text = seed;
    }
    // 默认下载目录（`Settings.Location.get` v1）预填一次，用户改过就不覆盖。
    final defDest = ref.watch(downloadDefaultDestProvider).value ?? '';
    if (!_defaultFilled && defDest.isNotEmpty) {
      _defaultFilled = true;
      _dest.text = defDest;
    }
    return DesignScaffold(
      appBar: AppBar(title: Text(t.dsNewTask)),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(Gap.lg, Gap.md, Gap.lg, Gap.xxl),
        children: [
          TextField(
            key: const Key('ds-create-urls'),
            controller: _urls,
            keyboardType: TextInputType.multiline,
            minLines: 4,
            maxLines: 8,
            decoration: InputDecoration(
              labelText: t.dsCreateUrl,
              hintText: t.dsUrlHint,
              alignLabelWithHint: true,
              border: const OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: Gap.lg),
          // FTP/HTTP 认证（官方 `Task.create {uri, username, password}`，
          // 需要账号的 FTP 下载；原 DC-1 死参数接线）。
          DesignSwitchRow(
            key: const Key('ds-create-ftp-auth'),
            value: _ftpAuth,
            onChanged: (v) => setState(() => _ftpAuth = v),
            title: Text(dataText('dsFtpAuth', '需要 FTP/HTTP 账号密码')),
          ),
          if (_ftpAuth) ...[
            TextField(
              key: const Key('ds-create-username'),
              controller: _username,
              decoration: InputDecoration(
                labelText: dataText('dsFtpUsername', '用户名'),
                border: const OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: Gap.md),
            TextField(
              key: const Key('ds-create-ftp-password'),
              controller: _ftpPassword,
              obscureText: true,
              decoration: InputDecoration(
                labelText: dataText('dsFtpPassword', '密码'),
                border: const OutlineInputBorder(),
              ),
            ),
          ],
          const SizedBox(height: Gap.lg),
          Row(
            children: [
              Expanded(
                child: Text(
                  _fileName ?? t.dsPickTorrent,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.bodyMedium,
                ),
              ),
              const SizedBox(width: Gap.sm),
              // ⚠️ `Row` 给非 flex 子项的宽度约束是**无界**的，而全局主题的
              // `OutlinedButtonThemeData.minimumSize = Size.fromHeight(48)` 里
              // 宽度是 `infinity`：两者相遇会让按钮内部拿
              // `BoxConstraints(w=Infinity)` layout → 布局断言直接抛。
              // 用局部主题把最小宽度收成有限值（按钮回到内容宽度）。
              // 用局部主题把最小宽度收成有限值（按钮回到内容宽度），
              // 再套 `Flexible`：英文 + 2.0 缩放时按钮的内容宽度仍可能
              // 超过一行，`Flexible` + 省略号可让标签收缩而不是溢出。
              Flexible(
                child: OutlinedButtonTheme(
                  data: OutlinedButtonThemeData(
                    style: OutlinedButton.styleFrom(
                      minimumSize: const Size(0, 44),
                    ),
                  ),
                  child: OutlinedButton(
                    key: const Key('ds-create-pick'),
                    onPressed: _submitting ? null : _pickFile,
                    child: Text(
                      t.contactPickFile,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: Gap.lg),
          TextField(
            key: const Key('ds-create-dest'),
            controller: _dest,
            decoration: InputDecoration(
              labelText: t.dsChooseDestination,
              helperText: defDest.isEmpty
                  ? null
                  : t.dsDefaultDestination(defDest),
              border: const OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: Gap.md),
          TextField(
            key: const Key('ds-create-password'),
            controller: _password,
            decoration: InputDecoration(
              labelText: t.dsExtractPassword,
              helperText: t.dsExtractPasswordHint,
              border: const OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: Gap.sm),
          DesignSwitchRow(
            key: const Key('ds-create-list'),
            value: _createList,
            onChanged: (v) => setState(() => _createList = v),
            title: Text(t.dsCreateList),
            subtitle: Text(t.dsCreateListHint),
          ),
          // C12：立即开始 / 排队。
          //
          // 官方 `Task.create` 没有"立即开始"参数（`ui/download.js` 的
          // `getWebAPICreateParams` 逐字只有 url/destination/username/password/
          // create_list/extract_password）；关掉这个开关时，客户端在创建成功后
          // 用 `Task/pause` 把**刚建好的那个任务**暂停（普通用户可调）。
          DesignSwitchRow(
            key: const Key('ds-create-immediate'),
            value: _startImmediately,
            onChanged: (v) => setState(() => _startImmediately = v),
            title: Text(dataText('dsStartImmediately', '立即开始下载')),
            subtitle: Text(
              dataText('dsStartImmediatelyHint', '关闭则创建后加入队列（暂停）'),
            ),
          ),
          // C12：可选**单任务**限速（KB/s，0/留空 = 不限）。
          // 走 `Task.BT.get|set`（normal 可改；全局限速是 admin-only 不做）。
          Row(
            children: [
              Expanded(
                child: TextField(
                  key: const Key('ds-create-max-down'),
                  controller: _maxDown,
                  keyboardType: TextInputType.number,
                  decoration: InputDecoration(
                    labelText: dataText('dsMaxDownloadRate', '下载限速 (KB/s)'),
                    border: const OutlineInputBorder(),
                  ),
                ),
              ),
              const SizedBox(width: Gap.md),
              Expanded(
                child: TextField(
                  key: const Key('ds-create-max-up'),
                  controller: _maxUp,
                  keyboardType: TextInputType.number,
                  decoration: InputDecoration(
                    labelText: dataText('dsMaxUploadRate', '上传限速 (KB/s)'),
                    border: const OutlineInputBorder(),
                  ),
                ),
              ),
            ],
          ),
          if (_error != null) ...[
            const SizedBox(height: Gap.sm),
            Text(
              _error!,
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            ),
          ],
          const SizedBox(height: Gap.lg),
          FilledButton(
            key: const Key('ds-create-submit'),
            onPressed: _submitting ? null : _submit,
            child: _submitting
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : Text(t.photoCreate),
          ),
        ],
      ),
    );
  }

  Future<void> _pickFile() async {
    final t = context.t;
    try {
      // file_picker 13 起是静态 API（`FilePicker.platform` 没了）。
      final picked = await FilePicker.pickFile(
        type: FileType.custom,
        allowedExtensions: const ['torrent', 'nzb', 'txt'],
      );
      if (picked == null) return;
      // file_picker 13 的 PlatformFile 用 `length()`（异步）而不是 `size`。
      final size = await picked.length();
      if (size != null && size > DownloadStationApi.maxAddBytes) {
        setState(() => _error = t.dsFileTooLarge);
        return;
      }
      setState(() {
        _filePath = picked.path;
        _fileName = picked.name;
        _error = null;
      });
    } catch (e) {
      setState(() => _error = userFacingError(e));
    }
  }

  Future<void> _submit() async {
    final t = context.t;
    final messenger = ScaffoldMessenger.of(context);
    final navigator = Navigator.of(context);
    final dest = _dest.text.trim();
    final password = _password.text.trim();
    final username = _username.text.trim();
    final ftpPassword = _ftpPassword.text.trim();
    setState(() {
      _submitting = true;
      _error = null;
    });
    // Stable object type for analytics (never carries a name/url): local torrent
    // files are `bt`, other local files `file`; a magnet URL wins over `url`.
    var createObjectType = _filePath == null
        ? 'url'
        : ((_fileName ?? '').toLowerCase().endsWith('.torrent') ? 'bt' : 'file');
    try {
      final actions = ref.read(downloadActionsProvider);
      // C12：只有需要"排队/限速"时才多花一次只读快照（拿创建前的任务 id）。
      final rateDown = _parseRate(_maxDown);
      final rateUp = _parseRate(_maxUp);
      final wantsOptions =
          !_startImmediately || rateDown != null || rateUp != null;
      var beforeIds = const <String>{};
      if (wantsOptions) {
        try {
          beforeIds = await actions.taskIdSnapshot();
        } catch (_) {
          // 快照拿不到不致命：newestTaskId 仍会尝试按创建时间找最新的那个。
        }
      }
      final DsCreateResult result;
      if (_filePath != null) {
        createObjectType = (_fileName ?? '').toLowerCase().endsWith('.torrent')
            ? 'bt'
            : 'file';
        result = await actions.createFile(
          filePath: _filePath!,
          fileName: _fileName ?? 'upload.torrent',
          destination: dest.isEmpty ? null : dest,
          extractPassword: password.isEmpty ? null : password,
          createList: _createList,
        );
      } else {
        final urls = _urls.text
            .split(RegExp(r'[\r\n]+'))
            .map((l) => l.trim())
            .where((l) => l.isNotEmpty)
            .toList();
        createObjectType = urls.any(
          (u) => u.toLowerCase().startsWith('magnet:'),
        )
            ? 'magnet'
            : 'url';
        if (urls.isEmpty) {
          setState(() {
            _submitting = false;
            _error = t.dsUrlRequired;
          });
          return;
        }
        if (urls.length > DownloadStationApi.maxAddLimit) {
          setState(() {
            _submitting = false;
            _error = t.dsTooManyUrls;
          });
          return;
        }
        final invalid = urls.where(
          (u) => DownloadStationApi.canonizeUrl(u).isEmpty,
        );
        if (invalid.isNotEmpty) {
          setState(() {
            _submitting = false;
            _error = t.dsUrlRequired;
          });
          return;
        }
        result = await actions.createUrl(
          urls: urls,
          destination: dest.isEmpty ? null : dest,
          username: _ftpAuth && username.isNotEmpty ? username : null,
          password: _ftpAuth && ftpPassword.isNotEmpty ? ftpPassword : null,
          extractPassword: password.isEmpty ? null : password,
          createList: _createList,
        );
      }
      trackOnce(
        UsageModule.downloads,
        UsageAction.create,
        objectType: createObjectType,
      );
      // `create_list=true` 时服务端回 `list_id`，任务**还没开始** —— 必须让
      // 用户选文件（`Task.List.get` → `Task.List.Polling.download`）。
      // 原 DC-2：这里以前直接把 listId 丢掉，选文件流程断链。
      final listId = result.listId;
      // ★★ r387/DA37（真机读到）：勾了「先选文件」但**服务端没回清单**
      //   （`Task.create` 的 `list_id` 是**空数组** —— URL 建任务时服务端
      //   不会先生成清单）。以前这里会拿空数组字符串化后的 `"[]"` 推一个
      //   **必然失败**的选文件页（真机 `code=120 name:list_id`）。
      //   现在：不推假页面；而且提示条**只有一条**（下面收尾那条改文案）——
      //   两条 snackbar 会互相盖住，真机上只看得到最后那条（r387 实测）。
      final listUnavailable = _createList && listId == null;
      if (_createList && listId != null && mounted) {
        final started = await Navigator.of(context).push<bool>(
          MaterialPageRoute(
            builder: (_) => DownloadFileSelectPage(
              listId: listId,
              destination: dest.isEmpty ? null : dest,
              extractPassword: password.isEmpty ? null : password,
            ),
          ),
        );
        if (started != true) {
          // 用户放弃了选择：留在本页，允许改参数重来。
          if (mounted) setState(() => _submitting = false);
          return;
        }
      }
      // C12：任务已经创建成功，这里再补「排队 / 限速」。选项失败**不改判**
      // 创建结果（只给一条提示），否则用户会以为任务没建上而重复创建。
      if (wantsOptions) {
        try {
          final applied = await actions.applyCreateOptionsToNewest(
            knownIds: beforeIds,
            startImmediately: _startImmediately,
            maxDownloadRate: rateDown,
            maxUploadRate: rateUp,
          );
          if (!applied) {
            messenger.showSnackBar(
              SnackBar(
                content: Text(
                  dataText(
                    'dsCreateOptionsNotApplied',
                    '任务已创建，但「立即开始/限速」未能应用（列表尚未刷新）',
                  ),
                ),
              ),
            );
          }
        } catch (e) {
          messenger.showSnackBar(
            SnackBar(
              content: Text(
                dataText(
                  'dsCreateOptionsFailed',
                  '任务已创建，但选项未生效：{msg}',
                ).replaceAll('{msg}', describeDownloadError(e)),
              ),
            ),
          );
        }
      }
      messenger.showSnackBar(
        SnackBar(
          content: Text(
            listUnavailable
                ? dataText(
                    'dsCreateListUnavailable',
                    '任务已创建，但服务端没有返回文件清单，无法先选文件',
                  )
                : t.dsCreated,
          ),
        ),
      );
      navigator.pop(true);
    } catch (e) {
      trackOnceFailure(
        UsageModule.downloads,
        UsageAction.create,
        objectType: createObjectType,
        reason: 'create_failed',
        error: e,
      );
      setState(() {
        _submitting = false;
        _error = t.dsCreateFailed(describeDownloadError(e));
      });
    }
  }

  /// 限速输入 → 整数 KB/s；空/非正数 = 不限（null）。
  static int? _parseRate(TextEditingController c) {
    final v = int.tryParse(c.text.trim()) ?? 0;
    return v > 0 ? v : null;
  }
}
