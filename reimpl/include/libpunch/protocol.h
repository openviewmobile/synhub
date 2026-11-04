// libpunch 协议层 —— 由 libsynoholepunch.so (Synology Chat 2.11.1-607) 逆向还原
// 参考: reverse/holepunch/PROTOCOL.md, reverse/holepunch/decompiled/
//
// 本文件为独立实现，不含 Synology 任何代码或二进制。
#pragma once

#include <cstdint>
#include <cstddef>

namespace libpunch {

// ---------------------------------------------------------------- 常量
// command_t 定长
constexpr size_t   kCommandSize      = 0x94;   // 148
constexpr size_t   kPayloadCapacity  = 0x80;   // 128
constexpr size_t   kPayloadOffset    = 0x14;   // 20

// udp_relay_header_t
constexpr size_t   kUdpRelayHeaderSize = 8;
constexpr uint16_t kUdpRelayMagic      = 0x7777;

// 字段合法值域（来自 UdpRelayHeaderHandler::set/parse 的比较常量）
constexpr uint8_t  kUdpRelayTypeMax  = 0x0b;   // type <= 11
constexpr uint8_t  kUdpRelayOpMax    = 0x04;   // op   <= 4
constexpr uint16_t kUdpRelayLenMax   = 0x579;  // length < 1401

// 打洞命令码
enum class CommandCode : uint32_t {
  PunchPrimary   = 1,   // 观察到：主动方与被动方都用它
  PunchSecondary = 2,   // 代码中定义，未出现在观察到的调用点
};

// COMMAND_OPTION：打洞时固定为 1，bit0 表示携带载荷
enum class CommandOption : uint8_t {
  None        = 0,
  WithPayload = 1,
};

// SERVICE_ID —— JNI 入口校验 `if (10 < v - 1U) v = 0;`，合法 [1,11]
// 与 Java PunchInfo.SERVICE_TYPE_* 一致
enum class ServiceId : int32_t {
  NoOp            = 0,
  Dsm             = 1,
  DsmHttps        = 2,   // Synology Chat 使用
  Http            = 3,
  Https           = 4,
  Webdav          = 5,
  WebdavHttps     = 6,
  CloudStation    = 7,
  VpnPlus         = 8,
  BeeDriveHttps   = 9,
  BsmHttp         = 10,
  BsmHttps        = 11,
};

// UdpRelayHeaderHandler::close_peer 使用的 op
constexpr uint8_t kUdpRelayOpClose = 0x04;

// ---------------------------------------------------------------- command_t
#pragma pack(push, 1)
struct command_t {              // 定长 148 字节
  uint8_t  f0;                  // 0x00  参与校验（set 中恒为 0），用途待定
  uint8_t  reserved0[3];        // 0x01
  uint32_t code;                // 0x04  CommandCode，网络序
  uint16_t length;              // 0x08  载荷长度 <= 0x80，网络序
  uint16_t checksum;            // 0x0a  累加校验和，网络序
  uint8_t  option;              // 0x0c  CommandOption，bit0 = 携带载荷
  uint8_t  reserved1;           // 0x0d
  uint16_t rand_b;              // 0x0e  rand()，网络序
  uint16_t rand_c;              // 0x10  rand()，网络序
  uint16_t rand_d;              // 0x12  rand()，网络序
  uint8_t  payload[kPayloadCapacity];  // 0x14
};
#pragma pack(pop)

static_assert(sizeof(command_t) == kCommandSize, "command_t must be 148 bytes");
static_assert(offsetof(command_t, code)     == 0x04, "code offset");
static_assert(offsetof(command_t, length)   == 0x08, "length offset");
static_assert(offsetof(command_t, checksum) == 0x0a, "checksum offset");
static_assert(offsetof(command_t, option)   == 0x0c, "option offset");
static_assert(offsetof(command_t, payload)  == 0x14, "payload offset");

// ---------------------------------------------------------------- udp_relay_header_t
#pragma pack(push, 1)
struct udp_relay_header_t {    // 8 字节
  uint16_t port;               // 0  网络序
  uint8_t  type;               // 2  <= 0x0b
  uint8_t  op;                 // 3  <= 0x04（4 = CLOSE）
  uint16_t checksum;           // 4  网络序 = port ^ type ^ length ^ op ^ 0x7777
  uint16_t length;             // 6  网络序 < 0x579
};
#pragma pack(pop)

static_assert(sizeof(udp_relay_header_t) == kUdpRelayHeaderSize, "udp_relay_header_t must be 8 bytes");

// ---------------------------------------------------------------- CommandHandler
class CommandHandler {
 public:
  // 构造命令。len > 0x80 时返回 false。
  static bool set(command_t& cmd, CommandCode code, const void* payload, int len,
                  CommandOption option);

  // 网络序 → 主机序，并校验 checksum。合法返回 true。
  static bool get(command_t& cmd);

  // 网络序 → 主机序，若 option.bit0 置位则解析载荷。
  static bool parse(command_t& cmd);

  // 比较 f0 / code / length 与整个 128 字节载荷区。
  static bool compare(const command_t& a, const command_t& b);

  // 16 位累加校验和（主机序输入）。
  static uint32_t compute_checksum(const command_t& cmd);
};

// ---------------------------------------------------------------- UdpRelayHeaderHandler
class UdpRelayHeaderHandler {
 public:
  // 组装 8 字节头并转网络序。字段越界返回 false。
  static bool set(uint8_t* buf, uint16_t port, uint8_t type, uint8_t op, uint16_t length);

  // 解析 8 字节头到主机序，并校验 checksum。合法返回 true。
  static bool parse(const uint8_t* buf, udp_relay_header_t& out);

  // 主机序头的校验和。
  static uint16_t compute_checksum(const udp_relay_header_t& h);

  // close_peer 实际发出的报文：op=CLOSE、checksum=0x7773。
  static int close_peer_packet(uint8_t* buf, size_t buflen);
};

}  // namespace libpunch
