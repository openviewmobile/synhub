// File Station 下载断点续传（P0-3 / 审计 M32）—— **引擎**，不含界面。
//
// 官方证据（DS file 4.17.2-609）：
//   * `sylibx/sydownloadmanager/services/DownloadTask.java:165-167`：
//     `if (this.mTempFile.exists()) { if (this.mCanAppend) {
//        this.mConn.addRequestProperty(HttpHeaders.RANGE,
//                                      "bytes=" + this.mTempFile.length() + "-");
//        this.mPreviousFileSize = this.mTempFile.length(); } ... }`
//     —— 临时文件带 `.sydownload` 后缀（`:53`），续传靠 `Range: bytes=<已下>-`。
//   * `:179-206`：`mTotalSize = contentLength + mPreviousFileSize`；
//     收完必须 `mPreviousFileSize + jCopy == mTotalSize`，不等就抛
//     `DownloadIncompleteException`（**总长校验点**）。
//   * `DownloadManager.pauseTask()`：`abort()` 后把任务放进 `mPausingTasks`，
//     **保留临时文件**；`resumeTask()` 重新执行同一个任务 → 走上面的 Range 分支。
//     `deleteTask()` 才删文件。
//
// 服务端参数证据：[K] `SYNO.FileStation.Download` v1/v2 `download`；真机尚未取到
// FileStation 的 206 原文（审计 §7.3 N6），因此本引擎对 Range 采取
// **"先信、但必须校验 206 + Content-Range；不符就诚实降级"** 的保守策略。
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:path_provider/path_provider.dart';
import '../../core/net/traffic_meter.dart';
import 'package:flutter/foundation.dart';

import '../../core/media/cache_service.dart' show humanBytes;
import '../../dsm/webapi.dart';

/// 一次 Range 请求的响应头结果（正文由 [RangeByteFetcher] 直接写进 sink）。
class RangeFetchOutcome {
  const RangeFetchOutcome({
    required this.statusCode,
    this.contentRange,
    this.contentLength,
  });

  /// HTTP 状态码（200 / 206 / 416 …）
  final int statusCode;

  /// `Content-Range` 原文，例如 `bytes 1024-4095/8192`
  final String? contentRange;

  /// 本次响应正文的字节数（206 时是"剩余段"的长度，200 时是整份长度）
  final int? contentLength;
}

/// 「支持任意起点 Range」的字节取数口。
///
/// ⚠️ 为什么不复用 `DsmWebApi.getBytes`：它只支持 `bytes=0-N` / `bytes=-N`，
/// 且**丢掉响应头**（拿不到状态码与 `Content-Range`）——续传两者都要。
/// `lib/src/dsm/**` 在本批是禁区，所以这里在文件功能层另开一个口子；
/// 生产用 [DioRangeByteFetcher]，测试注入假实现（不联网）。
abstract interface class RangeByteFetcher {
  /// 从 [start] 字节开始取 [url]，正文**流式**写进 [sink]。
  ///
  /// 契约（引擎按它校验）：
  ///   * `start == 0` → **不带** `Range` 头（普通 GET，服务端回 200）；
  ///   * `start > 0` → 带 `Range: bytes=<start>-`，服务端回 206 才算续传；
  ///   * `start > 0` 但服务端回 **200**（不支持 Range）→ **一个字节都不写**，
  ///     直接返回 `statusCode: 200`，由引擎决定"从 0 重来"；
  ///   * 用户暂停/取消 → 抛 [DownloadCancelledException]（已写进 sink 的字节
  ///     保留在临时文件里 —— 这正是可续传的根据）。
  Future<RangeFetchOutcome> fetchRange(
    String url, {
    required int start,
    required IOSink sink,
    void Function(int received, int total)? onProgress,
    DownloadCancelToken? cancelToken,
  });
}

