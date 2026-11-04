// r349：**管理员门控在 iOS 上到底给不给入口** —— 隔离探针（第二版）。
//
// 第一版的两个装置缺陷（已修，留档）：
//   ① `_allKeys` 用了 `find.byType(Widget)` —— 它只匹配 **runtimeType 恰好是
//      `Widget`** 的控件，等于**永远返回空** ⇒ 误报"树上 0 个 key"。
//      正确做法：遍历 element 树取 `widget.key`。
//   ② 忘了 `flutter test integration_test/...` **会卸载 App 清数据**（§2.0.1）
//      ⇒ 第一版冷启停在 **setup 页**，`dock-me`、`Settings` 全找不到。
//      本版自己走一遍登录。
//
// 为什么要有这条：r132 逐屏审计的 `s131_admin_gate` 报了
// `isAdmin=true source=AdminIdentitySource.initData 在树里=false`。
// ★ 关键是**它读的 provider 和门控读的不是同一个**：
//     审计读 `adminIdentityProvider`；`AdminOnly` 读 **`isAdminProvider`**
//     （`admin_identity.dart:357`，`await ref.watch(adminIdentityProvider.future)`
//      之后 `return id.isAdmin`，`retry: noRetry`）。
//   ⇒ 若 `isAdminProvider` 卡在 loading/error，而 `adminIdentityProvider`
//      后来读出来是 `initData/true`，**症状就是 s131 报的那样**。
//   本探针把**两个都读**，并逐次记录各自的 AsyncValue 状态。
//
// 已知对照（宿主，已通过）：`test/admin_gate_test.dart:285`
//   「管理员 ⇒ 设置页**有**「管理工具」条目（R3）」用**真 `SettingsPage`** +
//   `isAdminProvider.overrideWith(Future.value(true))` + 8×400px 滚动 ⇒ 找得到。
//   ⇒ 装置与产品在宿主上都对；iOS 上的差异只能出在"`isAdminProvider` 的实际结算"。
//
// 跑法：
//   export PATH="<flutter-sdk>/bin:$PATH"
//   tool/r132_ios_shot_poller.sh &      # 可选，用来抓像素
//   flutter test integration_test/r349_admin_gate_probe_test.dart \
//     -d A9D73490-69EC-4346-88D1-6ACAEFD58147 --timeout 900s
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import 'package:synhub/src/app.dart';
import 'package:synhub/src/core/device/device_profile.dart';
import 'package:synhub/src/core/security/biometric_auth.dart';
import 'package:synhub/src/core/ui/energy_orb.dart';
import 'package:synhub/src/data/note_api.dart';
import 'package:synhub/src/features/admin/admin_gate.dart';
import 'package:synhub/src/features/admin/admin_identity.dart'
    show AdminIdentitySource;
import 'package:synhub/src/features/media/audio_handler.dart';
import 'package:synhub/src/features/notes/note_background_sync_scheduler.dart';
import 'package:synhub/src/features/servers/session_controller.dart';

const String _kUrl = String.fromEnvironment(
  'PROBE_URL',
  defaultValue: 'http://127.0.0.1:18080',
);
const String _kAccount =
    String.fromEnvironment('PROBE_ACCOUNT', defaultValue: 'mockuser');
const String _kPassword =
    String.fromEnvironment('PROBE_PASSWORD', defaultValue: 'mockpass');

/// ★★ 正面方向的决定性开关：把 `isAdminProvider` **直接**钉成 `true`
/// （与宿主用例 `test/admin_gate_test.dart:285` 同一手法）——
/// 用来在 iOS 上单独验"**管理员必须看得见**"这一半契约（§2.0.7）。
/// 不开它时，验的是 Mock 上的自然结算 + fail-closed。
const bool _kForceAdmin = bool.fromEnvironment('PROBE_FORCE_ADMIN');

void _note(String s) => debugPrint('[gate] $s');

Future<void> _wait(WidgetTester t, int ms) async {
  final end = DateTime.now().add(Duration(milliseconds: ms));
  while (DateTime.now().isBefore(end)) {
    await t.pump(const Duration(milliseconds: 100));
  }
}

ProviderContainer? _container(WidgetTester tester) {
  final el = find.byType(SynologyChatApp);
  if (el.evaluate().isEmpty) return null;
  return ProviderScope.containerOf(tester.element(el.first), listen: false);
}

