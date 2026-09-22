/**
 * 搜索服务
 *
 * 职责:
 *   1. 汇总有搜索能力的源, 解析其 search.optionList
 *   2. 单源搜索(按源实现分派 load / loadNext)
 *   3. 聚合搜索: 并行请求所有源的第一页, 供分块预览
 *
 * 对应原版 search_page.dart / search_result_page.dart / aggregated_search_page.dart。
 */
import { hilog } from '@kit.PerformanceAnalysisKit';
import { comicSourceManager } from '../model/ComicSource';
import { ComicSourceMeta, SearchOptionDef } from '../model/sources/ComicSourceMeta';
import { jsRuntime } from '../runtime/JsRuntime';
import { ExploreComic, parseComicList, asNum, asStr } from './ExploreService';

const DOMAIN = 0x0000;
const TAG = 'SearchService';

/** 单个源的搜索结果 */
export class SourceSearchResult {
  sourceKey: string = '';
  sourceName: string = '';
  comics: ExploreComic[] = [];
  maxPage: number = 1;
  next: string = '';
  /** 该源搜索失败时的原因 */
  error: string = '';

  isOk(): boolean {
    return this.error.length === 0;
  }

  isEmpty(): boolean {
    return this.comics.length === 0;
  }
}

/** 输入是否命中源声明的 ID 正则(源的写法参差, 正则非法时按不命中处理) */
function matchesId(pattern: string, text: string): boolean {
  try {
    return new RegExp(pattern).test(text);
  } catch (e) {
    return false;
  }
}

export class SearchService {
  private static instance: SearchService = new SearchService();
  private parsedKeys: Set<string> = new Set<string>();

  static getInstance(): SearchService {
    return SearchService.instance;
  }

  /** 有搜索能力的源(优先取真引擎探测的结果) */
  sources(): ComicSourceMeta[] {
    const out: ComicSourceMeta[] = [];
    const metas = comicSourceManager.allJsSources();
    for (let i = 0; i < metas.length; i++) {
      const meta = metas[i];
      if (meta.searchOptions.length > 0 || meta.searchHasLoad) {
        out.push(meta);
      }
    }
    return out;
  }

  /**
   * 输入整体命中源声明的 ID 规则(comic.idMatch)时, 返回可按 ID 直达的源。
   * 对应原版 search_page.dart 中 findSuggestions() 对 idMatcher 的遍历。
   */
  idMatchSources(keyword: string): ComicSourceMeta[] {
    const text = keyword.trim();
    const out: ComicSourceMeta[] = [];
    if (text.length === 0) {
      return out;
    }
    const metas = comicSourceManager.allJsSources();
    for (let i = 0; i < metas.length; i++) {
      const meta = metas[i];
      if (meta.idMatcher.length === 0 || !meta.hasLoadInfo) {
        continue;
      }
      if (matchesId(meta.idMatcher, text)) {
        out.push(meta);
      }
    }
    return out;
  }

  /** 解析尚未解析过的源的搜索元信息 */
  async refresh(): Promise<void> {
    const metas: ComicSourceMeta[] = comicSourceManager.allJsSources();
    for (let i = 0; i < metas.length; i++) {
      const meta = metas[i];
      if (this.parsedKeys.has(meta.key)) {
        continue;
      }
      this.parsedKeys.add(meta.key);
      try {
        await jsRuntime.enrichSearchOptions(meta);
      } catch (e) {
        hilog.warn(DOMAIN, TAG, '解析源 %{public}s 的搜索选项失败: %{public}s', meta.key, `${e}`);
      }
    }
  }

  invalidate(key: string): void {
    this.parsedKeys.delete(key);
  }

  /** 某源的默认选项值(聚合搜索时无法逐个选择, 用各自默认值) */
  defaultOptions(meta: ComicSourceMeta): string[] {
    const out: string[] = [];
    const defs: SearchOptionDef[] = meta.searchOptions;
    for (let i = 0; i < defs.length; i++) {
      const def = defs[i];
      if (def.defaultValue.length > 0) {
        out.push(def.defaultValue);
        continue;
      }
      // 未声明默认值: 取第一个可选项, 避免源拿到空串
      let first = '';
      def.options.forEach((label: string, key: string) => {
        if (first.length === 0) {
          first = key;
        }
      });
      out.push(first);
    }
    return out;
  }

  /** 单源搜索 */
  async search(sourceKey: string, keyword: string, options: string[],
               pageNo: number): Promise<SourceSearchResult> {
    const result = new SourceSearchResult();
    result.sourceKey = sourceKey;
    const meta = comicSourceManager.findJsSource(sourceKey);
    result.sourceName = meta === null ? sourceKey : meta.name;
    try {
      const json = await jsRuntime.callSearchLoad(sourceKey, keyword, options, pageNo);
      this.fill(result, json);
    } catch (e) {
      result.error = `${e}`;
      hilog.warn(DOMAIN, TAG, '源 %{public}s 搜索失败: %{public}s', sourceKey, result.error);
    }
    return result;
  }

  /** 聚合搜索: 并行取所有源的第一页 */
  async searchAll(keyword: string): Promise<SourceSearchResult[]> {
    const metas = this.sources();
    const tasks: Promise<SourceSearchResult>[] = [];
    for (let i = 0; i < metas.length; i++) {
      const meta = metas[i];
      tasks.push(this.search(meta.key, keyword, this.defaultOptions(meta), 1));
    }
    return await Promise.all(tasks);
  }

  /** 把源返回的 JSON 填充到结果模型 */
  private fill(result: SourceSearchResult, json: string): void {
    let parsed: Object;
    try {
      parsed = JSON.parse(json) as Object;
    } catch (e) {
      result.error = '返回内容无法解析';
      return;
    }
    if (parsed === null || parsed === undefined) {
      return;
    }
    // 部分源的搜索实现直接返回数组
    const rec = parsed as Record<string, Object>;
    const comicsField = rec['comics'];
    if (comicsField === undefined || comicsField === null) {
      result.comics = parseComicList(parsed, result.sourceKey, result.sourceName);
      result.maxPage = 1;
      return;
    }
    result.comics = parseComicList(comicsField, result.sourceKey, result.sourceName);
    result.maxPage = asNum(rec['maxPage'], 1);
    result.next = asStr(rec['next']);
  }
}

/** 全局单例 */
export const searchService = SearchService.getInstance();
