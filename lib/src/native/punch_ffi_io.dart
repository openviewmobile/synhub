// libsynochatpunch 的 Dart FFI 绑定 —— **真实实现**（非 web 平台）。
//
// ★ 外部一律 `import '../native/punch_ffi.dart'`（门面），不要再直接引本文件：
//   web 上是 `punch_ffi_stub.dart` 顶替（第 334 轮，见门面文件头的说明）。
//
// 原文件头（保留）：
//
// 原生库由 reimpl/ 用自有 C++ 构建（见 reimpl/README.md），
// 不含 Synology 任何专有二进制；UDT 传输用开源 udt4。
//
// 用法：
//   final punch = SynoPunch.load();
//   punch.serverId = 'my-qc-id';
//   punch.serviceType = SynoServiceType.dsmHttps;
//   for (final s in echoServers) punch.addEchoServer(s.host, s.port);
//   if (await punch.start() == SynoPunchError.ok) {
//     final url = 'https://127.0.0.1:${punch.tcpPort}/';   // 交给 HTTP 栈
//   }
library;

import 'dart:ffi' as ffi;
import 'dart:io';

import 'package:ffi/ffi.dart';

// ---------------------------------------------------------------- C 结构
final class _SynoPunchHandle extends ffi.Opaque {}

// ---------------------------------------------------------------- 原生签名
typedef _NewC = ffi.Pointer<_SynoPunchHandle> Function();
typedef _NewDart = ffi.Pointer<_SynoPunchHandle> Function();

typedef _FreeC = ffi.Void Function(ffi.Pointer<_SynoPunchHandle>);
typedef _FreeDart = void Function(ffi.Pointer<_SynoPunchHandle>);

typedef _SetStrC =
    ffi.Void Function(ffi.Pointer<_SynoPunchHandle>, ffi.Pointer<Utf8>);
typedef _SetStrDart =
    void Function(ffi.Pointer<_SynoPunchHandle>, ffi.Pointer<Utf8>);

typedef _SetIntC = ffi.Void Function(ffi.Pointer<_SynoPunchHandle>, ffi.Int32);
typedef _SetIntDart = void Function(ffi.Pointer<_SynoPunchHandle>, int);

typedef _AddEchoC =
    ffi.Void Function(
      ffi.Pointer<_SynoPunchHandle>,
      ffi.Pointer<Utf8>,
      ffi.Int32,
    );
typedef _AddEchoDart =
    void Function(ffi.Pointer<_SynoPunchHandle>, ffi.Pointer<Utf8>, int);

typedef _StartC = ffi.Int32 Function(ffi.Pointer<_SynoPunchHandle>);
typedef _StartDart = int Function(ffi.Pointer<_SynoPunchHandle>);

typedef _PollC = ffi.Int32 Function(ffi.Pointer<_SynoPunchHandle>, ffi.Int32);
typedef _PollDart = int Function(ffi.Pointer<_SynoPunchHandle>, int);

typedef _VoidC = ffi.Void Function(ffi.Pointer<_SynoPunchHandle>);
typedef _VoidDart = void Function(ffi.Pointer<_SynoPunchHandle>);

typedef _IntC = ffi.Int32 Function(ffi.Pointer<_SynoPunchHandle>);
typedef _IntDart = int Function(ffi.Pointer<_SynoPunchHandle>);

typedef _StrC = ffi.Pointer<Utf8> Function(ffi.Pointer<_SynoPunchHandle>);
typedef _StrDart = ffi.Pointer<Utf8> Function(ffi.Pointer<_SynoPunchHandle>);

typedef _U64C = ffi.Uint64 Function(ffi.Pointer<_SynoPunchHandle>);
typedef _U64Dart = int Function(ffi.Pointer<_SynoPunchHandle>);

