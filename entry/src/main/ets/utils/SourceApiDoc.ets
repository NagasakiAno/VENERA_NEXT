/**
 * VeneraNext JS 漫画源搭建原理与接口文档
 * 供漫画源管理界面展示与保存到本地
 */

export const SOURCE_API_DOC: string = `# VeneraNext JS 漫画源搭建原理与接口文档

## 一、架构概述

VeneraNext 采用 JS 源插件系统作为漫画数据来源的核心架构。源以独立 .js 文件形式存在，通过继承 ComicSource 基类声明能力，由 ArkTS 侧的 JsRuntime 加载到 C++ JSVM 中执行，实现与宿主 App 的双向通信。

### 1.1 两阶段解析

| 阶段 | 名称 | 实现 | 产出 |
|------|------|------|------|
| A 阶段 | 静态正则解析 | ComicSourceParser.ets | 从源文件文本中提取 key/name/version/能力掩码/settings/account 等元信息，无需执行 JS |
| B 阶段 | JSVM 真引擎解析 | JsRuntime.ets 的 enrich*() 方法 | 将源加载到 JSVM 中执行，获取 explore/category/searchOptions/favorites 等运行时才能确定的精确信息 |

### 1.2 源生命周期

扫描磁盘 .js 文件 → ComicSourceParser.parse() 正则解析 → ComicSourceManager.addJsSource(meta) 注册到源池 → 用户点击源/首次调用 → JsRuntime.ensureLoaded(key) 加载到 JSVM → 源实例 init() → enrich* 补全 → call* 方法按需调用

### 1.3 通信机制

源脚本通过全局 sendMessage(message) 函数与宿主通信，宿主侧 JsRuntime.handleMessage() 分发到各处理器：
- 同步方法：load_data/save_data/load_setting/convert/cookie/html/image/random/uuid/isLogged/getLocale/getPlatform
- 异步方法：http/delay/compute/UI

---

## 二、源脚本结构

### 2.1 基本模板

class MySource extends ComicSource {
    key = "mysource"
    name = "我的漫画源"
    version = "1.0.0"
    minAppVersion = "1.0.0"
    url = "https://example.com"

    // 漫画 ID 规则（可选）
    // idMatch: "^(\\\\d+|jm\\\\d+)$"

    // 发现页（可选）
    explore = [
        {
            title: "热门",
            type: "multiPageComicList",
            load: async (page) => { /* 返回 {comics: Comic[], maxPage: number} */ }
        }
    ]

    // 搜索（可选）
    search = {
        load: async (keyword, options, page) => { /* 分页式 */ },
        optionList: [
            { label: "排序", type: "select", options: {"popular":"热门","latest":"最新"}, defaultValue: "popular" }
        ]
    }

    // 漫画详情与章节（可选）
    comic = {
        loadInfo: async (id) => { /* 返回 ComicDetails */ },
        loadEp: async (comicId, epId) => { /* 返回 {images: string[]} */ }
    }

    // 分类（可选）
    category = {
        title: "分类",
        parts: [{ name: "标签", type: "fixed", categories: [{label:"动作", target:{page:"category", attributes:{category:"action"}}}] }]
    }

    // 分类结果加载（可选）
    categoryComics = {
        load: async (category, param, options, page) => { /* 返回 {comics, maxPage} */ }
    }

    // 设置（可选）
    settings = {
        imageQuality: { title: "图片质量", type: "select", default: "high", options: ["low","medium","high"] },
        enableCache: { title: "启用缓存", type: "switch", default: true },
        clearCache: { title: "清除缓存", type: "callback" }
    }

    // 账号（可选）
    account = {
        login: async (account, password) => { /* 账密登录 */ }
    }

    // 网络收藏（可选）
    favorites = {
        title: "我的收藏",
        multiFolder: true,
        loadComics: async (page, folderId) => { /* 返回 {comics, maxPage} */ },
        loadFolders: async (comicId) => { /* 返回 {folders, favorited} */ },
        addOrDelFavorite: async (comicId, folderId, isAdding, favId) => {}
    }

    init() { /* 源加载后自动调用 */ }
}

### 2.2 能力掩码

| 字段 | 检测关键词 | 说明 |
|------|-----------|------|
| hasExplore | explore | 发现页 |
| hasSearch | search | 搜索 |
| hasLoadInfo | loadComicInfo 或 loadInfo | 漫画详情 |
| hasLoadEp | loadComicPages 或 loadEp | 章节图片 |
| hasSettings | settings | 设置项 |
| hasAccount | account | 账号系统 |

---

## 三、数据模型

### Comic
new Comic({ id, title, subtitle, cover, tags, description, maxPage, language, favoriteId, stars })

### ComicDetails
new ComicDetails({ title, subtitle, cover, description, tags, chapters, isFavorite, subId, thumbnails, recommend, commentCount, likesCount, isLiked, uploader, updateTime, uploadTime, url, stars, maxPage, comments })

### Comment
new Comment({ userName, avatar, content, time, replyCount, id, isLiked, score, voteStatus })

### ImageLoadingConfig
new ImageLoadingConfig({ url, method, data, headers, onResponse, modifyImage, onLoadFailed })

---

## 四、宿主提供的 JS API

### Network — HTTP 请求
Network.sendRequest(method, url, headers, data, extra) → Promise<{status, headers, body}>
Network.fetchBytes(method, url, headers, data, extra) → Promise<{status, headers, body: ArrayBuffer}>
Network.get(url, headers, extra)
Network.post(url, headers, data, extra)
Network.put(url, headers, data, extra)
Network.patch(url, headers, data, extra)
Network.delete(url, headers, extra)
fetch(url, { method, headers, body }) → Promise<{ok, status, headers, arrayBuffer(), text(), json()}>
Network.setCookies(url, cookies)
Network.getCookies(url) → Promise<Cookie[]>
Network.deleteCookies(url)

### Convert — 编解码与加密
Convert.encodeUtf8(str) / Convert.decodeUtf8(bytes)
Convert.encodeGbk(str) / Convert.decodeGbk(bytes)
Convert.encodeBase64(bytes) / Convert.decodeBase64(str)
Convert.md5(bytes) / Convert.sha1(bytes) / Convert.sha256(bytes) / Convert.sha512(bytes)
Convert.hmac(key, value, hash) / Convert.hmacString(key, value, hash)
Convert.encryptAesEcb(value, key) / Convert.decryptAesEcb(value, key)
Convert.encryptAesCbc(value, key, iv) / Convert.decryptAesCbc(value, key, iv)
Convert.encryptAesCfb(value, key, iv, blockSize) / Convert.decryptAesCfb(value, key, iv, blockSize)
Convert.encryptAesOfb(value, key, blockSize) / Convert.decryptAesOfb(value, key, blockSize)
Convert.decryptRsa(value, key)
Convert.hexEncode(bytes)

### HtmlDocument — HTML 解析
new HtmlDocument(htmlString)
doc.querySelector(query) → HtmlElement | null
doc.querySelectorAll(query) → HtmlElement[]
doc.getElementById(id) → HtmlElement | null
element.text / element.attributes / element.innerHTML / element.children / element.nodes
element.parent / element.classNames / element.id / element.localName
element.previousElementSibling / element.nextElementSibling
element.querySelector(query) / element.querySelectorAll(query)
node.text / node.type / node.toElement()
doc.dispose()

### Image — 位图操作（仅在 modifyImage 中可用）
Image.empty(width, height)
image.copyRange(x, y, width, height) → Image | null
image.copyAndRotate90() → Image | null
image.fillImageAt(x, y, srcImage)
image.fillImageRangeAt(x, y, srcImage, srcX, srcY, width, height)
image.width / image.height

### UI — 用户界面
UI.showMessage(message)
UI.showDialog(title, content, actions)
UI.launchUrl(url)
UI.showLoading(onCancel) → id
UI.cancelLoading(id)
UI.showInputDialog(title, validator, image) → Promise<string | null>
UI.showSelectDialog(title, options, initialIndex) → Promise<number | null>

### APP — 应用信息
APP.version / APP.locale / APP.platform

### ComicSource 基类方法
this.loadData(dataKey) / this.saveData(dataKey, data) / this.deleteData(dataKey)
this.loadSetting(key) / this.isLogged / this.translate(key)

### 全局工具函数
setTimeout(callback, delay) / setInterval(callback, delay)
createUuid() / randomInt(min, max) / randomDouble(min, max)
setClipboard(text) / getClipboard()
compute(func, ...args)
console.log(content) / console.warn(content) / console.error(content)

---

## 五、宿主侧调用接口（JsRuntime call* 方法）

### 5.1 核心调用
callSource(key, expr) — 任意表达式
callLoadInfo(sourceKey, id) — __m.comic.loadInfo(id) → ComicDetails
callLoadEp(sourceKey, comicId, epId) — __m.comic.loadEp(comicId, epId) → {images: string[]}
callOnImageLoad(sourceKey, url, comicId, epId) — ImageLoadingConfig 或 null
callModifyImage(sourceKey, key, code) — 还原后位图 key

### 5.2 搜索与分类
callSearchLoad(sourceKey, keyword, options, page) → {comics, maxPage}
callSearchLoadNext(sourceKey, keyword, options, next) → {comics, next}
callCategoryComicsLoad(sourceKey, category, param, options, page) → {comics, maxPage}

### 5.3 发现页
callExploreLoad(page, pageNo) — 按 type 分派
callExploreLoadNext(page, next) → {comics, next}

### 5.4 网络收藏
callFavoriteLoadComics(key, page, folderId) → {comics, maxPage}
callFavoriteLoadNext(key, next, folderId) → {comics, next}
callFavoriteLoadFolders(key, comicId) → {folders, favorited}
callFavoriteAddOrDel(key, comicId, folderId, isAdding, favId)
callFavoriteAddFolder(key, name)
callFavoriteDeleteFolder(key, folderId)

### 5.5 评论
callLoadComments(sourceKey, comicId, subId, page, replyTo) → {comments, maxPage}
callSendComment(sourceKey, comicId, subId, content, replyTo)
callLikeComment(sourceKey, comicId, subId, commentId, isLike)

### 5.6 设置与账号
callSettingCallback(key, settingKey)
loginWithPassword(key, account, password)
loginWithCookies(key, values)
logout(key) / reLogin(key) / isLogged(key)

### 5.7 B 阶段 enrich 方法
enrichSettings(meta) / enrichExplore(meta) / enrichCategory(meta)
enrichSearchOptions(meta) / enrichFavorites(meta)

---

## 六、设置类型

| 类型 | UI 呈现 | JS 声明 |
|------|---------|---------|
| input | 文本输入框 | { title, type: "input", default: "值" } |
| select | 下拉选择 | { title, type: "select", default: "值", options: ["a","b"] } |
| switch | 开关 | { title, type: "switch", default: true } |
| callback | 按钮 | { title, type: "callback", callback: () => {} } |

---

## 七、账号登录方式

| 方式 | JS 声明 | 说明 |
|------|---------|------|
| 账密登录 | account.login = async (account, password) => {} | 登录成功后 App 自动存储 |
| Cookies 登录 | account.loginWithCookies = { validate, fields } | 用户填入 cookie 值 |
| WebView 登录 | account.loginWithWebview = { url } | 弹出 WebView 页面 |

---

## 八、发现页类型

| type | 说明 | load 方法 |
|------|------|-----------|
| singlePageWithMultiPart | 单页多分区 | load() 无参数 |
| multiPartPage | 多分区页 | load() 无参数 |
| multiPageComicList | 多页漫画列表 | load(page) 或 loadNext(next) |
| mixed | 混合页 | load(page) |

---

## 九、源文件存放与命名

- 存放路径：App 沙箱 filesDir/sources/ 目录
- 文件命名：<key>.js
- 文件要求：必须包含 class XXX extends ComicSource，key 字段非空、仅含 [a-zA-Z0-9_]

---

## 十、版本兼容

- minAppVersion：源声明的最低 App 版本
- compareSemVer(v1, v2)：语义化版本比较
- APP.version：源脚本内可读取当前 App 版本
`;
