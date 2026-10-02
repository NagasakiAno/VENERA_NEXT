/**
 * VeneraNext 下载队列管理器
 * - 支持多任务排队下载（并发控制：同时最多1个任务）
 * - 任务状态机：pending → downloading → completed/failed/paused
 * - 进度追踪：downloadedImages/totalImages/progress
 * - JSON 持久化（filesDir/download_queue.json）
 * - listeners 订阅通知（UI 刷新）
 */
import { fileIo as fs } from '@kit.CoreFileKit';
import { common } from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';

const DOMAIN = 0x0000;
const TAG = 'DownloadQueueStore';

/** 下载统计信息 */
export interface DownloadStats {
  pending: number;
  downloading: number;
  completed: number;
  failed: number;
  paused: number;
  total: number;
}

/** 下载状态枚举 */
export enum DownloadStatus {
  PENDING = 0,
  DOWNLOADING = 1,
  COMPLETED = 2,
  FAILED = 3,
  PAUSED = 4
}

/** 下载任务 */
export class DownloadTask {
  /** 任务ID: sourceKey|comicId|epId */
  id: string = '';
  sourceKey: string = '';
  comicId: string = '';
  epId: string = '';
  /** 章节标题（展示用） */
  title: string = '';
  /** 漫画标题（展示用） */
  comicTitle: string = '';
  /** 漫画封面URL（展示用） */
  cover: string = '';
  status: DownloadStatus = DownloadStatus.PENDING;
  /** 总图片数 */
  totalImages: number = 0;
  /** 已下载图片数 */
  downloadedImages: number = 0;
  /** 进度百分比 0-100 */
  progress: number = 0;
  /** 添加时间戳 */
  addedTime: number = 0;
  /** 完成时间戳 */
  completedTime: number = 0;
  /** 错误信息 */
  errorMsg: string = '';

  constructor(id: string, sourceKey: string, comicId: string, epId: string,
    title: string, comicTitle: string, cover: string = '') {
    this.id = id;
    this.sourceKey = sourceKey;
    this.comicId = comicId;
    this.epId = epId;
    this.title = title;
    this.comicTitle = comicTitle;
    this.cover = cover;
    this.status = DownloadStatus.PENDING;
    this.totalImages = 0;
    this.downloadedImages = 0;
    this.progress = 0;
    this.addedTime = Date.now();
    this.completedTime = 0;
    this.errorMsg = '';
  }
}

/** 持久化 JSON 结构 */
interface DownloadQueuePersistData {
  tasks: DownloadTaskPersist[];
}

interface DownloadTaskPersist {
  id: string;
  sourceKey: string;
  comicId: string;
  epId: string;
  title: string;
  comicTitle: string;
  cover: string;
  status: number;
  totalImages: number;
  downloadedImages: number;
  progress: number;
  addedTime: number;
  completedTime: number;
  errorMsg: string;
}

class DownloadQueueStore {
  private tasks: DownloadTask[] = [];
  private listeners: Array<() => void> = [];
  private context: common.Context | null = null;
  private loaded: boolean = false;

  /** 初始化（传入 Context 以访问文件系统） */
  init(context: common.Context): void {
    this.context = context;
    this.load();
  }

  /** 是否已加载 */
  isLoaded(): boolean {
    return this.loaded;
  }

  /** 获取所有任务（按添加时间降序：最新的在前） */
  getAllTasks(): DownloadTask[] {
    const sorted = this.tasks.slice();
    sorted.sort((a: DownloadTask, b: DownloadTask) => b.addedTime - a.addedTime);
    return sorted;
  }

  /** 获取指定状态的任务 */
  getTasksByStatus(status: DownloadStatus): DownloadTask[] {
    const out: DownloadTask[] = [];
    for (let i = 0; i < this.tasks.length; i++) {
      if (this.tasks[i].status === status) {
        out.push(this.tasks[i]);
      }
    }
    return out;
  }

  /** 获取待下载任务（pending 状态，按添加时间升序） */
  getPendingTasks(): DownloadTask[] {
    const out: DownloadTask[] = [];
    for (let i = 0; i < this.tasks.length; i++) {
      if (this.tasks[i].status === DownloadStatus.PENDING) {
        out.push(this.tasks[i]);
      }
    }
    out.sort((a: DownloadTask, b: DownloadTask) => a.addedTime - b.addedTime);
    return out;
  }

