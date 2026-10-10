/**
 * 漫画详情页(最小实现)
 *
 * 数据入口: 源脚本的 comic.loadInfo(id) -> ComicDetails, 对应原版 ComicPage。
 * 当前服务于搜索框的「按 ID 直达」; 章节阅读(comic.loadEp + 图片管道)属后续阶段。
 */
import { promptAction } from '@kit.ArkUI';
import { common } from '@kit.AbilityKit';
import { image } from '@kit.ImageKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { Comic, ComicDetails, Comment } from '../../model/ComicModels';
import { ShelfItem, ShelfChapter, ShelfSourceType } from '../../model/ShelfItem';
import { localBookStore } from '../../model/LocalBookStore';
import { localFavoritesStore, FavoriteItem } from '../../model/LocalFavoritesStore';
import { downloadQueueStore, DownloadTask, DownloadStatus } from '../../model/DownloadQueueStore';
import { downloadService } from '../../services/DownloadService';
import { ReaderChapter, ReaderPageItem, ReaderPageType } from '../../model/ReaderModel';
import { comicDetailService } from '../../services/ComicDetailService';
import { comicReadService } from '../../services/ComicReadService';
import { readHistoryService, ReadHistoryItem } from '../../services/ReadHistoryService';
import { commentService, CommentResult } from '../../services/CommentService';
import { persistWebFavorites } from '../../utils/FileImporter';
import { appSettings } from '../../model/AppSettings';
import { knockShareService, ShareType, WebShareData, LocalShareData } from '../../services/KnockShareService';
import { ReaderSession } from './ReaderSession';
import { PRIMARY, PRIMARY_50, SUCCESS, GRAY_100, GRAY_500, GRAY_900, CARD, BG, MUTED_FG, ERROR,
  RADIUS_SM, RADIUS_MD, RADIUS_LG, SPACE_2, SPACE_3, SPACE_4,
  FS_TITLE, FS_SECTION, FS_BODY, FS_CAPTION, FS_SMALL } from '../../utils/Design';

const DOMAIN = 0x0000;
const TAG = 'ComicDetailPage';
/** 标签最多展示条数(部分源的标签极多) */
const MAX_TAGS = 30;

/** 扁平化后的章节项 */
class ChapterItem {
  id: string = '';
  title: string = '';
  /** 所属分组名(非分组漫画为空串) */
  group: string = '';
  /** 组内序号(0-based, 用于显示编号) */
  groupIdx: number = 0;
}

/** 展示用标签 */
class TagItem {
  text: string = '';
}

/** 标签分组(按 namespace) */
class TagGroup {
  namespace: string = '';
  items: string[] = [];
  color: string = '';
  bgColor: string = '';
}

/** namespace -> 颜色映射(低饱和半透明胶囊) */
function tagGroupColor(ns: string): [string, string] {
  // 返回 [textColor, bgColor(半透明)]
  switch (ns) {
    case '作者':
    case 'Author':
      return ['#FF145CDE', '#1A145CDE']; // 蓝色
    case '汉化组':
    case 'Translator':
      return ['#FF52C41A', '#1A52C41A']; // 绿色
    case '分类':
    case 'Categories':
    case 'Category':
      return ['#FF722ED1', '#1A722ED1']; // 紫色
    case '标签':
    case 'Tags':
    case 'Tag':
      return ['#FFFA8C16', '#1AFA8C16']; // 橙色
    case '上传者':
    case 'Uploader':
      return ['#FF13C2C2', '#1A13C2C2']; // 青色
    case '语言':
    case 'Language':
      return ['#FFEB2F96', '#1AEB2F96']; // 粉色
    case ' parody':
    case 'Parody':
      return ['#FF2F54EB', '#1A2F54EB']; // 深蓝
    case 'character':
    case 'Character':
      return ['#FFA0D911', '#1AA0D911']; // 黄绿
    case 'group':
    case 'Group':
      return ['#FFF5222D', '#1AF5222D']; // 红色
    case 'artist':
    case 'Artist':
      return ['#FF1890FF', '#1A1890FF']; // 亮蓝
    default:
      return ['#FF909399', '#1A909399']; // 默认灰色
  }
}

/** ComicDetails.tags(Map) -> 分组标签列表 */
function buildTagGroups(d: ComicDetails): TagGroup[] {
  const out: TagGroup[] = [];
  d.tags.forEach((values: string[], ns: string) => {
    const group = new TagGroup();
    group.namespace = ns;
    group.items = values;
    const colors = tagGroupColor(ns);
    group.color = colors[0];
    group.bgColor = colors[1];
    out.push(group);
  });
  return out;
}

@Component
export struct ComicDetailPage {
  /** 呈现容器(ComicDetailSheet)换书时同步并自动重载 */
  @Prop @Watch('onParamsChanged') sourceKey: string = '';
  sourceName: string = '';
  @Prop @Watch('onParamsChanged') comicId: string = '';

  /** 外部换书(半模态复用同一实例): 参数变化时重新加载 */
  onParamsChanged(): void {
    if (this.comicId.length > 0 && this.comicId !== this.currentId) {
      this.loadDetail(this.comicId);
    }
  }

  /** 推荐位跳转会替换当前 ID, 因此用内部状态而非直接读 prop */
  @State currentId: string = '';
  /** 详情数据(未加载时为占位对象, 由 hasDetail 判定是否可用) */
  @State detail: ComicDetails = new ComicDetails('', {});
  @State hasDetail: boolean = false;
  @State chapters: ChapterItem[] = [];
  @State tags: TagItem[] = [];
  @State tagGroups: TagGroup[] = [];
  @State recommend: Comic[] = [];
  @State loading: boolean = true;
  @State errorMsg: string = '';
  /** 当前阅读章节(发布到全局阅读器展示) */
  @State readerChapter: ReaderChapter | null = null;
  @State chapterLoading: boolean = false;
  /** 打开的章节要跳到的页码(0 基), 用于续读 */
  @State readerStartPage: number = 0;
  /** 本漫画的阅读进度(无则 null) */
  @State progress: ReadHistoryItem | null = null;
  /** 是否已收藏到书架(WEB 收藏快照) */
  @State isFaved: boolean = false;
  // 按压形变状态(共享 key, 模拟 systemMaterial interactive 物理效果)
  @State pressedKey: string = '';

