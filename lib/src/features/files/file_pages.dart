// 文件模块的附属页面：搜索、收藏、分享链接（只读管理）、后台任务。
//
// 这些页面都从「文件」Tab 顶栏进入，按任务数量分级：
//   * 任务中心：`BackgroundTask.list` + `clear_finished`（服务端只有这两个方法）
//   * 分享链接：**本页只做管理**（列表/删除/清理失效/发送/编辑），
//     **创建入口在文件·文件夹的行菜单**「创建分享链接」（`file_browse_page.dart:1126`）；wave3 起同页多
//     一个「共享给我的」Tab（`Sharing/list_share_me` v2，能力位门控）
//   * 收藏 / 搜索：`Favorite.list` / `Search.start|list|stop|clean`
import '../../design/kit/design_kit.dart';
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../design/design_palette.dart';
import '../../core/i18n/l10n.dart';
import '../../core/theme/app_tokens.dart';
import '../../core/ui/app_states.dart';
import '../../core/ui/hud_widgets.dart';
import '../../data/dto/file_entry_dto.dart';
import '../analytics/analytics_track.dart';
import '../analytics/usage_event.dart';
import '../search/global_search_page.dart' show GlobalSearchEntry;
import '../../data/filestation_api.dart';
import '../../data/local/file_store.dart';
import '../../dsm/webapi.dart' show DsmApiException, DsmErrorCode;
import 'file_browse_page.dart';
import 'file_link_share.dart';
import '../drive/drive_open_entry.dart' show openFileUnified;
import 'file_providers.dart';
import 'file_row.dart';
import 'file_task_retry.dart';
import 'file_sheets.dart';
import 'filestation_c5_text.dart';
import 'filestation_gaps_wave1_text.dart';
import 'filestation_gaps_wave2_text.dart';
import 'filestation_gaps_wave3_text.dart';
import 'filestation_p0b_text.dart';
import 'filestation_tasks_text.dart';
import 'file_search_root.dart';

// ★ r395：`kFileSearchDefaultRoot` / `fileSearchRootFor` 已抽到
// `file_search_root.dart`（「全局搜索」页也要用同一份判据）。这里继续
// **导出**，老调用点与老用例（`test/r135_file_search_poll_test.dart` 等）不用改。
export 'file_search_root.dart';

/// 搜索页 —— `Search.start` 建任务，`Search.list` 取结果（服务端异步搜索）。
/// 没有浏览上下文时（工作台/全局入口）用的搜索根。
///
/// ★ r121 真机 + 宿主只读探针取证：`SYNO.FileStation.Search:start` 传
/// `folder_path='/'` 时，**任何关键字都回 0 命中**
/// （`Citizen` / `home` / `home*` / `mp4` 全 0），而 `/home` 与 `/home/Video`
/// 都能正常命中（且搜索本身是递归的：`/home` + `01_1` 命中的是
/// `/home/Video/...`）。所以 `'/'` 不是可用的搜索根。
///
/// ★ r395：本函数与 [kFileSearchDefaultRoot] 的**定义**已搬到
/// `file_search_root.dart`（`export` 在上面），这里只保留说明。

/// 搜索轮询节奏：上限 30 次 × 400ms ≈ 12 秒。
/// 真机 `/home/Video` 的 `Citizen` 搜索在 1.2s 时还没跑完、~19s 才稳（r135），
/// 所以上限要够大；`finished:true` 会提前收手，正常情况到不了上限。
/// ★ r316：30 次 × 400ms = **12s** 不够 —— 真机上同一关键字（`Download`，
/// `/home` 下确实存在）出现过「先命中、清空重搜后 >25s 仍是 0」的**假否定**；
/// 现在给到 **90 次 = 36s**（`finished:true` 仍会提前收手，正常到不了上限），
/// 并且"耗尽上限"**不再**被当成"服务端说没有"（见 [fileSearchResultsAreFinal]）。
const _kSearchPollMax = 90;
const _kSearchPollInterval = Duration(milliseconds: 400);

/// 一轮轮询之后：**还要不要继续等**？
///
/// 判据只看服务端的 [serverFinished]（三态），不看"已经等了几轮"：
///   * `true`  ⇒ 服务端说搜完了 ⇒ 停（此刻 0 命中才是**真的** 0 命中）；
///   * `false` ⇒ 服务端说还在跑 ⇒ 继续等（**不许**因为"暂时 0 命中"就收手，
///     那正是 r135 真机上「先报 No matching files、重搜才命中」的成因）；
///   * `null`  ⇒ 老服务端没回这个字段 ⇒ **逐字退回旧策略**
///     （有结果就走，否则给 [i] >= 3 轮宽限），对这类服务端行为不变。
bool fileSearchShouldKeepPolling({
  required bool? serverFinished,
  required bool hasEntries,
  required int attempt,
}) {
  if (serverFinished == true) return false;
  if (serverFinished == false) return true;
  return !(hasEntries || attempt >= 3);
}

/// 一轮轮询之后：**这一轮的结果算不算"最终结果"**？（r316）
///
/// 就是"要不要继续等"的反面，但语义上必须分开写：**只有服务端说搜完了，
/// 才允许把 0 命中当成"没有匹配的文件"**。
///
/// 真机反例（r316）：`Files → NAS files → 搜索` 搜 `Download`（`/home` 下真有这个目录）
/// 第一次命中，清空重搜却回 `No matching files`，再等 25s 依旧 —— 那一刻服务端
/// **从没说过** `finished:true`，是客户端自己把"没等到"渲染成了"没有"（假否定）。
/// 与 r135 的 `Citizen` 是同一族缺陷，r135 只改了"什么时候收手"，没改
/// "收手之后怎么说"。
bool fileSearchResultsAreFinal({
  required bool? serverFinished,
  required bool hasEntries,
  required int attempt,
}) => !fileSearchShouldKeepPolling(
  serverFinished: serverFinished,
  hasEntries: hasEntries,
  attempt: attempt,
);

class FileSearchPage extends ConsumerStatefulWidget {
  const FileSearchPage({
    super.key,
    this.initialQuery = '',
    this.folderPath = '',
  });

  /// 带着关键词进来（工作台的吸顶搜索条回车就走到这里）
  final String initialQuery;

  /// 从「文件」浏览页进来时传**当前目录**；空 = 没有浏览上下文，
  /// 这时用 [kFileSearchDefaultRoot]（**绝不**回落到 `'/'`）。
  final String folderPath;

  @override
  ConsumerState<FileSearchPage> createState() => _FileSearchPageState();
}

class _FileSearchPageState extends ConsumerState<FileSearchPage> {
  final _controller = TextEditingController();

