// MailPlus（Webmail 客户端，阶段二 A 最后一批）真机探针。
//
//   # 1) 匿名能力探测（不需要账号）：这台 NAS 装没装 MailPlus
//   SYNO_NAS_URL=https://<nas>:<port> dart run tool/mail_probe.dart info
//
//   # 2) 只读功能往返（需要账号；**零写方法**，不改邮箱任何状态）
//   SYNO_NAS_URL=… SYNO_ACCOUNT=… SYNO_PASSWORD=… \
//     dart run tool/mail_probe.dart probe
//
// 事实来源：`docs/station-surveillance-mailplus-insight-research.md`
// 的实现回填小节（参数逐字对齐包内 `ui/mailclient.js` 的 `BaseWebAPIConfig.data`，
// 回包 root/字段逐字对齐 `Model.MailboxStore` / `Model.LabelStore` /
// `Model.BaseThreadReader` / `MessageLib.MsgStore`）。
//
// ⚠️ 本探针**只打只读方法**：`Info.getinfo` / `Mailbox.list` / `Label.list` /
// `Thread.list` / `Thread.get` / `Message.get`。**一个写方法都不碰** ——
// `set_read` / `set_star` / `set_mailbox`（都改邮箱状态）与
// `Draft.create` / `send` / `Attachment.upload*` 一律不调用。
// `SYNO.PersonMailAccount.*`（DSM 核心的外部账号）不在本模块范围内。
//
// 本探针是"核事实用"的：打印实际发出的参数与回包形状，以便把 research 的
// 开放项（回包 root 与字段、`conversation_view` 是否必需、分页 `has_more`、
// 普通用户能否调通）在真机上定案。
// ignore_for_file: avoid_print
import 'dart:io';

import 'package:synhub/src/core/net/dio_factory.dart';
import 'package:synhub/src/data/dto/mailplus_dto.dart';
import 'package:synhub/src/data/mailplus.dart';
import 'package:synhub/src/dsm/webapi.dart';

Future<DsmWebApi> _connect() async {
  final api = DsmWebApi(
    DirectTransport.url(
      Platform.environment['SYNO_NAS_URL']!,
      dio: DioFactory.create(allowSelfSigned: true),
    ),
  );
  await api.discover();
  return api;
}

Future<DsmWebApi> login() async {
  final api = await _connect();
  await api.login(
    account: Platform.environment['SYNO_ACCOUNT']!,
    password: Platform.environment['SYNO_PASSWORD']!,
    session: 'MailClient',
  );
  return api;
}

/// 匿名探测：只读 `SYNO.API.Info`（不需要登录）。
Future<void> info() async {
  final api = await _connect();
  final table = await api.discover();
  print('API 总数：${table.length}');
  final mc = table.keys.where((k) => k.startsWith('SYNO.MailClient')).toList()
    ..sort();
  final mps =
      table.keys.where((k) => k.startsWith('SYNO.MailPlusServer')).toList()
        ..sort();
  final pma =
      table.keys.where((k) => k.startsWith('SYNO.PersonMailAccount')).toList()
        ..sort();
  print('SYNO.MailClient.*：${mc.length}');
  for (final k in mc) {
    final e = table[k]!;
    print('  $k  v${e.minVersion}..${e.maxVersion}  path=${e.path}');
  }
  print('SYNO.MailPlusServer.*：${mps.length}（**管理员面，本模块不做**）');
  print('SYNO.PersonMailAccount.*：${pma.length}（DSM 核心的外部账号，另列一批）');
  if (mc.isEmpty) {
    print('结论：这台 NAS **没有安装** MailPlus（客户端命名空间不存在）');
    print('      （前置：先装 MailPlus Server 并配好域与激活用户）');
    return;
  }
  // 本模块真正依赖的 API 是否注册、注册到哪个 path。
  for (final name in [
    MailPlusApi.apiInfo,
    MailPlusApi.apiMailbox,
    MailPlusApi.apiLabel,
    MailPlusApi.apiThread,
    MailPlusApi.apiMessage,
    MailPlusApi.apiDraft,
    MailPlusApi.apiAttachment,
  ]) {
    final e = table[name];
    print(
      '  $name → '
      '${e == null ? '未注册' : 'v${e.minVersion}..${e.maxVersion} @ ${e.path}'}',
    );
  }
}

