// **RAR 测试素材**（base64 常量）：由 rarlab 官方 `rar` 命令行**本地生成**，
// 内容是我们自己造的（自造 txt + 自造 8x8 PNG），**没有下载任何真实漫画**。
//
// 生成命令（macOS arm64；`rar` 6.24 试用版只当"参考实现/夹具生成器"用，
// 运行时零依赖、不随 App 分发）：
//
//   rar a -r -ma4 -m0 out/rar4_store.rar .      # RAR4 store
//   rar a -r -ma4 -m3 out/rar4_comp.rar .       # RAR4 压缩（LZSS+Huffman）
//   rar a -r -ma4 -m5 -s out/rar4_solid.rar .   # RAR4 固实
//   rar a -r -ma5 -m0 out/rar5_store.rar .      # RAR5 store
//   rar a -r -ma5 -m3 out/rar5_comp.rar .       # RAR5 压缩
//   rar a -r -ma5 -m5 -s out/rar5_solid.rar .   # RAR5 固实
//   rar a -ma4 -psecret out/rar4_enc.rar readme.txt   # 文件加密
//   rar a -ma5 -psecret out/rar5_enc.rar readme.txt
//   rar a -ma4 -v1k -m0 out/rar4_vol.rar 中文说明.txt  # 多卷（取 part1/part2）
//
// 内容目录：`readme.txt`（ASCII）、`中文说明.txt`（utf-8）、`sub/cover.png`、
// `漫画/第01话/p1.png|p2.png|p10.png`（8x8 PNG）。
//
// 为什么把字节嵌进仓库而不是运行时调用 `rar`：门禁测试必须**完全离线**、
// 不依赖任何外部二进制。压缩流由**独立参考实现**产出，再交给自研纯 Dart
// 解码器校验 —— 这是"与独立算出的期望字节对照"，不是自比自证。
library;

import 'dart:convert';
import 'dart:typed_data';

/// base64 → 字节
Uint8List rarFixtureBytes(String b64) => base64Decode(b64);

/// 把 [unit] 重复 [times] 次（避免 `+` 拼接的 lint）
String _repeat(String unit, int times) {
  final b = StringBuffer();
  for (var i = 0; i < times; i++) {
    b.write(unit);
  }
  return b.toString();
}

/// 真实的 `readme.txt` 内容（ASCII，重复 26 次）
String get rarReadmeText =>
    'synology_chat cbr fixture\n${_repeat('hello RAR compression world ', 26)}';

/// 真实的 `中文说明.txt` 内容（utf-8）
String get rarChineseText => '电子书 CBR 测试素材\n${_repeat('这是一段用来触发压缩的中文文本。', 30)}';

