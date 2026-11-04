// 加密笔记的解锁状态与口令服务。
//
// 官方两个客户端的行为（我们照抄）：
//   * **口令只存在内存里**：Web 端 `enc_pwd` 是 AppWindow 上的一个 Map，
//     刷新页面就没了；Android 端把 token 写进 NoteProvider 的 `TOKEN` 列。
//     我们按 Web 的做法 —— 进程内 Map，不落盘（落盘等于把口令写进明文存储）。
//   * **解密在本地做**：`Note/get` 回来的 `content` 是密文，客户端用口令
//     `AES256Cipher.decrypt`（`NoteCrypto`）解出来再渲染。
//   * **保存要"解锁令牌"**：`Note.Encrypt/create` 换 token → `Note/set` 带
//     `token`。官方 Web 端 30 秒轮询 `check` 续期，Android 端保存前
//     `check` 一次、失败就重新 `create`。我们用后者的做法，并在令牌快过期时
//     自动续。
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/i18n/l10n.dart';

import '../../data/dto/note_dto.dart';
import '../../data/note_api.dart';
import '../../data/note_crypto.dart';
import 'note_providers.dart';
import 'note_reminder.dart';

/// 一条笔记的解锁状态（内存态）。
class NoteUnlock {
  const NoteUnlock({
    required this.password,
    required this.token,
    required this.expiresAt,
  });

  final String password;
  final String token;
  final DateTime expiresAt;

  /// 还剩不到 30 秒就算"要续了"（官方 Web 端也是提前轮询）
  bool get needsRefresh =>
      DateTime.now().isAfter(expiresAt.subtract(const Duration(seconds: 30)));

  NoteUnlock copyWith({String? token, DateTime? expiresAt}) => NoteUnlock(
    password: password,
    token: token ?? this.token,
    expiresAt: expiresAt ?? this.expiresAt,
  );
}

/// 进程内的解锁表（key = note object_id）。
class NoteUnlockStore {
  final Map<String, NoteUnlock> _byId = {};

  NoteUnlock? operator [](String objectId) => _byId[objectId];

  bool contains(String objectId) => _byId.containsKey(objectId);

  void keep(String objectId, NoteUnlock unlock) => _byId[objectId] = unlock;

  void forget(String objectId) => _byId.remove(objectId);

  void clear() => _byId.clear();

  int get length => _byId.length;
}

final noteUnlockStoreProvider = Provider<NoteUnlockStore>(
  (ref) => NoteUnlockStore(),
);

/// 口令不对时抛出（界面直接显示"口令不对"）。
class NotePasswordException implements Exception {
  const NotePasswordException();

  @override
  String toString() => currentText().noteWrongPassword;
}

/// 加密笔记的门面：解锁 / 续令牌 / 上锁 / 加密正文。
class NoteEncryptionService {
  NoteEncryptionService(this.api, this.store);

  final NoteStationApi api;
  final NoteUnlockStore store;

  /// 用口令解锁：**先本地解密**（口令不对立刻失败），再向服务端换令牌。
  ///
  /// 返回解出来的明文 HTML。
  Future<String> unlock(NoteDto note, String password) async {
    final String plain;
    try {
      plain = NoteCrypto.decryptContent(note.content, password);
    } on NoteDecryptException {
      throw const NotePasswordException();
    }
    String token = '';
    try {
      token = await api.createEncryptToken(
        objectId: note.objectId,
        password: password,
      );
    } catch (_) {
      // 令牌拿不到不影响"看"（官方 Web 端在只读场景下也不强求）；
      // 真正保存时会再试一次，那时失败才报错。
    }
    store.keep(
      note.objectId,
      NoteUnlock(
        password: password,
        token: token,
        expiresAt: DateTime.now().add(
          const Duration(seconds: NoteStationApi.unlockDurationSeconds),
        ),
      ),
    );
    return plain;
  }

  /// 确保有一个可用令牌（过期/失效自动重换）。
  Future<String> ensureToken(String objectId) async {
    final current = store[objectId];
    if (current == null) return '';
    if (!current.needsRefresh && current.token.isNotEmpty) {
      final ok = await api.checkEncryptToken(
        objectId: objectId,
        token: current.token,
      );
      if (ok) return current.token;
    }
    final token = await api.createEncryptToken(
      objectId: objectId,
      password: current.password,
    );
    store.keep(
      objectId,
      current.copyWith(
        token: token,
        expiresAt: DateTime.now().add(
          const Duration(seconds: NoteStationApi.unlockDurationSeconds),
        ),
      ),
    );
    return token;
  }

