"""在 pub get 和 OHOS 工程生成后，接入系统安全存储；重复执行保持幂等。"""

import json
from pathlib import Path
import re
import sys
import tempfile
from urllib.parse import quote, urljoin, urlsplit
from urllib.request import url2pathname


DART_MARKER = "// OHOS: 使用系统 AssetStore 密钥和原生 AES-GCM 存储。"
PLUGIN_IMPORT = (
    "import FluxdoSecureStoragePlugin from "
    "'../fluxdo/secure_storage/FluxdoSecureStoragePlugin';"
)
PLUGIN_REGISTER = (
    "flutterEngine.getPlugins()?.add(new FluxdoSecureStoragePlugin());"
)


def storage_package_source(repo):
    config_path = repo / ".dart_tool/package_config.json"
    config = json.loads(config_path.read_text(encoding="utf-8"))
    packages = [
        package for package in config["packages"]
        if package["name"] == "flutter_secure_storage"
    ]
    if len(packages) != 1:
        raise AssertionError("package_config 必须包含唯一的 flutter_secure_storage")
    package = packages[0]
    root_uri = urljoin(config_path.resolve().as_uri(), package["rootUri"])
    library_uri = urljoin(
        root_uri.rstrip("/") + "/", package.get("packageUri", "lib/")
    )
    source_uri = urlsplit(urljoin(library_uri.rstrip("/") + "/", "flutter_secure_storage.dart"))
    if source_uri.scheme != "file" or source_uri.netloc not in ("", "localhost"):
        raise AssertionError("flutter_secure_storage 必须位于本地 pub package")
    return Path(url2pathname(source_uri.path))


def patch_options(source):
    newline = "\r\n" if "\r\n" in source else "\n"
    branch = "} else if (defaultTargetPlatform == TargetPlatform.linux) {"
    ohos_branch = (
        "} else if (defaultTargetPlatform.name == 'ohos') {" + newline
        + "      " + DART_MARKER + newline
        + "      return const <String, String>{};" + newline
        + "    " + branch
    )
    if DART_MARKER in source:
        if source.count(DART_MARKER) != 1 or ohos_branch not in source:
            raise AssertionError("已有安全存储 OHOS 补丁格式不符")
        return source
    if source.count(branch) != 1:
        raise AssertionError("官方 FlutterSecureStorage options 选择器已改变")
    return source.replace(branch, ohos_branch)


def patch_entry(source):
    newline = "\r\n" if "\r\n" in source else "\n"
    if PLUGIN_IMPORT not in source:
        source = PLUGIN_IMPORT + newline + source
    elif source.count(PLUGIN_IMPORT) != 1:
        raise AssertionError("EntryAbility 安全存储插件 import 重复")
    if PLUGIN_REGISTER in source:
        if source.count(PLUGIN_REGISTER) != 1:
            raise AssertionError("EntryAbility 安全存储插件注册重复")
        return source
    registration = re.compile(
        r"(?m)^([ \t]*)GeneratedPluginRegistrant\.registerWith\(flutterEngine\)"
        r"[ \t]*;?[ \t]*(?:\r?\n|$)"
    )
    matches = list(registration.finditer(source))
    if len(matches) != 1:
        raise AssertionError("EntryAbility 必须保留唯一的 GeneratedPluginRegistrant")
    match = matches[0]
    original = match.group(0)
    if not original.endswith(("\n", "\r")):
        original += newline
    replacement = original + match.group(1) + PLUGIN_REGISTER + newline
    return source[:match.start()] + replacement + source[match.end():]


