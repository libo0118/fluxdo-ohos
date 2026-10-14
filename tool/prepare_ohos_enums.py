#!/usr/bin/env python3
"""仅在 OHOS CI 检出目录中为已确认的平台分支补齐鸿蒙行为。"""

import argparse
import json
from pathlib import Path
import re
from urllib.parse import urljoin, urlparse
from urllib.request import url2pathname


STATEMENT = re.compile(
    r"^(?P<indent>[ \t]*)case TargetPlatform.android:(?P<newline>\r?\n)"
    r"(?P<ohos>(?P=indent)case TargetPlatform.ohos:(?P=newline))?",
    re.MULTILINE,
)
EXPRESSION = re.compile(
    r"^(?P<indent>[ \t]*)TargetPlatform.android"
    r"(?P<ohos>[ \t]*\|\|[ \t]*TargetPlatform.ohos)?"
    r"(?=\s*(?:\|\||=>))",
    re.MULTILINE,
)


def add_ohos(source: str, expected: int) -> str:
    def statement(match: re.Match) -> str:
        return match[0] if match["ohos"] else (
            match[0] + match["indent"] + "case TargetPlatform.ohos:" + match["newline"]
        )

    def expression(match: re.Match) -> str:
        return match[0] if match["ohos"] else match[0] + " || TargetPlatform.ohos"

    source, statements = STATEMENT.subn(statement, source)
    source, expressions = EXPRESSION.subn(expression, source)
    if statements + expressions != expected:
        raise ValueError(
            f"Expected {expected} Android switch branches, found {statements + expressions}"
        )
    return source


def package_root(root: Path, name: str) -> Path:
    config = root / ".dart_tool/package_config.json"
    packages = json.loads(config.read_text(encoding="utf-8"))["packages"]
    matches = [package for package in packages if package["name"] == name]
    if len(matches) != 1:
        raise ValueError(f"Expected one {name} entry in {config}; run flutter pub get first")
    uri = urlparse(urljoin(config.resolve().as_uri(), matches[0]["rootUri"]))
    if uri.scheme != "file" or uri.netloc not in ("", "localhost"):
        raise ValueError(f"Unsupported package root URI: {uri.geturl()}")
    return Path(url2pathname(uri.path)).resolve()


def prepare(root: Path) -> None:
    math = package_root(root, "flutter_math_fork")
    # shortcut: 仅修复编译器报告的分支，上游新增分支时扩展此列表。
    targets = [
        (root / "packages/common_ui/lib/src/dismissible_popup_menu.dart", 1),
        (root / "packages/fluxdo_render/lib/src/widget/selection_content_layer.dart", 1),
        (math / "lib/src/widgets/selectable.dart", 2),
        (math / "lib/src/render/layout/line_editable.dart", 1),
        (math / "lib/src/widgets/selection/gesture_detector_builder_selectable.dart", 1),
    ]
    edits = []
    for path, expected in targets:
        original = path.read_bytes()
        try:
            updated = add_ohos(original.decode("utf-8"), expected).encode("utf-8")
        except ValueError as error:
            raise ValueError(f"{path}: {error}") from error
        edits.append((path, original, updated))
    for path, original, updated in edits:
        if path.read_bytes() != original:
            raise RuntimeError(f"Source changed during preparation: {path}")
        if updated != original:
            path.write_bytes(updated)
            print(f"Added OHOS Android behavior: {path}")


def self_test() -> None:
    statement = (
        "switch (platform) {\r\n"
        "  case TargetPlatform.android:\r\n"
        "  case TargetPlatform.fuchsia:\r\n"
        "    useMaterialSelection();\r\n"
        "}\r\n"
        "// case TargetPlatform.android:\r\n"
    )
    expected = statement.replace(
        "  case TargetPlatform.android:\r\n",
        "  case TargetPlatform.android:\r\n  case TargetPlatform.ohos:\r\n",
    )
    assert add_ohos(statement, 1) == expected
    assert add_ohos(expected, 1) == expected
    expression = (
        "switch (platform) {\n"
        "  TargetPlatform.android || TargetPlatform.fuchsia => mobile,\n"
        "  TargetPlatform.iOS => cupertino,\n"
        "};\n"
    )
    expected = expression.replace(
        "TargetPlatform.android", "TargetPlatform.android || TargetPlatform.ohos"
    )
    assert add_ohos(expression, 1) == expected
    assert add_ohos(expected, 1) == expected
    combined = add_ohos(statement + expression, 2)
    assert add_ohos(combined, 2) == combined
    try:
        add_ohos(statement, 2)
    except ValueError:
        pass
    else:
        raise AssertionError("Source drift was not rejected")
    print("OHOS enum preparation self-test passed")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("root", nargs="?", type=Path, default=Path.cwd())
    parser.add_argument("--self-test", action="store_true")
    args = parser.parse_args()
    if args.self_test:
        self_test()
    else:
        prepare(args.root.resolve())
