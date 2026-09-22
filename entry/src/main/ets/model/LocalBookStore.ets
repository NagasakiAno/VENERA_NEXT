/**
 * VeneraNext 本地书架全局可变数据源(单例)
 * 承载运行时新增/恢复的导入书, 并通过订阅通知书架页响应式刷新
 */
import { ShelfItem } from './ShelfItem';

class LocalBookStore {
  private items: ShelfItem[] = [];
  private listeners: Array<() => void> = [];

  constructor() {
    this.items = [];
  }

  /** 全部条目(导入的书) */
  all(): ShelfItem[] {
    return this.items;
  }

  /** 新增导入的书(幂等: 同 id 跳过) */
  addItem(it: ShelfItem): void {
    for (let i = 0; i < this.items.length; i++) {
      if (this.items[i].id === it.id) {
        return;
      }
    }
    this.items.push(it);
    this.notify();
  }

  /** 替换某条目(如惰性解析后回填 bookData) */
  updateItem(it: ShelfItem): void {
    for (let i = 0; i < this.items.length; i++) {
      if (this.items[i].id === it.id) {
        this.items[i] = it;
        break;
      }
    }
    this.notify();
  }

  /** 按 id 移除条目 */
  removeItem(id: string): void {
    const out: ShelfItem[] = [];
    for (let i = 0; i < this.items.length; i++) {
      if (this.items[i].id !== id) {
        out.push(this.items[i]);
      }
    }
    this.items = out;
    this.notify();
  }

  /** 按 id 查条目 */
  findById(id: string): ShelfItem | null {
    for (let i = 0; i < this.items.length; i++) {
      if (this.items[i].id === id) {
        return this.items[i];
      }
    }
    return null;
  }

  /** 订阅数据变化 */
  subscribe(fn: () => void): void {
    this.listeners.push(fn);
  }

  private notify(): void {
    for (let i = 0; i < this.listeners.length; i++) {
      this.listeners[i]();
    }
  }
}

/** 全局单例 */
export const localBookStore: LocalBookStore = new LocalBookStore();
