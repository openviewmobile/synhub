// 相册**文件夹封面**的离线界面测试（第 327 轮）。
//
// 背景：`Browse.Folder:list additional=["thumbnail"]` 的候选一直在请求、
// `FotoFolderDto.covers` 一直在解析，但**界面从来没画**（文件夹行只有文件夹图标），
// 而为此写的 `FotoApi.folderCoverUrl` 也**零调用点**（§2.0.45 死功能）。
// 本轮把这条接上：候选里挑**第一个就绪**的（本机实测第一项是坏视频 `ame_defect`，
// 盲取会 404）→ 复用 `photoSmartAlbumCoverRequest`（`unit_id` ⇒ `type=unit`）；
// 一个就绪的都没有 ⇒ 画图标、**一个请求都不发**。
//
// 判据（都不是"布局断言"，而是**请求有没有发**与**关键字有没有出现**）：
//   ① 就绪候选 → 画出 `photo-folder-cover-<id>`，且真的发了一条 `type=unit` 的缩略请求；
//   ② 候选全坏 / 没有候选 → 不画封面，且 `downloads` **恰好为空**（不发必然 404 的请求）；
//   ③ 候选第一项坏、第二项就绪 → 取第二项的 unit_id（不是盲取第一项）。
import 'dart:convert';

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:synhub/src/core/theme/app_theme.dart';
import 'package:synhub/src/data/dto/foto_dto.dart';
import 'package:synhub/src/data/foto_api.dart';
import 'package:synhub/src/data/local/database.dart';
import 'package:synhub/src/dsm/webapi.dart';
import 'package:synhub/src/features/chat/chat_session_controller.dart'
    show chatDatabaseProvider;
import 'package:synhub/src/features/photos/photo_browse_page.dart';
import 'package:synhub/src/features/photos/photo_providers.dart';

import 'support/chat_harness.dart' show FakeTransport;

/// 1×1 PNG（能真的被 `Image.memory` 解码，避免"没图也过"的假绿）
final _png = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8DwHwAFAAH/'
  'q842iQAAAABJRU5ErkJggg==',
);

const _fotoTable = {
  'SYNO.API.Info': {'path': 'query.cgi', 'minVersion': 1, 'maxVersion': 1},
  'SYNO.Foto.Setting.User': {
    'path': 'entry.cgi',
    'minVersion': 1,
    'maxVersion': 4,
  },
  'SYNO.Foto.Browse.Item': {
    'path': 'entry.cgi',
    'minVersion': 1,
    'maxVersion': 9,
  },
  'SYNO.Foto.Browse.Folder': {
    'path': 'entry.cgi',
    'minVersion': 1,
    'maxVersion': 5,
  },
  'SYNO.Foto.Thumbnail': {
    'path': 'entry.cgi',
    'minVersion': 1,
    'maxVersion': 2,
  },
};

/// 一个封面候选（`additional.thumbnail` 数组的元素）
Map<String, dynamic> _candidate({
  required String unitId,
  String sm = 'ready',
  String cacheKey = '',
}) => {
  'sm': sm,
  'm': sm,
  'xl': sm,
  'unit_id': unitId,
  'cache_key': cacheKey,
};

Map<String, dynamic> _folder(
  String id,
  String name, {
  List<Map<String, dynamic>>? covers,
}) => {
  'id': id,
  'name': name,
  'parent': '0',
  'item_count': 3,
  if (covers != null) 'additional': {'thumbnail': covers},
};

