/**
 * VeneraNext JS 运行时 (B 阶段)
 *
 * 职责:
 *   1. 加载 rawfile/init.js 并交给 native JSVM 执行, 得到运行时库(Convert/Network/Html/ComicSource...)
 *   2. 注册 sendMessage 处理器, 承接 JS 源脚本对 App 能力的所有请求
 *   3. 对上层提供 eval(code) 执行源脚本能力
 *
 * 数据流: ArkTS ──eval──▶ JSVM ──sendMessage──▶ 本文件分发 ──▶ 网络/存储/加密 ──▶ 回填 JS Promise
 */
import libentry from 'libentry.so';
import { common } from '@kit.AbilityKit';
import { fileIo as fs } from '@kit.CoreFileKit';
import { util } from '@kit.ArkTS';
import { cryptoFramework } from '@kit.CryptoArchitectureKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { httpClient, HttpMethod, ResponseType } from '../network/HttpClient';
import { cookieStore, Cookie } from '../network/CookieStore';
import { comicSourceManager } from '../model/ComicSource';
import { ComicSourceMeta, SettingDef, ExplorePageInfo, CategoryMeta, CategoryPart,
  CategoryItem, CategoryTarget, SearchOptionDef } from '../model/sources/ComicSourceMeta';
import { sourceDataStore } from '../services/SourceDataStore';
import { htmlBridge, HtmlRequest } from './HtmlBridge';
import { imageBridge } from './ImageBridge';
import { readHistoryService } from '../services/ReadHistoryService';

const DOMAIN = 0x0000;
const TAG = 'JsRuntime';

/** 诊断脚本: 验证 类继承 / 源数据读写 / 编码转换 / 网络 四条桥 */
const DIAGNOSE_SCRIPT = `
(async () => {
  class DiagSource extends ComicSource {
    key = 'vn_diag'
    name = 'Diag'
    version = '1.0.0'
  }
  const inst = new DiagSource()
  await inst.saveData('probe', { n: 42, s: 'hello' })
  const back = await inst.loadData('probe')
  const roundTrip = await Convert.decodeUtf8(await Convert.encodeUtf8('venera'))
  const resp = await Network.get(
    'https://cdn.jsdelivr.net/gh/venera-app/venera-configs@main/index.json', {})
  return {
    key: inst.key,
    savedN: back.n,
    savedS: back.s,
    roundTrip: roundTrip,
    httpStatus: resp.status,
    bodyLen: resp.body.length
  }
})()`;

/** 诊断脚本: Cookie 桥 set/get/delete 往返 */
const COOKIE_PROBE_SCRIPT = `
(async () => {
  const probeUrl = 'https://probe.venera.test/diag'
  Network.setCookies(probeUrl, [{ name: 'vn_probe', value: 'ok', domain: 'probe.venera.test' }])
  await new Promise((r) => setTimeout(r, 50))
  const list = await Network.getCookies(probeUrl)
  let hit = 0
  for (const c of list) { if (c.name === 'vn_probe' && c.value === 'ok') { hit++ } }
  Network.deleteCookies(probeUrl)
  await new Promise((r) => setTimeout(r, 50))
  const after = await Network.getCookies(probeUrl)
  let remain = 0
  for (const c of after) { if (c.name === 'vn_probe') { remain++ } }
  return { set: hit, remainAfterDelete: remain, total: list.length }
})()`;

/** 诊断脚本: HTML DOM 桥(解析 / 选择器 / 属性 / 节点关系) */
const HTML_PROBE_SCRIPT = `
(() => {
  const src = '<div class="box"><ul id="l"><li class="x" data-v="1">A</li><li class="x">B</li></ul></div>'
  const doc = new HtmlDocument(src)
  const items = doc.querySelectorAll('ul#l > li.x')
  const texts = items.map((e) => e.text.trim())
  const attr = items[0].attributes['data-v']
  const parent = items[0].parent.localName
  const byId = doc.getElementById('l').localName
  const first = doc.querySelector('li:first-child').text.trim()
  const innerLen = doc.querySelector('.box').innerHTML.length
  const sibling = items[0].nextElementSibling.text.trim()
  doc.dispose()
  return {
    count: items.length, texts: texts, attr: attr, parent: parent,
    byId: byId, first: first, sibling: sibling, innerLen: innerLen
  }
})()`;

/** 诊断脚本: Convert 桥(gbk 往返 / sha256 标准测试向量) */
const CONVERT_PROBE_SCRIPT = `
(() => {
  const gbkBytes = Convert.encodeGbk('中文abc')
  const back = Convert.decodeGbk(gbkBytes)
  const sha = Convert.sha256('abc')
  const bytes = new Uint8Array(sha)
  let hex = ''
  for (const b of bytes) { hex += b.toString(16).padStart(2, '0') }
  return {
    gbkRoundTrip: back,
    gbkLen: new Uint8Array(gbkBytes).length,
    gbkTag: Object.prototype.toString.call(gbkBytes),
    shaType: Object.prototype.toString.call(sha),
    sha256: hex
  }
})()`;

/** 诊断: 源脚本加载结果 */
interface ProbeSourceInfo {
  key: string;
  name: string;
  version: string;
  settings: string;
}

/** 日志截断, 避免超长脚本内容刷屏 */
function truncate(text: string, max: number): string {
  return text.length > max ? text.substring(0, max) + '...' : text;
}

/** message.key 作为源 key(字符串) 取值 */
function strKeyOf(msg: BridgeMessage): string {
  const k = msg.key;
  return typeof k === 'string' ? (k as string) : '';
}

/** message 中取数字字段(html 桥的 key/doc) */
function numOf(value: Object | undefined): number {
  return typeof value === 'number' ? (value as number) : 0;
}

/** message 中取字符串字段 */
function strOf(value: Object | undefined): string {
  return typeof value === 'string' ? (value as string) : '';
}

/** sendMessage 报文结构(与 assets/init.js 对应) */
interface BridgeMessage {
  method?: string;
  // log
  level?: string;
  title?: string;
  content?: string;
  // data
  /** 源 key(字符串) 或 html 桥的文档 key(数字), 由 method 决定语义 */
  key?: Object;
  data_key?: string;
  data?: Object;
  setting_key?: string;
  // html 桥
  doc?: Object;
  query?: string;
  id?: string;
  // http
  url?: string;
  http_method?: string;
  headers?: Object;
  extra?: Object;
  bytes?: boolean;
  // convert
  type?: string;
  value?: Object;
  isEncode?: boolean;
  hash?: string;
  isString?: boolean;
  iv?: Object;
  blockSize?: number;
  // random / delay
  min?: number;
  max?: number;
  time?: number;
  userId?: string;
  /** cookie 桥 */
  cookies?: Object;
  /** 其它 */
  function?: string;
}

/** http 响应(与 JS 侧 Network 约定一致) */
interface HttpResult {
  status: number;
  headers: Record<string, string>;
  body: Object;
  error: string;
}

/** 真引擎读出的设置定义(title/type/选项已字符串化, default 保留原始类型) */
interface RawSettingDef {
  title: string;
  type: string;
  default: Object | null;
  options: string[];
  labels: string[];
}

/** 真引擎读出的发现页定义 */
interface RawExplorePage {
  title: string;
  type: string;
  hasLoad: boolean;
  hasLoadNext: boolean;
}

/** 真引擎读出的分类项跳转目标 */
interface RawCategoryTarget {
  page: string;
  category: string;
  param: string;
  keyword: string;
}

/** 真引擎读出的分类项(注意 target 是嵌套对象) */
interface RawCategoryItem {
  label: string;
  target: RawCategoryTarget;
}

