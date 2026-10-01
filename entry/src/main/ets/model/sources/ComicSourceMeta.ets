/**
 * VeneraNext JS 漫画源静态元信息
 * A 阶段(正则解析)与 B 阶段(JSVM 真引擎)产出同构, 供 UI/存储层复用
 */

/** 源设置定义(select/switch/input/callback 四类型) */
export class SettingDef {
  title: string;
  type: string;          // select | switch | input | callback
  /**
   * 源声明的默认值, 保留原始类型(boolean/number/string)。
   * 源脚本里常见 `if (loadSetting('xxx'))` 写法, 若把 "false" 变成字符串会恒为真。
   */
  default: Object | null;
  options: string[];     // select 选项值(value)
  /** select 选项显示名, 与 options 一一对应; 为空时直接用 options 显示 */
  optionLabels: string[];

  constructor(title: string, type: string, defaultValue: Object | null = null, options: string[] = []) {
    this.title = title;
    this.type = type;
    this.default = defaultValue;
    this.options = options;
    this.optionLabels = [];
  }

  /** 取某个选项的显示名 */
  labelOf(index: number): string {
    if (index >= 0 && index < this.optionLabels.length && this.optionLabels[index].length > 0) {
      return this.optionLabels[index];
    }
    if (index >= 0 && index < this.options.length) {
      return this.options[index];
    }
    return '';
  }
}

/** 源账号能力描述 */
export class AccountMeta {
  hasLogin: boolean = false;          // 账密登录
  loginUrl: string = '';              // login 提示链接
  registerUrl: string = '';           // 注册链接
  cookieFields: string[] = [];        // cookies 登录字段名
  hasWebviewLogin: boolean = false;   // WebView 登录
  webviewUrl: string = '';
  hasCookiesValidate: boolean = false;

  constructor() {
    this.hasLogin = false;
    this.loginUrl = '';
    this.registerUrl = '';
    this.cookieFields = [];
    this.hasWebviewLogin = false;
    this.webviewUrl = '';
    this.hasCookiesValidate = false;
  }
}

/**
 * 源提供的一个发现页(对应 JS 源 explore[i])
 * type 取值: singlePageWithMultiPart | multiPartPage | multiPageComicList | mixed
 */
export class ExplorePageInfo {
  sourceKey: string;
  sourceName: string;
  /** explore 数组下标 */
  index: number;
  title: string;
  type: string;
  /** explore[i].load 存在(分页列表/混合页必需) */
  hasLoad: boolean;
  /** explore[i].loadNext 存在(游标式分页) */
  hasLoadNext: boolean;

  constructor(sourceKey: string, sourceName: string, index: number,
              title: string, type: string, hasLoad: boolean) {
    this.sourceKey = sourceKey;
    this.sourceName = sourceName;
    this.index = index;
    this.title = title;
    this.type = type;
    this.hasLoad = hasLoad;
    this.hasLoadNext = false;
  }

  /** 是否为多 Part 单页(一次加载出多个分块) */
  isMultiPart(): boolean {
    return this.type === 'singlePageWithMultiPart' || this.type === 'multiPartPage';
  }

  /** 是否为混合页(列表与分块混合) */
  isMixed(): boolean {
    return this.type === 'mixed';
  }

  /** 页面唯一标识(title 可能重复, 用源+下标保证唯一) */
  uid(): string {
    return this.sourceKey + '#' + this.index;
  }
}

/** 分类项的跳转目标(对应原版 PageJumpTarget) */
export class CategoryTarget {
  /** category | search | 其它自定义页 */
  page: string = '';
  /** page=category 时的分类名 */
  category: string = '';
  /** 附加参数(传给 categoryComics.load 的 param) */
  param: string = '';
  /** page=search 时的关键词 */
  keyword: string = '';

  isSearch(): boolean {
    return this.page === 'search';
  }

  isCategory(): boolean {
    return this.page === 'category';
  }

  isValid(): boolean {
    return this.page.length > 0;
  }
}

/** 一个可点的分类标签 */
export class CategoryItem {
  label: string;
  target: CategoryTarget;

  constructor(label: string, target: CategoryTarget) {
    this.label = label;
    this.target = target;
  }
}

/** 分类分组(fixed / random / dynamic) */
export class CategoryPart {
  name: string = '';
  /** fixed | random | dynamic */
  type: string = 'fixed';
  /** random 类型时随机展示的个数 */
  randomNumber: number = 1;
  items: CategoryItem[] = [];
}

