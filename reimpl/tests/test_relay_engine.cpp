// 中继引擎端到端验证：本地 TCP ↔ 中继引擎 ↔ 真实 UDT 隧道 ↔ 假 NAS 对端
#include "libpunch/relay_engine.h"
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

#include "udt.h"

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

// ---------------------------------------------------------------- 工具
static sockaddr_in loopback(uint16_t port) {
  sockaddr_in sa{};
  sa.sin_family = AF_INET;
  sa.sin_port = htons(port);
  sa.sin_addr.s_addr = inet_addr("127.0.0.1");
  return sa;
}

static bool wait_connected(UDTSOCKET a, UDTSOCKET b, int ms) {
  long deadline = now_ms() + ms;
  while (now_ms() < deadline) {
    int sa = 0, sb = 0, len = 4;
    UDT::getsockopt(a, 0, UDT_STATE, &sa, &len);
    len = 4;
    UDT::getsockopt(b, 0, UDT_STATE, &sb, &len);
    if (sa == CONNECTED && sb == CONNECTED) return true;
    std::this_thread::sleep_for(std::chrono::milliseconds(10));
  }
  return false;
}

// 从 UDT 套接字轮询读取，直到解析出一条记录
static bool poll_record(UDTSOCKET fd, RelayStreamBuffer& rx, RelayRecord* out, int timeout_ms) {
  long deadline = now_ms() + timeout_ms;
  char buf[2048];
  while (now_ms() < deadline) {
    RelayError e = rx.pop(out);
    if (e == RelayError::Ok) return true;
    if (e != RelayError::NeedMore) return false;

    int n = UDT::recv(fd, buf, (int)sizeof(buf), 0);
    if (n > 0) {
      rx.append((const uint8_t*)buf, (size_t)n);
      continue;
    }
    std::this_thread::sleep_for(std::chrono::milliseconds(5));
  }
  return false;
}

static bool udt_send_all(UDTSOCKET fd, const std::vector<uint8_t>& data, int timeout_ms) {
  long deadline = now_ms() + timeout_ms;
  size_t off = 0;
  while (off < data.size() && now_ms() < deadline) {
    int n = UDT::send(fd, (const char*)data.data() + off, (int)(data.size() - off), 0);
    if (n > 0) { off += (size_t)n; continue; }
    std::this_thread::sleep_for(std::chrono::milliseconds(5));
  }
  return off == data.size();
}

// ---------------------------------------------------------------- 假 NAS 对端
struct PeerResult {
  std::atomic<bool> ok{false};
  std::atomic<int> open_count{0};
  std::atomic<int> data_count{0};
  std::string received;
  uint16_t session_id = 0;
};

static void peer_main(UDTSOCKET conn, PeerResult* result, std::atomic<bool>* stop) {
  RelayStreamBuffer rx;
  RelayRecord rec;

  // ① 等 OPEN
  if (!poll_record(conn, rx, &rec, 5000)) { result->ok = false; return; }
  result->open_count = 1;
  result->session_id = rec.session_id;

  // ② 回一条 DATA
  std::vector<uint8_t> out;
  const char* msg = "hello from nas";
  encode_relay_record(&out, rec.session_id, rec.service_id, RelayOp::Data, (const uint8_t*)msg,
                      std::strlen(msg));
  udt_send_all(conn, out, 3000);

  // ③ 等客户端的 DATA，并回 TEARDOWN
  while (!stop->load()) {
    if (poll_record(conn, rx, &rec, 500)) {
      if (rec.op == RelayOp::Data) {
        result->data_count = result->data_count + 1;
        result->received.assign(rec.payload.begin(), rec.payload.end());

        std::vector<uint8_t> td;
        encode_relay_control(&td, rec.session_id, rec.service_id, RelayOp::Teardown);
        udt_send_all(conn, td, 3000);
        result->ok = true;
        return;
      }
    }
    if (result->data_count > 0) break;
  }
  result->ok = result->data_count > 0;
}

// ---------------------------------------------------------------- TCP 工具
static int tcp_connect(uint16_t port) {
  int fd = ::socket(AF_INET, SOCK_STREAM, 0);
  if (fd < 0) return -1;
  sockaddr_in sa = loopback(port);
  if (::connect(fd, (sockaddr*)&sa, sizeof(sa)) != 0) { ::close(fd); return -1; }
  int flags = fcntl(fd, F_GETFL, 0);
  fcntl(fd, F_SETFL, flags | O_NONBLOCK);
  return fd;
}

static bool tcp_send_all(int fd, const char* data, size_t len, int timeout_ms) {
  long deadline = now_ms() + timeout_ms;
  size_t off = 0;
  while (off < len && now_ms() < deadline) {
    ssize_t n = ::send(fd, data + off, len - off, 0);
    if (n > 0) { off += (size_t)n; continue; }
    std::this_thread::sleep_for(std::chrono::milliseconds(5));
  }
  return off == len;
}


