// LibPunch::Socket 验证 —— 在宿主机上真实建套接字跑
#include "libpunch/socket.h"

#include <arpa/inet.h>
#include <errno.h>
#include <fcntl.h>
#include <netinet/in.h>
#include <sys/socket.h>
#include <sys/time.h>
#include <unistd.h>

#include <cstdio>
#include <cstring>
#include <string>
#include <vector>

using namespace libpunch;

static int g_fail = 0, g_pass = 0, g_skip = 0;

#define CHECK(cond, msg)                                                    \
  do {                                                                      \
    if (cond) { ++g_pass; }                                                 \
    else { ++g_fail; std::printf("  FAIL: %s (%s:%d)\n", msg, __FILE__, __LINE__); } \
  } while (0)

#define SKIP(msg) do { ++g_skip; std::printf("  SKIP: %s\n", msg); } while (0)

static uint16_t bswap16r(uint16_t v) { return (uint16_t)((v >> 8) | (v << 8)); }

// 标准（RFC1071，大端序）IP 首部校验和，用作参照
static uint16_t std_ip_checksum(const uint8_t* p, size_t n) {
  uint32_t sum = 0;
  for (size_t i = 0; i + 1 < n; i += 2) sum += (uint32_t)((p[i] << 8) | p[i + 1]);
  if (n & 1) sum += (uint32_t)(p[n - 1] << 8);
  while (sum >> 16) sum = (sum >> 16) + (sum & 0xffff);
  return (uint16_t)~sum;
}

// ---------------------------------------------------------------- UDP
static void test_udp_primitives() {
  std::printf("[socket] UDP 建/绑/查端口\n");

  int fd = Socket::create_udp_socket(0, false);
  CHECK(fd >= 0, "create_udp_socket(0,false) 成功");
  if (fd < 0) return;

  int flags = fcntl(fd, F_GETFL, 0);
  CHECK((flags & O_NONBLOCK) != 0, "blocking=false 时置了 O_NONBLOCK");

  int port = Socket::get_socket_port(fd);
  CHECK(port > 0 && port < 65536, "get_socket_port 返回合法端口");

  Socket::close_socket(fd);

  int fd2 = Socket::create_udp_socket(0, true);
  CHECK(fd2 >= 0, "create_udp_socket(0,true) 成功");
  if (fd2 >= 0) {
    int f2 = fcntl(fd2, F_GETFL, 0);
    CHECK((f2 & O_NONBLOCK) == 0, "blocking=true 时未置 O_NONBLOCK");

    CHECK(Socket::set_blocking(fd2, false) == 0, "set_blocking(false) 返回 0");
    CHECK((fcntl(fd2, F_GETFL, 0) & O_NONBLOCK) != 0, "O_NONBLOCK 已置位");
    CHECK(Socket::set_blocking(fd2, true) == 0, "set_blocking(true) 返回 0");
    CHECK((fcntl(fd2, F_GETFL, 0) & O_NONBLOCK) == 0, "O_NONBLOCK 已清除");

    CHECK(Socket::set_reuseaddr(fd2) == 0, "set_reuseaddr 返回 0");
    CHECK(Socket::set_ip_ttl(fd2, 3) == 0, "set_ip_ttl(3) 成功（打洞用）");

    Socket::close_socket(fd2);
  }

  int p = Socket::get_unused_udp_port();
  CHECK(p > 0 && p < 65536, "get_unused_udp_port 返回合法端口");
}