/// 挂一个相册文件夹页（`folder` 是"当前所在的文件夹"）
Future<({FakeTransport transport, ProviderContainer container})> _pumpFolderPage(
  WidgetTester tester, {
  required Map<String, Map<String, dynamic>> responses,
  Map<String, List<int>> bytesByUrl = const {},
  required void Function(FakeTransport t) inspect,
}) async {
  final t = FakeTransport(responses, {...FakeTransport.table, ..._fotoTable});
  t.bytesByUrl.addAll(bytesByUrl);
  final api = DsmWebApi(t);
  await api.discover();
  await api.login(account: 'a', password: 'b');
  final db = ChatDatabase(NativeDatabase.memory());
  final c = ProviderContainer(
    overrides: [
      chatDatabaseProvider.overrideWithValue(db),
      fotoApiProvider.overrideWithValue(FotoApi(api)),
    ],
  );
  addTearDown(db.close);
  addTearDown(c.dispose);
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: c,
      child: MaterialApp(
        theme: AppTheme.dark(),
        home: const PhotoFolderPage(
          folder: FotoFolderDto(id: '0', name: 'root'),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
  inspect(t);
  return (transport: t, container: c);
}

void main() {
  testWidgets('① 就绪候选 → 文件夹行画出封面，且请求是 type=unit', (tester) async {
    late FakeTransport seen;
    await _pumpFolderPage(
      tester,
      responses: {
        'SYNO.Foto.Browse.Folder.list': {
          'list': [
            _folder(
              '267',
              '真机验收',
              covers: [_candidate(unitId: '9428', cacheKey: 'ck_ok')],
            ),
          ],
        },
      },
      bytesByUrl: {'9428': _png},
      inspect: (t) => seen = t,
    );

    expect(
      find.byKey(const Key('photo-folder-cover-267')),
      findsOneWidget,
      reason: '有就绪候选就必须画封面（不是文件夹图标）',
    );
    final thumbCalls = seen.downloads
        .where((u) => u.contains('Thumbnail'))
        .toList();
    expect(thumbCalls, hasLength(1), reason: seen.downloads.join('\n'));
    expect(thumbCalls.single, contains('type=%22unit%22'), reason: thumbCalls.single);
    expect(thumbCalls.single, contains('9428'), reason: 'id 必须是候选的 unit_id');
    expect(thumbCalls.single, contains('ck_ok'), reason: '有 cache_key 就带上');
  });

  testWidgets('② 候选全坏 / 没有候选 → 不画封面，且一个请求都不发', (tester) async {
    late FakeTransport seen;
    await _pumpFolderPage(
      tester,
      responses: {
        'SYNO.Foto.Browse.Folder.list': {
          'list': [
            _folder(
              '268',
              '坏封面目录',
              covers: [_candidate(unitId: '9429', sm: 'ame_defect')],
            ),
            _folder('269', '没给候选的目录'),
          ],
        },
      },
      inspect: (t) => seen = t,
    );

    expect(find.byKey(const Key('photo-folder-cover-268')), findsNothing);
    expect(find.byKey(const Key('photo-folder-cover-269')), findsNothing);
    expect(
      seen.downloads.where((u) => u.contains('Thumbnail')),
      isEmpty,
      reason: '非就绪候选不许发必然 404 的请求（真机第一项就是坏视频）',
    );
    // 行本身还在（退化是"画图标"，不是"行消失"）
    expect(find.text('坏封面目录'), findsOneWidget);
    expect(find.text('没给候选的目录'), findsOneWidget);
  });

  testWidgets('③ 第一项坏、第二项就绪 → 取第二项的 unit_id', (tester) async {
    late FakeTransport seen;
    await _pumpFolderPage(
      tester,
      responses: {
        'SYNO.Foto.Browse.Folder.list': {
          'list': [
            _folder(
              '270',
              '混合候选',
              covers: [
                _candidate(unitId: '9430', sm: 'ame_defect'),
                _candidate(unitId: '9431', sm: 'ready'),
              ],
            ),
          ],
        },
      },
      bytesByUrl: {'9431': _png},
      inspect: (t) => seen = t,
    );

    expect(find.byKey(const Key('photo-folder-cover-270')), findsOneWidget);
    final thumbCalls = seen.downloads
        .where((u) => u.contains('Thumbnail'))
        .toList();
    expect(thumbCalls, hasLength(1), reason: seen.downloads.join('\n'));
    expect(thumbCalls.single, contains('9431'), reason: '必须跳过坏的第一项');
    expect(
      thumbCalls.single.contains('9430'),
      isFalse,
      reason: '不许盲取第一项 —— ${thumbCalls.single}',
    );
  });
}
