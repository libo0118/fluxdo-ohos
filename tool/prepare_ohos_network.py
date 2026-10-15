"""仅在 OHOS CI 检出目录和已解析的 rhttp pub 缓存中准备网络依赖。"""

import argparse
import json
from pathlib import Path
import re
import subprocess
import shutil
import tempfile
from urllib.parse import unquote, urlparse
from urllib.request import url2pathname


DOH_REV = "03e0757336ee72f5800d6cb630fc8377a7cfba68"
RHTTP_REV = "02eb4114b57c108e76a9ed526b6118bc048b5604"
FRB_VERSION = "2.12.0"
RHTTP_DEPENDENCY = """  rhttp:
    git:
      url: https://github.com/Lingyan000/rhttp_plus.git
      path: rhttp
"""
RHTTP_IMPORTS = """import 'dart:async';
import 'dart:io';

import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated.dart'
    show ExternalLibrary;"""
RHTTP_INIT = """    await RustLib.init(
      externalLibrary: Platform.operatingSystem == 'ohos'
          ? ExternalLibrary.open('librhttp.so')
          : null,"""


def replace_once(content, before, after, label):
    if content.count(after) == 1 and content.count(before) == after.count(before):
        return content
    if content.count(before) != 1:
        raise AssertionError(f"{label}: 需要精确匹配一处，拒绝修改漂移源码")
    return content.replace(before, after, 1)


def verify_doh(repo):
    revision = subprocess.check_output(
        ["git", "-C", str(repo / "core/doh_proxy"), "rev-parse", "HEAD"],
        text=True,
    ).strip()
    if revision != DOH_REV:
        raise AssertionError(f"DoH 提交不匹配：{revision}，应为 {DOH_REV}")


def patch_doh(repo):
    source = repo / "core/doh_proxy"
    patch = repo / "ohos_support/webview/doh-current-leaf.patch"
    command = ["git", "-C", str(source), "apply", "--check"]
    if subprocess.run(command + ["--reverse", str(patch.resolve())], capture_output=True).returncode == 0:
        return
    subprocess.run(command + [str(patch.resolve())], check=True)
    subprocess.run(["git", "-C", str(source), "apply", str(patch.resolve())], check=True)


def prepare_before_pub_get(repo):
    verify_doh(repo)
    patch_doh(repo)
    path = repo / "pubspec.yaml"
    content = path.read_text(encoding="utf-8")
    pinned = RHTTP_DEPENDENCY + f"      ref: {RHTTP_REV}\n"
    prepared = replace_once(content, RHTTP_DEPENDENCY, pinned, str(path))
    if prepared != content:
        path.write_text(prepared, encoding="utf-8")
    print(f"已固定 DoH {DOH_REV} 和 rhttp {RHTTP_REV}")


def rhttp_package(repo):
    config = repo / ".dart_tool/package_config.json"
    packages = json.loads(config.read_text(encoding="utf-8"))["packages"]
    package = next(item for item in packages if item["name"] == "rhttp")
    uri = urlparse(package["rootUri"])
    if uri.scheme not in ("", "file") or uri.netloc not in ("", "localhost"):
        raise AssertionError("rhttp 必须解析为本地 pub 包")
    path = Path(url2pathname(uri.path)) if uri.scheme else Path(unquote(uri.path))
    return path.resolve() if uri.scheme else (config.parent / path).resolve()


def verify_rhttp(repo, package):
    lock = (repo / "pubspec.lock").read_text(encoding="utf-8")
    block = re.search(r"(?m)^  rhttp:\n(?:(?:    .*|\s*)\n)*", lock)
    if block is None or f'resolved-ref: "{RHTTP_REV}"' not in block[0]:
        raise AssertionError("pubspec.lock 中的 rhttp 提交不匹配")
    manifest = (package / "rust/Cargo.toml").read_text(encoding="utf-8")
    generated = (package / "lib/src/rust/frb_generated.dart").read_text(encoding="utf-8")
    if f'version = "={FRB_VERSION}"' not in manifest:
        raise AssertionError("rhttp Rust 的 FRB 版本发生变化")
    if f"String get codegenVersion => '{FRB_VERSION}';" not in generated:
        raise AssertionError("rhttp Dart 的 FRB 版本发生变化")
    if "stem: 'rhttp'" not in generated:
        raise AssertionError("rhttp 原生库名称发生变化")
    if not (package / "rust/Cargo.lock").is_file():
        raise AssertionError("rhttp 缺少用于 --locked 构建的 Cargo.lock")