def prepare(repo):
    repo = Path(repo).resolve()
    package_source = storage_package_source(repo)
    entry = repo / "ohos/entry/src/main/ets/entryability/EntryAbility.ets"
    native_directory = repo / "ohos_support/secure_storage"
    native_sources = sorted(native_directory.glob("*.ets"))
    if not native_sources or not (native_directory / "FluxdoSecureStoragePlugin.ets").is_file():
        raise AssertionError("缺少 OHOS 系统安全存储原生源码")
    # 所有输入验证通过后再写，防止不兼容模板导致半次接线。
    prepared = {
        package_source: patch_options(package_source.read_bytes().decode("utf-8")).encode("utf-8"),
        entry: patch_entry(entry.read_bytes().decode("utf-8")).encode("utf-8"),
    }
    for source in native_sources:
        destination = repo / "ohos/entry/src/main/ets/fluxdo/secure_storage" / source.name
        prepared[destination] = source.read_bytes()
    changed = []
    for destination, data in prepared.items():
        if destination.is_file() and destination.read_bytes() == data:
            continue
        destination.parent.mkdir(parents=True, exist_ok=True)
        destination.write_bytes(data)
        changed.append(destination)
    return changed


def self_test():
    dart_source = """Map<String, String> _selectOptions() {
    if (kIsWeb) {
      return {};
    } else if (defaultTargetPlatform == TargetPlatform.linux) {
      return {};
    } else {
      throw UnsupportedError('unsupported');
    }
  }
"""
    entry_source = """import ExistingNetworkPlugin from '../network/ExistingNetworkPlugin';
export default class EntryAbility extends FlutterAbility {
  configureFlutterEngine(flutterEngine: FlutterEngine) {
    super.configureFlutterEngine(flutterEngine)
    GeneratedPluginRegistrant.registerWith(flutterEngine)
    flutterEngine.getPlugins()?.add(new ExistingNetworkPlugin())
  }
}
"""
    with tempfile.TemporaryDirectory(prefix="fluxdo-storage-") as temporary:
        base = Path(temporary)
        repo = base / "repo with spaces"
        package = base / "package with spaces" / "lib"
        package.mkdir(parents=True)
        package_source = package / "flutter_secure_storage.dart"
        package_source.write_text(dart_source, encoding="utf-8")
        config = repo / ".dart_tool/package_config.json"
        config.parent.mkdir(parents=True)
        config.write_text(json.dumps({"packages": [{
            "name": "flutter_secure_storage",
            "rootUri": quote("../../package with spaces"),
            "packageUri": "lib/",
        }]}), encoding="utf-8")
        entry = repo / "ohos/entry/src/main/ets/entryability/EntryAbility.ets"
        entry.parent.mkdir(parents=True)
        entry.write_bytes(entry_source.replace("\n", "\r\n").encode("utf-8"))
        native = repo / "ohos_support/secure_storage/FluxdoSecureStoragePlugin.ets"
        native.parent.mkdir(parents=True)
        native.write_text("// 原生源码测试夹具\n", encoding="utf-8")
        assert storage_package_source(repo).resolve() == package_source.resolve()
        assert len(prepare(repo)) == 3
        assert prepare(repo) == []
        patched_entry = entry.read_bytes().decode("utf-8")
        assert patched_entry.count(PLUGIN_REGISTER) == 1
        assert "new ExistingNetworkPlugin()" in patched_entry
        assert patched_entry.count("\r\n") == patched_entry.count("\n")
        assert (repo / "ohos/entry/src/main/ets/fluxdo/secure_storage/FluxdoSecureStoragePlugin.ets").read_bytes() == native.read_bytes()
        config_data = json.loads(config.read_text(encoding="utf-8"))
        config_data["packages"][0]["rootUri"] = package.parent.as_uri()
        config.write_text(json.dumps(config_data), encoding="utf-8")
        assert storage_package_source(repo).resolve() == package_source.resolve()
        package_source.write_text(dart_source, encoding="utf-8")
        entry.write_text("模板已变，缺少注册器\n", encoding="utf-8")
        try:
            prepare(repo)
        except AssertionError:
            pass
        else:
            raise AssertionError("模板漂移必须拒绝")
        assert package_source.read_text(encoding="utf-8") == dart_source
    print("安全存储准备脚本自检通过")


if __name__ == "__main__":
    if sys.argv[1:] == ["--self-test"]:
        self_test()
    elif len(sys.argv) <= 2:
        root = Path(sys.argv[1]) if len(sys.argv) == 2 else Path.cwd()
        for destination in prepare(root):
            print(f"已准备系统安全存储：{destination.name}")
    else:
        raise SystemExit("用法：python prepare_ohos_storage.py [CI 检出目录 | --self-test]")