  @override
  void initState() {
    super.initState();
    // 工作台吸顶搜索条回车带过来的关键词：进来就直接搜
    final q = widget.initialQuery.trim();
    if (q.isNotEmpty) {
      _controller.text = q;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) unawaited(_search());
      });
    }
  }

  /// 存一份 api 引用给 `dispose()` 用 —— Riverpod 3 里
  /// "在 dispose 期间 ref.read" 会抛 `Bad state: Using "ref" when a widget is
  /// about to or has been unmounted is unsafe`（真机上离开搜索页就崩）。
  FileStationApi? _api;
  String _taskId = '';
  List<FileEntryDto> _results = const [];
  bool _busy = false;
  String? _error;
  bool _finished = false;

  /// 是否**已经发起过**一次搜索。
  ///
  /// ★ r316：必须把"还没搜过"与"搜过但服务端还没说完成"分开 ——
  /// 两者都是 `_results.isEmpty && !_finished`，但前者该说
  /// `输入关键词开始搜索`，后者该说"仍在进行"（否则初次进入搜索页会
  /// 被错写成"搜索仍在进行"）。这个坑是先改代码、被既有的
  /// `file_pages_ui_test`（`输入关键词开始搜索`）当场抓住的。
  bool _started = false;

  /// 高级搜索筛选（P0-5）。空 = 只按文件名搜（旧行为）。
  FileSearchFilter _filter = const FileSearchFilter();

  @override
  void dispose() {
    // 离开时停掉服务端搜索任务（免得它一直跑）
    final api = _api;
    if (_taskId.isNotEmpty && api != null) {
      api.stopSearch(_taskId).catchError((Object _) {});
      api.cleanSearch(_taskId).catchError((Object _) {});
    }
    _controller.dispose();
    super.dispose();
  }

  Future<void> _openFilter() async {
    final next = await showFileSearchFilterSheet(context, initial: _filter);
    if (next == null || !mounted) return;
    setState(() => _filter = next);
    if (_controller.text.trim().isNotEmpty || next.isNotEmpty) {
      await _search();
    }
  }

  Future<void> _search() async {
    final keyword = _controller.text.trim();
    if (keyword.isEmpty && _filter.isEmpty) return;
    final t = context.t;
    final api = ref.read(fileApiProvider);
    _api = api;
    if (api == null) {
      setState(() => _error = t.setNotConnected);
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
      _results = const [];
      _finished = false;
      _started = true;
    });
    try {
      final start = await api.startSearch(
        // r121 修：原来**写死 `'/'`** ⇒ 真机搜索恒 0 命中。
        // r135 修：`kFileRoot` 就是 `'/'`，所以"当前目录"= 根目录时也会传 `'/'`
        // ⇒ 仍要规整（真机对 `/` 回 600）。见 [fileSearchRootFor]。
        folderPath: fileSearchRootFor(widget.folderPath),
        pattern: keyword,
        filetype: _filter.filetype,
        extension: _filter.extension,
        sizeFrom: _filter.sizeFromBytes,
        sizeTo: _filter.sizeToBytes,
        mtimeFrom: _filter.mtimeFromSeconds,
        mtimeTo: _filter.mtimeToSeconds,
        owner: _filter.owner,
      );
      _taskId = start.taskId;
      // 服务端是**异步**搜索：`list` 会先回 `finished:false` + 已命中的部分结果，
      // 跑完才回 `finished:true`。
      //
      // ★ r135 修（D3 根因之二）：原来 `if (result.entries.isNotEmpty || i >= 3) break;`
      // 是**按"轮询次数"猜**服务端跑没跑完 —— `i >= 3` ≈ 1.2 秒就收手，于是
      // 大目录（`/home/Video`）里先得到"0 命中"的**假否定**，过十几秒重搜才命中
      // （r135 真机：`Citizen` 首次 `No matching files`，重搜才出
      // `Citizen Kane (1941).mkv`）。现在改成**看服务端自己的 `finished` 位**：
      //   * `finished == false` ⇒ 服务端说还没完 ⇒ 继续轮询（上限 [_kSearchPollMax] 次）；
      //   * `finished == true`  ⇒ 服务端说完了 ⇒ 立刻收手（0 命中就是真的 0 命中）；
      //   * `finished == null`  ⇒ 老服务端没回这个位 ⇒ 退回**旧策略**
      //     （有结果就走，否则给几轮宽限），行为对这类服务端逐字不变。
      for (var i = 0; i < _kSearchPollMax; i++) {
        // ★ r395：取结果改用**容忍瞬时 600** 的包装（600 = 服务端"结果缓存还没
        //   准备好"，官方 FileStation 文案就是「暂时无法访问搜索结果。请再试一次。」，
        //   见 `DsmErrorCode.searchCacheUnavailable`）。旧代码把这条**瞬时**状态
        //   直接抛给 catch ⇒ 整页 `Search failed`；其它码仍原样抛出。
        final result = await api.searchResultsRetrying(
          taskId: _taskId,
          limit: 500,
        );
        if (!mounted) return;
        // ★ r316 诊断探针（只进 logcat，不是用户文案）：判断"0 命中"是**服务端的
        // 结论**（`finished:true`）还是**我们没等到**（`finished:false`/`null`）。
        debugPrint(
          '[fileSearch] attempt=$i finished=${result.finished} '
          'entries=${result.entries.length} total=${result.total}',
        );
        final keep = fileSearchShouldKeepPolling(
          serverFinished: result.finished,
          hasEntries: result.entries.isNotEmpty,
          attempt: i,
        );
        setState(() {
          _results = result.entries;
          // ★ r316 修：`_finished` = **这一轮的结果算不算最终结果**，不再是"轮询结束"。
          // 原来这里恒 `true` ⇒ 服务端还在跑而客户端耗尽上限时，界面给出
          // `No matching files`（真机实测的假否定）。
          _finished = fileSearchResultsAreFinal(
            serverFinished: result.finished,
            hasEntries: result.entries.isNotEmpty,
            attempt: i,
          );
        });
        if (!keep) break;
        await Future<void>.delayed(_kSearchPollInterval);
      }
      // 使用日志：搜索**结果条数**（0 = 搜不到）——这是"搜索命中率"结论的原料
      track(
        ref,
        UsageModule.search,
        UsageAction.search,
        value: _results.length,
        detail: {'scope': 'files', 'tried': 1},
      );
      if (mounted) setState(() => _busy = false);
    } catch (e) {
      if (mounted) {
        setState(() {
          _busy = false;
          _error = describeFileError(e);
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final hud = DesignPalette.of(context);
    final t = context.t;
    return Scaffold(
      backgroundColor: hud.bg,
      appBar: AppBar(
        title: Text(t.fileSearchTitle),
        actions: [
          IconButton(
            tooltip: _filter.isEmpty
                ? fsP0b(FsP0bTextKeys.searchFilter, '筛选')
                : fsP0b(FsP0bTextKeys.searchFilterActive, '已启用筛选'),
            onPressed: _openFilter,
            icon: Badge(
              isLabelVisible: _filter.isNotEmpty,
              child: const Icon(Icons.tune),
            ),
          ),
        ],
      ),
      body: Column(
          children: [
            Padding(
              padding: const EdgeInsets.all(Gap.md),
              child: TextField(
                controller: _controller,
                textInputAction: TextInputAction.search,
                onSubmitted: (_) => _search(),
                decoration: InputDecoration(
                  hintText: t.fileSearchHint,
                  prefixIcon: const Icon(Icons.search),
                  suffixIcon: IconButton(
                    icon: const Icon(Icons.arrow_forward),
                    onPressed: _search,
                  ),
                ),
              ),
            ),
            // 全局搜索入口（`SYNO.Finder.*` 存在性门控）：
            // 吸顶搜索框回车先落到**本模块**的文件搜索，这里再给"在 NAS
            // 全局搜索"的出口（设计 §4.3(a)：不新增磁贴）。
            GlobalSearchEntry(initialQuery: _controller.text),
            Expanded(child: _body(t)),
          ],
        ),
    );
  }

  Widget _body(AppText t) {
    if (_busy) return const AppListSkeleton();
    if (_error != null) {
      return AppErrorView(
        title: t.fileSearchFailed,
        detail: _error,
        onRetry: _search,
      );
    }
    if (_results.isEmpty) {
      // ★ r316：`_finished == false` = **服务端还没说搜完**（客户端到了轮询上限）
      // ⇒ 既不能说"没有匹配"（那是假否定），也不能一直转圈（用户没有出口）
      // ⇒ 给"仍在进行 + 重试"的诚实态。
      if (!_started) {
        // 还没搜过：给"输入关键词"的提示（与"仍在进行"是两件事）
        return AppEmptyState(
          icon: Icons.search,
          title: t.fileSearchPrompt,
        );
      }
      if (!_finished) {
        return AppEmptyState(
          icon: Icons.hourglass_empty,
          title: t.fileSearchStillRunning,
          message: t.fileSearchStillRunningMessage,
          actionLabel: t.photoRetry,
          onAction: _search,
        );
      }
      // ★ r316 真机：服务端会对**确实存在**的目录回 `finished:true` + 0 条
      // （探针逐字：`attempt=0 finished=true entries=0 total=0`，而 `/home` 下
      // 明明有 `Download`）。这不是我们这一侧的谎，但用户会卡在"没有匹配"上
      // ⇒ 把页面里**已有的**全局搜索出口写进空态，给一条出路。
      return AppEmptyState(
        icon: Icons.search,
        title: t.fileNoMatches,
        message: '${t.fileSearchScope}\n${t.fileNoMatchesHint}',
      );
    }
    return ListView.builder(
      itemCount: _results.length,
      itemBuilder: (context, i) => FileRow(
        entry: _results[i],
        onTap: () => _openEntry(_results[i]),
        onMenu: () => _openEntry(_results[i]),
      ),
    );
  }

  /// 搜索结果没有"浏览上下文"，所以只给只读动作面板：打开所在目录 / 属性 / 收藏。
  Future<void> _openEntry(FileEntryDto entry) async {
    // 文件直接进预览（和浏览页一致）；文件夹仍走操作面板的"打开"
    if (!entry.isDir) {
      // ★ 用户 2026-09-25 裁决：Office 原生三种格式走「我的 Drive」同一个阅读器
      openFileUnified(context, ref, entry);
      return;
    }
    final t = context.t;
    final favorites = ref.read(fileFavoritesProvider).value ?? const <String>[];
    final action = await showFileItemSheet(
      context,
      entry: entry,
      isFavorite: favorites.contains(entry.path),
      readOnly: true,
    );
    if (!mounted || action == null) return;
    switch (action) {
      case 'open':
        await Navigator.of(context).push<void>(
          MaterialPageRoute(
            builder: (_) => FileBrowsePage(
              initialPath: entry.isDir ? entry.path : _parentOf(entry.path),
            ),
          ),
        );
      case 'properties':
        await showFilePropertiesSheet(context, entry);
      case 'favorite':
        try {
          final favorite = !favorites.contains(entry.path);
          await ref
              .read(fileActionsProvider)
              .setFavorite(entry.path, favorite: favorite);
          ref.invalidate(fileFavoritesProvider);
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(
                content: Text(favorite ? t.photoFavorited : t.photoUnfavorited),
              ),
            );
          }
        } catch (e) {
          if (mounted) {
            ScaffoldMessenger.of(
              context,
            ).showSnackBar(SnackBar(content: Text(describeFileError(e))));
          }
        }
    }
  }
}

