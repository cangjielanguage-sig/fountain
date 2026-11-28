# f_llm 模块审查报告（第 24/25 部分）

- **审查日期**：2026-11-28
- **模块路径**：`f_llm`（本部分 20 个源文件：`src/store/postgres/` 1 个实现 + 1 个集成测试、`src/tool/` 16 个实现 + 1 个测试）
- **基线**：工作区快照（`git rev-parse --short HEAD` = `f309f0b55`，`git diff --stat` 为空，仅 `docs/review/`、`reviews/` 未跟踪）⇒ 本部分全部问题来源记为 `存量`
- **审查重点**：客户端契约与配置、流式响应与错误处理、资源与超时、死代码、重复逻辑、并发安全（本部分无 LLM 客户端/流式代码，相关专项落在 `llm` 包，见「覆盖自检」）
- **报告版本**：v1（本部分只写分报告，模块合并版由主 Agent 产出）

## 发现

### [严重][存量] 文件工具沙箱可被路径穿越绕过（`genPath` 只挡字面量 `../` 前缀）

- **位置**：`f_llm/src/tool/AbstractFileFunction.cj:19-32`（判定在 `:20`，拼接在 `:31`）；实际受害点 `f_llm/src/tool/FileReadingFunction.cj:67`、`FileWritingFunction.cj:62`、`FileReplacingFunction.cj:67`
- **来源**：存量（快照模式无基线）
- **判据**：review-checklist §11（边界/安全校验不足）、§10 安全性（外部输入未校验）
- **证据**：静态确定 —— ①`Path.join` 官方文档明写「本方法仅进行字符串拼接，不处理 ".." 等路径遍历组件。如需安全验证，请先调用 `canonicalize` 并检查路径范围」（`stdlib/doc/libs/std/fs/fs_package_api/fs_package_structs.md:1628-1630`、`:1686-1688`）；②守卫只有 `path.startsWith('../')` 一处（`:20`），`./../x`、`a/../../x`、`..\\..\\x`（Windows 反斜杠）、裸 `..` 全部不命中；③非 Windows 分支把绝对路径 `path[1 ..]` 去掉首斜杠后直接 join（`:28-30`），`/../etc/passwd` → `../etc/passwd` 恰好落回穿越形态。
- **描述**：`readFile` / `writeFile` / `replaceFile` 的 `path` 完全由模型给出（`@JsonStringSchema` 参数），三个函数描述都向模型承诺「即使使用绝对路径也不会访问整个操作系统的文件系统」。实际 `genPath` 只做前缀字符串判断，模型给出 `./../../etc/passwd` 或 `logs/../../../home/u/.ssh/id_rsa` 即可读写沙箱外任意可读写文件；`writeFile` 的 `truncate` 模式还可直接清空任意文件。提示注入 + 该工具 = 任意文件读写。
- **建议**：改成先 `canonicalize`（或 `normalize`）再判前缀，并对不存在的目标取其父目录 `canonicalize`；仓库内已有同款正确写法可对齐：`f_llm/src/channel/EmailChannel.cj:233-245`（`canonicalize(Path(root))` + `actual == base || actual.startsWith('${base}/')`）。同时补 `..`、`..\\`、`./` 的显式拒绝与单测（含大小写/分隔符变体）。

### [严重][存量] `CommandFunction` 永远拿不到命令输出：`stdOut/stdErr` 用了 `Inherit`

- **位置**：`f_llm/src/tool/CommandFunction.cj:54-61`
- **来源**：存量（快照模式无基线）
- **判据**：review-checklist §11（契约与实现不符）、§3（承诺有行为、实现返回空）
- **证据**：静态确定 —— `executeWithOutput(..., stdOut: Inherit, stdErr: Inherit)`；std 文档 `stdlib/doc/libs/std/process/process_package_api/process_package_funcs.md:101-106` 说明 `stdOut` 是「重定向方式」，返回的第二个/第三个数组是「进程标准输出结果和进程错误结果」。`Inherit` 表示子进程直接复用父进程流，不经管道捕获，因此返回的 `stdout`/`stderr` 恒为空数组。
- **描述**：`call` 用 `String.unsafeUtf8(if(code == 0) stdout else stderr)` 取内容，两路都是空 → 回给模型的永远是「进程退出码：N / 输出内容：（空）」。命令输出只出现在服务进程的控制台，模型看不到，工具等于失效；`code != 0` 时同样看不到 stderr 原因，模型无法自纠（例如路径写错、权限不足）。
- **建议**：改为 `stdOut: Pipe, stdErr: Pipe`（默认值即是），或按行读 `SubProcess` 并同时 tee 到控制台；输出加 `llm_commandMaxBytes` 式上限后再截断（与 `getFetchMaxBytes()` 对齐），避免 `yes` 之类命令把内存打满。

### [严重][存量] `FileReplacngFunction` 先清空文件再编译正则 → 正则非法即丢文件内容

- **位置**：`f_llm/src/tool/FileReplacingFunction.cj:77-83`
- **来源**：存量（快照模式无基线）
- **判据**：review-checklist §11（资源/数据安全：失败路径不可回滚）
- **证据**：静态确定 —— 顺序为 `readToEnd`（`:78`）→ `seek(Begin(0))`（`:79`）→ `setLength(0)`（`:80`）→ `Regex(params.regex).replaceAll(...)`（`:81`）。`setLength` 文档明确「将当前文件截断为指定长度」并立即生效（`stdlib/doc/libs/std/fs/fs_package_api/fs_package_classes.md:1723`）；`Regex` 构造失败抛 `RegexException`（`stdlib/doc/libs/std/regex/regex_package_api/regex_package_classes.md:817-819`）。正则编译在截断之后，任何编译失败都发生在文件已被清空之后。
- **描述**：模型给一个不合法正则（`[`、`(?<`、非法转义等）时：文件被清成 0 字节 → 抛异常 → 原始内容不可恢复。`replaceAll` 之后若写入抛 `FSException`（磁盘满、权限变更）同样只剩空文件。工具描述只承诺「替换成功返回 OK，否则返回错误原因」，没有提示会毁文件。
- **建议**：把 `Regex(params.regex)` 提前到打开文件之前编译（失败即返回错误文本、不碰文件）；写回走「临时文件 + `rename`」原子替换，或至少先 `setLength` 前把原文备份到 `path + '.bak'`。另加一条单测：非法正则后文件内容不变。

### [严重][存量] `SsrfGuard` 可被尾点 / `?` `#` / IPv4 简写 / IPv4-mapped IPv6 绕过

