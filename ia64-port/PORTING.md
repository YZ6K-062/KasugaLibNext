# KasugaLibNext native → Linux/IA-64 移植说明

目标：为 `modules/modelling` 的 native 部分（vendored Box3D + JNI 桥）交叉编译出
`native/linux-ia64/libkasuga_box3d.so`，可合入 universal modelling jar。

## 一、结论

**可行，且不需要修改任何上游源码**（C / Gradle / Java 三处都不用改）。
真正的移植工作全部集中在构建链：CMake 工具链、JNI 查找、打包、验证。

| 项 | 结论 | 依据 |
|---|---|---|
| SIMD | IA-64 自动走纯标量 | `core.h` 未知 CPU → `B3_CPU_UNKNOWN` → `B3_SIMD_NONE`；`simd.h` 712–923 行为标量实现 |
| 内联汇编 | 不会编译到 x86/ARM 指令 | `solver.c` `b3Pause()` 有 `#else` 空实现 |
| 原子操作 | 通用 `__atomic_*` | `platform.h` 的 `__GNUC__` 分支 |
| 位运算 | 通用 `__builtin_ctz/clz/ctzll/popcountll` | `ctz.h` 非 MSVC 分支 |
| 128 位乘 | `__uint128_t`（GCC 支持） | `rapidhash.h` `__SIZEOF_INT128__` 分支 |
| 线程 | `pthread_create`（POSIX） | `timer.c` 的 `__linux__` 分支 |
| 端序 | 小端，与 x86_64 一致 | `platform.m4`: `VAR_CPU_ENDIAN=little`；`timer.c` 大端分支不触发 |
| ABI | LP64，`jlong`=`long` | `jni_md.h` 的 `_LP64` 分支 |
| JNI 符号导出 | 62 个 `JNIEXPORT` 全部可见 | `jni_md.h` 的 `JNIEXPORT` 含 `visibility("default")`，抵消 `C_VISIBILITY_PRESET hidden` |
| classifier | `linux-ia64` | `NativeBox3D.platformClassifier()` 与 `build.gradle` 对未知 arch 原样透传；`os.arch=ia64` 已由上游 `platform.m4` 坐实 |

`-DBOX3D_DISABLE_SIMD=ON` 仍显式传入，作为不依赖 CPU 探测的硬保险。

> **状态更新（2026-11-08）：真实交叉编译与运行期验收均已在本地 QEMU 构建机完成，见第二节。**

## 二、构建机（已实测可用）

工作区是 **Windows / MINGW64**（无 cmake、无 ia64 交叉链），但之前为 JDK 项目
搭好的 **QEMU x86_64 Debian 13 构建机**可直接复用，由
`ia64jdk/scripts/hostctl.py serve` 启动（磁盘 `ia64jdk/vm/buildhost.raw`，
串口 5700、控制 socket 5701，`hostctl.py exec "<cmd>"` 下发命令）。

实测环境：

| 项 | 值 |
|---|---|
| OS | Debian GNU/Linux 13 (trixie), x86_64 |
| 交叉工具链 | `/opt/cross/bin/ia64-linux-gnu-{gcc,g++,ar,ranlib,strip,readelf,nm}` **GCC 14.4.0**（不在 PATH，必须用 `--prefix /opt/cross/bin/ia64-linux-gnu-`） |
| sysroot | `/opt/ia64/rootfs`（T2 live.squash，glibc 2.4x） |
| JNI 头 | `/opt/src/jdk21/build/ia64c/images/jdk/include`（含 `linux/jni_md.h`） |
| cmake | 构建机原缺，已 `apt-get install -y cmake` 装上 **3.31.6** |
| 文件中转 | `ia64jdk/scripts/transfer_server.py 8100`，客机走 `10.0.2.2:8100`（GET 下载 / POST 回传） |

源码只需 vendored native 树，不必传整个 Gradle 仓库：把
`modules/modelling/src/main/native` 与 `ia64-port/` 打成 tar，构建机解到
`/opt/src/kasuga/{native,ia64-port}`，再用 `NATIVE_SRC=/opt/src/kasuga/native` 覆盖。

