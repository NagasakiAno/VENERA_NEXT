/**
 * VeneraNext 网络层封装
 * 对应 Flutter 版 network/app_dio.dart, 基于官方 @ohos.net.http 实现
 */
import { http } from '@kit.NetworkKit';
import { util } from '@kit.ArkTS';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { cookieStore } from './CookieStore';

const DOMAIN = 0x0000;
const TAG = 'HttpClient';
/** 源未指定 UA 时的默认值, 与原版 consts.dart 的 webUA 保持一致(不少网页源按 UA 返回不同页面) */
const DEFAULT_UA = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/119.0.0.0 Safari/537.36';

/** 日志截断 */
function truncate(text: string, max: number): string {
  return text.length > max ? text.substring(0, max) + '...' : text;
}

/** HTTP 方法 */
export enum HttpMethod {
  GET = 'GET',
  POST = 'POST',
  PUT = 'PUT',
  DELETE = 'DELETE'
}

/** 响应体类型 */
export enum ResponseType {
  /** 文本(JSON/HTML) */
  TEXT = 0,
  /** 二进制字节流 */
  BYTES = 1
}

/** 请求配置 */
export interface HttpRequest {
  url: string;
  method?: HttpMethod;
  headers?: Record<string, string>;
  body?: string;
  /** 二进制请求体(优先于 body), 供 JS 源的 ArrayBuffer 请求体使用 */
  bodyBytes?: ArrayBuffer;
  responseType?: ResponseType;
  /** 超时(ms) */
  timeout?: number;
}

/** http 请求结果, 字段命名与漫画源源生态一致 */
export interface HttpResponseData {
  status: number;
  headers: Record<string, string>;
  /** 文本响应 */
  body: string;
  /** 二进制响应 (由 body 的 base64 还原, 见 [bytes]) */
  bodyBase64: string;
  error: string;
}

/** 单例 HttpClient 封装, 每个请求新建并销毁 http.HttpRequestTask */
export class HttpClient {
  private static instance: HttpClient = new HttpClient();

  static getInstance(): HttpClient {
    return HttpClient.instance;
  }

  /** 发起一次请求, 返回解析后的结果 */
  async request<T>(req: HttpRequest): Promise<T> {
    const resp = await this.rawRequest(req);
    if (resp.error) {
      throw new Error(resp.error);
    }
    if (req.responseType === ResponseType.BYTES) {
      // 返回 Uint8Array
      const b64 = new util.Base64Helper();
      const u8 = b64.decodeSync(resp.bodyBase64);
      return u8 as T;
    }
    return resp.body as T;
  }

  /** 将 http.RequestMethod 与自定义枚举对齐的内部映射 */
  private mapMethod(method: HttpMethod): http.RequestMethod {
    switch (method) {
      case HttpMethod.POST:
        return http.RequestMethod.POST;
      case HttpMethod.PUT:
        return http.RequestMethod.PUT;
      case HttpMethod.DELETE:
        return http.RequestMethod.DELETE;
      default:
        return http.RequestMethod.GET;
    }
  }

