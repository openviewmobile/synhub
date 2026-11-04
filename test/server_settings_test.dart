// 服务端设置（`SYNO.Chat.Admin.Setting`）+ 消息可编辑性（`PostUtil`）测试。
//
// 真机实测值（NAS 2.3.1 / API 表 v1-5）：
//   file_size_limit=0(不限) allow_encryption=true allow_edit_message=true
//   allow_edit_message_time_within_min=-1(不限) allow_read_status=false
//   notify_type=mention_subscribe readonly_profile=[]
import 'package:flutter_test/flutter_test.dart';

import 'package:synhub/src/core/settings/server_settings.dart';
import 'package:synhub/src/data/dto/channel_dto.dart';
import 'package:synhub/src/data/dto/post_dto.dart';
import 'package:synhub/src/data/dto/server_settings_dto.dart';
import 'package:synhub/src/features/chat/post_editable.dart';

/// 真机 `Setting/get` 的响应（原样抄下）
const _liveJson = <String, dynamic>{
  'account_type': 'local',
  'allow_auto_import': true,
  'allow_custom_jitsi': false,
  'allow_drive_upload': true,
  'allow_ds_upload': true,
  'allow_edit_message': true,
  'allow_edit_message_time_within_min': -1,
  'allow_encryption': true,
  'allow_guest': false,
  'allow_pc_upload': true,
  'allow_read_status': false,
  'batch_delete_schedule_hour': -1,
  'enable_batch_delete': false,
  'file_size_limit': 0,
  'force_ad_fullname': false,
  'hide_post_url_preview': true,
  'jitsi_base_urls': ['', '', '', '', ''],
  'notification_render_nickname': true,
  'notify_type': 'mention_subscribe',
  'readonly_profile': <String>[],
};

PostDto _post({
  int postId = 100,
  int creatorId = 14,
  int createAt = 1000000,
  bool isVote = false,
}) => PostDto(
  postId: postId,
  channelId: 5,
  creatorId: creatorId,
  message: 'hi',
  createAt: createAt,
  // 投票消息靠 `props.vote` 认（`PostDto.vote` 是 getter）
  props: isVote
      ? const {
          'vote': {
            'choices': [
              {'text': 'a'},
            ],
          },
        }
      : const {},
);

ChannelDto _channel({
  String type = 'private',
  bool encrypted = false,
  List<int> members = const [14, 4],
}) => ChannelDto(
  channelId: 5,
  name: 'c',
  type: type,
  encrypted: encrypted,
  members: members,
);

