#!/usr/bin/env bash
# Verify every cross-compiled Linux target under qemu-user-static, without
# needing a JDK for each architecture.
#
# Run on the Debian 13 build host after:
#   apt-get install -y gcc-{s390x,powerpc64,powerpc64le,aarch64}-linux-gnu \
#                      g++-{...} qemu-user-static
#
#   ./verify/verify_qemu.sh /opt/src/matrix/native-port/out/native
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OUT="${1:-$(cd "$HERE/.." && pwd)/out/native}"
JNI="${JNI_INCLUDE:-/usr/lib/jvm/java-21-openjdk-amd64/include}"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# triple | qemu | classifier
TARGETS=(
  "s390x-linux-gnu|qemu-s390x-static|linux-s390x"
  "powerpc64-linux-gnu|qemu-ppc64-static|linux-ppc64"
  "powerpc64le-linux-gnu|qemu-ppc64le-static|linux-ppc64le"
  "aarch64-linux-gnu|qemu-aarch64-static|linux-aarch64"
)
fail=0
for row in "${TARGETS[@]}"; do
  IFS='|' read -r triple qemu cls <<< "$row"
  lib="$OUT/$cls/libkasuga_box3d.so"
  [[ -f "$lib" ]] || { echo "MISSING $lib"; fail=1; continue; }
  "${triple}-gcc" -O2 -I"$JNI" -I"$JNI/linux" \
      -o "$WORK/h_$cls" "$HERE/jni_harness.c" -ldl -lm || { echo "COMPILE FAIL $cls"; fail=1; continue; }
  echo "=== $cls ($triple, $qemu) ==="
  if "$qemu" -L "/usr/$triple" "$WORK/h_$cls" "$lib"; then
    echo "  PASS $cls"
  else
    echo "  FAIL $cls"; fail=1
  fi
done
exit "$fail"
