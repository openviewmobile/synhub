// 顶层编排端到端验证
//   本地 TCP 客户端 → 发起方引擎 → 真实 UDT 隧道 → 被动方引擎 → 本地 TCP 服务端
#include "libpunch/relay_client.h"
#include "libpunch/socket.h"

#include <arpa/inet.h>
#include <errno.h>
#include <fcntl.h>
#include <netinet/in.h>
#include <sys/socket.h>
#include <unistd.h>

#include <atomic>
#include <chrono>
#include <cstdio>
#include <cstring>
#include <string>
#include <thread>
#include <vector>

using namespace libpunch;

static int g_fail = 0, g_pass = 0;

#define CHECK(cond, msg)                                                    \
  do {                                                                      \
    if (cond) { ++g_pass; }                                                 \
    else { ++g_fail; std::printf("  FAIL: %s (%s:%d)\n", msg, __FILE__, __LINE__); } \
  } while (0)

static long now_ms() {
  return std::chrono::duration_cast<std::chrono::milliseconds>(
             std::chrono::steady_clock::now().time_since_epoch()).count();
}

static sockaddr_in loopback(uint16_t port) {
  sockaddr_in sa{};
  sa.sin_family = AF_INET;
  sa.sin_port = htons(port);
  sa.sin_addr.s_addr = inet_addr("127.0.0.1");
  return sa;
}

// ---------------------------------------------------------------- 假 echo 服务器
class FakeEcho {
 public:
  ~FakeEcho() { stop(); }

  bool start() {
    if (fd_ >= 0) return true;      // 幂等，避免重复赋值 std::thread
    fd_ = ::socket(AF_INET, SOCK_DGRAM, 0);
    if (fd_ < 0) return false;
    sockaddr_in sa = loopback(0);
    if (::bind(fd_, (sockaddr*)&sa, sizeof(sa)) != 0) return false;
    socklen_t len = sizeof(sa);
    ::getsockname(fd_, (sockaddr*)&sa, &len);
    bind_port_ = ntohs(sa.sin_port);
    th_ = std::thread([this] { loop(); });
    return true;
  }

  void stop() {
    stop_.store(true);
    if (th_.joinable()) th_.join();
    if (fd_ >= 0) { ::close(fd_); fd_ = -1; }
  }

  void set_reply(const char* ip, uint16_t port) {
    reply_ip_ = inet_addr(ip);
    reply_port_ = port;
  }
  uint16_t port() const { return bind_port_; }
  int requests() const { return requests_.load(); }

 private:
  void loop() {
    timeval tv{0, 100 * 1000};
    ::setsockopt(fd_, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof(tv));
    while (!stop_.load()) {
      uint8_t buf[512];
      sockaddr_in from{};
      socklen_t flen = sizeof(from);
      ssize_t n = ::recvfrom(fd_, buf, sizeof(buf), 0, (sockaddr*)&from, &flen);
      if (n < 0) continue;
      if (n == 0) continue;                        // TTL 敲门包
      if (n != (ssize_t)sizeof(command_t)) continue;
      requests_.fetch_add(1);

      // 回一条携带对端地址的 148 字节命令
      uint8_t pl[6];
      uint32_t ip = reply_ip_;
      uint16_t pt = htons(reply_port_);
      std::memcpy(pl, &ip, 4);
      std::memcpy(pl + 4, &pt, 2);

      command_t reply;
      CommandHandler::set(reply, CommandCode::PunchPrimary, pl, 6, CommandOption::WithPayload);
      ::sendto(fd_, &reply, sizeof(reply), 0, (sockaddr*)&from, flen);
    }
  }

  int fd_ = -1;
  uint16_t bind_port_ = 0;
  uint16_t reply_port_ = 0;
  uint32_t reply_ip_ = 0;
  std::thread th_;
  std::atomic<bool> stop_{false};
  std::atomic<int> requests_{0};
};

// ---------------------------------------------------------------- 本地 TCP 工具
static int tcp_connect(uint16_t port) {
  int fd = ::socket(AF_INET, SOCK_STREAM, 0);
  if (fd < 0) return -1;
  sockaddr_in sa = loopback(port);
  if (::connect(fd, (sockaddr*)&sa, sizeof(sa)) != 0) { ::close(fd); return -1; }
  int fl = fcntl(fd, F_GETFL, 0);
  fcntl(fd, F_SETFL, fl | O_NONBLOCK);
  return fd;
}

static std::string tcp_recv_n(int fd, size_t want, int timeout_ms) {
  long deadline = now_ms() + timeout_ms;
  std::string got;
  char buf[256];
  while (got.size() < want && now_ms() < deadline) {
    ssize_t n = ::recv(fd, buf, sizeof(buf), 0);
    if (n > 0) { got.append(buf, (size_t)n); continue; }
    std::this_thread::sleep_for(std::chrono::milliseconds(5));
  }
  return got;
}

