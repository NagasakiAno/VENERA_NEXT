/**
 * 分类页服务
 *
 * 职责:
 *   1. 汇总各源 category 定义(按 appSettings.categories 过滤)
 *   2. 调用 categoryComics.load 并把结果解析成模型
 *
 * 对应原版 categories_page.dart / category_comics_page.dart。
 */
import { hilog } from '@kit.PerformanceAnalysisKit';
import { comicSourceManager } from '../model/ComicSource';
import { ComicSourceMeta, CategoryPart, CategoryItem } from '../model/sources/ComicSourceMeta';
import { appSettings } from '../model/AppSettings';
import { jsRuntime } from '../runtime/JsRuntime';
import { ExploreComic, parseComicList, asNum, asStr } from './ExploreService';

const DOMAIN = 0x0000;
const TAG = 'CategoryService';
const KEY_CATEGORIES = 'categories';

/** 分类结果批次 */
export class CategoryBatch {
  comics: ExploreComic[] = [];
  maxPage: number = 1;
  next: string = '';

  isEmpty(): boolean {
    return this.comics.length === 0;
  }
}

export class CategoryService {
  private static instance: CategoryService = new CategoryService();
  private parsedKeys: Set<string> = new Set<string>();

  static getInstance(): CategoryService {
    return CategoryService.instance;
  }

  /** 提供分类的源(按 categories 配置的顺序过滤; 配置为空时返回全部) */
  sources(): ComicSourceMeta[] {
    const all: ComicSourceMeta[] = [];
    const metas = comicSourceManager.allJsSources();
    for (let i = 0; i < metas.length; i++) {
      if (!metas[i].category.isEmpty()) {
        all.push(metas[i]);
      }
    }
    const configured = this.configuredKeys();
    if (configured.length === 0) {
      return all;
    }
    const out: ComicSourceMeta[] = [];
    for (let i = 0; i < configured.length; i++) {
      for (let j = 0; j < all.length; j++) {
        if (all[j].key === configured[i]) {
          out.push(all[j]);
          break;
        }
      }
    }
    return out;
  }

  /** 解析尚未解析过的源的分类定义 */
  async refresh(): Promise<void> {
    const metas: ComicSourceMeta[] = comicSourceManager.allJsSources();
    for (let i = 0; i < metas.length; i++) {
      const meta = metas[i];
      if (this.parsedKeys.has(meta.key)) {
        continue;
      }
      this.parsedKeys.add(meta.key);
      try {
        await jsRuntime.enrichCategory(meta);
      } catch (e) {
        hilog.warn(DOMAIN, TAG, '解析源 %{public}s 的分类失败: %{public}s', meta.key, `${e}`);
      }
    }
  }

  invalidate(key: string): void {
    this.parsedKeys.delete(key);
  }

  /**
   * 取分组内实际展示的分类项。
   * random 类型按 randomNumber 随机抽取(每次进页面不同)。
   */
  visibleItems(part: CategoryPart): CategoryItem[] {
    const count = part.randomNumber;
    if (part.type !== 'random' || count <= 0 || count >= part.items.length) {
      return part.items;
    }
    const pool = part.items.slice();
    const out: CategoryItem[] = [];
    for (let i = 0; i < count && pool.length > 0; i++) {
      const idx = Math.floor(Math.random() * pool.length);
      out.push(pool[idx]);
      pool.splice(idx, 1);
    }
    return out;
  }

  /** 加载分类结果 */
  async load(sourceKey: string, category: string, param: string,
             options: string[] | null, pageNo: number): Promise<CategoryBatch> {
    const json = await jsRuntime.callCategoryComicsLoad(sourceKey, category, param, options, pageNo);
    const batch = new CategoryBatch();
    let parsed: Object;
    try {
      parsed = JSON.parse(json) as Object;
    } catch (e) {
      hilog.warn(DOMAIN, TAG, '分类结果无法解析: %{public}s', `${e}`);
      return batch;
    }
    if (parsed === null || parsed === undefined) {
      return batch;
    }
    const rec = parsed as Record<string, Object>;
    const meta = comicSourceManager.findJsSource(sourceKey);
    const name = meta === null ? sourceKey : meta.name;
    batch.comics = parseComicList(rec['comics'], sourceKey, name);
    batch.maxPage = asNum(rec['maxPage'], 1);
    batch.next = asStr(rec['next']);
    return batch;
  }

  private configuredKeys(): string[] {
    const raw = appSettings.get<string>(KEY_CATEGORIES, '[]');
    try {
      return JSON.parse(raw) as string[];
    } catch (e) {
      return [];
    }
  }
}

/** 全局单例 */
export const categoryService = CategoryService.getInstance();