  /** 按压形变触摸处理: Down 缩放 / Up·Cancel 恢复 */
  pressTouch(e: TouchEvent, key: string): void {
    if (e.type === TouchType.Down) {
      animateTo({ duration: 120, curve: Curve.EaseOut }, () => { this.pressedKey = key; });
    } else if (e.type === TouchType.Up || e.type === TouchType.Cancel) {
      animateTo({ duration: 120, curve: Curve.EaseOut }, () => { this.pressedKey = ''; });
    }
  }

  /** 按压缩放值 */
  pressScaleOf(key: string): number {
    return this.pressedKey === key ? 0.92 : 1;
  }
  /** 章节倒序显示(从 AppSettings 初始化, 详情页可临时切换) */
  @State reverseChapters: boolean = false;
  /** 当前阅读章节的图片地址(与 readerChapter.pages 下标对齐) */
  private readerUrls: string[] = [];
  private readerEpId: string = '';
  // === 评论状态 ===
  @State comments: Comment[] = [];
  @State commentPage: number = 1;
  @State commentMaxPage: number = 1;
  @State commentLoading: boolean = false;
  @State commentInput: string = '';
  @State commentSending: boolean = false;
  @State showCommentInput: boolean = false;
  // === 回复展开状态 ===
  @State expandedReplyId: string = '';
  @State replyMap: Map<string, Comment[]> = new Map();
  @State replyLoadingId: string = '';

  aboutToAppear(): void {
    hilog.info(DOMAIN, TAG, '详情页创建 id=%{public}s', this.comicId);
    this.currentId = this.comicId;
    this.reverseChapters = appSettings.get<boolean>('reverseChapterOrder', false);
    this.reload();
  }

  private reload(): void {
    hilog.info(DOMAIN, TAG, '详情页 reload id=%{public}s', this.currentId);
    this.loadDetail(this.currentId);
  }

  private async loadDetail(id: string): Promise<void> {
    if (id.length === 0) {
      return;
    }
    this.currentId = id;
    this.loading = true;
    this.errorMsg = '';
    this.hasDetail = false;
    try {
      const d = await comicDetailService.load(this.sourceKey, id);
      this.detail = d;
      this.hasDetail = true;
      this.chapters = buildChapters(d, this.reverseChapters);
      this.tags = buildTags(d);
      this.tagGroups = buildTagGroups(d);
      this.recommend = d.recommend;
    } catch (e) {
      this.errorMsg = `${e}`;
      hilog.warn(DOMAIN, TAG, '加载详情失败 %{public}s@%{public}s: %{public}s',
        this.sourceKey, id, this.errorMsg);
    } finally {
      this.loading = false;
      // 详情就绪后读取该漫画的阅读进度与收藏状态
      this.progress = readHistoryService.find(this.sourceKey, this.currentId);
      this.isFaved = localBookStore.findById(this.webFavId()) !== null;
      // 加载评论(异步, 不阻塞详情展示)
      this.loadComments();
    }
  }

  /** 加载评论列表 */
  private async loadComments(): Promise<void> {
    if (!this.hasDetail) {
      return;
    }
    this.commentLoading = true;
    this.comments = [];
    this.commentPage = 1;
    try {
      const res = await commentService.loadComments(
        this.sourceKey, this.currentId, this.detail.subId, 1, '');
      this.comments = res.comments;
      this.commentMaxPage = res.maxPage;
    } catch (e) {
      hilog.warn(DOMAIN, TAG, '加载评论失败: %{public}s', `${e}`);
    } finally {
      this.commentLoading = false;
    }
  }

  /** 加载更多评论(下一页) */
  private async loadMoreComments(): Promise<void> {
    if (this.commentLoading || this.commentPage >= this.commentMaxPage) {
      return;
    }
    this.commentLoading = true;
    try {
      const nextPage = this.commentPage + 1;
      const res = await commentService.loadComments(
        this.sourceKey, this.currentId, this.detail.subId, nextPage, '');
      this.comments = [...this.comments, ...res.comments];
      this.commentPage = nextPage;
      this.commentMaxPage = res.maxPage;
    } catch (e) {
      hilog.warn(DOMAIN, TAG, '加载更多评论失败: %{public}s', `${e}`);
    } finally {
      this.commentLoading = false;
    }
  }

  /** 发送评论 */
  private async sendComment(): Promise<void> {
    if (this.commentInput.trim().length === 0 || this.commentSending) {
      return;
    }
    this.commentSending = true;
    try {
      await commentService.sendComment(
        this.sourceKey, this.currentId, this.detail.subId, this.commentInput.trim(), '');
      this.commentInput = '';
      this.showCommentInput = false;
      promptAction.showToast({ message: '评论已发送' });
      // 重新加载评论
      this.loadComments();
    } catch (e) {
      promptAction.showToast({ message: '发送失败: ' + `${e}` });
    } finally {
      this.commentSending = false;
    }
  }

  /** 点赞/取消点赞评论 */
  private async toggleCommentLike(comment: Comment): Promise<void> {
    const newIsLiked = !comment.isLiked;
    // 乐观更新: 先切换 UI 状态
    const idx = this.comments.indexOf(comment);
    if (idx >= 0) {
      const updated = new Comment({});
      updated.userName = comment.userName;
      updated.avatar = comment.avatar;
      updated.content = comment.content;
      updated.time = comment.time;
      updated.replyCount = comment.replyCount;
      updated.id = comment.id;
      updated.isLiked = newIsLiked;
      updated.score = newIsLiked ? comment.score + 1 : Math.max(0, comment.score - 1);
      this.comments[idx] = updated;
    }
    try {
      await commentService.likeComment(
        this.sourceKey, this.currentId, this.detail.subId, comment.id, newIsLiked);
    } catch (e) {
      // 回滚乐观更新
      if (idx >= 0) {
        this.comments[idx] = comment;
      }
      promptAction.showToast({ message: '操作失败' });
    }
  }

