/**
 * VeneraNext 拷贝漫画(CopyManga) 真实源
 * 对应 venera-configs/copy_manga.js, 用 ArkTS 原生实现
 * 核心: HMAC-SHA256 签名 headers, JSON API, 分组章节, 图片按 words 重排
 */
import { httpClient, HttpMethod, ResponseType } from '../../network/HttpClient';
import { comic_Res } from '../../utils/Res';
import { BaseComicSource, comicSourceManager, SearchResult, ComicPagesResult } from '../ComicSource';
import { Comic, ComicDetails } from '../ComicModels';
import { decodeBase64, encodeUtf8, hmacString } from '../../utils/Convert';
import { hilog } from '@kit.PerformanceAnalysisKit';

const DOMAIN = 0x0000;
const TAG = 'CopyMangaSource';
const SECRET = 'M2FmMDg1OTAzMTEwMzJlZmUwNjYwNTUwYTA1NjNhNTM=';

/** JSON 顶层对象类型 */
type Json = Record<string, Object>;

/**
 * 拷贝漫画源
 */
export class CopyMangaSource extends BaseComicSource {
  readonly key: string = 'copy_manga';
  readonly name: string = '拷贝漫画';
  readonly version: string = '1.4.2';

  private apiHost: string = 'api.copy-manga.com';
  private imageQuality: string = '1500';
  private region: string = '1';
  private deviceInfo: string = '';
  private device: string = '';
  private pseudoid: string = '';

  /** 作者名 -> path_word 映射 (由详情加载填充) */
  private authorPathDict: Map<string, string> = new Map<string, string>();

  /** 最近一次 HMAC 异常信息(排错) */
  private lastHmacError: string = '';

  /** 从响应体提取 message 字段(用于展示 210 等提示) */
  private extractMessage(body: string): string {
    try {
      const d = JSON.parse(body) as Json;
      const m = d['message'];
      if (m) {
        return `${m}`;
      }
    } catch (e) {
    }
    return '';
  }

  /** 从 system/network2 动态获取可用 API 主机(对应源脚本 refreshAppApi) */
  private async refreshApiHost(): Promise<void> {
    try {
      const resp = await httpClient.rawRequest({
        url: 'https://api.copy-manga.com/api/v3/system/network2?platform=3',
        method: HttpMethod.GET,
        headers: { 'User-Agent': 'COPY/3.0.6', 'Accept': 'application/json' }
      });
      if (resp.status === 200 && resp.body.length > 0) {
        const data = JSON.parse(resp.body) as Json;
        const results = data['results'] as Json;
        const apiList = results['api'];
        // 注意: network2 返回的 api 主机常为反爬诱导(如 t66y.com), 不可直接采用。
        // 仅当返回的是 copy-manga 系域名时才采纳, 否则保持默认。
        if (Array.isArray(apiList) && (apiList as Object[]).length > 0) {
          const first = (apiList as Object[])[0] as Object[];
          if (first && first.length > 0) {
            const host = `${first[0]}`;
            if (host.length > 0 && this.isValidApiHost(host)) {
              this.apiHost = host;
              hilog.info(DOMAIN, TAG, 'refreshed apiHost=%{public}s', this.apiHost);
            }
          }
        }
      }
    } catch (e) {
      // 失败则沿用默认 host
    }
  }

  /** 校验 API 主机是否可信(copy-manga 系), 防止采用反爬诱导域名 */
  private isValidApiHost(host: string): boolean {
    return host.indexOf('copy-manga') >= 0 || host.indexOf('copy2000') >= 0
      || host.indexOf('copymanga') >= 0;
  }

  loadSetting(key: string, defaultValue: string): string {
    switch (key) {
      case 'base_url':
        return this.apiHost;
      case 'image_quality':
        return this.imageQuality;
      case 'region':
        return this.region;
      default:
        return defaultValue;
    }
  }

