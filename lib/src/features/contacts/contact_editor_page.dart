// 新建 / 编辑联系人。
//
// 字段与官方网页版编辑器**逐字对齐**（bundle 里的默认对象 + 真机 round-trip）：
// `full_name`、`name{given,family,prefix,suffix,additional}`、
// `mail[]`/`tel[]`/`url[]`/`im[]`/`date[]`/`adr[]`、`company`、`department`、
// `title`、`birthday`、`note`、`photo`。
//
// 头像：官方是"选图 → 方框裁切 → 传 base64 data URL"，这里复用个人资料页那套
// （`cropAvatarSquare` 居中裁正方形 + 缩到 512，再自己拼 data URL），
// 传输层是 form-urlencoded，所以 data URL 直接当普通字段发。
//
// 只读保护：团队通讯录里同步过来的「用户记录」`is_editable=false`，
// 编辑入口会直接拦住并说明原因（别让用户白填一遍再吃 105）。
import 'dart:convert';
import 'dart:typed_data';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:image_picker/image_picker.dart';

import '../../design/design_palette.dart';
import '../../core/i18n/l10n.dart';
import '../../core/media/image_prepare.dart';
import '../../core/theme/app_tokens.dart';
import '../../data/dto/contact_dto.dart';
import '../../data/dto/contact_extras_dto.dart';
import 'contacts_page.dart' show describeContactsError;
import 'contacts_providers.dart';

class ContactEditorPage extends ConsumerStatefulWidget {
  const ContactEditorPage({
    super.key,
    required this.addressbookId,
    this.existing,
  });

  /// 新建时用（编辑时用 [ContactDto.addressbookId]）
  final String addressbookId;

  /// 非空 = 编辑
  final ContactDto? existing;

  @override
  ConsumerState<ContactEditorPage> createState() => _ContactEditorPageState();
}

class _ContactEditorPageState extends ConsumerState<ContactEditorPage> {
  final _full = TextEditingController();
  final _given = TextEditingController();
  final _family = TextEditingController();
  final _prefix = TextEditingController();
  final _suffix = TextEditingController();
  final _additional = TextEditingController();
  final _nick = TextEditingController();
  final _company = TextEditingController();
  final _department = TextEditingController();
  final _title = TextEditingController();
  final _birthday = TextEditingController();
  final _note = TextEditingController();

  final _mail = <TextEditingController>[];
  final _tel = <TextEditingController>[];
  final _url = <TextEditingController>[];
  final _im = <TextEditingController>[];
  final _date = <TextEditingController>[];
  final _adr = <TextEditingController>[];

  String _photo = '';
  var _saving = false;

  bool get _isEdit => widget.existing != null;

  @override
  void initState() {
    super.initState();
    final d = widget.existing?.detail;
    final c = widget.existing;
    _full.text = d?.fullName ?? c?.fullName ?? '';
    _given.text = d?.givenName ?? '';
    _family.text = d?.familyName ?? '';
    _prefix.text = d?.prefix ?? '';
    _suffix.text = d?.suffix ?? '';
    _additional.text = d?.additionalName ?? '';
    _nick.text = d?.nickName ?? '';
    _company.text = d?.company ?? c?.company ?? '';
    _department.text = d?.department ?? c?.department ?? '';
    _title.text = d?.title ?? c?.title ?? '';
    _birthday.text = d?.birthday ?? '';
    _note.text = d?.note ?? c?.note ?? '';
    _photo = d?.photo ?? c?.photo ?? '';
    _fill(_mail, d?.mail ?? c?.mail ?? const []);
    _fill(_tel, d?.tel ?? c?.tel ?? const []);
    _fill(_url, d?.url ?? const []);
    _fill(_im, d?.im ?? const []);
    _fill(_date, d?.date ?? const []);
    _fill(_adr, d?.adr ?? const []);
    if (_mail.isEmpty) _mail.add(TextEditingController());
    if (_tel.isEmpty) _tel.add(TextEditingController());
  }

  void _fill(List<TextEditingController> into, List<String> values) {
    for (final v in values) {
      into.add(TextEditingController(text: v));
    }
  }

  @override
  void dispose() {
    for (final c in [
      _full,
      _given,
      _family,
      _prefix,
      _suffix,
      _additional,
      _nick,
      _company,
      _department,
      _title,
      _birthday,
      _note,
      ..._mail,
      ..._tel,
      ..._url,
      ..._im,
      ..._date,
      ..._adr,
    ]) {
      c.dispose();
    }
    super.dispose();
  }

