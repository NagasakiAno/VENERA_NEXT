/**
 * VeneraNext 搜索页
 *
 * 单页完成: 关键词输入 + 源选择(含"聚合") + 选项 + 结果。
 *   - 单源: 网格结果 + 滚到底分页
 *   - 聚合: 每个源一块, 横向预览, 可切到该源看全部
 *
 * 对应原版 search_page.dart + search_result_page.dart + aggregated_search_page.dart。
 */
import { promptAction, ChipGroup, ChipGroupItemOptions, ChipSize, uiMaterial } from '@kit.ArkUI';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { ComicSourceMeta, SearchOptionDef } from '../../model/sources/ComicSourceMeta';
import { searchService, SourceSearchResult } from '../../services/SearchService';
import { comicDetailService } from '../../services/ComicDetailService';
import { ExploreComic } from '../../services/ExploreService';
import { PRIMARY, PRIMARY_50, GRAY_100, GRAY_400, GRAY_500, GRAY_700, GRAY_900,
  CARD, BG, MUTED_FG, ERROR, RADIUS_MD, RADIUS_LG,
  SPACE_2, SPACE_3, SPACE_4, FS_SECTION, FS_CAPTION, FS_SMALL } from '../../utils/Design';

const DOMAIN = 0x0000;
const TAG = 'SearchPage';
/** "聚合" 的伪源 key */
const KEY_ALL = '__all__';
/** ID 预览的输入防抖(ms), 避免逐字触发详情请求 */
const ID_PREVIEW_DEBOUNCE_MS = 350;

/**
 * 悬浮顶栏(搜索行 + 源列表行)。顶栏常驻不回缩:
 * 沉浸式系统材质需要稳定的材质区域, 频繁改变高度会反复触发材质重算。
 * 结果区用同样高度的 contentStartOffset 避让, 形成透底的悬浮效果。
 * 顶栏总高含状态栏区域, 让材质条从屏幕最顶端铺起(内容用 SAFE_TOP 下移避让)。
 */
const SEARCH_ROW_H = 48;
const TITLE_CONTENT_H = 96;
/** 顶部系统安全区(与 Index 页面原有的避让量一致) */
const SAFE_TOP = 40;
const TITLE_BAR_H = SAFE_TOP + TITLE_CONTENT_H;

/** 去掉桥层叠加的 Error 前缀, 只留可读原因 */
function briefError(msg: string): string {
  let s = msg;
  while (s.startsWith('Error: ')) {
    s = s.substring('Error: '.length);
  }
  return s.length > 60 ? s.substring(0, 60) + '…' : s;
}

/** 选项组展示模型 */
class OptionGroupView {
  label: string = '';
  values: string[] = [];
  labels: string[] = [];
  selectedIndex: number = 0;
}

/**
 * 按 ID 直达的预览项(加载 comic.loadInfo 的标题与封面, 供用户确认)
 * 必须用 @Observed + 子组件 @ObjectLink: ForEach 的 key 不含可变字段,
 * 直接改属性不会触发卡片重建, 会一直停在"正在确认内容"。
 */
@Observed
class IdPreviewItem {
  sourceKey: string = '';
  sourceName: string = '';
  id: string = '';
  title: string = '';
  subtitle: string = '';
  cover: string = '';
  loading: boolean = true;
  error: string = '';
}

/** ID 预览卡片(封面/名称返回后由 @ObjectLink 驱动刷新) */
@Component
struct IdPreviewCard {
  @ObjectLink item: IdPreviewItem;
  onOpen: (item: IdPreviewItem) => void = () => {};

