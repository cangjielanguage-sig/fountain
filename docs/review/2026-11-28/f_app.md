# f_app 模块审查报告

- **审查日期**：2026-11-28
- **模块路径**：`f_app`（9 个源文件 + 2 个文档，共 11 个文件，约 1947 行）
- **基线**：工作区快照（sts/1.3.x；无 diff，全部问题记「存量」）
- **审查重点**：命令分发正确性、进程与资源生命周期、死代码、重复逻辑（与 fboot 命令表）、存量 BUG、README 覆盖率
- **报告版本**：v1

## 发现

> 以下发现按出现顺序编号 #1–#21（#1–#2 严重、#3–#17 一般、#18–#21 轻微），正文与「覆盖自检」表用 `#N` 引用。

### [严重][存量] `restart` 把 PID 当成目录路径：建一个以 PID 命名的目录，加载不到任何库，然后静默常驻

- **位置**：`f_app/src/App.cj:205-208`（`restart`）；`f_app/src/App.cj:191-193`（`shutdown(pid)` 取 `args[1]`）；`f_app/src/App.cj:40-42` → `f_app/src/funcs.cj:20-30,31-37`（`load` → `confirmTargetPath`）
- **来源**：存量（快照基线）。`git blame -L 205,208 -- f_app/src/App.cj` → `4be871f2fd 2026-10-02`；`confirmTargetPath` 自 `90f62c03b` 起固定按 `args[1]` 取路径。
- **判据**：review-checklist §11（契约与实现不符 / 逻辑错误）+ §14.1（接线缺失）
- **证据**：静态确定 —— README `f_app/README.md:74` 与 `help` 文本都把 `restart` 定义为 `fboot restart <PID> [PATH] --dylibPattern=...`；但 `restart()` 只是 `shutdown()` + `run()`，`shutdown()` 用 `Int64.parse(args[1])` 取 PID，紧接着 `run()` 把**同一份 `args`** 交给 `load()`，`confirmTargetPath` 判定 `args[1]`（就是 PID 字符串，不以 `-` 开头）为路径，`!exists(path)` 时执行 `Directory.create(path)`。
- **描述**：`fboot restart 12345` 的实际行为是：① 杀掉 12345；② 在当前目录创建空目录 `12345`；③ 扫描该目录找 `lib*.so`，一无所获；④ `InitializerCollection.initialize()` 无任务可做；⑤ 打印 `... started by fountain(1.3.2021) in ...`；⑥ `while(true){ sleep(Duration.Max) }` 永久阻塞。旧进程已停止、新进程没有加载任何业务库，用户看到的却是"启动成功"横幅，且工作目录里多出一个垃圾目录。这是本模块唯一会直接造成"服务停摆且无报错"的分发缺陷。
- **建议**：`restart` 不要复用 `this.args` 走 `run()`；显式构造去掉 PID 的实参（`App(args[1..]).run()` 或 `run(args[1..])` 并把 `run(args:)` 真正用起来，见 #18），或在 `restart` 里单独解析 `args[2]` 作为路径。另外 `confirmTargetPath` 不应有"顺手建目录"的副作用（见 #4）。

### [严重][存量] 初始化依赖无法满足时 `InitializerCollection.doInit` 无限循环：启动挂死、无日志、占满一核

- **位置**：`f_app/src/Initializer.cj:79-96`（`:81` 取队首、`:83` 判定依赖、`:85` 放回队尾、`:91` 删除已完成依赖）
- **来源**：存量（`git blame -L 79,96 -- f_app/src/Initializer.cj` → `4be871f2fd 2026-10-02`，`1937e41f92 2026-10-17` 只加了 provider 收集，循环结构未变）
- **判据**：review-checklist §11（逻辑错误 / 无出口循环）
- **证据**：静态确定 —— `dependencies` 的 key 只在 `register` 时由各 `Initializer.dependencies` 建立（`:57-67`），只有在"同名 initializer 完成初始化"时才 `dependencies.remove(initializer.name)`（`:91`）。`doInit` 判断项是 `dependencies.contains(dependency)`（`:83`），即"这个依赖名还没被移除"。若某个依赖名根本不会有对应 initializer（拼写错误、该模块的动态库没被 `--dylibPattern` 匹配到、被条件编译裁掉），该 key 永不删除 → 这个 initializer 每轮都被取出、判定为"依赖未满足"、再 `add` 回队列（`:85`），`while` 永不退出；A↔B 互相依赖同理。
- **描述**：触发条件全部来自部署期（库目录里少了某个模块），不是代码 bug 的极端输入。后果是进程在 `load()` 里死循环、没有任何输出（`:48` 的 `log.debug` 只在扫描阶段）、CPU 单核打满，运维只能凭"启动卡住"猜。`README.md:212` 只写了"会自动拓扑排序"，没写失败语义。
- **建议**：在 `doInit` 里记录"本轮成功初始化数"，一轮为 0 就抛 `BootException` 并列出所有 `dependencies` 中仍未满足的 key 与等待它们的 initializer 名；或在进入循环前先做一次"依赖名 ⊆ 已注册名"的校验（含环检测），启动即失败。

### [一般][存量] 内置命令表在四处分头维护，已出现文案漂移（`count` 重复、缺 `shutdown` / `restart` / `module` / `test`）

- **位置**：`f_app/src/App.cj:615-631`（`boot` 的 `match`）、`f_app/src/App.cj:582-613`（`help` 硬编码文本）、`f_app/src/SubCommand.cj:38`（未知命令的错误消息）、`f_app/README.md:70-84`（表格）
- **来源**：存量（`git blame -L 615,631 -- f_app/src/App.cj` → `a2f5a41b6 2026-09-19`；`help` 文本最后一次改动未同步新增的 `test`）
- **判据**：review-checklist §2（字面量复制 / 换形式复制的同一张命令表）
- **证据**：静态确定 —— 四份清单实际内容：
  - `boot`：`run` / `shutdown` / `restart` / `module` / `workspace` / `cleanUpdate` / `build` / `test` / `count` / `version` / `help`（11 个）；
  - `SubCommand.cj:38` 的错误消息：`count|run|workspace|cleanUpdate|build|count|version`——`count` 出现两次，缺 4 个内置命令；
  - `help` 文本：缺 `test` / `shutdown` / `restart`，且第 5 条写"把模块加入当前目录的 cjpm.toml"，而 `App.cj:329-331` 实际写的是**上一层目录**；
  - README 表格：11 个全，但 `count` 的参数列缺两个已实现开关（见 #19）。
- **描述**：这不只是文档问题——`SubCommandMediator` 的报错是用户敲错命令时唯一看到的提示，它把内置命令列表写错（重复项 + 缺失项），会直接把用户引到不存在的命令上；`help` 文本把 `module` 的落点写反，用户按提示操作会把模块加错位置。
- **建议**：定义一份 `const BUILTIN_COMMANDS: Array<(String, String)>`（名 + 一句话说明），`boot` 用前缀匹配分发、`help` 渲染它、错误消息从它拼 `strings.Join`；`SubCommand` 模块不该再手写内置命令名（它是被 `boot` 调用的下游）。

### [一般][存量] 未命中命令的兜底路径三重副作用：忽略 `dynamic:false`、跑完全部初始化、顺手创建目录

