#!/usr/bin/env python3
"""KasugaLibNext Experimental Builds -- unified native build driver.

One driver for all targets in targets.json. It configures CMake with the
target's toolchain, builds the `kasuga_box3d` JNI library, verifies the
artifact, and stages it under out/native/<classifier>/.

Usage:
  python build.py --list
  python build.py --target windows-x86_64-legacy
  python build.py --target linux-s390x --native-src /opt/src/kasuga/native
  python build.py --all-host windows

Environment / flags:
  NATIVE_SRC          vendored native source dir (default: ../modules/modelling/src/main/native)
  CMAKE               cmake executable (default: cmake on PATH)
  KASUGA_JOBS         parallel jobs (default: CPU count)
  KASUGA_BUILD_DIR    override build dir
  KASUGA_OUT_DIR      override staging dir

Why the sources do not need patching: see ../ia64-port/PORTING.md.
The only target-specific source-level concern is Legacy Windows, handled by
compat/legacy_windows.h forced in with -include (no upstream edit).
"""
import argparse
import json
import os
import platform
import re
import shutil
import subprocess
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
REPO = HERE.parent
TARGETS = json.loads((HERE / "targets.json").read_text(encoding="utf-8"))
DEFAULT_NATIVE = REPO / "modules" / "modelling" / "src" / "main" / "native"


def log(msg):
    print(f"\033[1;34m[port] {msg}\033[0m", flush=True)


def warn(msg):
    print(f"\033[1;33m[port] WARN: {msg}\033[0m", flush=True)


def die(msg):
    print(f"\033[1;31m[port] ERROR: {msg}\033[0m", flush=True)
    raise SystemExit(1)


def run(cmd, **kw):
    log("$ " + " ".join(str(c) for c in cmd))
    return subprocess.run([str(c) for c in cmd], **kw)


def tool(*names):
    for n in names:
        # An absolute path passed via --cmake / CMAKE should work directly.
        if os.path.isabs(n) and os.path.isfile(n):
            return n
        p = shutil.which(n)
        if p:
            return p
    # Windows installs of CMake/Ninja are frequently not on PATH.
    if os.name == "nt":
        extra = {
            "cmake": [r"C:\Program Files\CMake\bin\cmake.exe",
                      r"C:\Program Files (x86)\CMake\bin\cmake.exe"],
            "ninja": [r"D:\ninja-win\ninja.exe",
                      r"C:\Program Files\CMake\bin\ninja.exe"],
        }
        for n in names:
            for p in extra.get(n, []):
                if os.path.isfile(p):
                    return p
    return None


def cmake_for_target(t):
    """Pick a generator that exists on this host."""
    ninja = tool("ninja")
    return "Ninja" if ninja else ("Unix Makefiles" if os.name != "nt" else "MinGW Makefiles")


