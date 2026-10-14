"""固定真实图像解码源码，准备 OHOS loader；不改帧调度或退化为静态图。"""

import argparse
import hashlib
import json
from pathlib import Path, PurePosixPath
import re
import shutil
import tempfile
from urllib.parse import urljoin, urlsplit
from urllib.request import Request, url2pathname, urlopen
import zipfile


VERSIONS = {"native_animated_image": "0.3.4", "flutter_avif": "3.1.0", "flutter_avif_platform_interface": "3.1.0"}
MARKER = "  # Fluxdo OHOS 原生动态图像及 AVIF。\n"


def replace_once(source, before, after):
    if after in source:
        if source.count(after) != 1:
            raise AssertionError("图像补丁重复")
        return source
    if source.count(before) != 1:
        raise AssertionError(f"图像上游模板漂移：{before[:80]!r}")
    return source.replace(before, after)


def patch_dependencies(source):
    source = source.replace("\r\n", "\n")
    block = MARKER + "".join(f"  {name}: {version}\n" for name, version in VERSIONS.items())
    if MARKER in source:
        if source.count(MARKER) != 1 or block not in source:
            raise AssertionError("已有图像 override 与固定版本不同")
        return source
    match = re.search(r"(?m)^dependency_overrides:\n", source)
    if match is None:
        return source.rstrip() + "\n\ndependency_overrides:\n" + block
    tail = source[match.end():]
    end = re.search(r"(?m)^[^ \t#\n].*:", tail)
    section = tail[:end.start()] if end else tail
    if any(re.search(rf"(?m)^  {name}:", section) for name in VERSIONS):
        raise AssertionError("图像 override 已存在，必须先核对其来源")
    return source[:match.end()] + block + source[match.end():]


def package_root(repo, name):
    config_path = repo / ".dart_tool/package_config.json"
    config = json.loads(config_path.read_text(encoding="utf-8"))
    matches = [item for item in config["packages"] if item["name"] == name]
    if len(matches) != 1:
        raise AssertionError(f"必须解析唯一的 {name}")
    uri = urlsplit(urljoin(config_path.resolve().as_uri(), matches[0]["rootUri"]))
    if uri.scheme != "file" or uri.netloc not in ("", "localhost"):
        raise AssertionError("pub package 必须位于本地")
    return Path(url2pathname(uri.path))


def patch_animated(source):
    return replace_once(source.replace("\r\n", "\n"),
        "  if (Platform.isAndroid || Platform.isLinux) {",
        "  if (Platform.isAndroid || Platform.isLinux || Platform.operatingSystem == 'ohos') {")


def patch_avif(source):
    source = source.replace("\r\n", "\n")
    source = replace_once(source, "import 'dart:typed_data';",
        "import 'dart:typed_data';\nimport 'ohos_loader_stub.dart'\n    if (dart.library.io) 'ohos_loader_io.dart' as ohos;")
    return replace_once(source, "  static late final FlutterAvif api;",
        "  static late final FlutterAvif _registeredApi;\n"
        "  static FlutterAvif get api => ohos.ohosApi ?? _registeredApi;\n"
        "  static set api(FlutterAvif value) { _registeredApi = value; }")


def write_prepared(prepared):
    changed = []
    for path, data in prepared.items():
        if path.is_file() and path.read_bytes() == data:
            continue
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(data)
        changed.append(path)
    return changed


def prepare(repo, stage):
    repo = Path(repo).resolve()
    if stage == "before-pub-get":
        # pubspec_overrides.yaml 替换整个 overrides 节，因此只改实际生效的文件。
        path = repo / "pubspec_overrides.yaml"
        if not path.is_file():
            path = repo / "pubspec.yaml"
        return write_prepared({path: patch_dependencies(path.read_text(encoding="utf-8")).encode("utf-8")})
    prepared = {}
    for name, version in VERSIONS.items():
        root = package_root(repo, name)
        pubspec = root / "pubspec.yaml"
        if not re.search(rf"(?m)^version:\s*{re.escape(version)}\s*$", pubspec.read_text(encoding="utf-8")):
            raise AssertionError(f"{name} 不是固定版本 {version}")
    animated = package_root(repo, "native_animated_image") / "lib/src/ffi/native_animated_image_bindings.dart"
    avif = package_root(repo, "flutter_avif_platform_interface") / "lib/flutter_avif_platform_interface.dart"
    prepared[animated] = patch_animated(animated.read_text(encoding="utf-8")).encode("utf-8")
    prepared[avif] = patch_avif(avif.read_text(encoding="utf-8")).encode("utf-8")
    for filename in ["ohos_loader_stub.dart", "ohos_loader_io.dart"]:
        prepared[avif.parent / filename] = (repo / "ohos_support/images" / filename).read_bytes()
    # 预检全部成功后再写入，避免 pub cache 只完成一半补丁。
    return write_prepared(prepared)


