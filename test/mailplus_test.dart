// MailPlus（Webmail 客户端）接口层离线验证（阶段二 A 最后一批）。
//
// 事实来源：`docs/station-surveillance-mailplus-insight-research.md` 的实现回填
// 小节 + 离线取证 `RESPONSE_FIELDS.md`（MailClient 4.1.0-22327）：
//   * api/method/版本取自包内 `ui/mailclient.js` 的 registry；
//   * 回包 root/字段取自 `Model.MailboxStore` / `Model.LabelStore` /
//     `Model.BaseThreadReader` / `MessageLib.MsgStore` 的 JsonReader 定义。
// 这里只验"请求拼对了、回包解对了、错误翻对了"，不打真机、不碰写方法。
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';

import 'package:synhub/src/data/dto/mailplus_dto.dart';
import 'package:synhub/src/data/mailplus.dart';
import 'package:synhub/src/dsm/webapi.dart';

import 'support/chat_harness.dart' show FakeTransport;

const _mcTable = {
  'SYNO.API.Info': {'path': 'query.cgi', 'minVersion': 1, 'maxVersion': 1},
  'SYNO.MailClient.Info': {
    'path': 'entry.cgi',
    'minVersion': 1,
    'maxVersion': 2,
  },
  'SYNO.MailClient.Mailbox': {
    'path': 'entry.cgi',
    'minVersion': 1,
    'maxVersion': 7,
  },
  'SYNO.MailClient.Label': {
    'path': 'entry.cgi',
    'minVersion': 1,
    'maxVersion': 3,
  },
  'SYNO.MailClient.Thread': {
    'path': 'entry.cgi',
    'minVersion': 1,
    'maxVersion': 11,
  },
  'SYNO.MailClient.Message': {
    'path': 'entry.cgi',
    'minVersion': 1,
    'maxVersion': 10,
  },
  'SYNO.MailClient.Draft': {
    'path': 'entry.cgi',
    'minVersion': 1,
    'maxVersion': 7,
  },
  'SYNO.MailClient.Attachment': {
    'path': 'entry.cgi',
    'minVersion': 1,
    'maxVersion': 8,
  },
};

Future<(MailPlusApi, FakeTransport)> boot({
  Map<String, Map<String, dynamic>> responses = const {},
  bool noMail = false,
}) async {
  final t = FakeTransport(responses, {
    ...FakeTransport.table,
    if (!noMail) ..._mcTable,
  });
  final api = DsmWebApi(t);
  await api.discover();
  await api.login(account: 'a', password: 'b');
  return (MailPlusApi(api), t);
}

Map<String, dynamic> callOf(FakeTransport t, String method) =>
    t.calls.lastWhere((c) => c['method'] == method);

/// 官方 `message` 记录（含 `body` 对象与附件）。
Map<String, dynamic> _msg({
  String id = 'm1',
  String subject = '周报',
  Object body = const {'html': '<p>hi</p>', 'plain': 'hi'},
  List<Object>? attachment,
}) => {
  'id': id,
  'subject': subject,
  'from': [
    {'name': '张三', 'email': 'z@example.com'},
  ],
  'to': [
    {'name': '李四', 'email': 'l@example.com'},
  ],
  'body': body,
  'body_preview': '预览…',
  'arrival_time': 1700000000,
  'mailbox_id': 'INBOX',
  'thread_id': 't1',
  'rfc_message_id': '<x@y>',
  'read': false,
  'star': false,
  'attachment': ?attachment,
};