// ------------------------------------------------------- 高级搜索筛选（P0-5）
//
// 官方证据（DS file 4.17.2-609）：
//   * `fragments/SearchOptionsFragment.java` 的表单字段：位置 / 类型（`search_type`）
//     / 日期类型（`search_date_type` + `search_date_key`）/ 起止日期 / 大小（MB）
//     / 所有者或组（`search_owner_group` + `search_owner_group_key`）/ 自定义扩展名；
//   * `WebApiConnectionManager.startSearch(...)`：`filetype`（dir/file）或
//     `extension`（逗号表）、`size_from`/`size_to`（**MB×1048576 的字节**）、
//     `<dateKey>_from/_to`（**秒级时间戳**，起始取当天 0 点、结束取当天 23:59:59）、
//     `owner` / `group`；
//   * `R.array.search_type_key`（aapt2 dump 原文，8 项）：
//     ["", "dir", "file", <document extensions>, <video extensions>,
//      <picture extensions>, <audio extensions>, ""]
//     —— 索引 0/1/2 发 `filetype`，索引 3..6 发 `extension`，索引 7 是自定义扩展名；
//   * `R.array.search_date_key` = ["mtime", "crtime", "atime"]（本批 UI 只做
//     任务书要求的"修改时间"= `mtime`）。
//
// 未取证的字段一个不发：服务端 `Search.start` 还可能有别的参数，但只有上面这些
// 能在官方 APK 与 `SYNO.FileStation.Search.so` 参数字符串里两处对上。

/// 官方 `R.array.search_type_key` 里三条扩展名清单（逐字抄 APK 资源）。
const String kFileSearchDocumentsExtensions =
    'docx,wri,rtf,xla,xlb,xlc,xld,xlk,xll,xlm,xlt,xlv,xlw,xlsx,xlsm,xlsb,xltm,'
    'xlam,pptx,pps,ppsx,pdf,txt,doc,xls,ppt,odt,ods,odp,odg,odc,odf,odb,odi,odm,'
    'ott,ots,otp,otg,otc,otf,oti,oth,potx,pptm,ppsm,potm,dotx,dot,pot,ppa,xltx,'
    'docm,dotm,eml,msgc,c,cc,cpp,cs,cxx,ada,coffee,cs,css,js,json,lisp,markdown,'
    'ocaml,pl,py,rb,sass,scala,r,tex,conf,csv,sub,srt,md,log';

const String kFileSearchVideosExtensions =
    '3gp,3g2,asf,dat,divx,dvr-ms,m2t,m2ts,m4v,mkv,mp4,mts,mov,qt,tp,trp,ts,vob,'
    'wmv,xvid,ac3,amr,rm,rmvb,ifo,mpeg,mpg,mpe,m1v,m2v,mpeg1,mpeg2,mpeg4,ogv,'
    'webm,flv,avi,swf,f4v';

const String kFileSearchPicturesExtensions =
    'ico,tif,tiff,ufo,raw,arw,srf,sr2,dcr,k25,kdc,cr2,crw,nef,mrw,ptx,pef,raf,'
    '3fr,erf,mef,mos,orf,rw2,dng,x3f,jpg,jpg,jpeg,png,gif,bmp,psd';

const String kFileSearchAudioExtensions =
    'aac,flac,m4a,m4b,aif,ogg,pcm,wav,cda,mid,mp2,mka,mpc,ape,ra,ac3,dts,wma,'
    'mp3,mp1,mp2,mpa,ram,m4p,aiff,dsf,dff,m3u,wpl';

/// 官方 `search_type` 的 8 个选项（顺序与 APK 资源一致）。
enum FileSearchType {
  any,
  folder,
  file,
  documents,
  videos,
  pictures,
  audio,
  customExtension;

  /// 官方把索引 0/1/2 映射成 `filetype`（`, "dir", "file"`）。
  String? get filetype => switch (this) {
    FileSearchType.any => null,
    FileSearchType.folder => 'dir',
    FileSearchType.file => 'file',
    _ => null,
  };

  /// 索引 3..6 映射成官方固定的扩展名清单；[FileSearchType.customExtension]
  /// 由用户输入。
  String? get extension => switch (this) {
    FileSearchType.documents => kFileSearchDocumentsExtensions,
    FileSearchType.videos => kFileSearchVideosExtensions,
    FileSearchType.pictures => kFileSearchPicturesExtensions,
    FileSearchType.audio => kFileSearchAudioExtensions,
    _ => null,
  };

  bool get isFiletypeGroup =>
      this == FileSearchType.folder || this == FileSearchType.file;
}

/// 高级搜索筛选条件（空 = 不启用筛选）。
class FileSearchFilter {
  const FileSearchFilter({
    this.type = FileSearchType.any,
    this.customExtension,
    this.sizeFromMb,
    this.sizeToMb,
    this.mtimeFrom,
    this.mtimeTo,
    this.owner,
  });

  final FileSearchType type;
  final String? customExtension;
  final int? sizeFromMb;
  final int? sizeToMb;
  final DateTime? mtimeFrom;
  final DateTime? mtimeTo;
  final String? owner;

  /// `filetype`（`dir`/`file`）—— 官方索引 0/1/2 的分支
  String? get filetype => type.filetype;

  /// `extension`（逗号表）—— 官方索引 3..6 的分支 + 自定义
  String? get extension {
    if (type == FileSearchType.customExtension) {
      final v = customExtension?.trim() ?? '';
      return v.isEmpty ? null : v;
    }
    return type.extension;
  }

  /// 官方 `size_from`/`size_to`：**MB × 1048576**（`SearchOptionsFragment`
  /// 的 `Integer.valueOf(str).intValue() * 1048576`）。
  int get sizeFromBytes => (sizeFromMb ?? 0) * 1048576;
  int get sizeToBytes => (sizeToMb ?? 0) * 1048576;