- **位置**：`f_llm/src/tool/SsrfGuard.cj:51-72`（`hostOf`）、`:74-104`（`blocked`）
- **来源**：存量（快照模式无基线）
- **判据**：review-checklist §10 安全性、§11（边界校验不足）
- **证据**：静态确定 —— `hostOf` 只按 `://`、`/`、`@`、最后一个 `:` 截断，不处理 `?`、`#`、末尾点；`blocked` 只在 `host.split('.')` 恰好 4 段且前两段能 `tryParse` 成整数时才判内网（`:82-103`）。因此：
  - `http://127.0.0.1./x` → 5 段（末尾空段）→ 非 4 段 → 走 `digitsOnly` 判定（含 `.` 故为 false）→ **放行**，而 `127.0.0.1.` 是合法 FQDN，解析到回环；
  - `http://127.0.0.1?x=1` → `hostOf` 无 `?` 分支 → host=`127.0.0.1?x=1` → 1 段 → **放行**；
  - `http://127.1/x`（inet_aton 简写）→ 2 段 → **放行**；`http://[::ffff:127.0.0.1]/` → host=`::ffff:127.0.0.1`，既不等于 `::1` 也不以 `fc/fd/fe80` 开头 → **放行**。
- **描述**：`WebFetchFunction` 把模型给的 URL 直接交给 provider（`WebFetchFunction.cj:55` 先 `SsrfGuard.check`），上述四种写法都能通过校验后打到回环/内网，SSRF 防护在字面量层面就不成立（DNS rebinding 之外还有这一层）。注释里的「字面量级校验」预期是第二道防线，但现在连字面量级也没覆盖完整。
- **建议**：`hostOf` 先按 `#`、`?` 截断，去掉末尾单个 `.`；IPv4 用统一归一化（`inet_aton` 规则：1/2/3/4 段 + 十进制/八进制/十六进制）后判私有段；IPv6 用 `std.net` 解析后判 `isLoopback/isUnspecified/isUniqueLocal/isLinkLocal/isIPv4Mapped`，不要用字符串前缀；最终仍应在建连前用解析后的 IP 复检（代码注释已列为待补）。

### [一般][存量] `CommandFunction` 无超时且子进程继承 stdin：一条长命令可挂死整个工具循环

- **位置**：`f_llm/src/tool/CommandFunction.cj:52-56`
- **来源**：存量（快照模式无基线）
- **判据**：review-checklist §11（资源与错误处理）、§12.1（有界性）
- **证据**：静态确定 —— `executeWithOutput` 默认 `stdIn: Inherit`（`process_package_funcs.md:100`），本处未覆盖；函数是「创建并等待子进程运行完毕」（`process_package_funcs.md:88`），`FunctionCalling.call` 契约里没有超时/取消入口（`FunctionCalling.cj:60-76`）。
- **描述**：模型输出 `sleep 100000`、`cat`（等 stdin）、`ping -t`、`git commit`（等编辑器）等命令时，调用线程无限阻塞；同进程的 `ConsoleFunction` 也读 stdin，两者抢同一输入流，行为不可预测。整个 agent 流程没有取消路径（`LLMToolLoop` 只在自己 `catch` 里兜异常，兜不住「不返回」）。
- **建议**：用 `SubProcess` + `wait(Duration)`/`kill` 实现超时（例如 `llm_commandTimeoutMs`，默认 30s），超时后 kill 并把「已超时」文本回给模型；`stdIn: Pipe` 且立即关闭（或不继承），避免子进程读走交互输入。

### [一般][存量] `ConsoleFunction` 用 `readToEnd()` 当「读一行」，交互模式下永远不返回

- **位置**：`f_llm/src/tool/ConsoleFunction.cj:53-59`
- **来源**：存量（快照模式无基线）
- **判据**：review-checklist §11（语义与注释/描述不符）、§3（承诺的行为实际不可用）
- **证据**：静态确定 —— `reader.readToEnd()`（`:58`）。std 文档 `stdlib/doc/libs/std/env/env_package_api/env_package_classes.md:155-164` 明确「读取输入直到遇到文件结束符 EOF」，Linux 需 `Ctrl+D`、Windows 需 `Ctrl+Z`+回车；`:170` 还注明该接口是行缓冲、只保证「按回车后被读取」，不提供「读完一行即返回」。而工具先打印「> 请输入你的回复： 」（`:55`），语义是等一条回复。
- **描述**：用户在终端敲完一行回车后，工具不会返回，必须再按 `Ctrl+Z`（Windows）或两次 `Ctrl+D` 才结束；对不熟悉 EOF 的用户等于卡死，agent 也拿不到回复。另外 `?? ''` 把「无输入/EOF」静默当成空回复（`:58`），模型会认为用户回了空串。
- **建议**：改成逐行读（`ConsoleReader` 的 `readLine`/按 `\n` 切分，或 `readUntil('\n')`），并在无输入时返回明确的「用户未输入」文本而不是空串；若确实只支持 EOF 结束，就把描述改成「按 Ctrl+Z/Ctrl+D 结束输入」，别写「请输入你的回复」。

### [一般][存量] 文件读取无大小上限：`entire` 全量物化、`head` 用模型给的整数做 `ArrayList` 初始容量

- **位置**：`f_llm/src/tool/FileReadingFunction.cj:73`（entire）、`:101-115`（head，`ArrayList<String>(lines)` 在 `:103`）
- **来源**：存量（快照模式无基线）
- **判据**：review-checklist §5（一次性物化 / 按不可信长度预分配）
- **证据**：静态确定 —— `entire` 走 `String.unsafeUtf8(File.readFrom(path))`，一次把整文件读进 `Array<Byte>` 再复制成 `String`（约 2× 文件大小）；`head` 的 `lines` 来自 `Int64.parse(params.condition)`（`:102`，模型可控字符串），`ArrayList<String>(capacity)` 文档为「构造一个初始容量为指定大小」并「参数小于 0 抛 `IllegalArgumentException`」（`stdlib/doc/libs/std/collection/collection_package_api/collection_package_class.md:887-905`）。
- **描述**：①沙箱内放一个 500MB 日志，`readFile(mode=entire)` 峰值 ≈ 1GB 且无拒绝路径（`webFetch` 有 `llm_fetchMaxBytes`，文件工具没有对应键）；②`head` 传 `condition=10000000000`：先按 10^10 容量预分配（≈ 8×10^10 字节引用数组）直接 OOM；传 `condition=0` 或负数则在 `:103` 抛 `IllegalArgumentException`（负面路径没有兜底）；③`head` 在文件行数少于 `lines` 时把**全部**行留在 `ArrayList` 里，等于整个文件常驻。
- **建议**：加 `llm_fileReadMaxBytes`（默认与 `getFetchMaxBytes()` 同量级），`entire` 超限截断并标注；`head/tail/random` 的 `lines` 先夹到 `(0, 上限]` 再构造容器（或统一用 `LinkedList`，不预分配），并对 `lines <= 0` 返回错误文本。

