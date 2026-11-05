# libpunch 重写工程

用自有 C++ 重新实现 Synology Chat 的打洞 / 中继 / UDT 隧道功能。
**不打包 Synology 任何专有二进制**，全部代码由 `libsynoholepunch.so` 的反编译结果重建。
协议依据来自内部笔记（不进本仓库；本仓库不含任何 Synology 二进制）。

## 目录

```
reimpl/
├── CMakeLists.txt
├── include/libpunch/
│   ├── protocol.h          # command_t / udp_relay_header_t / 枚举常量
│   ├── socket.h            # LibPunch::Socket 26 个原语
│   ├── json.h              # 自研极简 JSON 解析器
│   ├── punch_server.h      # echo list 发现
│   ├── http.h              # libcurl 封装
│   ├── punch_exchange.h    # 打洞交换
│   ├── relay.h             # 隧道会话复用：记录格式 + 流重组器
│   ├── relay_session.h     # 会话/隧道/注册表三层对象模型
│   ├── relay_engine.h      # 中继事件循环（本地 TCP ↔ UDT 隧道）
│   ├── relay_client.h      # 顶层编排：打洞 → 建链 → 启动引擎
│   └── punch_c.h           # C ABI（Dart FFI 入口，21 个函数）
├── src/
│   ├── protocol.cpp        # CommandHandler + UdpRelayHeaderHandler
│   ├── socket.cpp          # Socket（POSIX 部分）
│   ├── udt_socket.cpp      # Socket 的 UDT 原语（对接 third_party/udt4）
│   ├── json.cpp            # JSON 递归下降解析
│   ├── punch_server.cpp    # 请求体构造 + 响应解析
│   ├── http.cpp            # POST + 错误码映射
│   ├── punch_exchange.cpp  # TTL 敲门 + 148B 收发循环
│   ├── relay_buffer.cpp    # 0x2c00 流重组器（对应 RelayRingBuffer）
│   ├── relay_session.cpp   # RelaySession / RelayTunnel / RelayAgent
│   ├── relay_engine.cpp    # epoll 循环 + 收发泵 + 背压 + 收敛
│   ├── relay_client.cpp    # prepare / await_peer / start_engine
│   └── punch_c.cpp         # C ABI 实现
└── tests/
    ├── test_protocol.cpp       # 46 项断言，对着反编译确定值
    ├── test_socket.cpp         # 34 项断言，真实建套接字跑
    ├── test_punch_server.cpp   # 62 项断言，请求体逐字节 + 响应边界
    ├── test_http.cpp           # 14 项断言，自建本地 HTTP 服务器端到端
    ├── test_punch_exchange.cpp # 40 项断言，自建假 echo 服务器端到端
    ├── test_udt.cpp            # 31 项断言，真实 UDT 连接 + rendezvous 打洞
    ├── test_relay_buffer.cpp   # 121 项断言，组帧/分片/边界/暂停语义
    ├── test_relay_session.cpp  # 85 项断言，双索引一致性 + 背压 + 端到端路由
    ├── test_relay_engine.cpp   # 22 项断言，真实 UDT 隧道端到端
    ├── test_relay_client.cpp   # 26 项断言，全栈：打洞 → UDT → 双引擎 → TCP 回环
    └── test_punch_c.cpp        # 35 项断言，C ABI 契约
```

第三方依赖见 [`third_party/README.md`](third_party/README.md)（udt4，BSD-3-Clause）。

## 构建与测试

```bash
cmake -S . -B build -DCMAKE_BUILD_TYPE=Release
cmake --build build
ctest --test-dir build --output-on-failure
```

预期：`100% tests passed out of 11`（共 516 项断言；raw socket 用例非 root 时跳过）。零告警。
依赖：libcurl（macOS 用 SDK 自带 8.7.1）。

## 已完成