/// ★ 正确版：遍历 **element 树**取 key。
/// （第一版 `find.byType(Widget)` 只匹配 runtimeType 恰好为 `Widget` 的控件 ⇒ 恒空。）
List<String> _allKeys(WidgetTester tester) {
  final out = <String>{};
  for (final e in tester.allElements) {
    final k = e.widget.key;
    if (k == null) continue;
    if (k is ValueKey<String>) {
      out.add(k.value);
    } else {
      out.add(k.toString());
    }
  }
  final l = out.toList()..sort();
  return l;
}

/// ★ 仪器㉒：打印 `AdminIdentity` 必须落到**字段**上 ——
/// `data(Instance of 'AdminIdentity')` 等于没量（读不出 isAdmin/source）。
String _idFields(AdminIdentity? id) {
  if (id == null) return 'null';
  return 'isAdmin=${id.isAdmin} source=${id.source.name}';
}

/// 把 `AsyncValue` 的状态说清楚（loading / data / error 三态，别只看 `.value`）。
String _av<T>(AsyncValue<T> v) {
  if (v.isLoading) return 'loading';
  if (v.hasError) return 'error(${v.error})';
  return 'data(${v.value})';
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('r349：iOS 管理员门控 —— adminIdentityProvider vs isAdminProvider 的实际结算',
      (tester) async {
    WidgetsFlutterBinding.ensureInitialized();
    final profile = DeviceProfile.detect();
    await NoteStationApi.initNoteDeviceName();
    await registerNoteBackgroundSync();
    final audioHandler = await createBackgroundAudioHandler();
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          deviceProfileProvider.overrideWithValue(profile),
          biometricAuthenticatorProvider
              .overrideWithValue(LocalAuthBiometricAuthenticator()),
          audioHandlerProvider.overrideWithValue(audioHandler),
          if (_kForceAdmin)
            isAdminProvider.overrideWith((ref) => Future.value(true)),
        ],
        child: const SynologyChatApp(),
      ),
    );
    await _wait(tester, 3000);

    final c = _container(tester);
    expect(c, isNotNull, reason: '拿不到 ProviderContainer');

    // ---------- ⓿ 先看冷启落在哪一页 ----------
    _note('⓿ 冷启 key（前 40）= ${_allKeys(tester).take(40).join("|")}');

    // ---------- ① 登录 Mock（若在 setup 页）----------
    if (!c!.read(sessionControllerProvider).loggedIn) {
      _note('① 未登录 ⇒ 走 setup 直连登录 $_kUrl');
      final lan = find.byIcon(Icons.lan_outlined);
      if (lan.evaluate().isNotEmpty) {
        await tester.tap(lan.first, warnIfMissed: false);
        await _wait(tester, 800);
      }
      final tf = find.byType(TextField);
      if (tf.evaluate().isNotEmpty) {
        await tester.enterText(tf.first, _kUrl);
        await _wait(tester, 400);
      }
      final orb = find.byType(EnergyOrb);
      if (orb.evaluate().isNotEmpty) {
        await tester.tap(orb.first, warnIfMissed: false);
      }
      final dl = DateTime.now().add(const Duration(seconds: 60));
      while (DateTime.now().isBefore(dl)) {
        await tester.pump(const Duration(milliseconds: 100));
        if (find.byType(AlertDialog).evaluate().isNotEmpty) break;
        if (c.read(sessionControllerProvider).connection != null) break;
      }
      if (find.byType(AlertDialog).evaluate().isNotEmpty) {
        final ok = find.byType(FilledButton);
        if (ok.evaluate().isNotEmpty) {
          await tester.tap(ok.last, warnIfMissed: false);
        }
        await _wait(tester, 1500);
      }
      final dl2 = DateTime.now().add(const Duration(seconds: 90));
      while (DateTime.now().isBefore(dl2)) {
        await tester.pump(const Duration(milliseconds: 100));
        if (find.byType(TextField).evaluate().length >= 2) break;
        if (c.read(sessionControllerProvider).loggedIn) break;
      }
      if (!c.read(sessionControllerProvider).loggedIn) {
        final f = find.byType(TextField);
        _note('① 登录表单 TextField 数 = ${f.evaluate().length}');
        if (f.evaluate().length >= 2) {
          await tester.enterText(f.at(0), _kAccount);
          await _wait(tester, 300);
          await tester.enterText(f.at(1), _kPassword);
          await _wait(tester, 300);
          await tester.testTextInput.receiveAction(TextInputAction.done);
          await _wait(tester, 1500);
          for (final label in ['Sign in', 'Log in', 'Login', '登录']) {
            final b = find.text(label);
            if (b.evaluate().isNotEmpty) {
              await tester.tap(b.last, warnIfMissed: false);
              break;
            }
          }
        }
      }
      final dl3 = DateTime.now().add(const Duration(seconds: 90));
      while (DateTime.now().isBefore(dl3)) {
        await tester.pump(const Duration(milliseconds: 100));
        if (c.read(sessionControllerProvider).loggedIn) break;
      }
      _note('① 登录结果 loggedIn = ${c.read(sessionControllerProvider).loggedIn}');
    } else {
      _note('① 启动时已登录（saved session）');
    }
    await _wait(tester, 2000);

    // ---------- ② 自然解析：两个 provider 一起轮询 ----------
    final seen = <String>[];
    for (var i = 0; i < 100; i++) {
      final idAv = c.read(adminIdentityProvider);
      final isAv = c.read(isAdminProvider);
      final line = 'id=${_av(idAv)} [${_idFields(idAv.value)}] is=${_av(isAv)}';
      if (seen.isEmpty || seen.last != line) {
        seen.add(line);
        _note('② i=$i $line');
      }
      final id = idAv.value;
      if (id != null &&
          id.source != AdminIdentitySource.unresolved &&
          !isAv.isLoading) {
        break;
      }
      await _wait(tester, 300);
    }
    _note('② 轨迹 = ${seen.join(" || ")}');

    // ---------- ③ 进设置页 ----------
    final meOk = await _tapKey(tester, 'dock-me');
    _note('③ dock-me 命中 = $meOk');
    await _wait(tester, 1500);
    var setOk = await _tapText(tester, 'Settings', settle: 2500);
    if (!setOk) setOk = await _tapText(tester, '设置', settle: 2500);
    _note('③ 点设置项命中 = $setOk');
    await _wait(tester, 2500);

    // ---------- ④ 此刻两个 provider 的实际结算 ----------
    _note('④ adminIdentityProvider = ${_av(c.read(adminIdentityProvider))}'
        ' [${_idFields(c.read(adminIdentityProvider).value)}]');
    _note('④ isAdminProvider       = ${_av(c.read(isAdminProvider))}'
        '  （★ 门控 `AdminOnly` 读的是这个）');

    // ---------- ⑤ 扫：往下到底再往上到顶 ----------
    var found = find.byKey(const Key('set-admin-tools')).evaluate().isNotEmpty;
    var scrolls = 0;
    for (var i = 0; i < 12 && !found; i++) {
      await _scrollDown(tester);
      scrolls++;
      found = find.byKey(const Key('set-admin-tools')).evaluate().isNotEmpty;
    }
    for (var i = 0; i < 18 && !found; i++) {
      await _scrollUp(tester);
      scrolls++;
      found = find.byKey(const Key('set-admin-tools')).evaluate().isNotEmpty;
    }
    final keys = _allKeys(tester);
    _note('⑤ 滚动 $scrolls 次后：set-admin-tools 在控件树里 = $found');
    _note('⑤ 树里 key 总数 = ${keys.length}');
    _note(
        '⑤ set- 开头的 key = ${keys.where((k) => k.startsWith("set-")).join("|")}');
    _note('⑤ 含 admin 的 key = ${keys.where((k) => k.contains("admin")).join("|")}');
    _note('⑤ 对照 set-personal-profile 在不在 = '
        '${find.byKey(const Key("set-personal-profile")).evaluate().isNotEmpty}');
    _note('⑤ 滚动后再读 isAdminProvider = ${_av(c.read(isAdminProvider))}');
    _note('⑤ 滚动后再读 adminIdentityProvider = '
        '${_av(c.read(adminIdentityProvider))}'
        ' [${_idFields(c.read(adminIdentityProvider).value)}]');

    // ---------- ⑤.5 ★★ 对照断言：证明"确实进到了设置页的列表" ----------
    // 设置页全仓只有 3 个带 Key 的条目（`settings_page.dart`）：
    //   set-photo-ai-edit(280) / set-admin-tools(357) / set-personal-profile(378)
    // ⇒ 拿 `set-photo-ai-edit` 与 `set-personal-profile` 当**同族对照**：
    //   它们能找到 ⇒ 列表真的在、滚动真的到了；否则 `set-admin-tools=false` 不结论。
    final hasTop =
        find.byKey(const Key('set-photo-ai-edit')).evaluate().isNotEmpty;
    final hasBottom =
        find.byKey(const Key('set-personal-profile')).evaluate().isNotEmpty;
    _note('⑤.5 同族对照：set-photo-ai-edit=$hasTop '
        'set-personal-profile=$hasBottom');
    _note('⑤.5 设置页可滚动 maxScrollExtent = ${_maxScroll(tester)}');
    var onSettings = hasTop || hasBottom;
    if (!onSettings) {
      // 再给一次机会：从头往下扫一遍（可能停在别的滚动物上）
      for (var i = 0; i < 10 && !onSettings; i++) {
        await _scrollDown(tester);
        onSettings = find.byKey(const Key('set-photo-ai-edit')).evaluate().isNotEmpty ||
            find.byKey(const Key('set-personal-profile')).evaluate().isNotEmpty;
      }
      _note('⑤.5 补扫后 onSettings = $onSettings '
          'maxScrollExtent = ${_maxScroll(tester)}');
    }
    if (!onSettings) {
      throw StateError('装置不诚实：找不到设置页的任何同族对照条目 '
          '⇒ 无法判 set-admin-tools 是否被门控（本屏应记"未验"，不是缺陷）');
    }

    // ---------- ⑥ 判据 ----------
    final isAdminTrue = c.read(isAdminProvider).value == true;
    _note('⑥ 判据前提：isAdminProvider=${_av(c.read(isAdminProvider))} '
        '强制档=$_kForceAdmin 同族对照=$onSettings');
    if (isAdminTrue) {
      expect(found, isTrue,
          reason: 'isAdminProvider=true 但树里没有 set-admin-tools ⇒ '
              '§2.0.7 契约「管理员展示」被违反（见上面的 key 转储定位）');
      _note('⑥ isAdminProvider=true 且入口在树里 ✅');
    } else {
      expect(found, isFalse,
          reason: 'isAdminProvider 非 true 却给了管理入口（fail-open，权限泄漏方向）');
      _note('⑥ isAdminProvider 不是 true ⇒ 隐藏（fail-closed）✅；'
          '★ 本条**不能**证"管理员一定看得到"，那是上面 isAdminTrue 分支的事');
    }
  });
}

