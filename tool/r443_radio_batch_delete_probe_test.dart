// **r443** · 网络电台「批量删除」的**契约探针**（写动词**有界**：只动自己建的
// `r443probe*` 临时电台，收尾删净）。
//
// 背景（`docs/android-remaining-todo-r418.md` §二-3「电台批量删除（UI）」）：
// 服务端形态 r401 已**顺带**读到一条（`updateradios {offset:0, limit:<n>,
// radios_json:'[]'}` 一次清空 26 条），但"多选删除"在 UI 里真的落地前必须把
// **契约**量清（不许拿顺带读数当契约）：
//   ① 一次调用删**一段连续多行**：`{offset, limit:n, radios_json:'[]'}` 是否真删 n 行？
//   ② 删完之后**后面的行号会不会前移**（⇒ 多段删除必须**从高往低**做）？
//   ③ 非连续多选（多段）逐段删，最终留下的**是不是原来那些**（不误删邻居）？
//   ④ `limit` 超出实际行数会怎样（钳制 / 报错 / 多删）？
//   ⑤ 空段（`limit:0`）会不会反而把整段清空（r399 的"键名错=静默清空"同族风险）？
//
// **写动词清单（本探针内，全部收尾还原）**：
//   * `Radio/add` ×7（名字前缀 `r443probe`，只建自己建的）
//   * `Radio/updateradios` ×7（只写这两段临时电台）
//   * 收尾断死：`UserDefined` 的 `total` 回到 T0 且前缀命中 **0**
// 凭据只从 `--dart-define` 来（`~/.synhub-nas.env`，仓库外）：
//   set -a; . ~/.synhub-nas.env; set +a
//   flutter test tool/r443_radio_batch_delete_probe_test.dart \
//     --dart-define=NAS_URL="$SYNO_NAS_URL" --dart-define=NAS_ACCOUNT="$SYNO_NAS_ACCOUNT" \
//     --dart-define=NAS_PASSWORD="$SYNO_NAS_PASSWORD"
// ignore_for_file: avoid_print
import 'package:flutter_test/flutter_test.dart';
import 'package:synhub/src/core/net/dio_factory.dart';
import 'package:synhub/src/data/audio_station.dart';
import 'package:synhub/src/data/dto/audio_station_dto.dart';
import 'package:synhub/src/dsm/webapi.dart';

const String url = String.fromEnvironment('NAS_URL');
const String account = String.fromEnvironment('NAS_ACCOUNT');
const String password = String.fromEnvironment('NAS_PASSWORD');
const String prefix = 'r443probe';

Future<AudioStationApi> connect() async {
  final api = DsmWebApi(
    DirectTransport.url(url, dio: DioFactory.create(allowSelfSigned: true)),
  );
  await api.discover();
  await api.login(account: account, password: password, session: 'AudioStation');
  print('[r443] 已登录 $url as $account');
  return AudioStationApi(api);
}

/// 读 `UserDefined` 这一层的**服务端行序**（`container` = `UserDefined`）。
Future<List<AudioRadioDto>> rows(AudioStationApi as, {String? label}) async {
  final page = await as.listRadios(
    container: AudioRadioDto.containerUserDefined,
    offset: 0,
    limit: 500,
  );
  if (label != null) {
    print('[r443] $label total=${page.total} 行=[${page.items.map((r) => r.title).join(' | ')}]');
  }
  return page.items;
}

int probeCount(List<AudioRadioDto> items) =>
    items.where((r) => r.title.startsWith(prefix)).length;

/// **兜底清理**：把 `r443probe*` 的行**从高往低**逐条删净。
///
/// ★ r443 探针第 1 次运行在 D 段**中止**（`limit:0` ⇒ 服务端回 `101`），留下
/// 1 条残留；这个助手就是那一课：**探针必须自带收尾**（`addTearDown`），
/// 不许靠"跑得顺利"。
Future<int> cleanupProbes(AudioStationApi as, {required String label}) async {
  var removed = 0;
  while (true) {
    final items = await rows(as);
    var idx = -1;
    for (var i = items.length - 1; i >= 0; i--) {
      // ★ 空 `title` 的行也算（`E` 段证明：`Radio.add` 空名称会被服务端照收，
      //   而它**没有前缀**）；T0 已断言"本来没有任何空 title 行" ⇒ 扫它不会伤用户数据。
      if (items[i].title.startsWith(prefix) || items[i].title.trim().isEmpty) {
        idx = i;
        break;
      }
    }
    if (idx < 0) break;
    await as.updateRadios(
      container: AudioRadioDto.containerUserDefined,
      radiosJson: const [],
      offset: idx,
      limit: 1,
    );
    removed++;
  }
  print('[r443] cleanup($label) 删掉 $removed 条');
  return removed;
}

