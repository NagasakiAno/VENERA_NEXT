/**
 * 漫画详情页缓存
 *
 * 缓存源脚本 callLoadInfo 返回的原始 JSON 字符串，避免重复网络请求。
 * 内存缓存 + 磁盘持久化(filesDir/detail_cache/{sourceKey}/{comicId}.json)。
 * 命中缓存时 ComicDetailService 直接 JSON.parse 构造 ComicDetails，秒开详情页。
 */
import { fileIo as fs } from '@kit.CoreFileKit';
import { common } from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { util } from '@kit.ArkTS';

const DOMAIN = 0x0000;
const TAG = 'ComicDetailCache';

class ComicDetailCache {
  private static instance: ComicDetailCache = new ComicDetailCache();

  /** 内存缓存: key = sourceKey|comicId → 原始 JSON 字符串 */
  private memCache: Map<string, string> = new Map<string, string>();

  /** 磁盘缓存根目录 */
  private rootDir: string = '';

  static getInstance(): ComicDetailCache {
    return ComicDetailCache.instance;
  }

  /** 初始化磁盘缓存目录 */
  async init(context: common.Context): Promise<void> {
    this.rootDir = context.filesDir + '/detail_cache';
    try {
      if (!fs.accessSync(this.rootDir)) {
        fs.mkdirSync(this.rootDir, true);
      }
      hilog.info(DOMAIN, TAG, '详情缓存目录: %{public}s', this.rootDir);
    } catch (e) {
      hilog.error(DOMAIN, TAG, 'init 失败: %{public}s', `${e}`);
    }
  }

  /** 读取缓存: 先内存后磁盘，返回原始 JSON 或 null */
  get(sourceKey: string, comicId: string): string | null {
    const key = sourceKey + '|' + comicId;
    // 1. 内存命中
    const memHit = this.memCache.get(key);
    if (memHit !== undefined) {
      hilog.info(DOMAIN, TAG, '内存缓存命中 %{public}s', key);
      return memHit;
    }
    // 2. 磁盘命中
    if (this.rootDir.length === 0) {
      return null;
    }
    const filePath = this.diskPath(sourceKey, comicId);
    try {
      if (!fs.accessSync(filePath)) {
        return null;
      }
      const file = fs.openSync(filePath, fs.OpenMode.READ_ONLY);
      const stat = fs.statSync(file.fd);
      const buf = new ArrayBuffer(stat.size);
      fs.readSync(file.fd, buf);
      fs.closeSync(file);
      const json = util.TextDecoder.create('utf-8').decodeToString(new Uint8Array(buf));
      // 回填内存缓存
      this.memCache.set(key, json);
      hilog.info(DOMAIN, TAG, '磁盘缓存命中 %{public}s (%{public}d bytes)', key, stat.size);
      return json;
    } catch (e) {
      hilog.warn(DOMAIN, TAG, '磁盘读取失败 %{public}s: %{public}s', key, `${e}`);
      return null;
    }
  }

  /** 写入缓存: 内存 + 异步磁盘 */
  put(sourceKey: string, comicId: string, rawJson: string): void {
    const key = sourceKey + '|' + comicId;
    this.memCache.set(key, rawJson);
    // 异步写磁盘，不阻塞调用方
    this.writeDisk(sourceKey, comicId, rawJson).catch((e: Error) => {
      hilog.warn(DOMAIN, TAG, '磁盘写入失败 %{public}s: %{public}s', key, `${e}`);
    });
  }

  /** 异步写入磁盘文件 */
  private async writeDisk(sourceKey: string, comicId: string, rawJson: string): Promise<void> {
    if (this.rootDir.length === 0) {
      return;
    }
    const filePath = this.diskPath(sourceKey, comicId);
    const dir = filePath.substring(0, filePath.lastIndexOf('/'));
    try {
      // 确保子目录存在
      if (!fs.accessSync(dir)) {
        fs.mkdirSync(dir, true);
      }
      const file = fs.openSync(filePath, fs.OpenMode.CREATE | fs.OpenMode.WRITE_ONLY |
        fs.OpenMode.TRUNC);
      const bytes = util.TextEncoder.create('utf-8').encodeInto(rawJson);
      fs.writeSync(file.fd, bytes.buffer);
      fs.closeSync(file);
      hilog.info(DOMAIN, TAG, '磁盘写入成功 %{public}s (%{public}d bytes)',
        sourceKey + '|' + comicId, rawJson.length);
    } catch (e) {
      hilog.warn(DOMAIN, TAG, '磁盘写入异常 %{public}s: %{public}s',
        sourceKey + '|' + comicId, `${e}`);
    }
  }

  /** 磁盘文件路径（comicId 可能是 URL，需转义非法文件名字符） */
  private diskPath(sourceKey: string, comicId: string): string {
    const safeId = comicId.replace(/[|/\\:*?"<>]/g, '_');
    return this.rootDir + '/' + sourceKey + '/' + safeId + '.json';
  }
}

/** 全局单例 */
export const comicDetailCache = ComicDetailCache.getInstance();
