# KasugaLibNext Experimental Builds — Native Target Matrix

七个目标全部产出可用二进制；六个目标做了运行期验证（含两个大端架构），
一个（Windows on ARM）因本机无 ARM64 Windows 只做到 PE 静态验证。

产物统一在 `out/native/<classifier>/`，并已打包为
`out/kasuga-native-universal.jar`（只含 `native/`，17 个条目）。
`native-port/` 是多目标框架；`../ia64-port/` 保留为首个 IA-64 目标的
已验证基线与原交接文档。

## 目标矩阵

| 架构 | OS | 定位 | classifier | 产物 | 编译方式 | 运行期验证 |
|---|---|---|---|---|---|---|
| IA-64 | Linux | 实验性 | `linux-ia64` | `libkasuga_box3d.so` 2,641,824 | 构建机 `/opt/cross` GCC 14.4 + T2 sysroot | ✅ IA-64 QEMU 客户机，JDK 21 Zero VM，`y=0.999930` |
| s390x | Linux | 实验性（**大端**） | `linux-s390x` | `.so` 1,052,592 | Debian 13 `s390x-linux-gnu` GCC 14.2 | ✅ `qemu-s390x-static`，`y=0.999930` |
| PPC64 | Linux | 实验性（**大端**） | `linux-ppc64` | `.so` 1,199,800 | `powerpc64-linux-gnu` GCC 14.2 | ✅ `qemu-ppc64-static`，`y=0.999930` |
| PPC64le | Linux | 实验性 | `linux-ppc64le` | `.so` 1,067,592 | `powerpc64le-linux-gnu` GCC 14.2 | ✅ `qemu-ppc64le-static`，`y=0.999930` |
| ARM64 | Linux | 原生 | `linux-aarch64` | `.so` 873,536 | `aarch64-linux-gnu` GCC 14.2 | ✅ `qemu-aarch64-static`，`y=0.999930` |
| x86-64 | Legacy Windows | 旧系统兼容 | `windows-x86_64` | `.dll` 1,292,800 | 本机 `llvm-mingw-xp` clang 22 (msvcrt) | ✅ 本机 Windows 11 + JDK 21 物理仿真 PASS；PE 静态证明 XP 兼容 |
| ARM64 | Windows on ARM | 原生 ARM64 | `windows-aarch64` | `.dll` 1,036,288 | 本机 `llvm-mingw 20261104` clang 23.1.5 交叉 | ⚠️ 仅 PE 机器类型 + 62 个导出符号 + 导入表核验；无 ARM64 Windows 真机 |

**classifier 依据**：`NativeBox3D.platformClassifier()` 与 `build.gradle` 的
`box3dArch` 对未知 `os.arch` 原样透传，仅把 `amd64|x86_64 → x86_64`、
`aarch64|arm64 → aarch64`。上游 `nsafran1217/jdk` 的 `platform.m4` 已确认
IA-64 的 `os.arch=ia64`。universal jar 的资源路径已用真实 JVM 验证：
`/native/windows-x86_64/kasuga_box3d.dll` 能解析、`System.load` 与 JNI 调用成功。

## 构建方式

统一入口 `build.py`（Windows 与 Linux 构建机同一份）：

```bash
python build.py --list
python build.py --target windows-x86_64-legacy
python build.py --target windows-aarch64
```

在 Debian 13 构建机（QEMU x86_64，`hostctl.py` 控制）上：

```bash
export NATIVE_SRC=/opt/src/matrix/native
export KASUGA_JNI_INCLUDE_DIR=/usr/lib/jvm/java-21-openjdk-amd64/include
for t in linux-aarch64 linux-ppc64le linux-ppc64 linux-s390x; do
    python3 native-port/build.py --target "$t"
done
```

IA-64 单独用已验证的 `../ia64-port/build_ia64.sh`（`--prefix /opt/cross/bin/ia64-linux-gnu-`），
或复用矩阵里的 `linux-ia64.toolchain.cmake`。

### 环境准备（已实测）

