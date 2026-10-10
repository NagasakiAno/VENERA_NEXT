/**
 * VeneraNext 设置页
 * 提供 漫画源管理、缓存管理、配置导入导出 等入口
 */
import { router, promptAction } from '@kit.ArkUI';
import { CARD, BG, FS_TITLE, GRAY_900, GRAY_500, MUTED_FG, SPACE_3, SPACE_4,
  RADIUS_LG, PRIMARY, ERROR, FS_BODY, FS_CAPTION, FS_SMALL, SPACE_2, SPACE_5,
  RADIUS_MD, BORDER, PRIMARY_50 } from '../../utils/Design';
import { diskCacheManager } from '../../utils/DiskCacheManager';
import { appSettings } from '../../model/AppSettings';
import { exportConfig, importConfig } from '../../utils/ConfigManager';
import { common, AbilityConstant } from '@kit.AbilityKit';
import { DISCLAIMER_TITLE, DISCLAIMER_TEXT } from '../../utils/DisclaimerContent';

@Component
export struct SettingsPage {
  // === 缓存管理状态 ===
  @State cacheSizeMB: number = 0;
  @State cacheCount: number = 0;
  @State cacheLimitMB: number = 500;
  @State showClearCacheDialog: boolean = false;
  @State clearingCache: boolean = false;
  @State sliderValue: number = 500;

  // === 阅读体验状态 ===
  @State preloadPageCount: number = 3;
  @State preloadSliderValue: number = 3;

  // === 配置导入导出状态 ===
  @State configExporting: boolean = false;
  @State configImporting: boolean = false;

  // === 免责声明弹窗状态 ===
  @State showDisclaimerDialog: boolean = false;

  // === 应用详情状态 === (版本号已移至关于页面)

  aboutToAppear(): void {
    this.refreshCacheInfo();
    this.preloadPageCount = appSettings.get<number>('preloadPageCount', 3);
    this.preloadSliderValue = this.preloadPageCount;
    // 首次打开设置页时检查免责声明是否已同意
    const accepted = appSettings.get<boolean>('disclaimerAccepted', false);
    if (!accepted) {
      this.showDisclaimerDialog = true;
    }
  }

  /** 刷新缓存信息 */
  private refreshCacheInfo(): void {
    this.cacheSizeMB = Math.round(diskCacheManager.getTotalSize() / 1024 / 1024);
    this.cacheCount = diskCacheManager.getCount();
    const limitBytes = appSettings.get<number>('cacheLimit', 500 * 1024 * 1024);
    this.cacheLimitMB = Math.round(limitBytes / 1024 / 1024);
    this.sliderValue = this.cacheLimitMB;
  }

  /** 清除缓存 */
  private async doClearCache(): Promise<void> {
    this.clearingCache = true;
    await diskCacheManager.clear();
    this.clearingCache = false;
    this.showClearCacheDialog = false;
    this.refreshCacheInfo();
    promptAction.showToast({ message: '缓存已清除' });
  }

  /** 设置缓存上限 */
  private async setCacheLimit(mb: number): Promise<void> {
    const bytes = mb * 1024 * 1024;
    await diskCacheManager.setLimit(bytes);
    await appSettings.put('cacheLimit', bytes);
    this.cacheLimitMB = mb;
    this.refreshCacheInfo();
  }

  /** 设置预加载页数 */
  private async setPreloadPageCount(count: number): Promise<void> {
    await appSettings.put('preloadPageCount', count);
    this.preloadPageCount = count;
    this.preloadSliderValue = count;
  }

  /** 导出配置 */
  private async doExportConfig(): Promise<void> {
    this.configExporting = true;
    const ctx = this.getUIContext().getHostContext() as common.UIAbilityContext;
    const ok = await exportConfig(ctx);
    this.configExporting = false;
    promptAction.showToast({
      message: ok ? '配置已导出' : '导出失败'
    });
  }

  /** 导入配置 */
  private async doImportConfig(): Promise<void> {
    this.configImporting = true;
    const ctx = this.getUIContext().getHostContext() as common.UIAbilityContext;
    const ok = await importConfig(ctx);
    this.configImporting = false;
    promptAction.showToast({
      message: ok ? '配置已导入' : '导入失败'
    });
    this.refreshCacheInfo();
  }

