// **r441** · 网络电台「关键字搜台」的**只读**契约探针。
//
// 背景（`docs/android-remaining-todo-r418.md` §二-2）：官方 Web 前端**有** `Radio.search`，
// 我们的 UI **没有**（`audio_radio_page.dart` 里逐字写着「`Radio.search` 仍未接 UI」）。
// 现有生产代码把 `keyword` 挂在 **`Radio.list`** 上（`audio_station.dart` `listRadios(keyword:)`）。
//
// 本探针要回答的是**契约问题**（不许猜）：
//   ① `Radio.list` 到底认不认 `keyword`？还是要 `text`？
//   ② `Radio.search`（v2）存在吗？参数名是 `keyword` 吗？回包 root 还是 `radios` 吗？
//   ③ `search` 要不要带 `container`？带与不带结果一样吗？
//   ④ 分页 `offset/limit` 在 `search` 上有效吗？
//
// 只读：零写动词（只调 `list` / `search`；不发 `add`/`updateradios`）。
// 凭据只从 `--dart-define` 来（`~/.synhub-nas.env`，仓库外）：
//   set -a; . ~/.synhub-nas.env; set +a
//   flutter test tool/r441_radio_search_probe_test.dart \
//     --dart-define=NAS_URL="$SYNO_NAS_URL" --dart-define=NAS_ACCOUNT="$SYNO_NAS_ACCOUNT" \
//     --dart-define=NAS_PASSWORD="$SYNO_NAS_PASSWORD"
// ignore_for_file: avoid_print
import 'package:flutter_test/flutter_test.dart';
import 'package:synhub/src/core/net/dio_factory.dart';
import 'package:synhub/src/data/audio_station.dart';
import 'package:synhub/src/dsm/webapi.dart';

const String url = String.fromEnvironment('NAS_URL');
const String account = String.fromEnvironment('NAS_ACCOUNT');
const String password = String.fromEnvironment('NAS_PASSWORD');
const String keywords = String.fromEnvironment(
  'KEYWORDS',
  defaultValue: 'Jazz,rock,news,SHOUTcast',
);

Future<AudioStationApi> connect() async {
  final api = DsmWebApi(
    DirectTransport.url(url, dio: DioFactory.create(allowSelfSigned: true)),
  );
  await api.discover();
  await api.login(account: account, password: password, session: 'AudioStation');
  print('[r441] 已登录 $url as $account');
  return AudioStationApi(api);
}

/// 一条只读调用的读数（**不看状态码，看内容**：条目数 + 前几个 title/id）。
class Reading {
  Reading(this.label, this.api, this.method, this.version, this.params);
  final String label;
  final String api;
  final String method;
  final int version;
  final Map<String, dynamic> params;

  int items = -1;
  int total = -1;
  List<String> sample = const <String>[];
  List<String> keys = const <String>[];
  int? errorCode;
  String? errorText;
  int ms = -1;

  bool get ok => errorCode == null;
}

Future<Reading> probe(
  AudioStationApi as,
  String label,
  String method,
  int version,
  Map<String, dynamic> params,
) async {
  final r = Reading(label, AudioStationApi.apiRadio, method, version, params);
  final t0 = DateTime.now();
  try {
    final data = await as.api.call(
      AudioStationApi.apiRadio,
      method,
      preferredVersion: version,
      params: params,
    );
    r.keys = data.keys.map((k) => k.toString()).toList();
    final raw = data['radios'] ?? data['items'];
    final list = <Map<String, dynamic>>[
      if (raw is List)
        for (final e in raw)
          if (e is Map) Map<String, dynamic>.from(e),
    ];
    r.items = list.length;
    r.total = data['total'] is int ? data['total'] as int : list.length;
    r.sample = [
      for (final e in list.take(3))
        'id=${e['id']} type=${e['type']} title=${e['title']}',
    ];
    // ★ 原始字段名逐个打出来（UI 要用 `url`/`id`，不许猜字段是否存在）；
    //   `raw_all=1` 时把前 8 条的**完整 map**都打出来（查标题编码/怪字符用）。
    if (list.isNotEmpty) {
      print('[r441]      raw_first=${list.first}');
      if (const String.fromEnvironment('RAW_ALL').isNotEmpty) {
        for (final e in list.take(8)) {
          print('[r441]      raw[t]=${e['title']}  '
              'runes=${(e['title'] as String? ?? '').runes.map((r) => r.toRadixString(16)).join(',')}');
        }
      }
    }
  } on DsmApiException catch (e) {
    r.errorCode = e.code;
    r.errorText = DsmErrorCode.describe(e.code, method: method);
  } catch (e) {
    r.errorText = '$e';
  }
  r.ms = DateTime.now().difference(t0).inMilliseconds;
  print(
    '[r441] ${r.label.padRight(46)} v$version  '
    '${r.ok ? "条目=${r.items} total=${r.total}" : "错误=${r.errorCode} ${r.errorText}"}'
    '  ${r.ms}ms',
  );
  if (r.ok) {
    print('[r441]      keys=${r.keys}');
    for (final s in r.sample) {
      print('[r441]      · $s');
    }
  }
  return r;
}

void main() {
  test('r441 网络电台搜索：list/keyword vs list/text vs search（只读）', () async {
    if (url.isEmpty || account.isEmpty || password.isEmpty) {
      fail('缺 NAS_URL/NAS_ACCOUNT/NAS_PASSWORD（只从 --dart-define 来）');
    }
    final as = await connect();

    print('');
    print('[r441] ======== 基线与能力表 ========');
    final baseline =
        await probe(as, 'list 无参（根层容器）', 'list', 2, const {});
    for (final c in baseline.sample) {
      print('[r441]      容器: $c');
    }
    // 容器 id 逐字取自基线（不猜）。
    final containerIds = [
      for (final s in baseline.sample)
        RegExp(r'id=([^ ]+)').firstMatch(s)?.group(1) ?? '',
    ].where((s) => s.isNotEmpty).toList();
    print('[r441]      基线容器 id = $containerIds');

    for (final kw in keywords.split(',').where((s) => s.trim().isNotEmpty)) {
      print('');
      print('[r441] ======== 关键字「$kw」 ========');
      await probe(as, '$kw | list + keyword', 'list', 2, {'keyword': kw});
      await probe(as, '$kw | list + text', 'list', 2, {'text': kw});
      await probe(as, '$kw | search + keyword', 'search', 2, {'keyword': kw});
      await probe(as, '$kw | search + text', 'search', 2, {'text': kw});
      await probe(as, '$kw | search 无参（探参数必填）', 'search', 2, const {});
      await probe(as, '$kw | search v1（探版本）', 'search', 1, {'keyword': kw});
      if (containerIds.isNotEmpty) {
        await probe(
          as,
          '$kw | search + keyword + container=${containerIds.first}',
          'search',
          2,
          {'keyword': kw, 'container': containerIds.first},
        );
      }
      await probe(
        as,
        '$kw | search + keyword + offset/limit',
        'search',
        2,
        {'keyword': kw, 'offset': 0, 'limit': 5},
      );
      await probe(
        as,
        '$kw | list + keyword + offset/limit',
        'list',
        2,
        {'keyword': kw, 'offset': 0, 'limit': 5},
      );
    }
  }, timeout: const Timeout(Duration(minutes: 8)));
}