- 构建机：`apt-get install -y cmake gcc-{s390x,powerpc64,powerpc64le,aarch64}-linux-gnu
  g++-{...} qemu-user-static`（Debian 13 均提供 GCC 14.2 + `/usr/<triple>` sysroot）。
- QEMU 用户态验证：`qemu-<arch>-static -L /usr/<triple> <harness> <so>`。
  `jni_harness.c` 用真实 `jni.h` 构造 JNIEnv 函数表并 `dlopen` 目标 `.so`，
  不需要各架构的 JDK。**注意 C 里 JNIEnv 是二级指针**（`(*env)->Func`），
  必须返回「指向函数表指针的指针」。
- Windows ARM64：`llvm-mingw 20261104 msvcrt x86_64` 官方包解到
  `D:/llvm-mingw-20261104-msvcrt-x86_64`（含 `aarch64-w64-mingw32`）。
  XP 那套 `llvm-mingw-xp` 只有 i686/x86_64 target，做不了 ARM64。

## Legacy Windows 的 XP 兼容处理

`box3d/src/timer.c` 的 Windows 分支调用 `CreateSemaphoreExW`（Vista+）。
`llvm-mingw-xp` 的 `_WIN32_WINNT=0x0501` 下该函数未声明；直接提升
`_WIN32_WINNT` 虽能编译，却会生成在 XP 上加载失败的 DLL。

方案：`compat/legacy_windows.h` 通过 `-include` 强制注入，把
`CreateSemaphoreExW` 映射到 XP 就有的 `CreateSemaphoreW`（Box3D 传的
flags=0 / access=SEMAPHORE_ALL_ACCESS 无特殊语义），**上游源码零改动**。

核验结果：

- 导入 DLL 仅 `KERNEL32.dll` + `msvcrt.dll`
- 零 Vista+ API（ARM64 目标不需要 XP 约束，保留 `CreateSemaphoreExW` 属正常）
- `MajorSubsystemVersion 5 / Minor 1`（XP）
- 62 个 `Java_*_NativeBox3D_*` 导出符号
- `SetThreadDescription` 是动态 `GetProcAddress`，XP 上静默回退，不影响加载

## 大端正确性

s390x 与 PPC64 是 **大端**。ELF `EI_DATA=2` 已逐个核对，
Box3D 的 `timer.c` 有显式 `__ORDER_BIG_ENDIAN__` 分支，JNI 桥只做数值打包
（不做字节序 punning）。四个 Linux 目标在 QEMU 里的重力下落结果
`initial y=5.0 → final y=0.999930, vy=0, qw=1.0` 与 IA-64 / Windows **完全一致**，
说明标量数学、端序、原子操作、线程、句柄打包均正确。

## 关于 MC 安装目录

`D:\MC\.minecraft\versions\1.21.1-NeoForge_21.1.252\mods\` 里的
`kasuga_lib-0.22.1-neoforge.jar` 是**旧版 KasugaLib**（995 条目，
不含 `NativeBox3D`，也没有任何 `native/` 资源），与本仓库的新 JNI 桥不兼容，
把库塞进它不会被加载。因此没有改动用户的 MC 目录。

等构建出 KasugaLibNext 的 modelling jar 后，一条命令即可合入全部七个平台：

```bash
jar uf /path/to/kasuga-modelling-*.jar -C native-port/out native
# 或 Gradle 覆盖层：
./gradlew :modules:modelling:processResources \
    -PkasugaBox3DNativeResources=native-port/out