  private openSourceManager(): void {
    router.pushUrl({ url: 'pages/settings/ComicSourcePage' }).catch((e: Error) => {
      // 忽略跳转失败
    });
  }

  /** 用户同意免责声明 — 同步更新内存, 确保立即生效 */
  private acceptDisclaimer(): void {
    appSettings.setSync('disclaimerAccepted', true);
    this.showDisclaimerDialog = false;
  }

  /** 用户拒绝免责声明 — 退出 APP */
  private rejectDisclaimer(): void {
    this.showDisclaimerDialog = false;
    const ctx = this.getUIContext().getHostContext() as common.UIAbilityContext;
    ctx.terminateSelf();
  }

  /** 打开免责声明浏览页 */
  private openDisclaimerPage(): void {
    router.pushUrl({ url: 'pages/settings/DisclaimerPage' }).catch((e: Error) => {
      // 忽略跳转失败
    });
  }

  @Builder
  settingRow(title: string, sub: string) {
    Row() {
      Column() {
        Text(title).fontSize(15).fontColor(GRAY_900)
        Text(sub).fontSize(12).fontColor(MUTED_FG).margin({ top: 2 })
      }.alignItems(HorizontalAlign.Start).layoutWeight(1)
      SymbolGlyph($r('sys.symbol.chevron_right')).fontSize(16).fontColor([GRAY_500])
    }
    .width('100%').height(64).padding({ left: SPACE_3, right: SPACE_3 })
    .backgroundColor(CARD).borderRadius(RADIUS_LG)
  }

  @Builder
  sectionHeader(title: string) {
    Text(title).fontSize(FS_CAPTION).fontColor(MUTED_FG)
      .width('100%')
      .margin({ top: SPACE_4, bottom: SPACE_2 })
  }

