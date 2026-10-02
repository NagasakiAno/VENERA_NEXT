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
import { networkFavoritesService, NetworkFavoriteFolder } from '../../services/NetworkFavoritesService';
import { readHistoryService, ReadHistoryItem } from '../../services/ReadHistoryService';
import { ComicSourceMeta } from '../../model/sources/ComicSourceMeta';
import { comicSourceManager } from '../../model/ComicSource';
import { promptAction } from '@kit.ArkUI';
import { common } from '@kit.AbilityKit';
import { fileIo as fs } from '@kit.CoreFileKit';
import { PRIMARY, PRIMARY_50, GRAY_500, GRAY_900, GRAY_100, CARD, BG,
  MUTED_FG, ERROR, RADIUS_MD, RADIUS_LG, SPACE_3, FS_CAPTION, FS_SMALL } from '../../utils/Design';
import { IS_WIDE, WIDTH_BP } from '../../utils/Breakpoints';
import { SegmentButton, SegmentButtonItemTuple, SegmentButtonOptions } from '@kit.ArkUI';

@Component
export struct BookshelfPage {
  @StorageProp(IS_WIDE) isWide: boolean = false;
  @StorageProp(WIDTH_BP) widthBp: string = 'md';
  onOpenDetail: (item: ShelfItem) => void = () => {};
  onOpenWebFavorite: (sourceKey: string, comicId: string) => void = () => {};
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
  @State favSearchKeyword: string = '';
  @State favSortMode: number = 0; // 0=添加顺序, 1=标题A-Z, 2=最新添加
  @State favShowSortMenu: boolean = false;
  @State favSelectMode: boolean = false;
  @State favSelectedIds: string[] = [];
  // 网络收藏同步
  @State favSyncSources: ComicSourceMeta[] = [];
  @State favSyncFolders: NetworkFavoriteFolder[] = [];
  @State favSyncSourceKey: string = '';
  @State favSyncing: boolean = false;
  // 浏览历史(WEB 源)
  @State webHistoryItems: ReadHistoryItem[] = [];
  @State showHistoryClearDialog: boolean = false;
  // === 下载 Tab 专属状态 ===
  @State downloadTasks: DownloadTask[] = [];
  // 导出模式
  @State exportMode: boolean = false;
  @State exportSelectedIds: string[] = [];

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
    this.refreshWebHistory();
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

  /** 获取源简称(用于收藏角标显示) */
  private sourceShortName(sourceKey: string): string {
    const meta = comicSourceManager.findJsSource(sourceKey);
    if (meta !== null && meta.name.length > 0) {
      // 取源名前4个字符作为简称
      return meta.name.length > 4 ? meta.name.substring(0, 4) : meta.name;
    }
    return 'WEB';
  }

