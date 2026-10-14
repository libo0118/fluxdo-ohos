"""Patch only the pinned resolved OHOS WebView dependency, preserving other platforms."""
import argparse
import os
from pathlib import Path
import re
import shutil
import tempfile

from prepare_ohos_enums import package_root
from prepare_ohos_network import replace_once

WEBVIEW_REV = 'a281ae3272a9218760d52b95014a71a41866bd6c'
PLUGIN = Path('ohos/src/main/ets/components/plugin')
COOKIE_RICH_LEGACY = '''    const rich = await FluxdoWebViewSecurity.cookiesForUrl(url);
    if (rich != null) {
      for (const cookie of rich) cookieListMap.add(cookie);
      return cookieListMap;
    }
    // fetchCookieSync may throw BusinessError; callers must catch (onMethodCall does).'''
COOKIE_RICH = '''    const rich: Array<Map<string, Object | null>> | null = await FluxdoWebViewSecurity.cookiesForUrl(url);
    if (rich != null) {
      for (let i = 0; i < rich.length; i++) {
        const cookie: Map<string, Object | null> = rich[i];
        cookieListMap.add(cookie);
      }
      return cookieListMap;
    }
    // fetchCookieSync may throw BusinessError; callers must catch (onMethodCall does).'''
SSL_CALLBACK = '''  onSslErrorEvent = async (event: SslErrorEvent) => {
    try {
      const leaf = FluxdoWebViewSecurity.leafChallenge(event);
      const delegate = this.inAppWebView?.channelDelegate;
      if (leaf == null || delegate == null) {
        event.handler.handleCancel();
        return;
      }
      const protectionSpace = new URLProtectionSpace(leaf.host, 'https', null,
        leaf.port, null, null, event.error, leaf.leaf);
      const challenge = new ServerTrustChallenge(protectionSpace);
      await delegate.onReceivedServerTrustAuthRequest(challenge,
        new InnerReceivedServerTrustAuthRequestCallback(event.handler));
    } catch (_) {
      event.handler.handleCancel();
    }
  }
'''


