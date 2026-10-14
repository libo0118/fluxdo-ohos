"""仅在 OHOS CI 检出目录中适配 Registry 3 和 WebView 6.1.5。"""

from pathlib import Path
import sys


REPLACEMENTS = {
    "lib/services/windows_protocol_registrar_io.dart": [
        ("Registry.currentUser.createKey(", "CURRENT_USER.create("),
        ("""    key.createValue(
      RegistryValue.string('', 'URL:$scheme Protocol'),
    );""", "    key.setValue('', RegistryValue.string('URL:$scheme Protocol'));"),
        ("key.createValue(const RegistryValue.string('URL Protocol', ''));",
         "key.setValue('URL Protocol', const RegistryValue.string(''));"),
        (r"key.createKey('shell\\open\\command')", r"key.create('shell\\open\\command')"),
        ("""cmdKey.createValue(RegistryValue.string('', '"$appPath" "%1"'));""",
         """cmdKey.setValue('', RegistryValue.string('"$appPath" "%1"'));"""),
    ],
    "lib/services/network/system_proxy_detector.dart": [
        ("Registry.openPath(RegistryHive.currentUser, path: _keyPath)", "CURRENT_USER.open(_keyPath)"),
        ("key.getIntValue('ProxyEnable')", "key.getInt('ProxyEnable')"),
        ("key.getStringValue('ProxyServer')", "key.getString('ProxyServer')"),
        ("key.getStringValue('AutoConfigURL')", "key.getString('AutoConfigURL')"),
    ],
    "lib/services/webview_settings.dart": [
        ("await controller.setMemoryUsageTargetLevel(MemoryUsageTargetLevel.LOW);",
         "return; // shortcut: OHOS WebView 6.1.5 缺少该接口，升级插件后恢复。"),
    ],
    "lib/pages/webview_page.dart": [
        ("""                            onDownloadStarting: (controller, request) {
                              final url = request.url.toString();
                              ref
                                  .read(downloadProvider.notifier)
                                  .startDownload(
                                    url: url,
                                    suggestedFilename:
                                        request.suggestedFilename,
                                    mimeType: request.mimeType,
                                    contentLength: request.contentLength,
                                  );
                              return null;
                            },""",
         """                            onDownloadStartRequest: (controller, request) {
                              final url = request.url.toString();
                              ref
                                  .read(downloadProvider.notifier)
                                  .startDownload(
                                    url: url,
                                    suggestedFilename:
                                        request.suggestedFilename,
                                    mimeType: request.mimeType,
                                    contentLength: request.contentLength,
                                  );
                            },"""),
    ],
}


def replace_once(content, before, after, relative_path):
    newline = "\r\n" if b"\r\n" in content else "\n"
    before = before.replace("\n", newline).encode("utf-8")
    after = after.replace("\n", newline).encode("utf-8")
    count = content.count(before)
    if count != 1:
        raise AssertionError(f"{relative_path}: 应精确匹配 1 处，实际为 {count} 处")
    return content.replace(before, after, 1)


if __name__ == "__main__":
    if len(sys.argv) > 2:
        raise SystemExit("用法：python prepare_ohos_app.py [CI 检出目录]")
    repo = Path(sys.argv[1]) if len(sys.argv) == 2 else Path.cwd()
    prepared = {}
    # 先验证全部匹配，避免上游变更导致只写入部分适配。
    for relative_path, replacements in REPLACEMENTS.items():
        path = repo / relative_path
        content = path.read_bytes()
        for before, after in replacements:
            content = replace_once(content, before, after, relative_path)
        prepared[path] = content
    for path, content in prepared.items():
        path.write_bytes(content)
        print(f"已准备 {path.relative_to(repo)}")