// ---------------------------------------------------------------- 原生库
class _Native {
  // 注意：不需要保存 DynamicLibrary 引用 —— lookupFunction 返回的函数指针
  // 在库被 GC 前一直有效，而 Dart 会保持它存活。
  _Native(ffi.DynamicLibrary lib)
    : newHandle = lib.lookupFunction<_NewC, _NewDart>('synopunch_new'),
      free = lib.lookupFunction<_FreeC, _FreeDart>('synopunch_free'),
      setServerId = lib.lookupFunction<_SetStrC, _SetStrDart>(
        'synopunch_set_server_id',
      ),
      setServiceType = lib.lookupFunction<_SetIntC, _SetIntDart>(
        'synopunch_set_service_type',
      ),
      addEchoServer = lib.lookupFunction<_AddEchoC, _AddEchoDart>(
        'synopunch_add_echo_server',
      ),
      clearEchoServers = lib.lookupFunction<_VoidC, _VoidDart>(
        'synopunch_clear_echo_servers',
      ),
      setUdtTxMss = lib.lookupFunction<_SetIntC, _SetIntDart>(
        'synopunch_set_udt_tx_mss',
      ),
      setCandidate = lib.lookupFunction<_AddEchoC, _AddEchoDart>(
        'synopunch_set_candidate',
      ),
      clearCandidate = lib.lookupFunction<_VoidC, _VoidDart>(
        'synopunch_clear_candidate',
      ),
      setRendezvous = lib.lookupFunction<_SetIntC, _SetIntDart>(
        'synopunch_set_rendezvous',
      ),
      setLocalServicePort = lib.lookupFunction<_SetIntC, _SetIntDart>(
        'synopunch_set_local_service_port',
      ),
      setPunchTimeout = lib.lookupFunction<_SetIntC, _SetIntDart>(
        'synopunch_set_punch_timeout',
      ),
      setConnectTimeout = lib.lookupFunction<_SetIntC, _SetIntDart>(
        'synopunch_set_connect_timeout',
      ),
      start = lib.lookupFunction<_StartC, _StartDart>('synopunch_start'),
      // r684：分段接口（同步/阻塞语义与 start 相同，只是拆成三段）
      prepare = lib.lookupFunction<_StartC, _StartDart>('synopunch_prepare'),
      udtPort = lib.lookupFunction<_StartC, _StartDart>('synopunch_udt_port'),
      awaitPeer = lib.lookupFunction<_StartC, _StartDart>('synopunch_await_peer'),
      startEngine = lib.lookupFunction<_StartC, _StartDart>(
        'synopunch_start_engine',
      ),
      tcpPort = lib.lookupFunction<_IntC, _IntDart>('synopunch_tcp_port'),
      poll = lib.lookupFunction<_PollC, _PollDart>('synopunch_poll'),
      stop = lib.lookupFunction<_VoidC, _VoidDart>('synopunch_stop'),
      isRunning = lib.lookupFunction<_IntC, _IntDart>('synopunch_is_running'),
      lastError = lib.lookupFunction<_StrC, _StrDart>('synopunch_last_error'),
      rxBytes = lib.lookupFunction<_U64C, _U64Dart>('synopunch_rx_bytes'),
      txBytes = lib.lookupFunction<_U64C, _U64Dart>('synopunch_tx_bytes');
  final _NewDart newHandle;
  final _FreeDart free;
  final _SetStrDart setServerId;
  final _SetIntDart setServiceType;
  final _AddEchoDart addEchoServer;
  final _VoidDart clearEchoServers;
  final _SetIntDart setUdtTxMss;
  final _AddEchoDart setCandidate;
  final _VoidDart clearCandidate;
  final _SetIntDart setRendezvous;
  final _SetIntDart setLocalServicePort;
  final _SetIntDart setPunchTimeout;
  final _SetIntDart setConnectTimeout;
  final _StartDart start;
  final _StartDart prepare;
  final _StartDart udtPort;
  final _StartDart awaitPeer;
  final _StartDart startEngine;
  final _IntDart tcpPort;
  final _PollDart poll;
  final _VoidDart stop;
  final _IntDart isRunning;
  final _StrDart lastError;
  final _U64Dart rxBytes;
  final _U64Dart txBytes;
}

// ---------------------------------------------------------------- 常量
/// SERVICE_ID，与原库 `PunchInfo.SERVICE_TYPE_*` 一致
class SynoServiceType {
  static const int noOp = 0;
  static const int dsm = 1;
  static const int dsmHttps = 2; // Synology Chat 用这个
  static const int http = 3;
  static const int https = 4;
  static const int webdav = 5;
  static const int webdavHttps = 6;
  static const int cloudStation = 7;
  static const int vpnPlus = 8;
  static const int beeDriveHttps = 9;
  static const int bsmHttp = 10;
  static const int bsmHttps = 11;
}

