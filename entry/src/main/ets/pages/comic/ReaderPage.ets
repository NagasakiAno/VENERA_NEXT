/**
 * VeneraNext 阅读器
 * 兼容本地/Web 归一化页面(文本页/图片页), PDF/EPUB/MOBI 解析后续接入
 * 设计要点:
 *  - 滚动 / 翻页(Swiper) 双模式
 *  - 竖屏: 单页, 图片铺满显示 + 模糊背景填充空白(消除黑边)
 *  - 横屏(宽高比>1.3): Swiper.displayCount=2 左右分栏并排, 点击左右区翻页
 *  - 底部控制: 右下角悬浮小tabbar显示页码, 底部90px触摸热区可呼出
 *    -> 点击弹出 CustomDialog 设置弹窗(原生沉浸光感): 页码轮盘/翻页切换/文本背景
 *  - 文本页可调背景
 *  - 长宽比判定独立于折叠开合(阔折叠/平板竖握仍走竖屏逻辑)
 */
import { ReaderChapter, ReaderPageItem, ReaderPageType } from '../../model/ReaderModel';
import { image } from '@kit.ImageKit';
import { vibrator } from '@kit.SensorServiceKit';
import { uiMaterial } from '@kit.ArkUI';
import { webview } from '@kit.ArkWeb';
import { fileIo as fs } from '@kit.CoreFileKit';
import { util } from '@kit.ArkTS';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { GRAY_900 } from '../../utils/Design';

// 沉浸光感材质(薄档: 最大限度保留背景透出的毛玻璃感)
const READER_MATERIAL = new uiMaterial.ImmersiveMaterial({
  style: uiMaterial.ImmersiveStyle.ULTRA_THIN,
  interactive: true,
  lightEffect: { color: undefined }
});

const DOMAIN = 0x0000;
const TAG = 'ReaderPage';

// ===== 阅读设置弹窗(原生沉浸光感) =====
@CustomDialog
struct ReaderSettingsDialog {
  controller?: CustomDialogController;
  currentPage: number = 0;
  totalPages: number = 1;
  mode: number = 1;
  isLandscape: boolean = false;
  isImage: boolean = false;
  isRich: boolean = false;
  bgColors: string[] = [];
  bgIndex: number = 0;
  onBack: () => void = () => {};
  onPageChange: (i: number) => void = () => {};
  onModeChange: (m: number) => void = () => {};
  onBgChange: (i: number) => void = () => {};

  private opts(): string[] {
    const n = Math.max(1, this.totalPages);
    const a: string[] = [];
    for (let i = 0; i < n; i++) {
      a.push((i + 1) + '');
    }
    return a;
  }

  // 页码轮盘
  @Builder
  wheel() {
    Row() {
      Text('页码').fontSize(13).fontColor('#B3FFFFFF')
      TextPicker({
        range: this.opts(),
        selected: this.currentPage
      })
      .width(96).height(120)
      .defaultPickerItemHeight(36)
      .textStyle({ color: '#B3FFFFFF', font: { size: 26 } })
      .selectedTextStyle({ color: '#FF145CDE', font: { size: 32 } })
      .onChange((v: string | string[], idx: number | number[]) => {
        const i: number = Array.isArray(idx) ? idx[0] : idx;
        if (i >= 0) {
          this.onPageChange(i);
        }
      })
      Text(' / ' + this.totalPages).fontSize(15).fontColor('#FFFFFFFF')
    }
    .width('100%').justifyContent(FlexAlign.Center)
  }

  // 文本背景(仅纯文本页)
  @Builder
  bgRow() {
    if (!this.isImage && !this.isRich) {
      Row({ space: 12 }) {
        ForEach(this.bgColors, (c: string, idx: number) => {
          Column()
            .width(30).height(30).borderRadius(15)
            .backgroundColor(c)
            .border({ width: idx === this.bgIndex ? 3 : 1,
              color: idx === this.bgIndex ? '#FF145CDE' : '#80FFFFFF' })
            .onClick(() => { this.onBgChange(idx); })
        }, (c: string) => c)
      }.width('100%').justifyContent(FlexAlign.Center).margin({ top: 8 })
    }
  }

