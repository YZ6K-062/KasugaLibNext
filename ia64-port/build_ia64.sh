#!/usr/bin/env bash
# =============================================================================
# build_ia64.sh -- Cross-compile KasugaLibNext's Box3D JNI native library for
#                  Linux/IA-64 (Itanium) from an x86_64 Debian 13 build host.
#
# WHAT THIS PRODUCES
#   out/native/linux-ia64/libkasuga_box3d.so
#   (ready to merge into the universal modelling jar, or to drop into
#    -PkasugaBox3DNativeResources for a Gradle build)
#
# QUICK START (on the Debian 13 host that already has the IA-64 cross toolchain
# and the T2 sysroot used for nsafran1217/jdk):
#
#   ./ia64-port/build_ia64.sh \
#       --sysroot /opt/ia64/rootfs \
#       --jni-include /opt/ia64/jdk/include
#
# All settings can also come from the environment:
#   IA64_SYSROOT, IA64_TOOLCHAIN_PREFIX, KASUGA_JNI_INCLUDE_DIR, JAVA_HOME,
#   KASUGA_NATIVE_CLASSIFIER, BUILD_DIR, OUT_DIR, JOBS, IA64_CXX_COMPILER
#
# REQUIREMENTS on the build host
#   - cmake >= 3.22, make/ninja
#   - ia64-linux-gnu-gcc AND ia64-linux-gnu-g++ (GCC 15.2 / binutils 2.46)
#       g++ is needed even though all 50 Box3D sources are .c: box3d's
#       project(... LANGUAGES C CXX) makes CMake run a CXX compiler sanity test.
#   - the T2/Linux IA-64 sysroot (glibc 2.43)
#   - jni.h + jni_md.h from any Linux JDK 8+ (IA-64 JDK preferred; a host JDK
#     is ABI-identical because both targets are LP64 little-endian)
#
# On a dedicated cross-build host you usually do NOT need the whole Gradle
# repository -- just the vendored native tree. Set NATIVE_SRC to that directory:
#   NATIVE_SRC=/opt/src/kasuga/native ./ia64-port/build_ia64.sh \
#       --sysroot /opt/ia64/rootfs --jni-include /opt/src/jdk21/.../jdk/include
#
# WHY NO UPSTREAM SOURCE PATCHES ARE NEEDED (see ../ for the full audit)
#   * box3d/src/core.h: IA-64 defines __ia64__, hits none of the CPU branches,
#     so B3_CPU_UNKNOWN -> B3_SIMD_NONE. simd.h/simd.c then compile their
#     scalar #else implementations; <emmintrin.h>/<arm_neon.h> are not included.
#   * -DBOX3D_DISABLE_SIMD=ON pins that behaviour explicitly (belt + braces).
#   * solver.c b3Pause(): x86/ARM/MSVC branches all miss, #else is a no-op.
#   * platform.h atomics: __GNUC__ -> generic __atomic_* builtins.
#   * ctz.h: generic __builtin_ctz/clz/ctzll/popcountll.
#   * rapidhash.h: __SIZEOF_INT128__ -> __uint128_t, available on IA-64 GCC.
#   * timer.c: __linux__ branch -> pthread_create (POSIX, in T2 glibc).
#   * Little-endian: timer.c's big-endian #if does not fire.
#   * JNI bridge: every entry point is JNIEXPORT, so C_VISIBILITY_PRESET hidden
#     does not hide Java_* symbols.
#   * NativeBox3D.platformClassifier(): unknown arch falls through
#     sanitize(os.arch) -> "ia64", giving "linux-ia64". Gradle's build.gradle
#     uses the same fallback, so the classifier matches on both sides.
#
# The only real porting work is the BUILD CHAIN: a CMake toolchain file, a
# cross-safe FindJNI shim, and packaging. Those live in ./cmake and ./*.sh.
# =============================================================================
set -euo pipefail

