// 隧道会话对象与注册表实现
#include "libpunch/relay_session.h"

#include <algorithm>
#include <cstring>

namespace libpunch {

// ---------------------------------------------------------------- RelaySession
void RelaySession::out_consume(size_t n) {
  if (out_queue_.empty()) return;
  std::vector<uint8_t>& front = out_queue_.front();
  if (n >= front.size()) {
    // 整块发完
    out_queue_.pop_front();
    return;
  }
  // 部分发出：丢弃已发前缀（对应原库 operator_new + memcpy 搬运剩余字节）
  front.erase(front.begin(), front.begin() + (std::ptrdiff_t)n);
}

// ---------------------------------------------------------------- RelayTunnel
RelaySession* RelayTunnel::add_session(int tcp_fd, uint16_t session_id, uint8_t service_id) {
  // 同 sessionId 或同 tcpFd 已存在时不重复登记（保持两张索引一致）
  auto it = by_session_.find(session_id);
  if (it != by_session_.end()) {
    return it->second;
  }
  if (by_tcp_fd_.count(tcp_fd) != 0) {
    return nullptr;
  }

  RelaySession* s = new RelaySession(tcp_fd, session_id, service_id);
  by_session_[session_id] = s;
  by_tcp_fd_[tcp_fd] = s;
  return s;
}

RelaySession* RelayTunnel::find_by_session(uint16_t session_id) const {
  auto it = by_session_.find(session_id);
  return it == by_session_.end() ? nullptr : it->second;
}

RelaySession* RelayTunnel::find_by_tcp_fd(int tcp_fd) const {
  auto it = by_tcp_fd_.find(tcp_fd);
  return it == by_tcp_fd_.end() ? nullptr : it->second;
}

RelaySession* RelayTunnel::remove_session(uint16_t session_id) {
  auto it = by_session_.find(session_id);
  if (it == by_session_.end()) return nullptr;
  RelaySession* s = it->second;
  by_session_.erase(it);
  by_tcp_fd_.erase(s->tcp_fd());
  delete s;
  return s;   // 已 delete，返回非空仅表示「原本存在」
}

void RelayTunnel::remove_session_by_tcp_fd(int tcp_fd) {
  auto it = by_tcp_fd_.find(tcp_fd);
  if (it == by_tcp_fd_.end()) return;
  RelaySession* s = it->second;
  by_tcp_fd_.erase(it);
  by_session_.erase(s->session_id());
  delete s;
}

void RelayTunnel::enqueue_record(uint16_t session_id, uint8_t service_id, RelayOp op,
                                 const uint8_t* payload, size_t len) {
  std::vector<uint8_t> rec;
  encode_relay_record(&rec, session_id, service_id, op, payload, len);
  if (!rec.empty()) tx_queue_.push_back(std::move(rec));
}

void RelayTunnel::tx_consume(size_t n) {
  if (tx_queue_.empty()) return;
  std::vector<uint8_t>& front = tx_queue_.front();
  if (n >= front.size()) {
    tx_queue_.pop_front();
    return;
  }
  front.erase(front.begin(), front.begin() + (std::ptrdiff_t)n);
}

size_t RelayTunnel::tx_pending_bytes() const {
  size_t total = 0;
  for (const auto& v : tx_queue_) total += v.size();
  return total;
}

// ---------------------------------------------------------------- RelayAgent
RelayTunnel* RelayAgent::add_tunnel(int udt_fd) {
  auto it = by_udt_fd_.find(udt_fd);
  if (it != by_udt_fd_.end()) return it->second.get();

  auto t = std::make_unique<RelayTunnel>(udt_fd);
  RelayTunnel* raw = t.get();
  by_udt_fd_[udt_fd] = std::move(t);
  return raw;
}

RelayTunnel* RelayAgent::find_tunnel(int udt_fd) const {
  auto it = by_udt_fd_.find(udt_fd);
  return it == by_udt_fd_.end() ? nullptr : it->second.get();
}

RelayTunnel* RelayAgent::remove_tunnel(int udt_fd) {
  auto it = by_udt_fd_.find(udt_fd);
  if (it == by_udt_fd_.end()) return nullptr;

  RelayTunnel* t = it->second.get();
  // 清掉该隧道下所有会话的 tcpFd 索引
  for (const auto& kv : t->sessions()) {
    tcp_to_udt_.erase(kv.second->tcp_fd());
  }
  by_udt_fd_.erase(it);
  return t;   // 已析构，返回非空仅表示「原本存在」
}

RelaySession* RelayAgent::insert_session(int udt_fd, int tcp_fd, uint16_t session_id,
                                         uint8_t service_id) {
  RelayTunnel* t = find_tunnel(udt_fd);
  if (t == nullptr) return nullptr;
  if (tcp_to_udt_.count(tcp_fd) != 0) return nullptr;

  RelaySession* s = t->add_session(tcp_fd, session_id, service_id);
  if (s == nullptr) return nullptr;

  tcp_to_udt_[tcp_fd] = udt_fd;
  if (connect_cb_ != nullptr) connect_cb_(tcp_fd, (int)service_id);
  return s;
}

RelayTunnel* RelayAgent::find_tunnel_by_tcp_fd(int tcp_fd) const {
  auto it = tcp_to_udt_.find(tcp_fd);
  if (it == tcp_to_udt_.end()) return nullptr;
  return find_tunnel(it->second);
}

RelaySession* RelayAgent::find_session_by_tcp_fd(int tcp_fd) const {
  RelayTunnel* t = find_tunnel_by_tcp_fd(tcp_fd);
  if (t == nullptr) return nullptr;
  return t->find_by_tcp_fd(tcp_fd);
}

RelaySession* RelayAgent::remove_session_by_tcp_fd(int tcp_fd) {
  auto it = tcp_to_udt_.find(tcp_fd);
  if (it == tcp_to_udt_.end()) return nullptr;

  RelayTunnel* t = find_tunnel(it->second);
  RelaySession* s = (t != nullptr) ? t->find_by_tcp_fd(tcp_fd) : nullptr;
  int service = (s != nullptr) ? (int)s->service_id() : 0;

  if (t != nullptr) t->remove_session_by_tcp_fd(tcp_fd);
  tcp_to_udt_.erase(it);

  if (disconnect_cb_ != nullptr) disconnect_cb_(tcp_fd, service);
  return s;   // 已 delete，返回非空仅表示「原本存在」
}

}  // namespace libpunch
