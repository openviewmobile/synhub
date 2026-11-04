// LibPunch::Socket —— 由 libsynoholepunch.so 反编译重建
// 原库 26 个原语全部覆盖。UDT 相关部分见 udt_transport.h（基于开源 udt4）。
#pragma once

#include <cstddef>
#include <cstdint>
#include <string>

#ifdef _WIN32
#error "libpunch 仅支持 POSIX"
#endif

#include <netinet/in.h>

namespace libpunch {

class Socket {
 public:
  // ------------------------------------------------ UDP
  // socket(AF_INET, SOCK_DGRAM) + SO_REUSEADDR + bind(INADDR_ANY, port)
  // blocking=false 时置 O_NONBLOCK。失败返回 -1。
  // 原库: Socket::create_udp_socket(int, bool)
  static int create_udp_socket(int port, bool blocking);

  // 原库: Socket::set_reuseaddr(int) —— 成功 0，失败 -1
  static int set_reuseaddr(int fd);

  // 原库: Socket::get_unused_udp_port() —— bind(0) 后 getsockname，随即关闭
  static int get_unused_udp_port();

  // 原库: Socket::get_socket_port(int) —— getsockname 的 sin_port（主机序）
  static int get_socket_port(int fd);

  // ------------------------------------------------ TCP
  // socket(AF_INET, SOCK_STREAM) + O_NONBLOCK
  // 原库: Socket::create_tcp_socket()
  static int create_tcp_socket();

  // TCP + SO_REUSEADDR + O_NONBLOCK + bind(addr|INADDR_ANY, port) + listen(64)
  // 原库: Socket::create_tcp_listen_socket(int, std::string)
  static int create_tcp_listen_socket(int port, const std::string& addr);

  // ------------------------------------------------ RAW / ICMP
  // socket(AF_INET, SOCK_RAW, IPPROTO_RAW) + IP_HDRINCL + O_NONBLOCK
  // 原库: Socket::create_icmp_raw_socket()
  static int create_icmp_raw_socket();

  // socket(AF_INET, SOCK_RAW, IPPROTO_ICMP) + O_NONBLOCK
  // 原库: Socket::create_icmp_listen_socket()
  static int create_icmp_listen_socket();

  // socket(AF_INET, SOCK_RAW, IPPROTO_UDP) + IP_HDRINCL + O_NONBLOCK
  // 原库: Socket::create_udp_raw_socket()
  static int create_udp_raw_socket();

  // setsockopt(IPPROTO_IP, IP_HDRINCL, 1) —— 成功 0，失败 -1
  // 原库: Socket::set_hdrincl(int)
  static int set_hdrincl(int fd);

  // ------------------------------------------------ 通用
  // 原库: Socket::close_socket(int)
  static void close_socket(int fd);

  // O_NONBLOCK 置位/清除 —— 成功 0，失败 -1
  // 原库: Socket::set_blocking(int, bool)
  static int set_blocking(int fd, bool blocking);

  // 原库: Socket::set_nosignal(int) —— 恒返回 -1；Linux 上用 MSG_NOSIGNAL 代替
  // 解析 `host`（IPv4 字面量或域名）到 in_addr。域名走 getaddrinfo。
  // 返回 false 表示解析失败。
  static bool resolve_ipv4(const std::string& host, struct in_addr* out);

  static int set_nosignal(int fd);

  // setsockopt(SOL_SOCKET, SO_RCVTIMEO, {ms/1000, (ms%1000)*1000})
  // 原库: Socket::set_recv_timeout(int, long)
  static int set_recv_timeout(int fd, long ms);

  // setsockopt(IPPROTO_IP, IP_TTL, ttl) —— 打洞时用 TTL=3
  // 原库: Socket::set_ip_ttl(int, int)
  static int set_ip_ttl(int fd, int ttl);

  // recvfrom(fd, buf, len, flags, NULL, NULL)
  // 原库: Socket::my_recv(int, char*, long, int)
  static int my_recv(int fd, char* buf, long len, int flags);

  // sendto(fd, buf, len, flags | MSG_NOSIGNAL, NULL, 0)
  // 原库: Socket::my_send(int, char*, long, int)
  static int my_send(int fd, const char* buf, long len, int flags);

  // ------------------------------------------------ 地址与校验和
  // 清零 16 字节，sin_family=family，sin_port=htons(port)，
  // sin_addr = ip ? inet_addr(ip) : INADDR_ANY
  // 原库: Socket::initial_sockaddr(sockaddr_in*, unsigned short, unsigned short, char const*)
  static void initial_sockaddr(sockaddr_in* out, uint16_t family, uint16_t port, const char* ip);

  // UDP 伪首部校验和。src_ip/dst_ip 为主机序 IPv4。
  // 原库: Socket::udp_checksum(void const*, unsigned long, unsigned int, unsigned int)
  static uint32_t udp_checksum(const void* data, size_t len, uint32_t src_ip, uint32_t dst_ip);

  // IP 首部校验和（标准 16 位反码和取反）
  // 原库: Socket::ip_checksum(char const*, unsigned int)
  static uint32_t ip_checksum(const void* data, uint32_t len);

  // ------------------------------------------------ UDT（见 udt_socket.cpp，依赖 third_party/udt4）
  // 全部返回 int —— udt4 的 UDTSOCKET 就是 int，失败返回 -1 (UDT::INVALID_SOCK)
  //
  // 三者的公共选项（数值来自反编译）：
  //   UDT_SNDSYN(1)=0、UDT_RCVSYN(2)=0、UDT_MSS(0)=1500、
  //   UDP_SNDBUF(8)=96000、UDP_RCVBUF(9)=96000、
  //   UDT_SNDBUF(5)=192000、UDT_RCVBUF(6)=192000
  //
  // 客户端：不 bind。原库: Socket::create_udt_client_socket()
  static int create_udt_client_socket();

  // 监听：额外 bind(port) + listen(64)。原库: Socket::create_udt_listen_socket(int)
  static int create_udt_listen_socket(int port);

  // 打洞通道：额外 UDT_RENDEZVOUS(12)=1 + bind(port)（双方同时 connect）。
  // 原库: Socket::create_udt_channel_socket(int)
  static int create_udt_channel_socket(int port);

  // UDT::getsockname 的端口（主机序），失败 -1
  // 原库: Socket::get_udt_channel_port(int)
  static int get_udt_channel_port(int fd);

  // UDT::getpeername 的地址，返回主机序 IPv4；失败 0
  // 原库: Socket::get_remote_udt_ip(int)
  static uint32_t get_remote_udt_ip(int fd);

  // UDT::getpeername 的端口（主机序）；失败 0
  // 原库: Socket::get_remote_udt_port(int)
  static uint16_t get_remote_udt_port(int fd);
};

}  // namespace libpunch
