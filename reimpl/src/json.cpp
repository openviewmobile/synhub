// 极简 JSON 递归下降解析器实现
#include "libpunch/json.h"

#include <cstdlib>
#include <cstring>

namespace libpunch {
namespace json {
namespace {

class Parser {
 public:
  explicit Parser(const std::string& s) : s_(s) {}

  bool parseValue(Value& out) {
    skipWs();
    if (pos_ >= s_.size()) return false;
    char c = s_[pos_];
    switch (c) {
      case '{': return parseObject(out);
      case '[': return parseArray(out);
      case '"': {
        std::string str;
        if (!parseString(str)) return false;
        out = Value::makeString(std::move(str));
        return true;
      }
      case 't':
        if (match("true")) { out = Value::makeBool(true); return true; }
        return false;
      case 'f':
        if (match("false")) { out = Value::makeBool(false); return true; }
        return false;
      case 'n':
        if (match("null")) { out = Value::makeNull(); return true; }
        return false;
      default: return parseNumber(out);
    }
  }

  void skipWs() {
    while (pos_ < s_.size()) {
      char c = s_[pos_];
      if (c == ' ' || c == '\t' || c == '\n' || c == '\r') { ++pos_; continue; }
      break;
    }
  }

  bool atEnd() { skipWs(); return pos_ >= s_.size(); }

 private:
  bool match(const char* lit) {
    size_t n = std::strlen(lit);
    if (s_.compare(pos_, n, lit) != 0) return false;
    pos_ += n;
    return true;
  }

  bool parseObject(Value& out) {
    ++pos_;  // '{'
    out = Value::makeObject();
    skipWs();
    if (pos_ < s_.size() && s_[pos_] == '}') { ++pos_; return true; }
    while (true) {
      skipWs();
      std::string key;
      if (!parseString(key)) return false;
      skipWs();
      if (pos_ >= s_.size() || s_[pos_] != ':') return false;
      ++pos_;
      Value v;
      if (!parseValue(v)) return false;
      out.set(key, std::move(v));
      skipWs();
      if (pos_ >= s_.size()) return false;
      if (s_[pos_] == ',') { ++pos_; continue; }
      if (s_[pos_] == '}') { ++pos_; return true; }
      return false;
    }
  }

  bool parseArray(Value& out) {
    ++pos_;  // '['
    out = Value::makeArray();
    skipWs();
    if (pos_ < s_.size() && s_[pos_] == ']') { ++pos_; return true; }
    while (true) {
      Value v;
      if (!parseValue(v)) return false;
      out.push(std::move(v));
      skipWs();
      if (pos_ >= s_.size()) return false;
      if (s_[pos_] == ',') { ++pos_; continue; }
      if (s_[pos_] == ']') { ++pos_; return true; }
      return false;
    }
  }

  bool parseString(std::string& out) {
    if (pos_ >= s_.size() || s_[pos_] != '"') return false;
    ++pos_;
    out.clear();
    while (pos_ < s_.size()) {
      char c = s_[pos_++];
      if (c == '"') return true;
      if (c != '\\') { out += c; continue; }
      if (pos_ >= s_.size()) return false;
      char e = s_[pos_++];
      switch (e) {
        case '"': out += '"'; break;
        case '\\': out += '\\'; break;
        case '/': out += '/'; break;
        case 'b': out += '\b'; break;
        case 'f': out += '\f'; break;
        case 'n': out += '\n'; break;
        case 'r': out += '\r'; break;
        case 't': out += '\t'; break;
        case 'u': {
          if (pos_ + 4 > s_.size()) return false;
          unsigned cp = 0;
          for (int i = 0; i < 4; ++i) {
            char h = s_[pos_++];
            cp <<= 4;
            if (h >= '0' && h <= '9') cp |= (unsigned)(h - '0');
            else if (h >= 'a' && h <= 'f') cp |= (unsigned)(h - 'a' + 10);
            else if (h >= 'A' && h <= 'F') cp |= (unsigned)(h - 'A' + 10);
            else return false;
          }
          // UTF-8 编码（不做代理对合并，够用）
          if (cp < 0x80) {
            out += (char)cp;
          } else if (cp < 0x800) {
            out += (char)(0xC0 | (cp >> 6));
            out += (char)(0x80 | (cp & 0x3F));
          } else {
            out += (char)(0xE0 | (cp >> 12));
            out += (char)(0x80 | ((cp >> 6) & 0x3F));
            out += (char)(0x80 | (cp & 0x3F));
          }
          break;
        }
        default: return false;
      }
    }
    return false;  // 未闭合
  }

  bool parseNumber(Value& out) {
    size_t start = pos_;
    if (pos_ < s_.size() && (s_[pos_] == '-' || s_[pos_] == '+')) ++pos_;
    bool any = false;
    while (pos_ < s_.size() && s_[pos_] >= '0' && s_[pos_] <= '9') { ++pos_; any = true; }
    if (pos_ < s_.size() && s_[pos_] == '.') {
      ++pos_;
      while (pos_ < s_.size() && s_[pos_] >= '0' && s_[pos_] <= '9') { ++pos_; any = true; }
    }
    if (any && pos_ < s_.size() && (s_[pos_] == 'e' || s_[pos_] == 'E')) {
      ++pos_;
      if (pos_ < s_.size() && (s_[pos_] == '-' || s_[pos_] == '+')) ++pos_;
      while (pos_ < s_.size() && s_[pos_] >= '0' && s_[pos_] <= '9') ++pos_;
    }
    if (!any) return false;
    out = Value::makeNumber(std::strtod(s_.substr(start, pos_ - start).c_str(), nullptr));
    return true;
  }

  const std::string& s_;
  size_t pos_ = 0;
};

}  // namespace

bool parse(const std::string& text, Value& out) {
  Parser p(text);
  if (!p.parseValue(out)) return false;
  return p.atEnd();
}

}  // namespace json
}  // namespace libpunch
