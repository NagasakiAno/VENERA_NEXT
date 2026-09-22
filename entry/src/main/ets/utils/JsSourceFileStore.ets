/**
 * VeneraNext JS 源文件存储
 * comic_source/*.js 源脚本 + {key}.data 源数据, 位于 filesDir
 */
import { fileIo as fs } from '@kit.CoreFileKit';
import { util } from '@kit.ArkTS';
import { common } from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';

const DOMAIN = 0x0000;
const TAG = 'JsSourceFileStore';
const DIR = 'comic_source';

export class JsSourceFileStore {
  private context: common.Context;
  private root: string = '';

  constructor(context: common.Context) {
    this.context = context;
    this.root = context.filesDir + '/' + DIR;
    if (!fs.accessSync(this.root)) {
      fs.mkdirSync(this.root);
    }
  }

  /** 源脚本目录 */
  sourceDir(): string {
    return this.root;
  }

  /** 写入源脚本 */
  writeJs(fileName: string, text: string): void {
    const p = this.root + '/' + fileName;
    const f = fs.openSync(p, fs.OpenMode.READ_WRITE | fs.OpenMode.CREATE | fs.OpenMode.TRUNC);
    fs.writeSync(f.fd, text);
    fs.closeSync(f);
  }

  /** 读取源脚本 */
  readJs(fileName: string): string {
    const p = this.root + '/' + fileName;
    if (!fs.accessSync(p)) {
      return '';
    }
    return this.readTextFile(p);
  }

  /** 删除源脚本 */
  deleteJs(fileName: string): void {
    const p = this.root + '/' + fileName;
    if (fs.accessSync(p)) {
      fs.unlinkSync(p);
    }
  }

  /** 列出所有 .js 源脚本名 */
  listJs(): string[] {
    const out: string[] = [];
    let names: string[] = [];
    try {
      names = fs.listFileSync(this.root);
    } catch (e) {
      return out;
    }
    for (let i = 0; i < names.length; i++) {
      if (names[i].toLowerCase().endsWith('.js')) {
        out.push(names[i]);
      }
    }
    return out;
  }

  /** 源是否有 .data 文件 */
  hasData(key: string): boolean {
    return fs.accessSync(this.root + '/' + key + '.data');
  }

  /** 读取源 data(JSON 文本) */
  readData(key: string): string {
    return this.readTextFile(this.root + '/' + key + '.data');
  }

  /** 写入源 data(JSON 字符串), 与 Appdata/源兼容 */
  writeData(key: string, json: string): void {
    const p = this.root + '/' + key + '.data';
    const f = fs.openSync(p, fs.OpenMode.READ_WRITE | fs.OpenMode.CREATE | fs.OpenMode.TRUNC);
    fs.writeSync(f.fd, json);
    fs.closeSync(f);
  }

  /** 删除源 data */
  deleteData(key: string): void {
    const p = this.root + '/' + key + '.data';
    if (fs.accessSync(p)) {
      fs.unlinkSync(p);
    }
  }

  private readTextFile(p: string): string {
    try {
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
}