| 模块 | 状态 | 依据 |
|---|---|---|
| `command_t` 布局（148 字节定长） | ✅ 已实现 + 断言 | `CommandHandler::set` 反编译 + `sendto(...,0x94,...)` |
| `CommandHandler::set / get / parse / compare / compute_checksum` | ✅ 已实现 + 断言 | `CommandHandler.cpp` |
| `udp_relay_header_t` 布局与 `0x7777` 异或校验 | ✅ 已实现 + 断言 | `UdpRelayHeaderHandler.cpp` |
| `close_peer` 报文逐字节一致 | ✅ 已断言 | 反编译实发 `00 00 00 04 77 73 00 00` |
| `SERVICE_ID` 值域 [1,11] | ✅ 已实现 + 断言 | JNI 入口 `if (10 < v - 1U) v = 0;` |
| `Socket` 全部 26 个原语 | ✅ 已实现 + 断言 | `Socket.cpp` |
| echo list 请求体（逐字节） | ✅ 已实现 + 断言 | `GetPunchServerListSSL` 的 ostringstream 拼接 |
| echo list 响应解析（含 `udt_tx_mss`） | ✅ 已实现 + 断言 | 同上，JsonCpp 调用序列 |
| HTTP POST + 错误码映射（8/9/10/11） | ✅ 已实现 + 断言 | 同上，libcurl setopt 序列 |
| 极简 JSON 解析器 | ✅ 已实现 + 断言 | 自研，无第三方依赖 |
| 打洞交换（TTL 敲门 + 148B 收发循环） | ✅ 已实现 + 断言 | `GetRemoteServerAddress` |
| UDT 原语 6 个（含 `UDT_RENDEZVOUS` 打洞模式） | ✅ 已实现 + 断言 | `Socket.cpp` 的 UDT 部分 |
| 隧道会话复用：记录格式 + 流重组 | ✅ 已实现 + 断言 | `RelayRingBuffer` / `op` 码 |
| 会话表与三层对象（Agent/Tunnel/Session） | ✅ 已实现 + 断言 | `UdtRelayAgent` / `TcpPeerClient` |
| 事件循环（本地 TCP ↔ UDT 隧道全链路） | ✅ 已实现 + 端到端断言 | `UdtRelayDaemon::EventLoop` |
| 顶层编排（打洞 → 建链 → 启动引擎） | ✅ 已实现 + 全栈断言 | `Start` / `PreStart` |

**已验证的关键正确性**：
- `close_peer_packet()` 产出的 8 字节与原库 `UdpRelayHeaderHandler::close_peer`
  实际 `UDT::send` 的字节完全一致 —— 协议层没跑偏的硬证据。
- `ip_checksum` 与原库一致地按**小端序**组装 16 位字：RFC1071 示例标准值 `0xb1e6`，
  本实现返回 `0xe6b1`（= 字节交换版）。走 raw socket 打洞路径时必须注意这个怪癖。
- echo list 请求体在**真实 curl 发出的 HTTP 报文**里逐字节核对通过（自建本地服务器抓包）。
- 打洞交换用**假 echo 服务器**端到端验证：请求包 148 字节合规、载荷为 QC ID、
  对端 IP/端口从响应载荷 0/4 偏移正确提取、TTL 敲门包被对端观测到、多服务器扇出。

### 打洞交换还原要点

**`out` 参数既是输入也是输出**：调用方 `PreStart` 先用 `RELAYDEAMON_OPTIONS` 里的
IP/端口预填候选对端地址，并据此决定是否做 TTL 敲门。

| 步骤 | 行为 |
|---|---|
| 建套接字 | `create_udp_socket(local_port, blocking=true)`，超时靠 `SO_RCVTIMEO` |
| TTL 敲门 | `set_ip_ttl(fd,3)` → 向**候选地址**发 0 字节包（最多 3 次）→ `set_ip_ttl(fd,64)` |
| 扇出 | 向每个 echo 服务器各发一份 148 字节命令 |
| 收包判定 | 必须 `n == 148` **且** `CommandHandler::get()` 通过 **且** `reply.code` 回显一致 |
| 成功 | `payload[0:4]` → `sin_addr`，`payload[4:6]` → `sin_port`（均网络序，直接拷贝） |

#### ⚠️ 错误码 6 与 11 的区分

这是最容易搞错的一处。原库收循环：

```c
do {
  while (true) { /* 顶部 deadline 检查 → 11；recv；匹配则成功 */ }
  piVar6 = __errno();
} while (*piVar6 == 4);   // EINTR 重试
uVar9 = 6;                // 其他 recvfrom 失败 → 6
```

| 场景 | 返回 |
|---|---|
| **完全静默**（`SO_RCVTIMEO` 到期 → `EAGAIN`） | **`6`** ← 不是 11 |
| 收到非法包后持续有流量直到剩余时间耗尽 | `11` |

