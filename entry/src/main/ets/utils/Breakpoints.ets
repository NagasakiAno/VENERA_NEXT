/**
 * VeneraNext 响应式断点工具
 * 判定宽屏形态的核心逻辑: 按屏幕长宽比(aspect ratio)切换
 *   - 宽 > 高 (横屏/平板横放) → 宽屏形态(平板分栏 UI)
 *   - 宽 <= 高 (竖屏/手机/折叠屏展开) → 窄屏形态(手机 UI)
 * 此方案修复了 PURA X 展开内屏误判为平板、MatePad 竖屏误判为平板的问题。
 */
import { deviceInfo } from '@kit.BasicServicesKit';

/** 窗口宽度(vp) */
export const WIN_WVP: string = 'winWidthVp';
/** 窗口高度(vp) */
export const WIN_HVP: string = 'winHeightVp';
/** 是否宽屏形态(折叠屏展开/平板/横屏) */
export const IS_WIDE: string = 'isWide';
/** 是否折叠设备已展开 */
export const FOLD_EXPANDED: string = 'foldExpanded';
/** 宽度断点字符串(供 GridRow/网格列数 使用) */
export const WIDTH_BP: string = 'widthBp';
/** 是否 PC(2in1) 设备 */
export const IS_PC: string = 'isPc';

/** 初始化默认手机形态 */
export function initBreakpoints(): void {
  AppStorage.setOrCreate<number>(WIN_WVP, 390);
  AppStorage.setOrCreate<number>(WIN_HVP, 844);
  AppStorage.setOrCreate<boolean>(FOLD_EXPANDED, false);
  AppStorage.setOrCreate<string>(WIDTH_BP, 'md');
  AppStorage.setOrCreate<boolean>(IS_WIDE, false);
  AppStorage.setOrCreate<boolean>(IS_PC, isPcDevice());
}

/** 是否 PC(2in1) 设备 */
export function isPcDevice(): boolean {
  try {
    return deviceInfo.deviceType === '2in1';
  } catch (e) {
    return false;
  }
}

/**
 * 设置折叠设备是否展开(由 display.foldStatusChange 驱动)
 * 注意: 折叠状态仅作信息记录, 不再影响宽屏判定(改用长宽比)
 * @param expanded true=完全展开
 */
export function setFoldStatus(expanded: boolean): void {
  AppStorage.setOrCreate<boolean>(FOLD_EXPANDED, expanded);
}

/**
 * 更新窗口尺寸并重新计算宽屏态
 * @param wvp 窗口宽(vp)
 * @param hvp 窗口高(vp)
 */
export function updateWindowSize(wvp: number, hvp: number): void {
  const w = Math.max(1, wvp);
  const h = Math.max(1, hvp);
  AppStorage.setOrCreate<number>(WIN_WVP, Math.round(w));
  AppStorage.setOrCreate<number>(WIN_HVP, Math.round(h));
  // 横向宽度断点
  let bp: string;
  if (w < 320) { bp = 'sm'; }
  else if (w < 600) { bp = 'md'; }
  else if (w < 840) { bp = 'lg'; }
  else { bp = 'xl'; }
  AppStorage.setOrCreate<string>(WIDTH_BP, bp);
  recomputeWide();
}

/** 依据屏幕长宽比重算宽屏态: 宽>高 → 平板分栏, 宽<=高 → 手机形态 */
function recomputeWide(): void {
  const w = AppStorage.get<number>(WIN_WVP) ?? 390;
  const h = AppStorage.get<number>(WIN_HVP) ?? 844;
  const pc = AppStorage.get<boolean>(IS_PC) ?? false;
  // PC 端优先使用平板横屏布局(窗口比例不满足也保持分栏形态)
  const wide = pc || w > h;
  AppStorage.setOrCreate<boolean>(IS_WIDE, wide);
}

/** 快速读宽屏态 */
export function isWide(): boolean {
  return AppStorage.get<boolean>(IS_WIDE) ?? false;
}

/** 快速读宽度断点 */
export function widthBp(): string {
  return AppStorage.get<string>(WIDTH_BP) ?? 'md';
}