/// 只读功能往返：不需要任何写权限。
Future<void> probe() async {
  final api = await login();
  final mail = MailPlusApi(api);
  print('installed=${mail.installed}');

  print('--- Info.getinfo v2（无参数）');
  await _tryPrint('getinfo', () async {
    final d = await mail.getInfo();
    print('  回包键：${d.keys.toList()..sort()}');
    for (final k in ['uid', 'user_uid', 'download_token', 'database_ready']) {
      if (d.containsKey(k)) print('  $k=${d[k]}');
    }
    return d;
  });

  print('--- Mailbox.list v7（root=mailbox）');
  List<MailMailboxDto> boxes;
  try {
    boxes = await mail.listMailboxes();
    print('  邮箱数=${boxes.length}');
  } catch (e) {
    print('  ✘ Mailbox.list → $e');
    print('  归因：${mailFailureKind(e)} / ${describeMailError(e)}');
    return;
  }
  for (final b in boxes.take(20)) {
    print(
      '  #${b.id} path=${b.path} display=${b.displayName} own=${b.isOwn} '
      'subscribed=${b.subscribed} unread=${b.unreadCount} draft=${b.draftCount}',
    );
  }
  if (boxes.isEmpty) {
    print('提示：装了 MailPlus 但当前账号**没有邮箱** → 后续列表无法继续验。');
    return;
  }

  print('--- Label.list v3（root=label）');
  await _tryPrint('Label.list', () async {
    final labels = await mail.listLabels();
    print('  标签数=${labels.length}');
    for (final l in labels.take(10)) {
      print('  #${l.id} ${l.label} path=${l.path} unread=${l.unreadCount}');
    }
    return labels;
  });

  // 选默认邮箱：INBOX 优先，否则第一条。
  final inbox = boxes.firstWhere(
    (b) => b.path.toUpperCase() == 'INBOX',
    orElse: () => boxes.first,
  );
  print('--- Thread.list v11（mailbox=${inbox.path}，root=thread）');
  await _tryPrint('Thread.list', () async {
    final page = await mail.listThreads(mailboxPath: inbox.path, limit: 10);
    print(
      '  total=${page.total} has_more=${page.hasMore} 本页=${page.items.length}',
    );
    for (final th in page.items) {
      final m = th.primary;
      print(
        '  #${th.id} unread=${th.unreadCount} star=${th.star} '
        'labels=${th.labelIds} msgs=${th.messages.length} '
        'subject=${m?.subject} from=${m?.from} '
        'attach=${m?.attachments.length} modified=${th.lastModified}',
      );
    }
    if (page.items.isEmpty) {
      print('  （这个邮箱是空的：可能真没邮件，也可能 mailbox condition 值要对 id 而不是 path）');
      return page;
    }
    final first = page.items.first;
    print('--- Thread.get v11（id=${first.id}，root=thread 数组）');
    await _tryPrint('Thread.get', () async {
      final th = await mail.getThread(first.id);
      print('  会话内邮件数=${th?.messages.length}');
      return th;
    });
    final msg = first.primary;
    if (msg != null) {
      print('--- Message.get v10（id=${msg.id}，root=message 数组）');
      await _tryPrint('Message.get', () async {
        final m = await mail.getMessage(msg.id);
        print('  subject=${m?.subject}');
        print('  from=${m?.from} to=${m?.to}');
        print(
          '  body_html=${(m?.bodyHtml ?? '').length}B '
          'body_plain=${(m?.bodyPlain ?? '').length}B '
          'preview=${(m?.bodyPreview ?? '').length}B',
        );
        print('  附件数=${m?.attachments.length}');
        return m;
      });
    }
    return page;
  });
  print('--- 探针结束（全程零写方法，未改动 NAS 上任何状态）');
}

Future<T?> _tryPrint<T>(String what, Future<T> Function() run) async {
  try {
    final v = await run();
    print('  ✔ $what');
    return v;
  } catch (e) {
    print('  ✘ $what → $e');
    print('  归因：${mailFailureKind(e)} / ${describeMailError(e)}');
    return null;
  }
}

Future<void> main(List<String> args) async {
  final cmd = args.isEmpty ? 'info' : args.first;
  switch (cmd) {
    case 'info':
      await info();
    case 'probe':
      await probe();
    default:
      stderr.writeln('用法: dart run tool/mail_probe.dart [info|probe]');
      exitCode = 2;
  }
}