我最初的测试期望写成"静默 → 11"，被测试纠正过来了。

### echo list 发现还原要点

```
POST https://global.quickconnect.to/Serv.php   (WW, 区域 0)
POST https://global.quickconnect.cn/Serv.php   (CN, 区域 1)

请求体（4 行，每行一个 '\n'，含结尾）：
{
"version":"1",
"command":"get_echo_list"
}
```

- **原库不设置 `Content-Type`**，curl 对 `CURLOPT_POSTFIELDS` 默认发
  `application/x-www-form-urlencoded`。已实测确认。
- 响应必须同时满足：`errno` 存在→整数→`== 0`；`sites` 是数组；`port` 是整数。
  任一不满足即返回错误码 10。
- `sites` 中**非字符串元素被静默跳过**（原库 `isString()` 判断）。
- `udt_tx_mss` 可选，仅当 `> 0` 时才覆盖（原库 `0 < iVar8` 判断）。

| 错误码 | 触发条件 |
|---|---|
| 8 | `curl_easy_init` 或任一 `setopt` 失败 |
| 9 | `curl_easy_perform` 失败 |
| 10 | JSON 解析失败 / `errno != 0` / 字段类型不符 |
| 11 | 超时（剩余时间耗尽） |

### `Socket` 层还原要点

| 原语 | 实现 |
|---|---|
| `create_udp_socket(port, blocking)` | `socket(AF_INET,SOCK_DGRAM)` + `SO_REUSEADDR` + `bind(INADDR_ANY,port)` + `O_NONBLOCK` 按参数 |
| `create_tcp_socket()` | `socket(AF_INET,SOCK_STREAM)` + **无条件** `O_NONBLOCK` |
| `create_tcp_listen_socket(port, addr)` | + `SO_REUSEADDR` + `bind` + `listen(64)` |
| `create_icmp_raw_socket()` | `socket(AF_INET,SOCK_RAW,IPPROTO_RAW)` + `IP_HDRINCL` |
| `create_icmp_listen_socket()` | `socket(AF_INET,SOCK_RAW,IPPROTO_ICMP)` |
| `create_udp_raw_socket()` | `socket(AF_INET,SOCK_RAW,IPPROTO_UDP)` + `IP_HDRINCL` |
| `my_send` | `sendto(..., flags \| MSG_NOSIGNAL, ...)` |
| `set_nosignal` | 恒返回 -1（原库在 Linux 上就是空桩） |
| `set_recv_timeout(fd, ms)` | `SO_RCVTIMEO{ms/1000,(ms%1000)*1000}` |
| `set_ip_ttl(fd, 3)` | `IPPROTO_IP/IP_TTL` —— 打洞敲门用 |

### UDT 原语还原要点

三者共用 SNDSYN=0 / RCVSYN=0 / MSS=1500 / UDP_SNDBUF=UDP_RCVBUF=96000 /
UDT_SNDBUF=UDT_RCVBUF=192000：

| 函数 | 额外行为 |
|---|---|
| `create_udt_client_socket()` | 不 bind |
| `create_udt_listen_socket(port)` | `bind(port)` + `listen(64)` |
| `create_udt_channel_socket(port)` | **`UDT_RENDEZVOUS(12)=1`** + `bind(port)` |

`create_udt_channel_socket` 就是打洞模式：双方各自 bind 后**同时** connect 对方，
无需 listen/accept。已在测试里用两个 channel socket 互相 connect 并成功互传数据。

`get_remote_udt_ip` 返回 `bswap32(sin_addr)` —— 即主机序 IPv4；
`get_remote_udt_port` / `get_udt_channel_port` 返回 `ntohs(sin_port)`。

> **注意**：udt4 把 `UDT_SNDBUF`/`UDT_RCVBUF` 存成「包个数」，取值时返回
> `count * (MSS - 28)`。所以设 192000 读回来是 `192000/(1500-28)=130` →
> `130*1472 = 191360`。这是 udt4 的正常行为，不是 bug。

### 隧道复用还原要点

隧道是字节流，每条记录 = **8 字节头 + 载荷**。头字段被复用：
`port` → **sessionId**、`type` → **serviceId**、`op` → 操作码。

