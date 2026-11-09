# ia64-linux-gnu.toolchain.cmake
#
# CMake toolchain for cross-compiling KasugaLibNext's Box3D JNI native library
# from an x86_64 Debian 13 build host to Linux/IA-64 (Itanium).
#
# Target runtime: T2/Linux, glibc 2.43, 16 KiB pages, little endian, LP64.
# Toolchain: GCC 15.2.0 / binutils 2.46 with the ia64-linux-gnu- prefix.
#
# Normally you do NOT call cmake by hand; use ../build_ia64.sh, which supplies
# every -D below. This file is also usable standalone:
#
#   cmake -S <repo>/modules/modelling/src/main/native -B <build> \
#     -DCMAKE_TOOLCHAIN_FILE=<this file> \
#     -DCMAKE_MODULE_PATH=<dir containing our FindJNI.cmake> \
#     -DIA64_SYSROOT=/opt/ia64/rootfs \
#     -DKASUGA_JNI_INCLUDE_DIR=<jdk>/include \
#     -DKASUGA_NATIVE_CLASSIFIER=linux-ia64 \
#     -DBOX3D_DISABLE_SIMD=ON -DCMAKE_BUILD_TYPE=Release
#
# Knobs (command line -D wins, then environment, then the default):
#   IA64_SYSROOT             target rootfs, default /opt/ia64/rootfs
#   IA64_TOOLCHAIN_PREFIX    cross tools prefix, default ia64-linux-gnu-
#   KASUGA_JNI_INCLUDE_DIR   directory containing jni.h (see FindJNI.cmake)

# ---------------------------------------------------------------- target ----
set(CMAKE_SYSTEM_NAME Linux)
set(CMAKE_SYSTEM_PROCESSOR ia64)
set(CMAKE_SYSTEM_VERSION 1)

# --------------------------------------------------------------- sysroot ----
if(NOT DEFINED IA64_SYSROOT OR "${IA64_SYSROOT}" STREQUAL "")
    if(DEFINED ENV{IA64_SYSROOT} AND NOT "$ENV{IA64_SYSROOT}" STREQUAL "")
        set(IA64_SYSROOT "$ENV{IA64_SYSROOT}")
    else()
        set(IA64_SYSROOT "/opt/ia64/rootfs")
    endif()
endif()
set(IA64_SYSROOT "${IA64_SYSROOT}" CACHE PATH "T2/Linux IA-64 sysroot" FORCE)

# ------------------------------------------------------------- toolchain ----
if(NOT DEFINED IA64_TOOLCHAIN_PREFIX OR "${IA64_TOOLCHAIN_PREFIX}" STREQUAL "")
    if(DEFINED ENV{IA64_TOOLCHAIN_PREFIX} AND NOT "$ENV{IA64_TOOLCHAIN_PREFIX}" STREQUAL "")
        set(IA64_TOOLCHAIN_PREFIX "$ENV{IA64_TOOLCHAIN_PREFIX}")
    else()
        set(IA64_TOOLCHAIN_PREFIX "ia64-linux-gnu-")
    endif()
endif()
set(IA64_TOOLCHAIN_PREFIX "${IA64_TOOLCHAIN_PREFIX}" CACHE STRING
    "IA-64 cross toolchain prefix (e.g. ia64-linux-gnu- or /opt/ia64/bin/ia64-linux-gnu-)" FORCE)

# box3d/CMakeLists.txt declares project(box3d LANGUAGES C CXX). Even though all
# 50 library sources are .c and no C++ source is ever compiled, CMake still runs
# a compiler sanity check for CXX, so an ia64-linux-gnu-g++ MUST be installed.
set(CMAKE_C_COMPILER   "${IA64_TOOLCHAIN_PREFIX}gcc")
set(CMAKE_CXX_COMPILER "${IA64_TOOLCHAIN_PREFIX}g++")
set(CMAKE_AR           "${IA64_TOOLCHAIN_PREFIX}ar"     CACHE FILEPATH "IA-64 ar"     FORCE)
set(CMAKE_RANLIB       "${IA64_TOOLCHAIN_PREFIX}ranlib" CACHE FILEPATH "IA-64 ranlib" FORCE)
set(CMAKE_STRIP        "${IA64_TOOLCHAIN_PREFIX}strip"  CACHE FILEPATH "IA-64 strip"  FORCE)

set(CMAKE_SYSROOT "${IA64_SYSROOT}")

# Never let find_library/find_path leak x86_64 host artifacts into the target.
set(CMAKE_FIND_ROOT_PATH "${IA64_SYSROOT}")
set(CMAKE_FIND_ROOT_PATH_MODE_PROGRAM NEVER)
set(CMAKE_FIND_ROOT_PATH_MODE_LIBRARY ONLY)
set(CMAKE_FIND_ROOT_PATH_MODE_INCLUDE ONLY)
set(CMAKE_FIND_ROOT_PATH_MODE_PACKAGE ONLY)

# try_compile would otherwise attempt to *link* an IA-64 executable, which can
# fail before the sysroot's crt/dynamic linker are wired up.
set(CMAKE_TRY_COMPILE_TARGET_TYPE STATIC_LIBRARY)

# ---------------------------------------------------------- compiler flags --
# GCC 15 on IA-64 hits an internal compiler error in the selective scheduling
# passes on several Box3D translation units (documented in nsafran1217/jdk).
# Disabling both passes is the known-good workaround.
#
# -pthread: box3d/src/timer.c's __linux__ branch calls pthread_create, but
# box3d/src/CMakeLists.txt never calls find_package(Threads). On glibc >= 2.34
# pthread symbols live in libc so it links anyway, but adding it explicitly
# keeps the build correct for any sysroot and defines _REENTRANT consistently.
set(_IA64_SAFE_FLAGS "-fno-selective-scheduling -fno-selective-scheduling2 -pthread")
set(CMAKE_C_FLAGS_INIT   "${_IA64_SAFE_FLAGS}")
set(CMAKE_CXX_FLAGS_INIT "${_IA64_SAFE_FLAGS}")
# -z noexecstack: GCC/binutils on IA-64 do not emit the PT_GNU_STACK note for
# C-only shared objects unless asked, so the resulting .so ends up with an
# executable stack. HotSpot then prints "might have disabled stack guard" on
# System.load() and has to patch the guard at runtime. Explicitly mark the
# stack non-executable (standard hardening for any JNI library).
set(CMAKE_EXE_LINKER_FLAGS_INIT    "-pthread -Wl,-z,noexecstack")
set(CMAKE_SHARED_LINKER_FLAGS_INIT "-pthread -Wl,-z,noexecstack")

# --------------------------------------------------------------------- JNI --
# The vendored CMakeLists.txt calls find_package(JNI REQUIRED). CMake's builtin
# FindJNI probes the x86_64 host JDK and would drag a host libjvm.so into an
# IA-64 shared object. build_ia64.sh prepends our own FindJNI.cmake via
# CMAKE_MODULE_PATH; that module exposes headers only and leaves
# JNI_LIBRARIES empty (correct for a Linux JNI library).
# Do NOT remove CMAKE_MODULE_PATH from the cmake invocation.
