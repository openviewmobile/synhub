// 守卫（第 435 轮 / `DA90`）：**缓存根层"未归类 = 0"** —— 明示保留也要登记，
// 零字节残留要能清，陌生形状要能被**工具**发现（而不是靠人记得）。
//
// 真机读数（r435，`tool/cache_scope_audit.py` 任意深度枚举）：
// `/data/data/com.openviewai.synhub/cache/` 共 65 个路径，其中根层有两个文件
// **既不在目录登记表、也不在 r434 的根层正则表**里：
//   * `subtitle_60_S01E01.gestdown.<uuid>.srt`（45,970 B）—— 在线字幕，
//     对话框逐字承诺「在线字幕会保留」⇒ 不删是对的，但**从来没有任何地方登记过它**；
//   * `<uuid>.jpg`（**0 字节**，名字连形状都不固定）—— 某次图片写入中断/失败的空壳，
//     用量看不到、`Clear` 删不掉，而且**下次出现同类文件没有任何机制会发现**。
//
// 修法（`lib/src/core/media/cache_service.dart`）三层，本文件逐条钉住：
//   * ① `kCacheRootKeptPatterns`：**明示保留**也要登记（不清理、不计入用量）；
//   * ② `kCacheRootZeroByteRule` ＋ `kCacheRootZeroByteMinAge`：根层 0 字节且够旧的算残留，可清；
//   * ③ `tool/cache_scope_audit.py`：把「未归类 = 0」变成可复算的判据（未归类 > 0 即 exit=1）。
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:synhub/src/core/media/cache_service.dart';

String _srcOf(String path) => File(path).readAsStringSync();