- **位置**：`f_app/src/SubCommand.cj:34-43`（`:40` `load(args, true)`）、`f_app/src/funcs.cj:20-30`（建目录）、`f_app/src/funcs.cj:61-62`（`InitializerCollection.initialize()` + 退出回调）
- **来源**：存量（`git blame -L 34,43 -- f_app/src/SubCommand.cj` → `4be871f2fd 2026-10-02`）
- **判据**：review-checklist §11（契约与实现不符）+ §14.1（开关只在一处判断，另一处走旧逻辑）
- **证据**：静态确定 ——
  1. `SubCommandMediator.exec` 写死 `load(args, true)`，完全绕开 `App.dynamic` 字段；`App(args, dynamic: false)` 在未知命令时照样扫描并加载动态库，与 `README.md:161`「`dynamic` 为 `false` 时不进行动态库扫描」相反；
  2. `confirmTargetPath(args)` 对 `args[1]` 无条件 `Directory.create`：`fboot typo foo`、`fboot publ 1.0.0` 会在当前目录生成 `foo/`、`1.0.0/`；
  3. `load()` 末尾无条件 `InitializerCollection.initialize()`，所以"命令名打错"要付整应用初始化的代价（ORM 建连、MVC 装配……），然后才抛 `BootException`。
- **描述**：拼错命令是最常见的用户操作，当前实现把"查命令"做成了"启动整个应用并改文件系统"，副作用不可撤销（初始化可能已对外建立连接）。
- **建议**：`exec` 增加 `dynamic` 参数由 `boot` 传入；`load` 拆成"解析路径（不建目录）"与"扫描加载"两步；`confirmTargetPath` 只在确实需要落盘的命令（`build` / `test` / `cleanUpdate`）里创建目录；命令未命中时先抛错、不初始化。

### [一般][存量] `test` 用 `test/cjpm.toml` 覆盖项目 `cjpm.toml`，无备份也无还原

- **位置**：`f_app/src/App.cj:487-499`（`:489` `copyToml('test', path)`）、`f_app/src/App.cj:469-471`（`overwrite: true`）
- **来源**：存量（`git blame -L 487,499 -- f_app/src/App.cj` → `4be871f2fd 2026-10-02`）
- **判据**：review-checklist §11（资源 / 状态不对称：改了不还原）
- **证据**：静态确定 —— `copyToml` 是 `copy(path.join('test/cjpm.toml'), to: path.join('cjpm.toml'), overwrite: true)`，之后只做 `doBuild` + `run`，没有任何 `finally` 或 `atExit` 把原文件写回。同一文件里的 `doBuild` 反而做了对称处理（`:436-441` 注册 `atExit` 恢复 `cjpm.toml` 并删除临时模块），说明作者知道这类"临时改配置"需要还原。
- **描述**：两条后果，取决于 `PATH/test/cjpm.toml` 是否存在：① 存在时，项目的 `cjpm.toml` 被永久替换成该文件内容（通常缺少 target / profile / 依赖版本段），用户若没提交过原配置就直接丢失，提交过则表现为"跑一次测试多出一堆脏改动"，构建失败时同样不还原；② 不存在时 `copy` 直接失败（本仓 `f_app`、`fboot` 等 9 个模块都没有 `test/cjpm.toml`，`ls */test/cjpm.toml` 无输出），也就是说 `fboot test` 在当前仓库完全不可用，而 README `:79` 把它列为受支持命令且没写"需要先准备 `test/cjpm.toml`"。
- **建议**：覆盖前 `copy` 到 `cjpm.toml.bak`，在 `try/finally`（或 `atExit`）里恢复；或者干脆不覆盖，把 `test/cjpm.toml` 作为 `--target-dir` 之外的独立 workspace 副本构建。

### [一般][存量] `shutdown` 用无 `sleep`、无超时的忙等轮询等进程消失

- **位置**：`f_app/src/App.cj:194-204`（`:196-202` 轮询）
- **来源**：存量（`git blame -L 194,204 -- f_app/src/App.cj` → `4be871f2fd 2026-10-02`）
- **判据**：review-checklist §11（资源处理 / 无界等待）
- **证据**：静态确定 —— `process.terminate()`（默认 `force: false`，即"由目标进程自行释放资源后结束"）之后是 `while (true) { try { findProcess(pid) } catch (_: ProcessException) { break } }`。按 std 文档 `process_package_funcs.md:149-172`，`findProcess` 只在 `pid` 不存在时抛 `ProcessException`，因此这段循环就是"对一个 syscall 做无间隔轮询"：目标进程优雅退出期间本进程 100% 占一核；目标进程忽略 SIGTERM（或权限不足杀不掉）时永不返回。
- **描述**：`fboot shutdown` 是部署脚本的收尾步骤，语义上应"最多等 N 秒，超时强杀并报错"。当前实现把"等不到"变成"永久卡住 + 烧 CPU"，CI 上表现为 job 超时而不是明确失败。
- **建议**：`sleep(50ms)` 轮询 + 总超时（如 30s），超时后 `terminate(force: true)` 并返回非 0；把"进程已退出"与"杀不掉"区分成两条日志。

### [一般][存量] 版本号校验正则的点号没有全部转义，非法版本号会通过校验并写进全仓 `cjpm.toml`

- **位置**：`f_app/src/App.cj:77`（`Regex(#'^\d+\.\d+.\d+$'#)`，第 3 段未转义）、`f_app/src/PublishCommand.cj:69`（`Regex(#'^\d+.\d+.\d+$'#)`，第 1、3 段未转义）；正确写法见 `f_app/src/App.cj:25-29`
- **来源**：存量（`git blame -L 77,77 -- f_app/src/App.cj` → `4be871f2fd 2026-10-02`；`PublishCommand.cj:69` 同批）
- **判据**：review-checklist §11（边界校验）+ §2（同一正则字面量三处各写一遍）
- **证据**：静态确定 —— `App.cj:25-29` 的 `versionRegex` 是 `^\d+\.\d+\.\d+$`（全转义），但 `version()` 自己另写了一个（`App.cj:77`），`PublishCommand` 又写了一个（`PublishCommand.cj:69`）。未转义的 `.` 匹配任意字符。
- **描述**：`fboot version 1.2x3` 能通过校验，随后 `App.cj:84-115` 递归改写工作目录下所有 `cjpm.toml` 的 `version`（并 `git add/commit/push`）；`fboot pub 1.3.2x1` 同样能通过，随后 `replaceDependencies`（`PublishCommand.cj:240`）把模块版本和同项目依赖都改成非法值再 `cjpm publish`。一次手滑就会污染全仓版本号并把非法制品推上去。
- **建议**：删掉两处内联正则，统一引用一个全转义的 `static let versionPattern = Regex('^\\d+\\.\\d+\\.\\d+$')`；顺手把 `App.cj:82-83` 的两个 toml 正则也提成常量，便于中英文档引用同一口径。

### [一般][存量] `version ... tag '消息'` 丢弃用户给的 tag 消息，实际把版本号当成附注

- **位置**：`f_app/src/App.cj:133-159`（`:141-145` 追加的是 `args[1]`）；契约文本在 `f_app/src/App.cj:605-607`（`help`）与 `f_app/README.md:98`
- **来源**：存量（`git blame -L 133,159 -- f_app/src/App.cj` → `4be871f2fd 2026-10-02`）
- **判据**：review-checklist §11（契约与实现不符）+ §14.1
- **证据**：静态确定 —— `tagmsg` 只被用来判断"有没有 tag 参数"（`:133-139`），真正拼进 `-m` 的是 `msg`（提交信息）加上 `'\n${args[1]}'`（`:142`，即版本号）。用户传入的 `tagmsg` 字符串没有任何一处被读取。
- **描述**：`fboot version 1.3.2022 'fix xxx' tag '发版说明'` 生成的是 `git tag -a release-1.3.2022 -m "fix xxx, version: 1.3.2022\n1.3.2022"`——"发版说明"丢失，附注里多了一行重复的版本号。`help:607` 承诺"以'版本消息'创建附注tag"，README 则绕开描述，两处都与实现不一致。
- **建议**：`msg += if (tagmsg.size > 1) { '\n${tagmsg[1]}' } else { '' }`（或直接用 `tagmsg[1]` 作为 `-m`），并按最终行为同步 `help` 与两版 README。

