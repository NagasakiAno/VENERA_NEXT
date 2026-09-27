/**
 * VeneraNext 发现页
 *
 * 对应原版 explore_page.dart: 多源 explore 页聚合为横向 Tab, 每个 Tab 按源声明的
 * 类型渲染(singlePageWithMultiPart / multiPageComicList / mixed),
 * 分页列表支持滚到底自动加载下一页。
 */
import { promptAction, router, ChipGroup, ChipGroupItemOptions, ChipSize, uiMaterial } from '@kit.ArkUI';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { ExplorePageInfo } from '../../model/sources/ComicSourceMeta';
import { exploreService, ExploreBatch, ExploreComic, ExplorePart } from '../../services/ExploreService';
import { PRIMARY, GRAY_100, GRAY_700, GRAY_900,
  CARD, BG, MUTED_FG, ERROR, RADIUS_MD, SPACE_2, SPACE_3, SPACE_4,
  FS_TITLE, FS_SECTION, FS_CAPTION, FS_SMALL } from '../../utils/Design';

const DOMAIN = 0x0000;
const TAG = 'DiscoveryPage';

/**
 * 悬浮顶栏: 标题行 + 发现页选择行。
 * 作为 Navigation 的标题栏渲染, 沉浸式系统材质才在生效范围内。
 */
const TITLE_ROW_H = 56;
const TAB_ROW_H = 48;
const TITLE_BAR_H = TITLE_ROW_H + TAB_ROW_H;

@Component
export struct DiscoveryPage {
  onOpenSearch: () => void = () => {};
  /** 打开在线漫画详情(由窗口根层的 ComicDetailSheet 呈现) */
  onOpenComic: (sourceKey: string, sourceName: string, comicId: string) => void =
    (_s: string, _n: string, _i: string) => {};

  @State pages: ExplorePageInfo[] = [];
  @State currentUid: string = '';
  @State parts: ExplorePart[] = [];
  @State comics: ExploreComic[] = [];
  @State isList: boolean = false;
  @State pageNo: number = 1;
  @State maxPage: number = 1;
  @State loading: boolean = false;
  @State loadingMore: boolean = false;
  @State errorMsg: string = '';
  @State ready: boolean = false;
  /** 发现页选择 ChipGroup */
  @State chipItems: ChipGroupItemOptions[] = [];
  @State chipIndex: number = 0;

  /** 每行格子下标(用于补齐最后一行) */
  private colIndexes: number[] = [0, 1, 2];

  aboutToAppear(): void {
    this.bootstrap().catch((e: Error) => {
      hilog.error(DOMAIN, TAG, '初始化失败: %{public}s', `${e}`);
    });
  }

  private async bootstrap(): Promise<void> {
    this.loading = true;
    this.ready = false;
    try {
      await exploreService.refresh();
    } catch (e) {
      hilog.warn(DOMAIN, TAG, '解析源发现页失败: %{public}s', `${e}`);
    }
    this.pages = exploreService.pages();
    this.rebuildChipItems();
    this.ready = true;
    if (this.pages.length === 0) {
      this.loading = false;
      return;
    }
    await this.loadPage(this.pages[0]);
  }

  /** 发现页选择 ChipGroup 的选项 */
  private rebuildChipItems(): void {
    const items: ChipGroupItemOptions[] = [];
    for (let i = 0; i < this.pages.length; i++) {
      const p = this.pages[i];
      items.push({ label: { text: p.title.length > 0 ? p.title : p.sourceName } });
    }
    this.chipItems = items;
    this.chipIndex = this.indexOfUid(this.currentUid);
  }

  private indexOfUid(uid: string): number {
    for (let i = 0; i < this.pages.length; i++) {
      if (this.pages[i].uid() === uid) {
        return i;
      }
    }
    return 0;
  }

  private currentPage(): ExplorePageInfo | null {
    for (let i = 0; i < this.pages.length; i++) {
      if (this.pages[i].uid() === this.currentUid) {
        return this.pages[i];
      }
    }
    return null;
  }