**实际执行命令（已成功）：**

```bash
NATIVE_SRC=/opt/src/kasuga/native ./ia64-port/build_ia64.sh \
    --sysroot /opt/ia64/rootfs \
    --prefix /opt/cross/bin/ia64-linux-gnu- \
    --jni-include /opt/src/jdk21/build/ia64c/images/jdk/include \
    --out-dir /opt/src/kasuga/out
```

产物：`out/native/linux-ia64/libkasuga_box3d.so`（2,641,824 字节，
SHA256 `2545e43dabcda186786a2c941f564dbfe09568b49c2e84f561105301bb06d263`）。

**ELF 验证（构建机上真实跑过）：** ELF64 / 2's complement little endian /
`Machine: Intel IA-64` / DYN；NEEDED 仅 `libm.so.6.1` 与 `libc.so.6.1`
（无误链 libjvm）；62 个 `Java_*_NativeBox3D_*` 导出符号；`PT_GNU_STACK RW`；
构建 0 error / 4 个 `-Wmaybe-uninitialized` 警告（上游代码，无害）。

## 二·b、运行期验收（IA-64 客户机，已实测通过）

用 `ia64jdk/scripts/vmctl.py serve --net` 起 IA-64 T2 live 客户机（`vm/build.raw`
数据盘），注意 live 系统需手动 `mkdir -p /build && mount /dev/sda /build`，
且 `eth0` 只拿到 link-local，要手动 `ip addr add 10.0.2.15/24 dev eth0; ip link set eth0 up`
才能访问 `10.0.2.2`。JDK 在 `/build/jdk`（OpenJDK 21.0.13 IA-64 **Zero VM**）。

Java 桩在构建机用 `javac 21` 编译（字节码与架构无关），与 `.so` 一起打包下载。
以 `-XX:+UseSerialGC -Xshare:off -Xint` 运行 `Box3DSmoke`：

```
os.arch = ia64, data model = 64, OpenJDK 64-Bit Zero VM
initial y = 5.0  ->  final y = 0.99993   (expected ~1.0)
final vy = 0.0, quaternion w = 1.0
120 x step() with 4 substeps ... ok
=== PASS: Box3D native physics works on Linux/IA-64 ===
```

一次性验证了标量数学、`__atomic_*`、pthread 工作线程、内存对齐、JNI 数组传递、
`jlong` 句柄打包、以及 `os.arch=ia64` → `linux-ia64` classifier 假设。

> 首次运行曾出现 HotSpot 的 "might have disabled stack guard" 警告：
> IA-64 上纯 C 共享库默认不带 `PT_GNU_STACK` note。已在工具链链接旗标加
> `-Wl,-z,noexecstack`，并在 `build_ia64.sh` 的 ELF 验证里加入 `GNU_STACK` 检查，
> 重编后警告消失、物理结果一致。

`package_ia64.sh` 也已用临时 jar 实测：`jar uf` 后
`native/linux-ia64/libkasuga_box3d.so` 条目存在且可枚举。

## 三、已完成的静态验证（在本机实测通过）

| # | 验证 | 结果 |
|---|---|---|
| 1 | 隔离 `core.h` 平台/CPU/SIMD 检测逻辑，注入纯 IA-64 宏集 | `B3_PLATFORM_LINUX` + `B3_CPU_UNKNOWN` + `B3_SIMD_NONE` |
| 2 | `-DBOX3D_DISABLE_SIMD` 预处理 | `B3_SIMD_NONE` |
| 3 | 预处理头文件依赖树 | 不引入 `emmintrin.h` / `arm_neon.h` / `xmmintrin.h` / `immintrin.h` |
| 4 | 标量模式全量语法编译 box3d 的 50 个 `.c` | 49/50 通过；唯一失败为 `timer.c` 的 **Windows 分支** `CreateSemaphoreExW`（IA-64 Linux 走不到该行） |
| 5 | 强制 `timer.c` 走 `__linux__`/pthread 分支语法编译 | 通过 |
| 6 | JNI 桥 + box3d 公共头（最小 `jni.h` 桩）标量模式语法编译 | 通过 |
| 7 | 62 个 `JNIEXPORT` 与冒烟测试桩的 9 个符号名逐一核对 | 全部匹配 |
| 8 | 全部 shell 脚本 `bash -n`、行尾 LF、可执行位、`--help` / 错误参数路径 | 通过 |
| 9 | 标量模式下把 50 个 `.c` **实际编译成目标文件**（非仅语法检查） | 50/50 通过，`nm -u` 显示标量构建零个 `_mm_*` 外部引用 |

