/**
 * VeneraNext 阅读器页面模型
 * 统一承载 文本页 / 图片页 两种内容, 兼容后续 PDF/EPUB/MOBI/WEB源 归一化
 */

/** 页面内容类型 */
export enum ReaderPageType {
  /** 纯文本页 */
  TEXT,
  /** 图片页(如漫画/扫描PDF) */
  IMAGE,
  /** 富文本页(EPUB HTML, 用 Web 组件按原格式渲染) */
  RICH
}

/** 阅读器单页 */
export class ReaderPageItem {
  type: ReaderPageType;
  /** 文本内容(文本页) */
  text: string;
  /** 图片地址或资源(图片页) */
  image: string | Resource;
  /** 页码(从0) */
  index: number;
  /** 富文本 HTML(富文本页, 与 filePath 二选一) */
  html: string;
  /** 富文本相对资源(图片)解析目录(Web baseUrl) */
  baseUrl: string;
  /** 富文本本地文件路径(沙箱内章节 html, 优先于 html 用 loadUrl 直接加载) */
  filePath: string;

  constructor(type: ReaderPageType, index: number, text: string, image: string | Resource,
    html: string = '', baseUrl: string = '', filePath: string = '') {
    this.type = type;
    this.index = index;
    this.text = text;
    this.image = image;
    this.html = html;
    this.baseUrl = baseUrl;
    this.filePath = filePath;
  }
}

/** 阅读器章节(由详情章节展开为页) */
export class ReaderChapter {
  id: number;
  title: string;
  pages: ReaderPageItem[];

  constructor(id: number, title: string, pages: ReaderPageItem[]) {
    this.id = id;
    this.title = title;
    this.pages = pages;
  }
}

/**
 * 生成富文本章节(EPUB: 一章 = 一个 RICH 页, 用 Web 按原格式渲染)
 * @param htmls 每章 HTML
 * @param baseUrls 每章相对资源(图片)目录, 与 htmls 对齐
 */
export function makeRichChapter(id: number, title: string, htmls: string[], baseUrls: string[]): ReaderChapter {
  const pages: ReaderPageItem[] = [];
  for (let i = 0; i < htmls.length; i++) {
    pages.push(new ReaderPageItem(ReaderPageType.RICH, i, '', '',
      htmls[i], i < baseUrls.length ? baseUrls[i] : ''));
  }
  return new ReaderChapter(id, title, pages);
}