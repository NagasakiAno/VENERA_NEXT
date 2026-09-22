/**
 * VeneraNext 漫画条目数据模型
 * 对应 Flutter 版 foundation/comic_source/models.dart 中的基础字段
 */

/** 漫画条目 */
export interface ComicItem {
  /** 漫画ID */
  comicId: string;
  /** 来源 key */
  sourceKey: string;
  /** 标题 */
  title: string;
  /** 封面地址 */
  coverUrl: string;
  /** 作者(可为空) */
  author?: string;
  /** 简介 */
  description?: string;
  /** 最近打开时间戳(ms), 用于书架排序 */
  lastReadTime: number;
  /** 是否收藏 */
  isFavorite: boolean;
}

/** 章节信息 */
export interface EpisodeInfo {
  /** 章节名 */
  name: string;
  /** 章节ID */
  episodeId: string;
  /** 是否已付费/锁定 */
  paid: boolean;
}

/** 书架分组类型 */
export enum ShelfType {
  /** 全部 */
  ALL = 0,
  /** 收藏 */
  FAVORITE = 1,
  /** 最近阅读 */
  RECENT = 2
}