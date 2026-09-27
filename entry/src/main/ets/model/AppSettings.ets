/**
 * VeneraNext 应用设置数据管理
 * 基于 ArkTS Preferences 持久化 + 内存状态, 用于全局共享
 */
import { preferences } from '@kit.ArkData';
import { common } from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';

const DOMAIN = 0x0000;
const TAG = 'AppSettings';
const STORE_NAME = 'venera_settings';

/** 应用设置键值, 与 Flutter 版保持语义一致 */
export class AppSettings {
  private static instance: AppSettings = new AppSettings();
  private store: preferences.Preferences | null = null;

  /** 当前数据(内存缓存) */
  private data: Map<string, Object> = new Map<string, Object>([
    ['theme_mode', 'system'],      // system | light | dark
    ['language', 'system'],        // system | zh-CN | en-US
    ['readerMode', 'galleryLeftToRight'],
    ['comicDisplayMode', 'detailed'],
    // === JS 源管理 ===
    ['comicSourceListUrl', 'https://cdn.jsdelivr.net/gh/venera-app/venera-configs@main/index.json'],
    ['explore_pages', '[]'],       // Explore 页 title 列表(JSON string[])
    ['categories', '[]'],          // 分类 Tab(key 列表)
    ['favorites', '[]'],           // 网络收藏 Tab
    ['searchSources', '[]'],       // 搜索可选源(key 列表)
    // === 阅读体验 ===
    ['reverseChapterOrder', false]  // 章节倒序显示(详情页可临时切换)
  ]);

  static getInstance(): AppSettings {
    if (AppSettings.instance == null) {
      AppSettings.instance = new AppSettings();
    }
    return AppSettings.instance;
  }

  /** 初始化 Preferences 并读取全部已存设置 */
  async init(context: common.Context): Promise<void> {
    try {
      const options: preferences.Options = { name: STORE_NAME };
      this.store = await preferences.getPreferences(context, options);
      const store = this.store;
      // 读取全部键, 合并到内存
      const all: Object = await store.getAll();
      const raw = all as Map<string, preferences.ValueType>;
      raw.forEach((value: preferences.ValueType, key: string) => {
        this.data.set(key, value as Object);
      });
      hilog.info(DOMAIN, TAG, 'AppSettings initialized, keys: %{public}d', raw.size);
    } catch (e) {
      hilog.error(DOMAIN, TAG, 'init failed: %{public}s', JSON.stringify(e));
    }
  }

  /** 读取设置, 优先内存, 未命中返回 defaultValue */
  public get<T>(key: string, defaultValue: T): T {
    const v = this.data.get(key);
    if (v === undefined || v === null) {
      return defaultValue;
    }
    return v as T;
  }

  /** 写设置: 更新内存并异步持久化 */
  public async put(key: string, value: preferences.ValueType): Promise<void> {
    this.data.set(key, value as Object);
    if (this.store) {
      try {
        await this.store.put(key, value);
        await this.store.flush();
      } catch (e) {
        hilog.error(DOMAIN, TAG, 'put failed for %{public}s: %{public}s',
          key, JSON.stringify(e));
      }
    }
  }
}

/** 全局单例, 供各页面使用 */
export const appSettings = AppSettings.getInstance();