// Phase 9 真机验收：设置层（主题持久化 + 图片质量真的生效）。
//
//   flutter test integration_test/phase9_test.dart -d <deviceId> \
//     --dart-define=SYNO_NAS_QC=… --dart-define=SYNO_NAS_ACCOUNT=… \
//     --dart-define=SYNO_NAS_PASSWORD=… --dart-define=SYNO_LIVE_POST=true
//
// 做这些事（真 NAS + 真机）：
//   ① 主题写进本地库、重启后仍是深色（新建一个 ChatStore 读同一份库）；
//   ② 「标准质量」上传一张 1600×800 的 PNG → 服务端存的是 **1280 宽 JPEG**，
//      文件名扩展名变成 jpg；
//   ③ 切到「原图」再传同一张 → 服务端存的就是原始 1600×800 PNG；
//   ④ 缓存上限能落盘；
//   ⑤ 收尾：删掉测试发出去的两条消息。
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:integration_test/integration_test.dart';
import 'package:path_provider/path_provider.dart';
import 'package:synhub/src/core/media/cache_service.dart';
import 'package:synhub/src/core/security/passcode_service.dart';
import 'package:synhub/src/core/settings/app_settings.dart';
import 'package:synhub/src/core/theme/app_tokens.dart';
import 'package:synhub/src/data/chat_api.dart';
import 'package:synhub/src/data/dto/file_prop_dto.dart';
import 'package:synhub/src/data/dto/post_dto.dart';
import 'package:synhub/src/features/chat/chat_session_controller.dart';
import 'package:synhub/src/features/servers/connection_service.dart';
import 'package:synhub/src/features/servers/server_profile.dart';
import 'package:synhub/src/features/settings/settings_page.dart';

const _qc = String.fromEnvironment('SYNO_NAS_QC');
const _account = String.fromEnvironment('SYNO_NAS_ACCOUNT');
const _password = String.fromEnvironment('SYNO_NAS_PASSWORD');
const _postRaw = String.fromEnvironment('SYNO_LIVE_POST');
final _doPost = _postRaw == '1' || _postRaw == 'true';

