# VeneraNext 本地文件导入(TXT/EPUB) + 富文本阅读 实现计划

## Context

阅读器当前仅支持 demo 数据（ReaderPage 在 aboutToAppear 里按 isImageContent 调 makeImageChapter/makeTextChapter 自行造章节），无法阅读真实文件。用户要求：
1. 书架"本地"tab 右下角加导入按钮，用 `picker.DocumentViewPicker`（单次免审批临时权限，不申请持久化存储权限）选文件导入，PDF/MOBI **本期不放入口**（纯 ArkTS 无渲染位图/SDK），只支持 TXT/EPUB。
2. EPUB 富文本章节（HTML 内嵌图片）用 **Web 组件加载本地 HTML** 渲染，图片完全按原格式显示、不做缩放/模糊。
3. 横屏富文本保留双栏（displayCount=2），**两页中间加竖分隔线**显示两个静态页面。
4. 导入的书**落盘持久化**（AppSettings Preferences 存 JSON），重启后书架恢复。

## 关键 API 边界（已调研核实）

- `picker.DocumentViewPicker(context)`：`@kit.CoreFileKit`，构造函数需 `common.UIAbilityContext`（页面内 `this.getUIContext().getHostContext()`），`select({fileSuffixFilters, maxSelectNumber:1})` 返回临时读写权限 URI。
- `fs`（`@kit.CoreFileKit`）：`fs.openSync(uri)` + `fs.copyFileSync` 把临时 URI 拷贝进沙箱 `cacheDir/books/`，退出后台临时权限失效但沙箱副本持久。
- `zlib.decompressFile(zipPath, outDir)`（`@kit.BasicServicesKit`）：整体解压 EPUB(zip) 到沙箱目录。
- Web 组件：`WebController.loadData(html, 'text/html', 'utf-8', baseUrl)` 加载富文本，`baseUrl` 指该章图片所在目录使相对图片路径可解析。
- PDF（`pdfService` 仅编辑不渲染位图）、MOBI（无 SDK）→ 本期不提供导入选项。

## 实施步骤

### 1. 模型扩展
- `model/ReaderModel.ets`：`ReaderPageType` 增加 `RICH`；`ReaderPageItem` 增加可选字段 `html: string`（尾参默认 ''，不破坏现有调用）+ `baseUrl: string`（Web 相对图片解析目录，可选）；新增 `makeRichChapter(id, title, items)` 与 `makeChapterFromHtmls(id, title, htmls, baseUrl)`。
- `model/ShelfItem.ets`：增加 `fileFormat: string`（'txt'/'epub'）、`bookData: ReaderChapter[] | null`（导入时解析的章节缓存）、`initLoaded: boolean`（是否已从沙箱路径惰性解析，持久化恢复时 false）。

### 2. 全局可变数据源（响应式新增书）
- 新建 `model/LocalBookStore.ets`：单例，`items` 初始化为 `localDemocoms.slice()`，`addItem()`、`findById()`、`subscribe()/notify()`。
- `model/DemoData.ets`：`findShelfItem` 改为委托 `localBookStore.findById`（DetailPanel 依赖它，一处改全局生效）。

### 3. 文件导入与解析
- 新建 `utils/FileImporter.ets`：
  - `doImport(context): Promise<ShelfItem|null>`：`DocumentViewPicker.select({fileSuffixFilters:['.txt','.epub'], maxSelectNumber:1})` → `fs.openSync(uri)` + `fs.copyFileSync` 到 `cacheDir/books/<随机名><ext>` → 按后缀分发解析 → 组装 ShelfItem（fileFormat、bookData、chapters）→ `localBookStore.addItem` + 持久化。
- 新建 `utils/parsers/TxtParser.ets`：读 UTF-8 全文 → 按约 800 字符分页 → 多个 `ReaderPageItem(TEXT)` → 单个 `ReaderChapter('正文', pages)`。
- 新建 `utils/parsers/EpubParser.ets`：`zlib.decompressFile` 解压 → 字符串匹配解析 `META-INF/container.xml` 得 OPF → manifest/spine 得章节顺序与 href → 每章读 html 原文 → `ReaderChapter(RICH, [ReaderPageItem(RICH, html, baseUrl=该章目录)])`。容错：解析失败回退全文单章。

