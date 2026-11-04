// Office 模板**全屏预览**：默认直接显示**模板正文**（服务端导出为 OOXML 后由
// 既有阅读器渲染，只读），可一键切回官方 2x 缩略图；左右换模板、缩放、
// 本地化标题/类型/来源 + 「使用此模板」。
//
// 为什么正文能出来（第 265 轮推翻第 260 轮的"只能看缩略图"）：
//   * 第 260 轮的依据是真机 `Office.Snapshot:get` 回 57379、
//     `Office.Doc.Snapshot:get` 回 105；第 265 轮把三条路都重新取证：
//     - `Office.Doc/Presentation/Sheet.Snapshot` 在 `webapi/SYNO.Office.lib`
//       里 `allowUser` 只有 admin ⇒ **105 是真实权限结论**（编辑器内部接口）；
//     - `Office.Snapshot:get` 的参数是 **`link_id`**（缺 → `120
//       {"name":"link_id","reason":"required"}`；不是 Drive 分享链接才回
//       57379）⇒ 那是 **Drive 分享链接**的预览通道，不是模板通道；
//     - 模板的正文通道是 **`Office.Export/download`**：官方 `ui.doc.js`
//       的 `downloadOffice()` 对 `Env.is_template` 走的分支逐字是
//       `e = Ext.apply({object_id: SYNO.SDS.Office.Env.objectId}, e)`，
//       而模板右键菜单第一项 `itemId:"open"` 的文案就是 `cf.preview`（预览）——
//       官方 Web 的"预览"就是**在阅读器里打开模板本体**。
//   * 真机（只读 POST 表单）53 个系统模板全部可导：`{object_id, format:"ms"}`
//     → 200 + 真 OOXML（doc 13,039 B / sheet 14,536 B / slide 29,008 B）。
//   证据全文：`docs/office-template-gallery.md` §9。
//
// 界面迁移决策（"适配安卓"而不是照抄桌面 Web，见同文档 §5）：
//   * 官方 Web 是"点卡片 = 直接用该模板新建"（`doMakeTemplate`）——
//     那会**在用户 Drive 里凭空造一个文件**，是有副作用的动作；
//     手机触屏误触率高，所以把"新建"放进预览里的显式按钮；
//   * 点卡片 = 预览（本页）；长按/⋮ = 菜单（预览 / 使用此模板）；
//   * 正文模式**不用** `PageView`（高保真阅读器自带横滑/翻页手势，两套会打架），
//     换模板走头部按钮；缩略图模式才用 `PageView` 横滑（保持既有交互与用例）。
//
// 正文渲染（第 272 轮改，详见 `office_template_document.dart` 文件头）：
//   第 265 轮用书籍阅读器渲染 docx/pptx —— 真机导出字节实测把版式全丢了
//   （字号/颜色/字体/页眉页脚/页边距 0 保留；主题 pptx 只剩一行标题）。
//   现在改用仓库**既有**的 Office OOXML 阅读器：docx → `OfficeDocxView`
//   （A4 纸面 + 真实页边距 + 分页 + 缩放适宽），pptx → `OfficeSlidesDeckView`
//   （16:9 画布 + 母版版式继承 + 翻页指示 + 全屏缩放）；解析不出来才回落
//   书籍阅读器。**没有**新写第二个渲染器。
//
// 诚实边界（必须显示，不许吹）：正文是**服务端导出**的 OOXML（只读、不是
// 可编辑的原生节点）；导不出来时（无权限/会话失效/加密模板/网络）**如实
// 回落**官方缩略图 + 元数据，并把**分类后的**原因写进说明行 + `debugPrint`
// （AGENTS §2.0.17 ②：中间态与失败态要分得清、失败要说得出为什么）。
import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart' show SchedulerBinding;

