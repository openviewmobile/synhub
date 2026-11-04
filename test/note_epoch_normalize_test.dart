// D22 守卫（r716）：显示边界必须容忍"秒 / 毫秒"两种 epoch 单位。
//
// 真机像素曾经出现 `2065-11-02`：笔记类接口按**毫秒**下发 `mtime`，
// 显示层按秒 `×1000` ⇒ 未来 40 年。
// 归一只放在**显示边界**（`formatFileTime`）：DTO 原值不动，
// 因为待办回写 `due_date` 必须保持毫秒（`test/note_widgets_test.dart` 已钉住）。
import 'package:flutter_test/flutter_test.dart';
import 'package:synhub/src/features/files/file_row.dart';

void main() {
  final now = DateTime(2025, 11, 4, 12);

  test('① 秒下发：正常格式化', () {
    final text = formatFileTime(1762200000, now: now);
    expect(text.isNotEmpty, isTrue);
    expect(text.contains('2065'), isFalse);
  });

  test('② 毫秒下发：不许出现未来年份（D22 的正支）', () {
    final text = formatFileTime(1762200000123, now: now);
    expect(text.isNotEmpty, isTrue);
    expect(text.contains('2065'), isFalse, reason: '又回到"未来 40 年"了：$text');
  });

  test('③ 两种单位对同一天给出同一个结果', () {
    expect(formatFileTime(1762200000, now: now),
        formatFileTime(1762200000123, now: now));
  });

  test('④ 0 / 负数不许炸，空串兜底', () {
    expect(formatFileTime(0, now: now), '');
    expect(() => formatFileTime(-1, now: now), returnsNormally);
  });
}
