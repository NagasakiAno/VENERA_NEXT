/*
 * Copyright (c) 2026 Huawei Device Co., Ltd.
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *     http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */

import { AbilityConstant, ConfigurationConstant, UIAbility, Want } from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { window, display } from '@kit.ArkUI';
import { systemShare, harmonyShare } from '@kit.ShareKit';
import { fileIo as fs } from '@kit.CoreFileKit';
import { uniformTypeDescriptor as utd } from '@kit.ArkData';
import { restoreImported, restoreWebFavorites } from '../utils/FileImporter';
import { jsSourceManager } from '../services/JsSourceManager';
import { jsRuntime } from '../runtime/JsRuntime';
import { diskCacheManager } from '../utils/DiskCacheManager';
import { comicDetailCache } from '../services/ComicDetailCache';
import { downloadQueueStore } from '../model/DownloadQueueStore';
import { shareService } from '../services/ShareService';
import { initBreakpoints, setFoldStatus, updateWindowSize } from '../utils/Breakpoints';
import { appSettings } from '../model/AppSettings';
import { downloadedChapterStore } from '../model/DownloadedChapterStore';

const DOMAIN = 0x0000;
const TAG = 'testTag';

export default class EntryAbility extends UIAbility {
  /** 当前屏幕密度(px -> vp 换算), 失败时回退 2.0 */
  private currentDensity(): number {
    try {
      const d = display.getDefaultDisplaySync();
      if (d.densityPixels > 0) {
        return d.densityPixels;
      }
    } catch (e) {
      hilog.error(DOMAIN, 'testTag', 'get density fail %{public}s', JSON.stringify(e));
    }
    return 2.0;
  }

  /** 当前折叠设备是否完全展开 */
  private isExpanded(): boolean {
    try {
      return display.getFoldStatus() === display.FoldStatus.FOLD_STATUS_EXPANDED;
    } catch (e) {
      return false;
    }
  }

  private foldCallback: (status: display.FoldStatus) => void = () => {};

  onCreate(want: Want, launchParam: AbilityConstant.LaunchParam): void {
    try {
      // UI 为浅色设计体系(BG/CARD 等均为浅色), 锁定浅色避免系统组件在深色模式下配色错乱
      this.context.getApplicationContext().setColorMode(ConfigurationConstant.ColorMode.COLOR_MODE_LIGHT);
    } catch (err) {
      hilog.error(DOMAIN, 'testTag', 'Failed to set colorMode. Cause: %{public}s', JSON.stringify(err));
    }
    // 初始化应用设置(Preferences 持久化), 必须在其他依赖 appSettings 的模块之前
    appSettings.init(this.context).catch((e: Error) => {
      hilog.error(DOMAIN, TAG, 'AppSettings 初始化失败: %{public}s', `${e}`);
    });
    // 初始化已下载章节URL列表存储(本地优先阅读)
    downloadedChapterStore.init(this.context);
    // 恢复已导入的书(从 filesDir/imported.json, 纯文件存储不依赖 Preferences 时序)
    restoreImported(this.context);
    // 恢复 WEB 收藏(书架收藏页签, filesDir/web_favorites.json)
    restoreWebFavorites(this.context);
    // 初始化图片磁盘缓存(读取索引, 清理过期/孤儿文件)
    diskCacheManager.init(this.context).catch((e: Error) => {
      hilog.error(DOMAIN, TAG, '磁盘缓存初始化失败: %{public}s', `${e}`);
    });
    // 初始化详情页缓存(创建目录)
    comicDetailCache.init(this.context).catch((e: Error) => {
      hilog.error(DOMAIN, TAG, '详情缓存初始化失败: %{public}s', `${e}`);
    });
    // 初始化下载队列(读取持久化的下载任务)
    downloadQueueStore.init(this.context);
    // 启动扫描已安装的 JS 漫画源
    jsSourceManager.scanFromFilesDir(this.context);
    // 初始化分享服务
    shareService.init(this.context);
    // 初始化响应式断点
    initBreakpoints();
    // 初始化 JS 运行时(加载 init.js + sendMessage 桥), 异步执行不阻塞启动
    this.bootJsRuntime().catch((e: Error) => {
      hilog.error(DOMAIN, TAG, 'bootJsRuntime 异常: %{public}s', `${e}`);
    });
    hilog.info(DOMAIN, TAG, '%{public}s', 'Ability onCreate');

    // 处理分享数据(冷启动时系统通过 want 传入)
    this.handleShareWant(want);
  }

  onNewWant(want: Want, launchParam: AbilityConstant.LaunchParam): void {
    hilog.info(DOMAIN, TAG, '%{public}s', 'Ability onNewWant');
    // 处理分享数据(应用已运行时系统通过 onNewWant 传入)
    this.handleShareWant(want);
  }

