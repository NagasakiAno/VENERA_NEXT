/**
 * VeneraNext 分类结果页
 *
 * 对应原版 category_comics_page.dart: 顶部选项 chips + 结果网格 + 分页加载。
 */
import { promptAction, router } from '@kit.ArkUI';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { comicSourceManager } from '../../model/ComicSource';
import { categoryService, CategoryBatch } from '../../services/CategoryService';
import { ExploreComic } from '../../services/ExploreService';
import { ComicDetailPage } from '../comic/ComicDetailPage';
import { PRIMARY, GRAY_100, GRAY_900, CARD, BG, MUTED_FG, ERROR, RADIUS_MD,
  SPACE_2, SPACE_3, SPACE_4, FS_TITLE, FS_SMALL } from '../../utils/Design';

const DOMAIN = 0x0000;
const TAG = 'CategoryComicsPage';

/** 路由参数 */
interface CategoryRouteParams {
  sourceKey: string;
  category: string;
  param: string;
  title: string;
}

/** 一个选项组的展示模型 */
class OptionGroupView {
  label: string = '';
  values: string[] = [];
  labels: string[] = [];
  selectedIndex: number = 0;
}

@Entry
@Component
export struct CategoryComicsPage {
  @State sourceKey: string = '';
  @State category: string = '';
  @State param: string = '';
  @State title: string = '';
  @State groups: OptionGroupView[] = [];
  @State comics: ExploreComic[] = [];
  @State pageNo: number = 1;
  @State maxPage: number = 1;
  @State loading: boolean = false;
  @State loadingMore: boolean = false;
  @State errorMsg: string = '';
  /** 详情覆盖层 */
  @State detailVisible: boolean = false;
  private detailSourceKey: string = '';
  private detailSourceName: string = '';
  private detailComicId: string = '';

  private colIndexes: number[] = [0, 1, 2];

  aboutToAppear(): void {
    const params = router.getParams() as CategoryRouteParams;
    if (params !== null && params !== undefined) {
      this.sourceKey = params.sourceKey;
      this.category = params.category;
      this.param = params.param;
      this.title = params.title;
    }
    this.initGroups();
    this.reload().catch((e: Error) => {
      hilog.error(DOMAIN, TAG, '加载分类结果失败: %{public}s', `${e}`);
    });
  }