  ContactInput _collect() => ContactInput(
    fullName: _full.text.trim(),
    givenName: _given.text.trim(),
    familyName: _family.text.trim(),
    prefix: _prefix.text.trim(),
    suffix: _suffix.text.trim(),
    additionalName: _additional.text.trim(),
    nickName: _nick.text.trim(),
    mail: _values(_mail),
    tel: _values(_tel),
    url: _values(_url),
    im: _values(_im),
    date: _values(_date),
    adr: _values(_adr),
    company: _company.text.trim(),
    department: _department.text.trim(),
    title: _title.text.trim(),
    birthday: _birthday.text.trim(),
    note: _note.text,
    photo: _photo,
  );

  static List<String> _values(List<TextEditingController> cs) => [
    for (final c in cs) c.text.trim(),
  ];

  Future<void> _pickPhoto() async {
    final picked = await ImagePicker().pickImage(
      source: ImageSource.gallery,
      maxWidth: 1080,
    );
    if (picked == null || !mounted) return;
    final squared = await cropAvatarSquare(picked.path);
    final bytes = await File(squared).readAsBytes();
    if (!mounted) return;
    setState(() {
      _photo = 'data:image/jpeg;base64,${base64Encode(bytes)}';
    });
  }

  Future<void> _save() async {
    final t = context.t;
    final input = _collect();
    if (input.fullName.trim().isEmpty) {
      _toast(t.contactNameRequired);
      return;
    }
    setState(() => _saving = true);
    try {
      final actions = ref.read(contactActionsProvider);
      if (_isEdit) {
        await actions.setContact(id: widget.existing!.id, input: input);
      } else {
        await actions.createContact(
          addressbookId: widget.addressbookId,
          input: input,
        );
      }
      if (!mounted) return;
      Navigator.of(context).pop(true);
    } catch (e) {
      if (!mounted) return;
      setState(() => _saving = false);
      _toast(t.noteSaveFailed(describeContactsError(e, t)));
    }
  }

  void _toast(String msg) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: DesignPalette.of(context).bg,
      appBar: AppBar(
        title: Text(
          _isEdit ? context.t.contactEditTitle : context.t.contactNewTitle,
        ),
        actions: [
          TextButton(
            onPressed: _saving ? null : _save,
            child: _saving
                ? const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : Text(context.t.actionSave),
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(Gap.md, Gap.md, Gap.md, Gap.xl),
        children: [
          Center(
            child: InkWell(
              borderRadius: BorderRadius.circular(64),
              onTap: _saving ? null : _pickPhoto,
              child: _PhotoPickerAvatar(photo: _photo, name: _full.text),
            ),
          ),
          const SizedBox(height: Gap.xs),
          Center(
            child: TextButton.icon(
              onPressed: _saving ? null : _pickPhoto,
              icon: const Icon(Icons.photo_camera_outlined, size: 18),
              label: Text(
                _photo.isEmpty
                    ? context.t.contactAddPhoto
                    : context.t.contactChangePhoto,
              ),
            ),
          ),
          if (_photo.isNotEmpty)
            Center(
              child: TextButton(
                onPressed: _saving ? null : () => setState(() => _photo = ''),
                child: Text(context.t.profileEditRemoveAvatar),
              ),
            ),
          const SizedBox(height: Gap.sm),
          _Section(
            title: context.t.contactSectionBasic,
            children: [
              _field(_full, context.t.contactFieldFullName, required: true),
              _field(_nick, context.t.profileEditNickname),
              _field(_company, context.t.contactFieldCompany),
              _field(_department, context.t.contactFieldDepartment),
              _field(_title, context.t.contactFieldJobTitle),
            ],
          ),
          _Section(
            title: context.t.contactSectionNameParts,
            children: [
              _field(_given, context.t.contactFieldGivenName),
              _field(_family, context.t.contactFieldFamilyName),
              _field(_prefix, context.t.contactFieldPrefix),
              _field(_suffix, context.t.contactFieldSuffix),
              _field(_additional, context.t.contactFieldMiddleName),
            ],
          ),
          _MultiSection(
            title: context.t.profileEditEmail,
            controllers: _mail,
            hint: 'name@example.com',
            keyboard: TextInputType.emailAddress,
            canAdd: true,
            onChanged: () => setState(() {}),
          ),
          _MultiSection(
            title: context.t.contactFieldPhone,
            controllers: _tel,
            hint: context.t.contactPhoneHint,
            keyboard: TextInputType.phone,
            canAdd: true,
            onChanged: () => setState(() {}),
          ),
          _MultiSection(
            title: context.t.contactFieldUrl,
            controllers: _url,
            hint: 'https://',
            canAdd: true,
            onChanged: () => setState(() {}),
          ),
          _MultiSection(
            title: context.t.contactFieldIm,
            controllers: _im,
            hint: context.t.contactImHint,
            canAdd: true,
            onChanged: () => setState(() {}),
          ),
          _MultiSection(
            title: context.t.contactFieldDate,
            controllers: _date,
            hint: '2026-09-21',
            canAdd: true,
            onChanged: () => setState(() {}),
          ),
          _MultiSection(
            title: context.t.contactFieldAddress,
            controllers: _adr,
            hint: context.t.contactAddressHint,
            canAdd: true,
            onChanged: () => setState(() {}),
          ),
          _Section(
            title: context.t.contactSectionOther,
            children: [
              _field(_birthday, context.t.contactFieldBirthday),
              _field(_note, context.t.contactFieldNote, lines: 4),
            ],
          ),
        ],
      ),
    );
  }

