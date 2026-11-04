// C ABI —— 供 Dart FFI 调用
//
// 有意对齐原库 JNI 的调用形状（synopunchNew / Start / Stop / Delete / TcpPort），
// 便于对照，但这是纯 C 接口，不含任何 JNI 依赖。
#pragma once

#include <stdint.h>

// 共享库需要显式导出：CMake 里设了 C_VISIBILITY_PRESET hidden，
// 不加这个属性符号会被隐藏，Dart FFI 会找不到。
#if defined(_WIN32)
#define SYNOPUNCH_API __declspec(dllexport)
#else
#define SYNOPUNCH_API __attribute__((visibility("default")))
#endif

#ifdef __cplusplus
extern "C" {
#endif

typedef struct synopunch_handle synopunch_handle;

// ---------------------------------------------------------------- 生命周期
SYNOPUNCH_API synopunch_handle* synopunch_new(void);
SYNOPUNCH_API void synopunch_free(synopunch_handle* h);

// ---------------------------------------------------------------- 配置
// QuickConnect ID，打洞载荷
SYNOPUNCH_API void synopunch_set_server_id(synopunch_handle* h, const char* qc_id);

// SERVICE_ID：1=DSM 2=DSM_HTTPS 3=HTTP 4=HTTPS 5=WEBDAV 6=WEBDAV_HTTPS
//             7=CLOUDSTATION 8=VPNPLUS 9=BEEDRIVE_HTTPS 10=BSM_HTTP 11=BSM_HTTPS
// 与原库一致：超出 [1,11] 会被归零
SYNOPUNCH_API void synopunch_set_service_type(synopunch_handle* h, int service_type);

// 追加一个 echo 服务器（来自 get_echo_list 响应的 sites[] + port）
//
// ⚠️ 别和 get_server_info 的 relay_servers / smartdns 混淆：
//    反编译确认原库**只**做 get_echo_list，且只解析
//    errno / port / sites / udt_tx_mss 四个字段；
//    relay_servers / server / smartdns / service / env 全由 Java 层
//    (com.synology.sylibx.syhttp3.relay.apis.ApiDSM) 处理，
//    原生库从不接触。打洞候选（udp_punch_port + smartdns.host 等）
//    因此来自 Dart 侧的 ServApi.punchCandidates()。
SYNOPUNCH_API void synopunch_add_echo_server(synopunch_handle* h, const char* ip, int port);
SYNOPUNCH_API void synopunch_clear_echo_servers(synopunch_handle* h);

// 从 echo list 响应里取到的 udt_tx_mss
SYNOPUNCH_API void synopunch_set_udt_tx_mss(synopunch_handle* h, int mss);

// 候选对端地址；设置后进入主动分支（默认使用 rendezvous 建链）
SYNOPUNCH_API void synopunch_set_candidate(synopunch_handle* h, const char* ip, int port);
SYNOPUNCH_API void synopunch_clear_candidate(synopunch_handle* h);

// rendezvous 建链开关。原库主动分支用 create_udt_channel_socket（带 RENDEZVOUS），
// 要求双方对称；与纯 listener 对接时置 0
SYNOPUNCH_API void synopunch_set_rendezvous(synopunch_handle* h, int enable);

// 收到对端 OPEN 时拨号的本地服务端口（0 = 不拨号，纯客户端半边）
SYNOPUNCH_API void synopunch_set_local_service_port(synopunch_handle* h, int port);

// 打洞超时 / 建链超时（毫秒）
SYNOPUNCH_API void synopunch_set_punch_timeout(synopunch_handle* h, int ms);
SYNOPUNCH_API void synopunch_set_connect_timeout(synopunch_handle* h, int ms);

// ---------------------------------------------------------------- 运行
// 阻塞完成：echo 发现已在外部做好 → 打洞 → UDT 建链 → 启动中继引擎
// 返回 0 成功，非 0 为 TunnelError
SYNOPUNCH_API int synopunch_start(synopunch_handle* h);

// ★ r684：把 `synopunch_start` 拆成**三段**，供"两侧都在本进程"的
//   回环装置（模拟器/单测）编排 —— 生产路径仍用上面那个一步到位的。
//
//   被动方：prepare → udt_port 取监听端口（要让对端知道）→ await_peer（阻塞）
//           → start_engine
//   发起方：set_candidate(对端 udt_port) → prepare → await_peer（阻塞 connect）
//           → start_engine
//
//   全部返回 0 成功 / 非 0 = TunnelError；失败时用 `synopunch_last_error` 取名。
SYNOPUNCH_API int synopunch_prepare(synopunch_handle* h);
// prepare 之后被动方的 UDT 监听端口；发起方或未 prepare 时返回 0
SYNOPUNCH_API int synopunch_udt_port(synopunch_handle* h);
SYNOPUNCH_API int synopunch_await_peer(synopunch_handle* h);
SYNOPUNCH_API int synopunch_start_engine(synopunch_handle* h);

// 本地 TCP 监听端口；把 https://127.0.0.1:<port>/ 交给 HTTP 栈即可。未启动返回 0
SYNOPUNCH_API int synopunch_tcp_port(synopunch_handle* h);

// 驱动一轮事件循环。返回本轮处理的 fd 数（0 表示无事件）
SYNOPUNCH_API int synopunch_poll(synopunch_handle* h, int timeout_ms);

// 停止并释放隧道与套接字（handle 仍可复用）
SYNOPUNCH_API void synopunch_stop(synopunch_handle* h);

// ---------------------------------------------------------------- 查询
SYNOPUNCH_API int synopunch_is_running(synopunch_handle* h);
// 最近一次失败的错误名（如 "PunchFailed"）；无错误返回 ""
SYNOPUNCH_API const char* synopunch_last_error(synopunch_handle* h);

// 统计：隧道收/发字节数
SYNOPUNCH_API uint64_t synopunch_rx_bytes(synopunch_handle* h);
SYNOPUNCH_API uint64_t synopunch_tx_bytes(synopunch_handle* h);

#ifdef __cplusplus
}  // extern "C"
#endif
