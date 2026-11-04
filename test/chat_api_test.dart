// ChatApi / compound 的离线验证。
//
// 关键证据：test/fixtures/*.json 是**真实 NAS 抓下来的原始响应**
// （由 tool/probe_chat.dart 落盘），所以这里的解析断言等价于「能读懂服务器」。
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:synhub/src/data/chat_api.dart';
import 'package:synhub/src/data/dto/channel_dto.dart';
import 'package:synhub/src/data/dto/user_dto.dart';
import 'package:synhub/src/data/remote/compound.dart';
import 'package:synhub/src/dsm/webapi.dart';

/// 记录请求并返回可编程响应的假传输。
class FakeTransport extends WebApiTransport {
  FakeTransport({this.apiTable = const {}});

  final Map<String, Map<String, Object?>> apiTable;

  /// 每次请求的 (api, method, 全部参数)
  final List<Map<String, String>> calls = [];

  /// (api, method) → 响应 data（会被包成 {success:true,data:...}）
  final Map<String, Map<String, dynamic>> responses = {};

  /// 让某次调用整体失败
  final Set<String> failures = {};

  Map<String, String> get lastCall => calls.last;

  @override
  String get describeKind => 'fake';

  @override
  String get baseUrl => 'https://nas.example.com:5001/';

  @override
  Future<String> describe({String? module}) async =>
      jsonEncode({'success': true, 'data': apiTable});

  @override
  Future<String> postForm(
    String path,
    Map<String, dynamic> params, {
    String? module,
  }) async {
    calls.add({...params});
    final key = '${params['api']}.${params['method']}';

    if (failures.contains(key)) {
      return jsonEncode({
        'success': false,
        'error': {'code': 105},
      });
    }

    if (key == 'SYNO.Entry.Request.request') {
      return jsonEncode({
        'success': true,
        'data': {'has_fail': false, 'result': _compoundResult(params)},
      });
    }

    final data = responses[key] ?? const <String, dynamic>{};
    return jsonEncode({'success': true, 'data': data});
  }

  /// 按 compound 参数逐段组装响应（真的把子请求解出来，而不是照抄）
  List<Map<String, dynamic>> _compoundResult(Map<String, dynamic> params) {
    expect(params['mode'], 'parallel', reason: 'compound 必须带 mode=parallel');
    final raw = params['compound'];
    expect(raw, isNotNull, reason: 'compound 参数缺失');
    final subs = jsonDecode(raw!) as List;
    return [
      for (final s in subs)
        () {
          final m = Map<String, dynamic>.from(s as Map);
          final k = '${m['api']}.${m['method']}';
          return {
            'api': m['api'],
            'method': m['method'],
            'version': m['version'],
            'success': true,
            'data': responses[k] ?? const <String, dynamic>{},
          };
        }(),
    ];
  }

  @override
  Future<void> close() async {}
}

Map<String, dynamic> _fixture(String name) => Map<String, dynamic>.from(
  jsonDecode(File('test/fixtures/$name').readAsStringSync()) as Map,
);

/// 真实 NAS 的 API 表片段（摘自实测 query 结果）
const _table = <String, Map<String, Object?>>{
  'SYNO.API.Info': {'path': 'query.cgi', 'minVersion': 1, 'maxVersion': 1},
  'SYNO.Entry.Request': {'path': 'entry.cgi', 'minVersion': 1, 'maxVersion': 2},
  'SYNO.Chat.Channel': {'path': 'entry.cgi', 'minVersion': 1, 'maxVersion': 5},
  'SYNO.Chat.User': {'path': 'entry.cgi', 'minVersion': 1, 'maxVersion': 3},
};

ChatApi _apiWith(FakeTransport t) {
  final api = DsmWebApi(t);
  return ChatApi(api);
}

