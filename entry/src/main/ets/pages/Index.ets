/**
 * VeneraNext 导航路由原型
 * 形态选择由 OH_DisplayManager(display 折叠状态) 驱动:
 *   - 竖屏(折叠态/手机): Navigation + TitleBarStyleOptions, 标题栏承载 TAB(书架/发现/设置)
 *   - 横屏(折叠展开/平板): 左侧圆角矩形底框 sidebar, 内含导航按钮
 * 后续再逐页实现内容。
 */
import { BookshelfPage } from './shelf/BookshelfPage';
import { DiscoveryPage } from './discovery/DiscoveryPage';
import { SettingsPage } from './settings/SettingsPage';
import { SearchPage } from './search/SearchPage';
import { DetailPanel } from './comic/DetailPanel';
import { ReaderPage } from './comic/ReaderPage';
import { ShelfItem } from '../model/ShelfItem';
import { ReaderChapter } from '../model/ReaderModel';
import { ensureBookData } from '../utils/FileImporter';
import { PRIMARY, GRAY_500, CARD, BG, FS_SMALL, RADIUS_LG, GRAY_100 } from '../utils/Design';
import { IS_WIDE, WIDTH_BP } from '../utils/Breakpoints';
import { HdsTabs, HdsTabsController, hdsMaterial } from '@kit.UIDesignKit';
import { hilog } from '@kit.PerformanceAnalysisKit';

@Entry
@Component
struct Index {
  @StorageProp(IS_WIDE) isWide: boolean = false;
  @StorageProp(WIDTH_BP) widthBp: string = 'md';
  @State currentIndex: number = 0;
  private tabs: string[] = ['书架', '发现', '设置'];
  @State showSearch: boolean = false;
  // 详情面板状态
  @State detailItemId: string = '';
  @State showDetail: boolean = false;
  // 阅读器状态
  @State showReader: boolean = false;
  @State readerSourceItem: ShelfItem | null = null;
  @State readerChapterStart: number = 0;
  // 真实章节(本地导入书解析结果, 空则阅读器走 demo)
  readerSourceChapter: ReaderChapter | null = null;

  tabSymbol(index: number): Resource {
    if (index === 0) { return $r('sys.symbol.square_grid_2x2'); }
    if (index === 1) { return $r('sys.symbol.magnifyingglass'); }
    return $r('sys.symbol.gearshape');
  }

  // ===== 详情面板控制 =====
  openDetail(item: ShelfItem): void {
    this.detailItemId = item.id;
    this.showDetail = true;
  }

  closeDetail(): void {
    this.showDetail = false;
  }

  async onStartRead(item: ShelfItem, chapter: number): Promise<void> {
    // 本地导入书: 惰性解析章节(持久化恢复后 bookData 为空)
    hilog.info(0, 'Index', 'onStartRead id=%{public}s fmt=%{public}s sandbox=%{public}s',
      item.id, item.fileFormat, item.sandboxPath);
    await ensureBookData(item);
    this.readerSourceItem = item;
    this.readerChapterStart = chapter;
    this.readerSourceChapter = resolveReaderChapter(item, chapter);
    hilog.info(0, 'Index', 'onStartRead chapter null=%{public}s pages=%{public}d',
      (this.readerSourceChapter === null) ? 'y' : 'n',
      this.readerSourceChapter !== null ? this.readerSourceChapter.pages.length : 0);
    this.showDetail = false;
    this.showReader = true;
  }

  /** 详情面板——横屏右侧覆盖层(滑入) */
  @Builder
  landscapeDetailSheet() {
    Column() {
      // 顶部拖拽条
      Row() {
        Column().width(36).height(4).borderRadius(2).backgroundColor(GRAY_100)
      }.width('100%').height(20).justifyContent(FlexAlign.Center)

      DetailPanel({
        itemId: this.detailItemId,
        onStartRead: (it: ShelfItem, ch: number): void => {
          this.onStartRead(it, ch);
        },
        onBack: (): void => this.closeDetail()
      })
      .width('100%').layoutWeight(1)
    }
    .width(360).height('100%').backgroundColor(BG)
    .borderRadius({ topLeft: 20, bottomLeft: 20 })
    .transition(TransitionEffect.OPACITY.combine(TransitionEffect.translate({ x: 360 }))
      .animation({ duration: 280, curve: Curve.EaseOut }))
  }