/// 生产实现：**必须拿到"会话那条 Dio"**，否则自签/NAS-IP 证书会被拒。
///
/// ★★★ 第 302 轮真机逐字（`下载到本机` 与 `离线文件缓存` 都走这里）：
/// ```
/// 已登记，但缓存失败：DioException [unknown]: null
/// Error: HandshakeException: Handshake error in client (OS Error:
///   CERTIFICATE_VERIFY_FAILED: IP address mismatch(handshake.cc:320))
/// ```
/// 原因是老代码无条件 `DioRangeByteFetcher()` —— 它**新建一个默认 TLS 的
/// `HttpClient`**，而本 NAS 用 `https://<IP>:5001` + 自签证书
/// （`CN=nas.example.com`），主机名与 IP 必然不匹配。
/// 会话那条 Dio 是 `DioFactory.create` 造的，`badCertificateCallback` /
/// `trustPolicy` 已经放行 ⇒ **把它的 TLS 配置继承过来**（见
/// `rangeByteFetcherProvider`）。
///
/// 只继承 TLS：`receiveTimeout` 仍按"长下载"处理 —— 请求级覆盖成 24h，
/// 免得会话的 30s 整体接收超时把大文件掐断（暂停/取消靠轮询
/// [DownloadCancelToken] 并中断流）。
class DioRangeByteFetcher implements RangeByteFetcher {
  DioRangeByteFetcher({Dio? dio})
    : dio = tagDioWithModule(
        dio ??
            Dio(
              BaseOptions(
                connectTimeout: const Duration(seconds: 15),
                // 关键：不设 receiveTimeout（长下载不能被"整体超时"掐断）
                receiveTimeout: null,
                validateStatus: (_) => true,
              ),
            ),
        TrafficModules.downloads,
      );

  /// 实际发请求的 Dio。**公开**是为了让用例能钉住"它就是会话那条"
  /// （继承 TLS 是这个字段的全部意义）。
  final Dio dio;

  /// 长下载的请求级接收超时（覆盖会话的 30s；见类文档）。
  static const Duration longReceiveTimeout = Duration(hours: 24);

  @override
  Future<RangeFetchOutcome> fetchRange(
    String url, {
    required int start,
    required IOSink sink,
    void Function(int received, int total)? onProgress,
    DownloadCancelToken? cancelToken,
  }) async {
    final response = await dio.get<ResponseBody>(
      url,
      options: Options(
        responseType: ResponseType.stream,
        validateStatus: (_) => true,
        receiveTimeout: longReceiveTimeout,
        headers: {if (start > 0) 'Range': 'bytes=$start-'},
      ),
    );
    final status = response.statusCode ?? 0;
    final contentRange = response.headers.value('content-range');
    final contentType = response.headers.value('content-type');
    final contentLength = int.tryParse(
      response.headers.value('content-length') ?? '',
    );
    final body = response.data;
    // 服务端忽略 Range（回 200 整份）：**不写正文**，交给引擎降级。
    if (start > 0 && status == 200) {
      await _drain(body);
      return RangeFetchOutcome(statusCode: 200, contentLength: contentLength);
    }
    if (status != 200 && status != 206 && status != 416) {
      // 非 2xx：把正文读出来还原 DSM 错误码（401/403/…）
      final raw = await _collect(body, 4096);
      throw _errorFromBytes(raw, status, url, contentType);
    }
    if (body == null) {
      return RangeFetchOutcome(
        statusCode: status,
        contentRange: contentRange,
        contentLength: contentLength,
      );
    }
    // 200 整份下载要做"DSM JSON 错误信封"检测：DSM 对鉴权失败会回
    // `HTTP 200 + {"success":false,"error":{"code":119}}`，不识别就会把它
    // 当文件内容写盘（R6-4a 的坑）。206 是续传段，不做检测。
    final sniffEnvelope = status == 200 && start == 0;
    var received = 0;
    final buffer = BytesBuilder();
    var buffering = sniffEnvelope && !_isBinaryContentType(contentType);
    final done = Completer<void>();
    // 暂停时不一定有数据到达 → 用 200ms 轮询兜底取消底层流（真取消连接）。
    final poll = Timer.periodic(const Duration(milliseconds: 200), (_) {
      if (cancelToken?.isCancelled ?? false) {
        if (!done.isCompleted) {
          done.completeError(const DownloadCancelledException());
        }
      }
    });
    late final StreamSubscription<List<int>> sub;
    sub = body.stream.listen(
      (chunk) {
        if (cancelToken?.isCancelled ?? false) return;
        received += chunk.length;
        if (buffering) {
          buffer.add(chunk);
          if (buffer.length > _kMaxErrorEnvelopeBytes) {
            sink.add(buffer.takeBytes());
            buffering = false;
          }
        } else {
          sink.add(chunk);
        }
        onProgress?.call(received, contentLength ?? 0);
      },
      onError: (Object e) {
        if (!done.isCompleted) done.completeError(e);
      },
      onDone: () {
        if (!done.isCompleted) done.complete();
      },
      cancelOnError: true,
    );
    try {
      await done.future;
    } finally {
      poll.cancel();
      await sub.cancel();
    }
    if (buffering) {
      final head = buffer.takeBytes();
      final code = _errorEnvelopeCode(head, contentType);
      if (code != null) {
        throw DsmApiException(
          code,
          method: 'SYNO.FileStation.Download',
          raw: {'uri': url},
        );
      }
      if (head.isNotEmpty) sink.add(head);
    }
    await sink.flush();
    return RangeFetchOutcome(
      statusCode: status,
      contentRange: contentRange,
      contentLength: contentLength,
    );
  }

