/**
 * VeneraNext 本地收藏多文件夹系统
 * - 支持多文件夹管理（创建/删除/重命名/排序）
 * - 每个文件夹内收藏项 CRUD
 * - 跨文件夹搜索、移动、复制
 * - JSON 文件持久化（filesDir/favorites.json）
 * - 与 ShelfItem.isFavorite 体系兼容（默认文件夹 "收藏"）
 */
import { fileIo as fs } from '@kit.CoreFileKit';
import { common } from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { ShelfItem, ShelfSourceType } from './ShelfItem';

const DOMAIN = 0x0000;
const TAG = 'LocalFavoritesStore';

/** 收藏项（文件夹内的条目） */
export class FavoriteItem {
  id: string = '';
  title: string = '';
  author: string = '';
  cover: string = '';         // 封面 URL 或 Resource 引用名
  tags: string[] = [];
  /** 添加时间戳 */
  time: number = 0;
  /** 在文件夹内的排序值 */
  displayOrder: number = 0;
  /** 来源类型（本地/WEB） */
  sourceType: ShelfSourceType = ShelfSourceType.WEB;
  /** 源 key（WEB 收藏时记录来源） */
  sourceKey: string = '';
  /** 源内 comicId */
  sourceComicId: string = '';

  constructor(id: string, title: string, author: string, cover: string,
    tags: string[], time: number, displayOrder: number,
    sourceType: ShelfSourceType, sourceKey: string, sourceComicId: string) {
    this.id = id;
    this.title = title;
    this.author = author;
    this.cover = cover;
    this.tags = tags;
    this.time = time;
    this.displayOrder = displayOrder;
    this.sourceType = sourceType;
    this.sourceKey = sourceKey;
    this.sourceComicId = sourceComicId;
  }
}

/** 收藏文件夹 */
export class FavoriteFolder {
  name: string = '';
  /** 排序值（越小越靠前） */
  order: number = 0;
  /** 文件夹内的收藏项 */
  items: FavoriteItem[] = [];
  /** 是否关联网络源（可选） */
  syncSourceKey: string = '';
  syncSourceFolder: string = '';

  constructor(name: string, order: number) {
    this.name = name;
    this.order = order;
    this.items = [];
    this.syncSourceKey = '';
    this.syncSourceFolder = '';
  }
}

/** 持久化 JSON 结构 */
interface FavoritesPersistData {
  folders: FavoriteFolderPersist[];
}

interface FavoriteFolderPersist {
  name: string;
  order: number;
  items: FavoriteItemPersist[];
  syncSourceKey?: string;
  syncSourceFolder?: string;
}

interface FavoriteItemPersist {
  id: string;
  title: string;
  author: string;
  cover: string;
  tags: string[];
  time: number;
  displayOrder: number;
  sourceType: number;
  sourceKey: string;
  sourceComicId: string;
}

/** 默认文件夹名 */
const DEFAULT_FOLDER = '收藏';

export class LocalFavoritesStore {
  private folders: FavoriteFolder[] = [];
  private listeners: Array<() => void> = [];
  private context: common.Context | null = null;
  private loaded: boolean = false;

  /** 初始化（传入 Context 以访问文件系统） */
  init(context: common.Context): void {
    this.context = context;
    this.load();
  }

  /** 是否已加载 */
  isLoaded(): boolean {
    return this.loaded;
  }

  /** 获取所有文件夹（按 order 排序） */
  getFolders(): FavoriteFolder[] {
    const sorted = this.folders.slice();
    sorted.sort((a: FavoriteFolder, b: FavoriteFolder) => a.order - b.order);
    return sorted;
  }

  /** 获取文件夹名列表 */
  getFolderNames(): string[] {
    const sorted = this.getFolders();
    const names: string[] = [];
    for (let i = 0; i < sorted.length; i++) {
      names.push(sorted[i].name);
    }
    return names;
  }

