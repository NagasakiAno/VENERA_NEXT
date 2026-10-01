/**
 * 评论服务
 *
 * 对应原版库的 comic.loadComments / comic.sendComment / comic.likeComment。
 * 包装 JsRuntime 调用, 解析 JSON 为 Comment 模型。
 */
import { hilog } from '@kit.PerformanceAnalysisKit';
import { Comment } from '../model/ComicModels';
import { comicSourceManager } from '../model/ComicSource';
import { jsRuntime } from '../runtime/JsRuntime';

const DOMAIN = 0x0000;
const TAG = 'CommentService';

/** 评论加载结果 */
export class CommentResult {
  comments: Comment[] = [];
  maxPage: number = 1;
}

export class CommentService {
  private static instance: CommentService = new CommentService();

  static getInstance(): CommentService {
    return CommentService.instance;
  }

  /** 源是否支持评论功能 */
  supportsComments(sourceKey: string): boolean {
    const meta = comicSourceManager.findJsSource(sourceKey);
    if (meta === null) {
      return false;
    }
    // 通过 ComicSourceMeta 的 hasLoadComments 标志判断(若存在)
    // 目前保守判断: 已登录的源都尝试加载
    return true;
  }

  /**
   * 加载评论列表。
   * @param sourceKey 源键
   * @param comicId 漫画 ID
   * @param subId 源返回的子 ID(可为空)
   * @param page 页码(从 1 开始)
   * @param replyTo 回复目标评论 ID(可为空, 空表示加载顶级评论)
   */
  async loadComments(sourceKey: string, comicId: string, subId: string,
                     page: number, replyTo: string): Promise<CommentResult> {
    const json = await jsRuntime.callLoadComments(sourceKey, comicId, subId, page, replyTo);
    if (json.length === 0 || json === 'null') {
      return new CommentResult();
    }
    let parsed: Object;
    try {
      parsed = JSON.parse(json) as Object;
    } catch (e) {
      hilog.warn(DOMAIN, TAG, '评论数据解析失败: %{public}s', `${e}`);
      return new CommentResult();
    }
    const result = new CommentResult();
    const record = parsed as Record<string, Object>;
    if (record === null || record === undefined) {
      return result;
    }
    const maxPage = record['maxPage'];
    if (typeof maxPage === 'number') {
      result.maxPage = maxPage as number;
    }
    const commentsRaw = record['comments'];
    if (commentsRaw !== null && commentsRaw !== undefined && Array.isArray(commentsRaw)) {
      const arr = commentsRaw as Object[];
      for (let i = 0; i < arr.length; i++) {
        const item = arr[i] as Record<string, Object>;
        if (item !== null && item !== undefined) {
          result.comments.push(new Comment(item));
        }
      }
    }
    hilog.info(DOMAIN, TAG, '加载评论 %{public}s@%{public}s p%{public}d: %{public}d 条',
      sourceKey, comicId, page, result.comments.length);
    return result;
  }

  /**
   * 发送评论。
   * @param content 评论内容
   * @param replyTo 回复目标评论 ID(可为空)
   */
  async sendComment(sourceKey: string, comicId: string, subId: string,
                    content: string, replyTo: string): Promise<void> {
    await jsRuntime.callSendComment(sourceKey, comicId, subId, content, replyTo);
    hilog.info(DOMAIN, TAG, '发送评论 %{public}s@%{public}s: %{public}s',
      sourceKey, comicId, content.length > 20 ? content.substring(0, 20) + '...' : content);
  }

  /**
   * 点赞/取消点赞评论。
   * @param commentId 评论 ID
   * @param isLike true=点赞, false=取消点赞
   */
  async likeComment(sourceKey: string, comicId: string, subId: string,
                    commentId: string, isLike: boolean): Promise<void> {
    await jsRuntime.callLikeComment(sourceKey, comicId, subId, commentId, isLike);
    hilog.info(DOMAIN, TAG, '点赞评论 %{public}s@%{public}s cid=%{public}s like=%{public}s',
      sourceKey, comicId, commentId, String(isLike));
  }
}

/** 全局单例 */
export const commentService = CommentService.getInstance();
