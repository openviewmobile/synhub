// 「上次看到哪儿」的**本机**记忆（r636 / `DA227`）。
//
// ## 为什么需要
//
// 真机现场：10 分钟的课程视频看到 04:31，退出去（哪怕只是回个消息）再点进来，
// 播放器**永远从 00:00 开始**。用户的动作是"接着看"，播放器给的却是"重新看"
// —— 这是视频播放器最基础的期待之一，Plex / YouTube / 播客类 App 全都有。
//
// ## 取舍（按人类视角，不按技术视角）
//
//   * **只记本机**：不回写 NAS、不发接口（§5.1 零写动词），也不进"最近播放"
//     这类服务端账本 —— 换台手机就该从头看，这是用户的心理预期；
//   * **只对可 seek 的源生效**：直播 / 不支持 Range 的流（`streamingOnly`）
//     没有"上次的位置"这回事，硬 seek 会失败；
//   * **太短的不记、快看完的不记**：看 3 秒就退出、或已经看到只剩 10 秒，
//     下次"接着看"等于立刻播完 —— 这两种都当"没记住"处理（并且清掉旧值）；
//   * **有上限**：最多 50 条、按最近使用淘汰，避免这个文件无限长。
//
// 存储 = `<support>/media_resume.json`（与 App 其它本机状态同层，覆盖安装保留）。
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';

/// 一条"上次看到"的记录。
class MediaResumeEntry {
  const MediaResumeEntry({required this.position, required this.updatedAt});

  final Duration position;
  final DateTime updatedAt;
}

/// 起记门槛：短于这个长度的"进度"没有意义。
const Duration kMediaResumeMinPosition = Duration(seconds: 5);

/// 离片尾这么近就算"看完了"，不再记住。
const Duration kMediaResumeEndGuard = Duration(seconds: 10);

/// 默认最多记住多少条。
const int kMediaResumeMaxEntries = 50;

/// 本机播放进度记忆。
///
/// 一切都是**尽力而为**：文件坏了、写不进去、目录拿不到 —— 都返回 null / 静默跳过。
/// 播放器绝不因为"记不住进度"而报错或卡住。
class MediaResumeStore {
  MediaResumeStore({
    Future<Directory> Function()? supportDirectory,
    this.maxEntries = kMediaResumeMaxEntries,
  }) : _supportDirectory = supportDirectory ?? getApplicationSupportDirectory;

  final Future<Directory> Function() _supportDirectory;
  final int maxEntries;

  /// 会随**每次打开**变化的查询参数（会话/防缓存）。
  ///
  /// ★ 真机第一版就栽在这里：FileStation 的直链带 `_sid` 与 `SynoToken`，
  /// 每次点开都重新拼一份 ⇒ 用整条 URL 当键，**存的和读的永远不是同一个键**，
  /// 表现为"后端明明存了，再进来还是 00:00"。所以键必须**抹掉易变参数**。
  static const Set<String> volatileQueryKeys = <String>{
    '_sid',
    'sid',
    'SID',
    'SynoToken',
    'synotoken',
    'token',
    'session',
    'sessionid',
    '_dc',
    'cached',
  };

  /// 把一条直链归一成**稳定身份**：协议 + 主机 + 路径 + **文件路径参数**。
  ///
  /// 两个坑都要躲开（都是真机踩出来的）：
  ///   ① 会话参数每次都变（`_sid`/`SynoToken`）⇒ 必须抹掉；
  ///   ② `MediaSource.uri` 里的参数**常常挂在 fragment 上**（`entry.cgi?#?api=…`，
  ///      不是 `?` 查询串）⇒ 只看 `Uri.query` 会把整段参数当"没有"，
  ///      于是同一目录下**所有视频共用一个键**（那条片子的进度会顶掉这条的）。
  ///      所以 fragment 里带 `=` 的也要当参数解析。
  static String keyOf(String uri) {
    final parsed = Uri.tryParse(uri);
    if (parsed == null) return uri;
    var query = parsed.hasQuery ? parsed.query : '';
    final fragment = parsed.fragment;
    if (query.isEmpty && fragment.contains('=')) {
      query = fragment.startsWith('?') ? fragment.substring(1) : fragment;
    }
    Map<String, String> params;
    try {
      params = Uri.splitQueryString(query);
    } catch (_) {
      params = const {};
    }
    params.removeWhere((k, _) => volatileQueryKeys.contains(k));
    final base = '${parsed.scheme}://${parsed.authority}${parsed.path}';
    // 文件身份优先用 `path`（FileStation/Drive 都是这个参数），它才是"哪一条"
    final filePath = params.remove('path');
    final keys = params.keys.toList()..sort();
    final rest = keys.map((k) => '$k=${params[k]}').join('&');
    if (filePath != null && filePath.isNotEmpty) {
      return rest.isEmpty ? '$base|$filePath' : '$base|$filePath|$rest';
    }
    return rest.isEmpty ? base : '$base|$rest';
  }

