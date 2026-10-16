#!/usr/bin/env bash
# Offline regression check: stub cargo/uname, never compile native code.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FIXTURE_DIR="$(mktemp -d "${TMPDIR:-/tmp}/dartus-build-test.XXXXXX")"
trap 'rm -rf "$FIXTURE_DIR"' EXIT
mkdir -p "$FIXTURE_DIR/bin" "$FIXTURE_DIR/native/walrus_ffi/target/release" \
  "$FIXTURE_DIR/native/walrus_ffi/target/debug"
cp "$SCRIPT_DIR/../native/build.sh" "$FIXTURE_DIR/native/build.sh"
touch "$FIXTURE_DIR/native/walrus_ffi/Cargo.toml"
cat > "$FIXTURE_DIR/bin/uname" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$DARTUS_TEST_HOST"
STUB
cat > "$FIXTURE_DIR/bin/cargo" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" > "$DARTUS_TEST_CARGO_LOG"
STUB
chmod +x "$FIXTURE_DIR/bin/uname" "$FIXTURE_DIR/bin/cargo"
export PATH="$FIXTURE_DIR/bin:$PATH"
export DARTUS_TEST_CARGO_LOG="$FIXTURE_DIR/cargo.log"

check_host() {
  local host="$1" library="$2" profile="$3" expected_cargo="$4"
  local output="$FIXTURE_DIR/output"
  # All three exist: selection must follow the host, not filename precedence.
  touch "$FIXTURE_DIR/native/walrus_ffi/target/$profile/libwalrus_ffi.dylib" \
    "$FIXTURE_DIR/native/walrus_ffi/target/$profile/libwalrus_ffi.so" \
    "$FIXTURE_DIR/native/walrus_ffi/target/$profile/walrus_ffi.dll"
  DARTUS_TEST_HOST="$host" bash "$FIXTURE_DIR/native/build.sh" "$profile" > "$output"
  grep -Fq "Built successfully: target/$profile/$library" "$output"
  [[ "$(cat "$DARTUS_TEST_CARGO_LOG")" == "$expected_cargo" ]]
  # Wrong-host artifacts must never satisfy the success check.
  rm "$FIXTURE_DIR/native/walrus_ffi/target/$profile/$library"
  if DARTUS_TEST_HOST="$host" bash "$FIXTURE_DIR/native/build.sh" "$profile" > "$output" 2>&1; then
    echo "FAIL: $host accepted another platform's artifact" >&2
    exit 1
  fi
  grep -Fq "Could not find $host library" "$output"
}

check_host Darwin libwalrus_ffi.dylib release 'build --release'
check_host Linux libwalrus_ffi.so release 'build --release'
check_host MINGW64_NT-10.0 walrus_ffi.dll release 'build --release'
check_host MSYS_NT-10.0 walrus_ffi.dll debug 'build'
check_host CYGWIN_NT-10.0 walrus_ffi.dll debug 'build'
if DARTUS_TEST_HOST=Unknown bash "$FIXTURE_DIR/native/build.sh" > "$FIXTURE_DIR/output" 2>&1; then
  echo 'FAIL: unsupported host succeeded' >&2
  exit 1
fi
grep -Fq "Unsupported build host 'Unknown'" "$FIXTURE_DIR/output"
echo 'Native build host selection: all stub checks passed.'
