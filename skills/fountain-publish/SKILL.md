---
name: fountain-publish
description: Use when 要把 fountain 模块发布到仓颉中心仓（fboot pub、cjpm install、发版、发布、制品入库、版本 a.b.c），或发布过程中出现限流 / 频率限制 / 429 / Too Many Requests / 请求过于频繁 / 请稍后再试需要立即停止并等 24 小时，或需要判断本次发布应在 Windows 的 WSL Ubuntu-24.04、鸿蒙 PC 的融合开发引擎、还是物理机上执行。
---

# fountain-publish — 安装 fboot 并发布模块

## 概述

固定三步：**判定执行环境 → 以 fboot 目录为工作目录安装 fboot → 在 fountain 仓库根执行 `fboot pub`**。

核心原则：**限流即停，等满 24 小时再重跑**。`fboot pub` 对失败会按斐波那契退避**无限重试**，所以「停」必须由执行方终止整个进程树，不能指望它自己退出；限流后绝不原地重试、绝不换模块继续发。

以下命令都在 fountain 仓库根执行；不在仓库根时给脚本加 `--repo <仓库根>`。

## 何时使用 / 不适用

适用：

- 用户要求发布 fountain 版本（`fboot pub <a.b.c> --skip-test --skip-lint`）；
- 发布输出里出现限流字样，要判断何时能重跑；
- 要确认这次发布该在 WSL、融合开发引擎还是物理机上跑。

不适用：

- 打 tag、升版本号 → `fountain-tag`（发布前先完成它的升版提交）；
- 只编译 / 只跑测试；
- 只手工发布单个模块（本技能按仓库 `.modules` 的 `[include]` 全量发布）。

## 第一步：判定执行环境（必做，不要靠记忆猜）

| 判定 | 执行位置 | fboot 安装命令 |
|---|---|---|
| Windows（`os.name == 'nt'`） | WSL Ubuntu-24.04（脚本转发） | `cd <repo>/fboot && cjpm install --root /mnt/d/docs/work/cangjie/installed` |
| 已在 WSL 里（`WSL_DISTRO_NAME`，或 `/proc/version` 含 `microsoft`） | 本机（WSL 语义） | `cd <repo>/fboot && cjpm install --root /mnt/d/docs/work/cangjie/installed` |
| 鸿蒙 PC 本机（`/system/bin/param` 存在，或 os-release 含 `ohos`/`harmony`） | 融合开发引擎（ssh） | 远端 `cd <repo>/fboot && cjpm install` |
| 已在融合开发引擎（`/mnt/linux_share` 存在） | 本机 | `cd <repo>/fboot && cjpm install` |
| 其他（Linux / macOS 物理机） | 本机 | `cd <repo>/fboot && cjpm install` |

用脚本判定并打印执行计划：

```bash
# Windows PowerShell 用 python，WSL / 融合引擎用 python3
python skills/fountain-publish/scripts/publish.py detect
python skills/fountain-publish/scripts/publish.py detect --json   # 机器可读
```

输出 `mode / executor / repo / install / publish / state` 六行。显式覆盖用 `--env windows|wsl|harmony|fusion|native`（`wsl` = 当前已经在 WSL 里，直接本机执行并带 `--root`）。

- Windows 分支由脚本自动 `wsl.exe -d Ubuntu-24.04 -- bash -lc 'source /mnt/d/docs/work/cangjie/cangjie.sh; …'` 转发，内层按 `--root /mnt/d/docs/work/cangjie/installed` 安装。
- 鸿蒙本机分支必须给融合引擎 ssh 目标：`--remote user@host`（或环境变量 `FU_PUBLISH_REMOTE`；连接信息沿用 `opsx-*` 技能固化的 ssh），远端仓库默认 `/mnt/linux_share/storage/Users/currentUser/Documents/cangjie/projects/fountain`，可用 `--remote-repo` 覆盖。缺 `--remote` 就停下来问用户，不要在本机硬跑。远端仓库需有同一份技能文件（同仓库、同分支），否则远端找不到 `publish.py`。

## 第二步：一键发布

```bash
python3 skills/fountain-publish/scripts/publish.py run --version a.b.c
```

脚本按顺序做：

