// 文件模块 wave2 的**纯函数 / 平台桥**离线验证。
//
//   * M58 `fileTaskRetryPlan` —— 哪些任务能重试、重发什么参数（红/绿都不碰网络）
//   * M50 `moveFavorite*` —— 本地重排（`replace_all` 的网络层未取证，见骨架报告）
//   * M72 `MethodChannelShortcutBridge` —— 通道不可用时**安静降级**为 false
//
// 不走 widget 的都用 `test()`；平台通道要在测试绑定里才能 invoke。
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:synhub/src/core/platform/app_platform.dart';
import 'package:synhub/src/data/dto/file_entry_dto.dart';
import 'package:synhub/src/features/files/file_favorite_reorder.dart';
import 'package:synhub/src/features/files/file_shortcut.dart';
import 'package:synhub/src/features/files/file_task_retry.dart';

FileTaskDto _task({
  required String api,
  String method = 'start',
  String path = '',
  Map<String, dynamic> params = const {},
  bool finished = true,
  List<FileTaskError> errors = const [],
}) => FileTaskDto(
  taskId: 'T-1',
  api: api,
  method: method,
  path: path,
  params: params,
  finished: finished,
  errors: errors,
);

FileEntryDto _entry(String name) =>
    FileEntryDto(name: name, path: '/home/$name', isDir: true);

