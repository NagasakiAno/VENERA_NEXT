/**
 * VeneraNext 书架数据访问
 * demo 测试数据已移除, 书架内容全部来自 LocalBookStore(本地导入 + 持久化恢复)
 */
import { ShelfItem } from './ShelfItem';
import { localBookStore } from './LocalBookStore';

/** 按 id 查条目(委托全局 store) */
export function findShelfItem(id: string): ShelfItem | null {
  return localBookStore.findById(id);
}
