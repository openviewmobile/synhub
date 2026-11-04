// HTTP 端到端验证：自建本地 HTTP 服务器，检查 curl 实际发出的请求
#include "libpunch/http.h"
#include "libpunch/punch_server.h"

#include <arpa/inet.h>
#include <netinet/in.h>
#include <sys/socket.h>
#include <unistd.h>

#include <atomic>
#include <cstdio>
#include <cstring>
#include <string>
#include <thread>

using namespace libpunch;

static int g_fail = 0, g_pass = 0, g_skip = 0;

#define CHECK(cond, msg)                                                    \
  do {                                                                      \
    if (cond) { ++g_pass; }                                                 \
    else { ++g_fail; std::printf("  FAIL: %s (%s:%d)\n", msg, __FILE__, __LINE__); } \
  } while (0)

#define SKIP(msg) do { ++g_skip; std::printf("  SKIP: %s\n", msg); } while (0)

// ---------------------------------------------------------------- 极简 HTTP 服务器
class TestHttpServer {
 public:
  bool start(const std::string& response_body) {
    listen_fd_ = ::socket(AF_INET, SOCK_STREAM, 0);
    if (listen_fd_ < 0) return false;
    int one = 1;
    ::setsockopt(listen_fd_, SOL_SOCKET, SO_REUSEADDR, &one, sizeof(one));

    sockaddr_in sa{};
    sa.sin_family = AF_INET;
    sa.sin_port = 0;
    sa.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
    if (::bind(listen_fd_, (sockaddr*)&sa, sizeof(sa)) != 0) return false;
    if (::listen(listen_fd_, 1) != 0) return false;

    socklen_t len = sizeof(sa);
    if (::getsockname(listen_fd_, (sockaddr*)&sa, &len) != 0) return false;
    port_ = ntohs(sa.sin_port);

    // 给 accept 设超时，避免测试挂死
    timeval tv{5, 0};
    ::setsockopt(listen_fd_, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof(tv));

    response_ = response_body;
    th_ = std::thread([this] { serve_once(); });
    return true;
  }

  void stop() {
    if (th_.joinable()) th_.join();
    if (listen_fd_ >= 0) ::close(listen_fd_);
    listen_fd_ = -1;
  }

  int port() const { return port_; }
  const std::string& captured_request() const { return request_; }

 private:
  void serve_once() {
    int c = ::accept(listen_fd_, nullptr, nullptr);
    if (c < 0) return;
    timeval tv{5, 0};
    ::setsockopt(c, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof(tv));

    char buf[4096];
    std::string req;
    size_t header_end = std::string::npos;

    while (true) {
      ssize_t n = ::recv(c, buf, sizeof(buf), 0);
      if (n <= 0) break;
      req.append(buf, (size_t)n);
      header_end = req.find("\r\n\r\n");
      if (header_end == std::string::npos) continue;

      // 解析 Content-Length，读满 body
      size_t cl = 0;
      size_t p = req.find("Content-Length:");
      if (p == std::string::npos) p = req.find("content-length:");
      if (p != std::string::npos) cl = (size_t)atol(req.c_str() + p + 15);
      size_t have = req.size() - (header_end + 4);
      if (have >= cl) break;
    }
    request_ = req;

    std::string resp = "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\n";
    resp += "Content-Length: " + std::to_string(response_.size()) + "\r\n";
    resp += "Connection: close\r\n\r\n";
    resp += response_;
    ::send(c, resp.data(), resp.size(), 0);
    ::close(c);
  }

  int listen_fd_ = -1;
  int port_ = 0;
  std::string response_;
  std::string request_;
  std::thread th_;
};

