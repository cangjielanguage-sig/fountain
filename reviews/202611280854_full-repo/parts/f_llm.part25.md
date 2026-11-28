# f_llm 模块审查报告（第 25/25 部分）

- **审查日期**：2026-11-28
- **模块路径**：`f_llm`（本部分 15 个源文件：`src/tool/` 的 `TodoFunction` / `ToolName` / `WebFetchFunction` / `WebSearchFunction` / `WrappedFunctionCalling` + `imports.cj` + 2 个测试；`src/util/` 的 `Redactor` / `TextClip` / `http` + `imports.cj` + 2 个测试；`src/wiring/StoreWiring.cj`）
- **基线**：工作区快照（`git diff` 为空）⇒ 本部分全部问题来源记为 `存量`，`git blame` 只用于给出提交号
- **审查重点**：客户端契约与配置、流式响应与错误处理、资源与超时、死代码、重复逻辑、并发安全（本部分无流式/LLM 客户端代码，相关专项落在 `llm`、`store` 包，见「覆盖自检」；与 part24 的分工：part24 覆盖 `src/tool/` 其余 18 个文件，本部分覆盖剩 5 个实现 + 2 个 util）
- **报告版本**：v1（本部分只写分报告，模块合并版由主 Agent 产出）

## 发现

### [一般][存量] `Redactor.mask` 用字节下标切片：含多字节字符的凭据直接抛异常

- **位置**：`f_llm/src/util/Redactor.cj:31-36`（切片在 `:35`）
- **来源**：存量（`git blame` = `e928da3176`，2026-10-27）
- **判据**：review-checklist §11（边界/等值处理）、§10 安全性（脱敏失效即敏感数据外泄）
- **证据**：静态确定 —— `String` 的区间下标是**字节下标**，且要求落点必须在字符边界上：`stdlib/doc/libs/std/core/core_package_api/core_package_structs.md:9377-9403`（`operator func [](Range<Int64>)`：区间是「UTF-8 编码后的字节下标范围，起止点必须位于字符边界上」，否则抛 `IllegalArgumentException`；越界抛 `IndexOutOfBoundsException`）；`String.size` 是「UTF-8 编码后的字节长度」（同文件 `:6181-6187`）。因此 `secret[0 .. 4]` / `secret[secret.size - 4 ..]` 在首/尾 4 字节落在某个多字节字符内部时必然抛异常，而 `secret.size <= 8` 的短路也按字节判（3 个汉字 = 9 字节 → 走切片分支）。
- **描述**：`mask` 是对外 `public` 的脱敏原语，仓内被 `llm/CallLogger.cj:37`（`CallLog.summary`，同为 public）调用。只要 `LLMConf.auth` 里出现非 ASCII（自定义网关的 token、用户误填的中文、从 UI 复制带全角字符的口令）且首尾 4 字节不落在字符边界，日志行构造就会抛 `IllegalArgumentException`，把一次成功的调用变成失败；`redactJson`（`:55`）对同类值有相同问题。
- **建议**：先按 `runes()` 取前 4 / 后 4 个**字符**再拼（`text.runes().take(4)` / 反向取尾部），或用 `toRuneArray()` 切字符数组；保持「长度 ≤ 8 全掩码」按字符数判。补一条用例：`mask('密钥-abcdefgh')` 不抛且能掩码。

### [一般][存量] `redactJson` 的「不区分大小写」只归一了数据侧，没归一敏感键表

- **位置**：`f_llm/src/util/Redactor.cj:47-58`（判定在 `:53`，默认键表在 `:41`）
- **来源**：存量（`e928da3176`）
- **判据**：review-checklist §11（契约与实现不符）、§10 安全性
- **证据**：静态确定 —— 注释写「递归把敏感键（不区分大小写）的值换成掩码」，实现是 `keys.contains(key) || keys.contains(key.toAsciiLower())`：只把**数据键**转小写，`keys` 原样比较。`defaultKeys()` 里存的是 `apiKey` / `api_key` 这种原始大小写（`:41`），于是 `ApiKey` → `apikey` 不在集合里、`API_KEY` → `api_key` 命中、`APIKey` → `apikey` 不命中，行为随大小写跳跃。
- **描述**：同一份配置以 `{"ApiKey": "sk-..."}` 形式序列化（各平台 SDK 风格不一，OpenAI 兼容网关常用 `ApiKey`）时脱敏失效，密钥原文进入日志。现有用例只覆盖全小写 `auth` / `token`（`src/util/Redactor_test.cj:38-51`），覆盖不到这条路径。
- **建议**：把键表统一归一化后比较（`keys` 在建表时就 `toAsciiLower()`，或判定改为 `keys.any { k => k.toAsciiLower() == key.toAsciiLower() }`）；`defaultKeys` 只留小写形式。补 `ApiKey` / `API_KEY` 两条用例。

### [一般][存量] `addTodo` 的 `predecessor` 在 `TodoSaving → Todo` 转换中被静默丢弃

- **位置**：`f_llm/src/tool/TodoFunction.cj:77`（源字段 `:41`，目标字段 `f_llm/src/model/po/Todo.cj:36-37`）
- **来源**：存量（`4be871f2`）
- **判据**：review-checklist §11（错误处理缺失/静默）、§10 正确性
- **证据**：静态确定 —— ①源类型 `TodoSaving` 的字段名是 `predecessor`（`:40-41`），目标 `Todo` 的字段名是 `predecessors`（`Todo.cj:36-37`），映射按字段名匹配；②`f_data` 的默认转换旗标是 `SILENCE`（`f_data/src/base/global_objects.cj:42-51`：`IGNORE_FIELD_NOT_FOUND | IGNORE_FIELD_TYPE_NOT_MATCH | IGNORE_FIELD_NOT_CONVERTABLE`），`DataObject.set` 对未知名只在没有 `IGNORE_FIELD_NOT_FOUND` 时抛（`f_data/src/base/DataObject.cj:119-128`）。两者相加：`predecessor` 既不会报错，也不会落库。
- **描述**：模型按 schema 认真填的「前置待办 ID 列表」在保存时全部消失，`Todo.predecessors` 永远是默认空串；任务依赖关系静默丢失且无日志。叠加一层：`TodoSaving` 里没有 `id` 字段，`addTodo` 无法指定 ID，`predecessor` 引用的 ID 只能来自 `save` 分配，本就在语义上无法自洽（`src/finder/TodoFinder.cj:19-21` 的 `save` 无返回 ID）。
- **建议**：二选一——①把 `TodoSaving` 的字段改名为 `predecessors: String`（JSON 串）或用 `TodoSaving` 上的 `predecessor` 命名映射注解；②在 `addTodo` 里显式做一次手工映射（`todo.predecessor(param.predecessors)`），不依赖名字对齐。同时补 `addTodo` 用例断言 `list()` 能读回 predecessors。

