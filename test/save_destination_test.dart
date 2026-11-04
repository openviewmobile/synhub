// 第 55 轮：macOS 沙盒下"文件保存双轨"的守卫用例。
//
// 这一组用例的目标是**给出真实证据**，而不是"文档里说应该可以"：
//   ① 容器轨（B）：在**真 macOS 文件系统**上跑 —— 解析路径 → 写盘 → 读回字节，
//      并断言路径确实在 `…/Documents/downloads` 下；
//   ② 用户选择轨（A）：面板交互本身无法离线自动化，但**裁决逻辑**与**落盘**
//      都能离线钉死（注入假面板给一个宿主临时目录），并且 entitlement
//      `com.apple.security.files.user-selected.read-write` 必须**真的在仓库里**
//      （读 `macos/Runner/*.entitlements` 原文，不是"我记得配了"）；
//   ③ **绝不覆盖**同名文件；
//   ④ 两条轨都要能说出**文件到底在哪**（`savedPath` 指向真文件）。
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import 'package:synhub/src/core/platform/app_paths.dart';
import 'package:synhub/src/core/platform/app_platform.dart';
import 'package:synhub/src/core/platform/save_destination.dart';

/// 一套指向测试临时目录的注入 dirs（不碰 path_provider 平台通道）。
PathProviderDirs _dirsFor(Directory root) => (
  support: () async => Directory(p.join(root.path, 'support'))..createSync(recursive: true),
  documents: () async => Directory(p.join(root.path, 'Documents'))..createSync(recursive: true),
  cache: () async => Directory(p.join(root.path, 'cache'))..createSync(recursive: true),
  temp: () async => root,
  external: () async => null,
);

