/**
 * 阅读历史 / 进度 (对应原版 History + ReadProgress)
 *
 * 落盘: {files}/comic_source/__read_history.data, 结构:
 *   { "items": [ {sourceKey, comicId, ..., epId, epTitle, page, total, updatedAt}, ... ] }
 * 同一个 (sourceKey, comicId) 只保留最新一条, 按 updatedAt 倒序, 上限 MAX_ITEMS 条。
 */
import { common } from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { JsSourceFileStore } from '../utils/JsSourceFileStore';

const DOMAIN = 0x0000;
const TAG = 'ReadHistory';
/** 存储键(与源数据放同一目录, 用前缀区分) */
const STORE_KEY = '__read_history';
/** 最多保留的历史条数 */
const MAX_ITEMS = 200;
/** 合并写入的延迟, 避免连续翻页时频繁落盘 */
const FLUSH_DELAY_MS = 1200;

/** 一条阅读记录 */
export class ReadHistoryItem {
  sourceKey: string = '';
  comicId: string = '';
  comicTitle: string = '';
  cover: string = '';
  /** 最近阅读的章节 */
  epId: string = '';
  epTitle: string = '';
  /** 已读到第几页(0 基) */
  page: number = 0;
  total: number = 0;
  updatedAt: number = 0;
}

/** 落盘结构 */
interface HistoryBox {
  items?: ReadHistoryItem[];
}

export class ReadHistoryService {
  private static instance: ReadHistoryService = new ReadHistoryService();
  private store: JsSourceFileStore | null = null;
  private items: ReadHistoryItem[] = [];
  private loaded: boolean = false;
  private flushTimer: number = -1;

  static getInstance(): ReadHistoryService {
    return ReadHistoryService.instance;
  }

  /** 初始化(需 AppContext), 幂等 */
  init(context: common.Context): void {
    if (this.store === null) {
      this.store = new JsSourceFileStore(context);
    }
  }

  /** 全部记录, 按最近阅读倒序 */
  list(): ReadHistoryItem[] {
    this.ensureLoaded();
    return this.items;
  }

  /** 查某本漫画的进度(没有返回 null) */
  find(sourceKey: string, comicId: string): ReadHistoryItem | null {
    this.ensureLoaded();
    for (let i = 0; i < this.items.length; i++) {
      const it = this.items[i];
      if (it.sourceKey === sourceKey && it.comicId === comicId) {
        hilog.info(DOMAIN, TAG, '命中进度 %{public}s@%{public}s ep=%{public}s p=%{public}d/%{public}d',
          sourceKey, comicId, it.epId, it.page + 1, it.total);
        return it;
      }
    }
    hilog.info(DOMAIN, TAG, '无进度记录 %{public}s@%{public}s(共 %{public}d 条)',
      sourceKey, comicId, this.items.length);
    return null;
  }

  /** 记录/更新进度 */
  record(item: ReadHistoryItem): void {
    this.ensureLoaded();
    item.updatedAt = Date.now();
    let replaced = false;
    for (let i = 0; i < this.items.length; i++) {
      const it = this.items[i];
      if (it.sourceKey === item.sourceKey && it.comicId === item.comicId) {
        // 保留已有的封面/标题(源可能不提供), 其余用新的
        if (item.comicTitle.length === 0) {
          item.comicTitle = it.comicTitle;
        }
        if (item.cover.length === 0) {
          item.cover = it.cover;
        }
        this.items[i] = item;
        replaced = true;
        break;
      }
    }
    if (!replaced) {
      this.items.push(item);
    }
    this.items.sort((a: ReadHistoryItem, b: ReadHistoryItem) => b.updatedAt - a.updatedAt);
    if (this.items.length > MAX_ITEMS) {
      this.items = this.items.slice(0, MAX_ITEMS);
    }
    this.scheduleFlush();
  }

  /** 删除某本漫画的进度 */
  remove(sourceKey: string, comicId: string): void {
    this.ensureLoaded();
    for (let i = 0; i < this.items.length; i++) {
      const it = this.items[i];
      if (it.sourceKey === sourceKey && it.comicId === comicId) {
        this.items.splice(i, 1);
        break;
      }
    }
    this.scheduleFlush();
  }

  /** 清空全部历史 */
  clear(): void {
    this.ensureLoaded();
    this.items = [];
    this.flush();
  }

  // ---------------------------------------------------------------- 内部

  private ensureLoaded(): void {
    if (this.loaded) {
      return;
    }
    this.loaded = true;
    const raw = this.store !== null ? this.store.readData(STORE_KEY) : '';
    if (raw.length === 0) {
      return;
    }
    try {
      const box = JSON.parse(raw) as HistoryBox;
      const arr = box.items;
      if (arr !== undefined && arr !== null) {
        this.items = arr;
      }
    } catch (e) {
      hilog.warn(DOMAIN, TAG, '历史数据解析失败, 已重置');
      this.items = [];
    }
  }

  private scheduleFlush(): void {
    if (this.flushTimer >= 0) {
      clearTimeout(this.flushTimer);
    }
    this.flushTimer = setTimeout(() => {
      this.flushTimer = -1;
      this.flush();
    }, FLUSH_DELAY_MS);
  }

  private flush(): void {
    if (this.store === null) {
      return;
    }
    const box: HistoryBox = { items: this.items };
    try {
      this.store.writeData(STORE_KEY, JSON.stringify(box));
      if (this.items.length > 0) {
        const top = this.items[0];
        hilog.info(DOMAIN, TAG, '历史已保存 %{public}d 条, 最近: %{public}s@%{public}s ep=%{public}s p=%{public}d',
          this.items.length, top.sourceKey, top.comicId, top.epId, top.page + 1);
      }
    } catch (e) {
      hilog.warn(DOMAIN, TAG, '历史写入失败: %{public}s', `${e}`);
    }
  }
}

/** 全局单例 */
export const readHistoryService = ReadHistoryService.getInstance();
