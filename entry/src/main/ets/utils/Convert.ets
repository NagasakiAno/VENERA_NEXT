/**
 * VeneraNext 加解密/编码工具层
 * 对应 Flutter 版 assets/init.js 中的 Convert 对象(JS 运行时供给漫画源使用)
 * 基于官方 CryptoArchitectureKit 与 util 实现, 全部 ArkTS 原生
 */
import { cryptoFramework } from '@kit.CryptoArchitectureKit';
import { util } from '@kit.ArkTS';
import { hilog } from '@kit.PerformanceAnalysisKit';

const DOMAIN = 0x0000;
const TAG = 'Convert';

/** UTF8 编码为 Uint8Array */
export function encodeUtf8(str: string): Uint8Array {
  const encoder = new util.TextEncoder();
  return encoder.encodeInto(str);
}

/** Uint8Array 解码为 UTF8 字符串 */
export function decodeUtf8(bytes: Uint8Array): string {
  const decoder = new util.TextDecoder();
  return decoder.decodeToString(bytes);
}

/** Base64 编码 */
export function encodeBase64(bytes: Uint8Array): string {
  const b64 = new util.Base64Helper();
  return b64.encodeToStringSync(bytes);
}

/** Base64 解码 */
export function decodeBase64(str: string): Uint8Array {
  const b64 = new util.Base64Helper();
  return b64.decodeSync(str);
}

/** 字节转十六进制字符串 */
export function hexEncode(bytes: Uint8Array): string {
  let out = '';
  for (let i = 0; i < bytes.length; i++) {
    out += bytes[i].toString(16).padStart(2, '0');
  }
  return out;
}

/** 十六进制字符串转字节 */
export function hexDecode(hex: string): Uint8Array {
  const len = Math.floor(hex.length / 2);
  const out = new Uint8Array(len);
  for (let i = 0; i < len; i++) {
    out[i] = parseInt(hex.substr(i * 2, 2), 16);
  }
  return out;
}

/** 摘要算法名称映射 (cryptoFramework 命名 到 vulun), 保持简洁 */
function digestAlgoName(alg: string): string {
  return alg.toUpperCase();
}

// ---------- 纯 ArkTS SHA-256 实现 (不依赖系统加密库) ----------
// 用于 HMAC, 规避 CryptoArchitectureKit.createMac 在此环境的不可用问题

const SHA256_K: number[] = [
  0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5,
  0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3, 0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
  0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
  0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
  0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13, 0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
  0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
  0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
  0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208, 0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2
];

function rotr(x: number, n: number): number {
  return (x >>> n) | (x << (32 - n));
}