  /** 展开/收起回复列表 */
  private async toggleReplyExpansion(c: Comment): Promise<void> {
    if (this.expandedReplyId === c.id) {
      this.expandedReplyId = '';
      return;
    }
    this.expandedReplyId = c.id;
    if (!this.replyMap.has(c.id)) {
      this.replyLoadingId = c.id;
      try {
        const res = await commentService.loadComments(
          this.sourceKey, this.currentId, this.detail.subId, 1, c.id);
        this.replyMap.set(c.id, res.comments);
      } catch (e) {
        promptAction.showToast({ message: '加载回复失败' });
        this.expandedReplyId = '';
      } finally {
        this.replyLoadingId = '';
      }
    }
  }

  /** 续读: 打开上次的章节并跳到上次的页码 */
  private continueReading(): void {
    const p = this.progress;
    if (p === null) {
      return;
    }
    let target: ChapterItem | null = null;
    for (let i = 0; i < this.chapters.length; i++) {
      if (this.chapters[i].id === p.epId) {
        target = this.chapters[i];
        break;
      }
    }
    if (target === null) {
      promptAction.showToast({ message: '上次阅读的章节已不存在' });
      return;
    }
    this.readerStartPage = p.page;
    this.openReader(target).catch((e: Error) => {
      hilog.warn(DOMAIN, TAG, '续读失败: %{public}s', `${e}`);
    });
  }

  /** 阅读器页码变化: 记录进度(不刷新本页状态, 避免打断阅读) */
  private onReaderProgress: (page: number, total: number) => void =
    (page: number, total: number): void => {
      if (this.readerUrls.length === 0) {
        return;
      }
      const item = new ReadHistoryItem();
      item.sourceKey = this.sourceKey;
      item.comicId = this.currentId;
      item.comicTitle = this.detail.title;
      item.cover = this.detail.cover;
      item.epId = this.readerEpId;
      item.epTitle = this.readerChapter !== null ? this.readerChapter.title : '';
      item.page = page;
      item.total = total;
      readHistoryService.record(item);
    };

  /** 续读按钮文案: 继续阅读 · 第X话 (P3/25) */
  private progressLabel(): string {
    const p = this.progress;
    if (p === null) {
      return '继续阅读';
    }
    const ep = p.epTitle.length > 0 ? p.epTitle : p.epId;
    return `继续阅读 · ${ep}（P${p.page + 1}/${p.total}）`;
  }

  /** 续读按钮副标题: 下 · P3/25 */
  private progressBrief(): string {
    const p = this.progress;
    if (p === null) {
      return '';
    }
    const ep = p.epTitle.length > 0 ? p.epTitle : p.epId;
    return `${ep} · P${p.page + 1}/${p.total}`;
  }

  private openChapter(c: ChapterItem): void {
    // 直接点章节: 从第一页开始
    this.readerStartPage = 0;
    this.openReader(c).catch((e: Error) => {
      hilog.warn(DOMAIN, TAG, '打开章节失败: %{public}s', `${e}`);
    });
  }

  /** 打开章节: 先取图片地址列表, 再交给阅读器按页懒加载 */
  private async openReader(c: ChapterItem): Promise<void> {
    if (this.chapterLoading) {
      return;
    }
    this.chapterLoading = true;
    promptAction.showToast({ message: '正在加载章节…' });
    try {
      const ok = await this.openChapterAt(c);
      if (ok) {
        // 发布到全局阅读器(Index 窗口根层挂载, 保证全屏)
        this.publishReaderSession(this.readerStartPage);
      }
    } finally {
      this.chapterLoading = false;
    }
  }

  /** 载入某一章的图片地址并替换阅读内容(不改变阅读器显隐) */
  private async openChapterAt(c: ChapterItem): Promise<boolean> {
    const res = await comicReadService.loadImages(this.sourceKey, this.currentId, c.id);
    if (!res.isOk()) {
      promptAction.showToast({ message: res.error.length > 0 ? res.error : '章节加载失败' });
      return false;
    }
    this.readerUrls = res.urls;
    this.readerEpId = c.id;
    const pages: ReaderPageItem[] = [];
    for (let i = 0; i < res.urls.length; i++) {
      pages.push(new ReaderPageItem(ReaderPageType.IMAGE, i, '', '', '', '', ''));
    }
    // 换新对象: ReaderPage 的 @Watch 会重置页状态
    this.readerChapter = new ReaderChapter(1, c.title, pages);
    return true;
  }

  /** 当前阅读章节在章节列表中的下标(不在列表里返回 -1) */
  private readerChapterIndex(): number {
    for (let i = 0; i < this.chapters.length; i++) {
      if (this.chapters[i].id === this.readerEpId) {
        return i;
      }
    }
    return -1;
  }

  /** 阅读器请求切章: delta = -1 上一话 / 1 下一话 */
  private switchReaderChapter: (delta: number) => Promise<boolean> =
    async (delta: number): Promise<boolean> => {
      const idx = this.readerChapterIndex();
      if (idx < 0) {
        return false;
      }
      const next = idx + delta;
      if (next < 0 || next >= this.chapters.length) {
        return false;
      }
      const ok = await this.openChapterAt(this.chapters[next]);
      if (ok) {
        hilog.info(DOMAIN, TAG, '切换到章节 %{public}s', this.chapters[next].title);
        // 重新发布: 新 chapter 对象触发 ReaderPage 的 @Watch 重置页状态
        this.publishReaderSession(0);
      }
      return ok;
    };

  /** 阅读器按页取图: 带源声明的请求头, 必要时执行图片还原 */
  private loadReaderPage: (index: number) => Promise<image.PixelMap | null> =
    (index: number): Promise<image.PixelMap | null> => {
      if (index < 0 || index >= this.readerUrls.length) {
        return Promise.resolve(null);
      }
      return comicReadService.loadImage(this.sourceKey, this.currentId, this.readerEpId,
        this.readerUrls[index]);
    };

  /** 把当前阅读内容发布到全局阅读器(由 Index 在窗口根层挂载, 保证全屏) */
  private publishReaderSession(startPage: number): void {
    const idx = this.readerChapterIndex();
    const s = new ReaderSession();
    s.chapter = this.readerChapter;
    s.hasPrev = idx > 0;
    s.hasNext = idx >= 0 && idx < this.chapters.length - 1;
    s.startPage = startPage;
    s.loader = this.loadReaderPage;
    s.switcher = this.switchReaderChapter;
    s.onProgress = this.onReaderProgress;
    s.onClose = (): void => {
      // 退出阅读后释放图片内存缓存, 并刷新进度显示
      comicReadService.clearCache();
      this.progress = readHistoryService.find(this.sourceKey, this.currentId);
    };
    ReaderSession.publish(s);
  }

