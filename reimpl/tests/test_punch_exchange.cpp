// 打洞交换验证：自建假 echo 服务器，真实收发 148 字节命令
#include "libpunch/protocol.h"
#include "libpunch/punch_exchange.h"
#include "libpunch/punch_server.h"

#include <arpa/inet.h>
#include <errno.h>
#include <netinet/in.h>
#include <sys/socket.h>
#include <unistd.h>

#include <atomic>
#include <chrono>
#include <cstdio>
#include <cstring>
#include <string>
#include <thread>
#include <vector>

using namespace libpunch;

static int g_fail = 0, g_pass = 0;

#define CHECK(cond, msg)                                                    \
  do {                                                                      \
    if (cond) { ++g_pass; }                                                 \
    else { ++g_fail; std::printf("  FAIL: %s (%s:%d)\n", msg, __FILE__, __LINE__); } \
  } while (0)

// ---------------------------------------------------------------- 假 echo 服务器
class FakeEchoServer {
 public:
  ~FakeEchoServer() { stop(); }

  bool start() {
    fd_ = ::socket(AF_INET, SOCK_DGRAM, 0);
    if (fd_ < 0) return false;
    int one = 1;
    ::setsockopt(fd_, SOL_SOCKET, SO_REUSEADDR, &one, sizeof(one));

    sockaddr_in sa{};
    sa.sin_family = AF_INET;
    sa.sin_port = 0;
    sa.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
    if (::bind(fd_, (sockaddr*)&sa, sizeof(sa)) != 0) return false;

    socklen_t len = sizeof(sa);
    if (::getsockname(fd_, (sockaddr*)&sa, &len) != 0) return false;
    port_ = ntohs(sa.sin_port);

    th_ = std::thread([this] { loop(); });
    return true;
  }

  void stop() {
    stop_.store(true);
    if (th_.joinable()) th_.join();
    if (fd_ >= 0) { ::close(fd_); fd_ = -1; }
  }

  uint16_t port() const { return port_; }

  // 配置回复内容
  void set_reply(const std::string& ip, uint16_t port, uint32_t code = 1,
                 bool enabled = true) {
    reply_ip_ = ::inet_addr(ip.c_str());
    reply_port_ = htons(port);
    reply_code_ = code;
    reply_enabled_ = enabled;
  }
  void set_corrupt_checksum(bool v) { corrupt_checksum_ = v; }
  // 每个命令包回复几次（用于让客户端反复收到不匹配的包，直到超时）
  void set_reply_burst(int n) { reply_burst_ = n; }
  // 持续回复指定毫秒数，用于把客户端的剩余时间耗光
  void set_reply_flood_ms(int ms) { reply_flood_ms_ = ms; }

  // 观测
  int command_count() const { return command_count_.load(); }
  int knock_count() const { return knock_count_.load(); }
  const std::vector<uint8_t>& last_command() const { return last_command_; }
  std::string last_payload() const {
    if (last_command_.size() != sizeof(command_t)) return {};
    const command_t* c = reinterpret_cast<const command_t*>(last_command_.data());
    uint16_t len = (uint16_t)((c->length >> 8) | (c->length << 8));
    if (len > 0x80) return {};
    return std::string((const char*)c->payload, len);
  }

 private:
  void loop() {
    timeval tv{0, 100 * 1000};   // 100ms，便于及时退出
    ::setsockopt(fd_, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof(tv));

    while (!stop_.load()) {
      uint8_t buf[2048];
      sockaddr_in from{};
      socklen_t flen = sizeof(from);
      ssize_t n = ::recvfrom(fd_, buf, sizeof(buf), 0, (sockaddr*)&from, &flen);
      if (n < 0) continue;

      // TTL 敲门包（0 字节）
      if (n == 0) { knock_count_.fetch_add(1); continue; }

      if (n != (ssize_t)sizeof(command_t)) continue;
      command_count_.fetch_add(1);
      last_command_.assign(buf, buf + n);

      if (!reply_enabled_) continue;

      // 构造回复：payload[0:4] = 对端 IPv4，payload[4:6] = 对端端口（均网络序）
      uint8_t pl[6];
      uint32_t ip = reply_ip_;
      uint16_t pt = reply_port_;
      std::memcpy(pl + 0, &ip, 4);
      std::memcpy(pl + 4, &pt, 2);

      command_t reply;
      CommandHandler::set(reply, (CommandCode)reply_code_, pl, 6, CommandOption::WithPayload);
      if (corrupt_checksum_) {
        uint8_t* raw = reinterpret_cast<uint8_t*>(&reply);
        raw[0x0a] ^= 0xff;   // 破坏校验和
      }
      for (int i = 0; i < reply_burst_; ++i) {
        ::sendto(fd_, &reply, sizeof(reply), 0, (sockaddr*)&from, flen);
      }
      if (reply_flood_ms_ > 0) {
        auto until = std::chrono::steady_clock::now() +
                     std::chrono::milliseconds(reply_flood_ms_);
        while (std::chrono::steady_clock::now() < until) {
          ::sendto(fd_, &reply, sizeof(reply), 0, (sockaddr*)&from, flen);
        }
      }
    }
  }

