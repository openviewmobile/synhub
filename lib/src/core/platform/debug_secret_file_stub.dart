// Web / 非 io 宿主：永远不用文件后端（`dart:io` 在这里不存在）。
bool debugSecretFileMode() => false;

Future<String?> debugSecretFileRead(String key) async =>
    throw UnsupportedError('debug secret file 只在 io 宿主可用');

Future<void> debugSecretFileWrite(String key, String value) async =>
    throw UnsupportedError('debug secret file 只在 io 宿主可用');

Future<void> debugSecretFileDelete(String key) async =>
    throw UnsupportedError('debug secret file 只在 io 宿主可用');
