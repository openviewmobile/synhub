// 日历的 **wave1 设置与共享** 弹层（2026-09-22）。
//
// 为什么单独一个文件：`calendar_page.dart` 已经 2900+ 行，再塞共享编辑器会把
// 页面测试的 blast radius 放大。这里只放"新入口"，页面那边只加一个图标按钮
// 和两处取值（待办角标、事件颜色），改动面最小。
//
// 这一批全部是 **wave1 新增**的 `SYNO.Cal.*` 能力，事实来源与降级语义逐条写在
// `lib/src/data/calendar_api.dart` 和 `docs/calendar-gaps-wave1.md`：
//
// | 区块 | API | 证据状态 |
// |---|---|---|
// | 配色 | `Cal.Event/list_color` v6 | 方法/版本 ✅，**回包形状未取证**（宽松解析） |
// | 时区 | `Cal.Timezone/list` | ✅ 真机无参（回**裸数组**） |
// | 共享成员 | `Cal.Sharing/get` | ✅ 真机 `{cal_id}` |
// | 共享候选 | `Cal.Share.Priv/list` | ✅ 真机无参 |
// | 共享写入 | `Cal.Sharing/set` | **客户端取证，未真机验** ⇒ 失败必须明说 |
// | 用户设置 | `Cal.Setting/get` | ✅ 真机；**只读**（`set` 未取证，登记不做） |
// | ICS 导入 | `Cal.Event/create_from_ics` v6 | 方法 ✅ / **参数未取证** ⇒ 只给说明 |
// | 邀请邮件 | `InviteMail*` / `SendMail` | **依赖邮件套件 / 仅管理员** ⇒ 只给说明 |
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../design/kit/design_kit.dart';
import '../../design/design_palette.dart';
import '../../core/i18n/data_text.dart';
import '../../core/i18n/l10n.dart';
import '../../core/services/service_availability.dart';
import '../../core/services/service_registry.dart';
import '../../core/theme/app_tokens.dart';
import '../../core/ui/app_states.dart';
import '../../data/calendar_api.dart';
import '../../data/dto/calendar_dto.dart';
import 'calendar_export.dart';
import 'calendar_providers.dart';

/// 打开日历设置弹层。
Future<void> showCalendarSettingsSheet(
  BuildContext context,
  WidgetRef ref,
) => showModalBottomSheet<void>(
  context: context,
  backgroundColor: Theme.of(context).colorScheme.surface,
  isScrollControlled: true,
  builder: (_) => const _CalendarSettingsSheet(),
);

class _CalendarSettingsSheet extends ConsumerWidget {
  const _CalendarSettingsSheet();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final api = ref.watch(calendarApiProvider);
    final setting = ref.watch(calSettingProvider);
    final calendars = ref.watch(calendarsProvider).value ?? const [];
    // 能力门控：`SYNO.Cal.Sharing` 不在能力表里 → **整块共享入口不显示**。
    // 显示一个"点了必然失败"的入口比不显示更糟（本项目既有纪律）。
    final canShare = api?.hasSharingApi ?? false;
    final canInviteMail = api?.hasInviteMailApi ?? false;
    // wave2 门控：导出走的是 `SYNO.Cal.Cal` 的 v1 `export` 方法 —— 能力表里
    // 没有这个 API 时**整块导出入口不显示**（与 wave1 的共享门控同一口径，
    // 复用 `serviceAvailabilityProvider.hasApi` 这个统一机制）。
    final canExport = ref
        .watch(serviceAvailabilityProvider)
        .hasApi(StationService.calendar, CalendarApi.calApi);
    // 事件日历 + 待办日历都要能导（真机两者都调通，见 calendar_export.dart）。
    // 门控关掉时**不 watch**：免得为一个不显示的区块多打一次 `Cal/list`。
    final exportCals = canExport
        ? (ref.watch(calExportCalendarsProvider).value ??
              const <CalendarDto>[])
        : const <CalendarDto>[];

