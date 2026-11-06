// 消息链路的测试脚手架：假传输 + 假实时通道 + 一个装好 ProviderContainer 的
// ChatSessionController。给 test/chat_messages_test.dart（逻辑）与
// test/chat_page_test.dart（UI）共用。
import 'dart:async';
import 'dart:io';
import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pointycastle/export.dart';
import 'package:synhub/src/data/chat_api.dart';
import 'package:synhub/src/data/local/database.dart';
import 'package:synhub/src/data/remote/socket/chat_socket.dart';
import 'package:synhub/src/core/services/service_reporting_api.dart';
import 'package:synhub/src/dsm/cgi_encryption.dart';
import 'package:synhub/src/dsm/webapi.dart';
import 'package:synhub/src/features/chat/chat_session_controller.dart';
import 'package:synhub/src/features/servers/connection_service.dart';
import 'package:synhub/src/features/servers/server_profile.dart';
import 'dart:typed_data';
import 'package:synhub/src/data/e2ee/e2ee_service.dart';

/// 记录请求并回放预设响应（按 `api.method` 索引）
class FakeTransport extends WebApiTransport {
  FakeTransport([
    Map<String, Map<String, dynamic>>? responses,
    Map<String, Map<String, dynamic>>? apiTable,
  ]) : responses = responses ?? {},
       apiTable = apiTable ?? table;

  /// (api, method) → 响应 data
  final Map<String, Map<String, dynamic>> responses;

  /// `SYNO.API.Info` 里的能力表（用例可以改小某个 API 的 maxVersion，
  /// 用来验"老服务器"分支）
  final Map<String, Map<String, dynamic>> apiTable;

  /// (api, method) → 让这次调用返回 `success:false` 的错误码（**一直**失败）
  final Map<String, int> failures = {};

  /// (api, method) → **只失败这一次**，之后恢复正常响应。
  /// 测"会话过期 → 重登 → 重放"用（重放那一次必须成功）。
  final Map<String, int> failTimes = {};
  final List<Map<String, dynamic>> calls = [];

  /// 登录了几次（第一次的 sid 保持 `FAKE-SID`，之后递增）
  int _loginCount = 0;

