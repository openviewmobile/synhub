// Office C' 路线尖兵：最小协作协议客户端（自研，零第三方依赖）
//
// 目标：只用手写的 engine.io(polling + websocket 升级) 与 Socket.IO 帧编解码，
// 连上 NAS 上 Office 服务端的 `/oo/socket.io/<ns>`，跑通
//   握手 → Socket.IO connect → say_hello/ask_peers → fetch → event(step) → save
// 的最小闭环，并把**每一个原始帧**落盘作为证据。
//
// 这不是编辑器；不含 UI、不含渲染、不含 OT 完整实现。仅用于证明协议可达性与形状。
//
// 用法：
//   dart run tool/office_collab_spike/office_collab_spike.dart doc   [--step-file F]
//   dart run tool/office_collab_spike/office_collab_spike.dart sheet
//
// 配置默认从 /tmp/office-collab-spike/{meta.json,live_session.json} 读取；
// 输出默认 /tmp/office-collab-spike/evid/dart_frames_<mode>.json。
//
// 安全：会话 id 只以“前 8 位 + …”形式出现在输出中。

import 'dart:async';
import 'dart:convert';
import 'dart:io';

// ---------------------------------------------------------------------------
// ProseMirror 位置算术（Synology 的 prosemirror fork 语义）
// ---------------------------------------------------------------------------
// 该 fork 的 node size 规则（离线从 SPK 内的 server/common/prosemirror 束导出并实测）：
//   text        -> 文本长度
//   leaf 节点    -> 1            （含 settings / image / picture / hard_break …）
//   非 leaf 节点 -> sum(children) + 2
// 注意：settings 在 JSON 里没有 content，但它是 leaf 且占 1 个位置；
//       纯按标准 ProseMirror 的 “leaf => content.size + 0” 推算会得到 0，进而算错位置。
const Set<String> kLeafTypes = {
  'hard_break', 'tab', 'pseudo_list_item', 'settings', 'horizontal_rule',
  'page_break', 'image', 'chart', 'connector', 'picture', 'page_num_text',
};

int nodeSize(Map<String, dynamic> node) {
  final type = (node['type'] as String?) ?? '';
  if (type == 'text') {
    return ((node['text'] as String?) ?? '').length;
  }
  if (kLeafTypes.contains(type)) return 1;
  var total = 0;
  final children = node['content'];
  if (children is List) {
    for (final child in children) {
      total += nodeSize((child as Map).cast<String, dynamic>());
    }
  }
  return total + 2;
}

/// 在 doc JSON 中定位包含 [marker] 的第一个 text 节点，返回其**末尾**的
/// ProseMirror 绝对位置（即在该处 from==to 插入即可追加一个字符）。
int? findInsertPosAfterMarker(Map<String, dynamic> root, String marker) {
  final out = <int>[];
  final children = root['content'];
  if (children is! List) return null;
  var pos = 0; // doc 的内容从位置 0 开始（doc 自身不是内容的一部分）
  for (final child in children) {
    final map = (child as Map).cast<String, dynamic>();
    if (_walk(map, pos, marker, out)) return out.first;
    pos += nodeSize(map);
  }
  return null;
}

bool _walk(Map<String, dynamic> node, int pos, String marker, List<int> out) {
  final type = (node['type'] as String?) ?? '';
  if (type == 'text') {
    final text = (node['text'] as String?) ?? '';
    if (text.contains(marker)) {
      out.add(pos + text.length);
      return true;
    }
    return false;
  }
  if (kLeafTypes.contains(type)) return false;
  final children = node['content'];
  if (children is! List) return false;
  var p = pos + 1; // 非 leaf 节点的内容从 pos+1 开始
  for (final child in children) {
    final map = (child as Map).cast<String, dynamic>();
    if (_walk(map, p, marker, out)) return true;
    p += nodeSize(map);
  }
  return false;
}

// ---------------------------------------------------------------------------
// 原始帧日志
// ---------------------------------------------------------------------------
class RawLog {
  final List<Map<String, dynamic>> entries = [];

