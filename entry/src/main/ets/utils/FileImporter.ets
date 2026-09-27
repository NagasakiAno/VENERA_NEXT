/**
 * VeneraNext 本地文件导入核心
 * - picker.DocumentViewPicker 选择文件(临时读写权限, 免持久化授权)
 * - 拷贝到应用沙箱 filesDir/books/ 持久保留
 * - 按后缀分发 TXT/EPUB 解析, 组装 ShelfItem 加入 LocalBookStore + 元信息落盘
 * - 提供持久化恢复(restoreImported)与惰性重解析(ensureBookData)
 */
import { picker, fileIo as fs } from '@kit.CoreFileKit';
import { common } from '@kit.AbilityKit';
import { util } from '@kit.ArkTS';
import { BusinessError } from '@kit.BasicServicesKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { ShelfItem, ShelfSourceType, ShelfChapter } from '../model/ShelfItem';
import { ReaderChapter, ReaderPageItem, ReaderPageType } from '../model/ReaderModel';
import { localBookStore } from '../model/LocalBookStore';
import { parseTxt } from './parsers/TxtParser';
import { parseEpub, extractEpubCover } from './parsers/EpubParser';

const DOMAIN = 0x0000;
const TAG = 'FileImporter';
const LOC_COVER: Resource = $r('app.media.blank_cover');

/** 持久化元信息 */
interface ImportedMeta {
  id: string;
  title: string;
  fileFormat: string;
  filePath: string;
  lastReadPage: number;
  /** 独立拷贝的封面文件沙箱路径(恢复时直接引用, 不重新解析) */
  coverPath: string;
  /** 详情页自定义描述(可选, 兼容旧记录) */
  customDescription?: string;
  /** 详情页自定义 TAG(可选, 兼容旧记录) */
  customTags?: string[];
  /** 是否收藏(可选, 兼容旧记录) */
  isFavorite?: boolean;
}

/** WEB 收藏条目元信息(filesDir/web_favorites.json, 详情快照) */
interface WebFavMeta {
  id: string;
  title: string;
  cover: string;
  author: string;
  description: string;
  tags: string[];
  /** 章节名列表(恢复时页数固定 0) */
  chapters: string[];
}

function webFavFile(context: common.Context): string {
  return context.filesDir + '/web_favorites.json';
}

/** 元信息文件路径(filesDir/imported.json, 纯文件存储, 不依赖 Preferences 时序) */
function metaFile(context: common.Context): string {
  return context.filesDir + '/imported.json';
}

function readTextFile(p: string): string {
  try {
    if (!fs.accessSync(p)) {
      return '';
    }
    const f = fs.openSync(p, fs.OpenMode.READ_ONLY);
    const stat = fs.statSync(f.fd);
    const buf = new ArrayBuffer(stat.size);
    fs.readSync(f.fd, buf);
    fs.closeSync(f);
    const decoder = util.TextDecoder.create('utf-8');
    return decoder.decodeToString(new Uint8Array(buf));
  } catch (e) {
    return '';
  }
}

function writeTextFile(p: string, text: string): void {
  try {
    const f = fs.openSync(p, fs.OpenMode.READ_WRITE | fs.OpenMode.CREATE | fs.OpenMode.TRUNC);
    fs.writeSync(f.fd, text);
    fs.closeSync(f);
  } catch (e) {
    hilog.error(DOMAIN, TAG, 'writeMeta fail %{public}s', JSON.stringify(e));
  }
}

/** 读取已导入书元信息 */
function readMeta(context: common.Context): ImportedMeta[] {
  const text = readTextFile(metaFile(context));
  if (text.length === 0) {
    return [];
  }
  try {
    return JSON.parse(text) as ImportedMeta[];
  } catch (e) {
    return [];
  }
}

function writeMeta(context: common.Context, arr: ImportedMeta[]): void {
  writeTextFile(metaFile(context), JSON.stringify(arr));
}

function extOf(p: string): string {
  const i = p.lastIndexOf('.');
  return i < 0 ? '' : p.substring(i).toLowerCase();
}

/** 从 uri 提取书名(去路径/扩展名, 解码) */
function titleOf(uri: string): string {
  let name = uri;
  const slash = name.lastIndexOf('/');
  if (slash >= 0) {
    name = name.substring(slash + 1);
  }
  const dot = name.lastIndexOf('.');
  if (dot > 0) {
    name = name.substring(0, dot);
  }
  try {
    return decodeURIComponent(name);
  } catch (e) {
    return name;
  }
}

/** 把临时 uri 拷贝到沙箱目标路径 */
function copyUriTo(uri: string, dest: string): void {
  const src = fs.openSync(uri, fs.OpenMode.READ_ONLY);
  try {
    fs.copyFileSync(src.fd, dest, 0);
  } finally {
    fs.closeSync(src);
  }
}