  private initGroups(): void {
    const meta = comicSourceManager.findJsSource(this.sourceKey);
    if (meta === null) {
      return;
    }
    const out: OptionGroupView[] = [];
    for (let i = 0; i < meta.categoryOptions.length; i++) {
      const def = meta.categoryOptions[i];
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
    this.groups = out;
  }

  /** 当前选项值(无选项组时为空数组, 与原版一致) */
  private currentOptions(): string[] {
    const out: string[] = [];
    for (let i = 0; i < this.groups.length; i++) {
      const group = this.groups[i];
      const idx = group.selectedIndex;
      out.push(idx >= 0 && idx < group.values.length ? group.values[idx] : '');
    }
    return out;
  }

  private async reload(): Promise<void> {
    this.loading = true;
    this.errorMsg = '';
    this.comics = [];
    this.pageNo = 1;
    this.maxPage = 1;
    try {
      const batch = await categoryService.load(this.sourceKey, this.category, this.param,
        this.currentOptions(), 1);
      this.applyBatch(batch, false);
    } catch (e) {
      this.errorMsg = `${e}`;
      hilog.error(DOMAIN, TAG, '加载失败: %{public}s', `${e}`);
    } finally {
      this.loading = false;
    }
  }

  private async loadMore(): Promise<void> {
    if (this.loading || this.loadingMore || this.pageNo >= this.maxPage) {
      return;
    }
    this.loadingMore = true;
    try {
      const batch = await categoryService.load(this.sourceKey, this.category, this.param,
        this.currentOptions(), this.pageNo + 1);
      this.applyBatch(batch, true);
    } catch (e) {
      hilog.warn(DOMAIN, TAG, '加载下一页失败: %{public}s', `${e}`);
    } finally {
      this.loadingMore = false;
    }
  }

  private applyBatch(batch: CategoryBatch, append: boolean): void {
    this.comics = append ? this.comics.concat(batch.comics) : batch.comics;
    this.maxPage = batch.maxPage > 0 ? batch.maxPage : 1;
    this.pageNo = append ? this.pageNo + 1 : 1;
  }

  private selectOption(gi: number, index: number): void {
    if (this.groups[gi].selectedIndex === index) {
      return;
    }
    this.groups[gi].selectedIndex = index;
    this.groups = this.groups.slice();
    this.reload().catch((e: Error) => {
      hilog.error(DOMAIN, TAG, '切换选项失败: %{public}s', `${e}`);
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
    this.detailSourceKey = c.sourceKey;
    this.detailSourceName = c.sourceName;
    this.detailComicId = c.id;
    this.detailVisible = true;
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
  optionBar() {
    Column({ space: 6 }) {
      ForEach(this.groups, (group: OptionGroupView, gi: number) => {
        Row({ space: 6 }) {
          Text(group.label).fontSize(11).fontColor(MUTED_FG)
            .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
            .constraintSize({ maxWidth: 120 })
          Scroll() {
            Row({ space: 8 }) {
              ForEach(group.values, (value: string, vi: number) => {
                Text(group.labels[vi].length > 0 ? group.labels[vi] : value)
                  .fontSize(FS_SMALL)
                  .fontColor(group.selectedIndex === vi ? CARD : GRAY_900)
                  .padding({ left: 12, right: 12, top: 5, bottom: 5 })
                  .backgroundColor(group.selectedIndex === vi ? PRIMARY : GRAY_100)
                  .borderRadius(13)
                  .onClick(() => {
                    this.selectOption(gi, vi);
                  })
              }, (value: string, vi: number) => `${gi}#${vi}#${value}`)
            }
          }
          .scrollable(ScrollDirection.Horizontal).scrollBar(BarState.Off)
          .align(Alignment.Start)
          .layoutWeight(1)
        }
        .width('100%').alignItems(VerticalAlign.Center)
      }, (group: OptionGroupView, gi: number) => `og#${gi}#${group.label}`)
    }
    .width('100%').padding({ left: SPACE_3, right: SPACE_3, top: SPACE_2, bottom: SPACE_2 })
  }

  build() {
    Stack() {
      Column() {
      // 顶栏
      Row() {
        Row() {
          SymbolGlyph($r('sys.symbol.chevron_left')).fontSize(18).fontColor([MUTED_FG])
        }
        .width(36).height(36).borderRadius(18).backgroundColor(GRAY_100)
        .justifyContent(FlexAlign.Center)
        .onClick(() => {
          router.back();
        })
        Text(this.title.length > 0 ? this.title : this.category)
          .fontSize(FS_TITLE).fontWeight(FontWeight.Bold).fontColor(GRAY_900)
          .layoutWeight(1).textAlign(TextAlign.Center)
          .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
      }
      .width('100%').height(52).padding({ left: SPACE_3, right: SPACE_3 })

      if (this.groups.length > 0) {
        this.optionBar()
      }

      if (this.loading) {
        Column({ space: 10 }) {
          LoadingProgress().width(36).height(36).color(PRIMARY)
          Text('加载中...').fontSize(FS_SMALL).fontColor(MUTED_FG)
        }
        .width('100%').layoutWeight(1).justifyContent(FlexAlign.Center)
      } else {
        List() {
          if (this.errorMsg.length > 0) {
            ListItem() {
              Column({ space: 8 }) {
                Text('加载失败').fontSize(FS_SMALL).fontColor(ERROR)
                Text(this.errorMsg).fontSize(FS_SMALL).fontColor(MUTED_FG)
                  .maxLines(4).textOverflow({ overflow: TextOverflow.Ellipsis })
                  .textAlign(TextAlign.Center)
                Row() {
                  Text('重试').fontSize(FS_SMALL).fontColor(CARD)
                }
                .height(32).padding({ left: 18, right: 18 }).borderRadius(16)
                .backgroundColor(PRIMARY).justifyContent(FlexAlign.Center)
                .onClick(() => {
                  this.reload().catch((e: Error) => {
                    hilog.error(DOMAIN, TAG, '重试失败: %{public}s', `${e}`);
                  });
                })
              }
              .width('100%').padding({ top: SPACE_4, bottom: SPACE_4 })
              .justifyContent(FlexAlign.Center)
            }
          } else if (this.comics.length === 0) {
            ListItem() {
              Column({ space: 8 }) {
                Text('没有内容').fontSize(FS_SMALL).fontColor(MUTED_FG)
              }
              .width('100%').height(160).justifyContent(FlexAlign.Center)
            }
          } else {
            ForEach(this.rowsOf(this.comics), (row: ExploreComic[], ri: number) => {
              ListItem() {
                this.comicRow(row)
              }
              .padding({ bottom: 10 })
            }, (row: ExploreComic[], ri: number) => `cr#${ri}`)
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
        .width('100%').layoutWeight(1)
        .padding({ left: SPACE_3, right: SPACE_3 })
        .onReachEnd(() => {
          this.loadMore();
        })
      }
      }
      .width('100%').height('100%').backgroundColor(BG)

      // 详情覆盖层(与搜索/发现共用同一个详情组件)
      if (this.detailVisible) {
        ComicDetailPage({
          sourceKey: this.detailSourceKey,
          sourceName: this.detailSourceName,
          comicId: this.detailComicId,
          onBack: (): void => {
            this.detailVisible = false;
          }
        })
          .width('100%').height('100%')
      }
    }
    .width('100%').height('100%')
  }
}
