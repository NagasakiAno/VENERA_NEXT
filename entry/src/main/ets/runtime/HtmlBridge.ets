/**
 * HTML DOM 桥
 *
 * 承接 JS 源里 HtmlDocument / HtmlElement / HtmlNode 的全部查询请求。
 * key 由 JS 侧 HtmlDocument._key 自增分配, doc 为所属文档 key, 与原版一致。
 *
 * 同时打开的文档数有上限(默认 8), 超出时丢弃最早的, 避免源忘记 dispose 造成内存膨胀。
 */
import { hilog } from '@kit.PerformanceAnalysisKit';
import { DomNode, DomKind, parseHtml, querySelectorAll } from '../parser/HtmlDom';

const DOMAIN = 0x0000;
const TAG = 'HtmlBridge';
const MAX_DOCS = 8;

/** html 桥请求参数 */
export interface HtmlRequest {
  function: string;
  key: number;
  doc: number;
  query: string;
  id: string;
  data: string;
}

/** 单个已解析文档 */
class DocEntry {
  root: DomNode;
  elements: DomNode[] = [];
  nodes: DomNode[] = [];

  constructor(root: DomNode) {
    this.root = root;
  }
}

export class HtmlBridge {
  private static instance: HtmlBridge = new HtmlBridge();
  private docs: Map<number, DocEntry> = new Map<number, DocEntry>();
  private order: number[] = [];

  static getInstance(): HtmlBridge {
    return HtmlBridge.instance;
  }

  /** 按 function 分发, 返回可直接 JSON 化的结果 */
  handle(req: HtmlRequest): Object | null {
    const fn = req.function;
    switch (fn) {
      case 'parse':
        this.onParse(req);
        return null;
      case 'dispose':
        this.drop(req.key);
        return null;
      case 'querySelector':
        return this.onQuerySelector(req.key, req.query);
      case 'querySelectorAll':
        return this.onQuerySelectorAll(req.key, req.query);
      case 'getElementById':
        return this.onGetElementById(req.key, req.id);
      case 'getText': {
        const node = this.elementOf(req.doc, req.key);
        return node === null ? null : node.allText();
      }
      case 'getAttributes': {
        const node = this.elementOf(req.doc, req.key);
        return node === null ? null : this.attrMap(node);
      }
      case 'getInnerHTML': {
        const node = this.elementOf(req.doc, req.key);
        return node === null ? null : node.serializeChildren();
      }
      case 'getClassNames': {
        const node = this.elementOf(req.doc, req.key);
        return node === null ? null : node.classList();
      }
      case 'getId': {
        const node = this.elementOf(req.doc, req.key);
        if (node === null) {
          return null;
        }
        const id = node.attr('id');
        return id.length === 0 ? null : id;
      }
      case 'getLocalName': {
        const node = this.elementOf(req.doc, req.key);
        return node === null ? null : node.tag;
      }
      case 'getChildren':
        return this.onChildren(req.doc, req.key);
      case 'getNodes':
        return this.onNodes(req.doc, req.key);
      case 'getParent':
        return this.onParent(req.doc, req.key);
      case 'getPreviousSibling':
        return this.onSibling(req.doc, req.key, false);
      case 'getNextSibling':
        return this.onSibling(req.doc, req.key, true);
      case 'dom_querySelector':
        return this.onElementQuerySelector(req.doc, req.key, req.query);
      case 'dom_querySelectorAll':
        return this.onElementQuerySelectorAll(req.doc, req.key, req.query);
      case 'node_text': {
        const node = this.nodeOf(req.doc, req.key);
        return node === null ? null : node.text;
      }
      case 'node_type': {
        const node = this.nodeOf(req.doc, req.key);
        return node === null ? null : HtmlBridge.kindName(node.kind);
      }
      case 'node_toElement':
        return this.onNodeToElement(req.doc, req.key);
      default:
        hilog.warn(DOMAIN, TAG, '未实现的 html 方法: %{public}s', fn);
        return null;
    }
  }

  /** 当前打开的文档数 */
  docCount(): number {
    return this.docs.size;
  }

  // ------------------------------------------------------------ 文档

  private onParse(req: HtmlRequest): void {
    if (this.docs.has(req.key)) {
      this.docs.delete(req.key);
    }
    const entry = new DocEntry(parseHtml(req.data));
    this.docs.set(req.key, entry);
    this.order.push(req.key);
    while (this.order.length > MAX_DOCS) {
      const oldest = this.order.shift();
      if (oldest !== undefined) {
        this.docs.delete(oldest);
        hilog.warn(DOMAIN, TAG, '文档数超限, 已释放 doc=%{public}d', oldest);
      }
    }
  }

  private drop(key: number): void {
    this.docs.delete(key);
    const idx = this.order.indexOf(key);
    if (idx >= 0) {
      this.order.splice(idx, 1);
    }
  }

  private entry(docKey: number): DocEntry | null {
    const e = this.docs.get(docKey);
    return e === undefined ? null : e;
  }

