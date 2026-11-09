# linux-generic.toolchain.cmake -- parameterised Linux cross toolchain.
#
# Used for s390x, ppc64 (big endian), ppc64le, aarch64. Knobs come from
# build.py via -D, from the environment, or from CMAKE_TRY_COMPILE_PLATFORM_
# VARIABLES (CMake re-reads this file inside try_compile sub-projects, which do
# NOT inherit ordinary -D variables).
#
#   KASUGA_TARGET_TRIPLE   e.g. s390x-linux-gnu / powerpc64-linux-gnu
#   KASUGA_TARGET_CPU      CMAKE_SYSTEM_PROCESSOR
#   KASUGA_SYSROOT         optional explicit sysroot
#   KASUGA_TOOLCHAIN_DIR   optional absolute dir containing the compilers
#   KASUGA_EXTRA_CFLAGS    extra target-specific C flags
#
# Endianness: s390x and ppc64 are BIG ENDIAN. Box3D has an explicit big-endian
# branch in timer.c; build.py verifies the ELF EI_DATA byte and the runtime
# smoke test asserts numeric results.

# Propagate our knobs into CMake's compiler-detection try_compile projects.
set(CMAKE_TRY_COMPILE_PLATFORM_VARIABLES
    KASUGA_TARGET_TRIPLE KASUGA_TARGET_CPU KASUGA_SYSROOT
    KASUGA_TOOLCHAIN_DIR KASUGA_EXTRA_CFLAGS)

if(NOT KASUGA_TARGET_TRIPLE AND DEFINED ENV{KASUGA_TARGET_TRIPLE})
    set(KASUGA_TARGET_TRIPLE "$ENV{KASUGA_TARGET_TRIPLE}")
endif()
if(NOT DEFINED KASUGA_TARGET_TRIPLE OR "${KASUGA_TARGET_TRIPLE}" STREQUAL "")
    message(FATAL_ERROR "KASUGA_TARGET_TRIPLE is required (and was not inherited by try_compile)")
endif()
if(NOT DEFINED KASUGA_TARGET_CPU OR "${KASUGA_TARGET_CPU}" STREQUAL "")
    set(KASUGA_TARGET_CPU "unknown")
endif()

set(CMAKE_SYSTEM_NAME Linux)
set(CMAKE_SYSTEM_PROCESSOR "${KASUGA_TARGET_CPU}")
set(CMAKE_SYSTEM_VERSION 1)

set(_pfx "${KASUGA_TARGET_TRIPLE}-")
if(DEFINED KASUGA_TOOLCHAIN_DIR AND NOT "${KASUGA_TOOLCHAIN_DIR}" STREQUAL "")
    set(_pfx "${KASUGA_TOOLCHAIN_DIR}/${KASUGA_TARGET_TRIPLE}-")
endif()

set(CMAKE_C_COMPILER   "${_pfx}gcc")
set(CMAKE_CXX_COMPILER "${_pfx}g++")
set(CMAKE_AR           "${_pfx}ar"     CACHE FILEPATH "" FORCE)
set(CMAKE_RANLIB       "${_pfx}ranlib" CACHE FILEPATH "" FORCE)
set(CMAKE_STRIP        "${_pfx}strip"  CACHE FILEPATH "" FORCE)
set(CMAKE_LINKER       "${_pfx}ld"     CACHE FILEPATH "" FORCE)

if(DEFINED KASUGA_SYSROOT AND NOT "${KASUGA_SYSROOT}" STREQUAL "")
    set(CMAKE_SYSROOT "${KASUGA_SYSROOT}")
    set(CMAKE_FIND_ROOT_PATH "${KASUGA_SYSROOT}")
endif()
set(CMAKE_FIND_ROOT_PATH_MODE_PROGRAM NEVER)
set(CMAKE_FIND_ROOT_PATH_MODE_LIBRARY ONLY)
set(CMAKE_FIND_ROOT_PATH_MODE_INCLUDE ONLY)
set(CMAKE_FIND_ROOT_PATH_MODE_PACKAGE ONLY)
set(CMAKE_TRY_COMPILE_TARGET_TYPE STATIC_LIBRARY)

# -pthread: timer.c's __linux__ branch calls pthread_create but box3d never
# calls find_package(Threads).
set(_flags "-pthread -ffp-contract=off ${KASUGA_EXTRA_CFLAGS}")
set(CMAKE_C_FLAGS_INIT   "${_flags}")
set(CMAKE_CXX_FLAGS_INIT "${_flags}")
set(CMAKE_EXE_LINKER_FLAGS_INIT    "-pthread -Wl,-z,noexecstack")
set(CMAKE_SHARED_LINKER_FLAGS_INIT "-pthread -Wl,-z,noexecstack")