  /**
   * 处理系统分享传入的 Want
   * 从 want 中解析 SharedData, 提取 HYPERLINK 类型记录的 content(JSON),
   * 调用 shareService.handleReceivedData() 导入收藏
   */
  private handleShareWant(want: Want): void {
    try {
      // 记录所有收到的 Want 关键信息, 便于排查跨设备分享链路
      const paramKeys = want.parameters === undefined ? [] : Object.keys(want.parameters);
      hilog.info(DOMAIN, TAG, '收到 Want: action=%{public}s uri=%{public}s type=%{public}s params=%{public}s',
        want.action ?? '', want.uri ?? '', want.type ?? '', paramKeys.join(','));

      // 1. 链接形式(华为分享把负载链接投递过来时)
      const wantUri = want.uri ?? '';
      if (wantUri.length > 0 && shareService.handleShareLink(wantUri)) {
        hilog.info(DOMAIN, TAG, '分享链接导入成功');
        return;
      }

      // 2. Share Kit 分享数据(同设备分享 / 跨设备投递)
      if (want.action !== 'ohos.want.action.sendData') {
        return;
      }
      systemShare.getSharedData(want).then((sharedData: systemShare.SharedData) => {
        const ok = shareService.importSharedData(sharedData);
        if (ok) {
          hilog.info(DOMAIN, TAG, '分享数据导入成功');
        } else {
          hilog.warn(DOMAIN, TAG, '分享数据导入失败(记录中未找到有效负载)');
        }
      }).catch((e: Error) => {
        hilog.error(DOMAIN, TAG, 'getSharedData 失败: %{public}s', `${e}`);
      });
    } catch (e) {
      hilog.error(DOMAIN, TAG, 'handleShareWant 异常: %{public}s', `${e}`);
    }
  }

  /** 注册华为分享事件(碰一碰 / 隔空传送), 当前页面有漫画时直接跨设备发送 */
  /** 分享接收沙箱目录 */
  private shareReceiveDir(): string {
    return this.context.cacheDir + '/share_receive';
  }

  /** 华为分享接收能力注册项(注销时要复用同一个对象) */
  private shareRecvCapability: harmonyShare.RecvCapabilityRegistry | null = null;

  /** 注册华为分享事件(碰一碰 / 隔空传送)与跨设备文件接收能力 */
  private registerHarmonyShareListeners(windowId: number): void {
    try {
      harmonyShare.on('knockShare', (target: harmonyShare.SharableTarget) => {
        shareService.handleSharableTarget(target);
      });
      harmonyShare.on('gesturesShare', (target: harmonyShare.SharableTarget) => {
        shareService.handleSharableTarget(target);
      });

      // 接收端: 注册纯文本分享能力, 对端通过华为分享发来的文件会先收进沙箱再自动导入
      const dir = this.shareReceiveDir();
      if (!fs.accessSync(dir)) {
        fs.mkdirSync(dir, true);
      }
      const capability: harmonyShare.RecvCapabilityRegistry = {
        windowId: windowId,
        capabilities: [
          { utd: utd.UniformDataType.PLAIN_TEXT, maxSupportedCount: 1 }
        ]
      };
      this.shareRecvCapability = capability;
      harmonyShare.on('dataReceive', capability, (target: harmonyShare.ReceivableTarget) => {
        this.onDataReceiveTarget(target);
      });
      hilog.info(DOMAIN, TAG, '华为分享监听与接收能力已注册');
    } catch (e) {
      hilog.error(DOMAIN, TAG, '注册华为分享监听失败: %{public}s', `${e}`);
    }
  }

  /** 收到分享接收请求: 把文件收进沙箱并解析导入 */
  private onDataReceiveTarget(target: harmonyShare.ReceivableTarget): void {
    const dir = this.shareReceiveDir();
    try {
      if (!fs.accessSync(dir)) {
        fs.mkdirSync(dir, true);
      }
      target.receive(dir, {
        onDataReceived: (shared: systemShare.SharedData) => {
          hilog.info(DOMAIN, TAG, '分享文件已接收, 开始导入');
          const ok = shareService.importReceivedFiles(dir);
          const fromRecords = shareService.importSharedData(shared);
          hilog.info(DOMAIN, TAG, '分享导入结果: file=%{public}s, record=%{public}s',
            ok ? 'ok' : 'fail', fromRecords ? 'ok' : 'fail');
        },
        onResult: (code: harmonyShare.ShareResultCode) => {
          hilog.info(DOMAIN, TAG, '分享接收完成 code=%{public}d', code as number);
        }
      }).catch((e: Error) => {
        hilog.error(DOMAIN, TAG, 'receive 调用失败: %{public}s', `${e}`);
      });
    } catch (e) {
      hilog.error(DOMAIN, TAG, '处理分享接收失败: %{public}s', `${e}`);
    }
  }

