/*
 * VeneraNext JSVM 运行时实现
 *
 * 数据流:
 *   ArkTS ──Eval(src)──▶ C++ ──OH_JSVM_RunScript──▶ JS 源脚本
 *     ▲                                                │
 *     └──── napi Promise(JSON) ◀── resolve ◀── sendMessage() 桥
 */
#include "jsvm_engine.h"

#include <ark_runtime/jsvm.h>
#include <hilog/log.h>

#include <cstdint>
#include <cstdio>
#include <cstring>
#include <string>
#include <vector>

namespace vn {
namespace {

constexpr int32_t kLogDomain = 0x0000;
constexpr const char *kLogTag = "JsVmEngine";

#define VN_LOGI(fmt, ...) OH_LOG_Print(LOG_APP, LOG_INFO, kLogDomain, kLogTag, fmt, ##__VA_ARGS__)
#define VN_LOGE(fmt, ...) OH_LOG_Print(LOG_APP, LOG_ERROR, kLogDomain, kLogTag, fmt, ##__VA_ARGS__)

// ------------------------------------------------------------------ base64

const char *kB64Chars = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";

std::string Base64Encode(const uint8_t *data, size_t len) {
  std::string out;
  if (data == nullptr || len == 0) {
    return out;
  }
  out.reserve(((len + 2) / 3) * 4);
  size_t i = 0;
  while (i + 3 <= len) {
    uint32_t n = (static_cast<uint32_t>(data[i]) << 16) | (static_cast<uint32_t>(data[i + 1]) << 8) |
                 static_cast<uint32_t>(data[i + 2]);
    out.push_back(kB64Chars[(n >> 18) & 63]);
    out.push_back(kB64Chars[(n >> 12) & 63]);
    out.push_back(kB64Chars[(n >> 6) & 63]);
    out.push_back(kB64Chars[n & 63]);
    i += 3;
  }
  size_t rest = len - i;
  if (rest == 1) {
    uint32_t n = static_cast<uint32_t>(data[i]) << 16;
    out.push_back(kB64Chars[(n >> 18) & 63]);
    out.push_back(kB64Chars[(n >> 12) & 63]);
    out.push_back('=');
    out.push_back('=');
  } else if (rest == 2) {
    uint32_t n = (static_cast<uint32_t>(data[i]) << 16) | (static_cast<uint32_t>(data[i + 1]) << 8);
    out.push_back(kB64Chars[(n >> 18) & 63]);
    out.push_back(kB64Chars[(n >> 12) & 63]);
    out.push_back(kB64Chars[(n >> 6) & 63]);
    out.push_back('=');
  }
  return out;
}

int B64Value(char c) {
  if (c >= 'A' && c <= 'Z') {
    return c - 'A';
  }
  if (c >= 'a' && c <= 'z') {
    return c - 'a' + 26;
  }
  if (c >= '0' && c <= '9') {
    return c - '0' + 52;
  }
  if (c == '+') {
    return 62;
  }
  if (c == '/') {
    return 63;
  }
  return -1;
}

std::vector<uint8_t> Base64Decode(const std::string &s) {
  std::vector<uint8_t> out;
  out.reserve(s.size() / 4 * 3);
  uint32_t buf = 0;
  int bits = 0;
  for (char c : s) {
    int v = B64Value(c);
    if (v < 0) {
      continue;
    }
    buf = (buf << 6) | static_cast<uint32_t>(v);
    bits += 6;
    if (bits >= 8) {
      bits -= 8;
      out.push_back(static_cast<uint8_t>((buf >> bits) & 0xFF));
    }
  }
  return out;
}

// ------------------------------------------------------------------ JSON

void AppendEscapedString(std::string &out, const std::string &s) {
  out.push_back('"');
  for (size_t i = 0; i < s.size(); i++) {
    unsigned char c = static_cast<unsigned char>(s[i]);
    switch (c) {
      case '"':
        out += "\\\"";
        break;
      case '\\':
        out += "\\\\";
        break;
      case '\n':
        out += "\\n";
        break;
      case '\r':
        out += "\\r";
        break;
      case '\t':
        out += "\\t";
        break;
      case '\b':
        out += "\\b";
        break;
      case '\f':
        out += "\\f";
        break;
      default:
        if (c < 0x20) {
          char buf[8];
          (void)snprintf(buf, sizeof(buf), "\\u%04x", c);
          out += buf;
        } else {
          out.push_back(static_cast<char>(c));
        }
        break;
    }
  }
  out.push_back('"');
}

void AppendDouble(std::string &out, double v) {
  char buf[40];
  int64_t iv = static_cast<int64_t>(v);
  if (static_cast<double>(iv) == v && v > -1e15 && v < 1e15) {
    (void)snprintf(buf, sizeof(buf), "%lld", static_cast<long long>(iv));
    out += buf;
    return;
  }
  (void)snprintf(buf, sizeof(buf), "%.17g", v);
  out += buf;
}

std::string JsToString(JSVM_Env env, JSVM_Value value) {
  size_t len = 0;
  if (OH_JSVM_GetValueStringUtf8(env, value, nullptr, 0, &len) != JSVM_OK) {
    return std::string();
  }
  std::string s(len, '\0');
  size_t copied = 0;
  if (OH_JSVM_GetValueStringUtf8(env, value, &s[0], len + 1, &copied) != JSVM_OK) {
    return std::string();
  }
  s.resize(copied);
  return s;
}

bool AppendJson(JSVM_Env env, JSVM_Value value, std::string &out, int depth);

void AppendBytesObject(std::string &out, const void *data, size_t len) {
  out += "{\"__bytes\":\"";
  out += Base64Encode(static_cast<const uint8_t *>(data), len);
  out += "\"}";
}

bool AppendJson(JSVM_Env env, JSVM_Value value, std::string &out, int depth) {
  if (depth > 24 || value == nullptr) {
    out += "null";
    return false;
  }
  bool flag = false;
  if (OH_JSVM_IsNullOrUndefined(env, value, &flag) == JSVM_OK && flag) {
    out += "null";
    return true;
  }
  JSVM_ValueType type = JSVM_UNDEFINED;
  if (OH_JSVM_Typeof(env, value, &type) != JSVM_OK) {
    out += "null";
    return false;
  }
  if (type == JSVM_BOOLEAN) {
    bool v = false;
    OH_JSVM_GetValueBool(env, value, &v);
    out += (v ? "true" : "false");
    return true;
  }
  if (type == JSVM_NUMBER) {
    double v = 0;
    OH_JSVM_GetValueDouble(env, value, &v);
    AppendDouble(out, v);
    return true;
  }
  if (type == JSVM_STRING) {
    AppendEscapedString(out, JsToString(env, value));
    return true;
  }
  if (type != JSVM_OBJECT) {
    // function / symbol / external / bigint 统一降级为 null
    out += "null";
    return true;
  }

  if (OH_JSVM_IsArraybuffer(env, value, &flag) == JSVM_OK && flag) {
    void *data = nullptr;
    size_t len = 0;
    OH_JSVM_GetArraybufferInfo(env, value, &data, &len);
    AppendBytesObject(out, data, len);
    return true;
  }
  if (OH_JSVM_IsTypedarray(env, value, &flag) == JSVM_OK && flag) {
    size_t len = 0;
    void *data = nullptr;
    OH_JSVM_GetTypedarrayInfo(env, value, nullptr, &len, &data, nullptr, nullptr);
    AppendBytesObject(out, data, len);
    return true;
  }
  if (OH_JSVM_IsDataview(env, value, &flag) == JSVM_OK && flag) {
    size_t len = 0;
    void *data = nullptr;
    OH_JSVM_GetDataviewInfo(env, value, &len, &data, nullptr, nullptr);
    AppendBytesObject(out, data, len);
    return true;
  }
  if (OH_JSVM_IsArray(env, value, &flag) == JSVM_OK && flag) {
    uint32_t len = 0;
    OH_JSVM_GetArrayLength(env, value, &len);
    out.push_back('[');
    for (uint32_t i = 0; i < len; i++) {
      if (i > 0) {
        out.push_back(',');
      }
      JSVM_Value item = nullptr;
      if (OH_JSVM_GetElement(env, value, i, &item) == JSVM_OK) {
        AppendJson(env, item, out, depth + 1);
      } else {
        out += "null";
      }
    }
    out.push_back(']');
    return true;
  }

  JSVM_Value keys = nullptr;
  JSVM_Status kst = OH_JSVM_GetAllPropertyNames(
      env, value, JSVM_KEY_OWN_ONLY,
      static_cast<JSVM_KeyFilter>(JSVM_KEY_ENUMERABLE | JSVM_KEY_SKIP_SYMBOLS),
      JSVM_KEY_NUMBERS_TO_STRINGS, &keys);
  if (kst != JSVM_OK || keys == nullptr) {
    out += "null";
    return false;
  }
  uint32_t keyCount = 0;
  OH_JSVM_GetArrayLength(env, keys, &keyCount);
  out.push_back('{');
  bool first = true;
  for (uint32_t i = 0; i < keyCount; i++) {
    JSVM_Value key = nullptr;
    if (OH_JSVM_GetElement(env, keys, i, &key) != JSVM_OK) {
      continue;
    }
    JSVM_Value prop = nullptr;
    if (OH_JSVM_GetProperty(env, value, key, &prop) != JSVM_OK) {
      continue;
    }
    JSVM_ValueType pt = JSVM_UNDEFINED;
    if (OH_JSVM_Typeof(env, prop, &pt) != JSVM_OK) {
      continue;
    }
    // 与 JSON.stringify 保持一致: 跳过 undefined / symbol / external
    if (pt == JSVM_UNDEFINED || pt == JSVM_SYMBOL || pt == JSVM_EXTERNAL) {
      continue;
    }
    if (!first) {
      out.push_back(',');
    }
    first = false;
    AppendEscapedString(out, JsToString(env, key));
    out.push_back(':');
    AppendJson(env, prop, out, depth + 1);
  }
  out.push_back('}');
  return true;
}

JSVM_Value MakeNull(JSVM_Env env) {
  JSVM_Value v = nullptr;
  OH_JSVM_GetNull(env, &v);
  return v;
}

/** 把 {"__bytes": "<base64>"} 递归还原为 ArrayBuffer */
JSVM_Value MaterializeBytes(JSVM_Env env, JSVM_Value value, int depth) {
  if (depth > 24 || value == nullptr) {
    return value;
  }
  bool flag = false;
  if (OH_JSVM_IsArray(env, value, &flag) == JSVM_OK && flag) {
    uint32_t len = 0;
    OH_JSVM_GetArrayLength(env, value, &len);
    for (uint32_t i = 0; i < len; i++) {
      JSVM_Value item = nullptr;
      if (OH_JSVM_GetElement(env, value, i, &item) != JSVM_OK) {
        continue;
      }
      JSVM_Value replaced = MaterializeBytes(env, item, depth + 1);
      if (replaced != item) {
        OH_JSVM_SetElement(env, value, i, replaced);
      }
    }
    return value;
  }
  JSVM_ValueType type = JSVM_UNDEFINED;
  if (OH_JSVM_Typeof(env, value, &type) != JSVM_OK || type != JSVM_OBJECT) {
    return value;
  }
  if (OH_JSVM_IsArraybuffer(env, value, &flag) == JSVM_OK && flag) {
    return value;
  }

  // 用「属性名遍历 + GetProperty」而非字符串键查询:
  // 这条路径与 AppendJson 相同, 已在消息序列化中验证可用
  JSVM_Value keys = nullptr;
  JSVM_Status kst = OH_JSVM_GetAllPropertyNames(
      env, value, JSVM_KEY_OWN_ONLY,
      static_cast<JSVM_KeyFilter>(JSVM_KEY_ENUMERABLE | JSVM_KEY_SKIP_SYMBOLS),
      JSVM_KEY_NUMBERS_TO_STRINGS, &keys);
  if (kst != JSVM_OK || keys == nullptr) {
    return value;
  }
  uint32_t keyCount = 0;
  OH_JSVM_GetArrayLength(env, keys, &keyCount);

  for (uint32_t i = 0; i < keyCount; i++) {
    JSVM_Value key = nullptr;
    if (OH_JSVM_GetElement(env, keys, i, &key) != JSVM_OK || key == nullptr) {
      continue;
    }
    if (JsToString(env, key) != "__bytes") {
      continue;
    }
    JSVM_Value b64 = nullptr;
    if (OH_JSVM_GetProperty(env, value, key, &b64) != JSVM_OK || b64 == nullptr) {
      continue;
    }
    JSVM_ValueType b64Type = JSVM_UNDEFINED;
    if (OH_JSVM_Typeof(env, b64, &b64Type) != JSVM_OK || b64Type != JSVM_STRING) {
      continue;
    }
    const std::string encoded = JsToString(env, b64);
    if (encoded.empty()) {
      continue;
    }
    const std::vector<uint8_t> bytes = Base64Decode(encoded);
    JSVM_Value ab = nullptr;
    void *buf = nullptr;
    if (OH_JSVM_CreateArraybuffer(env, bytes.size(), &buf, &ab) == JSVM_OK && ab != nullptr) {
      if (buf != nullptr && !bytes.empty()) {
        (void)memcpy(buf, bytes.data(), bytes.size());
      }
      VN_LOGI("materialize: b64=%{public}zu -> bytes=%{public}zu", encoded.size(), bytes.size());
      return ab;
    }
    VN_LOGE("materialize failed: b64Len=%{public}zu", encoded.size());
    return value;
  }

  // 非 bytes 包装: 递归处理各属性
  for (uint32_t i = 0; i < keyCount; i++) {
    JSVM_Value key = nullptr;
    if (OH_JSVM_GetElement(env, keys, i, &key) != JSVM_OK || key == nullptr) {
      continue;
    }
    JSVM_Value prop = nullptr;
    if (OH_JSVM_GetProperty(env, value, key, &prop) != JSVM_OK) {
      continue;
    }
    JSVM_Value replaced = MaterializeBytes(env, prop, depth + 1);
    if (replaced != prop) {
      OH_JSVM_SetProperty(env, value, key, replaced);
    }
  }
  return value;
}

/** JSON 字符串 -> JSVM 值(还原 __bytes) */
JSVM_Value JsonToJs(JSVM_Env env, const std::string &json) {
  if (json.empty()) {
    return MakeNull(env);
  }
  JSVM_Value str = nullptr;
  if (OH_JSVM_CreateStringUtf8(env, json.c_str(), json.size(), &str) != JSVM_OK) {
    return MakeNull(env);
  }
  JSVM_Value parsed = nullptr;
  JSVM_Status pst = OH_JSVM_JsonParse(env, str, &parsed);
  if (pst != JSVM_OK || parsed == nullptr) {
    VN_LOGE("JsonParse failed, status=%d", static_cast<int>(pst));
    return MakeNull(env);
  }
  const bool probe = json.find("__bytes") != std::string::npos;
  JSVM_Value result = MaterializeBytes(env, parsed, 0);
  if (probe) {
    bool isAb = false;
    OH_JSVM_IsArraybuffer(env, result, &isAb);
    VN_LOGI("JsonToJs: bytes payload -> isArrayBuffer=%{public}d", isAb ? 1 : 0);
  }
  return result;
}

std::string LastJsError(JSVM_Env env) {
  const JSVM_ExtendedErrorInfo *info = nullptr;
  if (OH_JSVM_GetLastErrorInfo(env, &info) != JSVM_OK || info == nullptr) {
    return "unknown JS error";
  }
  std::string msg = info->errorMessage != nullptr ? info->errorMessage : "unknown JS error";
  if (!msg.empty() && msg.back() == '\n') {
    msg.pop_back();
  }
  return msg;
}

// ------------------------------------------------------------ napi helpers

std::string NapiString(napi_env env, napi_value value) {
  if (value == nullptr) {
    return std::string();
  }
  size_t len = 0;
  if (napi_get_value_string_utf8(env, value, nullptr, 0, &len) != napi_ok) {
    return std::string();
  }
  std::string s(len, '\0');
  size_t copied = 0;
  if (napi_get_value_string_utf8(env, value, &s[0], len + 1, &copied) != napi_ok) {
    return std::string();
  }
  s.resize(copied);
  return s;
}

bool IsNapiString(napi_env env, napi_value value) {
  if (value == nullptr) {
    return false;
  }
  napi_valuetype t = napi_undefined;
  if (napi_typeof(env, value, &t) != napi_ok) {
    return false;
  }
  return t == napi_string;
}

std::string NapiErrorText(napi_env env, napi_value err) {
  if (err == nullptr) {
    return "sendMessage handler failed";
  }
  napi_valuetype t = napi_undefined;
  napi_typeof(env, err, &t);
  if (t == napi_string) {
    return NapiString(env, err);
  }
  // 尝试取 message 属性
  bool hasMessage = false;
  napi_has_named_property(env, err, "message", &hasMessage);
  if (hasMessage) {
    napi_value msgVal = nullptr;
    if (napi_get_named_property(env, err, "message", &msgVal) == napi_ok) {
      return NapiString(env, msgVal);
    }
  }
  return "sendMessage handler failed";
}

void RejectArk(napi_env env, napi_deferred deferred, const std::string &message) {
  napi_value msg = nullptr;
  napi_create_string_utf8(env, message.c_str(), message.size(), &msg);
  napi_reject_deferred(env, deferred, msg);
}

void ResolveArkJson(napi_env env, napi_deferred deferred, const std::string &json) {
  napi_value s = nullptr;
  napi_create_string_utf8(env, json.c_str(), json.size(), &s);
  napi_resolve_deferred(env, deferred, s);
}

// ------------------------------------------------------------ runtime state

struct SendPending {  // JS 侧 promise 等 ArkTS 处理器结果
  JSVM_Env env = nullptr;
  JSVM_Deferred deferred = nullptr;
  bool settled = false;
};

struct ArkPending {  // ArkTS 侧 promise 等 JS 执行结果
  napi_env env = nullptr;
  napi_deferred deferred = nullptr;
  bool settled = false;
};

struct RuntimeState {
  bool vmCreated = false;
  bool ready = false;
  bool inMicrotask = false;
  JSVM_VM vm = nullptr;
  JSVM_Env env = nullptr;
  JSVM_VMScope vmScope = nullptr;
  JSVM_EnvScope envScope = nullptr;
  napi_env arkEnv = nullptr;
  napi_ref handlerRef = nullptr;
};

RuntimeState g_rt;

/** 驱动 JSVM 微任务(跨引擎 resolve 后必须调用, 否则 await 不会继续) */
void PumpMicrotasks() {
  if (!g_rt.ready || g_rt.inMicrotask) {
    return;
  }
  g_rt.inMicrotask = true;
  if (OH_JSVM_PerformMicrotaskCheckpoint(g_rt.vm) != JSVM_OK) {
    bool pending = false;
    if (OH_JSVM_IsExceptionPending(g_rt.env, &pending) == JSVM_OK && pending) {
      VN_LOGE("microtask error: %{public}s", LastJsError(g_rt.env).c_str());
    }
  }
  g_rt.inMicrotask = false;
}

/** 用 JSON 结果 resolve JS 侧 promise, 并驱动微任务 */
void SettleJsPromise(JSVM_Env env, JSVM_Deferred deferred, const std::string &json) {
  JSVM_HandleScope hs = nullptr;
  OH_JSVM_OpenHandleScope(env, &hs);
  JSVM_Value value = JsonToJs(env, json);
  if (OH_JSVM_ResolveDeferred(env, deferred, value) != JSVM_OK) {
    VN_LOGE("resolve JS promise failed: %{public}s", LastJsError(env).c_str());
  }
  OH_JSVM_CloseHandleScope(env, hs);
  PumpMicrotasks();
}

/** 用错误信息 reject JS 侧 promise */
void SettleJsPromiseError(JSVM_Env env, JSVM_Deferred deferred, const std::string &message) {
  JSVM_HandleScope hs = nullptr;
  OH_JSVM_OpenHandleScope(env, &hs);
  JSVM_Value err = nullptr;
  OH_JSVM_CreateStringUtf8(env, message.c_str(), message.size(), &err);
  OH_JSVM_RejectDeferred(env, deferred, err);
  OH_JSVM_CloseHandleScope(env, hs);
  PumpMicrotasks();
}

napi_value NapiResolveJs(napi_env env, napi_callback_info info) {
  size_t argc = 1;
  napi_value argv[1] = {nullptr};
  void *data = nullptr;
  napi_get_cb_info(env, info, &argc, argv, nullptr, &data);
  SendPending *pending = static_cast<SendPending *>(data);
  if (pending == nullptr || pending->settled) {
    return nullptr;
  }
  pending->settled = true;
  // 约定: ArkTS 处理器返回 JSON 字符串; 非字符串一律按 null 处理
  std::string json = "null";
  if (argc > 0 && IsNapiString(env, argv[0])) {
    json = NapiString(env, argv[0]);
    if (json.empty()) {
      json = "null";
    }
  }
  SettleJsPromise(pending->env, pending->deferred, json);
  return nullptr;
}

napi_value NapiRejectJs(napi_env env, napi_callback_info info) {
  size_t argc = 1;
  napi_value argv[1] = {nullptr};
  void *data = nullptr;
  napi_get_cb_info(env, info, &argc, argv, nullptr, &data);
  SendPending *pending = static_cast<SendPending *>(data);
  if (pending == nullptr || pending->settled) {
    return nullptr;
  }
  pending->settled = true;
  SettleJsPromiseError(pending->env, pending->deferred, NapiErrorText(env, argc > 0 ? argv[0] : nullptr));
  return nullptr;
}

JSVM_Value JsPromiseResolved(JSVM_Env env, JSVM_CallbackInfo info) {
  size_t argc = 1;
  JSVM_Value argv[1] = {nullptr};
  void *data = nullptr;
  OH_JSVM_GetCbInfo(env, info, &argc, argv, nullptr, &data);
  ArkPending *pending = static_cast<ArkPending *>(data);
  if (pending == nullptr || pending->settled) {
    return nullptr;
  }
  pending->settled = true;
  JSVM_HandleScope hs = nullptr;
  OH_JSVM_OpenHandleScope(env, &hs);
  std::string json;
  if (argc > 0 && argv[0] != nullptr) {
    AppendJson(env, argv[0], json, 0);
  }
  OH_JSVM_CloseHandleScope(env, hs);
  if (json.empty()) {
    json = "null";
  }
  ResolveArkJson(pending->env, pending->deferred, json);
  return nullptr;
}

JSVM_Value JsPromiseRejected(JSVM_Env env, JSVM_CallbackInfo info) {
  size_t argc = 1;
  JSVM_Value argv[1] = {nullptr};
  void *data = nullptr;
  OH_JSVM_GetCbInfo(env, info, &argc, argv, nullptr, &data);
  ArkPending *pending = static_cast<ArkPending *>(data);
  if (pending == nullptr || pending->settled) {
    return nullptr;
  }
  pending->settled = true;
  std::string msg = "JS promise rejected";
  if (argc > 0 && argv[0] != nullptr) {
    JSVM_HandleScope hs = nullptr;
    OH_JSVM_OpenHandleScope(env, &hs);
    JSVM_ValueType type = JSVM_UNDEFINED;
    OH_JSVM_Typeof(env, argv[0], &type);
    if (type == JSVM_STRING) {
      msg = JsToString(env, argv[0]);
    } else {
      JSVM_Value text = nullptr;
      if (OH_JSVM_CoerceToString(env, argv[0], &text) == JSVM_OK && text != nullptr) {
        msg = JsToString(env, text);
      }
    }
    OH_JSVM_CloseHandleScope(env, hs);
  }
  RejectArk(pending->env, pending->deferred, msg);
  return nullptr;
}

/**
 * sendMessage 桥: JS 侧调用 -> 转发 ArkTS 处理器。
 *
 * 语义与原版一致: 处理器可返回「普通值」(同步方法, 如 load_data/load_setting/convert)
 * 或「Promise」(异步方法, 如 http/delay)。同步时直接把值还给 JS, 保证源脚本里
 * `const x = this.loadData('k')` 这类不 await 的写法能正常工作。
 */
JSVM_Value JsSendMessage(JSVM_Env env, JSVM_CallbackInfo info) {
  size_t argc = 1;
  JSVM_Value argv[1] = {nullptr};
  void *data = nullptr;
  OH_JSVM_GetCbInfo(env, info, &argc, argv, nullptr, &data);

  if (argc < 1 || argv[0] == nullptr) {
    JSVM_Value nullVal = MakeNull(env);
    return nullVal;
  }

  std::string msgJson;
  if (!AppendJson(env, argv[0], msgJson, 0)) {
    VN_LOGE("serialize sendMessage payload failed");
    JSVM_Value nullVal = MakeNull(env);
    return nullVal;
  }

  napi_env arkEnv = g_rt.arkEnv;
  napi_ref handlerRef = g_rt.handlerRef;
  if (arkEnv == nullptr || handlerRef == nullptr) {
    VN_LOGE("sendMessage handler not registered, payload=%.200s", msgJson.c_str());
    JSVM_Value nullVal = MakeNull(env);
    return nullVal;
  }

  napi_value handlerFn = nullptr;
  if (napi_get_reference_value(arkEnv, handlerRef, &handlerFn) != napi_ok || handlerFn == nullptr) {
    VN_LOGE("sendMessage handler reference is dead");
    JSVM_Value nullVal = MakeNull(env);
    return nullVal;
  }

  napi_value arg = nullptr;
  napi_create_string_utf8(arkEnv, msgJson.c_str(), msgJson.size(), &arg);
  napi_value undefined = nullptr;
  napi_get_undefined(arkEnv, &undefined);
  napi_value ret = nullptr;
  napi_status callStatus = napi_call_function(arkEnv, undefined, handlerFn, 1, &arg, &ret);

  if (callStatus != napi_ok || ret == nullptr) {
    // 处理器同步抛错: 记录原始报文便于定位, 再转成 JS 侧异常
    std::string message = "sendMessage handler failed";
    napi_value lastError = nullptr;
    if (napi_get_and_clear_last_exception(arkEnv, &lastError) == napi_ok && lastError != nullptr) {
      message = NapiErrorText(arkEnv, lastError);
    }
    VN_LOGE("sendMessage handler threw: %s | payload=%.200s", message.c_str(), msgJson.c_str());
    OH_JSVM_ThrowError(env, nullptr, message.c_str());
    return nullptr;
  }

  bool isPromise = false;
  napi_is_promise(arkEnv, ret, &isPromise);
  if (!isPromise) {
    // 同步方法: 直接返回结果
    std::string json = IsNapiString(arkEnv, ret) ? NapiString(arkEnv, ret) : std::string();
    if (json.empty()) {
      json = "null";
    }
    return JsonToJs(env, json);
  }

  // 异步方法: 创建 JS promise, 等 ArkTS 完成后回填
  JSVM_Value promise = nullptr;
  JSVM_Deferred deferred = nullptr;
  if (OH_JSVM_CreatePromise(env, &deferred, &promise) != JSVM_OK) {
    VN_LOGE("create JS promise failed");
    return nullptr;
  }

  // 回调结构体需长期有效(引擎会在后续调用时读取 data), 故意不释放
  SendPending *pending = new SendPending();
  pending->env = env;
  pending->deferred = deferred;

  napi_value thenFn = nullptr;
  napi_get_named_property(arkEnv, ret, "then", &thenFn);
  napi_value onOk = nullptr;
  napi_value onErr = nullptr;
  napi_create_function(arkEnv, "onOk", NAPI_AUTO_LENGTH, NapiResolveJs, pending, &onOk);
  napi_create_function(arkEnv, "onErr", NAPI_AUTO_LENGTH, NapiRejectJs, pending, &onErr);
  napi_value thenArgs[2] = {onOk, onErr};
  napi_value ignored = nullptr;
  if (napi_call_function(arkEnv, ret, thenFn, 2, thenArgs, &ignored) != napi_ok) {
    VN_LOGE("attach ArkTS promise callback failed");
    SettleJsPromise(env, deferred, "null");
  }
  return promise;
}

// JSVM_CallbackStruct 必须长期有效, 故用静态常量(引擎会持有指针)
JSVM_CallbackStruct kSendMessageCb = {JsSendMessage, nullptr};

std::string InstallGlobals(const std::string &appVersion) {
  JSVM_Env env = g_rt.env;
  JSVM_Value global = nullptr;
  if (OH_JSVM_GetGlobal(env, &global) != JSVM_OK) {
    return "get global failed";
  }
  JSVM_Value fn = nullptr;
  if (OH_JSVM_CreateFunction(env, "sendMessage", NAPI_AUTO_LENGTH, &kSendMessageCb, &fn) != JSVM_OK) {
    return std::string("create sendMessage failed: ") + LastJsError(env);
  }
  if (OH_JSVM_SetNamedProperty(env, global, "sendMessage", fn) != JSVM_OK) {
    return std::string("set sendMessage failed: ") + LastJsError(env);
  }
  JSVM_Value version = nullptr;
  OH_JSVM_CreateStringUtf8(env, appVersion.c_str(), appVersion.size(), &version);
  OH_JSVM_SetNamedProperty(env, global, "appVersion", version);
  return std::string();
}

JSVM_Script CompileScript(const std::string &source, const std::string &name, std::string &error) {
  JSVM_Env env = g_rt.env;
  JSVM_Value src = nullptr;
  if (OH_JSVM_CreateStringUtf8(env, source.c_str(), source.size(), &src) != JSVM_OK) {
    error = "create source string failed";
    return nullptr;
  }
  JSVM_Script script = nullptr;
  if (OH_JSVM_CompileScript(env, src, nullptr, 0, true, nullptr, &script) != JSVM_OK) {
    error = std::string("compile [") + name + "] failed: " + LastJsError(env);
    return nullptr;
  }
  return script;
}

}  // namespace

std::string InitRuntime(const std::string &initJs, const std::string &appVersion) {
  if (g_rt.ready) {
    return std::string();
  }
  if (g_rt.vmCreated) {
    return "JS runtime is initializing";
  }

  JSVM_InitOptions initOptions{};
  JSVM_Status st = OH_JSVM_Init(&initOptions);
  if (st != JSVM_OK) {
    return std::string("OH_JSVM_Init failed, status=") + std::to_string(static_cast<int>(st));
  }

  JSVM_CreateVMOptions vmOptions{};
  st = OH_JSVM_CreateVM(&vmOptions, &g_rt.vm);
  if (st != JSVM_OK || g_rt.vm == nullptr) {
    return std::string("OH_JSVM_CreateVM failed, status=") + std::to_string(static_cast<int>(st));
  }
  g_rt.vmCreated = true;

  st = OH_JSVM_OpenVMScope(g_rt.vm, &g_rt.vmScope);
  if (st != JSVM_OK) {
    return std::string("OH_JSVM_OpenVMScope failed, status=") + std::to_string(static_cast<int>(st));
  }

  st = OH_JSVM_CreateEnv(g_rt.vm, 0, nullptr, &g_rt.env);
  if (st != JSVM_OK || g_rt.env == nullptr) {
    return std::string("OH_JSVM_CreateEnv failed, status=") + std::to_string(static_cast<int>(st));
  }

  st = OH_JSVM_OpenEnvScope(g_rt.env, &g_rt.envScope);
  if (st != JSVM_OK) {
    return std::string("OH_JSVM_OpenEnvScope failed, status=") + std::to_string(static_cast<int>(st));
  }

  JSVM_HandleScope hs = nullptr;
  OH_JSVM_OpenHandleScope(g_rt.env, &hs);

  std::string globalsError = InstallGlobals(appVersion);
  if (!globalsError.empty()) {
    OH_JSVM_CloseHandleScope(g_rt.env, hs);
    return globalsError;
  }

  std::string compileError;
  JSVM_Script script = CompileScript(initJs, "<init>", compileError);
  if (script == nullptr) {
    OH_JSVM_CloseHandleScope(g_rt.env, hs);
    return compileError;
  }

  JSVM_Value result = nullptr;
  st = OH_JSVM_RunScript(g_rt.env, script, &result);
  if (st != JSVM_OK) {
    std::string error = std::string("run init.js failed: ") + LastJsError(g_rt.env);
    OH_JSVM_CloseHandleScope(g_rt.env, hs);
    return error;
  }

  OH_JSVM_CloseHandleScope(g_rt.env, hs);
  g_rt.ready = true;
  VN_LOGI("JS runtime ready, init.js size=%{public}zu", initJs.size());
  return std::string();
}

void SetMessageHandler(napi_env env, napi_value handler) {
  if (g_rt.handlerRef != nullptr) {
    napi_delete_reference(env, g_rt.handlerRef);
    g_rt.handlerRef = nullptr;
  }
  if (handler != nullptr) {
    napi_valuetype t = napi_undefined;
    napi_typeof(env, handler, &t);
    if (t == napi_function) {
      napi_create_reference(env, handler, 1, &g_rt.handlerRef);
    }
  }
  g_rt.arkEnv = env;
  VN_LOGI("sendMessage handler %{public}s", g_rt.handlerRef != nullptr ? "registered" : "cleared");
}

napi_value Eval(napi_env env, const std::string &source, const std::string &name) {
  napi_deferred deferred = nullptr;
  napi_value promise = nullptr;
  napi_create_promise(env, &deferred, &promise);

  if (!g_rt.ready) {
    RejectArk(env, deferred, "JS runtime not initialized");
    return promise;
  }
  if (!g_rt.inMicrotask) {
    // 正常路径: 从 ArkTS 主线程进入
  }

  ArkPending *pending = new ArkPending();
  pending->env = env;
  pending->deferred = deferred;

  JSVM_HandleScope hs = nullptr;
  OH_JSVM_OpenHandleScope(g_rt.env, &hs);

  std::string compileError;
  JSVM_Script script = CompileScript(source, name, compileError);
  if (script == nullptr) {
    OH_JSVM_CloseHandleScope(g_rt.env, hs);
    RejectArk(env, deferred, compileError);
    return promise;
  }

  JSVM_Value result = nullptr;
  if (OH_JSVM_RunScript(g_rt.env, script, &result) != JSVM_OK) {
    std::string error = std::string("run [") + name + "] failed: " + LastJsError(g_rt.env);
    OH_JSVM_CloseHandleScope(g_rt.env, hs);
    RejectArk(env, deferred, error);
    return promise;
  }

  bool isPromise = false;
  OH_JSVM_IsPromise(g_rt.env, result, &isPromise);
  if (!isPromise) {
    std::string json;
    if (result != nullptr) {
      AppendJson(g_rt.env, result, json, 0);
    }
    OH_JSVM_CloseHandleScope(g_rt.env, hs);
    ResolveArkJson(env, deferred, json.empty() ? "null" : json);
    PumpMicrotasks();
    return promise;
  }

  // JSVM_CallbackStruct 必须长期有效, 故堆分配且不释放
  JSVM_CallbackStruct *onOkCb = new JSVM_CallbackStruct{JsPromiseResolved, pending};
  JSVM_CallbackStruct *onErrCb = new JSVM_CallbackStruct{JsPromiseRejected, pending};
  JSVM_Value onOk = nullptr;
  JSVM_Value onErr = nullptr;
  OH_JSVM_CreateFunction(g_rt.env, "onResolved", NAPI_AUTO_LENGTH, onOkCb, &onOk);
  OH_JSVM_CreateFunction(g_rt.env, "onRejected", NAPI_AUTO_LENGTH, onErrCb, &onErr);

  JSVM_Value thenFn = nullptr;
  OH_JSVM_GetNamedProperty(g_rt.env, result, "then", &thenFn);
  JSVM_Value thenArgs[2] = {onOk, onErr};
  JSVM_Value ignored = nullptr;
  JSVM_Status callSt = OH_JSVM_CallFunction(g_rt.env, result, thenFn, 2, thenArgs, &ignored);
  OH_JSVM_CloseHandleScope(g_rt.env, hs);

  if (callSt != JSVM_OK) {
    RejectArk(env, deferred, std::string("attach promise handler failed: ") + LastJsError(g_rt.env));
    return promise;
  }
  PumpMicrotasks();
  return promise;
}

bool IsReady() {
  return g_rt.ready;
}

void DisposeRuntime() {
  if (g_rt.handlerRef != nullptr && g_rt.arkEnv != nullptr) {
    napi_delete_reference(g_rt.arkEnv, g_rt.handlerRef);
    g_rt.handlerRef = nullptr;
  }
  if (g_rt.env != nullptr) {
    if (g_rt.envScope != nullptr) {
      OH_JSVM_CloseEnvScope(g_rt.env, g_rt.envScope);
      g_rt.envScope = nullptr;
    }
    OH_JSVM_DestroyEnv(g_rt.env);
    g_rt.env = nullptr;
  }
  if (g_rt.vm != nullptr) {
    if (g_rt.vmScope != nullptr) {
      OH_JSVM_CloseVMScope(g_rt.vm, g_rt.vmScope);
      g_rt.vmScope = nullptr;
    }
    OH_JSVM_DestroyVM(g_rt.vm);
    g_rt.vm = nullptr;
  }
  g_rt.vmCreated = false;
  g_rt.ready = false;
  VN_LOGI("JS runtime disposed");
}

}  // namespace vn
