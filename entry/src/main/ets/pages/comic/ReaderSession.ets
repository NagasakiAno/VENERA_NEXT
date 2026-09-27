/**
 * 全局阅读器会话
 *
 * 阅读器必须挂在窗口根层(Index 外层 Stack)才能全屏:
 * 发现/分类/搜索页的 ComicDetailPage 深藏在 TabContent 或内容区(横屏还有
 * sidebar + 顶栏 padding + maxWidth 约束)内, 在其中就地叠放 ReaderPage
 * 会被父级布局裁剪, 平板 UI 下阅读器只占内容区一块, 无法全屏。
 * 因此打开章节时不再就地叠放阅读器, 而是把会话发布到 AppStorage,
 * 由 Index 在窗口根层统一挂载 ReaderPage, 覆盖整个窗口。
 */
import { ReaderChapter } from '../../model/ReaderModel';
import { image } from '@kit.ImageKit';

/** AppStorage key: 阅读器可见性 */
const KEY_VISIBLE = 'globalReaderVisible';
/** AppStorage key: 当前阅读会话(换章时整体替换新对象以触发刷新) */
const KEY_SESSION = 'globalReaderSession';

/** 一次阅读会话: 章节数据 + 按页加载/切章/进度/关闭回调 */
export class ReaderSession {
  /** 章节(换章时替换为新对象, ReaderPage 的 @Watch 会重置页状态) */
  chapter: ReaderChapter | null = null;
  /** 是否存在上一/下一章(控制切章按钮显隐) */
  hasPrev: boolean = false;
  hasNext: boolean = false;
  /** 打开时跳到的页码(0 基), 用于续读 */
  startPage: number = 0;
  /** 网络章节按页加载器(本地书路径用默认空实现) */
  loader: (index: number) => Promise<image.PixelMap | null> = async () => null;
  /** 请求切章: delta = -1 上一话 / 1 下一话; 返回是否切换成功 */
  switcher: (delta: number) => Promise<boolean> = async () => false;
  /** 页码变化回调(用于记录阅读进度) */
  onProgress: (page: number, total: number) => void = () => {};
  /** 阅读器关闭回调(释放图片缓存/刷新详情页进度显示) */
  onClose: () => void = () => {};

  /** 发布会话并显示全局阅读器 */
  static publish(s: ReaderSession): void {
    AppStorage.setOrCreate<ReaderSession>(KEY_SESSION, s);
    AppStorage.setOrCreate<boolean>(KEY_VISIBLE, true);
  }

  /** 隐藏全局阅读器 */
  static hide(): void {
    AppStorage.setOrCreate<boolean>(KEY_VISIBLE, false);
  }
}