/**
 * 打开文件选择器并导入一本书
 * @returns 导入成功的 ShelfItem, 用户取消/失败返回 null
 */
export async function doImport(context: common.UIAbilityContext): Promise<ShelfItem | null> {
  try {
    const pickerInst = new picker.DocumentViewPicker(context);
    const opts = new picker.DocumentSelectOptions();
    opts.fileSuffixFilters = ['.txt', '.epub'];
    opts.maxSelectNumber = 1;
    const uris: string[] = await pickerInst.select(opts);
    if (uris.length === 0) {
      return null;
    }
    const uri = uris[0];
    const ext = extOf(uri);
    if (ext !== '.txt' && ext !== '.epub') {
      hilog.warn(DOMAIN, TAG, 'unsupported ext %{public}s', ext);
      return null;
    }

    // 拷贝入沙箱 filesDir(持久数据, 不受系统清缓存影响)
    const booksDir = context.filesDir + '/books';
    if (!fs.accessSync(booksDir)) {
      fs.mkdirSync(booksDir);
    }
    const fileId = Date.now().toString();
    const destPath = booksDir + '/' + fileId + ext;
    copyUriTo(uri, destPath);

    const title = titleOf(uri);
    let bookData: ReaderChapter[] = [];
    let chapters: ShelfChapter[] = [];
    let cover: Resource | string = LOC_COVER;
    let coverPath = '';
    if (ext === '.txt') {
      const ch = parseTxt(destPath, title);
      bookData = [ch];
      chapters = [new ShelfChapter('正文', ch.pages.length)];
    } else {
      const unzipDir = booksDir + '/' + fileId + '_epub';
      const ch = await parseEpub(destPath, unzipDir, title);
      bookData = [ch];
      chapters = [new ShelfChapter('正文', ch.pages.length)];
      // 提取 EPUB 封面并拷贝为独立文件(重启后直接引用, 不依赖重新解析 OPF)
      const extracted = extractEpubCover(unzipDir);
      if (extracted.length > 0) {
        const coverFile = booksDir + '/' + fileId + '_cover' + extOf(extracted);
        fs.copyFileSync(extracted, coverFile, 0);
        cover = 'file://' + coverFile;
        coverPath = coverFile;
      }
    }

    const item = new ShelfItem('imp_' + fileId, title, cover, '', '通过本地导入的电子书。',
      [ext.replace('.', '').toUpperCase()], ShelfSourceType.LOCAL, chapters,
      false, 0, '', 0, '', [], ext.replace('.', ''), bookData, true, destPath);
    localBookStore.addItem(item);
    writeMeta(context, buildMeta(context, item, coverPath));
    hilog.info(DOMAIN, TAG, 'imported %{public}s (%{public}s)', title, ext);
    return item;
  } catch (e) {
    const err = e as BusinessError;
    hilog.error(DOMAIN, TAG, 'doImport failed code=%{public}s msg=%{public}s',
      err.code, err.message);
    return null;
  }
}

/** 在已有元信息后追加一条并返回新数组(同步写盘) */
function buildMeta(context: common.Context, item: ShelfItem, coverPath: string): ImportedMeta[] {
  const arr = readMeta(context);
  for (let i = 0; i < arr.length; i++) {
    if (arr[i].id === item.id) {
      // 重导入同 id: 保留已有收藏状态与自定义字段
      const prev = arr[i];
      arr[i] = { id: item.id, title: item.title, fileFormat: item.fileFormat,
        filePath: item.sandboxPath, lastReadPage: item.lastReadPage, coverPath: coverPath,
        isFavorite: prev.isFavorite ?? false,
        customDescription: prev.customDescription ?? '',
        customTags: prev.customTags ?? [] };
      return arr;
    }
  }
  arr.push({
    id: item.id, title: item.title, fileFormat: item.fileFormat,
    filePath: item.sandboxPath, lastReadPage: item.lastReadPage, coverPath: coverPath,
    isFavorite: false
  });
  return arr;
}

