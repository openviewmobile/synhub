// Synology Contacts 全量 API 的离线测试：**参数形态是重点**。
//
// 官方没有 Contacts 安卓 App，事实来源是「真机逐条取证 + 官方网页客户端 bundle」，
// 结论钉在 `docs/contacts-module-plan.md` §3.1。这里把每条都钉死，
// 回归时一眼能看出是谁把哪个参数改坏了：
//   * 回包键基本是**单数**（`addressbook`/`contact`/`label`/`principal`），
//     只有外部源是 `external_sources`；
//   * `Addressbook/create` 的 `is_public` 必须是**小写** `'false'`（`'False'` → 120）；
//   * `Contact/get` 要 v2 且 `ids` 是 JSON 数组串；`get_photo` 的参数是 `contact_ids`；
//   * `Label/*` 全部 v2；星标 = 给 `type:1` 的 Starred 标签 add_member；
//   * `Contact/toggle_*` 是**显示/隐藏**（`is_hidden`），不是星标；
//   * `import_preview` 把目标放**表单字段** `addressbook_id`，`import` 放**查询串** `id`；
//   * 导出走带 `_sid` 的直链（`method=export`），回 `text/vcard` 字节；
//   * CardDAV 地址 = `${origin}/carddav/${user}[/${uri}]`，`\` → `@@`。
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:synhub/src/data/contacts_api.dart';
import 'package:synhub/src/data/dto/contact_extras_dto.dart';
import 'package:synhub/src/dsm/webapi.dart';

import 'support/chat_harness.dart' show FakeTransport;

/// 真机 `SYNO.API.Info` 快照（Contacts 相关子集，DSM 7.4 / Contacts 1.0.11-20661）
const _contactsTable = {
  'SYNO.API.Info': {'path': 'query.cgi', 'minVersion': 1, 'maxVersion': 1},
  'SYNO.Contacts.Addressbook': {
    'path': 'entry.cgi',
    'minVersion': 1,
    'maxVersion': 1,
  },
  'SYNO.Contacts.Contact': {
    'path': 'entry.cgi',
    'minVersion': 1,
    'maxVersion': 2,
  },
  'SYNO.Contacts.Label': {
    'path': 'entry.cgi',
    'minVersion': 1,
    'maxVersion': 2,
  },
  'SYNO.Contacts.Info': {'path': 'entry.cgi', 'minVersion': 1, 'maxVersion': 2},
  'SYNO.Contacts.ExternalSource': {
    'path': 'entry.cgi',
    'minVersion': 1,
    'maxVersion': 1,
  },
};

/// 真机 `Addressbook/list` 回包（键是单数；type 2=Suggested/3=个人/4=团队）
Map<String, dynamic> _books() => {
  'addressbook': [
    {
      'id': 7,
      'name': 'Suggested',
      'member_count': 0,
      'mode': 3,
      'type': 2,
      'owned_shared': false,
      'shared_from': '',
      'shared_with': '',
      'uri': '8cc290ff-34ab-4c2b-bfec-3b0e73c1dbb6',
    },
    {
      'id': 6,
      'name': 'My Contacts',
      'member_count': 0,
      'mode': 3,
      'type': 3,
      'owned_shared': false,
      'uri': 'aaaabbbb-1111-2222-3333-444455556666',
    },
  ],
  'total': 2,
};

/// 真机 `Contact/list` 回包（列表项字段）
Map<String, dynamic> _contacts() => {
  'contact': [
    {
      'additional': {
        'label': [
          {'color': '', 'id': 3, 'name': 'Starred', 'type': 1},
        ],
      },
      'addressbook_id': 5,
      'company': 'Probe Inc',
      'department': '',
      'full_name': 'probe_联系人',
      'id': 12,
      'is_editable': true,
      'is_hidden': false,
      'photo': '',
      'primary_mail': 'probe@example.com',
      'primary_tel': '12345',
      'title': '',
      'usage_frequency': 0,
    },
  ],
  'offset': 0,
};

