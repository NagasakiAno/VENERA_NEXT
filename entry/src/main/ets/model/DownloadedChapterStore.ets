/**
 * 已下载章节的图片URL列表持久化存储
 * 下载完成后保存URL列表，阅读时优先从本地加载，避免依赖网络获取URL
 */
import { fileIo as fs } from '@kit.CoreFileKit';
import { common } from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { util } from '@kit.ArkTS';

const DOMAIN = 0x0000;
const TAG = 'DownloadedChapterStore';
const DIR_NAME = 'downloaded_chapters';

class DownloadedChapterStore {
  private baseDir: string = '';

  /** 初始化目录（在 EntryAbility.onCreate 中调用） */
  init(context: common.Context): void {
    this.baseDir = context.filesDir + '/' + DIR_NAME;
    try {
      if (!fs.accessSync(this.baseDir)) {
        fs.mkdirSync(this.baseDir, true);
      }
    } catch (e) {
      hilog.error(DOMAIN, TAG, 'init mkdir failed: %{public}s', `${e}`);
    }
  }

  /** 保存章节图片URL列表到本地 */
  save(sourceKey: string, comicId: string, epId: string, urls: string[]): void {
    if (this.baseDir.length === 0) {
      hilog.warn(DOMAIN, TAG, 'baseDir not initialized');
      return;
    }
    const key = this.makeKey(sourceKey, comicId, epId);
    const path = this.baseDir + '/' + key + '.json';
    try {
      const data = JSON.stringify({ urls: urls });
      const file = fs.openSync(path, fs.OpenMode.CREATE | fs.OpenMode.WRITE_ONLY | fs.OpenMode.TRUNC);
      fs.writeSync(file.fd, data);
      fs.closeSync(file);
      hilog.info(DOMAIN, TAG, 'saved %{public}d urls for %{public}s', urls.length, key);
    } catch (e) {
      hilog.error(DOMAIN, TAG, 'save failed for %{public}s: %{public}s', key, `${e}`);
    }
  }

  /** 从本地加载章节图片URL列表，不存在返回 null */
  load(sourceKey: string, comicId: string, epId: string): string[] | null {
    if (this.baseDir.length === 0) {
      hilog.warn(DOMAIN, TAG, 'load: baseDir not initialized');
      return null;
    }
    const key = this.makeKey(sourceKey, comicId, epId);
    const path = this.baseDir + '/' + key + '.json';
    hilog.info(DOMAIN, TAG, 'load: checking path=%{public}s', path);
    try {
      if (!fs.accessSync(path)) {
        hilog.info(DOMAIN, TAG, 'load: file not found for %{public}s', key);
        return null;
      }
      const file = fs.openSync(path, fs.OpenMode.READ_ONLY);
      const stat = fs.statSync(path);
      const buf = new ArrayBuffer(stat.size);
      fs.readSync(file.fd, buf);
      fs.closeSync(file);
      const parsed = JSON.parse(util.TextDecoder.create('utf-8').decodeToString(new Uint8Array(buf))) as Record<string, Object>;
      const urls = parsed['urls'];
      if (urls !== undefined && urls !== null && Array.isArray(urls)) {
        const arr = urls as Object[];
        const result: string[] = [];
        for (let i = 0; i < arr.length; i++) {
          const u = arr[i];
          if (typeof u === 'string' && (u as string).length > 0) {
            result.push(u as string);
          }
        }
        hilog.info(DOMAIN, TAG, 'loaded %{public}d urls for %{public}s', result.length, key);
        return result;
      }
      return null;
    } catch (e) {
      hilog.warn(DOMAIN, TAG, 'load failed for %{public}s: %{public}s', key, `${e}`);
      return null;
    }
  }

  /** 判断该章节是否已下载（本地有URL列表文件） */
  has(sourceKey: string, comicId: string, epId: string): boolean {
    if (this.baseDir.length === 0) {
      return false;
    }
    const key = this.makeKey(sourceKey, comicId, epId);
    const path = this.baseDir + '/' + key + '.json';
    try {
      return fs.accessSync(path);
    } catch (e) {
      return false;
    }
  }

