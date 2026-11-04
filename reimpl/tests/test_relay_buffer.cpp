// 隧道流重组层验证 —— 组帧/拆帧、分片、边界、暂停语义
#include "libpunch/protocol.h"
#include "libpunch/relay.h"

#include <cstdio>
#include <string>
#include <vector>

using namespace libpunch;

static int g_fail = 0, g_pass = 0;

#define CHECK(cond, msg)                                                    \
  do {                                                                      \
    if (cond) { ++g_pass; }                                                 \
    else { ++g_fail; std::printf("  FAIL: %s (%s:%d)\n", msg, __FILE__, __LINE__); } \
  } while (0)

static std::vector<uint8_t> bytes(std::initializer_list<uint8_t> v) {
  return std::vector<uint8_t>(v);
}

// ---------------------------------------------------------------- 组帧格式
static void test_open_record_wire_format() {
  std::printf("[relay] OPEN 记录线上格式\n");
  std::vector<uint8_t> buf;
  encode_relay_control(&buf, /*session_id=*/0x1234, /*service_id=*/2, RelayOp::Open);

  CHECK(buf.size() == 8, "OPEN 记录恰好 8 字节（无载荷）");
  if (buf.size() != 8) return;

  // 头字段一律大端
  CHECK(buf[0] == 0x12 && buf[1] == 0x34, "sessionId 大端 = 0x1234");
  CHECK(buf[2] == 2, "type 字段 = serviceId = 2");
  CHECK(buf[3] == 1, "op = 1 (OPEN)");
  CHECK(buf[6] == 0 && buf[7] == 0, "length = 0");
  // 校验和 = port ^ type ^ length ^ op ^ 0x7777
  uint16_t expect = 0x1234 ^ 2 ^ 0 ^ 1 ^ 0x7777;
  uint16_t got = (uint16_t)((buf[4] << 8) | buf[5]);
  CHECK(got == expect, ("checksum == 0x1234^2^0^1^0x7777, got 0x" + std::to_string(got)).c_str());

  // 用解码路径独立复核
  udp_relay_header_t h{};
  CHECK(UdpRelayHeaderHandler::parse(buf.data(), h), "OPEN 头可通过 parse");
  CHECK(h.port == 0x1234 && h.type == 2 && h.op == 1 && h.length == 0, "解码字段一致");
}

static void test_close_matches_library() {
  std::printf("[relay] CLOSE 记录与原库字节一致\n");
  // 原库 UdpRelayHeaderHandler::close_peer 实际发出 00 00 00 04 77 73 00 00
  std::vector<uint8_t> buf(8);
  int n = UdpRelayHeaderHandler::close_peer_packet(buf.data(), buf.size());
  CHECK(n == 8, "close_peer_packet 返回 8");
  CHECK(buf == bytes({0x00, 0x00, 0x00, 0x04, 0x77, 0x73, 0x00, 0x00}), "字节完全一致");

  // 解码应得到 op=Close
  udp_relay_header_t h{};
  CHECK(UdpRelayHeaderHandler::parse(buf.data(), h), "CLOSE 头可通过 parse");
  CHECK(h.op == (uint8_t)RelayOp::Close, "op 解码为 Close(4)");
}

// ---------------------------------------------------------------- 基本收发
static void test_single_record() {
  std::printf("[relay] 单条 DATA 记录往返\n");
  const uint8_t payload[] = "hello tunnel";
  std::vector<uint8_t> wire;
  encode_relay_record(&wire, 7, 3, RelayOp::Data, payload, sizeof(payload) - 1);

  CHECK(wire.size() == 8 + sizeof(payload) - 1, "记录长度 = 8 + 载荷");

  RelayStreamBuffer rb;
  rb.append(wire.data(), wire.size());

  RelayRecord rec;
  CHECK(rb.pop(&rec) == RelayError::Ok, "取出成功");
  CHECK(rec.session_id == 7, "sessionId == 7");
  CHECK(rec.service_id == 3, "serviceId == 3");
  CHECK(rec.op == RelayOp::Data, "op == Data");
  CHECK(rec.length == sizeof(payload) - 1, "length 正确");
  CHECK(std::string(rec.payload.begin(), rec.payload.end()) == "hello tunnel", "载荷一致");
  CHECK(rb.pop(&rec) == RelayError::NeedMore, "无更多记录");
}

