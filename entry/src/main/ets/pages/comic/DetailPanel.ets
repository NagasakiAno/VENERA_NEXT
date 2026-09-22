/**
 * VeneraNext 漫画详情面板
 * 提供完整详情: 封面/标题/作者/描述/TAG/章节列表
 * 本地: 收藏 / 继续阅读(上次定位) / 从头阅读 / 自定义描述 / 自定义TAG
 * WEB: 浏览量 / 更新时间 / 下载 / 收藏 / 评论 / 分享 / 章节 / 相关推荐
 */
import { ShelfItem, ShelfSourceType, ShelfChapter } from '../../model/ShelfItem';
import { findShelfItem } from '../../model/DemoData';
import { PRIMARY, PRIMARY_50, GRAY_500, GRAY_900, GRAY_100, CARD, BG,
  MUTED_FG, SUCCESS, WARNING, RADIUS_SM, RADIUS_MD, RADIUS_LG, SPACE_2, SPACE_3, SPACE_4, FS_TITLE,
  FS_SECTION, FS_BODY, FS_CAPTION, FS_SMALL } from '../../utils/Design';

@Component
export struct DetailPanel {
  @Prop itemId: string = '';
  onStartRead: (item: ShelfItem, chapterIndex: number) => void = () => {};
  onBack: () => void = () => {};
  @State cur: ShelfItem | null = null;
  @State rels: ShelfItem[] = [];

  aboutToAppear(): void {
    const it = findShelfItem(this.itemId);
    this.cur = it;
    if (it !== null) {
      const arr: ShelfItem[] = [];
      for (let i = 0; i < it.relatedIds.length; i++) {
        const r = findShelfItem(it.relatedIds[i]);
        if (r !== null) {
          arr.push(r);
        }
      }
      this.rels = arr;
    }
  }

  @Builder
  coverView(item: ShelfItem, w: number, h: number, radius: number) {
    Image(item.cover as Resource | string).width(w).height(h).borderRadius(radius)
      .objectFit(ImageFit.Cover).backgroundColor(GRAY_100)
  }

  @Builder
  sectionTitle(title: string) {
    Text(title).fontSize(FS_SECTION).fontWeight(FontWeight.Bold).fontColor(GRAY_900)
      .width('100%').margin({ top: SPACE_4 })
  }

  @Builder
  tagChip(text: string, bg: string, fg: string) {
    Text(text).fontSize(FS_SMALL).fontColor(fg).backgroundColor(bg)
      .borderRadius(RADIUS_SM).padding({ left: 10, right: 10, top: 4, bottom: 4 }).margin({ right: 8, bottom: 8 })
  }

  @Builder
  mainAction(item: ShelfItem) {
    Row({ space: 10 }) {
      Column({ space: 2 }) {
        SymbolGlyph($r('sys.symbol.heart')).fontSize(22).fontColor([item.isFavorite ? '#FFE8455E' : GRAY_500])
        Text(item.isFavorite ? '已收藏' : '收藏').fontSize(FS_SMALL).fontColor(MUTED_FG)
      }
      .width(56).height(48).justifyContent(FlexAlign.Center).borderRadius(RADIUS_MD).backgroundColor(GRAY_100)

      if (item.lastReadPage > 0) {
        Column() {
          Text('继续阅读').fontSize(15).fontColor('#FFFFFFFF').fontWeight(FontWeight.Medium)
          Text('读到' + item.lastReadChapter + '·' + item.lastReadPage + '页')
            .fontSize(9).fontColor('#CCFFFFFF')
        }
        .height(48).layoutWeight(1).justifyContent(FlexAlign.Center).borderRadius(RADIUS_MD)
        .backgroundColor(WARNING)
        .onClick(() => { this.onStartRead(item, 0); })

        Column() {
          Text('从头阅读').fontSize(15).fontColor(CARD).fontWeight(FontWeight.Medium)
        }
        .height(48).layoutWeight(1).justifyContent(FlexAlign.Center).borderRadius(RADIUS_MD)
        .backgroundColor(PRIMARY)
        .onClick(() => { this.onStartRead(item, 0); })
      } else {
        Column() {
          Text('开始阅读').fontSize(15).fontColor(CARD).fontWeight(FontWeight.Medium)
        }
        .height(48).layoutWeight(1).justifyContent(FlexAlign.Center).borderRadius(RADIUS_MD)
        .backgroundColor(PRIMARY)
        .onClick(() => { this.onStartRead(item, 0); })
      }
    }
    .width('100%').margin({ top: SPACE_3 })
  }

