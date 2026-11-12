/**
 * VeneraNext 分享服务
 *
 * 两条通道:
 * 1. 系统分享面板(Share Kit `systemShare`): 同设备分享给其它 App, 面板里的"华为分享"可跨设备发送
 * 2. 华为分享事件(harmonyShare): 碰一碰 / 隔空传送(Tap to Transfer / 抓取分享) 直接跨设备发送给对端
 *
 * 分享负载格式 (JSON):
 * - WEB源: { type:'web', sourceKey, comicId, title, cover, author, description, tags }
 * - 本地源: { type:'local', title, cover, author, description, tags, fileFormat, fileSize }
 *
 * 负载同时放在两个位置, 保证跨设备不同链路都能取到:
 * - SharedRecord.extraData['vnr']  (Share Kit 自定义扩展数据, 跨设备透传)
 * - SharedRecord.content 里的 URL:  https://veneranext.app/share?d=<base64(JSON)>
 *
 * 接收端: 从 Want 取 SharedData -> importSharedData(), 或从 Want.uri 解析 d= 参数。
 */
import { systemShare, harmonyShare } from '@kit.ShareKit';
import { uniformTypeDescriptor as utd } from '@kit.ArkData';
import { common } from '@kit.AbilityKit';
import { util } from '@kit.ArkTS';
import { fileIo as fs, fileUri } from '@kit.CoreFileKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { localFavoritesStore, FavoriteItem } from '../model/LocalFavoritesStore';
import { ShelfSourceType } from '../model/ShelfItem';

const DOMAIN = 0x0000;
const TAG = 'ShareService';

/** 分享数据类型 */
export enum ShareType {
  WEB = 'web',
  LOCAL = 'local'
}

/** WEB 源分享数据 */
export interface WebShareData {
  type: string;
  sourceKey: string;
  comicId: string;
  title: string;
  cover: string;
  author: string;
  description: string;
  tags: string[];
}

/** 本地源分享数据 */
export interface LocalShareData {
  type: string;
  title: string;
  cover: string;
  author: string;
  description: string;
  tags: string[];
  fileFormat: string;
  fileSize: number;
}

/** 接收到的分享数据 */
export type ReceivedShareData = WebShareData | LocalShareData;

/** 纯文本分享前缀: 目标设备收到的是文本而不是链接, 避免系统用浏览器打开 */
/** 自定义 URL scheme: 华为分享按链接投递, 对端由本应用处理链接完成导入 */
const SHARE_SCHEME_PREFIX = 'veneranext://share?d=';
const SHARE_TEXT_PREFIX = 'VeneraNextShare:';
/** extraData 中负载字段名 */
const EXTRA_KEY = 'vnr';

class ShareService {
  private context: common.Context | null = null;
  private initialized: boolean = false;
  /** 当前页面待分享的数据(碰一碰/隔空传送回调时使用) */
  private currentPayload: ReceivedShareData | null = null;

  /** 初始化 */
  init(context: common.Context): void {
    if (this.initialized) {
      return;
    }
    this.context = context;
    this.initialized = true;
    hilog.info(DOMAIN, TAG, '分享服务初始化成功');
  }

  /** 详情页加载完成/切换时更新当前可分享数据 */
  setCurrentPayload(data: ReceivedShareData): void {
    this.currentPayload = data;
  }

  /** 离开详情页时清空 */
  clearPayload(): void {
    this.currentPayload = null;
  }

  // ------------------------------------------------------------ 编码工具

  private toBase64(text: string): string {
    try {
      const encoder = new util.TextEncoder();
      const bytes = encoder.encodeInto(text);
      return new util.Base64Helper().encodeToStringSync(bytes);
    } catch (e) {
      hilog.error(DOMAIN, TAG, 'base64 编码失败: %{public}s', `${e}`);
      return '';
    }
  }

  private fromBase64(encoded: string): string {
    const bytes = new util.Base64Helper().decodeSync(encoded);
    return new util.TextDecoder().decodeToString(bytes);
  }

  private safeEncode(text: string): string {
    try {
      return encodeURIComponent(text);
    } catch (e) {
      return '';
    }
  }

  private safeDecode(text: string): string {
    try {
      return decodeURIComponent(text);
    } catch (e) {
      return text;
    }
  }

  // ------------------------------------------------------------ 发送

