/**
 * VeneraNext JS 漫画源解析器 (A 阶段: 正则静态解析)
 * 对应原版 lib/foundation/comic_source/parser.dart
 * 签名与 B 阶段(JSVM 真引擎)对齐, 后续换引擎不改调用方
 */
import { ComicSourceMeta, SettingDef, AccountMeta } from './ComicSourceMeta';

/** 解析异常 */
export class ComicSourceParseException extends Error {
  constructor(message: string) {
    super(message);
    this.name = 'ComicSourceParseException';
  }
}

/** 是否标识符字符(用于边界判断) */
function isIdentChar(c: string): boolean {
  if (c.length === 0) {
    return false;
  }
  const code = c.charCodeAt(0);
  // 0-9
  if (code >= 48 && code <= 57) {
    return true;
  }
  // A-Z
  if (code >= 65 && code <= 90) {
    return true;
  }
  // a-z
  if (code >= 97 && code <= 122) {
    return true;
  }
  return c === '_' || c === '$';
}

/**
 * 还原 JS 字符串字面量里的转义
 * 源中的 idMatch 形如 "^(\\d+|jm\\d+)$", 需还原成 ^(\d+|jm\d+)$ 才能当正则用
 */
function unescapeJsString(s: string): string {
  if (s.indexOf('\\') < 0) {
    return s;
  }
  let out = '';
  let i = 0;
  while (i < s.length) {
    const c = s.charAt(i);
    if (c === '\\' && i + 1 < s.length) {
      const n = s.charAt(i + 1);
      if (n === 'n') {
        out += '\n';
      } else if (n === 't') {
        out += '\t';
      } else if (n === 'r') {
        out += '\r';
      } else {
        out += n;
      }
      i += 2;
      continue;
    }
    out += c;
    i++;
  }
  return out;
}

/**
 * 捕获 JS 静态字符串字段: key = "..." (sep='=') 或 url: "..." (sep=':')
 * 手写扫描(不用动态 RegExp, 规避 ArkTS 正则引擎差异)
 */
function extractStringField(js: string, field: string, sep: string = '='): string {
  let from = 0;
  while (from < js.length) {
    const idx = js.indexOf(field, from);
    if (idx < 0) {
      return '';
    }
    from = idx + field.length;
    // 前边界: field 前不能是标识符字符(避免 key 命中 groupKey)
    const prev = idx > 0 ? js.charAt(idx - 1) : '';
    if (isIdentChar(prev)) {
      continue;
    }
    // field 之后: 仅允许空白, 然后是分隔符
    let i = from;
    while (i < js.length) {
      const c = js.charAt(i);
      if (c === ' ' || c === '\t' || c === '\r' || c === '\n') {
        i++;
      } else {
        break;
      }
    }
    if (i >= js.length || js.charAt(i) !== sep) {
      continue;
    }
    i++;
    while (i < js.length) {
      const c = js.charAt(i);
      if (c === ' ' || c === '\t' || c === '\r' || c === '\n') {
        i++;
      } else {
        break;
      }
    }
    const quote = js.charAt(i);
    if (quote !== '"' && quote !== "'") {
      continue;
    }
    i++;
    const start = i;
    while (i < js.length && js.charAt(i) !== quote) {
      if (js.charAt(i) === '\\') {
        i++;
      }
      i++;
    }
    return js.substring(start, Math.min(i, js.length));
  }
  return '';
}

/** 跳过空白, 返回下一个非空白字符下标 */
function skipWs(s: string, from: number): number {
  let i = from;
  while (i < s.length) {
    const c = s.charAt(i);
    if (c === ' ' || c === '\t' || c === '\r' || c === '\n') {
      i++;
    } else {
      break;
    }
  }
  return i;
}

/** 从 open(必须是 '{') 起找配平的 '}', 失败返回 -1 */
function matchBrace(s: string, open: number): number {
  let depth = 0;
  let inStr = false;
  let quote = '';
  for (let i = open; i < s.length; i++) {
    const c = s.charAt(i);
    if (inStr) {
      if (c === '\\') {
        i++;
        continue;
      }
      if (c === quote) {
        inStr = false;
      }
      continue;
    }
    if (c === '"' || c === "'") {
      inStr = true;
      quote = c;
      continue;
    }
    if (c === '{') {
      depth++;
    } else if (c === '}') {
      depth--;
      if (depth === 0) {
        return i;
      }
    }
  }
  return -1;
}

