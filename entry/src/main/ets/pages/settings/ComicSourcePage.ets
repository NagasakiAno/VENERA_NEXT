/**
 * VeneraNext 漫画源管理页 (ComicSourcePage)
 * 对应原版 lib/pages/comic_source_page.dart
 * 功能: URL安装 / 本地文件安装 / 源列表(版本/更新/删除) / 仓库列表 / 检查更新
 */
import { picker } from '@kit.CoreFileKit';
import { fileIo as fs } from '@kit.CoreFileKit';
import { util } from '@kit.ArkTS';
import { promptAction, router } from '@kit.ArkUI';
import { common } from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { HttpClient, HttpResponseData, HttpMethod, ResponseType } from '../../network/HttpClient';
import { ComicSourceMeta } from '../../model/sources/ComicSourceMeta';
import { compareSemVer } from '../../model/sources/ComicSourceParser';
import { comicSourceManager } from '../../model/ComicSource';
import { jsSourceManager, InstallResult } from '../../services/JsSourceManager';
import { jsSourceRepo, RepoSourceEntry } from '../../services/JsSourceRepo';
import { appSettings } from '../../model/AppSettings';
import { PRIMARY, PRIMARY_50, GRAY_500, GRAY_900, GRAY_100, CARD, BG,
  MUTED_FG, ERROR, SUCCESS, RADIUS_MD, RADIUS_LG, SPACE_2, SPACE_3, SPACE_4,
  FS_TITLE, FS_SECTION, FS_CAPTION, FS_SMALL } from '../../utils/Design';
import { SOURCE_API_DOC } from '../../utils/SourceApiDoc';

const DOMAIN = 0x0000;
const TAG = 'ComicSourcePage';

/** 跳转源详情的路由参数 */
interface DetailParams {
  key: string;
}

@Entry
@Component
export struct ComicSourcePage {
  @State sources: ComicSourceMeta[] = [];
  @State listUrl: string = '';
  @State repoList: RepoSourceEntry[] = [];
  @State showRepo: boolean = false;
  @State loading: boolean = false;
  @State loadingText: string = '加载中...';
  @State urlInput: string = '';
  @State showApiDoc: boolean = false;
  @State savingDoc: boolean = false;
  // 按压缩放交互(与全局交互统一)
  @State pressedKey: string = '';

  private ctx: common.UIAbilityContext | null = null;

  // 按压缩放交互处理(与全局统一: 120ms EaseOut)
  pressTouch(e: TouchEvent, key: string): void {
    if (e.type === TouchType.Down) {
      animateTo({ duration: 120, curve: Curve.EaseOut }, () => { this.pressedKey = key; });
    } else if (e.type === TouchType.Up || e.type === TouchType.Cancel) {
      animateTo({ duration: 120, curve: Curve.EaseOut }, () => { this.pressedKey = ''; });
    }
  }

  pressScaleOf(key: string): number {
    return this.pressedKey === key ? 0.92 : 1;
  }

  /** 显示加载遮罩 */
  private startLoading(text: string): void {
    this.loadingText = text;
    this.loading = true;
  }

  /** 隐藏加载遮罩 */
  private stopLoading(): void {
    this.loading = false;
  }

  aboutToAppear(): void {
    this.ctx = this.getUIContext().getHostContext() as common.UIAbilityContext;
    this.listUrl = this.baseListUrl();
    this.refresh();
  }

  /** 系统返回事件: 先关闭弹层, 再返回上一页 */
  onBackPress(): boolean {
    if (this.showApiDoc) {
      this.showApiDoc = false;
      return true;
    }
    if (this.showRepo) {
      this.showRepo = false;
      return true;
    }
    router.back();
    return true;
  }

