/**
 * VeneraNext MangaDex 真实源(公开 API, 无签名/无区域限制)
 * 对应 venera-configs/manga_dex.js, 用 ArkTS 原生实现
 * API: https://api.mangadex.org (MangaDex 官方公开 REST API)
 */
import { httpClient, HttpMethod, ResponseType } from '../../network/HttpClient';
import { comic_Res } from '../../utils/Res';
import { BaseComicSource, comicSourceManager, SearchResult, ComicPagesResult } from '../ComicSource';
import { Comic, ComicDetails } from '../ComicModels';
import { hilog } from '@kit.PerformanceAnalysisKit';

const DOMAIN = 0x0000;
const TAG = 'MangaDexSource';
const API = 'https://api.mangadex.org';
const COVER = 'https://mangadex.org/covers';

type Json = Record<string, Object>;

/**
 * MangaDex 漫画源
 */
export class MangaDexSource extends BaseComicSource {
  readonly key: string = 'manga_dex';
  readonly name: string = 'MangaDex';
  readonly version: string = '1.2.0';

  loadSetting(key: string, defaultValue: string): string {
    return defaultValue;
  }

  /** 从 MangaDex 条目解析 Comic */
  private parseComic(data: Json): Comic {
    const id = data['id'] as string ?? '';
    const attrs = data['attributes'] as Json;
    // 主标题(优先 en)
    const mainTitle = this.pickTitle(attrs['title'] as Json, attrs['altTitles'] as Object[]);
    // 封面
    const rels = data['relationships'] as Object[] ?? [];
    let cover = '';
    for (let i = 0; i < rels.length; i++) {
      const rel = rels[i] as Json;
      if (rel['type'] === 'cover_art' && rel['attributes']) {
        const fn = (rel['attributes'] as Json)['fileName'];
        if (fn) {
          cover = `${COVER}/${id}/${fn}.256.jpg`;
        }
        break;
      }
    }
    // 标签
    const tags: string[] = [];
    const tagArr = attrs['tags'] as Object[] ?? [];
    tagArr.forEach((t) => {
      const tt = t as Json;
      const name = (tt['attributes'] as Json)['name'] as Json;
      const en = name['en'];
      if (en) {
        tags.push(en as string);
      }
    });
    const input: Record<string, Object> = {
      'id': id,
      'title': mainTitle,
      'cover': cover,
      'tags': tags
    };
    return new Comic(this.key, input);
  }

  /** 选择标题(优先英文/中文, 兼容不同 locale) */
  private pickTitle(title: Json, altTitles: Object[] | null): string {
    const candidates: string[] = [];
    if (title) {
      (Object.keys(title)).forEach((lang) => {
        candidates.push(`${title[lang]}`);
      });
    }
    if (altTitles) {
      altTitles.forEach((al) => {
        const a = al as Json;
        Object.keys(a).forEach((lang) => {
          candidates.push(`${a[lang]}`);
        });
      });
    }
    if (candidates.length === 0) {
      return '';
    }
    // 英文优先
    for (let i = 0; i < candidates.length; i++) {
      if (candidates[i]) {
        return candidates[i];
      }
    }
    return candidates[0];
  }

  /** 加载列表接口(通用) */
  private async fetchList(url: string): Promise<comic_Res<SearchResult>> {
    try {
      const resp = await httpClient.rawRequest({
        url: url,
        method: HttpMethod.GET,
        headers: { 'Accept': 'application/json' }
      });
      if (resp.status !== 200) {
        return comic_Res.fail<SearchResult>(`HTTP ${resp.status}`);
      }
      const data = JSON.parse(resp.body) as Json;
      const total = data['total'] as number ?? 0;
      const items = data['data'] as Object[] ?? [];
      const comics: Comic[] = [];
      items.forEach((it) => {
        const v = it as Json;
        if (v && v['id']) {
          comics.push(this.parseComic(v));
        }
      });
      const maxPage = Math.ceil(total / 20) || 1;
      const result: SearchResult = { comics: comics, maxPage: maxPage };
      return comic_Res.success(result);
    } catch (e) {
      return comic_Res.fail<SearchResult>(`${e}`);
    }
  }

  // ---------- 协议实现 ----------

  async loadExplore(page: number): Promise<comic_Res<SearchResult>> {
    // MangaDex 热门: 30 天内关注的漫画
    const date = new Date(Date.now() - 30 * 24 * 60 * 60 * 1000);
    const iso = date.toISOString().substring(0, 19);
    const url = `${API}/manga?includes[]=cover_art&includes[]=artist&includes[]=author&` +
      `order%5BfollowedCount%5D=desc&hasAvailableChapters=true&` +
      `createdAtSince=${iso}&limit=20&offset=${(page - 1) * 20}`;
    return this.fetchList(url);
  }

  async search(keyword: string, page: number): Promise<comic_Res<SearchResult>> {
    const q = encodeURIComponent(keyword);
    const url = `${API}/manga?includes[]=cover_art&limit=20&offset=${(page - 1) * 20}&title=${q}`;
    return this.fetchList(url);
  }

