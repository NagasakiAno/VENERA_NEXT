/**
 * VeneraNext JS 漫画源仓库服务
 * 拉取官方 index.json、检查更新; 对应原版 index.json 仓库逻辑
 */
import { HttpClient, HttpResponseData, HttpMethod, ResponseType } from '../network/HttpClient';
import { compareSemVer } from '../model/sources/ComicSourceParser';
import { comicSourceManager } from '../model/ComicSource';

const DEFAULT_LIST_URL = 'https://cdn.jsdelivr.net/gh/venera-app/venera-configs@main/index.json';

/** index.json 数据容器(数组或 {data:[...]}) */
interface RepoIndexData {
  data: Object[];
}

/** index.json 单条目 */
interface RepoIndexItem {
  key?: string;
  name?: string;
  version?: string;
  fileName?: string;
  url?: string;
  description?: string;
}

/** 仓库条目 */
export class RepoSourceEntry {
  key: string;
  name: string;
  version: string;
  fileName: string;
  url: string;
  description: string;

  constructor(key: string, name: string, version: string, fileName: string, url: string, description: string) {
    this.key = key;
    this.name = name;
    this.version = version;
    this.fileName = fileName;
    this.url = url;
    this.description = description;
  }
}

export class JsSourceRepo {
  private static instance: JsSourceRepo = new JsSourceRepo();

  static getInstance(): JsSourceRepo {
    return JsSourceRepo.instance;
  }

  defaultListUrl(): string {
    return DEFAULT_LIST_URL;
  }

  /** 解析 index.json 文本为仓库条目 */
  parseIndex(json: string): RepoSourceEntry[] {
    const out: RepoSourceEntry[] = [];
    try {
      // index.json 可能是数组或 {data: [...]}
      const arr: Object = JSON.parse(json);
      let list: Object[] = [];
      if (Array.isArray(arr)) {
        list = arr as Object[];
      } else {
        const obj = arr as RepoIndexData;
        list = obj.data;
      }
      if (!list) {
        return out;
      }
      for (let i = 0; i < list.length; i++) {
        const it = list[i] as RepoIndexItem;
        out.push(new RepoSourceEntry(
          String(it.key ?? ''),
          String(it.name ?? ''),
          String(it.version ?? ''),
          String(it.fileName ?? ''),
          String(it.url ?? ''),
          String(it.description ?? '')
        ));
      }
    } catch (e) {
      // 解析失败返回空
    }
    return out;
  }

  /** 拉取 index.json 列表(禁缓存) */
  async fetchIndexList(listUrl: string): Promise<RepoSourceEntry[]> {
    try {
      const resp: HttpResponseData = await HttpClient.getInstance().rawRequest({
        url: listUrl,
        method: HttpMethod.GET,
        responseType: ResponseType.TEXT,
        headers: { 'Cache-Control': 'no-cache' }
      });
      if (resp.status >= 200 && resp.status < 300 && resp.body.length > 0) {
        return this.parseIndex(resp.body);
      }
      return [];
    } catch (e) {
      return [];
    }
  }

  /**
   * 检查对比仓库版本与已装源版本
   * @returns 有新版的 [(仓库条目, 已装源 key)]
   */
  checkUpdates(list: RepoSourceEntry[]): RepoSourceEntry[] {
    const out: RepoSourceEntry[] = [];
    for (let i = 0; i < list.length; i++) {
      const repo = list[i];
      const installed = comicSourceManager.findJsSource(repo.key);
      if (installed !== null && compareSemVer(repo.version, installed.version) > 0) {
        out.push(repo);
      }
    }
    return out;
  }
}

export const jsSourceRepo = JsSourceRepo.getInstance();