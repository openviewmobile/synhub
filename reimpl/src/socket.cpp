// LibPunch::Socket —— 反编译重建实现
#include "libpunch/socket.h"

#include <arpa/inet.h>
#include <fcntl.h>
#include <netdb.h>
#include <netinet/in.h>
#include <netinet/ip.h>
#include <sys/socket.h>
#include <sys/types.h>
#include <unistd.h>

#include <cstring>

#ifndef MSG_NOSIGNAL
#define MSG_NOSIGNAL 0
#endif

namespace libpunch {
namespace {

// 原库用 *(ushort*) 直接读取，在 ARM64/x86（小端）上即主机序组装。
// 这里显式用 memcpy 避免非对齐访问 UB，语义与原库在 LE 平台一致。
inline uint16_t read_u16_host(const void* p) {
  uint16_t v;
  std::memcpy(&v, p, sizeof(v));
  return v;
}

inline uint16_t bswap16_u(uint32_t v) {
  return (uint16_t)(((v & 0xff00ff00u) >> 8) | ((v & 0x00ff00ffu) << 8));
}

// 16 位反码和折叠
inline uint32_t fold16(uint32_t sum) {
  while (sum >> 16) sum = (sum >> 16) + (sum & 0xffffu);
  return sum & 0xffffu;
}

inline int ret_errno(int rc) { return rc < 0 ? -1 : 0; }

}  // namespace

// ---------------------------------------------------------------- UDP
int Socket::create_udp_socket(int port, bool blocking) {
  int fd = ::socket(AF_INET, SOCK_DGRAM, 0);
  if (fd == -1) return -1;

  sockaddr_in addr;
  std::memset(&addr, 0, sizeof(addr));
  addr.sin_family = AF_INET;
  addr.sin_port = htons((uint16_t)port);
  addr.sin_addr.s_addr = htonl(INADDR_ANY);

  int one = 1;
  if (::setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &one, sizeof(one)) < 0 ||
      ::bind(fd, reinterpret_cast<sockaddr*>(&addr), sizeof(addr)) != 0 ||
      set_blocking(fd, blocking) < 0) {
    ::close(fd);
    return -1;
  }
  return fd;
}

int Socket::set_reuseaddr(int fd) {
  int one = 1;
  return ret_errno(::setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &one, sizeof(one)));
}

int Socket::get_unused_udp_port() {
  int fd = create_udp_socket(0, false);
  if (fd == -1) return -1;

  sockaddr_in addr;
  std::memset(&addr, 0, sizeof(addr));
  socklen_t len = sizeof(addr);
  int port = -1;
  if (::getsockname(fd, reinterpret_cast<sockaddr*>(&addr), &len) == 0) {
    port = (int)ntohs(addr.sin_port);
  }
  ::close(fd);
  return port;
}

int Socket::get_socket_port(int fd) {
  if (fd < 0) return -1;
  sockaddr_in addr;
  std::memset(&addr, 0, sizeof(addr));
  socklen_t len = sizeof(addr);
  if (::getsockname(fd, reinterpret_cast<sockaddr*>(&addr), &len) != 0) return -1;
  return (int)ntohs(addr.sin_port);
}

// ---------------------------------------------------------------- TCP
int Socket::create_tcp_socket() {
  int fd = ::socket(AF_INET, SOCK_STREAM, 0);
  if (fd == -1) return -1;
  if (set_blocking(fd, false) < 0) {   // 原库无条件置 O_NONBLOCK
    ::close(fd);
    return -1;
  }
  return fd;
}

int Socket::create_tcp_listen_socket(int port, const std::string& addr) {
  int fd = ::socket(AF_INET, SOCK_STREAM, 0);
  if (fd == -1) return -1;

  int one = 1;
  if (::setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &one, sizeof(one)) < 0 ||
      set_blocking(fd, false) < 0) {
    ::close(fd);
    return -1;
  }

  sockaddr_in sa;
  std::memset(&sa, 0, sizeof(sa));
  sa.sin_family = AF_INET;
  sa.sin_port = htons((uint16_t)port);
  sa.sin_addr.s_addr = addr.empty() ? htonl(INADDR_ANY) : ::inet_addr(addr.c_str());

  if (::bind(fd, reinterpret_cast<sockaddr*>(&sa), sizeof(sa)) < 0 ||
      ::listen(fd, 0x40) < 0) {
    ::close(fd);
    return -1;
  }
  return fd;
}

// ---------------------------------------------------------------- RAW / ICMP
int Socket::create_icmp_raw_socket() {
  int fd = ::socket(AF_INET, SOCK_RAW, IPPROTO_RAW);   // 原库: socket(2,3,0xff)
  if (fd == -1) return -1;
  if (set_hdrincl(fd) < 0 || set_blocking(fd, false) < 0) {
    ::close(fd);
    return -1;
  }
  return fd;
}