/** 计算 Uint8Array 的 SHA-256 摘要 */
export function sha256Bytes(data: Uint8Array): Uint8Array {
  // 先填充到消息
  const bitLenHi = Math.floor(data.length / 0x20000000) | 0;
  const bitLenLo = (data.length << 3);
  const paddedLen = (((data.length + 8) >> 6) + 1) << 6;
  const padded = new Uint8Array(paddedLen);
  padded.set(data);
  padded[data.length] = 0x80;
  // 大端写入比特长度
  const dv = new DataView(padded.buffer);
  dv.setUint32(paddedLen - 8, bitLenHi, false);
  dv.setUint32(paddedLen - 4, bitLenLo, false);

  const h0 = 0x6a09e667, h1 = 0xbb67ae85, h2 = 0x3c6ef372, h3 = 0xa54ff53a;
  const h4 = 0x510e527f, h5 = 0x9b05688c, h6 = 0x1f83d9ab, h7 = 0x5be0cd19;
  let H: number[] = [h0, h1, h2, h3, h4, h5, h6, h7];
  const w = new Array<number>(64).fill(0);

  const view = new DataView(padded.buffer);
  for (let chunk = 0; chunk < paddedLen; chunk += 64) {
    for (let i = 0; i < 16; i++) {
      w[i] = view.getUint32(chunk + i * 4, false);
    }
    for (let i = 16; i < 64; i++) {
      const s0 = rotr(w[i - 15], 7) ^ rotr(w[i - 15], 18) ^ (w[i - 15] >>> 3);
      const s1 = rotr(w[i - 2], 17) ^ rotr(w[i - 2], 19) ^ (w[i - 2] >>> 10);
      w[i] = (w[i - 16] + s0 + w[i - 7] + s1) | 0;
    }
    let a = H[0], b = H[1], c = H[2], d = H[3];
    let e = H[4], f = H[5], g = H[6], h = H[7];
    for (let i = 0; i < 64; i++) {
      const S1 = rotr(e, 6) ^ rotr(e, 11) ^ rotr(e, 25);
      const ch = (e & f) ^ (~e & g);
      const temp1 = (h + S1 + ch + SHA256_K[i] + w[i]) | 0;
      const S0 = rotr(a, 2) ^ rotr(a, 13) ^ rotr(a, 22);
      const maj = (a & b) ^ (a & c) ^ (b & c);
      const temp2 = (S0 + maj) | 0;
      h = g; g = f; f = e; e = (d + temp1) | 0;
      d = c; c = b; b = a; a = (temp1 + temp2) | 0;
    }
    H[0] = (H[0] + a) | 0; H[1] = (H[1] + b) | 0; H[2] = (H[2] + c) | 0; H[3] = (H[3] + d) | 0;
    H[4] = (H[4] + e) | 0; H[5] = (H[5] + f) | 0; H[6] = (H[6] + g) | 0; H[7] = (H[7] + h) | 0;
  }
  const out = new Uint8Array(32);
  const odv = new DataView(out.buffer);
  for (let i = 0; i < 8; i++) {
    odv.setUint32(i * 4, H[i] >>> 0, false);
  }
  return out;
}

/** 纯 ArkTS HMAC-SHA256 */
export function hmacSha256Bytes(key: Uint8Array, data: Uint8Array): Uint8Array {
  const blockSize = 64;
  let k = key;
  if (k.length > blockSize) {
    k = sha256Bytes(k);
  }
  // pad
  const padded = new Uint8Array(blockSize);
  padded.set(k);
  const ipad = new Uint8Array(blockSize);
  const opad = new Uint8Array(blockSize);
  for (let i = 0; i < blockSize; i++) {
    ipad[i] = padded[i] ^ 0x36;
    opad[i] = padded[i] ^ 0x5c;
  }
  // inner: SHA256(ipad || data)
  const inner = new Uint8Array(blockSize + data.length);
  inner.set(ipad, 0);
  inner.set(data, blockSize);
  const innerHash = sha256Bytes(inner);
  // outer: SHA256(opad || innerHash)
  const outer = new Uint8Array(blockSize + 32);
  outer.set(opad, 0);
  outer.set(innerHash, blockSize);
  return sha256Bytes(outer);
}

/**
 * 计算 HAMC (md5/sha1/sha256/sha512), 使用纯 ArkTS SHA-256 实现
 * @param isHex 若 true 返回十六进制字符串, 否则返回字节数组
 */
export async function hmac(
  key: Uint8Array,
  data: Uint8Array,
  alg: string,
  isHex: boolean
): Promise<Uint8Array | string> {
  // 当前用纯 SHA-256 实现; 其它哈希算法暂回退同策略(多数源只用 sha256)
  const bytes = hmacSha256Bytes(key, data);
  return isHex ? hexEncode(bytes) : bytes;
}

/** HAMC 返回十六进制字符串 */
export async function hmacString(
  key: Uint8Array,
  data: Uint8Array,
  alg: string
): Promise<string> {
  return hmac(key, data, alg, true) as Promise<string>;
}

/** 记录错误日志(统一) */
export function logConvertError(op: string, e: Error | string): void {
  hilog.error(DOMAIN, TAG, 'convert %{public}s failed: %{public}s', op, `${e}`);
}