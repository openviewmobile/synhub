// 隧道会话对象与注册表 —— 还原自 TcpPeerClient / UdtRelayClient / UdtRelayAgent
//
// 三层所有权：
//   RelayAgent  拥有若干 RelayTunnel（按 UDT fd 索引）
//   RelayTunnel 拥有若干 RelaySession（按 sessionId 与 tcpFd 双重索引）
//   RelaySession 持有一个本地 TCP fd
#pragma once

#include <cstdint>
#include <deque>
#include <map>
#include <memory>
#include <vector>

#include "libpunch/relay.h"

namespace libpunch {

// TcpPeerClient 的状态字段（this + 0x4c），构造时为 1
enum class SessionStatus : int {
  Init     = 1,   // TcpPeerClient 构造时的初值
  Active   = 2,   // 隧道 → 本地 TCP 有数据在流转
  Draining = 3,   // 对端要求关闭，等本地输出队列排空后再拆
};

// 隧道 → 本地 TCP 的积压上限。HandleUdtRead 里队列超过 0x1d 就清读事件位（背压）
constexpr size_t kSessionQueueHighWater = 0x1d;   // 29

// ---------------------------------------------------------------- RelaySession
// 对应 TcpPeerClient
class RelaySession {
 public:
  RelaySession(int tcp_fd, uint16_t session_id, uint8_t service_id)
      : tcp_fd_(tcp_fd), session_id_(session_id), service_id_(service_id), status_(SessionStatus::Init) {}

  int tcp_fd() const { return tcp_fd_; }
  uint16_t session_id() const { return session_id_; }
  uint8_t service_id() const { return service_id_; }

  SessionStatus status() const { return status_; }
  void set_status(SessionStatus s) { status_ = s; }

  // TcpPeerClient::CheckStatus：参数为 3 或 4 时恒真，否则与当前状态比较
  bool check_status(int s) const {
    return (unsigned)(s - 3) < 2 || s == (int)status_;
  }

  // ---- 隧道 → 本地 TCP 的发送队列 ----
  void enqueue(std::vector<uint8_t> data) { out_queue_.push_back(std::move(data)); }
  bool out_empty() const { return out_queue_.empty(); }
  size_t out_size() const { return out_queue_.size(); }
  const std::vector<uint8_t>& out_front() const { return out_queue_.front(); }
  void out_pop_front() { out_queue_.pop_front(); }
  // 队首部分写出去后，丢弃已发送的前 n 字节
  void out_consume(size_t n);

  // 积压是否已达背压阈值
  bool backlogged() const { return out_queue_.size() > kSessionQueueHighWater; }

  void clear_queue() { out_queue_.clear(); }

 private:
  int tcp_fd_;
  uint16_t session_id_;
  uint8_t service_id_;
  SessionStatus status_;
  std::deque<std::vector<uint8_t>> out_queue_;
};

// ---------------------------------------------------------------- RelayTunnel
// 对应 UdtRelayClient
class RelayTunnel {
 public:
  explicit RelayTunnel(int udt_fd) : udt_fd_(udt_fd) {}

  int udt_fd() const { return udt_fd_; }

  // 会话表。同一会话同时按 sessionId 与 tcpFd 建索引（原库 +0x68 / +0x78 两张表）
  RelaySession* add_session(int tcp_fd, uint16_t session_id, uint8_t service_id);
  RelaySession* find_by_session(uint16_t session_id) const;
  RelaySession* find_by_tcp_fd(int tcp_fd) const;
  RelaySession* remove_session(uint16_t session_id);
  void remove_session_by_tcp_fd(int tcp_fd);

  size_t session_count() const { return by_session_.size(); }
  const std::map<uint16_t, RelaySession*>& sessions() const { return by_session_; }

  // ---- 本地 TCP → 隧道 的待发记录（已组帧的字节）----
  // 原库用 BinaryBuffer 队列；这里直接把整条记录编码后入队
  void enqueue_record(uint16_t session_id, uint8_t service_id, RelayOp op,
                      const uint8_t* payload, size_t len);
  bool tx_empty() const { return tx_queue_.empty(); }
  size_t tx_size() const { return tx_queue_.size(); }
  const std::vector<uint8_t>& tx_front() const { return tx_queue_.front(); }
  void tx_pop_front() { tx_queue_.pop_front(); }
  void tx_consume(size_t n);

  // 已组帧、但尚未发出的字节总数
  size_t tx_pending_bytes() const;

  // ---- 接收侧流重组 ----
  RelayStreamBuffer& rx() { return rx_; }
  const RelayStreamBuffer& rx() const { return rx_; }

  // ---- 统计（原库 this+0x90 收字节数 / this+0x98 发字节数）----
  uint64_t rx_bytes() const { return rx_bytes_; }
  uint64_t tx_bytes() const { return tx_bytes_; }
  void add_rx_bytes(uint64_t n) { rx_bytes_ += n; }
  void add_tx_bytes(uint64_t n) { tx_bytes_ += n; }

 private:
  int udt_fd_;
  std::map<uint16_t, RelaySession*> by_session_;
  std::map<int, RelaySession*> by_tcp_fd_;
  std::deque<std::vector<uint8_t>> tx_queue_;
  RelayStreamBuffer rx_;
  uint64_t rx_bytes_ = 0;
  uint64_t tx_bytes_ = 0;
};

// ---------------------------------------------------------------- RelayAgent
// 对应 UdtRelayAgent
class RelayAgent {
 public:
  using PeerCallback = void (*)(int tcp_fd, int service_id);

  void set_tcp_connect_callback(PeerCallback cb) { connect_cb_ = cb; }
  void set_tcp_disconnect_callback(PeerCallback cb) { disconnect_cb_ = cb; }

  // 隧道注册表
  RelayTunnel* add_tunnel(int udt_fd);
  RelayTunnel* find_tunnel(int udt_fd) const;
  RelayTunnel* remove_tunnel(int udt_fd);
  size_t tunnel_count() const { return by_udt_fd_.size(); }

  // 会话登记/注销（同时维护 tcpFd → udtFd 索引）
  RelaySession* insert_session(int udt_fd, int tcp_fd, uint16_t session_id, uint8_t service_id);
  RelaySession* find_session_by_tcp_fd(int tcp_fd) const;
  RelayTunnel* find_tunnel_by_tcp_fd(int tcp_fd) const;
  RelaySession* remove_session_by_tcp_fd(int tcp_fd);

 private:
  PeerCallback connect_cb_ = nullptr;
  PeerCallback disconnect_cb_ = nullptr;
  std::map<int, int> tcp_to_udt_;              // 对应原库 this+0x18 的表
  std::map<int, std::unique_ptr<RelayTunnel>> by_udt_fd_;   // this+0x30
};

}  // namespace libpunch
