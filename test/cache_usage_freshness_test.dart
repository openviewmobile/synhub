// ★ 第 425 轮 / `DA84`：设置页那一行「缓存用量」必须**每次进页面按当前磁盘重算**。
//
// 真机复现（r425，包 `4ad254f9…`）：`Clear` 之后去 Files 逛了一遍视频目录
// （首帧被重新抽出来，`cache/video_frames` 已有 68 KB / 4 个文件），回到
// 设置页 —— 这一行仍然写着 `No cache`。用户看到的数字 ≠ 设备上的缓存。
//
// 根因：`cacheUsageProvider` 是**会话级缓存**（`FutureProvider` 不带
// `autoDispose`），而全仓只有"清空缓存之后 `ref.invalidate`"这一处刷新它
// ⇒ 逛页面产生的新缓存不会反映到这一行。
//
// 修法：`FutureProvider.autoDispose`（离开设置页即销毁，回来重算；
// 统计中是 `t.cacheCounting`「正在统计…」，不会把"还在数"谎报成"没有缓存"）。
//
// ## 为什么用"假缓存"而不是真目录
// ★ r425 实测三个坑，都记在这里免得下轮再踩：
//   1. `testWidgets` 跑在**假异步**里，`Directory.createTemp` / `Directory.list()`
//      这类真 I/O **永远不完成** ⇒ provider 停在 `loading`，`pumpAndSettle`
//      直接 10 分钟超时（不是"慢"，是死等）；
//   2. 换成 `tester.runAsync` 放行真 I/O 也没能让 widget 侧拿到值
//      （20 轮 `runAsync`+`pump` 之后仍是 `loading`）；
//   3. 而 `ProviderContainer.read` 连读两次**两种 provider 都不重算**
//      （探针读数 `plain=1 auto=1`）⇒ 拿它当判据是假红/假绿。
// 所以：本用例把"目录 I/O"替换成可控的假 `usage()`，只钉**语义**
// （离开页面 → 重新回来 → 必须重算）；真机上的真 I/O 由 r425 的真机复验背书。
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:synhub/src/core/media/cache_service.dart';
import 'package:synhub/src/core/settings/app_settings.dart'
    show cacheServiceProvider;
import 'package:synhub/src/features/settings/settings_page.dart'
    show cacheUsageProvider;

/// 只回一个可控数字的假缓存（不碰真 I/O；每次 `usage()` 计一次数）
class _FakeCache extends CacheService {
  _FakeCache() : super(root: Directory('/nonexistent-r425-da84'));

  int calls = 0;
  int files = 0;

  @override
  Future<CacheUsage> usage({int limitBytes = 0}) async {
    calls++;
    return CacheUsage(bytes: files * 64, files: files, limit: limitBytes);
  }
}

/// 只渲染"文件数"，方便断言（真实页面渲染 `cacheUsed`/`cacheNone`）
class _UsageProbe extends ConsumerWidget {
  const _UsageProbe();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final label = ref
        .watch(cacheUsageProvider)
        .when(
          data: (u) => '${u.files}',
          loading: () => 'loading',
          error: (_, _) => 'error',
        );
    return Directionality(textDirection: TextDirection.ltr, child: Text(label));
  }
}

void main() {
  testWidgets('DA84：离开再回来，用量必须重算（不是会话初值）', (tester) async {
    final cache = _FakeCache();
    final container = ProviderContainer(
      overrides: [cacheServiceProvider.overrideWithValue(cache)],
    );
    addTearDown(container.dispose);

    Widget wrap(Widget child) => UncontrolledProviderScope(
      container: container,
      child: child,
    );

    // ① 进设置页：看到 0
    await tester.pumpWidget(wrap(const _UsageProbe()));
    await tester.pumpAndSettle();
    expect(find.text('0'), findsOneWidget);
    expect(cache.calls, 1);

    // ② 离开设置页
    await tester.pumpWidget(wrap(const SizedBox()));
    await tester.pumpAndSettle();

    // ③ 逛视频目录：首帧被抽出来（真机：`video_frames` 从 0 → 4 个文件）
    cache.files = 4;

    // ④ 回到设置页：必须看到新的数字
    await tester.pumpWidget(wrap(const _UsageProbe()));
    await tester.pumpAndSettle();
    expect(
      find.text('4'),
      findsOneWidget,
      reason: '会话级缓存时这里会停在初值 0（真机表现 = 回来仍写 No cache）',
    );
    expect(cache.calls, 2, reason: '回来必须重新统计一次');
  });
}