  /** 删除某个章节的本地URL列表 */
  remove(sourceKey: string, comicId: string, epId: string): void {
    if (this.baseDir.length === 0) {
      return;
    }
    const key = this.makeKey(sourceKey, comicId, epId);
    const path = this.baseDir + '/' + key + '.json';
    try {
      if (fs.accessSync(path)) {
        fs.unlinkSync(path);
      }
    } catch (e) {
      hilog.warn(DOMAIN, TAG, 'remove failed for %{public}s: %{public}s', key, `${e}`);
    }
  }

  /** 保存 onImageLoad 配置到本地（离线阅读时不再走网络） */
  saveImageConfig(sourceKey: string, comicId: string, epId: string, url: string,
                  cfgUrl: string, headers: Record<string, string>, modifyImage: string): void {
    if (this.baseDir.length === 0) {
      return;
    }
    const key = this.makeCfgKey(sourceKey, comicId, epId, url);
    const path = this.baseDir + '/' + key + '.json';
    try {
      const data = JSON.stringify({
        url: cfgUrl,
        headers: headers,
        modifyImage: modifyImage,
        imageUrl: url
      });
      const file = fs.openSync(path, fs.OpenMode.CREATE | fs.OpenMode.WRITE_ONLY | fs.OpenMode.TRUNC);
      fs.writeSync(file.fd, data);
      fs.closeSync(file);
    } catch (e) {
      hilog.warn(DOMAIN, TAG, 'saveImageConfig failed: %{public}s', `${e}`);
    }
  }

  /** 从本地加载 onImageLoad 配置，不存在返回 null */
  loadImageConfig(sourceKey: string, comicId: string, epId: string,
                  url: string): ImageConfigRecord | null {
    if (this.baseDir.length === 0) {
      return null;
    }
    const key = this.makeCfgKey(sourceKey, comicId, epId, url);
    const path = this.baseDir + '/' + key + '.json';
    try {
      if (!fs.accessSync(path)) {
        return null;
      }
      const file = fs.openSync(path, fs.OpenMode.READ_ONLY);
      const stat = fs.statSync(path);
      const buf = new ArrayBuffer(stat.size);
      fs.readSync(file.fd, buf);
      fs.closeSync(file);
      const parsed = JSON.parse(util.TextDecoder.create('utf-8').decodeToString(new Uint8Array(buf))) as Record<string, Object>;
      const rec = new ImageConfigRecord();
      const u = parsed['url'];
      if (typeof u === 'string') {
        rec.url = u as string;
      }
      const h = parsed['headers'];
      if (h !== undefined && h !== null) {
        const hr = h as Record<string, Object>;
        Object.keys(hr).forEach((k: string) => {
          const v = hr[k];
          if (typeof v === 'string') {
            rec.headers[k] = v as string;
          }
        });
      }
      const m = parsed['modifyImage'];
      if (typeof m === 'string') {
        rec.modifyImage = m as string;
      }
      return rec;
    } catch (e) {
      hilog.warn(DOMAIN, TAG, 'loadImageConfig failed: %{public}s', `${e}`);
      return null;
    }
  }

  private makeKey(sourceKey: string, comicId: string, epId: string): string {
    // 文件名中不能含 | ，替换为 _
    return (sourceKey + '_' + comicId + '_' + epId).replace(/[|/\\:*?"<>]/g, '_');
  }

  /** 图片配置的 key: 在章节 key 基础上加入 url 的哈希, 确保每张图片有独立配置 */
  private makeCfgKey(sourceKey: string, comicId: string, epId: string, url: string): string {
    return this.makeKey(sourceKey, comicId, epId) + '_cfg_' + this.hashStr(url);
  }

  /** 简单字符串哈希(DJB2), 用于生成短文件名区分不同图片 */
  private hashStr(s: string): string {
    let h = 5381;
    for (let i = 0; i < s.length; i++) {
      h = ((h << 5) + h) + s.charCodeAt(i);
      h = h & 0x7FFFFFFF; // 保持正数
    }
    return h.toString(36);
  }
}

/** onImageLoad 配置的持久化记录 */
export class ImageConfigRecord {
  url: string = '';
  headers: Record<string, string> = {};
  modifyImage: string = '';
}

/** 全局单例 */
export const downloadedChapterStore = new DownloadedChapterStore();
