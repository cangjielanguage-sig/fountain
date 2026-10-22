# 环境准备与 fboot 安装

## 1. 平台选择

| 平台 | 支持程度 | 说明 |
| --- | --- | --- |
| WSL Ubuntu-24.04 / Linux | 首选 | fountain 的实际构建与运行环境；fboot、cjpm 均在此使用 |
| Windows git-bash | 可用但有坑 | 环境变量注册表值有错位（见第 6 节），写脚本前先核对 |
| Windows PowerShell | 不直接用于构建 | shell 会吞 `$(...)` / `which`；构建命令写成 `.sh` 再交给 bash 跑 |

**WSL 必须用 Ubuntu-24.04**：默认发行版（18.04）缺 liburing，fboot 启动即报
`error while loading shared libraries: liburing.so.2`。命令模板：

```powershell
wsl -d Ubuntu-24.04 bash -lc "<命令>"
```

## 2. 本机已知事实（2026-10 探测，动手前建议用 `install_fboot.sh check` 复核）

| 项 | 值 |
| --- | --- |
| fountain 源码 | `D:\docs\work\cangjie\projects\fountain`（WSL 内 `/mnt/d/...`） |
| 仓颉环境脚本 | `/mnt/d/docs/work/cangjie/cangjie.sh`（`~/.bashrc` 里 source） |
| SDK | `1.3.0-alpha`，`CANGJIE_HOME=/mnt/d/docs/work/cangjie/cangjie-linux-bin/sdk/1.3.0/cangjie` |
| fboot 安装目录（CJPM_INSTALL） | `/mnt/d/docs/work/cangjie/installed` |
| 中心仓缓存（CJPM_CONFIG） | `/mnt/d/docs/work/cangjie/repository` |
| stdx 动态库 | 以 `$CANGJIE_STDX_DYNAMIC_PATH` 为准（参照 `linux_x86_64_cjnative/dynamic/stdx` 布局） |

版本号是活的：依赖要用的版本以 `f_version/src/FountainVersion.cj` 的 `Version` 或 `fboot version` 现场读取为准。

### 2.1 本机没有 fountain 源码时（文档副本 + 按版本切换）

`fountain_lookup.py` 找不到仓库根时会自动执行：
`git clone --depth 1 https://gitcode.com/Cangjie-TPC/fountain.git <skill-root>/fountain`，
该副本**仅用于查询文档**（README / 源码 API 参考，查询结果里会标注），不要用于构建或安装。
定位规则、版本优先级（`--version` > `$FOUNTAIN_VERSION` > 项目依赖）、切 tag 机制、`switch` / `version`
命令与「切版本只动副本」的约定见 SKILL.md「定位 fountain 仓库与查询版本」；本节只补该小节没有的细节：

- **换镜像 / 断开网络**：`--repo-url <URL>` / `--no-clone`（禁用克隆、`fetch`、`ls-remote` 与 `pull`；
  副本里已有目标 tag 时仍可本地 checkout）；
- **副本维护**：停在分支上时脚本会先 `pull --ff-only`，停在 tag 上（detached）时不做拉取；过时或损坏直接删掉
  `<skill-root>/fountain` 重新克隆（副本会随切换累积多个版本的快照，约 30MB/版本）；
- 构建 / 安装：用用户自己的 fountain 源码（`install_fboot.sh install` / path 依赖），或从中心仓装 fboot（3.2 节）。

实测（2026-10-10，gitcode）：`ls-remote --tags --refs`（76 个 tag）约 1s；首次浅克隆（1.3.14 快照 1547 个文件）
约 5s / 31MB；`fetch --depth 1 origin tag <tag>` 切版本约 2s。

实测（2026-10-10，gitcode）：`ls-remote --tags --refs`（76 个 tag）约 1s；首次浅克隆（1.3.14 快照 1547 个文件）
约 5s / 31MB；`fetch --depth 1 origin tag <tag>` 切版本约 2s。

**tag 怎么匹配**：按 **tag 名里的数字版本号**定位——cjpm 只接受 a.b.c 形式的数字版本号（项目依赖里就是这个号），
而数字版本号在 tag 名里唯一（实测本仓 76 个 tag 无重复），所以不必猜后缀形态：`release-1.3.14.alpha`、
`release-1.0.13`、`release-1.0.13.1`、`release-1.1.2.BETA`、`v1.3.9` 都能对上；也接受直接给 tag 名，
非数字输入只按 tag 名精确匹配（`release-1.3.9.alpha` 就是它本身，不会退化成按 `1.3.9` 匹配）。
同一数字版本号对应多个 tag 时（例如将来同时存在 `release-1.3.14` 与 `release-1.3.14.alpha`）取无后缀的
`release-<版本>`，并在结果里列出候选；一个都对不上时脚本给出警告并沿用副本现状态，
此时**不要把结果当作目标版本**。

## 3. 安装 fboot

### 3.1 从本仓库源码安装（推荐）

```bash
bash <skill-root>/scripts/install_fboot.sh install [--root DIR]
# 等价于：
# cd <fountain>/fboot && cjpm install --root DIR
```

`--root` 省略时脚本取 `$CJPM_INSTALL`，再不行取 `~/.cjpm`。

### 3.2 从中心仓安装（没有源码时）

```bash
cjpm install fountain::fboot-<版本> --root DIR
```

或 `bash <skill-root>/scripts/install_fboot.sh install --from-registry <版本> --root DIR`。

### 3.3 产物布局