def build_one(name, t, args):
    if name.startswith("_"):
        return None
    classifier = t["classifier"]
    log(f"=== {name} -> {classifier} ({t['arch']} / {t['os']}) ===")

    native = Path(args.native_src or os.environ.get("NATIVE_SRC") or DEFAULT_NATIVE).resolve()
    if not (native / "CMakeLists.txt").is_file():
        die(f"native source tree not found: {native}")

    cmake = tool(args.cmake or os.environ.get("CMAKE") or "cmake") or tool("cmake")
    if not cmake:
        die("cmake not found on PATH")

    tc = HERE / "targets" / t["toolchain"]
    if not tc.is_file():
        die(f"toolchain file missing: {tc}")

    build_dir = Path(args.build_dir or os.environ.get("KASUGA_BUILD_DIR")
                     or (HERE / "build" / name)).resolve()
    out_dir = Path(args.out_dir or os.environ.get("KASUGA_OUT_DIR")
                   or (HERE / "out")).resolve()
    stage = out_dir / "native" / classifier
    build_dir.mkdir(parents=True, exist_ok=True)
    stage.mkdir(parents=True, exist_ok=True)

    gen = cmake_for_target(t)
    cmd = [
        cmake, "-S", native, "-B", build_dir, "-G", gen, "-Wno-dev",
        f"-DCMAKE_TOOLCHAIN_FILE={tc.as_posix()}",
        f"-DCMAKE_MODULE_PATH={(HERE / 'cmake').as_posix()}",
        "-DCMAKE_BUILD_TYPE=Release",
        f"-DKASUGA_NATIVE_CLASSIFIER={classifier}",
        "-DBOX3D_DISABLE_SIMD=ON",
        "-DBUILD_SHARED_LIBS=OFF",
        "-DBOX3D_SAMPLES=OFF", "-DBOX3D_BENCHMARKS=OFF", "-DBOX3D_DOCS=OFF",
        "-DBOX3D_PROFILE=OFF", "-DBOX3D_VALIDATE=OFF", "-DBOX3D_UNIT_TESTS=OFF",
        "-DBOX3D_COMPILE_WARNING_AS_ERROR=OFF",
        f"-DKASUGA_JNI_MD_SUBDIR={t['jni_md']}",
    ]

    jni = t.get("jni_include") or os.environ.get("KASUGA_JNI_INCLUDE_DIR") or ""
    if jni and not Path(jni).is_dir():
        # A Windows JDK path in targets.json is meaningless on the build host.
        jni = ""
    if not jni and os.environ.get("JAVA_HOME"):
        jni = os.path.join(os.environ["JAVA_HOME"], "include")
    if not jni and os.name != "nt":
        import glob
        cands = sorted(glob.glob("/usr/lib/jvm/*/include"))
        if cands:
            jni = cands[0]
    if jni:
        cmd.append(f"-DKASUGA_JNI_INCLUDE_DIR={Path(jni).as_posix()}")
        cmd.append(f"-DJAVA_HOME={Path(jni).parent.as_posix()}")

    if t["host"] == "windows":
        mingw_root = os.environ.get("MINGW_ROOT") or t.get("mingw_root", "")
        cmd += [
            f"-DMINGW_ROOT={Path(mingw_root).as_posix() if mingw_root else ''}",
            f"-DMINGW_TRIPLE={t['triple']}",
            # Explicitly tell the toolchain whether the host tool names carry
            # .exe; more reliable than probing CMAKE_HOST_WIN32 in a toolchain.
            f"-DMINGW_EXE_SUFFIX={'.exe' if os.name == 'nt' else ''}",
        ]
        compat = t.get("compat_header")
        if compat:
            cmd.append(f"-DKASUGA_COMPAT_HEADER={(HERE / compat).as_posix()}")
    elif name == "linux-ia64":
        # Environment wins over targets.json so a relocatable bundle
        # (kasuga-ia64-toolchain/env.sh) can be unpacked anywhere.
        sysroot = os.environ.get("IA64_SYSROOT") or t.get("sysroot", "")
        prefix = os.environ.get("IA64_TOOLCHAIN_PREFIX")
        if not prefix:
            prefix = f"{t.get('toolchain_dir', '/opt/cross/bin')}/{t['triple']}-"
        cmd += [
            f"-DIA64_SYSROOT={Path(sysroot).as_posix() if sysroot else ''}",
            f"-DIA64_TOOLCHAIN_PREFIX={prefix}",
        ]
    else:
        cmd += [
            f"-DKASUGA_TARGET_TRIPLE={t['triple']}",
            f"-DKASUGA_TARGET_CPU={t.get('cpu', t['arch'])}",
        ]
        if t.get("sysroot"):
            cmd.append(f"-DKASUGA_SYSROOT={t['sysroot']}")
        if t.get("toolchain_dir"):
            cmd.append(f"-DKASUGA_TOOLCHAIN_DIR={t['toolchain_dir']}")

    log("Configuring")
    r = run(cmd)
    if r.returncode != 0:
        die("cmake configure failed")

    jobs = args.jobs or os.environ.get("KASUGA_JOBS") or str(os.cpu_count() or 4)
    log(f"Building (jobs={jobs})")
    r = run([cmake, "--build", build_dir, "--target", "kasuga_box3d",
             "--config", "Release", "--parallel", jobs])
    if r.returncode != 0:
        die("build failed")

    # CMake on Windows with a GNU-ish compiler may emit "lib<name>.dll" even
    # when we ask for no prefix (the platform module re-sets the variable).
    # Accept both, but always stage under the name Java's mapLibraryName wants.
    wanted = [t["libname"], t.get("built_name", ""),
              "lib" + t["libname"]]
    produced = None
    for w in wanted:
        if not w:
            continue
        p = build_dir / "resources" / "native" / classifier / w
        if p.is_file():
            produced = p
            break
    if produced is None:
        suffix = ".dll" if t["host"] == "windows" else ".so"
        found = sorted(build_dir.rglob("*" + suffix),
                       key=lambda p: p.stat().st_mtime, reverse=True)
        if not found:
            die(f"library not produced under {build_dir}")
        produced = found[0]
    if produced.name != t["libname"]:
        log(f"Note: linker emitted {produced.name}; staging as {t['libname']}")

    log(f"Built: {produced} ({produced.stat().st_size} bytes)")
    dest = stage / t["libname"]
    shutil.copy2(produced, dest)
    log(f"Staged: {dest}")

    verify(dest, t)
    return dest