  /** 保存接口文档到临时文件系统(应用沙箱临时目录) */
  private async saveApiDoc(): Promise<void> {
    if (this.ctx === null) {
      return;
    }
    this.savingDoc = true;
    try {
      // 临时文件系统接口: 写入 ctx.tempDir, 目录不存在则先创建
      const dir = this.ctx.tempDir;
      if (!fs.accessSync(dir)) {
        fs.mkdirSync(dir, true);
      }
      const path = dir + '/source_api_doc.md';
      const file = fs.openSync(path, fs.OpenMode.CREATE | fs.OpenMode.READ_WRITE | fs.OpenMode.TRUNC);
      // writeSync 直接接受字符串(内部 UTF-8 编码), 绕开 TextEncoder 缓冲隐患
      fs.writeSync(file.fd, SOURCE_API_DOC);
      fs.closeSync(file);
      promptAction.showToast({ message: '已保存到: ' + path });
    } catch (e) {
      promptAction.showToast({ message: '保存失败: ' + (e as Error).message });
    } finally {
      this.savingDoc = false;
    }
  }

  private baseListUrl(): string {
    const v = appSettings.get<string>('comicSourceListUrl', '');
    return v.length > 0 ? v : jsSourceRepo.defaultListUrl();
  }

  private refresh(): void {
    this.sources = comicSourceManager.allJsSources();
  }

  private async fetchJs(url: string): Promise<string> {
    const resp: HttpResponseData = await HttpClient.getInstance().rawRequest({
      url: url,
      method: HttpMethod.GET,
      responseType: ResponseType.TEXT,
      headers: { 'Cache-Control': 'no-cache' }
    });
    if (resp.status >= 200 && resp.status < 300 && resp.body.length > 0) {
      return resp.body;
    }
    hilog.error(DOMAIN, TAG, 'fetchJs failed status=%{public}d err=%{public}s url=%{public}s',
      resp.status, resp.error, url);
    return '';
  }

  /** 按 URL 安装 — 如果 URL 指向 index.json 仓库，自动打开源仓库弹层 */
  private async installByUrl(url: string): Promise<void> {
    if (url.length === 0 || this.ctx === null) {
      return;
    }
    // 检测是否为仓库地址 (index.json 或 .json 结尾)
    if (url.endsWith('.json') || url.includes('index.json')) {
      this.listUrl = url;
      this.openRepo();
      return;
    }
    this.startLoading('下载脚本中...');
    try {
      const js = await this.fetchJs(url);
      if (js.length === 0) {
        promptAction.showToast({ message: '下载失败' });
        return;
      }
      this.loadingText = '解析中...';
      const r: InstallResult = await jsSourceManager.installFromText(this.ctx, js, 'temp.js');
      if (r.ok) {
        promptAction.showToast({ message: '已安装：' + r.meta!.name });
      } else {
        promptAction.showToast({ message: '安装失败：' + r.error });
      }
      this.refresh();
    } catch (e) {
      promptAction.showToast({ message: '安装失败' });
    } finally {
      this.stopLoading();
    }
  }

  /** 本地文件安装(.js) */
  private async installByFile(): Promise<void> {
    if (this.ctx === null) {
      return;
    }
    try {
      const p = new picker.DocumentViewPicker(this.ctx);
      const opts = new picker.DocumentSelectOptions();
      opts.fileSuffixFilters = ['.js'];
      opts.maxSelectNumber = 1;
      const uris: string[] = await p.select(opts);
      if (uris.length === 0) {
        return;
      }
      // 读临时 uri(循环读满, 防大文件一次读不全)
      let text = '';
      try {
        const src = fs.openSync(uris[0], fs.OpenMode.READ_ONLY);
        const stat = fs.statSync(src.fd);
        const buf = new ArrayBuffer(stat.size);
        let read = 0;
        while (read < stat.size) {
          const n = fs.readSync(src.fd, buf, { offset: read, length: stat.size - read });
          if (n <= 0) {
            break;
          }
          read += n;
        }
        fs.closeSync(src);
        const decoder = util.TextDecoder.create('utf-8');
        text = decoder.decodeToString(new Uint8Array(buf));
        hilog.info(DOMAIN, TAG, 'local js read size=%{public}d', read);
      } catch (e) {
        hilog.error(DOMAIN, TAG, 'read local js failed: %{public}s', (e as Error).message);
        promptAction.showToast({ message: '读取文件失败：' + (e as Error).message });
        return;
      }
      const r: InstallResult = await jsSourceManager.installFromText(this.ctx, text, 'local.js');
      if (r.ok) {
        promptAction.showToast({ message: '已安装：' + r.meta!.name });
      } else {
        promptAction.showToast({ message: '安装失败：' + r.error });
      }
      this.refresh();
    } catch (e) {
      promptAction.showToast({ message: '安装失败：' + (e as Error).message });
    }
  }

