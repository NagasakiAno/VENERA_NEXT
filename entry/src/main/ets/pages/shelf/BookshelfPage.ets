/**
 * VeneraNext 书架页(本地导入为主)
 * 四个子Tab: 本地 / 历史 / 下载 / 收藏
 * 顶栏下方放置导入按钮; 响应式封面网格; 空态提示
 */
import { ShelfItem, ShelfSourceType } from '../../model/ShelfItem';
import { localBookStore } from '../../model/LocalBookStore';
import { localFavoritesStore, FavoriteItem, FavoriteFolder } from '../../model/LocalFavoritesStore';
import { downloadQueueStore, DownloadTask, DownloadStatus } from '../../model/DownloadQueueStore';
import { downloadService } from '../../services/DownloadService';
import { doImport, restoreImported, removeImported, restoreWebFavorites, persistWebFavorites } from '../../utils/FileImporter';
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
      { text: '本地' }, { text: '历史' }, { text: '下载' }, { text: '收藏' }
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
  // === 收藏 Tab 专属状态 ===
  @State favFolderNames: string[] = [];
  @State favCurrentFolder: string = '收藏';
  @State favItems: FavoriteItem[] = [];
  @State favShowFolderBar: boolean = false;
  // === 下载 Tab 专属状态 ===
  @State downloadTasks: DownloadTask[] = [];

  aboutToAppear(): void {
    // 订阅 store 变化, 导入/恢复/删除后刷新本地列表
    localBookStore.subscribe(() => {
      this.localItems = localBookStore.all();
    });
    // 页面出现时恢复已导入的书(幂等, 与 EntryAbility 互补)
    const ctx = this.getUIContext().getHostContext() as common.UIAbilityContext;
    restoreImported(ctx);
    restoreWebFavorites(ctx);
    this.localItems = localBookStore.all();
    // 初始化收藏 store
    localFavoritesStore.init(ctx);
    localFavoritesStore.subscribe(() => {
      this.refreshFavState();
    });
    this.refreshFavState();
    // 初始化下载队列 store
    downloadQueueStore.init(ctx);
    downloadQueueStore.subscribe(() => {
      this.downloadTasks = downloadQueueStore.getAllTasks();
    });
    this.downloadTasks = downloadQueueStore.getAllTasks();
    // 初始化下载队列 store
    downloadQueueStore.init(ctx);
    downloadQueueStore.subscribe(() => {
      this.downloadTasks = downloadQueueStore.getAllTasks();
    });
    this.downloadTasks = downloadQueueStore.getAllTasks();
  }

  /** 刷新收藏 Tab 状态 */
  private refreshFavState(): void {
    this.favFolderNames = localFavoritesStore.getFolderNames();
    if (this.favCurrentFolder === '' || localFavoritesStore.getFolder(this.favCurrentFolder) === null) {
      this.favCurrentFolder = '收藏';
    }
    this.favItems = localFavoritesStore.getFolderComics(this.favCurrentFolder);
  }

  /** 创建新文件夹 */
  private showCreateFolderDialog(): void {
    promptAction.showDialog({
      title: '新建收藏夹',
      message: '请输入文件夹名称',
      buttons: [
        { text: '取消', color: GRAY_500 },
        { text: '创建', color: PRIMARY }
      ]
    }).then((res: promptAction.ShowDialogSuccessResponse) => {
      if (res.index === 1) {
        // 使用 TextInput 方式更合适，但 showDialog 不支持输入
        // 这里用简单方式：创建带默认名的文件夹
        const baseName = '新文件夹';
        let name = baseName;
        let suffix = 1;
        while (!localFavoritesStore.createFolder(name)) {
          name = baseName + '(' + suffix + ')';
          suffix++;
        }
        this.favCurrentFolder = name;
        this.refreshFavState();
        promptAction.showToast({ message: '已创建: ' + name });
      }
    }).catch((e: Error) => {});
  }

  /** 切换收藏文件夹 */
  private switchFavFolder(name: string): void {
    this.favCurrentFolder = name;
    this.favItems = localFavoritesStore.getFolderComics(name);
    this.favShowFolderBar = false;
  }

  /** 从收藏夹移除 */
  private removeFavItem(item: FavoriteItem): void {
    promptAction.showDialog({
      title: '取消收藏',
      message: '确定将《' + item.title + '》从"' + this.favCurrentFolder + '"移除吗？',
      buttons: [
        { text: '取消', color: GRAY_500 },
        { text: '移除', color: ERROR }
      ]
    }).then((res: promptAction.ShowDialogSuccessResponse) => {
      if (res.index === 1) {
        localFavoritesStore.removeComic(this.favCurrentFolder, item.id);
        promptAction.showToast({ message: '已移除' });
      }
    }).catch((e: Error) => {});
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

  /** 确认删除书籍(WEB 收藏条目=移出书架并同步落盘) */
  private confirmDelete(item: ShelfItem): void {
    const isWeb = item.sourceType === ShelfSourceType.WEB;
    promptAction.showDialog({
      title: '删除书籍',
      message: '确定删除《' + item.title + '》吗？' + (isWeb ? '' : '文件将一并移除。'),
      buttons: [
        { text: '取消', color: GRAY_500 },
        { text: '删除', color: ERROR }
      ]
    }).then((res: promptAction.ShowDialogSuccessResponse) => {
      if (res.index === 1) {
        const ctx = this.getUIContext().getHostContext() as common.UIAbilityContext;
        if (isWeb) {
          localBookStore.removeItem(item.id);
          persistWebFavorites(ctx, localBookStore.all());
        } else {
          removeImported(ctx, item);
        }
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

  /** 当前 Tab 数据（仅 tab 0/1 使用，下载和收藏有独立 UI） */
  currentItems(): ShelfItem[] {
    const all = localBookStore.all();
    if (this.tab === 0) { // 本地
      return this.localItems;
    } else if (this.tab === 1) { // 历史(有阅读记录)
      return allWithRead(all);
    }
    return [];
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

  /** 收藏 Tab: 文件夹横向选择栏 */
  @Builder
  favFolderBar() {
    Row({ space: 8 }) {
      // 文件夹列表（横向滚动）
      Scroll() {
        Row({ space: 8 }) {
          ForEach(this.favFolderNames, (name: string) => {
            Text(name)
              .fontSize(FS_SMALL)
              .fontColor(this.favCurrentFolder === name ? CARD : GRAY_500)
              .backgroundColor(this.favCurrentFolder === name ? PRIMARY : GRAY_100)
              .borderRadius(16)
              .padding({ left: 12, right: 12, top: 6, bottom: 6 })
              .onClick(() => { this.switchFavFolder(name); })
          }, (name: string) => name)
          // 新建文件夹按钮
          Text('+')
            .fontSize(FS_SMALL)
            .fontColor(PRIMARY)
            .backgroundColor(PRIMARY_50)
            .borderRadius(16)
            .padding({ left: 12, right: 12, top: 6, bottom: 6 })
            .onClick(() => { this.showCreateFolderDialog(); })
        }
      }
      .scrollable(ScrollDirection.Horizontal)
      .scrollBar(BarState.Off)
      .layoutWeight(1)
    }
    .width('92%')
    .margin({ top: 4, bottom: 4 })
  }

  /** 收藏项封面格 */
  @Builder
  favCoverCell(item: FavoriteItem) {
    Column() {
      Stack({ alignContent: Alignment.BottomStart }) {
        Image(item.cover).width('100%').aspectRatio(3.0 / 4.0).borderRadius(RADIUS_MD)
          .objectFit(ImageFit.Cover).backgroundColor(GRAY_100)
        // 来源角标
        if (item.sourceType === ShelfSourceType.WEB) {
          Text('WEB').fontSize(9).fontColor(CARD).backgroundColor('#80145CDE')
            .borderRadius(4).padding({ left: 5, right: 5, top: 1, bottom: 1 }).margin(6)
        }
        // 管理模式: 右上角删除角标
        if (this.manageMode) {
          Text('×').fontSize(16).fontColor(CARD)
            .width(26).height(26).borderRadius(13)
            .backgroundColor('#E8455E').textAlign(TextAlign.Center)
            .position({ top: 4, right: 4 })
            .onClick(() => { this.removeFavItem(item); })
        }
      }
      .width('100%').aspectRatio(3.0 / 4.0).borderRadius(RADIUS_MD).clip(true)

      Text(item.title).fontSize(FS_CAPTION).maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis }).fontColor(GRAY_900).margin({ top: 4 })
    }
    .width('100%')
    .onClick(() => {
      if (!this.manageMode) {
        // 从收藏项打开详情：构造 ShelfItem 并回调
        const shelfItem = new ShelfItem(
          item.id, item.title, item.cover, item.author, '', item.tags,
          item.sourceType, [], true, 0, '', 0, '', [], '', null, false, ''
        );
        this.onOpenDetail(shelfItem);
      }
    })
  }

  /** 收藏空态 */
  @Builder
  favEmptyView() {
    Column({ space: 10 }) {
      SymbolGlyph($r('sys.symbol.heart')).fontSize(40).fontColor([GRAY_100])
      Text('暂无收藏，在漫画详情页点击收藏按钮添加').fontSize(FS_SMALL).fontColor(MUTED_FG)
    }
    .width('100%').layoutWeight(1).justifyContent(FlexAlign.Center)
  }

  /** 下载状态文本 */
  private downloadStatusText(status: DownloadStatus): string {
    switch (status) {
      case DownloadStatus.PENDING:
        return '等待中';
      case DownloadStatus.DOWNLOADING:
        return '下载中';
      case DownloadStatus.COMPLETED:
        return '已完成';
      case DownloadStatus.FAILED:
        return '失败';
      case DownloadStatus.PAUSED:
        return '已暂停';
      default:
        return '';
    }
  }

  /** 下载状态颜色 */
  private downloadStatusColor(status: DownloadStatus): string {
    switch (status) {
      case DownloadStatus.PENDING:
        return MUTED_FG;
      case DownloadStatus.DOWNLOADING:
        return PRIMARY;
      case DownloadStatus.COMPLETED:
        return '#FF4CAF50';
      case DownloadStatus.FAILED:
        return ERROR;
      case DownloadStatus.PAUSED:
        return '#FFFF9800';
      default:
        return MUTED_FG;
    }
  }

  /** 下载任务行 */
  @Builder
  downloadTaskRow(task: DownloadTask) {
    Row({ space: 12 }) {
      Column({ space: 4 }) {
        Text(task.comicTitle).fontSize(FS_CAPTION).fontColor(GRAY_900)
          .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis }).width('100%')
        Text(task.title).fontSize(FS_SMALL).fontColor(MUTED_FG)
          .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis }).width('100%')
        // 进度信息
        Row({ space: 8 }) {
          Text(this.downloadStatusText(task.status))
            .fontSize(FS_SMALL).fontColor(this.downloadStatusColor(task.status))
          if (task.totalImages > 0) {
            Text(`${task.downloadedImages}/${task.totalImages}`)
              .fontSize(FS_SMALL).fontColor(MUTED_FG)
          }
          if (task.errorMsg.length > 0) {
            Text(task.errorMsg).fontSize(FS_SMALL).fontColor(ERROR)
              .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
          }
        }
        // 进度条
        if (task.status === DownloadStatus.DOWNLOADING || task.status === DownloadStatus.PAUSED) {
          Progress({ value: task.downloadedImages, total: task.totalImages > 0 ? task.totalImages : 1,
            type: ProgressType.Linear })
            .width('100%').color(PRIMARY).backgroundColor(GRAY_100)
            .style({ strokeWidth: 4 })
        }
      }
      .layoutWeight(1).alignItems(HorizontalAlign.Start)

      // 操作按钮
      if (task.status === DownloadStatus.DOWNLOADING) {
        Column() {
          SymbolGlyph($r('sys.symbol.pause')).fontSize(18).fontColor([MUTED_FG])
        }
        .width(36).height(36).justifyContent(FlexAlign.Center).borderRadius(18)
        .backgroundColor(GRAY_100)
        .onClick(() => { downloadService.pauseTask(task.id); })
      } else if (task.status === DownloadStatus.PAUSED) {
        Column() {
          SymbolGlyph($r('sys.symbol.play')).fontSize(18).fontColor([PRIMARY])
        }
        .width(36).height(36).justifyContent(FlexAlign.Center).borderRadius(18)
        .backgroundColor(PRIMARY_50)
        .onClick(() => { downloadService.resumeTask(task.id); })
      } else if (task.status === DownloadStatus.FAILED) {
        Column() {
          SymbolGlyph($r('sys.symbol.arrow_clockwise')).fontSize(18).fontColor([PRIMARY])
        }
        .width(36).height(36).justifyContent(FlexAlign.Center).borderRadius(18)
        .backgroundColor(PRIMARY_50)
        .onClick(() => { downloadService.retryTask(task.id); })
      }

      // 删除按钮
      Column() {
        SymbolGlyph($r('sys.symbol.trash')).fontSize(18).fontColor([ERROR])
      }
      .width(36).height(36).justifyContent(FlexAlign.Center).borderRadius(18)
      .backgroundColor(GRAY_100)
      .onClick(() => {
        promptAction.showDialog({
          title: '删除任务',
          message: '确定删除下载任务"' + task.title + '"吗？',
          buttons: [
            { text: '取消', color: GRAY_500 },
            { text: '删除', color: ERROR }
          ]
        }).then((res: promptAction.ShowDialogSuccessResponse) => {
          if (res.index === 1) {
            downloadQueueStore.removeTask(task.id);
          }
        }).catch((e: Error) => {});
      })
    }
    .width('100%').padding({ left: SPACE_3, right: SPACE_3, top: 12, bottom: 12 })
    .backgroundColor(CARD).borderRadius(RADIUS_MD)
  }

  /** 下载空态 */
  @Builder
  downloadEmptyView() {
    Column({ space: 10 }) {
      SymbolGlyph($r('sys.symbol.arrow_down')).fontSize(40).fontColor([GRAY_100])
      Text('暂无下载任务，在漫画详情页点击下载按钮添加').fontSize(FS_SMALL).fontColor(MUTED_FG)
    }
    .width('100%').layoutWeight(1).justifyContent(FlexAlign.Center)
  }

  /** 下载管理顶栏 */
  @Builder
  downloadToolBar() {
    Row({ space: 8 }) {
      Text('下载管理').fontSize(FS_SMALL).fontColor(GRAY_900).fontWeight(FontWeight.Medium)
      Blank()
      // 清除已完成
      if (downloadQueueStore.getStats().completed > 0) {
        Text('清除已完成').fontSize(FS_SMALL).fontColor(PRIMARY)
          .onClick(() => {
            downloadQueueStore.clearCompleted();
            promptAction.showToast({ message: '已清除完成的任务' });
          })
      }
    }
    .width('92%').margin({ top: 4, bottom: 4 })
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
          if (index === 3) {
            this.refreshFavState();
          }
        }
      })
      .width('92%')
      .margin({ top: 12, bottom: 4 })

      // 本地 tab 顶栏下方导入栏
      if (this.tab === 0) {
        this.importBar()
      }

      // 下载 tab: 下载管理顶栏
      if (this.tab === 2) {
        this.downloadToolBar()
      }

      // 收藏 tab: 文件夹选择栏 + 管理按钮
      if (this.tab === 3) {
        Row({ space: 8 }) {
          this.favFolderBar()
          // 管理按钮
          Row() {
            SymbolGlyph($r('sys.symbol.square_grid_2x2')).fontSize(14)
              .fontColor([this.manageMode ? PRIMARY : GRAY_500])
            Text(this.manageMode ? '完成' : '管理').fontSize(FS_SMALL)
              .fontColor(this.manageMode ? PRIMARY : GRAY_500).margin({ left: 4 })
          }
          .height(32).padding({ left: 10, right: 10 }).borderRadius(16)
          .backgroundColor(this.manageMode ? PRIMARY_50 : GRAY_100)
          .justifyContent(FlexAlign.Center)
          .onClick(() => { this.toggleManage(); })
        }
        .width('92%').margin({ top: 4, bottom: 4 })
      }

      // 内容区域
      if (this.tab === 2) {
        // 下载 Tab: 任务列表
        if (this.downloadTasks.length === 0) {
          this.downloadEmptyView()
        } else {
          List({ space: 8 }) {
            ForEach(this.downloadTasks, (task: DownloadTask) => {
              ListItem() { this.downloadTaskRow(task) }
            }, (task: DownloadTask) => task.id)
          }
          .width('100%').padding({ left: SPACE_3, right: SPACE_3 }).layoutWeight(1)
        }
      } else if (this.tab === 3) {
        // 收藏 Tab: 使用 FavoriteItem 网格
        if (this.favItems.length === 0) {
          this.favEmptyView()
        } else {
          Grid() {
            ForEach(this.favItems, (item: FavoriteItem) => {
              GridItem() { this.favCoverCell(item) }
            }, (item: FavoriteItem) => item.id)
          }
          .columnsTemplate(this.columns())
          .columnsGap(12).rowsGap(12)
          .width('100%').padding({ left: SPACE_3, right: SPACE_3 }).layoutWeight(1)
        }
      } else {
        // 本地/历史 Tab: 使用 ShelfItem 网格
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
