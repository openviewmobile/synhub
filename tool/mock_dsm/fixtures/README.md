# Mock 夹具

`<api>.<method>.json`，内容是响应的 **`data`**（不含 `success`/`error` 信封）。

## 铁律

**每个夹具都必须在 `_source` 里写清出处**，只允许三种来源：

1. **反编译 SPK / APK** 里的解析代码或常量；
2. **真机 / 真 NAS 只读探针**的逐字回包（写清是哪个文档/哪次探测）；
3. Synology **官方 Web 前端 JS**。

**凭印象编一个"看起来像"的形状是被禁止的** —— 夹具是"服务端返回数据"的
权威来源，编了就等于伪造证据。

## 已有

| 夹具 | 来源 |
|---|---|
| `SYNO.FileStation.PhotoUpload.upload.json` | 真机只读探针（`docs/filestation-worm-photoupload-wave.md`） |
