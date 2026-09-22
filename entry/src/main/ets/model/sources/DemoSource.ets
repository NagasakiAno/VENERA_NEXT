/**
 * VeneraNext 内置示例漫画源(DemoSource)
 * 演示如何用 ArkTS + HttpClient 实现网络漫画源。
 * 使用说明: 该源对接一个公开的 JSON API 以便上手验证网络链路。
 * 实际漫画源(如鸡盒子/禁漫等)需按其站点 HTML/接口结构调整, 见 ComicSourceProtocol 契约。
 */
import { HttpClient, HttpMethod, ResponseType } from '../../network/HttpClient';
import { comic_Res } from '../../utils/Res';
import { comicSourceManager, SearchResult, ComicSourceProtocol, ComicPagesResult } from '../ComicSource';
import { Comic, ComicDetails } from '../ComicModels';

/**
 * 示例源: 对接一个演示漫画列表(JSON 结构)
 * 这里用固定的示例数据而非真实站点, 以保证无外部依赖即可运行。
 */
export class DemoSource implements ComicSourceProtocol {
  readonly key: string = 'venera_demo';
  readonly name: string = 'Venera 示例源';
  readonly version: string = '1.0.0';

  private client: HttpClient = HttpClient.getInstance();

  // ---- 运行时能力(示例源无需持久化, 空实现) ----
  loadData(key: string): string {
    return '';
  }

  saveData(key: string, value: string): void {
  }

  deleteData(key: string): void {
  }

  loadSetting(key: string, defaultValue: string): string {
    return defaultValue;
  }

  // 本地示例数据(避免依赖外部服务导致演示时联调失败)
  private demoLibrary: DemoComic[] = [
    {
      id: '1001', title: '星海旅人', cover: '', author: '示例作者',
      chapters: [
        { ep: 'c1', name: '第一章 启程' },
        { ep: 'c2', name: '第二章 未知领域' },
        { ep: 'c3', name: '第三章 重逢' }
      ]
    },
    {
      id: '1002', title: '机械之梦', cover: '', author: '示例作者',
      chapters: [
        { ep: 'c1', name: '序章' },
        { ep: 'c2', name: '觉醒' }
      ]
    },
    {
      id: '1003', title: '云端花园', cover: '', author: '示例作者',
      chapters: [
        { ep: 'c1', name: '第一章' }
      ]
    }
  ];

  async loadExplore(page: number): Promise<comic_Res<SearchResult>> {
    return this.buildResult(this.demoLibrary);
  }

  async search(keyword: string, page: number): Promise<comic_Res<SearchResult>> {
    const kw = keyword.trim();
    const filtered = this.demoLibrary.filter((c) => c.title.includes(kw));
    return this.buildResult(filtered);
  }

  async loadComicInfo(id: string): Promise<comic_Res<ComicDetails>> {
    const comic = this.demoLibrary.find((c) => c.id === id);
    if (!comic) {
      return comic_Res.fail<ComicDetails>(`Comic not found: ${id}`);
    }
    const chapters: Record<string, Object> = {};
    comic.chapters.forEach((ch) => {
      chapters[ch.ep] = ch.name;
    });
    const tags: Record<string, Object> = {};
    tags['作者'] = [comic.author];
    const detailsInput: Record<string, Object> = {
      'title': comic.title,
      'cover': comic.cover,
      'description': `《${comic.title}》是一款由 VeneraNext 示例源提供的演示漫画。`,
      'tags': tags,
      'chapters': chapters,
      'comicId': comic.id
    };
    const details = new ComicDetails(this.key, detailsInput);
    return comic_Res.success(details);
  }

  async loadComicPages(id: string, ep: string): Promise<comic_Res<ComicPagesResult>> {
    // 示例: 返回 3 张占位图(使用网络图片便于验证 Image 加载)
    const pages: string[] = [];
    const base = 'https://picsum.photos/seed/';
    for (let i = 0; i < 3; i++) {
      pages.push(`${base}${id}_${ep}_${i}/600/800`);
    }
    const pagesResult: ComicPagesResult = {
      images: pages
    };
    return comic_Res.success(pagesResult);
  }

  private buildResult(comics: DemoComic[]): comic_Res<SearchResult> {
    const list: Comic[] = [];
    comics.forEach((c) => {
      const input: Record<string, Object> = {
        'title': c.title,
        'cover': c.cover,
        'id': c.id
      };
      list.push(new Comic(this.key, input));
    });
    const searchResult: SearchResult = {
      comics: list,
      maxPage: 1
    };
    return comic_Res.success(searchResult);
  }
}

interface DemoComic {
  id: string;
  title: string;
  cover: string;
  author: string;
  chapters: DemoChapter[];
}

interface DemoChapter {
  ep: string;
  name: string;
  /** 仅作演示 */
  pages?: number;
}

/** 便于外部初始化内置源 */
export function registerBuiltinSources(): void {
  // 默认只注册示例源(防强依赖网络); 需要真实源时在入口调用 registerCopyMangaSource
  if (comicSourceManager.isEmpty()) {
    comicSourceManager.add(new DemoSource());
  }
}