// HTTP(S) 客户端 —— 还原自 GetPunchServerListSSL 的 libcurl 用法
#pragma once

#include <string>

#include "libpunch/punch_server.h"

namespace libpunch {

struct HttpOptions {
  long timeout_ms = 3000;          // CURLOPT_TIMEOUT
  long connect_timeout_ms = 1000;  // CURLOPT_CONNECTTIMEOUT
  std::string ca_info;             // CURLOPT_CAINFO，空则用系统 CA 库
  bool verify_peer = true;         // CURLOPT_SSL_VERIFYPEER，原库恒为 1
};

// POST body 到 url，响应体写入 response_body。
// 返回值对齐原库写入 UdtRelayDaemon+0xc0 的错误码。
PunchError http_post(const std::string& url, const std::string& body,
                     const HttpOptions& opt, std::string& response_body);

// 完整流程：POST echo list 请求 → 解析响应。
// 解析失败时 out.error 为 BadResponse。
PunchError fetch_echo_list(int global_server_site, const HttpOptions& opt, EchoListResult& out);

}  // namespace libpunch