// 真实收不到包时必须按 SO_RCVTIMEO 超时返回
static void test_recv_timeout() {
  std::printf("[socket] SO_RCVTIMEO 超时\n");
  // 必须是阻塞套接字，否则 O_NONBLOCK 会让 recvfrom 立刻返回 EAGAIN
  int fd = Socket::create_udp_socket(0, true);
  if (fd < 0) { CHECK(false, "建 socket"); return; }

  CHECK(Socket::set_recv_timeout(fd, 100) == 0, "set_recv_timeout(100ms) 返回 0");

  struct timeval t0, t1;
  gettimeofday(&t0, nullptr);
  char buf[64];
  int n = Socket::my_recv(fd, buf, sizeof(buf), 0);
  gettimeofday(&t1, nullptr);

  long elapsed_ms = (t1.tv_sec - t0.tv_sec) * 1000 + (t1.tv_usec - t0.tv_usec) / 1000;
  CHECK(n < 0, "无人发送时 my_recv 返回 -1");
  CHECK(errno == EAGAIN || errno == EWOULDBLOCK, "errno 为 EAGAIN/EWOULDBLOCK");
  CHECK(elapsed_ms >= 80 && elapsed_ms < 600, "超时约 100ms");

  Socket::close_socket(fd);
}

// ---------------------------------------------------------------- TCP
static void test_tcp_listen() {
  std::printf("[socket] TCP listen\n");

  int fd = Socket::create_tcp_listen_socket(0, "127.0.0.1");
  CHECK(fd >= 0, "create_tcp_listen_socket(0, 127.0.0.1) 成功");
  if (fd < 0) return;

  CHECK((fcntl(fd, F_GETFL, 0) & O_NONBLOCK) != 0, "监听套接字为非阻塞");

  int port = Socket::get_socket_port(fd);
  CHECK(port > 0, "监听端口合法");

  // 真的能连上（create_tcp_socket 忠实还原原库：非阻塞，故先转阻塞再 connect）
  int cli = Socket::create_tcp_socket();
  CHECK(cli >= 0, "create_tcp_socket 成功");
  if (cli >= 0) {
    CHECK(Socket::set_blocking(cli, true) == 0, "客户端转阻塞");
    sockaddr_in sa;
    Socket::initial_sockaddr(&sa, AF_INET, (uint16_t)port, "127.0.0.1");
    int rc = ::connect(cli, reinterpret_cast<sockaddr*>(&sa), sizeof(sa));
    CHECK(rc == 0, "connect 到监听端口成功");
    Socket::close_socket(cli);
  }
  Socket::close_socket(fd);
}

// ---------------------------------------------------------------- 地址与校验和
static void test_initial_sockaddr() {
  std::printf("[socket] initial_sockaddr\n");
  sockaddr_in sa;

  Socket::initial_sockaddr(&sa, AF_INET, 0x1234, "10.0.0.1");
  CHECK(sa.sin_family == AF_INET, "sin_family");
  CHECK(ntohs(sa.sin_port) == 0x1234, "sin_port");
  CHECK(sa.sin_addr.s_addr == inet_addr("10.0.0.1"), "sin_addr");

  Socket::initial_sockaddr(&sa, AF_INET, 0, nullptr);
  CHECK(sa.sin_addr.s_addr == htonl(INADDR_ANY), "ip=NULL → INADDR_ANY");
}

// 原库按小端序组装 16 位字，因此结果等于标准校验和的字节交换
static void test_ip_checksum() {
  std::printf("[socket] ip_checksum（小端序组装）\n");

  // RFC1071 示例 IP 首部
  const uint8_t hdr[20] = {0x45, 0x00, 0x00, 0x3c, 0x1c, 0x46, 0x40, 0x00, 0x40, 0x06,
                           0x00, 0x00, 0xac, 0x10, 0x0a, 0x63, 0xac, 0x10, 0x0a, 0x0c};
  uint16_t std = std_ip_checksum(hdr, sizeof(hdr));
  uint16_t mine = (uint16_t)Socket::ip_checksum(hdr, sizeof(hdr));

  CHECK(std == 0xb1e6, ("标准校验和应为 0xb1e6, got 0x" + std::to_string(std)).c_str());
  CHECK(mine == bswap16r(std), "本实现结果 == bswap16(标准校验和)");

  // 奇数长度也要确定
  const uint8_t odd[5] = {0x01, 0x02, 0x03, 0x04, 0x05};
  uint16_t a = (uint16_t)Socket::ip_checksum(odd, sizeof(odd));
  uint16_t b = (uint16_t)Socket::ip_checksum(odd, sizeof(odd));
  CHECK(a == b, "奇数长度结果稳定");

  // 校验和自洽：把结果填回校验和字段，再算一次应为 0（16 位反码和的固有性质）
  uint8_t buf[20];
  std::memcpy(buf, hdr, sizeof(buf));
  uint16_t c = (uint16_t)Socket::ip_checksum(buf, sizeof(buf));
  buf[10] = (uint8_t)(c & 0xff);
  buf[11] = (uint8_t)(c >> 8);
  CHECK((uint16_t)Socket::ip_checksum(buf, sizeof(buf)) == 0x0000,
        "填回校验和后重算 == 0");
}

