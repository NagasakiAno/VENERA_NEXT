# VeneraNext 工程交接文档（换设备续接用）

> 记录时间：2026-09-19
> 用途：换设备后无缝继续；**本文件是唯一的会话交接入口**，新会话请先读它，再读规划文档。

---

## 0. 一句话现状

Flutter 版 Venera 1.6.3 → HarmonyOS NEXT(ArkTS) 的移植工程 `VeneraNextNew`。
**阶段 0/1/2 已跑通，阶段 3（详情 → 章节 → 阅读器 → 图片管道）已打通并在真机验证通过**；本轮集中修掉了 4 个「源在真机上跑不通」的缺陷（详见 §4）。下一步是阶段 3 收尾 + 阶段 4（收藏/本地）。

**注意：本目录不是 git 仓库**（`git rev-parse` 报 not a repository）。换设备 = 手工拷贝整个 `VENERA` 目录。

---

## 1. 工程与环境

| 项 | 值 |
|---|---|
| 当前工程（只改这个） | `c:\Users\RAIGLIM\Documents\trae\VENERA\VeneraNextNew` |
| Bundle | `com.venera.next`（versionName 1.0.0） |
| SDK | target/compatibleSdkVersion `26.0.0` |
| 测试设备 | `HUAWEI Pura X Max`（宽屏折叠态，2584×1828 px） |
| 构建/部署工具 | `devecocli`（devEco CLI） |
| 签名 | `VeneraNextNew/signing/`（build-profile.json5 里是绝对路径，**换设备后若用户名/盘符不同需重新生成或改路径**） |

### 目录角色（别改错地方）

| 目录 | 说明 |
|---|---|
| `VeneraNextNew/` | **当前工程**，所有改动都在这 |
| `VeneraNext/` | 更早的迭代版本，仅参考，勿改 |
| `archive/VeneraNext_legacy_*` | 归档 |
| `venera-master/` | 原版 Flutter 源码（**判断"原版行为"的唯一依据**） |
| `src_download/` | 官方源脚本快照（`ehentai.js` / `picacg.js` / `wnacg.js` …），用于比对源协议 |
| `HARMONYOS_ARKTS_PORT_PLAN.md` | 总规划（1.6.3）。**其阶段勾选框已过期**，以本文件 §6 为准 |
| `VeneraNextNew/.trae/documents/` | 各轮 spec（`js-source-manager-plan.md`、`local-import-rich-reader-plan.md`） |

---

## 2. 构建 / 调试速查

```powershell
# 工作目录必须是 VeneraNextNew
devecocli run --device "HUAWEI Pura X Max"              # 编译 + 安装 + 启动(保留应用数据)
devecocli run --device "HUAWEI Pura X Max" --skip-build  # 只重装启动(用于回到首页/退出覆盖层)

# 日志(定位问题主要靠它)
devecocli log --device "HUAWEI Pura X Max" --bundle-name com.venera.next --from 2m --tail 200
devecocli log --device "HUAWEI Pura X Max" --bundle-name com.venera.next --keyword 详情 --from 2m --tail 20

# 界面树 / 驱动 UI
devecocli ui layout --device "HUAWEI Pura X Max" --depth 6 --mode simplified
devecocli ui click 1526 754 --device "HUAWEI Pura X Max"
```

**日志关键字约定**（排查时直接按这些 grep）：

| 关键字 | 含义 |
|---|---|
| `详情 <源>@<id>: 章节 N, 推荐 M` | `ComicDetailService` loadInfo 成功 |
| `章节 <源>@<epId>: N 张图` | `ComicReadService` loadEp 成功 |
| `图片就绪 W×H <url>` | 图片下载+解码成功 |
| `图片还原完成` | `modifyImage` 生效 |
| `源 X 调用失败 [表达式]: 错误` | JS 源抛错（含具体 JS 栈） |
| `文档数超限, 已释放 doc=N` | HtmlBridge 文档池淘汰（上限 8，正常现象） |

