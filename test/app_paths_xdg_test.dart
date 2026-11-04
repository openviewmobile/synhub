// ★★★ P0-2 回归（Linux 站，第 109 轮）：文档目录**按 XDG 回落，降级而不是抛**
//
// 背景（原始堆栈见 `docs/platform-linux.md` §8.4 缺陷 2）：amd64 容器 + Xvfb
// 真跑时 `getApplicationDocumentsDirectory()` 抛
// `MissingPlatformDirectoryException(Unable to get application documents directory)`
// **×5**（经 `drift_flutter` 的 `driftDatabase.databaseFile`）⇒ **drift 本地库
// 在 Linux 上根本建不起来**。根因：容器/最小发行版没有 `xdg-user-dirs` /
// `~/.config/user-dirs.dirs`。
//
// 本文件要钉四件事：
//   ① XDG 回落链（`$XDG_DATA_HOME` → `<home>/.local/share` → `<home>`）是**纯函数**，
//      逐级可测；
//   ② `AppPaths.documentsDirectory` 在 Linux + 目录拿不到时**降级不抛**，并真建目录；
//   ③ ★ **反向断言：未被证伪的平台一个字节都不许变** —— macOS/iOS/Android/web/
//      unknown 拿不到就原样重抛（AGENTS §2.0.22 第 3 条）；
//   ③b ★★ **r348 翻位（有真机证据）**：Windows 从"原样重抛"改成"按
//      `%LOCALAPPDATA%` 回落" —— 证据：真 Windows guest 上以 SYSTEM 起进程时
//      `MissingPlatformDirectoryException` 让 drift 建不起来
//      （`docs/platform-windows.md` §17.4）。★ 这正是那组反向断言存在的意义：
//      **翻位必须显式改用例**，不许悄悄变。
//   ④ 两个 drift 库**真的接上了**这条路径（静态扫描源码，防止被改回去）。
//
// ⚠️ 本文件**一次都不碰真平台通道**（`PathProviderDirs` 全部注入），
// 所以不会像 §2.0.20⑤ 那样在 `flutter test` 里挂起。
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'package:synhub/src/core/platform/app_paths.dart';
import 'package:synhub/src/core/platform/app_platform.dart';

/// 一组"问什么抛什么"的注入目录 —— 模拟容器里 path_provider 的真实行为。
PathProviderDirs _throwingDirs(Object Function() makeError) => (
  support: () async => throw makeError(),
  documents: () async => throw makeError(),
  cache: () async => throw makeError(),
  temp: () async => throw makeError(),
  external: () async => null,
);

/// 一组"documents 正常返回 [dir]"的注入目录。
PathProviderDirs _okDirs(Directory dir) => (
  support: () async => dir,
  documents: () async => dir,
  cache: () async => dir,
  temp: () async => dir,
  external: () async => null,
);

EnvironmentLookup _env(Map<String, String> map) => (name) => map[name];

