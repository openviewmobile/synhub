// 隧道会话对象与注册表验证
#include "libpunch/relay_session.h"

#include <cstdio>
#include <algorithm>
#include <map>
#include <string>
#include <vector>

using namespace libpunch;

static int g_fail = 0, g_pass = 0;

#define CHECK(cond, msg)                                                    \
  do {                                                                      \
    if (cond) { ++g_pass; }                                                 \
    else { ++g_fail; std::printf("  FAIL: %s (%s:%d)\n", msg, __FILE__, __LINE__); } \
  } while (0)

// ---------------------------------------------------------------- 会话对象
static void test_session_basics() {
  std::printf("[session] 基本字段与状态\n");
  RelaySession s(/*tcp_fd=*/11, /*session_id=*/0x2222, /*service_id=*/2);

  CHECK(s.tcp_fd() == 11, "tcp_fd");
  CHECK(s.session_id() == 0x2222, "session_id");
  CHECK(s.service_id() == 2, "service_id");
  CHECK(s.status() == SessionStatus::Init, "构造时状态为 Init(1)");

  s.set_status(SessionStatus::Active);
  CHECK(s.status() == SessionStatus::Active, "状态可设为 Active(2)");
  CHECK(s.out_empty(), "输出队列初始为空");
}

// CheckStatus：参数为 3 或 4 时恒真，否则与当前状态比较
static void test_check_status() {
  std::printf("[session] CheckStatus 语义\n");
  RelaySession s(11, 1, 2);

  CHECK(s.check_status(3), "3 恒真（当前是 1）");
  CHECK(s.check_status(4), "4 恒真（当前是 1）");
  CHECK(s.check_status(1), "1 == 当前状态 Init → 真");
  CHECK(!s.check_status(2), "2 != Init → 假");
  CHECK(!s.check_status(2), "2 != Init → 假");

  s.set_status(SessionStatus::Draining);
  CHECK(s.check_status(3), "3 仍恒真");
  CHECK(!s.check_status(1), "1 != Draining → 假");
}

// ---------------------------------------------------------------- 队列
static void test_out_queue_partial_consume() {
  std::printf("[session] 输出队列部分消费\n");
  RelaySession s(11, 1, 2);

  s.enqueue({1, 2, 3, 4, 5});
  s.enqueue({6, 7});
  CHECK(s.out_size() == 2, "两条待发");
  CHECK((s.out_front() == std::vector<uint8_t>{1, 2, 3, 4, 5}), "队首内容");

  s.out_consume(2);   // 只发出前 2 字节
  CHECK(s.out_size() == 2, "部分消费后仍两条");
  CHECK((s.out_front() == std::vector<uint8_t>{3, 4, 5}), "剩余字节正确");

  s.out_consume(3);   // 发完第一条
  CHECK(s.out_size() == 1, "第一条已出队");
  CHECK((s.out_front() == std::vector<uint8_t>{6, 7}), "队首变为第二条");

  s.out_consume(100);  // 超过长度 → 整条出队
  CHECK(s.out_empty(), "全部发完");
}

static void test_backpressure_threshold() {
  std::printf("[session] 背压阈值 = 29\n");
  RelaySession s(11, 1, 2);
  for (size_t i = 0; i < kSessionQueueHighWater; ++i) s.enqueue({(uint8_t)i});
  CHECK(!s.backlogged(), ("队列 == " + std::to_string(kSessionQueueHighWater) + " 未积压").c_str());

  s.enqueue({0xff});   // 第 30 条
  CHECK(s.backlogged(), "超过 0x1d 判为积压，应暂停隧道读取");
}