def verify(path, t):
    """Architecture/format checks that do not require running the target."""
    log(f"Verifying {path.name}")
    data = path.read_bytes()
    if t["host"] == "windows":
        if data[:2] != b"MZ":
            die("not a PE image (no MZ)")
        # machine field at PE header offset
        import struct
        pe = struct.unpack_from("<I", data, 0x3C)[0]
        machine = struct.unpack_from("<H", data, pe + 4)[0]
        names = {0x8664: "AMD64", 0xAA64: "ARM64", 0x14C: "I386"}
        got = names.get(machine, hex(machine))
        log(f"  PE machine: {got}")
        expect = "ARM64" if t["arch"] == "ARM64" else "AMD64"
        if got != expect:
            die(f"wrong PE machine: expected {expect}, got {got}")
    else:
        if data[:4] != b"\x7fELF":
            die("not an ELF image")
        ei_class, ei_data = data[4], data[5]
        log(f"  ELF class: {'ELF64' if ei_class == 2 else 'ELF32'}, "
            f"endian: {'big' if ei_data == 2 else 'little'}")
        if ei_class != 2:
            die("not ELF64")
        want_big = t["endian"] == "big"
        if (ei_data == 2) != want_big:
            die(f"endianness mismatch: expected {'big' if want_big else 'little'}")
    log("  PASS")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--list", action="store_true")
    ap.add_argument("--target")
    ap.add_argument("--all-host", choices=["windows", "buildhost"])
    ap.add_argument("--native-src")
    ap.add_argument("--build-dir")
    ap.add_argument("--out-dir")
    ap.add_argument("--cmake")
    ap.add_argument("--jobs")
    args = ap.parse_args()
    names = [k for k in TARGETS if not k.startswith("_")]

    if args.list:
        print(f"{'target':26} {'classifier':20} {'arch':16} {'host':10} {'endian':7} status")
        for n in names:
            t = TARGETS[n]
            print(f"{n:26} {t['classifier']:20} {t['arch']:16} {t['host']:10} "
                  f"{t['endian']:7} {t['status']}")
        return 0

    todo = []
    if args.target:
        if args.target not in TARGETS:
            die(f"unknown target: {args.target}")
        todo = [args.target]
    elif args.all_host:
        todo = [n for n in names if TARGETS[n]["host"] == args.all_host]
    else:
        ap.print_help()
        return 2

    ok, failed = [], []
    for n in todo:
        try:
            d = build_one(n, TARGETS[n], args)
            if d:
                ok.append((n, d))
        except SystemExit:
            failed.append(n)
        except Exception as ex:  # noqa: BLE001
            print(f"[port] {n}: unexpected error: {ex}", flush=True)
            failed.append(n)

    log(f"SUMMARY: {len(ok)} succeeded, {len(failed)} failed")
    for n, d in ok:
        print(f"  OK   {n:26} -> {d}")
    for n in failed:
        print(f"  FAIL {n}")
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