  int record(String dir, String transport, String raw, [String? note]) {
    final seq = entries.length + 1;
    entries.add({
      'seq': seq,
      'ts': DateTime.now().toIso8601String(),
      'dir': dir, // c2s | s2c | notice
      'transport': transport, // polling | websocket | local
      'raw': raw,
      'note': ?note,
    });
    return seq;
  }

  void note(String text) => record('notice', 'local', text);
}

String truncate(String s, [int n = 400]) =>
    s.length <= n ? s : '${s.substring(0, n)}…<${s.length - n} more bytes>';

// ---------------------------------------------------------------------------
// engine.io + Socket.IO 最小客户端
// ---------------------------------------------------------------------------
class EioSioClient {
  EioSioClient({
    required this.base,
    required this.path,
    required this.query,
    required this.headers,
    required this.log,
  }) {
    _http = HttpClient()..badCertificateCallback = (cert, host, port) => true;
    _http.connectionTimeout = const Duration(seconds: 20);
  }

  final Uri base; // e.g. https://nas.example.com:5001
  final String path; // e.g. /oo/socket.io/doc
  final Map<String, String> query;
  final Map<String, String> headers;
  final RawLog log;

  late final HttpClient _http;
  String? eioSid;
  WebSocket? _ws;
  bool _useWs = false;

  final Map<int, Completer<dynamic>> _acks = {};
  int _ackSeq = 0;

  final Completer<String> _connectDone = Completer<String>();
  final List<String> _serverEvents = [];
  final List<Map<String, dynamic>> decodedEvents = [];

  String get _queryString {
    // 只放应用层 query；EIO/transport 由各 transport 的 URL 自己拼，
    // 否则 http_build_query 语义下 EIO 会变成数组 -> engine.io 回
    // {"code":5,"message":"Unsupported protocol version"}。
    return query.entries
        .map((e) => '${Uri.encodeQueryComponent(e.key)}=${Uri.encodeQueryComponent(e.value)}')
        .join('&');
  }

  String get _pathPrefix => path.endsWith('/') ? path.substring(0, path.length - 1) : path;

  // --- polling ---
  Future<String> _pollGet(String extraQuery) async {
    final uri = Uri.parse(
        '${base.scheme}://${base.authority}$_pathPrefix/?EIO=4&transport=polling&$extraQuery');
    final req = await _http.getUrl(uri);
    req.headers.set('Cookie', headers['Cookie']!);
    if (headers.containsKey('X-SYNO-TOKEN')) {
      req.headers.set('X-SYNO-TOKEN', headers['X-SYNO-TOKEN']!);
    }
    req.headers.set('Accept', '*/*');
    final res = await req.close().timeout(const Duration(seconds: 60));
    final body = await res.transform(utf8.decoder).join();
    log.record('notice', 'polling', 'HTTP ${res.statusCode} GET $uri  ->  ${truncate(body)}');
    return body;
  }

  Future<void> _pollPost(String body) async {
    final uri = Uri.parse(
        '${base.scheme}://${base.authority}$_pathPrefix/?EIO=4&transport=polling&sid=$eioSid');
    final req = await _http.postUrl(uri);
    req.headers.set('Cookie', headers['Cookie']!);
    if (headers.containsKey('X-SYNO-TOKEN')) {
      req.headers.set('X-SYNO-TOKEN', headers['X-SYNO-TOKEN']!);
    }
    req.headers.contentType = ContentType('text', 'plain', charset: 'UTF-8');
    req.add(utf8.encode(body));
    final res = await req.close().timeout(const Duration(seconds: 60));
    final txt = await res.transform(utf8.decoder).join();
    log.record('notice', 'polling', 'HTTP ${res.statusCode} POST $uri  body=${truncate(body, 200)} -> ${truncate(txt, 200)}');
  }