**驱动 UI 的坑**：发现页的 chip 横向滚动对合成 `swipe/drag` 不敏感，经常点不到目标 chip。
绕法：① 先用 `ui layout` 确认 chip 当前坐标再点；② 或用搜索页的「按 ID 直达」直接进详情（最稳）。

---

## 3. 代码地图（关键文件 → 职责）

### 运行时 / 桥（最核心，改这里要格外小心）

| 文件 | 职责 |
|---|---|
| `entry/src/main/cpp/jsvm_engine.cpp` | JSVM-API 引擎：加载 `init.js` + 源脚本，`sendMessage` 双向桥（同步/异步分流） |
| `entry/src/main/resources/rawfile/init.js` | **原版 init.js 原文**，JS 侧协议（Network/HtmlDocument/Html/UI/Convert…）。不要改，改了就和原版行为分叉 |
| `runtime/JsRuntime.ets` | 桥的中枢：`onHttp`/`onHtml`/`onImage` 分发；`callSource` / `callLoadInfo` / `callLoadEp` / `callOnImageLoad` / `callModifyImage`；`diagnose()` 运行时自检 |
| `runtime/HtmlBridge.ets` | HtmlDocument 桥：parse / querySelector(All) / getElementById / 属性 / 文本 / dispose；文档池上限 8 |
| `parser/HtmlDom.ets` | 自研 HTML 解析 + CSS 选择器引擎（见 §8 的两条关键规则） |
| `runtime/ImageBridge.ets` | `modifyImage` 位图桥（RGBA 缓冲 put/get/release、blit、rotate90） |
| `network/HttpClient.ets` | `@ohos.net.http` 封装：UA 注入、Cookie 注入、`extraData` 规则、统一 ARRAY_BUFFER 取字节 |
| `network/CookieStore.ets` | Cookie 持久化 + `set-cookie` 收集 |

### 服务层

`services/`：`JsSourceManager`（源安装/更新/删除/磁盘加载）、`JsSourceRepo`（index.json 仓库）、`SourceDataStore`（`{key}.data` 持久化）、`ExploreService`、`CategoryService`、`SearchService`、`ComicDetailService`、`ComicReadService`（图片管道）、`ReadHistoryService`（阅读进度）。

### 页面

`pages/`：`Index.ets`（书架 + 侧边/底部导航 + 搜索覆盖层，材质分层在根 Stack）、`discovery/DiscoveryPage`、`search/SearchPage`（含「按 ID 直达」滑入卡片 + 筛选 sheet）、`category/CategoryComicsPage`、`comic/ComicDetailPage`（**统一详情页**：发现/搜索/分类三入口都走它）、`comic/ReaderPage`、`comic/DetailPanel`（旧版详情，目前只服务书架本地书 / 属于待重构项 b4）、`shelf/BookshelfPage`、`settings/*`（源管理）。

---

## 4. 本轮会话完成的工作（4 个缺陷 + 根因）

> 这些都是「源在真机上不工作」的真凶，结论已实机验证。**结论比补丁更重要，避免下次又绕回兜底方案。**

### 4.1 鸿蒙 `http` 的 `extraData` 会污染 GET 的 URL（影响面最大）

- **现象**：picacg 详情页报 `Cannot read properties of undefined (reading 'eps')`，而"原版完全正常"。
- **根因**：`HttpClient` 对所有请求都传了 `extraData`。鸿蒙官方文档明确：**非 POST/PUT 时 `extraData` 会被当作"参数补充"拼接到 URL 上**，即使传空串也会多一个 `&`。
  实测（httpbin 回显）URL 变成 `.../get?page=1&s=dd&`，而 picacg 的 `signature = HMAC(path+time+nonce+method+apiKey)` 是按原始 URL 串算的 → 服务端签名校验失败 → 返回 `HTTP 200 {"code":200,"message":"success"}`（**有 200 无 data**），源脚本再读 `data.data.eps.docs` 就炸。
