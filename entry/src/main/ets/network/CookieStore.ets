/**
 * VeneraNext Cookie 持久化
 * 对应原版 network/cookie_jar.dart (SQLite cookie.db), 这里用 filesDir/cookies.json
 *
 * 职责: 请求前注入 Cookie 头、响应后写入 Set-Cookie、供 JS 源脚本通过 cookie 桥读写
 */
import { common } from '@kit.AbilityKit';
import { fileIo as fs } from '@kit.CoreFileKit';
import { url, util } from '@kit.ArkTS';
import { hilog } from '@kit.PerformanceAnalysisKit';

const DOMAIN = 0x0000;
const TAG = 'CookieStore';
const FILE_NAME = 'cookies.json';

/** 单条 Cookie */
export class Cookie {
  name: string = '';
  value: string = '';
  domain: string = '';
  path: string = '/';
  /** 过期时间(秒级时间戳), -1 表示会话 Cookie */
  expires: number = -1;
  secure: boolean = false;
  httpOnly: boolean = false;

  isExpired(now: number): boolean {
    return this.expires > 0 && this.expires <= now;
  }
}

/** URL 解析结果 */
interface ParsedUrl {
  host: string;
  path: string;
  secure: boolean;
}

export class CookieStore {
  private static instance: CookieStore = new CookieStore();
  private cookies: Cookie[] = [];
  private filePath: string = '';
  private loaded: boolean = false;

  static getInstance(): CookieStore {
    return CookieStore.instance;
  }

  /** 初始化: 绑定文件并载入(幂等) */
  init(context: common.Context): void {
    if (this.loaded) {
      return;
    }
    this.filePath = context.filesDir + '/' + FILE_NAME;
    this.reload();
  }

  /** 从磁盘重载 */
  reload(): void {
    this.cookies = [];
    this.loaded = true;
    if (this.filePath.length === 0) {
      return;
    }
    let text = '';
    try {
      if (!fs.accessSync(this.filePath)) {
        return;
      }
      const f = fs.openSync(this.filePath, fs.OpenMode.READ_ONLY);
      const stat = fs.statSync(f.fd);
      const buf = new ArrayBuffer(stat.size);
      fs.readSync(f.fd, buf);
      fs.closeSync(f);
      text = util.TextDecoder.create('utf-8').decodeToString(new Uint8Array(buf));
    } catch (e) {
      hilog.error(DOMAIN, TAG, '读取 cookies.json 失败: %{public}s', `${e}`);
      return;
    }
    if (text.length === 0) {
      return;
    }
    try {
      const list = JSON.parse(text) as Record<string, Object>[];
      for (let i = 0; i < list.length; i++) {
        const c = CookieStore.fromJson(list[i]);
        if (c.name.length > 0) {
          this.cookies.push(c);
        }
      }
      hilog.info(DOMAIN, TAG, '载入 %{public}d 条 cookie', this.cookies.length);
    } catch (e) {
      hilog.warn(DOMAIN, TAG, 'cookies.json 解析失败, 已忽略');
    }
    this.dropExpired();
  }

  /** 生成请求用的 Cookie 头(无匹配返回空串) */
  headerFor(urlText: string): string {
    const parsed = CookieStore.parseUrl(urlText);
    if (parsed.host.length === 0) {
      return '';
    }
    const parts: string[] = [];
    const matched = this.match(parsed);
    for (let i = 0; i < matched.length; i++) {
      parts.push(matched[i].name + '=' + matched[i].value);
    }
    return parts.join('; ');
  }

  /** 读出某 URL 可见的 cookie(供 cookie 桥 get 使用) */
  listForUrl(urlText: string): Cookie[] {
    return this.match(CookieStore.parseUrl(urlText));
  }

  /** 从响应头写入 Set-Cookie */
  applyResponseHeaders(urlText: string, headers: Record<string, string>): void {
    const raw = this.collectSetCookie(headers);
    if (raw.length === 0) {
      return;
    }
    const parsed = CookieStore.parseUrl(urlText);
    let changed = false;
    for (let i = 0; i < raw.length; i++) {
      const c = CookieStore.parseSetCookie(raw[i], parsed.host);
      if (c === null) {
        continue;
      }
      this.upsert(c);
      changed = true;
    }
    if (changed) {
      this.dropExpired();
      this.flush();
    }
  }

  /** 直接写入若干 cookie(供 cookie 桥 set 使用) */
  put(urlText: string, list: Cookie[]): void {
    const parsed = CookieStore.parseUrl(urlText);
    for (let i = 0; i < list.length; i++) {
      const c = list[i];
      if (c.domain.length === 0) {
        c.domain = parsed.host;
      }
      if (c.path.length === 0) {
        c.path = '/';
      }
      this.upsert(c);
    }
    this.dropExpired();
    this.flush();
  }

