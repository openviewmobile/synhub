// M68（审计行 220）：把已下载的文件**导出到系统「下载」目录**。
//
// ## 用户可见的缺口（原话记录）
// > "下载的文件用户找不到、传不出去"
//
// 根因：我们的下载落盘在 `<应用文档>/downloads` —— **应用私有目录**，
// 系统「文件」App 里看不到、别的 App 也拿不到。官方 DS file 是写公共下载目录的。
//
// ## 实现在哪
// * **平台层**：`android/app/src/main/kotlin/…/MediaStoreBridge.kt`
//   —— `MediaStore.Downloads` 插入（API 29+ **免权限**；`IS_PENDING` 保证
//   "写完整才可见"；系统对同名文件自动改名，**不覆盖**用户已有文件）。
// * **本文件**：抽象 + 注入点 + 失败降级（与 `file_shortcut.dart` 同一套写法）。
//
// ## 通道契约（**与 Kotlin 侧逐字对应，改一处必须改两处**）
//   * 通道 `synhub/mediastore`
//   * `isSupported` → `Bool`
//   * `saveToDownloads` ← `{path, name, mimeType}` → `String?`（写好的 URI）
//
// ## 失败降级
// 平台没实现（桌面 / 测试 / 未注册）抛 `MissingPluginException`，
// 系统拒绝抛 `PlatformException` —— **一律 catch 成"不支持"**，
// UI 只给一句人话，**不把内部话术丢给用户**。
import 'dart:async' show unawaited;

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/i18n/data_text.dart';
import '../../core/platform/app_paths.dart';
import '../../core/platform/fs_bookmark.dart';
import '../../core/platform/ios_fs_export.dart';
import '../../core/platform/app_platform.dart';
import '../../core/platform/save_destination.dart';

/// 一次导出尝试的结果。
///
/// **不抛异常**：UI 只需要"成没成 / 为什么不成"。
class MediaStoreSaveResult {
  const MediaStoreSaveResult._(
    this.ok,
    this.uri,
    this.unsupported,
    this.reason, {
    this.hostTrack = false,
  });

  /// 成功：文件已经在系统「下载」目录里。
  ///
  /// [hostTrack] = true ⇒ [uri] 其实是**宿主机上的绝对路径**
  /// （不是 Android 的 `content://`），界面必须**把路径说出来**：
  /// 桌面上的 B 轨落在 App 容器里，用户不可能猜到。
  const MediaStoreSaveResult.saved(String uri, {bool hostTrack = false})
    : this._(true, uri, false, '', hostTrack: hostTrack);

  /// 这台设备/这个构建不支持（降级，不是错误）。
  ///
  /// 第 55 轮：带 `reason`（机器可读原因码）—— 宿主上是能力层给的
  /// `not-implemented-on-host`，界面用 `capabilityReasonText(reason)` 说明。
  const MediaStoreSaveResult.unsupported(
    [String reason = '', bool hostTrack = false]
  ) : this._(false, null, true, reason, hostTrack: hostTrack);

  /// 支持但这次失败了（源文件不在、磁盘满、系统拒绝…）。
  const MediaStoreSaveResult.failed([String reason = '', bool hostTrack = false])
    : this._(false, null, false, reason, hostTrack: hostTrack);

  final bool ok;
  final String? uri;

  /// `true` ⇒ [uri] 是宿主机文件系统路径（见 `saved` 的说明）。
  final bool hostTrack;

  /// `true` ⇒ 应当提示"这台设备不支持"，而不是"失败了"。
  final bool unsupported;

  /// 为什么（机器可读原因码；`''` = 没特别原因）。
  final String reason;
}

/// 把本地文件导出到系统「下载」目录。
abstract class MediaStoreSaver {
  /// 当前平台是否支持（API < 29 且无写权限 ⇒ false）。
  Future<bool> isSupported();

  /// 把 [sourcePath] 的文件以 [name] 的名字写进系统「下载」目录。
  Future<MediaStoreSaveResult> saveToDownloads({
    required String sourcePath,
    required String name,
    String mimeType,
  });
}

/// 平台实现：MethodChannel。
class MethodChannelMediaStoreSaver implements MediaStoreSaver {
  MethodChannelMediaStoreSaver({MethodChannel? channel})
    : _channel = channel ?? const MethodChannel(channelName);