### [一般][存量] `TodoFunction` 依赖的 `TodoFinder` 仓内没有实现：三个工具注册得上、每次调用必失败

- **位置**：`f_llm/src/tool/TodoFunction.cj:78`、`:87`、`:103`
- **来源**：存量（`4be871f2`）
- **判据**：review-checklist §14.1（接线缺失）、§11（契约与实现不符）；承诺源 `README.md:227`、`doc/f_llm.md:183`（内置工具表把 `TodoFunction` 列为可直接用的「todo 增删改查」）
- **证据**：静态确定 —— 全仓（排除 `.worktrees/`）搜 `TodoFinder` 只命中接口定义 `src/finder/TodoFinder.cj:18` 与这三处调用，无任何 `class ... <: TodoFinder`；`lookup<T>()` 找不到 bean 时抛 `BeanException('bean type ... does not exist')`（`f_bean/src/lookup.cj:26-30`）。`@ToolCall` 注册不触发 `lookup`，所以工具会正常进模型工具表。
- **描述**：宿主没实现 `TodoFinder` 时，`addTodo` / `todoList` / `updateStatus` 每次调用都抛 `BeanException`，被 `LLMToolLoop.invoke` 转成 `[工具调用失败] ...`（`src/tool/LLMToolLoop.cj:98-102`）回填给模型；模型会反复重试同一个坏工具，消耗轮次。README/doc 只说「todo 增删改查」，没有任何「需自行实现 `TodoFinder` bean」的前置条件说明（同类工具 `SkillLoadingFunction` 依赖的是 f_llm 自带 finder，读者无从分辨）。
- **建议**：①README 的内置工具表补一列「前置依赖」或在 `doc/f_llm.md` §3.2 注明 `TodoFunction` 需要宿主提供 `TodoFinder` 实现；②若这些工具本就不打算内置，考虑把 `@ToolCall` 从 `TodoFunction` 摘掉，交给使用者按需注册。

### [一般][存量] `todoList` 输出没有字节上限，`llm_toolResultMaxBytes` 实际只覆盖 `webSearch` 一个工具

- **位置**：`f_llm/src/tool/TodoFunction.cj:88-96`
- **来源**：存量（`4be871f2`）
- **判据**：review-checklist §5（无界容器/全量物化进上下文）、§14.1（接线缺失）
- **证据**：静态确定 —— `todoList` 把 `lookup<TodoFinder>().list(task)` 的全部条目逐条拼成 Markdown，无条数上限、无字节上限。`LLMConfig.getToolResultMaxBytes()`（默认 64KB，`src/config/LLMConfig.cj:185-190`）在整个 `f_llm` 只有一处引用（`WebSearchFunction.cj:68`）；`LLMToolLoop.invoke` 直接 `match(result.result)` 取字符串回填，没有兜底截断（`src/tool/LLMToolLoop.cj:103-107`）。
- **描述**：量化：单条待办渲染约 80-150 字节，一个 task 累积 1000 条即 80-150KB，超过工具预算 1-2 倍且直接进上下文，挤掉历史消息与技能提示；`list` 返回多少完全由库表决定，框架侧无拒绝路径。同一文档 `doc/f_llm.md:175` 又宣称「CommandFunction 输出截断到 `llm_toolResultMaxBytes`」，说明该配置被当作通用预算，实际只有 2 个工具各自手写。
- **建议**：在 `LLMToolLoop.invoke` 出口统一按 `getToolResultMaxBytes()` 截断（用 `TextClip` 加字节版），或在每个工具内显式调用；`todoList` 至少要按条数与字节双上限截断并标注 `[已截断]`。

### [一般][存量] `webFetch` 的 `llm_fetchMaxBytes` 只是渲染期事后截断：标题不受限、正文已整段物化

- **位置**：`f_llm/src/tool/WebFetchFunction.cj:64-74`（`budget` 在 `:67`）；同类包装开销未计入 `f_llm/src/tool/WebSearchFunction.cj:110-124`
- **来源**：存量（`98bc0c0e`）
- **判据**：review-checklist §5（预算/拒绝路径缺失）、§11（文档承诺与实现不符）；承诺源 `doc/f_llm.md:179`「抓取大小受 `llm_fetchMaxBytes` 限制」、`README.md` 同段落
- **证据**：静态确定 —— ①`head` 由完整 `page.title` 拼成，未截断：`title` 长度 > `maxBytes` 时 `budget = 0`，但输出仍是 `head + '' + '[已截断]'`，即全量标题（`WebFetchFunction.cj:66-73`）；②`'\n[已截断]'` 后缀（12 字节）与 `normalize` 的 `[` `]` + 后缀（合计 14 字节）都在预算之外（`WebSearchFunction.cj:119-124`）；③正文在被截断之前已整段读入内存：`search/DeepSeekSearchProvider.cj:36-49` 用 `readEntire()` 取整包 → `parseDeepSeekFetch` 原样放 `FetchedPage.content`（`:186-188`），`renderPage` 只是渲染期切片。
- **描述**：模型访问一个标题很长（或被恶意构造）的页面，`llm_fetchMaxBytes=256KB` 的限制对标题完全无效，模型上下文可被单次抓取撑爆；一个 100MB 的页面在 `readEntire` 阶段就已经占住 100MB 堆（`Accept-Encoding: identity` 还禁用了压缩，放大了字节量），事后截断救不了内存峰值。`webSearch` 的同类问题小两个数量级（固定多 14 字节），但同一根因：预算没有覆盖最终输出。
- **建议**：`renderPage` 先按 `maxBytes` 截标题（`# ${truncateBytes(title, maxBytes/4)}`），最后再对整串做一次 `truncateBytes(out, maxBytes)` 保证硬上限；`normalize` 把 `2 + 后缀长度` 预先算进预算。内存侧需要 provider 支持流式/`Content-Length` 预检，属跨包改动，建议单列。