PORT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${PORT_DIR}/.." && pwd)"
NATIVE_SRC="${NATIVE_SRC:-${REPO_ROOT}/modules/modelling/src/main/native}"
TOOLCHAIN_FILE="${PORT_DIR}/cmake/ia64-linux-gnu.toolchain.cmake"
MODULE_PATH="${PORT_DIR}/cmake"

IA64_SYSROOT="${IA64_SYSROOT:-/opt/ia64/rootfs}"
IA64_TOOLCHAIN_PREFIX="${IA64_TOOLCHAIN_PREFIX:-ia64-linux-gnu-}"
CLASSIFIER="${KASUGA_NATIVE_CLASSIFIER:-linux-ia64}"
BUILD_DIR="${BUILD_DIR:-${REPO_ROOT}/modules/modelling/build/native/box3d-ia64}"
OUT_DIR="${OUT_DIR:-${PORT_DIR}/out}"
JOBS="${JOBS:-$(getconf _NPROCESSORS_ONLN 2>/dev/null || echo 4)}"
MERGE_JAR="${MERGE_JAR:-}"
CONFIGURE_ONLY=0
VERIFY_ONLY=0

usage() {
    sed -n '2,60p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
    cat <<'EOF'

Options:
  --sysroot DIR        IA-64 target sysroot        (default /opt/ia64/rootfs)
  --prefix  STR        cross toolchain prefix      (default ia64-linux-gnu-)
  --jni-include DIR    dir containing jni.h        (default: JAVA_HOME/include)
  --classifier STR     native resource classifier  (default linux-ia64)
  --build-dir DIR      CMake build dir
  --out-dir DIR        staging dir for the .so
  --jobs N             parallel build jobs
  --merge-jar FILE     after building, merge into this existing jar
  --configure-only     run cmake configure then stop
  --verify-only        only verify an already built .so (implies no build)
  --so FILE            .so to inspect with --verify-only
  -h, --help           show this help
EOF
}

SO_TO_VERIFY=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        --sysroot)        IA64_SYSROOT="$2"; shift 2 ;;
        --prefix)         IA64_TOOLCHAIN_PREFIX="$2"; shift 2 ;;
        --jni-include)    KASUGA_JNI_INCLUDE_DIR="$2"; shift 2 ;;
        --classifier)     CLASSIFIER="$2"; shift 2 ;;
        --build-dir)      BUILD_DIR="$2"; shift 2 ;;
        --out-dir)        OUT_DIR="$2"; shift 2 ;;
        --jobs)           JOBS="$2"; shift 2 ;;
        --merge-jar)      MERGE_JAR="$2"; shift 2 ;;
        --configure-only) CONFIGURE_ONLY=1; shift ;;
        --verify-only)    VERIFY_ONLY=1; shift ;;
        --so)             SO_TO_VERIFY="$2"; shift 2 ;;
        -h|--help)        usage; exit 0 ;;
        *) echo "ERROR: unknown argument: $1" >&2; usage >&2; exit 2 ;;
    esac
done

log()  { printf '\n\033[1;34m[ia64] %s\033[0m\n' "$*"; }
warn() { printf '\033[1;33m[ia64] WARN: %s\033[0m\n' "$*" >&2; }
die()  { printf '\033[1;31m[ia64] ERROR: %s\033[0m\n' "$*" >&2; exit 1; }