void main() {
  late Directory tmp;
  setUp(() => tmp = Directory.systemTemp.createTempSync('r55_save_'));
  tearDown(() {
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  });

  File makeSrc(String text) =>
      File(p.join(tmp.path, 'src.bin'))..writeAsBytesSync(text.codeUnits);

  group('第 55 轮：保存落点裁决（双轨）', () {
    test('给了用户选的目录 ⇒ 走 A，原因码 user-selected', () async {
      final d = await resolveSaveDestination(
        userSelectedDirectory: '/Users/someone/Desktop',
        dirs: _dirsFor(tmp),
      );
      expect(d.track, SaveTrack.userSelected);
      expect(d.directory, '/Users/someone/Desktop');
      expect(d.reason, 'user-selected');
      expect(d.ok, isTrue);
    });

    test('没给（用户取消/面板不可用）⇒ 退 B（容器下载目录）', () async {
      final d = await resolveSaveDestination(dirs: _dirsFor(tmp));
      expect(d.track, SaveTrack.container);
      expect(d.reason, 'container');
      expect(d.ok, isTrue);
      expect(d.directory, endsWith(p.join('Documents', 'downloads')));
    });

    test('不注入 dirs（真 path_provider）：拿不到目录时**如实回原因**，不抛', () async {
      // `flutter test` 进程里没有 path_provider 的平台实现 ⇒ 解析必须
      // 降级成"没有落点 + 机器可读原因"，而不是把 MissingPluginException
      // 抛给界面。（沙箱 .app 内 path_provider 正常，见 docs/platform-macos.md §5。）
      final d = await resolveSaveDestination();
      if (!d.ok) {
        expect(d.track, SaveTrack.container);
        expect(d.reason, isNotEmpty);
      }
      // 真文件系统的写入证据在下面「落盘证据」组（用注入目录，真盘真字节）。
    });
  });

  group('第 55 轮：落盘证据（真文件系统，写→读回）', () {
    test('写进去的字节读回来一模一样，返回真路径', () async {
      final dir = Directory(p.join(tmp.path, 'out'))..createSync();
      final src = makeSrc('hello-synhub');
      final saved = await saveFileToDirectory(
        sourcePath: src.path,
        fileName: 'report.txt',
        directory: dir.path,
      );
      final f = File(saved);
      expect(f.existsSync(), isTrue);
      expect(f.readAsStringSync(), 'hello-synhub');
      expect(saved, p.join(dir.path, 'report.txt'));
    });

    test('★ 同名已存在 ⇒ 绝不覆盖，自动加 (1)', () async {
      final dir = Directory(p.join(tmp.path, 'out2'))..createSync();
      final src = makeSrc('new');
      final first = await saveFileToDirectory(
        sourcePath: src.path,
        fileName: 'a.txt',
        directory: dir.path,
      );
      File(first).writeAsStringSync('original');
      final second = await saveFileToDirectory(
        sourcePath: src.path,
        fileName: 'a.txt',
        directory: dir.path,
      );
      expect(second, isNot(first));
      expect(second, p.join(dir.path, 'a (1).txt'));
      expect(File(first).readAsStringSync(), 'original', reason: '原文件不许被动');
      expect(File(second).readAsStringSync(), 'new');
    });

    test('源文件不存在 ⇒ 如实抛（调用方按失败处理，不假装成功）', () async {
      final dir = Directory(p.join(tmp.path, 'out3'))..createSync();
      await expectLater(
        saveFileToDirectory(
          sourcePath: p.join(tmp.path, 'nope.bin'),
          fileName: 'nope.bin',
          directory: dir.path,
        ),
        throwsA(isA<FileSystemException>()),
      );
    });
  });

  group('第 55 轮：双轨端到端（面板用假实现，落盘走真文件系统）', () {
    test('A：用户选了目录 ⇒ 存在那里，savedPath 指真文件', () async {
      final src = makeSrc('via-A');
      final pick = Directory(p.join(tmp.path, 'picked'))..createSync();
      final r = await saveWithDualTrack(
        sourcePath: src.path,
        fileName: 'x.txt',
        pickDirectory: () async => pick.path,
        dirs: _dirsFor(tmp),
      );
      expect(r.destination.track, SaveTrack.userSelected);
      expect(r.cancelled, isFalse);
      expect(r.savedPath, isNotNull);
      expect(File(r.savedPath!).readAsStringSync(), 'via-A');
      expect(p.dirname(r.savedPath!), pick.path);
    });

    test('B：用户取消 ⇒ 退容器轨，仍保存成功且如实给出路径', () async {
      final src = makeSrc('via-B');
      final r = await saveWithDualTrack(
        sourcePath: src.path,
        fileName: 'y.txt',
        pickDirectory: () async => null,
        dirs: _dirsFor(tmp),
      );
      expect(r.destination.track, SaveTrack.container);
      expect(r.cancelled, isTrue);
      expect(r.savedPath, isNotNull);
      expect(File(r.savedPath!).readAsStringSync(), 'via-B');
      expect(r.savedPath, startsWith(r.destination.directory));
    });
  });

  group('第 55 轮：entitlement 是仓库里的事实（读原文）', () {
    test('user-selected.read-write 真的在 Debug/Release entitlements 里', () {
      for (final name in const ['DebugProfile.entitlements', 'Release.entitlements']) {
        final f = File(p.join('macos', 'Runner', name));
        expect(f.existsSync(), isTrue, reason: '$name 必须在仓库里');
        final s = f.readAsStringSync();
        expect(
          s,
          contains('com.apple.security.files.user-selected.read-write'),
          reason: '$name 少了用户选择路径的授权（沙盒下 A 轨会失败）',
        );
      }
    });

    test('★ r328：bookmarks.app-scope **已申请且有人用**（第 55 轮那条"尚未申请"的缺口已闭）', () {
      // 第 55 轮这条是**如实记录缺口**（"申请了却不用 = 空权限"）。
      // 第 328 轮把跨启动书签真做出来了（`FsBookmarkBridge` + `HostFileSaveSaver`）
      // ⇒ 缺口关闭：两份 entitlements 都必须有，且 `lib/` 里必须真有调用点
      //   （§2.0.45：申请了权限却没人用 = 空权限，同样是缺陷）。
      for (final name in const ['DebugProfile.entitlements', 'Release.entitlements']) {
        final s = File(p.join('macos', 'Runner', name)).readAsStringSync();
        expect(
          s,
          contains('com.apple.security.files.bookmarks.app-scope'),
          reason: '$name 少了书签授权 ⇒ A 轨"记住上次选的目录"跨启动会断',
        );
      }
      final users = <String>[];
      for (final e in Directory('lib').listSync(recursive: true)) {
        if (e is! File || !e.path.endsWith('.dart')) continue;
        if (e.readAsStringSync().contains('AppCapability.fsBookmark')) {
          users.add(e.path);
        }
      }
      expect(
        users.length,
        greaterThanOrEqualTo(3),
        reason: '★ 能力位/桥/接线都要用它（否则就是"申请了空权限"）；实际：${users.join(' / ')}',
      );
    });

    test('宿主能力表：documentPicker 可用（A 轨面板存在）、mediaStoreExport 不可用', () {
      final caps = staticCapabilitiesFor(AppHost.macos);
      expect(caps.can(AppCapability.documentPicker), isTrue);
      expect(caps.can(AppCapability.mediaStoreExport), isFalse);
      expect(
        caps.reasonOf(AppCapability.mediaStoreExport),
        CapabilityReason.notImplementedOnHost,
      );
    });
  });
}