```
<root>/bin/fboot        # 启动器可执行文件（Linux 无扩展名）
<root>/libs/fboot/*.so  # 框架动态库（Windows 产物为 .dll）
```

### 3.4 环境变量（每个新 shell 都要）

```bash
export PATH=$PATH:<root>/bin
export LD_LIBRARY_PATH=$LD_LIBRARY_PATH:<root>/libs/fboot
export CANGJIE_STDX_DYNAMIC_PATH=<stdx 动态库所在目录>
```

验收：`fboot version` 打印 `fountain(x.y.z)`；`fboot help` 打印命令列表。

### 3.5 查看 fboot 版本

```bash
fboot version                                                      # 返回 fboot 的版本，形如 fountain(x.y.z)
bash <skill-root>/scripts/install_fboot.sh version [--root DIR]   # 环境未配置时的查法：一次列出 PATH / 安装目录 / 源码三处
```

版本口径（它 = workspace 依赖版本 = 默认查询版本）、`install_fboot.sh version` 的自动装配行为（source 仓颉环境、
推断安装目录、同级 `libs/fboot` 重试）、「已安装版本与源码版本不一致属常态」与「别误用带参数形式」等，
见 SKILL.md「查看 fboot 版本」。

## 4. 在 WSL 里执行命令的规范

- `wsl -d Ubuntu-24.04 bash -lc "<cmd>"` 的 `bash -lc` **不读** `~/.bashrc`（Ubuntu 的 bashrc 对非交互 shell 提前退出），直接跑 `cjpm` / `fboot` 会 command not found。脚本里要**显式** `source /mnt/d/docs/work/cangjie/cangjie.sh`。
- 脚本**不要 `set -u`**：`cangjie.sh` 引用未定义变量，会让脚本在 source 那一步静默退出（无日志、无报错）。
- 从 Windows 侧下发命令时外层是 PowerShell：`$(...)`、`which`、`$var` 会被先解释。正确做法是：把逻辑写成 `.sh`（写到 `.autocode/tmp/` 之类目录）→ `sed -i 's/\r$//'` 去掉 CR → `wsl ... bash 脚本.sh`。
- 长构建/长测试：日志写 `/tmp/xxx.log` 再轮询；WSL 空闲回收会杀掉 `wsl -e bash -lc "nohup ... &"` 起的后台进程（日志也会消失）。要用 `Start-Process -FilePath wsl -ArgumentList '-d','Ubuntu-24.04','-e','bash','<脚本.sh>' -WindowStyle Hidden` 起独立常驻会话，或前台跑（工具调用可容忍约 3 分钟）。
- 同一 target 目录不要并发构建（并行会话/并行工具调用会互相干扰，报无关依赖的 `ld ... exit code 1` 时直接重试）。

## 5. 动态库搜索顺序（高频坑）

`~/.bashrc` 的 cangjie 环境把 `/mnt/d/docs/work/cangjie/installed/libs/fboot` 放进 `LD_LIBRARY_PATH`，且位置在应用自身产物目录**之前**。这些库没有 SONAME，运行时按名字取加载顺序里第一个同名库 ⇒

- 症状：改了 fountain 源码、重新构建应用后仍然报「新符号 undefined symbol」。
- 排查：`readelf -d` / `nm -D` / `ldd`（带上待验证的 `LD_LIBRARY_PATH`）确认实际加载的是哪一份 `libf_*.so`。
- 处理：让应用自己的 release 目录排在安装目录前面；或先刷新安装库（`cd <fountain>/fboot && cjpm install --root <CJPM_INSTALL>`）。
- 应用 release 目录里没有 stdx 与仓颉运行时库，安装目录/`CANGJIE_STDX_DYNAMIC_PATH` 仍要保留在搜索路径中。

另：从中心仓拉到驱动类动态库（如 `postgres_driver`）时，产物可能建在 `<target>/<名字>/release/` 这种嵌套目录里，需要按目录扫 `.so` 兜底加入 `LD_LIBRARY_PATH`（参考 `fdemo/boot.sh` 的 `extra_libs` 做法）。

## 6. Windows 侧已知错位（git-bash 构建前先核对）

- 注册表 `CANGJIE_HOME` 少一层：应为 `...\sdk\current\cangjie`。
- 注册表 `CANGJIE_STDX_DYNAMIC_PATH` 少一层且指向不存在的目录：应为 `...\stdx\current\dynamic\stdx`（即指向含库文件的那一层）。
- `D:\docs\work\cangjie\installed` 是 **WSL 里的 Linux 安装树**（`.so` + 无扩展名的 `bin/fboot`），Windows PATH 里的 `installed\bin`、`installed\libs\fboot` 对 Windows 进程无用。
- git-bash（MSYS）限制：`grep -P` 不可用（用 `-E`）；文件名里的 `:` 会被转换成私用区字符，日志文件名别用冒号。
- 参考 `fdemo/boot-win-gitbash.sh` 与 `frpcdemo/boot-win-gitbash.sh` 的写法；这两个脚本的「能跑通」尚未在 Windows 实机验证过。

## 7. 验证清单

1. `fboot version` 有输出且版本与预期的 fountain 版本一致。
2. `fboot help` 列出内置命令（run / module / workspace / build / test / count / version / pub / randhex …）。
3. `echo $CANGJIE_STDX_DYNAMIC_PATH` 指向真实存在的 stdx 动态库目录（`ls` 能看到 `libstdx.*`）。
4. 应用项目 `fboot build` 通过后，`.so` 产物能被 `fboot run` 的 `--dylibPattern` 匹配到。