// ---------------------------------------------------------------- 主测试
static void test_end_to_end() {
  std::printf("[engine] 端到端：本地 TCP ↔ 引擎 ↔ UDT ↔ 假 NAS\n");

  // 建一条真实 UDT 连接（listen + connect，与打洞后的建链等价）
  int lsn = Socket::create_udt_listen_socket(0);
  CHECK(lsn >= 0, "建 UDT 监听套接字");
  if (lsn < 0) return;
  uint16_t udt_port = (uint16_t)Socket::get_udt_channel_port(lsn);

  int cli = Socket::create_udt_client_socket();
  CHECK(cli >= 0, "建 UDT 客户端套接字");

  sockaddr_in sa = loopback(udt_port);
  UDT::connect(cli, (sockaddr*)&sa, sizeof(sa));

  int eid = UDT::epoll_create();
  UDT::epoll_add_usock(eid, lsn);
  std::set<UDTSOCKET> rd, wr;
  UDT::epoll_wait(eid, &rd, &wr, 3000);
  sockaddr_in peer{};
  int plen = sizeof(peer);
  UDTSOCKET conn = UDT::accept(lsn, (sockaddr*)&peer, &plen);
  CHECK(conn != UDT::INVALID_SOCK, "UDT accept 成功");
  CHECK(wait_connected(cli, conn, 3000), "UDT 双方 CONNECTED");
  UDT::epoll_release(eid);

  // 假 NAS 对端
  PeerResult result;
  std::atomic<bool> stop{false};
  std::thread peer_thr(peer_main, conn, &result, &stop);

  // 中继引擎
  RelayEngine engine;
  RelayEngineOptions opts;
  opts.listen_port = 0;
  opts.service_id = 2;      // dsm_https
  opts.read_chunk = 1400;
  CHECK(engine.start(cli, opts), "引擎启动");
  CHECK(engine.local_port() > 0, "拿到本地 TCP 端口");
  std::printf("       引擎本地端口 = %u\n", engine.local_port());

  // 本地 TCP 客户端连上引擎
  int tcp = tcp_connect(engine.local_port());
  CHECK(tcp >= 0, "本地 TCP 连接成功");

  // 客户端先发数据
  CHECK(tcp_send_all(tcp, "ping from client", 16, 2000), "本地 TCP 发送 ping");

  // 驱动引擎，直到双向都完成
  std::string from_local;
  long deadline = now_ms() + 8000;
  while (now_ms() < deadline) {
    engine.poll_once(20);
    if (from_local.size() < 14) {
      char buf[256];
      ssize_t n = ::recv(tcp, buf, sizeof(buf), 0);
      if (n > 0) from_local.append(buf, (size_t)n);
    }
    if (result.ok.load() && from_local.size() >= 14) break;
  }

  CHECK(result.open_count == 1, "对端收到 OPEN 记录");
  CHECK(result.data_count >= 1, "对端收到 DATA 记录");
  CHECK(result.received == "ping from client",
        ("对端收到的载荷正确, got \"" + result.received + "\"").c_str());
  CHECK(from_local == "hello from nas",
        ("本地 TCP 收到对端数据, got \"" + from_local + "\"").c_str());

  // 对端已发 TEARDOWN：再驱动几轮，会话应被拆除
  for (int i = 0; i < 20; ++i) engine.poll_once(20);
  RelayTunnel* t = engine.agent().find_tunnel(cli);
  CHECK(t != nullptr, "隧道仍在（TEARDOWN 只关会话）");

  // 引擎自报的收发字节数应大于 0
  if (t != nullptr) {
    CHECK(t->rx_bytes() > 0, "隧道记录到接收字节");
    CHECK(t->tx_bytes() > 0, "隧道记录到发送字节");
  }

  stop = true;
  if (peer_thr.joinable()) peer_thr.join();
  ::close(tcp);
  engine.stop();
  CHECK(!engine.running(), "stop() 后引擎停止");

  UDT::close(conn);
  UDT::close(cli);
  UDT::close(lsn);
}

// ---------------------------------------------------------------- 引擎契约
static void test_engine_rejects_bad_start() {
  std::printf("[engine] 启动参数校验\n");
  RelayEngine engine;
  RelayEngineOptions opts;
  CHECK(!engine.start(-1, opts), "udt_fd < 0 时启动失败");
  CHECK(!engine.running(), "失败后未运行");
}

static void test_engine_options() {
  std::printf("[engine] 选项生效\n");
  int lsn = Socket::create_udt_listen_socket(0);
  if (lsn < 0) { CHECK(false, "建监听"); return; }
  uint16_t p = (uint16_t)Socket::get_udt_channel_port(lsn);
  int c = Socket::create_udt_client_socket();
  sockaddr_in sa = loopback(p);
  UDT::connect(c, (sockaddr*)&sa, sizeof(sa));

  int eid = UDT::epoll_create();
  UDT::epoll_add_usock(eid, lsn);
  std::set<UDTSOCKET> rd, wr;
  UDT::epoll_wait(eid, &rd, &wr, 3000);
  sockaddr_in peer{};
  int plen = sizeof(peer);
  UDTSOCKET conn = UDT::accept(lsn, (sockaddr*)&peer, &plen);
  wait_connected(c, conn, 3000);
  UDT::epoll_release(eid);

  RelayEngine engine;
  RelayEngineOptions opts;
  opts.listen_port = 0;
  opts.service_id = 7;
  CHECK(engine.start(c, opts), "启动成功");
  CHECK(engine.agent().find_tunnel(c) != nullptr, "隧道已登记");
  CHECK(engine.udt_fd() == c, "udt_fd 记录正确");

  // 本地端口应可连接
  int tcp = tcp_connect(engine.local_port());
  CHECK(tcp >= 0, "本地端口可连接");
  if (tcp >= 0) ::close(tcp);

  engine.stop();
  UDT::close(conn);
  UDT::close(c);
  UDT::close(lsn);
}

int main() {
  test_engine_rejects_bad_start();
  test_end_to_end();
  test_engine_options();

  std::printf("\n%d passed, %d failed\n", g_pass, g_fail);
  return g_fail == 0 ? 0 : 1;
}