// ---------------------------------------------------------------- 隧道索引
static void test_tunnel_dual_index() {
  std::printf("[tunnel] sessionId 与 tcpFd 双索引\n");
  RelayTunnel t(/*udt_fd=*/100);

  RelaySession* a = t.add_session(11, 1, 2);
  RelaySession* b = t.add_session(12, 2, 3);
  CHECK(a != nullptr && b != nullptr, "登记两个会话");
  CHECK(t.session_count() == 2, "会话数 2");

  CHECK(t.find_by_session(1) == a, "按 sessionId 1 找到 a");
  CHECK(t.find_by_session(2) == b, "按 sessionId 2 找到 b");
  CHECK(t.find_by_tcp_fd(11) == a, "按 tcpFd 11 找到 a");
  CHECK(t.find_by_tcp_fd(12) == b, "按 tcpFd 12 找到 b");
  CHECK(t.find_by_session(99) == nullptr, "未知 sessionId → nullptr");
  CHECK(t.find_by_tcp_fd(99) == nullptr, "未知 tcpFd → nullptr");
}

static void test_tunnel_rejects_duplicates() {
  std::printf("[tunnel] 拒绝重复登记\n");
  RelayTunnel t(100);
  t.add_session(11, 1, 2);

  CHECK(t.add_session(11, 2, 2) == nullptr, "重复 tcpFd 被拒");
  CHECK(t.find_by_session(2) == nullptr, "被拒的 sessionId 未残留");
  CHECK(t.session_count() == 1, "会话数仍为 1");

  CHECK(t.add_session(99, 1, 2) != nullptr, "重复 sessionId 返回已存在的会话");
  CHECK(t.session_count() == 1, "会话数仍为 1");
}

static void test_tunnel_remove_keeps_index_consistent() {
  std::printf("[tunnel] 删除后两张索引一致\n");
  RelayTunnel t(100);
  t.add_session(11, 1, 2);
  t.add_session(12, 2, 2);
  t.add_session(13, 3, 2);

  t.remove_session(2);
  CHECK(t.session_count() == 2, "按 sessionId 删除后剩 2");
  CHECK(t.find_by_session(2) == nullptr, "sessionId 2 已消失");
  CHECK(t.find_by_tcp_fd(12) == nullptr, "其 tcpFd 索引也已清除");
  CHECK(t.find_by_session(1) != nullptr && t.find_by_session(3) != nullptr, "其余会话保留");

  t.remove_session_by_tcp_fd(13);
  CHECK(t.session_count() == 1, "按 tcpFd 删除后剩 1");
  CHECK(t.find_by_session(3) == nullptr, "其 sessionId 索引也已清除");
  CHECK(t.find_by_tcp_fd(13) == nullptr, "tcpFd 13 已消失");
  CHECK(t.find_by_session(1) != nullptr, "未受影响的会话仍在");

  CHECK(t.remove_session(42) == nullptr, "删除不存在的会话 → nullptr");
  CHECK(t.find_by_session(1) != nullptr, "误删保护");
}

static void test_tunnel_tx_queue() {
  std::printf("[tunnel] 待发记录队列\n");
  RelayTunnel t(100);

  t.enqueue_record(5, 2, RelayOp::Open, nullptr, 0);
  t.enqueue_record(5, 2, RelayOp::Data, (const uint8_t*)"abcd", 4);
  CHECK(t.tx_size() == 2, "两条待发");
  CHECK(t.tx_pending_bytes() == 8 + (8 + 4), "字节数 = 8 + 12");

  const std::vector<uint8_t>& first = t.tx_front();
  CHECK(first.size() == 8, "OPEN 记录 8 字节");
  CHECK(first[3] == 1, "op = OPEN");

  t.tx_consume(3);            // 部分发出
  CHECK(t.tx_size() == 2, "部分消费后仍两条");
  CHECK(t.tx_pending_bytes() == 5 + 12, "剩余字节数正确");
  CHECK(t.tx_front().size() == 5, "队首被截短到 5");

  t.tx_consume(5);            // 发完第一条
  CHECK(t.tx_size() == 1, "第一条出队");
  CHECK(t.tx_front()[3] == 2, "队首为 DATA");
}