  /** 获取指定文件夹 */
  getFolder(name: string): FavoriteFolder | null {
    for (let i = 0; i < this.folders.length; i++) {
      if (this.folders[i].name === name) {
        return this.folders[i];
      }
    }
    return null;
  }

  /** 创建文件夹 */
  createFolder(name: string): boolean {
    // 检查重名
    for (let i = 0; i < this.folders.length; i++) {
      if (this.folders[i].name === name) {
        return false;
      }
    }
    const order = this.folders.length;
    this.folders.push(new FavoriteFolder(name, order));
    this.save();
    this.notify();
    hilog.info(DOMAIN, TAG, '创建文件夹: %{public}s', name);
    return true;
  }

  /** 删除文件夹（收藏项一并删除） */
  deleteFolder(name: string): void {
    if (name === DEFAULT_FOLDER) {
      hilog.warn(DOMAIN, TAG, '不允许删除默认文件夹');
      return;
    }
    const out: FavoriteFolder[] = [];
    for (let i = 0; i < this.folders.length; i++) {
      if (this.folders[i].name !== name) {
        out.push(this.folders[i]);
      }
    }
    this.folders = out;
    this.save();
    this.notify();
    hilog.info(DOMAIN, TAG, '删除文件夹: %{public}s', name);
  }

  /** 重命名文件夹 */
  renameFolder(oldName: string, newName: string): boolean {
    if (oldName === DEFAULT_FOLDER) {
      hilog.warn(DOMAIN, TAG, '不允许重命名默认文件夹');
      return false;
    }
    // 检查新名是否冲突
    for (let i = 0; i < this.folders.length; i++) {
      if (this.folders[i].name === newName) {
        return false;
      }
    }
    for (let i = 0; i < this.folders.length; i++) {
      if (this.folders[i].name === oldName) {
        this.folders[i].name = newName;
        break;
      }
    }
    this.save();
    this.notify();
    return true;
  }

  /** 添加收藏到指定文件夹 */
  addComic(folderName: string, item: FavoriteItem): boolean {
    const folder = this.getFolder(folderName);
    if (folder === null) {
      hilog.warn(DOMAIN, TAG, '文件夹不存在: %{public}s', folderName);
      return false;
    }
    // 检查是否已存在（同 id）
    for (let i = 0; i < folder.items.length; i++) {
      if (folder.items[i].id === item.id) {
        return false;
      }
    }
    item.displayOrder = folder.items.length;
    folder.items.push(item);
    this.save();
    this.notify();
    hilog.info(DOMAIN, TAG, '添加收藏: %{public}s -> %{public}s', item.title, folderName);
    return true;
  }

  /** 从指定文件夹移除收藏 */
  removeComic(folderName: string, id: string): void {
    const folder = this.getFolder(folderName);
    if (folder === null) {
      return;
    }
    const out: FavoriteItem[] = [];
    for (let i = 0; i < folder.items.length; i++) {
      if (folder.items[i].id !== id) {
        out.push(folder.items[i]);
      }
    }
    folder.items = out;
    this.save();
    this.notify();
  }

  /** 从所有文件夹移除某个收藏 */
  removeFromAllFolders(id: string): void {
    for (let i = 0; i < this.folders.length; i++) {
      const out: FavoriteItem[] = [];
      for (let j = 0; j < this.folders[i].items.length; j++) {
        if (this.folders[i].items[j].id !== id) {
          out.push(this.folders[i].items[j]);
        }
      }
      this.folders[i].items = out;
    }
    this.save();
    this.notify();
  }

  /** 移动收藏到另一个文件夹 */
  moveComic(fromFolder: string, toFolder: string, id: string): boolean {
    const src = this.getFolder(fromFolder);
    const dst = this.getFolder(toFolder);
    if (src === null || dst === null) {
      return false;
    }
    let moved: FavoriteItem | null = null;
    const out: FavoriteItem[] = [];
    for (let i = 0; i < src.items.length; i++) {
      if (src.items[i].id === id) {
        moved = src.items[i];
      } else {
        out.push(src.items[i]);
      }
    }
    src.items = out;
    if (moved !== null) {
      moved.displayOrder = dst.items.length;
      dst.items.push(moved);
    }
    this.save();
    this.notify();
    return true;
  }