  /// 官方 `getTimestampString`：起始取当天 0 点、结束取当天 23:59:59（秒）。
  int? get mtimeFromSeconds => _startOfDaySeconds(mtimeFrom);
  int? get mtimeToSeconds => _endOfDaySeconds(mtimeTo);

  bool get isEmpty =>
      filetype == null &&
      extension == null &&
      sizeFromBytes <= 0 &&
      sizeToBytes <= 0 &&
      mtimeFromSeconds == null &&
      mtimeToSeconds == null &&
      (owner == null || owner!.trim().isEmpty);

  bool get isNotEmpty => !isEmpty;
}

int? _startOfDaySeconds(DateTime? d) {
  if (d == null) return null;
  final local = DateTime(d.year, d.month, d.day);
  return local.millisecondsSinceEpoch ~/ 1000;
}

/// 结束日期取**当天最后一秒**（官方 `calendar.add(5, 1); calendar.add(13, -1);`）
int? _endOfDaySeconds(DateTime? d) {
  if (d == null) return null;
  final local = DateTime(d.year, d.month, d.day + 1);
  return local.millisecondsSinceEpoch ~/ 1000 - 1;
}

/// 高级搜索筛选面板。返回 `null` = 取消；返回空 filter = 清除筛选。
Future<FileSearchFilter?> showFileSearchFilterSheet(
  BuildContext context, {
  FileSearchFilter initial = const FileSearchFilter(),
}) {
  return showDialog<FileSearchFilter>(
    context: context,
    builder: (context) => _FileSearchFilterDialog(initial: initial),
  );
}

class _FileSearchFilterDialog extends StatefulWidget {
  const _FileSearchFilterDialog({required this.initial});

  final FileSearchFilter initial;

  @override
  State<_FileSearchFilterDialog> createState() =>
      _FileSearchFilterDialogState();
}

class _FileSearchFilterDialogState extends State<_FileSearchFilterDialog> {
  late FileSearchType _type = widget.initial.type;
  late final TextEditingController _extension = TextEditingController(
    text: widget.initial.customExtension ?? '',
  );
  late final TextEditingController _sizeFrom = TextEditingController(
    text: widget.initial.sizeFromMb?.toString() ?? '',
  );
  late final TextEditingController _sizeTo = TextEditingController(
    text: widget.initial.sizeToMb?.toString() ?? '',
  );
  late final TextEditingController _owner = TextEditingController(
    text: widget.initial.owner ?? '',
  );
  late DateTime? _from = widget.initial.mtimeFrom;
  late DateTime? _to = widget.initial.mtimeTo;
  String? _error;

  @override
  void dispose() {
    _extension.dispose();
    _sizeFrom.dispose();
    _sizeTo.dispose();
    _owner.dispose();
    super.dispose();
  }

  Future<void> _pickDate({required bool from}) async {
    final now = DateTime.now();
    final initial = (from ? _from : _to) ?? now;
    final picked = await showDatePicker(
      context: context,
      initialDate: initial,
      firstDate: DateTime(now.year - 20),
      lastDate: DateTime(now.year + 1),
    );
    if (picked == null) return;
    setState(() {
      if (from) {
        _from = picked;
      } else {
        _to = picked;
      }
    });
  }

  void _apply() {
    final from = int.tryParse(_sizeFrom.text.trim());
    final to = int.tryParse(_sizeTo.text.trim());
    if (from != null && to != null && from > to) {
      setState(
        () => _error = fsP0b(
          FsP0bTextKeys.searchSizeInvalid,
          '最小大小不能大于最大大小',
        ),
      );
      return;
    }
    if (_from != null && _to != null && _from!.isAfter(_to!)) {
      setState(
        () => _error = fsP0b(
          FsP0bTextKeys.searchDateInvalid,
          '起始日期不能晚于结束日期',
        ),
      );
      return;
    }
    if (_type == FileSearchType.customExtension &&
        _extension.text.trim().isEmpty) {
      setState(
        () => _error = fsP0b(
          FsP0bTextKeys.searchExtensionHint,
          '扩展名（逗号分隔）',
        ),
      );
      return;
    }
    Navigator.of(context).pop(
      FileSearchFilter(
        type: _type,
        customExtension: _extension.text.trim(),
        sizeFromMb: from,
        sizeToMb: to,
        mtimeFrom: _from,
        mtimeTo: _to,
        owner: _owner.text.trim().isEmpty ? null : _owner.text.trim(),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    return AlertDialog(
      title: Text(fsP0b(FsP0bTextKeys.searchFilter, '筛选')),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(fsP0b(FsP0bTextKeys.searchType, '类型')),
            const SizedBox(height: Gap.sm),
            Wrap(
              spacing: Gap.sm,
              children: [
                for (final type in FileSearchType.values)
                  ChoiceChip(
                    label: Text(_typeLabel(type)),
                    selected: _type == type,
                    onSelected: (_) => setState(() {
                      _type = type;
                      _error = null;
                    }),
                  ),
              ],
            ),
            if (_type == FileSearchType.customExtension) ...[
              TextField(
                controller: _extension,
                decoration: InputDecoration(
                  labelText: fsP0b(
                    FsP0bTextKeys.searchExtensionHint,
                    '扩展名（逗号分隔）',
                  ),
                  hintText: 'pdf,docx',
                ),
              ),
            ],
            const SizedBox(height: Gap.md),
            Text(fsP0b(FsP0bTextKeys.searchSize, '大小（MB）')),
            Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _sizeFrom,
                    keyboardType: TextInputType.number,
                    decoration: InputDecoration(
                      labelText: fsP0b(FsP0bTextKeys.searchSizeFrom, '最小'),
                    ),
                  ),
                ),
                const SizedBox(width: Gap.sm),
                Expanded(
                  child: TextField(
                    controller: _sizeTo,
                    keyboardType: TextInputType.number,
                    decoration: InputDecoration(
                      labelText: fsP0b(FsP0bTextKeys.searchSizeTo, '最大'),
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: Gap.md),
            Text(fsP0b(FsP0bTextKeys.searchDate, '修改时间')),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton(
                    onPressed: () => _pickDate(from: true),
                    child: Text(
                      _from == null
                          ? fsP0b(FsP0bTextKeys.searchDateFrom, '起始')
                          : '${_from!.year}-${_from!.month}-${_from!.day}',
                    ),
                  ),
                ),
                const SizedBox(width: Gap.sm),
                Expanded(
                  child: OutlinedButton(
                    onPressed: () => _pickDate(from: false),
                    child: Text(
                      _to == null
                          ? fsP0b(FsP0bTextKeys.searchDateTo, '结束')
                          : '${_to!.year}-${_to!.month}-${_to!.day}',
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: Gap.md),
            TextField(
              controller: _owner,
              decoration: InputDecoration(
                labelText: fsP0b(FsP0bTextKeys.searchOwner, '所有者'),
                helperText: fsP0b(
                  FsP0bTextKeys.searchOwnerHint,
                  '账号名，留空表示不限',
                ),
              ),
            ),
            if (_error != null) ...[
              const SizedBox(height: Gap.sm),
              Text(
                _error!,
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            ],
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(const FileSearchFilter()),
          child: Text(fsP0b(FsP0bTextKeys.searchClear, '清除筛选')),
        ),
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(t.actionCancel),
        ),
        FilledButton(
          onPressed: _apply,
          child: Text(fsP0b(FsP0bTextKeys.searchApply, '应用')),
        ),
      ],
    );
  }

  String _typeLabel(FileSearchType type) => switch (type) {
    FileSearchType.any => fsP0b(FsP0bTextKeys.searchTypeAny, '任意'),
    FileSearchType.folder => fsP0b(FsP0bTextKeys.searchTypeFolder, '文件夹'),
    FileSearchType.file => fsP0b(FsP0bTextKeys.searchTypeFile, '任意文件'),
    FileSearchType.documents => fsP0b(
      FsP0bTextKeys.searchTypeDocuments,
      '文档',
    ),
    FileSearchType.videos => fsP0b(FsP0bTextKeys.searchTypeVideos, '视频'),
    FileSearchType.pictures => fsP0b(FsP0bTextKeys.searchTypePictures, '图片'),
    FileSearchType.audio => fsP0b(FsP0bTextKeys.searchTypeAudio, '音频'),
    FileSearchType.customExtension => fsP0b(
      FsP0bTextKeys.searchTypeExtension,
      '自定义扩展名',
    ),
  };
}

/// `/home/a/b.txt` → `/home/a`；已经在共享根就返回它自己
String _parentOf(String path) {  final idx = path.lastIndexOf('/');
  if (idx <= 0) return path;
  return path.substring(0, idx);
}

/// 收藏页 —— `Favorite.list`
///
/// 早先是 `ConsumerWidget` + 在 `build` 里 `FutureBuilder(future: api.listFavorites())`：
/// 每次重建都会**重新发一次请求**，而且取消收藏后没法刷新。
/// 改成有状态 + 显式刷新。
class FileFavoritesPage extends ConsumerStatefulWidget {
  const FileFavoritesPage({super.key});

