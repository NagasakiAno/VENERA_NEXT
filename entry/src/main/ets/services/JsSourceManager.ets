/**
 * VeneraNext JS 源管理器服务
 * 负责磁盘<->ComicSourceManager 的完整生命周期: 扫描/安装/更新/删除 + 四列表联动
 * (explore_pages/categories/favorites/searchSources 存储于 AppSettings)
 */
import { common } from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { ComicSourceMeta } from '../model/sources/ComicSourceMeta';
import { parse } from '../model/sources/ComicSourceParser';
import { JsSourceFileStore } from '../utils/JsSourceFileStore';
import { comicSourceManager } from '../model/ComicSource';
import { appSettings } from '../model/AppSettings';
import { sourceDataStore } from './SourceDataStore';
import { exploreService } from './ExploreService';
import { categoryService } from './CategoryService';
import { searchService } from './SearchService';
import { jsRuntime } from '../runtime/JsRuntime';

const DOMAIN = 0x0000;
const TAG = 'JsSourceManager';

const KEY_EXPLORE = 'explore_pages';
const KEY_CATEGORIES = 'categories';
const KEY_FAVORITES = 'favorites';
const KEY_SEARCH = 'searchSources';

function readList(key: string): string[] {
  const raw = appSettings.get<string>(key, '[]');
  try {
    return JSON.parse(raw) as string[];
  } catch (e) {
    return [];
  }
}

function writeList(key: string, list: string[]): void {
  appSettings.put(key, JSON.stringify(list));
}

/** 安装结果(带失败原因) */
export class InstallResult {
  meta: ComicSourceMeta | null = null;
  error: string = '';

  get ok(): boolean {
    return this.meta !== null;
  }
}

export class JsSourceManager {
  private static instance: JsSourceManager = new JsSourceManager();
  private store: JsSourceFileStore | null = null;

  static getInstance(): JsSourceManager {
    return JsSourceManager.instance;
  }

  private ensureStore(context: common.Context): JsSourceFileStore {
    if (this.store === null) {
      this.store = new JsSourceFileStore(context);
    }
    return this.store;
  }

  /** 启动扫描 comic_source/*.js 并注册(幂等) */
  scanFromFilesDir(context: common.Context): void {
    const store = this.ensureStore(context);
    const files = store.listJs();
    for (let i = 0; i < files.length; i++) {
      const fileName = files[i];
      const filePath = store.sourceDir() + '/' + fileName;
      const text = store.readJs(fileName);
      if (text.length === 0) {
        continue;
      }
      try {
        const meta = parse(text, filePath, fileName);
        comicSourceManager.addJsSource(meta);
        hilog.info(DOMAIN, TAG, 'scan loaded %{public}s v%{public}s', meta.key, meta.version);
      } catch (e) {
        hilog.warn(DOMAIN, TAG, 'scan skip %{public}s: %{public}s', fileName, (e as Error).message);
      }
    }
  }

  /** 通过脚本文本安装一个源(用于 URL 下载 / 本地文件读入后) */
  async installFromText(context: common.Context, jsText: string, hintFileName: string): Promise<InstallResult> {
    const result = new InstallResult();
    if (jsText.length === 0) {
      result.error = '脚本内容为空';
      return result;
    }
    const store = this.ensureStore(context);
    const tmpPath = store.sourceDir() + '/' + hintFileName;
    try {
      const meta = parse(jsText, tmpPath, hintFileName);
      // 冲突校验
      const conflict = comicSourceManager.findJsSource(meta.key);
      if (conflict !== null) {
        hilog.warn(DOMAIN, TAG, 'install conflict key=%{public}s', meta.key);
        result.error = '源已存在( key=' + meta.key + ' )，请先删除或改用更新';
        return result;
      }
      meta.fileName = meta.key + '.js';
      meta.filePath = store.sourceDir() + '/' + meta.fileName;
      store.writeJs(meta.fileName, jsText);
      comicSourceManager.addJsSource(meta);
      this.addToLists(meta);
      hilog.info(DOMAIN, TAG, 'installed %{public}s v%{public}s', meta.key, meta.version);
      result.meta = meta;
      return result;
    } catch (e) {
      const msg = (e as Error).message ?? String(e);
      hilog.warn(DOMAIN, TAG, 'install failed: %{public}s', msg);
      result.error = msg.length > 0 ? msg : '解析失败';
      return result;
    }
  }