  Future<void> _drain(ResponseBody? body) async {
    if (body == null) return;
    try {
      await body.stream.drain<void>();
    } catch (_) {
      // 已经读不出也不影响：这条响应我们本来就要丢弃
    }
  }

  Future<List<int>> _collect(ResponseBody? body, int max) async {
    if (body == null) return const [];
    final out = <int>[];
    try {
      await for (final chunk in body.stream) {
        out.addAll(chunk);
        if (out.length >= max) break;
      }
    } catch (_) {}
    return out;
  }
}

/// DSM 错误信封的体积上限（与 `DirectTransport.kMaxErrorEnvelopeBytes` 同值）。
const int _kMaxErrorEnvelopeBytes = 512;

bool _isBinaryContentType(String? contentType) {
  if (contentType == null) return false;
  final ct = contentType.toLowerCase().trim();
  return ct.startsWith('image/') ||
      ct.startsWith('audio/') ||
      ct.startsWith('video/') ||
      ct.startsWith('font/') ||
      ct.startsWith('application/octet-stream') ||
      ct.startsWith('application/pdf') ||
      ct.startsWith('application/zip') ||
      ct.startsWith('application/x-') ||
      ct.startsWith('application/vnd.');
}

int? _errorEnvelopeCode(List<int> data, String? contentType) {
  if (data.isEmpty || data.length > _kMaxErrorEnvelopeBytes) return null;
  if (_isBinaryContentType(contentType)) return null;
  try {
    final text = utf8.decode(data, allowMalformed: true).trim();
    if (text.length < 8 || !text.startsWith('{') || !text.endsWith('}')) {
      return null;
    }
    final decoded = jsonDecode(text);
    if (decoded is! Map) return null;
    if (decoded['success'] != false) return null;
    final err = decoded['error'];
    if (err is! Map) return null;
    final c = err['code'];
    return c is int ? c : null;
  } catch (_) {
    return null;
  }
}

Exception _errorFromBytes(
  List<int> data,
  int status,
  String url,
  String? contentType,
) {
  if (data.isNotEmpty) {
    try {
      final decoded = jsonDecode(utf8.decode(data, allowMalformed: true));
      if (decoded is Map && decoded['error'] is Map) {
        final c = (decoded['error'] as Map)['code'];
        if (c is int) {
          return DsmApiException(c, raw: {'http': status, 'uri': url});
        }
      }
    } catch (_) {}
  }
  return DsmTransportException('HTTP $status', statusCode: status, uri: url);
}

/// 断点信息持久化（**进程重启后仍可续**）。
///
/// 存的是"源路径 → 已知总长"，落盘在下载目录的 `.resume.json`。
/// 临时文件本身（`<name>.sydownload`）也在下载目录，两者一起就够重启后续传。
class FileResumeStore {
  FileResumeStore(this.directory);

  final Directory directory;

  File get _file => File('${directory.path}/.resume.json');

  Future<Map<String, dynamic>> _read() async {
    try {
      if (!await _file.exists()) return const {};
      final raw = await _file.readAsString();
      final decoded = jsonDecode(raw);
      if (decoded is Map && decoded['entries'] is Map) {
        return Map<String, dynamic>.from(decoded['entries'] as Map);
      }
    } catch (_) {
      // 坏了就当没有：续传是尽力而为，不能因为元数据坏掉阻断下载
    }
    return const {};
  }

  Future<void> _write(Map<String, dynamic> entries) async {
    try {
      await _file.writeAsString(
        jsonEncode({'version': 1, 'entries': entries}),
        flush: true,
      );
    } catch (_) {
      // 元数据写不进去也不阻断（顶多丢了"总长"这一个加速信息）
    }
  }