  // ---------------------------------------------------------------- UI

  /** 分区标题(与本地详情 DetailPanel 同款) */
  @Builder
  sectionTitle(title: string) {
    Text(title).fontSize(FS_SECTION).fontWeight(FontWeight.Bold).fontColor(GRAY_900)
      .width('100%').margin({ top: SPACE_4 })
  }

  @Builder
  chip(text: string, bg: string, fg: string) {
    Text(text).fontSize(FS_SMALL).fontColor(fg).backgroundColor(bg)
      .borderRadius(RADIUS_SM).padding({ left: 10, right: 10, top: 4, bottom: 4 })
  }

  @Builder
  infoSection(d: ComicDetails) {
    Row({ space: SPACE_3 }) {
      if (d.cover.length > 0) {
        Image(d.cover)
          .width(96).height(128)
          .objectFit(ImageFit.Cover)
          .borderRadius(RADIUS_MD).backgroundColor(GRAY_100)
      } else {
        Column().width(96).height(128)
          .borderRadius(RADIUS_MD).backgroundColor(GRAY_100)
      }

      Column({ space: 4 }) {
        Text(d.title)
          .fontSize(FS_TITLE).fontWeight(FontWeight.Bold).fontColor(GRAY_900)
          .maxLines(2).textOverflow({ overflow: TextOverflow.Ellipsis })
          .width('100%')
        if (d.subtitle.length > 0) {
          Text(d.subtitle).fontSize(FS_SMALL).fontColor(MUTED_FG)
            .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
            .width('100%')
        }
        if (d.uploader.length > 0) {
          Text('作者: ' + d.uploader).fontSize(FS_CAPTION).fontColor(MUTED_FG)
            .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
            .width('100%')
        }
        Row({ space: 6 }) {
          this.chip(this.sourceName.length > 0 ? this.sourceName : this.sourceKey, PRIMARY_50, PRIMARY)
          if (d.isFavorite) {
            this.chip('已收藏', SUCCESS, CARD)
          }
        }
        .margin({ top: 2 })
      }
      .layoutWeight(1).alignItems(HorizontalAlign.Start)
    }
    .width('100%').alignItems(VerticalAlign.Top)
    .margin({ top: SPACE_3 })
  }

  /** 数据行: 赞 / 更新时间 / 章节数 */
  @Builder
  metaRow(d: ComicDetails) {
    Row() {
      this.metaCell(d.likesCount > 0 ? d.likesCount.toString() : '-', '点赞')
      this.metaCell(d.updateTime.length > 0 ? d.updateTime : '-', '最近更新')
      this.metaCell(this.chapters.length.toString(), '章节')
    }
    .width('100%').padding({ top: SPACE_3, bottom: SPACE_3, left: SPACE_3, right: SPACE_3 })
    .backgroundColor(CARD).borderRadius(RADIUS_LG).margin({ top: SPACE_3 })
  }

  @Builder
  metaCell(val: string, label: string) {
    Column({ space: 2 }) {
      Text(val).fontSize(FS_BODY).fontWeight(FontWeight.Bold).fontColor(GRAY_900)
        .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
      Text(label).fontSize(FS_SMALL).fontColor(MUTED_FG)
    }
    .layoutWeight(1).alignItems(HorizontalAlign.Start)
  }

  /** 主操作: 收藏 / 继续阅读(有进度) 或 从头阅读 */
  @Builder
  actionRow() {
    Row({ space: 10 }) {
      Column({ space: 2 }) {
        SymbolGlyph($r('sys.symbol.heart')).fontSize(22)
          .fontColor([this.isFaved ? '#FFE8455E' : GRAY_500])
        Text(this.isFaved ? '已收藏' : '收藏').fontSize(FS_SMALL).fontColor(MUTED_FG)
      }
      .width(72).height(48).justifyContent(FlexAlign.Center).borderRadius(RADIUS_MD)
      .backgroundColor(GRAY_100)
      .scale({ x: this.pressScaleOf('fav'), y: this.pressScaleOf('fav') })
      .animation({ duration: 120, curve: Curve.EaseOut })
      .onClick(() => {
        this.toggleFavorite();
      })
      .onTouch((e: TouchEvent) => { this.pressTouch(e, 'fav'); })

      Column({ space: 2 }) {
        SymbolGlyph($r('sys.symbol.arrow_down')).fontSize(22)
          .fontColor([GRAY_500])
        Text('下载').fontSize(FS_SMALL).fontColor(MUTED_FG)
      }
      .width(72).height(48).justifyContent(FlexAlign.Center).borderRadius(RADIUS_MD)
      .backgroundColor(GRAY_100)
      .scale({ x: this.pressScaleOf('dl'), y: this.pressScaleOf('dl') })
      .animation({ duration: 120, curve: Curve.EaseOut })
      .onClick(() => {
        this.showDownloadDialog();
      })
      .onTouch((e: TouchEvent) => { this.pressTouch(e, 'dl'); })

      // 碰一碰分享按钮 - 暂时隐藏，后续完善后再放出
      // Column({ space: 2 }) {
      //   SymbolGlyph($r('sys.symbol.share')).fontSize(22)
      //     .fontColor([GRAY_500])
      //   Text('碰一碰').fontSize(FS_SMALL).fontColor(MUTED_FG)
      // }
      // .width(72).height(48).justifyContent(FlexAlign.Center).borderRadius(RADIUS_MD)
      // .backgroundColor(GRAY_100)
      // .scale({ x: this.pressScaleOf('knock'), y: this.pressScaleOf('knock') })
      // .animation({ duration: 120, curve: Curve.EaseOut })
      // .onClick(() => {
      //   this.startKnockShare();
      // })
      // .onTouch((e: TouchEvent) => { this.pressTouch(e, 'knock'); })

      if (this.progress !== null) {
        Column({ space: 2 }) {
          Text('继续阅读').fontSize(15).fontColor(CARD).fontWeight(FontWeight.Medium)
          Text(this.progressBrief()).fontSize(9).fontColor('#CCFFFFFF')
            .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
        }
        .height(48).layoutWeight(1).justifyContent(FlexAlign.Center).borderRadius(RADIUS_MD)
        .backgroundColor(PRIMARY)
        .scale({ x: this.pressScaleOf('continue'), y: this.pressScaleOf('continue') })
        .animation({ duration: 120, curve: Curve.EaseOut })
        .onClick(() => {
          this.continueReading();
        })
        .onTouch((e: TouchEvent) => { this.pressTouch(e, 'continue'); })
      }

      Column() {
        Text(this.progress !== null ? '从头阅读' : '开始阅读')
          .fontSize(15).fontColor(PRIMARY).fontWeight(FontWeight.Medium)
      }
      .height(48).layoutWeight(1).justifyContent(FlexAlign.Center).borderRadius(RADIUS_MD)
      .backgroundColor(PRIMARY_50)
      .scale({ x: this.pressScaleOf('start'), y: this.pressScaleOf('start') })
      .animation({ duration: 120, curve: Curve.EaseOut })
      .onClick(() => {
        this.readFromStart();
      })
      .onTouch((e: TouchEvent) => { this.pressTouch(e, 'start'); })
    }
    .width('100%').margin({ top: SPACE_3 })
  }