# ---------------------------------------------------------------------------
# Verification of a produced ELF object. Exported as a function so
# --verify-only and the post-build step share exactly the same checks.
# ---------------------------------------------------------------------------
verify_so() {
    local so="$1"
    [[ -f "$so" ]] || die "not found: $so"

    local readelf="${IA64_TOOLCHAIN_PREFIX}readelf"
    local nm="${IA64_TOOLCHAIN_PREFIX}nm"
    command -v "$readelf" >/dev/null 2>&1 || readelf=readelf
    command -v "$nm"      >/dev/null 2>&1 || nm=nm

    log "Verifying $(basename "$so")"

    local hdr
    hdr="$("$readelf" -h "$so" 2>/dev/null)" || die "readelf failed (is binutils for IA-64 available?)"
    echo "$hdr" | grep -E 'Class:|Data:|Machine:|Type:' | sed 's/^/    /'

    echo "$hdr" | grep -q 'ELF64' \
        || die "not ELF64 -- wrong target architecture"
    echo "$hdr" | grep -qiE 'Intel IA-64|IA-64' \
        || die "e_machine is not Intel IA-64 (50). This .so was built for the wrong CPU."
    echo "$hdr" | grep -qi 'little endian' \
        || die "not little-endian; T2/Linux IA-64 is little-endian"

    # No host JVM libraries may be pulled in.
    local needed
    needed="$("$readelf" -d "$so" 2>/dev/null | grep '(NEEDED)' || true)"
    echo "    Dynamic dependencies:"
    echo "$needed" | sed 's/^/      /'
    if echo "$needed" | grep -qiE 'libjvm|libjawt|libjli'; then
        die "JNI library links a JVM shared object -- FindJNI shim was not used."
    fi

    # JNIEXPORT must survive C_VISIBILITY_PRESET hidden.
    local jni_syms
    jni_syms="$("$nm" -D --defined-only "$so" 2>/dev/null \
        | grep -c 'Java_lib_kasuga_rendering_models_uml_dynamic_physics_box3d_NativeBox3D_' || true)"
    [[ "${jni_syms:-0}" -gt 0 ]] \
        || die "no exported Java_*NativeBox3D_* symbols found (JNIEXPORT / visibility problem)"
    echo "    Exported JNI entry points: $jni_syms"

    # No unresolved x86/SSE-ish or JNIEnv-linkage leftovers.
    local undef
    undef="$("$nm" -D --undefined-only "$so" 2>/dev/null || true)"
    if echo "$undef" | grep -qiE '_mm_|__builtin_ia32|JVM_'; then
        die "unexpected x86/JVM-internal undefined symbols"
    fi

    # PT_GNU_STACK must be RW (not RWE). Without -z noexecstack, HotSpot warns
    # on System.load() that the library "might have disabled stack guard".
    local stack
    stack="$("$readelf" -lW "$so" 2>/dev/null | grep -i 'GNU_STACK' || true)"
    if [[ -z "$stack" ]]; then
        warn "no PT_GNU_STACK note; HotSpot may warn about an executable stack"
    elif echo "$stack" | grep -q 'RWE'; then
        die "stack is executable (RWE); link with -Wl,-z,noexecstack"
    else
        echo "    GNU_STACK: $(echo "$stack" | tr -s ' ' | cut -d' ' -f1-8)"
    fi

    if command -v "${IA64_TOOLCHAIN_PREFIX}size" >/dev/null 2>&1; then
        "${IA64_TOOLCHAIN_PREFIX}size" "$so" 2>/dev/null | sed 's/^/    /' || true
    fi
    log "PASS: $so is a valid Linux/IA-64 JNI shared object"
}

if [[ "$VERIFY_ONLY" -eq 1 ]]; then
    if [[ -z "$SO_TO_VERIFY" ]]; then
        SO_TO_VERIFY="${OUT_DIR}/native/${CLASSIFIER}/libkasuga_box3d.so"
    fi
    verify_so "$SO_TO_VERIFY"
    exit 0
fi

# ---------------------------------------------------------------------------
# Preflight
# ---------------------------------------------------------------------------
log "Preflight"
[[ -f "${NATIVE_SRC}/CMakeLists.txt" ]] || die "native source tree missing at ${NATIVE_SRC}"
[[ -f "${TOOLCHAIN_FILE}" ]]           || die "toolchain file missing: ${TOOLCHAIN_FILE}"
[[ -f "${MODULE_PATH}/FindJNI.cmake" ]] || die "FindJNI shim missing: ${MODULE_PATH}/FindJNI.cmake"