  /// 已知总长；没有记录返回 null。
  Future<int?> totalFor(String sourcePath) async {
    final entries = await _read();
    final entry = entries[sourcePath];
    if (entry is Map) return _asInt(entry['total']);
    return _asInt(entry);
  }

  Future<void> save(String sourcePath, int total) async {
    final entries = Map<String, dynamic>.from(await _read());
    entries[sourcePath] = {
      'total': total,
      'updatedAt': DateTime.now().millisecondsSinceEpoch,
    };
    await _write(entries);
  }

  Future<void> remove(String sourcePath) async {
    final entries = Map<String, dynamic>.from(await _read());
    if (entries.remove(sourcePath) != null) await _write(entries);
  }
}

/// 下载结果（给界面判断"是不是降级重下了 / 从第几字节接上"）。
class FileDownloadOutcome {
  const FileDownloadOutcome({
    required this.localPath,
    required this.totalBytes,
    this.resumedFrom = 0,
    this.fullRestart = false,
  });

  final String localPath;
  final int totalBytes;

  /// 本次是从第几个字节接上的（0 = 从头）
  final int resumedFrom;

  /// 服务端不支持 Range → 已退回整文件下载（界面必须**如实提示**）
  final bool fullRestart;
}

/// 用户暂停（不是错误，也不是取消）。
class FileDownloadPausedException implements Exception {
  const FileDownloadPausedException();
}

/// 收完的字节数与总长对不上（官方 `DownloadIncompleteException` 的对应物）。
class FileDownloadIncompleteException implements Exception {
  const FileDownloadIncompleteException(this.message);

  final String message;

  static const String debugLabel = 'FileDownloadIncompleteException';

  @override
  String toString() => '$debugLabel($message)';
}

/// 一次文件下载的会话：进度 + 暂停/继续/取消三态。
///
/// 暂停（[pause]）＝ 取消当前 HTTP 请求但**保留临时文件**（官方
/// `DownloadManager.pauseTask` 的 `mPausingTasks` 语义）；
/// 取消（[cancel]）＝ 取消并让调用方删掉临时文件（官方 `deleteTask`）。
class FileDownloadSession extends ChangeNotifier {
  FileDownloadSession(this.filename);

  final String filename;

  /// 取消令牌 —— [resume] 时换一个新的（`DownloadCancelToken` 不可复位）
  DownloadCancelToken cancelToken = DownloadCancelToken();

  /// (已下载字节, 总字节)；total == 0 表示服务端没给长度 → 转圈
  final ValueNotifier<({int received, int total})> progress = ValueNotifier((
    received: 0,
    total: 0,
  ));

  bool _paused = false;
  bool _cancelled = false;

  /// ★ `DA100`：**这一次在飞请求里**用户按过暂停（即使随后立刻又按了「继续」也不清）。
  ///
  /// 为什么不能只看 [isPaused]：`pause()` 只是取消底层请求，取消异常要**稍后**才回到
  /// 引擎（dio 侧还有 200ms 轮询兜底）。用户若在这个窗口里点了「继续」，
  /// [isPaused] 已经变回 `false` ⇒ 那次取消被归成「用户取消(abort)」⇒ 任务显示「已取消」
  /// 并停在那儿。归类只该问「这次取消是不是暂停引起的」，所以用**单调痕迹**，
  /// 由 [beginRequest] 在**下一次请求开始前**清掉。
  bool _pauseRequested = false;

  /// 这次在飞请求是否由暂停引起（见 [_pauseRequested]）。
  bool get pauseRequestedForInFlightRequest => _pauseRequested;

  /// 每次**发起新请求之前**调用：清掉上一轮请求的暂停痕迹。
  void beginRequest() => _pauseRequested = false;
  bool _finished = false;
  Completer<void>? _resumeGate;

  bool get isPaused => _paused;
  bool get isCancelled => _cancelled;

  /// `onProgress` 回调（dio 会给 total = -1 表示未知，归一到 0）
  /// 进度百分比（`total <= 0` ⇒ 0；夹在 0..100）
  static int _pctOf(({int received, int total}) p) {
    if (p.total <= 0) return 0;
    return ((p.received * 100) ~/ p.total).clamp(0, 100);
  }