def prepare_sources(plugin, interface, support):
    changes = {}
    def change(path, before, after):
        current = changes.get(path, path.read_text(encoding='utf-8'))
        changes[path] = replace_once(current, before, after, str(path))

    node = plugin / PLUGIN / 'webview/in_app_webview/WebNodeController.ets'
    change(node, '.onSslErrorEventReceive(params.inAppWebView.inAppWebViewClient?.onSslErrorEventReceive)',
           '.onSslErrorEvent(params.inAppWebView.inAppWebViewClient?.onSslErrorEvent)')
    client = plugin / PLUGIN / 'webview/in_app_webview/InAppWebViewClient.ets'
    change(client, "import URLProtectionSpace from '../../types/URLProtectionSpace';",
           "import URLProtectionSpace from '../../types/URLProtectionSpace';\nimport FluxdoWebViewSecurity from '../../FluxdoWebViewSecurity';")
    legacy = '''  onSslErrorEventReceive = (event: OnSslErrorEventReceiveEvent) => {
    try {
      Log.d(TAG, 'onSslErrorEventReceive=' + JSON.stringify(event))
      this.onReceivedSslErrorEventReceive(event.handler, event.error)
    } catch (e) {
      Log.e(TAG, 'onSslErrorEventReceive error: ' + JSON.stringify(e));
    }
  }
'''
    change(client, legacy, '''  onSslErrorEventReceive = (event: OnSslErrorEventReceiveEvent) => {
    event.handler.handleCancel();
  }
''' + SSL_CALLBACK)
    # Remove the old URL-from-controller implementation so no alternate caller can use it.
    original = client.read_text(encoding='utf-8')
    start = original.find('  private onReceivedSslErrorEventReceive(')
    end = original.find('  private onReceivedClientAuthenticationRequest(', start)
    if start >= 0 and end > start:
        change(client, original[start:end], '')
    elif 'private onReceivedSslErrorEventReceive(' in changes[client]:
        raise AssertionError('Unexpected legacy TLS implementation')

    space = plugin / PLUGIN / 'types/URLProtectionSpace.ets'
    change(space, '  private sslError: SslError | null = null',
           '  private sslError: SslError | null = null\n  private sslCertificateDer: Uint8Array | null = null')
    change(space, 'sslCertificate?: cert.X509Cert | null, sslError?: SslError | null)',
           'sslCertificate?: cert.X509Cert | null, sslError?: SslError | null, sslCertificateDer?: Uint8Array)')
    change(space, '    if (sslError) {', '    if (sslCertificateDer != undefined) this.sslCertificateDer = sslCertificateDer;\n    if (sslError != undefined && sslError != null) {')
    change(space, "    urlProtectionSpaceMap.set('sslCertificate',  await SslCertificateExt.toMap(this.sslCertificate));\n    urlProtectionSpaceMap.set('sslCertificate', null);",
           '''    if (this.sslCertificateDer != null) {
      const certificate: Map<string, Any> = new Map<string, Any>();
      certificate.set('x509Certificate', this.sslCertificateDer);
      urlProtectionSpaceMap.set('sslCertificate', certificate);
    } else {
      urlProtectionSpaceMap.set('sslCertificate', await SslCertificateExt.toMap(this.sslCertificate));
    }''')
    change(space, "    urlProtectionSpaceMap.set('sslError', SslErrorExt.toMap(this.sslError));\n    urlProtectionSpaceMap.set('sslError', null);",
           "    // Preserve the actual failing request error.\n    urlProtectionSpaceMap.set('sslError', SslErrorExt.toMap(this.sslError));")
    error = plugin / PLUGIN / 'types/SslErrorExt.ets'
    change(error, '    if (sslError == null) {', '    if (sslError == null || sslError == undefined) {')
    enums = interface / 'lib/src/types/ssl_error_type.g.dart'
    for native in [2, 3, 4, 5]:
        before = f'      case TargetPlatform.android:\n        return {native};'
        after = f'      case TargetPlatform.android:\n      case TargetPlatform.ohos:\n        return {native};'
        change(enums, before, after)
    cookie = plugin / PLUGIN / 'MyCookieManager.ets'
    change(cookie, "import ChannelResultUtil from './types/ChannelResultUtil';",
           "import ChannelResultUtil from './types/ChannelResultUtil';\nimport FluxdoWebViewSecurity from './FluxdoWebViewSecurity';")
    if COOKIE_RICH_LEGACY in cookie.read_text(encoding='utf-8'):
        change(cookie, COOKIE_RICH_LEGACY, COOKIE_RICH)
    else:
        change(cookie, '    // fetchCookieSync may throw BusinessError; callers must catch (onMethodCall does).', COOKIE_RICH)
    proxy = plugin / PLUGIN / 'proxy/ProxyManager.ets'
    change(proxy, "import ProxyRuleExt from './ProxyRuleExt';",
           "import ProxyRuleExt from './ProxyRuleExt';\nimport FluxdoWebViewSecurity from '../FluxdoWebViewSecurity';")
    change(proxy, "      case 'setProxyOverride':",
           "      case 'supportsFluxdoBoundLeaf':\n        result.success(FluxdoWebViewSecurity.supportsBoundLeaf());\n        break;\n      case 'setProxyOverride':")
    for path, content in changes.items():
        if path.read_text(encoding='utf-8') != content:
            path.write_text(content, encoding='utf-8', newline='\n')
    shutil.copyfile(support, plugin / PLUGIN / 'FluxdoWebViewSecurity.ets')


def verify_locked_webview(lock):
    for name in ['flutter_inappwebview_ohos', 'flutter_inappwebview_platform_interface']:
        block = re.search(r'(?m)^  ' + name + r':\n(?:(?:    .*|\s*)\n)*', lock)
        revision = None if block is None else re.search(
            r'''(?m)^      resolved-ref: (["']?)([0-9a-f]{40})\1\s*$''', block[0])
        if revision is None or revision[2] != WEBVIEW_REV:
            raise AssertionError(f'{name} must resolve to {WEBVIEW_REV}')