  /// engine.io 握手（polling），返回 eio sid。
  Future<String> handshake() async {
    final body = await _pollGet(_queryString);
    // 可能含多个包，用 \x1e 分隔
    for (final packet in body.split('\u001e')) {
      if (packet.isEmpty) continue;
      log.record('s2c', 'polling', packet, 'engine.io packet');
      if (packet[0] == '0') {
        final hs = jsonDecode(packet.substring(1)) as Map<String, dynamic>;
        eioSid = hs['sid'] as String;
      }
    }
    if (eioSid == null) {
      throw StateError('engine.io handshake failed: ${truncate(body)}');
    }
    return eioSid!;
  }

  /// 发 Socket.IO CONNECT（默认命名空间），并等回 `40{...}`。
  /// 必须走**当前活跃**的 transport：升级到 websocket 后再用 polling 发 `40`
  /// 会被 engine.io 拒为 {"code":3,"message":"Bad request"}（polling 已被关闭）。
  Future<String> connectNamespace() async {
    const frame = '40';
    log.record('c2s', _useWs ? 'websocket' : 'polling', frame, 'socket.io CONNECT (default namespace)');
    _sendRaw(frame);
    return await _connectDone.future.timeout(const Duration(seconds: 60));
  }

  /// engine.io websocket 升级：2probe → 3probe → 5。
  /// 返回 true 表示升级成功并已在 websocket 上工作。
  /// 注意：升级探测失败后**必须重开 engine.io 会话**——实测在探测阶段关掉 ws，
  /// 服务端会把整个 engine.io session 一起销毁（后续 polling 会回
  /// {"code":1,"message":"Session ID unknown"}）。
  Future<bool> upgradeToWebSocket() async {
    final wsScheme = base.scheme == 'https' ? 'wss' : 'ws';
    final uri = Uri.parse(
        '$wsScheme://${base.authority}$_pathPrefix/?EIO=4&transport=websocket&sid=$eioSid&$_queryString');
    final ws = await WebSocket.connect(
      uri.toString(),
      headers: headers,
      customClient: _http,
      compression: CompressionOptions.compressionOff,
    );
    _ws = ws;
    log.record('notice', 'websocket', 'WS upgraded $uri');

    ws.listen((dynamic msg) {
      final text = msg is String ? msg : '(binary ${msg.length})';
      _onEnginePacket(text, 'websocket');
    }, onError: (Object e) {
      log.record('notice', 'websocket', 'WS error: $e');
    }, onDone: () {
      log.record('notice', 'websocket', 'WS closed');
    });

    ws.add('2probe');
    log.record('c2s', 'websocket', '2probe', 'engine.io probe');
    // 等 3probe
    final probeDeadline = DateTime.now().add(const Duration(seconds: 20));
    while (_probeSeen != true && DateTime.now().isBefore(probeDeadline)) {
      await Future<void>.delayed(const Duration(milliseconds: 120));
    }
    if (_probeSeen != true) {
      log.record('notice', 'websocket', 'no 3probe within 20s; abandoning websocket');
      await ws.close();
      _ws = null;
      return false;
    }
    ws.add('5');
    log.record('c2s', 'websocket', '5', 'engine.io UPGRADE');
    _useWs = true;
    return true;
  }

  bool? _probeSeen;

  void _onEnginePacket(String packet, String transport) {
    if (packet.isEmpty) return;
    log.record('s2c', transport, packet, 'engine.io packet');
    switch (packet[0]) {
      case '0':
        // 新 transport 的 open（fresh ws 才有）
        break;
      case '1':
        break;
      case '2': // ping -> pong
        _sendRaw('3');
        break;
      case '3': // pong (含 probe 响应 `3probe`)
        if (packet.startsWith('3probe')) _probeSeen = true;
        break;
      case '4': // message -> socket.io
        _onSioPacket(packet.substring(1));
        break;
      case '5':
        break;
      case '6':
        break;
    }
  }

