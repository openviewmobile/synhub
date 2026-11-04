// UDT 原语验证：真实建立 UDT 连接并传数据（含 rendezvous 打洞模式）
#include "libpunch/socket.h"

#include <arpa/inet.h>
#include <netinet/in.h>
#include <sys/socket.h>

#include <chrono>
#include <cstdio>
#include <cstring>
#include <set>
#include <string>
#include <thread>

#include "udt.h"

using namespace libpunch;

static int g_fail = 0, g_pass = 0;

#define CHECK(cond, msg)                                                    \
  do {                                                                      \
    if (cond) { ++g_pass; }                                                 \
    else { ++g_fail; std::printf("  FAIL: %s (%s:%d)\n", msg, __FILE__, __LINE__); } \
  } while (0)

static sockaddr_in loopback(uint16_t port) {
  sockaddr_in sa{};
  sa.sin_family = AF_INET;
  sa.sin_port = htons(port);
  sa.sin_addr.s_addr = inet_addr("127.0.0.1");
  return sa;
}

// 阻塞等待某 socket 可读（非阻塞 recv 需要）
static bool wait_readable(int eid, UDTSOCKET s, int timeout_ms) {
  UDT::epoll_add_usock(eid, s);
  std::set<UDTSOCKET> rd, wr;
  int n = UDT::epoll_wait(eid, &rd, &wr, timeout_ms);
  UDT::epoll_remove_usock(eid, s);
  return n > 0 && rd.count(s) > 0;
}

static int recv_with_wait(int eid, UDTSOCKET s, char* buf, int len, int timeout_ms) {
  for (int i = 0; i < 50; ++i) {
    int r = UDT::recv(s, buf, len, 0);
    if (r > 0) return r;
    (void)r;   // 非阻塞下暂无数据是常态，交给 wait_readable 重试
    if (!wait_readable(eid, s, timeout_ms / 10 + 1)) {
      std::this_thread::sleep_for(std::chrono::milliseconds(10));
    }
  }
  return -1;
}

static int send_with_wait(int eid, UDTSOCKET s, const char* buf, int len, int timeout_ms) {
  for (int i = 0; i < 50; ++i) {
    int r = UDT::send(s, buf, len, 0);
    if (r > 0) return r;
    UDT::epoll_add_usock(eid, s);
    std::set<UDTSOCKET> rd, wr;
    UDT::epoll_wait(eid, &rd, &wr, timeout_ms / 10 + 1);
    UDT::epoll_remove_usock(eid, s);
    std::this_thread::sleep_for(std::chrono::milliseconds(5));
  }
  return -1;
}

static int state_of(UDTSOCKET s) {
  int st = 0, len = 4;
  if (UDT::getsockopt(s, 0, UDT_STATE, &st, &len) == UDT::ERROR) return -1;
  return st;
}

// ---------------------------------------------------------------- 选项生效
static void test_options_applied() {
  std::printf("[udt] 选项生效\n");
  int s = Socket::create_udt_client_socket();
  CHECK(s >= 0, "create_udt_client_socket 成功");
  if (s < 0) return;

  int v = 0, len = 4;
  CHECK(UDT::getsockopt(s, 0, UDT_MSS, &v, &len) != UDT::ERROR, "读 UDT_MSS");
  CHECK(v == 1500, ("MSS == 1500, got " + std::to_string(v)).c_str());

  // udt4 把 UDT_SNDBUF/RCVBUF 存成「包个数」，取值时返回 count * (MSS - 28)。
  // 192000 / (1500-28) = 130（整除截断）→ 130 * 1472 = 191360
  len = 4;
  CHECK(UDT::getsockopt(s, 0, UDT_SNDBUF, &v, &len) != UDT::ERROR, "读 UDT_SNDBUF");
  CHECK(v == 191360, ("UDT_SNDBUF == 130*(1500-28) = 191360, got " + std::to_string(v)).c_str());

  len = 4;
  CHECK(UDT::getsockopt(s, 0, UDT_RCVBUF, &v, &len) != UDT::ERROR, "读 UDT_RCVBUF");
  CHECK(v == 191360, ("UDT_RCVBUF == 191360, got " + std::to_string(v)).c_str());

  len = 4;
  CHECK(UDT::getsockopt(s, 0, UDP_SNDBUF, &v, &len) != UDT::ERROR, "读 UDP_SNDBUF");
  CHECK(v == 96000, ("UDP_SNDBUF == 96000, got " + std::to_string(v)).c_str());

  len = 1;
  char syn = 1;
  CHECK(UDT::getsockopt(s, 0, UDT_RCVSYN, &syn, &len) != UDT::ERROR, "读 UDT_RCVSYN");
  CHECK(syn == 0, "RCVSYN 为非阻塞(0)");

  UDT::close(s);
}