1. **冷却门禁**：`<git-dir>/fountain-publish/state.json` 未满 24 小时 → 直接退出 3，不执行任何命令（无可用 `.git` 时落在 `~/.fountain-publish/<仓库哈希>/`）。
2. **装 fboot**：`cd <repo>/fboot && cjpm install`（WSL 自动带 `--root /mnt/d/docs/work/cangjie/installed`；融合/物理机裸 `cjpm install`）。装完把 `<root>/bin`、`<root>/libs/fboot` 补进 `PATH` / `LD_LIBRARY_PATH`。
3. **发布**：`cd <repo> && fboot pub a.b.c --skip-test --skip-lint`。
4. **盯结果**：逐行读 `fboot pub` 输出，每 60 秒打 `[STATUS] phase=… current=… modules=… failures=… elapsed=…`，结束时打 `[SUMMARY] exit=… elapsed=… modules=… log=…`。`cjpm install` 阶段只落日志、不按限流处理（依赖下载的瞬时「请稍后」会误冻结 24 小时）。
5. `fboot pub` 命中限流 → 杀进程树、写 `state.json`、退出 3；其他失败退出 4。

长任务（agent 工具会超时时）：后台跑，再轮询脚本日志里的状态行；不要把一整天的发布挂在前台调用上。

```bash
nohup python3 skills/fountain-publish/scripts/publish.py run --version a.b.c > /tmp/fp.log 2>&1 &
grep -aE '\[STATUS\]|\[RATE-LIMIT\]|\[SUMMARY\]' /tmp/fp.log
```

脚本自己的日志在 `<git-dir>/fountain-publish/publish-<版本>-<时间戳>.log`（主检出通常是 `<repo>/.git/fountain-publish/`；没有可用 `.git` 时落在 `~/.fountain-publish/<仓库哈希>/`）。

可选参数：`--skip-install`（fboot 已装好）、`--heartbeat 0`（关心跳）、`--repo`（不在仓库根执行时指定）、`--rate-limit-pattern`（追加限流正则）。

## 限流：立即结束，24 小时后重跑

判定（**大小写不敏感，命中任意一条**）：`限流`、`频率过高/超限/限制`、`频繁`、`rate limit`、`too many requests` / `TooManyRequests`、`429`、`请稍后（再）试/重试`、`try again later`。遇到新文案先用 `--rate-limit-pattern '<正则>'` 补，再把模式加进 `scripts/publish.py` 的 `RATE_LIMIT_PATTERNS`。监控只覆盖 `fboot pub` 阶段；`cjpm install` 失败按退出码 4 处理。

命中后必须：

1. **立即终止整个进程树**（脚本已做：POSIX `killpg`，Windows `taskkill /T`），不要让它继续重试；
2. 写 `state.json`：`rate_limited_at`、`resume_after`（限流时刻 + 24 小时）、触发规则、命中行、日志路径；
3. 结束本次执行（退出码 3），汇报恢复时刻。

冷却规则：

- 未满 24 小时重跑 → 直接退出 3，不 install、不 pub；把 `resume_after` 与剩余时间报给用户。
- 满 24 小时后重跑同一条命令即可；已入库模块由 `checkPublished(once: true)` 跳过，代价小。
- `--wait`：原地等到恢复时刻再继续，**只适合常驻会话**；WSL 空闲回收、工具超时、进程被杀都会让它白等，默认不要用。
- `--force`：仅当用户明确说「不等了」时使用。

## 发布前检查

- 版本号已由 `fountain-tag` 升好并提交；`f_version/src/FountainVersion.cj` 的 `Version` 与各 `cjpm.toml` 应等于 `a.b.c`。不一致时 `fboot pub` 会强制改掉（`replaceVersion`），改完会留在工作区。
- `git status` 不应有与本轮发布无关的改动——`fboot pub` 会改写各模块 `cjpm.toml` 再还原，别和手工改动混在一起。
- fboot 未安装不用手工试探，`run` 会自动装；只有 `--skip-install` 时才要求 PATH 里已有可用 fboot。

## 验收（不要只看「本地 success」）

1. 脚本输出 `[SUMMARY] exit=0` 且日志里有 `publish completed in …`。
2. 抽查仓库侧制品是否真入库：

```bash
curl 'https://pkg.cangjie-lang.cn/v1/artifact/getPackageMetadata?group=fountain&moduleName=<模块>&version=a.b.c'
# 期望 {"code":200,"msg":"success",...}；600009 = 制品不存在
```

