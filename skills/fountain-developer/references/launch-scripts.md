# 启动脚本生成指南（boot.sh / boot-macos.sh / boot-win-gitbash.sh）

工作流 E / F 的「搭骨架」阶段要为项目生成三平台启动脚本，模板取自 `fdemo`（Web/MVC 型）与
`frpcdemo`（RPC 型）。本文件是选用、合并与校验规则；**模板源码永远以仓库里的两份 demo 为准**
（先用 `fountain_lookup.py root` 定位仓库根，再 read 对应文件）。

## 1. 模板清单

| 项目形态（用到的模块） | Linux/WSL | macOS | Windows git-bash |
| --- | --- | --- | --- |
| Web / MVC（`f_mvc`、`f_orm`、`f_log`、`f_bean`、`f_security`、`f_ticktock` 等） | `fdemo/boot.sh` | `fdemo/boot-macos.sh` | `fdemo/boot-win-gitbash.sh` |
| RPC（`f_rpc` 服务端/客户端） | `frpcdemo/boot.sh` | `frpcdemo/boot-macos.sh` | `frpcdemo/boot-win-gitbash.sh` |
| 两者都用到 | 按第 4 节合并两份模板 |

## 2. 公共骨架（三平台一致，逐项保留）

- 用法：`./boot.sh <cmd> [target_path] [args...]`；`target_path` 缺省值按项目调整（fdemo 是脚本自身目录，frpcdemo 是 `./target`）。
- `exports()`：所有运行期配置。Web 型含 `logger_*` / `mvc_*` / `orm_*` / 切面配置项；RPC 型含 `logger_*` / `rpcServer_*` / `rpcClient_*` / `rpc_currentSkeleton`。
- **库搜索路径前插**：先把工程自己的 `release/*` 子目录放进搜索变量最前面（`find <target>/release/* -type d | grep -v '_stAtIc__|\.build-logs|<排除项>'`），否则会命中安装目录里的旧副本 ⇒ undefined symbol。
- `build()` → `fboot build $target_path $args`；`cleanUpdate()` → `fboot cleanUpdate $target_path`；运行 → `fboot run $target_path --dylibPattern='<正则>'`。
- `case "$1"` 子命令分派：Web 项目用 `run`；RPC 项目用 `runServer` / `runClient`。

## 3. 平台差异（按目标平台照抄对应实现，不要跨平台混用）

| 维度 | Linux/WSL（boot.sh） | macOS（boot-macos.sh） | Windows git-bash（boot-win-gitbash.sh） |
| --- | --- | --- | --- |
| 动态库搜索变量 | `LD_LIBRARY_PATH`（前置） | `DYLD_FALLBACK_LIBRARY_PATH`（SIP 会剥 `DYLD_LIBRARY_PATH`） | `PATH`（前置）；stdx 目录也要进 PATH |
| 目录列举/过滤 | `find` 可用 `-printf '%h\n'`；`grep -P` 可用 | **BSD find：无 `-printf`**，用 `find -type d`；`grep -E` | `find -type d`；`grep -E` |
| 配置传递 | `export` 环境变量 | `export` | 拼 `--key=value` 参数传 `fboot run`（`f_config` 读命令行参数与环境变量等价；**值里不要套引号**） |
| stdx 路径变量 | 原样使用 | 原样使用 | `cygpath -w` 转 Windows 形式；`cjpm` 是原生进程，只认 Windows 路径 |
| 编译后产物 | 无需额外动作 | 无需额外动作 | 若库分散在 `release/*/`，`cp release/*/*.dll release/libs/` 后统一进 PATH |
| 日志文件名 | 可用 `:` | 可用 `:` | **`:` 非法**（MSYS 会换成 U+F03A）⇒ 用 `-` |

## 4. 同时用到两套模块时的合并规则

1. **环境变量取并集**：logger 一组只保留一份（appender 名、日志路径改成项目自己的）；MVC/ORM 与 RPC 的配置项各自保留。
2. **dylibPattern 取并集**：把需要的包名段合成一个正则，例如 `'(boot|\.(controller|service\.impl)|rpcserver|rpcclient)'`；确保覆盖 controller、service.impl、初始化、cron、RPC 各库。
3. **子命令取并集**：`run`（Web）、`runServer` / `runClient`（RPC）、`build`、`cleanUpdate` 都保留。
4. **平台差异按目标平台选**：合并的是「业务配置与子命令」，不是「平台实现」——macOS 版仍用 BSD find，Windows 版仍用 `--key=value` + `cygpath`。
5. **RPC 特有约束**（来自 frpcdemo 注释）：
   - `rpcServer_port` 只接受端口号：脚本从「主机:端口」里拆出端口；
   - `rpcServer_baseAddresses` 要包含自己，否则注册表报不出权重；
   - Windows 上服务端日志名把 `:` 换成 `-`。
6. **敏感信息**：连接串/密钥只在 `build`（编译期嵌入）或用运行期环境变量提供；不要写死在脚本里。

## 5. 生成清单（Agent 执行步骤）

1. 定位仓库根并读模板：Web 型读 `fdemo` 三份脚本；含 RPC 再读 `frpcdemo` 三份。
2. 按项目模块清单确定：`dylibPattern`（覆盖哪些库）、需要保留的环境变量（对照 `server-development.md` 的模块映射与 `fdemo/boot.sh` / `frpcdemo/boot.sh` 的注释）。
3. 在项目根生成三个文件：`boot.sh`、`boot-macos.sh`、`boot-win-gitbash.sh`（文件名与 demo 保持一致）。
4. 按第 3 节表格逐平台改平台差异项；按第 4 节合并业务配置。
5. 校验：三个脚本都过 `bash -n`；在用户平台 `./boot.sh build` 应能构建（编译期配置在此生效）。
6. 在项目 README（或交付报告）里写清各平台启动方式与判据。

## 6. 生成后的校验与运行

```bash
bash -n boot.sh && bash -n boot-macos.sh && bash -n boot-win-gitbash.sh   # 语法
./boot.sh build            # 构建（编译期配置生效）
./boot.sh run              # 长驻进程：交给用户执行或后台跑，给判据（端口/日志）
./boot.sh cleanUpdate      # 依赖或产物异常时的清理重建
```

## 7. 注意事项

- 工程自建库目录必须排在安装目录（`installed/libs/fboot`）**之前**；从中心仓拉来的驱动产物可能在
  `<target>/<名字>/release/` 嵌套目录里，需要兜底扫 `lib*.so`（Linux）/ `.dll`（Windows）加入搜索路径
  （`fdemo/boot.sh` 的 `extra_libs` 是现成做法）。
- 三个脚本要**同步维护**：改了一个平台的配置，另外两个平台要跟改。
- Windows 上 `CANGJIE_STDX_DYNAMIC_PATH` 需要转成 Windows 路径（`cygpath -w`）并写入用户级环境变量，
  否则新终端里 `cjpm`/原生进程找不到 stdx（`fdemo/boot-win-gitbash.sh` 的 `build()` 是完整做法）。
- 脚本变更后用 `bash -n` 复核，再实际跑一次 `build` 验证；不要只改不验。
