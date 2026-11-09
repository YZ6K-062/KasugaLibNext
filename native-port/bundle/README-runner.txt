KasugaLibNext - Surface 备用机 Runner 搭建说明
==============================================

目录结构
--------
  \\6K-062的SURFACE\runner\
    README-runner.txt          本文件（入口）
    scripts\                   一次性脚本
      probe.ps1                 环境探测（只读）
      setup-runner.ps1          Windows runner + XP 工具链
      setup-wsl-runner.sh       WSL runner + IA-64 工具链
      migrate-runner-to-local.ps1   把 runner 从共享盘搬到本地磁盘  ★先跑这个
      cleanup-share.ps1            清掉共享盘上的 runner 副本
    packages\                  安装物料
      llvm-mingw-xp.zip          XP 目标交叉工具链（125 MB）
      actions-runner-win-x64-2.338.2.zip   runner 安装包（已解压，可删）
    logs\                      诊断输出
      probe-result.json          上次探测结果
    bin\ externals\ _work\ _diag\ .runner .credentials ...   ← runner 本体，待迁移

重要：runner 现在装在 SMB 共享上，有两个实际问题
--------------------------------------------------
  1) .credentials 是 runner 的明文 RSA 私钥。任何能读这个共享的人都能冒充
     这个 runner 接管仓库 CI。
  2) _work（checkout + 构建目录）在网络盘上，每个 job 的 git/CMake/文件 IO
     全走 SMB，慢且容易失败。

所以第一步是把 runner 搬到本地 C:\actions-runner。agentId 在 .runner 里，
跟着搬就行，**不需要重新注册、不需要新的 token**。


一、迁移 runner 到本地（管理员终端，先做这个）
---------------------------------------------
在共享盘上直接跑（脚本会自动认出共享路径）：

  cd \\6K-062的SURFACE\runner\scripts
  powershell -ExecutionPolicy Bypass -File .\migrate-runner-to-local.ps1

如果脚本是从别处（比如桌面副本）运行的，共享路径要显式给：

  powershell -ExecutionPolicy Bypass -File .\migrate-runner-to-local.ps1 `
      -ShareRunner '\\6K-062的SURFACE\runner'

先看会做什么而不实际执行：
  powershell -ExecutionPolicy Bypass -File .\migrate-runner-to-local.ps1 -WhatIf

它会：停掉 runner 服务/进程 → 复制 runner 到 C:\actions-runner →
把 workFolder 固定到本地 _work → 从 packages\llvm-mingw-xp.zip 解出
C:\llvm-mingw-xp 并写机器变量 MINGW_ROOT_XP → 把 runner 注册成本地服务 → 校验。

迁完确认 GitHub -> Settings -> Actions -> Runners 里仍是同一个 runner 且变回 Idle，
再清理共享盘：
  powershell -ExecutionPolicy Bypass -File .\cleanup-share.ps1            （预演）
  powershell -ExecutionPolicy Bypass -File .\cleanup-share.ps1 -Execute   （真删）


二、WSL 里装 IA-64 runner
-------------------------
已装 WSL（Ubuntu + Debian），Hyper-V 与虚拟机平台都已启用。
这台机器可以同时承担两个自建 runner：
  Windows runner  标签 xp-toolchain  -> 编 Legacy Windows XP x64
  WSL Linux runner 标签 ia64-cross   -> 编 IA-64 Linux

【关键前提】WSL 发行版必须 glibc >= 2.38：
    可以：Debian 13 (2.41)、Ubuntu 24.04 (2.39)
    不行：Ubuntu 22.04 (2.35)、Debian 12 (2.36) → 报 GLIBC_2.38 not found
  查看：getconf GNU_LIBC_VERSION
  不够就换：wsl --install -d Debian

IA-64 工具链包（本机 D 盘已有，WSL 通过 /mnt/d 读取）：
  D:\kasuga-ia64-toolchain-slim-20261108.tar.xz      698MB（解压约 3.2GB）
  D:\kasuga-ia64-toolchain-slim-20261108.tar.sha256

在 WSL 终端里：
  1) 确认能读到：  ls /mnt/d/kasuga-ia64-toolchain-slim-*.tar.xz
  2) 跑脚本：
       bash /mnt/d/setup-wsl-runner.sh -t <粘贴token>
     或把共享盘里的脚本复制过去再跑：
       cp "/mnt/c/runner/scripts/setup-wsl-runner.sh" ~/ && bash ~/setup-wsl-runner.sh -t <token>

     脚本会：检查 glibc/systemd → apt 装 python3/cmake/ninja/git/xz →
     自动找包并校验 sha256 → 解压到 /opt/kasuga-ia64-toolchain →
     编译探针确认能产出 IA-64 ELF → 下载 actions-runner → 以 ia64-cross 注册 →
     有 systemd 时装成服务。

  3) 若提示 "systemd is not PID 1"（开机不自启），在 /etc/wsl.conf 加：
       [boot]
       systemd=true
     然后在 Windows 执行 wsl --shutdown，重开 WSL 再跑一次脚本。

CI 里的 IA-64 job 会自动探测 /opt/kasuga-ia64-toolchain，装到默认位置即可，
不用再配变量。


三、注册 token 从哪来
--------------------
仓库 Settings -> Actions -> Runners -> New self-hosted runner，
复制它给出的 configure 命令里的 --token（约 1 小时有效）。
本机已装 gh 2.89，也可以用 PAT 自行铸造。

两个 runner 都需要 token（各自注册一次），Windows 和 Linux 各一个。


四、关于中文路径与脚本编码（踩过的坑）
------------------------------------
  * 共享盘名 \\6K-062的SURFACE 含中文。Windows PowerShell 5.1 读取
    **无 BOM 的 UTF-8 脚本**时按系统 ANSI 代码页（中文系统 = GBK）解码，
    脚本里的中文路径字面量会变成乱码，导致 "share runner not found"。
    → 本目录所有 .ps1 都已存成 **UTF-8 with BOM**，且源码正文全为 ASCII，
      即使 BOM 丢了也不会乱码。
  * 若你把脚本复制到别处，请保持 BOM（记事本另存为选 "UTF-8 带 BOM"，
    VS Code 右下角点 "Save with Encoding" -> UTF-8 with BOM）。
  * 命令行参数不受此影响：-ShareRunner '\\6K-062的SURFACE\runner' 直接可用。
  * 脚本开头已设 [Console]::OutputEncoding = UTF8，控制台输出不再乱码。
  * Expand-Archive 不支持 -WhatIf（会抛 IndexOutOfRange），脚本改用
    .NET 的 ZipFile 逐条解压，既支持 -WhatIf 也能覆盖已存在文件。


五、常见问题
------------
* 提示"禁止运行脚本"
    → 用 powershell -ExecutionPolicy Bypass -File .\xxx.ps1，别直接双击。

* migrate 之后 GitHub 里 runner 变成 Offline
    → 看 C:\actions-runner\_diag\ 里的最新日志；多半是网络或权限问题。

* XP job 报找不到 llvm-mingw
    → 检查机器变量 MINGW_ROOT_XP 是否指向 C:\llvm-mingw-xp，
       以及 C:\llvm-mingw-xp\bin\x86_64-w64-mingw32-clang.exe 是否存在。

* WSL 里报 GLIBC_2.38 not found
    → 发行版太老，换 Debian 13 或 Ubuntu 24.04。

* 8GB 内存
    → XP 目标很轻，够用。同时开 WSL2 跑 IA-64 时建议限内存：
      C:\Users\<你>\.wslconfig 写  [wsl2]  memory=4GB

* Surface 休眠后 runner 离线
    → 正常。电源设置里把"接通电源时永不睡眠"打开，或接受它是备用机。


========================================================================
附：GitHub 官方 add_runner 方法（已实测并修好）
========================================================================

`add_runner\addrunner.txt` 是从 GitHub「New self-hosted runner」页面复制的
官方命令。我逐行跑过一遍，结论是：**方法本身没问题，但直接粘贴一定会失败**。

网页复制把换行吃掉了，产生了三处硬伤：
  1. 注释被粘到上一条命令末尾，例如
     `cd actions-runner# Download the latest runner package`
  2. 复制按钮的提示文字 `Copied!` 混进了 hash 校验行：
     `... }Copied!# Extract the installer`  -> PowerShell 会当成一条命令
  3. 最致命的：`--token <token># Run it!` —— `#` 紧贴 token 且没有空格，
     PowerShell 不把它当注释，token 会被污染，注册必然失败