**本地 `cjpm publish success` ≠ 仓库侧入库**（f_pool 有先例：clean/bundle/publish 三步 exit=0，metadata 始终 600009）。至少抽查根模块与高风险模块；发现缺失单独排查，不要反复重发同一版本。

## 退出码

| 退出码 | 含义 | 下一步 |
|---|---|---|
| 0 | 发布完成 | 抽查 metadata 后交付 |
| 2 | 环境 / 参数错误 | 按提示修环境或参数（版本号 must be `a.b.c`） |
| 3 | 限流已停止（或在 24 小时冷却内） | 等到 `resume_after` 再重跑，不要重试 |
| 4 | `cjpm install` / `fboot pub` 非限流失败 | 看日志定位；fboot 会无限重试，必要时 Ctrl-C |
| 130 | 用户中断 | 已入库模块下次会自动跳过 |
| 其他（1/126/127/255…） | 转发或环境失败，发布通常还没开始 | 检查 `wsl.exe` / `ssh`、发行版名、`--remote-repo`、内层 `python3` 与技能文件 |

## 排障

| 现象 | 处理 |
|---|---|
| `fboot: command not found` | install root 的 `bin` 未进 PATH；脚本会补 `<root>/bin`，也可手工 `export PATH=<root>/bin:$PATH` |
| `lib*.so: cannot open shared object file` | 补 `export LD_LIBRARY_PATH=<root>/libs/fboot:$LD_LIBRARY_PATH` |
| `wsl.exe` 找不到 | 先 `wsl --install -d Ubuntu-24.04`；或 `--env` 指定实际环境 |
| 鸿蒙本机报缺少融合引擎 | 给 `--remote user@host`，或直接在融合引擎里运行本技能 |
| ssh 报 `BatchMode` / 认证失败 | 先配免密；不要把密码写进命令 |
| `Error: output-type … must be 'executable' for cjpm install` | `fboot pub` 内的非致命校验（返回值被忽略），不是失败原因 |
| 某模块反复失败、日志无限退避 | 非限流失败也会无限重试；看日志判断后中断，不要放着跑 |
| `f_pool` 报 600009 | 单独查仓库侧原因，不要反复 bundle/publish |
| WSL 会话被回收（退出 143） | 用后台 + 独立常驻会话；重跑即可，已入库模块会跳过 |
| `state.json` 损坏 / 读不出恢复时刻 | 脚本会拒绝执行（退出 2）而不是放行；确认上次限流时刻已满 24 小时后删除该文件 |
| 在 worktree 里状态落到 `~/.fountain-publish/<哈希>/` | `.git` 是文件且另一侧解析不了 gitdir；发布建议在主检出执行，或接受该 fallback 路径 |

## Red Flags — 命中就停下

| 你正想做 | 现实 |
|---|---|
| 在 Windows 上直接 `cd fboot && cjpm install` | 本流程一律经 WSL；WSL 才带 `--root /mnt/d/docs/work/cangjie/installed` |
| 在鸿蒙 PC 本机跑 `cjpm install` / `fboot pub` | 鸿蒙本机没有融合引擎工具链；经 `--remote` 到融合引擎，或在融合引擎里跑 |
| 把 WSL 与融合引擎的 `--root` 用反 | WSL 带 `--root`；鸿蒙 / 融合引擎 `cjpm install` 不带 `--root` |
| 命中限流后重试，或继续发布下一个模块 | 立即结束并等 24 小时；必须杀进程树 |
| 限流后只在对话里说「稍后再试」 | 必须落 `state.json` 并给出 `resume_after` |
| 未满 24 小时又跑一遍 | 直接退出 3，不执行任何命令 |
| 用 `--force` 绕过冷却 | 只有用户明确要求时 |
| 认为 `cjpm publish success` = 已入库 | 抽查 metadata，600009 是缺失 |
| 手工改 `cjpm.toml` / `FountainVersion.cj` 的版本 | `fboot pub` 自己会改；不要手改 |
| 把 `Error: output-type …` 当发布失败 | 非致命，别据此重试 |

## 随包资源

- `scripts/publish.py` — `detect`（只读判定）/ `run`（安装 + 发布 + 限流停止）/ `selftest`（限流判定自检）。
- 状态与日志：`<git-dir>/fountain-publish/`（`state.json` + 每次发布的日志）。
