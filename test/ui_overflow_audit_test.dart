// 全界面**运行时溢出审计**（布局审计任务 3）。
//
// 目的：把"肉眼读代码猜哪里会溢出"换成**机器判定**。
//   * 溢出在 debug 测试里就是 `RenderFlex overflowed` → `FlutterError`，
//     由 `tester.takeException()` 取到；这里对**每一页 × 每一组
//     （尺寸 × 文字缩放 × 语言）**都断言"一次异常都没有"。
//   * 语言跑 zh / en 两遍：英文串普遍更长，是最容易暴露截断的组合。
//   * 文字缩放跑 1.0 / 1.3 / 2.0：真机上用户会把系统字体调大。
//   * 假服务端回包**故意用超长 / 不可断行的 token**（长文件名、长 URL、
//     长用户名、长频道名），把窄屏布局逼到极限。
//
// 覆盖不了的页面用 `skip:` **显式列出**（原因写清楚），不做静默省略。
//
// ⚠️ 断言有效性有专门的 falsification 用例（见文件末尾）：故意塞一个固定
// 4000dp 宽的 `Row`，必须**红**。没有这一条，"全绿"可能只是断言写错了。
import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_quill/flutter_quill.dart'
    show FlutterQuillLocalizations;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:synhub/src/core/i18n/l10n.dart';
import 'package:synhub/src/core/services/service_availability.dart';
import 'package:synhub/src/core/services/service_registry.dart';
import 'package:synhub/src/core/theme/app_theme.dart';
import 'package:synhub/src/data/audio_station.dart';
import 'package:synhub/src/data/calendar_api.dart';
import 'package:synhub/src/data/contacts_api.dart';
import 'package:synhub/src/data/download_station.dart';
import 'package:synhub/src/data/drive_api.dart';
import 'package:synhub/src/data/filestation_api.dart';
import 'package:synhub/src/data/foto_api.dart';
import 'package:synhub/src/data/mailplus.dart';
import 'package:synhub/src/data/note_api.dart';
import 'package:synhub/src/data/office_api.dart';
import 'package:synhub/src/data/surveillance_station.dart';
import 'package:synhub/src/dsm/webapi.dart';
import 'package:synhub/src/features/audio/audio_providers.dart';
import 'package:synhub/src/features/calendar/calendar_providers.dart';
import 'package:synhub/src/features/contacts/contacts_providers.dart';
import 'package:synhub/src/features/downloads/download_providers.dart';
import 'package:synhub/src/features/files/drive_providers.dart';
import 'package:synhub/src/features/files/file_providers.dart';
import 'package:synhub/src/features/files/office_providers.dart';
import 'package:synhub/src/features/mailplus/mail_providers.dart';
import 'package:synhub/src/features/notes/note_providers.dart';
import 'package:synhub/src/features/photos/photo_providers.dart';
import 'package:synhub/src/features/surveillance/surv_providers.dart';
import 'package:synhub/src/features/ai/ai_model_page.dart';
import 'package:synhub/src/features/ai/ai_usage_page.dart';
import 'package:synhub/src/features/analytics/analytics_page.dart';
import 'package:synhub/src/features/audio/audio_page.dart';
import 'package:synhub/src/features/audio/audio_pins_page.dart';
import 'package:synhub/src/features/audio/audio_search_page.dart';
import 'package:synhub/src/features/audio/audio_song_page.dart';
import 'package:synhub/src/features/calendar/calendar_page.dart';
import 'package:synhub/src/features/chat/archive_page.dart';
import 'package:synhub/src/features/chat/channel_create_page.dart';
import 'package:synhub/src/features/chat/channel_hashtags_page.dart';
import 'package:synhub/src/features/chat/channel_list_page.dart';
import 'package:synhub/src/features/chat/channel_media_page.dart'
    as media_page;
import 'package:synhub/src/features/chat/channel_members_page.dart';
import 'package:synhub/src/features/chat/channel_scheduled_page.dart';
import 'package:synhub/src/features/chat/chat_page.dart';
import 'package:synhub/src/features/chat/read_status_page.dart';
import 'package:synhub/src/features/chat/thread_page.dart';
import 'package:synhub/src/features/contacts/contacts_manage_page.dart';
import 'package:synhub/src/features/contacts/contacts_page.dart';
import 'package:synhub/src/features/design/design_preview_page.dart';
import 'package:synhub/src/features/diagnostics/diag_page.dart';
import 'package:synhub/src/features/downloads/download_create_page.dart';
import 'package:synhub/src/features/downloads/download_page.dart';
import 'package:synhub/src/features/files/drive_labels_page.dart';
import 'package:synhub/src/features/files/drive_more_page.dart';
import 'package:synhub/src/features/files/drive_tasks_page.dart';
import 'package:synhub/src/features/files/file_browse_page.dart';
import 'package:synhub/src/features/files/file_pages.dart';
import 'package:synhub/src/features/files/office_page.dart';
import 'package:synhub/src/features/home/home_page.dart';
import 'package:synhub/src/features/login/login_page.dart';
import 'package:synhub/src/features/mailplus/mail_compose_page.dart';
import 'package:synhub/src/features/mailplus/mail_page.dart';
import 'package:synhub/src/features/notes/note_tag_page.dart';
import 'package:synhub/src/features/notes/note_todo_page.dart';
import 'package:synhub/src/features/notes/notes_page.dart';
import 'package:synhub/src/features/photos/photo_backup_page.dart';
import 'package:synhub/src/features/photos/photo_browse_page.dart';
import 'package:synhub/src/features/search/search_page.dart';
import 'package:synhub/src/features/search/global_search_page.dart';
import 'package:synhub/src/features/security/passcode_screen.dart';
import 'package:synhub/src/features/servers/certificates_page.dart';
import 'package:synhub/src/features/servers/server_setup_page.dart';
import 'package:synhub/src/features/settings/bots_page.dart';
import 'package:synhub/src/features/settings/e2ee_page.dart';
import 'package:synhub/src/features/settings/notification_settings_page.dart';
import 'package:synhub/src/features/settings/profile_edit_page.dart';
import 'package:synhub/src/features/settings/service_check_page.dart';
import 'package:synhub/src/features/settings/settings_page.dart';
import 'package:synhub/src/features/settings/snooze_settings_page.dart';
import 'package:synhub/src/features/shell/app_shell_page.dart';
import 'package:synhub/src/features/surveillance/surv_page.dart';

