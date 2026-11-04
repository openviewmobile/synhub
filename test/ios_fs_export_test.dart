// 第 333 轮：iOS 的 **A 轨**（用户现选目录）—— `synhub/iosfsexport`。
//
// 这一组要钉住三件事（缺一条这个桥就等于没接）：
//   ① **通道契约**：`{path, token, scoped}` / `cancelled` / 异常 三种回包各是什么语义
//      （取消与桥不可用**都**要退 B 轨，不许变成"失败"或"假成功）；
//   ② **接线**：iOS 宿主上 `HostFileSaveSaver` 真的先走这条桥（而不是 `file_picker`
//      的 desktop-only 的 `getDirectoryPath`）；
//   ③ **成对关闭**：拿过安全作用域就必须 `release` **恰好一次** —— 这是机制量
//      （只断言"存好了"会漏掉泄漏授权的半条；§2.0.30）。
//
// 判据一律取**真文件系统**（写进去的字节 + 绝对路径）与**假通道的调用记录**，
// 不碰真弹窗（弹窗本体在模拟器上也无法自动点击 ⇒ 见
// `docs/evidence-r333/README.md` 的未验清单）。
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import 'package:synhub/src/core/platform/app_paths.dart';
import 'package:synhub/src/core/platform/app_platform.dart';
import 'package:synhub/src/core/platform/ios_fs_export.dart';
import 'package:synhub/src/features/files/media_store_save.dart';

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

/// 假的原生桥：把"用户点了什么"和"release 被调了几次"都记下来。
class _FakeIosExport implements IosFsExportBridge {
  _FakeIosExport({this.picked, this.throwOnPick = false});

  IosPickedDirectory? picked;
  bool throwOnPick;
  int picks = 0;
  final List<String> released = [];

  @override
  Future<bool> isSupported() async => true;

  @override
  Future<IosPickedDirectory?> pickDirectory() async {
    picks++;
    if (throwOnPick) throw PlatformException(code: 'no_scene');
    return picked;
  }

  @override
  Future<void> release(String token) async => released.add(token);
}

/// 真通道（只用来验契约映射）：记录调用、按脚本回包。
class _ChannelHarness {
  _ChannelHarness(this.bridge);

  final MethodChannelIosFsExportBridge bridge;
  final List<MethodCall> calls = [];
  Object? Function(MethodCall)? reply;