  void report(int received, int total) {
    final next = (received: received, total: total < 0 ? 0 : total);
    final prev = progress.value;
    if (prev.received == next.received && prev.total == next.total) {
      return;
    }
    // ★ `DA101`：进度 tick 也必须让**任务行**重建。
    // 修前这里只写 `progress`（`ValueNotifier`），而任务行 `ListenableBuilder`
    // 监听的是 `FileDownloadTask`（`ChangeNotifier`）⇒ 进度条与百分比**只在状态变化时**
    // 才刷新；真机上表现为"文件在涨、界面数字冻住"（r447 实测：文字停在
    // `267 MB / 4.4 GB · 5%`，而 `.sydownload` 已从 487 MB 涨到 673 MB）。
    // 按**整数百分比**变化去重 ⇒ 一次下载最多 100 次重建。
    final changedPct = _pctOf(prev) != _pctOf(next);
    progress.value = next;
    if (changedPct) notifyListeners();
  }

  void pause() {
    if (_paused || _cancelled || _finished) return;
    _paused = true;
    _pauseRequested = true; // ★ DA100：单调痕迹，`resume()` 不许清掉
    cancelToken.cancel('pause');
    notifyListeners();
  }

  void resume() {
    if (!_paused) return;
    _paused = false;
    cancelToken = DownloadCancelToken();
    final gate = _resumeGate;
    _resumeGate = null;
    gate?.complete();
    notifyListeners();
  }

  void cancel() {
    if (_cancelled) return;
    _cancelled = true;
    cancelToken.cancel('cancel');
    notifyListeners();
  }

  void finish() {
    _finished = true;
    notifyListeners();
  }

  /// 暂停后挂起，直到用户点「继续」（或 [releaseGate] 放行取消）。
  Future<void> waitForResume() {
    if (_cancelled) return Future<void>.value();
    return (_resumeGate ??= Completer<void>()).future;
  }

  /// 取消时放行挂起的 [waitForResume]，否则循环会永远等下去
  void releaseGate() {
    final gate = _resumeGate;
    _resumeGate = null;
    gate?.complete();
  }

  int get percent => _pctOf(progress.value);

  String get humanReadable {
    final p = progress.value;
    if (p.total <= 0) return '';
    return '${humanBytes(p.received)} / ${humanBytes(p.total)}';
  }

  @override
  void dispose() {
    progress.dispose();
    super.dispose();
  }
}

class _ContentRange {
  const _ContentRange({
    required this.start,
    required this.end,
    required this.total,
    required this.rawTotal,
  });

  final int start;
  final int end;

  /// `*` 时是 0
  final int total;
  final String rawTotal;
}

/// 断点续传引擎：临时文件 + Range + 206 校验 + 降级 + 落盘。
class FileDownloadResumer {
  FileDownloadResumer({required this.fetcher, required this.store});

  final RangeByteFetcher fetcher;
  final FileResumeStore store;

  /// 临时文件后缀 —— 逐字取自官方 `DownloadTask.java:53`
  /// （`downloadData.getFileName() + (useTempFile ? ".sydownload" : "")`）。
  static const String tempSuffix = '.sydownload';