```

`.github/workflows/build.yml` 的 `package-universal` 已是
`jar uf "$jar_file" -C build/box3d-universal .`，只需在 `build` matrix
增加自建 runner job 上传 `out/native/<classifier>/` 即可，无需改打包步骤。

## 已知限制

- Windows on ARM 的 DLL 未在真实 ARM64 Windows 上运行验证（本机是 x86-64）。
  PE 机器类型、导入表、62 个导出符号均已核对；真机验证待补。
- Legacy Windows 的 XP 兼容性由 PE 静态属性证明，未在真实 XP 上启动；
  在本机 Windows 11 上运行期测试已通过。
- 各 Linux 目标的运行期验证用 `qemu-user-static` + C harness，未跑完整 JVM；
  IA-64 是唯一有完整 JVM（JDK 21 Zero）运行期验证的目标。
- `libkasuga_box3d.so` 的动态依赖仅 `libm.so.6` / `libc.so.6`；
  目标系统 glibc 需与构建机 Debian 13 (2.41) 兼容，IA-64 用的是 T2 glibc。


## CI 接入

`.github/workflows/native-experimental.yml` 负责实验性目标的交叉编译；
`build.yml` 通过 `workflow_call` 复用它，使所有产物落在**同一次 run**，
`package-universal` 现有的 `pattern: box3d-native-*` + `merge-multiple: true`
会自动把新平台合并进 universal modelling jar，无需改打包步骤。

| Job | Runner | 目标 | 验证 |
|---|---|---|---|
| `cross-linux` (matrix×4) | `ubuntu-24.04` | s390x / ppc64 / ppc64le / aarch64 | ELF 端序 + 62 个 JNI 导出符号 + `qemu-*-static` 物理冒烟 |
| `cross-windows-arm64` | `ubuntu-24.04` | Windows on ARM | PE `IMAGE_FILE_MACHINE_ARM64` + 62 个导出符号 |
| `self-hosted-ia64` | `[self-hosted, linux, ia64-cross]` | IA-64 Linux | 需 `/opt/cross` + `/opt/ia64/rootfs` T2 sysroot |
| `self-hosted-xp` | `[self-hosted, windows, xp-toolchain]` | Legacy Windows XP x64 | 需 `D:/llvm-mingw-xp-22.1.7-msvcrt-x86_64` |

- **自动运行**：`native-experimental.yml` 在 native 源码 / `native-port` /
  `ia64-port` / 该 workflow 自身变更时触发；`build.yml` 每次运行都会复用它。
  实验性 job 失败**不会**让主构建挂掉（`continue-on-error: true`），
  `package-universal` 用 `always() && needs.build.result == 'success'` 兜底。
- **启用自建 runner job**：`workflow_dispatch` 勾 `include_self_hosted`，
  或设置仓库变量 `ENABLE_NATIVE_SELF_HOSTED=true`。两者都设了
  `continue-on-error: true`，没有对应 runner 时也不会阻塞。
- **Ubuntu 24.04 包名已核实**（`gcc-powerpc64-linux-gnu` 在 universe、
  `gcc-powerpc64le-linux-gnu` 等），runner 固定为 `ubuntu-24.04` 以避免
  `latest` 漂移；交叉 sysroot 在 `/usr/<triple>`。
- **Linux 宿主交叉编译 Windows ARM64** 用 llvm-mingw 的
  `msvcrt-ubuntu-22.04-x86_64` 包（83MB，`actions/cache` 缓存）；
  `MINGW_ROOT` 环境变量覆盖 `targets.json` 里的 Windows 路径，
  toolchain 依据 `MINGW_EXE_SUFFIX` 决定是否给工具名加 `.exe`。
- 每个 job 用独立的 `--out-dir ${{ runner.temp }}/box3d-out`，上传
  `.../native/` 目录，保证 artifact 内是 `<classifier>/<lib>`，
  与既有 `build` job 的上传结构一致。

CI 里的每条 shell 命令都已在本地 Debian 13 构建机上彩排通过（4 个 Linux
架构全部 PASS，`windows-aarch64` 交叉编译 PASS）。彩排中修掉两个会让 CI
必然失败的问题：harness 必须用目标架构的 `${triple}-gcc` 编译（用宿主 gcc
会被 QEMU 拒绝），以及 `readelf` 输出里的 `2's complement` 不能过 `xargs`。


## 离线工具链包（U 盘 / 备用机）

IA-64 构建需要 x86_64 Linux 宿主上的交叉 GCC + T2 sysroot，这两者都不在
GitHub hosted runner 上，也不适合每次现装。`native-port/bundle/make-ia64-bundle.sh`
把它做成一个**可重定位**的单文件包：

