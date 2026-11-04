// D16 守卫（r719）：Photos「收藏」为空时**必须给一句说明**。
//
// 真机像素 `p12_photos_favorites.png`（r715）当时没出现空态文案 —— 那次 Mock 的
// `SYNO.Foto.Browse.Item&method=list` 回 `119`，页面走的是**错误态**，不是空态；
// 所以这条缺陷原来"看着像没接文案"。本用例直接把收藏 provider 覆写成空列表，
// 钉住"空 ⇒ 有 `photoEmptyFavoritesTitle` / `photoEmptyFavoritesMessage`"。
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:synhub/src/core/i18n/l10n.dart';
import 'package:synhub/src/data/dto/foto_dto.dart';
import 'package:synhub/src/features/photos/photo_browse_page.dart';
import 'package:synhub/src/features/photos/photo_providers.dart';

void main() {
  testWidgets('收藏为空：出标题与说明，不是一片空白', (tester) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          photoSectionProvider.overrideWith(_FixedSection.new),
          photoFavoritesProvider.overrideWith(
            (ref) async => <FotoItemDto>[],
          ),
        ],
        child: const MaterialApp(home: PhotoBrowsePage()),
      ),
    );
    await tester.pump(const Duration(milliseconds: 300));

    final t = currentText();
    expect(find.text(t.photoEmptyFavoritesTitle), findsOneWidget,
        reason: '收藏空态缺标题（D16）');
    expect(find.text(t.photoEmptyFavoritesMessage), findsOneWidget,
        reason: '收藏空态缺说明（D16）');
  });
}

/// 固定选中「收藏」分节。
class _FixedSection extends PhotoSectionNotifier {
  @override
  PhotoSection build() => PhotoSection.favorites;
}

// 说明：Notifier 的 `overrideWith` 只收工厂（不接参数），所以直接用 `_FixedSection.new`。
