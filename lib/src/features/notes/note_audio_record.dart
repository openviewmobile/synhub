// 笔记录音面板（C4）：`record` 包录音 → 临时 `file_<millis>.3gp` → 作为
// **普通文件附件**交给编辑器（保存时随 `Note/set` multipart 上传）。
//
// 官方 Android `views/AudioRecordingView.java`：
//   * `EXT = ".3gp"`；
//   * 临时文件名 `"file_" + System.currentTimeMillis() + EXT`；
//   * `EditorActivity` 的 "+" 菜单里 `create_attachment_when_audio_recording`
//     与 `create_attachment` 两组入口。
//
// 录音器抽象在 `note_picker.dart`（`NoteAudioRecorder`），测试注入假实现；
// 权限被拒 / 录音失败都只提示、不抛。
import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';

import '../../design/design_palette.dart';
import '../../core/i18n/l10n.dart';
import '../../core/theme/app_tokens.dart';
import 'note_gaps_text.dart';
import 'note_picker.dart';
import '../../core/user_facing_error.dart';

/// 弹录音面板；用户"完成"返回临时文件路径，取消返回 null。
Future<String?> showNoteAudioRecordSheet(BuildContext context, WidgetRef ref) {
  return showModalBottomSheet<String>(
    context: context,
    isDismissible: false,
    enableDrag: false,
    builder: (_) => const _NoteAudioRecordSheet(),
  );
}

class _NoteAudioRecordSheet extends ConsumerStatefulWidget {
  const _NoteAudioRecordSheet();

  @override
  ConsumerState<_NoteAudioRecordSheet> createState() =>
      _NoteAudioRecordSheetState();
}

class _NoteAudioRecordSheetState extends ConsumerState<_NoteAudioRecordSheet> {
  bool _recording = false;
  bool _busy = false;
  String? _path;
  String? _error;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _start());
  }

  Future<void> _start() async {
    final recorder = ref.read(noteAudioRecorderProvider);
    try {
      if (!await recorder.hasPermission()) {
        setState(
          () => _error = noteGaps(
            NoteGapsTextKeys.recordAudioDenied,
            '没有麦克风权限，无法录音',
          ),
        );
        return;
      }
      final dir = await getTemporaryDirectory();
      final path = '${dir.path}/${noteAudioFileName()}';
      await recorder.start(path);
      if (!mounted) return;
      setState(() {
        _recording = true;
        _path = path;
      });
    } catch (e) {
      if (!mounted) return;
      setState(
        () => _error = noteGapsFill(
          NoteGapsTextKeys.recordAudioFailed,
          '录音失败：{error}',
          {'error': userFacingError(e)},
        ),
      );
    }
  }

  Future<void> _stop() async {
    if (_busy) return;
    setState(() => _busy = true);
    final recorder = ref.read(noteAudioRecorderProvider);
    try {
      final path = await recorder.stop();
      if (!mounted) return;
      Navigator.of(context).pop(path);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _error = noteGapsFill(
          NoteGapsTextKeys.recordAudioFailed,
          '录音失败：{error}',
          {'error': userFacingError(e)},
        );
      });
    }
  }

  Future<void> _cancel() async {
    if (_busy) return;
    setState(() => _busy = true);
    final recorder = ref.read(noteAudioRecorderProvider);
    try {
      await recorder.cancel();
    } catch (_) {
      // 取消失败不阻塞关闭
    }
    if (!mounted) return;
    Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final hud = DesignPalette.of(context);
    return SafeArea(
      // 显式收宽度：底部面板在窄屏/测试里可能拿到未定宽约束，
      // 不夹一下按钮行会拿到无限宽（layout 断言）。
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 400),
          child: Padding(
            padding: const EdgeInsets.all(Gap.lg),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  _recording ? Icons.fiber_manual_record : Icons.mic_none,
                  color: _recording ? Colors.red : hud.dim,
                  size: 40,
                ),
                const SizedBox(height: Gap.md),
                Text(
                  _error ??
                      (_recording
                          ? noteGaps(
                              NoteGapsTextKeys.recordAudioStart,
                              '正在录音…',
                            )
                          : noteGaps(NoteGapsTextKeys.recordAudio, '录音')),
                  key: const Key('note-audio-record-status'),
                  textAlign: TextAlign.center,
                ),
                if (_path != null) ...[
                  const SizedBox(height: Gap.xs),
                  Text(
                    _path!.split(Platform.pathSeparator).last,
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ],
                const SizedBox(height: Gap.lg),
                // 主题给 FilledButton 设了 `minimumSize: Size.fromHeight(48)`
                // （全宽按钮约定），放进 Row 会拿到无限宽 → 这里竖排。
                FilledButton(
                  key: const Key('note-audio-record-stop'),
                  onPressed: _busy || !_recording ? null : _stop,
                  child: Text(noteGaps(NoteGapsTextKeys.recordAudioStop, '完成')),
                ),
                const SizedBox(height: Gap.sm),
                TextButton(
                  key: const Key('note-audio-record-cancel'),
                  onPressed: _busy ? null : _cancel,
                  child: Text(context.t.actionCancel),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
