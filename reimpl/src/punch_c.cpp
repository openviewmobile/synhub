// C ABI 实现
#include "libpunch/punch_c.h"

#include <arpa/inet.h>
#include <netinet/in.h>

#include <cstring>
#include <new>
#include <string>
#include <vector>

#include "libpunch/relay_client.h"

using namespace libpunch;

struct synopunch_handle {
  TunnelRequest req;
  RelayClient client;
  std::string last_error;
  bool rendezvous = true;
  int punch_timeout_ms = 5000;
  int connect_timeout_ms = 5000;
};

namespace {

inline synopunch_handle* H(synopunch_handle* h) { return h; }

void set_error(synopunch_handle* h, const char* name) {
  if (h != nullptr) h->last_error = name == nullptr ? "" : name;
}

// 与原库 synopunchStart 一致：serviceType 超出 [1,11] 则归零
int normalize_service_type(int v) { return (10 < (unsigned)(v - 1)) ? 0 : v; }

}  // namespace

extern "C" {

synopunch_handle* synopunch_new(void) {
  synopunch_handle* h = new (std::nothrow) synopunch_handle();
  if (h == nullptr) return nullptr;
  h->req.service_id = 2;   // dsm_https
  h->req.use_rendezvous = true;
  return h;
}

void synopunch_free(synopunch_handle* h) {
  if (h == nullptr) return;
  h->client.stop();
  delete h;
}

void synopunch_set_server_id(synopunch_handle* h, const char* qc_id) {
  if (H(h) == nullptr || qc_id == nullptr) return;
  h->req.qc_id = qc_id;
}

void synopunch_set_service_type(synopunch_handle* h, int service_type) {
  if (H(h) == nullptr) return;
  h->req.service_id = (uint8_t)normalize_service_type(service_type);
}

void synopunch_add_echo_server(synopunch_handle* h, const char* ip, int port) {
  if (H(h) == nullptr || ip == nullptr || port <= 0 || port > 65535) return;
  IpPortPair p;
  p.ip = ip;
  p.port = (uint16_t)port;
  h->req.echo_servers.push_back(p);
}

void synopunch_clear_echo_servers(synopunch_handle* h) {
  if (H(h) == nullptr) return;
  h->req.echo_servers.clear();
}

void synopunch_set_udt_tx_mss(synopunch_handle* h, int mss) {
  if (H(h) == nullptr) return;
  if (mss > 0) h->req.read_chunk = (size_t)mss;
}

void synopunch_set_candidate(synopunch_handle* h, const char* ip, int port) {
  if (H(h) == nullptr || ip == nullptr || port <= 0 || port > 65535) return;

  sockaddr_in sa;
  std::memset(&sa, 0, sizeof(sa));
  sa.sin_family = AF_INET;
  sa.sin_port = htons((uint16_t)port);
  sa.sin_addr.s_addr = inet_addr(ip);

  h->req.candidate = sa;
  h->req.has_candidate = true;
}

void synopunch_clear_candidate(synopunch_handle* h) {
  if (H(h) == nullptr) return;
  h->req.has_candidate = false;
  std::memset(&h->req.candidate, 0, sizeof(h->req.candidate));
}

void synopunch_set_rendezvous(synopunch_handle* h, int enable) {
  if (H(h) == nullptr) return;
  h->rendezvous = enable != 0;
  h->req.use_rendezvous = h->rendezvous;
}

void synopunch_set_local_service_port(synopunch_handle* h, int port) {
  if (H(h) == nullptr) return;
  h->req.local_service_port = port > 0 ? port : 0;
}

void synopunch_set_punch_timeout(synopunch_handle* h, int ms) {
  if (H(h) == nullptr) return;
  if (ms > 0) h->punch_timeout_ms = ms;
}

void synopunch_set_connect_timeout(synopunch_handle* h, int ms) {
  if (H(h) == nullptr) return;
  if (ms > 0) h->connect_timeout_ms = ms;
}

int synopunch_start(synopunch_handle* h) {
  if (H(h) == nullptr) return (int)TunnelError::EarlyExit;

  h->req.punch_timeout_ms = h->punch_timeout_ms;
  h->req.connect_timeout_ms = h->connect_timeout_ms;
  h->req.use_rendezvous = h->rendezvous;

  TunnelError rc = h->client.start(h->req);
  if (rc != TunnelError::Ok) {
    set_error(h, tunnel_error_name(rc));
    return (int)rc;
  }
  set_error(h, "");
  return 0;
}

// ---- r684：分段接口（见 punch_c.h 的说明）----
int synopunch_prepare(synopunch_handle* h) {
  if (H(h) == nullptr) return (int)TunnelError::EarlyExit;
  h->req.punch_timeout_ms = h->punch_timeout_ms;
  h->req.connect_timeout_ms = h->connect_timeout_ms;
  h->req.use_rendezvous = h->rendezvous;
  TunnelError rc = h->client.prepare(h->req);
  set_error(h, rc == TunnelError::Ok ? "" : tunnel_error_name(rc));
  return (int)rc;
}

int synopunch_udt_port(synopunch_handle* h) {
  if (H(h) == nullptr) return 0;
  return (int)h->client.udt_listen_port();
}

int synopunch_await_peer(synopunch_handle* h) {
  if (H(h) == nullptr) return (int)TunnelError::EarlyExit;
  h->req.punch_timeout_ms = h->punch_timeout_ms;
  h->req.connect_timeout_ms = h->connect_timeout_ms;
  TunnelError rc = h->client.await_peer(h->req);
  set_error(h, rc == TunnelError::Ok ? "" : tunnel_error_name(rc));
  return (int)rc;
}

int synopunch_start_engine(synopunch_handle* h) {
  if (H(h) == nullptr) return (int)TunnelError::EarlyExit;
  h->req.punch_timeout_ms = h->punch_timeout_ms;
  h->req.connect_timeout_ms = h->connect_timeout_ms;
  h->req.use_rendezvous = h->rendezvous;
  TunnelError rc = h->client.start_engine(h->req);
  set_error(h, rc == TunnelError::Ok ? "" : tunnel_error_name(rc));
  return (int)rc;
}

int synopunch_tcp_port(synopunch_handle* h) {
  if (H(h) == nullptr || !h->client.running()) return 0;
  return (int)h->client.local_port();
}

int synopunch_poll(synopunch_handle* h, int timeout_ms) {
  if (H(h) == nullptr || !h->client.running()) return 0;
  return h->client.engine().poll_once(timeout_ms);
}

void synopunch_stop(synopunch_handle* h) {
  if (H(h) == nullptr) return;
  h->client.stop();
}

int synopunch_is_running(synopunch_handle* h) {
  return (H(h) != nullptr && h->client.running()) ? 1 : 0;
}

const char* synopunch_last_error(synopunch_handle* h) {
  if (H(h) == nullptr) return "";
  return h->last_error.c_str();
}

uint64_t synopunch_rx_bytes(synopunch_handle* h) {
  if (H(h) == nullptr || !h->client.running()) return 0;
  RelayTunnel* t = h->client.engine().agent().find_tunnel(h->client.udt_fd());
  return t == nullptr ? 0 : t->rx_bytes();
}

uint64_t synopunch_tx_bytes(synopunch_handle* h) {
  if (H(h) == nullptr || !h->client.running()) return 0;
  RelayTunnel* t = h->client.engine().agent().find_tunnel(h->client.udt_fd());
  return t == nullptr ? 0 : t->tx_bytes();
}

}  // extern "C"