import '../../design/design_palette.dart';
import '../../core/i18n/data_text.dart';
import '../../core/theme/app_tokens.dart';
import '../../core/ui/adaptive_actions.dart';
import '../../data/office_api.dart';
import '../analytics/analytics_track.dart';
import '../analytics/usage_event.dart';
import 'office_template_document.dart';
import 'office_template_text.dart';
import 'office_template_thumbs.dart';

String officeTemplatePreviewText(String key, String zh) => dataText(key, zh);

/// 取正文失败 → **用户能懂的一句中文/英文原因**（不是把异常 toString 甩上屏）。
///
/// 为什么要有这张映射表（AGENTS §2.0.17 ②）：`OfficeAttachmentException` 的
/// `toString()` 是 `OfficeAttachmentException(network, code=…)` 这种工程串，
/// 既看不懂也分不出"该重试"还是"该换网络"。分类键来自真机实测的失败形态
/// （`105/119/6/404/空字节/超时`，见 `office_api.dart` 的
/// `officeAttachmentExceptionFor`）；未归类的异常仍**原样带一句**，
/// 绝不吞掉原因。
String officeTemplateBodyFailureReason(Object? error) {
  if (error is OfficeAttachmentException) {
    switch (error.kind) {
      case OfficeAttachmentErrorKind.missingParam:
        return officeTemplatePreviewText(
          'officeTemplateBodyReasonMissingId',
          '这个模板缺少标识，取不到正文',
        );
      case OfficeAttachmentErrorKind.notFound:
        return officeTemplatePreviewText(
          'officeTemplateBodyReasonNotFound',
          '服务端说这个模板的正文不在了（可能已被删除）',
        );
      case OfficeAttachmentErrorKind.noPermission:
        return officeTemplatePreviewText(
          'officeTemplateBodyReasonNoPermission',
          '当前账号没有导出这个模板正文的权限',
        );
      case OfficeAttachmentErrorKind.sessionExpired:
        return officeTemplatePreviewText(
          'officeTemplateBodyReasonSession',
          '登录状态已失效，重新连接后再试',
        );
      case OfficeAttachmentErrorKind.timeout:
        return officeTemplatePreviewText(
          'officeTemplateBodyReasonTimeout',
          '取模板正文超时，可以重试',
        );
      case OfficeAttachmentErrorKind.network:
        return officeTemplatePreviewText(
          'officeTemplateBodyReasonNetwork',
          '网络不通，取不到模板正文',
        );
      case OfficeAttachmentErrorKind.empty:
        return officeTemplatePreviewText(
          'officeTemplateBodyReasonEmpty',
          '服务端回了空正文（这个模板可能没有内容）',
        );
      case OfficeAttachmentErrorKind.unknown:
        break;
    }
    if (error.detail.isNotEmpty) {
      return officeTemplatePreviewText(
        'officeTemplateBodyFailed',
        '正文导出失败：{error}',
      ).replaceAll('{error}', error.detail);
    }
  }
  final text = '$error';
  return officeTemplatePreviewText(
    'officeTemplateBodyFailed',
    '正文导出失败：{error}',
  ).replaceAll('{error}', text.length <= 120 ? text : '${text.substring(0, 120)}…');
}

/// 全屏模板预览：正文（默认）或官方缩略图，左右/按钮换模板。
///
/// [onUseTemplate] 非空时才显示主按钮；点它会先关掉本页，再由调用方
/// 走**既有的**「从模板新建」流程（标题对话框 → `Template:make`），
/// 本页**不自己发任何写请求**。
class OfficeTemplatePreviewPage extends StatefulWidget {
  const OfficeTemplatePreviewPage({
    super.key,
    required this.templates,
    this.initialIndex = 0,
    this.thumbFetcher,
    this.thumbCache,
    this.bodyFetcher,
    this.bodyCache,
    this.encrypt = false,
    this.onUseTemplate,
  });

  /// 预览里可切换的模板序列（网格当前分组/过滤后的顺序）。
  final List<OfficeTemplateDto> templates;
  final int initialIndex;