static void test_udp_checksum() {
  std::printf("[socket] udp_checksum（手工验算）\n");

  // data=[0x12,0x34], len=2, src=10.0.0.1, dst=10.0.0.2
  // LE word       = 0x3412
  // src hi+lo     = 0x0a00 + 0x0001 = 0x0a01
  // dst hi+lo     = 0x0a00 + 0x0002 = 0x0a02
  // bswap16(2)    = 0x0200
  // proto<<8      = 0x1100
  // sum = 0x5b15  → ~sum = 0xa4ea
  const uint8_t data[2] = {0x12, 0x34};
  uint32_t c = Socket::udp_checksum(data, sizeof(data), 0x0a000001u, 0x0a000002u);
  CHECK(c == 0xa4eau, ("应为 0xa4ea, got 0x" + std::to_string(c)).c_str());

  // 全零载荷(4字节) + 零地址：
  // bswap16(4) = 0x0400, proto<<8 = 0x1100, 其余为 0 → sum = 0x1500 → ~sum = 0xeaff
  const uint8_t z[4] = {0, 0, 0, 0};
  uint32_t c2 = Socket::udp_checksum(z, sizeof(z), 0, 0);
  CHECK(c2 == 0xeaffu, ("应为 0xeaff, got 0x" + std::to_string(c2)).c_str());

  // 结果始终在 16 位内
  const uint8_t big[64] = {0xff};
  uint32_t c3 = Socket::udp_checksum(big, sizeof(big), 0xffffffffu, 0xffffffffu);
  CHECK(c3 <= 0xffffu, "结果在 16 位内");
}

// ---------------------------------------------------------------- raw socket
static void test_raw_sockets() {
  std::printf("[socket] raw socket（需 root）\n");
  if (geteuid() != 0) { SKIP("非 root，跳过 raw socket 测试"); return; }

  int a = Socket::create_icmp_raw_socket();
  CHECK(a >= 0, "create_icmp_raw_socket 成功");
  if (a >= 0) Socket::close_socket(a);

  int b = Socket::create_icmp_listen_socket();
  CHECK(b >= 0, "create_icmp_listen_socket 成功");
  if (b >= 0) Socket::close_socket(b);

  int c = Socket::create_udp_raw_socket();
  CHECK(c >= 0, "create_udp_raw_socket 成功");
  if (c >= 0) Socket::close_socket(c);
}

static void test_nosignal_is_stub() {
  std::printf("[socket] set_nosignal 是桩\n");
  CHECK(Socket::set_nosignal(0) == -1, "set_nosignal 恒返回 -1（与原库一致）");
}

int main() {
  test_udp_primitives();
  test_recv_timeout();
  test_tcp_listen();
  test_initial_sockaddr();
  test_ip_checksum();
  test_udp_checksum();
  test_raw_sockets();
  test_nosignal_is_stub();

  std::printf("\n%d passed, %d failed, %d skipped\n", g_pass, g_fail, g_skip);
  return g_fail == 0 ? 0 : 1;
}
