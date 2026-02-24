#!/usr/bin/env bash
# Build the walrus_ffi native library for Dart FFI consumption.
#
# Usage:
#   ./build.sh [release|debug]  # Default: release
#
# Prerequisites:
#   - Rust toolchain (rustup + cargo): https://rustup.rs
#
# Output:
#   walrus_ffi/target/{release,debug}/libwalrus_ffi.{dylib,so,dll}
#
# CI / cross-compilation:
#   For cross-compiling, add the target triple before running:
#     rustup target add aarch64-linux-android
#     cargo build --release --target aarch64-linux-android

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CRATE_DIR="$SCRIPT_DIR/walrus_ffi"

if [[ ! -f "$CRATE_DIR/Cargo.toml" ]]; then
  echo "Error: Cargo.toml not found at $CRATE_DIR/Cargo.toml" >&2
  exit 1
fi

PROFILE="${1:-release}"

echo "==> Building walrus_ffi ($PROFILE)..."
cd "$CRATE_DIR"

case "$PROFILE" in
  release)
    cargo build --release
    LIB_DIR="target/release"
    ;;
  debug)
    cargo build
    LIB_DIR="target/debug"
    ;;
  *)
    echo "Error: Unknown profile '$PROFILE'. Use 'release' or 'debug'." >&2
    exit 1
    ;;
esac

# Detect the library file.
if [[ -f "$LIB_DIR/libwalrus_ffi.dylib" ]]; then
  LIB_FILE="$LIB_DIR/libwalrus_ffi.dylib"
elif [[ -f "$LIB_DIR/libwalrus_ffi.so" ]]; then
  LIB_FILE="$LIB_DIR/libwalrus_ffi.so"
elif [[ -f "$LIB_DIR/walrus_ffi.dll" ]]; then
  LIB_FILE="$LIB_DIR/walrus_ffi.dll"
else
  echo "Error: Could not find compiled library in $LIB_DIR" >&2
  exit 1
fi

LIB_SIZE=$(du -h "$LIB_FILE" | cut -f1)
echo "==> Built successfully: $LIB_FILE ($LIB_SIZE)"
echo ""
echo "To use in Dart tests:"
echo "  cd Dartus && dart test"
echo ""
echo "To set a custom library path:"
echo "  export WALRUS_FFI_LIB=$CRATE_DIR/$LIB_FILE"
