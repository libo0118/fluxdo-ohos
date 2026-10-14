#!/usr/bin/env bash
# 供 OHOS 原生 crate 构建共用；仅在 Linux CI 中加载，保持 host 工具链独立。

ohos_native_env() {
  local repo="$1" candidate native=""
  if [[ "$(uname -s)" != Linux ]]; then
    echo 'OHOS 原生交叉编译仅支持本工作流的 Linux runner' >&2
    return 1
  fi
  for candidate in "${OHOS_SDK_NATIVE:-}" "${OHOS_NDK_HOME:-}" \
      "${HOS_SDK_HOME:-}/default/openharmony" \
      "${HOS_SDK_HOME:-}/default/hms"; do
    [[ -n "$candidate" ]] || continue
    if [[ -x "$candidate/llvm/bin/clang" && -d "$candidate/sysroot" ]]; then
      native="$candidate"
      break
    fi
    if [[ -x "$candidate/native/llvm/bin/clang" && -d "$candidate/native/sysroot" ]]; then
      native="$candidate/native"
      break
    fi
  done
  if [[ -z "$native" || ! -f "$native/build/cmake/ohos.toolchain.cmake" ]]; then
    echo 'ErBWs/setup-ohos 未提供可用 NDK；检查 OHOS_NDK_HOME / HOS_SDK_HOME' >&2
    return 1
  fi
  export OHOS_NATIVE_DIR="$(cd "$native" && pwd)"
  export OHOS_SDK_NATIVE="$OHOS_NATIVE_DIR"
  local tools="$repo/work/network-port/toolchain"
  mkdir -p "$tools"
  printf '#!/usr/bin/env bash\nexec %q --target=aarch64-linux-ohos --sysroot=%q -D__MUSL__ "$@"\n' \
    "$OHOS_NATIVE_DIR/llvm/bin/clang" "$OHOS_NATIVE_DIR/sysroot" > "$tools/clang"
  printf '#!/usr/bin/env bash\nexec %q --target=aarch64-linux-ohos --sysroot=%q -D__MUSL__ "$@"\n' \
    "$OHOS_NATIVE_DIR/llvm/bin/clang++" "$OHOS_NATIVE_DIR/sysroot" > "$tools/clang++"
  chmod +x "$tools/clang" "$tools/clang++"
  export CARGO_TARGET_AARCH64_UNKNOWN_LINUX_OHOS_LINKER="$tools/clang"
  export CC_aarch64_unknown_linux_ohos="$tools/clang"
  export CXX_aarch64_unknown_linux_ohos="$tools/clang++"
  export AR_aarch64_unknown_linux_ohos="$OHOS_NATIVE_DIR/llvm/bin/llvm-ar"
  export RANLIB_aarch64_unknown_linux_ohos="$OHOS_NATIVE_DIR/llvm/bin/llvm-ranlib"
  export CMAKE_TOOLCHAIN_FILE_aarch64_unknown_linux_ohos="$OHOS_NATIVE_DIR/build/cmake/ohos.toolchain.cmake"
  export BINDGEN_EXTRA_CLANG_ARGS_aarch64_unknown_linux_ohos="--target=aarch64-linux-ohos --sysroot=$OHOS_NATIVE_DIR/sysroot -D__MUSL__"
  export AWS_LC_SYS_CMAKE_BUILDER=1
  export OHOS_READELF="$OHOS_NATIVE_DIR/llvm/bin/llvm-readelf"
  export OHOS_NM="$OHOS_NATIVE_DIR/llvm/bin/llvm-nm"
  [[ -x "$OHOS_READELF" && -x "$OHOS_NM" ]] || return 1
  "$tools/clang" --version > "$repo/work/network-port/ndk-clang.txt"
  # SDK bundle 由 workflow 固定到 26.0.0.821，同时记录 NDK 元数据便于复现。
  find "$OHOS_NATIVE_DIR" -maxdepth 1 -name '*package*.json' -type f \
    -exec sha256sum '{}' \; > "$repo/work/network-port/ndk-metadata.sha256"
}