### [一般][存量] `webSearch` 的 `count`（文档承诺 1~50）不校验就透传给上游计费接口

- **位置**：`f_llm/src/tool/WebSearchFunction.cj:35-36`（schema 描述）、`:67`（透传）
- **来源**：存量（`98bc0c0e`）
- **判据**：review-checklist §11（缺少边界校验）、§10 安全性（模型可控入参直送外部付费接口）
- **证据**：静态确定 —— 参数描述写「返回条数，1~50，默认 10」，`call` 直接把 `params.count` 交给 `provider.search(...)`；`f_llm/src/tool/` 与 `f_llm/src/search/` 全目录搜 `count` 无任何 clamp（`DeepSeekSearchProvider.cj:99-105` 只是 `body.add('count', count)`）。
- **描述**：`count` 由模型填写，`-1`、`100000` 都会照发。上游可能直接 400（一次工具调用失败）、也可能真返回超大结果集（流量与费用放大），而 `normalize` 只截断**输出**不减少上游返回量。参数范围只写在给模型看的描述里，等于没有约束。
- **建议**：在 `call` 入口 `let count = min(max(params.count, 1), 50)`（或配置化上限），并把实际使用的值写进日志/结果，避免模型以为生效。同类参数（`provider`）已有显式校验语义可参照。

### [一般][存量] `util.http` 硬编码 `TrustAll`：所有经此出口的请求都不校验证书

- **位置**：`f_llm/src/util/http.cj:25-27`
- **来源**：存量（`4be871f2`）
- **判据**：review-checklist §10 安全性（凭据暴露面）
- **证据**：静态确定 —— `tls.verifyMode = CertificateVerifyMode.TrustAll` 无条件生效，无配置开关；`f_llm` 内同类硬编码共 7 处（`util/http.cj:26`、`llm/LLMTransport.cj:47`、`llm/LLMStreamTransport.cj:49`、`search/DeepSeekSearchProvider.cj:44`、`store/hydra/HttpTransport.cj:203`、`embedding/BgeM3Transport.cj:91`、`balance/BalanceQueriers.cj:42`），`f_mvc` 已有可配置写法可对照（`f_mvc/src/MVCConfig.cj:91-92`：`trustall` / `strict` 由配置决定）。
- **描述**：`http()` 用于 `TokenCounter`（`llm/TokenCounter.cj:72`）与余额查询（`balance/BalanceQueriers.cj:77`），请求头里带 `Authorization: Bearer <真实密钥>`（`:20`）。关闭校验后，处于中间位置的攻击者可解密并复用这些密钥；同时也失去了「连错端点」的兜底（自签证书与伪造证书无法区分）。这看起来是「自建网关常自签」的务实取舍，但没有任何文档记录（`doc/known-limitations.md` 未提），也没有 opt-in 开关。
- **建议**：加 `llm_tlsVerifyMode`（默认 `strict`），只在显式配置为 `trustall` 时关闭；把 `util.http` 与其余 6 处一起收敛到一个 `TransportConfig` 工厂，避免新增出口再次漏配。这是模块级设计取舍，需用户拍板（若要保留 TrustAll 默认，至少在 `known-limitations` 记一条并说明风险）。

### [一般][存量] `ToolName.sanitize` 非单射：两个 MCP 工具名清洗后撞车会让整个 MCP 源注册中断

- **位置**：`f_llm/src/tool/ToolName.cj:50-55`（`mcp`）、`:57-71`（`sanitize`）
- **来源**：存量（`98bc0c0e`）
- **判据**：review-checklist §11（边界）、§14.1（接线失败无回滚）
- **证据**：静态确定 —— `sanitize` 把每个非法字符逐个替换为 `_`，因此 `mcp('fs','read file')` 与 `mcp('fs','read_file')`、`mcp('a.b','x')` 与 `mcp('a_b','x')` 得到同一个名字；`McpToolSource.load` 逐条 `FunctionMediator.register`（`src/mcp/McpToolSource.cj:65-73`），重名直接抛 `FunctionCallingException('function already registered: ...')`（`src/tool/FunctionMediator.cj:59-61`），且 `load` 没有 try/catch 与回滚。
- **描述**：MCP server 里同时存在 `read file` 与 `read_file`（或 alias 含 `.`/`-` 的变体）时：先注册的那个留下、后一个抛异常导致整个 `load()` 中断，其余工具全部没进来；调用方看到的是「function already registered: mcp__fs__read_file」，无法判断是哪两个原始工具撞的。`FunctionMediator` 的校验（part24 已报「扫描路径不校验工具名」）在这里也帮不上——名字是合法的，只是重复。
- **建议**：`mcp()` 在清洗后做一次**冲突检测**（同一 server 内维护 `原始名 → 清洗名` 表，撞车时对后者追加短 hash），或在 `McpToolSource.load` 里对单条 `register` 失败降级为 `warn` 并继续（与 `FunctionMediator.ensureLoaded` 的单条容错口径一致），保证一个坏工具不拖垮整源。

### [轻微][存量] `ToolName` 的合法字符白名单写了两遍

- **位置**：`f_llm/src/tool/ToolName.cj:39-47` 与 `:59-69`
- **来源**：存量（`98bc0c0e`）
- **判据**：review-checklist §2（字面量复制）
- **证据**：静态确定 —— `validate` 与 `sanitize` 各写一遍同样的 5 类合法字符判定（`a-z` / `A-Z` / `0-9` / `_` / `-`），错误消息里的「allowed: A-Z a-z 0-9 _ -」是第三份同源表述。
- **描述**：新增允许字符（例如 MCP 允许的 `.`）时极易只改一处，导致「校验通过但清洗把它替换掉」或反之——这类漂移会直接表现为工具名对不上。
- **建议**：抽 `private static func isLegal(rune: Rune): Bool`，`validate` 与 `sanitize` 共用，错误消息由同一常量生成。

