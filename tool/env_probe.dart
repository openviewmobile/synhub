// 环境信息**联网**探针：真网络 + 真农历跑一遍天气/节假日/地理编码，用来抓 JSON 形状错。
//
// 这是"活体"探针，需要外网，所以放在 `tool/` 下、**不进默认测试套件**；
// 用法：flutter test tool/env_probe.dart
// ignore_for_file: avoid_print
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:synhub/src/data/holidays/holiday_service.dart';
import 'package:synhub/src/data/region/geocode_client.dart';
import 'package:synhub/src/data/region/region_context.dart';
import 'package:synhub/src/data/weather/weather_client.dart';

void main() {
  setUpAll(() => HttpOverrides.global = null);
  test('live: 天气 / 节假日 / 地理编码', () async {
    print('==== 单位制（按地区自动）');
    for (final cc in ['US', 'GB', 'CN', 'JP', 'DE', 'RU', 'LR', 'MM', 'FR']) {
      final u = weatherUnitsFor(cc);
      print(
        '  $cc ${unitSystemFor(cc).label} 温度=${u.temperatureLabel} 风=${u.wind.label} '
        '降水=${u.precipitationLabel} 气压=${u.pressureLabel} 能见=${u.visibilityLabel}',
      );
    }
    print(
      '  风速换算 20km/h → '
      '${weatherUnitsFor('CN').windText(20)} / ${weatherUnitsFor('US').windText(20)} / ${weatherUnitsFor('JP').windText(20)}',
    );

    print('==== 时区兜底');
    for (final tz in [
      'Asia/Shanghai',
      'America/New_York',
      'Europe/Berlin',
      'Australia/Sydney',
      'Etc/Unknown',
    ]) {
      print('  $tz → ${countryFromTimezone(tz)}');
    }

    print('==== 正查/反查');
    final geo = GeocodeClient();
    final hits = await geo.search('北京');
    print('  正查 北京 → ${hits.map((h) => h.label).join(' / ')}');
    final rev = await geo.reverse(latitude: 37.7749, longitude: -122.4194);
    print('  反查 旧金山 → ${rev.label} tz=${rev.timezone}');

    print('==== 天气');
    final w = WeatherClient();
    for (final probe in [
      ('open-meteo', '北京', 39.9042, 116.4074),
      ('nws', '纽约', 40.7128, -74.0060),
      ('met-no', '奥斯陆', 59.9139, 10.7522),
      ('wttr', '上海', 31.2304, 121.4737),
    ]) {
      final info = weatherProviderById(probe.$1)!;
      try {
        final b = await w.fetch(
          provider: info,
          latitude: probe.$3,
          longitude: probe.$4,
          days: 3,
        );
        final now = b.now;
        print(
          '  ${probe.$2} via ${probe.$1}: ${now?.text()} ${now?.temperatureC}°C '
          '体感=${now?.apparentC} 湿度=${now?.humidity}% 风=${now?.windKmh}km/h ${now?.windDir} '
          '气压=${now?.pressureHpa} 能见=${now?.visibilityKm} tz=${now?.timezone}',
        );
        for (final d in b.days.take(3)) {
          print(
            '     ${d.date.toIso8601String().substring(0, 10)} ${wmoText(d.code)} '
            '${d.minC}~${d.maxC}°C 降水=${d.precipitationMm} 日出=${d.sunrise}',
          );
        }
      } catch (e) {
        print('  ${probe.$2} via ${probe.$1} 失败: $e');
      }
    }

    print('==== 节假日');
    final h = HolidayService();
    for (final p in [
      ('CN', 2026, ''),
      ('DE', 2026, 'DE-BY'),
      ('US', 2026, ''),
      ('TW', 2026, ''),
      ('GB', 2026, ''),
    ]) {
      try {
        final b = await h.load(
          countryCode: p.$1,
          year: p.$2,
          subdivisionCode: p.$3,
        );
        print(
          '  ${p.$1}${p.$3.isEmpty ? '' : '/${p.$3}'} ${p.$2}: ${b.entries.length} 条 '
          '来源=${b.sources} 说明=${b.note}',
        );
        for (final e in b.entries.where((e) => e.date.year == 2026).take(6)) {
          print(
            '     ${e.date.toIso8601String().substring(0, 10)} ${e.kind.label} ${e.name}',
          );
        }
        // 关键抽查
        final national = b.entries.where((e) => e.name.contains('国庆')).toList();
        final qingming = b.entries.where((e) => e.name.contains('清明')).toList();
        print('     国庆=${national.length} 清明=${qingming.length}');
      } catch (e) {
        print('  ${p.$1} 失败: $e');
      }
    }

    print('==== 农历格子标签');
    for (final d in [
      DateTime(2026, 2, 17),
      DateTime(2026, 4, 5),
      DateTime(2026, 9, 25),
      DateTime(2026, 10, 1),
      DateTime(2026, 3, 3),
    ]) {
      final i = ChineseCalendar.infoFor(d);
      print(
        '  ${d.toIso8601String().substring(0, 10)} ${i.lunarMonthDay} 标签=${i.label} '
        '(${i.labelKind.label}) 法定=${i.isOfficialHoliday} 调休上班=${i.isWorkday} ${i.officialName}',
      );
    }
  });
}