void main() {
  group('P0-2 纯函数：linuxXdgDataBase 回落链', () {
    test('① XDG_DATA_HOME 优先（绝对路径）', () {
      expect(
        AppPaths.linuxXdgDataBase(_env({'XDG_DATA_HOME': '/xdg/data', 'HOME': '/h'})),
        '/xdg/data',
      );
    });

    test('② 没有 XDG_DATA_HOME → HOME/.local/share', () {
      expect(AppPaths.linuxXdgDataBase(_env({'HOME': '/h'})), '/h/.local/share');
    });

    test('③ XDG_DATA_HOME 是空串/空白 → 跳过它，走 HOME', () {
      expect(
        AppPaths.linuxXdgDataBase(_env({'XDG_DATA_HOME': '   ', 'HOME': '/h'})),
        '/h/.local/share',
      );
    });

    test('④ 规范要求 XDG_DATA_HOME 必须是绝对路径；相对路径不算数', () {
      expect(
        AppPaths.linuxXdgDataBase(
          _env({'XDG_DATA_HOME': 'relative/dir', 'HOME': '/h'}),
        ),
        '/h/.local/share',
        reason: 'XDG 基础目录规范：相对路径必须被忽略',
      );
    });

    test('⑤ 三者都拿不到 → null（调用方据此决定"仍要抛"）', () {
      expect(AppPaths.linuxXdgDataBase(_env({})), isNull);
      expect(AppPaths.linuxXdgDataBase(_env({'HOME': '  '})), isNull);
      expect(AppPaths.linuxXdgDataBase(_env({'HOME': 'relative'})), isNull);
    });
  });

  group('r348 纯函数：windowsDataBase 回落链', () {
    test('① LOCALAPPDATA 优先（Windows 绝对路径）', () {
      expect(
        AppPaths.windowsDataBase(
          _env({'LOCALAPPDATA': r'C:\Users\dev\AppData\Local', 'APPDATA': r'C:\Users\dev\AppData\Roaming'}),
        ),
        r'C:\Users\dev\AppData\Local',
      );
    });

    test('② 没有 LOCALAPPDATA → APPDATA（漫游）', () {
      expect(
        AppPaths.windowsDataBase(_env({'APPDATA': r'C:\Users\dev\AppData\Roaming'})),
        r'C:\Users\dev\AppData\Roaming',
      );
    });

    test('③ 两个都没有 → USERPROFILE\\AppData\\Local', () {
      expect(
        AppPaths.windowsDataBase(_env({'USERPROFILE': r'C:\Users\dev'})),
        p.windows.join(r'C:\Users\dev', 'AppData', 'Local'),
        reason: '★ 必须用 p.windows 拼（本仓用例跑在 POSIX 宿主上，宿主分隔符会拼错）',
      );
    });

    test('④ 空白/相对路径不算数（与 linuxXdgDataBase 同一判据）', () {
      expect(
        AppPaths.windowsDataBase(_env({'LOCALAPPDATA': '   ', 'APPDATA': r'relative\\dir'})),
        isNull,
      );
    });

    test('⑤ 三个都拿不到 → null（调用方据此决定"仍要抛"）', () {
      expect(AppPaths.windowsDataBase(_env({})), isNull);
      expect(AppPaths.windowsDataBase(_env({'LOCALAPPDATA': '/posix/only'})), isNull,
          reason: 'POSIX 绝对路径不是 Windows 绝对路径');
    });
  });

  group('P0-2 documentsDirectory：Linux 降级不抛', () {
    late Directory tmp;
    setUp(() => tmp = Directory.systemTemp.createTempSync('r109_xdg_'));
    tearDown(() {
      if (tmp.existsSync()) tmp.deleteSync(recursive: true);
    });

    test('Linux + XDG_DATA_HOME → 回落并**真建出** <base>/synhub', () async {
      final base = Directory('${tmp.path}/xdg');
      final out = await AppPaths.documentsDirectory(
        dirs: _throwingDirs(
          () => MissingPlatformDirectoryException(
            'Unable to get application documents directory',
          ),
        ),
        hostOverride: AppHost.linux,
        env: _env({'XDG_DATA_HOME': base.path}),
      );
      expect(out.path, '${base.path}/synhub');
      expect(out.existsSync(), isTrue, reason: 'drift 只建文件不建目录');
    });

    test('Linux + 只有 HOME → <HOME>/.local/share/synhub', () async {
      final out = await AppPaths.documentsDirectory(
        dirs: _throwingDirs(() => const SocketException('nope')),
        hostOverride: AppHost.linux,
        env: _env({'HOME': tmp.path}),
      );
      expect(out.path, '${tmp.path}/.local/share/synhub');
      expect(out.existsSync(), isTrue);
    });

    test('Linux + create:false → 给路径但不建目录', () async {
      final out = await AppPaths.documentsDirectory(
        dirs: _throwingDirs(() => const SocketException('nope')),
        hostOverride: AppHost.linux,
        env: _env({'HOME': tmp.path}),
        create: false,
      );
      expect(out.path, '${tmp.path}/.local/share/synhub');
      expect(out.existsSync(), isFalse);
    });

    test('Linux + 连 HOME 都没有 → 这条链走到头，仍然抛（不是静默给错路径）',
        () async {
      await expectLater(
        AppPaths.documentsDirectory(
          dirs: _throwingDirs(
            () => MissingPlatformDirectoryException(
              'Unable to get application documents directory',
            ),
          ),
          hostOverride: AppHost.linux,
          env: _env({}),
        ),
        throwsA(isA<MissingPlatformDirectoryException>()),
      );
    });

    test('Linux + path_provider 正常（装了 xdg-user-dirs）→ 原样用它，不回落',
        () async {
      final docs = Directory('${tmp.path}/Documents')..createSync();
      final out = await AppPaths.documentsDirectory(
        dirs: _okDirs(docs),
        hostOverride: AppHost.linux,
        env: _env({'HOME': tmp.path}),
      );
      expect(out.path, docs.path, reason: '有机器的~/Documents 时不该抢到 XDG 去');
    });
  });

  group('r348 ★ Windows 已翻位：拿不到 documents ⇒ 按 LOCALAPPDATA 回落', () {
    test('Windows + LOCALAPPDATA ⇒ <LOCALAPPDATA>\\synhub（不抛）', () async {
      final out = await AppPaths.documentsDirectory(
        dirs: _throwingDirs(
          () => MissingPlatformDirectoryException(
            'Unable to get application documents directory',
          ),
        ),
        hostOverride: AppHost.windows,
        env: _env({'LOCALAPPDATA': r'C:\Users\dev\AppData\Local'}),
        // ★ create:false 是**有理由的**：Windows 路径在 POSIX 宿主上真建目录
        //   只会造出一个名叫 `C:\Users...` 的奇怪文件 ⇒ 「真建出来」这一半
        //   由 Windows guest 上跑真家伙来钉（`docs/platform-windows.md` §17.4）。
        create: false,
      );
      expect(out.path, p.windows.join(r'C:\Users\dev\AppData\Local', 'synhub'));
    });

    test('★ 反向：Windows 只走 LOCALAPPDATA，**绝不**串到 Linux 的 XDG 里', () async {
      final out = await AppPaths.documentsDirectory(
        dirs: _throwingDirs(() => const SocketException('nope')),
        hostOverride: AppHost.windows,
        env: _env({
          'LOCALAPPDATA': r'C:\Users\dev\AppData\Local',
          'XDG_DATA_HOME': '/xdg',
          'HOME': '/h',
        }),
        create: false,
      );
      expect(out.path, isNot(contains('xdg')));
      expect(out.path, p.windows.join(r'C:\Users\dev\AppData\Local', 'synhub'));
    });

    test('★ 反向：Windows 连 LOCALAPPDATA/APPDATA/USERPROFILE 都没有 ⇒ 仍原样重抛',
        () async {
      final err = MissingPlatformDirectoryException(
        'Unable to get application documents directory',
      );
      Object? caught;
      try {
        await AppPaths.documentsDirectory(
          dirs: _throwingDirs(() => err),
          hostOverride: AppHost.windows,
          env: _env({}),
        );
      } catch (e) {
        caught = e;
      }
      expect(caught, same(err), reason: '回落链走到头就得抛，不许静默给错路径');
    });
  });

  group('P0-2 ★ 反向断言：其余平台行为逐字节不变', () {
    test('macOS / iOS / Android：原样重抛，绝不串到 Linux/Windows 的回落里', () async {
      for (final host in const [
        AppHost.macos,
        AppHost.ios,
        AppHost.android,
        AppHost.web,
        AppHost.unknown,
      ]) {
        final err = StateError('no documents on $host');
        Object? caught;
        try {
          await AppPaths.documentsDirectory(
            dirs: _throwingDirs(() => err),
            hostOverride: host,
            env: _env({'XDG_DATA_HOME': '/xdg', 'HOME': '/h'}),
          );
        } catch (e) {
          caught = e;
        }
        expect(caught, same(err), reason: '$host 不该走 XDG 回落');
      }
    });

    test('非 Linux + path_provider 正常 → 与直接调 path_provider 等价', () async {
      final tmp = Directory.systemTemp.createTempSync('r109_win_');
      addTearDown(() {
        if (tmp.existsSync()) tmp.deleteSync(recursive: true);
      });
      for (final host in const [AppHost.windows, AppHost.macos, AppHost.ios]) {
        final out = await AppPaths.documentsDirectory(
          dirs: _okDirs(tmp),
          hostOverride: host,
        );
        expect(out.path, tmp.path);
      }
    });
  });

  group('P0-2 接线：两个 drift 库都必须走这条路径（静态扫描，防回退）', () {
    // ★ 第 338 轮订正：r334 把"库里怎么连"拆到连接层（条件导入）之后，
    // 原来只扫 `analytics_database.dart` 的判据就**失效变红**了 —— 现在要
    // **跟着间接走**：原生连接层是真正把 documentsDirectory 交给 drift 的地方，
    // 同时钉住 `AnalyticsDatabase.open` 确实走那层连接（防止有人绕过它）。
    test('ChatDatabase / AnalyticsDatabase 的原生连接都传了 databaseDirectory', () {
      final chat = File('lib/src/data/local/database.dart').readAsStringSync();
      expect(
        chat.contains('databaseDirectory: AppPaths.documentsDirectory'),
        isTrue,
        reason: 'database.dart 又变回裸 driftDatabase(name:) 了 —— '
            'Linux 上会重新抛 MissingPlatformDirectoryException',
      );
      expect(chat.contains('driftDatabase(name:'), isFalse);

      final ana = File('lib/src/data/local/analytics_database.dart').readAsStringSync();
      expect(
        ana.contains('analyticsConnection()'),
        isTrue,
        reason: 'AnalyticsDatabase.open 必须走连接层（否则这条 XDG 路径被绕过）',
      );
      expect(ana.contains('driftDatabase(name:'), isFalse);

      final anaIo =
          File('lib/src/data/local/analytics_connection_io.dart').readAsStringSync();
      expect(
        anaIo.contains('databaseDirectory: AppPaths.documentsDirectory'),
        isTrue,
        reason: 'analytics_connection_io.dart 又变回裸 driftDatabase 了 —— '
            'Linux 上会重新抛 MissingPlatformDirectoryException',
      );
    });
  });
}
