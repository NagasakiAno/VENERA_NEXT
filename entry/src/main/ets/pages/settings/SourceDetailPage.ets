/**
 * VeneraNext 源详情页 (SourceDetailPage)
 * 对应原版 comic_source_page.dart 中的源详情面板
 * 功能: 渲染源声明的 settings(select/switch/input/callback) + 账号(账密/Cookies/登出)
 */
import { promptAction, router } from '@kit.ArkUI';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { comicSourceManager } from '../../model/ComicSource';
import { ComicSourceMeta, SettingDef } from '../../model/sources/ComicSourceMeta';
import { sourceDataStore } from '../../services/SourceDataStore';
import { jsRuntime } from '../../runtime/JsRuntime';
import { PRIMARY, PRIMARY_50, GRAY_100, GRAY_500, GRAY_900, CARD, BG,
  MUTED_FG, ERROR, SUCCESS, RADIUS_MD, RADIUS_LG, SPACE_2, SPACE_3, SPACE_4,
  FS_TITLE, FS_SECTION, FS_BODY, FS_CAPTION, FS_SMALL } from '../../utils/Design';

const DOMAIN = 0x0000;
const TAG = 'SourceDetailPage';

/** 路由参数 */
interface DetailParams {
  key: string;
}

/** 一个设置项的界面状态 */
class SettingRow {
  key: string = '';
  title: string = '';
  type: string = 'input';
  value: string = '';
  draft: string = '';
  options: string[] = [];
  labels: string[] = [];

  /** 当前值在 options 中的显示名 */
  currentLabel(): string {
    const idx = this.options.indexOf(this.value);
    if (idx >= 0 && idx < this.labels.length && this.labels[idx].length > 0) {
      return this.labels[idx];
    }
    return this.value;
  }

  labelAt(index: number): string {
    if (index >= 0 && index < this.labels.length && this.labels[index].length > 0) {
      return this.labels[index];
    }
    if (index >= 0 && index < this.options.length) {
      return this.options[index];
    }
    return '';
  }
}

@Entry
@Component
export struct SourceDetailPage {
  @State sourceKey: string = '';
  @State sourceName: string = '';
  @State sourceVersion: string = '';
  @State rows: SettingRow[] = [];
  @State expandedKey: string = '';

  @State hasAccount: boolean = false;
  @State logged: boolean = false;
  @State loggedName: string = '';
  /** password | cookies | unsupported | none */
  @State loginMode: string = 'none';
  @State webviewUrl: string = '';
  @State cookieFields: string[] = [];
  @State inputs: string[] = [];

  @State loading: boolean = false;
  @State loadingText: string = '处理中...';

  aboutToAppear(): void {
    const params = router.getParams() as DetailParams;
    this.sourceKey = params !== null && params !== undefined ? params.key : '';
    this.load().catch((e: Error) => {
      hilog.error(DOMAIN, TAG, '加载源详情失败: %{public}s', `${e}`);
    });
  }

  /** 系统返回事件: 返回上一页(避免滑动返回直接退回桌面) */
  onBackPress(): boolean {
    router.back();
    return true;
  }

  private startLoading(text: string): void {
    this.loadingText = text;
    this.loading = true;
  }

  private stopLoading(): void {
    this.loading = false;
  }

  private async load(): Promise<void> {
    const meta = comicSourceManager.findJsSource(this.sourceKey);
    if (meta === null) {
      promptAction.showToast({ message: '源不存在' });
      return;
    }
    this.sourceName = meta.name;
    this.sourceVersion = meta.version;
    this.refreshAccount(meta);
    // 先用静态解析结果渲染, 保证首屏可见
    this.rows = this.buildRows(meta);

    // 再用真引擎精化(拿到准确的 options value/label 与 callback 类型)
    this.startLoading('加载源脚本...');
    try {
      await jsRuntime.enrichSettings(meta);
      this.rows = this.buildRows(meta);
    } catch (e) {
      hilog.warn(DOMAIN, TAG, '真引擎解析设置失败, 沿用静态结果: %{public}s', `${e}`);
    } finally {
      this.stopLoading();
    }
  }

