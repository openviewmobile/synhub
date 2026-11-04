// 节假日：**国际节假日走网络、传统/农历走离线**，两边合一份给日历用。
//
// 为什么必须双轨（调研实测的结论，别推翻）：
//   * **Nager.Date**（`date.nager.at`）204 国、免 key、MIT，但**中国缺清明节**
//     （它只有 1/1、春节、5/1、10/1），且**不支持** IN/TW/TH/SA/IL/MY/MO（回 204）。
//   * **OpenHolidays**（`openholidaysapi.org`）只有 36 个欧洲国家，但**带州/省级**
//     （`subdivisionCode=DE-BY`），不支持的国家回 200 + `[]`。
//   * **农历/节气/中国法定调休** 只有本地算得准：`lunar` 包（MIT，纯 Dart）里有
//     `HolidayUtil` 的中国法定节假日表（含**调休上班**，实测 2026 年 39 条齐全）。
//   * 因此：**网络拿"公历法定假日"，离线拿"农历/节气/调休"**，合并展示；
//     覆盖不到的国家**如实说明**，绝不编造日期。
//
// 另一个必须记住的点：宗教节日（开斋节、排灯节…）是按**观月/地方宣布**定的，
// 历法换算与官方公告会差 1~2 天 → 这类一律标 `approximate`，UI 显示「预计」。
import 'dart:convert';

import 'package:dio/dio.dart';
import '../../core/net/traffic_meter.dart';
import 'package:flutter/foundation.dart';
import 'package:lunar/lunar.dart' as lunar_pkg;

import '../../core/i18n/data_text.dart';

/// 节假日类型（决定配色与是否放假）
enum HolidayKind {
  public('public', '法定节假日'),
  traditional('traditional', '传统节日'),
  solarTerm('solarTerm', '节气'),
  observance('observance', '纪念日'),
  workday('workday', '调休上班'),
  religious('religious', '宗教节日');

  const HolidayKind(this.id, this.label);

  final String id;

  /// 中文回落（界面侧读 [labelText]；`lib/src/features/**` 本轮不在迁移范围内）
  final String label;

  /// ARB key（多语言用；数据层不能碰 `AppText`）
  String get labelKey => switch (this) {
    HolidayKind.public => 'holidayKindPublic',
    HolidayKind.traditional => 'holidayKindTraditional',
    HolidayKind.solarTerm => 'holidayKindSolarTerm',
    HolidayKind.observance => 'holidayKindObservance',
    HolidayKind.workday => 'holidayKindWorkday',
    HolidayKind.religious => 'holidayKindReligious',
  };

  /// 当前语言文案（走 `data_text.dart` 的 [dataText]；没装翻译器时回落 [label]）
  String labelText() => dataText(labelKey, label);

  bool get isDayOff =>
      this != HolidayKind.workday && this != HolidayKind.observance;
}

/// 一条节假日
@immutable
class HolidayEntry {
  const HolidayEntry({
    required this.date,
    required this.name,
    required this.kind,
    required this.source,
    this.subdivisionCode = '',
    this.approximate = false,
  });

  final DateTime date;
  final String name;
  final HolidayKind kind;

  /// `nager` / `openholidays` / `lunar` / `builtin`
  final String source;
  final String subdivisionCode;

  /// 日期为历法换算/预计（宗教节日）→ UI 标「预计」
  final bool approximate;

  /// 界面显示名（把已知节日归一到当前语言；认不出的服务端原文原样返回）
  String get displayName => holidayNameText(name);

  String get key => '${date.year}-${date.month}-${date.day}|$name';

  HolidayEntry copyWith({HolidayKind? kind, bool? approximate}) => HolidayEntry(
    date: date,
    name: name,
    kind: kind ?? this.kind,
    source: source,
    subdivisionCode: subdivisionCode,
    approximate: approximate ?? this.approximate,
  );

  Map<String, Object?> toJson() => {
    'date':
        '${date.year}-${date.month.toString().padLeft(2, '0')}-'
        '${date.day.toString().padLeft(2, '0')}',
    'name': name,
    'kind': kind.id,
    'source': source,
    if (subdivisionCode.isNotEmpty) 'subdivisionCode': subdivisionCode,
    if (approximate) 'approximate': true,
  };

