// 实时通道 —— Engine.IO v3 / socket.io v2 客户端
//
// 协议实测（真实 NAS；原始帧见 test/fixtures/socket_frames.txt）：
//
//   → 连接 wss://<host>:<port>/sc/socket.io/?EIO=3&transport=websocket&client=mobile
//     （Cookie: id=<sid> —— 见 AccountManager.getStreamingUrlOfPostId：会话 id 存在名为 `id` 的 cookie）
//   ← 0{"sid":"...","upgrades":[],"pingInterval":25000,"pingTimeout":60000}
//   → 40                                   socket.io 命名空间连接
//   ← 40                                   命名空间连接成功
//   ← 42["client.init",{"id":"<conn_id>","version":"2.0.0"}]
//   → 42["client.initdone"]
//   ← 42["client.post.create",{"channel_id":7,"user_id":1,"data":{...}}]
//   ← 42["client.broadcast",{"type":"user.update","data":{...}}]
//
// 逆向依据：
//   data/remote/SocketHelper.java#provideSocket
//     options.path  = baseUrl.encodedPath() + "sc/socket.io"
//     options.query = "client=mobile"
//     transports    = {Polling, WebSocket}
//   SocketHelper.java#lambda$socketIO$3：收到 client.init → 存 conn_id → 回 client.initdone
//
// 底层用的是自己写的 [Eio3Client]（不是 socket_io_client）：
// 后者不给 `WebSocket.connect` 传 customClient，自签 / 主机名不匹配的 NAS 证书连不上。
// 原因与证据见 lib/src/data/remote/socket/eio3_client.dart 顶部注释。
library;

import 'dart:async';

import '../../../core/i18n/data_text.dart';
import 'eio3_client.dart';
import 'socket_events.dart';

/// 一条服务端推来的事件。
class ChatSocketEvent {
  const ChatSocketEvent(this.event, this.payload);

  final String event;

  /// 一般是 `Map`（socket.io v2 单参数）或 `List`（多参数）
  final Object? payload;

  Map<String, dynamic>? get asMap =>
      payload is Map ? Map<String, dynamic>.from(payload as Map) : null;

  @override
  String toString() => 'ChatSocketEvent($event, $payload)';
}

enum ChatSocketStatus {
  idle,
  connecting,
  connected,
  ready,
  disconnected,
  error,
}

/// 与 Chat Server 的实时连接。
///
/// 生命周期：`connect()` → 收到 `client.init` 并回 `initdone` 后进入
/// [ChatSocketStatus.ready]（此时 [connId] 可用）。
class ChatSocket {
  ChatSocket({
    required this.baseUrl,
    required this.sid,
    this.synotoken,
    this.autoReconnect = true,
    this.allowSelfSigned = true,
    this.certVerifier,
    this.connectTimeout = const Duration(seconds: 15),
  });

  /// 形如 `https://host:port/`（**根路径**，与 DSM 的 webapi 同一 baseUrl）
  final String baseUrl;

  /// 登录得到的 sid，会以 `id=<sid>` cookie 形式带上
  final String sid;

  /// 登录响应里的 synotoken（有就带）
  final String? synotoken;

  final bool autoReconnect;

  /// 自签 / 主机名不匹配的证书是否放行（见 core/net/self_signed.dart）
  final bool allowSelfSigned;

  /// ★ 证书裁决：生产的会话层必须传它（首连信任库），
  ///   否则自签/主机名不匹配就"一律放行"（见 `core/net/trust_store.dart`）。
  final bool Function(Object cert, String host, int port)? certVerifier;

  final Duration connectTimeout;

  Eio3Client? _client;
  StreamSubscription<Eio3Event>? _sub;

  final _events = StreamController<ChatSocketEvent>.broadcast();
  final _statuses = StreamController<ChatSocketStatus>.broadcast();

  ChatSocketStatus _status = ChatSocketStatus.idle;
  String? _connId;
  String? _serverVersion;
  String? _error;
  bool _closed = false;
  int _attempt = 0;
  Timer? _reconnectTimer;

  /// 服务端下发的 `client.init.id`；后续写接口（createPost 等）都要带
  String? get connId => _connId;

  /// 服务端协议版本（`client.init.version`，实测 "2.0.0"）
  String? get serverVersion => _serverVersion;

  ChatSocketStatus get status => _status;

  bool get isReady => _status == ChatSocketStatus.ready;

  String? get lastError => _error;

  Stream<ChatSocketEvent> get events => _events.stream;

  Stream<ChatSocketStatus> get statuses => _statuses.stream;

  /// `client.init` 已完成并回过 `client.initdone`
  ///
  /// 注意：**不用 completeError** —— dispose 路径没人 await 它的话会被 Dart
  /// 报成 unhandled async error。改成"正常完成 + [_readyError] 标记"，
  /// 由 [waitReady] 负责把它抛出来。
  Completer<void> _ready = Completer<void>();
  Object? _readyError;

  /// 等待握手完成（超时抛 [TimeoutException]，握手中途断线抛 [Eio3Exception]）
  Future<void> waitReady({
    Duration timeout = const Duration(seconds: 20),
  }) async {
    await _ready.future.timeout(timeout);
    final err = _readyError;
    if (err != null) throw err;
  }