### [一般][存量] `FunctionMediator` 扫描路径不校验工具名，`register` 路径校验 → 非法名可以进工具表

- **位置**：`f_llm/src/tool/FunctionMediator.cj:99-110`（扫描）、对照 `:56`（`register` 里 `ToolName.validate`）
- **来源**：存量（快照模式无基线）
- **判据**：review-checklist §2（同一规则两处实现不一致）、§11（契约不符）
- **证据**：静态确定 —— `register` 第一句是 `ToolName.validate(calling.name)`；`ensureLoaded` 的循环只查 `functions.contains` / `scanned.contains`（`:105`），全程没有 `ToolName.validate`，也没有长度检查。
- **描述**：一个第三方 `@Bean` 工具（或 MCP 之外自定义注册）名字含空格/中文/超过 64 字符时：显式 `register` 会在启动期明确报错，而 `@Bean` 扫描会静默放进表里；随后 `getDefinitions` 把它塞进请求，OpenAI 兼容接口直接 400，整轮请求失败且报错指向不到具体工具。两条注册路径对同一个约束给出不同行为。
- **建议**：`ensureLoaded` 在 `scanned[name] = ...` 之前调用同一个 `ToolName.validate(name)`；把「非法名」与「重名」都归到启动期失败（`ensureLoaded` 已经会把 `FunctionCallingException` 上抛）。

### [一般][存量] `ensureLoaded` 在全局 `mutex` 内构造/关闭所有工具 bean（临界区含 DI 与反射）

- **位置**：`f_llm/src/tool/FunctionMediator.cj:90-123`（`synchronized(mutex)` 从 `:94` 到 `:122`）
- **来源**：存量（快照模式无基线）
- **判据**：review-checklist §12.2（缩小临界区：I/O、解析、外部调用应移到锁外）
- **证据**：静态确定 —— 锁内做了：遍历 `BeanFactory`（`:99`）、`bm.bean` 构造每个工具实例（`:102`，内部会跑 `lookup<T>()` 依赖注入）、`calling.definition` 生成 JSON Schema（`:108`，反射 + 序列化）、`closeIfNeed` 关闭原型 bean（`:109`），最后才把结果写进 `functions`（`:118-120`）。锁只需要保护「`functions` 的写」与「`loaded` 的翻转」。
- **描述**：首次调用 `FunctionMediator.call/names/getDefinitions` 的所有线程都要在这把锁上排队，而临界区长度 ≈ 全部工具 bean 的构造 + schema 生成（任何 bean 的 `init` 里做配置读取、连接池初始化，都会被放大成全局停顿）。若某个 bean 的构造被阻塞（例如 init 里发起网络请求），整个工具表都不可用。构造期间还可能回调其他注册表（`FunctionDefinition.register` / `BeanFactory`），存在锁序倒置的隐患（具体是否成环取决于 `BeanFactory` 内部锁，本处无法证实）。
- **建议**：把「扫描 + 构造 + 生成定义」放到锁外的局部表（`scanned` 已经是局部的），只在最后 `synchronized(mutex){ merge; loaded.store(true) }`；重名检测在合并时做。这样首调用延迟不再串行化到所有线程，也避免持锁执行外部代码。

### [一般][存量] `ensureLoaded` 把「重名」与「bean 构造里的任何 `FunctionCallingException`」一起上抛 → 一个坏工具让整张表永久不可用

- **位置**：`f_llm/src/tool/FunctionMediator.cj:111-116`（对照承诺在 `:84-88`）
- **来源**：存量（快照模式无基线）
- **判据**：review-checklist §11（错误处理不对称）、§3（注释承诺的容错规则未兑现）
- **证据**：静态确定 —— 同一个 `try` 里既有重名检测（`:105-107`）也有 `bm.bean` 构造与 `definition` 生成（`:102`、`:108`），失败后只按异常**类型**分流：`catch(e: FunctionCallingException){ throw e }` 优先于 `catch(e: Exception){ warn + skip }`，无法区分「重名」和「bean 自己的异常」。可达路径：`@ToolCall` 宏把 `FunctionDefinition.register<...>(...)` 生成到 bean 的**字段初始化器**里（`f_llm/src/macros/ToolCall.cj:66-71`），`register` 在漏标 `@FunctionDefinition` 时抛 `FunctionCallingException`（`FunctionDefinition.cj:31`）——即抛在 `bm.bean` 构造过程中。
- **描述**：注释写「单个 bean 构造失败（缺依赖、配置不全）只跳过并记 `warn`，不能因为一个工具坏了就让整张工具表不可用」；实际只要有一个 `@Tool` 类漏标注解（或任何 bean 在构造/`definition` 阶段抛 `FunctionCallingException`），就会走 rethrow 分支，`loaded.store(true)` 永不执行、`functions` 保持空——此后**每次** `FunctionMediator.call/names/getDefinitions` 都会重新扫描并再次抛出，全部工具（含正常工具）彻底不可用，且失败信息只在第一次的堆栈里。
- **建议**：为「重名」引入专用异常（如 `DuplicateToolException`）或先做重名预检、检出时直接抛，构造失败一律 `warn + skip`；另外把这类错误从「首次调用时」提前到启动期自检（`ensureLoaded` 可显式暴露一个 `ready()` 供 `fboot` 启动检查调用）。

### [一般][存量] `LLMToolLoop.run` 直接改写入参 `params.messages`，异常中途退出留下半轮消息

