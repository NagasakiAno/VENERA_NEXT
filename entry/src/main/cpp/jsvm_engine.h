/*
 * VeneraNext JSVM 运行时 (B 阶段: 真 JS 引擎 + sendMessage 桥)
 *
 * 用鸿蒙官方 JSVM-API 创建独立 JS 运行时执行漫画源脚本, 并与 ArkTS 侧通过
 * Node-API 双向通信: JS 的 sendMessage() 转发给 ArkTS 处理器, 异步结果再
 * resolve 回 JS 侧 Promise。
 */
#ifndef VENERA_JSVM_ENGINE_H
#define VENERA_JSVM_ENGINE_H

#include <string>

#include "napi/native_api.h"

namespace vn {

/**
 * 初始化 JSVM 运行时并执行 init.js。
 * @param initJs init.js 源码
 * @param appVersion 注入到 JS 全局的 appVersion
 * @return 空串表示成功, 否则为失败原因
 */
std::string InitRuntime(const std::string &initJs, const std::string &appVersion);

/**
 * 注册 ArkTS 侧 sendMessage 处理器。
 * 处理器签名: (messageJson: string) => Promise<string> | string
 * 返回值为 JSON 字符串, 解析后作为 JS 侧 sendMessage 的返回值。
 */
void SetMessageHandler(napi_env env, napi_value handler);

/**
 * 执行一段 JS 代码。
 * @return napi Promise<string>, resolve 为 JSON 化的执行结果, reject 为错误信息
 */
napi_value Eval(napi_env env, const std::string &source, const std::string &name);

/** 运行时是否已就绪 */
bool IsReady();

/** 释放运行时(仅用于页面退出/重置, 进程内一般不用) */
void DisposeRuntime();

}  // namespace vn

#endif  // VENERA_JSVM_ENGINE_H