    return SafeArea(
      child: ListView(
        key: const Key('cal-settings-sheet'),
        shrinkWrap: true,
        padding: const EdgeInsets.fromLTRB(Gap.lg, Gap.md, Gap.lg, Gap.lg),
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  dataText('calSettingsTitle', '日历设置'),
                  style: theme.textTheme.titleMedium,
                ),
              ),
              IconButton(
                tooltip: context.t.photoClose,
                icon: const Icon(Icons.close),
                onPressed: () => Navigator.of(context).pop(),
              ),
            ],
          ),

          // ---- 配色（`Event/list_color` v6） ---------------------------------
          _SectionTitle(dataText('calEventColorsSection', '日程配色（服务端）')),
          _EventColorPalette(key: const Key('cal-settings-colors')),

          // ---- 时区（`Timezone/list`） --------------------------------------
          _SectionTitle(dataText('calTimezoneSection', '时区')),
          _Tile(
            key: const Key('cal-settings-timezone'),
            icon: Icons.public,
            title: dataText('calTimezoneCurrent', '新建日程的时区'),
            // 初值 = 会话内覆盖（用户在设置里选过）→ 否则 `Setting/get` 的
            // `time_zone`（真机取证）。可选列表来自 `Timezone/list`（真机裸数组）。
            subtitle: ref.watch(calDefaultTimeZoneProvider).isNotEmpty
                ? ref.watch(calDefaultTimeZoneProvider)
                : (setting.value?.timeZone.isNotEmpty == true
                      ? setting.value!.timeZone
                      : dataText('calNotSet', '未设置')),
            onTap: () => _openTimezonePicker(context, ref),
          ),

          // ---- 只读用户设置（`Setting/get`） --------------------------------
          _SectionTitle(dataText('calUserSettingsSection', '用户设置（只读）')),
          if (setting.hasError)
            _Hint(
              icon: Icons.error_outline,
              text: describeCalendarError(setting.error!),
            )
          else if (setting.value == null)
            _Hint(
              key: const Key('cal-settings-loading'),
              icon: Icons.hourglass_empty,
              text: dataText('calLoading', '加载中…'),
            )
          else
            ..._settingRows(setting.value!),

          // ---- 共享日历（`Sharing/get|set`、`Share.Priv/list`） -------------
          if (canShare) ...[
            _SectionTitle(dataText('calSharingSection', '共享日历')),
            if (calendars.isEmpty)
              _Hint(
                icon: Icons.event_busy_outlined,
                text: dataText('calNoCalendars', '这个账号还没有日历。'),
              )
            else
              for (var i = 0; i < calendars.length; i++)
                _Tile(
                  key: Key('cal-settings-sharing-$i'),
                  icon: Icons.group_outlined,
                  title: calendars[i].displayName,
                  subtitle: dataText('calSharingManage', '查看 / 设置共享成员'),
                  trailing: Icon(
                    Icons.chevron_right,
                    color: DesignPalette.of(context).dim,
                  ),
                  onTap: () =>
                      _openSharingEditor(context, ref, calendars[i]),
                ),
          ],

          // ---- 导出（`Cal.Cal/export` v1，**只读**） ------------------------
          if (canExport) ...[
            _SectionTitle(dataText('calExportSection', '导出')),
            if (exportCals.isEmpty)
              _Hint(
                key: const Key('cal-export-empty'),
                icon: Icons.event_busy_outlined,
                text: dataText('calNoCalendars', '这个账号还没有日历。'),
              )
            else
              for (var i = 0; i < exportCals.length; i++)
                _Tile(
                  key: Key('cal-settings-export-$i'),
                  icon: Icons.ios_share,
                  title: exportCals[i].displayName,
                  // ⚠️ 只显示**日历显示名**；内部 `cal_id` 不上屏、也不进文件名
                  subtitle: dataText('calExportIcs', '导出为 .ics 文件'),
                  onTap: () => exportCalendar(context, ref, exportCals[i]),
                ),
          ],

          // ---- ICS 导入（骨架：参数未取证） ---------------------------------
          _SectionTitle(dataText('calImportSection', '导入')),
          _Tile(
            key: const Key('cal-settings-ics'),
            icon: Icons.upload_file_outlined,
            title: dataText('calIcsImport', 'ICS 导入'),
            // **门控 + 明说原因**：参数名未取证，所以这里是"说明入口"，
            // 不是"点了就失败"的按钮（与 `cal-external-info` 同一条纪律）。
            subtitle: CalendarApi.icsImportUnavailableReason,
            onTap: () => _explain(
              context,
              dataText('calIcsImport', 'ICS 导入'),
              CalendarApi.icsImportUnavailableReason,
            ),
          ),

          // ---- 邀请邮件（依赖邮件套件 / 仅管理员） --------------------------
          if (canInviteMail)
            _Tile(
              key: const Key('cal-settings-invite-mail'),
              icon: Icons.mail_outline,
              title: dataText('calInviteMail', '邀请邮件'),
              subtitle: CalendarApi.inviteMailUnavailableReason,
              onTap: () => _explain(
                context,
                dataText('calInviteMail', '邀请邮件'),
                CalendarApi.inviteMailUnavailableReason,
              ),
            ),
        ],
      ),
    );
  }

  /// `Setting/get` 的**只读**行。写能力（`Setting/set`）**没有 entry.cgi 的真机
  /// 取证**，所以按纪律只读并登记（见 `docs/calendar-gaps-wave1.md`）。
  List<Widget> _settingRows(CalSettingDto s) {
    final weekNames = [
      dataText('calWeekdaySun', '周日'),
      dataText('calWeekdayMon', '周一'),
      dataText('calWeekdayTue', '周二'),
      dataText('calWeekdayWed', '周三'),
      dataText('calWeekdayThu', '周四'),
      dataText('calWeekdayFri', '周五'),
      dataText('calWeekdaySat', '周六'),
    ];
    final week = (s.weekStartDay >= 0 && s.weekStartDay <= 6)
        ? weekNames[s.weekStartDay]
        : '${s.weekStartDay}';
    return [
      _Tile(
        key: const Key('cal-settings-date-format'),
        icon: Icons.event_note_outlined,
        title: dataText('calDateFormat', '日期格式'),
        subtitle: s.dateFormat,
      ),
      _Tile(
        key: const Key('cal-settings-time-format'),
        icon: Icons.schedule_outlined,
        title: dataText('calTimeFormat', '时间格式'),
        subtitle: '${s.timeFormat} h',
      ),
      _Tile(
        key: const Key('cal-settings-week-start'),
        icon: Icons.calendar_view_week_outlined,
        title: dataText('calWeekStart', '每周起始日'),
        subtitle: week,
      ),
      _Tile(
        key: const Key('cal-settings-default-view'),
        icon: Icons.dashboard_outlined,
        title: dataText('calDefaultView', '默认视图'),
        subtitle: s.defaultView,
      ),
      _Tile(
        key: const Key('cal-settings-show-week-numbers'),
        icon: Icons.numbers,
        title: dataText('calShowWeekNumbers', '显示周数'),
        subtitle: s.showWeekNumbers
            ? dataText('calYes', '是')
            : dataText('calNo', '否'),
      ),
    ];
  }
}