/** 源的分类配置(category) */
export class CategoryMeta {
  title: string = '';
  enableRankingPage: boolean = false;
  parts: CategoryPart[] = [];

  isEmpty(): boolean {
    return this.parts.length === 0;
  }
}

/** 搜索选项组(search.optionList 的一项) */
export class SearchOptionDef {
  label: string = '';
  /** select | multi-select | dropdown */
  type: string = 'select';
  /** key -> 显示名 */
  options: Map<string, string> = new Map<string, string>();
  /** 默认选中的 key */
  defaultValue: string = '';
  /** 供 multi-select 使用的默认值 */
  defaultValues: string[] = [];
}

/**
 * 源的网络收藏能力(对应原版 FavoriteData, 由 enrichFavorites 真引擎解析产出;
 * 源脚本以 favorites = {...} 声明)
 */
export class FavoriteMeta {
  /** 收藏页标题 */
  title: string = '';
  /** 是否多文件夹 */
  multiFolder: boolean = false;
  /** loadComics(page, folder) 存在(分页) */
  hasLoadComics: boolean = false;
  /** loadNext(next, folder) 存在(游标) */
  hasLoadNext: boolean = false;
  /** loadFolders(comicId?) 存在(多文件夹必需) */
  hasLoadFolders: boolean = false;
  /** addOrDelFavorite 存在(收藏/取消收藏) */
  hasAddOrDelFavorite: boolean = false;
  hasAddFolder: boolean = false;
  hasDeleteFolder: boolean = false;
  /** "全部收藏"的文件夹 ID(空串表示无) */
  allFavoritesId: string = '';
  /** 收藏时间是否从旧到新(影响同步的拉取起点) */
  isOldToNewSort: boolean = false;

  /** 是否具备任一收藏能力 */
  hasAny(): boolean {
    return this.hasLoadComics || this.hasLoadNext || this.hasLoadFolders
      || this.hasAddOrDelFavorite;
  }
}

/**
 * 磁盘上 JS 漫画源的静态描述
 * A 阶段由正则解析产出, B 阶段由 JSVM 执行产出(接口一致)
 */
export class ComicSourceMeta {
  key: string;
  name: string;
  version: string;
  minAppVersion: string;
  url: string;
  fileName: string;        // 磁盘文件名 <key>.js
  filePath: string;        // 沙箱绝对路径

  // 能力掩码
  hasExplore: boolean;
  hasSearch: boolean;
  hasLoadInfo: boolean;
  hasLoadEp: boolean;
  hasSettings: boolean;
  hasAccount: boolean;

  // 设置与账号
  settings: Map<string, SettingDef>;
  account: AccountMeta;
  /** 网络收藏能力(enrichFavorites 解析产出) */
  favorite: FavoriteMeta;

  // 发现页(真引擎解析产出)
  explorePages: ExplorePageInfo[];

  /**
   * 源声明的漫画 ID 规则(对应源里的 comic.idMatch 与 Dart 侧 idMatcher)。
   * 搜索框输入整体命中该正则时, 可直接按 ID 打开详情(comic.loadInfo)
   */
  idMatcher: string;

  // 分类与搜索(真引擎解析产出)
  category: CategoryMeta;
  /** search.optionList 定义的搜索选项组 */
  searchOptions: SearchOptionDef[];
  /** 源是否提供 categoryComics.load(可用于分类结果页) */
  hasCategoryComics: boolean;
  /** 源实现的是 search.load(分页) 还是 search.loadNext(游标) */
  searchHasLoad: boolean;
  /** categoryComics.optionList 定义的结果页选项组 */
  categoryOptions: SearchOptionDef[];

  // 源运行时数据 ({key}.data 内存镜像)
  data: Map<string, string>;

  constructor(key: string, name: string, version: string = '1.0.0') {
    this.key = key;
    this.name = name;
    this.version = version;
    this.minAppVersion = '';
    this.url = '';
    this.fileName = key + '.js';
    this.filePath = '';
    this.hasExplore = false;
    this.hasSearch = false;
    this.hasLoadInfo = false;
    this.hasLoadEp = false;
    this.hasSettings = false;
    this.hasAccount = false;
    this.settings = new Map<string, SettingDef>();
    this.account = new AccountMeta();
    this.favorite = new FavoriteMeta();
    this.explorePages = [];
    this.idMatcher = '';
    this.category = new CategoryMeta();
    this.searchOptions = [];
    this.hasCategoryComics = false;
    this.searchHasLoad = false;
    this.categoryOptions = [];
    this.data = new Map<string, string>();
  }
}