### [轻微][存量] `src/util/imports.cj` 有 4 条在本包内用不到的 import

- **位置**：`f_llm/src/util/imports.cj:22-28`
- **来源**：存量（`4be871f2`）
- **判据**：review-checklist §1（未使用的 import）
- **证据**：静态确定 —— `f_llm.util` 包只有 `Redactor.cj`、`TextClip.cj`、`http.cj` 三个源文件，逐个 grep：`f_log`（`Logger`/`LoggerFactory`）、`f_util`、`f_llm.constant` 零命中；`f_data` 由 `Redactor.cj:20` 的文件级 import 自行满足，`imports.cj:23` 是同一条的重复。实际用到的是 `std.collection`、`stdx.net.tls(.common)`（`TlsClientConfig`/`CertificateVerifyMode`）与 `f_base`（`resource`）、`f_httpclient`（`HttpClient`）。
- **描述**：冗余 import 会让读者误以为该包依赖日志与全局配置（`internal import` 还扩大了包内符号可见面），也让「这个包依赖什么」难以从 import 块读出。
- **建议**：删掉 `f_log` / `f_util` / `f_llm.constant` / 重复的 `f_data` 四条；若确实是给后续文件预留，加一行注释说明。

### [轻微][存量] `StoreWiring.wire()` 在一把全局锁里做配置读取、bean 初始化和数据库补种

- **位置**：`f_llm/src/wiring/StoreWiring.cj:52-71`（`seedKinds` 在 `:77-97` 也在同一临界区内被调用）
- **来源**：存量（`58131ec4` / `30587071`）
- **判据**：review-checklist §6.2 / §12.2（锁内 I/O）
- **证据**：静态确定 —— 临界区包含 `StoreSettings.load()`（`:67`、`:82`）、`Stores.bootstrap()`（`:68`）、`MemoryKinds.seed/attach`（`:85-86`、`:89-90`，`attach` 会 `allCustom()` 查库，`store/MemoryKinds.cj:63-78`）。字段 `kindsSeeded` / `beanInitialized` 只在这把锁内读写，可见性没有问题。
- **描述**：启动期调用、单线程，竞争线程数实际为 1，因此当前不是性能问题；风险在结构上：①一旦有第二个线程在启动窗口内调用 `wire()`（多入口初始化、测试并行），就要等整段 DB 补种完成；②`wire()` 可重入性未被禁止——若 `Stores.bootstrap()`/`MemoryKinds.attach()` 内部再触发 `wire()`（例如未来在工厂里做 lazy wire），会自锁死；③`seedKinds` 失败后 `kindsSeeded` 保持 `false`，下次 `wire()` 会重放补种（`seed` 幂等、`attach` 会先 `clear()` 再重建，行为可接受但需明确）。
- **建议**：把锁外可做的部分移出（`StoreSettings.load()` 结果先取好），只用一个短临界区保护 `beanInitialized` / `kindsSeeded` 两个标志；补种放在锁外并加重入保护（`AtomicBool` CAS 单飞）。

### [轻微][存量] `StoreWiring` 类注释与实现不一致：写「三个内容族」，实际注册 5 个

- **位置**：`f_llm/src/wiring/StoreWiring.cj:44-48`（注释）vs `:60-67`（实现）
- **来源**：存量（`58131ec4`）
- **判据**：review-checklist §13（文档/注释与代码不一致）
- **证据**：静态确定 —— 注释写「补齐 `inMemory` / `postgres` / `mysql` 三个内容族工厂」，实现注册 5 个内容族（`inMemory`、`postgres`、`mysql`、`f_hydra`、`fhydra`）与 3 个 meta（`postgres`、`mysql`、`f_store`）。
- **描述**：注释是这段代码唯一的「注册了什么」说明；按注释排查「为什么 `fhydra` 能用」会走弯路。同时 `f_hydra` / `fhydra` 两个近义名字并列出现且都指向 Hydra 系实现（`HydraContentStore` / `FhydraContentStore`），没有一句说明区别。
- **建议**：注释改成「注册 5 个内容族 + 3 个 meta，逐条列出」，并给 `f_hydra` / `fhydra` 各补半句（历史别名 or 不同后端）。

### [轻微][存量] 三个测试文件里的注册/配置脚手架复制了 5 份，且用 `catch(_: Exception){}` 吞掉冲突

- **位置**：`f_llm/src/tool/ToolFunctions_test.cj:98-108`（两个 helper）、`:78-87`（`searchConf`）、`:89-96`（`textOf`）；`f_llm/src/tool/WebFetch_test.cj:56-71`（`fetchConf` + `registerFetchProvider`）、`:122-125`（内联的 result 取值）
- **来源**：存量（`4be871f2` / `98bc0c0e`）
- **判据**：review-checklist §2（跨文件重复）、§3（静默吞异常）、§12.1（共享状态）
- **证据**：静态确定 —— `registerQuietly` / `registerSearchQuietly` / `registerFetchProvider` 三段函数体都是 `try{ X.register(p) }catch(_: Exception){}`；`searchConf` / `fetchConf` 除 `conf.id`（9 / 12）外逐行相同；`textOf` 与 `WebFetch_test.cj:122-125` 的 `match(result.result)` 同语义。另外 `LLMCandidateProvider.setSupplier(...)`（`:191`、`:204`、`:117`、`:134`）改的是全局供给函数，用后不还原。
- **描述**：①吞异常让「重复注册失败」这条真实信号静默消失——`testDuplicateRegisterFails` 之所以要单独写一个 `try`，正是因为 helper 把异常吃掉了；②`setSupplier` 不还原 → 用例结果依赖执行顺序（单独跑 `testWebSearchWithoutConfThrows` 之外的用例可能读到别人的空供给），与 part24 已报的「测试隔离」是同类问题；③5 份脚手架任意一份改了（例如注册改成断言成功），其余四份不会同步。
- **建议**：抽一个包内 `TestScaffold`（`registerOrIgnore`、`confOf(id, provider)`、`textOf`），`setSupplier` 用 `try/finally` 还原；helper 至少把冲突打到 stderr 而不是完全吞掉。

### [轻微][存量] `redactJson` 递归无深度上限

