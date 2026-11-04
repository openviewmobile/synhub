// 打洞服务器（echo list）发现 —— 反编译重建
#include "libpunch/punch_server.h"

#include "libpunch/json.h"

namespace libpunch {

std::string punch_server_url(int global_server_site) {
  return global_server_site == kGlobalServerCn
             ? "https://global.quickconnect.cn/Serv.php"
             : "https://global.quickconnect.to/Serv.php";
}

std::string build_echo_list_request() {
  // 逐行拼接，每行末尾 '\n'（含最后一行）—— 与原库 ostream << "{" << endl ... 一致
  std::string body;
  body += "{\n";
  body += "\"version\":\"1\",\n";
  body += "\"command\":\"get_echo_list\"\n";
  body += "}\n";
  return body;
}

bool parse_echo_list_response(const std::string& body, EchoListResult& out) {
  out.sites.clear();
  out.udt_tx_mss = 0;
  out.errno_code = -1;
  out.error = PunchError::BadResponse;

  json::Value root;
  if (!json::parse(body, root)) {
    out.error = PunchError::BadResponse;   // 原库: 解析失败 → 10
    return false;
  }

  // errno 必须存在且为整数
  const json::Value& errno_v = root["errno"];
  if (errno_v.isNull() || !errno_v.isNumber()) return false;

  out.errno_code = errno_v.asInt();
  if (out.errno_code != 0) return false;   // 原库: errno != 0 → 10

  const json::Value& sites_v = root["sites"];
  const json::Value& port_v = root["port"];
  if (!sites_v.isArray() || !port_v.isNumber()) return false;

  uint16_t port = (uint16_t)port_v.asInt();

  // udt_tx_mss 可选，仅当 > 0 时生效
  if (root.has("udt_tx_mss")) {
    int mss = root["udt_tx_mss"].asInt();
    if (mss > 0) out.udt_tx_mss = mss;
  }

  for (size_t i = 0; i < sites_v.size(); ++i) {
    const json::Value& item = sites_v[i];
    if (!item.isString()) continue;       // 原库 isString() 判断，非字符串跳过
    IpPortPair pair;
    pair.ip = item.asString();
    pair.port = port;
    out.sites.push_back(std::move(pair));
  }

  out.error = PunchError::Ok;
  return true;
}

}  // namespace libpunch
