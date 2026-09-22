/**
 * VeneraNext 书架页(本地导入为主)
 * 四个子Tab: 本地 / 历史 / 追更 / 收藏
 * 顶栏下方放置导入按钮; 响应式封面网格; 空态提示
 */
import { ShelfItem, ShelfSourceType } from '../../model/ShelfItem';
import { localBookStore } from '../../model/LocalBookStore';
import { doImport, restoreImported, removeImported } from '../../utils/FileImporter';
import { promptAction } from '@kit.ArkUI';
import { common } from '@kit.AbilityKit';
import { PRIMARY, PRIMARY_50, GRAY_500, GRAY_900, GRAY_100, CARD, BG,
  MUTED_FG, ERROR, RADIUS_MD, RADIUS_LG, SPACE_3, FS_CAPTION, FS_SMALL } from '../../utils/Design';
import { IS_WIDE, WIDTH_BP } from '../../utils/Breakpoints';
import { SegmentButton, SegmentButtonItemTuple, SegmentButtonOptions } from '@kit.ArkUI';

@Component
export struct BookshelfPage {
  @StorageProp(IS_WIDE) isWide: boolean = false;
  @StorageProp(WIDTH_BP) widthBp: string = 'md';
  onOpenDetail: (item: ShelfItem) => void = () => {};
  @State tab: number = 0;
  // 本地书列表(响应式: 导入 + 恢复)
  @State localItems: ShelfItem[] = localBookStore.all();
  // 导入中标记(防重复点击)
  @State importing: boolean = false;
  // 顶栏 SegmentButton 状态(显式颜色适配深色模式)
  @State segOptions: SegmentButtonOptions = SegmentButtonOptions.capsule({
    buttons: [
      { text: '本地' }, { text: '历史' }, { text: '追更' }, { text: '收藏' }
    ] as SegmentButtonItemTuple,
    multiply: false,
    fontColor: GRAY_500,
    selectedFontColor: CARD,
    backgroundColor: CARD,
    selectedBackgroundColor: PRIMARY
  });
  @State segSelected: number[] = [0];
  // 管理模式(显示删除角标)
  @State manageMode: boolean = false;

  aboutToAppear(): void {
    // 订阅 store 变化, 导入/恢复/删除后刷新本地列表
    localBookStore.subscribe(() => {
      this.localItems = localBookStore.all();
    });
    // 页面出现时恢复已导入的书(幂等, 与 EntryAbility 互补)
    const ctx = this.getUIContext().getHostContext() as common.UIAbilityContext;
    restoreImported(ctx);
    this.localItems = localBookStore.all();
  }

  /** 导入本地文件(TXT/EPUB) */
  private async importBook(): Promise<void> {
    if (this.importing) {
      return;
    }
    this.importing = true;
    try {
      const ctx = this.getUIContext().getHostContext() as common.UIAbilityContext;
      const it = await doImport(ctx);
      if (it !== null) {
        promptAction.showToast({ message: '已导入：' + it.title });
      }
    } catch (e) {
      promptAction.showToast({ message: '导入失败' });
    } finally {
      this.importing = false;
    }
  }

  /** 确认删除书籍 */
  private confirmDelete(item: ShelfItem): void {
    promptAction.showDialog({
      title: '删除书籍',
      message: '确定删除《' + item.title + '》吗？文件将一并移除。',
      buttons: [
        { text: '取消', color: GRAY_500 },
        { text: '删除', color: ERROR }
      ]
    }).then((res: promptAction.ShowDialogSuccessResponse) => {
      if (res.index === 1) {
        const ctx = this.getUIContext().getHostContext() as common.UIAbilityContext;
        removeImported(ctx, item);
        promptAction.showToast({ message: '已删除' });
      }
    }).catch((e: Error) => {
      // 取消
    });
  }

  /** 切换管理模式 */
  private toggleManage(): void {
    this.manageMode = !this.manageMode;
  }

  /** 封面图统一渲染(本地Resource/沙箱 file:// 路径) */
  @Builder
  coverView(item: ShelfItem, radius: number) {
    Image(item.cover as Resource | string).width('100%').aspectRatio(3.0 / 4.0).borderRadius(radius)
      .objectFit(ImageFit.Cover).backgroundColor(GRAY_100)
  }