  /// [sourcePath] 是 NAS 上的源路径（断点元数据的 key）；
  /// [fileName] 是落盘用的文件名。
  Future<FileDownloadOutcome> download({
    required String sourcePath,
    required String url,
    required String fileName,
    required Directory directory,
    void Function(int received, int total)? onProgress,
    DownloadCancelToken? cancelToken,
    bool Function()? isPaused,
  }) async {
    final target = File('${directory.path}/$fileName');
    final temp = File('${target.path}$tempSuffix');
    final knownTotal = await store.totalFor(sourcePath);

    // 已经整份下好（且长度对得上）→ 直接复用，不必再下
    if (await target.exists()) {
      final len = await target.length();
      if (knownTotal == null || knownTotal == len) {
        await store.remove(sourcePath);
        return FileDownloadOutcome(localPath: target.path, totalBytes: len);
      }
    }

    var have = await temp.exists() ? await temp.length() : 0;
    var total = knownTotal ?? 0;
    final resumedFrom = have;
    var fullRestart = false;
    if (total > 0 && have >= total) {
      return _finalize(
        sourcePath: sourcePath,
        temp: temp,
        target: target,
        total: total,
        resumedFrom: resumedFrom,
        fullRestart: fullRestart,
      );
    }

    while (true) {
      final sink = temp.openWrite(
        mode: have > 0 ? FileMode.append : FileMode.write,
      );
      RangeFetchOutcome outcome;
      try {
        outcome = await fetcher.fetchRange(
          url,
          start: have,
          sink: sink,
          onProgress: (received, remainingTotal) {
            final effective = remainingTotal > 0
                ? have + remainingTotal
                : total;
            onProgress?.call(have + received, effective);
          },
          cancelToken: cancelToken,
        );
      } catch (e) {
        // 暂停 / 取消：**保留临时文件**（官方 pauseTask 就是保留，
        // deleteTask 才删）。进度不丢。
        await _closeQuietly(sink);
        if (e is DownloadCancelledException) {
          if (isPaused?.call() ?? false) {
            throw const FileDownloadPausedException();
          }
          rethrow;
        }
        rethrow;
      }
      await _closeQuietly(sink);
      final written = (await temp.length()) - have;

      if (outcome.statusCode == 416) {
        // 范围不可满足：要么本地已经齐了，要么远端变小了 → 从头来
        final rangeTotal = _parseUnsatisfiedTotal(outcome.contentRange);
        if (rangeTotal != null && rangeTotal == await temp.length()) {
          return _finalize(
            sourcePath: sourcePath,
            temp: temp,
            target: target,
            total: rangeTotal,
            resumedFrom: resumedFrom,
            fullRestart: fullRestart,
          );
        }
        await _truncate(temp);
        have = 0;
        total = rangeTotal ?? 0;
        fullRestart = true;
        continue;
      }
      if (outcome.statusCode == 200 && have > 0) {
        // 服务端不支持 Range（忽略 Range 头回了整份）：**诚实降级**
        // 回到整文件下载，而不是把整份 append 到半截文件后面。
        await _truncate(temp);
        have = 0;
        total = outcome.contentLength ?? 0;
        fullRestart = true;
        continue;
      }
      if (outcome.statusCode != 200 && outcome.statusCode != 206) {
        throw HttpException(
          'HTTP ${outcome.statusCode}',
          uri: Uri.tryParse(url),
        );
      }

      if (outcome.statusCode == 206) {
        final range = _parseContentRange(outcome.contentRange);
        // 206 校验点①：Content-Range 必须存在且可解析
        if (range == null) {
          throw FileDownloadIncompleteException(
            '206 响应缺少合法的 Content-Range: ${outcome.contentRange}',
          );
        }
        // 206 校验点②：起点必须正好是"我们已经有的字节数"
        if (range.start != have) {
          throw FileDownloadIncompleteException(
            'Content-Range 起点 ${range.start} 与本地已有 $have 不一致',
          );
        }
        // 206 校验点③：总长必须大于终点；且远端总长与记录的旧总长不一致
        // 说明文件被改过 → 从头重下（继续拼接必然损坏）。
        if (range.total > 0 && range.total <= range.end) {
          throw FileDownloadIncompleteException(
            'Content-Range 总长 ${range.total} 不大于终点 ${range.end}',
          );
        }
        if (range.total > 0) {
          if (total > 0 && total != range.total) {
            await _truncate(temp);
            have = 0;
            total = range.total;
            fullRestart = true;
            continue;
          }
          total = range.total;
          await store.save(sourcePath, total);
        } else if (range.rawTotal == '*') {
          // 总长未知：允许继续，但无法做"收完校验"
          total = 0;
        }
      } else {
        // 200：整份下载，总长以 content-length 为准
        total = outcome.contentLength != null && outcome.contentLength! > 0
            ? outcome.contentLength!
            : (written > 0 ? written : total);
        if (total > 0) await store.save(sourcePath, total);
      }

      have += written;
      if (total > 0 && have >= total) {
        return _finalize(
          sourcePath: sourcePath,
          temp: temp,
          target: target,
          total: total,
          resumedFrom: resumedFrom,
          fullRestart: fullRestart,
        );
      }
      if (written == 0) {
        // 一个字节都没拿到且还没齐：不用空转
        throw const FileDownloadIncompleteException('服务端没有返回任何数据');
      }
      if (total <= 0) {
        // 没有总长可校验：收完即认为完成（如实记在文档的未验证边界里）
        return _finalize(
          sourcePath: sourcePath,
          temp: temp,
          target: target,
          total: 0,
          resumedFrom: resumedFrom,
          fullRestart: fullRestart,
        );
      }
    }
  }