  /// `/` + `sc/socket.io` —— 与 SocketHelper 的 `baseUrl.encodedPath() + "sc/socket.io"` 一致
  static String socketPathFor(String baseUrl) {
    final path = Uri.tryParse(baseUrl)?.path ?? '/';
    final base = path.endsWith('/') ? path : '$path/';
    return '${base}sc/socket.io';
  }

  Map<String, String> get cookies => {
    'id': sid,
    if (synotoken != null && synotoken!.isNotEmpty) 'synotoken': synotoken!,
  };

  String get _cookieHeader =>
      cookies.entries.map((e) => '${e.key}=${e.value}').join('; ');

  /// 建立连接。返回的 Future 在「socket 打开」时完成，握手完成看 [waitReady]。
  Future<void> connect() async {
    _reconnectTimer?.cancel();
    _closed = false;
    disposeSocketOnly(); // 结束上一轮的等待状态
    _ready = Completer<void>();
    _readyError = null;

    _setStatus(ChatSocketStatus.connecting);

    final client = Eio3Client(
      baseUrl: baseUrl,
      path: socketPathFor(baseUrl),
      // ⚠️ DSM 7.4 起实时通道也走 CSRF 校验，而且这里**只认查询串**上的
      // `SynoToken`（cookie / 头都不认）：不带就被回 `44{"code":119}`
      // （sid not found，看着像会话失效，其实是缺令牌），前端表现为一直"离线"。
      // 官方网页端就是这么干的：`query: Ext.urlEncode({SynoToken: _S("SynoToken"), …})`
      // （`webman/3rdparty/Chat/ui/synochat-common.js` 的 `SYNO.SDS.Chat.Socket.initSocket`）。
      query: {
        'client': 'mobile',
        if (synotoken != null && synotoken!.isNotEmpty) 'SynoToken': synotoken!,
      },
      headers: {'Cookie': _cookieHeader},
      allowSelfSigned: allowSelfSigned,
      certVerifier: certVerifier,
      connectTimeout: connectTimeout,
    );
    _client = client;

    client.onError = (e) {
      _error = '$e';
      _setStatus(ChatSocketStatus.error);
    };
    client.onDisconnected = () {
      if (_closed) return;
      _setStatus(ChatSocketStatus.disconnected);
      if (autoReconnect) _scheduleReconnect();
    };

    _sub = client.events.listen((e) {
      if (e.name == SocketEvent.clientInit) {
        _handleInit(e.payload);
      } else {
        _events.add(ChatSocketEvent(e.name, e.payload));
      }
    });

    await client.connect();
    _setStatus(ChatSocketStatus.connected);
    _attempt = 0;
  }

  void _scheduleReconnect() {
    if (_reconnectTimer?.isActive ?? false) return;
    _attempt++;
    // 1s 起步，最多 10s，指数退避
    final delayMs = (1000 * (1 << (_attempt - 1).clamp(0, 4))).clamp(
      1000,
      10000,
    );
    _reconnectTimer = Timer(Duration(milliseconds: delayMs), () {
      if (_closed) return;
      connect().catchError((Object e) {
        _error = '$e';
        _setStatus(ChatSocketStatus.error);
        _scheduleReconnect();
      });
    });
  }

  void _handleInit(Object? payload) {
    if (payload is! Map) return;
    final map = Map<String, dynamic>.from(payload);
    final id = map['id'] as String?;
    final version = map['version'] as String?;
    if (id == null || id.isEmpty) return;

    _connId = id;
    if (version != null && version.isNotEmpty) _serverVersion = version;

    // 对齐 SocketHelper：握手确认后立刻回 initdone
    emit(SocketEvent.clientInitDone);
    _readyError = null;
    if (!_ready.isCompleted) _ready.complete();
    _setStatus(ChatSocketStatus.ready);
  }

  /// 发送事件（socket.io v2：`42["event",payload]`）
  void emit(String event, [Object? payload]) {
    _client?.emit(event, payload);
  }

  /// `client.user.activate` / `deactivate` —— 前后台切换时告知服务端
  void setActive(bool active) => emit(
    active ? SocketEvent.clientUserActivate : SocketEvent.clientUserDeactivate,
  );

  /// 正在输入。载荷是 **thread_id**（不是 channel_id）：官方客户端恒发 0，
  /// 服务端把 typing 状态挂在 `TypingVo` 的 "0" 键下；发频道号的话别人看不到。
  void typing([int threadId = 0]) =>
      emit(SocketEvent.clientUserTyping, threadId);

  void clearTyping() => emit(SocketEvent.clientUserClearTyping);

  void _setStatus(ChatSocketStatus s) {
    if (_status == s) return;
    _status = s;
    if (!_statuses.isClosed) _statuses.add(s);
  }

  /// 断开但保留事件流（重连用）
  void disposeSocketOnly() {
    _reconnectTimer?.cancel();
    _reconnectTimer = null;
    final client = _client;
    _client = null;
    _sub?.cancel();
    _sub = null;
    client?.dispose();
    if (!_ready.isCompleted) {
      // 让等待方立刻知道断了，而不是干等到超时
      _readyError = Eio3Exception(dataText('apiSocketDisconnected', '连接已断开'));
      _ready.complete();
    }
  }

  /// 彻底销毁
  void dispose() {
    _closed = true;
    disposeSocketOnly();
    _setStatus(ChatSocketStatus.idle);
    _events.close();
    _statuses.close();
  }
}