- **为什么只影响一部分接口**：无 `?` 的接口（`/comics/{id}`、`/comics/random`、`/recommendation`）不受影响；带 `?` 的全挂（`/eps?page=N`、`/order/N/pages?page=N`、`comics?page=N&s=dd`）。
- **修复**：`HttpClient.rawRequest` 只对 POST/PUT 设置 `extraData`。顺带删掉了之前的 `normalizeEmptyEps` 兜底（它会伪造「第1話」和空图片列表，掩盖真因）。
- **附带收益**：所有依赖查询串的源（分页/排行榜/分类筛选）一起修好。

### 4.2 HTML 解析缺隐式 `<tbody>`（EH 系全空白）

- **现象**：eh latest / eh popular / eh watched 等加载完成、**无报错、完全空白**。
- **根因**：EH 列表页是 `<table class="itg gltc">` 里直接放 `<tr>`，源用 `table.itg.gltc > tbody > tr` 取行。浏览器与 Dart `package:html` 都会按 HTML5 规范补一层**隐式 `<tbody>`**，我们自研解析器不补 → 命中 0 → 源返回空数组（不抛错）→ 空白页。
  实测：`tbody=0`（`tr=29`）→ 选择器命中 0；补上后 `tbody=2`、命中 27。
- **修复**：`HtmlDom.parseHtml` 中，`<tr>` 的直接父是 `<table>` 时自动插一层 `tbody`。

### 4.3 重复属性取了"最后一个"（绅士源全空白）

- **现象**：紳士漫畫（wnacg）同样空白，且很迷惑：`div.gallary_wrap` 命中 6，但 `div.bodywrap` / `div.title_sort` 命中 0。
- **根因**：该页存在 `<div class="bodywrap" class="cc">`（**同一标签两个 class**）。HTML 规范规定重复属性**以第一个为准**，而我们的属性解析用 `Map.set` → 后者覆盖前者 → 元素 class 变成 `cc`。
- **修复**：`buildElement` 里改为 `if (!attrs.has(name)) set(...)`。
- **验证**：`bodywrap/title_sort/gallary_wrap` 各命中 6，`div.gallary_wrap > ul.cc > li` 命中 66。

### 4.4 无章节源（EH）「没有可用章节」+ 图片地址解析

三个子问题一起修：

1. **EH 的 `loadInfo` 不返回 `chapters`**（整本即一章，靠 `maxPage` 读）。原版语义是 `loadEp(comicId, **null**)`。我们的详情页在章节为空时直接弹「没有可阅读的章节」→ 卡在门口。
   → `ComicDetailPage.buildChapters`：列表为空时补一个**隐式章节**「全一話」(id 留空)。
2. **`epId` 为空要传 `null` 而不是 `""`** → `JsRuntime.callLoadEp` / `callOnImageLoad`：`epId.length === 0 ? 'null' : JSON.stringify(epId)`。
3. **`onImageLoad` 返回的 `url` 可以覆盖"图片标识"**：EH 的 `loadEp` 返回的是**页码**（`"0","1",…`），真实地址由 `onImageLoad` 返回的 `url` 给出（原版取 `configs['url'] ?? imageKey`）。我们之前只读 `headers`/`modifyImage`，把 url 丢了 → 会去下载字符串 `"0"`。
   → `ComicReadService`：新增 `cfg.url`，`target = cfg.url || url`。

**验证**：EH 详情显示「全一話」→ 阅读器 `1 / 24`，日志 `章节 ehentai@: 24 张图` + `图片就绪 1280×1871` ×3；picacg 回归正常（`章节 1, 12 张图`、`1 / 12`）。

### 4.5 顺带

- 默认 UA 从 `VeneraNext/1.0` 改为**原版 `webUA`（桌面 Chrome 119）**——不少网页源按 UA 返回不同页面。
- 所有临时诊断代码（探针、DIAG 日志、`normalizeEmptyEps`）**已全部删除**，当前代码是干净状态（可 `grep -rn "DIAG\|临时诊断\|探针" entry/src/main/ets` 复核）。

---

## 5. 待办清单（按优先级）

### P0（进行中：阶段 3 收尾）

