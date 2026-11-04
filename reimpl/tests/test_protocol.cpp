// libpunch 协议层验证 —— 用原库反编译得到的确定值做断言
#include "libpunch/protocol.h"

#include <cstdio>
#include <cstring>
#include <string>

using namespace libpunch;

static int g_fail = 0;
static int g_pass = 0;

#define CHECK(cond, msg)                                              \
  do {                                                                \
    if (cond) { ++g_pass; }                                           \
    else { ++g_fail; std::printf("  FAIL: %s  (%s:%d)\n", msg, __FILE__, __LINE__); } \
  } while (0)

static std::string hex(const uint8_t* p, size_t n) {
  std::string s;
  char b[4];
  for (size_t i = 0; i < n; ++i) { std::snprintf(b, sizeof(b), "%02x ", p[i]); s += b; }
  if (!s.empty()) s.pop_back();
  return s;
}

// ---------------------------------------------------------------- 结构尺寸
static void test_layout() {
  std::printf("[layout]\n");
  CHECK(sizeof(command_t) == 148, "command_t == 148");
  CHECK(offsetof(command_t, code) == 0x04, "code @0x04");
  CHECK(offsetof(command_t, length) == 0x08, "length @0x08");
  CHECK(offsetof(command_t, checksum) == 0x0a, "checksum @0x0a");
  CHECK(offsetof(command_t, option) == 0x0c, "option @0x0c");
  CHECK(offsetof(command_t, rand_b) == 0x0e, "rand_b @0x0e");
  CHECK(offsetof(command_t, payload) == 0x14, "payload @0x14");
  CHECK(sizeof(udp_relay_header_t) == 8, "udp_relay_header_t == 8");
}

// ---------------------------------------------------------------- UDP relay 头
// 原库 close_peer 实发字节: 00 00 00 04 77 73 00 00
static void test_close_peer_packet() {
  std::printf("[udp_relay_header] close_peer 实发字节\n");
  uint8_t buf[8] = {0};
  int n = UdpRelayHeaderHandler::close_peer_packet(buf, sizeof(buf));
  CHECK(n == 8, "close_peer_packet 长度 8");

  const uint8_t expect[8] = {0x00, 0x00, 0x00, 0x04, 0x77, 0x73, 0x00, 0x00};
  CHECK(std::memcmp(buf, expect, 8) == 0,
        ("close_peer 字节序列, got: " + hex(buf, 8)).c_str());

  udp_relay_header_t h;
  CHECK(UdpRelayHeaderHandler::parse(buf, h), "close_peer 报文可解析");
  CHECK(h.op == kUdpRelayOpClose, "op == CLOSE(4)");
  CHECK(h.checksum == 0x7773, "checksum == 0x7773");
  CHECK(h.port == 0 && h.type == 0 && h.length == 0, "其余字段为 0");
}

static void test_udp_roundtrip() {
  std::printf("[udp_relay_header] 往返\n");
  uint8_t buf[8] = {0};
  CHECK(UdpRelayHeaderHandler::set(buf, 0x1234, 0x03, 0x02, 0x0140), "set 正常值");
  udp_relay_header_t h;
  CHECK(UdpRelayHeaderHandler::parse(buf, h), "parse 正常值");
  CHECK(h.port == 0x1234 && h.type == 0x03 && h.op == 0x02 && h.length == 0x0140,
        "字段往返一致");
  CHECK(h.checksum == UdpRelayHeaderHandler::compute_checksum(h), "checksum 自洽");

  // 越界必须被拒
  CHECK(!UdpRelayHeaderHandler::set(buf, 0, 0x0c, 0x00, 0), "type=12 被拒 (上限 0x0b)");
  CHECK(!UdpRelayHeaderHandler::set(buf, 0, 0x00, 0x05, 0), "op=5 被拒 (上限 4)");
  CHECK(!UdpRelayHeaderHandler::set(buf, 0, 0x00, 0x00, 0x579), "length=0x579 被拒 (上限 0x578)");
  CHECK(UdpRelayHeaderHandler::set(buf, 0, 0x0b, 0x04, 0x578), "边界值 0x0b/4/0x578 接受");

  // 篡改必须被检出
  CHECK(UdpRelayHeaderHandler::set(buf, 0x0102, 1, 1, 0x10), "set 用于篡改测试");
  buf[0] ^= 0xff;
  udp_relay_header_t bad;
  CHECK(!UdpRelayHeaderHandler::parse(buf, bad), "篡改 port 后校验失败");
}