  build() {
    Column() {
      // 顶部: 返回 / 标题 / 模式切换(竖屏) / 关闭
      Row() {
        Row() {
          SymbolGlyph($r('sys.symbol.chevron_left')).fontSize(18).fontColor(['#FFFFFFFF'])
        }
        .width(34).height(34).borderRadius(17).backgroundColor('#26FFFFFF')
        .justifyContent(FlexAlign.Center)
        .onClick(() => { this.controller?.close(); this.onBack(); })

        Text('阅读设置').fontSize(15).fontColor('#FFFFFFFF').layoutWeight(1).textAlign(TextAlign.Center)

        // 模式切换(富文本固定翻页, 不显示)
        if (!this.isLandscape && !this.isRich) {
          Row() {
            Text(this.mode === 1 ? '翻页' : '滚动').fontSize(14).fontColor('#FFFFFFFF')
          }
          .height(32).padding({ left: 14, right: 14 }).borderRadius(16)
          .backgroundColor('#26FFFFFF')
          .onClick(() => { this.onModeChange(this.mode === 1 ? 0 : 1); })
        }

        Row() {
          SymbolGlyph($r('sys.symbol.arrow_down')).fontSize(18).fontColor(['#FFFFFFFF'])
        }
        .width(34).height(34).borderRadius(17).backgroundColor('#26FFFFFF')
        .justifyContent(FlexAlign.Center)
        .margin({ left: 8 })
        .onClick(() => { this.controller?.close(); })
      }
      .width('100%').height(44).padding({ left: 12, right: 8 })

      this.wheel()
      this.bgRow()
    }
    .width('100%').padding({ top: 8, bottom: 16 })
    .borderRadius(20)
  }
}

@Component
export struct ReaderPage {
  @Prop chapterId: number = 1;
  // 外部传入的真实章节(本地导入书解析结果); 为空则显示占位
  @Prop @Watch('onChapterSwitched') externalChapter: ReaderChapter | null = null;
  /** 是否存在上一/下一章(控制切章按钮显隐) */
  @Prop hasPrevChapter: boolean = false;
  @Prop hasNextChapter: boolean = false;
  /** 请求切章: delta = -1 上一话 / 1 下一话; 返回是否切换成功 */
  onSwitchChapter: (delta: number) => Promise<boolean> = async () => false;
  /** 首章打开时跳到的页码(0 基), 用于恢复阅读进度 */
  initialPage: number = 0;
  /** 页码变化回调(用于记录阅读进度) */
  onProgress: (page: number, total: number) => void = () => {};
  /**
   * 网络章节的按页加载器(带源声明的请求头 / 图片还原)。
   * 页面内 image 为空串时按页调它取 PixelMap, 返回 null 表示该页加载失败。
   */
  remoteLoader: (index: number) => Promise<image.PixelMap | null> = async () => null;
  onBack: () => void = () => {};

  @State chapter: ReaderChapter = new ReaderChapter(0, '', []);
  @State curPage: number = 0;
  /** 网络章节: 下标 -> 已解码的图片(未加载为 undefined, 失败为 null) */
  @State pageMaps: (image.PixelMap | null)[] = [];
  private loadingPages: Set<number> = new Set<number>();
  /** 正在切章, 避免重复触发 */
  private switching: boolean = false;
  @State mode: number = 1;          // 0=滚动 1=翻页
  @State isLandscape: boolean = false;
  @State isImage: boolean = false;
  @State winW: number = 390;
  @State winH: number = 640;
  private bgColors: string[] = ['#FFF5F0', '#FFFDF0', '#FFFFFF', '#F0F5FF', '#2A2A2A'];
  @State bgIndex: number = 0;

