// P1 尾巴：`Note.Polling`（大/加密笔记的轮询保存）与笔记共享。
//
// 形态全部来自 NAS 上实际装的 **NoteStation 2.6.10-3938**：
//   * `webapi/SYNO.NoteStation.lib`：`Note.Polling` maxVersion=3，v1–v3 都是
//     `set set_status set_stop copy copy_status copy_stop create create_status create_stop`；
//     `Permission` v1 `set delete`、`Permission.Public|User|Group` v1 `set delete`、
//     `Shard.Link` v1 `get`、`Share.Priv` v1–2 `list`（`allowUser` 全含 `normal.*`）；
//   * `ui/notestation.js`：轮询只在**加密笔记**或**带 token 的冲突覆盖**时启用，
//     `set_status` 每 1s 一次、`finish && success` 才 `set_stop` 再 `getNote`；
//     共享里 `perm` 是 `"ro"`/`"rw"` 字符串，公开链接用 `Shard.Link/get {mode:"public"}`；
//   * `scripts/create_table.sql`：`note`/`notebook` 都有 `acl JSON` 列，
//     `dsm_user` 的 key 是 **uid**、值里才有 `name`/`perm`/`inherit`。
import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:synhub/src/core/theme/app_theme.dart';
import 'package:synhub/src/data/dto/note_acl_dto.dart';
import 'package:synhub/src/data/dto/note_dto.dart';
import 'package:synhub/src/data/local/database.dart';
import 'package:synhub/src/data/note_api.dart';
import 'package:synhub/src/dsm/webapi.dart';
import 'package:synhub/src/features/chat/chat_session_controller.dart'
    show chatDatabaseProvider;
import 'package:synhub/src/features/notes/note_providers.dart';
import 'package:synhub/src/features/notes/note_share_page.dart';

import 'support/chat_harness.dart' show FakeTransport;

const _noteTable = {
  'SYNO.API.Info': {'path': 'query.cgi', 'minVersion': 1, 'maxVersion': 1},
  'SYNO.NoteStation.Note': {
    'path': 'entry.cgi',
    'minVersion': 1,
    'maxVersion': 3,
  },
  'SYNO.NoteStation.Note.Polling': {
    'path': 'entry.cgi',
    'minVersion': 1,
    'maxVersion': 3,
  },
  'SYNO.NoteStation.Permission': {
    'path': 'entry.cgi',
    'minVersion': 1,
    'maxVersion': 1,
  },
  'SYNO.NoteStation.Permission.Public': {
    'path': 'entry.cgi',
    'minVersion': 1,
    'maxVersion': 1,
  },
  'SYNO.NoteStation.Permission.User': {
    'path': 'entry.cgi',
    'minVersion': 1,
    'maxVersion': 1,
  },
  'SYNO.NoteStation.Permission.Group': {
    'path': 'entry.cgi',
    'minVersion': 1,
    'maxVersion': 1,
  },
  'SYNO.NoteStation.Shard.Link': {
    'path': 'entry.cgi',
    'minVersion': 1,
    'maxVersion': 1,
  },
  'SYNO.NoteStation.Share.Priv': {
    'path': 'entry.cgi',
    'minVersion': 1,
    'maxVersion': 2,
  },
};

Future<NoteStationApi> _api(FakeTransport t) async {
  final api = DsmWebApi(t);
  await api.discover();
  await api.login(account: 'a', password: 'b');
  return NoteStationApi(api);
}

NoteDto _note({
  String id = 'n1',
  String title = '周会纪要',
  bool encrypt = false,
  NoteAcl acl = NoteAcl.none,
}) => NoteDto(
  objectId: id,
  title: title,
  parentId: 'nb1',
  ver: '1.0',
  encrypt: encrypt,
  acl: acl,
);

Future<({FakeTransport t, ProviderContainer container})> _boot(
  Map<String, Map<String, dynamic>> responses, {
  Map<String, int> failures = const {},
}) async {
  final t = FakeTransport(responses, {...FakeTransport.table, ..._noteTable});
  t.onCall = (params) {
    final key = '${params['api']}.${params['method']}';
    if (responses.containsKey(key)) return responses[key]!;
    return {'success': true};
  };
  t.failures.addAll(failures);
  final api = await _api(t);
  final container = ProviderContainer(
    overrides: [
      noteApiProvider.overrideWithValue(api),
      chatDatabaseProvider.overrideWith((ref) {
        final db = ChatDatabase(NativeDatabase.memory());
        ref.onDispose(db.close);
        return db;
      }),
    ],
  );
  addTearDown(container.dispose);
  return (t: t, container: container);
}