  static const table = {
    'SYNO.API.Info': {'path': 'query.cgi', 'minVersion': 1, 'maxVersion': 1},
    'SYNO.Chat.Channel': {
      'path': 'entry.cgi',
      'minVersion': 1,
      'maxVersion': 5,
    },
    // 服务端能力/限制（编辑窗口、文件大小上限、加密开关…）
    'SYNO.Chat.Admin.Setting': {
      'path': 'entry.cgi',
      'minVersion': 1,
      'maxVersion': 5,
    },
    'SYNO.Chat.User': {'path': 'entry.cgi', 'minVersion': 1, 'maxVersion': 3},
    'SYNO.Chat.Post': {'path': 'entry.cgi', 'minVersion': 1, 'maxVersion': 8},
    'SYNO.Chat.Post.Reaction': {
      'path': 'entry.cgi',
      'minVersion': 1,
      'maxVersion': 1,
    },
    'SYNO.Chat.Post.Subscribe': {
      'path': 'entry.cgi',
      'minVersion': 1,
      'maxVersion': 2,
    },
    'SYNO.Chat.Post.Hashtag': {
      'path': 'entry.cgi',
      'minVersion': 1,
      'maxVersion': 1,
    },
    // 频道成员（Channel/get 不带成员，要单独问）
    'SYNO.Chat.Channel.Member': {
      'path': 'entry.cgi',
      'minVersion': 1,
      'maxVersion': 1,
    },
    // 命名频道（创建/邀请/退出/踢人）——服务端只有 v1
    'SYNO.Chat.Channel.Named': {
      'path': 'entry.cgi',
      'minVersion': 1,
      'maxVersion': 1,
    },
    // 头像（`SYNO.Personal.Profile.Photo` delete）——真机上是 v1-2
    'SYNO.Personal.Profile.Photo': {
      'path': 'entry.cgi',
      'minVersion': 1,
      'maxVersion': 2,
    },
    // 头像取图（`SYNO.Chat.User.Avatar / get`）—— 2.4.7 服务端包实测 v1: get
    'SYNO.Chat.User.Avatar': {
      'path': 'entry.cgi',
      'minVersion': 1,
      'maxVersion': 1,
    },
    // 贴纸目录（Phase 5：`SYNO.Chat.Sticker / list` v1，真机 maxVersion=2）
    'SYNO.Chat.Sticker': {
      'path': 'entry.cgi',
      'minVersion': 1,
      'maxVersion': 2,
    },
    // 机器人消息按钮（2.4.7 服务端方法表：只有 trigger 一个方法）
    'SYNO.Chat.Post.Attachment': {
      'path': 'entry.cgi',
      'minVersion': 1,
      'maxVersion': 1,
    },
    // 权限表（`SYNO.Chat.Misc acl`）
    'SYNO.Chat.Misc': {'path': 'entry.cgi', 'minVersion': 1, 'maxVersion': 1},
    // Phase 6 剩余项：频道标签（帖子标签上面已有）
    'SYNO.Chat.Channel.Hashtag': {
      'path': 'entry.cgi',
      'minVersion': 1,
      'maxVersion': 1,
    },
    // Phase 6：投票 / 提醒 / 定时消息（真机 maxVersion 都是 1）
    'SYNO.Chat.Post.Vote': {
      'path': 'entry.cgi',
      'minVersion': 1,
      'maxVersion': 1,
    },
    // 注意：`create` / `vote` / `get_choices` / `close` / `create_option` /
    // `set` / `delete` 全在 v1 —— 真机 2.4.7 也是 maxVersion=1
    'SYNO.Chat.Post.Reminder': {
      'path': 'entry.cgi',
      'minVersion': 1,
      'maxVersion': 1,
    },
    'SYNO.Chat.Post.Schedule': {
      'path': 'entry.cgi',
      'minVersion': 1,
      'maxVersion': 1,
    },
    // Phase 7：E2EE 用的匿名频道 API
    'SYNO.Chat.Channel.Anonymous': {
      'path': 'entry.cgi',
      'minVersion': 1,
      'maxVersion': 2,
    },
    // Phase 6 剩余项：归档 / 机器人（标签两个 API 表里本来就有）
    'SYNO.Chat.Archive': {
      'path': 'entry.cgi',
      'minVersion': 1,
      'maxVersion': 1,
    },
    'SYNO.Chat.Channel.Chatbot': {
      'path': 'entry.cgi',
      'minVersion': 1,
      'maxVersion': 1,
    },
    // Phase 9：频道通知档位（真机 2.4.6 maxVersion=3，服务端 2.3.1 也是 3）
    'SYNO.Chat.Channel.Preference': {
      'path': 'entry.cgi',
      'minVersion': 1,
      'maxVersion': 3,
    },
    // Phase 9：用户偏好（免打扰 / 定时免打扰）——真机 2.4.7 maxVersion=4
    'SYNO.Chat.User.Preference': {
      'path': 'entry.cgi',
      'minVersion': 1,
      'maxVersion': 4,
    },
    // 斜杠命令（`/jitsi` 起会议）——真机 2.4.7 maxVersion=1
    'SYNO.Chat.Webhook.Slash': {
      'path': 'entry.cgi',
      'minVersion': 1,
      'maxVersion': 1,
    },
    'SYNO.Entry.Request': {
      'path': 'entry.cgi',
      'minVersion': 1,
      'maxVersion': 2,
    },
    'SYNO.API.Auth': {'path': 'auth.cgi', 'minVersion': 1, 'maxVersion': 6},
    'SYNO.API.Encryption': {
      'path': 'encryption.cgi',
      'minVersion': 1,
      'maxVersion': 1,
    },
  };

  /// 让 `SYNO.API.Info / query`（`describe`）直接抛**断网**：
  /// 验"网络失败 → unreachable，**不隐藏** tab"（设计 §3 用例 9）。
  bool offlineDescribe = false;

  @override
  Future<String> describe({String? module}) async {
    if (offlineDescribe) {
      throw DioException(
        requestOptions: RequestOptions(path: 'query.cgi'),
        type: DioExceptionType.connectionError,
        error: 'describe offline (test)',
      );
    }
    return jsonEncode({'success': true, 'data': apiTable});
  }