  /** 注销华为分享事件监听 */
  private unregisterHarmonyShareListeners(): void {
    try {
      harmonyShare.off('knockShare');
      harmonyShare.off('gesturesShare');
      const cap = this.shareRecvCapability;
      if (cap !== null) {
        harmonyShare.off('dataReceive', cap);
        this.shareRecvCapability = null;
      }
    } catch (e) {
      hilog.error(DOMAIN, TAG, '注销华为分享监听失败: %{public}s', `${e}`);
    }
  }

  /** 启动 JS 运行时并做一次诊断(验证 继承/存储/编码/网络/真实源脚本) */
  private async bootJsRuntime(): Promise<void> {
    const ok = await jsRuntime.init(this.context);
    if (!ok) {
      hilog.error(DOMAIN, TAG, 'JS 运行时初始化失败: %{public}s', jsRuntime.lastError());
      return;
    }
    hilog.info(DOMAIN, TAG, 'JS 运行时就绪');
    try {
      const report = await jsRuntime.diagnose();
      hilog.info(DOMAIN, TAG, 'SELFCHECK_OK %{public}s', report);
    } catch (e) {
      hilog.error(DOMAIN, TAG, 'SELFCHECK_FAIL %{public}s', `${e}`);
    }
  }

  onDestroy(): void {
    hilog.info(DOMAIN, 'testTag', '%{public}s', 'Ability onDestroy');
  }

  onWindowStageCreate(windowStage: window.WindowStage): void {
    // Main window is created, set main page for this ability
    hilog.info(DOMAIN, 'testTag', '%{public}s', 'Ability onWindowStageCreate');

    // 折叠状态驱动: display.foldStatus 比窗口宽高比更可靠(适用阔折叠内屏)
    setFoldStatus(this.isExpanded());

    // 监听折叠状态变化(展开/折叠切换 -> 平板/手机 UI)
    this.foldCallback = (status: display.FoldStatus): void => {
      setFoldStatus(status === display.FoldStatus.FOLD_STATUS_EXPANDED);
    };
    try {
      display.on('foldStatusChange', this.foldCallback);
    } catch (e) {
      hilog.error(DOMAIN, 'testTag', 'fold listen fail %{public}s', JSON.stringify(e));
    }

    // 窗口尺寸(含分屏/旋转) -> 实时密度换算 vp
    const mainWin = windowStage.getMainWindowSync();
    const prop = mainWin.getWindowProperties();
    const density0 = this.currentDensity();
    updateWindowSize(
      Math.round(prop.windowRect.width / density0),
      Math.round(prop.windowRect.height / density0));

    // 沉浸式: 内容延伸到系统状态栏/导航条区域, 避免底部黑条
    try {
      mainWin.setWindowLayoutFullScreen(true);
    } catch (e) {
      hilog.error(DOMAIN, 'testTag', 'set window fullscreen fail %{public}s', JSON.stringify(e));
    }

    mainWin.on('windowSizeChange', (size: window.Size) => {
      const density = this.currentDensity();
      // 折叠开合会改变默认屏, 顺带刷新折叠状态
      setFoldStatus(this.isExpanded());
      updateWindowSize(
        Math.round(size.width / density),
        Math.round(size.height / density));
    });
    // 注册华为分享(碰一碰/隔空传送)与跨设备文件接收
    this.registerHarmonyShareListeners(mainWin.getWindowProperties().id);


    windowStage.loadContent('pages/Index', (err) => {
      if (err.code) {
        hilog.error(DOMAIN, 'testTag', 'Failed to load the content. Cause: %{public}s', JSON.stringify(err));
        return;
      }
      hilog.info(DOMAIN, 'testTag', 'Succeeded in loading the content.');
    });
  }

  onWindowStageDestroy(): void {
    this.unregisterHarmonyShareListeners();
    // Main window is destroyed, release UI related resources
    try {
      display.off('foldStatusChange', this.foldCallback);
    } catch (e) {
      hilog.error(DOMAIN, 'testTag', 'fold off fail %{public}s', JSON.stringify(e));
    }
    hilog.info(DOMAIN, 'testTag', '%{public}s', 'Ability onWindowStageDestroy');
  }

  onForeground(): void {
    // Ability has brought to foreground
    hilog.info(DOMAIN, 'testTag', '%{public}s', 'Ability onForeground');
  }

  onBackground(): void {
    // Ability has back to background
    hilog.info(DOMAIN, 'testTag', '%{public}s', 'Ability onBackground');
  }
}