/**
 * VeneraNext 设置页
 * 提供 漫画源管理 等入口
 */
import { router } from '@kit.ArkUI';
import { CARD, BG, FS_TITLE, GRAY_900, GRAY_500, MUTED_FG, SPACE_3, SPACE_4, RADIUS_LG } from '../../utils/Design';

@Component
export struct SettingsPage {
  private openSourceManager(): void {
    router.pushUrl({ url: 'pages/settings/ComicSourcePage' }).catch((e: Error) => {
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

  build() {
    Column() {
      Row() {
        Text('设置').fontSize(FS_TITLE).fontWeight(FontWeight.Bold).fontColor(GRAY_900)
      }
      .width('100%').height(56).padding({ left: SPACE_4 }).alignItems(VerticalAlign.Center)

      Column({ space: 10 }) {
        Column() {
          this.settingRow('漫画源管理', '安装/更新/删除 JS 漫画源，配置源仓库')
        }
        .width('100%')
        .onClick(() => { this.openSourceManager(); })
      }
      .width('100%').padding({ left: SPACE_4, right: SPACE_4 }).layoutWeight(1)

    }
    .width('100%').height('100%').backgroundColor(BG)
  }
}