  /// 缩略图字节提供者（生产 = `OfficeApi.templateThumbBytes`）。
  final OfficeTemplateThumbFetcher? thumbFetcher;
  final OfficeTemplateThumbCache? thumbCache;

  /// 正文字节提供者（生产 = `OfficeApi.templateExportBytes`）。
  ///
  /// **null = 走缩略图预览**（未连接 / 未注入；既有调用方与离线用例不受影响）。
  final OfficeTemplateBodyFetcher? bodyFetcher;

  /// 正文缓存；null = 进程级默认实例。
  final OfficeTemplateBodyCache? bodyCache;

  /// 从**加密入口**进来时为 true（按钮文案变「加密新建」）。
  final bool encrypt;

  /// 「使用此模板」：由调用方接既有的 `Template:make` 流程。
  final void Function(OfficeTemplateDto template)? onUseTemplate;

  @override
  State<OfficeTemplatePreviewPage> createState() =>
      _OfficeTemplatePreviewPageState();
}

/// 正文加载的**四个状态**（AGENTS §2.0.17 ②：中间态与失败态必须分得清，
/// 而且"取字节"与"排版"是**两个**中间态 —— 大模板的排版也要时间）。
enum OfficeTemplateBodyStage {
  /// 正在**取字节**（网络）。
  fetching,

  /// 字节到手，正在**解析/排版**成本地阅读器模型。
  rendering,

  /// 已就绪。
  ready,

  /// 失败（原因见 [officeTemplateBodyFailureReason]）。
  failed,
}

/// 一个模板的正文加载结果。
class _BodyLoad {
  const _BodyLoad(this.stage, {this.model, this.error});

  final OfficeTemplateBodyStage stage;
  final OfficeTemplateBodyModel? model;
  final Object? error;
}

class _OfficeTemplatePreviewPageState extends State<OfficeTemplatePreviewPage> {
  late final PageController _controller = PageController(
    initialPage: widget.initialIndex.clamp(
      0,
      widget.templates.isEmpty ? 0 : widget.templates.length - 1,
    ),
  );
  late int _index = widget.initialIndex.clamp(
    0,
    widget.templates.isEmpty ? 0 : widget.templates.length - 1,
  );

  /// 正文模式开关（没注入 [OfficeTemplatePreviewPage.bodyFetcher] 时恒为 false）。
  late bool _showBody = widget.bodyFetcher != null;

  late final OfficeTemplateBodyCache _bodyCache =
      widget.bodyCache ?? officeTemplateBodyCache;

  /// objectId → 正文字节 future（跨重建复用，不重复打网络）。
  final Map<String, Future<Uint8List>> _bodyFutures = {};

  /// objectId → 加载状态（fetching / rendering / ready / failed）。
  final Map<String, _BodyLoad> _loads = {};

  /// 已经打过失败日志的 objectId（一条失败只打一次，别刷屏）。
  final Set<String> _loggedFailures = {};