  build() {
    Row({ space: SPACE_3 }) {
      if (this.item.cover.length > 0) {
        Image(this.item.cover)
          .width(48).height(64)
          .objectFit(ImageFit.Cover)
          .borderRadius(RADIUS_MD).backgroundColor(GRAY_100)
      } else {
        Column() {
          if (this.item.loading) {
            LoadingProgress().width(18).height(18).color(MUTED_FG)
          }
        }
        .width(48).height(64)
        .borderRadius(RADIUS_MD).backgroundColor(GRAY_100)
        .justifyContent(FlexAlign.Center)
      }

      Column({ space: 4 }) {
        Row({ space: 6 }) {
          Text(`[${this.item.sourceName}] 直达`)
            .fontSize(11).fontColor(PRIMARY)
            .padding({ left: 8, right: 8, top: 2, bottom: 2 })
            .backgroundColor(PRIMARY_50).borderRadius(8)
          Text(this.item.id).fontSize(11).fontColor(MUTED_FG)
            .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
            .layoutWeight(1)
        }
        .width('100%').alignItems(VerticalAlign.Center)

        if (this.item.title.length > 0) {
          Text(this.item.title).fontSize(FS_SECTION).fontWeight(FontWeight.Bold).fontColor(GRAY_900)
            .maxLines(2).textOverflow({ overflow: TextOverflow.Ellipsis })
            .width('100%')
        } else if (this.item.loading) {
          Text('正在确认内容...').fontSize(FS_CAPTION).fontColor(MUTED_FG).width('100%')
        } else {
          Text(this.item.error.length > 0 ? '确认失败：' + briefError(this.item.error) : '没有找到对应内容')
            .fontSize(FS_CAPTION).fontColor(ERROR)
            .maxLines(2).textOverflow({ overflow: TextOverflow.Ellipsis })
            .width('100%')
        }

        if (this.item.subtitle.length > 0) {
          Text(this.item.subtitle).fontSize(FS_SMALL).fontColor(MUTED_FG)
            .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
            .width('100%')
        }
      }
      .layoutWeight(1).alignItems(HorizontalAlign.Start)

      SymbolGlyph($r('sys.symbol.chevron_right')).fontSize(16).fontColor([GRAY_400])
    }
    .width('100%').padding(SPACE_2)
    .backgroundColor(CARD).borderRadius(RADIUS_LG)
    .shadow({ radius: 16, color: '#1F000000', offsetX: 0, offsetY: 4 })
    .alignItems(VerticalAlign.Center)
    .onClick(() => {
      this.onOpen(this.item);
    })
  }
}

@Component
export struct SearchPage {
  onClose: () => void = () => {};
  /** 打开在线漫画详情(由窗口根层的 ComicDetailSheet 呈现) */
  onOpenComic: (sourceKey: string, sourceName: string, comicId: string) => void =
    (_s: string, _n: string, _i: string) => {};

  @State keyword: string = '';
  @State sources: ComicSourceMeta[] = [];
  @State selectedKey: string = KEY_ALL;
  @State groups: OptionGroupView[] = [];
  /** 聚合结果(每个源一块) */
  @State results: SourceSearchResult[] = [];
  /** 单源结果 */
  @State comics: ExploreComic[] = [];
  @State pageNo: number = 1;
  @State maxPage: number = 1;
  @State loading: boolean = false;
  @State loadingMore: boolean = false;
  @State searched: boolean = false;
  @State errorMsg: string = '';
  /** 按 ID 直达的预览卡片(命中 comic.idMatch 时出现) */
  @State idPreviews: IdPreviewItem[] = [];
  /** 源列表 ChipGroup: 下标 0 = 聚合 */
  @State chipItems: ChipGroupItemOptions[] = [];
  @State chipIndex: number = 0;
  /** 筛选面板(排序/分类等选项)显隐 */
  @State filterVisible: boolean = false;

  /** 当前输入命中的源(不直接渲染, 用于驱动预览卡片) */
  private idHits: ComicSourceMeta[] = [];
  /** 预览请求版本号: 输入变化后旧响应直接丢弃 */
  private idPreviewToken: number = 0;
  private idDebounceTimer: number = -1;

  private colIndexes: number[] = [0, 1, 2];

  aboutToAppear(): void {
    this.bootstrap().catch((e: Error) => {
      hilog.error(DOMAIN, TAG, '初始化失败: %{public}s', `${e}`);
    });
  }

