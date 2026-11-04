// LibPunch::Socket 的 UDT 原语 —— 基于开源 udt4（third_party/udt4，BSD-3-Clause）
// 选项数值与调用序列逐条对齐 libsynoholepunch.so 的反编译结果。
#include <arpa/inet.h>
#include <netinet/in.h>
#include <sys/socket.h>

#include <cstring>

#include "libpunch/socket.h"
#include "udt.h"

namespace libpunch {
namespace {

// 反编译中出现的调优常量
constexpr int kUdtMss = 1500;            // 0x5dc
constexpr int kUdpSndBuf = 96000;        // 0x17700
constexpr int kUdpRcvBuf = 96000;
constexpr int kUdtSndBuf = 192000;       // 0x2ee00
constexpr int kUdtRcvBuf = 192000;
constexpr int kListenBacklog = 0x40;     // 64

// 三个 create_* 共用的选项序列：SNDSYN / RCVSYN 置为非阻塞，其余为缓冲区调优
bool apply_common_options(int s) {
  char nonblocking = 0;
  int mss = kUdtMss;
  int udp_snd = kUdpSndBuf;
  int udp_rcv = kUdpRcvBuf;
  int udt_snd = kUdtSndBuf;
  int udt_rcv = kUdtRcvBuf;

  if (UDT::setsockopt(s, 0, UDT_SNDSYN, &nonblocking, 1) == UDT::ERROR) return false;
  if (UDT::setsockopt(s, 0, UDT_RCVSYN, &nonblocking, 1) == UDT::ERROR) return false;
  if (UDT::setsockopt(s, 0, UDT_MSS, &mss, 4) == UDT::ERROR) return false;
  if (UDT::setsockopt(s, 0, UDP_SNDBUF, &udp_snd, 4) == UDT::ERROR) return false;
  if (UDT::setsockopt(s, 0, UDP_RCVBUF, &udp_rcv, 4) == UDT::ERROR) return false;
  if (UDT::setsockopt(s, 0, UDT_SNDBUF, &udt_snd, 4) == UDT::ERROR) return false;
  if (UDT::setsockopt(s, 0, UDT_RCVBUF, &udt_rcv, 4) == UDT::ERROR) return false;
  return true;
}

void fill_addr(sockaddr* out, int port) {
  std::memset(out, 0, sizeof(sockaddr_in));
  sockaddr_in* sa = reinterpret_cast<sockaddr_in*>(out);
  sa->sin_family = AF_INET;
  sa->sin_port = htons((uint16_t)port);
  sa->sin_addr.s_addr = htonl(INADDR_ANY);
}

}  // namespace

int Socket::create_udt_client_socket() {
  UDTSOCKET s = UDT::socket(AF_INET, SOCK_STREAM, 0);
  if (s == UDT::INVALID_SOCK) return -1;
  if (!apply_common_options(s)) {   // 不 bind
    UDT::close(s);
    return -1;
  }
  return (int)s;
}

int Socket::create_udt_listen_socket(int port) {
  UDTSOCKET s = UDT::socket(AF_INET, SOCK_STREAM, 0);
  if (s == UDT::INVALID_SOCK) return -1;

  sockaddr sa;
  fill_addr(&sa, port);

  if (!apply_common_options(s) ||
      UDT::bind(s, &sa, sizeof(sockaddr_in)) == UDT::ERROR ||
      UDT::listen(s, kListenBacklog) == UDT::ERROR) {
    UDT::close(s);
    return -1;
  }
  return (int)s;
}

int Socket::create_udt_channel_socket(int port) {
  UDTSOCKET s = UDT::socket(AF_INET, SOCK_STREAM, 0);
  if (s == UDT::INVALID_SOCK) return -1;

  char rendezvous = 1;
  char nonblocking = 0;   // 原库 local_4c[0] = 0，用于 SNDSYN / RCVSYN
  sockaddr sa;
  fill_addr(&sa, port);

  // 顺序对齐原库：SNDSYN(0)、RCVSYN(0)、RENDEZVOUS(1)，再是缓冲区选项，最后 bind
  if (UDT::setsockopt(s, 0, UDT_SNDSYN, &nonblocking, 1) == UDT::ERROR ||
      UDT::setsockopt(s, 0, UDT_RCVSYN, &nonblocking, 1) == UDT::ERROR ||
      UDT::setsockopt(s, 0, UDT_RENDEZVOUS, &rendezvous, 1) == UDT::ERROR) {
    UDT::close(s);
    return -1;
  }

  int mss = kUdtMss, udp_snd = kUdpSndBuf, udp_rcv = kUdpRcvBuf;
  int udt_snd = kUdtSndBuf, udt_rcv = kUdtRcvBuf;
  if (UDT::setsockopt(s, 0, UDT_MSS, &mss, 4) == UDT::ERROR ||
      UDT::setsockopt(s, 0, UDP_SNDBUF, &udp_snd, 4) == UDT::ERROR ||
      UDT::setsockopt(s, 0, UDP_RCVBUF, &udp_rcv, 4) == UDT::ERROR ||
      UDT::setsockopt(s, 0, UDT_SNDBUF, &udt_snd, 4) == UDT::ERROR ||
      UDT::setsockopt(s, 0, UDT_RCVBUF, &udt_rcv, 4) == UDT::ERROR ||
      UDT::bind(s, &sa, sizeof(sockaddr_in)) == UDT::ERROR) {
    UDT::close(s);
    return -1;
  }
  return (int)s;
}

int Socket::get_udt_channel_port(int fd) {
  sockaddr sa;
  std::memset(&sa, 0, sizeof(sa));
  int len = sizeof(sockaddr_in);
  if (UDT::getsockname((UDTSOCKET)fd, &sa, &len) == UDT::ERROR) return -1;
  return (int)ntohs(reinterpret_cast<sockaddr_in*>(&sa)->sin_port);
}

uint32_t Socket::get_remote_udt_ip(int fd) {
  sockaddr sa;
  std::memset(&sa, 0, sizeof(sa));
  int len = sizeof(sockaddr_in);
  if (UDT::getpeername((UDTSOCKET)fd, &sa, &len) == UDT::ERROR) return 0;
  // 原库返回 bswap32(sin_addr) —— sockaddr 里是网络序，交换后即主机序
  return ntohl(reinterpret_cast<sockaddr_in*>(&sa)->sin_addr.s_addr);
}

uint16_t Socket::get_remote_udt_port(int fd) {
  sockaddr sa;
  std::memset(&sa, 0, sizeof(sa));
  int len = sizeof(sockaddr_in);
  if (UDT::getpeername((UDTSOCKET)fd, &sa, &len) == UDT::ERROR) return 0;
  return ntohs(reinterpret_cast<sockaddr_in*>(&sa)->sin_port);
}

}  // namespace libpunch