- **位置**：`f_llm/src/tool/LLMToolLoop.cj:47-58`（`params.messages.add` 在 `:54`、`:56`）
- **来源**：存量（快照模式无基线）
- **判据**：review-checklist §11（副作用与契约不符）、§12.1（异步/异常路径状态）
- **证据**：静态确定 —— `run` 无返回值之外的状态说明，注释只讲「默认关闭 + 硬上限」；`:54` 先追加 assistant 消息，`:56` 再逐条追加 tool 结果，两者之间 `invoke` 抛出的异常只会被 `invoke` 自己吞（`:98-102`），但 `LLM.chat`（`:49`）抛异常时 `params.messages` 已经多了上一轮的 assistant+tool 条目。
- **描述**：调用方把同一个 `LLMToolParams` 复用到下一次 `LLM.chat`（很常见的「多轮对话」写法）时，会看到上一轮的工具对话被重复追加；失败路径则可能只有 assistant 的 `tool_calls`、没有对应 `tool` 消息，下一次请求会被上游判为「tool 消息无对应调用」而 400。契约里没写「run 会修改入参」。
- **建议**：在 `run` 内部维护 `messages` 的副本（或本地 `ArrayList<ChatMessage>`，收尾再整体写回），失败时不落盘；文档注释补一句「会就地追加 assistant/tool 消息」。

### [一般][存量] `CurrentTimeFunction` 给 `australia/sydney` 固定 +10:00，但悉尼有夏令时

- **位置**：`f_llm/src/tool/CurrentTimeFunction.cj:109`（映射），承诺见 `:36-39`、`:31`
- **来源**：存量（快照模式无基线）
- **判据**：review-checklist §11（语义与注释不符）
- **证据**：静态确定 —— 类注释写「时区只支持**固定偏移**…不做夏令时推算」，参数说明写「Asia/Shanghai、Asia/Tokyo、Asia/Seoul 等**无夏令时**的常见时区」，但映射表把 `australia/sydney` 定为 `10 * 3600`。悉尼标准时 +10:00、夏令时 +11:00（每年 10 月至次年 4 月），属于有 DST 的时区。
- **描述**：南半球夏令时期间（约半年）用 `timezone=Australia/Sydney` 得到的时间比真实本地时间早 1 小时，且没有任何提示；正好踩中注释里「猜错时区比报不支持更糟」的反面。
- **建议**：删掉 `australia/sydney` 映射（落到「unsupported timezone」并让模型改用显式偏移），或明确支持 `+11:00`；同时把映射表与注释的「无 DST 白名单」做成同一份常量，避免再漂移。

### [一般][存量] PostgreSQL 集成测试：`catch(Exception)` 把任何失败变成 SKIP，断言又依赖常量向量与历史数据

- **位置**：`f_llm/src/store/postgres/PostgresMemoryRepository_test.cj:98-103`、`:174-177`（SKIP）、`:30-45` + `:257-268`（不稳定断言）
- **来源**：存量（快照模式无基线）
- **判据**：review-checklist §3（静默吞异常）、§11（测试与契约不符）
- **证据**：静态确定 —— ①`repository()` / `metaStore()` 的 `try` 块里包含建表 DDL、`ALTER TABLE`、`ORM.register`，任何一步失败都只 `println("SKIP ...")` 并返回 `None`，`@Expect` 一条都不执行，测试报告是绿的；DDL 本身有 bug（列类型、约束名写错）时同样表现为「跳过」。②`Fixed1024Embedder.embed` 忽略 `text`，恒返回同一向量（`:31-34`），`testDenseSearchReturnsAddedRecord` 却断言 `hits[0].record.id == record.id`（`:265`），而 `store.add` 不做清理（9001/9002/9003 跨运行累积），所有向量同分时的排序由 DB 决定 → 上一轮遗留的记录可能排第一。
- **描述**：这个文件既可能在「没有 PG」时假装通过，也可能在「有 PG」时随机失败；两种情况下它都不能作为「记忆库 SQL 正确」的证据。`metaStore` 的 `DELETE FROM llm_conf`（`:213`）还会清掉同库其他测试的数据。
- **建议**：区分「环境缺失」与「真实失败」——只对连接类异常（`SqlException`/连接超时）跳过，DDL/断言异常直接失败；每个用例用固定 id + `finally` 清理（或 `TRUNCATE` 各自表）；`embed` 用 `text` 的哈希派生不同向量，或断言改成「命中集合包含该 id」而不是「hits[0] 就是它」。

### [轻微][存量] 死代码：未使用的局部 `iterator` 与 3 处未使用 `import`

- **位置**：`f_llm/src/tool/FileReadingFunction.cj:153`；`f_llm/src/tool/CurrentTimeFunction.cj:18`、`:20`；`f_llm/src/tool/MemoriesLoadingFunction.cj:20`
- **来源**：存量（快照模式无基线）
- **判据**：review-checklist §1（无调用者/读了不用、未使用的 `import`）
- **证据**：静态确定 —— ①`let iterator = StringReader(f).lines()` 之后从未引用（`:155` 又重新 `StringReader(f).lines()`），等于多建一个 reader 对象即弃；②`CurrentTimeFunction` 全文无 `ArrayList`，`fountain::f_bean.*` 里的符号一个未用（`@Bean` 来自 `:21` 的 `f_bean.macros.*`）；③`MemoriesLoadingFunction` 只用 `MemorySummaryFinder`，`SkillReferenceParam` 未出现。已全仓 grep：这三个符号在对应文件内零引用。
- **描述**：`iterator` 是复制粘贴残留，还额外分配了一个 `StringReader`（同文件已有一个）；三处 `import` 是复制邻近文件带过来的，读代码时容易误判「这里有第二种读法」。
- **建议**：删 `:153` 那一行与三处 `import`。

### [轻微][存量] 重复逻辑：`localResult` 与 `call` 的「format 归一化 + match」逐行重复

- **位置**：`f_llm/src/tool/CurrentTimeFunction.cj:68-80` 与 `:85-97`
- **来源**：存量（快照模式无基线）
- **判据**：review-checklist §2（换控制流/跨函数复制：语义相同的三段分支）
- **证据**：静态确定 —— 两处都是「trim → 空则 `'iso'` → else `toAsciiLower`」再做 `match 'iso' / 'epoch' / _`，三支的错误文案字面量也完全一致（`:78` 与 `:95`）；唯一差异是 `'iso'` 分支调用 `isoAt(...)` 还是 `DateTime.now().toString()`。
- **描述**：错误文案与格式白名单要改两处，容易只改一处导致 `local` 与显式时区行为不一致（例如将来加 `'rfc3339'`）。
- **建议**：抽出 `render(format: String, params, isoText: () -> String)`，把「iso 的两种渲染」作为参数传入。

### [轻微][存量] 重复逻辑：epoch→日期换算（`floorDiv`/`pad2`/`civilFromEpoch`）在本模块有第二套实现

