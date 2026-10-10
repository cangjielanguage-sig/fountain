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
`git clone --depth 1 https://gitcode.com/Cangjie-SIG/fountain.git <skill-root>/fountain`，
该副本**仅用于查询文档**（README / 源码 API 参考，查询结果里会标注），不要用于构建或安装：

- 查询：`python <skill-root>/scripts/fountain_lookup.py modules`（第二次起直接用副本，不会重复克隆）；
- **按版本查询（默认行为）**：查询前先定目标版本——`--version X.Y.Z`（也可给 tag 名）> `$FOUNTAIN_VERSION`
  > 当前项目 cjpm.toml 里 `"fountain::f_*"` 的依赖版本（从当前目录向上找最近的）。定了版本后脚本把副本切到
  对应 tag（`git fetch --depth 1 origin tag <tag>` + `git checkout --detach`，只取该版本快照，实测约 30MB / 几秒；
  命中本地已有 tag 时不联网），再检索；**输出头部标注实际版本**；
- 只切副本 / 看状态：`python <skill-root>/scripts/fountain_lookup.py switch 1.3.9`（`switch latest` 回默认分支）、
  `python <skill-root>/scripts/fountain_lookup.py version`；
- **切版本只动技能目录下的副本**：`--root` / `$FOUNTAIN_ROOT` 指定的源码目录不会被改动（版本不符时输出警告）；
  自动发现的源码目录版本不符时，脚本改用文档副本并在 stderr 说明；
- 构建 / 安装：用用户自己的 fountain 源码（`install_fboot.sh install` / path 依赖），或从中心仓装 fboot（3.2 节）；
- 换镜像 / 断开网络：`--repo-url <URL>` / `--no-clone`（禁用克隆、`fetch`、`ls-remote` 与 `pull`；
  副本里已有目标 tag 时仍可本地 checkout）；
- 副本过时或损坏：直接删掉 `<skill-root>/fountain` 重新克隆（副本会随切换累积多个版本的快照，约 30MB/版本）；
  副本停在分支上时脚本会先 `pull --ff-only`，停在 tag 上（detached）时不做拉取。

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

- **`fboot version` 返回的就是 fboot 的版本**（`fountain(x.y.z)`）；这个 `x.y.z` 也是 `fboot workspace` 自动写入 workspace 根 cjpm.toml 的
  `"fountain::f_base"` / `"fountain::f_version"` 版本号（fboot 的版本与其内置的 fountain 版本一致），工作流 D 添加其它模块也用它。
- fboot 不在 PATH 时（新 shell 未配置环境，直接跑会报 `libf_app@fountain.so` 打不开）用脚本的 `version` 子命令：它会自动 source 仓颉环境、
  从 fboot 位置推断安装目录，并用同级 `libs/fboot` 重试，无需手工配 PATH / LD_LIBRARY_PATH。
- **已安装 fboot 与源码版本不一致是常态**（本机实测：PATH 中 1.3.9、源码 1.3.14）。应用依赖版本以 fboot 版本为准；
  想用源码版本就先重装 fboot（工作流 A）再建 workspace。
- 带参数形式 `fboot version x.y.z [msg] [tag [tagmsg]]` 是**升版 / 打 tag 的管理命令**（会 git pull / commit / push），
  不是查询命令，别误用。

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
