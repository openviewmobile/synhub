// N4：位置的**编辑面板**。
//
// ★ 官方形态（不自创）：Android `fragments/MapDialogFragment` =
//   可编辑的 `AutoCompleteTextView`（`act_location`）＋ 地图 ＋
//   `remove_tag`(清除) / `ok` / `cancel`；官方 Web `Info.Map.Window` =
//   `Info.Map.SearchField`（`queryParam:"query"`，走 `Info:searchplace`）
//   ＋ 地图 ＋ `delete_gps` / `ok` / `cancel`，标题 `info.location`。
//   本面板**没有地图**（Flutter 不引 Google Maps 插件），于是保留官方可移植的
//   那一半：**可自由输入的位置名** ＋ **searchplace 搜索结果** ＋
//   **"用当前位置"**（官方 `Geolocation.getCurrentGPS()` / `execGPS()`）＋
//   **删除 GPS** ＋ 取消/保存。坐标从搜索结果或设备定位来，**不手填、不伪造**。
import '../../design/kit/design_kit.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../design/design_palette.dart';
import '../../core/i18n/l10n.dart';
import '../../core/theme/app_tokens.dart';
import '../../data/dto/note_dto.dart';
import '../../data/region/device_location.dart';
import 'note_location.dart';
import 'note_location_text.dart';
import 'note_providers.dart';
import 'note_widgets.dart' show describeNoteError;

/// 打开「设置位置」面板。
Future<void> showNoteLocationSheet(
  BuildContext context,
  WidgetRef ref,
  NoteDto note,
) => showModalBottomSheet<void>(
  context: context,
  isScrollControlled: true,
  showDragHandle: true,
  builder: (_) => NoteLocationSheet(note: note),
);

class NoteLocationSheet extends ConsumerStatefulWidget {
  const NoteLocationSheet({super.key, required this.note});

  final NoteDto note;

  @override
  ConsumerState<NoteLocationSheet> createState() => _NoteLocationSheetState();
}

class _NoteLocationSheetState extends ConsumerState<NoteLocationSheet> {
  late final TextEditingController _name;
  late final TextEditingController _search;

  double? _lat;
  double? _lng;

