// ⑥下载 F3：**eMule 搜索页**（`SYNO.DownloadStation2.eMule.Search` v1）。
//
// 界面字段逐字对齐官方 `AdvancedSearchPanel`：
// * 关键字（必填）；
// * 搜索方式 `local|global|kad`（默认 local；**kad 关键字太短会被客户端挡下**）；
// * 文件类型 `any|audio|video|image|doc|prog|archive|iso`（默认 any）；
// * 最小/最大大小（MB）、最小来源数、扩展名 —— **填了才发**。
// 结果多选后「下载选中」＝官方 `actionDownload`（`file_id:[…]`）。
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../design/kit/design_kit.dart';
import '../../core/i18n/data_text.dart';
import '../../core/theme/app_tokens.dart';
import '../../data/dto/download_task_dto.dart';
import '../analytics/analytics_track.dart';
import '../analytics/usage_event.dart';
import 'download_emule_search_providers.dart';

const _searchTypes = ['local', 'global', 'kad'];
const _fileTypes = [
  'any',
  'audio',
  'video',
  'image',
  'doc',
  'prog',
  'archive',
  'iso',
];

class DownloadEmuleSearchPage extends ConsumerStatefulWidget {
  const DownloadEmuleSearchPage({super.key});

  @override
  ConsumerState<DownloadEmuleSearchPage> createState() =>
      _DownloadEmuleSearchPageState();
}