  /** 从第一章开始读 */
  private readFromStart(): void {
    if (this.chapters.length === 0) {
      promptAction.showToast({ message: '没有可阅读的章节' });
      return;
    }
    this.openChapter(this.chapters[0]);
  }

  /** 下载对话框：选择下载范围 */
  private showDownloadDialog(): void {
    if (this.chapters.length === 0) {
      promptAction.showToast({ message: '没有可下载的章节' });
      return;
    }
    promptAction.showDialog({
      title: '下载章节',
      message: `共 ${this.chapters.length} 个章节，选择下载范围：`,
      buttons: [
        { text: '全部章节', color: '#FF4F8EF7' },
        { text: '前5章', color: '#FF4F8EF7' },
        { text: '取消', color: '#FF999999' }
      ]
    }).then((result: promptAction.ShowDialogSuccessResponse) => {
      if (result.index === 0) {
        this.enqueueDownload(0, this.chapters.length - 1);
      } else if (result.index === 1) {
        const end = Math.min(4, this.chapters.length - 1);
        this.enqueueDownload(0, end);
      }
    });
  }

  /** 将指定范围的章节加入下载队列 */
  private enqueueDownload(startIdx: number, endIdx: number): void {
    let added = 0;
    for (let i = startIdx; i <= endIdx; i++) {
      const c = this.chapters[i];
      const taskId = this.sourceKey + '|' + this.currentId + '|' + c.id;
      const task = new DownloadTask(taskId, this.sourceKey, this.currentId, c.id,
        c.title.length > 0 ? c.title : c.id, this.detail.title, this.detail.cover);
      if (downloadQueueStore.addTask(task)) {
        added++;
      }
    }
    if (added > 0) {
      promptAction.showToast({ message: `已加入下载队列 (${added} 个章节)` });
      downloadService.startQueue();
    } else {
      promptAction.showToast({ message: '这些章节已在下载队列中' });
    }
  }

  /** 碰一碰分享: 将当前漫画信息通过 NFC 碰一碰分享给附近设备 */
  private startKnockShare(): void {
    if (!this.hasDetail) {
      promptAction.showToast({ message: '漫画信息未加载完成' });
      return;
    }
    const d = this.detail;
    // 判断是 WEB 源还是本地源
    if (this.sourceKey.length > 0) {
      // WEB 源: 分享 sourceKey + comicId, 对方可直接关联到正确源
      const shareData: WebShareData = {
        type: ShareType.WEB,
        sourceKey: this.sourceKey,
        comicId: this.currentId,
        title: d.title,
        cover: d.cover,
        author: d.uploader,
        description: d.description,
        tags: this.tags.map((t: TagItem) => t.text)
      };
      knockShareService.registerShare(shareData);
      promptAction.showToast({ message: '碰一碰分享已准备，请将设备靠近对方设备' });
    } else {
      // 本地源: 分享元信息(文件包传输暂不支持)
      const shareData: LocalShareData = {
        type: ShareType.LOCAL,
        title: d.title,
        cover: d.cover,
        author: d.uploader,
        description: d.description,
        tags: this.tags.map((t: TagItem) => t.text),
        fileFormat: '',
        fileSize: 0
      };
      knockShareService.registerShare(shareData);
      promptAction.showToast({ message: '碰一碰分享已准备，本地文件传输暂不支持' });
    }
  }

  /** 注销碰一碰分享监听(页面退出时调用) */
  private stopKnockShare(): void {
    knockShareService.unregisterShare();
  }

  /** WEB 收藏条目在书架中的 id */
  private webFavId(): string {
    return 'web_' + this.sourceKey + '_' + this.currentId;
  }

  /** 收藏/取消收藏: 同时写入书架(LocalBookStore)和收藏夹(LocalFavoritesStore) */
  private toggleFavorite(): void {
    if (!this.hasDetail) {
      return;
    }
    const ctx = this.getUIContext().getHostContext() as common.UIAbilityContext;
    const id = this.webFavId();
    if (this.isFaved) {
      // 取消收藏：从书架和所有收藏夹移除
      localBookStore.removeItem(id);
      localFavoritesStore.removeFromAllFolders(id);
      this.isFaved = false;
      persistWebFavorites(ctx, localBookStore.all());
      promptAction.showToast({ message: '已取消收藏' });
      return;
    }
    // 添加收藏：写入书架 + 默认收藏夹
    const chs: ShelfChapter[] = [];
    for (let i = 0; i < this.chapters.length; i++) {
      chs.push(new ShelfChapter(this.chapters[i].title, 0));
    }
    const tagArr: string[] = [];
    for (let i = 0; i < this.tags.length; i++) {
      tagArr.push(this.tags[i].text);
    }
    localBookStore.addItem(new ShelfItem(id, this.detail.title, this.detail.cover,
      this.detail.uploader, this.detail.description, tagArr, ShelfSourceType.WEB, chs, true,
      0, '', 0, '', [], '', null, false, ''));
    // 同时写入 LocalFavoritesStore（默认文件夹）
    const favItem = new FavoriteItem(
      id, this.detail.title, this.detail.uploader,
      typeof this.detail.cover === 'string' ? this.detail.cover as string : '',
      tagArr, Date.now(), 0, ShelfSourceType.WEB, this.sourceKey, this.currentId
    );
    localFavoritesStore.addComic('收藏', favItem);
    this.isFaved = true;
    persistWebFavorites(ctx, localBookStore.all());
    promptAction.showToast({ message: '已收藏' });
  }

