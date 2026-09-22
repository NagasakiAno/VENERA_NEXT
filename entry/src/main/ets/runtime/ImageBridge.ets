/**
 * 图片桥 (对应原版 Dart 侧的 utils/image.dart)
 *
 * init.js 的 Image 类通过 sendMessage({method:'image', function:...}) 操作位图,
 * 供源脚本 comic.onImageLoad 返回的 modifyImage 代码做图片还原
 * (例: jm 把整页按 num 块乱序拼接, 需要重排)。
 *
 * 原版把像素放在宿主(Dart)侧的内存表里, 这里同样放在 ArkTS 侧:
 * JS 只传坐标参数, 像素数据不过桥, 因此开销与源脚本里的调用次数成正比而与图片大小无关。
 */
import { hilog } from '@kit.PerformanceAnalysisKit';

const DOMAIN = 0x0000;
const TAG = 'ImageBridge';
/** 表内最多保留的位图数(超出按插入顺序淘汰, 防止还原过程与缓存叠加导致内存膨胀) */
const MAX_IMAGES = 12;

/** 一张 RGBA_8888 位图 */
export class ImageBuffer {
  width: number;
  height: number;
  /** RGBA 顺序, 字节数 = width * height * 4 */
  pixels: ArrayBuffer;

  constructor(width: number, height: number, pixels: ArrayBuffer) {
    this.width = width;
    this.height = height;
    this.pixels = pixels;
  }
}

/** method="image" 的报文 */
interface ImageMessage {
  function?: string;
  key?: number;
  x?: number;
  y?: number;
  image?: number;
  srcX?: number;
  srcY?: number;
  width?: number;
  height?: number;
}

export class ImageBridge {
  private static instance: ImageBridge = new ImageBridge();
  private images: Map<number, ImageBuffer> = new Map<number, ImageBuffer>();
  private order: number[] = [];
  private nextKey: number = 1;

  static getInstance(): ImageBridge {
    return ImageBridge.instance;
  }

  /** 登记一张位图, 返回其 key(与 init.js 里 Image.key 对应) */
  put(buffer: ImageBuffer): number {
    const key = this.nextKey;
    this.nextKey = this.nextKey + 1;
    this.images.set(key, buffer);
    this.order.push(key);
    while (this.order.length > MAX_IMAGES) {
      const old = this.order.shift();
      if (old !== undefined) {
        this.images.delete(old);
      }
    }
    return key;
  }

  get(key: number): ImageBuffer | null {
    const b = this.images.get(key);
    return b === undefined ? null : b;
  }

  release(key: number): void {
    this.images.delete(key);
    const i = this.order.indexOf(key);
    if (i >= 0) {
      this.order.splice(i, 1);
    }
  }

  /** 丢弃除 keep 之外的全部位图(一次还原结束后清理) */
  releaseExcept(keep: number[]): void {
    const next: number[] = [];
    for (let i = 0; i < this.order.length; i++) {
      const k = this.order[i];
      if (keep.indexOf(k) >= 0) {
        next.push(k);
      } else {
        this.images.delete(k);
      }
    }
    this.order = next;
  }

  /** 处理一条 image 报文的原始 JSON; 返回值由调用方 JSON 化后回给 JS(与原版一致) */
  handleRaw(messageJson: string): Object | null {
    let msg: ImageMessage;
    try {
      msg = JSON.parse(messageJson) as ImageMessage;
    } catch (e) {
      hilog.error(DOMAIN, TAG, 'image 报文解析失败');
      return null;
    }
    return this.handle(msg);
  }