/** 真引擎读出的分类分组 */
interface RawCategoryPart {
  name: string;
  type: string;
  randomNumber: number;
  items: RawCategoryItem[];
}

/** 真引擎读出的分类配置 */
interface RawCategoryMeta {
  title: string;
  enableRanking: boolean;
  hasCategoryComics: boolean;
  parts: RawCategoryPart[];
  options: RawSearchOption[];
}

/** 真引擎读出的搜索选项组 */
interface RawSearchOption {
  label: string;
  type: string;
  options: string[];
  default: string;
}

/** 真引擎读出的搜索能力 */
interface RawSearchMeta {
  options: RawSearchOption[];
  hasLoad: boolean;
  hasLoadNext: boolean;
  /** comic.idMatch: 漫画 ID 规则(空串表示源未声明) */
  idMatch: string;
  /** comic.loadInfo 是否真实存在 */
  hasLoadInfo: boolean;
}

/**
 * JS 侧解析 optionList 的片段(search.optionList 与 categoryComics.optionList 同构):
 * 生成 __parseOptions(list) 函数, 每项为 {label, type, options: string[], default}
 */
const OPTION_LIST_JS = ' const __parseOptions = (list) => {'
  + ' const out = [];'
  + ' for (const g of (list || [])) {'
  + '   const opts = [];'
  + '   for (const o of (g.options || [])) { if (typeof o === "string" && o.length > 0) { opts.push(o); } }'
  + '   const d = g.default;'
  + '   let dv = "";'
  + '   if (typeof d === "string") { dv = d; }'
  + '   else if (Array.isArray(d) && d.length > 0) { dv = String(d[0]); }'
  + '   else if (d !== undefined && d !== null) { dv = String(d); }'
  + '   out.push({ label: g.label === undefined ? "" : String(g.label),'
  + '     type: g.type === undefined ? "select" : String(g.type),'
  + '     options: opts, default: dv }); }'
  + ' return out; };';

/** RawSearchOption[] -> SearchOptionDef[] */
function toOptionDefs(raw: RawSearchOption[]): SearchOptionDef[] {
  const list: SearchOptionDef[] = [];
  for (let i = 0; i < raw.length; i++) {
    const r = raw[i];
    const def = new SearchOptionDef();
    def.label = r.label.length > 0 ? r.label : ('选项 ' + (i + 1).toString());
    def.type = r.type;
    def.defaultValue = r.default;
    for (let j = 0; j < r.options.length; j++) {
      const rawOption = r.options[j];
      const dash = rawOption.indexOf('-');
      if (dash <= 0) {
        continue;
      }
      def.options.set(rawOption.substring(0, dash), rawOption.substring(dash + 1));
    }
    list.push(def);
  }
  return list;
}

/** 诊断/探测失败时的报告 */
interface DiagError {
  error: string;
  path: string;
}

/** base64 占位对象, C++ 侧会还原成 ArrayBuffer */
interface BytesWrapper {
  __bytes: string;
}

/** 尚未实现的方法只告警一次, 避免刷屏 */
class WarnedMethods {
  private static seen: Set<string> = new Set<string>();

  static warnOnce(method: string): void {
    if (WarnedMethods.seen.has(method)) {
      return;
    }
    WarnedMethods.seen.add(method);
    hilog.warn(DOMAIN, TAG, 'sendMessage 未实现的方法: %{public}s', method);
  }
}

class JsRuntimeImpl {
  private ready: boolean = false;
  private initError: string = '';
  private initTask: Promise<boolean> | null = null;
  /** 已加载进 JS 运行时的源 key(ComicSource.sources 中已注册实例) */
  private loadedSources: Set<string> = new Set<string>();
  /** 加载中的源: 并发调用共享同一 Promise, 避免重复执行源脚本 */
  private loadTasks: Map<string, Promise<void>> = new Map<string, Promise<void>>();

  /** 初始化: 仅执行一次, 并发调用复用同一 Promise */
  init(context: common.Context): Promise<boolean> {
    if (this.initTask !== null) {
      return this.initTask;
    }
    this.initTask = this.doInit(context);
    return this.initTask;
  }

  isReady(): boolean {
    return this.ready;
  }

  lastError(): string {
    return this.initError;
  }

  private async doInit(context: common.Context): Promise<boolean> {
    sourceDataStore.init(context);
    cookieStore.init(context);
    readHistoryService.init(context);
    let initJs = '';
    try {
      const bytes = context.resourceManager.getRawFileContentSync('init.js');
      initJs = util.TextDecoder.create('utf-8').decodeToString(bytes);
    } catch (e) {
      this.initError = '读取 init.js 失败: ' + (e as Error).message;
      hilog.error(DOMAIN, TAG, '%{public}s', this.initError);
      return false;
    }
    if (initJs.length === 0) {
      this.initError = 'init.js 内容为空';
      return false;
    }
    try {
      libentry.setMessageHandler((messageJson: string) => this.handleMessage(messageJson));
      const error = libentry.initRuntime(initJs, '1.6.3');
      if (error.length > 0) {
        this.initError = error;
        hilog.error(DOMAIN, TAG, 'initRuntime 失败: %{public}s', error);
        return false;
      }
      this.ready = true;
      hilog.info(DOMAIN, TAG, 'JS 运行时就绪');
      return true;
    } catch (e) {
      this.initError = 'JS 运行时初始化异常: ' + (e as Error).message;
      hilog.error(DOMAIN, TAG, '%{public}s', this.initError);
      return false;
    }
  }

  /** 执行 JS 代码, 返回 JSON 字符串结果 */
  async eval(code: string, name: string = '<eval>'): Promise<string> {
    if (!this.ready) {
      throw new Error(this.initError.length > 0 ? this.initError : 'JS 运行时未初始化');
    }
    return await libentry.evalScript(code, name);
  }

  /** 执行 JS 代码并解析为指定类型 */
  async evalJson<T>(code: string, name: string = '<eval>'): Promise<T> {
    const raw = await this.eval(code, name);
    return JSON.parse(raw) as T;
  }

  // ============================================================ 运行时诊断

  /**
   * 运行时自检: 验证「类继承 / 源数据读写 / 编码转换 / 网络 / 真实源脚本执行」,
   * 返回 { basic, source } 结构的 JSON 报告。用于验收与故障定位。
   */
  async diagnose(): Promise<string> {
    const basic = await this.safeEval(DIAGNOSE_SCRIPT, '<diagnose>', '基础能力');
    const convert = await this.safeEval(CONVERT_PROBE_SCRIPT, '<convert-probe>', 'Convert 桥');
    const html = await this.safeEval(HTML_PROBE_SCRIPT, '<html-probe>', 'HTML 桥');
    const cookie = await this.safeEval(COOKIE_PROBE_SCRIPT, '<cookie-probe>', 'Cookie 桥');

    let source = 'null';
    const sources = comicSourceManager.allJsSources();
    if (sources.length > 0) {
      const meta = sources[0];
      try {
        await this.loadSource(meta);
        await this.enrichSettings(meta);
        const parts: string[] = [];
        meta.settings.forEach((def: SettingDef, k: string) => {
          parts.push(k + ':' + def.type + (def.options.length > 0 ? '/' + def.options.length : ''));
        });
        const info: ProbeSourceInfo = {
          key: meta.key,
          name: meta.name,
          version: meta.version,
          settings: parts.join(', ')
        };
        source = JSON.stringify(info);
      } catch (e) {
        const failure: DiagError = { error: `${e}`, path: meta.filePath };
        source = JSON.stringify(failure);
        hilog.error(DOMAIN, TAG, '诊断-源脚本执行失败: %{public}s', `${e}`);
      }
    }
    // 清理自检产生的临时源数据, 避免污染沙箱
    sourceDataStore.clear(JsRuntimeImpl.DIAG_KEY);
    return '{"basic":' + basic + ',"convert":' + convert + ',"html":' + html
      + ',"cookie":' + cookie + ',"source":' + source + '}';
  }

