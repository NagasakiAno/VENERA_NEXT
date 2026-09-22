/**
 * VeneraNext 轻量 HTML DOM
 *
 * 为 JS 源的 HtmlDocument / HtmlElement / HtmlNode 提供:
 *   1. HTML 解析(标签/属性/文本/注释, script|style 原文保留)
 *   2. CSS 选择器查询(tag / #id / .class / [attr op value] / 后代 / 子代 / 逗号分组 / 常见伪类)
 *   3. element 与 node 的注册表(key 由 JS 侧 HtmlDocument 分配, 与原版一致)
 *
 * 只实现漫画源实际用到的子集, 不做完整 HTML5 规范(宽松纠错即可)。
 */

/** 节点类型 */
export enum DomKind {
  ELEMENT = 0,
  TEXT = 1,
  COMMENT = 2,
  DOCUMENT = 3,
}

/** DOM 节点 */
export class DomNode {
  kind: DomKind = DomKind.ELEMENT;
  tag: string = '';
  attrs: Map<string, string> = new Map<string, string>();
  children: DomNode[] = [];
  parent: DomNode | null = null;
  /** TEXT / COMMENT 的内容 */
  text: string = '';

  attr(name: string): string {
    const v = this.attrs.get(name);
    return v === undefined ? '' : v;
  }

  classList(): string[] {
    const raw = this.attr('class').trim();
    if (raw.length === 0) {
      return [];
    }
    const out: string[] = [];
    const parts = raw.split(' ');
    for (let i = 0; i < parts.length; i++) {
      const p = parts[i].replace(/\t|\r|\n/g, '');
      if (p.length > 0) {
        out.push(p);
      }
    }
    return out;
  }

  /** 自身及后代全部文本 */
  allText(): string {
    if (this.kind === DomKind.TEXT || this.kind === DomKind.COMMENT) {
      return this.text;
    }
    let out = '';
    for (let i = 0; i < this.children.length; i++) {
      out += this.children[i].allText();
    }
    return out;
  }

  /** 直接子元素 */
  childElements(): DomNode[] {
    const out: DomNode[] = [];
    for (let i = 0; i < this.children.length; i++) {
      if (this.children[i].kind === DomKind.ELEMENT) {
        out.push(this.children[i]);
      }
    }
    return out;
  }

  /** 收集全部后代元素(先序, 不含自身) */
  collectDescendants(out: DomNode[]): void {
    for (let i = 0; i < this.children.length; i++) {
      const c = this.children[i];
      if (c.kind === DomKind.ELEMENT) {
        out.push(c);
        c.collectDescendants(out);
      }
    }
  }

  /** 序列化(用于 innerHTML) */
  serializeChildren(): string {
    let out = '';
    for (let i = 0; i < this.children.length; i++) {
      out += this.children[i].serialize();
    }
    return out;
  }