class _DownloadEmuleSearchPageState
    extends ConsumerState<DownloadEmuleSearchPage> {
  final _keyword = TextEditingController();
  final _minSize = TextEditingController();
  final _maxSize = TextEditingController();
  final _minSource = TextEditingController();
  final _extension = TextEditingController();
  String _type = 'local';
  String _fileType = 'any';

  @override
  void dispose() {
    _keyword.dispose();
    _minSize.dispose();
    _maxSize.dispose();
    _minSource.dispose();
    _extension.dispose();
    super.dispose();
  }

  int? _intOf(TextEditingController c) => int.tryParse(c.text.trim());

  Future<void> _runSearch() async {
    await ref
        .read(emuleSearchProvider.notifier)
        .search(
          keyword: _keyword.text,
          searchType: _type,
          fileType: _fileType,
          fileSizeMin: _intOf(_minSize),
          fileSizeMax: _intOf(_maxSize),
          sourceNumMin: _intOf(_minSource),
          fileExtension: _extension.text,
        );
    if (!mounted) return;
    final s = ref.read(emuleSearchProvider);
    if (s.errorText == null) {
      trackOnce(
        UsageModule.downloads,
        UsageAction.search,
        objectType: 'emule',
        value: s.results.length,
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final s = ref.watch(emuleSearchProvider);
    return DesignScaffold(
      appBar: AppBar(
        title: Text(dataText('dsEmuleSearch', 'eMule 搜索')),
        leading: IconButton(
          key: const Key('ds-emule-search-back'),
          tooltip: dataText('dsBack', '返回'),
          icon: const Icon(Icons.arrow_back),
          onPressed: () {
            // 主动离开 = 停会话（官方 onBeforeClose 同款）。
            ref.read(emuleSearchProvider.notifier).stop();
            Navigator.of(context, rootNavigator: true).maybePop();
          },
        ),
        actions: [
          if (s.selected.isNotEmpty)
            TextButton(
              key: const Key('ds-emule-search-download'),
              onPressed: () async {
                final ok = await ref
                    .read(emuleSearchProvider.notifier)
                    .downloadSelected();
                if (ok && context.mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(
                      content: Text(dataText('dsEmuleAdded', '已创建下载任务')),
                    ),
                  );
                  ref.read(emuleSearchProvider.notifier).clearSelection();
                }
              },
              child: Text(
                '${dataText('dsEmuleDownloadN', '下载选中')} '
                '(${s.selected.length})',
              ),
            ),
        ],
      ),
      body: Column(
        children: [
          _SearchForm(
            keyword: _keyword,
            minSize: _minSize,
            maxSize: _maxSize,
            minSource: _minSource,
            extension: _extension,
            type: _type,
            fileType: _fileType,
            onType: (v) => setState(() => _type = v),
            onFileType: (v) => setState(() => _fileType = v),
            onSubmit: _runSearch,
          ),
          if (s.running)
            const Padding(
              padding: EdgeInsets.symmetric(horizontal: Gap.lg),
              child: LinearProgressIndicator(),
            ),
          if (s.errorText != null)
            Padding(
              padding: const EdgeInsets.all(Gap.lg),
              child: Text(
                s.errorText!,
                key: const Key('ds-emule-search-error'),
              ),
            ),
          Expanded(
            child: !s.running && s.done && s.results.isEmpty && s.errorText == null
                ? Center(
                    child: Text(
                      dataText('dsEmuleNoResult', '没有找到结果'),
                      key: const Key('ds-emule-search-empty'),
                    ),
                  )
                : ListView.builder(
                    itemCount: s.results.length,
                    itemBuilder: (context, i) {
                      final r = s.results[i];
                      return _ResultTile(
                        index: i,
                        result: r,
                        checked: s.selected.contains(r.fileId),
                        onToggle: () =>
                            ref.read(emuleSearchProvider.notifier).toggle(r.fileId),
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }
}

class _SearchForm extends StatelessWidget {
  const _SearchForm({
    required this.keyword,
    required this.minSize,
    required this.maxSize,
    required this.minSource,
    required this.extension,
    required this.type,
    required this.fileType,
    required this.onType,
    required this.onFileType,
    required this.onSubmit,
  });

  final TextEditingController keyword;
  final TextEditingController minSize;
  final TextEditingController maxSize;
  final TextEditingController minSource;
  final TextEditingController extension;
  final String type;
  final String fileType;
  final ValueChanged<String> onType;
  final ValueChanged<String> onFileType;
  final Future<void> Function() onSubmit;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(Gap.lg, Gap.md, Gap.lg, Gap.sm),
      child: Column(
        children: [
          TextField(
            key: const Key('ds-emule-search-keyword'),
            controller: keyword,
            decoration: InputDecoration(
              labelText: dataText('dsEmuleKeyword', '关键字'),
            ),
            onSubmitted: (_) => onSubmit(),
          ),
          const SizedBox(height: Gap.sm),
          Row(
            children: [
              Expanded(
                child: DropdownButtonFormField<String>(
                  isExpanded: true,
                  key: const Key('ds-emule-search-type'),
                  initialValue: type,
                  decoration: InputDecoration(
                    labelText: dataText('dsEmuleMethod', '搜索方式'),
                  ),
                  items: [
                    for (final v in _searchTypes)
                      DropdownMenuItem(value: v, child: Text(v)),
                  ],
                  onChanged: (v) => onType(v ?? 'local'),
                ),
              ),
              const SizedBox(width: Gap.sm),
              Expanded(
                child: DropdownButtonFormField<String>(
                  isExpanded: true,
                  key: const Key('ds-emule-search-filetype'),
                  initialValue: fileType,
                  decoration: InputDecoration(
                    labelText: dataText('dsEmuleFileType', '文件类型'),
                  ),
                  items: [
                    for (final v in _fileTypes)
                      DropdownMenuItem(value: v, child: Text(v)),
                  ],
                  onChanged: (v) => onFileType(v ?? 'any'),
                ),
              ),
            ],
          ),
          const SizedBox(height: Gap.sm),
          Row(
            children: [
              Expanded(
                child: TextField(
                  key: const Key('ds-emule-search-min'),
                  controller: minSize,
                  keyboardType: TextInputType.number,
                  decoration: InputDecoration(
                    labelText: dataText('dsEmuleMinSize', '最小大小(MB)'),
                  ),
                ),
              ),
              const SizedBox(width: Gap.sm),
              Expanded(
                child: TextField(
                  key: const Key('ds-emule-search-max'),
                  controller: maxSize,
                  keyboardType: TextInputType.number,
                  decoration: InputDecoration(
                    labelText: dataText('dsEmuleMaxSize', '最大大小(MB)'),
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: Gap.sm),
          Row(
            children: [
              Expanded(
                child: TextField(
                  key: const Key('ds-emule-search-source'),
                  controller: minSource,
                  keyboardType: TextInputType.number,
                  decoration: InputDecoration(
                    labelText: dataText('dsEmuleMinSource', '最小来源数'),
                  ),
                ),
              ),
              const SizedBox(width: Gap.sm),
              Expanded(
                child: TextField(
                  key: const Key('ds-emule-search-extension'),
                  controller: extension,
                  decoration: InputDecoration(
                    labelText: dataText('dsEmuleExtension', '扩展名'),
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: Gap.sm),
          SizedBox(
            width: double.infinity,
            child: FilledButton(
              key: const Key('ds-emule-search-submit'),
              onPressed: onSubmit,
              child: Text(dataText('dsEmuleSearch', 'eMule 搜索')),
            ),
          ),
        ],
      ),
    );
  }
}

class _ResultTile extends StatelessWidget {
  const _ResultTile({
    required this.index,
    required this.result,
    required this.checked,
    required this.onToggle,
  });

  final int index;
  final DsEmuleSearchResult result;
  final bool checked;
  final VoidCallback onToggle;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    // 官方把"已下载过"标红（`file_has_downloaded`）。
    final color = result.hasDownloaded ? theme.colorScheme.error : null;
    return DesignCheckRow(
      key: Key('ds-emule-result-$index'),
      value: checked,
      onChanged: (_) => onToggle(),
      title: Text(
        result.filename.isEmpty
            ? dataText('dsEmuleUnnamed', '（未命名文件）')
            : result.filename,
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
        style: color == null ? null : TextStyle(color: color),
      ),
      subtitle: Text(
        '${dsHumanBytes(result.fileSize)} · '
        '${result.source}/${result.completedSource}',
        maxLines: 1,
      ),
    );
  }
}