  /** 自检源使用的 key(不注册为真实源, 仅用于落盘往返验证) */
  private static readonly DIAG_KEY: string = 'vn_diag';

  /** 执行诊断脚本, 失败时返回错误报告而不是抛出 */
  private async safeEval(script: string, name: string, label: string): Promise<string> {
    try {
      return await this.eval(script, name);
    } catch (e) {
      const failure: DiagError = { error: `${e}`, path: '' };
      hilog.error(DOMAIN, TAG, '诊断-%{public}s 失败: %{public}s', label, `${e}`);
      return JSON.stringify(failure);
    }
  }

  private readTextFile(path: string): string {
    try {
      const file = fs.openSync(path, fs.OpenMode.READ_ONLY);
      const stat = fs.statSync(file.fd);
      const buf = new ArrayBuffer(stat.size);
      fs.readSync(file.fd, buf);
      fs.closeSync(file);
      return util.TextDecoder.create('utf-8').decodeToString(new Uint8Array(buf));
    } catch (e) {
      hilog.error(DOMAIN, TAG, '读取源脚本失败: %{public}s', `${e}`);
      return '';
    }
  }

  // ============================================================ 源加载与调用

  /** 把源脚本加载进 JS 运行时(ComicSource.sources[key] = new Xxx()) */
  loadSource(meta: ComicSourceMeta): Promise<void> {
    if (this.loadedSources.has(meta.key)) {
      return Promise.resolve();
    }
    const running = this.loadTasks.get(meta.key);
    if (running !== undefined) {
      return running;
    }
    const task = this.doLoadSource(meta);
    this.loadTasks.set(meta.key, task);
    return task;
  }

  /**
   * 实际加载流程。完成 init 之后才标记为已就绪,
   * 保证随后调用源方法时源自身的初始化(如拉取可用域名)已经结束。
   */
  private async doLoadSource(meta: ComicSourceMeta): Promise<void> {
    try {
      const text = this.readTextFile(meta.filePath);
      if (text.length === 0) {
        throw new Error('源脚本读取失败: ' + meta.fileName);
      }
      const m = /class\s+(\w+)\s+extends\s+ComicSource/.exec(text);
      if (m === null) {
        throw new Error('源脚本缺少 class 定义: ' + meta.fileName);
      }
      const code = '(function(){\n' + text + '\n;ComicSource.sources['
        + JSON.stringify(meta.key) + '] = new ' + m[1] + '();\n})()';
      await this.eval(code, '<load:' + meta.key + '>');
      // 设置定义必须在 init 之前就绪: 源脚本的 init() 常通过 loadSetting 决定行为
      await this.enrichSettingsInternal(meta);
      await this.runSourceInit(meta.key);
      this.loadedSources.add(meta.key);
      hilog.info(DOMAIN, TAG, '源就绪: %{public}s', meta.key);
    } finally {
      this.loadTasks.delete(meta.key);
    }
  }

  /**
   * 源注册后的 init() 钩子(原版在源加载后调用)。
   * 部分源用它拉取可用 API 域名 / 图片域名, 不调用会导致 baseUrl 为 undefined。
   */
  private async runSourceInit(key: string): Promise<void> {
    const code = '(async () => {'
      + ' const __m = ComicSource.sources[' + JSON.stringify(key) + '];'
      + ' if (__m && typeof __m.init === "function") { await __m.init(); }'
      + ' })()';
    let initError = '';
    try {
      await this.withTimeout(this.eval(code, '<init:' + key + '>'), JsRuntimeImpl.INIT_TIMEOUT_MS);
      hilog.info(DOMAIN, TAG, '源 %{public}s init 完成', key);
    } catch (e) {
      initError = `${e}`;
      hilog.warn(DOMAIN, TAG, '源 %{public}s init 未完成: %{public}s', key, initError);
    }
  }

  /** init 的等待上限: 源可能在 init 里拉取域名列表, 超时后不阻塞后续调用 */
  private static readonly INIT_TIMEOUT_MS: number = 18000;

  /** 给 Promise 加超时(源脚本内部的网络请求可能长时间挂起) */
  private withTimeout(task: Promise<string>, ms: number): Promise<string> {
    return new Promise<string>((resolve: (v: string) => void, reject: (e: Error) => void) => {
      let settled = false;
      const timer = setTimeout(() => {
        if (settled) {
          return;
        }
        settled = true;
        reject(new Error('操作超时 ' + ms.toString() + 'ms'));
      }, ms);
      task.then((value: string) => {
        if (settled) {
          return;
        }
        settled = true;
        clearTimeout(timer);
        resolve(value);
      }).catch((err: Object) => {
        if (settled) {
          return;
        }
        settled = true;
        clearTimeout(timer);
        reject(new Error(`${err}`));
      });
    });
  }

  /** 卸载(源更新/删除后调用), 下次调用时自动重载 */
  unloadSource(key: string): void {
    this.loadedSources.delete(key);
  }

  isSourceLoaded(key: string): boolean {
    return this.loadedSources.has(key);
  }

  /** 确保源已加载, 未加载则从磁盘重新加载; 加载中的源会等待其完成 */
  async ensureLoaded(key: string): Promise<void> {
    if (this.loadedSources.has(key)) {
      return;
    }
    const running = this.loadTasks.get(key);
    if (running !== undefined) {
      return running;
    }
    const meta = comicSourceManager.findJsSource(key);
    if (meta === null) {
      throw new Error('源不存在: ' + key);
    }
    await this.loadSource(meta);
  }

  /**
   * 调用源脚本实例上的表达式(以 __m 指代该实例), 返回结果的 JSON 字符串。
   * 例: callSource('happy', "__m.comic.loadInfo('123')")
   * 源内抛错时会附带 stack, 便于定位到源脚本的具体行。
   */
  async callSource(key: string, expr: string): Promise<string> {
    await this.ensureLoaded(key);
    const code = '(async () => {'
      + ' const __m = ComicSource.sources[' + JSON.stringify(key) + '];'
      + ' if (__m === undefined || __m === null) { throw new Error("源实例不存在"); }'
      + ' try { return await (' + expr + '); }'
      + ' catch (__e) {'
      + '   const __msg = (__e && __e.message) ? __e.message : String(__e);'
      + '   const __stack = (__e && __e.stack) ? __e.stack : "";'
      + '   throw new Error(__stack.length > 0 ? __msg + " | " + __stack : __msg);'
      + ' } })()';
    try {
      return await this.eval(code, '<call:' + key + '>');
    } catch (e) {
      hilog.error(DOMAIN, TAG, '源 %{public}s 调用失败 [%{public}s]: %{public}s', key, expr, `${e}`);
      throw new Error(`${e}`);
    }
  }

  /** 触发源设置中 callback 类型的按钮 */
  async callSettingCallback(key: string, settingKey: string): Promise<string> {
    const expr = '__m.settings[' + JSON.stringify(settingKey) + '].callback()';
    hilog.info(DOMAIN, TAG, '执行源设置回调 %{public}s.%{public}s', key, settingKey);
    const result = await this.callSource(key, expr);
    hilog.info(DOMAIN, TAG, '源设置回调完成 %{public}s.%{public}s -> %{public}s',
      key, settingKey, truncate(result, 120));
    return result;
  }