| op | 名称 | 载荷 |
|---|---|---|
| `1` | OPEN | 无 |
| `2` | DATA | TCP 数据 |
| `3` | TEARDOWN | 无（关单个会话） |
| `4` | CLOSE | 无（关整条隧道） |

`op=4` 的实际字节 `00 00 00 04 77 73 00 00` 已与原库 `close_peer` 输出核对一致。

- `sessionId` 是每条隧道内 **16 位自增计数器**，accept 到本地 TCP 连接时分配
- `udt_tx_mss`（echo list 响应字段）就是 `HandleTcpRead` 从本地 TCP 单次读取的字节数
- 流重组器 `RelayRingBuffer`：0x2c00 环形缓冲，消费越过 0x2680 时暂停读取并压缩
- `parse` 失败与 `length >= 0x579` 在原库里**都返回 -1**，不可区分

### 对象模型

```
RelayAgent    tcpFd → udtFd         +  udtFd → RelayTunnel*
RelayTunnel   sessionId → Session*  +  tcpFd → Session*   +  rx/tx 队列
RelaySession  tcpFd / sessionId / serviceId / status
```

| 要点 | 说明 |
|---|---|
| `sessionId` 作用域 | **单条隧道内**，不同隧道可重复 |
| 状态初值 | `SessionStatus::Init = 1`（对应原库构造时 `this[0x4c] = 1`） |
| `CheckStatus` | 参数为 3 或 4 时恒真，否则与当前状态比较 |
| 背压阈值 | 隧道→TCP 队列超过 `0x1d`(29) 条即判积压 |
| 拆除条件 | 输出队列**排空**且 `status == 3` |

索引一致性是这里最容易出错的地方，测试专门覆盖：按 `sessionId` 删除后
`tcpFd` 索引也必须消失，反之亦然；移除整条隧道要清空其下所有 `tcpFd` 索引。

### 事件循环还原要点

单个 UDT epoll 同时管理 UDT 套接字与系统 fd，每轮处理四组就绪集合：
**TCP 读 / TCP 写 / UDT 读 / UDT 写**。本地监听 fd 在 TCP 读集合里被识别
（`fd == this[4]`）后走 accept 分支。

事件位掩码来自 udt4 的 `EPOLLOpt`：`0x1`=IN、`0x4`=OUT、`0x8`=ERR。
`SetEvent(9)`=IN|ERR（TCP 会话）、`SetEvent(0xd)`=IN|OUT|ERR（隧道）。

> ⚠️ **平台差异**：udt4 只在 **Linux** 上真正用 `epoll_ctl` 等待系统 fd
> （`epoll.cpp` 里有 `#ifdef LINUX`）。Android 是 Linux，原库设计成立；
> 在 macOS 上自测时引擎改用 `poll()` 补上这一段，行为等价。

**已完成第一次真实端到端验证**：本地 TCP 客户端 → 引擎组帧 → 真实 UDT 隧道 →
假 NAS 对端解帧 → 回程数据 → 本地 TCP 客户端收到；对端 `TEARDOWN` 后会话正确拆除。

### 关键架构结论

**`libsynoholepunch.so` 只是客户端半边**：全库搜索 `connect(`，除 `UDT::connect`
外没有任何本地 socket 连接；`serviceId` 只被读取写进报文头（3 处）。
所以「收到 OPEN 后拨号本地服务」是 NAS 侧另一个组件的职责。

Android 端所需的一切已完备：建隧道 → 暴露 `127.0.0.1:<port>` → 灌 HTTP 流量。

引擎另外实现了 `local_service_port`（收到 OPEN 时拨号），使本工程在联调/兜底时
也能充当对端 —— 原库没有这个能力。

### rendezvous 必须双方对称

`create_udt_channel_socket` 带 `UDT_RENDEZVOUS`，实测连不上普通 listener。
`TunnelRequest::use_rendezvous` 控制该行为，默认与原库一致（true）。

## 打包与 FFI

### 产出共享库

```bash
# 宿主（macOS/Linux），用于本地测试
cmake -S reimpl -B reimpl/build -DCMAKE_BUILD_TYPE=Release
cmake --build reimpl/build --target synochatpunch
# → reimpl/build/libsynochatpunch.dylib

# Android，构建 + strip + 安装到 jniLibs
./reimpl/scripts/build_android.sh
# → android/app/src/main/jniLibs/<abi>/libsynochatpunch.so
```

