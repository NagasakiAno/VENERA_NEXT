# VeneraNext P0 阶段1：JS 漫画源管理闭环 实现计划

## Context

VeneraNext 是 Venera 漫画阅读器的鸿蒙 ArkTS 移植。规划文档 `HARMONYOS_ARKTS_PORT_PLAN.md` 明确：**必须保留「JS 源脚本 + JS 运行时 + sendMessage 桥」架构**（第三方 .js 源脚本，App 只做运行时壳），否则失去开放源生态。

当前鸿蒙工程只有**原生 ArkTS 源协议**（`model/ComicSource.ets` 的 `ComicSourceProtocol` + 手写源 MangaDex/CopyManga/Demo），**没有 JS 引擎、没有源仓库、没有源管理 UI**。

本轮执行 **P0 阶段1：源管理闭环**，决策已定：
- **先 A 再 B**：先以「正则静态解析」交付完整闭环（扫描/安装/更新/删除/仓库/设置UI/持久化），零 NDK 风险；JSVM-API 真引擎作为下一里程碑（M0B）接入，Parser 接口预留。
- **只留 JS 源**：移除原生 ArkTS 源池（MangaDexSource 等），Manager 只承载磁盘 JS 源。

## 关键设计

### 数据模型（A/B 同构共享）
`ComicSourceMeta`（新建 `model/sources/ComicSourceMeta.ets`）—— 一个磁盘 .js 源的静态描述，正则(A)与真引擎(B)产出同构：
- 元信息：`key/name/version/minAppVersion/url/filePath`
- `settings: Map<string, SettingDef>`（`SettingDef{title,type(select|switch|input|callback),default,options[]}`）
- `account：{login?, cookieFields?, hasWebviewLogin?, hasCookiesValidate?...}`
- 能力掩码：成绩 `hasExplore/hasSearch/hasLoadInfo/hasLoadEp/hasSettings/hasAccount`
- `data: Map<string,string>`（对应 `{key}.data`）

### Parser（A 实现，正则）
`ComicSourceParser.ets`（新建 `model/sources/`）：
- `parse(jsText, filePath): ComicSourceMeta`
- 正则抓：`class (\w+) extends ComicSource`、静态字段 `key/name/version/minAppVersion/url`、`settings {...}`（括号配平截段逐项提取）、能力探测用子串存在性（`explore`/`search`/`comic.loadComicInfo`/`comic.loadEp`/`settings`/`account`）
- 校验：无 `extends ComicSource` 抛异常；key 仅 `[a-zA-Z0-9_]`；key 冲突拒绝
- `compareSemVer(v1,v2)` 版本比较工具
- 签名与 B 阶段对齐，后续换引擎不改 UI/存储层

### 源文件存储
`JsSourceFileStore.ets`（新建 `utils/`）：
- 目录 `filesDir/comic_source/`
- `writeJs/readJs/delete/listJs`、`readData(key)/writeData(key,json)` → `{key}.data`

### Manager 改造（只留 JS 源）
`model/ComicSource.ets` 改造：
- **删除**原生源池（`ComicSourceProtocol/BaseComicSource`/原生 addAll 用法）
- 保留单例，改持 `jsSources: Map<key, ComicSourceMeta>`
- 新方法：`scanFromFilesDir(ctx)`（启动扫描 *.js → parse）、`addJsSource(meta)`（写盘+注册+写四列表）、`removeJsSource(key)`（删盘+移除+**清理 explore_pages/categories/favorites/searchSources 四列表失效项**）、`updateJsSource(key,newJs)`（先 remove 再 parse 写回）、`allJsSources()`/`findJsSource(key)`

### 仓库服务
`JsSourceRepo.ets`（新建 `services/`）：
- `fetchIndexList(url)`：GET index.json（禁缓存），解析 `[{key,name,version,fileName,url,description}]`
- `checkUpdates()` 对比 `compareSemVer` 返回待更新清单
- 默认 `comicSourceListUrl` = 官方仓库

### 设置项
`AppSettings.ets` 新增键：`comicSourceListUrl`、`explore_pages[]`、`categories[]`、`favorites[]`、`searchSources[]`

### 初始化
`EntryAbility.ets` 在 onCreate 调 `comicSourceManager.scanFromFilesDir(context)`

### 源管理 UI
- `pages/settings/ComicSourcePage.ets`（新建）：URL 安装、本地文件安装(复用 FileImporter 的 DocumentViewPicker)、源列表(name/version/New Version 角标/Edit/Update/Delete)、仓库弹层(Refresh + 已装✓/未装 Add)、检查更新
- `pages/settings/SourceSettingsRow.ets`（新建，占位）：渲染 settings 四类型；callback 提示"待接入真引擎"
- `pages/settings/SourceAccountPage.ets`（新建，占位）：账号元信息展示；WebView 登录提示"后置"
- `SettingsPage.ets`：加「漫画源」入口跳转
- `Index.ets`：经设置页进入源管理（不新增底部 tab）

## 新建/修改文件清单

**新建**
- `model/sources/ComicSourceMeta.ets`
- `model/sources/ComicSourceParser.ets`
- `utils/JsSourceFileStore.ets`
- `services/JsSourceRepo.ets`
- `pages/settings/ComicSourcePage.ets`
- `pages/settings/SourceSettingsRow.ets`（占位）
- `pages/settings/SourceAccountPage.ets`（占位）

**修改**
- `model/ComicSource.ets`（只留 JS 源池）
- `model/AppSettings.ets`（新增键）
- `entryability/EntryAbility.ets`（启动扫描）
- `pages/settings/SettingsPage.ets`（源管理入口）
- `pages/Index.ets`（路由）
- 清理现有 `model/sources/CopyMangaSource/MangaDexSource/DemoSource`（不再被 Manager 引用，评估保留为文件或删除）

## 验证

真机（HUAWEI Pura X Max）`devecocli run --module entry@default --device "HUAWEI Pura X Max" --build-mode debug`：
1. 启动无源 → 设置页「漫画源」空列表
2. 输入仓库 URL → Refresh → 拉到 index.json；未装显示 Add → 点 Add 下载安装
3. 本地选 .js → 卡片出现；重启仍在（磁盘加载）
4. 检查更新 → 新版本行显示 New Version → 更新后 version 变化
5. Delete → 源消失，四列表对应项清理，`{key}.data` 删除
6. 日志确认 parse 正则捕获 name/key/version/settings

## 后置里程碑（本轮不做）
- **M0B**：NDK cpp + JSVM-API（`OH_JSVM_*`）真执行 init.js + 源脚本；`ComicSourceParser` 换真引擎内核；sendMessage 网络异步桥
- 阶段2：发现/分类/搜索；阶段3：详情/阅读/图片管道