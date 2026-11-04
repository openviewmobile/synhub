// 阅读器（EPUB / FB2 / CBZ）的本地状态与偏好。
//
// 三层：
//   * [bookStoreProvider]   —— Drift：进度 + 书签（每台机器一份）
//   * [readerPrefsProvider] —— 字号/行距/主题，落在设置键值里（全 App 共享）
//   * 进度/书签的 provider —— 按 `bookKey` 分家族，进书时读、滚动时写
//
// 写进度是**节流**的：滚动回调每帧都会来，真正落库交给
// [ReaderProgressNotifier.report]，它自己判断"值没变就不写"（判在 store 里，
// 这里再挡一道内存里的重复值，避免把 sqlite 写热）。
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/settings/app_settings.dart';
import '../../data/local/book_store.dart';
import '../chat/chat_session_controller.dart' show chatDatabaseProvider;
import 'book_tts.dart';
import 'book_tts_linux.dart';

/// 阅读进度 / 书签的本地库
final bookStoreProvider = Provider<BookStore>(
  (ref) => BookStore(ref.watch(chatDatabaseProvider)),
);

/// 听书用的系统 TTS 引擎（测试里覆盖成假引擎，见 `book_tts.dart`）
final ttsEngineProvider = Provider<TtsEngine>((ref) {
  // ★ r691：`flutter_tts` 没有 Linux 实现 ⇒ Linux 走进程式合成器
  //   （`spd-say` / `espeak-ng`，见 `book_tts_linux.dart`），其它平台仍是 `SystemTtsEngine`。
  final engine = defaultTtsEngine();
  ref.onDispose(engine.dispose);
  return engine;
});

/// 一本书的进度（读一次；写完自己 invalidate）
final bookProgressProvider = FutureProvider.family<BookProgress?, String>((
  ref,
  bookKey,
) async {
  return ref.watch(bookStoreProvider).progressOf(bookKey);
});

/// 一本书的书签/划线列表
final bookMarksProvider = FutureProvider.family<List<BookMark>, String>((
  ref,
  bookKey,
) async {
  return ref.watch(bookStoreProvider).marksOf(bookKey);
});

/// "最近在读"（跨书；给文件页的继续阅读条用）
final recentBooksProvider = FutureProvider<List<BookProgress>>((ref) async {
  return ref.watch(bookStoreProvider).recent(limit: 12);
});

/// 进度写入（节流 + 去重）
class ReaderProgressNotifier extends Notifier<String> {
  /// 上一次真正提交的值：`chapter|scroll`
  String _last = '';

  @override
  String build() => '';

  /// 记一次当前位置。`scroll` 是章内百分比（0..1）。
  ///
  /// [sourceUrl] 是"这本书从哪再拿字节"的现成直链（Drive 来源才有）——
  /// 工作台「继续阅读」靠它不查目录就能重开。
  Future<void> report({
    required String bookKey,
    required String title,
    required String format,
    required int chapter,
    required double scroll,
    required int chapterCount,
    String sourceUrl = '',
  }) async {
    final sig =
        '$chapter|${scroll.toStringAsFixed(2)}|$chapterCount|$sourceUrl';
    if (sig == _last) return;
    _last = sig;
    await ref
        .read(bookStoreProvider)
        .saveProgress(
          bookKey: bookKey,
          title: title,
          format: format,
          chapter: chapter,
          scroll: scroll,
          chapterCount: chapterCount,
          sourceUrl: sourceUrl,
        );
    ref.invalidate(recentBooksProvider);
  }

  /// 打开另一本书时清掉节流状态
  void reset() => _last = '';
}

final readerProgressProvider = NotifierProvider<ReaderProgressNotifier, String>(
  ReaderProgressNotifier.new,
);

// ------------------------------------------------------------------ 书签

class BookMarksNotifier {
  BookMarksNotifier(this.ref, this.bookKey);

  final Ref ref;
  final String bookKey;

  Future<int> add({
    required int chapter,
    required double scroll,
    String excerpt = '',
    String note = '',
  }) async {
    final id = await ref
        .read(bookStoreProvider)
        .addMark(
          bookKey: bookKey,
          chapter: chapter,
          scroll: scroll,
          excerpt: excerpt,
          note: note,
        );
    ref.invalidate(bookMarksProvider(bookKey));
    return id;
  }

