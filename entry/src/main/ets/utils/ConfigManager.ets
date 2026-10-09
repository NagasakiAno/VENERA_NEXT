/**
 * VeneraNext 配置导入导出工具
 * - 导出: AppSettings + JS源文件内容 + 源数据(登录态/cookies) + 收藏列表 → JSON 文件
 * - 导入: 从 JSON 文件恢复全部配置(写回.js和.data文件, 重新扫描注册)
 * - 使用 picker.DocumentViewPicker 选择保存/读取位置(临时权限)
 */
import { picker, fileIo as fs } from '@kit.CoreFileKit';
import { common } from '@kit.AbilityKit';
import { util } from '@kit.ArkTS';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { appSettings } from '../model/AppSettings';
import { comicSourceManager } from '../model/ComicSource';
import { localFavoritesStore, FavoriteItem } from '../model/LocalFavoritesStore';
import { ComicSourceMeta } from '../model/sources/ComicSourceMeta';
import { JsSourceFileStore } from './JsSourceFileStore';
import { sourceDataStore } from '../services/SourceDataStore';
import { jsSourceManager } from '../services/JsSourceManager';

const DOMAIN = 0x0000;
const TAG = 'ConfigManager';

/** 导出数据结构 */
interface ExportData {
  version: number;
  exportTime: number;
  settings: Record<string, Object>;
  jsSources: ComicSourceMeta[];
  /** JS源文件内容: fileName → 脚本全文 */
  jsSourceFiles: Record<string, string>;
  /** 源运行时数据(登录态/cookies/设置): sourceKey → data JSON */
  sourceData: Record<string, string>;
  favorites: FavoriteItem[];
}

/**
 * 导出配置到用户选择的文件位置
 * @returns 是否成功
 */
export async function exportConfig(context: common.UIAbilityContext): Promise<boolean> {
  try {
    const store = new JsSourceFileStore(context);
    sourceDataStore.init(context);

    // 1. 收集 JS 源文件内容
    const jsSourceFiles: Record<string, string> = {};
    const jsFileNames = store.listJs();
    for (let i = 0; i < jsFileNames.length; i++) {
      const fileName = jsFileNames[i];
      const content = store.readJs(fileName);
      if (content.length > 0) {
        jsSourceFiles[fileName] = content;
      }
    }
    hilog.info(DOMAIN, TAG, '导出 JS 源文件: %{public}d 个', jsFileNames.length);

    // 2. 收集源运行时数据(登录态/cookies/源设置)
    const sourceData: Record<string, string> = {};
    const allSources = comicSourceManager.allJsSources();
    for (let i = 0; i < allSources.length; i++) {
      const key = allSources[i].key;
      const dataJson = store.readData(key);
      if (dataJson.length > 0) {
        sourceData[key] = dataJson;
      }
    }
    hilog.info(DOMAIN, TAG, '导出源数据: %{public}d 个', Object.keys(sourceData).length);

    // 3. 收集配置数据
    const data: ExportData = {
      version: 2,
      exportTime: Date.now(),
      settings: collectSettings(),
      jsSources: allSources,
      jsSourceFiles: jsSourceFiles,
      sourceData: sourceData,
      favorites: collectFavorites()
    };

    const json = JSON.stringify(data);
    const encoder = new util.TextEncoder();
    const bytes = encoder.encodeInto(json);

    // 4. 使用 DocumentViewPicker 选择保存位置
    const pickerInst = new picker.DocumentViewPicker(context);
    const opts = new picker.DocumentSaveOptions();
    opts.newFileNames = ['venera_config.json'];
    const uris: string[] = await pickerInst.save(opts);
    if (uris.length === 0) {
      return false;
    }

    // 5. 写入文件
    const uri = uris[0];
    const file = fs.openSync(uri, fs.OpenMode.WRITE_ONLY | fs.OpenMode.CREATE | fs.OpenMode.TRUNC);
    fs.writeSync(file.fd, bytes.buffer);
    fs.closeSync(file);

    hilog.info(DOMAIN, TAG, '配置导出成功: %{public}s', uri);
    return true;
  } catch (e) {
    const err = e as BusinessError;
    hilog.error(DOMAIN, TAG, 'exportConfig failed code=%{public}s msg=%{public}s',
      err.code, err.message);
    return false;
  }
}

/**
 * 从用户选择的文件导入配置
 * @returns 是否成功
 */
