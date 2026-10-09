/**
 * 图片磁盘缓存管理器
 *
 * 对应原版 Flutter CacheManager (lib/foundation/cache_manager.dart):
 *   - 存储路径: {cacheDir}/image_cache/{0-9}/{sha256hex}
 *   - 缓存键: 与内存缓存一致 sourceKey|epId|url
 *   - 过期: 7天, 命中续期
 *   - 淘汰: 过期清理 + LRU(按expires排序) + 孤儿文件清理
 *   - 限制: 默认 500MB
 *
 * 存储的是原始下载字节(JPEG/PNG等), 不是解码后的 RGBA。
 * 从磁盘恢复时仍需 decode + applyModify, 但省去了最耗时的网络下载。
 */
import { fileIo as fs } from '@kit.CoreFileKit';
import { common } from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { util } from '@kit.ArkTS';
import { sha256Bytes, hexEncode, encodeUtf8 } from './Convert';

const DOMAIN = 0x0000;
const TAG = 'DiskCacheManager';
/** 缓存过期时间(毫秒): 7天 */
const EXPIRE_MS = 7 * 24 * 60 * 60 * 1000;
/** 默认缓存上限(字节): 500MB */
const DEFAULT_LIMIT = 500 * 1024 * 1024;
/** 子目录数量 */
const SUBDIR_COUNT = 10;
/** 索引文件名 */
const INDEX_FILE = 'index.json';

/** 缓存索引条目 */
interface CacheEntry {
  /** 缓存键(原始字符串) */
  key: string;
  /** 文件相对路径(相对根目录, 如 "3/a1b2c3...") */
  file: string;
  /** 过期时间戳(毫秒) */
  expires: number;
  /** 文件大小(字节) */
  size: number;
}

export class DiskCacheManager {
  private static instance: DiskCacheManager = new DiskCacheManager();
  private rootDir: string = '';
  private indexFile: string = '';
  /** 缓存索引: key -> CacheEntry */
  private index: Map<string, CacheEntry> = new Map<string, CacheEntry>();
  /** 当前缓存总大小(字节) */
  private currentSize: number = 0;
  /** 缓存上限(字节) */
  private limitSize: number = DEFAULT_LIMIT;
  /** 是否已初始化 */
  private initialized: boolean = false;

  static getInstance(): DiskCacheManager {
    return DiskCacheManager.instance;
  }

  /** 初始化: 创建目录, 读取索引, 清理过期/孤儿文件 */
  async init(context: common.Context): Promise<void> {
    if (this.initialized) {
      return;
    }
    this.rootDir = context.cacheDir + '/image_cache';
    this.indexFile = this.rootDir + '/' + INDEX_FILE;

    try {
      // 创建根目录
      if (!fs.accessSync(this.rootDir)) {
        fs.mkdirSync(this.rootDir, true);
      }
      // 创建子目录
      for (let i = 0; i < SUBDIR_COUNT; i++) {
        const sub = this.rootDir + '/' + i.toString();
        if (!fs.accessSync(sub)) {
          fs.mkdirSync(sub, true);
        }
      }
      // 读取索引
      await this.loadIndex();
      // 清理过期条目
      await this.cleanExpired();
      // 清理孤儿文件
      await this.cleanOrphans();
      hilog.info(DOMAIN, TAG, '初始化完成, 缓存 %{public}d 条, %{public}d MB',
        this.index.size, Math.round(this.currentSize / 1024 / 1024));
    } catch (e) {
      hilog.error(DOMAIN, TAG, '初始化失败: %{public}s', `${e}`);
    }
    this.initialized = true;
  }

  /**
   * 查找缓存: 命中则续期并返回文件绝对路径, 未命中返回 null。
   * 调用方负责读取文件内容。
   */
  find(key: string): string | null {
    const entry = this.index.get(key);
    if (entry === undefined) {
      return null;
    }
    // 过期检查
    if (Date.now() > entry.expires) {
      this.deleteInternal(key);
      return null;
    }
    // 续期(命中即刷新, 对应原版 findCache 的续期逻辑)
    entry.expires = Date.now() + EXPIRE_MS;
    this.index.set(key, entry);
    // 异步保存索引(不阻塞读取)
    this.saveIndex().catch((e: Error) => {
      hilog.warn(DOMAIN, TAG, '索引保存失败: %{public}s', `${e}`);
    });
    return this.rootDir + '/' + entry.file;
  }

