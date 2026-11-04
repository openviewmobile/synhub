// echo list 发现 + JSON 解析验证
#include "libpunch/json.h"
#include "libpunch/punch_server.h"

#include <cstdio>
#include <string>

using namespace libpunch;

static int g_fail = 0, g_pass = 0;

#define CHECK(cond, msg)                                                    \
  do {                                                                      \
    if (cond) { ++g_pass; }                                                 \
    else { ++g_fail; std::printf("  FAIL: %s (%s:%d)\n", msg, __FILE__, __LINE__); } \
  } while (0)

static std::string escape(const std::string& s) {
  std::string o;
  for (char c : s) {
    if (c == '\n') o += "\\n";
    else if (c == '\t') o += "\\t";
    else o += c;
  }
  return o;
}

// ---------------------------------------------------------------- 请求体
// 逐字节对齐原库 ostringstream 的输出
static void test_request_body() {
  std::printf("[echo_list] 请求体逐字节\n");
  const std::string got = build_echo_list_request();
  const std::string want = "{\n\"version\":\"1\",\n\"command\":\"get_echo_list\"\n}\n";
  CHECK(got == want, ("请求体不匹配, got: \"" + escape(got) + "\"").c_str());

  // 4 行 + 结尾换行
  size_t nl = 0;
  for (char c : got) if (c == '\n') ++nl;
  CHECK(nl == 4, "共 4 个换行（每行一个，含结尾）");
  CHECK(got.front() == '{' && got[got.size() - 2] == '}', "以 { 开头，末尾换行前是 }");
}

static void test_urls() {
  std::printf("[echo_list] URL 选择\n");
  CHECK(punch_server_url(kGlobalServerWw) == "https://global.quickconnect.to/Serv.php",
        "WW → global.quickconnect.to");
  CHECK(punch_server_url(kGlobalServerCn) == "https://global.quickconnect.cn/Serv.php",
        "CN → global.quickconnect.cn");
  CHECK(punch_server_url(99) == "https://global.quickconnect.to/Serv.php",
        "未知区域回退到 WW");
}

// ---------------------------------------------------------------- 响应
static void test_response_ok() {
  std::printf("[echo_list] 正常响应\n");
  const char* body =
      "{\"errno\":0,\"sites\":[\"203.0.113.10\",\"203.0.113.11\"],"
      "\"port\":1234,\"udt_tx_mss\":1400}";
  EchoListResult r;
  CHECK(parse_echo_list_response(body, r), "解析成功");
  CHECK(r.error == PunchError::Ok, "error == Ok");
  CHECK(r.errno_code == 0, "errno == 0");
  CHECK(r.sites.size() == 2, "2 个站点");
  CHECK(r.sites[0].ip == "203.0.113.10", "站点 0 IP");
  CHECK(r.sites[1].ip == "203.0.113.11", "站点 1 IP");
  CHECK(r.sites[0].port == 1234 && r.sites[1].port == 1234, "所有站点用同一个 port");
  CHECK(r.udt_tx_mss == 1400, "udt_tx_mss 生效");
}

static void test_response_edge() {
  std::printf("[echo_list] 边界与错误\n");
  EchoListResult r;

  // 无 udt_tx_mss → 保持 0
  CHECK(parse_echo_list_response(
            "{\"errno\":0,\"sites\":[\"1.2.3.4\"],\"port\":80}", r), "无 mss 可解析");
  CHECK(r.udt_tx_mss == 0, "udt_tx_mss 默认 0");

  // udt_tx_mss <= 0 → 不生效（原库 0 < iVar8 判断）
  CHECK(parse_echo_list_response(
            "{\"errno\":0,\"sites\":[],\"port\":80,\"udt_tx_mss\":-5}", r), "负 mss 可解析");
  CHECK(r.udt_tx_mss == 0, "负 mss 被忽略");
  CHECK(parse_echo_list_response(
            "{\"errno\":0,\"sites\":[],\"port\":80,\"udt_tx_mss\":0}", r), "零 mss 可解析");
  CHECK(r.udt_tx_mss == 0, "零 mss 被忽略");

  // errno != 0 → 失败
  CHECK(!parse_echo_list_response("{\"errno\":5,\"sites\":[],\"port\":80}", r), "errno=5 失败");
  CHECK(r.errno_code == 5, "errno_code 记录为 5");

  // 缺字段
  CHECK(!parse_echo_list_response("{\"sites\":[],\"port\":80}", r), "缺 errno 失败");
  CHECK(!parse_echo_list_response("{\"errno\":0,\"port\":80}", r), "缺 sites 失败");
  CHECK(!parse_echo_list_response("{\"errno\":0,\"sites\":[]}", r), "缺 port 失败");
  CHECK(!parse_echo_list_response("{\"errno\":\"0\",\"sites\":[],\"port\":80}", r),
        "errno 是字符串 → 失败");
  CHECK(!parse_echo_list_response("{\"errno\":0,\"sites\":{},\"port\":80}", r),
        "sites 是对象 → 失败");
  CHECK(!parse_echo_list_response("not json at all", r), "非 JSON 失败");
  CHECK(!parse_echo_list_response("", r), "空串失败");

  // sites 里非字符串元素被跳过（原库 isString 判断）
  CHECK(parse_echo_list_response(
            "{\"errno\":0,\"sites\":[\"1.2.3.4\",123,null,\"5.6.7.8\"],\"port\":9}", r),
        "混合类型 sites 可解析");
  CHECK(r.sites.size() == 2, "只取字符串元素");
  CHECK(r.sites[0].ip == "1.2.3.4" && r.sites[1].ip == "5.6.7.8", "字符串元素保序");

  // 空 sites
  CHECK(parse_echo_list_response("{\"errno\":0,\"sites\":[],\"port\":9}", r), "空 sites 可解析");
  CHECK(r.sites.empty(), "结果为空");
}