  void _onSioPacket(String p) {
    if (p.isEmpty) return;
    final type = int.tryParse(p[0]) ?? -1;
    var i = 1;
    String? ns;
    if (i < p.length && p[i] == '/') {
      final comma = p.indexOf(',', i);
      if (comma != -1) {
        ns = p.substring(i, comma);
        i = comma + 1;
      }
    }
    var idStr = '';
    while (i < p.length && p.codeUnitAt(i) >= 48 && p.codeUnitAt(i) <= 57) {
      idStr += p[i];
      i++;
    }
    final payload = i < p.length ? p.substring(i) : '';
    switch (type) {
      case 0: // CONNECT
        if (!_connectDone.isCompleted) _connectDone.complete(payload);
        break;
      case 1: // DISCONNECT
        break;
      case 2: // EVENT
        _serverEvents.add(payload);
        try {
          final decoded = jsonDecode(payload);
          if (decoded is List && decoded.isNotEmpty) {
            decodedEvents.add({
              'name': decoded[0],
              if (decoded.length > 1) 'args': decoded.sublist(1),
            });
          }
        } catch (_) {}
        break;
      case 3: // ACK
        final id = int.tryParse(idStr);
        if (id != null && _acks.containsKey(id)) {
          final c = _acks.remove(id)!;
          if (!c.isCompleted) {
            c.complete(payload.isEmpty ? null : jsonDecode(payload));
          }
        }
        break;
      case 4: // CONNECT_ERROR
        if (!_connectDone.isCompleted) _connectDone.completeError(StateError(payload));
        break;
    }
  }

  void _sendRaw(String frame) {
    if (_useWs && _ws != null) {
      _ws!.add(frame);
    } else {
      unawaited(_pollPost(frame));
    }
  }

  /// 发一条 Socket.IO EVENT 并等待 ACK（返回解析后的 payload）。
  Future<dynamic> emit(String event, [dynamic data, Duration timeout = const Duration(seconds: 60)]) async {
    final id = ++_ackSeq;
    final completer = Completer<dynamic>();
    _acks[id] = completer;
    final arr = <dynamic>[event, ?data];
    final frame = '42$id${jsonEncode(arr)}';
    log.record('c2s', _useWs ? 'websocket' : 'polling', frame, 'socket.io EVENT+ACK $event');
    _sendRaw(frame);
    try {
      return await completer.future.timeout(timeout);
    } on TimeoutException {
      _acks.remove(id);
      log.note('ACK timeout for $event (id=$id)');
      return {'__timeout__': true};
    }
  }

  List<String> get serverEvents => List.unmodifiable(_serverEvents);

  /// 等待服务端推送的某个事件（如 `ready`）。
  /// 实测：服务端在 `onConnect` 完成后才注册事件监听并 emit `ready`；
  /// 在此之前的 C→S 事件会被**静默丢弃**（不排队、不回 ack）。
  Future<bool> waitForServerEvent(String name,
      {Duration timeout = const Duration(seconds: 90)}) async {
    final deadline = DateTime.now().add(timeout);
    while (DateTime.now().isBefore(deadline)) {
      if (decodedEvents.any((e) => e['name'] == name)) return true;
      await Future<void>.delayed(const Duration(milliseconds: 150));
    }
    return false;
  }

  Future<void> close() async {
    try {
      _ws?.add('41');
    } catch (_) {}
    await _ws?.close();
    _http.close(force: true);
  }
}

