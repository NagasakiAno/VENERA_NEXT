# VeneraNext

一款基于 **HarmonyOS** 的开源漫画阅读器，采用 **JS 源插件系统** 作为漫画数据来源。本应用本身不提供、不存储、不传播任何漫画内容，所有内容均来源于用户自行安装的第三方漫画源插件。

## ✨ 特性

- **多源聚合**：支持同时安装多个 JS 漫画源，发现页/搜索/分类多源聚合展示
- **JS 源插件系统**：源以独立 `.js` 文件形式存在，继承 `ComicSource` 基类声明能力，无需修改应用代码即可扩展
- **响应式布局**：手机/平板/折叠屏自适应，竖屏底部页签 + 横屏侧边栏双形态
- **本地书架**：支持导入本地漫画文件，阅读进度、收藏本地持久化
- **网络收藏同步**：支持将收藏同步回源账号（含收藏文件夹管理）
- **华为分享**：详情页一键分享漫画到附近设备，接收方自动导入收藏
- **按 ID 直达**：搜索框输入漫画 ID（命中源声明的 `idMatch` 正则）可直接打开详情
- **沉浸式阅读**：全屏阅读器，支持阅读进度记忆

## 📱 系统要求

- HarmonyOS（API 12+）
- 设备类型：手机 / 平板

## 📦 安装

### 从 Release 安装

前往 [Releases](../../releases) 页面下载最新的 `.app` 或 `.hap` 安装包。

### 从源码构建

```bash
# 设置 SDK 路径
$env:DEVECO_SDK_HOME="<DevEco Studio 安装路径>\sdk"

# 构建 HAP（真机调试）
& "<DevEco Studio 安装路径>\tools\hvigor\bin\hvigorw.bat" --mode module -p module=entry@default assembleHap

# 构建 APP（应用市场提交）
& "<DevEco Studio 安装路径>\tools\hvigor\bin\hvigorw.bat" --mode project -p signingConfig=none assembleApp
```

构建产物：

| 文件 | 路径 | 用途 |
|------|------|------|
| HAP | `entry/build/default/outputs/default/entry-default-unsigned.hap` | 手动签名后真机安装 |
| APP | `build/outputs/default/VeneraNextNew-default-unsigned.app` | 提交华为应用市场审核 |

## 🔌 漫画源插件

### 源搭建

源以 JavaScript 脚本形式编写，继承 `ComicSource` 基类声明能力：

```javascript
class MySource extends ComicSource {
    key = "mysource"              // 源唯一标识
    name = "我的漫画源"            // 显示名称
    version = "1.0.0"
    minAppVersion = "1.0.0"
    url = "https://example.com"

    // 发现页
    explore = [
        {
            title: "热门",
            type: "multiPageComicList",
            load: async (page) => ({ comics: [], maxPage: 1 })
        }
    ]

    // 搜索
    search = {
        load: async (keyword, options, page) => ({ comics: [], maxPage: 1 }),
        optionList: []
    }

    // 详情与章节
    comic = {
        loadInfo: async (id) => ({}),
        loadEp: async (comicId, epId) => ({ images: [] })
    }
}
```

完整的源搭建原理与接口文档见 [docs/源搭建原理与接口文档.md](docs/源搭建原理与接口文档.md)。

### 安装源

在应用内 **设置 → 漫画源** 中通过 URL 下载或本地文件导入 `.js` 源脚本。

> ⚠️ 源插件以 JavaScript 形式运行，具备网络请求、本地数据读写等能力。安装前请仔细审查源代码，仅从可信渠道获取。

## 📖 使用说明

| 功能 | 入口 |
|------|------|
| 书架 | 底部页签「书架」— 本地导入书 + 收藏的漫画 |
| 发现 | 底部页签「发现」— 多源发现页聚合，顶部芯片切换源 |
| 分类 | 发现页右上角网格图标 — 多源分类聚合 |
| 搜索 | 发现页右上角放大镜 — 多源聚合搜索 / 按 ID 直达 |
| 分享 | 漫画详情页分享按钮 — 华为分享到附近设备 |
| 源管理 | 设置 → 漫画源 — 安装/更新/删除源 |

## 📄 免责声明

本应用是一款开源漫画阅读器软件，本身 **不提供、不存储、不传播** 任何漫画内容。所有漫画内容均来源于用户自行安装的第三方漫画源插件，源插件由第三方开发者独立编写和维护。

完整免责声明见 [docs/免责声明.md](docs/免责声明.md)。**使用本应用即表示您已阅读、理解并同意免责声明的全部内容。**

## 📄 许可证

本项目基于 Apache License 2.0 开源。
