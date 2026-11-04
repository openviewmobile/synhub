# 本地 Mock NAS 服务器（`tool/mock_nas/`）

> 目的：**在没有 NAS 口令、不动真机的前提下**，把两件事做成可复现：
> ① 「会话失效」路径（`sessionExpired`，DSM 错误码 **119**）；
> ② 「服务端未提供该服务」时的**降级**（能力表 `SYNO.API.Info` 里缺 API）。
>
> 依据：`docs/service-availability-design.md` §6 方案 B、
> `docs/device-batch-r5-taskbook.md` §8。
> 真机验证的**任务书**在 `docs/device-batch-r5-taskbook.md` §8，本文件只讲怎么把
> mock 跑起来、每个开关的**实测原始输出**、以及真机接入的两种跑法。

---

## 0. 一句话

App 用 DSM `webapi` 风格接口（`query.cgi` / `auth.cgi` / `entry.cgi`）。本 mock 用
**零三方依赖的 Dart** 实现这几条接口，启动参数决定：

* 能力表里声明哪些 API（→ 验降级）；
* FileStation `Download` / `List` 回什么（→ 验 `119` / `105`）；
* `Range` 认不认（→ 标定 `206` vs `200`）。

登录**不看口令**，回一个明显的假 `sid`（`MOCK-SID-n`）。

---

## 1. 运行前提

只需要 Dart。本机 `dart` 不在 `PATH` 时，用 Flutter SDK 自带的：

```bash
DART=<flutter-sdk>/bin/dart      # 本机实测可用（Dart 3.13.3）
# 或者
export PATH="$PATH:<flutter-sdk>/bin"
```

> 脚本里用 `dart <file>` 而不是 `dart run <file>`：同时起多个实例时，`dart run` 的
> native-assets 打包步骤会并发互踩（`Failed to codesign dylib ...`）。`dart <file>` 无此问题。

本目录**零三方依赖**（只用 `dart:io` / `dart:convert`），但仓库本身是 Flutter 工程，
`dart` 仍会走一次 pub 解析；首次运行稍慢属正常。

---

## 2. 快速开始（HTTP 模式，宿主内自测）

```bash
cd $HOME/Documents/synology_chat
DART=<flutter-sdk>/bin/dart

# 只声明 FileStation（默认）
$DART tool/mock_nas/mock_nas_server.dart --port=8788

# 真机接入要监听局域网：默认已是 0.0.0.0
# 宿主局域网 IP：
ipconfig getifaddr en0          # 本机实测 → 10.254.254.39
```

启动输出：

```
[mock] 本地 Mock NAS 已启动
[mock]   监听        : http://0.0.0.0:8788
[mock]   SYNO.API.Info : 声明 19 个 API
[mock]   Range       : 开（206 + Content-Range）
[mock]   Download 字节: 1048576（合成）
[mock]   download-error=- truncate-after=- list-error=- error-http-status=200
[mock] 真机填的服务器地址：http://<宿主局域网IP>:8788
[mock] 假凭据：account=mock  password=mock（随便填，登录不看口令）
```

---

## 3. 选项

| 选项 | 作用 |
|---|---|
| `--port=<n>` | 监听端口（默认 `8788`） |
| `--host=<addr>` | 绑定地址（默认 `0.0.0.0`，便于真机访问） |
| `--apis=<spec>` | 能力表声明哪些服务：`file`（默认） / `all` / `none` / `file,photo,chat` 逗号组合。服务名：`file photo chat note calendar contacts drive office audio download surveillance mailplus` |
| `--api-info-empty` | 去掉**全部套件服务**，只留核心 API（见下方 ⚠️） |
| `--literal-api-info-empty` | 字面意义的"只剩 `SYNO.API.Info`"（观测用；App 会登不进） |
| `--download-error=<code>` | FileStation `Download` 一律回该错误码（如 `119`） |
| `--download-truncate-after=<n>` | `Download` 先发 `n` 字节再断流；随后**该 sid 的所有请求**回 `119` |
| `--list-error=<code>` | FileStation `List` 回该错误码（如 `105` 无权限） |
| `--range=off` | 忽略 `Range`，一律 `200`（对照默认 `206`） |
| `--download-bytes=<n>` | 内置合成媒体大小（默认 `1048576`） |
| `--media-file=<path>` | 改用真实文件做 `Download` 内容（如 `clip-h264.mp4`） |
| `--error-http-status=<n>` | 注入错误用的 HTTP 状态（默认 `200`；`403` 见 §6 的坑） |
| `--https` / `--cert=` / `--key=` | 开 HTTPS（默认用自带的 `mock_nas_cert.pem` / `mock_nas_key.pem`） |
| `--api-table=<path>` | 追加/覆盖 API 版本表（JSON） |
| `--verbose` | 逐请求日志（口令/`_sid`/`SynoToken` 已脱敏） |