  static HolidayEntry? fromJson(Map<String, Object?> json) {
    final date = DateTime.tryParse('${json['date'] ?? ''}');
    final name = '${json['name'] ?? ''}';
    if (date == null || name.isEmpty) return null;
    return HolidayEntry(
      date: date,
      name: name,
      kind: HolidayKind.values.firstWhere(
        (k) => k.id == json['kind'],
        orElse: () => HolidayKind.public,
      ),
      source: '${json['source'] ?? ''}',
      subdivisionCode: '${json['subdivisionCode'] ?? ''}',
      approximate: json['approximate'] == true,
    );
  }
}

/// 一年的节假日（含来源说明）
@immutable
class HolidayBundle {
  const HolidayBundle({
    required this.countryCode,
    required this.year,
    required this.entries,
    required this.sources,
    this.note = '',
    this.fetchedAt,
  });

  final String countryCode;
  final int year;
  final List<HolidayEntry> entries;
  final List<String> sources;

  /// 面向用户的一句说明（"这个国家/地区暂无公开数据源"等）
  final String note;
  final DateTime? fetchedAt;

  bool get isEmpty => entries.isEmpty;

  /// 某天全部条目（法定优先、调休在后）
  List<HolidayEntry> on(DateTime date) {
    final out = entries
        .where(
          (e) =>
              e.date.year == date.year &&
              e.date.month == date.month &&
              e.date.day == date.day,
        )
        .toList();
    out.sort((a, b) {
      final p = _priority(a.kind).compareTo(_priority(b.kind));
      return p != 0 ? p : a.name.compareTo(b.name);
    });
    return out;
  }

  /// 某天的主标题（法定 > 传统 > 节气 > 纪念）
  HolidayEntry? primaryOn(DateTime date) {
    final list = on(date);
    return list.isEmpty ? null : list.first;
  }

  static int _priority(HolidayKind kind) => switch (kind) {
    HolidayKind.public => 0,
    HolidayKind.workday => 1,
    HolidayKind.traditional => 2,
    HolidayKind.solarTerm => 3,
    HolidayKind.religious => 4,
    HolidayKind.observance => 5,
  };

  Map<String, Object?> toJson() => {
    'countryCode': countryCode,
    'year': year,
    'sources': sources,
    'note': note,
    'entries': [for (final e in entries) e.toJson()],
  };

  static HolidayBundle fromJson(Map<String, Object?> json) {
    final raw = json['entries'];
    final entries = <HolidayEntry>[];
    if (raw is List) {
      for (final one in raw) {
        if (one is Map) {
          final e = HolidayEntry.fromJson(one.map((k, v) => MapEntry('$k', v)));
          if (e != null) entries.add(e);
        }
      }
    }
    final sources = json['sources'];
    return HolidayBundle(
      countryCode: '${json['countryCode'] ?? ''}',
      year: (json['year'] as num?)?.toInt() ?? 0,
      entries: entries,
      sources: sources is List ? [for (final s in sources) '$s'] : const [],
      note: '${json['note'] ?? ''}',
    );
  }
}

/// 数据源选择（顺序即优先级）
enum HolidaySource {
  openHolidays('openholidays', 'OpenHolidays（欧洲，含州/省）'),
  nager('nager', 'Nager.Date（全球 204 国）'),
  lunar('lunar', '本地农历（传统节日/节气/中国调休）');

  const HolidaySource(this.id, this.label);

  final String id;

  /// 中文回落（界面侧读 [labelText]；`lib/src/features/**` 本轮不在迁移范围内）
  final String label;

  /// ARB key（多语言用；数据层不能碰 `AppText`）
  String get labelKey => switch (this) {
    HolidaySource.openHolidays => 'holidaySourceOpenHolidays',
    HolidaySource.nager => 'holidaySourceNager',
    HolidaySource.lunar => 'holidaySourceLunar',
  };

  /// 当前语言文案（走 `data_text.dart` 的 [dataText]；没装翻译器时回落 [label]）
  String labelText() => dataText(labelKey, label);

  /// 由服务端/聚合器给的**原始 id** 反查枚举（例：`'nager'`）。
  ///
  /// ★★★ D70（r349 真机像素）：节假日来源行原本把**原始 id 直接画给用户**
  /// （像素实测 `节假日 nager+lunar`），而 `labelText()` 明明已经存在、
  /// ARB 键中英文齐全、**却一个调用点都没有** —— 同一行里**天气源**走的是
  /// 本地化名字（`provider.nameText()`），节假日源却走 id，
  /// 这就是 §2.0.26 的"同一语义被造成两份表示"＋§2.0.57 的"封装了没有 caller"。
  ///
  /// 认不出的 id 返回 `null`，由调用方**原样显示**（不编造名字，见 §2.0.12 的口径）。
  static HolidaySource? fromId(String id) {
    for (final s in values) {
      if (s.id == id) return s;
    }
    return null;
  }