  /** 更新单个源 */
  private async updateSource(meta: ComicSourceMeta): Promise<void> {
    if (this.ctx === null || meta.url.length === 0) {
      promptAction.showToast({ message: '该源无更新 URL' });
      return;
    }
    this.startLoading('更新中...');
    try {
      const js = await this.fetchJs(meta.url);
      if (js.length === 0) {
        promptAction.showToast({ message: '下载失败' });
        return;
      }
      const updated = await jsSourceManager.update(this.ctx, meta.key, js);
      promptAction.showToast({ message: updated !== null ? '已更新到 v' + updated.version : '更新失败' });
      this.refresh();
    } catch (e) {
      promptAction.showToast({ message: '更新失败' });
    } finally {
      this.stopLoading();
    }
  }

  /** 删除源 */
  private confirmRemove(meta: ComicSourceMeta): void {
    if (this.ctx === null) {
      return;
    }
    promptAction.showDialog({
      title: '删除源',
      message: '确定删除漫画源「' + meta.name + '」吗？',
      buttons: [
        { text: '取消', color: GRAY_500 },
        { text: '删除', color: ERROR }
      ]
    }).then((res: promptAction.ShowDialogSuccessResponse) => {
      if (res.index === 1) {
        jsSourceManager.remove(this.ctx as common.UIAbilityContext, meta.key);
        promptAction.showToast({ message: '已删除' });
        this.refresh();
      }
    }).catch((e: Error) => {
      // 取消
    });
  }

  /** 拉起仓库弹层(立即打开, 列表区显示加载中) */
  private async openRepo(): Promise<void> {
    this.repoList = [];
    this.showRepo = true;
    this.startLoading('加载源仓库...');
    try {
      this.repoList = await jsSourceRepo.fetchIndexList(this.listUrl);
    } catch (e) {
      this.repoList = [];
    } finally {
      this.stopLoading();
    }
  }

  /** 从仓库安装 */
  private async installFromRepo(entry: RepoSourceEntry): Promise<void> {
    if (this.ctx === null) {
      return;
    }
    // 组装 url: 有 url 用绝对地址; 否则目录 + fileName
    let jsUrl = entry.url;
    if (jsUrl.length === 0 && entry.fileName.length > 0) {
      const base = this.listUrl.substring(0, this.listUrl.lastIndexOf('/'));
      jsUrl = base + '/' + entry.fileName;
    }
    this.startLoading('下载 ' + entry.key + ' 中...');
    try {
      const js = await this.fetchJs(jsUrl);
      if (js.length === 0) {
        promptAction.showToast({ message: '下载失败' });
        return;
      }
      this.loadingText = '解析中...';
      const r: InstallResult = await jsSourceManager.installFromText(this.ctx, js, entry.key + '.js');
      promptAction.showToast({ message: r.ok ? '已安装：' + r.meta!.name : '安装失败：' + r.error });
      if (r.ok) {
        this.repoList = this.repoList.slice();
      }
      this.refresh();
    } catch (e) {
      promptAction.showToast({ message: '安装失败：' + (e as Error).message });
    } finally {
      this.stopLoading();
    }
  }

  /** 打开源详情(设置 + 账号) */
  private openDetail(meta: ComicSourceMeta): void {
    const params: DetailParams = { key: meta.key };
    router.pushUrl({ url: 'pages/settings/SourceDetailPage', params: params })
      .catch((e: Error) => {
        hilog.error(DOMAIN, TAG, '打开源详情失败: %{public}s', `${e}`);
      });
  }