| # | 事项 | 说明 |
|---|---|---|
| b3 | 详情页样式对齐本地 `DetailPanel` 同款 | `ComicDetailPage` 已吸收版式，需最终对齐（用户要求） |
| b4 | 书架切入统一详情页 + 本地自定义描述/自定义 TAG 上线 | `DetailPanel.localEditPlaceholder` 目前是**纯占位无 onClick**；需输入弹窗 + 持久化；书架 tab 改走 `ComicDetailPage` |
| b5 | 收藏功能上线 | 现状 `ShelfItem.isFavorite` 恒 false、按钮是 toast 占位；需本地存储 + 详情页可切换 + 书架「收藏」tab 打通 |
| — | 图片磁盘缓存 | 当前**仅内存 8 张**，`clearCache()` 退出阅读器即清空（原版有磁盘缓存） |
| — | `modifyImage` 图片还原实测 | 代码已通，但只在 jm `chapterId > 220980` 的章节才会真正触发，尚未实测 |
| — | 章节分组与倒序 | `ComicChapters.grouped` 已能解析分组，详情页目前**扁平展示**，未做分组标题、未支持 `reverseChapterOrder` |

### P1 / P2（阶段 4–6，见 `HARMONYOS_ARKTS_PORT_PLAN.md` §13）

本地收藏 CRUD、网络收藏（含 Login expired 重试）、下载队列、本地漫画离线阅读、CBZ 导入、WebView 登录 + Cookie 回写、Cloudflare 挑战、代理/DNS Override、应用锁、WebDAV + `.venera` 导入导出、图片收藏/追更/章评/EPUB-PDF 导出、JSPool 改图。

---

## 6. Spec / 阶段进度（以本节为准，规划文档的勾选框已过期）

| 阶段 | 内容 | 状态 |
|---|---|---|
| 阶段 0 | 工程底座 / JSVM 引擎 / `init.js` / sendMessage 桥 | ✅ 完成（真实 JSVM 内核已跑通，非 Mock） |
| 阶段 1 | 源管理闭环（index.json / 安装更新删除 / settings / `{key}.data`） | ✅ 完成（spec：`js-source-manager-plan.md`，其"后置里程碑 M0B"也已于后续做完） |
| 阶段 2 | 网络桥 + HtmlDocument 桥 + Convert + 发现/分类/搜索 | ✅ 完成（Explore 三类型、Categories/CategoryComics、单源+聚合搜索均可用） |
| 阶段 3 | 详情 + 阅读器 + 图片管道 | 🟡 **主体完成**（loadInfo/loadEp/onImageLoad/modifyImage/跨章切换/历史进度均已真机验证）；剩 磁盘缓存、分组倒序、modifyImage 实测 → §5 P0 |
| 阶段 4 | 收藏与本地（本地/网络收藏、下载队列、本地漫画、CBZ） | ⬜ 未开始（收藏为该阶段首个 b5） |
| 阶段 5 | 安全与韧性（WebView 登录、Cloudflare、代理、应用锁） | ⬜ 未开始 |
| 阶段 6 | 同步与增强（WebDAV、图片收藏、追更、导出、Headless） | ⬜ 未开始 |

另有一份独立 spec：`local-import-rich-reader-plan.md`（本地 TXT/EPUB 导入 + 富文本阅读）——**已实现**（`utils/parsers/TxtParser|EpubParser`、`ReaderPage` 的 RICH 页、`BookshelfPage` 导入入口均在）。

---

## 7. 已知问题（已发现、未排查，非本轮范围）

| 现象 | 线索 |
|---|---|
| 嗨皮漫画（`happy.js`）加载失败 | `HttpClient: request failed: Internal error \| code=2300999 \| url=https://m.happymh.com`，底层 `CURLcode 35`（SSL connect error）→ 疑站点/网络问题，非解析问题 |
| comic-walker 启动时报 401 | `https://mobileapp.comic-walker.com/v1/users` → `Parameter error`；疑"未登录态探测"，需确认是否影响功能 |
| 部分源搜索/分类需登录 | 如 nhentai / EH 的收藏、JM 的部分接口；WebView 登录属阶段 5 |