  private refreshAccount(meta: ComicSourceMeta): void {
    this.hasAccount = meta.hasAccount;
    this.logged = jsRuntime.isLogged(this.sourceKey);
    this.loggedName = jsRuntime.loggedAccount(this.sourceKey);
    this.webviewUrl = meta.account.webviewUrl;
    this.cookieFields = meta.account.cookieFields;
    if (meta.account.hasLogin) {
      this.loginMode = 'password';
    } else if (meta.account.hasCookiesValidate || meta.account.cookieFields.length > 0) {
      this.loginMode = 'cookies';
    } else if (meta.account.hasWebviewLogin) {
      this.loginMode = 'unsupported';
    } else {
      this.loginMode = 'none';
    }
    // 输入框: 账密 2 个, cookies 按字段数
    const count = this.loginMode === 'cookies' ? this.cookieFields.length : 2;
    const next: string[] = [];
    for (let i = 0; i < count; i++) {
      next.push('');
    }
    this.inputs = next;
  }

  private buildRows(meta: ComicSourceMeta): SettingRow[] {
    const out: SettingRow[] = [];
    meta.settings.forEach((def: SettingDef, k: string) => {
      const row = new SettingRow();
      row.key = k;
      row.title = def.title.length > 0 ? def.title : k;
      row.type = def.type;
      row.options = def.options;
      row.labels = def.optionLabels;
      const cur = jsRuntime.settingValue(this.sourceKey, k);
      row.value = SourceDetailPage.toText(cur !== null ? cur : def.default);
      row.draft = row.value;
      out.push(row);
    });
    return out;
  }

  private static toText(v: Object | null): string {
    if (v === null) {
      return '';
    }
    if (typeof v === 'string') {
      return v as string;
    }
    return JSON.stringify(v);
  }

  /** 保存一个设置项 */
  private saveSetting(row: SettingRow, value: Object): void {
    sourceDataStore.saveSetting(this.sourceKey, row.key, value);
    row.value = SourceDetailPage.toText(value);
    row.draft = row.value;
    this.rows = this.rows.slice();
  }

  private setInput(index: number, text: string): void {
    const next: string[] = [];
    for (let i = 0; i < this.inputs.length; i++) {
      next.push(i === index ? text : this.inputs[i]);
    }
    this.inputs = next;
  }

  // ---------------------------------------------------------------- 账号动作

  private async doPasswordLogin(): Promise<void> {
    const account = this.inputs.length > 0 ? this.inputs[0] : '';
    const password = this.inputs.length > 1 ? this.inputs[1] : '';
    if (account.length === 0) {
      promptAction.showToast({ message: '请输入账号' });
      return;
    }
    this.startLoading('登录中...');
    try {
      await jsRuntime.loginWithPassword(this.sourceKey, account, password);
      promptAction.showToast({ message: '登录成功' });
      await this.reloadAfterAccount();
    } catch (e) {
      promptAction.showToast({ message: '登录失败：' + `${e}` });
    } finally {
      this.stopLoading();
    }
  }

  private async doCookiesLogin(): Promise<void> {
    this.startLoading('校验中...');
    try {
      await jsRuntime.loginWithCookies(this.sourceKey, this.inputs);
      promptAction.showToast({ message: '登录成功' });
      await this.reloadAfterAccount();
    } catch (e) {
      promptAction.showToast({ message: '登录失败：' + `${e}` });
    } finally {
      this.stopLoading();
    }
  }

  private async doLogout(): Promise<void> {
    this.startLoading('登出中...');
    try {
      await jsRuntime.logout(this.sourceKey);
      await this.reloadAfterAccount();
      promptAction.showToast({ message: '已登出' });
    } catch (e) {
      promptAction.showToast({ message: '登出失败：' + `${e}` });
    } finally {
      this.stopLoading();
    }
  }

  private async reloadAfterAccount(): Promise<void> {
    const meta = comicSourceManager.findJsSource(this.sourceKey);
    if (meta !== null) {
      this.refreshAccount(meta);
    }
  }

  // ---------------------------------------------------------------- 设置动作

  private async runCallback(row: SettingRow): Promise<void> {
    this.startLoading('执行中...');
    try {
      await jsRuntime.callSettingCallback(this.sourceKey, row.key);
      promptAction.showToast({ message: '已执行：' + row.title });
    } catch (e) {
      promptAction.showToast({ message: '执行失败：' + `${e}` });
    } finally {
      this.stopLoading();
    }
  }

  // ---------------------------------------------------------------- UI

  @Builder
  sectionTitle(text: string, hint: string) {
    Row({ space: 8 }) {
      Text(text).fontSize(FS_SECTION).fontWeight(FontWeight.Bold).fontColor(GRAY_900)
      if (hint.length > 0) {
        Text(hint).fontSize(FS_SMALL).fontColor(MUTED_FG)
      }
    }
    .width('100%').padding({ left: SPACE_4, right: SPACE_4, top: SPACE_4, bottom: SPACE_2 })
  }