### ⚠️ `--api-info-empty` 为什么不是"字面只剩 `SYNO.API.Info`"

客户端的 `_prepare()`（`lib/src/dsm/webapi.dart:1200`）**先查能力表**：表里没有的 API
**直接本地抛 `102`**，请求根本不发。少了 `SYNO.API.Encryption`，`login()` 第一步
`getinfo` 就 `102`，连登都登不进去，也就验不了降级。

真实 DSM 的能力表**恒含** `SYNO.API.Info` / `SYNO.API.Encryption` / `SYNO.API.Auth`
（与装没装套件无关）。所以本 mock：

* `--api-info-empty` = 去掉全部**套件服务**，保留这 3 条核心 API（**推荐用这个**）；
* `--literal-api-info-empty` = 真的只剩 `SYNO.API.Info`（用 `probe_client.dart` 实测
  会在 `login()` 本地抛 `DsmApiException(API 不存在 @ SYNO.API.Encryption.getinfo, code=102)`）。

这个选择是**实测踩出来**的，不是设计臆测：最初版本按字面实现，真实客户端连登录
都进不去。

---

## 4. 故障注入的实测原始输出

以下都是**本机实跑**（`bash tool/mock_nas/selftest.sh`，`PASS=28 FAIL=0`），
未做任何删改。

### 4.1 能力表可切换

`--apis=file`（默认）→ 只声明 FileStation（+ 核心 API）：

```bash
curl -s 'http://127.0.0.1:18088/webapi/query.cgi?api=SYNO.API.Info&version=1&method=query&query=all'
```

```json
{"success":true,"data":{"SYNO.API.Info":{"path":"query.cgi","minVersion":1,"maxVersion":1},"SYNO.API.Encryption":{...},"SYNO.API.Auth":{...},"SYNO.FileStation.List":{"path":"entry.cgi","minVersion":1,"maxVersion":2},"SYNO.FileStation.Download":{"path":"entry.cgi","minVersion":1,"maxVersion":2}, ...仅 FileStation...}}
```

未声明的 API → `102`（与真实 DSM 一致）：

```bash
curl -s 'http://127.0.0.1:18088/webapi/entry.cgi?api=SYNO.Foto.Browse.Item&version=1&method=list&_sid=MOCK-SID-1'
# {"success":false,"error":{"code":102}}
```

`--api-info-empty` → 无任何套件服务，核心仍在：

```json
{"success":true,"data":{"SYNO.API.Info":{"path":"query.cgi","minVersion":1,"maxVersion":1},"SYNO.API.Encryption":{"path":"encryption.cgi","minVersion":1,"maxVersion":1},"SYNO.API.Auth":{"path":"auth.cgi","minVersion":1,"maxVersion":7}}}
```

`--apis=all` → 96 条（`probe_client.dart` 实测 `SYNO.Foto.Browse.Item=true`、`SYNO.Chat.Channel=true`）。

### 4.2 登录（假 `sid`）

```bash
curl -s 'http://127.0.0.1:18088/webapi/auth.cgi?api=SYNO.API.Auth&version=7&method=login&session=Chat'
# {"success":true,"data":{"sid":"MOCK-SID-1","synotoken":"MOCK-TOKEN-1","device_id":"MOCK-DID"}}
```

`encryption.cgi` 的 `getinfo` 回一份**结构合法**的 mock RSA 公钥（App 登录时会真做
`RSA/ECB/PKCS1`），密文我们**不解读**。

### 4.3 `--download-error=119`

```bash
curl -s -D - 'http://127.0.0.1:8790/webapi/entry.cgi?api=SYNO.FileStation.Download&method=download&_sid=MOCK-SID-1'
```

```
HTTP/1.1 200 OK
content-type: application/json; charset=utf-8
content-length: 38

{"success":false,"error":{"code":119}}
```

### 4.4 `--list-error=105`（无权限）

```
HTTP/1.1 200 OK
content-type: application/json; charset=utf-8
content-length: 38

{"success":false,"error":{"code":105}}
```

