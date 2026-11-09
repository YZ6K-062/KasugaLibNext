#!/usr/bin/env bash
# =============================================================================
# package_ia64.sh -- Merge the cross-compiled IA-64 Box3D JNI library into an
#                    existing (universal) KasugaLibNext modelling jar.
#
# Mirrors .github/workflows/build.yml "package-universal": the jar must contain
#   native/<classifier>/<System.mapLibraryName("kasuga_box3d")>
# so that NativeBox3D.loadLibrary() finds it via
#   getResourceAsStream("/native/" + platformClassifier() + "/" + mappedName)
#
# Usage:
#   ./package_ia64.sh <path-to-modelling.jar> [staging-dir] [classifier]
#
#   staging-dir  directory that contains native/<classifier>/*.so
#                (default: ./out next to this script)
#   classifier   default linux-ia64
#
# The jar is updated IN PLACE. Pass a copy if you want to keep the original.
# =============================================================================
set -euo pipefail

PORT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
JAR_FILE="${1:-}"
STAGE="${2:-${PORT_DIR}/out}"
CLASSIFIER="${3:-${KASUGA_NATIVE_CLASSIFIER:-linux-ia64}}"

die() { printf '\033[1;31m[ia64] ERROR: %s\033[0m\n' "$*" >&2; exit 1; }
log() { printf '\033[1;34m[ia64] %s\033[0m\n' "$*"; }

if [[ -z "$JAR_FILE" ]]; then
    sed -n '2,22p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
    exit 2
fi

[[ -f "$JAR_FILE" ]] || die "jar not found: $JAR_FILE"
command -v jar >/dev/null 2>&1 || die "'jar' not found on PATH (need a JDK, any architecture is fine)"

LIB="${STAGE}/native/${CLASSIFIER}/libkasuga_box3d.so"
[[ -f "$LIB" ]] || die "IA-64 library not found: $LIB (run build_ia64.sh first)"

# Sanity: refuse to put a non-IA-64 object into the IA-64 classifier directory.
if command -v readelf >/dev/null 2>&1; then
    if ! readelf -h "$LIB" 2>/dev/null | grep -qiE 'Intel IA-64|IA-64'; then
        die "$LIB is not an IA-64 ELF object (or host readelf cannot read it)."
    fi
fi

log "Merging native/${CLASSIFIER}/libkasuga_box3d.so into $JAR_FILE"

# -C changes directory; the path inside the jar becomes exactly
# native/<classifier>/libkasuga_box3d.so, matching the runtime lookup.
jar uf "$JAR_FILE" -C "$STAGE" "native/${CLASSIFIER}"

# Verify the entry is present.
entry="$(jar tf "$JAR_FILE" | grep -E "^native/${CLASSIFIER}/libkasuga_box3d\.so$" || true)"
[[ -n "$entry" ]] || die "merge appeared to succeed but the jar entry is missing"
log "Verified jar entry: $entry"

echo
log "All native libraries now in the jar:"
jar tf "$JAR_FILE" | grep -E '^native/.+\.(dll|so|dylib)$' | sort | sed 's/^/    /'

cat <<EOF

[ia64] Packaging done.

On the IA-64 target, verify the JVM really reports the expected classifier:
    java -XshowSettings:properties -version 2>&1 | grep -E 'os.arch|os.name'
Expected: os.name = Linux, os.arch = ia64  ->  classifier linux-ia64.
If the JDK reports a different os.arch string, either rebuild with
  --classifier linux-<that-string>
or bypass the lookup entirely with
  -Dkasuga.box3d.library=/absolute/path/libkasuga_box3d.so
EOF