  int fd_ = -1;
  uint16_t port_ = 0;
  std::thread th_;
  std::atomic<bool> stop_{false};

  uint32_t reply_ip_ = 0;
  uint16_t reply_port_ = 0;
  uint32_t reply_code_ = 1;
  bool reply_enabled_ = true;
  bool corrupt_checksum_ = false;
  int reply_burst_ = 1;
  int reply_flood_ms_ = 0;

  std::atomic<int> command_count_{0};
  std::atomic<int> knock_count_{0};
  std::vector<uint8_t> last_command_;
};

static PunchExchangeParams make_params(uint16_t server_port, std::string qcid = "myqcid") {
  PunchExchangeParams p;
  p.local_port = 0;
  p.qc_id = std::move(qcid);
  p.use_code1 = true;
  p.timeout_ms = 1500;
  IpPortPair s;
  s.ip = "127.0.0.1";
  s.port = server_port;
  p.servers.push_back(s);
  return p;
}

// ---------------------------------------------------------------- 成功路径
static void test_success() {
  std::printf("[punch] 成功交换\n");
  FakeEchoServer srv;
  if (!srv.start()) { CHECK(false, "启动假服务器"); return; }
  srv.set_reply("203.0.113.55", 9999);

  auto p = make_params(srv.port());
  auto r = get_remote_server_address(nullptr, p);
  srv.stop();

  CHECK(r.error == PunchError::Ok, "返回 Ok");
  CHECK(r.packets_sent == 1, "发出 1 个命令包");
  CHECK(srv.command_count() >= 1, "服务器收到命令包");
  CHECK(ntohl(r.peer.sin_addr.s_addr) == ntohl(inet_addr("203.0.113.55")), "对端 IP 正确");
  CHECK(ntohs(r.peer.sin_port) == 9999, "对端端口正确");
  CHECK(r.peer.sin_family == AF_INET, "sin_family = AF_INET");
}

// 服务器侧核验客户端发出的命令是否严格合规
static void test_request_is_wellformed() {
  std::printf("[punch] 请求包合规性\n");
  FakeEchoServer srv;
  if (!srv.start()) { CHECK(false, "启动假服务器"); return; }
  srv.set_reply("198.51.100.1", 1234);

  auto p = make_params(srv.port(), "test-qcid-123");
  auto r = get_remote_server_address(nullptr, p);
  srv.stop();

  CHECK(r.error == PunchError::Ok, "交换成功");
  const auto& raw = srv.last_command();
  CHECK(raw.size() == sizeof(command_t), "恰好 148 字节");
  if (raw.size() != sizeof(command_t)) return;

  // 用接收方的解码路径独立校验
  command_t got;
  std::memcpy(&got, raw.data(), sizeof(got));
  CHECK(CommandHandler::get(got), "收到的命令校验和有效");
  CHECK(got.code == (uint32_t)CommandCode::PunchPrimary, "code == 1");
  CHECK(got.length == std::string("test-qcid-123").size(), "length 正确");
  CHECK(got.option == (uint8_t)CommandOption::WithPayload, "option == 1");
  CHECK(srv.last_payload() == "test-qcid-123", "载荷为 QuickConnect ID");

  // 线路上一律大端：code 在原始字节里应是 00 00 00 01
  CHECK(raw[4] == 0 && raw[5] == 0 && raw[6] == 0 && raw[7] == 1, "code 网络序为大端");
  CHECK(raw[0x14] == 't', "载荷起始于 0x14");
}