### [一般][存量] `pub` 的模块发现只扫一层：`Directory.walk` 非递归，嵌套模块既不会发布也过不了 `[include]` 校验

- **位置**：`f_app/src/PublishCommand.cj:133-150`（`:136` `Directory.walk`，`:134-135` 注释）
- **来源**：存量（`git blame -L 133,150 -- f_app/src/PublishCommand.cj` → 循环体 `4be871f2fd 2026-10-02`，注释由 `b016d34fcf 2026-11-13` 加入）
- **判据**：review-checklist §11（逻辑错误）+ 语言 / 标准库语义以文档为准
- **证据**：静态确定 —— std 文档 `fs/fs_package_api/fs_package_classes.md:430` 与 `:497` 两处都写明「遍历指定目录下的子项目（**非递归**，即不包含子目录的子项目）」；实现 `cangjie_runtime/stdlib/libs/std/fs/directory.cj:113-147` 也只有一个目录句柄的读取循环。而 `allModules` 的回调里没有任何递归调用（对照 `funcs.cj:45-57` 与 `App.cj:500-544` 都是显式递归），`:134` 的注释"Directory.walk 自身递归"与文档、实现相反。
- **描述**：`allModules` 只能发现工作目录**下一层**带 `cjpm.toml` 的目录。fountain 仓库的模块正好都在第一层，所以自身不受影响，但任何嵌套布局（如 `fdbm/test/e2e/custom_ext`、多级子模块的应用工程）都会：① 模块被漏发布；② 在 `.modules` 的 `[include]` 里点名时被 `check()`（`:160-164`）判成 `module X which is in [include] does not exists`，错误信息还指向"不存在"而非"层级太深"。
- **建议**：在回调里对 `fi.isDirectory()` 递归调用 `allModules(fi.path, modules)`（并保留隐藏目录剪枝），或改用一次性递归收集；同时改掉误导性注释。

### [一般][存量] 没有 `.modules` 文件时 `fboot pub` 直接抛 `FSException`，README 承诺的"两者都不写"路径不可用

- **位置**：`f_app/src/PublishCommand.cj:90`（`this.lines('./.modules')`）、`:53-55`（`path |> canonicalize |> lines`）、`:35-44`（`entireFile` 的 `exists` 兜底）
- **来源**：存量（`git blame -L 45,55 -- f_app/src/PublishCommand.cj` → `4be871f2fd 2026-10-02`）
- **判据**：review-checklist §11（边界：文件不存在）
- **证据**：静态确定 —— `canonicalize` 文档 `fs/fs_package_api/fs_package_funcs.md:23`（及 String 重载 `:81`）明确「路径不存在或无法规范化时抛出 FSException」。`lines(String)` 先 `canonicalize` 再进 `entireFile`，而 `entireFile` 里的 `if(exists(path)) ... else ''` 说明作者本意是"文件不存在视为空"。该兜底分支从 `exec` 的调用路径上永远走不到。
- **描述**：`fboot pub 1.3.2022` 在没有任何范围文件的项目里直接崩在 `canonicalize`；`README.md:241` 却说"也可以两者都不写（发布遍历到的全部模块）"。fountain 根目录有 `.modules`，所以问题被掩盖，下游项目第一次用 `pub` 就会踩。
- **建议**：`exec` 里改成 `let lines = if (exists('./.modules')) this.lines('./.modules') else Iterator.empty()`；或让 `lines(String)` 不做 `canonicalize`（`File.readFrom` 自己会抛，兜底逻辑也就统一了）。

### [一般][存量] `pub` 的依赖排序没有环检测，`checkLoop` 也没有重试上限：两种情形都会永久挂起

- **位置**：`f_app/src/PublishCommand.cj:321-379`（`:325` 队列、`:330-334` 回队）、`:276-292`（`checkLoop` 无限退避）、`:380-396`（`:391` 用 stdout 固定行判成功）
- **来源**：存量（`git blame -L 321,379 -- f_app/src/PublishCommand.cj` → `4be871f2fd 2026-10-02`）
- **判据**：review-checklist §11（无出口循环 / 错误处理）
- **证据**：静态确定 + 待确认 ——
  - 静态确定：`pub()` 只要发现"还有 `moduleInfos` 里存在的被依赖模块"就把自己 `q.add(m)` 再 `return`（`:330-334`）；A↔B 互相依赖时两者永远互为未完成，`while (let Some(m) <- q.remove())` 在两者之间无限往返，无日志输出（只有第一次的 `to publish ... after ...`）。
  - 静态确定：`checkLoop` 的 `while(result.isNone())` 只在回调返回 `Some` 时退出，`catch (e: Exception)` 分支返回 `None`（`:313-317`），即"探测失败 → 永远重试"；`b` 按斐波那契增长（`:286-288`），第 90 轮附近 `Int64` 溢出、退避时长早已到"天"量级。
  - 待确认：`cjpm` 子进程是否真的会打印 `cjpm clean success` / `cjpm bundle success` / `cjpm publish success`（`:338-343`）；若目标 `cjpm` 版本文案不同，`success` 恒为 `false`（`:388-395`），整段发布重试也会变成永久挂起。
- **描述**：三种挂起叠加在同一个"发布"动作上：依赖环（无提示）、网络/仓库不可达（无限退避）、成功标记不匹配（无限重试）。对 CI 来说是 job 永不结束，对本地是终端静默卡住。
- **建议**：发布前做一次拓扑排序并显式抛"依赖成环：A → B → A"；`checkLoop` 增加最大轮数与总时长上限（超限抛 `BootException`）；成功判定改为退出码，stdout 匹配只做日志。

### [一般][存量] `pub` 探测制品仓库时把 TLS 校验设为 `TrustAll`

- **位置**：`f_app/src/PublishCommand.cj:293-320`（`:297-299`）
- **来源**：存量（`git blame -L 297,299 -- f_app/src/PublishCommand.cj` → `4be871f2fd 2026-10-02`）
- **判据**：review-checklist §10（安全性：凭据 / 传输安全）
- **证据**：静态确定 —— `let tls = TlsClientConfig(); tls.verifyMode = TrustAll`，随后 `ClientBuilder().tlsConfig(tls).build()` 请求 `https://pkg.cangjie-lang.cn/v1/artifact/getPackageMetadata?...`；响应只判断 `{code: 200, msg: 'success'}`（`:304-309`）。
- **描述**：中间人返回一个伪造的 `{"code":200,"msg":"success"}` 就能让发布流程相信"该版本已发布"从而跳过真实发布（`once: true` 分支），或反过来让 `cjpm install`（`:308`）从被劫持的源安装依赖。发布链路是供应链入口，关闭证书校验属于必须修的安全缺陷；`TrustAll` 大概率是为了绕过内网代理缺 CA，但代价放错了地方。
- **建议**：恢复默认校验（系统 CA），确实需要自签时通过 `TlsClientConfig` 指定 CA 文件路径；把 `verifyMode` 做成显式配置项并在 README 写明风险。

### [一般][存量] `load()` 算出了动态库搜索路径变量与分隔符却从未设置；`macOS` 分支还调用了该平台不支持的 `PackageInfo.load`

