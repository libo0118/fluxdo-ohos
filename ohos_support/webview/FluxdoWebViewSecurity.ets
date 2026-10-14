import deviceInfo from '@ohos.deviceInfo';
import url from '@ohos.url';
import webview from '@ohos.web.webview';
import { Any } from '@ohos/flutter_ohos';

export class FluxdoLeafChallenge {
  host: string;
  port: number;
  leaf: Uint8Array;
  constructor(host: string, port: number, leaf: Uint8Array) {
    this.host = host;
    this.port = port;
    this.leaf = leaf;
  }
}

export default class FluxdoWebViewSecurity {
  static supportsBoundLeaf(): boolean {
    return deviceInfo.sdkApiVersion >= 20;
  }

  static dnsHost(host: string): string | null {
    const normalized = host.endsWith('.') ? host.slice(0, -1) : host;
    if (normalized.length == 0 || normalized.length > 253 ||
      !/^[A-Za-z0-9.-]+$/.test(normalized) || /^\d+(\.\d+)*$/.test(normalized)) return null;
    const labels = normalized.split('.');
    if (labels.some((label: string) => label.length == 0 || label.length > 63 ||
      label.startsWith('-') || label.endsWith('-'))) return null;
    return normalized.toLowerCase();
  }

  static leafChallenge(event: SslErrorEvent): FluxdoLeafChallenge | null {
    // shortcut: API <20 cannot bind the failing URL to its certificate chain; keep refusing exceptions.
    if (!this.supportsBoundLeaf() || event.error != SslError.Untrusted) return null;
    const chain = event.certChainData;
    if (chain == undefined || chain.length == 0 || chain[0].length == 0 || chain[0].length > 16384) return null;
    const parsed = new url.URL(event.url);
    const host = this.dnsHost(parsed.hostname);
    if (parsed.protocol != 'https:' || parsed.username != '' || parsed.password != '' || host == null) return null;
    const port = parsed.port == '' ? 443 : Number(parsed.port);
    if (!Number.isInteger(port) || port < 1 || port > 65535) return null;
    // shortcut: SDK does not promise chain order; a non-leaf first entry fails the exact native cache comparison.
    return new FluxdoLeafChallenge(host, port, new Uint8Array(chain[0]));
  }

  static async cookiesForUrl(rawUrl: string): Promise<Array<Map<string, Any>> | null> {
    // shortcut: API <23 only exposes name/value; preserve the existing low-confidence session-cookie gate.
    if (deviceInfo.sdkApiVersion < 23) return null;
    const parsed = new url.URL(rawUrl);
    if (parsed.protocol != 'https:' && parsed.protocol != 'http:') return [];
    const host = parsed.hostname.toLowerCase();
    const path = parsed.pathname == '' ? '/' : parsed.pathname;
    const cookies = await webview.WebCookieManager.fetchAllCookies(false);
    const result: Array<Map<string, Any>> = [];
    for (const cookie of cookies) {
      const domain = cookie.domain.toLowerCase();
      const domainName = domain.startsWith('.') ? domain.slice(1) : domain;
      if (domainName == '' || (host != domainName && (!domain.startsWith('.') || !host.endsWith('.' + domainName)))) continue;
      if (!cookie.path.startsWith('/') || !(path == cookie.path ||
        (path.startsWith(cookie.path) && (cookie.path.endsWith('/') || path.charAt(cookie.path.length) == '/')))) continue;
      if (cookie.isSecure && parsed.protocol != 'https:') continue;
      const expiry = cookie.isSessionCookie ? null : Date.parse(cookie.expiresDate);
      if (expiry != null && (!Number.isFinite(expiry) || expiry <= Date.now())) continue;
      const map: Map<string, Any> = new Map<string, Any>();
      map.set('name', cookie.name);
      map.set('value', cookie.value);
      map.set('domain', cookie.domain);
      map.set('path', cookie.path);
      map.set('expiresDate', expiry);
      map.set('isSessionOnly', cookie.isSessionCookie);
      map.set('isHttpOnly', cookie.isHttpOnly);
      map.set('isSecure', cookie.isSecure);
      map.set('sameSite', cookie.samesitePolicy == 0 ? 'None' : cookie.samesitePolicy == 1 ? 'Lax' : cookie.samesitePolicy == 2 ? 'Strict' : null);
      result.push(map);
    }
    return result;
  }
}
