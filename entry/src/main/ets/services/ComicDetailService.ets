/**
 * 漫画详情服务
 *
 * 对应原版 ComicPage 的数据入口: comic.loadInfo(id) -> ComicDetails。
 * 目前服务于「搜索框按 ID 直达」: 输入整体命中源声明的 comic.idMatch 时直接加载详情。
 */
import { hilog } from '@kit.PerformanceAnalysisKit';
import { ComicDetails } from '../model/ComicModels';
import { comicSourceManager } from '../model/ComicSource';
import { jsRuntime } from '../runtime/JsRuntime';
import { comicDetailCache } from './ComicDetailCache';

const DOMAIN = 0x0000;
const TAG = 'ComicDetailService';

export class ComicDetailService {
  private static instance: ComicDetailService = new ComicDetailService();

  static getInstance(): ComicDetailService {
    return ComicDetailService.instance;
  }

  /** 按源与 ID 加载漫画详情（优先缓存，未命中走网络） */
  async load(sourceKey: string, id: string): Promise<ComicDetails> {
    const meta = comicSourceManager.findJsSource(sourceKey);
    if (meta === null) {
      throw new Error('源不存在: ' + sourceKey);
    }
    if (!meta.hasLoadInfo) {
      throw new Error('源 ' + meta.name + ' 不支持加载漫画详情');
    }

    // 1. 缓存命中 → 直接构造 ComicDetails
    const cached = comicDetailCache.get(sourceKey, id);
    if (cached !== null) {
      let parsedCache: Object | null = null;
      try {
        parsedCache = JSON.parse(cached) as Object;
      } catch (e) {
        hilog.warn(DOMAIN, TAG, '缓存 JSON 解析失败，回退网络: %{public}s', `${e}`);
      }
      if (parsedCache !== null && parsedCache !== undefined) {
        const detail = new ComicDetails(sourceKey, parsedCache as Record<string, Object>);
        detail.comicId = id;
        hilog.info(DOMAIN, TAG, '缓存命中详情 %{public}s@%{public}s: 章节 %{public}d',
          sourceKey, id, detail.chapters === null ? 0 : detail.chapters.length());
        return detail;
      }
    }

    // 2. 未命中 → 网络请求
    const json = await jsRuntime.callLoadInfo(sourceKey, id);
    let parsed: Object;
    try {
      parsed = JSON.parse(json) as Object;
    } catch (e) {
      throw new Error('详情数据无法解析');
    }
    if (parsed === null || parsed === undefined) {
      throw new Error('没有该 ID 对应的漫画');
    }
    // 3. 写入缓存
    comicDetailCache.put(sourceKey, id, json);
    const detail = new ComicDetails(sourceKey, parsed as Record<string, Object>);
    detail.comicId = id;
    hilog.info(DOMAIN, TAG, '详情 %{public}s@%{public}s: 章节 %{public}d, 推荐 %{public}d',
      sourceKey, id, detail.chapters === null ? 0 : detail.chapters.length(),
      detail.recommend.length);
    return detail;
  }
}

/** 全局单例 */
export const comicDetailService = ComicDetailService.getInstance();