  private swiperCtrl: SwiperController = new SwiperController();
  private scrollCtrl: Scroller = new Scroller();
  // 每个 RICH 页独立 WebController(按需创建, 懒加载)
  private richControllers: webview.WebviewController[] = [];

  /** 懒获取第 idx 个 RICH 页的 WebController(Web 构造参数表达式调用) */
  private getRichController(idx: number): webview.WebviewController {
    while (this.richControllers.length <= idx) {
      this.richControllers.push(new webview.WebviewController());
    }
    return this.richControllers[idx];
  }

  private settingsCtrl: CustomDialogController = new CustomDialogController({
    builder: ReaderSettingsDialog({
      currentPage: this.curPage,
      totalPages: this.maxPage(),
      mode: this.mode,
      isLandscape: this.isLandscape,
      isImage: this.isImage,
      isRich: this.isRichChapter(),
      bgColors: this.bgColors,
      bgIndex: this.bgIndex,
      onPageChange: (i: number) => { this.goPage(i); },
      onModeChange: (m: number) => { this.mode = m; this.haptic(); this.settingsCtrl.close(); },
      onBgChange: (i: number) => { this.bgIndex = i; this.haptic(); },
      onBack: () => { this.onBack(); }
    }),
    autoCancel: true,
    alignment: DialogAlignment.Bottom,
    backgroundColor: '#001A1A1E',
    systemMaterial: READER_MATERIAL
  });

  aboutToAppear(): void {
    if (this.externalChapter !== null && this.externalChapter.pages.length > 0) {
      // 真实导入章节优先(本地书/富文本)
      this.chapter = this.externalChapter;
      const first = this.externalChapter.pages[0];
      this.isImage = first.type === ReaderPageType.IMAGE;
      // 富文本每章一页, 走 Swiper 翻页(Web 内部滚动), 避免 List 中大量 Web 组件卡顿
      this.mode = first.type === ReaderPageType.RICH ? 1 : this.mode;
      // 恢复上次阅读到的页码
      this.curPage = Math.max(0, Math.min(this.externalChapter.pages.length - 1, this.initialPage));
      // 网络章节: 先加载首屏 3 页
      this.ensureRange(this.curPage, 3);
      this.onProgress(this.curPage, this.externalChapter.pages.length);
      return;
    }
    // 无外部章节(理论不发生): 占位说明页, 不展示 demo 内容
    const html = '<html><head><meta name="viewport" content="width=device-width,initial-scale=1.0">' +
      '<style>body{font-family:sans-serif;padding:24px;color:#333;line-height:1.8}</style></head>' +
      '<body><p>（无可用内容）</p></body></html>';
    this.chapter = new ReaderChapter(1, '无内容',
      [new ReaderPageItem(ReaderPageType.RICH, 0, '', '', html, '', '')]);
    this.isImage = false;
    this.mode = 1;
    this.curPage = 0;
  }

  private haptic(): void {
    try {
      vibrator.startVibration({ type: 'time', duration: 18 }, { id: 0, usage: 'touch' });
    } catch (e) {
      // 静默
    }
  }

  private maxPage(): number {
    return Math.max(1, this.chapter.pages.length);
  }

  // ===== 网络章节: 按页懒加载 =====

  /** 该页是否需要走网络加载(图片字段为空的图片页) */
  private isRemotePage(pg: ReaderPageItem): boolean {
    if (pg.type !== ReaderPageType.IMAGE) {
      return false;
    }
    return typeof pg.image === 'string' && (pg.image as string).length === 0;
  }

  /** 确保 [from, from+count) 区间的页面已加载 */
  private ensureRange(from: number, count: number): void {
    const total = this.chapter.pages.length;
    for (let i = from; i < from + count; i++) {
      if (i < 0 || i >= total) {
        continue;
      }
      const pg = this.chapter.pages[i];
      if (!this.isRemotePage(pg)) {
        continue;
      }
      if (this.pageMaps[i] !== undefined || this.loadingPages.has(i)) {
        continue;
      }
      this.loadRemotePage(i);
    }
  }