---

## 8. 踩坑与约束清单（**最有价值的复用资产**）

### 鸿蒙 API / ArkTS

1. **`http` 的 `extraData`**：非 POST/PUT 会被拼到 URL（空串也加 `&`）→ 只在 POST/PUT 传（§4.1）。
2. **默认 UA**：源未指定时用桌面 Chrome UA，对齐原版 `webUA`。
3. **沉浸光感 `uiMaterial.ImmersiveMaterial` 有生效范围**：仅 Navigation/NavDestination 标题栏、`BarPosition.End` 的底部 TabBar、以及弹窗类组件（含 `bindSheet`）。普通区域用会报 `Material inactive: out of scope`。配 `expandSafeArea([SafeAreaType.SYSTEM])` 让材质延伸到状态栏/挖孔区（横屏右侧才不会截断）。
4. **ArkTS 严格模式**：禁 `any`（用 `Object`/`Record<string,T>`/明确 interface）；对象字面量必须有明确类型（`arkts-no-untyped-obj-literals`）；数组字面量元素类型要可推断；`throw` 只能抛 Error 子类。
5. **ArkUI 8 位色是 `#AARRGGBB`（Alpha 在前）**，不是 `#RRGGBBAA`。
6. **`ForEach` 的 key 必须包含可变字段**，否则 ArkUI 复用子节点不刷新（配 `@Observed` + `@ObjectLink` 才算稳）。本轮多次踩到。
7. `Swiper` **没有** `onReachEnd`；初始页用 `.index()`。
8. 取响应体统一用 `expectDataType: ARRAY_BUFFER` 再手动解码，规避 STRING 模式的编码隐患。

### HTML 解析（自研，`HtmlDom.ets`）

9. **要补隐式 `<tbody>`**（`<table>` 下直接出现的 `<tr>`）——大量源的 `table.xxx > tbody > tr` 依赖它（§4.2）。
10. **重复属性"第一个优先"**（HTML5 规范），不是最后一个（§4.3）。
11. 选择器引擎已支持：`tag`、`.class`、`#id`、`[attr]`、`[attr=~=|=^=$=*]`、后代、`>`、`:nth-child()`。**不支持** `+`/`~`/伪类如 `:not()`，遇到新源报"命中 0"时先看选择器用了什么。

### 源协议（venera JS 源）

12. **`Network.get(url, headers, extra)` 的第 3 个参数是 `extra`（给拦截器用），不是请求体**，原版也不会拼到 URL 上。
13. **无章节源**：`loadInfo` 不返回 `chapters`（整本即一章）→ 阅读走 `loadEp(comicId, null)`（§4.4）。
14. **`onImageLoad` 返回的 `url` 可以覆盖图片标识**（如 EH 把页码解析成真实地址），原版取 `configs['url'] ?? imageKey`。
15. 源协议的权威文档：`venera-master/doc/js_api.md` + `venera-master/assets/init.js`；判断"原版怎么处理"一律回查 `venera-master/lib/foundation/`。

---

## 9. 换设备续接 Checklist

1. 拷贝整个 `VENERA` 目录（无 git，建议自行打包/网盘）。
2. 复核 `VeneraNextNew/build-profile.json5` 里 **签名材料绝对路径**（`C:/Users/RAIGLIM/...`），若新设备路径或用户名不同：改路径或 `devecocli signature generate --force`。
3. 连真机 → `devecocli device list`；若设备名不同，替换命令里的 `--device`。
4. `devecocli run` 跑一次，确认能装能启（首次会全量编译，较慢）。
5. 新会话开场把本文件发给 AI，并说明"接着 §5 P0 的 b3/b4/b5"。若会话上下文丢失，可让 AI 先读 §3 代码地图 + §8 踩坑清单再动手。
6. 源数据（`{key}.data`、已安装源、书架）在**应用沙箱内**，换设备不会自动同步 → 重装后需重新添加源并登录。
