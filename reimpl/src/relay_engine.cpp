// 中继事件循环实现
#include "libpunch/relay_engine.h"

#include <arpa/inet.h>
#include <errno.h>
#include <netinet/in.h>
#include <sys/socket.h>
#include <unistd.h>

#include <chrono>
#include <cstring>
#include <poll.h>
#include <set>

#include "libpunch/socket.h"
#include "udt.h"

namespace libpunch {
namespace {

constexpr int kUdtEventIn = UDT_EPOLL_IN;                      // 0x1
constexpr int kUdtEventOut = UDT_EPOLL_OUT;                    // 0x4
constexpr int kUdtEventInOut = UDT_EPOLL_IN | UDT_EPOLL_OUT;   // 0x5

// 非阻塞下「暂时无法收发」的错误
inline bool would_block(int e) { return e == EAGAIN || e == EWOULDBLOCK || e == EINTR; }

}  // namespace

RelayEngine::RelayEngine() = default;

RelayEngine::~RelayEngine() { stop(); }

bool RelayEngine::start(int udt_fd, const RelayEngineOptions& options) {
  if (running_) return false;
  if (udt_fd < 0) return false;

  udt_fd_ = udt_fd;
  service_id_ = options.service_id;
  read_chunk_ = options.read_chunk == 0 ? 1400 : options.read_chunk;
  idle_timeout_sec_ = options.idle_timeout_sec;
  local_service_port_ = options.local_service_port;
  local_service_host_ = options.local_service_host;

  // 本地 TCP 监听：只为 127.0.0.1 服务
  listen_fd_ = Socket::create_tcp_listen_socket(options.listen_port, "127.0.0.1");
  if (listen_fd_ < 0) return false;

  int port = Socket::get_socket_port(listen_fd_);
  if (port < 0) {
    Socket::close_socket(listen_fd_);
    listen_fd_ = -1;
    return false;
  }
  local_port_ = (uint16_t)port;

  epoll_id_ = UDT::epoll_create();
  if (epoll_id_ < 0) {
    Socket::close_socket(listen_fd_);
    listen_fd_ = -1;
    return false;
  }

  int ev_in = kUdtEventIn;
  int ev_inout = kUdtEventInOut;
  UDT::epoll_add_ssock(epoll_id_, listen_fd_, &ev_in);   // 监听套接字只关心可读
  UDT::epoll_add_usock(epoll_id_, udt_fd_, &ev_inout);   // 隧道需要读写

  agent_.add_tunnel(udt_fd_);

  next_session_id_ = 1;
  idle_seconds_ = 0;
  idle_timeouts_fired_ = 0;
  running_ = true;
  return true;
}

void RelayEngine::stop() {
  if (!running_ && epoll_id_ < 0 && listen_fd_ < 0) return;
  running_ = false;

  // 先拆所有会话，再回收隧道，最后释放 epoll 与监听 fd
  RelayTunnel* t = agent_.find_tunnel(udt_fd_);
  if (t != nullptr) {
    std::vector<int> tcp_fds;
    for (const auto& kv : t->sessions()) tcp_fds.push_back(kv.second->tcp_fd());
    for (int fd : tcp_fds) teardown_session(fd);
    agent_.remove_tunnel(udt_fd_);
  }

  if (epoll_id_ >= 0) {
    UDT::epoll_release(epoll_id_);
    epoll_id_ = -1;
  }
  if (listen_fd_ >= 0) {
    Socket::close_socket(listen_fd_);
    listen_fd_ = -1;
  }
  udt_fd_ = -1;
  local_port_ = 0;
}

void RelayEngine::teardown_session(int tcp_fd) {
  if (epoll_id_ >= 0) UDT::epoll_remove_ssock(epoll_id_, tcp_fd);
  Socket::close_socket(tcp_fd);
  agent_.remove_session_by_tcp_fd(tcp_fd);
}

void RelayEngine::teardown_tunnel(int udt_fd) {
  RelayTunnel* t = agent_.find_tunnel(udt_fd);
  if (t == nullptr) return;

  std::vector<int> tcp_fds;
  for (const auto& kv : t->sessions()) tcp_fds.push_back(kv.second->tcp_fd());
  for (int fd : tcp_fds) teardown_session(fd);

  if (epoll_id_ >= 0) UDT::epoll_remove_usock(epoll_id_, udt_fd);
  agent_.remove_tunnel(udt_fd);
  if (udt_fd == udt_fd_) running_ = false;   // 隧道没了，引擎随之停下
}

void RelayEngine::accept_new_client() {
  sockaddr_in peer{};
  socklen_t len = sizeof(peer);
  int tcp_fd = ::accept(listen_fd_, (sockaddr*)&peer, &len);
  if (tcp_fd < 0) return;

  Socket::set_blocking(tcp_fd, false);
  Socket::set_nosignal(tcp_fd);

  RelayTunnel* t = agent_.find_tunnel(udt_fd_);
  if (t == nullptr) {
    Socket::close_socket(tcp_fd);
    return;
  }

  // sessionId 是隧道内 16 位自增计数器；跳过后清零可避免 0
  uint16_t sid = next_session_id_++;
  if (next_session_id_ == 0) next_session_id_ = 1;
  if (sid == 0) sid = next_session_id_++;

  RelaySession* s = agent_.insert_session(udt_fd_, tcp_fd, sid, service_id_);
  if (s == nullptr) {
    Socket::close_socket(tcp_fd);
    return;
  }

  int ev = kUdtEventIn;
  UDT::epoll_add_ssock(epoll_id_, tcp_fd, &ev);

  // 立刻向对端声明新会话（op = OPEN，无载荷）
  t->enqueue_record(sid, service_id_, RelayOp::Open, nullptr, 0);
}

void RelayEngine::handle_tcp_read(RelaySession* s) {
  RelayTunnel* t = agent_.find_tunnel_by_tcp_fd(s->tcp_fd());
  if (t == nullptr) return;

  std::vector<char> buf(read_chunk_);
  int n = Socket::my_recv(s->tcp_fd(), buf.data(), (long)buf.size(), 0);
  if (n < 0) {
    if (would_block(errno)) return;
    teardown_session(s->tcp_fd());
    return;
  }
  if (n == 0) {                       // 对端关闭了本地 TCP
    teardown_session(s->tcp_fd());
    return;
  }
  if ((size_t)n >= 0x10000) {         // 放不进 16 位长度字段
    teardown_session(s->tcp_fd());
    return;
  }

  t->enqueue_record(s->session_id(), s->service_id(), RelayOp::Data, (const uint8_t*)buf.data(),
                    (size_t)n);
}

void RelayEngine::handle_tcp_write(RelaySession* s) {
  if (s->out_empty()) return;

  const std::vector<uint8_t>& front = s->out_front();
  int n = Socket::my_send(s->tcp_fd(), (const char*)front.data(), (long)front.size(), 0);

  if (n > 0) {
    size_t before = s->out_size();
    s->out_consume((size_t)n);
    size_t after = s->out_size();
    // 队列降到阈值以下 → 恢复隧道读事件（对应原库重新置位读事件）
    if (before > kSessionQueueHighWater && after <= kSessionQueueHighWater) {
      RelayTunnel* t = agent_.find_tunnel_by_tcp_fd(s->tcp_fd());
      if (t != nullptr) {
        int ev = kUdtEventInOut;
        UDT::epoll_add_usock(epoll_id_, t->udt_fd(), &ev);
      }
    }
  } else if (n < 0) {
    if (would_block(errno)) return;
    teardown_session(s->tcp_fd());
    return;
  } else {
    return;   // n == 0，本轮不发
  }

  // 收敛条件：输出队列排空 且 对端已要求关闭
  if (s->out_empty() && s->status() == SessionStatus::Draining) {
    teardown_session(s->tcp_fd());
  }
}

bool RelayEngine::dispatch_record(RelayTunnel* t, const RelayRecord& rec) {
  RelaySession* s = t->find_by_session(rec.session_id);

  switch (rec.op) {
    case RelayOp::Data:
      if (s == nullptr) {
        // 未知会话：回一条 TEARDOWN 让对端收敛
        t->enqueue_record(rec.session_id, rec.service_id, RelayOp::Teardown, nullptr, 0);
        return false;
      }
      s->enqueue(rec.payload);
      s->set_status(SessionStatus::Active);
      // 积压超阈值 → 摘掉隧道读事件做背压（本地 TCP 写空后恢复）
      if (s->backlogged()) {
        int ev = kUdtEventOut;
        UDT::epoll_add_usock(epoll_id_, t->udt_fd(), &ev);
      }
      return true;

    case RelayOp::Close:
      teardown_tunnel(t->udt_fd());
      return true;

    case RelayOp::Open:
      // 对端声明新会话：本端按配置拨号本地服务，建立对应会话
      if (s == nullptr && local_service_port_ > 0) {
        int fd = ::socket(AF_INET, SOCK_STREAM, 0);
        if (fd >= 0) {
          sockaddr_in sa{};
          sa.sin_family = AF_INET;
          sa.sin_port = htons((uint16_t)local_service_port_);
          if (!Socket::resolve_ipv4(local_service_host_, &sa.sin_addr)) {
            Socket::close_socket(fd);
            t->enqueue_record(rec.session_id, rec.service_id, RelayOp::Teardown, nullptr, 0);
            return false;
          }
          if (::connect(fd, (sockaddr*)&sa, sizeof(sa)) == 0) {
            Socket::set_blocking(fd, false);
            Socket::set_nosignal(fd);
            RelaySession* ns = agent_.insert_session(t->udt_fd(), fd, rec.session_id,
                                                     rec.service_id);
            if (ns != nullptr) {
              int ev = kUdtEventIn;
              UDT::epoll_add_ssock(epoll_id_, fd, &ev);
              return true;
            }
            Socket::close_socket(fd);
          } else {
            Socket::close_socket(fd);
          }
        }
        // 拨号失败 → 回 TEARDOWN 让对端收敛
        t->enqueue_record(rec.session_id, rec.service_id, RelayOp::Teardown, nullptr, 0);
        return false;
      }
      [[fallthrough]];

    case RelayOp::Teardown:
    default:
      // 对端要求收尾：本地已无待发数据就直接拆，否则等写空（Draining）
      if (s == nullptr || s->out_empty()) {
        if (s != nullptr) teardown_session(s->tcp_fd());
      } else {
        s->set_status(SessionStatus::Draining);
      }
      return s != nullptr;
  }
}

void RelayEngine::handle_udt_read(RelayTunnel* t) {
  char buf[4096];
  int n = UDT::recv(t->udt_fd(), buf, (int)sizeof(buf), 0);

  if (n > 0) {
    t->rx().append((const uint8_t*)buf, (size_t)n);
    t->add_rx_bytes((uint64_t)n);
  } else if (n == 0) {
    teardown_tunnel(t->udt_fd());     // 对端关闭隧道
    return;
  } else {
    // 非阻塞下无数据可读是常态
    UDT::ERRORINFO& info = UDT::getlasterror();
    if (info.getErrorCode() == 6002 /* EASYNCRCV */) return;
    teardown_tunnel(t->udt_fd());
    return;
  }

  RelayRecord rec;
  for (;;) {
    RelayError err = t->rx().pop(&rec);
    if (err == RelayError::NeedMore) break;
    if (err != RelayError::Ok) {       // 协议错误 → 隧道不可用
      teardown_tunnel(t->udt_fd());
      return;
    }
    if (!dispatch_record(t, rec)) {
      // 分发过程中可能已经拆掉隧道
      if (agent_.find_tunnel(t->udt_fd()) == nullptr) return;
    }
  }
}

void RelayEngine::handle_udt_write(RelayTunnel* t) {
  if (t->tx_empty()) return;

  const std::vector<uint8_t>& front = t->tx_front();
  int n = UDT::send(t->udt_fd(), (const char*)front.data(), (int)front.size(), 0);

  if (n > 0) {
    t->tx_consume((size_t)n);
    t->add_tx_bytes((uint64_t)n);
  } else if (n == UDT::ERROR) {
    UDT::ERRORINFO& info = UDT::getlasterror();
    if (info.getErrorCode() != 6001 /* EASYNCSND */) teardown_tunnel(t->udt_fd());
    return;
  } else {
    return;
  }
}

void RelayEngine::poll_tcp_fds(int timeout_ms, std::set<int>* read_fds, std::set<int>* write_fds) {
  std::vector<struct pollfd> fds;
  fds.push_back({listen_fd_, POLLIN, 0});

  RelayTunnel* t = agent_.find_tunnel(udt_fd_);
  if (t != nullptr) {
    for (const auto& kv : t->sessions()) {
      short ev = POLLIN;
      if (!kv.second->out_empty()) ev |= POLLOUT;   // 无待发数据时不关注可写，避免忙等
      fds.push_back({kv.second->tcp_fd(), ev, 0});
    }
  }

  int n = ::poll(fds.data(), fds.size(), timeout_ms);
  if (n <= 0) return;

  for (const struct pollfd& p : fds) {
    if (p.revents & (POLLIN | POLLHUP | POLLERR)) read_fds->insert(p.fd);
    if (p.revents & POLLOUT) write_fds->insert(p.fd);
  }
}

int RelayEngine::poll_once(int timeout_ms) {
  if (!running_) return 0;

  std::set<UDTSOCKET> read_udt, write_udt;
  std::set<SYSSOCKET> read_sys, write_sys;

#if defined(__linux__)
  // Android / Linux：单次 epoll_wait 同时覆盖 UDT 与系统 fd，与原库一致
  int n = UDT::epoll_wait(epoll_id_, &read_udt, &write_udt, timeout_ms, &read_sys, &write_sys);
  if (n < 1) {
    UDT::ERRORINFO& info = UDT::getlasterror();
    if (info.getErrorCode() != 6003 /* ETIMEOUT */ && errno != EINTR) {
      if (!running_) return 0;
    }
  }
#else
  // macOS 等平台：udt4 只跟踪系统 fd 却不轮询，改用 poll() 补上
  UDT::epoll_wait(epoll_id_, &read_udt, &write_udt, 0, &read_sys, &write_sys);
  read_sys.clear();
  write_sys.clear();
  if (read_udt.empty() && write_udt.empty()) {
    poll_tcp_fds(timeout_ms, &read_sys, &write_sys);
  } else {
    poll_tcp_fds(0, &read_sys, &write_sys);
  }
#endif
  if (!running_) return 0;

  int handled = 0;

  // ① 本地 TCP 可读：监听套接字 → accept；其余 → 收数据进隧道
  for (int fd : read_sys) {
    if (fd == listen_fd_) {
      accept_new_client();
      ++handled;
    } else {
      RelaySession* s = agent_.find_session_by_tcp_fd(fd);
      if (s != nullptr) {
        handle_tcp_read(s);
        ++handled;
      }
    }
  }

  // ② 本地 TCP 可写：把隧道送来的数据写出去
  for (int fd : write_sys) {
    RelaySession* s = agent_.find_session_by_tcp_fd(fd);
    if (s != nullptr) {
      handle_tcp_write(s);
      ++handled;
    }
  }

  // ③ 隧道可读：重组并分发到会话
  for (UDTSOCKET u : read_udt) {
    RelayTunnel* t = agent_.find_tunnel((int)u);
    if (t != nullptr) {
      handle_udt_read(t);
      ++handled;
    }
  }

  // ④ 隧道可写：把本地 TCP 的待发记录发出去
  for (UDTSOCKET u : write_udt) {
    RelayTunnel* t = agent_.find_tunnel((int)u);
    if (t != nullptr) {
      handle_udt_write(t);
      ++handled;
    }
  }

  // 空闲记账：本轮毫无动静才累加
  if (handled == 0) {
    idle_seconds_ += (uint64_t)(timeout_ms > 0 ? timeout_ms : 0) / 1000;
    if (idle_seconds_ == 0 && timeout_ms > 0) idle_seconds_ = 0;
  } else {
    idle_seconds_ = 0;
  }

  if (idle_timeout_sec_ >= 0 && idle_seconds_ > (uint64_t)idle_timeout_sec_) {
    ++idle_timeouts_fired_;
    idle_seconds_ = 0;
  }

  return handled;
}

}  // namespace libpunch
