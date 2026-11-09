# windows-x86_64-legacy.toolchain.cmake
#
# Target: x86-64 Windows, "legacy" profile (XP x64 / Server 2003 x64 compatible).
# Toolchain: D:/llvm-mingw-xp-22.1.7-msvcrt-x86_64 (clang 22, msvcrt, _WIN32_WINNT=0x0501)
#
# Knobs (set by build.sh):
#   MINGW_ROOT      e.g. D:/llvm-mingw-xp-22.1.7-msvcrt-x86_64
#   MINGW_TRIPLE    e.g. x86_64-w64-mingw32
#   KASUGA_COMPAT_HEADER  absolute path to compat/legacy_windows.h

set(CMAKE_SYSTEM_NAME Windows)
set(CMAKE_SYSTEM_PROCESSOR AMD64)

if(NOT DEFINED MINGW_ROOT OR "${MINGW_ROOT}" STREQUAL "")
    set(MINGW_ROOT "D:/llvm-mingw-xp-22.1.7-msvcrt-x86_64")
endif()
if(NOT DEFINED MINGW_TRIPLE OR "${MINGW_TRIPLE}" STREQUAL "")
    set(MINGW_TRIPLE "x86_64-w64-mingw32")
endif()

set(_pfx "${MINGW_ROOT}/bin/${MINGW_TRIPLE}")
set(CMAKE_C_COMPILER   "${_pfx}-clang.exe")
set(CMAKE_CXX_COMPILER "${_pfx}-clang++.exe")
set(CMAKE_AR           "${_pfx}-llvm-ar.exe"     CACHE FILEPATH "" FORCE)
set(CMAKE_RANLIB       "${_pfx}-llvm-ranlib.exe" CACHE FILEPATH "" FORCE)
set(CMAKE_RC_COMPILER  "${_pfx}-windres.exe"     CACHE FILEPATH "" FORCE)
set(CMAKE_STRIP        "${_pfx}-strip.exe"       CACHE FILEPATH "" FORCE)

set(CMAKE_C_COMPILER_TARGET   "${MINGW_TRIPLE}")
set(CMAKE_CXX_COMPILER_TARGET "${MINGW_TRIPLE}")

# Java's System.mapLibraryName("kasuga_box3d") returns "kasuga_box3d.dll" on
# Windows. CMake with a GNU-ish compiler otherwise emits "libkasuga_box3d.dll",
# which the runtime loader would never find. Pin the PE naming explicitly.
set(CMAKE_SHARED_LIBRARY_PREFIX "")
set(CMAKE_SHARED_LIBRARY_SUFFIX ".dll")
set(CMAKE_IMPORT_LIBRARY_PREFIX "")
set(CMAKE_IMPORT_LIBRARY_SUFFIX ".dll.a")
set(CMAKE_EXECUTABLE_SUFFIX ".exe")

# We are cross-compiling from a Windows host with a Windows-hosted clang whose
# default target is x86_64-w64-windows-gnu. Tell CMake not to assume the host
# compiler produces runnable test executables for a different triple.
set(CMAKE_CROSSCOMPILING TRUE)
set(CMAKE_TRY_COMPILE_TARGET_TYPE STATIC_LIBRARY)

# XP compatibility: keep the API surface at Windows XP x64 (NT 5.2).
# llvm-mingw-xp defaults to 0x0501 (XP); 0x0502 is Server 2003 / XP x64.
# Do NOT raise this to 0x0600: that would expose Vista+ APIs and produce a DLL
# that fails to load on XP even though it compiles.
add_compile_definitions(_WIN32_WINNT=0x0502 WINVER=0x0502)

# Force the legacy Windows compat shim into every TU (CreateSemaphoreExW ->
# CreateSemaphoreW). This keeps the vendored Box3D sources untouched.
if(DEFINED KASUGA_COMPAT_HEADER AND EXISTS "${KASUGA_COMPAT_HEADER}")
    string(REPLACE "\\" "/" _compat "${KASUGA_COMPAT_HEADER}")
    set(CMAKE_C_FLAGS_INIT   "-include ${_compat}")
    set(CMAKE_CXX_FLAGS_INIT "-include ${_compat}")
endif()

# Deterministic math (mirrors box3d's own -ffp-contract=off for GCC/Clang).
set(CMAKE_C_FLAGS_INIT   "${CMAKE_C_FLAGS_INIT} -ffp-contract=off")
set(CMAKE_CXX_FLAGS_INIT "${CMAKE_CXX_FLAGS_INIT} -ffp-contract=off")

# Static libstdc++/libgcc + no UCRT dependency: llvm-mingw-xp uses msvcrt.
set(CMAKE_SHARED_LINKER_FLAGS_INIT "-static-libgcc")
set(CMAKE_EXE_LINKER_FLAGS_INIT    "-static-libgcc")

# Never let find_* pick up host libraries from the Windows host toolchain dirs.
set(CMAKE_FIND_ROOT_PATH "${MINGW_ROOT}/${MINGW_TRIPLE}")
set(CMAKE_FIND_ROOT_PATH_MODE_PROGRAM NEVER)
set(CMAKE_FIND_ROOT_PATH_MODE_LIBRARY ONLY)
set(CMAKE_FIND_ROOT_PATH_MODE_INCLUDE ONLY)
set(CMAKE_FIND_ROOT_PATH_MODE_PACKAGE ONLY)
