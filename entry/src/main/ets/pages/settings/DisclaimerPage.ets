/**
 * VeneraNext 免责声明浏览页
 * 从设置 > 应用详情 进入，可滚动阅读完整免责声明
 */
import { router } from '@kit.ArkUI';
import { DISCLAIMER_TITLE, DISCLAIMER_TEXT } from '../../utils/DisclaimerContent';
import { GRAY_900, GRAY_500, BG, CARD, FS_TITLE, FS_BODY, FS_SMALL,
  SPACE_3, SPACE_4, RADIUS_LG } from '../../utils/Design';

@Entry
@Component
export struct DisclaimerPage {
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

        Text(DISCLAIMER_TITLE).fontSize(FS_TITLE).fontWeight(FontWeight.Bold).fontColor(GRAY_900)
          .layoutWeight(1).textAlign(TextAlign.Center)

        // 占位保持标题居中
        Row().width(36)
      }
      .width('100%').height(52).padding({ left: SPACE_3, right: SPACE_3 })

      // 声明正文
      Scroll() {
        Column() {
          Text(DISCLAIMER_TEXT)
            .fontSize(FS_BODY).fontColor(GRAY_900).lineHeight(24)
            .width('100%')
        }
        .width('100%').padding({ left: SPACE_4, right: SPACE_4, top: SPACE_3, bottom: SPACE_4 })
      }
      .width('100%').layoutWeight(1).scrollBar(BarState.Auto)
    }
    .width('100%').height('100%').backgroundColor(BG)
  }
}