  /** 处理一条 image 报文; 返回值由调用方 JSON 化后回给 JS(与原版一致) */
  private handle(msg: ImageMessage): Object | null {
    const fn = msg.function ?? '';
    if (fn === 'emptyImage') {
      const w = msg.width ?? 0;
      const h = msg.height ?? 0;
      if (w <= 0 || h <= 0) {
        return null;
      }
      return this.put(new ImageBuffer(w, h, new ArrayBuffer(w * h * 4)));
    }

    const dst = this.get(msg.key ?? 0);
    if (dst === null) {
      hilog.warn(DOMAIN, TAG, 'image 报文找不到位图: %{public}s key=%{public}d', fn, msg.key ?? 0);
      return null;
    }
    if (fn === 'getWidth') {
      return dst.width;
    }
    if (fn === 'getHeight') {
      return dst.height;
    }
    if (fn === 'fillImageAt') {
      const src = this.get(msg.image ?? 0);
      if (src === null) {
        return null;
      }
      this.blit(dst, msg.x ?? 0, msg.y ?? 0, src, 0, 0, src.width, src.height);
      return null;
    }
    if (fn === 'fillImageRangeAt') {
      const src = this.get(msg.image ?? 0);
      if (src === null) {
        return null;
      }
      this.blit(dst, msg.x ?? 0, msg.y ?? 0, src,
        msg.srcX ?? 0, msg.srcY ?? 0, msg.width ?? 0, msg.height ?? 0);
      return null;
    }
    if (fn === 'copyRange') {
      const rw = msg.width ?? 0;
      const rh = msg.height ?? 0;
      if (rw <= 0 || rh <= 0) {
        return null;
      }
      const out = new ImageBuffer(rw, rh, new ArrayBuffer(rw * rh * 4));
      this.blit(out, 0, 0, dst, msg.x ?? 0, msg.y ?? 0, rw, rh);
      return this.put(out);
    }
    if (fn === 'copyAndRotate90') {
      return this.put(this.rotate90(dst));
    }
    hilog.warn(DOMAIN, TAG, '未实现的 image 方法: %{public}s', fn);
    return null;
  }

  /** 把 src 的 [srcX,srcX+w) × [srcY,srcY+h) 拷到 dst 的 (x,y), 自动裁剪越界 */
  private blit(dst: ImageBuffer, x: number, y: number, src: ImageBuffer,
               srcX: number, srcY: number, w: number, h: number): void {
    if (w <= 0 || h <= 0 || x < 0 || y < 0 || srcX < 0 || srcY < 0) {
      return;
    }
    let copyW = w;
    let copyH = h;
    if (x + copyW > dst.width) {
      copyW = dst.width - x;
    }
    if (y + copyH > dst.height) {
      copyH = dst.height - y;
    }
    if (srcX + copyW > src.width) {
      copyW = src.width - srcX;
    }
    if (srcY + copyH > src.height) {
      copyH = src.height - srcY;
    }
    if (copyW <= 0 || copyH <= 0) {
      return;
    }
    const d = new Uint8Array(dst.pixels);
    const s = new Uint8Array(src.pixels);
    const dRow = dst.width * 4;
    const sRow = src.width * 4;
    for (let row = 0; row < copyH; row++) {
      const dOff = (y + row) * dRow + x * 4;
      const sOff = (srcY + row) * sRow + srcX * 4;
      d.set(s.subarray(sOff, sOff + copyW * 4), dOff);
    }
  }

  /** 顺时针旋转 90° */
  private rotate90(buf: ImageBuffer): ImageBuffer {
    const nw = buf.height;
    const nh = buf.width;
    const out = new ImageBuffer(nw, nh, new ArrayBuffer(nw * nh * 4));
    const s = new Uint8Array(buf.pixels);
    const d = new Uint8Array(out.pixels);
    const sRow = buf.width * 4;
    const dRow = nw * 4;
    for (let y = 0; y < buf.height; y++) {
      for (let x = 0; x < buf.width; x++) {
        const sOff = y * sRow + x * 4;
        const dOff = x * dRow + (buf.height - 1 - y) * 4;
        d[dOff] = s[sOff];
        d[dOff + 1] = s[sOff + 1];
        d[dOff + 2] = s[sOff + 2];
        d[dOff + 3] = s[sOff + 3];
      }
    }
    return out;
  }
}

/** 全局单例 */
export const imageBridge = ImageBridge.getInstance();
