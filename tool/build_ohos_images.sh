#!/usr/bin/env bash
# 真正构建 OHOS ELF；flutter pub get 和 after-pub-get 图像准备之后执行。
set -euo pipefail

repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
work="$repo/work/image-port"
sources="$work/sources"
target=aarch64-unknown-linux-ohos
rust_version=1.94.0
mkdir -p "$work"
# 与网络库复用已安装工具链及下载缓存，host/target 构建产物保持独立。
export CARGO_HOME="$repo/work/network-port/cargo-home"
export RUSTUP_HOME="$repo/work/network-port/rustup"
rustup toolchain install "$rust_version" --profile minimal --no-self-update
rustup target add --toolchain "$rust_version" "$target"
host="$(rustc "+$rust_version" -vV | sed -n 's/^host: //p')"
python3 "$repo/tool/prepare_ohos_images.py" --stage fetch-native-sources --repo "$repo"
python3 "$repo/tool/prepare_ohos_images.py" --stage prepare-native --repo "$repo"

animated="$sources/animated/crates/native_animated_image_codec/Cargo.toml"
avif="$sources/avif/rust/Cargo.toml"
[[ -s "$sources/avif/rust/Cargo.lock" ]] || { echo '缺少已提交的 AVIF Cargo.lock' >&2; exit 1; }
# Linux host 上运行上游真实 codec 回归；不尝试执行目标 ELF。
CARGO_TARGET_DIR="$work/host-animated" cargo "+$rust_version" test --manifest-path "$animated" --locked --target "$host"
CARGO_TARGET_DIR="$work/host-avif" cargo "+$rust_version" test --manifest-path "$avif" --locked --target "$host"

source "$repo/tool/ohos_native_env.sh"
ohos_native_env "$repo"
python3 - "$sources/libavif-rs/libdav1d-sys/crossfiles/$target.meson" \
    "$CARGO_TARGET_AARCH64_UNKNOWN_LINUX_OHOS_LINKER" "$AR_aarch64_unknown_linux_ohos" <<'PY'
from pathlib import Path
import sys
path, compiler, archiver = sys.argv[1:]
def quoted(value):
    return "'" + value.replace("\\", "\\\\").replace("'", "\\'") + "'"
data = ("[binaries]\nc = " + quoted(compiler) + "\nar = " + quoted(archiver) + "\n"
        "[host_machine]\nsystem = 'linux'\ncpu_family = 'aarch64'\ncpu = 'armv8'\nendian = 'little'\n"
        "[properties]\nneeds_exe_wrapper = true\n[built-in options]\nb_staticpic = true\n"
        "[project options]\nenable_tools = false\nenable_tests = false\n")
destination = Path(path)
destination.parent.mkdir(parents=True, exist_ok=True)
destination.write_text(data, encoding='utf-8')
PY
CARGO_TARGET_DIR="$work/animated" cargo "+$rust_version" build --manifest-path "$animated" --locked --release --lib --target "$target"
CARGO_TARGET_DIR="$work/avif" cargo "+$rust_version" build --manifest-path "$avif" --locked --release --lib --target "$target"

out="$repo/ohos/entry/libs/arm64-v8a"
mkdir -p "$out"
install -m 755 "$work/animated/$target/release/libnative_animated_image_codec.so" "$out/libnative_animated_image_codec.so"
install -m 755 "$work/avif/$target/release/libflutter_avif.so" "$out/libflutter_avif.so"
verify_elf() {
  local library="$1" name report
  name="$(basename "$library")"
  report="$work/$name.readelf.txt"
  "$OHOS_READELF" --file-header --dynamic --notes --version-info "$library" > "$report"
  grep -Eq 'Machine:.*AArch64' "$report" || { echo "$name 不是 AArch64" >&2; return 1; }
  if grep -Eiq 'Android|libandroid\.so|liblog\.so|libjnigraphics\.so|GLIBC_' "$report"; then
    echo "$name 含其他平台 ABI，拒绝装入 HAP" >&2
    return 1
  fi
  "$OHOS_NM" --dynamic --defined-only --format=posix "$library" > "$work/$name.symbols.txt"
}
verify_elf "$out/libnative_animated_image_codec.so"
verify_elf "$out/libflutter_avif.so"
for symbol in decode get_metadata_json get_frame_rgba release free_string version; do
  grep -Eq "^native_animated_image_$symbol " "$work/libnative_animated_image_codec.so.symbols.txt" || { echo "动态图 ABI 缺少 $symbol" >&2; exit 1; }
done
for symbol in store_dart_post_cobject decode_single_frame_image init_memory_decoder get_next_frame reset_decoder dispose_decoder encode_avif; do
  grep -Eq "^$symbol " "$work/libflutter_avif.so.symbols.txt" || { echo "AVIF ABI 缺少 $symbol" >&2; exit 1; }
done

# 验证 NEEDED 闭包；仅复制相同 NDK 的实际 C++ 运行库。
queue=("$out/libnative_animated_image_codec.so" "$out/libflutter_avif.so")
declare -A checked_runtime=()
for ((i = 0; i < ${#queue[@]}; i++)); do
  while IFS= read -r dependency; do
    case "$dependency" in
      libc.so|libdl.so|libm.so|libpthread.so|librt.so) continue ;;
      libc++_shared.so|libunwind.so)
        if [[ -z "${checked_runtime[$dependency]:-}" ]]; then
          runtime=""
          while IFS= read -r -d '' candidate; do
            if "$OHOS_READELF" --file-header "$candidate" | grep -q 'Machine:.*AArch64'; then
              runtime="$candidate"
              break
            fi
          done < <(find "$OHOS_NATIVE_DIR" -type f -name "$dependency" -print0)
          [[ -n "$runtime" ]] || { echo "NDK 缺少 $dependency" >&2; exit 1; }
          if [[ -f "$out/$dependency" ]] && ! cmp -s "$runtime" "$out/$dependency"; then
            echo "$dependency 已存在但与本次 NDK 不同" >&2
            exit 1
          fi
          install -m 755 "$runtime" "$out/$dependency"
          checked_runtime[$dependency]=1
          queue+=("$out/$dependency")
        fi
        verify_elf "$out/$dependency"
        ;;
      *) echo "未处理的图像动态依赖：$dependency" >&2; exit 1 ;;
    esac
  done < <("$OHOS_READELF" --dynamic "${queue[i]}" | sed -n 's/.*Shared library: \[\([^]]*\)\].*/\1/p')
done
{
  printf 'Rust: %s\nTarget: %s\nSDK bundle: 26.0.0.821\n' "$rust_version" "$target"
  cat "$repo/ohos_support/images/sources.json"
  sha256sum "$sources/animated/crates/native_animated_image_codec/Cargo.lock" "$sources/avif/rust/Cargo.lock" "${queue[@]}"
} > "$work/BUILD-INFO.txt"
printf '已交叉编译并验证 OHOS 图像原生库：%s\n' "$out"
