/**
 * VeneraNext 网络收藏同步服务
 *
 * 对应原版 network_favorites_page.dart + favorite_actions.dart 的 importNetworkFolder:
 *   1. 浏览网络源账户收藏(收藏夹列表/收藏列表, loadComics 分页 或 loadNext 游标)
 *   2. 同步网络收藏夹到本地收藏(增量去重, 关联 syncSourceKey/syncSourceFolder)
 *   3. 收藏/取消收藏(favorites.addOrDelFavorite)
 * 全部调用经 jsRuntime.retryZone: 错误含 "Login expired" 时自动 reLogin 并重试一次。
 */
import { hilog } from '@kit.PerformanceAnalysisKit';
import { Comic } from '../model/ComicModels';
import { comicSourceManager } from '../model/ComicSource';
import { ComicSourceMeta, FavoriteMeta } from '../model/sources/ComicSourceMeta';
import { jsRuntime } from '../runtime/JsRuntime';
import { localFavoritesStore, FavoriteItem } from '../model/LocalFavoritesStore';
import { ShelfSourceType } from '../model/ShelfItem';
import { asStr, asNum, asArray } from './ExploreService';

const DOMAIN = 0x0000;
const TAG = 'NetworkFavoritesService';

/** 网络收藏夹 */
export class NetworkFavoriteFolder {
  id: string = '';
  name: string = '';

  constructor(id: string, name: string) {
    this.id = id;
    this.name = name;
  }
}

/** 一次收藏列表加载结果 */
export class NetworkFavoriteBatch {
  comics: Comic[] = [];
  maxPage: number = 1;
  next: string = '';

  isEmpty(): boolean {
    return this.comics.length === 0;
  }
}

/** 同步结果 */
export class NetworkSyncResult {
  /** 新增到本地的数量 */
  imported: number = 0;
  /** 服务端返回的总数 */
  received: number = 0;
  /** 请求页数 */
  pages: number = 0;
  /** 本地文件夹名 */
  folderName: string = '';
}

/** 同步进度回调(已导入数, 已请求页数, 已接收数) */
export type SyncProgressCallback = (imported: number, pages: number, received: number) => void;

export class NetworkFavoritesService {
  private static instance: NetworkFavoritesService = new NetworkFavoritesService();

  static getInstance(): NetworkFavoritesService {
    return NetworkFavoritesService.instance;
  }

  /** 已登录且有网络收藏能力的源列表 */
  availableSources(): ComicSourceMeta[] {
    const out: ComicSourceMeta[] = [];
    const metas = comicSourceManager.allJsSources();
    for (let i = 0; i < metas.length; i++) {
      if (metas[i].favorite.hasAny() && jsRuntime.isLogged(metas[i].key)) {
        out.push(metas[i]);
      }
    }
    return out;
  }

  /**
   * 已登录源列表(先懒加载解析收藏能力再过滤)。
   * 源的 favorite 能力默认为空, 必须先 enrichFavorites 才能被 availableSources 选中。
   */
  async availableSourcesWithEnrich(): Promise<ComicSourceMeta[]> {
    const metas = comicSourceManager.allJsSources();
    for (let i = 0; i < metas.length; i++) {
      if (jsRuntime.isLogged(metas[i].key) && !metas[i].favorite.hasAny()) {
        try {
          await this.ensureCapabilities(metas[i].key);
        } catch (e) {
          hilog.warn(DOMAIN, TAG, '源 %{public}s 收藏能力解析失败: %{public}s', metas[i].key, `${e}`);
        }
      }
    }
    return this.availableSources();
  }

  /** 确保源的收藏能力已解析(懒加载), 返回能力描述 */
  async ensureCapabilities(key: string): Promise<FavoriteMeta> {
    const meta = comicSourceManager.findJsSource(key);
    if (meta === null) {
      throw new Error('源不存在: ' + key);
    }
    if (!meta.favorite.hasAny()) {
      await jsRuntime.enrichFavorites(meta);
    }
    return meta.favorite;
  }