  @override
  ConsumerState<FileFavoritesPage> createState() => _FileFavoritesPageState();
}

class _FileFavoritesPageState extends ConsumerState<FileFavoritesPage> {
  late Future<List<FileEntryDto>> _future = _load();

  /// 最近一次加载到的收藏行（重排对话框要用当前顺序）。
  List<FileEntryDto> _rows = const [];

  Future<List<FileEntryDto>> _load() async {
    final api = ref.read(fileApiProvider);
    if (api == null) {
      _rows = const [];
      return const [];
    }
    final rows = (await api.listFavorites(limit: 1000)).entries;
    _rows = rows;
    return rows;
  }

  // 注意：必须用块体。`setState(() => _future = _load())` 的箭头表达式会把
  // `Future` 当返回值交回 setState，debug 下直接抛
  // "setState() callback argument returned a Future"（M50 保存成功后被 catch
  // 吞成"保存失败"，才发现这个潜伏 bug）。
  void _reload() {
    setState(() {
      _future = _load();
    });
  }

  /// M51：打开固定的「个人文件夹」入口（`/home`）。
  ///
  /// 路径优先用 `List/list_share` 里解析出来的 home 条目（复用根目录缓存，
  /// 见 `fileHomeEntryProvider`），没解析出来就用固定的 `/home`。
  void _openHome(FileEntryDto home) {
    Navigator.of(context).push<void>(
      MaterialPageRoute(
        builder: (_) => FileBrowsePage(initialPath: home.path),
      ),
    );
  }

  /// M50：重排收藏。本地排序 → `Favorite/replace_all` v2。
  ///
  /// 参数形态已真机取证：`path` / `name` 两个平行 JSON 数组串，顺序 = 期望顺序。
  /// 失败（含**真机的 400**）一律视为保存失败：**不刷新列表**，界面上原来的顺序
  /// 原样保留，只弹错误提示。注意 400 在 FileStation 里**不是**参数名错，
  /// 所以这里不用 `describeFileError`(400 会被 DsmErrorCode 认成"密码错误")，
  /// 而是给收藏专用的明确文案。
  Future<void> _reorder() async {
    if (_rows.isEmpty) return;
    final ordered = await showFavoriteReorderSheet(context, entries: _rows);
    if (ordered == null || !mounted) return;
    try {
      await ref.read(fileActionsProvider).replaceAllFavorites(ordered);
      if (!mounted) return;
      AppSnack.show(
        context,
        fsGap2(FsGap2TextKeys.favoriteReordered, '收藏顺序已保存'),
      );
      _reload();
    } catch (e) {
      if (!mounted) return;
      // 保留服务端给的顺序 = 什么都不做（`_rows` 从未被就地改动）
      AppSnack.show(context, _favoriteSaveError(e), error: true);
    }
  }

  /// 收藏保存失败的文案：400 / 120 是真机实测的"这组参数被拒"，不能套用
  /// `DsmErrorCode` 的 400（那是聊天模块的"密码错误"）。
  String _favoriteSaveError(Object e) {
    final rejected =
        e is DsmApiException &&
        (e.code == 400 || e.code == DsmErrorCode.requestParameterInvalid);
    final head = fsGap2(FsGap2TextKeys.favoriteReorderFailed, '收藏顺序保存失败');
    if (rejected) {
      return fsGap2Fill(
        FsGap2TextKeys.favoriteReorderRejectedDetail,
        '{head}（{detail}）',
        <String, String>{
          'head': head,
          'detail': fsGap2(
            FsGap2TextKeys.favoriteReorderRejected,
            '服务端拒绝了这组参数',
          ),
        },
      );
    }
    return '$head${fsGap2(FsGap2TextKeys.errorDetailSeparator, '：')}'
        '${describeFileError(e)}';
  }

  /// 取消收藏（行尾星标与操作菜单共用）。成功后就地刷新列表 + 提示。
  Future<void> _unfavorite(FileEntryDto entry) async {
    final t = context.t;
    try {
      await ref
          .read(fileActionsProvider)
          .setFavorite(entry.path, favorite: false);
      ref.invalidate(fileFavoritesProvider);
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(t.photoUnfavorited)));
      _reload();
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(describeFileError(e))));
    }
  }

  /// P1-7：收藏行的面板（打开 / 重命名收藏 / 移除 / 属性）。
  ///
  /// 收藏是 DSM 的一条记录，不是普通路径 —— 所以走
  /// [showFavoriteItemSheet] 而不是文件面板（后者会给压缩/分享这些
  /// 会失败的入口）。
  Future<void> _openFavorite(FileEntryDto entry) async {
    final t = context.t;
    final action = await showFavoriteItemSheet(context, entry: entry);
    if (!mounted || action == null) return;
    switch (action) {
      case 'open':
        await Navigator.of(context).push<void>(
          MaterialPageRoute(
            builder: (_) => FileBrowsePage(
              initialPath: entry.isDir ? entry.path : _parentOf(entry.path),
            ),
          ),
        );
      case 'rename':
        final name = await promptFileName(
          context,
          title: fsC5(FsC5TextKeys.favoriteRename, '重命名收藏'),
          actionLabel: t.photoRename,
          initial: entry.name,
        );
        if (name == null || name.trim().isEmpty || !mounted) return;
        try {
          await ref
              .read(fileActionsProvider)
              .renameFavorite(entry.path, name.trim());
          if (!mounted) return;
          AppSnack.show(context, fsC5(FsC5TextKeys.favoriteRenamed, '收藏已重命名'));
          _reload();
        } catch (e) {
          if (!mounted) return;
          AppSnack.show(context, describeFileError(e), error: true);
        }
      case 'unfavorite':
        await _unfavorite(entry);
      case 'properties':
        await showFilePropertiesSheet(context, entry);
    }
  }

  /// P1-7：清掉已失效的收藏（`Favorite/clear_broken`，无参数）。
  Future<void> _clearBroken() async {
    final ok = await confirmDanger(
      context,
      title: fsC5(FsC5TextKeys.favoriteClearBroken, '清理失效收藏'),
      message: fsC5(
        FsC5TextKeys.favoriteClearBrokenConfirm,
        '将删除所有指向已不存在路径的收藏记录。',
      ),
      actionLabel: fsC5(FsC5TextKeys.favoriteClearBroken, '清理失效收藏'),
    );
    if (!ok || !mounted) return;
    try {
      await ref.read(fileActionsProvider).clearBrokenFavorites();
      if (!mounted) return;
      AppSnack.show(context, fsC5(FsC5TextKeys.favoriteCleared, '已清理失效收藏'));
      _reload();
    } catch (e) {
      if (!mounted) return;
      AppSnack.show(context, describeFileError(e), error: true);
    }
  }

  @override
  Widget build(BuildContext context) {
    final hud = DesignPalette.of(context);
    final t = context.t;
    final api = ref.watch(fileApiProvider);
    // M51：`/home` 固定入口 —— 优先复用 `List/list_share` 已解析的 home 条目
    // （`fileHomeEntryProvider` 读的是根目录缓存），没解析出来就固定 `/home`。
    final home = ref.watch(fileHomeEntryProvider);
    final homeEntry =
        home ??
        const FileEntryDto(name: 'home', path: '/home', isDir: true);
    return Scaffold(
      backgroundColor: hud.bg,
      appBar: AppBar(
        title: Text(t.photoSectionFavorites),
        actions: [
          // M50：批量重排（本地排序 → `Favorite/replace_all`）
          IconButton(
            key: const Key('file-favorites-reorder'),
            tooltip: fsGap2(FsGap2TextKeys.favoriteReorder, '重排收藏'),
            icon: const Icon(Icons.reorder),
            onPressed: _reorder,
          ),
          // P1-7：清理失效收藏（`Favorite/clear_broken`）
          IconButton(
            tooltip: fsC5(FsC5TextKeys.favoriteClearBroken, '清理失效收藏'),
            icon: const Icon(Icons.cleaning_services_outlined),
            onPressed: _clearBroken,
          ),
          IconButton(
            tooltip: t.photoRefresh,
            icon: const Icon(Icons.refresh),
            onPressed: _reload,
          ),
        ],
      ),
      body: api == null
            ? AppEmptyState(icon: Icons.cloud_off, title: t.setNotConnected)
            : Column(
                children: [
                  // M51：个人文件夹固定在收藏页最上方（官方抽屉里的 home 项）
                  Material(
                    type: MaterialType.transparency,
                    child: DesignRowTile(
                      key: const Key('file-home-entry'),
                      leading: const Icon(Icons.person_outline),
                      title: Text(
                        fsGap2(FsGap2TextKeys.personalFolder, '个人文件夹'),
                      ),
                      subtitle: Text(
                        homeEntry.path,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      trailing: const Icon(Icons.chevron_right),
                      onTap: () => _openHome(homeEntry),
                    ),
                  ),
                  const Divider(height: 1),
                  Expanded(
                    child: FutureBuilder(
                      future: _future,
                      builder: (context, snap) {
                        if (snap.connectionState != ConnectionState.done) {
                          return const AppListSkeleton();
                        }
                        if (snap.hasError) {
                          return AppErrorView(
                            title: t.fileFavoritesLoadFailed,
                            detail: describeFileError(snap.error!),
                            onRetry: _reload,
                          );
                        }
                        final rows =
                            snap.data ?? const <FileEntryDto>[];
                        if (rows.isEmpty) {
                          return AppEmptyState(
                            icon: Icons.star_border,
                            title: t.photoEmptyFavoritesTitle,
                            message: t.fileNoFavoritesMessage,
                          );
                        }
                        return ListView.builder(
                          itemCount: rows.length,
                          itemBuilder: (context, i) => FileRow(
                            entry: rows[i],
                            isFavorite: true,
                            onToggleFavorite: () => _unfavorite(rows[i]),
                            // 文件夹点开直接进；其余走收藏面板（含重命名收藏）
                            onTap: () => rows[i].isDir
                                ? _openFavorite(rows[i])
                                : openFileUnified(context, ref, rows[i]),
                            onMenu: () => _openFavorite(rows[i]),
                          ),
                        );
                      },
                    ),
                  ),
                ],
              ),
    );
  }
}