import 'support/chat_harness.dart';

// ---------------------------------------------------------------- 审计参数

/// 审计窗口尺寸（逻辑像素，dpr=1）。
///
///   360×640  = 小屏下限（主流最低端安卓机）
///   375×814  = **r307 那台非折叠屏真机（LGE-AN10）的精确逻辑尺寸**
///              （`init=1312×2848 @560dpi` / `cur=1148×2492`，
///               1148÷(490/160)=375、2492÷(490/160)≈813.7 ⇒ 375×814）
///   393×852  ≈ 同代手机的常见逻辑尺寸（iPhone 15 一档）
///   411×891  = 真机批次 R5/R6 实际使用的那台手机
///   800×1280 = 平板 / 折叠屏展开
const List<({String tag, Size size})> kAuditSizes = [
  (tag: '360x640', size: Size(360, 640)),
  (tag: '375x814', size: Size(375, 814)),
  (tag: '393x852', size: Size(393, 852)),
  (tag: '411x891', size: Size(411, 891)),
  (tag: '800x1280', size: Size(800, 1280)),
];

/// 文字缩放档位（系统"字体大小"）
const List<double> kAuditScales = [1.0, 1.3, 2.0];

/// 审计语言（英文串普遍比中文长）
const List<String> kAuditLangs = ['zh', 'en'];

// ---------------------------------------------------------------- 断言工具

/// 取走当前所有待处理异常（`takeException` 一次只给一个）。
///
/// `takeException()` 在多异常时只回一个"Multiple exceptions were detected"
/// 的汇总对象，看不到具体是谁溢出 —— 所以审计用 [_captureErrors] 抓
/// `FlutterErrorDetails`，这里只负责把汇总异常**消费掉**，免得泄漏到下一个用例。
List<Object> _drainExceptions(WidgetTester tester) {
  final out = <Object>[];
  while (out.length < 60) {
    final e = tester.takeException();
    if (e == null) break;
    out.add(e);
  }
  return out;
}

/// 抓本轮用例里所有 `FlutterErrorDetails`（含"哪个 widget、哪一行"），
/// 同时**照常**转给框架默认处理（断言失败/红的语义不变）。
List<FlutterErrorDetails> _captureErrors() {
  final out = <FlutterErrorDetails>[];
  final prev = FlutterError.onError;
  FlutterError.onError = (details) {
    out.add(details);
    prev?.call(details);
  };
  addTearDown(() {
    FlutterError.onError = prev;
  });
  return out;
}

/// 从 [FlutterErrorDetails] 里抠出一行"哪一页哪一 widget"的可读定位。
String _where(FlutterErrorDetails d) {
  final text = d.toString();
  final cause = RegExp(
    r'The relevant error-causing widget was:\s*([^\n]*)\s*\n\s*([^\n]*)',
  ).firstMatch(text);
  final creator = RegExp(r'creator: ([^\n]*)').firstMatch(text);
  final parts = <String>[
    d.exception.toString().split('\n').first,
    if (cause != null) '${cause.group(1)} ${cause.group(2)}'.trim(),
    if (cause == null && creator != null) creator.group(1)!.trim(),
  ];
  return parts.join(' | ');
}

/// 断言"这一轮 pump 没有溢出/布局异常"。
///
/// 断言对 [captured] 里**任何**一条都失败 —— 溢出只是其中最常见的一类，
/// "unbounded height"、"RenderBox was not laid out" 之类同样是布局缺陷。
void _expectNoOverflow(
  WidgetTester tester,
  String what,
  List<FlutterErrorDetails> captured,
) {
  _drainExceptions(tester); // 消费掉汇总异常，避免泄漏
  if (captured.isEmpty) return;
  final overflow = captured
      .where((d) => d.toString().contains('overflowed'))
      .length;
  fail(
    '$what 出现 ${captured.length} 个布局异常'
    '${overflow == 0 ? '' : '（其中 $overflow 个是 overflow）'}:\n'
    '${captured.map((d) => '  - ${_where(d)}').join('\n')}',
  );
}

// ---------------------------------------------------------------- 审计环境

const List<Locale> kSupportedLocales = [Locale('zh'), Locale('en')];

const List<LocalizationsDelegate<Object>> kDelegates = [
  AppText.delegate,
  FlutterQuillLocalizations.delegate,
  GlobalMaterialLocalizations.delegate,
  GlobalWidgetsLocalizations.delegate,
  GlobalCupertinoLocalizations.delegate,
];

/// 一个审计用例：页面 + 造"长内容"用的假服务端回包 + 额外 provider 覆盖。
class _PageCase {
  const _PageCase({required this.name, required this.build, this.table});

  final String name;
  final Widget Function() build;

  /// 覆盖 `SYNO.API.Info` 能力表（默认 [_fullTable]）。
  ///
  /// S3 之后新增的界面按**能力位**显隐（Finder 入口、NAS AI Console），
  /// 只有换掉能力表才能同时覆盖"有 / 无该能力"两种布局。
  final Map<String, Map<String, dynamic>> Function()? table;
}