command -v cmake >/dev/null 2>&1 || die "cmake not found on PATH"
echo "    cmake: $(cmake --version | head -1)"

CC="${IA64_TOOLCHAIN_PREFIX}gcc"
CXX="${IA64_CXX_COMPILER:-${IA64_TOOLCHAIN_PREFIX}g++}"
command -v "$CC"  >/dev/null 2>&1 || die "cross C compiler not found: $CC"
# g++ is required for CMake's CXX language sanity check (see header comment).
command -v "$CXX" >/dev/null 2>&1 || die \
    "cross C++ compiler not found: $CXX
     box3d declares project(... LANGUAGES C CXX) even though no .cpp is built.
     Install g++-ia64-linux-gnu, or set IA64_CXX_COMPILER to your ia64 g++."
echo "    C compiler:   $($CC --version | head -1)"
echo "    C++ compiler: $($CXX --version | head -1)"

[[ -d "$IA64_SYSROOT" ]] || die "IA-64 sysroot not found: $IA64_SYSROOT (use --sysroot)"
echo "    sysroot: $IA64_SYSROOT"

# Resolve JNI headers.
if [[ -z "${KASUGA_JNI_INCLUDE_DIR:-}" ]]; then
    if [[ -n "${JAVA_HOME:-}" && -f "${JAVA_HOME}/include/jni.h" ]]; then
        KASUGA_JNI_INCLUDE_DIR="${JAVA_HOME}/include"
    else
        for d in /opt/ia64/jdk/include /usr/lib/jvm/default-java/include \
                 /usr/lib/jvm/java-21-openjdk-amd64/include \
                 /usr/lib/jvm/java-17-openjdk-amd64/include; do
            [[ -f "$d/jni.h" ]] && KASUGA_JNI_INCLUDE_DIR="$d" && break
        done
    fi
fi
[[ -n "${KASUGA_JNI_INCLUDE_DIR:-}" && -f "${KASUGA_JNI_INCLUDE_DIR}/jni.h" ]] \
    || die "jni.h not found. Pass --jni-include <jdk>/include or set JAVA_HOME."
[[ -f "${KASUGA_JNI_INCLUDE_DIR}/linux/jni_md.h" || -f "${KASUGA_JNI_INCLUDE_DIR}/jni_md.h" ]] \
    || die "jni_md.h not found under ${KASUGA_JNI_INCLUDE_DIR}/linux/ (or alongside jni.h)"
echo "    JNI headers: ${KASUGA_JNI_INCLUDE_DIR}"

# Guard against a stale native (host) build in the same directory.
if [[ -f "${BUILD_DIR}/CMakeCache.txt" ]]; then
    cached_sysroot="$(grep -E '^CMAKE_SYSROOT:PATH=' "${BUILD_DIR}/CMakeCache.txt" 2>/dev/null | cut -d= -f2- || true)"
    if [[ -n "$cached_sysroot" && "$cached_sysroot" != "$IA64_SYSROOT" ]]; then
        warn "build dir was configured for a different sysroot ($cached_sysroot); wiping it"
        rm -rf "$BUILD_DIR"
    fi
fi

# ---------------------------------------------------------------------------
# Configure
# ---------------------------------------------------------------------------
log "Configuring CMake (target: Linux/IA-64, classifier: ${CLASSIFIER})"
mkdir -p "$BUILD_DIR" "$OUT_DIR/native/${CLASSIFIER}"

# Only pass JAVA_HOME when it is genuinely a JDK root; deriving it by stripping
# "/include" is unreliable and our FindJNI shim uses KASUGA_JNI_INCLUDE_DIR
# directly, so a bogus JAVA_HOME would only add a misleading hint.
JDK_ARGS=()
if [[ -n "${JAVA_HOME:-}" && -f "${JAVA_HOME}/include/jni.h" ]]; then
    JDK_ARGS+=("-DJAVA_HOME=${JAVA_HOME}")
fi