  /** 账号密码登录: 成功后将 [账号, 密码] 写入源数据(与原版语义一致) */
  async loginWithPassword(key: string, account: string, password: string): Promise<void> {
    const expr = '__m.account.login(' + JSON.stringify(account) + ',' + JSON.stringify(password) + ')';
    await this.callSource(key, expr);
    const pair: Object[] = [account, password];
    sourceDataStore.set(key, 'account', pair);
    hilog.info(DOMAIN, TAG, '源 %{public}s 登录成功(账密)', key);
  }

  /** Cookies 登录: 校验字段通过后写入源数据 */
  async loginWithCookies(key: string, values: string[]): Promise<void> {
    const arr = '[' + values.map((v: string) => JSON.stringify(v)).join(',') + ']';
    await this.callSource(key, '__m.account.loginWithCookies.validate(' + arr + ')');
    const stored: Object[] = values;
    sourceDataStore.set(key, 'account', stored);
  }

  /** 登出: 调用源的 logout 并清除本地账号数据 */
  async logout(key: string): Promise<void> {
    if (this.loadedSources.has(key)) {
      try {
        await this.callSource(key, '__m.account.logout ? __m.account.logout() : null');
      } catch (e) {
        hilog.warn(DOMAIN, TAG, '源 %{public}s 的 logout 调用失败: %{public}s', key, `${e}`);
      }
    }
    sourceDataStore.remove(key, 'account');
  }

  /** 是否已登录(以源数据中是否存在 account 为准) */
  isLogged(key: string): boolean {
    return sourceDataStore.get(key, 'account') !== null;
  }

  /** 当前登录账号名(账密登录时取首元素), 未登录返回空串 */
  loggedAccount(key: string): string {
    const v = sourceDataStore.get(key, 'account');
    if (v === null) {
      return '';
    }
    const arr = v as Object[];
    if (arr.length === 0) {
      return '';
    }
    const first = arr[0];
    return typeof first === 'string' ? (first as string) : '';
  }

  /** 读取源设置当前值: 优先用户已保存值, 回退到源声明的 default */
  settingValue(key: string, settingKey: string): Object | null {
    const saved = sourceDataStore.getSetting(key, settingKey);
    if (saved !== null) {
      return saved;
    }
    const meta = comicSourceManager.findJsSource(key);
    if (meta !== null) {
      const def: SettingDef | undefined = meta.settings.get(settingKey);
      if (def !== undefined) {
        return def.default;
      }
    }
    return null;
  }

  /** 用真引擎重新解析源的 settings 定义(公开入口: 会先确保源已加载) */
  async enrichSettings(meta: ComicSourceMeta): Promise<void> {
    await this.ensureLoaded(meta.key);
    await this.enrichSettingsInternal(meta);
  }

  /** 解析实现(调用方需保证源已加载, 避免加载流程内递归) */
  private async enrichSettingsInternal(meta: ComicSourceMeta): Promise<void> {
    const code = '(function(){ const __m = ComicSource.sources[' + JSON.stringify(meta.key) + '];'
      + ' const __out = {}; const __s = __m.settings;'
      + ' if (__s) { for (const __k of Object.keys(__s)) { const __d = __s[__k] || {};'
      + ' const __opts = []; const __labels = [];'
      + ' for (const __o of (__d.options || [])) {'
      + ' if (__o !== null && typeof __o === "object") {'
      + ' __opts.push(__o.value === undefined ? "" : String(__o.value));'
      + ' __labels.push(__o.label === undefined ? "" : String(__o.label));'
      + ' } else { __opts.push(String(__o)); __labels.push(""); } }'
      + ' __out[__k] = { title: __d.title === undefined ? __k : String(__d.title),'
      + ' type: __d.type === undefined ? "input" : String(__d.type),'
      + ' default: __d.default === undefined ? null : __d.default,'
      + ' options: __opts, labels: __labels }; } }'
      + ' return __out; })()';
    const raw = await this.evalJson<Record<string, RawSettingDef>>(code, '<settings:' + meta.key + '>');
    const next = new Map<string, SettingDef>();
    Object.keys(raw).forEach((k: string) => {
      const d = raw[k];
      const def = new SettingDef(
        d.title.length > 0 ? d.title : k,
        d.type.length > 0 ? d.type : 'input',
        d.default,
        d.options
      );
      def.optionLabels = d.labels;
      next.set(k, def);
    });
    meta.settings = next;
    meta.hasSettings = next.size > 0;
    hilog.info(DOMAIN, TAG, '源 %{public}s 设置项: %{public}d 个', meta.key, next.size);
  }

  /**
   * 用真引擎解析源的 explore[] 定义(标题/类型/加载能力)。
   * 静态正则无法判断 load 是否存在, 也无法得到准确 title。
   */
  async enrichExplore(meta: ComicSourceMeta): Promise<void> {
    await this.ensureLoaded(meta.key);
    const code = '(function(){ const __m = ComicSource.sources[' + JSON.stringify(meta.key) + '];'
      + ' const __out = []; const __e = __m.explore;'
      + ' if (Array.isArray(__e)) { for (let i = 0; i < __e.length; i++) { const __p = __e[i] || {};'
      + ' __out.push({'
      + ' title: __p.title === undefined ? "" : String(__p.title),'
      + ' type: __p.type === undefined ? "" : String(__p.type),'
      + ' hasLoad: typeof __p.load === "function",'
      + ' hasLoadNext: typeof __p.loadNext === "function"'
      + ' }); } } return __out; })()';
    const raw = await this.evalJson<RawExplorePage[]>(code, '<explore:' + meta.key + '>');
    const list: ExplorePageInfo[] = [];
    for (let i = 0; i < raw.length; i++) {
      const p = raw[i];
      const info = new ExplorePageInfo(meta.key, meta.name, i, p.title, p.type, p.hasLoad);
      info.hasLoadNext = p.hasLoadNext;
      list.push(info);
    }
    meta.explorePages = list;
    meta.hasExplore = list.length > 0;
    hilog.info(DOMAIN, TAG, '源 %{public}s 发现页: %{public}d 个', meta.key, list.length);
  }