  Future<FileDownloadOutcome> _finalize({
    required String sourcePath,
    required File temp,
    required File target,
    required int total,
    required int resumedFrom,
    required bool fullRestart,
  }) async {
    final len = await temp.length();
    // 官方 `DownloadIncompleteException`：收完必须与总长一致
    if (total > 0 && len != total) {
      throw FileDownloadIncompleteException('已收 $len 字节，总长 $total 字节');
    }
    if (await target.exists()) await target.delete();
    await temp.rename(target.path);
    await store.remove(sourcePath);
    return FileDownloadOutcome(
      localPath: target.path,
      totalBytes: len,
      resumedFrom: resumedFrom,
      fullRestart: fullRestart,
    );
  }

  Future<void> _truncate(File file) async {
    if (await file.exists()) await file.writeAsBytes(const [], flush: true);
  }
}

/// 解析 `bytes <start>-<end>/<total|*>`
_ContentRange? _parseContentRange(String? raw) {
  if (raw == null) return null;
  final m = RegExp(
    r'^bytes\s+(\d+)-(\d+)/(\d+|\*)$',
  ).firstMatch(raw.trim());
  if (m == null) return null;
  final totalRaw = m.group(3)!;
  return _ContentRange(
    start: int.parse(m.group(1)!),
    end: int.parse(m.group(2)!),
    total: totalRaw == '*' ? 0 : int.parse(totalRaw),
    rawTotal: totalRaw,
  );
}

/// 解析 416 的 `bytes */<total>`
int? _parseUnsatisfiedTotal(String? raw) {
  if (raw == null) return null;
  final m = RegExp(r'^bytes\s+\*/(\d+)$').firstMatch(raw.trim());
  if (m == null) return null;
  return int.parse(m.group(1)!);
}

int? _asInt(Object? v) {
  if (v is int) return v;
  if (v is num) return v.toInt();
  if (v is String) return int.tryParse(v);
  return null;
}

Future<void> _closeQuietly(IOSink sink) async {
  try {
    await sink.flush();
  } catch (_) {}
  try {
    await sink.close();
  } catch (_) {}
}

// ============================================================ 离线文件缓存层
//
// ★ 第 302 轮：219/G4「离线文件」的**真缓存**。
//
// ## 为什么补这一层（真机发现，不是猜）
//
// 第 302 轮在真机上把「加入离线文件」走通后，链路是：
//   点菜单 → Snackbar「已加入离线文件」→ 文件工具/离线文件页「共 1 项 / 合计 11 B」
//   → force-stop 冷启动后仍在（**清单确实落盘**）。
// 但 `OfflinePinEntry.localPath` 在**全仓没有任何生产者**（只有 `fromJson` 与落盘/读回），
// 于是：`hasLocalCopy` 恒 false ⇒ 清单行永远"未缓存"；`buildSafIndex()` 只收
// `hasLocalCopy` 的项 ⇒ **系统「文件」App 的 Synology 位置里永远看不到离线文件**；
// 断网后自然也打不开 —— 而"离线"两个字的全部意义就在这里。
// 官方 `Pin` 是有 `mLocalPath` 的：离线文件 = **登记 + 真把字节放到本机**。
//
// ## 为什么放在这个文件（不是新开一个）
//
// `test/platform_web_test.dart` ④ 守卫"`lib/` 里 import `dart:io` 的文件数
// **只许缩不许涨**"（基线 82，web 站上 `dart:io` 是**运行期**债务）。
// 本层必然要碰文件系统，放进**已有的** `dart:io` 文件里 ⇒ 净增 0，
// 守卫方向不变。（我试过"删两个没用 dart:io 的文件来抵消"，但 `analyzer`
// 明说 lib/ 里**没有**未使用导入 —— 那两个文件用的是 `SocketException` /
// `HandshakeException` / `FileSystemException` 这类我第一版正则漏掉的类型。
// **别再用正则猜"这个文件用没用 dart:io"，直接看 `flutter analyze` 的
// `unused_import`。**）
//
// ## 语义边界（不许含糊）
//
//   * 缓存**只**写 App 私有目录 `<Documents>/offline_cache/`，不碰相册/下载；
//   * 文件名 = `<8 位路径指纹>_<安全文件名>`：同名不同目录**不会**互相覆盖
//     （离线清单的主键是 NAS 全路径）；
//   * 缓存失败**不回滚登记**：登记与缓存是两件事（官方 `Pin` 在、`mLocalPath`
//     空就是"未缓存"）。失败原因如实回给界面；
//   * 取消登记（或整表清空）时**顺手删掉本地副本**，不留孤儿字节。
//
// 参数用**原语**（path/name）而不是 `OfflinePinEntry`：本文件是**引擎**，
// 不反向依赖 features 的模型（`file_offline_pin.dart` 才是登记模型所在）。