  /** 生成 reqId(某些接口需要) */
  private async getReqId(): Promise<string> {
    if (this.region === '0') {
      return '';
    }
    try {
      const resp = await httpClient.rawRequest({
        url: 'https://marketing.aiacgn.com/api/v2/adopr/query3/?format=json&ident=200100001',
        method: HttpMethod.GET,
        headers: {
          'User-Agent': 'COPY/3.0.6',
          'Accept': 'application/json'
        }
      });
      if (resp.status === 200 && resp.body.length > 0) {
        const data = JSON.parse(resp.body) as Json;
        const results = data['results'] as Json;
        if (results && results['request_id']) {
          return results['request_id'] as string;
        }
      }
    } catch (e) {
      hilog.warn(DOMAIN, TAG, 'getReqId failed: %{public}s', `${e}`);
    }
    return '';
  }

  /** 构建头像签名 headers (HMAC-SHA256) */
  private async buildHeaders(): Promise<Record<string, string>> {
    const now = new Date();
    const year = `${now.getFullYear()}`;
    const month = `${now.getMonth() + 1}`.padStart(2, '0');
    const day = `${now.getDate()}`.padStart(2, '0');
    const ts = `${Math.floor(now.getTime() / 1000)}`;

    const token = this.loadData('token');
    let sig = '';
    try {
      const key = decodeBase64(SECRET);
      const data = encodeUtf8(ts);
      sig = await hmacString(key, data, 'sha256');
      this.lastHmacError = '';
    } catch (e) {
      const er = e as Error;
      this.lastHmacError = er && er.message ? er.message : `${e}`;
      hilog.error(DOMAIN, TAG, 'hmac failed: %{public}s', this.lastHmacError);
    }

    const headers: Record<string, string> = {
      'User-Agent': 'COPY/3.0.6',
      'source': 'copyApp',
      'deviceinfo': this.deviceInfo,
      'dt': `${year}.${month}.${day}`,
      'platform': '3',
      'referer': 'com.copymanga.app-3.0.6',
      'version': '3.0.6',
      'device': this.device,
      'pseudoid': this.pseudoid,
      'Accept': 'application/json',
      'region': this.region,
      'authorization': `Token${token}`,
      'umstring': 'b4c89ca4104ea9a97750314d791520ac',
      'x-auth-timestamp': ts,
      'x-auth-signature': sig
    };
    return headers;
  }

  /** 懒初始化设备标识 */
  private ensureDeviceInfo(): void {
    if (this.deviceInfo.length > 0) {
      return;
    }
    let info = this.loadData('_deviceinfo');
    if (info.length === 0) {
      info = this.generateDeviceInfo();
      this.saveData('_deviceinfo', info);
    }
    let dev = this.loadData('_device');
    if (dev.length === 0) {
      dev = this.generateDevice();
      this.saveData('_device', dev);
    }
    let pid = this.loadData('_pseudoid');
    if (pid.length === 0) {
      pid = this.generatePseudoid();
      this.saveData('_pseudoid', pid);
    }
    this.deviceInfo = info;
    this.device = dev;
    this.pseudoid = pid;
  }

  private randomInt(min: number, max: number): number {
    return Math.floor(Math.random() * (max - min + 1)) + min;
  }

  private generateDeviceInfo(): string {
    return `${this.randomInt(1000000, 9999999)}V-${this.randomInt(1000, 9999)}`;
  }

  private generateDevice(): string {
    const charA = () => String.fromCharCode(65 + this.randomInt(0, 25));
    const digit = () => String.fromCharCode(48 + this.randomInt(0, 9));
    return `${charA()}${charA()}${digit()}${charA()}.${digit()}${digit()}${digit()}${digit()}${digit()}${digit()}.${digit()}${digit()}${digit()}`;
  }

  private generatePseudoid(): string {
    const chars = 'abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789';
    let out = '';
    for (let i = 0; i < 16; i++) {
      out += chars.charAt(this.randomInt(0, chars.length - 1));
    }
    return out;
  }

  /** 解析单个漫画(列表/搜索结果项) */
  private parseComic(raw: Json): Comic {
    let comic = raw;
    const c = raw['comic'];
    if (c && typeof c === 'object') {
      comic = c as Json;
    }
    const tags: string[] = [];
    const theme = comic['theme'];
    if (theme && Array.isArray(theme)) {
      (theme as Object[]).forEach((t) => {
        const tt = t as Json;
        if (tt && tt['name']) {
          tags.push(tt['name'] as string);
        }
      });
    }
    let author = '';
    const authors = comic['author'];
    if (authors && Array.isArray(authors) && (authors as Object[]).length > 0) {
      const a0 = (authors as Object[])[0] as Json;
      if (a0 && a0['name']) {
        author = a0['name'] as string;
      }
    }
    const input: Record<string, Object> = {
      'id': comic['path_word'] ?? '',
      'title': comic['name'] ?? '',
      'subtitle': author,
      'cover': comic['cover'] ?? '',
      'tags': tags,
      'description': comic['datetime_updated'] ?? ''
    };
    return new Comic(this.key, input);
  }