  serialize(): string {
    if (this.kind === DomKind.TEXT) {
      return this.text;
    }
    if (this.kind === DomKind.COMMENT) {
      return '<!--' + this.text + '-->';
    }
    if (this.kind === DomKind.DOCUMENT) {
      return this.serializeChildren();
    }
    let out = '<' + this.tag;
    this.attrs.forEach((v: string, k: string) => {
      out += ' ' + k + '="' + v.replace(/"/g, '&quot;') + '"';
    });
    out += '>';
    out += this.serializeChildren();
    if (!isVoidTag(this.tag)) {
      out += '</' + this.tag + '>';
    }
    return out;
  }
}

// ------------------------------------------------------------------ 解析

const VOID_TAGS: string[] = ['area', 'base', 'br', 'col', 'embed', 'hr', 'img', 'input',
  'link', 'meta', 'param', 'source', 'track', 'wbr'];

function isVoidTag(tag: string): boolean {
  return VOID_TAGS.indexOf(tag) >= 0;
}

function isSpace(c: string): boolean {
  return c === ' ' || c === '\t' || c === '\r' || c === '\n' || c === '\f';
}

/** 常见实体解码 */
function namedEntity(name: string): string {
  switch (name) {
    case 'amp': return '&';
    case 'lt': return '<';
    case 'gt': return '>';
    case 'quot': return '"';
    case 'apos': return "'";
    case 'nbsp': return ' ';
    case 'copy': return '©';
    case 'reg': return '®';
    case 'hellip': return '…';
    case 'mdash': return '—';
    case 'ndash': return '–';
    case 'ldquo': return '“';
    case 'rdquo': return '”';
    case 'lsquo': return '‘';
    case 'rsquo': return '’';
    case 'middot': return '·';
    case 'times': return '×';
    case 'laquo': return '«';
    case 'raquo': return '»';
    default: return '';
  }
}

function decodeEntities(s: string): string {
  if (s.indexOf('&') < 0) {
    return s;
  }
  let out = '';
  let i = 0;
  const n = s.length;
  while (i < n) {
    const amp = s.indexOf('&', i);
    if (amp < 0) {
      out += s.substring(i);
      break;
    }
    out += s.substring(i, amp);
    const semi = s.indexOf(';', amp + 1);
    if (semi < 0 || semi - amp > 12) {
      out += '&';
      i = amp + 1;
      continue;
    }
    const body = s.substring(amp + 1, semi);
    let decoded = '';
    if (body.startsWith('#x') || body.startsWith('#X')) {
      const code = parseInt(body.substring(2), 16);
      if (!isNaN(code) && code > 0) {
        decoded = String.fromCharCode(code);
      }
    } else if (body.startsWith('#')) {
      const code = parseInt(body.substring(1), 10);
      if (!isNaN(code) && code > 0) {
        decoded = String.fromCharCode(code);
      }
    } else {
      decoded = namedEntity(body);
    }
    if (decoded.length === 0) {
      out += '&' + body + ';';
    } else {
      out += decoded;
    }
    i = semi + 1;
  }
  return out;
}

/** 找标签结束的 '>'(跳过引号内的) */
function findTagEnd(html: string, start: number): number {
  let i = start + 1;
  let quote = '';
  while (i < html.length) {
    const c = html.charAt(i);
    if (quote.length > 0) {
      if (c === quote) {
        quote = '';
      }
    } else if (c === '"' || c === "'") {
      quote = c;
    } else if (c === '>') {
      return i;
    }
    i++;
  }
  return -1;
}

function appendChild(parent: DomNode, child: DomNode): void {
  child.parent = parent;
  parent.children.push(child);
}

function appendText(parent: DomNode, raw: string): void {
  if (raw.length === 0) {
    return;
  }
  const node = new DomNode();
  node.kind = DomKind.TEXT;
  node.text = decodeEntities(raw);
  appendChild(parent, node);
}

/** 由标签内部文本构建元素 */
function buildElement(body: string): DomNode | null {
  let i = 0;
  const n = body.length;
  while (i < n && isSpace(body.charAt(i))) {
    i++;
  }
  const nameStart = i;
  while (i < n) {
    const c = body.charAt(i);
    if (isSpace(c) || c === '/') {
      break;
    }
    i++;
  }
  const name = body.substring(nameStart, i).toLowerCase();
  if (name.length === 0) {
    return null;
  }
  const node = new DomNode();
  node.kind = DomKind.ELEMENT;
  node.tag = name;

  while (i < n) {
    while (i < n && isSpace(body.charAt(i))) {
      i++;
    }
    if (i >= n) {
      break;
    }
    const aStart = i;
    while (i < n) {
      const c = body.charAt(i);
      if (isSpace(c) || c === '=') {
        break;
      }
      i++;
    }
    const aName = body.substring(aStart, i).toLowerCase();
    if (aName.length === 0) {
      i++;
      continue;
    }
    while (i < n && isSpace(body.charAt(i))) {
      i++;
    }
    let aValue = '';
    if (i < n && body.charAt(i) === '=') {
      i++;
      while (i < n && isSpace(body.charAt(i))) {
        i++;
      }
      const quote = body.charAt(i);
      if (quote === '"' || quote === "'") {
        i++;
        const vStart = i;
        while (i < n && body.charAt(i) !== quote) {
          i++;
        }
        aValue = body.substring(vStart, i);
        i++;
      } else {
        const vStart = i;
        while (i < n && !isSpace(body.charAt(i))) {
          i++;
        }
        aValue = body.substring(vStart, i);
      }
    }
    // HTML5 规范: 同一标签上的重复属性, 以「第一个」为准(后来的丢弃)。
    // 部分站点确实会输出 `class="bodywrap" class="cc"` 这种重复属性,
    // 若用后者覆盖, 元素的真实 class 会丢失, 源的 `div.bodywrap` 就会命中 0。
    if (!node.attrs.has(aName)) {
      node.attrs.set(aName, decodeEntities(aValue));
    }
  }
  return node;
}

/** 解析 HTML 为文档节点 */
export function parseHtml(html: string): DomNode {
  const doc = new DomNode();
  doc.kind = DomKind.DOCUMENT;
  const stack: DomNode[] = [doc];
  const lower = html.toLowerCase();
  let i = 0;
  const n = html.length;

  while (i < n) {
    const lt = html.indexOf('<', i);
    if (lt < 0) {
      appendText(stack[stack.length - 1], html.substring(i));
      break;
    }
    if (lt > i) {
      appendText(stack[stack.length - 1], html.substring(i, lt));
    }

    // 注释
    if (html.startsWith('<!--', lt)) {
      const end = html.indexOf('-->', lt + 4);
      const node = new DomNode();
      node.kind = DomKind.COMMENT;
      node.text = end < 0 ? html.substring(lt + 4) : html.substring(lt + 4, end);
      appendChild(stack[stack.length - 1], node);
      i = end < 0 ? n : end + 3;
      continue;
    }
    // doctype / 处理指令
    if (html.startsWith('<!', lt) || html.startsWith('<?', lt)) {
      const end = html.indexOf('>', lt);
      i = end < 0 ? n : end + 1;
      continue;
    }
    // 闭合标签
    if (html.startsWith('</', lt)) {
      const end = html.indexOf('>', lt);
      if (end < 0) {
        break;
      }
      const name = html.substring(lt + 2, end).trim().toLowerCase();
      for (let s = stack.length - 1; s > 0; s--) {
        if (stack[s].tag === name) {
          stack.splice(s, stack.length - s);
          break;
        }
      }
      i = end + 1;
      continue;
    }

    // 开标签
    const end = findTagEnd(html, lt);
    if (end < 0) {
      break;
    }
    let inner = html.substring(lt + 1, end);
    let selfClose = false;
    if (inner.endsWith('/')) {
      selfClose = true;
      inner = inner.substring(0, inner.length - 1);
    }
    const node = buildElement(inner);
    if (node === null) {
      i = end + 1;
      continue;
    }
    // HTML5 解析规则: <table> 下直接出现的 <tr> 会被补一层隐式 <tbody>
    // (浏览器与 package:html 都这么做; 源的 `table.xxx > tbody > tr` 依赖它,
    //  否则命中为 0, 列表页会「无报错但全空」)
    if (node.tag === 'tr' && stack[stack.length - 1].tag === 'table') {
      const implicit = new DomNode();
      implicit.kind = DomKind.ELEMENT;
      implicit.tag = 'tbody';
      appendChild(stack[stack.length - 1], implicit);
      stack.push(implicit);
    }
    appendChild(stack[stack.length - 1], node);

    // script / style 内容按原文保留, 直接跳到闭合标签
    if (node.tag === 'script' || node.tag === 'style') {
      const closeTag = '</' + node.tag;
      const closeIdx = lower.indexOf(closeTag, end + 1);
      if (closeIdx >= 0) {
        const raw = html.substring(end + 1, closeIdx);
        if (raw.length > 0) {
          const t = new DomNode();
          t.kind = DomKind.TEXT;
          t.text = raw;
          appendChild(node, t);
        }
        const gt = html.indexOf('>', closeIdx);
        i = gt < 0 ? n : gt + 1;
        continue;
      }
    }

    if (!selfClose && !isVoidTag(node.tag)) {
      stack.push(node);
    }
    i = end + 1;
  }
  return doc;
}

// ------------------------------------------------------------------ 选择器

/** 属性条件 */
class AttrCond {
  name: string = '';
  op: string = '';
  value: string = '';
}

/** 选择器单元(单步) */
class SelPart {
  tag: string = '';
  id: string = '';
  classes: string[] = [];
  attrs: AttrCond[] = [];
  /** 与前一步的关系: ' ' 后代 | '>' 子代 */
  combinator: string = ' ';
  /** 仅支持 first-child / last-child / nth-child */
  pseudo: string = '';
  pseudoArg: number = 0;