  /// 上锁：通知服务端丢弃令牌（`Encrypt/delete`）并清本地口令。
  Future<void> lock(String objectId) async {
    final current = store[objectId];
    store.forget(objectId);
    if (current == null || current.token.isEmpty) return;
    try {
      await api.deleteEncryptToken(objectId: objectId, token: current.token);
    } catch (_) {
      // 上锁是"尽力而为"：服务端不认（比如令牌早过期）就算了
    }
  }

  /// 加密一段正文（新建 / 保存加密笔记时用）。
  String encrypt(String plainHtml, String password) =>
      NoteCrypto.encryptContent(plainHtml, password);

  /// **改口令**（I2）。
  ///
  /// ★ 取证：官方**没有** `Note.Encrypt/change_password` 这种接口 ——
  ///   官方就是"**本地换口令重加密 + `Note/copy` 出一份副本**"：
  ///   * Android `fragments/ChangePasswordDialogFragment.lambda$onCreateView$3`：
  ///     `EncryptNoteTask.setOldPassword(旧)` + `setKey(新)`（本地 AES 重加密）
  ///     → `CopyNoteLoader.setEncAction(ENCRYPT_TO_ENCRYPT)` +
  ///     `setContent(新密文)` + `setOldPassword(旧)` + `setNewPassword(新)`；
  ///     `CopyNoteLoader.smali:1070/1144` 把标题拼成 `原题 + " - " + duplicate`
  ///     （**不删原件**，官方行为如此）；
  ///   * 官方 Web `Encrypt.Modify.Window.onClickOk`：
  ///     `o = CryptoJS.AES.encrypt(MAGIC + content, 新口令)` → `copyNote({...,
  ///     content:o, encrypt:true, old_password, new_password, password})`；
  ///     其 `backend.copyNote` 带顶层 `encryption:["old_password","new_password"]`
  ///     —— 那是 `synowebapi` 传输层选项。我们跟 **Android** 的 `cipher_key`
  ///     路线（见 [NoteStationApi.copyNoteEncryptPolling]），`DsmWebApi.call()`
  ///     只传 `params` 即可，**不需要**动禁改的 `lib/src/dsm/**`。
  ///   * 分支：**有附件**才走 `Note.Polling/copy` + `cipher_key`（服务端要
  ///     重加密附件）；无附件走 `Note/copy` 一次性调用。
  ///
  /// 返回新笔记 id。失败**原样抛出**（界面如实报错）。
  Future<String> changePassword(
    NoteDto note, {
    required String oldPassword,
    required String newPassword,
  }) async {
    final plain = NoteCrypto.decryptContent(note.content, oldPassword);
    final cipher = NoteCrypto.encryptContent(plain, newPassword);
    final title = _changePasswordCopyTitle(note.title);
    final parentId = note.parentId;
    final String newId;
    if (note.attachments.isEmpty) {
      newId = await api.copyNote(
        note.objectId,
        parentId: parentId,
        title: title,
        ver: note.ver,
        encrypt: true,
        content: cipher,
      );
    } else {
      newId = await api.copyNoteEncryptPolling(
        objectId: note.objectId,
        title: title,
        parentId: parentId,
        oldPassword: oldPassword,
        newPassword: newPassword,
        encryptedContent: cipher,
      );
    }
    // 新副本的解锁态直接给上：用户刚输了新口令，不该再问一次
    if (newId.isNotEmpty) {
      store.keep(
        newId,
        NoteUnlock(
          password: newPassword,
          token: '',
          expiresAt: DateTime.now().add(
            const Duration(seconds: NoteStationApi.unlockDurationSeconds),
          ),
        ),
      );
    }
    // 原件的解锁态作废（它的口令已经不该再用了）
    store.forget(note.objectId);
    return newId;
  }

  /// 口令是否满足官方限制（1~32 字符）。
  static String? validatePassword(String password, [AppText? l10n]) {
    final t = l10n ?? currentText();
    if (password.isEmpty) return t.notePasscodeRequired;
    if (password.length > NoteCrypto.maxPasswordLength) {
      return t.notePasscodeTooLong(NoteCrypto.maxPasswordLength);
    }
    return null;
  }
}

/// 换口令后副本的标题（官方 `CopyNoteLoader` / Web 都是「原题 + 分隔符 + duplicate」；
/// 这里复用本仓库 `note_copy.dart` 同一套"副本"文案）。
String _changePasswordCopyTitle(String title) {
  final base = title.trim().isEmpty
      ? noteB(NoteBTextKeys.copyTitle, '无标题笔记')
      : title.trim();
  return '$base${noteB(NoteBTextKeys.copySuffix, '（副本）')}';
}

/// 未连接时为 null。
final noteEncryptionProvider = Provider<NoteEncryptionService?>((ref) {
  final api = ref.watch(noteApiProvider);
  if (api == null) return null;
  return NoteEncryptionService(api, ref.watch(noteUnlockStoreProvider));
});