### 4.5 `--range=off` 对照（`206` vs `200`）

支持 Range（默认）：

```
$ curl -s -D - -o /dev/null -H 'Range: bytes=0-63' '.../entry.cgi?api=SYNO.FileStation.Download&method=download&_sid=MOCK-SID-1'
HTTP/1.1 206 Partial Content
accept-ranges: bytes
content-length: 64
content-type: application/octet-stream
content-range: bytes 0-63/1048576
```

`--range=off`：

```
HTTP/1.1 200 OK
content-type: application/octet-stream
accept-ranges: none
content-length: 1048576
```

> 后缀范围也正确：`Range: bytes=-16` → `content-range: bytes 1048560-1048575/1048576`。

### 4.6 `--download-truncate-after=4096`（"播到一半会话失效"）

**第一次**请求：声明完整长度，实际只发 4096 字节就断流 → 客户端提前 EOF（`curl` exit 18）：

```
HTTP/1.1 206 Partial Content
accept-ranges: bytes
content-length: 1048576
content-type: application/octet-stream
content-range: bytes 0-1048575/1048576

curl_exit=18  收到字节=4096
```

**同一 sid 的下一次**请求（播放器重试）→ `119`：

```
HTTP/1.1 200 OK
content-type: application/json; charset=utf-8
content-length: 38

{"success":false,"error":{"code":119}}
```

**该 sid 的其它接口**（如 `List`）同样 `119`。

**重新登录**拿到新 sid（`MOCK-SID-2`），会话可恢复（避免"一失效就永远失效"）。

---

## 5. 自测：两条命令

```bash
# 全量：能力表切换 / 未声明 102 / 119 / 105 / api-info-empty / 206 vs 200 /
# 截断 / 重登恢复 / 真实客户端兼容 —— 打印原始 curl 输出 + PASS/FAIL
bash tool/mock_nas/selftest.sh

# 用**本项目真实 DSM 客户端代码**打 mock（证明协议兼容：登录 RSA 加密、
# 能力表解析、_sid/SynoToken 拼装、119 解析）
$DART tool/mock_nas/probe_client.dart --url=http://127.0.0.1:8788
```

`probe_client.dart` 实测（`--apis=file`）：

```
[probe] discover：19 个 API
[probe]   SYNO.FileStation.List   = true
[probe]   SYNO.FileStation.Download = true
[probe]   SYNO.Foto.Browse.Item  = false
[probe]   SYNO.Chat.Channel      = false
[probe] login OK：sid=MOCK-S…(10) synotoken=MOCK-T…(12)
[probe] List /home/Books：4 项 → Books/, Photos/, mock-clip.mp4, session-expiry.txt
[probe] downloadUrl：has _sid=true has SynoToken=true api=SYNO.FileStation.Download method=download
[probe] getBytes(maxBytes=64)：收到 64 字节（若 --range=off 会明显多于 64）
[probe] call List：成功（会话仍有效）
```

截断实例上，同一次 probe 的后续调用落到 `sessionExpired`：

```
[probe] call List 抛 DsmApiException code=119 → sessionExpired 分支（会话失效）
```

---

## 6. 真机怎么接（**http vs https 两种跑法**）

App「添加服务器」允许直接填 URL（`ServerProfile.normalizedBaseUrl`：无协议补
`https://`，显式带 `http://` 就按 http 走）。所以：

| 跑法 | 启动命令 | App 里填 | 宿主侧实测 |
|---|---|---|---|
| **HTTP** | `dart tool/mock_nas/mock_nas_server.dart --port=8788` | `http://10.254.254.39:8788` | ✅ curl / 真实客户端代码都通 |
| **HTTPS 自签** | `dart tool/mock_nas/mock_nas_server.dart --port=8788 --https` | `https://10.254.254.39:8788` | ✅ `curl -k` / 真实客户端代码都通 |

> `10.254.254.39` 是本机 `en0` 的实测地址；换机器用 `ipconfig getifaddr en0` 重新取。
> 端口随便挑，只要 App 里填的一致（默认建议 `8788`）。

### 宿主侧实测结论（已做）

* **HTTP**：`curl http://127.0.0.1:8788/...` 全通；`probe_client.dart`（本项目真实
  `DsmWebApi` + `DirectTransport` + `DioFactory`）打 `http://127.0.0.1:18088` **登录、
  列目录、取流、解析 119 全部成功**。