  private loadRemotePage(idx: number): void {
    this.loadingPages.add(idx);
    this.remoteLoader(idx)
      .then((pm: image.PixelMap | null) => {
        this.pageMaps[idx] = pm;
        this.loadingPages.delete(idx);
        this.pageMaps = this.pageMaps.slice();
      })
      .catch((e: Error) => {
        hilog.warn(DOMAIN, TAG, '第 %{public}d 页加载失败: %{public}s', idx, `${e}`);
        this.pageMaps[idx] = null;
        this.loadingPages.delete(idx);
        this.pageMaps = this.pageMaps.slice();
      });
  }

  // ===== 跨章连续阅读 =====

  /** 外部切换章节: 重置本页状态并加载新章首屏 */
  private onChapterSwitched(): void {
    const ext = this.externalChapter;
    if (ext === null || ext.pages.length === 0) {
      return;
    }
    this.chapter = ext;
    this.pageMaps = [];
    this.loadingPages.clear();
    this.isImage = ext.pages[0].type === ReaderPageType.IMAGE;
    this.curPage = 0;
    this.swiperCtrl.changeIndex(0);
    this.scrollCtrl.scrollEdge(Edge.Top);
    this.ensureRange(0, 3);
    // 章节变了, 进度从头开始
    this.onProgress(0, ext.pages.length);
  }

  /** 请求切章(上一次/下一次); 到边界或失败时什么都不做 */
  private switchChapter(delta: number): void {
    if (this.switching) {
      return;
    }
    const can = delta < 0 ? this.hasPrevChapter : this.hasNextChapter;
    if (!can) {
      return;
    }
    this.switching = true;
    this.onSwitchChapter(delta)
      .then((ok: boolean) => {
        if (!ok) {
          hilog.warn(DOMAIN, TAG, '切换章节失败 delta=%{public}d', delta);
        }
      })
      .catch((e: Error) => {
        hilog.warn(DOMAIN, TAG, '切换章节异常: %{public}s', `${e}`);
      })
      .finally(() => {
        this.switching = false;
      });
  }

  /** 当前章节是否富文本(EPUB 一章一页) */
  private isRichChapter(): boolean {
    return this.chapter.pages.length > 0 && this.chapter.pages[0].type === ReaderPageType.RICH;
  }

  private goPage(p: number): void {
    const t = Math.max(0, Math.min(this.maxPage() - 1, p));
    if (t === this.curPage) {
      return;
    }
    this.curPage = t;
    this.ensureRange(t - 1, 4);
    this.onProgress(t, this.chapter.pages.length);
    this.haptic();
  }

  private openSettings(): void {
    this.settingsCtrl.open();
  }

  private touchX: number = 0;
  private touchY: number = 0;
  private swiped: boolean = false;

  // 统一点击+左右滑动翻页处理 (zone: 0=左 1=中 2=右)
  private handleTap(e: TouchEvent, zone: number): void {
    if (e.type === TouchType.Down) {
      this.touchX = e.touches[0].x;
      this.touchY = e.touches[0].y;
      this.swiped = false;
    } else if (e.type === TouchType.Move) {
      const dx = e.touches[0].x - this.touchX;
      const dy = e.touches[0].y - this.touchY;
      if (!this.swiped && Math.abs(dx) > 40 && Math.abs(dx) > Math.abs(dy)) {
        this.swiped = true;
        if (dx < 0) {
          this.goPage(this.curPage + 1);
        } else {
          this.goPage(this.curPage - 1);
        }
      }
    } else if ((e.type === TouchType.Up || e.type === TouchType.Cancel) && !this.swiped) {
      // 点击: 左上一页 / 中无操作(设置仅由tabbar呼出) / 右下一页; 到头则切章
      if (zone === 0) {
        if (this.curPage === 0) {
          this.switchChapter(-1);
        } else {
          this.goPage(this.curPage - 1);
        }
      } else if (zone === 2) {
        if (this.curPage >= this.maxPage() - 1) {
          this.switchChapter(1);
        } else {
          this.goPage(this.curPage + 1);
        }
      }
    }
  }

