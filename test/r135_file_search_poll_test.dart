// 第 135 轮真机缺陷回归：**「文件」搜索的假否定（flaky 0 命中）+ 根目录搜索恒失败**。
//
// ## 真机证据（先有像素，后有本用例）
//
// 构建：debug APK，Honor LGE-AN10（1148×2492 @490dpi），App 语言 = English，
// NAS `/home/Video` 里确实有 `Citizen Kane (1941).mkv`（4.4 GB）。
//
// * `/private/tmp/r134_ui/040_after_search_video_citizen.png`
//   —— 在 `/home/Video` 搜 `Citizen`，**首次**结果 = 「No matching files」（假否定）；
// * `/private/tmp/r134_ui/043_search_retry_19s.png`
//   —— **重搜**（warm）在同一目录命中 `Citizen Kane (1941).mkv`；
// * `/private/tmp/r134_ui/006_before_search_citizen.png`
//   —— 在**根目录**搜 `Citizen` 直接报 `Search failed / Error code 600`。
//
// ## 两个根因（各自独立、都要修）
//
// **① 轮询按"次数"猜，不看服务端自己的 `finished` 位。**
// `SYNO.FileStation.Search:list` 是**异步**的：还在跑的时候回
// `finished:false` + 已命中的部分结果，跑完才回 `finished:true`。
// 原代码 `if (result.entries.isNotEmpty || i >= 3) break;` ⇒ 约 1.2 秒就收手，
// 大目录还没扫完 ⇒ 界面上先出现「No matching files」，过十几秒重搜才命中。
//
// **② 根目录（`kFileRoot = '/'`）被原样当成搜索根。**
// 真机对 `folder_path='/'` 回 `Error code 600`；`''` 同理。都要回落 `/home`。
//
// ## 本用例的双向验证
//
// ①②③ 断言修复后的行为；④⑤ 把**修复前**的写法原样写出来，断言它**确实**
// 会"提前收手" / 把 `'/'` 发出去 —— 证明这几条断言不是恒真。
import 'package:flutter_test/flutter_test.dart';

import 'package:synhub/src/data/dto/file_entry_dto.dart';
import 'package:synhub/src/features/files/file_pages.dart';