export async function importConfig(context: common.UIAbilityContext): Promise<boolean> {
  try {
    // 1. 选择文件
    const pickerInst = new picker.DocumentViewPicker(context);
    const opts = new picker.DocumentSelectOptions();
    opts.fileSuffixFilters = ['.json'];
    opts.maxSelectNumber = 1;
    const uris: string[] = await pickerInst.select(opts);
    if (uris.length === 0) {
      return false;
    }

    // 2. 读取文件
    const uri = uris[0];
    const file = fs.openSync(uri, fs.OpenMode.READ_ONLY);
    const stat = fs.statSync(file.fd);
    const buf = new ArrayBuffer(stat.size);
    fs.readSync(file.fd, buf);
    fs.closeSync(file);
    const decoder = util.TextDecoder.create('utf-8');
    const text = decoder.decodeToString(new Uint8Array(buf));

    // 3. 解析 JSON
    const data = JSON.parse(text) as ExportData;
    if (data.version === undefined) {
      hilog.warn(DOMAIN, TAG, '无效的配置文件');
      return false;
    }

    const store = new JsSourceFileStore(context);
    sourceDataStore.init(context);

    // 4. 恢复设置
    await restoreSettings(data.settings);

    // 5. 恢复 JS 源文件(写回 .js 文件到 comic_source/)
    if (data.jsSourceFiles) {
      const fileNames = Object.keys(data.jsSourceFiles);
      for (let i = 0; i < fileNames.length; i++) {
        const fileName = fileNames[i];
        const content = data.jsSourceFiles[fileName];
        if (content && content.length > 0) {
          store.writeJs(fileName, content);
        }
      }
      hilog.info(DOMAIN, TAG, '恢复 JS 源文件: %{public}d 个', fileNames.length);
    }

    // 6. 恢复源运行时数据(登录态/cookies/源设置)
    if (data.sourceData) {
      const sourceKeys = Object.keys(data.sourceData);
      for (let i = 0; i < sourceKeys.length; i++) {
        const key = sourceKeys[i];
        const dataJson = data.sourceData[key];
        if (dataJson && dataJson.length > 0) {
          store.writeData(key, dataJson);
          // 刷新内存缓存, 让运行时立即读到新数据
          sourceDataStore.invalidate(key);
        }
      }
      hilog.info(DOMAIN, TAG, '恢复源数据: %{public}d 个', sourceKeys.length);
    }

    // 7. 重新扫描源文件, 注册到 ComicSourceManager
    jsSourceManager.scanFromFilesDir(context);

    // 8. 恢复收藏
    if (data.favorites && data.favorites.length > 0) {
      restoreFavorites(data.favorites);
      hilog.info(DOMAIN, TAG, '恢复收藏: %{public}d 个', data.favorites.length);
    }

    hilog.info(DOMAIN, TAG, '配置导入成功');
    return true;
  } catch (e) {
    const err = e as BusinessError;
    hilog.error(DOMAIN, TAG, 'importConfig failed code=%{public}s msg=%{public}s',
      err.code, err.message);
    return false;
  }
}

/** 收集所有 AppSettings 键值 */
function collectSettings(): Record<string, Object> {
  const out: Record<string, Object> = {};
  const keys = [
    'theme_mode', 'language', 'readerMode', 'comicDisplayMode',
    'comicSourceListUrl', 'explore_pages', 'categories', 'favorites',
    'searchSources', 'reverseChapterOrder', 'preloadPageCount',
    'cacheLimit', 'disclaimerAccepted'
  ];
  for (let i = 0; i < keys.length; i++) {
    const k = keys[i];
    const v = appSettings.get<Object>(k, '');
    out[k] = v;
  }
  return out;
}

/** 恢复 AppSettings */
async function restoreSettings(settings: Record<string, Object>): Promise<void> {
  const keys = Object.keys(settings);
  for (let i = 0; i < keys.length; i++) {
    const k = keys[i];
    const v = settings[k];
    if (v !== undefined && v !== null) {
      await appSettings.put(k, v as string | number | boolean);
    }
  }
}

/** 收集所有收藏项 */
function collectFavorites(): FavoriteItem[] {
  const allFolders = localFavoritesStore.getFolders();
  const out: FavoriteItem[] = [];
  for (let i = 0; i < allFolders.length; i++) {
    const items = allFolders[i].items;
    for (let j = 0; j < items.length; j++) {
      out.push(items[j]);
    }
  }
  return out;
}

/** 恢复收藏项 */
function restoreFavorites(items: FavoriteItem[]): void {
  for (let i = 0; i < items.length; i++) {
    const item = items[i];
    // 添加到默认收藏文件夹
    localFavoritesStore.addComic('收藏', item);
  }
}