  /// 把聚合器给的 **id 列表**渲染成用户可读的来源名（`'nager','lunar'`
  /// → `Nager.Date（全球 204 国） + 本地农历（传统节日/节气/中国调休）`）。
  ///
  /// ★ 这是**唯一实现**：界面**不许**再自己去 `join('+')` 原始 id
  /// （D70 就是这么来的 —— 同一行里天气源走本地化、节假日源走 id）。
  /// 认不出的 id **原样保留**：宁可显示一个陌生代号，也不许把来源悄悄吞掉。
  static String sourceLabels(Iterable<String> ids) =>
      ids.map((s) => fromId(s)?.labelText() ?? s).join(' + ');
}

/// OpenHolidays 只覆盖这些国家（欧洲 36 国，实测不含 GB）
const Set<String> kOpenHolidaysCountries = {
  'AT',
  'BE',
  'BG',
  'CH',
  'CY',
  'CZ',
  'DE',
  'DK',
  'EE',
  'ES',
  'FI',
  'FR',
  'GR',
  'HR',
  'HU',
  'IE',
  'IS',
  'IT',
  'LI',
  'LT',
  'LU',
  'LV',
  'MT',
  'NL',
  'NO',
  'PL',
  'PT',
  'RO',
  'SE',
  'SI',
  'SK',
};

/// 用农历传统节日的国家/地区（华人文化圈）
const Set<String> kLunarCountries = {'CN', 'HK', 'MO', 'TW', 'SG', 'MY'};

/// 按国家/地区给出数据源顺序
List<HolidaySource> holidaySourcesFor(String countryCode) {
  final cc = countryCode.toUpperCase();
  final out = <HolidaySource>[];
  if (kOpenHolidaysCountries.contains(cc)) out.add(HolidaySource.openHolidays);
  if (cc.isNotEmpty) out.add(HolidaySource.nager);
  if (kLunarCountries.contains(cc) || cc.isEmpty) out.add(HolidaySource.lunar);
  return out;
}

class HolidayService {
  HolidayService({
    Dio? dio,
    Map<String, HolidayBundle>? cache,
    this.nagerBase = kNagerBase,
    this.openHolidaysBase = kOpenHolidaysBase,
  }) : _dio = tagDioWithModule(
         dio ??
             Dio(
               BaseOptions(
                 connectTimeout: const Duration(seconds: 10),
                 receiveTimeout: const Duration(seconds: 15),
                 validateStatus: (_) => true,
               ),
             ),
         TrafficModules.calendar,
       ),
       _cache = cache ?? <String, HolidayBundle>{};

  final Dio _dio;
  final Map<String, HolidayBundle> _cache;

  /// base URL 覆盖（测试用本机桩；默认是线上地址）
  final String nagerBase;
  final String openHolidaysBase;

  static const String kNagerBase = 'https://date.nager.at/api/v3';
  static const String kOpenHolidaysBase = 'https://openholidaysapi.org';

  /// 缓存有效期：节假日一年才变一次，12 小时足够（当天新增的调休公告也会跟上）
  static const Duration kTtl = Duration(hours: 12);

  String _key(String cc, String subdiv, int year, String lang) =>
      '${cc.toUpperCase()}|$subdiv|$year|$lang';

