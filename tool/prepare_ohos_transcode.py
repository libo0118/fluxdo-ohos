"""OHOS 工程生成后注册系统媒体转码插件，保留其它原生插件。"""

from pathlib import Path
import os
import re
import sys
import tempfile


PLUGIN = "FluxdoTranscodePlugin"
PLUGIN_IMPORT = f"import {PLUGIN} from '../fluxdo/transcode/{PLUGIN}';"
PLUGIN_REGISTER = f"flutterEngine.getPlugins()?.add(new {PLUGIN}());"


def patch_entry(source):
    newline = "\r\n" if "\r\n" in source else "\n"
    registration = re.compile(
        r"(?m)^([ \t]*)GeneratedPluginRegistrant\.registerWith\(flutterEngine\)"
        r"[ \t]*;?[ \t]*(?:\r?\n|$)"
    )
    matches = list(registration.finditer(source))
    if len(matches) != 1:
        raise AssertionError("EntryAbility 必须保留唯一的 GeneratedPluginRegistrant")
    imported = source.count(PLUGIN_IMPORT)
    registered = source.count(PLUGIN_REGISTER)
    if imported or registered:
        if imported != 1 or registered != 1:
            raise AssertionError("已有转码插件注册不完整或重复")
        return source
    match = matches[0]
    original = match.group(0)
    if not original.endswith(("\n", "\r")):
        original += newline
    replacement = original + match.group(1) + PLUGIN_REGISTER + newline
    return PLUGIN_IMPORT + newline + source[:match.start()] + replacement + source[match.end():]


def prepare(repo):
    repo = Path(repo).resolve()
    entry = repo / "ohos/entry/src/main/ets/entryability/EntryAbility.ets"
    native = repo / f"ohos_support/transcode/{PLUGIN}.ets"
    if not native.is_file():
        raise AssertionError("缺少 OHOS 系统转码插件源码")
    native_bytes = native.read_bytes()
    if b"com.fluxdo/media_transcode" not in native_bytes:
        raise AssertionError("转码插件通道合同不符")
    prepared = {
        entry: patch_entry(entry.read_bytes().decode("utf-8")).encode("utf-8"),
        repo / f"ohos/entry/src/main/ets/fluxdo/transcode/{PLUGIN}.ets": native_bytes,
    }
    changed = []
    # 模板全部验证后才开始写入，每个文件使用原子替换。
    for destination, data in prepared.items():
        if destination.is_file() and destination.read_bytes() == data:
            continue
        destination.parent.mkdir(parents=True, exist_ok=True)
        with tempfile.NamedTemporaryFile(dir=destination.parent, delete=False) as temporary:
            temporary.write(data)
            temporary_path = Path(temporary.name)
        try:
            os.replace(temporary_path, destination)
        finally:
            temporary_path.unlink(missing_ok=True)
        changed.append(destination)
    return changed


def self_test():
    with tempfile.TemporaryDirectory(prefix="fluxdo-transcode-") as temporary:
        repo = Path(temporary) / "repo with spaces"
        entry = repo / "ohos/entry/src/main/ets/entryability/EntryAbility.ets"
        entry.parent.mkdir(parents=True)
        source = """import ExistingPlugin from '../fluxdo/ExistingPlugin';
export default class EntryAbility extends FlutterAbility {
  configureFlutterEngine(flutterEngine: FlutterEngine) {
    super.configureFlutterEngine(flutterEngine)
    GeneratedPluginRegistrant.registerWith(flutterEngine)
    flutterEngine.getPlugins()?.add(new ExistingPlugin());
  }
}
""".replace("\n", "\r\n")
        entry.write_bytes(source.encode("utf-8"))
        native = repo / f"ohos_support/transcode/{PLUGIN}.ets"
        native.parent.mkdir(parents=True)
        native.write_text("// com.fluxdo/media_transcode\n", encoding="utf-8")
        assert len(prepare(repo)) == 2
        assert prepare(repo) == []
        patched = entry.read_bytes().decode("utf-8")
        assert patched.count(PLUGIN_IMPORT) == patched.count(PLUGIN_REGISTER) == 1
        assert "new ExistingPlugin()" in patched
        assert patched.count("\r\n") == patched.count("\n")
        assert (repo / f"ohos/entry/src/main/ets/fluxdo/transcode/{PLUGIN}.ets").read_bytes() == native.read_bytes()
        for invalid in ["unexpected template", patched + PLUGIN_REGISTER,
                        patched.replace(PLUGIN_IMPORT, "")]:
            entry.write_bytes(invalid.encode("utf-8"))
            try:
                prepare(repo)
            except AssertionError:
                pass
            else:
                raise AssertionError("模板漂移和重复注册必须拒绝")
            assert entry.read_bytes().decode("utf-8") == invalid
    print("转码准备脚本自检通过：幂等、保留已有插件、CRLF、漂移拒绝")


if __name__ == "__main__":
    if sys.argv[1:] == ["--self-test"]:
        self_test()
    elif len(sys.argv) <= 2:
        root = Path(sys.argv[1]) if len(sys.argv) == 2 else Path.cwd()
        for destination in prepare(root):
            print(f"已准备系统媒体转码：{destination.name}")
    else:
        raise SystemExit("用法：python prepare_ohos_transcode.py [CI 检出目录 | --self-test]")