String _marker(String kind) =>
    'flt-p9-$kind-${DateTime.now().millisecondsSinceEpoch}';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  // ★ 真机 `integration_test` 的"常驻动效"陷阱（第 45 轮定位）：
  //   `FieldBackdrop` 在 `AppEffects.ambientAllowed` 为真时会
  //   `AnimationController.repeat()`（`lib/src/core/ui/field_backdrop.dart:104`），
  //   而 `ambientAllowed = Motion.enabled && !AppEffects.isFlutterTest`
  //   （`lib/src/core/theme/app_tokens.dart:109`）；`isFlutterTest` 只认
  //   `Platform.environment.containsKey('FLUTTER_TEST')`（`:99`）—— 这个环境变量
  //   **只有宿主 `flutter test` 才有，真机 App 进程里永远没有** ⇒ 生产路径的常驻
  //   动效照常在跑 ⇒ 含 `FieldBackdrop` 的页面（设置页就是）上的 `pumpAndSettle()`
  //   永远等不到停帧：默认 10 分钟超时，整目标先被套件看门狗杀掉，日志里连一条
  //   `Expected/Actual` 都看不到。
  //   这里按仓库既有约定（AGENTS §2.0.9「有常驻动画时 pumpAndSettle 不可用」）
  //   显式打开**用户可见的**「减少动效」开关把常驻动效停掉：
  //   不改产品行为、不放宽任何产品断言。
  AppEffects.reducedMotion.value = true;

  testWidgets('Phase 9 真机：设置层（主题持久化 / 图片质量 / 缓存上限）', (tester) async {
    expect(_qc, isNotEmpty, reason: '需要 --dart-define=SYNO_NAS_QC=…');

    final conn = await ConnectionService().connect(
      const ServerProfile(kind: ServerAddressKind.quickConnect, value: _qc),
    );
    await conn.api.login(
        account: _account, password: _password, session: 'Chat');

    final container = ProviderContainer();
    addTearDown(() {
      try {
        container.dispose();
      } catch (_) {}
    });
    await container.read(chatSessionControllerProvider.notifier).start(conn);
    final ctrl = container.read(chatSessionControllerProvider.notifier);
    final store = container.read(chatStoreProvider);
    final settings = container.read(settingsServiceProvider);

    // ---------- ① 主题：三档 + 持久化 ----------
    await container.read(themeChoiceProvider.notifier).preload();
    debugPrint('[p9] 启动时主题=${container.read(themeChoiceProvider).label}');

    await container.read(themeChoiceProvider.notifier).set(AppThemeChoice.dark);
    expect(container.read(themeChoiceProvider), AppThemeChoice.dark);
    expect(await store.setting('dark_mode'), '2', reason: 'key 沿用原版');

    // 换个门面重新读（等价于重启后 preload：值来自本地库而不是内存）
    final freshSettings = SettingsService(store);
    expect(await freshSettings.themeChoice(), AppThemeChoice.dark);
    debugPrint('[p9] 主题持久化 ✓ dark_mode=2');

    // 设置页能打开并显示当前档位
    await tester.pumpWidget(UncontrolledProviderScope(
      container: container,
      child: const MaterialApp(home: SettingsPage()),
    ));
    await tester.pumpAndSettle();
    expect(find.text('设置'), findsOneWidget);
    expect(find.text('深色'), findsOneWidget);
    debugPrint('[p9] 设置页渲染 ✓');

    // ---------- ② 缓存上限 + 容量淘汰 ----------
    await container.read(cacheLimitProvider.notifier).set(10485760);
    expect(await settings.cacheLimitBytes(), 10485760);
    await container.read(cacheLimitProvider.notifier).set(kDefaultCacheLimitBytes);
    debugPrint('[p9] 缓存上限读写 ✓');

    // 真机上的缓存目录：写 3 份、按上限淘汰、再清空
    final cache = container.read(cacheServiceProvider);
    for (var i = 0; i < 3; i++) {
      final path = await cache.pathFor(900000 + i, 'flt-p9-cache-$i.bin');
      final f = File(path);
      await f.writeAsBytes(List.filled(4096, i));
      // 手动拉开 mtime，保证淘汰顺序确定
      await f.setLastModified(
          DateTime.now().subtract(Duration(minutes: 10 - i * 3)));
    }
    var usage = await cache.usage(limitBytes: kDefaultCacheLimitBytes);
    debugPrint('[p9] 缓存用量 ${usage.humanSize} / ${usage.files} 个文件');
    expect(usage.files, greaterThanOrEqualTo(3));

    final freed = await cache.enforceLimit(5000); // 只留 5000 字节 → 至少删一份
    debugPrint('[p9] 淘汰释放 ${humanBytes(freed)}，剩余 '
        '${(await cache.usage()).humanSize}');
    expect(freed, greaterThan(0));

    final cleared = await cache.clear();
    debugPrint('[p9] 清空缓存释放 ${humanBytes(cleared)}');
    expect((await cache.usage()).bytes, 0);
    debugPrint('[p9] 缓存管理 ✓');

    // ---------- ③ 应用锁（4 位口令） ----------
    final passcode = container.read(passcodeServiceProvider);
    await store.setSetting('passcode_expiration', 'ALWAYS');
    await passcode.setPasscode('2468');
    expect(await passcode.verify('2468'), isTrue);
    expect(await passcode.verify('0000'), isFalse);
    // 换个门面重新读（等价于重启后）
    expect(await SettingsService(store).passcodeEnabled(), isTrue);
    expect(await SettingsService(store).passcodeHash(), isNotEmpty);

    await container.read(passcodeLockProvider.notifier).init();
    expect(container.read(passcodeLockProvider), isTrue, reason: '冷启动要锁');
    expect(await passcode.unlock('2468'), isTrue);
    container.read(passcodeLockProvider.notifier).markUnlocked();
    expect(container.read(passcodeLockProvider), isFalse);

    // 退到后台再回来（ALWAYS → 立刻重锁）
    container.read(passcodeLockProvider.notifier).onPaused();
    await container.read(passcodeLockProvider.notifier).onResumed();
    expect(container.read(passcodeLockProvider), isTrue,
        reason: 'ALWAYS 档位退后台回来必须重输');
    debugPrint('[p9] 应用锁 ✓（冷启动锁 / 验证 / 退后台重锁）');

    // 收尾：关掉应用锁，免得后续手测被挡
    await passcode.disable();
    container.read(passcodeLockProvider.notifier).markDisabled();
    expect(await SettingsService(store).passcodeEnabled(), isFalse);

    if (!_doPost) {
      debugPrint('[p9] 未开 SYNO_LIVE_POST，跳过上传验证');
      return;
    }

    // ---------- ③ 图片质量 ----------
    final channels = await store.allChannels();
    final target = channels.firstWhere((c) => !c.encrypted && c.isJoined,
        orElse: () => channels.first);
    debugPrint('[p9] 频道=#${target.channelId}');

    // 造一张 1600×800 的 PNG
    final dir = await getTemporaryDirectory();
    final srcPath = '${dir.path}/${_marker('src')}.png';
    final big = img.Image(width: 1600, height: 800);
    img.fill(big, color: img.ColorRgb8(200, 40, 90));
    await File(srcPath).writeAsBytes(img.encodePng(big));
    debugPrint('[p9] 源图 1600×800 PNG，${await File(srcPath).length()} 字节');

    final created = <int>[];

    Future<PostDto?> upload(String kind, {required bool original}) async {
      await container
          .read(imageQualityProvider.notifier)
          .set(original ? ImageQuality.original : ImageQuality.standard);
      final name = '${_marker(kind)}.png';
      final before = (await store.postsForChannel(target.channelId))
          .map((p) => p.postId)
          .toSet();
      final ok = await ctrl.sendAttachment(
        channelId: target.channelId,
        filePath: srcPath,
        fileName: name,
        message: 'flt',
      );
      expect(ok, isTrue, reason: '上传 $name 应该成功');
      final after = await store.postsForChannel(target.channelId);
      final mine = after
          .where((p) => !before.contains(p.postId) && p.postId > 0)
          .toList();
      expect(mine, isNotEmpty, reason: '要能拿到服务端确认的新消息');
      created.add(mine.first.postId);
      return mine.first;
    }

    /// 把服务端那份附件拉回来量尺寸
    Future<img.Image> fetchStored(PostDto post) async {
      final api = ChatApi(conn.api);
      final props = post.fileProps;
      final files = FilePropDto.parseList(props);
      expect(files, isNotEmpty, reason: '确认后的消息应带 file_props');
      final raw = await api.downloadPostFile(post.postId);
      final decoded = img.decodeImage(Uint8List.fromList(raw));
      expect(decoded, isNotNull, reason: '服务端存下来的应该是能解码的图');
      debugPrint('[p9] 服务端文件：${files.first.name} '
          '${raw.length} 字节 ${decoded!.width}×${decoded.height}');
      return decoded;
    }

    // 物品：标准质量 → 1280 宽 JPEG
    final standard = await upload('std', original: false);
    final stdImg = await fetchStored(standard!);
    expect(stdImg.width, 1280, reason: '标准质量要缩到长边 1280');
    expect(stdImg.height, 640);
    final stdProps = FilePropDto.parseList(standard.fileProps).first;
    expect(stdProps.name.toLowerCase(), endsWith('.jpg'),
        reason: '原版会把扩展名替换成 jpg');
    debugPrint('[p9] 标准质量 ✓ 1280×640 jpg');

    // 原图质量 → 1600 宽 PNG，且文件名保持 png
    final orig = await upload('orig', original: true);
    final origImg = await fetchStored(orig!);
    expect(origImg.width, 1600, reason: '原图不该被缩');
    expect(origImg.height, 800);
    final origProps = FilePropDto.parseList(orig.fileProps).first;
    expect(origProps.name.toLowerCase(), endsWith('.png'));
    debugPrint('[p9] 原图质量 ✓ 1600×800 png');

    // ---------- ④ 频道通知档位（真服务端 set → get 双向确认） ----------
    final original = await ctrl.loadChannelNotification(target.channelId);
    debugPrint('[p9] 频道 #${target.channelId} 当前通知档位='
        '${original.isEmpty ? '(空)' : original}');
    expect(
      ChatApi.notificationOptionsFor(target),
      contains(anyOf(
        ChatApi.notificationAll,
        ChatApi.notificationNone,
      )),
      reason: '候选里至少要有 all/none',
    );

    for (final value in const [
      ChatApi.notificationNone,
      ChatApi.notificationAll,
    ]) {
      final ok = await ctrl.setChannelNotification(target.channelId, value);
      expect(ok, isTrue, reason: '写 $value 应该成功');
      final readBack = await ctrl.loadChannelNotification(target.channelId);
      expect(readBack, value, reason: '服务端必须回读出刚写的档位（双向确认）');
      final local = (await store.allChannels())
          .firstWhere((c) => c.channelId == target.channelId);
      expect(local.notificationMobile, value);
      debugPrint('[p9] 档位 $value 写入 + 回读一致 ✓');
    }

    // 恢复原值（原来是空串就恢复成 all，不要留下测试痕迹）
    final restore = original.isEmpty ? ChatApi.notificationAll : original;
    await ctrl.setChannelNotification(target.channelId, restore);
    debugPrint('[p9] 已恢复原档位=$restore ✓');

    // ---------- ⑤ 收尾：删掉测试消息 ----------
    final api = ChatApi(conn.api);
    for (final id in created) {
      try {
        await api.deletePost(id);
        debugPrint('[p9] 已删 #$id');
      } catch (e) {
        debugPrint('[p9] 删 #$id 失败：$e');
      }
    }
    debugPrint('[p9] 清理完成 ✓');
  });
}