/// 配色面板：**只用 `list_color` 的回值**，拿不到就照实说。
///
/// ⚠️ **绝不内置调色板**：写死颜色会把"接口没接通"伪装成"功能正常"，
/// 而且真机上服务端配色改过之后客户端会显示过期颜色（falsification ①）。
class _EventColorPalette extends ConsumerWidget {
  const _EventColorPalette({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final async = ref.watch(calEventColorsProvider);
    if (async.hasError) {
      return _Hint(
        key: const Key('cal-colors-error'),
        icon: Icons.error_outline,
        text: describeCalendarError(async.error!),
      );
    }
    final colors = async.value;
    if (colors == null) {
      return _Hint(
        key: const Key('cal-colors-loading'),
        icon: Icons.hourglass_empty,
        text: dataText('calLoading', '加载中…'),
      );
    }
    if (colors.isEmpty) {
      // 服务端没给（或这个方法在这台设备上不可用）—— **照实说**
      return _Hint(
        key: const Key('cal-colors-empty'),
        icon: Icons.format_color_reset_outlined,
        text: dataText(
          'calNoServerColors',
          // ★★ r348 D60：ARB 已是干净的「…（需要更高的服务端版本）。」，
          //   兜底串还在印 `Event/list_color 仅 v6`（同一句两份表示，§2.0.26）。
          '这台 NAS 没有返回可用配色（需要更高的服务端版本）。',
        ),
      );
    }
    return Wrap(
      spacing: Gap.sm,
      runSpacing: Gap.sm,
      children: [
        for (var i = 0; i < colors.length; i++)
          Tooltip(
            message: colors[i].name.isEmpty
                ? colors[i].color
                : '${colors[i].name} ${colors[i].color}',
            child: Container(
              key: Key('cal-color-swatch-$i'),
              width: 28,
              height: 28,
              decoration: BoxDecoration(
                color: _swatchColor(colors[i].color),
                shape: BoxShape.circle,
                border: Border.all(
                  color: Theme.of(context).colorScheme.outlineVariant,
                ),
              ),
            ),
          ),
      ],
    );
  }
}

/// 时区选择（`Timezone/list`）。
///
/// 选中后写 [calDefaultTimeZoneProvider]（**会话内**的新建初值）——
/// 单条事件的时区最终是 `Event/create` 的 `tz_id`，那条路径是真机验证过的。
Future<void> _openTimezonePicker(BuildContext context, WidgetRef ref) async {
  // ⚠️ 必须 `await …future`，不能 `ref.read(...).value`：这个 provider 是
  // `autoDispose` 且**没有别处 watch**，第一次 read 只会拿到 AsyncLoading，
  // `.value` 是 null → 选择器永远是空的（离线测试抓出来的）。
  List<CalTimezoneDto> list;
  try {
    list = await ref.read(calTimezoneListProvider.future);
  } catch (_) {
    list = const [];
  }
  if (!context.mounted) return;
  final picked = await showModalBottomSheet<String>(
    context: context,
    backgroundColor: Theme.of(context).colorScheme.surface,
    isScrollControlled: true,
    builder: (ctx) => SafeArea(
      child: ListView(
        key: const Key('cal-timezone-sheet'),
        shrinkWrap: true,
        children: [
          DesignRowTile(title: Text(dataText('calTimezonePick', '选择时区'))),
          if (list.isEmpty)
            _Hint(
              key: const Key('cal-timezone-empty'),
              icon: Icons.public_off,
              text: dataText(
                'calTimezoneEmpty',
                // ★★ r348 D60：ARB 早已是干净的「这台 NAS 没有返回时区表。」，
                //   但这条**兜底串**还在印 `Cal.Timezone/list`（同一句两份表示，§2.0.26）。
                '这台 NAS 没有返回时区表。',
              ),
            ),
          for (var i = 0; i < list.length; i++)
            DesignRowTile(
              key: Key('cal-timezone-$i'),
              dense: true,
              title: Text(list[i].tzId),
              onTap: () => Navigator.of(ctx).pop(list[i].tzId),
            ),
        ],
      ),
    ),
  );
  if (picked == null || picked.isEmpty) return;
  ref.read(calDefaultTimeZoneProvider.notifier).set(picked);
}

/// 共享日历编辑器：读 `Sharing/get`，写 `Sharing/set`（**失败必须明说**）。
Future<void> _openSharingEditor(
  BuildContext context,
  WidgetRef ref,
  CalendarDto calendar,
) async {
  await showModalBottomSheet<void>(
    context: context,
    backgroundColor: Theme.of(context).colorScheme.surface,
    isScrollControlled: true,
    builder: (_) => _SharingEditorSheet(calendar: calendar),
  );
}

class _SharingEditorSheet extends ConsumerStatefulWidget {
  const _SharingEditorSheet({required this.calendar});