  private async bootstrap(): Promise<void> {
    // 先用静态解析出的 ID 规则给出直达入口, 真引擎解析完成后再校正
    this.refreshIdHits();
    try {
      await searchService.refresh();
    } catch (e) {
      hilog.warn(DOMAIN, TAG, '解析源搜索能力失败: %{public}s', `${e}`);
    }
    this.sources = searchService.sources();
    this.rebuildChipItems();
    this.refreshIdHits();
  }

  // ---------------------------------------------------------------- 标题栏联动

  /** 源列表 ChipGroup 的选项(聚合 + 各源) */
  private rebuildChipItems(): void {
    const items: ChipGroupItemOptions[] = [];
    items.push({ label: { text: '聚合' } });
    for (let i = 0; i < this.sources.length; i++) {
      items.push({ label: { text: this.sources[i].name } });
    }
    this.chipItems = items;
    this.chipIndex = this.chipIndexOf(this.selectedKey);
  }

  /** 源 key 在 ChipGroup 中的下标(0 为"聚合") */
  private chipIndexOf(key: string): number {
    if (key === KEY_ALL) {
      return 0;
    }
    for (let i = 0; i < this.sources.length; i++) {
      if (this.sources[i].key === key) {
        return i + 1;
      }
    }
    return 0;
  }

  private keyAtIndex(index: number): string {
    if (index <= 0 || index > this.sources.length) {
      return KEY_ALL;
    }
    return this.sources[index - 1].key;
  }

  // ---------------------------------------------------------------- 按 ID 直达

  /** 重新计算命中的源并刷新预览卡片 */
  private refreshIdHits(): void {
    this.idHits = searchService.idMatchSources(this.keyword);
    if (this.idHits.length === 0) {
      this.cancelIdPreview();
      this.idPreviews = [];
      return;
    }
    this.scheduleIdPreview();
  }

  private cancelIdPreview(): void {
    if (this.idDebounceTimer !== -1) {
      clearTimeout(this.idDebounceTimer);
      this.idDebounceTimer = -1;
    }
  }

  /** 输入防抖: 打字过程中不逐个字符请求详情 */
  private scheduleIdPreview(): void {
    this.cancelIdPreview();
    this.idDebounceTimer = setTimeout(() => {
      this.idDebounceTimer = -1;
      this.loadIdPreviews();
    }, ID_PREVIEW_DEBOUNCE_MS);
  }

  /** 同一 ID + 同一批源时复用已有结果(也避免在飞请求被重复发起) */
  private canReusePreviews(id: string): boolean {
    if (this.idHits.length !== this.idPreviews.length) {
      return false;
    }
    for (let i = 0; i < this.idHits.length; i++) {
      const p = this.idPreviews[i];
      if (p.sourceKey !== this.idHits[i].key || p.id !== id) {
        return false;
      }
    }
    return true;
  }

  private async loadIdPreviews(): Promise<void> {
    const id = this.keyword.trim();
    if (id.length === 0) {
      this.idPreviews = [];
      return;
    }
    if (this.canReusePreviews(id)) {
      return;
    }
    this.idPreviewToken = this.idPreviewToken + 1;
    const token = this.idPreviewToken;
    const items: IdPreviewItem[] = [];
    for (let i = 0; i < this.idHits.length; i++) {
      const item = new IdPreviewItem();
      item.sourceKey = this.idHits[i].key;
      item.sourceName = this.idHits[i].name;
      item.id = id;
      items.push(item);
    }
    this.idPreviews = items;
    const tasks: Promise<void>[] = [];
    for (let i = 0; i < items.length; i++) {
      tasks.push(this.loadOnePreview(items[i], token));
    }
    await Promise.all(tasks);
  }

  private async loadOnePreview(item: IdPreviewItem, token: number): Promise<void> {
    try {
      const d = await comicDetailService.load(item.sourceKey, item.id);
      if (token !== this.idPreviewToken) {
        return;
      }
      item.title = d.title;
      item.subtitle = d.subtitle;
      item.cover = d.cover;
      hilog.info(DOMAIN, TAG, 'ID 预览完成 %{public}s@%{public}s: %{public}s',
        item.sourceKey, item.id, item.title);
    } catch (e) {
      if (token !== this.idPreviewToken) {
        return;
      }
      item.error = `${e}`;
      hilog.warn(DOMAIN, TAG, 'ID 预览失败 %{public}s@%{public}s: %{public}s',
        item.sourceKey, item.id, item.error);
    } finally {
      if (token === this.idPreviewToken) {
        item.loading = false;
        this.idPreviews = this.idPreviews.slice();
      }
    }
  }