  @Builder
  settingRowView(row: SettingRow) {
    Column() {
      Row({ space: 10 }) {
        Column() {
          Text(row.title).fontSize(FS_CAPTION).fontColor(GRAY_900)
          Text(row.type + ' · ' + row.key).fontSize(11).fontColor(MUTED_FG).margin({ top: 2 })
        }.alignItems(HorizontalAlign.Start).layoutWeight(1)

        // select: 当前值 + 展开箭头
        if (row.type === 'select') {
          Row({ space: 4 }) {
            Text(row.currentLabel().length > 0 ? row.currentLabel() : '未选择')
              .fontSize(FS_SMALL).fontColor(PRIMARY)
            SymbolGlyph(this.expandedKey === row.key ? $r('sys.symbol.chevron_up') : $r('sys.symbol.chevron_down'))
              .fontSize(14).fontColor([GRAY_500])
          }
          .onClick(() => {
            this.expandedKey = this.expandedKey === row.key ? '' : row.key;
          })
        } else if (row.type === 'switch') {
          Toggle({ type: ToggleType.Switch, isOn: row.value === 'true' })
            .selectedColor(PRIMARY)
            .onChange((isOn: boolean) => {
              this.saveSetting(row, isOn);
            })
        } else if (row.type === 'callback') {
          Row() {
            Text('执行').fontSize(FS_SMALL).fontColor(CARD)
          }
          .height(30).padding({ left: 14, right: 14 }).borderRadius(15)
          .backgroundColor(PRIMARY).justifyContent(FlexAlign.Center)
          .onClick(() => {
            this.runCallback(row);
          })
        }
      }
      .width('100%')

      // input: 输入框 + 保存
      if (row.type === 'input') {
        Row({ space: 8 }) {
          TextInput({ text: row.draft, placeholder: '请输入' })
            .fontColor(GRAY_900)
            .placeholderColor(MUTED_FG)
            .backgroundColor(GRAY_100)
            .layoutWeight(1)
            .onChange((v: string) => {
              row.draft = v;
            })
            .onSubmit(() => {
              this.saveSetting(row, row.draft);
              promptAction.showToast({ message: '已保存' });
            })
          Row() {
            Text('保存').fontSize(FS_SMALL).fontColor(GRAY_900)
          }
          .height(34).padding({ left: 14, right: 14 }).borderRadius(17)
          .backgroundColor(GRAY_100).justifyContent(FlexAlign.Center)
          .onClick(() => {
            this.saveSetting(row, row.draft);
            promptAction.showToast({ message: '已保存' });
          })
        }
        .width('100%').margin({ top: 8 })
      }

      // select 展开选项
      if (row.type === 'select' && this.expandedKey === row.key) {
        Column() {
          ForEach(row.options, (opt: string, idx: number) => {
            Row() {
              Text(row.labelAt(idx)).fontSize(FS_CAPTION)
                .fontColor(row.value === opt ? PRIMARY : GRAY_900)
              Text('').layoutWeight(1)
              if (row.value === opt) {
                SymbolGlyph($r('sys.symbol.checkmark')).fontSize(14).fontColor([PRIMARY])
              }
            }
            .width('100%').height(40)
            .onClick(() => {
              this.saveSetting(row, opt);
              this.expandedKey = '';
            })
          }, (opt: string, idx: number) => row.key + '#' + idx)
        }
        .width('100%').margin({ top: 6 })
        .backgroundColor(GRAY_100).borderRadius(RADIUS_MD)
        .padding({ left: SPACE_3, right: SPACE_3 })
      }
    }
    .width('100%').padding(SPACE_3)
    .backgroundColor(CARD).borderRadius(RADIUS_MD).margin({ top: 8 })
  }

