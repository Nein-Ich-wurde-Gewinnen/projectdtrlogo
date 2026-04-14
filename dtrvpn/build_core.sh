#!/usr/bin/env bash
# build_core.sh — FIX: export-паттерн из FlClash вместо inline ${GOARM:+...}
set -euo pipefail

ARCHES="${BUILD_ARCHES:-arm64}"

find_ndk() {
    for dir in \
        "${ANDROID_NDK_HOME:-}" "${ANDROID_NDK:-}" \
        "${ANDROID_SDK_ROOT:-}/ndk/28.2.13676358" \
        "${ANDROID_HOME:-}/ndk/28.2.13676358" \
        "${ANDROID_SDK_ROOT:-}/ndk/26.1.10909125" \
        "${ANDROID_HOME:-}/ndk/26.1.10909125"; do
        [ -n "$dir" ] && [ -d "$dir" ] && echo "$dir" && return 0
    done; return 1
}

find_toolchain() {
    local tc
    tc=$(ls -d "$1/toolchains/llvm/prebuilt"/*/ 2>/dev/null | head -1)
    [ -n "$tc" ] && echo "${tc%/}" || return 1
}

command -v go >/dev/null || { echo "❌ Go не найден"; exit 1; }
NDK_HOME=$(find_ndk)    || { echo "❌ NDK не найден"; exit 1; }
TOOLCHAIN=$(find_toolchain "$NDK_HOME") || exit 1

echo "✅ Go $(go version | awk '{print $3}')"
echo "✅ NDK:       $NDK_HOME"
echo "✅ Toolchain: $TOOLCHAIN"

cd core
if [ ! -f "go.sum" ]; then
    echo "ℹ️ go.sum не найден — go mod tidy..."
    GOFLAGS="" go mod tidy
else
    go mod download
fi
cd ..

build_arch() {
    local ARCH="$1"
    local ARCH_NAME GOARCH GOARM CC_BIN OUTPUT_DIR
    case "$ARCH" in
        arm64)  ARCH_NAME="arm64-v8a";   GOARCH="arm64"; GOARM="";  CC_BIN="aarch64-linux-android21-clang" ;;
        arm)    ARCH_NAME="armeabi-v7a"; GOARCH="arm";   GOARM="7"; CC_BIN="armv7a-linux-androideabi21-clang" ;;
        x86_64) ARCH_NAME="x86_64";      GOARCH="amd64"; GOARM="";  CC_BIN="x86_64-linux-android21-clang" ;;
        *) echo "❌ Неизвестная arch: $ARCH"; return 1 ;;
    esac

    OUTPUT_DIR="$(pwd)/android/app/src/main/jniLibs/$ARCH_NAME"
    local CC="$TOOLCHAIN/bin/$CC_BIN"
    [ -f "$CC" ] || { echo "❌ Clang не найден: $CC"; return 1; }
    mkdir -p "$OUTPUT_DIR"
    echo ""
    echo "🔨 $ARCH_NAME..."

    # КЛЮЧЕВОЙ ПАТТЕРН (FlClash): export отдельно, затем чистый go build
    (
        cd core
        export CGO_ENABLED=1 GOOS=android GOARCH="$GOARCH" CC="$CC"
        export CFLAGS="-O3 -Werror"
        unset CGO_CFLAGS CGO_LDFLAGS
        [ -n "$GOARM" ] && export GOARM="$GOARM" || unset GOARM 2>/dev/null || true
        go build -buildmode=c-shared -trimpath -ldflags="-w -s" \
            -o "$OUTPUT_DIR/libclash.so" .
    )

    echo "✅ libclash.so → $OUTPUT_DIR  $(ls -lh "$OUTPUT_DIR/libclash.so" | awk '{print $5}')"
}

for ARCH in $ARCHES; do build_arch "$ARCH"; done
echo ""
echo "🏁 Готово!"