  /** 点击卡片才进入详情页 */
  private openPreview(p: IdPreviewItem): void {
    // 输入可能刚改过(卡片尚未刷新): 以当前输入为准
    const cur = this.keyword.trim();
    this.onOpenComic(p.sourceKey, p.sourceName, cur.length > 0 ? cur : p.id);
  }

  // ---------------------------------------------------------------- 搜索

  private async doSearch(): Promise<void> {
    const kw = this.keyword.trim();
    if (kw.length === 0) {
      promptAction.showToast({ message: '请输入关键词' });
      return;
    }
    this.searched = true;
    this.errorMsg = '';
    this.results = [];
    this.comics = [];
    this.pageNo = 1;
    this.maxPage = 1;
    this.loading = true;
    try {
      if (this.selectedKey === KEY_ALL) {
        this.results = await searchService.searchAll(kw);
        if (this.results.length === 0) {
          this.errorMsg = '没有可用的搜索源';
        }
      } else {
        const meta = this.metaOf(this.selectedKey);
        const options = meta === null ? [] : searchService.defaultOptions(meta);
        const r = await searchService.search(this.selectedKey, kw, options, 1);
        if (r.isOk()) {
          this.comics = r.comics;
          this.maxPage = r.maxPage > 0 ? r.maxPage : 1;
        } else {
          this.errorMsg = r.error;
        }
      }
    } catch (e) {
      this.errorMsg = `${e}`;
      hilog.error(DOMAIN, TAG, '搜索失败: %{public}s', `${e}`);
    } finally {
      this.loading = false;
    }
  }

  private async loadMore(): Promise<void> {
    if (this.loading || this.loadingMore || this.selectedKey === KEY_ALL) {
      return;
    }
    if (this.pageNo >= this.maxPage) {
      return;
    }
    this.loadingMore = true;
    try {
      const meta = this.metaOf(this.selectedKey);
      const options = meta === null ? [] : searchService.defaultOptions(meta);
      const r = await searchService.search(this.selectedKey, this.keyword.trim(), options, this.pageNo + 1);
      if (r.isOk()) {
        this.comics = this.comics.concat(r.comics);
        this.pageNo = this.pageNo + 1;
      }
    } catch (e) {
      hilog.warn(DOMAIN, TAG, '加载下一页失败: %{public}s', `${e}`);
    } finally {
      this.loadingMore = false;
    }
  }

  private metaOf(key: string): ComicSourceMeta | null {
    for (let i = 0; i < this.sources.length; i++) {
      if (this.sources[i].key === key) {
        return this.sources[i];
      }
    }
    return null;
  }

  /** 切源: 聚合 / 某源(有选项则展示, 并可立即重搜) */
  private selectSource(key: string): void {
    if (this.selectedKey === key) {
      return;
    }
    this.selectedKey = key;
    this.chipIndex = this.chipIndexOf(key);
    this.results = [];
    this.comics = [];
    this.errorMsg = '';
    this.buildGroups();
    if (this.searched && this.keyword.trim().length > 0) {
      this.doSearch();
    }
  }

  /** 筛选面板中某组选项的 ChipGroup 数据 */
  private groupChipItems(gi: number): ChipGroupItemOptions[] {
    const out: ChipGroupItemOptions[] = [];
    const group = this.groups[gi];
    for (let i = 0; i < group.values.length; i++) {
      const text = group.labels[i].length > 0 ? group.labels[i] : group.values[i];
      out.push({ label: { text: text } });
    }
    return out;
  }