  private isInstalled(key: string): boolean {
    return comicSourceManager.findJsSource(key) !== null;
  }

  /** 仓库弹层 */
  @Builder
  repoSheet() {
    Column() {
      Row() {
        Text('源仓库').fontSize(FS_SECTION).fontWeight(FontWeight.Bold).fontColor(GRAY_900).layoutWeight(1)
        Text('关闭').fontSize(FS_SMALL).fontColor(PRIMARY).onClick(() => { this.showRepo = false; })
      }
      .width('100%').height(44).padding({ left: SPACE_3, right: SPACE_3 })

      TextInput({ text: this.listUrl, placeholder: '仓库 URL' })
        .onChange((v: string) => { this.listUrl = v; })
        .fontColor(GRAY_900)
        .placeholderColor(MUTED_FG)
        .backgroundColor(GRAY_100)
        .width('92%').margin({ bottom: 8 })

      Row() {
        Text('刷新').fontSize(FS_CAPTION).fontColor(PRIMARY)
          .onClick(() => { this.openRepo(); })
        Text(this.repoList.length > 0 ? ('共 ' + this.repoList.length + ' 个源') : '')
          .fontSize(FS_SMALL).fontColor(MUTED_FG).margin({ left: 10 })
      }.width('92%').justifyContent(FlexAlign.End).margin({ bottom: 8 })

      if (this.repoList.length === 0) {
        Column({ space: 10 }) {
          LoadingProgress().width(36).height(36).color(PRIMARY)
          Text(this.loading ? '加载源仓库中...' : '未获取到源列表，请检查网络或仓库 URL 后点「刷新」')
            .fontSize(FS_SMALL).fontColor(MUTED_FG).textAlign(TextAlign.Center)
            .padding({ left: 24, right: 24 })
        }
        .width('100%').layoutWeight(1).justifyContent(FlexAlign.Center)
      } else {
        List() {
          ForEach(this.repoList, (entry: RepoSourceEntry) => {
            ListItem() {
              Row({ space: 10 }) {
                Column() {
                  Text(entry.name).fontSize(FS_CAPTION).fontColor(GRAY_900)
                    .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
                  Text('v' + entry.version + ' · ' + entry.key).fontSize(11).fontColor(MUTED_FG).margin({ top: 2 })
                }.alignItems(HorizontalAlign.Start).layoutWeight(1)

                if (this.isInstalled(entry.key)) {
                  Text('✓ 已安装').fontSize(FS_SMALL).fontColor(SUCCESS)
                } else {
                  Row() {
                    Text('Add').fontSize(FS_SMALL).fontColor(CARD)
                  }
                  .height(30).padding({ left: 14, right: 14 }).borderRadius(15)
                  .backgroundColor(PRIMARY).justifyContent(FlexAlign.Center)
                  .scale({ x: this.pressScaleOf('add' + entry.key), y: this.pressScaleOf('add' + entry.key) })
                  .animation({ duration: 120, curve: Curve.EaseOut })
                  .onClick(() => { this.installFromRepo(entry); })
                  .onTouch((e: TouchEvent) => { this.pressTouch(e, 'add' + entry.key); })
                }
              }
              .width('100%').height(56).padding({ left: SPACE_3, right: SPACE_3 })
              .backgroundColor(CARD).borderRadius(RADIUS_MD)
            }
          }, (entry: RepoSourceEntry) => entry.key + entry.version)
        }
        .width('100%').layoutWeight(1)
      }
    }
    .width('100%').height('100%').backgroundColor(BG)
  }