/** 应用启动时恢复已导入的书(封面直接引用持久化的独立文件, 章节惰性解析) */
export function restoreImported(context: common.Context): void {
  const arr = readMeta(context);
  hilog.info(DOMAIN, TAG, 'restoreImported meta count=%{public}d', arr.length);
  for (let i = 0; i < arr.length; i++) {
    const m = arr[i];
    if (m.filePath.length === 0 || !fs.accessSync(m.filePath)) {
      hilog.warn(DOMAIN, TAG, 'restore skip missing file: %{public}s', m.id);
      continue;
    }
    let cover: Resource | string = LOC_COVER;
    // 直接引用独立拷贝的封面文件(不重新解析 OPF); 旧记录无 coverPath 走默认图
    if (m.coverPath !== undefined && m.coverPath.length > 0 && fs.accessSync(m.coverPath)) {
      cover = 'file://' + m.coverPath;
    }
    const it = new ShelfItem(m.id, m.title, cover, '', '通过本地导入的电子书。',
      [m.fileFormat.toUpperCase()], ShelfSourceType.LOCAL,
      [new ShelfChapter('正文', 1)], false, m.lastReadPage, '', 0, '', [],
      m.fileFormat, null, false, m.filePath);
    // 恢复用户自定义描述/TAG 与收藏状态(旧记录无此字段走默认值)
    it.customDescription = m.customDescription ?? '';
    it.customTags = m.customTags ?? [];
    it.isFavorite = m.isFavorite ?? false;
    localBookStore.addItem(it);
  }
}

/**
 * 详情页编辑后持久化条目元信息(自定义描述/TAG)
 * 仅更新 imported.json 中对应记录的自定义字段, 其余字段保持不变
 */
export function persistItemMeta(context: common.Context, item: ShelfItem): void {
  const arr = readMeta(context);
  for (let i = 0; i < arr.length; i++) {
    if (arr[i].id === item.id) {
      arr[i].customDescription = item.customDescription;
      arr[i].customTags = item.customTags;
      arr[i].isFavorite = item.isFavorite;
      writeMeta(context, arr);
      return;
    }
  }
  hilog.warn(DOMAIN, TAG, 'persistItemMeta missing meta id=%{public}s', item.id);
}

/** WEB 收藏全量落盘(仅收集 ShelfSourceType.WEB 条目) */
export function persistWebFavorites(context: common.Context, items: ShelfItem[]): void {
  const arr: WebFavMeta[] = [];
  for (let i = 0; i < items.length; i++) {
    const it = items[i];
    if (it.sourceType !== ShelfSourceType.WEB) {
      continue;
    }
    const chs: string[] = [];
    for (let j = 0; j < it.chapters.length; j++) {
      chs.push(it.chapters[j].name);
    }
    arr.push({ id: it.id, title: it.title, cover: it.cover as string, author: it.author,
      description: it.description, tags: it.tags, chapters: chs });
  }
  writeTextFile(webFavFile(context), JSON.stringify(arr));
}

/** 启动时恢复 WEB 收藏(详情快照, 章节页数固定 0, 仅书架展示) */
export function restoreWebFavorites(context: common.Context): void {
  const text = readTextFile(webFavFile(context));
  if (text.length === 0) {
    return;
  }
  let arr: WebFavMeta[] = [];
  try {
    arr = JSON.parse(text) as WebFavMeta[];
  } catch (e) {
    return;
  }
  for (let i = 0; i < arr.length; i++) {
    const m = arr[i];
    const chs: ShelfChapter[] = [];
    for (let j = 0; j < m.chapters.length; j++) {
      chs.push(new ShelfChapter(m.chapters[j], 0));
    }
    localBookStore.addItem(new ShelfItem(m.id, m.title, m.cover, m.author,
      m.description, m.tags, ShelfSourceType.WEB, chs, true,
      0, '', 0, '', [], '', null, false, ''));
  }
  hilog.info(DOMAIN, TAG, 'restoreWebFavorites count=%{public}d', arr.length);
}

/**
 * 惰性解析: 持久化恢复的书打开前确保 bookData 已解析
 * 保证 bookData 永不为空(失败时生成占位章节), 避免阅读器回退 demo 内容
 */
/** 是否占位章节(解析失败生成的缓存, 需要重新解析) */
function isPlaceholderChapter(it: ShelfItem): boolean {
  const bd = it.bookData;
  if (bd === null || bd.length === 0 || bd[0].pages.length === 0) {
    return false;
  }
  return bd[0].pages[0].type === ReaderPageType.RICH && bd[0].pages[0].filePath.length === 0;
}

