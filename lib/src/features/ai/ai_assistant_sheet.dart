// 端侧 AI 助手面板：**所有功能共用同一个弹层**（阅读器 / 笔记 / 文档预览）。
//
// 为什么做成"共用 + 由调用方给请求构造器"：
//   * 生成逻辑、流式展示、引用、降级提示只有一份，改一处全受益；
//   * 各功能只需要回答"这段文本是什么、标题是什么"；
//   * 没装模型时用内置摘要（UI 上如实标注"内置摘要（无模型）"），
//     并给一个"去装模型"的入口 —— 功能不会因为没模型就消失。
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../design/design_palette.dart';
import '../../core/i18n/l10n.dart';
import '../../core/theme/app_tokens.dart';
import 'ai_model_page.dart';
import 'ai_providers.dart';
import 'ai_service.dart';
import 'cloud_settings.dart';
import 'on_device_ai.dart';
import 'text_ai.dart';
import '../../core/user_facing_error.dart';
import '../analytics/analytics_track.dart';
import '../analytics/usage_event.dart';

/// 打开 AI 助手弹层
Future<void> showAiAssistant(
  BuildContext context, {
  required String title,
  required AiRequest Function(AiTaskKind kind, String question) build,
  AiTaskKind initial = AiTaskKind.summary,
  List<AiTaskKind> tasks = const [AiTaskKind.summary, AiTaskKind.askBook],
  Map<AiTaskKind, String> labelOverrides = const {},
  String? askHint,
  String selection = '',
}) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    builder: (_) => AiAssistantSheet(
      title: title,
      build: build,
      initial: initial,
      tasks: tasks,
      selection: selection,
      labelOverrides: labelOverrides,
      askHint: askHint,
    ),
  );
}

class AiAssistantSheet extends ConsumerStatefulWidget {
  const AiAssistantSheet({
    super.key,
    required this.title,
    required this.build,
    this.initial = AiTaskKind.summary,
    this.tasks = const [AiTaskKind.summary, AiTaskKind.askBook],
    this.labelOverrides = const {},
    this.askHint,
    this.selection = '',
  });

  /// 出处（书名 · 章节 / 笔记标题）
  final String title;

  /// 请求构造器：给定任务与问题，返回要发给引擎的请求
  final AiRequest Function(AiTaskKind kind, String question) build;

  final AiTaskKind initial;
  final List<AiTaskKind> tasks;

  /// 任务名的替换（例如 PDF 里 `askBook` 该叫"问这份 PDF"而不是"问这本书"）。
  /// 只换显示文案，不动 `AiTaskKind` 本身 —— 枚举是跨模块共用的。
  final Map<AiTaskKind, String> labelOverrides;

  /// "提问"输入框的提示语（内容形态不同，问法也不同）
  final String? askHint;

  /// 选中的原文（非空时显示长短，并允许"解释/翻译"）
  final String selection;

  @override
  ConsumerState<AiAssistantSheet> createState() => _AiAssistantSheetState();
}

class _AiAssistantSheetState extends ConsumerState<AiAssistantSheet> {
  final _question = TextEditingController();
  StreamSubscription<String>? _sub;

  AiTaskKind _kind = AiTaskKind.summary;
  String _raw = '';
  AiAnswer? _answer;
  String _error = '';
  bool _running = false;
  int _elapsed = 0;

  /// 这次生成用的是哪一档引擎（错误与空回答的文案要按档位说人话：
  /// 云端档说"检查地址/key/模型"，端侧档才说"内存紧张、换个更小的模型"）
  AiEngineKind? _errorEngine;

  /// 本次生成是否自动加大过长度（>0 就是在答案下面标一句，别默默多花钱）
  int _retriedBudget = 0;

  /// 模型返回的**思考内容**（云端推理模型 / 端侧 ` thinking` 段）。
  /// 默认折叠，点开才看，可复制 —— 以前这些都只用于诊断。
  String _thinkingText = '';
  bool _showThinking = false;

