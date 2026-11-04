// `SYNO.FileStation.ThumbInfo / get`（图片 EXIF / IPTC / XMP 元数据）的离线验证。
//
// ## 事实来源（两种形状都取到了真机原文）
//
// **① 空态** —— `/home` 下的文件（真机只读实测）：
// ```console
// SYNO.FileStation.ThumbInfo/get  path=entry.cgi  v1..1  params={path:/home}
//   → {"exif":null,"iptc":null,"xmp":null}
// ```
//
// **② 有数据** —— `/home/Photos/手机备份/IMG_20260920_171030.jpg`
// （2026-09-22 真机实测，截图 `docs/evidence-r17/06-file-thumbinfo-data-exif.png`）：
// 块的取值是**数组**，元素形如 `{"name": "…", "value": "…\n"}`，
// `name` 是**人话英文**，`value` **带尾随 `\n`**：
// ```json
// "exif": [
//   {"name":"Image Width","value":"3072\n"},
//   {"name":"Model","value":"LGE-AN10\n"},
//   {"name":"Exposure Time","value":"0.06 s\n"},
//   {"name":"FNumber","value":"F1.8\n"},
//   {"name":"ISO Speed Ratings","value":"6400\n"},
//   {"name":"Date and Time (original)","value":"2026:09:20 17:10:30\n"},
//   {"name":"Focal Length","value":"5.5 mm\n"},
//   {"name":"GPS Latitude","value":"0deg 0' 0\"\n"},
//   {"name":"Image Description","value":"\n"}
// ]
// ```
//
// ⇒ 本文件的"有数据"用例**直接引用上面这段真机原文**（不是构造的猜测形状）。
// 另有若干用例覆盖"形状变了也不崩"的通用回落。
//
// ⚠️ 全部离线（`FakeTransport`），不碰真实 NAS。
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:synhub/src/data/dto/file_entry_dto.dart';
import 'package:synhub/src/data/filestation_api.dart';
import 'package:synhub/src/dsm/webapi.dart';
import 'package:synhub/src/features/files/file_providers.dart';
import 'package:synhub/src/features/files/file_sheets.dart';

import 'package:synhub/src/core/theme/app_theme.dart';
import 'support/chat_harness.dart';

const _table = {
  'SYNO.API.Info': {'path': 'query.cgi', 'minVersion': 1, 'maxVersion': 1},
  'SYNO.FileStation.ThumbInfo': {
    'path': 'entry.cgi',
    'minVersion': 1,
    'maxVersion': 1,
  },
};

/// 真机 `/home/Photos/手机备份/IMG_20260920_171030.jpg` 的 `exif` 原文
/// （**逐字抄自真机回包**；只截取前若干项，顺序与原样一致）。
const _realExif = [
  {'name': 'Image Width', 'value': '3072\n'},
  {'name': 'Image Length', 'value': '4096\n'},
  {'name': 'Image Description', 'value': '\n'},
  {'name': 'Make', 'value': 'HUAWEI\n'},
  {'name': 'Model', 'value': 'LGE-AN10\n'},
  {'name': 'X-Resolution', 'value': '72\n'},
  {'name': 'Y-Resolution', 'value': '72\n'},
  {'name': 'Resolution Unit', 'value': 'inch\n'},
  {'name': 'Date and Time', 'value': '2026:09:20 17:10:30\n'},
  {'name': 'Exif IFD Pointer', 'value': '210\n'},
  {'name': 'Exposure Time', 'value': '0.06 s\n'},
  {'name': 'FNumber', 'value': 'F1.8\n'},
  {'name': 'Exposure Program', 'value': 'Auto\n'},
  {'name': 'ISO Speed Ratings', 'value': '6400\n'},
  {'name': 'Date and Time (original)', 'value': '2026:09:20 17:10:30\n'},
  {'name': 'Shutter speed', 'value': '1/17 s\n'},
  {'name': 'Aperture', 'value': 'F1.8\n'},
  {'name': 'Focal Length', 'value': '5.5 mm\n'},
  {'name': 'GPS Latitude', 'value': '0deg 0\' 0"\n'},
  {'name': 'GPS Date Stamp', 'value': '\n'},
];

class _PathRecordingTransport extends FakeTransport {
  _PathRecordingTransport(super.responses, super.apiTable);

  final List<String> paths = [];

  @override
  Future<String> postForm(
    String path,
    Map<String, dynamic> params, {
    String? module,
  }) {
    paths.add(path);
    return super.postForm(path, params);
  }
}