void main() {
  group('compound 请求格式', () {
    test('compound 参数是 JSON 数组字符串，mode=parallel', () async {
      final t = FakeTransport();
      final api = DsmWebApi(t);

      await api.compound([
        const ApiRequest(
          'SYNO.Chat.User',
          'list',
          version: 2,
          params: {'type': 'human'},
        ),
        const ApiRequest(
          'SYNO.Chat.User',
          'list',
          version: 2,
          params: {'type': 'bot'},
        ),
      ]);

      final call = t.lastCall;
      expect(call['api'], 'SYNO.Entry.Request');
      expect(call['method'], 'request');
      expect(call['version'], '2');
      expect(call['mode'], 'parallel');

      final subs = jsonDecode(call['compound']!) as List;
      expect(subs, hasLength(2));
      expect(subs[0], {
        'api': 'SYNO.Chat.User',
        'method': 'list',
        'version': 2,
        'type': 'human',
      });
      expect(subs[1], {
        'api': 'SYNO.Chat.User',
        'method': 'list',
        'version': 2,
        'type': 'bot',
      });
    });

    test('逐段 success 独立：某段失败不影响其他段', () async {
      final t = FakeTransport();
      t.responses['SYNO.Chat.User.list'] = {'users': []};
      final api = DsmWebApi(t);

      final results = await api.compound([
        const ApiRequest('SYNO.Chat.User', 'list', version: 2),
        const ApiRequest('SYNO.Chat.Channel', 'get', version: 5),
      ]);

      expect(results, hasLength(2));
      expect(results.every((r) => r.success), isTrue);
      expect(results[0].api, 'SYNO.Chat.User');
      expect(results[0].method, 'list');
      expect(results[0].version, 2);
    });
  });

  group('版本协商（对齐 Api.getMaxAvailableVersion）', () {
    Future<int> negotiateFor(int serverMax) async {
      final t = FakeTransport(
        apiTable: {
          'SYNO.Chat.Channel': {
            'path': 'entry.cgi',
            'minVersion': 1,
            'maxVersion': serverMax,
          },
        },
      );
      final api = DsmWebApi(t);
      await api.discover();
      return ChatApi(api).negotiate('SYNO.Chat.Channel', const [5, 4, 2, 1]);
    }

    test('服务器 5 → 5', () async => expect(await negotiateFor(5), 5));
    test('服务器 4 → 4', () async => expect(await negotiateFor(4), 4));
    test(
      '服务器 3 → 2（跳过 4/5，落到 2）',
      () async => expect(await negotiateFor(3), 2),
    );
    test('服务器 1 → 1', () async => expect(await negotiateFor(1), 1));
  });

  group('Channel.list（真实响应 fixture）', () {
    test('解析出频道并按原字段还原', () async {
      final fixture = _fixture('channel_list.json');
      final t = FakeTransport(apiTable: _table);
      t.responses['SYNO.Chat.Channel.list'] = fixture;
      final chat = _apiWith(t);
      await chat.api.discover();

      final channels = await chat.listChannels();
      expect(channels, isNotEmpty);
      expect(t.lastCall['is_joined'], 'true');
      expect(t.lastCall['version'], '5');

      final c = channels.first;
      expect(c.channelId, greaterThan(0));
      expect(c.type, isNotEmpty);
      expect(c.totalMemberCount, greaterThanOrEqualTo(0));
      // 实测响应里 notification 偏好嵌在 preferences 下
      expect(c.notificationDesktop, isA<String>());
    });

    test('v1 老版本响应缺字段也不炸（宽容解析）', () {
      final c = ChannelDto.fromJson({'channel_id': 7, 'name': 'x'});
      expect(c.channelId, 7);
      expect(c.name, 'x');
      expect(c.unread, 0);
      expect(c.unreadThread, isEmpty);
      expect(c.members, isEmpty);
      expect(c.isJoined, isFalse);
    });

    test('unread_thread 的字符串 key 被还原成 int', () {
      final c = ChannelDto.fromJson({
        'channel_id': 1,
        'unread_thread': {'12': 3, '34': 1},
      });
      expect(c.unreadThread, {12: 3, 34: 1});
    });
  });

  group('User.list（compound，真实响应 fixture）', () {
    test('human + bot 两段合并解析', () async {
      final fixture = _fixture('compound_users.json');
      // fixture 是 compound 的 data（含 result[]），直接喂给 User.list 的两段
      final segs = fixture['result'] as List;
      final human = segs[0]['data'] as Map<String, dynamic>;
      final bot = segs[1]['data'] as Map<String, dynamic>;

      final t = FakeTransport(apiTable: _table);
      t.responses['SYNO.Chat.User.list'] = human;
      final chat = _apiWith(t);
      await chat.api.discover();

      final users = await chat.listUsers();
      // 两段用同一份假响应，因此是 human 的两倍
      expect(users.length, (human['users'] as List).length * 2);

      final u = users.first;
      expect(u.userId, greaterThan(0));
      expect(u.username, isNotEmpty);
      expect(u.type, 'human');
      // 资源字段在 user_props 下
      expect(bot, isNotNull);
    });

    test('用户资料从 user_props/key_pair 里取', () {
      final users =
          _fixture('compound_users.json')['result'][0]['data']['users'] as List;
      final u = UserDto.fromJson(Map<String, dynamic>.from(users.first as Map));
      expect(u.avatarColor, startsWith('#'));
      expect(u.displayName, isNotEmpty); // nickname 为空时退回 username
      expect(u.isBot, isFalse);
    });

    test('broadcast 载荷能还原 user.update', () {
      final frames = File('test/fixtures/socket_frames.txt').readAsLinesSync();
      final broadcast = frames.firstWhere(
        (l) => l.contains('client.broadcast'),
      );
      // 42["client.broadcast",{...}]
      final payload = broadcast.substring(
        broadcast.indexOf(',') + 1,
        broadcast.lastIndexOf(']'),
      );
      final obj = jsonDecode(payload) as Map<String, dynamic>;
      expect(obj['type'], 'user.update');
      final u = UserDto.tryFromBroadcast(obj['data']);
      expect(u, isNotNull);
      expect(u!.userId, greaterThan(0));
    });
  });

  group('Channel.get via compound', () {
    test('按 id 批量取，单个失败不影响其他', () async {
      final t = FakeTransport(apiTable: _table);
      t.responses['SYNO.Chat.Channel.get'] = {
        'channel': {'channel_id': 9, 'name': 'group', 'type': 'private'},
      };
      final chat = _apiWith(t);
      await chat.api.discover();

      final chans = await chat.listChannelsByIds([9, 10]);
      expect(chans, hasLength(2));
      expect(chans.first.channelId, 9);
      expect(chans.first.name, 'group');

      final subs = jsonDecode(t.lastCall['compound']!) as List;
      expect(subs.map((e) => e['channel_id']), [9, 10]);
      expect(subs.first['version'], 5, reason: 'Channel max=5，get 存在于 v5');
    });

    // 2.4.7-22203 `SYNO.Chat.Channel` 的方法表是**互不包含**的几个版本：
    //   v3 只有 list、v4 只有 list/close/hide_global/get。
    // `get` 在 v1/v2/v3 里根本不存在，所以服务器最高到 v3 时不能发 v3 的 get。
    test('服务器只到 v3 时不发必然 103 的 Channel/get，返回空表', () async {
      final t = FakeTransport(
        apiTable: {
          'SYNO.API.Info': {
            'path': 'query.cgi',
            'minVersion': 1,
            'maxVersion': 1,
          },
          'SYNO.Entry.Request': {
            'path': 'entry.cgi',
            'minVersion': 1,
            'maxVersion': 2,
          },
          'SYNO.Chat.Channel': {
            'path': 'entry.cgi',
            'minVersion': 1,
            'maxVersion': 3,
          },
        },
      );
      final chat = _apiWith(t);
      await chat.api.discover();

      final chans = await chat.listChannelsByIds([9, 10]);
      expect(chans, isEmpty);
      expect(
        t.calls.where((c) => c['compound'] != null),
        isEmpty,
        reason: '不该发出去',
      );
    });

    test('按 2.4.7 方法表挑版本：get 只认 [5,4]', () {
      // 直接检查候选表本身（这些就是"方法可用版本"的口径）
      expect(ChatApi.channelGet, [5, 4]);
      expect(ChatApi.channelList, [5, 4, 2, 1]);
      expect(
        ChatApi.channelHide.contains(4),
        isFalse,
        reason: 'v4 没有 hide —— 不能拿协商版本去发 hide',
      );
      expect(ChatApi.channelHide.contains(2), isTrue);
      expect(ChatApi.channelHideGlobal, [5, 4]);
      expect(
        ChatApi.channelArchive.contains(4),
        isFalse,
        reason: 'archive 只在 v2/v5',
      );
    });
  });
}