  /**
   * 用真引擎解析源的 category 定义, 把新旧两种写法统一成 label + target。
   * 新格式: categories = [{label, target:{page, attributes}}]
   * 旧格式: categories = ["tag", ...] + itemType/categoryParams/groupParam
   */
  async enrichCategory(meta: ComicSourceMeta): Promise<void> {
    await this.ensureLoaded(meta.key);
    const keyJson = JSON.stringify(meta.key);
    const code = '(function(){'
      + ' const __m = ComicSource.sources[' + keyJson + '];'
      + ' const __c = __m.category;'
      + ' const __hasCC = !!(__m.categoryComics && typeof __m.categoryComics.load === "function");'
      + OPTION_LIST_JS
      + ' const __catOpts = __parseOptions(__m.categoryComics ? __m.categoryComics.optionList : null);'
      + ' if (!__c || !__c.title) { return { title: "", enableRanking: false,'
      + '   hasCategoryComics: __hasCC, parts: [], options: __catOpts }; }'
      + ' const __toTarget = (raw) => {'
      + '   const empty = { page: "", category: "", param: "", keyword: "" };'
      + '   if (raw === null || typeof raw !== "object") { return empty; }'
      + '   if (raw.page !== undefined) {'
      + '     const a = raw.attributes || {};'
      + '     return { page: String(raw.page),'
      + '       category: a.category === undefined ? "" : String(a.category),'
      + '       param: a.param === undefined ? "" : String(a.param),'
      + '       keyword: a.text === undefined ? "" : String(a.text) }; }'
      + '   if (raw.action !== undefined) {'
      + '     const kw = raw.keyword === undefined ? "" : String(raw.keyword);'
      + '     return { page: String(raw.action), category: kw,'
      + '       param: raw.param === undefined ? "" : String(raw.param), keyword: kw }; }'
      + '   return empty; };'
      + ' const __parts = [];'
      + ' for (const __p of (__c.parts || [])) {'
      + '   const __cats = __p.categories;'
      + '   if (!Array.isArray(__cats)) { continue; }'
      + '   const __name = __p.name === undefined ? "" : String(__p.name);'
      + '   const __itemType = __p.itemType === undefined ? "" : String(__p.itemType);'
      + '   const __params = __p.categoryParams || [];'
      + '   const __group = __p.groupParam === undefined ? "" : String(__p.groupParam);'
      + '   const __items = [];'
      + '   for (let __i = 0; __i < __cats.length; __i++) {'
      + '     const __e = __cats[__i];'
      + '     if (__e !== null && typeof __e === "object") {'
      + '       __items.push({ label: __e.label === undefined ? "" : String(__e.label),'
      + '         target: __toTarget(__e.target) }); continue; }'
      + '     const __label = String(__e);'
      + '     const __p0 = (__i < __params.length && __params[__i] !== null && __params[__i] !== undefined)'
      + '       ? String(__params[__i]) : "";'
      + '     let __t = { page: "", category: "", param: "", keyword: "" };'
      + '     if (__itemType === "category") {'
      + '       __t = { page: "category", category: __label,'
      + '         param: __group.length > 0 ? __group : __p0, keyword: "" };'
      + '     } else if (__itemType === "search") {'
      + '       __t = { page: "search", category: "", param: "", keyword: __label };'
      + '     } else if (__itemType === "search_with_namespace") {'
      + '       __t = { page: "search", category: "", param: "", keyword: __name + ":" + __label };'
      + '     } else if (__itemType.length > 0) {'
      + '       __t = { page: __itemType, category: "", param: __p0, keyword: "" }; }'
      + '     __items.push({ label: __label, target: __t }); }'
      + '   __parts.push({ name: __name,'
      + '     type: __p.type === undefined ? "fixed" : String(__p.type),'
      + '     randomNumber: __p.randomNumber === undefined ? 1 : Number(__p.randomNumber),'
      + '     items: __items }); }'
      + ' return { title: String(__c.title), enableRanking: __c.enableRankingPage === true,'
      + '   hasCategoryComics: __hasCC, parts: __parts, options: __catOpts }; })()';
    const raw = await this.evalJson<RawCategoryMeta>(code, '<category:' + meta.key + '>');
    const cat = new CategoryMeta();
    cat.title = raw.title;
    cat.enableRankingPage = raw.enableRanking;
    for (let i = 0; i < raw.parts.length; i++) {
      const rp = raw.parts[i];
      const part = new CategoryPart();
      part.name = rp.name;
      part.type = rp.type;
      part.randomNumber = rp.randomNumber;
      for (let j = 0; j < rp.items.length; j++) {
        const ri = rp.items[j];
        const target = new CategoryTarget();
        if (ri.target !== undefined && ri.target !== null) {
          target.page = ri.target.page;
          target.category = ri.target.category;
          target.param = ri.target.param;
          target.keyword = ri.target.keyword;
        }
        part.items.push(new CategoryItem(ri.label, target));
      }
      cat.parts.push(part);
    }
    meta.category = cat;
    meta.hasCategoryComics = raw.hasCategoryComics;
    meta.categoryOptions = toOptionDefs(raw.options);
    hilog.info(DOMAIN, TAG, '源 %{public}s 分类分组: %{public}d 个, 选项组: %{public}d 个, 结果页: %{public}s',
      meta.key, cat.parts.length, meta.categoryOptions.length, raw.hasCategoryComics ? '有' : '无');
  }

  /** 用真引擎解析 search.optionList(每组选项是 "key-显示名" 字符串) */
  async enrichSearchOptions(meta: ComicSourceMeta): Promise<void> {
    await this.ensureLoaded(meta.key);
    const keyJson = JSON.stringify(meta.key);
    const code = '(function(){'
      + ' const __m = ComicSource.sources[' + keyJson + '];'
      + ' const __s = __m.search;'
      + ' const __c = __m.comic;'
      + OPTION_LIST_JS
      + ' return { options: __parseOptions(__s ? __s.optionList : null),'
      + '   hasLoad: !!(__s && typeof __s.load === "function"),'
      + '   hasLoadNext: !!(__s && typeof __s.loadNext === "function"),'
      + '   idMatch: (__c && typeof __c.idMatch === "string") ? __c.idMatch : "",'
      + '   hasLoadInfo: !!(__c && typeof __c.loadInfo === "function") }; })()';
    const raw = await this.evalJson<RawSearchMeta>(code, '<search:' + meta.key + '>');
    const list = toOptionDefs(raw.options);
    meta.searchOptions = list;
    meta.searchHasLoad = raw.hasLoad;
    meta.idMatcher = raw.idMatch;
    meta.hasLoadInfo = raw.hasLoadInfo;
    hilog.info(DOMAIN, TAG, '源 %{public}s 搜索: 选项组 %{public}d 个, 分页方式 %{public}s, ID 规则 %{public}s',
      meta.key, list.length, raw.hasLoad ? 'load' : (raw.hasLoadNext ? 'loadNext' : '无'),
      raw.idMatch.length > 0 ? raw.idMatch : '无');
  }

  // ============================================================ 分类 / 搜索调用

  /**
   * 调用源的分类结果加载(categoryComics.load)。
   * @param options 用户在选项 chips 中选中的值; 源未声明选项时传 null(与原版一致)
   */
  async callCategoryComicsLoad(sourceKey: string, category: string, param: string,
                               options: string[] | null, pageNo: number): Promise<string> {
    const optJson = options === null ? 'null' : JSON.stringify(options);
    const expr = '__m.categoryComics.load(' + JSON.stringify(category) + ','
      + JSON.stringify(param) + ',' + optJson + ',' + pageNo + ')';
    return await this.callSource(sourceKey, expr);
  }

  /**
   * 单源搜索。源实现 search.load 时走分页, 否则走 search.loadNext 游标式。
   * @param options 选中值数组(按 optionList 顺序); 源无选项时传 null
   */
  async callSearchLoad(sourceKey: string, keyword: string, options: string[] | null,
                       pageNo: number): Promise<string> {
    const meta = comicSourceManager.findJsSource(sourceKey);
    if (meta === null) {
      throw new Error('源不存在: ' + sourceKey);
    }
    const optJson = options === null ? 'null' : JSON.stringify(options);
    const kwJson = JSON.stringify(keyword);
    const expr = meta.searchHasLoad
      ? '__m.search.load(' + kwJson + ',' + optJson + ',' + pageNo + ')'
      : '__m.search.loadNext(' + kwJson + ',' + optJson + ',null)';
    return await this.callSource(sourceKey, expr);
  }

  /** 游标式搜索的下一页 */
  async callSearchLoadNext(sourceKey: string, keyword: string, options: string[] | null,
                           next: string): Promise<string> {
    const optJson = options === null ? 'null' : JSON.stringify(options);
    const expr = '__m.search.loadNext(' + JSON.stringify(keyword) + ',' + optJson + ','
      + JSON.stringify(next) + ')';
    return await this.callSource(sourceKey, expr);
  }

  // ============================================================ 漫画详情调用