// 真实响应更容易带额外字段/嵌套，验证解析器不因此崩
static void test_response_realistic() {
  std::printf("[echo_list] 带额外字段的真实形状\n");
  const char* body = R"({
  "errno": 0,
  "sites": ["203.0.113.10", "203.0.113.11", "198.51.100.7"],
  "port": 63520,
  "udt_tx_mss": 1200,
  "extra": {"nested": [1, 2, {"deep": true}]},
  "unicode": "测试\u00e9"
})";
  EchoListResult r;
  CHECK(parse_echo_list_response(body, r), "带额外字段仍可解析");
  CHECK(r.sites.size() == 3, "3 个站点");
  CHECK(r.sites[2].ip == "198.51.100.7", "第 3 个站点");
  CHECK(r.sites[0].port == 63520, "端口 63520");
  CHECK(r.udt_tx_mss == 1200, "mss 1200");
}

// ---------------------------------------------------------------- JSON 解析器
static void test_json_parser() {
  std::printf("[json] 解析器\n");
  json::Value v;

  CHECK(json::parse("null", v) && v.isNull(), "null");
  CHECK(json::parse("true", v) && v.isBool() && v.asBool(), "true");
  CHECK(json::parse("false", v) && v.isBool() && !v.asBool(), "false");
  CHECK(json::parse("42", v) && v.asInt() == 42, "42");
  CHECK(json::parse("-7", v) && v.asInt() == -7, "负数");
  CHECK(json::parse("3.5", v) && v.asDouble() == 3.5, "小数");
  CHECK(json::parse("\"hi\"", v) && v.asString() == "hi", "字符串");
  CHECK(json::parse("\"a\\nb\"", v) && v.asString() == "a\nb", "转义 \\n");
  CHECK(json::parse("[1,2,3]", v) && v.size() == 3 && v[1].asInt() == 2, "数组");
  CHECK(json::parse("{\"a\":1}", v) && v["a"].asInt() == 1, "对象");
  CHECK(json::parse("  {  }  ", v) && v.isObject() && v.size() == 0, "空白容忍");
  CHECK(json::parse("[]", v) && v.isArray() && v.size() == 0, "空数组");
  CHECK(json::parse("{\"a\":{\"b\":[true,null]}}", v) && v["a"]["b"][0].asBool(), "嵌套");

  // 不存在的键返回 Null 单例
  CHECK(json::parse("{}", v) && v["nope"].isNull(), "缺键 → Null");
  CHECK(v[0].isNull(), "非数组下标 → Null");

  // 非法输入
  CHECK(!json::parse("{", v), "未闭合对象");
  CHECK(!json::parse("[1,", v), "未闭合数组");
  CHECK(!json::parse("\"abc", v), "未闭合字符串");
  CHECK(!json::parse("{\"a\"1}", v), "缺冒号");
  CHECK(!json::parse("", v), "空输入");
  CHECK(!json::parse("{\"a\":1}x", v), "尾部多余字符");
  CHECK(!json::parse("nul", v), "残缺字面量");
}

// ---------------------------------------------------------------- IpPortPair 布局
static void test_ipportpair_layout() {
  std::printf("[echo_list] IpPortPair 字段语义\n");
  IpPortPair p;
  p.ip = "203.0.113.10";
  p.port = 63520;
  CHECK(p.ip == "203.0.113.10" && p.port == 63520, "字段可独立设置");
}

int main() {
  test_request_body();
  test_urls();
  test_response_ok();
  test_response_edge();
  test_response_realistic();
  test_json_parser();
  test_ipportpair_layout();

  std::printf("\n%d passed, %d failed\n", g_pass, g_fail);
  return g_fail == 0 ? 0 : 1;
}
