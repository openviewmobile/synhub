// 下载进度框 —— 对齐原版 `ui/fragment/DownloadFragment.java`。
//
// 原版行为（`fragment_download.xml` + `DownloadFragment`）：
//   * `AlertDialog`，标题 `R.string.downloading`（"正在下载…"），内容 = 文件名 +
//     `ProgressBar` + `已下载 / 总大小` + 百分比；正按钮 = 取消
//     （`presenter.cancel("download")`）；
//   * `showProgress(read, total)`：**total == 0 → 进度条转圈、隐藏字节数与百分比**
//     （服务端没给 Content-Length 的情形），否则 `read / total` +
//     `(read*100)/total` 取整百分比；
//   * 下载完成后按 option 分派：打开 / 存到公共下载目录 / 分享 / 当纯文本打开；
//   * 取消/失败 → `dismiss()`，失败再弹 `ErrorUtil.showError`。
//
// 我们这里只做"进度 + 取消"这一块（打开/另存/分享在附件长按菜单里），
// 用 [DownloadTask] 承载进度与取消句柄，测试里可以直接驱动它。
import 'dart:async';

import 'package:flutter/material.dart';

import '../../core/i18n/l10n.dart';
import '../../core/media/cache_service.dart' show humanBytes;
import '../../dsm/webapi.dart';
import '../../core/user_facing_error.dart';

/// 一次下载的进度与取消句柄
class DownloadTask {
  DownloadTask(this.filename);

  final String filename;

  final DownloadCancelToken cancelToken = DownloadCancelToken();

  /// (已下载字节, 总字节)；total == 0 表示服务端没给长度 → 转圈
  final ValueNotifier<({int received, int total})> progress = ValueNotifier((
    received: 0,
    total: 0,
  ));

  bool get isCancelled => cancelToken.isCancelled;

  /// `onProgress` 回调（dio 会给 total = -1 表示未知，归一到 0）
  void report(int received, int total) {
    if (progress.value.received == received && progress.value.total == total) {
      return;
    }
    progress.value = (received: received, total: total < 0 ? 0 : total);
  }

  void cancel() => cancelToken.cancel();

  void dispose() => progress.dispose();

  /// 百分比（0–100，取整；total == 0 → 0）
  int get percent {
    final p = progress.value;
    if (p.total <= 0) return 0;
    final v = (p.received * 100) ~/ p.total;
    return v.clamp(0, 100);
  }

  /// 原版用的是 `FileUtils.byteCountToDisplaySize`（1024 进制 + 3 位有效数字）
  String get humanReadable {
    final p = progress.value;
    if (p.total <= 0) return '';
    return '${humanBytes(p.received)} / ${humanBytes(p.total)}';
  }
}

/// 进度框本体（无状态、纯展示；进度/取消都在 [task] 上）
class DownloadProgressDialog extends StatelessWidget {
  const DownloadProgressDialog({super.key, required this.task});

  final DownloadTask task;

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(context.t.chatDownloading),
      content: ValueListenableBuilder<({int received, int total})>(
        valueListenable: task.progress,
        builder: (context, p, _) {
          final unknown = p.total <= 0;
          return Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(task.filename, maxLines: 2, overflow: TextOverflow.ellipsis),
              const SizedBox(height: 16),
              LinearProgressIndicator(
                value: unknown ? null : task.percent / 100,
              ),
              if (!unknown) ...[
                const SizedBox(height: 8),
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text(
                      task.humanReadable,
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                    Text(
                      '${task.percent}%',
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  ],
                ),
              ],
            ],
          );
        },
      ),
      actions: [
        TextButton(
          onPressed: () {
            task.cancel();
            Navigator.of(context).pop();
          },
          child: Text(context.t.actionCancel),
        ),
      ],
    );
  }
}

/// 下载失败：带着给用户看的文案（`runWithDownloadDialog` 原样返回它）
class DownloadFailedException implements Exception {
  const DownloadFailedException(this.message);

  final String message;

  @override
  String toString() => 'DownloadFailedException($message)';
}

/// 用户取消下载的哨兵（调用方静默关闭，不弹错误 —— 对齐原版 `cancel()`）
const String kDownloadCancelled = '__cancelled__';

/// 弹下载框 → 跑 [run]（用 [DownloadTask] 的 token 与进度）→ 关框。
///
/// 返回 null 表示成功，[kDownloadCancelled] 表示用户取消，其它为错误文案。
Future<String?> runWithDownloadDialog(
  BuildContext context,
  Future<void> Function(DownloadTask task) run, {
  required String filename,
}) async {
  final t = context.t;
  final task = DownloadTask(filename);
  final navigator = Navigator.of(context, rootNavigator: true);
  // 用显式 route 而不是 showDialog()：取消按钮会自己 pop，
  // `canPop()` 那时已经指向下面的页面，直接 pop 会把页面也关掉。
  final route = DialogRoute<void>(
    context: context,
    barrierDismissible: false,
    builder: (_) => DownloadProgressDialog(task: task),
  );
  unawaited(navigator.push(route));
  try {
    await run(task);
    return null;
  } on DownloadCancelledException {
    return kDownloadCancelled;
  } on DownloadFailedException catch (e) {
    return e.message;
  } catch (e) {
    return t.chatErrDownloadFailed(userFacingError(e));
  } finally {
    if (route.isActive) navigator.removeRoute(route);
    task.dispose();
  }
}