void main() {
  group('能力探测 / 未安装判据', () {
    test('能力表有 MailClient.Info → installed=true', () async {
      final (mail, _) = await boot();
      expect(mail.installed, isTrue);
    });

    test('没有 MailClient 命名空间 → installed=false（未安装）', () async {
      final (mail, _) = await boot(noMail: true);
      expect(mail.installed, isFalse);
    });
  });

  group('Mailbox / list v7', () {
    test('逐字参数 + root mailbox + additional 计数', () async {
      final (mail, t) = await boot(
        responses: {
          'SYNO.MailClient.Mailbox.list': {
            'total': 2,
            'mailbox': [
              {
                'id': '1',
                'path': 'INBOX',
                'is_own': true,
                'owner': 'a',
                'my_permission': 1,
                'subscribed': true,
                'owner_valid': true,
                'has_expired': false,
                'additional': {'unread_count': 3, 'draft_total_count': 1},
              },
              {'id': '2', 'path': 'INBOX.Drafts', 'is_own': false},
            ],
          },
        },
      );
      final boxes = await mail.listMailboxes();
      final call = callOf(t, 'list');
      expect(call['api'], 'SYNO.MailClient.Mailbox');
      expect(call['version'], '7');
      expect(call['subscription'], false);
      expect(jsonDecode(call['additional'] as String), [
        'unread_count',
        'draft_total_count',
      ]);
      expect(boxes, hasLength(2));
      expect(boxes.first.path, 'INBOX');
      expect(boxes.first.isOwn, isTrue);
      expect(boxes.first.unreadCount, 3);
      expect(boxes.first.draftCount, 1);
      // displayName 由 path 末段派生（官方前端也是客户端算的）
      expect(boxes[1].displayName, 'Drafts');
      expect(boxes[1].isOwn, isFalse);
    });

    test('root 缺失或不是 List → 空列表，不崩', () async {
      final (mail, _) = await boot(
        responses: {
          'SYNO.MailClient.Mailbox.list': {'mailbox': 'oops'},
        },
      );
      expect(await mail.listMailboxes(), isEmpty);
    });
  });

  group('Label / list v3', () {
    test('逐字参数 + root label + path 派生 display_name', () async {
      final (mail, t) = await boot(
        responses: {
          'SYNO.MailClient.Label.list': {
            'total': 1,
            'label': [
              {
                'id': 'l1',
                'name': '重要',
                'path': 'Work/Urgent',
                'background_color': '#f00',
                'text_color': '#fff',
                'additional': {'unread_count': 2},
              },
            ],
          },
        },
      );
      final labels = await mail.listLabels();
      final call = callOf(t, 'list');
      expect(call['api'], 'SYNO.MailClient.Label');
      expect(call['version'], '3');
      expect(jsonDecode(call['additional'] as String), ['unread_count']);
      expect(labels.single.label, 'Urgent');
      expect(labels.single.unreadCount, 2);
      expect(labels.single.textColor, '#fff');
    });
  });

  group('Thread / list v11', () {
    test(
      'condition JSON + offset/limit/additional + root thread/total/has_more',
      () async {
        final (mail, t) = await boot(
          responses: {
            'SYNO.MailClient.Thread.list': {
              'total': 42,
              'has_more': true,
              'thread': [
                {
                  'id': 't1',
                  'star': true,
                  'unread': 2,
                  'label': [
                    {'id': 'l1', 'name': '重要'},
                  ],
                  'last_modified': 1700000000,
                  'message': [_msg()],
                },
              ],
            },
          },
        );
        final page = await mail.listThreads(
          mailboxPath: 'INBOX',
          keyword: '周报',
          unreadOnly: true,
          offset: 30,
          limit: 30,
          withRecipient: true,
        );
        final call = callOf(t, 'list');
        expect(call['api'], 'SYNO.MailClient.Thread');
        expect(call['version'], '11');
        expect(call['offset'], 30);
        expect(call['limit'], 30);
        final cond = (jsonDecode(call['condition'] as String) as List)
            .cast<Map<String, dynamic>>();
        expect(
          cond.map((m) => m['name']),
          containsAll(<String>['mailbox', 'keyword', 'unread']),
        );
        expect(
          cond.firstWhere((m) => m['name'] == 'mailbox')['value'],
          'INBOX',
        );
        expect(cond.firstWhere((m) => m['name'] == 'keyword')['value'], '周报');
        expect(jsonDecode(call['additional'] as String), ['with_recipient']);

        expect(page.total, 42);
        expect(page.hasMore, isTrue);
        expect(page.offset, 30);
        final th = page.items.single;
        expect(th.id, 't1');
        expect(th.unreadCount, 2);
        expect(th.unread, isTrue);
        expect(th.labelIds, ['l1']); // label 是对象数组 → 取 id
        expect(th.subject, '周报');
        expect(th.from, '张三 <z@example.com>');
      },
    );

    test('没有条件时不发空 condition 项', () async {
      final (mail, t) = await boot(
        responses: {
          'SYNO.MailClient.Thread.list': {'total': 0, 'thread': []},
        },
      );
      await mail.listThreads(mailboxPath: null);
      expect(jsonDecode(callOf(t, 'list')['condition'] as String), isEmpty);
    });

    test('has_more=false + total 缺失 → 以本条数兜底', () async {
      final (mail, _) = await boot(
        responses: {
          'SYNO.MailClient.Thread.list': {
            'thread': [
              {'id': 't1', 'message': []},
            ],
          },
        },
      );
      final page = await mail.listThreads();
      expect(page.total, 1);
      expect(page.hasMore, isFalse);
    });
  });

  group('Thread / get v11 与 Message / get v10 的 root', () {
    test('Thread.get 回包 root 是 thread 数组 → 取第一条', () async {
      final (mail, t) = await boot(
        responses: {
          'SYNO.MailClient.Thread.get': {
            'thread': [
              {
                'id': 't1',
                'message': [_msg()],
              },
            ],
          },
        },
      );
      final th = await mail.getThread('t1');
      expect(callOf(t, 'get')['version'], '11');
      expect(th!.id, 't1');
      expect(th.messages.single.subject, '周报');
    });

    test('Thread.get 空数组 → null', () async {
      final (mail, _) = await boot(
        responses: {
          'SYNO.MailClient.Thread.get': {'thread': []},
        },
      );
      expect(await mail.getThread('t1'), isNull);
    });

    test('Message.get 回包 root 是 message 数组；body 是对象', () async {
      final (mail, t) = await boot(
        responses: {
          'SYNO.MailClient.Message.get': {
            'message': [
              _msg(
                attachment: [
                  {
                    'name': 'a.pdf',
                    'size': 2048,
                    'md5': 'abc',
                    'content_id': 'cid1',
                    'url': 'https://nas/dl/1',
                    'inline': false,
                  },
                ],
              ),
            ],
          },
        },
      );
      final m = await mail.getMessage('m1');
      final call = callOf(t, 'get');
      expect(call['api'], 'SYNO.MailClient.Message');
      expect(call['version'], '10');
      expect(call['id'], 'm1');
      expect(
        jsonDecode(call['additional'] as String),
        MailPlusApi.messageAdditionalDefault,
      );

      expect(m!.subject, '周报');
      expect(m.bodyHtml, '<p>hi</p>');
      expect(m.bodyPlain, 'hi');
      expect(m.displayBody, '<p>hi</p>');
      expect(m.to.single, '李四 <l@example.com>');
      final a = m.attachments.single;
      expect(a.name, 'a.pdf');
      expect(a.md5, 'abc');
      expect(a.contentId, 'cid1');
      expect(a.url, 'https://nas/dl/1');
      expect(a.key, 'abc');
    });

    test('Message.get：body 缺/null、from 是裸字符串 → 都能收', () async {
      final (mail, _) = await boot(
        responses: {
          'SYNO.MailClient.Message.get': {
            'message': [
              {'id': 'm9', 'from': 'bare@example.com', 'body': null},
            ],
          },
        },
      );
      final m = await mail.getMessage('m9');
      expect(m!.from, 'bare@example.com');
      expect(m.body, '');
      expect(m.displayBody, ''); // body_preview 也缺
      expect(m.arrivalTime, 0);
      expect(m.attachments, isEmpty);
    });

    test('Message.get：body 只有 plain 时 displayBody 用 plain', () async {
      final (mail, _) = await boot(
        responses: {
          'SYNO.MailClient.Message.get': {
            'message': [
              {
                'id': 'm2',
                'body': {'plain': '纯文本', 'truncated': 't'},
              },
            ],
          },
        },
      );
      final m = await mail.getMessage('m2');
      expect(m!.bodyPlain, '纯文本');
      expect(m.displayBody, '纯文本');
    });
  });

  group('写方法参数形态（只验拼装，不打真机）', () {
    test('set_read / set_star（0/1）/ set_mailbox', () async {
      final (mail, t) = await boot();
      await mail.setRead('m1', read: true);
      expect(callOf(t, 'set_read')['read'], true);
      expect(callOf(t, 'set_read')['version'], '10');

      await mail.setStar('m1', star: true);
      expect(callOf(t, 'set_star')['star'], 1);
      await mail.setStar('m1', star: false);
      expect(callOf(t, 'set_star')['star'], 0);

      await mail.setMailbox('m1', 'mb9');
      expect(callOf(t, 'set_mailbox')['mailbox_id'], 'mb9');
    });

    test('createDraft / sendDraft 参数逐字；id 从回包取', () async {
      final (mail, t) = await boot(
        responses: {
          'SYNO.MailClient.Draft.create': {'id': 'd-1'},
        },
      );
      final id = await mail.createDraft(
        to: ['a@b.c'],
        cc: ['c@d.e'],
        subject: '标题',
        body: '正文',
      );
      final call = callOf(t, 'create');
      expect(call['api'], 'SYNO.MailClient.Draft');
      expect(call['version'], '7');
      expect(jsonDecode(call['to'] as String), ['a@b.c']);
      expect(jsonDecode(call['cc'] as String), ['c@d.e']);
      expect(jsonDecode(call['bcc'] as String), isEmpty);
      expect(jsonDecode(call['attachment'] as String), isEmpty);
      expect(jsonDecode(call['temp_attachment'] as String), isEmpty);
      expect(call['subject'], '标题');
      expect(call['enable_read_request'], false);
      expect(call['enable_delivery_request'], false);
      expect(call.containsKey('refer_to'), isFalse);
      expect(id, 'd-1');

      await mail.sendDraft(id);
      final send = callOf(t, 'send');
      expect(send['version'], '7');
      expect(send['id'], 'd-1');
    });

    test('createDraft 回包没有 id → 空串（调用方据此报错）', () async {
      final (mail, _) = await boot();
      expect(await mail.createDraft(to: const ['a@b.c']), '');
    });
  });

  group('附件下载 URL', () {
    test('有 md5 用 md5；无 md5 用 msg_path/part_id；带票据参数', () async {
      final (mail, _) = await boot();
      expect(
        mail.attachmentDownloadPath(),
        endsWith('entry.cgi/SYNO.MailClient.Attachment'),
      );

      final byMd5 = mail.attachmentDownloadUrl(
        const MailAttachmentDto(id: 'a', md5: 'M1'),
        downloadToken: 'tok',
      );
      expect(byMd5, contains('/webapi/entry.cgi'));
      expect(byMd5, contains('api=SYNO.MailClient.Attachment'));
      expect(byMd5, contains('method=download'));
      expect(byMd5, contains('version=8'));
      expect(byMd5, contains('md5=M1'));
      expect(byMd5, contains('download_token=tok'));
      expect(byMd5, contains('type=original'));

      final byPart = mail.attachmentDownloadUrl(
        const MailAttachmentDto(id: 'a', msgPath: '/INBOX/1', partId: '2'),
        type: 'thumb',
      );
      expect(byPart, contains('msg_path=%2FINBOX%2F1'));
      expect(byPart, contains('part_id=2'));
      expect(byPart, contains('type=thumb'));
    });
  });

  group('错误分类与文案（三态判据）', () {
    test('102/103/104/121 → notInstalled', () {
      for (final c in [102, 103, 104, 121]) {
        expect(
          mailFailureKind(DsmApiException(c)),
          MailFailureKind.notInstalled,
        );
      }
    });

    test('105/160/402/408 → noPrivilege', () {
      for (final c in [105, 160, 402, 408]) {
        expect(
          mailFailureKind(DsmApiException(c)),
          MailFailureKind.noPrivilege,
        );
      }
    });

    test('会话过期 / 网络 / 其它', () {
      expect(
        mailFailureKind(DsmApiException(106)),
        MailFailureKind.sessionExpired,
      );
      expect(
        mailFailureKind(DsmApiException(119)),
        MailFailureKind.sessionExpired,
      );
      expect(
        mailFailureKind(DsmTransportException('x')),
        MailFailureKind.network,
      );
      expect(mailFailureKind(DsmApiException(1202)), MailFailureKind.network);
      expect(mailFailureKind(DsmApiException(2100)), MailFailureKind.network);
      expect(mailFailureKind(DsmApiException(999)), MailFailureKind.other);
    });

    test('describeMailError 给可读中文', () {
      expect(describeMailError(DsmApiException(102)), '这台 NAS 没有安装 MailPlus');
      expect(describeMailError(DsmApiException(160)), '这个账号没有使用 MailPlus 的权限');
      expect(describeMailError(DsmTransportException('x')), contains('网络'));
      expect(describeMailError(DsmApiException(401)), '邮箱不存在');
      expect(describeMailError(DsmApiException(500)), contains('发信'));
      expect(describeMailError(DsmApiException(999)), contains('999'));
    });
  });

  group('DTO 缺字段 / null / 变形', () {
    test('邮箱全空 → 安全默认值', () {
      final b = MailMailboxDto.fromJson(const {});
      expect(b.id, '');
      expect(b.path, '');
      expect(b.isOwn, isFalse);
      expect(b.subscribed, isTrue);
      expect(b.unreadCount, 0);
      expect(b.displayName, '');
    });

    test('会话没有 message → primary/subject 全空，不崩', () {
      final th = MailThreadDto.fromJson(const {'id': 't'});
      expect(th.messages, isEmpty);
      expect(th.primary, isNull);
      expect(th.subject, '');
      expect(th.unread, isFalse);
      expect(th.hasAttachment, isFalse);
    });

    test('label 是裸 id 列表也能收', () {
      final th = MailThreadDto.fromJson(const {
        'id': 't',
        'label': ['l1', 'l2'],
      });
      expect(th.labelIds, ['l1', 'l2']);
    });

    test('附件按 createItemConfig 的优先级算 key', () {
      expect(
        MailAttachmentDto.fromJson(const {
          'msg_path': '/p',
          'part_id': '3',
          'md5': 'm',
        }).key,
        '/p3',
      );
      expect(
        MailAttachmentDto.fromJson(const {'msg_id': 'i', 'part_id': '3'}).key,
        'i3',
      );
      expect(MailAttachmentDto.fromJson(const {'id': 'x'}).key, 'x');
    });

    test('附件 size 用 filesize 兜底；name 用 filename 兜底', () {
      final a = MailAttachmentDto.fromJson(const {
        'filename': 'f.txt',
        'filesize': '123',
      });
      expect(a.name, 'f.txt');
      expect(a.size, 123);
    });
  });
}