/// 超长 / 不可断行的 token（把窄屏布局逼到极限）。
const _longCn = '一个名字特别特别长的条目用来验证窄屏截断行为是否正常并且还要更长一些才可以（日本語も混ぜる）';
const _longLatin =
    'quarterly-financial-report-2026-Q4-consolidated-with-appendix-and-notes-final-v3-APPROVED.pdf';
const _longUrl =
    'https://download.synology.com/download/DSM/release/7.2.2/72806/'
    'DSM_DS1823xs%2B_72806.pat?token=eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9';
const _longUser =
    'very.long.user.name.for.layout.audit@example-corporation.internal';

/// 假服务端回包：所有主要列表都给"超长内容"，逼出真实的截断/溢出。
Map<String, Map<String, dynamic>> _content() => {
  // ---- 聊天
  'SYNO.Chat.Channel.list': {
    'channels': [
      {
        'channel_id': 5,
        'name': _longCn,
        'type': 'public',
        'is_joined': true,
        'unread': 3,
        'last_post_at': 1000,
      },
      {
        'channel_id': 6,
        'name': _longLatin,
        'type': 'private',
        'is_joined': true,
        'unread': 128,
        'last_post_at': 900,
      },
    ],
  },
  'SYNO.Chat.Channel.get': {
    'channel': {
      'channel_id': 5,
      'name': _longCn,
      'type': 'public',
      'is_joined': true,
    },
  },
  'SYNO.Chat.User.list': {
    'users': [
      {
        'user_id': 14,
        'username': _longUser,
        'type': 'human',
        'status': 'online',
      },
      {'user_id': 15, 'username': '张三丰', 'type': 'human', 'status': 'offline'},
    ],
  },
  'SYNO.Chat.User.get': {
    'user': {'user_id': 14, 'username': _longUser, 'type': 'human'},
  },
  'SYNO.Chat.Channel.view': {'last_view_at': 1234},
  'SYNO.Chat.Post.list': {
    'posts': [
      {
        'post_id': 4294967300,
        'channel_id': 5,
        'creator_id': 14,
        'create_at': 2000,
        'type': 'normal',
        'message': '$_longUrl 这个链接非常长，用来验证不可断行 token 在气泡里的行为',
        'props': {'encrypted': false},
      },
    ],
  },
  'SYNO.Chat.Channel.Member.list': {
    'members': [
      {'user_id': 14, 'username': _longUser, 'type': 'human'},
      {'user_id': 15, 'username': '张三丰', 'type': 'human'},
    ],
  },
  // ---- 文件
  'SYNO.FileStation.List.list_share': {
    'shares': [
      {'name': _longLatin, 'path': '/$_longLatin', 'isdir': true},
      {'name': '共享文件夹里一个极其漫长的中文名字', 'path': '/x', 'isdir': true},
    ],
    'total': 2,
    'offset': 0,
  },
  'SYNO.FileStation.List.list': {
    'files': [
      {
        'name': _longLatin,
        'path': '/home/$_longLatin',
        'isdir': false,
        'additional': {
          'size': 123456789,
          'time': {'mtime': 1758100000},
          'owner': {'user': _longUser},
          'perm': {
            'acl': {'read': true, 'write': true, 'exec': false},
          },
        },
      },
      {
        'name': _longCn,
        'path': '/home/$_longCn',
        'isdir': true,
        'additional': {
          'size': 0,
          'time': {'mtime': 1758100000},
          'owner': {'user': 'administrators'},
          'perm': {
            'acl': {'read': true, 'write': false, 'exec': true},
          },
        },
      },
    ],
    'total': 2,
    'offset': 0,
  },
  'SYNO.FileStation.Favorite.list': {
    'files': [
      {
        'name': _longLatin,
        'path': '/home/$_longLatin',
        'isdir': false,
        'additional': {
          'size': 4096,
          'time': {'mtime': 1758100000},
        },
      },
    ],
    'total': 1,
  },
  'SYNO.FileStation.Sharing.list': {
    'links': [
      {
        'id': 'abc',
        'path': '/home/$_longLatin',
        'url': 'https://nas.example.com:5001/sharing/abcdefghijklmnop',
        'link_owner': _longUser,
      },
    ],
    'total': 1,
  },
  'SYNO.FileStation.BackgroundTask.list': {
    'tasks': [
      {
        'taskid': 't1',
        'api': 'SYNO.FileStation.Compress',
        'path': '/home/$_longLatin',
        'title': _longCn,
        'progress': 42,
        'finished': false,
      },
    ],
    'total': 1,
  },
  'SYNO.FileStation.Info.get': {
    'is_manager': true,
    'hostname': 'SynologyNAS',
    'support_virtual_protocol': 'smb',
  },
  // ---- Drive
  'SYNO.SynologyDrive.Files.list': {
    'items': [
      {
        'file_id': '9',
        'name': _longLatin,
        'type': 'file',
        'path': '/$_longLatin',
        'display_path': '/mydrive/$_longLatin',
        'parent_id': '1',
        'size': 2048,
        'modified_time': 1789775507,
        'created_time': 1789775501,
        'content_type': 'document',
        'owner': _longUser,
        'capabilities': {'can_write': true},
        'version_id': '65',
      },
    ],
    'total': 1,
  },
  'SYNO.SynologyDrive.Labels.list': {
    'labels': [
      {'id': 'l1', 'name': _longCn, 'color': '#FF0000'},
      {'id': 'l2', 'name': _longLatin, 'color': '#00FF00'},
    ],
  },
  // ---- 相册
  'SYNO.Foto.Browse.Item.list': {
    'list': [
      {
        'id': '1',
        'filename': _longLatin,
        'filesize': 1024 * 512,
        'time': DateTime(2026, 9, 18, 10).millisecondsSinceEpoch ~/ 1000,
        'indexed_time':
            DateTime(2026, 9, 18, 11).millisecondsSinceEpoch ~/ 1000,
        'folder_id': '10',
        'type': 'photo',
        'additional': {
          'thumbnail': {
            'sm': 'sm_1',
            'm': 'm_1',
            'xl': 'xl_1',
            'cache_key': 'ck_1',
          },
          'album': ['a1'],
        },
      },
    ],
    'total': 1,
  },
  'SYNO.Foto.Browse.Album.list': {
    'list': [
      {'id': 'a1', 'name': _longCn, 'item_count': 12},
      {'id': 'a2', 'name': _longLatin, 'item_count': 3},
    ],
    'total': 2,
  },
  'SYNO.Foto.Browse.Folder.list': {
    'list': [
      {'id': '10', 'name': _longCn, 'item_count': 5},
    ],
    'total': 1,
  },
  'SYNO.Foto.Setting.User.get': {'space': 'personal'},
  // ---- Audio Station
  'SYNO.AudioStation.Song.list': {
    'songs': [
      {
        'id': 'music_1',
        'path': '/volume1/music/示例歌曲.mp3',
        'type': 'file',
        'title': _longCn,
        'artist': '一个很长很长的歌手名字 Band With A Very Long Name',
        'album': _longLatin,
        'additional': {
          'song_tag': {
            'title': _longCn,
            'artist': 'Long Artist Name',
            'album': _longLatin,
          },
          'song_audio': {
            'duration': 227,
            'bitrate': 320000,
            'frequency': 44100,
            'channel': 2,
            'filesize': 9090909,
          },
          'song_rating': {'rating': 0},
        },
      },
    ],
    'total': 1,
  },
  'SYNO.AudioStation.Playlist.list': {
    'playlists': [
      {'id': 'p1', 'name': _longCn, 'song_count': 3},
    ],
    'total': 1,
  },
  'SYNO.AudioStation.Pin.list': {'pins': []},
  // ---- Download Station
  'SYNO.DownloadStation.Task.list': {
    'tasks': [
      {
        'id': 'dbid_1',
        'title': _longLatin,
        'type': 'bt',
        'status': 'downloading',
        'size': 4096,
        'username': _longUser,
        'additional': {
          'detail': {'destination': '/volume1/downloads/一个非常深的目录层级/再深一层'},
          'transfer': {
            'size_downloaded': 1024,
            'speed_download': 2048,
            'speed_upload': 0,
          },
        },
      },
    ],
    'total': 1,
  },
  'SYNO.DownloadStation.Info.getinfo': {'is_bt_enabled': true},
  // ---- 日历
  'SYNO.Cal.Cal.list': {
    'list': [
      {
        'cal_id': '/demo_user/home/',
        'cal_displayname': _longCn,
        'cal_color': '#B240AF',
        'cal_privilege': 'RW',
        'cal_type': 'event',
        'default_calendar': true,
        'original_cal_id': '/demo_user/home/',
      },
    ],
  },
  'SYNO.Cal.Setting.get': {
    'time_zone': 'Asia/Shanghai',
    'week_start_day': 0,
    'date_format': 'Y-m-d',
    'time_format': '24',
  },
  'SYNO.Cal.Event.list': {
    'list': [
      {
        'evt_id': '1',
        'cal_id': '/demo_user/home/',
        'original_cal_id': '/demo_user/home/',
        'summary': _longCn,
        'description': _longUrl,
        'dtstart_string': '${DateTime.now().year}0919T100000',
        'dtend_string': '${DateTime.now().year}0919T110000',
        'is_all_day': false,
        'tz_id': 'Asia/Shanghai',
        'color': '#B240AF',
        'is_repeat_evt': false,
        'dav_etag': 'etag-1',
      },
    ],
  },
  'SYNO.Cal.Todo.list': {
    'list': [
      {
        'evt_id': 9,
        'summary': _longCn,
        'percent_complete': 0,
        'due_string': '${DateTime.now().year}0919T180000',
      },
    ],
  },
  // ---- 联系人
  'SYNO.Contacts.Addressbook.list': {
    'addressbook': <Map<String, dynamic>>[
      {'id': 5, 'name': _longCn, 'is_editable': true},
    ],
  },
  'SYNO.Contacts.Contact.list': {
    'contact': <Map<String, dynamic>>[
      {
        'id': 1,
        'addressbook_id': 5,
        'full_name': _longCn,
        'company': '一个名字同样很长的公司名称有限责任公司',
        'department': '研发',
        'title': '工程师',
        'primary_mail': _longUser,
        'primary_tel': '13800000000',
        'is_editable': false,
        'photo': '',
        'additional': {
          'label': [
            {'name': '客户'},
          ],
        },
      },
    ],
  },
  'SYNO.Contacts.Info.list': {'version': 1},
  // ---- MailPlus
  'SYNO.MailClient.Mailbox.list': {
    'total': 1,
    'mailbox': [
      {
        'id': '1',
        'path': 'INBOX',
        'is_own': true,
        'subscribed': true,
        'additional': {'unread_count': 2},
      },
    ],
  },
  'SYNO.MailClient.Thread.list': {
    'total': 2,
    'has_more': false,
    'thread': [
      {
        'id': 't1',
        'star': true,
        'unread': 1,
        'last_modified': 1700000000,
        'message': [
          {
            'id': 'm1',
            'subject': _longCn,
            'from': _longUser,
            'to': _longUser,
            'date': 1700000000,
            'unread': 1,
            'attach_count': 1,
          },
        ],
      },
      {
        'id': 't2',
        'star': false,
        'unread': 0,
        'last_modified': 1700000001,
        'message': [
          {
            'id': 'm2',
            'subject': _longLatin,
            'from': _longUser,
            'to': _longUser,
            'date': 1700000001,
            'unread': 0,
          },
        ],
      },
    ],
  },
  // ---- Surveillance
  'SYNO.SurveillanceStation.Camera.List': {
    'total': 2,
    'cameras': [
      {
        'id': 1,
        'name': _longCn,
        'camStatus': 1,
        'enablePtzControl': true,
        'resolution': '1920x1080',
        'fps': 25,
        'host': '10.0.0.9',
      },
      {
        'id': 2,
        'name': _longLatin,
        'camStatus': 3,
        'enablePtzControl': false,
        'resolution': '2560x1440',
        'fps': 30,
        'host': '10.0.0.10',
      },
    ],
  },
  // ---- 笔记
  'SYNO.NoteStation.Note.list': {
    'notes': [
      {
        'object_id': 'n1',
        'title': _longCn,
        'parent_id': 'nb1',
        'tag': ['a', 'b'],
        'mtime': 1700000000000,
        'ctime': 1700000000000,
      },
    ],
    'total': 1,
  },
  'SYNO.NoteStation.Notebook.list': {
    'notebooks': [
      {'id': 'nb1', 'name': _longCn},
    ],
    'total': 1,
  },
  'SYNO.NoteStation.Tag.list': {
    'tags': [
      {'name': _longCn, 'note_count': 3},
    ],
  },
  'SYNO.NoteStation.Todo.list': {
    'todos': [
      {
        'object_id': 'td1',
        'title': _longCn,
        'status': 'todo',
        'priority': 'high',
      },
    ],
  },
};