  /// 取一年的节假日。
  ///
  /// [allowNetwork] = false 时只用本地农历（离线场景/测试）。
  Future<HolidayBundle> load({
    required String countryCode,
    required int year,
    String subdivisionCode = '',
    String language = 'zh',
    bool allowNetwork = true,
    bool forceRefresh = false,
  }) async {
    final cc = countryCode.toUpperCase();
    final key = _key(cc, subdivisionCode, year, language);
    final cached = _cache[key];
    if (!forceRefresh &&
        cached != null &&
        cached.fetchedAt != null &&
        DateTime.now().difference(cached.fetchedAt!) < kTtl) {
      return cached;
    }
    final sourcesUsed = <String>[];
    final collected = <HolidayEntry>[];
    final notes = <String>[];

    for (final source in holidaySourcesFor(cc)) {
      if (source == HolidaySource.lunar) {
        // 农历只对华人文化圈有意义；其它国家不塞农历节日进去
        if (cc.isNotEmpty && !kLunarCountries.contains(cc)) continue;
        final list = ChineseCalendar.yearEntries(
          year,
          includeOfficial: cc == 'CN' || cc.isEmpty,
        );
        if (list.isNotEmpty) {
          collected.addAll(list);
          sourcesUsed.add(HolidaySource.lunar.id);
        }
        continue;
      }
      if (!allowNetwork) continue;
      try {
        final list = switch (source) {
          HolidaySource.nager => await _nager(cc, year),
          HolidaySource.openHolidays => await _openHolidays(
            cc,
            year,
            subdivisionCode,
            language,
          ),
          HolidaySource.lunar => const <HolidayEntry>[],
        };
        if (list.isNotEmpty) {
          collected.addAll(list);
          sourcesUsed.add(source.id);
        }
      } catch (e) {
        // 一个源挂了不能让整页没数据：记一句说明，继续用其它源
        notes.add(
          dataText('holidaySourceFailed', '{source} 取数失败：{error}')
              .replaceAll('{source}', source.labelText())
              .replaceAll('{error}', '$e'),
        );
      }
    }

    // 中国大陆：`HolidayUtil` 是官方表（含调休），网络源的英文条目在同一天让位，
    // 否则 10-01 会同时躺着"国庆节"和"National Day"
    final filtered = cc == 'CN'
        ? _dropNetworkDuplicatesOnLunarDays(collected)
        : collected;
    final merged = mergeHolidays(filtered);
    // 只有农历、没有任何法定假日源覆盖 → 如实说明（TW/IN/TH/SA/IL/MY/MO 实测
    // Nager 回 204、OpenHolidays 不含）
    final hasNetworkSource = sourcesUsed.any(
      (s) => s != HolidaySource.lunar.id,
    );
    if (!hasNetworkSource && cc.isNotEmpty && merged.isNotEmpty) {
      notes.add(
        dataText(
          'holidayNoPublicSource',
          '{cc} 没有公开的法定节假日数据源，这里只有农历与传统节日',
        ).replaceAll('{cc}', cc),
      );
    }
    if (merged.isEmpty && notes.isEmpty) {
      notes.add(
        cc.isEmpty
            ? dataText('holidayNoRegion', '还没有确定地区，先只显示农历信息')
            : dataText(
                'holidayNoSourceFor',
                '暂时没有 {country} 的公开节假日数据源',
              ).replaceAll('{country}', countryNameForNote(cc)),
      );
    }
    final bundle = HolidayBundle(
      countryCode: cc,
      year: year,
      entries: merged,
      sources: sourcesUsed,
      note: notes.join(dataText('holidayNoteSep', '；')),
      fetchedAt: DateTime.now(),
    );
    _cache[key] = bundle;
    return bundle;
  }

  /// 中国大陆专用：本地官方表（kind=public/workday）出现过的日子，
  /// 把网络源同一天的 public 条目丢掉（名字不同、指同一天）
  static List<HolidayEntry> _dropNetworkDuplicatesOnLunarDays(
    List<HolidayEntry> input,
  ) {
    final officialDays = <String>{
      for (final e in input)
        if (e.source == HolidaySource.lunar.id &&
            (e.kind == HolidayKind.public || e.kind == HolidayKind.workday))
          '${e.date.year}-${e.date.month}-${e.date.day}',
    };
    if (officialDays.isEmpty) return input;
    return [
      for (final e in input)
        if (e.source == HolidaySource.lunar.id ||
            e.kind != HolidayKind.public ||
            !officialDays.contains(
              '${e.date.year}-${e.date.month}-${e.date.day}',
            ))
          e,
    ];
  }

  /// 数据源优先级（合并同义节日时用）
  static int _sourceRank(String source) => switch (source) {
    'openholidays' => 0,
    'nager' => 1,
    'lunar' => 2,
    _ => 3,
  };