  // ===== 图片页: 铺满 + 模糊背景 =====
  @Builder
  imagePage(item: ReaderPageItem, blur: boolean, idx: number) {
    if (this.isRemotePage(item) && (this.pageMaps[idx] === undefined || this.pageMaps[idx] === null)) {
      // 网络章节: 未加载完成(或失败)时的占位
      Column({ space: 8 }) {
        if (this.pageMaps[idx] === null) {
          Text('这一页加载失败').fontSize(13).fontColor('#FF909399')
        } else {
          LoadingProgress().width(28).height(28).color('#FF909399')
        }
      }
      .width('100%')
      .height(this.winH)
      .justifyContent(FlexAlign.Center)
      .backgroundColor('#FF000000')
    } else if (!blur) {
      // 滚动模式: 图宽满屏, 高度自适应, 首尾相接无模糊
      Image(this.pageImageSource(item, idx)).width('100%')
        .objectFit(ImageFit.Contain).backgroundColor('#FF000000')
    } else {
      // 翻页模式: 前景尽量完整(contain), 空白用当前页模糊填充(cover本身已填满, 无需scale)
      Stack() {
        Image(this.pageImageSource(item, idx)).width('100%').height('100%')
          .objectFit(ImageFit.Cover).blur(30)
        Image(this.pageImageSource(item, idx)).width('100%').height('100%').objectFit(ImageFit.Contain)
      }
      .width('100%').height('100%').backgroundColor('#FF000000')
    }
  }

  /** 优先用已加载的网络位图, 否则用页面自带的本地图片 */
  private pageImageSource(item: ReaderPageItem, idx: number): image.PixelMap | Resource | string {
    const pm = idx < this.pageMaps.length ? this.pageMaps[idx] : undefined;
    if (pm !== undefined && pm !== null) {
      return pm;
    }
    return item.image as Resource | string;
  }

  // ===== 文本页: scrollable=true 供翻页单页滚动, false 由外层List滚动 =====
  @Builder
  textPage(item: ReaderPageItem, scrollable: boolean) {
    if (scrollable) {
      Scroll(this.scrollCtrl) {
        Column() {
          this.textContent(item)
        }
        .width('100%').padding({ left: 24, right: 24 })
      }
      .scrollable(ScrollDirection.Vertical).scrollBar(BarState.Off)
      .width('100%').height('100%').backgroundColor(this.bgColors[this.bgIndex])
    } else {
      Column() {
        this.textContent(item)
      }
      .width('100%').padding({ left: 24, right: 24 }).backgroundColor(this.bgColors[this.bgIndex])
    }
  }

  @Builder
  textContent(item: ReaderPageItem) {
    Text(item.text).fontSize(17).lineHeight(28).fontColor(GRAY_900)
      .width('100%').margin({ top: 36, bottom: 40 })
  }

  // ===== 富文本页(RICH): Web 组件按原格式渲染, 章节内由 Web 内部滚动 =====
  // 显示修复: 注入 viewport meta 防止无 viewport 的 EPUB 以 980px 渲染导致内容只显示左上角
  // 性能: 按需 loadData 当前章, 不预读全书
  @Builder
  richPage(item: ReaderPageItem) {
    Web({ src: 'about:blank', controller: this.getRichController(item.index) })
      .width('100%').height('100%')
      .backgroundColor('#FFFFFFFF')
      .javaScriptAccess(true)
      .fileAccess(true)
      .onPageEnd(() => { this.loadRich(item); })
  }

  /** 富文本是否已加载(防 onPageEnd 重复加载) */
  private richLoaded: boolean[] = [];

