// 「后台同步」设置页（第 115 轮，M3 的收尾）。
//
// 官方对应物：`Utils.resumeSyncService/pauseSyncService` 的**用户开关**
// （官方把它放在设置里；DSnote 没有单独的"后台同步"页，开关与账号/同步
// 区域在一起）。我方做成独立小页，入口在笔记列表的溢出菜单，
// 因为原生通道（`NoteSyncPlugin`）本来就是按下述语义提供的：
//
//   * 开关 = `enable()` / `disable()`（原生持久化，**关掉不动数据**）；
//   * 「立即同步」= `syncNow()`（排队一次 WorkManager 单次任务）；
//   * 周期任务状态由原生持有，页面只**读**（`isEnabled`）。
import '../../design/kit/design_kit.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../design/design_palette.dart';
import 'note_background_sync_scheduler.dart';
import 'note_reminder.dart' show noteB;

class NoteBackgroundSyncPage extends ConsumerStatefulWidget {
  const NoteBackgroundSyncPage({super.key});

  @override
  ConsumerState<NoteBackgroundSyncPage> createState() =>
      _NoteBackgroundSyncPageState();
}

class _NoteBackgroundSyncPageState
    extends ConsumerState<NoteBackgroundSyncPage> {
  bool? _enabled;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final enabled = await ref.read(noteBackgroundSyncBridgeProvider).enabled();
    if (!mounted) return;
    setState(() => _enabled = enabled);
  }

  Future<void> _setEnabled(bool value) async {
    setState(() => _busy = true);
    final ok = await ref
        .read(noteBackgroundSyncBridgeProvider)
        .setEnabled(enabled: value);
    if (!mounted) return;
    setState(() {
      _busy = false;
      // 原生确认才改 UI；不确认就保持原值（不假装成功）
      if (ok) _enabled = value;
    });
    if (!ok && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(noteB(kNoteBackgroundSyncFailed, '设置失败'))),
      );
    }
  }

  Future<void> _syncNow() async {
    setState(() => _busy = true);
    final ok = await ref
        .read(noteBackgroundSyncBridgeProvider)
        .syncNow(reason: 'manual');
    if (!mounted) return;
    setState(() => _busy = false);
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          ok
              ? noteB(kNoteBackgroundSyncQueued, '已排队，稍后自动同步')
              : noteB(kNoteBackgroundSyncFailed, '设置失败'),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final hud = DesignPalette.of(context);
    final enabled = _enabled;
    return Scaffold(
      backgroundColor: hud.bg,
      appBar: AppBar(
        title: Text(noteB(kNoteBackgroundSyncTitle, '后台同步')),
      ),
      body: ListView(
        children: [
          DesignSwitchRow(
            key: const Key('note-bg-sync-enable'),
            secondary: Icon(Icons.sync_outlined, color: hud.dim),
            title: Text(noteB(kNoteBackgroundSyncEnable, '允许后台同步')),
            subtitle: Text(
              noteB(
                kNoteBackgroundSyncHint,
                'Android 会每隔一段时间在后台拉取一次笔记改动；'
                    '关掉只停后台，不影响你在 App 里手动同步',
              ),
              style: TextStyle(color: hud.dim),
            ),
            value: enabled ?? false,
            onChanged: (_busy || enabled == null)
                ? null
                : (v) => _setEnabled(v),
          ),
          DesignRowTile(
            key: const Key('note-bg-sync-now'),
            leading: Icon(Icons.play_arrow_outlined, color: hud.dim),
            title: Text(noteB(kNoteBackgroundSyncNow, '立即同步一次')),
            enabled: !_busy,
            onTap: _busy ? null : _syncNow,
          ),
        ],
      ),
    );
  }
}

/// 文案 key（与 ARB 机制一致：缺 key 时回落到中文原文）。
const String kNoteBackgroundSyncTitle = 'noteBackgroundSyncTitle';
const String kNoteBackgroundSyncEnable = 'noteBackgroundSyncEnable';
const String kNoteBackgroundSyncHint = 'noteBackgroundSyncHint';
const String kNoteBackgroundSyncNow = 'noteBackgroundSyncNow';
const String kNoteBackgroundSyncQueued = 'noteBackgroundSyncQueued';
const String kNoteBackgroundSyncFailed = 'noteBackgroundSyncFailed';