  /// 合并去重：**同一天同名只留一条**，并且优先级高的类型覆盖低的
  /// （例：Nager 的"农历新年"与本地"春节"同日 → 留法定那条）
  static List<HolidayEntry> mergeHolidays(List<HolidayEntry> input) {
    final byKey = <String, HolidayEntry>{};
    for (final e in input) {
      final existing = byKey[e.key];
      if (existing == null) {
        byKey[e.key] = e;
        continue;
      }
      final keep =
          HolidayBundle._priority(e.kind) <
              HolidayBundle._priority(existing.kind)
          ? e
          : existing;
      byKey[e.key] = keep;
    }
    // 同一天、同一类型、**指的是同一个节日的不同语言名字**（Neujahr / New Year's
    // Day）也要合并 —— 靠别名表判断，判不出来就都留着（宁可多一条，别丢真节日）。
    final byAlias = <String, HolidayEntry>{};
    final passthrough = <HolidayEntry>[];
    for (final e in byKey.values) {
      final alias = holidayAlias(e.name);
      if (alias.isEmpty) {
        passthrough.add(e);
        continue;
      }
      final k =
          '${e.date.year}-${e.date.month}-${e.date.day}|${e.kind.id}|$alias';
      final existing = byAlias[k];
      if (existing == null ||
          _sourceRank(e.source) < _sourceRank(existing.source)) {
        byAlias[k] = e;
      }
    }
    final out = [...passthrough, ...byAlias.values]
      ..sort((a, b) {
        final d = a.date.compareTo(b.date);
        return d != 0 ? d : a.name.compareTo(b.name);
      });
    return out;
  }

  // ------------------------------------------------------------------ Nager

  Future<List<HolidayEntry>> _nager(String cc, int year) async {
    if (cc.isEmpty) return const [];
    final res = await _get('$nagerBase/PublicHolidays/$year/$cc');
    if (res.statusCode == 204) return const [];
    final list = _decodeList(res);
    final out = <HolidayEntry>[];
    for (final one in list) {
      final date = DateTime.tryParse('${one['date'] ?? ''}');
      if (date == null) continue;
      final name = '${one['localName'] ?? one['name'] ?? ''}';
      if (name.isEmpty) continue;
      // types 里可能有 "Public"/"Bank"/"School"/"Optional"/"Observance"
      final types = one['types'];
      final isPublic =
          types is List && types.any((t) => '$t'.toLowerCase() == 'public');
      final counties = one['counties'];
      out.add(
        HolidayEntry(
          date: date,
          name: name,
          // `global=false` 且带 counties 的是"部分地区"：仍算法定，但注明
          kind: isPublic || types == null
              ? HolidayKind.public
              : HolidayKind.observance,
          source: HolidaySource.nager.id,
          subdivisionCode: counties is List && counties.isNotEmpty
              ? '${counties.first}'
              : '',
        ),
      );
    }
    return out;
  }

  // ------------------------------------------------------------ OpenHolidays

  Future<List<HolidayEntry>> _openHolidays(
    String cc,
    int year,
    String subdivisionCode,
    String language,
  ) async {
    if (!kOpenHolidaysCountries.contains(cc)) return const [];
    final res = await _get('$openHolidaysBase/PublicHolidays', {
      'countryIsoCode': cc,
      'validFrom': '$year-01-01',
      'validTo': '$year-12-31',
      'languageIsoCode': language == 'zh' ? 'EN' : language.toUpperCase(),
      if (subdivisionCode.isNotEmpty) 'subdivisionCode': subdivisionCode,
    });
    final list = _decodeList(res);
    final out = <HolidayEntry>[];
    for (final one in list) {
      final date = DateTime.tryParse('${one['startDate'] ?? ''}');
      if (date == null) continue;
      final names = one['name'];
      var name = '';
      if (names is List) {
        for (final n in names) {
          final text = '${(n as Map)['text'] ?? ''}';
          if (text.isNotEmpty) {
            name = text;
            break;
          }
        }
      }
      if (name.isEmpty) continue;
      final type = '${one['type'] ?? ''}'.toLowerCase();
      final kind = switch (type) {
        'public' => HolidayKind.public,
        'bank' ||
        'school' ||
        'authorities' ||
        'optional' => HolidayKind.observance,
        _ => HolidayKind.observance,
      };
      out.add(
        HolidayEntry(
          date: date,
          name: name,
          kind: kind,
          source: HolidaySource.openHolidays.id,
          subdivisionCode: '${one['subdivisionCode'] ?? ''}',
        ),
      );
    }
    return out;
  }

  // ------------------------------------------------------------------ 工具