/** 括号配平: 从指定字段名后截取第一个 {...} 对象 */
function extractObject(js: string, field: string): string {
  const idx = js.indexOf(field);
  if (idx < 0) {
    return '';
  }
  const open = js.indexOf('{', idx);
  if (open < 0) {
    return '';
  }
  const end = matchBrace(js, open);
  return end < 0 ? '' : js.substring(open, end + 1);
}

/** 从 settings 对象文本提取单个 SettingDef */
function extractSetting(key: string, objText: string): SettingDef {
  let title = key;
  const titleM = /title\s*:\s*["']([^"']*)["']/.exec(objText);
  if (titleM !== null) {
    title = titleM[1];
  }
  let type = 'input';
  const typeM = /type\s*:\s*["']([^"']*)["']/.exec(objText);
  if (typeM !== null) {
    type = typeM[1];
  }
  let def = '';
  const defM = /default\s*:\s*["']([^"']*)["']/.exec(objText);
  if (defM !== null) {
    def = defM[1];
  }
  // options: 抓数组内的字符串字面量(兼容 ["a","b"] 与 [{value:"a"}] 两种写法)
  const opts: string[] = [];
  const optArrM = /options\s*:\s*\[([^\]]*)\]/.exec(objText);
  if (optArrM !== null) {
    const valRe = /["']([^"']*)["']/g;
    let vm = valRe.exec(optArrM[1]);
    while (vm !== null) {
      opts.push(vm[1]);
      vm = valRe.exec(optArrM[1]);
    }
  }
  return new SettingDef(title, type, def, opts);
}

/** 解析 settings 对象为 Map(成员键支持 "key": {} 与 key: {}) */
function extractSettings(settingsText: string): Map<string, SettingDef> {
  const result = new Map<string, SettingDef>();
  const n = settingsText.length;
  let depth = 0;
  let i = 0;
  while (i < n) {
    const c = settingsText.charAt(i);
    if (c === '"' || c === "'") {
      // 字符串: 先整体跳出, 再判断是否为 "key": {...}
      const quote = c;
      let j = i + 1;
      const start = j;
      while (j < n && settingsText.charAt(j) !== quote) {
        if (settingsText.charAt(j) === '\\') {
          j++;
        }
        j++;
      }
      const strVal = settingsText.substring(start, Math.min(j, n));
      const after = skipWs(settingsText, j + 1);
      if (depth === 1 && settingsText.charAt(after) === ':') {
        const open = skipWs(settingsText, after + 1);
        if (settingsText.charAt(open) === '{') {
          const end = matchBrace(settingsText, open);
          if (end > open) {
            result.set(strVal, extractSetting(strVal, settingsText.substring(open, end + 1)));
            i = end + 1;
            continue;
          }
        }
      }
      i = j + 1;
      continue;
    }
    if (c === '{') {
      depth++;
      i++;
      continue;
    }
    if (c === '}') {
      depth--;
      i++;
      continue;
    }
    // 裸标识符键(仅在 settings 顶层)
    if (depth === 1 && isIdentChar(c)) {
      let j = i;
      while (j < n) {
        const k = settingsText.charAt(j);
        if (isIdentChar(k) || k === '.' || k === '-') {
          j++;
        } else {
          break;
        }
      }
      const bareKey = settingsText.substring(i, j);
      const after = skipWs(settingsText, j);
      if (settingsText.charAt(after) === ':') {
        const open = skipWs(settingsText, after + 1);
        if (settingsText.charAt(open) === '{') {
          const end = matchBrace(settingsText, open);
          if (end > open) {
            result.set(bareKey, extractSetting(bareKey, settingsText.substring(open, end + 1)));
            i = end + 1;
            continue;
          }
        }
      }
      i = j;
      continue;
    }
    i++;
  }
  return result;
}

/** 生成内容预览(压缩空白), 用于失败诊断 */
function previewOf(js: string): string {
  const oneLine = js.replace(/\s+/g, ' ').trim();
  return oneLine.length > 80 ? oneLine.substring(0, 80) + '...' : oneLine;
}

/**
 * 解析 JS 源脚本文本为 ComicSourceMeta
 * @param js 源脚本全文
 * @param filePath 磁盘路径
 * @param fileName 文件名
 * @throws ComicSourceParseException 非源脚本 / key 非法
 */
