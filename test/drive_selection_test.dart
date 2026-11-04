// ★★ **③Drive 第 56 轮：D25 多选模型 + 压缩包名** 的用例
//
// 被测：
// * `DriveSelection`（纯状态转移）；
// * `driveArchiveName`（`archive_name` 的推导与**清洗**）。
//
// ## 为什么这些必须钉（都是"错了也不报错"的）
// ① `toggleAll` 若写成"逐个取反"：已选 1/3 再点全选 ⇒ 那 1 个被**取消**，
//    用户看到的是"全选后反而少了一个"；
// ② `archive_name` 若不清洗：`/`、`:`、`?` 会出现在 `Content-Disposition`
//    里 ⇒ 浏览器/文件系统存不下来，而**服务端不会报错**；
// ③ `clear` 若漏调：换目录后旧 id 残留 ⇒ "打包下载"里混进**另一个目录**
//    的文件，或直接 102（对象不存在）。
//
// 全程纯函数，无网络、无真机（规程 §5.1）。
import 'package:flutter_test/flutter_test.dart';

import 'package:synhub/src/features/drive/drive_selection.dart';

void main() {
  group('DSel-1. ★★ `toggleAll` 的"补全"语义（不是逐个取反）', () {
    test('★★ 已选 1/3 再点全选 ⇒ 变成 3/3（那 1 个**不能**被取消）', () {
      const sel = DriveSelection({'a'});
      final r = sel.toggleAll(['a', 'b', 'c']);
      expect(r.sortedIds, [
        'a',
        'b',
        'c',
      ], reason: '★ 逐个取反的实现会得到 {b,c} —— "点全选反而少了一个"');
    });

    test('★ 已全选再点 ⇒ 全部取消', () {
      const sel = DriveSelection({'a', 'b', 'c'});
      expect(sel.toggleAll(['a', 'b', 'c']).isEmpty, isTrue);
    });

    test('★ 空可见集合 ⇒ 不改变（避免"点全选清空一切"）', () {
      const sel = DriveSelection({'a'});
      expect(sel.toggleAll(const []).sortedIds, ['a']);
    });

    test('★ 取消全选**只**影响可见项，不动集合外的', () {
      const sel = DriveSelection({'a', 'b', 'x'});
      final r = sel.toggleAll(['a', 'b']);
      expect(r.sortedIds, [
        'x',
      ], reason: '可见的 a/b 被取消，集合外的 x 保留（防御性：正常换目录会 clear）');
    });
  });

  group('DSel-2. ★ 单点切换 / 增删 / 清空', () {
    test('★ toggle 是切换（选中 ⇄ 取消）', () {
      const sel = DriveSelection.empty();
      final on = sel.toggle('a');
      expect(on.contains('a'), isTrue);
      expect(on.toggle('a').contains('a'), isFalse);
    });

    test('★ 不可变：每次操作返回新实例，原实例不变', () {
      const sel = DriveSelection({'a'});
      final next = sel.toggle('b');
      expect(sel.sortedIds, ['a'], reason: '★ 原对象不能被改（共享可变集合的经典坑）');
      expect(next.sortedIds, ['a', 'b']);
      expect(identical(sel, next), isFalse);
    });

    test('★ clear 之后为空', () {
      expect(const DriveSelection({'a', 'b'}).clear().isEmpty, isTrue);
    });

    test('★ 相等性按集合语义（顺序无关）', () {
      const a = DriveSelection({'x', 'y'});
      const b = DriveSelection({'y', 'x'});
      expect(a, b);
      expect(a.hashCode, b.hashCode);
    });

    test('★ `sortedIds` 稳定有序（便于断言与请求可复现）', () {
      const sel = DriveSelection({'c', 'a', 'b'});
      expect(sel.sortedIds, ['a', 'b', 'c']);
    });
  });

  group('DSel-3. ★★ `driveArchiveName`：单文件 / 多文件 / 清洗', () {
    test('★ 单文件 ⇒ 直接用它的名字', () {
      expect(
        driveArchiveName(selectedNames: ['报告.docx'], folderName: '文档'),
        '报告.docx',
      );
    });

    test('★ 多文件 ⇒ 父目录名 + `.zip`', () {
      expect(
        driveArchiveName(selectedNames: ['a.txt', 'b.txt'], folderName: '项目资料'),
        '项目资料.zip',
      );
    });

    test('★★ 多文件但**拿不到目录名** ⇒ 退化名（不能给空）', () {
      expect(
        driveArchiveName(selectedNames: ['a', 'b']),
        'SynologyDrive.zip',
        reason:
            '★ 空 `archive_name` 官方是"不发这个参数"（走服务端默认），'
            '但我们这里必须给出**确定**的名字；给空串会让调用方误以为没名字',
      );
      expect(
        driveArchiveName(selectedNames: ['a', 'b'], folderName: '  '),
        'SynologyDrive.zip',
      );
    });

    test('★★ 非法字符必须被清洗（否则 Content-Disposition 存不下来）', () {
      final n = driveArchiveName(
        selectedNames: ['a', 'b'],
        folderName: 'a/b:c*d?e"f<g>h|i',
      );
      for (final bad in ['/', ':', '*', '?', '"', '<', '>', '|']) {
        expect(
          n.contains(bad),
          isFalse,
          reason:
              '★ 清洗后不能残留 `$bad` —— 它会让压缩包存不下来，'
              '而**服务端不会报错**',
        );
      }
      expect(n.endsWith('.zip'), isTrue);
    });

    test('★ 空白折叠成下划线，且不留首尾空白', () {
      expect(
        driveArchiveName(selectedNames: ['a', 'b'], folderName: '  我的   文档  '),
        '我的_文档.zip',
      );
    });

    test('★ 全是非法字符 ⇒ 剥成空后退化到 SynologyDrive（不给 "_.zip" 这种废名）', () {
      // ⚠️ 我原本把期望写成 `'_.zip'`，实现按"逐字符替换"也确实是 `'___'`。
      // 但那是个**没意义**的名字 —— 更好的是剥掉首尾下划线后退化。
      // 所以这里改的是**期望（选了更优行为）**，同时实现也修了折叠+剥边。
      expect(
        driveArchiveName(selectedNames: ['a', 'b'], folderName: '///'),
        'SynologyDrive.zip',
      );
      expect(
        driveArchiveName(selectedNames: ['a', 'b'], folderName: '   '),
        'SynologyDrive.zip',
      );
    });

    test('★ 名字里带 `/` 的**单个**文件也要清洗（防目录穿越观感）', () {
      final n = driveArchiveName(
        selectedNames: ['../etc/passwd'],
        folderName: 'x',
      );
      expect(n.contains('/'), isFalse);
    });

    test('★ 什么都没选 ⇒ 空串（调用方据此不显示"下载"）', () {
      expect(driveArchiveName(selectedNames: const []), '');
    });
  });
}