def extract_source(archive, destination):
    with zipfile.ZipFile(archive) as source:
        entries = source.infolist()
        roots = {PurePosixPath(item.filename).parts[0] for item in entries}
        if len(roots) != 1:
            raise AssertionError("源码 zip 根目录不唯一")
        prepared = {}
        for item in entries:
            path = PurePosixPath(item.filename)
            if item.is_dir():
                continue
            if ".." in path.parts or path.is_absolute() or (item.external_attr >> 16) & 0o170000 == 0o120000:
                raise AssertionError("源码 zip 包含非法路径或链接")
            # flutter_avif 仓库附带其他平台二进制；构建只提取真实 Rust 和上游动画夹具。
            relative = Path(*path.parts[1:])
            if not relative.parts:
                continue
            if destination.name == "animated" and relative.parts[0] != "crates":
                continue
            if destination.name == "avif" and relative.parts[0] != "rust" and relative.as_posix() != "flutter_avif/example/assets/vettel.avif":
                continue
            prepared[destination / relative] = source.read(item)
        write_prepared(prepared)


def fetch_sources(repo, archive_dir=None):
    repo = Path(repo).resolve()
    pins = json.loads((repo / "ohos_support/images/sources.json").read_text(encoding="utf-8"))
    work = repo / "work/image-port"
    cache = work / "archives" if archive_dir is None else Path(archive_dir)
    cache.mkdir(parents=True, exist_ok=True)
    for name, pin in pins.items():
        archive = cache / f"{name}.zip"
        if not archive.is_file():
            request = Request(f"https://api.github.com/repos/{pin['repository']}/zipball/{pin['revision']}",
                headers={"User-Agent": "fluxdo-ohos-image-build"})
            with urlopen(request, timeout=180) as response:
                data = response.read()
            if hashlib.sha256(data).hexdigest() != pin["sha256"]:
                raise AssertionError(f"{name} 源码压缩包 SHA256 不匹配")
            archive.write_bytes(data)
        if hashlib.sha256(archive.read_bytes()).hexdigest() != pin["sha256"]:
            raise AssertionError(f"缓存的 {name} 源码压缩包 SHA256 不匹配")
        extract_source(archive, work / "sources" / name)
    return work / "sources"


def prepare_native(repo, sources):
    repo, sources = Path(repo).resolve(), Path(sources).resolve()
    avif = sources / "avif/rust"
    backend = sources / "libavif-rs"
    # 使用上游 Gitlink 固定的 C 源码，避开 Cargo 的未固定 git HEAD 和 host 库。
    for name, target in [("libavif-c", backend / "libavif-sys/libavif"), ("dav1d-c", backend / "libdav1d-sys/vendor")]:
        shutil.copytree(sources / name, target, dirs_exist_ok=True, ignore=shutil.ignore_patterns("android_jni", ".github"))
    manifest = (avif / "Cargo.toml").read_text(encoding="utf-8")
    manifest = replace_once(manifest,
        'libdav1d-sys = { version = "0.5", git = "https://github.com/yekeskin/libavif-rs.git" }',
        'libdav1d-sys = { version = "0.5", path = "../../libavif-rs/libdav1d-sys" }')
    manifest = replace_once(manifest,
        'libavif-sys = { version = "0.14.3", git = "https://github.com/yekeskin/libavif-rs.git",',
        'libavif-sys = { version = "0.14.3", path = "../../libavif-rs/libavif-sys",')
    # 上游生成模型严格要求 rust-protobuf 3.7.1；保留它的版本检查。
    manifest = replace_once(manifest, 'protobuf = "3.7.1"', 'protobuf = "=3.7.1"')
    build_path = backend / "libavif-sys/build.rs"
    build = replace_once(build_path.read_text(encoding="utf-8"), '    avif.define("BUILD_SHARED_LIBS", "0");',
        '    if env::var("TARGET").expect("TARGET").ends_with("linux-ohos") {\n'
        '        let native = env::var("OHOS_SDK_NATIVE").expect("OHOS_SDK_NATIVE");\n'
        '        avif.define("CMAKE_TOOLCHAIN_FILE", Path::new(&native).join("build/cmake/ohos.toolchain.cmake"))\n'
        '            .define("OHOS_ARCH", "arm64-v8a")\n'
        '            .define("CMAKE_POSITION_INDEPENDENT_CODE", "ON");\n'
        '    }\n    avif.define("BUILD_SHARED_LIBS", "0");')
    build = replace_once(build, '.define("RAV1E_LIBRARY", "-rav1e");',
        '.define("RAV1E_LIBRARY", "-rav1e")\n'
        '            .define("RAV1E_INCLUDE_DIR", out_dir.join("include").join("rav1e"));')
    tests_path = avif / "src/flutter_avif.rs"
    tests = tests_path.read_bytes()
    marker = b"\n// Fluxdo OHOS upstream codec regressions.\n"
    if marker not in tests:
        tests += marker + (repo / "ohos_support/images/avif_tests.rs").read_bytes()
    lock = repo / "ohos_support/images/avif-Cargo.lock"
    prepared = {avif / "Cargo.toml": manifest.encode("utf-8"), build_path: build.encode("utf-8"), tests_path: tests}
    animated_manifest = sources / "animated/crates/native_animated_image_codec/Cargo.toml"
    animated_config = replace_once(animated_manifest.read_text(encoding="utf-8"),
        'crate-type = ["cdylib", "staticlib"]', 'crate-type = ["cdylib", "staticlib", "rlib"]')
    prepared[animated_manifest] = animated_config.encode("utf-8")
    animated_tests = sources / "animated/crates/native_animated_image_codec/tests"
    prepared[animated_tests / "ohos_codec.rs"] = (repo / "ohos_support/images/animated_tests.rs").read_bytes()
    for filename in ["two-frames.gif", "two-frames.png", "two-frames.webp"]:
        fixture = repo / "ohos_support/images/fixtures" / filename
        prepared[animated_tests / "ohos-fixtures" / fixture.name] = fixture.read_bytes()
    if lock.is_file():
        prepared[avif / "Cargo.lock"] = lock.read_bytes()
    return write_prepared(prepared)