- **位置**：`f_app/src/funcs.cj:33-37`（`libPathName` / `delim` 解构后无任何使用）、`f_app/src/funcs.cj:35`（`case macOS => (".dylib", ...)`）+ `:51-53`（`PackageInfo.load`）；对应承诺缺口写在 `f_app/README.md:270`
- **来源**：存量（`git blame -L 33,37 -- f_app/src/funcs.cj` → `4be871f2fd 2026-10-02`）
- **判据**：review-checklist §14.1（接线缺失 / 平台能力与承诺不符）+ §1（读了不用）
- **证据**：静态确定 —— ① `match (OS.current)` 产出 `(".so", 'LD_LIBRARY_PATH', ':')` 三元组，`ext` 用于文件名后缀判断（`:51`），`libPathName` / `delim` 之后再未出现，`load()` 只返回 `(path, providers)`，没有把路径写进 `std.env` 或子进程环境；② `PackageInfo.load` 的文档 `reflect/reflect_package_api/reflect_package_classes.md:8270-8274` 明确「**不支持平台：macOS、iOS**」，而 `funcs.cj:35` 仍为 macOS 匹配 `.dylib` 并走同一条 `PackageInfo.load`（`:53`），按文档会抛 `ReflectException`（`:8286`）；同页 `:8287` 还写明"相同包名 / 相同文件名的共享库重复加载会抛异常"，`load()` 对此没有任何幂等保护。
- **描述**：第 ① 点：`fboot run /opt/app` 的典型部署形态是"主库 + 若干被依赖的 `.so` 同目录"。仓颉动态库加载的符号解析依赖进程的库搜索路径；当前实现既不设置 `LD_LIBRARY_PATH` / `DYLD_FALLBACK_LIBRARY_PATH`，也没有其它注入手段，所以只要被加载的库依赖同目录其它库，加载就会失败（`PackageInfo.load` 抛异常，`load` 没有 try/catch，直接冒到 `boot`）。README 已承认"库搜索路径变量并未实际设置"。第 ② 点：整条 macOS 分支在当前 SDK 上必然失败——`fboot run` 在 macOS 上会停在第一个 `.dylib`，而 README `:270` 的扩展名表把 macOS 列为受支持平台，使用者会以为是路径或库的问题。第 ③ 点：同一进程内二次 `load()`（`test` → `run`、异常后重试等路径）会因重复加载同一动态库抛 `ReflectException`，错误信息是"重复加载"而不是"已加载"。
- **建议**：在 `load()` 开头把 `path` 追加（去重）到 `libPathName` 指向的变量（`std.env.setVariable`，Windows 用 `SetDllDirectory` 等价手段）；macOS 分支要么改为明确报错"当前 SDK 的 `PackageInfo.load` 不支持 macOS"，要么在 README 与 `help` 里去掉 macOS 支持声明；给已加载库记一个 `HashSet<String>` 做幂等，重复项直接跳过。

### [一般][存量] `initialize()` 用 `unsafeZeroValue` 把单例整体置零，二次调用或置零后注册都会在 null 容器上崩

- **位置**：`f_app/src/Initializer.cj:94`（`instance = unsafeZeroValue<InitializerCollection>()`）、`:47-52`（三个引用型字段 + `Mutex`）、`:101-103`（`initialize()`）
- **来源**：存量（`git blame -L 79,96 -- f_app/src/Initializer.cj` → `4be871f2fd 2026-10-02`）
- **判据**：review-checklist §11（错误处理）+ §12.1（共享可变状态无保护）
- **证据**：静态确定 —— `InitializerCollection` 是 `struct`，字段 `mutex` / `initializers` / `dependencies` 全是引用类型；`unsafeZeroValue` 会把它们置为 null。此后：① 任何 `InitializerCollection.register(...)`（后加载动态库的 `static init`）走 `doRegister` → `synchronized(mutex)`（`:55`）取 null 锁；② 任何 `initialize()` 再调用走 `doInit` → `initializers.remove()`（`:81`）对 null 队列调用。仓内有宿主自行调用该 API：`fdbm/src/server/CustomLoader.cj:85`、`fprobe/src/runtime/AgentRuntime.cj:99`。
- **描述**：README `:203` 把 `initialize()` 描述为"一次性的（结束时会把自己置空）"，但没写第二次调用的后果。`fdbm` 的加载流程是"先 `PackageInfo.load` 多个扩展库 → 再 `initialize()`"，如果宿主在 `App.load()` 之后又走一次自定义加载（或在 `initialize()` 之后再 `register`），就会拿到 `NullPointerException` 而不是可诊断的错误。并发下还有第二重问题：`instance` 是普通 `static var`，`doInit` 的读取—置零与 `register` 的写入之间没有同步，两个线程同时 `initialize()` 会各自遍历并各自置零。
- **建议**：用 `private static var initialized = false`（加锁或 `Atomic`）替代 `unsafeZeroValue`；二次 `initialize()` 返回空列表并 warn，`register` 在已初始化状态下显式抛 `BootException`。

### [一般][存量] 各模块 `start()` 用 `spawn` 启动后丢弃 `Future`：启动失败不传播，进程仍打印"started"并永久阻塞

- **位置**：`f_app/src/App.cj:57-62`
- **来源**：存量（`git blame -L 57,62 -- f_app/src/App.cj` → `4be871f2fd 2026-10-02`）
- **判据**：review-checklist §12.1（异步语义：`Future` 异常被吞 / 超时但任务继续跑）
- **证据**：静态确定（后果中的"是否打印堆栈"待确认）—— `for(provider in providers){ let current = provider; spawn{ current().start() } }`，`spawn` 的返回值没有被保存，主线程紧接着 `while(true){ sleep(Duration.Max) }`。`Initializer.start()` 的契约（`Initializer.cj:42-45`）明确"是否阻塞取决于实现"，所以 `start()` 抛异常（端口被占、DB 连不上、证书过期）时，主线程既不会收到异常也不会改变退出码。
- **描述**：`fboot run` 的输出是唯一的启动信号，而它在所有 `start()` 之前就打印了 `'${app}... started by ...'`。端口冲突这类最常见的启动失败，用户的观感是"打印了 started、进程活着、服务 404"。排查时也没有 `spawn` 线程名或失败计数可依。
- **建议**：收集 `Future<Unit>`，至少在 `start()` 外包 `try/catch` 打 `log.error` 并 `exit(非0)`（或把失败写进一个原子计数，主循环检测到就退出）；若要保持"任何一个 start 都可阻塞"，至少别在 start 之前打印 `started`。

### [一般][存量] `randhex` / `shutdown` 缺少实参校验，错误全部表现为未捕获异常

- **位置**：`f_app/src/RandHex.cj:36-40`（`args[0]`、`Int64.parse`）、`f_app/src/App.cj:183-185`（`pid()` 取 `args[1]`）
- **来源**：存量（`git blame -L 36,40 -- f_app/src/RandHex.cj` → 创建提交；`App.cj:183-185` → `4be871f2fd 2026-10-02`）
- **判据**：review-checklist §11（边界 / 空值 / 错误处理）
- **证据**：静态确定 —— `fboot randhex`（无参）→ `args[0]` 数组越界；`fboot randhex abc` → `Int64.parse` 按 std 文档 `convert/convert_package_api/convert_package_interfaces.md:830-832` 在转换失败时抛 `IllegalArgumentException`（同页 `:786-800` 提供 `tryParse` 返回 `Option`）；`fboot shutdown`（无 PID）→ `shutdown()` 内 `pid()` 取 `args[1]` 越界。`version` 分支在取 `args[1]` 前先判了 `args.size == 1`，安全。两处都没有 `try/catch`，`boot` 也没有统一的 arity 校验。
- **描述**：用户少打一个参数，看到的是 `IndexOutOfBoundsException` / `IllegalArgumentException` 加堆栈，而 README 只列了用法。对 CLI 工具来说这是最容易被当成"工具坏了"的体验问题，也让退出码失去意义（当前统一为未捕获异常的非 0）。
- **建议**：在 `boot()` 的每个分支入口做 arity 检查（缺参打印 usage 并返回 2），`randhex` 用 `tryParse` 并对 `count <= 0` 给出明确提示。

