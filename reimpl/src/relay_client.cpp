// 顶层启动编排实现
#include "libpunch/relay_client.h"

#include <arpa/inet.h>
#include <errno.h>
#include <netinet/in.h>
#include <sys/socket.h>
#include <unistd.h>

#include <chrono>
#include <cstring>
#include <set>
#include <thread>

#include "libpunch/socket.h"
#include "udt.h"

namespace libpunch {
namespace {

long now_ms() {
  return std::chrono::duration_cast<std::chrono::milliseconds>(
             std::chrono::steady_clock::now().time_since_epoch()).count();
}

}  // namespace

const char* tunnel_error_name(TunnelError e) {
  switch (e) {
    case TunnelError::Ok: return "Ok";
    case TunnelError::EarlyExit: return "EarlyExit";
    case TunnelError::ListenSocket: return "ListenSocket";
    case TunnelError::UdpPort: return "UdpPort";
    case TunnelError::PunchFailed: return "PunchFailed";
    case TunnelError::UdtChannel: return "UdtChannel";
    case TunnelError::UdtConnect: return "UdtConnect";
    case TunnelError::UdtListen: return "UdtListen";
    case TunnelError::AcceptFailed: return "AcceptFailed";
    case TunnelError::EngineStart: return "EngineStart";
  }
  return "Unknown";
}

RelayClient::~RelayClient() { stop(); }

// 等 UDT 套接字进入 CONNECTED
TunnelError RelayClient::wait_connected(int udt_fd, int timeout_ms) {
  long deadline = now_ms() + timeout_ms;
  while (now_ms() < deadline) {
    int st = 0, len = 4;
    if (UDT::getsockopt(udt_fd, 0, UDT_STATE, &st, &len) == UDT::ERROR) {
      return TunnelError::UdtConnect;
    }
    if (st == CONNECTED) return TunnelError::Ok;
    if (st == BROKEN || st == CLOSED || st == NONEXIST) return TunnelError::UdtConnect;
    std::this_thread::sleep_for(std::chrono::milliseconds(10));
  }
  return TunnelError::UdtConnect;
}

TunnelError RelayClient::prepare(const TunnelRequest& req) {
  if (prepared_) return TunnelError::EarlyExit;
  is_initiator_ = req.has_candidate;

  // ① 打洞交换 —— 两方都要做，用于让 echo 服务器/对端学到自己的地址
  PunchExchangeParams pp;
  pp.local_port = 0;
  pp.servers = req.echo_servers;
  pp.qc_id = req.qc_id;
  pp.use_code1 = true;
  pp.do_ttl_punch = req.has_candidate;
  pp.timeout_ms = req.punch_timeout_ms;

  punch_ = get_remote_server_address(req.has_candidate ? &req.candidate : nullptr, pp);
  if (punch_.error != PunchError::Ok) return TunnelError::PunchFailed;

  if (is_initiator_) {
    // ② 发起方：rendezvous 通道 + connect 对端
    int port = Socket::get_unused_udp_port();
    if (port < 0) return TunnelError::UdpPort;

    udt_fd_ = req.use_rendezvous ? Socket::create_udt_channel_socket(port)
                                 : Socket::create_udt_client_socket();
    if (udt_fd_ < 0) return TunnelError::UdtChannel;

    // 建链在 await_peer 阶段完成（对应的 UDT::connect 调用）
    prepared_ = true;
    return TunnelError::Ok;
  }

  // ②' 被动方：建监听套接字，等对端接入
  int port = Socket::get_unused_udp_port();
  if (port < 0) return TunnelError::UdpPort;

  listen_udt_fd_ = Socket::create_udt_listen_socket(port);
  if (listen_udt_fd_ < 0) return TunnelError::UdtListen;

  int bound = Socket::get_udt_channel_port(listen_udt_fd_);
  udt_listen_port_ = bound > 0 ? (uint16_t)bound : 0;
  prepared_ = true;
  return TunnelError::Ok;
}

TunnelError RelayClient::await_peer(const TunnelRequest& req) {
  if (!prepared_) return TunnelError::EarlyExit;

  if (is_initiator_) {
    if (UDT::connect(udt_fd_, (const sockaddr*)&punch_.peer, sizeof(sockaddr_in)) == UDT::ERROR) {
      return TunnelError::UdtConnect;
    }
    return wait_connected(udt_fd_, req.connect_timeout_ms);
  }

  int eid = UDT::epoll_create();
  if (eid < 0) return TunnelError::AcceptFailed;
  int ev = UDT_EPOLL_IN;
  UDT::epoll_add_usock(eid, listen_udt_fd_, &ev);

  TunnelError rc = TunnelError::AcceptFailed;
  long deadline = now_ms() + req.connect_timeout_ms;
  while (now_ms() < deadline) {
    std::set<UDTSOCKET> rd, wr;
    int n = UDT::epoll_wait(eid, &rd, &wr, 50, nullptr, nullptr);
    if (n > 0 && rd.count(listen_udt_fd_) != 0) {
      sockaddr_in peer{};
      int plen = sizeof(peer);
      UDTSOCKET conn = UDT::accept(listen_udt_fd_, (sockaddr*)&peer, &plen);
      if (conn != UDT::INVALID_SOCK) {
        udt_fd_ = (int)conn;
        rc = TunnelError::Ok;
        break;
      }
    }
  }
  UDT::epoll_release(eid);

  if (rc == TunnelError::Ok) rc = wait_connected(udt_fd_, req.connect_timeout_ms);
  return rc;
}

TunnelError RelayClient::start_engine(const TunnelRequest& req) {
  if (udt_fd_ < 0) return TunnelError::EarlyExit;

  RelayEngineOptions eo;
  eo.listen_port = 0;
  eo.service_id = req.service_id;
  eo.read_chunk = req.read_chunk;
  eo.idle_timeout_sec = req.idle_timeout_sec;
  eo.local_service_port = req.local_service_port;

  if (!engine_.start(udt_fd_, eo)) return TunnelError::EngineStart;

  running_ = true;
  return TunnelError::Ok;
}

TunnelError RelayClient::start(const TunnelRequest& req) {
  if (running_) return TunnelError::EarlyExit;

  TunnelError rc = prepare(req);
  if (rc == TunnelError::Ok) rc = await_peer(req);
  if (rc == TunnelError::Ok) rc = start_engine(req);
  if (rc != TunnelError::Ok) stop();
  return rc;
}

void RelayClient::stop() {
  running_ = false;
  engine_.stop();

  if (udt_fd_ >= 0) {
    UDT::close(udt_fd_);
    udt_fd_ = -1;
  }
  if (listen_udt_fd_ >= 0) {
    UDT::close(listen_udt_fd_);
    listen_udt_fd_ = -1;
  }
  is_initiator_ = false;
  prepared_ = false;
  udt_listen_port_ = 0;
}

}  // namespace libpunch