  /** 源行: 名称/版本/能力 + 操作 */
  @Builder
  sourceRow(meta: ComicSourceMeta) {
    Column({ space: 10 }) {
      // 行1: 名称 + 版本 + 能力徽标
      Row({ space: 8 }) {
        Text(meta.name).fontSize(FS_CAPTION).fontWeight(FontWeight.Medium).fontColor(GRAY_900)
          .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis }).layoutWeight(1)
        Text('v' + meta.version).fontSize(11).fontColor(PRIMARY)
          .padding({ left: 6, right: 6, top: 1, bottom: 1 }).backgroundColor(PRIMARY_50).borderRadius(6)
        Row({ space: 4 }) {
          if (meta.hasLoadInfo) { this.capTag('详情') }
          if (meta.hasLoadEp) { this.capTag('阅读') }
          if (meta.hasSearch) { this.capTag('搜索') }
          if (meta.hasExplore) { this.capTag('发现') }
        }
      }
      .width('100%').alignItems(VerticalAlign.Center)

      // 行2: key + 操作按钮
      Row() {
        Text(meta.key).fontSize(11).fontColor(MUTED_FG).layoutWeight(1)
          .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
        Row({ space: 16 }) {
          Text('设置').fontSize(FS_SMALL).fontColor(GRAY_900)
            .onClick(() => { this.openDetail(meta); })
          Text('更新').fontSize(FS_SMALL).fontColor(PRIMARY)
            .onClick(() => { this.updateSource(meta); })
          Text('删除').fontSize(FS_SMALL).fontColor(ERROR)
            .onClick(() => { this.confirmRemove(meta); })
        }
      }
      .width('100%').alignItems(VerticalAlign.Center)
    }
    .width('100%').padding({ left: SPACE_3, right: SPACE_3, top: 12, bottom: 12 })
    .backgroundColor(CARD).borderRadius(RADIUS_LG).margin({ top: 8 })
  }

  @Builder
  capTag(text: string) {
    Text(text).fontSize(10).fontColor(GRAY_500)
      .padding({ left: 6, right: 6, top: 1, bottom: 1 }).backgroundColor(GRAY_100).borderRadius(5)
  }

  build() {
    Stack() {
      Column() {
        // 顶栏
        Row() {
          Row() {
            SymbolGlyph($r('sys.symbol.chevron_left')).fontSize(18).fontColor([GRAY_500])
          }
          .width(36).height(36).borderRadius(18).backgroundColor(GRAY_100)
          .justifyContent(FlexAlign.Center)
          .onClick(() => { router.back(); })

          Text('漫画源').fontSize(FS_TITLE).fontWeight(FontWeight.Bold).fontColor(GRAY_900).layoutWeight(1)
            .textAlign(TextAlign.Center)
        }
        .width('100%').height(52).padding({ left: SPACE_3, right: SPACE_3 })

        // 安装操作栏
        Column() {
          TextInput({ text: this.urlInput, placeholder: '输入 JS 脚本 URL 或源仓库地址' })
            .onChange((v: string) => { this.urlInput = v; })
            .fontColor(GRAY_900)
            .placeholderColor(MUTED_FG)
            .backgroundColor(GRAY_100)
            .width('100%')
            .onSubmit(() => { this.installByUrl(this.urlInput); })

          Row({ space: 10 }) {
            Row() {
              Text('按 URL 安装').fontSize(FS_SMALL).fontColor(CARD)
            }
            .height(34).padding({ left: 14, right: 14 }).borderRadius(17)
            .backgroundColor(PRIMARY).justifyContent(FlexAlign.Center).layoutWeight(1)
            .onClick(() => { this.installByUrl(this.urlInput); })

            Row() {
              Text('本地文件').fontSize(FS_SMALL).fontColor(GRAY_900)
            }
            .height(34).padding({ left: 14, right: 14 }).borderRadius(17)
            .backgroundColor(GRAY_100).justifyContent(FlexAlign.Center).layoutWeight(1)
            .onClick(() => { this.installByFile(); })
          }
          .width('100%').margin({ top: 8 })
        }
        .width('92%').padding(SPACE_3)
        .backgroundColor(CARD).borderRadius(RADIUS_LG).margin({ top: 6 })

        // 接口文档入口
        Row() {
          Text('源搭建接口文档').fontSize(FS_SMALL).fontColor(PRIMARY).layoutWeight(1)
          if (this.savingDoc) {
            LoadingProgress().width(16).height(16).color(PRIMARY)
          } else {
            Text('保存').fontSize(FS_SMALL).fontColor(PRIMARY)
              .onClick(() => { this.saveApiDoc(); })
          }
          Text('查看').fontSize(FS_SMALL).fontColor(PRIMARY).margin({ left: 16 })
            .onClick(() => { this.showApiDoc = true; })
        }
        .width('92%').height(40).padding({ left: SPACE_3, right: SPACE_3 })
        .backgroundColor(CARD).borderRadius(RADIUS_MD).margin({ top: 8 })

        // 源列表 / 空态
        if (this.sources.length === 0) {
          Column({ space: 8 }) {
            Text('尚未安装漫画源').fontSize(FS_SECTION).fontColor(GRAY_900)
            Text('粘贴 JS 脚本 URL 安装，或输入源仓库地址（index.json）浏览安装').fontSize(FS_SMALL).fontColor(MUTED_FG)
          }
          .width('100%').layoutWeight(1).justifyContent(FlexAlign.Center)
        } else {
          Scroll() {
            Column() {
              ForEach(this.sources, (meta: ComicSourceMeta) => {
                this.sourceRow(meta)
              }, (meta: ComicSourceMeta) => meta.key)
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

      // 仓库弹层
      if (this.showRepo) {
        Column() {
          this.repoSheet()
        }
        .width('100%').height('100%')
        .backgroundColor('#331A1A1E')
        .transition(TransitionEffect.OPACITY.animation({ duration: 200, curve: Curve.EaseOut }))
      }

      // 接口文档弹层
      if (this.showApiDoc) {
        Column() {
          // 顶栏
          Row() {
            Row() {
              SymbolGlyph($r('sys.symbol.chevron_left')).fontSize(18).fontColor([GRAY_500])
            }
            .width(36).height(36).borderRadius(18).backgroundColor(CARD)
            .justifyContent(FlexAlign.Center)
            .onClick(() => { this.showApiDoc = false; })

            Text('源搭建接口文档').fontSize(FS_TITLE).fontWeight(FontWeight.Bold).fontColor(GRAY_900)
              .layoutWeight(1).textAlign(TextAlign.Center)

            Row() {
              if (this.savingDoc) {
                LoadingProgress().width(16).height(16).color(PRIMARY)
              } else {
                Text('保存').fontSize(FS_SMALL).fontColor(PRIMARY)
              }
            }
            .width(48).height(36).justifyContent(FlexAlign.Center)
            .onClick(() => { this.saveApiDoc(); })
          }
          .width('100%').height(52).padding({ left: SPACE_3, right: SPACE_3 })

          Scroll() {
            Text(SOURCE_API_DOC)
              .fontSize(12).fontColor(GRAY_900).lineHeight(18)
              .width('100%')
          }
          .width('100%').layoutWeight(1).scrollBar(BarState.Auto)
        }
        .width('100%').height('100%').backgroundColor(BG)
        .transition(TransitionEffect.OPACITY.animation({ duration: 200, curve: Curve.EaseOut }))
      }

      // 全局加载遮罩(网络操作时提示, 防误以为卡死)
      if (this.loading) {
        Column() {
          Column({ space: 10 }) {
            LoadingProgress().width(42).height(42).color(PRIMARY)
            Text(this.loadingText).fontSize(FS_SMALL).fontColor(GRAY_900)
          }
          .width(140).height(140).borderRadius(RADIUS_LG)
          .backgroundColor(CARD)
          .justifyContent(FlexAlign.Center)
          .shadow({ radius: 24, color: '#33000000', offsetX: 0, offsetY: 6 })
        }
        .width('100%').height('100%')
        .backgroundColor('#20000000')
        .justifyContent(FlexAlign.Center)
        .transition(TransitionEffect.OPACITY.animation({ duration: 150 }))
      }
    }
    .width('100%').height('100%')
  }
}