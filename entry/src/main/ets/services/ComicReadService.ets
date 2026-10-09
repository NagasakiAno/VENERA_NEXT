/**
 * 网络漫画阅读服务 (阶段3: 详情 → 章节图片管道)
 *
 * 链路(对应原版 ImageDownloader + CacheManager):
 *   comic.loadEp(comicId, epId) -> images: string[]
 *   每张图:
 *     comic.onImageLoad(url, comicId, epId) -> { headers, modifyImage? }
 *     -> HTTP(带 headers) -> 解码为 RGBA 缓冲
 *     -> 可选: 执行 modifyImage 还原(如 jm 的乱序拼接)
 *     -> PixelMap(内存缓存)
 */
import { image } from '@kit.ImageKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { httpClient, HttpMethod, ResponseType } from '../network/HttpClient';
import { jsRuntime } from '../runtime/JsRuntime';
import { imageBridge, ImageBuffer } from '../runtime/ImageBridge';
import { diskCacheManager } from '../utils/DiskCacheManager';
import { fileIo as fs } from '@kit.CoreFileKit';
import { downloadedChapterStore } from '../model/DownloadedChapterStore';

const DOMAIN = 0x0000;
const TAG = 'ComicReadService';
/** 内存缓存上限(张), 超出后释放最早的 */
const MAX_CACHE = 8;
const IMAGE_TIMEOUT_MS = 30000;

/** 一个章节的图片地址列表 */
export class ChapterImages {
  urls: string[] = [];
  error: string = '';

  isOk(): boolean {
    return this.error.length === 0 && this.urls.length > 0;
  }
}

/** onImageLoad 的配置 */
interface ImageLoadingConfig {
  /** 源解析出的真实图片地址, 空串表示沿用传入的地址 */
  url: string;
  headers: Record<string, string>;
  /** 源提供的还原代码(源码字符串), 空串表示无需还原 */
  modifyImage: string;
}

/** 解码后的原始像素 */
class RawPixels {
  width: number = 0;
  height: number = 0;
  buffer: ArrayBuffer = new ArrayBuffer(0);
}

export class ComicReadService {
  private static instance: ComicReadService = new ComicReadService();
  private cache: Map<string, image.PixelMap> = new Map<string, image.PixelMap>();
  private cacheOrder: string[] = [];

  static getInstance(): ComicReadService {
    return ComicReadService.instance;
  }

  /** 拉取章节图片地址(comic.loadEp) — 优先读取本地已下载的URL列表 */
  async loadImages(sourceKey: string, comicId: string, epId: string): Promise<ChapterImages> {
    const out = new ChapterImages();
    hilog.info(DOMAIN, TAG, 'loadImages: sourceKey=%{public}s comicId=%{public}s epId=%{public}s',
      sourceKey, comicId, epId);

    // 1. 优先检查本地是否已下载该章节（有URL列表文件）
    const localUrls = downloadedChapterStore.load(sourceKey, comicId, epId);
    if (localUrls !== null && localUrls.length > 0) {
      out.urls = localUrls;
      hilog.info(DOMAIN, TAG, '本地命中章节 %{public}s@%{public}s: %{public}d 张图',
        sourceKey, epId, out.urls.length);
      return out;
    }

    // 2. 本地没有，走网络获取
    let json = '';
    try {
      json = await jsRuntime.callLoadEp(sourceKey, comicId, epId);
    } catch (e) {
      out.error = `${e}`;
      hilog.warn(DOMAIN, TAG, 'loadEp 失败 %{public}s@%{public}s/%{public}s: %{public}s',
        sourceKey, comicId, epId, out.error);
      return out;
    }
    let parsed: Object;
    try {
      parsed = JSON.parse(json) as Object;
    } catch (e) {
      out.error = '章节数据无法解析';
      return out;
    }
    if (parsed === null || parsed === undefined) {
      out.error = '该章节没有图片';
      return out;
    }
    // 兼容 { images: [] } 与直接返回数组两种写法
    let list: Object = parsed;
    if (!Array.isArray(parsed)) {
      const rec = parsed as Record<string, Object>;
      list = rec['images'] ?? rec['imagesList'] ?? rec['urls'];
    }
    if (list === undefined || list === null || !Array.isArray(list)) {
      out.error = '该章节没有图片';
      return out;
    }
    const arr = list as Object[];
    for (let i = 0; i < arr.length; i++) {
      const u = arr[i];
      if (typeof u === 'string' && (u as string).length > 0) {
        out.urls.push(u as string);
      }
    }
    if (out.urls.length === 0) {
      out.error = '该章节没有图片';
    } else {
      // 网络获取成功 → 保存URL列表到本地，下次阅读优先从本地加载
      downloadedChapterStore.save(sourceKey, comicId, epId, out.urls);
    }
    hilog.info(DOMAIN, TAG, '章节 %{public}s@%{public}s: %{public}d 张图',
      sourceKey, epId, out.urls.length);
    return out;
  }

