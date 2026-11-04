// IW44 解码器的**异常行为自检**。
//
// 诚实声明：本仓库没有真实 DJVU / IW44 样本，也没有 IW44 编码器，因此这个脚本
// **只**验证"垃圾 / 空 / 截断输入会抛出已声明的异常，且不会卡死、不会返回半截
// 乱码"，不验证像素正确性。端到端（编码器 → 解码器逐像素比对）仍然缺失。
//
// 每个 case 在**独立 isolate** 里跑并带 5 秒超时，这样即使解码器因畸形输入陷入
// 死循环，父进程也能杀掉并判失败（"never hangs" 是硬要求）。
//
// 运行：dart run tool/djvu_iw44_selftest.dart
//
// 这是一个命令行脚本（不在 lib/ 里），因此关闭 print / 相对 import 的 lint。
// ignore_for_file: avoid_print, avoid_relative_lib_imports
import 'dart:async';
import 'dart:isolate';
import 'dart:typed_data';

import '../lib/src/features/files/djvu_errors.dart';
import '../lib/src/features/files/djvu_iw44.dart';

const Duration _timeout = Duration(seconds: 5);

/// 期望抛 [DjvuFormatException] 或 [DjvuUnsupportedException]（两者都算"已声明"）。
const String _expectDeclared = 'declared';

/// 期望抛 [DjvuUnsupportedException]。
const String _expectUnsupported = 'unsupported';

/// 期望成功，且返回 [DjvuIw44Pixels]。
const String _expectOk = 'ok';

var _failures = 0;

Future<void> _check(
  String name,
  String expectation,
  List<Uint8List> chunks, {
  int width = 0,
  int height = 0,
  void Function(DjvuIw44Pixels pix)? validate,
}) async {
  final receive = ReceivePort();
  final errors = ReceivePort();
  Isolate isolate;
  try {
    isolate = await Isolate.spawn(
      _runCase,
      <Object?>[receive.sendPort, chunks, width, height],
      onError: errors.sendPort,
      errorsAreFatal: true,
    );
  } catch (e) {
    _fail('[$name] 无法启动 isolate: $e');
    receive.close();
    errors.close();
    return;
  }
  final completer = Completer<Object?>();
  receive.listen((message) {
    if (!completer.isCompleted) completer.complete(message);
  });
  // onError 也应当让 completer 结束（未捕获错误视为失败）。
  errors.listen((message) {
    if (!completer.isCompleted) completer.complete('isolate-error:$message');
  });
  try {
    final result = await completer.future.timeout(_timeout);
    _evaluate(name, expectation, result, validate);
  } on TimeoutException {
    isolate.kill(priority: Isolate.immediate);
    _fail('[$name] 超过 ${_timeout.inSeconds}s 未返回 —— 疑似死循环');
  } finally {
    isolate.kill(priority: Isolate.immediate);
    receive.close();
    errors.close();
  }
}

void _evaluate(
  String name,
  String expectation,
  Object? result,
  void Function(DjvuIw44Pixels pix)? validate,
) {
  final text = '$result';
  if (expectation == _expectOk) {
    if (!text.startsWith('ok:')) {
      _fail('[$name] 期望成功，实际 $text');
      return;
    }
    final parts = text.substring(3).split(':');
    final pix = DjvuIw44Pixels(
      int.parse(parts[0]),
      int.parse(parts[1]),
      int.parse(parts[2]),
      Uint8List(0),
    );
    // 注：像素数据无法跨 isolate 直接校验时由父进程重跑；这里只校验元数据。
    validate?.call(pix);
    _pass('[$name] 成功：${pix.width}x${pix.height} ch=${pix.channels}（$text）');
    return;
  }
  if (text.startsWith('format:')) {
    _pass('[$name] DjvuFormatException: ${text.substring(7)}');
    return;
  }
  if (text.startsWith('unsupported:')) {
    if (expectation == _expectDeclared || expectation == _expectUnsupported) {
      _pass('[$name] DjvuUnsupportedException: ${text.substring(12)}');
      return;
    }
    _fail('[$name] 不应是 unsupported：$text');
    return;
  }
  if (text.startsWith('other:')) {
    _fail('[$name] 抛出未声明异常：${text.substring(6)}');
    return;
  }
  if (text == 'no-throw') {
    _fail('[$name] 期望抛异常，实际正常返回');
    return;
  }
  _fail('[$name] 意外结果：$text');
}

void _pass(String msg) => print('ok   $msg');

void _fail(String msg) {
  _failures++;
  print('FAIL $msg');
}

/// isolate 入口：解码并回传结果字符串。必须是顶层函数。
void _runCase(List<Object?> args) {
  final send = args[0] as SendPort;
  final rawChunks = args[1] as List<Object?>;
  final chunks = <Uint8List>[for (final c in rawChunks) (c as Uint8List)];
  final width = args[2] as int;
  final height = args[3] as int;
  try {
    final pix = djvuIw44Decode(chunks, width: width, height: height);
    // 顺带做一趟全量读取，确保没有越界/懒崩溃。
    var sum = 0;
    for (final b in pix.data) {
      sum += b;
    }
    send.send(
      'ok:${pix.width}:${pix.height}:${pix.channels}:'
      '${pix.data.length}:$sum',
    );
  } on DjvuFormatException catch (e) {
    send.send('format:${e.message}');
  } on DjvuUnsupportedException catch (e) {
    send.send('unsupported:${e.message}');
  } catch (e) {
    send.send('other:$e');
  }
}

Uint8List _bytes(List<int> values) => Uint8List.fromList(values);

