/**
 * VeneraNext TXT 解析器
 * 读取本地 UTF-8 文本, 按固定字符数分页为阅读器 TEXT 页
 */
import { fileIo as fs } from '@kit.CoreFileKit';
import { util } from '@kit.ArkTS';
import { ReaderChapter, ReaderPageItem, ReaderPageType } from '../../model/ReaderModel';

/** 每页约多少字符(中文按字符) */
const CHARS_PER_PAGE = 800;

/** 读取文件为 UTF-8 字符串 */
function readText(path: string): string {
  const f = fs.openSync(path, fs.OpenMode.READ_ONLY);
  try {
    const stat = fs.statSync(f.fd);
    const buf = new ArrayBuffer(stat.size);
    fs.readSync(f.fd, buf);
    const decoder = util.TextDecoder.create('utf-8');
    return decoder.decodeToString(new Uint8Array(buf));
  } finally {
    fs.closeSync(f);
  }
}

/**
 * 解析 TXT 为单个正文章节(多页)
 * @param path 沙箱内 txt 路径
 * @param title 书名
 */
export function parseTxt(path: string, title: string): ReaderChapter {
  const text = readText(path);
  const pages: ReaderPageItem[] = [];
  let idx = 0;
  for (let i = 0; i < text.length; i += CHARS_PER_PAGE) {
    const end = Math.min(i + CHARS_PER_PAGE, text.length);
    pages.push(new ReaderPageItem(ReaderPageType.TEXT, idx, text.substring(i, end), ''));
    idx++;
  }
  if (pages.length === 0) {
    pages.push(new ReaderPageItem(ReaderPageType.TEXT, 0, '（空文件）', ''));
  }
  return new ReaderChapter(1, title, pages);
}
