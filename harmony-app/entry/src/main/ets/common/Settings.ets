import { preferences } from '@kit.ArkData';
import { common } from '@kit.AbilityKit';
import { Log } from './Logger';
import { DEFAULT_PORT } from '../net/Protocol';

const STORE_NAME: string = 'halolink_settings';
const KEY_PORT: string = 'port';
const KEY_WEB_MODE: string = 'webMode';
const KEY_WEB_URL: string = 'webUrl';
const KEY_AUTO_LISTEN: string = 'autoListen';
const KEY_SHOW_STATS: string = 'showStats';
const KEY_DISPLAY_MODE: string = 'displayMode';      // 'fit' | 'fill'
const KEY_TOUCH_ENABLED: string = 'touchEnabled';    // v1.1 default OFF
const KEY_DISPLAY_MODE_SET: string = 'displayModeUserSet';

/** Persisted user settings (preferences). */
export class AppSettings {
  port: number = DEFAULT_PORT;
  webMode: boolean = false;
  webUrl: string = '';
  autoListen: boolean = true;
  showStats: boolean = true;
  displayMode: string = 'fit';      // 完整显示(可能留黑边) | 裁剪填满(无黑边,可能裁掉边缘)
  displayModeUserSet: boolean = false;
  touchEnabled: boolean = false;    // 触摸/键盘/滚轮/文本回传，默认关闭
}

export class SettingsStore {
  static async load(context: common.Context): Promise<AppSettings> {
    const settings = new AppSettings();
    try {
      const store = await preferences.getPreferences(context, STORE_NAME);
      settings.port = store.getSync(KEY_PORT, DEFAULT_PORT) as number;
      settings.webMode = store.getSync(KEY_WEB_MODE, false) as boolean;
      settings.webUrl = store.getSync(KEY_WEB_URL, '') as string;
      settings.autoListen = store.getSync(KEY_AUTO_LISTEN, true) as boolean;
      settings.showStats = store.getSync(KEY_SHOW_STATS, true) as boolean;
      settings.displayMode = store.getSync(KEY_DISPLAY_MODE, 'fit') as string;
      settings.displayModeUserSet = store.getSync(KEY_DISPLAY_MODE_SET, false) as boolean;
      settings.touchEnabled = store.getSync(KEY_TOUCH_ENABLED, false) as boolean;
      Log.i(`settings loaded port=${settings.port} webMode=${settings.webMode} ` +
        `displayMode=${settings.displayMode} touch=${settings.touchEnabled}`);
    } catch (err) {
      Log.w(`settings load failed: ${JSON.stringify(err)}`);
    }
    return settings;
  }

  static async save(context: common.Context, settings: AppSettings): Promise<void> {
    try {
      const store = await preferences.getPreferences(context, STORE_NAME);
      await store.put(KEY_PORT, settings.port);
      await store.put(KEY_WEB_MODE, settings.webMode);
      await store.put(KEY_WEB_URL, settings.webUrl);
      await store.put(KEY_AUTO_LISTEN, settings.autoListen);
      await store.put(KEY_SHOW_STATS, settings.showStats);
      await store.put(KEY_DISPLAY_MODE, settings.displayMode);
      await store.put(KEY_DISPLAY_MODE_SET, settings.displayModeUserSet);
      await store.put(KEY_TOUCH_ENABLED, settings.touchEnabled);
      await store.flush();
      Log.i('settings saved');
    } catch (err) {
      Log.w(`settings save failed: ${JSON.stringify(err)}`);
    }
  }
}
