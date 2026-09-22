/**
 * VeneraNext EPUB 解析器(性能优化版)
 * 1. zlib 解压 epub(zip) 到沙箱目录
 * 2. 解析 META-INF/container.xml -> OPF 路径
 * 3. 解析 OPF manifest/spine -> 章节顺序与 href
 * 4. 每章只记录文件路径(不读全文), RICH 页由 Web loadUrl 直接加载本地文件,
 *    图片相对路径由浏览器自动解析, 避免整本书 HTML 一次性读入内存
 * 容错: 解析失败时回退全文单章
 */
import { fileIo as fs } from '@kit.CoreFileKit';
import { util } from '@kit.ArkTS';
import { zlib } from '@kit.BasicServicesKit';
import { ReaderChapter, ReaderPageItem, ReaderPageType } from '../../model/ReaderModel';

const TAG = 'EpubParser';

/** 读文件为 UTF-8 字符串(仅用于 XML 元数据, 章节正文不预读) */
function readText(path: string): string {
  if (!fs.accessSync(path)) {
    return '';
  }
  const f = fs.openSync(path, fs.OpenMode.READ_ONLY);
  try {
    const stat = fs.statSync(f.fd);
    const buf = new ArrayBuffer(stat.size);
    fs.readSync(f.fd, buf);
    const decoder = util.TextDecoder.create('utf-8');
    return decoder.decodeToString(new Uint8Array(buf));
  } finally {
    fs.closeSync(f);
  }
}

/** 从 container.xml 提取 rootfile 的 full-path(OPF 路径) */
function findOpfPath(root: string): string {
  const xml = readText(root + '/META-INF/container.xml');
  if (xml.length === 0) {
    return '';
  }
  const m = /full-path\s*=\s*["']([^"']+)["']/.exec(xml);
  return m !== null ? m[1] : '';
}

class ManifestItem {
  id: string;
  href: string;
  mediaType: string;

  constructor(id: string, href: string, mediaType: string) {
    this.id = id;
    this.href = href;
    this.mediaType = mediaType;
  }
}

class OpfInfo {
  items: ManifestItem[];
  spineIds: string[];

  constructor(items: ManifestItem[], spineIds: string[]) {
    this.items = items;
    this.spineIds = spineIds;
  }
}

/** 解析 OPF: 返回 manifest 列表与 spine 顺序的 idref */
function parseOpf(opfXml: string): OpfInfo {
  const items: ManifestItem[] = [];
  // manifest 的 <item ...>
  const itemRe = /<item\s+([^>]*)>/g;
  let mm = itemRe.exec(opfXml);
  while (mm !== null) {
    const attrs = mm[1];
    const idM = /id\s*=\s*["']([^"']*)["']/.exec(attrs);
    const hrefM = /href\s*=\s*["']([^"']*)["']/.exec(attrs);
    const typeM = /media-type\s*=\s*["']([^"']*)["']/.exec(attrs);
    if (idM !== null && hrefM !== null) {
      items.push(new ManifestItem(idM[1], hrefM[1], typeM !== null ? typeM[1] : ''));
    }
    mm = itemRe.exec(opfXml);
  }
  // spine 的 <itemref idref="...">
  const spineIds: string[] = [];
  const spineRe = /<itemref\s+([^>]*)>/g;
  let sm = spineRe.exec(opfXml);
  while (sm !== null) {
    const idrefM = /idref\s*=\s*["']([^"']*)["']/.exec(sm[1]);
    if (idrefM !== null) {
      spineIds.push(idrefM[1]);
    }
    sm = spineRe.exec(opfXml);
  }
  return new OpfInfo(items, spineIds);
}

/**
 * 解析 EPUB 为富文本章节(章节正文不预读, 只记录文件路径)
 * @param bookPath 沙箱内 epub 文件路径
 * @param unzipDir 解压输出目录(已解压则跳过)
 * @param title 书名
 */
export async function parseEpub(bookPath: string, unzipDir: string, title: string): Promise<ReaderChapter> {
  // 1. 解压(已解压则跳过, 避免重复解压卡顿)
  if (!fs.accessSync(unzipDir + '/META-INF/container.xml')) {
    if (!fs.accessSync(unzipDir)) {
      fs.mkdirSync(unzipDir);
    }
    await zlib.decompressFile(bookPath, unzipDir);
  }

  // 2. 找 OPF
  const opfRel = findOpfPath(unzipDir);
  if (opfRel.length === 0) {
    return fallbackChapter(unzipDir, title);
  }
  const opfPath = unzipDir + '/' + opfRel;
  const opfDir = opfPath.substring(0, opfPath.lastIndexOf('/'));
  const opfXml = readText(opfPath);
  if (opfXml.length === 0) {
    return fallbackChapter(unzipDir, title);
  }

  // 3. manifest + spine -> 章节文件路径列表
  const parsed = parseOpf(opfXml);
  const filePaths: string[] = [];
  for (let i = 0; i < parsed.spineIds.length; i++) {
    const id = parsed.spineIds[i];
    let href = '';
    for (let j = 0; j < parsed.items.length; j++) {
      if (parsed.items[j].id === id) {
        href = parsed.items[j].href;
        break;
      }
    }
    if (href.length === 0) {
      continue;
    }
    // 解码 href 中的 URL 编码
    let dec = '';
    try {
      dec = decodeURIComponent(href);
    } catch (e) {
      dec = href;
    }
    const htmlPath = opfDir + '/' + dec;
    if (fs.accessSync(htmlPath)) {
      filePaths.push(htmlPath);
    }
  }

  // 4. 构造章节
  if (filePaths.length === 0) {
    return fallbackChapter(unzipDir, title);
  }
  return makeRichChapterLocal(title, filePaths);
}