// 模拟 NAS：在被动方引擎的本地端口上收 "ping" 回 "pong"
static void nas_server(uint16_t port, std::atomic<bool>* ready, std::atomic<bool>* stop,
                       std::string* seen, std::atomic<uint16_t>* actual_port) {
  int lsn = ::socket(AF_INET, SOCK_STREAM, 0);
  int one = 1;
  ::setsockopt(lsn, SOL_SOCKET, SO_REUSEADDR, &one, sizeof(one));
  sockaddr_in sa = loopback(port);
  if (::bind(lsn, (sockaddr*)&sa, sizeof(sa)) != 0) { ready->store(true); ::close(lsn); return; }
  socklen_t slen = sizeof(sa);
  ::getsockname(lsn, (sockaddr*)&sa, &slen);
  if (actual_port != nullptr) actual_port->store(ntohs(sa.sin_port));
  ::listen(lsn, 4);
  ready->store(true);

  int fl = fcntl(lsn, F_GETFL, 0);
  fcntl(lsn, F_SETFL, fl | O_NONBLOCK);

  long deadline = now_ms() + 10000;
  while (!stop->load() && now_ms() < deadline) {
    int c = ::accept(lsn, nullptr, nullptr);
    if (c < 0) { std::this_thread::sleep_for(std::chrono::milliseconds(5)); continue; }

    int cf = fcntl(c, F_GETFL, 0);
    fcntl(c, F_SETFL, cf | O_NONBLOCK);

    std::string data = tcp_recv_n(c, 4, 4000);   // 等 "ping"
    seen->assign(data);
    if (!data.empty()) {
      const char* pong = "pong";
      long d2 = now_ms() + 2000;
      size_t off = 0;
      while (off < 4 && now_ms() < d2) {
        ssize_t n = ::send(c, pong + off, 4 - off, 0);
        if (n > 0) { off += (size_t)n; continue; }
        std::this_thread::sleep_for(std::chrono::milliseconds(5));
      }
    }
    std::this_thread::sleep_for(std::chrono::milliseconds(200));
    ::close(c);
  }
  ::close(lsn);
}