// ---------------------------------------------------------------- 测试
static void test_end_to_end() {
  std::printf("[http] 本地服务器端到端\n");

  const char* resp_body =
      "{\"errno\":0,\"sites\":[\"203.0.113.10\"],\"port\":63520,\"udt_tx_mss\":1200}";

  TestHttpServer srv;
  if (!srv.start(resp_body)) { CHECK(false, "启动本地服务器"); return; }

  HttpOptions opt;
  opt.timeout_ms = 4000;
  opt.connect_timeout_ms = 2000;
  opt.verify_peer = false;   // 本地是明文 HTTP

  std::string url = "http://127.0.0.1:" + std::to_string(srv.port()) + "/Serv.php";
  std::string body = build_echo_list_request();
  std::string response;

  PunchError err = http_post(url, body, opt, response);
  srv.stop();

  CHECK(err == PunchError::Ok, "http_post 成功");
  CHECK(response == resp_body, "响应体完整收到");

  const std::string& req = srv.captured_request();
  CHECK(req.rfind("POST /Serv.php", 0) == 0, "请求行是 POST /Serv.php");

  // 原库未设置 Content-Type，curl 对 POSTFIELDS 默认发 application/x-www-form-urlencoded
  CHECK(req.find("Content-Type: application/x-www-form-urlencoded") != std::string::npos,
        "Content-Type 为 curl 默认值（原库确实没设）");

  // 逐字节核对请求体
  size_t hp = req.find("\r\n\r\n");
  CHECK(hp != std::string::npos, "找到头部结束");
  if (hp != std::string::npos) {
    std::string sent = req.substr(hp + 4);
    CHECK(sent == body, ("发出的请求体与原库一致, got: \"" + sent + "\"").c_str());
    CHECK(sent == "{\n\"version\":\"1\",\n\"command\":\"get_echo_list\"\n}\n",
          "请求体逐字节匹配");
  }
}

static void test_parse_after_fetch() {
  std::printf("[http] fetch_echo_list 全链路\n");

  TestHttpServer srv;
  if (!srv.start("{\"errno\":0,\"sites\":[\"1.2.3.4\",\"5.6.7.8\"],\"port\":9000}")) {
    CHECK(false, "启动本地服务器");
    return;
  }

  // 直接复用 http_post + 解析（fetch_echo_list 走的是硬编码的 quickconnect URL）
  HttpOptions opt;
  opt.verify_peer = false;
  opt.timeout_ms = 4000;
  std::string url = "http://127.0.0.1:" + std::to_string(srv.port()) + "/Serv.php";

  std::string response;
  PunchError err = http_post(url, build_echo_list_request(), opt, response);
  srv.stop();
  CHECK(err == PunchError::Ok, "http_post 成功");

  EchoListResult r;
  CHECK(parse_echo_list_response(response, r), "响应解析成功");
  CHECK(r.sites.size() == 2 && r.sites[1].ip == "5.6.7.8", "站点解析正确");
  CHECK(r.sites[0].port == 9000, "端口解析正确");
}

static void test_unreachable() {
  std::printf("[http] 目标不可达\n");
  HttpOptions opt;
  opt.verify_peer = false;
  opt.timeout_ms = 1500;
  opt.connect_timeout_ms = 800;   // 保留端口，几乎肯定连不上

  std::string response;
  PunchError err = http_post("http://127.0.0.1:1/Serv.php", build_echo_list_request(), opt,
                             response);
  CHECK(err == PunchError::CurlPerform, "连接失败返回 CurlPerform(9)（对齐原库）");
}

static void test_fetch_error_propagates() {
  std::printf("[http] fetch_echo_list 错误码传播\n");
  HttpOptions opt;
  opt.verify_peer = false;
  opt.timeout_ms = 1500;
  opt.connect_timeout_ms = 800;

  // 打洞服务器不可达时必须返回 9 而不是崩溃
  EchoListResult r;
  PunchError err = fetch_echo_list(kGlobalServerWw, opt, r);
  CHECK(err == PunchError::CurlPerform || err == PunchError::Ok,
        "返回 CurlPerform(9) 或联网成功");
  CHECK(r.error == err, "out.error 与返回值一致");
}

int main() {
  test_end_to_end();
  test_parse_after_fetch();
  test_unreachable();
  test_fetch_error_propagates();

  std::printf("\n%d passed, %d failed, %d skipped\n", g_pass, g_fail, g_skip);
  return g_fail == 0 ? 0 : 1;
}
