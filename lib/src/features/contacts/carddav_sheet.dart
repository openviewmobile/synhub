// CardDAV 与外部源（对齐官方网页版的「CardDAV」对话框 + 外部通讯录同步）。
//
// 官方口径（bundle 逐字抽出，见 `docs/recheck/contacts-webclient-params.md`）：
//   * 两条地址：`/carddav/<user>`（iOS/macOS 用）和 `/carddav/<user>/<uri>`（其他客户端）；
//     `user` 里的 `\` 要转义成 `@@`；iOS 那条**只在 https 下可用**（官方直接把入口置灰）；
//   * 对话框只有 服务器地址 / 用户名 / 密码 三个输入框 —— 没有名称、没有同步间隔；
//   * 同步是**手动**的（`ExternalSource/refresh {addressbook_id}`）；
//   * 服务端**没有删除外部源的接口**（方法表里只有 create/set/refresh），
//     所以这里只做「添加 / 看 / 同步」，删除要去网页端。
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../../design/kit/design_kit.dart';
import '../../design/design_palette.dart';
import '../../core/i18n/data_text.dart';
import '../../core/i18n/l10n.dart';
import '../../core/services/service_availability.dart';
import '../../core/services/service_registry.dart';
import '../../core/theme/app_tokens.dart';
import '../../core/ui/app_states.dart';
import '../../data/dto/contact_dto.dart';
import '../../data/dto/contact_extras_dto.dart';
import 'contacts_page.dart' show describeContactsError;
import 'contacts_providers.dart';

/// 外部源一行里"同步状态"那一段。
///
/// 语义与文案的原文出处：官方网页客户端 `ui/static/js/main.js` 的
/// `renderLastUpdate()`（`-1` = `status_fail`、`1` = `status_process`、
/// 其它 = `new Date(1e3*update_time)` 格式化）；文案取自
/// `ui/texts/{chs,enu}/strings` 的 `[account_setting_dialog]`：
/// `上次更新 / 失败 / 正在处理`（en：Last update / Failed / Processing）。
String _sourceSubtitle(ExternalSourceDto s, AppText t) {
  final at = s.lastUpdatedAt;
  final when = at == null
      ? ''
      : '${at.year}-${_p2(at.month)}-${_p2(at.day)} '
            '${_p2(at.hour)}:${_p2(at.minute)}';
  final status = s.hasFailed
      ? dataText('contactSyncStatusFailed', '失败')
      : s.isProcessing
      ? dataText('contactSyncStatusProcessing', '正在处理')
      : '';
  return [
    if (s.username.isNotEmpty) s.username,
    if (s.isCardDav) 'CardDAV',
    if (status.isNotEmpty)
      dataText('contactLabelValue', '{label}：{value}')
          .replaceAll('{label}', dataText('contactSyncStatus', '同步状态'))
          .replaceAll('{value}', status)
    else if (when.isNotEmpty)
      dataText('contactLabelValue', '{label}：{value}')
          .replaceAll('{label}', dataText('contactLastUpdate', '上次更新'))
          .replaceAll('{value}', when),
    t.contactBookHash(s.addressbookId),
  ].join(' · ');
}

String _p2(int v) => v.toString().padLeft(2, '0');

Future<void> showCardDavSheet(BuildContext context) =>
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: DesignPalette.of(context).bg,
      builder: (_) => const _CardDavSheet(),
    );

class _CardDavSheet extends ConsumerStatefulWidget {
  const _CardDavSheet();

  @override
  ConsumerState<_CardDavSheet> createState() => _CardDavSheetState();
}

class _CardDavSheetState extends ConsumerState<_CardDavSheet> {
  String? _bookId;
  var _busy = false;

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    final info = ref.watch(contactsInfoProvider);
    final books =
        ref.watch(addressbooksProvider).value ?? const <AddressbookDto>[];
    final sources = ref.watch(externalSourcesProvider);
    final account = info.value?.account ?? '';
    // 能力位（C4）：缺 `SYNO.Contacts.ExternalSource` → **只隐藏外部源这一块**
    // （CardDAV 地址照常显示），**不隐藏联系人模块**。
    final canExternal = ref
        .watch(serviceAvailabilityProvider)
        .hasApi(StationService.contacts, kContactsExternalSourceApi);

    // 默认选第一个有 uri 的通讯录（general 地址要用它）
    AddressbookDto? book;
    for (final b in books) {
      if (b.id == _bookId) book = b;
    }

    book ??= () {
      for (final b in books) {
        if (b.uri.isNotEmpty) return b;
      }
      return null;
    }();

    final api = ref.watch(contactsApiProvider);
    final urls = api?.cardDavUrls(
      account: account,
      addressbookUri: book?.uri ?? '',
    );
    final httpBook = book; // 供闭包用（book 可能为 null）

