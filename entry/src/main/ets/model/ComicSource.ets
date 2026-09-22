/**
 * VeneraNext 漫画源抽象协议与源容器
 * 对应 Flutter 版 foundation/comic_source/comic_source.dart 的契约
 * 策略: 核心采用「JS 源脚本」架构(兼容官方仓库第三方 .js), 由 ComicSourceManager 管理;
 *       旧的原生 ArkTS 源(ComicSourceProtocol)保留为兼容层, 与 JS 源池共存。
 */
import { comic_Res } from '../utils/Res';
import { Comic, ComicDetails } from './ComicModels';
import { ComicSourceMeta } from './sources/ComicSourceMeta';

/** 搜索结果 */
export interface SearchResult {
  comics: Comic[];
  /** 是否为最后一页 (maxPage 语义) */
  maxPage: number;
}

/** 章节页面(图片)加载结果 */
export interface ComicPagesResult {
  images: string[];
}

/**
 * 漫画源需实现的能力子集: 搜索/详情/章节图片 + 元信息
 * 其它高级能力(收藏/评论/账号/归档)在后续迭代按需扩展
 */
export interface ComicSourceProtocol {
  /** 源标识 */
  readonly key: string;
  /** 源名称 */
  readonly name: string;
  /** 版本 */
  readonly version: string;

  /** 首页/精选探索列表(分页), 每源可选提供 */
  loadExplore(page: number): Promise<comic_Res<SearchResult>>;

  /** 按关键词搜索(分页) */
  search(keyword: string, page: number): Promise<comic_Res<SearchResult>>;

  /** 加载漫画详情(包含章节) */
  loadComicInfo(id: string): Promise<comic_Res<ComicDetails>>;

  /** 加载指定章节的所有图片地址 */
  loadComicPages(id: string, ep: string): Promise<comic_Res<ComicPagesResult>>;

  /** 源自身的持久化数据读写(如登录 token/设备信息), key 为该源的命名空间 */
  loadData(key: string): string;
  saveData(key: string, value: string): void;
  deleteData(key: string): void;

  /** 源设置读取 (对应 JS 源的 loadSetting) */
  loadSetting(key: string, defaultValue: string): string;
}

/**
 * 漫画源运行时能力基座(抽象), 封装数据持久化与设置读取,
 * 供真实网络源(CopyManga 等)继承复用, 对应 JS 源基类 ComicSource
 */
export abstract class BaseComicSource implements ComicSourceProtocol {
  abstract readonly key: string;
  abstract readonly name: string;
  abstract readonly version: string;

  /** 数据存储: key 以源 key 为前缀隔离 */
  private dataStore: Map<string, string> = new Map<string, string>();

  loadData(key: string): string {
    return this.dataStore.get(key) ?? '';
  }

  saveData(key: string, value: string): void {
    this.dataStore.set(key, value);
  }

  deleteData(key: string): void {
    this.dataStore.delete(key);
  }

  /** 设置读取, 子类可重写注入来源特定设置 */
  loadSetting(key: string, defaultValue: string): string {
    return defaultValue;
  }

  abstract loadExplore(page: number): Promise<comic_Res<SearchResult>>;
  abstract search(keyword: string, page: number): Promise<comic_Res<SearchResult>>;
  abstract loadComicInfo(id: string): Promise<comic_Res<ComicDetails>>;
  abstract loadComicPages(id: string, ep: string): Promise<comic_Res<ComicPagesResult>>;
}

/** 漫画源类型, 内置示例 */
export class ComicSourceEntry {
  readonly protocol: ComicSourceProtocol;

  constructor(protocol: ComicSourceProtocol) {
    this.protocol = protocol;
  }

  get key(): string {
    return this.protocol.key;
  }

  get name(): string {
    return this.protocol.name;
  }
}