  final CalendarDto calendar;

  @override
  ConsumerState<_SharingEditorSheet> createState() =>
      _SharingEditorSheetState();
}

class _SharingEditorSheetState extends ConsumerState<_SharingEditorSheet> {
  /// 本地草稿（保存时整体提交 —— 服务端 `set` 就是全量语义）
  List<CalShareMemberDto>? _draft;

  /// 保存中（防连点）
  bool _saving = false;

  @override
  Widget build(BuildContext context) {
    final async = ref.watch(calSharingOfProvider(widget.calendar.calId));
    final loaded = _draft ?? async.value;
    // 提升成**非空局部变量**：下面闭包（onPressed）里 Dart 不会跨闭包保留
    // 类型提升，直接用 `loaded` 会编译不过。
    final members = loaded ?? const <CalShareMemberDto>[];
    final hasMembers = loaded != null;
    final principals = ref.watch(calSharePrincipalsProvider).value ?? const [];
    final canWrite = widget.calendar.canWrite;

    return SafeArea(
      child: ListView(
        key: const Key('cal-sharing-sheet'),
        shrinkWrap: true,
        padding: const EdgeInsets.fromLTRB(Gap.lg, Gap.md, Gap.lg, Gap.lg),
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  // ⚠️ 只显示日历**显示名**，不显示内部 cal_id
                  widget.calendar.displayName,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.titleMedium,
                ),
              ),
              IconButton(
                tooltip: context.t.photoClose,
                icon: const Icon(Icons.close),
                onPressed: () => Navigator.of(context).pop(),
              ),
            ],
          ),
          if (!hasMembers)
            _Hint(
              key: const Key('cal-sharing-loading'),
              icon: Icons.hourglass_empty,
              text: dataText('calLoading', '加载中…'),
            )
          else if (members.isEmpty)
            _Hint(
              key: const Key('cal-sharing-empty'),
              icon: Icons.lock_outline,
              text: dataText('calSharingNone', '这个日历没有共享给任何人。'),
            )
          else
            for (var i = 0; i < members.length; i++)
              DesignRowTile(
                key: Key('cal-sharing-member-$i'),
                dense: true,
                leading: Icon(
                  members[i].isUser
                      ? Icons.person_outline
                      : Icons.groups_outlined,
                ),
                title: Text(members[i].name),
                subtitle: Text(
                  members[i].canWrite
                      ? dataText('calCanWrite', '可编辑')
                      : dataText('dtoNotePermReadOnly', '只读'),
                ),
                trailing: canWrite
                    ? IconButton(
                        key: Key('cal-sharing-remove-$i'),
                        tooltip: dataText('calRemove', '移除'),
                        icon: const Icon(Icons.remove_circle_outline),
                        onPressed: _saving
                            ? null
                            : () => setState(() {
                                _draft = [
                                  for (final m in members)
                                    if (m != members[i]) m,
                                ];
                              }),
                      )
                    : null,
              ),
          if (canWrite && principals.isNotEmpty)
            DesignRowTile(
              key: const Key('cal-sharing-add'),
              dense: true,
              leading: const Icon(Icons.add),
              title: Text(dataText('calSharingAdd', '添加成员')),
              onTap: _saving ? null : () => _addMember(members, principals),
            ),
          const SizedBox(height: Gap.md),
          if (canWrite)
            FilledButton(
              key: const Key('cal-sharing-save'),
              onPressed: _saving ? null : () => _save(members),
              child: Text(
                _saving
                    ? dataText('calSaving', '正在保存…')
                    : dataText('actionSave', '保存'),
              ),
            ),
        ],
      ),
    );
  }

  Future<void> _addMember(
    List<CalShareMemberDto> members,
    List<CalSharePrincipalDto> principals,
  ) async {
    final picked = await showModalBottomSheet<CalSharePrincipalDto>(
      context: context,
      backgroundColor: Theme.of(context).colorScheme.surface,
      builder: (ctx) => SafeArea(
        child: ListView(
          key: const Key('cal-principal-sheet'),
          shrinkWrap: true,
          children: [
            DesignRowTile(title: Text(dataText('calSharingAdd', '添加成员'))),
            for (var i = 0; i < principals.length; i++)
              DesignRowTile(
                key: Key('cal-principal-$i'),
                dense: true,
                leading: Icon(
                  principals[i].isUser
                      ? Icons.person_outline
                      : Icons.groups_outlined,
                ),
                title: Text(principals[i].name),
                onTap: () => Navigator.of(ctx).pop(principals[i]),
              ),
          ],
        ),
      ),
    );
    if (picked == null || !mounted) return;
    setState(() {
      _draft = [
        ...members,
        CalShareMemberDto(
          name: picked.name,
          privilege: 'RO',
          isUser: picked.isUser,
        ),
      ];
    });
  }

  Future<void> _save(List<CalShareMemberDto> members) async {
    final api = ref.read(calendarApiProvider);
    if (api == null) return;
    setState(() => _saving = true);
    try {
      final saved = await api.setCalendarSharing(
        calId: widget.calendar.calId,
        members: members,
      );
      if (!mounted) return;
      setState(() {
        _draft = saved;
        _saving = false;
      });
      ref.invalidate(calSharingOfProvider(widget.calendar.calId));
      AppSnack.show(context, dataText('calSharingSaved', '共享设置已更新'));
    } catch (e) {
      if (!mounted) return;
      setState(() => _saving = false);
      // ⚠️ **明确提示**：`Sharing/set` 是客户端取证、未真机验回包；
      // 失败了就说清楚（含错误码语义），**绝不静默**（falsification ⑤）。
      AppSnack.show(
        context,
        '${dataText('calSharingSaveFailed', '共享设置保存失败')}：'
        '${describeCalendarError(e)}',
        error: true,
      );
    }
  }
}