  /** 删除某 URL 对应域下的全部 cookie(供 cookie 桥 delete 使用) */
  deleteForUrl(urlText: string): void {
    const parsed = CookieStore.parseUrl(urlText);
    if (parsed.host.length === 0) {
      return;
    }
    const kept: Cookie[] = [];
    for (let i = 0; i < this.cookies.length; i++) {
      if (!CookieStore.domainMatch(this.cookies[i].domain, parsed.host)) {
        kept.push(this.cookies[i]);
      }
    }
    this.cookies = kept;
    this.flush();
  }

  /** 清空全部 */
  clearAll(): void {
    this.cookies = [];
    this.flush();
  }

  /** 有效 cookie 数量 */
  count(): number {
    return this.cookies.length;
  }

  // ------------------------------------------------------------ 内部

  private match(parsed: ParsedUrl): Cookie[] {
    const now = Math.floor(Date.now() / 1000);
    const out: Cookie[] = [];
    for (let i = 0; i < this.cookies.length; i++) {
      const c = this.cookies[i];
      if (c.isExpired(now)) {
        continue;
      }
      if (c.secure && !parsed.secure) {
        continue;
      }
      if (!CookieStore.domainMatch(c.domain, parsed.host)) {
        continue;
      }
      if (!CookieStore.pathMatch(c.path, parsed.path)) {
        continue;
      }
      out.push(c);
    }
    return out;
  }

  /** 同名同域同路径覆盖, 否则追加 */
  private upsert(c: Cookie): void {
    for (let i = 0; i < this.cookies.length; i++) {
      const e = this.cookies[i];
      if (e.name === c.name && e.domain === c.domain && e.path === c.path) {
        this.cookies[i] = c;
        return;
      }
    }
    this.cookies.push(c);
  }

  private dropExpired(): void {
    const now = Math.floor(Date.now() / 1000);
    const kept: Cookie[] = [];
    for (let i = 0; i < this.cookies.length; i++) {
      if (!this.cookies[i].isExpired(now)) {
        kept.push(this.cookies[i]);
      }
    }
    if (kept.length !== this.cookies.length) {
      this.cookies = kept;
      this.flush();
    }
  }

  private flush(): void {
    if (this.filePath.length === 0) {
      return;
    }
    try {
      const f = fs.openSync(this.filePath, fs.OpenMode.READ_WRITE | fs.OpenMode.CREATE | fs.OpenMode.TRUNC);
      fs.writeSync(f.fd, JSON.stringify(this.cookies));
      fs.closeSync(f);
    } catch (e) {
      hilog.error(DOMAIN, TAG, '写入 cookies.json 失败: %{public}s', `${e}`);
    }
  }

  /** 从响应头里收集所有 set-cookie 值(兼容大小写与多值, 鸿蒙对多值头返回数组) */
  private collectSetCookie(headers: Record<string, string>): string[] {
    const out: string[] = [];
    const keys = Object.keys(headers);
    for (let i = 0; i < keys.length; i++) {
      if (keys[i].toLowerCase() !== 'set-cookie') {
        continue;
      }
      const raw = headers[keys[i]];
      if (Array.isArray(raw)) {
        const arr = raw as Object[];
        for (let j = 0; j < arr.length; j++) {
          const item = arr[j];
          if (typeof item !== 'string' || (item as string).length === 0) {
            continue;
          }
          const segments = CookieStore.splitSetCookie(item as string);
          for (let k = 0; k < segments.length; k++) {
            out.push(segments[k]);
          }
        }
        continue;
      }
      if (typeof raw !== 'string' || (raw as string).length === 0) {
        continue;
      }
      const segments = CookieStore.splitSetCookie(raw as string);
      for (let j = 0; j < segments.length; j++) {
        out.push(segments[j]);
      }
    }
    return out;
  }

  /**
   * 拆分可能被合并的 Set-Cookie。
   * 分隔点特征: 逗号后紧跟 `token=` 形式(而非星期缩写如 Wed,).
   */
  private static splitSetCookie(value: string): string[] {
    const out: string[] = [];
    let start = 0;
    for (let i = 0; i < value.length; i++) {
      if (value.charAt(i) !== ',') {
        continue;
      }
      const rest = value.substring(i + 1).trim();
      const eq = rest.indexOf('=');
      if (eq <= 0) {
        continue;
      }
      const head = rest.substring(0, eq);
      // 星期缩写(Www)或月份缩写形式的日期片段含 '-'/' ' 等, 排除掉
      if (head.indexOf(' ') >= 0 || head.indexOf(';') >= 0) {
        continue;
      }
      out.push(value.substring(start, i).trim());
      start = i + 1;
    }
    const tail = value.substring(start).trim();
    if (tail.length > 0) {
      out.push(tail);
    }
    return out;
  }