/// 分享链接（**只读管理**）：列出现有链接 + 删除 + 清理失效
class FileShareLinksPage extends ConsumerStatefulWidget {
  const FileShareLinksPage({super.key});

  @override
  ConsumerState<FileShareLinksPage> createState() => _FileShareLinksPageState();
}

class _FileShareLinksPageState extends ConsumerState<FileShareLinksPage> {
  late Future<List<ShareLinkDto>> _future;

  @override
  void initState() {
    super.initState();
    _future = _load();
  }

  Future<List<ShareLinkDto>> _load() async {
    final api = ref.read(fileApiProvider);
    if (api == null) return const [];
    return api.listShareLinks();
  }

  /// 「我的分享」（既有只读管理）的整块内容。
  ///
  /// wave3 起与「共享给我的」共用一个页面 —— 官方 Web 端也是这么组织的
  /// （`SharingManager.Manger.createTabPanel` 把
  /// `SharingPanel`(`list`) 与 `ShareWithMePanel`(`list_share_me`) 并成两个
  /// Tab，`/tmp/spk/export_FileStation/ui/file_browser/FileBrowser.js`）。
  Widget _buildMyLinks() {
    final t = context.t;
    return FutureBuilder(
        future: _future,
        builder: (context, snap) {
          if (snap.connectionState != ConnectionState.done) {
            return const AppListSkeleton();
          }
          if (snap.hasError) {
            return AppErrorView(
              title: t.fileShareLinksLoadFailed,
              detail: describeFileError(snap.error!),
              onRetry: () => setState(() => _future = _load()),
            );
          }
          final links = snap.data ?? const <ShareLinkDto>[];
          if (links.isEmpty) {
            return AppEmptyState(
              icon: Icons.link_off,
              title: t.fileNoShareLinks,
              message: t.fileNoShareLinksMessage,
            );
          }
          return ListView.builder(
            itemCount: links.length,
            itemBuilder: (context, i) {
              final link = links[i];
              return DesignRowTile(
                // r306：整行可点 = 看服务端详情（`Sharing/getinfo`）。
                // ★ 不加第 4 个图标：右侧已有 发送/编辑/删除 三个，
                //   再塞就违反 §2.0.10（放不下时该折进 ⋮ 而不是硬挤）。
                key: Key('share-link-row-${link.id}'),
                onTap: () => _openDetail(link),
                leading: Icon(
                  link.isFolder
                      ? Icons.folder_shared_outlined
                      : Icons.insert_drive_file_outlined,
                ),
                title: Text(link.name.isEmpty ? link.path : link.name),
                subtitle: Text(
                  [
                    if (!link.isValid) t.fileLinkInvalid,
                    if (link.hasPassword) t.fileLinkHasPassword,
                    if (link.dateExpired.isNotEmpty)
                      t.fileLinkExpiresAt(link.dateExpired),
                    link.path,
                  ].join(' · '),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                trailing: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    // M37：把链接发出去（官方 `email_link_context`）
                    if (link.url.isNotEmpty)
                      IconButton(
                        key: Key('share-link-send-${link.id}'),
                        tooltip: fsGap(FsGapTextKeys.shareSend, '发送'),
                        icon: const Icon(Icons.send_outlined),
                        onPressed: () async {
                          final ok = await ref.read(linkShareProvider)(
                            url: link.url,
                            subject: link.name,
                          );
                          if (context.mounted && !ok) {
                            AppSnack.show(
                              context,
                              fsGap(
                                FsGapTextKeys.shareSendFailed,
                                '发送失败（没有可用的应用）',
                              ),
                              error: true,
                            );
                          }
                        },
                      ),
                    // M36：编辑密码 / 有效期（`Sharing.edit`）
                    IconButton(
                      key: Key('share-link-edit-${link.id}'),
                      tooltip: fsGap(
                        FsGapTextKeys.editShareLink,
                        '编辑分享链接',
                      ),
                      icon: const Icon(Icons.edit_outlined),
                      onPressed: () => _edit(link),
                    ),
                    IconButton(
                      tooltip: t.fileDeleteLink,
                      icon: const Icon(Icons.delete_outline),
                      onPressed: () => _delete(link),
                    ),
                  ],
                ),
              );
            },
          );
        },
      );
  }

  @override
  Widget build(BuildContext context) {
    final hud = DesignPalette.of(context);
    final t = context.t;
    // wave3 能力门控：`list_share_me` 需要 `SYNO.FileStation.Sharing` **v2**
    // （真机逐版本：v1=103、v2/v3=OK）。服务端只到 v1、或根本没有 Sharing
    // → 「共享给我的」入口整个不渲染（复用 `FileCapabilities` 统一机制，
    // 与「下载任务」入口同一约定：不留会失败的入口）。
    final withMe = ref.watch(fileCapabilitiesProvider).canShareWithMe;
    return DefaultTabController(
      length: withMe ? 2 : 1,
      child: Scaffold(
        backgroundColor: hud.bg,
        appBar: AppBar(
          title: Text(t.fileShareLinksTitle),
          // 有能力位才多出第二个 Tab；没能力位时页面形状与本批之前**完全一致**
          bottom: withMe
              ? TabBar(
                  tabs: [
                    Tab(text: t.fileShareLinksTitle),
                    Tab(
                      key: const Key('shared-with-me-tab'),
                      text: fsGap3(FsGap3TextKeys.shareWithMe, '共享给我的'),
                    ),
                  ],
                )
              : null,
          actions: [
            IconButton(
              tooltip: t.fileCleanInvalidLinks,
              icon: const Icon(Icons.cleaning_services_outlined),
              onPressed: () async {
                try {
                  // 只调 clear_invalid。之前这里先发了一次 `Sharing.delete(id="[]")`，
                  // 空数组在服务端是无效参数（真机 101），按钮必然弹错。
                  await ref.read(fileApiProvider)?.clearInvalidShareLinks();
                  setState(() => _future = _load());
                } catch (e) {
                  if (context.mounted) {
                    AppSnack.show(context, describeFileError(e), error: true);
                  }
                }
              },
            ),
          ],
        ),
        body: withMe
            ? TabBarView(children: [_buildMyLinks(), const _SharedWithMeTab()])
            : _buildMyLinks(),
      ),
    );
  }

  /// r306：分享链接详情 —— `Sharing/getinfo`（只读）。
  ///
  /// `FileStationApi.shareLinkInfo` 此前**全仓无调用方**（死代码）⇒ 这里接上它
  /// （§2.0.45：封装了没有 caller 就是死功能，要么接、要么删）。
  /// 把 `id` 传**裸串**（不是 `delete` 那种 JSON 数组串）—— 官方 APK 里
  /// `getShareLink(String)` 用的是 `SingleApiParameter`，这两条不一样。
  Future<void> _openDetail(ShareLinkDto link) async {
    final action = await showShareLinkDetailSheet(
      context,
      link: link,
      load: () =>
          ref.read(fileApiProvider)!.shareLinkInfo([link.id]),
    );
    if (!mounted) return;
    switch (action) {
      case 'edit':
        await _edit(link);
      case 'delete':
        await _delete(link);
    }
  }

  /// 删除单条分享链接（行内图标与详情面板**共用**这一条路径）。
  Future<void> _delete(ShareLinkDto link) async {
    try {
      await ref.read(fileActionsProvider).deleteShareLinks([link.id]);
      if (mounted) setState(() => _future = _load());
    } catch (e) {
      if (!mounted) return;
      AppSnack.show(context, describeFileError(e), error: true);
    }
  }

  /// M36：编辑分享链接（改密码 / 有效期）→ `Sharing.edit` → 刷新列表。
  Future<void> _edit(ShareLinkDto link) async {
    final draft = await showEditShareLinkSheet(context, link: link);
    if (draft == null || !mounted) return;
    try {
      await ref.read(fileActionsProvider).editShareLink(
        id: link.id,
        password: draft.password,
        clearPassword: draft.clearPassword,
        dateExpired: draft.dateExpired,
      );
      if (!mounted) return;
      setState(() => _future = _load());
      AppSnack.show(context, fsGap(FsGapTextKeys.shareEdited, '分享链接已更新'));
    } catch (e) {
      if (context.mounted) {
        AppSnack.show(context, describeFileError(e), error: true);
      }
    }
  }
}