  /// Kotlin 侧注册的同名通道（`MediaStoreBridge.CHANNEL`）。
  static const String channelName = 'synhub/mediastore';

  final MethodChannel _channel;

  @override
  Future<bool> isSupported() async {
    // ★ 第 55 轮：`synhub/mediastore` 只有 Kotlin 一份 ⇒ 宿主上先问能力层，
    //   不碰通道（原因由 [capabilityStatus] 给出）。
    if (!capabilityGateAllows(AppCapability.mediaStoreExport)) {
      debugPrint(
        capabilityGateLog(AppCapability.mediaStoreExport, 'mediastore.isSupported'),
      );
      return false;
    }
    try {
      return await _channel.invokeMethod<bool>('isSupported') == true;
    } on MissingPluginException {
      return false;
    } on PlatformException {
      return false;
    }
  }

  /// 导出能力在本平台的结论（**界面据此说明"为什么导不出去"**）。
  static CapabilityStatus capabilityStatus() =>
      AppPlatformCapabilities.current().statusOf(AppCapability.mediaStoreExport);

  @override
  Future<MediaStoreSaveResult> saveToDownloads({
    required String sourcePath,
    required String name,
    String mimeType = 'application/octet-stream',
  }) async {
    if (!capabilityGateAllows(AppCapability.mediaStoreExport)) {
      final reason = capabilityGateReason(AppCapability.mediaStoreExport);
      debugPrint(
        capabilityGateLog(
          AppCapability.mediaStoreExport,
          'mediastore.saveToDownloads',
        ),
      );
      return MediaStoreSaveResult.unsupported(reason);
    }
    try {
      final uri = await _channel.invokeMethod<String>('saveToDownloads', {
        'path': sourcePath,
        'name': name,
        'mimeType': mimeType,
      });
      if (uri == null || uri.isEmpty) {
        return const MediaStoreSaveResult.failed();
      }
      return MediaStoreSaveResult.saved(uri);
    } on MissingPluginException {
      return const MediaStoreSaveResult.unsupported(CapabilityReason.bridgeMissing);
    } on PlatformException {
      return const MediaStoreSaveResult.failed(CapabilityReason.probeError);
    }
  }
}

/// 注入点：测试覆盖成假桥。
///
/// ★ 第 328 轮：默认实现按**宿主**分派 —— 桌面走宿主的文件系统（双轨），
/// Android/iOS 仍走 `synhub/mediastore`。改这里之前先读 [HostFileSaveSaver]
/// 文件头（那里记着"为什么宿主上原来是一条死路"）。
final mediaStoreSaverProvider = Provider<MediaStoreSaver>((ref) {
  // 书签这一路**只在能力位可用时才注入**（= macOS）：
  // Linux/Windows 上注入等于每次都白打一次没有实现的通道，
  // 行为应当与 r328 之前**逐字一致**（每次弹面板，不假装记住）。
  final withBookmarks = capabilityGateAllows(AppCapability.fsBookmark);
  return fileExportSaverForHost(
    bookmarks: withBookmarks ? ref.watch(fsBookmarkBridgeProvider) : null,
    recent: withBookmarks ? ref.watch(recentSaveDirectoryStoreProvider) : null,
    // ★ r333：iOS 的 A 轨走原生文件夹选择器（`UIDocumentPickerViewController`
    //   + 安全作用域）。**只在 iOS 宿主构造** —— macOS 有 NSOpenPanel、
    //   Linux/Windows 有各自的对话框（都走 file_picker），不需要这条通道。
    iosExport: currentAppHost == AppHost.ios
        ? MethodChannelIosFsExportBridge()
        : null,
  );
});

