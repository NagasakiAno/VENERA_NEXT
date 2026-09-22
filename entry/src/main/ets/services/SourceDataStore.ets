/**
 * VeneraNext 源运行时数据存储
 * 对应原版 {dataPath}/comic_source/{key}.data (JSON 对象), 供 JS 源脚本与 App UI 共用
 *
 * 结构约定(与原版一致):
 *   {
 *     "settings": { "<settingKey>": <value> },   // 用户在源设置里选/填的值
 *     "account":  ["<user>", "<pwd>"],           // 账号登录后写入
 *     "<自定义 key>": ...                         // 源脚本 saveData 写入的内容
 *   }
 */
import { common } from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { JsSourceFileStore } from '../utils/JsSourceFileStore';

const DOMAIN = 0x0000;
const TAG = 'SourceDataStore';

/** 源数据对象 */
export type SourceDataBox = Record<string, Object | null>;

export class SourceDataStore {
  private static instance: SourceDataStore = new SourceDataStore();
  private store: JsSourceFileStore | null = null;
  /** key -> 已解析的数据对象 */
  private cache: Map<string, SourceDataBox> = new Map();

  static getInstance(): SourceDataStore {
    return SourceDataStore.instance;
  }

  /** 初始化(需 AppContext), 幂等 */
  init(context: common.Context): void {
    if (this.store === null) {
      this.store = new JsSourceFileStore(context);
    }
  }

  /** 取某个源的完整数据对象(带缓存), 无数据时返回空对象 */
  box(key: string): SourceDataBox {
    if (key.length === 0) {
      return {};
    }
    const cached = this.cache.get(key);
    if (cached !== undefined) {
      return cached;
    }
    const raw = this.store !== null ? this.store.readData(key) : '';
    if (raw.length === 0) {
      const empty: SourceDataBox = {};
      this.cache.set(key, empty);
      return empty;
    }
    let parsed: SourceDataBox = {};
    try {
      parsed = JSON.parse(raw) as SourceDataBox;
    } catch (e) {
      hilog.warn(DOMAIN, TAG, '源 %{public}s 的 data 解析失败, 已重置', key);
      parsed = {};
    }
    this.cache.set(key, parsed);
    return parsed;
  }

  /** 读单个字段 */
  get(key: string, dataKey: string): Object | null {
    const v = this.box(key)[dataKey];
    return v === undefined ? null : v;
  }

  /** 写单个字段并落盘 */
  set(key: string, dataKey: string, value: Object | null): void {
    const box = this.box(key);
    box[dataKey] = value;
    this.persist(key, box);
  }

  /** 删除单个字段并落盘 */
  remove(key: string, dataKey: string): void {
    const box = this.box(key);
    const next: SourceDataBox = {};
    Object.keys(box).forEach((k: string) => {
      if (k !== dataKey) {
        next[k] = box[k];
      }
    });
    this.persist(key, next);
  }

  /** 取 settings 子对象(源设置当前值) */
  settings(key: string): Record<string, Object | null> {
    const v = this.box(key)['settings'];
    if (v === undefined || v === null) {
      return {};
    }
    return v as Record<string, Object | null>;
  }

  /** 写一个源设置项 */
  saveSetting(key: string, settingKey: string, value: Object | null): void {
    const box = this.box(key);
    const current = box['settings'];
    const settings: Record<string, Object | null> =
      (current === undefined || current === null) ? {} : (current as Record<string, Object | null>);
    settings[settingKey] = value;
    box['settings'] = settings;
    this.persist(key, box);
  }

  /** 取一个源设置项(未设置时返回 null) */
  getSetting(key: string, settingKey: string): Object | null {
    const v = this.settings(key)[settingKey];
    return v === undefined ? null : v;
  }

  /** 清空某源数据(删除源时调用) */
  clear(key: string): void {
    this.cache.delete(key);
    if (this.store !== null) {
      this.store.deleteData(key);
    }
  }

  /** 丢弃缓存(源脚本外部改动后强制重读) */
  invalidate(key: string): void {
    this.cache.delete(key);
  }

  /** 按源 key 写入整份数据(更新源时用于保留/重置) */
  replace(key: string, box: SourceDataBox): void {
    this.persist(key, box);
  }

  private persist(key: string, box: SourceDataBox): void {
    this.cache.set(key, box);
    if (this.store !== null) {
      this.store.writeData(key, JSON.stringify(box));
    }
  }
}

/** 全局单例 */
export const sourceDataStore = SourceDataStore.getInstance();