/// 「共享给我的」Tab（wave3）。
///
/// 数据源：`SYNO.FileStation.Sharing / list_share_me` —— **v2**（真机逐版本：
/// v1=103、v2/v3=OK；本机空态回包
/// `{"data":{"links":[],"offset":0,"total":0},"success":true}`）。
///
/// 字段渲染逐个对照官方 Web 前端（`FileBrowser.js` 的
/// `SharingManager.Common.createStore` reader + `createColModel`）：
/// `name` / `path` / `link_owner` / `date_expired`(→`expire_at`) / `status` /
/// `isFolder` / `project_name`。**`id` 不上屏**（只在 Key / 断言里）。
class _SharedWithMeTab extends ConsumerStatefulWidget {
  const _SharedWithMeTab();

  @override
  ConsumerState<_SharedWithMeTab> createState() => _SharedWithMeTabState();
}

class _SharedWithMeTabState extends ConsumerState<_SharedWithMeTab> {
  late Future<SharedWithMeListResult> _future = _load();

  Future<SharedWithMeListResult> _load() async {
    final api = ref.read(fileApiProvider);
    if (api == null) return const SharedWithMeListResult();
    return api.listSharedWithMe();
  }

  /// 分享来源应用 → 类型标签（官方 `SharingManager.Common.getTypeArray` 的取值）
  String _typeLabel(String projectName) => switch (projectName) {
    'SYNO.SDS.App.FileStation3.Instance' => fsGap3(
      FsGap3TextKeys.typeSharingLinks,
      '分享链接',
    ),
    'SYNO.SDS.App.SharingUpload.Application' => fsGap3(
      FsGap3TextKeys.typeRequestLink,
      '文件请求',
    ),
    'SYNO.SDS.PDFViewer.Application' => fsGap3(
      FsGap3TextKeys.typeDocumentLink,
      '文档链接',
    ),
    _ => '',
  };

  /// `status` → 文案（官方列模型：`broken` / `expired` / `inactive`，其余 ok）
  String _statusLabel(String status) => switch (status) {
    'broken' => context.t.fileLinkInvalid,
    'expired' => fsGap3(FsGap3TextKeys.statusExpired, '已过期'),
    'inactive' => fsGap3(FsGap3TextKeys.statusInactive, '未生效'),
    _ => fsGap3(FsGap3TextKeys.statusOk, '有效'),
  };

