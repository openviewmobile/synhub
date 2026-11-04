// 极简 JSON 解析器 —— 自研，无第三方依赖
// 仅需覆盖 quickconnect Serv.php 响应的结构（对象/数组/字符串/数字/布尔/null）
#pragma once

#include <cstdint>
#include <map>
#include <string>
#include <vector>

namespace libpunch {
namespace json {

class Value {
 public:
  enum class Type { Null, Bool, Number, String, Array, Object };

  Value() : type_(Type::Null) {}

  Type type() const { return type_; }
  bool isNull() const { return type_ == Type::Null; }
  bool isBool() const { return type_ == Type::Bool; }
  bool isNumber() const { return type_ == Type::Number; }
  bool isString() const { return type_ == Type::String; }
  bool isArray() const { return type_ == Type::Array; }
  bool isObject() const { return type_ == Type::Object; }

  bool asBool(bool def = false) const { return isBool() ? bool_ : def; }
  double asDouble(double def = 0) const { return isNumber() ? num_ : def; }
  int asInt(int def = 0) const { return isNumber() ? (int)num_ : def; }
  const std::string& asString() const { return str_; }

  size_t size() const { return isArray() ? arr_.size() : (isObject() ? obj_.size() : 0); }

  // 数组下标；越界返回 Null 单例
  const Value& operator[](size_t i) const {
    static const Value kNull;
    if (!isArray() || i >= arr_.size()) return kNull;
    return arr_[i];
  }

  // 对象取值；不存在返回 Null 单例
  const Value& operator[](const std::string& key) const {
    static const Value kNull;
    if (!isObject()) return kNull;
    auto it = obj_.find(key);
    return it == obj_.end() ? kNull : it->second;
  }

  bool has(const std::string& key) const {
    return isObject() && obj_.find(key) != obj_.end();
  }

  // 构造（仅供解析器使用）
  static Value makeNull() { return Value(); }
  static Value makeBool(bool b) { Value v; v.type_ = Type::Bool; v.bool_ = b; return v; }
  static Value makeNumber(double d) { Value v; v.type_ = Type::Number; v.num_ = d; return v; }
  static Value makeString(std::string s) { Value v; v.type_ = Type::String; v.str_ = std::move(s); return v; }
  static Value makeArray() { Value v; v.type_ = Type::Array; return v; }
  static Value makeObject() { Value v; v.type_ = Type::Object; return v; }

  void push(Value v) { arr_.push_back(std::move(v)); }
  void set(const std::string& k, Value v) { obj_[k] = std::move(v); }

 private:
  Type type_;
  bool bool_ = false;
  double num_ = 0;
  std::string str_;
  std::vector<Value> arr_;
  std::map<std::string, Value> obj_;
};

// 解析成功返回 true。允许前后空白。
bool parse(const std::string& text, Value& out);

}  // namespace json
}  // namespace libpunch