  /** 是否有正在下载的任务 */
  hasDownloading(): boolean {
    for (let i = 0; i < this.tasks.length; i++) {
      if (this.tasks[i].status === DownloadStatus.DOWNLOADING) {
        return true;
      }
    }
    return false;
  }

  /** 添加任务（重复检查：同 id 不重复添加） */
  addTask(task: DownloadTask): boolean {
    for (let i = 0; i < this.tasks.length; i++) {
      if (this.tasks[i].id === task.id) {
        hilog.warn(DOMAIN, TAG, '任务已存在: %{public}s', task.id);
        return false;
      }
    }
    this.tasks.push(task);
    this.save();
    this.notify();
    hilog.info(DOMAIN, TAG, '添加下载任务: %{public}s', task.title);
    return true;
  }

  /** 移除任务 */
  removeTask(id: string): void {
    const out: DownloadTask[] = [];
    for (let i = 0; i < this.tasks.length; i++) {
      if (this.tasks[i].id !== id) {
        out.push(this.tasks[i]);
      }
    }
    this.tasks = out;
    this.save();
    this.notify();
  }

  /** 清除已完成的任务 */
  clearCompleted(): void {
    const out: DownloadTask[] = [];
    for (let i = 0; i < this.tasks.length; i++) {
      if (this.tasks[i].status !== DownloadStatus.COMPLETED) {
        out.push(this.tasks[i]);
      }
    }
    this.tasks = out;
    this.save();
    this.notify();
  }

  /** 清除所有任务 */
  clearAll(): void {
    this.tasks = [];
    this.save();
    this.notify();
  }

  /** 更新任务状态 */
  updateStatus(id: string, status: DownloadStatus): void {
    for (let i = 0; i < this.tasks.length; i++) {
      if (this.tasks[i].id === id) {
        const old = this.tasks[i];
        const updated = new DownloadTask(old.id, old.sourceKey, old.comicId, old.epId,
          old.title, old.comicTitle, old.cover);
        updated.status = status;
        updated.totalImages = old.totalImages;
        updated.downloadedImages = old.downloadedImages;
        updated.progress = status === DownloadStatus.COMPLETED ? 100 : old.progress;
        updated.addedTime = old.addedTime;
        updated.completedTime = status === DownloadStatus.COMPLETED ? Date.now() : old.completedTime;
        updated.errorMsg = old.errorMsg;
        this.tasks[i] = updated;
        break;
      }
    }
    this.save();
    this.notify();
  }

  /** 更新任务进度 */
  updateProgress(id: string, downloaded: number, total: number): void {
    for (let i = 0; i < this.tasks.length; i++) {
      if (this.tasks[i].id === id) {
        // 创建新对象替换旧对象, 确保 @State ForEach 检测到变化并重新渲染
        const old = this.tasks[i];
        const updated = new DownloadTask(old.id, old.sourceKey, old.comicId, old.epId,
          old.title, old.comicTitle, old.cover);
        updated.status = old.status;
        updated.totalImages = total;
        updated.downloadedImages = downloaded;
        updated.progress = total > 0 ? Math.round(downloaded * 100 / total) : 0;
        updated.addedTime = old.addedTime;
        updated.completedTime = old.completedTime;
        updated.errorMsg = old.errorMsg;
        this.tasks[i] = updated;
        break;
      }
    }
    this.notify();
  }

  /** 更新任务错误信息 */
  updateError(id: string, errorMsg: string): void {
    for (let i = 0; i < this.tasks.length; i++) {
      if (this.tasks[i].id === id) {
        const old = this.tasks[i];
        const updated = new DownloadTask(old.id, old.sourceKey, old.comicId, old.epId,
          old.title, old.comicTitle, old.cover);
        updated.status = old.status;
        updated.totalImages = old.totalImages;
        updated.downloadedImages = old.downloadedImages;
        updated.progress = old.progress;
        updated.addedTime = old.addedTime;
        updated.completedTime = old.completedTime;
        updated.errorMsg = errorMsg;
        this.tasks[i] = updated;
        break;
      }
    }
    this.save();
    this.notify();
  }