export function parse(js: string, filePath: string, fileName: string): ComicSourceMeta {
  // 1. 校验(允许 extends 与 ComicSource 间任意空白)
  if (!/extends\s+ComicSource/.test(js)) {
    throw new ComicSourceParseException('缺少 extends ComicSource。文件开头: ' + previewOf(js));
  }
  const classRe = /class\s+(\w+)\s+extends\s+ComicSource/;
  const cm = classRe.exec(js);
  if (cm === null) {
    throw new ComicSourceParseException('未找到 class 定义。文件开头: ' + previewOf(js));
  }

  // 2. 元信息
  const key = extractStringField(js, 'key');
  const name = extractStringField(js, 'name');
  const version = extractStringField(js, 'version');
  const minAppVersion = extractStringField(js, 'minAppVersion');
  const url = extractStringField(js, 'url');

  if (key.length === 0) {
    throw new ComicSourceParseException('key is empty');
  }
  if (!/^[a-zA-Z0-9_]+$/.test(key)) {
    throw new ComicSourceParseException('key only supports [a-zA-Z0-9_]');
  }

  const meta = new ComicSourceMeta(key, name.length > 0 ? name : key, version.length > 0 ? version : '1.0.0');
  meta.minAppVersion = minAppVersion;
  meta.url = url;
  meta.fileName = key + '.js';
  meta.filePath = filePath;

  // 3. 能力探测(子串存在性)
  meta.hasExplore = js.indexOf('explore') >= 0;
  meta.hasSearch = js.indexOf('search') >= 0;
  meta.hasLoadInfo = js.indexOf('loadComicInfo') >= 0 || js.indexOf('loadInfo') >= 0;
  meta.hasLoadEp = js.indexOf('loadComicPages') >= 0 || js.indexOf('loadEp') >= 0;
  meta.hasSettings = js.indexOf('settings') >= 0;
  meta.hasAccount = js.indexOf('account') >= 0;

  // 3.5 漫画 ID 规则(comic.idMatch): 搜索框命中时可按 ID 直达, 由 B 阶段真引擎校正
  meta.idMatcher = unescapeJsString(extractStringField(js, 'idMatch', ':'));

  // 4. settings
  if (meta.hasSettings) {
    const settingsText = extractObject(js, 'settings');
    if (settingsText.length > 0) {
      meta.settings = extractSettings(settingsText);
    }
  }

  // 5. account
  if (meta.hasAccount) {
    const acc = new AccountMeta();
    acc.hasLogin = js.indexOf('login(') >= 0 || js.indexOf('login (') >= 0
      || js.indexOf('login:') >= 0 || js.indexOf('login :') >= 0;
    acc.loginUrl = extractStringField(js, 'login', ':');
    // loginWithWebview / loginWithCookies 均为对象, 用括号配平提取(避免未转义 { 触发正则错误)
    const webObj = extractObject(js, 'loginWithWebview');
    acc.hasWebviewLogin = webObj.length > 0;
    if (webObj.length > 0) {
      acc.webviewUrl = extractStringField(webObj, 'url', ':');
    }
    const cookiesObj = extractObject(js, 'loginWithCookies');
    acc.hasCookiesValidate = cookiesObj.length > 0;
    if (cookiesObj.length > 0) {
      // 从 loginWithCookies 对象中提取 fields 数组（如 ["ipb_member_id","ipb_pass_hash","igneous","star"]）
      const fieldsArrM = /fields\s*:\s*\[([^\]]*)\]/.exec(cookiesObj);
      if (fieldsArrM !== null) {
        const valRe = /["']([^"']*)["']/g;
        let vm = valRe.exec(fieldsArrM[1]);
        while (vm !== null) {
          acc.cookieFields.push(vm[1]);
          vm = valRe.exec(fieldsArrM[1]);
        }
      }
    }
    meta.account = acc;
  }

  return meta;
}

/** 语义化版本比较: v1 > v2 => 1; v1 < v2 => -1; 相等 => 0 */
export function compareSemVer(v1: string, v2: string): number {
  const p1 = v1.split('.').map((s) => parseInt(s, 10) || 0);
  const p2 = v2.split('.').map((s) => parseInt(s, 10) || 0);
  const len = Math.max(p1.length, p2.length);
  for (let i = 0; i < len; i++) {
    const a = i < p1.length ? p1[i] : 0;
    const b = i < p2.length ? p2[i] : 0;
    if (a !== b) {
      return a > b ? 1 : -1;
    }
  }
  return 0;
}