  /**
   * 加载收藏夹列表(favorites.loadFolders)。
   * 兼容两种返回: 新格式 {folders: {id: name}, favorited: [id]}; 旧源直接返回 Map<id, name>。
   */
  async loadFolders(key: string, comicId: string = ''): Promise<NetworkFavoriteFolder[]> {
    const json = await jsRuntime.callFavoriteLoadFolders(key, comicId);
    let parsed: Object;
    try {
      parsed = JSON.parse(json) as Object;
    } catch (e) {
      hilog.warn(DOMAIN, TAG, '收藏夹结果无法解析: %{public}s', `${e}`);
      return [];
    }
    const out: NetworkFavoriteFolder[] = [];
    if (parsed === null || parsed === undefined) {
      return out;
    }
    const rec = parsed as Record<string, Object>;
    let foldersField: Object | undefined = rec['folders'];
    if (foldersField === null || foldersField === undefined) {
      // 旧源直接返回 Map<id, name>
      foldersField = parsed;
    }
    const folderRec = foldersField as Record<string, Object>;
    const ids = Object.keys(folderRec);
    for (let i = 0; i < ids.length; i++) {
      const name = asStr(folderRec[ids[i]]);
      if (ids[i].length > 0 && name.length > 0) {
        out.push(new NetworkFavoriteFolder(ids[i], name));
      }
    }
    hilog.info(DOMAIN, TAG, '源 %{public}s 收藏夹 %{public}d 个', key, out.length);
    return out;
  }

  /** 分页加载收藏列表(favorites.loadComics) */
  async loadComicsPage(key: string, page: number, folderId: string): Promise<NetworkFavoriteBatch> {
    const json = await jsRuntime.callFavoriteLoadComics(key, page, folderId);
    return this.parseBatch(json, key);
  }

  /** 游标加载收藏列表(favorites.loadNext) */
  async loadComicsNext(key: string, next: string, folderId: string): Promise<NetworkFavoriteBatch> {
    const json = await jsRuntime.callFavoriteLoadNext(key, next, folderId);
    return this.parseBatch(json, key);
  }

  /** 解析 {comics, maxPage} / {comics, next} 结构 */
  private parseBatch(json: string, key: string): NetworkFavoriteBatch {
    const batch = new NetworkFavoriteBatch();
    let parsed: Object;
    try {
      parsed = JSON.parse(json) as Object;
    } catch (e) {
      hilog.warn(DOMAIN, TAG, '收藏列表无法解析: %{public}s', `${e}`);
      return batch;
    }
    if (parsed === null || parsed === undefined) {
      return batch;
    }
    const rec = parsed as Record<string, Object>;
    const comicsField = rec['comics'];
    if (comicsField !== null && comicsField !== undefined) {
      const arr = asArray(comicsField);
      for (let i = 0; i < arr.length; i++) {
        const item = arr[i] as Record<string, Object>;
        if (item) {
          batch.comics.push(new Comic(key, item));
        }
      }
    }
    batch.maxPage = asNum(rec['maxPage'], 1);
    batch.next = asStr(rec['next']);
    return batch;
  }

  /** 添加/取消网络收藏 */
  async addOrDelFavorite(key: string, comicId: string, folderId: string,
                         isAdding: boolean, favId: string): Promise<void> {
    await jsRuntime.callFavoriteAddOrDel(key, comicId, folderId, isAdding, favId);
    hilog.info(DOMAIN, TAG, '源 %{public}s 收藏操作: %{public}s isAdding=%{public}s',
      key, comicId, String(isAdding));
  }

