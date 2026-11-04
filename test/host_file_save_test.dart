// 第 328 轮：**宿主（macOS/Linux/Windows）上的"存到本机"** —— 死功能转正的守卫。
//
// 这一组用例要钉住的是**一个真缺陷的修复**，不是"新功能":
//   * 界面按钮（`_SaveToDownloadsButton`）读 `mediaStoreSaverProvider`；
//   * 而 `synhub/mediastore` **只有 Kotlin 一份** ⇒ 宿主上能力层恒
//     `unavailable:not-implemented-on-host` ⇒ 按钮永远只回"这台设备不支持"；
//   * 同时 `save_destination.dart`（r55 的双轨，170 行 + 11 条用例）**零调用点**。
// 现在路由器把两者接上（桌面 ⇒ 双轨；Android ⇒ MediaStore，行为不变）。
//
// 判据一律取**真文件系统**：写进去的字节、文件的绝对路径、同名不覆盖。
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import 'package:synhub/src/core/platform/app_paths.dart';
import 'package:synhub/src/core/platform/app_platform.dart';
import 'package:synhub/src/core/platform/fs_bookmark.dart';
import 'package:synhub/src/features/files/media_store_save.dart';

/// 指向测试临时目录的注入 dirs（不碰 `path_provider` 平台通道）。
PathProviderDirs _dirsFor(Directory root) => (
  support: () async =>
      Directory(p.join(root.path, 'support'))..createSync(recursive: true),
  documents: () async =>
      Directory(p.join(root.path, 'Documents'))..createSync(recursive: true),
  cache: () async =>
      Directory(p.join(root.path, 'cache'))..createSync(recursive: true),
  temp: () async => root,
  external: () async => null,
);

/// 假书签桥（记录调用；可指定三态）。
class _FakeBookmarks implements FsBookmarkBridge {
  _FakeBookmarks({this.resolvePath = '', this.createOk = true});

  String resolvePath;
  bool createOk;
  final List<String> started = [];
  final List<String> stopped = [];
  final List<String> created = [];

  @override
  Future<bool> isSupported() async => true;

  @override
  Future<String?> create(String path) async {
    created.add(path);
    return createOk ? 'BM:${path.replaceAll('/', '_')}' : null;
  }

  @override
  Future<FsBookmarkAccess> startAccess(String bookmark) async {
    started.add(bookmark);
    if (resolvePath.isEmpty) {
      return const FsBookmarkAccess(ok: false, reason: 'resolve-failed');
    }
    return FsBookmarkAccess(ok: true, path: resolvePath);
  }

  @override
  Future<void> stopAccess(String bookmark) async => stopped.add(bookmark);
}

class _MemRecentStore implements RecentSaveDirectoryStore {
  RecentSaveDirectory? value;
  int writes = 0;
  int clears = 0;

  @override
  Future<RecentSaveDirectory?> read() async => value;

  @override
  Future<void> write(RecentSaveDirectory v) async {
    value = v;
    writes++;
  }

  @override
  Future<void> clear() async {
    value = null;
    clears++;
  }
}