  @Builder
  tagSection() {
    Column() {
      this.sectionTitle('标签')
      // 按 namespace 分组展示, 每组用不同颜色的低饱和半透明胶囊
      ForEach(this.tagGroups, (group: TagGroup) => {
        Column({ space: 4 }) {
          // namespace 标题
          if (group.namespace.length > 0) {
            Text(group.namespace).fontSize(FS_SMALL).fontColor(group.color)
              .fontWeight(FontWeight.Medium).margin({ top: SPACE_2 })
          }
          // 标签胶囊
          Flex({ wrap: FlexWrap.Wrap }) {
            ForEach(group.items, (tag: string) => {
              Text(tag).fontSize(FS_SMALL).fontColor(group.color)
                .padding({ left: 10, right: 10, top: 4, bottom: 4 })
                .backgroundColor(group.bgColor).borderRadius(12)
                .margin({ right: 6, bottom: 6 })
            }, (tag: string, i: number) => `tg#${group.namespace}#${i}#${tag}`)
          }
          .width('100%')
        }
        .width('100%').alignItems(HorizontalAlign.Start)
      }, (group: TagGroup) => `tgn#${group.namespace}`)
    }
    .width('100%').alignItems(HorizontalAlign.Start)
  }

  /** 章节行: 序号(组内编号) + 标题 + 提示(读到过 / 右箭头) */
  @Builder
  chapterRow(c: ChapterItem, idx: number) {
    Row({ space: SPACE_3 }) {
      Text((c.groupIdx + 1).toString())
        .fontSize(FS_SMALL).fontColor(MUTED_FG)
        .width(28).height(28).textAlign(TextAlign.Center)
        .borderRadius(14).backgroundColor(GRAY_100)

      Column({ space: 2 }) {
        Text(c.title.length > 0 ? c.title : c.id)
          .fontSize(FS_BODY).fontColor(GRAY_900)
          .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
          .width('100%')
        if (this.isReadingChapter(c)) {
          Text('读到第 ' + ((this.progress?.page ?? 0) + 1) + ' 页')
            .fontSize(10).fontColor(PRIMARY)
        }
      }
      .layoutWeight(1).alignItems(HorizontalAlign.Start)

      SymbolGlyph($r('sys.symbol.chevron_right')).fontSize(14).fontColor([MUTED_FG])
    }
    .width('100%').height(52)
    .alignItems(VerticalAlign.Center)
    .onClick(() => {
      this.openChapter(c);
    })
  }

  /** 该章节是否是上次读到的章节 */
  private isReadingChapter(c: ChapterItem): boolean {
    const p = this.progress;
    return p !== null && p.epId === c.id;
  }

  /** 切换章节倒序: 重建 chapters 数组, 阅读器导航随之跟随 */
  private toggleReverseChapters(): void {
    this.reverseChapters = !this.reverseChapters;
    if (this.hasDetail) {
      this.chapters = buildChapters(this.detail, this.reverseChapters);
    }
  }

  /** 判断当前章节项是否需要显示分组标题(组首或第一项) */
  private isGroupHeader(idx: number): boolean {
    if (idx >= this.chapters.length) {
      return false;
    }
    const c = this.chapters[idx];
    if (c.group.length === 0) {
      return false;
    }
    return idx === 0 || this.chapters[idx - 1].group !== c.group;
  }

  @Builder
  chapterSection() {
    Column() {
      // 章节标题行 + 倒序切换按钮
      Row() {
        Text('章节').fontSize(FS_SECTION).fontWeight(FontWeight.Bold).fontColor(GRAY_900)
        Blank()
        Row({ space: 4 }) {
          SymbolGlyph($r('sys.symbol.chevron_up'))
            .fontSize(14)
            .fontColor([this.reverseChapters ? PRIMARY : MUTED_FG])
          SymbolGlyph($r('sys.symbol.chevron_down'))
            .fontSize(14)
            .fontColor([this.reverseChapters ? PRIMARY : MUTED_FG])
          Text(this.reverseChapters ? '倒序' : '正序')
            .fontSize(FS_SMALL).fontColor(this.reverseChapters ? PRIMARY : MUTED_FG)
        }
        .onClick(() => {
          this.toggleReverseChapters();
        })
      }
      .width('100%').margin({ top: SPACE_4 })

      Column() {
        ForEach(this.chapters, (c: ChapterItem, idx: number) => {
          // 分组标题: 组名变化时插入分隔标题
          if (this.isGroupHeader(idx)) {
            Row() {
              Text(c.group)
                .fontSize(FS_BODY).fontWeight(FontWeight.Bold).fontColor(GRAY_900)
            }
            .width('100%').padding({ top: SPACE_2, bottom: 4 })
          }
          this.chapterRow(c, idx)
          if (idx < this.chapters.length - 1) {
            Divider().color(GRAY_100).strokeWidth(0.5)
          }
        }, (c: ChapterItem) => `cp#${c.id}`)
      }
      .width('100%').padding({ left: SPACE_3, right: SPACE_3 })
      .backgroundColor(CARD).borderRadius(RADIUS_LG)
      .margin({ top: SPACE_2 })
    }
    .width('100%').alignItems(HorizontalAlign.Start)
  }

  @Builder
  recommendSection() {
    Column() {
      this.sectionTitle('相关推荐')
      Scroll() {
        Row({ space: SPACE_2 }) {
          ForEach(this.recommend, (c: Comic) => {
            Column() {
              if (c.cover.length > 0) {
                Image(c.cover)
                  .width(96).aspectRatio(0.72)
                  .objectFit(ImageFit.Cover)
                  .borderRadius(RADIUS_MD).backgroundColor(GRAY_100)
              } else {
                Column().width(96).aspectRatio(0.72)
                  .borderRadius(RADIUS_MD).backgroundColor(GRAY_100)
              }
              Text(c.title.length > 0 ? c.title : c.id)
                .fontSize(11).fontColor(GRAY_900).width(96)
                .maxLines(2).textOverflow({ overflow: TextOverflow.Ellipsis })
                .margin({ top: 4 })
            }
            .width(96)
            .onClick(() => {
              this.loadDetail(c.id);
            })
          }, (c: Comic) => `rc#${c.id}`)
        }
      }
      .scrollable(ScrollDirection.Horizontal)
      .scrollBar(BarState.Off)
      .align(Alignment.Start)
      .width('100%').margin({ top: SPACE_2 })
    }
    .width('100%').alignItems(HorizontalAlign.Start)
  }

