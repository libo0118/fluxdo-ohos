#!/usr/bin/env bash
# flutter pub get 及 prepare_ohos_network.py --stage after-pub-get 后执行。
set -euo pipefail

repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
work="$repo/work/network-port"
target=aarch64-unknown-linux-ohos
rust_version=1.94.0
doh_revision=03e0757336ee72f5800d6cb630fc8377a7cfba68
mkdir -p "$work"
export CARGO_HOME="$work/cargo-home"
export RUSTUP_HOME="$work/rustup"
if [[ "$(git -C "$repo/core/doh_proxy" rev-parse HEAD)" != "$doh_revision" ]]; then
  echo 'DoH 源码不是固定的上游提交，拒绝构建' >&2
  exit 1
fi
rhttp="$(python3 "$repo/tool/prepare_ohos_network.py" --stage rhttp-path --repo "$repo")"
rustup toolchain install "$rust_version" --profile minimal --no-self-update
rustup target add --toolchain "$rust_version" "$target"
host="$(rustc "+$rust_version" -vV | sed -n 's/^host: //p')"

# gen_ca 在 host 上运行；之后两种网络引擎都使用同一份证书资源。
(
  cd "$repo/core/doh_proxy"
  CARGO_TARGET_DIR="$work/host" cargo "+$rust_version" test --locked --lib --target "$host" ohos_leaf
  CARGO_TARGET_DIR="$work/host" cargo "+$rust_version" test --locked --lib --target "$host" select::tests
  CARGO_TARGET_DIR="$work/host" cargo "+$rust_version" test --locked --lib --target "$host" probe::tests
  CARGO_TARGET_DIR="$work/host" cargo "+$rust_version" test --locked --lib --target "$host" proxy::tests
  CARGO_TARGET_DIR="$work/host" cargo "+$rust_version" run --locked --release --target "$host" --bin gen_ca
)
install -m 644 "$repo/core/doh_proxy/certs/ca.crt" "$repo/assets/certs/proxy_ca.pem"
cmp "$repo/core/doh_proxy/certs/ca.crt" "$repo/assets/certs/proxy_ca.pem"
source "$repo/tool/ohos_native_env.sh"
ohos_native_env "$repo"

CARGO_TARGET_DIR="$work/doh" cargo "+$rust_version" build \
  --manifest-path "$repo/core/doh_proxy/Cargo.toml" --locked --release --lib \
  --target "$target" --features ech
# 上游 rhttp 开启 HTTP/3，需要保留 reqwest 的显式构建开关。
CARGO_TARGET_AARCH64_UNKNOWN_LINUX_OHOS_RUSTFLAGS="${CARGO_TARGET_AARCH64_UNKNOWN_LINUX_OHOS_RUSTFLAGS:-} --cfg reqwest_unstable" \
  CARGO_TARGET_DIR="$work/rhttp" cargo "+$rust_version" build \
  --manifest-path "$rhttp/rust/Cargo.toml" --locked --release --lib --target "$target"

out="$repo/ohos/entry/libs/arm64-v8a"
mkdir -p "$out"
install -m 755 "$work/doh/$target/release/libdoh_proxy.so" "$out/libdoh_proxy.so"
install -m 755 "$work/rhttp/$target/release/librhttp.so" "$out/librhttp.so"

verify_elf() {
  local library="$1" name report
  name="$(basename "$library")"
  report="$work/$name.readelf.txt"
  "$OHOS_READELF" --file-header --dynamic --notes "$library" > "$report"
  grep -Eq 'Machine:.*AArch64' "$report" || { echo "$name 不是 AArch64" >&2; return 1; }
  if grep -Eiq 'Android|libandroid\.so|liblog\.so|libjnigraphics\.so' "$report"; then
    echo "$name 带有 Android 标识或依赖，拒绝装入 HAP" >&2
    return 1
  fi
  "$OHOS_NM" --dynamic --defined-only --format=posix "$library" > "$work/$name.symbols.txt"
}

verify_elf "$out/libdoh_proxy.so"
verify_elf "$out/librhttp.so"
for symbol in doh_proxy_start_with_config_json doh_proxy_stop doh_proxy_is_running \
    doh_proxy_get_port doh_proxy_matches_current_leaf doh_proxy_init_logging doh_proxy_lookup_ech_config \
    doh_proxy_lookup_ip doh_proxy_lookup_host doh_proxy_clear_dns_cache \
    doh_proxy_record_host_success doh_proxy_clear_preferred_host_ip \
    doh_proxy_dns_cache_stats doh_proxy_dns_cache_records doh_proxy_generate_ca \
    doh_proxy_get_embedded_ca_pem doh_proxy_take_auth_rejected \
    doh_proxy_take_accel_update doh_proxy_accel_request doh_proxy_free_string \
    doh_proxy_network_changed doh_proxy_select_status doh_proxy_select_rerace \
    doh_proxy_set_share_measurements; do
  grep -Eq "^$symbol " "$work/libdoh_proxy.so.symbols.txt" || { echo "DoH 缺少 $symbol" >&2; exit 1; }
done
grep -Eq '^frb_get_rust_content_hash ' "$work/librhttp.so.symbols.txt"
grep -Eq '^frbgen_rhttp_rust_arc_increment_strong_count_RustOpaque_flutter_rust_bridgefor_generatedRustAutoOpaqueInnerRequestClient ' \
  "$work/librhttp.so.symbols.txt"

# 只复制实际 NEEDED 的 OHOS C++ 运行库；系统 libc 等由设备提供。
queue=("$out/libdoh_proxy.so" "$out/librhttp.so")
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
            echo "$dependency 已存在但与本次 NDK 不同，拒绝混用运行库" >&2
            exit 1
          fi
          install -m 755 "$runtime" "$out/$dependency"
          checked_runtime[$dependency]=1
          queue+=("$out/$dependency")
        fi
        verify_elf "$out/$dependency"
        ;;
      *) echo "未处理的 OHOS 动态依赖：$dependency" >&2; exit 1 ;;
    esac
  done < <("$OHOS_READELF" --dynamic "${queue[i]}" | sed -n 's/.*Shared library: \[\([^]]*\)\].*/\1/p')
done

{
  printf 'Rust: %s\nTarget: %s\nDoH: %s\nrhttp: %s\nFRB: 2.12.0\nSDK bundle: 26.0.0.821\n' \
    "$rust_version" "$target" "$doh_revision" 02eb4114b57c108e76a9ed526b6118bc048b5604
  sha256sum "$repo/core/doh_proxy/Cargo.lock" "$rhttp/rust/Cargo.lock" \
    "$repo/assets/certs/proxy_ca.pem" "${queue[@]}"
} > "$work/BUILD-INFO.txt"
printf '已交叉编译并验证 OHOS 网络原生库：%s\n' "$out"