- **位置**：`f_llm/src/util/Redactor.cj:48-71`（自递归在 `:59`、`:66`）
- **来源**：存量（`e928da3176`）
- **判据**：review-checklist §4（无界递归）
- **证据**：静态确定 —— 递归深度等于输入 JSON 的嵌套层数，没有任何深度计数或访问集合；`JsonValue` 的深度完全由报文决定。
- **描述**：当前 `redactJson` 在仓内只有测试调用（`src/util/Redactor_test.cj:45`、`:56`），不在生产路径上，所以按 `轻微` 记；一旦按注释承诺接到 debug 报文日志（`llm/CallLogger.cj:27`），模型返回或网页正文构造的深层嵌套 JSON 就是一条栈溢出路径（先爆栈，与 §4/§5 同源）。
- **建议**：接线时同时加 `depth` 参数（例如 32 层后原样返回或替换为 `'****'`），并按 `LLM_MAX_...` 风格配置。

### [轻微][存量] `todoList` 不渲染 `status` / `predecessor`，模型改完状态无法核对

- **位置**：`f_llm/src/tool/TodoFunction.cj:88-96`
- **来源**：存量（`4be871f2`）
- **判据**：review-checklist §14.1（只做了一半）、§3（契约完整性）
- **证据**：静态确定 —— 渲染模板只有 `ID` / `title` / `content`；`Todo` 的 `status` 与 `predecessor()` 均未输出，而 `updateStatus`（`:102-105`）只回 `success` 或 not found。
- **描述**：`TodoStatus` 有 6 个语义状态（`src/constant/TodoStatus.cj:28-33`），文档也在 `TodoFunction` 上列了状态图例（`:61-69`），但列表里看不到任何状态 → 模型无法判断「哪些还没做」、无法确认更新是否落到期望值，只能再盲改一次。
- **建议**：模板补 `status`（状态字符即可，如 `✅`）与 `predecessors`；同时把类注释里的状态图例挪到 `description` 或一次性的 tool 结果里，避免模型无从知晓状态取值。

### [轻微][存量] 文档称 `ToolName` 里有内置工具名常量（实际没有），且 `ToolName` / `normalize` 未进公开 API 清单

- **位置**：`f_llm/src/tool/ToolName.cj:27-30`（只有 `MAX_LENGTH`）；工具名仍是字面量：`WebFetchFunction.cj:44`、`WebSearchFunction.cj:54`；同类：`f_llm/src/tool/WebSearchFunction.cj:97`（`normalize`）
- **来源**：存量（`98bc0c0e`）
- **判据**：review-checklist §13（文档与实现不符）、§14.2（public API 未文档化）
- **证据**：静态确定 —— `README.md:217`「内置工具（`ToolName` 里有常量）」、`doc/f_llm.md:169`「`ToolName`：工具名常量，避免散落字符串」，而 `ToolName` 只声明了 `MAX_LENGTH` + `validate` / `mcp` / `sanitize`（`:28-71`）；`grep ToolName README.md` 全文件只命中第 217 行，说明 `public struct ToolName` 及其 3 个 public 成员在「其他公开 API」清单（`README.md:864`、`:1014` 附近的逐类型条目）里完全缺席。同一清单收了 `renderPage`（func）却漏了 `normalize`（func），两者同为 `fountain::f_llm.tool` 的顶层 public 函数。
- **描述**：①按文档去找「工具名常量」会扑空，读者由此以为改名有单一入口；实际上 `webFetch` 等名字散落在各 `FunctionCalling` 实现里，而 `ToolName` 只提供 64 字符 + 字符集规则——这条规则恰恰是 MCP alias 超长时启动失败的排查依据，却没被文档化。②`normalize` 是 public 顶层函数（工具结果归一化），下游可复用，但公开清单里没有。
- **建议**：把 `doc/f_llm.md:169` 与 `README.md:217` 的表述改成「工具名校验与 MCP 命名规则（64 字符上限 / 允许 `A-Za-z0-9_-`）」；在逐类型清单补 `ToolName`（`MAX_LENGTH`/`validate`/`mcp`）与模块级 `normalize`。若确实想要「名字常量」，就把 `'webFetch'` 等下沉成 `ToolName.WEB_FETCH`。

## 优化可行性方案

### [堆内存] `truncateBytes` 逐字符 `toString()` 生成临时 String

- **现状**：`f_llm/src/tool/WebFetchFunction.cj:76-94`。每次 `webFetch` 最多遍历 `limit` 字节；中文 3 字节/字时约 8.7 万次迭代（`maxBytes` 默认 256KB），每次 `let piece = rune.toString()` 新建一个 1-4 字节的临时 `String`，存活期仅一次迭代；`StringBuilder` 未预分配，最终串 256KB 时要经历多次扩容拷贝（旧串同时存活）。
- **方案**：`StringBuilder()` 改为带容量构造（`StringBuilder(min(text.size, limit))`，若该重载可用则用，否则先 `reserve`）；字节长度改为按 `rune` 的 UTF-8 宽度计算（`rune` → 1/2/3/4 字节的判定）而不建 String。
- **预期**：单次抓取减少约 `limit/3` 个短命对象与 1-2 次大块拷贝（数量级：十万级分配 → 个位数分配）；对 256KB 正文的峰值临时内存有可观下降。
- **代价**：手写 UTF-8 宽度判定，需与 `runes()` 语义严格对齐；`limit` 仍需保证不切断字符。
- **验证**：`cjpm bench -O2` 同输入（256KB 中文正文 × 200 次）对比中位数与 `getAllocatedHeapSize()`；`cjprof heap` 看 `String` 分配占比是否下降。
- **证据状态**：`无基线（待验证，不进 tasks）`

### [堆内存] `renderPage` 的 `head + content + '[已截断]'` 让同一份正文最多同时存活 3 份

