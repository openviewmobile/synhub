// libpunch 协议层实现 —— 由 libsynoholepunch.so 反编译结果重建
#include "libpunch/protocol.h"

#include <cstdlib>
#include <cstring>
#include <ctime>

namespace libpunch {
namespace {

inline uint16_t bswap16(uint16_t v) { return (uint16_t)((v >> 8) | (v << 8)); }

inline uint32_t bswap32_ok(uint32_t v) {
  return ((v & 0x000000ffu) << 24) | ((v & 0x0000ff00u) << 8) |
         ((v & 0x00ff0000u) >> 8)  | ((v & 0xff000000u) >> 24);
}

// 与原实现一致：惰性 srand(time(NULL))，随后连续 rand()
uint16_t next_rand() {
  static bool seeded = false;
  if (!seeded) {
    std::srand((unsigned)std::time(nullptr));
    seeded = true;
  }
  return (uint16_t)std::rand();
}

}  // namespace

// ------------------------------------------------------------ CommandHandler
bool CommandHandler::set(command_t& cmd, CommandCode code, const void* payload, int len,
                         CommandOption option) {
  if (len > (int)kPayloadCapacity) return false;

  std::memset(&cmd, 0, sizeof(cmd));          // 原实现逐字节清零 0x00..0x93
  cmd.option = (uint8_t)option;
  cmd.length = (uint16_t)len;
  cmd.code   = (uint32_t)code;
  cmd.rand_b = next_rand();
  cmd.rand_c = next_rand();
  cmd.rand_d = next_rand();
  if (len > 0 && payload != nullptr) std::memcpy(cmd.payload, payload, (size_t)len);

  cmd.checksum = (uint16_t)(compute_checksum(cmd) & 0xffffu);   // 主机序计算

  // 主机序 → 网络序（大端）
  cmd.code     = bswap32_ok(cmd.code);
  cmd.length   = bswap16(cmd.length);
  cmd.checksum = bswap16(cmd.checksum);
  cmd.rand_b   = bswap16(cmd.rand_b);
  cmd.rand_c   = bswap16(cmd.rand_c);
  cmd.rand_d   = bswap16(cmd.rand_d);
  return true;
}

uint32_t CommandHandler::compute_checksum(const command_t& cmd) {
  uint32_t sum = (uint32_t)cmd.f0 + cmd.code + cmd.length + (uint32_t)cmd.option +
                 (uint32_t)cmd.rand_b + (uint32_t)cmd.rand_c + (uint32_t)cmd.rand_d;
  uint32_t n = cmd.length;
  if (n > kPayloadCapacity) n = (uint32_t)kPayloadCapacity;   // 原实现截断到 128
  for (uint32_t i = 0; i < n; ++i) sum += cmd.payload[i];
  return sum;
}

bool CommandHandler::get(command_t& cmd) {
  // 网络序 → 主机序（与原实现 swap 的字段一致：code/length/checksum/rand_b/rand_c/rand_d）
  cmd.code     = bswap32_ok(cmd.code);
  cmd.length   = bswap16(cmd.length);
  cmd.checksum = bswap16(cmd.checksum);
  cmd.rand_b   = bswap16(cmd.rand_b);
  cmd.rand_c   = bswap16(cmd.rand_c);
  cmd.rand_d   = bswap16(cmd.rand_d);

  return cmd.checksum == (uint16_t)(compute_checksum(cmd) & 0xffffu);
}

bool CommandHandler::parse(command_t& cmd) {
  cmd.code     = bswap32_ok(cmd.code);
  cmd.length   = bswap16(cmd.length);
  cmd.checksum = bswap16(cmd.checksum);
  cmd.rand_b   = bswap16(cmd.rand_b);
  cmd.rand_c   = bswap16(cmd.rand_c);
  cmd.rand_d   = bswap16(cmd.rand_d);

  if ((cmd.option & 0x01) == 0) return true;
  // 原实现在此调用 FUN_003014f4(payload) 解析载荷，语义待补（PROTOCOL.md §8）
  return true;
}

bool CommandHandler::compare(const command_t& a, const command_t& b) {
  if (a.f0 != b.f0) return false;
  if (a.code != b.code) return false;
  if (a.length != b.length) return false;
  return std::memcmp(a.payload, b.payload, kPayloadCapacity) == 0;
}

// ------------------------------------------------------------ UdpRelayHeaderHandler
uint16_t UdpRelayHeaderHandler::compute_checksum(const udp_relay_header_t& h) {
  return (uint16_t)(h.port ^ (uint16_t)h.type ^ h.length ^ (uint16_t)h.op ^ kUdpRelayMagic);
}

bool UdpRelayHeaderHandler::set(uint8_t* buf, uint16_t port, uint8_t type, uint8_t op,
                                uint16_t length) {
  if (buf == nullptr) return false;
  if (type > kUdpRelayTypeMax || op > kUdpRelayOpMax || length >= kUdpRelayLenMax) return false;

  udp_relay_header_t h;
  h.port     = port;
  h.type     = type;
  h.op       = op;
  h.length   = length;
  h.checksum = compute_checksum(h);   // 主机序值

  // 主机序 → 网络序（大端）：按字节写出，不做整体 bswap（否则会双重交换）
  buf[0] = (uint8_t)(h.port >> 8);     buf[1] = (uint8_t)(h.port & 0xff);
  buf[2] = h.type;
  buf[3] = h.op;
  buf[4] = (uint8_t)(h.checksum >> 8); buf[5] = (uint8_t)(h.checksum & 0xff);
  buf[6] = (uint8_t)(h.length >> 8);   buf[7] = (uint8_t)(h.length & 0xff);
  return true;
}

bool UdpRelayHeaderHandler::parse(const uint8_t* buf, udp_relay_header_t& out) {
  if (buf == nullptr) return false;

  out.port   = (uint16_t)((buf[0] << 8) | buf[1]);
  out.type   = buf[2];
  out.op     = buf[3];
  out.checksum = (uint16_t)((buf[4] << 8) | buf[5]);
  out.length = (uint16_t)((buf[6] << 8) | buf[7]);

  if (out.type > kUdpRelayTypeMax) return false;
  if (out.op > kUdpRelayOpMax) return false;
  if (out.length >= kUdpRelayLenMax) return false;

  // 原实现把 checksum 也异或进去再与 0x7777 比较，等价于校验和自洽
  uint16_t x = (uint16_t)(out.port ^ (uint16_t)out.type ^ out.op ^ out.length ^ out.checksum);
  return x == kUdpRelayMagic;
}

int UdpRelayHeaderHandler::close_peer_packet(uint8_t* buf, size_t buflen) {
  if (buf == nullptr || buflen < kUdpRelayHeaderSize) return -1;
  if (!set(buf, 0, 0, kUdpRelayOpClose, 0)) return -1;
  return (int)kUdpRelayHeaderSize;
}

}  // namespace libpunch