/// 生产分派：**桌面宿主 + iOS** ⇒ [HostFileSaveSaver]；其余 ⇒ [MethodChannelMediaStoreSaver]。
///
/// 判据用**宿主**（不是"能力位可不可用"）：Android 上 API < 29 且无写权限时，
/// MediaStore 也会 `isSupported() == false`，那时**不该**改走"按路径写盘"
/// （SAF 给的路径 `dart:io` 写不进去）—— 保持今天的"如实说不支持"。
///
/// ## ★★ 第 330 轮：iOS 必须一起进来（修一条"必然报错的入口"）
///
/// 原来的判据是 `isDesktop`（macOS/Linux/Windows）⇒ **iOS 落在
/// [MethodChannelMediaStoreSaver]**，而 `synhub/mediastore` **只有 Kotlin 一份**
/// ⇒ iOS 上这个按钮点下去**永远只回一句"这台设备不支持"**
/// （§2.0.56 的 D27：不给必然报错的入口；§2.0.57 的 D28 同型，只是平台漏了一个）。
///
/// iOS 的落点是**真的存在**的：
///   * `ios/Runner/Info.plist` 已有 `UIFileSharingEnabled=true` +
///     `LSSupportsOpeningDocumentsInPlace=true` ⇒ **App 的 Documents 目录本来就在
///     「文件」App 里可见**（`On My iPhone/SynHub`），而 B 轨正是
///     `<Documents>/downloads`（`save_destination.dart` 的裁决）；
///   * A 轨（用户现选目录）在 iOS 上天然拿不到：`FilePicker.getDirectoryPath`
///     是 **desktop-only** 的 API ⇒ `pickUserDirectoryForSave` 抛错 ⇒
///     `saveWithDualTrack` 捕获后走 B 轨（**不是**崩溃，也不是假成功）。
/// ⇒ 分派把 iOS 收进来，落点与文案立刻都对了（文案由结果的 `hostTrack` 位选，
/// 见 §2.0.57②），**不需要**新增能力位（`mediaStoreExport` 仍是 Android 语义）。
///
/// ★ 用 [currentAppHost] 而不是 [detectAppHost]：前者才认
/// `debugForceAppHost` 这个单测缝（否则 iOS 这一支永远无法离线验证）。
MediaStoreSaver fileExportSaverForHost({
  FsBookmarkBridge? bookmarks,
  RecentSaveDirectoryStore? recent,
  IosFsExportBridge? iosExport,
}) => _exportUsesLocalFilesystem(currentAppHost)
    ? HostFileSaveSaver(
        bookmarks: bookmarks,
        recent: recent,
        iosExport: iosExport,
      )
    : MethodChannelMediaStoreSaver();

/// 落点是不是"本机文件系统"（桌面 **+ iOS**）—— 拒绝 Android 的理由见上。
bool _exportUsesLocalFilesystem(AppHost h) => h.isDesktop || h == AppHost.ios;

/// 界面据此换文案：桌面/iOS 上的落点是"本机文件系统"，不是 Android 的「下载」目录。
bool fileExportUsesLocalFilesystem() =>
    _exportUsesLocalFilesystem(currentAppHost);

/// 宿主（macOS/Linux/Windows）上的导出：接到 `save_destination.dart` 的**双轨**上。
///
/// ## 为什么必须补这一条（这是修一个**死功能**，不是加新功能）
/// 界面上那个 `存到系统「下载」` 按钮读 [mediaStoreSaverProvider]，而
/// `synhub/mediastore` **只有 Kotlin 一份**（`kAndroidOnlyBridgeCapabilities`
/// 里的 `mediaStoreExport`）⇒ 在 macOS/Linux/Windows 上能力层恒为
/// `unavailable:not-implemented-on-host`，按钮永远只回一句"这台设备不支持"。
/// 与此同时 `lib/src/core/platform/save_destination.dart`（r55 的"文件保存双轨"，
/// 170 行 + 11 条用例）**在 App 里一个调用点都没有**（§2.0.45）——
/// 它正是为宿主准备的落点裁决。本类把两者接上：宿主的这条功能**从死路变成通路**。
///
/// * 用户选了目录 ⇒ A 轨（`user-selected.read-write` 的一次性沙箱扩展）；
/// * 用户取消 / 面板不可用 ⇒ B 轨（`<容器>/Documents/downloads`，免授权），
///   且**把绝对路径原样带回**（绝不"存好了却不说到哪了"）。
/// * 同名文件**绝不覆盖**（`saveFileToDirectory` 会自动加 ` (1)`）。
class HostFileSaveSaver implements MediaStoreSaver {
  HostFileSaveSaver({
    Future<String?> Function()? pickDirectory,
    PathProviderDirs? dirs,
    FsBookmarkBridge? bookmarks,
    RecentSaveDirectoryStore? recent,
    IosFsExportBridge? iosExport,
  }) : _pickDirectory = pickDirectory ?? pickUserDirectoryForSave,
       _dirs = dirs,
       _bookmarks = bookmarks,
       _recent = recent,
       _iosExport = iosExport;

