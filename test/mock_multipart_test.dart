// `tool/mock_dsm/mock_multipart.dart` 的守卫。
//
// 它存在的唯一理由：让 `SYNO.FileStation.Upload/upload` 的**字节**真的到 Mock 服务端
// （r319 之前是 `drain()` 丢体 ⇒ "上传"这条写动词在 Mock 上永远验不到落盘）。
// 所以这里的判据必须是**逐字节**的：字节数、二进制内容、字段值三样都要对，
// 并且**反向**证明"没有 boundary 时返回 null"（不许把判不了当成解析成功）。
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';

import '../tool/mock_dsm/mock_multipart.dart';

/// 造一份 `Dio` 形态的 multipart 体。
List<int> buildBody({
  required String boundary,
  required Map<String, String> fields,
  List<({String name, String filename, List<int> bytes})> files = const [],
}) {
  final out = <int>[];
  void add(String s) => out.addAll(utf8.encode(s));
  for (final e in fields.entries) {
    add('--$boundary\r\n');
    add('Content-Disposition: form-data; name="${e.key}"\r\n\r\n');
    add('${e.value}\r\n');
  }
  for (final f in files) {
    add('--$boundary\r\n');
    add(
      'Content-Disposition: form-data; name="${f.name}"; '
      'filename="${f.filename}"\r\n',
    );
    add('Content-Type: application/octet-stream\r\n\r\n');
    out.addAll(f.bytes);
    add('\r\n');
  }
  add('--$boundary--\r\n');
  return out;
}

void main() {
  const boundary = '----dio-boundary-r319';

  test('字段与文件都能解析出来，文件字节**逐字节**相等', () {
    final payload = <int>[0, 1, 2, 255, 254, 13, 10, 45, 45, 7];
    final body = buildBody(
      boundary: boundary,
      fields: {'path': '/home/mockfs_sandbox', 'overwrite': 'true'},
      files: [
        (name: 'file', filename: 'r319.bin', bytes: payload),
      ],
    );
    final form = MultipartForm.parse(body, 'multipart/form-data; boundary=$boundary');
    expect(form, isNotNull);
    expect(form!.fields['path'], '/home/mockfs_sandbox');
    expect(form.fields['overwrite'], 'true');
    final files = form.files.toList();
    expect(files, hasLength(1));
    expect(files.first.filename, 'r319.bin');
    expect(files.first.bytes, payload, reason: '二进制必须原样（不能经 UTF-8 往返）');
  });

  test('二进制体里含 CRLF / `--` 也不会被切开', () {
    // 内容里故意塞 `\r\n--<boundary>` 的**前缀**（但不是完整分隔符）
    final payload = utf8.encode('a\r\n--not-the-boundary\r\nb');
    final body = buildBody(
      boundary: boundary,
      fields: {'path': '/home'},
      files: [
        (name: 'file', filename: 'tricky.txt', bytes: payload),
      ],
    );
    final form = MultipartForm.parse(body, 'multipart/form-data; boundary=$boundary');
    expect(form!.files.first.bytes, payload);
  });

  test('多文件：顺序与字节都保留', () {
    final a = utf8.encode('AAA');
    final b = <int>[0xDE, 0xAD, 0xBE, 0xEF];
    final body = buildBody(
      boundary: boundary,
      fields: {'path': '/home'},
      files: [
        (name: 'file', filename: 'a.txt', bytes: a),
        (name: 'file', filename: 'b.bin', bytes: b),
      ],
    );
    final form = MultipartForm.parse(body, 'multipart/form-data; boundary=$boundary');
    final files = form!.files.toList();
    expect(files.map((f) => f.filename), ['a.txt', 'b.bin']);
    expect(files[0].bytes, a);
    expect(files[1].bytes, b);
  });

  test('boundary 带引号也能取（浏览器/某些客户端会加引号）', () {
    expect(
      MultipartForm.boundaryOf('multipart/form-data; boundary="$boundary"'),
      boundary,
    );
  });

  test('反向验证：没有 boundary ⇒ 返回 null（"判不了"不许当成解析成功）', () {
    final body = buildBody(
      boundary: boundary,
      fields: {'path': '/home'},
    );
    expect(MultipartForm.parse(body, 'multipart/form-data'), isNull);
  });

  test('反向验证：体被截断（分隔符缺失）⇒ 不产生"半个文件"的假数据', () {
    final body = buildBody(
      boundary: boundary,
      fields: {'path': '/home'},
      files: [
        (name: 'file', filename: 'x.bin', bytes: const [1, 2, 3]),
      ],
    );
    // 砍掉结尾的 `--<boundary>--`
    final truncated = body.sublist(0, body.length - (boundary.length + 6));
    final form = MultipartForm.parse(
      truncated,
      'multipart/form-data; boundary=$boundary',
    );
    // 要么判不了（null），要么解析出的文件字节**不是**残缺的 1/2 个字节
    if (form != null) {
      for (final f in form.files) {
        expect(f.bytes, isNot(equals(const [1])));
        expect(f.bytes, isNot(equals(const [1, 2])));
      }
    }
  });
}
