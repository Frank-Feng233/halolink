import { hilog } from '@kit.PerformanceAnalysisKit';

const DOMAIN: number = 0x3200;
const TAG: string = 'HaloLink';
const MAX_MEMORY_LOGS: number = 120;

/** One line of in-app debug log (shown in the settings panel). */
export interface LogLine {
  time: string;
  text: string;
}

/**
 * Project logger. Everything goes to hilog with tag "HaloLink" so it can be
 * inspected with `hdc shell hilog | grep HaloLink`; the last N lines are also
 * kept in memory for the in-app diagnostics panel.
 */
export class Log {
  private static lines: LogLine[] = [];

  static i(message: string): void {
    hilog.info(DOMAIN, TAG, '%{public}s', message);
    Log.remember('I', message);
  }

  static w(message: string): void {
    hilog.warn(DOMAIN, TAG, '%{public}s', message);
    Log.remember('W', message);
  }

  static e(message: string): void {
    hilog.error(DOMAIN, TAG, '%{public}s', message);
    Log.remember('E', message);
  }

  static d(message: string): void {
    hilog.debug(DOMAIN, TAG, '%{public}s', message);
  }

  static recent(count: number): LogLine[] {
    if (count >= Log.lines.length) {
      return Log.lines.slice(0);
    }
    return Log.lines.slice(Log.lines.length - count);
  }

  static clear(): void {
    Log.lines = [];
  }

  private static remember(level: string, message: string): void {
    const now = new Date();
    const hh = now.getHours().toString().padStart(2, '0');
    const mm = now.getMinutes().toString().padStart(2, '0');
    const ss = now.getSeconds().toString().padStart(2, '0');
    const line: LogLine = { time: `${hh}:${mm}:${ss}`, text: `[${level}] ${message}` };
    Log.lines.push(line);
    if (Log.lines.length > MAX_MEMORY_LOGS) {
      Log.lines.shift();
    }
  }
}
