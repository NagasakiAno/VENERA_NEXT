/**
 * VeneraNext 下载执行服务
 * - 调用 ComicReadService.loadImages() 获取章节图片 URL 列表
 * - 逐张下载原始字节并写入 DiskCacheManager
 * - 队列调度：当前任务完成后自动启动下一个 pending 任务
 * - 并发控制：同时最多 1 个任务下载
 */
import { hilog } from '@kit.PerformanceAnalysisKit';
import { comicReadService } from './ComicReadService';
import { downloadQueueStore, DownloadTask, DownloadStatus } from '../model/DownloadQueueStore';
import { diskCacheManager } from '../utils/DiskCacheManager';
import { downloadedChapterStore } from '../model/DownloadedChapterStore';

const DOMAIN = 0x0000;
const TAG = 'DownloadService';

class DownloadService {
  private currentTask: DownloadTask | null = null;
  private isRunning: boolean = false;

  /** 启动队列调度（如果有 pending 任务且当前没有在下载） */
  startQueue(): void {
    if (this.isRunning) {
      return;
    }
    const pending = downloadQueueStore.getPendingTasks();
    if (pending.length === 0) {
      return;
    }
    this.executeTask(pending[0]);
  }

  /** 执行单个下载任务 */
  private async executeTask(task: DownloadTask): Promise<void> {
    this.isRunning = true;
    this.currentTask = task;
    downloadQueueStore.updateStatus(task.id, DownloadStatus.DOWNLOADING);

    hilog.info(DOMAIN, TAG, '开始下载: %{public}s', task.title);

    // 1. 获取章节图片 URL 列表
    const chapterImages = await comicReadService.loadImages(task.sourceKey, task.comicId, task.epId);
    if (!chapterImages.isOk()) {
      downloadQueueStore.updateError(task.id, chapterImages.error);
      downloadQueueStore.updateStatus(task.id, DownloadStatus.FAILED);
      hilog.warn(DOMAIN, TAG, '获取章节图片失败: %{public}s', chapterImages.error);
      this.onTaskFinished();
      return;
    }

    const total = chapterImages.urls.length;
    downloadQueueStore.updateProgress(task.id, 0, total);

    // 2. 逐张下载并写入磁盘缓存
    let downloaded = 0;
    let failedCount = 0;

    for (let i = 0; i < chapterImages.urls.length; i++) {
      // 检查任务是否被暂停或删除
      const current = downloadQueueStore.findTask(task.id);
      if (current === null) {
        // 任务已被删除
        hilog.info(DOMAIN, TAG, '任务已被删除，停止下载: %{public}s', task.title);
        this.onTaskFinished();
        return;
      }
      if (current.status === DownloadStatus.PAUSED) {
        hilog.info(DOMAIN, TAG, '任务已暂停: %{public}s', task.title);
        this.onTaskFinished();
        return;
      }

      const url = chapterImages.urls[i];
      const cacheKey = task.sourceKey + '|' + task.comicId + '|' + task.epId + '|' + url;

      // 检查磁盘缓存是否已有此图片（避免重复下载）
      const existingPath = diskCacheManager.find(cacheKey);
      if (existingPath !== null) {
        downloaded++;
        downloadQueueStore.updateProgress(task.id, downloaded, total);
        continue;
      }

      // 下载图片原始字节
      const bytes = await comicReadService.downloadImageBytes(task.sourceKey, task.comicId,
        task.epId, url);
      if (bytes !== null) {
        // 写入磁盘缓存
        await diskCacheManager.write(cacheKey, bytes);
        downloaded++;
      } else {
        failedCount++;
        hilog.warn(DOMAIN, TAG, '图片下载失败 [%{public}d/%{public}d]: %{public}s',
          i + 1, total, url.substring(0, 50));
      }

      downloadQueueStore.updateProgress(task.id, downloaded, total);
    }

    // 3. 判断任务结果
    if (downloaded === 0) {
      downloadQueueStore.updateError(task.id, '全部图片下载失败');
      downloadQueueStore.updateStatus(task.id, DownloadStatus.FAILED);
    } else if (failedCount > 0) {
      downloadQueueStore.updateError(task.id, `${failedCount} 张图片下载失败`);
      downloadQueueStore.updateStatus(task.id, DownloadStatus.COMPLETED);
      // 保存URL列表到本地，下次阅读时优先从本地加载
      downloadedChapterStore.save(task.sourceKey, task.comicId, task.epId, chapterImages.urls);
      hilog.info(DOMAIN, TAG, '下载完成（部分失败）: %{public}s (%{public}d/%{public}d)',
        task.title, downloaded, total);
    } else {
      downloadQueueStore.updateStatus(task.id, DownloadStatus.COMPLETED);
      // 保存URL列表到本地，下次阅读时优先从本地加载
      downloadedChapterStore.save(task.sourceKey, task.comicId, task.epId, chapterImages.urls);
      hilog.info(DOMAIN, TAG, '下载完成: %{public}s (%{public}d 张)', task.title, total);
    }

    this.onTaskFinished();
  }

  /** 任务完成后调度下一个 */
  private onTaskFinished(): void {
    this.isRunning = false;
    this.currentTask = null;
    // 自动启动下一个 pending 任务
    this.startQueue();
  }

  /** 暂停当前任务 */
  pauseTask(id: string): void {
    downloadQueueStore.updateStatus(id, DownloadStatus.PAUSED);
  }

  /** 继续暂停的任务 */
  resumeTask(id: string): void {
    const task = downloadQueueStore.findTask(id);
    if (task !== null && task.status === DownloadStatus.PAUSED) {
      downloadQueueStore.updateStatus(id, DownloadStatus.PENDING);
      this.startQueue();
    }
  }

  /** 重试失败的任务 */
  retryTask(id: string): void {
    const task = downloadQueueStore.findTask(id);
    if (task !== null && task.status === DownloadStatus.FAILED) {
      task.errorMsg = '';
      downloadQueueStore.updateStatus(id, DownloadStatus.PENDING);
      this.startQueue();
    }
  }

  /** 获取当前正在下载的任务 */
  getCurrentTask(): DownloadTask | null {
    return this.currentTask;
  }
}

/** 全局单例 */
export const downloadService = new DownloadService();