  final Future<String?> Function() _pickDirectory;
  final PathProviderDirs? _dirs;

  /// 书签桥（**只有 macOS 有**）+ "上次选的目录"存储。
  ///
  /// 两个都注入才启用"记住目录"：Linux/Windows 的沙箱不是这种模型
  /// （路径字符串本来就够用）⇒ 它们保持"每次弹面板"的旧行为，**不假装也记住**。
  final FsBookmarkBridge? _bookmarks;
  final RecentSaveDirectoryStore? _recent;

  /// iOS 的文件夹选择器桥（其它宿主为 null ⇒ 行为与 r330 之前逐字一致）。
  final IosFsExportBridge? _iosExport;

  /// 生产用的目录选择器：`file_picker` 13 的静态 API（macOS = `NSOpenPanel`，
  /// 带 `canChooseDirectories`；Linux/Windows 走各自的文件对话框）。
  ///
  /// 面板**不在这里弹**（用例注入假选择器）⇒ 可离线测试。
  static Future<String?> pickUserDirectoryForSave() async {
    try {
      return await FilePicker.getDirectoryPath(
        dialogTitle: dataText('fsDownloadTaskSaveToLocal', '存到本机'),
      );
    } catch (_) {
      // 面板不可用（宿主没实现 / 用户取消时部分平台会抛）⇒ 交给 B 轨
      return null;
    }
  }

  @override
  Future<bool> isSupported() async => true;

  /// 当前开着的沙箱扩展（`stopAccess` 成对用；见 [saveToDownloads] 的 `finally`）。
  String? _openBookmark;

  /// 当前开着的 iOS 安全作用域句柄（`release` 成对用，同上）。
  String? _openIosToken;

  /// 选目录：**先试"上次选的那个"（安全作用域书签），没有再弹面板**。
  ///
  /// ★ 正确性判据**不是** `startAccess` 的返回值（同一个路径本进程已经开过时
  /// 系统会返回 false，而那时路径照样能写），而是**真写进去** —— 所以这里只管
  /// 把目录定出来，成败由 [saveWithDualTrack] + 上层回读判。
  ///
  /// 书签解析失败（目录被删 / 权限变了 / entitlement 没批）⇒ **忘掉它**并回落
  /// 弹面板（绝不"静默换个地方写"）。
  Future<String?> _resolveUserDirectory() async {
    // ★ r333：iOS 先走原生文件夹选择器（`file_picker` 的 `getDirectoryPath`
    //   在这个宿主上**是 desktop-only 的 API**，不接这条桥就永远只能落 B 轨）。
    //   用户取消 / 桥不可用 ⇒ 返回 null ⇒ 上游照旧退 B 轨。
    final ios = _iosExport;
    if (ios != null) {
      final picked = await ios.pickDirectory();
      if (picked == null) return null;
      // 授权**先持有到写完**：token 交给 `saveToDownloads` 的 finally 释放。
      _openIosToken = picked.token;
      return picked.path;
    }

    final bm = _bookmarks;
    final recent = _recent;
    if (bm == null || recent == null) return _pickDirectory();

    final remembered = await recent.read();
    if (remembered != null) {
      final acc = await bm.startAccess(remembered.bookmark);
      if (acc.ok && acc.path.isNotEmpty) {
        // 过期的书签**仍然能用**（`stale` 只表示"建议重新生成"）⇒ 本次照用，
        // 下次走"重新弹面板 + 重新生成"那条；这里不额外写盘。
        _openBookmark = remembered.bookmark;
        return acc.path;
      }
      // 失效 ⇒ 清掉，别让下一次再白解析一次
      await recent.clear();
    }

    final picked = await _pickDirectory();
    if (picked == null || picked.trim().isEmpty) return null;
    final dir = picked.trim();
    // 记住它：书签**生成失败也不影响本次保存**（只是下次还要弹面板），
    // 所以这里对 `create` 的失败**不报错**。
    final data = await bm.create(dir);
    if (data != null && data.isNotEmpty) {
      await recent.write(RecentSaveDirectory(path: dir, bookmark: data));
    }
    return dir;
  }