int Socket::create_icmp_listen_socket() {
  int fd = ::socket(AF_INET, SOCK_RAW, IPPROTO_ICMP);  // 原库: socket(2,3,1)
  if (fd == -1) return -1;
  if (set_blocking(fd, false) < 0) {
    ::close(fd);
    return -1;
  }
  return fd;
}

int Socket::create_udp_raw_socket() {
  int fd = ::socket(AF_INET, SOCK_RAW, IPPROTO_UDP);   // 原库: socket(2,3,0x11)
  if (fd == -1) return -1;
  if (set_hdrincl(fd) < 0 || set_blocking(fd, false) < 0) {
    ::close(fd);
    return -1;
  }
  return fd;
}

int Socket::set_hdrincl(int fd) {
  int one = 1;
  return ret_errno(::setsockopt(fd, IPPROTO_IP, IP_HDRINCL, &one, sizeof(one)));
}

// ---------------------------------------------------------------- 通用
void Socket::close_socket(int fd) { ::close(fd); }

int Socket::set_blocking(int fd, bool blocking) {
  int flags = ::fcntl(fd, F_GETFL, 0);
  if (flags < 0) return -1;
  if (blocking) {
    flags &= ~O_NONBLOCK;
  } else {
    flags |= O_NONBLOCK;
  }
  return ret_errno(::fcntl(fd, F_SETFL, flags));
}

// 原库恒返回 -1（Linux/Android 上无 SO_NOSIGPIPE，改用 sendto 的 MSG_NOSIGNAL）
bool Socket::resolve_ipv4(const std::string& host, struct in_addr* out) {
  if (out == nullptr || host.empty()) return false;

  // 先按字面量解析，省掉一次 DNS —— 绝大多数场景是 IP
  if (::inet_pton(AF_INET, host.c_str(), out) == 1) return true;

  struct addrinfo hints{};
  hints.ai_family = AF_INET;
  hints.ai_socktype = SOCK_STREAM;
  struct addrinfo* res = nullptr;
  if (::getaddrinfo(host.c_str(), nullptr, &hints, &res) != 0 || res == nullptr) {
    return false;
  }
  bool ok = false;
  for (struct addrinfo* p = res; p != nullptr; p = p->ai_next) {
    if (p->ai_family == AF_INET && p->ai_addr != nullptr) {
      *out = reinterpret_cast<sockaddr_in*>(p->ai_addr)->sin_addr;
      ok = true;
      break;
    }
  }
  ::freeaddrinfo(res);
  return ok;
}

int Socket::set_nosignal(int fd) {
  (void)fd;
  return -1;
}

int Socket::set_recv_timeout(int fd, long ms) {
  struct timeval tv;
  tv.tv_sec = ms / 1000;
  tv.tv_usec = (ms % 1000) * 1000;
  return ret_errno(::setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof(tv)));
}

int Socket::set_ip_ttl(int fd, int ttl) {
  int v = ttl;
  return ret_errno(::setsockopt(fd, IPPROTO_IP, IP_TTL, &v, sizeof(v)));
}

int Socket::my_recv(int fd, char* buf, long len, int flags) {
  return (int)::recvfrom(fd, buf, (size_t)len, flags, nullptr, nullptr);
}

int Socket::my_send(int fd, const char* buf, long len, int flags) {
  return (int)::sendto(fd, buf, (size_t)len, flags | MSG_NOSIGNAL, nullptr, 0);
}

// ---------------------------------------------------------------- 地址与校验和
void Socket::initial_sockaddr(sockaddr_in* out, uint16_t family, uint16_t port, const char* ip) {
  std::memset(out, 0, sizeof(sockaddr_in));
  out->sin_family = family;
  out->sin_port = htons(port);
  out->sin_addr.s_addr = (ip == nullptr) ? htonl(INADDR_ANY) : ::inet_addr(ip);
}

uint32_t Socket::ip_checksum(const void* data, uint32_t len) {
  const uint8_t* p = static_cast<const uint8_t*>(data);
  uint32_t sum = 0;
  uint32_t i = 0;
  for (; i + 1 < len; i += 2) sum += read_u16_host(p + i);
  if (len & 1) sum += p[len - 1];   // 原库把末字节按低字节累加（小端序组装）
  return (uint32_t)(~fold16(sum) & 0xffffu);
}

uint32_t Socket::udp_checksum(const void* data, size_t len, uint32_t src_ip, uint32_t dst_ip) {
  const uint8_t* p = static_cast<const uint8_t*>(data);
  uint32_t sum = 0;
  size_t i = 0;
  for (; i + 1 < len; i += 2) sum += read_u16_host(p + i);
  if (len & 1) sum += p[len - 1];

  // 伪首部：src/dst IP 的高低位 + 按网络序的 UDP 长度 + 协议号(17)<<8
  sum += (src_ip >> 16) + (src_ip & 0xffffu);
  sum += (dst_ip >> 16) + (dst_ip & 0xffffu);
  sum += bswap16_u((uint32_t)len);
  sum += 0x1100u;

  return (uint32_t)(~fold16(sum) & 0xffffu);
}

}  // namespace libpunch