/// 缓存结果。`localPath` 非空即成功（[ok]）。
class OfflineCacheResult {
  const OfflineCacheResult({this.localPath = '', this.bytes = 0, this.error});

  /// 本机副本的路径；失败时为空串（**登记仍在**）。
  final String localPath;

  /// 落盘字节数。
  final int bytes;

  /// 失败原因（只用于界面提示，不进清单）。
  final String? error;

  bool get ok => localPath.isNotEmpty;

  static const OfflineCacheResult failed = OfflineCacheResult();
}

/// 一次缓存的取数口 —— 生产实现走 [FileDownloadResumer]（断点续传），
/// 单测注入假实现，**不联网、不碰平台通道**。
typedef OfflineCacheFetcher =
    Future<FileDownloadOutcome> Function({
      required String path,
      required String name,
      required Directory directory,
      void Function(int received, int total)? onProgress,
    });

/// 把一条登记真下到本机。
class OfflineCacher {
  const OfflineCacher({required this.fetcher, this.documentsDir});

  final OfflineCacheFetcher fetcher;

  /// 解析 `<Documents>` 的口子。默认走 `path_provider`；
  /// 单测注入临时目录，**不碰平台通道**。
  final Future<Directory> Function()? documentsDir;

  /// 私有缓存目录名（相对 `<Documents>`）。
  static const String directoryName = 'offline_cache';

  Future<OfflineCacheResult> cache({
    required String path,
    required String name,
    void Function(int received, int total)? onProgress,
  }) async {
    if (path.isEmpty) return OfflineCacheResult.failed;
    try {
      final docs =
          await (documentsDir?.call() ?? getApplicationDocumentsDirectory());
      final dir = Directory('${docs.path}/$directoryName');
      if (!dir.existsSync()) await dir.create(recursive: true);
      final outcome = await fetcher(
        path: path,
        name: name,
        directory: dir,
        onProgress: onProgress,
      );
      final localPath = outcome.localPath;
      if (localPath.isEmpty) return OfflineCacheResult.failed;
      final bytes = await File(localPath).length();
      return OfflineCacheResult(localPath: localPath, bytes: bytes);
    } catch (e) {
      // 缓存是"锦上添花"：失败只回原因，登记照旧（界面显示"未缓存"）。
      return OfflineCacheResult(error: '$e');
    }
  }

  /// 落盘用的文件名：`<指纹>_<安全名>`。
  ///
  /// 指纹取自 NAS 全路径 ⇒ 不同目录下的同名文件不会互相覆盖，
  /// 而同一个文件重复缓存**命中同一路径**（[FileDownloadResumer] 直接复用）。
  static String fileNameFor({required String path, required String name}) {
    final safe = _safeName(name.isEmpty ? _baseName(path) : name);
    return '${pathFingerprint(path)}_$safe';
  }

  static String _baseName(String path) {
    final i = path.lastIndexOf('/');
    return i < 0 ? path : path.substring(i + 1);
  }

  /// 去掉路径分隔符与 `..`，并限制长度（FAT/APFS 都不喜欢超长名）。
  static String _safeName(String name) {
    final cleaned = name
        .replaceAll(RegExp(r'[/\\]'), '_')
        .replaceAll('..', '_')
        .replaceAll(RegExp(r'^\.+'), '_')
        .trim();
    final out = cleaned.isEmpty ? 'file' : cleaned;
    return out.length <= 80 ? out : out.substring(out.length - 80);
  }
}

/// 8 位十六进制的稳定路径指纹（FNV-1a 32 位）。
///
/// 不引加密库：这里只要"稳定 + 碰撞概率足够低"，不是安全用途。
String pathFingerprint(String path) {
  var hash = 0x811c9dc5;
  for (final unit in path.codeUnits) {
    hash ^= unit;
    hash = (hash * 0x01000193) & 0xffffffff;
  }
  return hash.toRadixString(16).padLeft(8, '0');
}

/// 删除某个本地副本（取消登记时调用）。找不到文件**不算错**
/// —— 用户手动清过 App 数据是正常情况。
Future<void> deleteOfflineCopy(String localPath) async {
  if (localPath.isEmpty) return;
  try {
    final f = File(localPath);
    if (f.existsSync()) await f.delete();
  } catch (_) {
    // 删不掉只意味着磁盘上多一个字节，不该让"取消登记"失败。
  }
}
