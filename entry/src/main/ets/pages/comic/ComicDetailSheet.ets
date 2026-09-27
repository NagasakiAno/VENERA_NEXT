/**
 * 在线漫画详情的统一呈现容器
 *
 * 与本地书籍详情(Index 的 portraitDetailSheet/landscapeDetailSheet)同款交互:
 *   - 竖屏: 底部半模态 bindSheet(560 高, 自绘拖拽条)
 *   - 横屏: 右侧 360 宽滑入面板 + 半透明遮罩(点击关闭)
 * 宿主:
 *   - Index(发现/搜索 bubble 到窗口根层, 横屏面板可盖住 sidebar)
 *   - CategoryComicsPage(路由页, 自挂在自身窗口根 Stack)
 */
import { ComicDetailPage } from './ComicDetailPage';
import { GRAY_100, BG } from '../../utils/Design';
import { IS_WIDE } from '../../utils/Breakpoints';

@Component
export struct ComicDetailSheet {
  @Prop visible: boolean = false;
  @Prop sourceKey: string = '';
  @Prop sourceName: string = '';
  @Prop comicId: string = '';
  onClose: () => void = () => {};
  @StorageProp(IS_WIDE) isWide: boolean = false;

  @Builder
  dragPill() {
    Row() {
      Column().width(36).height(4).borderRadius(2).backgroundColor(GRAY_100)
    }.width('100%').height(20).justifyContent(FlexAlign.Center)
  }

  /** 横屏: 右侧滑入面板 */
  @Builder
  landscapePanel() {
    Row() {
      // 半透明遮罩(点击关闭)
      Column().width('100%').height('100%').backgroundColor('#40000000').layoutWeight(1)
        .onClick(() => {
          this.onClose();
        })
      Column() {
        this.dragPill()
        ComicDetailPage({
          sourceKey: this.sourceKey,
          sourceName: this.sourceName,
          comicId: this.comicId
        })
          .width('100%').layoutWeight(1)
      }
      .width(360).height('100%').backgroundColor(BG)
      .padding({ top: 40 })
      .borderRadius({ topLeft: 20, bottomLeft: 20 })
      .transition(TransitionEffect.OPACITY.combine(TransitionEffect.translate({ x: 360 }))
        .animation({ duration: 280, curve: Curve.EaseOut }))
    }
    .width('100%').height('100%').alignItems(VerticalAlign.Top)
  }

  /** 竖屏: bindSheet 内容 */
  @Builder
  portraitContent() {
    Column() {
      this.dragPill()
      ComicDetailPage({
        sourceKey: this.sourceKey,
        sourceName: this.sourceName,
        comicId: this.comicId
      })
        .width('100%').layoutWeight(1)
    }
    .width('100%').backgroundColor(BG)
  }

  build() {
    Stack() {
      // 横屏呈现(窗口级覆盖层); 竖屏时 Stack 为空壳, 仅承载 bindSheet
      if (this.isWide && this.visible) {
        this.landscapePanel()
      }
    }
    .width('100%').height('100%')
    // 常驻全屏空壳: 自身对触摸透明, 避免挡住底层页面的点击;
    // 面板显示时子节点(遮罩/内容)照常响应
    .hitTestBehavior(HitTestMode.None)
    .bindSheet(!this.isWide && this.visible, this.portraitContent(), {
      height: 560,
      dragBar: false,
      backgroundColor: Color.Transparent,
      showClose: false,
      onDisappear: (): void => {
        this.onClose();
      }
    })
  }
}