  Map<String, MediaResumeEntry>? _cache;
  Directory? _dir;

  /// 判断这条进度值不值得记（也给读侧复用：读到"太短/太靠尾"的脏值当没读到）。
  static bool isWorthRemembering(Duration position, Duration duration) {
    if (duration <= Duration.zero) return false;
    if (position < kMediaResumeMinPosition) return false;
    if (position > duration - kMediaResumeEndGuard) return false;
    return true;
  }

  Future<File?> _file() async {
    try {
      _dir ??= await _supportDirectory();
      return File('${_dir!.path}/media_resume.json');
    } catch (_) {
      return null;
    }
  }

  Future<Map<String, MediaResumeEntry>> _load() async {
    final cached = _cache;
    if (cached != null) return cached;
    final out = <String, MediaResumeEntry>{};
    final f = await _file();
    if (f != null && await f.exists()) {
      try {
        final raw = jsonDecode(await f.readAsString());
        final items = raw is Map ? raw['items'] : null;
        if (items is Map) {
          for (final e in items.entries) {
            final v = e.value;
            if (v is! Map) continue;
            final ms = v['ms'];
            final at = v['at'];
            if (ms is! num) continue;
            out['${e.key}'] = MediaResumeEntry(
              position: Duration(milliseconds: ms.toInt()),
              updatedAt: DateTime.fromMillisecondsSinceEpoch(
                at is num ? at.toInt() : 0,
              ),
            );
          }
        }
      } catch (_) {
        // 坏文件 = 没有记忆，不打扰用户。
      }
    }
    _cache = out;
    return out;
  }

  Future<void> _flush() async {
    final f = await _file();
    if (f == null) return;
    final items = _cache ?? const <String, MediaResumeEntry>{};
    try {
      final payload = <String, Object?>{
        'version': 1,
        'items': <String, Object?>{
          for (final e in items.entries)
            e.key: <String, Object?>{
              'ms': e.value.position.inMilliseconds,
              'at': e.value.updatedAt.millisecondsSinceEpoch,
            },
        },
      };
      await f.writeAsString(jsonEncode(payload), flush: false);
    } catch (_) {
      // 写不进去就下次再试；不许影响播放。
    }
  }

  /// 读到"值得续播"的位置；否则 null。
  Future<Duration?> load(String uri, {required Duration duration}) async {
    final key = keyOf(uri);
    if (key.isEmpty || !isWorthRemembering(const Duration(seconds: 5), duration)) {
      // 连 15 秒都不到的视频不记进度。
      return null;
    }
    final items = await _load();
    final e = items[key];
    if (e == null) return null;
    if (!isWorthRemembering(e.position, duration)) return null;
    return e.position;
  }

  /// 记一次进度；不值得记时**顺手清掉旧值**（看完了就别再"续播"）。
  Future<void> save(
    String uri,
    Duration position, {
    required Duration duration,
  }) async {
    final key = keyOf(uri);
    if (key.isEmpty) return;
    final items = await _load();
    if (!isWorthRemembering(position, duration)) {
      if (items.remove(key) != null) await _flush();
      return;
    }
    items[key] = MediaResumeEntry(
      position: position,
      updatedAt: DateTime.now(),
    );
    if (items.length > maxEntries) {
      final sorted = items.entries.toList()
        ..sort((a, b) => b.value.updatedAt.compareTo(a.value.updatedAt));
      final keep = sorted.take(maxEntries);
      items
        ..clear()
        ..addEntries(keep);
    }
    await _flush();
  }

  /// 用户点「从头播放」/ 换别的片子后不想再被拉回旧位置时调用。
  Future<void> clear(String uri) async {
    final key = keyOf(uri);
    final items = await _load();
    if (items.remove(key) != null) await _flush();
  }
}