  /** 按新脚本更新某源(先删旧脚本再解析写回; 保留 {key}.data 中的登录态与设置) */
  async update(context: common.Context, key: string, newJsText: string): Promise<ComicSourceMeta | null> {
    const store = this.ensureStore(context);
    const old = comicSourceManager.findJsSource(key);
    // 只删旧脚本文件, 不动 data
    if (old !== null) {
      store.deleteJs(old.fileName);
    }
    try {
      const meta = parse(newJsText, store.sourceDir() + '/' + key + '.js', key + '.js');
      meta.fileName = key + '.js';
      meta.filePath = store.sourceDir() + '/' + meta.fileName;
      store.writeJs(meta.fileName, newJsText);
      comicSourceManager.addJsSource(meta);
      // 让运行时下次调用时重新加载新脚本
      jsRuntime.unloadSource(key);
      exploreService.invalidate(key);
      categoryService.invalidate(key);
      searchService.invalidate(key);
      hilog.info(DOMAIN, TAG, 'updated %{public}s -> v%{public}s', key, meta.version);
      return meta;
    } catch (e) {
      hilog.warn(DOMAIN, TAG, 'update %{public}s failed: %{public}s', key, (e as Error).message);
      return null;
    }
  }

  /** 删除源: 盘文件 + data + 池 + 运行时卸载 + 四列表清理 */
  remove(context: common.Context, key: string): void {
    const store = this.ensureStore(context);
    const meta = comicSourceManager.findJsSource(key);
    if (meta !== null) {
      store.deleteJs(meta.fileName);
    } else {
      store.deleteJs(key + '.js');
    }
    comicSourceManager.removeJsSource(key);
    sourceDataStore.clear(key);
    jsRuntime.unloadSource(key);
    exploreService.invalidate(key);
    categoryService.invalidate(key);
    searchService.invalidate(key);
    this.cleanupLists(key);
    hilog.info(DOMAIN, TAG, 'removed %{public}s', key);
  }

  /** 安装时把源能提供的页追加进四列表 */
  private addToLists(meta: ComicSourceMeta): void {
    if (meta.hasExplore) {
      const l = readList(KEY_EXPLORE);
      const t = meta.name;
      if (l.indexOf(t) < 0) {
        l.push(t);
        writeList(KEY_EXPLORE, l);
      }
    }
    if (meta.hasSearch) {
      const l = readList(KEY_SEARCH);
      if (l.indexOf(meta.key) < 0) {
        l.push(meta.key);
        writeList(KEY_SEARCH, l);
      }
    }
    // categories/favorites 需源提供 category/favorites 能力, 本轮仅占位记录 key
    if (meta.hasExplore) {
      // category 依赖源内部, 本轮用 key 占位
      const l = readList(KEY_CATEGORIES);
      if (l.indexOf(meta.key) < 0 && hasCategory(meta)) {
        l.push(meta.key);
        writeList(KEY_CATEGORIES, l);
      }
    }
  }

  /** 删除时清理四列表中的失效项 */
  private cleanupLists(key: string): void {
    const explore = readList(KEY_EXPLORE).filter(() => true);
    // explore_pages 存 name, 难以按 key 删; 简化: 从 searchSources/categories 清 key
    const search = readList(KEY_SEARCH).filter((k) => k !== key);
    writeList(KEY_SEARCH, search);
    const cats = readList(KEY_CATEGORIES).filter((k) => k !== key);
    writeList(KEY_CATEGORIES, cats);
    const fav = readList(KEY_FAVORITES).filter((k) => k !== key);
    writeList(KEY_FAVORITES, fav);
  }
}

/** 是否提供分类能力(简单子串判断) */
function hasCategory(meta: ComicSourceMeta): boolean {
  // 占位: 元信息不含 category 掩码, 视为否(本轮分类 UI 未实现)
  return false;
}

export const jsSourceManager = JsSourceManager.getInstance();