  @Builder
  localEditPlaceholder() {
    Row({ space: 10 }) {
      Row() {
        Text('✎').fontSize(16).fontColor(PRIMARY)
        Text('自定义描述').fontSize(FS_CAPTION).fontColor(PRIMARY).margin({ left: 4 })
      }
      .height(34).padding({ left: 12, right: 12 }).borderRadius(RADIUS_MD)
      .backgroundColor(PRIMARY_50).justifyContent(FlexAlign.Center).layoutWeight(1)

      Row() {
        Text('✎').fontSize(16).fontColor(PRIMARY)
        Text('自定义TAG').fontSize(FS_CAPTION).fontColor(PRIMARY).margin({ left: 4 })
      }
      .height(34).padding({ left: 12, right: 12 }).borderRadius(RADIUS_MD)
      .backgroundColor(PRIMARY_50).justifyContent(FlexAlign.Center).layoutWeight(1)
    }
    .width('100%').margin({ top: SPACE_3 })
  }

  @Builder
  metaCell(val: string, label: string) {
    Column() {
      Text(val).fontSize(FS_BODY).fontWeight(FontWeight.Bold).fontColor(GRAY_900)
      Text(label).fontSize(FS_SMALL).fontColor(MUTED_FG).margin({ top: 2 })
    }.layoutWeight(1)
  }

  @Builder
  webMetaRow(item: ShelfItem) {
    Row() {
      this.metaCell(fmt(item.viewCount), '浏览')
      this.metaCell(item.updateTime.length > 0 ? item.updateTime : '-', '最近更新')
      this.metaCell(item.chapters.length + '', '章节')
    }
    .width('100%').padding({ top: SPACE_3, bottom: SPACE_3, left: SPACE_3, right: SPACE_3 })
    .backgroundColor(CARD).borderRadius(RADIUS_LG).margin({ top: SPACE_3 })
  }

  @Builder
  webActionBtn(symbol: Resource, label: string) {
    Column({ space: 2 }) {
      SymbolGlyph(symbol).fontSize(20).fontColor([GRAY_500])
      Text(label).fontSize(FS_SMALL).fontColor(MUTED_FG)
    }
    .width(72).height(56).justifyContent(FlexAlign.Center).borderRadius(RADIUS_MD).backgroundColor(GRAY_100)
  }

  @Builder
  webActions() {
    Row({ space: 10 }) {
      this.webActionBtn($r('sys.symbol.arrow_down'), '下载')
      this.webActionBtn($r('sys.symbol.bolt'), '评论')
      this.webActionBtn($r('sys.symbol.square_grid_2x2'), '分享')
    }.width('100%').margin({ top: SPACE_3 })
  }

  @Builder
  chapterRow(ch: ShelfChapter, idx: number, item: ShelfItem) {
    Row() {
      Text(ch.name).fontSize(FS_BODY).fontColor(GRAY_900).layoutWeight(1)
        .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
      Text('第' + ch.pages + '页').fontSize(FS_SMALL).fontColor(MUTED_FG)
    }
    .width('100%').height(40).padding({ left: SPACE_3, right: SPACE_3 })
    .onClick(() => { this.onStartRead(item, idx); })
  }

  @Builder
  chapterList(item: ShelfItem) {
    Column() {
      ForEach(item.chapters, (ch: ShelfChapter, idx: number) => {
        this.chapterRow(ch, idx, item)
      }, (ch: ShelfChapter) => ch.name)
    }
    .width('100%').backgroundColor(CARD).borderRadius(RADIUS_LG)
  }