void main() {
  // ★ 第 55 轮：这些用例验证的是**桥被调用时发什么载荷**（Android 语义），
  //   而能力层在 macOS 宿主上会正确地拦住 Android-only 桥 ⇒ 先把门打开
  //   （反向验证：门打开时确实去碰通道；见 `platform_capability_test.dart`）。
  setUp(() => debugForceCapabilityGate = true);
  tearDown(() => debugForceCapabilityGate = false);
  TestWidgetsFlutterBinding.ensureInitialized();

  // ★ 第 303 轮：任务详情里的**口令打码**（真机缺陷：`params` 快照把压缩/解压
  // 的口令原样回下来，详情页照原样渲染 ⇒ 屏幕上出现明文密码）。
  group('第 303 轮 isSecretTaskParamKey', () {
    test('口令类键名全部命中（大小写 / 下划线 / 连字符无关）', () {
      for (final k in const [
        'password',
        'Password',
        'PASSWORD',
        'passwd',
        'pass',
        'passphrase',
        'pwd',
        'secret',
        'api_key',
        'apikey',
        'API-KEY',
        'token',
        'credential',
      ]) {
        expect(isSecretTaskParamKey(k), isTrue, reason: '$k 必须打码');
      }
    });

    test('★ 真机形状：服务端把口令记在 `codepage` 键上 → 必须打码', () {
      // 真机逐字：`codepage  r303Zz9pw`（带口令的 Extract 任务快照，无 password 键）
      expect(isSecretTaskParamKey('codepage', value: 'r303Zz9pw'), isTrue);
      expect(isSecretTaskParamKey('codepage', value: '  utF8 '), isFalse,
          reason: '已知编码 token（大小写/空白无关）不能被误打码');
      for (final token in kFileCodepageTokens) {
        expect(isSecretTaskParamKey('codepage', value: token), isFalse,
            reason: '$token 是合法编码，详情页要照常显示');
      }
    });

    test('反向验证：普通参数**不能**被误打码（否则详情页就没用了）', () {
      for (final k in const [
        'format',
        'level',
        'mode',
        'codepage',
        'dest_file_path',
        'dest_folder_path',
        'file_path',
        'create_subfolder',
        'keep_dir',
        'overwrite',
        // 含 "path" 的键不能被 "pass" 之类的子串规则误伤
        'passenger_path',
      ]) {
        expect(isSecretTaskParamKey(k), isFalse, reason: '$k 不该打码');
      }
    });
  });

  group('M58 fileTaskRetryPlan', () {
    test('Compress：参数快照齐全 → 原样复用快照', () {
      final plan = fileTaskRetryPlan(
        _task(
          api: 'SYNO.FileStation.Compress',
          path: '/home/a',
          params: {
            'path': '["/home/a"]',
            'dest_file_path': '/home/a.zip',
            'format': 'zip',
            'level': 'moderate',
            'mode': 'add',
          },
        ),
      );
      expect(plan, isNotNull);
      expect(plan!.api, 'SYNO.FileStation.Compress');
      expect(plan.method, 'start');
      expect(plan.params['dest_file_path'], '/home/a.zip');
      expect(plan.params['mode'], 'add');
    });

    test('Compress：快照缺 dest_file_path → 不可重试（不猜目标）', () {
      final plan = fileTaskRetryPlan(
        _task(
          api: 'SYNO.FileStation.Compress',
          path: '/home/a',
          params: {'format': 'zip'},
        ),
      );
      expect(plan, isNull);
    });

    test('CopyMove：快照齐全 → 保留 remove_src / dest_folder_path', () {
      final plan = fileTaskRetryPlan(
        _task(
          api: 'SYNO.FileStation.CopyMove',
          path: '/home/a',
          params: {
            'path': '["/home/a"]',
            'dest_folder_path': '/home/b',
            'remove_src': true,
          },
        ),
      );
      expect(plan, isNotNull);
      expect(plan!.params['remove_src'], isTrue);
      expect(plan.params['dest_folder_path'], '/home/b');
    });

    test('CopyMove：快照缺目标 → null（即便 task.path 在）', () {
      final plan = fileTaskRetryPlan(
        _task(api: 'SYNO.FileStation.CopyMove', path: '/home/a'),
      );
      expect(plan, isNull);
    });

    test('Delete：无快照 → 用 task.path 重建（JSON 数组串 + recursive）', () {
      final plan = fileTaskRetryPlan(
        _task(api: 'SYNO.FileStation.Delete', path: '/home/a'),
      );
      expect(plan, isNotNull);
      expect(plan!.api, 'SYNO.FileStation.Delete');
      expect(plan.params['path'], '["/home/a"]');
      expect(plan.params['recursive'], isTrue);
    });

    test('MD5 / DirSize：无快照 → file_path 用 JSON 数组串重建', () {
      final md5 = fileTaskRetryPlan(
        _task(api: 'SYNO.FileStation.MD5', path: '/home/a'),
      );
      final size = fileTaskRetryPlan(
        _task(api: 'SYNO.FileStation.DirSize', path: '/home/a'),
      );
      expect(md5!.params['file_path'], '["/home/a"]');
      expect(size!.params['file_path'], '["/home/a"]');
    });

    test('快照里的 taskid 被剥掉（那是原任务号，不能拿来重发）', () {
      final plan = fileTaskRetryPlan(
        _task(
          api: 'SYNO.FileStation.Compress',
          params: {
            'taskid': 'old-task',
            'path': '["/home/a"]',
            'dest_file_path': '/home/a.zip',
          },
        ),
      );
      expect(plan!.params.containsKey('taskid'), isFalse);
    });

    test('Rename / 未知 API → 不可重试', () {
      expect(
        fileTaskRetryPlan(
          _task(
            api: 'SYNO.FileStation.Rename',
            params: {'path': '["/home/a"]', 'name': '["/home/b"]'},
          ),
        ),
        isNull,
      );
      expect(
        fileTaskRetryPlan(_task(api: 'SYNO.FileStation.SomeOther')),
        isNull,
      );
    });

    test('Delete 的 delete（永久删除）也允许重试', () {
      final plan = fileTaskRetryPlan(
        _task(
          api: 'SYNO.FileStation.Delete',
          method: 'delete',
          path: '/home/a',
        ),
      );
      expect(plan, isNotNull);
      expect(plan!.method, 'delete');
    });
  });

  group('M50 moveFavorite', () {
    test('上移 / 下移 / 越界原样', () {
      final a = _entry('a');
      final b = _entry('b');
      final c = _entry('c');
      final list = [a, b, c];

      expect(moveFavoriteUp(list, 1).map((e) => e.name), ['b', 'a', 'c']);
      expect(moveFavoriteDown(list, 0).map((e) => e.name), ['b', 'a', 'c']);
      // 越界不动
      expect(moveFavoriteUp(list, 0).map((e) => e.name), ['a', 'b', 'c']);
      expect(moveFavoriteDown(list, 2).map((e) => e.name), ['a', 'b', 'c']);
      // 不改原列表
      expect(list.map((e) => e.name), ['a', 'b', 'c']);
    });
  });

  group('M72 ShortcutBridge 降级', () {
    test('通道没实现（桌面 / 测试 / Android 未加）→ 返回 false，不抛', () async {
      final bridge = MethodChannelShortcutBridge();
      final ok = await bridge.pinShortcut(
        id: 'fs-/home',
        label: 'home',
        path: '/home',
      );
      expect(ok, isFalse);
    });

    test('平台回 error（PlatformException）→ 也是 false，不抛', () async {
      const channel = MethodChannel('synhub/shortcut_test_error');
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
            throw PlatformException(code: 'no_shortcut_support');
          });
      addTearDown(
        () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(channel, null),
      );
      final bridge = MethodChannelShortcutBridge(channel: channel);
      final ok = await bridge.pinShortcut(
        id: 'fs-/home',
        label: 'home',
        path: '/home',
      );
      expect(ok, isFalse);
    });

    test('平台返回 true → 透传 true', () async {
      const channel = MethodChannel('synhub/shortcut_test_ok');
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
            expect(call.method, 'pinShortcut');
            final args = Map<String, dynamic>.from(call.arguments as Map);
            expect(args['path'], '/home');
            expect(args['label'], 'home');
            return true;
          });
      addTearDown(
        () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(channel, null),
      );
      final bridge = MethodChannelShortcutBridge(channel: channel);
      final ok = await bridge.pinShortcut(
        id: 'fs-/home',
        label: 'home',
        path: '/home',
      );
      expect(ok, isTrue);
    });
  });

  // ── 第 304 轮：未完成任务的"已运行多久"（卡死任务唯一能提供的事实）──────
  //
  // 真机（第 303 轮）：一个卡死的压缩任务会**永远**显示 `0%` + 「任务错误：没有错误」，
  // 客户端不报错、不提示"可能已失效"。这里钉的是**事实来源**：`crtime`（服务端 epoch 秒）
  // → 时长；拿不到就不显示（**不许编造**），时钟倒挂也不许算出负数。
  group('第 304 轮 fileTaskElapsed（crtime → 已运行多久）', () {
    final now = DateTime(2026, 10, 8, 12, 0, 0);
    String at(Duration ago) =>
        '${now.subtract(ago).millisecondsSinceEpoch ~/ 1000}';

    test('正常形状：<1 分钟 → 0 分钟；90 秒 → 1 分钟；59 分 → 59 分钟', () {
      expect(fileTaskElapsed(at(const Duration(seconds: 5)), now: now)!.minutes, 0);
      expect(fileTaskElapsed(at(const Duration(seconds: 5)), now: now)!.hours,
          isNull);
      expect(fileTaskElapsed(at(const Duration(seconds: 90)), now: now)!.minutes,
          1);
      expect(
        fileTaskElapsed(at(const Duration(minutes: 59)), now: now)!.minutes,
        59,
      );
      expect(fileTaskElapsed(at(const Duration(minutes: 59)), now: now)!.hours,
          isNull);
    });

    test('≥1 小时：拆成 小时 + 余分钟（卡死任务真的会跑这么久）', () {
      final e1 = fileTaskElapsed(at(const Duration(minutes: 60)), now: now)!;
      expect(e1.hours, 1);
      expect(e1.minutes, 0);
      final e2 = fileTaskElapsed(at(const Duration(hours: 2, minutes: 25)), now: now)!;
      expect(e2.hours, 2);
      expect(e2.minutes, 25);
    });

    test('拿不到 crtime ⇒ null（空串 / 脏值 / 0 都不许编造时长）', () {
      expect(fileTaskElapsed('', now: now), isNull);
      expect(fileTaskElapsed('   ', now: now), isNull);
      expect(fileTaskElapsed('abc', now: now), isNull);
      expect(fileTaskElapsed('0', now: now), isNull);
      expect(fileTaskElapsed('-5', now: now), isNull);
    });

    test('服务端时钟比本机快（未来时间）⇒ 0 分钟，不许出现负数/负时长', () {
      final future = '${now.add(const Duration(minutes: 30)).millisecondsSinceEpoch ~/ 1000}';
      final e = fileTaskElapsed(future, now: now)!;
      expect(e.minutes, 0);
      expect(e.hours, isNull);
    });

    test('前后空白要容忍（服务端回显偶发带空格）', () {
      expect(fileTaskElapsed(' ${at(const Duration(minutes: 7))} ', now: now)!.minutes, 7);
    });
  });

}