void main() {
  group('r135 · 搜索根规整（fileSearchRootFor）', () {
    test('子目录原样透传 —— 不做任何猜测', () {
      expect(fileSearchRootFor('/home/Video'), '/home/Video');
      expect(fileSearchRootFor('/home'), '/home');
      expect(fileSearchRootFor('/home/Drive/x'), '/home/Drive/x');
      // 前后空白要被 trim 掉（真机上来自 UI 输入）
      expect(fileSearchRootFor('  /home/Video  '), '/home/Video');
    });

    test('空串与 "/" 一律回落 kFileSearchDefaultRoot（真机对 "/" 回 600）', () {
      expect(fileSearchRootFor(''), kFileSearchDefaultRoot);
      expect(fileSearchRootFor('   '), kFileSearchDefaultRoot);
      expect(fileSearchRootFor('/'), kFileSearchDefaultRoot);
      expect(fileSearchRootFor('  /  '), kFileSearchDefaultRoot);
      expect(kFileSearchDefaultRoot, '/home');
    });

    // ---------------------------------------------------------- 反向验证
    test('反向验证：修复前的写法会把 "/" 原样发出去', () {
      // 修复前的表达式（r121 的形态）—— 只挡了空串，**没挡 `'/'`**：
      String before(String folderPath) => folderPath.trim().isEmpty
          ? kFileSearchDefaultRoot
          : folderPath.trim();

      // 浏览栈的根就是 `'/'`（`kFileRoot`），所以"在根目录点搜索"必然走到这条分支
      expect(
        before('/'),
        '/',
        reason: '修复前的写法在根目录下就是发 `folder_path="/"` ⇒ 真机 600',
      );
      // 而修复后是 `/home` ⇒ 这条断言证明上面那组"回落 /home"不是恒真
      expect(fileSearchRootFor('/'), isNot(before('/')));
    });
  });

  group('r135 · 服务端 finished 位（FileListResult.finished）', () {
    test('顶层 finished 被解析成三态', () {
      final running = FileListResult.fromJson(const {
        'total': 0,
        'offset': 0,
        'files': [],
        'finished': false,
      });
      expect(running.finished, isFalse);
      expect(running.stillRunning, isTrue);

      final done = FileListResult.fromJson(const {
        'total': 1,
        'offset': 0,
        'files': [],
        'finished': true,
      });
      expect(done.finished, isTrue);
      expect(done.stillRunning, isFalse);
    });

    // ★ 这一条是整套修法的地基：`List.list` 等接口**根本不回** `finished`，
    //   必须与"服务端明说 false"分开，否则所有普通列目录都会被当成"还在跑"。
    test('没回 finished ⇒ null（"不知道"），不是 false', () {
      final plain = FileListResult.fromJson(const {
        'total': 2,
        'offset': 0,
        'files': [],
      });
      expect(plain.finished, isNull);
      expect(plain.stillRunning, isFalse, reason: 'null 不算"还在跑"');
    });

    test('宽松助手：字符串/数字形态的 finished 也认，脏值 → null', () {
      expect(
        FileListResult.fromJson(const {'files': [], 'finished': '1'}).finished,
        isTrue,
      );
      expect(
        FileListResult.fromJson(const {'files': [], 'finished': 0}).finished,
        isFalse,
      );
      expect(
        FileListResult.fromJson(const {
          'files': [],
          'finished': 'not-a-bool',
        }).finished,
        isNull,
      );
    });
  });

  group('r135 · 轮询判据（fileSearchShouldKeepPolling）', () {
    test('服务端说还在跑（false）⇒ 继续等，哪怕已经有 0 条结果', () {
      // 真机 `/home/Video` 的 `Citizen` 就是这个形态：第一次 list 时
      // `finished:false` + 0 条 ⇒ 修复前在这里收了手 ⇒ 假否定。
      expect(
        fileSearchShouldKeepPolling(
          serverFinished: false,
          hasEntries: false,
          attempt: 0,
        ),
        isTrue,
      );
      expect(
        fileSearchShouldKeepPolling(
          serverFinished: false,
          hasEntries: false,
          attempt: 29,
        ),
        isTrue,
        reason: '服务端没说完，就一直等到上限（`_kSearchPollMax` 兜底，不是这里管）',
      );
      // 已经有部分命中、但服务端说还没完 ⇒ 也继续等（要拿全量）
      expect(
        fileSearchShouldKeepPolling(
          serverFinished: false,
          hasEntries: true,
          attempt: 0,
        ),
        isTrue,
      );
    });

    test('服务端说完了（true）⇒ 立刻收手，0 命中就是真的 0 命中', () {
      expect(
        fileSearchShouldKeepPolling(
          serverFinished: true,
          hasEntries: false,
          attempt: 0,
        ),
        isFalse,
        reason: '这一条保证修复没有把"真的搜不到"变成"永远转圈"',
      );
      expect(
        fileSearchShouldKeepPolling(
          serverFinished: true,
          hasEntries: true,
          attempt: 0,
        ),
        isFalse,
      );
    });

    test('老服务端没回 finished（null）⇒ 逐字退回旧策略', () {
      // 旧策略：有结果就走；否则给到第 3 轮（i >= 3）宽限
      expect(
        fileSearchShouldKeepPolling(
          serverFinished: null,
          hasEntries: true,
          attempt: 0,
        ),
        isFalse,
      );
      expect(
        fileSearchShouldKeepPolling(
          serverFinished: null,
          hasEntries: false,
          attempt: 0,
        ),
        isTrue,
      );
      expect(
        fileSearchShouldKeepPolling(
          serverFinished: null,
          hasEntries: false,
          attempt: 2,
        ),
        isTrue,
      );
      expect(
        fileSearchShouldKeepPolling(
          serverFinished: null,
          hasEntries: false,
          attempt: 3,
        ),
        isFalse,
      );
    });

    // ---------------------------------------------------------- 反向验证
    test('反向验证：修复前的写法在服务端说"还没完"时提前收手', () {
      // ⚠️ 两个函数的**极性相反**，比之前先统一口径：
      //   * `before`  = "该收手了吗"（旧代码 `if (…) break;` 的判据）
      //   * `after`   = "该收手了吗"（新判据取反；`fileSearchShouldKeepPolling`
      //                 返回的是"还要不要继续等"）
      // 修复前的内联判据 —— 逐字照抄 r134 `file_pages.dart` 里那一行，
      // **完全不看服务端的 `finished`**，只数轮询次数：
      bool before({required bool hasEntries, required int i}) =>
          hasEntries || i >= 3;
      bool after({
        required bool? serverFinished,
        required bool hasEntries,
        required int attempt,
      }) => !fileSearchShouldKeepPolling(
        serverFinished: serverFinished,
        hasEntries: hasEntries,
        attempt: attempt,
      );

      // 真机现场（`040_after_search_video_citizen.png`）：服务端 `finished:false`、
      // 0 条命中，轮询到第 3 轮（400ms × 3 ≈ 1.2 秒）——
      // 修复前的判据在这里收手，界面就显示「No matching files」。
      expect(
        before(hasEntries: false, i: 3),
        isTrue,
        reason: '修复前判据在"服务端还没扫完"时就收手（i >= 3 分支）',
      );
      // 另一个形态：已经有部分命中就直接收手，拿不到全量
      expect(before(hasEntries: true, i: 0), isTrue);

      // 修复后同样的输入（服务端明说还没完）**不许收手** ⇒
      // 证明上面那两条不是恒真。
      // i < 3 时新旧**口径一致**（都还没收手）—— 这证明差异恰好出在
      // "旧代码数满了 3 轮就收手"这个点上，而不是我随口写了两个不同函数。
      for (final i in [0, 1, 2]) {
        expect(
          after(serverFinished: false, hasEntries: false, attempt: i),
          before(hasEntries: false, i: i),
          reason: '第 $i 轮：新旧都还没收手，这里必须一致',
        );
      }
      // i >= 3 时**必须分道扬镳**：旧代码收手（假否定），新代码继续等。
      for (final i in [3, 4, 29]) {
        expect(
          before(hasEntries: false, i: i),
          isTrue,
          reason: '第 $i 轮：旧代码在这一步收手（这正是真机看到的假否定）',
        );
        expect(
          after(serverFinished: false, hasEntries: false, attempt: i),
          isFalse,
          reason: '第 $i 轮：服务端说还没扫完，修复后不该收手',
        );
      }
      expect(
        after(serverFinished: false, hasEntries: true, attempt: 0),
        isNot(before(hasEntries: true, i: 0)),
        reason: '有部分命中 + 服务端说还没完 ⇒ 修复后要继续等全量',
      );
      // 而服务端明说"扫完了"时两者口径可以一致（都收手）——
      // 这条保证修复没有把搜索变成"永远转圈"。
      expect(after(serverFinished: true, hasEntries: false, attempt: 0), isTrue);
    });
  });

  // ★★★ r316：真机抓到**假否定** —— 同一关键字（`Download`，`/home` 下真有）
  // 第一次命中、清空重搜 >25s 仍是 `No matching files`。根因不是"收手太早"
  // （r135 已修），而是**收手之后怎么说**：服务端从没说过 `finished:true`，
  // 客户端却把"没等到"渲染成"没有匹配"。
  group('r316 · 「算不算最终结果」= 只有服务端说搜完才算（fileSearchResultsAreFinal）', () {
    test('服务端还在跑 + 0 条（哪怕已到轮询上限）⇒ **不算**最终结果（不许报没有匹配）', () {
      expect(
        fileSearchResultsAreFinal(
          serverFinished: false,
          hasEntries: false,
          attempt: 0,
        ),
        isFalse,
      );
      expect(
        fileSearchResultsAreFinal(
          serverFinished: false,
          hasEntries: false,
          // 上限本身由 `_kSearchPollMax` 管；这里就是要钉"到上限也不算"
          attempt: 89,
        ),
        isFalse,
        reason: 'r316 真机的假否定就发生在这里：界面不得说 No matching files',
      );
    });

    test('服务端说搜完了 + 0 条 ⇒ **算**最终结果（真 0 命中才允许这么说）', () {
      expect(
        fileSearchResultsAreFinal(
          serverFinished: true,
          hasEntries: false,
          attempt: 0,
        ),
        isTrue,
      );
    });

    test('老服务端（finished 缺失）⇒ 逐字退回旧策略，不改变它的行为', () {
      // 旧策略：有结果就走；没有就给 3 轮宽限
      expect(
        fileSearchResultsAreFinal(
          serverFinished: null,
          hasEntries: false,
          attempt: 3,
        ),
        isTrue,
        reason: '没有 finished 位的服务端，宽限用尽后必须能收手（否则永远转圈）',
      );
      expect(
        fileSearchResultsAreFinal(
          serverFinished: null,
          hasEntries: false,
          attempt: 2,
        ),
        isFalse,
      );
      expect(
        fileSearchResultsAreFinal(
          serverFinished: null,
          hasEntries: true,
          attempt: 0,
        ),
        isTrue,
      );
    });

    test('反向：判据与"要不要继续等"严格互补（改一个必须改另一个）', () {
      for (final finished in [true, false, null]) {
        for (final hasEntries in [true, false]) {
          for (final attempt in [0, 3, 89]) {
            expect(
              fileSearchResultsAreFinal(
                serverFinished: finished,
                hasEntries: hasEntries,
                attempt: attempt,
              ),
              !fileSearchShouldKeepPolling(
                serverFinished: finished,
                hasEntries: hasEntries,
                attempt: attempt,
              ),
              reason:
                  'finished=$finished hasEntries=$hasEntries attempt=$attempt',
            );
          }
        }
      }
    });
  });
}
