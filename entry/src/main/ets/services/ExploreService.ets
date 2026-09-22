/**
 * 发现页服务
 *
 * 职责:
 *   1. 汇总各源提供的 explore 页(按 appSettings.explore_pages 的顺序与显隐过滤)
 *   2. 调用源脚本的 explore[i].load* 并把返回的松散 JSON 解析成强类型模型
 *
 * 对应原版 explore_page.dart + parser.dart 的 explore 部分。
 * 返回结构自适应判定, 不依赖源声明的 type 字符串:
 *   - 数组         -> 多 Part  (`[{title, comics, viewMore}]`)
 *   - 有 comics 字段 -> 平铺分页 (`{comics, maxPage}` / `{comics, next}`)
 *   - 有 data 字段   -> 混合    (`{data: (Comic[] | {title, comics})[], maxPage}`)
 *   - 其它对象       -> 单页多 Part (`{ partTitle: Comic[] }`)
 */
import { hilog } from '@kit.PerformanceAnalysisKit';
import { comicSourceManager } from '../model/ComicSource';
import { ComicSourceMeta, ExplorePageInfo } from '../model/sources/ComicSourceMeta';
import { appSettings } from '../model/AppSettings';
import { jsRuntime } from '../runtime/JsRuntime';

const DOMAIN = 0x0000;
const TAG = 'ExploreService';
const KEY_EXPLORE_PAGES = 'explore_pages';

/** 列表项漫画 */
export class ExploreComic {
  id: string = '';
  title: string = '';
  subtitle: string = '';
  cover: string = '';
  tags: string[] = [];
  sourceKey: string = '';
  sourceName: string = '';
}

/** 一个内容分块 */
export class ExplorePart {
  title: string = '';
  comics: ExploreComic[] = [];
}

/** 一次加载的结果 */
export class ExploreBatch {
  /** 平铺列表(分页列表型) */
  comics: ExploreComic[] = [];
  /** 分块列表(多 Part / 混合型) */
  parts: ExplorePart[] = [];
  /** true 表示 comics 是平铺列表 */
  isList: boolean = false;
  maxPage: number = 1;
  /** 游标式分页的下一页游标 */
  next: string = '';

  /** 是否有内容 */
  isEmpty(): boolean {
    return this.comics.length === 0 && this.parts.length === 0;
  }
}

// ---------------------------------------------------------------- JSON 取值

export function asStr(v: Object | undefined): string {
  if (v === undefined || v === null) {
    return '';
  }
  if (typeof v === 'string') {
    return v as string;
  }
  if (typeof v === 'number' || typeof v === 'boolean') {
    return `${v}`;
  }
  return '';
}

export function asNum(v: Object | undefined, fallback: number): number {
  if (v === undefined || v === null) {
    return fallback;
  }
  if (typeof v === 'number') {
    return v as number;
  }
  const parsed = parseInt(`${v}`, 10);
  return isNaN(parsed) ? fallback : parsed;
}

export function asArray(v: Object | undefined): Object[] {
  if (v === undefined || v === null) {
    return [];
  }
  const arr = v as Object[];
  return arr.length === undefined ? [] : arr;
}

export function asStrArray(v: Object | undefined): string[] {
  const out: string[] = [];
  const arr = asArray(v);
  for (let i = 0; i < arr.length; i++) {
    const s = asStr(arr[i]);
    if (s.length > 0) {
      out.push(s);
    }
  }
  return out;
}

/**
 * 把源返回的 Comic 数组解析成模型。
 * Explore / 分类结果 / 搜索 共用同一套字段映射。
 */
export function parseComicList(raw: Object | undefined, sourceKey: string,
                               sourceName: string): ExploreComic[] {
  const out: ExploreComic[] = [];
  const arr = asArray(raw);
  for (let i = 0; i < arr.length; i++) {
    const item = arr[i];
    if (item === undefined || item === null) {
      continue;
    }
    const rec = item as Record<string, Object>;
    const c = new ExploreComic();
    c.id = asStr(rec['id']);
    c.title = asStr(rec['title']);
    const subtitle = asStr(rec['subtitle']);
    c.subtitle = subtitle.length > 0 ? subtitle : asStr(rec['subTitle']);
    c.cover = asStr(rec['cover']);
    c.tags = asStrArray(rec['tags']);
    c.sourceKey = sourceKey;
    c.sourceName = sourceName;
    out.push(c);
  }
  return out;
}

export class ExploreService {
  private static instance: ExploreService = new ExploreService();
  /** 已解析过 explore 元信息的源 key(避免空 explore 反复重试) */
  private parsedKeys: Set<string> = new Set<string>();

  static getInstance(): ExploreService {
    return ExploreService.instance;
  }