static void test_second_code() {
  std::printf("[punch] COMMAND_CODE=2 分支\n");
  FakeEchoServer srv;
  if (!srv.start()) { CHECK(false, "启动假服务器"); return; }
  srv.set_reply("203.0.113.7", 5555, /*code=*/2);

  auto p = make_params(srv.port());
  p.use_code1 = false;
  auto r = get_remote_server_address(nullptr, p);
  srv.stop();

  CHECK(r.error == PunchError::Ok, "code=2 交换成功");
  const auto& raw = srv.last_command();
  if (raw.size() == sizeof(command_t)) {
    CHECK(raw[4] == 0 && raw[5] == 0 && raw[6] == 0 && raw[7] == 2, "发出的 code 为 2");
  }
}

// ---------------------------------------------------------------- 失败/忽略路径
// 完全无回复时：recvfrom 因 SO_RCVTIMEO 返回 EAGAIN，走 errno != EINTR 分支 → 6
// （错误码 11 只在「循环重新进入且剩余时间已耗尽」时出现，见 test_deadline_exhausted）
static void test_timeout() {
  std::printf("[punch] 无回复 → RecvFailed(6)\n");
  FakeEchoServer srv;
  if (!srv.start()) { CHECK(false, "启动假服务器"); return; }
  srv.set_reply("1.2.3.4", 1, 1, /*enabled=*/false);   // 收包但不回复

  auto p = make_params(srv.port());
  p.timeout_ms = 300;
  auto t0 = std::chrono::steady_clock::now();
  auto r = get_remote_server_address(nullptr, p);
  auto ms = std::chrono::duration_cast<std::chrono::milliseconds>(
                std::chrono::steady_clock::now() - t0).count();
  srv.stop();

  CHECK(r.error == PunchError::RecvFailed, "返回 RecvFailed(6)（对齐原库 errno 分支）");
  CHECK(ms >= 250, "确实等满了 SO_RCVTIMEO");
  CHECK(ms < 1500, "未过度拖延");
}

// 服务器持续回不匹配的包，把剩余时间耗光 → 循环顶部判定超时 → 11
static void test_deadline_exhausted() {
  std::printf("[punch] 持续无效回复 → Timeout(11)\n");
  FakeEchoServer srv;
  if (!srv.start()) { CHECK(false, "启动假服务器"); return; }
  srv.set_reply("1.2.3.4", 1, /*code=*/7);   // code 不匹配
  srv.set_reply_flood_ms(400);               // 持续冲刷到超过客户端超时

  auto p = make_params(srv.port());
  p.timeout_ms = 250;
  auto t0 = std::chrono::steady_clock::now();
  auto r = get_remote_server_address(nullptr, p);
  auto ms = std::chrono::duration_cast<std::chrono::milliseconds>(
                std::chrono::steady_clock::now() - t0).count();
  srv.stop();

  CHECK(r.error == PunchError::Timeout, "返回 Timeout(11)");
  CHECK(ms >= 200, "等到剩余时间耗尽");
}

static void test_wrong_code_ignored() {
  std::printf("[punch] 命令码不匹配的回复被忽略\n");
  FakeEchoServer srv;
  if (!srv.start()) { CHECK(false, "启动假服务器"); return; }
  srv.set_reply("1.2.3.4", 1, /*code=*/7);   // 回一个不同的 code，且只回一次

  auto p = make_params(srv.port());
  p.timeout_ms = 300;
  auto r = get_remote_server_address(nullptr, p);
  srv.stop();

  // 该包被忽略 → 重新 recv → 无包 → EAGAIN → 6
  CHECK(r.error == PunchError::RecvFailed, "不匹配的回复被忽略（未误用其地址）");
  CHECK(r.packets_sent == 1, "只发过一次命令");
}

static void test_corrupt_checksum_ignored() {
  std::printf("[punch] 校验和错误的回复被忽略\n");
  FakeEchoServer srv;
  if (!srv.start()) { CHECK(false, "启动假服务器"); return; }
  srv.set_reply("1.2.3.4", 1);
  srv.set_corrupt_checksum(true);

  auto p = make_params(srv.port());
  p.timeout_ms = 300;
  auto r = get_remote_server_address(nullptr, p);
  srv.stop();

  CHECK(r.error == PunchError::RecvFailed, "校验和错误的回复被忽略");
}