  /**
   * 加载单张图片: 带源声明的请求头下载, 必要时执行图片还原, 返回可直接渲染的 PixelMap。
   * 命中内存缓存时直接返回(调用方不要 release 缓存里的对象)。
   */
  async loadImage(sourceKey: string, comicId: string, epId: string,
                  url: string): Promise<image.PixelMap | null> {
    const cacheKey = sourceKey + '|' + comicId + '|' + epId + '|' + url;
    // 1. 内存缓存命中 → 直接返回
    const hit = this.cache.get(cacheKey);
    if (hit !== undefined) {
      return hit;
    }
    // 2. 磁盘缓存命中 → 读字节 → 解码 → 还原 → 写内存缓存
    const diskPath = diskCacheManager.find(cacheKey);
    if (diskPath !== null) {
      const diskBytes = this.readDiskFile(diskPath);
      if (diskBytes !== null) {
        const raw = await decode(diskBytes);
        if (raw !== null) {
          const cfg = await this.loadConfig(sourceKey, comicId, epId, url);
          let pm = await this.applyModify(sourceKey, raw, cfg.modifyImage);
          if (pm === null) {
            pm = await createFromPixels(raw);
          }
          if (pm !== null) {
            this.putCache(cacheKey, pm);
            hilog.info(DOMAIN, TAG, '磁盘缓存命中 %{public}d×%{public}d %{public}s',
              raw.width, raw.height, truncate(url));
            return pm;
          }
        }
      }
      // 磁盘缓存文件损坏, 删除该条目
      diskCacheManager.delete(cacheKey);
    }
    // 3. 网络下载
    const cfg = await this.loadConfig(sourceKey, comicId, epId, url);
    // 源可以把「图片标识」换成真实地址(如 e-hentai 用页码换 URL), 对应原版 configs['url'] ?? imageKey
    const target = cfg.url.length > 0 ? cfg.url : url;
    const bytes = await this.download(target, cfg.headers);
    if (bytes === null) {
      return null;
    }
    // 写入磁盘缓存(原始字节, 非解码后像素)
    diskCacheManager.write(cacheKey, bytes).catch((e: Error) => {
      hilog.warn(DOMAIN, TAG, '磁盘缓存写入失败: %{public}s', `${e}`);
    });
    const raw = await decode(bytes);
    if (raw === null) {
      return null;
    }
    let pm = await this.applyModify(sourceKey, raw, cfg.modifyImage);
    if (pm === null) {
      // 还原失败时退回原图, 至少能看
      pm = await createFromPixels(raw);
    }
    if (pm === null) {
      return null;
    }
    this.putCache(cacheKey, pm);
    hilog.info(DOMAIN, TAG, '图片就绪 %{public}d×%{public}d %{public}s',
      raw.width, raw.height, truncate(url));
    return pm;
  }

  /** 清空内存缓存(退出阅读器时调用, 磁盘缓存保留) */
  clearCache(): void {
    this.cache.forEach((pm: image.PixelMap) => {
      pm.release();
    });
    this.cache.clear();
    this.cacheOrder = [];
  }

