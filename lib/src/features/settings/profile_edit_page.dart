// 个人资料编辑（对齐原版 `ProfileEditFragment`）。
//
// 入口：抽屉里点自己 → 编辑；点别人 → 只看资料（成员页里已有资料弹层）。
// 字段：昵称 / 邮箱 / 简介 + 头像（拍照或相册，裁成正方形）。
// 提交：`SYNO.Chat.User / set` v1 **multipart**（`nickname`/`description`/`email`
// + 可选 `avatar` blob），成功后把服务端返回的 user 写回本地库。
//
// 只读字段：服务端 `readonly_profile` 里列出的字段（`nickname`/`email`/`desc`）
// 要**禁用输入**（原版 `mNicknameText.setEnabled(!readonlyNickname())`）。
// 校验照抄 `ChatUtil.validateNickname` / `validateEmail`：
//   * 昵称：`User` API 支持 v3 时免除特殊字符限制且上限 255，否则上限 32 且
//     不许 `~!@{}<>`|?#$%^&*()+[]'":;,/=` 这些字符
//   * 邮箱：允许为空；非空必须匹配 `EMAIL_ADDRESS_PATTERN`
import 'dart:io';

import 'package:flutter/material.dart';

import '../../design/kit/design_kit.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:image_picker/image_picker.dart';

import '../../core/i18n/l10n.dart';
import '../../core/i18n/data_text.dart';
import '../../core/media/camera_support.dart';
import '../analytics/analytics_track.dart';
import '../analytics/usage_event.dart';
import '../../core/media/image_prepare.dart';
import '../../core/settings/server_settings.dart';
import '../../data/dto/server_settings_dto.dart';
import '../../data/dto/user_dto.dart';
import '../chat/chat_session_controller.dart';
import '../chat/user_avatar.dart';
import '../../core/ui/app_states.dart';
import '../../core/user_facing_error.dart';

/// `ChatUtil.INVALID_NICKNAME_PATTERN`
final _invalidNickname = RegExp(r"""[~!@{}<>`|?#$%^&*()+\[\]'":;,/=]+""");

/// `ChatUtil.EMAIL_ADDRESS_PATTERN`
final _emailPattern = RegExp(
  r'''(([^<>()\[\]\\.,;:\s@"]+(\.[^<>()\[\]\\.,;:\s@"]+)*)|(".+"))'''
  r'''@((\[[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}])'''
  r'''|(([a-zA-Z\-0-9]+\.)+[a-zA-Z]{2,}))''',
);

/// 昵称是否合法（[exemptSpecialChars] = `User` API 支持 v3）
bool isValidNickname(String nickname, {required bool exemptSpecialChars}) =>
    exemptSpecialChars || !_invalidNickname.hasMatch(nickname);

/// 邮箱是否合法（空串视为合法 —— 原版就是"非空才校验"）
bool isValidEmail(String email) =>
    email.isEmpty || _emailPattern.firstMatch(email)?.group(0) == email;

/// 昵称长度上限（原版 `ProfileEditFragment.MAX_NICKNAME_LENGTH`）
int nicknameMaxLength({required bool exemptSpecialChars}) =>
    exemptSpecialChars ? 255 : 32;

/// `readonly_profile` 里的字段名 → 是否只读
bool isProfileFieldReadonly(String field, ServerSettings settings) =>
    settings.readonlyProfile.contains(field);

class ProfileEditPage extends ConsumerStatefulWidget {
  const ProfileEditPage({super.key});

  @override
  ConsumerState<ProfileEditPage> createState() => _ProfileEditPageState();
}

class _ProfileEditPageState extends ConsumerState<ProfileEditPage> {
  final _nickname = TextEditingController();
  final _email = TextEditingController();
  final _desc = TextEditingController();

  String _originalNickname = '';
  String _originalEmail = '';
  String _originalDesc = '';

  /// 当前登录用户（本地缓存里的那条）—— 用来显示服务端已有的头像
  UserDto? _me;

  /// 选好的新头像（已在 `_pickAvatar` 里裁成正方形）
  String? _avatarPath;
  bool _removeAvatar = false;
  bool _saving = false;
  bool _loaded = false;