* **HTTPS 自签**：`--https` 起得来，`curl -k https://127.0.0.1:18094/...` 通，
  证书 `CN=mock-nas.local`，sha256 指纹
  `62:C8:B0:62:55:5B:9B:ED:47:90:3A:9B:85:73:F1:91:55:D5:24:86:AB:AF:13:31:A0:F6:80:8E:86:46:6F:7C`，
  SAN 覆盖 `localhost / mock-nas.local / 127.0.0.1 / 10.254.254.39 / 10.254.254.114`。
  自带证书是**仅供 mock 的抛弃式自签证书**（私钥 `mock_nas_key.pem` 也在仓库里，无所谓泄露）。

### 真机上哪种能连上：**未实测**（如实说明）

设备被另一批次独占，本次**没有动设备**，所以下面是**预判**而不是结论，真机批次须实测后回填：

* **HTTP 的主要风险**：`android/app/src/main/AndroidManifest.xml` **没有**
  `android:usesCleartextTraffic="true"`，也没有 `networkSecurityConfig`，而
  `targetSdk=36`（Android 9+ 默认禁明文）。本项目 Android 侧 HTTP 走
  `dio` → `IOHttpClientAdapter` → `dart:io HttpClient`（自实现 socket，历史上不经过
  Android `NetworkSecurityPolicy`），**有可能明文可用**；但这依赖 Flutter/dart:io 的
  当前行为，**必须在真机上判定**。若被拒，App 会表现为连接失败/握手错误。
* **HTTPS 自签的有利点**：`DioFactory.create()` **默认 `allowSelfSigned=true`**（自签
  证书与 IP 访问不受信任时也放行），且自带证书带 IP SAN。若 App 走
  `trustPolicy`（首连信任）会先要求确认指纹，那就用上面的 sha256 指纹核对。
  因此**预判 HTTPS 自签更可能直接连通**。
* **判定要求**：真机批次按任务书 §8 记录「App 里填的是什么协议 / 连接是否成功 /
  失败时的原始文案或 logcat」。任一条跑不通就写「未验证 + 原因」，**不得写成通过**。

### 自己重新生成 HTTPS 证书（可选）

```bash
cd tool/mock_nas
openssl req -x509 -newkey rsa:2048 -nodes \
  -keyout mock_nas_key.pem -out mock_nas_cert.pem -days 3650 \
  -subj "/CN=mock-nas.local/O=Local Mock NAS" \
  -addext "subjectAltName=DNS:localhost,DNS:mock-nas.local,IP:127.0.0.1,IP:<你的局域网IP>"
```

---

## 7. ⚠️ 一个真实的坑：`200 + JSON 119` 在媒体通道可能被误判

DSM 对"缺 `_sid`/CSRF 的下载 URL"的真实形态是 **`HTTP 200` + 身体
`{"success":false,"error":{"code":119}}`**（本项目 `lib/src/dsm/webapi.dart:664`、
`media_source.dart:118` 都有记录）。Media3 会把这段 JSON 当成"没有 extractor 能读的流"，
文本上**和"编码不支持"一样**。

* 对**走 Dio 的下载/`getBytes`**：`_errorFromBody` 只在 **非 2xx** 时才解析 JSON ——
  所以 `200 + JSON` 会被当成**文件内容**（会"下载"到一个 38 字节的 JSON）。
* 对**播放器（Media3）**：`classifyPlayerError` 找的是错误文本里的 `119`/`401`/`403`，
  而 `UnrecognizedInputFormatException` 文本里**不一定有** `119` → 可能落到中性的
  "播放失败"而不是"会话不存在，请重新登录"。

所以 mock 提供 **`--error-http-status=403`**：

```bash
dart tool/mock_nas/mock_nas_server.dart --port=8788 --download-error=119 --error-http-status=403
```

此时 `{"success":false,"error":{"code":119}}` 走 **HTTP 403**：

* Dio 路径 → `_errorFromBody` 解析出 `DsmApiException(119)` → `sessionExpired`；
* Media3 路径 → `Response code: 403` → `classifyPlayerError` 命中 `403` → `sessionExpired`。

**实测**（`probe_client.dart`）：

```
[probe] getBytes 抛 DsmApiException code=119 （--download-error 注入，且 --error-http-status=403）
```