  /**
   * 加载漫画详情(comic.loadInfo), 也是「按 ID 直达」的落地调用。
   *
   * 源普遍用 Map 承载 chapters(如 jm/picacg), 而 native 侧的 JSON 序列化只认自有可枚举属性,
   * Map 会被序列化成 {}, 因此在 JS 侧先把 Map 递归归一成普通对象再返回。
   */
  async callLoadInfo(sourceKey: string, id: string): Promise<string> {
    const expr = '(async () => {'
      + ' const __r = await __m.comic.loadInfo(' + JSON.stringify(id) + ');'
      + ' const __fix = (v) => {'
      + '   if (v instanceof Map) {'
      + '     const o = {}; v.forEach((vv, kk) => { o[String(kk)] = __fix(vv); }); return o; }'
      + '   if (Array.isArray(v)) { return v.map(__fix); }'
      + '   if (v !== null && typeof v === "object") {'
      + '     const o = {}; for (const k in v) { o[k] = __fix(v[k]); } return o; }'
      + '   return v === undefined ? null : v; };'
      + ' return __fix(__r); })()';
    return await this.callSource(sourceKey, expr);
  }

  // ============================================================ 章节图片调用

  /**
   * 加载章节图片地址(comic.loadEp), 返回 { images: string[] } 的 JSON。
   * epId 为空表示「整本即一章」(原版传 null, 如 e-hentai)。
   */
  async callLoadEp(sourceKey: string, comicId: string, epId: string): Promise<string> {
    const ep = epId.length === 0 ? 'null' : JSON.stringify(epId);
    const expr = '__m.comic.loadEp(' + JSON.stringify(comicId) + ',' + ep + ')';
    return await this.callSource(sourceKey, expr);
  }

  /**
   * 图片加载配置(comic.onImageLoad): 返回 { url, headers, modifyImage } 的 JSON。
   * url 可能被源替换(如 e-hentai 把页码解析成真实图片地址)。源未实现时返回 null。
   */
  async callOnImageLoad(sourceKey: string, url: string, comicId: string,
                        epId: string): Promise<string> {
    const ep = epId.length === 0 ? 'null' : JSON.stringify(epId);
    const expr = '(async () => {'
      + ' const __c = __m.comic;'
      + ' if (!__c || typeof __c.onImageLoad !== "function") { return null; }'
      + ' return await __c.onImageLoad(' + JSON.stringify(url) + ','
      + JSON.stringify(comicId) + ',' + ep + '); })()';
    return await this.callSource(sourceKey, expr);
  }

  /**
   * 执行源的图片还原代码(comic.onImageLoad 返回的 modifyImage 源码),
   * 传入待还原位图的 key, 返回还原后位图的 key(失败返回 -1)。
   *
   * 源码形如 `let modifyImage = (image) => {...}`: 直接拼进函数体执行,
   * 这样源码里的 let 声明与它引用的全局符号(Image/Convert 等)都在同一作用域内可用。
   */
  async callModifyImage(sourceKey: string, key: number, code: string): Promise<number> {
    const expr = '(function(){'
      + code
      + '; if (typeof modifyImage !== "function") { return null; }'
      + ' const __r = modifyImage(new Image(' + key.toString() + '));'
      + ' return (__r && typeof __r.key === "number") ? __r.key : null; })()';
    const raw = await this.callSource(sourceKey, expr);
    let parsed: Object;
    try {
      parsed = JSON.parse(raw) as Object;
    } catch (e) {
      return -1;
    }
    return typeof parsed === 'number' ? parsed as number : -1;
  }

  // ============================================================ 发现页调用

  /**
   * 调用一个发现页的加载方法, 返回原始 JSON(由 ExploreService 解析成模型)。
   * 对应原版 parser.dart 中按 type 分派的四种调用方式。
   */
  async callExploreLoad(page: ExplorePageInfo, pageNo: number): Promise<string> {
    const ref = '__m.explore[' + page.index + ']';
    let expr = '';
    if (page.isMultiPart()) {
      expr = ref + '.load()';
    } else if (page.isMixed()) {
      expr = ref + '.load(' + pageNo + ')';
    } else if (page.hasLoad) {
      expr = ref + '.load(' + pageNo + ')';
    } else if (page.hasLoadNext) {
      expr = ref + '.loadNext(null)';
    } else {
      throw new Error('该发现页未提供加载方法');
    }
    return await this.callSource(page.sourceKey, expr);
  }

  /** 游标式分页(multiPageComicList 且未实现 load 时) */
  async callExploreLoadNext(page: ExplorePageInfo, next: string): Promise<string> {
    const expr = '__m.explore[' + page.index + '].loadNext(' + JSON.stringify(next) + ')';
    return await this.callSource(page.sourceKey, expr);
  }

  // ============================================================ sendMessage 分发

  /**
   * sendMessage 分发。
   *
   * 与原版语义一致: 「同步方法」直接返回 JSON 字符串(load_data/load_setting/convert 等),
   * 「异步方法」返回 Promise (http/delay)。源脚本里大量 `const x = this.loadData('k')`
   * 是不 await 的, 因此同步语义必须成立。
   */
  private handleMessage(messageJson: string): string | Promise<string> {
    let msg: BridgeMessage;
    try {
      msg = JSON.parse(messageJson) as BridgeMessage;
    } catch (e) {
      hilog.error(DOMAIN, TAG, 'sendMessage 报文解析失败: %{public}s', truncate(messageJson, 300));
      return 'null';
    }
    const method = msg.method ?? '';
    try {
      switch (method) {
        case 'log':
          this.onLog(msg);
          return 'null';
        // ---- 同步方法 ----
        case 'load_data':
          return JSON.stringify(this.onLoadData(msg));
        case 'save_data':
          this.onSaveData(msg);
          return 'null';
        case 'delete_data':
          this.onDeleteData(msg);
          return 'null';
        case 'load_setting':
          return JSON.stringify(this.onLoadSetting(msg));
        case 'isLogged':
          return JSON.stringify(this.isLogged(strKeyOf(msg)));
        case 'cookie':
          return JSON.stringify(this.onCookie(msg));
        case 'html':
          return JSON.stringify(this.onHtml(msg));
        case 'convert': {
          const conv = JSON.stringify(this.onConvert(msg));
          hilog.info(DOMAIN, TAG, 'convert %{public}s -> %{public}s', msg.type ?? '', truncate(conv, 100));
          return conv;
        }
        case 'image':
          // 源脚本 comic.onImageLoad.modifyImage 的位图操作(见 init.js 的 Image 类)
          return JSON.stringify(imageBridge.handleRaw(messageJson));
        case 'random':
          return JSON.stringify(this.onRandom(msg));
        case 'uuid':
          return JSON.stringify(util.generateRandomUUID(true));
        case 'getLocale':
          return JSON.stringify('zh_CN');
        case 'getPlatform':
          // 源脚本普遍以 android/ios 判断分支, 这里对齐安卓语义以最大化兼容
          return JSON.stringify('android');
        // ---- 异步方法 ----
        case 'http':
          return this.onHttp(msg).then((r: HttpResult) => JSON.stringify(r));
        case 'delay':
          return JsRuntimeImpl.sleep(msg.time ?? 0).then(() => 'null');
        default:
          WarnedMethods.warnOnce(method);
          return 'null';
      }
    } catch (e) {
      const err = e as Error;
      const text = err.message ?? String(e);
      hilog.error(DOMAIN, TAG, 'sendMessage %{public}s 处理失败: %{public}s', method, text);
      // 抛回 JS 侧, 让源脚本的 try/catch 能感知
      throw new Error(text);
    }
  }

  // ============================================================ 各 method 实现

  private onLog(msg: BridgeMessage): void {
    const title = msg.title ?? 'JS';
    const content = msg.content !== undefined ? JSON.stringify(msg.content) : '';
    const level = msg.level ?? 'info';
    if (level === 'error') {
      hilog.error(DOMAIN, TAG, '[%{public}s] %{public}s', title, content);
    } else if (level === 'warning') {
      hilog.warn(DOMAIN, TAG, '[%{public}s] %{public}s', title, content);
    } else {
      hilog.info(DOMAIN, TAG, '[%{public}s] %{public}s', title, content);
    }
  }