/** 容错: 找不到章节时扫描解压目录下所有 html 单章 */
function fallbackChapter(unzipDir: string, title: string): ReaderChapter {
  const filePaths: string[] = [];
  collectHtmlPaths(unzipDir, filePaths, 0);
  if (filePaths.length === 0) {
    return makeRichChapterLocal(title, []);
  }
  return makeRichChapterLocal(title, filePaths);
}

function collectHtmlPaths(dir: string, out: string[], depth: number): void {
  if (depth > 3) {
    return;
  }
  let names: string[] = [];
  try {
    names = fs.listFileSync(dir);
  } catch (e) {
    return;
  }
  for (let i = 0; i < names.length; i++) {
    const p = dir + '/' + names[i];
    const lower = names[i].toLowerCase();
    if (lower.endsWith('.html') || lower.endsWith('.htm') || lower.endsWith('.xhtml')) {
      if (fs.accessSync(p)) {
        out.push(p);
      }
    } else {
      // 可能是目录
      try {
        if (fs.statSync(p).isDirectory()) {
          collectHtmlPaths(p, out, depth + 1);
        }
      } catch (e) {
        // 忽略
      }
    }
  }
}

/** 组装 RICH 章节(仅文件路径, 正文由 Web 按需加载) */
function makeRichChapterLocal(title: string, filePaths: string[]): ReaderChapter {
  const pages: ReaderPageItem[] = [];
  if (filePaths.length === 0) {
    pages.push(new ReaderPageItem(ReaderPageType.RICH, 0, '', '',
      '<html><body><p>（EPUB 解析失败或无内容）</p></body></html>', '', ''));
    return new ReaderChapter(1, title, pages);
  }
  for (let i = 0; i < filePaths.length; i++) {
    pages.push(new ReaderPageItem(ReaderPageType.RICH, i, '', '', '', '', filePaths[i]));
  }
  return new ReaderChapter(1, title, pages);
}

/**
 * 提取 EPUB 封面图沙箱路径
 * 优先 metadata 中 name=cover 的 meta -> manifest 对应 id 的 href;
 * 兜底 manifest 中第一个 image 类型 item
 * @returns 封面图片绝对路径; 无则 ''
 */
export function extractEpubCover(unzipDir: string): string {
  const opfRel = findOpfPath(unzipDir);
  if (opfRel.length === 0) {
    return '';
  }
  const opfPath = unzipDir + '/' + opfRel;
  const opfDir = opfPath.substring(0, opfPath.lastIndexOf('/'));
  const opfXml = readText(opfPath);
  if (opfXml.length === 0) {
    return '';
  }
  const parsed = parseOpf(opfXml);

  // 1. metadata 里找 cover id
  let coverId = '';
  const metaRe = /<meta\s+([^>]*)>/g;
  let metaM = metaRe.exec(opfXml);
  while (metaM !== null) {
    const attrs = metaM[1];
    const nameM = /name\s*=\s*["']cover["']/.exec(attrs);
    const contentM = /content\s*=\s*["']([^"']*)["']/.exec(attrs);
    if (nameM !== null && contentM !== null) {
      coverId = contentM[1];
      break;
    }
    metaM = metaRe.exec(opfXml);
  }

  // 2. 匹配 href
  if (coverId.length > 0) {
    for (let i = 0; i < parsed.items.length; i++) {
      if (parsed.items[i].id === coverId) {
        return joinHref(opfDir, parsed.items[i].href);
      }
    }
  }
  // 3. 兜底: 第一个 image 类型 item
  for (let i = 0; i < parsed.items.length; i++) {
    if (parsed.items[i].mediaType.indexOf('image/') >= 0) {
      return joinHref(opfDir, parsed.items[i].href);
    }
  }
  return '';
}

/** 拼接 href 到沙箱绝对路径(解码 URL 编码) */
function joinHref(dir: string, href: string): string {
  let dec = '';
  try {
    dec = decodeURIComponent(href);
  } catch (e) {
    dec = href;
  }
  const p = dir + '/' + dec;
  return fs.accessSync(p) ? p : '';
}
