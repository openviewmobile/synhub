// W1-2：封面**两级来源 + 明确占位**的离线测试。
//
// 钉死三件事（用户明确要求"内嵌 + 服务器缩略图两级、缺一不可、不许空白"）：
//   1. 有内嵌封面 → 用内嵌（第一级优先）；
//   2. 没有内嵌但有服务端缩略图 → 用缩略图（第二级兜底）；
//   3. 两级都没有 → 画**明确占位**（带 Key + 说明），而不是空白框。
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:synhub/src/features/media/media_cover.dart';
import 'package:synhub/src/features/media/media_cover_provider.dart';
import 'package:synhub/src/features/media/media_cover_view.dart';
import 'package:synhub/src/core/theme/app_theme.dart';
import 'package:synhub/src/features/media/media_source.dart'
    show MediaKind;

final Uint8List _png = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAIAAACQd1PeAAAADElEQVR4nGP4z8AAAAMB'
  'AQDJ/pLvAAAAAElFTkSuQmCC',
);

MediaCoverKey _key() => const MediaCoverKey(
  cacheKey: 'k',
  uri: 'https://fake.test/webdav/a.mp3',
  kind: MediaKind.audio,
  extension: 'mp3',
);

Future<void> _pump(
  WidgetTester tester,
  Widget child, {
  MediaCover? cover,
}) async {
  final container = ProviderContainer(
    overrides: [mediaCoverProvider.overrideWith((ref, key) async => cover)],
  );
  addTearDown(container.dispose);
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(theme: AppTheme.dark(), home: Scaffold(body: child)),
    ),
  );
  await tester.pump();
  await tester.pump();
}

void main() {
  testWidgets('① 有内嵌封面 → 第一级优先，缩略图不参与', (tester) async {
    await _pump(
      tester,
      MediaCoverLayers(
        embedded: _key(),
        thumbBytes: _png,
        placeholder: const MediaCoverPlaceholder(),
      ),
      cover: MediaCover(bytes: _png, mime: 'image/png', source: 'mp3/id3v2.3'),
    );
    expect(find.byType(Image), findsOneWidget);
    expect(find.byType(MediaCoverPlaceholder), findsNothing);
  });

  testWidgets('② 没有内嵌、有服务端缩略图 → 第二级兜底', (tester) async {
    await _pump(
      tester,
      MediaCoverLayers(
        embedded: _key(),
        thumbBytes: _png,
        placeholder: const MediaCoverPlaceholder(),
      ),
      cover: null,
    );
    expect(find.byType(Image), findsOneWidget);
    expect(find.byType(MediaCoverPlaceholder), findsNothing);
  });

  testWidgets('③ 两级都没有 → 明确占位（不是空白）', (tester) async {
    await _pump(
      tester,
      MediaCoverLayers(
        embedded: _key(),
        thumbBytes: null,
        placeholder: const MediaCoverPlaceholder(key: Key('cover-placeholder')),
      ),
      cover: null,
    );
    expect(find.byKey(const Key('cover-placeholder')), findsOneWidget);
    expect(find.byType(Image), findsNothing);
    expect(find.text(mediaCoverUnavailableText()), findsOneWidget);
  });

  testWidgets('海报背景同样支持服务端缩略图兜底', (tester) async {
    await _pump(
      tester,
      const MediaCoverBackdrop(
        request: null,
        thumbBytes: null,
        fallback: MediaCoverPlaceholder(key: Key('backdrop-placeholder')),
      ),
    );
    // 这里 thumbBytes 为 null（const），只验 fallback 走明确占位
    expect(find.byKey(const Key('backdrop-placeholder')), findsOneWidget);
  });

  testWidgets('海报背景有缩略图字节 → 画图（不落回 fallback）', (tester) async {
    await _pump(
      tester,
      MediaCoverBackdrop(
        request: null,
        thumbBytes: _png,
        fallback: const MediaCoverPlaceholder(key: Key('backdrop-placeholder')),
      ),
    );
    expect(find.byType(Image), findsOneWidget);
    expect(find.byKey(const Key('backdrop-placeholder')), findsNothing);
  });
}