Future<void> _pump(
  WidgetTester tester,
  ProviderContainer container,
  Widget child,
) async {
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(theme: AppTheme.dark(), home: child),
    ),
  );
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 50));
}

/// 只留下 NoteStation 的调用（`discover`/`login` 等 DSM 通用请求会混在 calls 里）
List<Map<String, dynamic>> _nsCalls(FakeTransport t) => t.calls
    .where((c) => '${c['api']}'.startsWith('SYNO.NoteStation.'))
    .toList(growable: false);

void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;

  group('Note.Polling · 接口层', () {
    test('什么时候走轮询：加密 / 带 token / 超大正文', () {
      expect(NoteStationApi.needsPolling(html: 'hi'), isFalse);
      expect(NoteStationApi.needsPolling(html: 'hi', encrypt: true), isTrue);
      expect(NoteStationApi.needsPolling(html: 'hi', token: 'abc'), isTrue);
      final huge = 'x' * (NoteStationApi.pollingThresholdBytes + 1);
      expect(NoteStationApi.needsPolling(html: huge), isTrue);
      // 多字节字符按 **UTF-8 字节数** 算（不是字符数）
      final cjk = '汉' * (NoteStationApi.pollingThresholdBytes ~/ 3 + 1);
      expect(NoteStationApi.needsPolling(html: cjk), isTrue);
    });

    test('保存：set → set_status（未完成要再问）→ set_stop → getNote', () async {
      var polls = 0;
      final t = FakeTransport(const {}, {
        ...FakeTransport.table,
        ..._noteTable,
      });
      t.onCall = (params) {
        switch ('${params['api']}.${params['method']}') {
          case 'SYNO.NoteStation.Note.Polling.set':
            return {'task_id': 'T1'};
          case 'SYNO.NoteStation.Note.Polling.set_status':
            polls++;
            if (polls == 1) {
              return {
                'succ': true,
                'resp': {'finish': false},
              };
            }
            return {
              'succ': true,
              'resp': {
                'finish': true,
                'success': true,
                'data': [
                  {'object_id': 'n1', 'ver': '2.0'},
                ],
              },
            };
          case 'SYNO.NoteStation.Note.get':
            return {'object_id': 'n1', 'ver': '2.0', 'title': '周会纪要'};
          default:
            return {'success': true};
        }
      };
      final api = await _api(t);
      final note = await api.setNotePolling(
        objectId: 'n1',
        ver: '1.0',
        title: '周会纪要',
        html: '<p>hi</p>',
        encrypt: true,
      );
      expect(note?.ver, '2.0', reason: '轮询结束后按 resp.data[0].ver 重新 getNote');
      expect(polls, 2, reason: 'finish 之前每秒再问一次');

      final calls = _nsCalls(
        t,
      ).map((c) => '${c['api']}.${c['method']}').toList(growable: false);
      expect(calls, [
        'SYNO.NoteStation.Note.Polling.set',
        'SYNO.NoteStation.Note.Polling.set_status',
        'SYNO.NoteStation.Note.Polling.set_status',
        'SYNO.NoteStation.Note.Polling.set_stop',
        'SYNO.NoteStation.Note.get',
      ]);
      final setCall = _nsCalls(t).first;
      expect('${setCall['version']}', '3');
      expect(setCall['object_id'], '"n1"');
      expect(setCall['encrypt'], 'true');
      expect(setCall['commit_msg'], contains('Flutter'));
    });

    test('真机形状：data 直接是任务状态对象，`finish:false` 时 error 117 不算失败', () async {
      // 2026-09-20 在装的 NAS（NoteStation 2.6.10-3938）上实测：
      //   create      → {task_id: 'demo_user/NoteStation1789873518362AB0B0'}
      //   第一次 status → {auto_remove:false, error:{code:117}, finish:false,
      //                    info:{…原始请求参数…}, success:false}
      //   第二次 status → {auto_remove:false, finish:true, success:true,
      //                    data:{object_id:'1028_p8DZ…', acl:{}, …}}
      //   —— **没有 `succ`/`resp` 外壳**（那是 synowebapi 那层的包装）
      var polls = 0;
      final t = FakeTransport(const {}, {
        ...FakeTransport.table,
        ..._noteTable,
      });
      t.onCall = (params) {
        switch ('${params['method']}') {
          case 'set':
            return {'task_id': 'demo_user/NoteStation1'};
          case 'set_status':
            polls++;
            if (polls == 1) {
              return {
                'auto_remove': false,
                'error': {'code': 117},
                'finish': false,
                'info': {'api': 'SYNO.NoteStation.Note.Polling'},
                'success': false,
              };
            }
            return {
              'auto_remove': false,
              'finish': true,
              'success': true,
              'data': [
                {'object_id': 'n1', 'ver': '9.0', 'acl': <String, dynamic>{}},
              ],
            };
          case 'get':
            return {'object_id': 'n1', 'ver': '9.0'};
          default:
            return {'success': true};
        }
      };
      final api = await _api(t);
      final note = await api.setNotePolling(
        objectId: 'n1',
        ver: '1.0',
        html: '<p>x</p>',
        encrypt: true,
      );
      expect(polls, 2);
      expect(note?.ver, '9.0');
      expect(
        _nsCalls(t).any((c) => '${c['method']}' == 'set_stop'),
        isTrue,
        reason: 'finish 之后必须发 set_stop（官方顺序）',
      );
    });

    test('succ 不是 true → 把 resp 当错误抛（官方同款分支）', () async {
      final t = FakeTransport(const {}, {
        ...FakeTransport.table,
        ..._noteTable,
      });
      t.onCall = (params) {
        if ('${params['method']}' == 'set') return {'task_id': 'T1'};
        if ('${params['method']}' == 'set_status') {
          return {
            'succ': false,
            'resp': {'code': 1023},
          };
        }
        return {'success': true};
      };
      final api = await _api(t);
      await expectLater(
        api.setNotePolling(
          objectId: 'n1',
          ver: '1.0',
          html: '<p>x</p>',
          encrypt: true,
        ),
        throwsA(isA<DsmApiException>().having((e) => e.code, 'code', 1023)),
      );
    });

    test('finish 但 success=false → 报 resp.error', () async {
      final t = FakeTransport(const {}, {
        ...FakeTransport.table,
        ..._noteTable,
      });
      t.onCall = (params) {
        if ('${params['method']}' == 'set') return {'task_id': 'T1'};
        if ('${params['method']}' == 'set_status') {
          return {
            'succ': true,
            'resp': {
              'finish': true,
              'success': false,
              'error': {'code': 1022},
            },
          };
        }
        return {'success': true};
      };
      final api = await _api(t);
      await expectLater(
        api.setNotePolling(
          objectId: 'n1',
          ver: '1.0',
          html: '<p>x</p>',
          encrypt: true,
        ),
        throwsA(isA<DsmApiException>().having((e) => e.code, 'code', 1022)),
      );
      expect(
        _nsCalls(t).any((c) => '${c['method']}' == 'set_stop'),
        isFalse,
        reason: '失败分支官方不会发 set_stop',
      );
    });

    test('create / copy 也各有自己的前缀（官方三套）', () async {
      final t = FakeTransport(const {}, {
        ...FakeTransport.table,
        ..._noteTable,
      });
      t.onCall = (params) {
        final m = '${params['method']}';
        if (m == 'create' || m == 'copy') return {'task_id': 'T1'};
        if (m == 'create_status' || m == 'copy_status') {
          return {
            'succ': true,
            'resp': {
              'finish': true,
              'success': true,
              'data': [
                {'object_id': 'new1', 'ver': '1.0'},
              ],
            },
          };
        }
        if ('${params['api']}' == 'SYNO.NoteStation.Note') {
          return {'object_id': 'new1', 'ver': '1.0'};
        }
        return {'success': true};
      };
      final api = await _api(t);
      await api.createNotePolling(
        title: 'T',
        parentId: 'nb1',
        html: '<p>x</p>',
      );
      await api.copyNotePolling(objectId: 'n1', ver: '1.0');
      final ms = _nsCalls(t).map((c) => '${c['method']}').toList();
      expect(
        ms,
        containsAllInOrder(['create', 'create_status', 'create_stop']),
      );
      expect(ms, containsAllInOrder(['copy', 'copy_status', 'copy_stop']));
    });
  });

  group('笔记共享 · 接口层', () {
    test('公开分享：先开总开关，再 Permission.Public/set（perm 是字符串 ro/rw）', () async {
      final t = FakeTransport(const {}, {
        ...FakeTransport.table,
        ..._noteTable,
      });
      final api = await _api(t);
      await api.setPublicPermission(
        objectId: 'n1',
        perm: NoteSharePerm.readOnly,
      );
      final calls = _nsCalls(t);
      expect(calls[0]['api'], 'SYNO.NoteStation.Permission');
      expect(calls[0]['enabled'], 'true');
      expect(calls[1]['api'], 'SYNO.NoteStation.Permission.Public');
      expect('${calls[1]['version']}', '1');
      expect(calls[1]['object_id'], '"n1"');
      expect(calls[1]['perm'], '"ro"');

      await api.setPublicPermission(
        objectId: 'n1',
        perm: NoteSharePerm.readWrite,
      );
      expect(_nsCalls(t).last['perm'], '"rw"');

      await api.deletePublicPermission('n1');
      expect(_nsCalls(t).last['api'], 'SYNO.NoteStation.Permission.Public');
      expect('${_nsCalls(t).last['method']}', 'delete');
      expect(_nsCalls(t).last['object_id'], '"n1"');
    });

    test('用户/群组：set 与 delete 的参数名官方白名单', () async {
      final t = FakeTransport(const {}, {
        ...FakeTransport.table,
        ..._noteTable,
      });
      final api = await _api(t);
      await api.setUserPermission(
        objectId: 'n1',
        username: 'demo_user',
        perm: NoteSharePerm.readWrite,
        uid: '4',
      );
      var call = _nsCalls(t).last;
      expect(call['api'], 'SYNO.NoteStation.Permission.User');
      expect(call['username'], '"demo_user"');
      expect(call['perm'], '"rw"');
      expect(call['uid'], '"4"');

      await api.setGroupPermission(
        objectId: 'n1',
        groupname: 'users',
        perm: NoteSharePerm.readOnly,
        gid: '100',
      );
      call = _nsCalls(t).last;
      expect(call['api'], 'SYNO.NoteStation.Permission.Group');
      expect(call['groupname'], '"users"');
      expect(call['gid'], '"100"');

      await api.deleteUserPermission(
        objectId: 'n1',
        username: 'demo_user',
        uid: '4',
      );
      call = _nsCalls(t).last;
      expect('${call['method']}', 'delete');
      expect(call['username'], '"demo_user"');

      await api.deleteGroupPermission(objectId: 'n1', groupname: 'users');
      call = _nsCalls(t).last;
      expect(call['api'], 'SYNO.NoteStation.Permission.Group');
      expect(call['groupname'], '"users"');
      expect(call.containsKey('gid'), isFalse, reason: '没给 gid 就不发空值');
    });

    test('公开链接：Shard.Link/get + mode=public → url', () async {
      final t = FakeTransport(
        const {
          'SYNO.NoteStation.Shard.Link.get': {
            'url': 'https://nas/ns/sharing/abc',
          },
        },
        {...FakeTransport.table, ..._noteTable},
      );
      t.onCall = (p) => p['method'] == 'get'
          ? {'url': 'https://nas/ns/sharing/abc'}
          : {'success': true};
      final api = await _api(t);
      final url = await api.publicShareUrl('n1');
      expect(url, 'https://nas/ns/sharing/abc');
      final call = _nsCalls(t).last;
      expect('${call['version']}', '1');
      expect(call['object_id'], '"n1"');
      expect(call['mode'], '"public"');
    });

    test('候选账号：Share.Priv/list v2 + query，解 list[]（含群组）', () async {
      final t = FakeTransport(const {}, {
        ...FakeTransport.table,
        ..._noteTable,
      });
      t.onCall = (p) => p['method'] == 'list'
          ? {
              'list': [
                {'name': 'demo_user', 'type': 'user'},
                {'name': 'users', 'type': 'group'},
                {'name': '', 'type': 'user'},
              ],
            }
          : {'success': true};
      final api = await _api(t);
      final list = await api.sharePrincipals(query: 'ku');
      expect(list.length, 2, reason: '空名字要丢掉');
      expect(list.first.name, 'demo_user');
      expect(list.last.type, 'group');
      final call = _nsCalls(t).last;
      expect('${call['version']}', '2', reason: '官方 store 用的是 v2');
      expect(call['query'], 'ku');
    });
  });

  group('ACL 解析（acl JSON 列）', () {
    test('dsm_user 的 key 是 uid、值里有名字/权限/继承', () {
      final acl = NoteAcl.fromJson({
        'enabled': true,
        'public': {'perm': 'ro', 'inherit': false},
        'dsm_user': {
          '4': {'name': 'demo_user', 'perm': 'rw', 'inherit': false},
          '7': {'name': 'guest', 'perm': 'ro', 'inherit': true},
        },
        'dsm_group': {
          '100': {'name': 'users', 'perm': 'ro'},
        },
      });
      expect(acl.enabled, isTrue);
      expect(acl.hasPublic, isTrue);
      expect(acl.publicPerm, NoteSharePerm.readOnly);
      expect(acl.users.map((e) => e.name), ['demo_user', 'guest']);
      expect(acl.users.firstWhere((e) => e.name == 'demo_user').id, '4');
      expect(
        acl.users.firstWhere((e) => e.name == 'demo_user').perm,
        NoteSharePerm.readWrite,
      );
      expect(acl.groups.single.name, 'users');
      expect(acl.groups.single.isGroup, isTrue);
      expect(acl.hasIndividual, isTrue, reason: 'public.inherit=false 就是单独授权');
    });

    test('烂数据不炸（缺 perm / 不是 map / 未知 perm 值）', () {
      expect(NoteAcl.fromJson(null).isEmpty, isTrue);
      expect(NoteAcl.fromJson('nope').isEmpty, isTrue);
      final acl = NoteAcl.fromJson({
        'dsm_user': {
          '4': {'name': 'a'},
          '5': 'oops',
          '6': {'name': 'b', 'perm': 'xx'},
        },
        'public': {'perm': 'xx'},
      });
      expect(acl.users, isEmpty);
      expect(acl.hasPublic, isFalse);
    });

    test('NoteDto 会把 acl 解析出来（`individual_shared` 仍是独立的列）', () {
      final note = NoteDto.fromJson({
        'object_id': 'n1',
        'ver': '1.0',
        'individual_shared': true,
        'acl': {
          'enabled': true,
          'public': {'perm': 'rw'},
        },
      });
      expect(note.individualShared, isTrue);
      expect(note.acl.publicPerm, NoteSharePerm.readWrite);
      expect(note.canShare, isTrue);
      expect(_note(encrypt: true).canShare, isFalse, reason: '加密笔记不能共享');
    });
  });

  group('共享页面', () {
    testWidgets('打开时显示现有 ACL（公开 + 用户 + 群组）', (tester) async {
      final acl = NoteAcl.fromJson({
        'enabled': true,
        'public': {'perm': 'ro'},
        'dsm_user': {
          '4': {'name': 'demo_user', 'perm': 'rw'},
        },
        'dsm_group': {
          '100': {'name': 'users', 'perm': 'ro'},
        },
      });
      final boot = await _boot(const {});
      await _pump(tester, boot.container, NoteSharePage(note: _note(acl: acl)));

      expect(find.text('共享'), findsOneWidget);
      expect(find.byKey(const Key('note-share-public-switch')), findsOneWidget);
      expect(find.textContaining('当前权限：只读'), findsOneWidget);
      expect(find.byKey(const Key('note-share-user-demo_user')), findsOneWidget);
      expect(find.byKey(const Key('note-share-group-users')), findsOneWidget);
    });

    testWidgets('打开公开分享 → Permission.Public/set + 取链接', (tester) async {
      final boot = await _boot(const {
        'SYNO.NoteStation.Note.get': {'object_id': 'n1', 'ver': '1.0'},
      });
      // Shard.Link/get 的回包
      boot.t.onCall = (params) {
        final key = '${params['api']}.${params['method']}';
        if (key == 'SYNO.NoteStation.Shard.Link.get') {
          return {'url': 'https://nas/ns/sharing/xyz'};
        }
        if (key == 'SYNO.NoteStation.Note.get') {
          return {
            'object_id': 'n1',
            'ver': '1.0',
            'acl': {
              'enabled': true,
              'public': {'perm': 'ro'},
            },
          };
        }
        return {'success': true};
      };
      await _pump(tester, boot.container, NoteSharePage(note: _note()));
      await tester.tap(find.byKey(const Key('note-share-public-switch')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));

      final kinds = _nsCalls(
        boot.t,
      ).map((c) => '${c['api']}.${c['method']}').toList(growable: false);
      expect(kinds, contains('SYNO.NoteStation.Permission.set'));
      expect(kinds, contains('SYNO.NoteStation.Permission.Public.set'));
      expect(kinds, contains('SYNO.NoteStation.Shard.Link.get'));
      expect(find.textContaining('nas/ns/sharing/xyz'), findsOneWidget);
      expect(find.textContaining('当前权限：只读'), findsOneWidget);
    });

    testWidgets('切权限 → Public/set perm=rw', (tester) async {
      final acl = NoteAcl.fromJson({
        'enabled': true,
        'public': {'perm': 'ro'},
      });
      final boot = await _boot(const {});
      boot.t.onCall = (params) {
        if ('${params['api']}.${params['method']}' ==
            'SYNO.NoteStation.Shard.Link.get') {
          return {'url': 'https://nas/x'};
        }
        if ('${params['api']}.${params['method']}' ==
            'SYNO.NoteStation.Note.get') {
          return {
            'object_id': 'n1',
            'ver': '1.0',
            'acl': {
              'enabled': true,
              'public': {'perm': 'rw'},
            },
          };
        }
        return {'success': true};
      };
      await _pump(tester, boot.container, NoteSharePage(note: _note(acl: acl)));
      await tester.tap(find.text('可编辑'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      final call = _nsCalls(
        boot.t,
      ).lastWhere((c) => '${c['api']}' == 'SYNO.NoteStation.Permission.Public');
      expect(call['perm'], '"rw"');
      expect(find.textContaining('当前权限：可编辑'), findsOneWidget);
    });

    testWidgets('取消某个用户的共享 → Permission.User/delete', (tester) async {
      final acl = NoteAcl.fromJson({
        'enabled': true,
        'dsm_user': {
          '4': {'name': 'demo_user', 'perm': 'rw'},
        },
      });
      final boot = await _boot(const {});
      boot.t.onCall = (params) =>
          '${params['api']}.${params['method']}' == 'SYNO.NoteStation.Note.get'
          ? {
              'object_id': 'n1',
              'ver': '1.0',
              'acl': {'enabled': true},
            }
          : {'success': true};
      await _pump(tester, boot.container, NoteSharePage(note: _note(acl: acl)));
      await tester.tap(
        find.descendant(
          of: find.byKey(const Key('note-share-user-demo_user')),
          matching: find.byType(IconButton),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      final call = _nsCalls(
        boot.t,
      ).lastWhere((c) => '${c['api']}' == 'SYNO.NoteStation.Permission.User');
      expect('${call['method']}', 'delete');
      expect(call['username'], '"demo_user"');
      expect(find.textContaining('已取消'), findsOneWidget);
    });

    testWidgets('加密笔记：说清楚不能共享，也不放任何入口', (tester) async {
      final boot = await _boot(const {});
      await _pump(
        tester,
        boot.container,
        NoteSharePage(note: _note(encrypt: true)),
      );
      expect(find.text('加密笔记不能共享'), findsWidgets);
      expect(find.byKey(const Key('note-share-public-switch')), findsNothing);
      expect(find.byKey(const Key('note-share-add')), findsNothing);
      expect(_nsCalls(boot.t), isEmpty, reason: '加密笔记不该发任何共享请求');
    });
  });
}