/** 漫画源管理器(单例): JS 源为主, 兼容原生源 */
export class ComicSourceManager {
  private static instance: ComicSourceManager = new ComicSourceManager();
  /** JS 源池(磁盘 .js 解析出的元信息) */
  private jsSources: Map<string, ComicSourceMeta> = new Map<string, ComicSourceMeta>();
  /** 兼容层: 原生 ArkTS 源 */
  private nativeSources: ComicSourceEntry[] = [];

  static getInstance(): ComicSourceManager {
    return ComicSourceManager.instance;
  }

  // ===== 原生源兼容层(原有) =====
  add(source: ComicSourceProtocol): void {
    const idx = this.nativeSources.findIndex((s) => s.key === source.key);
    if (idx >= 0) {
      this.nativeSources.splice(idx, 1);
    }
    this.nativeSources.push(new ComicSourceEntry(source));
  }

  addAll(sourceList: ComicSourceProtocol[]): void {
    sourceList.forEach((s) => this.add(s));
  }

  /** 全部原生源 */
  nativeAll(): ComicSourceEntry[] {
    return this.nativeSources;
  }

  // ===== JS 源池(核心) =====

  /** 启动/运行时注册一个 JS 源元信息 */
  addJsSource(meta: ComicSourceMeta): void {
    this.jsSources.set(meta.key, meta);
  }

  /** 移除一个 JS 源 */
  removeJsSource(key: string): void {
    this.jsSources.delete(key);
  }

  /** 全部 JS 源 */
  allJsSources(): ComicSourceMeta[] {
    return Array.from(this.jsSources.values());
  }

  /** 按 key 查 JS 源 */
  findJsSource(key: string): ComicSourceMeta | null {
    return this.jsSources.get(key) ?? null;
  }

  /** JS 源是否为空 */
  jsEmpty(): boolean {
    return this.jsSources.size === 0;
  }

  // ===== 兼容旧调用(原生源/MangaDex 等使用) =====

  /** 找源(先 JS 池, 再原生池) */
  find(key: string): ComicSourceEntry | null {
    const js = this.jsSources.get(key);
    if (js !== undefined) {
      return new ComicSourceEntry(new JsSourceProtocolProxy(js));
    }
    return this.nativeSources.find((s) => s.key === key) ?? null;
  }

  /** 总源是否为空(JS 池 + 原生池) */
  isEmpty(): boolean {
    return this.jsSources.size === 0 && this.nativeSources.length === 0;
  }
}

/**
 * 兼容代理: 把 ComicSourceMeta 包装成 ComicSourceProtocol, 供旧调用方使用
 * (本轮 JS 源仅提供元信息, 网络能力待 B 阶段引擎接入)
 */
class JsSourceProtocolProxy implements ComicSourceProtocol {
  readonly key: string;
  readonly name: string;
  readonly version: string;

  constructor(meta: ComicSourceMeta) {
    this.key = meta.key;
    this.name = meta.name;
    this.version = meta.version;
  }

  async loadExplore(page: number): Promise<comic_Res<SearchResult>> {
    return comic_Res.success<SearchResult>({ comics: [], maxPage: 1 });
  }

  async search(keyword: string, page: number): Promise<comic_Res<SearchResult>> {
    return comic_Res.success<SearchResult>({ comics: [], maxPage: 1 });
  }

  async loadComicInfo(id: string): Promise<comic_Res<ComicDetails>> {
    return comic_Res.fail<ComicDetails>('JS source runtime not ready yet (B phase)');
  }

  async loadComicPages(id: string, ep: string): Promise<comic_Res<ComicPagesResult>> {
    return comic_Res.fail<ComicPagesResult>('JS source runtime not ready yet (B phase)');
  }

  loadData(key: string): string {
    return '';
  }

  saveData(key: string, value: string): void {
  }

  deleteData(key: string): void {
  }

  loadSetting(key: string, defaultValue: string): string {
    return defaultValue;
  }
}

/** 全局单例 */
export const comicSourceManager = ComicSourceManager.getInstance();