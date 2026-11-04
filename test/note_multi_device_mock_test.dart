// ★★★ 第 116 轮 / 台账 M7：**多设备一致性** —— 用 Mock 模拟"两台设备"
// （用户规则 B2：真机无法验证的用 Mock 验证）。
//
// 场景（台账原文："单设备无法验证"）：
//   设备 A（另一台手机）先把同一条笔记改成 v2；
//   设备 B（本机）离线时基于 **v1** 改了同一条，队列里压着一条待推送。
//
// 要守的**安全性质**（比功能更重要）：
//   ① `flushPending` 不能把 v1 的改动**盲目覆盖** v2（服务端会拒，
//      而我们的实现必须**保住本地待推送项**——丢数据才是灾难）；
//   ② 下一次 `sync()` 必须把这条**识别为冲突**，并且**两边内容都给出**；
//   ③ 用户选"以服务端为准"后，本地待推送项才被清掉（显式裁决，不静默）。
import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:synhub/src/dsm/webapi.dart';
import 'package:synhub/src/data/local/database.dart';
import 'package:synhub/src/features/chat/chat_session_controller.dart';
import 'package:synhub/src/features/notes/note_providers.dart';
import 'package:synhub/src/features/notes/note_sync.dart';

import 'package:synhub/src/data/note_api.dart';

import 'support/chat_harness.dart' show FakeTransport;

const _table = {
  'SYNO.API.Info': {'path': 'query.cgi', 'minVersion': 1, 'maxVersion': 1},
  'SYNO.NoteStation.Note': {
    'path': 'entry.cgi',
    'minVersion': 1,
    'maxVersion': 4,
  },
  'SYNO.NoteStation.Notebook': {
    'path': 'entry.cgi',
    'minVersion': 1,
    'maxVersion': 2,
  },
  'SYNO.NoteStation.Todo': {
    'path': 'entry.cgi',
    'minVersion': 1,
    'maxVersion': 2,
  },
};