  private buildGroups(): void {
    const meta = this.metaOf(this.selectedKey);
    const out: OptionGroupView[] = [];
    if (meta !== null) {
      const defs: SearchOptionDef[] = meta.searchOptions;
      for (let i = 0; i < defs.length; i++) {
        const def = defs[i];
        const group = new OptionGroupView();
        group.label = def.label;
        def.options.forEach((label: string, key: string) => {
          group.values.push(key);
          group.labels.push(label);
        });
        if (group.values.length === 0) {
          continue;
        }
        const idx = group.values.indexOf(def.defaultValue);
        group.selectedIndex = idx >= 0 ? idx : 0;
        out.push(group);
      }
    }
    this.groups = out;
  }

  private selectOption(gi: number, index: number): void {
    if (this.groups[gi].selectedIndex === index) {
      return;
    }
    this.groups[gi].selectedIndex = index;
    this.groups = this.groups.slice();
  }

  private currentOptions(): string[] {
    const out: string[] = [];
    for (let i = 0; i < this.groups.length; i++) {
      const group = this.groups[i];
      const idx = group.selectedIndex;
      out.push(idx >= 0 && idx < group.values.length ? group.values[idx] : '');
    }
    return out;
  }

  private doSearchWithOptions(): void {
    const kw = this.keyword.trim();
    if (kw.length === 0) {
      promptAction.showToast({ message: '请输入关键词' });
      return;
    }
    const meta = this.metaOf(this.selectedKey);
    if (meta === null) {
      return;
    }
    this.searched = true;
    this.comics = [];
    this.errorMsg = '';
    this.loading = true;
    searchService.search(this.selectedKey, kw, this.currentOptions(), 1)
      .then((r: SourceSearchResult) => {
        if (r.isOk()) {
          this.comics = r.comics;
          this.maxPage = r.maxPage > 0 ? r.maxPage : 1;
          this.pageNo = 1;
        } else {
          this.errorMsg = r.error;
        }
        this.loading = false;
      })
      .catch((e: Error) => {
        this.errorMsg = `${e}`;
        this.loading = false;
      });
  }

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

  // ---------------------------------------------------------------- UI