- **位置**：`f_llm/src/tool/CurrentTimeFunction.cj:152-188`；对照 `f_llm/src/balance/sign/Signers.cj:60-89`
- **来源**：存量（快照模式无基线）
- **判据**：review-checklist §2（换算复制 / 只改类型名）
- **证据**：静态确定 —— 两处都是 Howard Hinnant 的 days→civil：`z = days + 719468`、`era = z/146097`、`yoe = (doe - doe/1460 + doe/36524 - doe/146096)/365`、`mp = (5*doy+2)/153`、`month = mp<10 ? mp+3 : mp-9`、`year = month<=2 ? y+1 : y` 逐行一致；`floorDiv` 两处公式不同（`-((-v+d-1)/d)` vs `(a-b+1)/b`），`pad2` 与 `pad(value, width)` 也各写一份。全仓 grep 只有这两处（`f_email`/`f_jit` 的 `pad2` 属别的模块）。
- **描述**：同一算法两份公式不同的 `floorDiv` 是最容易出「一处修、一处漏」的形态（负数 epoch 边界、闰年边界）。
- **建议**：抽到模块内共用位置（`f_llm/src/util` 或 `f_time`），对外只暴露 `formatOffset(epochMillis, offsetSeconds)`；`floorDiv` 保留一份并配负数用例。

### [轻微][存量] 重复逻辑：`tail`/`head`/`random` 三个分支的「收集 → join」代码三次复制

- **位置**：`f_llm/src/tool/FileReadingFunction.cj:86-100`、`:104-114`、`:121-133`
- **来源**：存量（快照模式无基线）
- **判据**：review-checklist §2（只改容器类型/只改边界条件的复制）
- **证据**：静态确定 —— 三段都以 `let gen = StringGenerator(); for(l in list){ gen.appendln(l) }; return gen.toString()` 收尾，字符级一致；容器分别用 `LinkedList`/`ArrayList`/`LinkedList`，新增逻辑只有「保留前 N / 保留后 N / 蓄水池」一段。
- **描述**：`end` 分支的 join 是本文件最重复的代码；`head` 用 `ArrayList(lines)` 预分配（见 §5 那条），另两条用 `LinkedList`，同一语义三套写法。
- **建议**：抽 `joinLines(list: Iterable<String>): String` 与统一的 `BoundedLines(k, strategy)`。

### [轻微][存量] 两个技能工具的 `description` 完全相同，模型无法区分

- **位置**：`f_llm/src/tool/SkillLoadingFunction.cj:44-48` 与 `f_llm/src/tool/SkillReferenceLoadingFunction.cj:45-49`
- **来源**：存量（快照模式无基线）
- **判据**：review-checklist §2（字面量复制）+ §11（描述与实现不符）
- **证据**：静态确定 —— 两处都是 `'加载技能详细描述'`；但 `SkillReferenceLoadingFunction.call`（`:55-57`）用 `skillsFinder.loadSkillReferences(params.references)` 并返回 `ResultType.SkillReference`，加载的是「技能引用」而非「技能详细描述」，参数说明还写着「待加载的技能标题列表」（`:26`，实际是 `ArrayList<SkillReferenceParam>`）。
- **描述**：工具描述是模型选择工具的唯一依据；两个工具同名描述 = 选择随机。参数说明也把 `references` 说成标题列表，模型会传错结构。
- **建议**：`SkillReferenceLoadingFunction.description` 改为「加载技能引用（技能内的引用片段/文件）」，`references` 的 schema 描述按 `SkillReferenceParam` 实际字段重写。

### [轻微][存量] 命名：`FileReplacngFunction` 少一个 `i`，且已进 README 与 public API

- **位置**：`f_llm/src/tool/FileReplacingFunction.cj:36`（对照文件名 `FileReplacingFunction.cj`）
- **来源**：存量（快照模式无基线）
- **判据**：review-checklist §10（可维护性/命名）、§1（可见性建议另列）
- **证据**：静态确定 —— 类名 `FileReplacngFunction`，`README.md:221` / `README_en.md` 也照抄了这个拼写，说明它已是对外可见的类型名。
- **描述**：工具名 `replaceFile` 正常，但类型名拼写错误会被下游按名引用（`lookup<FileReplacngFunction>`、`import`），改名是破坏性变更。
- **建议**：保留旧名做 `@Deprecated` 别名（或加一行 `public type FileReplacingFunction = FileReplacngFunction` 之类的过渡），README 同步；本报告只作提示，不默认要求改。

### [轻微][存量] `SsrfGuard.blocked` 误杀以 `fc`/`fd`/`fe80` 开头的普通域名

- **位置**：`f_llm/src/tool/SsrfGuard.cj:79`
- **来源**：存量（快照模式无基线）
- **判据**：review-checklist §11（边界校验过宽）
- **证据**：静态确定 —— `host == '::1' || host == '::' || host.startsWith('fc') || host.startsWith('fd') || host.startsWith('fe80')` 对「任何主机名」生效，而 ULA/链路本地只对 IPv6 **字面量**成立。
- **描述**：`fc2.com`、`fd.io`、`fe80.example.com` 这类合法公网域名会被判为「private or local address」直接拒绝，`webFetch` 对它们永久不可用。
- **建议**：先判 `host.contains(':')`（IPv6 字面量）再套前缀规则，或按 `std.net` 的地址解析结果判断。

### [轻微][存量] 可读性：`var` 未重赋值、冗余中间变量

- **位置**：`f_llm/src/tool/FileWritingFunction.cj:62`；`f_llm/src/tool/FileReplacingFunction.cj:67`、`:76`；`f_llm/src/tool/CurrentTimeFunction.cj:177`
- **来源**：存量（快照模式无基线）
- **判据**：review-checklist §10（可读性/语言特性）
- **证据**：静态确定 —— `var path = genPath(...)`（两处）之后从未重新赋值；`let p = path` 只为绕开后续使用；`var z = days + 719468` 在 `:178` 只读。
- **描述**：`var` 暗示会变，实际不变，读者需要多确认一次；`let p = path` 属噪音。
- **建议**：改 `let`，删掉 `p`。

### [轻微][存量][待确认] `LLMToolLoop.assistantEcho` 只回填第一条 `ToolCallMessage`，而 `toolCallsOf` 收集所有消息里的调用

