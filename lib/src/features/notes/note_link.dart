// N2 笔记链接（`notestation://`）—— **纯函数**（可离线单测）。
//
// 官方取证：`fragments/NoteLinkDialogFragment` + 编辑器命令
// `CMD_CREATE_LINK`；链接 URI 形态由官方 Web/Android 统一为
// `notestation://local/self/<noteId>`（本地库内的笔记）。
//
// 这里把形态**收拢成一处**（原先散在编辑器里内联拼接），
// 便于离线断言 —— 形态错了在真机上表现为"点链接没反应"，很难查。
library;

/// 本地笔记的 `notestation://` URI。
String noteLinkUri(String noteId) => 'notestation://local/self/$noteId';

/// 从链接 URI 里取回笔记 id；不是本地笔记链接时返回 null。
///
/// * `notestation://local/self/<id>` → `<id>`
/// * 其它（外部 http、共享链接 `notestation://.../shared/...`）→ null
String? noteIdFromLink(String? href) {
  if (href == null) return null;
  const prefix = 'notestation://local/self/';
  if (!href.startsWith(prefix)) return null;
  final id = href.substring(prefix.length);
  return id.isEmpty ? null : id;
}