  /// 便捷构造：只给一份**可编程的 `SYNO.API.Info` 能力表**
  /// （设计 §3 基础设施）。登录/取公钥等响应走默认空值。
  static FakeTransport withApiInfo(Map<String, Map<String, dynamic>> apiInfo) =>
      FakeTransport(const {}, apiInfo);

  /// 每次请求的**人为延迟**（默认 0）。测"请求进行中"的 UI（转圈/禁用）时
  /// 设一个值，配合 `tester.pump(Duration)` 观察中间态。
  Duration responseDelay = Duration.zero;

  /// 这些 `api.method` **永远不返回**（用来测"请求进行中"的界面——
  /// 比 [responseDelay] 干净：不会留下待触发的 Timer 让测试框架报错）。
  final Set<String> pendingKeys = {};

  /// 这些 `api.method` 直接抛 `DioException`（= 断网），
  /// 用来测各模块的**离线回落**（本地缓存 + 离线写队列）。
  final Set<String> offlineKeys = {};

  /// 按**请求参数**动态决定回包（比静态 `responses[api.method]` 更灵活）：
  /// Drive 等接口的回包取决于 `path` 参数，用它按目录给不同 items。
  /// 返回 null 表示"这次不用它，走静态 responses"。
  Map<String, dynamic>? Function(Map<String, dynamic> params)? onCall;

  @override
  Future<String> postForm(
    String path,
    Map<String, dynamic> params, {
    String? module,
  }) async {
    calls.add(params);
    final key0 = '${params['api']}.${params['method']}';
    if (offlineKeys.contains(key0)) {
      throw DioException(
        requestOptions: RequestOptions(path: path),
        type: DioExceptionType.connectionError,
        error: 'offline (test)',
      );
    }
    if (pendingKeys.contains(key0)) return Completer<String>().future;
    if (responseDelay > Duration.zero) {
      await Future<void>.delayed(responseDelay);
    }
    final key = '${params['api']}.${params['method']}';
    final failCode = failures[key];
    if (failCode != null) {
      return jsonEncode({
        'success': false,
        'error': {'code': failCode},
      });
    }
    final once = failTimes.remove(key); // 消费掉：下一次就是正常响应
    if (once != null) {
      return jsonEncode({
        'success': false,
        'error': {'code': once},
      });
    }

    // 登录要真 RSA 加密（客户端实现了 CGI 加密协议），所以这里给真公钥
    if (key == 'SYNO.API.Encryption.getinfo') {
      return jsonEncode({
        'success': true,
        'data': {
          'public_key': _testPubKeyB64(),
          // 真服务端会下发这两个字面量：前者当**参数名**装密文，
          // 后者当前缀。假服务端漏了它们，登录请求里就会出现一个空名字段，
          // 掩盖"参数放错位置"的问题（补上更贴近真机）。
          'cipherkey': '__cIpHeRtExT',
          'ciphertoken': '__cIpHeRtOkEn',
        },
      });
    }
    if (key == 'SYNO.API.Auth.login') {
      return jsonEncode({
        'success': true,
        // sid 每次都换（更接近真服务端：重新登录会拿到新 sid）。
        // 第一个仍是 `FAKE-SID`，老断言（`_sid=FAKE-SID`）不受影响。
        'data': {
          'sid': _loginCount++ == 0 ? 'FAKE-SID' : 'FAKE-SID-$_loginCount',
          'synotoken': 'FAKE-TOKEN',
          // 真服务端在"信任此设备"或"带着上次的 device_id"时回 `did`，
          // 客户端存下来下次当 `device_id` 回传（见 TrustDeviceManager）
          if (params['enable_device_token'] == 'yes' ||
              params['device_id'] != null)
            'did': 'FAKE-DID',
        },
      });
    }
    // compound：把每段当成独立调用处理
    if (key == 'SYNO.Entry.Request.request') {
      final segments = jsonDecode('${params['compound']}') as List;
      final result = <Map<String, dynamic>>[];
      for (final seg in segments) {
        final m = Map<String, dynamic>.from(seg as Map);
        final k = '${m['api']}.${m['method']}';
        result.add({
          'api': m['api'],
          'method': m['method'],
          'version': m['version'],
          'success': true,
          'data': responses[k] ?? const <String, dynamic>{},
        });
      }
      return jsonEncode({
        'success': true,
        'data': {'has_fail': false, 'result': result},
      });
    }
    final dynamicReply = onCall?.call(params);
    if (dynamicReply != null) {
      return jsonEncode({'success': true, 'data': dynamicReply});
    }
    final data = Map<String, dynamic>.from(
      responses[key] ?? const <String, dynamic>{},
    );
    // 服务端会原样回带我们发去的 mobile_token（实测行为），假服务端照做
    if (key == 'SYNO.Chat.Post.create' && params['mobile_token'] != null) {
      data['mobile_token'] = params['mobile_token'];
    }
    return jsonEncode({'success': true, 'data': data});
  }