void main() {
  group('A 静态：登记表与规则本身', () {
    test('A-①：`kCacheRootKeptPatterns` 每条都带非空理由，且正则可用', () {
      expect(kCacheRootKeptPatterns, isNotEmpty);
      for (final p in kCacheRootKeptPatterns) {
        expect(p.why.trim().length, greaterThan(20), reason: '理由不许敷衍');
        expect(() => p.regex, returnsNormally);
      }
      // 在线字幕必须被登记（真机就在根层躺着这一个）
      final srt =
          'subtitle_60_S01E01.gestdown.69cf7d79-052c-4f12-a57d-995d77de43ad.srt';
      expect(
        kCacheRootKeptPatterns.any((p) => p.regex.hasMatch(srt)),
        isTrue,
        reason: '在线字幕是"明示保留"，必须在保留表里有一条',
      );
      // 但不能顺手把可再生的那种也吞进来（两张表各管各的）
      expect(
        kCacheRootKeptPatterns.any((p) => p.regex.hasMatch('${'a' * 32}.pdf')),
        isFalse,
      );
    });

    test('A-②：零字节规则有文字理由，且门槛 ≥ 1 小时（不许删"正在写"的）', () {
      expect(kCacheRootZeroByteRule.trim().length, greaterThan(30));
      expect(
        kCacheRootZeroByteMinAge.inMinutes,
        greaterThanOrEqualTo(60),
        reason: '门槛太短会把"边写边删"的空文件也删掉',
      );
    });

    test('A-③：判定**顺序**写死 —— 保留 > 可再生 > 零字节残留', () {
      final src = _srcOf('lib/src/core/media/cache_service.dart');
      final fn = src.substring(
        src.indexOf('Future<List<File>> _rootRegenerableFiles()'),
      );
      final iKept = fn.indexOf('kCacheRootKeptPatterns');
      final iRegen = fn.indexOf('kCacheRootRegenerablePatterns');
      final iZero = fn.indexOf('kCacheRootZeroByteMinAge');
      expect(iKept, greaterThan(-1));
      expect(iRegen, greaterThan(-1));
      expect(iZero, greaterThan(-1));
      expect(iKept, lessThan(iRegen), reason: '明示保留必须先判（否则会被别的正则吞掉）');
      expect(iRegen, lessThan(iZero), reason: '零字节规则是最后兜底');
      expect(
        fn.contains('continue'),
        isTrue,
        reason: '命中"保留"必须 continue 跳过，不能只 break 内层循环',
      );
    });
  });

  group('B 行为：用量 / 清空真的按三张表走', () {
    test('B-①：用量含"登记的 pdf ＋ 够旧的零字节残留 ＋ 登记目录"，不含明示保留/陌生形状', () async {
      final root = Directory.systemTemp.createTempSync('cache_root_r435_');
      addTearDown(() {
        try {
          root.deleteSync(recursive: true);
        } catch (_) {}
      });

      final stray = File('${root.path}/${'d' * 31}7.pdf')
        ..writeAsBytesSync(List.filled(100, 7));
      final srt = File('${root.path}/subtitle_60_S01E01.gestdown.x.srt')
        ..writeAsStringSync('1\n00:00 --> 00:01\nhi\n');
      // 够旧的零字节残留（模拟那次中断的图片写入）
      final junk = File('${root.path}/deadbeef-0000-1111-2222-333344445555.jpg')
        ..writeAsBytesSync(const []);
      junk.setLastModifiedSync(DateTime.now().subtract(const Duration(hours: 2)));
      // 刚写过的零字节文件（可能正在写）⇒ 不许碰
      final fresh = File('${root.path}/fresh.jpg')..writeAsBytesSync(const []);
      // 陌生形状但有内容 ⇒ 不许碰（不知道内容的字节不许删）
      final unknown = File('${root.path}/unknown.bin')
        ..writeAsBytesSync(List.filled(10, 9));
      // 登记目录里的普通缓存（对照组）
      final reg = File('${root.path}/chat_cache/keep.bin')
        ..createSync(recursive: true)
        ..writeAsBytesSync(List.filled(50, 3));

      final cache = CacheService(root: root);
      final u = await cache.usage();
      expect(u.files, 3, reason: '登记目录 1 + 根层登记模式 1 + 零字节残留 1');
      expect(u.bytes, 150, reason: '100 + 0 + 50');

      final freed = await cache.clear();
      expect(freed, 150);
      expect(stray.existsSync(), isFalse, reason: '根层登记的 pdfx 遗留必须清掉');
      expect(junk.existsSync(), isFalse, reason: '够旧的零字节残留必须清掉');
      expect(reg.existsSync(), isFalse, reason: '登记目录里的缓存必须清掉');
      expect(srt.existsSync(), isTrue, reason: '在线字幕 = 明示保留，不许动');
      expect(fresh.existsSync(), isTrue, reason: '刚写的 0 字节文件可能是"正在写"，不许动');
      expect(unknown.existsSync(), isTrue, reason: '陌生形状有内容 ⇒ 不知道是什么就不删');
      expect(srt.readAsStringSync(), isNotEmpty, reason: '保留的文件内容不许被改');
    });

    test('B-②：零字节残留"够旧"才回收 —— 同内容只把 mtime 改老，行为必须翻转', () async {
      final root = Directory.systemTemp.createTempSync('cache_root_r435_age_');
      addTearDown(() {
        try {
          root.deleteSync(recursive: true);
        } catch (_) {}
      });

      final f = File('${root.path}/whatever.jpg')..writeAsBytesSync(const []);
      final cache = CacheService(root: root);

      expect((await cache.usage()).files, 0, reason: '刚写的：不算缓存');
      f.setLastModifiedSync(DateTime.now().subtract(const Duration(hours: 2)));
      expect((await cache.usage()).files, 1, reason: '变老之后：算 0 字节残留');
      expect(await cache.clear(), 0, reason: '0 字节释放 0 字节，但文件必须消失');
      expect(f.existsSync(), isFalse);
    });

    test('B-③：白名单目录整棵子树都不碰（含任意深度）', () async {
      final root = Directory.systemTemp.createTempSync('cache_root_r435_wl_');
      addTearDown(() {
        try {
          root.deleteSync(recursive: true);
        } catch (_) {}
      });

      final deep = File('${root.path}/saf_ondemand/a/b/c.bin')
        ..createSync(recursive: true)
        ..writeAsBytesSync(List.filled(20, 1));
      final voice = File('${root.path}/voice/voiceMessage-1.aac')
        ..createSync(recursive: true)
        ..writeAsBytesSync(List.filled(20, 2));

      final cache = CacheService(root: root);
      expect((await cache.usage()).files, 0, reason: '白名单目录不计入用量');
      expect(await cache.clear(), 0);
      expect(deep.existsSync(), isTrue);
      expect(voice.existsSync(), isTrue);
    });
  });

  group('C 工具：未归类 = 0 必须可复算（不是只靠人记得）', () {
    test('C-①：审计工具在，且认这三样东西（两张根层表 ＋ 零字节规则）', () {
      final f = File('tool/cache_scope_audit.py');
      expect(f.existsSync(), isTrue, reason: '机器可检的审计工具必须在仓库里');
      final src = f.readAsStringSync();
      for (final sym in const [
        'kCacheRootKeptPatterns',
        'kCacheRootRegenerablePatterns',
        'kCacheRootZeroByteRule',
        'kRegenerableCacheDirs',
        'kCacheNotRegenerable',
      ]) {
        expect(src.contains(sym), isTrue, reason: '工具必须从 Dart 源码读 $sym（唯一事实来源）');
      }
      expect(
        src.contains('UNCLASSIFIED'),
        isTrue,
        reason: '未归类必须是一种**显式**判定',
      );
      expect(
        src.contains('res["verdict"] == "OK" else 1'),
        isTrue,
        reason: '未归类 > 0 ⇒ 非零退出码（否则"报警"只是打印）',
      );
    });
  });
}