  private elementOf(docKey: number, key: number): DomNode | null {
    const entry = this.entry(docKey);
    if (entry === null || key < 0 || key >= entry.elements.length) {
      return null;
    }
    return entry.elements[key];
  }

  private nodeOf(docKey: number, key: number): DomNode | null {
    const entry = this.entry(docKey);
    if (entry === null || key < 0 || key >= entry.nodes.length) {
      return null;
    }
    return entry.nodes[key];
  }

  private pushElement(entry: DocEntry, node: DomNode): number {
    entry.elements.push(node);
    return entry.elements.length - 1;
  }

  private pushNode(entry: DocEntry, node: DomNode): number {
    entry.nodes.push(node);
    return entry.nodes.length - 1;
  }

  // ------------------------------------------------------------ 查询

  private onQuerySelector(docKey: number, query: string): Object | null {
    const entry = this.entry(docKey);
    if (entry === null) {
      return null;
    }
    const found = querySelectorAll(entry.root, query);
    if (found.length === 0) {
      return null;
    }
    return this.pushElement(entry, found[0]);
  }

  private onQuerySelectorAll(docKey: number, query: string): Object {
    const out: number[] = [];
    const entry = this.entry(docKey);
    if (entry === null) {
      return out;
    }
    const found = querySelectorAll(entry.root, query);
    for (let i = 0; i < found.length; i++) {
      out.push(this.pushElement(entry, found[i]));
    }
    return out;
  }

  private onGetElementById(docKey: number, id: string): Object | null {
    const entry = this.entry(docKey);
    if (entry === null || id.length === 0) {
      return null;
    }
    const found = querySelectorAll(entry.root, '#' + id);
    if (found.length === 0) {
      return null;
    }
    return this.pushElement(entry, found[0]);
  }

  private onElementQuerySelector(docKey: number, key: number, query: string): Object | null {
    const entry = this.entry(docKey);
    const root = this.elementOf(docKey, key);
    if (entry === null || root === null) {
      return null;
    }
    const found = querySelectorAll(root, query);
    if (found.length === 0) {
      return null;
    }
    return this.pushElement(entry, found[0]);
  }

  private onElementQuerySelectorAll(docKey: number, key: number, query: string): Object {
    const out: number[] = [];
    const entry = this.entry(docKey);
    const root = this.elementOf(docKey, key);
    if (entry === null || root === null) {
      return out;
    }
    const found = querySelectorAll(root, query);
    for (let i = 0; i < found.length; i++) {
      out.push(this.pushElement(entry, found[i]));
    }
    return out;
  }

  private onChildren(docKey: number, key: number): Object {
    const out: number[] = [];
    const entry = this.entry(docKey);
    const node = this.elementOf(docKey, key);
    if (entry === null || node === null) {
      return out;
    }
    const kids = node.childElements();
    for (let i = 0; i < kids.length; i++) {
      out.push(this.pushElement(entry, kids[i]));
    }
    return out;
  }

  private onNodes(docKey: number, key: number): Object {
    const out: number[] = [];
    const entry = this.entry(docKey);
    const node = this.elementOf(docKey, key);
    if (entry === null || node === null) {
      return out;
    }
    for (let i = 0; i < node.children.length; i++) {
      out.push(this.pushNode(entry, node.children[i]));
    }
    return out;
  }

  private onParent(docKey: number, key: number): Object | null {
    const entry = this.entry(docKey);
    const node = this.elementOf(docKey, key);
    if (entry === null || node === null || node.parent === null) {
      return null;
    }
    const parent = node.parent;
    if (parent.kind !== DomKind.ELEMENT) {
      return null;
    }
    return this.pushElement(entry, parent);
  }

  private onSibling(docKey: number, key: number, forward: boolean): Object | null {
    const entry = this.entry(docKey);
    const node = this.elementOf(docKey, key);
    if (entry === null || node === null || node.parent === null) {
      return null;
    }
    const siblings = node.parent.childElements();
    const idx = siblings.indexOf(node);
    if (idx < 0) {
      return null;
    }
    const target = forward ? idx + 1 : idx - 1;
    if (target < 0 || target >= siblings.length) {
      return null;
    }
    return this.pushElement(entry, siblings[target]);
  }

  private onNodeToElement(docKey: number, key: number): Object | null {
    const entry = this.entry(docKey);
    const node = this.nodeOf(docKey, key);
    if (entry === null || node === null || node.kind !== DomKind.ELEMENT) {
      return null;
    }
    return this.pushElement(entry, node);
  }

  private attrMap(node: DomNode): Object {
    const out: Record<string, string> = {};
    node.attrs.forEach((v: string, k: string) => {
      out[k] = v;
    });
    return out;
  }

  private static kindName(kind: DomKind): string {
    if (kind === DomKind.ELEMENT) {
      return 'element';
    }
    if (kind === DomKind.TEXT) {
      return 'text';
    }
    if (kind === DomKind.COMMENT) {
      return 'comment';
    }
    if (kind === DomKind.DOCUMENT) {
      return 'document';
    }
    return 'unknown';
  }
}

/** 全局单例 */
export const htmlBridge = HtmlBridge.getInstance();