  /**
   * 写入缓存: 将原始字节数据写入磁盘文件, 更新索引。
   * 若键已存在, 先删除旧文件再写新文件。
   */
  async write(key: string, data: Uint8Array): Promise<void> {
    if (!this.initialized || this.rootDir.length === 0) {
      return;
    }
    // 已存在则先删旧
    const old = this.index.get(key);
    if (old !== undefined) {
      this.deleteInternal(key);
    }
    // 计算文件路径
    const hash = this.hashKey(key);
    const subdir = this.hashSubdir(hash);
    const relPath = subdir + '/' + hash;
    const absPath = this.rootDir + '/' + relPath;

    try {
      // 写文件
      const file = fs.openSync(absPath, fs.OpenMode.CREATE | fs.OpenMode.WRITE_ONLY);
      fs.writeSync(file.fd, data.buffer);
      fs.closeSync(file);
      // 更新索引
      const entry: CacheEntry = {
        key: key,
        file: relPath,
        expires: Date.now() + EXPIRE_MS,
        size: data.byteLength
      };
      this.index.set(key, entry);
      this.currentSize += data.byteLength;
      // 检查是否超限, 执行 LRU 淘汰
      if (this.currentSize > this.limitSize) {
        await this.evictLRU();
      }
      // 异步保存索引
      this.saveIndex().catch((e: Error) => {
        hilog.warn(DOMAIN, TAG, '索引保存失败: %{public}s', `${e}`);
      });
    } catch (e) {
      hilog.warn(DOMAIN, TAG, '写入缓存失败: %{public}s', `${e}`);
    }
  }

  /** 删除指定键的缓存 */
  delete(key: string): void {
    this.deleteInternal(key);
    this.saveIndex().catch((e: Error) => {
      hilog.warn(DOMAIN, TAG, '索引保存失败: %{public}s', `${e}`);
    });
  }

  /** 清空全部磁盘缓存 */
  async clear(): Promise<void> {
    try {
      // 删除整个缓存目录并重建
      if (fs.accessSync(this.rootDir)) {
        fs.rmdirSync(this.rootDir);
      }
      fs.mkdirSync(this.rootDir, true);
      for (let i = 0; i < SUBDIR_COUNT; i++) {
        fs.mkdirSync(this.rootDir + '/' + i.toString(), true);
      }
      this.index.clear();
      this.currentSize = 0;
      await this.saveIndex();
      hilog.info(DOMAIN, TAG, '磁盘缓存已清空');
    } catch (e) {
      hilog.error(DOMAIN, TAG, '清空缓存失败: %{public}s', `${e}`);
    }
  }

  /** 获取当前缓存总大小(字节) */
  getTotalSize(): number {
    return this.currentSize;
  }

  /** 获取缓存条目数 */
  getCount(): number {
    return this.index.size;
  }

  /** 查找所有键以 prefix 开头的缓存文件绝对路径 */
  findByPrefix(prefix: string): string[] {
    const result: string[] = [];
    this.index.forEach((entry: CacheEntry, key: string) => {
      if (key.startsWith(prefix)) {
        result.push(this.rootDir + '/' + entry.file);
      }
    });
    return result;
  }

  /** 设置缓存上限(字节) */
  setLimit(bytes: number): void {
    this.limitSize = bytes;
  }

  // ---------------------------------------------------------------- 内部

  /** 计算缓存键的 SHA-256 十六进制哈希(用作文件名) */
  private hashKey(key: string): string {
    const bytes = sha256Bytes(encodeUtf8(key));
    return hexEncode(bytes);
  }

  /** 根据哈希决定子目录编号(0~9) */
  private hashSubdir(hash: string): string {
    // 取哈希前2位作为数字, 模 SUBDIR_COUNT
    const prefix = parseInt(hash.substring(0, 2), 16);
    return (prefix % SUBDIR_COUNT).toString();
  }

  /** 读取索引文件 */
  private async loadIndex(): Promise<void> {
    try {
      if (!fs.accessSync(this.indexFile)) {
        return;
      }
      const file = fs.openSync(this.indexFile, fs.OpenMode.READ_ONLY);
      const stat = fs.statSync(this.indexFile);
      const buf = new ArrayBuffer(stat.size);
      fs.readSync(file.fd, buf);
      fs.closeSync(file);
      const text = new util.TextDecoder('utf-8').decodeToString(new Uint8Array(buf));
      const arr = JSON.parse(text) as Object[];
      if (!Array.isArray(arr)) {
        return;
      }
      for (let i = 0; i < arr.length; i++) {
        const item = arr[i] as Record<string, Object>;
        const entry: CacheEntry = {
          key: item['key'] as string,
          file: item['file'] as string,
          expires: item['expires'] as number,
          size: item['size'] as number
        };
        this.index.set(entry.key, entry);
        this.currentSize += entry.size;
      }
    } catch (e) {
      hilog.warn(DOMAIN, TAG, '读取索引失败: %{public}s', `${e}`);
    }
  }