    return SafeArea(
      child: DraggableScrollableSheet(
        expand: false,
        initialChildSize: 0.7,
        maxChildSize: 0.95,
        minChildSize: 0.4,
        builder: (context, scroll) => ListView(
          controller: scroll,
          padding: const EdgeInsets.fromLTRB(Gap.lg, Gap.lg, Gap.lg, Gap.xl),
          children: [
            Row(
              children: [
                const Icon(Icons.qr_code_2),
                const SizedBox(width: Gap.sm),
                Text('CardDAV', style: Theme.of(context).textTheme.titleLarge),
              ],
            ),
            const SizedBox(height: Gap.xs),
            Text(
              t.contactCarddavIntro,
              style: Theme.of(
                context,
              ).textTheme.bodySmall?.copyWith(color: DesignPalette.of(context).dim),
            ),
            const SizedBox(height: Gap.md),
            // ★ 失败与"还没读到"必须分开：取账号失败时 `account` 是空串，
            //   原来会永远停在进度条（且两条 CardDAV 地址都不出现、无重试）。
            if (info.hasError)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: Gap.sm),
                child: AppEmptyState(
                  key: const Key('carddav-account-error'),
                  icon: Icons.cloud_off,
                  title: t.photoLoadFailed,
                  message: describeContactsError(info.error!, t),
                  actionLabel: t.photoRetry,
                  onAction: () => ref.invalidate(contactsInfoProvider),
                  compact: true,
                ),
              )
            else if (account.isEmpty)
              const Padding(
                padding: EdgeInsets.symmetric(vertical: Gap.md),
                child: LinearProgressIndicator(minHeight: 2),
              ),
            if (books.isNotEmpty) ...[
              DropdownButtonFormField<String>(
                isExpanded: true,
                initialValue: book?.id,
                decoration: InputDecoration(
                  labelText: t.contactCarddavBindBook,
                  isDense: true,
                ),
                items: [
                  for (final b in books)
                    DropdownMenuItem(value: b.id, child: Text(b.name)),
                ],
                onChanged: (v) => setState(() => _bookId = v),
              ),
              const SizedBox(height: Gap.md),
            ],
            if (urls != null) ...[
              _UrlCard(
                title: 'iOS / macOS',
                subtitle: t.contactCarddavIosHint,
                url: urls.short,
              ),
              _UrlCard(
                title: t.contactCarddavOtherClients,
                subtitle: httpBook == null
                    ? t.contactCarddavNoUuid
                    : httpBook.name,
                url: urls.general,
              ),
              if (urls.short.startsWith('https://'))
                Center(
                  child: Padding(
                    padding: const EdgeInsets.only(top: Gap.sm),
                    child: QrImageView(
                      data: urls.general,
                      size: 172,
                      backgroundColor: Colors.white,
                      padding: const EdgeInsets.all(8),
                    ),
                  ),
                ),
            ],
            if (canExternal) ...[
              const Divider(height: Gap.xl),
              Row(
                children: [
                  Expanded(
                    child: Text(
                      t.contactExternalSources,
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                  ),
                  TextButton.icon(
                    onPressed: _busy ? null : _addDialog,
                    icon: const Icon(Icons.add, size: 18),
                    label: Text(t.chatAdd),
                  ),
                ],
              ),
              sources.when(
                loading: () => const Padding(
                  padding: EdgeInsets.symmetric(vertical: Gap.md),
                  child: LinearProgressIndicator(minHeight: 2),
                ),
                error: (e, _) => Padding(
                  padding: const EdgeInsets.symmetric(vertical: Gap.sm),
                  child: AppEmptyState(
                    key: const Key('carddav-sources-error'),
                    icon: Icons.cloud_off,
                    title: t.photoLoadFailed,
                    message: describeContactsError(e, t),
                    actionLabel: t.photoRetry,
                    onAction: () => ref.invalidate(externalSourcesProvider),
                    compact: true,
                  ),
                ),
                // ⚠️ 空列表是**正常空态**（真机 `ExternalSource/list` 就回
                // `{"external_sources":[],"total":0}`，见
                // `docs/live-nas-verification.md` §6.2），**绝不当成错误**。
                data: (list) => list.isEmpty
                    ? Padding(
                        padding: const EdgeInsets.symmetric(vertical: Gap.sm),
                        child: Text(
                          t.contactNoExternalSources,
                          style: Theme.of(
                            context,
                          ).textTheme.bodySmall?.copyWith(color: DesignPalette.of(context).dim),
                        ),
                      )
                    : Column(
                        children: [
                          for (final s in list)
                            DesignRowTile(
                              contentPadding: EdgeInsets.zero,
                              leading: const Icon(Icons.cloud_outlined),
                              title: Text(
                                s.location.isNotEmpty
                                    ? s.location
                                    : (s.source.isEmpty
                                          ? t.contactExternalSource
                                          : s.source),
                              ),
                              subtitle: Text(_sourceSubtitle(s, t)),
                              trailing: IconButton(
                                tooltip: t.noteSyncNow,
                                icon: const Icon(Icons.sync),
                                onPressed: _busy
                                    ? null
                                    : () => _sync(s.addressbookId),
                              ),
                            ),
                        ],
                      ),
              ),
              const SizedBox(height: Gap.sm),
              Text(
                t.contactExternalSourceNote,
                style: Theme.of(
                  context,
                ).textTheme.bodySmall?.copyWith(color: DesignPalette.of(context).dim),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Future<void> _sync(String addressbookId) async {
    setState(() => _busy = true);
    final t = context.t;
    final messenger = ScaffoldMessenger.of(context);
    try {
      await ref.read(contactActionsProvider).syncExternalSource(addressbookId);
      messenger.showSnackBar(SnackBar(content: Text(t.contactSyncTriggered)));
    } catch (e) {
      messenger.showSnackBar(
        SnackBar(
          content: Text(t.contactSyncFailed(describeContactsError(e, t))),
        ),
      );
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _addDialog() async {
    final result = await showDialog<({String url, String user, String pwd})>(
      context: context,
      builder: (_) => const _CardDavForm(),
    );
    if (result == null || !mounted) return;
    setState(() => _busy = true);
    final t = context.t;
    final messenger = ScaffoldMessenger.of(context);
    try {
      await ref
          .read(contactActionsProvider)
          .createCardDav(
            location: result.url,
            username: result.user,
            password: result.pwd,
          );
      messenger.showSnackBar(SnackBar(content: Text(t.contactAddedSyncing)));
      ref.invalidate(externalSourcesProvider);
      ref.invalidate(addressbooksProvider);
    } catch (e) {
      messenger.showSnackBar(
        SnackBar(
          content: Text(t.contactAddFailed(describeContactsError(e, t))),
        ),
      );
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }
}

class _UrlCard extends StatelessWidget {
  const _UrlCard({
    required this.title,
    required this.subtitle,
    required this.url,
  });

  final String title;
  final String subtitle;
  final String url;

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    return Padding(
      padding: const EdgeInsets.only(bottom: Gap.sm),
      child: Container(
        padding: const EdgeInsets.all(Gap.md),
        decoration: BoxDecoration(
          color: DesignPalette.of(context).surface,
          borderRadius: BorderRadius.circular(Radii.pane),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(title, style: Theme.of(context).textTheme.labelLarge),
            Text(
              subtitle,
              style: Theme.of(
                context,
              ).textTheme.bodySmall?.copyWith(color: DesignPalette.of(context).dim),
            ),
            const SizedBox(height: Gap.xs),
            Row(
              children: [
                Expanded(
                  child: SelectableText(
                    url,
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ),
                IconButton(
                  tooltip: t.contactCopyUrl,
                  icon: const Icon(Icons.copy, size: 18),
                  onPressed: () {
                    Clipboard.setData(ClipboardData(text: url));
                    ScaffoldMessenger.of(
                      context,
                    ).showSnackBar(SnackBar(content: Text(t.contactUrlCopied)));
                  },
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _CardDavForm extends StatefulWidget {
  const _CardDavForm();

  @override
  State<_CardDavForm> createState() => _CardDavFormState();
}

class _CardDavFormState extends State<_CardDavForm> {
  final _url = TextEditingController();
  final _user = TextEditingController();
  final _pwd = TextEditingController();

  @override
  void dispose() {
    _url.dispose();
    _user.dispose();
    _pwd.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    return AlertDialog(
      title: Text(t.contactAddCarddavAccount),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          TextField(
            controller: _url,
            decoration: InputDecoration(
              labelText: t.contactServerUrl,
              hintText: 'https://dav.example.com/',
              isDense: true,
            ),
          ),
          const SizedBox(height: Gap.sm),
          TextField(
            controller: _user,
            decoration: InputDecoration(
              labelText: t.contactUsername,
              isDense: true,
            ),
          ),
          const SizedBox(height: Gap.sm),
          TextField(
            controller: _pwd,
            obscureText: true,
            decoration: InputDecoration(
              labelText: t.contactPassword,
              isDense: true,
            ),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(t.actionCancel),
        ),
        FilledButton(
          onPressed: () {
            final url = _url.text.trim();
            if (url.isEmpty) return;
            Navigator.of(
              context,
            ).pop((url: url, user: _user.text.trim(), pwd: _pwd.text));
          },
          child: Text(t.chatAdd),
        ),
      ],
    );
  }
}