  /** 从 list 数据构造搜索结果(包含 maxPage 计算) */
  private buildResultFromList(body: string): comic_Res<SearchResult> {
    const data = JSON.parse(body) as Json;
    const results = data['results'] as Json;
    if (!results) {
      return comic_Res.fail<SearchResult>('Invalid results');
    }
    const list = results['list'];
    const comics: Comic[] = [];
    if (Array.isArray(list)) {
      (list as Object[]).forEach((item) => {
        const v = item as Json;
        if (v && v['path_word'] !== null && v !== undefined) {
          comics.push(this.parseComic(v));
        }
      });
    }
    const total = (results['total'] as number) ?? 0;
    const maxPage = Math.floor((total - (total % 21)) / 21) + 1;
    const result: SearchResult = { comics: comics, maxPage: maxPage };
    return comic_Res.success(result);
  }

  // ---------- 协议实现 ----------

  async loadExplore(page: number): Promise<comic_Res<SearchResult>> {
    this.ensureDeviceInfo();
    await this.refreshApiHost();
    // 候选线路: 当前 host + 备用 host
    const candidates: string[] = [];
    if (this.apiHost.length > 0) {
      candidates.push(this.apiHost);
    }
    candidates.push('api.copy2000.online');
    try {
      const headers = await this.buildHeaders();
      let lastFail = '';
      for (let ci = 0; ci < candidates.length; ci++) {
        const resp = await httpClient.rawRequest({
          url: `https://${candidates[ci]}/api/v3/h5/homeIndex`,
          method: HttpMethod.GET,
          headers: headers
        });
        if (resp.status === 200 && resp.body.length > 0) {
          try {
            const d = JSON.parse(resp.body) as Json;
            const rs = d['results'] as Json;
            if (rs && rs['recComics']) {
              // 命中有效 JSON 数据
              return this.parseHomeData(resp.body);
            }
            lastFail = `[${candidates[ci]}] json-ok-but-no-recComics`;
          } catch (pe) {
            lastFail = `[${candidates[ci]}] ${resp.body}`;
          }
        } else {
          lastFail = `[${candidates[ci]}] status=${resp.status}`;
        }
      }
      // 排错信息: 暴露签名、设备字段与 HMAC 异常
      return comic_Res.fail<SearchResult>(
        `线路均失败: ${lastFail} | sig=${headers['x-auth-signature']} hmacErr=${this.lastHmacError} pid=${this.pseudoid}`);
    } catch (e) {
      return comic_Res.fail<SearchResult>(`${e}`);
    }
  }

  /** 解析首页 JSON 为 Comic 列表 */
  private parseHomeData(body: string): comic_Res<SearchResult> {
    const data = JSON.parse(body) as Json;
    const results = data['results'] as Json;
    const comics: Comic[] = [];
    const sectionKeys = ['recComics', 'hotComics', 'newComics', 'finishComics'];
    sectionKeys.forEach((sec) => {
      let secData = results[sec];
      if (!secData) {
        return;
      }
      let items: Object[] = [];
      if (secData instanceof Array) {
        items = secData as Object[];
      } else {
        const secObj = secData as Json;
        const list = secObj['list'];
        if (Array.isArray(list)) {
          items = list as Object[];
        }
      }
      items.forEach((obj) => {
        const v = obj as Json;
        const comic = v['comic'] ? v['comic'] as Json : v;
        if (comic && comic['path_word']) {
          comics.push(this.parseComic(comic));
        }
      });
    });
    const seen = new Set<string>();
    const unique: Comic[] = [];
    comics.forEach((c) => {
      if (!seen.has(c.id)) {
        seen.add(c.id);
        unique.push(c);
      }
    });
    const result: SearchResult = { comics: unique, maxPage: 1 };
    return comic_Res.success(result);
  }