> 验证 4 里的 `aligned_alloc` 缺失是 llvm-mingw/MSVCRT 的主机限制，
> T2 sysroot 的 glibc 2.43 原生支持；已用声明桩消除该主机差异。

> **不要用反汇编里的 SSE 指令数量判断可移植性**：在 x86_64 主机上，
> clang `-O2` 的自动向量化会对纯标量 C 循环合法生成 `addps`/`shufps` 等指令，
> 无论源码走 SSE2 还是标量路径都会出现。IA-64 交叉编译器有自己的后端，
> 根本不会生成 x86 指令。有效的判据是上表的预处理头文件依赖（验证 3）、
> 条件编译分支（验证 1/2）与 `nm -u` 符号引用（验证 9）。

**后续补充**：真实 IA-64 代码生成、链接、运行期物理行为已于 2026-11-08
在第二节所述的构建机 + IA-64 客户机上全部实测通过，不再属于"未验证"。

## 四、复现步骤（构建机命令已在第二节给出，这里是通用形式）

前置：`cmake>=3.22`、`ia64-linux-gnu-gcc` **和** `ia64-linux-gnu-g++`、
T2 sysroot、任意 Linux JDK 8+ 的 `include/`（或 IA-64 JDK 自带的）。

```bash
# 1) 交叉编译 + ELF 验证 + 落地到 ia64-port/out/native/linux-ia64/
#    工具链不在 PATH 时用 --prefix 指向绝对路径前缀；只有精简源码树时用 NATIVE_SRC
NATIVE_SRC=/path/to/native ./ia64-port/build_ia64.sh \
    --sysroot /opt/ia64/rootfs \
    --prefix /opt/cross/bin/ia64-linux-gnu- \
    --jni-include /opt/src/jdk21/build/ia64c/images/jdk/include

# 2a) 合入已有的 universal modelling jar（原地更新，建议先备份）
./ia64-port/package_ia64.sh /path/to/kasuga-modelling-*.jar

# 2b) 或：作为 Gradle 的 native 资源覆盖层参与打包
./gradlew :modules:modelling:processResources \
    -PkasugaBox3DNativeResources=ia64-port/out
```

`build_ia64.sh` 会自动校验 ELF 为 `Intel IA-64` / ELF64 / 小端、
动态依赖不含 `libjvm.so`、`PT_GNU_STACK` 非 RWE、
以及 62 个 `Java_*_NativeBox3D_*` 符号确实导出。

## 五、在 IA-64 目标机上运行期验收

```bash
./ia64-port/smoke/run_smoke_ia64.sh \
    ia64-port/out/native/linux-ia64/libkasuga_box3d.so
```

该测试不依赖 slf4j 或任何 KasugaLib 类（自带同名 FQN 的 JNI 桩），
跑一个确定性重力下落仿真，一次性覆盖：标量 SIMD 数学、`__atomic_*`、
pthread 工作线程、`aligned_alloc`/`_Alignas(16)` 对齐、JNI 数组传递、
`jlong` 句柄打包。

脚本默认 VM 参数 `-XX:+UseSerialGC -Xshare:off -Xint`：

- IA-64 移植只有 Serial/Parallel/Epsilon GC（G1/ZGC/Shenandoah 缺 barrier）；
- CDS 不可用；
- `-Xint` 规避 qemu 的 SMC 缺陷（只影响 JIT 动态生成代码，不影响 AOT 的 C 库）。
  若已构建 `nsafran1217/jdk` 的 `zero`/`core` VM，改用
  `VM_ARGS="-zero -XX:+UseSerialGC -Xshare:off"` 更稳。