  /**
   * 同步网络收藏夹到本地(对应原版 importNetworkFolder):
   *   1. 确定本地文件夹: 已关联(syncSourceKey/syncSourceFolder)则复用;
   *      否则新建(名称=网络收藏夹名或源名)并关联;
   *      同名但未关联的文件夹视为冲突, 抛错。
   *   2. 分页拉取: loadComics(从第 1 页; isOldToNewSort 时从 maxPage-maxPages+1 页起)
   *      或 loadNext(游标), 每页经 addComic 去重写入。
   *
   * @param key        源 key
   * @param folderId   网络收藏夹 ID(非多文件夹源传空串)
   * @param folderName 网络收藏夹名(多文件夹源用于本地命名, 可空)
   * @param maxPages   最多拉取页数
   * @param onProgress 进度回调
   */
  async syncFolderToLocal(key: string, folderId: string, folderName: string,
                          maxPages: number, onProgress: SyncProgressCallback): Promise<NetworkSyncResult> {
    const meta = comicSourceManager.findJsSource(key);
    if (meta === null) {
      throw new Error('源不存在: ' + key);
    }
    const fav = await this.ensureCapabilities(key);
    if (!fav.hasLoadComics && !fav.hasLoadNext) {
      throw new Error('该源不支持加载网络收藏列表');
    }

    // 1. 解析本地文件夹
    const resultName = this.resolveLocalFolderName(key, folderId, folderName, meta.name);
    const result = new NetworkSyncResult();
    result.folderName = resultName;

    // 2. 分页拉取
    const isOldToNew = fav.isOldToNewSort;
    let page = 1;
    let next = '';
    if (fav.hasLoadComics && isOldToNew) {
      // 从旧到新: 先取第 1 页拿 maxPage, 从尾部开始拉最新的
      const first = await this.loadComicsPage(key, 1, folderId);
      result.pages++;
      page = Math.max(1, first.maxPage - maxPages + 1);
    }
    let finished = false;
    while (!finished && result.pages < maxPages) {
      let batch: NetworkFavoriteBatch;
      if (fav.hasLoadComics) {
        batch = await this.loadComicsPage(key, page, folderId);
      } else {
        batch = await this.loadComicsNext(key, next, folderId);
      }
      result.pages++;
      result.received += batch.comics.length;
      for (let i = 0; i < batch.comics.length; i++) {
        const c = batch.comics[i];
        const item = new FavoriteItem(
          c.id, c.title, c.subtitle, c.cover, c.tags,
          Date.now(), 0,
          ShelfSourceType.WEB, key, c.id
        );
        // addComic 内部按 id 去重, 返回 false 表示已存在
        if (localFavoritesStore.addComic(resultName, item)) {
          result.imported++;
        }
      }
      onProgress(result.imported, result.pages, result.received);
      if (fav.hasLoadComics) {
        if (batch.isEmpty() || batch.maxPage === page) {
          finished = true;
        } else {
          page++;
        }
      } else {
        if (batch.isEmpty() || batch.next.length === 0) {
          finished = true;
        } else {
          next = batch.next;
        }
      }
    }
    hilog.info(DOMAIN, TAG, '同步完成: %{public}s 新增 %{public}d, 接收 %{public}d, %{public}d 页',
      resultName, result.imported, result.received, result.pages);
    return result;
  }

  /**
   * 本地文件夹命名与冲突检查(对应原版逻辑):
   * 名称 = 源名 + 网络收藏夹名(多文件夹源) 或 源名(单文件夹源);
   * 已存在且未关联 → 冲突; 已关联 → 复用; 不存在 → 创建并关联。
   */
  private resolveLocalFolderName(key: string, folderId: string,
                                 folderName: string, sourceName: string): string {
    const fid = folderId.length === 0 ? '' : folderId;
    // 多文件夹源: 文件夹名加源名前缀, 避免不同源的 "全部" 等同名文件夹混淆
    const resultName = folderName.length > 0 ? `${sourceName} - ${folderName}` : sourceName;
    const existing = localFavoritesStore.getFolder(resultName);
    if (existing === null) {
      localFavoritesStore.createFolder(resultName);
      localFavoritesStore.linkFolderToNetwork(resultName, key, fid);
      return resultName;
    }
    if (existing.syncSourceKey === key && existing.syncSourceFolder === fid) {
      return resultName;
    }
    throw new Error('文件夹"' + resultName + '"已存在且未关联该网络收藏夹');
  }
}

/** 全局单例 */
export const networkFavoritesService = NetworkFavoritesService.getInstance();