export async function ensureBookData(it: ShelfItem): Promise<void> {
  if (it.bookData !== null && it.bookData.length > 0 && !isPlaceholderChapter(it)) {
    hilog.info(DOMAIN, TAG, 'ensureBookData already loaded id=%{public}s pages=%{public}d',
      it.id, it.bookData[0].pages.length);
    return;
  }
  hilog.info(DOMAIN, TAG, 'ensureBookData start id=%{public}s fmt=%{public}s sandbox=%{public}s',
    it.id, it.fileFormat, it.sandboxPath);
  // 无有效文件信息 -> 占位章节
  if (it.sandboxPath.length === 0 || it.fileFormat.length === 0) {
    hilog.warn(DOMAIN, TAG, 'ensureBookData invalid file info -> placeholder');
    it.bookData = [placeholderChapter(it.title)];
    it.initLoaded = true;
    localBookStore.updateItem(it);
    return;
  }
  try {
    const fmt = it.fileFormat.toLowerCase();
    if (fmt === 'txt' || fmt === '.txt') {
      const ch = parseTxt(it.sandboxPath, it.title);
      it.bookData = [ch];
      it.chapters = [new ShelfChapter('正文', ch.pages.length)];
    } else if (fmt === 'epub' || fmt === '.epub') {
      const dir = it.sandboxPath.substring(0, it.sandboxPath.lastIndexOf('.')) + '_epub';
      const ch = await parseEpub(it.sandboxPath, dir, it.title);
      it.bookData = [ch];
      it.chapters = [new ShelfChapter('正文', ch.pages.length)];
      hilog.info(DOMAIN, TAG, 'ensureBookData epub pages=%{public}d dirExist=%{public}s firstPath=%{public}s',
        ch.pages.length, fs.accessSync(dir) ? 'y' : 'n',
        ch.pages.length > 0 ? ch.pages[0].filePath : '');
      // 补封面(恢复后 cover 为 Resource 时首次解析)
      if (typeof it.cover !== 'string') {
        const coverPath = extractEpubCover(dir);
        if (coverPath.length > 0) {
          it.cover = 'file://' + coverPath;
        }
      }
    } else {
      // 未知格式 -> 占位章节
      it.bookData = [placeholderChapter(it.title)];
    }
    it.initLoaded = true;
    localBookStore.updateItem(it);
  } catch (e) {
    const err = e as BusinessError;
    hilog.error(DOMAIN, TAG, 'ensureBookData failed code=%{public}s msg=%{public}s',
      err.code, err.message);
    // 解析失败 -> 占位章节(不显示 demo 内容)
    it.bookData = [placeholderChapter(it.title)];
    it.initLoaded = true;
    localBookStore.updateItem(it);
  }
}

/** 解析失败/无效文件的占位说明章节 */
function placeholderChapter(title: string): ReaderChapter {
  const html = '<html><head><meta name="viewport" content="width=device-width,initial-scale=1.0">' +
    '<style>body{font-family:sans-serif;padding:24px;color:#333;line-height:1.8}</style></head>' +
    '<body><h3>' + title + '</h3><p>（该文件暂无法解析或已失效，请重新导入）</p></body></html>';
  return new ReaderChapter(1, title,
    [new ReaderPageItem(ReaderPageType.RICH, 0, '', '', html, '', '')]);
}

/** 递归删除目录及其内容 */
function deleteDirRecursive(dir: string): void {
  if (!fs.accessSync(dir)) {
    return;
  }
  try {
    const names: string[] = fs.listFileSync(dir);
    for (let i = 0; i < names.length; i++) {
      const p = dir + '/' + names[i];
      try {
        if (fs.statSync(p).isDirectory()) {
          deleteDirRecursive(p);
        } else {
          fs.unlinkSync(p);
        }
      } catch (e) {
        // 忽略单个失败
      }
    }
    fs.rmdirSync(dir);
  } catch (e) {
    // 忽略
  }
}

/**
 * 删除已导入的书: 沙箱文件 + 元信息记录 + store 移除
 */
export function removeImported(context: common.Context, it: ShelfItem): void {
  // 1. 删除原文件(.txt/.epub)
  if (it.sandboxPath.length > 0) {
    try {
      fs.unlinkSync(it.sandboxPath);
    } catch (e) {
      hilog.warn(DOMAIN, TAG, 'remove unlink fail %{public}s', it.sandboxPath);
    }
    // 2. 删除 EPUB 解压目录
    const fmt = it.fileFormat.toLowerCase();
    if (fmt === 'epub' || fmt === '.epub') {
      const dir = it.sandboxPath.substring(0, it.sandboxPath.lastIndexOf('.')) + '_epub';
      deleteDirRecursive(dir);
    }
  }
  // 3. 删除独立封面文件并清元信息
  const arr = readMeta(context);
  const out: ImportedMeta[] = [];
  for (let i = 0; i < arr.length; i++) {
    if (arr[i].id === it.id) {
      if (arr[i].coverPath !== undefined && arr[i].coverPath.length > 0) {
        try {
          fs.unlinkSync(arr[i].coverPath);
        } catch (e) {
          // 忽略
        }
      }
    } else {
      out.push(arr[i]);
    }
  }
  writeMeta(context, out);
  // 4. store 移除(触发书架刷新)
  localBookStore.removeItem(it.id);
  hilog.info(DOMAIN, TAG, 'removed %{public}s', it.id);
}