  /** 查找任务 */
  findTask(id: string): DownloadTask | null {
    for (let i = 0; i < this.tasks.length; i++) {
      if (this.tasks[i].id === id) {
        return this.tasks[i];
      }
    }
    return null;
  }

  /** 获取下载统计 */
  getStats(): DownloadStats {
    let pending = 0;
    let downloading = 0;
    let completed = 0;
    let failed = 0;
    let paused = 0;
    for (let i = 0; i < this.tasks.length; i++) {
      switch (this.tasks[i].status) {
        case DownloadStatus.PENDING:
          pending++;
          break;
        case DownloadStatus.DOWNLOADING:
          downloading++;
          break;
        case DownloadStatus.COMPLETED:
          completed++;
          break;
        case DownloadStatus.FAILED:
          failed++;
          break;
        case DownloadStatus.PAUSED:
          paused++;
          break;
        default:
          break;
      }
    }
    const stats: DownloadStats = {
      pending: pending,
      downloading: downloading,
      completed: completed,
      failed: failed,
      paused: paused,
      total: this.tasks.length
    };
    return stats;
  }

  /** 订阅数据变化 */
  subscribe(fn: () => void): void {
    this.listeners.push(fn);
  }

  // === 持久化 ===

  private filePath(): string {
    if (this.context === null) {
      return '';
    }
    return this.context.filesDir + '/download_queue.json';
  }

  private load(): void {
    const path = this.filePath();
    if (path === '') {
      this.loaded = true;
      return;
    }
    try {
      if (!fs.accessSync(path)) {
        this.loaded = true;
        return;
      }
      const content = fs.readTextSync(path);
      const data: DownloadQueuePersistData = JSON.parse(content) as DownloadQueuePersistData;
      this.tasks = [];
      for (let i = 0; i < data.tasks.length; i++) {
        const tp = data.tasks[i];
        const task = new DownloadTask(tp.id, tp.sourceKey, tp.comicId, tp.epId,
          tp.title, tp.comicTitle, tp.cover ?? '');
        task.status = tp.status as DownloadStatus;
        task.totalImages = tp.totalImages;
        task.downloadedImages = tp.downloadedImages;
        task.progress = tp.progress;
        task.addedTime = tp.addedTime;
        task.completedTime = tp.completedTime;
        task.errorMsg = tp.errorMsg;
        // 加载时将 downloading 状态重置为 paused（避免重启后卡在 downloading）
        if (task.status === DownloadStatus.DOWNLOADING) {
          task.status = DownloadStatus.PAUSED;
        }
        this.tasks.push(task);
      }
      this.loaded = true;
      hilog.info(DOMAIN, TAG, '加载下载队列: %{public}d 个任务', this.tasks.length);
    } catch (e) {
      hilog.error(DOMAIN, TAG, '加载下载队列失败: %{public}s', (e as Error).message);
      this.loaded = true;
    }
  }

  private save(): void {
    const path = this.filePath();
    if (path === '' || this.context === null) {
      return;
    }
    try {
      const data: DownloadQueuePersistData = { tasks: [] };
      for (let i = 0; i < this.tasks.length; i++) {
        const task = this.tasks[i];
        data.tasks.push({
          id: task.id,
          sourceKey: task.sourceKey,
          comicId: task.comicId,
          epId: task.epId,
          title: task.title,
          comicTitle: task.comicTitle,
          cover: task.cover,
          status: task.status,
          totalImages: task.totalImages,
          downloadedImages: task.downloadedImages,
          progress: task.progress,
          addedTime: task.addedTime,
          completedTime: task.completedTime,
          errorMsg: task.errorMsg
        });
      }
      const json = JSON.stringify(data);
      const file = fs.openSync(path, fs.OpenMode.CREATE | fs.OpenMode.WRITE_ONLY | fs.OpenMode.TRUNC);
      fs.writeSync(file.fd, json);
      fs.closeSync(file);
    } catch (e) {
      hilog.error(DOMAIN, TAG, '保存下载队列失败: %{public}s', (e as Error).message);
    }
  }

  private notify(): void {
    for (let i = 0; i < this.listeners.length; i++) {
      this.listeners[i]();
    }
  }
}

/** 全局单例 */
export const downloadQueueStore = new DownloadQueueStore();