  build() {
    Stack() {
      Scroll() {
        Column() {
          // 顶栏
          Row() {
            Text('设置').fontSize(FS_TITLE).fontWeight(FontWeight.Bold).fontColor(GRAY_900)
          }
          .width('100%').height(56).padding({ left: SPACE_4 }).alignItems(VerticalAlign.Center)

          Column({ space: 10 }) {
            // === 漫画源管理 ===
            this.sectionHeader('漫画源')
            Column() {
              this.settingRow('漫画源管理', '安装/更新/删除 JS 漫画源')
            }
            .width('100%')
            .onClick(() => { this.openSourceManager(); })

            // === 缓存管理 ===
            this.sectionHeader('缓存管理')

            // 缓存信息卡片
            Column() {
              Row() {
                Column() {
                  Text('图片缓存').fontSize(FS_BODY).fontColor(GRAY_900)
                  Text(`${this.cacheSizeMB} MB · ${this.cacheCount} 个文件`)
                    .fontSize(FS_SMALL).fontColor(MUTED_FG).margin({ top: 2 })
                }.alignItems(HorizontalAlign.Start).layoutWeight(1)

                if (this.clearingCache) {
                  LoadingProgress().width(24).height(24).color(PRIMARY)
                } else {
                  Button('清除')
                    .fontSize(FS_SMALL).fontColor(ERROR)
                    .backgroundColor(Color.Transparent)
                    .borderWidth(1).borderColor(ERROR).borderRadius(RADIUS_MD)
                    .height(32).padding({ left: 12, right: 12 })
                    .onClick(() => { this.showClearCacheDialog = true; })
                }
              }
              .width('100%').padding(SPACE_3)

              // 缓存上限 Slider
              Column() {
                Row() {
                  Text('缓存上限').fontSize(FS_SMALL).fontColor(MUTED_FG)
                  Text(`${this.cacheLimitMB} MB`).fontSize(FS_SMALL).fontColor(PRIMARY)
                    .margin({ left: 8 })
                }
                .width('100%').justifyContent(FlexAlign.SpaceBetween)

                Slider({
                  value: this.sliderValue,
                  min: 100,
                  max: 2048,
                  step: 50,
                  style: SliderStyle.OutSet
                })
                  .width('100%').height(40)
                  .trackColor(BORDER)
                  .selectedColor(PRIMARY)
                  .blockColor(PRIMARY)
                  .onChange((value: number, mode: SliderChangeMode) => {
                    this.cacheLimitMB = Math.round(value);
                    if (mode === SliderChangeMode.End || mode === SliderChangeMode.Click) {
                      this.setCacheLimit(this.cacheLimitMB);
                    }
                  })
              }
              .width('100%').padding({ left: SPACE_3, right: SPACE_3, bottom: SPACE_3 })
            }
            .width('100%').backgroundColor(CARD).borderRadius(RADIUS_LG)

            // === 阅读体验 ===
            this.sectionHeader('阅读体验')

            // 预加载页数卡片
            Column() {
              Row() {
                Text('预加载页数').fontSize(FS_BODY).fontColor(GRAY_900)
                Text(`${this.preloadPageCount} 页`).fontSize(FS_SMALL).fontColor(PRIMARY)
                  .margin({ left: 8 })
              }
              .width('100%').justifyContent(FlexAlign.SpaceBetween)
              .padding({ left: SPACE_3, right: SPACE_3, top: SPACE_3 })

              Text('翻页时提前加载的漫画页数，越大越流畅但占用更多内存')
                .fontSize(FS_SMALL).fontColor(MUTED_FG)
                .margin({ top: 2, left: SPACE_3, right: SPACE_3 })

              Slider({
                value: this.preloadSliderValue,
                min: 1,
                max: 10,
                step: 1,
                style: SliderStyle.OutSet
              })
                .width('100%').height(40)
                .trackColor(BORDER)
                .selectedColor(PRIMARY)
                .blockColor(PRIMARY)
                .padding({ left: SPACE_3, right: SPACE_3 })
                .onChange((value: number, mode: SliderChangeMode) => {
                  this.preloadPageCount = Math.round(value);
                  if (mode === SliderChangeMode.End || mode === SliderChangeMode.Click) {
                    this.setPreloadPageCount(this.preloadPageCount);
                  }
                })
            }
            .width('100%').backgroundColor(CARD).borderRadius(RADIUS_LG)
            .padding({ bottom: SPACE_3 })

            // === 配置管理 ===
            this.sectionHeader('配置管理')

            Row() {
              Column() {
                Text('导出配置').fontSize(FS_BODY).fontColor(GRAY_900)
                Text('导出源列表、收藏、阅读设置').fontSize(FS_SMALL).fontColor(MUTED_FG)
                  .margin({ top: 2 })
              }.alignItems(HorizontalAlign.Start).layoutWeight(1)

              if (this.configExporting) {
                LoadingProgress().width(24).height(24).color(PRIMARY)
              } else {
                Button('导出')
                  .fontSize(FS_SMALL).fontColor(PRIMARY)
                  .backgroundColor(Color.Transparent)
                  .borderWidth(1).borderColor(PRIMARY).borderRadius(RADIUS_MD)
                  .height(32).padding({ left: 12, right: 12 })
                  .onClick(() => { this.doExportConfig(); })
              }
            }
            .width('100%').height(64).padding({ left: SPACE_3, right: SPACE_3 })
            .backgroundColor(CARD).borderRadius(RADIUS_LG)

            Row() {
              Column() {
                Text('导入配置').fontSize(FS_BODY).fontColor(GRAY_900)
                Text('从备份文件恢复源列表、收藏、设置').fontSize(FS_SMALL).fontColor(MUTED_FG)
                  .margin({ top: 2 })
              }.alignItems(HorizontalAlign.Start).layoutWeight(1)

              if (this.configImporting) {
                LoadingProgress().width(24).height(24).color(PRIMARY)
              } else {
                Button('导入')
                  .fontSize(FS_SMALL).fontColor(PRIMARY)
                  .backgroundColor(Color.Transparent)
                  .borderWidth(1).borderColor(PRIMARY).borderRadius(RADIUS_MD)
                  .height(32).padding({ left: 12, right: 12 })
                  .onClick(() => { this.doImportConfig(); })
              }
            }
            .width('100%').height(64).padding({ left: SPACE_3, right: SPACE_3 })
            .backgroundColor(CARD).borderRadius(RADIUS_LG)

            // === 关于应用 ===
            this.sectionHeader('关于')

            // 关于应用入口
            Column() {
              Row() {
                Text('关于应用').fontSize(FS_BODY).fontColor(GRAY_900)
                SymbolGlyph($r('sys.symbol.chevron_right')).fontSize(16).fontColor([GRAY_500])
              }
              .width('100%').justifyContent(FlexAlign.SpaceBetween)
              .padding({ left: SPACE_3, right: SPACE_3, top: 14, bottom: 14 })
            }
            .width('100%').backgroundColor(CARD).borderRadius(RADIUS_LG)
            .onClick(() => { router.pushUrl({ url: 'pages/settings/AboutPage' }); })
          }
          .width('100%').padding({ left: SPACE_4, right: SPACE_4, bottom: 80 })
        }
        .width('100%')
      }
      .width('100%').height('100%').backgroundColor(BG)
      .scrollBar(BarState.Auto)

      // 清除缓存确认弹窗(叠加层)
      if (this.showClearCacheDialog) {
        Column() {
          Column() {
            Text('清除缓存').fontSize(FS_BODY).fontWeight(FontWeight.Bold).fontColor(GRAY_900)
            Text(`将删除 ${this.cacheSizeMB} MB 的缓存图片，不影响已下载的章节。`)
              .fontSize(FS_SMALL).fontColor(MUTED_FG).margin({ top: 8 })
            Row({ space: 12 }) {
              Button('取消')
                .fontSize(FS_SMALL).fontColor(GRAY_500)
                .backgroundColor(Color.Transparent)
                .layoutWeight(1)
                .onClick(() => { this.showClearCacheDialog = false; })
              Button('清除')
                .fontSize(FS_SMALL).fontColor(CARD)
                .backgroundColor(ERROR)
                .layoutWeight(1)
                .onClick(() => { this.doClearCache(); })
            }
            .margin({ top: 16 })
          }
          .width('80%').padding(SPACE_4)
          // 半透明模糊材质底框(与全局弹层统一)
          .backgroundColor('#B3FFFFFF')
          .backgroundBlurStyle(BlurStyle.COMPONENT_ULTRA_THICK)
          .clip(true)
          .borderRadius(RADIUS_LG)
        }
        .width('100%').height('100%')
        .backgroundColor('#99000000')
        .justifyContent(FlexAlign.Center)
        .onClick(() => { this.showClearCacheDialog = false; })
      }

      // 免责声明弹窗(首次打开设置页时显示)
      if (this.showDisclaimerDialog) {
        Column() {
          Column() {
            Text(DISCLAIMER_TITLE).fontSize(FS_BODY).fontWeight(FontWeight.Bold).fontColor(GRAY_900)
            Scroll() {
              Text(DISCLAIMER_TEXT)
                .fontSize(FS_SMALL).fontColor(GRAY_900).lineHeight(20)
                .width('100%')
            }
            .width('100%').height(300).margin({ top: 12 })

            Row({ space: 12 }) {
              Button('拒绝')
                .fontSize(FS_SMALL).fontColor(ERROR)
                .backgroundColor(Color.Transparent)
                .borderWidth(1).borderColor(ERROR).borderRadius(RADIUS_MD)
                .layoutWeight(1)
                .onClick(() => { this.rejectDisclaimer(); })
              Button('知晓并同意')
                .fontSize(FS_SMALL).fontColor(CARD)
                .backgroundColor(PRIMARY)
                .borderRadius(RADIUS_MD)
                .layoutWeight(1)
                .onClick(() => { this.acceptDisclaimer(); })
            }
            .margin({ top: 16 })
          }
          .width('85%').padding(SPACE_4)
          // 半透明模糊材质底框(与全局弹层统一)
          .backgroundColor('#B3FFFFFF')
          .backgroundBlurStyle(BlurStyle.COMPONENT_ULTRA_THICK)
          .clip(true)
          .borderRadius(RADIUS_LG)
        }
        .width('100%').height('100%')
        .backgroundColor('#99000000')
        .justifyContent(FlexAlign.Center)
      }
    }
    .width('100%').height('100%')
  }
}
