/**
 * VeneraNext 结果封装(对应 Flutter 版 foundation/res.dart)
 * 用于承载操作的成败与数据
 */
export class comic_Res<T> {
  /** 错误信息, 为空表示成功 */
  readonly errorMessage: string;
  /** 数据 */
  readonly data: T | null;

  private constructor(data: T | null, errorMessage: string) {
    this.data = data;
    this.errorMessage = errorMessage;
  }

  get error(): boolean {
    return this.errorMessage.length > 0;
  }

  static success<T>(data: T): comic_Res<T> {
    return new comic_Res<T>(data, '');
  }

  static fail<T>(message: string): comic_Res<T> {
    return new comic_Res<T>(null, message);
  }
}