  /// 打开分享目标：**复用既有的浏览路径**（`FileBrowsePage`），不另起一套。
  /// 目录直接进；文件进它所在目录 —— 与收藏页 `_openFavorite` 同一做法。
  void _open(SharedWithMeLinkDto link) {
    if (link.path.isEmpty) return;
    Navigator.of(context).push<void>(
      MaterialPageRoute(
        builder: (_) => FileBrowsePage(
          initialPath: link.isFolder ? link.path : _parentOf(link.path),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    return FutureBuilder(
      future: _future,
      builder: (context, snap) {
        if (snap.connectionState != ConnectionState.done) {
          return const AppListSkeleton();
        }
        if (snap.hasError) {
          final err = snap.error;
          // 103（方法不存在）/105（无权限）不是"加载失败"：能力/授权问题，
          // 给一句"不可用"说明，不画成红色错误页。
          final unavailable =
              err is DsmApiException &&
              (err.code == DsmErrorCode.methodNotFound ||
                  err.code == DsmErrorCode.noPermission);
          if (unavailable) {
            return AppEmptyState(
              icon: Icons.link_off,
              title: fsGap3(
                FsGap3TextKeys.unavailable,
                '服务器不支持"共享给我的"',
              ),
            );
          }
          return AppErrorView(
            title: fsGap3(FsGap3TextKeys.loadFailed, '共享给我的列表加载失败'),
            detail: describeFileError(err!),
            onRetry: () => setState(() => _future = _load()),
          );
        }
        final links = snap.data?.links ?? const <SharedWithMeLinkDto>[];
        if (links.isEmpty) {
          // 真机本机就是空（`links: []`）→ 明确空态，**不是错误**
          return AppEmptyState(
            icon: Icons.inbox_outlined,
            title: fsGap3(FsGap3TextKeys.noSharedWithMe, '还没有人分享给你'),
            message: fsGap3(
              FsGap3TextKeys.noSharedWithMeMessage,
              '别人分享给你的文件会出现在这里。',
            ),
          );
        }
        return ListView.builder(
          itemCount: links.length,
          itemBuilder: (context, i) {
            final link = links[i];
            final type = _typeLabel(link.projectName);
            return DesignRowTile(
              key: Key('shared-with-me-${link.id}'),
              leading: Icon(
                link.isFolder
                    ? Icons.folder_shared_outlined
                    : Icons.insert_drive_file_outlined,
              ),
              // 只显示名字/路径，**绝不显示 id**
              title: Text(link.name.isEmpty ? link.path : link.name),
              subtitle: Text(
                [
                  if (type.isNotEmpty) type,
                  if (link.linkOwner.isNotEmpty)
                    '${fsGap3(FsGap3TextKeys.sharedBy, '来自')} ${link.linkOwner}',
                  _statusLabel(link.status),
                  if (link.hasPassword) t.fileLinkHasPassword,
                  if (link.dateExpired.isNotEmpty)
                    t.fileLinkExpiresAt(link.dateExpired),
                  link.path,
                ].join(' · '),
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
              trailing: link.path.isEmpty
                  ? null
                  : const Icon(Icons.chevron_right),
              onTap: link.path.isEmpty ? null : () => _open(link),
            );
          },
        );
      },
    );
  }
}

/// 哪些任务的 API 支持 `stop`（`Search` 是另一套 `search_taskid`，不在这里）
bool _canStop(String apiName) => const {
  'SYNO.FileStation.Compress',
  'SYNO.FileStation.Extract',
  'SYNO.FileStation.CopyMove',
  'SYNO.FileStation.DirSize',
}.contains(apiName);

/// `clear_finished` 的**二次确认** + 执行。
///
/// 官方 DS file 把"清除已完成"放在弹层后面（`BackgroundTaskFragment` 的
/// `doClearTransferring` → `clearFinish`，`:262`/`:342`），确认文案是
/// `sure_to_clear_finish`（APK `res/values-zh-rCN/strings.xml:798` 逐字：
/// "已完成的任务会被清除。您确定要继续吗？"）。
///
/// ⚠️ 用户点"取消"或点弹层外面 ⇒ **一个请求都不发**；只有点确认才发
/// `BackgroundTask.clear_finished`。这是"破坏性写操作不得一键触发"的硬要求。
Future<void> _confirmClearFinishedTasks(
  BuildContext context,
  WidgetRef ref,
) async {
  final ok = await confirmDanger(
    context,
    title: context.t.fileCleanFinished,
    message: fsTask(
      FsTaskTextKeys.clearConfirmFinished,
      '已完成的任务会被清除。您确定要继续吗？',
    ),
    actionLabel: context.t.fileCleanFinished,
  );
  if (!ok || !context.mounted) return;
  try {
    await ref.read(fileActionsProvider).clearFinishedTasks();
  } catch (e) {
    if (context.mounted) {
      AppSnack.show(context, describeFileError(e), error: true);
    }
  }
}

/// 后台任务中心（文件部分）—— `BackgroundTask.list` / `clear_finished`
class FileTasksPage extends ConsumerWidget {
  const FileTasksPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final hud = DesignPalette.of(context);
    final t = context.t;
    final tasks = ref.watch(fileTasksProvider);
    return Scaffold(
      backgroundColor: hud.bg,
      appBar: AppBar(
        title: Text(t.wsTasks),
        actions: [
          IconButton(
            tooltip: t.fileCleanFinished,
            icon: const Icon(Icons.cleaning_services_outlined),
            // ⚠️ `clear_finished` 是**破坏性写接口**：它删的是 NAS 上"已完成
            // 后台任务"的历史记录，**没有回滚路径**（本会话真机事故见
            // `docs/probe-write-incident-2026-09-22.md`）。官方 DS file 也把它
            // 放在选择弹层后面（`BackgroundTaskFragment.doClearTransferring`
            // → `clearFinish`，`:275`），所以这里**必须二次确认**后才发请求。
            onPressed: () => _confirmClearFinishedTasks(context, ref),
          ),
          IconButton(
            tooltip: t.photoRefresh,
            icon: const Icon(Icons.refresh),
            onPressed: () => ref.invalidate(fileTasksProvider),
          ),
        ],
      ),
      body: tasks.when(
          loading: () => const AppListSkeleton(),
          error: (e, __) => AppErrorView(
            title: t.fileTasksLoadFailed,
            detail: describeFileError(e),
            onRetry: () => ref.invalidate(fileTasksProvider),
          ),
          data: (rows) {
            if (rows.isEmpty) {
              return AppEmptyState(
                icon: Icons.done_all,
                title: t.fileNoTasks,
                message: t.fileNoTasksMessage,
              );
            }
            // 任务行现在可点（P1-8 详情），而 `FieldBackdrop` 用 `ColoredBox`
            // 垫底 —— 中间不隔一层 `Material` 的话，带 onTap 的 ListTile
            // 每帧都会抛"水波纹可能看不见"的断言。
            return Material(
              type: MaterialType.transparency,
              child: RefreshIndicator(
              onRefresh: () async => ref.invalidate(fileTasksProvider),
              child: ListView.builder(
                physics: const AlwaysScrollableScrollPhysics(),
                itemCount: rows.length,
                itemBuilder: (context, i) {
                  final task = rows[i];
                  return DesignRowTile(
                    // P1-8：点开看任务的 api/method/params/errors（官方 DETAIL）
                    // M58：失败任务在详情里给「重试」（重发原 api/参数）
                    onTap: () => showFileTaskDetailSheet(
                      context,
                      task,
                      onRetry: () =>
                          ref.read(fileActionsProvider).retryTask(task),
                    ),
                    leading: Icon(
                      task.finished
                          ? Icons.check_circle_outline
                          : Icons.autorenew,
                    ),
                    title: Text(task.label),
                    subtitle: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          task.processingPath.isEmpty
                              ? task.path
                              : task.processingPath,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                        if (!task.finished)
                          Padding(
                            padding: const EdgeInsets.only(top: 4),
                            child: LinearProgressIndicator(
                              value: task.progress <= 0 ? null : task.progress,
                            ),
                          ),
                        // ★ 第 303 轮真机缺陷：卡死的任务会永远显示 `0%` +
                        // 「任务错误：没有错误」，客户端没有任何失败面。这里把
                        // **服务端下发的事实**（`crtime` ⇒ 已经跑了多久）摊给用户，
                        // 让"1 秒的任务跑了 25 分钟"这个矛盾可见，再由他自己决定
                        // 要不要点「停止任务」。**不设"超时=死"的阈值**（无依据）。
                        if (!task.finished)
                          if (fileTaskElapsed(task.createdTime)
                              case final elapsed?)
                            Padding(
                              padding: const EdgeInsets.only(top: 2),
                              child: TelemetryLabel(
                                elapsed.hours == null
                                    ? t.fileTaskElapsedMinutes(elapsed.minutes)
                                    : t.fileTaskElapsedHours(
                                        elapsed.hours!,
                                        elapsed.minutes,
                                      ),
                                size: 11,
                              ),
                            ),
                        if (task.errors.isNotEmpty)
                          Text(
                            t.fileTasksFailedCount(task.errors.length),
                            style: TextStyle(
                              color: Theme.of(context).colorScheme.error,
                            ),
                          ),
                      ],
                    ),
                    trailing: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        if (!task.finished && _canStop(task.api))
                          IconButton(
                            tooltip: t.fileStopTask,
                            icon: const Icon(Icons.stop_circle_outlined),
                            onPressed: () async {
                              try {
                                // ⚠️ taskid 是裸字符串（真机实测：发 JSON 数组串
                                // 服务端回的是 HTML 错误页），多个任务就一个个停
                                await ref
                                    .read(fileApiProvider)
                                    ?.stopTask(
                                      apiName: task.api,
                                      taskId: task.taskId,
                                    );
                                ref.invalidate(fileTasksProvider);
                              } catch (e) {
                                if (context.mounted) {
                                  AppSnack.show(
                                    context,
                                    describeFileError(e),
                                    error: true,
                                  );
                                }
                              }
                            },
                          ),
                        TelemetryLabel(
                          task.finished
                              ? t.calEnvDone
                              : '${(task.progress * 100).round()}%',
                          size: 11,
                        ),
                      ],
                    ),
                  );
                },
              ),
              ),
            );
          },
        ),
    );
  }
}