void main() {
  group('ServerSettings 解析（真机响应）', () {
    test('逐字段', () {
      final s = ServerSettings.fromJson(_liveJson);
      expect(s.fileSizeLimitMb, 0);
      expect(s.fileSizeLimitBytes, 0, reason: '0 = 不限制');
      expect(s.allowEncryption, isTrue);
      expect(s.allowGuest, isFalse);
      expect(s.allowEditMessage, isTrue);
      expect(s.editMessageTimeWithinMin, -1);
      expect(s.editWindowMs, 0, reason: '-1 = 不限时间');
      expect(s.allowReadStatus, isFalse);
      expect(s.defaultNotificationType, 'mention_subscribe');
      expect(s.hidePostUrlPreview, isTrue);
      expect(s.notificationRenderNickname, isTrue);
      expect(s.readonlyProfile, isEmpty);
    });

    test('file_size_limit 的单位是 MB（原版乘 1048576）', () {
      final s = ServerSettings.fromJson({..._liveJson, 'file_size_limit': 32});
      expect(s.fileSizeLimitMb, 32);
      expect(s.fileSizeLimitBytes, 32 * 1048576);
      expect(s.fileTooLarge(33 * 1048576), isTrue);
      expect(s.fileTooLarge(32 * 1048576), isFalse, reason: '等于上限不算超');
      expect(s.fileTooLarge(1), isFalse);
    });

    test('编辑窗口：正数按分钟，<=0 视为不限', () {
      final limited = ServerSettings.fromJson({
        ..._liveJson,
        'allow_edit_message_time_within_min': 15,
      });
      expect(limited.editWindowMs, 15 * kMsPerMinute);
      expect(
        limited.editWindowExpired(1000, nowMs: 1000 + 14 * kMsPerMinute),
        isFalse,
      );
      expect(
        limited.editWindowExpired(1000, nowMs: 1000 + 16 * kMsPerMinute),
        isTrue,
      );

      final unlimited = ServerSettings.fromJson({
        ..._liveJson,
        'allow_edit_message_time_within_min': -1,
      });
      expect(unlimited.editWindowExpired(0, nowMs: 999999999), isFalse);
      expect(
        ServerSettings.fromJson({
          ..._liveJson,
          'allow_edit_message_time_within_min': 0,
        }).editWindowExpired(0, nowMs: 999999999),
        isFalse,
        reason: '0 也当不限',
      );
    });

    test('JSON 往返 + 字段缺失时用宽松默认值', () {
      final s = ServerSettings.fromJson(_liveJson);
      final back = ServerSettings.fromJson(s.toJson());
      expect(back.toString(), s.toString());

      final empty = ServerSettings.fromJson(const {});
      expect(empty.allowEncryption, isTrue, reason: '没拉到设置前不要拦住用户');
      expect(empty.allowEditMessage, isTrue);
      expect(empty.fileSizeLimitBytes, 0);
      expect(empty.defaultNotificationType, '');
    });

    test('merge：只覆盖推送里带的字段（notify_type 空则保留旧的）', () {
      final base = ServerSettings.fromJson(_liveJson);
      final patch = ServerSettings.fromJson(const {
        'allow_edit_message': false,
        'file_size_limit': 8,
      });
      final merged = base.merge(patch);
      expect(merged.allowEditMessage, isFalse);
      expect(merged.fileSizeLimitMb, 8);
      expect(
        merged.defaultNotificationType,
        'mention_subscribe',
        reason: '推送没带 notify_type',
      );
      expect(merged.allowEncryption, isTrue);
    });
  });

  group('可编辑性（PostUtil.isPostEditable 逐行对照）', () {
    final settings = ServerSettings.fromJson(_liveJson); // 窗口不限、允许编辑

    test('别人的消息永远不能编辑', () {
      expect(
        isPostEditable(
          _post(creatorId: 4),
          _channel(),
          myUserId: 14,
          settings: settings,
        ),
        isFalse,
      );
    });

    test('自己的消息：允许编辑 + 窗口不限 → 可编辑', () {
      expect(
        isPostEditable(
          _post(createAt: 1),
          _channel(),
          myUserId: 14,
          settings: settings,
          nowMs: 9999999999,
        ),
        isTrue,
      );
    });

    test('服务端关掉 allow_edit_message → 谁都不能编辑', () {
      final off = ServerSettings.fromJson({
        ..._liveJson,
        'allow_edit_message': false,
      });
      expect(
        isPostEditable(_post(), _channel(), myUserId: 14, settings: off),
        isFalse,
      );
    });

    test('窗口过期 → 不能编辑（v4 服务器也一样）', () {
      final s15 = ServerSettings.fromJson({
        ..._liveJson,
        'allow_edit_message_time_within_min': 15,
      });
      final old = _post(createAt: 1000);
      expect(
        isPostEditable(
          old,
          _channel(),
          myUserId: 14,
          settings: s15,
          nowMs: 1000 + 16 * kMsPerMinute,
        ),
        isFalse,
      );
      expect(
        isPostEditable(
          old,
          _channel(),
          myUserId: 14,
          settings: s15,
          nowMs: 1000 + 14 * kMsPerMinute,
        ),
        isTrue,
      );
    });

    test('老服务器（不支持 v4）只有 list_editable 那条能编辑', () {
      final p = _post(postId: 100);
      expect(
        isPostEditable(
          p,
          _channel(),
          myUserId: 14,
          settings: settings,
          supportsEditAllPost: false,
          editablePostId: 100,
        ),
        isTrue,
      );
      expect(
        isPostEditable(
          p,
          _channel(),
          myUserId: 14,
          settings: settings,
          supportsEditAllPost: false,
          editablePostId: 77,
        ),
        isFalse,
        reason: '只有最新那条能改',
      );
    });

    test('投票、未启用加密时的加密频道、对方全停用的机器人频道都不能编辑', () {
      expect(
        isPostEditable(
          _post(isVote: true),
          _channel(),
          myUserId: 14,
          settings: settings,
        ),
        isFalse,
        reason: '投票消息',
      );
      expect(
        isPostEditable(
          _post(),
          _channel(encrypted: true),
          myUserId: 14,
          settings: ServerSettings.fromJson({
            ..._liveJson,
            'allow_encryption': false,
          }),
        ),
        isFalse,
        reason: '服务端关了加密 → 加密频道不能改',
      );
      expect(
        isPostEditable(
          _post(),
          _channel(type: 'anonymous', members: [14, 8]),
          myUserId: 14,
          settings: settings,
          allUsersDisabled: true,
        ),
        isFalse,
      );
      expect(
        isPostEditable(
          _post(),
          _channel(type: 'private', members: [14, 8]),
          myUserId: 14,
          settings: settings,
          allUsersDisabled: true,
        ),
        isTrue,
        reason: '普通频道不受"对方停用"影响',
      );
    });
  });

  group('订阅判定（PostUtil.isSubscribedPost）', () {
    test('按话题 id 匹配', () {
      final ch = ChannelDto(channelId: 5, name: 'c', subscribes: const [900]);
      expect(isSubscribedPost(ch, 900), isTrue);
      expect(isSubscribedPost(ch, 901), isFalse);
      expect(isSubscribedPost(ch, 0), isFalse);
      expect(isSubscribedPost(null, 900), isFalse);
    });
  });

  group('isAllOtherUsersDisabled', () {
    test('除我之外全停用才算', () {
      final ch = ChannelDto(channelId: 5, name: 'c', members: const [14, 7, 8]);
      expect(
        isAllOtherUsersDisabled(ch, 14, isDisabled: (u) => u != 14),
        isTrue,
      );
      expect(
        isAllOtherUsersDisabled(ch, 14, isDisabled: (u) => false),
        isFalse,
      );
      expect(
        isAllOtherUsersDisabled(
          ChannelDto(channelId: 5, name: 'c', members: const [14]),
          14,
          isDisabled: (_) => false,
        ),
        isTrue,
        reason: '只有我自己也算"对方全没了"（原版同样返回 true）',
      );
    });
  });
}
