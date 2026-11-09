
Installation information
=======

This template repository can be directly cloned to get you started with a new
mod. Simply create a new repository cloned from this one, by following the
instructions provided by [GitHub](https://docs.github.com/en/repositories/creating-and-managing-repositories/creating-a-repository-from-a-template).

Once you have your clone, simply open the repository in the IDE of your choice. The usual recommendation for an IDE is either IntelliJ IDEA or Eclipse.

If at any point you are missing libraries in your IDE, or you've run into problems you can
run `gradlew --refresh-dependencies` to refresh the local cache. `gradlew clean` to reset everything
{this does not affect your code} and then start the process again.

Mapping Names:
============
By default, the MDK is configured to use the official mapping names from Mojang for methods and fields
in the Minecraft codebase. These names are covered by a specific license. All modders should be aware of this
license. For the latest license text, refer to the mapping file itself, or the reference copy here:
https://github.com/NeoForged/NeoForm/blob/main/Mojang.md

Additional Resources:
==========
Community Documentation: https://docs.neoforged.net/  
NeoForged Discord: https://discord.neoforged.net/

Custom rendering:
==========
The custom rendering surface includes owner-scoped world pipelines, managed effects,
post-processing graphs, reload-safe resource/generated shaders, the imperative Java Shader DSL,
background shader preparation and schema-driven runtime parameters.

See [doc/reference/effect-rendering.md](doc/reference/effect-rendering.md) for the API behavior, examples and the GLSL-to-Java
Shader DSL guide.

The optional `modules:shader-graal` module adds a GraalJS frontend that constructs the same typed
shader programs. See [GraalJS scripting](doc/reference/shader-dsl.en.md#graaljs-scripting) for dependencies and examples.

Camera movement, rotation, zoom and keyframe playback are documented in
[doc/reference/camera-animation.md](doc/reference/camera-animation.md). Player / Free / Fixed creation and entity following are documented in
[doc/reference/cameras.md](doc/reference/cameras.md).

World-space UI panels and transparent free-cursor input are documented in
[doc/reference/world-ui-input.md](doc/reference/world-ui-input.md).

Optional world-wide volumetric skies, placeable cumulonimbus volumes and standalone previews are documented in
[doc/reference/volumetric-clouds.md](doc/reference/volumetric-clouds.md).

The [Nebula demo](doc/guides/nebula-demo.md) combines graph-managed MRT, OBJ/PBR assets,
volumetric warp effects and shared camera animation, with deterministic 4K60 recording.

Run the focused release gate with:

```bash
./gradlew renderingReleaseCheck
```

The manual and artifact checks for a release candidate are recorded in
[API validation guide](doc/guides/verification.md).


Documentation:
==========

- [API reference index](doc/reference/README.md): interfaces, builders, configuration schemas, examples and commands.
- [Architecture and principles](doc/explanation/README.md): data flow, ownership, algorithms and implementation boundaries.
- [Proxy kernel and content integration](doc/explanation/proxy/README.en.md): sessions, typed ports, lifecycle, and a practical integration guide.
- [Skeleton physics, IK and diamond constraints](doc/reference/skeleton-dynamics.md).
- [Model loading and rendering](doc/reference/modelling/README.en.md) / [中文](doc/reference/modelling/README.md).
- [Formula API](doc/reference/formula/README.en.md) / [中文](doc/reference/formula/README.md).


Experimental Native Builds:
==========

The `modules:modelling` native component (vendored Box3D + a thin JNI bridge)
is shipped for the platforms below. Experimental targets are cross-compiled by
this repository's port framework; official builds are the upstream-provided
binaries. Artifacts live under `native-port/out/native/<classifier>/`.

Full build and verification notes (中文): [native-port/MATRIX.md](native-port/MATRIX.md)
and [ia64-port/PORTING.md](ia64-port/PORTING.md).

| Architecture | OS | Classifier | Origin | Build toolchain | Runtime verification |
|---|---|---|---|---|---|
| IA-64 | Linux | `linux-ia64` | Experimental | `/opt/cross` GCC 14.4 + T2 sysroot | PASS: IA-64 QEMU guest, JDK 21 Zero VM, full JNI smoke |
| s390x (**BE**) | Linux | `linux-s390x` | Experimental | `s390x-linux-gnu` GCC 14.2 | PASS: `qemu-s390x-static` + C harness |
| PPC64 (**BE**) | Linux | `linux-ppc64` | Experimental | `powerpc64-linux-gnu` GCC 14.2 | PASS: `qemu-ppc64-static` + C harness |
| PPC64LE | Linux | `linux-ppc64le` | Experimental | `powerpc64le-linux-gnu` GCC 14.2 | PASS: `qemu-ppc64le-static` + C harness |
| ARM64 | Linux | `linux-aarch64` | Experimental | `aarch64-linux-gnu` GCC 14.2 | PASS: `qemu-aarch64-static` + C harness |
| x86-64 | Legacy Windows (XP x64 / Server 2003) | `legacy_windows-x86_64` | Experimental (our XP build, renamed) | `llvm-mingw-xp` clang 22 / msvcrt | PASS: Windows 11 + JDK 21 JNI smoke; PE statically proven XP-compatible |
| ARM64 | Windows on ARM | `windows-aarch64` | Experimental (cross-compiled) | `llvm-mingw 20261104` / LLVM 23.1.5 | PARTIAL: PE machine type + 62 exports + import table only; no ARM64 Windows host |
| x86-64 | Linux | `linux-x86_64` | Official build | upstream | PASS: native x86-64 Linux + C harness |
| x86-64 | Windows | `windows-x86_64` | Official build | upstream | PASS: Windows 11 + JDK 21 JNI smoke |
| ARM64 | macOS | `macos-aarch64` | Official build | upstream | PARTIAL: Mach-O ARM64 dylib + 62 exports only; no macOS host |

Verification summary
----------

Runtime smoke tests use the same deterministic gravity-drop simulation
(`Box3DSmoke.java` for real JVMs, `native-port/verify/jni_harness.c` for
QEMU user mode). Every platform that was executed reports the identical
result: `initial y = 5.0 -> final y = 0.999930`, `vy = 0`, `qw = 1.0`, and all
13 state floats finite. This covers the scalar SIMD fallback, `__atomic_*`,
worker threads, aligned allocations, JNI array marshalling and `jlong` handle
packing — including the two **big-endian** targets (s390x, PPC64).

Static checks applied to all ten artifacts: correct ELF64 / PE / Mach-O machine
type and endianness, 62 exported `Java_*_NativeBox3D_*` symbols, ELF `NEEDED`
limited to `libc` / `libm`, and a non-executable `GNU_STACK`. The Legacy
Windows DLL additionally imports only `KERNEL32.dll` + `msvcrt.dll`, contains
no Vista+ APIs, and targets subsystem 5.1 (XP); the Vista+ `CreateSemaphoreExW`
call in Box3D is redirected to XP's `CreateSemaphoreW` by
`native-port/compat/legacy_windows.h`, without editing upstream sources.
This is why the legacy build exists: the official `windows-x86_64` DLL imports
`VCRUNTIME140.dll` plus UCRT (`api-ms-win-crt-*`) and cannot load on XP,
whereas the legacy DLL needs only `KERNEL32.dll` + `msvcrt.dll`.
The universal jar's resource path was verified on a real JVM
(`/native/windows-x86_64/kasuga_box3d.dll` resolves, loads and answers JNI calls).

Notes / Known gaps
----------

- `platformClassifier()` now returns `legacy_windows-x86_64` on Windows NT 5.x
  (XP / XP x64 / Server 2003) with an x86-64 JVM, so the XP build is selected
  automatically. Detection uses the release name first and the numeric
  `os.version` as a fallback; Vista+ (NT 6.0+) never takes this branch. The
  explicit `-Dkasuga.box3d.library=<path>` override still wins over all of it.
- `native-port/out/kasuga-native-universal.jar` has been rebuilt with all ten
  platform directories, including `legacy_windows-x86_64`. End-to-end JVM tests
  with simulated XP and Windows 11 properties confirm each branch resolves its
  resource, loads the DLL and answers a JNI call.
- `native-port/targets.json` now uses `legacy_windows-x86_64` as the legacy
  target's classifier. `MATRIX.md` still describes the original 7-target
  experimental build; the three official artifacts are documented above.
- Windows on ARM and macOS ARM64 have no runtime verification: no such host is
  available here. IA-64 is the only experimental target with a full JVM test.