  /** 全部可用发现页(按 explore_pages 配置顺序过滤) */
  pages(): ExplorePageInfo[] {
    const all: ExplorePageInfo[] = [];
    const metas = comicSourceManager.allJsSources();
    for (let i = 0; i < metas.length; i++) {
      const list = metas[i].explorePages;
      for (let j = 0; j < list.length; j++) {
        all.push(list[j]);
      }
    }
    const configured = this.configuredTitles();
    if (configured.length === 0) {
      return all;
    }
    // 按配置顺序取每个 title 的第一个匹配(与原版 explore_pages 语义一致)
    const out: ExplorePageInfo[] = [];
    const used: Set<string> = new Set<string>();
    for (let i = 0; i < configured.length; i++) {
      const title = configured[i];
      if (used.has(title)) {
        continue;
      }
      for (let j = 0; j < all.length; j++) {
        if (all[j].title === title) {
          out.push(all[j]);
          used.add(title);
          break;
        }
      }
    }
    return out;
  }

  /** 解析尚未解析过的源的 explore 元信息 */
  async refresh(): Promise<void> {
    const metas: ComicSourceMeta[] = comicSourceManager.allJsSources();
    for (let i = 0; i < metas.length; i++) {
      const meta = metas[i];
      if (this.parsedKeys.has(meta.key)) {
        continue;
      }
      this.parsedKeys.add(meta.key);
      try {
        await jsRuntime.enrichExplore(meta);
      } catch (e) {
        hilog.warn(DOMAIN, TAG, '解析源 %{public}s 的发现页失败: %{public}s', meta.key, `${e}`);
      }
    }
  }

  /** 源被删除/更新后失效 */
  invalidate(key: string): void {
    this.parsedKeys.delete(key);
  }

  /** 加载一页 */
  async load(page: ExplorePageInfo, pageNo: number): Promise<ExploreBatch> {
    const json = await jsRuntime.callExploreLoad(page, pageNo);
    return this.parse(json, page);
  }

  /** 游标式加载下一页 */
  async loadNext(page: ExplorePageInfo, next: string): Promise<ExploreBatch> {
    const json = await jsRuntime.callExploreLoadNext(page, next);
    return this.parse(json, page);
  }

  // ---------------------------------------------------------------- 解析

  private parse(json: string, page: ExplorePageInfo): ExploreBatch {
    const batch = new ExploreBatch();
    let parsed: Object;
    try {
      parsed = JSON.parse(json) as Object;
    } catch (e) {
      hilog.warn(DOMAIN, TAG, '发现页返回内容无法解析: %{public}s', `${e}`);
      return batch;
    }
    if (parsed === null || parsed === undefined) {
      return batch;
    }

    // 数组 -> 多 Part
    const arr = asArray(parsed);
    if (arr.length > 0) {
      for (let i = 0; i < arr.length; i++) {
        const part = this.toPart(arr[i], page);
        if (part.comics.length > 0) {
          batch.parts.push(part);
        }
      }
      return batch;
    }

    const obj = parsed as Record<string, Object>;

    // 平铺分页
    const comicsField = obj['comics'];
    if (comicsField !== undefined && comicsField !== null) {
      batch.isList = true;
      batch.comics = this.toComics(comicsField, page);
      batch.maxPage = asNum(obj['maxPage'], 1);
      batch.next = asStr(obj['next']);
      return batch;
    }

    // 混合
    const dataField = obj['data'];
    if (dataField !== undefined && dataField !== null) {
      const items = asArray(dataField);
      for (let i = 0; i < items.length; i++) {
        const item = items[i];
        if (item === undefined || item === null) {
          continue;
        }
        const inner = asArray(item);
        if (inner.length > 0) {
          // 平铺的一组漫画
          const part = new ExplorePart();
          part.comics = this.toComics(item, page);
          batch.parts.push(part);
        } else {
          const part = this.toPart(item, page);
          if (part.comics.length > 0) {
            batch.parts.push(part);
          }
        }
      }
      batch.maxPage = asNum(obj['maxPage'], 1);
      return batch;
    }

    // 单页多 Part: { partTitle: Comic[] }
    Object.keys(obj).forEach((k: string) => {
      const comics = this.toComics(obj[k], page);
      if (comics.length > 0) {
        const part = new ExplorePart();
        part.title = k;
        part.comics = comics;
        batch.parts.push(part);
      }
    });
    return batch;
  }

  private toPart(raw: Object | undefined, page: ExplorePageInfo): ExplorePart {
    const part = new ExplorePart();
    if (raw === undefined || raw === null) {
      return part;
    }
    const rec = raw as Record<string, Object>;
    part.title = asStr(rec['title']);
    part.comics = this.toComics(rec['comics'], page);
    return part;
  }

  private toComics(raw: Object | undefined, page: ExplorePageInfo): ExploreComic[] {
    return parseComicList(raw, page.sourceKey, page.sourceName);
  }

  private configuredTitles(): string[] {
    const raw = appSettings.get<string>(KEY_EXPLORE_PAGES, '[]');
    try {
      return JSON.parse(raw) as string[];
    } catch (e) {
      return [];
    }
  }
}

/** 全局单例 */
export const exploreService = ExploreService.getInstance();