- **位置**：`f_llm/src/tool/LLMToolLoop.cj:54-57` 与 `:64-83`
- **来源**：存量（快照模式无基线）
- **判据**：review-checklist §11（配对不完整）
- **证据**：待确认 —— `toolCallsOf` 遍历 `response.messages` 收集**全部** `ToolCallMessage` 的 `tool_calls`（`:66-72`），`assistantEcho` 只 `return` 第一条（`:78-80`）。若一次响应里出现多条工具调用消息（多 choice / 流式合并成多条），就会执行全部调用但只回填一条 assistant 消息。
- **描述**：上游若只返回一条 `ToolCallMessage`（当前 OpenAI 兼容实现的常态），行为正确；多消息时下一轮请求里会出现「tool 消息找不到对应 tool_calls」而 400。缺的是「provider 是否可能返回多条 `ToolCallMessage`」的实际证据（需要抓一次真实响应）。
- **建议**：改成 `assistantEcho` 返回全部 `ToolCallMessage`（`ArrayList<ChatMessage>`），与 `toolCallsOf` 一一配对；或断言「只允许一条」并在多消息时显式报错。

### [轻微][存量] 测试隔离：`LLMToolLoop_test` 改掉全局 transport 不还原，计数器非原子

- **位置**：`f_llm/src/tool/LLMToolLoop_test.cj:51-60`、`:84`、`:96`、`:111`
- **来源**：存量（快照模式无基线）
- **判据**：review-checklist §12.1（全局可变状态）、§1（测试卫生）
- **证据**：静态确定 —— `LLM.setTransport(transport)` 是进程级全局状态的覆盖，三个用例都设不还原；`LoopTransport.calls` 是普通 `var`，`post` 里 `calls++` 无同步（测试若并行执行会读错次数）。
- **描述**：同模块其他用例（走真实/桩 transport 的）若与这些用例同进程串行执行，会受最后一个 `transport` 影响，失败信息指向错误的位置。
- **建议**：`@BeforeEach`/`@AfterEach` 保存并还原 transport；`calls` 用 `AtomicInt64`。

## 优化可行性方案

### [堆内存] `readFile` 的 tail/head/random 结果被拼两遍

- **现状**：`read(path, predicate)` 里，predicate 在 `end=true` 时先把命中的 N 行 join 成一个 `String`（`FileReadingFunction.cj:93-97`、`:108-112`、`:128-132`），返回给 `append` 后又 `gen.appendln(l)` 再复制一遍（`:148-150`）。即峰值同时持有「N 行 + 拼接串 + 第二次拼接串」，约为结果的 2–3 倍；`entire` 模式本身还要 `Array<Byte>` + `String` 两份（`:73`）。
- **方案**：把 predicate 协议从 `(String, Bool) -> String` 改成「收集器」形式（`end` 时直接把选中行写入目标 `StringGenerator`，不再返回中间串），`entire` 改为读流 + 预分配 `size` 的一次性 `String` 构造。
- **预期**：`readFile(mode=head/tail/random, N 行)` 峰值从约 2–3× 结果降到约 1×；`entire` 从 2× 文件大小降到 1×。具体降幅需按文件大小实测。
- **代价**：`read` 的签名与三个分支都要改；无行为变化（输出行序与内容不变），需补「空文件 / 末行无换行 / CRLF」用例。
- **验证**：`getAllocatedHeapSize()` 与 RSS 在 100MB 文件下 `head 1000` / `entire` 的峰值对照，同 SDK、`-O2`、各 10 轮取中位数。
- **证据状态**：`无基线（待验证，不进 tasks）`

### [CPU] 文件工具每次调用都重算沙箱路径（`exists` + 可能建目录）

- **现状**：`AbstractFileFunction.cj:31` 每次 `genPath` 都调 `LLMConfig.getFileSandboxPath()`，后者（`f_llm/src/config/LLMConfig.cj:205-221`）每次都 `Config.getString` + `exists(path)`，目录不存在时还 `Directory.create(recursive: true)`。属可缓存的启动期工作。
- **方案**：`LLMConfig` 内按配置值缓存 `Path`（配置热更新时失效），或由 `FunctionMediator` 在注册阶段解析一次。
- **预期**：每次文件工具调用省 1–2 次 `stat`（可能加一次 `mkdir`）；调用频率决定端到端收益，未测。
- **代价**：需要配置变更时的失效路径（`Config` 是否有 watch 机制需确认）；改动在 `config` 包，不在本部分文件内。
- **验证**：`cjprof record` 跑文件工具压测（1k 次调用），看 `exists`/`Directory.create` 的自耗时占比。
- **证据状态**：`无基线（待验证，不进 tasks）`；该条已由本模块 part8 的待验证假设 #6 记录，此处只作本部分文件（`AbstractFileFunction.cj:31`）的调用点补充，不重复计数。

## 待验证假设

| # | 假设 | 位置 | 缺什么数据 | 怎么采 |
| --- | --- | --- | --- | --- |
| 1 | 首次 `FunctionMediator` 调用在 `mutex` 内构造全部工具 bean，N 个 bean 的构造 + schema 生成可能达数十毫秒到秒级，且并发首调用全部串行 | `f_llm/src/tool/FunctionMediator.cj:94-122` | 单个 bean 构造耗时、N、并发首调用排队时长 | 在 `:99` 前后打分段计时，跑「冷启动 + 8 线程同时 `FunctionMediator.call`」，记录 P50/P99 |
| 2 | `CommandFunction` 的子进程启动（`Inherit` 重定向下无输出捕获）在工具体感延迟中占比高，尤其短命令 | `f_llm/src/tool/CommandFunction.cj:54-56` | 单次 `executeWithOutput` 耗时分布、命令长度分布 | `cjprof` 跑 100 条真实命令；同时作为「命令输出恒空」那条改 `Pipe` 之前的基线 |
| 3 | `PostgresTokenUsageSaver.saveTokenUsage` 每次聊天都 `dao<PostgresTokenUsageDAO>('postgres')` 现取 DAO，属每请求固定开销 | `f_llm/src/store/postgres/TokenUsageSaver.cj:33-37` | `dao<>()` 单次耗时、每会话调用次数 | 在 `saveTokenUsage` 内计时，跑 10 分钟稳态负载取 P95；对照「构造期缓存 DAO 字段」的改后数据 |
| 4 | `readFile` 的 `read()` 每行 `String` + `StringGenerator` 分配是 GC 抖动来源 | `f_llm/src/tool/FileReadingFunction.cj:146-161` | 每轮分配量、GC 次数、单次调用 CPU 占比 | `cjprof heap` 跑 100MB / 100 万行文件，对比 `heat` 前后的 `getAllocatedHeapSize()` |
| 5 | local mode 用在 `read()` 的临时行串上可降峰值（对象不逃逸出 `read`） | `f_llm/src/tool/FileReadingFunction.cj:152-160` | 峰值内存与 local region 占用 | 按 `--experimental --enable-local-mode` 改前后各 10 轮，比 `getUsedHeapSize()` 峰值与 `getAllocatedLocalObjectSize()`；注意 `String` 需 local 构造重载 |