  void install() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('synhub/iosfsexport'),
          (call) async {
            calls.add(call);
            return reply?.call(call);
          },
        );
  }

  void uninstall() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('synhub/iosfsexport'),
          null,
        );
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tmp;
  late _ChannelHarness harness;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('r333_iosfs_');
    // 能力门：只有宿主说自己是 iOS 时 `documentPicker` 才放行
    // （这条桥复用那个能力位 —— 它就是 iOS 的系统文档/目录选择器）。
    debugForceAppHost = AppHost.ios;
    harness = _ChannelHarness(MethodChannelIosFsExportBridge())..install();
  });

  tearDown(() {
    harness.uninstall();
    debugForceAppHost = null;
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  });

  File makeSrc(String name, List<int> bytes) =>
      File(p.join(tmp.path, name))..writeAsBytesSync(bytes);

  group('r333 iOS A 轨：通道契约', () {
    test('① 选中目录 ⇒ {path, token, scoped} 原样翻成记录', () async {
      harness.reply = (_) => <String, Object?>{
        'path': '/Users/x/iCloud Drive/存档',
        'token': 'T-1',
        'scoped': true,
      };
      final picked = await harness.bridge.pickDirectory();
      expect(picked, isNotNull);
      expect(picked!.path, '/Users/x/iCloud Drive/存档');
      expect(picked.token, 'T-1');
      expect(picked.scoped, isTrue, reason: '这条位只进诊断面板，不当"能不能写"的判据');
      expect(harness.calls.single.method, 'pickDirectory');
    });

    test('② 用户取消（cancelled:true）⇒ null（**不是**失败，也不是空路径）', () async {
      harness.reply = (_) => <String, Object?>{'cancelled': true};
      expect(await harness.bridge.pickDirectory(), isNull);
    });

    test('③ 反向：回了一个空 path ⇒ 同样当"没得用"（不许拿空路径去写盘）', () async {
      harness.reply = (_) => <String, Object?>{'path': '', 'token': 'T-2'};
      expect(await harness.bridge.pickDirectory(), isNull);
    });

    test('④ 原生报错（no_scene 等）⇒ null，**不抛**（否则整次保存变成失败）', () async {
      harness.reply = (_) => throw PlatformException(code: 'no_scene');
      expect(await harness.bridge.pickDirectory(), isNull);
    });

    test('⑤ release 把 token 原样发下去；空 token 不发（少打一次无用通道）', () async {
      harness.reply = (_) => null;
      await harness.bridge.release('T-9');
      expect(harness.calls.single.method, 'release');
      expect((harness.calls.single.arguments as Map)['token'], 'T-9');
      await harness.bridge.release('');
      expect(harness.calls.length, 1, reason: '空 token 不该再打通道');
    });

    test('⑥ 桥不在（通道缺失）⇒ isSupported=false、选目录 null（能力如实）', () async {
      final bare = MethodChannelIosFsExportBridge();
      // 没有任何 mock handler ⇒ `MissingPluginException`
      expect(await bare.isSupported(), isFalse);
      expect(await bare.pickDirectory(), isNull);
    });
  });

  group('r333 iOS A 轨：接进双轨（真文件系统 + 成对关闭）', () {
    test('⑦ iOS 上先走原生选择器：字节真的落进"用户选的目录"，且 release 恰好一次',
        () async {
      final chosen = Directory(p.join(tmp.path, 'chosen'))..createSync();
      final src = makeSrc('报告.bin', <int>[1, 2, 3, 4, 250]);
      final ios = _FakeIosExport(
        picked: IosPickedDirectory(
          path: chosen.path,
          token: 'TK-1',
          scoped: true,
        ),
      );
      // ★ 故意同时塞一个"会抛"的 file_picker 选择器：iOS 上**不许**再走它
      final saver = HostFileSaveSaver(
        pickDirectory: () async => throw UnsupportedError('getDirectoryPath'),
        iosExport: ios,
        dirs: _dirsFor(tmp),
      );
      final r = await saver.saveToDownloads(
        sourcePath: src.path,
        name: '报告.bin',
        mimeType: 'application/octet-stream',
      );

      expect(r.ok, isTrue);
      expect(r.hostTrack, isTrue);
      expect(r.uri, p.join(chosen.path, '报告.bin'));
      expect(
        File(r.uri!).readAsBytesSync(),
        <int>[1, 2, 3, 4, 250],
        reason: '判据取真字节，不是"返回值看起来对"',
      );
      expect(ios.picks, 1);
      expect(
        ios.released,
        ['TK-1'],
        reason: '★ 安全作用域必须成对关闭且只关一次（漏关 = 泄漏授权，多关 = 语义错）',
      );
    });

    test('⑧ 反向（成对关闭的另一半）：用户取消 ⇒ 落 B 轨（容器 downloads），'
        '**不** release 任何 token', () async {
      final src = makeSrc('取消.bin', <int>[7, 7]);
      final ios = _FakeIosExport(picked: null); // = 用户取消 / 桥不可用
      final saver = HostFileSaveSaver(
        iosExport: ios,
        dirs: _dirsFor(tmp),
      );
      final r = await saver.saveToDownloads(
        sourcePath: src.path,
        name: '取消.bin',
        mimeType: 'application/octet-stream',
      );

      expect(r.ok, isTrue, reason: 'B 轨（容器）永远拿得到 ⇒ 不许变成"失败"');
      expect(r.hostTrack, isTrue);
      expect(
        p.dirname(r.uri!),
        p.join(tmp.path, 'Documents', 'downloads'),
        reason: 'B 轨落点 = <Documents>/downloads（save_destination 的裁决）',
      );
      expect(File(r.uri!).existsSync(), isTrue);
      expect(ios.picks, 1);
      expect(ios.released, isEmpty, reason: '没拿过授权就不该有 release');
    });

    test('⑩ 桥实现抛异常（例如 picker_busy）⇒ 仍退 B 轨，保存**不许**变成失败',
        () async {
      final src = makeSrc('抛错.bin', <int>[3, 3, 3]);
      final ios = _FakeIosExport(throwOnPick: true);
      final saver = HostFileSaveSaver(iosExport: ios, dirs: _dirsFor(tmp));
      final r = await saver.saveToDownloads(
        sourcePath: src.path,
        name: '抛错.bin',
        mimeType: 'application/octet-stream',
      );
      expect(r.ok, isTrue);
      expect(
        p.dirname(r.uri!),
        p.join(tmp.path, 'Documents', 'downloads'),
        reason: '原生的 no_scene / picker_busy 只该让这次"用不上 A 轨"，'
            '不该把一次本来能成功的保存弄成失败',
      );
      expect(ios.released, isEmpty);
    });

    test('⑨ 同名不覆盖：两次存进同一目录 ⇒ 第二个自动加 ` (1)`（策略只有一份）',
        () async {
      final chosen = Directory(p.join(tmp.path, 'dup'))..createSync();
      final src = makeSrc('同名.bin', <int>[5]);
      final saver = HostFileSaveSaver(
        iosExport: _FakeIosExport(
          picked: IosPickedDirectory(path: chosen.path, token: 'TK-2', scoped: false),
        ),
        dirs: _dirsFor(tmp),
      );
      final a = await saver.saveToDownloads(
        sourcePath: src.path,
        name: '同名.bin',
        mimeType: 'application/octet-stream',
      );
      final b = await saver.saveToDownloads(
        sourcePath: src.path,
        name: '同名.bin',
        mimeType: 'application/octet-stream',
      );
      expect(a.uri, p.join(chosen.path, '同名.bin'));
      expect(
        b.uri,
        p.join(chosen.path, '同名 (1).bin'),
        reason: '★ 命名/不覆盖策略只能有一份实现（Dart 侧 saveFileToDirectory）—— '
            '让 Swift 也 copy 就会变成两份，迟早发散',
      );
      expect(File(a.uri!).existsSync(), isTrue);
      expect(File(b.uri!).existsSync(), isTrue);
    });

    test('⑪ 反向（r346）：`scoped` **只是诊断位** —— true/false 两种都要真落盘',
        () async {
      // ★ AGENTS §2.0.64③ / §2.0.58 同型：`scoped` 不许当"能不能写"的判据。
      //   iOS 的系统文档选择器在**同一台机器上**会给出 `scoped=true`（安全作用域
      //   已开）与 `scoped=false`（无需作用域，例如 App 容器内或本已可写）两种回包；
      //   拿它门控写盘 = 把"能写"的场景误判成不能写。
      //   判据取**真文件**，不取任何返回值（同 §2.0.58「判据取真文件而非 startAccess」）。
      for (final scoped in <bool>[true, false]) {
        final chosen = Directory(p.join(tmp.path, 'scoped_$scoped'))..createSync();
        final src = makeSrc('flag_$scoped.bin', <int>[1, 2, 3]);
        final saver = HostFileSaveSaver(
          iosExport: _FakeIosExport(
            picked:
                IosPickedDirectory(path: chosen.path, token: 'TK-$scoped', scoped: scoped),
          ),
          dirs: _dirsFor(tmp),
        );
        final r = await saver.saveToDownloads(
          sourcePath: src.path,
          name: 'flag_$scoped.bin',
          mimeType: 'application/octet-stream',
        );
        expect(r.uri, p.join(chosen.path, 'flag_$scoped.bin'),
            reason: 'scoped=$scoped 也必须写进用户选的目录');
        final f = File(r.uri!);
        expect(f.existsSync(), isTrue, reason: 'scoped=$scoped 必须真落盘（判据取真文件）');
        expect(f.readAsBytesSync(), <int>[1, 2, 3],
            reason: '不只是文件在，内容也要对（避免"建了个空文件"当成功）');
      }
    });
  });
}