  /**
   * 构造 Share Kit 共享数据(纯文本 + extraData 双通道)
   * 注意: 不要用 HYPERLINK 承载负载 —— 目标设备接受后会把链接交给浏览器打开,
   * 而不是拉起本应用。这里用 PLAIN_TEXT, 让系统按"分享文本"投递到目标应用。
   */
  /** 把分享负载写成沙箱临时文件, 供 Share Kit 作为文件分享 */
  private writePayloadFile(text: string): string {
    try {
      const ctx = this.context;
      if (ctx === null) {
        return '';
      }
      const file = ctx.cacheDir + '/VeneraNext_share_' + Date.now() + '.txt';
      const f = fs.openSync(file, fs.OpenMode.CREATE | fs.OpenMode.WRITE_ONLY | fs.OpenMode.TRUNC);
      fs.writeSync(f.fd, text);
      fs.closeSync(f);
      return file;
    } catch (e) {
      hilog.warn(DOMAIN, TAG, '写入分享临时文件失败: %{public}s', `${e}`);
      return '';
    }
  }

  /**
   * 构造 Share Kit 共享数据
   * 跨设备投递使用文件记录: 接收端应用注册 dataReceive 能力后可把文件直接收进沙箱并自动导入,
   * 避免纯文本被对端保存成 TXT 或链接被浏览器打开。
   */
  /**
   * 构造 Share Kit 共享数据(自定义 scheme 超链接 + extraData 双通道)
   * 关键点: 华为分享面板会把文件/文本落地成本地文件, 但会把 HYPERLINK 当作链接投递;
   * 用 veneranext:// 自定义 scheme, 目标设备解析链接时由本应用接管, 从而拉起应用并自动导入。
   */
  buildSharedData(data: ReceivedShareData): systemShare.SharedData {
    const payloadJson = JSON.stringify(data);
    const link = SHARE_SCHEME_PREFIX + this.safeEncode(this.toBase64(payloadJson));
    const extra: Record<string, string | number | boolean | Array<string | number | boolean>> = {};
    extra[EXTRA_KEY] = payloadJson;
    extra['vnr_v'] = '3';
    const description = data.description.length > 0 ? data.description : 'VeneraNext 漫画分享';
    const record: systemShare.SharedRecord = {
      utd: utd.UniformDataType.HYPERLINK,
      content: link,
      title: data.title,
      description: description,
      extraData: extra
    };
    return new systemShare.SharedData(record);
  }

  /** 接收端: 解析沙箱接收目录中的分享文件并导入, 解析成功后清空目录 */
  importReceivedFiles(dir: string): boolean {
    let ok = false;
    try {
      if (!fs.accessSync(dir)) {
        return false;
      }
      const names = fs.listFileSync(dir);
      for (const name of names) {
        const filePath = dir + '/' + name;
        try {
          const f = fs.openSync(filePath, fs.OpenMode.READ_ONLY);
          const stat = fs.statSync(f.fd);
          const buf = new ArrayBuffer(stat.size);
          fs.readSync(f.fd, buf);
          fs.closeSync(f);
          const content = util.TextDecoder.create('utf-8').decodeToString(new Uint8Array(buf));
          if (this.handleReceivedData(content)) {
            ok = true;
          }
          fs.unlinkSync(filePath);
        } catch (e) {
          hilog.warn(DOMAIN, TAG, '读取接收文件失败: %{public}s', `${e}`);
        }
      }
    } catch (e) {
      hilog.error(DOMAIN, TAG, '导入接收文件失败: %{public}s', `${e}`);
    }
    return ok;
  }

  /**
   * 发送端: 通过系统分享面板分享数据
   * 弹出系统分享面板, 用户可选择华为分享、蓝牙等方式发送
   */
  shareViaSystem(context: common.UIAbilityContext, data: ReceivedShareData): void {
    try {
      const shareData = this.buildSharedData(data);
      const shareController = new systemShare.ShareController(shareData);
      shareController.show(context, {
        previewMode: systemShare.SharePreviewMode.DEFAULT
      }).then(() => {
        hilog.info(DOMAIN, TAG, '分享面板已关闭: %{public}s', data.title);
      }).catch((e: Error) => {
        hilog.error(DOMAIN, TAG, '分享面板异常: %{public}s', `${e}`);
      });
      hilog.info(DOMAIN, TAG, '系统分享面板已弹出: %{public}s', data.title);
    } catch (e) {
      hilog.error(DOMAIN, TAG, '系统分享失败: %{public}s', `${e}`);
    }
  }

  /**
   * 华为分享事件回调(碰一碰 / 隔空传送): 把当前页面的漫画发送到对端设备
   */
  handleSharableTarget(target: harmonyShare.SharableTarget): void {
    const data = this.currentPayload;
    if (data === null) {
      hilog.warn(DOMAIN, TAG, '收到华为分享事件, 但当前没有可分享内容');
      target.reject(harmonyShare.SharableErrorCode.NO_CONTENT_ERROR).catch((e: Error) => {
        hilog.error(DOMAIN, TAG, '拒绝分享失败: %{public}s', `${e}`);
      });
      return;
    }
    try {
      target.share(this.buildSharedData(data)).then(() => {
        hilog.info(DOMAIN, TAG, '华为分享发送完成: %{public}s', data.title);
      }).catch((e: Error) => {
        hilog.error(DOMAIN, TAG, '华为分享发送失败: %{public}s', `${e}`);
      });
    } catch (e) {
      hilog.error(DOMAIN, TAG, '华为分享异常: %{public}s', `${e}`);
    }
  }