## 文件覆盖

| # | 文件 | 类型 | 已读 | 说明 |
| --- | --- | --- | --- | --- |
| 1 | `f_llm/src/store/postgres/PostgresMemoryRepository_test.cj` | .cj（测试） | ✅ | 见「一般 · PostgreSQL 集成测试」 |
| 2 | `f_llm/src/store/postgres/TokenUsageSaver.cj` | .cj | ✅ | 单条 DAO 写入，无错误处理；DAO 取值频次见待验证假设 #3；`@BeanMeta` 条件与 `llm_memoryStore` 对齐，与 `MySqlTokenUsageSaver` 同约定，不判缺陷 |
| 3 | `f_llm/src/tool/AbstractFileFunction.cj` | .cj | ✅ | 见「严重 · 沙箱穿越」；`protected genPath` 属 `public abstract` 非 sealed 类，按硬原则一不判死代码 |
| 4 | `f_llm/src/tool/AnswerFunction.cj` | .cj | ✅ | 参数/结果一对一透传，未发现问题 |
| 5 | `f_llm/src/tool/CommandFunction.cj` | .cj | ✅ | 见「严重 · 输出恒空」「一般 · 无超时」 |
| 6 | `f_llm/src/tool/ConsoleFunction.cj` | .cj | ✅ | 见「一般 · readToEnd 等 EOF」 |
| 7 | `f_llm/src/tool/CurrentTimeFunction.cj` | .cj | ✅ | 见 Sydney DST、重复逻辑、死代码、`var` 未重赋值 |
| 8 | `f_llm/src/tool/FileReadingFunction.cj` | .cj | ✅ | 见 OOM、死代码、三段 join 重复、异常契约 |
| 9 | `f_llm/src/tool/FileReplacingFunction.cj` | .cj | ✅ | 见「严重 · 先截断后编译正则」、命名、可读性 |
| 10 | `f_llm/src/tool/FileWritingFunction.cj` | .cj | ✅ | 无写入错误兜底（异常经 `LLMToolLoop` 转文本）；`var path` 见可读性条 |
| 11 | `f_llm/src/tool/FunctionCalling.cj` | .cj | ✅ | 默认 `call(T)` 抛 `FunctionCallingException` 是显式守卫而非静默空实现，未计入 §3；`definition` 每次重建 `JsonObject`（性能面已由 part18 记录） |
| 12 | `f_llm/src/tool/FunctionDefinition.cj` | .cj | ✅ | 反射取注解失败即抛，注册走 `BeanFactory`，未发现问题 |
| 13 | `f_llm/src/tool/FunctionMediator.cj` | .cj | ✅ | 见「一般 · 名称未校验」「一般 · 锁内构造」「一般 · catch 过宽」 |
| 14 | `f_llm/src/tool/FunctionResult.cj` | .cj | ✅ | 3 参 `init` 固定 `ResultType.Text`、`result` 默认 `String` 而主构造默认 `''`，属便利构造，不判缺陷 |
| 15 | `f_llm/src/tool/LLMToolLoop.cj` | .cj | ✅ | 见「一般 · 改写入参」、`assistantEcho` 配对 |
| 16 | `f_llm/src/tool/LLMToolLoop_test.cj` | .cj（测试） | ✅ | 见「轻微 · 测试隔离」；`LoopEcho*` 等仅测试使用的 internal 符号属可见性建议，不判死代码 |
| 17 | `f_llm/src/tool/MemoriesLoadingFunction.cj` | .cj | ✅ | 未使用 `import SkillReferenceParam`（死代码条）；`lookup` 失败会让该工具被 `ensureLoaded` 跳过，属既定容错 |
| 18 | `f_llm/src/tool/SkillLoadingFunction.cj` | .cj | ✅ | 与 SkillReference 版描述相同（重复逻辑条） |
| 19 | `f_llm/src/tool/SkillReferenceLoadingFunction.cj` | .cj | ✅ | 同上；参数 schema 说明与 `references` 类型不符 |
| 20 | `f_llm/src/tool/SsrfGuard.cj` | .cj | ✅ | 见「严重 · SSRF 绕过」「轻微 · 误杀域名」 |

合计：`.cj` 20 个（含 2 个 `*_test.cj`）/ `.md` 0 个 / 共 20 个，全部读完。

**范围外提示**（不计入本部分统计）：`README.md:217` 写「内置工具（`ToolName` 里有常量）」，但 `f_llm/src/tool/ToolName.cj` 只有 `MAX_LENGTH`/`validate`/`mcp`/`sanitize`，没有任何工具名常量 —— 文档与实现不符，留给负责 README 的部分处置。

## 覆盖自检

