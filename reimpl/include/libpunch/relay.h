// UDT 隧道上的会话复用层 —— 还原自 RelayRingBuffer / TcpPeerClient / UdtRelayClient
//
// 隧道是字节流，每条记录 = 8 字节 udp_relay_header_t + length 字节载荷。
// 头里的 port 字段在隧道里被复用为 **sessionId**，type 字段被复用为 **serviceId**。
//
//   op = 1  OPEN      新建会话（length = 0）
//   op = 2  DATA      载荷为该会话的 TCP 数据
//   op = 3  TEARDOWN  关闭单个会话（length = 0）
//   op = 4  CLOSE     关闭整条 UDT 隧道
#pragma once

#include <cstddef>
#include <cstdint>
#include <vector>

#include "libpunch/protocol.h"

namespace libpunch {

// 反编译常量
constexpr size_t kRelayBufferCapacity = 0x2c00;       // 11264，环形缓冲大小
constexpr size_t kRelayCompactionThreshold = 0x2680;  // 9856，消费游标阈值
constexpr uint16_t kRelayMaxPayload = kUdpRelayLenMax - 1;  // 1400

// 会话操作码
enum class RelayOp : uint8_t {
  Open     = 1,
  Data     = 2,
  Teardown = 3,
  Close    = 4,
};

enum class RelayError {
  Ok,          // 成功取出一条记录
  NeedMore,    // 数据不足，等更多字节
  BadHeader,   // 头校验失败
  BadLength,   // length >= 0x579
};

struct RelayRecord {
  uint16_t session_id = 0;   // 头的 port 字段
  uint8_t service_id = 0;    // 头的 type 字段
  RelayOp op = RelayOp::Data;
  uint16_t length = 0;
  std::vector<uint8_t> payload;
};

// ---------------------------------------------------------------- 流重组器
//
// 对应 RelayRingBuffer。原库用 0x2c00 环形缓冲 + 读/写双游标，
// Read 与 Pop 都会推进解析游标，游标越过 0x2680 时置「暂停读取」标志，
// Pop 越过阈值时整体复位。净效果是两条约束，这里按其本意实现：
//   1. 未消费字节超过 0x2680 → paused() 为真，调用方应暂停从 UDT 读取
//      （防止消费方跟不上时环形缓冲被撑爆）
//   2. pop 推进消费游标越过 0x2680 → 压掉已消费前缀，限制内存占用
class RelayStreamBuffer {
 public:
  explicit RelayStreamBuffer(size_t capacity = kRelayBufferCapacity);

  // 追加从 UDT 读到的字节
  void append(const uint8_t* data, size_t len);

  // 尝试取出下一条完整记录。NeedMore 表示还需更多字节。
  // 发生协议错误后缓冲进入不可用状态，需 reset()。
  RelayError pop(RelayRecord* out);

  size_t capacity() const { return capacity_; }
  size_t pending() const { return buf_.size() - read_pos_; }
  size_t read_pos() const { return read_pos_; }
  // 未消费数据已达阈值，调用方应暂停读取
  bool paused() const { return pending() > kRelayCompactionThreshold; }
  bool failed() const { return failed_; }

  // 清空并复位
  void reset();

 private:
  std::vector<uint8_t> buf_;
  size_t read_pos_ = 0;
  size_t capacity_;
  bool failed_ = false;
};

// ---------------------------------------------------------------- 组帧辅助
// 把一条记录编码成连续字节（8 字节头 + 载荷），追加到 out
void encode_relay_record(std::vector<uint8_t>* out, uint16_t session_id, uint8_t service_id,
                         RelayOp op, const uint8_t* payload, size_t len);

// 便捷重载：OPEN / TEARDOWN / CLOSE（length = 0）
void encode_relay_control(std::vector<uint8_t>* out, uint16_t session_id, uint8_t service_id,
                          RelayOp op);

}  // namespace libpunch
