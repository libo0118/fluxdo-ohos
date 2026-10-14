"""生成工程后接入真实 OHOS 通知与 Want 生命周期；拒绝模板漂移。"""
from pathlib import Path
import re
import sys
import tempfile

PLUGIN_IMPORT = "import FluxdoNotificationsPlugin from '../fluxdo/notifications/FluxdoNotificationsPlugin';"
WANT_IMPORT = "import OhosNotificationWant from '@ohos.app.ability.Want';"
CONSTANT_IMPORT = "import OhosNotificationAbilityConstant from '@ohos.app.ability.AbilityConstant';"
BINDING = "FluxdoNotificationsPlugin.abilityContext = this.context;"
REGISTER = "flutterEngine.getPlugins()?.add(new FluxdoNotificationsPlugin());"
WANT_HOOK = "FluxdoNotificationsPlugin.receiveWant(want);"


def lifecycle(source, name, newline):
    marker = f"// Fluxdo OHOS notification {name}."
    hook = f"    {WANT_HOOK} {marker}"
    if marker in source:
        if source.count(marker) != 1 or WANT_HOOK + " " + marker not in source:
            raise AssertionError(f"已有通知 {name} 补丁不完整")
        return source
    method = re.compile(r"(?m)^\s*" + name + r"\s*\(")
    methods = list(method.finditer(source))
    if methods:
        if len(methods) != 1:
            raise AssertionError(f"EntryAbility {name} 方法重复")
        call = re.compile(r"(?m)^([ \t]*)super\." + name + r"\(want,\s*launchParam\)[ \t]*;?[ \t]*(?:\r?\n|$)")
        calls = list(call.finditer(source))
        if len(calls) != 1 or calls[0].start() < methods[0].start():
            raise AssertionError(f"EntryAbility {name} 必须保留标准 super 生命周期")
        match = calls[0]
        hook = match.group(1) + WANT_HOOK + " " + marker + newline
        return source[:match.end()] + hook + source[match.end():]
    end = re.search(r"\}\s*$", source)
    if end is None:
        raise AssertionError("EntryAbility class 缺少结束括号")
    added = newline + f"  {name}(want: OhosNotificationWant, launchParam: OhosNotificationAbilityConstant.LaunchParam): void {{" + newline
    added += f"    super.{name}(want, launchParam);" + newline + hook + newline + "  }" + newline
    return source[:end.start()] + added + source[end.start():]


def patch_entry(source):
    newline = "\r\n" if "\r\n" in source else "\n"
    if source.count("extends FlutterAbility") != 1:
        raise AssertionError("必须保留 FlutterAbility 基类")
    for line in (PLUGIN_IMPORT, WANT_IMPORT, CONSTANT_IMPORT):
        if line not in source:
            source = line + newline + source
        elif source.count(line) != 1:
            raise AssertionError("通知插件 import 重复")
    anchor = re.compile(r"(?m)^([ \t]*)GeneratedPluginRegistrant\.registerWith\(flutterEngine\)[ \t]*;?[ \t]*(?:\r?\n|$)")
    matches = list(anchor.finditer(source))
    if len(matches) != 1:
        raise AssertionError("必须保留唯一 GeneratedPluginRegistrant")
    if BINDING in source or REGISTER in source:
        if source.count(BINDING) != 1 or source.count(REGISTER) != 1:
            raise AssertionError("已有通知注册补丁不完整")
    else:
        match = matches[0]
        addition = match.group(1) + BINDING + newline + match.group(1) + REGISTER + newline
        source = source[:match.end()] + addition + source[match.end():]
    source = lifecycle(source, "onCreate", newline)
    return lifecycle(source, "onNewWant", newline)


def prepare(repo):
    repo = Path(repo).resolve()
    entry = repo / "ohos/entry/src/main/ets/entryability/EntryAbility.ets"
    native = repo / "ohos_support/notifications/FluxdoNotificationsPlugin.ets"
    destination = repo / "ohos/entry/src/main/ets/fluxdo/notifications/FluxdoNotificationsPlugin.ets"
    prepared = {entry: patch_entry(entry.read_bytes().decode("utf-8")).encode("utf-8"), destination: native.read_bytes()}
    changed = []
    for path, data in prepared.items():
        if path.is_file() and path.read_bytes() == data:
            continue
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(data)
        changed.append(path)
    return changed


def self_test():
    template = """import { FlutterAbility, FlutterEngine } from '@ohos/flutter_ohos';
export default class EntryAbility extends FlutterAbility {
  configureFlutterEngine(flutterEngine: FlutterEngine) {
    super.configureFlutterEngine(flutterEngine);
    GeneratedPluginRegistrant.registerWith(flutterEngine)
    flutterEngine.getPlugins()?.add(new ExistingSecurePlugin());
  }
}
"""
    patched = patch_entry(template.replace("\n", "\r\n"))
    assert patch_entry(patched) == patched
    assert patched.count("\n") == patched.count("\r\n")
    assert "new ExistingSecurePlugin()" in patched
    assert patched.count(WANT_HOOK) == 2
    existing = template.replace("\n}", "\n  onCreate(want: Want, launchParam: AbilityConstant.LaunchParam): void {\n    super.onCreate(want, launchParam);\n    ExistingPlugin.abilityContext = this.context;\n  }\n}")
    patched_existing = patch_entry(existing)
    assert patched_existing.count("onCreate(want:") == 1
    assert "ExistingPlugin.abilityContext = this.context" in patched_existing
    assert patch_entry(patched_existing) == patched_existing
    for invalid in ("changed template", template.replace("GeneratedPluginRegistrant.registerWith(flutterEngine)", ""), existing.replace("super.onCreate(want, launchParam);", "super.onCreate(otherWant, launchParam);")):
        try: patch_entry(invalid)
        except AssertionError: pass
        else: raise AssertionError("模板漂移必须拒绝")
    with tempfile.TemporaryDirectory(prefix="fluxdo-notifications-") as temporary:
        repo = Path(temporary)
        entry = repo / "ohos/entry/src/main/ets/entryability/EntryAbility.ets"
        native = repo / "ohos_support/notifications/FluxdoNotificationsPlugin.ets"
        entry.parent.mkdir(parents=True)
        native.parent.mkdir(parents=True)
        entry.write_bytes(template.encode())
        native.write_text("// test native", encoding="utf-8")
        assert len(prepare(repo)) == 2
        assert prepare(repo) == []
        entry.write_text("changed template", encoding="utf-8")
        native.write_text("// changed", encoding="utf-8")
        try: prepare(repo)
        except AssertionError: pass
        else: raise AssertionError("模板漂移必须先拒绝再写")
        assert (repo / "ohos/entry/src/main/ets/fluxdo/notifications/FluxdoNotificationsPlugin.ets").read_text() == "// test native"
    print("OHOS notification preparation: passed")


if __name__ == '__main__':
    if sys.argv[1:] == ['--self-test']:
        self_test()
    elif len(sys.argv) <= 2:
        for path in prepare(Path(sys.argv[1]) if len(sys.argv) == 2 else Path.cwd()):
            print(f"Prepared OHOS notifications: {path.name}")
    else:
        raise SystemExit('Usage: prepare_ohos_notifications.py [repo | --self-test]')
