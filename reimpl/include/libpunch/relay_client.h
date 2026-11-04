// 顶层启动编排 —— 还原自 UdtRelayDaemon::Start / PreStart
//
//   Start() = PreStart()（发现 + 打洞 + UDT 建链）→ EventLoop()（阻塞跑中继）→ PostStop()
//
// 把已实现的三块串成一条启动序列：
//   echo 发现  →  打洞交换  →  UDT 建链  →  RelayEngine 启动
#pragma once

#include <netinet/in.h>

#include <cstdint>
#include <string>
#include <vector>

#include "libpunch/punch_exchange.h"
#include "libpunch/punch_server.h"
#include "libpunch/relay_engine.h"

namespace libpunch {

// PreStart 的返回值（写入 RELAYDAEMON_INFO.errcode / this+0xc0）
enum class TunnelError {
  Ok = 0,
  EarlyExit = 1,          // 已停止
  ListenSocket = 3,       // 本地 TCP 监听套接字创建失败
  UdpPort = 5,            // get_unused_udp_port 失败
  PunchFailed = 6,        // 打洞交换失败
  UdtChannel = 7,         // create_udt_channel_socket 失败
  UdtConnect = 8,         // UDT::connect 失败
  UdtListen = 9,          // create_udt_listen_socket 失败
  AcceptFailed = 10,      // 等待对端接入失败
  EngineStart = 12,       // 中继引擎启动失败
};

const char* tunnel_error_name(TunnelError e);

struct TunnelRequest {
  std::string qc_id;                      // QuickConnect ID，打洞载荷
  uint8_t service_id = 2;                 // dsm_https
  std::vector<IpPortPair> echo_servers;   // 来自 fetch_echo_list

  // 发起方：候选对端地址。有候选 → 主动 connect；无候选 → listen/accept
  bool has_candidate = false;
  sockaddr_in candidate{};

  // 建链模式。
  //   true （默认，与原库一致）：发起方用 create_udt_channel_socket
  //         —— 设了 UDT_RENDEZVOUS，**要求双方都处于 rendezvous 模式**。
  //   false：发起方用 create_udt_client_socket，对端用 listener 即可。
  // 反编译里主动/被动两条分支分别用 channel 与 listen，且 TTL 敲门条件
  // (doTtlPunch = hasPort && hasIp) 在双方都可能成立，说明真实协议是双方 rendezvous。
  bool use_rendezvous = true;

  size_t read_chunk = 1400;               // udt_tx_mss
  int punch_timeout_ms = 5000;
  int connect_timeout_ms = 5000;          // 等 UDT 建链完成
  int idle_timeout_sec = -1;

  // 本端收到对端 OPEN 时拨号的本地服务端口（0 = 不拨号）。
  // 客户端半边用不到；充当 NAS 侧/对端时才需要。
  int local_service_port = 0;
};

// 完成一次完整接入：打洞 → 建链 → 启动本地中继
class RelayClient {
 public:
  RelayClient() = default;
  ~RelayClient();

  RelayClient(const RelayClient&) = delete;
  RelayClient& operator=(const RelayClient&) = delete;

  // 阶段 ①：打洞交换 + 准备 UDT 套接字
  //   发起方：建 rendezvous 通道套接字
  //   被动方：建监听套接字，之后可由 udt_listen_port() 取到端口用于对外广播
  TunnelError prepare(const TunnelRequest& req);

  // 被动方在 prepare 之后可用：UDT 监听端口（0 表示不适用）
  uint16_t udt_listen_port() const { return udt_listen_port_; }

  // 阶段 ②：等 UDT 建链完成（发起方等 CONNECTED；被动方等 accept）
  TunnelError await_peer(const TunnelRequest& req);

  // 阶段 ③：启动本地中继，之后 local_port() 即可用
  TunnelError start_engine(const TunnelRequest& req);

  // 便利接口：依次执行三个阶段
  TunnelError start(const TunnelRequest& req);

  void stop();

  bool running() const { return running_; }
  uint16_t local_port() const { return engine_.local_port(); }
  RelayEngine& engine() { return engine_; }

  // 打洞结果（诊断用）
  const PunchExchangeResult& punch_result() const { return punch_; }
  int udt_fd() const { return udt_fd_; }
  bool is_initiator() const { return is_initiator_; }

 private:
  TunnelError wait_connected(int udt_fd, int timeout_ms);

  RelayEngine engine_;
  PunchExchangeResult punch_;
  int udt_fd_ = -1;
  int listen_udt_fd_ = -1;
  bool is_initiator_ = false;
  bool running_ = false;
  bool prepared_ = false;
  uint16_t udt_listen_port_ = 0;
};

}  // namespace libpunch
