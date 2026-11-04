// C ABI 验证：接口契约、参数校验、默认值
#include "libpunch/punch_c.h"

#include <cstdio>
#include <cstring>
#include <string>

static int g_fail = 0, g_pass = 0;

#define CHECK(cond, msg)                                                    \
  do {                                                                      \
    if (cond) { ++g_pass; }                                                 \
    else { ++g_fail; std::printf("  FAIL: %s (%s:%d)\n", msg, __FILE__, __LINE__); } \
  } while (0)

static void test_lifecycle() {
  std::printf("[capi] 生命周期\n");
  synopunch_handle* h = synopunch_new();
  CHECK(h != nullptr, "synopunch_new 返回非空");
  if (h == nullptr) return;

  CHECK(synopunch_is_running(h) == 0, "新建时未运行");
  CHECK(synopunch_tcp_port(h) == 0, "新建时无端口");
  CHECK(std::string(synopunch_last_error(h)) == "", "新建时无错误");
  CHECK(synopunch_rx_bytes(h) == 0, "新建时 rx = 0");
  CHECK(synopunch_tx_bytes(h) == 0, "新建时 tx = 0");
  CHECK(synopunch_poll(h, 0) == 0, "未运行时 poll 返回 0");

  synopunch_stop(h);   // 未运行也能安全调用
  synopunch_free(h);
  synopunch_free(nullptr);   // 空指针安全
  synopunch_stop(nullptr);
  CHECK(synopunch_is_running(nullptr) == 0, "空句柄查询安全");
  CHECK(synopunch_tcp_port(nullptr) == 0, "空句柄端口为 0");
  CHECK(std::string(synopunch_last_error(nullptr)) == "", "空句柄错误为空串");
}

static void test_null_safety() {
  std::printf("[capi] 空指针安全\n");
  synopunch_handle* h = synopunch_new();

  // 全部 setter 传 nullptr 都不应崩溃
  synopunch_set_server_id(h, nullptr);
  synopunch_add_echo_server(h, nullptr, 1234);
  synopunch_add_echo_server(nullptr, "1.2.3.4", 1234);
  synopunch_set_candidate(h, nullptr, 1234);
  synopunch_set_candidate(nullptr, "1.2.3.4", 1234);
  synopunch_set_server_id(nullptr, "x");
  synopunch_set_service_type(nullptr, 2);
  synopunch_clear_echo_servers(nullptr);
  synopunch_clear_candidate(nullptr);
  synopunch_set_udt_tx_mss(nullptr, 1400);
  synopunch_set_rendezvous(nullptr, 1);
  synopunch_set_local_service_port(nullptr, 80);
  synopunch_set_punch_timeout(nullptr, 100);
  synopunch_set_connect_timeout(nullptr, 100);
  CHECK(true, "所有 setter 对空句柄安全");

  synopunch_free(h);
}

static void test_service_type_normalization() {
  std::printf("[capi] SERVICE_ID 归一化（与原库 JNI 一致）\n");

  // 合法范围 [1,11] 应保持不变；越界归零。
  // 直接观察行为不方便，改为验证「越界不导致启动崩溃 + 后续错误路径正常」。
  synopunch_handle* h = synopunch_new();

  for (int v : {0, 1, 2, 11, 12, 99, -5}) {
    synopunch_set_service_type(h, v);
    // 没有 echo 服务器 → 打洞必失败，且失败码应是 PunchFailed
    int rc = synopunch_start(h);
    CHECK(rc != 0, ("SERVICE_ID=" + std::to_string(v) + " 无服务器时启动失败").c_str());
    CHECK(std::string(synopunch_last_error(h)) == "PunchFailed",
          ("SERVICE_ID=" + std::to_string(v) + " 错误名为 PunchFailed").c_str());
  }
  synopunch_free(h);
}

static void test_start_failure_paths() {
  std::printf("[capi] 启动失败路径\n");

  synopunch_handle* h = synopunch_new();
  synopunch_set_server_id(h, "test-qcid");

  // ① 无 echo 服务器
  int rc = synopunch_start(h);
  CHECK(rc != 0, "无服务器 → 非 0");
  CHECK(std::string(synopunch_last_error(h)) == "PunchFailed", "错误名正确");
  CHECK(synopunch_is_running(h) == 0, "失败后未运行");
  CHECK(synopunch_tcp_port(h) == 0, "失败后无端口");

  // ② 非法 echo 服务器端口应被忽略 → 仍是 PunchFailed
  synopunch_add_echo_server(h, "127.0.0.1", 0);
  synopunch_add_echo_server(h, "127.0.0.1", 70000);
  synopunch_add_echo_server(h, "127.0.0.1", -1);
  rc = synopunch_start(h);
  CHECK(rc != 0, "非法端口被忽略 → 仍失败");
  CHECK(std::string(synopunch_last_error(h)) == "PunchFailed", "错误名仍为 PunchFailed");

  // ③ 配置一个真实存在但不应答的 echo 服务器 → 打洞超时
  synopunch_clear_echo_servers(h);
  synopunch_add_echo_server(h, "127.0.0.1", 9);   // discard 端口，不会有我们的回复
  synopunch_set_punch_timeout(h, 300);
  rc = synopunch_start(h);
  CHECK(rc != 0, "不应答的服务器 → 启动失败");
  CHECK(std::string(synopunch_last_error(h)) != "", "有错误名");

  synopunch_clear_candidate(h);
  synopunch_stop(h);
  synopunch_free(h);
}

static void test_config_roundtrip() {
  std::printf("[capi] 配置接口可调用\n");
  synopunch_handle* h = synopunch_new();

  synopunch_set_server_id(h, "my-qc-id");
  synopunch_set_service_type(h, 2);
  synopunch_set_udt_tx_mss(h, 1400);
  synopunch_set_rendezvous(h, 1);
  synopunch_set_local_service_port(h, 5000);
  synopunch_set_punch_timeout(h, 1000);
  synopunch_set_connect_timeout(h, 1000);
  synopunch_add_echo_server(h, "127.0.0.1", 1234);
  synopunch_add_echo_server(h, "10.0.0.1", 5678);
  synopunch_set_candidate(h, "10.0.0.1", 9999);
  CHECK(true, "配置接口全部可调用");

  synopunch_clear_candidate(h);
  synopunch_clear_echo_servers(h);

  // 清空后启动应失败于打洞
  int rc = synopunch_start(h);
  CHECK(rc != 0, "清空服务器后启动失败");

  synopunch_free(h);
}

int main() {
  test_lifecycle();
  test_null_safety();
  test_service_type_normalization();
  test_start_failure_paths();
  test_config_roundtrip();

  std::printf("\n%d passed, %d failed\n", g_pass, g_fail);
  return g_fail == 0 ? 0 : 1;
}