// ---------------------------------------------------------------- 审计主循环

void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;

  final longContent = _content();

  final pages = <_PageCase>[
    _PageCase(name: 'ServerSetupPage', build: () => const ServerSetupPage()),
    _PageCase(name: 'LoginPage', build: () => const LoginPage()),
    _PageCase(name: 'HomePage(受限首页)', build: () => const HomePage()),
    _PageCase(name: 'AppShellPage', build: () => const AppShellPage()),
    _PageCase(name: 'ChannelListPage', build: () => const ChannelListPage()),
    _PageCase(name: 'ChatPage', build: () => const ChatPage(channelId: 5)),
    _PageCase(
      name: 'ThreadPage',
      build: () => const ThreadPage(channelId: 5, parentPostId: 4294967300),
    ),
    _PageCase(
      name: 'ChannelMembersPage',
      build: () => const ChannelMembersPage(channelId: 5),
    ),
    _PageCase(
      name: 'ChannelMediaPage',
      build: () => const media_page.ChannelMediaPage(channelId: 5),
    ),
    _PageCase(
      name: 'ChannelHashtagsPage',
      build: () => const ChannelHashtagsPage(channelId: 5),
    ),
    _PageCase(
      name: 'ScheduledMessagesPage',
      build: () => const ScheduledMessagesPage(channelId: 5),
    ),
    _PageCase(
      name: 'RemindersPage',
      build: () => const RemindersPage(channelId: 5),
    ),
    _PageCase(
      name: 'ReadStatusPage',
      build: () => const ReadStatusPage(postId: 4294967300, readUsers: true),
    ),
    _PageCase(
      name: 'ChannelCreatePage',
      build: () => const ChannelCreatePage(),
    ),
    _PageCase(name: 'ArchivePage', build: () => const ArchivePage()),
    _PageCase(name: 'SearchPage', build: () => const SearchPage()),
    _PageCase(name: 'ServiceCheckPage', build: () => const ServiceCheckPage()),
    _PageCase(name: 'SettingsPage', build: () => const SettingsPage()),
    _PageCase(name: 'ProfileEditPage', build: () => const ProfileEditPage()),
    _PageCase(
      name: 'NotificationSettingsPage',
      build: () => const NotificationSettingsPage(),
    ),
    _PageCase(
      name: 'SnoozeSettingsPage',
      build: () => const SnoozeSettingsPage(),
    ),
    _PageCase(
      name: 'ScheduleSnoozePage',
      build: () => const ScheduleSnoozePage(),
    ),
    _PageCase(name: 'E2eePage', build: () => const E2eePage()),
    _PageCase(name: 'CertificatesPage', build: () => const CertificatesPage()),
    _PageCase(name: 'BotsPage', build: () => const BotsPage()),
    _PageCase(name: 'DiagPage', build: () => const DiagPage(autoRun: false)),
    _PageCase(name: 'NotesPage', build: () => const NotesPage()),
    _PageCase(name: 'NoteTodoPage', build: () => const NoteTodoPage()),
    _PageCase(name: 'NoteTagPage', build: () => const NoteTagPage()),
    _PageCase(name: 'FileBrowsePage', build: () => const FileBrowsePage()),
    _PageCase(name: 'FileSearchPage', build: () => const FileSearchPage()),
    _PageCase(
      name: 'FileFavoritesPage',
      build: () => const FileFavoritesPage(),
    ),
    _PageCase(
      name: 'FileShareLinksPage',
      build: () => const FileShareLinksPage(),
    ),
    _PageCase(name: 'FileTasksPage', build: () => const FileTasksPage()),
    _PageCase(name: 'DriveLabelsPage', build: () => const DriveLabelsPage()),
    _PageCase(name: 'DriveTasksPage', build: () => const DriveTasksPage()),
    _PageCase(name: 'DriveMorePage', build: () => const DriveMorePage()),
    _PageCase(name: 'PhotoBrowsePage', build: () => const PhotoBrowsePage()),
    _PageCase(name: 'PhotoBackupPage', build: () => const PhotoBackupPage()),
    _PageCase(name: 'AudioPage', build: () => const AudioPage()),
    _PageCase(name: 'AudioSearchPage', build: () => const AudioSearchPage()),
    _PageCase(name: 'AudioPinsPage', build: () => const AudioPinsPage()),
    _PageCase(
      name: 'AudioSongDetailPage',
      build: () =>
          const AudioSongDetailPage(songId: 'music_1', title: '一首很长很长的歌名'),
    ),
    _PageCase(name: 'DownloadPage', build: () => const DownloadPage()),
    _PageCase(
      name: 'DownloadCreatePage',
      build: () => const DownloadCreatePage(),
    ),
    _PageCase(name: 'CalendarPage', build: () => const CalendarPage()),
    _PageCase(name: 'ContactsPage', build: () => const ContactsPage()),
    _PageCase(
      name: 'ContactsManagePage',
      build: () => const ContactsManagePage(),
    ),
    _PageCase(name: 'MailPage', build: () => const MailPage()),
    _PageCase(name: 'MailComposePage', build: () => const MailComposePage()),
    _PageCase(name: 'SurveillancePage', build: () => const SurveillancePage()),
    _PageCase(name: 'AiModelPage', build: () => const AiModelPage()),
    _PageCase(name: 'AiUsagePage', build: () => const AiUsagePage()),
    _PageCase(
      name: 'UsageAnalyticsPage',
      build: () => const UsageAnalyticsPage(),
    ),
    _PageCase(
      name: 'DesignPreviewPage',
      build: () => const DesignPreviewPage(),
    ),
    _PageCase(
      name: 'PasscodeLockScreen',
      build: () => const PasscodeLockScreen(),
    ),
    // ---- S3 之后新增的界面（审计矩阵原本未覆盖，见 docs/ui-audit.md 追加节）
    // Finder 全局搜索：入口（吸顶）与页面本体都要在"能力位在位"的能力表下跑
    _PageCase(
      name: 'GlobalSearchEntry',
      build: () => const GlobalSearchEntry(),
      table: _finderTable,
    ),
    _PageCase(
      name: 'GlobalSearchPage',
      build: () => const GlobalSearchPage(),
      table: _finderTable,
    ),
    // 工作台 Office 入口页（内容复用 DriveBrowseView）
    _PageCase(
      name: 'OfficePage',
      build: () => const OfficePage(title: 'Office'),
    ),
    // NAS AI Console 卡片：有 / 无 `SYNO.AI.Completion` 两种能力位布局
    _PageCase(
      name: 'AiModelPage(no AI.Completion)',
      build: () => const AiModelPage(),
      table: _noCompletionTable,
    ),
    // 工作台（2026-09-22 收口后是 11 个入口 —— office / drive 磁贴已撤，
    // Office 入口移进 Drive 的「更多」页；见 `drive_more_page.dart`）。
    // `AppShellPage` 默认 tab 不是工作台，磁贴只有单跑 `WorkspaceTab` 才建得出来。
    _PageCase(
      name: 'WorkspaceTab(11 tiles)',
      build: () => const WorkspaceTab(),
    ),
  ];

  group('运行时溢出审计（尺寸 × 文字缩放 × 语言）', () {
    for (final page in pages) {
      for (final lang in kAuditLangs) {
        for (final s in kAuditSizes) {
          for (final scale in kAuditScales) {
            final what = '${page.name} · ${s.tag} · x$scale · $lang';
            testWidgets(what, (tester) async {
              final captured = _captureErrors();
              final env = await _boot(longContent, table: page.table?.call());
              _applyView(tester, s.size);
              setCurrentText(lookupAppText(Locale(lang)));
              await tester.pumpWidget(
                _app(
                  container: env,
                  home: page.build(),
                  locale: Locale(lang),
                  scale: scale,
                ),
              );
              await tester.pump();
              await tester.pump(const Duration(milliseconds: 80));
              await tester.pump(const Duration(milliseconds: 400));
              _expectNoOverflow(tester, what, captured);
            });
          }
        }
      }
    }
  });

  group('覆盖缺口（显式 skip，不静默省略）', () {
    test(
      'MediaPlayerPage（需真实原生播放器 surface / 视频解码）',
      () {},
      skip:
          'MediaPlayerPage 在 initState 里向原生播放器要 surface，离线无平台通道；'
          '真实控制条布局由 test/media_player_controls_ui_test.dart 覆盖',
    );

    test(
      '私有构造的弹层（_ChannelManageSheet / _CardDavSheet / _VoteEditorDialog / '
      '_EventEditorSheet / _ProfileSheet / UploadProgressDialog 等）',
      () {},
      skip:
          '这些是 library-private 类（`_XxxSheet` / `_XxxDialog`），测试无法 import；'
          '只能在打开它们的宿主页面里覆盖（宿主页已在本文件矩阵内）',
    );

    test(
      'SurvCameraPage / MailDetailPage / NoteViewPage / FilePreviewPage 等需要具体 DTO 的详情页',
      () {},
      skip:
          '构造需要真实 DTO（相机会话 / 邮件 thread id / 笔记对象 / 文件条目）；'
          '本批次按"宿主列表页 + 列表部分"覆盖，详情页正文未纳入矩阵',
    );

    test(
      'Office / Drive 表格与日历月视图的极端列宽（需真实文档与自建表格数据）',
      () {},
      skip:
          'Office 预览要真实 docx/xlsx 字节；月视图跨时区重复事件由 '
          'test/calendar_page_test.dart 覆盖，本矩阵只覆盖当月单一事件',
    );
  });

  // ------------------------------------------- S3 新界面专项断言
  //
  // 矩阵本身已把这些界面纳入 4 尺寸 × 3 缩放 × 2 语言；这里补的是"显隐"和
  // "第二屏"这类**矩阵循环看不到**的事实：能力位缺失时界面必须整体隐藏，
  // 能力位在位时必须出现；工作台 13 个磁贴的第二屏也要真的建出来并跑一次。
  group('S3 新界面专项断言（能力位显隐 / 第二屏磁贴）', () {
    Future<ProviderContainer> pump(
      WidgetTester tester,
      Widget home, {
      Map<String, Map<String, dynamic>>? table,
      double scale = 2.0,
      Size size = const Size(360, 640),
    }) async {
      final env = await _boot(longContent, table: table);
      _applyView(tester, size);
      setCurrentText(lookupAppText(const Locale('en')));
      await tester.pumpWidget(
        _app(
          container: env,
          home: home,
          locale: const Locale('en'),
          scale: scale,
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 80));
      await tester.pump(const Duration(milliseconds: 400));
      return env;
    }

    testWidgets('Finder 能力位在位 → 全局搜索入口可见，缺失 → 整体隐藏', (tester) async {
      final captured = _captureErrors();
      await pump(tester, const GlobalSearchEntry(), table: _finderTable());
      expect(find.byKey(const Key('global-search-entry')), findsOneWidget);
      _expectNoOverflow(tester, 'GlobalSearchEntry（能力位在位）', captured);

      await pump(tester, const GlobalSearchEntry());
      expect(
        find.byKey(const Key('global-search-entry')),
        findsNothing,
        reason: '缺 SYNO.Finder.FileIndexing.Search 时入口必须整体隐藏',
      );
      _expectNoOverflow(tester, 'GlobalSearchEntry（能力位缺失）', captured);
    });

    testWidgets('全局搜索页面本体：窄屏 + 2.0 缩放下无溢出', (tester) async {
      final captured = _captureErrors();
      await pump(tester, const GlobalSearchPage(), table: _finderTable());
      expect(find.byKey(const Key('global-search-page')), findsOneWidget);
      expect(find.byKey(const Key('global-search-field')), findsOneWidget);
      _expectNoOverflow(tester, 'GlobalSearchPage', captured);
    });

    testWidgets('Office 入口页：窄屏 + 2.0 缩放下无溢出', (tester) async {
      final captured = _captureErrors();
      await pump(tester, const OfficePage(title: 'Office'));
      expect(find.byKey(const Key('office-page')), findsOneWidget);
      _expectNoOverflow(tester, 'OfficePage', captured);
    });

    testWidgets('NAS AI Console 卡片：能力位在位出现、缺失整体隐藏', (tester) async {
      final captured = _captureErrors();
      // 用"放得下"的常规组合：卡片在页面靠下，矮屏 + 大字号下会被 ListView 懒构建
      // 跳过（那是滚动位置问题，不是显隐问题）。
      await pump(
        tester,
        const AiModelPage(),
        size: const Size(800, 1280),
        scale: 1.0,
      );
      expect(
        find.byKey(const Key('ai-server-channel')),
        findsOneWidget,
        reason: 'SYNO.AI.Completion 在位时 NAS AI Console 卡片应出现',
      );
      _expectNoOverflow(tester, 'AiModelPage（有 AI.Completion）', captured);

      await pump(
        tester,
        const AiModelPage(),
        table: _noCompletionTable(),
        size: const Size(800, 1280),
        scale: 1.0,
      );
      expect(
        find.byKey(const Key('ai-server-channel')),
        findsNothing,
        reason: '缺 SYNO.AI.Completion 时卡片必须整体隐藏',
      );
      _expectNoOverflow(tester, 'AiModelPage（无 AI.Completion）', captured);
    });

    testWidgets('工作台 S3 收口：office/drive 磁贴已撤；第二屏建得出来且不溢出', (tester) async {
      final captured = _captureErrors();
      await pump(
        tester,
        const WorkspaceTab(),
        size: const Size(360, 640),
        scale: 1.0,
      );
      expect(find.byKey(const Key('ws-pager')), findsOneWidget);
      // 2026-09-22 收口：office / drive 不再是工作台磁贴（入口进 Drive 更多页）
      expect(
        find.byKey(const Key('ws-tile-office')),
        findsNothing,
        reason: 'office 磁贴必须已从工作台撤掉',
      );
      expect(find.byKey(const Key('ws-tile-drive')), findsNothing);
      // 11 个入口在这个小尺寸下仍然分屏：翻到第二屏，确认剩下的磁贴能建出来
      expect(find.byKey(const Key('ws-dot-1')), findsOneWidget);
      await tester.drag(
        find.byKey(const Key('ws-pager')),
        const Offset(-400, 0),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 80));
      expect(
        find.byKey(const Key('ws-tile-mailplus')),
        findsOneWidget,
        reason: '第 11 个入口（mailplus）在第二屏，翻页后应能建出来',
      );
      expect(
        find.byKey(const Key('ws-tile-files')),
        findsNothing,
        reason: '第二屏不该再出现第一屏的磁贴（确认真的翻页了）',
      );
      _expectNoOverflow(tester, 'WorkspaceTab（第一屏 + 第二屏）', captured);
    });
  });

  // ------------------------------------------------------ falsification
  //
  // 证明这套断言**真的能抓到溢出**：给同一套审计脚手架塞一个固定 4000dp
  // 宽的 Row 子项 —— 必须拿到非空异常。没有这一条，"全绿"可能只是断言写错。
  group('falsification', () {
    testWidgets('断言有效性：固定 4000dp 宽的 Row 必须被判红', (tester) async {
      _applyView(tester, const Size(360, 640));
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: Row(
              children: [
                SizedBox(width: 4000, height: 10),
                SizedBox(width: 4000, height: 10),
              ],
            ),
          ),
        ),
      );
      await tester.pump();
      final errors = _drainExceptions(tester);
      expect(
        errors.where((e) => e.toString().contains('overflowed')),
        isNotEmpty,
        reason: '故意造 4000dp 宽 Row 却没被 takeException 抓到 —— 断言无效',
      );
    });

    testWidgets('断言有效性：_expectNoOverflow 对溢出页面必须抛 fail', (tester) async {
      final captured = _captureErrors();
      _applyView(tester, const Size(360, 640));
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: Column(
              children: [
                Row(children: [SizedBox(width: 4000, height: 10)]),
              ],
            ),
          ),
        ),
      );
      await tester.pump();
      expect(
        () => _expectNoOverflow(tester, 'falsification', captured),
        throwsA(isA<TestFailure>()),
      );
    });
  });
}

