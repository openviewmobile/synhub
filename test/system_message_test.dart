// 系统消息文案（Phase 9 补齐）：逐条对齐原版 `ChannelViewBinder` + `strings.xml`。
//
// 真实 payload 形状（NAS 实测，注意是**顶层** `system_props`，不是 `props.system`）：
//   {"system_props":{"channel_id":1,"effective_user_id":14,"event":"thread.create",
//                    "post_id":4294967323,"trigger_user_id":14},
//    "message":"", "type":"system", "creator_id":1}
import 'package:flutter_test/flutter_test.dart';

import 'package:synhub/src/data/dto/channel_dto.dart';
import 'package:synhub/src/data/dto/post_dto.dart';
import 'package:synhub/src/data/dto/user_dto.dart';
import 'package:synhub/src/features/chat/system_message.dart';

const _me = 14;
const _demo_user4 = 4;
const _guest = 9;

final _users = <int, UserDto>{
  _me: UserDto(userId: _me, username: 'me', nickname: '我', type: 'human'),
  _demo_user4: UserDto(
    userId: _demo_user4,
    username: 'demo',
    nickname: '演示用户',
    type: 'human',
  ),
  _guest: UserDto(
    userId: _guest,
    username: 'guest_abc',
    nickname: '',
    type: 'human',
  ),
};

final _channel = ChannelDto.fromJson(const {
  'channel_id': 7,
  'name': '项目讨论',
  'type': 'private',
  'is_joined': true,
});

PostDto _post(
  String event,
  Map<String, dynamic> systemProps, {
  String message = '',
  String type = 'system',
}) => PostDto.fromJson({
  'post_id': 4294967300,
  'channel_id': 7,
  'creator_id': 1,
  'create_at': 1000,
  'type': type,
  'message': message,
  'system_props': {'event': event, ...systemProps},
});

String _text(PostDto p, {ChannelDto? channel}) => systemMessageText(
  p,
  usersById: _users,
  channel: channel ?? _channel,
  myUserId: _me,
);

