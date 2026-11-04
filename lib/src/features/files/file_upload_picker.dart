// 「上传文件」的**选择器缝隙**（Files 页 `FAB → Upload file`）。
//
// ## 为什么要有这个文件
//
// `FilePicker.pickFile()` 是**静态 API**，macOS 上会拉起 `NSOpenPanel`、
// Android 上拉起 SAF 选择器 —— **原生面板在自动化里点不到**（§2.0.9 同族问题：
// 平台弹层既不在 Flutter 树里，也拿不到它的句柄）。
// 于是"上传"这条写动词一直只能验到"API 层会拼 multipart"，验不到
// "FAB → 选文件 → 冲突检测 → 上传 → 列表刷新"整链。
//
// 把选择器抽成 **typedef + provider** 后，用例可以注入一个返回临时文件的假选择器，
// 让整链真的跑一遍（Mock 服务端收到字节并落进内存树）。
// 这与 notes 侧既有的 `noteFilePickerProvider`（`note_picker.dart`）**同一手法** ——
// 本仓已经有这个模式，这里不再另造第二种。
//
// ★ 注意：**不改变默认行为**。默认实现就是原来的 `FilePicker.pickFile()`，
//   生产路径逐字不变（用户取消 → 返回 `null` → 与改动前一样直接 return）。
import 'package:file_picker/file_picker.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// 一次"选到的文件"：只要路径与文件名（上传用的是**路径**，不是字节）。
class PickedUploadFile {
  const PickedUploadFile({required this.path, required this.name, this.size});

  final String path;
  final String name;

  /// 字节数（埋点用）。取不到就是 `null` —— **不要**编一个 0 冒充真实大小。
  ///
  /// ★ 来源是 `PlatformFile.lengthSync()`（**平台自己上报**的大小，不做 I/O），
  /// 与抽取前的原代码逐字等价。**不要**为了它去引入 dart:io 的导入 ——
  /// `test/platform_web_test.dart` 盯着 `lib/` 里导入 dart:io 的文件数
  /// （**只许缩不许涨**），r319 第一版就是因此把 82 涨到 83、全量 -1。
  ///
  /// ⚠️ 那个扫描器是**纯文本**正则 `import\s+'dart:([a-z0-9_]+)'`：
  /// 上面这行注释里如果**原样写出**那句导入语句，它也会被数进去（r319 真的踩了
  /// —— 去掉真导入后计数**纹丝不动**，因为注释里还留着一份）。
  final int? size;
}

typedef FileUploadPicker = Future<PickedUploadFile?> Function();

/// 生产默认实现（与抽取前逐字等价：取消/没有路径 ⇒ `null`）。
Future<PickedUploadFile?> pickUploadFileFromPlatform() async {
  final f = await FilePicker.pickFile();
  final path = f?.path;
  if (f == null || path == null) return null;
  return PickedUploadFile(path: path, name: f.name, size: f.lengthSync());
}

final fileUploadPickerProvider = Provider<FileUploadPicker>(
  (ref) => pickUploadFileFromPlatform,
);