/// 真机 `Contact/get` v2 回包（含 `additional.contact_detail`）
Map<String, dynamic> _contactDetail() => {
  'contact': [
    {
      'addressbook_id': 6,
      'company': 'Probe Inc',
      'full_name': 'probe_联系人',
      'id': 12,
      'is_editable': true,
      'is_hidden': false,
      'photo': '',
      'additional': {
        'label': [
          {'id': 3, 'name': 'Starred', 'type': 1},
        ],
        'contact_detail': {
          'company': 'Probe Inc',
          'department': '',
          'full_name': 'probe_联系人',
          'mail': [
            {'data': 'probe@example.com', 'is_readonly': false},
          ],
          'name': {
            'additional_name': '',
            'family_name': 'Test',
            'given_name': 'Probe',
            'prefix': '',
            'suffix': '',
          },
          'note': 'hello from probe',
          'photo': '',
          'tel': [
            {'data': '12345', 'is_readonly': false},
          ],
        },
      },
    },
  ],
};

Future<({ContactsApi contacts, FakeTransport t})> _boot([
  Map<String, Map<String, dynamic>> responses = const {},
]) async {
  final t = FakeTransport(responses, {
    ...FakeTransport.table,
    ..._contactsTable,
  });
  final api = DsmWebApi(t);
  await api.discover();
  await api.login(account: 'a', password: 'b');
  return (contacts: ContactsApi(api), t: t);
}