### [一般][存量] `build` 找不到 workspace `members` 时 `addModule` 静默不做任何事，临时版本模块因此不参与编译（版本与横幅静默丢失）

- **位置**：`f_app/src/App.cj:415-426`（`:419` 的条件）、`:435`（返回值被忽略）、`:442-449`
- **来源**：存量（`git blame -L 415,426 -- f_app/src/App.cj` → `4be871f2fd 2026-10-02`）
- **判据**：review-checklist §3（静默失效 / 空操作）+ §14.1（接线缺失）
- **证据**：静态确定 —— `addModule` 只有在 `toml.indexOf('members')` 与随后的 `']'` 都命中时才改写；否则直接返回原 `toml`，既不打日志也不报错。`doBuild` 不看返回状态，照样 `Directory.create(versionModuleDir)`、`cjpm init`、写 `src/<n>_AppVersion.cj`（`:442-449`），但这个目录不在 workspace 的 `members` 里，`cjpm build` 不会编译它 → `AppVersion.set(...)` 永不执行。
- **描述**：单模块工程（没有 `[workspace] members`）或 `members` 写法不被 `indexOf(']')` 命中的工程，`fboot build` 会"成功"产出一个没有版本号、没有横幅的产物：`run` 时 `AppVersion.version.isEmpty()` 为真，只打印 `'<app> started by fountain(...)'`，`banner.txt` 也不生效（`App.cj:49-53`、`:371-383`）。排查方向会被引向 `AppVersion` / `f_version`，而真正的断点在 `addModule` 的静默 no-op。
- **建议**：`if (!toml.contains(moduleMember))` 且找不到可插入位置时抛 `BootException('cjpm.toml 缺少 [workspace] members，无法注入 ${versionModuleName}')`；`doBuild` 前先用返回状态校验一次。

### [轻微][存量] 死代码集合：不可达语句、恒假分支、无读字段、未用 import、无调用者私有函数、恒空状态导致的死分支、未读形参

- **位置**（`private` 已全仓搜符号名，`internal` 已在本包及子包内搜引用）：
  - `f_app/src/App.cj:66` —— `while(true){ sleep(Duration.Max) }` 之后的 `0` 不可达；
  - `f_app/src/App.cj:146`、`:152` —— `msg` 在 `:121-128` 的两条分支里都会被赋非空，`msg.isEmpty()` 恒假，`:152-157` 的失败文案分支永不执行；
  - `f_app/src/App.cj:32` —— `appHomeIsWorkingPath` 全仓无读取（`grep -rn appHomeIsWorkingPath f_app/src` 仅定义处），属兼容残留；
  - `f_app/src/imports.cj:22`（`getCommand`）、`:24`（`InputStream`）—— 全模块无使用（`grep -rn "getCommand\|InputStream" f_app/src` 仅 import 行）；
  - `f_app/src/PublishCommand.cj:35-37` —— `entireFile(path: String)` 无调用者，只有 `Path` 重载被 `lines` 使用；
  - `f_app/src/PublishCommand.cj:340`、`:345-348` —— `nodep` 初始化为 `''` 后从未赋值，`nodep.value != ''` 恒假，整段 `cjpm install` 永不执行；
  - `f_app/src/App.cj:43-44` —— `run(args: Array<String>)` 的形参 `args` 从未被读取（`load()` 用的是成员 `this.args`），`test():498` 传入的 `path` / `dylibPattern` 实际被丢弃（当前靠 `this.args[1]` 恰好等于同一路径才没出错）。
- **来源**：存量（快照基线；上述行分别来自 `4be871f2fd 2026-10-02`、`1937e41f92 2026-10-17`）
- **判据**：review-checklist §1（不可达语句 / 恒假分支 / 无调用者 / 读了不用）
- **证据**：静态确定 —— 见上列搜索命令与赋值/读取路径。
- **描述**：`run(args:)` 的未读形参最危险：`sleep(Duration.Max)` 后的 `0` 只是噪音，但"传参被忽略"会让下一位维护者误以为 `test` 走的是参数里的路径，任何把 PID 从 `restart` 里剥掉的改动都会失效（见 #1）。`nodep` 死分支则掩盖了"发布完成后没有安装依赖"这一能力缺口。
- **建议**：删 `:66` 的 `0`、`PublishCommand.cj:35-37` 与 `nodep` 相关分支；`appHomeIsWorkingPath` 若已废弃就从构造函数移除（README 同步删掉那句"尚未参与任何逻辑"）；`run(args:)` 要么使用形参（`load(args, dynamic)`），要么删掉形参并把 `test()` 的调用改成 `run()`。

### [轻微][存量] README / README_en 的过期与覆盖缺口：`extractPattern` 描述、版本号、依赖清单、`count` 新开关、`help` 差异

- **位置**：`f_app/README.md:270`（`README_en.md:275` 同）、`f_app/README.md:3`（`README_en.md:3`）、`f_app/README.md:4`（`README_en.md:4`）、`f_app/README.md:80`（`README_en.md:80`）、`f_app/README.md:82`（`README_en.md:82`）
- **来源**：存量（`git blame -L 264,275 -- f_app/README.md` → README 重写提交；`f_app/src/funcs.cj:38-44` 已改成读 `Config.getDylibPattern()`，README 未跟随）
- **判据**：review-checklist §13（文档与实现不符）+ §14.2（README 覆盖不足）
- **证据**：静态确定 ——
  1. README:270 说 `--dylibPattern` 的提取是"取首个非 `--dylibPattern=` 参数的下一个下标再切片 ⇒ 缺省 `PATH` 或没有位置参数时会下标越界"。实际实现是 `funcs.cj:38-44`：`Config.getDylibPattern()` 去掉成对引号。配置值来自 `f_config` 的静态初始化（`f_config/src/Config.cj:60-68` 解析 `env.getCommandLine()`，`:304-306` 提供 getter），与位置参数顺序无关，也不存在那段切片，因此"会下标越界"这条排障提示已经不成立，真正的约束（`--dylibPattern` 没给时正则退化为 `^lib.*(|.+_stAtIc__).*$`，等于匹配全部 `lib*`）反而没写；
  2. README:3 写"当前 `1.3.7`，与 `f_version/src/FountainVersion.cj` 同步"，实际 `f_app/cjpm.toml:6` 与 `FountainVersion.cj:21` 都是 `1.3.2021`；
  3. README:4 的依赖列表漏了 `f_config`（`cjpm.toml:24`，`funcs.cj` / `App.cj` 都直接用 `Config`），同时列了 `f_concurrent`（`cjpm.toml:23`），但 `f_app/src/**` 没有任何 `f_concurrent` 符号引用（待确认是否为运行期需要）；
  4. README:80 的 `count` 参数列缺 `--ignoreTests` 与 `--ignoreDemos`（实现在 `App.cj:563-566`），`help` 文本（`App.cj:597`）同样没提，两个新能力只能靠读源码发现；
  5. README:82 说 `help`"不含 `test`"，实际 `help` 还缺 `shutdown` / `restart`（见 #3）。
- **描述**：第 1 条是"按文档排障会走错方向"级别的不一致（读者会去找一个不存在的下标越界）；第 2、3 条会让读者对依赖版本与必需模块判断错误；第 4 条属新能力未进文档。
- **建议**：把 README:270 改写成当前实现的真实语义（全局配置项、引号处理、空值的退化行为），版本号改成引用 `cjpm.toml` 或写具体值并纳入发版检查（`fboot version` / `pub` 时同步），依赖表按 `cjpm.toml` 重排，补 `count` 的两个开关与 `help` 的差异说明；中英两版逐条同步。