static void test_multiple_records_one_append() {
  std::printf("[relay] 一次 append 含多条记录\n");
  std::vector<uint8_t> wire;
  encode_relay_control(&wire, 1, 2, RelayOp::Open);
  encode_relay_record(&wire, 1, 2, RelayOp::Data, (const uint8_t*)"abc", 3);
  encode_relay_record(&wire, 2, 2, RelayOp::Data, (const uint8_t*)"defg", 4);
  encode_relay_control(&wire, 1, 2, RelayOp::Teardown);

  RelayStreamBuffer rb;
  rb.append(wire.data(), wire.size());

  RelayRecord rec;
  CHECK(rb.pop(&rec) == RelayError::Ok && rec.op == RelayOp::Open && rec.session_id == 1,
        "第 1 条 OPEN");
  CHECK(rb.pop(&rec) == RelayError::Ok && rec.op == RelayOp::Data && rec.payload.size() == 3,
        "第 2 条 DATA(3)");
  CHECK(rb.pop(&rec) == RelayError::Ok && rec.session_id == 2 && rec.payload.size() == 4,
        "第 3 条 DATA(4) 属 session 2");
  CHECK(rb.pop(&rec) == RelayError::Ok && rec.op == RelayOp::Teardown, "第 4 条 TEARDOWN");
  CHECK(rb.pop(&rec) == RelayError::NeedMore, "已取空");
}

// ---------------------------------------------------------------- 分片
static void test_byte_by_byte() {
  std::printf("[relay] 逐字节喂入（模拟 UDT 流分片）\n");
  std::vector<uint8_t> wire;
  encode_relay_control(&wire, 0xabcd, 2, RelayOp::Open);
  encode_relay_record(&wire, 0xabcd, 2, RelayOp::Data, (const uint8_t*)"0123456789", 10);
  encode_relay_control(&wire, 0xabcd, 2, RelayOp::Teardown);

  RelayStreamBuffer rb;
  RelayRecord rec;
  int got = 0;

  for (size_t i = 0; i < wire.size(); ++i) {
    rb.append(&wire[i], 1);
    while (rb.pop(&rec) == RelayError::Ok) ++got;
    // 每次喂入都不应产生协议错误
    CHECK(!rb.failed(), "逐字节喂入无协议错误");
  }
  CHECK(got == 3, ("拆成 3 条记录, got " + std::to_string(got)).c_str());
}

static void test_header_split_exactly() {
  std::printf("[relay] 头恰好被切成两半\n");
  std::vector<uint8_t> wire;
  encode_relay_record(&wire, 5, 1, RelayOp::Data, (const uint8_t*)"payload!", 8);

  for (size_t split = 1; split < 8; ++split) {   // 在头内部每个位置切开
    RelayStreamBuffer rb;
    RelayRecord rec;
    rb.append(wire.data(), split);
    CHECK(rb.pop(&rec) == RelayError::NeedMore, "头不完整 → NeedMore");
    rb.append(wire.data() + split, wire.size() - split);
    CHECK(rb.pop(&rec) == RelayError::Ok, "补齐后取出成功");
    CHECK(rec.session_id == 5 && rec.payload.size() == 8, "字段正确");
  }

  for (size_t split = 8; split < wire.size(); ++split) {   // 在载荷内部切开
    RelayStreamBuffer rb;
    RelayRecord rec;
    rb.append(wire.data(), split);
    CHECK(rb.pop(&rec) == RelayError::NeedMore, "载荷不完整 → NeedMore");
    rb.append(wire.data() + split, wire.size() - split);
    CHECK(rb.pop(&rec) == RelayError::Ok, "补齐后取出成功");
  }
}

// ---------------------------------------------------------------- 错误
static void test_bad_checksum() {
  std::printf("[relay] 校验和损坏\n");
  std::vector<uint8_t> wire;
  encode_relay_record(&wire, 9, 2, RelayOp::Data, (const uint8_t*)"xx", 2);
  wire[5] ^= 0xff;   // 破坏 checksum

  RelayStreamBuffer rb;
  rb.append(wire.data(), wire.size());
  RelayRecord rec;
  CHECK(rb.pop(&rec) == RelayError::BadHeader, "返回 BadHeader");
  CHECK(rb.failed(), "缓冲进入失败态");
  CHECK(rb.pop(&rec) == RelayError::BadHeader, "失败态持续");
}

static void test_oversized_length() {
  std::printf("[relay] length 越界\n");
  // 手工构造一个 length = 0x579（== 上限，非法）
  uint8_t hdr[8] = {0x00, 0x01, 0x02, 0x02, 0x00, 0x00, 0x05, 0x79};
  uint16_t ck = (uint16_t)(0x0001 ^ 0x02 ^ 0x0579 ^ 0x02 ^ 0x7777);
  hdr[4] = (uint8_t)(ck >> 8);
  hdr[5] = (uint8_t)(ck & 0xff);

  RelayStreamBuffer rb;
  rb.append(hdr, sizeof(hdr));
  RelayRecord rec;
  // 注意：原库 RelayRingBuffer::Read 里 parse 失败与 length >= 0x579 都返回 -1，
  // 两者本不可区分；这里 parse 会先拒绝越界长度，所以表现为 BadHeader。
  CHECK(rb.pop(&rec) == RelayError::BadHeader, "越界 length 被拒（原库同样并入 -1）");
  CHECK(rb.failed(), "缓冲进入失败态");
}

