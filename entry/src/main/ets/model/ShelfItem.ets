/**
 * VeneraNext 书架条目统一模型
 * 同时承载 本地导入 与 WEB源(demo) 两种来源, 覆盖书架/详情页所需字段
 */
import { ReaderChapter } from './ReaderModel';

/** 来源类型 */
export enum ShelfSourceType {
  /** 本地导入 */
  LOCAL,
  /** WEB 源 */
  WEB
}

/** 章节 */
export class ShelfChapter {
  name: string;
  /** 页数(供阅读定位) */
  pages: number;

  constructor(name: string, pages: number) {
    this.name = name;
    this.pages = pages;
  }
}

/** 书架条目(列表/详情共用) */
export class ShelfItem {
  id: string;
  title: string;
  cover: Resource | string;   // 封面图(本地模板/网络URL)
  author: string;
  description: string;
  tags: string[];
  sourceType: ShelfSourceType;
  chapters: ShelfChapter[];

  // 是否收藏
  isFavorite: boolean;
  // 上次阅读到第几页
  lastReadPage: number;
  lastReadChapter: string;
  // 最近阅读时间戳
  lastReadTime: number;

  // === WEB 源专属字段(demo) ===
  viewCount: number;
  updateTime: string;
  relatedIds: string[];   // 相关推荐

  // === 本地导入书专属字段 ===
  fileFormat: string;         // 'txt' / 'epub'(demo 为空)
  bookData: ReaderChapter[] | null;  // 导入时解析的章节缓存(阅读器用)
  initLoaded: boolean;        // 是否已从沙箱路径惰性解析(persist 恢复时 false)
  sandboxPath: string;        // 沙箱内的原文件路径(持久化恢复后按此重解析)

  constructor(id: string, title: string, cover: Resource | string, author: string,
    description: string, tags: string[], sourceType: ShelfSourceType,
    chapters: ShelfChapter[], isFavorite: boolean = false,
    lastReadPage: number = 0, lastReadChapter: string = '',
    viewCount: number = 0, updateTime: string = '', relatedIds: string[] = [],
    fileFormat: string = '', bookData: ReaderChapter[] | null = null,
    initLoaded: boolean = false, sandboxPath: string = '') {
    this.id = id;
    this.title = title;
    this.cover = cover;
    this.author = author;
    this.description = description;
    this.tags = tags;
    this.sourceType = sourceType;
    this.chapters = chapters;
    this.isFavorite = isFavorite;
    this.lastReadPage = lastReadPage;
    this.lastReadChapter = lastReadChapter;
    this.lastReadTime = 0;
    this.viewCount = viewCount;
    this.updateTime = updateTime;
    this.relatedIds = relatedIds;
    this.fileFormat = fileFormat;
    this.bookData = bookData;
    this.initLoaded = initLoaded;
    this.sandboxPath = sandboxPath;
  }
}