  // ------------------------------------------------------------ 接收

  /** 解析 Want 中的 SharedData(Share Kit 透传的分享记录) */
  importSharedData(shared: systemShare.SharedData): boolean {
    let ok = false;
    try {
      const records = shared.getRecords();
      hilog.info(DOMAIN, TAG, '收到分享记录 %{public}d 条', records.length);
      for (const record of records) {
        hilog.info(DOMAIN, TAG, '分享记录 utd=%{public}s title=%{public}s hasExtra=%{public}s',
          record.utd, record.title ?? '', record.extraData === undefined ? 'false' : 'true');
        // 1. extraData 中的自定义负载(跨设备优先)
        if (record.extraData !== undefined && record.extraData !== null) {
          const raw = record.extraData[EXTRA_KEY];
          if (typeof raw === 'string' && this.handleReceivedData(raw as string)) {
            ok = true;
            continue;
          }
        }
        // 2. content 直接是 JSON(兼容旧版分享)
        const content = record.content ?? '';
        if (content.length > 0) {
          if (this.handleReceivedData(content)) {
            ok = true;
            continue;
          }
          // 3. content 是携带负载的链接
          if (this.handleShareLink(content)) {
            ok = true;
          }
        }
      }
    } catch (e) {
      hilog.error(DOMAIN, TAG, '解析分享记录失败: %{public}s', `${e}`);
    }
    return ok;
  }

  /** 从分享链接(或任意带 d= 参数的 URI)中解析负载 */
  handleShareLink(link: string): boolean {
    if (link.length === 0) {
      return false;
    }
    const marker = 'd=';
    const idx = link.indexOf(marker);
    if (idx < 0) {
      return false;
    }
    let encoded = link.substring(idx + marker.length);
    const amp = encoded.indexOf('&');
    if (amp >= 0) {
      encoded = encoded.substring(0, amp);
    }
    try {
      const json = this.fromBase64(this.safeDecode(encoded));
      return this.handleReceivedData(json);
    } catch (e) {
      hilog.warn(DOMAIN, TAG, '链接负载解析失败: %{public}s', `${e}`);
      return false;
    }
  }

  /** 处理接收到的分享负载(纯文本前缀 / 直接 JSON) */
  handleReceivedData(content: string): boolean {
    try {
      let text = content.trim();
      // 纯文本分享: VeneraNextShare:<base64(JSON)>
      if (text.indexOf(SHARE_TEXT_PREFIX) === 0) {
        text = this.fromBase64(text.substring(SHARE_TEXT_PREFIX.length));
      }
      const data = JSON.parse(text) as ReceivedShareData;

      if (data.type === ShareType.WEB) {
        this.importWebFavorite(data as WebShareData);
        return true;
      } else if (data.type === ShareType.LOCAL) {
        this.handleLocalShare(data as LocalShareData);
        return true;
      }

      hilog.warn(DOMAIN, TAG, '未知的分享数据类型: %{public}s', data.type);
      return false;
    } catch (e) {
      hilog.error(DOMAIN, TAG, '处理分享数据失败: %{public}s', `${e}`);
      return false;
    }
  }

  /** 接收端: 导入 WEB 源到收藏 */
  private importWebFavorite(data: WebShareData): void {
    const favItem = new FavoriteItem(
      `web_${data.sourceKey}_${data.comicId}`,
      data.title,
      data.author,
      data.cover,
      data.tags,
      Date.now(),
      0,
      ShelfSourceType.WEB,
      data.sourceKey,
      data.comicId
    );
    localFavoritesStore.addComic('收藏', favItem);
    hilog.info(DOMAIN, TAG, 'WEB 源已导入收藏: %{public}s', data.title);
  }

  /** 接收端: 本地源分享(仅记录元信息) */
  private handleLocalShare(data: LocalShareData): void {
    const favItem = new FavoriteItem(
      `local_${Date.now()}`,
      data.title,
      data.author,
      data.cover,
      data.tags,
      Date.now(),
      0,
      ShelfSourceType.LOCAL,
      '',
      ''
    );
    localFavoritesStore.addComic('收藏', favItem);
    hilog.info(DOMAIN, TAG, '本地源信息已记录(文件传输暂不支持): %{public}s', data.title);
  }
}

/** 全局单例 */
export const shareService = new ShareService();
