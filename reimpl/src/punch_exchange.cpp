// 打洞交换实现 —— 反编译重建
#include "libpunch/punch_exchange.h"

#include <arpa/inet.h>
#include <errno.h>
#include <netinet/in.h>
#include <sys/socket.h>
#include <sys/time.h>

#include <cstdio>
#include <cstdlib>

// LIBPUNCH_DEBUG=1 时把打洞过程打到 stderr，便于排查"卡在哪一步"
namespace {
inline bool dbg_on() {
  static const bool on = ::getenv("LIBPUNCH_DEBUG") != nullptr;
  return on;
}
#define LP_DBG(...) do { if (dbg_on()) { std::fprintf(stderr, "[punch] " __VA_ARGS__); std::fprintf(stderr, "\n"); } } while (0)
}  // namespace
#include <unistd.h>

#include <cstring>

#include "libpunch/protocol.h"
#include "libpunch/socket.h"

namespace libpunch {
namespace {

// TTL 敲门时用的计数上限（原库：首次失败再试，最多 3 次）
constexpr int kKnockAttempts = 3;
constexpr int kTtlPunch = 3;
constexpr int kTtlRestore = 64;

inline long elapsed_ms(const timeval& start, const timeval& now) {
  return (now.tv_usec - start.tv_usec) / 1000 + (now.tv_sec - start.tv_sec) * 1000;
}

// 从响应载荷取对端地址：payload[0:4] = IPv4，payload[4:6] = 端口（均网络序，直接拷贝）
inline void extract_peer(const command_t& reply, sockaddr_in* out) {
  std::memset(out, 0, sizeof(*out));
  out->sin_family = AF_INET;
  std::memcpy(&out->sin_addr, reply.payload + 0, 4);
  std::memcpy(&out->sin_port, reply.payload + 4, 2);
}

}  // namespace

PunchExchangeResult get_remote_server_address(const sockaddr_in* candidate,
                                              const PunchExchangeParams& params) {
  PunchExchangeResult result;
  result.error = PunchError::EarlyExit;

  if (params.servers.empty()) return result;

  const uint32_t code_host =
      (uint32_t)(params.use_code1 ? CommandCode::PunchPrimary : CommandCode::PunchSecondary);

  // 构造 148 字节命令
  command_t cmd;
  if (!CommandHandler::set(cmd, (CommandCode)code_host, params.qc_id.data(),
                           (int)params.qc_id.size(), CommandOption::WithPayload)) {
    return result;
  }

  // 1. 建 UDP 套接字（阻塞；超时靠 SO_RCVTIMEO 驱动）
  int fd = Socket::create_udp_socket(params.local_port, /*blocking=*/true);
  if (fd < 0) {
    result.error = PunchError::SocketCreate;   // 2
    return result;
  }

  struct FdGuard {
    int fd;
    ~FdGuard() { Socket::close_socket(fd); }
  } guard{fd};

  // 2. TTL=3 敲门：让沿途 NAT 先建立映射，包不会真正送达对端
  if (params.do_ttl_punch && candidate != nullptr) {
    Socket::set_ip_ttl(fd, kTtlPunch);
    // 发 0 字节数据报（原库传 NULL，语义相同；这里传有效指针以满足 bionic 的
    // __nonnull 标注，线上字节完全一致）
    uint8_t dummy = 0;
    for (int i = 0; i < kKnockAttempts; ++i) {
      ssize_t n = ::sendto(fd, &dummy, 0, 0, reinterpret_cast<const sockaddr*>(candidate),
                           sizeof(sockaddr_in));
      ++result.knock_sent;
      if (n >= 0) break;   // 成功即停
    }
    Socket::set_ip_ttl(fd, kTtlRestore);       // 恢复默认 TTL=64
  }

  // 3. 向所有 echo 服务器各发一份命令
  for (const IpPortPair& s : params.servers) {
    sockaddr_in dst;
    std::memset(&dst, 0, sizeof(dst));
    dst.sin_family = AF_INET;
    dst.sin_port = htons(s.port);
    dst.sin_addr.s_addr = ::inet_addr(s.ip.c_str());
    ::sendto(fd, &cmd, sizeof(cmd), 0, reinterpret_cast<sockaddr*>(&dst), sizeof(dst));
    ++result.packets_sent;
    LP_DBG("→ echo %s:%u 发了 %zu 字节", s.ip.c_str(), (unsigned)s.port, sizeof(cmd));
  }

  // 4. 收循环
  timeval start;
  ::gettimeofday(&start, nullptr);

  for (;;) {
    timeval now;
    ::gettimeofday(&now, nullptr);
    long remaining = params.timeout_ms - elapsed_ms(start, now);
    if (remaining <= 0) {
      result.error = PunchError::Timeout;      // 11
      return result;
    }

    Socket::set_recv_timeout(fd, remaining);

    command_t reply;
    std::memset(&reply, 0, sizeof(reply));
    sockaddr_in from;
    LP_DBG("等待回应，剩余 %ld ms", remaining);
    socklen_t fromlen = sizeof(from);
    ssize_t n = ::recvfrom(fd, &reply, sizeof(reply), 0, reinterpret_cast<sockaddr*>(&from),
                           &fromlen);

    if (n < 0) {
      if (errno == EINTR) continue;            // 原库: errno == 4 重试
      LP_DBG("recvfrom 失败 errno=%d (%s)", errno, errno == EAGAIN ? "超时" : "其他");
      result.error = PunchError::RecvFailed;   // 6
      return result;
    }
    LP_DBG("← 收到 %zd 字节 来自 %s", n, ::inet_ntoa(from.sin_addr));
    if (n != (ssize_t)sizeof(reply)) continue; // 长度不符 → 继续等

    if (!CommandHandler::get(reply)) { LP_DBG("校验和不过，忽略"); continue; }
    if (reply.code != code_host) {
      LP_DBG("命令码不符: 期望 0x%x 得到 0x%x", code_host, reply.code);
      continue;
    }

    extract_peer(reply, &result.peer);
    result.error = PunchError::Ok;
    return result;
  }
}

}  // namespace libpunch