  @override
  Future<MediaStoreSaveResult> saveToDownloads({
    required String sourcePath,
    required String name,
    String mimeType = 'application/octet-stream',
  }) async {
    try {
      final r = await saveWithDualTrack(
        sourcePath: sourcePath,
        fileName: name,
        pickDirectory: _resolveUserDirectory,
        dirs: _dirs,
      );
      final saved = r.savedPath;
      if (saved == null || saved.isEmpty) {
        // 两轨都拿不到落点（容器目录都拿不到）⇒ 如实"不支持"，不是"失败"
        return MediaStoreSaveResult.unsupported(r.destination.reason, true);
      }
      return MediaStoreSaveResult.saved(saved, hostTrack: true);
    } catch (_) {
      // ★ `hostTrack: true` 三种结果都要带：界面**只**按这个位选文案
      //   （用"当前宿主是什么"会诱使文案跟着环境走，把 Android 的文案守卫
      //   变成"取决于跑用例的机器"——那是假绿/假红两头的来源）。
      return const MediaStoreSaveResult.failed('', true);
    } finally {
      // ★ 沙箱扩展**必须成对关**（拿过就关，成功失败都关）—— 否则扩展泄漏，
      //   长时间运行后系统会拒绝再开。
      final open = _openBookmark;
      _openBookmark = null;
      if (open != null) {
        unawaited(_bookmarks?.stopAccess(open) ?? Future<void>.value());
      }
      // iOS 的安全作用域同样**拿过就关**（成功失败都关）。
      final iosToken = _openIosToken;
      _openIosToken = null;
      if (iosToken != null) {
        unawaited(_iosExport?.release(iosToken) ?? Future<void>.value());
      }
    }
  }
}
/// 按文件名猜 MIME（只覆盖常见类型；猜不到给 `application/octet-stream`）。
///
/// 为什么要有：MediaStore 靠 MIME 决定归类，写错会让系统把它放进"其他"
/// 而不是"下载"，用户还是难找。
String mediaStoreMimeForName(String name) {
  final dot = name.lastIndexOf('.');
  if (dot < 0 || dot == name.length - 1) return 'application/octet-stream';
  switch (name.substring(dot + 1).toLowerCase()) {
    case 'pdf':
      return 'application/pdf';
    case 'txt':
    case 'md':
    case 'log':
      return 'text/plain';
    case 'csv':
      return 'text/csv';
    case 'json':
      return 'application/json';
    case 'xml':
      return 'application/xml';
    case 'html':
    case 'htm':
      return 'text/html';
    case 'zip':
      return 'application/zip';
    case '7z':
      return 'application/x-7z-compressed';
    case 'rar':
      return 'application/vnd.rar';
    case 'tar':
      return 'application/x-tar';
    case 'gz':
      return 'application/gzip';
    case 'doc':
      return 'application/msword';
    case 'docx':
      return 'application/vnd.openxmlformats-officedocument.wordprocessingml.document';
    case 'xls':
      return 'application/vnd.ms-excel';
    case 'xlsx':
      return 'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet';
    case 'ppt':
      return 'application/vnd.ms-powerpoint';
    case 'pptx':
      return 'application/vnd.openxmlformats-officedocument.presentationml.presentation';
    case 'jpg':
    case 'jpeg':
      return 'image/jpeg';
    case 'png':
      return 'image/png';
    case 'gif':
      return 'image/gif';
    case 'webp':
      return 'image/webp';
    case 'mp3':
      return 'audio/mpeg';
    case 'm4a':
      return 'audio/mp4';
    case 'flac':
      return 'audio/flac';
    case 'wav':
      return 'audio/wav';
    case 'mp4':
      return 'video/mp4';
    case 'mkv':
      return 'video/x-matroska';
    case 'mov':
      return 'video/quicktime';
    case 'epub':
      return 'application/epub+zip';
    default:
      return 'application/octet-stream';
  }
}
