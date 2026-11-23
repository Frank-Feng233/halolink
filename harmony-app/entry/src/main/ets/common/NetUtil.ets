import { connection } from '@kit.NetworkKit';
import { Log } from '../common/Logger';

/** Network helper: find the IPv4 address the Mac should connect to. */
export class NetUtil {
  static localIpv4(): string {
    try {
      const netHandle = connection.getDefaultNetSync();
      if (netHandle === null || netHandle.netId === 0) {
        return '';
      }
      const props = connection.getConnectionPropertiesSync(netHandle);
      if (props === null || props.linkAddresses === undefined) {
        return '';
      }
      // Prefer a real LAN address; USB RNDIS / debug networks often show
      // 172.25.x, which the Mac cannot reach in Wi-Fi mode.
      let fallback = '';
      for (const link of props.linkAddresses) {
        const address = link.address.address;
        if (address.indexOf('.') <= 0 || address.startsWith('127.')) {
          continue;
        }
        if (address.startsWith('192.168.') || address.startsWith('10.') ||
          (address.startsWith('172.') && address.indexOf('.') > 0)) {
          return address;
        }
        if (fallback.length === 0) {
          fallback = address;
        }
      }
      if (fallback.length > 0) {
        return fallback;
      }
      // Fallback: any non-loopback address (IPv6 link local is not useful here).
      for (const link of props.linkAddresses) {
        const address = link.address.address;
        if (!address.startsWith('127.') && address.indexOf(':') < 0) {
          return address;
        }
      }
    } catch (err) {
      Log.w(`NetUtil.localIpv4 failed: ${JSON.stringify(err)}`);
    }
    return '';
  }
}
