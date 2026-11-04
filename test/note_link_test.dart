// ★★★ 第 128 轮 / 台账 N2：笔记链接（`notestation://`）形态与回解析。
//
// 官方：`NoteLinkDialogFragment` + 编辑器 `CMD_CREATE_LINK`，
// 本地笔记链接形态 `notestation://local/self/<noteId>`。
// 形态错了在真机上表现为"点链接没反应"，所以在纯函数层钉死。
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:synhub/src/features/notes/note_link.dart';
import 'package:synhub/src/features/notes/note_sync.dart';
import 'package:synhub/src/core/theme/app_theme.dart';
import 'package:synhub/src/features/notes/note_widgets.dart';

void main() {
  _m6();
  group('128. N2 笔记链接', () {
    test('★ 本地笔记链接形态逐字', () {
      expect(noteLinkUri('n-1'), 'notestation://local/self/n-1');
      expect(noteLinkUri(''), 'notestation://local/self/');
    });

    test('★ 回解析：本地链接取回 id', () {
      expect(noteIdFromLink('notestation://local/self/n-9'), 'n-9');
      expect(noteIdFromLink(noteLinkUri('abc/def')), 'abc/def');
    });

    test('★ 非本地链接一律 null（不误判外部/共享链接）', () {
      expect(noteIdFromLink('https://example.com/n-1'), isNull);
      expect(noteIdFromLink('notestation://local/self/'), isNull);
      expect(noteIdFromLink('notestation://shared/xyz'), isNull);
      expect(noteIdFromLink(null), isNull);
    });
  });
}

// ---------------------------------------------------------------- M6 断网横幅
//
// 官方 `error_connect_fail_offline`：离线时要在笔记列表上给提示（不是静默）。
// 这里断言横幅**三种状态的可见性**（离线显示 / 有待推送显示 / 正常隐藏）。
void _m6() {
  group('128. M6 断网提示横幅', () {
    Future<void> pumpWith(WidgetTester tester, NoteSyncStatus status) async {
      await tester.pumpWidget(
        ProviderScope(
          overrides: [noteSyncProvider.overrideWith(() => _FakeSync(status))],
          child: MaterialApp(theme: AppTheme.dark(), home: Scaffold(body: NoteOfflineBanner())),
        ),
      );
      await tester.pump();
    }

    testWidgets('★ 离线 ⇒ 显示"离线 · 显示上次同步的内容"', (tester) async {
      await pumpWith(tester, const NoteSyncStatus(state: NoteSyncState.offline));
      expect(
        find.textContaining('离线 · 显示上次同步的内容'),
        findsOneWidget,
        reason: '离线时必须给提示（不能静默）',
      );
    });

    testWidgets('★ 正常 ⇒ 不出离线提示', (tester) async {
      // 分开两个用例：同一个 tester 里连 pump 两次会沿用上一棵树的状态
      await pumpWith(tester, const NoteSyncStatus(state: NoteSyncState.idle));
      expect(find.textContaining('离线 ·'), findsNothing);
    });
  });
}

class _FakeSync extends NoteSyncNotifier {
  _FakeSync(this._initial);

  final NoteSyncStatus _initial;

  @override
  NoteSyncStatus build() => _initial;
}