  /// multipart 上传：把查询串和表单字段一起记进 [calls]（另有文件名/路径两个键）
  @override
  Future<String> postMultipart(
    String path, {
    required Map<String, dynamic> query,
    required Map<String, String> fields,
    String? fileField,
    String? filePath,
    String? fileName,
    String? mimeType,
    String? module,
    List<MultipartUploadFile>? files,
    void Function(int sent, int total)? onProgress,
    Map<String, String>? headers,
  }) async {
    final recorded = <String, dynamic>{
      ...query,
      ...fields,
      'file_name': ?fileName,
      'file_path': ?filePath,
      // 上传时声明的 MIME（视频入口要验 `video/mp4` 这类走对了）
      'mime_type': ?mimeType,
      // 上传那一刻的实际字节（加密附件测试要检查它是密文）
      if (filePath != null && File(filePath).existsSync())
        'file_bytes': File(filePath).readAsBytesSync(),
      'file_field': ?fileField,
      // 多文件（笔记附件）：字段名 → 文件名 的列表
      if (files != null)
        'files': [for (final f in files) '${f.field}:${f.fileName}'],
      if (files != null && files.length == 1) ...{
        'file_name': files.first.fileName,
        'file_path': files.first.path,
        if (File(files.first.path).existsSync())
          'file_bytes': File(files.first.path).readAsBytesSync(),
      },
    };
    calls.add(recorded);
    onProgress?.call(1, 2);
    onProgress?.call(2, 2);
    // 元数据可能在查询串（聊天上传）也可能在表单字段（笔记附件，官方 App 就在字段里）
    final api = '${fields['api'] ?? query['api'] ?? ''}';
    final method = '${fields['method'] ?? query['method'] ?? ''}';
    final key = '$api.$method';
    final failCode = failures[key];
    if (failCode != null) {
      return jsonEncode({
        'success': false,
        'error': {'code': failCode},
      });
    }
    final data = Map<String, dynamic>.from(
      responses[key] ?? const <String, dynamic>{},
    );
    // 假服务端照着真服务端的形状回一条 file 消息
    if (data.isEmpty && fileName != null) {
      final id = uploadPostId;
      data.addAll({
        'post_id': id,
        'channel_id': int.tryParse('${query['channel_id']}') ?? 0,
        'creator_id': 14,
        'create_at': 1700000009000,
        'type': 'file',
        'message': fields['message'] ?? '',
        'thread_id': int.tryParse('${query['thread_id'] ?? 0}') ?? 0,
        'file_props': {
          'name': fileName,
          'type': fileName.contains('.')
              ? fileName.split('.').last.toLowerCase()
              : '',
          'size': 68,
          'mtime': 1700000009,
          'is_image': false,
          'is_snippet': false,
          'is_voice_msg': false,
          'source': 'upload',
        },
        'props': {'encrypted': false},
      });
    }
    return jsonEncode({'success': true, 'data': data});
  }

  /// 上传默认返回的 post_id
  int uploadPostId = 900001;

  /// 下载接口返回的字节
  List<int> downloadBytes = utf8.encode('fake-attachment');