  async search(keyword: string, page: number): Promise<comic_Res<SearchResult>> {
    this.ensureDeviceInfo();
    try {
      const headers = await this.buildHeaders();
      const q = encodeURIComponent(keyword);
      const url = `https://${this.apiHost}/api/v3/search/comic?limit=30&offset=${(page - 1) * 30}&q=${q}&q_type=`;
      const resp = await httpClient.rawRequest({
        url: url,
        method: HttpMethod.GET,
        headers: headers
      });
      if (resp.status !== 200) {
        return comic_Res.fail<SearchResult>(`Invalid status: ${resp.status}`);
      }
      return this.buildResultFromList(resp.body);
    } catch (e) {
      return comic_Res.fail<SearchResult>(`${e}`);
    }
  }

  async loadComicInfo(id: string): Promise<comic_Res<ComicDetails>> {
    this.ensureDeviceInfo();
    try {
      const headers = await this.buildHeaders();
      const reqId = await this.getReqId();
      const resp = await httpClient.rawRequest({
        url: `https://${this.apiHost}/api/v3/comic2/${id}?in_mainland=true&request_id=${reqId}&platform=3`,
        method: HttpMethod.GET,
        headers: headers,
        timeout: 60000
      });
      if (resp.status !== 200) {
        // 210 为源站反爬/限流提示, 其他为请求异常
        if (resp.status === 210) {
          return comic_Res.fail<ComicDetails>(`访问受限(210): ${this.extractMessage(resp.body)}`);
        }
        return comic_Res.fail<ComicDetails>(`加载失败(status ${resp.status})`);
      }
      const data = JSON.parse(resp.body) as Json;
      const results = data['results'] as Json;
      const comic = results['comic'] as Json;
      const groups = results['groups'] as Json;

      const title = comic['name'] as string ?? '';
      const cover = comic['cover'] as string ?? '';
      const brief = comic['brief'] as string ?? '';

      // 作者 & 标签
      const authors: string[] = [];
      const authorArr = comic['author'];
      if (authorArr && Array.isArray(authorArr)) {
        (authorArr as Object[]).forEach((a) => {
          const aa = a as Json;
          if (aa && aa['name']) {
            authors.push(aa['name'] as string);
            const pw = aa['path_word'];
            if (pw) {
              this.authorPathDict.set(aa['name'] as string, pw as string);
            }
          }
        });
      }
      const tags: string[] = [];
      const theme = comic['theme'];
      if (theme && Array.isArray(theme)) {
        (theme as Object[]).forEach((t) => {
          const tt = t as Json;
          const name = tt && tt['name'] ? tt['name'] as string : '';
          if (name.length > 0) {
            tags.push(name);
          }
        });
      }
      const updateTime = comic['datetime_updated'] as string ?? '';
      const status = comic['status'] as Json;
      const statusText = status ? `${status['display'] ?? ''}` : '';

      // 分组章节
      const chaptersJson: Record<string, Object> = {};
      if (groups && typeof groups === 'object') {
        const groupKeys = Object.keys(groups as Record<string, Object>);
        // 并行加载每组章节, 用 Promise.all 逐个 await
        await this.loadAllGroups(id, groups as Json, chaptersJson);
      }

      const tagsMap: Record<string, Object> = {};
      tagsMap['作者'] = authors;
      tagsMap['更新'] = [updateTime];
      tagsMap['标签'] = tags;
      tagsMap['状态'] = [statusText];

      const detailsInput: Record<string, Object> = {
        'title': title,
        'cover': cover,
        'description': brief,
        'tags': tagsMap,
        'chapters': chaptersJson,
        'comicId': id,
        'isFavorite': false,
        'subId': comic['uuid'] ?? ''
      };
      const details = new ComicDetails(this.key, detailsInput);
      return comic_Res.success(details);
    } catch (e) {
      return comic_Res.fail<ComicDetails>(`${e}`);
    }
  }