def self_test(source_root=None):
    original = "dependencies:\n  other: ^1.0.0\ndependency_overrides:\n  existing: 2.0.0\ndev_dependencies:\n  test: any\n"
    patched = patch_dependencies(original)
    assert patch_dependencies(patched) == patched and "  existing: 2.0.0" in patched
    assert patch_dependencies("dependencies:\n  other: any\n").endswith("  flutter_avif_platform_interface: 3.1.0\n")
    try:
        patch_animated("template drift")
    except AssertionError:
        pass
    else:
        raise AssertionError("必须拒绝 loader 模板漂移")
    repo_source = Path(__file__).resolve().parents[1]
    with tempfile.TemporaryDirectory(prefix="fluxdo-images-") as temporary:
        repo = Path(temporary) / "repo with spaces"
        repo.mkdir()
        (repo / "pubspec.yaml").write_text(original, encoding="utf-8")
        override = repo / "pubspec_overrides.yaml"
        override.write_text("dependency_overrides:\n  media: any\n", encoding="utf-8")
        assert len(prepare(repo, "before-pub-get")) == 1
        assert prepare(repo, "before-pub-get") == []
        assert (repo / "pubspec.yaml").read_text(encoding="utf-8") == original
        if source_root is not None:
            source_root = Path(source_root)
            fixture_roots = {
                "native_animated_image": source_root / "animated-source/Lingyan000-native_animated_image-6a35d2c/packages/native_animated_image",
                "flutter_avif": source_root / "avif-source/yekeskin-flutter_avif-513c918/flutter_avif",
                "flutter_avif_platform_interface": source_root / "avif-source/yekeskin-flutter_avif-513c918/flutter_avif_platform_interface",
            }
            packages = {}
            for name, source in fixture_roots.items():
                destination = repo / "pub cache" / name
                shutil.copytree(source, destination)
                packages[name] = destination
            config = repo / ".dart_tool/package_config.json"
            config.parent.mkdir()
            config.write_text(json.dumps({"packages": [{"name": n, "rootUri": p.as_uri()} for n, p in packages.items()]}), encoding="utf-8")
            shutil.copytree(repo_source / "ohos_support/images", repo / "ohos_support/images")
            assert len(prepare(repo, "after-pub-get")) == 4
            assert prepare(repo, "after-pub-get") == []
            bindings = packages["native_animated_image"] / "lib/src/ffi/native_animated_image_bindings.dart"
            before = fixture_roots["native_animated_image"] / "lib/src/ffi/native_animated_image_bindings.dart"
            bindings.write_bytes(before.read_bytes())
            platform = packages["flutter_avif_platform_interface"] / "lib/flutter_avif_platform_interface.dart"
            platform.write_text("template drift", encoding="utf-8")
            try:
                prepare(repo, "after-pub-get")
            except AssertionError:
                pass
            else:
                raise AssertionError("必须拒绝 AVIF 模板漂移")
            assert bindings.read_bytes() == before.read_bytes()
    print("OHOS 图像准备自检通过：固定版本、override 文件优先、幂等、漂移拒绝与原子预检")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--stage", choices=["before-pub-get", "after-pub-get", "fetch-native-sources", "prepare-native"])
    parser.add_argument("--repo", type=Path, default=Path.cwd())
    parser.add_argument("--archive-dir", type=Path)
    parser.add_argument("--source-root", type=Path)
    parser.add_argument("--self-test", action="store_true")
    args = parser.parse_args()
    if args.self_test:
        self_test(args.source_root)
    elif args.stage == "fetch-native-sources":
        print(fetch_sources(args.repo, args.archive_dir))
    elif args.stage == "prepare-native":
        sources = args.source_root or args.repo / "work/image-port/sources"
        for path in prepare_native(args.repo, sources):
            print(f"已准备 OHOS 图像原生源码：{path.name}")
    elif args.stage:
        for path in prepare(args.repo, args.stage):
            print(f"已准备 OHOS 图像：{path.name}")
    else:
        parser.error("需要 --stage 或 --self-test")