/// `rar4_store.rar` —— 3110 字节
const String kRar4Store =
    'UmFyIRoHAM+QcwAADQAAAAAAAACe+nQgkDIASgAAAEoAAAADZHWhs3UJNV0UMA0ApIEAAHN1Ylxj'
    'b3Zlci5wbmcA8GjqTYlQTkcNChoKAAAADUlIRFIAAAAIAAAACAgCAAAAS20p3AAAABFJREFUeNpj'
    '+M/AgBUxDC0JACj/P8HOd8hPAAAAAElFTkSuQmCCYK10IJJEALsFAAC7BQAAAzdHced1CTVdFDAf'
    'AKSBAADkuK3mlofor7TmmI4udHh0AE5qLYdl9IsOZgAudHh0APCc5U3nlLXlrZDkuaYgQ0JSIOa1'
    'i+ivlee0oOadkArov5nmmK/kuIDmrrXnlKjmnaXop6blj5HljovnvKnnmoTkuK3mlofmlofmnKzj'
    'gILov5nmmK/kuIDmrrXnlKjmnaXop6blj5HljovnvKnnmoTkuK3mlofmlofmnKzjgILov5nmmK/k'
    'uIDmrrXnlKjmnaXop6blj5HljovnvKnnmoTkuK3mlofmlofmnKzjgILov5nmmK/kuIDmrrXnlKjm'
    'naXop6blj5HljovnvKnnmoTkuK3mlofmlofmnKzjgILov5nmmK/kuIDmrrXnlKjmnaXop6blj5Hl'
    'jovnvKnnmoTkuK3mlofmlofmnKzjgILov5nmmK/kuIDmrrXnlKjmnaXop6blj5HljovnvKnnmoTk'
    'uK3mlofmlofmnKzjgILov5nmmK/kuIDmrrXnlKjmnaXop6blj5HljovnvKnnmoTkuK3mlofmlofm'
    'nKzjgILov5nmmK/kuIDmrrXnlKjmnaXop6blj5HljovnvKnnmoTkuK3mlofmlofmnKzjgILov5nm'
    'mK/kuIDmrrXnlKjmnaXop6blj5HljovnvKnnmoTkuK3mlofmlofmnKzjgILov5nmmK/kuIDmrrXn'
    'lKjmnaXop6blj5HljovnvKnnmoTkuK3mlofmlofmnKzjgILov5nmmK/kuIDmrrXnlKjmnaXop6bl'
    'j5HljovnvKnnmoTkuK3mlofmlofmnKzjgILov5nmmK/kuIDmrrXnlKjmnaXop6blj5HljovnvKnn'
    'moTkuK3mlofmlofmnKzjgILov5nmmK/kuIDmrrXnlKjmnaXop6blj5HljovnvKnnmoTkuK3mlofm'
    'lofmnKzjgILov5nmmK/kuIDmrrXnlKjmnaXop6blj5HljovnvKnnmoTkuK3mlofmlofmnKzjgILo'
    'v5nmmK/kuIDmrrXnlKjmnaXop6blj5HljovnvKnnmoTkuK3mlofmlofmnKzjgILov5nmmK/kuIDm'
    'rrXnlKjmnaXop6blj5HljovnvKnnmoTkuK3mlofmlofmnKzjgILov5nmmK/kuIDmrrXnlKjmnaXo'
    'p6blj5HljovnvKnnmoTkuK3mlofmlofmnKzjgILov5nmmK/kuIDmrrXnlKjmnaXop6blj5Hljovn'
    'vKnnmoTkuK3mlofmlofmnKzjgILov5nmmK/kuIDmrrXnlKjmnaXop6blj5HljovnvKnnmoTkuK3m'
    'lofmlofmnKzjgILov5nmmK/kuIDmrrXnlKjmnaXop6blj5HljovnvKnnmoTkuK3mlofmlofmnKzj'
    'gILov5nmmK/kuIDmrrXnlKjmnaXop6blj5HljovnvKnnmoTkuK3mlofmlofmnKzjgILov5nmmK/k'
    'uIDmrrXnlKjmnaXop6blj5HljovnvKnnmoTkuK3mlofmlofmnKzjgILov5nmmK/kuIDmrrXnlKjm'
    'naXop6blj5HljovnvKnnmoTkuK3mlofmlofmnKzjgILov5nmmK/kuIDmrrXnlKjmnaXop6blj5Hl'
    'jovnvKnnmoTkuK3mlofmlofmnKzjgILov5nmmK/kuIDmrrXnlKjmnaXop6blj5HljovnvKnnmoTk'
    'uK3mlofmlofmnKzjgILov5nmmK/kuIDmrrXnlKjmnaXop6blj5HljovnvKnnmoTkuK3mlofmlofm'
    'nKzjgILov5nmmK/kuIDmrrXnlKjmnaXop6blj5HljovnvKnnmoTkuK3mlofmlofmnKzjgILov5nm'
    'mK/kuIDmrrXnlKjmnaXop6blj5HljovnvKnnmoTkuK3mlofmlofmnKzjgILov5nmmK/kuIDmrrXn'
    'lKjmnaXop6blj5HljovnvKnnmoTkuK3mlofmlofmnKzjgILov5nmmK/kuIDmrrXnlKjmnaXop6bl'
    'j5HljovnvKnnmoTkuK3mlofmlofmnKzjgIKiNnQgkC8A8gIAAPICAAADbunYinUJNV0UMAoApIEA'
    'AHJlYWRtZS50eHQA8KngTXN5bm9sb2d5X2NoYXQgY2JyIGZpeHR1cmUKaGVsbG8gUkFSIGNvbXBy'
    'ZXNzaW9uIHdvcmxkIGhlbGxvIFJBUiBjb21wcmVzc2lvbiB3b3JsZCBoZWxsbyBSQVIgY29tcHJl'
    'c3Npb24gd29ybGQgaGVsbG8gUkFSIGNvbXByZXNzaW9uIHdvcmxkIGhlbGxvIFJBUiBjb21wcmVz'
    'c2lvbiB3b3JsZCBoZWxsbyBSQVIgY29tcHJlc3Npb24gd29ybGQgaGVsbG8gUkFSIGNvbXByZXNz'
    'aW9uIHdvcmxkIGhlbGxvIFJBUiBjb21wcmVzc2lvbiB3b3JsZCBoZWxsbyBSQVIgY29tcHJlc3Np'
    'b24gd29ybGQgaGVsbG8gUkFSIGNvbXByZXNzaW9uIHdvcmxkIGhlbGxvIFJBUiBjb21wcmVzc2lv'
    'biB3b3JsZCBoZWxsbyBSQVIgY29tcHJlc3Npb24gd29ybGQgaGVsbG8gUkFSIGNvbXByZXNzaW9u'
    'IHdvcmxkIGhlbGxvIFJBUiBjb21wcmVzc2lvbiB3b3JsZCBoZWxsbyBSQVIgY29tcHJlc3Npb24g'
    'd29ybGQgaGVsbG8gUkFSIGNvbXByZXNzaW9uIHdvcmxkIGhlbGxvIFJBUiBjb21wcmVzc2lvbiB3'
    'b3JsZCBoZWxsbyBSQVIgY29tcHJlc3Npb24gd29ybGQgaGVsbG8gUkFSIGNvbXByZXNzaW9uIHdv'
    'cmxkIGhlbGxvIFJBUiBjb21wcmVzc2lvbiB3b3JsZCBoZWxsbyBSQVIgY29tcHJlc3Npb24gd29y'
    'bGQgaGVsbG8gUkFSIGNvbXByZXNzaW9uIHdvcmxkIGhlbGxvIFJBUiBjb21wcmVzc2lvbiB3b3Js'
    'ZCBoZWxsbyBSQVIgY29tcHJlc3Npb24gd29ybGQgaGVsbG8gUkFSIGNvbXByZXNzaW9uIHdvcmxk'
    'IGhlbGxvIFJBUiBjb21wcmVzc2lvbiB3b3JsZCAZ8XQgklQASQAAAEkAAAADECskS3UJNV0UMC8A'
    'pIEAAOa8q+eUu1znrKwwMeivnVxwMTAucG5nAG9iKzt1XCx7CDAx3YtcAHAxMC4AcG5nAPC49E2J'
    'UE5HDQoaCgAAAA1JSERSAAAACAAAAAgIAgAAAEttKdwAAAAQSURBVHjaY2Bg+I8DDSkJAKlwP8H8'
    'y0X8AAAAAElFTkSuQmCCTyB0IJJSAEkAAABJAAAAAzOm5i11CTVdFDAtAKSBAADmvKvnlLtc56ys'
    'MDHor51ccDIucG5nAG9iKzt1XCx7CDAx3YtcAHAyLnAAbmcA8HHxTYlQTkcNChoKAAAADUlIRFIA'
    'AAAIAAAACAgCAAAAS20p3AAAABBJREFUeNpjYPjPgB0NLQkA6TA/wR2B3AEAAAAASUVORK5CYILy'
    'sHQgklIASgAAAEoAAAADZHWhs3UJNV0UMC0ApIEAAOa8q+eUu1znrKwwMeivnVxwMS5wbmcAb2Ir'
    'O3VcLHsIMDHdi1wAcDEucABuZwDw/+1NiVBORw0KGgoAAAANSUhEUgAAAAgAAAAICAIAAABLbSnc'
    'AAAAEUlEQVR42mP4z8CAFTEMLQkAKP8/wc53yE8AAAAASUVORK5CYIL21HTgkkIAAAAAAAAAAAAD'
    'AAAAAHUJNV0UMB0A7UEAAOa8q+eUu1znrKwwMeivnQBvYis7dVwsewgwMd2LAPDs8k0a0XTgkCgA'
    'AAAAAAAAAAADAAAAAHUJNV0UMAMA7UEAAHN1YgDw5+dNkPZ04JIxAAAAAAAAAAAAAwAAAAB1CTVd'
    'FDAMAO1BAADmvKvnlLsAb2ArO3UA8I0MScQ9ewBABwA=';

