import { AbilityConstant, ConfigurationConstant, UIAbility, Want } from '@kit.AbilityKit';
import { window } from '@kit.ArkUI';
import { BusinessError } from '@kit.BasicServicesKit';
import { Log } from '../common/Logger';

/**
 * HaloLink entry ability.
 *
 * The whole app is one immersive landscape window: no status bar, no navigation
 * bar, screen kept on while it is the extended display. Users can still leave via
 * the in-app ✕ button (system swipe gestures are intentionally not relied upon).
 */
export default class EntryAbility extends UIAbility {
  onCreate(want: Want, launchParam: AbilityConstant.LaunchParam): void {
    Log.i('EntryAbility onCreate');
    // Force dark system theme so sheets/buttons/toasts follow the dark UI.
    try {
      this.context.getApplicationContext()
        .setColorMode(ConfigurationConstant.ColorMode.COLOR_MODE_DARK);
      Log.i('application color mode set to DARK');
    } catch (err) {
      Log.w(`setColorMode failed: ${JSON.stringify(err)}`);
    }
  }

  onDestroy(): void {
    Log.i('EntryAbility onDestroy');
  }

  onWindowStageCreate(windowStage: window.WindowStage): void {
    Log.i('EntryAbility onWindowStageCreate');
    windowStage.loadContent('pages/Index', (err: BusinessError) => {
      if (err.code) {
        Log.e(`loadContent failed: ${JSON.stringify(err)}`);
        return;
      }
      Log.i('loadContent ok');
    });
    windowStage.getMainWindow().then((win: window.Window) => {
      this.applyImmersiveMode(win);
    }).catch((err: BusinessError) => {
      Log.e(`getMainWindow failed: ${JSON.stringify(err)}`);
    });
  }

  onWindowStageDestroy(): void {
    Log.i('EntryAbility onWindowStageDestroy');
  }

  onForeground(): void {
    Log.i('EntryAbility onForeground');
    window.getLastWindow(this.context).then((win: window.Window) => {
      win.setWindowKeepScreenOn(true).catch((err: BusinessError) => {
        Log.w(`setWindowKeepScreenOn failed: ${err.message}`);
      });
    }).catch((err: BusinessError) => {
      Log.w(`getLastWindow failed: ${err.message}`);
    });
  }

  onBackground(): void {
    Log.i('EntryAbility onBackground');
  }

  private async applyImmersiveMode(win: window.Window): Promise<void> {
    try {
      await win.setWindowLayoutFullScreen(true);
      await win.setWindowSystemBarEnable([]);
      await win.setWindowKeepScreenOn(true);
      // Follow the system auto-rotate switch + orientation sensor (v1.1 requirement).
      try {
        await win.setPreferredOrientation(window.Orientation.AUTO_ROTATION);
        Log.i('preferred orientation = AUTO_ROTATION');
      } catch (orientErr) {
        Log.w(`setPreferredOrientation(AUTO_ROTATION) failed: ${JSON.stringify(orientErr)}`);
      }
      await win.setWindowSystemBarProperties({
        statusBarColor: '#000000',
        navigationBarColor: '#000000',
        statusBarContentColor: '#FFFFFF',
        navigationBarContentColor: '#FFFFFF'
      });
      Log.i('immersive fullscreen mode applied');
    } catch (err) {
      const e = err as BusinessError;
      Log.e(`applyImmersiveMode failed: ${e.code} ${e.message}`);
    }
  }
}
