"""在 OHOS 工程生成后恢复 Android 原包名、名称和默认图标。"""

import json
from pathlib import Path
import re
import struct
import sys
import xml.etree.ElementTree as ET


ANDROID = "{http://schemas.android.com/apk/res/android}"
JSON5_TOKEN = re.compile(r'"(?:\\.|[^"\\])*"|//[^\r\n]*|/\*[\s\S]*?\*/|,\s*(?=[}\]])')


def read_json(path):
    def strip_token(match):
        token = match.group()
        return token if token.startswith('"') else token[1:] if token.startswith(",") else " "
    return json.loads(JSON5_TOKEN.sub(strip_token, path.read_text(encoding="utf-8")))


def prepare(repo):
    gradle = (repo / "android/app/build.gradle.kts").read_text(encoding="utf-8")
    identifiers = re.findall(r'^\s*applicationId\s*=\s*"([^"\r\n]+)"', gradle, re.MULTILINE)
    assert len(identifiers) == 1, "Android applicationId 应精确匹配一处"
    bundle = identifiers[0]
    assert re.fullmatch(r"(?:[A-Za-z][A-Za-z0-9_]*\.)+[A-Za-z][A-Za-z0-9_]*", bundle)
    application = ET.parse(repo / "android/app/src/main/AndroidManifest.xml").getroot().find("application")
    assert application is not None
    label = application.attrib[ANDROID + "label"]
    assert label and not label.startswith("@"), "名称应是可复制的字面值"
    launchers = []
    for alias in application.findall("activity-alias"):
        if alias.attrib.get(ANDROID + "enabled", "true") != "true":
            continue
        for intent in alias.findall("intent-filter"):
            actions = {item.attrib[ANDROID + "name"] for item in intent.findall("action")}
            categories = {item.attrib[ANDROID + "name"] for item in intent.findall("category")}
            if "android.intent.action.MAIN" in actions and "android.intent.category.LAUNCHER" in categories:
                launchers.append(alias)
    assert len(launchers) == 1, "应有且仅有一个默认启用的 launcher alias"
    icon_name = re.fullmatch(r"@mipmap/([A-Za-z_][A-Za-z0-9_]*)", launchers[0].attrib[ANDROID + "icon"])
    assert icon_name is not None
    icon = (repo / f"android/app/src/main/res/mipmap-xxxhdpi/{icon_name[1]}.png").read_bytes()
    assert icon[:16] == b"\x89PNG\r\n\x1a\n\x00\x00\x00\rIHDR"
    width, height = struct.unpack(">II", icon[16:24])
    assert width == height and width >= 192

    app_path = repo / "ohos/AppScope/app.json5"
    app_config = read_json(app_path)
    app = app_config["app"]
    assert app["icon"] == "$media:app_icon" and app["label"] == "$string:app_name"
    module = read_json(repo / "ohos/entry/src/main/module.json5")["module"]
    abilities = [item for item in module["abilities"] if item["name"] == module["mainElement"]]
    assert module["type"] == "entry" and len(abilities) == 1
    assert abilities[0]["icon"] == "$media:icon"
    assert abilities[0]["startWindowIcon"] == "$media:icon"
    assert abilities[0]["label"] == "$string:EntryAbility_label"
    app["bundleName"] = bundle
    app["vendor"] = "1molchuan"
    prepared = {app_path: app_config}
    for relative, resource in (
        ("ohos/AppScope/resources/base/element/string.json", "app_name"),
        ("ohos/entry/src/main/resources/base/element/string.json", "EntryAbility_label"),
    ):
        path = repo / relative
        data = read_json(path)
        entries = [entry for entry in data["string"] if entry["name"] == resource]
        assert len(entries) == 1
        entries[0]["value"] = label
        prepared[path] = data
    icon_targets = [
        repo / "ohos/AppScope/resources/base/media/app_icon.png",
        repo / "ohos/entry/src/main/resources/base/media/icon.png",
    ]
    assert all(path.is_file() for path in icon_targets)
    # 验证全部模板引用后再写，权限、ability 和业务绑定不变。
    for path, data in prepared.items():
        newline = "\r\n" if b"\r\n" in path.read_bytes() else "\n"
        text = (json.dumps(data, ensure_ascii=False, indent=2) + "\n").replace("\n", newline)
        path.write_bytes(text.encode("utf-8"))
    for path in icon_targets:
        path.write_bytes(icon)
    print(f"已恢复 {bundle} / {label} / {icon_name[1]} ({width}x{height})")


if __name__ == "__main__":
    if len(sys.argv) > 2:
        raise SystemExit("用法：python prepare_ohos_identity.py [检出目录]")
    prepare(Path(sys.argv[1]) if len(sys.argv) == 2 else Path.cwd())