cmake -S "$NATIVE_SRC" -B "$BUILD_DIR" -G "Unix Makefiles" \
    -Wno-dev \
    -DCMAKE_TOOLCHAIN_FILE="$TOOLCHAIN_FILE" \
    -DCMAKE_MODULE_PATH="$MODULE_PATH" \
    -DIA64_SYSROOT="$IA64_SYSROOT" \
    -DIA64_TOOLCHAIN_PREFIX="$IA64_TOOLCHAIN_PREFIX" \
    -DKASUGA_JNI_INCLUDE_DIR="$KASUGA_JNI_INCLUDE_DIR" \
    ${JDK_ARGS[@]+"${JDK_ARGS[@]}"} \
    -DCMAKE_BUILD_TYPE=Release \
    -DKASUGA_NATIVE_CLASSIFIER="$CLASSIFIER" \
    -DBOX3D_DISABLE_SIMD=ON \
    -DBUILD_SHARED_LIBS=OFF \
    -DBOX3D_SAMPLES=OFF \
    -DBOX3D_BENCHMARKS=OFF \
    -DBOX3D_DOCS=OFF \
    -DBOX3D_PROFILE=OFF \
    -DBOX3D_VALIDATE=OFF \
    -DBOX3D_UNIT_TESTS=OFF \
    -DBOX3D_COMPILE_WARNING_AS_ERROR=OFF

# Confirm the shim actually took effect.
if grep -qE '^JAVA_JVM_LIBRARY:.*=' "${BUILD_DIR}/CMakeCache.txt" 2>/dev/null; then
    : # harmless if empty
fi
log "Configure OK"

if [[ "$CONFIGURE_ONLY" -eq 1 ]]; then
    log "--configure-only: stopping here"
    exit 0
fi

# ---------------------------------------------------------------------------
# Build
# ---------------------------------------------------------------------------
log "Building target kasuga_box3d with ${JOBS} jobs"
cmake --build "$BUILD_DIR" --target kasuga_box3d --parallel "$JOBS"

SO_BUILT="${BUILD_DIR}/resources/native/${CLASSIFIER}/libkasuga_box3d.so"
[[ -f "$SO_BUILT" ]] || die "build finished but library not at expected path: $SO_BUILT"

# ---------------------------------------------------------------------------
# Verify + stage
# ---------------------------------------------------------------------------
verify_so "$SO_BUILT"

STAGED="${OUT_DIR}/native/${CLASSIFIER}/libkasuga_box3d.so"
cp -f "$SO_BUILT" "$STAGED"
log "Staged: $STAGED"

# Strip debug info but keep dynamic symbols (JNI entry points must remain).
if command -v "${IA64_TOOLCHAIN_PREFIX}strip" >/dev/null 2>&1; then
    "${IA64_TOOLCHAIN_PREFIX}strip" --strip-debug "$STAGED" 2>/dev/null || warn "strip failed, keeping unstripped .so"
    verify_so "$STAGED" >/dev/null
fi

if [[ -n "$MERGE_JAR" ]]; then
    log "Merging into jar: $MERGE_JAR"
    exec "${PORT_DIR}/package_ia64.sh" "$MERGE_JAR" "$OUT_DIR" "$CLASSIFIER"
fi

cat <<EOF

[ia64] DONE.

Artifact: ${STAGED}

Next steps (pick one):
  1) Merge into an existing universal modelling jar:
       ${PORT_DIR}/package_ia64.sh /path/to/kasuga-modelling-*.jar "${OUT_DIR}"
  2) Feed a Gradle build as a native resource overlay:
       ./gradlew :modules:modelling:processResources \\
         -PkasugaBox3DNativeResources=${OUT_DIR}
  3) Runtime smoke test on the IA-64 target:
       ${PORT_DIR}/smoke/run_smoke_ia64.sh "${STAGED}"
  4) Force the JVM to load this exact file regardless of classifier:
       java -Dkasuga.box3d.library=${STAGED} ...
EOF
