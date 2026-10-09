/**
 * 简易 ZIP 文件写入器 (STORE 模式, 无压缩)
 * 用于创建 CBZ (Comic Book Zip) 文件
 *
 * ZIP 格式结构:
 *   [Local File Header + File Data] * N
 *   [Central Directory Header] * N
 *   [End of Central Directory Record]
 */
import { fileIo as fs } from '@kit.CoreFileKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { util } from '@kit.ArkTS';

const DOMAIN = 0x0000;
const TAG = 'ZipWriter';

/** ZIP 条目输入 */
export interface ZipEntryInput {
  name: string;
  data: Uint8Array;
}

/** CRC32 计算表 */
const CRC_TABLE: Uint32Array = (() => {
  const table = new Uint32Array(256);
  for (let i = 0; i < 256; i++) {
    let crc = i;
    for (let j = 0; j < 8; j++) {
      if (crc & 1) {
        crc = (crc >>> 1) ^ 0xEDB88320;
      } else {
        crc = crc >>> 1;
      }
    }
    table[i] = crc;
  }
  return table;
})();

/** 计算 Uint8Array 的 CRC32 */
function crc32(data: Uint8Array): number {
  let crc = 0xFFFFFFFF;
  for (let i = 0; i < data.length; i++) {
    crc = (crc >>> 8) ^ CRC_TABLE[(crc ^ data[i]) & 0xFF];
  }
  return (crc ^ 0xFFFFFFFF) >>> 0;
}

/** 将 Uint16 写入 DataView (小端) */
function writeUint16LE(view: DataView, offset: number, value: number): void {
  view.setUint16(offset, value & 0xFFFF, true);
}

/** 将 Uint32 写入 DataView (小端) */
function writeUint32LE(view: DataView, offset: number, value: number): void {
  view.setUint32(offset, value >>> 0, true);
}

/** 将字符串编码为 UTF-8 字节 */
function encodeUtf8(str: string): Uint8Array {
  const encoder = util.TextEncoder.create('utf-8');
  return encoder.encodeInto(str);
}

/** ZIP 文件条目内部信息 */
interface ZipEntry {
  fileName: string;
  fileData: Uint8Array;
  crc32Value: number;
  localHeaderOffset: number;
}

/**
 * 创建 ZIP 文件 (STORE 模式)
 * @param entries 文件名 -> 文件数据的映射数组
 * @param outputPath 输出 ZIP 文件路径
 */