  /// 按 URL 子串定制的字节（例如 OG 图/头像）：命中优先于 [downloadBytes]
  final Map<String, List<int>> bytesByUrl = {};

  /// 记录下载过的 URL
  final List<String> downloads = [];

  /// 记录带 `Range` 的下载：`<url>#<maxBytes>`
  final List<String> ranges = [];

  /// 测试用：把下载卡住（验进度框的「取消」）
  bool holdDownloads = false;
  Completer<void>? _holdGate;

  /// 放行被 [holdDownloads] 卡住的下载
  void releaseDownloads() {
    _holdGate?.complete();
    _holdGate = null;
  }

  @override
  Future<List<int>> getBytes(
    String url, {
    void Function(int received, int total)? onProgress,
    DownloadCancelToken? cancelToken,
    int? maxBytes,
    int? tailBytes,
    String? module,
  }) async {
    if (cancelToken?.isCancelled ?? false) {
      throw const DownloadCancelledException();
    }
    // 记录 Range（文本预览取头部 / 内嵌封面取头尾片段）
    if (tailBytes != null && tailBytes > 0) {
      ranges.add('$url#tail=$tailBytes');
    } else if (maxBytes != null) {
      ranges.add('$url#$maxBytes');
    }
    downloads.add(url);
    final failCode = failures.entries
        .where((e) => url.contains(e.key))
        .map((e) => e.value)
        .firstOrNull;
    if (failCode != null) {
      throw DsmTransportException(
        'HTTP $failCode',
        statusCode: failCode,
        uri: url,
      );
    }
    if (holdDownloads) {
      _holdGate ??= Completer<void>();
      await _holdGate!.future;
      if (cancelToken?.isCancelled ?? false) {
        throw const DownloadCancelledException();
      }
    }
    // ★ 闸门放行后**必须再查一次取消令牌**：真实下载被取消时不会返回字节。
    //   桩里若在此处照常回字节，"取消 → 不落盘"的用例会变成假绿（第 38 轮实测）。
    if (cancelToken?.isCancelled ?? false) {
      throw const DownloadCancelledException();
    }
    var data = downloadBytes;
    for (final e in bytesByUrl.entries) {
      if (url.contains(e.key)) {
        data = e.value;
        break;
      }
    }
    // 模拟 `Range: bytes=0-N` / `bytes=-N`：真服务端只回对应片段（HTTP 206）
    if (tailBytes != null && tailBytes > 0 && data.length > tailBytes) {
      data = data.sublist(data.length - tailBytes);
    } else if (maxBytes != null && maxBytes > 0 && data.length > maxBytes) {
      data = data.sublist(0, maxBytes);
    }
    onProgress?.call(data.length, data.length);
    return data;
  }

  /// 记录 POST 表单下载（导出类接口）：`<path>?<params>`
  final List<String> postDownloads = [];

  @override
  Future<List<int>> postBytes(
    String path,
    Map<String, dynamic> params, {
    void Function(int received, int total)? onProgress,
    DownloadCancelToken? cancelToken,
    String? module,
  }) async {
    if (cancelToken?.isCancelled ?? false) {
      throw const DownloadCancelledException();
    }
    postDownloads.add(
      '$path?${params.entries.map((e) => '${e.key}=${e.value}').join('&')}',
    );
    // 匹配键既可以是 path 片段，也可以是 `api` 名字（导出类接口的 path 都叫
    // `entry.cgi`，只能靠 `api` 区分）
    final api = '${params['api']}';
    bool hit(String key) => path.contains(key) || api.contains(key);
    final failCode = failures.entries
        .where((e) => hit(e.key))
        .map((e) => e.value)
        .firstOrNull;
    if (failCode != null) {
      throw DsmTransportException(
        'HTTP $failCode',
        statusCode: failCode,
        uri: path,
      );
    }
    var data = downloadBytes;
    for (final e in bytesByUrl.entries) {
      if (hit(e.key)) {
        data = e.value;
        break;
      }
    }
    onProgress?.call(data.length, data.length);
    return data;
  }

  @override
  String get baseUrl => 'https://nas.example.com:5001/';