  /**
   * 发起请求并返回完整响应, 忽略错误, 由调用方检查
   * 对应 Flutter 版 JsEngine._http 的返回结构
   */
  async rawRequest(req: HttpRequest): Promise<HttpResponseData> {
    const httpTask = http.createHttp();
    const result: HttpResponseData = {
      status: 0,
      headers: {},
      body: '',
      bodyBase64: '',
      error: ''
    };
    try {
      const header: Record<string, string> = {};
      const rawHeaders = req.headers ?? {};
      Object.keys(rawHeaders).forEach((k: string) => {
        const v = rawHeaders[k];
        // 源脚本常把 loadData 的结果直接塞进 header, 可能为 null/undefined;
        // 这类值传给鸿蒙 http 会在内部抛 "charAt is not callable", 必须过滤掉
        if (typeof v === 'string' && v.length > 0) {
          header[k] = v;
        } else if (typeof v === 'number' || typeof v === 'boolean') {
          header[k] = `${v}`;
        }
      });
      if (!header['accept-encoding'] && !header['Accept-Encoding']) {
        // 鸿蒙 http 不自动解压 gzip, 强制要求未压缩响应(或允许, 由调用方处理)
        header['Accept-Encoding'] = 'identity';
      }
      if (!header['user-agent'] && !header['User-Agent']) {
        header['User-Agent'] = DEFAULT_UA;
      }
      // 注入 Cookie(调用方未显式指定时), 对应原版 CookieManager 拦截器
      const cookieHeader = cookieStore.headerFor(req.url);
      if (cookieHeader.length > 0 && !header['Cookie'] && !header['cookie']) {
        header['Cookie'] = cookieHeader;
      }
      const method = this.mapMethod(req.method ?? HttpMethod.GET);
      const options: http.HttpRequestOptions = {
        method: method,
        header: header,
        // 统一用 ARRAY_BUFFER 取原始字节, 手动解码, 规避 http STRING 模式的编码隐患
        expectDataType: http.HttpDataType.ARRAY_BUFFER,
        connectTimeout: req.timeout ?? 15000,
        readTimeout: req.timeout ?? 15000,
        usingCache: false
      };
      // extraData 只有 POST/PUT 才作为请求体; 其余方法会被系统当作「参数补充」
      // 拼接到 URL 上(即使传空串也会多一个 &), 会破坏源脚本基于完整 URL 计算的
      // 签名(picacg 的 HMAC 就因此校验失败, 返回 200 但无 data), 所以必须不传。
      if (method === http.RequestMethod.POST || method === http.RequestMethod.PUT) {
        options.extraData = req.bodyBytes ?? req.body ?? '';
      }
      const response = await httpTask.request(req.url, options);
      result.status = response.responseCode;
      // 响应头
      const respHeaders = response.header as Record<string, string>;
      if (respHeaders) {
        Object.keys(respHeaders).forEach((k: string) => {
          const v = respHeaders[k];
          // 鸿蒙 http 对多值响应头(如 set-cookie)返回数组, 统一转成字符串保存
          if (typeof v === 'string') {
            result.headers[k.toLowerCase()] = v as string;
          } else if (Array.isArray(v)) {
            const parts: string[] = [];
            const arr = v as Object[];
            for (let i = 0; i < arr.length; i++) {
              parts.push(`${arr[i]}`);
            }
            result.headers[k.toLowerCase()] = parts.join(', ');
          } else if (v !== undefined && v !== null) {
            result.headers[k.toLowerCase()] = `${v}`;
          }
        });
        // 写入响应携带的 Set-Cookie
        cookieStore.applyResponseHeaders(req.url, respHeaders);
      }
      const raw = response.result;
      const buf = raw as ArrayBuffer;
      const u8 = new Uint8Array(buf);
      if (req.responseType === ResponseType.BYTES) {
        const b64 = new util.Base64Helper();
        result.bodyBase64 = b64.encodeToStringSync(u8);
      } else {
        // 手动 UTF-8 解码
        const decoder = new util.TextDecoder();
        result.body = decoder.decodeToString(u8);
      }
    } catch (e) {
      const er = e as Error;
      result.error = (er && er.message && er.message.length > 0 && er.message !== 'undefined')
        ? er.message : `${e}`;
      // 鸿蒙网络错误通常带 code(如 2300006=域名解析失败), 对定位很关键
      const code = (e as Record<string, Object>)['code'];
      const codeText = (typeof code === 'number' || typeof code === 'string') ? `${code}` : '-';
      const detail = (er && er.stack && er.stack.length > 0) ? er.stack : `${e}`;
      hilog.error(DOMAIN, TAG, 'request failed: %{public}s | code=%{public}s | detail=%{public}s | url=%{public}s',
        result.error, codeText, truncate(detail, 200), req.url);
    } finally {
      httpTask.destroy();
    }
    return result;
  }
}

/** 全局单例 */
export const httpClient = HttpClient.getInstance();