// ---------------------------------------------------------------- 主测试
static void test_full_stack() {
  std::printf("[client] 全栈：打洞 → UDT → 两个引擎 → 本地 TCP 回环\n");

  FakeEcho echo;
  bool echo_ok = echo.start();
  CHECK(echo_ok, "假 echo 服务器启动");
  if (!echo_ok) return;
  echo.set_reply("127.0.0.1", 1);   // 先给个占位地址

  TunnelRequest base;
  base.qc_id = "test-qcid";
  base.service_id = 2;
  base.echo_servers.push_back({"127.0.0.1", echo.port()});
  base.punch_timeout_ms = 2000;
  base.connect_timeout_ms = 5000;

  // ---- 被动方：先 prepare 拿到 UDT 监听端口，再写进 echo 回复 ----
  RelayClient responder;
  TunnelRequest rreq = base;
  TunnelError rc = responder.prepare(rreq);
  CHECK(rc == TunnelError::Ok, ("被动方 prepare, err=" + std::string(tunnel_error_name(rc))).c_str());
  if (rc != TunnelError::Ok) return;

  uint16_t r_udt_port = responder.udt_listen_port();
  CHECK(r_udt_port > 0, "被动方拿到 UDT 监听端口");
  echo.set_reply("127.0.0.1", r_udt_port);
  std::printf("       被动方 UDT 端口 = %u\n", r_udt_port);

  // NAS 先起在自己的固定端口上，被动方收到 OPEN 后拨号到这里
  const uint16_t kNasPort = 0;   // 0 = 由 NAS 自己选
  std::atomic<bool> nas_ready{false}, nas_stop{false};
  std::string nas_seen;
  std::atomic<uint16_t> nas_port{0};
  std::thread nas(nas_server, kNasPort, &nas_ready, &nas_stop, &nas_seen, &nas_port);
  long nw0 = now_ms() + 3000;
  while (!nas_ready.load() && now_ms() < nw0) std::this_thread::sleep_for(std::chrono::milliseconds(10));
  CHECK(nas_ready.load(), "NAS 服务端就绪");
  rreq.local_service_port = nas_port.load();
  std::printf("       NAS 本地服务端口 = %u\n", nas_port.load());

  std::atomic<bool> resp_up{false};
  std::thread resp_thread([&] {
    try {
      TunnelError e = responder.await_peer(rreq);
      if (e != TunnelError::Ok) {
        std::printf("       被动方 await_peer 失败: %s\n", tunnel_error_name(e));
        resp_up = true;
        return;
      }
      e = responder.start_engine(rreq);
      if (e != TunnelError::Ok) std::printf("       被动方 start_engine 失败: %s\n", tunnel_error_name(e));
    } catch (...) {
      std::printf("       被动方线程抛出异常\n");
    }
    resp_up = true;
  });

  // ---- 发起方：带候选地址 → rendezvous 建链 ----
  RelayClient initiator;
  TunnelRequest ireq = base;
  ireq.has_candidate = true;
  ireq.candidate = loopback(r_udt_port);
  // 对端是纯 listener，必须用普通 client 套接字；
  // rendezvous 模式要求双方都设 UDT_RENDEZVOUS（见 test_udt.cpp 的对称用例）。
  ireq.use_rendezvous = false;

  rc = initiator.prepare(ireq);
  CHECK(rc == TunnelError::Ok, ("发起方 prepare, err=" + std::string(tunnel_error_name(rc))).c_str());
  CHECK(initiator.is_initiator(), "发起方走 rendezvous 分支");
  CHECK(initiator.punch_result().error == PunchError::Ok, "发起方打洞成功");
  CHECK(initiator.punch_result().peer.sin_port == htons(r_udt_port),
        "发起方从 echo 拿到被动方端口");
  CHECK(echo.requests() >= 1, "echo 服务器收到打洞请求");

  rc = initiator.await_peer(ireq);
  CHECK(rc == TunnelError::Ok, ("发起方建链, err=" + std::string(tunnel_error_name(rc))).c_str());

  // 等被动方 accept 完成
  long wd = now_ms() + 5000;
  while (!resp_up.load() && now_ms() < wd) std::this_thread::sleep_for(std::chrono::milliseconds(10));
  CHECK(resp_up.load(), "被动方接入流程完成");

  CHECK(initiator.udt_fd() >= 0, "发起方拿到 UDT 隧道 fd");
  CHECK(responder.udt_fd() >= 0, "被动方拿到 UDT 隧道 fd");

  if (initiator.udt_fd() < 0 || responder.udt_fd() < 0) {
    initiator.stop(); responder.stop();
    if (resp_thread.joinable()) resp_thread.join();
    echo.stop();
    return;
  }

  rc = initiator.start_engine(ireq);
  CHECK(rc == TunnelError::Ok, "发起方引擎启动");
  CHECK(initiator.local_port() > 0, "发起方拿到本地 TCP 端口");
  CHECK(responder.local_port() > 0, "被动方拿到本地 TCP 端口");

  std::printf("       发起方本地端口 = %u, 被动方本地端口 = %u\n",
              initiator.local_port(), responder.local_port());

  // ---- 客户端连发起方的本地端口，发 "ping" 期待 "pong" ----
  int cli = tcp_connect(initiator.local_port());
  CHECK(cli >= 0, "客户端连上发起方本地端口");

  std::string from_nas;
  if (cli >= 0) {
    ::send(cli, "ping", 4, 0);
    long deadline = now_ms() + 8000;
    while (now_ms() < deadline) {
      initiator.engine().poll_once(10);
      responder.engine().poll_once(10);
      if (from_nas.size() < 4) {
        char buf[64];
        ssize_t n = ::recv(cli, buf, sizeof(buf), 0);
        if (n > 0) from_nas.append(buf, (size_t)n);
      }
      if (from_nas.size() >= 4 && nas_seen.size() >= 4) break;
    }
  }

  CHECK(nas_seen == "ping", ("NAS 收到 \"ping\", got \"" + nas_seen + "\"").c_str());
  CHECK(from_nas == "pong", ("客户端收到 \"pong\", got \"" + from_nas + "\"").c_str());

  nas_stop = true;
  if (nas.joinable()) nas.join();
  if (cli >= 0) ::close(cli);
  initiator.stop();
  responder.stop();
  if (resp_thread.joinable()) resp_thread.join();
  echo.stop();

  CHECK(!initiator.running(), "发起方已停止");
  CHECK(!responder.running(), "被动方已停止");
}

// ---------------------------------------------------------------- 参数校验
static void test_error_paths() {
  std::printf("[client] 错误路径\n");
  CHECK(std::string(tunnel_error_name(TunnelError::Ok)) == "Ok", "错误名 Ok");
  CHECK(std::string(tunnel_error_name(TunnelError::PunchFailed)) == "PunchFailed", "错误名 PunchFailed");

  RelayClient c;
  TunnelRequest req;
  req.qc_id = "x";
  req.punch_timeout_ms = 200;
  // 无 echo 服务器 → 打洞早退
  TunnelError rc = c.prepare(req);
  CHECK(rc == TunnelError::PunchFailed, "空服务器列表 → PunchFailed");
  CHECK(!c.running(), "失败后未运行");
  CHECK(c.local_port() == 0, "失败后无本地端口");
}

int main() {
  test_error_paths();
  test_full_stack();

  std::printf("\n%d passed, %d failed\n", g_pass, g_fail);
  return g_fail == 0 ? 0 : 1;
}