export async function createZipFile(
  entries: ZipEntryInput[],
  outputPath: string
): Promise<void> {
  const zipEntries: ZipEntry[] = [];
  let currentOffset = 0;

  // 1. 计算各条目大小和偏移
  for (let i = 0; i < entries.length; i++) {
    const nameBytes = encodeUtf8(entries[i].name);
    const data = entries[i].data;
    const crc = crc32(data);
    const localHeaderSize = 30 + nameBytes.length;

    zipEntries.push({
      fileName: entries[i].name,
      fileData: data,
      crc32Value: crc,
      localHeaderOffset: currentOffset
    });

    currentOffset += localHeaderSize + data.length;
  }

  // 2. 计算中央目录大小
  let centralDirSize = 0;
  for (let i = 0; i < zipEntries.length; i++) {
    const nameBytes = encodeUtf8(zipEntries[i].fileName);
    centralDirSize += 46 + nameBytes.length;
  }

  // 3. 计算总文件大小
  const endRecordSize = 22;
  const totalSize = currentOffset + centralDirSize + endRecordSize;

  // 4. 构建完整 ZIP 文件字节
  const buffer = new ArrayBuffer(totalSize);
  const view = new DataView(buffer);
  const bytes = new Uint8Array(buffer);

  // 写入 Local File Headers + File Data
  for (let i = 0; i < zipEntries.length; i++) {
    const entry = zipEntries[i];
    const nameBytes = encodeUtf8(entry.fileName);
    const offset = entry.localHeaderOffset;

    // Local File Header (30 bytes)
    writeUint32LE(view, offset, 0x04034b50);       // signature
    writeUint16LE(view, offset + 4, 20);            // version needed
    writeUint16LE(view, offset + 6, 0);             // flags
    writeUint16LE(view, offset + 8, 0);             // compression method (STORE)
    writeUint16LE(view, offset + 10, 0);            // mod time
    writeUint16LE(view, offset + 12, 0);            // mod date
    writeUint32LE(view, offset + 14, entry.crc32Value); // crc-32
    writeUint32LE(view, offset + 18, entry.fileData.length); // compressed size
    writeUint32LE(view, offset + 22, entry.fileData.length); // uncompressed size
    writeUint16LE(view, offset + 26, nameBytes.length);      // filename length
    writeUint16LE(view, offset + 28, 0);            // extra field length

    // Filename
    bytes.set(nameBytes, offset + 30);

    // File data
    bytes.set(entry.fileData, offset + 30 + nameBytes.length);
  }

  // 写入 Central Directory Headers
  let cdOffset = currentOffset;
  for (let i = 0; i < zipEntries.length; i++) {
    const entry = zipEntries[i];
    const nameBytes = encodeUtf8(entry.fileName);

    // Central Directory Header (46 bytes)
    writeUint32LE(view, cdOffset, 0x02014b50);      // signature
    writeUint16LE(view, cdOffset + 4, 20);           // version made by
    writeUint16LE(view, cdOffset + 6, 20);           // version needed
    writeUint16LE(view, cdOffset + 8, 0);            // flags
    writeUint16LE(view, cdOffset + 10, 0);           // compression method (STORE)
    writeUint16LE(view, cdOffset + 12, 0);           // mod time
    writeUint16LE(view, cdOffset + 14, 0);           // mod date
    writeUint32LE(view, cdOffset + 16, entry.crc32Value); // crc-32
    writeUint32LE(view, cdOffset + 20, entry.fileData.length); // compressed size
    writeUint32LE(view, cdOffset + 24, entry.fileData.length); // uncompressed size
    writeUint16LE(view, cdOffset + 28, nameBytes.length);      // filename length
    writeUint16LE(view, cdOffset + 30, 0);           // extra field length
    writeUint16LE(view, cdOffset + 32, 0);           // comment length
    writeUint16LE(view, cdOffset + 34, 0);           // disk number start
    writeUint16LE(view, cdOffset + 36, 0);           // internal attrs
    writeUint32LE(view, cdOffset + 38, 0);           // external attrs
    writeUint32LE(view, cdOffset + 42, entry.localHeaderOffset); // local header offset

    // Filename
    bytes.set(nameBytes, cdOffset + 46);

    cdOffset += 46 + nameBytes.length;
  }

  // 写入 End of Central Directory Record (22 bytes)
  writeUint32LE(view, cdOffset, 0x06054b50);        // signature
  writeUint16LE(view, cdOffset + 4, 0);              // disk number
  writeUint16LE(view, cdOffset + 6, 0);              // disk with central dir
  writeUint16LE(view, cdOffset + 8, zipEntries.length); // entries on this disk
  writeUint16LE(view, cdOffset + 10, zipEntries.length); // total entries
  writeUint32LE(view, cdOffset + 12, centralDirSize);   // central dir size
  writeUint32LE(view, cdOffset + 16, currentOffset);    // central dir offset
  writeUint16LE(view, cdOffset + 20, 0);                // comment length

  // 5. 写入文件
  const file = fs.openSync(outputPath, fs.OpenMode.CREATE | fs.OpenMode.WRITE_ONLY | fs.OpenMode.TRUNC);
  fs.writeSync(file.fd, buffer);
  fs.closeSync(file);

  hilog.info(DOMAIN, TAG, 'ZIP created: %{public}d entries, %{public}d bytes', zipEntries.length, totalSize);
}