def prepare_after_pub_get(repo):
    verify_doh(repo)
    patch_doh(repo)
    package = rhttp_package(repo)
    verify_rhttp(repo, package)
    path = package / "lib/src/rhttp.dart"
    content = path.read_text(encoding="utf-8")
    # 先验证所有匹配，再一次写入；网络请求、异常处理及 FRB 校验保持原逻辑。
    prepared = content
    if RHTTP_IMPORTS not in prepared:
        prepared = replace_once(prepared, "import 'dart:async';", RHTTP_IMPORTS, str(path))
    if RHTTP_INIT not in prepared:
        prepared = replace_once(prepared, "    await RustLib.init(", RHTTP_INIT, str(path))
    if prepared != content:
        path.write_text(prepared, encoding="utf-8")
    print(f"已配置 OHOS rhttp 加载入口：{package}")


def self_test(doh_source=None):
    original = "import 'dart:async';\n    await RustLib.init(\n      forceSameCodegenVersion: false,\n    );\n"
    patched = replace_once(original, "import 'dart:async';", RHTTP_IMPORTS, "测试 import")
    patched = replace_once(patched, "    await RustLib.init(", RHTTP_INIT, "测试 init")
    assert "ExternalLibrary.open('librhttp.so')" in patched
    assert "forceSameCodegenVersion: false," in patched
    pinned = RHTTP_DEPENDENCY + f"      ref: {RHTTP_REV}\n"
    assert replace_once(RHTTP_DEPENDENCY, RHTTP_DEPENDENCY, pinned, "测试 pin") == pinned
    # 重复执行不重复注入；上游漂移时必须失败，不能部分写入。
    assert replace_once(pinned, RHTTP_DEPENDENCY, pinned, "测试幂等") == pinned
    try:
        replace_once("漂移源码", RHTTP_DEPENDENCY, pinned, "测试拒绝")
    except AssertionError:
        pass
    else:
        raise AssertionError("漂移源码未被拒绝")
    assert r"libdoh_proxy.so" in (Path(__file__).resolve().parent.parent / "lib/services/network/doh_proxy/doh_proxy_ffi.dart").read_text(encoding="utf-8")
    if doh_source is not None:
        with tempfile.TemporaryDirectory() as directory:
            repo = Path(directory)
            source = repo / 'core/doh_proxy'
            source.mkdir(parents=True)
            for name in ['cert.rs', 'proxy.rs', 'ffi.rs']:
                (source / 'src').mkdir(exist_ok=True)
                shutil.copyfile(doh_source / 'src' / name, source / 'src' / name)
            patch = repo / 'ohos_support/webview/doh-current-leaf.patch'
            patch.parent.mkdir(parents=True)
            shutil.copyfile(Path(__file__).resolve().parent.parent / 'ohos_support/webview/doh-current-leaf.patch', patch)
            patch_doh(repo)
            first = {name: (source / 'src' / name).read_bytes() for name in ['cert.rs', 'proxy.rs', 'ffi.rs']}
            patch_doh(repo)
            assert first == {name: (source / 'src' / name).read_bytes() for name in first}
            path = source / 'src/cert.rs'
            path.write_text(path.read_text(encoding='utf-8').replace('matches_cached_leaf', 'drift'), encoding='utf-8')
            before = {name: (source / 'src' / name).read_bytes() for name in first}
            try:
                patch_doh(repo)
            except subprocess.CalledProcessError:
                pass
            else:
                raise AssertionError('Rust patch source drift accepted')
            assert before == {name: (source / 'src' / name).read_bytes() for name in first}
        print('Rust actual-source patch: repeat and atomic drift rejection passed')
    print("网络准备脚本自检通过")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--stage", choices=("before-pub-get", "after-pub-get", "rhttp-path"))
    parser.add_argument("--repo", type=Path, default=Path.cwd())
    parser.add_argument("--self-test", action="store_true")
    parser.add_argument("--doh-source", type=Path)
    args = parser.parse_args()
    if args.self_test:
        self_test(args.doh_source)
    elif args.stage == "before-pub-get":
        prepare_before_pub_get(args.repo.resolve())
    elif args.stage == "after-pub-get":
        prepare_after_pub_get(args.repo.resolve())
    elif args.stage == "rhttp-path":
        package = rhttp_package(args.repo.resolve())
        verify_rhttp(args.repo.resolve(), package)
        print(package)
    else:
        parser.error("需要 --stage 或 --self-test")
