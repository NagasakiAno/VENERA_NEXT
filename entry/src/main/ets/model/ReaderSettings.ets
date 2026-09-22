/**
 * VeneraNext 阅读器设置模型
 * 基于 AppSettings 持久化, 保存当前阅读偏好
 */
import { appSettings } from '../model/AppSettings';

/** 阅读模式 */
export enum ReaderMode {
  /** 左右翻页(从右向左, 日式) */
  GALLERY = 0,
  /** 右左翻页(从左向右, 韩/美) */
  RTL = 1,
  /** 上下滚动 */
  SCROLL = 2,
  /** 自适应 */
  AUTO = 3
}

/** 阅读器设置存取 */
export class ReaderSettings {
  private static instance: ReaderSettings = new ReaderSettings();

  static getInstance(): ReaderSettings {
    return ReaderSettings.instance;
  }

  getMode(): ReaderMode {
    const v = appSettings.get<string>('reader_mode', 'gallery');
    switch (v) {
      case 'rtl':
        return ReaderMode.RTL;
      case 'scroll':
        return ReaderMode.SCROLL;
      case 'auto':
        return ReaderMode.AUTO;
      default:
        return ReaderMode.GALLERY;
    }
  }

  setMode(mode: ReaderMode): void {
    const key = mode === ReaderMode.RTL ? 'rtl' : mode === ReaderMode.SCROLL ? 'scroll'
      : mode === ReaderMode.AUTO ? 'auto' : 'gallery';
    appSettings.put('reader_mode', key);
  }
}

/** 全局单例 */
export const readerSettings = ReaderSettings.getInstance();