  /** 查找某漫画在哪些文件夹中 */
  findInFolders(id: string): string[] {
    const result: string[] = [];
    for (let i = 0; i < this.folders.length; i++) {
      for (let j = 0; j < this.folders[i].items.length; j++) {
        if (this.folders[i].items[j].id === id) {
          result.push(this.folders[i].name);
          break;
        }
      }
    }
    return result;
  }

  /** 判断是否已被收藏（任意文件夹） */
  isFavorited(id: string): boolean {
    for (let i = 0; i < this.folders.length; i++) {
      for (let j = 0; j < this.folders[i].items.length; j++) {
        if (this.folders[i].items[j].id === id) {
          return true;
        }
      }
    }
    return false;
  }

  /** 获取指定文件夹的收藏列表 */
  getFolderComics(folderName: string): FavoriteItem[] {
    const folder = this.getFolder(folderName);
    if (folder === null) {
      return [];
    }
    return folder.items.slice();
  }

  /** 获取所有收藏（跨文件夹，去重） */
  getAllComics(): FavoriteItem[] {
    const seen: Record<string, boolean> = {};
    const out: FavoriteItem[] = [];
    for (let i = 0; i < this.folders.length; i++) {
      for (let j = 0; j < this.folders[i].items.length; j++) {
        const item = this.folders[i].items[j];
        if (!seen[item.id]) {
          seen[item.id] = true;
          out.push(item);
        }
      }
    }
    return out;
  }

  /** 跨文件夹搜索 */
  search(keyword: string): FavoriteItem[] {
    const lower = keyword.toLowerCase();
    const out: FavoriteItem[] = [];
    const seen: Record<string, boolean> = {};
    for (let i = 0; i < this.folders.length; i++) {
      for (let j = 0; j < this.folders[i].items.length; j++) {
        const item = this.folders[i].items[j];
        if (!seen[item.id]) {
          seen[item.id] = true;
          if (item.title.toLowerCase().indexOf(lower) >= 0 ||
            item.author.toLowerCase().indexOf(lower) >= 0) {
            out.push(item);
          }
        }
      }
    }
    return out;
  }

  /** 文件夹内搜索 */
  searchInFolder(folderName: string, keyword: string): FavoriteItem[] {
    const folder = this.getFolder(folderName);
    if (folder === null) {
      return [];
    }
    const lower = keyword.toLowerCase();
    const out: FavoriteItem[] = [];
    for (let i = 0; i < folder.items.length; i++) {
      if (folder.items[i].title.toLowerCase().indexOf(lower) >= 0 ||
        folder.items[i].author.toLowerCase().indexOf(lower) >= 0) {
        out.push(folder.items[i]);
      }
    }
    return out;
  }

  /** 获取收藏总数 */
  totalCount(): number {
    let count = 0;
    for (let i = 0; i < this.folders.length; i++) {
      count += this.folders[i].items.length;
    }
    return count;
  }

  /** 文件夹排序（重排 order） */
  reorderFolders(newOrder: string[]): void {
    for (let i = 0; i < newOrder.length; i++) {
      const folder = this.getFolder(newOrder[i]);
      if (folder !== null) {
        folder.order = i;
      }
    }
    this.save();
    this.notify();
  }

  /** 订阅数据变化 */
  subscribe(fn: () => void): void {
    this.listeners.push(fn);
  }

  /** 从 ShelfItem 创建 FavoriteItem */
  static fromShelfItem(item: ShelfItem, sourceKey: string, sourceComicId: string): FavoriteItem {
    const coverStr: string = typeof item.cover === 'string' ? item.cover as string : '';
    return new FavoriteItem(
      item.id,
      item.title,
      item.author,
      coverStr,
      item.tags,
      Date.now(),
      0,
      item.sourceType,
      sourceKey,
      sourceComicId
    );
  }