> 默认仍是 **200**（DSM 真实形态）。真机批次建议**两种都试**：
> `200` 那次如果只出现泛化的"播放失败"，那就是 **App 侧的真实缺口**（媒体通道没解析
> 119 身体），据实记录；`403` 那次用于确认"面板/文案确实能走到会话失效分支"。

---

## 8. 安全

* mock 的 `sid` / `SynoToken` / `device_id` 一律是明显的假值（`MOCK-*`）；
* 日志（含 `--verbose`）对 `passwd` / `password` / `account` / `cipherkey` / `_sid` /
  `synotoken` / `otp_code` / `device_id` **脱敏**（打 `***`）；
* 本目录内容（含 README / 日志 / 证书）**不含**任何真实 NAS 地址、账号、`_sid` 或
  `SynoToken`；自带证书是抛弃式 mock 证书；
* 真机验证后按任务书 §8 清理：删掉 App 里新增的 mock 服务器条目，不留任何 mock 凭据。

---

## 9. 已知限制（这是"判定点服务器"，不是 DSM 仿真）

* **有状态业务后端**（见 §11）覆盖的 API 家族会真的改内存；**其余被声明**的 API
  一律回 `{"success":true,"data":{}}`（够让能力检测通过，不保证模块功能）；
  **未声明**的回 `102`。
* 合成媒体是确定性伪随机字节，**不是真实可解码媒体**。要看真实播放行为，用
  `--media-file=<真实文件>`（如 `home/Books/clip-h264.mp4` 的本地副本）。
* `--download-truncate-after` 是**按 sid 记账**的：首次 Download 后该 sid 全回 `119`
  （与任务书要求一致）。重登发新 sid 即可恢复。
* 不做 HTTPS 证书校验/`SynoToken` 校验（mock 不校验任何凭据）。
* **不是真机证据**：mock 通过只证明"协议往返 + DTO 解析 + 状态迁移"对，
  真机的网络策略/权限/DSM 版本行为仍未验（见 `docs/mock-nas-verification-report.md`）。

---

## 10. 文件清单

| 文件 | 说明 |
|---|---|
| `mock_nas_server.dart` | 服务器（零三方依赖，`dart <file>` 直接跑）；含 `startMockNas()` 库入口 |
| `mock_nas_store.dart` | **有状态业务后端**：笔记/文件/下载/相册的内存模型与 handler（零三方依赖） |
| `probe_client.dart` | 用本项目真实 DSM 客户端打 mock，证明协议兼容 |
| `run_mock_nas.sh` | **一条命令起 mock 并等就绪**（见 §11.1） |
| `selftest.sh` | 全量自测（打印原始 curl 输出 + PASS/FAIL 汇总） |
| `mock_nas_cert.pem` / `mock_nas_key.pem` | 抛弃式自签证书（HTTPS 模式用） |
| `README.md` | 本文件 |

---

## 11. 有状态业务后端 + 自动化验证设施（2026-09 新增）

### 11.1 一条命令起 mock 并等就绪

```bash
# 默认 :8788，声明 file
bash tool/mock_nas/run_mock_nas.sh

# 声明四件套（笔记 / 文件 / 下载 / 相册）
bash tool/mock_nas/run_mock_nas.sh --port=8788 --apis=file,note,download,photo

# 全部套件
bash tool/mock_nas/run_mock_nas.sh --apis=all
```

脚本会：选 `dart` → 后台起服务器 → **轮询 `SYNO.API.Info` 直到就绪**
（`MOCK_READY_TIMEOUT`，默认 30s）→ 打印 `[run] READY http://127.0.0.1:<port>（声明 N 个 API）`
与 PID → 阻塞等待（`Ctrl-C` 收工，子进程一并杀掉）。
实测：`bash tool/mock_nas/run_mock_nas.sh --port=18791 --apis=file`
→ `READY http://127.0.0.1:18791（声明 20 个 API）`，`Ctrl-C` 后 `lsof -i :18791` 无监听。

### 11.2 进程内起 mock（测试用）

`mock_nas_server.dart` 导出（同一套 `MockConfig`/handler，只是不占固定端口）：

```dart
final instance = await startMockNas(declaredApis: {'file', 'note'});
final api = DsmWebApi(DirectTransport.url(instance.url));   // 真实客户端代码
await api.discover();
await api.login(account: 'mock', password: 'mock');          // mock 不看口令
// instance.store 是内存后端，可直接断言"写操作之后状态对不对"
await instance.close();
```