  Future<Response<dynamic>> _get(
    String url, [
    Map<String, Object?>? query,
  ]) async {
    return _dio.get<dynamic>(
      url,
      queryParameters: query,
      options: Options(
        responseType: ResponseType.plain,
        headers: const {'Accept': 'application/json'},
      ),
    );
  }

  List<Map<String, dynamic>> _decodeList(Response<dynamic> res) {
    final code = res.statusCode ?? 0;
    if (code == 204) return const [];
    if (code < 200 || code >= 300) {
      throw StateError('HTTP $code');
    }
    final raw = res.data;
    Object? decoded = raw;
    if (raw is String) {
      if (raw.trim().isEmpty) return const [];
      decoded = jsonDecode(raw);
    }
    if (decoded is! List) return const [];
    return [
      for (final one in decoded)
        if (one is Map) one.map((k, v) => MapEntry('$k', v)),
    ];
  }
}

/// 节日别名：把不同语言的"同一个节日"归到同一个键上。
///
/// 只收**确定性高、跨源一定会撞**的那些（否则宁可不合并）：源之间的语言不同，
/// 靠字符串是配不上的（`Neujahr` vs `New Year's Day`）。
const Map<String, String> kHolidayAliases = {
  'new year': 'newyear',
  "new year's day": 'newyear',
  'neujahr': 'newyear',
  '元旦': 'newyear',
  '元旦节': 'newyear',
  'nouvel an': 'newyear',
  'año nuevo': 'newyear',
  'capodanno': 'newyear',
  'labour day': 'labour',
  'labor day': 'labour',
  '劳动节': 'labour',
  'tag der arbeit': 'labour',
  'staatsfeiertag': 'labour',
  'fête du travail': 'labour',
  'christmas day': 'christmas',
  'weihnachten': 'christmas',
  'weihnachtstag': 'christmas',
  '圣诞': 'christmas',
  '圣诞节': 'christmas',
  'noël': 'christmas',
  'navidad': 'christmas',
  'natale': 'christmas',
  'good friday': 'goodfriday',
  'karfreitag': 'goodfriday',
  '耶稣受难日': 'goodfriday',
  'easter monday': 'eastermonday',
  'ostermontag': 'eastermonday',
  'easter sunday': 'eastersunday',
  'ostersonntag': 'eastersunday',
  'national day': 'nationalday',
  '国庆节': 'nationalday',
  'mid-autumn festival': 'midautumn',
  '中秋节': 'midautumn',
  'dragon boat festival': 'dragonboat',
  '端午节': 'dragonboat',
  'qingming festival': 'qingming',
  'tomb-sweeping day': 'qingming',
  '清明节': 'qingming',
  'spring festival': 'springfestival',
  'chinese new year': 'springfestival',
  '春节': 'springfestival',
  'lunar new year': 'springfestival',
  'all saints day': 'allsaints',
  'allerheiligen': 'allsaints',
  'assumption day': 'assumption',
  'maria himmelfahrt': 'assumption',
  'epiphany': 'epiphany',
  'heilige drei könige': 'epiphany',
  "international women's day": 'womensday',
  'internationaler frauentag': 'womensday',
  'all souls day': 'allsouls',
};

/// 名字 → 别名键（配不上回空串，调用方**必须**按"配不上就不合并"处理）
String holidayAlias(String name) {
  final lower = name.toLowerCase().trim();
  if (lower.isEmpty) return '';
  final direct = kHolidayAliases[lower];
  if (direct != null) return direct;
  // 去掉标点/多余空格后再配一次（`New Year’s Day` 这类弯引号）
  final cleaned = lower
      .replaceAll(RegExp(r"[’'`.,]"), '')
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim();
  final again = kHolidayAliases[cleaned];
  if (again != null) return again;
  // 最后做一次"包含"匹配（`New Year's Day (observed)`）
  for (final e in kHolidayAliases.entries) {
    if (e.key.length >= 5 && cleaned.contains(e.key)) return e.value;
  }
  return '';
}