  @Builder
  commentSection() {
    Column() {
      // 标题行 + 发评论按钮
      Row() {
        Text('评论').fontSize(FS_SECTION).fontWeight(FontWeight.Bold).fontColor(GRAY_900)
        if (this.detail.commentCount > 0) {
          Text(`${this.detail.commentCount}`).fontSize(FS_SMALL).fontColor(MUTED_FG)
            .margin({ left: 6 })
        }
        Blank()
        Text('发评论').fontSize(FS_SMALL).fontColor(PRIMARY)
          .onClick(() => {
            this.showCommentInput = !this.showCommentInput;
          })
      }
      .width('100%').margin({ top: SPACE_4 })

      // 发评论输入框
      if (this.showCommentInput) {
        Column({ space: 8 }) {
          TextArea({ placeholder: '写下你的评论...', text: this.commentInput })
            .fontSize(FS_BODY).fontColor(GRAY_900)
            .backgroundColor(GRAY_100).borderRadius(RADIUS_MD)
            .width('100%').height(80)
            .onChange((value: string) => {
              this.commentInput = value;
            })
          Row() {
            Blank()
            Text(this.commentSending ? '发送中...' : '发送')
              .fontSize(FS_SMALL).fontColor(this.commentSending ? MUTED_FG : CARD)
              .height(32).padding({ left: 16, right: 16 }).borderRadius(16)
              .backgroundColor(this.commentSending ? GRAY_100 : PRIMARY)
              .textAlign(TextAlign.Center)
              .onClick(() => {
                if (!this.commentSending) {
                  this.sendComment();
                }
              })
          }
          .width('100%')
        }
        .width('100%').padding(SPACE_3)
        .backgroundColor(CARD).borderRadius(RADIUS_MD).margin({ top: SPACE_2 })
      }

      // 评论列表
      if (this.commentLoading && this.comments.length === 0) {
        Row({ space: 8 }) {
          LoadingProgress().width(20).height(20).color(PRIMARY)
          Text('加载评论中...').fontSize(FS_SMALL).fontColor(MUTED_FG)
        }
        .width('100%').justifyContent(FlexAlign.Center).padding(SPACE_4)
      } else if (this.comments.length === 0) {
        Column({ space: 6 }) {
          Text('暂无评论').fontSize(FS_SMALL).fontColor(MUTED_FG)
        }
        .width('100%').justifyContent(FlexAlign.Center).padding(SPACE_4)
      } else {
        Column() {
          ForEach(this.comments, (c: Comment, index: number) => {
            this.commentRow(c)
          }, (c: Comment, index: number) => `cm#${index}#${c.id}#${c.isLiked}#${c.score}`)
        }
        .width('100%').padding({ left: SPACE_3, right: SPACE_3 })
        .backgroundColor(CARD).borderRadius(RADIUS_LG)
        .margin({ top: SPACE_2 })

        // 加载更多按钮
        if (this.commentPage < this.commentMaxPage) {
          Row() {
            if (this.commentLoading) {
              LoadingProgress().width(16).height(16).color(PRIMARY)
              Text('加载中...').fontSize(FS_SMALL).fontColor(MUTED_FG).margin({ left: 6 })
            } else {
              Text('加载更多').fontSize(FS_SMALL).fontColor(PRIMARY)
            }
          }
          .width('100%').justifyContent(FlexAlign.Center).padding(SPACE_3)
          .onClick(() => {
            if (!this.commentLoading) {
              this.loadMoreComments();
            }
          })
        }
      }
    }
    .width('100%').alignItems(HorizontalAlign.Start)
  }

  /** 单条评论行 */
  @Builder
  commentRow(c: Comment) {
    Row({ space: 10 }) {
      // 头像
      if (c.avatar.length > 0) {
        Image(c.avatar).width(36).height(36).borderRadius(18)
          .objectFit(ImageFit.Cover).backgroundColor(GRAY_100)
      } else {
        Column().width(36).height(36).borderRadius(18).backgroundColor(GRAY_100)
      }

      Column({ space: 4 }) {
        // 用户名 + 时间
        Row() {
          Text(c.userName).fontSize(FS_SMALL).fontColor(GRAY_900).fontWeight(FontWeight.Medium)
            .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
          if (c.time.length > 0) {
            Text(c.time).fontSize(10).fontColor(MUTED_FG).margin({ left: 8 })
              .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
          }
        }
        .width('100%')

        // 评论内容
        Text(c.content).fontSize(FS_BODY).fontColor(GRAY_900).lineHeight(20)
          .width('100%')

        // 点赞 + 回复数
        Row({ space: 12 }) {
          Row({ space: 4 }) {
            SymbolGlyph($r('sys.symbol.heart'))
              .fontSize(14)
              .fontColor([c.isLiked ? '#FFE8455E' : MUTED_FG])
            Text(c.score > 0 ? c.score.toString() : '')
              .fontSize(10).fontColor(c.isLiked ? '#FFE8455E' : MUTED_FG)
          }
          .onClick(() => {
            this.toggleCommentLike(c);
          })

          if (c.replyCount > 0) {
            Row({ space: 4 }) {
              SymbolGlyph($r('sys.symbol.chevron_right'))
                .fontSize(10)
                .fontColor([this.expandedReplyId === c.id ? PRIMARY : MUTED_FG])
              Text(`${c.replyCount} 回复`).fontSize(10)
                .fontColor(this.expandedReplyId === c.id ? PRIMARY : MUTED_FG)
            }
            .onClick(() => {
              this.toggleReplyExpansion(c);
            })
          }
        }
        .margin({ top: 2 })

        // 回复列表(展开时显示)
        if (this.expandedReplyId === c.id) {
          if (this.replyLoadingId === c.id) {
            Row({ space: 6 }) {
              LoadingProgress().width(14).height(14).color(PRIMARY)
              Text('加载回复中...').fontSize(10).fontColor(MUTED_FG)
            }
            .width('100%').padding({ left: 8, top: 4 })
          } else {
            Column({ space: 6 }) {
              ForEach(this.replyMap.get(c.id) ?? [], (reply: Comment, rIdx: number) => {
                Row({ space: 8 }) {
                  if (reply.avatar.length > 0) {
                    Image(reply.avatar).width(24).height(24).borderRadius(12)
                      .objectFit(ImageFit.Cover).backgroundColor(GRAY_100)
                  } else {
                    Column().width(24).height(24).borderRadius(12).backgroundColor(GRAY_100)
                  }
                  Column({ space: 2 }) {
                    Text(reply.userName).fontSize(10).fontColor(GRAY_900).fontWeight(FontWeight.Medium)
                      .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
                    Text(reply.content).fontSize(11).fontColor(GRAY_900).lineHeight(16)
                      .width('100%')
                  }
                  .layoutWeight(1).alignItems(HorizontalAlign.Start)
                }
                .width('100%')
              }, (reply: Comment, rIdx: number) => `reply#${rIdx}#${reply.id}`)
            }
            .width('100%').padding({ left: 8, top: 4, bottom: 4 })
            .backgroundColor(GRAY_100).borderRadius(RADIUS_MD)
          }
        }
      }
      .layoutWeight(1).alignItems(HorizontalAlign.Start)
    }
    .width('100%').padding({ top: 10, bottom: 10 })
    .alignItems(VerticalAlign.Top)
  }