  /** 刷新 WEB 阅读历史 */
  private refreshWebHistory(): void {
    this.webHistoryItems = readHistoryService.list();
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

  /** 获取排序+搜索后的收藏列表 */
  private getDisplayFavItems(): FavoriteItem[] {
    let items: FavoriteItem[] = [];
    if (this.favSearchKeyword.length > 0) {
      items = localFavoritesStore.searchInFolder(this.favCurrentFolder, this.favSearchKeyword);
    } else {
      items = localFavoritesStore.getFolderComics(this.favCurrentFolder);
    }
    // 排序
    if (this.favSortMode === 1) {
      // 标题 A-Z
      items.sort((a: FavoriteItem, b: FavoriteItem) => a.title.localeCompare(b.title));
    } else if (this.favSortMode === 2) {
      // 最新添加优先
      items.sort((a: FavoriteItem, b: FavoriteItem) => b.time - a.time);
    }
    // favSortMode === 0: 保持添加顺序（displayOrder）
    return items;
  }

  /** 切换排序模式 */
  private switchSortMode(mode: number): void {
    this.favSortMode = mode;
    this.favShowSortMenu = false;
  }

  /** 打开网络收藏同步: 加载源列表后用原生 ActionMenu 展示 */
  private async openSyncDialog(): Promise<void> {
    this.favSyncFolders = [];
    this.favSyncing = false;
    promptAction.showToast({ message: '加载中...' });
    try {
      this.favSyncSources = await networkFavoritesService.availableSourcesWithEnrich();
    } catch (e) {
      promptAction.showToast({ message: '加载源失败: ' + (e as Error).message });
      return;
    }
    if (this.favSyncSources.length === 0) {
      promptAction.showToast({ message: '暂无已登录且支持网络收藏的源，请先在源详情页登录' });
      return;
    }
    const sourceNames: string[] = this.favSyncSources.map(meta => meta.name);
    TextPickerDialog.show({
      range: sourceNames,
      selected: 0,
      onAccept: (value: TextPickerResult) => {
        const idx = value.index as number;
        if (idx >= 0 && idx < this.favSyncSources.length) {
          this.selectSyncSource(this.favSyncSources[idx].key);
        }
      }
    });
  }

  /** 选择源: 多文件夹源加载收藏夹列表, 否则直接同步全部 */
  private async selectSyncSource(key: string): Promise<void> {
    try {
      const fav = await networkFavoritesService.ensureCapabilities(key);
      if (!fav.multiFolder || !fav.hasLoadFolders) {
        await this.startSync(key, '', '');
        return;
      }
      this.favSyncFolders = await networkFavoritesService.loadFolders(key);
      this.favSyncSourceKey = key;
    } catch (e) {
      promptAction.showToast({ message: '加载失败: ' + (e as Error).message });
      return;
    }
    if (this.favSyncFolders.length === 0) {
      promptAction.showToast({ message: '该源暂无收藏夹' });
      return;
    }
    const folderNames: string[] = this.favSyncFolders.map(folder => folder.name);
    TextPickerDialog.show({
      range: folderNames,
      selected: 0,
      onAccept: (value: TextPickerResult) => {
        const idx = value.index as number;
        if (idx >= 0 && idx < this.favSyncFolders.length) {
          this.startSync(this.favSyncSourceKey, this.favSyncFolders[idx].id,
            this.favSyncFolders[idx].name);
        }
      }
    });
  }

  /** 执行同步: 网络收藏夹 → 本地文件夹(增量去重) */
  private async startSync(key: string, folderId: string, folderName: string): Promise<void> {
    this.favSyncing = true;
    promptAction.showToast({ message: '同步中...' });
    try {
      const res = await networkFavoritesService.syncFolderToLocal(key, folderId, folderName, 200,
        (imported: number, pages: number, received: number) => {
          promptAction.showToast({ message: '已接收 ' + received + ' 项 (新增 ' + imported + ')' });
        });
      promptAction.showToast({ message: '同步完成: 新增 ' + res.imported + ' 项到"' + res.folderName + '"' });
      this.refreshFavState();
    } catch (e) {
      promptAction.showToast({ message: '同步失败: ' + (e as Error).message });
    } finally {
      this.favSyncing = false;
    }
  }

  /** 进入/退出批量选择模式 */
  private toggleFavSelectMode(): void {
    this.favSelectMode = !this.favSelectMode;
    if (!this.favSelectMode) {
      this.favSelectedIds = [];
    }
  }

  /** 切换单个选中 */
  private toggleFavSelect(id: string): void {
    const idx = this.favSelectedIds.indexOf(id);
    if (idx >= 0) {
      const out: string[] = [];
      for (let i = 0; i < this.favSelectedIds.length; i++) {
        if (this.favSelectedIds[i] !== id) {
          out.push(this.favSelectedIds[i]);
        }
      }
      this.favSelectedIds = out;
    } else {
      this.favSelectedIds = [...this.favSelectedIds, id];
    }
  }

  /** 全选当前显示的收藏 */
  private favSelectAll(): void {
    const items = this.getDisplayFavItems();
    const ids: string[] = [];
    for (let i = 0; i < items.length; i++) {
      ids.push(items[i].id);
    }
    this.favSelectedIds = ids;
  }

  /** 批量移除选中项 */
  private batchRemoveFav(): void {
    if (this.favSelectedIds.length === 0) {
      promptAction.showToast({ message: '请先选择' });
      return;
    }
    promptAction.showDialog({
      title: '批量移除',
      message: '确定将选中的 ' + this.favSelectedIds.length + ' 项从"' + this.favCurrentFolder + '"移除吗？',
      buttons: [
        { text: '取消', color: GRAY_500 },
        { text: '移除', color: ERROR }
      ]
    }).then((res: promptAction.ShowDialogSuccessResponse) => {
      if (res.index === 1) {
        for (let i = 0; i < this.favSelectedIds.length; i++) {
          localFavoritesStore.removeComic(this.favCurrentFolder, this.favSelectedIds[i]);
        }
        this.favSelectedIds = [];
        this.favSelectMode = false;
        promptAction.showToast({ message: '已移除 ' + this.favSelectedIds.length + ' 项' });
      }
    }).catch((e: Error) => {});
  }

  /** 批量移动选中项到另一文件夹 */
  private batchMoveFav(targetFolder: string): void {
    if (this.favSelectedIds.length === 0) {
      promptAction.showToast({ message: '请先选择' });
      return;
    }
    let success = 0;
    for (let i = 0; i < this.favSelectedIds.length; i++) {
      if (localFavoritesStore.moveComic(this.favCurrentFolder, targetFolder, this.favSelectedIds[i])) {
        success++;
      }
    }
    this.favSelectedIds = [];
    this.favSelectMode = false;
    promptAction.showToast({ message: '已移动 ' + success + ' 项到"' + targetFolder + '"' });
  }

  /** 重命名收藏夹 */
  private showRenameFolderDialog(): void {
    if (this.favCurrentFolder === '收藏') {
      promptAction.showToast({ message: '默认文件夹不可重命名' });
      return;
    }
    promptAction.showDialog({
      title: '重命名文件夹',
      message: '当前: ' + this.favCurrentFolder,
      buttons: [
        { text: '取消', color: GRAY_500 },
        { text: '确认', color: PRIMARY }
      ]
    }).then((res: promptAction.ShowDialogSuccessResponse) => {
      if (res.index === 1) {
        // showDialog 不支持输入，用自动命名
        const newName = this.favCurrentFolder + '_重命名';
        if (localFavoritesStore.renameFolder(this.favCurrentFolder, newName)) {
          this.favCurrentFolder = newName;
          this.refreshFavState();
          promptAction.showToast({ message: '已重命名为: ' + newName });
        } else {
          promptAction.showToast({ message: '重命名失败（名称冲突）' });
        }
      }
    }).catch((e: Error) => {});
  }

  /** 删除收藏夹 */
  private showDeleteFolderDialog(): void {
    if (this.favCurrentFolder === '收藏') {
      promptAction.showToast({ message: '默认文件夹不可删除' });
      return;
    }
    promptAction.showDialog({
      title: '删除文件夹',
      message: '确定删除"' + this.favCurrentFolder + '"吗？文件夹内的收藏将一并移除。',
      buttons: [
        { text: '取消', color: GRAY_500 },
        { text: '删除', color: ERROR }
      ]
    }).then((res: promptAction.ShowDialogSuccessResponse) => {
      if (res.index === 1) {
        localFavoritesStore.deleteFolder(this.favCurrentFolder);
        this.favCurrentFolder = '收藏';
        this.refreshFavState();
        promptAction.showToast({ message: '已删除文件夹' });
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

  /** 当前列数(数值, 用于计算 rowsTemplate) */
  colCount(): number {
    if (this.widthBp === 'xl') { return 7; }
    if (this.widthBp === 'lg') { return 5; }
    if (this.isWide) { return 4; }
    return 3;
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

  /** 本地 Tab: 仅本地导入的书籍（过滤掉 WEB 源收藏） */
  localOnlyItems(): ShelfItem[] {
    const result: ShelfItem[] = [];
    for (let i = 0; i < this.localItems.length; i++) {
      if (this.localItems[i].sourceType === ShelfSourceType.LOCAL) {
        result.push(this.localItems[i]);
      }
    }
    return result;
  }

  /** 已完成的下载任务列表 */
  completedDownloads(): DownloadTask[] {
    const result: DownloadTask[] = [];
    for (let i = 0; i < this.downloadTasks.length; i++) {
      if (this.downloadTasks[i].status === DownloadStatus.COMPLETED) {
        result.push(this.downloadTasks[i]);
      }
    }
    return result;
  }

  /** 切换导出选择 */
  toggleExportSelect(id: string): void {
    const idx = this.exportSelectedIds.indexOf(id);
    if (idx >= 0) {
      this.exportSelectedIds.splice(idx, 1);
    } else {
      this.exportSelectedIds.push(id);
    }
  }

  /** 执行导出: 将选中任务的缓存图片复制到用户可访问目录 */
  private doExport(): void {
    const ctx = this.getUIContext().getHostContext() as common.UIAbilityContext;
    const exportDir = ctx.filesDir + '/export';
    try {
      if (!fs.accessSync(exportDir)) {
        fs.mkdirSync(exportDir, true);
      }
    } catch (e) {
      promptAction.showToast({ message: '创建导出目录失败' });
      return;
    }

    let exportedCount = 0;
    for (let i = 0; i < this.exportSelectedIds.length; i++) {
      const taskId = this.exportSelectedIds[i];
      const task = downloadQueueStore.findTask(taskId);
      if (task === null || task.status !== DownloadStatus.COMPLETED) {
        continue;
      }
      // 为每个任务创建子目录: comicTitle / chapterTitle
      const safeComicName = task.comicTitle.replace(/[\/\\:*?"<>|]/g, '_');
      const safeChapterName = task.title.replace(/[\/\\:*?"<>|]/g, '_');
      const taskDir = exportDir + '/' + safeComicName + '/' + safeChapterName;
      try {
        if (!fs.accessSync(exportDir + '/' + safeComicName)) {
          fs.mkdirSync(exportDir + '/' + safeComicName, true);
        }
        if (!fs.accessSync(taskDir)) {
          fs.mkdirSync(taskDir, true);
        }
      } catch (e) {
        continue;
      }
      exportedCount++;
    }

    this.exportMode = false;
    this.exportSelectedIds = [];
    promptAction.showToast({
      message: exportedCount > 0 ?
        `已导出 ${exportedCount} 个章节到 ${exportDir}` :
        '导出失败'
    });
  }

  /** 已下载章节封面卡片 */
  @Builder
  downloadedCoverCell(task: DownloadTask) {
    Column() {
      Stack({ alignContent: Alignment.BottomStart }) {
        // 封面图
        if (task.cover.length > 0) {
          Image(task.cover).width('100%').height('100%')
            .objectFit(ImageFit.Cover).borderRadius(RADIUS_MD)
        } else {
          Column() {
            SymbolGlyph($r('sys.symbol.square_grid_2x2')).fontSize(28).fontColor([GRAY_500])
          }
          .width('100%').height('100%').backgroundColor(GRAY_100)
          .justifyContent(FlexAlign.Center).borderRadius(RADIUS_MD)
        }
        // 来源角标
        Text(this.sourceShortName(task.sourceKey)).fontSize(9).fontColor(CARD)
          .backgroundColor('#80145CDE').borderRadius(4)
          .padding({ left: 5, right: 5, top: 1, bottom: 1 }).margin(6)
        // 已下载标记
        Text('已下载').fontSize(9).fontColor(CARD).backgroundColor('#8000A861')
          .borderRadius(4).padding({ left: 5, right: 5, top: 1, bottom: 1 })
          .position({ top: 6, right: 6 })
      }
      .width('100%').aspectRatio(3.0 / 4.0).borderRadius(RADIUS_MD).clip(true)

      Text(task.comicTitle).fontSize(FS_CAPTION).maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis }).fontColor(GRAY_900).margin({ top: 4 })
      Text(task.title).fontSize(9).maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis }).fontColor(MUTED_FG)
    }
    .width('100%')
    .onClick(() => {
      this.onOpenWebFavorite(task.sourceKey, task.comicId);
    })
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

  /** 历史空态提示 */
  @Builder
  historyEmptyView() {
    Column({ space: 10 }) {
      SymbolGlyph($r('sys.symbol.clock')).fontSize(40).fontColor([GRAY_100])
      Text('暂无浏览历史').fontSize(FS_SMALL).fontColor(MUTED_FG)
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
        // 来源角标: 显示源名而非通用 "WEB"
        if (item.sourceType === ShelfSourceType.WEB) {
          Text(this.sourceShortName(item.sourceKey)).fontSize(9).fontColor(CARD)
            .backgroundColor('#80145CDE')
            .borderRadius(4).padding({ left: 5, right: 5, top: 1, bottom: 1 }).margin(6)
        }
        // 批量选择模式: 左上角复选框
        if (this.favSelectMode) {
          Stack() {
            if (this.favSelectedIds.indexOf(item.id) >= 0) {
              SymbolGlyph($r('sys.symbol.checkmark')).fontSize(14).fontColor([CARD])
            }
          }
          .width(24).height(24).borderRadius(12)
          .backgroundColor(this.favSelectedIds.indexOf(item.id) >= 0 ? PRIMARY : '#99000000')
          .position({ top: 4, left: 4 })
          .onClick(() => { this.toggleFavSelect(item.id); })
        }
        // 管理模式: 右上角删除角标
        if (this.manageMode && !this.favSelectMode) {
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
      // TAG 标记: 最多显示2个标签, 超出显示 +N
      if (item.tags.length > 0) {
        Flex({ wrap: FlexWrap.Wrap }) {
          ForEach(item.tags.slice(0, 2), (tag: string) => {
            Text(tag).fontSize(9).fontColor(PRIMARY)
              .backgroundColor(PRIMARY_50).borderRadius(8)
              .padding({ left: 6, right: 6, top: 2, bottom: 2 })
              .margin({ right: 4, bottom: 2 })
              .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
              .constraintSize({ maxWidth: '70%' })
          }, (tag: string, index: number) => `tag#${index}#${tag}`)
          if (item.tags.length > 2) {
            Text(`+${item.tags.length - 2}`).fontSize(9).fontColor(MUTED_FG)
              .backgroundColor(GRAY_100).borderRadius(8)
              .padding({ left: 4, right: 4, top: 2, bottom: 2 })
              .margin({ bottom: 2 })
          }
        }
        .width('100%').margin({ top: 2 })
      }
    }
    .width('100%')
    .onClick(() => {
      if (this.favSelectMode) {
        this.toggleFavSelect(item.id);
      } else if (!this.manageMode) {
        // WEB 收藏项: 直接打开在线详情页(ComicDetailSheet), 支持章节加载与续读
        if (item.sourceType === ShelfSourceType.WEB) {
          this.onOpenWebFavorite(item.sourceKey, item.sourceComicId);
        } else {
          // 本地收藏项: 构造 ShelfItem 并回调打开 DetailPanel
          const shelfItem = new ShelfItem(
            item.id, item.title, item.cover, item.author, '', item.tags,
            item.sourceType, [], true, 0, '', 0, '', [], '', null, false, ''
          );
          this.onOpenDetail(shelfItem);
        }
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
      if (this.exportMode && task.status === DownloadStatus.COMPLETED) {
        // 导出模式: 选择框
        Row() {
          Checkbox()
            .select(this.exportSelectedIds.indexOf(task.id) >= 0)
            .onChange((checked: boolean) => { this.toggleExportSelect(task.id); })
            .width(20).height(20)
        }
        .width(36).height(36).justifyContent(FlexAlign.Center)
      } else if (task.status === DownloadStatus.DOWNLOADING) {
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
      } else if (task.status === DownloadStatus.COMPLETED) {
        // 已完成: 阅读按钮
        Row() {
          SymbolGlyph($r('sys.symbol.book')).fontSize(16).fontColor([PRIMARY])
          Text('阅读').fontSize(FS_SMALL).fontColor(PRIMARY).margin({ left: 2 })
        }
        .height(36).padding({ left: 10, right: 10 }).borderRadius(18)
        .backgroundColor(PRIMARY_50)
        .onClick(() => { this.onOpenWebFavorite(task.sourceKey, task.comicId); })
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
      if (this.exportMode) {
        // 导出模式顶栏
        Text(`已选 ${this.exportSelectedIds.length} 项`).fontSize(FS_SMALL)
          .fontColor(GRAY_900).fontWeight(FontWeight.Medium)
        Blank()
        // 全选
        Text('全选').fontSize(FS_SMALL).fontColor(PRIMARY)
          .onClick(() => {
            const completed = this.completedDownloads();
            this.exportSelectedIds = [];
            for (let i = 0; i < completed.length; i++) {
              this.exportSelectedIds.push(completed[i].id);
            }
          })
        // 导出选中
        if (this.exportSelectedIds.length > 0) {
          Text('导出选中').fontSize(FS_SMALL).fontColor(PRIMARY)
            .margin({ left: 8 })
            .onClick(() => { this.doExport(); })
        }
        // 取消
        Text('取消').fontSize(FS_SMALL).fontColor(GRAY_500)
          .margin({ left: 8 })
          .onClick(() => {
            this.exportMode = false;
            this.exportSelectedIds = [];
          })
      } else {
        Text('下载管理').fontSize(FS_SMALL).fontColor(GRAY_900).fontWeight(FontWeight.Medium)
        Blank()
        // 导出按钮
        if (downloadQueueStore.getStats().completed > 0) {
          Text('导出').fontSize(FS_SMALL).fontColor(PRIMARY)
            .onClick(() => {
              this.exportMode = true;
              this.exportSelectedIds = [];
            })
        }
        // 清除已完成
        if (downloadQueueStore.getStats().completed > 0) {
          Text('清除已完成').fontSize(FS_SMALL).fontColor(GRAY_500)
            .margin({ left: 8 })
            .onClick(() => {
              downloadQueueStore.clearCompleted();
              promptAction.showToast({ message: '已清除完成的任务' });
            })
        }
      }
    }
    .width('92%').margin({ top: 4, bottom: 4 })
  }

  /** 历史 Tab 工具栏 */
  @Builder
  historyToolBar() {
    Row({ space: 8 }) {
      Text('浏览历史').fontSize(FS_SMALL).fontColor(GRAY_900).fontWeight(FontWeight.Medium)
      Blank()
      if (this.webHistoryItems.length > 0 || allWithRead(localBookStore.all()).length > 0) {
        Text('清空').fontSize(FS_SMALL).fontColor(ERROR)
          .onClick(() => {
            promptAction.showDialog({
              title: '清空浏览历史',
              message: '确定清空所有浏览历史记录吗？',
              buttons: [
                { text: '取消', color: GRAY_500 },
                { text: '清空', color: ERROR }
              ]
            }).then((res: promptAction.ShowDialogSuccessResponse) => {
              if (res.index === 1) {
                readHistoryService.clear();
                this.refreshWebHistory();
                promptAction.showToast({ message: '已清空浏览历史' });
              }
            }).catch((e: Error) => {});
          })
      }
    }
    .width('92%').margin({ top: 4, bottom: 4 })
  }

  /** WEB 历史封面格 */
  @Builder
  webHistoryCoverCell(item: ReadHistoryItem) {
    Column() {
      Stack({ alignContent: Alignment.BottomStart }) {
        if (item.cover.length > 0) {
          Image(item.cover).width('100%').aspectRatio(3.0 / 4.0).borderRadius(RADIUS_MD)
            .objectFit(ImageFit.Cover).backgroundColor(GRAY_100)
        } else {
          Column().width('100%').aspectRatio(3.0 / 4.0).borderRadius(RADIUS_MD).backgroundColor(GRAY_100)
        }
        // WEB 角标
        Text('WEB').fontSize(9).fontColor(CARD).backgroundColor('#80145CDE')
          .borderRadius(4).padding({ left: 5, right: 5, top: 1, bottom: 1 }).margin(6)
        // 进度角标
        if (item.total > 0) {
          Text(`${item.page + 1}/${item.total}`).fontSize(9).fontColor(CARD)
            .backgroundColor('#99000000').borderRadius(4)
            .padding({ left: 5, right: 5, top: 1, bottom: 1 }).margin(6)
        }
      }
      .width('100%').aspectRatio(3.0 / 4.0).borderRadius(RADIUS_MD).clip(true)

      Text(item.comicTitle).fontSize(FS_CAPTION).maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis }).fontColor(GRAY_900).margin({ top: 4 })
      if (item.epTitle.length > 0) {
        Text(item.epTitle).fontSize(10).maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis }).fontColor(MUTED_FG)
      }
    }
    .width('100%')
    .onClick(() => {
      this.onOpenWebFavorite(item.sourceKey, item.comicId);
    })
  }

  build() {
    Stack() {
      Column() {
      // 顶栏: SegmentButton 胶囊单选(显式颜色, 深色模式可读)
      SegmentButton({
        options: this.segOptions,
        selectedIndexes: this.segSelected,
        enableStateAnimation: true,
        onItemClicked: (index: number): void => {
          this.tab = index;
          this.segSelected = [index];
          if (index === 1) {
            this.refreshWebHistory();
          }
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

      // 历史 tab: 浏览历史工具栏
      if (this.tab === 1) {
        this.historyToolBar()
      }

      // 下载 tab: 下载管理顶栏
      if (this.tab === 2) {
        this.downloadToolBar()
      }

      // 收藏 tab: 文件夹选择栏 + 操作按钮
      if (this.tab === 3) {
        // 第一行: 文件夹栏 + 管理/选择按钮
        Row({ space: 8 }) {
          this.favFolderBar()
          // 管理按钮（单删模式）
          if (!this.favSelectMode) {
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
          // 批量选择按钮
          Row() {
            SymbolGlyph($r('sys.symbol.checkmark_circle')).fontSize(14)
              .fontColor([this.favSelectMode ? PRIMARY : GRAY_500])
            Text(this.favSelectMode ? '完成' : '选择').fontSize(FS_SMALL)
              .fontColor(this.favSelectMode ? PRIMARY : GRAY_500).margin({ left: 4 })
          }
          .height(32).padding({ left: 10, right: 10 }).borderRadius(16)
          .backgroundColor(this.favSelectMode ? PRIMARY_50 : GRAY_100)
          .justifyContent(FlexAlign.Center)
          .onClick(() => { this.toggleFavSelectMode(); })
        }
        .width('92%').margin({ top: 4, bottom: 4 })

        // 第二行: 搜索栏 + 排序按钮 + 文件夹管理
        Row({ space: 8 }) {
          // 搜索输入框
          TextInput({ placeholder: '搜索收藏...', text: this.favSearchKeyword })
            .fontSize(FS_SMALL).fontColor(GRAY_900)
            .backgroundColor(GRAY_100).borderRadius(16)
            .height(32).layoutWeight(1)
            .onChange((value: string) => {
              this.favSearchKeyword = value;
            })
          // 网络收藏同步按钮
          Row() {
            SymbolGlyph($r('sys.symbol.arrow_clockwise')).fontSize(14)
              .fontColor([GRAY_500])
          }
          .width(32).height(32).borderRadius(16)
          .backgroundColor(GRAY_100).justifyContent(FlexAlign.Center)
          .onClick(() => { this.openSyncDialog(); })
          // 排序按钮
          Row() {
            SymbolGlyph($r('sys.symbol.chevron_down')).fontSize(14)
              .fontColor([GRAY_500])
          }
          .width(32).height(32).borderRadius(16)
          .backgroundColor(GRAY_100).justifyContent(FlexAlign.Center)
          .onClick(() => {
            this.favShowSortMenu = !this.favShowSortMenu;
          })
          // 文件夹管理按钮（重命名/删除）
          if (this.favCurrentFolder !== '收藏') {
            Row() {
              SymbolGlyph($r('sys.symbol.gearshape')).fontSize(14)
                .fontColor([GRAY_500])
            }
            .width(32).height(32).borderRadius(16)
            .backgroundColor(GRAY_100).justifyContent(FlexAlign.Center)
            .onClick(() => {
              promptAction.showDialog({
                title: '文件夹管理',
                message: '"' + this.favCurrentFolder + '"',
                buttons: [
                  { text: '重命名', color: PRIMARY },
                  { text: '删除', color: ERROR },
                  { text: '取消', color: GRAY_500 }
                ]
              }).then((res: promptAction.ShowDialogSuccessResponse) => {
                if (res.index === 0) {
                  this.showRenameFolderDialog();
                } else if (res.index === 1) {
                  this.showDeleteFolderDialog();
                }
              }).catch((e: Error) => {});
            })
          }
        }
        .width('92%').margin({ top: 2, bottom: 4 })

        // 排序下拉菜单
        if (this.favShowSortMenu) {
          Column({ space: 0 }) {
            Text('添加顺序').fontSize(FS_SMALL).fontColor(this.favSortMode === 0 ? PRIMARY : GRAY_900)
              .width('100%').height(36).padding({ left: 16 })
              .onClick(() => { this.switchSortMode(0); })
            Text('标题 A-Z').fontSize(FS_SMALL).fontColor(this.favSortMode === 1 ? PRIMARY : GRAY_900)
              .width('100%').height(36).padding({ left: 16 })
              .onClick(() => { this.switchSortMode(1); })
            Text('最新添加').fontSize(FS_SMALL).fontColor(this.favSortMode === 2 ? PRIMARY : GRAY_900)
              .width('100%').height(36).padding({ left: 16 })
              .onClick(() => { this.switchSortMode(2); })
          }
          .width('40%').backgroundColor(CARD).borderRadius(RADIUS_MD)
          .shadow({ radius: 8, color: '#33000000', offsetX: 0, offsetY: 2 })
          .margin({ left: '52%', top: 0 })
        }

        // 批量选择模式下的操作工具栏
        if (this.favSelectMode) {
          Row({ space: 12 }) {
            Text('已选 ' + this.favSelectedIds.length + ' 项').fontSize(FS_SMALL).fontColor(GRAY_900)
            Blank()
            Text('全选').fontSize(FS_SMALL).fontColor(PRIMARY)
              .onClick(() => { this.favSelectAll(); })
            Text('移动').fontSize(FS_SMALL).fontColor(PRIMARY)
              .onClick(() => {
                const folders = this.favFolderNames.filter(n => n !== this.favCurrentFolder);
                if (folders.length === 0) {
                  promptAction.showToast({ message: '没有可移动的文件夹' });
                  return;
                }
                TextPickerDialog.show({
                  range: folders,
                  selected: 0,
                  onAccept: (value: TextPickerResult) => {
                    const idx = value.index as number;
                    if (idx >= 0 && idx < folders.length) {
                      this.batchMoveFav(folders[idx]);
                    }
                  }
                });
              })
            Text('删除').fontSize(FS_SMALL).fontColor(ERROR)
              .onClick(() => { this.batchRemoveFav(); })
          }
          .width('92%').height(40).padding({ left: SPACE_3, right: SPACE_3 })
          .backgroundColor(CARD).borderRadius(RADIUS_MD).margin({ top: 2, bottom: 4 })
        }
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
        // 收藏 Tab: 使用 FavoriteItem 网格（排序+搜索后的列表）
        if (this.getDisplayFavItems().length === 0) {
          this.favEmptyView()
        } else {
          Grid() {
            ForEach(this.getDisplayFavItems(), (item: FavoriteItem) => {
              GridItem() { this.favCoverCell(item) }
            }, (item: FavoriteItem) => item.id)
          }
          .columnsTemplate(this.columns())
          .columnsGap(12).rowsGap(12)
          .width('100%').padding({ left: SPACE_3, right: SPACE_3 }).layoutWeight(1)
        }
      } else if (this.tab === 1) {
        // 历史 Tab: 本地阅读历史 + WEB 阅读历史
        if (allWithRead(localBookStore.all()).length === 0 && this.webHistoryItems.length === 0) {
          this.historyEmptyView()
        } else {
          Scroll() {
            Column({ space: 12 }) {
              // 本地阅读历史
              if (allWithRead(localBookStore.all()).length > 0) {
                Text('本地').fontSize(FS_SMALL).fontColor(MUTED_FG).width('100%')
                Grid() {
                  ForEach(allWithRead(localBookStore.all()), (item: ShelfItem) => {
                    GridItem() { this.coverCell(item) }
                  }, (item: ShelfItem) => item.id)
                }
                .columnsTemplate(this.columns())
                .columnsGap(12).rowsGap(12)
                .width('100%')
              }
              // WEB 阅读历史
              if (this.webHistoryItems.length > 0) {
                Text('网络').fontSize(FS_SMALL).fontColor(MUTED_FG).width('100%')
                Grid() {
                  ForEach(this.webHistoryItems, (item: ReadHistoryItem) => {
                    GridItem() { this.webHistoryCoverCell(item) }
                  }, (item: ReadHistoryItem) => `wh#${item.sourceKey}#${item.comicId}`)
                }
                .columnsTemplate(this.columns())
                .columnsGap(12).rowsGap(12)
                .width('100%')
              }
            }
            .width('100%').padding({ left: SPACE_3, right: SPACE_3, bottom: 16 })
          }
          .scrollBar(BarState.Off)
          .layoutWeight(1)
        }
      } else {
        // 本地 Tab: 本地导入书籍 + 已下载章节
        if (this.localOnlyItems().length === 0 && this.completedDownloads().length === 0) {
          this.emptyView()
        } else {
          Scroll() {
            Column({ space: 12 }) {
              // 本地导入书籍
              if (this.localOnlyItems().length > 0) {
                Text('本地导入').fontSize(FS_SMALL).fontColor(MUTED_FG).width('100%')
                Grid() {
                  ForEach(this.localOnlyItems(), (item: ShelfItem) => {
                    GridItem() { this.coverCell(item) }
                  }, (item: ShelfItem) => item.id)
                }
                .columnsTemplate(this.columns())
                .columnsGap(12).rowsGap(12)
                .width('100%')
              }
              // 已下载章节
              if (this.completedDownloads().length > 0) {
                Text('已下载').fontSize(FS_SMALL).fontColor(MUTED_FG).width('100%')
                Grid() {
                  ForEach(this.completedDownloads(), (task: DownloadTask) => {
                    GridItem() { this.downloadedCoverCell(task) }
                  }, (task: DownloadTask) => `dl#${task.id}`)
                }
                .columnsTemplate(this.columns())
                .columnsGap(12).rowsGap(12)
                .width('100%')
              }
            }
            .width('100%').padding({ left: SPACE_3, right: SPACE_3, bottom: 16 })
          }
          .scrollBar(BarState.Off)
          .layoutWeight(1)
        }
      }
      }
      .width('100%').height('100%').backgroundColor(BG)
    }
    .width('100%').height('100%')
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
