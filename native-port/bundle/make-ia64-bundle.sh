#!/usr/bin/env bash
# make-ia64-bundle.sh - build a relocatable IA-64 cross toolchain bundle.
#
# Run ON THE DEBIAN BUILD HOST (it needs the installed toolchain + sysroot).
# Produces a tarball that can be copied to any x86_64 Linux machine and
# unpacked anywhere; the included env.sh rewrites the hard-coded sysroot path.
#
# Why a bundle and not just a tar of /opt:
#   - GCC was configured with --prefix=/opt/cross and
#     --with-sysroot=/opt/ia64/rootfs. Those paths are baked into the binary.
#     The bundle therefore installs to the SAME relative layout and ships an
#     env.sh that passes --sysroot explicitly, which overrides the baked value.
#   - The T2 rootfs is 7.6 GB, but 5.9 GB of that is desktop/Qt6/LLVM/X11 that
#     a C-only cross build never touches. The slim variant (headers + libc/libm
#     + crt objects + libgcc) is ~1.7 GB and was verified to build AND run the
#     real Box3D JNI library.
#
# Usage:
#   ./make-ia64-bundle.sh                    # slim bundle (recommended)
#   SLIM=0 ./make-ia64-bundle.sh             # full sysroot bundle
#   OUTDIR=/mnt/usb ./make-ia64-bundle.sh    # write straight to the USB stick

set -euo pipefail

CROSS_SRC="${CROSS_SRC:-/opt/cross}"
ROOTFS_SRC="${ROOTFS_SRC:-/opt/ia64/rootfs}"
SLIM_ROOTFS="${SLIM_ROOTFS:-/opt/ia64/slim2}"
JDK_INC="${JDK_INC:-/opt/src/jdk21/build/ia64c/images/jdk/include}"
SLIM="${SLIM:-1}"
OUTDIR="${OUTDIR:-/opt/ia64/bundle}"
NAME="kasuga-ia64-toolchain"
STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT

die() { echo "ERROR: $*" >&2; exit 1; }
log() { printf '\n\033[1;34m[bundle] %s\033[0m\n' "$*"; }

[[ -x "$CROSS_SRC/bin/ia64-linux-gnu-gcc" ]] || die "toolchain not found at $CROSS_SRC"
[[ -f "$ROOTFS_SRC/usr/lib/libc.so" ]] || die "sysroot not found at $ROOTFS_SRC"

B="$STAGE/$NAME"
mkdir -p "$B"

# ---------------------------------------------------------------- toolchain --
log "Copying cross toolchain ($(du -sh "$CROSS_SRC" | cut -f1))"
cp -a "$CROSS_SRC" "$B/cross"

# ------------------------------------------------------------------ sysroot --
if [[ "$SLIM" == "1" && -d "$SLIM_ROOTFS" ]]; then
    log "Copying SLIM sysroot ($(du -sh "$SLIM_ROOTFS" | cut -f1))"
    cp -a "$SLIM_ROOTFS" "$B/sysroot"
    SYSROOT_KIND="slim"
else
    log "Copying FULL sysroot ($(du -sh "$ROOTFS_SRC" | cut -f1)) - this is slow"
    mkdir -p "$B/sysroot"
    # Dirs that a C cross build never reads. Dropping them is safe even in the
    # "full" variant; set KEEP_ALL=1 to copy literally everything.
    if [[ "${KEEP_ALL:-0}" == "1" ]]; then
        cp -a "$ROOTFS_SRC/." "$B/sysroot/"
    else
        tar -C "$ROOTFS_SRC" -cf - \
            --exclude='./lib/firmware' --exclude='./lib/modules' \
            --exclude='./lib/udev' --exclude='./lib/security' \
            --exclude='./usr/lib/qt6' --exclude='./usr/lib/libLLVM*' \
            --exclude='./usr/lib/libgallium*' --exclude='./usr/lib/libQt6*' \
            --exclude='./usr/share' --exclude='./usr/doc' --exclude='./usr/X11R7' \
            --exclude='./usr/translations' --exclude='./usr/libexec' \
            --exclude='./opt' --exclude='./boot' --exclude='./var' \
            --exclude='./proc' --exclude='./sys' --exclude='./dev' \
            --exclude='./run' --exclude='./tmp' --exclude='./srv' \
            --exclude='./root' --exclude='./home' \
            . 2>/dev/null | tar -C "$B/sysroot" -xf -
    fi
    SYSROOT_KIND="full"
fi

# ------------------------------------------------------------- JDK headers --
if [[ -d "$JDK_INC" ]]; then
    log "Copying JNI headers ($(du -sh "$JDK_INC" | cut -f1))"
    mkdir -p "$B/jni"
    cp -a "$JDK_INC/." "$B/jni/"
else
    echo "WARN: JNI headers not found at $JDK_INC; a host JDK 21's include/ also works" >&2
fi

# ------------------------------------------------------------------- env.sh --
cat > "$B/env.sh" <<'ENVEOF'
# Source this file before building:
#   source <bundle>/env.sh
#
# Exports the variables build.py / build_ia64.sh consume. It also patches the
# GCC default sysroot at *use* time: passing --sysroot overrides the path that
# was baked in at configure time, so the bundle works from any location.
_IA64_BUNDLE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

export IA64_TOOLCHAIN_PREFIX="$_IA64_BUNDLE_DIR/cross/bin/ia64-linux-gnu-"
export IA64_SYSROOT="$_IA64_BUNDLE_DIR/sysroot"
export KASUGA_JNI_INCLUDE_DIR="$_IA64_BUNDLE_DIR/jni"
# build.py reads these:
export KASUGA_TARGET_TRIPLE="ia64-linux-gnu"
export KASUGA_TARGET_CPU="ia64"
# Wrapper dir FIRST so manual `ia64-linux-gnu-gcc` calls also get --sysroot.
# (build.py/CMake is fine either way: CMAKE_SYSROOT already injects --sysroot.)
export PATH="$_IA64_BUNDLE_DIR/bin:$_IA64_BUNDLE_DIR/cross/bin:$PATH"