  @Builder
  body() {
    Scroll() {
      Column({ space: SPACE_4 }) {
        if (this.hasDetail) {
          this.infoSection(this.detail)
          this.actionRow()
          this.metaRow(this.detail)
        }
        if (this.tagGroups.length > 0) {
          this.tagSection()
        }
        if (this.hasDetail && this.detail.description.length > 0) {
          Column() {
            this.sectionTitle('简介')
            Text(this.detail.description).fontSize(FS_BODY).fontColor(GRAY_900).lineHeight(21)
              .width('100%').margin({ top: SPACE_2 })
          }
          .width('100%').alignItems(HorizontalAlign.Start)
        }
        if (this.chapters.length > 0) {
          this.chapterSection()
        }
        if (this.recommend.length > 0) {
          this.recommendSection()
        }
        if (this.hasDetail) {
          this.commentSection()
        }
      }
      .width('100%').padding({ left: SPACE_3, right: SPACE_3, bottom: SPACE_4 })
      .alignItems(HorizontalAlign.Start)
    }
    .scrollBar(BarState.Off)
    .align(Alignment.Top)
    .width('100%').layoutWeight(1)
  }

  build() {
    Stack() {
      Column() {
      if (this.loading) {
        Column({ space: 10 }) {
          LoadingProgress().width(36).height(36).color(PRIMARY)
          Text('加载中...').fontSize(FS_SMALL).fontColor(MUTED_FG)
        }
        .width('100%').layoutWeight(1).justifyContent(FlexAlign.Center)
      } else if (this.errorMsg.length > 0) {
        Column({ space: 12 }) {
          Text('加载失败').fontSize(FS_SMALL).fontColor(ERROR)
          Text(this.errorMsg).fontSize(FS_SMALL).fontColor(MUTED_FG)
            .maxLines(4).textOverflow({ overflow: TextOverflow.Ellipsis })
            .textAlign(TextAlign.Center).padding({ left: 24, right: 24 })
          Row() {
            Text('重试').fontSize(FS_SMALL).fontColor(CARD)
          }
          .height(32).padding({ left: 16, right: 16 }).borderRadius(16)
          .backgroundColor(PRIMARY).justifyContent(FlexAlign.Center)
          .onClick(() => {
            this.reload();
          })
        }
        .width('100%').layoutWeight(1).justifyContent(FlexAlign.Center)
      } else {
        this.body()
      }
      }
      .width('100%').height('100%').backgroundColor(BG)
    }
    .width('100%').height('100%')
  }
}

/** ComicChapters(扁平或分组) -> 扁平章节项(保留分组信息, 可选倒序) */
function buildChapters(d: ComicDetails, reverse: boolean): ChapterItem[] {
  const out: ChapterItem[] = [];
  if (d.chapters !== null) {
    if (d.chapters.isGrouped()) {
      // 分组结构: 逐组展开, 每组内可倒序, 组间顺序不变
      d.chapters.grouped.forEach((group: Map<string, string>, groupName: string) => {
        const items: ChapterItem[] = [];
        group.forEach((title: string, id: string) => {
          const item = new ChapterItem();
          item.id = id;
          item.title = title;
          item.group = groupName;
          items.push(item);
        });
        if (reverse) {
          items.reverse();
        }
        for (let i = 0; i < items.length; i++) {
          items[i].groupIdx = i;
          out.push(items[i]);
        }
      });
    } else {
      // 扁平结构: 整体可倒序
      const items: ChapterItem[] = [];
      d.chapters.chapters.forEach((title: string, id: string) => {
        const item = new ChapterItem();
        item.id = id;
        item.title = title;
        item.group = '';
        items.push(item);
      });
      if (reverse) {
        items.reverse();
      }
      for (let i = 0; i < items.length; i++) {
        items[i].groupIdx = i;
        out.push(items[i]);
      }
    }
  }
  // 部分源不给章节列表(整本即一章, 如 e-hentai 只返回 maxPage):
  // 按原版语义补一个隐式章节, id 留空 -> 阅读时 ep 传 null
  if (out.length === 0) {
    const item = new ChapterItem();
    item.id = '';
    item.title = '全一話';
    item.group = '';
    item.groupIdx = 0;
    out.push(item);
  }
  return out;
}

/** Map<命名空间, 标签[]> -> 展示用标签(超出上限截断) */
function buildTags(d: ComicDetails): TagItem[] {
  const out: TagItem[] = [];
  d.tags.forEach((values: string[], ns: string) => {
    for (let i = 0; i < values.length; i++) {
      if (out.length >= MAX_TAGS) {
        return;
      }
      const item = new TagItem();
      const v = values[i];
      item.text = ns.length > 0 ? `${ns}: ${v}` : v;
      out.push(item);
    }
  });
  return out;
}