// ---------------------------------------------------------------- TTL 敲门
static void test_ttl_knock() {
  std::printf("[punch] TTL=3 敲门\n");
  FakeEchoServer srv;
  if (!srv.start()) { CHECK(false, "启动假服务器"); return; }
  srv.set_reply("203.0.113.9", 8080);

  // 候选地址 = 假服务器，这样敲门包能被观测到
  sockaddr_in cand{};
  cand.sin_family = AF_INET;
  cand.sin_port = htons(srv.port());
  cand.sin_addr.s_addr = inet_addr("127.0.0.1");

  auto p = make_params(srv.port());
  p.do_ttl_punch = true;
  p.timeout_ms = 1000;

  auto r = get_remote_server_address(&cand, p);
  // 给服务器一点时间收尾
  std::this_thread::sleep_for(std::chrono::milliseconds(50));
  srv.stop();

  CHECK(r.error == PunchError::Ok, "带敲门仍能成功");
  CHECK(r.knock_sent >= 1, "至少发了 1 个敲门包");
  CHECK(srv.knock_count() >= 1, "服务器观测到 0 字节敲门包");
}

static void test_no_knock_without_candidate() {
  std::printf("[punch] 无候选地址时不敲门\n");
  FakeEchoServer srv;
  if (!srv.start()) { CHECK(false, "启动假服务器"); return; }
  srv.set_reply("203.0.113.9", 8080);

  auto p = make_params(srv.port());
  p.do_ttl_punch = true;      // 想敲，但没给 candidate
  p.timeout_ms = 800;

  auto r = get_remote_server_address(nullptr, p);
  std::this_thread::sleep_for(std::chrono::milliseconds(50));
  srv.stop();

  CHECK(r.error == PunchError::Ok, "交换成功");
  CHECK(r.knock_sent == 0, "candidate 为空时不发敲门包");
  CHECK(srv.knock_count() == 0, "服务器未观测到敲门包");
}

// ---------------------------------------------------------------- 多服务器
static void test_multiple_servers() {
  std::printf("[punch] 多服务器扇出\n");
  FakeEchoServer a, b;
  if (!a.start() || !b.start()) { CHECK(false, "启动假服务器"); return; }
  a.set_reply("203.0.113.20", 4444, 1, false);   // a 不回复
  b.set_reply("203.0.113.21", 4445);             // b 回复

  PunchExchangeParams p;
  p.local_port = 0;
  p.qc_id = "fanout";
  p.timeout_ms = 1500;
  p.servers.push_back({"127.0.0.1", a.port()});
  p.servers.push_back({"127.0.0.1", b.port()});

  auto r = get_remote_server_address(nullptr, p);
  a.stop();
  b.stop();

  CHECK(r.error == PunchError::Ok, "交换成功");
  CHECK(r.packets_sent == 2, "向 2 个服务器各发一份");
  CHECK(a.command_count() >= 1, "服务器 A 收到");
  CHECK(b.command_count() >= 1, "服务器 B 收到");
  CHECK(ntohs(r.peer.sin_port) == 4445, "采用先回复的 B 的地址");
}

static void test_empty_servers() {
  std::printf("[punch] 空服务器列表\n");
  PunchExchangeParams p;
  p.qc_id = "x";
  p.timeout_ms = 200;
  auto r = get_remote_server_address(nullptr, p);
  CHECK(r.error == PunchError::EarlyExit, "返回 EarlyExit(1)");
  CHECK(r.packets_sent == 0, "未发包");
}

static void test_empty_qcid() {
  std::printf("[punch] 空 QuickConnect ID\n");
  FakeEchoServer srv;
  if (!srv.start()) { CHECK(false, "启动假服务器"); return; }
  srv.set_reply("203.0.113.30", 3333);

  auto p = make_params(srv.port(), "");
  auto r = get_remote_server_address(nullptr, p);
  srv.stop();

  CHECK(r.error == PunchError::Ok, "空载荷仍可交换");
  CHECK(srv.last_payload().empty(), "载荷为空");
}

int main() {
  test_success();
  test_request_is_wellformed();
  test_second_code();
  test_timeout();
  test_deadline_exhausted();
  test_wrong_code_ignored();
  test_corrupt_checksum_ignored();
  test_ttl_knock();
  test_no_knock_without_candidate();
  test_multiple_servers();
  test_empty_servers();
  test_empty_qcid();

  std::printf("\n%d passed, %d failed\n", g_pass, g_fail);
  return g_fail == 0 ? 0 : 1;
}