  @override
  void initState() {
    super.initState();
    trackView(UsageModule.ai, screen: 'assistant');
    _kind =
        widget.selection.isNotEmpty && widget.tasks.contains(AiTaskKind.explain)
        ? AiTaskKind.explain
        : widget.initial;
    // 首帧后再跑：initState 里直接跑会在 build 前改 state
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _run(_kind);
    });
  }

  @override
  void dispose() {
    _sub?.cancel();
    _question.dispose();
    super.dispose();
  }

  void _stop() {
    _sub?.cancel();
    _sub = null;
    // 云端：取消订阅不会自动断 HTTP，得额外说一声（省 token）
    ref.read(aiServiceProvider).cancel();
    if (mounted) setState(() => _running = false);
  }

  void _run(AiTaskKind kind, {String question = ''}) {
    _sub?.cancel();
    final req = widget.build(kind, question);
    final service = ref.read(aiServiceProvider);
    final engineKind = service.engineKind;
    setState(() {
      _kind = kind;
      _raw = '';
      _answer = null;
      _error = '';
      _errorEngine = engineKind;
      _retriedBudget = 0;
      _thinkingText = '';
      _showThinking = false;
      _running = true;
      _elapsed = 0;
    });
    final sw = Stopwatch()..start();
    _sub = service
        .stream(req)
        .listen(
          (chunk) {
            if (!mounted) return;
            setState(() => _raw += chunk);
          },
          onError: (Object e) {
            // 失败只记异常类型当原因码，绝不记 message（可能带 host/key）
            trackOnceFailure(
              UsageModule.ai,
              UsageAction.complete,
              objectType: kind.id,
              reason: e.runtimeType.toString(),
              error: e,
            );
            if (!mounted) return;
            setState(() {
              _running = false;
              _error = userFacingError(e);
              // 报错也可能已经收到了思考内容（例如"只在思考"到上限）
              _thinkingText = _collectThinking(service);
            });
          },
          onDone: () async {
            sw.stop();
            final retried = service.lastRetriedBudget;
            final finishSw = Stopwatch()..start();
            final answer = await service.finish(
              _raw,
              req,
              elapsedMs: sw.elapsedMilliseconds,
            );
            finishSw.stop();
            trackOnce(
              UsageModule.ai,
              UsageAction.complete,
              objectType: kind.id,
              detail: {UsageDetailKeys.kind: engineKind.id},
            );
            if (!mounted) return;
            setState(() {
              _running = false;
              _answer = answer;
              _elapsed = sw.elapsedMilliseconds;
              _retriedBudget = retried;
              _thinkingText = _collectThinking(service);
            });
          },
          cancelOnError: true,
        );
  }

  /// 思考内容从哪来：云端引擎自己收（Claude/Gemini 原生思考块 +
  /// OpenAI 兼容 `reasoning_content`）；端侧模型是 ` thinking` 段，从原始输出里摘。
  String _collectThinking(AiService service) {
    final fromEngine = service.lastThinking.trim();
    if (fromEngine.isNotEmpty) return fromEngine;
    if (_raw.isEmpty) return '';
    return extractThinkingText(_raw);
  }

  @override
  Widget build(BuildContext context) {
    final hud = DesignPalette.of(context);
    final theme = Theme.of(context);
    final readiness = ref.watch(aiReadinessProvider);
    final installed = ref.watch(aiInstalledModelsProvider).value ?? const [];
    final modelName = ref.watch(aiModelChoiceProvider)?.displayName ?? '';
    final usingModel = installed.isNotEmpty;
    final tier = ref.watch(aiTierProvider);
    final cloud = ref.watch(cloudSettingsProvider);
    // 当前实际会用的引擎（云端配好就是云端；没配好会自动降级）
    final cloudActive = tier == AiTier.cloud && cloud.configured;

    return Padding(
      padding: EdgeInsets.only(
        bottom: MediaQuery.of(context).viewInsets.bottom,
      ),
      child: Material(
        color: hud.bg,
        shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(18)),
        ),
        child: ConstrainedBox(
          constraints: BoxConstraints(
            maxHeight: MediaQuery.of(context).size.height * 0.85,
          ),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(Gap.md, Gap.sm, Gap.md, Gap.md),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _header(
                  theme,
                  hud,
                  usingModel,
                  modelName,
                  cloudActive: cloudActive,
                  cloudModel: cloud.model,
                  cloudProvider: cloud.provider.nameText,
                ),
                const SizedBox(height: Gap.sm),
                _tasks(theme, hud),
                if (widget.selection.isNotEmpty) ...[
                  const SizedBox(height: Gap.xs),
                  Text(
                    context.t.aiSelectedChars(
                      widget.selection.characters.length,
                    ),
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: hud.dim,
                    ),
                  ),
                ],
                if (_kind == AiTaskKind.askBook) ...[
                  const SizedBox(height: Gap.sm),
                  _askBar(theme, hud),
                ],
                const SizedBox(height: Gap.sm),
                Flexible(child: _body(theme, hud, readiness, installed)),
                const SizedBox(height: Gap.sm),
                _footer(theme, hud, readiness, installed),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _header(
    ThemeData theme,
    DesignPalette hud,
    bool usingModel,
    String name, {
    bool cloudActive = false,
    String cloudModel = '',
    String cloudProvider = '',
  }) {
    return Row(
      children: [
        Icon(Icons.auto_awesome, size: 18, color: theme.colorScheme.primary),
        const SizedBox(width: Gap.sm),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                context.t.aiSheetTitle(_kind.labelIn(context.t)),
                style: theme.textTheme.titleSmall,
              ),
              Text(
                widget.title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.bodySmall?.copyWith(color: hud.dim),
              ),
            ],
          ),
        ),
        if (cloudActive)
          _Badge(
            icon: Icons.cloud_outlined,
            text: cloudModel.isEmpty
                ? cloudProvider
                : '${cloudProvider.split(' ').first} · $cloudModel',
            color: theme.colorScheme.primary,
          )
        else if (usingModel)
          _Badge(
            icon: Icons.memory,
            text: name.isEmpty ? context.t.aiEngineOnDevice : name,
            color: theme.colorScheme.primary,
          )
        else
          _Badge(
            icon: Icons.bolt,
            text: context.t.aiEngineExtractive,
            color: hud.dim,
          ),
        IconButton(
          onPressed: () => Navigator.of(context).pop(),
          icon: const Icon(Icons.close, size: 20),
        ),
      ],
    );
  }

  Widget _tasks(ThemeData theme, DesignPalette hud) {
    final items = <AiTaskKind>{
      ...widget.tasks,
      if (widget.selection.isNotEmpty) AiTaskKind.explain,
      if (widget.selection.isNotEmpty) AiTaskKind.translate,
    }.toList();
    return Wrap(
      spacing: Gap.xs,
      children: [
        for (final t in items)
          ChoiceChip(
            label: Text(widget.labelOverrides[t] ?? t.labelIn(context.t)),
            selected: _kind == t,
            onSelected: (_) {
              if (t == AiTaskKind.askBook) {
                setState(() => _kind = t);
                return;
              }
              _run(t);
            },
          ),
      ],
    );
  }

  Widget _askBar(ThemeData theme, DesignPalette hud) {
    return Row(
      children: [
        Expanded(
          child: TextField(
            controller: _question,
            textInputAction: TextInputAction.send,
            onSubmitted: (v) {
              if (v.trim().isEmpty) return;
              _run(AiTaskKind.askBook, question: v.trim());
            },
            decoration: InputDecoration(
              hintText: widget.askHint ?? context.t.aiAskHintDefault,
              isDense: true,
              filled: true,
              fillColor: hud.surface2,
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(10),
                borderSide: BorderSide(color: hud.line),
              ),
            ),
          ),
        ),
        const SizedBox(width: Gap.sm),
        // 主题里 FilledButton 是全宽按钮：放在 Row 里要显式给宽度
        SizedBox(
          width: 88,
          child: FilledButton(
            onPressed: _running
                ? null
                : () {
                    final v = _question.text.trim();
                    if (v.isEmpty) return;
                    _run(AiTaskKind.askBook, question: v);
                  },
            child: Text(context.t.aiAskAction),
          ),
        ),
      ],
    );
  }

  Widget _body(
    ThemeData theme,
    DesignPalette hud,
    AsyncValue<dynamic> readiness,
    List<String> installed,
  ) {
    // 流式期间也走同一套清洗：Qwen3 这类带思考段的模型会**边生成边**把
    // ` thinking…` 冒出来（真机实测），不能等结束后再删；
    // 同时修掉 byte-level 词表在真机上的 Latin-1 乱码（`Ġç®…` → `算…`）。
    final streamed = cleanModelText(_raw);
    final thinking =
        _raw.isNotEmpty &&
        splitThinking(repairMojibake(_raw)).thinking &&
        streamed.isEmpty;
    if (_error.isNotEmpty) {
      // ⚠️ 文案必须**分档位**：云端档还写"模型在手机上跑"会让人以为配的云端模型
      // 根本没被用上（真机上就是被这句话误导过）。
      final cloud = _errorEngine == AiEngineKind.cloud;
      return SingleChildScrollView(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _hint(
              theme,
              hud,
              Icons.error_outline,
              cloud ? context.t.aiCloudNoAnswer : context.t.aiNoAnswer,
              cloud
                  ? context.t.aiCloudErrorDetail(_error)
                  : context.t.aiOnDeviceErrorDetail(_error),
            ),
            // 失败也可能是"只在思考"：把已收到的思考给出来，别浪费
            if (_thinkingText.isNotEmpty) _thinkingPanel(theme, hud),
          ],
        ),
      );
    }
    if (_raw.isEmpty && _running || thinking) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: Gap.lg),
        child: Row(
          children: [
            const SizedBox(
              width: 18,
              height: 18,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
            const SizedBox(width: Gap.sm),
            Text(
              thinking
                  ? context.t.aiThinking
                  // ⚠️ 按档位说：云端档写"端侧模型正在生成…"会让用户以为
                  // 配的云端模型根本没被用上（真机上差点又被这句误导）
                  : switch (_errorEngine) {
                      AiEngineKind.cloud => context.t.aiCloudGenerating,
                      AiEngineKind.onDeviceModel =>
                        context.t.aiOnDeviceGenerating,
                      AiEngineKind.extractive => context.t.aiExtracting,
                      null =>
                        installed.isEmpty
                            ? context.t.aiExtracting
                            : context.t.aiOnDeviceGenerating,
                    },
              style: theme.textTheme.bodySmall?.copyWith(color: hud.dim),
            ),
          ],
        ),
      );
    }
    if (_raw.isEmpty && _answer == null) {
      return _hint(
        theme,
        hud,
        Icons.auto_awesome_outlined,
        context.t.aiPickAction,
        context.t.aiPickActionHint,
      );
    }
    final answer = _answer;
    final body = answer?.text.isNotEmpty == true ? answer!.text : streamed;
    if (body.trim().isEmpty && !_running) {
      // 跑完了却什么都没有：过去这里会静静显示空白（看着像"功能没生效"）。
      // 现在如实说明，并给出可操作的下一步；**有思考内容时照样给折叠区**
      // （推理模型把预算花在思考上时，用户至少能看看它想了什么）。
      return SingleChildScrollView(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _hint(
              theme,
              hud,
              Icons.hourglass_empty,
              context.t.aiEmptyAnswer,
              _errorEngine == AiEngineKind.cloud
                  ? context.t.aiCloudEmptyDetail
                  : context.t.aiOnDeviceEmptyDetail,
            ),
            if (_thinkingText.isNotEmpty) _thinkingPanel(theme, hud),
          ],
        ),
      );
    }
    return SingleChildScrollView(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (_kind == AiTaskKind.summary || _kind == AiTaskKind.askBook)
            _bullets(theme, hud, body)
          else
            SelectableText(body, style: theme.textTheme.bodyMedium),
          if (_running) ...[
            const SizedBox(height: Gap.xs),
            Row(
              children: [
                const SizedBox(
                  width: 12,
                  height: 12,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
                const SizedBox(width: Gap.xs),
                Text(
                  context.t.aiGenerating,
                  style: theme.textTheme.labelSmall?.copyWith(color: hud.dim),
                ),
              ],
            ),
          ],
          if (_thinkingText.isNotEmpty) ...[
            const SizedBox(height: Gap.sm),
            _thinkingPanel(theme, hud),
          ],
          if (_retriedBudget > 0) ...[
            const SizedBox(height: Gap.xs),
            Text(
              // 如实告知：推理模型把预算用光了，App 自动加大长度又试了一次
              context.t.aiBudgetRaised(_retriedBudget),
              style: theme.textTheme.labelSmall?.copyWith(color: hud.dim),
            ),
          ],
          if (answer != null && answer.passages.isNotEmpty) ...[
            const SizedBox(height: Gap.sm),
            Text(
              context.t.aiCitedSource,
              style: theme.textTheme.labelSmall?.copyWith(color: hud.dim),
            ),
            const SizedBox(height: Gap.xs),
            for (var i = 0; i < answer.passages.length; i++)
              Padding(
                padding: const EdgeInsets.only(bottom: Gap.xs),
                child: Text(
                  '[${i + 1}] ${answer.passages[i].title}',
                  style: theme.textTheme.bodySmall?.copyWith(color: hud.dim),
                ),
              ),
          ],
          if (answer != null && answer.truncated) ...[
            const SizedBox(height: Gap.xs),
            Text(
              context.t.aiInputTruncated(kAiMaxInputChars),
              style: theme.textTheme.labelSmall?.copyWith(color: hud.danger),
            ),
          ],
        ],
      ),
    );
  }

  /// 「思考过程」折叠区：**默认折叠**、可展开、可复制。
  ///
  /// 推理模型（云端 `reasoning_content` / Claude thinking / Gemini thought，
  /// 端侧 ` thinking`）的思考内容以前只用于诊断（数字数、判断是否被预算截断），
  /// 现在如实给用户看 —— 但**默认折叠**，别让它挡住正文。
  Widget _thinkingPanel(ThemeData theme, DesignPalette hud) {
    final open = _showThinking;
    return Container(
      width: double.infinity,
      decoration: BoxDecoration(
        color: hud.surface,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: hud.line, width: 1),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          InkWell(
            onTap: () => setState(() => _showThinking = !open),
            child: Padding(
              padding: const EdgeInsets.symmetric(
                horizontal: Gap.sm,
                vertical: Gap.xs,
              ),
              child: Row(
                children: [
                  Icon(
                    Icons.psychology_outlined,
                    size: 16,
                    color: theme.colorScheme.primary,
                  ),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      open
                          ? context.t.aiThinkingCollapse
                          : context.t.aiThinkingFold,
                      style: theme.textTheme.labelSmall,
                    ),
                  ),
                  Text(
                    context.t.aiThinkingChars(_thinkingText.characters.length),
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: hud.dim,
                    ),
                  ),
                  const SizedBox(width: 4),
                  Icon(
                    open ? Icons.expand_less : Icons.expand_more,
                    size: 18,
                    color: hud.dim,
                  ),
                ],
              ),
            ),
          ),
          if (open) ...[
            Padding(
              padding: const EdgeInsets.fromLTRB(Gap.sm, 0, Gap.sm, 0),
              child: SelectableText(
                _thinkingText,
                style: theme.textTheme.bodySmall?.copyWith(color: hud.dim),
              ),
            ),
            Align(
              alignment: Alignment.centerRight,
              child: TextButton.icon(
                onPressed: _copyThinking,
                icon: const Icon(Icons.copy_all_outlined, size: 16),
                label: Text(context.t.aiThinkingCopy),
              ),
            ),
          ],
        ],
      ),
    );
  }

  void _copyThinking() {
    final messenger = ScaffoldMessenger.of(context);
    final done = context.t.aiThinkingCopied;
    Clipboard.setData(ClipboardData(text: _thinkingText)).then((_) {
      messenger.showSnackBar(SnackBar(content: Text(done)));
    });
  }

  /// 要点渲染：`- ` 开头的行做项目符号，其余当正文
  Widget _bullets(ThemeData theme, DesignPalette hud, String body) {
    final lines = body
        .split('\n')
        .map((l) => l.trim())
        .where((l) => l.isNotEmpty)
        .toList();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (final l in lines)
          Padding(
            padding: const EdgeInsets.only(bottom: Gap.xs),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (l.startsWith('- ') || l.startsWith('• ')) ...[
                  Text(
                    '•',
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: theme.colorScheme.primary,
                    ),
                  ),
                  const SizedBox(width: Gap.sm),
                ],
                Expanded(
                  child: SelectableText(
                    l.startsWith('- ') || l.startsWith('• ')
                        ? l.substring(2)
                        : l,
                    style: theme.textTheme.bodyMedium,
                  ),
                ),
              ],
            ),
          ),
      ],
    );
  }

  Widget _footer(
    ThemeData theme,
    DesignPalette hud,
    AsyncValue<dynamic> readiness,
    List<String> installed,
  ) {
    return Row(
      children: [
        if (_running)
          TextButton.icon(
            onPressed: _stop,
            icon: const Icon(Icons.stop_circle_outlined, size: 18),
            label: Text(context.t.aiStop),
          )
        else if (_raw.isNotEmpty)
          TextButton.icon(
            onPressed: () {
              final messenger = ScaffoldMessenger.of(context);
              final copied = context.t.fileCopied;
              Clipboard.setData(ClipboardData(text: _raw)).then((_) {
                messenger.showSnackBar(SnackBar(content: Text(copied)));
              });
            },
            icon: const Icon(Icons.copy_all_outlined, size: 18),
            label: Text(context.t.aiCopy),
          ),
        const Spacer(),
        if (_elapsed > 0)
          Text(
            '${(_elapsed / 1000).toStringAsFixed(1)}s',
            style: theme.textTheme.labelSmall?.copyWith(color: hud.dim),
          ),
        if (installed.isEmpty)
          TextButton.icon(
            onPressed: () {
              Navigator.of(context).pop();
              Navigator.of(context).push<void>(
                MaterialPageRoute(builder: (_) => const AiModelPage()),
              );
            },
            icon: const Icon(Icons.download_outlined, size: 18),
            label: Text(context.t.aiInstallOnDeviceModel),
          ),
      ],
    );
  }

  Widget _hint(
    ThemeData theme,
    DesignPalette hud,
    IconData icon,
    String title,
    String detail,
  ) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: Gap.lg),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 20, color: hud.dim),
          const SizedBox(width: Gap.sm),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title, style: theme.textTheme.bodyMedium),
                const SizedBox(height: 2),
                Text(
                  detail,
                  style: theme.textTheme.bodySmall?.copyWith(color: hud.dim),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _Badge extends StatelessWidget {
  const _Badge({required this.icon, required this.text, required this.color});

  final IconData icon;
  final String text;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(right: Gap.xs),
      padding: const EdgeInsets.symmetric(horizontal: Gap.sm, vertical: 3),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: color.withValues(alpha: 0.5)),
      ),
      child: Row(
        children: [
          Icon(icon, size: 12, color: color),
          const SizedBox(width: 4),
          Text(
            text,
            style: Theme.of(
              context,
            ).textTheme.labelSmall?.copyWith(color: color),
          ),
        ],
      ),
    );
  }
}