  @override
  String authenticatedUrl(
    String path,
    Map<String, String> params, {
    String? sid,
  }) {
    // ⚠️ 与**生产**的 `DirectTransport.authenticatedUrl` 同形：`_sid` 与
    // `SynoToken` **都**在查询串里。少一个都会让媒体层的查询串自检（
    // `media_source.dart`）把这条来源判成 sessionExpired —— 那是对的语义，
    // 所以脚手架必须跟生产一致，否则测的是"假传输的缺陷"。
    final qp = <String, String>{
      ...params,
      '_sid': ?sid,
      if (synoToken != null && synoToken!.isNotEmpty) 'SynoToken': synoToken!,
    };
    final q = qp.entries
        .map((e) => '${e.key}=${Uri.encodeQueryComponent(e.value)}')
        .join('&');
    return 'https://fake.test/webapi/$path?$q';
  }

  @override
  String get describeKind => 'fake';

  @override
  Future<void> close() async {}
}

/// 一次生成、全程复用的测试 RSA 公钥（base64 X.509）
String? _pubCache;
String _testPubKeyB64() {
  if (_pubCache != null) return _pubCache!;
  final kp = generateTestRsaKeyPair(1024);
  _pubCache = base64Encode(
    encodeX509RsaPublicKey(
      (kp.publicKey as RSAPublicKey).modulus!,
      (kp.publicKey as RSAPublicKey).exponent!,
    ),
  );
  return _pubCache!;
}

/// 立刻"就绪"的假实时通道
class FakeChatSocket extends ChatSocket {
  FakeChatSocket({
    required super.baseUrl,
    required super.sid,
    this.healthy = true,
  }) : super(synotoken: null);

  /// false 表示"实时通道没建起来"（用于验证降级 UI）
  final bool healthy;

  final _events = StreamController<ChatSocketEvent>.broadcast();

  @override
  String? get connId => healthy ? 'FAKE-CONN' : null;

  @override
  ChatSocketStatus get status =>
      healthy ? ChatSocketStatus.ready : ChatSocketStatus.error;

  @override
  Stream<ChatSocketEvent> get events => _events.stream;

  @override
  Stream<ChatSocketStatus> get statuses => const Stream.empty();

  @override
  Future<void> connect() async {}

  @override
  Future<void> waitReady({
    Duration timeout = const Duration(seconds: 20),
  }) async {
    if (!healthy) throw TimeoutException('假 socket 未就绪');
  }

  /// 记下发出去的事件（typing 节流之类的行为要断言）
  final List<({String event, Object? payload})> emitted = [];

  @override
  void emit(String event, [Object? payload]) =>
      emitted.add((event: event, payload: payload));

  /// 某个事件被发了几次
  int emitCount(String event) => emitted.where((e) => e.event == event).length;

  @override
  void dispose() {
    if (!_events.isClosed) _events.close();
  }

  void push(ChatSocketEvent e) {
    if (!_events.isClosed) _events.add(e);
  }
}

const testChannelJson = {
  'channel_id': 5,
  'name': '测试频道',
  'type': 'public',
  'is_joined': true,
  'unread': 3,
  'last_post_at': 1000,
};

const testPostJson = {
  'post_id': 4294967300,
  'channel_id': 5,
  'creator_id': 14,
  'create_at': 2000,
  'type': 'normal',
  'message': '来自服务端的正文',
  'props': {'encrypted': false},
};

class ChatHarness {
  ChatHarness(this.container, this.socket, this.transport, this.api);

  final ProviderContainer container;
  final FakeChatSocket socket;

  /// 假传输背后的 API（测 URL 之类的用）
  final DsmWebApi api;

  /// 假传输：可以查"客户端到底发了哪些请求"
  final FakeTransport transport;

  ChatSessionController get ctrl =>
      container.read(chatSessionControllerProvider.notifier);

  /// 直接调 API（不经过控制器）时用
  ChatApi get apiForTest => ChatApi(api);
}