  /** 加载某一页(切换 Tab 或刷新) */
  private async loadPage(page: ExplorePageInfo): Promise<void> {
    this.currentUid = page.uid();
    this.chipIndex = this.indexOfUid(this.currentUid);
    this.loading = true;
    this.errorMsg = '';
    this.parts = [];
    this.comics = [];
    this.pageNo = 1;
    this.maxPage = 1;
    this.isList = false;
    try {
      const batch = await exploreService.load(page, 1);
      this.applyBatch(batch, false);
    } catch (e) {
      this.errorMsg = `${e}`;
      hilog.error(DOMAIN, TAG, '加载 %{public}s 失败: %{public}s', page.title, `${e}`);
    } finally {
      this.loading = false;
    }
  }

  /** 加载下一页(平铺列表型) */
  private async loadMore(): Promise<void> {
    if (this.loading || this.loadingMore || !this.isList) {
      return;
    }
    if (this.pageNo >= this.maxPage) {
      return;
    }
    const page = this.currentPage();
    if (page === null) {
      return;
    }
    this.loadingMore = true;
    try {
      const batch = await exploreService.load(page, this.pageNo + 1);
      this.applyBatch(batch, true);
    } catch (e) {
      hilog.warn(DOMAIN, TAG, '加载下一页失败: %{public}s', `${e}`);
    } finally {
      this.loadingMore = false;
    }
  }

  private applyBatch(batch: ExploreBatch, append: boolean): void {
    if (batch.isList) {
      this.isList = true;
      this.comics = append ? this.comics.concat(batch.comics) : batch.comics;
      this.maxPage = batch.maxPage > 0 ? batch.maxPage : 1;
      this.pageNo = append ? this.pageNo + 1 : 1;
    } else {
      this.isList = false;
      this.parts = append ? this.parts.concat(batch.parts) : batch.parts;
    }
  }

  private refreshCurrent(): void {
    const page = this.currentPage();
    if (page === null) {
      return;
    }
    this.loadPage(page).catch((e: Error) => {
      hilog.error(DOMAIN, TAG, '刷新失败: %{public}s', `${e}`);
    });
  }

  /** 漫画按行分组 */
  private rowsOf(comics: ExploreComic[]): ExploreComic[][] {
    const cols = this.colIndexes.length;
    const rows: ExploreComic[][] = [];
    for (let i = 0; i < comics.length; i += cols) {
      rows.push(comics.slice(i, i + cols));
    }
    return rows;
  }

  private openComic(c: ExploreComic): void {
    if (c.id.length === 0) {
      return;
    }
    this.onOpenComic(c.sourceKey, c.sourceName, c.id);
  }

  /** 打开分类页 */
  private openCategories(): void {
    router.pushUrl({ url: 'pages/category/CategoriesPage' })
      .catch((e: Error) => {
        hilog.error(DOMAIN, TAG, '打开分类页失败: %{public}s', `${e}`);
      });
  }

  // ---------------------------------------------------------------- UI

  @Builder
  comicCell(c: ExploreComic) {
    Column() {
      if (c.cover.length > 0) {
        Image(c.cover)
          .width('100%')
          .aspectRatio(0.72)
          .objectFit(ImageFit.Cover)
          .borderRadius(RADIUS_MD)
          .backgroundColor(GRAY_100)
      } else {
        Column()
          .width('100%').aspectRatio(0.72)
          .borderRadius(RADIUS_MD).backgroundColor(GRAY_100)
      }
      Text(c.title.length > 0 ? c.title : c.id)
        .fontSize(FS_SMALL).fontColor(GRAY_900)
        .maxLines(2).textOverflow({ overflow: TextOverflow.Ellipsis })
        .margin({ top: 6 })
    }
    .layoutWeight(1)
    .onClick(() => {
      this.openComic(c);
    })
  }

  @Builder
  comicRow(row: ExploreComic[]) {
    Row({ space: 8 }) {
      ForEach(this.colIndexes, (ci: number) => {
        if (ci < row.length) {
          this.comicCell(row[ci])
        } else {
          Column().layoutWeight(1)
        }
      }, (ci: number) => `${ci}`)
    }
    .width('100%')
  }

