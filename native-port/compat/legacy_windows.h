/* legacy_windows.h -- XP/2003 compatibility shim for the Box3D JNI native lib.
 *
 * Forced into every translation unit with -include. It does NOT modify the
 * vendored upstream sources.
 *
 * Problem: box3d/src/timer.c's Windows branch calls CreateSemaphoreExW(),
 * which was introduced in Windows Vista. With llvm-mingw-xp's
 * _WIN32_WINNT=0x0501 the function is not even declared, and on a real XP
 * system kernel32.dll does not export it. Simply raising _WIN32_WINNT would
 * make the header declare it but produce a DLL that fails to load on XP.
 *
 * Fix: map the call to CreateSemaphoreW(), which exists since Windows 2000.
 * The two extra arguments of CreateSemaphoreExW (flags, desired access) are
 * passed as 0 / SEMAPHORE_ALL_ACCESS by Box3D -- i.e. no special behaviour is
 * requested, so CreateSemaphoreW(NULL, init, max, NULL) is semantically
 * equivalent for this use.
 *
 * Also make sure we never accidentally pull in a Vista+ API through macros.
 */
#ifndef KASUGA_LEGACY_WINDOWS_H
#define KASUGA_LEGACY_WINDOWS_H

#if defined(_WIN32)

#ifndef WIN32_LEAN_AND_MEAN
#define WIN32_LEAN_AND_MEAN 1
#endif
#include <windows.h>

/* Only shim when the toolchain targets pre-Vista Windows. */
#if defined(_WIN32_WINNT) && (_WIN32_WINNT < 0x0600)

#ifndef CreateSemaphoreExW
static inline HANDLE kasuga_CreateSemaphoreExW(
    LPSECURITY_ATTRIBUTES lpSemaphoreAttributes,
    LONG lInitialCount,
    LONG lMaximumCount,
    LPCWSTR lpName,
    DWORD dwFlags,
    DWORD dwDesiredAccess)
{
    (void)dwFlags;
    (void)dwDesiredAccess;
    return CreateSemaphoreW(lpSemaphoreAttributes, lInitialCount,
                            lMaximumCount, lpName);
}
#define CreateSemaphoreExW kasuga_CreateSemaphoreExW
#endif

/* SEMAPHORE_ALL_ACCESS is not exposed by some XP-era headers. Box3D only uses
 * it as an argument that our shim ignores, so a harmless fallback suffices. */
#ifndef SEMAPHORE_ALL_ACCESS
#define SEMAPHORE_ALL_ACCESS (STANDARD_RIGHTS_REQUIRED | SYNCHRONIZE | 0x3)
#endif

#endif /* _WIN32_WINNT < 0x0600 */
#endif /* _WIN32 */
#endif /* KASUGA_LEGACY_WINDOWS_H */
