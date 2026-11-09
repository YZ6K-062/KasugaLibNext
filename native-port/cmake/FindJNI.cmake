# FindJNI.cmake -- cross-compilation shim for the KasugaLibNext native matrix.
#
# WHY THIS EXISTS
# ---------------
# The vendored CMakeLists.txt calls `find_package(JNI REQUIRED)` and then does
#     target_include_directories(kasuga_box3d PRIVATE ${JNI_INCLUDE_DIRS})
#     target_link_libraries(kasuga_box3d PRIVATE box3d::box3d ${JNI_LIBRARIES})
#
# CMake's builtin FindJNI probes the BUILD HOST: when cross-compiling it finds
# the host JDK and puts host libjvm.so / libjawt.so (or jvm.lib on Windows)
# into JNI_LIBRARIES, which either fails to link or produces a broken DLL.
#
# A JNI shared library must NOT link libjvm at all: JNI calls go through the
# JNIEnv function table supplied by the embedding JVM at load time, and the JVM
# resolves Java_* entry points from our library. So the correct FindJNI result
# is: headers only, JNI_LIBRARIES empty.
#
# jni.h / jni_md.h are architecture-neutral (LP64 on all 64-bit targets; the
# endianness is handled by the compiler, not by the header), so headers from
# ANY JDK 8+ of the host OS family work. jni_md.h lives in a platform subdir:
#   Linux -> include/linux/jni_md.h
#   Win32 -> include/win32/jni_md.h
#   macOS -> include/darwin/jni_md.h
# JDK 9+ defines JNIEXPORT with default visibility / dllexport, which is
# REQUIRED because the vendored CMakeLists sets C_VISIBILITY_PRESET hidden.
#
# Point it at headers with -DKASUGA_JNI_INCLUDE_DIR=<jdk>/include, or set
# JAVA_HOME. build.sh puts this directory first in CMAKE_MODULE_PATH.

include(FindPackageHandleStandardArgs)

set(_jni_hints "")
if(DEFINED KASUGA_JNI_INCLUDE_DIR AND NOT "${KASUGA_JNI_INCLUDE_DIR}" STREQUAL "")
    list(APPEND _jni_hints "${KASUGA_JNI_INCLUDE_DIR}")
endif()
if(DEFINED ENV{KASUGA_JNI_INCLUDE_DIR} AND NOT "$ENV{KASUGA_JNI_INCLUDE_DIR}" STREQUAL "")
    list(APPEND _jni_hints "$ENV{KASUGA_JNI_INCLUDE_DIR}")
endif()
if(DEFINED JAVA_HOME AND NOT "${JAVA_HOME}" STREQUAL "")
    list(APPEND _jni_hints "${JAVA_HOME}/include")
endif()
if(DEFINED ENV{JAVA_HOME} AND NOT "$ENV{JAVA_HOME}" STREQUAL "")
    list(APPEND _jni_hints "$ENV{JAVA_HOME}/include")
endif()
list(APPEND _jni_hints
    "/opt/ia64/jdk/include"
    "/usr/lib/jvm/default-java/include"
    "/usr/lib/jvm/java-21-openjdk-amd64/include"
    "/usr/lib/jvm/java-17-openjdk-amd64/include"
    "C:/Program Files/Eclipse Adoptium/jdk-21.0.11.10-hotspot/include")

# KASUGA_JNI_MD_SUBDIR can override (linux/win32/darwin). Otherwise probe all.
set(_jni_md_subdirs "")
if(DEFINED KASUGA_JNI_MD_SUBDIR AND NOT "${KASUGA_JNI_MD_SUBDIR}" STREQUAL "")
    list(APPEND _jni_md_subdirs "${KASUGA_JNI_MD_SUBDIR}")
endif()
list(APPEND _jni_md_subdirs linux win32 darwin "")

# Use EXISTS checks instead of find_path(): CMAKE_FIND_ROOT_PATH_MODE_INCLUDE is
# ONLY for cross builds, which would re-root every probe into the target sysroot
# where no JDK lives.
set(JAVA_INCLUDE_PATH "")
set(JAVA_INCLUDE_PATH2 "")
foreach(_hint IN LISTS _jni_hints)
    if(EXISTS "${_hint}/jni.h")
        set(JAVA_INCLUDE_PATH "${_hint}")
        foreach(_md IN LISTS _jni_md_subdirs)
            if("${_md}" STREQUAL "")
                set(_cand "${_hint}/jni_md.h")
            else()
                set(_cand "${_hint}/${_md}/jni_md.h")
            endif()
            if(EXISTS "${_cand}")
                get_filename_component(JAVA_INCLUDE_PATH2 "${_cand}" DIRECTORY)
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

# FAIL_MESSAGE must be ONE CMake argument (adjacent quoted strings are separate
# arguments in CMake and would be parsed as unknown keywords).
find_package_handle_standard_args(JNI
    REQUIRED_VARS JAVA_INCLUDE_PATH JAVA_INCLUDE_PATH2
    FAIL_MESSAGE "FindJNI (cross): jni.h / jni_md.h not found. Pass -DKASUGA_JNI_INCLUDE_DIR=<jdk>/include (with <jdk>/include/<linux|win32|darwin>/jni_md.h) or export JAVA_HOME.")

message(STATUS "FindJNI (cross): includes = ${JNI_INCLUDE_DIRS}")
message(STATUS "FindJNI (cross): JNI_LIBRARIES intentionally empty (no libjvm link)")