  /** 并发加载所有分组章节, 结果写入 out */
  private async loadAllGroups(
    id: string,
    groups: Json,
    out: Record<string, Object>
  ): Promise<void> {
    const keys = Object.keys(groups as Record<string, Object>);
    // 串行加载(避免并发过多触发限流)
    for (let i = 0; i < keys.length; i++) {
      const groupKey = keys[i];
      const groupObj = groups[groupKey] as Json;
      if (!groupObj) {
        continue;
      }
      const path = groupObj['path_word'] as string;
      if (!path) {
        continue;
      }
      const groupName = groupObj['name'] as string ?? groupKey;
      const groupChapters = await this.fetchGroupChapters(id, path);
      if (groupChapters.size > 0) {
        // ArkTS Map 转普通对象
        const obj: Record<string, Object> = {};
        groupChapters.forEach((title, epId) => {
          obj[epId] = title;
        });
        out[groupName] = obj;
      }
    }
  }

  /** 获取单分组章节 (分页拉取全部) */
  private async fetchGroupChapters(id: string, path: string): Promise<Map<string, string>> {
    const out = new Map<string, string>();
    const headers = await this.buildHeaders();
    const reqId = await this.getReqId();
    let offset = 0;
    const limit = 100;
    for (;;) {
      const resp = await httpClient.rawRequest({
        url: `https://${this.apiHost}/api/v3/comic/${id}/group/${path}/chapters?limit=${limit}&offset=${offset}&in_mainland=true&request_id=${reqId}`,
        method: HttpMethod.GET,
        headers: headers
      });
      if (resp.status !== 200) {
        break;
      }
      const data = JSON.parse(resp.body) as Json;
      const results = data['results'] as Json;
      if (!results) {
        break;
      }
      const list = results['list'];
      if (Array.isArray(list)) {
        (list as Object[]).forEach((e) => {
          const ee = e as Json;
          if (ee && ee['uuid']) {
            out.set(ee['uuid'] as string, ee['name'] as string ?? '');
          }
        });
      }
      const total = (results['total'] as number) ?? 0;
      offset += limit;
      if (offset >= total) {
        break;
      }
    }
    return out;
  }

  async loadComicPages(id: string, ep: string): Promise<comic_Res<ComicPagesResult>> {
    this.ensureDeviceInfo();
    try {
      const headers = await this.buildHeaders();
      const reqId = await this.getReqId();
      const resp = await httpClient.rawRequest({
        url: `https://${this.apiHost}/api/v3/comic/${id}/chapter2/${ep}?in_mainland=true&request_id=${reqId}`,
        method: HttpMethod.GET,
        headers: headers
      });
      if (resp.status !== 200) {
        // 210 限流时提示
        if (resp.status === 210) {
          return comic_Res.fail<ComicPagesResult>(`访问过于频繁(210)，请稍后重试`);
        }
        return comic_Res.fail<ComicPagesResult>(`Invalid status: ${resp.status}`);
      }
      const data = JSON.parse(resp.body) as Json;
      const chapter = (data['results'] as Json)['chapter'] as Json;
      const contents = chapter['contents'] as Object[] ?? [];
      const words = chapter['words'] as number[] ?? [];
      const urls: string[] = [];
      (contents as Object[]).forEach((c) => {
        const cc = c as Json;
        if (cc && cc['url']) {
          urls.push(cc['url'] as string);
        }
      });
      // 质量替换: 把 c{orig}x.webp 替换为 c{quality}x.webp
      const hdUrls: string[] = urls.map((u) =>
        u.replace(/([./])c\d+x\.[a-zA-Z]+$/, `$1c${this.imageQuality}x.webp`)
      );
      // 按 words 排序
      const images = new Array<string>(hdUrls.length).fill('');
      for (let i = 0; i < hdUrls.length; i++) {
        const order = words[i];
        if (order !== undefined && order !== null && order >= 0 && order < images.length) {
          images[order] = hdUrls[i];
        } else {
          images[i] = hdUrls[i];
        }
      }
      // 去空
      const finalImages: string[] = images.filter((u) => u.length > 0);
      const result: ComicPagesResult = { images: finalImages };
      return comic_Res.success(result);
    } catch (e) {
      return comic_Res.fail<ComicPagesResult>(`${e}`);
    }
  }
}

/** 注册内置真实源 */
export function registerCopyMangaSource(): void {
  if (comicSourceManager.find('copy_manga') == null) {
    comicSourceManager.add(new CopyMangaSource());
  }
}