  /** 竖屏封面格 */
  @Builder
  coverCell(item: ShelfItem) {
    Column() {
      Stack({ alignContent: Alignment.BottomStart }) {
        this.coverView(item, RADIUS_MD)
        // 来源角标
        if (item.sourceType === ShelfSourceType.WEB) {
          Text('WEB').fontSize(9).fontColor(CARD).backgroundColor('#80145CDE')
            .borderRadius(4).padding({ left: 5, right: 5, top: 1, bottom: 1 }).margin(6)
        }
        // 追更进度角标
        if (item.lastReadPage > 0 && (this.tab === 0 || this.tab === 3)) {
          Text('读到第' + item.lastReadChapter.replace('第', '').replace('章', '') + '章')
            .fontSize(9).fontColor(CARD).backgroundColor('#99000000')
            .padding({ left: 5, right: 5, top: 1, bottom: 1 }).margin(6)
        }
        // 管理模式: 右上角删除角标
        if (this.manageMode) {
          Text('×').fontSize(16).fontColor(CARD)
            .width(26).height(26).borderRadius(13)
            .backgroundColor('#E8455E').textAlign(TextAlign.Center)
            .position({ top: 4, right: 4 })
            .onClick(() => { this.confirmDelete(item); })
        }
      }
      .width('100%').aspectRatio(3.0 / 4.0).borderRadius(RADIUS_MD).clip(true)

      Text(item.title).fontSize(FS_CAPTION).maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis }).fontColor(GRAY_900).margin({ top: 4 })
    }
    .width('100%')
    .onClick(() => {
      if (!this.manageMode) {
        this.onOpenDetail(item);
      }
    })
  }

  /** 网格列数(横屏更多列) */
  columns(): string {
    const n: number = this.widthBp === 'xl' ? 7 : this.widthBp === 'lg' ? 5 :
      this.isWide ? 4 : 3;
    return `repeat(${Math.max(3, n)}, 1fr)`;
  }

  /** 当前 Tab 数据 */
  currentItems(): ShelfItem[] {
    const all = localBookStore.all();
    if (this.tab === 0) { // 本地
      return this.localItems;
    } else if (this.tab === 1) { // 历史(有阅读记录)
      return allWithRead(all);
    } else if (this.tab === 2) { // 追更(全部导入书)
      return all;
    } else { // 收藏
      return allFavorite(all);
    }
  }

  /** 导入栏: 管理 + 提示 + 导入 */
  @Builder
  importBar() {
    Row({ space: 10 }) {
      // 管理按钮(切换管理模式删除书籍)
      Row() {
        SymbolGlyph($r('sys.symbol.square_grid_2x2')).fontSize(14)
          .fontColor([this.manageMode ? PRIMARY : GRAY_500])
        Text(this.manageMode ? '完成' : '管理').fontSize(FS_SMALL)
          .fontColor(this.manageMode ? PRIMARY : GRAY_500).margin({ left: 4 })
      }
      .height(36).padding({ left: 14, right: 14 }).borderRadius(18)
      .backgroundColor(this.manageMode ? PRIMARY_50 : GRAY_100)
      .justifyContent(FlexAlign.Center)
      .onClick(() => { this.toggleManage(); })

      Text('导入本地文件').fontSize(FS_SMALL).fontColor(MUTED_FG).layoutWeight(1)

      Row() {
        SymbolGlyph($r('sys.symbol.square_grid_2x2')).fontSize(16).fontColor(['#FFFFFFFF'])
        Text('导入').fontSize(FS_SMALL).fontColor('#FFFFFFFF').margin({ left: 4 })
      }
      .height(36).padding({ left: 16, right: 16 }).borderRadius(18)
      .backgroundColor(PRIMARY)
      .justifyContent(FlexAlign.Center)
      .onClick(() => { this.importBook(); })
    }
    .width('92%').height(52).padding({ left: SPACE_3, right: SPACE_3 })
    .backgroundColor(CARD).borderRadius(RADIUS_LG).margin({ top: 4, bottom: 8 })
  }

  /** 空态提示 */
  @Builder
  emptyView() {
    Column({ space: 10 }) {
      SymbolGlyph($r('sys.symbol.square_grid_2x2')).fontSize(40).fontColor([GRAY_100])
      Text('暂无书籍，点击上方"导入"添加本地电子书').fontSize(FS_SMALL).fontColor(MUTED_FG)
    }
    .width('100%').layoutWeight(1).justifyContent(FlexAlign.Center)
  }

  build() {
    Column() {
      // 顶栏: SegmentButton 胶囊单选(显式颜色, 深色模式可读)
      SegmentButton({
        options: this.segOptions,
        selectedIndexes: this.segSelected,
        enableStateAnimation: true,
        onItemClicked: (index: number): void => {
          this.tab = index;
          this.segSelected = [index];
        }
      })
      .width('92%')
      .margin({ top: 12, bottom: 4 })

      // 本地 tab 顶栏下方导入栏(书籍列表上面, 无遮挡冲突)
      if (this.tab === 0) {
        this.importBar()
      }

      // 封面网格 / 空态
      if (this.currentItems().length === 0) {
        this.emptyView()
      } else {
        Grid() {
          ForEach(this.currentItems(), (item: ShelfItem) => {
            GridItem() { this.coverCell(item) }
          }, (item: ShelfItem) => item.id)
        }
        .columnsTemplate(this.columns())
        .columnsGap(12).rowsGap(12)
        .width('100%').padding({ left: SPACE_3, right: SPACE_3 }).layoutWeight(1)
      }
    }
    .width('100%').height('100%').backgroundColor(BG)
  }
}

// 辅助过滤函数(模块级)
function allWithRead(all: ShelfItem[]): ShelfItem[] {
  const out: ShelfItem[] = [];
  for (let i = 0; i < all.length; i++) {
    if (all[i].lastReadPage > 0) {
      out.push(all[i]);
    }
  }
  return out;
}

function allFavorite(all: ShelfItem[]): ShelfItem[] {
  const out: ShelfItem[] = [];
  for (let i = 0; i < all.length; i++) {
    if (all[i].isFavorite) {
      out.push(all[i]);
    }
  }
  return out;
}