# A wrapper that always injects --sysroot: GCC otherwise falls back to the
# configured /opt/ia64/rootfs path, which does not exist on this machine.
mkdir -p "$_IA64_BUNDLE_DIR/bin"
cat > "$_IA64_BUNDLE_DIR/bin/ia64-linux-gnu-gcc" <<'WRAP'
#!/bin/sh
_here="$(cd "$(dirname "$0")/.." && pwd)"
exec "$_here/cross/bin/ia64-linux-gnu-gcc" --sysroot="$_here/sysroot" "$@"
WRAP
cat > "$_IA64_BUNDLE_DIR/bin/ia64-linux-gnu-g++" <<'WRAP'
#!/bin/sh
_here="$(cd "$(dirname "$0")/.." && pwd)"
exec "$_here/cross/bin/ia64-linux-gnu-g++" --sysroot="$_here/sysroot" "$@"
WRAP
chmod +x "$_IA64_BUNDLE_DIR/bin/"*

echo "IA-64 cross toolchain ready:"
echo "  IA64_TOOLCHAIN_PREFIX = $IA64_TOOLCHAIN_PREFIX"
echo "  IA64_SYSROOT          = $IA64_SYSROOT"
echo "  KASUGA_JNI_INCLUDE_DIR= $KASUGA_JNI_INCLUDE_DIR"
echo "verify with: ia64-linux-gnu-gcc -v  (wrapper on PATH injects --sysroot)"
ENVEOF
chmod +x "$B/env.sh"

# ------------------------------------------------------------------ README ---
cat > "$B/README.txt" <<'DOCEOF'
KasugaLibNext - IA-64 (Itanium) cross toolchain bundle
=====================================================

Contents
  cross/    GCC 14.4.0 + binutils 2.46 for ia64-linux-gnu (x86_64 host binaries)
  sysroot/  T2/Linux IA-64 sysroot (glibc, headers, crt objects)
  jni/      JNI headers (jni.h + linux/jni_md.h)
  env.sh    exports the variables the build scripts expect

Requirements on the target machine
  - x86_64 Linux (Debian 13 / Ubuntu 24.04 verified). NOT Windows-native:
    these are ELF x86_64 host binaries, so use WSL2 or a Linux VM on Windows.
  - ~4 GB free disk for the slim bundle, ~9 GB for the full one.

Install
  tar -xJf kasuga-ia64-toolchain-*.tar.xz -C /where/you/want
  cd /where/you/want/kasuga-ia64-toolchain
  source ./env.sh

Build the native library (from the KasugaLibNext repo root)
  source /where/you/want/kasuga-ia64-toolchain/env.sh
  NATIVE_SRC=$PWD/modules/modelling/src/main/native \
    python3 native-port/build.py --target linux-ia64

Notes
  - GCC was configured with --prefix=/opt/cross and
    --with-sysroot=/opt/ia64/rootfs. Those paths are compiled in, so the bundle
    must NOT be split; env.sh adds a wrapper that passes --sysroot explicitly,
    which is what makes relocation work.
  - The slim sysroot drops desktop/Qt6/LLVM/X11/firmware. It was verified to
    build AND run the real Box3D JNI library; if you need extra headers
    (e.g. X11, alsa), use the full variant.
  - For runtime tests you additionally need QEMU for IA-64, which is NOT
    included here (QEMU is only needed to *run* the result, not to build it).
DOCEOF

# --------------------------------------------------------------- checksums ---
log "Writing manifest"
(
  cd "$B"
  # NOTE: plain `[[ cond ]] && cmd` inside a `while` body returns 1 whenever the
  # condition is false, which under `set -e` aborts the whole script as soon as
  # one symlink is met. Use an explicit if and never let the loop fail.
  : > MANIFEST.sha256
  find . \( -type f -o -type l \) -print0 | sort -z | while IFS= read -r -d '' f; do
      if [ -f "$f" ] && [ ! -L "$f" ]; then
          sha256sum "$f" >> MANIFEST.sha256 || true
      fi
  done
  echo "files: $(wc -l < MANIFEST.sha256)"
) || { echo "WARN: manifest generation failed; continuing without checksums" >&2; }

# --------------------------------------------------------------- packaging ---
mkdir -p "$OUTDIR"
STAMP="$(date +%Y%m%d)"
ARCHIVE="$OUTDIR/${NAME}-${SYSROOT_KIND}-${STAMP}.tar.xz"

log "Compressing -> $ARCHIVE (this takes a while)"
if command -v xz >/dev/null 2>&1; then
    # -6 keeps peak memory ~4x lower than -9, which matters on a 7 GB VM; the
    # ratio difference on already-compressed binaries is small.
    tar -C "$STAGE" -cf - "$NAME" | xz -T0 -6 --memlimit-compress=60% > "$ARCHIVE"
else
    ARCHIVE="${ARCHIVE%.xz}.gz"
    tar -C "$STAGE" -czf "$ARCHIVE" "$NAME"
fi

log "Done"
ls -lh "$ARCHIVE"
echo
echo "Transfer this single file. On the target:"
echo "  tar -xJf $(basename "$ARCHIVE") -C /opt/ia64 && source /opt/ia64/$NAME/env.sh"
echo
echo "Verify after unpacking:"
echo "  source /opt/ia64/$NAME/env.sh && ia64-linux-gnu-gcc -v 2>&1 | tail -2"