/// `rar4_comp.rar` —— 1063 字节
const String kRar4Comp =
    'UmFyIRoHAM+QcwAADQAAAAAAAAC1cXQgkDIASgAAAEoAAAADZHWhs3UJNV0dMA0ApIEAAHN1Ylxj'
    'b3Zlci5wbmcA8GjqTYlQTkcNChoKAAAADUlIRFIAAAAIAAAACAgCAAAAS20p3AAAABFJREFUeNpj'
    '+M/AgBUxDC0JACj/P8HOd8hPAAAAAElFTkSuQmCCkcZ0IJJEAGkAAAC7BQAAAzdHced1CTVdHTMf'
    'AKSBAADkuK3mlofor7TmmI4udHh0AE5qLYdl9IsOZgAudHh0APCc5U0JQBkH3YETe4U4scDciSU0'
    'KfihCKaWCmM0sopTjDM+zOGLGvGlw5XtnuTe4H69wr2pExTjkNuJltpxkCwpJOjW4LZGE81BSQ2z'
    'oaF9Nisr04CPHKeKFHGSK310MKIPlmfTr3/tSlK8z2ii0nQgkC8ARQAAAPICAAADbunYinUJNV0d'
    'MwoApIEAAHJlYWRtZS50eHQA8KngTQ0BTIvlT/3CrirgpgLFEUJKnmWjFN7YH3cUO/ezjsN6RazB'
    'jmuj460J+yFxL6niQyjA2gnZuZR12wKshMvQh7lj12vx+qsUdCCSVABJAAAASQAAAAMQKyRLdQk1'
    'XR0wLwCkgQAA5ryr55S7XOesrDAx6K+dXHAxMC5wbmcAb2IrO3VcLHsIMDHdi1wAcDEwLgBwbmcA'
    '8Lj0TYlQTkcNChoKAAAADUlIRFIAAAAIAAAACAgCAAAAS20p3AAAABBJREFUeNpjYGD4jwMNKQkA'
    'qXA/wfzLRfwAAAAASUVORK5CYIKHWXQgklIASQAAAEkAAAADM6bmLXUJNV0dMC0ApIEAAOa8q+eU'
    'u1znrKwwMeivnVxwMi5wbmcAb2IrO3VcLHsIMDHdi1wAcDIucABuZwDwcfFNiVBORw0KGgoAAAAN'
    'SUhEUgAAAAgAAAAICAIAAABLbSncAAAAEElEQVR42mNg+M+AHQ0tCQDpMD/BHYHcAQAAAABJRU5E'
    'rkJggjrJdCCSUgBKAAAASgAAAANkdaGzdQk1XR0wLQCkgQAA5ryr55S7XOesrDAx6K+dXHAxLnBu'
    'ZwBvYis7dVwsewgwMd2LXABwMS5wAG5nAPD/7U2JUE5HDQoaCgAAAA1JSERSAAAACAAAAAgIAgAA'
    'AEttKdwAAAARSURBVHjaY/jPwIAVMQwtCQAo/z/BznfITwAAAABJRU5ErkJggvbUdOCSQgAAAAAA'
    'AAAAAAMAAAAAdQk1XRQwHQDtQQAA5ryr55S7XOesrDAx6K+dAG9iKzt1XCx7CDAx3YsA8OzyTRrR'
    'dOCQKAAAAAAAAAAAAAMAAAAAdQk1XRQwAwDtQQAAc3ViAPDn502Q9nTgkjEAAAAAAAAAAAADAAAA'
    'AHUJNV0UMAwA7UEAAOa8q+eUuwBvYCs7dQDwjQxJxD17AEAHAA==';