  @Builder
  partBlock(part: ExplorePart) {
    Column({ space: 8 }) {
      if (part.title.length > 0) {
        Row({ space: 6 }) {
          Column().width(3).height(14).borderRadius(2).backgroundColor(PRIMARY)
          Text(part.title).fontSize(FS_SECTION).fontWeight(FontWeight.Bold).fontColor(GRAY_900)
            .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis }).layoutWeight(1)
        }
        .alignItems(VerticalAlign.Center)
      }
      ForEach(this.rowsOf(part.comics), (row: ExploreComic[], ri: number) => {
        this.comicRow(row)
      }, (row: ExploreComic[], ri: number) => `${part.title}#${ri}`)
    }
    .width('100%')
  }

  @Builder
  emptyState(title: string, hint: string) {
    Column({ space: 8 }) {
      Text(title).fontSize(FS_SECTION).fontColor(GRAY_900)
      Text(hint).fontSize(FS_SMALL).fontColor(MUTED_FG)
        .textAlign(TextAlign.Center).padding({ left: 32, right: 32 })
    }
    .width('100%').layoutWeight(1).justifyContent(FlexAlign.Center)
  }

  /**
   * 悬浮顶栏: 标题行(发现 + 刷新/分类/搜索) + 发现页选择行。
   * 作为 Navigation 标题栏渲染, 沉浸式系统材质生效; 高度固定保证材质区域稳定。
   */
  @Builder
  discoveryTitleBar() {
    Column() {
      Row() {
        Text('发现').fontSize(FS_TITLE).fontWeight(FontWeight.Bold).fontColor(GRAY_900)
        Blank()
        Row() {
          SymbolGlyph($r('sys.symbol.arrow_clockwise')).fontSize(18).fontColor([GRAY_900])
        }
        .width(40).height(40).justifyContent(FlexAlign.Center).borderRadius(20)
        .backgroundColor(Color.Transparent)
        .systemMaterial(new uiMaterial.ImmersiveMaterial({ interactive: true }))
        .onClick(() => {
          this.refreshCurrent();
        })
        Row() {
          SymbolGlyph($r('sys.symbol.square_grid_2x2')).fontSize(18).fontColor([GRAY_900])
        }
        .width(40).height(40).justifyContent(FlexAlign.Center).borderRadius(20)
        .backgroundColor(Color.Transparent)
        .systemMaterial(new uiMaterial.ImmersiveMaterial({ interactive: true }))
        .margin({ left: SPACE_2 })
        .onClick(() => {
          this.openCategories();
        })
        Row() {
          SymbolGlyph($r('sys.symbol.magnifyingglass')).fontSize(18).fontColor([GRAY_900])
        }
        .width(40).height(40).justifyContent(FlexAlign.Center).borderRadius(20)
        .backgroundColor(Color.Transparent)
        .systemMaterial(new uiMaterial.ImmersiveMaterial({ interactive: true }))
        .margin({ left: SPACE_2 })
        .onClick(() => {
          this.onOpenSearch();
        })
      }
      .width('100%').height(TITLE_ROW_H)
      .alignItems(VerticalAlign.Center)

      Row() {
        ChipGroup({
          items: this.chipItems,
          itemStyle: {
            size: ChipSize.SMALL,
            backgroundColor: Color.Transparent,
            selectedBackgroundColor: Color.Transparent,
            fontColor: GRAY_900,
            selectedFontColor: CARD
          },
          chipGroupPadding: { top: 6, bottom: 6 },
          chipGroupSpace: { startSpace: 12, endSpace: 12, itemSpace: 8 },
          selectedIndexes: [this.chipIndex],
          backgroundSystemMaterial: new uiMaterial.ImmersiveMaterial({
            interactive: true
          }),
          selectedBackgroundSystemMaterial: new uiMaterial.ImmersiveMaterial({
            materialColor: '#B3145CDE',
            interactive: true
          }),
          onChange: (indexes: number[]) => {
            if (indexes.length === 0 || indexes[0] >= this.pages.length) {
              return;
            }
            const target = this.pages[indexes[0]];
            if (target.uid() === this.currentUid) {
              return;
            }
            this.chipIndex = indexes[0];
            this.loadPage(target).catch((e: Error) => {
              hilog.error(DOMAIN, TAG, '切换发现页失败: %{public}s', `${e}`);
            });
          }
        })
          .layoutWeight(1)
      }
      .width('100%').alignItems(VerticalAlign.Center)
    }
    .width('100%')
    .height(TITLE_BAR_H)
    .padding({ left: SPACE_3, right: SPACE_3, bottom: SPACE_2 })
    .justifyContent(FlexAlign.Center)
    // 让材质条延伸到状态栏/挖孔等系统区域, 横屏时右侧不会被截断
    .expandSafeArea([SafeAreaType.SYSTEM])
  }

  @Builder
  content() {
    List() {
      if (this.errorMsg.length > 0) {
        ListItem() {
          Column({ space: 8 }) {
            Text('加载失败').fontSize(FS_CAPTION).fontColor(ERROR)
            Text(this.errorMsg).fontSize(FS_SMALL).fontColor(MUTED_FG)
              .maxLines(4).textOverflow({ overflow: TextOverflow.Ellipsis })
              .textAlign(TextAlign.Center)
            Row() {
              Text('重试').fontSize(FS_SMALL).fontColor(CARD)
            }
            .height(32).padding({ left: 18, right: 18 }).borderRadius(16)
            .backgroundColor(PRIMARY).justifyContent(FlexAlign.Center)
            .onClick(() => {
              this.refreshCurrent();
            })
          }
          .width('100%').padding({ top: SPACE_4, bottom: SPACE_4 }).justifyContent(FlexAlign.Center)
        }
      } else if (this.isList) {
        ForEach(this.rowsOf(this.comics), (row: ExploreComic[], ri: number) => {
          ListItem() {
            this.comicRow(row)
          }
          .padding({ bottom: 10 })
        }, (row: ExploreComic[], ri: number) => `list#${ri}`)
      } else {
        ForEach(this.parts, (part: ExplorePart, pi: number) => {
          ListItem() {
            this.partBlock(part)
          }
          .padding({ bottom: SPACE_2 })
        }, (part: ExplorePart, pi: number) => `${this.currentUid}#part#${pi}`)
      }

      // 底部状态
      ListItem() {
        Column() {
          if (this.loadingMore) {
            Row({ space: 8 }) {
              LoadingProgress().width(18).height(18).color(PRIMARY)
              Text('加载中...').fontSize(FS_SMALL).fontColor(MUTED_FG)
            }
          } else if (this.isList && this.pageNo >= this.maxPage && this.comics.length > 0) {
            Text('没有更多了').fontSize(FS_SMALL).fontColor(MUTED_FG)
          } else if (this.isList && this.comics.length > 0) {
            Text('上拉加载更多').fontSize(FS_SMALL).fontColor(MUTED_FG)
              .onClick(() => {
                this.loadMore();
              })
          }
        }
        .width('100%').height(48).justifyContent(FlexAlign.Center)
      }
    }
    .scrollBar(BarState.Off)
    .align(Alignment.Top)
    .contentStartOffset(TITLE_BAR_H)
    .width('100%').layoutWeight(1)
    .padding({ left: SPACE_3, right: SPACE_3 })
    .onReachEnd(() => {
      this.loadMore();
    })
  }

  build() {
    Stack() {
      // 顶栏交给 Navigation 的标题栏渲染: 沉浸式系统材质只在标题栏子树中生效,
      // STACK 模式让内容区延伸到标题栏下方, 形成透底的悬浮效果。
      Navigation() {
        Column() {
          if (this.loading) {
            Column({ space: 10 }) {
              LoadingProgress().width(36).height(36).color(PRIMARY)
              Text('加载中...').fontSize(FS_SMALL).fontColor(MUTED_FG)
            }
            .width('100%').layoutWeight(1).justifyContent(FlexAlign.Center)
          } else if (!this.ready) {
            Column().width('100%').layoutWeight(1)
          } else if (this.pages.length === 0) {
            this.emptyState('暂无发现页',
              '请先安装漫画源；若源已安装但没有发现页，可在源详情中查看其能力。')
          } else {
            this.content()
          }
        }
        .width('100%').height('100%')
      }
      .hideBackButton(true)
      .hideToolBar(true)
      .mode(NavigationMode.Stack)
      .title({ builder: this.discoveryTitleBar, height: TITLE_BAR_H }, {
        barStyle: BarStyle.STACK,
        systemMaterial: new uiMaterial.ImmersiveMaterial({})
      })
      .width('100%').height('100%')
      .backgroundColor(BG)
      // 横屏时让材质条延伸到左右安全区, 不被截断
      .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.START, SafeAreaEdge.END])
    }
    .width('100%').height('100%')
  }
}