已验证的 Android 产物（NDK 30.0.14904198，android-29）：

| ABI | 原始 | strip 后 | 导出符号 |
|---|---|---|---|
| arm64-v8a | 7.2M | **1.0M** | 21 |
| armeabi-v7a | 5.8M | **656K** | 21 |
| x86_64 | 6.9M | **984K** | 21 |

### 为什么 Android 上不需要 libcurl

NDK 不自带 libcurl。本工程的**echo 服务器发现放在宿主侧**（Flutter 用 Dio 完成），
原生层通过 `synopunch_add_echo_server()` 接收服务器列表 —— 这也更符合分层：
HTTP/证书/代理交给 Dart 生态，原生层只管打洞与隧道。

因此 CMake 里 `punch_discovery`（JSON + echo list 解析，纯逻辑）在 Android 上照常构建，
只有 `punch_http`（libcurl 封装）被 `if(NOT ANDROID)` 排除。

### C ABI

`include/libpunch/punch_c.h` —— 21 个函数，形状有意对齐原库 JNI
（`synopunchNew` / `Start` / `Stop` / `Delete` / `TcpPort`），便于对照，但不含任何 JNI 依赖。

⚠️ CMake 里设了 `C_VISIBILITY_PRESET hidden`，所以每个函数都必须带
`SYNOPUNCH_API`（`__attribute__((visibility("default")))`）才会被导出。
漏掉会让 `nm -D` 显示 0 个符号、FFI 静默失败 —— 这个坑已经踩过一次。

### Dart 侧

`lib/src/native/punch_ffi.dart`：`SynoPunch` 封装 + `SynoServiceType` / `SynoPunchError` /
`SynoEchoServer` 常量类。测试见 `test/punch_ffi_test.dart`（11 项，真实加载原生库）。

### 设备端验证

用 NDK 编了个 dlopen 探针推到真机（LGE_AN10 / Android 12 / arm64）运行：

```
OK   dlopen libsynochatpunch.so
OK   dlsym 全部 21 个 C ABI 符号
OK   synopunch_new
OK   synopunch_start rc=6 err=PunchFailed port=0
```

最后一行说明 UDP 套接字创建、udt4 初始化、打洞交换在 Android 上都正常工作
（无 echo 服务器时按预期返回 `PunchFailed`）。

## 待办

- [ ] 真实 NAS 联调（需地址与测试账号）：打洞通路 + relay 兜底等价性验证
- [ ] 本地 TCP 监听端口 + 转发（`TcpPeerClient` / `RelayRingBuffer`）
- [ ] FFI 接入 Flutter，替换 JNI
- [ ] 真实 NAS 联调，与 relay 兜底等价性验证

## 设计原则

1. **协议层零平台依赖**，可在宿主机直接单测（当前已做到）。
2. **每个协议常量都附反编译依据**，不接受"大概是这样"。
3. UDT 复用开源 `udt4`（原库静态链接的也是它），不自研。
4. JNI → 改为 FFI，去掉对 `PunchInfo` Java 类的绑定。

## 构建目标：仅 arm64-v8a

目前只出 **arm64-v8a**，不再编 32 位与 x86_64。

| 项 | 值 |
|---|---|
| 构建脚本默认 ABI | `ABIS=arm64-v8a`（`build_android.sh`） |
| jniLibs | 仅 `android/app/src/main/jniLibs/arm64-v8a/` |
| `abiFilters` | `android/app/build.gradle.kts` 的 `defaultConfig.ndk` |
| Flutter 侧 | `flutter build apk --target-platform android-arm64` |

⚠️ **`abiFilters` 管不到 Flutter 引擎的预编译库** —— 必须同时加
`--target-platform android-arm64`，否则 `libflutter.so` 的
armeabi-v7a / x86_64 版本仍会进包。

⚠️ 改 ABI 后务必 `flutter clean`：增量打包会在 APK 里留下**空洞**
（实测 `AssetManifest.bin` 前有 69.9 MB 死区，文件 145 MB 而条目只有 75 MB）。

### 体积

| 构建 | 大小 | 说明 |
|---|---|---|
| debug | 75.2 MB | 含 kernel_blob 43 MB（解压）+ VkLayer 14.5 MB |
| **release** | **18.4 MB** | libapp.so 4.8 + libflutter.so 11.2 + libsynochatpunch.so 1.0 |