Map<String, dynamic>? _lastCall(_PathRecordingTransport t, String key) {
  for (final call in t.calls.reversed) {
    if ('${call['api']}.${call['method']}' == key) return call;
  }
  return null;
}

int _thumbInfoCalls(_PathRecordingTransport t) => t.calls
    .where(
      (c) => '${c['api']}.${c['method']}' == 'SYNO.FileStation.ThumbInfo.get',
    )
    .length;

FileEntryDto _entry(String name) =>
    FileEntryDto(name: name, path: '/home/$name');

void main() {
  group('FileThumbInfoDto：空态与宽松解析', () {
    test('真机空回包：三个 null ⇒ isEmpty，且不是错误', () {
      final dto = FileThumbInfoDto.fromJson(const {
        'exif': null,
        'iptc': null,
        'xmp': null,
      });
      expect(dto.isEmpty, isTrue);
      expect(dto.rowCount, 0);
      expect(dto.blocks.length, 3);
      for (final b in dto.blocks) {
        expect(b.isEmpty, isTrue);
      }
      // 三个块的顺序与键名一致
      expect(dto.blocks.map((b) => b.kind).toList(), ThumbInfoKind.values);
    });

    test('缺键 / 空容器也等同空态（不崩）', () {
      expect(FileThumbInfoDto.fromJson(const {}).isEmpty, isTrue);
      expect(
        FileThumbInfoDto.fromJson(const {
          'exif': '',
          'iptc': [],
          'xmp': {},
        }).isEmpty,
        isTrue,
      );
    });

    test('真机有数据回包：[{name,value}] ⇒ name 当标签、value 去掉尾随 \\n', () {
      final dto = FileThumbInfoDto.fromJson(const {
        'exif': _realExif,
        'iptc': null,
        'xmp': null,
      });
      expect(dto.isEmpty, isFalse);
      final rows = dto.blocks[0].rows;

      ThumbInfoRow row(String label) => rows.firstWhere((r) => r.key == label);

      expect(row('Model').value, 'LGE-AN10', reason: '尾随 \\n 必须去掉');
      expect(row('Exposure Time').value, '0.06 s');
      expect(row('FNumber').value, 'F1.8');
      expect(row('ISO Speed Ratings').value, '6400');
      expect(row('Focal Length').value, '5.5 mm');
      expect(row('Date and Time (original)').value, '2026:09:20 17:10:30');
      expect(row('GPS Latitude').value, '0deg 0\' 0"');
      // 没有任何一行的键或值还带着 JSON 包装 / 换行
      for (final r in rows) {
        expect(r.key.contains('{'), isFalse);
        expect(r.value.contains('{'), isFalse);
        expect(r.value.contains('\n'), isFalse);
      }
    });

    test('真机里 value 只有空白的项不占行（Image Description / GPS Date Stamp）', () {
      final dto = FileThumbInfoDto.fromJson(const {'exif': _realExif});
      final keys = dto.blocks[0].rows.map((r) => r.key).toList();
      expect(keys, isNot(contains('Image Description')));
      expect(keys, isNot(contains('GPS Date Stamp')));
      expect(keys, contains('Image Width'));
      // 20 条原文 − 2 条空值 = 18 行
      expect(dto.blocks[0].rows.length, _realExif.length - 2);
    });

    test('单个 {name,value} 对象也认（不是数组的变体）', () {
      final dto = FileThumbInfoDto.fromJson(const {
        'iptc': {'name': 'Caption', 'value': '海滩\n'},
      });
      expect(dto.blocks[1].rows.single.key, 'Caption');
      expect(dto.blocks[1].rows.single.value, '海滩');
    });

    test('形状变了也兜得住：字符串 / 对象 / 数字 / 非 name-value 数组', () {
      final s = FileThumbInfoDto.fromJson(const {
        'exif': 'Make: Canon\nModel: R5',
      });
      expect(s.rowCount, 1);
      expect(s.blocks[0].rows.single.key, '');
      expect(s.blocks[0].rows.single.value, contains('Canon'));

      final m = FileThumbInfoDto.fromJson(const {
        'exif': {'Exif.Image.Model': 'Canon EOS R5', 'Ignored': null},
      });
      expect(m.blocks[0].rows.single.key, 'Exif.Image.Model');
      expect(m.blocks[0].rows.single.value, 'Canon EOS R5');

      final n = FileThumbInfoDto.fromJson(const {'exif': 400});
      expect(n.blocks[0].rows.single.value, '400');

      // 数组元素不是 {name,value} ⇒ 退回平铺（信息不丢）
      final a = FileThumbInfoDto.fromJson(const {
        'xmp': [
          'one',
          {'k': 'v'},
        ],
      });
      expect(a.blocks[2].rows.length, 2);
      expect(a.blocks[2].rows[1].value, contains('"k":"v"'));
    });
  });

  group('标签映射：认得就给中文，认不出就原样显示键名', () {
    test('真机回的英文 name 命中中文标签（相机/光圈/ISO/拍摄时间/焦距/GPS）', () {
      expect(thumbInfoLabel('Model').label('Model'), '相机型号');
      expect(thumbInfoLabel('Make').label('Make'), '相机制造商');
      expect(thumbInfoLabel('FNumber').label('x'), '光圈');
      expect(thumbInfoLabel('Aperture').label('x'), '光圈');
      expect(thumbInfoLabel('ISO Speed Ratings').label('x'), 'ISO');
      expect(thumbInfoLabel('Exposure Time').label('x'), '曝光时间');
      expect(thumbInfoLabel('Date and Time (original)').label('x'), '拍摄时间');
      expect(thumbInfoLabel('Focal Length').label('x'), '焦距');
      expect(thumbInfoLabel('GPS Latitude').label('x'), 'GPS 位置');
      expect(thumbInfoLabel('GPS Longitude Reference').label('x'), 'GPS 位置');
    });

    test('Exiv2 全名也认得（别的 DSM 版本可能回这种）', () {
      expect(thumbInfoLabel('Exif.Image.Model').label('x'), '相机型号');
      expect(thumbInfoLabel('Exif.Photo.FNumber').label('x'), '光圈');
      expect(thumbInfoLabel('Exif.GPSInfo.GPSLatitude').label('x'), 'GPS 位置');
    });

    test('不认得的键：原样返回原始键名（不猜中文、不吞行）', () {
      expect(thumbInfoLabel('Image Width').label('Image Width'), 'Image Width');
      expect(
        thumbInfoLabel('Exposure Program').label('Exposure Program'),
        'Exposure Program',
      );
      expect(
        thumbInfoLabel('My.Vendor.Key').label('My.Vendor.Key'),
        'My.Vendor.Key',
      );
    });
  });

  group('哪些文件才显示元数据', () {
    test('位图与 RAW 显示；目录 / 普通文件不显示', () {
      expect(showsThumbInfo(_entry('a.jpg')), isTrue);
      expect(showsThumbInfo(_entry('a.HEIC')), isTrue);
      expect(showsThumbInfo(_entry('a.cr2')), isTrue);
      expect(showsThumbInfo(_entry('a.nef')), isTrue);
      expect(showsThumbInfo(_entry('a.txt')), isFalse);
      expect(showsThumbInfo(_entry('a.pdf')), isFalse);
      expect(showsThumbInfo(_entry('a.zip')), isFalse);
      const dir = FileEntryDto(
        name: 'photos',
        path: '/home/photos',
        isDir: true,
      );
      expect(showsThumbInfo(dir), isFalse);
    });
  });

  group('请求形状（真机原文对齐）', () {
    test('api/method/version=1，参数只有 path，且 path 来自能力表', () async {
      final t = _PathRecordingTransport(const {}, _table);
      t.onCall = (p) => p['api'] == 'SYNO.FileStation.ThumbInfo'
          ? const {'exif': null}
          : null;
      final web = DsmWebApi(t);
      await web.discover();
      await FileStationApi(web).thumbInfo('/home/a.jpg');
      final call = _lastCall(t, 'SYNO.FileStation.ThumbInfo.get');
      expect(call, isNotNull);
      expect(call!['version'], '1', reason: '真机 v1..1');
      expect(call['path'], '/home/a.jpg', reason: '真机参数名就是单值 path');
      expect(call.keys.toSet(), {'api', 'method', 'version', 'path'});
      expect(t.paths.last, 'entry.cgi');
    });
  });

  group('属性面板内的元数据块（离线 widget）', () {
    Future<_PathRecordingTransport> pump(
      WidgetTester tester,
      FileEntryDto entry, {
      Map<String, Map<String, dynamic>> table = _table,
      Map<String, dynamic>? reply,
    }) async {
      final t = _PathRecordingTransport(const {}, table);
      if (reply != null) {
        t.onCall = (p) =>
            p['api'] == 'SYNO.FileStation.ThumbInfo' ? reply : null;
      }
      final web = DsmWebApi(t);
      await web.discover();
      final c = ProviderContainer(
        overrides: [fileApiProvider.overrideWithValue(FileStationApi(web))],
      );
      addTearDown(c.dispose);
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: c,
          child: MaterialApp(theme: AppTheme.dark(), 
            home: Scaffold(
              body: SingleChildScrollView(
                child: FileThumbInfoPanel(entry: entry),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      return t;
    }

    testWidgets('真机有数据：按 name/value 两列显示，中文标签命中，没有 JSON 包装', (tester) async {
      await pump(
        tester,
        _entry('IMG_20260920_171030.jpg'),
        reply: const {'exif': _realExif, 'iptc': null, 'xmp': null},
      );
      expect(find.text('照片元数据'), findsOneWidget);
      expect(find.text('EXIF'), findsOneWidget);

      // 指名要的字段
      expect(find.text('相机型号'), findsOneWidget);
      expect(find.text('LGE-AN10'), findsOneWidget);
      expect(find.text('相机制造商'), findsOneWidget);
      expect(find.text('HUAWEI'), findsOneWidget);
      expect(find.text('光圈'), findsNWidgets(2)); // FNumber + Aperture
      expect(find.text('F1.8'), findsNWidgets(2));
      expect(find.text('ISO'), findsOneWidget);
      expect(find.text('6400'), findsOneWidget);
      expect(find.text('曝光时间'), findsOneWidget);
      expect(find.text('0.06 s'), findsOneWidget);
      expect(find.text('拍摄时间'), findsNWidgets(2)); // Date and Time + (original)
      expect(find.text('焦距'), findsOneWidget);
      expect(find.text('5.5 mm'), findsOneWidget);
      expect(find.text('GPS 位置'), findsOneWidget);
      expect(find.text('0deg 0\' 0"'), findsOneWidget);

      // 没映射的**原样显示服务端的英文名**（不发明翻译）
      expect(find.text('Image Width'), findsOneWidget);
      expect(find.text('3072'), findsOneWidget);
      expect(find.text('Exposure Program'), findsOneWidget);

      // 绝不能把 JSON 对象直接糊到界面上，也不能留换行
      expect(find.textContaining('{"name"'), findsNothing);
      expect(find.textContaining('\\n'), findsNothing);
      // 有数据时不能出现空态文案；IPTC/XMP 是 null ⇒ 不出标题
      expect(find.textContaining('不含 EXIF'), findsNothing);
      expect(find.text('IPTC'), findsNothing);
      expect(find.text('XMP'), findsNothing);
    });

    testWidgets('真机空回包：优雅空态，明说"不含元数据"（不是错误）', (tester) async {
      await pump(
        tester,
        _entry('a.jpg'),
        reply: const {'exif': null, 'iptc': null, 'xmp': null},
      );
      expect(find.text('照片元数据'), findsOneWidget);
      expect(find.text('该文件不含 EXIF / IPTC / XMP 元数据'), findsOneWidget);
      // 空态不是"加载失败"
      expect(find.textContaining('失败'), findsNothing);
    });

    testWidgets('非图片：整块不出现，且一个请求都不发', (tester) async {
      final t = await pump(
        tester,
        _entry('a.txt'),
        reply: const {'exif': null, 'iptc': null, 'xmp': null},
      );
      expect(find.text('照片元数据'), findsNothing);
      expect(_thumbInfoCalls(t), 0);
    });

    testWidgets('API 不在能力表：整块不出现，且一个请求都不发', (tester) async {
      final t = await pump(
        tester,
        _entry('a.jpg'),
        table: const {
          'SYNO.API.Info': {
            'path': 'query.cgi',
            'minVersion': 1,
            'maxVersion': 1,
          },
        },
        reply: const {'exif': null},
      );
      expect(find.text('照片元数据'), findsNothing);
      expect(_thumbInfoCalls(t), 0);
    });

    testWidgets('请求失败：整块消失，**不**伪装成"不含元数据"', (tester) async {
      final t = _PathRecordingTransport(const {}, _table);
      t.failures['SYNO.FileStation.ThumbInfo.get'] = DsmErrorCode.noPermission;
      final web = DsmWebApi(t);
      await web.discover();
      final c = ProviderContainer(
        overrides: [fileApiProvider.overrideWithValue(FileStationApi(web))],
      );
      addTearDown(c.dispose);
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: c,
          child: MaterialApp(theme: AppTheme.dark(), 
            home: Scaffold(
              body: SingleChildScrollView(
                child: FileThumbInfoPanel(entry: _entry('a.jpg')),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(_thumbInfoCalls(t), 1, reason: '确实发了一次请求');
      expect(find.textContaining('不含 EXIF'), findsNothing);
      expect(find.text('照片元数据'), findsNothing);
    });
  });
}
