# linux-ia64.toolchain.cmake -- Linux/IA-64 (Itanium), T2/Linux target.
#
# Verified 2026-11-08 on the Debian 13 build host: produced a working
# libkasuga_box3d.so that passed the gravity-drop smoke test on a real IA-64
# guest under QEMU. Kept here as one target of the native matrix.
#
# Knobs (set by build.sh):
#   IA64_SYSROOT             default /opt/ia64/rootfs
#   IA64_TOOLCHAIN_PREFIX    default ia64-linux-gnu- (or an absolute prefix)

set(CMAKE_SYSTEM_NAME Linux)
set(CMAKE_SYSTEM_PROCESSOR ia64)
set(CMAKE_SYSTEM_VERSION 1)

# CMake re-reads the toolchain inside try_compile sub-projects, which do not
# inherit ordinary -D variables. Propagate our knobs explicitly.
set(CMAKE_TRY_COMPILE_PLATFORM_VARIABLES IA64_SYSROOT IA64_TOOLCHAIN_PREFIX)

if(NOT DEFINED IA64_SYSROOT OR "${IA64_SYSROOT}" STREQUAL "")
    set(IA64_SYSROOT "/opt/ia64/rootfs")
endif()
if(NOT DEFINED IA64_TOOLCHAIN_PREFIX OR "${IA64_TOOLCHAIN_PREFIX}" STREQUAL "")
    set(IA64_TOOLCHAIN_PREFIX "ia64-linux-gnu-")
endif()
set(IA64_SYSROOT "${IA64_SYSROOT}" CACHE PATH "T2/Linux IA-64 sysroot" FORCE)
set(IA64_TOOLCHAIN_PREFIX "${IA64_TOOLCHAIN_PREFIX}" CACHE STRING "IA-64 toolchain prefix" FORCE)

set(CMAKE_C_COMPILER   "${IA64_TOOLCHAIN_PREFIX}gcc")
set(CMAKE_CXX_COMPILER "${IA64_TOOLCHAIN_PREFIX}g++")
set(CMAKE_AR           "${IA64_TOOLCHAIN_PREFIX}ar"     CACHE FILEPATH "" FORCE)
set(CMAKE_RANLIB       "${IA64_TOOLCHAIN_PREFIX}ranlib" CACHE FILEPATH "" FORCE)
set(CMAKE_STRIP        "${IA64_TOOLCHAIN_PREFIX}strip"  CACHE FILEPATH "" FORCE)

set(CMAKE_SYSROOT "${IA64_SYSROOT}")
set(CMAKE_FIND_ROOT_PATH "${IA64_SYSROOT}")
set(CMAKE_FIND_ROOT_PATH_MODE_PROGRAM NEVER)
set(CMAKE_FIND_ROOT_PATH_MODE_LIBRARY ONLY)
set(CMAKE_FIND_ROOT_PATH_MODE_INCLUDE ONLY)
set(CMAKE_FIND_ROOT_PATH_MODE_PACKAGE ONLY)
set(CMAKE_TRY_COMPILE_TARGET_TYPE STATIC_LIBRARY)

# GCC on IA-64 ICEs in the selective scheduling passes on some Box3D TUs.
# -pthread: timer.c's __linux__ branch calls pthread_create but box3d never
# calls find_package(Threads).
set(_safe "-fno-selective-scheduling -fno-selective-scheduling2 -pthread")
set(CMAKE_C_FLAGS_INIT   "${_safe}")
set(CMAKE_CXX_FLAGS_INIT "${_safe}")

# IA-64 C-only shared objects otherwise lack a PT_GNU_STACK note; HotSpot then
# warns "might have disabled stack guard" on System.load().
set(CMAKE_EXE_LINKER_FLAGS_INIT    "-pthread -Wl,-z,noexecstack")
set(CMAKE_SHARED_LINKER_FLAGS_INIT "-pthread -Wl,-z,noexecstack")