### [轻微][存量] 「改写 FountainVersion 版本号」有两份实现，放行条件与替换范围都不同；`check()` 的错误文案固定写 `[include]`

- **位置**：`f_app/src/App.cj:384-404`（`version` 命令用）与 `f_app/src/PublishCommand.cj:56-62`（`pub` 命令用）；`f_app/src/PublishCommand.cj:160-164`
- **来源**：存量（`git blame -L 384,404 -- f_app/src/App.cj` → `4be871f2fd`；`PublishCommand.cj:56-62` 同批）
- **判据**：review-checklist §2（跨文件复制后行为漂移）
- **证据**：静态确定 ——
  - `App.replaceVersion`：要求 `workingDir.fileName` 是 `fountain` 或 `fboot`，只替换 `fountain\((\d+\.)+\d+\)` 与 `release-(\d+\.)+\d+` 两处；
  - `PublishCommand.replaceVersion`：要求路径 `endsWith('fountain')`，用 `\d+\.\d+\.\d+` 对整文件做 `replaceAll`，会把注释、示例、任何三段数字一起改掉；
  - 两者对同一文件（`f_version/src/FountainVersion.cj`）的触发条件（目录名 vs 路径后缀）与替换粒度都不同，且都不做"改完是否仍合法"的校验。
- **描述**：`fboot pub 1.3.2022` 与 `fboot version 1.3.2022` 对同一个文件产生不同的写入结果；`pub` 那条一旦文件里出现其它三段数字（注释里的示例、历史记录）会被一起改写。`check()` 被 `publishExcludes`（`:408`）复用时报错仍写 "which is in [include]"，用户会去检查 `[exclude]` 里没有的内容。
- **建议**：抽一个 `VersionFile.update(fountainRoot, version)`（唯一写入点，只改 `Version` 常量并派生 `FountainVersion`），两处命令都调它；`check()` 增加 `source` 参数用于文案。

### [轻微][存量] 路径与键的健壮性：`replace(ext, '')` 删掉路径中所有扩展名、`allModules` 用目录名当模块名

- **位置**：`f_app/src/funcs.cj:53`；`f_app/src/PublishCommand.cj:145`（key）、`:200-205`（用 key 判依赖）
- **来源**：存量（快照基线；`4be871f2fd 2026-10-02`）
- **判据**：review-checklist §11（边界）+ 语言语义以文档为准
- **证据**：静态确定 ——
  1. `String.replace(old, new)` 替换**全部**出现（std 文档 `core/core_package_api/core_package_structs.md:7904-7943`，示例 `"Hello, Hello, World".replace("Hello","Hi")` → `"Hi, Hi, World"`）。`PackageInfo.load(fi.path.toString().replace(ext, ''))` 会把路径里所有 `.so` / `.dll` 都删掉：`/opt/my.sources/libx.so` → `/opt/my.urces/libx`。应只剥结尾的扩展名（`fileNameWithoutExtension` 后拼回父目录，或 `removeSuffix`）。
  2. `allModules` 以 `fi.path.fileName`（目录名）作为模块键，而依赖行解析出的是 `cjpm.toml` 里声明的模块名（`:197-199` 剥掉 `org::`）。本仓目录名与模块名一致所以没暴露，一旦不一致（或不同层级出现同名目录）就会出现两种错：同名目录静默覆盖（后遍历到的赢），依赖名对不上 `modules` 而 `continue`（`:200-202`），既不排序也不报"未包含在发布范围"。
- **描述**：第 1 条只在路径本身含 `.so` 子串（如 `my.sources`、`foo.dll.backup` 目录）时触发，概率低但后果是"明明存在的库加载失败"；第 2 条是发布范围的正确性问题，静默跳过比报错更难发现。
- **建议**：用 `removeSuffix` 语义精确剥离；`allModules` 改以"解析 `cjpm.toml` 的 `name`（失败回退目录名）"为键，并在发现重复键时直接抛错。

## 优化可行性方案

> 本模块是一次性 CLI 进程：没有长期驻留容器、没有请求热路径、没有锁竞争。以下两条都属"可做但收益需实测"，没有改前 / 改后数据，一律标 `无基线（待验证）`，不进修复清单。

### [CPU] `versionRegex` 是一个每次访问都重新编译正则的属性

- **现状**：`f_app/src/App.cj:25-29` 的 `private static prop versionRegex: Regex` 在 getter 里 `Regex(...)`；唯一调用点 `App.cj:288` 在 `for(arg in this.args[1 .. ] where !versionRegex.matches(arg))` 的 `where` 里，**每个参数访问一次属性**，即每次 `fboot module` / `workspace` 冷启动编译 1~N 次同一正则。
- **方案**：改为 `private static let versionRegex = Regex('^\\d+\\.\\d+\\.\\d+$')`（库初始化时编译一次）；顺带把 `App.cj:77`、`PublishCommand.cj:69` 的内联正则统一引到它。
- **预期**：省掉每次参数的一次正则编译（单次开销与端到端影响均未测，不可据此声称提速）；实际价值主要是消除"同一正则三种写法"导致的语义漂移（见 #7）。
- **代价**：`static let` 在包初始化期编译，若正则非法会变成加载期失败而不是使用期失败（当前正则固定，风险为零）。
- **验证**：`cjpm bench -O2` 对比 `App(['module','x']).boot()` 冷启动 100 次的中位数与离散度；或 `cjprof record` 看 `Regex` 构造占比。**证据状态：无基线（待验证，不进 tasks）**

### [CPU] `pub` 的日志放大：逐行打印 cjpm.toml 与替换前后每一行

- **现状**：`PublishCommand.cj:171`（`extracting ${line} ...` 每行一条）、`:241-243`（打印完整 `cjpm.toml` + 分隔线）、`:266`（每行替换前后各一条）、`:269-271`（再打印整份替换结果）。一个 30 模块、每份 60 行的仓库约 30×(60×3 + 120) ≈ 9k 行日志，且 `println` 到 CI 的管道是同步写。
- **方案**：默认只打印模块级摘要（`publishing org::m`、依赖计数），逐行输出挂到 `--verbose`；错误路径保留完整 diff。
- **预期**：减少 `pub` 在 CI 的墙钟与日志体积（量级取决于日志 sink，需实测）。
- **代价**：排障时需要加 `--verbose` 才能看到逐行替换，README 需同步。
- **验证**：同机同仓库跑 `fboot pub`（dry-run 分支）5 轮，对照墙钟中位数与 stdout 字节数；`cjprof` 确认 `println` 不在前 10。**证据状态：无基线（待验证，不进 tasks）**

## 待验证假设

