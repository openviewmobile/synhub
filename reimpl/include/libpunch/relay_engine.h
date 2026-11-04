// 中继事件循环 —— 还原自 UdtRelayDaemon::EventLoop
//
// 单个 UDT epoll 同时管理两类 fd：
//   - UDT 套接字（隧道）        UDT::epoll_add_usock
//   - 系统 fd（本地 TCP）       UDT::epoll_add_ssock
//
// 每轮处理四组就绪集合：TCP 读 / TCP 写 / UDT 读 / UDT 写。
#pragma once

#include <cstdint>
#include <set>
#include <string>

#include "libpunch/relay_session.h"

namespace libpunch {

struct RelayEngineOptions {
  int listen_port = 0;          // 本地 TCP 监听端口，0 = 由内核分配
  uint8_t service_id = 2;       // dsm_https
  size_t read_chunk = 1400;     // 从本地 TCP 单次读取的字节数（对应 udt_tx_mss）
  int idle_timeout_sec = -1;    // 空闲上报阈值，-1 = 不启用

  // 收到对端 OPEN 时，由本端主动拨号的服务端口（0 = 不拨号）。
  //
  // ⚠️ 注意：原库 libsynoholepunch.so 里**没有任何 connect() 去连本地服务**，
  // serviceId 只被读取写进报文头。说明该 .so 只是**客户端半边** ——
  // 收到 OPEN 后拨号本地端口是 NAS 侧另一个组件（不在这个 .so 里）的职责。
  // 这里实现它，是为了让本工程既能当客户端，也能在联调/兜底时充当对端。
  int local_service_port = 0;

  // 上述拨号的目标地址，默认回环。指向真实 NAS 即可让本实现充当「NAS 侧对端」，
  // 从而在没有可用打洞网络时仍能验证隧道端到端等价。
  std::string local_service_host = "127.0.0.1";
};

// 把「本地 TCP 端口」与「已建立的 UDT 隧道」对接起来。
// 上层拿到 local_port() 后，把 https://127.0.0.1:<local_port>/chat/ 交给 HTTP 栈即可。
class RelayEngine {
 public:
  RelayEngine();
  ~RelayEngine();

  RelayEngine(const RelayEngine&) = delete;
  RelayEngine& operator=(const RelayEngine&) = delete;

  // udt_fd 必须是一条已连接的 UDT 通道（见 punch_exchange / create_udt_channel_socket）
  bool start(int udt_fd, const RelayEngineOptions& options);
  void stop();

  // 处理一轮事件，返回本轮实际处理的 fd 数。timeout_ms 对应原库固定传入的 1000。
  int poll_once(int timeout_ms = 1000);

  bool running() const { return running_; }
  uint16_t local_port() const { return local_port_; }
  int listen_fd() const { return listen_fd_; }
  int udt_fd() const { return udt_fd_; }
  uint64_t idle_seconds() const { return idle_seconds_; }
  int idle_timeouts_fired() const { return idle_timeouts_fired_; }

  RelayAgent& agent() { return agent_; }
  const RelayAgent& agent() const { return agent_; }

 private:
  void accept_new_client();
  void handle_tcp_read(RelaySession* s);
  void handle_tcp_write(RelaySession* s);
  void handle_udt_read(RelayTunnel* t);
  void handle_udt_write(RelayTunnel* t);

  // 关闭单个会话：先从 epoll 摘除，再关 fd，最后从注册表删除
  void teardown_session(int tcp_fd);

  // 回收整条隧道
  void teardown_tunnel(int udt_fd);

  // 把隧道收到的记录分发给目标会话，返回是否成功路由
  bool dispatch_record(RelayTunnel* t, const RelayRecord& rec);

  // 非 Linux 平台上 udt4 不轮询系统 fd（见 third_party/udt4/src/epoll.cpp 的 #ifdef LINUX），
  // 这里用 poll() 自行补上，使引擎在宿主机上同样可测。
  void poll_tcp_fds(int timeout_ms, std::set<int>* read_fds, std::set<int>* write_fds);

  RelayAgent agent_;
  int listen_fd_ = -1;
  int udt_fd_ = -1;
  int epoll_id_ = -1;
  uint16_t local_port_ = 0;
  uint16_t next_session_id_ = 1;
  uint8_t service_id_ = 2;
  size_t read_chunk_ = 1400;
  int idle_timeout_sec_ = -1;
  int local_service_port_ = 0;
  std::string local_service_host_ = "127.0.0.1";
  uint64_t idle_seconds_ = 0;
  int idle_timeouts_fired_ = 0;
  bool running_ = false;
};

}  // namespace libpunch