/// `rar4_solid.rar` —— 909 字节
const String kRar4Solid =
    'UmFyIRoHADvQcwgADQAAAAAAAACC3XSAkDIAnAAAAEoAAAADZHWhs3UJNV0dNQ0ApIEAAHN1Ylxj'
    'b3Zlci5wbmcA8GjqTQgVWUzL3NorjWDAXBxQoe0bggv4JLWUWCFUg7sWNW0Jb6klS25xogiUG1BU'
    'VFBxatBtuLAUEFc0EF3S5tnpH8HcKCnvYIeVPX8G0LnQ++73DvTh39HzPnMuHce4c/A8DgbefCy0'
    'D8Q877EEsxFMzvLXvL0y5sZ9WM2Eki/0JfsrY9fBnDyMDGvzsX5yfH0leWcaQ5KDCRqQFJv0AMF/'
    'dJCSUgAEAAAASgAAAANkdaGzdQk1XR01LQCkgQAA5ryr55S7XOesrDAx6K+dXHAxLnBuZwBvYis7'
    'dVwsewgwMd2LXABwMS5wAG5nAPD/7U244voACxl0kJJUABQAAABJAAAAAxArJEt1CTVdHTUvAKSB'
    'AADmvKvnlLtc56ysMDHor51ccDEwLnBuZwBvYis7dVwsewgwMd2LXABwMTAuAHBuZwDwuPRN/yLB'
    'J1FLE++QffpFKQOz5wbJB9BoOXSQklIAEQAAAEkAAAADM6bmLXUJNV0dNS0ApIEAAOa8q+eUu1zn'
    'rKwwMeivnVxwMi5wbmcAb2IrO3VcLHsIMDHdi1wAcDIucABuZwDwcfFNtoP8my9QNk+Mcme7Fa8I'
    'PoC6s3SQkC8AMAAAAPICAAADbunYinUJNV0dNQoApIEAAHJlYWRtZS50eHQA8KngTWJkcKwdaZoq'
    'xNKSBXTXBqxZcnXXhnxIaxYAm/TKoY0goMMRQxwSgrragLvoxksfQDkidJCSRABFAAAAuwUAAAM3'
    'R3HndQk1XR01HwCkgQAA5Lit5paH6K+05piOLnR4dABOai2HZfSLDmYALnR4dADwnOVNc3mm6dCv'
    '20QZUAvianO1d9zr5hctA93v4hcNWv2MiqNfhukpc7vRRbn7re5Oc7qTnHslqmLg2rXcnV7szbvr'
    'jGMZGfpA8Wp08JJCAAAAAAAAAAAAAwAAAAB1CTVdFDAdAO1BAADmvKvnlLtc56ysMDHor50Ab2Ir'
    'O3VcLHsIMDHdiwDw7PJNp4108JAoAAAAAAAAAAAAAwAAAAB1CTVdFDADAO1BAABzdWIA8OfnTaRW'
    'dPCSMQAAAAAAAAAAAAMAAAAAdQk1XRQwDADtQQAA5ryr55S7AG9gKzt1APCNDEnEPXsAQAcA';

