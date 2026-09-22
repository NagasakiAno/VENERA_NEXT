/**
 * VeneraNext JSVM 运行时 native 接口
 */

/**
 * 初始化 JS 运行时并执行 init.js
 * @param initJs init.js 源码
 * @param appVersion 注入到 JS 全局的 appVersion
 * @returns 空串表示成功, 否则为失败原因
 */
export const initRuntime: (initJs: string, appVersion: string) => string;

/**
 * 注册 sendMessage 处理器
 * @param handler 入参为 message 的 JSON 字符串。
 *   返回 JSON 字符串表示同步结果(load_data/convert 等),
 *   返回 Promise<JSON 字符串> 表示异步结果(http/delay 等), 与原版 sendMessage 语义一致。
 */
export const setMessageHandler: (handler: (messageJson: string) => string | Promise<string>) => void;

/**
 * 执行 JS 代码
 * @param code 源码
 * @param name 调试用名称
 * @returns resolve 为执行结果的 JSON 字符串, reject 为错误信息
 */
export const evalScript: (code: string, name: string) => Promise<string>;

/** 运行时是否已就绪 */
export const isReady: () => boolean;

/** 释放运行时 */
export const disposeRuntime: () => void;