  /** 保存索引文件(异步) */
  private async saveIndex(): Promise<void> {
    if (this.rootDir.length === 0) {
      return;
    }
    try {
      const arr: CacheEntry[] = [];
      this.index.forEach((entry: CacheEntry) => {
        arr.push(entry);
      });
      const text = JSON.stringify(arr);
      const data = new util.TextEncoder().encodeInto(text);
      const file = fs.openSync(this.indexFile,
        fs.OpenMode.CREATE | fs.OpenMode.WRITE_ONLY | fs.OpenMode.TRUNC);
      fs.writeSync(file.fd, data.buffer);
      fs.closeSync(file);
    } catch (e) {
      hilog.warn(DOMAIN, TAG, '保存索引失败: %{public}s', `${e}`);
    }
  }

  /** 清理过期条目 */
  private async cleanExpired(): Promise<void> {
    const now = Date.now();
    const expiredKeys: string[] = [];
    this.index.forEach((entry: CacheEntry, key: string) => {
      if (now > entry.expires) {
        expiredKeys.push(key);
      }
    });
    for (let i = 0; i < expiredKeys.length; i++) {
      this.deleteInternal(expiredKeys[i]);
    }
    if (expiredKeys.length > 0) {
      hilog.info(DOMAIN, TAG, '清理过期缓存 %{public}d 条', expiredKeys.length);
    }
  }

  /** 清理孤儿文件(磁盘上有但索引中没有的) */
  private async cleanOrphans(): Promise<void> {
    try {
      for (let i = 0; i < SUBDIR_COUNT; i++) {
        const subDir = this.rootDir + '/' + i.toString();
        if (!fs.accessSync(subDir)) {
          continue;
        }
        const iter = fs.listFileSync(subDir);
        for (let j = 0; j < iter.length; j++) {
          const fileName = iter[j];
          const relPath = i.toString() + '/' + fileName;
          // 检查索引中是否有此文件
          let found = false;
          this.index.forEach((entry: CacheEntry) => {
            if (entry.file === relPath) {
              found = true;
            }
          });
          if (!found) {
            // 孤儿文件, 删除
            try {
              fs.unlinkSync(subDir + '/' + fileName);
            } catch (e) {
              // 忽略删除失败
            }
          }
        }
      }
    } catch (e) {
      hilog.warn(DOMAIN, TAG, '清理孤儿文件失败: %{public}s', `${e}`);
    }
  }

  /** LRU 淘汰: 按 expires 升序(最早过期=最久未访问)删除, 直到低于上限 */
  private async evictLRU(): Promise<void> {
    // 收集所有条目并按 expires 升序排序
    const entries: CacheEntry[] = [];
    this.index.forEach((entry: CacheEntry) => {
      entries.push(entry);
    });
    entries.sort((a: CacheEntry, b: CacheEntry) => a.expires - b.expires);

    let evicted = 0;
    for (let i = 0; i < entries.length && this.currentSize > this.limitSize; i++) {
      this.deleteInternal(entries[i].key);
      evicted++;
    }
    if (evicted > 0) {
      hilog.info(DOMAIN, TAG, 'LRU 淘汰 %{public}d 条, 剩余 %{public}d MB',
        evicted, Math.round(this.currentSize / 1024 / 1024));
    }
  }

  /** 内部删除: 删文件 + 删索引 + 减大小(不保存索引) */
  private deleteInternal(key: string): void {
    const entry = this.index.get(key);
    if (entry === undefined) {
      return;
    }
    // 删文件
    try {
      const absPath = this.rootDir + '/' + entry.file;
      if (fs.accessSync(absPath)) {
        fs.unlinkSync(absPath);
      }
    } catch (e) {
      // 文件可能已不存在, 忽略
    }
    // 删索引
    this.index.delete(key);
    this.currentSize -= entry.size;
    if (this.currentSize < 0) {
      this.currentSize = 0;
    }
  }
}

/** 全局单例 */
export const diskCacheManager = DiskCacheManager.getInstance();
