/**
 * VeneraNext 漫画源数据模型
 * 对应 Flutter 版 foundation/comic_source/models.dart
 */

/** 漫画摘要 (列表/搜索项) */
export class Comic {
  title: string;
  cover: string;
  id: string;
  subtitle: string;
  tags: string[];
  description: string;
  sourceKey: string;
  maxPage: number;
  language: string;
  /**
   * 收藏项 ID(仅当漫画来自网络收藏页时由源返回,
   * 用于 addOrDelFavorite 的 favId 参数)
   */
  favoriteId: string;

  constructor(sourceKey: string, json: Record<string, Object>) {
    this.sourceKey = sourceKey;
    this.title = json['title'] as string ?? '';
    this.subtitle = (json['subtitle'] as string) ?? (json['subTitle'] as string) ?? '';
    this.cover = json['cover'] as string ?? '';
    this.id = json['id'] as string ?? '';
    this.tags = (json['tags'] as string[]) ?? [];
    this.description = json['description'] as string ?? '';
    this.maxPage = json['maxPage'] as number ?? 0;
    this.language = json['language'] as string ?? '';
    this.favoriteId = json['favoriteId'] as string ?? '';
  }

  toString(): string {
    return `${this.sourceKey}@${this.id}`;
  }
}

/** 漫画章节集 */
export class ComicChapters {
  /** 扁平 章节ID->章节名 */
  chapters: Map<string, string>;
  /** 分组结构 分组名->(章节ID->章节名) */
  grouped: Map<string, Map<string, string>>;

  constructor(json: Record<string, Object>) {
    this.chapters = new Map<string, string>();
    this.grouped = new Map<string, Map<string, string>>();
    const keys = Object.keys(json);
    keys.forEach((k: string) => {
      const v = json[k];
      if (typeof v === 'object' && v !== null) {
        const group = new Map<string, string>();
        const sub = v as Record<string, Object>;
        const subKeys = Object.keys(sub);
        subKeys.forEach((k2: string) => {
          group.set(k2, `${sub[k2]}`);
        });
        this.grouped.set(k, group);
      } else {
        this.chapters.set(k, `${v}`);
      }
    });
  }

  static fromJson(json: Record<string, Object>): ComicChapters {
    return new ComicChapters(json);
  }

  /** 是否为分组结构 */
  isGrouped(): boolean {
    return this.grouped.size > 0;
  }

  /** 全部章节 (含分组展开) */
  allChapters(): Map<string, string> {
    if (!this.isGrouped()) {
      return this.chapters;
    }
    const res = new Map<string, string>();
    this.grouped.forEach((group) => {
      group.forEach((title, id) => {
        res.set(id, title);
      });
    });
    return res;
  }

  /** 总章节数 */
  length(): number {
    if (this.isGrouped()) {
      let n = 0;
      this.grouped.forEach((g) => { n += g.size; });
      return n;
    }
    return this.chapters.size;
  }
}

/** 漫画详情 */
export class ComicDetails {
  title: string;
  subtitle: string;
  cover: string;
  description: string;
  /** 命名空间 -> 标签列表 */
  tags: Map<string, string[]>;
  chapters: ComicChapters | null;
  thumbnails: string[];
  sourceKey: string;
  comicId: string;
  isFavorite: boolean;
  updateTime: string;
  /** 相关推荐(源返回的 Comic[]) */
  recommend: Comic[];
  uploader: string;
  likesCount: number;

  constructor(sourceKey: string, json: Record<string, Object>) {
    this.sourceKey = sourceKey;
    this.title = json['title'] as string ?? '';
    this.subtitle = json['subtitle'] as string ?? '';
    this.cover = json['cover'] as string ?? '';
    this.description = json['description'] as string ?? '';
    this.tags = new Map<string, string[]>();
    const t = json['tags'];
    if (t && typeof t === 'object') {
      const tagRecord = t as Record<string, Object>;
      Object.keys(tagRecord).forEach((k: string) => {
        this.tags.set(k, tagRecord[k] as string[] ?? []);
      });
    }
    const ch = json['chapters'];
    this.chapters = ch ? ComicChapters.fromJson(ch as Record<string, Object>) : null;
    this.thumbnails = json['thumbnails'] as string[] ?? [];
    this.comicId = json['comicId'] as string ?? '';
    this.isFavorite = json['isFavorite'] as boolean ?? false;
    this.updateTime = json['updateTime'] as string ?? '';
    this.recommend = [];
    const rec = json['recommend'];
    if (rec && Array.isArray(rec)) {
      const arr = rec as Object[];
      for (let i = 0; i < arr.length; i++) {
        const item = arr[i] as Record<string, Object>;
        if (item) {
          this.recommend.push(new Comic(sourceKey, item));
        }
      }
    }
    this.uploader = json['uploader'] as string ?? '';
    const likes = json['likesCount'];
    this.likesCount = typeof likes === 'number' ? likes as number : 0;
    // 补全 id 引用(此构造用于阅读链路)
    if (this.comicId.length === 0) {
      this.comicId = json['id'] as string ?? '';
    }
  }
}