  @override
  void initState() {
    super.initState();
    trackOnce(UsageModule.office, UsageAction.preview, objectType: 'template');
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  OfficeTemplateDto? get _current =>
      widget.templates.isEmpty ? null : widget.templates[_index];

  void _use(OfficeTemplateDto template) {
    Navigator.of(context).pop();
    widget.onUseTemplate?.call(template);
    // 「使用此模板」= 从模板新建（唯一有副作用的主按钮，记一次意图）。
    trackOnce(UsageModule.office, UsageAction.create, objectType: 'template');
  }

  /// 这个模板**为什么**没有正文（加密模板要先有口令，本页不发口令 ⇒ 不试）；
  /// 有正文返回 `null`。
  String? _bodyUnavailableReason(OfficeTemplateDto template) {
    if (template.encrypt) {
      return officeTemplatePreviewText(
        'officeTemplateBodyEncrypted',
        '这是加密模板，需要口令才能导出正文',
      );
    }
    if (officeTemplateBodyKind(template.ntype) == null) {
      return officeTemplatePreviewText(
        'officeTemplateBodyUnknownType',
        '这种类型的模板没有可用的正文导出',
      );
    }
    return null;
  }

  /// 取正文（失败记忆 + 并发去重都在 [_bodyCache] 里）。
  Future<Uint8List> _bodyFuture(OfficeTemplateDto template) {
    final existing = _bodyFutures[template.objectId];
    if (existing != null) return existing;
    final fetcher = widget.bodyFetcher;
    final future = fetcher == null
        ? Future<Uint8List>.error(
            StateError('未注入模板正文字节提供者'),
          )
        : _bodyCache.load(
            template.objectId,
            () => fetcher(template),
          );
    _bodyFutures[template.objectId] = future;
    return future;
  }

  /// 取字节 → 排版 → 就绪 / 失败，**每个中间态都 setState 一次**，
  /// 这样用户看到的不是"一个转圈然后突然全出现"，失败也不会伪装成加载。
  Future<void> _runLoad(OfficeTemplateDto template) async {
    try {
      final bytes = await _bodyFuture(template);
      if (!mounted) return;
      setState(() {
        _loads[template.objectId] = const _BodyLoad(
          OfficeTemplateBodyStage.rendering,
        );
      });
      // 解析是同步的：让出**一帧**，好让"正在排版"真的画出来
      // （否则这一帧会被同步解析挡在后面，用户永远看不到）。
      await SchedulerBinding.instance.endOfFrame;
      if (!mounted) return;
      final kind = officeTemplateBodyKind(template.ntype);
      if (kind == null) {
        setState(() {
          _loads[template.objectId] = _BodyLoad(
            OfficeTemplateBodyStage.failed,
            error: StateError('unknown ntype'),
          );
        });
        return;
      }
      final model = prepareOfficeTemplateBody(kind, bytes);
      setState(() {
        _loads[template.objectId] = _BodyLoad(
          OfficeTemplateBodyStage.ready,
          model: model,
        );
      });
    } catch (error) {
      if (!mounted) return;
      _logBodyFailure(template, error);
      // 稳定的失败原因：附件错误用 Enum（`OfficeAttachmentErrorKind`），
      // 其余归到 decode（解析/排版失败）。绝不把 message 当原因。
      trackOnceFailure(
        UsageModule.office,
        UsageAction.preview,
        objectType: 'template',
        reason: error is OfficeAttachmentException
            ? error.kind
            : UsageFailureReason.decode,
        error: error,
      );
      setState(() {
        _loads[template.objectId] = _BodyLoad(
          OfficeTemplateBodyStage.failed,
          error: error,
        );
      });
    }
  }

  void _logBodyFailure(OfficeTemplateDto template, Object error) {
    if (!_loggedFailures.add(template.objectId)) return;
    // ★ 可查询的失败原因（release 包也进 logcat，tag `flutter`）：
    //   与"还在加载"完全分开，见 AGENTS §2.0.17 ②。
    debugPrint(
      '[officeTemplatePreview] FAIL object_id=${template.objectId} '
      'ntype=${template.ntype} reason=$error',
    );
  }

  void _retryBody() {
    final template = _current;
    if (template == null) return;
    _bodyCache.invalidate(template.objectId);
    _loggedFailures.remove(template.objectId);
    setState(() {
      _bodyFutures.remove(template.objectId);
      _loads.remove(template.objectId);
    });
  }

  void _go(int delta) {
    final total = widget.templates.length;
    if (total == 0) return;
    final next = (_index + delta).clamp(0, total - 1);
    if (next == _index) return;
    setState(() => _index = next);
  }

  void _toggleBody() {
    setState(() {
      _showBody = !_showBody;
      if (!_showBody && _controller.hasClients) {
        _controller.jumpToPage(_index);
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final total = widget.templates.length;
    final bodyMode = _showBody && widget.bodyFetcher != null;
    return Scaffold(
      key: const Key('office-template-preview'),
      backgroundColor: DesignPalette.of(context).bg,
      appBar: AppBar(
        leading: IconButton(
          key: const Key('office-template-preview-close'),
          tooltip: officeTemplatePreviewText('officeTemplatePreviewClose', '关闭'),
          icon: const Icon(Icons.close),
          onPressed: () => Navigator.of(context).maybePop(),
        ),
        title: Text(
          officeTemplatePreviewText(
            'officeTemplatePreviewCounter',
            '{index} / {total}',
          )
              .replaceAll('{index}', '${_index + 1}')
              .replaceAll('{total}', '$total'),
          key: const Key('office-template-preview-counter'),
        ),
        actions: adaptiveActions([
          // 正文模式没有 PageView（阅读器自带横滑，别打架）⇒ 换模板走按钮。
          if (bodyMode && total > 1)
            IconButton(
              key: const Key('office-template-preview-prev'),
              tooltip: officeTemplatePreviewText('officeTemplatePreviewPrev', '上一个'),
              icon: const Icon(Icons.chevron_left),
              onPressed: _index > 0 ? () => _go(-1) : null,
            ),
          if (bodyMode && total > 1)
            IconButton(
              key: const Key('office-template-preview-next'),
              tooltip: officeTemplatePreviewText('officeTemplatePreviewNext', '下一个'),
              icon: const Icon(Icons.chevron_right),
              onPressed: _index < total - 1 ? () => _go(1) : null,
            ),
          if (widget.bodyFetcher != null && total > 0)
            IconButton(
              key: const Key('office-template-preview-toggle'),
              tooltip: bodyMode
                  ? officeTemplatePreviewText(
                      'officeTemplatePreviewShowThumb',
                      '看缩略图',
                    )
                  : officeTemplatePreviewText(
                      'officeTemplatePreviewShowBody',
                      '看正文',
                    ),
              icon: Icon(
                bodyMode ? Icons.image_outlined : Icons.article_outlined,
              ),
              onPressed: _toggleBody,
            ),
        ]),
      ),
      body: SafeArea(
        child: total == 0
            ? Center(
                key: const Key('office-template-preview-empty'),
                child: Text(
                  officeTemplatePreviewText(
                    'officeTemplateLibraryEmpty',
                    '服务端没有返回可用模板',
                  ),
                ),
              )
            : Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Expanded(
                    child: bodyMode
                        ? _bodyArea(_current!)
                        : _thumbPager(total),
                  ),
                  _note(context, bodyMode),
                  if (widget.onUseTemplate != null && _current != null)
                    Padding(
                      padding: const EdgeInsets.fromLTRB(
                        Gap.md,
                        Gap.xs,
                        Gap.md,
                        Gap.md,
                      ),
                      child: FilledButton.icon(
                        key: Key(
                          'office-template-preview-use-${_current!.objectId}',
                        ),
                        onPressed: () => _use(_current!),
                        icon: const Icon(Icons.add_box_outlined),
                        label: Text(
                          widget.encrypt
                              ? officeTemplatePreviewText(
                                  'officeTemplateUseEncrypted',
                                  '加密新建',
                                )
                              : officeTemplatePreviewText(
                                  'officeTemplateUse',
                                  '使用此模板',
                                ),
                        ),
                      ),
                    ),
                ],
              ),
      ),
    );
  }

  /// 缩略图模式：官方样式不变（PageView 横滑 + InteractiveViewer 缩放）。
  Widget _thumbPager(int total) => PageView.builder(
    key: const Key('office-template-preview-pager'),
    controller: _controller,
    itemCount: total,
    onPageChanged: (i) => setState(() => _index = i),
    itemBuilder: (context, i) => _page(widget.templates[i]),
  );

  /// 正文模式：加载中（取字节 / 排版两个中间态分开） / 正文 / 如实回落。
  Widget _bodyArea(OfficeTemplateDto template) {
    final unavailable = _bodyUnavailableReason(template);
    if (unavailable != null) return _bodyFallback(template, unavailable);

    var load = _loads[template.objectId];
    if (load == null) {
      // 第一次进这一页：立刻进入 fetching 并异步跑起来（不在 build 里 setState）。
      load = const _BodyLoad(OfficeTemplateBodyStage.fetching);
      _loads[template.objectId] = load;
      unawaited(_runLoad(template));
    }
    switch (load.stage) {
      case OfficeTemplateBodyStage.fetching:
        return _bodyLoading(template, OfficeTemplateBodyStage.fetching);
      case OfficeTemplateBodyStage.rendering:
        return _bodyLoading(template, OfficeTemplateBodyStage.rendering);
      case OfficeTemplateBodyStage.failed:
        return _bodyFallback(
          template,
          officeTemplateBodyFailureReason(load.error),
        );
      case OfficeTemplateBodyStage.ready:
        final model = load.model;
        if (model == null) {
          return _bodyFallback(
            template,
            officeTemplateBodyFailureReason(StateError('missing model')),
          );
        }
        return OfficeTemplateBodyView(
          key: const Key('office-template-preview-body'),
          model: model,
          title: officeTemplateTitleFromKey(template.titleKey),
        );
    }
  }

  /// 中间态：骨架（缩略图垫底）+ 转圈 + **说得出在干什么**。
  ///
  /// 两个阶段各有自己的键（`office-template-preview-body-stage` 的语义标签是
  /// `fetching` / `rendering`），既给用户看也给用例查（AGENTS §2.0.17 ②）。
  Widget _bodyLoading(OfficeTemplateDto template, OfficeTemplateBodyStage stage) {
    final label = stage == OfficeTemplateBodyStage.fetching
        ? officeTemplatePreviewText(
            'officeTemplateBodyFetching',
            '正在获取模板正文…',
          )
        : officeTemplatePreviewText(
            'officeTemplateBodyRendering',
            '正在排版…',
          );
    return Stack(
      key: const Key('office-template-preview-body-loading'),
      fit: StackFit.expand,
      children: [
        _thumbPage(template, zoomable: false),
        Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const CircularProgressIndicator(),
              const SizedBox(height: Gap.sm),
              // ★ **可查询的阶段**：语义标签是机器可读的 `fetching`/`rendering`，
              //   正文是给用户看的话。两者都要有（AGENTS §2.0.17 ②）。
              Semantics(
                key: const Key('office-template-preview-body-stage'),
                label: stage.name,
                child: Text(label),
              ),
            ],
          ),
        ),
      ],
    );
  }

  /// 失败/不可用：官方 2x 缩略图 + 元数据 + **说得出为什么**。
  Widget _bodyFallback(OfficeTemplateDto template, String reason) {
    return Column(
      key: Key('office-template-preview-body-fallback-${template.objectId}'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Expanded(
          child: _thumbPage(template, zoomable: true),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: Gap.md),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(
                Icons.info_outline,
                size: 16,
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
              const SizedBox(width: Gap.xxs),
              Expanded(
                child: Text(
                  reason,
                  key: const Key('office-template-preview-body-reason'),
                  style: Theme.of(context).textTheme.labelSmall?.copyWith(
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
                ),
              ),
              TextButton(
                key: const Key('office-template-preview-body-retry'),
                onPressed: _retryBody,
                child: Text(
                  officeTemplatePreviewText('officeLibraryRetry', '重试'),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  /// 单个模板的缩略图页（既有交互原样保留）。
  Widget _thumbPage(OfficeTemplateDto template, {required bool zoomable}) {
    final title = officeTemplateTitleFromKey(template.titleKey);
    final image = Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 720),
        child: AspectRatio(
          aspectRatio: officeTemplateThumbAspect(template.ntype),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(6),
            child: ColoredBox(
              color: kOfficeTemplateThumbSkeleton,
              child: OfficeTemplateThumbnail(
                key: Key('office-template-preview-image-${template.objectId}'),
                objectId: template.objectId,
                ver: template.thumbVer,
                fetcher: widget.thumbFetcher,
                cache: widget.thumbCache,
                semanticLabel: title,
                iconSize: 48,
              ),
            ),
          ),
        ),
      ),
    );
    return Padding(
      padding: const EdgeInsets.all(Gap.md),
      child: zoomable
          ? InteractiveViewer(
              key: Key('office-template-preview-zoom-${template.objectId}'),
              minScale: 1,
              maxScale: 5,
              child: image,
            )
          : image,
    );
  }

  Widget _page(OfficeTemplateDto template) {
    final title = officeTemplateTitleFromKey(template.titleKey);
    return ListView(
      key: Key('office-template-preview-page-${template.objectId}'),
      padding: const EdgeInsets.all(Gap.md),
      children: [
        Center(
          child: InteractiveViewer(
            key: Key('office-template-preview-zoom-${template.objectId}'),
            minScale: 1,
            maxScale: 5,
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 720),
              child: AspectRatio(
                aspectRatio: officeTemplateThumbAspect(template.ntype),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(6),
                  child: ColoredBox(
                    color: kOfficeTemplateThumbSkeleton,
                    child: OfficeTemplateThumbnail(
                      key: Key(
                        'office-template-preview-image-${template.objectId}',
                      ),
                      objectId: template.objectId,
                      ver: template.thumbVer,
                      fetcher: widget.thumbFetcher,
                      cache: widget.thumbCache,
                      semanticLabel: title,
                      iconSize: 48,
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
        const SizedBox(height: Gap.md),
        Text(
          title,
          key: Key('office-template-preview-title-${template.objectId}'),
          style: Theme.of(context).textTheme.titleMedium,
        ),
        const SizedBox(height: Gap.xxs),
        Wrap(
          spacing: Gap.xs,
          runSpacing: Gap.xxs,
          children: [
            _badge(
              key: Key('office-template-preview-type-${template.objectId}'),
              text: officeTemplateTypeLabel(template.ntype),
            ),
            _badge(
              key: Key('office-template-preview-source-${template.objectId}'),
              text: template.system
                  ? officeTemplatePreviewText(
                      'officeTemplateSourceSystem',
                      '系统',
                    )
                  : officeTemplatePreviewText('officeTemplateSourceMine', '我的'),
            ),
          ],
        ),
      ],
    );
  }

  Widget _badge({required Key key, required String text}) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      key: key,
      padding: const EdgeInsets.symmetric(horizontal: Gap.sm, vertical: 3),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest.withValues(alpha: 0.5),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(text, style: Theme.of(context).textTheme.labelSmall),
    );
  }

  /// 说明行（**诚实分级**，不吹）：正文模式说清"正文由服务端导出、只读"，
  /// 缩略图模式说清"这只是缩略图、不是正文"。
  Widget _note(BuildContext context, bool bodyMode) {
    final text = bodyMode
        ? officeTemplatePreviewText(
            'officeTemplatePreviewBodyNote',
            '正文由服务端导出后本地渲染（只读）；导出失败会如实回落官方缩略图',
          )
        : officeTemplatePreviewText(
            'officeTemplatePreviewNote',
            '这是官方缩略图预览，不是正文渲染；要查看正文请用此模板新建后打开',
          );
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: Gap.md),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(
            Icons.info_outline,
            size: 16,
            color: Theme.of(context).colorScheme.onSurfaceVariant,
          ),
          const SizedBox(width: Gap.xxs),
          Expanded(
            child: Text(
              text,
              key: const Key('office-template-preview-note'),
              style: Theme.of(context).textTheme.labelSmall?.copyWith(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