  @Builder
  comicCell(c: ExploreComic) {
    Column() {
      if (c.cover.length > 0) {
        Image(c.cover)
          .width('100%').aspectRatio(0.72)
          .objectFit(ImageFit.Cover)
          .borderRadius(RADIUS_MD).backgroundColor(GRAY_100)
      } else {
        Column().width('100%').aspectRatio(0.72)
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

  /** 聚合结果: 每个源一块横向预览 */
  @Builder
  aggregatedBlock(r: SourceSearchResult) {
    Column({ space: 8 }) {
      Row({ space: 8 }) {
        Text(r.sourceName).fontSize(FS_CAPTION).fontWeight(FontWeight.Bold).fontColor(GRAY_900)
          .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
        if (r.isOk()) {
          Text(r.comics.length.toString() + ' 条').fontSize(11).fontColor(MUTED_FG)
        } else {
          Text('失败').fontSize(11).fontColor(ERROR)
        }
        Text('').layoutWeight(1)
        if (r.isOk() && r.comics.length > 0) {
          Text('查看全部').fontSize(FS_SMALL).fontColor(PRIMARY)
            .onClick(() => {
              this.selectSource(r.sourceKey);
            })
        }
      }
      .width('100%').alignItems(VerticalAlign.Center)

      if (!r.isOk()) {
        Text(r.error).fontSize(11).fontColor(MUTED_FG)
          .maxLines(2).textOverflow({ overflow: TextOverflow.Ellipsis })
          .width('100%')
      } else if (r.comics.length === 0) {
        Text('没有结果').fontSize(FS_SMALL).fontColor(MUTED_FG).width('100%')
      } else {
        Scroll() {
          Row({ space: 8 }) {
            ForEach(r.comics.slice(0, 8), (c: ExploreComic) => {
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
                this.openComic(c);
              })
            }, (c: ExploreComic) => r.sourceKey + '#' + c.id)
          }
        }
        .scrollable(ScrollDirection.Horizontal)
        .scrollBar(BarState.Off)
        .align(Alignment.Start)
        .width('100%')
      }
    }
    .width('100%').padding(SPACE_3)
    .backgroundColor(CARD).borderRadius(RADIUS_LG).margin({ top: SPACE_2 })
  }

  /**
   * 悬浮顶栏: 作为 Navigation 的标题栏渲染, 因此在标题栏中的沉浸式系统材质可以生效
   * (官方约束: 材质只在 Navigation/NavDestination 标题栏、底部 TabBar、弹窗类组件中生效)。
   * 高度固定不回缩, 保证材质区域稳定、不反复重算。
   */
  @Builder
  searchTitleBar() {
    Column() {
      // 内容整体下移一个状态栏高度, 上方留给材质条
      Column() {
        // 搜索行
        Row({ space: SPACE_2 }) {
        Row() {
          SymbolGlyph($r('sys.symbol.chevron_left')).fontSize(18).fontColor([GRAY_900])
        }
        .width(40).height(40).borderRadius(20)
        .justifyContent(FlexAlign.Center)
        .onClick(() => {
          this.onClose();
        })

        Row() {
          SymbolGlyph($r('sys.symbol.magnifyingglass')).fontSize(16).fontColor([MUTED_FG])
            .margin({ left: 8, right: 8 })
          TextInput({ text: this.keyword, placeholder: '搜索漫画或输入 ID' })
            .fontColor(GRAY_900).placeholderColor(MUTED_FG)
            .backgroundColor(Color.Transparent)
            .padding({ left: 4, right: 8 })
            .height(40)
            .layoutWeight(1)
            .onChange((v: string) => {
              this.keyword = v;
              this.refreshIdHits();
            })
            .onSubmit(() => {
              this.doSearch();
            })
          if (this.keyword.length > 0) {
            SymbolGlyph($r('sys.symbol.xmark_circle_fill')).fontSize(16).fontColor([GRAY_400])
              .margin({ right: 10 })
              .onClick(() => {
                this.keyword = '';
                this.refreshIdHits();
              })
          }
        }
        .height(40).borderRadius(20).layoutWeight(1)
        .backgroundColor(Color.Transparent)
        .systemMaterial(new uiMaterial.ImmersiveMaterial({
          materialColor: '#33FFFFFF',
          interactive: true
        }))
        .alignItems(VerticalAlign.Center)

        Row() {
          Text('搜索').fontSize(FS_SMALL).fontColor(CARD)
        }
        .height(40).padding({ left: 16, right: 16 }).borderRadius(20)
        .backgroundColor(Color.Transparent)
        .justifyContent(FlexAlign.Center)
        .systemMaterial(new uiMaterial.ImmersiveMaterial({
          materialColor: '#B3145CDE',
          interactive: true
        }))
        .onClick(() => {
          this.doSearch();
        })
      }
      .width('100%').height(SEARCH_ROW_H)
      .alignItems(VerticalAlign.Center)

      // 源列表: 常驻顶栏
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
          chipGroupSpace: { startSpace: 12, endSpace: 4, itemSpace: 8 },
          selectedIndexes: [this.chipIndex],
          backgroundSystemMaterial: new uiMaterial.ImmersiveMaterial({
            interactive: true
          }),
          selectedBackgroundSystemMaterial: new uiMaterial.ImmersiveMaterial({
            materialColor: '#B3145CDE',
            interactive: true
          }),
          onChange: (indexes: number[]) => {
            if (indexes.length === 0) {
              return;
            }
            const key = this.keyAtIndex(indexes[0]);
            this.chipIndex = indexes[0];
            this.selectSource(key);
          }
        })
          .layoutWeight(1)

        // 排序/分类等选项收进筛选面板, 不再常驻占版面
        if (this.groups.length > 0) {
          Row() {
            SymbolGlyph($r('sys.symbol.square_grid_2x2')).fontSize(16)
              .fontColor([GRAY_900])
          }
          .width(36).height(36).borderRadius(18)
          .justifyContent(FlexAlign.Center)
          .backgroundColor(Color.Transparent)
          .systemMaterial(new uiMaterial.ImmersiveMaterial({
            interactive: true
          }))
          .onClick(() => {
            this.filterVisible = true;
          })
        }
      }
      .width('100%').alignItems(VerticalAlign.Center)
      }
      .width('100%')
      .height(TITLE_CONTENT_H)
      .padding({ left: SPACE_3, right: SPACE_3 })
      .justifyContent(FlexAlign.Center)
    }
    .width('100%')
    .height(TITLE_BAR_H)
    .padding({ top: SAFE_TOP })
    // 材质条铺到屏幕顶端与左右安全区
    .expandSafeArea([SafeAreaType.SYSTEM])
  }

  /** 筛选面板: 每个选项组一个 ChipGroup, 选中即时重搜 */
  @Builder
  filterSheet() {
    Column({ space: SPACE_4 }) {
      ForEach(this.groups, (group: OptionGroupView, gi: number) => {
        Column({ space: SPACE_2 }) {
          Text(group.label).fontSize(FS_CAPTION).fontColor(MUTED_FG)
            .width('100%')
          ChipGroup({
            items: this.groupChipItems(gi),
            itemStyle: {
              size: ChipSize.SMALL,
              backgroundColor: Color.Transparent,
              selectedBackgroundColor: Color.Transparent,
              fontColor: GRAY_900,
              selectedFontColor: CARD
            },
            chipGroupPadding: { top: 0, bottom: 0 },
            chipGroupSpace: { startSpace: 0, endSpace: 0 },
            selectedIndexes: [group.selectedIndex],
            backgroundSystemMaterial: new uiMaterial.ImmersiveMaterial({
              interactive: true
            }),
            selectedBackgroundSystemMaterial: new uiMaterial.ImmersiveMaterial({
              materialColor: '#B3145CDE',
              interactive: true
            }),
            onChange: (indexes: number[]) => {
              if (indexes.length === 0) {
                return;
              }
              this.selectOption(gi, indexes[0]);
              this.doSearchWithOptions();
            }
          })
            .width('100%')
        }
        .width('100%').alignItems(HorizontalAlign.Start)
      }, (group: OptionGroupView, gi: number) => `fg#${gi}#${group.label}`)

      Row() {
        Text('完成').fontSize(FS_SMALL).fontColor(CARD)
      }
      .width('100%').height(40).borderRadius(20)
      .backgroundColor(PRIMARY).justifyContent(FlexAlign.Center)
      .onClick(() => {
        this.filterVisible = false;
      })
    }
    .width('100%')
    .padding({ left: SPACE_4, right: SPACE_4, top: SPACE_2, bottom: SPACE_4 })
    .alignItems(HorizontalAlign.Start)
  }
  /**
   * 「按 ID 直达」预览卡片: 输入整体命中某源声明的 comic.idMatch 时,
   * 先从顶部滑入一张圆角卡片, 展示 [源] 直达 + 封面缩略图 + 名称,
   * 让用户在跳转前确认是否为目标内容; 点击卡片才进入详情页。
   * 对应原版 search_page.dart 的 Open comic 建议项。
   */
  @Builder
  idPreviewPanel() {
    Column({ space: SPACE_2 }) {
      ForEach(this.idPreviews, (p: IdPreviewItem) => {
        IdPreviewCard({
          item: p,
          onOpen: (item: IdPreviewItem): void => {
            this.openPreview(item);
          }
        })
      // key 必须带上 id: 只按源做 key 时, 换 ID 后会复用旧卡片, 显示上一个 ID 的内容
      }, (p: IdPreviewItem) => `idpv#${p.sourceKey}#${p.id}`)
    }
    .width('100%')
    .padding({ left: SPACE_3, right: SPACE_3, bottom: SPACE_2 })
    .margin({ top: TITLE_BAR_H + SPACE_2 })
    .transition(TransitionEffect.move(TransitionEdge.TOP)
      .animation({ duration: 260, curve: Curve.Friction }))
  }

  @Builder
  resultsView() {
    if (this.loading) {
      Column({ space: 10 }) {
        LoadingProgress().width(36).height(36).color(PRIMARY)
        Text('搜索中...').fontSize(FS_SMALL).fontColor(MUTED_FG)
      }
      .width('100%').layoutWeight(1).justifyContent(FlexAlign.Center)
    } else if (this.errorMsg.length > 0) {
      Column({ space: 8 }) {
        Text('搜索失败').fontSize(FS_SMALL).fontColor(ERROR)
        Text(this.errorMsg).fontSize(FS_SMALL).fontColor(MUTED_FG)
          .maxLines(4).textOverflow({ overflow: TextOverflow.Ellipsis })
          .textAlign(TextAlign.Center).padding({ left: 24, right: 24 })
      }
      .width('100%').layoutWeight(1).justifyContent(FlexAlign.Center)
    } else if (!this.searched) {
      Column({ space: 8 }) {
        Text('输入关键词开始搜索').fontSize(FS_SECTION).fontColor(GRAY_900)
        Text('选择"聚合"可一次搜索所有源').fontSize(FS_SMALL).fontColor(MUTED_FG)
      }
      .width('100%').layoutWeight(1).justifyContent(FlexAlign.Center)
    } else if (this.selectedKey === KEY_ALL) {
      List() {
        ForEach(this.results, (r: SourceSearchResult) => {
          ListItem() {
            this.aggregatedBlock(r)
          }
        }, (r: SourceSearchResult) => r.sourceKey)
        ListItem() {
          Column().height(24)
        }
      }
      .scrollBar(BarState.Off)
      .align(Alignment.Top)
      .contentStartOffset(TITLE_BAR_H)
      .width('100%').layoutWeight(1)
      .padding({ left: SPACE_3, right: SPACE_3 })
    } else {
      List() {
        if (this.comics.length === 0) {
          ListItem() {
            Column() {
              Text('没有结果').fontSize(FS_SMALL).fontColor(MUTED_FG)
            }
            .width('100%').height(160).justifyContent(FlexAlign.Center)
          }
        } else {
          ForEach(this.rowsOf(this.comics), (row: ExploreComic[], ri: number) => {
            ListItem() {
              this.comicRow(row)
            }
            .padding({ bottom: 10 })
          }, (row: ExploreComic[], ri: number) => `sr#${ri}`)
        }
        ListItem() {
          Column() {
            if (this.loadingMore) {
              Row({ space: 8 }) {
                LoadingProgress().width(18).height(18).color(PRIMARY)
                Text('加载中...').fontSize(FS_SMALL).fontColor(MUTED_FG)
              }
            } else if (this.comics.length > 0 && this.pageNo >= this.maxPage) {
              Text('没有更多了').fontSize(FS_SMALL).fontColor(MUTED_FG)
            } else if (this.comics.length > 0) {
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
  }

  build() {
    Stack({ alignContent: Alignment.Top }) {
      // 顶栏交给 Navigation 的标题栏渲染: 沉浸式系统材质只在标题栏子树中生效,
      // STACK 模式让内容区延伸到标题栏下方, 形成透底的悬浮效果。
      Navigation() {
        Column() {
          this.resultsView()
        }
        .width('100%').height('100%')
      }
      .hideBackButton(true)
      .hideToolBar(true)
      .mode(NavigationMode.Stack)
      .title({ builder: this.searchTitleBar, height: TITLE_BAR_H }, {
        barStyle: BarStyle.STACK,
        systemMaterial: new uiMaterial.ImmersiveMaterial({})
      })
      .width('100%').height('100%')
      .backgroundColor(BG)
      .expandSafeArea([SafeAreaType.SYSTEM])

      // 命中 ID 规则时从顶部滑入的直达预览卡片(浮层, 不推挤内容)
      if (this.idPreviews.length > 0) {
        this.idPreviewPanel()
      }
    }
    .width('100%').height('100%')
    .bindSheet(this.filterVisible, this.filterSheet(), {
      height: SheetSize.FIT_CONTENT,
      title: { title: '筛选' },
      dragBar: true,
      // 弹窗类组件属于沉浸光感的生效范围
      systemMaterial: new uiMaterial.ImmersiveMaterial({}),
      onDisappear: () => {
        this.filterVisible = false;
      }
    })
  }
}