  @Builder
  relatedItem(rel: ShelfItem) {
    Column() {
      this.coverView(rel, 80, 106, RADIUS_MD)
      Text(rel.title).fontSize(FS_SMALL).maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis }).fontColor(GRAY_900).width(80).margin({ top: 4 })
    }
  }

  @Builder
  relatedRow() {
    Scroll() {
      Row({ space: 12 }) {
        ForEach(this.rels, (rel: ShelfItem) => {
          this.relatedItem(rel)
        }, (rel: ShelfItem) => rel.id)
      }.padding({ top: SPACE_3, bottom: SPACE_2 })
    }
    .scrollable(ScrollDirection.Horizontal).scrollBar(BarState.Off).width('100%')
  }

  /** 本地详情主体 */
  @Builder
  localBody(item: ShelfItem) {
    Column() {
      this.headRow(item)
      this.mainAction(item)
      this.localEditPlaceholder()
      this.sectionTitle('简介')
      Text(item.description).fontSize(FS_BODY).fontColor(GRAY_900).lineHeight(21).width('100%').margin({ top: SPACE_2 })
      this.sectionTitle('标签')
      Flex({ wrap: FlexWrap.Wrap }) {
        ForEach(item.tags, (t: string) => { this.tagChip(t, GRAY_100, GRAY_500) }, (t: string) => t)
      }.width('100%').margin({ top: SPACE_2 })
      this.sectionTitle('章节')
      this.chapterList(item)
      Column().height(24)
    }
    .width('100%').padding({ left: SPACE_4, right: SPACE_4, bottom: SPACE_4 })
  }

  /** WEB 详情主体 */
  @Builder
  webBody(item: ShelfItem) {
    Column() {
      this.headRow(item)
      this.mainAction(item)
      this.webMetaRow(item)
      this.webActions()
      this.sectionTitle('简介')
      Text(item.description).fontSize(FS_BODY).fontColor(GRAY_900).lineHeight(21).width('100%').margin({ top: SPACE_2 })
      this.sectionTitle('标签')
      Flex({ wrap: FlexWrap.Wrap }) {
        ForEach(item.tags, (t: string) => { this.tagChip(t, GRAY_100, GRAY_500) }, (t: string) => t)
      }.width('100%').margin({ top: SPACE_2 })
      this.sectionTitle('章节')
      this.chapterList(item)
      this.sectionTitle('相关推荐')
      this.relatedRow()
      Column().height(24)
    }
    .width('100%').padding({ left: SPACE_4, right: SPACE_4, bottom: SPACE_4 })
  }

  @Builder
  headRow(item: ShelfItem) {
    Row({ space: SPACE_3 }) {
      this.coverView(item, 96, 128, RADIUS_MD)
      Column() {
        Text(item.title).fontSize(FS_TITLE).fontWeight(FontWeight.Bold).fontColor(GRAY_900)
          .maxLines(2).textOverflow({ overflow: TextOverflow.Ellipsis })
        Text(item.author).fontSize(FS_CAPTION).fontColor(MUTED_FG).margin({ top: 4 })
        Row({ space: 6 }) {
          this.tagChip(item.sourceType === ShelfSourceType.LOCAL ? '本地' : 'WEB源', PRIMARY_50, PRIMARY)
          this.tagChip(item.isFavorite ? '已收藏' : '连载中', SUCCESS, '#FFFFFFFF')
        }.margin({ top: 6 })
      }
      .alignItems(HorizontalAlign.Start).layoutWeight(1)
    }
    .width('100%').margin({ top: SPACE_3 })
  }

  @Builder
  bodyContent(item: ShelfItem) {
    if (item.sourceType === ShelfSourceType.LOCAL) {
      this.localBody(item)
    } else {
      this.webBody(item)
    }
  }

  build() {
    Scroll() {
      if (this.cur !== null) {
        this.bodyContent(this.cur as ShelfItem)
      } else {
        Column() {
          Text('未找到条目').fontSize(FS_BODY).fontColor(MUTED_FG)
        }.width('100%').height('100%').justifyContent(FlexAlign.Center)
      }
    }
    .scrollBar(BarState.Off).width('100%').height('100%').backgroundColor(BG)
  }
}

function fmt(n: number): string {
  if (n >= 10000) {
    return (n / 10000).toFixed(1) + 'w';
  }
  return n + '';
}