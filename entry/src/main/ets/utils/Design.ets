/**
 * VeneraNext ArkUI 设计令牌 —— 严格对齐 harmonyos-comic-reader/pages 原型
 * 颜色一律使用 #ARGB 面值(避免 sys.color 编译解析问题)
 */

// ===== 主色 (HarmonyOS Blue) =====
export const PRIMARY: string = '#FF145CDE';
export const PRIMARY_50: string = '#FFEBF2FF';
export const PRIMARY_100: string = '#FFD6E4FF';
export const PRIMARY_200: string = '#FFADCCFF';
export const PRIMARY_300: string = '#FF7AA8FF';
export const PRIMARY_400: string = '#FF4D8BFF';
export const PRIMARY_600: string = '#FF0A4FBF';
export const PRIMARY_700: string = '#FF073D94';
export const PRIMARY_FG: string = '#FFFFFFFF';

// ===== 中性色 =====
export const GRAY_50: string = '#FFFAFAFA';
export const GRAY_100: string = '#FFF1F3F5';
export const GRAY_200: string = '#FFE8EAED';
export const GRAY_300: string = '#FFD8DCE0';
export const GRAY_400: string = '#FFB8BCC2';
export const GRAY_500: string = '#FF909399';
export const GRAY_600: string = '#FF6B6E73';
export const GRAY_700: string = '#FF4A4D52';
export const GRAY_800: string = '#FF2C2E33';
export const GRAY_900: string = '#FF182431';

// ===== 语义别名 =====
export const BG: string = '#FFF1F3F5';      // 页面背景
export const FG: string = '#FF182431';       // 前景文字
export const CARD: string = '#FFFFFFFF';     // 卡片背景
export const CARD_FG: string = '#FF182431';  // 卡片文字
export const MUTED: string = '#FFF1F3F5';
export const MUTED_FG: string = '#FF909399';
export const BORDER: string = '#FFE8EAED';   // 分割线/边框
export const INPUT_BG: string = '#FFE8EAED'; // 输入框

// ===== 语义状态 =====
export const SUCCESS: string = '#FF52C41A';
export const WARNING: string = '#FFFAAD14';
export const ERROR: string = '#FFE8455E';
export const INFO: string = '#FF145CDE';

// ===== 圆角 =====
export const RADIUS_SM: number = 4;
export const RADIUS_MD: number = 8;
export const RADIUS_LG: number = 12;
export const RADIUS_XL: number = 16;

// ===== 间距 (8pt 网格) =====
export const SPACE_1: number = 4;
export const SPACE_2: number = 8;
export const SPACE_3: number = 12;
export const SPACE_4: number = 16;
export const SPACE_5: number = 24;
export const SPACE_6: number = 32;

// ===== 字号 =====
export const FS_DISPLAY: number = 24;
export const FS_TITLE: number = 20;   // 顶部标题
export const FS_SECTION: number = 17; // 区块标题
export const FS_BODY: number = 15;
export const FS_CAPTION: number = 13;
export const FS_SMALL: number = 12;