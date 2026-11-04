// UDT 隧道会话复用层实现
#include "libpunch/relay.h"

#include <cstring>

namespace libpunch {

RelayStreamBuffer::RelayStreamBuffer(size_t capacity) : capacity_(capacity) {
  buf_.reserve(capacity);
}

void RelayStreamBuffer::append(const uint8_t* data, size_t len) {
  if (len == 0 || failed_) return;
  buf_.insert(buf_.end(), data, data + len);
}

RelayError RelayStreamBuffer::pop(RelayRecord* out) {
  if (failed_) return RelayError::BadHeader;
  if (pending() < kUdpRelayHeaderSize) return RelayError::NeedMore;

  udp_relay_header_t h{};
  if (!UdpRelayHeaderHandler::parse(buf_.data() + read_pos_, h)) {
    failed_ = true;
    return RelayError::BadHeader;
  }
  if (h.length >= kUdpRelayLenMax) {
    failed_ = true;
    return RelayError::BadLength;
  }
  if (pending() < kUdpRelayHeaderSize + h.length) return RelayError::NeedMore;

  if (out != nullptr) {
    out->session_id = h.port;
    out->service_id = h.type;
    out->op = (RelayOp)h.op;
    out->length = h.length;
    out->payload.assign(buf_.begin() + read_pos_ + kUdpRelayHeaderSize,
                        buf_.begin() + read_pos_ + kUdpRelayHeaderSize + h.length);
  }

  read_pos_ += kUdpRelayHeaderSize + h.length;

  // 对应原库 Pop 末尾：游标越过阈值 → 压掉已消费前缀，限制内存占用
  if (read_pos_ > kRelayCompactionThreshold) {
    buf_.erase(buf_.begin(), buf_.begin() + read_pos_);
    read_pos_ = 0;
  }
  return RelayError::Ok;
}

void RelayStreamBuffer::reset() {
  buf_.clear();
  read_pos_ = 0;
  failed_ = false;
}

void encode_relay_record(std::vector<uint8_t>* out, uint16_t session_id, uint8_t service_id,
                         RelayOp op, const uint8_t* payload, size_t len) {
  if (out == nullptr || len >= kUdpRelayLenMax) return;

  uint8_t hdr[kUdpRelayHeaderSize];
  if (!UdpRelayHeaderHandler::set(hdr, session_id, service_id, (uint8_t)op, (uint16_t)len)) {
    return;
  }
  out->insert(out->end(), hdr, hdr + kUdpRelayHeaderSize);
  if (len > 0 && payload != nullptr) out->insert(out->end(), payload, payload + len);
}

void encode_relay_control(std::vector<uint8_t>* out, uint16_t session_id, uint8_t service_id,
                          RelayOp op) {
  encode_relay_record(out, session_id, service_id, op, nullptr, 0);
}

}  // namespace libpunch