  /** 详情面板——竖屏底部半模态 */
  @Builder
  portraitDetailSheet() {
    Column() {
      Row() {
        Column().width(36).height(4).borderRadius(2).backgroundColor(GRAY_100)
      }.width('100%').height(20).justifyContent(FlexAlign.Center)

      DetailPanel({
        itemId: this.detailItemId,
        onStartRead: (it: ShelfItem, ch: number): void => {
          this.onStartRead(it, ch);
        },
        onBack: (): void => this.closeDetail()
      })
      .width('100%').layoutWeight(1)
    }
    .width('100%').backgroundColor(BG)
  }

  // ===== 竖屏: HdsTabs 底部悬浮光感页签 =====
  private tabsController: HdsTabsController = new HdsTabsController();

  @Builder
  hdsTab(index: number, label: string, symbol: Resource) {
    Column() {
      SymbolGlyph(symbol).fontSize(24).fontColor([index === this.currentIndex ? PRIMARY : GRAY_500])
      Text(label)
        .fontSize(11)
        .fontWeight(index === this.currentIndex ? FontWeight.Medium : FontWeight.Normal)
        .fontColor(index === this.currentIndex ? PRIMARY : GRAY_500)
        .margin({ top: 2 })
    }
    .width('100%').justifyContent(FlexAlign.Center)
  }

  @Builder
  portraitFrame() {
    HdsTabs({ controller: this.tabsController }) {
      TabContent() {
        BookshelfPage({ onOpenDetail: (it: ShelfItem): void => this.openDetail(it) })
      }.tabBar(this.hdsTab(0, '书架', $r('sys.symbol.square_grid_2x2')))

      TabContent() {
        DiscoveryPage({ onOpenSearch: (): void => { this.showSearch = true; } })
      }.tabBar(this.hdsTab(1, '发现', $r('sys.symbol.magnifyingglass')))

      TabContent() {
        SettingsPage()
      }.tabBar(this.hdsTab(2, '设置', $r('sys.symbol.gearshape')))
    }
    .vertical(false)
    .barPosition(BarPosition.End)
    .barOverlap(true)
    .onChange((index: number) => { this.currentIndex = index; })
    // 底部悬浮 + 沉浸光感材质
    .barFloatingStyle({
      barBottomMargin: 12,
      gradientMask: { maskColor: '#66F1F3F5', maskHeight: 48 },
      systemMaterialEffect: {
        materialType: hdsMaterial.MaterialType.IMMERSIVE,
        materialLevel: hdsMaterial.MaterialLevel.ADAPTIVE
      }
    })
    .width('100%').height('100%')
    // 竖屏: 详情使用底部半模态 bindSheet
    .bindSheet(this.showDetail, this.portraitDetailSheet(), {
      height: 560,
      dragBar: false,
      backgroundColor: Color.Transparent,
      showClose: false,
      onDisappear: (): void => { this.showDetail = false; }
    })
  }

  // ===== 横屏: sidebar 滑动高亮胶囊 =====
  private readonly sideItemHeight: number = 64;
  private readonly sideItemGap: number = 8;
  // 滑块纵向偏移(vp), 随选中项滑动
  @State slideOffset: number = 0;

  /** 第 index 项滑块的纵向偏移 */
  private pillOffset(index: number): number {
    return index * (this.sideItemHeight + this.sideItemGap);
  }

  @Builder
  sideItem(index: number, label: string) {
    Column({ space: 4 }) {
      SymbolGlyph(this.tabSymbol(index))
        .fontSize(22)
        .fontColor([index === this.currentIndex ? CARD : GRAY_500])
      Text(label)
        .fontSize(11)
        .fontColor(index === this.currentIndex ? CARD : GRAY_500)
        .fontWeight(index === this.currentIndex ? FontWeight.Bold : FontWeight.Normal)

    }
    .width('100%').height(this.sideItemHeight).justifyContent(FlexAlign.Center)
    .margin({ bottom: this.sideItemGap })
    .onClick(() => {
      // 平滑滑动高亮胶囊到当前项
      animateTo({ duration: 220, curve: Curve.EaseOut }, () => {
        this.currentIndex = index;
        this.slideOffset = this.pillOffset(index);
      });
    })
  }

  // ===== 横屏: 圆角矩形底框 sidebar(半透明模糊 + 滑动胶囊) =====
  @Builder
  landslidePill() {
    Column()
      .width(56).height(this.sideItemHeight)
      .borderRadius(16)
      .backgroundColor(PRIMARY)
      .shadow({ radius: 6, color: '#33145CDE', offsetY: 2 })
      // 随 slideOffset 滑动
      .position({ x: 8, y: this.slideOffset })
  }