  @Builder
  accountCard() {
    Column() {
      Row({ space: 8 }) {
        Text('账号').fontSize(FS_CAPTION).fontWeight(FontWeight.Medium).fontColor(GRAY_900)
        Text(this.logged ? ('已登录' + (this.loggedName.length > 0 ? ' · ' + this.loggedName : '')) : '未登录')
          .fontSize(FS_SMALL).fontColor(this.logged ? SUCCESS : MUTED_FG)
        Text('').layoutWeight(1)
        if (this.logged) {
          Text('登出').fontSize(FS_SMALL).fontColor(ERROR)
            .onClick(() => {
              this.doLogout();
            })
        }
      }
      .width('100%')

      if (!this.logged) {
        if (this.loginMode === 'password') {
          Column({ space: 8 }) {
            TextInput({ text: this.inputs.length > 0 ? this.inputs[0] : '', placeholder: '账号 / 邮箱' })
              .fontColor(GRAY_900).placeholderColor(MUTED_FG).backgroundColor(GRAY_100)
              .onChange((v: string) => {
                this.setInput(0, v);
              })
            TextInput({ placeholder: '密码' })
              .type(InputType.Password)
              .fontColor(GRAY_900).placeholderColor(MUTED_FG).backgroundColor(GRAY_100)
              .onChange((v: string) => {
                this.setInput(1, v);
              })
            Row() {
              Text('登录').fontSize(FS_SMALL).fontColor(CARD)
            }
            .width('100%').height(36).borderRadius(18)
            .backgroundColor(PRIMARY).justifyContent(FlexAlign.Center)
            .onClick(() => {
              this.doPasswordLogin();
            })
          }
          .width('100%').margin({ top: 10 })
        } else if (this.loginMode === 'cookies') {
          Column({ space: 8 }) {
            ForEach(this.cookieFields, (field: string, idx: number) => {
              TextInput({ text: this.inputs.length > idx ? this.inputs[idx] : '', placeholder: field })
                .fontColor(GRAY_900).placeholderColor(MUTED_FG).backgroundColor(GRAY_100)
                .onChange((v: string) => {
                  this.setInput(idx, v);
                })
            }, (field: string, idx: number) => field + '#' + idx)
            Row() {
              Text('登录').fontSize(FS_SMALL).fontColor(CARD)
            }
            .width('100%').height(36).borderRadius(18)
            .backgroundColor(PRIMARY).justifyContent(FlexAlign.Center)
            .onClick(() => {
              this.doCookiesLogin();
            })
          }
          .width('100%').margin({ top: 10 })
        } else if (this.loginMode === 'unsupported') {
          Column({ space: 4 }) {
            Text('该源使用 WebView 登录（暂未接入）').fontSize(FS_SMALL).fontColor(MUTED_FG)
            if (this.webviewUrl.length > 0) {
              Text('登录页：' + this.webviewUrl).fontSize(11).fontColor(GRAY_500)
                .maxLines(2).textOverflow({ overflow: TextOverflow.Ellipsis })
            }
          }
          .alignItems(HorizontalAlign.Start).width('100%').margin({ top: 10 })
        } else {
          Text('该源未声明登录能力').fontSize(FS_SMALL).fontColor(MUTED_FG).margin({ top: 10 })
        }
      }
    }
    .width('100%').padding(SPACE_3)
    .backgroundColor(CARD).borderRadius(RADIUS_LG).margin({ top: SPACE_2 })
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
          .onClick(() => {
            router.back();
          })

          Column() {
            Text(this.sourceName).fontSize(FS_TITLE).fontWeight(FontWeight.Bold).fontColor(GRAY_900)
              .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
            Text('v' + this.sourceVersion + ' · ' + this.sourceKey).fontSize(11).fontColor(MUTED_FG)
          }
          .alignItems(HorizontalAlign.Center).layoutWeight(1)
        }
        .width('100%').height(60).padding({ left: SPACE_3, right: SPACE_3 })

        Scroll() {
          Column() {
            if (this.hasAccount) {
              this.sectionTitle('账号', '')
              this.accountCard()
            }

            if (this.rows.length > 0) {
              this.sectionTitle('设置', this.rows.length + ' 项')
              ForEach(this.rows, (row: SettingRow) => {
                this.settingRowView(row)
              }, (row: SettingRow) => row.key + '#' + row.value)
            } else {
              this.sectionTitle('设置', '')
              Text('该源未声明设置项').fontSize(FS_SMALL).fontColor(MUTED_FG)
                .width('100%').padding({ left: SPACE_4 })
            }

            Column().height(32)
          }
          .width('100%')
        }
        .scrollable(ScrollDirection.Vertical).scrollBar(BarState.Off)
        .align(Alignment.Top)
        .width('100%').layoutWeight(1)
        .padding({ left: SPACE_3, right: SPACE_3 })
      }
      .width('100%').height('100%').backgroundColor(BG)

      if (this.loading) {
        Column() {
          Column({ space: 10 }) {
            LoadingProgress().width(42).height(42).color(PRIMARY)
            Text(this.loadingText).fontSize(FS_SMALL).fontColor(GRAY_900)
          }
          .width(150).height(140).borderRadius(RADIUS_LG)
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