void main() {
  group('116. 多设备一致性（Mock 模拟两台设备）', () {
    late FakeTransport t;
    late ProviderContainer container;

    Future<void> boot(Map<String, Map<String, dynamic>> responses) async {
      t = FakeTransport(responses, {...FakeTransport.table, ..._table});
      final api = DsmWebApi(t);
      await api.discover();
      await api.login(account: 'a', password: 'b');
      container = ProviderContainer(
        overrides: [
          noteApiProvider.overrideWithValue(NoteStationApi(api)),
          chatDatabaseProvider.overrideWith((ref) {
            final db = ChatDatabase(NativeDatabase.memory());
            ref.onDispose(db.close);
            return db;
          }),
        ],
      );
      addTearDown(container.dispose);
    }

    Map<String, Map<String, dynamic>> server({
      required String ver,
      required String html,
    }) => {
      'SYNO.NoteStation.Notebook.list': {
        'notebooks': [
          {'object_id': 'nb1', 'title': '本', 'preset': true},
        ],
      },
      'SYNO.NoteStation.Note.list': {
        'notes': [
          {
            'object_id': 'n1',
            'title': '会议',
            'parent_id': 'nb1',
            'ver': ver,
            'content': html,
            'mtime': 100,
          },
        ],
        'total': 1,
      },
      'SYNO.NoteStation.Note.get': {
        'object_id': 'n1',
        'title': '会议',
        'parent_id': 'nb1',
        'ver': ver,
        'content': html,
        'mtime': 100,
      },
      'SYNO.NoteStation.Todo.list': {'todos': <dynamic>[]},
    };

    test('★ 设备A 改成 v2 后，设备B 基于 v1 的待推送项**不被盲覆盖且不丢**', () async {
      await boot(server(ver: '1', html: '<p>原始</p>'));
      final sync = container.read(noteSyncProvider.notifier);
      await sync.sync(); // 设备B 先拿到 v1

      // 设备B 离线改（基于 v1）→ 队列里有一条待推送
      await saveOffline(
        container.read(noteStoreProvider),
        sync,
        objectId: 'n1',
        title: '会议',
        parentId: 'nb1',
        html: '<p>设备B的改动</p>',
        ver: '1',
      );
      // 队列刚写入，计数要主动刷一次（notifier 只在 sync/flush 后自刷）
      await sync.refreshPending();
      expect(container.read(noteSyncProvider).pending, 1);

      // 设备A 在服务端改成 v2（Mock 换响应）
      t.responses['SYNO.NoteStation.Note.get'] = server(
        ver: '2',
        html: '<p>设备A的改动</p>',
      )['SYNO.NoteStation.Note.get']!;
      t.responses['SYNO.NoteStation.Note.list'] = server(
        ver: '2',
        html: '<p>设备A的改动</p>',
      )['SYNO.NoteStation.Note.list']!;

      // 设备B 此时推送：Mock 让服务端**按版本错拒绝**（v1 已过期）
      // —— 真实 DSM 在 ver 过期时就是回错误码，这样才验到"推送失败"分支
      t.failures['SYNO.NoteStation.Note.set'] = 1008;
      await sync.flushPending();
      final after = container.read(noteSyncProvider);
      expect(
        after.pending,
        1,
        reason: '推送失败必须**保住**本地改动，绝不能丢数据',
      );

      // 下一次 sync 必须把这条识别为冲突，且两边内容都在
      await sync.sync();
      final conflicts = container.read(noteSyncProvider).conflicts;
      expect(conflicts, isNotEmpty, reason: '设备A/设备B 都改了 ⇒ 必须报冲突');
      final c = conflicts.first;
      expect(c.objectId, 'n1');
      expect(c.serverVer, '2');
      expect(c.serverContent, '<p>设备A的改动</p>');
      expect(c.localContent, '<p>设备B的改动</p>');
      expect(c.baseVer, '1');
    });

    test('★ M5：官方策略"两个都保留" —— 本地版另存为 `<标题> Conflict` 副本', () async {
      await boot(server(ver: '1', html: '<p>原始</p>'));
      final sync = container.read(noteSyncProvider.notifier);
      await sync.sync();
      await saveOffline(
        container.read(noteStoreProvider),
        sync,
        objectId: 'n1',
        title: '会议',
        parentId: 'nb1',
        html: '<p>设备B的改动</p>',
        ver: '1',
      );
      await sync.refreshPending();
      t.failures['SYNO.NoteStation.Note.set'] = 1008;
      t.responses['SYNO.NoteStation.Note.list'] = server(
        ver: '2',
        html: '<p>设备A的改动</p>',
      )['SYNO.NoteStation.Note.list']!;
      t.responses['SYNO.NoteStation.Note.get'] = server(
        ver: '2',
        html: '<p>设备A的改动</p>',
      )['SYNO.NoteStation.Note.get']!;
      t.responses['SYNO.NoteStation.Note.create'] = {
        'object_id': 'copy1',
        'ver': '1',
      };

      await sync.sync();
      final conflict = container.read(noteSyncProvider).conflicts.first;
      await sync.keepBothOnConflict(conflict);

      // ① 真的发了一次 create（本地那版另存）
      final creates = t.calls
          .where((c) => c['method'] == 'create')
          .toList(growable: false);
      expect(creates, hasLength(1), reason: '官方策略：把本地版另存为新笔记');
      expect(creates.single['title'], contains('会议'));
      expect(
        '${creates.single['title']}',
        contains('Conflict'),
        reason: '官方标题后缀来自 R.string.conflict（strings.xml:125）',
      );
      expect('${creates.single['parent_id']}', contains('nb1'),
          reason: '副本优先落回原笔记本（比官方 getDefaultNotebookId 更贴近预期）');
      expect('${creates.single['content']}', contains('设备B的改动'));

      // ② 原笔记随后以服务端版为准（与官方同序）
      expect(container.read(noteSyncProvider).conflicts, isEmpty);
      expect(container.read(noteSyncProvider).pending, 0);
    });

    test('★ 用户选"以服务端为准"后，本地待推送项才被清掉（显式裁决）', () async {
      await boot(server(ver: '1', html: '<p>原始</p>'));
      final sync = container.read(noteSyncProvider.notifier);
      await sync.sync();
      await saveOffline(
        container.read(noteStoreProvider),
        sync,
        objectId: 'n1',
        title: '会议',
        parentId: 'nb1',
        html: '<p>设备B的改动</p>',
        ver: '1',
      );
      await sync.refreshPending();
      // 与场景一致：设备B 的推送会被服务端按版本错拒绝（待推送项因此留着）
      t.failures['SYNO.NoteStation.Note.set'] = 1008;
      t.responses['SYNO.NoteStation.Note.list'] = server(
        ver: '2',
        html: '<p>设备A的改动</p>',
      )['SYNO.NoteStation.Note.list']!;
      t.responses['SYNO.NoteStation.Note.get'] = server(
        ver: '2',
        html: '<p>设备A的改动</p>',
      )['SYNO.NoteStation.Note.get']!;

      await sync.sync();
      final conflict = container.read(noteSyncProvider).conflicts.first;
      expect(container.read(noteSyncProvider).pending, 1);

      await sync.resolveWithServer(conflict);
      expect(
        container.read(noteSyncProvider).pending,
        0,
        reason: '显式裁决后才清队列',
      );
      expect(container.read(noteSyncProvider).conflicts, isEmpty);
    });
  });
}