void main() {
  group('成员进出', () {
    test('channel.join：别人自己进来（trigger=0）', () {
      expect(
        _text(
          _post('channel.join', const {
            'target_user_ids': [_demo_user4],
          }),
        ),
        '演示用户 加入了此频道。',
      );
    });

    test('channel.join：被邀请进来（trigger=邀请人，target=新人）', () {
      expect(
        _text(
          _post('channel.join', const {
            'trigger_user_id': _me,
            'target_user_ids': [_demo_user4],
          }),
        ),
        '我 已邀请 演示用户 进入此频道。',
      );
    });

    test('channel.join：访客带邮箱', () {
      expect(
        _text(
          _post('channel.join', const {
            'trigger_user_id': _me,
            'target_user_ids': [_guest],
            'extra': {'email': 'g@example.com'},
          }),
        ),
        '我的访客abc 访客 (g@example.com) 加入了此频道。',
      );
    });

    test('channel.disjoin：自己退出', () {
      expect(
        _text(
          _post('channel.disjoin', const {
            'target_user_ids': [_demo_user4],
          }),
        ),
        '演示用户 离开了此频道。',
      );
    });

    test('channel.disjoin：被踢（trigger=操作人）', () {
      expect(
        _text(
          _post('channel.disjoin', const {
            'trigger_user_id': _me,
            'target_user_ids': [_demo_user4],
          }),
        ),
        '我 已将 演示用户 从成员列表中删除。',
      );
    });

    test('channel.kick：用频道名', () {
      expect(
        _text(
          _post('channel.kick', const {
            'target_user_ids': [_me],
          }),
        ),
        '您已从 项目讨论 的成员列表中被删除。',
      );
    });

    test('channel.guest.invited', () {
      expect(
        _text(
          _post('channel.guest.invited', const {
            'trigger_user_id': _me,
            'extra': {'email': 'g@example.com'},
          }),
        ),
        '我 已邀请访客 g@example.com。',
      );
    });

    test('多人用 ", " 连接（原版 displayUsersName）', () {
      expect(
        _text(
          _post('channel.disjoin', const {
            'target_user_ids': [_demo_user4, _me],
          }),
        ),
        '演示用户, 我 离开了此频道。',
      );
    });
  });

  group('频道本身', () {
    test('channel.update：改名 / 改描述 / 类型升级', () {
      expect(
        _text(
          _post('channel.update', const {
            'extra': {
              'update_info': [
                {'attr': 'channel_name', 'new': '新名字', 'old': '旧名字'},
              ],
            },
          }),
        ),
        '频道名称已更改为 新名字。',
      );
      expect(
        _text(
          _post('channel.update', const {
            'extra': {
              'update_info': [
                {'attr': 'purpose', 'new': '新描述', 'old': ''},
              ],
            },
          }),
        ),
        '频道描述已更改为 新描述。',
      );
      expect(
        _text(
          _post('channel.update', const {
            'extra': {
              'update_info': [
                {'attr': 'type', 'new': 'private', 'old': 'anonymous'},
              ],
            },
          }),
        ),
        '会话已转换为专用频道。',
      );
      expect(
        _text(
          _post('channel.update', const {
            'extra': {
              'update_info': [
                {'attr': 'channel_name', 'new': '新名字'},
                {'attr': 'purpose', 'new': '新描述'},
              ],
            },
          }),
        ),
        '频道名称已更改为 新名字。 频道描述已更改为 新描述。',
      );
    });

    test('channel.close：四种 reason', () {
      expect(
        _text(
          _post('channel.close', const {
            'extra': {'reason': 'all_user_broken'},
          }),
        ),
        '频道 项目讨论 已关闭。原因：所有的用户都无法进入此频道。',
      );
      expect(
        _text(
          _post('channel.close', const {
            'extra': {'reason': 'user_deleted', 'username': 'demo'},
          }),
        ),
        '频道 项目讨论 已关闭。原因：用户 demo 已删除。',
      );
      expect(
        _text(
          _post('channel.close', const {
            'extra': {'reason': 'admin_toggle'},
          }),
        ),
        '频道 项目讨论 已关闭。原因：此操作由管理员触发。',
      );
      expect(
        _text(
          _post('channel.close', const {
            'extra': {'reason': 'user_trigger', 'username': 'demo_user'},
          }),
        ),
        '频道 项目讨论 已关闭。原因：demo_user已关闭此频道。',
      );
    });

    test('channel.archive：-1 用「系统用户」', () {
      expect(
        _text(_post('channel.archive', const {'trigger_user_id': -1})),
        '频道 项目讨论 已被 系统用户 存档。',
      );
      expect(
        _text(_post('channel.archive', const {'trigger_user_id': _demo_user4})),
        '频道 项目讨论 已被 演示用户 存档。',
      );
    });

    test('channel.revive / channel.rescue', () {
      expect(
        _text(_post('channel.revive', const {'trigger_user_id': _demo_user4})),
        '您已被 演示用户 恢复。您现在可回到 项目讨论。',
      );
      expect(
        _text(
          _post('channel.rescue', const {
            'trigger_user_id': _demo_user4,
            'target_user_ids': [_me],
          }),
        ),
        '我 已被 演示用户 恢复。',
      );
    });
  });

  group('加密 / 密钥', () {
    test('user.broken 用真人名（不是 user_id）', () {
      expect(
        _text(
          _post('user.broken', const {
            'trigger_user_id': _me,
            'target_user_ids': [_demo_user4],
          }),
        ),
        '我, 演示用户 无法进入此频道且其权限必须由另一用户恢复。',
      );
    });

    test('user.forgot_password / encrypt.enabled / encrypt.disabled', () {
      expect(_text(_post('user.forgot_password', const {})), '您的私钥已重置。');
      expect(_text(_post('encrypt.enabled', const {})), contains('启用频道加密'));
      expect(
        _text(_post('encrypt.disabled', const {})),
        contains('加密频道已由管理员禁用'),
      );
    });

    test('encrypt.notify 带上邀请人', () {
      expect(
        _text(_post('encrypt.notify', const {'trigger_user_id': _demo_user4})),
        contains('演示用户 邀请您使用频道加密'),
      );
    });
  });

  group('帖子 / 话题 / 投票', () {
    // ★ r339（D38）：这三条曾经把**官方变量名**当期望值钉住 ——
    // `已创建一篇 post。` / `演示用户 已在 post 中留言。` / `已锁定 this message`。
    // 单测"绿"了很多轮，真机上却把 `post` / `this message` 画给用户：
    // **用例把缺陷当成了契约**。期望值改中文，泄漏扫描守卫见
    // `test/i18n_placeholder_audit_test.dart`（含反向）。
    test('thread.create / comment.create / post.pin', () {
      expect(_text(_post('thread.create', const {})), '已创建一篇帖子。');
      expect(
        _text(_post('comment.create', const {'trigger_user_id': _demo_user4})),
        '演示用户 已在帖子中留言。',
      );
      expect(_text(_post('post.pin', const {})), '已锁定此消息');
    });

    test('post.delete：消息 / 文件两种措辞', () {
      expect(
        _text(
          _post('post.delete', const {
            'trigger_user_id': _demo_user4,
            'extra': {
              'username': 'demo',
              'channel': {'name': '项目讨论'},
              'post': {'message': '早上好'},
            },
          }),
        ),
        'demo 已删除您在通道 项目讨论 中的消息 早上好。',
      );
      expect(
        _text(
          _post('post.delete', const {
            'trigger_user_id': _demo_user4,
            'extra': {
              'username': 'demo',
              'channel': {'name': '项目讨论'},
              'post': {
                'message': '',
                'file_props': {'name': 'report.pdf'},
              },
            },
          }),
        ),
        'demo 已删除您在通道 项目讨论 中的文件 report.pdf。',
      );
    });

    test('post.vote.delete / close / update', () {
      expect(
        _text(
          _post('post.vote.delete', const {
            'trigger_user_id': _demo_user4,
            'extra': {
              'username': 'demo',
              'channel': {'name': '项目讨论'},
              'post': {'message': ''},
            },
          }),
        ),
        'demo 已删除您在通道 项目讨论 中的投票 。',
      );
      expect(_text(_post('post.vote.close', const {})), '投票现已关闭。');
      expect(_text(_post('post.vote.update', const {})), '投票已更新。');
    });
  });

  group('集成 / 兜底', () {
    test('bot.* 文案', () {
      expect(
        _text(
          _post('bot.add', const {
            'trigger_user_id': _me,
            'target_user_ids': [_demo_user4],
          }),
        ),
        '我 已添加整合 演示用户',
      );
      expect(
        _text(
          _post('bot.delete', const {
            'trigger_user_id': _me,
            'target_user_ids': [_demo_user4],
          }),
        ),
        '我 已删除整合 演示用户。',
      );
      expect(
        _text(
          _post('bot.set_disabled', const {
            'trigger_user_id': _me,
            'target_user_ids': [_demo_user4],
            'extra': {'is_disabled': true},
          }),
        ),
        '我 已禁用集成 演示用户。',
      );
    });

    test('welcome.message：私密空间欢迎语（trigger 翻名字）', () {
      // 原版 `bindWelcome` + `R.string.welcome`
      expect(
        _text(
          _post('welcome.message', const {
            'trigger_user_id': _demo_user4,
            'effective_user_id': _demo_user4,
          }),
        ),
        '您好，演示用户，\n这是您的私密空间，您可在此写信息或保留您将来可能会用到的任何文件和链接。',
      );
    });

    test('welcome.message：查不到那个人时名字留空（原版 displayUsersName 返回空）', () {
      expect(
        _text(_post('welcome.message', const {'trigger_user_id': 999})),
        // 模板是「您好，%1$s，」，名字为空就出现两个逗号 —— 原版就是这样
        '您好，，\n这是您的私密空间，您可在此写信息或保留您将来可能会用到的任何文件和链接。',
      );
    });

    test('command.error 用 message 原文', () {
      expect(
        _text(_post('command.error', const {}, message: '不认识的命令')),
        '不认识的命令',
      );
    });

    test('没有 event 但有 message → 用 message；都没有 → 「系统消息」', () {
      final withMsg = PostDto.fromJson(const {
        'post_id': 1,
        'channel_id': 7,
        'type': 'system',
        'message': '服务端直接给了文案',
      });
      expect(_text(withMsg), '服务端直接给了文案');
      final empty = PostDto.fromJson(const {
        'post_id': 1,
        'channel_id': 7,
        'type': 'system',
        'message': '',
      });
      expect(_text(empty), '系统消息');
    });

    test('未知 event → 明确兜底，不崩', () {
      expect(
        _text(_post('brand.new.event', const {'trigger_user_id': _demo_user4})),
        '系统消息（brand.new.event）',
      );
    });
  });

  group('兜底与兼容', () {
    test('只有 effective_user_id 时也能说清是谁', () {
      expect(
        _text(_post('channel.join', const {'effective_user_id': _demo_user4})),
        '演示用户 加入了此频道。',
      );
    });
  });

  group('名字规则（ChatUtil.displayUserName）', () {
    test('昵称优先、访客后缀、缺用户兜底', () {
      expect(displayUserName(_users[_demo_user4], _demo_user4), '演示用户');
      expect(displayUserName(_users[_guest], _guest), 'abc 访客');
      expect(displayUserName(null, 42), '用户 42');
      expect(
        displayUserName(
          const UserDto(userId: 3, username: 'onlyname', type: 'human'),
          3,
        ),
        'onlyname',
      );
    });
  });
}