Future<ChatHarness> bootChat({
  Map<String, Map<String, dynamic>>? extra,
  bool healthy = true,
  List<Object> moreOverrides = const [],

  /// 覆盖 `SYNO.API.Info` 能力表（验老服务器：把某个 API 的 maxVersion 调小）
  Map<String, Map<String, dynamic>>? apiTable,

  /// 服务器证书没过系统 CA 校验（只有我们的固定指纹信任它）
  bool certPinned = false,

  /// 复用外部的本地库（不新建内存库）。
  ///
  /// ★ r326：模拟"**同一台设备上 App 冷启动**" —— 连起两个容器、共用同一个
  /// `ChatDatabase`，第二个容器的 `ChatSyncState` 从空串开始（= 新进程），
  /// 而本地键值表/消息都还在。别再用 `moreOverrides` 去 override
  /// `chatDatabaseProvider`：同一个容器里重复 override 会被 Riverpod 直接拒
  /// （`Tried to override a provider twice`）。
  ChatDatabase? database,
}) async {
  final responses = <String, Map<String, dynamic>>{
    'SYNO.Chat.Channel.list': {
      'channels': [testChannelJson],
    },
    'SYNO.Chat.User.list': {
      'users': [
        {'user_id': 14, 'username': 'me', 'type': 'human', 'status': 'online'},
      ],
    },
    'SYNO.Chat.User.get': {
      'user': {'user_id': 14, 'username': 'me', 'type': 'human'},
    },
    // 真实响应：ChannelViewVo { success, data: { last_view_at } }，
    // DsmWebApi.call 已经把外层 data 拆掉，所以这里直接就是 last_view_at
    'SYNO.Chat.Channel.view': {'last_view_at': 1234},
    // 用户偏好（免打扰）：真机返回的字段名/默认值（关闭定时免打扰时服务端
    // **不下发** start/end，这里也照真机来，逼 DTO 走默认值分支）
    'SYNO.Chat.User.Preference.get': {
      'preferences': {
        'notification_showmessage': true,
        'snooze': 0,
        'snooze_schedule_enable': false,
      },
    },
    'SYNO.Chat.User.Preference.set': {'success': true},
    ...?extra,
  };

  final transport = FakeTransport(responses, apiTable);
  final api = ServiceReportingApi(transport);
  await api.discover();
  await api.login(account: 'a', password: 'b');

  final conn = DsmConnection(
    api: api,
    endpoint: const ResolvedEndpoint(
      baseUrl: 'https://nas:5001/',
      source: 'lan',
    ),
    profile: const ServerProfile(
      kind: ServerAddressKind.direct,
      value: 'https://nas:5001/',
    ),
    dio: Dio(),
    certPinned: certPinned,
  );

  late FakeChatSocket socket;
  final container = ProviderContainer(
    overrides: <Object>[
      chatDatabaseProvider.overrideWith((ref) {
        if (database != null) return database;
        final db = ChatDatabase(NativeDatabase.memory());
        ref.onDispose(db.close);
        return db;
      }),
      chatSocketFactoryProvider.overrideWithValue(
        (baseUrl, sid, synotoken) => socket = FakeChatSocket(
          baseUrl: baseUrl,
          sid: sid,
          healthy: healthy,
        ),
      ),
      ...moreOverrides,
    ].cast(),
  );
  addTearDown(container.dispose);

  final ctrl = container.read(chatSessionControllerProvider.notifier);
  await ctrl.start(conn);
  return ChatHarness(container, socket, transport, api);
}

/// 直通式 E2EE 桩：文件名原样、字节原样，其余成员走 `noSuchMethod`。
///
/// **为什么需要它**：§2.0.8④ 之后，`_open` 对**非串流、非加密**文件走"内置阅读器"
/// 分支（`attachment_view.dart:387-400`）并**直接 return** —— 既不下载也不弹进度框。
/// 想测"下载 / 进度框 / 取消 / 401"这条链，必须把附件变成**加密频道**
/// （`access != null` ⇒ `encrypted = true` ⇒ 落到第 4 分支"下载后打开"）。
class PassthroughE2ee implements E2eeService {
  @override
  String? tryDecryptFileName(int channelId, String encodedName) => encodedName;

  @override
  Uint8List? tryDecryptFileBytes(int channelId, List<int> raw) =>
      raw is Uint8List ? raw : Uint8List.fromList(raw);

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
