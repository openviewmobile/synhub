// 打洞交换 —— 还原自 UdtRelayDaemon::GetRemoteServerAddress @0x2fa764
#pragma once

#include <netinet/in.h>

#include <cstdint>
#include <string>
#include <vector>

#include "libpunch/punch_server.h"

namespace libpunch {

struct PunchExchangeParams {
  uint16_t local_port = 0;          // 本地 UDP 端口（0 = 由内核分配）
  std::vector<IpPortPair> servers;  // echo/打洞服务器列表
  std::string qc_id;                // QuickConnect ID，作为命令载荷
  bool use_code1 = true;            // true → COMMAND_CODE=1，false → 2
  bool do_ttl_punch = false;        // 是否对候选地址做 TTL=3 敲门
  long timeout_ms = 5000;           // 总超时（原库取 this+0xc8）
};

struct PunchExchangeResult {
  sockaddr_in peer{};        // 发现的对端地址
  PunchError error = PunchError::Ok;
  int packets_sent = 0;      // 发给 echo 服务器的命令包数（便于测试/诊断）
  int knock_sent = 0;        // TTL 敲门包数
};

// 执行一次完整打洞交换。
//
// 流程（严格对齐反编译）：
//   1. create_udp_socket(local_port, blocking=true)
//   2. 构造 148 字节 command_t（code / qc_id 载荷 / option=1）
//   3. 若 do_ttl_punch：set_ip_ttl(fd,3) → 向 candidate 发空包（最多 3 次）
//      → set_ip_ttl(fd,64)
//   4. 向 servers 中每个地址各发一份 148 字节命令
//   5. 循环 recvfrom，期望恰好 148 字节且 reply.code 回显一致；
//      响应载荷 payload[0:4] = 对端 IPv4，payload[4:6] = 对端端口（均网络序）
//      EINTR 重试；剩余时间驱动 SO_RCVTIMEO；耗尽返回 Timeout(11)
//
// candidate 可为 nullptr（无候选地址，此时不应启用 do_ttl_punch）。
PunchExchangeResult get_remote_server_address(const sockaddr_in* candidate,
                                              const PunchExchangeParams& params);

}  // namespace libpunch
