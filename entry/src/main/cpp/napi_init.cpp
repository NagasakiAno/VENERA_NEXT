/*
 * VeneraNext Native 模块入口 (libentry.so)
 *
 * 对 ArkTS 暴露的接口见 types/libentry/index.d.ts
 */
#include <string>

#include "jsvm_engine.h"
#include "napi/native_api.h"

namespace {

napi_value ThrowIfFatal(napi_env env, const std::string &message) {
  napi_throw_error(env, nullptr, message.c_str());
  return nullptr;
}

/** initRuntime(initJs: string, appVersion: string): string  —— 空串表示成功 */
napi_value InitRuntime(napi_env env, napi_callback_info info) {
  size_t argc = 2;
  napi_value argv[2] = {nullptr, nullptr};
  napi_get_cb_info(env, info, &argc, argv, nullptr, nullptr);

  if (argc < 1 || argv[0] == nullptr) {
    return ThrowIfFatal(env, "initRuntime requires initJs");
  }
  std::string initJs;
  size_t len = 0;
  napi_get_value_string_utf8(env, argv[0], nullptr, 0, &len);
  initJs.resize(len);
  napi_get_value_string_utf8(env, argv[0], &initJs[0], len + 1, &len);
  initJs.resize(len);

  std::string appVersion = "0.0.0";
  if (argc > 1 && argv[1] != nullptr) {
    size_t vlen = 0;
    if (napi_get_value_string_utf8(env, argv[1], nullptr, 0, &vlen) == napi_ok && vlen > 0) {
      appVersion.resize(vlen);
      napi_get_value_string_utf8(env, argv[1], &appVersion[0], vlen + 1, &vlen);
      appVersion.resize(vlen);
    }
  }

  std::string error = vn::InitRuntime(initJs, appVersion);
  napi_value result = nullptr;
  napi_create_string_utf8(env, error.c_str(), error.size(), &result);
  return result;
}

/** setMessageHandler(handler: (messageJson: string) => Promise<string>): void */
napi_value SetMessageHandler(napi_env env, napi_callback_info info) {
  size_t argc = 1;
  napi_value argv[1] = {nullptr};
  napi_get_cb_info(env, info, &argc, argv, nullptr, nullptr);
  vn::SetMessageHandler(env, argc > 0 ? argv[0] : nullptr);
  return nullptr;
}

/** evalScript(code: string, name: string): Promise<string> */
napi_value EvalScript(napi_env env, napi_callback_info info) {
  size_t argc = 2;
  napi_value argv[2] = {nullptr, nullptr};
  napi_get_cb_info(env, info, &argc, argv, nullptr, nullptr);

  std::string code;
  if (argc > 0 && argv[0] != nullptr) {
    size_t len = 0;
    napi_get_value_string_utf8(env, argv[0], nullptr, 0, &len);
    code.resize(len);
    napi_get_value_string_utf8(env, argv[0], &code[0], len + 1, &len);
    code.resize(len);
  }

  std::string name = "<eval>";
  if (argc > 1 && argv[1] != nullptr) {
    size_t nlen = 0;
    if (napi_get_value_string_utf8(env, argv[1], nullptr, 0, &nlen) == napi_ok && nlen > 0) {
      name.resize(nlen);
      napi_get_value_string_utf8(env, argv[1], &name[0], nlen + 1, &nlen);
      name.resize(nlen);
    }
  }

  return vn::Eval(env, code, name);
}

/** isReady(): boolean */
napi_value IsReady(napi_env env, napi_callback_info info) {
  napi_value result = nullptr;
  napi_get_boolean(env, vn::IsReady(), &result);
  return result;
}

/** disposeRuntime(): void */
napi_value DisposeRuntime(napi_env env, napi_callback_info info) {
  vn::DisposeRuntime();
  return nullptr;
}

napi_value Init(napi_env env, napi_value exports) {
  napi_property_descriptor desc[] = {
      {"initRuntime", nullptr, InitRuntime, nullptr, nullptr, nullptr, napi_default, nullptr},
      {"setMessageHandler", nullptr, SetMessageHandler, nullptr, nullptr, nullptr, napi_default, nullptr},
      {"evalScript", nullptr, EvalScript, nullptr, nullptr, nullptr, napi_default, nullptr},
      {"isReady", nullptr, IsReady, nullptr, nullptr, nullptr, napi_default, nullptr},
      {"disposeRuntime", nullptr, DisposeRuntime, nullptr, nullptr, nullptr, napi_default, nullptr},
  };
  napi_define_properties(env, exports, sizeof(desc) / sizeof(desc[0]), desc);
  return exports;
}

}  // namespace

static napi_module entryModule = {
    1,          // nm_version
    0,          // nm_flags
    nullptr,    // nm_filename
    Init,       // nm_register_func
    "entry",    // nm_modname
    nullptr,    // nm_priv
    {0},        // reserved
};

extern "C" __attribute__((constructor)) void RegisterEntryModule(void) {
  napi_module_register(&entryModule);
}