  private async onHttp(msg: BridgeMessage): Promise<HttpResult> {
    const url = msg.url ?? '';
    const methodName = (msg.http_method ?? 'GET').toUpperCase();
    const wantBytes = msg.bytes === true;

    const headers: Record<string, string> = {};
    const rawHeaders = this.asRecord(msg.headers);
    Object.keys(rawHeaders).forEach((k: string) => {
      const v = rawHeaders[k];
      if (typeof v === 'string') {
        headers[k] = v as string;
      } else {
        headers[k] = JSON.stringify(v);
      }
    });

    // data 可能是 string / ArrayBuffer(已还原为 {__bytes})
    let bodyText = '';
    let bodyBytes: ArrayBuffer | undefined = undefined;
    const data = msg.data;
    if (typeof data === 'string') {
      bodyText = data as string;
    } else if (data !== undefined && data !== null) {
      const bytes = this.extractBytes(data);
      if (bytes !== null) {
        bodyBytes = bytes;
      } else {
        bodyText = JSON.stringify(data);
      }
    }

    const resp = await httpClient.rawRequest({
      url: url,
      method: this.mapMethod(methodName),
      headers: headers,
      body: bodyText.length > 0 ? bodyText : undefined,
      bodyBytes: bodyBytes,
      responseType: wantBytes ? ResponseType.BYTES : ResponseType.TEXT
    });

    const result: HttpResult = {
      status: resp.status,
      headers: resp.headers,
      body: wantBytes ? ({ __bytes: resp.bodyBase64 } as BytesWrapper) : resp.body,
      error: resp.error
    };
    return result;
  }

  private mapMethod(name: string): HttpMethod {
    if (name === 'POST') {
      return HttpMethod.POST;
    }
    if (name === 'PUT') {
      return HttpMethod.PUT;
    }
    if (name === 'DELETE') {
      return HttpMethod.DELETE;
    }
    return HttpMethod.GET;
  }

  private onConvert(msg: BridgeMessage): Object | null {
    const type = msg.type ?? '';
    const isEncode = msg.isEncode === true;
    const value = msg.value;
    switch (type) {
      case 'utf8': {
        if (isEncode) {
          return this.bytesWrapper(this.strToBytes(JsRuntimeImpl.toStr(value)));
        }
        return this.bytesToStr(this.extractBytesOrEmpty(value));
      }
      case 'base64': {
        if (isEncode) {
          return this.bytesToBase64(this.extractBytesOrEmpty(value));
        }
        const raw = value;
        const b64Text = typeof raw === 'string'
          ? (raw as string)
          : this.bytesToStr(this.extractBytesOrEmpty(raw));
        return this.bytesWrapper(this.base64ToBytes(b64Text));
      }
      case 'md5':
      case 'sha1':
      case 'sha256':
      case 'sha512': {
        return this.bytesWrapper(this.digest(type.toUpperCase(), this.extractBytesOrEmpty(value)));
      }
      case 'hmac': {
        const hash = (msg.hash ?? 'sha256').toUpperCase();
        const mac = this.hmac(hash, this.extractBytesOrEmpty(msg.key), this.extractBytesOrEmpty(value));
        return msg.isString === true ? this.bytesToHex(mac) : this.bytesWrapper(mac);
      }
      case 'gbk': {
        if (isEncode) {
          const encoded = util.TextEncoder.create('gbk').encodeInto(JsRuntimeImpl.toStr(value));
          // encodeInto 的底层 buffer 可能略大于实际长度, slice 截到精确长度
          return this.bytesWrapper(encoded.slice());
        }
        return util.TextDecoder.create('gbk').decodeToString(this.extractBytesOrEmpty(value));
      }
      case 'aes-ecb':
      case 'aes-cbc':
      case 'aes-cfb':
      case 'aes-ofb': {
        const mode = type.substring(4).toUpperCase();
        const key = this.extractBytesOrEmpty(msg.key);
        const iv = this.extractBytesOrEmpty(msg.iv);
        return this.bytesWrapper(this.aes(mode, key, iv, this.extractBytesOrEmpty(value), isEncode));
      }
      default:
        WarnedMethods.warnOnce('convert:' + type);
        return null;
    }
  }

  /** AES 对称加解密(对应原版 aes-ecb/cbc/cfb/ofb, 无填充) */
  private aes(mode: string, key: Uint8Array, iv: Uint8Array, data: Uint8Array, isEncode: boolean): Uint8Array {
    const algName = 'AES' + (key.length * 8).toString();
    const keyBlob: cryptoFramework.DataBlob = { data: key };
    const symKey = cryptoFramework.createSymKeyGenerator(algName).convertKeySync(keyBlob);
    const cipher = cryptoFramework.createCipher(algName + '|' + mode + '|NoPadding');
    const opMode = isEncode ? cryptoFramework.CryptoMode.ENCRYPT_MODE : cryptoFramework.CryptoMode.DECRYPT_MODE;
    if (iv.length > 0) {
      const ivSpec: cryptoFramework.IvParamsSpec = {
        algName: 'IvParamsSpec',
        iv: { data: iv }
      };
      cipher.initSync(opMode, symKey, ivSpec);
    } else {
      cipher.initSync(opMode, symKey, null);
    }
    const input: cryptoFramework.DataBlob = { data: data };
    return cipher.doFinalSync(input).data;
  }

  /** 包装成 C++ 侧可还原为 ArrayBuffer 的 {__bytes: base64} */
  private bytesWrapper(bytes: Uint8Array): Object {
    const wrapper: BytesWrapper = { __bytes: this.bytesToBase64(bytes) };
    return wrapper as Object;
  }

  // ---------------------------------------------------------- 源数据存取

  private onLoadData(msg: BridgeMessage): Object | null {
    return sourceDataStore.get(strKeyOf(msg), msg.data_key ?? '');
  }

  private onSaveData(msg: BridgeMessage): void {
    const dataKey = msg.data_key ?? '';
    if (dataKey === 'setting') {
      throw new Error('setting is not allowed to be saved');
    }
    sourceDataStore.set(strKeyOf(msg), dataKey, msg.data === undefined ? null : msg.data);
  }

  private onDeleteData(msg: BridgeMessage): void {
    sourceDataStore.remove(strKeyOf(msg), msg.data_key ?? '');
  }

  private onLoadSetting(msg: BridgeMessage): Object | null {
    const sourceKey = strKeyOf(msg);
    const settingKey = msg.setting_key ?? '';
    if (sourceKey.length === 0 || settingKey.length === 0) {
      throw new Error('loadSetting 参数不合法');
    }
    // 1. 用户已保存的设置值
    const saved = sourceDataStore.getSetting(sourceKey, settingKey);
    if (saved !== null) {
      return saved;
    }
    const meta = comicSourceManager.findJsSource(sourceKey);
    if (meta === null) {
      throw new Error('源不存在: ' + sourceKey);
    }
    // 2. 源声明的默认值(保留原始类型)
    const def: SettingDef | undefined = meta.settings.get(settingKey);
    if (def === undefined) {
      // 与原版一致: 未声明的设置返回 null 而不是抛错,
      // 否则源脚本里 `if (loadSetting('x'))` 这类写法会被异常直接打断
      hilog.warn(DOMAIN, TAG, '源 %{public}s 读取未声明的设置 %{public}s', sourceKey, settingKey);
      return null;
    }
    return def.default;
  }

  // ---------------------------------------------------------- HTML DOM 桥

