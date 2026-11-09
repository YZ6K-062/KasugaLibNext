# windows-aarch64.toolchain.cmake
#
# Target: Windows on ARM (ARM64), cross-compiled from x86_64 Windows.
# Toolchain: llvm-mingw 20261104 (LLVM 23.1.5), msvcrt variant, which ships an
# aarch64-w64-mingw32 sysroot. GCC-based MinGW cannot target Windows ARM64.
#
# The XP-oriented llvm-mingw-xp toolchain only has i686/x86_64 targets, so
# Windows on ARM needs this separate one. Modern Windows on ARM provides
# CreateSemaphoreExW, so NO compat shim is needed (unlike the legacy target).

set(CMAKE_SYSTEM_NAME Windows)
set(CMAKE_SYSTEM_PROCESSOR ARM64)

# MINGW_ROOT can be overridden by -D or by the environment, so the same
# toolchain works on both the Windows host (zip package) and a Linux CI runner
# (the llvm-mingw-*-ubuntu-*.tar.xz cross package).
if(NOT DEFINED MINGW_ROOT OR "${MINGW_ROOT}" STREQUAL "")
    if(DEFINED ENV{MINGW_ROOT} AND NOT "$ENV{MINGW_ROOT}" STREQUAL "")
        set(MINGW_ROOT "$ENV{MINGW_ROOT}")
    else()
        set(MINGW_ROOT "D:/llvm-mingw-20261104-msvcrt-x86_64")
    endif()
endif()
if(NOT DEFINED MINGW_TRIPLE OR "${MINGW_TRIPLE}" STREQUAL "")
    set(MINGW_TRIPLE "aarch64-w64-mingw32")
endif()

# Windows llvm-mingw tools carry .exe; the Linux cross package does not.
if(DEFINED MINGW_EXE_SUFFIX)
    set(_exe "${MINGW_EXE_SUFFIX}")
elseif(CMAKE_HOST_WIN32)
    set(_exe ".exe")
else()
    set(_exe "")
endif()

set(_pfx "${MINGW_ROOT}/bin/${MINGW_TRIPLE}")
set(CMAKE_C_COMPILER   "${_pfx}-clang${_exe}")
set(CMAKE_CXX_COMPILER "${_pfx}-clang++${_exe}")
set(CMAKE_AR           "${_pfx}-llvm-ar${_exe}"     CACHE FILEPATH "" FORCE)
set(CMAKE_RANLIB       "${_pfx}-llvm-ranlib${_exe}" CACHE FILEPATH "" FORCE)
set(CMAKE_RC_COMPILER  "${_pfx}-windres${_exe}"     CACHE FILEPATH "" FORCE)
set(CMAKE_STRIP        "${_pfx}-strip${_exe}"       CACHE FILEPATH "" FORCE)

set(CMAKE_C_COMPILER_TARGET   "${MINGW_TRIPLE}")
set(CMAKE_CXX_COMPILER_TARGET "${MINGW_TRIPLE}")

# System.mapLibraryName("kasuga_box3d") == "kasuga_box3d.dll" on Windows.
set(CMAKE_SHARED_LIBRARY_PREFIX "")
set(CMAKE_SHARED_LIBRARY_SUFFIX ".dll")
set(CMAKE_IMPORT_LIBRARY_PREFIX "")
set(CMAKE_IMPORT_LIBRARY_SUFFIX ".dll.a")
set(CMAKE_EXECUTABLE_SUFFIX ".exe")

# Never try to RUN ARM64 test binaries on an x86_64 host.
set(CMAKE_CROSSCOMPILING TRUE)
set(CMAKE_TRY_COMPILE_TARGET_TYPE STATIC_LIBRARY)

set(CMAKE_C_FLAGS_INIT   "-ffp-contract=off")
set(CMAKE_CXX_FLAGS_INIT "-ffp-contract=off")
set(CMAKE_SHARED_LINKER_FLAGS_INIT "-static-libgcc")
set(CMAKE_EXE_LINKER_FLAGS_INIT    "-static-libgcc")

set(CMAKE_FIND_ROOT_PATH "${MINGW_ROOT}/${MINGW_TRIPLE}")
set(CMAKE_FIND_ROOT_PATH_MODE_PROGRAM NEVER)
set(CMAKE_FIND_ROOT_PATH_MODE_LIBRARY ONLY)
set(CMAKE_FIND_ROOT_PATH_MODE_INCLUDE ONLY)
set(CMAKE_FIND_ROOT_PATH_MODE_PACKAGE ONLY)