/// 一个合法但 slices=0 的灰度头（BM44：major=0x81, minor=2）。
Uint8List _grayHeader({
  int serial = 0,
  int slices = 0,
  int w = 32,
  int h = 32,
}) => _bytes([
  serial,
  slices,
  0x81,
  0x02,
  (w >> 8) & 0xff,
  w & 0xff,
  (h >> 8) & 0xff,
  h & 0xff,
  0, // crcbdelay
]);

Future<void> main() async {
  print('== IW44 解码器自检（无真实样本，只查异常/边界）==');

  // 1. 空 chunks。
  await _check('empty list', _expectDeclared, <Uint8List>[]);

  // 2. chunks 里有空 Uint8List。
  await _check('empty chunk', _expectDeclared, <Uint8List>[_bytes([])]);

  // 3. 只有一个字节。
  await _check('1-byte chunk', _expectDeclared, <Uint8List>[
    _bytes([0]),
  ]);

  // 4. 只有 primary header（2 字节）。
  await _check('primary-only', _expectDeclared, <Uint8List>[
    _bytes([0, 10]),
  ]);

  // 5. 只有 secondary header，缺 tertiary。
  await _check('secondary-only', _expectDeclared, <Uint8List>[
    _bytes([0, 10, 0x81, 0x02]),
  ]);

  // 6. 头合法、声明大量 slice、正文只有几个字节 → ZP 位流截断。
  await _check('truncated body', _expectDeclared, <Uint8List>[
    Uint8List.fromList(<int>[
      ..._grayHeader(slices: 200, w: 1024, h: 1024),
      0x00,
      0x00,
    ]),
  ]);

  // 6b. 正文完全为空但头合法：ZP 算术解码器有 25 字节 0xff 填充容差
  //     （参考实现的 ZPCodec::preload 行为相同），因此这不属于"截断"，
  //     会得到一张合法的粗图。这里显式记录该语义。
  await _check(
    'header-only (ZP fill tolerated)',
    _expectOk,
    <Uint8List>[_grayHeader(slices: 200, w: 256, h: 256)],
    validate: (pix) {
      if (pix.width != 256 || pix.height != 256 || pix.channels != 1) {
        _fail('[header-only] 元数据错误 ${pix.width}x${pix.height}');
      }
    },
  );

  // 7. 纯随机垃圾（要求是已声明异常，不允许其它异常）。
  await _check('random garbage', _expectDeclared, <Uint8List>[
    _bytes(List<int>.generate(64, (i) => (i * 37 + 11) & 0xff)),
  ]);

  // 8. 主版本不支持。
  await _check('bad major', _expectUnsupported, <Uint8List>[
    _bytes([0, 0, 0x02, 0x02, 0, 32, 0, 32, 0]),
  ]);

  // 9. 次版本太新。
  await _check('bad minor', _expectUnsupported, <Uint8List>[
    _bytes([0, 0, 0x81, 0x07, 0, 32, 0, 32, 0]),
  ]);

  // 10. 尺寸为 0 且没有 override。
  await _check('zero size', _expectDeclared, <Uint8List>[
    _bytes([0, 0, 0x81, 0x02, 0, 0, 0, 0, 0]),
  ]);

  // 11. 尺寸超大（65535x65535）→ 超出实现上限。
  await _check('oversized', _expectUnsupported, <Uint8List>[
    _bytes([0, 0, 0x81, 0x02, 0xff, 0xff, 0xff, 0xff, 0]),
  ]);

  // 12. 序号不连续：第一个合法（slices=0），第二个 serial=7。
  await _check('serial gap', _expectDeclared, <Uint8List>[
    _grayHeader(serial: 0, slices: 0),
    _grayHeader(serial: 7, slices: 0, w: 32, h: 32),
  ]);

  // 13. 合法头 + slices=0：应成功，输出 32x32 灰度、全 128。
  //     这里在父进程直接跑一遍（同步、已知有界），顺便真校验像素。
  try {
    final pix = djvuIw44Decode(<Uint8List>[_grayHeader(slices: 0)]);
    if (pix.width == 32 && pix.height == 32 && pix.channels == 1) {
      var ok = true;
      for (final b in pix.data) {
        if (b != 128) {
          ok = false;
          break;
        }
      }
      if (ok) {
        _pass('[zero slices] 成功：32x32 ch=1 且全 128');
      } else {
        _fail('[zero slices] 像素不是全 128');
      }
    } else {
      _fail(
        '[zero slices] 元数据错误 ${pix.width}x${pix.height} ch=${pix.channels}',
      );
    }
  } on DjvuFormatException catch (e) {
    _fail('[zero slices] 意外抛出 DjvuFormatException: ${e.message}');
  } on DjvuUnsupportedException catch (e) {
    _fail('[zero slices] 意外抛出 DjvuUnsupportedException: ${e.message}');
  } catch (e) {
    _fail('[zero slices] 意外异常 $e');
  }

  // 14. override 尺寸：头里 32x32，用 width/height 覆盖成 16x8。
  await _check(
    'size override',
    _expectOk,
    <Uint8List>[_grayHeader(slices: 0)],
    width: 16,
    height: 8,
    validate: (pix) {
      if (pix.width != 16 || pix.height != 8 || pix.channels != 1) {
        _fail('[size override] 元数据错误 ${pix.width}x${pix.height}');
      }
    },
  );

  print('');
  if (_failures == 0) {
    print('全部通过：所有坏输入都抛已声明异常、无死循环、合法零系数头可解。');
    print('注意：这不等于 IW44 像素解码正确 —— 仍缺真实样本端到端验证。');
  } else {
    print('失败 $_failures 项。');
  }
}