void main() {
  group('ContactsApi：通讯录（Addressbook）', () {
    test('list 用 v1，回包键是单数 addressbook', () async {
      final b = await _boot({'SYNO.Contacts.Addressbook.list': _books()});
      final books = await b.contacts.addressbooks();

      final call = b.t.calls.last;
      expect(call['api'], 'SYNO.Contacts.Addressbook');
      expect(call['method'], 'list');
      expect(call['version'], '1');
      expect(books.map((x) => x.name), ['Suggested', 'My Contacts']);
      expect(books[1].id, '6');
      expect(books[1].type, 3, reason: 'type 3 = 个人通讯录');
      expect(books[1].uri, 'aaaabbbb-1111-2222-3333-444455556666');
    });

    test('create 的 is_public 必须是小写 false/true（大写回 120）', () async {
      final b = await _boot({
        'SYNO.Contacts.Addressbook.create': {'id': 12},
      });
      final id = await b.contacts.createAddressbook(name: 'probe_book');
      expect(id, '12');

      final call = b.t.calls.last;
      expect(call['name'], 'probe_book');
      expect(call['is_public'], 'false', reason: "'False' 真机回 120");

      await b.contacts.createAddressbook(name: 'pub', isPublic: true);
      expect(b.t.calls.last['is_public'], 'true');
    });

    test('set 是 {id,name}；delete 的 ids 是 JSON 数组串', () async {
      final b = await _boot({
        'SYNO.Contacts.Addressbook.set': <String, dynamic>{},
        'SYNO.Contacts.Addressbook.delete': <String, dynamic>{},
      });
      await b.contacts.setAddressbook(id: '12', name: 'renamed');
      expect(b.t.calls.last['id'], '12');
      expect(b.t.calls.last['name'], 'renamed');

      await b.contacts.deleteAddressbook('12');
      expect(b.t.calls.last['ids'], '["12"]');
    });

    test('copy_member 用 id（目标簿）、move_member 用 dest_id', () async {
      final b = await _boot({
        'SYNO.Contacts.Addressbook.copy_member': <String, dynamic>{},
        'SYNO.Contacts.Addressbook.move_member': <String, dynamic>{},
      });
      await b.contacts.copyContacts(targetId: '9', contactIds: ['1', '2']);
      expect(b.t.calls.last['id'], '9');
      expect(b.t.calls.last['contact_ids'], '["1","2"]');
      expect(b.t.calls.last.containsKey('dest_id'), isFalse);

      await b.contacts.moveContacts(destId: '9', contactIds: ['3']);
      expect(b.t.calls.last['dest_id'], '9');
      expect(b.t.calls.last['contact_ids'], '["3"]');
    });

    test(
      'set_addressbook_display 的 config 是 [{addressbook_id,status}]',
      () async {
        final b = await _boot({
          'SYNO.Contacts.Addressbook.set_addressbook_display':
              <String, dynamic>{},
        });
        await b.contacts.setAddressbookDisplay([
          (id: '7', status: 1),
          (id: '6', status: 0),
        ]);

        final call = b.t.calls.last;
        expect(jsonDecode(call['addressbook_display_config'] as String), [
          {'addressbook_id': '7', 'status': 1},
          {'addressbook_id': '6', 'status': 0},
        ], reason: '真机只有数组形态吃；对象形态回 120');
      },
    );

    test('share_addressbook 的 config 元素键是 id（不是 principal_id）', () async {
      final b = await _boot({
        'SYNO.Contacts.Addressbook.share_addressbook': <String, dynamic>{},
      });
      await b.contacts.shareAddressbook(
        addressbookId: '6',
        config: [(principalId: '4', mode: 1, status: 2)],
      );

      final call = b.t.calls.last;
      expect(call['addressbook_id'], '6');
      expect(jsonDecode(call['sharing_addressbook_config'] as String), [
        {'id': '4', 'mode': 1, 'status': 2},
      ]);
    });

    test('list_principal 带 addressbook_id/limit/offset', () async {
      final b = await _boot({
        'SYNO.Contacts.Addressbook.list_principal': {
          'principal': [
            {
              'account_name': 'syno.contacts.internal.everyone',
              'display_name': 'syno.contacts.internal.everyone',
              'id': 1,
              'is_shared': false,
              'member': [11, 4, 5],
              'mode': 0,
              'status': 2,
              'type': 2,
            },
          ],
          'offset': 0,
        },
      });
      final ps = await b.contacts.principals(addressbookId: '6');

      expect(b.t.calls.last['addressbook_id'], '6');
      expect(b.t.calls.last['limit'], '100');
      expect(ps.single.isGroup, isTrue, reason: 'type 2 = 群组');
      expect(ps.single.memberIds, ['11', '4', '5']);
    });
  });

  group('ContactsApi：联系人（Contact）', () {
    test('list 用 v2 + 服务端搜索/排序参数', () async {
      final b = await _boot({'SYNO.Contacts.Contact.list': _contacts()});
      final cs = await b.contacts.contacts(
        addressbookId: '5',
        labelId: '3',
        keyword: ' demo ',
        sort: ContactSort.company,
        descending: true,
      );

      final call = b.t.calls.last;
      expect(call['version'], '2');
      expect(call['addressbook_id'], '5');
      expect(call['label_id'], '3');
      expect(call['keyword'], '["demo"]', reason: 'keyword 是 JSON 数组串');
      expect(call['sort_by'], 'company');
      expect(call['sort_direction'], 'desc');
      expect(cs.single.fullName, 'probe_联系人');
      expect(cs.single.labelIds, ['3']);
      expect(cs.single.labels, ['Starred']);
    });

    test('list 不传筛选时不带多余参数', () async {
      final b = await _boot({'SYNO.Contacts.Contact.list': _contacts()});
      await b.contacts.contacts();
      final call = b.t.calls.last;
      for (final k in ['addressbook_id', 'label_id', 'keyword', 'group_id']) {
        expect(call.containsKey(k), isFalse, reason: '空筛选不该发 $k');
      }
      expect(call['sort_by'], 'full_name');
      expect(call['sort_direction'], 'asc');
    });

    test('get 用 v2 且 ids 是 JSON 数组串；详情里有 contact_detail', () async {
      final b = await _boot({'SYNO.Contacts.Contact.get': _contactDetail()});
      final c = await b.contacts.contact('12');

      final call = b.t.calls.last;
      expect(call['version'], '2');
      expect(call['ids'], '["12"]');
      expect(call['id'], isNull);

      expect(c?.detail?.givenName, 'Probe');
      expect(c?.detail?.familyName, 'Test');
      expect(c?.detail?.mail, ['probe@example.com']);
      expect(c?.detail?.tel, ['12345']);
      expect(c?.detail?.note, 'hello from probe');
    });

    test('get_photo 的参数是 contact_ids（ids/id 都回 120）', () async {
      final b = await _boot({
        'SYNO.Contacts.Contact.get_photo': {
          'photo': [
            {'id': 12, 'photo': 'data:image/png;base64,AAA'},
            {'id': 13, 'photo': ''},
          ],
        },
      });
      final photos = await b.contacts.photos(['12', '13']);

      final call = b.t.calls.last;
      expect(call['contact_ids'], '["12","13"]');
      expect(call['ids'], isNull);
      expect(photos, {'12': 'data:image/png;base64,AAA'});
    });

    test('create 发 addressbook_id + 扁平字段，嵌套值 JSON 串', () async {
      final b = await _boot({
        'SYNO.Contacts.Contact.create': {'id': 12},
      });
      final id = await b.contacts.createContact(
        addressbookId: '6',
        input: const ContactInput(
          fullName: 'probe_联系人',
          givenName: 'Probe',
          familyName: 'Test',
          mail: ['probe@example.com'],
          tel: ['12345'],
          company: 'Probe Inc',
          note: 'hello from probe',
        ),
      );

      final call = b.t.calls.last;
      expect(id, '12');
      expect(call['api'], 'SYNO.Contacts.Contact');
      expect(call['method'], 'create');
      expect(call['version'], '1');
      expect(call['addressbook_id'], '6');
      expect(call['full_name'], 'probe_联系人');
      expect(call['company'], 'Probe Inc');
      expect(call['note'], 'hello from probe');
      expect(jsonDecode(call['name'] as String), {
        'given_name': 'Probe',
        'family_name': 'Test',
        'prefix': '',
        'suffix': '',
        'additional_name': '',
      });
      expect(jsonDecode(call['mail'] as String), [
        {'data': 'probe@example.com'},
      ]);
      expect(jsonDecode(call['tel'] as String), [
        {'data': '12345'},
      ]);
      expect(
        jsonDecode(call['adr'] as String),
        <Object>[],
        reason: '没填地址就发空数组，不要发明字段',
      );
    });

    test('set 是 {id} + 字段；delete 是 ids JSON 串', () async {
      final b = await _boot({
        'SYNO.Contacts.Contact.set': <String, dynamic>{},
        'SYNO.Contacts.Contact.delete': <String, dynamic>{},
      });
      await b.contacts.setContact(
        id: '12',
        input: const ContactInput(fullName: '改过的', note: 'edited'),
      );
      expect(b.t.calls.last['id'], '12');
      expect(b.t.calls.last['full_name'], '改过的');
      expect(b.t.calls.last['note'], 'edited');

      await b.contacts.deleteContacts(['12', '13']);
      expect(b.t.calls.last['ids'], '["12","13"]');
    });

    test('toggle_person 是显示/隐藏（is_hidden 小写），不是星标', () async {
      final b = await _boot({
        'SYNO.Contacts.Contact.toggle_person': <String, dynamic>{},
      });
      await b.contacts.setContactsHidden(['12'], hidden: true);

      final call = b.t.calls.last;
      expect(call['api'], 'SYNO.Contacts.Contact');
      expect(call['method'], 'toggle_person');
      expect(call['ids'], '["12"]');
      expect(call['is_hidden'], 'true');

      await b.contacts.setContactsHidden(['12'], hidden: false);
      expect(b.t.calls.last['is_hidden'], 'false');
    });

    test('list_group 带 addressbook_id（本 NAS 上是空数组也照解析）', () async {
      final b = await _boot({
        'SYNO.Contacts.Contact.list_group': {'group': <Object>[], 'total': 0},
      });
      final gs = await b.contacts.groups(addressbookId: '5');
      expect(b.t.calls.last['addressbook_id'], '5');
      expect(gs, isEmpty);
    });
  });

  group('ContactsApi：标签（Label，全部 v2）', () {
    test('list 在 v2，能认出系统 Starred（type=1）', () async {
      final b = await _boot({
        'SYNO.Contacts.Label.list': {
          'label': [
            {'color': '', 'id': 3, 'name': 'Starred', 'type': 1},
            {
              'color': '#00AA00',
              'id': 6,
              'name': 'probe_tag2',
              'type': 0,
              'member': [12],
              'member_count': 1,
            },
          ],
          'total': 2,
        },
      });
      final labels = await b.contacts.labels();

      expect(b.t.calls.last['version'], '2');
      expect(labels.first.isStarred, isTrue);
      expect(labels[1].isStarred, isFalse);
      expect(labels[1].displayColor, '#00AA00');
      expect(labels[1].memberCount, 1);
    });

    test(
      'create 的 color 去掉 # 并大写；set 是 {id,name,color}；delete 用 ids',
      () async {
        final b = await _boot({
          'SYNO.Contacts.Label.create': {'id': 6},
          'SYNO.Contacts.Label.set': <String, dynamic>{},
          'SYNO.Contacts.Label.delete': <String, dynamic>{},
        });
        final id = await b.contacts.createLabel(
          name: 'probe_tag',
          color: '#ff0000',
        );
        expect(id, '6');
        expect(b.t.calls.last['version'], '2');
        expect(b.t.calls.last['name'], 'probe_tag');
        expect(b.t.calls.last['color'], 'FF0000');

        await b.contacts.setLabel(id: '6', name: 'probe_tag2', color: '00AA00');
        expect(b.t.calls.last['id'], '6');
        expect(b.t.calls.last['color'], '00AA00');

        await b.contacts.deleteLabel('6');
        expect(b.t.calls.last['ids'], '["6"]');
      },
    );

    test('星标 = 给 Starred 标签 add_member / remove_member', () async {
      final b = await _boot({
        'SYNO.Contacts.Label.add_member': <String, dynamic>{},
        'SYNO.Contacts.Label.remove_member': <String, dynamic>{},
      });
      await b.contacts.addLabelMembers(labelIds: ['3'], contactIds: ['12']);
      expect(b.t.calls.last['method'], 'add_member');
      expect(b.t.calls.last['version'], '2');
      expect(b.t.calls.last['ids'], '["3"]');
      expect(b.t.calls.last['contact_ids'], '["12"]');

      await b.contacts.removeLabelMembers(labelIds: ['3'], contactIds: ['12']);
      expect(b.t.calls.last['method'], 'remove_member');
    });
  });

  group('ContactsApi：导入导出', () {
    test('import_preview 是 multipart：目标走表单字段 addressbook_id', () async {
      final b = await _boot({
        'SYNO.Contacts.Addressbook.import_preview': {
          'contact': [
            {
              'full_name': 'demo_user',
              'primary_mail': 'user@example.com',
              'status': 1,
            },
          ],
        },
      });
      final preview = await b.contacts.importPreview(
        filePath: '/tmp/ab5.vcf',
        fileName: 'ab5.vcf',
        addressbookId: '6',
      );

      final call = b.t.calls.last;
      expect(call['api'], 'SYNO.Contacts.Addressbook');
      expect(call['method'], 'import_preview');
      expect(call['html5upload'], 'true');
      expect(call['addressbook_id'], '6', reason: '真机：放表单字段才吃');
      expect(call['id'], isNull, reason: 'preview 放 id 回 120');
      expect(call['file_field'], 'file');
      expect(call['file_name'], 'ab5.vcf');

      expect(preview.single.fullName, 'demo_user');
      expect(preview.single.primaryMail, 'user@example.com');
    });

    test('import 是 multipart：目标走查询串 id（表单放 addressbook_id 回 120）', () async {
      final b = await _boot({
        'SYNO.Contacts.Addressbook.import': {
          'contact_ids': [13, 14, 15, 16],
          'total': 4,
        },
      });
      final ids = await b.contacts.importVCard(
        filePath: '/tmp/ab5.vcf',
        fileName: 'ab5.vcf',
        addressbookId: '6',
      );

      final call = b.t.calls.last;
      expect(call['method'], 'import');
      expect(call['id'], '6', reason: '真机：import 的目标必须走查询串');
      expect(call['addressbook_id'], isNull);
      expect(call['file_field'], 'file');
      expect(ids, ['13', '14', '15', '16']);
    });

    test('export 走带 _sid 的直链（method=export），通讯录 v1 / 标签 v2', () async {
      final b = await _boot();
      await b.contacts.exportAddressbook('6');
      expect(b.t.downloads.last, contains('method=export'));
      expect(b.t.downloads.last, contains('id=6'));
      expect(b.t.downloads.last, contains('version=1'));
      expect(b.t.downloads.last, contains('_sid='), reason: '直链要带会话');

      await b.contacts.exportLabel('6');
      expect(b.t.downloads.last, contains('SYNO.Contacts.Label'));
      expect(b.t.downloads.last, contains('version=2'));
    });
  });

  group('ContactsApi：外部源 / CardDAV', () {
    test('create_carddav 的六个字段与官方一致', () async {
      final b = await _boot({
        'SYNO.Contacts.ExternalSource.create_carddav': <String, dynamic>{},
      });
      await b.contacts.createCardDav(
        location: 'https://dav.example.com/',
        username: 'u',
        password: 'p',
        importType: 1,
        addressbookId: '6',
      );

      final call = b.t.calls.last;
      expect(call['api'], 'SYNO.Contacts.ExternalSource');
      expect(call['method'], 'create_carddav');
      expect(call['is_sync'], 'true');
      expect(call['import_type'], '1');
      expect(call['addressbook_id'], '6');
      expect(call['addressbook_location'], 'https://dav.example.com/');
      expect(call['username'], 'u');
      expect(call['pwd'], 'p');
    });

    test(
      'set_carddav 没有 is_sync/import_type；refresh 只发 addressbook_id',
      () async {
        final b = await _boot({
          'SYNO.Contacts.ExternalSource.set_carddav': <String, dynamic>{},
          'SYNO.Contacts.ExternalSource.refresh': <String, dynamic>{},
        });
        await b.contacts.setCardDav(
          addressbookId: '6',
          location: 'https://dav.example.com/',
          username: 'u',
          password: 'p',
        );
        final set = b.t.calls.last;
        expect(set['method'], 'set_carddav');
        expect(set.containsKey('is_sync'), isFalse);
        expect(set.containsKey('import_type'), isFalse);

        await b.contacts.syncExternalSource('6');
        expect(b.t.calls.last['method'], 'refresh');
        expect(b.t.calls.last['addressbook_id'], '6');
      },
    );

    test('list 的键是复数 external_sources', () async {
      final b = await _boot({
        'SYNO.Contacts.ExternalSource.list': {
          'external_sources': [
            {
              'addressbook_id': 8,
              'source': 'carddav',
              'addressbook_location': 'https://dav.example.com/',
              'username': 'u',
            },
          ],
          'total': 1,
        },
      });
      final srcs = await b.contacts.externalSources();
      expect(srcs.single.addressbookId, '8');
      expect(srcs.single.isCardDav, isTrue);
      expect(srcs.single.location, 'https://dav.example.com/');
    });

    test('CardDAV 地址公式与官方网页版逐字一致（\\ → @@、去尾斜杠）', () {
      final api = ContactsApi(DsmWebApi(FakeTransport()));
      final urls = api.cardDavUrls(
        account: r'DOMAIN\demo_user',
        addressbookUri: 'aaaabbbb-1111',
        originOverride: 'https://ds923plus:5001/',
      );
      expect(urls.short, 'https://ds923plus:5001/carddav/DOMAIN@@demo_user');
      expect(
        urls.general,
        'https://ds923plus:5001/carddav/DOMAIN@@demo_user/aaaabbbb-1111',
      );

      // 没给 uri 时 general 退化成 short（官方也就是这个行为）
      final only = api.cardDavUrls(
        account: 'demo_user',
        originOverride: 'https://nas.local',
      );
      expect(only.short, 'https://nas.local/carddav/demo_user');
      expect(only.general, only.short);
    });
  });

  group('ContactsApi：Info 与容错解析', () {
    test('Info/get 只有 v1，principal 里取账号名', () async {
      final b = await _boot({
        'SYNO.Contacts.Info.get': {
          'principal': {
            'account_name': 'demo_user',
            'display_name': 'demo_user',
            'id': 4,
            'type': 1,
          },
        },
      });
      final info = await b.contacts.info();
      expect(b.t.calls.last['version'], '1');
      expect(info.account, 'demo_user');
    });

    test('群组/外部源取不到样本时也不炸（字段全缺省）', () async {
      final b = await _boot({
        'SYNO.Contacts.Contact.list_group': {
          'group': [
            {'id': 1, 'name': 'family'},
          ],
        },
        'SYNO.Contacts.ExternalSource.list': {
          'external_sources': [
            {'addressbook_id': 9},
          ],
        },
      });
      final gs = await b.contacts.groups(addressbookId: '5');
      expect(gs.single.name, 'family');
      expect(gs.single.memberCount, 0);

      final srcs = await b.contacts.externalSources();
      expect(srcs.single.addressbookId, '9');
      expect(srcs.single.location, '');
      expect(srcs.single.isCardDav, isFalse);
    });

    test('标签没给颜色时按 id 给稳定默认色（同 id 每次都一样）', () {
      const a = LabelDto(id: '6', name: 'x');
      const b = LabelDto(id: '6', name: 'y');
      const c = LabelDto(id: '7', name: 'x');
      expect(a.displayColor, b.displayColor);
      expect(a.displayColor, isNot(c.displayColor));
      expect(a.displayColor, startsWith('#'));
      expect(a.displayColor.length, 7);
    });

    test('adr 的结构化地址能拼成人看的一行', () {
      final d = ContactDetailDto.fromJson({
        'adr': [
          {
            'data': {
              'street': '中关村大街 1 号',
              'city': '北京',
              'state': '',
              'postal_code': '100080',
              'country': '中国',
            },
          },
        ],
      });
      expect(d.adr.single, '中关村大街 1 号, 北京, 100080, 中国');
    });

    test('ContactInput.toParams 不打多余的空字段（photo 为空就不发）', () {
      final p = const ContactInput(fullName: 'x').toParams();
      expect(p.containsKey('photo'), isFalse);
      expect(p.containsKey('nick_name'), isFalse);
      expect(jsonDecode(p['mail'] as String), isEmpty);
      expect(p['full_name'], 'x');
    });

    test('文件路径里的 .vcf 名字不参与解析（只用于上传）', () async {
      // 直接用一个真实临时文件，确保 multipart 分支真的读了字节
      final dir = await Directory.systemTemp.createTemp('contacts_import');
      final f = File('${dir.path}/ab.vcf')
        ..writeAsStringSync('BEGIN:VCARD\nEND:VCARD\n');
      final b = await _boot({
        'SYNO.Contacts.Addressbook.import_preview': {'contact': <Object>[]},
      });
      await b.contacts.importPreview(
        filePath: f.path,
        fileName: 'ab.vcf',
        addressbookId: '6',
      );
      expect(b.t.calls.last['file_bytes'], isNotEmpty);
      await dir.delete(recursive: true);
    });
  });
}