  private onHtml(msg: BridgeMessage): Object | null {
    const req: HtmlRequest = {
      function: msg.function ?? '',
      key: numOf(msg.key),
      doc: numOf(msg.doc),
      query: msg.query ?? '',
      id: msg.id ?? '',
      data: strOf(msg.data)
    };
    return htmlBridge.handle(req);
  }

  // ---------------------------------------------------------- Cookie 桥

  private onCookie(msg: BridgeMessage): Object | null {
    const fn = msg.function ?? '';
    const urlText = msg.url ?? '';
    if (fn === 'set') {
      cookieStore.put(urlText, this.parseCookieList(msg.cookies));
      return null;
    }
    if (fn === 'get') {
      return this.cookieListJson(urlText);
    }
    if (fn === 'delete') {
      cookieStore.deleteForUrl(urlText);
      return null;
    }
    WarnedMethods.warnOnce('cookie:' + fn);
    return null;
  }

  /** {name,value,domain} 列表 -> Cookie 对象列表 */
  private parseCookieList(value: Object | undefined): Cookie[] {
    const out: Cookie[] = [];
    if (value === undefined || value === null) {
      return out;
    }
    const arr = value as Record<string, Object>[];
    for (let i = 0; i < arr.length; i++) {
      const item = arr[i];
      if (item === undefined || item === null) {
        continue;
      }
      const c = new Cookie();
      const name = item['name'];
      const val = item['value'];
      const domain = item['domain'];
      const path = item['path'];
      c.name = typeof name === 'string' ? (name as string) : '';
      c.value = typeof val === 'string' ? (val as string) : '';
      c.domain = typeof domain === 'string' ? (domain as string) : '';
      c.path = typeof path === 'string' ? (path as string) : '/';
      if (c.name.length > 0) {
        out.push(c);
      }
    }
    return out;
  }

  /** 转为原版 cookie 桥 get 返回的数组结构 */
  private cookieListJson(urlText: string): Object {
    const list = cookieStore.listForUrl(urlText);
    const out: Object[] = [];
    for (let i = 0; i < list.length; i++) {
      const c = list[i];
      const item: Record<string, Object | null> = {};
      item['name'] = c.name;
      item['value'] = c.value;
      item['domain'] = c.domain;
      item['path'] = c.path;
      item['expires'] = c.expires;
      item['max-age'] = c.expires > 0 ? c.expires : -1;
      item['secure'] = c.secure;
      item['httpOnly'] = c.httpOnly;
      item['session'] = c.expires <= 0;
      out.push(item);
    }
    return out;
  }

  private onRandom(msg: BridgeMessage): number {
    const min = JsRuntimeImpl.toNum(msg.min, 0);
    const max = JsRuntimeImpl.toNum(msg.max, 1);
    const v = min + Math.random() * (max - min);
    return msg.type === 'double' ? v : Math.floor(v);
  }

  // ---------------------------------------------------------- 工具

  /** 任意 JS 值安全转字符串(源脚本常把非字符串传进 convert) */
  private static toStr(value: Object | undefined): string {
    if (value === undefined || value === null) {
      return '';
    }
    if (typeof value === 'string') {
      return value as string;
    }
    if (typeof value === 'number' || typeof value === 'boolean') {
      return `${value}`;
    }
    return '';
  }

  /** 任意 JS 值安全转数字 */
  private static toNum(value: Object | undefined, fallback: number): number {
    if (typeof value === 'number') {
      return value as number;
    }
    if (typeof value === 'string') {
      const parsed = Number.parseFloat(value as string);
      return isNaN(parsed) ? fallback : parsed;
    }
    return fallback;
  }

  private asRecord(value: Object | undefined): Record<string, Object> {
    if (value === undefined || value === null) {
      return {};
    }
    return value as Record<string, Object>;
  }

  /** 从 {__bytes: base64} 取出 ArrayBuffer, 非字节对象返回 null */
  private extractBytes(value: Object | undefined): ArrayBuffer | null {
    if (value === undefined || value === null) {
      return null;
    }
    const rec = value as Record<string, Object>;
    const b64 = rec['__bytes'];
    if (typeof b64 !== 'string') {
      return null;
    }
    const u8 = this.base64ToBytes(b64 as string);
    return u8.buffer.slice(u8.byteOffset, u8.byteOffset + u8.byteLength) as ArrayBuffer;
  }

  private extractBytesOrEmpty(value: Object | undefined): Uint8Array {
    const buf = this.extractBytes(value);
    if (buf !== null) {
      return new Uint8Array(buf);
    }
    if (typeof value === 'string') {
      return this.strToBytes(value as string);
    }
    return new Uint8Array(0);
  }

  private strToBytes(str: string): Uint8Array {
    return new util.TextEncoder().encodeInto(str);
  }

  private bytesToStr(bytes: Uint8Array): string {
    return util.TextDecoder.create('utf-8').decodeToString(bytes);
  }

  private bytesToBase64(bytes: Uint8Array): string {
    return new util.Base64Helper().encodeToStringSync(bytes);
  }

  /**
   * base64 解码(容错):
   * 源抓下来的 base64 常见三类脏数据, 严格模式会整串拒绝:
   *   1. 开头带 UTF-8 BOM(\uFEFF) —— 服务端存文本文件时的常见情况
   *   2. 中间夹换行/空格(每 76 字符折行的 PEM 风格)
   *   3. URL-safe 字母表(- 与 _)
   * 因此这里只保留合法字符, 其余一律丢弃。
   */
  private base64ToBytes(text: string): Uint8Array {
    let cleaned = '';
    for (let i = 0; i < text.length; i++) {
      const c = text.charAt(i);
      const code = c.charCodeAt(0);
      const isAlnum = (code >= 65 && code <= 90) || (code >= 97 && code <= 122)
        || (code >= 48 && code <= 57);
      if (isAlnum || c === '+' || c === '/' || c === '=') {
        cleaned += c;
      } else if (c === '-') {
        cleaned += '+';
      } else if (c === '_') {
        cleaned += '/';
      }
    }
    const rest = cleaned.length % 4;
    if (rest === 2) {
      cleaned += '==';
    } else if (rest === 3) {
      cleaned += '=';
    } else if (rest === 1) {
      cleaned = cleaned.substring(0, cleaned.length - 1);
    }
    if (cleaned.length === 0) {
      return new Uint8Array(0);
    }
    return new util.Base64Helper().decodeSync(cleaned);
  }

  private bytesToHex(bytes: Uint8Array): string {
    let out = '';
    for (let i = 0; i < bytes.length; i++) {
      out += bytes[i].toString(16).padStart(2, '0');
    }
    return out;
  }

  /** 摘要(同步 API, 保证 convert 桥的同步语义) */
  private digest(alg: string, data: Uint8Array): Uint8Array {
    const md = cryptoFramework.createMd(alg);
    const input: cryptoFramework.DataBlob = { data: data };
    md.updateSync(input);
    return md.digestSync().data;
  }

  /** HMAC(同步 API) */
  private hmac(alg: string, key: Uint8Array, data: Uint8Array): Uint8Array {
    const keyBlob: cryptoFramework.DataBlob = { data: key };
    const generator = cryptoFramework.createSymKeyGenerator('HMAC');
    const symKey = generator.convertKeySync(keyBlob);
    const mac = cryptoFramework.createMac(alg);
    mac.initSync(symKey);
    const input: cryptoFramework.DataBlob = { data: data };
    mac.updateSync(input);
    return mac.doFinalSync().data;
  }

  private static sleep(ms: number): Promise<void> {
    return new Promise<void>((resolve: () => void) => {
      setTimeout(() => {
        resolve();
      }, ms);
    });
  }
}

/** 全局单例 */
export const jsRuntime = new JsRuntimeImpl();