// ---------------------------------------------------------------------------
// main
// ---------------------------------------------------------------------------
Future<void> main(List<String> argv) async {
  final mode = argv.isNotEmpty && !argv.first.startsWith('-') ? argv.first : 'doc';
  final stepFile = _argValue(argv, '--step-file');
  final noWrite = argv.contains('--no-write');
  final spikeDir = _argValue(argv, '--spike-dir') ?? '/tmp/office-collab-spike';

  final meta = jsonDecode(File('$spikeDir/meta.json').readAsStringSync()) as Map<String, dynamic>;
  final session = jsonDecode(File('/tmp/live_session.json').readAsStringSync()) as Map<String, dynamic>;
  final baseUrl = (meta['base_url'] as String?) ?? (session['base'] as String);
  final sid = session['sid'] as String;
  final base = Uri.parse(baseUrl);

  final target = (mode == 'sheet' ? meta['sheet'] : meta['doc']) as Map<String, dynamic>;
  final linkId = target['link_id'] as String;
  final objectId = target['object_id'] as String;
  final ns = mode == 'sheet' ? 'sheet' : 'doc';

  final log = RawLog();
  final sidPrefix = '${sid.substring(0, 8)}…';
  log.note('mode=$mode base=$baseUrl sid(cookie id)=$sidPrefix ns=$ns '
      'objectId=$objectId linkId=$linkId path=/oo/socket.io/$ns');

  stdout.writeln('== Office C\' spike ($mode) ==');
  stdout.writeln('target: ${target['path']}  object_id=$objectId  link_id=$linkId  ntype=${target['ntype']}');
  stdout.writeln('ckpt: cookie id=$sidPrefix (full sid never printed)');

  final client = EioSioClient(
    base: base,
    path: '/oo/socket.io/$ns',
    // 实测（SYNO.Office.Permission:check 直接探针）：
    //   objectId 必须是 Office 的 object_id（1028_xxx.doc / .sh / .slide）
    //   linkId   必须是 Drive 的 permanent_link
    // 传反（objectId=permanent_link）时 Permission:check 会静默回
    //   {readable:false,writable:false,...} -> socket.io 立刻 "Permission denied"。
    query: {
      'objectId': objectId,
      'linkId': linkId,
    },
    headers: {
      'Cookie': 'id=$sid',
      'X-SYNO-TOKEN': '',
      'User-Agent': 'DSH-OfficeCollabSpike/0.1 (dart)',
      'Origin': '$baseUrl',
    },
    log: log,
  );

  final out = <String, dynamic>{'mode': mode, 'target': target, 'steps': {}};

  try {
    // 1) engine.io 握手
    String eioSid = await client.handshake();
    out['steps']['handshake'] = {
      'ok': true,
      'eio_sid_prefix': '${eioSid.substring(0, 8)}…',
    };
    stdout.writeln('[1] engine.io handshake OK  eio_sid=${eioSid.substring(0, 8)}…');

    // 2) websocket 升级（先升级再 connect；失败则重开会话，绝不复用被销毁的会话）
    try {
      final upgraded = await client.upgradeToWebSocket().timeout(const Duration(seconds: 40));
      out['steps']['upgrade'] = {'ok': upgraded};
      stdout.writeln('[2] websocket upgrade ${upgraded ? "OK (transport=websocket)" : "FAILED -> re-handshake on polling"}');
      if (!upgraded) {
        eioSid = await client.handshake();
        log.note('re-handshake after failed upgrade; new eio_sid=${eioSid.substring(0, 8)}…');
      }
    } catch (e) {
      out['steps']['upgrade'] = {'ok': false, 'error': '$e'};
      stdout.writeln('[2] websocket upgrade error: $e');
      eioSid = await client.handshake();
    }

    // 3) Socket.IO CONNECT（默认命名空间；命名空间由 URL 路径区分）
    String connectAck = '';
    String connectErr = '';
    try {
      connectAck = await client.connectNamespace().timeout(const Duration(seconds: 60));
      out['steps']['connect'] = {'ok': true, 'ack': connectAck};
      stdout.writeln('[3] Socket.IO connect OK  ack=${truncate(connectAck, 120)}');
    } catch (e) {
      connectErr = '$e';
      out['steps']['connect'] = {'ok': false, 'error': connectErr};
      stdout.writeln('[3] Socket.IO connect FAILED: $e');
    }

    if (connectErr.isNotEmpty) {
      // 命名空间未连上时继续 emit 没有意义（服务端不会派发到未鉴权的 socket）。
      stdout.writeln('[!] skipping all events because namespace connect failed');
    } else {
      // 关键门禁：等 `ready`。
      // 服务端 onConnect 是异步的（要从 Drive 载入文档、建 ProseMirror 实例），
      // 期间 Client 的事件监听尚未注册 —— 此时发的事件会被**静默丢弃**
      // （既不入队也不回 ack）。官方客户端等 `ready` 之后再发第一帧。
      final ready = await client.waitForServerEvent('ready',
          timeout: Duration(seconds: mode == 'sheet' ? 90 : 120));
      out['steps']['wait_ready'] = {'ok': ready};
      stdout.writeln('[4] server "ready" received = $ready');

      if (mode == 'sheet') {
        // sheet：只做握手 + init + peek，不发任何写命令
        final initAck = await client.emit('init');
        out['steps']['init'] = {'ack': initAck};
        stdout.writeln('[sheet] init ack = ${truncate(jsonEncode(initAck), 900)}');

        final peekAck = await client.emit('peek');
        out['steps']['peek'] = {'ack': peekAck};
        stdout.writeln('[sheet] peek ack = ${truncate(jsonEncode(peekAck), 300)}');
      } else {
        // doc：say_hello / ask_peers / fetch / event / save / poll
        final helloAck = await client.emit('say_hello');
        out['steps']['say_hello'] = {'ack': helloAck};
        stdout.writeln('[5] say_hello ack = ${truncate(jsonEncode(helloAck), 300)}');

        await Future<void>.delayed(const Duration(milliseconds: 400));

        final peersAck = await client.emit('ask_peers');
        out['steps']['ask_peers'] = {'ack': peersAck};
        stdout.writeln('[6] ask_peers ack = ${truncate(jsonEncode(peersAck), 400)}');

        final fetchAck = await client.emit('fetch');
        out['steps']['fetch'] = {'ack': fetchAck};
        // socket.io ack 参数是“参数列表”：服务端 cb(null, data) -> [null, data]
        final docWrapper = _ackPayload(fetchAck);
        Map<String, dynamic>? fetched;
        if (docWrapper is Map && docWrapper['doc'] is Map) {
          fetched = (docWrapper['doc'] as Map).cast<String, dynamic>();
        }
        final data = fetched?['data'];
        if (data is Map) {
          final dataMap = data.cast<String, dynamic>();
          out['steps']['fetch']['doc_version'] = fetched?['version'];
          out['steps']['fetch']['doc_top_types'] =
              ((dataMap['content'] as List?) ?? const [])
                  .map((c) => ((c as Map)['type'] ?? '?'))
                  .toList();
          File('$spikeDir/evid/dart_fetched_doc.json')
              .writeAsStringSync(const JsonEncoder.withIndent(' ').convert(dataMap));
          stdout.writeln('[7] fetch OK  version=${fetched?['version']} '
              'top_types=${out['steps']['fetch']['doc_top_types']}');
        } else {
          stdout.writeln('[7] fetch returned no doc: ${truncate(jsonEncode(fetchAck), 400)}');
        }

        // 8) event：最小 step
        if (data is Map && mode == 'docneg') {
          // 故意两次**负向**探针，用来取错误码原文（不动状态、不 save）：
          //   (a) version 错 -> 期望 ERR_VERSION_NOT_CURRENT(402)
          //   (b) stepType 未知 -> 期望 ERR_INVALID_COMMAND(411)
          final version = fetched?['version'] as int? ?? 0;
          final badVersion = await client.emit('event', {
            'version': version + 5,
            'steps': [
              {
                'stepType': 'replace',
                'from': 37,
                'to': 37,
                'slice': {
                  'content': [
                    {'type': 'text', 'text': 'X'}
                  ],
                  'openLeft': 0,
                  'openRight': 0,
                },
                'structure': false,
              }
            ],
            'clientId': 'spikedart01',
            'selection': null,
          });
          out['steps']['event_bad_version'] = {'sent_version': version + 5, 'ack': badVersion};
          stdout.writeln('[8a] event(bad version) ack = ${truncate(jsonEncode(badVersion), 400)}');

          final badStep = await client.emit('event', {
            'version': version,
            'steps': [
              {'stepType': 'dsh_bogus_step', 'from': 0, 'to': 0}
            ],
            'clientId': 'spikedart01',
            'selection': null,
          });
          out['steps']['event_bad_step'] = {'ack': badStep};
          stdout.writeln('[8b] event(bogus stepType) ack = ${truncate(jsonEncode(badStep), 400)}');

          final refetch = await client.emit('fetch');
          final refData = _ackPayload(refetch);
          out['steps']['refetch_after_negative'] = {
            'version': (refData is Map && refData['doc'] is Map)
                ? (refData['doc'] as Map)['version']
                : null,
            'ack': null,
          };
          stdout.writeln('[8c] refetch after negative probes version = '
              '${out['steps']['refetch_after_negative']['version']} (expect unchanged $version)');
        } else if (data is Map && noWrite) {
          stdout.writeln('[8] --no-write: skipping event/save/poll');
          log.note('--no-write: fetch-only run');
        } else if (data is Map) {
          final dataMap = data.cast<String, dynamic>();
          Map<String, dynamic>? step;
          String stepSource;
          if (stepFile != null && File(stepFile).existsSync()) {
            final planned = jsonDecode(File(stepFile).readAsStringSync()) as Map<String, dynamic>;
            step = (planned['step'] as Map).cast<String, dynamic>();
            stepSource = 'offline-computed from the real schema (SPK prosemirror bundle)';
            log.note('step loaded from $stepFile ($stepSource)');
          } else {
            final pos = findInsertPosAfterMarker(dataMap, 'C3SPIKE-DOC-BASE');
            step = pos == null
                ? null
                : {
                    'stepType': 'replace',
                    'from': pos,
                    'to': pos,
                    'slice': {
                      'content': [
                        {'type': 'text', 'text': '#'}
                      ],
                      'openLeft': 0,
                      'openRight': 0,
                    },
                    'structure': false,
                  };
            stepSource = 'computed in-client by node-size arithmetic';
            log.note('$stepSource, insert pos=$pos');
          }
          if (step == null) {
            stdout.writeln('[8] could not compute a step (marker not found)');
          } else {
            final version = fetched?['version'];
            final eventAck = await client.emit('event', {
              'version': version,
              'steps': [step],
              'clientId': 'spikedart01',
              'selection': null,
            });
            out['steps']['event'] = {
              'step': step,
              'step_source': stepSource,
              'version': version,
              'ack': eventAck,
            };
            stdout.writeln('[8] event(step) ack = ${truncate(jsonEncode(eventAck), 700)}');

            // 9) save
            final saveAck = await client.emit('save', <String, dynamic>{});
            out['steps']['save'] = {'ack': saveAck};
            stdout.writeln('[9] save ack = ${truncate(jsonEncode(saveAck), 400)}');

            // 10) poll：记录服务端增量广播的形状
            final pollAck = await client.emit('poll', {'version': version});
            out['steps']['poll'] = {'ack': pollAck};
            stdout.writeln('[10] poll ack = ${truncate(jsonEncode(pollAck), 400)}');
          }
        }
      }
    }

    await Future<void>.delayed(const Duration(seconds: 3));
    out['server_events'] = client.serverEvents;
    out['server_events_decoded'] = client.decodedEvents;
    stdout.writeln('server-pushed events: ${client.serverEvents.length} '
        '(${client.decodedEvents.map((e) => e['name']).join(', ')})');
  } catch (e, st) {
    out['fatal'] = '$e\n$st';
    stdout.writeln('FATAL: $e');
  } finally {
    await client.close();
  }

  out['frames'] = log.entries;
  final outPath = '$spikeDir/evid/dart_frames_$mode.json';
  File(outPath).writeAsStringSync(const JsonEncoder.withIndent(' ').convert(out));
  stdout.writeln('frames(${log.entries.length}) -> $outPath');
}

String? _argValue(List<String> argv, String name) {
  final i = argv.indexOf(name);
  if (i == -1 || i + 1 >= argv.length) return null;
  return argv[i + 1];
}

/// Socket.IO ack 的参数是**位置参数列表**：服务端 `cb(null, data)` → `[null, data]`。
/// 返回“最后一个非 null 参数”，即真正的业务载荷。
dynamic _ackPayload(dynamic ack) {
  if (ack is! List || ack.isEmpty) return ack;
  for (var i = ack.length - 1; i >= 0; i--) {
    if (ack[i] != null) return ack[i];
  }
  return ack.last;
}