// ---------------------------------------------------------------- 基础设施

/// 启一个"全模块可用"的假服务端 + ProviderContainer。
///
/// `apiBox` 在 `bootChat` 返回后才赋值，这是可以的：这些 provider 是**惰性**
/// 的，页面第一次 `ref.watch` 时（pumpWidget 期间）`apiBox` 已经填好了。
Future<ProviderContainer> _boot(
  Map<String, Map<String, dynamic>> responses, {
  Map<String, Map<String, dynamic>>? table,
}) async {
  DsmWebApi? apiBox;
  final h = await bootChat(
    extra: responses,
    apiTable: table ?? _fullTable(),
    moreOverrides: [
      availabilityApiProvider.overrideWith((ref) => apiBox),
      ..._moduleOverrides(() => apiBox),
    ],
  );
  apiBox = h.api;
  h.container.read(serviceAvailabilityProvider.notifier).refresh();
  return h.container;
}

T? _wrap<T>(DsmWebApi? api, T Function(DsmWebApi) ctor) =>
    api == null ? null : ctor(api);

/// 各模块 API provider 全部指向同一条假传输（页面读不到就显示空态 —— 那本身
/// 也是一种合法布局；能注入的尽量注入，逼近真实内容形态）。
List<Object> _moduleOverrides(DsmWebApi? Function() api) => [
  fileApiProvider.overrideWith((ref) => _wrap(api(), FileStationApi.new)),
  driveApiProvider.overrideWith((ref) => _wrap(api(), DriveApi.new)),
  fotoApiProvider.overrideWith((ref) => _wrap(api(), FotoApi.new)),
  audioApiProvider.overrideWith((ref) => _wrap(api(), AudioStationApi.new)),
  downloadApiProvider.overrideWith(
    (ref) => _wrap(api(), DownloadStationApi.new),
  ),
  noteApiProvider.overrideWith((ref) => _wrap(api(), NoteStationApi.new)),
  calendarApiProvider.overrideWith((ref) => _wrap(api(), CalendarApi.new)),
  contactsApiProvider.overrideWith((ref) => _wrap(api(), ContactsApi.new)),
  mailApiProvider.overrideWith((ref) => _wrap(api(), MailPlusApi.new)),
  surveillanceApiProvider.overrideWith(
    (ref) => _wrap(api(), SurveillanceStationApi.new),
  ),
  officeApiProvider.overrideWith((ref) => _wrap(api(), OfficeApi.new)),
];

