// 「从 NAS 选图片」：一个只列图片的简易文件浏览（复用 FileStation 接口）。
//
// 官方 DS note 只有"从本机选"；我们多给了 NAS 来源 —— 因为 P0 已经有文件浏览，
// 而"把 NAS 上的图插进笔记"是这套 Client Station 该有的顺手能力。
import '../../design/kit/design_kit.dart';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';

import '../../design/design_palette.dart';
import '../../core/i18n/l10n.dart';
import '../../core/media/cache_service.dart' show humanBytes;
import '../../core/theme/app_tokens.dart';
import '../../data/dto/file_entry_dto.dart';
import '../files/file_providers.dart';
import 'note_picker.dart';
import '../../core/user_facing_error.dart';

const _imageExts = {
  'jpg',
  'jpeg',
  'png',
  'gif',
  'bmp',
  'webp',
  'heic',
  'heif',
  'tif',
  'tiff',
};

bool _isImage(String name) {
  final i = name.lastIndexOf('.');
  if (i < 0) return false;
  return _imageExts.contains(name.substring(i + 1).toLowerCase());
}

/// 打开 NAS 图片选择器；返回选好的图（已下载到临时目录）。
Future<List<NotePickedImage>> pickNasImages(
  BuildContext context,
  WidgetRef ref,
) async {
  final picked = await Navigator.of(context, rootNavigator: true)
      .push<List<FileEntryDto>>(
        MaterialPageRoute(builder: (_) => const _NasImagePickerPage()),
      );
  if (picked == null || picked.isEmpty) return const [];

  final api = ref.read(fileApiProvider);
  if (api == null) return const [];
  final dir = await getTemporaryDirectory();
  final out = <NotePickedImage>[];
  for (final entry in picked) {
    try {
      final bytes = await api.api.getBytes(api.downloadUrl([entry.path]));
      final file = File('${dir.path}/note-nas-${entry.name}');
      await file.writeAsBytes(bytes, flush: true);
      out.add(NotePickedImage(path: file.path, name: entry.name));
    } catch (_) {
      // 单张失败不影响其它（界面上会少一张）
    }
  }
  return out;
}

class _NasImagePickerPage extends ConsumerStatefulWidget {
  const _NasImagePickerPage();

  @override
  ConsumerState<_NasImagePickerPage> createState() =>
      _NasImagePickerPageState();
}

class _NasImagePickerPageState extends ConsumerState<_NasImagePickerPage> {
  String _path = '/home';
  bool _loading = true;
  String? _error;
  List<FileEntryDto> _entries = const [];
  final Set<String> _selected = {};

  @override
  void initState() {
    super.initState();
    _load(_path);
  }

  Future<void> _load(String path) async {
    final api = ref.read(fileApiProvider);
    if (api == null) {
      setState(() {
        _loading = false;
        _error = context.t.setNotConnected;
      });
      return;
    }
    setState(() {
      _loading = true;
      _error = null;
      _path = path;
    });
    try {
      final result = await api.listFolder(folderPath: path);
      if (!mounted) return;
      setState(() {
        _entries = result.entries;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = userFacingError(e);
        _loading = false;
      });
    }
  }

  void _enter(FileEntryDto dir) => _load(dir.path);

  void _up() {
    if (_path == '/' || _path.isEmpty) return;
    final i = _path.lastIndexOf('/');
    _load(i <= 0 ? '/' : _path.substring(0, i));
  }

  @override
  Widget build(BuildContext context) {
    final hud = DesignPalette.of(context);
    final dirs = _entries.where((e) => e.isDir).toList();
    final images = _entries.where((e) => !e.isDir && _isImage(e.name)).toList();
    final rows = [...dirs, ...images];
    return Scaffold(
      backgroundColor: hud.bg,
      appBar: AppBar(
        title: Text(context.t.noteFromNas),
        actions: [
          TextButton(
            onPressed: _selected.isEmpty
                ? null
                : () => Navigator.of(context).pop([
                    for (final e in images)
                      if (_selected.contains(e.path)) e,
                  ]),
            child: Text(
              _selected.isEmpty
                  ? context.t.noteInsert
                  : context.t.noteInsertCount(_selected.length),
            ),
          ),
        ],
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(Gap.md, Gap.sm, Gap.md, Gap.sm),
            child: Row(
              children: [
                IconButton(
                  tooltip: context.t.noteUpOneLevel,
                  icon: const Icon(Icons.arrow_upward),
                  onPressed: _up,
                ),
                Expanded(
                  child: Text(
                    _path,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(
                      context,
                    ).textTheme.bodySmall?.copyWith(color: hud.dim),
                  ),
                ),
              ],
            ),
          ),
          const Divider(height: 1),
          Expanded(child: _list(context, hud, rows, images)),
        ],
      ),
    );
  }

  Widget _list(
    BuildContext context,
    DesignPalette hud,
    List<FileEntryDto> rows,
    List<FileEntryDto> images,
  ) {
    if (_loading) return const Center(child: CircularProgressIndicator());
    if (_error != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(Gap.xl),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                context.t.noteFolderOpenFailed('$_error'),
                textAlign: TextAlign.center,
                style: TextStyle(color: hud.dim),
              ),
              const SizedBox(height: Gap.md),
              FilledButton(
                onPressed: () => _load(_path),
                child: Text(context.t.photoRetry),
              ),
            ],
          ),
        ),
      );
    }
    if (rows.isEmpty) {
      return Center(
        child: Text(
          context.t.noteNoImagesHere,
          style: TextStyle(color: hud.dim),
        ),
      );
    }
    return ListView.separated(
      itemCount: rows.length,
      separatorBuilder: (_, _) => const Divider(height: 1, indent: Gap.lg),
      itemBuilder: (context, i) {
        final e = rows[i];
        if (e.isDir) {
          return DesignRowTile(
            leading: Icon(Icons.folder_outlined, color: hud.dim),
            title: Text(e.name),
            onTap: () => _enter(e),
          );
        }
        final checked = _selected.contains(e.path);
        final index = images.indexOf(e) + 1;
        return DesignRowTile(
          leading: Icon(
            checked ? Icons.check_circle : Icons.image_outlined,
            color: checked ? Theme.of(context).colorScheme.primary : hud.dim,
          ),
          title: Text(e.name),
          subtitle: Text(
            humanBytes(e.size),
            style: TextStyle(color: hud.dim, fontSize: 11),
          ),
          onTap: () => setState(() {
            if (checked) {
              _selected.remove(e.path);
            } else {
              _selected.add(e.path);
            }
          }),
          trailing: checked ? Text('#$index') : null,
        );
      },
    );
  }
}
