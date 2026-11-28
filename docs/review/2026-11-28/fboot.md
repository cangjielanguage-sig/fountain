# fboot 模块审查报告

- **审查日期**：2026-11-28
- **模块路径**：`fboot`（1 个 .cj + 2 个 .md，共 3 个文件）
- **基线**：工作区快照（sts/1.3.x，未对照远端目标分支；无 diff，全部问题记「存量」）
- **审查重点**：正确性、死代码、重复逻辑、空实现、存量 BUG、README 覆盖率
- **报告版本**：v1

## 发现

### [一般][存量] 零实参调用 `fboot` 直接数组越界，入口没有参数校验也没有错误兜底

- **位置**：`fboot/src/main.cj:21`（`App(args, dynamic: true).boot()`）
- **来源**：存量（`git blame -L 18,22 -- fboot/src/main.cj` → `4be871f2fd 2026-10-02`，纯换行符 / 包名迁移，逻辑自 2025-05-22 `eb4ef5a87` 起未变；快照模式无基线）
- **判据**：review-checklist §11（空集合 / `None` 未处理、缺少边界校验）+ §3（错误路径不兜底）
- **证据**：静态确定 —— `App.boot()` 第一句就是 `match (args[0])`（`f_app/src/App.cj:616`），此前无 `args.size` 判断；`App` 构造函数（`f_app/src/App.cj:29`）只做赋值，不补默认子命令。`main(args)` 的 `args` 不含程序名这一前提由仓库内同类入口反证：`fprobe/src/main.cj:44`、`fmq/src/main.cj:48` 都以 `if (args.size == 0)` 作为「无参数」分支；`App.start()`（`f_app/src/App.cj:632-637`）也是手工把 `run` 塞到 `args[0]` 再交给 `boot()`。
- **描述**：用户只敲 `fboot`（README 通篇按 `fboot <子命令>` 组织，这是最常见的首次交互）时 `args.size == 0`，`args[0]` 触发越界异常，进程带着堆栈信息退出，而不是打印命令列表。同一入口对 `BootException`（例如 `App.cj:496` 的「缺少 `--dylibPattern`」，这是面向用户的提示语）也不做捕获，参数错误一律以未捕获异常 + 堆栈呈现。触发条件仅为「子命令缺失 / 参数不全」，无数据损失，故按边界校验缺失定「一般」而非按运行时崩溃定「严重」。
- **建议**：`main` 里先判空再分发，与 fprobe / fmq 保持一致：
  ```cangjie
  main(args: Array<String>): Int64 {
      if (args.size == 0) {
          println(...)            // 或复用 App(['help']).boot()
          return 2
      }
      try {
          return App(args, dynamic: true).boot()
      } catch (e: BootException) {
          eprintln(e.message)
          return 2
      }
  }
  ```
  这样零参数、缺 `--dylibPattern`、未知子命令三种输入都能给出可读提示与固定退出码；`BootException` 已是 `public class`（`f_app/src/BootException.cj:19`），不需要改 f_app 契约。

### [一般][存量] README 命令清单落后于实现，缺 4 个已实现子命令，且与 `f_app` 的命令表两处不一致

- **位置**：`fboot/README.md:24-40`（`README_en.md:24-39` 同构同缺）
- **来源**：存量（`git blame` 显示清单由 `ae521006d7 2026-07-14` 引入，`1678120906 2026-11-25` 仅补了 cleanUpdate/count/pub/version/help；快照模式无基线）
- **判据**：review-checklist §14.2（公开能力未文档化）+ §13（文档与实现不符）
- **证据**：静态确定 —— 权威分发在 `f_app/src/App.cj:615-630`，内置子命令为 `run` / `shutdown` / `restart` / `module` / `workspace` / `cleanUpdate` / `build` / `test` / `count` / `version` / `help`，另有动态注册的 `pub`（`f_app/src/PublishCommand.cj:21`）、`randhex`（`f_app/src/RandHex.cj:28-30`）。README 只列了 9 个具体子命令（`run` / `workspace` / `module` / `build` / `cleanUpdate` / `count` / `pub` / `version` / `help`），缺 `shutdown <PID>`、`restart <PID> [PATH]`、`test [PATH]`、`randhex <n>`。
- **描述**：按 README 学不会停机与自测——`run` 是 `while(true) { sleep(Duration.Max) }` 的常驻进程（`f_app/src/App.cj:60-63`），唯一的正常停机手段 `fboot shutdown <PID>` 未在任何一份 fboot README 中出现；`test` 同样缺失。另外三处描述不完整：
  1. `fboot/README.md:38` 只写「`fboot version` 显示当前fountain版本号」，实际带参数时是破坏性操作：`git pull` → 递归改写全部 `cjpm.toml` 的 `version`/`cjc-version` → 改写 `f_version/src/FountainVersion.cj` → `git add/commit` → `git push`（`f_app/src/App.cj:69-171`，`git push` 在 `:162`），README 未提示会提交并推送。
  2. `fboot/README.md:32` 只写「编译使用fountain开发的应用项目」，漏了 `build [<path>] [--cfgkey=cfgval[,...]]` 的约定——`--k=v` 形式的参数被转成子进程环境变量、其余参数透传给 `cjpm build`（`f_app/src/App.cj:450-461`，help 文本 `:594`）。
  3. `fboot/README.md:35` 的 `pub <version>` 未提 `--skip-lint` / `--skip-test`，而实现把它们写进了错误提示的推荐命令行（`f_app/src/PublishCommand.cj:73,87`）；`fboot/README.md:29` 说 `<direct_path>` 是「绝对路径」，实现同时接受相对路径并按当前目录拼接（`f_app/src/App.cj:296-305`，help 文本 `:590`）。
  中英文两版逐条对齐，因此 `README_en.md:26,29,32,35,38` 存在完全相同的缺口（属"同步地一起过期"，不是翻译漏译）。