void main() {
  late Directory tmp;
  setUp(() => tmp = Directory.systemTemp.createTempSync('r328_hostsave_'));
  tearDown(() {
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  });

  File makeSrc(String name, List<int> bytes) =>
      File(p.join(tmp.path, name))..writeAsBytesSync(bytes);

  test('① 宿主分派：桌面宿主走本机文件系统（不是 MediaStore）', () {
    // 用例跑在宿主上（macOS/Linux CI）⇒ 必须走本机这条路；
    // 这条断言同时是"Android 行为不变"的反面：Android 上它必须是 false。
    expect(
      fileExportUsesLocalFilesystem(),
      isTrue,
      reason: '★ 桌面宿主必须走本机文件系统（否则"存到本机"永远是死路）',
    );
    expect(fileExportSaverForHost(), isA<HostFileSaveSaver>());
    // ★ 光有对的工厂不够：**生产注入点**必须真的用上它，否则又是
    //   "封装了但没有 caller"那一类（这一次是"有 caller 但没接线"）。
    final c = ProviderContainer();
    addTearDown(c.dispose);
    expect(
      c.read(mediaStoreSaverProvider),
      isA<HostFileSaveSaver>(),
      reason: '★ `mediaStoreSaverProvider` 的默认实现必须分派到宿主这条路',
    );
  });

  // =====================================================================
  // ★★ 第 330 轮：iOS 也必须走本机这条路（修一条"必然报错的入口"）
  // =====================================================================
  group('r330 iOS 导出分派', () {
    tearDown(() => debugForceAppHost = null);

    test('① iOS ⇒ HostFileSaveSaver（不是 MediaStore）+ 文案按"本机"走', () {
      debugForceAppHost = AppHost.ios;
      expect(
        fileExportSaverForHost(),
        isA<HostFileSaveSaver>(),
        reason: '★ iOS 上 `synhub/mediastore` 只有 Kotlin 一份 ⇒ 原实现是'
            '"点了必然回一句不支持"的死入口；iOS 的 Documents 目录本来就在'
            '「文件」App 里可见（Info.plist 的 UIFileSharingEnabled）',
      );
      expect(
        fileExportUsesLocalFilesystem(),
        isTrue,
        reason: 'iOS 的落点不是 Android 的「系统下载目录」⇒ 文案不能照抄 Android',
      );
      // 生产注入点同样要跟着宿主走（§2.0.45：有 caller 还得真接线）
      final c = ProviderContainer();
      addTearDown(c.dispose);
      expect(c.read(mediaStoreSaverProvider), isA<HostFileSaveSaver>());
    });

    test('② 反向：Android 仍然走 MediaStore、文案仍然是「下载」', () {
      debugForceAppHost = AppHost.android;
      expect(
        fileExportSaverForHost(),
        isA<MethodChannelMediaStoreSaver>(),
        reason: '★ 这条是 iOS 那一支的**反面**：Android 上 SAF 路径 `dart:io` 写不进去'
            '⇒ 绝不许把 Android 也改走"按路径写盘"（那会把"如实说不支持"变成假成功）',
      );
      expect(fileExportUsesLocalFilesystem(), isFalse);
      final c = ProviderContainer();
      addTearDown(c.dispose);
      expect(c.read(mediaStoreSaverProvider), isA<MethodChannelMediaStoreSaver>());
    });

    test('③ iOS 上 A 轨拿不到目录（getDirectoryPath 是 desktop-only）⇒ 落 B 轨，'
        '字节仍在、路径如实', () async {
      debugForceAppHost = AppHost.ios;
      final src = makeSrc('ios.bin', <int>[9, 8, 7, 0, 255]);
      final saver = HostFileSaveSaver(
        // 模拟 iOS 上 file_picker 抛 `unsupported`
        pickDirectory: () async => throw UnsupportedError('getDirectoryPath'),
        dirs: _dirsFor(tmp),
      );
      final r = await saver.saveToDownloads(
        sourcePath: src.path,
        name: 'ios.bin',
        mimeType: 'application/octet-stream',
      );
      expect(r.ok, isTrue);
      expect(r.hostTrack, isTrue, reason: '界面只按这个位选文案（§2.0.57②）');
      expect(r.uri, isNotNull);
      expect(File(r.uri!).readAsBytesSync(), <int>[9, 8, 7, 0, 255]);
      expect(r.uri, startsWith(tmp.path));
    });
  });

  test('② A 轨：用户选的目录 —— 字节逐字节落盘、路径如实返回', () async {
    final src = makeSrc('a.bin', <int>[1, 2, 3, 0, 255, 7]);
    final picked = Directory(p.join(tmp.path, 'picked'))..createSync();
    final saver = HostFileSaveSaver(
      pickDirectory: () async => picked.path,
      dirs: _dirsFor(tmp),
    );
    final r = await saver.saveToDownloads(sourcePath: src.path, name: 'a.bin');
    expect(r.ok, isTrue);
    expect(r.unsupported, isFalse);
    expect(
      r.hostTrack,
      isTrue,
      reason: '★ 界面据此把**绝对路径**说出来（容器目录用户猜不到）',
    );
    expect(r.uri, p.join(picked.path, 'a.bin'));
    expect(
      File(r.uri!).readAsBytesSync(),
      <int>[1, 2, 3, 0, 255, 7],
      reason: '★ 判据是**真文件系统**上的字节，不是"回了 ok"',
    );
  });

  test('③ B 轨：用户取消 ⇒ 落到容器 downloads，且路径仍然如实返回', () async {
    final src = makeSrc('b.bin', <int>[9, 8, 7]);
    final saver = HostFileSaveSaver(
      pickDirectory: () async => null, // 取消
      dirs: _dirsFor(tmp),
    );
    final r = await saver.saveToDownloads(sourcePath: src.path, name: 'b.bin');
    expect(r.ok, isTrue);
    expect(r.hostTrack, isTrue);
    final dir = await AppPaths.downloadsDirectory(dirs: _dirsFor(tmp));
    expect(
      r.uri,
      p.join(dir.path, 'b.bin'),
      reason: 'B 轨的落点必须就是容器下载目录（不静默换地方）',
    );
    expect(File(r.uri!).readAsBytesSync(), <int>[9, 8, 7]);
  });

  test('④ **绝不覆盖**同名文件：第二次自动加 ` (1)`', () async {
    final src = makeSrc('c.bin', <int>[1]);
    final picked = Directory(p.join(tmp.path, 'picked2'))..createSync();
    final saver = HostFileSaveSaver(
      pickDirectory: () async => picked.path,
      dirs: _dirsFor(tmp),
    );
    final first = await saver.saveToDownloads(sourcePath: src.path, name: 'c.bin');
    final second = await saver.saveToDownloads(
      sourcePath: src.path,
      name: 'c.bin',
    );
    expect(first.uri, p.join(picked.path, 'c.bin'));
    expect(
      second.uri,
      p.join(picked.path, 'c (1).bin'),
      reason: '★ 同名不覆盖是硬要求（用户已有文件不许被悄悄换掉）',
    );
    expect(File(first.uri!).existsSync(), isTrue, reason: '第一份必须还在');
  });

  test('⑤ 源文件不存在 ⇒ 如实失败（不是"不支持"，也不是假装成功）', () async {
    final picked = Directory(p.join(tmp.path, 'picked3'))..createSync();
    final saver = HostFileSaveSaver(
      pickDirectory: () async => picked.path,
      dirs: _dirsFor(tmp),
    );
    final r = await saver.saveToDownloads(
      sourcePath: p.join(tmp.path, 'nope.bin'),
      name: 'nope.bin',
    );
    expect(r.ok, isFalse);
    expect(r.unsupported, isFalse, reason: '这是失败，不是"这台设备不支持"');
    expect(
      r.hostTrack,
      isTrue,
      reason: '★ 失败也要带"本机路径轨"位：界面**只**按这个位选文案，'
          '否则桌面上的失败会显示 Android 的"存入系统「下载」目录失败"',
    );
    expect(picked.listSync(), isEmpty, reason: '失败时不许留下半份文件');
  });

  test('⑥ 两轨都拿不到落点 ⇒ `unsupported`（带原因码），不是崩溃', () async {
    final src = makeSrc('d.bin', <int>[1, 2]);
    // record 字面量（`PathProviderDirs` 是 typedef，没有构造函数）
    final brokenDirs = (
      support: () async => throw StateError('no support dir'),
      documents: () async => throw StateError('no documents dir'),
      cache: () async => throw StateError('no cache dir'),
      temp: () async => throw StateError('no temp dir'),
      external: () async => null,
    );
    final saver = HostFileSaveSaver(
      pickDirectory: () async => null,
      dirs: brokenDirs,
    );
    final r = await saver.saveToDownloads(sourcePath: src.path, name: 'd.bin');
    expect(r.ok, isFalse);
    expect(r.unsupported, isTrue, reason: '取不到落点是"不支持"，要能与"失败"区分');
    expect(r.hostTrack, isTrue, reason: '同上：三种结果都要带本机路径轨位');
    expect(r.reason, isNotEmpty, reason: '要给界面一个机器可读原因码');
  });

  // ---- ★ 第 328 轮（backlog §3.4）：**记住用户选的目录**（安全作用域书签）----
  //
  // 这一组的判据全部取**真文件系统 + 调用记录**："记住了"不等于"下次真的用上了"。
  group('第 328 轮：宿主"记住上次选的目录"（书签）', () {
    test('⑦ 有书签 ⇒ **不弹面板**、写进记住的目录、扩展成对关闭', () async {
      final src = makeSrc('bm.bin', <int>[5, 6, 7]);
      final rememberedDir = Directory(p.join(tmp.path, 'remembered'))
        ..createSync();
      var panelCalls = 0;
      final bm = _FakeBookmarks(resolvePath: rememberedDir.path);
      final recent = _MemRecentStore()
        ..value = const RecentSaveDirectory(path: '/old', bookmark: 'BM_OLD');
      final saver = HostFileSaveSaver(
        pickDirectory: () async {
          panelCalls++;
          return null;
        },
        dirs: _dirsFor(tmp),
        bookmarks: bm,
        recent: recent,
      );

      final r = await saver.saveToDownloads(sourcePath: src.path, name: 'bm.bin');
      expect(r.ok, isTrue);
      expect(
        panelCalls,
        0,
        reason: '★ 记住之后**不该**再弹面板（这就是这条功能的全部意义）',
      );
      expect(r.uri, p.join(rememberedDir.path, 'bm.bin'));
      expect(File(r.uri!).readAsBytesSync(), <int>[5, 6, 7]);
      expect(bm.started, ['BM_OLD'], reason: '必须用**存下来的那个**书签解析');
      expect(
        bm.stopped,
        ['BM_OLD'],
        reason: '★ 沙箱扩展必须成对关（泄漏会让后续 start 被系统拒绝）',
      );
      expect(recent.clears, 0, reason: '解析成功就不许把记录清掉');
    });

    test('⑧ 书签失效 ⇒ 清掉记录 + 回落弹面板 + **写入新书签**', () async {
      final src = makeSrc('bm2.bin', <int>[1]);
      final picked = Directory(p.join(tmp.path, 'picked_bm'))..createSync();
      final bm = _FakeBookmarks(resolvePath: ''); // 解析失败
      final recent = _MemRecentStore()
        ..value = const RecentSaveDirectory(path: '/gone', bookmark: 'BM_GONE');
      final saver = HostFileSaveSaver(
        pickDirectory: () async => picked.path,
        dirs: _dirsFor(tmp),
        bookmarks: bm,
        recent: recent,
      );

      final r = await saver.saveToDownloads(sourcePath: src.path, name: 'bm2.bin');
      expect(r.ok, isTrue);
      expect(r.uri, p.join(picked.path, 'bm2.bin'));
      expect(recent.value, isNotNull, reason: '弹面板选完之后要重新记住');
      expect(recent.value!.path, picked.path);
      expect(bm.created, [picked.path], reason: '给新目录生成书签');
      expect(
        bm.stopped,
        isEmpty,
        reason: '解析失败时**没有**开过扩展 ⇒ 不该乱关（会把别人的扩展关掉）',
      );
    });

    test('⑨ 首次（没记住过）⇒ 弹面板 + 记住；`create` 失败也不碍本次保存', () async {
      final src = makeSrc('bm3.bin', <int>[2]);
      final picked = Directory(p.join(tmp.path, 'picked_bm3'))..createSync();
      final bm = _FakeBookmarks(createOk: false); // 书签生成失败
      final recent = _MemRecentStore();
      final saver = HostFileSaveSaver(
        pickDirectory: () async => picked.path,
        dirs: _dirsFor(tmp),
        bookmarks: bm,
        recent: recent,
      );

      final r = await saver.saveToDownloads(sourcePath: src.path, name: 'bm3.bin');
      expect(
        r.ok,
        isTrue,
        reason: '★ 记不住只是"下次还要弹面板"，**不是**保存失败',
      );
      expect(File(r.uri!).readAsBytesSync(), <int>[2]);
      expect(recent.value, isNull, reason: '生成失败 ⇒ 不写半条坏记录');
      expect(recent.writes, 0);
    });

    test('⑩ 没注入书签（Linux/Windows 形态）⇒ 行为与 r328 之前**逐字一致**', () async {
      final src = makeSrc('bm4.bin', <int>[3]);
      final picked = Directory(p.join(tmp.path, 'picked_bm4'))..createSync();
      var panelCalls = 0;
      final saver = HostFileSaveSaver(
        pickDirectory: () async {
          panelCalls++;
          return picked.path;
        },
        dirs: _dirsFor(tmp),
      );
      final r = await saver.saveToDownloads(sourcePath: src.path, name: 'bm4.bin');
      expect(r.ok, isTrue);
      expect(panelCalls, 1, reason: '每次都弹（这两个宿主没有书签模型）');
      expect(r.uri, p.join(picked.path, 'bm4.bin'));
    });
  });

}