  /** 按需加载富文本章节(注入 viewport 后 loadData) */
  private loadRich(item: ReaderPageItem): void {
    const idx = item.index;
    if (idx < this.richLoaded.length && this.richLoaded[idx]) {
      return;
    }
    while (this.richLoaded.length <= idx) {
      this.richLoaded.push(false);
    }
    try {
      const ctrl = this.getRichController(idx);
      let html = item.html;
      let baseUrl = item.baseUrl;
      if (item.filePath.length > 0) {
        html = this.readSandboxText(item.filePath);
        const dir = item.filePath.substring(0, item.filePath.lastIndexOf('/'));
        baseUrl = 'file://' + dir + '/';
      }
      hilog.info(0, 'ReaderPage', 'loadRich idx=%{public}d htmlLen=%{public}d path=%{public}s',
        idx, html.length, item.filePath);
      if (html.length > 0) {
        ctrl.loadData(this.injectViewport(html), 'text/html', 'utf-8', baseUrl);
        this.richLoaded[idx] = true;
      }
    } catch (e) {
      hilog.error(0, 'ReaderPage', 'loadRich fail %{public}s', JSON.stringify(e));
    }
  }

  /** 注入 viewport meta, 保证手机宽度渲染 */
  private injectViewport(html: string): string {
    if (html.indexOf('name="viewport"') >= 0 || html.indexOf("name='viewport'") >= 0) {
      return html;
    }
    return '<meta name="viewport" content="width=device-width, initial-scale=1.0, maximum-scale=2.0">' + html;
  }

  /** 读取沙箱文本文件(富文本章节正文, 按需读) */
  private readSandboxText(path: string): string {
    try {
      if (!fs.accessSync(path)) {
        return '';
      }
      const f = fs.openSync(path, fs.OpenMode.READ_ONLY);
      const stat = fs.statSync(f.fd);
      const buf = new ArrayBuffer(stat.size);
      fs.readSync(f.fd, buf);
      fs.closeSync(f);
      const decoder = util.TextDecoder.create('utf-8');
      return decoder.decodeToString(new Uint8Array(buf));
    } catch (e) {
      return '';
    }
  }

  // ===== 翻页模式内容 =====
  @Builder
  swiperContent() {
    Swiper(this.swiperCtrl) {
      ForEach(this.chapter.pages, (pg: ReaderPageItem, idx: number) => {
        Column() {
          if (pg.type === ReaderPageType.IMAGE) {
            this.imagePage(pg, true, idx)
          } else if (pg.type === ReaderPageType.RICH) {
            this.richPage(pg)
          } else {
            this.textPage(pg, true)
          }
        }
        .width('100%').height('100%')
      }, (pg: ReaderPageItem) => pg.index + '_' + pg.type)
    }
    .index(this.curPage)
    .indicator(false)
    .loop(false)
    .displayCount(this.isLandscape && !this.isRichChapter() ? 2 : 1)
    .onChange((i: number) => {
      this.curPage = i;
      this.ensureRange(i - 1, 4);
      this.onProgress(i, this.chapter.pages.length);
    })
    .width('100%').height('100%')
    .backgroundColor('#FF000000')
  }

  // ===== 滚动模式内容 =====
  @Builder
  scrollContent() {
    List({ scroller: this.scrollCtrl }) {
      ForEach(this.chapter.pages, (pg: ReaderPageItem, idx: number) => {
        ListItem() {
          if (pg.type === ReaderPageType.IMAGE) {
            this.imagePage(pg, false, idx)
          } else if (pg.type === ReaderPageType.RICH) {
            this.richPage(pg)
          } else {
            this.textPage(pg, false)
          }
        }
      }, (pg: ReaderPageItem) => pg.index + '_' + pg.type)
    }
    .listDirection(Axis.Vertical)
    .scrollBar(BarState.Off)
    // 滚动模式: 按可见区间懒加载网络章节图片
    .onScrollIndex((start: number, end: number) => {
      this.ensureRange(start, end - start + 1);
      this.curPage = start;
      this.onProgress(start, this.chapter.pages.length);
    })
    .width('100%').height('100%').backgroundColor('#FF000000')
  }

