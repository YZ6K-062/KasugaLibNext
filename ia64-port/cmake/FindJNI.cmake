# FindJNI.cmake -- cross-compilation shim for Linux/IA-64 (KasugaLibNext port)
#
# WHY THIS EXISTS
# ---------------
# The vendored CMakeLists.txt calls `find_package(JNI REQUIRED)` and then does
#     target_include_directories(kasuga_box3d PRIVATE ${JNI_INCLUDE_DIRS})
#     target_link_libraries(kasuga_box3d PRIVATE box3d::box3d ${JNI_LIBRARIES})
#
# CMake's builtin FindJNI, when cross-compiling, will probe the *x86_64 build
# host*: it finds the host JDK, and (much worse) puts host libjvm.so / libjawt.so
# into JNI_LIBRARIES. Linking those into an IA-64 shared object either fails
# outright ("skipping incompatible ...") or produces a broken DT_NEEDED.
#
# On Linux a JNI shared library must NOT link libjvm at all: every JNI call goes
# through the JNIEnv function table supplied by the embedding JVM at dlopen()
# time, and the JVM resolves Java_* entry points out of our .so. So the correct
# result of FindJNI is: headers only, JNI_LIBRARIES empty.
#
# jni.h / jni_md.h are architecture-neutral (LP64 is identical on x86_64 and
# IA-64; both little endian), so headers from ANY Linux JDK 8+ work. Prefer the
# IA-64 JDK built from nsafran1217/jdk if you have it, otherwise a host JDK is
# ABI-safe. JDK 9+ jni_md.h defines JNIEXPORT with default visibility, which is
# REQUIRED because the vendored CMakeLists sets C_VISIBILITY_PRESET hidden.
#
# USAGE
# -----
# build_ia64.sh puts this directory first in CMAKE_MODULE_PATH, so this module
# shadows the builtin one. Point it at headers with:
#     -DKASUGA_JNI_INCLUDE_DIR=/path/to/jdk/include
# or set the JAVA_HOME environment variable. Without either, the common Linux
# JDK locations below are probed.

include(FindPackageHandleStandardArgs)

set(_jni_hints "")

if(DEFINED KASUGA_JNI_INCLUDE_DIR AND NOT "${KASUGA_JNI_INCLUDE_DIR}" STREQUAL "")
    list(APPEND _jni_hints "${KASUGA_JNI_INCLUDE_DIR}")
endif()
if(DEFINED ENV{KASUGA_JNI_INCLUDE_DIR} AND NOT "$ENV{KASUGA_JNI_INCLUDE_DIR}" STREQUAL "")
    list(APPEND _jni_hints "$ENV{KASUGA_JNI_INCLUDE_DIR}")
endif()
if(DEFINED ENV{JAVA_HOME} AND NOT "$ENV{JAVA_HOME}" STREQUAL "")
    list(APPEND _jni_hints "$ENV{JAVA_HOME}/include")
endif()
if(DEFINED JAVA_HOME AND NOT "${JAVA_HOME}" STREQUAL "")
    list(APPEND _jni_hints "${JAVA_HOME}/include")
endif()
list(APPEND _jni_hints
    "/opt/ia64/jdk/include"
    "/usr/lib/jvm/default-java/include"
    "/usr/lib/jvm/java-21-openjdk-amd64/include"
    "/usr/lib/jvm/java-17-openjdk-amd64/include"
    "/usr/lib/jvm/java-21-openjdk/include"
    "/usr/lib/jvm/java-17-openjdk/include")

# Use EXISTS checks instead of find_path(): CMAKE_FIND_ROOT_PATH_MODE_INCLUDE is
# ONLY, which would otherwise re-root every probe into the IA-64 sysroot where
# no JDK lives.
set(JAVA_INCLUDE_PATH "")
set(JAVA_INCLUDE_PATH2 "")
foreach(_hint IN LISTS _jni_hints)
    if(EXISTS "${_hint}/jni.h")
        set(JAVA_INCLUDE_PATH "${_hint}")
        # jni_md.h is platform-specific; on Linux it lives in include/linux/.
        foreach(_md "${_hint}/linux" "${_hint}")
            if(EXISTS "${_md}/jni_md.h")
                set(JAVA_INCLUDE_PATH2 "${_md}")
                break()
            endif()
        endforeach()
        break()
    endif()
endforeach()

# Headers only. Deliberately empty -- see "WHY THIS EXISTS" above.
set(JNI_LIBRARIES "")
set(JAVA_AWT_LIBRARY "")
set(JAVA_JVM_LIBRARY "")
set(JAVA_AWT_INCLUDE_PATH "${JAVA_INCLUDE_PATH}")

set(JNI_INCLUDE_DIRS "")
if(JAVA_INCLUDE_PATH)
    list(APPEND JNI_INCLUDE_DIRS "${JAVA_INCLUDE_PATH}")
endif()
if(JAVA_INCLUDE_PATH2)
    list(APPEND JNI_INCLUDE_DIRS "${JAVA_INCLUDE_PATH2}")
endif()
list(REMOVE_DUPLICATES JNI_INCLUDE_DIRS)

# NOTE: FAIL_MESSAGE must be ONE CMake argument. Adjacent quoted strings are
# separate arguments in CMake (not concatenated like in C) and would be parsed
# as unknown keywords by find_package_handle_standard_args().
find_package_handle_standard_args(JNI
    REQUIRED_VARS JAVA_INCLUDE_PATH JAVA_INCLUDE_PATH2
    FAIL_MESSAGE "FindJNI (IA-64 cross): jni.h / jni_md.h not found. Pass -DKASUGA_JNI_INCLUDE_DIR=<jdk>/include (requires <jdk>/include/linux/jni_md.h) or export JAVA_HOME. Any Linux JDK 8+ is ABI-compatible.")

# Exported for diagnostics in the configure log.
message(STATUS "FindJNI (IA-64 cross): includes = ${JNI_INCLUDE_DIRS}")
message(STATUS "FindJNI (IA-64 cross): JNI_LIBRARIES intentionally empty (no libjvm link)")