  /// 已提交的搜索关键字（空 = 还没搜）
  String _query = '';
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _name = TextEditingController(text: widget.note.location ?? '');
    _search = TextEditingController();
    _lat = widget.note.latitude;
    _lng = widget.note.longitude;
  }

  @override
  void dispose() {
    _name.dispose();
    _search.dispose();
    super.dispose();
  }

  NoteDto get _note => widget.note;

  /// 搜索中心点：优先用已选坐标，否则用设备定位（拿不到就没有中心点）。
  double? get _centerLat {
    if (_lat != null && _lat != 0) return _lat;
    return ref.watch(noteDeviceLocationProvider).value?.latitude;
  }

  double? get _centerLng {
    if (_lng != null && _lng != 0) return _lng;
    return ref.watch(noteDeviceLocationProvider).value?.longitude;
  }

  String get _display => noteLocationDisplayText(
    _name.text.trim(),
    _lat,
    _lng,
  );

  @override
  Widget build(BuildContext context) {
    final hud = DesignPalette.of(context);
    final t = context.t;
    final permission =
        ref.watch(noteLocationPermissionProvider).value ??
        LocationPermission.unsupported;
    final canUseDevice = permission == LocationPermission.granted;
    final lat = _centerLat;
    final lng = _centerLng;
    return SafeArea(
      key: const Key('note-location-sheet'),
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(Gap.lg, 0, Gap.lg, Gap.lg),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              noteLocation(NoteLocationTextKeys.setLocation, '设置位置'),
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(height: Gap.sm),
            // 官方 `getLocationDisplayText` 的显示口径（名字 + (lat,lng)）；
            // 什么都没有就出占位符，绝不出一个编造的坐标。
            Text(
              _display.isEmpty ? '—' : _display,
              key: const Key('note-location-display'),
              style: TextStyle(color: hud.dim, fontSize: 12),
            ),
            const SizedBox(height: Gap.sm),
            // 官方 `act_location`：可自由输入的位置名
            TextField(
              key: const Key('note-location-name'),
              controller: _name,
              decoration: InputDecoration(
                labelText: noteLocation(NoteLocationTextKeys.location, '位置'),
                hintText: noteLocation(
                  NoteLocationTextKeys.locationNameHint,
                  '地点名称',
                ),
              ),
              onChanged: (_) => setState(() {}),
            ),
            const SizedBox(height: Gap.sm),
            Row(
              children: [
                Expanded(
                  child: TextField(
                    key: const Key('note-location-search'),
                    controller: _search,
                    decoration: InputDecoration(
                      labelText: noteLocation(
                        NoteLocationTextKeys.searchPlace,
                        '搜索地点',
                      ),
                      hintText: noteLocation(
                        NoteLocationTextKeys.searchPlaceHint,
                        '搜索地点或地址',
                      ),
                    ),
                    onSubmitted: (_) => _submitSearch(),
                  ),
                ),
                IconButton(
                  key: const Key('note-location-search-submit'),
                  tooltip: noteLocation(
                    NoteLocationTextKeys.searchPlace,
                    '搜索地点',
                  ),
                  icon: const Icon(Icons.search),
                  onPressed: _busy ? null : _submitSearch,
                ),
              ],
            ),
            if (canUseDevice)
              Align(
                alignment: Alignment.centerLeft,
                child: TextButton.icon(
                  key: const Key('note-location-use-current'),
                  onPressed: _busy ? null : _useCurrentLocation,
                  icon: const Icon(Icons.my_location),
                  label: Text(
                    noteLocation(
                      NoteLocationTextKeys.useCurrentLocation,
                      '用当前位置',
                    ),
                  ),
                ),
              ),
            if (_query.isNotEmpty) _searchResults(lat, lng),
            const Divider(height: Gap.lg),
            Row(
              children: [
                TextButton(
                  key: const Key('note-location-delete-gps'),
                  onPressed: _busy ? null : _deleteGps,
                  child: Text(
                    noteLocation(
                      NoteLocationTextKeys.deleteGps,
                      '删除 GPS 信息',
                    ),
                  ),
                ),
                const Spacer(),
                TextButton(
                  key: const Key('note-location-cancel'),
                  onPressed: _busy ? null : () => Navigator.of(context).pop(),
                  child: Text(t.actionCancel),
                ),
                const SizedBox(width: Gap.sm),
                FilledButton(
                  key: const Key('note-location-save'),
                  // 全局主题给 FilledButton 设了 `Size.fromHeight(48)`（宽度无限），
                  // 直接放进 Row 会量到无限宽；这里收成内容宽（与 OutlinedButton 同）。
                  style: FilledButton.styleFrom(
                    minimumSize: const Size(0, 40),
                  ),
                  onPressed: _busy ? null : _save,
                  child: Text(t.actionSave),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _searchResults(double? lat, double? lng) {
    if (lat == null || lng == null) {
      // 没有中心点就**不发请求**（真机上 `searchplace` 缺合法 `location` 会挂到超时）
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: Gap.sm),
        child: Text(
          noteLocation(
            NoteLocationTextKeys.searchNeedsCenter,
            '先设置或获取一个位置，才能搜索附近地点',
          ),
          style: TextStyle(color: DesignPalette.of(context).dim, fontSize: 12),
        ),
      );
    }
    final query = _query;
    final async = ref.watch(
      notePlaceSearchProvider(
        NotePlaceQuery(latitude: lat, longitude: lng, query: query),
      ),
    );
    return async.when(
      loading: () => Padding(
        padding: const EdgeInsets.symmetric(vertical: Gap.sm),
        child: Row(
          children: [
            const SizedBox(
              width: 18,
              height: 18,
              child: CircularProgressIndicator(
                key: Key('note-location-searching'),
                strokeWidth: 2,
              ),
            ),
            const SizedBox(width: Gap.sm),
            Text(
              noteLocation(NoteLocationTextKeys.searching, '搜索中…'),
              style: TextStyle(
                color: DesignPalette.of(context).dim,
                fontSize: 12,
              ),
            ),
          ],
        ),
      ),
      error: (e, _) => Padding(
        padding: const EdgeInsets.symmetric(vertical: Gap.sm),
        child: Text(
          describeNoteError(e, context.t),
          key: const Key('note-location-search-error'),
          style: TextStyle(color: DesignPalette.of(context).dim, fontSize: 12),
        ),
      ),
      data: (places) {
        if (places.isEmpty) {
          return Padding(
            padding: const EdgeInsets.symmetric(vertical: Gap.sm),
            child: Text(
              noteLocation(
                NoteLocationTextKeys.noSearchResult,
                '未找到相符项目。',
              ),
              key: const Key('note-location-no-result'),
              style: TextStyle(color: DesignPalette.of(context).dim, fontSize: 12),
            ),
          );
        }
        return Column(
          children: [
            for (var i = 0; i < places.length; i++)
              DesignRowTile(
                key: Key('note-location-result-$i'),
                dense: true,
                contentPadding: EdgeInsets.zero,
                // ⚠️ 只上屏 `name`/`address`；`placeID` 只留在数据层
                title: Text(places[i].name),
                subtitle: places[i].address.isEmpty
                    ? null
                    : Text(places[i].address),
                trailing: Tooltip(
                  message: noteLocation(
                    NoteLocationTextKeys.useThisPlace,
                    '用这条',
                  ),
                  child: const Icon(Icons.place_outlined, size: 18),
                ),
                onTap: () => _selectPlace(places[i]),
              ),
          ],
        );
      },
    );
  }

  void _submitSearch() {
    final q = _search.text.trim();
    if (q.isEmpty) return;
    if (_centerLat == null || _centerLng == null) {
      _toast(
        noteLocation(
          NoteLocationTextKeys.searchNeedsCenter,
          '先设置或获取一个位置，才能搜索附近地点',
        ),
      );
      return;
    }
    setState(() => _query = q);
  }

  void _selectPlace(NotePlaceDto place) {
    setState(() {
      if (place.name.isNotEmpty) _name.text = place.name;
      if (place.hasGps) {
        _lat = place.latitude;
        _lng = place.longitude;
      }
    });
  }

  Future<void> _useCurrentLocation() async {
    final probe = ref.read(noteDeviceLocationProbeProvider);
    final permission = await probe.ensurePermission(interactive: true);
    if (!mounted) return;
    if (permission == LocationPermission.unsupported) {
      _toast(
        noteLocation(
          NoteLocationTextKeys.locationUnsupported,
          '当前设备不支持定位',
        ),
      );
      return;
    }
    if (permission != LocationPermission.granted) {
      _toast(
        noteLocation(
          NoteLocationTextKeys.locationPermissionDenied,
          '没有定位权限，无法获取当前位置',
        ),
      );
      return;
    }
    if (!await probe.serviceEnabled()) {
      if (mounted) {
        _toast(
          noteLocation(
            NoteLocationTextKeys.locationUnavailable,
            '现在取不到当前位置',
          ),
        );
      }
      return;
    }
    final fix = await probe.current();
    if (!mounted) return;
    if (fix == null || !fix.isUsable) {
      _toast(
        noteLocation(
          NoteLocationTextKeys.locationUnavailable,
          '现在取不到当前位置',
        ),
      );
      return;
    }
    setState(() {
      _lat = fix.latitude;
      _lng = fix.longitude;
      // 官方 `getCurrentGPS` 只给坐标、不给地名
      _name.text = '';
    });
  }

  void _deleteGps() {
    // 官方 `removeGPS`：地图清标记 → 坐标归 0、位置名清空；提示 `delete_gps_message`
    setState(() {
      _lat = 0;
      _lng = 0;
      _name.text = '';
    });
    _toast(
      noteLocation(
        NoteLocationTextKeys.deleteGpsMessage,
        '已成功删除 GPS 信息',
      ),
    );
  }

  Future<void> _save() async {
    final t = context.t;
    final api = ref.read(noteApiProvider);
    if (api == null) return;
    setState(() => _busy = true);
    try {
      // 官方 `Info.Window.onClickOK` 每次都把坐标写进表单（没有 GPS 就是 0），
      // `location` 原样给出（空串由 `SetNoteOperation` 丢掉，与官方一致）。
      await api.setNote(
        objectId: _note.objectId,
        ver: _note.ver,
        latitude: _lat ?? 0,
        longitude: _lng ?? 0,
        location: _name.text.trim(),
      );
      ref.invalidate(noteDetailProvider(_note.objectId));
      ref.invalidate(noteListProvider);
      _toast(noteLocation(NoteLocationTextKeys.locationSaved, '位置已保存'));
      if (mounted) Navigator.of(context).pop();
    } catch (e) {
      _toast(
        noteLocationFill(
          NoteLocationTextKeys.saveFailed,
          '操作失败：{error}',
          {'error': describeNoteError(e, t)},
        ),
      );
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _toast(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(message)));
  }
}