  // ===== 横屏: 右侧内容 =====
  @Builder
  wideContent() {
    Column() {
      if (this.currentIndex === 0) {
        BookshelfPage({ onOpenDetail: (it: ShelfItem): void => this.openDetail(it) })
          .transition(TransitionEffect.OPACITY
            .combine(TransitionEffect.translate({ y: 16 }))
            .animation({ duration: 260, curve: Curve.EaseOut }))
      } else if (this.currentIndex === 1) {
        DiscoveryPage({ onOpenSearch: (): void => { this.showSearch = true; } })
          .transition(TransitionEffect.OPACITY
            .combine(TransitionEffect.translate({ y: 16 }))
            .animation({ duration: 260, curve: Curve.EaseOut }))
      } else {
        SettingsPage()
          .transition(TransitionEffect.OPACITY
            .combine(TransitionEffect.translate({ y: 16 }))
            .animation({ duration: 260, curve: Curve.EaseOut }))
      }
    }
    .width('100%').height('100%')
    .constraintSize({ maxWidth: 1080 })
    .layoutWeight(1)
  }

  // ===== 横屏: 圆角矩形底框 sidebar =====
  @Builder
  landscapeFrame() {
    Row() {
      // 圆角矩形底框侧边导航(半透明模糊材质)
      Column() {
        // Logo
        Row() {
          Text('V').fontSize(20).fontWeight(FontWeight.Bold).fontColor('#FFFFFFFF')
        }.width(44).height(44).borderRadius(22).backgroundColor(PRIMARY)
          .justifyContent(FlexAlign.Center).margin({ top: 20, bottom: 16 })

        // 按钮区 + 滑动高亮胶囊
        Stack({ alignContent: Alignment.TopStart }) {
          // 背景层: 滑动高亮胶囊(在下层, 不遮挡按钮内容)
          this.landslidePill()

          // 前景层: 三个导航按钮(竖向)
          Column() {
            ForEach(this.tabs, (t: string, idx: number) => { this.sideItem(idx, t) }, (t: string) => t)
          }.width('100%')
        }
        .width('100%').height(this.tabs.length * (this.sideItemHeight + this.sideItemGap))
      }
      .width(72).height('88%').borderRadius(24)
      // 半透明模糊材质底框
      .backgroundColor('#B3FFFFFF')
      .backgroundBlurStyle(BlurStyle.COMPONENT_ULTRA_THICK)
      .clip(true)
      .margin({ left: 16, top: 24, bottom: 24 }).alignItems(HorizontalAlign.Center)

      // 内容
      this.wideContent()
    }
    .width('100%').height('100%')
  }

  build() {
    Stack() {
      // 页面内容层: 整体下移 40 避免入侵状态栏
      Stack() {
        if (this.isWide) {
          this.landscapeFrame()
        } else {
          this.portraitFrame()
        }

        // 横屏: 右侧详情覆盖层(带遮罩)
        if (this.isWide && this.showDetail) {
          Row() {
            // 半透明遮罩(点击关闭)
            Column().width('100%').height('100%').backgroundColor('#40000000').layoutWeight(1)
              .onClick(() => { this.closeDetail(); })
            // 右侧详情面板
            this.landscapeDetailSheet()
          }
          .width('100%').height('100%').alignItems(VerticalAlign.Top)
        }

        // 阅读器覆盖层(最高层)
        if (this.showReader && this.readerSourceItem !== null) {
          ReaderPage({
            chapterId: 1,
            externalChapter: this.readerSourceChapter,
            onBack: (): void => {
              this.showReader = false;
              this.readerSourceChapter = null;
            }
          })
          .width('100%').height('100%')
        }
      }
      .width('100%').height('100%')
      .padding({ top: 40 })
      .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.BOTTOM])

      // 搜索覆盖层: 不参与上面的状态栏下移, 以便顶栏材质铺满到屏幕顶端
      if (this.showSearch) {
        SearchPage({ onClose: (): void => { this.showSearch = false; } })
          .width('100%').height('100%')
      }
    }
    .width('100%').height('100%').backgroundColor(BG)
  }
}

/** 从书架条目解析出待阅读章节(本地导入书 bookData; demo 返回 null 走阅读器 demo) */
function resolveReaderChapter(item: ShelfItem, chapterIndex: number): ReaderChapter | null {
  if (item === null || item.bookData === null || item.bookData.length === 0) {
    return null;
  }
  const idx = Math.max(0, Math.min(chapterIndex, item.bookData.length - 1));
  return item.bookData[idx];
}