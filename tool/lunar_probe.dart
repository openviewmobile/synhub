import 'package:lunar/lunar.dart';

void main() {
  for (final ymd in ['2026-02-17', '2026-04-05', '2026-10-01', '2025-10-06']) {
    final p = ymd.split('-').map(int.parse).toList();
    final solar = Solar.fromYmd(p[0], p[1], p[2]);
    final lunar = solar.getLunar();
    print(
      '$ymd 农历=${lunar.getYearInChinese()}-${lunar.getMonthInChinese()}-${lunar.getDayInChinese()} '
      '| 农历节日=${lunar.getFestivals()} 公历节日=${solar.getFestivals()} 其他=${lunar.getOtherFestivals()}',
    );
    final jq = lunar.getJieQiTable();
    final hit = jq.entries
        .where((e) => e.value.toYmd() == ymd)
        .map((e) => e.key)
        .toList();
    print('   节气=$hit');
  }
  print('--- 2026 法定节假日（HolidayUtil）');
  final list = HolidayUtil.getHolidaysByYear(2026);
  print('条数=${list.length}');
  for (final h in list.take(30)) {
    print(
      '   ${h.getDay()} ${h.getName()} 上班=${h.isWork()} 关联=${h.getTarget()}',
    );
  }
  print('--- 2025 条数=${HolidayUtil.getHolidaysByYear(2025).length}');
}