static void test_max_legal_length() {
  std::printf("[relay] 最大合法 length = 1400\n");
  std::vector<uint8_t> payload(kRelayMaxPayload, 0xAB);
  std::vector<uint8_t> wire;
  encode_relay_record(&wire, 1, 2, RelayOp::Data, payload.data(), payload.size());
  CHECK(wire.size() == 8 + kRelayMaxPayload, "长度为 8 + 1400");

  RelayStreamBuffer rb;
  rb.append(wire.data(), wire.size());
  RelayRecord rec;
  CHECK(rb.pop(&rec) == RelayError::Ok, "1400 字节载荷可取出");
  CHECK(rec.length == kRelayMaxPayload, "length == 1400");
  CHECK(rec.payload == payload, "载荷内容一致");
}

static void test_reject_oversized_encode() {
  std::printf("[relay] 拒绝编码越界长度\n");
  std::vector<uint8_t> payload(kUdpRelayLenMax, 0);
  std::vector<uint8_t> wire;
  encode_relay_record(&wire, 1, 2, RelayOp::Data, payload.data(), payload.size());
  CHECK(wire.empty(), "length >= 0x579 时不产出任何字节");
}

// ---------------------------------------------------------------- 暂停/压缩
static void test_pause_and_compaction() {
  std::printf("[relay] 暂停阈值与内存压缩\n");

  // 每条 8 + 100 = 108 字节；造 120 条 = 12960 字节 > 0x2c00(11264)
  const size_t kRecords = 120, kPayload = 100;
  std::vector<uint8_t> wire;
  for (size_t i = 0; i < kRecords; ++i) {
    std::vector<uint8_t> p(kPayload, (uint8_t)i);
    encode_relay_record(&wire, (uint16_t)i, 2, RelayOp::Data, p.data(), p.size());
  }

  RelayStreamBuffer rb;
  rb.append(wire.data(), wire.size());
  CHECK(rb.pending() > kRelayCompactionThreshold, "未消费数据超过阈值");
  CHECK(rb.paused(), "paused() 为真，调用方应停止读取");

  RelayRecord rec;
  size_t n = 0;
  while (rb.pop(&rec) == RelayError::Ok) ++n;
  CHECK(n == kRecords, ("取完 " + std::to_string(kRecords) + " 条, got " + std::to_string(n)).c_str());
  CHECK(rb.pending() == 0, "全部消费完毕");
  CHECK(!rb.paused(), "消费后解除暂停");
  CHECK(rb.read_pos() <= kRelayCompactionThreshold, "消费游标已压缩复位");
  CHECK(!rb.failed(), "无协议错误");
}

static void test_reset() {
  std::printf("[relay] reset 复位失败态\n");
  std::vector<uint8_t> wire;
  encode_relay_record(&wire, 1, 2, RelayOp::Data, (const uint8_t*)"z", 1);
  wire[5] ^= 0xff;

  RelayStreamBuffer rb;
  rb.append(wire.data(), wire.size());
  RelayRecord rec;
  CHECK(rb.pop(&rec) == RelayError::BadHeader, "先进入失败态");
  rb.reset();
  CHECK(!rb.failed(), "reset 后失败态清除");
  CHECK(rb.pending() == 0, "reset 后缓冲为空");

  std::vector<uint8_t> good;
  encode_relay_control(&good, 1, 2, RelayOp::Open);
  rb.append(good.data(), good.size());
  CHECK(rb.pop(&rec) == RelayError::Ok, "reset 后可继续使用");
}

static void test_empty_append() {
  std::printf("[relay] 空 append 无副作用\n");
  RelayStreamBuffer rb;
  rb.append(nullptr, 0);
  CHECK(rb.pending() == 0, "仍为空");
  RelayRecord rec;
  CHECK(rb.pop(&rec) == RelayError::NeedMore, "NeedMore");
  CHECK(!rb.failed(), "未进入失败态");
}

int main() {
  test_open_record_wire_format();
  test_close_matches_library();
  test_single_record();
  test_multiple_records_one_append();
  test_byte_by_byte();
  test_header_split_exactly();
  test_bad_checksum();
  test_oversized_length();
  test_max_legal_length();
  test_reject_oversized_encode();
  test_pause_and_compaction();
  test_reset();
  test_empty_append();

  std::printf("\n%d passed, %d failed\n", g_pass, g_fail);
  return g_fail == 0 ? 0 : 1;
}