/// `rar5_store.rar` —— 2986 字节
const String kRar5Store =
    'UmFyIRoHAQDz4YLrCwEFBwAGAQGAgIAAoqs2jysCAwvKAATKAKSDAmR1obOAAAENc3ViL2NvdmVy'
    'LnBuZwoDE88TsGrRkG8eiVBORw0KGgoAAAANSUhEUgAAAAgAAAAICAIAAABLbSncAAAAEUlEQVR4'
    '2mP4z8CAFTEMLQkAKP8/wc53yE8AAAAASUVORK5CYIJM20SMLgIDC7sLBLsLpIMCN0dx54AAARDk'
    'uK3mlofor7TmmI4udHh0CgMTzxOwav+wbR7nlLXlrZDkuaYgQ0JSIOa1i+ivlee0oOadkArov5nm'
    'mK/kuIDmrrXnlKjmnaXop6blj5HljovnvKnnmoTkuK3mlofmlofmnKzjgILov5nmmK/kuIDmrrXn'
    'lKjmnaXop6blj5HljovnvKnnmoTkuK3mlofmlofmnKzjgILov5nmmK/kuIDmrrXnlKjmnaXop6bl'
    'j5HljovnvKnnmoTkuK3mlofmlofmnKzjgILov5nmmK/kuIDmrrXnlKjmnaXop6blj5HljovnvKnn'
    'moTkuK3mlofmlofmnKzjgILov5nmmK/kuIDmrrXnlKjmnaXop6blj5HljovnvKnnmoTkuK3mlofm'
    'lofmnKzjgILov5nmmK/kuIDmrrXnlKjmnaXop6blj5HljovnvKnnmoTkuK3mlofmlofmnKzjgILo'
    'v5nmmK/kuIDmrrXnlKjmnaXop6blj5HljovnvKnnmoTkuK3mlofmlofmnKzjgILov5nmmK/kuIDm'
    'rrXnlKjmnaXop6blj5HljovnvKnnmoTkuK3mlofmlofmnKzjgILov5nmmK/kuIDmrrXnlKjmnaXo'
    'p6blj5HljovnvKnnmoTkuK3mlofmlofmnKzjgILov5nmmK/kuIDmrrXnlKjmnaXop6blj5Hljovn'
    'vKnnmoTkuK3mlofmlofmnKzjgILov5nmmK/kuIDmrrXnlKjmnaXop6blj5HljovnvKnnmoTkuK3m'
    'lofmlofmnKzjgILov5nmmK/kuIDmrrXnlKjmnaXop6blj5HljovnvKnnmoTkuK3mlofmlofmnKzj'
    'gILov5nmmK/kuIDmrrXnlKjmnaXop6blj5HljovnvKnnmoTkuK3mlofmlofmnKzjgILov5nmmK/k'
    'uIDmrrXnlKjmnaXop6blj5HljovnvKnnmoTkuK3mlofmlofmnKzjgILov5nmmK/kuIDmrrXnlKjm'
    'naXop6blj5HljovnvKnnmoTkuK3mlofmlofmnKzjgILov5nmmK/kuIDmrrXnlKjmnaXop6blj5Hl'
    'jovnvKnnmoTkuK3mlofmlofmnKzjgILov5nmmK/kuIDmrrXnlKjmnaXop6blj5HljovnvKnnmoTk'
    'uK3mlofmlofmnKzjgILov5nmmK/kuIDmrrXnlKjmnaXop6blj5HljovnvKnnmoTkuK3mlofmlofm'
    'nKzjgILov5nmmK/kuIDmrrXnlKjmnaXop6blj5HljovnvKnnmoTkuK3mlofmlofmnKzjgILov5nm'
    'mK/kuIDmrrXnlKjmnaXop6blj5HljovnvKnnmoTkuK3mlofmlofmnKzjgILov5nmmK/kuIDmrrXn'
    'lKjmnaXop6blj5HljovnvKnnmoTkuK3mlofmlofmnKzjgILov5nmmK/kuIDmrrXnlKjmnaXop6bl'
    'j5HljovnvKnnmoTkuK3mlofmlofmnKzjgILov5nmmK/kuIDmrrXnlKjmnaXop6blj5HljovnvKnn'
    'moTkuK3mlofmlofmnKzjgILov5nmmK/kuIDmrrXnlKjmnaXop6blj5HljovnvKnnmoTkuK3mlofm'
    'lofmnKzjgILov5nmmK/kuIDmrrXnlKjmnaXop6blj5HljovnvKnnmoTkuK3mlofmlofmnKzjgILo'
    'v5nmmK/kuIDmrrXnlKjmnaXop6blj5HljovnvKnnmoTkuK3mlofmlofmnKzjgILov5nmmK/kuIDm'
    'rrXnlKjmnaXop6blj5HljovnvKnnmoTkuK3mlofmlofmnKzjgILov5nmmK/kuIDmrrXnlKjmnaXo'
    'p6blj5HljovnvKnnmoTkuK3mlofmlofmnKzjgILov5nmmK/kuIDmrrXnlKjmnaXop6blj5Hljovn'
    'vKnnmoTkuK3mlofmlofmnKzjgILov5nmmK/kuIDmrrXnlKjmnaXop6blj5HljovnvKnnmoTkuK3m'
    'lofmlofmnKzjgIJn3s5SKAIDC/IFBPIFpIMCbunYioAAAQpyZWFkbWUudHh0CgMTzxOwajTCax5z'
    'eW5vbG9neV9jaGF0IGNiciBmaXh0dXJlCmhlbGxvIFJBUiBjb21wcmVzc2lvbiB3b3JsZCBoZWxs'
    'byBSQVIgY29tcHJlc3Npb24gd29ybGQgaGVsbG8gUkFSIGNvbXByZXNzaW9uIHdvcmxkIGhlbGxv'
    'IFJBUiBjb21wcmVzc2lvbiB3b3JsZCBoZWxsbyBSQVIgY29tcHJlc3Npb24gd29ybGQgaGVsbG8g'
    'UkFSIGNvbXByZXNzaW9uIHdvcmxkIGhlbGxvIFJBUiBjb21wcmVzc2lvbiB3b3JsZCBoZWxsbyBS'
    'QVIgY29tcHJlc3Npb24gd29ybGQgaGVsbG8gUkFSIGNvbXByZXNzaW9uIHdvcmxkIGhlbGxvIFJB'
    'UiBjb21wcmVzc2lvbiB3b3JsZCBoZWxsbyBSQVIgY29tcHJlc3Npb24gd29ybGQgaGVsbG8gUkFS'
    'IGNvbXByZXNzaW9uIHdvcmxkIGhlbGxvIFJBUiBjb21wcmVzc2lvbiB3b3JsZCBoZWxsbyBSQVIg'
    'Y29tcHJlc3Npb24gd29ybGQgaGVsbG8gUkFSIGNvbXByZXNzaW9uIHdvcmxkIGhlbGxvIFJBUiBj'
    'b21wcmVzc2lvbiB3b3JsZCBoZWxsbyBSQVIgY29tcHJlc3Npb24gd29ybGQgaGVsbG8gUkFSIGNv'
    'bXByZXNzaW9uIHdvcmxkIGhlbGxvIFJBUiBjb21wcmVzc2lvbiB3b3JsZCBoZWxsbyBSQVIgY29t'
    'cHJlc3Npb24gd29ybGQgaGVsbG8gUkFSIGNvbXByZXNzaW9uIHdvcmxkIGhlbGxvIFJBUiBjb21w'
    'cmVzc2lvbiB3b3JsZCBoZWxsbyBSQVIgY29tcHJlc3Npb24gd29ybGQgaGVsbG8gUkFSIGNvbXBy'
    'ZXNzaW9uIHdvcmxkIGhlbGxvIFJBUiBjb21wcmVzc2lvbiB3b3JsZCBoZWxsbyBSQVIgY29tcHJl'
    'c3Npb24gd29ybGQg2p37gzUCAwvJAATJAKSDAhArJEuAAAEX5ryr55S7L+esrDAx6K+dL3AxMC5w'
    'bmcKAxPPE7BqEphzHolQTkcNChoKAAAADUlIRFIAAAAIAAAACAgCAAAAS20p3AAAABBJREFUeNpj'
    'YGD4jwMNKQkAqXA/wfzLRfwAAAAASUVORK5CYIK1jgxoNAIDC8kABMkApIMCM6bmLYAAARbmvKvn'
    'lLsv56ysMDHor50vcDIucG5nCgMTzxOwakVQch6JUE5HDQoaCgAAAA1JSERSAAAACAAAAAgIAgAA'
    'AEttKdwAAAAQSURBVHjaY2D4z4AdDS0JAOkwP8EdgdwBAAAAAElFTkSuQmCC/0bfRTQCAwvKAATK'
    'AKSDAmR1obOAAAEW5ryr55S7L+esrDAx6K+dL3AxLnBuZwoDE88TsGq193AeiVBORw0KGgoAAAAN'
    'SUhEUgAAAAgAAAAICAIAAABLbSncAAAAEUlEQVR42mP4z8CAFTEMLQkAKP8/wc53yE8AAAAASUVO'
    'RK5CYIJSGozDKwIDCwAFAO2DAQAAAACAAAEP5ryr55S7L+esrDAx6K+dCgMTzxOwamLkch6FwIVv'
    'HwIDCwAFAO2DAQAAAACAAAEDc3ViCgMTzxOwan6Wbh64XJ2pIgIDCwAFAO2DAQAAAACAAAEG5ryr'
    '55S7CgMTzxOwah/niBwdd1ZRAwUEAA==';