  async loadComicInfo(id: string): Promise<comic_Res<ComicDetails>> {
    try {
      const resp = await httpClient.rawRequest({
        url: `${API}/manga/${id}?includes[]=cover_art&includes[]=artist&includes[]=author`,
        method: HttpMethod.GET,
        headers: { 'Accept': 'application/json' }
      });
      if (resp.status !== 200) {
        return comic_Res.fail<ComicDetails>(`HTTP ${resp.status}`);
      }
      const data = JSON.parse(resp.body) as Json;
      const comicData = data['data'] as Json;
      const attrs = comicData['attributes'] as Json;
      const title = this.pickTitle(attrs['title'] as Json, attrs['altTitles'] as Object[]);
      // 封面
      const rels = comicData['relationships'] as Object[] ?? [];
      let cover = '';
      for (let i = 0; i < rels.length; i++) {
        const rel = rels[i] as Json;
        if (rel['type'] === 'cover_art' && rel['attributes']) {
          const fn = (rel['attributes'] as Json)['fileName'];
          if (fn) {
            cover = `${COVER}/${id}/${fn}.256.jpg`;
          }
          break;
        }
      }
      const desc = attrs['description'] as Json;
      const description = `${desc['en'] ?? ''}`;
      // 标签
      const tagMap: Record<string, Object> = {};
      const genres: string[] = [];
      const tagArr = attrs['tags'] as Object[] ?? [];
      tagArr.forEach((t) => {
        const tt = t as Json;
        const name = (tt['attributes'] as Json)['name'] as Json;
        const en = name['en'];
        if (en) {
          genres.push(en as string);
        }
      });
      tagMap['标签'] = genres;
      const status = attrs['status'] as string ?? '';
      tagMap['状态'] = [status];

      // 章节 feed
      const chaptersJson: Record<string, Object> = await this.fetchChapters(id);

      const detailsInput: Record<string, Object> = {
        'title': title,
        'cover': cover,
        'description': description,
        'tags': tagMap,
        'chapters': chaptersJson,
        'comicId': id
      };
      const details = new ComicDetails(this.key, detailsInput);
      return comic_Res.success(details);
    } catch (e) {
      return comic_Res.fail<ComicDetails>(`${e}`);
    }
  }

  /** 拉取全部章节, 按语言分组 */
  private async fetchChapters(id: string): Promise<Record<string, Object>> {
    const grouped: Record<string, Object> = {};
    let offset = 0;
    const limit = 500;
    for (let guard = 0; guard < 20; guard++) {
      const url = `${API}/manga/${id}/feed?limit=${limit}&offset=${offset}&order%5Bchapter%5D=asc&order%5BupdatedAt%5D=asc`;
      const resp = await httpClient.rawRequest({
        url: url,
        method: HttpMethod.GET,
        headers: { 'Accept': 'application/json' }
      });
      if (resp.status !== 200) {
        break;
      }
      const data = JSON.parse(resp.body) as Json;
      const items = data['data'] as Object[] ?? [];
      items.forEach((it) => {
        const v = it as Json;
        const cid = v['id'] as string;
        const cattrs = v['attributes'] as Json;
        const chapterNum = cattrs['chapter'] as string ?? '';
        const chTitle = cattrs['title'] as string ?? '';
        const lang = cattrs['translatedLanguage'] as string ?? 'und';
        const display = chapterNum.length > 0 ? `${chapterNum}: ${chTitle}` : chTitle;
        const groupName = lang;
        let group = grouped[groupName] as Record<string, Object>;
        if (!group) {
          const g: Record<string, Object> = {};
          grouped[groupName] = g;
          group = g;
        }
        group[cid] = display;
      });
      const total = data['total'] as number ?? 0;
      offset += limit;
      if (offset >= total) {
        break;
      }
    }
    return grouped;
  }

  async loadComicPages(id: string, ep: string): Promise<comic_Res<ComicPagesResult>> {
    try {
      // MangaDex: 用章节 id 获取 at-home server
      const resp = await httpClient.rawRequest({
        url: `${API}/at-home/server/${ep}`,
        method: HttpMethod.GET,
        headers: { 'Accept': 'application/json' }
      });
      if (resp.status !== 200) {
        return comic_Res.fail<ComicPagesResult>(`HTTP ${resp.status}`);
      }
      const data = JSON.parse(resp.body) as Json;
      const baseUrl = data['baseUrl'] as string ?? '';
      const chapter = data['chapter'] as Json;
      const hash = chapter['hash'] as string ?? '';
      const files = chapter['dataSaver'] as Object[] ?? [];
      const images: string[] = [];
      files.forEach((f) => {
        images.push(`${baseUrl}/data-saver/${hash}/${f}`);
      });
      const result: ComicPagesResult = { images: images };
      return comic_Res.success(result);
    } catch (e) {
      return comic_Res.fail<ComicPagesResult>(`${e}`);
    }
  }
}

/** 注册真实源 */
export function registerMangaDexSource(): void {
  if (comicSourceManager.find('manga_dex') == null) {
    comicSourceManager.add(new MangaDexSource());
  }
}