// ---------------------------------------------------------------- command_t
static void test_command_roundtrip() {
  std::printf("[command] 打洞命令往返\n");
  const char* qcid = "myquickconnectid";
  command_t tx;
  CHECK(CommandHandler::set(tx, CommandCode::PunchPrimary, qcid, (int)std::strlen(qcid),
                            CommandOption::WithPayload), "set 成功");

  // 网络序：code 应为 00 00 00 01
  const uint8_t* raw = reinterpret_cast<const uint8_t*>(&tx);
  CHECK(raw[4] == 0x00 && raw[5] == 0x00 && raw[6] == 0x00 && raw[7] == 0x01,
        ("code 网络序 == 00 00 00 01, got " + hex(raw + 4, 4)).c_str());
  CHECK(raw[8] == 0x00 && raw[9] == (uint8_t)std::strlen(qcid),
        ("length 网络序, got " + hex(raw + 8, 2)).c_str());
  CHECK(std::memcmp(raw + 0x14, qcid, std::strlen(qcid)) == 0, "载荷就位");

  // 模拟接收方：拷贝 → get → 校验
  command_t rx;
  std::memcpy(&rx, &tx, sizeof(rx));
  CHECK(CommandHandler::get(rx), "接收方 get 校验通过");
  CHECK((uint32_t)rx.code == (uint32_t)CommandCode::PunchPrimary, "code 还原");
  CHECK(rx.length == std::strlen(qcid), "length 还原");
  CHECK(std::memcmp(rx.payload, qcid, std::strlen(qcid)) == 0, "载荷还原");

  // 篡改校验
  std::memcpy(&rx, &tx, sizeof(rx));
  rx.payload[0] ^= 0xff;
  CHECK(!CommandHandler::get(rx), "载荷被篡改后 get 失败");
}

static void test_command_limits() {
  std::printf("[command] 边界与语义\n");
  command_t c;
  uint8_t buf[0x80];
  std::memset(buf, 0xa5, sizeof(buf));

  CHECK(CommandHandler::set(c, CommandCode::PunchPrimary, buf, 0x80,
                            CommandOption::WithPayload), "载荷 128 字节接受");
  CHECK(!CommandHandler::set(c, CommandCode::PunchPrimary, buf, 0x81,
                             CommandOption::WithPayload), "载荷 129 字节拒绝");

  CHECK(CommandHandler::set(c, CommandCode::PunchPrimary, nullptr, 0,
                            CommandOption::None), "空载荷 OK");
  CHECK(c.option == 0, "option 写入 @0x0c");
  CHECK(c.f0 == 0, "f0 恒为 0");

  // compare：只比 f0/code/length/载荷
  command_t a, b;
  CommandHandler::set(a, CommandCode::PunchPrimary, "abc", 3, CommandOption::WithPayload);
  CommandHandler::set(b, CommandCode::PunchPrimary, "abc", 3, CommandOption::WithPayload);
  CHECK(CommandHandler::compare(a, b), "同内容 compare 相等（随机字段不影响）");

  CommandHandler::set(b, CommandCode::PunchSecondary, "abc", 3, CommandOption::WithPayload);
  CHECK(!CommandHandler::compare(a, b), "code 不同则不相等");
}

static void test_service_id_range() {
  std::printf("[service_id] 值域 [1,11]\n");
  // 原库 JNI 入口: if (10 < v - 1U) v = 0;
  auto normalize = [](uint32_t v) -> uint32_t { return (10u < v - 1u) ? 0u : v; };
  CHECK(normalize(0) == 0, "0 → 0 (NoOp)");
  CHECK(normalize(1) == 1, "1 → 1 (Dsm)");
  CHECK(normalize(2) == 2, "2 → 2 (DsmHttps, Chat 使用)");
  CHECK(normalize(11) == 11, "11 → 11 (BsmHttps)");
  CHECK(normalize(12) == 0, "12 → 0 (越界归零)");
  CHECK((int)ServiceId::DsmHttps == 2, "ServiceId::DsmHttps == 2");
}

int main() {
  test_layout();
  test_close_peer_packet();
  test_udp_roundtrip();
  test_command_roundtrip();
  test_command_limits();
  test_service_id_range();

  std::printf("\n%d passed, %d failed\n", g_pass, g_fail);
  return g_fail == 0 ? 0 : 1;
}