/// 全部服务都齐全的能力表（`SYNO.API.Info` 的实测形态）。
Map<String, Map<String, dynamic>> _fullTable() {
  final table = <String, Map<String, dynamic>>{...FakeTransport.table};
  for (final spec in kServiceRegistry.values) {
    for (final api in spec.allApis) {
      table[api] = {'path': 'entry.cgi', 'minVersion': 1, 'maxVersion': 9};
    }
  }
  return table;
}

/// 明显缺 `SYNO.AI.Completion` 的能力表：NAS AI Console 卡片必须整体隐藏。
Map<String, Map<String, dynamic>> _noCompletionTable() =>
    _fullTable()..remove(kAiCompletionApi);

/// 带 `SYNO.Finder.*` 的能力表：全局搜索入口 / 页面必须**可见**。
///
/// `SYNO.Finder.*` 不属于任何 StationService（是 DSM 横切能力），所以
/// [_fullTable] 不会带上它，必须显式补。
Map<String, Map<String, dynamic>> _finderTable() => _fullTable()
  ..addAll({
    kFinderFileIndexingSearchApi: {
      'path': 'entry.cgi',
      'minVersion': 1,
      'maxVersion': 1,
    },
    kFinderFileApi: {'path': 'entry.cgi', 'minVersion': 1, 'maxVersion': 1},
  });

void _applyView(WidgetTester tester, Size size) {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
}

Widget _app({
  required ProviderContainer container,
  required Widget home,
  required Locale locale,
  required double scale,
}) => UncontrolledProviderScope(
  container: container,
  child: MaterialApp(
    theme: AppTheme.dark(),
    locale: locale,
    localizationsDelegates: kDelegates,
    supportedLocales: kSupportedLocales,
    builder: (context, child) => MediaQuery(
      data: MediaQuery.of(
        context,
      ).copyWith(textScaler: TextScaler.linear(scale)),
      child: child ?? const SizedBox.shrink(),
    ),
    home: home,
  ),
);
