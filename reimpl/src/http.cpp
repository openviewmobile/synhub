// HTTP(S) 客户端实现 —— libcurl，用法对齐 GetPunchServerListSSL 反编译结果
#include "libpunch/http.h"

#include <curl/curl.h>

#include <cstdlib>
#include <cstring>

namespace libpunch {
namespace {

// 原库的 CURLOPT_WRITEFUNCTION：把数据追加到累计缓冲
size_t write_cb(char* ptr, size_t size, size_t nmemb, void* userdata) {
  size_t n = size * nmemb;
  auto* buf = static_cast<std::string*>(userdata);
  buf->append(ptr, n);
  return n;
}

struct CurlGlobal {
  CurlGlobal() { curl_global_init(CURL_GLOBAL_DEFAULT); }
  ~CurlGlobal() { curl_global_cleanup(); }
};

void ensure_global() {
  static CurlGlobal g;
  (void)g;
}

}  // namespace

PunchError http_post(const std::string& url, const std::string& body, const HttpOptions& opt,
                     std::string& response_body) {
  ensure_global();
  response_body.clear();

  CURL* curl = curl_easy_init();
  if (curl == nullptr) return PunchError::CurlInit;   // 原库: 8

  struct Cleanup {
    CURL* c;
    ~Cleanup() { if (c) curl_easy_cleanup(c); }
  } cleanup{curl};

  // 沿用原库的 setopt 序列，任一失败即返回 8
  if (curl_easy_setopt(curl, CURLOPT_URL, url.c_str()) != CURLE_OK) return PunchError::CurlInit;
  if (curl_easy_setopt(curl, CURLOPT_POSTFIELDS, body.c_str()) != CURLE_OK)
    return PunchError::CurlInit;
  if (curl_easy_setopt(curl, CURLOPT_WRITEFUNCTION, write_cb) != CURLE_OK)
    return PunchError::CurlInit;
  if (curl_easy_setopt(curl, CURLOPT_WRITEDATA, &response_body) != CURLE_OK)
    return PunchError::CurlInit;
  if (curl_easy_setopt(curl, CURLOPT_SSL_VERIFYPEER, opt.verify_peer ? 1L : 0L) != CURLE_OK)
    return PunchError::CurlInit;
  if (curl_easy_setopt(curl, CURLOPT_TIMEOUT_MS, opt.timeout_ms) != CURLE_OK)
    return PunchError::CurlInit;
  if (curl_easy_setopt(curl, CURLOPT_CONNECTTIMEOUT_MS, opt.connect_timeout_ms) != CURLE_OK)
    return PunchError::CurlInit;
  if (!opt.ca_info.empty()) {
    if (curl_easy_setopt(curl, CURLOPT_CAINFO, opt.ca_info.c_str()) != CURLE_OK)
      return PunchError::CurlInit;
  }

  CURLcode rc = curl_easy_perform(curl);
  if (rc != CURLE_OK) {
    // 原库未细分 curl 错误码，perform 失败一律 9
    return PunchError::CurlPerform;
  }
  return PunchError::Ok;
}

PunchError fetch_echo_list(int global_server_site, const HttpOptions& opt, EchoListResult& out) {
  std::string body = build_echo_list_request();
  std::string response;
  PunchError err = http_post(punch_server_url(global_server_site), body, opt, response);
  if (err != PunchError::Ok) {
    out.error = err;
    return err;
  }
  if (!parse_echo_list_response(response, out)) {
    out.error = PunchError::BadResponse;   // 原库: 10
    return PunchError::BadResponse;
  }
  out.error = PunchError::Ok;
  return PunchError::Ok;
}

}  // namespace libpunch
