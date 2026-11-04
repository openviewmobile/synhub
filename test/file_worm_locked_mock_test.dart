// ①文件 台账行 154（M34 文件锁定 / WORM）的**正样本**收尾 —— 走自建 **Mock Server**
// （`tool/mock_dsm/mock_dsm_core.dart` 的真实后端：目录校验 / 登录 / 夹具都在
// 那台后端里跑，不是自造假传输）。
//
// ## 为什么需要它（此前挂 🟡 的原因）
//
// 真机取证卡在"**本机没有已锁定的文件**"：造一个锁定共享要往真 NAS 发
// `Worm:set` 之类的**变更动词**，§5.1 明令禁止。按用户 2026-09-23 的新规
// 「真机/真 NAS 无法验证的也一律通过 Mock Server 验证」（B2），
// 本文件用 Mock 提供**锁定态正样本**，把下面四条链路一次钉死：
//
//   1. `Worm:get_share_info` = Immutable/Appendable ⇒ 自动锁定**已启用**
//      （判定逐字来自官方 `FileBrowserUtil.js`）；
//   2. `Worm:get` 的**锁定**回包 → `FileWormPathStatus.isLocked == true`
//      （`worm_state & 32`，`WormVo.State.isLocked()`）；
//   3. `List:list` 的 `additional.worm_state` → `FileEntryDto.wormLocked`；
//   4. 界面：属性页显示「锁定 (不可变)」；动作面板对锁定条目**只留复制**，
//      且给出一句原因（官方 `ResourceListFragment.java:2657-2682` 只放行 COPY）。
import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:synhub/src/data/dto/file_entry_dto.dart';
import 'package:synhub/src/data/dto/file_mount_dto.dart' show FileWormState;
import 'package:synhub/src/data/dto/file_worm_dto.dart';
import 'package:synhub/src/data/filestation_api.dart';
import 'package:synhub/src/data/local/database.dart';
import 'package:synhub/src/dsm/webapi.dart';
import 'package:synhub/src/features/chat/chat_session_controller.dart'
    show chatDatabaseProvider;
import 'package:synhub/src/features/files/file_providers.dart';
import 'package:synhub/src/features/files/file_sheets.dart';

import '../tool/mock_dsm/mock_dsm_core.dart';
import 'package:synhub/src/core/theme/app_theme.dart';
import 'support/mock_dsm_transport.dart';

/// Mock 上的"已锁定"共享：Immutable 自动锁定 + 锁定期 7 天。
const _shareLocked = <String, Object?>{
  'subvol_mode': 2, // Enterprise
  'def_lock_mode': 3, // Immutable ⇒ autoLockEnabled
  'lock_wait_time': 3600, // 1 小时
  'def_lock_duration': 604800, // 7 天
};

/// `Worm:get` 的**成功**回包（锁定正样本）。字段名来自官方
/// `FileProperty.js` 的 `WormFieldset.setLockRetention`。
const _lockedStatus = <String, Object?>{
  'worm_state': 4, // 线上下标 4 = IMMUTABLE_LOCKED
  'lock_time': 1789000000,
  'unlock_time': 1800000000,
  'lock_duration': 604800,
  'last_update_time': 1789000001,
  'ds_current_time': 1789000100,
};

