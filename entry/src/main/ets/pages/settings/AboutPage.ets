/**
 * VeneraNext 关于应用页面
 * 展示应用图标、版本号、免责声明、源项目引用、开源协议、GitHub 地址
 */
import { router } from '@kit.ArkUI';
import { bundleManager } from '@kit.AbilityKit';
import { GRAY_900, GRAY_500, BG, CARD, FS_TITLE, FS_BODY, FS_SMALL,
  SPACE_3, SPACE_4, RADIUS_LG, PRIMARY, MUTED_FG } from '../../utils/Design';
import { DISCLAIMER_TITLE, DISCLAIMER_TEXT } from '../../utils/DisclaimerContent';

@Entry
@Component
export struct AboutPage {
  @State appVersion: string = '';

  aboutToAppear(): void {
    try {
      const info = bundleManager.getBundleInfoForSelfSync(
        bundleManager.BundleFlag.GET_BUNDLE_INFO_DEFAULT
      );
      this.appVersion = info.versionName;
    } catch (e) {
      this.appVersion = '1.0.1';
    }
  }

  build() {
    Column() {
      // 顶栏
      Row() {
        Row() {
          SymbolGlyph($r('sys.symbol.chevron_left')).fontSize(18).fontColor([GRAY_500])
        }
        .width(36).height(36).borderRadius(18).backgroundColor(CARD)
        .justifyContent(FlexAlign.Center)
        .onClick(() => { router.back(); })

        Text('关于应用').fontSize(FS_TITLE).fontWeight(FontWeight.Bold).fontColor(GRAY_900)
          .layoutWeight(1).textAlign(TextAlign.Center)

        Row().width(36)
      }
      .width('100%').height(52).padding({ left: SPACE_3, right: SPACE_3 })

      Scroll() {
        Column({ space: 16 }) {
          // 应用图标 + 名称
          Column({ space: 8 }) {
            Image($r('app.media.app_logo'))
              .width(80).height(80).borderRadius(20)
            Text('VeneraNext').fontSize(20).fontWeight(FontWeight.Bold).fontColor(GRAY_900)
            Text('v' + this.appVersion).fontSize(FS_SMALL).fontColor(PRIMARY)
          }
          .width('100%').justifyContent(FlexAlign.Center)
          .padding({ top: SPACE_4, bottom: SPACE_4 })

          // 项目地址
          Column() {
            Text('项目地址').fontSize(FS_BODY).fontColor(GRAY_900)
              .width('100%').padding({ left: SPACE_3, top: 14 })
            Text('https://github.com/NagasakiAno/VENERA_NEXT')
              .fontSize(FS_SMALL).fontColor(PRIMARY).margin({ top: 4 })
              .width('100%').padding({ left: SPACE_3 })
            Text('基于 GPL-3.0 协议开源').fontSize(11).fontColor(MUTED_FG).margin({ top: 2 })
              .width('100%').padding({ left: SPACE_3, bottom: 14 })
          }
          .width('100%').backgroundColor(CARD).borderRadius(RADIUS_LG)

          // 源项目引用
          Column() {
            Text('源项目引用').fontSize(FS_BODY).fontColor(GRAY_900)
              .width('100%').padding({ left: SPACE_3, top: 14 })
            Text('本项目参考了 venera-app/venera 项目的 JSON 源插件格式设计')
              .fontSize(FS_SMALL).fontColor(GRAY_900).margin({ top: 4 })
              .width('100%').padding({ left: SPACE_3 })
            Text('https://github.com/venera-app/venera')
              .fontSize(FS_SMALL).fontColor(PRIMARY).margin({ top: 4 })
              .width('100%').padding({ left: SPACE_3, bottom: 14 })
          }
          .width('100%').backgroundColor(CARD).borderRadius(RADIUS_LG)

          // 免责声明
          Column() {
            Row() {
              Text(DISCLAIMER_TITLE).fontSize(FS_BODY).fontColor(GRAY_900)
              SymbolGlyph($r('sys.symbol.chevron_right')).fontSize(16).fontColor([GRAY_500])
            }
            .width('100%').justifyContent(FlexAlign.SpaceBetween)
            .padding({ left: SPACE_3, right: SPACE_3, top: 14, bottom: 14 })
          }
          .width('100%').backgroundColor(CARD).borderRadius(RADIUS_LG)
          .onClick(() => { router.pushUrl({ url: 'pages/settings/DisclaimerPage' }); })
        }
        .width('100%').padding({ left: SPACE_4, right: SPACE_4, bottom: SPACE_4 })
      }
      .width('100%').layoutWeight(1).scrollBar(BarState.Auto)
    }
    .width('100%').height('100%').backgroundColor(BG)
  }
}
