# 设计规格（spec）—— 设计与代码的**唯一真源**

一个界面 = 一份 `*.json`。同一份 spec 有两个消费者：

| 消费者 | 产物 | 用途 |
|---|---|---|
| `design/emit_svg.py` | `design/gen/svg/<id>.svg` + PNG | 设计稿（评审用、可导入 Figma） |
| `design/emit_flutter.py` | `design/gen/flutter/<id>_page.dart` | **Flutter 界面代码**（可直接被 analyzer 校验） |

## 节点类型（第一批）

```jsonc
{
  "id": "audio_library",              // 唯一 id
  "unit": "lib/src/features/audio/audio_page.dart",  // 对应的"界面单元"（矩阵台账文件名）
  "title": "音乐库",
  "appbar": { "actions": ["search", "more"] },        // 顶栏动作（顺序即视觉顺序）
  "tabs": ["歌曲", "专辑", ...],                       // 可滚动 tab（有则渲染 TabBar）
  "body": { "type": "list", "items": [ {"title": "...", "sub": "...", "lead": "cover", "trail": "more"} ] },
  "bottomNav": null,                  // "chat"|"files"|"photos"|"workspace"|"me"|null
  "fab": false
}
```

`body.type` 支持的形态：`list` / `grid` / `player` / `settings` / `form` / `empty`。
`items[].trail`：`more` / `play` / `check` / 文本。
`items[].lead`：`cover` / `icon` / 色值。

## 为什么这样设计

代码生成不是"截图转代码"，而是**同一棵语义树分别渲染成设计稿和 Widget 树**：
所以设计改了 → 代码跟着变；代码改了 → 设计稿跟着变。两边不会漂移。