- **建议**：把 `App.help()`（`f_app/src/App.cj:583-612`）与 `f_app/README.md` 的内置子命令表作为唯一来源，fboot README 只保留「安装 / 启动 / 创建项目」三段 + 一句"完整子命令见 `fboot help`"，避免第三份手抄清单继续漂移；若要保留清单，至少补齐 `shutdown` / `restart` / `test` / `randhex` 与 `version`、`build`、`pub` 的参数说明，中英同步改。

### [轻微][存量] README 无标题、无用途段、无前置条件，读者从根 README 跳进来直接落在安装命令上

- **位置**：`fboot/README.md:1`（`README_en.md:1` 同）
- **来源**：存量（文件首行自 `ae521006d7 2026-07-14` 起即为 `## 安装`；快照模式无基线）
- **判据**：review-checklist §14.2（缺关键段落：用途、依赖与安装）
- **证据**：静态确定 —— `fboot/README.md:1` 是 `## 安装`，全文无 H1、无「fboot 是什么」、无仓颉 SDK / cjc 版本要求（`fboot/cjpm.toml` 的 `cjc-version = "1.2.0"`、`version = "1.3.2021"`）；对照同仓 `f_app/README.md:1-5` 的写法（H1 标题 + 版本口径 + 依赖说明）。根 `README.md:44-48` 只有一句「依赖fountain的应用项目启动程序」并把详情链接指到本文件，读者到这里得不到补充信息。
- **描述**：影响的是可发现性而非正确性：新用户不知道 fboot 只负责加载动态库、不负责编译应用，也不知道要装哪个版本的 SDK；`workspace 下每个模块必须编译为动态链接库`这条关键约束孤零零地挂在第 15 行，没有被组织进「前置条件 / 限制」段。
- **建议**：补一行 H1（`# fboot`）+ 两三句用途与边界（"只做启动与脚手架，编译交给 cjpm"），把 SDK 版本、workspace 必须 dynamic、`run` 常驻需 `shutdown` 停机整理成「前置条件 / 注意事项」段；中英同步。

## 优化可行性方案

> 本模块只有 1 个 `.cj`（1 行委托调用），无堆分配、无循环、无锁、无序列化路径，不构成 CPU / 内存优化对象。0 条方案。

## 待验证假设

> 本模块无热点可疑点，未采集也未提出性能假设（入口只做一次委托，`App` 是 `struct`，见 `f_app/src/App.cj:24` 注释）。

| # | 假设 | 位置 | 缺什么数据 | 怎么采 |
| --- | --- | --- | --- | --- |
| — | 无 | — | — | — |

## 文件覆盖

| # | 文件 | 类型 | 已读 | 说明 |
| --- | --- | --- | --- | --- |
| 1 | `fboot/README.md` | .md | ✅ | 命令清单与实现漂移，见发现 #2；缺标题/用途段，见发现 #3 |
| 2 | `fboot/README_en.md` | .md | ✅ | 与中文版逐条对齐，同缺 #2/#3 |
| 3 | `fboot/src/main.cj` | .cj | ✅ | 1 行委托 `App(args, dynamic: true).boot()`；版权头在 `package` 之前，见发现 #1 |

合计：`.cj` 1 个 / `.md` 2 个 / 共 3 个，全部读完。

## 覆盖自检