double _maxScroll(WidgetTester tester) {
  final sv = find.byType(Scrollable);
  if (sv.evaluate().isEmpty) return -1;
  try {
    final st = tester.state<ScrollableState>(sv.first);
    return st.position.maxScrollExtent;
  } catch (_) {
    return -1;
  }
}

Future<bool> _tapKey(WidgetTester tester, String k, {int settle = 1200}) async {
  final f = find.byKey(Key(k));
  if (f.evaluate().isEmpty) return false;
  await tester.tap(f.first, warnIfMissed: false);
  await _wait(tester, settle);
  return true;
}

Future<bool> _tapText(WidgetTester tester, String s, {int settle = 1600}) async {
  final f = find.text(s).hitTestable();
  if (f.evaluate().isEmpty) return false;
  await tester.tap(f.first, warnIfMissed: false);
  await _wait(tester, settle);
  return true;
}

Future<void> _scrollDown(WidgetTester tester, [double dy = 400]) async {
  final logical = tester.view.physicalSize / tester.view.devicePixelRatio;
  await tester.dragFrom(
      Offset(logical.width / 2, logical.height * 0.65), Offset(0, -dy));
  await _wait(tester, 600);
}

Future<void> _scrollUp(WidgetTester tester, [double dy = 400]) async {
  final logical = tester.view.physicalSize / tester.view.devicePixelRatio;
  await tester.dragFrom(
      Offset(logical.width / 2, logical.height * 0.35), Offset(0, dy));
  await _wait(tester, 600);
}
