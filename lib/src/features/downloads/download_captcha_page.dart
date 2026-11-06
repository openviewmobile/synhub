// Download Station「输入验证码」页（wave5）。
//
// 事实来源（**包内官方前端 `ui/download.js` 的 `DLM.CaptchaEnterDialog`
// 逐字 + 真机只读探针**，见 `download_station.dart` 的 Captcha 段）：
//   * `Captcha:list` v2 → `data.task_ids`（**需要验证码的任务**）；
//   * 逐个任务 `Captcha:download {task_id, t}` 取**验证码图片**（GET 直链）；
//   * `Captcha:set {task_id, code}` 提交；失败 `2301` = 验证码不正确；
//   * 提交成功 → 官方 `setCaptchaResultCallback` 立刻读下一个（`onSubmit()`）。
//
// 硬约束：
//   * **内部 id 绝不上屏**：`task_id` 只进 Key / provider family / 请求参数；
//   * **不静默失败**：提交失败**必须**显示原因（2301 给"验证码不正确"），
//     取图失败给"验证码图片加载失败"，都不许装成空态；
//   * 门控：能力表里没有 `SYNO.DownloadStation2.Captcha` 时，
//     `download_page.dart` 根本不给入口（本页兜底显示"本机不支持"）。
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../design/kit/design_kit.dart';
import '../../core/i18n/data_text.dart';
import '../../core/theme/app_tokens.dart';
import '../../core/ui/app_states.dart';
import '../../data/download_station.dart';
import 'download_providers.dart';

class DownloadCaptchaPage extends ConsumerStatefulWidget {
  const DownloadCaptchaPage({super.key});

  @override
  ConsumerState<DownloadCaptchaPage> createState() =>
      _DownloadCaptchaPageState();
}

class _DownloadCaptchaPageState extends ConsumerState<DownloadCaptchaPage> {
  final _code = TextEditingController();

  /// 下一个待处理任务的**下标**（不是 id；id 不上屏也不进状态）。
  int _index = 0;

  /// 图片防缓存值：提交失败后换一张新图，必须变。
  int _cacheBuster = 0;

  bool _submitting = false;
  String? _errorText;

  @override
  void dispose() {
    _code.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final async = ref.watch(downloadCaptchaProvider);
    // ★★ DA81：这里**不再**只认 `Captcha:list` —— 与入口条共用
    //   `captchaPendingIds()`。否则入口靠"任务状态 15"兜底出现时，
    //   点进来会看到"没有需要验证码的任务"（真机复现过）。
    final ids = captchaPendingIds(
      async.value ?? const <String>[],
      ref.watch(downloadListProvider).items,
    );
    return DesignScaffold(
      appBar: AppBar(title: Text(dataText('dsCaptchaTitle', '输入验证码'))),
      body: ids.isEmpty
          ? async.when(
              loading: () => const AppListSkeleton(rows: 4),
              // 取不到列表：**不装成空态**，给明确原因 + 重试。
              error: (e, _) => AppErrorView(
                key: const Key('ds-captcha-load-error'),
                title: dataText('dsCaptchaLoadFailed', '验证码任务读取失败'),
                detail: describeDownloadError(e),
                onRetry: () => ref.invalidate(downloadCaptchaProvider),
              ),
              data: (_) => AppEmptyState(
                key: const Key('ds-captcha-none'),
                icon: Icons.verified_outlined,
                title: dataText('dsCaptchaNoneTitle', '没有需要验证码的任务'),
                message: dataText(
                  'dsCaptchaNoneMessage',
                  '需要验证码的任务都已经处理完了。',
                ),
              ),
            )
          : _body(context, ids, _index.clamp(0, ids.length - 1)),
    );
  }