  // === 持久化 ===

  private filePath(): string {
    if (this.context === null) {
      return '';
    }
    return this.context.filesDir + '/favorites.json';
  }

  private load(): void {
    const path = this.filePath();
    if (path === '') {
      this.ensureDefault();
      this.loaded = true;
      return;
    }
    try {
      if (!fs.accessSync(path)) {
        this.ensureDefault();
        this.loaded = true;
        return;
      }
      const content = fs.readTextSync(path);
      const data: FavoritesPersistData = JSON.parse(content) as FavoritesPersistData;
      this.folders = [];
      for (let i = 0; i < data.folders.length; i++) {
        const fp = data.folders[i];
        const folder = new FavoriteFolder(fp.name, fp.order);
        if (fp.syncSourceKey !== undefined) {
          folder.syncSourceKey = fp.syncSourceKey;
        }
        if (fp.syncSourceFolder !== undefined) {
          folder.syncSourceFolder = fp.syncSourceFolder;
        }
        for (let j = 0; j < fp.items.length; j++) {
          const ip = fp.items[j];
          const item = new FavoriteItem(
            ip.id, ip.title, ip.author, ip.cover, ip.tags,
            ip.time, ip.displayOrder,
            ip.sourceType === 0 ? ShelfSourceType.LOCAL : ShelfSourceType.WEB,
            ip.sourceKey, ip.sourceComicId
          );
          folder.items.push(item);
        }
        this.folders.push(folder);
      }
      this.ensureDefault();
      this.loaded = true;
      hilog.info(DOMAIN, TAG, '加载收藏: %{public}d 个文件夹, %{public}d 条收藏',
        this.folders.length, this.totalCount());
    } catch (e) {
      hilog.error(DOMAIN, TAG, '加载收藏失败: %{public}s', (e as Error).message);
      this.ensureDefault();
      this.loaded = true;
    }
  }

  private save(): void {
    const path = this.filePath();
    if (path === '' || this.context === null) {
      return;
    }
    try {
      const data: FavoritesPersistData = { folders: [] };
      for (let i = 0; i < this.folders.length; i++) {
        const folder = this.folders[i];
        const fp: FavoriteFolderPersist = {
          name: folder.name,
          order: folder.order,
          items: [],
          syncSourceKey: folder.syncSourceKey,
          syncSourceFolder: folder.syncSourceFolder
        };
        for (let j = 0; j < folder.items.length; j++) {
          const item = folder.items[j];
          fp.items.push({
            id: item.id,
            title: item.title,
            author: item.author,
            cover: item.cover,
            tags: item.tags,
            time: item.time,
            displayOrder: item.displayOrder,
            sourceType: item.sourceType === ShelfSourceType.LOCAL ? 0 : 1,
            sourceKey: item.sourceKey,
            sourceComicId: item.sourceComicId
          });
        }
        data.folders.push(fp);
      }
      const json = JSON.stringify(data);
      const file = fs.openSync(path, fs.OpenMode.CREATE | fs.OpenMode.WRITE_ONLY | fs.OpenMode.TRUNC);
      fs.writeSync(file.fd, json);
      fs.closeSync(file);
    } catch (e) {
      hilog.error(DOMAIN, TAG, '保存收藏失败: %{public}s', (e as Error).message);
    }
  }

  /** 确保默认文件夹存在 */
  private ensureDefault(): void {
    for (let i = 0; i < this.folders.length; i++) {
      if (this.folders[i].name === DEFAULT_FOLDER) {
        return;
      }
    }
    this.folders.push(new FavoriteFolder(DEFAULT_FOLDER, 0));
  }

  private notify(): void {
    for (let i = 0; i < this.listeners.length; i++) {
      this.listeners[i]();
    }
  }
}

/** 全局单例 */
export const localFavoritesStore: LocalFavoritesStore = new LocalFavoritesStore();