/// 别名键（`kHolidayAliases` 的**值**）→ ARB key；认不出返回 null。
///
/// 这张表就是"节日名的通行英文译法"（春节 = Spring Festival、中秋 =
/// Mid-Autumn Festival…），**不要机翻**。
String? holidayNameKey(String alias) => switch (alias) {
  'newyear' => 'holidayNewYear',
  'labour' => 'holidayLabour',
  'christmas' => 'holidayChristmas',
  'goodfriday' => 'holidayGoodFriday',
  'eastermonday' => 'holidayEasterMonday',
  'eastersunday' => 'holidayEasterSunday',
  'nationalday' => 'holidayNationalDay',
  'midautumn' => 'holidayMidAutumn',
  'dragonboat' => 'holidayDragonBoat',
  'qingming' => 'holidayQingming',
  'springfestival' => 'holidaySpringFestival',
  'allsaints' => 'holidayAllSaints',
  'assumption' => 'holidayAssumption',
  'epiphany' => 'holidayEpiphany',
  'womensday' => 'holidayWomensDay',
  'allsouls' => 'holidayAllSouls',
  _ => null,
};

/// 节日名 → 当前语言文案。
///
/// 来源名是多语言的（`Neujahr` / `元旦` / `New Year's Day`），靠 [holidayAlias]
/// 归到同一个 ARB key；**认不出的名字原样返回**（服务端原文，例如 `Tag der
/// Arbeit` 或农历节气的 `立春`）。数据层走 `data_text.dart`（docs §4.6）；
/// 没装翻译器时回落传入的名字本身。
String holidayNameText(String name) {
  final alias = holidayAlias(name);
  if (alias.isEmpty) return name;
  final k = holidayNameKey(alias);
  if (k == null) return name;
  return dataText(k, name);
}

String countryNameForNote(String cc) =>
    cc.isEmpty ? dataText('holidayRegionGeneric', '该地区') : cc.toUpperCase();

/// 农历日历：**纯离线**（`lunar` 包），提供
/// ①每天一个"农历小标签"（节日 > 节气 > 初二/十五…）
/// ②整年的传统节日与节气
/// ③中国法定节假日 + **调休上班**（`HolidayUtil`）
class ChineseCalendar {
  const ChineseCalendar._();

  /// 农历日期的**双语**构造。
  ///
  /// ★ 为什么不能直接拼中文字符串：`lunar` 包只给中文（"九月初二"），
  ///   英文界面里就成了"中英混排"（真机实测：英文语言下日历卡片显示
  ///   "初二 九月初二"，第 260 轮）。
  ///   做法：**两种写法都交给模板**，各语言自己挑占位符 ——
  ///   zh 模板用 `{zh}`（中文写法），en 模板用 `{m}/{d}`（阿拉伯数字）；
  ///   于是数据层**不需要**判断当前语言（数据层不该 import Flutter，
  ///   见 `data_text.dart` 文件头）。
  /// 占位符一律**全部**替换（不是只替第一个）：
  /// `test/i18n_placeholder_audit_test.dart` 静态要求 `*Fill` 助手把
  /// 每个占位符都以 `'名字': 值` 的形式显式给出 —— 所以这里收一个 values map，
  /// 而不是散开的定位参数（第 260 轮：散开写法会被守卫判为"缺替换"）。
  static String _fill(
    String key,
    String zhFallback,
    Map<String, Object> values,
  ) {
    var out = dataText(key, zhFallback);
    for (final e in values.entries) {
      out = out.replaceAll('{${e.key}}', '${e.value}');
    }
    return out;
  }

  /// "九月初二" / `Lunar 9/2`
  static String _lunarMonthDay(lunar_pkg.Lunar l) => _fill(
    'calendarLunarMonthDay',
    '{zh}',
    {
      'zh': '${l.getMonthInChinese()}月${l.getDayInChinese()}',
      'm': l.getMonth(),
      'd': l.getDay(),
    },
  );

  /// "九月" / `Lunar 9`
  static String _lunarMonthOnly(lunar_pkg.Lunar l) => _fill(
    'calendarLunarMonthOnly',
    '{zh}月',
    {'zh': l.getMonthInChinese(), 'm': l.getMonth(), 'd': l.getDay()},
  );

  /// "初二" / `Lunar 2`
  static String _lunarDayOnly(lunar_pkg.Lunar l) => _fill(
    'calendarLunarDayOnly',
    '{zh}',
    {'zh': l.getDayInChinese(), 'm': l.getMonth(), 'd': l.getDay()},
  );