- **现状**：`f_llm/src/tool/WebFetchFunction.cj:64-74`。`head`、`content`、拼接结果各是一份完整 `String`；截断生效时总长 ~`maxBytes`，最坏瞬时同时持有 `content`（≤256KB）+ `head + content`（≤256KB）+ 带后缀的最终串（≤256KB）。
- **方案**：用一个预分配的 `StringBuilder` 依次 append 标题、正文切片、后缀，只产生最终一份串；`[已截断]` 的判定用 `content.size < page.content.size` 提前算好。
- **预期**：单次 `webFetch` 峰值降低约 1-2 × `maxBytes`（默认即 256-512KB 量级），高并发抓取时按并发度线性放大收益。
- **代价**：无（纯拼装方式改动，输出完全等价）。
- **验证**：`getAllocatedHeapSize()` / RSS 对照，同 256KB 正文、并发 8，跑 10 分钟稳态看峰值是否回落。
- **证据状态**：`无基线（待验证，不进 tasks）`

### [CPU] `pickConf` 每次工具调用重建候选列表 + 逐条加锁查注册表

- **现状**：`f_llm/src/tool/WebSearchFunction.cj:73-94`。每次 `webSearch`/`webFetch`：`LLMCandidateProvider.candidates()` 取全量 conf（supplier 可能是一次查库，见 `llm/LLMCandidateProvider.cj:52-57`）→ `filter` 生成新 `ArrayList` → 每个 conf 调一次 `SearchProviderRegistry.get`（内部 `synchronized(mutex)` + `ensureLoaded`）→ 可选地再 `filter` 一次 → 取 `[0]`。中间的两个 `ArrayList` 只为了拿第一个元素。
- **方案**：单遍遍历直接返回第一个匹配项（显式 `provider` 时比较 `conf.provider`），不建中间 list；同一轮里 provider 查询结果复用。
- **预期**：工具调用路径少了 1-2 次 `ArrayList` 分配与 `N` 次互斥锁获取（N = conf 数，通常 <10）。单次收益很小，只有在工具调用密集（每轮对话多次联网）时才可见。
- **代价**：错误消息里「候选为空」的判定需要保留（仍然在遍历结束时抛），逻辑分支略增。
- **验证**：`cjpm bench` 或分段计时，构造 20 条 conf、循环调用 10 万次，对比中位数；同时用 `cjprof` 确认 `SearchProviderRegistry.get` 的占比。
- **证据状态**：`无基线（待验证，不进 tasks）`

### [CPU] `Redactor.defaultKeys()` 作为默认参数每次调用都新建 `HashSet`

- **现状**：`f_llm/src/util/Redactor.cj:39-45` 被 `:48` 用作默认实参，因此每次 `redactJson(value)` 都执行一次 `HashSet` 构造 + 7 次 `add` + 7 个字面量（字面量驻留常量池，`HashSet` 是每次新建）。
- **方案**：改为 `private static let DEFAULT_KEYS = ...`（只读共享），默认参数改成 `keys!: ?HashSet<String> = None`，函数内 `let effective = keys ?? DEFAULT_KEYS`；需要加自定义键时调用方显式传入新集合。
- **预期**：每次脱敏省 1 个 `HashSet` 与 7 次插入；对逐条报文脱敏（一旦接线）是可线性放大的固定开销。
- **代价**：`defaultKeys()` 仍是 public（对外契约不变），但要保证共享集合不被调用方 `add` 污染——文档上写明「返回值可修改的副本」，内部共享用私有常量。
- **验证**：微基准 100 万次 `redactJson` 的分配量与耗时中位数。
- **证据状态**：`无基线（待验证，不进 tasks）`

## 待验证假设

| # | 假设 | 位置 | 缺什么数据 | 怎么采 |
| --- | --- | --- | --- | --- |
| 1 | `truncateBytes` 的逐 `rune.toString()` + `StringBuilder` 扩容是 `webFetch` 的主要 CPU/分配来源 | `f_llm/src/tool/WebFetchFunction.cj:76-94` | self time 占比、每次调用分配字节数 | `cjprof record` 跑 200 次 256KB 中文正文抓取；`cjprof heap` 看 `String` 分配占比 |
| 2 | `renderPage` 双份拼接的峰值内存与并发度线性相关，是 RSS 尖峰来源之一 | `f_llm/src/tool/WebFetchFunction.cj:69-73` | 峰值 RSS / heapUsed、并发 8 下的曲线 | 8 线程各跑 100 次 256KB 抓取，记录 `getUsedHeapSize()` 峰值（改前 / 改后同输入） |
| 3 | `pickConf` 的候选重建与逐条加锁在工具密集场景可测 | `f_llm/src/tool/WebSearchFunction.cj:73-94` | 单次 `pickConf` 耗时、每轮对话调用次数 | 在 `pickConf` 内分段计时，20 条 conf、10 万次循环取 P95；`cjprof` 对照 `SearchProviderRegistry.get` 占比 |
| 4 | `LLMCandidateProvider.candidates()` 的 supplier 是否每次真查库（决定假设 3 的上限） | `f_llm/src/llm/LLMCandidateProvider.cj:52-57` | supplier 默认实现与缓存策略 | 读 `LLMConfsHolder` 的 supplier 注入处并加计数埋点，跑 10 分钟稳态 |

## 文件覆盖