/// `rar5_comp.rar` —— 928 字节
const String kRar5Comp =
    'UmFyIRoHAQDz4YLrCwEFBwAGAQGAgIAAoqs2jysCAwvKAATKAKSDAmR1obOAAAENc3ViL2NvdmVy'
    'LnBuZwoDE88TsGrRkG8eiVBORw0KGgoAAAANSUhEUgAAAAgAAAAICAIAAABLbSncAAAAEUlEQVR4'
    '2mP4z8CAFTEMLQkAKP8/wc53yE8AAAAASUVORK5CYIKmZKbDLgIDC+MABLsLpIMCN0dx54ADARDk'
    'uK3mlofor7TmmI4udHh0CgMTzxOwav+wbR7C+GAlQFMvkzvcKcWXA3IkRBogLEIoqKDSxUGMpYCg'
    'g4wyf/MSg4u29V3dlXsD9kImUxBV9HfhgifBRGpqHjEMCvN8tCxK+Yw3UJtHKybmdlFLJyD3qN0r'
    'pICub4v29jk/buD1NiXbKAIDC8AABPIFpIMCbunYioADAQpyZWFkbWUudHh0CgMTzxOwajTCax7H'
    'oD00BEIvlD/tFbSrQpQLFEUJOTWdwQC/5ClSh8y52xMofccPjzQP6UeSvSqw2jBEIdu7Kn7/IM0j'
    'MWKp2NOr2p37gzUCAwvJAATJAKSDAhArJEuAAAEX5ryr55S7L+esrDAx6K+dL3AxMC5wbmcKAxPP'
    'E7BqEphzHolQTkcNChoKAAAADUlIRFIAAAAIAAAACAgCAAAAS20p3AAAABBJREFUeNpjYGD4jwMN'
    'KQkAqXA/wfzLRfwAAAAASUVORK5CYIK1jgxoNAIDC8kABMkApIMCM6bmLYAAARbmvKvnlLsv56ys'
    'MDHor50vcDIucG5nCgMTzxOwakVQch6JUE5HDQoaCgAAAA1JSERSAAAACAAAAAgIAgAAAEttKdwA'
    'AAAQSURBVHjaY2D4z4AdDS0JAOkwP8EdgdwBAAAAAElFTkSuQmCC/0bfRTQCAwvKAATKAKSDAmR1'
    'obOAAAEW5ryr55S7L+esrDAx6K+dL3AxLnBuZwoDE88TsGq193AeiVBORw0KGgoAAAANSUhEUgAA'
    'AAgAAAAICAIAAABLbSncAAAAEUlEQVR42mP4z8CAFTEMLQkAKP8/wc53yE8AAAAASUVORK5CYIJS'
    'GozDKwIDCwAFAO2DAQAAAACAAAEP5ryr55S7L+esrDAx6K+dCgMTzxOwamLkch6FwIVvHwIDCwAF'
    'AO2DAQAAAACAAAEDc3ViCgMTzxOwan6Wbh64XJ2pIgIDCwAFAO2DAQAAAACAAAEG5ryr55S7CgMT'
    'zxOwah/niBwdd1ZRAwUEAA==';

/// `rar5_solid.rar` —— 789 字节
const String kRar5Solid =
    'UmFyIRoHAQAJ78hvCwEFBwQGAQGAgIAARMxklisCAwucAQTKAKSDAmR1obOAHQENc3ViL2NvdmVy'
    'LnBuZwoDE88TsGrRkG8exAeZJ2V1Qi90XtWlcLArRaYEO7J0QV4FC2JWEDRhb7KyaUMXqZjCuvJI'
    'IhCWCoqKC0zSErpsCggq1wILvR1rncx8DzQghmjvXwJQfAXQ7f///wOc4fH/yfmnh99q++0/aP3i'
    '/RuQdg0zRMAABp+ycgVXV/XWWXu1Fe2SpnnnPt2VYSbr/q2hq5um7BpXtb+rSf/bLIA+BBOpv0Zg'
    '6Lp/njQCAwuFAATKAKSDAmR1obPAHQEW5ryr55S7L+esrDAx6K+dL3AxLnBuZwoDE88TsGq193Ae'
    'Rx8CxQG8Ct8uNQIDC5YABMkApIMCECskS8AdARfmvKvnlLsv56ysMDHor50vcDEwLnBuZwoDE88T'
    'sGoSmHMeRA0TwIOc5ootzsw167BRjkBdqwLrgEM3uPQ0AgMLkwAEyQCkgwIzpuYtwB0BFua8q+eU'
    'uy/nrKwwMeivnS9wMi5wbmcKAxPPE7BqRVByHkELEMLA3XWeGl91zUcnnLZynACyOmcIKAIDC7EA'
    'BPIFpIMCbunYisAdAQpyZWFkbWUudHh0CgMTzxOwajTCax5BNS5WXGEmLjl7yUPfkBS4FA8USVI5'
    'FIRkOEmmIKD5AjooscjCqsQUYMkSifCHG6jAesYlgi4CAwvDAAS7C6SDAjdHcefAHQEQ5Lit5paH'
    '6K+05piOLnR4dAoDE88TsGr/sG0eRlxAZ612KU+39UA679AI15rVTsZ+PMflPMa/O8fdUt/Kw6a5'
    'L/YjXo160GJ3Ux0zWfuiz4cxIqQ+3nv54+9paZkbrBvsTdsrAgMLAAUA7YMBAAAAAMAAAQ/mvKvn'
    'lLsv56ysMDHor50KAxPPE7BqYuRyHuWwCNUfAgMLAAUA7YMBAAAAAMAAAQNzdWIKAxPPE7BqfpZu'
    'HkkRfF0iAgMLAAUA7YMBAAAAAMAAAQbmvKvnlLsKAxPPE7BqH+eIHB13VlEDBQQA';

/// `rar4_enc.rar` —— 162 字节
const String kRar4Enc =
    'UmFyIRoHAM+QcwAADQAAAAAAAAACyHQklDcAUAAAAPICAAADbunYinUJNV0dMwoApIEAAHJlYWRt'
    'ZS50eHS/lxErOO2AIwDwqeBNqCYVOYj5vQv1CWusgp4+m/0aW6sraVU4jVEfkrAI/WQ8efLoiC2s'
    'zqGzQChpwohsaM2PvizvXsQdAVmrFDdaGPBLfNVqomwKV/yQ9Jf5pRDEPXsAQAcA';