  private static parseSetCookie(raw: string, defaultHost: string): Cookie | null {
    const parts = raw.split(';');
    if (parts.length === 0) {
      return null;
    }
    const first = parts[0].trim();
    const eq = first.indexOf('=');
    if (eq <= 0) {
      return null;
    }
    const c = new Cookie();
    c.name = first.substring(0, eq).trim();
    c.value = first.substring(eq + 1).trim();
    c.domain = defaultHost;
    c.path = '/';
    for (let i = 1; i < parts.length; i++) {
      const seg = parts[i].trim();
      if (seg.length === 0) {
        continue;
      }
      const e2 = seg.indexOf('=');
      const k = (e2 < 0 ? seg : seg.substring(0, e2)).trim().toLowerCase();
      const v = e2 < 0 ? '' : seg.substring(e2 + 1).trim();
      if (k === 'domain' && v.length > 0) {
        c.domain = v.charAt(0) === '.' ? v.substring(1) : v;
      } else if (k === 'path' && v.length > 0) {
        c.path = v;
      } else if (k === 'max-age') {
        const n = parseInt(v, 10);
        if (!isNaN(n)) {
          c.expires = Math.floor(Date.now() / 1000) + n;
        }
      } else if (k === 'expires') {
        if (c.expires < 0) {
          const t = Date.parse(v);
          if (!isNaN(t)) {
            c.expires = Math.floor(t / 1000);
          }
        }
      } else if (k === 'secure') {
        c.secure = true;
      } else if (k === 'httponly') {
        c.httpOnly = true;
      }
    }
    return c;
  }

  /** 域匹配(cookie 数据可能来自文件, 做类型保护) */
  private static domainMatch(rawDomain: Object | undefined, rawHost: Object | undefined): boolean {
    const cookieDomain = typeof rawDomain === 'string' ? (rawDomain as string) : '';
    const host = typeof rawHost === 'string' ? (rawHost as string) : '';
    if (cookieDomain.length === 0) {
      return true;
    }
    if (host.length === 0) {
      return false;
    }
    const cd = cookieDomain.charAt(0) === '.' ? cookieDomain.substring(1) : cookieDomain;
    if (host === cd) {
      return true;
    }
    return host.endsWith('.' + cd);
  }

  /** 路径匹配(同样做类型保护) */
  private static pathMatch(rawPath: Object | undefined, rawReqPath: Object | undefined): boolean {
    const cookiePath = typeof rawPath === 'string' ? (rawPath as string) : '';
    const reqPath = typeof rawReqPath === 'string' ? (rawReqPath as string) : '';
    if (reqPath.length === 0) {
      return false;
    }
    const cp = cookiePath.length === 0 ? '/' : cookiePath;
    if (!reqPath.startsWith(cp)) {
      return false;
    }
    if (cp.endsWith('/')) {
      return true;
    }
    if (reqPath.length === cp.length) {
      return true;
    }
    return reqPath.charAt(cp.length) === '/';
  }

  private static parseUrl(urlText: string): ParsedUrl {
    const out: ParsedUrl = { host: '', path: '/', secure: false };
    if (urlText.length === 0) {
      return out;
    }
    try {
      const u = url.URL.parseURL(urlText);
      const host = u.hostname;
      const path = u.pathname;
      out.host = typeof host === 'string' ? host : '';
      out.path = (typeof path === 'string' && path.length > 0) ? path : '/';
      out.secure = u.protocol === 'https:';
      return out;
    } catch (e) {
      // 退化: 手工截取 host 与 path
      hilog.warn(DOMAIN, TAG, 'URL 解析失败, 退化处理: %{public}s', urlText);
      let rest = urlText;
      const scheme = rest.indexOf('://');
      if (scheme > 0) {
        out.secure = rest.substring(0, scheme).toLowerCase() === 'https';
        rest = rest.substring(scheme + 3);
      }
      const slash = rest.indexOf('/');
      const hostPort = slash < 0 ? rest : rest.substring(0, slash);
      const colon = hostPort.indexOf(':');
      out.host = colon < 0 ? hostPort : hostPort.substring(0, colon);
      out.path = slash < 0 ? '/' : rest.substring(slash);
      const q = out.path.indexOf('?');
      if (q >= 0) {
        out.path = out.path.substring(0, q);
      }
      return out;
    }
  }

  private static fromJson(raw: Record<string, Object>): Cookie {
    const c = new Cookie();
    const name = raw['name'];
    const value = raw['value'];
    const domain = raw['domain'];
    const path = raw['path'];
    const expires = raw['expires'];
    const secure = raw['secure'];
    const httpOnly = raw['httpOnly'];
    c.name = typeof name === 'string' ? name : '';
    c.value = typeof value === 'string' ? value : '';
    c.domain = typeof domain === 'string' ? domain : '';
    c.path = typeof path === 'string' ? path : '/';
    c.expires = typeof expires === 'number' ? expires : -1;
    c.secure = secure === true;
    c.httpOnly = httpOnly === true;
    return c;
  }
}

/** 全局单例 */
export const cookieStore = CookieStore.getInstance();
