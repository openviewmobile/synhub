// **r443** · 电台「多选批量删除」的**真机夹具**（真 NAS 有界写，三段式）。
//
// 为什么单独一个探针：批量删除的**动作**要在真机 App 界面上做（那才是被验的对象），
// 而"先造出几条能被删的电台"和"删完回读服务端"这两件事必须在宿主侧做 ——
// 否则就得在真机上手打三条 URL（打字与取证混在一起，读数就脏了）。
//
// 用法（`ACTION` 三档，默认 `readback` = **只读**）：
//   set -a; . ~/.synhub-nas.env; set +a
//   flutter test tool/r443_ui_fixture_probe_test.dart \
//     --dart-define=NAS_URL="$SYNO_NAS_URL" --dart-define=NAS_ACCOUNT="$SYNO_NAS_ACCOUNT" \
//     --dart-define=NAS_PASSWORD="$SYNO_NAS_PASSWORD" --dart-define=ACTION=setup
//
//   * `setup`    ：建 3 条 `r443ui-1/2/3`（`Radio/add`，只建这个前缀）
//   * `readback` ：**只读**打印 `UserDefined` 逐行（`id`/`title`/`url`）＋ 前缀命中
//   * `cleanup`  ：把 `r443ui*` 行**从高往低**删净，收尾断死残留 = 0
//
// ★ 写动词只在 `setup`/`cleanup` 两档发生；`readback` 恒零写（§5.1 要能逐笔对上）。
// ignore_for_file: avoid_print
import 'package:flutter_test/flutter_test.dart';
import 'package:synhub/src/core/net/dio_factory.dart';
import 'package:synhub/src/data/audio_station.dart';
import 'package:synhub/src/data/dto/audio_station_dto.dart';
import 'package:synhub/src/dsm/webapi.dart';

const String url = String.fromEnvironment('NAS_URL');
const String account = String.fromEnvironment('NAS_ACCOUNT');
const String password = String.fromEnvironment('NAS_PASSWORD');
const String action = String.fromEnvironment('ACTION', defaultValue: 'readback');
const String prefix = 'r443ui';

Future<AudioStationApi> connect({required bool write}) async {
  final api = DsmWebApi(
    DirectTransport.url(url, dio: DioFactory.create(allowSelfSigned: true)),
  );
  await api.discover();
  await api.login(account: account, password: password, session: 'AudioStation');
  print('[r443ui] 已登录 $url as $account（ACTION=$action，写动词=${write ? "允许" : "禁止"}）');
  return AudioStationApi(api);
}

Future<List<AudioRadioDto>> rows(AudioStationApi as, {String? label}) async {
  final page = await as.listRadios(
    container: AudioRadioDto.containerUserDefined,
    offset: 0,
    limit: 200,
  );
  if (label != null) {
    print('[r443ui] $label total=${page.total}');
    for (var i = 0; i < page.items.length; i++) {
      final r = page.items[i];
      print('[r443ui]   行[$i] id="${r.id}" title="${r.title}" url="${r.url}" type=${r.type}');
    }
    final hits = page.items.where((r) => r.title.startsWith(prefix)).toList();
    print('[r443ui] $label 前缀 `$prefix` 命中=${hits.length} '
        '[${hits.map((r) => r.title).join(' | ')}]');
  }
  return page.items;
}

void main() {
  test('r443 真机夹具：$action', () async {
    expect(url, isNotEmpty, reason: '必须给 --dart-define=NAS_URL');
    final as = await connect(write: action != 'readback');
    final before = await rows(as, label: 'T0');

    switch (action) {
      case 'setup':
        expect(before.where((r) => r.title.startsWith(prefix)), isEmpty,
            reason: 'T0 不许已有 $prefix* 残留');
        for (var i = 1; i <= 3; i++) {
          await as.addRadio(
            container: AudioRadioDto.containerUserDefined,
            title: '$prefix-$i',
            url: 'https://example.invalid/$prefix/$i',
            desc: 'r443 ui fixture',
          );
          print('[r443ui] setup `Radio/add` title=$prefix-$i url=https://example.invalid/$prefix/$i');
        }
        final after = await rows(as, label: 'setup 后');
        expect(after.length, before.length + 3);
        expect(after.where((r) => r.title.startsWith(prefix)).length, 3);
      case 'cleanup':
        var removed = 0;
        while (true) {
          final items = await rows(as);
          var idx = -1;
          for (var i = items.length - 1; i >= 0; i--) {
            if (items[i].title.startsWith(prefix)) {
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
          print('[r443ui] cleanup `updateradios` {offset:$idx, limit:1, radios_json:"[]"}');
          removed++;
        }
        final end = await rows(as, label: 'cleanup 后');
        print('[r443ui] cleanup 删掉 $removed 条');
        expect(end.where((r) => r.title.startsWith(prefix)), isEmpty);
        expect(end.length, before.length - removed + 0, reason: '收尾必须可对账');
      default:
        // 只读档：写动词一处都不许出现。
        print('[r443ui] readback = 只读（零写动词）');
    }
  }, timeout: const Timeout(Duration(minutes: 5)));
}
