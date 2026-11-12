# Komga 漫画服务器接入可行性调研

> 调研对象: [Komga](https://komga.org)（开源自托管漫画/电子书服务器，Kotlin + Spring Boot）
> 调研版本: API v1 / 文档 1.30.x
> 结论: **可行**。纯 JS 源可覆盖浏览/搜索/详情/阅读/登录；但"列表封面鉴权"是唯一硬缺口，推荐用 MangaBridges Windows 测试服务器做一层 Komga 适配（代理）最稳。

---

## 一、Komga 是什么

- 自托管漫画服务器，扫描磁盘漫画库（CBZ/CBR/PDF/EPUB 等），提供 Web UI、OPDS、REST API。
- 数据模型：**Library → Series → Book → Page**
  - Series ≈ 一部漫画；Book ≈ 卷/话；Page ≈ 页面图片。
- REST API 基础路径 `/api/v1`（部分用户接口在 `/api/v2`），OpenAPI 可在运行实例的 `/swagger-ui.html` 查看。

## 二、认证

- **Basic Auth**：`Authorization: Basic base64(user:password)`
- **API Key**：请求头 `X-API-Key: <key>`（在 `/api/v2/users/me/api-keys` 创建）
- **会话**：登录后返回 `KOMGA-SESSION` Cookie；或请求头 `X-Auth-Token` 复用会话
- 除登录/公告等少数接口外，**所有接口（含封面、页面图片）都需要认证**

## 三、关键端点（v1.30）

| 用途 | 方法 / 路径 | 说明 |
|------|-------------|------|
| 库列表 | `GET /api/v1/libraries` | 获取 libraryId |
| 系列列表 | `GET /api/v1/series?page=&size=&sort=&search=&library_id=&genre=&tag=&read_status=&complete=` | 返回 Spring `Page<SeriesDto>`；另有 `POST /api/v1/series/list`（新接口） |
| 系列详情 | `GET /api/v1/series/{seriesId}` | `SeriesDto`（含 metadata/title/summary/genres/tags/booksCount） |
| 系列封面 | `GET /api/v1/series/{seriesId}/thumbnail` | `image/jpeg`，需认证 |
| 系列的书 | `GET /api/v1/series/{seriesId}/books?page=&size=&sort=` | 返回 `Page<BookDto>`（已标记 deprecated，推荐 `POST /api/v1/books/list` + `series_id`） |
| 书列表 | `POST /api/v1/books/list` | body 过滤条件，返回 `Page<BookDto>` |
| 书详情 | `GET /api/v1/books/{bookId}` | `BookDto`（name/metadata.media.pagesCount/readProgress） |
| 书的页面清单 | `GET /api/v1/books/{bookId}/pages` | `PageDto[]`：number(1 基)、fileName、mediaType、width/height、sizeBytes |
| 页面图片 | `GET /api/v1/books/{bookId}/pages/{pageNumber}?zero_based=false&convert=jpeg` | 1 基页码；`convert` 支持 jpeg/png；需认证 |
| 页面缩略图 | `GET /api/v1/books/{bookId}/pages/{pageNumber}/thumbnail` | 300px 缩略图 |
| 阅读进度 | `PATCH /api/v1/books/{bookId}/read-progress` | body `{page, completed}` |
| 收藏集合 | `GET /api/v1/collections`、`GET /api/v1/collections/{id}/series` | Collection 可当"收藏夹" |
| 阅读清单 | `GET /api/v1/readlists`、`GET /api/v1/readlists/{id}/books` | ReadList 可当"书单/收藏夹" |
| 当前用户 | `GET /api/v2/users/me` | 登录校验 |
| OPDS | `/opds/v1.2/...` | Atom XML，可作兜底通道 |

分页响应为 Spring Data `Page`：`content[]`、`totalElements`、`totalPages`、`number`（**0 基**）、`size`。

## 四、与 MangaBridges 源接口的映射

| MangaBridges 源接口 | Komga 实现 | 备注 |
|--------------------|-----------|------|
| `explore[].load(page)` | `GET /api/v1/series?page=page-1&size=pageSize&sort=lastModified,desc` | page 需 −1；maxPage = `totalPages` |
| `search.load(keyword,...)` | `GET /api/v1/series?search=keyword&page=...` | 关键词搜标题/元数据 |
| `categoryComics.load(category)` | `genre` / `tag` / `publisher` / `read_status` 过滤 | Komga 无固定"分类页"，用标签动态生成 |
| `comic.loadInfo(id)` | `GET /api/v1/series/{id}` + `/books` | chapters = books（book.id → 章节名） |
| `comic.loadEp(comicId, epId)` | `GET /api/v1/books/{bookId}/pages` → 拼图片 URL | 页面 1 基 |
| `comic.onImageLoad(url,...)` | 返回 `{ headers: { Authorization: Basic ... } }` | 阅读页可正常鉴权（App 走 ComicReadService 带 header 下载） |
| `account.login(account,password)` | `GET /api/v2/users/me`（Basic） | 成功后把 base64 凭据存进源数据 |
| `favorites.loadFolders/loadComics` | Collections / ReadLists | 收藏操作需 POST/DELETE 集合成员 |
| 评论 | 无 | 源不声明 loadComments 即可 |
| `idMatch` | series id（UUID） | 可作为 ID 直达 |

## 五、兼容性缺口与风险

1. **列表封面鉴权（硬缺口）**
   发现页/搜索页的封面是 ArkUI `Image(c.cover)` 直接加载，**不会带源声明的请求头**；Komga 缩略图必须认证，因此列表封面会 401。
   - 可选方案：
     a. 用 Windows 测试服务器做 **Komga 适配/代理**：服务器持 Basic/API Key 拉 Komga，再以无鉴权方式对内提供封面和 API（推荐）；
     b. 修改 App：列表封面也走源 `onImageLoad` 的 header（需要改应用代码，工作量大）；
     c. URL 内嵌凭据 `http://user:pass@host/...`（HarmonyOS 支持情况不确定，不推荐）。
2. **分页 0 基 vs App 1 基**：转换即可，注意 `maxPage` 取 `totalPages`。
3. **Series/Book 层级**：Komga 的 Book 可能是一卷（多话）或单话；映射成"章节"后，章节名建议用 `metadata.title || name`，并显示 `number`。
4. **阅读方向**：Komga 有 `readingDirection: LEFT_TO_RIGHT / RIGHT_TO_LEFT / WEBTOON`；当前阅读器未做日漫 RTL 支持，可忽略或用设置项。
5. **API 演进**：`GET /api/v1/series`、`GET /api/v1/series/{id}/books` 已标记 deprecated（推荐 `POST .../list`）；建议实现时优先新接口、旧接口兜底。版本要求 ≥ 1.19（books/list），更早版本需用 GET。
6. **PDF/EPUB 书**：`/pages` 对 PDF 动态分页，页面图片仍可用；EPUB 返回的是页图像，阅读体验与原生 EPUB 不同。
7. **性能**：页面图默认原始格式较大，建议加 `?convert=jpeg`；封面缩略图 300px 已够列表用。
8. **权限模型**：Komga 可限制用户访问的库/年龄分级；API Key 或账号需有对应库权限。

## 六、落地路线建议

**路线 A：纯 JS 源直连 Komga**
- 工作量：约 1 天；覆盖发现/搜索/详情/阅读/登录。
- 适合：Komga 部署在内网且能关闭/绕过封面鉴权（较少见），或能接受列表封面缺失。

**路线 B：Windows 测试服务器做 Komga 适配层（推荐）**
- 测试服务器新增"Komga 源"模式：配置 Komga 地址 + 账号/API Key，服务器代理 `/api/v1/*` 并缓存封面，对内输出 MangaBridges 现有 API 与无鉴权图片，自动生成源脚本。
- 工作量：约 1.5–2 天；彻底规避封面鉴权、CORS、分页差异与 API 版本漂移，也方便审核演示时用 Komga 库。
- 对 App 零改动，复用现有源脚本与设置体系。

**路线 C：原生 ArkTS 源（实现 ComicSourceProtocol）**
- 不推荐：脱离 JS 源插件体系，后续维护成本高。

## 七、验证清单（做 PoC 时用）

- [ ] 用 Basic Auth 拉 `/api/v1/series?page=0&size=12`，核对 `content/totalPages`
- [ ] 拉 `/api/v1/series/{id}/books`，确认书籍数量与章节名
- [ ] 拉 `/api/v1/books/{id}/pages`，核对页数与 `number` 起始
- [ ] 直接打开 `/api/v1/books/{id}/pages/1`（带 Basic 头）确认图片字节
- [ ] 不带认证打开 `/api/v1/series/{id}/thumbnail`，确认 401（验证封面缺口）
- [ ] 测 `PATCH /read-progress` 与 Collections 收藏流程（可选）