/// `rar5_enc.rar` —— 190 字节
const String kRar5Enc =
    'UmFyIRoHAQDz4YLrCwEFBwAGAQGAgIAA1d5dVlkCAzzAAATyBaSDAiD5C/GAAwEKcmVhZG1lLnR4'
    'dDABAAMPSl+OeizB7TNLkCoSwPuUUo7orJqrUMdArlusw9n0KvP+O+gfesc9hwev+0oKAxPPE7Bq'
    'NMJrHovaPGbA/MYYddkHQwNlHH05vaH/72woGR0e2/MkEHBOEyUQYih5TtAhnN74Th7mYapSKTm/'
    'coVbW/pAVijEE0odd1ZRAwUEAA==';

/// `rar4_trunc.rar` —— 744 字节
const String kRar4Trunc =
    'UmFyIRoHAM+QcwAADQAAAAAAAAC1cXQgkDIASgAAAEoAAAADZHWhs3UJNV0dMA0ApIEAAHN1Ylxj'
    'b3Zlci5wbmcA8GjqTYlQTkcNChoKAAAADUlIRFIAAAAIAAAACAgCAAAAS20p3AAAABFJREFUeNpj'
    '+M/AgBUxDC0JACj/P8HOd8hPAAAAAElFTkSuQmCCkcZ0IJJEAGkAAAC7BQAAAzdHced1CTVdHTMf'
    'AKSBAADkuK3mlofor7TmmI4udHh0AE5qLYdl9IsOZgAudHh0APCc5U0JQBkH3YETe4U4scDciSU0'
    'KfihCKaWCmM0sopTjDM+zOGLGvGlw5XtnuTe4H69wr2pExTjkNuJltpxkCwpJOjW4LZGE81BSQ2z'
    'oaF9Nisr04CPHKeKFHGSK310MKIPlmfTr3/tSlK8z2ii0nQgkC8ARQAAAPICAAADbunYinUJNV0d'
    'MwoApIEAAHJlYWRtZS50eHQA8KngTQ0BTIvlT/3CrirgpgLFEUJKnmWjFN7YH3cUO/ezjsN6RazB'
    'jmuj460J+yFxL6niQyjA2gnZuZR12wKshMvQh7lj12vx+qsUdCCSVABJAAAASQAAAAMQKyRLdQk1'
    'XR0wLwCkgQAA5ryr55S7XOesrDAx6K+dXHAxMC5wbmcAb2IrO3VcLHsIMDHdi1wAcDEwLgBwbmcA'
    '8Lj0TYlQTkcNChoKAAAADUlIRFIAAAAIAAAACAgCAAAAS20p3AAAABBJREFUeNpjYGD4jwMNKQkA'
    'qXA/wfzLRfwAAAAASUVORK5CYIKHWXQgklIASQAAAEkAAAADM6bmLXUJNV0dMC0ApIEAAOa8q+eU'
    'u1znrKwwMeivnVxwMi5wbmcAb2IrO3VcLHsIMDHdi1wAcDIucABuZwDwcfFNiVBORw0KGgoAAAAN'
    'SUhEUgAAAAgAAAAICAIAAABLbSncAAAAEElEQVR42mNg+M+AHQ0tCQDpMD/BHYHcAQAAAABJRU5E'
    'rkJg';

/// `rar5_corrupt.rar` —— 928 字节
const String kRar5Corrupt =
    'UmFyIRoHAQDz4YLrCwEFBwAGAQGAgIAAoqs2jysCAwvKAATKAKSDAmR1obOAAAENc3ViL2NvdmVy'
    'LnBuZwoDE88TsGrRkG8eiVBORw0KGgoAAAANSUhEUgAAAAgAAAAICAIAAABLbSncAAAAEUlEQVR4'
    '2mP4z8CAFTEMLQkAKP8/wc53yE8AAAAASUVORK5CYIKmZKbDLgIDC+MABLsLpIMCN0dx54ADARDk'
    'uK3mlofor7TmmI4udHh0CgMTzxOwav+wbR7C+GAlQFMvkzvcKcWXA3IkRBogLEIoqKDSxUGMpYCg'
    'g4wyf/MSg4u29V3dlXsD9kImUxBV9HfhgifBRGpqHjEMCvN8tCxK+Yw3UJtHKybmdlFLJyD3qN0r'
    'pICub4v29jk/buD1NiXbKAIDC8AABPIFpIMCbunYioADAQpyZWFkbWUudHh0CgMTzxOwajTCax7H'
    'oD00BEIvlD/tFbSrQpQLFEUJOTWdwQC/5ClSh8y52xMofccPjzQP6UeSvSqw2jBEIdu7Kn7/IM0j'
    'MWKp2NOr2p37gzUCAwvJAATJAKSDAhArJEuAAAEX5ryr55S7L+esrDAx6K+dL3AxMC5wbmcKAxPP'
    'E7BqEphzHomvTkcNChoKAAAADUlIRFIAAAAIAAAACAgCAAAAS20p3AAAABBJREFUeNpjYGD4jwMN'
    'KQkAqXA/wfzLRfwAAAAASUVORK5CYIK1jgxoNAIDC8kABMkApIMCM6bmLYAAARbmvKvnlLsv56ys'
    'MDHor50vcDIucG5nCgMTzxOwakVQch6JUE5HDQoaCgAAAA1JSERSAAAACAAAAAgIAgAAAEttKdwA'
    'AAAQSURBVHjaY2D4z4AdDS0JAOkwP8EdgdwBAAAAAElFTkSuQmCC/0bfRTQCAwvKAATKAKSDAmR1'
    'obOAAAEW5ryr55S7L+esrDAx6K+dL3AxLnBuZwoDE88TsGq193AeiVBORw0KGgoAAAANSUhEUgAA'
    'AAgAAAAICAIAAABLbSncAAAAEUlEQVR42mP4z8CAFTEMLQkAKP8/wc53yE8AAAAASUVORK5CYIJS'
    'GozDKwIDCwAFAO2DAQAAAACAAAEP5ryr55S7L+esrDAx6K+dCgMTzxOwamLkch6FwIVvHwIDCwAF'
    'AO2DAQAAAACAAAEDc3ViCgMTzxOwan6Wbh64XJ2pIgIDCwAFAO2DAQAAAACAAAEG5ryr55S7CgMT'
    'zxOwah/niBwdd1ZRAwUEAA==';