/// 与 C 侧 `TunnelError` 一一对应
class SynoPunchError {
  static const int ok = 0;
  static const int earlyExit = 1;
  static const int listenSocket = 3;
  static const int udpPort = 5;
  static const int punchFailed = 6;
  static const int udtChannel = 7;
  static const int udtConnect = 8;
  static const int udtListen = 9;
  static const int acceptFailed = 10;
  static const int engineStart = 12;

  static String name(int code) => switch (code) {
    ok => 'Ok',
    earlyExit => 'EarlyExit',
    listenSocket => 'ListenSocket',
    udpPort => 'UdpPort',
    punchFailed => 'PunchFailed',
    udtChannel => 'UdtChannel',
    udtConnect => 'UdtConnect',
    udtListen => 'UdtListen',
    acceptFailed => 'AcceptFailed',
    engineStart => 'EngineStart',
    _ => 'Unknown($code)',
  };
}

/// echo / relay 服务器地址
class SynoEchoServer {
  const SynoEchoServer(this.host, this.port);
  final String host;
  final int port;

  @override
  String toString() => '$host:$port';
}

// ---------------------------------------------------------------- 封装
/// 空洞穿透隧道的 Dart 侧句柄。
///
/// 生命周期：`SynoPunch.load()` → 配置 → `start()` → 用 [tcpPort] 发 HTTP →
/// 期间周期性调用 [pump] → `dispose()`。
class SynoPunch {
  SynoPunch._(this._native) {
    _handle = _native.newHandle();
    if (_handle == ffi.nullptr) {
      throw StateError('synopunch_new() 返回空指针');
    }
  }

  /// 按平台加载共享库。
  ///
  /// Android 上库放在 `jniLibs/<abi>/libsynochatpunch.so`，随 APK 打包，
  /// 因此只给文件名即可（由 linker 解析）。
  factory SynoPunch.load({String? libraryPath}) {
    final lib = _openLibrary(libraryPath);
    return SynoPunch._(_Native(lib));
  }

  /// 真正打开库的地方。
  ///
  /// ★ r683（iOS）：iOS **不能**随 App 带 dylib（要签名/嵌入），所以
  /// `ios/lib/libsynochatpunch.a` 是以**静态库**形式经 `-force_load` 链进 Runner 的；
  /// 此时没有"库文件"可 `open`，Dart FFI 要用 `DynamicLibrary.process()` 在
  /// 主可执行映像里找符号（与 `--allow-...` 无关，符号在就行）。
  /// 显示名仍按平台给（诊断页要显示"期望的文件名"）。
  static ffi.DynamicLibrary _openLibrary(String? libraryPath) {
    if (libraryPath != null) return ffi.DynamicLibrary.open(libraryPath);
    if (Platform.isIOS) return ffi.DynamicLibrary.process();
    return ffi.DynamicLibrary.open(defaultLibraryName());
  }

  /// 各平台的默认库名（iOS 是静态链接，名字只用于显示/诊断）
  static String defaultLibraryName() {
    if (Platform.isAndroid) return 'libsynochatpunch.so';
    if (Platform.isIOS) return 'libsynochatpunch.a (static, process)';
    if (Platform.isMacOS) return 'libsynochatpunch.dylib';
    if (Platform.isLinux) return 'libsynochatpunch.so';
    if (Platform.isWindows) return 'synochatpunch.dll';
    throw UnsupportedError('不支持的平台: ${Platform.operatingSystem}');
  }

  final _Native _native;
  late final ffi.Pointer<_SynoPunchHandle> _handle;
  bool _disposed = false;

  void _check() {
    if (_disposed) throw StateError('SynoPunch 已释放');
  }

  // ------------------------------------------------------------ 配置
  /// QuickConnect ID，作为打洞命令的载荷
  set serverId(String v) {
    _check();
    final p = v.toNativeUtf8();
    try {
      _native.setServerId(_handle, p);
    } finally {
      malloc.free(p);
    }
  }

  /// SERVICE_ID，见 [SynoServiceType]。超出 [1,11] 会被原生层归零
  set serviceType(int v) {
    _check();
    _native.setServiceType(_handle, v);
  }

  void addEchoServer(String host, int port) {
    _check();
    final p = host.toNativeUtf8();
    try {
      _native.addEchoServer(_handle, p, port);
    } finally {
      malloc.free(p);
    }
  }