### 4. 阅读器数据流改造
- `pages/comic/ReaderPage.ets`：新增可选 `@Prop externalChapter: ReaderChapter | null = null`；`aboutToAppear` 优先用 `externalChapter`（设置 isImage/isRich、curPage=0），否则回退 demo 生成。
- `pages/Index.ets`：新增模块级 `resolveReaderChapter(item, chapterIndex): ReaderChapter|null`（从 item.bookData 取对应章节）；`onStartRead` 计算并传入 `ReaderPage.externalChapter`。

### 5. 富文本 RICH 渲染
- `ReaderPage.ets` 新增 `richPage(item)` builder：`Web({ src:'about:blank', controller })` + `onPageEnd` 里 `loadData(item.html,'text/html','utf-8', item.baseUrl)`，宽高 100% 占满单页，页面上下滚动由 Web 内部处理。
- 每章 RICH 页配独立 `WebController`（同页多 Web 互斥），章节就绪后按 RICH 页数量补齐。
- `swiperContent`/`scrollContent` 的 ForEach 分支增加 `RICH`。
- **横屏双栏分隔线**：当 `isLandscape && displayCount===2` 时，在 Swiper 两页之间叠加一条 1vp 宽的分隔线（Stack 上层，半透明白/黑），富文本章节保留双栏静态显示两页。
- 设置弹窗背景色选择对 RICH 页隐藏（`isRich` 与 `isImage` 同样处理）。

### 6. 书架 UI 与持久化
- `pages/shelf/BookshelfPage.ets`：
  - 新增 `@State localItems: ShelfItem[]`，`aboutToAppear` 快照 `localBookStore.items` 并 `subscribe` 刷新；`currentItems()` tab0 返回 `this.localItems`。
  - `this.tab===0` 时右下角悬浮导入按钮（参考 ReaderPage bottomTabBar 的 Stack+position 模式）：PRIMARY 圆底 + `SymbolGlyph($r('sys.symbol.square_and_arrow_up'))`，点击调 `FileImporter.doImport`，成功 `promptAction.showToast`。
- `model/AppSettings.ets`：新增持久化键 `imported_books`（JSON：`[{id,title,fileFormat,filePath,lastReadPage}]`）；启动时反序列化重建 ShelfItem（initLoaded=false，打开阅读时按 filePath 惰性重解析）；导入成功时写回。

## 新建/修改文件清单

**新建**
- `model/LocalBookStore.ets`
- `utils/FileImporter.ets`
- `utils/parsers/TxtParser.ets`
- `utils/parsers/EpubParser.ets`

**修改**
- `model/ReaderModel.ets`（RICH/html/baseUrl/makeRichChapter）
- `model/ShelfItem.ets`（fileFormat/bookData/initLoaded）
- `model/DemoData.ets`（findShelfItem 委托）
- `model/AppSettings.ets`（imported_books 持久化）
- `pages/comic/ReaderPage.ets`（externalChapter/RICH 渲染/横屏分隔线/isRich）
- `pages/Index.ets`（resolveReaderChapter/传递 externalChapter）
- `pages/shelf/BookshelfPage.ets`（@State 本地数组/导入按钮/订阅）

## 验证

真机（HUAWEI Pura X Max）：
```
devecocli run --module entry@default --device "HUAWEI Pura X Max" --build-mode debug
```
1. 本地 tab 右下角出现导入按钮（仅本地 tab 显示）。
2. 选 .txt → 书架新增书 → 详情 → 阅读走 TEXT 分页，翻页/滚动/背景调色生效。
3. 选 .epub → 解压解析 → 阅读走 RICH，Web 渲染 HTML，内嵌图片原尺寸显示；横屏双栏两页中间有分隔线。
4. 选择器不出现 PDF/MOBI 选项。
5. 重启应用后书架恢复导入的书；打开按沙箱路径重新解析。
6. 竖屏/横屏切换下按钮避让，无白屏/崩溃。