```
kasuga-ia64-toolchain-slim-20261108.tar.xz   698 MB  (解压约 3.2 GB)
  kasuga-ia64-toolchain/
    cross/     GCC 14.4.0 + binutils 2.46 (x86_64 → ia64-linux-gnu)
    sysroot/   T2/Linux IA-64：头文件 + libc/libm + crt + libgcc
    jni/       jni.h + linux/jni_md.h
    env.sh     导出 IA64_TOOLCHAIN_PREFIX / IA64_SYSROOT / KASUGA_JNI_INCLUDE_DIR
    MANIFEST.sha256
```

体积：原始 `/opt/ia64/rootfs` 是 **7.6 GB**，其中 5.9 GB 是桌面组件
（Qt6 243 MB、libLLVM 282 MB、X11 197 MB、`usr/share` 1.2 GB、firmware 625 MB），
C 交叉编译完全用不到。剔除后 sysroot 降到 1.7 GB，包体 698 MB。

**可重定位是怎么解决的**：GCC 编译时写死了 `--prefix=/opt/cross` 与
`--with-sysroot=/opt/ia64/rootfs`。包里的 `env.sh` 会生成两个 wrapper
（`bin/ia64-linux-gnu-gcc{,++}`）并在 PATH 最前面注入 `--sysroot=<包内路径>`，
显式参数覆盖编译期默认值。`build.py` 也已改为环境变量优先于 targets.json。

**已验证**：把 `/opt/cross` 临时移走后，仅用解压到 `/opt/verify-bundle` 的包
完成了一次完整构建（产物 2,645,056 B，62 个 JNI 导出符号，ELF64/IA-64/小端）。
`build.py --target linux-ia64` 配合 `source env.sh` 也单独验证通过。

在目标机使用：

```bash
tar -xJf kasuga-ia64-toolchain-slim-20261108.tar.xz -C /opt
source /opt/kasuga-ia64-toolchain/env.sh
NATIVE_SRC=$PWD/modules/modelling/src/main/native \
  python3 native-port/build.py --target linux-ia64
```

注意：交叉工具链是 **x86_64 Linux ELF 程序**，Windows 上必须走 WSL2 或 Linux
虚拟机；构建阶段不需要 QEMU（QEMU 只在运行 IA-64 测试时需要）。

CI 的 `self-hosted-ia64` job 两种布局都支持：`IA64_BUNDLE` 指向解压目录，
或沿用 `/opt/cross` + `/opt/ia64/rootfs`。

### 备用机（Surface）上的两个自建 runner

`native-port/bundle/setup-runner.ps1` 装 Windows runner（标签 `xp-toolchain`），
`native-port/bundle/setup-wsl-runner.sh` 在 WSL 里装 Linux runner（标签 `ia64-cross`）
并从离线包安装 IA-64 工具链到 `/opt/kasuga-ia64-toolchain`——正好是
`self-hosted-ia64` job 自动探测的位置。

**runner 不要装在 SMB 共享上**。第一次部署时 runner 直接解压在
`\\6K-062的SURFACE\runner`，带来两个实际问题：`.credentials` 是明文 RSA
私钥（共享可读者即可冒充该 runner 接管仓库 CI），以及 `_work` 在网络盘上，
每个 job 的 checkout/CMake/IO 全走 SMB。
`native-port/bundle/migrate-runner-to-local.ps1` 负责迁移：停服务 → 复制到
`C://actions-runner` → 固定 workFolder → 安装 XP 工具链并写 `MINGW_ROOT_XP` →
注册为本地服务。agentId 随 `.runner` 一起搬，**无需重新注册或新 token**。
`native-port/bundle/cleanup-share.ps1` 负责之后清理共享盘上的副本（默认预演，
删除进回收站）。

WSL 发行版必须 **glibc >= 2.38**（工具链二进制要求）：
Debian 13 / Ubuntu 24.04 可以，Ubuntu 22.04 / Debian 12 会报
`GLIBC_2.38 not found`。安装脚本会在开头检查这一项。
