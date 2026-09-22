/**
 * VeneraNext 响应式断点工具
 * 规范来源: HarmonyOS 一次开发多端部署 + @ohos.display 折叠状态
 * 判定宽屏形态的两个维度:
 *   1. 折叠设备展开态(FoldStatus.EXPANDED) -> 平板分栏(如 Pura X 1.414:1 内屏)
 *   2. 窗口宽度断点 lg/xl(平板/横屏)
 * 折叠状态由 OH_DisplayManager(display) 提供, 比窗口宽度/高宽比更可靠,
 * 尤其适用于"宽度中等但比例矮胖"的阔折叠内屏。
 */

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

/** 初始化默认手机形态 */
export function initBreakpoints(): void {
  AppStorage.setOrCreate<number>(WIN_WVP, 390);
  AppStorage.setOrCreate<number>(WIN_HVP, 844);
  AppStorage.setOrCreate<boolean>(FOLD_EXPANDED, false);
  AppStorage.setOrCreate<string>(WIDTH_BP, 'md');
  AppStorage.setOrCreate<boolean>(IS_WIDE, false);
}

/**
 * 设置折叠设备是否展开(由 display.foldStatusChange 驱动)
 * @param expanded true=完全展开
 */
export function setFoldStatus(expanded: boolean): void {
  AppStorage.setOrCreate<boolean>(FOLD_EXPANDED, expanded);
  recomputeWide();
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

/** 依据折叠状态 + 宽度断点 重算宽屏态 */
function recomputeWide(): void {
  const folded = AppStorage.get<boolean>(FOLD_EXPANDED) ?? false;
  const bp = AppStorage.get<string>(WIDTH_BP) ?? 'md';
  const wide = folded || bp === 'lg' || bp === 'xl';
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