/// `#RRGGBB` → [Color]；解析不出来给一个中性灰（**不是**某个具体配色，
/// 免得把"服务端没给颜色"显示成"服务端给了紫色"）。
Color _swatchColor(String raw) {
  final s = raw.trim();
  if (s.length >= 7 && s.startsWith('#')) {
    final v = int.tryParse(s.substring(1, 7), radix: 16);
    if (v != null) return Color(0xFF000000 | v);
  }
  if (s.length == 6) {
    final v = int.tryParse(s, radix: 16);
    if (v != null) return Color(0xFF000000 | v);
  }
  return const Color(0xFF9E9E9E);
}

void _explain(BuildContext context, String title, String body) {  showDialog<void>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Text(title),
      content: Text(body),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(ctx).pop(),
          child: Text(dataText('actionOk', '好')),
        ),
      ],
    ),
  );
}

class _SectionTitle extends StatelessWidget {
  const _SectionTitle(this.text);

  final String text;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(0, Gap.md, 0, Gap.xs),
    child: Text(
      text,
      style: Theme.of(context).textTheme.labelLarge?.copyWith(
        color: DesignPalette.of(context).dim,
      ),
    ),
  );
}

class _Tile extends StatelessWidget {
  const _Tile({
    super.key,
    required this.icon,
    required this.title,
    required this.subtitle,
    this.trailing,
    this.onTap,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final Widget? trailing;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) => DesignRowTile(
    dense: true,
    contentPadding: EdgeInsets.zero,
    leading: Icon(icon, size: 20),
    title: Text(title),
    subtitle: Text(
      subtitle,
      style: Theme.of(context).textTheme.bodySmall?.copyWith(
        color: DesignPalette.of(context).dim,
      ),
    ),
    trailing: trailing,
    onTap: onTap,
  );
}

class _Hint extends StatelessWidget {
  const _Hint({super.key, required this.icon, required this.text});

  final IconData icon;
  final String text;

  @override
  Widget build(BuildContext context) => DesignRowTile(
    dense: true,
    contentPadding: EdgeInsets.zero,
    leading: Icon(icon, size: 18, color: DesignPalette.of(context).dim),
    title: Text(
      text,
      style: Theme.of(context).textTheme.bodySmall?.copyWith(
        color: DesignPalette.of(context).dim,
      ),
    ),
  );
}