  /// 本地读取自己那条资料失败的原因（null = 没失败）。
  /// 失败时给出可重试的错误态，而不是永远转圈。
  Object? _loadError;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _nickname.dispose();
    _email.dispose();
    _desc.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final store = ref.read(chatStoreProvider);
      final myId = ref.read(chatSessionControllerProvider).myUserId;
      final users = await store.allUsers();
      UserDto? me;
      for (final u in users) {
        if (u.userId == myId) {
          me = u;
          break;
        }
      }
      if (!mounted) return;
      setState(() {
        _me = me;
        _originalNickname = me?.nickname ?? '';
        _originalEmail = me?.email ?? '';
        _originalDesc = me?.description ?? '';
        _nickname.text = _originalNickname;
        _email.text = _originalEmail;
        _desc.text = _originalDesc;
        _loaded = true;
        _loadError = null;
      });
    } catch (e) {
      // ★ 以前没有 catch：本地读取一失败 `_loaded` 就永远 false ⇒
      //   整页永久转圈、也没有重试入口。现在给明确错误态 + 重试。
      logErrorForDiagnostics('profile_edit.load', e);
      if (!mounted) return;
      setState(() {
        _loaded = true;
        _loadError = e;
      });
    }
  }

  /// 重试加载（真的重新读一次本地用户表）。
  void _retryLoad() {
    setState(() {
      _loaded = false;
      _loadError = null;
    });
    _load();
  }

  bool get _changed =>
      _nickname.text.trim() != _originalNickname ||
      _email.text.trim() != _originalEmail ||
      _desc.text.trim() != _originalDesc ||
      _avatarPath != null ||
      _removeAvatar;

  Future<void> _pickAvatar(ImageSource source) async {
    // ★ DA293：兜住一切挑图失败（桌面端 camera 源必然抛，权限被拒也会抛），
    //   给一句人话原因 —— 绝不再出现"点了没反应"。
    try {
      final picked = await ImagePicker().pickImage(
        source: source,
        maxWidth: 1080,
      );
      if (picked == null || !mounted) return;
      final squared = await cropAvatarSquare(picked.path);
      if (!mounted) return;
      setState(() {
        _avatarPath = squared;
        _removeAvatar = false;
      });
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.maybeOf(context)?.showSnackBar(
        SnackBar(
          content: Text(
            source == ImageSource.camera && !kCameraCaptureSupported
                ? dataText('chatCameraUnavailable',
                    '这台设备没有可用的相机，请改用「从相册选择」。')
                : dataText('profileAvatarPickFailed', '选择图片失败，请重试。'),
          ),
        ),
      );
      debugPrint('[profile] 挑头像失败（$source）：$e');
    }
  }

  Future<void> _save({required bool exemptSpecialChars}) async {
    final api = ref.read(chatSessionControllerProvider.notifier).chatApi;
    if (api == null) {
      _toast(context.t.profileEditNotConnected);
      return;
    }
    final nickname = _nickname.text.trim();
    final email = _email.text.trim();
    final desc = _desc.text.trim();
    if (!isValidNickname(nickname, exemptSpecialChars: exemptSpecialChars)) {
      _toast(context.t.profileEditInvalidNickname);
      return;
    }
    if (!isValidEmail(email)) {
      _toast(context.t.profileEditInvalidEmail);
      return;
    }

    setState(() => _saving = true);
    final progress = ValueNotifier<double>(0);
    try {
      // "移除头像"走 `Profile.Photo/delete` + `User/set(remove_avatar=true)`（原版 removeAvatar）
      if (_removeAvatar) {
        try {
          await api.deleteProfilePhoto();
        } catch (e) {
          // 有的服务器没这个 API：不致命，继续提交资料
          debugPrint('[profile] 删头像失败（忽略）：$e');
        }
      }
      final user = await api.setUserProfile(
        nickname: nickname,
        description: desc,
        email: email,
        avatarPath: _removeAvatar ? null : _avatarPath,
        removeAvatar: _removeAvatar,
        onProgress: (sent, total) {
          if (total > 0) progress.value = sent / total;
        },
      );
      final dto = UserDto.fromJson(user);
      // `User/set` 返回完整 user → **覆盖写**（对齐原版 `DatabaseHelper.setUser`
      // 的直接 UPDATE）。走 `_mergeUser` 会把移除头像回的 `avatar_version: 0`
      // 当"空值"保留旧值，本地就永远显示旧头像。
      await ref.read(chatStoreProvider).upsertUsers([dto], authoritative: true);
      // 换了/移除了头像：清掉这个用户所有版本的头像字节缓存，再让头像 provider
      // 重取（缓存键里虽然带 avatar_version，但同版本下重试/回滚也要能刷新）
      evictUserAvatars(dto.userId);
      ref.invalidate(userAvatarImageProvider);
      if (!mounted) return;
      setState(() {
        _me = dto;
        _originalNickname = dto.nickname;
        _originalEmail = dto.email;
        _originalDesc = dto.description;
        _avatarPath = null;
        _removeAvatar = false;
      });
      _toast(context.t.actionSaved);
      // 让聊天页/列表页重新读用户表
      ref.invalidate(usersProvider);
    } catch (e) {
      if (mounted) {
        // 使用日志：资料保存失败（用户可见的错误；只记稳定原因码与错误类型）
        trackOnceFailure(
          UsageModule.settings,
          UsageAction.edit,
          objectType: 'profile',
          reason: 'profile_save_failed',
          error: e,
        );
        _toast(
          context.t.actionSaveFailed(userFacingError(e)),
        );
      }
    } finally {
      progress.dispose();
      if (mounted) setState(() => _saving = false);
    }
  }

  void _toast(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }

  @override
  Widget build(BuildContext context) {
    final settings = ref.watch(serverSettingsProvider);
    final sync = ref.watch(chatSessionControllerProvider);
    // `User` API 支持 v3 → 免特殊字符限制、上限 255（原版 isSupportExemptSpecialCharacter）
    final exempt = sync.supportsUserV3;
    final readonlyNickname = isProfileFieldReadonly('nickname', settings);
    final readonlyEmail = isProfileFieldReadonly('email', settings);
    final readonlyDesc = isProfileFieldReadonly('desc', settings);
    final maxLen = nicknameMaxLength(exemptSpecialChars: exempt);
    final t = context.t;

    return DesignScaffold(
      appBar: AppBar(
        title: Text(t.meProfile),
        actions: [
          TextButton(
            onPressed: (!_changed || _saving || !_loaded)
                ? null
                : () => _save(exemptSpecialChars: exempt),
            child: _saving
                ? const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : Text(t.actionSave),
          ),
        ],
      ),
      body: !_loaded
          ? const Center(child: CircularProgressIndicator())
          : _loadError != null
          ? AppErrorView(
              key: const Key('profile-edit-load-error'),
              detail: userFacingError(_loadError!),
              onRetry: _retryLoad,
            )
          : ListView(
              padding: const EdgeInsets.all(16),
              children: [
                Center(
                  child: Column(
                    children: [
                      // 本地新选的图优先；否则显示服务端当前头像
                      // （`SYNO.Chat.User.Avatar / get`，原版 `ProfileEditFragment`
                      // 也是 `mAvatarVersion != 0` 时 load `ChatUserAvatar.L`）。
                      // 「移除头像」已点 → 先按无头像渲染，别继续显示旧图。
                      if (_avatarPath != null)
                        CircleAvatar(
                          radius: 40,
                          backgroundImage: FileImage(File(_avatarPath!)),
                        )
                      else
                        UserAvatar(
                          size: 80,
                          user: _removeAvatar ? null : _me,
                          fallbackLabel: _nickname.text.trim(),
                          background: _removeAvatar || _me == null
                              ? null
                              : userAvatarColor(_me!, Theme.of(context)),
                          semanticLabel: _nickname.text.trim(),
                        ),
                      const SizedBox(height: 8),
                      Wrap(
                        spacing: 8,
                        children: [
                          TextButton.icon(
                            onPressed: () => _pickAvatar(ImageSource.gallery),
                            icon: const Icon(Icons.photo_library_outlined),
                            label: Text(t.profileEditFromGallery),
                          ),
                          // ★ DA293：桌面端没有相机实现 —— 原来这个按钮在
                          //   macOS 上点了**完全没反应**（`image_picker` 的
                          //   camera 源在桌面抛 UnimplementedError，而调用点
                          //   没有 try/catch）。没相机就不摆假控件。
                          if (kCameraCaptureSupported)
                            TextButton.icon(
                              onPressed: () => _pickAvatar(ImageSource.camera),
                              icon: const Icon(Icons.photo_camera_outlined),
                              label: Text(t.profileEditTakePhoto),
                            ),
                          if (_avatarPath != null || !_removeAvatar)
                            TextButton.icon(
                              onPressed: () => setState(() {
                                _avatarPath = null;
                                _removeAvatar = true;
                              }),
                              icon: const Icon(Icons.delete_outline),
                              label: Text(t.profileEditRemoveAvatar),
                            ),
                        ],
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 16),
                TextField(
                  controller: _nickname,
                  enabled: !readonlyNickname,
                  maxLength: maxLen,
                  onChanged: (_) => setState(() {}),
                  decoration: InputDecoration(
                    labelText: t.profileEditNickname,
                    border: const OutlineInputBorder(),
                    helperText: readonlyNickname ? t.profileEditReadonly : null,
                  ),
                ),
                const SizedBox(height: 8),
                TextField(
                  controller: _email,
                  enabled: !readonlyEmail,
                  keyboardType: TextInputType.emailAddress,
                  onChanged: (_) => setState(() {}),
                  decoration: InputDecoration(
                    labelText: t.profileEditEmail,
                    border: const OutlineInputBorder(),
                    helperText: readonlyEmail ? t.profileEditReadonly : null,
                  ),
                ),
                const SizedBox(height: 8),
                TextField(
                  controller: _desc,
                  enabled: !readonlyDesc,
                  maxLines: 3,
                  onChanged: (_) => setState(() {}),
                  decoration: InputDecoration(
                    labelText: t.profileEditDesc,
                    border: const OutlineInputBorder(),
                    helperText: readonlyDesc
                        ? t.profileEditReadonly
                        : t.profileEditDescHint,
                  ),
                ),
                const SizedBox(height: 16),
                Builder(
                  builder: (context) {
                    final users =
                        ref.watch(usersProvider).value ?? const <UserDto>[];
                    var account = '';
                    for (final u in users) {
                      if (u.userId == sync.myUserId) {
                        account = u.username;
                        break;
                      }
                    }
                    return Text(
                      t.profileEditAccountLine(
                        account.isEmpty ? '—' : account,
                        sync.myUserId,
                      ),
                      style: Theme.of(context).textTheme.bodySmall,
                    );
                  },
                ),
              ],
            ),
    );
  }
}