  // ===== 右下角悬浮小tabbar: 切章 + 页码, 点击页码呼出设置 =====
  @Builder
  chapterBtn(label: string, delta: number) {
    Text(label).fontSize(13).fontColor('#FF1A1A1E')
      .height(34).padding({ left: 14, right: 14 }).borderRadius(20)
      .backgroundColor('#A6FFFFFF')
      .border({ width: 1, color: '#33FFFFFF' })
      .backdropBlur(30)
      .onClick(() => {
        this.switchChapter(delta);
      })
  }

  @Builder
  bottomTabBar() {
    Row({ space: 8 }) {
      if (this.hasPrevChapter) {
        this.chapterBtn('上一话', -1)
      }

      Row({ space: 6 }) {
        SymbolGlyph($r('sys.symbol.chevron_up')).fontSize(14).fontColor(['#FF1A1A1E'])
        Text((this.curPage + 1) + ' / ' + this.chapter.pages.length)
          .fontSize(13).fontColor('#FF1A1A1E')
      }
      .height(34).padding({ left: 14, right: 14 }).borderRadius(20)
      // 半透明毛玻璃(backdropBlur 普通模糊, 自定义区域可用)
      .backgroundColor('#A6FFFFFF')
      .border({ width: 1, color: '#33FFFFFF' })
      .backdropBlur(30)
      .justifyContent(FlexAlign.Center)
      .onClick(() => { this.openSettings(); })

      if (this.hasNextChapter) {
        this.chapterBtn('下一话', 1)
      }
    }
    .alignItems(VerticalAlign.Center)
  }

  // ===== 点击翻页区(横屏左右/竖屏上中下) =====
  @Builder
  tapRegions() {
    Row() {
      // 左区: 点击上一页 / 右滑下一页?
      Column().width('30%').height('100%').onTouch((e: TouchEvent) => { this.handleTap(e, 0); })
      // 中区: 点击呼出设置
      Column().width('40%').height('100%').onTouch((e: TouchEvent) => { this.handleTap(e, 1); })
      // 右区: 点击下一页
      Column().width('30%').height('100%').onTouch((e: TouchEvent) => { this.handleTap(e, 2); })
    }
    .width('100%').height('100%')
  }

  build() {
    Stack({ alignContent: Alignment.TopStart }) {
      // 内容区
      Column() {
        if (this.mode === 1) {
          this.swiperContent()
        } else {
          this.scrollContent()
        }
      }
      .width('100%').height('100%')

      // 点击翻页区(仅翻页模式且非富文本: 富文本由 Web 内部滚动, 避免误翻章)
      if (this.mode === 1 && !this.isRichChapter()) {
        this.tapRegions()
      }

      // 横屏双栏分隔线(两页中间一条竖线, 静态分栏; 富文本单页不分栏)
      if (this.mode === 1 && this.isLandscape && !this.isRichChapter()) {
        Column()
          .width(1).height('100%')
          .position({ x: this.winW / 2 - 0.5, y: 0 })
          .backgroundColor('#33000000')
      }

      // 右下角悬浮tabbar(设置仅由此呼出, 始终可用含滚动模式)
      Column() {
        Blank()
        this.bottomTabBar()
      }
      .width('100%').height(70)
      .alignItems(HorizontalAlign.End)
      .padding({ right: 16, bottom: 24 })
      .position({ x: 0, y: this.winH - 70 })
    }
    .width('100%').height('100%')
    .backgroundColor('#FF000000')
    .onAreaChange((oldV: Area, newV: Area) => {
      const w = newV.width as number;
      const h = newV.height as number;
      if (w > 0 && h > 0) {
        this.winW = w;
        this.winH = h;
        this.isLandscape = (w / h) > 1.3;
        // 富文本(RICH)保持滚动模式; 其余内容横屏强制翻页
        if (this.isLandscape && !this.isRichChapter()) {
          this.mode = 1;
        }
      }
    })
  }
}