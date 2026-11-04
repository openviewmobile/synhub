import '../../core/media/camera_support.dart';
// 笔记编辑器的图片来源（可注入，便于离线测试）。
//
// 官方 DS note 的插入图片有三个入口：相册、拍照、文件；我们额外加了「从 NAS 选」
// （走 FileStation 的文件浏览）。这里只包**本地**三个入口，NAS 那个是纯 UI
// 流程（见 `note_nas_picker.dart`），因为它要用到 BuildContext。
import 'package:file_picker/file_picker.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:image_picker/image_picker.dart';
import 'package:record/record.dart';

/// `painting` 不是"选一张已有的图"，而是打开绘图板现画（见
/// `note_drawing_page.dart`）；编辑器在调 picker 之前就把它分流了，
/// 所以 [pickLocalNoteImages] 对它返回空列表。
///
/// `audio` / `video`（C4/C5）也不是"选图"：录音走 [NoteAudioRecorder]（编辑器
/// 里弹录音面板），录像走 `image_picker` 的 `pickVideo`，结果都作为**普通文件
/// 附件**上传（不进正文 image embed）。
enum NotePickSource { gallery, camera, file, nas, painting, audio, video }

/// 选好的一张图（还没上传）
class NotePickedImage {
  const NotePickedImage({
    required this.path,
    required this.name,
    this.mimeType,
  });

  final String path;
  final String name;
  final String? mimeType;
}

/// 相册/拍照/文件选择。测试里用 `noteLocalPickerProvider` 覆盖掉。
typedef NoteLocalPicker =
    Future<List<NotePickedImage>> Function(NotePickSource source);

final noteLocalPickerProvider = Provider<NoteLocalPicker>(
  (ref) => pickLocalNoteImages,
);

/// 选**任意文件**（非图片附件；官方工具栏 `add_attachment`）。
///
/// 与图片来源分开：图片走 Quill image embed（正文里能看到图），
/// 普通文件只作为**附件**上传并在附件列表里出现（官方也是这样，不发裂图）。
typedef NoteFilePicker = Future<List<NotePickedImage>> Function();

final noteFilePickerProvider = Provider<NoteFilePicker>(
  (ref) => pickNoteFiles,
);

Future<List<NotePickedImage>> pickNoteFiles() async {
  final files = await FilePicker.pickFiles();
  return [
    for (final f in files)
      if (f.path != null) NotePickedImage(path: f.path!, name: f.name),
  ];
}

Future<List<NotePickedImage>> pickLocalNoteImages(NotePickSource source) async {
  switch (source) {
    case NotePickSource.gallery:
      final files = await ImagePicker().pickMultiImage();
      return [
        for (final f in files)
          NotePickedImage(path: f.path, name: f.name, mimeType: f.mimeType),
      ];
    case NotePickSource.camera:
      // ★ DA293：入口已经按平台门控（桌面不摆「拍照」），这里再兜一层 ——
      //   万一有别的调用点绕过 UI，也要**响亮失败**而不是抛插件内部的
      //   `UnimplementedError`（那会被上层当"用户取消"吞掉）。
      if (!kCameraCaptureSupported) {
        throw UnsupportedError('这台设备没有可用的相机');
      }
      final shot = await ImagePicker().pickImage(source: ImageSource.camera);
      if (shot == null) return const [];
      return [
        NotePickedImage(
          path: shot.path,
          name: shot.name,
          mimeType: shot.mimeType,
        ),
      ];
    case NotePickSource.file:
      // file_picker 13 起是静态 API（`FilePicker.platform` 没了）
      final f = await FilePicker.pickFile();
      if (f?.path == null) return const [];
      return [NotePickedImage(path: f!.path!, name: f.name)];
    case NotePickSource.nas:
      // NAS 来源由 UI 层处理（需要 BuildContext 弹文件浏览）
      return const [];
    case NotePickSource.painting:
      // 绘图板由 UI 层处理（需要 Navigator + 导出 PNG）
      return const [];
    case NotePickSource.audio:
      // 录音由 UI 层处理（需要录音面板 + [NoteAudioRecorder]）
      return const [];
    case NotePickSource.video:
      // C5 录像：官方 DS note「拍照/录像」同一入口；视频作为文件附件
      // ★ DA293：同上，桌面端没有相机实现
      if (!kCameraCaptureSupported) {
        throw UnsupportedError('这台设备没有可用的相机');
      }
      final video = await ImagePicker().pickVideo(source: ImageSource.camera);
      if (video == null) return const [];
      return [
        NotePickedImage(
          path: video.path,
          name: video.name,
          mimeType: video.mimeType,
        ),
      ];
  }
}

/// 笔记录音（可注入；真机用 `record` 包，测试注入假实现）。
///
/// 官方 Android `views/AudioRecordingView.java`：文件名
/// `file_<System.currentTimeMillis()>` + `EXT = ".3gp"` —— 逐字照抄。
abstract class NoteAudioRecorder {
  Future<bool> hasPermission();
  Future<void> start(String path);
  Future<String?> stop();

  /// 放弃并删除临时文件
  Future<void> cancel();
}

/// 笔记录音的官方文件名（`file_<millis>.3gp`）
String noteAudioFileName([DateTime? now]) =>
    'file_${(now ?? DateTime.now()).millisecondsSinceEpoch}.3gp';

class RecordNoteAudioRecorder implements NoteAudioRecorder {
  final _rec = AudioRecorder();

  @override
  Future<bool> hasPermission() => _rec.hasPermission();

  @override
  Future<void> start(String path) =>
      _rec.start(const RecordConfig(encoder: AudioEncoder.aacLc), path: path);

  @override
  Future<String?> stop() => _rec.stop();

  @override
  Future<void> cancel() => _rec.cancel();
}

final noteAudioRecorderProvider = Provider<NoteAudioRecorder>(
  (ref) => RecordNoteAudioRecorder(),
);