  Widget _body(BuildContext context, List<String> ids, int index) {
    final taskId = ids[index];
    final image = ref.watch(
      downloadCaptchaImageProvider((taskId, '$_cacheBuster')),
    );
    return ListView(
      padding: const EdgeInsets.all(Gap.lg),
      children: [
        Text(
          // 只报"第几个"，不报 id。
          dataText('dsCaptchaProgress', '第 {cur}/{total} 个')
              .replaceAll('{cur}', '${index + 1}')
              .replaceAll('{total}', '${ids.length}'),
          style: Theme.of(context).textTheme.bodySmall,
        ),
        const SizedBox(height: Gap.md),
        Text(
          dataText(
            'dsCaptchaHint',
            '这台 NAS 要求输入验证码才能继续这个下载任务，请输入图片里的字符。',
          ),
        ),
        const SizedBox(height: Gap.md),
        Center(
          child: image.when(
            loading: () => const SizedBox(
              height: 72,
              child: Center(child: CircularProgressIndicator()),
            ),
            // 真机取图失败是 HTTP 404 + HTML ⇒ 明确提示，不留空白。
            error: (e, _) => Text(
              dataText('dsCaptchaImageFailed', '验证码图片加载失败，请重试'),
            ),
            data: (bytes) => bytes == null
                ? Column(
                    key: const Key('ds-captcha-image-failed'),
                    children: [
                      Text(
                        dataText('dsCaptchaImageFailed', '验证码图片加载失败，请重试'),
                      ),
                      TextButton(
                        key: const Key('ds-captcha-image-retry'),
                        onPressed: () => setState(() => _cacheBuster++),
                        child: Text(dataText('dsCaptchaRetryImage', '重新加载图片')),
                      ),
                    ],
                  )
                : Image.memory(
                    bytes,
                    key: const Key('ds-captcha-image'),
                    height: 72,
                    fit: BoxFit.contain,
                  ),
          ),
        ),
        const SizedBox(height: Gap.lg),
        TextField(
          key: const Key('ds-captcha-code'),
          controller: _code,
          autofocus: true,
          enabled: !_submitting,
          textInputAction: TextInputAction.done,
          onSubmitted: (_) => _submit(taskId),
          decoration: InputDecoration(
            labelText: dataText('dsCaptchaCodeLabel', '验证码'),
            border: const OutlineInputBorder(),
            errorText: _errorText,
          ),
        ),
        const SizedBox(height: Gap.lg),
        FilledButton(
          key: const Key('ds-captcha-submit'),
          onPressed: _submitting ? null : () => _submit(taskId),
          child: _submitting
              ? const SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : Text(dataText('dsCaptchaSubmit', '提交')),
        ),
        const SizedBox(height: Gap.sm),
        TextButton(
          key: const Key('ds-captcha-skip'),
          onPressed: _submitting ? null : () => _advance(ids),
          child: Text(dataText('dsCaptchaSkip', '跳过这个任务')),
        ),
      ],
    );
  }

  Future<void> _submit(String taskId) async {
    final messenger = ScaffoldMessenger.of(context);
    final code = _code.text.trim();
    if (code.isEmpty) {
      setState(() {
        _errorText = dataText('dsCaptchaCodeRequired', '请输入验证码');
      });
      return;
    }
    setState(() {
      _submitting = true;
      _errorText = null;
    });
    try {
      await ref
          .read(downloadActionsProvider)
          .submitCaptcha(taskId: taskId, code: code);
      if (!mounted) return;
      messenger.showSnackBar(
        SnackBar(content: Text(dataText('dsCaptchaAccepted', '验证码已提交'))),
      );
      _advance(
        // ★ DA81：提交后用**同一个判据**算"还有哪些待处理"。
        captchaPendingIds(
          ref.read(downloadCaptchaProvider).value ?? const <String>[],
          ref.read(downloadListProvider).items,
        ),
      );
    } catch (e) {
      if (!mounted) return;
      // 失败**必须**可见：2301 走 describeDownloadError 的"验证码不正确"。
      setState(() {
        _submitting = false;
        _errorText = describeDownloadError(e);
        // 换一张新图（官方提交失败后也会给下一张）。
        _cacheBuster++;
      });
    }
  }

  /// 处理下一个任务；全部处理完就关页（返回 true 让任务列表刷新）。
  void _advance(List<String> ids) {
    final next = _index + 1;
    if (next >= ids.length) {
      Navigator.of(context).pop(true);
      return;
    }
    setState(() {
      _index = next;
      _submitting = false;
      _errorText = null;
      _code.clear();
      _cacheBuster++;
    });
  }
}