| 维度 | 命中 | 未命中时的说明 |
| --- | --- | --- |
| 正确性 / 设计 / 语言特性 / 可读性 / 安全性 | 23 | 全部进「发现」（严重 4 / 一般 9 / 轻微 10）。按性质分：安全 3 条、契约与错误处理 5 条、资源与边界 2 条、锁粒度 1 条、语义与注释不符 1 条、重复逻辑 4 条、死代码 1 条、命名与可读性 2 条、边界过宽 1 条、测试 2 条、待确认 1 条 |
| §1 死代码 | 1（4 处） | 已逐个 private / internal / protected 符号搜引用：`FunctionMediator` 的 `getMeta`/`ensureLoaded`/`callee`/`closeIfNeed`/`log`/`mutex`/`functions`/`loaded` 均有用；`LLMToolLoop` 的 `toolCallsOf`/`assistantEcho`/`toolResult`/`invoke` 均有调用；`FileReadingFunction.read`、`CurrentTimeFunction.localResult` 有调用；`offsetOf`/`parseOffset`/`isoAt`/`floorDiv`/`pad2`/`civilFromEpoch`（internal）在本文件内全部有引用；`genPath` 属 `public abstract` 非 sealed 类的 `protected`，按硬原则一不判。命中项为 1 个未使用的局部 `iterator` + 3 处未使用 `import` |
| §2 重复逻辑 | 4 | 已把本部分 20 个文件的函数体压成「输入→输出→副作用」两两比对，并按同义错误文案/字面量跨文件搜（`'加载技能详细描述'`、`719468`、`floorDiv`、`getFileSandboxPath`）。命中的 4 条见「轻微 · 重复逻辑」×3 与技能工具描述；`Answer/Command/Console/Memory/Skill` 五个工具的 `name`/`description` 属性属必要样板，不判重复 |
| §3 空实现 | 0 | 无空函数体、无 `TODO`/`FIXME`、无 `catch {}`；`FunctionCalling.call(T)` 默认抛 `FunctionCallingException("default implementation")` 是有注释的显式守卫（`FunctionCalling.cj:60-68`），不属「静默空实现」；`LLMToolLoop.invoke` 的 `catch` 会返回 `'[工具调用失败] …'` 文本，非静默吞 |
| §4 栈溢出 | 0 | 全部分文件无自递归/间接递归：`civilFromEpoch` 是直线算术，`read()` 是单层迭代 + 闭包回调，`ensureLoaded` 是单层 for，`hostOf` 是 4 段顺序处理 |
| §5 OOM | 1 | 「一般 · 文件读取无大小上限」（`entire` 2× 文件大小、`head` 按模型整数预分配、`head` 全量驻留）；`CommandFunction` 无 `Pipe` 故当前不存在输出堆积（改 Pipe 后需同时加上限，已写进该条建议） |
| §6.1 热点瓶颈 | 0 | 本部分无任何 profile / bench 数据，未把「锁内构造」「每行分配」写成热点，全部降级为「待验证假设」#1–#5 |
| §6.2 大粒度锁 | 0 | `FunctionMediator.mutex` 的临界区确实偏大，但没有竞争测量数据，不按性能缺陷计；设计面按 §12.2 记入「一般 · ensureLoaded 锁内构造」 |
| §6.3 并发串行 | 0 | 本部分无 `spawn`/`Future`/线程池；`LLMToolLoop` 的「模型要工具 → 本地执行」是协议要求的串行，不属并发串行热点 |
| §6.4 低效算法 | 0 | `hostOf` 的 `indexOf`/`split`、`offsetOf` 的 `match` 都是常数级；`read` 是单趟线性；无「循环内 `contains`/`remove(at:0)`/字符串拼接」形态（`StringGenerator` 已避免 O(n²)） |
| §7 降堆内存方案 | 1 | 「[堆内存] readFile 结果拼两遍」，无基线 |
| §8 降 CPU 方案 | 1 | 「[CPU] 每次调用重算沙箱路径」，无基线且已在 part8 记录，不重复计数 |
| §9 local mode 可行性 | 0（记入假设 #5） | `read()` 的临时行串不逃逸，是唯一候选；但收益只能靠峰值内存对照证明，缺数据，故只列「待验证假设」 |
| §11 现有代码的 BUG（存量） | 23（全部） | 快照模式 `git diff` 为空，本部分 23 条全为存量；已逐条核对边界（空串/负数/0/超大数）、空集合取值、`Option` 与异常路径、文件句柄释放（`ResourceManager` 成对使用） |
| §12 并发安全与锁粒度 | 1 | 并发安全：`FunctionMediator` 的 `ConcurrentHashMap` + 双重检查 + `AtomicBool` 无检查-然后-写入缺口，`register` 的重名判断在锁内，未发现数据竞争；`ensureLoaded` 的锁粒度见「一般」那条。`ConsoleFunction`/`CommandFunction` 的 stdin 竞争已并入「命令无超时」条。测试类里的全局 `setTransport` 见「轻微」条 |
| §14 功能完备性与 README 覆盖 | 1 | 本部分无 `.md` 文件，未做 README 逐符号对照（留给 README 部分）；仅记录 1 条范围外提示（`ToolName` 无常量）。功能完备性方面：`command`/`console` 两个工具的实际行为与描述不符，已分别列为「严重」「一般」 |
| 文件覆盖（§13 等） | 20/20 | 无缺文件；本部分 20 个文件全是 `.cj`，无 `.md`，故 §13 文档一致性不适用 |

## 模块统计

| 严重程度 | 数量 |
| --- | --- |
| 严重 | 4 |
| 一般 | 9 |
| 轻微 | 10 |
| 优化方案（堆内存 / CPU） | 1 / 1（CPU 那条已在 part8 记录，不重复计数） |

## 总评

本部分（`src/tool/` 内置工具 + Postgres 用量落库 + 两个测试）的整体结构是清楚的：工具注册与调用有单一入口（`FunctionMediator`），原型 bean 会关闭，`definition`/`call` 分层干净，`SsrfGuard`、`ToolName`、`LLMToolLoop` 都带「为什么这样写」的注释，代码质量在「可读」这一档之上。

但**工具的实际行为与它给模型的承诺之间有系统性落差**，这是本部分的主要风险，建议按阻塞项处理：

1. 沙箱不成立（`genPath` 只挡 `../` 前缀，`Path.join` 不规范化）——模型可控路径即可读写沙箱外文件，`writeFile(truncate)` 还能清空任意文件。三个文件工具共用同一处，改一处即可，且仓库内已有正确写法（`EmailChannel` 的 `canonicalize` + 前缀比较）可对齐。
2. `command` 工具的输出永远是空的（`Inherit` 不捕获），且无超时、继承 stdin，长命令会把工具循环挂死。这两条让 `command` 目前处于「看起来能用、实际不可用或会卡住」的状态。
3. `replaceFile` 先 `setLength(0)` 再编译正则，非法正则直接毁文件——数据丢失不可逆，修法很小（把正则编译提前 + 临时文件原子替换）。
4. `SsrfGuard` 的四种字面量绕过（尾点、`?`、`127.1`、IPv4-mapped IPv6）让 SSRF 防护在最外层就失效。

其余为可排期项：读文件无大小上限与 `head` 按模型整数预分配（OOM 面）、工具名约束在两条注册路径上不一致、`ensureLoaded` 锁内构造全部 bean、`LLMToolLoop` 就地改写入参、`Australia/Sydney` 的 DST 错报、以及两处重复的 epoch→日期换算。性能方面本部分没有任何可复核的测量数据，5 条与锁/分配/DAO 取值相关的怀疑全部放在「待验证假设」，未计入缺陷，也未写成收益结论。

存量共 23 条（4 严重 / 9 一般 / 10 轻微），是否纳入本轮修复由用户在门禁决定；本报告只报不修。