  /** 清空磁盘缓存(用户手动清理时调用) */
  async clearDiskCache(): Promise<void> {
    await diskCacheManager.clear();
  }

  /**
   * 下载单张图片的原始字节（供 DownloadService 使用）。
   * 复用 loadConfig + download 逻辑，但不写入内存缓存、不解码。
   * 返回原始字节，调用方负责写入磁盘缓存。
   */
  async downloadImageBytes(sourceKey: string, comicId: string, epId: string,
    url: string): Promise<Uint8Array | null> {
    const cfg = await this.loadConfig(sourceKey, comicId, epId, url);
    const target = cfg.url.length > 0 ? cfg.url : url;
    return await this.download(target, cfg.headers);
  }

  /** 读取磁盘缓存文件为 Uint8Array */
  private readDiskFile(path: string): Uint8Array | null {
    try {
      const file = fs.openSync(path, fs.OpenMode.READ_ONLY);
      const stat = fs.statSync(path);
      const buf = new ArrayBuffer(stat.size);
      fs.readSync(file.fd, buf);
      fs.closeSync(file);
      return new Uint8Array(buf);
    } catch (e) {
      hilog.warn(DOMAIN, TAG, '读取磁盘缓存失败: %{public}s', `${e}`);
      return null;
    }
  }

  // ---------------------------------------------------------------- 内部

  private async loadConfig(sourceKey: string, comicId: string, epId: string,
                           url: string): Promise<ImageLoadingConfig> {
    const cfg: ImageLoadingConfig = { url: '', headers: {}, modifyImage: '' };

    // 1. 优先从本地持久化配置读取（离线阅读时不再走网络）
    const localCfg = downloadedChapterStore.loadImageConfig(sourceKey, comicId, epId, url);
    if (localCfg !== null) {
      cfg.url = localCfg.url;
      cfg.headers = localCfg.headers;
      cfg.modifyImage = localCfg.modifyImage;
      hilog.info(DOMAIN, TAG, '使用本地配置 %{public}s', truncate(url));
      return cfg;
    }

    // 2. 本地没有 → 走网络获取
    let json = '';
    try {
      json = await jsRuntime.callOnImageLoad(sourceKey, url, comicId, epId);
    } catch (e) {
      hilog.warn(DOMAIN, TAG, 'onImageLoad 失败: %{public}s', `${e}`);
      return cfg;
    }
    let parsed: Object;
    try {
      parsed = JSON.parse(json) as Object;
    } catch (e) {
      return cfg;
    }
    if (parsed === null || parsed === undefined) {
      return cfg;
    }
    const rec = parsed as Record<string, Object>;
    const u = rec['url'];
    if (typeof u === 'string' && (u as string).length > 0) {
      cfg.url = u as string;
    }
    const h = rec['headers'];
    if (h !== undefined && h !== null) {
      const hr = h as Record<string, Object>;
      Object.keys(hr).forEach((k: string) => {
        const v = hr[k];
        if (typeof v === 'string' && (v as string).length > 0) {
          cfg.headers[k] = v as string;
        }
      });
    }
    const m = rec['modifyImage'];
    if (typeof m === 'string' && (m as string).length > 0) {
      cfg.modifyImage = m as string;
    }

    // 3. 网络获取成功 → 保存到本地，下次离线阅读可直接使用
    downloadedChapterStore.saveImageConfig(sourceKey, comicId, epId, url,
      cfg.url, cfg.headers, cfg.modifyImage);

    return cfg;
  }

  private async download(url: string,
                         headers: Record<string, string>): Promise<Uint8Array | null> {
    try {
      const bytes = await httpClient.request<Uint8Array>({
        url: url,
        method: HttpMethod.GET,
        headers: headers,
        responseType: ResponseType.BYTES,
        timeout: IMAGE_TIMEOUT_MS
      });
      return bytes.length > 0 ? bytes : null;
    } catch (e) {
      hilog.warn(DOMAIN, TAG, '图片下载失败 %{public}s: %{public}s', truncate(url), `${e}`);
      return null;
    }
  }

