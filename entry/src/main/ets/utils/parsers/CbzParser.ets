/**
 * VeneraNext CBZ/ZIP 漫画解析器
 * CBZ = Comic Book Zip = ZIP 文件包含图片(jpg/png/webp/gif/bmp)
 * 1. zlib 解压 cbz(zip) 到沙箱目录
 * 2. 递归扫描解压目录中的图片文件
 * 3. 按文件名自然排序(page1 < page2 < page10, 而非字典序 page1 < page10 < page2)
 * 4. 每张图片 = 一个 IMAGE 页, 第一张图 = 封面
 * 容错: 无图片时返回占位章节
 */
import { fileIo as fs } from '@kit.CoreFileKit';
import { zlib } from '@kit.BasicServicesKit';
import { ReaderChapter, ReaderPageItem, ReaderPageType } from '../../model/ReaderModel';

const TAG = 'CbzParser';

/** 支持的图片扩展名 */
const IMG_EXTS: string[] = ['.jpg', '.jpeg', '.png', '.webp', '.gif', '.bmp'];

function isImageFile(name: string): boolean {
  const lower = name.toLowerCase();
  for (let i = 0; i < IMG_EXTS.length; i++) {
    if (lower.endsWith(IMG_EXTS[i])) {
      return true;
    }
  }
  return false;
}

/**
 * 自然排序比较: page1.jpg < page2.jpg < page10.jpg
 * 将字符串拆为数字段与非数字段交替比较
 */
function naturalCompare(a: string, b: string): number {
  let i = 0;
  let j = 0;
  while (i < a.length && j < b.length) {
    // 跳过相同前缀字符
    if (a[i] === b[j]) {
      i++;
      j++;
      continue;
    }
    // 尝试提取数字段
    const aNum = extractNumber(a, i);
    const bNum = extractNumber(b, j);
    if (aNum !== null && bNum !== null) {
      if (aNum.value !== bNum.value) {
        return aNum.value - bNum.value;
      }
      i = aNum.end;
      j = bNum.end;
      continue;
    }
    // 非数字段按字典序
    return a.charCodeAt(i) - b.charCodeAt(j);
  }
  return a.length - b.length;
}

class NumberSegment {
  value: number = 0;
  end: number = 0;
}

function extractNumber(s: string, start: number): NumberSegment | null {
  if (start >= s.length || s[start] < '0' || s[start] > '9') {
    return null;
  }
  let end = start;
  while (end < s.length && s[end] >= '0' && s[end] <= '9') {
    end++;
  }
  const seg = new NumberSegment();
  seg.value = parseInt(s.substring(start, end));
  seg.end = end;
  return seg;
}

/** 递归扫描目录中的图片文件, 返回完整路径列表 */
function collectImagePaths(dir: string, out: string[], depth: number): void {
  if (depth > 5) {
    return;
  }
  let names: string[] = [];
  try {
    names = fs.listFileSync(dir);
  } catch (e) {
    return;
  }
  // 先收集当前目录的图片, 再递归子目录
  const imgs: string[] = [];
  const dirs: string[] = [];
  for (let i = 0; i < names.length; i++) {
    const p = dir + '/' + names[i];
    if (isImageFile(names[i])) {
      imgs.push(p);
    } else {
      try {
        if (fs.statSync(p).isDirectory()) {
          dirs.push(p);
        }
      } catch (e) {
        // 忽略
      }
    }
  }
  // 当前目录图片按自然排序加入
  imgs.sort(naturalCompare);
  for (let i = 0; i < imgs.length; i++) {
    out.push(imgs[i]);
  }
  // 递归子目录
  dirs.sort(naturalCompare);
  for (let i = 0; i < dirs.length; i++) {
    collectImagePaths(dirs[i], out, depth + 1);
  }
}

/**
 * 解析 CBZ 为图片章节
 * @param bookPath 沙箱内 cbz 文件路径
 * @param unzipDir 解压输出目录(已解压则跳过)
 * @param title 书名
 */
export async function parseCbz(bookPath: string, unzipDir: string, title: string): Promise<ReaderChapter> {
  // 1. 解压(已解压则跳过)
  if (!fs.accessSync(unzipDir)) {
    fs.mkdirSync(unzipDir);
    await zlib.decompressFile(bookPath, unzipDir);
  }

  // 2. 递归扫描图片
  const imagePaths: string[] = [];
  collectImagePaths(unzipDir, imagePaths, 0);

  // 3. 构造章节
  if (imagePaths.length === 0) {
    // 无图片 -> 占位章节
    const pages: ReaderPageItem[] = [];
    pages.push(new ReaderPageItem(ReaderPageType.RICH, 0, '', '',
      '<html><body><p>（CBZ 解析失败或无图片）</p></body></html>', '', ''));
    return new ReaderChapter(1, title, pages);
  }

  const pages: ReaderPageItem[] = [];
  for (let i = 0; i < imagePaths.length; i++) {
    pages.push(new ReaderPageItem(ReaderPageType.IMAGE, i, '',
      'file://' + imagePaths[i], '', '', ''));
  }
  return new ReaderChapter(1, title, pages);
}

/**
 * 提取 CBZ 封面图沙箱路径(第一张图片)
 * @returns 封面图片绝对路径; 无则 ''
 */
export function extractCbzCover(unzipDir: string): string {
  if (!fs.accessSync(unzipDir)) {
    return '';
  }
  const imagePaths: string[] = [];
  collectImagePaths(unzipDir, imagePaths, 0);
  return imagePaths.length > 0 ? imagePaths[0] : '';
}
