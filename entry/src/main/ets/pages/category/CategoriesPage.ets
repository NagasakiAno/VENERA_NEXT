/**
 * VeneraNext 分类页
 *
 * 汇总各源 category 声明的分类分组, 点分类项进入结果页。
 * 对应原版 categories_page.dart。
 */
import { promptAction, router } from '@kit.ArkUI';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { ComicSourceMeta, CategoryPart, CategoryItem } from '../../model/sources/ComicSourceMeta';
import { categoryService } from '../../services/CategoryService';
import { PRIMARY, GRAY_100, GRAY_900, CARD, BG, MUTED_FG, ERROR,
  RADIUS_MD, RADIUS_LG, SPACE_2, SPACE_3, SPACE_4,
  FS_TITLE, FS_SECTION, FS_CAPTION, FS_SMALL } from '../../utils/Design';

const DOMAIN = 0x0000;
const TAG = 'CategoriesPage';

/** 跳转分类结果页的路由参数 */
interface CategoryRouteParams {
  sourceKey: string;
  category: string;
  param: string;
  title: string;
}

/** 展示用分组(已按 random 抽取) */
class GroupView {
  name: string = '';
  items: CategoryItem[] = [];
}

/** 展示用源卡片 */
class SourceView {
  key: string = '';
  name: string = '';
  groups: GroupView[] = [];
}

@Entry
@Component
export struct CategoriesPage {
  @State views: SourceView[] = [];
  @State loading: boolean = true;

  aboutToAppear(): void {
    this.bootstrap().catch((e: Error) => {
      hilog.error(DOMAIN, TAG, '初始化失败: %{public}s', `${e}`);
    });
  }

  private async bootstrap(): Promise<void> {
    this.loading = true;
    try {
      await categoryService.refresh();
    } catch (e) {
      hilog.warn(DOMAIN, TAG, '解析源分类失败: %{public}s', `${e}`);
    }
    this.views = this.buildViews();
    this.loading = false;
  }

  private buildViews(): SourceView[] {
    const out: SourceView[] = [];
    const metas: ComicSourceMeta[] = categoryService.sources();
    for (let i = 0; i < metas.length; i++) {
      const meta = metas[i];
      const view = new SourceView();
      view.key = meta.key;
      view.name = meta.name;
      const parts: CategoryPart[] = meta.category.parts;
      for (let j = 0; j < parts.length; j++) {
        const items = categoryService.visibleItems(parts[j]);
        if (items.length === 0) {
          continue;
        }
        const group = new GroupView();
        group.name = parts[j].name;
        group.items = items;
        view.groups.push(group);
      }
      if (view.groups.length > 0) {
        out.push(view);
      }
    }
    return out;
  }

  /** 点击一个分类项 */
  private openItem(item: CategoryItem, sourceKey: string): void {
    const target = item.target;
    hilog.info(DOMAIN, TAG, '点击分类项 %{public}s -> page=%{public}s category=%{public}s',
      item.label, target.page, target.category);
    if (target.isCategory()) {
      const params: CategoryRouteParams = {
        sourceKey: sourceKey,
        category: target.category.length > 0 ? target.category : item.label,
        param: target.param,
        title: item.label
      };
      router.pushUrl({ url: 'pages/category/CategoryComicsPage', params: params })
        .then(() => {
          hilog.info(DOMAIN, TAG, '已打开分类结果页 %{public}s', params.category);
        })
        .catch((e: Error) => {
          hilog.error(DOMAIN, TAG, '打开分类结果失败: %{public}s', JSON.stringify(e));
        });
      return;
    }
    if (target.isSearch()) {
      promptAction.showToast({ message: '搜索页开发中：' + target.keyword });
      return;
    }
    promptAction.showToast({ message: '暂不支持的跳转：' + target.page });
  }

  @Builder
  chip(item: CategoryItem, sourceKey: string) {
    Text(item.label.length > 0 ? item.label : '未命名')
      .fontSize(FS_SMALL).fontColor(GRAY_900)
      .padding({ left: 12, right: 12, top: 6, bottom: 6 })
      .backgroundColor(GRAY_100).borderRadius(14)
      .margin({ right: 8, bottom: 8 })
      .onClick(() => {
        this.openItem(item, sourceKey);
      })
  }

  @Builder
  sourceCard(view: SourceView) {
    Column({ space: 10 }) {
      Row({ space: 6 }) {
        Text(view.name).fontSize(FS_CAPTION).fontWeight(FontWeight.Bold).fontColor(GRAY_900)
          .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
        Text(view.key).fontSize(11).fontColor(MUTED_FG).layoutWeight(1)
          .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
      }
      .width('100%').alignItems(VerticalAlign.Center)

      ForEach(view.groups, (group: GroupView, gi: number) => {
        Column({ space: 6 }) {
          Text(group.name).fontSize(FS_SMALL).fontColor(MUTED_FG)
            .width('100%')
          Flex({ wrap: FlexWrap.Wrap }) {
            ForEach(group.items, (item: CategoryItem) => {
              this.chip(item, view.key)
            }, (item: CategoryItem) => view.key + '#' + gi + '#' + item.label)
          }
          .width('100%')
        }
        .width('100%').alignItems(HorizontalAlign.Start)
      }, (group: GroupView, gi: number) => view.key + '#g' + gi)
    }
    .width('100%').padding(SPACE_3)
    .backgroundColor(CARD).borderRadius(RADIUS_LG).margin({ top: SPACE_2 })
  }

  build() {
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
        Text('分类').fontSize(FS_TITLE).fontWeight(FontWeight.Bold).fontColor(GRAY_900)
          .layoutWeight(1).textAlign(TextAlign.Center)
      }
      .width('100%').height(52).padding({ left: SPACE_3, right: SPACE_3 })

      if (this.loading) {
        Column({ space: 10 }) {
          LoadingProgress().width(36).height(36).color(PRIMARY)
          Text('加载中...').fontSize(FS_SMALL).fontColor(MUTED_FG)
        }
        .width('100%').layoutWeight(1).justifyContent(FlexAlign.Center)
      } else if (this.views.length === 0) {
        Column({ space: 8 }) {
          Text('暂无分类页').fontSize(FS_SECTION).fontColor(GRAY_900)
          Text('已安装的源都没有声明 category 配置').fontSize(FS_SMALL).fontColor(MUTED_FG)
            .textAlign(TextAlign.Center).padding({ left: 32, right: 32 })
        }
        .width('100%').layoutWeight(1).justifyContent(FlexAlign.Center)
      } else {
        Scroll() {
          Column() {
            ForEach(this.views, (view: SourceView) => {
              this.sourceCard(view)
            }, (view: SourceView) => view.key)
            Column().height(24)
          }
          .width('100%').padding({ left: SPACE_3, right: SPACE_3 })
        }
        .scrollable(ScrollDirection.Vertical).scrollBar(BarState.Off)
        .align(Alignment.Top)
        .width('100%').layoutWeight(1)
      }
    }
    .width('100%').height('100%').backgroundColor(BG)
  }
}