// ---------------------------------------------------------------- 监听/连接
static void test_listen_connect_transfer() {
  std::printf("[udt] 监听 → 连接 → 双向传数据\n");

  int lsn = Socket::create_udt_listen_socket(0);
  CHECK(lsn >= 0, "create_udt_listen_socket 成功");
  if (lsn < 0) return;

  CHECK(state_of(lsn) == LISTENING, "监听套接字状态为 LISTENING");

  int port = Socket::get_udt_channel_port(lsn);
  CHECK(port > 0 && port < 65536, ("get_udt_channel_port 合法, got " + std::to_string(port)).c_str());

  int cli = Socket::create_udt_client_socket();
  CHECK(cli >= 0, "create_udt_client_socket 成功");

  int eid = UDT::epoll_create();
  CHECK(eid >= 0, "epoll_create 成功");

  sockaddr_in sa = loopback((uint16_t)port);
  UDT::connect(cli, (sockaddr*)&sa, sizeof(sa));   // 非阻塞，立即返回

  CHECK(wait_readable(eid, lsn, 3000), "监听套接字可读（有连接待接受）");

  sockaddr_in peer{};
  int plen = sizeof(peer);
  UDTSOCKET conn = UDT::accept(lsn, (sockaddr*)&peer, &plen);
  CHECK(conn != UDT::INVALID_SOCK, "accept 成功");

  // 非阻塞套接字：必须等双方都进入 CONNECTED 才能发数据
  for (int i = 0; i < 100; ++i) {
    if (state_of(cli) == CONNECTED && state_of(conn) == CONNECTED) break;
    std::this_thread::sleep_for(std::chrono::milliseconds(20));
  }
  CHECK(state_of(cli) == CONNECTED, "客户端进入 CONNECTED");

  if (conn != UDT::INVALID_SOCK) {
    // 客户端 → 服务端
    const char* msg = "hello udt over loopback";
    int sent = send_with_wait(eid, cli, msg, (int)std::strlen(msg), 3000);
    CHECK(sent == (int)std::strlen(msg), ("客户端 send 成功, got " + std::to_string(sent)).c_str());

    char buf[128] = {0};
    int r = recv_with_wait(eid, conn, buf, sizeof(buf) - 1, 3000);
    CHECK(r == (int)std::strlen(msg), "服务端 recv 到等长数据");
    CHECK(std::string(buf, r > 0 ? r : 0) == msg, "数据内容一致");

    // 服务端 → 客户端
    const char* back = "ack";
    send_with_wait(eid, conn, back, (int)std::strlen(back), 3000);
    char buf2[64] = {0};
    int r2 = recv_with_wait(eid, cli, buf2, sizeof(buf2) - 1, 3000);
    CHECK(r2 == 3 && std::string(buf2, 3) == "ack", "反向数据一致");

    // 对端地址查询
    CHECK(Socket::get_remote_udt_port(conn) == Socket::get_udt_channel_port(cli),
          "conn 看到的对端端口 == 客户端本地端口");
    CHECK(Socket::get_remote_udt_ip(conn) == 0x7f000001u, "conn 看到的对端 IP == 127.0.0.1");

    UDT::close(conn);
  }

  UDT::epoll_release(eid);
  UDT::close(cli);
  UDT::close(lsn);
}

// ---------------------------------------------------------------- rendezvous
// 这就是打洞模式：双方各自 bind 后同时 connect 对方，无需 listen/accept
static void test_rendezvous() {
  std::printf("[udt] rendezvous 打洞模式\n");

  int a = Socket::create_udt_channel_socket(0);
  int b = Socket::create_udt_channel_socket(0);
  CHECK(a >= 0 && b >= 0, "两个 channel socket 创建成功");
  if (a < 0 || b < 0) return;

  int pa = Socket::get_udt_channel_port(a);
  int pb = Socket::get_udt_channel_port(b);
  CHECK(pa > 0 && pb > 0 && pa != pb, "两者各绑到不同端口");

  sockaddr_in sa_b = loopback((uint16_t)pb);
  sockaddr_in sa_a = loopback((uint16_t)pa);
  UDT::connect(a, (sockaddr*)&sa_b, sizeof(sa_b));
  UDT::connect(b, (sockaddr*)&sa_a, sizeof(sa_a));

  // 轮询直到双方都进入 CONNECTED
  bool ok = false;
  for (int i = 0; i < 100; ++i) {
    if (state_of(a) == CONNECTED && state_of(b) == CONNECTED) { ok = true; break; }
    std::this_thread::sleep_for(std::chrono::milliseconds(20));
  }
  CHECK(ok, ("双方 rendezvous 后均 CONNECTED, a=" + std::to_string(state_of(a)) +
             " b=" + std::to_string(state_of(b))).c_str());

  if (ok) {
    int eid = UDT::epoll_create();
    const char* msg = "rendezvous payload";
    int sent = send_with_wait(eid, a, msg, (int)std::strlen(msg), 3000);
    CHECK(sent == (int)std::strlen(msg), ("A 发送成功, got " + std::to_string(sent)).c_str());
    char buf[128] = {0};
    int r = recv_with_wait(eid, b, buf, sizeof(buf) - 1, 3000);
    CHECK(r == (int)std::strlen(msg) && std::string(buf, r > 0 ? r : 0) == msg,
          "B 收到 A 的数据（无需 accept）");
    // 谁先 connect 不影响结果
    CHECK(Socket::get_remote_udt_port(b) == pa, "B 看到的对端端口 == A 的本地端口");
    UDT::epoll_release(eid);
  }

  UDT::close(a);
  UDT::close(b);
}

int main() {
  test_options_applied();
  test_listen_connect_transfer();
  test_rendezvous();

  std::printf("\n%d passed, %d failed\n", g_pass, g_fail);
  return g_fail == 0 ? 0 : 1;
}
