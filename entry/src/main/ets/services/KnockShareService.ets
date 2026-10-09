/**
 * VeneraNext 碰一碰分享服务
 *
 * 基于 HarmonyOS Share Kit (API 12+):
 * - 发送端: 详情页注册碰一碰监听, 碰一碰时通过 SharableTarget.share() 发送数据
 * - 接收端: 系统通知用户, 用户确认后通过系统分享面板接收数据
 *
 * 分享数据格式 (使用 HYPERLINK UTD 类型, content 为 JSON):
 * - WEB源: { type: 'web', sourceKey, comicId, title, cover, author, description, tags }
 * - 本地源: { type: 'local', title, cover, author, description, tags, fileFormat, fileSize }
 *
 * 注意:
 * - 碰一碰分享需要 NFC + 蓝牙硬件支持, 且两台设备都需开启华为分享服务
 * - 宿主应用无法获得分享结果, Share Kit 会通过系统通知消息告知用户对端接收或拒绝
 * - 当前仅支持手机碰手机, 需 HarmonyOS NEXT 5.0.0.102 SP6 及以上版本
 */
import { harmonyShare, systemShare } from '@kit.ShareKit';
import { uniformTypeDescriptor as utd } from '@kit.ArkData';
import { common } from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { localFavoritesStore, FavoriteItem } from '../model/LocalFavoritesStore';
import { ShelfSourceType } from '../model/ShelfItem';

const DOMAIN = 0x0000;
const TAG = 'KnockShareService';

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

class KnockShareService {
  private context: common.Context | null = null;
  private initialized: boolean = false;
  /** 当前准备分享的数据(发送端) */
  private pendingShareData: ReceivedShareData | null = null;
  /** 碰一碰回调引用(用于 off 注销) */
  private knockShareCallback: ((target: harmonyShare.SharableTarget) => void) | null = null;

  /** 初始化 */
  init(context: common.Context): void {
    if (this.initialized) {
      return;
    }
    this.context = context;
    this.initialized = true;
    hilog.info(DOMAIN, TAG, '碰一碰分享服务初始化成功');
  }

  /**
   * 发送端: 注册碰一碰分享监听
   * 在详情页 aboutToAppear 时调用, 碰一碰触发后自动发送数据
   */
  registerShare(data: ReceivedShareData): void {
    this.pendingShareData = data;

    // 先注销旧回调(避免重复注册)
    this.unregisterShare();

    // 注册新的碰一碰回调
    this.knockShareCallback = (target: harmonyShare.SharableTarget): void => {
      hilog.info(DOMAIN, TAG, '碰一碰事件触发, 发送分享数据');
      this.doShare(target);
    };

    try {
      harmonyShare.on('knockShare', this.knockShareCallback);
      hilog.info(DOMAIN, TAG, '碰一碰监听已注册: %{public}s', data.title);
    } catch (e) {
      hilog.error(DOMAIN, TAG, '注册碰一碰监听失败: %{public}s', `${e}`);
    }
  }

  /** 发送端: 注销碰一碰分享监听 */
  unregisterShare(): void {
    if (this.knockShareCallback !== null) {
      try {
        harmonyShare.off('knockShare', this.knockShareCallback);
      } catch (e) {
        // 忽略
      }
      this.knockShareCallback = null;
    }
    this.pendingShareData = null;
  }

  /** 执行分享: 构建 SharedData 并通过 SharableTarget.share() 发送 */
  private doShare(target: harmonyShare.SharableTarget): void {
    if (this.pendingShareData === null) {
      hilog.warn(DOMAIN, TAG, '无分享数据');
      return;
    }

    try {
      const data = this.pendingShareData;
      const jsonStr = JSON.stringify(data);

      // 使用 HYPERLINK UTD 类型, content 为 JSON 字符串
      // 接收端通过系统分享面板接收, 解析 content 中的 JSON 数据
      const shareData = new systemShare.SharedData({
        utd: utd.UniformDataType.HYPERLINK,
        content: jsonStr,
        title: data.title,
        description: data.description.length > 0 ? data.description : 'VeneraNext 漫画分享'
      });

      target.share(shareData);
      hilog.info(DOMAIN, TAG, '分享数据已发送: %{public}s', data.title);
    } catch (e) {
      hilog.error(DOMAIN, TAG, '发送分享数据失败: %{public}s', `${e}`);
    }
  }

  /**
   * 接收端: 处理接收到的分享数据
   * 从系统分享面板接收 HYPERLINK 类型数据, 解析 content 中的 JSON
   */
  handleReceivedData(content: string): boolean {
    try {
      const data = JSON.parse(content) as ReceivedShareData;

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

  /**
   * 接收端: 导入 WEB 源到收藏
   * WEB 源只需 sourceKey + comicId 即可在对方设备上关联到正确的源
   */
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

  /**
   * 接收端: 处理本地源分享
   * 本地源文件包传输较复杂, 当前版本仅记录元信息到收藏
   * 后续可通过蓝牙/Wi-Fi Direct 传输实际文件
   */
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
export const knockShareService = new KnockShareService();