另外官方示例的 `runs-on: self-hosted` 对本仓库太宽（会同时匹配 IA-64
runner），我们的实验性 job 需要 `xp-toolchain` 标签。

修好的版本：`scripts\add-runner-official.ps1`
  - 用官方原版包 v2.338.2，并校验 GitHub 给的 SHA256
    a1f17aa987fc8158bc7521d284912267a0d01b7c2c4684b33c86783b5e8221cc
    （实测 `packages\actions-runner-win-x64-2.338.2.zip` 哈希完全一致）
  - 优先复用 packages 里的离线包，没有才下载
  - 装到 **C:\actions-runner（本地磁盘）**，不是 SMB 共享盘。
    .credentials 是明文私钥，_work 放网络盘会让每个 job 都走 SMB
  - 解压用系统自带 tar.exe，不依赖被部分环境拦截的 Add-Type
  - 自动加 `--labels xp-toolchain`，支持 `--unattended` / `--runasservice`
  - UTF-8 BOM + 纯 ASCII 源码，避开之前中文路径乱码的坑
  - token 只从 -Token 参数传入，脚本里不保存

实测结果（在本机 Windows PowerShell 5.1 上）：
  [ok] 共享路径自动识别、SHA256 匹配、tar.exe 解压出 276 个文件
  [ok] Runner.Listener.exe 版本 2.338.2
  [ok] -WhatIf 完整预演、-VerifyOnly 全流程（不注册、不消耗 token）
  [ok] 用无效 token 走 config.cmd，成功到达 GitHub runner-registration
       API 并被拒绝（404），未创建任何 runner

在 Surface 上使用（token 会过期 1 小时，请现场取新的）：

  cd \\6K-062的SURFACE\runner\scripts
  powershell -ExecutionPolicy Bypass -File .\add-runner-official.ps1 -WhatIf
  powershell -ExecutionPolicy Bypass -File .\add-runner-official.ps1 -Token <新token> -Replace -RunAsService

  -RunAsService 需要「以管理员身份运行」；-Replace 会用同名 runner
  替换掉现在共享盘上那个 agentId 21 的旧注册（名字都是 6K-062的SURFACE）。
  替换前建议先停掉旧 runner 服务/进程，避免两个进程抢同一个 agent。

【安全提醒】`add_runner\addrunner.txt` 里含有**明文 registration token**，
而且放在 SMB 共享上。任何能读这个共享的人都能用它给该仓库注册 runner。
建议用完后删除该文件，或到 GitHub 重新生成一个 token 让旧的作废。
新脚本不会把 token 写进任何文件。