  matches(node: DomNode): boolean {
    if (node.kind !== DomKind.ELEMENT) {
      return false;
    }
    if (this.tag.length > 0 && this.tag !== '*' && node.tag !== this.tag) {
      return false;
    }
    if (this.id.length > 0 && node.attr('id') !== this.id) {
      return false;
    }
    if (this.classes.length > 0) {
      const cls = node.classList();
      for (let i = 0; i < this.classes.length; i++) {
        if (cls.indexOf(this.classes[i]) < 0) {
          return false;
        }
      }
    }
    for (let i = 0; i < this.attrs.length; i++) {
      const cond = this.attrs[i];
      const actual = node.attrs.get(cond.name);
      if (actual === undefined) {
        return false;
      }
      if (cond.op.length === 0) {
        continue;
      }
      if (cond.op === '=') {
        if (actual !== cond.value) {
          return false;
        }
      } else if (cond.op === '*=') {
        if (actual.indexOf(cond.value) < 0) {
          return false;
        }
      } else if (cond.op === '^=') {
        if (!actual.startsWith(cond.value)) {
          return false;
        }
      } else if (cond.op === '$=') {
        if (!actual.endsWith(cond.value)) {
          return false;
        }
      } else if (cond.op === '~=') {
        if (actual.split(' ').indexOf(cond.value) < 0) {
          return false;
        }
      }
    }
    if (this.pseudo.length > 0) {
      const siblings = node.parent === null ? [] : node.parent.childElements();
      const idx = siblings.indexOf(node);
      if (this.pseudo === 'first-child' && idx !== 0) {
        return false;
      }
      if (this.pseudo === 'last-child' && idx !== siblings.length - 1) {
        return false;
      }
      if (this.pseudo === 'nth-child' && idx !== this.pseudoArg - 1) {
        return false;
      }
    }
    return true;
  }
}

function isSelDelim(c: string): boolean {
  return c === '.' || c === '#' || c === '[' || c === ':' || c === '(' || c === ')' || isSpace(c);
}

function parseAttrCond(inner: string): AttrCond | null {
  const cond = new AttrCond();
  const text = inner.trim();
  if (text.length === 0) {
    return null;
  }
  const eq = text.indexOf('=');
  if (eq < 0) {
    cond.name = text.toLowerCase();
    return cond.name.length > 0 ? cond : null;
  }
  let name = text.substring(0, eq).trim();
  let op = '=';
  const last = name.length > 0 ? name.charAt(name.length - 1) : '';
  if (last === '*' || last === '^' || last === '$' || last === '~' || last === '|') {
    op = last + '=';
    name = name.substring(0, name.length - 1);
  }
  cond.name = name.trim().toLowerCase();
  let value = text.substring(eq + 1).trim();
  if (value.length >= 2) {
    const q = value.charAt(0);
    if ((q === '"' || q === "'") && value.endsWith(q)) {
      value = value.substring(1, value.length - 1);
    }
  }
  cond.value = value;
  cond.op = op;
  return cond;
}

function parseSelPart(text: string): SelPart {
  const part = new SelPart();
  const n = text.length;
  let i = 0;
  // 标签名
  while (i < n) {
    const c = text.charAt(i);
    if (c === '.' || c === '#' || c === '[' || c === ':') {
      break;
    }
    part.tag += c;
    i++;
  }
  part.tag = part.tag.trim().toLowerCase();

  while (i < n) {
    const c = text.charAt(i);
    if (c === ':') {
      // 伪类: 支持 first-child / last-child / nth-child(n)
      i++;
      let name = '';
      while (i < n) {
        const ch = text.charAt(i);
        if (ch === '(' || ch === '.' || ch === '#' || ch === '[' || isSpace(ch)) {
          break;
        }
        name += ch;
        i++;
      }
      let arg = 0;
      if (i < n && text.charAt(i) === '(') {
        const close = text.indexOf(')', i);
        const inner = close < 0 ? '' : text.substring(i + 1, close);
        arg = parseInt(inner, 10);
        i = close < 0 ? n : close + 1;
      }
      const lower = name.toLowerCase();
      if (lower === 'first-child' || lower === 'last-child') {
        part.pseudo = lower;
      } else if (lower === 'nth-child' && !isNaN(arg)) {
        part.pseudo = 'nth-child';
        part.pseudoArg = arg;
      }
      continue;
    }
    if (c === '.') {
      i++;
      let name = '';
      while (i < n && !isSelDelim(text.charAt(i))) {
        name += text.charAt(i);
        i++;
      }
      if (name.length > 0) {
        part.classes.push(name);
      }
      continue;
    }
    if (c === '#') {
      i++;
      let name = '';
      while (i < n && !isSelDelim(text.charAt(i))) {
        name += text.charAt(i);
        i++;
      }
      part.id = name;
      continue;
    }
    if (c === '[') {
      const close = text.indexOf(']', i);
      if (close < 0) {
        break;
      }
      const cond = parseAttrCond(text.substring(i + 1, close));
      if (cond !== null) {
        part.attrs.push(cond);
      }
      i = close + 1;
      continue;
    }
    i++;
  }
  return part;
}

/** 解析整条选择器为若干步 */
function parseSelector(text: string): SelPart[] {
  const parts: SelPart[] = [];
  const n = text.length;
  let i = 0;
  let buf = '';
  let combinator = ' ';

  const flush = (): void => {
    const trimmed = buf.trim();
    if (trimmed.length > 0) {
      const part = parseSelPart(trimmed);
      part.combinator = parts.length === 0 ? ' ' : combinator;
      parts.push(part);
    }
    buf = '';
  };

  while (i < n) {
    const c = text.charAt(i);
    if (c === '>') {
      flush();
      combinator = '>';
      i++;
      continue;
    }
    if (isSpace(c)) {
      flush();
      if (combinator !== '>') {
        combinator = ' ';
      }
      i++;
      continue;
    }
    buf += c;
    i++;
  }
  flush();
  return parts;
}

function queryGroup(root: DomNode, selector: string): DomNode[] {
  const parts = parseSelector(selector);
  if (parts.length === 0) {
    return [];
  }
  let current: DomNode[] = [];
  root.collectDescendants(current);

  for (let pi = 0; pi < parts.length; pi++) {
    const part = parts[pi];
    const next: DomNode[] = [];
    if (pi === 0) {
      for (let i = 0; i < current.length; i++) {
        if (part.matches(current[i])) {
          next.push(current[i]);
        }
      }
    } else if (part.combinator === '>') {
      for (let i = 0; i < current.length; i++) {
        const kids = current[i].childElements();
        for (let k = 0; k < kids.length; k++) {
          if (part.matches(kids[k])) {
            next.push(kids[k]);
          }
        }
      }
    } else {
      for (let i = 0; i < current.length; i++) {
        const pool: DomNode[] = [];
        current[i].collectDescendants(pool);
        for (let d = 0; d < pool.length; d++) {
          if (part.matches(pool[d])) {
            next.push(pool[d]);
          }
        }
      }
    }
    current = next;
    if (current.length === 0) {
      break;
    }
  }
  return current;
}

/** 查询全部匹配元素(支持逗号分组) */
export function querySelectorAll(root: DomNode, selector: string): DomNode[] {
  const out: DomNode[] = [];
  const groups = selector.split(',');
  for (let g = 0; g < groups.length; g++) {
    const group = groups[g].trim();
    if (group.length === 0) {
      continue;
    }
    const found = queryGroup(root, group);
    for (let i = 0; i < found.length; i++) {
      if (out.indexOf(found[i]) < 0) {
        out.push(found[i]);
      }
    }
  }
  return out;
}
