// 导入联系人（对齐官方网页版的导入向导，只是步骤压到一屏）。
//
// 真机口径（`docs/contacts-module-plan.md` §3.1）：
//   * `Addressbook/import_preview` 是 **multipart**，目标通讯录放**表单字段**
//     `addressbook_id`（放 `id` 回 120）；
//   * `Addressbook/import` 也是 multipart，但目标要放**查询串** `id`；
//   * 文件字段名统一是 `file`，官方接受 `.vcf / .csv / .txt`（前端限 200MB）。
//
// 预览里每条有 `status`：官方用它区分"新增 / 已存在"，这里同样给个提示，
// 但**不阻止**导入（服务端怎么合并由它自己决定，我们不替它做假设）。
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../design/kit/design_kit.dart';
import '../../design/design_palette.dart';
import '../../core/i18n/l10n.dart';
import '../../core/theme/app_tokens.dart';
import '../../data/dto/contact_dto.dart';
import '../../data/dto/contact_extras_dto.dart';
import 'contacts_page.dart' show describeContactsError;
import 'contacts_providers.dart';

class ContactImportPage extends ConsumerStatefulWidget {
  const ContactImportPage({super.key, required this.books});

  final List<AddressbookDto> books;

  @override
  ConsumerState<ContactImportPage> createState() => _ContactImportPageState();
}

class _ContactImportPageState extends ConsumerState<ContactImportPage> {
  late final List<AddressbookDto> _books = widget.books;
  String? _bookId;
  String? _filePath;
  String? _fileName;
  List<ImportPreviewDto>? _preview;
  var _busy = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    if (_books.isNotEmpty) _bookId = _books.first.id;
  }

  @override
  Widget build(BuildContext context) {
    final booksAsync = ref.watch(addressbooksProvider);
    final books = booksAsync.value ?? _books;
    if (books.isNotEmpty && _bookId == null) _bookId = books.first.id;

    return Scaffold(
      backgroundColor: DesignPalette.of(context).bg,
      appBar: AppBar(title: Text(context.t.contactImportTitle)),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(Gap.md, Gap.md, Gap.md, Gap.xl),
        children: [
          Text(
            context.t.contactImportHelp,
            style: Theme.of(
              context,
            ).textTheme.bodySmall?.copyWith(color: DesignPalette.of(context).dim),
          ),
          const SizedBox(height: Gap.md),
          DropdownButtonFormField<String>(
            isExpanded: true,
            initialValue: _bookId,
            decoration: InputDecoration(
              labelText: context.t.contactImportTargetBook,
              isDense: true,
            ),
            items: [
              for (final b in books)
                DropdownMenuItem(value: b.id, child: Text(b.name)),
            ],
            onChanged: _busy ? null : (v) => setState(() => _bookId = v),
          ),
          const SizedBox(height: Gap.md),
          OutlinedButton.icon(
            onPressed: _busy ? null : _pick,
            icon: const Icon(Icons.folder_open),
            label: Text(
              _fileName == null ? context.t.contactPickFile : _fileName!,
            ),
          ),
          if (_error != null) ...[
            const SizedBox(height: Gap.md),
            Text(
              _error!,
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: Theme.of(context).colorScheme.error,
              ),
            ),
          ],
          if (_preview != null) ...[
            const SizedBox(height: Gap.lg),
            Row(
              children: [
                Expanded(
                  child: Text(
                    context.t.contactPreviewCount(_preview!.length),
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                ),
                if (_preview!.any((p) => p.maybeDuplicate))
                  Text(
                    context.t.contactPreviewDuplicates(
                      _preview!.where((p) => p.maybeDuplicate).length,
                    ),
                    style: Theme.of(
                      context,
                    ).textTheme.bodySmall?.copyWith(color: DesignPalette.of(context).dim),
                  ),
              ],
            ),
            const SizedBox(height: Gap.xs),
            for (final p in _preview!)
              DesignRowTile(
                dense: true,
                contentPadding: EdgeInsets.zero,
                leading: Icon(
                  p.maybeDuplicate
                      ? Icons.content_copy_outlined
                      : Icons.person_add_alt,
                  size: 18,
                  color: p.maybeDuplicate
                      ? DesignPalette.of(context).dim
                      : Theme.of(context).colorScheme.primary,
                ),
                title: Text(
                  p.fullName.isEmpty ? context.t.contactUnnamed : p.fullName,
                ),
                subtitle: p.primaryMail.isEmpty ? null : Text(p.primaryMail),
              ),
          ],
          const SizedBox(height: Gap.lg),
          FilledButton.icon(
            onPressed: (_busy || _preview == null || _bookId == null)
                ? null
                : _import,
            icon: _busy
                ? const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.upload),
            label: Text(
              _busy
                  ? context.t.contactImportBusy
                  : context.t.contactImportToThisBook,
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _pick() async {
    final t = context.t;
    final picked = await FilePicker.pickFile(
      type: FileType.custom,
      allowedExtensions: const ['vcf', 'csv', 'txt'],
    );
    if (picked == null) return;
    final path = picked.path;
    if (path == null) {
      setState(() => _error = t.contactNoFilePath);
      return;
    }
    setState(() {
      _filePath = path;
      _fileName = picked.name;
      _preview = null;
      _error = null;
    });
    await _runPreview();
  }

  Future<void> _runPreview() async {
    final t = context.t;
    final path = _filePath;
    if (path == null) return;
    setState(() => _busy = true);
    try {
      final list = await ref
          .read(contactActionsProvider)
          .previewImport(
            filePath: path,
            fileName: _fileName ?? 'import.vcf',
            addressbookId: _bookId,
          );
      if (!mounted) return;
      setState(() {
        _preview = list;
        if (list.isEmpty) _error = t.contactNoContactsInFile;
      });
    } catch (e) {
      if (!mounted) return;
      setState(
        () => _error = t.contactPreviewFailed(describeContactsError(e, t)),
      );
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _import() async {
    final t = context.t;
    final path = _filePath;
    final bookId = _bookId;
    if (path == null || bookId == null) return;
    setState(() => _busy = true);
    final messenger = ScaffoldMessenger.of(context);
    final nav = Navigator.of(context);
    try {
      final ids = await ref
          .read(contactActionsProvider)
          .importVCard(
            filePath: path,
            fileName: _fileName ?? 'import.vcf',
            addressbookId: bookId,
          );
      messenger.showSnackBar(
        SnackBar(
          content: Text(
            ids.isEmpty
                ? t.contactImportDone
                : t.contactImportedCount(ids.length),
          ),
        ),
      );
      nav.maybePop();
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _error = t.contactImportFailed(describeContactsError(e, t));
      });
    }
  }
}