  void addEchoServers(Iterable<SynoEchoServer> servers) {
    for (final s in servers) {
      addEchoServer(s.host, s.port);
    }
  }

  void clearEchoServers() {
    _check();
    _native.clearEchoServers(_handle);
  }

  /// echo list 响应里的 `udt_tx_mss`，决定隧道单包上限（≤ 1400）
  set udtTxMss(int v) {
    _check();
    _native.setUdtTxMss(_handle, v);
  }

  /// 候选对端地址。设置后进入主动分支
  void setCandidate(String host, int port) {
    _check();
    final p = host.toNativeUtf8();
    try {
      _native.setCandidate(_handle, p, port);
    } finally {
      malloc.free(p);
    }
  }

  void clearCandidate() {
    _check();
    _native.clearCandidate(_handle);
  }

  /// rendezvous 建链开关。
  ///
  /// 原库主动分支用 `create_udt_channel_socket`（带 `UDT_RENDEZVOUS`），
  /// 实测**要求双方都处于 rendezvous 模式**；与纯 listener 对接时置 false。
  set rendezvous(bool v) {
    _check();
    _native.setRendezvous(_handle, v ? 1 : 0);
  }

  /// 收到对端 OPEN 时拨号的本地服务端口（0 = 不拨号，纯客户端半边）
  set localServicePort(int v) {
    _check();
    _native.setLocalServicePort(_handle, v);
  }

  set punchTimeoutMs(int v) {
    _check();
    _native.setPunchTimeout(_handle, v);
  }

  set connectTimeoutMs(int v) {
    _check();
    _native.setConnectTimeout(_handle, v);
  }

  // ------------------------------------------------------------ 运行
  /// 打洞 + 建链 + 启动中继。**阻塞**，应在 isolate 或 `compute` 中调用。
  /// 返回 [SynoPunchError] 中的码。
  int start() {
    _check();
    return _native.start(_handle);
  }

  // ------------------------------------------------------------ 分段接口（r684）
  //
  // 生产路径用 [start] 一步到位。这三段是给"两侧都在本进程"的回环装置用的
  // （模拟器/宿主单测）：被动方要先 `prepare()` 拿到 UDT 端口告诉对端，
  // 再 `awaitPeer()`（阻塞等接入），最后 `startEngine()`。

  /// 阶段①：打洞 + 准备 UDT 套接字。返回 [SynoPunchError] 的码。
  int prepare() => _disposed ? -1 : _native.prepare(_handle);

  /// 阶段①之后被动方的 UDT 监听端口（要对端知道才能连）；其余情形 0。
  int get udtPort => _disposed ? 0 : _native.udtPort(_handle);

  /// 阶段②：等建链完成。**阻塞**（发起方 connect / 被动方 accept）。
  int awaitPeer() => _disposed ? -1 : _native.awaitPeer(_handle);

  /// 阶段③：起中继引擎（之后 [tcpPort] 才有效）。
  int startEngine() => _disposed ? -1 : _native.startEngine(_handle);

  /// 本地 TCP 监听端口。把它接到 `https://127.0.0.1:<port>/` 即可。
  /// 未启动返回 0。
  int get tcpPort {
    if (_disposed) return 0;
    return _native.tcpPort(_handle);
  }

  /// 是否已建立隧道
  bool get isRunning {
    if (_disposed) return false;
    return _native.isRunning(_handle) != 0;
  }

  /// 驱动一轮事件循环，返回本轮处理的 fd 数。
  ///
  /// 原生侧没有自己的线程（与原库一致，事件循环由调用方驱动），
  /// 因此需要周期性调用。建议 10–50 ms 一次。
  int pump({int timeoutMs = 10}) {
    if (_disposed) return 0;
    return _native.poll(_handle, timeoutMs);
  }

  /// 最近一次失败的错误名
  String get lastError {
    if (_disposed) return '';
    return _native.lastError(_handle).toDartString();
  }

  int get rxBytes => _disposed ? 0 : _native.rxBytes(_handle);
  int get txBytes => _disposed ? 0 : _native.txBytes(_handle);

  void stop() {
    if (_disposed) return;
    _native.stop(_handle);
  }

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _native.free(_handle);
  }
}