| 维度 | 命中 | 未命中时的说明 |
| --- | --- | --- |
| 正确性 / 设计 / 语言特性 / 可读性 / 安全性 | 1 | 正确性：零实参越界（发现 #1）。设计：入口只做委托，分层正确，无跨层调用。语言特性：隐式尾表达式返回 `Int64`、`struct App` 值语义均用法正确；`import fountain::f_app.*` 通配导入仅用 `App`，可收窄但不算问题。安全性：本模块不解析外部输入、无凭据、无日志，0 条。 |
| §1 死代码 | 0 | `main.cj` 没有 `private` / `internal` / `protected` 声明；唯一的 `main` 是入口；无 `return` 后置语句、无未用局部变量；`import fountain::f_app.*` 中的 `App` 已被使用。两份 README 无代码。 |
| §2 重复逻辑 | 1 | `.cj` 层无重复实现。重复只在文档层：同一份 CLI 命令清单被手抄到 `fboot/README.md`、`fboot/README_en.md`、`f_app/README.md` 与 `App.help()` 四处，且已漂移（缺 shutdown/restart/test/randhex）——已并入发现 #2，不另计。 |
| §3 空实现 | 0 | `main` 是真实委托调用，不是空函数体；模块内无 `TODO` / `FIXME` / `catch {}` / `throw UnsupportedException`；CLI 行为全部在 f_app（不在本模块统计）。 |
| §4 栈溢出 | 0 | 无递归、无自引用结构；调用链 `main → App.boot` 深度固定为 2（f_app 内递归属其自身范围）。 |
| §5 OOM | 0 | 无容器、无预分配、无全量物化；`args` 由运行时提供，本模块不复制。 |
| §6.1 热点瓶颈 | 0 | 入口仅一次函数调用，无循环与 I/O 热点；未提供 profile/bench 数据，按规则不出热点结论。 |
| §6.2 大粒度锁 | 0 | 无线程、无锁、无 `synchronized`。 |
| §6.3 并发串行 | 0 | 无 `spawn` / `Future`；`run` 内并发初始化在 f_app。 |
| §6.4 低效算法 | 0 | 无循环、无查找、无字符串拼接。 |
| §7 降堆内存方案 | 0 | 无堆对象创建（`App` 为 `struct`，`f_app/src/App.cj:24-33`），无方案可提。 |
| §8 降 CPU 方案 | 0 | 单次委托调用，无计算、无分配、无序列化。 |
| §9 local mode 可行性 | 0 | 函数内无临时大对象，`main` 只转交参数；local region 收益无法用峰值内存证明，不适用。 |
| §11 现有代码的 BUG（存量） | 1 | 已核对 `main` 的入参边界（空数组未处理）→ 发现 #1；`App.boot` 返回值透传正确，退出码语义成立。 |
| §12 并发安全与锁粒度 | 0 | 本模块无共享可变状态、无静态字段；`main` 单线程执行，`App` 按值传递，线程封闭可证。启动期 `spawn` 与初始化顺序在 f_app，不在本模块。 |
| §14 功能完备性与 README 覆盖 | 2 | 发现 #2（4 个已实现子命令未文档化 + 3 处参数说明缺失 + 1 处路径描述不准）、发现 #3（缺标题/用途/前置条件段）。代码侧无"承诺未实现"：README 列出的每个子命令在 `App.boot` 中都有对应分支，无空实现、无接线缺失。 |
| 文件覆盖（§13 等） | 3/3 | 3 个文件全部读完，无遗漏；§13 的文档-实现比对已落到 `f_app/src/App.cj` 行号。 |

**范围外提示**（不计入本模块统计，供对应模块复核）：
- `f_app/src/App.cj:299` 只把以 `/` 开头的参数当绝对路径，Windows 下 `D:\foo` 会被当成相对路径拼到当前目录，README #5 的"绝对路径"承诺在 Windows 上不成立（f_app 模块范围）。
- `f_app/src/App.cj:583-612` 的 `help()` 自身也漏了 `shutdown` / `restart` / `test`，与 dispatch 列表不一致（f_app 模块范围）。
- `f_app/README.md:3` 自称版本 `1.3.7`，`f_app/cjpm.toml` 是 `1.3.2021`（全仓各模块均为 `1.3.2021`，无漂移；仅 f_app 文档口径过期，f_app 模块范围）。

## 模块统计

| 严重程度 | 数量 |
| --- | --- |
| 严重 | 0 |
| 一般 | 1 |
| 轻微 | 2 |
| 优化方案（堆内存 / CPU） | 0 / 0 |

存量缺陷 3 条（1 一般 + 2 轻微），是否纳入修复待用户决定。

## 总评

代码本体质量良好：`fboot` 只剩一行入口委托，版权头规范、`package` 前置、返回码透传正确，没有死代码、重复实现、空实现、递归或内存增长面，也不存在并发共享状态——这与"应用没有 `main`、由 fboot 加载动态库"的工程约定一致，`App` 用 `struct` 且入口不做额外分配也是对的。

唯一的功能性风险是入口边界：零实参（以及参数不全导致的 `BootException`）没有兜底，`fboot` 单独执行会以越界异常 + 堆栈结束，属于首用即撞到的问题，建议排期修掉；修法只是 `main` 里加判空与一个 `catch`，不动 f_app 契约。

文档是本模块的主要欠账：命令清单在 `App.boot` 分发、`App.help()`、`f_app/README.md`、`fboot/README.md` 四处各存一份，fboot 这份最旧，缺 `shutdown` / `restart` / `test` / `randhex`，还把 `fboot version x.y.z` 这个会 `git commit` + `git push` 的破坏性操作写成"显示版本号"——这一条最容易造成误操作，应与代码侧边界问题一并处理。缺标题与用途段属可读性问题，可随后续文档整理一并做。