| # | 文件 | 类型 | 已读 | 说明 |
| --- | --- | --- | --- | --- |
| 1 | `f_llm/src/tool/TodoFunction.cj` | .cj | ✅ | 见「一般 · predecessor 丢弃」「一般 · TodoFinder 无实现」「一般 · todoList 无预算」「轻微 · 不渲染 status」 |
| 2 | `f_llm/src/tool/ToolFunctions_test.cj` | .cj（测试） | ✅ | 见「轻微 · 测试脚手架重复/吞异常」；`WebSearch` 三条用例逻辑正确（含 no-fallback 断言） |
| 3 | `f_llm/src/tool/ToolName.cj` | .cj | ✅ | 见「一般 · sanitize 撞名」「轻微 · 白名单重复」「轻微 · 文档称有常量」 |
| 4 | `f_llm/src/tool/WebFetchFunction.cj` | .cj | ✅ | 见「一般 · fetchMaxBytes 事后截断」；`SsrfGuard.check` 先于 provider（`:55`）顺序正确，未重复 part24 的 SsrfGuard 结论 |
| 5 | `f_llm/src/tool/WebFetch_test.cj` | .cj（测试） | ✅ | 用例覆盖 SSRF 拒绝/不触达 provider/字符边界截断/工具名规则；缺 `title` 超预算用例（见建议） |
| 6 | `f_llm/src/tool/WebSearchFunction.cj` | .cj | ✅ | 见「一般 · count 未校验」「一般 · 预算未含包装」；`pickConf` 显式 provider 不回退的实现与注释一致 |
| 7 | `f_llm/src/tool/WrappedFunctionCalling.cj` | .cj | ✅ | 两个 init 中「命名参数版」仓内零引用，但属对外 public 契约，按硬原则一不判死代码（信息项） |
| 8 | `f_llm/src/tool/imports.cj` | .cj | ✅ | 逐条核对：`LinkedList`/`ConcurrentHashMap`/`AtomicBool`/`AtomicInt64`/`SecureRandom`/`TypeInfo`/`std.fs`/`std.io`/`f_regex`/`f_log`/`f_egraph`/`f_bean.macros` 在包内均有引用，无冗余 |
| 9 | `f_llm/src/util/Redactor.cj` | .cj | ✅ | 见「一般 · 字节切片」「一般 · 大小写」「轻微 · 递归无深度上限」；`redactJson` 仓内仅测试引用（信息项） |
| 10 | `f_llm/src/util/Redactor_test.cj` | .cj（测试） | ✅ | 4 条用例均有效，但未覆盖多字节与 `ApiKey` 变体（与发现 1、2 的建议一致） |
| 11 | `f_llm/src/util/TextClip.cj` | .cj | ✅ | 按 `rune` 计数、`truncated` 判定与 `+1` 省略号语义自洽；被 `store/LoomMemoryPolicy.cj:252` 使用 |
| 12 | `f_llm/src/util/TextClip_test.cj` | .cj（测试） | ✅ | 边界（空串/0/恰好等于上限/中文）齐全，无问题 |
| 13 | `f_llm/src/util/http.cj` | .cj | ✅ | 见「一般 · TrustAll」；`resource` 在 `finally` 里 `close()`（`f_base/src/resource.cj:18-24`），无句柄泄漏；超时依赖 stdx 默认读写各 15s（`stdx/doc/libs_stdx/net/http/http_package_api/http_package_classes.md:546-570`、`:585-591`），建连无超时是已知限制（`doc/known-limitations.md` §1），本轮不判缺陷 |
| 14 | `f_llm/src/util/imports.cj` | .cj | ✅ | 见「轻微 · 4 条未使用 import」 |
| 15 | `f_llm/src/wiring/StoreWiring.cj` | .cj | ✅ | 见「轻微 · 锁内 I/O」「轻微 · 注释与实现不符」；幂等性（`ensure`/`contains` 先查后注）与 `seedKinds` 失败只 warn 的设计与 `doc/f_llm.md:297` 一致 |

合计：`.cj` 15 个 / `.md` 0 个 / 共 15 个，全部读完。

## 覆盖自检

| 维度 | 命中 | 未命中时的说明 |
| --- | --- | --- |
| 正确性 / 设计 / 语言特性 / 可读性 / 安全性 | 9 | 正确性/契约 7（mask 字节切片、redactJson 大小写、predecessor 丢弃、TodoFinder 未接线、todoList 无预算、fetch 预算不覆盖输出、count 未校验）、健壮性 1（sanitize 撞名导致整源注册中断）、安全性 1（TrustAll）；语言特性面：`.size` 一律当字节长度使用，除 `mask` 外均正确；可读性问题并入对应发现的建议 |
| §1 死代码 | 0 | 逐个核对：`truncateBytes`/`pickConf`/`ToolName.sanitize`/`StoreWiring.ensure*`/`seedKinds` 均有调用者；`private`/`internal` 符号全仓搜索无孤岛；`public` 且对外可达的 `Redactor.*`、`TextClip.clip`、`renderPage`、`normalize`、`WrappedFunctionCalling`（两个 init）按硬原则一不判，其中 `redactJson`、`WrappedFunctionCalling(name!/description!/callee!)` 仓内零引用仅记为信息；`return`/`throw` 后无同层语句；局部 `let` 全部被读；未使用 import 单列 1 条（轻微） |
| §2 重复逻辑 | 2 | ①`ToolName` 合法字符白名单两遍（已列发现）；②测试脚手架 5 份（已列发现）。已两两比对：`truncateBytes`（字节预算）与 `TextClip.clip`（字符预算，后缀在预算内）单位与后缀语义不同，判为非重复，但「字节版裁剪」缺 util 落点，见「一般 · fetchMaxBytes」建议；`StoreWiring.ensure` / `ensureMeta` 仅类型与注册 API 不同，`Stores` 无泛型注册入口，判不可合并 |
| §3 空实现 | 0 | `seedKinds` 的 `catch` 只降级为 `warn` 并保留 `kindsSeeded=false` 供重试，不属静默；唯一空函数体是测试替身 `CountingFetchProvider.search`（返回空列表，违反 `SearchProvider`「失败必须抛」的约定但只用于测试）与 `EchoFunction.call`（返回固定结果）；生产的 `FunctionCalling.call(T)` 默认实现抛异常是显式守卫，未计入 |
| §4 栈溢出 | 1 | `redactJson` 自递归无深度上限（已列轻微，当前仅测试调用）；`truncateBytes`/`TextClip.clip`/`normalize` 均为单层循环；`ToolName.sanitize` 无递归 |
| §5 OOM | 2 | ①`todoList` 无条数/字节上限，整张待办表直接进上下文（一般）；②`webFetch` 的正文在 provider 侧已 `readEntire` 整段物化、标题不受 `maxBytes` 约束（一般，与 §11「预算不覆盖输出」同一条）。`normalize` 有 `maxBytes` 且按整条追加，无平方级拼接 |
| §6.1 热点瓶颈 | 0 | 未提供任何 profile / bench 数据，`truncateBytes`、`renderPage` 拼接、`pickConf` 只作线索，已全部降级为「待验证假设」#1-#4，不当缺陷报 |
| §6.2 大粒度锁 | 1 | `StoreWiring.wire()` 锁内含配置读取与 DB 补种（轻微，启动期单线程、竞争线程数为 1，已说明为何当前不是性能问题） |
| §6.3 并发串行 | 0 | 本部分无 `spawn`/`Future`/线程池；`pickConf` 单线程顺序调用，不构成串行段 |
| §6.4 低效算法 | 0 | `truncateBytes`/`normalize`/`todoList` 均为 O(n) 单遍；`pickConf` 的两级 `filter` 是 O(N)（N = conf 数，量级个位数），未测出复杂度问题，分配开销归入 §8 方案 |
| §7 降堆内存方案 | 2 | `truncateBytes` 逐字符临时 String、`renderPage` 三份串同时存活（均标 `无基线`） |
| §8 降 CPU 方案 | 2 | `pickConf` 重建候选、`defaultKeys()` 每次建 HashSet（均标 `无基线`） |
| §9 local mode 可行性 | 0 | 本部分临时对象都小且短命（`HashSet`、`ArrayList`、`StringBuilder`），没有「函数内创建、函数内消费」的大结构；`truncateBytes` 的产物会作为返回值逃逸，需要 `exclave`，收益无法用峰值内存证明，按无数据不立方案 |
| §11 现有代码的 BUG（存量） | 9 | 即上文 9 条一般级发现，全部为存量（快照模式无 diff，`git blame` 命中 `e928da3176` / `4be871f2` / `98bc0c0e` / `58131ec4` 等既有提交），无本次改动引入项 |
| §12 并发安全与锁粒度 | 1 | 并发安全 0：`StoreWiring` 的 `mutex`/`kindsSeeded`/`beanInitialized` 只在该锁内读写，`ToolName`/`Redactor`/`TextClip`/`truncateBytes`/`normalize` 全为无状态纯函数；锁粒度 1（`StoreWiring`，已列轻微）。测试用例的全局 `setSupplier` 污染归入测试脚手架条 |
| §14 功能完备性与 README 覆盖 | 2 | ①`TodoFunction` 依赖的 `TodoFinder` 仓内无实现且文档未提前置条件（一般）；②`ToolName` 3 个 public 成员与模块级 `normalize` 未进公开 API 清单、且文档误称「ToolName 里有常量」（轻微）。`webSearch`/`webFetch`/`TextClip`/`Redactor`/`WrappedFunctionCalling`/`StoreWiring` 的 README 条目与实现一致 |
| 文件覆盖（§13 等） | 15/15 | 无缺失；本部分无 `.md` 文件（`README.md`、`doc/**` 属其他部分），涉及文档的结论均标了承诺源行号，未越界展开 |

