# 第三方依赖

## udt4

| | |
|---|---|
| 来源 | https://github.com/netvirt/udt4 |
| 版本 | commit `4bed260`（master） |
| 许可 | **BSD-3-Clause**，Copyright (c) 2001-2011 The Board of Trustees of the University of Illinois |
| 许可全文 | [`udt4/LICENSE.txt`](udt4/LICENSE.txt) |
| 规模 | 14,538 行（`src/*.cpp` + `src/*.h`） |

### 为什么用它

`libsynoholepunch.so` 的符号表里有 **228 个 UDT 相关导出符号**，全部对应 udt4：

```
CUDTUnited::{startup,newSocket,connect,listen,accept,epoll_*}
CUDTSocket、CHandShake、CCCFactory<CUDTCC>、CUDTException
```

`reimpl/src/udt_socket.cpp` 里的选项数值也与 udt4 的 `UDTOpt` 枚举逐条对上：

| 反编译里的数值 | udt4 枚举 | 值 |
|---|---|---|
| `0` | `UDT_MSS` | 1500 |
| `1` | `UDT_SNDSYN` | 0 |
| `2` | `UDT_RCVSYN` | 0 |
| `5` / `6` | `UDT_SNDBUF` / `UDT_RCVBUF` | 192000 |
| `8` / `9` | `UDP_SNDBUF` / `UDP_RCVBUF` | 96000 |
| `12` | `UDT_RENDEZVOUS` | 1 |

因此 UDT 层直接用上游源码，不自行重写 —— 它是独立的开源组件，
与本项目要替换的 Synology 专有代码无关。

### 本地改动

无。仅删除了上游的 `Makefile`（改用 CMake）与规范草案文本 `draft-gg-udt-xx.txt`。
源码未打任何补丁，`clang++ -std=c++14` 在 macOS 上 13 个编译单元全部通过。

### 与目标的关系

护城河在 LibPunch 自己的 ~3,800 行（协议、打洞、中继调度），
不在 UDT 这个通用可靠 UDP 传输库上。重复实现 udt4 不会带来任何协议兼容性收益，
只会引入风险。