Future<void> addProbe(AudioStationApi as, int n) async {
  await as.addRadio(
    container: AudioRadioDto.containerUserDefined,
    title: '$prefix-$n',
    url: 'https://example.invalid/$prefix/$n',
    desc: 'r443 probe',
  );
}

/// 段替换：把 `[offset, offset+limit)` 换成 [radiosJson]（这里恒为空 ⇒ 删除）。
Future<void> replaceRange(
  AudioStationApi as, {
  required int offset,
  required int limit,
  required String label,
}) async {
  await as.updateRadios(
    container: AudioRadioDto.containerUserDefined,
    radiosJson: const [],
    offset: offset,
    limit: limit,
  );
  print('[r443] 段替换 $label ⇒ {offset:$offset, limit:$limit, radios_json:"[]"} 已发');
}

void main() {
  test('r443 电台批量删除契约探针', () async {
    expect(url, isNotEmpty, reason: '必须给 --dart-define=NAS_URL');
    final as = await connect();

    // ★ 兜底：任何中途失败都不许留残留（addTearDown 在断言失败后也会跑）。
    addTearDown(() async => cleanupProbes(as, label: 'tearDown 兜底'));

    // ---------- T0：基线（先清掉上一次中止留下的残留，如实登记） ----------
    await cleanupProbes(as, label: 'T0 前置');
    final t0 = await rows(as, label: 'T0 基线');
    expect(probeCount(t0), 0, reason: 'T0 不许已经有 r443probe* 残留');
    expect(t0.every((r) => r.title.trim().isNotEmpty), isTrue,
        reason: '★ T0 不许本来就有"空名称"行 —— 这是 tearDown 敢扫空 title 行的前置');
    final base = t0.length;
    print('[r443] T0 total=$base');

    // ---------- A：一次调用删**连续 3 行** ----------
    for (var i = 1; i <= 3; i++) {
      await addProbe(as, i);
    }
    final a1 = await rows(as, label: 'A1 建 3 条后');
    expect(a1.length, base + 3, reason: 'Radio.add 应逐条追加');
    expect(probeCount(a1), 3);
    // 这 3 条是**追加**的 ⇒ 段起点 = base（服务端行号相对容器）。
    final firstIdx = a1.indexWhere((r) => r.title == '$prefix-1');
    print('[r443] A 段起点 = $firstIdx（期望 $base）');
    await replaceRange(as, offset: firstIdx, limit: 3, label: 'A 连续 3 行');
    final a2 = await rows(as, label: 'A2 连续 3 行删后');
    print('[r443] A2 ⇒ total=${a2.length}（T0=$base） 前缀命中=${probeCount(a2)}');
    expect(probeCount(a2), 0, reason: 'limit=3 + 空 radios_json 应一次删掉 3 行');
    expect(a2.length, base, reason: 'A 之后应回到 T0');

    // ---------- B：多段（非连续）删除 —— 行号前移验证 ----------
    for (var i = 1; i <= 3; i++) {
      await addProbe(as, i);
    }
    final b1 = await rows(as, label: 'B1 建 3 条后');
    final i1 = b1.indexWhere((r) => r.title == '$prefix-1');
    final i2 = b1.indexWhere((r) => r.title == '$prefix-2');
    final i3 = b1.indexWhere((r) => r.title == '$prefix-3');
    print('[r443] B 行号 = $i1 / $i2 / $i3（期望连续且以 $base 起）');
    expect([i2, i3], [i1 + 1, i1 + 2], reason: '追加的三条必须连续');
    // 多选 = 第 1、3 条（两段），按"从高往低"删：先 offset=i3，再 offset=i1。
    await replaceRange(as, offset: i3, limit: 1, label: 'B 先删高位第 3 条');
    await replaceRange(as, offset: i1, limit: 1, label: 'B 再删低位第 1 条');
    final b2 = await rows(as, label: 'B2 两段删后');
    print('[r443] B2 ⇒ total=${b2.length} 前缀命中=${probeCount(b2)} '
        '残留=[${b2.where((r) => r.title.startsWith(prefix)).map((r) => r.title).join(' | ')}]');
    expect(probeCount(b2), 1, reason: '两段删除后应只剩中间那条（证明行号未误伤邻居）');
    expect(b2.where((r) => r.title.startsWith(prefix)).single.title, '$prefix-2',
        reason: '留下的必须正是**没被选**的那条');
    // 收尾：删掉剩下那条（它就是 base 位置上唯一一条）。
    await replaceRange(as, offset: i1, limit: 1, label: 'B 收尾删中间那条');
    final b3 = await rows(as, label: 'B3 删净后');
    expect(probeCount(b3), 0);
    expect(b3.length, base);

    // ---------- C：`limit` 超出实际行数 ----------
    for (var i = 1; i <= 2; i++) {
      await addProbe(as, i);
    }
    final c1 = await rows(as, label: 'C1 建 2 条后');
    final cStart = c1.indexWhere((r) => r.title == '$prefix-1');
    await replaceRange(as, offset: cStart, limit: 99, label: 'C limit=99（越界）');
    final c2 = await rows(as, label: 'C2 越界删后');
    print('[r443] C2 ⇒ total=${c2.length}（T0=$base） 前缀命中=${probeCount(c2)}');
    expect(probeCount(c2), 0, reason: '越界 limit 应钳到末尾，不许报错');
    expect(c2.length, base,
        reason: '★ 关键判据：越界 limit 后**仍必须等于 T0** —— 若把前面的行也吃掉就会小于 T0');

    // ---------- D：`limit:0` 空段 ----------
    await addProbe(as, 9);
    final d1 = await rows(as, label: 'D1 建 1 条后');
    final dIdx = d1.indexWhere((r) => r.title == '$prefix-9');
    DsmApiException? emptySegErr;
    try {
      await replaceRange(as, offset: dIdx, limit: 0, label: 'D limit=0 空段');
    } on DsmApiException catch (e) {
      emptySegErr = e;
    }
    print('[r443] D 空段 ⇒ code=${emptySegErr?.code} method=${emptySegErr?.method} '
        '文案=${emptySegErr == null ? "" : DsmErrorCode.describe(emptySegErr.code, method: emptySegErr.method)}');
    expect(emptySegErr, isNotNull,
        reason: '★ 真机读数：`limit:0` **不是**"空段替换"而是**被服务端拒**（r399 的'
            '"键名错=静默清空"在这里不成立）');
    final d2 = await rows(as, label: 'D2 空段被拒后');
    print('[r443] D2 ⇒ total=${d2.length}（期望 ${base + 1}） 前缀命中=${probeCount(d2)}');
    expect(probeCount(d2), 1,
        reason: '★ 关键反向断言：空段被拒后那条**必须还在**（不许静默删掉）');
    await replaceRange(as, offset: dIdx, limit: 1, label: 'D 收尾删净');

    // ---------- E：`Radio.add` 参数不合法时回什么码（101 的第二个含义） ----------
    final e0 = await rows(as, label: 'E0 新建前');
    DsmApiException? addErr;
    try {
      await as.addRadio(
        container: AudioRadioDto.containerUserDefined,
        title: '',
        url: '',
        desc: '',
      );
    } on DsmApiException catch (e) {
      addErr = e;
    }
    final e1 = await rows(as, label: 'E1 空名称新建后');
    print('[r443] E `Radio.add`{title:"", url:""} ⇒ 异常=${addErr == null ? "无" : addErr.code}'
        ' / total ${e0.length} → ${e1.length}');
    for (final r in e1.where((r) => r.title.trim().isEmpty)) {
      print('[r443] E 死行字段 id="${r.id}" title="${r.title}" url="${r.url}" '
          'desc="${r.desc}" type=${r.type}');
    }
    // ★★ 这一条是**新缺陷候选**（`DA97`）：服务端**不校验**，我们 UI 也必须拦。
    expect(addErr, isNull,
        reason: '真机读数：空名称/空 URL 的 `Radio.add` **不报错**（服务端照收）');
    expect(e1.length, e0.length + 1,
        reason: '★ 真机读数：空名称新建会**真的多出一行**（没有名字、没有 url 的死行）');
    final dead = e1.where((r) => r.title.trim().isEmpty).toList();
    expect(dead.length, 1, reason: '那一行的 title 为空');
    expect(dead.single.url, isEmpty, reason: '那一行的 url 也为空（点了也播不了）');
    // 清理这一行（它是本探针造的；T0 已断言没有空 title 行）。
    final deadIdx = e1.indexWhere((r) => r.title.trim().isEmpty);
    await replaceRange(as, offset: deadIdx, limit: 1, label: 'E 删掉死行');
    final e2 = await rows(as, label: 'E2 删死行后');
    expect(e2.length, e0.length, reason: 'E 之后行数必须回到新建前');
    await cleanupProbes(as, label: 'E 后兜底');

    // ---------- 收尾断死 ----------
    final end = await rows(as, label: '收尾');
    print('[r443] 收尾 total=${end.length} 前缀命中=${probeCount(end)}');
    expect(probeCount(end), 0, reason: '收尾必须零残留');
    expect(end.length, base, reason: '收尾 total 必须回到 T0=$base');
  }, timeout: const Timeout(Duration(minutes: 6)));
}