  /** 执行源提供的还原代码; 未提供或失败返回 null */
  private async applyModify(sourceKey: string, raw: RawPixels,
                            code: string): Promise<image.PixelMap | null> {
    if (code.length === 0) {
      return null;
    }
    const inKey = imageBridge.put(new ImageBuffer(raw.width, raw.height, raw.buffer));
    try {
      const outKey = await jsRuntime.callModifyImage(sourceKey, inKey, code);
      const out = outKey > 0 ? imageBridge.get(outKey) : null;
      if (out === null) {
        hilog.warn(DOMAIN, TAG, '图片还原未返回结果(源=%{public}s)', sourceKey);
        return null;
      }
      const copy = new ImageBuffer(out.width, out.height, out.pixels.slice(0));
      imageBridge.release(outKey);
      hilog.info(DOMAIN, TAG, '图片还原完成 %{public}d×%{public}d (源=%{public}s)',
        copy.width, copy.height, sourceKey);
      return await createFromPixels(copyToRaw(copy));
    } finally {
      imageBridge.release(inKey);
    }
  }

  private putCache(key: string, pm: image.PixelMap): void {
    this.cache.set(key, pm);
    this.cacheOrder.push(key);
    while (this.cacheOrder.length > MAX_CACHE) {
      const old = this.cacheOrder.shift();
      if (old !== undefined) {
        const victim = this.cache.get(old);
        if (victim !== undefined) {
          victim.release();
          this.cache.delete(old);
        }
      }
    }
  }
}

/** 解码图片字节为 RGBA 原始像素 */
async function decode(bytes: Uint8Array): Promise<RawPixels | null> {
  let src: image.ImageSource | null = null;
  let pm: image.PixelMap | null = null;
  try {
    const buffer = bytes.buffer.slice(bytes.byteOffset, bytes.byteOffset + bytes.byteLength) as ArrayBuffer;
    src = image.createImageSource(buffer);
    const opts: image.DecodingOptions = {
      editable: true,
      desiredPixelFormat: image.PixelMapFormat.RGBA_8888
    };
    pm = await src.createPixelMap(opts);
    const info = await pm.getImageInfo();
    const raw = new RawPixels();
    raw.width = info.size.width;
    raw.height = info.size.height;
    const buf = new ArrayBuffer(pm.getPixelBytesNumber());
    await pm.readPixelsToBuffer(buf);
    raw.buffer = buf;
    return raw;
  } catch (e) {
    hilog.warn(DOMAIN, TAG, '图片解码失败: %{public}s', `${e}`);
    return null;
  } finally {
    if (pm !== null) {
      pm.release();
    }
    if (src !== null) {
      src.release();
    }
  }
}

/** 用 RGBA 原始像素构造 PixelMap */
async function createFromPixels(raw: RawPixels): Promise<image.PixelMap | null> {
  if (raw.width <= 0 || raw.height <= 0 || raw.buffer.byteLength === 0) {
    return null;
  }
  try {
    // srcPixelFormat 描述的是「传入缓冲区」的格式, 默认为 BGRA_8888,
    // 不写会把 RGBA 字节当 BGRA 读, 导致红蓝通道互换
    const opts: image.InitializationOptions = {
      size: { width: raw.width, height: raw.height },
      pixelFormat: image.PixelMapFormat.RGBA_8888,
      srcPixelFormat: image.PixelMapFormat.RGBA_8888,
      editable: false
    };
    return await image.createPixelMap(raw.buffer, opts);
  } catch (e) {
    hilog.warn(DOMAIN, TAG, '构造 PixelMap 失败: %{public}s', `${e}`);
    return null;
  }
}

function copyToRaw(buf: ImageBuffer): RawPixels {
  const raw = new RawPixels();
  raw.width = buf.width;
  raw.height = buf.height;
  raw.buffer = buf.pixels;
  return raw;
}

function truncate(s: string): string {
  return s.length > 90 ? s.substring(0, 90) + '…' : s;
}

/** 全局单例 */
export const comicReadService = ComicReadService.getInstance();