  Future<void> remove(int id) async {
    await ref.read(bookStoreProvider).deleteMark(id);
    ref.invalidate(bookMarksProvider(bookKey));
  }

  Future<void> setNote(int id, String note) async {
    await ref.read(bookStoreProvider).setMarkNote(id, note);
    ref.invalidate(bookMarksProvider(bookKey));
  }
}

final bookMarksActionsProvider = Provider.family<BookMarksNotifier, String>((
  ref,
  bookKey,
) {
  return BookMarksNotifier(ref, bookKey);
});

// ------------------------------------------------------------------ 阅读偏好

/// 阅读器外观（字号/行距/主题/对齐）
class ReaderPrefs {
  const ReaderPrefs({
    this.fontSize = 16,
    this.lineHeight = 1.5,
    this.theme = 'normal',
    this.justify = false,
  });

  final double fontSize;
  final double lineHeight;

  /// `normal` / `sepia` / `night`
  final String theme;
  final bool justify;

  ReaderPrefs copyWith({
    double? fontSize,
    double? lineHeight,
    String? theme,
    bool? justify,
  }) => ReaderPrefs(
    fontSize: fontSize ?? this.fontSize,
    lineHeight: lineHeight ?? this.lineHeight,
    theme: theme ?? this.theme,
    justify: justify ?? this.justify,
  );

  /// 正文字号档位（UI 只在这几档里跳，避免滑到看不清）
  static const List<double> fontSizes = [14, 16, 18, 20, 22, 24];
  static const List<double> lineHeights = [1.3, 1.5, 1.7, 2.0];
}

class ReaderPrefsNotifier extends Notifier<ReaderPrefs> {
  @override
  ReaderPrefs build() => const ReaderPrefs();

  /// 启动 / 进阅读器时预读
  Future<void> preload() async {
    final s = ref.read(settingsServiceProvider);
    final prefs = ReaderPrefs(
      fontSize: await s.readerFontSize(),
      lineHeight: await s.readerLineHeight(),
      theme: await s.readerTheme(),
      justify: await s.readerJustify(),
    );
    if (ref.mounted) state = prefs;
  }

  Future<void> setFontSize(double v) async {
    state = state.copyWith(fontSize: v);
    await ref.read(settingsServiceProvider).setReaderFontSize(v);
  }

  /// 档位内加减（`+1` / `-1`）
  Future<void> stepFontSize(int dir) async {
    final list = ReaderPrefs.fontSizes;
    final i = list.indexOf(state.fontSize);
    final int next = i < 0
        ? (dir > 0 ? 0 : list.length - 1)
        : (i + dir).clamp(0, list.length - 1).toInt();
    await setFontSize(list[next]);
  }

  Future<void> setLineHeight(double v) async {
    state = state.copyWith(lineHeight: v);
    await ref.read(settingsServiceProvider).setReaderLineHeight(v);
  }

  Future<void> setTheme(String v) async {
    state = state.copyWith(theme: v);
    await ref.read(settingsServiceProvider).setReaderTheme(v);
  }

  Future<void> setJustify(bool v) async {
    state = state.copyWith(justify: v);
    await ref.read(settingsServiceProvider).setReaderJustify(v);
  }
}

final readerPrefsProvider = NotifierProvider<ReaderPrefsNotifier, ReaderPrefs>(
  ReaderPrefsNotifier.new,
);

/// 阅读背景色 / 文字色（三种阅读主题）。`normal` 返回 null = 用 App 主题。
({int bg, int? fg})? readerColorsOf(String theme) => switch (theme) {
  'sepia' => (bg: 0xFFF6ECD9, fg: 0xFF3B3226),
  'night' => (bg: 0xFF0B0B0C, fg: 0xFFC9C9CC),
  _ => null,
};

/// 启动时把阅读偏好读进来（字号/行距/主题），免得进书先闪一下默认字号。
Future<void> preloadReaderPrefs(dynamic ref) async {
  await ref.read(readerPrefsProvider.notifier).preload();
}