  Widget _field(
    TextEditingController c,
    String label, {
    bool required = false,
    int lines = 1,
  }) => Padding(
    padding: const EdgeInsets.only(bottom: Gap.sm),
    child: TextField(
      controller: c,
      maxLines: lines,
      onChanged: required ? (_) => setState(() {}) : null,
      decoration: InputDecoration(
        labelText: required ? '$label *' : label,
        isDense: true,
      ),
    ),
  );
}

/// 头像（有 data URL 就显示图，否则显示姓名首字）
class _PhotoPickerAvatar extends StatelessWidget {
  const _PhotoPickerAvatar({required this.photo, required this.name});

  final String photo;
  final String name;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final bytes = decodePhotoDataUrl(photo);
    return CircleAvatar(
      radius: 40,
      backgroundColor: scheme.primary.withValues(alpha: 0.18),
      backgroundImage: bytes == null ? null : MemoryImage(bytes),
      child: bytes != null
          ? null
          : Text(
              initialsOf(name),
              style: TextStyle(
                color: scheme.primary,
                fontWeight: FontWeight.w700,
                fontSize: 28,
              ),
            ),
    );
  }
}

/// `data:image/…;base64,xxx` → 字节（解析不了给 null，绝不抛）
Uint8List? decodePhotoDataUrl(String raw) {
  final s = raw.trim();
  final comma = s.indexOf(',');
  if (comma <= 0 || !s.toLowerCase().startsWith('data:image')) return null;
  try {
    return base64Decode(s.substring(comma + 1));
  } catch (_) {
    return null;
  }
}

/// 姓名首字（和列表头像同一口径）
String initialsOf(String name) {
  final n = name.trim();
  if (n.isEmpty) return '?';
  return n.substring(0, 1).toUpperCase();
}

class _Section extends StatelessWidget {
  const _Section({required this.title, required this.children});

  final String title;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(top: Gap.md),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            title,
            style: Theme.of(
              context,
            ).textTheme.labelMedium?.copyWith(color: DesignPalette.of(context).dim),
          ),
          const SizedBox(height: Gap.sm),
          ...children,
        ],
      ),
    );
  }
}

/// 多值字段（邮箱/电话/网址/IM/日期/地址）：一行一个，可加可删
class _MultiSection extends StatelessWidget {
  const _MultiSection({
    required this.title,
    required this.controllers,
    required this.hint,
    required this.onChanged,
    this.keyboard,
    this.canAdd = true,
  });

  final String title;
  final List<TextEditingController> controllers;
  final String hint;
  final VoidCallback onChanged;
  final TextInputType? keyboard;
  final bool canAdd;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(top: Gap.md),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  title,
                  style: Theme.of(
                    context,
                  ).textTheme.labelMedium?.copyWith(color: DesignPalette.of(context).dim),
                ),
              ),
              if (canAdd)
                IconButton(
                  tooltip: context.t.contactAddRow(title),
                  visualDensity: VisualDensity.compact,
                  icon: const Icon(Icons.add, size: 18),
                  onPressed: () {
                    controllers.add(TextEditingController());
                    onChanged();
                  },
                ),
            ],
          ),
          for (var i = 0; i < controllers.length; i++)
            Padding(
              padding: const EdgeInsets.only(bottom: Gap.xs),
              child: Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: controllers[i],
                      keyboardType: keyboard,
                      decoration: InputDecoration(
                        hintText: hint,
                        isDense: true,
                      ),
                    ),
                  ),
                  IconButton(
                    tooltip: context.t.contactRemoveRow,
                    visualDensity: VisualDensity.compact,
                    icon: const Icon(Icons.remove_circle_outline, size: 18),
                    onPressed: () {
                      final c = controllers.removeAt(i);
                      c.dispose();
                      if (controllers.isEmpty) {
                        controllers.add(TextEditingController());
                      }
                      onChanged();
                    },
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}