// ---------------------------------------------------------------- 注册表
static void test_agent_lookup_chain() {
  std::printf("[agent] tcpFd → 隧道 → 会话 查询链\n");
  RelayAgent agent;

  RelayTunnel* t1 = agent.add_tunnel(100);
  RelayTunnel* t2 = agent.add_tunnel(200);
  CHECK(t1 != nullptr && t2 != nullptr && t1 != t2, "两条隧道");
  CHECK(agent.add_tunnel(100) == t1, "重复添加返回既有隧道");
  CHECK(agent.tunnel_count() == 2, "隧道数 2");

  agent.insert_session(100, 11, 1, 2);
  agent.insert_session(100, 12, 2, 2);
  agent.insert_session(200, 21, 1, 3);

  CHECK(agent.find_tunnel_by_tcp_fd(11) == t1, "tcpFd 11 属隧道 100");
  CHECK(agent.find_tunnel_by_tcp_fd(21) == t2, "tcpFd 21 属隧道 200");
  CHECK(agent.find_tunnel_by_tcp_fd(99) == nullptr, "未知 tcpFd → nullptr");

  RelaySession* s = agent.find_session_by_tcp_fd(21);
  CHECK(s != nullptr && s->session_id() == 1 && s->service_id() == 3, "找到会话且 serviceId 正确");

  // 两条隧道的 sessionId 可以重复（作用域是隧道内）
  CHECK(t1->find_by_session(1) != nullptr && t2->find_by_session(1) != nullptr,
        "不同隧道可有相同 sessionId");
  CHECK(t1->find_by_session(1) != t2->find_by_session(1), "但指向不同会话对象");
}

static void test_agent_remove_tunnel_cleans_index() {
  std::printf("[agent] 移除隧道清空 tcpFd 索引\n");
  RelayAgent agent;
  agent.add_tunnel(100);
  agent.insert_session(100, 11, 1, 2);
  agent.insert_session(100, 12, 2, 2);
  agent.add_tunnel(200);
  agent.insert_session(200, 21, 1, 3);

  agent.remove_tunnel(100);
  CHECK(agent.tunnel_count() == 1, "隧道数降为 1");
  CHECK(agent.find_tunnel(100) == nullptr, "隧道 100 已消失");
  CHECK(agent.find_tunnel_by_tcp_fd(11) == nullptr, "tcpFd 11 索引已清除");
  CHECK(agent.find_tunnel_by_tcp_fd(12) == nullptr, "tcpFd 12 索引已清除");
  CHECK(agent.find_session_by_tcp_fd(11) == nullptr, "会话查询也失败");
  CHECK(agent.find_tunnel_by_tcp_fd(21) == agent.find_tunnel(200), "另一隧道不受影响");

  CHECK(agent.insert_session(100, 31, 1, 2) == nullptr, "向已移除隧道登记会话被拒");
}

static void test_agent_callbacks() {
  std::printf("[agent] 连接/断开回调\n");
  static int conn_fd = 0, conn_svc = 0, disc_fd = 0, disc_svc = 0;
  conn_fd = conn_svc = disc_fd = disc_svc = 0;

  RelayAgent agent;
  agent.set_tcp_connect_callback([](int fd, int svc) { conn_fd = fd; conn_svc = svc; });
  agent.set_tcp_disconnect_callback([](int fd, int svc) { disc_fd = fd; disc_svc = svc; });

  agent.add_tunnel(100);
  agent.insert_session(100, 11, 1, 7);
  CHECK(conn_fd == 11 && conn_svc == 7, "登记会话触发连接回调");

  agent.remove_session_by_tcp_fd(11);
  CHECK(disc_fd == 11 && disc_svc == 7, "移除会话触发断开回调");

  conn_fd = 0;
  agent.insert_session(999, 12, 1, 2);   // 隧道不存在
  CHECK(conn_fd == 0, "登记失败不触发回调");
}