测试脚手架在 **`test/support/mock_nas_harness.dart`**（`startMockNasHarness`）。

### 11.3 有状态后端覆盖的家族/方法

**写方法真的改内存**（删除后 list 里就没有，复制/移动后目标处就有）。

| 家族 | 方法（真的改状态的高亮） |
|---|---|
| `SYNO.NoteStation.Note` | `list` / `get` / `create` / **`set`**（含 `attachment[action=delete]`）/ **`delete`**（`recycle` 真值）/ **`restore`** / **`copy`** / `get_attachment_text` |
| `SYNO.NoteStation.Note.Polling` | `set` / `copy` / `create` + `*_status` / `*_stop`（同步完成） |
| `SYNO.NoteStation.Note.Version` | `list` / **`restore`** |
| `SYNO.NoteStation.Notebook` | `list` / `get` / `create` / **`set`**（`title`/`stack`）/ **`delete`** |
| `SYNO.NoteStation.Notebook.Polling` | **`archive`**（真归档）/ `archive_status` / `archive_stop` |
| `SYNO.NoteStation.Todo` | `list` / `list_timeout` / `create` / **`set`** / **`delete`** |
| `SYNO.NoteStation.Tag` / `Shortcut` / `FTS` / `Info` / `Setting` | list/读写（Setting 的 `search_attachment` 真持久） |
| `SYNO.NoteStation.Export.*` / `Import.*` | `start` / `status`（同步完成）/ `stop` |
| `SYNO.FileStation.List` | `list`（**路径感知**）/ `list_share` / `getinfo` |
| `SYNO.FileStation.Delete` | **`start`**（→ `/<share>/#recycle`）/ **`delete`**（永久） |
| `SYNO.FileStation.CopyMove` | **`start`**（`remove_src` 真复制/移动） |
| `SYNO.FileStation.CreateFolder` / `Rename` / `CheckExist` / `BackgroundTask` | 真的建/改名/查存在 |
| `SYNO.Core.RecycleBin` | **`start`**（清空该共享回收站） |
| `SYNO.DownloadStation2.Task` | `list`（status/keyword/sort/分页）/ `get` / **`create`** / **`pause`/`resume`/`pause_condition`/`resume_condition`/`delete`/`delete_condition`/`edit`** |
| `Task.Statistic` / `Settings.Location` / `Task.BT` / `Task.BT.Tracker` / `.Peer` / `.File` | 读 + **`Task.BT/set`**（限速/优先级真持久）、`File/copy` |
| `Task.NZB.Log` / `.NZB.File` / `Task.List` / `Task.List.Polling` / `Task.Source` | 读 + **`Task.List/delete`、`Polling/download`**（清单真释放） |
| `DownloadStation2.Captcha` | `list` / **`set`**（真清验证码任务） |
| `DownloadStation2.BTSearch` / `DownloadStation.BTSearch` | start/list/stop/getModule |
| `DownloadStation2.RSS.Feed` | `list` / **`add`/`set`/`delete`** |
| `SYNO.Foto.Browse.Item` | `list`（album/folder/favorite 过滤 + offset/limit）/ **`set_favorite`/`delete`/`move`/`copy`** |
| `SYNO.Foto.Browse.Album` | `list` / **`create`/`set`/`delete`** / **`set_album_list_order`**（真持久） |
| `SYNO.Foto.Browse.NormalAlbum` | `list` / **`add_item`/`delete_item`** |
| `SYNO.Foto.Browse.Folder` | `list` / `get` / **`create`/`rename`/`delete`** |

**未覆盖 = 未覆盖**：Chat / Calendar / Contacts / Audio / Office / Drive / 分享链接等家族
仍走 §9 的空 `data` 路径（能力表可声明，但列表恒空、写操作不落状态）。

### 11.4 怎么"再加一行验证"

见 `docs/mock-nas-verification-report.md` §6 的范式。三步：
1. 在 `mock_nas_store.dart` 的 `reply()` switch 里补该 API 的 handler
   （写方法必须改内存，并在 `mock_nas_server.dart` 的 `kServiceApiGroups` 里登记）；
2. 在 `test/mock_nas_<模块>_test.dart` 加一个 `test('<行ID> <行名>', …)`，
   用 `startMockNasHarness` + 该模块的真实 Api 类走 loopback；
3. 跑 `flutter test test/mock_nas_<模块>_test.dart`，再到报告 §4 的表里补一行。

---
