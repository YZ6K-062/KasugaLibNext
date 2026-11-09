#!/usr/bin/env bash
# =============================================================================
# run_smoke_ia64.sh -- Runtime acceptance test for the IA-64 Box3D JNI library.
#
# Compiles the dependency-free JNI stub + Box3DSmoke and runs a deterministic
# gravity-drop simulation. This is the only step that actually NEEDS an IA-64
# machine (or qemu-ia64 user-mode emulation); everything else in ia64-port can
# be done on the x86_64 cross-build host.
#
# Usage:
#   ./run_smoke_ia64.sh <path-to-libkasuga_box3d.so> [extra-classpath]
#
# Environment:
#   JAVA_BIN      java executable   (default: java on PATH)
#   JAVAC_BIN     javac executable  (default: javac on PATH)
#   VM_ARGS       extra JVM flags
#                 default: "-XX:+UseSerialGC -Xshare:off -Xint"
#                 (SerialGC because G1/ZGC/Shenandoah have no IA-64 barriers;
#                  -Xshare:off because CDS is unavailable; -Xint avoids the
#                  qemu SMC bug that breaks JIT-generated code.)
#   QEMU_PREFIX   prefix command for user-mode emulation, e.g.
#                 "qemu-ia64 -L /opt/ia64/rootfs"
#   KEEP_CLASSES  set to 1 to keep the compiled classes for debugging
#
# Tip: if you built the nsafran1217/jdk IA-64 JDK, prefer its "zero" or "core"
# VM explicitly -- e.g. VM_ARGS="-zero -XX:+UseSerialGC -Xshare:off" -- the
# C++/template interpreters have no dynamic code generation at all, so they are
# immune to the qemu self-modifying-code defect that affects the server JIT.
# =============================================================================
set -euo pipefail

SMOKE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SO="${1:-}"
EXTRA_CP="${2:-}"

die() { printf '\033[1;31m[ia64] ERROR: %s\033[0m\n' "$*" >&2; exit 1; }
log() { printf '\033[1;34m[ia64] %s\033[0m\n' "$*"; }

if [[ -z "$SO" ]]; then
    sed -n '2,30p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
    exit 2
fi
[[ -f "$SO" ]] || die "library not found: $SO"
SO_ABS="$(cd "$(dirname "$SO")" && pwd)/$(basename "$SO")"

JAVA_BIN="${JAVA_BIN:-java}"
JAVAC_BIN="${JAVAC_BIN:-javac}"
VM_ARGS="${VM_ARGS:--XX:+UseSerialGC -Xshare:off -Xint}"
command -v "$JAVA_BIN"  >/dev/null 2>&1 || die "java not found: $JAVA_BIN"
command -v "$JAVAC_BIN" >/dev/null 2>&1 || die "javac not found: $JAVAC_BIN"

CLASSES="$(mktemp -d "${TMPDIR:-/tmp}/kasuga-ia64-smoke.XXXXXX")"
if [[ "${KEEP_CLASSES:-0}" != "1" ]]; then
    trap 'rm -rf "$CLASSES"' EXIT
fi

log "Compiling smoke test sources"
"$JAVAC_BIN" -d "$CLASSES" \
    "${SMOKE_DIR}/src/lib/kasuga/rendering/models/uml/dynamic/physics/box3d/NativeBox3D.java" \
    "${SMOKE_DIR}/src/Box3DSmoke.java"

CP="$CLASSES"
[[ -n "$EXTRA_CP" ]] && CP="${CP}:${EXTRA_CP}"

# Build the command as an array so spaces in VM_ARGS / QEMU_PREFIX are handled.
CMD=()
if [[ -n "${QEMU_PREFIX:-}" ]]; then
    # shellcheck disable=SC2206
    CMD+=( $QEMU_PREFIX )
fi
CMD+=( "$JAVA_BIN" )
# shellcheck disable=SC2206
CMD+=( $VM_ARGS )
CMD+=( "-Dkasuga.box3d.library=${SO_ABS}" "-cp" "$CP" "Box3DSmoke" )

log "Running: ${CMD[*]}"
echo
"${CMD[@]}"
