"""仅在 OHOS CI 检出目录中适配 Registry 3 和 WebView 6.1.5。"""

from pathlib import Path
import sys


REPLACEMENTS = {
    "lib/utils/share_utils.dart": [
        ("""    final outputPath = await FilePicker.platform.saveFile(
      dialogTitle: S.current.share_selectSaveLocation,
      fileName: fileName,
      type: ext.isNotEmpty ? FileType.custom : FileType.any,
      allowedExtensions: ext.isNotEmpty ? [ext] : null,
    );

    if (outputPath == null) {
      return const ShareOutcome(shared: false);
    }

    try {
      final sourceFile = File(file.path);
      await sourceFile.copy(outputPath);""",
         """    try {
      final outputPath = await FilePicker.platform.saveFile(
        dialogTitle: S.current.share_selectSaveLocation,
        fileName: fileName,
        bytes: await File(file.path).readAsBytes(),
        type: ext.isNotEmpty ? FileType.custom : FileType.any,
        allowedExtensions: ext.isNotEmpty ? [ext] : null,
      );
      if (outputPath == null) {
        return const ShareOutcome(shared: false);
      }"""),
    ],
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


def replace_once(content, before, after, relative_path, expected=1):
    newline = "\r\n" if b"\r\n" in content else "\n"
    before = before.replace("\n", newline).encode("utf-8")
    after = after.replace("\n", newline).encode("utf-8")
    count = content.count(before)
    if count != expected:
        raise AssertionError(f"{relative_path}: 应精确匹配 {expected} 处，实际为 {count} 处")
    return content.replace(before, after)


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
    # FilePicker 12 改为静态 API 且默认多选，保留原有入口的单选语义。
    picker_sites = {
        "lib/pages/data_management_page.dart": (1, "pickFiles", True),
        "lib/utils/share_utils.dart": (2, "saveFile", False),
        "lib/pages/chat/channel/_chat_composer.dart": (1, "pickFiles", False),
        "lib/widgets/markdown_editor/rich_composer/rich_composer_editor.dart": (2, "pickFiles", True),
        "lib/widgets/markdown_editor/markdown_toolbar.dart": (1, "pickFiles", True),
        "lib/widgets/markdown_editor/media_upload_helper.dart": (1, "pickFiles", True),
    }
    for relative_path, (expected, method, single) in picker_sites.items():
        path = repo / relative_path
        replacement = f"FilePicker.{method}(" + ("allowMultiple: false, " if single else "")
        content = prepared[path] if path in prepared else path.read_bytes()
        prepared[path] = replace_once(
            content, f"FilePicker.platform.{method}(", replacement,
            relative_path, expected,
        )
    for path, content in prepared.items():
        path.write_bytes(content)
        print(f"已准备 {path.relative_to(repo)}")