def prepare(repo):
    verify_locked_webview((repo / 'pubspec.lock').read_text(encoding='utf-8'))
    roots = [package_root(repo, name) for name in
             ['flutter_inappwebview_ohos', 'flutter_inappwebview_platform_interface']]
    prepare_sources(*roots, repo / 'ohos_support/webview/FluxdoWebViewSecurity.ets')
    print('Prepared pinned OHOS WebView TLS and native cookie metadata')


def self_test(source):
    for quote in ['', '"', "'"]:
        lock = ''.join(f'  {name}:\n    description:\n      resolved-ref: {quote}{WEBVIEW_REV}{quote}\n'
                       for name in ['flutter_inappwebview_ohos', 'flutter_inappwebview_platform_interface'])
        verify_locked_webview(lock)
        try:
            verify_locked_webview(lock.replace(WEBVIEW_REV, '0' * 40, 1))
        except AssertionError:
            pass
        else:
            raise AssertionError('Incorrect source revision accepted')
    if source is None:
        raise AssertionError('--self-test requires --source-root pinned WebView source')
    support = Path(__file__).resolve().parent.parent / 'ohos_support/webview/FluxdoWebViewSecurity.ets'
    with tempfile.TemporaryDirectory() as directory:
        root = Path(directory)
        plugin = root / 'plugin'
        interface = root / 'interface'
        source = source.resolve()
        if os.name == 'nt':
            source = Path('\\\\?\\' + str(source))
        names = ['webview/in_app_webview/WebNodeController.ets',
                 'webview/in_app_webview/InAppWebViewClient.ets',
                 'types/URLProtectionSpace.ets', 'types/SslErrorExt.ets', 'MyCookieManager.ets',
                 'proxy/ProxyManager.ets']
        for name in names:
            target = plugin / PLUGIN / name
            target.parent.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(source / 'flutter_inappwebview_ohos' / PLUGIN / name, target)
        target = interface / 'lib/src/types/ssl_error_type.g.dart'
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(source / 'flutter_inappwebview_platform_interface/lib/src/types/ssl_error_type.g.dart', target)
        manifest = plugin / 'ohos/src/main/module.json5'
        shutil.copyfile(source / 'flutter_inappwebview_ohos/ohos/src/main/module.json5', manifest)
        manifest_before = manifest.read_bytes()
        prepare_sources(plugin, interface, support)
        assert manifest.read_bytes() == manifest_before
        first = {str(p.relative_to(root)): p.read_bytes() for p in root.rglob('*') if p.is_file()}
        prepare_sources(plugin, interface, support)
        assert first == {str(p.relative_to(root)): p.read_bytes() for p in root.rglob('*') if p.is_file()}
        cookie = plugin / PLUGIN / 'MyCookieManager.ets'
        cookie.write_text(cookie.read_text(encoding='utf-8').replace(COOKIE_RICH, COOKIE_RICH_LEGACY), encoding='utf-8')
        prepare_sources(plugin, interface, support)
        assert first == {str(p.relative_to(root)): p.read_bytes() for p in root.rglob('*') if p.is_file()}
        node = plugin / PLUGIN / 'webview/in_app_webview/WebNodeController.ets'
        node.write_text(node.read_text(encoding='utf-8').replace('.onSslErrorEvent(', '.drift('), encoding='utf-8')
        before = {str(p.relative_to(root)): p.read_bytes() for p in root.rglob('*') if p.is_file()}
        try:
            prepare_sources(plugin, interface, support)
        except AssertionError:
            pass
        else:
            raise AssertionError('Source drift accepted')
        assert before == {str(p.relative_to(root)): p.read_bytes() for p in root.rglob('*') if p.is_file()}
    print('WebView preparation: exact-source patch, repeat and atomic drift rejection passed')


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('repo', nargs='?', type=Path, default=Path.cwd())
    parser.add_argument('--self-test', action='store_true')
    parser.add_argument('--source-root', type=Path)
    args = parser.parse_args()
    if args.self_test:
        self_test(args.source_root or package_root(args.repo.resolve(), 'flutter_inappwebview_ohos').parent)
    else:
        prepare(args.repo.resolve())