static void test_agent_duplicate_tcp_fd() {
  std::printf("[agent] 跨隧道拒绝重复 tcpFd\n");
  RelayAgent agent;
  agent.add_tunnel(100);
  agent.add_tunnel(200);
  CHECK(agent.insert_session(100, 11, 1, 2) != nullptr, "首次登记成功");
  CHECK(agent.insert_session(200, 11, 5, 2) == nullptr, "同一 tcpFd 不能登记到另一隧道");
  CHECK(agent.find_tunnel_by_tcp_fd(11) == agent.find_tunnel(100), "原归属未变");
}

// ---------------------------------------------------------------- 端到端
static void test_end_to_end_routing() {
  std::printf("[session] 端到端：组帧 → 隧道接收 → 按会话路由\n");
  RelayAgent agent;
  agent.add_tunnel(100);
  agent.insert_session(100, 11, /*session_id=*/1, 2);
  agent.insert_session(100, 12, /*session_id=*/2, 2);

  RelayTunnel* t = agent.find_tunnel(100);

  // 对端发来 record：session 2 收 "hello"、session 1 收 "world"、session 1 收到 TEARDOWN
  std::vector<uint8_t> wire;
  encode_relay_record(&wire, 2, 2, RelayOp::Data, (const uint8_t*)"hello", 5);
  encode_relay_record(&wire, 1, 2, RelayOp::Data, (const uint8_t*)"world", 5);
  encode_relay_control(&wire, 1, 2, RelayOp::Teardown);

  // 模拟分片：每次喂 3 字节
  for (size_t i = 0; i < wire.size(); i += 3) {
    size_t n = std::min<size_t>(3, wire.size() - i);
    t->rx().append(wire.data() + i, n);
  }

  RelayRecord rec;
  int routed = 0;
  while (t->rx().pop(&rec) == RelayError::Ok) {
    RelaySession* s = t->find_by_session(rec.session_id);
    CHECK(s != nullptr, "按 sessionId 找到目标会话");
    if (s == nullptr) continue;
    ++routed;
    if (rec.op == RelayOp::Data) {
      s->enqueue(rec.payload);
      s->set_status(SessionStatus::Active);
    } else {
      s->set_status(SessionStatus::Draining);
    }
  }

  CHECK(routed == 3, ("路由了 3 条记录, got " + std::to_string(routed)).c_str());

  RelaySession* s1 = t->find_by_session(1);
  RelaySession* s2 = t->find_by_session(2);
  CHECK((s1->out_front() == std::vector<uint8_t>{'w', 'o', 'r', 'l', 'd'}), "会话 1 收到 world");
  CHECK((s2->out_front() == std::vector<uint8_t>{'h', 'e', 'l', 'l', 'o'}), "会话 2 收到 hello");
  CHECK(s1->status() == SessionStatus::Draining, "会话 1 状态转为 Draining");
  CHECK(s2->status() == SessionStatus::Active, "会话 2 状态为 Active");

  // Draining 且队列排空 → 可以拆除（对应 HandleTcpWrite 的收敛条件）
  s1->out_pop_front();
  CHECK(s1->out_empty() && s1->status() == SessionStatus::Draining, "排空 + Draining → 可拆除");
}

int main() {
  test_session_basics();
  test_check_status();
  test_out_queue_partial_consume();
  test_backpressure_threshold();
  test_tunnel_dual_index();
  test_tunnel_rejects_duplicates();
  test_tunnel_remove_keeps_index_consistent();
  test_tunnel_tx_queue();
  test_agent_lookup_chain();
  test_agent_remove_tunnel_cleans_index();
  test_agent_callbacks();
  test_agent_duplicate_tcp_fd();
  test_end_to_end_routing();

  std::printf("\n%d passed, %d failed\n", g_pass, g_fail);
  return g_fail == 0 ? 0 : 1;
}