也可绕过 classifier 直接指定文件：
`java -Dkasuga.box3d.library=/abs/path/libkasuga_box3d.so ...`

## 六、文件清单

```
ia64-port/
├── PORTING.md                          本说明
├── build_ia64.sh                       交叉编译主入口（含 ELF 验证、staging）
├── package_ia64.sh                     合入 universal jar / Gradle overlay 说明
├── cmake/
│   ├── ia64-linux-gnu.toolchain.cmake  CMake 交叉工具链（sysroot、GCC ICE 规避、-pthread）
│   └── FindJNI.cmake                   接管 find_package(JNI)，只给头文件、不链 host libjvm
├── smoke/
│   ├── run_smoke_ia64.sh                IA-64 目标机运行期验收
│   └── src/
│       ├── Box3DSmoke.java              重力下落仿真 + 断言
│       └── lib/kasuga/.../NativeBox3D.java   同名 FQN 最小 JNI 桩
└── out/                                构建产物（gitignore 即可）
```

## 七、已知风险与处理

| 风险 | 处理 |
|---|---|
| `find_package(JNI REQUIRED)` 误找 x86 主机 JDK / 链入 host `libjvm.so` | 自定义 `FindJNI.cmake` 接管，`JNI_LIBRARIES` 置空。**注意 `FAIL_MESSAGE` 必须单个字符串参数**（CMake 不会拼接相邻引号串，否则报 "Unknown keywords"——首次构建实际踩到并已修） |
| GCC 在 IA-64 上 selective scheduling ICE | 工具链加 `-fno-selective-scheduling -fno-selective-scheduling2`（GCC 14.4.0 交叉链实测有效） |
| `box3d` 声明 `LANGUAGES C CXX` 但无 `.cpp` | 仍需 `ia64-linux-gnu-g++` 供 CMake 做编译器检查；脚本会明确报错 |
| `pthread_create` 未显式链接 | 工具链加 `-pthread`（glibc≥2.34 虽已并入 libc，显式更稳） |
| **可执行栈**：IA-64 上纯 C `.so` 默认无 `PT_GNU_STACK` note，HotSpot 加载时警告 "might have disabled stack guard" | 链接加 `-Wl,-z,noexecstack`，并在 `verify_so` 中检查 `GNU_STACK` 非 RWE（首次运行实测发现并已修） |
| 目标 JDK 的 `os.arch` 不是 `ia64` | `--classifier linux-<实际值>` 重建，或用 `-Dkasuga.box3d.library` 绕过（实测 `os.arch=ia64`） |
| qemu SMC 缺陷 | 冒烟测试用 `-Xint` / `zero` VM；AOT 的 C 库不受影响（实测 Zero VM 全程无异常） |
| 16 KiB 页 / glibc 2.43 | 必须使用 T2 sysroot，不能复用主机 glibc |
| 交叉工具链不在 PATH | `--prefix /opt/cross/bin/ia64-linux-gnu-`；脚本与 toolchain 都支持绝对路径前缀 |
| 构建机只有精简源码树 | `NATIVE_SRC=/path/to/native ./ia64-port/build_ia64.sh ...` |
| IA-64 live 客户机无 `/build`、网卡只拿 link-local | 手动 `mkdir -p /build && mount /dev/sda /build`；`ip addr add 10.0.2.15/24 dev eth0; ip link set eth0 up` |

## 八、可选：纳入官方 CI

`.github/workflows/build.yml` 的 `package-universal` 已用
`jar uf "$jar_file" -C build/box3d-universal .` 合并所有 classifier 的库。
只需要在 `build` matrix 增加一个自建 runner job，调用 `build_ia64.sh` 并上传
`out/native/linux-ia64/` 为 `box3d-native-Linux-ia64` artifact 即可，
`package-universal` 无需改动。