/// `rar4_vol.part1.rar` —— 1024 字节
const String kRar4VolPart1 =
    'UmFyIRoHAFpucxEBDQAAAAAAAAC2VnQikkQAlAMAALsFAAADehY3mXUJNV0UMB8ApIEAAOS4reaW'
    'h+ivtOaYji50eHQATmoth2X0iw5mAC50eHQA8JzlTeeUteWtkOS5piBDQlIg5rWL6K+V57Sg5p2Q'
    'Cui/meaYr+S4gOauteeUqOadpeinpuWPkeWOi+e8qeeahOS4reaWh+aWh+acrOOAgui/meaYr+S4'
    'gOauteeUqOadpeinpuWPkeWOi+e8qeeahOS4reaWh+aWh+acrOOAgui/meaYr+S4gOauteeUqOad'
    'peinpuWPkeWOi+e8qeeahOS4reaWh+aWh+acrOOAgui/meaYr+S4gOauteeUqOadpeinpuWPkeWO'
    'i+e8qeeahOS4reaWh+aWh+acrOOAgui/meaYr+S4gOauteeUqOadpeinpuWPkeWOi+e8qeeahOS4'
    'reaWh+aWh+acrOOAgui/meaYr+S4gOauteeUqOadpeinpuWPkeWOi+e8qeeahOS4reaWh+aWh+ac'
    'rOOAgui/meaYr+S4gOauteeUqOadpeinpuWPkeWOi+e8qeeahOS4reaWh+aWh+acrOOAgui/meaY'
    'r+S4gOauteeUqOadpeinpuWPkeWOi+e8qeeahOS4reaWh+aWh+acrOOAgui/meaYr+S4gOauteeU'
    'qOadpeinpuWPkeWOi+e8qeeahOS4reaWh+aWh+acrOOAgui/meaYr+S4gOauteeUqOadpeinpuWP'
    'keWOi+e8qeeahOS4reaWh+aWh+acrOOAgui/meaYr+S4gOauteeUqOadpeinpuWPkeWOi+e8qeea'
    'hOS4reaWh+aWh+acrOOAgui/meaYr+S4gOauteeUqOadpeinpuWPkeWOi+e8qeeahOS4reaWh+aW'
    'h+acrOOAgui/meaYr+S4gOauteeUqOadpeinpuWPkeWOi+e8qeeahOS4reaWh+aWh+acrOOAgui/'
    'meaYr+S4gOauteeUqOadpeinpuWPkeWOi+e8qeeahOS4reaWh+aWh+acrOOAgui/meaYr+S4gOau'
    'teeUqOadpeinpuWPkeWOi+e8qeeahOS4reaWh+aWh+acrOOAgui/meaYr+S4gOauteeUqOadpein'
    'puWPkeWOi+e8qeeahOS4reaWh+aWh+acrOOAgui/meaYr+S4gOauteeUqOadpeinpuWPkeWOi+e8'
    'qeeahOS4reaWh+aWh+acrOOAgui/meaYr+S4gOauteeUqOadpeinpuWPkeWOi+e8qeeahOS4reaW'
    'h+aWh+acrOOAgui/meaYr+S4gOauteeUqOadpeinpuWPkeWiDHsPQBQAjHnCOQAAAAAAAAAAAA==';

/// `rar4_vol.part2.rar` —— 659 字节
const String kRar4VolPart2 =
    'UmFyIRoHABl6cxEADQAAAAAAAAC8hXQhkkQAJwIAALsFAAADN0dx53UJNV0UMB8ApIEAAOS4reaW'
    'h+ivtOaYji50eHQATmoth2X0iw5mAC50eHQA8JzlTY6L57yp55qE5Lit5paH5paH5pys44CC6L+Z'
    '5piv5LiA5q6155So5p2l6Kem5Y+R5Y6L57yp55qE5Lit5paH5paH5pys44CC6L+Z5piv5LiA5q61'
    '55So5p2l6Kem5Y+R5Y6L57yp55qE5Lit5paH5paH5pys44CC6L+Z5piv5LiA5q6155So5p2l6Kem'
    '5Y+R5Y6L57yp55qE5Lit5paH5paH5pys44CC6L+Z5piv5LiA5q6155So5p2l6Kem5Y+R5Y6L57yp'
    '55qE5Lit5paH5paH5pys44CC6L+Z5piv5LiA5q6155So5p2l6Kem5Y+R5Y6L57yp55qE5Lit5paH'
    '5paH5pys44CC6L+Z5piv5LiA5q6155So5p2l6Kem5Y+R5Y6L57yp55qE5Lit5paH5paH5pys44CC'
    '6L+Z5piv5LiA5q6155So5p2l6Kem5Y+R5Y6L57yp55qE5Lit5paH5paH5pys44CC6L+Z5piv5LiA'
    '5q6155So5p2l6Kem5Y+R5Y6L57yp55qE5Lit5paH5paH5pys44CC6L+Z5piv5LiA5q6155So5p2l'
    '6Kem5Y+R5Y6L57yp55qE5Lit5paH5paH5pys44CC6L+Z5piv5LiA5q6155So5p2l6Kem5Y+R5Y6L'
    '57yp55qE5Lit5paH5paH5pys44CC6L+Z5piv5LiA5q6155So5p2l6Kem5Y+R5Y6L57yp55qE5Lit'
    '5paH5paH5pys44CCRq17DkAUAChgsu8BAAAAAAAAAAA=';