| # | 假设 | 位置 | 缺什么数据 | 怎么采 |
| --- | --- | --- | --- | --- |
| 1 | 目录里存在软链接环（`a -> ..`）时，`load` / `count` / `version` 的显式递归会无限下降直至栈溢出 | `f_app/src/funcs.cj:45-57`、`App.cj:85-88`、`App.cj:500-509` | `FileInfo.isDirectory()` 是否跟随符号链接、目标目录树里是否可能出现环 | 造 `ln -s .. loop` 后跑 `fboot count` / `fboot run`，观察栈深度与退出方式 |
| 2 | `Directory.walk` 在目标 SDK 上确实非递归（本报告按 std 源码判定），因此 `pub` 只发现一层模块 | `f_app/src/PublishCommand.cj:136` | 目标 SDK 上 `pub` 对两层目录布局的实际可见性 | 在临时工程 `a/b/cjpm.toml` 布局下跑 `fboot pub`，确认 `b` 是否被发现 |
| 3 | `cjpm clean/bundle/publish` 的 stdout 含固定行 `cjpm clean success` / `cjpm bundle success` / `cjpm publish success` | `f_app/src/PublishCommand.cj:338-343,388-395` | 目标 cjpm 版本的真实输出文案 | 手工执行三条命令并 `grep` 这三个字面量；不匹配则 `pub` 必进无限重试 |
| 4 | `spawn` 线程里未捕获的异常只由运行时默认处理器打印，主线程与退出码不受影响 | `f_app/src/App.cj:57-62` | 运行时对仓颉线程未捕获异常的处理策略 | 让某个 `Initializer.start()` 直接抛异常，观察 stderr 与 `fboot run` 退出码 |
| 5 | `sleep(Duration.Max)`（≈292 年）在目标平台能真正长期挂起，不会因 timespec 转换提前返回 | `f_app/src/App.cj:63-65` | 目标平台 `nanosleep` 对超大时长的处理 | 启动后观察 24h 的 CPU 与线程状态，确认无自旋唤醒 |
| 6 | `versionRegex` 重复编译在冷启动里占比可忽略 | `f_app/src/App.cj:25-29` | 自耗时占比 | `cjprof record` 跑 `fboot module x` 100 次，看 `Regex` 构造占比 |

## 文件覆盖

| # | 文件 | 类型 | 已读 | 说明 |
| --- | --- | --- | --- | --- |
| 1 | `f_app/README.md` | .md | ✅ | 结构完整、覆盖全部 public 符号；`extractPattern` 描述 / 版本号 / 依赖表 / `count` 开关过期，见 #19 |
| 2 | `f_app/README_en.md` | .md | ✅ | 与中文版逐段对齐（280 行对 275 行），同 #19 |
| 3 | `f_app/src/App.cj` | .cj | ✅ | 643 行、11 个子命令分发 + git/cjpm 编排；`restart` PID→路径（#1）、`test` 覆盖配置（#5）、忙等（#6）、正则（#7）、`spawn`（#15）、死代码（#18）均在此 |
| 4 | `f_app/src/BootException.cj` | .cj | ✅ | 22 行，版权头在 `package` 前（2025 与创建年一致）；`public class` 对外可达，构造参数已用，无问题 |
| 5 | `f_app/src/Initializer.cj` | .cj | ✅ | 初始化拓扑排序（#2 死循环）、`unsafeZeroValue` 置零（#14）；`start()` 默认空实现有注释说明，属有意 no-op，不判空实现 |
| 6 | `f_app/src/PublishCommand.cj` | .cj | ✅ | 420 行；模块发现（#9）、缺 `.modules`（#10）、环与重试（#11）、`TrustAll`（#12）、死分支与死函数（#18）、重复实现（#20）、路径/键（#21） |
| 7 | `f_app/src/RandHex.cj` | .cj | ✅ | 41 行；`static init` 注册 + `args[0]` 未校验（#16）；版权头 2026 与创建年一致 |
| 8 | `f_app/src/SubCommand.cj` | .cj | ✅ | 46 行；分发骨架与错误消息命令表（#3）、强制 `load(args,true)`（#4）；`SubCommandMediator.commands` 为 `private static let`，register/exec 均有调用者 |
| 9 | `f_app/src/constants.cj` | .cj | ✅ | 18 行，仅 `APP_STATIC_RESOURCE_SUFFIX`；被 `funcs.cj:59` 与 `App.cj:406` 使用，无问题 |
| 10 | `f_app/src/funcs.cj` | .cj | ✅ | 63 行；`confirmTargetPath` 建目录（#4）、库搜索路径死变量（#13）、`replace(ext,'')`（#21）；`load` 递归符合 `walk` 非递归语义 |
| 11 | `f_app/src/imports.cj` | .cj | ✅ | 37 行；`getCommand` / `InputStream` 未使用（#18），其余 import 均被引用 |

合计：`.cj` 9 个 / `.md` 2 个 / 共 11 个，全部读完。

## 覆盖自检