  /// 某天的农历小标签（日历格子里显示的那一行）
  ///
  /// 顺序：农历节日 → 节气 → 公历节日 → 初一显示"X月" → 否则显示农历日
  static ChineseDayInfo infoFor(DateTime date) {
    final solar = lunar_pkg.Solar.fromYmd(date.year, date.month, date.day);
    final lunar = solar.getLunar();
    final festivals = lunar.getFestivals();
    final jieQi = lunar.getJieQi();
    final solarFestivals = solar.getFestivals();
    final official = lunar_pkg.HolidayUtil.getHolidayByYmd(
      date.year,
      date.month,
      date.day,
    );
    String text;
    HolidayKind kind;
    if (official != null) {
      // 官方节假日表（含调休）优先：它才是"这天放不放假"的权威说法，
      // 否则 10-01 会被公历节日表标成"纪念日"
      text = holidayNameText(official.getName());
      kind = official.isWork() ? HolidayKind.workday : HolidayKind.public;
    } else if (festivals.isNotEmpty) {
      text = holidayNameText(festivals.first);
      kind = HolidayKind.traditional;
    } else if (jieQi.isNotEmpty) {
      // 节气名（"清明""立春"…）是农历包的原文，没有通行英文译法表 → 保持原样
      text = jieQi;
      kind = HolidayKind.solarTerm;
    } else if (solarFestivals.isNotEmpty) {
      text = holidayNameText(solarFestivals.first);
      kind = HolidayKind.observance;
    } else if (lunar.getDay() == 1) {
      text = _lunarMonthOnly(lunar);
      kind = HolidayKind.observance;
    } else {
      text = _lunarDayOnly(lunar);
      kind = HolidayKind.observance;
    }
    return ChineseDayInfo(
      lunarMonthDay: _lunarMonthDay(lunar),
      lunarYear: lunar.getYearInChinese(),
      label: text,
      labelKind: kind,
      isOfficialHoliday: official != null && !official.isWork(),
      isWorkday: official?.isWork() ?? false,
      officialName: official?.getName() ?? '',
    );
  }

  /// 整年的传统节日 + 节气（+ 中国法定节假日/调休）
  static List<HolidayEntry> yearEntries(
    int year, {
    bool includeOfficial = true,
  }) {
    final out = <HolidayEntry>[];
    // 做法：**逐日遍历公历年**（365/366 天），每天问一次农历的节日与节气。
    // 之前按"农历月"遍历踩过坑：`LunarMonth.getDayCount()` 与实际可用天数在
    // 年末会差一天（`only 29 days in lunar year 2024 month 12`），而按公历走
    // 既不会错位，也天然覆盖"除夕落在公历 1/2 月"的情况。
    for (
      var day = DateTime(year, 1, 1);
      day.year == year;
      day = DateTime(year, day.month, day.day + 1)
    ) {
      final solar = lunar_pkg.Solar.fromYmd(day.year, day.month, day.day);
      final lunar = solar.getLunar();
      for (final f in lunar.getFestivals()) {
        out.add(
          HolidayEntry(
            date: day,
            name: f,
            kind: HolidayKind.traditional,
            source: HolidaySource.lunar.id,
          ),
        );
      }
      final jieQi = lunar.getJieQi();
      if (jieQi.isNotEmpty) {
        out.add(
          HolidayEntry(
            date: day,
            name: jieQi,
            kind: HolidayKind.solarTerm,
            source: HolidaySource.lunar.id,
          ),
        );
      }
    }
    if (includeOfficial) {
      for (final h in lunar_pkg.HolidayUtil.getHolidaysByYear(year)) {
        final date = DateTime.tryParse(h.getDay());
        if (date == null) continue;
        final work = h.isWork();
        out.add(
          HolidayEntry(
            date: date,
            name: h.getName(),
            kind: work ? HolidayKind.workday : HolidayKind.public,
            source: HolidaySource.lunar.id,
          ),
        );
      }
    }
    return HolidayService.mergeHolidays(out);
  }
}

/// 某天的农历信息
@immutable
class ChineseDayInfo {
  const ChineseDayInfo({
    required this.lunarMonthDay,
    required this.lunarYear,
    required this.label,
    required this.labelKind,
    required this.isOfficialHoliday,
    required this.isWorkday,
    this.officialName = '',
  });

  final String lunarMonthDay;
  final String lunarYear;

  /// 格子里那一行小字
  final String label;
  final HolidayKind labelKind;
  final bool isOfficialHoliday;

  /// 调休上班（UI 上打一个"班"）
  final bool isWorkday;
  final String officialName;

  bool get isFestival =>
      labelKind == HolidayKind.traditional ||
      labelKind == HolidayKind.solarTerm;
}
