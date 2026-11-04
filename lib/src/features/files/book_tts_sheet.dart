// 「朗读」弹层（E2 听书）：播放/暂停/继续/停止 + 按段落推进。
//
// 状态机在 `book_tts.dart`（纯 Dart、可单测）；这里只做界面。
// 引擎走 `ttsEngineProvider`，测试里覆盖成假引擎 —— 所以**离线也能验整条 UI**，
// 不会真的出声。
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../design/design_palette.dart';
import '../../core/i18n/l10n.dart';
import '../../core/theme/app_tokens.dart';
import 'book_providers.dart';
import 'book_tts.dart';

/// 打开朗读弹层（[paragraphs] 是切好的段落；空的话给明确提示）
Future<void> showBookTtsSheet(
  BuildContext context, {
  required String title,
  required List<String> paragraphs,
}) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    builder: (_) => BookTtsSheet(title: title, paragraphs: paragraphs),
  );
}

class BookTtsSheet extends ConsumerStatefulWidget {
  const BookTtsSheet({
    super.key,
    required this.title,
    required this.paragraphs,
  });

  final String title;
  final List<String> paragraphs;

  @override
  ConsumerState<BookTtsSheet> createState() => _BookTtsSheetState();
}

class _BookTtsSheetState extends ConsumerState<BookTtsSheet> {
  late final TtsController _ctl;
  Object? _error;

  @override
  void initState() {
    super.initState();
    _ctl = TtsController(
      engine: ref.read(ttsEngineProvider),
      paragraphs: widget.paragraphs,
      onChanged: () {
        if (mounted) setState(() {});
      },
      onError: (e) {
        if (mounted) setState(() => _error = e);
      },
    );
    // ★ DA200：进弹层就先问一次引擎（真机没装 TTS ⇒ 按钮点了只会弹红字）
    _probeEngine();
  }

  /// 引擎是否可用；`null` = 还没探测完（这期间按钮仍可点，避免闪灰）
  bool? _engineAvailable;

  Future<void> _probeEngine() async {
    final sample = widget.paragraphs.isEmpty ? '' : widget.paragraphs.first;
    bool ok;
    try {
      ok = await ref.read(ttsEngineProvider).availableFor(sample);
    } catch (_) {
      ok = false;
    }
    if (mounted) setState(() => _engineAvailable = ok);
  }

  @override
  void dispose() {
    // 关掉弹层就停声：不然用户退出阅读页还在念
    _ctl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    final theme = Theme.of(context);
    final hud = DesignPalette.of(context);
    final empty = widget.paragraphs.isEmpty;
    final playing = _ctl.state == TtsPlaybackState.playing;
    final paused = _ctl.state == TtsPlaybackState.paused;

    return SafeArea(
      child: SingleChildScrollView(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(Gap.md, Gap.sm, Gap.md, Gap.md),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Icon(
                    Icons.volume_up_outlined,
                    size: 18,
                    color: theme.colorScheme.primary,
                  ),
                  const SizedBox(width: Gap.sm),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          t.bookTtsTitle,
                          style: theme.textTheme.titleMedium,
                        ),
                        Text(
                          widget.title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: hud.dim,
                          ),
                        ),
                      ],
                    ),
                  ),
                  IconButton(
                    tooltip: t.photoClose,
                    icon: const Icon(Icons.close, size: 18),
                    onPressed: () => Navigator.of(context).pop(),
                  ),
                ],
              ),
              const SizedBox(height: Gap.xs),
              if (empty)
                Text(
                  t.bookTtsUnsupported,
                  key: const Key('book-tts-empty'),
                  style: theme.textTheme.bodySmall?.copyWith(color: hud.dim),
                )
              else ...[
                Text(
                  t.bookTtsState(_ctl.index + 1, _ctl.count),
                  key: const Key('book-tts-state'),
                  style: theme.textTheme.labelSmall?.copyWith(color: hud.dim),
                ),
                const SizedBox(height: Gap.sm),
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(Gap.sm),
                  decoration: BoxDecoration(
                    color: hud.surface2,
                    borderRadius: BorderRadius.circular(10),
                    border: Border.all(color: hud.line),
                  ),
                  child: Text(
                    _ctl.currentText,
                    maxLines: 5,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodyMedium,
                  ),
                ),
                const SizedBox(height: Gap.md),
                Row(
                  children: [
                    IconButton(
                      key: const Key('book-tts-prev'),
                      tooltip: t.bookTtsPrev,
                      onPressed: () => _ctl.previous(),
                      icon: const Icon(Icons.skip_previous),
                    ),
                    if (playing)
                      FilledButton.icon(
                        key: const Key('book-tts-pause'),
                        // ⚠️ 主题里 FilledButton 的 minimumSize 是
                        // `Size.fromHeight(48)`（整行宽），放进 Row 必须覆盖，
                        // 否则 BoxConstraints 里宽度是 ∞ 直接崩布局
                        style: FilledButton.styleFrom(
                          minimumSize: const Size(0, 40),
                          padding: const EdgeInsets.symmetric(
                            horizontal: Gap.sm,
                          ),
                        ),
                        onPressed: () => _ctl.pause(),
                        icon: const Icon(Icons.pause, size: 18),
                        label: Text(t.bookTtsPause),
                      )
                    else
                      FilledButton.icon(
                        key: const Key('book-tts-play'),
                        style: FilledButton.styleFrom(
                          minimumSize: const Size(0, 40),
                          padding: const EdgeInsets.symmetric(
                            horizontal: Gap.sm,
                          ),
                        ),
                        // ★ DA200：引擎不可用就别给能点的按钮（点了必然失败）
                        onPressed: _engineAvailable == false
                            ? null
                            : () => _ctl.play(),
                        icon: const Icon(Icons.play_arrow, size: 18),
                        label: Text(
                          paused ? t.bookTtsResume : t.bookTtsReadAloud,
                        ),
                      ),
                    const SizedBox(width: Gap.sm),
                    IconButton(
                      key: const Key('book-tts-stop'),
                      tooltip: t.bookTtsStop,
                      onPressed: _ctl.isActive ? () => _ctl.stop() : null,
                      icon: const Icon(Icons.stop),
                    ),
                    IconButton(
                      key: const Key('book-tts-next'),
                      tooltip: t.bookTtsNext,
                      onPressed: () => _ctl.next(),
                      icon: const Icon(Icons.skip_next),
                    ),
                  ],
                ),
                if (_engineAvailable == false)
                  Text(
                    // 进层就说清楚，而不是让用户点一次才知道（DA200）
                    t.bookTtsUnsupported,
                    key: const Key('book-tts-no-engine'),
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: theme.colorScheme.error,
                    ),
                  )
                else if (!_ctl.isActive)
                  Text(
                    t.bookTtsIdle,
                    style: theme.textTheme.labelSmall?.copyWith(color: hud.dim),
                  )
                else if (paused)
                  Text(
                    t.bookTtsResumeHint,
                    style: theme.textTheme.labelSmall?.copyWith(color: hud.dim),
                  ),
                if (_error != null) ...[
                  const SizedBox(height: Gap.xs),
                  Text(
                    // 引擎不可用是"设备/系统没装 TTS"，不是朗读过程出错 ——
                    // 用一句用户能懂的话，别把内部哨兵直接甩出去
                    '$_error' == kTtsEngineUnavailable
                        ? t.bookTtsUnsupported
                        : t.bookTtsFailed('$_error'),
                    key: const Key('book-tts-error'),
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.error,
                    ),
                  ),
                ],
              ],
            ],
          ),
        ),
      ),
    );
  }
}
