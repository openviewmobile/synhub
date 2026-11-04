// 打洞服务器（echo list）发现 —— 还原自 UdtRelayDaemon::GetPunchServerListSSL
#pragma once

#include <cstdint>
#include <string>
#include <vector>

namespace libpunch {

// 对齐原库布局：libc++ std::string(24B) @0x00，uint16 port @0x18，整体 32 字节
struct IpPortPair {
  std::string ip;      // @0x00
  uint16_t port = 0;   // @0x18
};

// 原库写入 UdtRelayDaemon+0xc0 的错误码
enum class PunchError : int {
  Ok           = 0,
  EarlyExit    = 1,   // 入口早退（无服务器 / 计时已停）
  SocketCreate = 2,   // Socket::create_udp_socket 失败
  UdtConnect   = 4,   // UDT::connect 失败
  RecvFailed   = 6,   // recvfrom 失败（非 EINTR）
  CurlInit     = 8,   // curl_easy_init 或 setopt 失败
  CurlPerform  = 9,   // curl_easy_perform 失败
  BadResponse  = 10,  // JSON/字段校验失败
  Timeout      = 11,  // 剩余时间耗尽
};

struct EchoListResult {
  std::vector<IpPortPair> sites;
  int udt_tx_mss = 0;               // 0 表示服务器未提供
  int errno_code = -1;              // 响应里的 "errno"
  PunchError error = PunchError::Ok;
};

// ---------------------------------------------------------------- 常量
// 由 libsynoholepunch.so 的字符串表确认：
//   https://global.quickconnect.to/Serv.php   (GLOBAL_SERVER_WW = 0)
//   https://global.quickconnect.cn/Serv.php   (GLOBAL_SERVER_CN = 1)
constexpr int kGlobalServerWw = 0;
constexpr int kGlobalServerCn = 1;

std::string punch_server_url(int global_server_site);

// ---------------------------------------------------------------- 请求
// 原库用 ostringstream 拼出（每行一个 '\n'，结尾也有 '\n'）：
//   {
//   "version":"1",
//   "command":"get_echo_list"
//   }
std::string build_echo_list_request();

// ---------------------------------------------------------------- 响应
// 解析 Serv.php 的响应。
// 语义严格对齐原库：
//   - "errno" 必须存在且为整数，且 == 0，否则 BadResponse
//   - "sites" 必须为数组，"port" 必须为整数，否则 BadResponse
//   - "sites" 中非字符串元素被跳过（原库 isString() 判断）
//   - "udt_tx_mss" 存在且 > 0 时覆盖默认值
bool parse_echo_list_response(const std::string& body, EchoListResult& out);

}  // namespace libpunch