| 维度 | 命中 | 未命中时的说明 |
| --- | --- | --- |
| 正确性 / 设计 / 语言特性 / 可读性 / 安全性 | 21 | 21 条发现按主维度归类：正确性 16（#1、#2、#4–#11、#13–#17、#21）、设计 1（#3：命令表四处分头维护，`SubCommand` 反向承担内置命令清单）、语言特性 1（#18：`struct` 静态单例 + `unsafeZeroValue`、`String.replace` 全替换语义、未读形参 / 恒假分支）、可读性 2（#19 文档过期、#20 重复实现漂移）、安全性 1（#12 TLS）。 |
| §1 死代码 | 7 组 / 8 个符号 | 逐个 `private` 符号全仓搜过、`internal` 在本包及子包内搜过：`App.cj:66` 不可达 `0`；`App.cj:146/152` 恒假 `msg.isEmpty()`；`App.cj:32` `appHomeIsWorkingPath` 无读；`imports.cj:22/24` 两个未用 import；`PublishCommand.cj:35-37` `entireFile(String)` 无调用者；`PublishCommand.cj:340/345-348` `nodep` 恒空导致死分支；`App.cj:43-44` 形参 `args` 未读。其余 `private` 符号（`app` / `pid` / `directories` / `entireFileText` / `appendToml` / `doInit` / `extract` / `banner` / `appVersionModuleName` / `genCode` / `addModule` / `doBuild` / `copyToml` / `confirmBuildArgs` / `count` 两个重载 / `help` / `version` / `shutdown` 三个重载 / `restart` / `run` 两个重载 / `load` / `providerOf` / `doRegister` / `populateQueue` / `check` / `allModules` 两个重载 / `publishIncludes/Excludes/All` / `cjpm` / `checkPublished` / `checkLoop` / `replaceDependencies` 等）均有调用者。`public` 声明（`App` / `SubCommand` / `SubCommandMediator` / `Initializer` / `InitializerCollection` / `BootException` / `ModuleInfo` / `PublishCommand` / `RandHexCommand` 及其成员）对外可达，按硬原则一不判死代码。 |
| §2 重复逻辑 | 3 | #3（内置命令表四份：`boot` match / `help` 文本 / 错误消息 / README 表格，已漂移）；#7（版本号正则三处各写一遍，其中两处未转义）；#20（`replaceVersion` 两份实现，放行条件与替换粒度不同）。其余候选：`App.count` 与 `PublishCommand.lines` 都做"逐行读 + 过滤"，但前者统计、后者产出迭代器，语义不同，不合并；`funcs.load` 与 `App.count` 的目录递归形状相似但回调行为完全不同，不判重复。 |
| §3 空实现 | 1 | #17 的 `addModule` 找不到 `members` 时静默 no-op（无日志、无异常），属"开关打开后走进空分支"。其余：`Initializer.start(): Unit {}` 是接口默认实现且注释写明"是否阻塞取决于实现"，属有意的 Null Object，不判；`catch` 均有日志或重试语义（`App.cj:102-104` warn、`PublishCommand.cj:313-317` 打印堆栈后重试），无 `catch {}`。 |
| §4 栈溢出 | 0 | 3 处递归（`funcs.cj:45-57`、`App.cj:85-88`、`App.cj:500-509`；`allModules` 不递归）深度都等于目录层级，不来自报文 / 配置长度；每帧只持有 `Path` / `Regex` / 计数结构，无大对象。唯一的无界面是文件系统软链接环，缺"是否跟随软链"的证据，已列待验证假设 #1，不按缺陷计。 |
| §5 OOM | 0 | 全量物化的对象只有 `cjpm.toml` / `.modules` / `banner.txt`（KB 级，`PublishCommand.cj:38-44`、`App.cj:220-222`、`:371-383`）；`count` 用 `StringReader` 逐行读；无按不可信长度预分配、无全局只增容器（`SubCommandMediator.commands` 由 `static init` 定长注册，`moduleInfos` / `includes` 受模块数约束）；`load` 的 `providers` 随 initializer 数有界。 |
| §6.1 热点瓶颈 | 0 | 未提供本模块的 `cjprof` / `cjpm bench` 数据；模块内没有请求热路径，最"重"的循环是目录遍历与 `pub` 的日志输出，无法给出自耗时占比与输入规模，按规程只进待验证假设 #3 / #6 与 CPU 方案。 |
| §6.2 大粒度锁 | 0 | 只有 `InitializerCollection.doRegister` 的 `synchronized(mutex)`（`Initializer.cj:55-68`），临界区只做队列 `add` 与一次 map 复合操作，无 I/O / 解析 / 回调；`pub`、`App` 全程无锁。 |
| §6.3 并发串行 | 0 | 唯一的并发是 `App.cj:59-61` 为每个 initializer `spawn` 一个 `start()`（故意并行、结果不汇合，见 #15），无"spawn 后立刻 get"、无单消费者串行段、无批大小 1 的窗口。 |
| §6.4 低效算法 | 0 | 无双层循环匹配；`allModules` / `extractCjpm` 是单趟遍历 + HashMap 查找；`count` 每行做一次 `String.contains` 与 `trimAscii`，O(字符数)；`replaceDependencies` 每个模块编译一次正则（模块数级），未构成 O(n²)。唯一可降的是重复编译，已进 CPU 方案。 |
| §7 降堆内存方案 | 0 | 常驻堆只有 CLI 参数、路径、`providers` 与几个 KB 级字符串，生命周期等于进程；没有缓存可淘汰、没有副本可去（`PublishCommand.lines` 的全量读入已是文件本身大小）；收益低于可测噪声，故不列方案。 |
| §8 降 CPU 方案 | 2 | 见「优化可行性方案」：`versionRegex` 重复编译、`pub` 日志放大。两条均 `无基线（待验证）`。 |
| §9 local mode 可行性 | 0 | 无函数内大临时对象：`count` 逐行、`load` 逐个 `PackageInfo.load`、`extractCjpm` 单个 map；峰值内存由配置文件与子进程输出决定，不属于 local region 能改变的量级，且 CLI 进程生存期极短，收益无法用峰值内存证明。 |
| §11 现有代码的 BUG（存量） | 21 | 本轮读到的 21 条全部为存量（快照模式无基线）：`confirmTargetPath` / `load` / `count` / `extract` / `addModule` / `shutdown` / `version` / `test` / `restart` / `boot` / `start` 的边界与空值路径已逐个核对，`Option` 均被处理（`let Some(...) <-` 或 `?.`），无静默丢弃的 `Result`。 |
| §12 并发安全与锁粒度 | 2 | 共享路径：① `InitializerCollection.instance`（`static var`）在 `doInit` 被整体置零，与 `register` 的写入之间无同步（#14）；② `spawn` 的 `Future` 被丢弃，异常与完成状态不可见（#15）。锁粒度维度：唯一锁是 `register` 的 `Mutex`，临界区已最小，不建议改动；`SubCommandMediator.commands` 用 `ConcurrentHashMap` 且只有单值读写，无需额外锁。 |
| §13 文档与代码一致性 | 2 | #19（README `extractPattern` 描述、版本号、依赖表、`count` 开关、`help` 差异）、#20（`check()` 文案与两版 `replaceVersion` 的语义漂移在文档里没有体现）。其余段落核对一致：`README.md:48` 的分发规则与 `boot` 相符；`:72-84` 的 11 个命令行为与实现相符（除 `count` 参数列）；`:209-216` 的 `Initializer` 行为与 `Initializer.cj` 相符（但缺"依赖不满足会挂死"）；`:224-253` 的 `pub` 流程与实现相符（含"备份在改写之后"这一反直觉行为已被写明）。两版 README 无译漏或结论相反。 |
| §14 功能完备性与 README 覆盖 | 4 | 功能完备性：#13（`libPathName`/`delim` 算了不用 → 库搜索路径能力缺失；macOS 分支调用了文档标注"不支持 macOS"的 `PackageInfo.load`）、#17（`addModule` 静默跳过 → 版本/横幅能力静默缺失）、#4（`dynamic:false` 开关失效）。README 覆盖：11 个 public 类型 / 接口全部有文档（`App`、`SubCommand`、`SubCommandMediator`、`Initializer`、`InitializerCollection`、`BootException`、`ModuleInfo`、`PublishCommand`、`RandHexCommand`），无未文档化的 public 符号；缺口是 `count` 的两个新开关与 `help` 差异说明（#19）。根 `README.md` 模块表已登记 `f_app`。 |
| 文件覆盖 | 11/11 | 按 `files/f_app.txt` 逐行读完 9 个 `.cj` + 2 个 `.md`，无遗漏、无跳过。 |

## 模块统计

| 严重程度 | 数量 |
| --- | --- |
| 严重 | 2 |
| 一般 | 15 |
| 轻微 | 4 |
| 优化方案（堆内存 / CPU） | 0 / 2 |

存量缺陷 21 条（2 严重 + 15 一般 + 4 轻微），是否纳入修复待用户决定；待验证假设 6 条不计入统计，也不进 `todo.md` / `tasks.md`。

## 总评

`f_app` 是 fboot 的"命令总线"：11 个内置子命令 + 动态库加载 + 初始化编排 + 发布工具，全部挤在 `App` 一个 struct（643 行、约 30 个私有方法）与 `PublishCommand`（420 行）里。代码风格统一、版权头规范、`Option` 处理基本到位（`let Some(x) <-` 而非 `getOrThrow`），也没有锁竞争或内存增长问题——但它承担的是"进程生命周期"这类最难排查的职责，而现在的错误处理普遍是"抛一个未捕获异常"或"静默卡住"，这是本模块风险的主要来源。

两条建议优先处理：

1. **`restart`（#1，严重）**：PID 被当成目录路径，结果是"杀掉旧进程 → 建个空目录 → 打印 started → 永久阻塞"。这是唯一"打印了启动成功、实际什么也没启动"的缺陷（#2 是另一种形态：卡在初始化、连横幅都打不出来），改动很小（restart 不要把 PID 传给 `run`），建议本轮就修。
2. **初始化死循环（#2，严重）**：依赖名对不上（库没被 `--dylibPattern` 匹配到就会发生）时启动挂死、无任何日志。加一次"无进展即失败"的检测即可，属于低改动高收益。

其余一般项可按两条线排期：**命令分发与副作用**（#3 命令表漂移、#4 兜底路径建目录+全量初始化、#5 `test` 覆盖配置、#16 参数校验）与**发布链路**（#9 只扫一层、#10 缺 `.modules` 崩、#11 环与无限重试、#12 `TrustAll`）。发布链路的问题多在"顺手发现"的位置，但每一条都会让 `fboot pub` 在真实项目上卡住或产生错误结果，且 `TrustAll` 属供应链安全，建议一并修。

死代码（#18）与 README 过期（#19）不影响运行，可随下次改动清理；其中 `run(args:)` 的未读形参建议在修 #1 时一起处理，否则很容易在改 `restart` 时踩到"传参不生效"的坑。性能方面没有可用数据，本模块也不在请求热路径上，两条 CPU 方案仅作下一轮补基线的候选。