## 模块统计

| 严重程度 | 数量 |
| --- | --- |
| 严重 | 0 |
| 一般 | 9 |
| 轻微 | 8 |
| 优化方案（堆内存 / CPU） | 2 / 2 |

## 总评

本部分是「工具出口 + 脱敏/裁剪工具函数 + 启动接线」，整体结构清晰：`redactJson`/`truncateBytes`/`TextClip.clip` 都写了为什么这样做（UTF-8 边界、gzip、不截断工具名），`StoreWiring` 的幂等与失败降级也与文档口径一致，**没有死代码和空实现**，`public` 面收得比较干净。

主要风险集中在三处：

1. **工具结果预算不统一**。`llm_toolResultMaxBytes` 名义上是全局工具预算，实际只有 `webSearch` 一个工具在用（`WebSearchFunction.cj:68`），`LLMToolLoop` 出口也不兜底 → `todoList` 可以把整张待办表灌进上下文，`webFetch` 的 `llm_fetchMaxBytes` 又能被超长标题绕过、且正文在截断前已整段物化。这是最容易在真实流量下变成「上下文爆掉/费用飙升」的一条，建议优先处理（一条 `LLMToolLoop` 出口兜底 + 各工具显式预算）。
2. **脱敏原语在边界输入上会抛异常或漏脱敏**。`mask` 用字节下标切片（多字节凭据 → `IllegalArgumentException`），`redactJson` 只归一数据侧大小写（`ApiKey` 漏脱敏）。两者都是对外 public 的脱敏 API，出错方向恰好是「日志中断」或「密钥入日志」，都属于不能容忍的失败方向。
3. **`TodoFunction` 一整组工具在当前仓库里不可用**：`TodoFinder` 无实现（调用必抛 `BeanException`）、`predecessor` 字段因命名不一致被静默丢弃、列表不渲染状态、也没有任何用例覆盖。这一组要么补齐实现与文档前置条件，要么从内置工具里摘掉，不适合维持「注册得上但用不了」的中间状态。

TLS 全量 `TrustAll`（本部分 1 处，模块内共 7 处）属于模块级设计取舍，安全影响明确（Bearer 密钥可被中间人截获），建议单独立项由用户决定是加配置开关还是保留现状并记入 `known-limitations`。

存量缺陷共 17 条（9 一般 + 8 轻微），是否纳入修复待用户决定；本轮未发现阻塞级的严重缺陷。性能相关的 4 条方案与 4 条假设均无基线数据，不进 `tasks.md`，下一轮补 `cjprof`/`cjpm bench` 后再判。

## 范围外提示（不计入本部分统计）

- `src/store/MemoryKinds.cj:55` 的 `CUSTOM` 是普通 `HashMap`，`attach`（`:63-78`，会先 `clear()`）、`register` / `remove` / `all`（`:97`、`:123`、`:157`）都无同步 → 静态共享可变状态的数据竞争；`StoreWiring` 的锁只在启动期保护写者，保护不到其他线程的读写（与本部分「轻微 · 锁内 I/O」相邻，建议在 `store` 那部分独立立项）。
- `src/model/po/Todo.cj:39-41` 的 `predecessor()` 对默认空串直接 `JsonValue.fromStr(predecessors)`：`predecessors` 为 `''` 时抛异常，属性不可安全读取（与本部分「predecessor 丢弃」互为因果）。
- `src/llm/CallLogger.cj:40-43` 的 `CallLog.info` 全仓零调用，「每次调用一行汇总日志」未接线；`CallLog.summary` 只有测试在用。
- `doc/f_llm.md:175` 称 `CommandFunction` 输出截断到 `llm_toolResultMaxBytes`，实际全模块只有 `WebSearchFunction.cj:68` 引用该配置。
- `MemoryKinds.predefined()` 返回 9 个 kind（含 `experience` / `experience_failed`），`doc/f_llm.md:327` 写「7 个预定义 kind」。