void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;

  late MockDsmBackend backend;
  late MockDsmTransport transport;
  late DsmWebApi web;
  late FileStationApi api;

  Future<void> boot() async {
    backend = MockDsmBackend(catalog: DsmCatalog.load());
    backend.login(username: 'u', admin: false);
    backend.fixture('SYNO.FileStation.Worm', 'get_share_info', (p) {
      // **共享级**配置：共享内任意路径（含文件）都问得到；共享外才是
      // 官方那种"外层 1500 + 内层 408（路径不存在）"。
      if (!'${p['path']}'.startsWith('/wormshare')) {
        return {
          'success': false,
          'error': {
            'code': 1500,
            'errors': [
              {'code': 408, 'path': '${p['path']}'},
            ],
          },
        };
      }
      return {'success': true, 'data': _shareLocked};
    });
    backend.fixture('SYNO.FileStation.Worm', 'get', (p) {
      if (p['path'] == '/wormshare/locked.txt') {
        return {'success': true, 'data': _lockedStatus};
      }
      if (p['path'] == '/wormshare/open.txt') {
        return {'success': true, 'data': {'worm_state': 3}}; // OPEN
      }
      // 真机常态：外层 1500 + 内层 0 = "该路径没有 WORM 状态"。
      return {
        'success': false,
        'error': {
          'code': 1500,
          'errors': [
            {'code': 0, 'path': '${p['path']}'},
          ],
        },
      };
    });
    backend.fixture('SYNO.FileStation.List', 'list', (p) {
      return {
        'success': true,
        'data': {
          'total': 2,
          'offset': 0,
          'files': [
            {
              'name': 'locked.txt',
              'path': '/wormshare/locked.txt',
              'isdir': false,
              'filesize': 12,
              'mtime': 1789000000,
              'additional': {
                'size': 12,
                'is_worm_share': true,
                'worm_state': 4,
              },
            },
            {
              'name': 'open.txt',
              'path': '/wormshare/open.txt',
              'isdir': false,
              'filesize': 34,
              'mtime': 1789000001,
              'additional': {
                'size': 34,
                'is_worm_share': true,
                'worm_state': 3,
              },
            },
          ],
        },
      };
    });
    transport = MockDsmTransport(backend);
    web = DsmWebApi(transport);
    await web.discover();
    await web.login(account: 'u', password: 'x');
    api = FileStationApi(web);
  }

  setUp(boot);

  group('API 层（Mock Server 后端）', () {
    test('`get_share_info`：Immutable ⇒ 自动锁定已启用 + 等待/锁定期解析', () async {
      final info = await api.wormShareInfo('/wormshare');
      expect(info, isNotNull);
      expect(info!.defLockMode, FileWormDefLockMode.immutable);
      expect(info.autoLockEnabled, isTrue, reason: '只有 Immutable/Appendable 算启用');
      expect(info.subvolMode, FileWormSubVolMode.enterprise);
      expect(info.lockWaitTime, 3600);
      expect(info.defLockDuration, 604800);
    });

    test('`get`：锁定正样本 ⇒ isLocked + 时间字段全解析', () async {
      final st = await api.wormGet('/wormshare/locked.txt');
      expect(st.hasState, isTrue, reason: 'success:true 且有 worm_state');
      expect(st.state, 4);
      expect(st.isLocked, isTrue, reason: '`worm_state & 32`（WormVo.State.isLocked）');
      expect(st.isOpen, isFalse);
      expect(st.isExpired, isFalse);
      expect(st.lockTime, 1789000000);
      expect(st.unlockTime, 1800000000);
      expect(st.lockDuration, 604800);
      expect(st.serverTime, 1789000100);
    });

    test('`get`：开放态与"没有 WORM"都不算锁定', () async {
      final open = await api.wormGet('/wormshare/open.txt');
      expect(open.isLocked, isFalse);
      expect(open.isOpen, isTrue);

      // 内层 code=0（真机常态）⇒ notInWorm，且**不抛异常**
      final none = await api.wormGet('/wormshare/other.txt');
      expect(none.notInWorm, isTrue);
      expect(none.isLocked, isFalse);
    });

    test('`List:list` 的 additional.worm_state ⇒ wormLocked', () async {
      final page = await api.listFolder(folderPath: '/wormshare');
      expect(page.entries.length, 2);
      final locked = page.entries.firstWhere((e) => e.name == 'locked.txt');
      final open = page.entries.firstWhere((e) => e.name == 'open.txt');
      expect(locked.wormStateCode, 4);
      expect(locked.isWormShare, isTrue);
      expect(locked.wormLocked, isTrue, reason: '锁定 ⇒ 官方只放行 COPY');
      expect(open.wormLocked, isFalse, reason: 'OPEN 不是锁定态');
    });

    test('位掩码直判：弱不可变/弱可附加也算锁定，过期态不算', () {
      for (final v in [
        FileWormState.immutableLocked,
        FileWormState.appendableLocked,
        FileWormState.weakImmutableLocked,
        FileWormState.weakAppendableLocked,
      ]) {
        expect(FileWormState.isLocked(v), isTrue, reason: 'value=$v');
      }
      for (final v in [
        FileWormState.open,
        FileWormState.immutableExpired,
        FileWormState.appendableExpired,
        FileWormState.notInWormShare,
      ]) {
        expect(FileWormState.isLocked(v), isFalse, reason: 'value=$v');
      }
    });
  });

  group('界面层（Mock Server 后端）', () {
    Future<ProviderContainer> pump(Object? Function(WidgetTester) open) async {
      final db = ChatDatabase(NativeDatabase.memory());
      final c = ProviderContainer(
        overrides: [
          chatDatabaseProvider.overrideWithValue(db),
          fileApiProvider.overrideWithValue(api),
        ],
      );
      addTearDown(() async {
        c.dispose();
        await db.close();
      });
      return c;
    }

    testWidgets('属性页：锁定正样本 ⇒ 「锁定 (不可变)」+ 已启用 + 7 天', (tester) async {
      final entry = FileEntryDto.fromJson({
        'name': 'locked.txt',
        'path': '/wormshare/locked.txt',
        'isdir': false,
        'filesize': 12,
        'mtime': 1789000000,
        'additional': {'size': 12, 'is_worm_share': true, 'worm_state': 4},
      });
      final c = await pump((_) => null);
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: c,
          child: MaterialApp(theme: AppTheme.dark(), 
            home: Scaffold(
              body: Builder(
                builder: (context) => TextButton(
                  onPressed: () => showFilePropertiesSheet(context, entry),
                  child: const Text('打开属性'),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('打开属性'));
      await tester.pumpAndSettle();

      expect(find.text('WriteOnce'), findsOneWidget);
      expect(find.text('Enterprise'), findsOneWidget);
      expect(find.text('已启用'), findsOneWidget);
      expect(find.text('1 小时'), findsOneWidget);
      expect(find.text('7 天'), findsOneWidget);
      expect(
        find.text('锁定 (不可变)'),
        findsOneWidget,
        reason: '逐路径锁定态必须上屏（正样本此前拿不到）',
      );
      // 内部值不上屏
      expect(find.text('4'), findsNothing);
      expect(find.text('/wormshare/locked.txt'), findsOneWidget, reason: '只出现一次');
    });

    testWidgets('动作面板：锁定条目**只留复制**，改名/移动/删除全被拿掉', (tester) async {
      final entry = FileEntryDto.fromJson({
        'name': 'locked.txt',
        'path': '/wormshare/locked.txt',
        'isdir': false,
        'filesize': 12,
        'mtime': 1789000000,
        'additional': {'size': 12, 'is_worm_share': true, 'worm_state': 4},
      });
      final c = await pump((_) => null);
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: c,
          child: MaterialApp(theme: AppTheme.dark(), 
            home: Scaffold(
              body: Builder(
                builder: (context) => TextButton(
                  onPressed: () => showFileItemSheet(
                    context,
                    entry: entry,
                    canShare: false,
                    recycleBin: false,
                    wormLocked: true,
                  ),
                  child: const Text('打开动作'),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('打开动作'));
      await tester.pumpAndSettle();

      expect(find.text('WORM 已锁定'), findsOneWidget, reason: '锁定分区');
      expect(find.text('复制到…'), findsOneWidget, reason: '官方对锁定态只放行 COPY');
      for (final gone in ['重命名', '移动到…', '删除', '压缩']) {
        expect(find.text(gone), findsNothing, reason: '锁定态不许出现「$gone」');
      }
    });
  });
}
