# f_llm 模块审查报告

- **审查日期**：2026-11-28
- **模块路径**：`f_llm`（480 个文件：368 个 .cj + 112 个 .md）
- **基线**：工作区快照（sts/1.3.x 工作区，master 同提交 120fd2542，无分支差异）
- **审查重点**：见 scope.md（正确性、死代码、重复逻辑、空实现、栈溢出、OOM、热点、并发与锁、存量 BUG、内存/CPU 优化空间、local mode 可行性、README 覆盖）
- **报告版本**：v1（由 25 个分部分报告合并：`parts/f_llm.part1..25.md`）

## 发现

<!-- 第 1 部分 -->

### [严重][存量] #1 README 承诺的 `llm_confSource` / `llm_confs` 在默认部署下完全不生效，且回退是静默的

- **位置**：`f_llm/README.md:176`、`f_llm/README.md:778`、`f_llm/README_en.md:174`、`f_llm/README_en.md:769`；实现 `f_llm/src/llm/LLMConfs.cj:49-59`、`f_llm/src/service/LLMConfSource.cj:153-168`、`f_llm/src/config/LLMConfig.cj:97-99`
- **来源**：存量（快照模式无基线，`git blame` 不可用）
- **判据**：review-checklist §14.1「接线缺失 / 承诺了但没实现」、§13「文档写的配置在源码里找不到或不一致」、§3「开关打开后走进空分支」
- **证据**：静态确定 —— `LLMConfs.createHolder()` 先读 `StoreSettings.load().metaStore`，只要它是 `f_store` / `postgres` / `mysql` 三者之一就**直接** `return LLMConfsHolder(source: StoreMetaConfSource(MetaStoreAdapter()))`，`LLMConfig.getConfSource()` 根本不会被读；而默认值正是 `f_store`（`src/store/StoreSettings.cj:40`），另外两个也是 `StoreWiring.wire()` 必然注册的实现，因此 `createHolder` 的第二个分支（`createConfSource(...)`）在常规部署里不可达。此外 `createConfSource` 只接受 `database` / `env` / `file:<path>`（`LLMConfSource.cj:153-168`），README 表里写的 `static` / `store` 会抛 `IllegalArgumentException`，`file`（不带路径）也不被接受；代码默认值是 `database`（`LLMConfig.cj:98`）而不是 README 写的「空」。
- **描述**：按 README「配置来源由 `llm_confSource` 选择；`llm_confs` 可直接内联一组配置（静态部署）」操作时，用户设 `llm_confSource=env` + `llm_confs='[{...}]'` 会被完全忽略：快照来自 meta store 的 `llm_conf` 表。表里没有数据 → `LLMConfsSnapshot.candidates()` 返回空 → 每次 `LLM.chatByName` 抛 `no available llm conf for: X, available: []`（`src/llm/LLM.cj:113-122`），而用户在 `llm_confs` 里明明配了模型。更糟的是 `LLMConfs.cj:54` 的 `catch(_: Exception) {}` 不回日志，与 README:243「未知配置值**启动失败**并打印可选列表，不静默回退」直接相反——同一份文档两套语义。
- **建议**：二选一并把另一处文档改掉——(a) 保留 1.3 的「模型配置统一走 `llm_metaStore.confs`」，则 README:176 / 778 改成这条事实，`llm_confSource` / `llm_confs` 标注为「旧来源，仅当 `llm_metaStore` 不是 f_store/postgres/mysql 时生效」；(b) 让显式配置优先：`llm_confSource` 非空时先走 `createConfSource`，否则才用 meta store。同时把 `LLMConfs.cj:54` 的静默 catch 改成 `log.warn`，并补一条启动用例「默认 metaStore + `llm_confs` 内联」。

### [一般][存量] #2 「配置只在启动时读取一次」与实现按 60s TTL 刷新模型配置矛盾

- **位置**：`f_llm/README.md:69`、`f_llm/README.md:840`、`f_llm/README_en.md:69`；实现 `f_llm/src/llm/LLMConfsHolder.cj:73`、`:111-117`、`:224-266`、`f_llm/src/config/LLMConfig.cj:101-103`
- **来源**：存量
- **判据**：review-checklist §13「文档过期 / 与实现不符」
- **证据**：静态确定 —— `ensureFresh()` 在 `MonoTime.now() - loadedAt >= refreshInterval` 时调用 `refresh()` 并整体替换快照（`LLMConfsHolder.cj:111-117`、`:255`），`refreshInterval` 默认 `Config.getValue(LLM_CONF_REFRESH_SECONDS) ?? 60`（`LLMConfig.cj:101-103`）；而 README:780 把该键默认值写成「无」。`candidates()` / `all()` / `peekNext()` 每次入口都调 `ensureFresh()`（`:124-132`、`:168-169`），所以刷新是真实生效的。
- **描述**：进程级 env 键确实只在启动装一次（`f_config` 的 `ARGS` 启动装载），但**模型配置**（provider、url、auth、实际模型名、weight、token 阈值）每 60 s 会从 meta store 重新装载，并在下一次调用生效。运维按 README:840「配置只读：只在启动时读取一次，切换存储或端点必须重启」理解，会误判密钥轮换、权重调整、熔断阈值调整的生效时机；反之，改完库里的 url 没重启却发现生效了，也找不到依据。附带一处未文档化语义：`llm_confRefreshSeconds=0`（或负数）会让 `now - loadedAt < 0` 恒假 ⇒ **每次调用都 reload**，并不等于"关闭刷新"。
- **建议**：README 把「进程级 env 键」与「模型配置快照」分开写：前者启动读一次；后者默认 60 s 懒式 TTL 刷新、刷新失败保留旧快照（`LLMConfsHolder.cj:259-261`），`0`/负数语义写清（建议把 `<=0` 定义为"不刷新"并在代码里实现该判断）。

### [一般][存量] #3 配置项表 10 处默认值写成「无」，实现里有具体默认值（超时与各类上限因此被隐藏）

- **位置**：`f_llm/README.md:771`、`:780`、`:781`、`:782`、`:784`、`:785`、`:786`、`:787`、`:797`、`:798`（英文版 `README_en.md:762`、`:771`、`:772`、`:773`、`:775`、`:776`、`:777`、`:778`、`:788`、`:789`）
- **来源**：存量
- **判据**：review-checklist §13「API / 配置 / 默认值与源码不符」
- **证据**：静态确定，逐项对照（README 写「无」/「空」，实现有默认值）：

  | 键 | README | 实现（`src/config/LLMConfig.cj`） |
  | --- | --- | --- |
  | `llm_rebuildIndexNamespace` | 空（:771） | `'global'`（:147-149） |
  | `llm_confRefreshSeconds` | 无（:780） | `60` s（:101-103） |
  | `llm_loadBalanceAlgo` | 无（:781） | `'randomWeight'`（:160-162） |
  | `llm_failureThreshold` / `llm_cooldownSeconds` | 无（:782） | `5` / `60` s（:164-170） |
  | `llm_streamIdleTimeout` / `llm_streamMaxLineBytes` | 无（:784） | `120` s / `1 MiB`（:177-183） |
  | `llm_toolResultMaxBytes` / `llm_fetchMaxBytes` | 无（:785） | `64 KiB` / `256 KiB`（:188-197） |
  | `llm_prunerLlmName` / `llm_summarisingLlmName` | 无（:786） | `'chat-pro'` / `'chat-pro'`（:117-119、:156-158） |
  | `llm_balanceLowThreshold` | 无（:787） | `100`（:202-204） |
  | `llm_fileSandboxPath` | 无（:797） | 未配置 ⇒ 当前工作目录（`getPath`，:205-221） |
  | `llm_faithfulMemoryPath` | 无（:798） | 未配置 ⇒ `<cwd>/.memory`（:251-253） |

- **描述**：最有害的是超时与上限两类：读者会认为流式没有空闲超时、SSE 单行不限长、工具结果与抓取正文不限大小（README:784-785），实际 120 s / 1 MiB / 64 KiB / 256 KiB 已经生效——排查"长回答被截断""大文件抓取不全"时不会想到这些默认值。`llm_fileSandboxPath` 写「无」，实际未配置时沙箱根 = 进程 cwd 并被 `Directory.create` 自动创建，安全边界与文档描述不同。另外多数 `Duration.second * n` 的写法对 `0` 没有特殊处理（0 是合法值，等于"无冷却 / 每次刷新"），文档也没写。
- **建议**：表里补真实默认值；对「0 / 负数」统一约定（0=不限/关闭，负=非法并在启动校验），并在代码里实现该校验而不是靠乘法碰运气。

### [一般][存量] #4 重试上限文档写「无」，实际是 `Int64.Max`（≈无限重试），退避也没有封顶

- **位置**：`f_llm/README.md:783`、`f_llm/README_en.md:774`；实现 `f_llm/src/config/LLMConfig.cj:245-250`、`f_llm/src/agents/AgentTask.cj:414-440`
- **来源**：存量
- **判据**：review-checklist §11「契约与实现不符 / 资源不对称」、§13「默认值与源码不符」、§12.1「异步语义：超时但任务继续跑」
- **证据**：静态确定 —— `getLLMAccessTryingCount()` 默认 `Int64.Max`、`getLLMAccessTryingElapsed()` 默认 `Duration.second * Int64.Max`（`LLMConfig.cj:246`、`:249`）；`AgentTask.accessLLM()` 的主循环是 `while(count < maxCount && elapsed < maxElapsed)`，未配置时两个条件都几乎永不成立，等于「一直重试」；退避是 `Duration.second * b` 的斐波那契（`b` 逐轮翻倍，`AgentTask.cj:432-440`），没有上限。
- **描述**：一个持续失败的 agent 任务（连接被拒、端点 5xx 之外的异常）会无限重试并长期占用执行线程，没有任何总时限；「重试次数 / 总重试时长」这两个键在未配置时的语义不是"关闭/有限"，而是"永不放弃"，与 README 表格的「无」会让人得出相反结论。另有一处待确认：`Duration.second * Int64.Max` 是否在构造时就因纳秒溢出抛异常（`Duration` 的乘法溢出语义仓内无文档，本机也无 SDK 源码可查），若抛异常则默认路径直接不可用——这一点需要实测确认，暂不据此提级。
- **建议**：默认值改成有限（例如 3 次 / 60 s），把"无限"留给显式配置（如 `-1`）；退避加单次封顶（如 30 s）；README 写清"不配置 = 无限重试"以及总时限的判定口径（从首次尝试起算还是从进入方法起算）。补一条单测：注入恒失败的 transport，断言重试次数与总耗时上界。

### [严重][存量] #5 「按文档建表」这条路径整体不可用：`wire()` 不建表，MySQL 建表脚本还缺代码正在写的向量列

- **位置**：`f_llm/README.md:78`、`:288`、`:726-745`（尤其 `:728`「两个文件列定义一一对应…必须同步改」、`:752`「与代码同步」）、`f_llm/doc/content-store.md:25`、`f_llm/README_en.md:286`；实现 `f_llm/src/wiring/StoreWiring.cj:52-71`、`f_llm/src/dao/mysql/MemoryDAO.cj:26-45`、`:62`、`f_llm/tables-mysql.sql:110-122`、`f_llm/tables-pg.sql:130-158`
- **来源**：存量
- **判据**：review-checklist §13「文档承诺与实现相反」、「规格与实现漂移」、§14.1「承诺了但没实现」
- **证据**：静态确定 ——
  1. **`wire()` 不建表**：它只做 `BeanFactory.instance.afterRegistered()`（:56-59）、5 个内容族 + 3 个元数据族工厂注册（:60-67）、`Stores.bootstrap()` 校验（:68）、`seedKinds()` 补种（:69、:77-97）。全仓 `CREATE TABLE` 只出现在 `src/dao/postgres/Evolution*.cj` 与 `src/dao/mysql/Evolution*.cj`（演进 4 表），20 张主表没有任何建表代码。
  2. **MySQL 脚本与代码对不上**：`MySqlMemoryDAO.myUpsertMemory` 往 `llm_memory (…, title_vec, content_vec, …)` 写 `myvector_construct(...)`（`MemoryDAO.cj:30-33`、`:38-39`），`mySearchDense` 也读 `m.title_vec`（`:62`）；而 `tables-mysql.sql:110-122` 建的 `llm_memory` **没有** `title_vec` / `content_vec` 两列，另建了一张 `llm_memory_vector`（:156-168）——MySQL 代码从不读写这张表（`grep llm_memory_vector src/{dao,store}/mysql` 零命中，只有 `MySqlMemoryRepository_test.cj:51` 自建表时才有 `title_vec`）。Postgres 侧用的才是 `llm_memory_vector`（`tables-pg.sql:130-158`），两套后端反而被写成了对方的形状；`doc/content-store.md:25` 也按 PG 的形状把 `llm_memory_vector` 写成"SQL 部署"的统一向量表。
- **描述**：按 README:288（"wire() 幂等建表"）部署会缺 20 张主表；按 README:743-745 只跑 `tables-mysql.sql` 部署 MySQL，则第一次写入记忆就报 `Unknown column 'title_vec' in 'field list'`，检索同样失败——"两个文件列定义一一对应、且与代码同步"的承诺在 MySQL 这一半不成立。附带一处可读性证据：`tables-mysql.sql:275` 起出现 `-- 7. 鐭ヨ瘑鏂囨。` 这类乱码注释，说明该文件经历过一次未完成的编码转换，与"必须同步改"的维护约定相冲突。
- **建议**：README 统一为「`wire()` 只注册实现 + 校验 + 补种 kind；建表执行 `tables-*.sql`，演进 4 表由 bootstrap 建」；`tables-mysql.sql` 的 `llm_memory` 补 `title_vec` / `content_vec`（含 HNSW 索引与 `myvector_index_build`），删掉或明确标注未被使用的 `llm_memory_vector`，并把乱码注释修掉；补一条 MySQL 真库用例覆盖「建表 → 写入 → dense 检索」，现有 `MySqlMemoryRepository_test` 是自建表、绕过了交付脚本。

### [一般][存量] #6 上下文裁剪一节的名字表照抄即报错，且「保留首条 system」的承诺不成立

- **位置**：`f_llm/README.md:192-205`、`f_llm/README_en.md:190-203`、`f_llm/doc/f_llm-memory-design.md:263-276`；实现 `f_llm/src/llm/ContextPruner.cj:39-56`、`:89-126`、`:127-157`、`:164-180`、`:210-221`、`:246-253`、`:279-287`、`f_llm/src/llm/ContextPrunerMediator.cj:33-36`、`:65-71`
- **来源**：存量
- **判据**：review-checklist §13「文档承诺与实现相反」、「示例不能用」、§11「语义与注释不符」
- **证据**：静态确定 ——
  1. **名字对不上**：注册名都是带参数的合成名 `LastN_${n}`、`Summary_BY_${llmType}_${model}`、`Keywords_BY_…`、`DRC_${systemPruner}_${othersPruner}`、`Saturation_${pruner}`、`TokenBudget_${budget}`、`RetainLastUser_${pruner}`、`RetainLastRound_${pruner}`，只有 `Retain` 是裸名（`ContextPruner.cj:31`、`:45`、`:104`、`:123`、`:139`、`:178`、`:219`、`:252`、`:286`）。`prune()` 命中不到就抛 `unknown context pruner: X, available: …`（Mediator:70）。README 表里的 `LastN` / `RetainLastUser` / `RetainLastRound` / `TokenBudget` / `Saturation` / `DRC` / `Summary` / `Keywords` 一个都不是有效键。仓内只有 `RetainContextPruner` 带 `@Bean`（`ContextPruner.cj:27-37`），中介者启动时只 `lookupList` 到它，其余实现必须显式 `register`（仓内仅测试注册过）；`src/agents/AgentTask.cj:68` 的注释也已按合成名描述（`Saturation_${pruner.name}`）。
  2. **system 保留不成立**：只有 `DRCContextPruner` 把 system 单独拆出来（:142-156）；`LastNContextPruner` 直接 `messages[size - n*2 ..]`（:51-55）、`TokenBudgetContextPruner` 从尾部往前装（:223-244），system 在首位会被整条丢掉。README:205「各策略都以『保留首条 system 消息』为约定」因此是错的，而同一页又依赖这条约定来解释人格/技能的注入位置（`doc/f_llm-memory-design.md:263-276` 的 system 前缀）。
- **描述**：按文档配 `LastN` 启动即抛 `unknown context pruner`；配 `LastN_1`（需要自己构造并注册）又会把人格与技能所在的首条 system 裁掉——模型看不到人格与技能，静默降级、无日志，属于"文档指路指错 + 实现与文档承诺相反"的组合缺陷。
- **建议**：README 表增加「实际注册名 / 是否需要显式 register」两列，或让 Mediator 支持前缀解析并给默认参数（`LastN` → `LastN_1`）；对 `LastN` / `TokenBudget` / `RetainLastUser` / `RetainLastRound` 统一实现「先摘出 role==system 的消息、裁剪其余、再把 system 前置」，与 README:205 对齐；若短期不改实现，则必须把 :205 改成「只有 DRC / Saturation 组合保留 system」。

### [一般][存量] #7 content-store 文档写的删除顺序含 `llm_memory_token`，Postgres 侧只删向量表 → 倒排行永久残留

- **位置**：`f_llm/doc/content-store.md:111`；实现 `f_llm/src/store/postgres/MemoryRepository.cj:122-125`、`f_llm/src/dao/postgres/MemoryDAO.cj:177-179`、`f_llm/tables-pg.sql:162-172`
- **来源**：存量
- **判据**：review-checklist §11「资源不对称」、§13「文档与实现不符」
- **证据**：静态确定 —— Postgres `remove(userId, id)` 只做 `deleteVectors(id)`（`DELETE FROM llm_memory_vector WHERE memory_id=?`，`MemoryDAO.cj:177-179`）+ `removeMemory(...)`（`MemoryDAO.cj:181-185`），没有任何一条语句清 `llm_memory_token`（DAO 里唯一的 token 清空是 `clearTokens`，只用于 upsert 重写稀疏，`MemoryDAO.cj:75-78`、`MemoryRepository.cj:56`）；`tables-pg.sql:162-170` 也没有外键，不会级联。MySQL 侧的 `remove` 反而只清 token + 主表（`src/store/mysql/MemoryRepository.cj:126-131`），两个后端各漏一张表、且漏的不是同一张。
- **描述**：删除一条 Postgres 记忆后，它的 sparse 倒排行（每条记忆「标题 token + 正文 token」两批行）永久留在 `llm_memory_token`，`idx_memory_token_lookup` 随删除次数单调变大；检索正确性不受影响（`MemoryDAO.cj:114-124` 的 sparse SQL 会 `JOIN llm_memory`，已删记录 join 不到），但这是纯粹的存储与索引膨胀，且与文档明确写出的"先删 vector / token 再删 memory"不符（MySQL 是"删 token、主表"，Postgres 是"删 vector、主表"）。
- **建议**：两边统一成一个 `removeAll(id)`（vector + token + 主表三张都删），Postgres 侧补 `DELETE FROM llm_memory_token WHERE memory_id=?`；或给两处都建 FK `ON DELETE CASCADE`。补一条跨后端用例断言删除后三张表都查不到该 id（`CrossBackendConformance_test` 已有骨架，加一条即可）。

### [一般][存量] #8 流式失败转移的语义没有文档，实现会在已回调部分内容后从头重放

- **位置**：`f_llm/README.md:100-108`、`:163-190`（`chatStream` 只有一句「流式，逐段回调」）；实现 `f_llm/src/llm/LLM.cj:208-285`（`236-247` 逐条 `onDelta`，`248-254` catch 后 `continue`）
- **来源**：存量
- **判据**：review-checklist §13「关键段落缺失」、§14.1「只做了一半的分支」、§11「契约与实现不符」
- **证据**：静态确定 —— `stream()` 在候选循环内部直接调用 `onDelta`；候选 A 中途异常（连接断、`SseTimeoutException`）被包成 `LLMException` 后 `continue` 到候选 B，B 重新建报文、从第一个 delta 重放，`requestId` 始终不变（:214 只生成一次）。调用方拿不到「已输出多少 / 这段作废」的信号。
- **描述**：长回答遇到连接中断（LLM 场景常见）时，调用方会收到「A 的前半段 + B 的完整回答」，按 delta 追加就得到重复/错乱文本；README 只在非流式的 `chat` 行承诺"失败转移"，对流式是否重放、已回调内容如何作废只字未提。同一处还有第二个契约缺口：流式路径既不调 `hooks.onSuccess` 也不调 `hooks.onRetryableFailure`（对比 `call()` 的 `:148`、`:157`、`:170`），所以**流式调用的成功/失败永远不计入熔断**，而 README:174 把「熔断」写成 `LLMConfs` 的通用能力。
- **建议**：README「流式」小节补一段契约：是否允许换候选、换候选时已回调的 delta 是否作废、调用方应如何丢弃；实现上二选一——(a) 首个 delta 之后不再换候选，直接抛错让调用方整段重试；(b) 换候选时抛带 `deliveredChars` 的可重试异常。同时给 `stream()` 补 hooks 记账，与 `call()` 一致。

### [一般][存量] #9 切块文档没有输入上限，实现把全文展开成 Rune 数组（峰值 ≈ 4–5× 内容大小）

- **位置**：`f_llm/doc/content-store.md:89`、`f_llm/README.md:19-25`；实现 `f_llm/src/store/KnowledgeChunker.cj:66-87`、`:20-36`
- **来源**：存量
- **判据**：review-checklist §5「一次性物化 / 缺少拒绝路径」、§13「关键限制缺失」、§9 约束 4（local region 全局上限）
- **证据**：静态确定（规模待实测）—— `splitImpl` 先 `countRunes` 扫一遍，再 `ArrayList<Rune>(total)` 全量装 rune（local 档 `@ local!`，堆档普通分配），最后逐块 `StringBuilder.toString()` 产出副本。峰值 ≈ `4 B × 字符数`（ASCII 下 ≈ 4×内容字节）+ 输出块副本（≈内容大小）≈ **5×内容**；`knowledgeChunkerUsesLocalBytes` 只在 `content.size ≤ 2 MiB` 时走 local（`KNOWLEDGE_CHUNKER_LOCAL_CONTENT_BYTES = 8 MiB / 4`），超过就整份走堆，没有任何大小拒绝路径。文档只写 `split(content, maxChars: 400, overlap: 50)`，没写"多大以上不要直接切"。
- **描述**：100 MB 的文档按上式峰值 ≥ 500 MB（且随后每块一次 embedding HTTP 调用，无并发上限）；local 档也不是"只影响自己"——`cjLocalRegionMaxSize` 是所有线程活跃 local region 共用的上限，并发 N 个 ≤2 MiB 文档同时切块会叠加 N×8 MiB，超限抛 `LocalRegionOutOfMemoryError`，而 README:21 只写了"单次预算 8 MiB"。
- **建议**：文档补输入上限（例如"content > 8 MiB 请先分片再 upsert"）与并发提示；代码侧加 `maxContentBytes` 参数或分片入口；若要保持 local 档，给切块加并发闸门或把门限按并发数下调。收益需要峰值内存数据，见「优化可行性方案」1 与「待验证假设」1。

### [轻微][存量] #10 文档把预定义 memory kind 写成 7 个，代码与启动补种是 9 个

- **位置**：`f_llm/doc/f_llm-memory-design.md:39`、`f_llm/doc/content-store.md:74-78`（权重表）；实现 `f_llm/src/store/MemoryKinds.cj:45-60`、`:80-92`、`f_llm/tables-pg.sql:113-124`
- **来源**：存量
- **判据**：review-checklist §13「文档过期」、§2「字面量复制（同一张表散落多处）」
- **证据**：静态确定 —— `predefined()` 依次加入 note / fact / preference / task / doc / knowledge / session / **experience** / **experience_failed**（9 个）；SQL 注释与 `INSERT` 种子只列 7 个。`weightOf` 里 experience 走 `0.8`（与自定义同档，`MemoryKinds.cj:178-193`），文档权重表没有这一行。
- **描述**：`StoreWiring.seedKinds()` 会用 9 个 kind 写 `llm_memory_kind`（predefined=true），因此 experience / experience_failed 也受「预定义不可删除」保护（`remove` 抛 `IllegalArgumentException`，`MemoryKinds.cj:158-161`），与文档"7 个预定义"不一致；只按文档初始化的人（直接跑 SQL）会少两行，靠代码补种的人会多两行。
- **建议**：文档改成 9 个并补 experience 权重说明；`tables-pg.sql` / `tables-mysql.sql` 的种子语句同步成 9 行（现在只靠代码 seed 兜底）。

### [轻微][存量] #11 文档内联的提炼提示词与实现文案不一致，摘要编号也不是从 1 开始

- **位置**：`f_llm/doc/f_llm-memory-design.md:280-292`、`:55-67`；实现 `f_llm/src/loom/LoomMemoryPolicy.cj:120-126`、`:204-218`
- **来源**：存量
- **判据**：review-checklist §13「文档与实现不符」（文档声称引用的是提示词原文）
- **证据**：静态确定 —— 文档写「输出 JSON，不要解释：\n{"memory":…}」，实现是「提炼两条内容，只输出 JSON：\n{"memory":…}」；摘要行标签用 `[${index + 1}]`，而 `index` 从 `turns.size - maxTurns` 起算（`:207-212`），开了 maxTurns 截断后首行是 `[6]` 而不是文档示例的 `[1]`。
- **建议**：文档改为引用实现常量、或删掉提示词原文（避免两处漂移）；若要 `[1]` 语义，标签改成 `index - limit + 1`。

### [轻微][存量] #12 README 说内置工具名常量在 `ToolName` 里，`ToolName` 实际只有名字校验

- **位置**：`f_llm/README.md:217`、`f_llm/README_en.md:215`；实现 `f_llm/src/tool/ToolName.cj:27-45`
- **来源**：存量
- **判据**：review-checklist §13「文档指向不存在的 API」
- **证据**：静态确定 —— `ToolName` 只有 `MAX_LENGTH`、`validate`、`mcp`、`sanitize`，没有任何工具名常量；`webSearch` / `channelSend` 等字符串散落在各自的 `FunctionCalling` 实现里。
- **建议**：文档指向实际的常量位置，或把工具名收口成常量类并在此点名；否则使用者按文档去 `ToolName` 找 `WEB_SEARCH` 会扑空。

### [轻微][存量] #13 README 自述「六块能力」但表里 8 行，目录树缺 `src/channel/`

- **位置**：`f_llm/README.md:3`、`:5-14`、`:31-54`、`:812-813`、`f_llm/README_en.md:3`、`:31-54`
- **来源**：存量
- **判据**：review-checklist §13/§14.2「结构未登记 / 索引遗漏」
- **证据**：静态确定 —— 能力表 8 行（模型访问 / 存储 / 记忆族 / loom / Supervisor / channel / 技能演进 / 检索评测）；layout 里没有 `channel/`（全文件检索 `channel/` 零命中），但正文「第三方平台通道」与 API 速查都指向 `fountain::f_llm.channel.ChannelMediator`，实际也存在 `src/channel/`（`ChannelContract.cj`、`EmailChannel.cj`、`ChannelMediator*.cj`）。另外 `README.md:812-813` 两条 `cjpm test` 完全相同、描述却一条写"单元测试"一条写"真库用例会 SKIP"；英文版 Tests 一节（`README_en.md:800-807`）把中文版"连上了断言失败照常报错"（`README.md:816-817`）压缩掉了，只留 "probe connectivity and skip themselves"，读者会以为 SKIP 覆盖断言失败。
- **建议**：改为「八块能力」；layout 补 `channel/` 一行；两条重复的 `cjpm test` 合并成一条并保留探测/SKIP 说明；英文版补回"断言失败照常失败、SKIP 只针对连接不可用"这句（与 `doc/dev-env.md:137-161` 的约定一致）。

### [轻微][存量] #14 同一个「默认存储」有两份常量，取值互相矛盾

- **位置**：`f_llm/src/store/Stores.cj:31-32`（`DEFAULT_CONTENT='postgres'`、`DEFAULT_META='postgres'`）vs `f_llm/src/store/StoreSettings.cj:39-40`（`'f_hydra'`、`'f_store'`）；文档侧 `README.md:764-765`
- **来源**：存量
- **判据**：review-checklist §2「字面量复制 / 换算复制 → 行为漂移」、§11「契约与实现不符」
- **证据**：静态确定 —— `Stores.DEFAULT_CONTENT` / `Stores.DEFAULT_META` 全仓零引用（grep 只命中定义处与一条测试对 `StoreSettings.DEFAULT_META` 的断言），真正常用的是 `StoreSettings` 的同名常量（`StoreSettings.cj:72-74`）。两组值一个 `postgres`、一个 `f_hydra`/`f_store`，README 与真值一致的是后者。
- **描述**：`Stores` 是 public 类，这两个常量对外可达（**不判死代码**），但语义是错的：下游若引用 `Stores.DEFAULT_CONTENT` 会得到与 README 相反的默认值（`postgres` 需要真库，无库部署直接启动失败）。
- **建议**：删掉这两个常量，或改成 `public static const DEFAULT_CONTENT = StoreSettings.DEFAULT_CONTENT` 之类的单向引用，保证默认值只有一处定义。

### [一般][存量] #15 `writeKnowledge` 的 docId 格式过期，README 写的旧格式已被演进侧明确排除（静默不消费）

- **位置**：`f_llm/README.md:515`、`f_llm/README.md:323`、`f_llm/README_en.md:509`；实现 `f_llm/src/loom/LoomMemoryPolicy.cj:156`、`f_llm/src/loom/SkillEvolutionJob.cj:310-315`、`:333`
- **来源**：存量
- **判据**：review-checklist §13「文档过期（描述的功能已改名/改格式）」、§11「与规格冲突」
- **证据**：静态确定 —— 实现写出的 docId 是 `loom:${policy.userId}:${policy.namespace}:${flowName}:${stamp}-${nextDocSeq()}`；`SkillEvolutionJob` 只按 `loom:<userId>:<namespace>:` 前缀取知识，且注释写明「旧格式（`loom:<flow>:<seq>`）无法判定归属，一律不取——宁可少取，不可串味」。
- **描述**：README 两处仍写 `loom:<流程>:<序号>` / `loom:X:N`。按 README 的写法手工 upsert 同形 docId 的知识，演进任务永远不会消费它，且没有任何日志或异常；反过来，运维按 README 去库里按 `loom:<flow>:` 找文档也找不到（真实前缀带 userId/namespace）。
- **建议**：README 改成 `loom:<userId>:<namespace>:<flow>:<时间戳>-<序号>`，并注明「演进只认带租户前缀的 id；手工写入请勿借用 `loom:` 前缀」。

### [一般][存量] #16 JIT 步骤「可通过 `{id.output}` 传值」与 `plan.validate()` 直接拒绝 JIT 占位符相反

- **位置**：`f_llm/README.md:395`、`f_llm/README_en.md:391`；实现 `f_llm/src/loom/Plan.cj:109-124`、`f_llm/src/loom/LoomRunner.cj:121`
- **来源**：存量
- **判据**：review-checklist §13「文档承诺与实现相反」、§11「契约与实现不符」
- **证据**：静态确定 —— `FlowPlan.validate()` 对 `kind == 'jit'` 的步骤遍历已见 step id，只要 `input` 含 `{<id>.output}` 或 `{<id>}` 就抛 `jit step does not support {…} template placeholders`，含 `{start.output}` / `{start}` 同样抛；`LoomRunner.run()` 第一行就是 `plan.validate()`。
- **描述**：README 规则表同一行自相矛盾：前半句「每个 JIT 步骤独立编译」正确，后半句「只能通过 `{id.output}` 传值」是旧行为。用户按后半句写 JIT 步骤，`run()` 立刻抛错，且错误信息与文档说法相反，容易误判为框架 bug。
- **建议**：改为「JIT 步骤**不支持** `{…}` 模板占位符（`validate()` 会拒绝）；需要上游数据时改用 `llm`/`tool` 步骤，或在片段内调 `loomStore` / `loomCallTool`」。

### [一般][存量] #17 `command` 工具可执行任意系统命令，README 未标注该限制，`llm_fileSandboxPath` 只被说成「文件工具只能访问该目录」

- **位置**：`f_llm/README.md:222`、`f_llm/README.md:797`、`f_llm/README_en.md:220`、`f_llm/README_en.md:788`；实现 `f_llm/src/tool/CommandFunction.cj:52-56`、`f_llm/src/config/LLMConfig.cj:219-221`
- **来源**：存量
- **判据**：review-checklist §14.2「缺关键段落：限制与注意事项」、§10「安全性」、§13
- **证据**：静态确定 —— `CommandFunction` 标了 `@Bean`（按 README:138「@Bean + FunctionCalling<T>，FunctionMediator 自动装载」即默认进入工具表），`call()` 把入参按空格 `split` 后直接执行，`workingDirectory` 取自 `llm_fileSandboxPath`，**没有**命令白名单、参数校验或路径越界拦截；该配置项只决定 cwd（未配置时还是进程 cwd）。
- **描述**：README 把 `command` 与「受 `llm_fileSandboxPath` 限制」的文件工具并列在同一张表里，读者容易把「沙箱」理解为整体隔离。实际模型可以 `cd ..`、用绝对路径、起子进程、访问网络。这是文档层面的安全边界缺失（代码语义就是「执行命令」，本身不算 bug）。
- **建议**：该行补一句「无隔离：可执行任意系统命令，`llm_fileSandboxPath` 仅作为工作目录；暴露给模型前请用 `ToolScope` / 工具白名单收缩」；`llm_fileSandboxPath` 的说明改为「文件类工具的路径根，不限制 `command`」。

### [轻微][存量] #18 `WebSearchFunction` 并不带 `SsrfGuard`，README 把两个工具并列标注同一防护

- **位置**：`f_llm/README.md:224`、`f_llm/README_en.md:222`；实现 `f_llm/src/tool/WebFetchFunction.cj:55`、`f_llm/src/tool/WebSearchFunction.cj:63-70`
- **来源**：存量
- **判据**：review-checklist §13「描述与实现不符」
- **证据**：静态确定 —— `SsrfGuard.check` 只出现在 `WebFetchFunction`；`WebSearchFunction.call()` 走 `SearchProvider.search(conf, …)`（固定平台端点），全程不经 `SsrfGuard`。
- **描述**：表格把 `WebSearchFunction` / `WebFetchFunction` 并列并统一标注「带 `SsrfGuard` 防内网探测」，实际防护只覆盖抓取（搜索不需要，因为 URL 不可控）。这会让安全评审误判覆盖面。
- **建议**：把括号里的说明移到 `WebFetchFunction` 单元格；顺带在该行标注「搜索借用可用 `LLMConf` 的平台凭据，端点由 provider 决定」。

### [一般][存量] #19 快速开始缺「模型配置从哪来」这一环，`chatByName` 的 `llmName` 是逻辑名而非模型名

- **位置**：`f_llm/README.md:58-98`（关键在 `:93-94`）、`f_llm/README.md:131`、`f_llm/README.md:176`、`:779`；`f_llm/README_en.md:58-98`
- **来源**：存量
- **判据**：review-checklist §14.2「缺关键段落：按文档用不起来」、§13「示例不能用」
- **证据**：静态确定 —— `chatByName(llmName, params)` 用 `llmName` 从快照取候选（`src/llm/LLM.cj:90-101`），候选键是 `LLMConf.llmName`；请求体里的 `model` 用的是 `actualLlmName`（`src/llm/ChatCompletionsMapper.cj:29-38`）。示例把 `'deepseek-flash'` 同时当 `llmName` 与 `model`，而全文没有任何 `llm_confs` 元素、`file:` 来源文件内容或 `llm_conf` 表行的样例（`grep llmName / llm_confs` 只命中表头与说明句）。
- **描述**：快速开始第 1 步只配了存储与 embedding 环境变量，第 3 步直接 `chatByName('deepseek-flash', …)`；由于默认数据源是 meta store 且其中没有该 `llmName`，必然抛 `no available llm conf for: deepseek-flash`（`src/llm/LLM.cj:113-122`）。与 #1 同源但缺口不同：#1 是「配了不生效」，本条是「文档没教怎么配、也没解释逻辑名」。
- **建议**：补一段最小模型配置样例（`llm_confs` JSON 元素 / `llm_conf` 表行 / f_store 键均可），并说明 `chatByName` 收 `llmName`（逻辑名），示例里把两者写成 `'chat-pro'` / `'deepseek-flash'` 以区分。

### [轻微][存量] #20 「其他公开 API」附录有生成残留，且整类 `public const` 未收录

- **位置**：`f_llm/README.md:860-1069`（残留具体在 `:1016`、`:981`、`:948`）、`f_llm/README_en.md:851-1061`
- **来源**：存量
- **判据**：review-checklist §13（文档与源码不一致 / 无法使用）、§14.2（公开 API 未文档化）
- **证据**：静态确定 ——
  1. **残留**：`ResponseFormat` 写成 `static let json: ResponseFormat = ResponseFormat(             )`，实际是 `ResponseFormat('json_object')`（`src/llm/LLMParams.cj:62-64`）；`MemoryKinds` 的 `static let DOC =` / `FACT =` / `NOTE =` 只有等号没有值；`LLMConfView` 的 `llmUrl`（let）缺类型（实际 `public let llmUrl: String`，`src/store/StoreModels.cj:175`）。
  2. **缺口**：以 `^public (class|interface|struct|enum|type|func|let|const)` 抽取 `src/**`（排除 `*_test.cj`）共 537 个顶层声明（去掉 `*Test` 类后），其中 69 个在 README 中检索不到，全部是 `public const`：`ROLE_*`(4)、`LLM_TYPE_*`(9)、`MODEL_NAME_*`(12)、`CONTEXT_PRUNER_*`(7)、`TODO_STATUS_*`(6)、`KNOWLEDGE_KIND_*`(11)、`SPEC_KIND_*`(7)、`TOOL_TYPE_*`(3)、`PART_TYPE_*`(2)、`SKILL_TYPE_*`(2)、`THINKING*`(2)、`SUMMARISE_*`(2)、`CONTENT_SIZE_*`(2)、`FOUNTAIN_LLM_AGENT`、`SummarisingAgentId`（如 `src/constant/ContextPrunerName.cj:38`、`src/constant/Role.cj:20`）。
- **描述**：附录自称覆盖「未在上文展开的公开声明」，但既有生成残留（读者照抄写不出可编译代码），又整类漏掉公开常量；其中 `CONTEXT_PRUNER_*` 与 `TODO_STATUS_*` 是调用方真的会硬编码的字符串（与 #6 的裁剪器命名问题叠加）。
- **建议**：重新生成附录并让脚本把「空实参 / 空初值 / 缺类型」判为失败；附录至少纳入 `constant/` 下全部 `public const` 的名字与值。

### [轻微][存量] #21 README 覆盖遗漏：`MemoryHit.degraded`、`llm_a2aEnabled`、`wire(characterUserId:)` / `LoomCharacterScope`

- **位置**：`f_llm/README.md:265`（`MemoryHit`）、`f_llm/README.md:848` 与配置表 `:762-803`、`f_llm/README.md:494`、`f_llm/doc/f_llm-memory-design.md:261`；`f_llm/README_en.md:263`、`:839`、`:490`
- **来源**：存量
- **判据**：review-checklist §14.2（公开字段 / 关键配置项未文档化）、§13
- **证据**：静态确定 ——
  1. `MemoryHit` 带 `degraded` 字段（`src/store/PostgresMemoryStore.cj:115`），memory-design §2.4/§8 与 `content-store.md:65` 都用它判断召回可信度，README 的数据模型表只写 `record / score`。
  2. `llm_a2aEnabled` 只在 A2A 段落出现，配置项表没有它；取值默认 `false`（`src/config/LLMConfig.cj:66-68`）。
  3. 人格归属：文档称「角色记录按 `LoomMemoryPolicy.userId` 取」，代码先取 `LoomCharacterScope.current()`，没有安装时才回落记忆策略的 userId（`src/loom/LoomRunner.cj:158-163`），而该 scope 由 `wire(characterUserId:)` 安装（`src/loom/LoomWiring.cj:80-84`）；README 的 loom 章节与配置表都没提这个参数。
- **描述**：三处都是「实现有、文档无」：读者不知道降级标记，也就不会在召回质量下降时区分「真没命中」与「只有 dense 通路」；不知道开 A2A 要设 `llm_a2aEnabled`；配了 `characterUserId` 后人格读的是另一个用户，而文档口径仍是记忆策略的 userId。
- **建议**：`MemoryHit` 行补 `degraded`；配置表补 `llm_a2aEnabled`（默认 `false`）；人格小节改写为「取 `wire(characterUserId:)`（>0 时）→ 否则 `LoomMemoryPolicy.userId`」。

<!-- 第 2 部分 -->

### [一般][存量] §2.8 的错误处理口径与实现相反：不可重试错误不换候选、也不记熔断

- **位置**：`f_llm/doc/f_llm.md:142-145`（§2.8）；同源表述 `:95-96`（§2.3）、`:581`（§10「单个平台失败 → 换下一个候选」）
- **来源**：存量（快照模式无基线）
- **判据**：review-checklist §13（文档承诺与实现相反）+ §11（错误处理语义与命名不符）
- **证据**：静态确定 —— ①`LLM.call` 对 `status >= 400` 只在 `isRetryable` 为真时 `continue`，否则 `throw error` 直接终止整个候选循环（`src/llm/LLM.cj:153-161`），不会「立即换候选」；②该分支不调用 `hooks.onRetryableFailure`，异常直接抛出，熔断器收不到这次失败（`CircuitBreaker.recordRetryableFailure` 只被 `LLM.cj:148/157` 调用）；③`chat(candidates, params)` / `respond(...)` 传入的是空 `LLMHooks()`（`LLM.cj:68-82`），连可重试失败也不记熔断，只有 `chatByName` 建真钩子（`:123-126`）；④`llm_accessTryingCount` / `llm_accessTryingElapsed` 的唯一读取点是 `src/agents/AgentTask.cj:415-416` 的自建重试循环，LLM 门面从不读它们（全仓 grep 仅 `LLMConfig.cj:245-250` 定义 + `AgentTask` 使用）。
- **描述**：文档让调用方以为「4xx（鉴权/参数错）会自动换下一个平台重试，且所有失败都进熔断」。真实行为是：非可重试 4xx 立即失败、不换候选、不记熔断；普通 `chat/respond` 即使 5xx 失败也不进熔断；「重试预算」是 `AgentTask` 层的概念，与候选调度无关。排障时会得到「换平台也没用 / 熔断计数不动」的错误预期。
- **建议**：把 `doc/f_llm.md:144-145` 改成实际口径——「可重试（408/409/425/429/5xx）换下一个候选；其余 4xx 立即抛出且不计熔断；候选循环没有重试预算，预算只在 `AgentTask.accessLLM`」；若希望「两者都记熔断」，在 `LLM.cj:161` 前补一次 `onRetryableFailure` 或在 `LLMException` 上带 `fatal` 标记，由钩子区分统计。

### [一般][存量] `platform-channel` 规格的「模块加载后 `platforms()` 至少含 `email`」与实现相反

- **位置**：`f_llm/doc/spec/add-channel-mediator/specs/platform-channel/spec.md:41-44`；相关表述 `f_llm/doc/loom.md:61`
- **来源**：存量
- **判据**：review-checklist §13（规格与实现漂移）+ §14.1（验收场景不成立）
- **证据**：静态确定 —— `ChannelMediator.platforms()` 遍历的是 **instances**（`src/channel/ChannelMediator.cj:118-130`），provider 表由另一个方法暴露：`providerPlatforms()`（`:71-80`）。`llm_channels` 未配置时 `ChannelBootstrap.install` 在空串处直接返回（`src/channel/ChannelBootstrap.cj:46-51`），`LoomWiring.wire` 调用 `installFromConfig()` 后实例表仍为空（`src/loom/LoomWiring.cj:119`），所以 `platforms()` 返回空数组。
- **描述**：规格的 MUST 场景「进程加载 f_llm 且未做任何手工注册 → `platforms()` 至少包含 `email`」无法通过。`loom.md:61` 又用 `platforms()` 表达「只列已实现平台」，把「能力清单」与「已装配账号」两个口径混在同一个方法名上。调用方按规格写「从 `platforms()` 里挑一个去 send」会拿到空列表，误判成部署没有任何通道能力。
- **建议**：规格改成「`providerPlatforms()` 至少含 `email`；`platforms()` 表示已装配账号的平台」；`loom.md:31-37` 的组件表把两个方法并列写清（`providerPlatforms()` = 能力清单，`platforms()` = 实例清单）。

### [一般][存量] `LoomA2aClient` 规格要求 `send` / `get` / `cancel`，实现只有 `ask`

- **位置**：`f_llm/doc/spec/add-loom-a2a/specs/loom-a2a/spec.md:41-44`
- **来源**：存量
- **判据**：review-checklist §13（规格与实现漂移）+ §14.1（MUST 能力未实现）
- **证据**：静态确定 —— `src/loom/A2aBridge.cj:136-169` 的公开面只有 `init()` / `init(send:)` / `ask(url, text)`；`LoomA2aClient` 上没有 `get` / `cancel`（`A2aClient` 自身有，但规格点名的是 `LoomA2aClient`）。同目录 `tasks.md:18` 只承诺 `ask`，说明是规格写宽了而没有回头收窄。
- **描述**：按规格使用 `LoomA2aClient.get(taskId)` / `cancel(...)` 的下游代码会编译失败；`input-required` 之后继续同一任务、异步取任务结果这两类流程无法通过该类完成。规格还要求「协议错误原样上抛（保留 code）」，`ask` 在无文本时抛的是 `LoomException`（`A2aBridge.cj:167`），与协议错误是两种异常。
- **建议**：二选一——在 `LoomA2aClient` 补 `get` / `cancel` 两个薄转发（并保留 `JsonRpcException.code`），或把 `spec.md:41-44` 收窄成「`ask`：发送并取第一个文本产物；协议错误由底层 `A2aClient` 原样抛出」。

### [一般][存量] A2A 与 Supervisor 的开关耦合未文档化，且「`wire` 末尾启动 A2A」与真实装配顺序不符

- **位置**：`f_llm/doc/loom.md:666-671`；`f_llm/doc/spec/add-loom-a2a/proposal.md:18-24`
- **来源**：存量
- **判据**：review-checklist §13（文档与实现不符）+ §14.1（前置条件/接线缺失）
- **证据**：静态确定 —— ①`LoomWiring.wire` 在 `:117` 调 `LoomA2a.startIfEnabled()`，`:121` 才 `installSupervisor(...)`，不是文档说的「末尾」；②`SupervisorAgent()` 在 `execute` 时才取 `Supervisor.current()`，取不到就返回 `NO_USABLE` + `message='loom supervisor is not installed'`（`src/loom/A2aBridge.cj:35-42`）；③`LLMConfig.a2aEnabled()`（`src/config/LLMConfig.cj:66-68`）与 `supervisorEnabled()`（`:70-72`）互相独立，`startIfEnabled` 没有任何「需要 supervisor」的校验（`A2aBridge.cj:86-111`）。
- **描述**：只设 `llm_a2aEnabled=true`（`llm_supervisor` 保持默认 false）时，9 个 A2A 方法照常注册——等于对外开了一个**永远返回失败**的入口；调用方无法从协议层区分「能力没开」与「没有可用流程」。文档既没写这个前置条件，也没写启动顺序，排障时容易误判为路由表为空。启动瞬间还存在「A2A 已注册、Supervisor 尚未安装」的窗口。
- **建议**：`loom.md:666` 补一句「`llm_a2aEnabled=true` 且 `llm_supervisor=true` 才具备派发能力，否则每次调用返回 `loom supervisor is not installed`」；或在 `LoomA2a.startIfEnabled()` 里判 `supervisorEnabled()==false` 时 `warn` 并直接返回 false（不注册半残入口），并把 `:671` 的「末尾」改成实际位置（host 装配之后、Supervisor 之前）。

### [一般][存量] `known-limitations` 说「所有配置只在启动读一次、`LLMConfsHolder` 定死」，与 §2.2 的 60 s 懒刷新相反

- **位置**：`f_llm/doc/known-limitations.md:8`、`:14`、`:16`；对照 `f_llm/doc/f_llm.md:87`、`:91`
- **来源**：存量
- **判据**：review-checklist §13（文档内部矛盾、与实现不符）+ §2（同一事实两处写法冲突）
- **证据**：静态确定 —— ①`LLMConfsHolder.load()` 每次取快照先比 TTL：`current.version > 0 && MonoTime.now() - current.loadedAt < refreshInterval` 才复用，否则 `refresh(current)`（`src/llm/LLMConfsHolder.cj:113-116`）；`refresh` 重新 `source.load()` 并整体替换快照（`:224-260`）；②TTL 来自 `LLMConfig.getConfRefreshInterval()`，默认 60 秒（`src/config/LLMConfig.cj:101-103`）；③`LLMConfView` 的 provider/llmName/actualLlmName/weight/enabled/llmUrl/auth/temperature 都在每次 `source.load()` 里重建（`src/store/StoreModels.cj:167-193`），所以在 database / `StoreMetaConfSource` 来源下，改库里的权重/密钥/端点在 60 秒内生效，无需重启；`env` / `file:` 来源本身是静态的，刷新读到的仍是同一份内容；④真正「启动期定死」的是 `llm_memoryStore` / `llm_metaStore` / `llm_embeddingUrl` 这类环境变量，以及 `CircuitBreaker` 在构造时读取的 `llm_failureThreshold` / `llm_cooldownSeconds`（`CircuitBreaker.cj:46-52`，holder 只建一次）。
- **描述**：`known-limitations` 的结论「改权重必须重启」「`LLMConfsHolder` 首次使用时定死」是错的。运维按它理解会错过「密钥轮换 / 权重调整已经生效」；反过来，改熔断阈值却确实要重启，文档没写。两条文档对「配置能否热更新」给出相反答案，属于最容易在事故复盘时扯皮的那类不一致。
- **建议**：把 §0 拆成两层写清：**部署配置**（存储/端点/embedding 地址）启动读一次；**模型配置**（`llm_confSource` 来源的 LLMConf 行）按 `llm_confRefreshSeconds`（默认 60 s）懒刷新，权重/密钥/url 实时生效；**熔断阈值与冷却**只在进程启动构造 `CircuitBreaker` 时读取。`f_llm.md:91` 补一句默认 60 s 与「哪些字段会被刷新」。

### [一般][存量] §10 说演进任务抛错有「调度器日志」，实际被静默吞掉，违反 §0 的「降级要留观测点」

- **位置**：`f_llm/doc/f_llm.md:586`（§10 失败与降级表）；对照 `:21-25`（§0 硬约束 3）
- **来源**：存量
- **判据**：review-checklist §3（静默吞异常）+ §13（文档承诺的观测点不存在）
- **证据**：静态确定 —— `SkillEvolutionJob.schedule` 的任务体 `try { … } catch (error: Exception) { () }`（`src/loom/SkillEvolutionJob.cj:387-405`）；`SkillEvolutionJob.cj` 全文没有任何 `Logger` / `log` 调用（grep 零命中）。`TicktockScheduler` 只是把闭包交给 `f_ticktock`；`f_ticktock` 的 `executeOne` 只在异常**逃出** `task.run()` 时才 `LOGGER.warn`（`f_ticktock/src/Ticktock.cj:279-288`），而这里已经被内层 catch 吞掉，所以调度器日志也不会出现。
- **描述**：演进任务失败（租约异常、模型失败、存储失败）时进程里没有任何日志、计数或状态可查，文档却说「调度器日志」可看。这与模块自定的「任何静默退回都必须有可查询的计数或标记」直接冲突，也是「技能一直不演进」最难排查的一类故障。
- **建议**：在 `catch` 里 `LoggerFactory.getLogger<SkillEvolutionJob>().warn('skill evolution failed: ${error.message}')`，并给 `SkillEvolutionLedger` 或状态存储加一个 `lastError` / `failedRuns` 计数；若确定不记录，就把 `:586` 改成「吞掉，无日志（已知缺口）」，不要写成已有观测点。

### [一般][存量] §6.6 与 `loom.md` 承诺「步骤超时由 `LoomTimeout` 控制、失败向下传」，实际 `LoomTimeout` 只包记忆写入，流程步骤没有超时

- **位置**：`f_llm/doc/f_llm.md:403`（§6.6 第 5 条）；`f_llm/doc/loom.md:204-206`
- **来源**：存量
- **判据**：review-checklist §13（文档承诺与实现相反）+ §11（超时语义）
- **证据**：静态确定 —— ①`LoomTimeout` 的唯一生产调用点是 `MemoryRecorderTask.recordWithTimeout`（`src/loom/BackgroundTasks.cj:44`），全仓再无其它调用（grep `LoomTimeout` 仅定义 + 该处）；②`LoomRunner.runCompiled` 的步骤执行路径（`runSync` / `runAsync`）没有任何超时包装，`runAsync` 里 `waiter.get()` 也是无参阻塞（`src/loom/LoomRunner.cj:307`）；③`loom.md:206` 的「这一步记为失败，不会挂死整条流程」因此没有实现依据，和第 15 部分报出的「并行步骤异常/挂起会永久阻塞」正好相反。
- **描述**：文档把「记忆写入的超时保护」误写成「流程步骤的超时保护」。按文档排期的用户会认为长步骤有 3 s/可配超时兜底，实际只有记忆落库有；步骤本身可以无限期阻塞。`LoomTimeout` 的语义说明（调用方按时返回、被调用方后台继续）本身正确，但适用范围被放大了。
- **建议**：把 `f_llm.md:403` 改成「流程步骤没有内置超时；`LoomTimeout` 仅用于 `MemoryRecorderTask.recordWithTimeout`」，或在 `LoomRunner` 的步骤闭包外加可配超时（与第 15 部分的 `waiter.get(timeout)` 修复一起做）；`loom.md:204-206` 同步限定适用范围。

### [轻微][存量] §9 自称「全部环境变量」，实际漏 5 个键（其中一个全仓无文档且零调用）

- **位置**：`f_llm/doc/f_llm.md:566-575`（§9 配置表）
- **来源**：存量
- **判据**：review-checklist §13（配置项表与源码不符）+ §14.2（配置项遗漏）
- **证据**：静态确定 —— 表头写「全部环境变量，启动时读一次」，但 `LLMConfig.cj` 里另有 5 个键未列：`llm_channelSendRoots`（`:37`，`EmailChannel.send` 用它做附件白名单，`:205`）、`llm_a2aEnabled`（`:66-68`）、`llm_memoryUserId`（`:32`，`Memory.cj:126` 读取）、`llm_faithfulMemoryPath`（`:40`，`FaithfulMemory.cj:34` 读取）、`llm_auto`（`:34`）。前四个在 README / `loom.md` 有零散记载；`llm_auto` 在 README / README_en / `doc/**` 全部检索不到，`LLMConfig.isAuto()`（`:47-49`）也零调用者。
- **描述**：按「全部」理解会漏配通道附件根目录与 A2A 开关；`llm_auto` 则是既无文档、也无内部使用者的暗配置。
- **建议**：补齐 4 个在用键；`llm_auto` 与 `isAuto()` 要么接线（明确谁该读它）要么删除并在启动时 `warn`（与 §4.1 处理废弃键的方式一致）。

### [轻微][存量] §1 模块结构把 mapper 与 dialect 的目录写反，且漏了 `channel/` 包

- **位置**：`f_llm/doc/f_llm.md:42-43`（结构树 `:30-64`）
- **来源**：存量
- **判据**：review-checklist §13（文档过期 / 结构描述与实现不符）
- **证据**：静态确定 —— `src/llm/` 下是 `ChatCompletionsMapper.cj`、`ResponsesMapper.cj`、`ChatStreamAccumulator.cj`、`ResponsesStreamAccumulator.cj`；`src/llm/openai/` 只有 `ProviderDialect.cj` / `ProviderDialects.cj` / `DeepSeekDialect.cj`。文档把两组写到了相反的位置。同节结构树也没有 `channel/`，而 `src/channel/` 已有 6 个 `.cj`（含 `ChannelMediator` / `EmailChannel`）。
- **描述**：结构树是新人定位代码的第一入口，写反会让人在 `openai/` 里找不到 mapper、在 `llm/` 里找不到方言；通道能力在总览里完全不可见。
- **建议**：把 42、43 两行对调，并在结构树补 `channel/  第三方平台通道（契约/中介者/邮件/工具）`。

### [轻微][存量] 「`memory.search` 与 `knowledge.search` 保持一致」不成立

- **位置**：`f_llm/doc/f_llm.md:425`（§6.7 约定）
- **来源**：存量
- **判据**：review-checklist §13（返回结构与实现不符）
- **证据**：静态确定 —— memory 返回 `{id,title,content,kind,score}`（`src/loom/LoomStoreGateway.cj:199-204`），knowledge 返回 `{docId,seq,score,content}`（`:118-129`）。两者的共同点只是「都带正文」。
- **描述**：字段名不同，模型按 `id` 取 knowledge 结果会取空；`doc/loom.md:558-559` 的两行反而是准确的，两份文档口径互相矛盾。
- **建议**：把 `:425` 改成「两者都带正文可直接喂模型，字段名不同（memory：id/title/kind；knowledge：docId/seq）」。

### [轻微][存量] §4.4 键布局表与 §4.5 表清单不完整

- **位置**：`f_llm/doc/f_llm.md:249-263`（§4.4）、`:269-280`（§4.5）
- **来源**：存量
- **判据**：review-checklist §13（关键信息缺失）
- **证据**：静态确定 —— 未列实际在用的 `f_llm:evo-lease:evolution`（`src/store/EvolutionLease.cj:174`，正是 §7.7 租约的落点）、`f_llm:meta:seq:conf`（`FStoreMetaStore.cj:83`）、`f_llm:meta:skill:title:`（`:238`）；`:269-280` 的「基础表」只列 8 张，`tables-pg.sql` 实际 20 张（`llm_memory_token` 倒排表、`llm_skill_version`、`llm_channel_binding` 等未出现）。
- **描述**：这两张表是运维排查「数据落在哪」的索引，缺项会让人误判「租约不在 f_store」「没有倒排表」。
- **建议**：补 3 个键；表清单改成「示例 + 以 `tables-pg.sql` 为准」，或列出全部 20 张。

### [轻微][存量] `known-limitations` §11 的「零代码引用」清单有一项不成立，两个默认常量取值与文档相反

- **位置**：`f_llm/doc/known-limitations.md:135-141`
- **来源**：存量
- **判据**：review-checklist §13（文档与实现不符）+ §1（零引用结论须有全仓搜索依据）
- **证据**：静态确定 —— ①`PlanDto` 被 `src/loom/Planner.cj:152,164,260,278` 引用（`DataObject<PlanDto>.populate` 与三个 `planOf/questionsOf/assumptionsOf` 形参），不是「零调用方」；②`Stores.DEFAULT_CONTENT` / `DEFAULT_META` 的值是 `postgres` / `postgres`（`src/store/Stores.cj:31-32`），而文档与 `StoreSettings` 的默认实现是 `f_hydra` / `f_store`（`src/store/StoreSettings.cj:39-40`）。
- **描述**：这节的作用是「别删这些符号」，但其中一项判据错误；另两个常量若被外部宿主当默认值用，会得到与文档相反的结果（无库部署直接启动失败）。
- **建议**：把 `PlanDto` 从清单移除或改述为「由 `DataObject` 反射填充、字段不直接按名访问」；`DEFAULT_*` 改为引用 `StoreSettings.DEFAULT_*`，或在本节明确「历史值，不要用于选型」。

### [轻微][存量] `perf-baseline` 的自证公式与自己的第一个数据点矛盾

- **位置**：`f_llm/doc/perf-baseline.md:16-17`
- **来源**：存量
- **判据**：review-checklist §13（文档内部数据不自洽）
- **证据**：静态确定 —— 列出 5 个探针值后总结「即 `4 × rune 数 + 4,112 B`」，但 `1,000 rune: 4,064 B` 按该公式应为 8,112 B（实际只多 64 B）。其余四点（10,000 / 100,000 / 1,000,000 / 2,097,152）都与公式吻合。
- **描述**：这个公式正是「说明」里推导 2 MiB 理论峰值 8,392,720 B、进而论证「比 8 MiB 预算多 4,112 B 可接受」的依据；首个点对不上会让读者怀疑整套口径，也让下一轮复测无法判断哪个数可信。
- **建议**：核对 1,000 rune 的探针是否漏计（或改成「小规模下头/对齐开销约 64 B，稳定尺寸后为 4,112 B」），把公式与数据的适用范围写清。

### [轻微][存量] `perf-baseline` 说 ohos 上「不构建」，`cjpm.toml` 却配了该目标

- **位置**：`f_llm/doc/perf-baseline.md:45`
- **来源**：存量
- **判据**：review-checklist §13（文档与工程配置不符）
- **证据**：待确认 —— `f_llm/cjpm.toml:79-87` 明确给出 `[target.aarch64-linux-ohos]` / `[target.x86_64-linux-ohos]` 的 `compile-option`（`--dy-std -ldl`，即去掉 local-mode）与 `bin-dependencies`；仓库的 `docs/LocalMode.md:850` 只说「ohos 构建需要条件编译排除，或保留独立非 local 路径」，没有「本模块不构建」的结论。未跑构建，无法判定「不构建」的依据。
- **描述**：若实际能构建，正确表述应是「ohos 目标不启用 local mode」；若确实不构建，应说明卡在哪（工具链 / 依赖），否则读者会以为没有 ohos 产物。
- **建议**：改成「ohos 目标不启用 local mode（`cjpm.toml` 的 target 段覆盖 compile-option，需条件编译排除 local 路径）」，或补一句排除机制的出处。

### [轻微][存量] spec 引用不存在的 `ChannelProviders` 类型与 `fromConf` 工厂

- **位置**：`f_llm/doc/spec/add-channel-mediator/design.md:40`；`f_llm/doc/spec/add-channel-mediator/tasks.md:12,13,25`
- **来源**：存量
- **判据**：review-checklist §13（示例代码不能用 / API 名不存在）
- **证据**：静态确定 —— 全仓无 `ChannelProviders` 类；provider 表在 `ChannelMediator.registerProvider`（`src/channel/ChannelMediator.cj:55`）、`providerPlatforms()`（`:71`）、`create(conf)`（`:83`，只收 `conf`、不收 `platform`）；`EmailChannel.cj:388` 的顶层自动注册用的也是 `ChannelMediator.registerProvider`。`EmailChannel` 没有 `fromConf` 静态工厂（grep 零命中），生产实现由 `FEmailTransport` + 构造器组装。
- **描述**：tasks 里 4 条已勾选任务都以 `ChannelProviders` 为验收对象，读者照它写第三个平台实现会编译失败；`create(platform, conf)` 与实现 `create(conf)` 的签名差也只写在 design 里。
- **建议**：把 4 处改名为 `ChannelMediator.registerProvider` / `providerPlatforms` / `create`，design D2 的示例代码同步改成实际的 `ChannelMediator.registerProvider(...)` 与 `EmailChannel(...)` 构造方式。

### [轻微][存量] A2A 规格两处细节与实现不符：正文回落取流程名、自动流程名格式不同

- **位置**：`f_llm/doc/spec/add-loom-a2a/design.md:40-42`；`f_llm/doc/spec/add-loom-supervisor/design.md:76`
- **来源**：存量
- **判据**：review-checklist §13（规格与实现漂移）
- **证据**：静态确定 —— ①规格要求「`outcome.message` 为空时用流程结果的事件文本」，`SupervisorAgent.map` 实际回落 `outcome.flow`（`src/loom/A2aBridge.cj:60-73`），即返回流程名而非产出；②设计写自动流程名 `auto-<yyyyMMddHHmmss>`，实现是 `auto-${秒级时间戳}`（`Supervisor.cj:233-246`），`loom.md:117` 的「秒级时间戳」才与实现一致。
- **描述**：A2A 客户端在 `message` 为空时会拿到一个流程名当结果正文；按设计文档做日志/审计规则的人会解析不到预期的 14 位时间格式。两处都不影响主链路，但属于「规格已归档、实现未对齐」。
- **建议**：`map` 为空时改用 `outcome.result` 的 `data`（与规格一致），或把规格改成 `outcome.flow`；设计文档的命名格式改成 `auto-<epoch 秒>` 并说明撞名顺延规则。

### [轻微][存量] `loom.md` 说 `MAX_TURNS` 保留「开头几步 + 最后几步」，实现只保留最后 200 条

- **位置**：`f_llm/doc/loom.md:244`
- **来源**：存量
- **判据**：review-checklist §13（注释/文档与实现不符）
- **证据**：静态确定 —— 超过上限时 `LoomContextLog.record` 只从 `turns.size - (MAX_TURNS - 1)` 开始拷贝，然后追加本条（`src/loom/LoomContextLog.cj:79-88`），即丢掉全部早期轮次，保留「最后 199 条 + 当前」，没有「开头几步」的保留逻辑。
- **描述**：文档用这个理由解释「长流程快照不会无限增长」。实际语义是「只留尾部」，提炼看不到流程开头（系统提示、首步事实），与文档给出的质量预期不符。
- **建议**：改成「超出后只保留最近 200 轮，开头轮次被丢弃（如需保留首轮，另行实现采样策略）」；若要保留开头，改成「首轮 + 最近 N-1 轮」。

<!-- 第 3 部分 -->

### [一般] MCP 输入模式清洗口径：规格要求「只保留四个键」，实现保留全部非 `$` 键

- **位置**：`f_llm/doc/spec/f-llm-openai-compat/specs/llm-tool-calling/spec.md:81-83`
- **来源**：存量（快照模式无基线）
- **判据**：review-checklist §13（规格与实现漂移）
- **证据**：静态确定 —— ①规格场景写「清洗后只保留 `type` / `properties` / `required` / `additionalProperties`」；②`src/mcp/McpToolSource.cj:128-152` 的 `sanitizeSchema` 只跳过 `$` 前缀键，`description` / `items` / `enum` / `default` 全部原样保留；③`McpToolSource.cj:52` 的类注释还写着「`additionalProperties` 一律剥掉」，与 `:128-131` 的实际规则相反；④`McpToolSource_test.cj:75-76` 只断言 `additionalProperties` 保留，没有任何「只保留四键」的用例。
- **描述**：规格的验收口径（只留四键）会**删掉 `description`、`items`、`enum`**——这些正是模型理解工具参数所必需的字段；实现按 2026-10-28 的修正（`design.md:294`）改成了「只剥 `$` 元信息键」，规格没跟着改。按规格做验收会判实现不合规，按实现做验收则规格的这条 Scenario 无法通过；两种读法还会导致下游对工具 schema 的预期不一致。
- **建议**：把 `spec.md:81-83` 改成与 `design.md:294` 一致的口径——「剥掉以 `$` 开头的元信息键，`additionalProperties` 与 `description` / `items` / `enum` 原样保留，`type` 为数组时取第一个非 `null` 类型」；同时修掉 `McpToolSource.cj:52` 的过期注释。

### [一般] `response.failed` 只读顶层 `message`，规格要求的「上游错误码」永远不出现在异常里

- **位置**：`f_llm/doc/spec/f-llm-openai-compat/specs/llm-protocol-compat/spec.md:73-75`
- **来源**：存量（快照模式无基线）
- **判据**：review-checklist §13（规格与实现不符）+ §11（错误处理丢失上游信息）
- **证据**：静态确定 —— ①规格要求「收到 `response.failed` 或 `error` 事件 → 调用失败，异常中包含上游错误码」；②`src/llm/ResponsesStreamAccumulator.cj:62-67` 只在事件的**顶层**取 `message`，取不到就退化成字面量 `'response.failed'`，全文件没有任何读取 `code` 的分支；③异常在 `:80-82` 拼成 `responses stream failed: ${failure}`；④该 `result()` 在 `src/llm/LLM.cj:268-272` 被调用，位置在流式 `try` 块（`:231-254`）**之外**，所以它既不会被包成带 `requestId` / 阶段的 `LLMException`，也不会转移到下一个平台。
- **描述**：Responses API 的 `response.failed` 事件把错误放在 `response.error.{code,message}` 里，顶层通常没有 `message`，因此异常消息恒为 `responses stream failed: response.failed`，既没有 code 也没有上游说明。排障时无法区分「模型拒绝」「配额不足」「参数非法」；叠加 `result()` 在 try 之外，这条失败还是全模块唯一不带 `requestId` 的流式异常，且不会按「可重试」规则换平台（与 design §6 的错误语义表也不一致）。
- **建议**：`ResponsesStreamAccumulator.feed` 的 `response.failed` 分支改为读 `response.error.message` / `response.error.code`（缺省再回落顶层 `message`），并把 code 带进 `LLMException`；补一条用真实事件体（含 `response.error.code`）的用例。

### [一般] 附件发送校验未落实设计承诺的「必须是普通文件、不能是符号链接」

- **位置**：`f_llm/doc/spec/fix-channel-attachment-safety/design.md:39`
- **来源**：存量（快照模式无基线）
- **判据**：review-checklist §13（设计与实现不符）+ §10（外部输入校验）
- **证据**：静态确定 —— 设计写「校验：`canonicalize()` 后必须以某个根为前缀、`isRegular()` 为真、不能是符号链接（`Path` 的 canonical 与实际不同即视为链接）」；`src/channel/EmailChannel.cj:220-246` 的 `checkAttachment` 只有 `exists` → `canonicalize` → 前缀比较 → `isDirectory`（`:239`），`f_llm` 内 `isRegular` / `isSymbolicLink` 零命中（同仓 `f_io/src/ExtendPath.cj:86,90` 已在用 `FileInfo.isRegular()` / `isSymbolicLink()`，接口是现成的）。
- **描述**：两处承诺没落地：①没有 `isRegular`，落在允许根目录内的 FIFO / 设备文件 / socket 会通过校验并被当附件发出（`send` 只判空、越界、目录）；②没有符号链接判定，根目录内「指向同根另一文件」的链接会被放行（指向根外的链接因 canonical 越界而被拒，这部分是安全的）。结果是设计文档声称已收口的「任意读」面仍留一个特殊文件与站内链接的口子。
- **建议**：`checkAttachment` 增加 `FileInfo(Path(actual)).isRegular()` 判断，并用 `FileInfo(Path(attachment.path)).isSymbolicLink()` 直接判链接（两者都是 std.fs 现成接口，`f_io` 已在用）；或把 `design.md:39` 收窄成「只校验前缀 + 非目录」，明确特殊文件与站内链接不在防护范围。

### [一般] `Redactor` 的掩码阈值与设计相反：设计写「长度 < 12 全掩码」，实现是「≤ 8」

- **位置**：`f_llm/doc/spec/f-llm-openai-compat/design.md:246`
- **来源**：存量（快照模式无基线）
- **判据**：review-checklist §13（文档承诺与实现相反）+ §10（敏感数据进日志）
- **证据**：静态确定 —— 设计 §9 写「前 4 + `****` + 后 4（长度 < 12 全掩码）」；`src/util/Redactor.cj:25-35` 是 `if(secret.size <= 8){ '****' } else { 前4 + '****' + 后4 }`。`doc/spec/f-llm-openai-compat/tasks.md:74` 把这次偏差记成「实现取更保守的『短于等于前后可见位数就不露』」，方向说反了：`<= 8` 比 `< 12` **更宽松**。
- **描述**：9–11 字符的密钥/令牌会输出 8 个明文字符（只掩中间 4 位），而设计承诺的是整串掩码。对 `auth`、`Authorization`、`*Key*/*Secret*/*Token*` 这些字段来说，9–11 位正是短口令与部分测试 key 的常见长度；一旦进日志，等于把密文还原到只差一位。文档还让人以为实现更保守，掩盖了这个差异。
- **建议**：把阈值改回 `< 12`（与设计一致），或明确把设计改成 `≤ 8` 并在 tasks 里把「更保守」的表述纠正为「更宽松，接受 9–11 位部分暴露」；无论选哪个，都要补一条 9/11 字符密钥的断言用例。

### [一般] 配置来源的失败时机与报错方式与规格不符：规格要「启动失败 + 首载失败报错」，实现是懒加载 + 只记日志

- **位置**：`f_llm/doc/spec/f-llm-openai-compat/specs/llm-conf-routing/spec.md:21-39`（未知来源要「启动阶段失败」；首载失败要「调用报错」）
- **来源**：存量（快照模式无基线）
- **判据**：review-checklist §13（规格与实现不符）+ §11（错误被降级为日志）
- **证据**：静态确定 —— ①`src/llm/LLMConfs.cj:47-73` 的 `holder()` 是懒建：`createHolder()` 在第一次业务调用时才执行，全仓没有任何启动期预热调用（`grep "LLMConfs.holder()" src` 只命中 `LLM.cj:99`、`Embedding.cj:60,99`、`LLMCandidateProvider.cj:40` 这些请求路径）；②`src/llm/LLMConfsHolder.cj:259-261` 对 `source.load()` 的异常只 `log.error` 并保留旧快照，首次装载失败同样不抛；③`LLMConfsHolder.cj:111-121` 的 `ensureFresh` 只在**装载成功**时更新 `loadedAt`，失败后每次调用都会再同步打一次来源。
- **描述**：规格给出的三个承诺没有一个按原样成立：未知来源 `llm_confSource` 不会在启动阶段失败，而是在第一条业务请求上抛 `IllegalArgumentException`（`src/service/LLMConfSource.cj:168`）；文件不存在 / JSON 非法时首次装载失败只留一条 error 日志，调用方拿到的是「no available llm conf for: X, available: []」，真实原因（哪个文件、哪一行 JSON）在异常里看不到；又因为没有失败退避，配置源故障期间**每个请求**都要同步付一次失败查询的延迟。这与同仓 `fountain-baseline.md` §5「配置只在启动读一次」的预期也不一致（启动期没有任何校验点）。
- **建议**：二选一并写进文档——（a）`StoreWiring` / `ChannelBootstrap` 之类的装配入口显式调用一次 `LLMConfs.holder().ensureFresh()`，把未知来源与首次装载失败变成启动失败；（b）把规格改成「首次调用时装载，失败保留空快照并记 error」，同时把装载异常原文带进 `LLM.chatByName` 的「no available」消息，并给 `ensureFresh` 加失败退避（例如失败后 5s 内不再重试）。

### [一般] 设计称「刷新整体替换、读路径无锁」，但快照引用的读写没有同步

- **位置**：`f_llm/doc/spec/f-llm-openai-compat/design.md:136-142`
- **来源**：存量（快照模式无基线）
- **判据**：review-checklist §12.1（可见性 / 发布逸出）
- **证据**：待确认 —— 缺仓颉语言内存模型对「普通字段跨线程发布」的可见性保证。代码层面静态可见：`src/llm/LLMConfsHolder.cj:82` 的 `snapshot` 是普通 `var`；写点在 `:255`，位于 `synchronized(mutex)` 块**之外**（`:225-229` 的锁只保护 `refreshing` 置位，`:262-264` 的锁只保护复位）；读点在 `:112`（`ensureFresh`）、`:126`（`candidates`）、`:131`（`all`）、`:104-108`（`version`），全部不取锁。
- **描述**：设计把「读路径无锁」当作安全前提，正确性因此依赖引用赋值的原子性与跨线程可见性。`refreshing` 的加解锁只给写线程之间建立顺序，读者与写者之间没有 happens-before：理论上读者可以一直看到旧快照（版本号不前进 → `ensureFresh` 每请求都触发一次刷新尝试），或者看到新 `snapshot` 而 `version` 仍是旧值（`balancerFor` 的版本判断失效，权重表与配置错配）。这与该文件 §3.3「调度器必须随快照版本重建」的约束直接相关。
- **建议**：先确认语言语义（`std.sync` 是否提供原子引用 / 是否需要显式 fence）；若与 Java 普通引用一致，把快照发布改成「锁内写 + 锁内读一次引用」或原子引用，读路径仍可保持无锁（读一次不可变快照即可）。补一条多线程并发刷新 + 高频读的最终状态断言用例。

### [一般] `design.md` §5 的对外 API 与「保留 `LLMContextMediator`」均与实现相反，且与同文件附录冲突

- **位置**：`f_llm/doc/spec/f-llm-openai-compat/design.md:194-200`
- **来源**：存量（快照模式无基线）
- **判据**：review-checklist §13（API 与源码不符 / 文档过期）
- **证据**：静态确定 —— ①`design.md:194-198` 写 `LLM.chat(req: LLMRequest): LLMResponse`、`LLM.chatStream(req, onDelta: (LLMDelta) -> Unit)`、`LLM.respondStream(req, onEvent: (ResponsesEvent) -> Unit)`；实际门面是 `LLM.chat(candidates: ArrayList<LLMConf>, params: LLMParams): LLMResp`（`src/llm/LLM.cj:68`）、`LLM.chatByName(llmName, params)`（`:90`）、`LLM.chatStream`（`:186`）、`LLM.respondStream`（`:194`），`LLMRequest` / `LLMResponse` / `LLMDelta` 在 `src/` 内零命中；②`design.md:200` 写「`LLMContextMediator` 保留并改为按 `llmName` 访问，新增 `candidates()/peekNext()/isCircuitOpen()/refreshNow()`」，而该类已被删除——同一文件 `:307` 自述「已整体删除」，全仓仅 `src/llm/ContextPruner_test.cj:180` 的注释提到它，那四个方法实际在 `src/llm/LLMConfsHolder.cj:104-190`；③`proposal.md:3`、`:27` 已声明 `LLMRequest/LLMResponse` 未进代码，只有 §5 正文没改。
- **描述**：§5 是「对外 API」章节，是全文档被下游引用最多的一段。按它写调用会直接编译失败，且读者会以为旧中介者仍是扩展点、去 `LLMContextMediator` 上找 `candidates()/peekNext()`。同一份文档的正文与附录给出相反结论，属最容易被当成「现行契约」的一类过期。
- **建议**：§5 改为实际签名（`chat/chatByName/chatStream/respondStream` + `LLMParams`/`LLMResp`/`LLMHooks`），并把「`LLMContextMediator` 保留」一句改成「已删除，选号/熔断/刷新统一走 `LLMConfsHolder`（`candidates()/peekNext()/isCircuitOpen()/refreshNow()`）」。

### [轻微] 流式异常只区分 `connect` / `read`，设计承诺的「首包 / 中途」阶段信息不存在

- **位置**：`f_llm/doc/spec/f-llm-openai-compat/design.md:202-212`（§6 错误语义表「流空闲超时 … 保留 `requestId` 与阶段（首包/中途）」）
- **来源**：存量（快照模式无基线）
- **判据**：review-checklist §13（文档承诺未落地）
- **证据**：静态确定 —— `src/llm/LLM.cj:248-253` 把**所有**流内异常统一包成 `phase: read`；`:256-261` 对 `status >= 400` 用 `phase: connect`。全文件没有「首包 / 中途」的判定，也没有记录首包时间点。
- **描述**：TTFT 超时（首包迟迟不来）与流到一半断线在日志里都是 `phase: read`，排障时无法判断是「上游没开始回」还是「回了一半断了」——而这恰好是选择「换平台」还是「重试同平台」的关键依据。规格侧 `specs/llm-protocol-compat/spec.md:53` 也只要求「带阶段信息」，两边都没落到可实现的口径上。
- **建议**：在 `stream()` 里记录 `firstDelta` 布尔（收到首个非空 delta 时置位），catch 时按它输出 `phase: first_packet` / `phase: mid_stream`；把设计 §6 的这一行改成这两个具体取值。

### [轻微] 设计 §2.4 说 `llm_confSource` 可写「实现名」，但 `static` 源无法通过配置选中

- **位置**：`f_llm/doc/spec/f-llm-openai-compat/design.md:121-132`
- **来源**：存量（快照模式无基线）
- **判据**：review-checklist §14.1（接线缺失：能力存在但无配置入口）
- **证据**：静态确定 —— 设计的内置实现表列了 `StaticConfSource`（「代码内静态注册，适合测试与嵌入式」），并写「选择方式：`llm_confSource`（默认 `database`），可写实现名或 `name:path` 形式」；`src/service/LLMConfSource.cj:153-170` 的 `createConfSource` 只认 `database` / `env` / `file:<path>`，其余一律抛 `unknown llm conf source: ..., available: database / env / file:<path>`；`StaticConfSource`（`:54`）只在测试里通过 `LLMConfs.setHolder` 使用。
- **描述**：按设计把 `llm_confSource` 配成 `static` 会在首次调用时启动失败，且错误信息里的「可用来源」也不含它。对嵌入式/测试场景，文档给了一条实际不存在的选择路径。
- **建议**：要么在 `createConfSource` 里支持 `static`（返回一个从全局注册表读的来源，并在文档里写清注册 API），要么把设计表里 `StaticConfSource` 的说明改成「仅经 `LLMConfs.setHolder` 注入，不参与 `llm_confSource` 选择」。

### [轻微] 提案正文称 `ModelCapabilities` 未进代码，实际已实现并被主路径调用

- **位置**：`f_llm/doc/spec/f-llm-openai-compat/proposal.md:3`、`:24`、`:66`
- **来源**：存量（快照模式无基线）
- **判据**：review-checklist §13（文档结论与实现相反）
- **证据**：静态确定 —— 提案三处都写「`ThinkingCapability` / `ModelCapabilities` … 未实现 / 未进代码」；实际 `src/llm/ModelCapabilities.cj:24-73` 提供 `ModelCapabilities.resolve` / `blocksTemperature` 与 `ThinkingPolicy.apply`，`src/llm/LLM.cj:142`、`:226` 在每次请求构造报文后调用 `ThinkingPolicy.apply`，`ModelCapabilities_test.cj` 覆盖三级解析。
- **描述**：同一变更的 `design.md:351`（verify 修复）已经写明「新增 `ModelCapabilities.resolve()` + `ThinkingPolicy.apply()`」，提案的「状态（2026-10-28）」与偏差表没回填。读者按提案会以为思考能力只能是 `conf.alwaysThinking` 一条规则，从而重复实现或误判线上行为（`deepseek-flash` 恒思考、`embedding-3` 不支持思考都来自这张能力表）。
- **建议**：把提案 `:3`、`:24`、`:66` 改成「`ThinkingCapability` 未实现；`ModelCapabilities` + `ThinkingPolicy` 已在 verify 阶段补齐（见 design §verify 修复）」，避免与 design 结论冲突。

### [轻微] 任务进度在两份文档里不一致：58/63 与 59/64

- **位置**：`f_llm/doc/spec/f-llm-openai-compat/proposal.md:3`、`f_llm/doc/spec/f-llm-openai-compat/tasks.md:5`
- **来源**：存量（快照模式无基线）
- **判据**：review-checklist §13（同一变更的文档之间口径不一致）
- **证据**：静态确定 —— 提案写「任务进度 58/63，剩余 9.2–9.6 为其他平台联调」；tasks 写「59/64 完成，5 项 deferred（9.2–9.6）」。按 `tasks.md` 逐条点数：1.x 3 + 2.x 7 + 3.x 10 + 4.x 7 + 5.x 6 + 6.x 10 + 7.x 10 + 8.x 4 + 9.x 7（含 `9.7 腾讯云 tokenhub`）= **64**，deferred 5 项 ⇒ 59 完成，tasks 侧正确，提案侧少了 9.7。
- **描述**：同一变更的两份文档给出不同的完成度，归档核对时分不清哪份是准的；9.7 是后补条目，提案侧没有同步。
- **建议**：提案的进度行改为「59/64（9.2–9.6 deferred）」，或直接删掉数字改为指向 `tasks.md`，避免二次漂移。

### [轻微] `cover-loom-test-gaps` 提案的用例数与文件数与实际不符（4 条 / 4 文件 vs 5 条 / 3 文件）

- **位置**：`f_llm/doc/spec/cover-loom-test-gaps/proposal.md:15`、`:29`
- **来源**：存量（快照模式无基线）
- **判据**：review-checklist §13（文档与实现不符）
- **证据**：静态确定 —— 提案 `:15` 写「补 4 条用例（第 5 条并发见下）」，`:29` 写「4 个测试文件，新增 5 条用例」；`tasks.md:5-15` 列了 5 条用例，实际分布在 3 个文件：`src/channel/EmailChannel_test.cj:325,337`、`src/loom/LoomContextMemory_test.cj:358,376`、`src/loom/StoreFunctions_test.cj:93`。
- **描述**：「第 5 条并发」的编号暗示 5 条里有 1 条是并发用例，实际第 5 条是附件绝对路径那条，并发用例明确「不补」（design D4）。文件数 4 也多于实际的 3。数字对不上会让归档核对误以为少补了一条用例。
- **建议**：改成「补 5 条用例、涉及 3 个测试文件；并发用例不补（见 design D4）」，删掉容易误解的「第 5 条」编号。

### [轻微] `f-llm-openai-compat/design.md` 有 10 处小节标题粘在正文行尾，附录表格行断裂，另有一处脚本路径不存在

- **位置**：`f_llm/doc/spec/f-llm-openai-compat/design.md:292`、`:294`、`:296-300`、`:305`、`:317`、`:323`、`:328`、`:333`、`:338`、`:343`、`:347`、`:355`、`:284`
- **来源**：存量（快照模式无基线）
- **判据**：review-checklist §13（文档可读性 / 链接失效）
- **证据**：静态确定 —— 全文 26 个 `###` 标题里有 10 个不是行首（`:300` `### 非平台联调部分…`、`:305` `### 旧链路迁移…`、`:317` `### deepseek-flash 识图…`、`:323` `### 多模态与 embedding 迁移…`、`:328` `### 旧搜索链路清理…`、`:333` `### Responses 多模态…`、`:338` `### 腾讯云 tokenhub…`、`:343` `### 联调边界…`、`:347` `### verify 修复…`、`:355` `### verify WARNING 修复…`），全部接在上一条 bullet 末尾；`:292` 的表格行尾部直接串了 `|- 工具循环 \`LLMToolLoop\` …`，`:294` 与 `:296` 同样把两条内容并进一行；`:284` 指向的 `.autocode/tmp/fllm_db_test.sh` 在当前工作区不存在（`.autocode/tmp/` 下无 `*fllm*`）。
- **描述**：这些小节是「方言注册、多模态、余额、verify 修复」等关键结论的落点，渲染后不会出现在目录里，读者按目录跳转会漏掉整段；断行还把「工具循环放 tool 包」这类设计原因塞进表格单元格。脚本路径失效则让真库验证无法照做。
- **建议**：把 10 处标题前的空行补齐（标题独立成行），`:292` 的表格行补 `|` 收尾并把后续 bullet 拆出，`:284` 的脚本路径改成仓库内实际位置或注明「临时脚本，不入库」。

### [轻微] 归档规格的「SQL 只出现在 DAO 层」验收场景在归档时已被违反，且未记录例外

- **位置**：`f_llm/doc/spec/archive/2026-10-31-f-llm-store-wiring/specs/llm-store-wiring/spec.md:14-17`
- **来源**：存量（快照模式无基线；`git blame` 依据：`cdea037a40 2026-10-30`）
- **判据**：review-checklist §13（规格与实现漂移；归档变更按「当时结论是否自洽」核对）
- **证据**：静态确定 —— 该场景声明 `PostgresMemoryRepository` / `MySqlMemoryRepository` 源码「不出现 `SELECT` / `INSERT` / `UPDATE` / `DELETE` 字面量」；`src/store/postgres/MemoryRepository.cj:56` 与 `src/store/mysql/MemoryRepository.cj:60`、`:127` 直接 `executor(DRIVER).setSql('DELETE FROM llm_memory_token …')`，注释说明是「DAO 宏对纯 DELETE 方法生成有缺陷」的绕行。这些行由 `cdea037a40` 于 2026-10-30 引入，早于该变更 2026-10-31 的归档，而 `tasks.md:3-4`（0.1/0.2）全部勾选。
- **描述**：归档规格把一个已知不成立的验收标准记为已通过，绕行原因只写在代码注释里。后续按规格做 DAO 迁移的人会以为 Repository 层已经没有 SQL，改动 DAO 宏后也不会去检查这两处直写。
- **建议**：在该 spec 的 Scenario 后补一句例外「纯 DELETE 方法因 DAO 宏缺陷暂由 Repository 直写，待宏修复后移除」，或在归档目录里加一条偏差记录（与 `f-llm-openai-compat/design.md` 的「实现偏差」表同格式）。

### [轻微] 余额金额解析失败静默回落 0.00，与规格「不得返回 0」的口径冲突

- **位置**：`f_llm/doc/spec/f-llm-openai-compat/specs/llm-balance-query/spec.md:49-52`
- **来源**：存量（快照模式无基线）
- **判据**：review-checklist §13（规格与实现不符）+ §11（失败路径被当成成功）
- **证据**：静态确定 —— 规格写「未实现或无法查询的平台 SHALL 抛出明确的『不支持』异常，SHALL NOT 返回 0 或空快照」，并在 `BalanceQuerier.cj:64-66` 的接口注释里重申「余额为 0 与『查不到』是两件事」；但 `src/balance/BalanceUnits.cj:40-47` 的 `parse` 用 `catch(_: Exception){ 0.0f64 }` 吞掉解析失败，`toYuan` 再 `format` 成 `"0.00"`，`BalanceSnapshot.totalValue` 也是 0.0。
- **描述**：上游把金额字段改成对象、带千分位、或返回 `null` 时，快照落成 `0.00` 并参与低余额判断（`BalanceQuerier.cj:135-146`：`totalValue < threshold` 就会告警）——产生**假告警**，把「字段格式变了」误报成「余额耗尽」。这正好违反规格自己写下的区分原则。
- **建议**：`parse` 改成返回 `?Float64`，`toYuan` 在解析失败时抛 `BalanceUnsupportedException`（或带平台与字段名的专用异常），让「查不到」走异常路径；`BalanceMediator.queryAll` 已有按平台 catch 并 `warn` 的逻辑，不会打断其它平台。

### [轻微] `fix-channel-attachment-safety/design.md` D4 标题与自身结论、与实现三者不一致

- **位置**：`f_llm/doc/spec/fix-channel-attachment-safety/design.md:53-57`
- **来源**：存量（快照模式无基线）
- **判据**：review-checklist §13（文档过期 / 语义与注释不符）
- **证据**：静态确定 —— D4 标题写「净化发生在 `receive` 调用 `save` **之前，而不是 `freeName` 内部**」（`:53`），紧接着的「替代」段却写「两层都净化。**采纳**——`save` 与 `freeName` 都调 `bareName`」（`:57`）；实现与「采纳」一致而与标题相反：`freeName` 第一行即 `bareName(filename)`（`src/channel/EmailChannel.cj:120`），`save` 自身不净化、只经 `freeName` 落盘（`EmailChannel.cj:161`，无直接 `bareName` 调用）。
- **描述**：标题是 D4 的结论行，读者只读标题会以为 `freeName` 依赖调用方先净化，从而在新增调用点重复净化或漏掉净化；而 D4 的正文已经改口，同一段落的结论与理由互相打脸。
- **建议**：把标题改成「净化在 `freeName` 内完成，`save` 只经 `freeName` 落盘」，正文保留「两层都净化」的采纳结论（与代码一致）；顺带说明 `receive` 在调用 `save` 前不做净化。

### [轻微] 已归档变更的 `tasks.md` 里 5.3/5.4 落在「移出本变更」小节下，与移出说明矛盾

- **位置**：`f_llm/doc/spec/archive/2026-10-30-f-llm-memory-storage/tasks.md:43-58`
- **来源**：存量（快照模式无基线）
- **判据**：review-checklist §13（归档文档按「当时结论是否自洽」核对）
- **证据**：静态确定 —— `:43` 的「## 5. 集成与回归」是空节；`:45` 起是「## 移出本变更（由后继变更 `f-llm-store-wiring` 承接）」，只列 5.1/5.2 并给出三条移出原因与后继范围；随后 `:57`/`:58` 又把已勾选的 `[x] 5.3 跑 fboot build + cjpm test 全量`、`[x] 5.4 把 propose 产物同步到 …` 排在同一节末尾，读起来像「5.3/5.4 也被移出」。
- **描述**：5.3/5.4 实际是在本变更内完成的集成与文档同步（`5.3` 的全量回归是该变更的收尾动作），却被排进「移出」叙述里，与 5.1/5.2 的移出结论并列。归档核对时会误以为集成与回归也没做。
- **建议**：把 5.3/5.4 移到「## 5. 集成与回归」节下，或把「移出本变更」改成独立的 `## 6.` 节。

<!-- 第 4 部分 -->

### [严重][存量] #1 水位线的「超量不丢」保证不成立：取数始终是「最新 500 条」，spec 的「超量」场景不可达

- **位置**：
  - 承诺：`f_llm/doc/spec/fix-evolution-watermark/specs/loom-flow/spec.md:15-18`（Scenario「素材超过单轮上限」：本轮只取到 500 条、最大 `at = 200`，库里还有 `at = 201…900`，水位线 200，下一轮仍能取到）
  - 取数：`f_llm/src/loom/SkillEvolutionJob.cj:266-270`（`load` 无 `since` 参数）、`:272-306`（`experiencesOf` 固定 `"offset":0,"limit":<limit>`，既不下推 `since` 也不指定顺序）
  - 过滤与推进：`f_llm/src/loom/SkillEvolutionJob.cj:247-257`（`fresh` 只留 `at == 0 || at > since`）、`:234-241`（水位线 = 本轮 `fresh*` 集合的最大 `at`）
  - 存储顺序：`f_llm/src/loom/LoomStoreGateway.cj:147-163`（走 `listByKind`）、`f_llm/src/dao/mysql/MemoryDAO.cj:141,153`、`f_llm/src/dao/postgres/MemoryDAO.cj:159,171`（均为 `ORDER BY save_time DESC`）；`f_llm/src/store/InMemoryStores.cj:122-141`（HashMap 遍历，顺序未定义）
- **来源**：存量（快照模式无基线；该 spec 与对应实现同属已归档变更 `fix-evolution-watermark`）
- **判据**：review-checklist §13（规格与实现漂移）+ §11（契约与实现不符）+ 严重度表「数据丢失」
- **证据**：静态确定 —— 查询没有 `since` 下推、SQL 明确 `save_time DESC`、水位线取「本轮结果集的最大 `at`」，三条事实串起来即可判定；spec 场景要求「取到的是最旧的一批」，与存储契约相反
- **描述**：该变更要消灭的是「单轮 `limit` 溢出导致永久跳过」，实现把水位线换成「本轮处理过的最大 `at`」，但**取数方向没改**：
  1. 某轮新增 700 条（`at = 1000..1699`），`load` 取 `ORDER BY save_time DESC LIMIT 0,500`，拿到的是 `at = 1200..1699`；
  2. `advanced = 1699`，水位线推进到 1699（`SkillEvolutionJob.cj:236`）；
  3. 下一轮 `load` 仍取最新 500 条，`fresh()` 用 `at > 1699` 过滤，`at = 1000..1199` 那 200 条**从未被取到、也永远不满足条件** → 永久跳过，且 `report.rejected/skipped` 里不会出现。

  也就是说 bug 从「since 之后的溢出」搬到了「窗口之下的溢出」，后果与原缺陷同类（静默丢样本）。`design.md:10-11` 否决分页取数的理由是「memory.list 不支持按 `at` 过滤」，但没有意识到「不支持过滤」同时意味着**无法保证返回最旧的一批**，所以 spec 的场景二在当前存储契约下不可达。放大因素：`StoreContracts.cj:48-64` 的 `listByKind` 默认实现是「取一页再过滤」，SQL 版虽带 `kind` 条件但仍是 DESC，单 kind 的实际批量会小于 500；内存后端按哈希序返回，同一份代码在不同后端下降级到哪个窗口不确定。
- **建议**：任选一条并补「新增 > `limit`」的回归用例（现有用例只覆盖单轮装得下的情形）：
  1. 给 `MemoryStore.list/listByKind` 契约加 `since`（`save_time > since`）并下推到 SQL `WHERE`，`load` 传 `state.lastRunAt()`；
  2. 或改按 `at` 升序游标取数（`ORDER BY save_time ASC, id ASC` + keyset），水位线语义不变；
  3. 或退一步：当返回条数 `== limit` 时**不推进**到该批的最大 `at`（只推进到批内最小值之前），并记 warn。
  无论哪种，都应把「返回顺序」写进 `StoreContracts.MemoryStore` 的接口注释，避免下一个调用方重踩。

### [一般][存量] #2 水位线在「本轮零素材」时仍推进到 `now`，与规格「MUST NOT 直接推进到当前时间」相反

- **位置**：`f_llm/doc/spec/fix-evolution-watermark/specs/loom-flow/spec.md:7-8`（承诺）；实现 `f_llm/src/loom/SkillEvolutionJob.cj:234-242`
- **来源**：存量（快照模式无基线）
- **判据**：review-checklist §13（规格与实现漂移）+ §11（错误处理缺失：静默跳样本）
- **证据**：静态确定 —— ①spec 写「水位线 MUST 推进到本轮实际参与处理的素材中最大的 `at`，MUST NOT 直接推进到当前时间；**没有带时间戳的素材时** MUST 保持原有按轮次推进行为」；②实现把两种情形合并成一个 `else`：`if (advanced > 0) { if (advanced > state.lastRunAt()) { state.markRun(advanced) } } else if (now > 0) { state.markRun(now) }`；`advanced == 0` 既包含「只有 `at = 0` 的知识文档」（设计 D3 认可），也包含「本轮一条新素材都没有」，后者被规格明确禁止；③design.md:17-20 只对 `at == 0` 情形给了理由，未覆盖零素材。
- **描述**：零素材那轮仍把水位线推到 `now`。`now` 在 `schedule` 里于 `run` 之前取得（`SkillEvolutionJob.cj:389`），所以本轮之后写入且 `at ≈ 真实时间` 的素材不会丢；但两类素材会被永久跳过：其一，写入方时钟慢于演进方、`at` 落在 `(lastRunAt, now)` 的回填/跨实例写入（状态存储支持 postgres/mysql 多后端，`doc/loom.md:349`；若多实例共享同一元数据库，这条成立）；其二，`at` 由别处提供（测试、导入、定时任务传固定值）而落在水位线之下。命中后该素材既不被处理也不报错，与 #1 是同一类后果。
- **建议**：把零素材与 `at == 0` 分开——只有「本轮确实取到了素材但全部 `at == 0`」才 `markRun(now)`；零素材直接不推进（或推进到 `min(now, 已观测最大 at)`）。同时补一条用例：`since = 100`、本轮零素材 → `lastRunAt()` 仍为 100；并把 spec:7-8 的「没有带时间戳的素材」写清是否包含零素材。
- **备注**：未定为严重，因为触发依赖「`at` 来源与演进进程时钟不同源或多实例提交晚于本轮读取快照」；若确认部署形态是多实例共享元数据库，本条应升为严重。

### [轻微][存量] #3 `fix-channel-attachment-safety` 的 tasks 声称「符号链接拒绝」用例已验证，实际不存在该用例

- **位置**：`f_llm/doc/spec/fix-channel-attachment-safety/tasks.md:18`（3.2 验证口径「4 条（根内成功、根外拒绝、符号链接拒绝、未配置拒绝）」）；`specs/platform-channel/spec.md:7`（MUST NOT 是符号链接）
- **来源**：存量（快照模式无基线）
- **判据**：review-checklist §13（验收口径与实现/用例不符）+ §14（承诺但未实现）
- **证据**：静态确定 —— ①`src/channel/EmailChannel_test.cj` 共 17 个用例，发送侧只有 `testSendAllowsAttachmentInsideRoots:210` / `testSendRejectsAttachmentOutsideRoots:233` / `testSendRejectsWhenRootsUnconfigured:258` / `testSendRejectsDirectoryAsAttachment:279`，全文件搜 `symlink` / `symbolic` 零命中；②实现 `EmailChannel.cj:220-246` 只做 `exists` → `canonicalize` → 前缀比较 → `isDirectory`（`:239`）；③代码侧的 `isRegular` / 符号链接缺口已由第 3 部分报为一般项（`f_llm.part3.md` 第 31 行起），本部分只计入「验收口径被替换」这一文档问题。
- **描述**：这条 tasks 勾选把一个**不存在**的用例登记为已验证，导致「安全约束已收口」的结论没有测试支撑：根目录内指向同根另一文件的符号链接、FIFO / 设备文件仍会通过 `send` 校验。第 4 条实际是「目录」用例，验收口径被悄悄替换过。
- **建议**：与第 3 部分的修复一起收口——`checkAttachment` 补 `FileInfo(...).isRegular()` + `isSymbolicLink()`，把 tasks 3.2 的「符号链接拒绝」改成真实用例（建软链 → 断言 `ok=false`、`transport.sent.size == 0`）；在补齐前把该勾去掉。

### [轻微][存量] #4 同一份 spec 对 email 必填项的口径不一致：spec 要求 `from`，实现与其它文档只要求 `user`/`smtpHost`

- **位置**：`f_llm/doc/spec/fix-channel-robustness/specs/platform-channel/spec.md:49`；实现 `f_llm/src/channel/ChannelBootstrap.cj:116-130`
- **来源**：存量（快照模式无基线）
- **判据**：review-checklist §13（同一能力的多处文档口径分叉）
- **证据**：静态确定 —— spec 写「email 平台 MUST 校验 `from`/`user`/`smtpHost` 非空」；`validate()` 只抛 `missing smtpHost`（`:120-122`）与 `missing user`（`:123-125`），没有 `from` 分支；`doc/loom.md:59` 写的是「email 必填 `user` / `smtpHost`」，`README.md:790` 的 `llm_channels` 行也未提 `from`；同变更 `tasks.md:13` 只要求「缺 `smtpHost` → skipped」。
- **描述**：`from` 留空在实现里是**合法**的——`EmailChannel.send` 在 `from` 为空时回落到 `conf.user`（`EmailChannel.cj:322-326`），这是设计意图，不是遗漏。因此 spec 的这条 MUST 是过严描述：按 spec 验收会判实现不合规，按实现写文档则会漏掉「回落」这个真实语义。
- **建议**：把 spec:49 改成「email 平台 MUST 校验 `user`/`smtpHost` 非空；`from` 可为空，发送时回落到 `user`」；顺手在 `doc/loom.md` 通道小节点明回落规则。

### [轻微][存量] #5 `fix-loom-experience-persona` 的设计与规格仍写 `kindOf`（单值），实现已改为 `kindsOf`（成功+失败两类）

- **位置**：`f_llm/doc/spec/fix-loom-experience-persona/design.md:13`、`specs/loom-flow/spec.md:7`；实现 `f_llm/src/loom/LoomStoreGateway.cj:147-149,384-400`
- **来源**：存量（快照模式无基线）
- **判据**：review-checklist §13（设计/规格与实现漂移）
- **证据**：静态确定 —— ①design D1 写「一行改动：`let kindFilter = kindOf(args, defaultKind)`」，spec 写「MUST 只返回 `kind=experience` 的记录」；②`list` 分支实际调 `kindsOf(args, defaultKind)`，该方法在 `defaultKind == 'experience'` 时返回 `['experience', 'experience_failed']` 两个 kind（`:391-394`）；③`doc/loom.md:294` 已把这个语义写成正式约定「不指定 `kind` 时**同时覆盖**两类经验」。
- **描述**：实现是对的（失败经验也是经验），滞后的是这份变更文档：它把一个已被后续变更取代的单值口径留在 design/spec 里，读者按它做验收会误判「失败经验不该返回」。
- **建议**：design.md:13 改为 `kindsOf`，spec.md:7 的措辞改成「只返回经验类记录（成功 `experience` 与失败 `experience_failed`）」，并指向 `doc/loom.md:294`。

### [轻微][存量] #6 `fix-loom-memory-owner` 以「≈60 字符」断言 docId 安全，但 `namespace` / `flow` 无长度与字符集约束

- **位置**：`f_llm/doc/spec/fix-loom-memory-owner/design.md:7,32`；实现 `f_llm/src/loom/LoomMemoryPolicy.cj:156,160-165`、`f_llm/src/loom/SkillEvolutionJob.cj:314-316`
- **来源**：存量（快照模式无基线）
- **判据**：review-checklist §13（设计结论缺前提）+ §11（长度/字符集边界未校验，失败被静默吞掉）
- **证据**：静态确定 —— ①design D1 称 `loom:<userId>:<namespace>:<flow>:<stamp>-<seq>` 同时解决「跨重启不撞号 + 按前缀过滤」，风险表写「字段是 `VARCHAR(128)`，实测格式 ≈ 60 字符，安全」；②列宽证据在 `f_llm/src/store/it/KnowledgeConformance_test.cj:47`（`doc_id VARCHAR(128) PRIMARY KEY`）；③`extract` 直接拼接 `policy.namespace` 与 `flowName` 写入 docId（`LoomMemoryPolicy.cj:156`），全仓没有任何长度/字符集校验，upsert 失败被 `catch (error: Exception) { () }` 吞掉（`:160-165`）；④`ownedBy` 用 `docId.startsWith('loom:<userId>:<namespace>:')` 判归属（`SkillEvolutionJob.cj:315`）。
- **描述**：两条都由「归属塞进字符串」带来：其一，`namespace` + `flowName` 超过约 90 字符时 docId 超 128，PG/MySQL 插入失败或报错被吞，知识静默不落库（记忆与经验仍写成功，所以从流程结果看不出少了一半）；其二，`namespace` 或 `flowName` 含 `:` 时前缀判定会串味——`namespace='work:daily'` 写入的 `loom:7:work:daily:x:1-1` 会被 `ownedBy(id, 7, 'work')` 判为本租户知识，正是 D4 声称要防的「串味」。两者都不需要恶意输入，命名习惯（`team:proj` 这类带冒号的命名空间）就能触发。
- **建议**：写入侧对 docId 做长度上限校验（超限时截断 `flowName` 或抛明确错误，别让 upsert 静默失败），并禁止 `namespace` / `flowName` 含 `:`（或改用 `\u{0001}` 之类的分隔符，和 `ChannelMediator.keyOf` 的既有做法一致，`ChannelMediator.cj:47`）；`ownedBy` 同时校验分隔符位置，避免前缀误判。

### [轻微][存量] #7 `fix-loom-extract-data-loss` 提案的用例数与它自己列出的类别不符（6 条 vs 4+1+1+3 条）

- **位置**：`f_llm/doc/spec/fix-loom-extract-data-loss/proposal.md:18`
- **来源**：存量（快照模式无基线）
- **判据**：review-checklist §13（文档内部不自洽）
- **证据**：静态确定 —— 原文「补 6 条用例：TextClip 四种输入、中文长正文提炼、中文长知识切块、三种 summarize 回落」，逐项相加为 4+1+1+3 = 9 条；同变更 `tasks.md:7-19` 列出的条目更多（1.1 四条、1.2 emoji、2.1、2.2 回归、3.1–3.3、4.1–4.2）；实际 `src/util/TextClip_test.cj` 有 5 个用例，也已超出「四种输入」。
- **描述**：纯计数字面错误，会让人误判补齐程度（第 3 部分也报过 `cover-loom-test-gaps` 的同类问题，说明这是模板化写作留下的固定噪声）。
- **建议**：改成「补 9 条用例」或删除具体数字，只保留分类清单。

### [轻微][存量] #8 `fix-loom-memory-owner` 的「未覆盖」条目与 `fix-evolution-watermark` 的结论相反，且未标注已被取代

- **位置**：`f_llm/doc/spec/fix-loom-memory-owner/design.md:35-37`（「演进素材 `limit=500` 与水位线无条件推进……需要把 `state.markRun(now)` 改成『推进到已处理的最大 at』，**并配分页取数**，属独立设计」）对比 `f_llm/doc/spec/fix-evolution-watermark/design.md:10-11`（「把 `load` 改成游标分页（按 `at` 递增取）。**否决**——需要改存储查询契约」）
- **来源**：存量（快照模式无基线）
- **判据**：review-checklist §13（文档过期 / 两份规格互斥）
- **证据**：静态确定 —— 两份归档 spec 同在 `f_llm/doc/spec/` 下，对同一后续工作给出互斥方案，前者的「未覆盖」段没有「已由 `fix-evolution-watermark` 处理」的指向
- **描述**：水位线改造已落地（`SkillEvolutionJob.cj:234-241`），分页取数被明确否决；`fix-loom-memory-owner` 仍把「分页取数」写成待办方案。读者会误以为分页是既定路线，而实际结论相反。叠加上 #1：被否决的分页/`since` 下推正是「超量不丢」缺失的那一环，两份文档合起来正好把这个决策缺口暴露出来。
- **建议**：在 `fix-loom-memory-owner/design.md` 的「未覆盖」段补一句「水位线部分已由 `fix-evolution-watermark` 处理（分页方案被否决，遗留风险见该变更）」，或删掉该段只留链接；若采纳 #1 的 `since` 下推，则两处一并更新。

### [轻微][存量] #9 `llm_channelSendRoots` 文档写「绝对路径」，实现不校验绝对性

- **位置**：`f_llm/doc/spec/fix-channel-attachment-safety/proposal.md:14`（「新配置 `llm_channelSendRoots`（逗号分隔**绝对路径**）」）对比 `f_llm/src/config/LLMConfig.cj:227-244`（按逗号切分 + `trimAscii`，无绝对路径校验）；消费侧 `f_llm/src/channel/EmailChannel.cj:230-237` 直接 `canonicalize(Path(root))`
- **来源**：存量（快照模式无基线）
- **判据**：review-checklist §13（配置约束与源码不符）
- **证据**：静态确定 —— 读取函数无路径形态校验；`canonicalize` 对相对路径按进程 cwd 解析（官方文档 `cangjie-doc/cangjie-doc/md/doc/cjapi/fs.md:13`：解析 `..` 与符号链接、返回绝对标准路径）
- **描述**：配置写成相对路径时不会在装配期报错，而是在发信时按**进程启动目录**解析成某个目录，把「允许根」变成随部署方式漂移的值；`~` 不展开，该项会 `canonicalize` 失败并在 `checkAttachment` 的 `continue`（`EmailChannel.cj:235`）里被静默跳过，极端情况下所有根都不可用而表现成「一律拒发」。
- **建议**：`channelSendRoots()` 对每项判绝对路径（`Path(item).isAbsolute()`），非绝对直接丢弃并 warn；`README.md:791` 的配置说明同步写明「必须是绝对路径，否则忽略」。

<!-- 第 5 部分 -->

### [一般][存量] `experience` 双 kind 合并让 `limit` / `offset` 不再是页语义

- **位置**：`f_llm/src/loom/LoomStoreGateway.cj:149-163`（`memory.list` 的 experience 分支）；承诺源 `f_llm/doc/spec/fix-loom-read-path/specs/loom-flow/spec.md:21`
- **来源**：存量（快照模式无基线）
- **判据**：review-checklist §11（契约与实现不符 / 边界）、§13（规格与实现漂移）
- **证据**：静态确定 —— `offset`、`limit` 被**逐 kind** 各传一遍，`merged.add` 拼接后无全局截断：`limit=1` 时两 kind 各取 1 条 → 返回 2 条；`offset=1` 时两 kind 各自的第 0 条都被跳过 → 跨页漏条。`listByKind` 是「先过滤再分页」的下推实现（`f_llm/src/store/MemoryRepository.cj:72-80`、`f_llm/src/dao/postgres/MemoryDAO.cj:166-172`）。
- **描述**：spec 要求「`memory.list` 在缺少 `limit`、或 `limit<=0` 时 MUST 使用缺省上限 50」，实现里 50 是**每 kind** 的上限，experience 一次最多返回 100 条；`offset` 在两条 kind 流上重复生效。文档 `f_llm/doc/loom.md:565` 还写「带 `kind` 时…**先过滤再分页**」，与「两类各分页再拼接」不符。演进侧同路径（`SkillEvolutionJob.cj:266-269` 对两类 kind 各取 `limit=500`）。
- **建议**：最小改法是在网关内合并后按 `saveTime` 排序再 `take(limit)`；根治则是给 Store 增加 `listByKinds(..., offset, limit)`（`kind IN (...)` + 单次 `LIMIT/OFFSET`）。注意 `MemoryQuery.kinds` 只服务 `search`（`f_llm/src/store/InMemoryStores.cj:152`），`list` 侧没有等价能力，不能直接复用。

### [一般][存量] 网关的惰性单例无同步，违反「一次装配最多创建一个网关」

- **位置**：`f_llm/src/loom/LoomWiring.cj:38-53`（`LoomGatewayHolder.get`）；共享路径 `LoomWiring.cj:103-106`（`loomStore` 闭包）与 `LoomWiring.cj:215`（调度线程里的 `SkillEvolutionJob`）；承诺源 `f_llm/doc/spec/fix-loom-store-gateway-reuse/specs/loom-flow/spec.md:5-7`
- **来源**：存量
- **判据**：review-checklist §12.1（惰性初始化 / 检查-然后-写入 / 发布逸出）、§13（规格与实现漂移）
- **证据**：静态确定 —— `get` 是「读 `value`（`:46`）→ 为 `None` 则 `LoomStoreGateway()`（`:50`）→ 回写 `value`（`:51`）」的检查-然后-写入，`value` 是普通字段，无 `Mutex` / 原子。两个访问者是请求线程（`LoomWiring.cj:105` 的 store 闭包）与调度线程（`LoomWiring.cj:215` 任务触发时 `holder.get(injected)`）。
- **描述**：并发首调用时两个线程都可能看到 `None`，各建一个网关（内部会 `Stores.content()` + `Stores.meta()` + `EvolutionStores.current()`），构造计数 >1，与 spec 的「MUST 最多创建一个」直接冲突；`value` 的写也没有 happens-before，另一线程可能读到未安全发布的引用（是否会观察到未构造完成的对象取决于运行时内存模型，待确认）。后果量级：多一个实例与一组存储连接，不涉及数据损坏。`design.md:14` 把「并发下的懒加载优化」列为 Non-Goal，但 spec 的 MUST 是无条件的，两处口径不一致。
- **建议**：`get` 整体放进 `synchronized`（构造只在首次发生，临界区代价可接受）；或双检 + 原子引用。若坚持不做并发保证，则把 spec 的 MUST 降级为「单线程首次使用」并在 design 的 Non-Goal 中明说。

### [一般][存量] jit 占位符校验只覆盖向后引用，前向引用与任意 `{…}` 仍会漏成字面量

- **位置**：`f_llm/src/loom/Plan.cj:107-121`（`FlowPlan.validate` 的 `jit` 分支）、`f_llm/src/loom/LoomCompiler.cj:77-85`（`compileJit` 无校验）；承诺源 `f_llm/doc/spec/fix-loom-read-path/specs/loom-flow/spec.md:33-35`、`design.md:36-37`、`tasks.md:16`
- **来源**：存量
- **判据**：review-checklist §13（规格与实现漂移）、§14.1（半成品：只处理部分输入）
- **证据**：静态确定 —— 校验遍历 `seen.keys()`，而 `seen` 在同一次循环里先加入当前步骤 id（`Plan.cj:106-107`），因此只覆盖「已出现过的步骤」与 `start`；`{later.output}`（前向引用）、`{input}`、`{env.X}` 一律放行，继续拼进 `jitSourceOf` 当代码编译。design D3 写的是「`LoomCompiler` 在拼 jit 源码前扫一遍：正则近似 `\{[a-zA-Z_][\w.\-]*\}` 命中即抛」，tasks 3.1 也写「`LoomCompiler` 对 jit 源码里的 `{…}` 抛 `LoomException`」，实际落点在 `Plan.validate`，机制是「按已知 id 精确匹配」。
- **描述**：spec 写的是「源码若包含 `{…}` 形式的模板占位符，编译期 MUST 抛错」，实现收窄成「引用已声明步骤或 start 才抛」。最常见的**前向引用**（引用后定义步骤的输出）与拼错 id 仍然编译失败或变成字面量，正是该变更想消除的排查成本。文档把位置写成 `LoomCompiler`，后续维护按文档找不到校验点。
- **建议**：在 `LoomCompiler.compileJit` 编译前统一扫描整段 `step.input`（可先收集全部 step id + `start`，再扫一遍；无法识别的 `{…}` 也抛错），并修正 `design.md:36-37` / `tasks.md:16` 的位置与机制描述。

### [一般][存量] 提炼写入失败被静默吞掉，与「提炼失败可观测」的 MUST 冲突

- **位置**：`f_llm/src/loom/LoomMemoryPolicy.cj:160-165`（knowledge upsert）、`:192-198`（memory add）；承诺源 `f_llm/doc/spec/fix-loom-memory-owner/specs/loom-flow/spec.md:51-53`
- **来源**：存量
- **判据**：review-checklist §3（`catch { () }` 静默吞异常）、§11（错误处理静默）、§13
- **证据**：静态确定 —— knowledge 分支 `catch (error: Exception) { () }`，memory/experience 分支 `catch { false }`，只让 `written` 不递增。`LoomRunner.cj:238-252` 只在 `extract` 抛出或 `written==0` 时 `warn`；三条写入中只要有一条成功（例如 memory 成功、knowledge 失败），`written>=1`，既不告警也无痕迹。
- **描述**：`proposal.md:11` 的根因之一是「提炼失败三层 `catch` 静默」，本次只补了外层两类：`extract` 自己把异常吃掉，`catch (error)` 分支不会因单点写入失败触发。spec 的「异常与零写入 MUST 各留一条 warn，MUST NOT 完全静默」只对「全挂」成立。
- **建议**：`write` 内对 `LoomHostApi.callStore` 的失败各打一条 warn（带 kind / docId / flow），`written` 只统计成功；或让 `extract` 返回失败项列表由 `LoomRunner` 统一告警。

### [一般][存量] `docId` 唯一性仍依赖秒级时间戳 + 进程内序号，重启/多实例同秒会覆盖

- **位置**：`f_llm/src/loom/LoomMemoryPolicy.cj:155-156`（`stamp` + `nextDocSeq()`）、`:170-181`；承诺源 `f_llm/doc/spec/fix-loom-memory-owner/specs/loom-flow/spec.md:5-7`
- **来源**：存量
- **判据**：review-checklist §11（边界 / 契约与实现不符）、§13
- **证据**：静态确定（机制）—— `stamp = DateTime.now().toUnixTimeStamp().toSeconds()` 只有秒级精度，`seq` 是进程内静态计数、启动即为 1（`LoomMemoryPolicy.cj:167-181`）。同进程内两次执行必然不同，跨进程（重启、多实例）则可能完全相同。
- **描述**：proposal 的原始缺陷是「重启后序号归零，撞上历史文档即覆盖」。加时间戳把窗口从「每次重启必撞」缩小到「重启后与上一次首条写入落在同一秒」，但 spec 写的是无条件「MUST NOT 覆盖既有文档」，多实例部署同秒各自写第一条知识同样会互覆。后果是知识文档被覆盖（数据丢失），触发面窄但不为零。
- **建议**：`docId` 后缀改用毫秒/纳秒时间戳，或加进程唯一标识（启动时生成一次随机串/UUID），消掉「同秒 + 序号重来」这个组合。

### [一般][存量] 演进素材的分页发生在租户过滤之前，其他租户占满首页时本租户静默零素材

- **位置**：`f_llm/src/loom/SkillEvolutionJob.cj:318-341`（`knowledgeOf`）；文档已声明为未覆盖项 `f_llm/doc/spec/fix-loom-memory-owner/proposal.md:31`
- **来源**：存量
- **判据**：review-checklist §11（静默少取 / 语义与注释不符）、§14.1（半成品：只处理部分输入）
- **证据**：静态确定 —— 先 `gateway.call('knowledge','docIds','{offset:0,limit:500}')` 取**全局**前 500 个 id（`SkillEvolutionJob.cj:319-324`），再在内存里用 `ownedBy` 前缀过滤（`:314-315`、`:333-336`）；`ownedBy` 只决定「读不读正文」，不参与「取哪 500 个」。
- **描述**：知识库多租户共用时，前 500 个 id 若被其他租户占满，本租户本轮演进素材为 0，且没有任何日志（`written==0` 告警只覆盖提炼，不覆盖素材为空）。proposal 把它归入「`limit=500` 上限未覆盖」，但实际后果是「本租户完全读不到」，不只是「少取几条」。
- **建议**：让 `knowledge.docIds` 支持按 docId 前缀过滤（或按 owner 建索引），把分页与租户过滤的顺序调换；同时把「素材为空」也纳入可观测（一条 debug/warn）。

### [一般][存量] 选路阶段把「状态查询异常」当成「状态漂移」，会摘除本来正常的流程

- **位置**：`f_llm/src/loom/Supervisor.cj:184-192`；承诺源 `f_llm/doc/spec/fix-loom-supervisor-lifecycle/specs/loom-supervisor/spec.md:5-7`、`design.md:22-24`
- **来源**：存量
- **判据**：review-checklist §11（错误分类 / 契约与实现不符）
- **证据**：静态确定 —— `let stillCompiled = try { service.status(chosen) == COMPILED } catch (e: Exception) { false }`，随后 `if (!stillCompiled) { let _ = unregister(chosen); return NO_USABLE }`；`unregister` 会从内存路由表移除条目（`Supervisor.cj:324-336`）。spec 只授权对「流程已不是 compiled」摘除，design D2（`design.md:24`）则说「`routable()` 与 `status()` 是候选枚举，异常等于『没有候选』」。
- **描述**：`status()` 抛异常（存储抖动、连接被回收）被折算成 `false`，于是对一条完全正常的流程执行 `unregister`，之后只能靠 `LoomService.tap` / `confirmFlow` 重新登记。「没有候选」只是本次不派发，「摘除」是状态变更，两者被合并了。
- **建议**：区分两种失败：`let status = try { Some(service.status(chosen)) } catch { None }`；`None` 时返回 `NO_USABLE` 且**不摘除**，只有 `Some(s) && s != COMPILED` 才摘除。`SupervisorOutcome.message` 可分原因，便于排查。

### [一般][存量] `StoreInvoker` 用「异常类型」判断是否已装配，业务异常也会触发新建网关并重放同一请求

- **位置**：`f_llm/src/loom/StoreFunctions.cj:84-96`；文档 `f_llm/doc/spec/fix-loom-store-gateway-reuse/design.md:37-46`、`specs/loom-flow/spec.md:5-7`
- **来源**：存量
- **判据**：review-checklist §11（错误处理：错误分类过粗）、§13（与「MUST NOT 在每次调用时重新构造」冲突）
- **证据**：静态确定 —— `case None => try { LoomHostApi.callStore(...) } catch (error: LoomException) { LoomStoreGateway().call(...) }`。已装配时 `callStore` 执行的是同一个网关函数（`LoomHostApi.cj:169-177`），而网关对未知 op 抛的也是 `LoomException`（`LoomStoreGateway.cj:355` `unsupported ${kind}.${op}`）。因此「已装配 + op 拼错」也走 fallback：新建网关（`Stores.content()` / `Stores.meta()` / `EvolutionStores.current()`）再重放请求。
- **描述**：`design.md:41-44` 用 `catch (e: LoomException)` 识别「未装配」，但未装配与业务错误的异常类型相同。后果：(1) 每次业务异常多开一次存储、多一条连接——正是本变更要消除的开销；(2) 写类 op（`add`/`upsert`/`remove`）在「已部分生效后抛错」时会被重放，存在重复写入面（是否发生取决于底层实现，待确认）。
- **建议**：只对「未装配」回退。让 `LoomHostApi` 暴露 `storeInstalled(): Bool`，或未装配抛专用类型，`StoreInvoker` 只 catch 该类型；其余异常原样上抛（工具层已有 `memoryCall failed: …` 包装）。

### [一般][存量] design 声称「网关按 op 白名单执行」，实际没有白名单，`character.set` / `prompt.put` / `skill.remove` 都能从 `loomStoreCall` 直达

- **位置**：`f_llm/doc/spec/fix-loom-tool-coverage/design.md:34`；实现 `f_llm/src/loom/LoomStoreGateway.cj:321-341`、`f_llm/src/loom/StoreFunctions.cj:193-215`
- **来源**：存量
- **判据**：review-checklist §10（安全性：外部输入未校验 / 越权面）、§13（文档承诺与实现不符）
- **证据**：静态确定 —— `design.md:34` 的风险是「模型滥用 `loomStoreCall`（例如 kind=character 改人格）」，缓解写「网关按 op 白名单执行」。网关只有 kind / op 的 if 链，无白名单、无只读限制：`character.set` / `character.reset`（`LoomStoreGateway.cj:321-341`）、`prompt.put` / `prompt.remove`、`skill.remove`、`memory.remove`、`knowledge.remove` 全部可达；`StoreCallFunction` 只校验 kind/op 非空与 payload「像个对象」（`StoreFunctions.cj:193-208`）。
- **描述**：模型可以在流程里把某用户的人格、提示词、技能删改（`character.set` 会整体覆盖 `characterKey`/`prompts`）。这是文档自己识别出的风险，但给出的缓解措施不存在，读文档的人会以为写操作被挡住了。
- **建议**：二选一——(a) 在工具层做读写分级：写 op 默认不放行，需显式开关；(b) 若确认要保留写能力，把 `design.md:34` 的缓解列改成真实做法（如「由 `ToolScope` 控制工具可见性，不做 op 级限制」），并写明风险承担方式。

### [一般][存量] 网关创建时机：proposal / tasks 说「装配期建一个」，design 与实现是「懒建一次」，design 风险表还留着急切方案

- **位置**：`f_llm/doc/spec/fix-loom-store-gateway-reuse/proposal.md:18`、`tasks.md:9`、`design.md:18-30`、`design.md:69-71`；实现 `f_llm/src/loom/LoomWiring.cj:38-53,103-106`
- **来源**：存量
- **判据**：review-checklist §13（文档与实现不一致 / 文档内部自相矛盾）
- **证据**：静态确定 —— 实现是懒建：`LoomGatewayHolder.get` 首次调用才 `LoomStoreGateway()`，`wire` 只 `installStore` 一个闭包（`LoomWiring.cj:103-106`），装配阶段不触碰存储；`f_llm/doc/loom.md:219` 也写「存储网关**懒建一次**：装配阶段不连存储」。而 `proposal.md:18` 写「在装配期建**一个**网关」，`tasks.md:9` 写「`wire` … 装配期建一次并复用」；`design.md:29` 明确否决了「在装配期直接建」，`design.md:71` 的风险行却仍是「装配期建网关若失败（库不可用），整个 wire 抛错」——该风险在懒建方案下不存在。
- **描述**：同一变更三份文档给出两种相反的创建时机，且 design 的风险表是急切方案的残留。按 proposal / tasks / 风险表理解，会误判「启动期是否连库」「`wire` 是否可能因存储不可用抛错」。
- **建议**：以代码与 `doc/loom.md:219` 为准统一为懒建：改 `proposal.md:18`、`tasks.md:9` 的措辞，把 `design.md:71` 的风险行改写为「异常延迟到首次 store 调用暴露」。

### [一般][存量] 若干已实现行为没有进对外文档：`wire(host:)` / `characterUserId`、演进归属回落、`prompt.get` 的 `version<=0`

- **位置**：`f_llm/doc/spec/fix-loom-supervisor-lifecycle/tasks.md:21`、`fix-loom-memory-owner/tasks.md:30`、`fix-loom-persona-prompt/tasks.md:24`；实现 `f_llm/src/loom/LoomWiring.cj:73-77,129-141`、`LoomStoreGateway.cj:277-285`、`doc/loom.md:328,569-570`
- **来源**：存量
- **判据**：review-checklist §14.2（公开 API / 关键配置未文档化）、§13
- **证据**：静态确定 —— ①`tasks.md:21` 声称「README 中英补 `host` 参数说明」，但 `grep -n "host:" README.md README_en.md` 无命中（wire 示例只有 `chat` / `plannerModel`，`README.md:332`、`README_en.md:328`），`characterUserId:` 同样无命中；②`tasks.md:30` 声称「`doc/loom.md` 补演进归属派生」，但 `evolutionUserId` 只出现在一个示例（`doc/loom.md:328`），`evolutionOwner` 在 `doc/loom.md` 中无命中；③`tasks.md:24` 声称「网关表补 `prompt.get/remove` 的版本语义」，表中只写了 `remove` 必须给版本，`latest / get` 行没有「`version<=0` 取最新」（`doc/loom.md:569`），而代码 `LoomStoreGateway.cj:278-281` 明确实现该语义。
- **描述**：`wire(host:)` 改变了「已安装宿主不被覆盖」的装配语义（`LoomWiring.cj:129-136`），`evolutionUserId/Namespace` 未显式给时会静默跟随 `LoomMemoryPolicy`（`:152-172`）。这两条都容易被误配，却只存在于代码里；`host` 是 `public static func wire` 的参数，不属于 internal 细节。
- **建议**：在 `README.md` / `README_en.md` 的 loom 装配小节补 `wire` 参数表（`host`、`characterUserId`、`evolutionUserId`、`evolutionNamespace`、`gateway`）；`doc/loom.md` 演进小节写明「未显式给 → 跟随记忆策略，写读同源」；网关表 `prompt` 行补 `get` 的 `version<=0 = latest`。

### [一般][存量] 「同一进程只能跑一个流程」是硬约束，但只写在内部 KDoc，`executeNow` 也没有串行化

- **位置**：`f_llm/src/loom/LoomHostApi.cj:24-28`（KDoc 声明「约束：**单线程使用**」）、`LoomHostApi.cj:47-49,183-205,212,235`、`LoomContextLog.cj:51-53`、`LoomService.cj:122-140`；文档 `f_llm/doc/spec/fix-loom-persona-prompt/design.md:40-46`
- **来源**：存量
- **判据**：review-checklist §14.1（关键限制未记录）、§12.1（共享可变状态：先证线程封闭）
- **证据**：静态确定（共享路径）—— `personaText` / `skillText` / `values` / `current` 与 `LoomContextLog.turns` 全是 `private static var`，只由一把 `mutex` 保证不撕裂，不提供按流程隔离；`LoomService.executeNow`（`LoomService.cj:122-140`）每次 `new LoomRunner` 后直接 `run`，无队列、无锁。`LoomHostApi.cj:27-28` 自己声明「并发流程需各自持有独立进程」。
- **描述**：按 §12 误报边界，这里**不判**为并发缺陷（类型已声明非线程安全），问题在文档面：这条「一个进程只能跑一个流程」的硬约束没有进 `README` / `doc/loom.md` / `doc/known-limitations.md`，`fix-loom-persona-prompt/design.md:45` 的 Risks 也只写了「`LoomCharacterScope` 是静态态」。宿主若在 HTTP 服务里并发调用 `executeNow`（看着像普通 API），会出现 A 流程拿到 B 的人格/技能前缀，A、B 的对话轮次进同一个 `turns` 缓冲，提炼时把别人的对话写进自己的记忆。`doc/loom.md` 的并发小节只讲了「计划 `parallel` 走 `AsyncFlow`」，容易被读成「多流程并发安全」。
- **建议**：把该约束写进 `doc/known-limitations.md` 与 `README`（一句话：「同一进程同一时刻只应执行一个 loom 流程；并发请分进程或自行串行化」）；`LoomService.executeNow` 若将来要支持并发，应改为显式上下文（`LoomRunner` 内 context 随 `bind` 传递，或 `ThreadLocal` + `finally` 清理），而不是静态字段。

### [轻微][存量] 同类「单字段 Box」类在 loom 内重复 25 份

- **位置**：`f_llm/src/loom/LoomMemoryPolicy.cj:27,31`、`LoomCharacterScope.cj:62`、`LoomHostApi.cj:32,36,41`、`LoomRegistry.cj:78-90`、`LoomRunner.cj:26,45,49,53,58`、`LoomTimeout.cj:21`、`LoomContextLog.cj:36`、`LoomAgent.cj:89`、`EvolutionLeases.cj:72`、`SkillCatalog.cj:358-375`、`SkillEvolutionJob.cj:464`
- **来源**：存量
- **判据**：review-checklist §2（重复逻辑：只改类型名 / 同一技巧复制）
- **证据**：静态确定 —— `grep -rn "class .*Box" src/loom/*.cj`（排除 `_test`）共 25 处，形状一律 `class XxxBox { public var value: T = 初值 }`，唯一用途是把 `synchronized`（Unit 语义）的返回值带出来，用法一律「new → 锁内赋值 → 锁外读」。本部分审查的变更文档也各自新增了一个（`PolicyBox`、`DocSeqBox`、`ScopeBox`）。
- **描述**：同一惯用法复制 25 次，每加一处锁就要再抄一个类；`public var` 在这些内部类上也无意义（类型本身不可见）。
- **建议**：放一个泛型持有者 `class Box<T> { public var value: T }`（构造参数传初值），各调用点改 `let box = Box<Int64>(0)`；机械替换、无行为变化，顺手可把 `public var` 收成 `var`。

### [轻微][存量] 提炼告警条件里的 `policy.enabled` 是恒真判断

- **位置**：`f_llm/src/loom/LoomRunner.cj:241`
- **来源**：存量
- **判据**：review-checklist §1（恒真分支）
- **证据**：静态确定 —— `if (written == 0 && policy.enabled)` 位于 `if (policy.enabled && !turns.isEmpty())`（`LoomRunner.cj:238`）内部，第二个条件永远成立。
- **描述**：重复判断，读者会以为存在「策略关闭也要告警」的分支。
- **建议**：去掉 `&& policy.enabled`。

### [轻微][存量] 六个已完成的变更仍留在 `doc/spec/` 未归档，且 memory-owner 的 tasks 缺 follow-up 段

- **位置**：`f_llm/doc/spec/fix-loom-memory-owner/`、`fix-loom-persona-prompt/`、`fix-loom-read-path/`、`fix-loom-store-gateway-reuse/`、`fix-loom-supervisor-lifecycle/`、`fix-loom-tool-coverage/`；对照 `f_llm/doc/spec/archive/`（仅两项：`2026-10-30-f-llm-memory-storage/`、`2026-10-31-f-llm-store-wiring/`）
- **来源**：存量
- **判据**：review-checklist §13（文档过期 / 状态不符）
- **证据**：静态确定 —— 五份 tasks 的 `Workflow follow-up` 都写着「`openspec validate --strict` → 归档 → 覆盖 `f_llm/doc/spec/<name>/`」（`fix-loom-persona-prompt/tasks.md:26-28`、`fix-loom-read-path/tasks.md:24-26`、`fix-loom-store-gateway-reuse/tasks.md:23-25`、`fix-loom-supervisor-lifecycle/tasks.md:23-25`、`fix-loom-tool-coverage/tasks.md:21-23`），任务全部 `[x]`，目录仍在原地；`fix-loom-memory-owner/tasks.md`（1-34 行）连 follow-up 段都没有。
- **描述**：`doc/spec/` 同时存放「进行中」与「已完成」变更，读者无法区分当前有效规格；仓库已有 `archive/` 约定，这六个却没进去。
- **建议**：按 follow-up 归档这六个目录（保留 spec delta 供追溯），并给 memory-owner 的 tasks 补 follow-up 段；归档前先处理本报告里与这些变更相关的未兑现项。

### [轻微][存量] 装配状态散成 5 处进程级静态，各文档只分别声称「与 `LoomServices` 一致」

- **位置**：`f_llm/src/loom/LoomWiring.cj:150`（`reload`）、`:39`（`LoomGatewayHolder.value`）、`LoomCharacterScope.cj:30`（`installed`）、`LoomMemoryPolicy.cj:75`（`current`）、`LoomHostApi.cj:47/212/235`（host / persona / skills）
- **来源**：存量
- **判据**：review-checklist §10（设计合理性 / 可测试性）
- **证据**：静态确定 —— 三份文档分别在 Risks 表写「进程级单例语义，与 `LoomServices` 一致」（`fix-loom-supervisor-lifecycle/design.md:53`、`fix-loom-persona-prompt/design.md:45`、`fix-loom-store-gateway-reuse/design.md:72`），但没有一处汇总「一次装配写哪些静态、`wire` 重入时谁覆盖谁、测试要重置哪几个」。
- **描述**：`wire` 每次调用都会覆盖 `reload` / `currentHost` / `current` / `installed`，并新建 `LoomGatewayHolder`（旧 holder 的已建网关仍被旧闭包持有直到重装）。装配契约只能靠通读多份文档拼出来，测试隔离也没有统一入口。
- **建议**：在 `doc/loom.md` 装配小节加一张「装配写入的进程级状态 / 重置方式」表，或引入单个 `LoomRuntime` 持有这些字段并提供 `resetAll()`。

<!-- 第 6 部分 -->

### [一般][存量] 存储后端配置键在合并主规格里仍是已删除的 `llm_contentStore`

- **位置**：`f_llm/doc/spec/llm-content-store/spec.md:10`（`系统 SHALL 读取 llm_contentStore 决定内容族实现`）、`f_llm/doc/spec/llm-store-wiring/spec.md:31`（`启动时读取 llm_contentStore / llm_metaStore`）
- **来源**：存量 —— 主规格由 `1df859449 2026-10-30`「归档 f-llm-memory-storage，主规格落 llm-content-store / llm-meta-store」一次写成，此后无提交；同日 13 个提交之后 `9f459e0c1 2026-10-30`「删除 llm_contentStore，记忆选型统一为 llm_memoryStore」把它改成废弃键
- **判据**：review-checklist §2（同一字面量散落多处、已漂移）、§13（API / 配置默认值与源码不符）
- **证据**：静态确定 —— `f_llm/src/store/StoreSettings.cj:34` `CONTENT_KEY = 'llm_memoryStore'`，`:45` 把 `llm_contentStore` 列入 `DEPRECATED_KEYS`，`:63-70` 命中后只 `warn{'deprecated config key ignored: ...'}`、`:72` 仍取 `llm_memoryStore ?? 'f_hydra'`；`f_llm/src/store/Stores.cj:29` 同名常量、`:106` 校验读的也是 `memoryStore`。`README.md:805` 已写明旧键「只识别、不生效」
- **描述**：按主规格配 `llm_contentStore=postgres` 的用户不会切到 PostgreSQL：进程只打一条 warn，实际仍用默认 `f_hydra`（进程内内容族），记忆 / 知识写进了另一个后端。规格同时还承诺「取值未知或未注册时 MUST 启动失败」，而废弃键连校验都进不去（`StoreWiring.cj:68` 调 `Stores.bootstrap()` 读的是新键），「静默回退」正是该规格明令禁止的行为。`llm-meta-store/spec.md:10` 用的键名正确，仅内容族一处漂移
- **建议**：两份主规格统一改为 `llm_memoryStore`，并把 `llm_contentStoreUrl`（远程地址）一并补进配置段；保留一句「旧键 `llm_contentStore` 只 warn 不生效」，避免读者以为两个键等价

### [一般][存量] `llm-content-store` 主规格的可选值表、记忆种类、隔离边界均与实现相反

- **位置**：`f_llm/doc/spec/llm-content-store/spec.md:110`、`:117-118`（内存实现不得出现在可选值列表）、`:34`（预定义 7 个种类）、`:22`（`namespace` 取 `global` 或 `ws-{workspaceId}`）、`:62`（权重表）
- **来源**：存量 —— 主规格 `1df859449 2026-10-30`；实现侧 `7b39bbe94 2026-10-31`（f_hydra 设为默认内容族并在 `StoreWiring` 注册 `inMemory`）、`ab7477b52 2026-11-06`（经验 kind 纳入预定义集合）
- **判据**：review-checklist §13（规格与实现漂移）、§11（契约与实现不符）、§14.1（承诺的功能与实际不符）
- **证据**：静态确定 ——
  1. `f_llm/src/wiring/StoreWiring.cj:60` 无条件 `ensure('inMemory', { => InMemoryContentStore() })`，`Stores.content('inMemory')` 因此可选中；`README.md:239` / `:764` 把 `inMemory` 列为合法内容族。规格却写「内存实现 MUST 仅用于测试，不得出现在可选值列表」「列表为 postgres、mysql、f_hydra、fhydra，不含 memory」
  2. `f_llm/src/store/MemoryKinds.cj:80-91` `predefined()` 返回 9 个（含 `experience` / `experience_failed`，`:51-53`），`:189-191` 两者权重 0.8；规格写「预定义 7 个」且权重表无经验项
  3. `f_llm/src/memory/Memory.cj:121` `remember(..., namespace!: String = 'loom')` 默认写 `loom` 命名空间；规格把隔离边界枚举为 `global` 或 `ws-{workspaceId}`，不含 `loom`
- **描述**：三点后果分别是 ——（a）`inMemory` 不落盘，选它等于**重启即丢全部记忆与知识**，而规格里那条 MUST 正是防止这种误配，现在实现与 README 都放开了、规格还写着禁止，读者无从判断哪个是准的；（b）按规格只能数出 7 种记忆种类，`experience` 系的写入与检索权重会被漏掉；（c）规格的「跨工作空间隔离」口径不覆盖 loom 默认命名空间，按它实现检索过滤会漏掉 loom 自己写的摘要
- **建议**：以 README 的配置表为准重写该主规格的取值段与种类段；`inMemory` 若要保留为可选值，就删掉那条 MUST 并显式写明「不持久化，仅用于演示 / 测试」；若要保留 MUST，则在 `Stores.bootstrap()` 里拒绝生产选择 `inMemory`（二选一，不能两边都留）

### [一般][存量] `llm-store-wiring` 主规格承诺的「MySQL 无向量索引时降级 + warn」未实现：旧版本直接抛错、无库名时静默丢 dense

- **位置**：`f_llm/doc/spec/llm-store-wiring/spec.md:96-106`（Requirement「MySQL 与 PostgreSQL 行为一致」及其 Scenario「无向量索引时降级 → 检索仍返回结果，日志含降级 `warn`」）
- **来源**：存量 —— 规格 `03cd91532 2026-10-31`；实现侧 `f_llm/src/store/mysql/KnowledgeStore.cj` 自引入起即无该分支（`git log` 无相关提交）
- **判据**：review-checklist §14.1（承诺了但没实现）、§3（静默吞掉降级）、§11（错误处理缺失或静默）
- **证据**：静态确定 —— `f_llm/src/store/mysql/KnowledgeStore.cj:97-113`：`case Some(model)` 内 `let path = annPath()`，`if (!path.isEmpty())` 才走 `chunkSearchDense`，**没有 else、没有 try/catch、没有 warn、没有应用层余弦兜底**。`annPath()`（`:189-207`）拼 `db.llm_document_chunk.content_vec`，只有库名解析失败才返回空串；库名可解析时无论服务端版本都发 `MYVECTOR_IS_ANN(...)`（`f_llm/src/dao/mysql/KnowledgeDAO.cj:104-111`），在无该函数的 9.0/9.1 上查询直接报错并向上抛（`LoomStoreGateway.cj:114-118` 的调用无 try，最终由工具层转成 `failed` 文本）。全 `src/` 无 `VECTOR INDEX` 字面量、无 MySQL 版本探测（唯一 `9\.2` 命中是 `Planner.cj:24` 的设计章节号）；`README.md:743` 反向写「VECTOR 列与 HNSW 索引需 9.2+」
- **描述**：规格承诺「低于 9.2 时降级为应用层暴力计算并记录 `warn`，不得拒绝启动，检索仍返回结果」；实现是两条相反的失败形态 —— 库名可解析但服务端无 `MYVECTOR_IS_ANN` 时**整次检索抛错**（连词面结果都拿不到）；库名解析失败时 dense 一路**静默跳过**、只剩词面 LIKE 且日志无痕。两种都不满足规格，也都没有 `degraded` 标记（对照同规格 `:45-55` 对 BGE-M3 失败要求的 `degraded=true`）
- **建议**：二选一并写进规格 —— 要么补「无 ANN → 应用层 cosine 兜底 + 一次性 `warn` + `degraded` 标记」（`VectorMath` 已有向量字面量工具），要么把 Scenario 改成「MySQL 需 9.2+，否则启动校验拒绝」并与 `README.md:743` 对齐；无论选哪条，`annPath()` 为空的分支都应留一条 `warn`

### [一般][存量] `fix-memory-write-consistency` 的任务与设计声称 kind 字面量已改用常量，三处实现仍是字面量

- **位置**：`f_llm/doc/spec/fix-memory-write-consistency/tasks.md:6`（`[x] 1.2 ... 的 kind 字面量改用常量`）、`f_llm/doc/spec/fix-memory-write-consistency/design.md:35-37`（D4「只替换三个 loom 文件里的字面量」）
- **来源**：存量 —— 文档与该提交同批落地（`ab7477b52 2026-11-06`），代码侧未做该项
- **判据**：review-checklist §13（规格与实现漂移）、§14.1（只做了一半）
- **证据**：静态确定 —— `f_llm/src/loom/LoomMemoryPolicy.cj:145-149` 仍是 `'experience'` / `'experience_failed'` 字面量；`f_llm/src/loom/LoomStoreGateway.cj:81`、`:86-87`、`:391-393` 同；`f_llm/src/loom/SkillEvolutionJob.cj:267-268` 同。全仓 `grep 'MemoryKinds.EXPERIENCE'` **零命中**，`MemoryKinds.cj:51-53` 两个新常量只在本文件的 `predefined()` / `weightOf()` 内被引用
- **描述**：任务被勾成完成，但「消除 `experience` 字面量散落」这一目标一点没做；后续读者按 tasks 会以为已收敛，改动 kind 语义时仍要满仓搜字符串。另一面：`MemoryKinds.EXPERIENCE` / `EXPERIENCE_FAILED` 是对外可达的 `public` 常量，仓内除自身外无引用（按硬原则一**不算死代码**，仅作信息），它们的价值目前只剩「给下游用」
- **建议**：补做 1.2（三处改引 `MemoryKinds.EXPERIENCE*`，行为等价、可零风险合入）；若决定不做，把 `[x]` 改回 `[ ]` 并在 tasks 里写明原因，避免任务清单继续失真

### [轻微][存量] `llm-store-wiring` 主规格的「SQL 只出现在 DAO 层」验收场景不成立（与 part3 发现 #13 同源）

- **位置**：`f_llm/doc/spec/llm-store-wiring/spec.md:19-22`（Scenario：检查两个 Repository 源码「不出现 SELECT / INSERT / UPDATE / DELETE 字面量」）
- **来源**：存量 —— 主规格 `03cd91532 2026-10-31`；越界代码 `cdea037a40 2026-10-30` 已存在（与 part3 #13 的 blame 结论一致）
- **判据**：review-checklist §13（规格与实现漂移）
- **证据**：静态确定 —— `f_llm/src/store/postgres/MemoryRepository.cj:55-58`、`f_llm/src/store/mysql/MemoryRepository.cj:59-62`、`:127` 直接 `executor(DRIVER).setSql('DELETE FROM llm_memory_token WHERE memory_id = ?')`，注释说明是「DAO 宏对纯 DELETE 方法生成有缺陷」的绕行
- **描述**：同一段文字在归档副本（part3 已报）与主规格里各有一份；主规格这份会让按契约做 DAO 迁移的人以为 Repository 层已无 SQL
- **建议**：在该 Scenario 后补一行例外说明（哪三处、为什么、何时回收）；主规格与归档副本同步修改

### [轻微][存量] `llm-store-wiring` 主规格的 Purpose 仍是归档工具留下的 TBD 占位

- **位置**：`f_llm/doc/spec/llm-store-wiring/spec.md:4`（`TBD - created by archiving change f-llm-store-wiring. Update Purpose after archive.`）
- **来源**：存量（`03cd91532 2026-10-31` 归档提交原样带入）
- **判据**：review-checklist §3（占位未填）、§14.2（缺关键段落：用途）
- **证据**：静态确定 —— 同层两份主规格 `llm-content-store/spec.md:3-4`、`llm-meta-store/spec.md:3-4` 都有实义 Purpose，只有这份留着工具提示
- **描述**：主规格的第一段就是「待办」，读者拿不到「这份契约管什么」的一句话定义
- **建议**：补一段 Purpose：记忆 / 经验 / 知识 / 文档与元数据的存储分层、选型与启动接线

### [轻微][存量] `perf-loom-render-context` 的 design D3 与同变更 spec / tasks 对「空值占位符」的结论相反

- **位置**：`f_llm/doc/spec/perf-loom-render-context/design.md:22-24`（D3：命中但值为空 → 替换成空串，「与原 `String.replace` 行为一致」）vs `f_llm/doc/spec/perf-loom-render-context/specs/loom-flow/spec.md:20-23`、`f_llm/doc/spec/perf-loom-render-context/tasks.md:7`、`f_llm/doc/spec/perf-loom-render-context/proposal.md:17`（`{start.output}` 无事件数据时**原样保留**）
- **来源**：存量（同一变更四份文档同批提交）
- **判据**：review-checklist §13（文档之间口径不一致）、§10（正确性 / 可读性）
- **证据**：静态确定 —— `f_llm/src/loom/LoomHostApi.cj:117-122`：`token == 'start.output'` 且 `fromEvent.isEmpty()` 时不置 `handled`，走 `:139-141` 只吐 `{` 并继续扫描，占位符原样保留；而对 `{stepId.output}` 命中空串则 `:129-130` 直接 append 空值。即实现是「两种占位符两套空值语义」，与 spec / tasks 一致、与 design D3 的一句话结论相反
- **描述**：D3 是「重构中最容易错的地方」那一节的配套决策，写反了会让后续维护者按它去「修正」实现，反而把 spec 钉住的 `{start.output}` 语义改坏
- **建议**：把 D3 改为「`{stepId.output}` 命中空值 → 空串；`{start.output}` 无事件数据 → 保留占位符（与原 `replace` 只在 `fromEvent` 非空时替换的实现一致）」

### [轻微][存量] `perf-retrieval-candidates` 的「知识候选 1000→400」只覆盖带 Embedder 的构造路径

- **位置**：`f_llm/doc/spec/perf-retrieval-candidates/proposal.md:15-16`、`f_llm/doc/spec/perf-retrieval-candidates/design.md:20-23`（D4「知识候选上限降到 400 … 候选与正文全量驻留不划算」）
- **来源**：存量（变更文档与实现同批）
- **判据**：review-checklist §13（文档表述与实现范围不符）、§7（有界化未覆盖全部分支）
- **证据**：静态确定 —— `f_llm/src/store/postgres/KnowledgeStore.cj:36-52`：`init()` 与 `init(pageSize:maxCandidates!: Int64 = 1000)` 两条**无语义（lexical-only）**构造仍默认 1000；只有 `init(embedder:...)`（`:58`）是 400。`f_llm/src/store/mysql/KnowledgeStore.cj:34-52` 结构相同。而 lexical-only 实例正是「未配置 Embedder」时的生产路径（`init()` 注释：测试或未配置 Embedder 时使用）
- **描述**：proposal 的 Impact 写成无条件「知识候选 1000→400」，实际未配置 Embedder 的部署仍按 1000 条候选全量驻留正文，D4 想解决的峰值内存在这条路径上没变
- **建议**：要么把 lexical-only 的默认也降到 400（与 `pageSize=200`×2 页一致），要么在 proposal / design 里注明「仅 embedder 路径」，避免读者以为上界已统一

### [轻微][存量] `perf-loom-render-context` design D1 以「`std.sync` 只有 `Mutex`」否决读写锁，依据待确认

- **位置**：`f_llm/doc/spec/perf-loom-render-context/design.md:14`（`**替代**：细粒度读写锁。否决——std.sync 只有 Mutex`）
- **来源**：存量
- **判据**：review-checklist §10（设计依据须可核）、§12.2（锁粒度取舍要给理由）
- **证据**：待确认 —— 本机无 SDK 1.3 的标准库文档（`~/.autocode/cj/doc` 不存在，`cangjie-doc-lookup` 离线资源缺失），无法核实 `std.sync` 是否提供 `RWLock` / 读写锁；若提供，该否决理由不成立。同一句的「拷贝一张小表的成本远低于锁内做字符串替换」也没有计时数据
- **描述**：这是该设计唯一支撑「为什么不是读写锁」的论据，错了会把后续同类改造也带偏；正确性上无影响（现状用 `Mutex` + 快照 + 锁外替换是自洽的）
- **建议**：核对 SDK 1.3 `std.sync` 导出清单后改写该条（或删掉「只有 `Mutex`」只留成本论证），并补一次 `values` 规模 10/100 时的「锁内拷贝 vs 锁内替换」分段计时

<!-- 第 7 部分 -->

### [严重][存量] AgentTask 构造器用 `producingEvents` 的长度索引 `acceptableEvents`：越界崩溃 + `nextEvent` 枚举内容错

- **位置**：`f_llm/src/agents/AgentTask.cj:82-84`
- **来源**：存量（快照模式无基线）
- **判据**：review-checklist §11（边界越界 / 语义与命名不符）+ §1（读了不用的正常字段）
- **证据**：静态确定 —— `for(i in 0 .. agent.producingEvents.size)` 的上界来自 `producings` 列，循环体却取 `agent.acceptableEvents[i]`；两列是 `agents` 表里独立的 `acceptable` / `producings` 字段（`f_llm/src/model/po/Agent.cj:32-35,47-56`、`f_llm/tables-pg.sql:39-40`），没有等长约束
- **描述**：`producingEventJsons` 的语义是「本智能体能产出的下游事件」，最终作为工具参数 `nextEvent` 的 `enum` 注入（`AgentTask.cj:394-398`）。现在装的是「本智能体接受的事件」：
  1. `producings` 比 `acceptable` 长（或 `acceptable` 为 `NULL`/空串——`''.split(',')` 只得到 1 个空元素）时，构造 `AgentTask` 直接 `IndexOutOfBoundsException`，属于装配期崩溃；
  2. 长度恰好相等时，枚举里仍是入参事件名，模型会被引导去选一个不会发生的下游事件。`src/agents` 下没有任何测试，这个错位不会被用例拦住。
- **建议**：改为直接遍历产出一侧（`for(e in agent.producingEvents){ list.add(JsonString(e)) }`）；在 `Agent` 上加一条 `producings` 非空校验，并补 `AgentTask` 构造用例覆盖 `acceptable.size != producings.size`。

### [严重][存量] 余额查询关闭 TLS 校验：Bearer API Key 与云账单 AK/SK 可被中间人截获或篡改

- **位置**：`f_llm/src/balance/BalanceQueriers.cj:41-43`（`verifyMode = CertificateVerifyMode.TrustAll`）、`:76-80`（`defaultBalanceGet` → `f_llm/src/util/http.cj:20,25-27` 同一 TrustAll）
- **来源**：存量（快照模式无基线）
- **判据**：review-checklist §10（安全性：敏感数据）+ §11（契约与实现不符）
- **证据**：静态确定 —— 两条余额取数路径都显式把 `CertificateVerifyMode` 设为 `TrustAll`；官方文档明确 `TrustAll` 表示「本端不作对对端证书的校验……一般仅在开发测试阶段使用」（`cangjie_stdx-main-doc/doc/libs_stdx/net/tls/common/tls_common_package_api/tls_common_package_enums.md:20-22`）
- **描述**：`defaultBalanceGet` 发的是 `Authorization: Bearer <DeepSeek API Key>`（`util/http.cj:20`），`defaultPost` 发的是腾讯/火山签名头（`Authorization=...Credential=<AK>/...`）。TLS 校验关闭后，同网段攻击者可自签证书完成 MITM，直接读走明文密钥，或篡改余额响应使告警与预算判断失真。`doc/todo.md` §3 只登记了「HTTP 建连超时缺失」，没有说明为什么必须 TrustAll，看起来是绕证书问题的临时手段被固化成了默认值。
- **建议**：默认改回 `CertificateVerifyMode.Default`；自签/代理场景用配置项（如 `llm_balanceInsecureTls`）显式打开并限制在余额路径；`util/http.cj` 的同名问题属其它部分，需一并处理。

### [一般][存量] 余额响应按「结构一定正确」解析：金额解析失败静默变 `0.00`，结构不符时抛裸异常

- **位置**：`f_llm/src/balance/BalanceUnits.cj:41-47`（`catch(_){ 0.0f64 }`）；`f_llm/src/balance/BalanceQueriers.cj:86-90`（`asBool().value`）、`:91-113`（`asArray()` 与 `balance_infos` 缺失返回空列表）、`:148-155`（`Response`/`Error` 直接 `asObject()`）、`:212-221`（同上）
- **来源**：存量（快照模式无基线）
- **判据**：review-checklist §11（错误处理静默 / 外部输入未校验）+ §3（`catch` 吞异常）
- **证据**：静态确定 —— `BalanceUnits.parse` 吞掉 `Float64.parse` 失败；`Option.value` 在 `None` 时抛 `NoneValueException`（`core_package_enums.md:400-406`），`asArray()`/`asObject()` 在类型不符时抛 `JsonException`（`f_data/src/json/JsonValue.cj:70-75`）
- **描述**：接口注释明写「查不到就是抛异常，不得返回 0 或空快照——余额为 0 与查不到是两件事」（`BalanceQuerier.cj:64-69`），实现却有两条反向路径：
  1. 金额是 `"abc"`、字段缺失、`balance_infos` 缺失时得到 `total="0.00" / totalValue=0.0`，`mark()` 再把 `low` 置真（`BalanceQuerier.cj:135-145`）——「接口坏了」被报成「余额为零」，`queryAll` 也不会记 warn；
  2. `is_available` 不是 bool、`balance_infos` 不是数组、`Response` 不是对象时，抛的是未包装的 `NoneValueException`/`JsonException`，调用方拿不到「哪个平台、什么字段」的上下文。
- **建议**：`parse` 改返回 `?Float64` 或抛 `BalanceUnsupportedException`；`parse*` 在必需字段缺失/类型不符时抛带平台与字段名的异常，并对 `balance_infos` 缺失显式报错而不是返回空列表；「金额为 0」与「金额不可读」用 `available`/错误字段区分。

### [一般][存量] `BalanceMediator.ensureLoaded` 吞掉 bean 扫描异常并置 `loaded=true`：一次瞬时失败永久禁用全部余额查询

- **位置**：`f_llm/src/balance/BalanceQuerier.cj:147-161`（`catch(e){ log.warn }` 后无条件 `loaded = true`）
- **来源**：存量（快照模式无基线）
- **判据**：review-checklist §3（静默吞异常）+ §11（失败路径当成功）
- **证据**：静态确定 —— `loaded = true` 在 `catch` 之后、`synchronized` 块内无条件执行；`lookupList<BalanceQuerier>()` 初始化失败后注册表保持空
- **描述**：`lookupList` 只要抛一次（bean 构造失败、依赖未就绪），注册表就永远为空且不再重扫，之后每次 `query()` 都报 `balance query is not supported for provider: X, available: []`，把「启动态瞬时故障」固化成「该平台不支持余额」。本仓其它装配代码也承认「库/凭据比应用晚就绪是常态」（`ChannelBootstrap.cj:39`）。
- **建议**：只在扫描成功时置 `loaded = true`；失败保留 `false` 并按时间退避重试，或把异常直接抛给调用方，不要降级成「不支持」。

### [一般][存量] `ensureLoaded` 的自动发现绕过「同名注册直接失败」约定：重复 provider 静默覆盖

- **位置**：`f_llm/src/balance/BalanceQuerier.cj:75`（注释承诺）、`:153-155`（`queriers[querier.provider] = querier`）
- **来源**：存量（快照模式无基线）
- **判据**：review-checklist §11（契约与实现不符）+ `fountain-baseline.md §4`（同名注册启动直接失败，不做隐式优先级）
- **证据**：静态确定 —— `register()` 在 `:90-92` 检查重复并抛 `IllegalArgumentException`，`ensureLoaded()` 的 bean 扫描分支直接 `put`，没有 `contains` 检查
- **描述**：两个 `@Bean` 实现声明同一个 `provider`（例如两个类都返回 `"deepseek"`）时，谁生效取决于 `lookupList` 的遍历顺序，后者静默覆盖前者；显式 `register` 同名反而会失败。与项目基线要求的「启动直接失败」相反，出问题时只能靠行为差异猜。
- **建议**：把插入收敛到一个 `insertOrThrow(querier)` 私有方法，两条注册路径共用；同名时抛带两个实现类名的异常。

### [一般][存量] `ensureLoaded` 在锁内执行 `lookupList`（bean 实例化），临界区长度不可控

- **位置**：`f_llm/src/balance/BalanceQuerier.cj:148-155`；调用侧 `:87-95`
- **来源**：存量（快照模式无基线）
- **判据**：review-checklist §6.2 / §12.2（临界区里做 I/O、构造等可能阻塞的动作）
- **证据**：静态确定（锁内调用 `lookupList`）+ 待确认（是否真有 bean 在构造期回调 `register`）。`lookupList` 会实例化所有 `BalanceQuerier` bean；`std.sync.Mutex` 在仓颉 1.3 是**可重入**的（`sync_package_classes.md:8919-8930`），因此重入不会死锁，但会在 `loaded` 仍为 `false` 时再次进入 `lookupList`
- **描述**：临界区里跑的是「例化全部下游实现 + 写 HashMap」，单次持有时长取决于各实现构造开销（读配置、建连）。若某个 bean 构造期调用 `BalanceMediator.instance.register(...)`，会重入 `ensureLoaded` 并再次扫描；`register` 本身也会先 `ensureLoaded`（`:88`），形成重复扫描与部分初始化状态可见。
- **建议**：锁外先 `lookupList` 到局部列表，锁内只做 `if(!loaded){ 批量 put; loaded = true }`；`register` 在 `loaded=true` 后不再触发扫描。

### [一般][存量] `BalanceMediator.names()` 无锁遍历被 `register()` 加锁修改的 `HashMap`

- **位置**：`f_llm/src/balance/BalanceQuerier.cj:97-104`（读侧）对比 `:87-95`（写侧）
- **来源**：存量（快照模式无基线）
- **判据**：review-checklist §12.1（迭代与修改并发）
- **证据**：待确认 —— `for((name, _) in queriers)` 完全在 `synchronized` 之外，`register`/`ensureLoaded` 的写入都在锁内；仓内没有运行期 `register` 调用（仅测试），触发面取决于下游是否在运行期注册
- **描述**：`names()` 是 public，且被 `query()` 的失败信息调用（`:114`）。一旦有线程 `register()` 扩容 `HashMap`，遍历线程会读到不一致的内部状态。同模块 `ChannelMediator.platforms()` 把遍历放在锁内（`ChannelMediator.cj:99-108`），写法不一致。
- **建议**：遍历整体进锁，或先拷一份名字数组再排序返回（与 `ChannelMediator.providerPlatforms()` 同构）。

### [一般][存量] `accessLLM` 重试预算默认为「无限」，退避 sleep 不校验剩余预算

- **位置**：`f_llm/src/agents/AgentTask.cj:414-453`（`:424` 循环条件、`:432-440` 斐波那契退避）
- **来源**：存量（快照模式无基线）
- **判据**：review-checklist §12.1（异步/超时语义）+ §11（边界）
- **证据**：静态确定 —— `maxCount` / `maxElapsed` 默认 `Int64.Max`（`f_llm/src/config/LLMConfig.cj:245-250`）；`elapsed` 只在 `catch` 里更新，`sleep(sleepDuration)` 前不比较剩余时长
- **描述**：（1）默认配置下「次数 + 总时长」双无限，持续失败会长期占住调用线程；（2）退避 1/1/2/3/5/8… 秒无上限，第 20 次失败会 sleep 上千秒，即使 `maxElapsed` 只剩 1 秒也照睡满整个窗口；（3）`finally` 固定打 `count + 1`，成功与失败的 tried 语义混在一起。注：与 `parts/f_llm.part1.md`、`parts/f_llm.part2.md` 对同文件的记录同源，合并时去重。
- **建议**：`sleep` 取 `min(backoff, 剩余预算)`，预算不足直接抛；退避加封顶；在 README 配置表写明默认值；`resp` 改用 `?LLMResp` 替代 `unsafeZeroValue`（`:423`）。

### [一般][存量] Token 用量落库失败会让整次智能体事件失败

- **位置**：`f_llm/src/agents/AgentTask.cj:456-457`
- **来源**：存量（快照模式无基线）
- **判据**：review-checklist §11（错误处理缺失）+ §10（次要副作用失败应降级）
- **证据**：静态确定 —— `saveTokenUsage` 是裸 DAO 插入、无 try/catch（`f_llm/src/store/postgres/TokenUsageSaver.cj:33-38`，MySQL 同构），调用点也不在 try 内
- **描述**：LLM 已成功、工具已执行，只因用量表插入失败（库不可用、表缺失、唯一键冲突）就抛出，调用方拿不到 `DataEvent`，整轮对话作废。`DummyTokenUsageSaver` 的存在说明这条链路允许空实现，统计本身不是强一致数据。
- **建议**：包 try/catch 并 `log.warn`（或异步 fire-and-forget），失败只计入指标；不要阻断业务事件。

### [一般][存量] 模型给的工具参数 JSON 在 `try` 之外解析：一次坏参数就让整个事件失败

- **位置**：`f_llm/src/agents/AgentTask.cj:473-476`（`JsonValue.fromStr(arguments).asObject()` 在 `:477` 的 `try` 之前）
- **来源**：存量（快照模式无基线）
- **判据**：review-checklist §11（错误处理缺失 / 外部输入未校验）
- **证据**：静态确定 —— `fromStr` / `asObject` / `json.add` 三条语句都在 `try{ let fnResult = FunctionMediator.call(...) }` 之前；`fromStr` 对非法 JSON、`asObject` 对数组/标量都抛 `JsonException`（`f_data/src/json/JsonValue.cj:70-75,156-179`）
- **描述**：工具参数由模型生成，截断、少引号、对象写成字符串都是常态。现在这种本可恢复的工具错误会直接抛出 `exec`；而同文件对 `FunctionMediator.call` 的失败已有「回写错误 ToolMessage 让模型自我修正」的处理（`:501-504`），两段语义不一致。
- **建议**：把 `fromStr`/`asObject` 一起纳入 `try`，失败时 `addToolMsg('工具参数不是合法 JSON: ...')` 并继续下一个 tool call；同时校验 `function.name` 非空。

### [一般][存量] 技能里出现未注册的函数名时，`getDefinitions` 直接抛异常，整次事件失败

- **位置**：`f_llm/src/agents/AgentTask.cj:411`
- **来源**：存量（快照模式无基线）
- **判据**：review-checklist §11（错误处理缺失）+ §14.1（接线缺失/半成品）
- **证据**：静态确定 —— `FunctionMediator.getMeta` 未命中时 `throw FunctionNotFoundException(function)`（`f_llm/src/tool/FunctionMediator.cj:125-131`），`AgentTask` 对 `getDefinitions` 没有 try/降级
- **描述**：`functionNames` 来自技能定义（DB 运行期数据）。技能里留一个已下线/拼错的函数名（或对应模块没进 workspace）时，整个 `exec` 在调用 LLM 之前就抛异常，表现为「智能体彻底不响应」，而不是「少了一个工具」。
- **建议**：逐个 `try` 取定义，缺失函数名 `log.warn` 后跳过，并把缺失项回灌到提示词或事件数据；或在装配技能时预校验。

### [一般][存量] 通道装配报告被丢弃：README 承诺「单条非法只跳过并 warn」，实现没有 warn

- **位置**：`f_llm/src/channel/ChannelBootstrap.cj:76-79`；生产调用点 `f_llm/src/loom/LoomWiring.cj:119`；承诺源 `f_llm/README.md:790` / `f_llm/README_en.md:781`
- **来源**：存量（快照模式无基线）
- **判据**：review-checklist §13（文档与实现不符）+ §3（静默吞错误）
- **证据**：静态确定 —— `ChannelBootstrap` 全文没有 `log.*`；唯一生产调用方把返回值赋给 `_`；`ChannelInstallReport.errors` 无人读取，`summary()` 也不含 `errors`（`:31-33`）
- **描述**：`llm_channels` 配错（缺 `smtpHost`、端口越界、平台未实现）时只静默少一个账号：无日志、无指标，之后 `channelSend` 报「channel not found」。中英文 README 都明确写「skipped with a warning / 跳过并 warn」。
- **建议**：`install()` 在 `catch` 里直接 `log.warn`（带 platform/account，不带 password），或让调用方消费报告并在 `errors.size > 0` 时 warn；`summary()` 补 `errors.size`。

### [一般][存量] `channelInbox` 的 `limit` 无上限，由模型参数直接透传到 IMAP 拉取

- **位置**：`f_llm/src/channel/ChannelFunctions.cj:118-126`（只把 `<=0` 归一到 10）；透传路径 `ChannelMediator.receive` → `f_llm/src/channel/EmailChannel.cj:258-260`（`transport.receive(limit)` 原样使用）
- **来源**：存量（快照模式无基线）
- **判据**：review-checklist §5（按不可信长度处理 / 无拒绝路径）
- **证据**：静态确定 —— `ChannelInboxParam.limit` 默认 10（同文件 `:61-62`），`call` 只判 `> 0`，下游 `receive` 无 clamp
- **描述**：`limit` 是模型可写的工具入参，`limit=100000` 会驱动一次巨量 IMAP FETCH，把邮件头/正文全量物化进 `ArrayList<InboundMessage>`，又长又贵的网络往返也会占满工具调用超时预算。这同时是 §5 的「无拒绝路径」和 §6.4 的输入放大。
- **建议**：在 `ChannelInboxFunction` 里设上限（如 `min(max(limit,1), 50)`），越界裁剪并回写提示；`EmailChannel.receive` 亦应自带 clamp 守住接口契约。

### [一般][存量] `AgentEventData` 被整对象塞回 `data`：多跳后 `ToData` 负载丢失，模板占位符不再替换

- **位置**：`f_llm/src/agents/AgentTask.cj:350`（`eData = any`）、`:379`（`eData = agentData`）、`:458`（`data: eData`）；消费点 `:354`
- **来源**：存量（快照模式无基线）
- **判据**：review-checklist §11（语义与注释不符）+ §10（正确性）
- **证据**：静态确定（类型链）+ 待确认（是否存在 ≥3 跳的 Agent 链）。`AgentEventData` 没有实现 `ToData`（`AgentEventData.cj:18`），而下一跳只认 `let Some(any: ToData) <- agentData.data`（`:354`）
- **描述**：第 1 跳（事件 data 是 `SimpleDataObject`）把 `ToData` 存进 `eventData.data`，第 2 跳能取到并替换模板；但第 2 跳结束时 `eData = agentData`，于是 `eventData.data = Some(AgentEventData)`。第 3 跳再进 `:354` 时类型不匹配，落入 `assembleNoParamPrompts`，`{{...}}` 保持原样——负载在第二跳之后丢失。`AgentTask` 头注释（`:47-48`）明确要求把 `e.data` 转成 `SimpleDataObject` 做模板参数，嵌套包装与该约定冲突。
- **建议**：转发时保留原始负载：`eData = agentData.data ?? (agentData as Any)`，或给 `AgentEventData` 实现 `ToData` 并把 `data` 透传；补一条 3 跳链的用例断言第 3 跳仍能替换占位符。

### [轻微][存量] 三处非 public 符号全项目零引用（死代码）

- **位置**：`f_llm/src/agents/AgentEventData.cj:19`（`var skillIds = HashSet<String>()`）、`f_llm/src/balance/BalanceQuerier.cj:164-166`（`func LLMConfig_balanceLowThreshold()`）、`f_llm/src/balance/BalanceQueriers.cj:271-273`（`func numberOf(obj:key:)`）
- **来源**：存量（快照模式无基线）
- **判据**：review-checklist §1（非 public 无调用者）
- **证据**：静态确定 —— 全仓（排除 `.worktrees/`）搜索 `skillIds`、`LLMConfig_balanceLowThreshold`、`numberOf(` 只有定义处命中；三者都不带 `public`，`AgentEventData` 也没有 `@DataAssist` 反射入口
- **描述**：`skillIds` 是被私有 `skillReferences` 取代后遗留的可变字段；`LLMConfig_balanceLowThreshold` 与 `mark()` 里 `Float64(LLMConfig.getBalanceLowThreshold())`（`BalanceQuerier.cj:136`）是同一换算的第二份拷贝；`numberOf` 是 `BalanceUnits.parse(balanceTextOf(...))` 的无人使用封装。
- **建议**：删除三处；需要测试入口时改为私有 helper，让测试走公开路径。

### [轻微][存量] `AgentEvent` 四个公开构造函数逐字相同，只差参数类型；`(data as Any).getOrThrow()` 恒成功

- **位置**：`f_llm/src/agents/AgentEvent.cj:23-38`
- **来源**：存量（快照模式无基线）
- **判据**：review-checklist §2（只改类型名的重复）+ §10（可读性）
- **证据**：静态确定 —— 四个 `public init` 的构造体都是 `this(..., data: (data as Any).getOrThrow(), ...)`；参数静态类型本身就是目标类型，`as Any` 不可能返回 `None`
- **描述**：重载本身必要（仓颉无隐式上转），但每个构造都带一次「看起来会失败、实际不会失败」的断言，读者需要额外确认；真正的契约（`TaskEvent.data` 是 `Any`）反而没有注释。
- **建议**：保留重载，去掉 `as Any` 直接传 `data`，并加一行注释说明 `TaskEvent.data` 统一存 `Any`。

### [轻微][存量] `AgentTask` 三个惰性字段无同步：`tokenUsageSaverLookuped` 可能先于赋值可见

- **位置**：`f_llm/src/agents/AgentTask.cj:102-113`、`:114-125`、`:126-138`
- **来源**：存量（快照模式无基线）
- **判据**：review-checklist §12.1（惰性初始化 / 可见性）
- **证据**：待确认 —— 缺「`AgentTask` 实例是否被多线程共用」的证据；字段是普通 `var`（非原子、非 volatile）
- **描述**：`skillsFinder_`/`orgFinder_` 重复 lookup 只损失启动开销，可接受；`tokenUsageSaverLookuped` 是「标志位 + 值」的发布问题：另一线程可能先看到 `true`、后看到旧值，从而长期拿 `DummyTokenUsageSaver`，用量统计静默丢失且无日志。
- **建议**：改用单一 `?TokenUsageSaver` 字段（与上面两个 prop 写法统一），或在 `exec` 入口解析一次后作为局部变量传递（`exec` 每事件一次，天然线程封闭）。

### [轻微][存量] `genSkillDetails` 两分支是同一段模板的复制；无引用时也照打「技能引用列表」标题

- **位置**：`f_llm/src/agents/AgentTask.cj:149-170`、`:241-251`、`:258-259`
- **来源**：存量（快照模式无基线）
- **判据**：review-checklist §2（换控制流的重复）+ §10（可维护性）
- **证据**：静态确定 —— 两分支模板逐行相同，仅是否经过 `populatePromptsParams` 不同；`assembleSkillReference` 在 `references.size == 0` 时直接返回，但调用方已先追加 `'#### 技能引用列表\n'`
- **描述**：提示词模板是行为契约，改一处漏一处风险实打实；空引用时提示词里会留一个悬空小标题，模型可能误判「引用列表丢了」。
- **建议**：先算出 `title`/`details` 两个字符串再走一次模板；把「技能引用列表」标题的追加挪进 `assembleSkillReference`，有引用才写。

### [轻微][存量] 三个余额解析函数是三份同构的「取字段 → 换算 → 构造快照」

- **位置**：`f_llm/src/balance/BalanceQueriers.cj:83-115`（DeepSeek）、`:147-179`（腾讯）、`:212-244`（火山）
- **来源**：存量（快照模式无基线）
- **判据**：review-checklist §2（字面量复制 / 只改类型名）
- **证据**：静态确定 —— 三段都是「`json.get` 取 N 个金额字段 → `BalanceUnits.toYuan` → 填 13 个同名字段 → `ArrayList.add`」，差异只有字段名、单位、错误结构；`queriedAt: DateTime.now().toString()` 也各写一遍
- **描述**：`BalanceSnapshot` 以后加字段要改三处，容易漏；单位/错误结构差异需要显式保留，不能简单合并掉。
- **建议**：抽一个私有 `snapshotOf(fields, unit, provider, account, raw)` 构造器，三个 `parse*` 只负责取字段与校验错误结构；`balanceTextOf` 与 `ChannelBootstrap.strOf` 的 `JsonNull`/非字符串语义差异要写进注释。

### [轻微][存量] `channelInbox` 失败时返回对象、成功时返回数组，同一工具两种结果形状

- **位置**：`f_llm/src/channel/ChannelFunctions.cj:127-130`（失败对象）对比 `:133-156`（成功数组）；描述 `:114`
- **来源**：存量（快照模式无基线）
- **判据**：review-checklist §11（契约与实现不符）+ §10（可读性）
- **证据**：静态确定 —— `description` 声明「返回 JSON 数组」，失败分支返回 `{"ok":false,"error":...}`，与 `channelSend` 的 `{ok:...}` 也不统一
- **描述**：模型侧要写两种解析路径，容易把失败对象当数组处理。
- **建议**：统一为 `{"ok":bool,"messages":[...],"error":""}`，同步更新 `description`。

### [轻微][存量] 空响应/被截断时不报错，产出 `name=''` 的事件

- **位置**：`f_llm/src/agents/AgentTask.cj:459-512`（`eventName` 默认 `''`，只在 tool call 分支赋值）
- **来源**：存量（快照模式无基线）
- **判据**：review-checklist §11（空集合未处理 / 失败路径当成功）
- **证据**：静态确定 —— `resp.messages` 为空或只有非 `ToolCallMessage`/`AssistantMessage` 时，仍构造并返回 `DataEvent`；`LLMResp.finishReason`（`f_llm/src/llm/LLMResp.cj:24-29`）在本流程从未被读取
- **描述**：`length` 截断、内容过滤拦空、上游空 choices 三种情况都会产出「没有内容但事件名为空串」的下游事件，排障只能靠猜。
- **建议**：`eventName.isEmpty()` 且没有 assistant 文本时抛明确异常或在事件数据里写 `finishReason`；`finishReason == 'length'` 记 warn。

### [轻微][存量] `ChannelInstallReport.summary()` 不含 `errors`，装配报告的主要信息读不到

- **位置**：`f_llm/src/channel/ChannelBootstrap.cj:31-33`
- **来源**：存量（快照模式无基线）
- **判据**：review-checklist §10（可维护性/可观测）
- **证据**：静态确定 —— `summary()` 只拼 `installed` / `skipped`；`errors` 需要调用方自行遍历，而唯一生产调用方根本不看报告（`LoomWiring.cj:119`）
- **描述**：跳过几条、为什么跳过是装配期最需要的信息。
- **建议**：`summary()` 追加 `errors=${errors.size}`，新增 `errorDetails(limit)` 供日志截断输出。

### [轻微][存量] README 写 `llm_balanceLowThreshold` 默认「无」，代码默认 `100`

- **位置**：文档 `f_llm/README.md:787`、`f_llm/README_en.md:778`；代码 `f_llm/src/config/LLMConfig.cj:199-204`；判定 `f_llm/src/balance/BalanceQuerier.cj:136`
- **来源**：存量（快照模式无基线）
- **判据**：review-checklist §13（配置默认值与源码不符）
- **证据**：静态确定 —— README 默认列写「无 / none」，`getBalanceLowThreshold()` 返回 `Config.getValue<Int64>(...) ?? 100`
- **描述**：按 README 理解「不配就没有告警」，实际不配时所有 < 100 的余额都会被标 `low` 并打 warn。README 属本模块其它部分范围，此处因涉及本部分阈值判定一并记录，合并时归到 README 的 §13。
- **建议**：README 默认值改 `100`，或代码默认改为「不告警」并同步注释。

### [轻微][存量] 余额查询失败也抛 `BalanceUnsupportedException`，与「平台未实现」混为一类

- **位置**：`f_llm/src/balance/BalanceQueriers.cj:150-155`（腾讯 `Error`）、`:214-221`（火山 `Error`）；异常定义 `f_llm/src/balance/BalanceQuerier.cj:57-62`
- **来源**：存量（快照模式无基线）
- **判据**：review-checklist §11（语义与命名 / 注释不符）
- **证据**：静态确定 —— `BalanceUnsupportedException` 的注释是「平台没有可用的余额查询实现」，但两个 `parse*` 在上游返回 `Error`（鉴权失败、限流）时也抛它
- **描述**：调用方无法区分「该平台不支持」与「本次查询失败」；现在 `queryAll` 用 `catch(e: Exception)` 兜住，暂时无行为差异，但任何按类型分支的上层都会误判。
- **建议**：新增 `BalanceQueryFailedException`（或复用 `LLMException`）表达上游错误，`Unsupported` 只留给未实现平台。

### [轻微][存量] 腾讯/火山请求 URL 与签名器各写一份 host/action/version，存在漂移风险

- **位置**：`f_llm/src/balance/BalanceQueriers.cj:142`（腾讯 host）与 `f_llm/src/balance/sign/Signers.cj:109`；`BalanceQueriers.cj:204-206`（火山 action/version）与 `Signers.cj:150-155`
- **来源**：存量（快照模式无基线）
- **判据**：review-checklist §2（字面量复制）
- **证据**：静态确定 —— 火山 URL 里手写 `Action=QueryBalanceAcct&Version=2022-01-01`，同时又把同样两个字面量作为参数传给 `VolcSigner.headers`；腾讯 host 在 URL 与签名器的 `canonicalHeaders` 各写一次
- **描述**：改版本号或 host 时只改一处，签名就会对不上（表现为 403，而不是编译错误），排障成本高。
- **建议**：把 host/action/version 提成 `Signers` 或 `BalanceQueriers` 的常量，URL 与签名串都从同一组常量拼。

### [轻微][存量] 多币种余额共用一个无单位阈值

- **位置**：`f_llm/src/balance/BalanceQuerier.cj:135-145`；阈值来源 `f_llm/src/config/LLMConfig.cj:199-204`；多币种用例 `f_llm/src/balance/Balance_test.cj:25-32`
- **来源**：存量（快照模式无基线）
- **判据**：review-checklist §11（注释与实现不符 / 契约）
- **证据**：静态确定 —— `LLMConfig` 注释写「与余额同币种口径」，但 `getBalanceLowThreshold()` 只返回一个 `Int64`，`mark()` 直接拿 `snapshot.totalValue < threshold`，不读 `snapshot.currency`
- **描述**：DeepSeek 同时返回 CNY 与 USD 时，100 的阈值会按同一数值套到 USD 上（90 USD 被标 low，110 USD 反而正常）；多平台汇总时也无法按币种配置。
- **建议**：阈值改为按币种配置（`llm_balanceLowThreshold_<currency>` 或 JSON map），缺省回落到一个基准币种并显式换算/标注。

### [轻微][存量] `perf-retrieval-candidates` 的「默认 400 条候选」只落实到带 embedder 的构造

- **位置**：文档 `f_llm/doc/spec/perf-retrieval-candidates/specs/loom-flow/spec.md:15-18`、`tasks.md:9`；代码 `f_llm/src/store/mysql/KnowledgeStore.cj:41,45`（1000）与 `:55`（400），`f_llm/src/store/postgres/KnowledgeStore.cj:40,44` 同构；可达路径 `f_llm/src/store/mysql/ContentStore.cj:50`
- **来源**：存量（快照模式无基线）
- **判据**：review-checklist §13（规格与实现漂移）
- **证据**：待确认 —— 无 embedder 的 `MySqlKnowledgeStore()` 仍用 `maxCandidates=1000`，而 `ContentStore` 在 `model == None` 时正走这个构造；spec 的 Scenario 写「默认参数 → 最多 400」
- **描述**：若「默认参数」指无 embedder 的词面路径，则 spec 的验收口径与实现不一致；这类部署仍会拉 1000 条候选，与本次性能变更的目标相反。
- **建议**：确认无 embedder 路径是否是生产默认；是则把 1000 也降到 400，或把 spec 措辞限定为「带 embedder 的默认参数」。

<!-- 第 8 部分 -->

### [严重][存量] 接收落盘目录 `downloadDir` 不过沙箱：模型可控参数可向任意可写目录新建文件

- **位置**：`f_llm/src/channel/EmailChannel.cj:258-278`（`receive` 把 `downloadDir` 原样交给 `AttachmentSink.save`）、`:148-155`（`save` 只校验「非空 + 存在」）
- **来源**：存量（`git blame -L 148,177` 指向 2026-11-06 `6d706eb81f`）
- **判据**：review-checklist §10（安全性：外部输入未校验）+ §11（同一约束在两个方向上不对称）
- **证据**：静态确定 —— ①发送方向有白名单（`EmailChannel.send:204-217` → `checkAttachment:220-246`，越界即整封失败）；②接收方向只有 `dir.isEmpty()` / `!exists(dir)` 两个判断；③`downloadDir` 来自工具入参 `ChannelInboxParam.downloadDir`（`ChannelFunctions.cj:64`，由模型调用时直接填，`ChannelFunctions.cj:126` 无二次校验）；④项目自身把模型可见的文件操作钉在沙箱里：`f_llm/src/tool/AbstractFileFunction.cj:31`、`CommandFunction.cj:55`。
- **描述**：`channelInbox` 的 `downloadDir` 是模型可控参数。提示注入可让模型取 `downloadDir=/home/u/.ssh`，再用攻击者邮件里的附件名投放 `authorized_keys`（`freeName` 会避开已存在文件，因此**新建**而非覆盖，但新建已足够）；同理可向 `~/.config`、`/etc/cron.d` 等可写目录写入内容。第 1 稿定为「一般」，本稿按「安全漏洞」口径上调为**严重**：绕开了本仓对模型可见文件操作的统一沙箱约定。README:558 只承诺「发送按路径给出且必须在允许根目录内」，接收方向未写限制。
- **建议**：接收侧复用同一套根目录语义（`channelSendRoots()` 或独立的 `llm_channelReceiveRoots`），`canonicalize(downloadDir)` 必须落在允许根之内，否则单条附件返回 `error` 而不写入；同时把该约束写进 README 通道配置表。

### [严重][存量] 收信路径全量物化且无上限：附件整块进内存 + `limit` 无上界

- **位置**：`f_llm/src/channel/EmailChannel.cj:260`（`for (mail in transport.receive(limit))`）、`:269`（`AttachmentSink.save(downloadDir, item.filename, item.read())`）、`:360`（`ReceivedAttachment(..., {=> item.read()})`）、`:351-356`（`email().list(limit: limit)` + 每封 `email().body(summary)`）
- **来源**：存量（同上，`6d706eb81f`）
- **判据**：review-checklist §5（一次性物化 / 无界容器 / 无拒绝路径）
- **证据**：静态确定 —— ①`EmailChannel.receive` 把 `limit` 原样下传，自身无上限；②`f_email/src/EmailFacade.cj:252-258` 的 `Email.list` 规定 **`limit <= 0` 表示全部**，而公共入口 `ChannelMediator.receive`（`ChannelMediator.cj:203-205`）直接转发，`0`/负数不会被拒；③每个附件的字节由 `ReceivedAttachment.read: () -> Array<Byte>`（`EmailChannel.cj:29`）整体返回，落盘前必须先拿完整数组；④`f_email/src/EmailFacade.cj:141-155` 的 `MailAttachment.read()` 用 `ArrayList<Byte>` 逐字节 `add` 再 `toArray()`（≈2× 附件字节 + 扩容余量）。
- **描述**：三层叠加成无界内存面：邮件数（`limit` 无上限、`<=0` 语义反转）× 每封正文（`body()` 整封 fetch）× 每个附件（2× 字节）。峰值 ≈ Σ(正文 + 2×附件字节)。`InboundAttachment.size` 已带回字节数，代码里没有任何一处用它做拒绝；工具侧 `ChannelFunctions.cj:119-121` 只保证「`<=0` 时取 10」，正数一律放行。第 1 稿把「单附件物化」写成优化方案，本稿按「无界增长导致 OOM」口径升级为**严重**，因为 `limit` 与 `downloadDir` 都来自模型输入，不是内部常量。
- **建议**：`Channel.receive` 对 `limit` 做 `[1, 上限]` 夹取并显式拒绝 `<=0`（不要落到 f_email 的「全部」语义）；附件通道改为流式（`open(): InputStream` 或 `saveTo(path: Path)`，复用 `EmailFacade.cj:158-180` 的 64 KiB 缓冲）；超过配置上限（如 `llm_channelAttachmentMaxBytes`）直接记 `error`、不落盘。

### [一般][存量] 只有 HTML 正文的邮件，正文被静默丢成空串

- **位置**：`f_llm/src/channel/EmailChannel.cj:357`（`let text = body.text ?? ''`），所在函数 `FEmailTransport.receive:351-374`
- **来源**：存量（`git blame` 指向 `6d706eb81f`，2026-11-06）
- **判据**：review-checklist §11（数据丢失）+ §3（`case None` 兜底把内容吃掉）
- **证据**：静态确定 —— `f_email` 的 `MailBody` 同时给出 `text: ?String` 与 `html: ?String`（`f_email/src/EmailFacade.cj:189-193`），`f_email/src/model/MailMessage.cj:97` 说明 `text()` 只取 `text/plain`；`html` 在 `f_llm/src/channel/` 里零引用（只命中发送侧 `EmailChannel.cj:329-332`），收发不对称。
- **描述**：大量真实邮件是 `text/html` 单段（营销、通知、企业系统邮件），`message.text()` 返回 `None` → `InboundMessage.text` 为空串 → `ChannelFunctions.render` 把 `"text":""` 交给模型（`ChannelFunctions.cj:142`）。调用方无法区分「正文为空」与「邮件没有纯文本段」，模型只能看到标题、发件人和附件。
- **建议**：`let text = body.text ?? body.html ?? ''`；若要保留语义差别，可在 `InboundMessage` 加 `textKind`（`plain`/`html`）。补一条「只有 html 段」的 `FEmailTransport.receive` 用例。

### [一般][存量] `InboundMessage.receivedAt` 恒为空串：可用的收信时间没接线

- **位置**：`f_llm/src/channel/EmailChannel.cj:363`（`receivedAt: ''` 硬编码）
- **来源**：存量（`git blame` 指向 `6d706eb81f`）
- **判据**：review-checklist §14.1（接线缺失）+ §11（契约与实现不符）
- **证据**：静态确定 —— ①`MailSummary` 带 `date: ?MailDate` 与 `receivedAt: ?MailDate`（`f_email/src/EmailFacade.cj:59-60`），IMAP 分支已填 `receivedAt: imapDate(item.internalDate)`（`EmailFacade.cj:309`）；②`f_llm` 侧只有 `EmailChannel.cj:363` 一处构造 `ReceivedMail`，写死空串；③该字段会被渲染进工具结果（`ChannelFunctions.cj:142`），README:934 也把它列为公开字段。
- **描述**：唯一已实现的通道产出的每封信 `receivedAt` 都是 `""`，模型无法按时间排序或判断新旧。POP3 分支 `receivedAt` 为 `None` 但 `date` 有值，可直接回落。`EmailChannel_test.cj:113` 用假数据填了该字段，测试因此看不出生产路径恒空。
- **建议**：`receivedAt: (summary.receivedAt ?? summary.date)?.toString() ?? ''`；补一条「摘要带日期 → 输出非空」的用例。

### [一般][存量] 发送侧 `html` 非空即丢弃 `text`，未走 multipart/alternative

- **位置**：`f_llm/src/channel/EmailChannel.cj:329-333`
- **来源**：存量（`git blame -L 329,333` 指向 2026-11-06）
- **判据**：review-checklist §11（能力被丢弃）+ §14.1（只做了一半的分支）
- **证据**：静态确定 —— 代码是 `if (html.isEmpty()) builder.text(...) else builder.html(...)`，永远只调一个；`f_email/src/model/MailMessage.cj:176` 明确「`text` + `html` 同时存在时自动生成 `multipart/alternative`」，`Message_test.cj:99-115` 即该用例。`OutboundMessage`（`ChannelContract.cj:60-74`）同时提供两字段且无「二选一」说明。
- **描述**：调用方同时给纯文本与 HTML 时纯文本被静默丢弃：邮件只带单 part，纯文本客户端/网关看到空正文且无法降级。这是上层把已有能力收窄，不是 f_email 的限制。
- **建议**：两个字段都非空时都调（`builder.text(...)` + `builder.html(...)`），交给 `MailMessage` 生成 `multipart/alternative`；两者皆空时返回明确的 `SendReceipt.failure`。

### [一般][存量] `ModelNames.normalize` 默认分支不做小写化：小写匹配、原样返回，能力判断会漂

- **位置**：`f_llm/src/constant/ModelNames.cj:33-47`（`match(trimmed.toAsciiLower())` 各 `case` 返回常量，`case _ => trimmed`）
- **来源**：存量
- **判据**：review-checklist §11（语义与实现不符）+ §10（正确性：同一函数两套归一规则）
- **证据**：静态确定 —— 匹配用 `toAsciiLower()`，未命中却返回**未小写**的 `trimmed`。唯一调用点 `f_llm/src/llm/ModelCapabilities.cj:42-52` 用它做等值比较（`model == MODEL_NAME_DEEPSEEK_FLASH` 等）。因此 `'DeepSeek/DeepSeek-Flash'`（带平台前缀）能归一到常量，而裸名 `'DeepSeek-Flash'` / `'GLM-5'` 被原样返回、比较失败。`ModelNames_test.cj:25-45` 只覆盖带前缀的大小写混写（`:28`），未覆盖裸名大写。
- **描述**：`conf.actualLlmName` 由配置/DB 提供，大小写不受框架约束。写成 `DeepSeek-Reasoner` 时 `ModelCapabilities.resolve` 落到默认 `Toggle`，`ThinkingPolicy` 不移除 `temperature`，上游可能 400 或静默忽略参数；`isFlash('DeepSeek-Flash')` 同样返回 `false`。注释已写明「归一**只用于能力判断/日志分类**」，补齐小写化不影响实际发出的模型名。
- **建议**：`case _ => trimmed.toAsciiLower()`，注释注明「返回值恒为小写，报文请用 `conf.actualLlmName`」；补 `normalize('DeepSeek-Flash')` / `normalize('GLM-5')` 用例。

### [一般][存量] `FEmailTransport` 惰性建连无任何同步：共享实例上的 `Email` 会被并发读写

- **位置**：`f_llm/src/channel/EmailChannel.cj:293-316`（`private var client: ?Email` + `email()` 的「读-建-写」）、`:376-384`（`close()` 置 `None`）
- **来源**：存量（`git blame` 指向 `6d706eb81f`）
- **判据**：review-checklist §12.1（共享可变状态无保护 / 惰性初始化竞态 / 跨线程资源）
- **证据**：静态确定 —— 共享路径：`ChannelMediator.instances`（`ChannelMediator.cj:37`，`static let`）→ `channel():152-197` 把**同一个** `Channel` 引用交给任意调用者 → `EmailChannel.send/receive` 直接调 `transport`。`FEmailTransport.client` 的赋值（`:314`）与读取（`:301-303`）都在无锁区，该文件与 `EmailChannel` 内既无 `Mutex` 也无 `synchronized`。`Email` 自身是「懒连接 + 会话状态」：`f_email/src/EmailFacade.cj:214-221` 持有 `smtpValue/imapValue/pop3Value/currentMailbox/selectedMailbox`，类注释未声明线程安全、全文件无 `Mutex`。
- **描述**：两条后果：(1) **首次并发建连竞态** —— 两线程同时看到 `None` 各建一个 `Email`，后写者覆盖前者，先建那个的 socket 再无引用可达，`close()` 只关最后一个 → 连接泄漏 + 重复认证；(2) **共享会话并发使用** —— 即便初始化完成，多线程同时 `send`/`receive` 打在同一个 `Email` 上，IMAP 命令-响应序列与「当前 mailbox」状态互相穿插，可能协议错位、取到别人的正文或直接抛 `ChannelException`。是否真并发取决于 agent 任务调度，**这一点需实测**，故本稿定为「一般」而非严重；但「代码层面无任何同步手段」是静态事实。
- **建议**：给 `email()` 加锁（双重检查 + 锁内二次判空），并把「同一 transport 上的 send/receive」串行化；更好的做法是 `Channel` 无状态、每次操作从连接池取独占连接（`f_email` 已支持 `MailSummary` 定位，复用连接不是硬需求）。

### [一般][存量] 全局锁内调用 `Channel.close()`：锁里做网络 I/O

- **位置**：`f_llm/src/channel/ChannelMediator.cj:98-114`（`register` 在 `synchronized(mutex)` 内 `previous.close()`）、`:208-219`（`closeAll` 在同一把锁内逐个 `close()`）
- **来源**：存量
- **判据**：review-checklist §6.2 / §12.2（锁内 I/O、锁内调用外部实现）
- **证据**：静态确定 —— `mutex` 是类级 `static let`（`:35`），`register` 临界区含 `instances.get` → `previous.close()` → `instances[key] = channel`；`closeAll` 遍历全部实例逐个 `close()` 再 `clear()`。`EmailChannel.close():286-288` → `FEmailTransport.close():376-384` → `f_email` 的 `Email.close()`（`EmailFacade.cj:421-447`，逐协议 `close()`，必发 QUIT/LOGOUT 并等响应）。
- **描述**：重装配（`ChannelBootstrap.install` 可重复调用，`ChannelBootstrap.cj:74` 逐条 `register`）或收尾（`closeAll`）时，全局锁在「等远端 QUIT 响应」的整段时间被持有：期间 `channel()`/`send`/`receive`/`platforms()` 全部阻塞；若 `close()` 因半死连接挂住（f_email 关闭路径无独立超时），所有工具调用一起卡住。未来接入的平台若在 `close()` 里回调中介者，`Mutex` 不可重入 → 自死锁。附带风险：`channel()` 返回共享引用，`register` 换新时关闭旧实例，正在使用旧实例的线程会遇到「已关闭的连接」（是否可触发取决于是否运行期重装配，见待验证假设 #3）。
- **建议**：锁内只做「取出旧实例 + 替换」，出锁后再 `close()`；`closeAll` 先在锁内 `swap` 出快照并 `clear`，再锁外逐个关。

### [一般][存量] `checkAttachment` 在根目录不可解析时 `continue` 吞掉原因，误报为「附件越界」

- **位置**：`f_llm/src/channel/EmailChannel.cj:230-245`（重点 `:232-236`），根目录来源 `f_llm/src/config/LLMConfig.cj:227-244`
- **来源**：存量
- **判据**：review-checklist §11（错误处理静默）+ §10（可诊断性）
- **证据**：静态确定 —— ①`canonicalize(Path(root))` 抛异常时 `catch { continue }`，该 root 被静默跳过，最终统一落到 `:245` 的 `attachment outside allowed roots`；②`channelSendRoots()` 的回落分支（`LLMConfig.cj:239-242`）只 `trimAscii` 取 `llm_fileSandboxPath` 原串，不像 `getFileSandboxPath()`（`:219-221`）那样先建目录，所以「只配了 sandbox 路径且目录尚未创建」是可达状态。
- **描述**：根目录写错、无权限、尚未创建时，用户看到的是「附件的路径不在白名单内」而不是「白名单根目录不可解析」，排查方向被带偏；同一个配置项在两处行为也不一致（一处建目录、一处不建）。
- **建议**：`canonicalize` 失败时把原因并入错误消息（区分「root 不可用」与「附件越界」），并保留最后一个失败原因；`channelSendRoots()` 回落分支复用 `getFileSandboxPath()` 的结果。

### [一般][存量] `LLMConfig.getPath` 在 getter 里建目录且不捕获异常；路径是文件时仍当目录返回

- **位置**：`f_llm/src/config/LLMConfig.cj:205-218`（`getPath`），调用方 `:219-221`、`:251-253`
- **来源**：存量
- **判据**：review-checklist §11（错误处理缺失、语义与命名不符）+ §10（设计合理性）
- **证据**：静态确定 —— `if (!exists(path)) { Directory.create(path, recursive: true) }` 无 `try`；`exists(path)` 为真时不再区分文件/目录，直接把该 `Path` 返回。调用点 `f_llm/src/tool/AbstractFileFunction.cj:31`、`f_llm/src/tool/CommandFunction.cj:55` 在每次文件工具调用时都会走到这里。
- **描述**：一个「读配置」的函数带创建目录的副作用：(1) `llm_fileSandboxPath` 指向无权创建的位置时，每次工具调用抛 `FileException`，错误与「文件操作」无关且无上下文；(2) 配置误指向已存在的**文件**时 `exists` 为真 → 返回文件路径当沙箱根，后续 `join(p)` 得到 `file/xxx`，失败点被推到写入阶段。
- **建议**：拆成 `sandboxPath(): Path`（纯读）与 `ensureSandboxPath(): (Path, String)`（建目录并返回错误原因）；`exists` 为真时补 `isDirectory` 判定。

### [轻微][存量] 死代码两处：`freeName` 的 `while(true)` 之后不可达；测试替身 `closed` 只写不读

- **位置**：①`f_llm/src/channel/EmailChannel.cj:134-142`（循环后的 `base`）；②`f_llm/src/channel/EmailChannel_test.cj:33`（`public var closed: Bool = false`）与 `:52-54`（唯一写入点）
- **来源**：存量
- **判据**：review-checklist §1（不可达语句 / 读了不用）
- **证据**：静态确定 —— ①`while (true)` 体内只有 `return candidate` 与 `index++`，无 `break`，循环后的 `base` 永不执行（是否为满足编译器类型检查而保留：待确认）；②全仓搜 `.closed` 只命中 `ChannelMediator_test.cj:192,193,224,225`（那是 `FakeChannel.closed`），`FakeEmailTransport.closed` 零读取点，也没有用例调用 `EmailChannel.close()`。
- **描述**：①典型「改成无限循环后忘删回退值」——读者会误以为存在「找不到空名就回退原名」的兜底，而该路径实际可能覆盖已有文件；②`close()` 的副作用无人断言，`EmailChannel.close → FEmailTransport.close`（含 `client = None` 重置）整条链路在测试里没被覆盖。
- **建议**：①删除 `:142` 的 `base`，或在循环里加探测上限并把它作为真实兜底；②补一条 `channel.close()` 后 `@Expect(transport.closed, true)` 的用例，否则删字段。

### [轻微][存量] `bareName` 按「字符数」截断，120 个多字节字符仍可能超过文件名上限

- **位置**：`f_llm/src/channel/EmailChannel.cj:99-110`（`MAX_NAME_CHARS = 120`，`for (rune in tail.runes())` 计 `count`）
- **来源**：存量
- **判据**：review-checklist §11（边界）+ §10（外部输入未校验）
- **证据**：静态确定 —— 截断单位是 rune，落盘用字节长度受限的底层 API：120 个 3 字节汉字 = 360 字节，超过常见文件系统 255 字节的单段名上限。
- **描述**：远端附件名长且为中文时 `File.create` 抛异常，`save` 返回 `('', 'write attachment failed: …')`。功能上是优雅失败，但用户只看到写盘失败，且原名已被截断，排查时对不上号。
- **建议**：按字节累加（`rune.toString().size`）并以 ~200 字节为界，保留扩展名。

### [轻微][存量] `AttachmentSink.save` 写失败后不清理已创建的文件

- **位置**：`f_llm/src/channel/EmailChannel.cj:160-176`（`File.create` 在锁内先建，`write` 在锁外，`catch` 只返回错误串）
- **来源**：存量
- **判据**：review-checklist §11（资源不对称 / 失败路径未清理）
- **证据**：静态确定 —— `catch` 分支只 `return ('', 'write attachment failed: …')`，没有 `delete`；`finally` 只 `close()`。
- **描述**：磁盘满或写入中途失败会留下 0 字节/半截文件；下次同名附件落盘时 `freeName` 看到它存在会顺延成 `-2`，垃圾逐步累积，用户也可能把半截文件当完整附件。
- **建议**：失败路径 `try { delete(Path(target)) } catch (_) {}`，或在 `finally` 里按成功标志决定是否删。

### [轻微][存量] `close()` 异常被静默吞掉且无日志：连接泄漏没有任何痕迹

- **位置**：`f_llm/src/channel/ChannelMediator.cj:106-110`、`:211-215`；同类 `f_llm/src/channel/EmailChannel.cj:366-372`（`receive` 部分结果后丢弃剩余失败）、`:171-175`（`save` 的 `finally`）
- **来源**：存量
- **判据**：review-checklist §3（`catch {}` 静默吞异常；此处无契约要求静默，降为轻微）+ §11
- **证据**：静态确定 —— 四处 `catch` 体都是 `()` / `{}`，无日志；`ChannelMediator` 内无 `LoggerFactory`（文件头只有 `std.collection/sort/sync`），`EmailChannel.cj:366-372` 在 `result` 非空时连 `e` 都不使用。
- **描述**：`close` 是对外连接的唯一释放点，关失败既不重试也不记录，`instances` 又被替换/清空，旧连接彻底失去引用，只能在 OS 层看到 CLOSE_WAIT 堆积。收信中途失败时调用方拿到「部分邮件」，无法区分「邮箱只有这些」与「第 N 封之后失败」。与本仓「日志走 `f_log`」的约定（`fountain-baseline.md` §6）不一致。
- **建议**：四处按 `f_log` 记 `warn`（带平台/账号/已完成条数）；`receive` 的部分失败在返回值里带出，至少不能静默。

### [轻微][存量] 重复逻辑：「平台是否已实现」的判定与「不支持」消息三处复制

- **位置**：`f_llm/src/channel/ChannelMediator.cj:91`（`create`）、`:172-181`（`channel` 有账号分支）、`:185-195`（`channel` 空账号分支）
- **来源**：存量
- **判据**：review-checklist §2（字面量复制 + 换控制流）
- **证据**：静态确定 —— `'channel platform not supported: ${…}'` 三处逐字相同；`:173-179` 与 `:187-193` 是同一段「取 `providers.contains(name)` → 不支持则抛 → 否则抛 not found」，只差上游条件与错误文案尾缀。
- **描述**：`channel()` 两段判定分别在「账号非空未命中」与「账号为空且零实例」路径上重复，`create()` 是同一语义的第三种写法；改一处漏一处会让不同入参给出不同的「不支持」文案。
- **建议**：抽 `private static func requireProvider(name: String, raw: String): Unit`（锁内取快照、锁外判定），`create` 与 `channel` 共用；两处 `not found` 保留各自文案并注释说明差异。

### [轻微][存量] `EmailChannel.isDirectory` 用 `canonicalize("<path>/.")` 复刻 std 能力

- **位置**：`f_llm/src/channel/EmailChannel.cj:248-256`
- **来源**：存量
- **判据**：review-checklist §2（标准库已有同语义实现）+ §10（标准库利用）
- **证据**：静态确定 —— `std.fs` 提供 `FileInfo.isDirectory(): Bool`（`stdlib/doc/libs/std/fs/fs_package_api/fs_package_structs.md:645-648`，另有 `isRegular`/`isSymbolicLink`）；本仓 `f_io/src/ExtendPath.cj:86-90` 已在用 `FileInfo.isRegular()` / `isSymbolicLink()`。
- **描述**：靠「拼 `/.` 再规范化」判目录，语义依赖 `canonicalize` 对「文件 + `/.`」抛异常这一未文档化细节，且每个附件多一次系统调用。第 3 部分已指出 `checkAttachment` 缺 `isRegular`/符号链接校验，改用 `FileInfo` 可一并解决。
- **建议**：`FileInfo(Path(actual)).isDirectory()`，异常/不存在按拒绝处理。

### [轻微][存量] 数值型配置项没有下界校验，0/负数把「保护」变成「立即失效」

- **位置**：`f_llm/src/config/LLMConfig.cj:177-183`（`getStreamIdleTimeout` / `getStreamMaxLineBytes`）、`:168-170`（`getCooldownDuration`）、`:164-166`（`getFailureThreshold`）、`:131-134`（`getEmbeddingRetries`）
- **来源**：存量
- **判据**：review-checklist §11（缺少边界校验）+ §10（错误处理）
- **证据**：静态确定 —— 四个 getter 都是 `Config.getValue<Int64>(k) ?? <default>` 直接返回，无 `max(0)`、无上限。`Duration.second * (-1)` 得负 `Duration`（`std` 文档：`Duration` 范围 `[-2^63, 2^63)` 秒，只在越界时抛 `ArithmeticException`，不拒绝负数）；`Int64.Max` 秒的默认值已核对 `Duration.Max = (0x7FFF_FFFF_FFFF_FFFF, 999999999)`，**不会溢出**。
- **描述**：`llm_streamIdleTimeout=0`/负数会让流式读「每次判断都已超时」，与「防半死连接」的意图相反；`llm_cooldownSeconds` 为负会让熔断立即恢复；`llm_streamMaxLineBytes=0` 会让 SSE 首行即判超限。具体表现取决于使用点（`src/llm/**`，不在本部分），故只报边界缺失。
- **建议**：getter 内 `let v = … ?? default; if (v <= 0) { log.warn{…}; default } else { v }`，并给 `streamMaxLineBytes` 加上限（如 32 MiB）。

### [轻微][存量] Windows 下附件「是否在根目录内」的判定恒不成立

- **位置**：`f_llm/src/channel/EmailChannel.cj:237`（`actual == base || actual.startsWith('${base}/')`）
- **来源**：存量
- **判据**：review-checklist §11（契约与实现不符：跨平台语义）+ §10
- **证据**：静态确定（有文档依据）—— `std.fs` 文档写明 Windows 路径分隔符为 `\`（`stdlib/doc/libs/std/fs/fs_package_api/fs_package_structs.md:1186-1188`），而前缀比较硬编码 `/`。
- **描述**：`canonicalize` 在 Windows 返回 `D:\data\a.pdf` 形态，`base` 为 `D:\data`，`startsWith('D:\data/')` 为假 → 位于允许根内的附件全部被判 `outside allowed roots`，发信整体失效。是否需要支持 Windows 运行期部署待确认（`fountain-baseline.md` §1 只写了在 WSL 编译/测试；`f_llm/cjpm.toml` 有 `x86_64-w64-mingw32` target），故列轻微。
- **建议**：改用 `Path(actual).parent` 逐级比对，或统一分隔符后再比较；补「根目录末尾带分隔符」用例（`root='/data/att/'` 时 `'${base}/'` 会变双斜杠）。

### [轻微][存量] `register` 的文档注释与空账号实现相反

- **位置**：`f_llm/src/channel/ChannelMediator.cj:95`（注释「同 `(platform, account)` 重复登记按最新一次覆盖」）vs `:99-103`（空账号第二次登记直接 `throw`）
- **来源**：存量
- **判据**：review-checklist §11（语义与注释不符）
- **证据**：静态确定 —— 注释无「除空账号外」限定；`ChannelMediator_test.cj:198-211` 的用例名即 `testRegisterBlankAccountTwiceThrows`。
- **描述**：调用方照注释会以为「重复登记安全幂等」，实际空账号第二次抛异常，`ChannelBootstrap.install` 把它记成 `skipped` + error（`ChannelBootstrap.cj:76-79`），表现为「配置里两条同平台无账号条目只生效一条」。
- **建议**：注释改成「同键覆盖；账号留空时只允许一个实例，第二次登记抛 `ChannelException`」。

### [轻微][存量] `closeAll` 的「进程退出」路径未接线

- **位置**：`f_llm/src/channel/ChannelMediator.cj:207-219`（全仓仅 `ChannelMediator_test.cj:222` 调用）
- **来源**：存量
- **判据**：review-checklist §14.1（接线缺失）+ §11（注释承诺未兑现）
- **证据**：静态确定 —— `grep -rn "closeAll" --include=*.cj f_llm/src` 只命中定义与测试；`ChannelBootstrap` 只 `register`（`ChannelBootstrap.cj:74`），无关闭调用。注释写「进程退出 / 重装配用」。
- **描述**：注释承诺的关闭入口没有生产调用点，SMTP/IMAP 连接只能靠进程退出回收；`reset()` 被描述为「重装配用」但只 `instances.clear()`，每次重装配都遗留旧连接。
- **建议**：把 `closeAll` 接到模块卸载/优雅停机钩子（`fboot` 无钩子则在 `ChannelBootstrap` 提供 `shutdown()`）；`reset()` 注释改为「仅测试用」。

### [轻微][存量] 默认模型 `'chat-pro'` 复制两份；`_a2aEnabled` 键名内联未走常量

- **位置**：`f_llm/src/config/LLMConfig.cj:117-119` 与 `:156-158`（同为 `?? 'chat-pro'`）、`:66-68`（`LLM + '_a2aEnabled'`）
- **来源**：存量
- **判据**：review-checklist §2（字面量复制）
- **证据**：静态确定 —— 两处 getter 默认值相同但语义不同（裁剪 vs 摘要）；同文件其余键一律「`public static const` + getter」，只有 `_a2aEnabled` 在函数体里拼键名。
- **描述**：改默认模型要同时改两处，漏一处会出现两条路径用不同默认模型；`_a2aEnabled` 键名无法被外部引用/检索，与同文件约定不一致。
- **建议**：抽 `private static const DEFAULT_CHAT_LLM`（若两处允许独立演进则各留一个常量并注释）；`_a2aEnabled` 补 `public static let LLM_A2A_ENABLED`。

### [轻微][存量] 测试的全局状态不回收，且有两处断言可因错误原因通过

- **位置**：①`f_llm/src/channel/ChannelFunctions_test.cj:126`（`Config.set(llm_channelSendRoots, dir)` 后无 `Config.remove`）；②`f_llm/src/channel/ChannelMediator_test.cj:135-146`（注册 `demo` provider 后只 `reset()`，provider 表不清）；③`f_llm/src/channel/ChannelMediator.cj:228-234`（`resetAll` 注释称给「验证注册表本身」的用例用，全仓无调用者）；④`f_llm/src/channel/EmailChannel_test.cj:101-103`（`error.contains('ghost.pdf')`）；⑤`f_llm/src/channel/EmailChannel_test.cj:66-90`（`Config.set` 仅在末尾 `remove`，无 `finally`）
- **来源**：存量
- **判据**：review-checklist §1（无调用者）+ §11（测试隔离 / 断言质量）
- **证据**：静态确定 —— `ChannelMediator.instances`/`providers` 与 `Config` 都是进程级状态（`ChannelMediator.cj:36-37`），`reset()` 只清 `instances`（`:222-226`）；`grep "resetAll" f_llm/src` 只命中定义处。④未配置 roots 时错误串为 `attachment directory not configured (llm_channelSendRoots): ghost.pdf`（`EmailChannel.cj:208-209`），同样包含 `ghost.pdf`，所以该用例在「白名单未配置」路径上也会通过，没有真正覆盖 `checkAttachment` 的「文件不存在」分支。
- **描述**：测试类之间靠执行顺序互相污染：冒烟用例留下的 `llm_channelSendRoots` 让后续用例走「已配置」路径，`demo` provider 留在表里会让 `providerPlatforms()` 多一项、`create('demo')` 在别的用例里意外成功。`resetAll` 正为此准备却没人用，说明「知道问题但没接上」。`EmailChannel_test.cj:217-229` 已是 `try/finally` 写法，说明规范存在但未统一。
- **建议**：配置改动一律 `try { … } finally { Config.remove(...) }`；需要清 provider 的用例改用 `resetAll()`；④收紧为 `error.contains('attachment not found')`。

<!-- 第 9 部分 -->

### [严重][存量] MySQL 检索把 `namespace` / `docId` 手工拼进 SQL，转义只覆盖单引号，反斜杠可逃逸

- **位置**：`f_llm/src/dao/mysql/MemoryDAO.cj:49-59`（`mySearchDense` 的 filter 拼装，转义函数在 `:178-180` `daoEscape`）；`f_llm/src/dao/mysql/KnowledgeDAO.cj:93-102`（`chunkSearchDense` 的 `docIds` 拼装，转义为行内 `replace("'", "''")`）
- **来源**：存量（快照模式无基线）
- **判据**：review-checklist §10（安全性：注入 / 外部输入未校验）、§11（契约与实现不符）；`fountain-baseline.md` §2「参数化，不拼串」
- **证据**：静态确定 —— ①两处都把外部字符串插进 SQL 文本：`quoted += "'" + daoEscape(namespaces[index]) + "'"`（`MemoryDAO.cj:56`）、`quoted += "'" + docIds[index].replace("'", "''") + "'"`（`KnowledgeDAO.cj:100`）；②转义只把 `'` 换成 `''`，没有处理 `\`。MySQL 默认 `sql_mode` 不含 `NO_BACKSLASH_ESCAPES`，字符串字面量里 `\'` 是「转义后的引号」，因此以 `\` 结尾的值会吞掉收尾引号、把后半段逸出字面量（例：namespace = `x\` 时生成 `... IN ('x\')` 之后的文本被当作 SQL 而非字符串）；③值确实是外部输入且在生产主路径上：`namespace` 来自模型工具入参 `strOf(args, 'namespace')` → `MemoryQuery.namespaces`（`f_llm/src/loom/LoomStoreGateway.cj:176-186`）→ `MySqlMemoryRepository.searchDense`（`f_llm/src/store/mysql/MemoryRepository.cj:52-55`）→ `mySearchDense`；`KnowledgeQuery.docIds` 是 `f_llm/src/store/StoreModels.cj` 的公开构造参数（当前仓内只有测试传入，属潜在面）；④同文件/同层已有正确写法：`mySearchSparse` 用 `meet(true, 't.namespace').IN(namespaces)` 全参数绑定（`MemoryDAO.cj:91-95`），PG 的 `searchDense` 同（`f_llm/src/dao/postgres/MemoryDAO.cj:58-63`），说明内联只是 `MYVECTOR_IS_ANN` 过滤器文本无法绑定参数后的退化写法，不是业务必需
- **描述**：`MYVECTOR_IS_ANN(... , (filter))` 的第 5 个参数是「一段子查询文本」，不能放占位符，于是代码改为自行引号拼接；而自研转义不完整，构成 SQL 注入面。触发条件是 namespace/docId 含 `\`（或 `\` + 引号组合）。后果是任意 SQL 拼接（读越权数据 / 触发错误），且 `doc_id` 过滤条件可被整体短路（`OR 1=1`）导致跨文档召回
- **建议**：`annPath`（配置派生）可保留内联；`namespace` / `docId` 两种落点二选一——(a) 白名单校验后再拼（`[A-Za-z0-9_.:@-]{1,32}`，不匹配直接跳过并计数告警），(b) 按 MySQL 规则补全转义（先 `\`→`\\` 再 `'`→`''`，即 `daoEscape` 改成两替换并加注释说明「依赖 `NO_BACKSLASH_ESCAPES` 关闭」）。同时把两处引号列表构造合并到一个 `private func quoteIn(values)`（见 §2 #4），并补用例 `namespaces = ["a\\"]`、`docIds = ["a\\"]` 断言 SQL 仍能正确执行

### [一般][存量] 主键回读用「第二条语句 `SELECT LAST_INSERT_ID()`」，而 `f_orm` 在非事务路径每条语句后归还连接

- **位置**：`f_llm/src/dao/mysql/MemoryDAO.cj:42-44`（`myUpsertMemory`）、`f_llm/src/dao/mysql/MetaDAO.cj:87-93`（`confPut`）
- **来源**：存量（快照模式无基线）
- **判据**：review-checklist §11（契约与实现不符 / 跨语句依赖会话状态）、§12.1（异步语义与跨线程资源）
- **证据**：静态确定 —— ①`f_orm` 的 `execute` 在非事务路径 `finally` 里调 `this.close()`（`f_orm/src/base/SqlExecutor.cj:878-900`）；②`close()` 执行 `_connection_.close()` 并置 `NoneConnection`、从线程 current 表移除（`SqlExecutor.cj:153-171`），下一条语句经 `connection` getter 重新从连接池取连接（`SqlExecutor.cj:409-430`）；③`LAST_INSERT_ID()` 是**会话级**函数。⇒ 第二条 SELECT 与 INSERT 不保证同一物理会话。缺的数据：连接池容量与并发下两条语句是否稳定复用同一连接（`f_llm/src/store/mysql/MySqlMemoryRepository_test.cj:110` 的断言只在单线程下成立）
- **描述**：两段式「INSERT … → 另起 SELECT 取 id」在并发下可能拿到 0 或其他线程刚插入的 id。调用方后果：`MySqlMemoryRepository.upsert` 返回 0 → 随后 `upsertSparse(memoryId=0)` 把词项挂到 `memory_id = 0`（`f_llm/src/store/mysql/MemoryRepository.cj:57-66`），稀疏召回永久丢失该条；`confPut` 返回 0 → 上层索引键与主体不一致
- **建议**：改单语句回读。PG 已用 `INSERT … RETURNING id`（`postgres/MemoryDAO.cj:32-38`）；MySQL 用执行器的 `insert` 属性取 `UpdateResult.lastInsertId`（`SqlExecutor.cj:469-473`）即可，`ON DUPLICATE KEY UPDATE id = LAST_INSERT_ID(id)` 的写法与该属性兼容；或把两段包进显式事务（`tx.isSome()` 时 `close()` 不执行）。补并发用例：8 线程各 upsert 一条，断言返回值非 0、互不相同且能在库中查到

### [一般][存量] `MemoryQuery.kinds` 在 MySQL 检索路径被静默丢弃，与内存实现行为不一致

- **位置**：`f_llm/src/dao/mysql/MemoryDAO.cj:47-48`（`mySearchDense` 签名无 kind）、`:88-89`（`mySearchSparse` 签名无 kind）、`:71-77`（`myInsertToken` 固定 `field = 'm'` 同时不落 kind 维度）
- **来源**：存量（快照模式无基线）
- **判据**：review-checklist §11（契约与实现不符）、§14（只做了一半的分支）
- **证据**：静态确定 —— ①`MemoryQuery` 明确带 `kinds`（`f_llm/src/store/StoreModels.cj:61-77`），`LoomStoreGateway` 也确实把工具入参 `kinds` 传进 `MemoryQuery` 做 `search`（`f_llm/src/loom/LoomStoreGateway.cj:181-191`）；②内存实现按 kinds 过滤（`f_llm/src/store/InMemoryStores.cj:149-152`）；③MySQL 仓储的 `searchDense` / `searchSparse` 只把 `userId` / `namespaces` / `tokens` / `limit` 下推，DAO 签名里根本没有 kind 形参，`hits()` 也只是映射不加过滤（`f_llm/src/store/mysql/MemoryRepository.cj:52-55, 137-149`）；④`list` 路径反而正确下推（`myListByKind`，`MemoryDAO.cj:148-157`），说明检索路径是漏了而不是有意
- **描述**：同一个 `MemoryQuery` 在内存后端按 kind 过滤、在 MySQL 后端不过滤。表现是「检索结果里混入其它 kind（如 `session` / `note`）」，且与 `list` 的语义不一致；调用方无法感知过滤器被丢弃
- **建议**：给 `mySearchDense` / `mySearchSparse` 增 `kinds: Array<String>` 形参，用 `${meet(kinds.size > 0, 'm.kind').IN(kinds)}` 下推（与 `myListByKind` 同风格）；`mySearchDense` 的 ANN filter 子查询里同样拼 `AND kind IN (...)`（需接着 #1 做白名单/转义）。补 conformance 用例：同一数据集在 `InMemoryStores` 与 MySQL 上 `MemoryQuery(..., kinds: ['fact'])` 结果集必须一致

### [一般][存量] MySQL 记忆 DAO 读写的向量列不在仓内 MySQL 表结构里（`llm_memory.title_vec` 等 4 列）

- **位置**：`f_llm/src/dao/mysql/MemoryDAO.cj:28-33`（写入 `title_vec` / `content_vec`）、`:62`（`myvector_distance(m.title_vec, …)`）、`:79-86`（写 `title_colbert` / `content_colbert`）、`:111-121`（读同两列）
- **来源**：存量（快照模式无基线；`git log -1` 显示 `MemoryDAO.cj` 2026-11-04 仍在改，`tables-mysql.sql` 停在 2026-10-31）
- **判据**：review-checklist §11（与规格冲突）、§13（规格与实现漂移）
- **证据**：待确认（权威侧未定）—— ①`f_llm/tables-mysql.sql:110-122` 的 `llm_memory` 只有 `id/user_id/namespace/title/content/kind/save_time/update_time`，向量另立 `llm_memory_vector`（同文件 `:156-168`）；②`f_llm/doc/content-store.md:25` 与 `f_llm/doc/f_llm.md:274` 同样把向量列写在 `llm_memory_vector`；③PG 侧同名 DAO 已拆表写入（`f_llm/src/dao/postgres/MemoryDAO.cj:29-56`）；④只有测试自建的临时表把 `title_vec` 直接放在 `llm_memory` 上（`f_llm/src/store/it/CrossBackendConformance_test.cj:164-178`、`f_llm/src/store/mysql/MySqlMemoryRepository_test.cj:51`）。缺的信息：生产库实际结构（是否有未入库的 `ALTER`）、哪一侧是权威
- **描述**：若以随仓 DDL 建库，MySQL 记忆后端所有向量写入都会 `Unknown column`，即「后端整体不可用」；同时单测用的是自建表，永远测不出这个偏差。若生产库确实被手工加过列，则随仓 DDL 与文档才是错的（新部署必挂）。两种情况下都必须先对齐一方
- **建议**：二选一并同步另一侧——(a) 按 PG 拆分：`myUpsertMemory` 写 `llm_memory` 取 id 再写 `llm_memory_vector`，`mySearchDense` 改 `JOIN llm_memory_vector`、ANN 路径改 `{db}.llm_memory_vector.title_dense`，colbert 读写改到向量表；(b) 若确要单表，把 4 列补进 `tables-mysql.sql` 并补向量索引。两种都要加一条「按随仓 DDL 建空库 → upsert → dense 召回」的用例

### [一般][存量] MySQL 用 `INSERT IGNORE` 顶替 `ON CONFLICT DO NOTHING`，错误被降级为 warning 后与「0 行 = 已存在」的判定混同

- **位置**：`f_llm/src/dao/mysql/EvolutionLeaseDAO.cj:37-43`（`leaseInsert`）、`f_llm/src/dao/mysql/KindDAO.cj:38-44`（`kindInsert`）、`:52-58`（`kindInsertCustom`）、`f_llm/src/dao/mysql/EvolutionStateDAO.cj:75-81`（`knowledgeInsert`）
- **来源**：存量（快照模式无基线）
- **判据**：review-checklist §11（错误处理缺失 / 静默）、§2（跨方言实现漂移导致语义不等价）
- **证据**：静态确定（语义差异）+ 待确认（是否存在能触发的输入）—— MySQL 的 `IGNORE` 会把「数据过长被截断」「NOT NULL 写入隐式默认」等错误降级为 warning 并继续执行；PG 的 `ON CONFLICT DO NOTHING` 只吞唯一冲突，其它错误照常抛出。调用方把返回值当语义用：`EvolutionLease.ensure` / `acquire` 里 `leaseInsert(...) == 1` 表示「抢到租约」（`f_llm/src/store/mysql/EvolutionLease.cj:46-52, 69-80`）；`kindInsert(kind, …)` 的 `kind` 是用户自定义串（`f_llm/src/store/mysql/KindPersistence.cj:26-34`），列宽 `VARCHAR(32)`（`tables-mysql.sql:125-132`），仓内无长度校验
- **描述**：超长 kind 会被静默截断后写入，之后 `kindHas(原值)` 永远查不到 → 「补种」每次都报成功但库里是另一条记录；`leaseInsert` 若遇可降级错误则返回 0，被解释为「别人已持有租约」，结果是**演进任务永久不启动且无日志**
- **建议**：MySQL 侧改用 `INSERT ... ON DUPLICATE KEY UPDATE lease_id = lease_id`（保留 0 行语义）或 `INSERT ... SELECT ... WHERE NOT EXISTS`，让非唯一冲突的错误照常抛出；`kindInsert` 前后加长度校验（`kind.size > 32` 直接拒绝并告警），并在 DAO 注释里写明「返回值只表示唯一冲突，不表示写入成功」

### [一般][存量] `llm_skill_evolution` 主键由应用侧 `MAX(id)+1` 分配，仓内只有进程内互斥

- **位置**：`f_llm/src/dao/mysql/EvolutionDAO.cj:26-38`（`id BIGINT PRIMARY KEY`，无自增/序列）、`:68-71`（`maxEntryId`）；`f_llm/src/dao/postgres/EvolutionDAO.cj:26-37`、`:76-79`（同构）
- **来源**：存量（快照模式无基线）
- **判据**：review-checklist §11（并发正确性）、§12.1（检查-然后-写入非原子）
- **证据**：静态确定（DB 侧无分配器）+ 待确认（部署是否多实例）—— ①两张表都把 `id` 建成普通 `BIGINT PRIMARY KEY`，没有 `AUTO_INCREMENT` / `GENERATED … AS IDENTITY`；②DAO 只提供 `maxEntryId()`，id 计算在调用方：`MySqlEvolutionStore.save` 用 `nextId = maxIdOf(dao) + 1`，唯一保护是实例字段 `mutex`（`f_llm/src/store/mysql/EvolutionStore.cj:34-57`）；③`insertEntry` 是普通 INSERT，冲突即抛
- **描述**：多进程 / 多实例部署（或滚动发布期间新旧进程并存）时，两个进程各自从 `MAX(id)` 起算，必然出现主键冲突 —— 表现为「演进报告写不进去」或（若上层吞异常）静默丢记录。`llm_evolution_lease` 的 CAS 只串行化「当天由谁跑」，不保护 id 分配
- **建议**：把 id 交回数据库（MySQL `AUTO_INCREMENT`、PG `GENERATED BY DEFAULT AS IDENTITY`），`insertEntry` 后按 #2 的方式单语句回读；若必须保留外部指定 id（导入场景），改成「冲突时重算一次并重试」的显式 CAS 循环，而不是依赖进程内锁。DDL 变更需带 `ALTER TABLE` 迁移脚本

### [轻微][存量] 公开常量拼写错误 `THINGKING_ENABLED` / `THINGKING_DISABLED`

- **位置**：`f_llm/src/constant/ThinkingSwitch.cj:19-20`
- **来源**：存量（快照模式无基线）
- **判据**：review-checklist §10（可读性 / 命名）；属对外可达 `public`，按硬原则一不判死代码，只作可见性/命名问题
- **证据**：静态确定 —— 正确拼写为 `THINKING`；同文件 `ThinkingSwitch`（`:18`）与 `ThinkingMode`（`:23`）都是正确拼写，只有两个常量错。已有 4 处引用：`f_llm/src/llm/LLMParams.cj:57`、`f_llm/src/llm/openai/ProviderDialects.cj:160, 165, 167`
- **描述**：常量是对外契约（下游会硬编码），错拼会被复制到下游代码；改名属破坏性变更
- **建议**：新增正确名并把旧名做成别名（`public const THINKING_ENABLED = THINGKING_ENABLED`），旧名标 `@Deprecated`，下个大版本删除；同时全仓把 4 处引用切到新名

### [轻微][存量] `TodoStatus` 注释承诺 7 种状态，实现只有 6 个常量，「删除」态全仓不存在

- **位置**：`f_llm/src/constant/TodoStatus.cj:18-26`（注释列出 `⏸️ ◯ 🟡 ✅ ❌ 🔄 🗑️` 七态）、`:28-33`（只有 6 个 `TODO_STATUS_*`）
- **来源**：存量（快照模式无基线）
- **判据**：review-checklist §11（语义与注释不符）、§14（承诺但未实现）
- **证据**：静态确定 —— 全仓 `grep "🗑"` 在 `src/`、`README*.md`、`doc/` 零命中；写入侧 `TodoFunction` 直接把模型给的字符串透传（`f_llm/src/tool/TodoFunction.cj:103` `updateStatus(param.task, param.id, param.status)`），无白名单校验；`Todo` 模型默认值用 `TODO_STATUS_PENDING`（`f_llm/src/model/po/Todo.cj:35`）
- **描述**：状态词表是这套工具对外契约（模型按词表填值），但注释多出一态、代码少一个常量、写入端不校验 —— 三处都不一致，调用方无法确定合法取值集合
- **建议**：补 `TODO_STATUS_DELETED = "🗑️"` 并在 `updateStatus` 上按常量白名单校验（非法值拒绝并回错误），或从注释里删掉该态；README 的状态说明按同一份常量表生成

### [轻微][存量] `src/constant/imports.cj` 的两条 `internal import` 在整个 `constant` 包零使用

- **位置**：`f_llm/src/constant/imports.cj:18-20`
- **来源**：存量（快照模式无基线）
- **判据**：review-checklist §1（未使用的 import）
- **证据**：静态确定 —— `fountain::f_llm.constant` 包共 17 个 `.cj`，全包搜 `convert` / `exception` / `LLMException` 只在 `imports.cj` 自身命中；包内其余文件（`ConstantSize` / `KnowledgeKind` / `LLMAgent` / `Role` / `SkillType` / `SpecKind` / `ModelName(s)` / `ToolType` / `TodoStatus` / `ThinkingSwitch` / `ContextPrunerName` / `SummaryActionKind` / `SpecialAgentId`）既不用 `std.convert` 也不用 `f_llm.exception`；反向也不成环（`f_llm/src/exception/*.cj` 只 import `f_base.BaseException`）
- **描述**：该文件是「包级导入汇总」约定的残留模板：其它包（`src/agents/imports.cj:18-34`、`src/embedding/imports.cj:18-35`）的写法里每条导入都有实际使用，本包这两条没有。留着会让读者以为包内用了 `convert` / 异常类型
- **建议**：删掉这两行（或整文件），需要时再按「用到才加」补回；若确要保留包级导入约定，就在 README 的模块约定里写明「`imports.cj` 允许暂时空置」

### [轻微][存量] 演进表索引管理两方言不对称：MySQL 只在 `CREATE TABLE` 内建 KEY，没有 PG 那种幂等补建入口

- **位置**：`f_llm/src/dao/mysql/EvolutionDAO.cj:28-36`（`KEY idx_evo_skill (skill_title, at_time)` 写在建表语句里）vs `f_llm/src/dao/postgres/EvolutionDAO.cj:40-46`（`ensureSkillIndex()` 用 `CREATE INDEX IF NOT EXISTS` 单独补）
- **来源**：存量（快照模式无基线）
- **判据**：review-checklist §11（升级路径缺失）、§14（只做了一半的分支）
- **证据**：静态确定 —— `CREATE TABLE IF NOT EXISTS` 在表已存在时整句跳过，KEY 不会补；MySQL 侧没有任何 `ensureIndex` 入口（`grep ensureSkillIndex` 只在 PG DAO 与其 store 出现），PG 侧有（`f_llm/src/store/postgres/EvolutionStore.cj`）
- **描述**：表先由旧版本建出、索引后加的场景下，MySQL 部署会永久缺 `idx_evo_skill`，`listBySkill` / `listEntries` 退化为全表扫 + filesort；同一份代码在两种方言上「升级后能力不同」
- **建议**：MySQL 侧补 `func ensureSkillIndex()`：`CREATE INDEX idx_evo_skill ON ...` 包在「先查 `information_schema.statistics` 再建」或直接捕 `ER_DUP_KEYNAME`（1061）当成功；与 `ensureTable` 一起在启动期调用

### [轻微][存量] 词法回调用 `LIKE '%term%'` 但 `term` 未转义 `%` / `_`，模式会被放大

- **位置**：`f_llm/src/dao/mysql/KnowledgeDAO.cj:123-131`（`chunkSearch`）、`f_llm/src/dao/postgres/KnowledgeDAO.cj:97-105`（同构）
- **来源**：存量（快照模式无基线）
- **判据**：review-checklist §11（边界 / 契约与实现不符）、§6.4（只判存在却全量扫描）
- **证据**：静态确定 —— 模式由调用方拼成 `'%' + terms[0] + '%'`（`f_llm/src/store/mysql/KnowledgeStore.cj:119`），而 `KnowledgeSearch.terms` 只做空格切分与 `trimAscii`，不过滤通配符（`f_llm/src/store/KnowledgeSearch.cj:31-41`）。用户输入 `%` 时模式退化为 `'%%%'`（匹配全表），`_` 则匹配任意单字符
- **描述**：不构成注入（仍是参数绑定），但会让一次检索退化为「全表逐行 + 最多 `maxCandidates` 行」的扫描，并且词法命中先被放大再被 `occurrences` 打分淘汰 —— 结果正确性大致不变，代价是白扫一批页（`pageSize=200`、`maxCandidates=1000`）
- **建议**：`terms()` 里剥掉 / 转义 `%`、`_`（`\%`、`\_`），或对 `chunkSearch` 的 pattern 做同样转义后再绑定；顺手补用例：`KnowledgeQuery('%')` 的返回条数与 `KnowledgeQuery('无此词')` 一致

### [轻微][存量] 重复逻辑：`?Map` 包装模板 9 处、`Any → Int64` 解析 5 套、引号 IN 列表 2 处、`enabled AND weight > 0` 谓词 3 处

- **位置**：
  - ①`executor.setSql(...).firstToMap()` + `if(row.isEmpty()){None}else{Some(row)}`：`mysql/MemoryDAO.cj:115-120`、`:129-133`、`mysql/MetaDAO.cj:31-35`、`:113-117`、`:144-148`、`:157-161`、`mysql/KindDAO.cj:31-35`、`mysql/KnowledgeDAO.cj:31-35`、`:83-87`（PG 侧同样形态，`postgres/KindDAO.cj:36-40`、`postgres/KnowledgeDAO.cj:31-35`）
  - ②`Any → Int64`：`mysql/MemoryDAO.cj:170-176`（`daoIntOf`，只认 Int64/Int32）、`mysql/MetaDAO.cj:89-93`（行内 match `?Any`）、`f_llm/src/store/mysql/MemoryRepository.cj:190-199`（`intOf`，认 Int64/Int32/Int16/Int8/UInt64）、`f_llm/src/store/mysql/EvolutionStore.cj:128-136`（`myEvoIntOf`，另认 Float64/String）、`f_llm/src/store/mysql/KindPersistence.cj`（`kindIntOf`）
  - ③引号 IN 列表：`mysql/MemoryDAO.cj:51-58`（调 `daoEscape`）vs `mysql/KnowledgeDAO.cj:95-102`（行内 `replace`）
  - ④`enabled … weight > 0`：`src/dao/LLMConfDAO.cj:36`（`enabled = true`）、`mysql/MetaDAO.cj:58`（`enabled = 1`）、`:72`（`enabled = 1`）
- **来源**：存量（快照模式无基线）
- **判据**：review-checklist §2（表现形式不同的重复逻辑：近似重复 / 字面量复制 / 只改类型名）
- **证据**：静态确定 —— 逐组两两比对函数体「输入-输出-副作用」：①9 处语义完全一致（同一 map 形状、同一 None 语义），抽一个 `func rowOption(row: Map<String, Any>): ?Map<String, Any>` 即可；②5 套分支集合**不等价**：`daoIntOf` 对 `Int16` / `Float64` / `String` 返回 0，`myEvoIntOf` 会解析，`intOf` 认 `Int8` / `UInt64` —— 同一驱动返回值交给不同 helper 结果可能不同（当前列宽下多数走 Int32/Int64，未观察到错误，属潜在漂移）；③两处循环逻辑逐行对齐，只有「是否调用 `daoEscape`」不同（同时是 #1 的成因）；④三处是同一业务谓词的复制，且 `true` / `1` 两种写法并存
- **描述**：这四组都不是「刻意的独立演进」：①③④是纯粹的复制，②已经出现分支集合漂移。风险不在当下行为，而在「改一处忘另一处」——例如补超长 kind 校验时只改 `KindPersistence` 的 helper，或修 #1 时只改 `daoEscape` 一处
- **建议**：①抽到 `f_orm` 的 DAO 基类能力（`RootDAO.rowOption(...)`）或本包 `dao/util.cj`；②统一成一个 `daoIntOf(?Any)`，分支取并集（Int64/Int32/Int16/Int8/UInt64/Float64/String），放 `f_llm/dao` 包内供两个方言共用；③合并成 `quoteIn(values)` 并只保留一处转义（与 #1 同批修）；④把 `llm_conf` 的「启用且有权重」抽成 `const ENABLED_CONF_PREDICATE = 'enabled = true AND weight > 0'` 常量或 `SqlPartial`。合并时必须保留各方言必需差异（`LIMIT a,b` vs `LIMIT ? OFFSET ?`、`CAST(… AS SIGNED)`、`ON DUPLICATE KEY` vs `ON CONFLICT`），这些不算重复

<!-- 第 10 部分 -->

本部分没有流式（SSE）代码：`BgeM3Transport` / `Embedding` 都是同步一次性 `readEntire`，流式契约在别的分部分。客户端侧的问题集中在**共享状态、超时与重试、错误分类**；三个 DAO 的参数化是干净的（`${arg(...)}` / `meet().IN(...)`，无拼串），问题只在分页排序键与重复样板。

### [严重][存量] `HttpEmbedder` 的单槽缓存在多线程下会返回「别的文本」的向量

- **位置**：`f_llm/src/embedding/HttpEmbedder.cj:66-74`（`responseOf`），字段 `:57-59`
- **来源**：存量（`git blame`：`:58-59`、`:66-74` 均为 `89bc5e222c` 2026-10-31 引入）
- **判据**：review-checklist §12.1（共享可变状态无保护 / 检查-然后-写入 / 可见性）；§11（并发正确性）
- **证据**：静态确定 —— 共享链完整：`@Bean public class DefaultEmbedder`（`DefaultEmbedder.cj:27-37`）内部只构造**一个** `HttpEmbedder`（`:33-36`）；`f_bean` 默认 `scope = BeanScope.singleton`（`f_bean/src/BeanMeta.cj:26`），`BeanManager.bean` 对单例只 new 一次（`f_bean/src/BeanManager.cj:98-113`）；`HydraContentStore` 构造期 `lookupOption<Embedder>()` 取到该单例并以 `private let model: Embedder`（`f_llm/src/store/hydra/ContentStore.cj:30/37/69-75`）长期持有，被所有请求线程共用。`cachedText` / `cachedResponse` 是普通 `var`，读写**无锁、无原子、无线程封闭**，且写入顺序是「先 `:71` 写 `cachedText`，再 `:72` 写 `cachedResponse`」，读侧判据 `:67` 是跨这两个字段的复合判断。
- **描述**：线程 A 为文本 `x` 拿到响应 X，执行 `:71` 把 `cachedText` 置为 `x` 后、`:72` 前被切走；线程 B 此时用同一文本 `x` 调 `embed('x')`，`:67` 判 `cachedText == 'x'` 成立且 `cachedResponse.isSome()`（值仍是上一次文本 `w` 的响应 W）→ **直接返回 W**。调用方把 W 当作 `x` 的向量写入 `llm_memory_vector`（`ContentStore` → `MemoryRepository.upsert`），全程无异常无日志，属静默数据错误；同一竞态也会让「一次写入问三次、只发一次 HTTP」的优化互相顶掉（变成 3 次请求）。`Embedder` 接口（`f_llm/src/store/MemoryRepository.cj` 的接口声明）没有任何「非线程安全」约定，调用方无从规避。
- **建议**：把缓存收敛成**单个不可变条目**（`class Entry { let text: String; let response: EmbeddingResponse }`，一个 `var` 发布，读侧先取本地引用再比较），`text` 与 `response` 天然同代；或用一个 `Mutex` 只包「比较 + 引用拷贝」（`Embedding.cj:42-57` 已有同款用法）。更彻底的做法是去掉跨调用缓存，让写入方在一次记忆写入内调一次 `resolve(text): EmbeddingResponse` 后自行分发 dense / sparse / colbert。补并发用例：两线程交替 `embed("a")` / `embed("b")` 各 1000 次，断言首分量与文本一一对应。

### [严重][存量] `BgeM3Transport.embed` 每次调用都改写进程级 HTTP 超时，污染所有其它 HTTP 客户端

- **位置**：`f_llm/src/embedding/BgeM3Transport.cj:61-65`
- **来源**：存量（`git blame`：`:62-63` = `033799be37`、`:64` = `8a456f9545`，均 2026-10-31）
- **判据**：review-checklist §12.1（全局可变状态无保护）；`fountain-baseline.md` §5（配置只在启动读一次）
- **证据**：静态确定 —— `HttpClient.globalReadTimeout/globalWriteTimeout` 写的是 `private static var readTimeout_ / writeTimeout_`（`f_httpclient/src/httpclient.cj:29-36`），**没有任何同步**；每个 `HttpClient(url)` 构造时把这两个静态值套到自己的 builder 上（`httpclient.cj:41-48`）。因此每次向量化都会把**全进程**后续构造的客户端读/写超时改成 `llm_embeddingTimeoutMs`（默认 3000，`f_llm/src/config/LLMConfig.cj:127-130`）——包括对话链路、MCP、`f_http` 等无关客户端。
- **描述**：三层后果。①**跨组件副作用**：别的链路按自己的 SLO 设了 60s，一次向量化把它改成 3s，之后新建的客户端全部 3s 超时，表现为「偶发超时、重启即好」，与向量化无因果可循。②**数据竞争**：`readTimeout_` 是无同步 `static var`，向量化线程写、其它线程在构造函数读。③超时设在**重试循环之外**，重试期间别的线程改了全局值，本实例也不跟随，语义更乱。
- **建议**：删掉 `:62-65`，在 `postOnce` 里用实例级 API：`let client = HttpClient(url)` 之后 `client.readTimeout(Duration.millisecond * timeoutMs).writeTimeout(...)`（`httpclient.cj:106-117` 返回 `This`，可链式）。建连超时若要管，应补进 `f_httpclient` 的 `ClientBuilder`（`:57-59` 的注释已说明当前没有该入口），而不是用全局静态兜。

### [严重][存量] `BgeM3Transport` 无条件 `CertificateVerifyMode.TrustAll`，端点改 https 即关闭证书校验

- **位置**：`f_llm/src/embedding/BgeM3Transport.cj:90-92`
- **来源**：存量（`git blame`：`89bc5e222c` 2026-10-31）
- **判据**：review-checklist §10（安全性：外部端点未校验、静默降级）；§11（契约与实现不符：类注释只说是「传输层」）
- **证据**：静态确定 —— `postOnce` 对**任意** URL 都设 `tls.verifyMode = CertificateVerifyMode.TrustAll`，不按 host 判断回环、也没有配置开关；URL 来自 `llm_embeddingUrl`（`LLMConfig.cj:122-125`，默认 `http://127.0.0.1:8000/...`，`DefaultEmbedder.cj:33-36` 原样透传）。
- **描述**：默认回环 http 下无实际影响；一旦把 `llm_embeddingUrl` 指向 https 的内网 GPU 机、sidecar 或第三方 embedding API，证书链与主机名校验被静默关闭，中间人可返回任意向量 → 记忆库被投毒且不可观测（写入的是攻击者构造的 1024 维向量，检索命中与重排全被操纵）。
- **建议**：默认不设 `tlsConfig`（走 `CertificateVerifyMode.Default`）；仅在 host ∈ {`127.0.0.1`, `localhost`, `::1`} 时 TrustAll，并写成显式函数 + 注释；确需连自签远端时加配置项（如 `llm_embeddingInsecureTls`，默认 `false`）并在 README 标注。

### [一般][存量] `escape()` 手写 JSON 转义漏控制字符，含 `\t` / `\r` 的文本发出非法报文

- **位置**：`f_llm/src/embedding/BgeM3Transport.cj:102-104`（使用点 `:84-86`）
- **来源**：存量（`git blame`：`89bc5e222c` 2026-10-31）
- **判据**：review-checklist §11（边界 / 外部输入未校验）；§2（与 `f_data` 的 JSON 序列化重复，且复制件少了规则）
- **证据**：静态确定 —— `escape` 只处理 `\`、`"`、`\n` 三类，随后把结果直接插进 `'{"input":["${escape(text)}"],...}'`。JSON 要求 U+0000–U+001F 全部转义，`\t`、`\r`、`\b`、`\f` 及其它控制字符仍以原字节进入字符串字面量，报文非法。`f_data` 已有 `JsonObject` / `JsonArray`（`Embedding.cj:70-72` 正是用它构造报文）。
- **描述**：记忆正文里出现制表符（中文文档、代码片段、Markdown 缩进都带 `\t`）或 Windows 换行（`\r\n` 只有 `\n` 被处理）时，请求体不是合法 JSON，服务返回 4xx；再经 `:67-76` 重试 3 次仍失败，用户只看到「向量化失败」。
- **建议**：改为 `JsonArray` + `JsonObject` 序列化（与 `Embedding.cj:70-72` 同构），顺带消掉这处重复的转义实现；若坚持手写，至少补齐 `\r \t \b \f` 并对 `< 0x20` 统一 `\u00XX`。补用例：`embed("a\tb\rc")` 生成的 body 能通过 `JsonValue.fromStr` 反解。

### [一般][存量] 重试把确定性失败（4xx）也重试，`retries < 0` 时报错文案还会误导

- **位置**：`f_llm/src/embedding/BgeM3Transport.cj:67-80`（4xx 抛点 `:95-97`）
- **来源**：存量（`git blame`：`033799be37` 2026-10-31）
- **判据**：review-checklist §11（错误处理：失败路径分类不当）；§8 第 7 条（异常控制流放大）
- **证据**：静态确定 —— `postOnce` 对 `status >= 400` 一律抛 `IllegalStateException`，`embed` 的 `catch(e: Exception)`（`:70`）不看状态码，因此 400/401/404 都会被重试 `retries` 次，每次 `sleep(100/200ms)`；`0..(retries + 1)` 在 `retries < 0` 时是空区间，一次都不尝试，直接抛 `bge-m3 embedding failed without exception`（`:79`）。
- **描述**：4xx 是确定性失败，重试只增加延迟（默认 3 次 + 退避）与无效请求量，直接放大请求主路径的 P99；错误类型与模块既有的 `EmbeddingException`（`Embedding.cj:28-32`）不一致，调用方按类型降级会漏掉；负 `retries` 会把配置错误报成「服务没返回异常」。
- **建议**：按状态码抛可区分的异常（如 `BgeM3StatusException(status)`），只在 5xx / 429 / IO 异常时重试，4xx 立即上抛；入口做 `max(0, retries)`；兜底文案改成带 `retries` 与「未执行任何尝试」的可诊断消息。补用例：transport 返回 400，断言只调用 1 次。

### [一般][存量] `Embedding.parse` 逐分量吞异常补 `0.0`，把坏报文变成「合法」零向量

- **位置**：`f_llm/src/embedding/Embedding.cj:144-151`
- **来源**：存量（`git blame`：`ce152e5f22` 2026-10-28）
- **判据**：review-checklist §3（`catch` 静默吞掉异常，至少一般）；§11（失败当成功）
- **证据**：静态确定 —— `try { embedding.add(Float64.parse(value.toString())) } catch (_: Exception) { embedding.add(0.0f64) }`，注释明写「单个分量异常按 0 处理，长度保持不变」；之后只要 `embedding` 非空（`:155`）就返回成功，`holder.recordSuccess(conf.id)`（`:91`）照常记成功。
- **描述**：provider 换了数值格式（返回 `null`、字符串数字、不接受指数形式）时逐维填 0；整体不兼容时得到全零向量，长度仍等于维度，`Embedding.embed` 侧无维度/范数校验。零向量写进 `llm_memory_vector` 后 `MemoryDAO.cj:68` 的 `1 - (<=>)` 打分退化为常数，检索变成「随机命中」，而熔断器认为这次调用成功、不会切换候选。
- **建议**：区分「字段类型不符」（整个响应不可用 → 抛 `EmbeddingException`，走上层失败转移）与「个别 `NaN/Inf`」（置 0 + `f_log` warn）；至少加「任一分量解析失败即整条失败」的门槛，并校验最终向量非全零。

### [一般][存量] 失败转移在两条错误路径上退化：4xx 直接放弃其余候选、全熔断时 `last` 为空

- **位置**：`f_llm/src/embedding/Embedding.cj:81-94`（`throw` 在 `:87`、聚合 `:94`）
- **来源**：存量（`git blame`：`ce152e5f22` 2026-10-28）
- **判据**：review-checklist §11（契约与实现不符 / 错误处理不完善）；类注释 `:34-40` 承诺「失败转移、可重试失败记熔断」
- **证据**：静态确定 —— 非重试状态码走 `throw EmbeddingException(...)`（`:87`）而不是 `continue`，循环立刻结束；候选取全被 `holder.isCircuitOpen` 跳过时（`:67-69`），`lastError` 仍是初值 `''`，最终消息为 `all embedding confs failed for: X, last: `（`:94`）。
- **描述**：①4xx 不区分「这次请求本身错」（`input` 超长，换 provider 可能成功）与「凭据/路径错」，多候选配置下第一个候选的 400 会让整次调用失败，与注释承诺的失败转移不一致；②全熔断恰恰是运维最需要信息的场景，却只给空 `last`，日志里看不出是熔断；③消息里没有候选数量与跳过原因。
- **建议**：4xx 也走「记 `lastError` → `continue`」，只在候选耗尽后抛聚合异常；聚合消息带 `tried=n, skippedByCircuit=m, last=<原因>`；`lastError` 初值改为 `'no candidate attempted'`。若「4xx 必须终止」是有意设计，请在 `:81-88` 补注释并把初值改掉。

### [一般][存量] `MemoryDAO.list` / `listByKind` 用非唯一键 `save_time` 排序 + `OFFSET`，分页会重复或漏行

- **位置**：`f_llm/src/dao/postgres/MemoryDAO.cj:154-163`（`list`）、`:166-175`（`listByKind`）；时间来源 `:26-35`（`now()`）
- **来源**：存量（快照模式；SQL 主体早于本轮）
- **判据**：review-checklist §11（边界 / 契约不符：分页不稳定）；§6.4 仅作线索
- **证据**：静态确定 —— 两条 SQL 都是 `ORDER BY save_time DESC LIMIT ${arg(limit)} OFFSET ${arg(offset)}`，排序键不唯一且没有 `id` 作为 tie-breaker。`save_time` 由 `now()` 生成，PostgreSQL 的 `now()` 是**事务开始时间**，同一事务内批量写入的多行时间戳完全相同；等值键上行的相对顺序由执行计划决定。
- **描述**：调用方按 `offset += limit` 遍历（管理端记忆列表、导出、批量重排）时，同一行可能出现在两页、或整行被跳过；结果不可复现，且不抛异常。这是静默的可见性错误。
- **建议**：排序改 `ORDER BY save_time DESC, id DESC`（两处），必要时建 `(user_id, namespace, save_time DESC, id DESC)` 索引；更稳的是 keyset 分页（`WHERE id < ${cursor} ORDER BY id DESC`）。补集成用例：同事务插 5 行、`limit=2` 翻 3 页，断言并集正好 5 行且无重复。

### [一般][存量] 注释称「按权重挑起点」，向量化路径里 `weight` 只当启用开关

- **位置**：`f_llm/src/embedding/Embedding.cj:34-40`（注释）、`:66-93`（实现）；对照 `f_llm/src/llm/LLMConfsHolder.cj:49-57`、`:170`、`:189-222`
- **来源**：存量（`git blame`：`ce152e5f22` 2026-10-28）
- **判据**：review-checklist §11（语义与注释不符）；`fountain-baseline.md` §4（多实现选择应收敛，不在调用点各写一套策略）
- **证据**：静态确定 —— `LLMConfsHolder.candidates`（`:49-57`）只按 `weight > 0` 过滤、按 `byName` 列表顺序返回，不做加权；`Embedding.embed` 顺序 `for` 取第一个成功者；同类的加权选择器 `balancerFor`（`:189-222`）只被 `:170` 的对话侧入口使用。另外 `MetaDAO.confCandidates`（`f_llm/src/dao/postgres/MetaDAO.cj:67-75`）没有 `ORDER BY`，行序不保证稳定。
- **描述**：两个 embedding 候选配 `weight=9` / `weight=1` 时，期望 9:1 分流，实际 100% 打到行序第一个（且行序可能随 PG 更新而变）。同一份 `llm_conf` 在对话与向量化两条路径上语义不同，扩容/灰度时流量分配与预期不符，且很难发现。
- **建议**：二选一——让 `Embedding.embed` 复用 `balancerFor` 的选点（失败再按顺序兜底）；或把 `:35` 注释改成「按行序取第一个可用候选，`weight` 仅作启用开关」并同步到 embedding 配置文档。当前的双重语义必须消掉。

### [一般][存量] 向量化的 token 用量从未落库，`EmbeddingParam.agentId/session` 被静默丢弃

- **位置**：`f_llm/src/embedding/Embedding.cj:59-95`（只写 `result.usage.llmId`，`:90`）；`f_llm/src/embedding/EmbeddingParam.cj:21-26`
- **来源**：存量（快照模式）
- **判据**：review-checklist §1（读了不用）/ §11（契约与实现不符：参数暗示了会被记录）；`fountain-baseline.md` §2（DAO 层已备好列）
- **证据**：静态确定 —— `Embedding.embed` 全程不读 `params.agentId` / `params.session`（全仓 grep `EmbeddingParam(` 的调用点都传了这两个值，如 `f_llm/src/model/entity/KnowledgeEntity.cj:25/63`、`LlmEmbeddingTransport.cj:40-42`）；`saveTokenUsage` 的调用点只有 `f_llm/src/agents/AgentTask.cj:457` 与 `f_llm/src/llm/ContextPruner.cj:71`，都是对话路径；而 `TokenUsage` 明确带 `agent_id` / `session` 列（`f_llm/src/model/po/TokenUsage.cj:39-42`），`EmbeddingResp.usage` 也一路透传出来却无人消费。
- **描述**：embedding 的 `prompt_tokens/total_tokens`（`Embedding.parse:158-163` 已解析）既不落 `llm_token_usage`，也不进任何账目；即便将来落库，`agent_id` 也会是 0、`session` 为空串——这两列的存在与调用方显式传参让人以为会记录，实际是死的。成本核算与限流按 token 计量时会漏掉向量化这一块。
- **建议**：要么在 `Embedding.embed` 成功后把 `params.agentId/session` 写进 `usage` 并调 `lookupOption<TokenUsageSaver>()?.saveTokenUsage(...)`（与 `ContextPruner.cj:71` 同构）；要么删掉 `EmbeddingParam` 的这两个字段和 `EmbeddingResp.usage`，把「向量化不计量」写成显式契约。二选一，不要保留「传了但不用」的中间态。

### [轻微][存量] `embedding/imports.cj` 有 7 条没有消费者的 `internal import`

- **位置**：`f_llm/src/embedding/imports.cj:19`（`ConcurrentHashMap`）、`:21`（`MonoTime`）、`:27`（`fountain::f_log.*`）、`:28`（`f_util.UUID`）、`:31`（`f_llm.exception.LLMException`）、`:33`（`f_llm.finder.*`）、`:35`（`f_llm.util.*`）
- **来源**：存量（快照模式）
- **判据**：review-checklist §1（未使用的 `import`）
- **证据**：静态确定 —— 在 `f_llm/src/embedding/**`（含 `exception` 子包）逐个符号 grep：`ConcurrentHashMap`、`MonoTime`、`UUID`、`LLMException`、`LoggerFactory`/`f_log`、`f_llm.util`、`f_llm.finder` 全部零命中（仅 `imports.cj` 自身命中）；`BgeM3Transport.cj:93` 的 `http` 是 lambda 形参，不是 `f_llm.util` 的函数。无论 `internal import` 取「文件级」还是「包级重导出」语义（本地官方文档目录 `~/.autocode/cj/doc` 为空，作用域按 §铁律记 `待确认`），这 7 行都没有消费者——差异只是「死 import」还是「死重导出」。
- **描述**：`imports.cj` 变成 18 行里 7 行失效的清单，读者无法据此判断包的真实依赖；同时它把依赖边界放大成「包内谁都能用」。另：`EmbeddingParam.cj:18` 的 `import fountain::f_data.macros.*` 在该文件内也无任何宏使用（该类是普通 `public class`，没有 `@DataAssist`）。
- **建议**：删掉这 7 行与 `EmbeddingParam.cj:18`；后续真需要时在使用处写显式 import，不再走包级重导出。删除属安全机械清理，编译即可验证。

### [轻微][存量] 六处「`row.isEmpty()` → `None`/`Some(row)`」与两处 id→`Int64` 转换各写一遍

- **位置**：`MemoryDAO.cj:134-138`、`:147-151`；`MetaDAO.cj:31-35`、`:113-117`、`:145-149`、`:158-162`（样板 6 处）；`MemoryDAO.cj:197-203`（`daoIntOf`）vs `MetaDAO.cj:88-93`（`confPut` 内联 `match`）
- **来源**：存量（快照模式）
- **判据**：review-checklist §2（跨文件复制 / 只改类型名）
- **证据**：静态确定 —— 六个 `firstToMap()` 调用点后跟的 5 行完全同构（`let row = ...; if(row.isEmpty()){ None } else { Some<Map<String, Any>>(row) }`），差异只有 SQL 与返回列；两处 id 转换的分支集合与回退值（`0`）逐字相同。
- **描述**：当前无行为漂移（已逐分支比对），但新增一个查询就要再抄 5 行：任何一处加过滤/日志，其余 5 处即漂移。`daoIntOf` 与 `confPut` 的内联 `match` 也是同一语义的两份实现（PG 驱动可能回 `Int32`，回退 0）。
- **建议**：在 `dao/postgres` 内加 `private func optionOf(row: Map<String, Any>): ?Map<String, Any>`（先按 `fountain-api-lookup` 核对 `f_orm` 是否已有同类能力），六处收敛成一行；id 转换统一走 `daoIntOf`，放到同包一个 `RowValues.cj`（不新建跨层共享包）。合并时要保留差异点：`characterGet` 等返回列不同，`isEmpty` 判定语义一致。

### [轻微][存量] 五个异常类逐字重复，`LLMException` / `RoleException` 还在两个包里各存一份

- **位置**：`f_llm/src/exception/LLMException.cj:18-30`、`RoleException.cj:18-32`、`FunctionCallingException.cj:18-30`、`FunctionNotFoundException.cj:18-30`、`IllegalPathException.cj:18-30`；重复副本 `f_llm/src/embedding/exception/LLMException.cj:18-30`、`RoleException.cj:18-32`
- **来源**：存量（快照模式）
- **判据**：review-checklist §2（只改类型名）；§10 设计合理性（包划分）
- **证据**：静态确定 —— 类体都是同一份 4 个构造器（`()` / `(String)` / `(Exception)` / `(String, Exception)`），唯一差异是类名；`fountain::f_llm.embedding.exception` 这个包在全仓**没有任何 import**（`grep -rn "embedding.exception"` 只命中这两个文件自身），即两份副本无人使用；同包内 `RoleException.cj:18` 显式 `import fountain::f_base.BaseException`，`LLMException.cj:18` 不 import 却能用（依赖父包 `embedding/imports.cj:23` 的 `f_base.*`，这一条同时说明包级重导出的隐式性，见上一条 `待确认`）。
- **描述**：异常层级是调用方做降级的唯一抓手，现在既重复又分散：同一失败面有 `IllegalStateException`（`HttpEmbedder.cj:79`、`BgeM3Transport.cj:96`）、`EmbeddingException`（`Embedding.cj:63/87/94/156`）、`LLMException` 三种类型；两份同名的 `LLMException` 分居两包，catch 一处漏另一处，且副本一旦改动就会漂移。
- **建议**：`BaseException` 已有 4 个构造器（`f_base/src/BaseException.cj:44`），子类可省掉全部构造器，只留 `public class XxxException <: BaseException {}`；删掉 `f_llm/src/embedding/exception/` 整个目录（全仓零引用，属对外不可达的重复副本，删除前请确认无下游依赖），异常统一到 `fountain::f_llm.exception`；传输层改抛 `EmbeddingException` 或其后代。

### [轻微][存量] 注释与实现不符两处：重试退避时间、`lexical_weights`「同 token 取最大」

- **位置**：`f_llm/src/embedding/BgeM3Transport.cj:54-60`（注释「退避 100ms / 300ms」）vs `:73`（`100 * (attempt + 1)` ⇒ 100ms、200ms）；`:36-39`（注释「同 token 取最大」）vs `:121-126`（`sparse[Int64.parse(token)] = ...` 直接覆盖）
- **来源**：存量（`git blame`：`033799be37` / `89bc5e222c`，2026-10-31）
- **判据**：review-checklist §11（语义与注释不符）
- **证据**：静态确定 —— `retries=2` 时 `attempt ∈ {0,1,2}`，`attempt < retries` 时 sleep `100*(attempt+1)`，两次退避为 100/200ms；`lexical_weights` 解析是 HashMap 赋值（后者覆盖前者），「取最大」是服务端 `_process_token_weights` 的行为，客户端没有 `max`。
- **描述**：退避时间是容量评估与 SLO 的可观测参数，注释差 100ms 会让人算错重试窗口；「取最大」若被当成客户端保证，服务端一旦返回重复 key，权重会随 JSON 字段顺序变化。
- **建议**：注释改成「退避 100ms、200ms（`100ms × attempt` 递增）」；「同 token 取最大」改成「服务端已按 token 聚合，客户端同 key 覆盖（依赖服务端保证）」，或在客户端补 `max(...)` 兜底。

### [轻微][存量] `postgres/MemoryDAO.cj` 尾部挂着描述「MySQL 记忆 DAO」的文档注释

- **位置**：`f_llm/src/dao/postgres/MemoryDAO.cj:190-196`（注释）与 `:197-203`（实际被注释的 `daoIntOf`）
- **来源**：存量（`git blame`：`cdea037a40` 2026-10-30）
- **判据**：review-checklist §13（文档与代码不一致）；§10 可读性
- **证据**：静态确定 —— 注释讲「MySQL 记忆 DAO …… 唯一例外是 MyVector 的 `MYVECTOR_IS_ANN` / `myvector_construct` …… 只能内联数值字面量」，本文件只有 `@DAO public interface PostgresMemoryDAO`，全文没有 MySQL DAO 或 `myvector` 调用（对应实现实际在 `f_llm/src/dao/mysql/MemoryDAO.cj`）。
- **描述**：读者会以为本文件里有 MySQL 实现或「内联字面量」的合法例外，从而在新增 SQL 时放松 `arg(...)` 参数化要求（`fountain-baseline.md` §2）。
- **建议**：把这段注释移到 `src/dao/mysql/MemoryDAO.cj`（那边才有该例外），并给 `daoIntOf` 补一行说明「`RETURNING id` 的驱动类型可能是 `Int64`/`Int32`，其它回 0」。

### [轻微][存量] `EmbeddingParam.dimension` 声明后从不读取

- **位置**：`f_llm/src/embedding/EmbeddingParam.cj:25`；使用方 `Embedding.cj:70-72`（只读 `params.input`）
- **来源**：存量（快照模式）
- **判据**：review-checklist §1（死配置字段）；§11（契约不符：参数暗示了不会发生的行为）
- **证据**：静态确定 —— 全仓 grep `dimension` 只命中 `EmbeddingParam.cj:25` 与 `HttpEmbedder.cj:78-81`（后者用的是构造参数 `dim`）；`Embedding.embed` 不做任何维度校验，`HttpEmbedder.DEFAULT_DIM`（`:53`）与这里的默认值 `1024` 是两处独立常量。
- **描述**：调用方看到 `dimension: Int64 = 1024` 会以为「传 768 就按 768 校验」，实际该字段被忽略，向量维度只由传输层/构造参数决定；默认值双写，改一处漏一处。
- **建议**：`Embedding.embed` 用 `params.dimension` 校验返回长度（不一致抛 `EmbeddingException`），默认值引用 `HttpEmbedder.DEFAULT_DIM`；若确定不校验，删掉该字段。

### [轻微][存量] 冗余中转变量与空语句

- **位置**：`MemoryDAO.cj:181-185`（`removeMemory`）、`MetaDAO.cj:124-128`（`skillDelete`）、`MetaDAO.cj:165-169`（`promptDelete`）、`MetaDAO.cj:50-54`（`characterDelete` 末尾 `()`）
- **来源**：存量（快照模式）
- **判据**：review-checklist §1（无作用语句）/ §10 可读性
- **证据**：静态确定 —— 三处都是 `let deleted = executor.setSql(sql).update; return deleted`（变量只用于返回），`characterDelete` 在 `update` 之后单独一行 `()`。
- **描述**：`let x = ...; return x` 暗示「做过额外加工」但并没有，读者会去找不存在的处理；`()` 同理。不影响行为。
- **建议**：三处直接以 `executor.setSql(sql).update` 作尾表达式；删掉 `characterDelete` 的 `()`。

### [轻微][存量] 连服务的用例把所有非断言异常当 SKIP，实现坏掉也会「跳过」

- **位置**：`f_llm/src/embedding/BgeM3Transport_test.cj:26-40`
- **来源**：存量（`git blame`：`89bc5e222c` 2026-10-31）
- **判据**：review-checklist §3（`catch` 静默吞异常）；§11（失败当成功）
- **证据**：静态确定 —— 只对 `AssertException` 重新抛出（`:34-36`），其余 `catch(e: Exception)` 一律 `println("SKIP ...")` 后正常返回；服务在但返回 500、JSON 结构变了、维度不符，都会被 `IllegalStateException` 吃掉，用例仍「通过」。
- **描述**：这是三路（dense/sparse/colbert）真实可用性的唯一集成验证；服务升级改字段名时 CI 仍绿，问题要到生产检索退化才暴露。
- **建议**：先做一次轻量探测（`embed('ping')` 或健康检查）判断「服务是否存在」，不存在才 SKIP；探测通过后所有异常一律上抛。或按连接层异常类型白名单 SKIP（如连接拒绝），其余失败。

<!-- 第 11 部分 -->

本部分主体是「请求报文构造 / 响应解析 / 调用日志」三件事，外加 `finder` 的 10 个 SPI 接口与 3 个异常类。请求构造是**纯函数、无阻塞 I/O、无锁**（`ChatCompletionsMapper.build` 只操作局部 `JsonObject`，`build` 的输入 `LLMParams` 不被改写），并发面干净；`finder` 接口由工具层统一 `lookup<XxxFinder>()` 注入实现（`AgentTask.cj:108/120/298`、`Memory.cj:42-45`、`SkillLoadingFunction.cj:32`、`TodoFunction.cj:78/87/103`），分层正确，没有「业务代码里散落 if/else 选实现」。

问题集中在**契约完整性**：①`parse` 在 `choices` 缺失/为空时静默返回空响应，`LLM.call` 记成功，下游 `messages[0]` 直接越界；②非流式路径不标 `usageEstimated`，上游不给 usage 时把 0 当真值落库；③`parse` 对 `null`/异类型字段直接 `asObject()`，畸形 200 响应抛 `JsonException` 且绕过候选切换；④流式请求从不带 `stream_options.include_usage`，用量只能估算；⑤多模态消息的 `content` 文本在 `parts` 非空时被整段丢弃；⑥`CallLog`（文档承诺的「每次调用一行汇总日志」）**全仓没有任何生产调用点**。另有 8 条轻微：`temperature` 合并语义与配置注释相反、`intOf` 的 `toString+tryParse` 静默归零、两处 `private init(){}` 死代码（编译器已报 `unused`）、`finder` 包一条用不到的 import、三组重复逻辑、响应解析用例错放在 `ChatCompletionsResponse_test.cj`。

### [严重][存量] #1 `parse` 在 `choices` 缺失/为空时静默返回空响应，整条链路把异常响应当成功

- **位置**：`f_llm/src/llm/ChatCompletionsMapper.cj:149-158`（`if(let Some(rawChoices) <- resp.get('choices')){ ... if(choices.size > 0){ ... } }`，**两个 `if` 都没有 `else`**）；成功判定在 `f_llm/src/llm/LLM.cj:169-171`
- **来源**：存量（`git blame -L 147,157`：`9a1dd2412a` 2026-10-27，当时路径为 `f_llm/src/llm/protocol/ChatCompletionsMapper.cj`）
- **判据**：review-checklist §11「失败路径当成功 / 错误处理缺失」、§3「`Option` 只判 `Some`、坏值被当成合法」、§14.1「只做了一半的分支」
- **证据**：静态确定 —— `parse` 的两条空路径都直接落到 `out`（`LLMResp()`：零消息、`finishReason = ''`、usage 全 0、`usageEstimated = false`），既不抛也不记日志；`LLM.call` 拿到结果后只补 `result.usage.llmId = conf.id`（`LLM.cj:169`）就 `hooks.onSuccess(conf.id)` + `return result`（`:170-171`），**没有校验 `messages` 是否为空**。两条真实的下游消费点都是盲取第一个元素：`f_llm/src/memory/Memory.cj:70` 的 `.messages[0].content`、`f_llm/src/llm/ContextPruner.cj:74` 的 `msgs[msgs.size - 1]`（空列表时下标 = -1）。
- **描述**：触发条件是「HTTP 200 + 无有效 choices」：网关把限流/审核拦截包成 `{"error":{...}}` 返回 200、上游返回 `{"choices":[]}`（部分平台在内容过滤时如此）、或代理层返回 `{}`。此时：①`LLM.call` 把这次调用当成功并 `recordSuccess`（熔断器的失败计数被清掉，故障平台不会降级）；②业务层拿到 0 条消息的 `LLMResp`，在 `Memory.cj:70` / `ContextPruner.cj:74` 直接 `IndexOutOfBoundsException`——一个「调用方按 `LLMException` 写的 catch 全都接不住」的越界异常；③即使调用方读了 `messages.size` 做兜底，也会把「上游失败」当成「模型返回空内容」。这是本部分唯一会**静默产出错误结果 + 崩溃下游**的路径。
- **建议**：`parse` 在 `choices` 缺失或为空时抛 `LLMException('empty choices, body: ${…}')`（错误体截断，沿用 `LLM.cj:155` 的 `previewOf`），让 `LLM.call` 走既有失败分支（可重试则 `continue` 换候选）；若要保持 `parse` 不抛，则必须在 `LLM.cj:169` 前判 `result.messages.isEmpty()` 并转成 `LLMException`。补用例：`{}`、`{"choices":[]}`、`{"error":{"message":"x"}}` 三种 200 响应各一条，断言抛 `LLMException` 且 `hooks.onRetryableFailure` 被调用。

### [一般][存量] #2 非流式响应缺 `usage` 时 `usageEstimated` 不置位，0 用量被当成真值落库

- **位置**：`f_llm/src/llm/ChatCompletionsMapper.cj:159-161`（usage 分支）、`:194-201`（`fillUsage`）
- **来源**：存量（`git blame`：`9a1dd2412a` 2026-10-27）
- **判据**：review-checklist §11「契约与实现不符 / 失败路径当成功」、§14.1「只做了一半的分支」
- **证据**：静态确定 —— 契约写在 `f_llm/src/llm/LLMResp.cj:27-29`：「*usage 是否为启发式估算（上游没给 usage 时置 true）*」。流式侧遵守（`ChatStreamAccumulator.cj:163-170`：`hasUsage == false` 时估算 completion 并 `usageEstimated = true`），非流式侧没有：`parse` 只在 `resp.get('usage')` 命中时填 `TokenUsage`，缺省路径直接返回，`usageEstimated` 保持 `false`。全仓 `usageEstimated` 的写入点只有 `ChatStreamAccumulator.cj:169`、`ResponsesStreamAccumulator.cj:91` 两处，非流式零写入点（`grep -rn usageEstimated f_llm/src`）。
- **描述**：部分 OpenAI 兼容网关在非流式响应里省略 `usage`（或给 `null`，后者见 #3）。此时 `LLMResp` 是 `prompt=0, completion=0, total=0, estimated=false`，`ContextPruner.cj:71` 的 `lookupOption<TokenUsageSaver>()?.saveTokenUsage(resp.usage)` 会把这些 0 写进 `llm_token_usage`——行上看不出「没数据」还是「真 0」；`CallLog.summary` 的 `estimated:` 字段（`CallLogger.cj:37`）也恒为 `false`，观测面同样失去区分能力。同一契约在流式/非流式两种行为。
- **建议**：`parse` 的 usage 分支补 `else { out.usageEstimated = true }`，并复用 `ChatStreamAccumulator.cj:185-189` 的 `estimateTokens` 至少估算 completion（让两条路径口径一致）；或在 `LLM.call` 收口处统一判定「`usage.total == 0 ⇒ estimated = true`」。补用例：`{"choices":[...]}` 无 `usage` 的响应断言 `usageEstimated == true`（现有 `ChatCompletionsResponse_test.cj:118-123` 只断言了 0）。

### [一般][存量] #3 `parse` 对 `null` / 异类型字段直接 `asObject()` / `asArray()`，畸形 200 响应抛 `JsonException` 且绕过候选切换

- **位置**：`f_llm/src/llm/ChatCompletionsMapper.cj:159-160`（`rawUsage.asObject()`）、`:150`（`rawChoices.asArray()`）、`:140`（`other.asString()`）、`:174-178`（`call.get('function')` 之外的 `rawCalls.asArray()`）
- **来源**：存量（`git blame`：`9a1dd2412a` 2026-10-27）
- **判据**：review-checklist §11「错误处理缺失 / 与契约不符」、§3「`Option` 只判 `Some` 不判内容」
- **证据**：静态确定 —— `JsonValue.asObject()` / `asArray()` / `asString()` 在类型不符时 `throw JsonException`（`f_data/src/json/JsonValue.cj:55-76`，三个 `as*` 都是 `if(let x: T <- this)… else throw JsonException`）。`parse` 的守卫只判断「键存在」：`"usage": null` 时 `get` 返回 `Some(JsonNull)`，`asObject()` 直接抛；`"choices": null`、`content` 为数字/对象/布尔时同理。抛点位于 `LLM.cj:164`（`JsonValue.fromStr(...).asObject()` 之后的 `parse`），**在只包住 `post` 的 `try`（`LLM.cj:145-151`）之外**，因此既不走 `hooks.onRetryableFailure` + `continue` 的候选转移，抛出的也是 `JsonException` 而非契约上的 `LLMException`。
- **描述**：触发条件是「200 但字段形状不同」，与 #1 同一类上游异常的不同表现。后果：多候选配置下不会切到下一个平台、熔断计数不记，表现为「偶发失败、换平台就好、日志里只有 Json 异常」。`ChatStreamAccumulator.cj:64-67` 有相同形态的守卫（范围外，同模式）。
- **建议**：`parse` 入口做形状校验（`JsonValue.kind` / `isObject` / `isArray`，`f_data/src/json/JsonValue.cj:77-91`、`:578-587`），不符时跳过字段并计一次 warn + `estimated`；`content` 的兜底改用同文件的 `textOf`（`:205-210`，已处理 `JsonNull`）。更彻底的做法是在 `LLM.call` 里把「反序列化 + parse」整体包进 `try`，统一转 `LLMException` 并进入候选转移。

### [一般][存量] #4 流式请求从不带 `stream_options.include_usage`，上游不回 usage ⇒ 用量全部估算（prompt 记 0）

- **位置**：`f_llm/src/llm/ChatCompletionsMapper.cj:51-55`（`stream` 分支只写 `stream: true`）
- **来源**：存量（`git blame`：`9a1dd2412a` 2026-10-27）
- **判据**：review-checklist §11「契约与实现不符 / 数据错误」、§14.1「能力未接完：有估算兜底却没有取真值的手段」
- **证据**：静态确定（请求侧）+ 待确认（各家平台默认行为）—— `grep -rn "stream_options\|include_usage" f_llm` 零命中，请求体永远只有 `stream: true`；响应侧 `ChatStreamAccumulator.result()`（`:158-170`）在 `hasUsage == false` 时走估算分支且 `response.usage.prompt = 0`（`:166`）——prompt 侧连估算都没有，`total` 只等于 completion 的粗估。`f_llm/doc/f_llm.md:102` 列的请求体字段也没有 usage 开关。
- **描述**：OpenAI Chat Completions 在未显式要求时不会在流里给 `usage`（要求方式是 `stream_options: {"include_usage": true}`，末块带 usage、其余块为 `null`），DeepSeek 等兼容实现同样默认不发。于是 `LLM.stream` 每次调用都以「prompt=0、completion=字节数/3」进入 `llm_token_usage` 与日志，prompt 侧恒 0 会让「缓存命中率 / 上下文成本」类分析全部失真。注意加上该字段后，`null` 块会触发 #3 的 `asObject()` 缺陷，两处必须一起改。
- **建议**：`stream == true` 时补 `body.add('stream_options', ...)`，并在 `ChatStreamAccumulator.cj:64` 把 `Some(JsonNull)` 当作「本块无 usage」跳过；若个别平台拒绝该字段，走 `ProviderDialect.decorate`（`LLM.cj:140`）做平台开关而不是全局关闭。补用例：末块缺 usage → `usageEstimated == true`；末块带 usage → `false` 且 `prompt > 0`。

### [一般][存量] #5 `CallLog` 从未接线：文档承诺的「每次调用一行汇总 / 失败观测点」在生产路径不存在

- **位置**：`f_llm/src/llm/CallLogger.cj:40-43`（`info`，零生产调用方）；契约在 `:23-29` 类注释
- **来源**：存量（`git blame`：整文件出自 `e928da3176` 2026-10-27「…Redactor、调用日志（任务 7.1-7.6）」）
- **判据**：review-checklist §14.1「接线缺失 / 承诺了但没实现」、§13「文档与实现不一致」
- **证据**：静态确定 —— `grep -rn "CallLog\." f_llm/src` 只有 `ContextPruner_test.cj:211`（测试调 `summary`），`CallLog.info` 全仓零调用；`elapsedMs` / `ttftMs` 除 `CallLogger.cj:35-41` 自身外**没有任何计算点**（`grep -rn "elapsedMs\|ttft" f_llm/src/llm` 只命中该文件），即连计时都没埋。承诺源三处：`CallLogger.cj:23-29`「只记**一行**：平台、模型、耗时、TTFT、用量、结束原因、是否估算」；`f_llm/doc/f_llm.md:157`「`LLMHooks` 提供调用前后的切面（日志、审计、埋点），`CallLogger` / `CallLog` 是内置实现」；`f_llm/doc/f_llm.md:581`「单个平台失败 → 换下一个候选｜观测点：熔断计数、`CallLog`」。而 `LLMHooks`（`LLMHooks.cj:24-34`）只有 `onSuccess` / `onRetryableFailure` 两个 `(Int64) -> Unit` 回调，`LLM.call`（`LLM.cj:144-171`）与流式路径都没有调 `CallLog`。
- **描述**：三处后果。①**可观测性缺口**：出问题时没有「一次调用一行」的汇总（provider / model / 耗时 / TTFT / 用量 / finish），排查「慢在哪个模型、TTFT 多少、是否估算」无据。②**文档失真**：`doc/f_llm.md:157/581` 描述的是不存在的实现；`doc/f_llm.md:157` 还把类型写成 `CallLogger`，而代码里只有 `CallLog`（`CallLogger` 只是文件名）。③**成本**：`CallLog.summary` 的 `estimated:` 是当前唯一能暴露「用量是估算」的通道（见 #2），它不产出，估算值就被静默当真值。
- **建议**：在 `LLM.call` 成功分支（`LLM.cj:169-171` 之前，起点用 `MonoTime.now()`——同包已此用法，见 `CircuitBreaker.cj:58`）与流式首块/末块（TTFT = 首块时间 − 起点）各调一次 `CallLog.info(conf, result, elapsedMs, ttftMs: ttft)`；失败分支在 `lastError` 落盘处补一条 warn（带 provider/model/status）。短期不接就把 `doc/f_llm.md:157/581` 改成「预留」，不要写成已具备。

### [一般][存量] #6 多模态消息的 `content` 文本在 `parts` 非空时被整段丢弃，且两条报文路径都如此、无任何文档提示

- **位置**：`f_llm/src/llm/ChatMessage.cj:24-25`（`parts` 注释）、`:35-44`（`addText` / `addImage`）；丢弃点在 `f_llm/src/llm/ChatCompletionsMapper.cj:92-101`（`message.remove('parts')` + `message.add('content', parts 数组)`），Responses 侧同构于 `ResponsesMapper.cj:161-181`
- **来源**：存量（`git blame -L 46,51`：`ce152e5f22` 2026-10-28；`ChatCompletionsMapper.cj:88-105` 出自 `9a1dd2412a` 2026-10-27）
- **判据**：review-checklist §11「语义与注释不符 / 数据丢失」、§2（两条报文路径同构复制，见 #12）
- **证据**：静态确定 —— `ChatMessage` 的 `content` 是独立字段（`:28`），`addText` / `addImage` 只往 `parts` 追加（`:36`、`:42`），**不回写 `content`**；`rewriteMultimodal` 对每条消息先 `remove('parts')`，再在 `parts` 非空时 `message.add('content', JsonArray(...))`——`add` 覆盖同名键，于是构造时写进 `content` 的文本从报文里消失。仓内唯一的使用形态正好踩中：`ChatCompletionsMapper_test.cj:120-121`（`UserMessage('看图')` + `addImage(...)`）断言 `content` 数组只有 1 项且是 `image_url`，即测试把「'看图' 被丢弃」固化成了期望；`ChatCompletionsResponse_test.cj:128-139` 的 Responses 版同样只有 1 个 `input_image`。注释只说「非空时 `content` 只是文本摘要」，没有说「摘要不会发给模型」。
- **描述**：`UserMessage('描述这张图').addImage(url)` 是最自然的写法，实际发给模型的是「只有图片、没有问题」——模型不会报错，只会答非所问；排查时看 `params` 里 `content` 明明在，报文里却没有，很容易误判为上游丢字段。附带一处命名漂移：`multimodal`（`:47-51`）返回 `!parts.isEmpty()`，因此**只 addText 的纯文本消息也算 multimodal**（`ResponsesMapper.cj:162` 用它决定 content 走数组还是字符串），与注释「是否含多模态片段」不符，调用方若用它判断「有没有图片」会得到假阳性。
- **建议**：二选一并写进 README 与类型注释：①首次 `addText` / `addImage` 时若 `content` 非空且尚无 text 片段，先把 `content` 作为首个 text 片段种进 `parts`（这样 `UserMessage('看图').addImage(...)` 会得到 2 个片段；需同步改 `testBuildsContentParts` 的断言）；②保持「parts 权威」，但让 `addImage` / `addText` 在 `content` 非空时显式清空 `content` 或在报文里追加一条 warn，避免静默丢文本。`multimodal` 建议改名 `hasParts`，或改成「存在非 text 片段」。

### [轻微][存量] #7 `temperature` 合并语义与配置注释 / 类注释相反：conf 设 -1 仍然会发出 `temperature: 1.0`

- **位置**：`f_llm/src/llm/ChatCompletionsMapper.cj:40-49`（合并逻辑），注释在 `:28-31`（规则 2）
- **来源**：存量（`git blame`：`:40-49` 出自 `9a1dd2412a` 2026-10-27）
- **判据**：review-checklist §11「语义与注释不符」、§13「配置默认值与文档不符」
- **证据**：静态确定 —— 合并是「conf 优先、否则用 params」，而 `LLMParams.temperature` 的默认值是 **`1.0`**（`f_llm/src/llm/LLMParams.cj:30`）。因此 `conf.temperature = -1`（`LLMConf.cj:56-58`：「温度：< 0 表示用平台默认值（报文不带该参数）」）只有在调用方**同时**把 `params.temperature` 也设成负数时才走 `body.remove('temperature')`；默认参数下报文带 `temperature: 1.0`。类注释 `:30`「`temperature` 有效值为负 ⇒ 报文里不出现该字段」读起来像「conf 负即可」。
- **描述**：运维在 `llm_conf.temperature` 填 -1 期望「不干预、用平台默认」，实际发出 1.0；对 temperature 默认值不是 1.0 的平台可感知，且排查时从配置上看不出来。`ThinkingPolicy` 只对恒思考模型删该字段（`ModelCapabilities.cj:73-85`），覆盖不到这类模型。
- **建议**：语义收敛成一处并写清：要么 `conf.temperature < 0` ⇒ 直接 `remove`（params 不参与，与 `LLMConf` 注释一致），要么把 `LLMParams.temperature` 默认改成 `-1.0` 让「未显式设置」与「用平台默认」同义。补用例：`conf(-1)` + 默认 `params` → 断言 `body.get('temperature').isNone()`（现有 `testTemperatureFallsBackToParams` 断言的是相反行为）。

### [轻微][存量] #8 `intOf` 用 `toString() + tryParse` 取整，字符串 / 小数形式的 token 数静默变 0

- **位置**：`f_llm/src/llm/ChatCompletionsMapper.cj:228-234`
- **来源**：存量（`git blame`：`9a1dd2412a` 2026-10-27）
- **判据**：review-checklist §11「错误处理静默 / 边界」、§10「标准库利用」（有 `asInt` 不用）
- **证据**：静态确定 —— `Int64.tryParse(value.toString()) ?? 0`；`JsonValue.toString()` 是 **JSON 序列化**（`f_data/src/json/JsonValue.cj:153-155` → `toJsonString(false)`，字符串值经 `JsonWriter` 带引号写出），`JsonString("19")` 的文本是 `"19"`，`tryParse` 必然失败 ⇒ 0；`JsonDecimal(19.0)` 的文本 `19.0` 同样失败。`JsonValue.asInt()`（`JsonValue.cj:30-39`）已处理 `JsonInt` 与 `JsonDecimal`（后者走 `toBigInt()`）。
- **描述**：触发条件是上游把 usage 写成字符串（部分国产网关 / 代理层如此）或写成 `19.0`。此时 prompt/completion/total 全变 0，与 #2「缺 usage」表现相同却无法区分，进一步污染计费数据；附带每次取值一次小字符串分配 + 解析（一次响应 3-4 次，μs 级，本身不是热点）。
- **建议**：改成 `if(value.kind == JsonKind.JsonInt || value.kind == JsonKind.JsonDecimal){ value.asInt().value… } else { 0 }`（或先 `isInt` / `isDecimal` 判断），并对「有值但解析不出」记一条 warn（带 key 与原文），让「格式不认识」不再与「字段缺失」同义。

### [轻微][存量] #9 死代码：`CallLog` / `ChatCompletionsMapper` 上的 `private init(){}` 无调用者（编译器已报 `unused`）

- **位置**：`f_llm/src/llm/CallLogger.cj:33`、`f_llm/src/llm/ChatCompletionsMapper.cj:34`
- **来源**：存量（`git blame`：`e928da3176` / `9a1dd2412a`，2026-10-27）
- **判据**：review-checklist §1「无调用者」、§11「兼容残留」
- **证据**：静态确定 —— 构建日志直接给出证据：`f_llm/target/release/.build-logs/f_llm@fountain/f_llm.llm@….errlog:9-21` 有 `warning: unused function:'init'`，逐条指向 `CallLogger.cj:33`、`ChatCompletionsMapper.cj:34`（同 errlog 还有 `ResponsesMapper.cj:34`、`ModelCapabilities.cj:28`、`LLMErrorClassifier.cj:25`）。两个 struct 的成员全是 `static`（`CallLog.summary/info`、`ChatCompletionsMapper.build/parse`），构造函数从未被调用；`private init(){}` 的唯一作用是「禁止外部构造」，与「所有成员都是 static」叠加后冗余（static 成员本就无需实例）。
- **描述**：不影响行为，但每次构建刷 warning，长期淹没真正的 `unused` 告警（该 errlog 共 12 条 warning，其中 6 条是这类 `unused function:'init'`，本部分占 2 条）。是否算「死代码」有争议（它表达「不可实例化」的意图），但既然编译器按 `unused` 报，且意图可由注释表达，建议清理。
- **建议**：删除这两个 `private init(){}`（同款另见 #12 提到的 `ResponsesMapper.cj:34` 等，范围外）；若坚持保留「不可实例化」的显式约定，改成注释 + `-Woff unused` 的局部抑制，并在 `cjlintignore.cfg` 说明。

### [轻微][存量] #10 `finder/imports.cj` 里的 `fountain::f_orm.*` 在本包内没有任何使用

- **位置**：`f_llm/src/finder/imports.cj:21`
- **来源**：存量（`git blame`：`4be871f2f` 2026-10-02）
- **判据**：review-checklist §1「未使用的 `import`」
- **证据**：静态确定 —— `grep -rn "RootDAO\|ORM\.\|SqlExecutor" f_llm/src/finder/` 零命中；finder 包 10 个文件引用的类型只有 `Agent` / `Code` / `CodeParam` / `Knowledge` / `KnowledgeParam` / `KnowledgeKind` / `MemorySummary` / `Skill` / `SkillReference` / `SkillReferenceParam` / `Specification` / `SpecKind` / `Todo` / `TokenUsage` + `ArrayList` + `LoggerFactory`。同文件其余 import（`std.collection` / `f_log` / `f_llm.constant`（`KnowledgeKind`）/ `f_llm.model` / `f_llm.model.po`）均有命中。
- **描述**：本仓约定「每包一个 `imports.cj` 承载包级 `internal import`」（`internal import` 对同包所有文件可见，见 `cangjie-doc/md/doc/cj_syntax.md:71`），因此这类残留会随包长期存在；它不影响编译（编译器不报未使用 import），但会让读者以为 finder 直接依赖 ORM。DAO 实现确实用 ORM，但那些在 `src/store/**`，不在本包。
- **建议**：删掉该行；若 finder 后续要放 `@QueryMappersGenerator` 的查询映射再按需加回。

### [轻微][存量] #11 重复逻辑①：同包 JSON 取值助手「拷贝式演进」，已出现行为漂移

- **位置**：`f_llm/src/llm/ChatCompletionsMapper.cj:194-201`（`fillUsage`）↔ `f_llm/src/llm/ChatStreamAccumulator.cj:175-182`（`fillStreamUsage`）；`ChatCompletionsMapper.cj:139-141`（`contentTextOf` 标量分支）↔ `:205-210`（`textOf`）；`:212-218` / `:220-226`（`stringOf` 两版）
- **来源**：存量（`git blame`：`fillUsage`、`stringOf`、`textOf` 出自 `9a1dd2412a`；`fillStreamUsage` 出自 `ce62d320ef` 2026-10-27）
- **判据**：review-checklist §2「只改函数名 / 换控制流」
- **证据**：静态确定 —— `fillUsage` 与 `fillStreamUsage` **逐行同构**（`prompt/completion/total` 三个 `intOf` + `prompt_tokens_details.cached_tokens` 的 `if let`），唯一差别是函数名与 `private static` / 包级可见性。`contentTextOf` 的 `case other => other.asString().value`（`:140`）与 `textOf` 的 `case _ => value.asString().value`（`:208`）是同一逻辑两份；`stringOf(obj,key)` 与 `stringOf(obj,key,default)` 只差兜底 `''`。
- **描述**：风险不是重复本身，而是**漂移已经发生**：流式侧有 `estimateTokens` 兜底 + `usageEstimated = true`（`ChatStreamAccumulator.cj:163-170`），非流式侧什么都没有（#2）；`fillStreamUsage` / `fillUsage` 任一侧补字段（如 `completion_tokens_details.reasoning_tokens`）另一侧不会跟上。名称也在混淆：`ContentPart.textOf`（`ContentPart.cj:42`）是工厂方法，同包顶层 `textOf` 是取值函数。
- **建议**：`fillStreamUsage` 删掉，`ChatStreamAccumulator.cj:65` 改调 `fillUsage`（提升为包级并移到单独的 `WireSupport.cj`）；`contentTextOf` 标量分支直接 `textOf(raw)`；`stringOf(obj,key)` 改为 `stringOf(obj, key, '')` 单行转调。迁移后把流式/非流式的 usage 兜底策略一并收口到同一处。

### [轻微][存量] #12 重复逻辑②：`build` 的「温度 / stream / tools」三段在 Chat 与 Responses 两个映射器里各写一遍，且已漂移（Responses 丢 `response_format`）

- **位置**：`f_llm/src/llm/ChatCompletionsMapper.cj:40-49`、`:51-55`、`:66-76` ↔ `f_llm/src/llm/ResponsesMapper.cj:57-66`、`:68-72`、`:74-89`（对端文件范围外，同包）
- **来源**：存量（`git blame`：Chat 侧 `9a1dd2412a` 2026-10-27，Responses 侧 `d3ebac792` 2026-10-27）
- **判据**：review-checklist §2「跨文件复制 / 近似重复，其中一块少了边界判断」
- **证据**：静态确定 —— 三段逐句对齐：温度「conf ≥ 0 用 conf，否则用 params，仍 < 0 则 remove」、stream「true 则 add / 否则 remove」、tools「`if(let tool: LLMToolParams <- params)` 遍历 `tool.functions`，空集合 remove」。差异点只有 tools 条目形状（Chat 套 `{type, function}`，Responses 扁平 `{type,name,description,parameters}`）——这部分**应当**不同。但 `response_format` 的处理只在 Chat 侧存在（`:57-64`），`ResponsesMapper.build`（`:36-90`）完全没有该分支，也没有 Responses 等价的 `text.format`；`'json_object'` 字面量（`:61`）与 `ResponseFormat.json`（`LLMParams.cj:63`）也各写一份。
- **描述**：调用方 `params.response_format = ResponseFormat.json` 走 `respond()`（`LLM.cj:138`）时静默退化成纯文本请求——不报错、不告警，只是模型不返回 JSON。这是「近似重复里少一块」的典型后果。另外 `remove('stream')` / `remove('tools')` 在 Responses 的新建 `JsonObject` 上恒为 no-op，属防御性冗余。
- **建议**：三段抽成包内小函数（`applyTemperature(conf, params, body)`、`applyStream(body, stream)`、`collectTools(params)`），两个映射器只保留各自的结构差异；`response_format` 抽成返回 `?JsonValue` 的函数，Chat 用 `{type}`、Responses 用平台要求形态，缺失时显式 warn 或抛 `LLMException`，避免静默降级。

### [轻微][存量] #13 重复逻辑③：六个异常类的四个构造函数完全同构，且 `RoleException` 在两个包里各定义了一份

- **位置**：`f_llm/src/exception/LLMException.cj:18-29`、`RoleException.cj:20-31`、`SkillNotFoundException.cj:18-29`（同包另有 `FunctionCallingException` / `FunctionNotFoundException` / `IllegalPathException`，形态相同）；**同名重复**：`f_llm/src/embedding/exception/RoleException.cj:20`（`fountain::f_llm.embedding.exception.RoleException`，与 `fountain::f_llm.exception.RoleException` 除包名外字节级同构）
- **来源**：存量（`git blame`：`4be871f2f` 2026-10-02 前既有）
- **判据**：review-checklist §2「只改类型名」、§14.1「能力漂移」
- **证据**：静态确定 —— 三个文件除类名外同构：`<: BaseException` + `init()` / `init(message)` / `init(caused)` / `init(message, caused)` 四个纯转发构造。`grep -rn "RoleException" --include=*.cj` 命中两个定义处（`src/exception/RoleException.cj:20`、`src/embedding/exception/RoleException.cj:20`），**同名、同结构、不同包**，且全仓零构造/捕获点。附带一处 import 不一致：只有 `src/exception/RoleException.cj:18` 写了 `internal import fountain::f_base.BaseException`，同包其余五个文件引用同一基类却没有 import（依赖 `internal import` 的包级可见性）——删掉/移动 `RoleException.cj` 的那一行，另外五个文件立刻编译失败。
- **描述**：语义上区分异常类型是合理的（调用方按类型降级），问题在样板与重名：①6 个文件 × 12 行纯转发、新增类型要复制 4 个构造函数；②同名 `RoleException` 分属两个包，使用者 `import fountain::f_llm.exception.*` 与 `import fountain::f_llm.embedding.exception.*` 同时可见时会出现歧义或需要别名，`catch(RoleException)` 捕获的是哪一个取决于 import——这类错误在编译期不一定暴露；③全仓零引用的 `RoleException` / `SkillNotFoundException` 作为对外可达的 public 类型，按硬原则一**不判死代码**，这里只记信息并建议单列「可见性建议」。
- **建议**：删掉 `src/embedding/exception/RoleException.cj`（与 `src/exception/RoleException.cj` 完全重复，删前确认无下游 import）；两个异常包统一基类与 import 写法（或都交给各自包的 `imports.cj`）；4 个构造函数的样板可用宏或中间基类 `FountainException <: BaseException` 收敛。`RoleException` / `SkillNotFoundException` 是否保留请交用户决定，不默认删除。

### [轻微][存量] #14 `ChatCompletionsResponse_test.cj` 混装 `ResponsesMapper` 与 `LLMErrorClassifier` 的用例（按文件名找不到被测对象）

- **位置**：`f_llm/src/llm/ChatCompletionsResponse_test.cj:126-203`（5 个 `testResponses*` 用例）、`:205-215`（`testClassifyStatusCodes`）
- **来源**：存量（快照模式无基线；文件 216 行由 `9a1dd2412a` 起的多次追加累积）
- **判据**：review-checklist §10「可维护性」、§2 误报边界之外（这不是重复，而是归属错位）
- **证据**：静态确定 —— 文件名对应 `ChatCompletionsMapper.parse`，但 216 行 / 10 个用例里，5 个测 `ResponsesMapper.build/parse`、1 个测 `LLMErrorClassifier.isRetryable/isFatal`；`ChatCompletionsMapper` 的 `parse` 只被 `testParseText` / `testParseToolCalls` / `testParseReasoningContent` / `testUsageMissingDefaultsToZero` 覆盖。三类被测对象共用一个 fixture 段（`:25-74`）与同一 `@Test` 类 `ChatCompletionsResponseTest`。
- **描述**：后果是「改 `ResponsesMapper` 时在 `ChatCompletionsResponse_test.cj` 里找用例」「按文件名 grep 不到 Responses 的测试」，以及 `ChatCompletionsMapper.parse` 的空 `choices`（#1）、`usageEstimated`（#2）没有任何用例——用例被别的被测对象的测试挤占了位置。另 `:25-74` 的 `RESP` 常量是文件级 `let`，与本包其他测试的 `facadeConf` 分离，理解成本偏高。
- **建议**：拆成 `ResponsesMapper_test.cj`（5 个用例 + Responses fixture）与 `LLMErrorClassifier_test.cj`（1 个用例），`ChatCompletionsResponse_test.cj` 只留 4 个 Chat 解析用例，并补 #1 / #2 的空 `choices`、无 usage 用例。

<!-- 第 12 部分 -->

### [严重][存量] 流式传输无条件 `CertificateVerifyMode.TrustAll`：模型 API Key 暴露给中间人

- **位置**：`f_llm/src/llm/LLMStreamTransport.cj:48-50`（`DefaultStreamTransport.stream`）；同根因见范围外 `f_llm/src/llm/LLMTransport.cj:46-48`
- **来源**：存量（`git blame` `LLMStreamTransport.cj:49` → `ce62d320ef` 2026-10-27，快照模式无 diff）
- **判据**：review-checklist §10 安全性；§11「契约与实现不符」
- **证据**：静态确定 —— `var tls = TlsClientConfig(); tls.verifyMode = CertificateVerifyMode.TrustAll; client.tlsConfig(tls)` 对**任意** URL 生效，没有按 host 判断回环地址的分支，也没有配置开关；同一个客户端随后把 `dialect.headers(conf)`（含 `Authorization: Bearer <api key>`，`openai/DeepSeekDialect.cj:50-53`）发出去
- **描述**：所有流式（以及非流式）请求都在关闭证书链校验的 TLS 通道上进行。攻击者只要能劫持 DNS / 出口代理，即可用任意自签证书完成中间人，拿到 Provider 的 apiKey 并读写全部对话内容；失败方式完全静默（请求照常成功）。项目内已有可配置写法（`f_mvc/src/MVCConfig.cj:90-104` 的 `TLS_VERIFY_MODE`：default / customCA / trustAll），f_llm 没有对齐。
- **建议**：新增 `llm_tlsVerifyMode`（默认 `default`，可选 `customCA` + PEM、`trustAll`），在两个 transport 构造 client 时按配置设置；只允许显式配置才关校验。若短期不改配置体系，至少只在 `127.0.0.1` / `localhost` / `::1` 才 `TrustAll` 并抽成带注释的函数。

### [严重][存量] 客户端没有自己的超时，且会被 embedding 设置的 3s 全局读超时接管

- **位置**：`f_llm/src/llm/LLMStreamTransport.cj:43-50`、`f_llm/src/llm/LLMTransport.cj:41-48`（范围外，同一模式）
- **来源**：存量（快照模式无 diff）
- **判据**：review-checklist §11「资源与契约：超时缺失」/ §6.1（I/O 等待）；`fountain-baseline` §8
- **证据**：静态确定 —— `f_httpclient/src/httpclient.cj:29-36` 定义进程级 `readTimeout_` / `writeTimeout_`，`:41-48` 在**构造函数**里套用；`f_llm/src/embedding/BgeM3Transport.cj:62-65` 每次 `embed()` 都把这两个静态值改成 `timeoutMs`（默认 3000ms，`:48`）且从不复位。两处 LLM transport 都不调用 `client.readTimeout(...)` / `writeTimeout(...)`
- **描述**：同一进程内只要发生过一次向量化，之后新建的 chat 客户端读/写超时就是 **3 秒**——`llm_streamIdleTimeout`（默认 120s，`f_llm/src/config/LLMConfig.cj:177-179`）在 socket 层被 3s 覆盖，SSE 首 token 或长回答的停顿超过 3s 就会读超时，被 `LLMErrorClassifier` 判为可重试后换平台重发或整体失败。反过来，没走过 embedding 的进程则**完全没有**读/写超时：对端接受连接后不响应，调用线程会一直被占住（`AgentTask.cj:424-435` 的 `maxElapsed` 只在两次尝试之间检查，无法打断进行中的调用）。
- **建议**：两个 transport 都显式设置超时：非流式用 `llm_requestTimeoutMs`，流式用「连接/首包超时 + `llm_streamIdleTimeout`」；`BgeM3Transport` 改用 per-client `client.readTimeout(...)`，不要改进程级 static。

### [严重][存量] `RetainLastNRoundPruner.prune` 短会话负下标切片，直接抛 `IndexOutOfBoundsException`

- **位置**：`f_llm/src/llm/ContextPruner.cj:290`（`let last = messages[messages.size - 2 * n ..]`）
- **来源**：存量（`git blame` `ContextPruner.cj:290` → `4be871f2fd` 2026-10-02，快照模式无 diff）
- **判据**：review-checklist §11「边界差一 / 越界」；`std.collection` 文档 `ArrayList` 的 `operator func [](Range<Int64>)`：「range 无效时抛 `IndexOutOfBoundsException`」
- **证据**：静态确定 —— 只要 `messages.size < 2 * n`（默认 `n = 1`，即**只有 1 条消息的首轮请求**，或空列表），`start` 为 `-1` / 更小；没有 `size <= 2*n` 的短路分支（对比 `LastNContextPruner:51` 就做了 `size > n*2` 判断）
- **描述**：这是裁剪策略里唯一没有做长度保护的实现。一旦被注册并写进 `agent.conf['pruner']`，首轮会话（只有一条 user 消息）必然崩溃；崩溃点在 `AgentTask.cj:412` 的主路径上（裁剪先于调模型），外层无 try。测试只覆盖 6 条消息（`ContextPruner_test.cj:107-113`）。
- **建议**：`let start = if(messages.size > 2 * n){ messages.size - 2 * n } else { 0 }`，或 `if(messages.size <= 2 * n){ return msgs }`；`n <= 0` 一并校验；补「空列表 / 1 条 / 恰好 2n 条」三个用例。

### [严重][存量] 流式中途失败后换平台重放，`onDelta` 已吐出的内容会重复

- **位置**：`f_llm/src/llm/LLM.cj:231-254`（try 覆盖 `236-247` 的 `onDelta` 调用；`catch` 后 `continue`）
- **来源**：存量（快照模式无 diff）
- **判据**：review-checklist §11「错误处理」/ §12.1「异步语义」；类注释 `LLM.cj:202-207` 承诺「中途异常包成 `LLMException` 并带 requestId 与阶段信息」
- **证据**：静态确定 —— `onDelta` 在 transport 回调里同步调用（`:239-245`）；任何后续异常（读中断、`SseTimeoutException`、**`onDelta` 自身抛错**）都进 `catch`（`:248`）→ `continue` 换下一个候选；下一个候选新建 `ChatStreamAccumulator()`（`:228`）从零开始，再次从头回调 `onDelta`。调用方没有任何「重置」信号
- **描述**：用户会看到「候选 A 的前半段 + 候选 B 的完整段」拼在一起，正文/推理/工具参数三路都受影响；调用方回调抛异常（客户端断开、UI 报错）也会被误判成传输失败并**重发整次请求**（重复计费）。若两次都失败，最终异常里也不含已吐出内容的信息。当前仓内 `chatStream` 只被测试调用（`LLMStream_test.cj:165,187`），但它是公开入口，下游一旦使用即触发。
- **建议**：(1) 一旦有 delta 吐出就把该次请求标记为「不可转移」，失败时抛带 `partial=true` / `emittedDeltas` 的 `LLMException`；或 (2) 在 `LLMHooks` 加 `onRestart` 回调由调用方清屏。另外把 `onDelta` 调用移出 try（或置标志后重抛），避免把调用方缺陷归到网络故障。

### [严重][存量] `previewOf` 按字节切 400，落在多字节字符边界上抛 `IllegalArgumentException`

- **位置**：`f_llm/src/llm/LLM.cj:288-293`（`body[0 .. 400] + '...'`），调用点 `:155`
- **来源**：存量（快照模式无 diff）
- **判据**：`std.core` 文档：`String.size` 是 UTF-8 字节长度，`operator func [](Range<Int64>)`「起止点不是字符边界抛 `IllegalArgumentException`」；review-checklist §11「错误处理」
- **证据**：静态确定 —— 上游错误体（DeepSeek / 智谱等中文平台）通常是中文 JSON，`body.size > 400` 时第 400 个字节有约 2/3 的概率落在某个 3 字节汉字中间；该行位于 `LLMErrorClassifier.isRetryable(status)`（`:156`）**之前**
- **描述**：两个后果：① 429/5xx 这类本该换平台重试的失败，因为构造错误消息时抛异常而直接终止整次调用；② 异常类型从 `LLMException` 变成 `IllegalArgumentException`，`AgentTask` / `Memory` / `fprobe` 里 `catch (ex: LLMException)` 的调用方接不到。表现为「偶发、不可复现的 500」。
- **建议**：字符安全截断（按 rune 取前 N 个字符，或把端点回退到最近的 UTF-8 字符边界）；并把 `previewOf` 包进 try，失败时返回 `'<unprintable>'`，保证「构造错误消息」永不抛异常。补一条「中文错误体 + status=500 仍能转移到下一个候选」的用例。

### [一般][存量] 配置快照 `snapshot` 一处无锁写、多处无锁读，跨线程无同步手段

- **位置**：`f_llm/src/llm/LLMConfsHolder.cj:255`（写）↔ `:112`（`ensureFresh` 读）、`:104-108`（`version`）、`:126`、`:131`、`:171`、`:191`
- **来源**：存量（快照模式无 diff）
- **判据**：review-checklist §12.1「共享可变状态无保护 / 可见性 / 发布逸出」
- **证据**：静态确定（无任何锁 / 原子 / 通道）+ 待确认（仓颉语言层对普通字段跨线程可见性的保证：本地文档只查到「原子操作、互斥锁、条件变量」三种同步机制，见 `md/doc/concurrency/sync.md:1-5`，未见通用内存模型章节）——`mutex` 只保护 `refreshing`（`:225-229`、`:261-264`），`snapshot = LLMConfsSnapshot(...)` 在 `synchronized` 块**之外**执行
- **描述**：刷新线程把新快照写进普通字段，读线程（每次 `candidates/all/peekNext` 入口）无同步读取。没有 happens-before 就没有「读到新版本」的保证；弱内存序平台（ARM）上还可能读到「引用是新的、内部字段未完全可见」的中间态。该类注释自称「刷新整体替换快照，读路径无锁」（`:29`、`:75`），但并未给出无锁发布的安全手段。
- **建议**：`snapshot` 改成 `AtomicReference<LLMConfsSnapshot>`（`std.sync` 文档确认提供 `load/store/compareAndSwap`），一个原子读 + 一个原子写即可获得发布语义，读路径依然无锁；或把读写都放进 `mutex`（成本是每请求一次短锁，需与 §6.2 的竞争一起评估）。

### [一般][存量] 刷新版本号取自调用方捕获的旧快照，可能写出重复版本，balancer 继续持有已下线的 conf

- **位置**：`f_llm/src/llm/LLMConfsHolder.cj:111-117`（`refresh(current)`）→ `:255`（`old.version + 1`）、`:189-194`（`balancersVersion != snapshot.version`）、`:215-218`（`balancer.add(chosen.weight){_ => chosen}`）
- **来源**：存量（快照模式无 diff）
- **判据**：review-checklist §12.1「检查-然后-写入」/ §11「并发正确性」
- **证据**：静态确定（需特定交错，窗口窄）—— `ensureFresh` 先读 `let current = snapshot`（`:112`）、判断 TTL（`:113`）、再 `refresh(current)`（`:116`）。线程 C 在 `:113` 之后被抢占、线程 A 完成一次刷新写出 v2，C 恢复后仍以 `old = v1` 落盘 `v2 = 1 + 1`：版本号重复，但内容是新加载的
- **描述**：`balancerFor` 用 `balancersVersion != snapshot.version` 判断是否重建（`:191`），版本号重复 ⇒ 缓存不失效 ⇒ `LoadBalance` 里 `{_ => chosen}` 闭包捕获的仍是上一份快照的 `LLMConf` 对象（`:215-218`）。之后 `peekNext` 会把**已删除 / 已停用 / url 已改**的 conf 返回给 `LLM.callByName`，请求打到旧端点（旧 key）；`conf.id` 若已不存在，熔断计数还会记到幽灵 id 上。
- **建议**：刷新成功时按「写入那一刻的当前版本」生成版本号（与 `refreshing` 同一把锁内完成），或用单调递增计数器；`balancerFor` 改为按快照引用相等判断重建，彻底不依赖版本号。

### [一般][存量] 熔断只挂在 `*ByName` 入口，流式与直接传候选的调用完全不更新熔断状态

- **位置**：`f_llm/src/llm/LLM.cj:208-285`（`stream` 里没有任何 `hooks` / breaker 调用）、`:68-82`（`chat`/`respond` 构造空 `LLMHooks()`）、`:123-126`（只有 `callByName` 建了真钩子）
- **来源**：存量（快照模式无 diff）
- **判据**：review-checklist §12.1「契约与实现不符」/ §14.1「接线缺失」；类注释 `LLM.cj:84-89`「选号、熔断、失败转移在这里串起来」、`CircuitBreaker.cj:29`「流中断」也算可重试失败
- **证据**：静态确定 —— 全仓 `grep onRetryableFailure|recordRetryableFailure` 的调用点只有 `LLM.cj:148,157` 与 `Embedding.cj:77,83`；`stream()` 的 `catch`（`:248`）只写 `lastError`，不记录失败，成功返回前也不回写成功；`chatStream/respondStream` 只要调用方自备 `candidates` 就绕开 `chatByName` 的选号与熔断。`LLM.chat(candidates, …)` 的唯一生产形态是 `LLMToolLoop.run`（`tool/LLMToolLoop.cj:43,49`），而该循环本身仓内也只有测试引用
- **描述**：一个持续 5xx/断流的平台，只要流量走流式或自备候选，就永远不会被熔断，也不会被 `peekNext` 跳过——与 `CircuitBreaker` 文档承诺的「流中断计入」相反。当前仓内这两条路径无生产调用者（`chatStream` 仅测试），属设计缺口而非现行故障，但对外是公开 API。
- **建议**：把钩子下沉到 `call`/`stream` 的公共层；补 `chatStreamByName/respondStreamByName`；`stream` 的 `catch` 与 `status>=400` 两个可重试分支调 `onRetryableFailure`，成功返回前调 `onSuccess`。

### [一般][存量] 流被提前截断（无 `[DONE]`、无 `finish_reason`）仍按成功返回

- **位置**：`f_llm/src/llm/LLM.cj:267-272`（直接 `chatAccumulator.result()` 返回）；`f_llm/src/llm/ChatStreamAccumulator.cj:135-172`（`result()` 不检查 `done`）
- **来源**：存量（快照模式无 diff）
- **判据**：review-checklist §11「失败路径当成功」/ §3「静默」
- **证据**：静态确定 —— `ChatStreamAccumulator` 只在 `feed` 收到 `[DONE]` 时置 `done`（`:59-62`），`finished` 属性（`:47-51`）在 `LLM.stream` 里**从未被读取**；`result()` 无论 `done` / `finishReason` 是否为空都照常拼出 `LLMResp`
- **描述**：服务端在 `[DONE]` 前正常关闭 TCP（或代理按字节截断）时，`SseReader.next()` 返回 `None`、`stream()` 拿到 `<400` 状态码、`result()` 返回半截正文，`finishReason` 为空、`usageEstimated=true`。调用方无法区分「模型说完了」和「流被截断」；工具调用参数可能只收到一半（`arguments` 截断后 JSON 非法，却仍被当作合法工具调用下发）。
- **建议**：`result()` 或 `LLM.stream` 收口处校验：`!finished && finishReason.isEmpty()` ⇒ 抛 `LLMException(phase: 'truncated')`（或至少在 `LLMResp` 置 `truncated` 标记）；工具调用场景额外校验每个 `arguments` 能被 `JsonValue.fromStr` 解析。

### [一般][存量] 单个非法 SSE 帧就让整条流作废；同一帧里 `content` 与 `tool_calls` 共存时静默丢弃工具调用

- **位置**：`f_llm/src/llm/ChatStreamAccumulator.cj:63`（`JsonValue.fromStr(data).asObject()` 无保护）、`:84-98`（`content` 非空即 `return`，`tool_calls` 分支在其后）
- **来源**：存量（快照模式无 diff）
- **判据**：review-checklist §11「错误处理缺失」/「部分输入被静默丢弃」
- **证据**：静态确定 —— `feed` 的解析没有任何 `try`，`data` 为空串、非 JSON、JSON 不是对象（如 `data: true`）都会抛异常；异常沿 `onData` 冒到 `LLM.stream` 的 `catch`（`:248`）→ 换平台重放（叠加严重 #4 的重复输出）。`mergeDelta` 的判定顺序是 `content` → `reasoning` → `tool_calls`，每帧最多返回一种增量
- **描述**：① 一个坏帧 = 整条流从头再来一次（或整次失败），而 SSE 里偶发空 `data:` 很常见；② 少数实现会在同一帧里同时下发 `content`（或 `reasoning_content`）与首个 `tool_calls` 增量（带 `finish_reason: tool_calls`），此时工具调用片段被丢弃，最终参数缺失或残缺，出错方式还是隐式的
- **建议**：`feed` 内对解析失败降级为 `None` 并记一次 `warn`（带 requestId 与预览，不中断流）；`mergeDelta` 改为「先收集本帧所有增量，再统一上报」，至少保证 `tool_calls` 在任何早退之前处理。

### [一般][存量] `enabled` 开关只在数据库来源生效，`file:` / `env` 配置下停用的平台仍参与调度

- **位置**：`f_llm/src/llm/LLMConfsHolder.cj:237-250`（只过滤 `isPlaceholder`）、`:49-57`（只过滤 `weight > 0`）；来源侧 `f_llm/src/service/LLMConfSource.cj:67-71`（static）、`:92-95`（file）、`:121-146`（env）、`:99-120`（`parseConfJson`）
- **来源**：存量（快照模式无 diff）
- **判据**：review-checklist §11「契约与实现不符」/ §14.1「接线缺失」；承诺源 `f_llm/doc/spec/f-llm-openai-compat/specs/llm-conf-routing/spec.md:41-43`「系统 SHALL 只装载 `enabled = true` 且 `weight > 0` 的配置」
- **证据**：静态确定 —— `LLMConf.enabled` 字段存在（`f_llm/src/model/po/LLMConf.cj:86-87`）；`enabled` 过滤只写在 SQL 里（`f_llm/src/dao/LLMConfDAO.cj:33-36`、`dao/postgres/MetaDAO.cj:58,72`、`dao/mysql/MetaDAO.cj:58,72`），`FileConfSource` / `EnvConfSource` / `StaticConfSource` 原样返回全部行，`parseConfJson` 也不看 `enabled`；holder 这一层是唯一的公共收口，却只判 `isPlaceholder` 与 `weight > 0`
- **描述**：用 `llm_confSource = file:...` 或 `env` 部署时，把一条配置改成 `enabled = false`（典型的「临时下线这个 key」）不会生效，只要 `weight > 0` 就继续分流。与 spec 的过滤器契约不一致，运维会以为已经摘掉。
- **建议**：在 `refresh` 的装载循环里补 `if(!conf.enabled){ dropped++; continue }`（复用现有 warn），并在 `LLMConfsSnapshot.candidates/all` 注释里写清「enabled 由装载层统一过滤」，避免两处判据漂移。

### [一般][存量] 刷新失败后不退避：每个请求都会重新 `load()` 一次配置源

- **位置**：`f_llm/src/llm/LLMConfsHolder.cj:111-117` + `:224-266`（失败只 `log.error`，不动 `loadedAt` / `version`）
- **来源**：存量（快照模式无 diff）
- **判据**：review-checklist §6.1（I/O 等待）/ §11「错误处理缺失」；`mem §5.2`（重试风暴）
- **证据**：静态确定 —— 失败路径（`:259-261`）保留旧 `snapshot`（`loadedAt` 仍是上次成功时间），`ensureFresh` 的判据是 `MonoTime.now() - current.loadedAt < refreshInterval`，因此**下一次访问立刻再次过期**；`refreshing` 只保证同一时刻只有一个线程在 load，不阻止「上一个刚失败、下一个立刻再试」
- **描述**：数据库/文件不可用期间，每次 `candidates/all/peekNext`（即每个 LLM 请求，含 `AgentTask.cj:424-440` 的重试链）都会触发一次完整的 `source.load()`（可能是全表扫描或文件读），把故障放大成「DB 不可用 + 每请求一次连通超时」，日志按请求量刷 error。首次装载就失败（`version == 0`）时更严重。
- **建议**：失败时记录 `nextRetryAt = now + min(cooldown, refreshInterval * 2^n)`（指数退避，上限可配），`ensureFresh` 同时检查它；或失败时把 `loadedAt` 前推到 `now - refreshInterval/2`，把重试间隔至少拉到半个周期。

### [一般][存量] `SaturationContextPruner` 的默认 conf 选择器取「全局第一条」，与「阈值按 conf 取」的契约矛盾且结果不稳定

- **位置**：`f_llm/src/llm/ContextPruner.cj:196-203`（`defaultConfSelector` 取 `LLMCandidateProvider.candidates()[0]`）、`:182-193`（`prune` 用它的 `tokenThreshold`）；`f_llm/src/llm/LLMConfsHolder.cj:59-67`（`all()` 遍历 `byId` 这个 `HashMap`）
- **来源**：存量（快照模式无 diff）
- **判据**：review-checklist §11「语义与注释不符」；类注释 `ContextPruner.cj:158-163`「阈值按 conf 取（评审 B4），不再跨平台取最小值」、`AgentTask.cj:70-74`「可以用 agentId 查询到智能体使用的大模型，进而确定饱和 token 数」
- **证据**：静态确定 —— `LLMCandidateProvider.candidates()` 返回 `LLMConfs.holder().all()`，`all()` 不看 `llmName`，只按 `weight > 0` 过滤后遍历 `HashMap<Int64, LLMConf>`；`HashMap` 迭代顺序不保证稳定。`prune(agentId, session, messages)` 签名里也没有 `llmName`，拿不到「本次请求真正会用到的 conf」，`agentId` 一路传进来却完全没用
- **描述**：饱和裁剪实际用的是「某个任意平台 / 某个任意模型」的 `tokenThreshold`：可能是 embedding 或另一条 chat 配置的阈值，也可能每次进程重启都换成另一个。填小 → 每轮白裁一次（多砍上下文，甚至丢关键历史）；填大或缺 `tokenThreshold` → 该裁不裁，直接把超长上下文发给上游拿 400。
- **建议**：把选择器参数化到「本次请求的 conf」——`prune` 增加 `llmName` / `conf` 形参，或由 `AgentTask` 在调用前把候选 conf 注入 `SaturationContextPruner`；默认实现若保留，至少固定成「按 llmName 排序后取第一条」并写进注释。

### [一般][存量] `RetainLastUserPruner` / `RetainLastNRoundPruner` 就地修改内层返回的列表（可能就是调用方入参）

- **位置**：`f_llm/src/llm/ContextPruner.cj:274`（`msgs.add(lastUser.getOrThrow())`）、`:295`（`msgs.add(all: last)`）
- **来源**：存量（快照模式无 diff）
- **判据**：review-checklist §11「副作用不对称」/ §12.1「共享可变状态」
- **证据**：静态确定 —— 内层 `ContextPruner` 有多个实现直接 `return messages`（`RetainContextPruner:34-36`、`LastNContextPruner:53-55` 的未超限分支、`SaturationContextPruner:192` 的未触发分支），此时 `msgs` 与入参是同一个 `ArrayList` 实例，`add` 会改到调用方持有的列表上；`ArrayList` 切片返回新对象（`std.collection` 文档：「切片操作返回的 ArrayList 为全新的对象」），所以只有「原样返回」的实现会中招
- **描述**：`AgentTask.cj:412-413` 把 `params.messages` 传进去又接回同一个变量，当场看不出问题；但任何缓存/复用同一份 `messages` 的调用方（例如多轮重试复用同一 `params`）每裁剪一次就会往自己的列表尾部追加一份「最后一条 user」/「最后一轮」，消息数随调用次数单调增长，直到超上下文。这也让「裁剪」变成非纯函数，难测试。测试用的是 `LastNContextPruner(n: 0)`（返回副本），未覆盖。
- **建议**：两个装饰器都先复制（`let out = ArrayList<ChatMessage>(msgs); out.add(...)`）再返回；或在接口注释里写死「装饰器不得原地改内层结果」，并补一个「内层返回入参」的用例断言入参长度不变。

### [一般][存量] `ContextLLMPruner.prune` 取「最后一条消息」无保护，并强改其 role

- **位置**：`f_llm/src/llm/ContextPruner.cj:72-74`（`let msg = msgs[msgs.size - 1]; msg.role = ROLE_USER; return msgs`）
- **来源**：存量（快照模式无 diff）
- **判据**：review-checklist §11「空集合未处理」/「语义与命名不符」
- **证据**：静态确定 —— `ChatCompletionsMapper.parse`（`:147-163`）只在 `choices` 非空且带 `message` 时 `appendMessage`，上游返回 `choices: []`（内容审核拒绝、空响应）时 `LLMResp.messages` 为空，`msgs[-1]` 抛 `IndexOutOfBoundsException`；`msg.role = ROLE_USER` 是对**解析出来的消息对象**的就地改写，该对象还带着上游的 `reasoning_content`、`tool_calls`
- **描述**：摘要/关键词裁剪在上游返回空 choices 时会崩在裁剪里，而不是给出可诊断的错误；把 assistant 消息改标成 user 后，如果这条消息带 `tool_calls`，后续请求会出现「user 消息带 tool_calls」的非法报文（OpenAI 协议要求 `tool_calls` 只出现在 assistant 上）。
- **建议**：`if(msgs.isEmpty()){ return ArrayList<ChatMessage>() }`（或抛带 provider/model 的 `LLMException`）；返回时新建一条 `UserMessage` 承载内容，而不是复用解析出的对象。

### [一般][存量] 非流式 200 响应体不是 JSON 对象 / `choices` 为空时，异常不包装、空消息直落下游

- **位置**：`f_llm/src/llm/LLM.cj:164-168`（`JsonValue.fromStr(response.body).asObject()` 无 try）；`f_llm/src/llm/ChatCompletionsMapper.cj:147-158`（空 choices 返回空 `messages`）
- **来源**：存量（快照模式无 diff）
- **判据**：review-checklist §11「错误处理」/「失败路径当成功」；§10 契约
- **证据**：静态确定 —— 解析不在任何 try 内，且 `result` 的 `messages` 可能为空；`call` 的注释只承诺「可重试状态码或传输异常 → 换下一个候选」「其余 4xx 立即抛出」
- **描述**：三种现实情况都走不到正常失败路径：① 网关/WAF 返回 200 + HTML、模型下线返回纯文本 → 抛原生解析异常，既不是 `LLMException` 也不会转移；② 上游返回 JSON 数组 → `asObject()` 抛错，同上；③ 200 + `choices: []`（审核拦截/空响应）→ 返回一个 `messages` 为空的 `LLMResp`，被当成成功，下游 `messages[0]`（`f_llm/src/memory/Memory.cj:70`）与 `ContextLLMPruner:73` 再崩一次，堆栈离真实原因很远。
- **建议**：解析包 try，失败转成可重试的 `LLMException`（带 status 与 `previewOf(body)`）；`messages` 为空时按「上游未返回内容」失败，或在 `LLMResp` 显式标记 `empty` 让调用方判断。

### [一般][存量] 饱和阈值判定在两处各写一遍，且口径已经分叉

- **位置**：`f_llm/src/llm/ContextPruner.cj:182-193`（`SaturationContextPruner.prune`）↔ `f_llm/src/llm/LLMConfsHolder.cj:139-146`（`saturated`）
- **来源**：存量（快照模式无 diff）
- **判据**：review-checklist §2「跨层复制 / 只改类型名」
- **证据**：静态确定 —— 两处都是「`threshold = conf.tokenThreshold`；`threshold <= 0` 返回 false / 不裁；`HeuristicTokenCounter().count(conf, messages) >= threshold`」；差别只有返回类型（`Bool` vs 直接返回裁剪结果）和 conf 来源。`grep saturated` 显示 holder 版本只被测试调用（`LLMByName_test.cj:138-140`），生产走 pruner 版本
- **描述**：同一业务判据两份实现。`HeuristicTokenCounter` 换算法、`tokenThreshold` 改成「占比」或加 0.9 折算时很容易只改一处——这正是两者现在已经分歧的起点（一个用调用方传入的 conf，一个用全局第一条 conf，见上一条）。另外 `TokenCounter` 约定「无法计数返回 -1、由调用方决定」（`TokenCounter.cj:28-29`），这两个调用点都没有处理 -1。
- **建议**：保留 `LLMConfsHolder.saturated(conf, messages)` 作为唯一实现，`SaturationContextPruner.prune` 改为调用它；同时补「`count` 返回 -1 时按 0.9 折算或保守不裁」的分支。

### [一般][存量] `LLMCandidateProvider.defaultSupplier` 吞掉所有异常返回空列表，裁剪阈值静默失效

- **位置**：`f_llm/src/llm/LLMCandidateProvider.cj:37-44`（`try{ LLMConfs.holder().all() }catch(_: Exception){ ArrayList<LLMConf>() }`）；`f_llm/src/llm/LLMConfs.cj:52-57`（同类静默回退，无日志）
- **来源**：存量（快照模式无 diff）
- **判据**：review-checklist §3「`catch` 静默吞异常」
- **证据**：静态确定 —— 失败路径既无日志也无标记，返回空列表；唯一生产消费者是 `ContextPruner.cj:196-203` 的 `defaultConfSelector`，`list.isEmpty()` ⇒ `None` ⇒ `SaturationContextPruner` 直接返回原消息（`:183-191`）。`LLMConfs.createHolder` 的 MetaStore 分支失败时也静默掉到旧来源，同样无日志，可能读到与 MetaStore 不同的一份配置（split-brain）
- **描述**：配置库瞬时不可用 / `LLMConfs.holder()` 初始化抛异常时，饱和裁剪会被静默关闭，随后超长上下文打上游拿 400；排障时日志里只有 `LLMConfsHolder` 的 error，看不出「裁剪因此被跳过」。这也与「无法计数返回 -1」的显式约定相反——这里选择了「假装没有候选」。
- **建议**：两处 `catch (e: Exception)` 都记 `warn`（带 `e`）后再回退；`defaultConfSelector` 在 `None` 时记 `debug`「saturation pruner skipped: no conf」。

### [一般][存量] `max_tokens` 默认 65536 且无条件写进每个请求报文，没有任何按模型收敛的逻辑

- **位置**：`f_llm/src/llm/LLMParams.cj:31`（`private var max_tokens: Int64 = 65536`），序列化点 `f_llm/src/llm/ChatCompletionsMapper.cj:37`（`JsonValue.from(params.toData())` 整对象转 JSON）
- **来源**：存量（快照模式无 diff）
- **判据**：review-checklist §11「契约与实现不符」/ §14.1「半成品：只支持部分输入」/ §1「读了不用」
- **证据**：待确认（需一次真实请求确认上游是否拒绝）—— 代码层静态可见：`grep max_tokens` 在 `f_llm/src` 只命中定义处，`ChatCompletionsMapper` / `ResponsesMapper` / `ModelCapabilities` / `ProviderDialect` 都没有读取或裁剪它；`JsonValue.from(params.toData())` 会把所有字段（含默认值）转成报文，因此 `max_tokens: 65536` 会出现在每个非流式与流式请求里
- **描述**：多数平台的 `max_tokens` 上限远低于 65536（DeepSeek 8192、GLM-4 4096 量级）。若上游严格校验，所有请求会在 400 上失败并触发整串候选转移；若上游只做截断，则该字段等于永不起作用，用户也无法通过配置表达「本次最多要多少 token」——两种情况下这个默认值都没有实际意义。
- **建议**：默认改为不发送（`max_tokens <= 0` 时 `body.remove('max_tokens')`），由 `ModelCapabilities` / `LLMConf.conf['maxTokens']` 提供按模型上限收敛（`min(请求值, 模型上限)`）；补 mapper 用例：默认参数不出现 `max_tokens`、显式设置后按上限收敛。

### [轻微][存量] 错误诊断信息在失败路径上被丢弃或标错

- **位置**：`f_llm/src/llm/LLM.cj:173-183`（`details` 构造后被 `lastError` 分支丢弃）、`:249-252`（所有异常恒标 `phase: read`）、`:256-259`（流式 4xx 异常不含错误体）
- **来源**：存量（快照模式无 diff）
- **判据**：review-checklist §11「错误处理缺失」/ §14.1「半成品」
- **证据**：静态确定 —— `call` 先拼好 `tried: [a, b]` 再 `if(let Some(error) <- lastError){ throw error }`，`details` 在这条分支永远用不到；`stream` 的 `catch` 不含阶段判别，连接/DNS/TLS 失败与读中断都写成 `phase: read`；流式 4xx 只带 `status`，没有非流式那条 `previewOf(body)`
- **描述**：排障时「为什么没连上」与「读到一半断了」不可区分；同一份报文两个入口的异常信息量不对称，流式更难查。
- **建议**：把 `tried` 拼进 `lastError.message`（或在 `LLMException` 上加 `tried` 字段）；`catch` 里按异常类型分 `connect` / `read`（`SseTimeoutException` 单标 `idle-timeout`）；流式 4xx 也带截断后的响应体。

### [轻微][存量] 冗余判断、无用构造与未使用 import

- **位置**：`f_llm/src/llm/LLMConfsHolder.cj:201`（重复判 `weight > 0`）、`:171`（为取 `count` 复制整表）、`:135-137`（`getTokenThreshold` 纯转手）；`f_llm/src/llm/LLMCandidateProvider.cj:21`（未使用的 `import fountain::f_bean.*`）
- **来源**：存量（快照模式无 diff）
- **判据**：review-checklist §1「未使用的 import / 读后不用」、§6.4「已知规模却多走一趟」
- **证据**：静态确定 —— `snapshot.candidates(llmName)` 已过滤 `weight > 0`（`:49-57`），`balancerFor` 再判一次；`getTokenThreshold` 与 `saturated`（`:139-146`）内的 `conf.tokenThreshold` 完全等价；`LLMCandidateProvider.cj` 全文未使用 `f_bean` 任何符号（无 `@Bean`、无 `lookup*`）
- **描述**：`getTokenThreshold` 还制造了「阈值有独立入口」的错觉（实际没有任何附加逻辑），与 `saturated` 形成第二个入口。
- **建议**：删掉未用 import 与 `getTokenThreshold`（`LLMByName_test.cj:141` 改断言 `conf.tokenThreshold`）；`balancerFor` 直接用 `snapshot.candidates()` 的结果。

### [轻微][存量] 空响应仍造消息、熔断无半开探测、`isFatal` 把成功码也算 fatal

- **位置**：`f_llm/src/llm/ChatStreamAccumulator.cj:138-141`、`f_llm/src/llm/CircuitBreaker.cj:54-68`/`:77-99`、`f_llm/src/llm/LLMErrorClassifier.cj:37-39`
- **来源**：存量（快照模式无 diff）
- **判据**：review-checklist §11「边界 / 语义与命名不符」
- **证据**：静态确定 —— `result()` 在 `order.isEmpty()` 时无条件 `response.messages.add(AssistantMessage(content))`，`content` 可能为空串；`isOpen` 冷却到期即把 `openUntil` / `failures` 全部清零，没有「先放一个探测请求、成功再全开」的状态；`isFatal = !isRetryable`，`isFatal(200)` 返回 `true`
- **描述**：空 assistant 消息会进入下一轮历史（部分平台拒收空 `content`）；冷却结束瞬间所有并发流量同时回到刚恢复的平台，容易再次打挂；`isFatal` 的名字与语义不一致，误用会把成功响应当失败。
- **建议**：`result()` 在 `content`/`reasoning` 都为空且无工具调用时不加消息（或标 `finishReason='empty'`）；熔断加 `HalfOpen` 状态（只放 1 个探测）；`isFatal` 改为 `status >= 400 && !isRetryable(status)`，或删掉这个没有生产调用者的包装（仅 `ChatCompletionsResponse_test.cj:214` 使用）。

### [轻微][存量] `LLMConfs.holder()` 在全局锁内做存储初始化

- **位置**：`f_llm/src/llm/LLMConfs.cj:61-71`（`synchronized(mutex)` 内调 `createHolder()`）→ `:49-59`（`StoreSettings.load()`、`MetaStoreAdapter()` 构造）
- **来源**：存量（快照模式无 diff）
- **判据**：review-checklist §6.2「锁内 I/O」
- **证据**：静态确定 —— `createHolder` 的 `StoreSettings.load()` 与适配器构造都可能触达文件/存储，且整段在 `LLMConfs.mutex` 内；仅在首次初始化执行，之后走缓存
- **描述**：首个 LLM 请求会持锁完成存储初始化，同刻的其它请求全部排队；若初始化抛异常，每次请求都会重试一遍（`current` 仍为 `None`），错误放大方式与 `LLMConfsHolder.refresh` 相同但没有日志。
- **建议**：锁外构造、锁内二次检查后发布；构造失败加一次 `warn` 与退避（与 `LLMConfsHolder` 的刷新退避共用策略）。

### [轻微][存量] 测试桩与全局单例互相污染

- **位置**：`f_llm/src/llm/ContextPruner_test.cj:167-171`、`:181-183`；`f_llm/src/llm/LLMByName_test.cj:28-49`
- **来源**：存量（快照模式无 diff）
- **判据**：review-checklist §11「契约与实现不符」；`LLMConfSource` 接口约定「必须整体返回一份快照，不要返回内部可变结构」（`service/LLMConfSource.cj:32`）
- **证据**：静态确定 —— 测试向进程级单例 `ContextPrunerMediator.instance` 注册 `TokenBudget_999` 且不注销；`StaticSource.load()` 直接返回构造时传入的同一个 `ArrayList`（对比生产 `StaticConfSource.load` 会复制，`service/LLMConfSource.cj:67-71`）；`FixedTransport` 在 `statuses` 为空时走 `statuses[statuses.size - 1]` = `[-1]`，`calls` 为非原子 `var`
- **描述**：注册表与全局 holder/transport 被测试改写后不还原，用例并行或重复执行时结果依赖顺序；`StaticSource` 违反接口的「返回快照」约定，被其他测试复用时会出现跨用例的列表污染。
- **建议**：`StaticSource.load()` 复制一份；`FixedTransport` 对空 `statuses` 直接抛断言；把 mediator 的注册改为可注入实例或在 `@AfterEach` 里清理。

### [轻微][存量] `ContextSummaryPruner` 与 `ContextKeywordsPruner` 除提示词外逐行相同

- **位置**：`f_llm/src/llm/ContextPruner.cj:89-107` 与 `108-126`
- **来源**：存量（快照模式无 diff）
- **判据**：review-checklist §2「近似重复：只改字面量」
- **证据**：静态确定 —— 两个类的 `init` 参数表、`super(...)` 调用、`name` 拼装方式完全一致，差异只有默认 `promptsGenerator` 文案与 `CONTEXT_PRUNER_SUMMARY` / `KEYWORDS` 常量
- **描述**：两份实现同时承担「参数默认值 + 名称规则」，以后给摘要加 `max_tokens` 限制或改提示词插值方式时容易只改一处。
- **建议**：抽一个带 `namePrefix` 与 `defaultPrompt` 的基类（或让 `ContextLLMPruner` 接受 `nameSuffix`），两个子类只提供常量与默认提示词。

### [轻微][存量] `LLMParams.cj` 内三处近重复：`Property` 与手工拼的字段、两个 `addProperty`、`addFunctions`/`addFunction`

- **位置**：`f_llm/src/llm/LLMParams.cj:105-110` 与 `111-119`（两个 `addProperty`）、`44-48` 与 `49-51`（`addFunctions` / `addFunction`）、`123-127`（`Property`）
- **来源**：存量（快照模式无 diff）
- **判据**：review-checklist §2「字面量复制 + 子集实现」
- **证据**：静态确定 —— `addProperty(name:type:description:)` 手写的 `'type'` / `'description'` 键与 `Property` 的字段一一对应；`addFunction` 就是 `addFunctions` 的单元素版本；`Property` 全仓零引用（`grep -rn "\bProperty\b" --include=*.cj` 只命中定义处，属对外可达 public，**不算死代码**，仅记「仓内无引用」）
- **描述**：JSON 字段名散落在两处，字段改名时容易只改一边，生成上游不认的 schema；两个 `addProperty` 重载里「没有则新建对象」的分支也是重复的。
- **建议**：`addProperty(name:type:description:)` 内部委托给 `addProperty(name:propName:propValue:)`；`addFunction` 改成 `addFunctions([function])`；`Property` 要么用于构造，要么标 `@Deprecated` 留到下一个大版本删。

### [轻微][存量] README 对裁剪策略的两处描述与实现相反（文档侧属其他部分）

- **位置**：实现侧 `f_llm/src/llm/ContextPruner.cj:51-52`（`LastN` 取 `2 * n` 条）、`48-56` / `223-244`（不保留首条 system）；文档侧 `f_llm/README.md:199`（「保留最近 N 条」）、`README.md:206-207`（「各策略都以保留首条 system 为约定」）
- **来源**：存量（快照模式无 diff）
- **判据**：review-checklist §13「文档与实现相反」
- **证据**：静态确定 —— 规格侧与实现一致：`f_llm/doc/spec/f-llm-openai-compat/specs/llm-context-pruning/spec.md:16-19` 明确 `LastN_2` 在 6 条输入上保留最后 4 条；README 与规格冲突
- **描述**：按 README 配 `LastN_2` 会得到「最近 4 条」而不是「最近 2 条」；`LastN` / `TokenBudget` 也确实会丢掉首条 system 消息（`TokenBudgetContextPruner` 只看尾部预算）。**文档侧文件不在本部分清单内**，此处登记以便与 README 所属部分合并去重。
- **建议**：README 改为「N 轮 = 2N 条」，并把「保留首条 system」限定到 DRC/Summary 等实际保证的策略。

> **范围外提示**：`AgentTask.cj:54-75` 注释把 `LastN_*` / `Summary_*` / `DRC_*` / `Saturation_*` 描述成可直接配置的名字，但 `ContextPrunerMediator.ensureLoaded`（`ContextPrunerMediator.cj:28-38`）只登记 `@Bean`（当前仅 `RetainContextPruner`），`register` 全仓只有测试调用（`ContextPruner_test.cj:168,171`）——生产要用其余策略必须自行注册。该行为已被项目文档记录（`docs/fountain实现思想与应用/…第16弹….md:246,559`），本次不展开、不计数，交由 `AgentTask.cj` 所属部分判定注释是否要补一句。

<!-- 第 13 部分 -->

### [严重][存量] LLM 传输层显式关闭 TLS 证书校验，Bearer Key 与完整应答都暴露在中间人信道

- **位置**：`f_llm/src/llm/LLMTransport.cj:46-48`（`DefaultHttpTransport.post` 里 `tls.verifyMode = CertificateVerifyMode.TrustAll`）；同一根因另两处：`f_llm/src/llm/LLMStreamTransport.cj:48-50`（流式传输）、`f_llm/src/util/http.cj:25-27`（`RemoteTokenCounter` 等使用的 `http()` 助手）
- **来源**：存量（`git blame -L 46,50 -- f_llm/src/llm/LLMTransport.cj` → `d3ebac7923 2026-10-27`；另外两处同作者同期）
- **判据**：review-checklist §10（安全性：敏感数据 / 硬编码降级）+ §11（契约与实现不符：调用方以为在走标准 HTTPS）
- **证据**：静态确定 —— 三处都在构造 `HttpClient` 后无条件把 `TlsClientConfig().verifyMode` 置成 `CertificateVerifyMode.TrustAll`，没有任何配置项能切回默认校验（全仓 `CertificateVerifyMode.TrustAll` 共 8 处：`f_llm` 内 7 处——本文件的 `LLMTransport`、`LLMStreamTransport`、`util/http`，加 `balance/BalanceQueriers.cj:42`、`embedding/BgeM3Transport.cj:91`、`search/DeepSeekSearchProvider.cj:44`、`store/hydra/HttpTransport.cj:203`；以及 `f_app/src/PublishCommand.cj:298`。没有一处按配置判断；反例是 `f_mvc/src/MVCConfig.cj:92` 已经把 `trustall` 做成可配置项，说明仓内已有正确形态可参照）
- **描述**：`DefaultHttpTransport.post` 是所有非流式 LLM 调用的唯一生产通道（`LLM.cj:38` 把 `transport` 初始化成它）。它把证书校验关成 TrustAll，而请求头里带的是 `Authorization: Bearer ${conf.auth}`（`ProviderDialect.cj:71`、`ProviderDialects.cj:150`）——即明文 API Key，响应体是模型输出与 usage。任何能劫持 DNS / 中间设备 / 企业代理的对手都可完整拿到密钥并篡改响应（例如把工具调用参数改掉）。这不是"自签证书兼容"的局部例外，而是对所有 provider 一律生效；`doc/known-limitations.md` 与 README 都没有把它记为已知限制。`RemoteTokenCounter` 走 `util/http.cj` 的同一助手，同样把 Key 发到 `conf['tokenizerUrl']`
- **建议**：①改为默认校验，只在 `conf` 显式给出 `tlsInsecure=true`（或给某个自建内网 endpoint）时降级，并在日志里 warn 一次；②给 `LLMConf` 增加 `caFile` / `tlsInsecure` 两个选项，把 `TlsClientConfig` 的构造收敛到一个工厂（见轻微第 4 条，三处重复的正是这段）；③流式与非流式共用同一个工厂，避免只修一处

### [一般][存量] Responses 路径静默丢弃 `max_tokens` 与 `response_format`，同一份 `LLMParams` 在两条协议下语义不同

- **位置**：`f_llm/src/llm/ResponsesMapper.cj:36-91`（`build` 只写 `model` / `instructions` / `input` / `temperature` / `stream` / `tools`）
- **来源**：存量（`git blame` → `2026-10-27` 同批提交，快照模式无 diff）
- **判据**：review-checklist §11（契约与实现不符）+ §14.1（只做了一半的映射）
- **证据**：静态确定 —— `LLMParams` 的字段是 `model / messages / thinking / response_format / temperature / max_tokens`（`f_llm/src/llm/LLMParams.cj:22-31`）；Chat 路径用 `JsonValue.from(params.toData())` 整体序列化后再按值剔除（`ChatCompletionsMapper.cj:37-64`），所以 `max_tokens`、`response_format` 都会进报文；Responses 路径是"手拼白名单"，这两个字段在 `build` 里没有任何对应写入，且全文件搜 `max_tokens` / `max_output_tokens` / `response_format` 零命中
- **描述**：`LLM.respond` / `respondByName` 与 `LLM.chat` 接受同一个 `LLMParams`，但走 Responses 时：①`max_tokens`（默认 65536）不生效 → 不能限制单次输出长度，长回答成本与延迟不可控；②`response_format=json_object` 不生效 → 需要结构化输出的调用方（工具参数、评测）拿到自由文本，下游 `JsonValue.fromStr` 直接失败。两条都是"不报错、结果不对"，比抛异常更难查。Responses 协议的对应字段是 `max_output_tokens` 与 `text.format`，不是简单改名，确实需要单独映射——但现在的实现是"整段缺失"
- **建议**：在 `build` 里补两段映射（`max_tokens` → `max_output_tokens`，`response_format.type == json_object` → `text: {format: {type: 'json_object'}}`），并加一条 `ChatCompletionsMapper` / `ResponsesMapper` 的字段覆盖对照用例：同一个 `LLMParams` 两边都断言"该带的字段都带了"，防止以后再漏

### [一般][存量] `ResponsesMapper.parse` 把 `status=failed / incomplete` 当成功返回，错误原因被丢弃

- **位置**：`f_llm/src/llm/ResponsesMapper.cj:93-128`（`:95` 只把 `status` 写进 `finishReason`，随后无条件返回 `LLMResp`）
- **来源**：存量（`git blame` → `ce62d320ef 2026-10-27`）
- **判据**：review-checklist §11（失败路径当成功）+ §3（`Result` 失败被丢弃）
- **证据**：静态确定 —— `parse` 的入参是 HTTP 200 的响应体；当 `status` 为 `failed`/`incomplete` 时，`output` 通常为空或缺项，循环不产生消息，函数仍返回一个 `messages` 为空的 `LLMResp`；`resp.get('error')` / `incomplete_details` 全文件零引用
- **描述**：上游以 200 + `status: failed` 表达业务失败（Responses 的常见形态）时，`LLM.call` 认为成功，`hooks.onSuccess(conf.id)` 清掉熔断计数，返回空消息列表。后果按调用方：`respond` 的外部使用者拿到空 `messages[0]`（越界或空回答）；若上层拿它继续工具循环，会和"模型没话说"混淆。同时 `error.message` 不进任何日志/异常，线上只能看到 `finish: failed`
- **建议**：`status` 不属于 `completed`/`in_progress` 时抛 `LLMException`（消息带 `error.code/message` 与 `incomplete_details.reason`），或至少把错误文本塞进 `finishReason` 之外的独立字段；配一条 fixture：`{"status":"failed","error":{"code":"server_error","message":"boom"}}` 断言抛异常

### [一般][存量] Responses 流在缺 `response.completed` 时返回"成功"的部分结果，截断对调用方不可见

- **位置**：`f_llm/src/llm/ResponsesStreamAccumulator.cj:79-93`（`result()`：只有 `failure` 与 `completed` 两个分支，其余一律走 86-92 行拼装 `partial`）
- **来源**：存量（`git blame` → `ce62d320ef 2026-10-27`）
- **判据**：review-checklist §11（错误处理缺失）+ §3（`case None` 兜底把错误吃掉）
- **证据**：静态确定 —— 类内没有"是否收到终态事件"的标志：`done` 只由 `[DONE]` / `response.completed` / `failed` / `error` 置位，而 `result()` 完全不读 `done`；走到 86 行时既可能是"SSE 正常结束但上游没发 completed"，也可能是"连接中断被上层吞掉"，两者都返回 `usageEstimated=true` 的正常 `LLMResp`，`finishReason` 为空串
- **描述**：调用方无法区分"模型正常答完"与"答到一半断了"。`LLM.stream`（`LLM.cj:267`）在 `transport.stream` 返回后直接 `result()`，若流被对端提前关闭（CDN/网关超时、上游 5xx 后断开），拿到的是半截正文 + `finish:'undefined'`，会被当成最终答案落库/回应用户。Chat 路径有同样的隐患，但 Responses 侧本来就有 `response.completed` 这个明确终态可用却没使用
- **建议**：`result()` 里 `completed.isNone() && !done` 时抛 `LLMException('responses stream ended without response.completed')`，或返回带 `finishReason='truncated'` 的结果并让 `LLM.stream` 按可重试失败处理（注意此时已经向 `onDelta` 推过增量，需要上层决定是否丢弃）

### [一般][存量] 非流式 HTTP 传输没有显式超时，完全依赖 stdx 默认值，而 f_llm 从未为 LLM 路径设置全局超时

- **位置**：`f_llm/src/llm/LLMTransport.cj:40-53`（`post` 只 `new HttpClient(url)` + header + tlsConfig，无 `readTimeout`/`writeTimeout`）
- **来源**：存量（`git blame` → `d3ebac7923 2026-10-27`）
- **判据**：review-checklist §11（资源与超时）+ §12.1（无界阻塞）
- **证据**：待确认 —— ①`HttpClient` 构造只把**进程级静态**超时应用上去（`f_httpclient/src/httpclient.cj:41-48` 读 `readTimeout_`/`writeTimeout_`，二者只由 `globalReadTimeout`/`globalWriteTimeout` 写入，`:29-36`）；②全仓 `globalReadTimeout` 只有 `f_llm/src/embedding/BgeM3Transport.cj:63-64` 与一个测试调用，LLM 路径从不设置；③因此 `DefaultHttpTransport` 的读超时等于 `ClientBuilder` 的默认值，该默认值不在仓内、本次环境也没有 stdx 源码/文档可核（SDK 目录只有二进制）。缺的数据：stdx `ClientBuilder.readTimeout` 的默认值，以及一次 >120s 的长回答实测（若默认较短，长推理请求会被误判成传输失败并触发换平台；若默认无限，则对端不响应时线程会一直挂着）
- **描述**：两条后果方向相反、都不可接受：默认超时偏短 → 长回答被截断后走 failover，重复计费；无默认超时 → 单个卡住的 provider 占住一个请求线程，直到 TCP keepalive 才释放。流式路径有 `llm_streamIdleTimeout`（默认 120s，`LLMConfig.cj:176-178`）兜底，非流式路径没有任何同类配置项
- **建议**：给 `LLMConf` 或 `LLMConfig` 增加 `llm_readTimeoutMs` / `llm_connectTimeoutMs`（默认值应大于最长生成时间，例如 300s），在 `DefaultHttpTransport` 里显式 `client.readTimeout(...)`/`writeTimeout(...)`，不要再依赖进程级 `globalReadTimeout`（它会被 embedding 的 3s 默认值顺带改掉，见下条）

### [一般][存量] A2A 代理卡片硬编码名称/描述与 80 端口 URL，与规格"由 LLMConfig 拼出"冲突，默认部署下卡片地址不可用

- **位置**：`f_llm/src/loom/A2aBridge.cj:129-132`（`defaultCard()`：`name: 'loom-supervisor'`、中文 `description`、`url: 'http://127.0.0.1/rpc/a2a'`）
- **来源**：存量（快照模式无基线；文件头年份 2026，与 A2A 特性同批）
- **判据**：review-checklist §14.1（承诺了但没实现 / 接线缺失）+ §13（规格与实现漂移）
- **证据**：静态确定 —— ①承诺源：`f_llm/doc/spec/add-loom-a2a/proposal.md:22`「卡片由 `LLMConfig` 里的名称/描述拼出，`url` 指向 `/rpc/a2a`」，`tasks.md:14` 同款验收口径；②缺失证据：`LLMConfig.cj` 里 A2A 只有 `llm_a2aEnabled`（`:62-68`），没有任何 name/description/host/port 配置项；`defaultCard()` 三个字段全是字面量；③端口：仓内所有 A2A 示例都是 `http://127.0.0.1:8080/rpc/a2a`（`f_a2a/README.md:54,98`、`f_a2a/doc/a2a-protocol.md:188`），这里是 80 —— 除非进程恰好监听 80，外部客户端按卡片地址调用必然连接失败
- **描述**：开启 `llm_a2aEnabled=true` 后，`a2a.agent.card` 返回的 URL 指向本机 80 端口，而 fountain 应用默认监听 8080（`LoomA2a` 的日志也只打 `chosenCard.url`）。对接方拿到卡片 → 直接 POST 到 80 → 连接被拒，且没有任何日志提示"卡片地址是猜的"。名称/描述硬编码还导致多实例部署时对外全是同一个 `loom-supervisor`，没法区分
- **建议**：新增 `llm_a2aName` / `llm_a2aDescription` / `llm_a2aUrl`（缺省时用 `f_config` 里的服务端口拼 `http://127.0.0.1:<port>/rpc/a2a`），`defaultCard()` 只做兜底并在兜底时 `warn`；补一条断言"配置了 `llm_a2aUrl` 时卡片取配置值"的用例

### [一般][存量] `DoSample` 的默认 `mut prop` setter 是空实现：写 `do_sample = false` 静默无效

- **位置**：`f_llm/src/llm/advanced_params.cj:32-39`（`get(){ true }` + `set(value){}`）
- **来源**：存量（`git blame -L 32,39` → `4be871f2fd 2026-10-02`）
- **判据**：review-checklist §3（空实现：公开契约承诺有行为）
- **证据**：静态确定 —— setter 参数 `value` 未使用、函数体为空；getter 恒返回 `true`，所以该属性的取值与赋值完全脱钩。全仓搜 `DoSample` 只有定义处（README 索引 `f_llm/README.md:864` 登记了这个公开接口），没有任何类实现或使用
- **描述**：这是"接口给默认实现"的典型空实现：任何类 `class X <: DoSample` 都会继承这个 setter，`x.do_sample = false` 能编译、能运行、什么也不改，采样参数永远按 true 下发。当前仓内零使用，所以现在没有实际损失；但它是对外 public 接口，一旦被下游采纳就是静默错配（同文件 `FrequencyPenalty` / `ThinkingBudget` 只有只读默认值，没有这个问题）
- **建议**：二选一——(a) 删除这三个未使用的接口（对外 API 收窄需用户确认）；(b) 若要保留，把 `do_sample` 改成 `private var` + 由实现类覆盖，或在 setter 里真的存值（`mut prop` 的默认实现必须能被覆盖时才有意义）。同类问题合并检查：`FrequencyPenalty.frequency_penalty` / `ThinkingBudget.thinking_budget` 的默认值 0.5 / 1024 也没有任何配置来源

### [一般][存量] `ResponsesMapper.parse` 的 reasoning 跨 `output` 项不清零：后续 message 重复挂同一段思考内容，提前出现的 reasoning 则整段丢失

- **位置**：`f_llm/src/llm/ResponsesMapper.cj:96`（`var reasoning = ''`）、`:101`（`reasoning += textOfReasoning(obj)`）、`:104-106`（挂到 `assistant.reasoningContent` 后不重置）
- **来源**：存量（`git blame` → `ce62d320ef 2026-10-27`，与 `parse` 同批）
- **判据**：review-checklist §11（逻辑错误：状态变量跨迭代复用）＋ §2（与 `ChatCompletionsMapper.appendMessage` 的「一条响应一份 reasoning」语义漂移）
- **证据**：静态确定 —— `reasoning` 声明在 `for(item in rawOutput...)` 之外；`case 'reasoning'` 只累加，`case 'message'` 只读取，`parse` 全程没有 `reasoning = ''`
- **描述**：`output = [reasoning, message, message]` 时两条 `AssistantMessage` 都带同一份 `reasoningContent`，回灌下一轮上下文会重复计费，并让模型看到两份互相矛盾的「上一次思考」；`output` 里 reasoning 排在 message 之后（ReAct 风格的分段输出）时，先出现的 message 完全拿不到 reasoning。仓内测试只覆盖单 message（`LLMStream_test.cj:136-144`），没覆盖多 message。
- **建议**：`case 'message'` 挂载后立即 `reasoning = ''`，把 reasoning 归属「紧随其后的第一条 message」；补一条 `output` 含两组 `reasoning + message` 的用例，断言两条消息各带各的 reasoning。

### [轻微][存量] 6 个方言各写一遍 `endpoint` / `headers`，已经出现 `Accept-Encoding` 漂移

- **位置**：`f_llm/src/llm/openai/ProviderDialect.cj:58-64`（`StandardDialect.endpoint`）、`:66-74`（`headers`）；`f_llm/src/llm/openai/DeepSeekDialect.cj:39-46`、`:48-56`；`f_llm/src/llm/openai/ProviderDialects.cj:38-45`、`:64-71`、`:90-97`、`:126-133`（4 份 `endpoint`）、`:145-154`（`bearerHeaders`）
- **来源**：存量（`git blame` → `33216a0f12 2026-10-28` 方言表重构）
- **判据**：review-checklist §2（换控制流 / 跨文件复制，且差异不是业务要求）
- **证据**：静态确定 —— 6 份 `endpoint` 的 Chat 分支逐行相同（`trimTrailingSlash(conf.url) + conf.option('chatPath', '/chat/completions')`），Responses 分支 4 份只改错误文案；`headers` 有 3 份（`StandardDialect`、`DeepSeekDialect`、`bearerHeaders`），前两份**没有** `Accept-Encoding: identity`，`bearerHeaders` 有，测试也只对 zhipu 断言了这一项（`ProviderDialects_test.cj:139`）。差异点清单：`Accept-Encoding`（有/无）、`Accept`（都有）、`Authorization`（都有，条件相同）
- **描述**：方言表的设计意图是"只描述差异"，但复制粘贴让"通用头"也进了每个方言。真正的风险不是行数，而是漂移：`LLMStreamTransport.cj:47` 与 `LLMTransport.cj:45` 各自补了 identity，所以流式/非流式暂时都对；但 `StandardDialect`/`DeepSeekDialect` 的 `headers()` 返回值本身不完整，任何未来直接用 `dialect.headers(conf)` 发请求的新代码（例如余额查询、`/models` 探测）都会漏掉 `Accept-Encoding`，在 gzip 响应上踩"把压缩字节当 UTF-8"的老坑（`util/http.cj:23` 的注释正是这个坑）
- **建议**：把 `endpoint` 的通用实现提到 `ProviderDialect` 的默认方法（差异用 `conf.option` 的 path 覆盖已经能表达），`headers` 统一走 `bearerHeaders`，各平台只保留 `decorate` 与"不支持的 kind 抛错"；若要保留手写，至少把 `Accept-Encoding` 补进 `StandardDialect`/`DeepSeekDialect` 并加断言

### [轻微][存量] `ResponsesMapper.build` 与 `ChatCompletionsMapper.build` 的 temperature / stream / tools 三段逐行重复，且 Responses 侧悄悄少字段

- **位置**：`f_llm/src/llm/ResponsesMapper.cj:57-66`（temperature）、`:68-72`（stream）、`:74-89`（tools 空集合分支） ↔ `f_llm/src/llm/ChatCompletionsMapper.cj:40-49`、`:51-55`、`:66-76`
- **来源**：存量（`git blame` → `2026-10-27`，两文件同批）
- **判据**：review-checklist §2（近似重复：一块少了边界/字段）
- **证据**：静态确定 —— temperature 段（`conf.temperature >= 0 ? conf : params` 再按 `< 0` 剔除）逐 token 相同；stream 段相同；tools 段只有"元素形状"不同（Chat 是 `function.toData()` 的嵌套 `function` 对象，Responses 是扁平 `{type,name,description,parameters}`），外层"`size > 0` 就 add 否则 remove"完全相同。差异点：Responses 侧没有 `response_format` 处理，也没有 `max_tokens`（见一般第 1 条）
- **描述**：三段重复本身不难看，但它们承担的是"两条协议必须保持一致的语义"（温度优先级、stream 标志、工具空集合不发）。现在语义已经漂了（一般第 1 条）。下次再有人往 Chat 侧加一个"参数优先级"规则，Responses 侧不会跟着变
- **建议**：把"有效温度计算"抽成 `internal func effectiveTemperature(conf, params): Float64`，stream/tools 的"有则写、无则删"抽成一个 3 行的 helper；两条 `build` 只保留各自的报文骨架（Chat 用 `toData`、Responses 用白名单），并在 `build` 上方用注释列出"本协议缺失的字段"清单

### [轻微][存量] `textOfReasoning` 与 `textOfMessage` 只有字面量不同，是一份实现的两份拷贝

- **位置**：`f_llm/src/llm/ResponsesMapper.cj:131-142`（匹配 `'reasoning_text'`）与 `:144-155`（匹配 `'output_text'`）
- **来源**：存量（`git blame` → `ce62d320ef 2026-10-27`）
- **判据**：review-checklist §2（只改字面量 / 类型名的重复）
- **证据**：静态确定 —— 两个函数体逐行对齐：遍历 `content` 数组 → `asObject()` → `stringOf(item,'type') == <字面量>` → `text.append(stringOf(item,'text'))`，唯一差异是 `'reasoning_text'` vs `'output_text'`
- **描述**：两份实现意味着"content part 的解析规则"有两个真相。加一种 part 类型（例如 `output_refusal`）、或给拼接加分隔符、或改成跳过空串，都得改两处，很容易只改一处
- **建议**：合成 `private static func textOfParts(obj: JsonObject, partType: String): String`，两处分别传字面量；`'reasoning_text'` / `'output_text'` 提成模块内常量（与 `PART_TYPE_IMAGE` 同级）

### [轻微][存量] `DefaultHttpTransport.post` 与 `f_llm.util.http()` 是同一段"建客户端 + identity + TrustAll"的第二份实现

- **位置**：`f_llm/src/llm/LLMTransport.cj:40-53` ↔ `f_llm/src/util/http.cj:18-29`
- **来源**：存量（`git blame` → `d3ebac7923 2026-10-27` / 同期）
- **判据**：review-checklist §2（跨文件复制，且差异没有业务理由）
- **证据**：静态确定 —— 两者都做：`HttpClient(url)` → 逐条 `header` → `client.header('Accept-Encoding','identity')` → `TlsClientConfig()` + `TrustAll` + `tlsConfig` → `resource(client){…}`。差异只有 `http()` 把 `Authorization` / `Content-Type` / `Accept` 固化在助手里，而 transport 走 `dialect.headers(conf)` 传入的 Map
- **描述**：安全策略（TrustAll）与压缩策略（identity）现在有三份拷贝（另见 `LLMStreamTransport.cj:47-50`），严重第 1 条要求"改成可配置"时必须三处同改，漏一处就等于没修。这也是"看起来只改了一行、线上仍然降级"的典型来源
- **建议**：抽一个 `internal func newClient(url: String, headers: HashMap<String,String>): HttpClient`（统一 identity + TLS 策略），`http()`、`DefaultHttpTransport`、`DefaultStreamTransport` 全部改用它；TLS 策略从该工厂一处读配置

### [轻微][存量] `imports.cj` 里的 `UUID` 导入在整包零引用；`A2aCallFunction.cj` 的 `f_log` 导入同样未使用

- **位置**：`f_llm/src/llm/imports.cj:28`（`internal import fountain::f_util.UUID`）、`f_llm/src/loom/A2aCallFunction.cj:25`（`import fountain::f_log.*`）
- **来源**：存量（`git blame` → 2026-10 各批提交）
- **判据**：review-checklist §1（无使用的 import）
- **证据**：静态确定 —— `grep -rn "UUID" f_llm/src/llm` 只命中 `imports.cj:28` 本身；`A2aCallFunction.cj` 内 `LoggerFactory` / `log` 零出现（该文件只用 `FunctionCalling`、`FunctionResult`、`JsonStringSchema`、`@DataAssist`）
- **描述**：`imports.cj` 是包级共享导入文件，一条无用导入会长期留着（没人会去删"公共文件"）。`A2aCallFunction` 的 `f_log` 是复制 `MemoryCallFunction` 时带过来的
- **建议**：删掉这两条。`imports.cj` 里 `fountain::f_bean.*` / `fountain::f_base.*` 是否真被使用无法静态排除（前者可能为 `@Bean` 宏、后者含大量扩展方法），本次只报能确证的 `UUID`

### [轻微][存量] `ResponsesMapper.build` 有 3 处对刚创建的对象做 `remove`，是恒空的无效语句

- **位置**：`f_llm/src/llm/ResponsesMapper.cj:62-63`（`body.remove('temperature')`）、`:71`（`body.remove('stream')`）、`:87`（`body.remove('tools')`）
- **来源**：存量（`git blame` → `2026-10-27`）
- **判据**：review-checklist §1（恒假分支 / 不可达语句）
- **证据**：静态确定 —— `body` 在 `:37` 新建，到 `:62` 只 `add` 过 `model` / `instructions` / `input`，从未写入 `temperature` / `stream` / `tools`；`JsonObject.remove` 对不存在的键是 no-op，所以三个 else 分支永远不起作用
- **描述**：这三处是"从 Chat 侧照搬结构"留下的残骸（Chat 侧的 `body` 来自 `params.toData()`，确实可能有这些键，所以 remove 有意义）。读代码的人会误以为"Responses 报文里可能已经有 temperature/stream/tools 需要清"
- **建议**：直接删掉三个 else 分支（`if(stream){ body.add('stream', true) }` 即可），或加注释说明"本对象是白名单构造，不需要清理"

### [轻微][存量] `DialectRegistry.providers()` 不触发内建注册，首次调用可能返回空列表

- **位置**：`f_llm/src/llm/openai/ProviderDialect.cj:151-159`（`providers()` 直接遍历 `dialects`，未调 `ensureBuiltins()`）↔ `:110-117`（`resolve()` 会调）
- **来源**：存量（`git blame` → `33216a0f12 2026-10-28`）
- **判据**：review-checklist §1（注册了但取不到 / 半成品接线）+ §11（契约与实现不符）
- **证据**：静态确定 —— 内建方言只在 `ensureBuiltins()`（`:125-147`）里写入 `dialects`，`providers()` 没有调用它；因此"进程启动后第一次调用的是 `providers()`"时返回空列表，而 `resolve('deepseek')` 之后同一调用返回 6 个
- **描述**：`providers()` 是公开 API（README `f_llm/README.md:900` 登记），语义应当是"当前可用的 provider 全集"。它对调用顺序敏感，会做出"没有任何 provider"的错误判断（例如管理页下拉框为空、启动自检误报）
- **建议**：`providers()` 首行加 `ensureBuiltins()`；补一条用例：新进程里先调 `providers()` 断言包含 `deepseek`/`zhipu`/`volcengine`/`aliyun`/`siliconflow`/`openai`

### [轻微][存量] `LoomA2a` 先置 `started` 再注册：注册失败或 `reset()` 后重入会留下"已启动但不可达"的状态

- **位置**：`f_llm/src/loom/A2aBridge.cj:91-109`（`:91-96` 置 `started=true` 并释放锁，`:105-106` 在锁外 `server.register()`，`:107-109` 才写 `lastServer`）、`:122-127`（`reset()` 只复位标志、不注销方法）
- **来源**：存量（快照模式无基线）
- **判据**：review-checklist §12.1（检查-然后-写入跨锁、发布逸出）+ §11（资源/状态不对称）
- **证据**：静态确定（并发时序部分为待确认）—— ①置位与注册分属两个临界区，中间的失败（`A2aServer` 构造抛异常）不会被回滚，之后 `startIfEnabled()` 永远命中 `:92-94` 返回 `true`，但 `server()` 是 `None`；②`A2aServer.register()` 内部用 `safeRegister` 吞掉 `JsonRpcException`（`f_a2a/src/server/A2aServer.cj:184-190`），所以 `reset()` 后再 `startIfEnabled()` 会建出第二个 `A2aServer` 并把它的 9 个方法静默注册失败——`started` / `lastServer` 指向新实例，实际处理请求的是旧实例的 handler（任务存在旧实例里，`server()` 却给出新实例）
- **描述**：`reset()` 的注释已声明"不注销已注册的方法"，所以这条是"已知限制"而非意外；但公开 API 的组合（`reset` + `startIfEnabled`）会产生**看着成功、实际不生效**的状态，且只在测试里被用到。真正需要关注的是第一个窗口：如果 `A2aServer` 构造或 `register()` 抛异常，启动流程会得到一个永久"已启用"的假象
- **建议**：把 `started = true` 移到 `register()` 成功之后（失败则复位并重新抛出）；`reset()` 若要保留，改名 `resetForTest()` 并在内部断言仅有测试调用，或干脆去掉 `started` 标志改为"`lastServer.isSome()` 即已启动"

### [轻微][存量] Responses 流式不转发推理增量，与 Chat 流式的 `LLMDeltaKind.Reasoning` 不对称

- **位置**：`f_llm/src/llm/ResponsesStreamAccumulator.cj:50-75`（只处理 `response.output_text.delta` / `completed` / `failed` / `error`）↔ `f_llm/src/llm/ChatStreamAccumulator.cj:90-97`（`reasoning_content` / `reasoning` 都会产出 `LLMDeltaKind.Reasoning`）
- **来源**：存量（快照模式无基线）
- **判据**：review-checklist §11（语义与命名/同族实现不符）
- **证据**：静态确定 —— `feed` 的 match 里没有 `response.reasoning_summary_text.delta` / `response.reasoning_text.delta` 之类分支，`LLMDeltaKind.Reasoning` 在整个文件零出现；最终结果不受影响（`response.completed` 里带 reasoning，`ResponsesMapper.parse` 会挂到 `AssistantMessage.reasoningContent`）
- **描述**：同一个 `respondStream` 回调在 Chat 下能收到思考过程（前端可展示"正在思考"），在 Responses 下全程静默到结束才一次性出现。用户感知是"换了 platform 就没有思考过程"，而这是协议实现差异，不是模型能力差异。顺带：README 的成员清单只登记了 `feed` / `finished` / `isDone`（`f_llm/README.md:1018`），`public func result()` 未登记，一并补
- **建议**：补 `response.reasoning_summary_text.delta` / `response.reasoning_text.delta` 分支，返回 `LLMDelta(LLMDeltaKind.Reasoning, delta)`；若上游事件名不确定，至少在类注释里写明"Responses 流式不转发 reasoning，原因：…"；README 成员清单补 `result`

### [轻微][存量] Responses 解析不填 `usage.cached`，同一份 `TokenUsage` 在两条协议下含义不同

- **位置**：`f_llm/src/llm/ResponsesMapper.cj:121-126`（只取 `input_tokens` / `output_tokens` / `total_tokens`）↔ `f_llm/src/llm/ChatCompletionsMapper.cj:194-201`（额外取 `prompt_tokens_details.cached_tokens`）
- **来源**：存量（`git blame` → 2026-10-27 两文件同批）
- **判据**：review-checklist §2（近似重复：一块少了字段）
- **证据**：静态确定 —— `TokenUsage` 有 `cached` 字段（`ChatCompletionsMapper.cj:199`、`ChatStreamAccumulator.cj:161` 都在写），Responses 的非流式与流式（`ResponsesStreamAccumulator.cj:86-92`）都不写，恒为 0；Responses 协议里的对应字段是 `usage.input_tokens_details.cached_tokens`
- **描述**：按 `usage.cached` 统计"缓存命中省了多少钱"的报表会在 Responses 路径上恒为 0，看起来像"完全没命中缓存"，进而误导 prompt 结构优化。金额口径问题不会报错，只会长期偏差
- **建议**：`ResponsesMapper` 里补 `input_tokens_details.cached_tokens` 的读取；把 `fillUsage` 从 `ChatCompletionsMapper` 提成共享函数，两个协议各自传字段名映射，避免第三次漂移

### [轻微][存量] 测试直接改全局传输/方言注册表且不复位，用例之间会互相污染

- **位置**：`f_llm/src/llm/LLMStream_test.cj:163`、`:186`（`LLM.setStreamTransport(transport)`）、`f_llm/src/llm/LLM_test.cj:78,91,102,117,132`（`LLM.setTransport(...)`）、`f_llm/src/llm/openai/ProviderDialect_test.cj:95,102`（`DialectRegistry.register(...)`）
- **来源**：存量（快照模式无基线）
- **判据**：review-checklist §11（资源不对称 / 隐式全局依赖）
- **证据**：静态确定 —— `LLM.transport` / `streamTransport` 是 `static var`（`LLM.cj:38-39`），测试只写不还原；`DialectRegistry.dialects` 同理（`ProviderDialect.cj:90`）。`ProviderDialect_test.cj:102` 还注册了 `fake-dup`，同一进程内重复执行该用例会变成"第一次 register 就抛"
- **描述**：这些用例单独跑都过，但组合/重跑时会命中别的用例留下的假传输或已注册方言（尤其 `testDuplicateRegisterThrows` 与 `testRegisterAndResolve` 共享 `dialects`）。缺 `@AfterEach` 还原，失败现象会随执行顺序变化
- **建议**：给 `LLM` 加 `internal func resetTransportForTest()`、给 `DialectRegistry` 加 `internal func clearForTest()`，在 `@AfterEach` 里复位；或把 `setTransport` 收窄为接受 `LLMTransport` 的调用级参数

### [轻微][存量] `trimTrailingSlash` 后 base 可能变成空串/相对路径，`conf.url` 缺失时不会在拼端点阶段报错

- **位置**：`f_llm/src/llm/openai/ProviderDialect.cj:79-85`（`trimTrailingSlash`）、`:58-64`（`endpoint` 直接 `base + path`）
- **来源**：存量（`git blame` → `33216a0f12 2026-10-28`）
- **判据**：review-checklist §11（边界 / 空值未处理）
- **证据**：静态确定 —— `LLMConf.url` 默认是 `''`（`model/po/LLMConf.cj:50` 附近），`trimTrailingSlash('')` 返回 `''`，`endpoint` 于是给出 `'/chat/completions'`；`conf.url = '/'` 同样收敛成 `''`。这个字符串会一路传进 `HttpClient(url)`，抛的是 URL 解析层的异常，在 `LLM.call` 里被当成"可重试传输失败"→ 换下一个候选，最终报"no llm candidate available"，掩盖真正原因（配置缺 url）
- **描述**：配置错误与网络错误被归为同一类，运维只能靠翻 provider 名字猜。同类问题还有一条更明确的：`ZhipuDialect/VolcengineDialect/AliyunDialect/SiliconFlowDialect.endpoint` 对 `LLMApiKind.Responses` 抛 `IllegalArgumentException`（`ProviderDialects.cj:43/69/95/131`），而 `endpoint` 的调用点在 `LLM.call` 的 `try` 内（`LLM.cj:145-146`）、`LLM.stream` 的 `try` 内（`LLM.cj:231-233`），异常会被 `catch(e: Exception)` 包成"llm transport failed"并调用 `hooks.onRetryableFailure(conf.id)`——一次「provider 不支持该 API」的配置错误会推高该平台的熔断计数、并浪费一次对其他平台的真实请求，最终异常文案也丢掉了「不支持 responses api」这条唯一有用的信息。`trimTrailingSlash` 本身是 `while + 逐字符切片`，`https://x///` 这种输入会做 O(n²) 的字符串拷贝，但只在启动路径上出现，不构成性能问题
- **建议**：在 `endpoint` 开头校验 `conf.url` 非空且含 `://`，否则抛 `IllegalArgumentException('llm url is empty, provider=…, llm=…')`（不可重试，直接暴露配置错误）；同时把 `dialect.endpoint(...)` / `headers(...)` 移到 `LLM.call`/`LLM.stream` 的 `try` 之外（或在 `catch` 里 `if(e is IllegalArgumentException){ throw }`），让配置错误不计入熔断；`trimTrailingSlash` 改成 `url.trimEnd(c: '/')` 之类的单趟实现

### [轻微][存量] 启发式 token 计数只看 `content`，工具调用参数与多模态 parts 完全不计数

- **位置**：`f_llm/src/llm/TokenCounter.cj:44-50`（`HeuristicTokenCounter.count` 只累加 `message.content`）
- **来源**：存量（快照模式无基线）
- **判据**：review-checklist §11（估算口径与实际报文不符）
- **证据**：静态确定 —— `ChatMessage` 家族的体积不只 `content`：`ToolCallMessage.tool_calls[].function.arguments`（单次可达数十 KB，工具结果上限就配到 64KB，`LLMConfig.cj:196-199`）、`ToolMessage` 的 `content`、`ContentPart.imageUrl`（base64 data URL 可达 MB 级）都不进计数
- **描述**：`HeuristicTokenCounter` 被 `LLMConfsHolder.saturated`（`LLMConfsHolder.cj:139-146`）与 `ContextPrunerMediator`（`ContextPruner.cj:186`）用来判断"上下文是否已到阈值"。工具密集或多图会话里真实 prompt 远大于估算值 → 判定"没饱和"→ 不裁剪 → 上游 400（context_length_exceeded），而熔断计数把它当致命错误直接抛出
- **建议**：计数时把 `tool_calls[].function.{name,arguments}`、`parts[].text`、`parts[].imageUrl` 的长度一并算进去（图片按固定 token 估值或按 base64 长度/4 粗估）；在 `count` 的注释里明确"这是下界估计"，并让 `saturated` 用 `> threshold * 0.9` 之类的安全裕度

### [轻微][存量] 流式归并对非 JSON 的 `data` 没有守卫，空事件会让整条流失败并触发换平台

- **位置**：`f_llm/src/llm/ResponsesStreamAccumulator.cj:49`（`JsonValue.fromStr(data).asObject()`）；同一模式：`f_llm/src/llm/ChatStreamAccumulator.cj:63`（范围外，仅作对照）
- **来源**：存量（`git blame` → `ce62d320ef 2026-10-27`）
- **判据**：review-checklist §11（异常路径未处理）+ §3（兜底把协议噪声变成致命错误）
- **证据**：静态确定（触发条件为待确认）—— `JsonValue.fromStr('')` / 非法 JSON 会抛 `JsonException`（`f_data/src/json/JsonValue.cj:27-80` 的 `asObject` 只在类型不符时抛，`fromStr` 对空串抛解析异常）；而 `SseReader.next()` 只要块里出现过任一字段（包括只有 `event:` / `id:` 的块）就会返回事件，`joinData` 对无 data 的块返回 `''`（`f_httpclient/src/sse/SseReader.cj:90-135`）。`data=''` → `fromStr` 抛 → 异常穿透 `DefaultStreamTransport` 的 `while` → 被 `LLM.stream` 的 `catch(e: Exception)` 当成传输失败 → 换下一个平台（已推送的增量重复）
- **描述**：OpenAI 兼容端点通常只发 `data:`，但 `event:` 前缀块、厂商心跳、代理注入的注释外文本都会命中。一旦命中，本可忽略的一行会变成"整条回答重来一遍"（并且用户已经看到半截输出）。当前所有测试都只喂合法 JSON（`LLMStream_test.cj:27-32`），覆盖不到
- **建议**：`feed` 里先判 `data.trimAscii().isEmpty()` 直接返回 `None`，再用 `try { JsonValue.fromStr } catch { return None }` 跳过非法行（可选记一次 debug 日志计数）；补一条用例：喂 `''`、`'event: ping'`、`'{bad'` 三个事件，断言流继续且 `result()` 正常

### [轻微][存量] `response.failed` 读的是顶层 `message`，而该事件的错误在 `response.error.message`

- **位置**：`f_llm/src/llm/ResponsesStreamAccumulator.cj:62-67`
- **来源**：存量（`git blame` → `ce62d320ef 2026-10-27`）
- **判据**：review-checklist §11（字段路径与协议不符，导致错误信息丢失）
- **证据**：待确认 —— 代码只在顶层取 `stringOf(json,'message')`，取不到就退化成常量 `'response.failed'`；同文件 `case 'error'`（`:68-73`）才是顶层带 `message` 的事件形态。缺的信息：Responses 流式 `response.failed` 事件的真实报文（本地无规范文档，本次也无法联网核对），以及 DeepSeek `/responses` 实测样例
- **描述**：如果 `response.failed` 确实把错误放在 `response.error.{code,message}`，那当前实现永远拿不到上游原文，抛出的异常只剩 `responses stream failed: response.failed` —— 排查"为什么这次没答完"时没有任何线索（对比非流式路径会把 400 的 body 截断 400 字节带进异常，`LLM.cj:155`）
- **建议**：`case 'response.failed'` 时优先读 `json.get('response').asObject().get('error').asObject()` 的 `code`/`message`，取不到再退回顶层 `message`；把成功/失败两种形态都写成 fixture 用例

### [轻微][存量] 模型名「归一」对大小写变体不成立，能力表把 `DeepSeek-Flash` / `Embedding-3` 判成可开关

- **位置**：`f_llm/src/llm/ModelCapabilities.cj:42-48`（`ModelNames.normalize` 的结果直接与常量比较）；根因：`f_llm/src/constant/ModelNames.cj:35-45`（默认分支 `case _ => trimmed` 返回**未小写**的原串，属范围外文件）
- **来源**：存量
- **判据**：review-checklist §11（注释承诺「模型名先归一到框架常量」，在变体上不成立）
- **证据**：静态确定 —— `normalize` 用 `match(trimmed.toAsciiLower())` 匹配，但兜底返回 `trimmed`；`ModelCapabilities.resolve` 用 `== MODEL_NAME_DEEPSEEK_FLASH`（`'deepseek-flash'`，大小写敏感）。故 `'DeepSeek-Flash'` / `'Embedding-3'` 落不进能力表，走 `ThinkingMode.Toggle`
- **描述**：手填配置或聚合平台返回的大小写变体会让「恒思考模型不带 `temperature`」失效 → 报文继续带 `temperature`（被忽略或 400），`embedding-3` 的 `None` 也失效 → 仍可能被塞思考字段。现有用例全用小写或带平台前缀（`ModelCapabilities_test.cj:43-50`、`ModelNames_test.cj:28`），掩盖了裸名变体。
- **建议**：`normalize` 兜底返回 `trimmed.toAsciiLower()`（注释里写清「不改 `conf.actualLlmName` 发出的原值」），或 `resolve` 侧统一小写后再比；补 `'DeepSeek-Flash'` / `'Embedding-3'` 两条断言。

<!-- 第 14 部分 -->

### [严重][存量] `LoomContextLog` 是进程级单例，嵌套与并发执行互相清空、串台，跨流程/跨用户的对话会写进同一条记忆

- **位置**：`f_llm/src/loom/LoomContextLog.cj:52`（`private static var turns`）、`:66-71`（`begin` 无条件重置）、`:92-105`（`snapshot` / `clear`）
- **来源**：存量（`git blame`：`LoomContextLog.cj:66-71` 为 `b597073227` 2026-11-03，`:67` 加锁为 `a45fc16d14` 2026-11-07；`LoomRunner.cj:217/233-234` 同期）
- **判据**：review-checklist §12.1（共享可变状态无隔离 / 可见性与生命周期错配）、§11（契约与实现不符：「生命周期严格绑在一次流程执行上」）
- **证据**：静态确定 —— 状态是 `static`，唯一隔离手段是一把 `Mutex`（只保证单次操作原子，不区分执行实例）；`LoomRunner.runCompiled` 的 `begin()`（`LoomRunner.cj:217`）与 `finally` 里的 `snapshot()+clear()`（`LoomRunner.cj:233-234`）都作用在这份全局状态上，没有任何 per-execution 标识
- **描述**：`begin()` 无条件 `turns = ArrayList()` + `active = true`，`clear()` 无条件 `turns = ArrayList()` + `active = false`。只要有两条执行重叠，就会出现：
  1. B 的 `begin()` 把 A 已累积的轮次清空 → A 结束时的记忆提炼拿到残缺上下文；
  2. B 结束时的 `clear()` 把 `active` 置 `false` → A 其后所有 `LoomHostApi.callLlm`（`LoomHostApi.cj:205` 调 `record`）被静默丢弃，A 的 `snapshot()` 缺尾；
  3. 反向：A 的 `snapshot()` 可能取到 B 写入的 `LlmTurn`，`LoomMemoryExtractor.extract` 以 A 的 `plan.name` 与记忆策略的 `userId` 落库 → **B 的 prompt 与输出被当成 A 的上下文写进 A 的记忆**（内容串台；若 A/B 属于不同用户，就是把他人对话落到本用户名下）。
  4. `LoomRunner.cj:216` 只在 `policy.enabled` 时才 `begin()`，但 `finally` 里的 `snapshot()/clear()` 无条件执行 → 关闭记忆策略的执行会清掉另一条开启策略的执行的状态（第 2 条只是其中一种）。
  并发路径是真实存在的：`LoomService.executeNow`（`LoomService.cj:122-141`）无任何串行化，既被 `LoomExecuteFunction`（`LoomFunctions.cj:126`，工具调用线程）调用，也被 `ScheduleCreateFunction.runFlow`（`ScheduleFunctions.cj:86`，ticktock 线程）调用；`parallel=true` 时 `AsyncFlow` 还会在分叉分支上并发跑步骤。更确定的嵌套路径：`loomExecute` 本身是注册给模型的工具，流程里的 tool 步骤可以调用它 → 内层 `executeNow` 与外层同线程嵌套，`begin()/clear()` 必然互踩，**不需要并发就能触发**。
- **建议**：把 `turns` / `active` 从 `static` 改成「每次执行一个实例」：`LoomRunner.runCompiled` 里 `let ctx = LoomContextLog()`，通过参数或 `ThreadLocal` 传给 `LoomHostApi`（`callLlm` 增加 `ctx` 形参或从当前执行上下文取），删除 `static` 状态；若短期不能改，至少在 `begin()` 里检测 `active` 已为 `true` 就拒绝或退化为「不重置、只标记嵌套层数」，并在 `clear()` 里做引用计数，避免外层被内层关闭。

### [严重][存量] `JitTicktockTask` 的定时单步任务没有宿主可绑，tool/llm 步骤到点必然静默失效

- **位置**：`f_llm/src/loom/JitTicktockTask.cj:37-53`（任务体 `41-52`、吞异常 `48-51`）；依赖点 `f_llm/src/loom/LoomHostApi.cj:147-151`、`f_llm/src/loom/LoomRunner.cj:219/235`；承诺源 `f_llm/README.md:533`
- **来源**：存量（`git blame`：`JitTicktockTask.cj:37-53` 与 `BackgroundTasks.cj` 同批引入于 2026-11-03；`LoomHostApi.bind` 仅 `LoomRunner.cj:219` 一处于 `a45fc16d14` 2026-11-07 补齐）
- **判据**：review-checklist §3（承诺有行为、实际走进空分支）/ §14.1（承诺了但没接线）/ §0「静默失效 = 严重」
- **证据**：静态确定 —— 全仓 `grep -rn "LoomHostApi.bind" f_llm/src` 只命中 `LoomRunner.cj:219`；`LoomHostApi.callTool`/`callLlm` 在 `current == None` 时直接抛 `LoomException('loom host is not bound…')`（`:147-151`、`:200-208`）；`JitTicktockTask.create` 的任务体只构造事件并调用步骤闭包，从不 `bind`，异常被 `catch (error: Exception){ () }` 吞掉
- **描述**：`README.md:533` 写「JIT 步骤在任务里执行时由 `JitTicktockTask` 承接」，`doc/loom.md:186` 又把它列为「方式二：只跑某一步」并给出 `tool` 步骤示例。实际上定时触发时刻没有宿主：凡编译产物里出现 `loomCallTool`/`loomCallLlm`/`loomStore`（tool、mcp、llm 步骤，以及 jit 片段里调用这些桥的写法）都会抛错并被吞，任务表现为「按 cron 跑了但什么都没做」，且日志无痕。若触发时恰有另一条流程在执行，则会借用那条流程的 host（工具/模型的归属与配额记到别人头上）。当前生产链路走 `ScheduleCreateFunction.runFlow` → `executeNow`（跑整条流程，`ScheduleFunctions.cj:66-93`），本类仅测试引用，因此是「按 README 用就会踩空」的缺陷
- **建议**：`create` 接受 `LoomHost`（或任务体内 `LoomServices.currentHost()`）并在 `try` 里 `LoomHostApi.bind(host)` / `finally unbind()`；`catch` 里补 `warn`（`LoomRunner.cj:243-251` 有现成写法）。若确定不做单步调度，删掉本类并把 `README.md:533` 改成「定时任务执行完整流程（`executeNow`）」

### [一般][存量] `CodeGen.stepSource` 与 `LoomCompiler.{jit,tool,llm}SourceOf` 是三份同形源码生成逻辑，预览与真实编译靠注释约束同步

- **位置**：`f_llm/src/loom/CodeGen.cj:70-89`（`stepSource`）与 `f_llm/src/loom/LoomCompiler.cj:77-103`（`jitSourceOf` / `toolSourceOf` / `llmSourceOf`）
- **来源**：存量（`git blame`：`CodeGen.cj:74-75` 为 `0e6df9a3d0` 2026-11-02，`LoomCompiler.cj:91-103` 同期）
- **判据**：review-checklist §2（表现形式不同的重复逻辑 / 字面量复制）、§13（落库原文与实际执行的一致性）
- **证据**：静态确定 —— 三段生成串逐字对齐，只有缩进与注释差异：`'{ args: String =>\n  let ${id}_out = loomCallTool(${jsonQuote(tool)}, args)\n  ${id}_out\n}'` 两处各一份；`loomCallLlm` 同理；`jit` 两处都是 `{ e: Event => … ${id}_result }`。`CodeGen.cj:71` 的注释「与 `LoomCompiler` 实际编译的源码保持同形」正是靠人工约定。更进一步：`flowSource` 的流程组装部分与 f_egraph 现签名也不符——生成的 `flow.registerStart(category:…, tag:…, eventName:…)`（`CodeGen.cj:107-109`）、`flow.registerEnd(category:…, tag:…)`（`:127`）、`flow.get()`（`:129`）三处，而 `Flow.registerStart(eventName: String)` / `registerEnd()` 都不收 `category`/`tag`（`f_egraph/src/base/Flow.cj:23-24`、`AsyncFlow.cj:107/111`），`Flow` 上也没有 `get()`（`get()` 在 `EndExecutorGetter` 上，要用 `start()` 的返回值调），即这段落库源码**不可编译**
- **描述**：`flowSource` / `stepSources` 会落库并作为「可读源码」给开发者审计（`doc/loom.md:507` "流程级没有走 JIT：`CodeGen.flowSource` 只作预览/落库原文"），而真正执行的是 `LoomCompiler` 编译的串。两处任一侧改了字面量（函数名、参数顺序、变量命名），预览与执行就会静默分叉，审计看到的源码不再等于跑的代码——这是排查 loom 问题最难定位的一类偏差。全仓没有任何入口去编译 `flowSource`（只落库/预览/测试字符串断言），所以签名对不上也不会被编译器发现；叠加 `hasAsync` 的派发差异（见下一条），审计者拿到的「源码」在三个维度上都与真实执行不符
- **建议**：删掉 `CodeGen.stepSource` 里的三份模板，改为委托：`jit` → `LoomCompiler.jitSourceOf(step)`、`tool`/`mcp` → `LoomCompiler.toolSourceOf(step)`、`llm` → `LoomCompiler.llmSourceOf(step)`（这三个已是 `public static`，`LoomCompiler` 与 `CodeGen` 同包，无新增依赖）；顺带删掉 `CodeGen.jsonQuote`（`:164-166`）这个纯转发。

### [一般][存量] `StepPlan.async` 只有预览消费者，执行实际按 `plan.parallel` 派发，落库源码里的 `AsyncFlow`/`ImmediateFlow` 与真实执行不一致

- **位置**：`f_llm/src/loom/CodeGen.cj:135-145`（`hasAsync`）、`:96-98`（选 `AsyncFlow`/`ImmediateFlow`）；对照 `f_llm/src/loom/LoomService.cj:140`、`f_llm/src/loom/LoomRunner.cj:222`
- **来源**：存量（`git blame`：`CodeGen.cj:135-145` 为 `f6e7ba515d` 2026-11-01，`LoomService.cj:140` 为 `75f386d77e` 2026-11-07）
- **判据**：review-checklist §1（读了不用的字段 / 死配置字段）、§11（契约与实现不符）
- **证据**：静态确定 —— 全仓 `\.async` 读取点只有 `CodeGen.cj:137/140`；`StepPlan.async`（`Plan.cj:42`）由 `Planner.cj:203-206` 解析、`Plan.cj:241` 序列化进 `planJson`，但执行侧只看 `parallel`（`LoomService.cj:140` 传 `plan.parallel || parallel`，`LoomRunner.cj:222` 据此选 `AsyncFlow`）
- **描述**：默认计划里 `StepPlan.async` 是 `'auto'`，`hasAsync` 对非 `jit` 步骤一律返回 `true` → 预览源码写 `AsyncFlow(...)`；而 `FlowPlan.parallel` 默认 `false` → 实际执行是 `ImmediateFlow`。反之 `parallel=true` 且所有步骤 `async='false'` 时，预览写 `ImmediateFlow` 而实际并发。开发者按落库源码审计「这一步是并发还是串行」会得到错误结论；`async` 这个 schema 字段对执行完全无效。
- **建议**：二选一——(a) 让执行侧也消费 `async`（`LoomRunner` 按 `hasAsync(plan) || plan.parallel` 决定派发），(b) 承认 `async` 只是展示位，把 `hasAsync` 改为读 `plan.parallel`，并在 `planJson` schema 里标注 `async` 为保留字段。任一做法都要同步 `doc/loom.md:494-503` 的三级并发开关描述。

### [一般][存量] `FStoreLoomStore.save` 用 7 次独立写且**先写状态头**，崩溃或并发读会得到「新状态 + 旧源码」，重启后按旧计划执行却标 `compiled`

- **位置**：`f_llm/src/loom/FStoreLoomStore.cj:59-68`（`save`，`:61` 先写 `:h`，`:63-66` 才写 `planJson`/`flowSource`/`stepSources`）
- **来源**：存量（`git blame`：整段为 `f170ea26b9` 2026-11-02）
- **判据**：review-checklist §11（资源/写入顺序与一致性）、§12.1（复合操作非原子）
- **证据**：静态确定 —— `save` 是 7 次 `store.add`（`put` → `FStoreLoomStore.cj:129-132`），无事务、无 batch、无版本号；`f_store` 的 `add` 是逐次 WAL append（`f_store/src/Store.cj:97-107`），单键原子、跨键不原子。`LoomService.confirmFlow`（`LoomService.cj:113-115`）先 `compileSteps` 再 `flow.mark(COMPILED)` 再 `registry.put` → 落库
- **描述**：`save` 的写序让「状态」先于「内容」可见。任一次写失败/进程崩溃/并发读卡在两次 `put` 之间，都会出现 `:h = compiled` 而 `:p`（`planJson`）仍是上一版的情况；`LoomBootstrap.startup` 只按 `status == compiled` 重编译（`LoomRegistry.cj:230`），于是**重启后用旧计划当新版本执行，且状态显示编译成功**。同一进程内 `get()` 也是 6 次独立读（`:70-91`），并发 `save` 时会读到混合快照。
- **建议**：把 `:h` 与 `:index` 的写放到最后（内容 → 状态 → 索引），使「可见即完整」；内容字段合并成一次 `StepSourceCodec` 风格的多字段编码一次写入，或在 `:h` 里存一个内容版本号/校验（写内容后回写 `:h`），`get()` 校验不一致就返回 `None` 并打日志。若改成本更低，至少在 `save` 前后 `store.syncWAL()` 并接受「半新半旧」由启动期校验兜底。

### [一般][存量] `DefaultLoomHost.callTool` 把非字符串的工具结果静默降级成空串，流程拿到 `''` 继续跑

- **位置**：`f_llm/src/loom/DefaultLoomHost.cj:42-49`（`match(result.result as JsonString){ case None => '' }`）
- **来源**：存量（`git blame`：`DefaultLoomHost.cj:42-49` 为 `f484d075d4` 2026-11-01）
- **判据**：review-checklist §11（错误处理缺失 / 成功路径静默吞掉非预期结果）
- **证据**：静态确定 —— `FunctionMediator.call` 返回 `FunctionResult`，其 `result` 是 `JsonValue`；`callTool` 只接受 `JsonString`，其余类型（`JsonObject` / `JsonArray` / `JsonInt`）一律返回 `''`，无日志、无异常、无标记
- **描述**：`loomCallTool` 是每条 tool/mcp 步骤的唯一出口（`LoomJitBridge` 把 `loomCallTool` 绑到 `LoomHostApi.callTool`，最终落到本方法）。工具返回结构化结果时，步骤的 `{id.output}` 变成空串，后续步骤与模型都看到「成功但没数据」，而 `LoomHostApi.taskEvent` 会照常把事件推进下去——失败被伪装成空结果。仓内现有工具基本都返回字符串，因此影响面取决于后续是否接入返回对象的工具，属潜在但无告警的失效路径。
- **建议**：`None` 分支改为序列化整个 `JsonValue`（`result.result.toString()`），或在非字符串时返回显式错误文本 `'[loomCallTool] non-string result: ${name}'` 并 warn；只在 `FunctionResult` 明确表示失败时才回空串，并让调用方（`LoomRunner.bodyOf`）把错误文本当步骤失败处理。

### [一般][存量] `LoomBootstrap.startup` 失败路径上的 `registry.put(flow)` 未做保护，写库失败会中断整个启动，违背「单条失败不影响其它」

- **位置**：`f_llm/src/loom/LoomBootstrap.cj:85-89`（`catch` 内 `flow.mark(FAILED)` + `registry.put(flow)`）
- **来源**：存量（`git blame`：`LoomBootstrap.cj:80-89` 为 `4badb23236` 2026-11-06）
- **判据**：review-checklist §11（错误处理缺失 / 异常路径上的二次失败）、§13（与 `doc/loom.md:643` 承诺相反）
- **证据**：静态确定 —— `registry.put` 在锁外直接 `target.save(flow)`（`LoomRegistry.cj:176-186`），`FStoreLoomStore.save` → `store.add` 会抛（`guardOpen()` / 写失败）；而 `LoomBootstrap.cj:85-89` 的 `catch` 块内部没有任何 `try`，因此 `put` 抛出的异常会穿出 `startup`，`LoomWiring.wire`（`LoomWiring.cj:92`）随之失败
- **描述**：设计承诺是「单条失败只把该条标 `failed`，不影响其它流程」（`doc/loom.md:643`、`LoomBootstrap.cj:38`）。实际上数据库不可写时，第一条坏流程就会让整个 `wire()` 抛错——恰好与「库可能比应用晚就绪，恢复失败不阻断启动」的设计目标相反。另外 `catch (e: Exception)` 的 `e` 未使用，失败原因完全不落地（见轻微项）。
- **建议**：`catch` 内用独立的 `try{ registry.put(flow) }catch(error: Exception){ /* 计数 + warn */ }` 包住，失败只累加 `result.failed` 并记录 `flow.name` 与 `error.message`；`ReloadResult` 增加 `failedNames: ArrayList<String>` 供装配日志输出。

### [一般][存量] 三个演进工厂对未知 `llm_metaStore` / `llm_memoryStore` 静默回落 `f_store`，与同仓 `LoomBootstrap.storeFor` 的「未知取值直接抛错」约定相反

- **位置**：`f_llm/src/loom/EvolutionLeases.cj:39-48`（`case _ => FStoreEvolutionLease()`）、`f_llm/src/loom/EvolutionStores.cj:32-38`、`f_llm/src/loom/EvolutionStateStores.cj:31-37`
- **来源**：存量（`git blame`：`EvolutionLeases.cj:39-48` 为 `ca253ca2a4` 2026-11-04，`EvolutionStores.cj:32-38` 为 `01571db6fd`、`EvolutionStateStores.cj:31-37` 为 `11f5d5f106`，均 2026-11-04）
- **判据**：review-checklist §14.1（接线/配置分发）、§11（配置错误静默降级）；`fountain-baseline.md` §4「多实现与注册冲突：启动时选一个实现，不要静默兜底」
- **证据**：静态确定 —— 三个 `byName` 都是 `match(name){ case 'postgres'… case 'mysql'… case 'memory'… case _ => FStoreXxx() }`，`_` 分支不校验、不抛错；同文件族里的 `LoomBootstrap.storeFor`（`LoomBootstrap.cj:48-63`）对未知值 `throw IllegalStateException('unknown loom store: …')`，`doc/loom.md:526` 也明确写着「未知取值直接抛错并列出可用值，不静默兜底」
- **描述**：把 `llm_metaStore` / `llm_memoryStore` 写成 `postgresql`、`my_sql` 之类时，流程存储会启动失败（`storeFor` 抛错），但演进报告表、演进状态、每日租约三族会**悄悄落到 `f_store` 本地文件**：多进程部署下每台机器各拿一份租约（跨进程互斥失效）、演进状态水位线分叉、演进报告写进本地而非库。这些偏差没有任何报错，只有审计时才发现数据不在库里。
- **建议**：三个 `byName` 统一改成与 `storeFor` 相同的白名单 + 未知值抛 `LoomException('unknown evolution store: …; expected f_store|memory|postgres|mysql')`；`fhydra`/`f_hydra` 这类额外取值在文档里列全。抽一个 `MetaStoreFactory.pick(name)` 返回枚举，避免三份 `match` 各写一遍（同时消掉重复逻辑）。

### [一般][存量] `SkillEvolutionTask.evolve` 绕过 A/B 门禁与「无样例不落库」的演进不变量，直接把模型输出写成新版本

- **位置**：`f_llm/src/loom/BackgroundTasks.cj:57-82`（`:78-80` 构造新 `Skill` 并 `store.upsert`）
- **来源**：存量（`git blame`：`BackgroundTasks.cj:57-82` 为 `75396dc966` 2026-11-03）
- **判据**：review-checklist §11（契约与实现不符）、§14.1（承诺了但实现不同）
- **证据**：静态确定 —— `evolve` 只做「标题非空 → 找到技能 → `chat(prompt)` → 非空就 `upsert(version+1)`」，全程没有 `SkillGate.evaluate`、没有 `skill.functions` 里的 `samples` 校验、没有 `SkillEvolutionLedger` 记录；生产链路的 `SkillEvolutionJob` 则是 `SkillGate` + 冷却期 + 报告留档（`SkillEvolutionJob.cj:426` 处才写版本 +1）
- **描述**：`doc/loom.md:299` 把「A/B 门禁」列为演进流程的必经阶段，`doc/loom.md:310` 明确「**没有样例时不落库**——无据可依的演进会污染技能库」；而 `doc/loom.md:203` / `README.md:1034` 又把 `SkillEvolutionTask.evolve` 当作「技能演进」的公开入口推荐。开发者按文档调用它就得到一个绕过全部质量闸门、且不写演进报告的路径：一次模型幻觉就会把技能正文改坏并 +1 版本，`SkillEvolutionJob` 的冷却期/水位线也不会知道这次变更。当前该 API 全仓仅测试引用（生产走 `SkillEvolutionJob`），所以是「文档诱导的误用面」而非在线故障。
- **建议**：要么把 `evolve` 改成内部实现细节（收窄为 `internal`，README/doc 删掉该入口），要么让它走与 `SkillEvolutionJob` 相同的 `SkillGate` + 样例校验 + 报告落库；同时把 `doc/loom.md:203` 的表述改为「底层工具，生产请用 `SkillEvolutionJob`」。

### [一般][存量] `llm_memoryStore=inMemory` 时演进租约选到 f_store，README 承诺的「租约跟随内容族」不成立

- **位置**：`f_llm/src/loom/EvolutionLeases.cj:39-48`（`case 'memory'` + `case _ => FStoreEvolutionLease()`）；对照 `f_llm/src/loom/LoomBootstrap.cj:59`、`f_llm/README.md:764`、`:239`、`f_llm/src/store/InMemoryStores.cj:84`
- **来源**：存量（`git blame`：`EvolutionLeases.cj:39-48` 为 `ca253ca2a4` 2026-11-04）
- **判据**：review-checklist §14.1（配置项未生效 / 接线缺失）、§13（与 README 承诺相反）
- **证据**：静态确定 —— `byName` 先 `trimAscii().toAsciiLower()`，文档值 `inMemory` 变成 `'inmemory'`，match 只列 `'memory'`，于是落到 `_ => FStoreEvolutionLease()`（文件存储）；而内容族的 Bean 条件认的正是 `StringCond.Exactly('inMemory')`（`InMemoryStores.cj:84`），`README.md:764` 写明「`llm_memoryStore` … 内容族 + **租约**：`f_hydra`/`fhydra`/`postgres`/`mysql`/`inMemory`」，`:239` 同。对照组 `LoomBootstrap.storeFor`（`LoomBootstrap.cj:59`）认 `'memory' || 'inmemory'`，三处别名处理不一致
- **描述**：按文档配 `inMemory`（本地演示/单测常见取值）时，记忆在内存、每日租约写在 `./data/f_llm-meta` 的文件里：重启后内存清空但租约还在，技能演进被「上次刚演进过」的冷却判断挡住；多副本部署时每台机器各持一份租约（与 G6 的后果相同，但触发值是文档明确列出的，不需要用户写错）
- **建议**：`EvolutionLeases.byName` 增加 `case 'inmemory'`（与 `storeFor` 共用同一套别名归一，可与 G6 的「统一工厂」一并进行）；补一条 `byName('inMemory') is InMemoryEvolutionLease` 的单测

<!-- 第 15 部分 -->

### [严重][存量] #1 一次执行的全部上下文都是进程级静态量，`bind`/`unbind` 不校验归属，两个流程并发即互相清空步骤输出、串人格/技能、串记忆归属

- **位置**：
  - `f_llm/src/loom/LoomHostApi.cj:46-49`（`mutex` / `current` / `values` 均为 `private static`）、`:54-59`（`bind` 重建 `values`）、`:61-66`（`unbind` 清空）、`:147-152`（`callTool` 无锁读 `current`）、`:181-209`（`callLlm` 无锁读 `current`，并读 `personaText` / `skillText`）、`:212`、`:235`（`personaText` / `skillText` 静态）、`:262-267`（`taskEvent` 以步骤名写 `values`，不带 flow/tag）
  - `f_llm/src/loom/LoomRunner.cj:216-219`（`LoomContextLog.begin()` 与 `LoomHostApi.bind(host)`）、`:231-237`（`finally` 里 `snapshot` / `clear` / `unbind` / `clearPersona` / `clearSkills`）
  - `f_llm/src/loom/LoomContextLog.cj:51-53`（`turns` / `active` 静态，范围外文件，取证用）
- **来源**：存量（`git blame`：`LoomHostApi.cj:54-58` 为 `182d8196d2 2026-11-02`，`:55` 的 `synchronized` 为 `449f47ac1a 2026-11-07`；`LoomRunner.cj:216-237` 为 `3f87c56345 2026-11-02`）
- **判据**：review-checklist §12.1「共享可变状态无保护 / 发布逸出 / 可见性」；§11「并发正确性」
- **证据**：静态确定 —— ① `current` / `values` / `personaText` / `skillText` / `turns` 都是 `private static var`，而 `runCompiled` 每次执行都会 `bind`（重建 `values`）→ 执行 → `unbind` + `clear`，作用域是**进程**而非一次执行，全程没有任何"整轮执行"的锁（`mutex` 只保护单次读写）；② `callTool`（`:148`）与 `callLlm`（`:200`）读 `current` **完全不加锁**，与 `bind`/`unbind` 的锁内写构成 data race——同文件里 `callStore`（`:170-178`）、`currentPersonaText`（`:226-232`）反而都规规矩矩用 `synchronized` 拷贝，说明这两处是遗漏而非设计；③ 入口不唯一：`LoomFunctions.cj:126`（工具调用）、`LoomService.cj:140`（`executeNow` → `LoomRunner.run`）、范围外的 `ScheduleFunctions.cj:86`（定时任务）、`Supervisor.cj:194/227`（路由派发）、`LoomAgent.cj:130`（`runCompiled`）都直达同一条执行链，仓内不存在串行化它们的锁。
- **描述**：`bind` 把 `values` 换成新表、`unbind` 清 `current`、`clearPersona` / `clearSkills` 抹掉人格与技能、`LoomContextLog.begin/clear` 重置临时上下文。A、B 两个流程并发时：B 的 `bind` 清空 A 已产出的步骤输出，A 后续 `{step.output}` 按"未命中保留原样"（`LoomHostApi.cj:71` 的注释语义）把字面量 `{fetch.output}` 送进模型；B 的 `unbind` 让 A 的 `callTool` / `callLlm` 抛 `loom host is not bound`；`personaText` / `skillText` 被对方覆盖 ⇒ A 的 system 里混进 B 的人格与技能正文（跨租户提示词泄漏）；`LoomContextLog` 的快照被先结束的一方整体取走 ⇒ `LoomMemoryExtractor` 把别人的对话写进自己的记忆/知识（`docId` 前缀只带 `userId/namespace`，写错不可自愈）。`LoomHostApi.cj:22-30` 写着"约束：单线程使用"，但该注释贴在 `class TextBox`（`:32`）上方，`LoomHostApi` 类本身没有注释，这条"约束"既不可发现、也没有任何运行期校验。
- **建议**：把"一次执行的上下文"从静态量改成执行期对象（`host` / `values` / `persona` / `skills` / `turns` / `tag`），由 `runCompiled` 创建并沿闭包传参（`LoomJitBridge` 的 `PredefinedFunction` 闭包已可直接捕获，不必改 JIT 源码签名）；静态入口只作兜底，并加一把"进程内只允许一个流程在跑"的锁（`tryLock` 失败直接抛可读异常），把单流程串行从注释变成强制约束。最低限度：`values` 的键带上 `LoomRunner.cj:137` 的 `tag`；`unbind` 前校验 `current` 仍是自己 `bind` 的 host（ABA 保护）；`callTool` / `callLlm` 取 `current` 走锁内拷贝。补并发用例：两个 `runCompiled` 并行、步骤内 `sleep`，断言两边 `{step.output}` 都命中且 system 不串。

### [严重][存量] #2 `parallel=true` 时步骤抛异常：`waiter.get()` 无超时永久阻塞，异常无痕、流程资源不释放

- **位置**：`f_llm/src/loom/LoomRunner.cj:301-311`（`302-305` `flow.start(...)`、`307` `waiter.get()`、`308-310` `finally { release(flow) }`）；语义判据在 `f_egraph/src/base/AsyncDispatcher.cj:75-86`（`get()` 里 `endCondition.wait()` 无超时）、`:116-121`（`asyncExecute` 在 `spawn` 里直接 `executor.accept`，异常不回收）、`:108-115`（End 只由 `notifyEnd` 通知）、`:138-148`（`DummyEvent` 直接 `continue`）
- **来源**：存量（`git blame`：`LoomRunner.cj:300-311` 为 `3f87c56345 2026-11-02`，`try` 包装为 `8633ab3a6e 2026-11-06`）
- **判据**：review-checklist §12.1「异步语义：Future 异常被吞、超时但任务继续跑」；§11「资源不对称 / 错误处理静默」
- **证据**：静态确定 —— `AsyncEndExecutorGetter.get()` 的唯一实现是 `AsyncDispatcher.get()`，等待条件变量且**没有超时参数**（只有 `tryGet(timeout:)` 才有）；End 事件只由 sink 步骤返回的 `EventType.End` 触发 `notifyEnd`。步骤闭包在 `asyncExecute` 的 `spawn` 里执行，抛异常时既不会产生 End 事件，也没有 `registerError` / 错误通道，`waiter.get()` 就没有唤醒源。
- **描述**：`parallel=true` 是 `plan.parallel` 或调用参数显式开启的正常模式（`LoomService.cj:140`）。任意步骤（工具超时、`loomCallLlm` 报错、JIT 片段抛错）抛出后，执行线程永久停在 `waiter.get()`：调用方（LLM 工具请求线程、定时任务线程）被永久占用，`finally` 也永远不会执行（`release(flow)`、`unbind`、`clearPersona`、记忆提炼全部跳过）；同进程后续流程还会命中 #1 的静态量污染。异常本身没有日志，现场只剩线程栈。
- **建议**：改用 `waiter.tryGet(timeout: <执行上限>)`（`AsyncEndExecutorGetter` 已提供），超时抛 `LoomException('loom flow timed out: ${plan.name}')`；步骤侧（`LoomRunner.cj:334-365` 的 `bodyOf`）把 `compiled(e)` 包一层 `try/catch`，转成 error 日志 + 主动 emit `End` 收尾，保证 End 必定触发；`release` / 解绑逻辑保持在 `finally`（现在因为永远到不了 `finally` 而形同虚设，超时路径要确保走到）。补用例：并行计划里让一个步骤抛异常，断言在超时内返回错误而不是挂住。

### [严重][存量] #3 多根 / 不可达步骤的计划：只把 `order[0]` 注册为 start，其余根永不触发；若它们是汇聚点的前驱，并行模式永远等不齐（挂起），同步模式静默少跑步骤

- **位置**：`f_llm/src/loom/LoomRunner.cj:264`（`flow.registerStart(order[0])`）、`:296`（异步同）、`:121-125`（`run` 只校验非空步骤）、`:526-563`（`topologicalOrder` 对多根无提示）；根数/可达性校验缺失处：`f_llm/src/loom/Plan.cj:94-141`（`validate` 只查 id 重复、边端点、自环、kind）
- **来源**：存量（`git blame`：`registerStart(order[0])` 与异步同段为 `3f87c56345 2026-11-02`；快照模式无基线）
- **判据**：review-checklist §11「边界 / 契约与实现不符」；§12.1「条件等待：等待超时后状态未处理」
- **证据**：静态确定 —— `validate()` 不检查"入度为 0 的步骤数"，`topologicalOrder` 会把所有根都放进 `order`，但 `registerStart` 只登记 `order[0]` 一个事件名；`JoinBarrier.release`（`:76-94`）对 `need > 1` 的节点必须凑满 `expected` 次才放行，未到达的分支不会被补偿；`AsyncDispatcher` 对 `DummyEvent` 直接 `continue`（`AsyncDispatcher.cj:142`），因此凑不满的汇聚点不会产出 End。
- **描述**：`Planner` 产出的计划只有"步骤 + 边"，没有任何"必须单根"的约束或提示。计划形如 `a`、`b` 两个根且 `a→d`、`b→d`（`d` 入度 2）时：同步模式 `start(a)` 跑完 a、把事件交给 d、屏障计数 1/2 → 吞掉，b 从未执行，`runSync` 正常返回、`record` 里是 a 的输出（调用方看到"成功"，实际只跑了半个流程）；并行模式 End 永不触发 ⇒ 命中 #2 的永久阻塞。语义上 `FlowPlan.validate` 已经拒绝了 `http` 这类未实现的 kind，说明"拒绝跑不了的形状"是该项目既有的处理原则，多根属于同类漏检。
- **建议**：二选一——(a) `validate()` 增加"恰好一个入度为 0 的步骤，且所有步骤从它可达"的检查，不满足直接抛 `LoomException`（配合 Planner 提示词约束）；(b) 支持多根：把所有根都 `registerStart`，并在 `start` 时对每个根各投一次起始事件（`AsyncFlow` / `ImmediateFlow` 都支持多 start 名，`registerTask` 的"首个任务必须同名"校验可逐根满足）。无论哪种，都要为 `JoinBarrier` 加超时兜底，避免"少一个前驱"变成永久等待。

### [一般][存量] #4 `LoomExecuteParam.dryRun` 承诺"只预览不编译"，但从未接线：模型传 `dryRun=false` 仍然只预览

- **位置**：`f_llm/src/loom/LoomFunctions.cj:71-72`（`@JsonStringSchema[description:'"true" 时只预览不编译（默认）；预览返回计划与闭包原文'] private var dryRun`）、`:110-121`（`confirm=false` 分支构造 `LoomRequest` 时未传 `dryRun`）；`LoomRequest.dryRun` 在 `f_llm/src/loom/Planner.cj:35/46/60` 只被赋值，`Planner.plan` 无读取点
- **来源**：存量（`git blame`：`LoomFunctions.cj:118-120` 为 `716e648239 2026-11-01`）
- **判据**：review-checklist §1「读了不用（配置项 / 字段赋给局部变量后再无使用）」；§14.1「配置项被读取却从未使用」
- **证据**：静态确定 —— 全仓 `grep dryRun` 只有 4 处：本例字段声明、`Planner.cj` 的 `LoomRequest.dryRun` 声明/赋值、`Supervisor.cj:212` 显式传 `dryRun: false`；`LoomExecuteFunction.call` 里没有任何地方读 `params.dryRun`（`@DataAssist[props fields]` 生成的 prop 也无人读）。
- **描述**：`LoomExecuteParam` 是给模型看的 JSON schema，`dryRun` 的描述明确写了"true 时只预览不编译（默认）"，暗示 `false` 会编译。实际 `call()` 只按 `confirm` 分支，`dryRun` 被静默丢弃：模型按 schema 传 `dryRun=false` 期望编译，得到的是"pending + 源码预览"，而工具返回里没有"该参数被忽略"的提示，模型会误判流程已就绪。
- **建议**：要么把 `dryRun` 接入（`confirm=false && dryRun=false` → 直接 `confirmFlow`，或把它传进 `LoomRequest` 并让 `Planner` / `CodeGen` 消费），要么从 schema 删除该字段并把 description 改为只讲 `confirm`；`LoomRequest.dryRun` 若确实无人消费，也一并处理（它在范围外的 `Planner.cj`，本报告只提示）。

### [一般][存量] #5 `memory.list` 多 kind 分页：每个 kind 各取 `offset+limit` 再拼接，单页可返回 2×limit，分页契约被破坏

- **位置**：`f_llm/src/loom/LoomStoreGateway.cj:147-174`（`149` `kindsOf`、`150-151` `offset` / `limit`、`157-161` 每个 kind 各调一次 `listByKind(userId, ns, kind, offset, limit)`、`162` `merged`）；`kindsOf` 的默认双 kind 见 `:384-400`（`experience` → `experience` + `experience_failed`）
- **来源**：存量（快照模式无基线）
- **判据**：review-checklist §11「契约与实现不符」；§6.4「同一输入重复取数」
- **证据**：静态确定 —— `wanted` 有 2 个元素时循环执行两次 `listByKind(..., offset, limit)`，`merged` 最多 `2 × limit` 条；`offset` 分别作用在每个 kind 上，而不是作用在合并结果上。KDoc（`:34`）承诺的是 `memory.list {"userId","namespace","offset","limit"}` → 记录数组，未说明"每 kind 各自分页"。
- **描述**：`experience` 走默认双 kind 时，`limit=50` 的"一页"实际最多返回 100 条；调用方按 `offset += limit` 翻页时，页边界不再对应合并序（每个 kind 各自从自己的 offset 起算），合并结果按 kind 分组（先全部 `experience` 再全部 `experience_failed`）也不是时间序。流程里若把 `{list.output}` 拼进上下文，会把两倍的记录塞进模型输入。
- **建议**：分页口径二选一并写进 KDoc：① 单 kind 单页（`kind` 必填，缺省报错），② 合并后在网关内排序再按 `offset/limit` 切（需要 Store 提供 `listByKinds`，或先取全量——只在上限可控时可行）。当前实现至少要把 `listByKind` 的 `limit` 改成 `offset + limit` 后合并切片，并补一条"2 个 kind、limit=10、翻三页无重复无遗漏"的用例。

### [一般][存量] #6 `skill.upsert` 主键分配是 check-then-write：并发 upsert 撞同一个 id，后者静默覆盖前者

- **位置**：`f_llm/src/loom/LoomStoreGateway.cj:249-272`（`251-260` 全量 `meta.skills.list()` 求 `maxId` 后 `targetId = maxId + 1`、`:262-271` `upsert`）；并发入口：`f_llm/src/loom/StoreFunctions.cj:85-92`（工具层直接 `gateway.call`）、`LoomJitBridge.cj:50-54`（JIT 步骤的 `loomStore`）
- **来源**：存量（快照模式无基线）
- **判据**：review-checklist §12.1「检查-然后-写入」（容器线程安全不代表组合操作原子）；§11「并发正确性」
- **证据**：静态确定 —— `list()` 与 `upsert()` 之间没有任何锁或版本校验，"读 max → +1 → 写"是典型的非原子组合操作；`SkillCatalog` / `SkillEvolutionJob`（范围外）与流程内的 `loomStore('skill','upsert',…)` 是同一条链路。
- **描述**：两个请求同时新建技能（`id<=0`）时拿到同一个 `maxId+1`，第二个 `upsert` 覆盖第一个：技能正文、`functions`、`version` 一起丢失，且没有任何报错。技能演进是后台任务（会写 `upsert`），与前台工具调用天然并发。
- **建议**：把 id 分配下沉到 Store（`skills.nextId()` / 自增列 / `upsert` 返回分配结果并在存储侧保证唯一），或在网关内用一把 `Mutex` 包住"读 max + 写"（技能写入频率低，粗锁可接受，但要在注释里写明原因）。同时把 `count`（`:218-220` 的 `list().size`）换成 Store 的计数接口。

### [一般][存量] #7 `intOf` 把"缺字段 / 非法值"一律折成 0：`userId=0` 的记忆写进共享桶、`remove(id=0)` 静默失败、`evolution.list` 不传 limit 返回空

- **位置**：`f_llm/src/loom/LoomStoreGateway.cj:420-434`（`424` `value.toString()`、`425-430` Int64→Float64→`0`、`:432` 缺键 `0`）；使用点 `:134`（`userId`）、`:142/210`（`id`）、`:150-151`（`offset/limit`）、`:182`（`topK`）、`:346`（`evolution.list` 的 `limit`）；对照 `:402-410`（`pageOf` 对 `knowledge`/`memory` 做了默认值兜底，`evolution` 没有）
- **来源**：存量（快照模式无基线）
- **判据**：review-checklist §11「空集合 / 空串 / `None` 未处理」「错误处理缺失或静默」
- **证据**：静态确定 —— `intOf` 的失败路径直接返回 `0`，调用方没有任何 `isNone` 判别；`memory.add` 用 `userId` 直接构造 `MemoryWrite`（`:137-139`），网关不校验 `userId > 0`；`evolution` 分支（`:345-355`）没有走 `pageOf`。
- **描述**：模型漏写 `userId` 时，记忆被写进 `userId=0` 的公共命名空间（多租户串数据，且后续按真实 userId 检索不到）；`memory.remove` 漏 `id` 时删的是 0 号记录并返回 `false`，调用方无法区分"不存在"和"参数错"；`evolution.list` 不传 `limit` 时 `limit=0` → 返回 `[]`，与"缺字段按默认 50"（`pageOf` 的注释）不一致。
- **建议**：`intOf` 换成 `?Int64`，必填键（`userId`、`id`、`docId`）缺失即抛 `LoomException('loom store gateway: <kind>.<op> requires <key>')`；可选键统一走 `pageOf` 风格的默认值；`evolution.list` 复用 `pageOf`。补用例：缺 `userId` 的 `memory.add` 必须报错而不是写 0 号桶。

### [一般][存量] #8 注册表内存态与持久化非原子：`put` 先改内存再 `save`、`remove` 先删内存再删库，任一步抛错就分叉

- **位置**：`f_llm/src/loom/LoomRegistry.cj:175-183`（`put`：`176-178` 写 `flows`、`179-182` `store.save`）、`:193-208`（`remove`：`195-200` 删内存、`201-206` `store.remove`，返回值被丢弃）、`:241-266`（`restore` 只做合并、不清理旧值）
- **来源**：存量（快照模式无基线）
- **判据**：review-checklist §11「资源不对称 / 错误处理缺失」；§12.1「有界性与一致性」
- **证据**：静态确定 —— `put` 的两步不在同一个事务/补偿逻辑里，`store.save` 抛异常时内存已更新；`remove` 同理，且 `target.remove(name)` 的 `Bool` 被忽略（存储侧没删掉也算成功）。
- **描述**：`store.save` 失败（DB 断连、约束冲突）时，`LoomService.execute` 抛出异常并告诉模型"失败"，但注册表里已经有了这条 `pending` 流程——本进程内可见、重启后消失，行为随进程重启而变。`remove` 失败时更危险：内存删了、`Supervisor.untap` 摘了路由（`LoomService.cj:143-148`），但库里还留着 `compiled` 记录，重启 `restore()` 后流程复活且没有路由。
- **建议**：先落库再改内存（`save` 成功才 `flows[name] = flow`），失败直接抛出，保证"内存是库的缓存"；`remove` 先删库、成功后删内存；`restore` 改为"清空后重建"并在 KDoc 注明"仅启动期调用一次"，避免运行期调用把旧流程混进来。

### [一般][存量] #9 `LoomRegistry.get` / `compiledFlows` 把内部可变 `LoomFlow` 直接交出去：调用方在锁外读改写，`status` 无同步

- **位置**：`f_llm/src/loom/LoomRegistry.cj:185-191`（`get` 锁内取引用、锁外原样返回）、`:219-238`（`compiledFlows` 把同一批引用装进结果）、`:102-114`（`MemoryLoomStore.get` 同样返回内部引用）；使用点 `f_llm/src/loom/LoomService.cj:107-118`（`flow.mark(COMPILED)` + `registry.put(flow)`）、`:124-140`、`:150-154`（`status()` 读 `flow.status`）
- **来源**：存量（快照模式无基线）
- **判据**：review-checklist §12.1「发布逸出 / 迭代与修改并发」；§11「并发正确性」
- **证据**：静态确定 —— `LoomFlow` 的 `status` / `stepSources` / `planJson` 都是 `public var`，注册表的锁只保护 `HashMap` 本身；`confirmFlow` 的"取 → 编译 → `mark` → `put`"整段在锁外，`status()` 在另一线程读同一个 `String` 字段。两个并发 `confirmFlow` 会对同一实例各编译一遍、各自 `mark` + `put`，`status()` 可能读到编译前后的中间态。
- **描述**：这是"锁保护了容器却保护不住容器里的对象"的典型形态。除并发外还有语义问题：任何持有 `get()` 结果的调用方（工具层、`Supervisor`、测试）都能改 `status` / `description` 而绕过 `mark()` 的合法性校验（`LoomFlow.mark` 才是唯一校验点）。
- **建议**：`LoomFlow` 改成不可变 + 显式状态迁移（`withStatus(next)` 返回新实例，注册表在锁内替换），或 `get()` 返回快照（拷贝 `stepSources` 等可变容器）；`confirmFlow` 的整段状态迁移放进注册表提供的 `update(name) { flow => ... }` 原子操作里。至少要把 `LoomFlow` 的字段收窄为 `public let` + 受控 `mark`。

### [一般][存量] #10 `LoomService.execute` 同名直接覆盖：已编译流程被一次预览静默替换，源码与状态一起丢

- **位置**：`f_llm/src/loom/LoomService.cj:71-103`（`77` / `90` 直接 `LoomFlow(request.name, …)`、`83` / `98` `registry.put(flow)`）；`f_llm/src/loom/LoomRegistry.cj:175-183`（`put` 是覆盖语义、无 `contains` 检查）；`f_llm/src/loom/LoomFunctions.cj:61`（`name` 仅由模型填写）
- **来源**：存量（快照模式无基线）
- **判据**：review-checklist §11「契约与实现不符」；fountain-baseline §4「同名注册：启动直接失败，不做隐式优先级」
- **证据**：静态确定 —— `put` 无条件赋值；`execute` 不查 `registry.get(name)`，也不比较 `round` / 描述。`name` 是 LLM 从自然语言里生成的字符串（`LoomExecuteParam.name` 的描述只有"流程标识，全局唯一"），重名成本极低。
- **描述**：模型重复调用 `loomExecute`（重试、同一任务换个说法）时，已 `compiled` 的流程被新 `pending` 覆盖：旧 `stepSources` 丢失、`Supervisor.tap` 把路由状态改回 `pending`，正在跑的实例不受影响但新派发会按 `pending` 处理（`Supervisor.cj:116-124` 只转 status，具体分支待确认）。表现为"昨天能跑的流程今天说没编译"。
- **建议**：`execute` 在 `name` 已存在且状态为 `compiled` 时拒绝覆盖（抛 `LoomException('loom flow already compiled: ${name}')`）或要求显式 `force` 参数；`pending` 覆盖时保留旧 `round` 并在返回里说明"已替换"。`LoomRegistry.put` 提供 `putIfAbsent` / `replace(name, expectedStatus: …)` 供调用方选择语义。

### [一般][存量] #11 `LoomStoreGateway` 的 op 契约表与实现不符：表头写"未列出的 op 一律抛 `LoomException`"，实际支持 5 类未列出的能力

- **位置**：`f_llm/src/loom/LoomStoreGateway.cj:25-44`（KDoc 表 + `43` 的"未列出的 op 一律抛"）、实现 `:214-273`（`skill.load` / `skill.upsert`）、`:275-319`（`prompt.get/latest/put/remove`）、`:321-337`（`character.get/set/reset`）、`:339-356`（`evolution.list/by_skill`）；实际调用方 `f_llm/src/loom/LoomRunner.cj:389`（`prompt.latest`）、`:428`（`character.get`）、`:473`（`skill.load`）
- **来源**：存量（快照模式无基线）
- **判据**：review-checklist §13「API / 配置 / 默认值与源码不符」；§14.2「公开 API 未文档化」
- **证据**：静态确定 —— 表里只有 `knowledge` / `memory` / `skill`（`get/list/count/remove`）/ `experience`；`prompt`、`character`、`evolution` 三类和 `skill.load/upsert` 在实现里都有，`LoomRunner` 自己也依赖 `prompt.latest` / `character.get` / `skill.load`。
- **描述**：网关是 `loomStore` 与 `StoreFunctions` 的唯一入口，KDoc 表是模型和开发者写 JIT 片段时的唯一参考。按表理解，"未列出的 op 一律抛"意味着 `prompt.latest` 不可用，而实际上这条路径是人格解析的主链路（`LoomRunner.resolvePersona`）。反过来，`character.set/reset`、`prompt.put/remove` 这些会改数据的 op 没有任何文档说明权限与副作用。
- **建议**：补齐 KDoc 表（含 `skill.load` 的 `title` 键、`skill.upsert` 的 id 分配规则、`prompt.put` 的版本递增、`character` / `evolution` 全量 op），并把"未列出的 op 抛错"改成"未列出的 op 抛错（当前实现见下表）"避免自相矛盾；`evolution` 只读这一点值得写进表里（`:344` 的注释已说明理由）。

### [一般][存量] #12 注册表 `flows` 只增不删：每次 `loomExecute` 落一条含 `planJson` + `stepSources` 的记录，无 TTL / 上限

- **位置**：`f_llm/src/loom/LoomRegistry.cj:167-168`（`flows` 普通 `HashMap`）、`:175-183`（只 `flows[flow.name] = flow`）、`:193-208`（只有显式 `remove` 才减）；写入驱动 `f_llm/src/loom/LoomService.cj:83/98/115`；删除入口只有 `LoomFunctions.cj:191` 的 `loomDelete`（需要模型主动调用）
- **来源**：存量（快照模式无基线）
- **判据**：review-checklist §5「无界容器：全局 `HashMap` 随请求增长，GC 后条目仍在」
- **证据**：静态确定（增长无界）；量级需实测 —— 单条 `LoomFlow` 持有 `planJson`（每步 1 段 JSON）+ `stepSources`（每步一段源码）+ `description` / `tools` / `mcps`，按 5 步流程估 3~8 KB；10 万条即 300~800 MB，且没有淘汰路径（`clear()` 语义不适用）。增长速率取决于调用量与 `name` 的唯一性。
- **描述**：`clarifying` / `pending` 流程是"半成品"，正常业务里被 `compiled` 覆盖或删除，但失败、放弃、模型换名字重试都会留下死记录；`compiled` 流程也只在显式 `loomDelete` 时才释放。长跑进程（fboot 常驻）里这是一条线性增长的堆占用，且 `restore()` 每次重启还会把库里的全量读回内存。
- **建议**：给注册表加有界策略——按 `status` 分桶：`clarifying/pending` 设 TTL（例如 24h 未确认即清理），`compiled` 设条数上限（LRU 或按 `lastUsed`）并落库保留；`restore()` 只加载 `compiled`（`pending` 源码已无意义）。补一条 10 万条 `put` 后的 `usedHeap` 对照，作为"是否真的需要上限"的判据。

### [轻微][存量] #13 死代码：`release(Flow<EndExecutorGetter>)` 空重载无调用者、`LoomMemoryPolicy` 未使用的 `f_log` 导入、`buildCount` 仅测试可见

- **位置**：
  - `f_llm/src/loom/LoomRunner.cj:313-315`（`private static func release(flow: Flow<EndExecutorGetter>): Unit { () }`）
  - `f_llm/src/loom/LoomMemoryPolicy.cj:22`（`import fountain::f_log.*`，全文件无 `Logger` / `LoggerFactory` 使用）
  - `f_llm/src/loom/LoomStoreGateway.cj:46-51`（`static var buildCount` + `static func resetBuildCount`，`:61/69` 自增）
- **来源**：存量（快照模式无基线）
- **判据**：review-checklist §1「无调用者 / 未使用的 import / 仅测试使用」
- **证据**：静态确定 —— `release(` 在 `LoomRunner.cj` 只有 `:275`（`ImmediateFlow`）与 `:309`（`AsyncFlow`）两个调用点，均精确匹配到同名具体重载，泛型重载零调用；`buildCount` / `resetBuildCount` 全仓只在 `LoomStoreGateway_test.cj:119-123`、`LoomWiringGateway_test.cj:43-61` 出现。
- **描述**：泛型 `release` 不仅没人调用，还是**空实现**——与另外两个真正 `flow.remove()` 的重载放在一起，读者会以为"泛型路径故意不释放"，实际只是重载解析不到的历史残留。`f_log` 导入让读者以为该文件会打日志（它的 `catch` 分支全是静默 `()`）。`buildCount` 是包内可见的测试计数，两个构造函数无条件自增，本身无锁（测试单线程时无碍）。
- **建议**：删除泛型 `release` 重载（或合并成一个接收 `BaseFlow` 的实现，因为 `remove()` 在 `BaseFlow` 上就有）；删 `f_log` 导入；`buildCount` 改名 `testBuildCount` 并在 KDoc 注明"仅测试"，或改为返回给测试的可选计数器。

### [轻微][存量] #14 重复逻辑：三份 `fieldOf/strOf`、三份 `Any→String`（语义已漂移）、两个逐行相同的 `release`、`execute` 两个分支的装配代码

- **位置**：
  - JSON 取字符串：`f_llm/src/loom/LoomMemoryPolicy.cj:241-249`、`f_llm/src/loom/LoomRunner.cj:492-500`、`f_llm/src/loom/LoomStoreGateway.cj:369-377`（后者名 `strOf`）
  - `Any→String`：`f_llm/src/loom/LoomHostApi.cj:278-286`（`String` + `Int64`）、`f_llm/src/loom/LoomRunner.cj:460-466`（只认 `String`）、`f_llm/src/loom/LoomJitBridge.cj:57-65`（只认 `String` + 下标保护）
  - 释放流程：`f_llm/src/loom/LoomRunner.cj:317-323` 与 `:325-331`（仅参数类型不同）
  - 流程装配：`f_llm/src/loom/LoomService.cj:77-86` 与 `:90-102`（`round` / `tools` / `mcps` / `put` / `Supervisor.tap` 各写一遍）
  - 手写 JSON 数组：`LoomStoreGateway.cj:119-129`、`:164-173`、`:192-207`、`:228-238`、`:451-466`、`:479-490`，`LoomService.cj:168-179`
- **来源**：存量（快照模式无基线）
- **判据**：review-checklist §2「只改类型名 / 字面量复制 / 跨层复制」
- **证据**：静态确定 —— 三份 `fieldOf` 逐行同构（`json.get(key)` → `as JsonString` → `text.value` 否则 `''`）；三份 `textOf` 的差异是**语义**差异（`LoomHostApi` 认 `Int64`，另外两处遇到数字返回空串），属于"实现漂移"而非纯复制；两个 `release` 除形参类型完全一致；两个 `execute` 分支的 5 个字段赋值与两次副作用调用一致。
- **描述**：`fieldOf` 三份意味着"JSON 字符串字段的缺失语义"有三个独立演进点；`textOf` 的差异已经造成不一致——`LoomHostApi.taskEvent` 会把 `Int64` 步骤输出记成十进制串，而 `LoomRunner.taskTextOf` 遇到同样的 `Int64` 起始数据得到空串（自动技能检索拿不到任务文本）。手写 JSON 数组的 7 处都依赖 `FlowPlan.jsonQuote` 做转义，目前正确，但只要有一处改用字符串插值就会产生非法 JSON。
- **建议**：在 `f_llm/src/loom` 内提一个包内工具 `LoomJson`（不新建共享包）：`str(json, key)`、`text(any)`（明确是否支持数字）、`array(items, render)`；`release` 合并成一个接收 `BaseFlow` 的函数；`execute` 的两个分支抽成 `storeFlow(flow, plan, status)`。合并前先把 `textOf` 的语义差异参数化（`allowNumber: Bool`），否则是"统一即回归"。

### [轻微][存量] #15 `LoomDefaults.chat` 在响应没有 `AssistantMessage` 时静默返回空串，多段时只留最后一段

- **位置**：`f_llm/src/loom/LoomDefaults.cj:45-52`（`var text = ''`；`for` 里 `match(item as AssistantMessage)` 覆盖赋值；无匹配则原样返回）
- **来源**：存量（快照模式无基线）
- **判据**：review-checklist §11「错误处理缺失或静默」；§3「`case None => ()` 当兜底把错误吃掉」
- **证据**：静态确定 —— 空串会一路传给 `Planner` / `CodeGen` 的调用方（`LoomWiring.cj:67` 的零配置装配），表现为"模型没返回任何内容"而不是"响应结构异常"。
- **描述**：这是"零配置能用"的门面（README 明确指向 `LoomDefaults.chat`）。上游返回工具调用消息、空 `messages`、或纯 `ToolMessage` 时 `text` 为空，规划阶段会得到空计划并以"模型没给 JSON"的形式失败，排查方向被误导到提示词而不是响应解析；多段 assistant 内容（分段流式/多候选）只保留最后一段，前面的内容静默丢弃。
- **建议**：无 `AssistantMessage` 时抛 `LoomException('loom default chat: no assistant message in response')`；多段时按顺序拼接（或取第一段并在 KDoc 说明理由）。

### [轻微][存量] #16 `LoomMemoryExtractor.extract` 的返回契约写"0~2"（实际可为 3），且知识写入失败被完全吞掉

- **位置**：`f_llm/src/loom/LoomMemoryPolicy.cj:107`（`@return 写入条数（0~2）`）、`:140-167`（`written` 在 note、experience、knowledge 三处 +1）、`:160-165`（`knowledge` 分支 `catch (error: Exception) { () }`）
- **来源**：存量（快照模式无基线）
- **判据**：review-checklist §11「注释与实现不符」；§3「静默吞掉异常」
- **证据**：静态确定 —— `writeKnowledge=true` 时最多 3；`LoomRunner.cj:241-246` 只在 `written == 0` 时 warn，知识单条失败不影响 `written`，因此"配置了写知识但一条没写"没有任何日志。
- **描述**：`write()`（`:183-199`）失败时返回 `false`，注释解释了"存储未装配时不影响流程结果"，属于有意的降级；知识分支连返回值都没有，`catch` 里只有一个 `()`，与记忆分支的"失败→false→计数"不对称。运维视角下 `writeKnowledge` 打开后长期不生效无法发现。
- **建议**：KDoc 改成 `0~3` 并说明各条来源；知识分支 `catch` 里至少 `LoggerFactory.getLogger<LoomMemoryExtractor>().warn(...)`（该文件已导入 `f_log`，正好可用）；或把三处写入统一成 `(ok: Bool, kind: String)` 列表返回，让调用方决定日志级别。

### [轻微][存量] #17 状态用字符串字面量而非 `LoomStatus` 常量；`LoomHostApi` 的"单线程使用"约束注释贴错对象

- **位置**：`f_llm/src/loom/LoomService.cj:43`（`status == 'clarifying'`）、`:86` / `:101`（`LoomResult('clarifying' / 'pending')`）、`:118`（`'compiled'`）、`:150-154`；常量定义 `f_llm/src/loom/LoomRegistry.cj:26-33`（`LoomStatus.CLARIFYING/…`）；注释错位 `f_llm/src/loom/LoomHostApi.cj:22-34`（"约束：单线程使用"紧贴 `class TextBox`，`LoomHostApi` 无类注释）
- **来源**：存量（快照模式无基线）
- **判据**：review-checklist §10「语言特性 / 可读性」；§13「文档与代码一致性」
- **证据**：静态确定 —— `LoomStatus` 提供常量与 `valid()`，`LoomFlow.mark` 用它校验，但 `LoomResult.status` / `needsClarification` / `status()` 全部用字面量；`LoomHostApi.cj` 的类文档被写在 `class TextBox` 前，`LoomHostApi` 自身只有成员级注释。
- **描述**：状态字符串是"编解码契约"（`llm_loom_flow.status` 落库、`Supervisor.register(status:)`、工具返回值），字面量散落意味着改名时编译器帮不上忙，也容易出现 `'clarify'` / `'clarifying'` 这类拼写漂移（当前 `needsClarification` 与 `CLARIFYING` 靠人工对齐）。注释错位使"单线程使用"这条最重要的运行约束在读 `LoomHostApi` 时看不到——直接放大了 #1。
- **建议**：`LoomService` / `LoomResult` 全部改用 `LoomStatus.*`；`LoomStatus` 增加 `prop isTerminal` 之类的判定集中语义；把单线程约束的注释移到 `LoomHostApi` 类声明前，并补一句"并发执行由 `LoomRunner` 串行化（见 …）"或改为运行期校验（见 #1）。

### [轻微][存量] #18 进程级单例 `LoomServices` / `LoomSchedules` 的 `install` / `reset` 无同步，与同模块其它单例的写法不一致

- **位置**：`f_llm/src/loom/LoomFunctions.cj:28-55`（`installed` / `host` 静态，`install` / `installHost` / `reset` 直接赋值，`current` 直接读）、`f_llm/src/loom/LoomScheduler.cj:53-70`（同形态）；对照 `LoomHostApi.cj:46` / `LoomMemoryPolicy.cj:74`（都有 `Mutex`）
- **来源**：存量（快照模式无基线）
- **判据**：review-checklist §12.1「共享可变状态无保护 / 可见性」
- **证据**：待确认 —— 现状静态确定（无锁读写 `?T` 静态字段），但 `install` 是否只发生在启动装配期、`current` 是否只读，需要看 `LoomWiring` 的调用时机；若严格"启动装一次、之后只读"，风险降为可见性理论问题。
- **描述**：`LoomServices.install` 在测试里被反复调用（`LoomFunctions_test.cj:50/61` 等），生产侧若出现"运行期重装"（例如 `LoomWiring` 被多次触发），读到 `None` 的窗口会让 `loomExecute` 静默降级成"service not installed"字符串返回（`LoomFunctions.cj:103-107`），而不是报错。
- **建议**：与 `LoomMemoryPolicy` 统一——`private static let mutex` + 锁内赋值/锁内拷贝；或者把这两个单例改成"只能装一次"的幂等语义（第二次抛错）。

### [轻微][存量] #19 测试卫生：`LoomServiceSkills_test` 用桩网关覆盖全局 store 而不复位、`bind` 后不 `unbind`；`LoomPromptDesign_test` 改进程级 Http 超时并依赖 `/tmp`；`LoomRenderPerf_test` 名为 Perf 实为功能用例

- **位置**：`f_llm/src/loom/LoomServiceSkills_test.cj:68`、`:96`（`finally` 里 `LoomHostApi.installStore({ kind, op, payload => '[]' })` 而不是 `resetStore()`）、`:63`、`:90`（`LoomHostApi.bind(host)` 后没有 `unbind`，靠 runner 的 `finally` 兜底）；`f_llm/src/loom/LoomPromptDesign_test.cj:81-85`（`HttpClient.globalReadTimeout/globalWriteTimeout` 改进程级配置，`static var timeoutsReady` 无同步）、`:65-71`、`:185-190`（读写 `/tmp`）；`f_llm/src/loom/LoomRenderPerf_test.cj:24-84`（类名与注释都指向性能，内容全是功能断言）
- **来源**：存量（快照模式无基线）
- **判据**：review-checklist §6.1「没有测量数据不能当基线」；§12.1「共享可变状态」在测试进程内的同类问题
- **证据**：静态确定 —— `LoomHostApi.storeGateway` 是进程级静态量；桩函数永远返回 `'[]'`，后续用例若没重新 `installStore`，会拿到"任何检索都为空"的假数据而不是"未装配"的报错（`callStore` 的 `None` 分支才会抛 `loom store gateway is not installed`）。
- **描述**：按类/方法顺序跑测试时，`LoomServiceSkills_test` 之后执行的用例会拿到假网关；`bind` 未 `unbind` 的窗口里若用例失败（异常跳过 runner 的 `finally` 之前），后面的用例会看到过期宿主。`LoomPromptDesign_test` 把全局读超时改成 300s，影响同进程所有 HTTP 用例（含失败重试用例的时长预期）。`LoomRenderPerf_test` 的类名会让人误以为有渲染性能基线（本报告 §6.1 因此明确不引用它）。
- **建议**：`finally` 统一 `LoomHostApi.resetStore()` / `unbind()`；`LoomPromptDesign_test` 的全局超时改成构造期注入或 `finally` 恢复原值；`LoomRenderPerf_test` 改名（如 `LoomRender_test`）或补真正的 bench 用例。

<!-- 第 16 部分 -->

### [严重][存量] #1 `Planner.parse` 剥完围栏仍解析原始串：带 ` ```json ` 围栏的模型输出必然解析失败，且抛出 `JsonException` 而非 `LoomException`

- **位置**：`f_llm/src/loom/Planner.cj:148`（`let trimmed = stripFence(raw)`）、`:149`（只拿 `trimmed` 做首尾字符判定）、`:152`（`JsonValue.fromStr(raw)` —— 用的是 `raw`）；实现本体 `f_llm/src/loom/Planner.cj:226-244`
- **来源**：存量（`git blame`：`:148` 为 `eb47a0f5c5 2026-11-02`，`:152` 为 `75f386d77e 2026-11-07`；快照无基线可比）
- **判据**：review-checklist §11「契约与实现不符 / 语义与注释不符」、§10 正确性
- **证据**：静态确定 —— ① 方法体内 `trimmed` 只有 2 处引用（`:149` 的两个判定），之后 `let dto = match (DataObject<PlanDto>.populate(JsonValue.fromStr(raw).toData()))` 仍用 `raw`；② `f_data` 的 `JsonValue.fromStr` → `fromBytes` → `fromInput` → `fromJson` 是严格 token 解析，遇到非 JSON 词法直接 `throw JsonException`（`f_data/src/json/JsonValue.cj:156-212`，含 `case _ => throw JsonException(...)` / `Unexpected token Name` 等分支），不会返回 `None`，所以 `:154` 的 `case None => throw LoomException(...)` 也接不住围栏场景。
- **描述**：注释（`:147`）写明「模型偶尔用 ```json 包裹，或加解释性文字：先剥围栏再确认外层是 JSON 对象」，实现只做了后半句。后果：任何带围栏的输出在 `:152` 抛 `JsonException`（消息是 JSON 词法错误，不含 `planner returned` 上下文），一路冒到 `LoomService.execute`（`LoomService.cj:75` 无 try/catch）→ 调用方拿到的是一次裸解析异常，`PlannerResult`「要么 planned 要么 need_clarification」的契约被绕过。`stripFence` 本身没问题（`Supervisor.cj:264`、`SkillNamer.cj:71`、`LoomMemoryPolicy.cj:129` 三处都在正确使用），是 `parse` 单点接线错误；`Planner_test.cj` 的 8 条 `parse`/`plan` 用例（`:62-199`）没有一条带围栏，所以一直没暴露。
- **建议**：`JsonValue.fromStr(trimmed)`，并把解析包进 `try { … } catch (e: Exception) { throw LoomException('planner returned invalid JSON: ${e.message}') }`，让异常类型回到契约内。若要容忍「围栏 + 前后说明」，取首个 `{` 到末个 `}` 的子串再解析，并在注释里写清只支持「单个 JSON 对象」。补两条用例：` ```json\n{…}\n``` `（应成功）、围栏后跟一段说明（应成功或给可读 `LoomException`）。

### [严重][存量] #2 `LoomTimeout` 用无同步的可变盒子跨线程传结果：数据竞争，可能把空串当成功结果、或对已完成调用误报超时

- **位置**：`f_llm/src/loom/LoomTimeout.cj:21-25`（`class TimeoutBox`，`done` / `value` / `error` 三个 `public var`）、`:39-47`（`spawn` 内写 `value` / `error` / `done`）、`:48-59`（调用线程轮询读 `done` / `error` / `value`）
- **来源**：存量（`git blame`：整段为 `75396dc966 2026-11-03`；快照无基线可比）
- **判据**：review-checklist §12.1「共享可变状态无保护 / 可见性：用普通字段当跨线程信号，而不走原子 / 锁 / 通道」、§11「并发正确性」
- **证据**：静态确定 —— 全文件无 `synchronized` / `Mutex` / `Atomic*`（逐行核对 `:1-61`，只有 `sleep` 与 `spawn`）；`done` 是普通 `Bool` 字段，写在 `spawn` 线程、读在调用线程，两线程之间没有任何 happens-before 边（该函数**故意不** `Future.get()`，所以连 `spawn` 返回值的完成同步也放弃了）。写入顺序（先 `value` 再 `done`）只约束写者自身的顺序，不构成对读线程的可见性保证。语言文档：本机 `~/.autocode/cj/doc` 为空（`ls` 无输出），无法引具体章节，故判据只取 checklist §12.1。
- **描述**：三种可观察错误：① `box.done` 写入对轮询线程不可见 ⇒ 一直读到 `false`，`action` 早已返回却仍返回 `timeout after ${timeoutMs}ms`（步骤被记为失败）；② 观察到 `done=true` 但读到旧值 `''` ⇒ **把空串当成 LLM / 工具的成功结果**返回，调用方无法区分「模型返回空」与「竞争读到空」；③ 只 `catch (error: Exception)`，`Error` 子类逃出后 `box.done` 永不置位，表现为必然等满超时（`BackgroundTasks.cj:44` 的 `recordWithTimeout` 是唯一生产调用点，超时即丢记录）。另外轮询用 `waited += 10` 常量累加而非读时钟，真实超时只会晚于 `timeoutMs`，且每次空转都 `sleep(10ms)`，「注释语义正确、传结果通道不成立」是本条的核心。
- **建议**：优先用语言自带的超时等待替代手写轮询（`Future.get` 的 `Duration` 重载 / `TimeoutException`，签名与 `timeout <= 0` 的边界需按 std 文档核对，标 `待确认`）；若保留轮询，把 `done` 换成 `AtomicBool`、`value`/`error` 改由同一把 `Mutex` 保护或改成单字段 `AtomicReference<TimeoutResult>`，读方先拿一次同步再读负载。补并发用例：`action` 内 `sleep(5ms)` 后返回固定串，循环 1000 次断言既不出现空串也不出现早退超时。

### [严重][存量] #3 评测入口有破坏性全局副作用：`loadCorpus` 无条件清空整个技能库，`run` 覆盖进程级 `SkillCatalog` 且异常路径不还原

- **位置**：`f_llm/src/loom/RetrievalEvalRunner.cj:49-53`（`for(skill in meta.skills.list()){ meta.skills.remove(skill.id) }`）、`:87-90`（`SkillCatalog.reset()` + `install(… embedder)`）、`:123-129`（只在正常返回前 `reset()`，不在 `finally`）
- **来源**：存量（`git blame`：`7dbccf3e1d 2026-11-05`；快照无基线可比）
- **判据**：review-checklist §11「资源不对称 / 数据丢失」、§12.1「共享可变状态无保护」、§5「长期持有与全局集合」
- **证据**：静态确定 —— ① `loadCorpus(meta, docs)` 的入参类型是任意 `MetaStore`，删除循环没有任何过滤（不是「只删本次语料的同名技能」，尽管注释 `:50` 的理由是叠版本）；`SkillStore.remove(id)` 在契约里就是真删（`store/StoreContracts.cj:97-98` 的注释即「删除」）；② `SkillCatalog` 是进程级单例（`SkillCatalog.cj:60-66` 的 `install` 持锁覆盖 `storeFactory` / `embedder` 并清空 `vectors`），`run` 覆盖它、结束时 `reset()`，但 `:118-121` 的 `evaluate`、`:123` 的 `embedFailureDetail` 任一处抛异常都会跳过 `:129` 的 `reset()`。
- **描述**：`doc/retrieval-eval.md:102` 的示例传 `InMemoryMetaStore()`，正常用法安全；但 API 接受任意 store，误传 `FStoreMetaStore` / mysql / postgres 即等于**清空生产技能库**（标题索引与正文一起删），且不可回滚。`run` 中途抛异常则整个进程的技能检索从此指向评测语料（`RetrievalEvalRunner` 是 README 对外宣传的能力，见 `README.md:14`、`:143`）。这是「危险默认 + 无守卫」。
- **建议**：① `loadCorpus` 只删本次语料标题命中的 id（先算 `titleToId` 的键集），或加显式 `resetAll!: Bool = false`；② `SkillCatalog` 的安装 / 还原包进 `try { … } finally { SkillCatalog.reset() }`（还原到原 `storeFactory` 更好）；③ 文档补一句「传入生产 `MetaStore` 会清空技能库」。用例侧建议补「`loadCorpus` 不删除语料外技能」的断言。

### [一般][存量] #4 `LoomRequest.onUnresolved` 只有赋值、没有读取点：文档承诺的「澄清轮次用尽按 ask/default/abort 收尾」不存在

- **位置**：`f_llm/src/loom/Planner.cj:33-34`（字段与注释「澄清轮次用尽时的策略：ask | default | abort」）、`:45`（构造参数）、`:59`（赋值）；承诺源 `f_llm/doc/f_llm.md:375-376`
- **来源**：存量（`git blame`：`d3ced38130 2026-11-01`；快照无基线可比）
- **判据**：review-checklist §14.1「承诺了但没实现 / 接线缺失」、§1「读了不用（死配置字段）」；硬原则一：字段对外可达，**不判死代码**，只判「承诺未接线」
- **证据**：静态确定 —— 全仓 `grep -rn onUnresolved`（排除 `.worktrees`）只命中 `Planner.cj` 的 3 处（声明 / 参数 / 赋值）+ `doc/f_llm.md:375-376`、`README.md:969` 的说明；`LoomService` / `LoomAgent` / `CodeGen` / `LoomRunner` 零读取。`round` 也只有两处写入（`LoomService.cj:79`、`:94`），没有「轮次 +1 / 上限判定」的代码。
- **描述**：传 `onUnresolved: 'abort'` 或 `'default'` 不会有任何行为差异——既不会 abort，也不会用 `ClarifyQuestion.defaultValue` 收尾（`defaultValue` 因此只是透传字段）。这是「公开契约写了一个分支，实现里没有该分支」。同源 `dryRun`（`LoomRequest.dryRun` / `LoomExecuteParam.dryRun` 全链路无读取）已由 `parts/f_llm.part15.md` 的 #4 记录，**本部分不重复计数**。
- **建议**：要么在 `LoomService.execute` 的澄清分支真正消费（`round >= maxRound` 时按 `onUnresolved` 三分支：`abort` 抛 `LoomException`、`default` 用 `defaultValue` 填 `answers` 后重新 plan、`ask` 保持现状），`maxRound` 作为可选配置；要么删字段并同步改 `doc/f_llm.md:375-376`。测试落点：`Planner_test` / `LoomService_test` 各补一条「round 用尽 + abort」。

### [一般][存量] #5 提示词与 `StepPlan` 注释都声明 `kind=http` 合法，`validate` 却一律拒绝：按提示词输出的模型会让整份计划被否

- **位置**：`f_llm/src/loom/Prompts.cj:36`（规则 6：「步骤 kind 只能是 tool / llm / mcp / jit / http」）、`f_llm/src/loom/Plan.cj:30`（`kind` 取值注释同样列出 `http`）、`f_llm/src/loom/Plan.cj:125-126`（`case 'http' => throw LoomException('loom step kind http is not implemented yet: …')`）
- **来源**：存量（`git blame`：`Plan.cj:126` 与 `Prompts.cj:36` 均为 `d3ced38130 2026-11-01`；快照无基线可比）
- **判据**：review-checklist §13「规格与实现漂移」、§14.1「承诺了但没实现」、§11「契约与实现不符」
- **证据**：静态确定 —— 提示词把 `http` 列为可选 kind，`validate` 又把 `http` 单独判死；`Plan_test.cj:146-157` 还写了用例锁定「拒绝 http」，两者不可能同时为真。
- **描述**：`http` 是模型输入契约里的合法选项，模型照规则第 6 条排一个 `http` 步骤完全合理；但 `Planner.planOf` → `validate()` 抛错后**整份计划被否决**（连同其中合法步骤一起丢掉），一次成功的模型调用作废，用户只看到「不支持」。提示词是模型唯一的规格来源，这里两个规格源各说一套。
- **建议**：二选一并保持单一事实源：①（推荐）从 `Prompts.cj:36` 与 `Plan.cj:30` 删掉 `http`，改为「需要 HTTP 请用已注册工具」；② 实现 http 步骤后再放开（属功能开发，另开条）。若保留 `http` 作实验，提示词必须显式写「暂不支持，请勿使用」。

### [一般][存量] #6 网关惰性初始化是裸 check-then-write：并发首次调用会构造两个 `LoomStoreGateway`（两套存储连接），注释承诺的「只建一次」不成立

- **位置**：`f_llm/src/loom/LoomWiring.cj:38-54`（`class LoomGatewayHolder`：`:39` `private var value: ?LoomStoreGateway`，`:46-52` 先查后写、无锁）、`:104-106`（`LoomHostApi.installStore({ … gatewayHolder.get(gateway).call(…) })`）
- **来源**：存量（`git blame`：`8fa6e394aa 2026-11-06`；快照无基线可比）
- **判据**：review-checklist §12.1「检查-然后-写入 / 惰性初始化」、§6.3「并发串行（重复初始化）」
- **证据**：静态确定（模式）+ 调用路径可证 —— `match (value) { Some => return }` 与 `value = Some(LoomStoreGateway())` 之间无任何同步手段；并发读者至少有两条：① `LoomHostApi.callStore` 只在锁内拷 `storeGateway`，回调在**锁外**执行（`LoomHostApi.cj:170-179`），任意流程步骤的 `loomStore(…)` 都会走到这里；② 技能演进 cron 在调度器线程执行 `SkillEvolutionJob.load(holder.get(injected), …)`（`LoomWiring.cj:213-216`）。无参构造 `LoomStoreGateway()` 会 `Stores.content()` + `Stores.meta()` + `EvolutionStores.current()`（`LoomStoreGateway.cj:68-74`），可能各开一套连接 / 句柄。
- **描述**：两线程同时首次进入 ⇒ 都看到 `None` ⇒ 各建一个网关，后者覆盖前者，先建的那个被本线程用完即弃——连接池 / 文件句柄泄漏，同进程出现两份网关；`buildCount` 也会 >1，即 `LoomWiringGateway_test` 想守的「只建一次」自检在并发下失效（该测试只覆盖「注入网关时不新建」，`LoomWiringGateway_test.cj:47-65`）。
- **建议**：给 holder 加 `Mutex` 做锁内二次检查，或在 `wire` 里用原子引用 CAS；若坚持不锁，就改成装配期建一次并删掉「懒建」注释（`:101-102` 与实现二选一）。补并发用例：10 线程同时 `callStore('skill','count','{}')`，断言 `LoomStoreGateway.buildCount == 1`。

### [一般][存量] #7 定时流程执行失败被 `catch (error: Exception) { () }` 吞掉：无日志、无计数，cron 任务静默失效

- **位置**：`f_llm/src/loom/ScheduleFunctions.cj:82-93`（`:85-90` 的 `try { service.executeNow(…) } catch (error: Exception) { () }`）
- **来源**：存量（`git blame`：`36c19d2ed2 2026-11-03`；快照无基线可比）
- **判据**：review-checklist §3「`catch` 静默吞掉异常」、§11「错误处理缺失或静默」、`fountain-baseline.md` §6（日志走 `f_log`）
- **证据**：静态确定 —— `catch` 体是空 tuple `()`，无 `LoggerFactory`、无计数器、无回写；同文件其它分支（`:56-60`、`:73-77`）都会把可读结果返回给调用方，只有这一支什么都不留。
- **描述**：`scheduleCreate` 注册的 body 在调度线程按 cron 执行同名流程（`:66-71`），`runFlow` 里的任何异常（流程不存在、未编译、JIT 失败、LLM 超时抛错）都被吞。表现是「到点了，但什么都没发生」，且没有任何日志能证明它跑过。注释（`:81`）只解释了「宿主缺失时静默跳过」，实现把「宿主缺失」与「执行失败」合并成了同一种静默。
- **建议**：`case None` 保持静默（可 `debug`），`catch` 分支至少 `LoggerFactory.getLogger<ScheduleCreateFunction>().error('loom scheduled flow failed: ${name}: ${error.message}')`；担心日志放大就 `warn` + 去重，但不要什么都不打。

### [一般][存量] #8 评测用「标题」反查语料 id，既不校验标题唯一、又用 `case None => ()` 静默丢命中

- **位置**：`f_llm/src/loom/RetrievalEvalRunner.cj:65-71`（`titleToId`：`map[doc.title] = doc.id`，后写覆盖先写）、`:91-100`（search 闭包里 `match (idOf.get(hit.title)) { case Some(id) => ids.add(id); case None => () }`）
- **来源**：存量（`git blame`：`7dbccf3e1d 2026-11-05`；快照无基线可比）
- **判据**：review-checklist §3「`case None => ()` 把错误吃掉」、§11「静默失效」、§13（数据约束未写入文档）
- **证据**：静态确定 —— 语料 `id` 唯一有断言（`RetrievalEval_test.cj:134-139`），**标题唯一没有任何断言**；`SkillCatalog.search` 只回标题（`:93` 的 `hit.title`），标题重复时两条语料折叠到同一 id，另一条永远命不中，`recall` 被系统性拉低；`case None` 让「标题对不上」这种数据错误直接表现为「没命中」。
- **描述**：受影响的正「改了语料忘改标题 / id」的场景——正是评测脚本最该报警的输入错误，却被计成一个安静的指标下降（`doc/retrieval-eval.md:122-133` 记录过一次「指标莫名偏低」的踩坑，说明这类失真发生过）。
- **建议**：`titleToId` 检测冲突并抛 `LoomException('duplicate corpus title: …')`；`case None` 分支累加 `unmappedHits` 并在报告头 `WARN`（与 `embedFailures` 同款处理）。`testShippedDatasetIsWellFormed` 补「标题唯一」断言。

### [一般][存量] #9 `status` 未识别与空 `steps` 都落到 `planned`：模型输出 `{}` 或拼错 status 会静默产出一个空流程，被落库并可编译

- **位置**：`f_llm/src/loom/Planner.cj:156-161`（只有 `if (dto.status == 'need_clarification')`，其余一律 `planOf` + `PlannerResult('planned', …)`）；`f_llm/src/loom/Plan.cj:94-141`（`validate` 没有 `steps` 非空校验）；`f_llm/src/loom/CodeGen.cj:148-162`（`firstStep` 在空 `steps` 时返回 `''`，`flowSource` 因此跳过 `registerStart`）
- **来源**：存量（`git blame`：`d3ced38130 2026-11-01`；快照无基线可比）
- **判据**：review-checklist §11「契约与实现不符 / 空集合未处理」、§14.1「只做了一半的分支」、§3「开关打开后走进空分支」
- **证据**：静态确定 —— `PlanDto.status` 默认 `'planned'`（`Planner.cj:364`），`parse` 是二值判定；`{}`、`{"status":"clarify"}`、`{"status":"PLANNED"}` 都进 `planned` 分支，`planOf` 产出 0 步骤的 `FlowPlan`，`validate` 三个循环都不执行直接通过，`CodeGen.firstStep` 返回 `''`、`flowSource` 不写 `registerStart`。`Planner_test.cj:124-131` 的用例名叫 `testPlanWithoutStepsIsRejectedByCodeGen`，但断言只有 `plan.steps.size == 0`——**没有任何拒绝**，用例名与断言相反。
- **描述**：模型把 status 写错或返回空对象时，用户得到一份「成功但空」的流程：`pending` → `confirm` → `compiled`，执行时无任务可跑、无报错。错误被推迟到「跑完什么都没发生」，与「模型没排步骤」无法区分；而无步骤在 schema 里本应是非法计划。
- **建议**：`match (dto.status) { case 'planned' => …; case 'need_clarification' => …; case other => throw LoomException('planner returned unknown status: ${other}') }`；`validate` 增加 `if (steps.isEmpty()) { throw LoomException('loom plan must have at least one step') }`；把那条用例改名或改成真正的拒绝断言。

### [一般][存量] #10 `wire(store:)` 只接管流程注册表；演进族存储 / 技能目录仍走全局 `llm_metaStore`，注入 store 的调用方仍会连生产库（测试里真的写 `./data/f_llm-meta`）

- **位置**：`f_llm/src/loom/LoomWiring.cj:85-92`（`store!` 只用于 `LoomRegistry`）、`:128`（`SkillCatalog.install({=> Stores.meta().skills})`）、`:130-134`（`EvolutionStores.bootstrap()` / `EvolutionStateStores.bootstrap()` / `EvolutionLeases.bootstrap()`）；对照 `EvolutionStores.cj:41-43`（`current()` → `byName(StoreSettings.load().metaStore)`）、`StoreSettings.cj:40-41`（默认 `f_store` / `./data/f_llm-meta`）
- **来源**：存量（`git blame`：`8fa6e394aa 2026-11-06`；快照无基线可比）
- **判据**：review-checklist §14.1「接线缺失 / 只做了一半」、§10 设计合理性（注入点覆盖面与声明不符）、§11「契约与实现不符」
- **证据**：静态确定 —— `wire` 的 `store` 参数在 `:87-91` 之后不再出现；四个 bootstrap / install 全部走 `Stores.*` / `StoreSettings`，与入参无关。可观察后果就在本部分：`LoomWiring_test.cj:37-89` 的四条用例只传 `store: MemoryLoomStore()`、**没有**设 `llm_metaStore`，因此每次 `wire` 都会 `EvolutionLeases.bootstrap()` 对默认 `./data/f_llm-meta` 建表并写一条租约；同目录的 `LoomWiringSupervisor_test.cj:57-58` 专门设了 `llm_metaStore=memory` 并在注释里写明「装配会碰演进族存储：指到内存，避免写默认元数据目录污染别的用例」——两条测试的写法差异正好证明这条链没被 `store` 覆盖。
- **描述**：① 调用方以为「传了 store 就完全隔离」，实际技能目录、演进报告表、演进状态、租约仍打到全局配置的库；② `cjpm test` 会写仓库目录下的 `./data/f_llm-meta`，并使测试之间通过全局存储产生隐式耦合（`Config` 是进程级单例，测试类并行执行时互相污染）。
- **建议**：让 `wire` 把选定的 store 一并传给 `SkillCatalog.install` 与三个 bootstrap（或新增 `evolutionStore! / metaStore!` 参数并在注释里写明「只影响 X」）；`LoomWiring_test` 与 `LoomWiringChannel_test` 补齐 `Config.set<String>([('llm_metaStore','memory')])` + `finally` 清理（照抄 `LoomWiringSupervisor_test.cj:56-77` 的写法）。

### [轻微][存量] #11 `FlowPlan.validate` 不查任何长度的环：`a→b→a` 能通过校验并被标成 compiled，直到执行期才由拓扑排序拒绝

- **位置**：`f_llm/src/loom/Plan.cj:93`（注释「校验：步骤 id 唯一、边两端存在、无自环、kind 合法」）、`:133-140`（只判 `edge.from == edge.to`）；兜底 `f_llm/src/loom/LoomRunner.cj:525-561`（Kahn 拓扑排序，`:558-560` 抛 `loom plan contains a cycle, cannot execute`）
- **来源**：存量（`git blame`：`d3ced38130 2026-11-01`；快照无基线可比）
- **判据**：review-checklist §11「边界缺失」、§14.1「只做了一半的分支」
- **证据**：静态确定 —— `validate` 的边循环只有「端点存在 + 非自环」两项，无入度 / 可达性检查；环不会被无限执行（`LoomRunner.topologicalOrder` 会抛错），所以**不是挂死**，而是「编译成功、执行必失败」。
- **描述**：同一类非法输入（模型排错边）在编译期放行、在执行期才报错，`confirmFlow` 之后 `LoomStatus.COMPILED` 是个假状态；排错信息到了执行期才出现，且 `LoomService.confirmFlow` 的成功返回会让人误以为流程可用。
- **建议**：在 `validate` 末尾加一次 Kahn（O(V+E)，用现成 `HashMap` 入度表），走不完即抛 `LoomException('loom plan contains a cycle: <剩余 id>')`；顺带把「根节点唯一 / 全部可达」也放这里（与 `parts/f_llm.part15.md` #3 的修法合并到同一处）。补用例：`a→b→a` 必须在 `validate` 就被拒。

### [轻微][存量] #12 jit 占位符拒绝逻辑写了两遍，且只扫「已见」步骤 id：同文案重复 + 前向引用漏检

- **位置**：`f_llm/src/loom/Plan.cj:109-124`（`:111-118` 遍历 `seen.keys()` 抛一次，`:119-124` 又为 `start` 抛一次，两段文案除 token 名外逐字相同）；`seen[item.id] = true` 在 `:106`，即扫描集合只含当前及之前步骤
- **来源**：存量（`git blame`：`d3ced38130 2026-11-01`；快照无基线可比）
- **判据**：review-checklist §2「字面量复制：同一文案两处」、§11「边界缺失」（校验覆盖不全）
- **证据**：静态确定 —— 两段 `throw LoomException('jit step does not support {…} template placeholders …')` 只差括号里的 id 与提示语；`:111` 的 `for (token in seen.keys())` 在 `:106` 之后执行，因此**后续步骤的 id 不在集合里**，`{later.output}` 形式的占位符不会被拒绝。
- **描述**：jit 源码在编译期固化，占位符不会被替换——这正是该校验存在的理由；引用后面步骤的 jit 步骤会带着字面量 `{x.output}` 编译通过，运行时产出的是这段字面文本（静默错误结果）。重复的两段在修改提示语时也容易只改一处。
- **建议**：改成先收集 token 列表（`seen.keys()` + `'start'`，或直接扫全部 `steps` 的 id），再对 `['{${t}.output}', '{${t}}']` 两个模式循环抛一次；若要保留「仅前序」的语义，注释必须写明并说明后继引用为何安全。

### [轻微][存量] #13 `TopicStat` 与 `EvalReport` 的四个指标函数逐行相同（重复逻辑）

- **位置**：`f_llm/src/loom/RetrievalEval.cj:79-105`（`TopicStat` 的 `ndcg` / `recallAt1` / `recallAtK` / `mrr`）对 `:142-168`（`EvalReport` 的同名四个函数）
- **来源**：存量（`git blame`：`7dbccf3e1d 2026-11-05`；快照无基线可比）
- **判据**：review-checklist §2「只改类型名：两个函数体逐行对齐」
- **证据**：静态确定 —— 四对函数体逐字相同（同样的 `if(total <= 0){ return 0.0f64 }` + 同样的分子/分母），唯一差异是 `EvalReport` 多一个 `negativeRate`；两边的 `total` 都是「正样本数」，语义一致。`render`（`:186-187`、`:212-213`）同时调用两种类型的方法。
- **描述**：当前无行为漂移，但「改分母规则」要改两处（例如以后把负样本计入分母），很容易只改一边。
- **建议**：抽 `internal func metricRatio(numerator: Float64, total: Int64): Float64`（或让 `EvalReport` 内嵌一个「全局 `TopicStat`」），四对方法改成一行委托；两个类型对外签名不变。

### [轻微][存量] #14 语料目录解析在两处逐字重复（同一环境变量、同一缺省值），且都不 trim 而同类 env 读取又 trim，口径不统一

- **位置**：`f_llm/src/loom/RetrievalEval.cj:249-255` 对 `f_llm/src/loom/RetrievalEvalManual_test.cj:55-60`
- **来源**：存量（`git blame`：`7dbccf3e1d 2026-11-05`；快照无基线可比）
- **判据**：review-checklist §2「字面量复制：同一个环境变量 / 同一个缺省值散落多处」
- **证据**：静态确定 —— 两处都是 `match(getVariable('fllm_evalDir')){ case Some(value) => value; case None => './eval' }`，逐字相同（都不 `trimAscii`）；而同一测试文件的 `modelName()`（`:48-53`）对 `fllm_evalModel` 做了 `trimAscii` 并处理空串，`minScore`（`:69-72`）也做了 trim，只有目录这一路不 trim，同一文件内口径已不一致。
- **描述**：`fllm_evalDir` 带尾随空格 / 换行时，目录路径会带进脏字符（`./eval ` 打不开），错误表现为「文件不存在」而不是「变量写错了」；`RetrievalEval_test.evalDir`（`:314-322`）又是第三份「先试再用 `../eval` 回落」的逻辑，三处需要人肉对齐。
- **建议**：`RetrievalEvalManual_test.evalDir()` 直接调 `RetrievalEval.defaultDir()`，并把 `trimAscii` 收进 `defaultDir`；`RetrievalEval_test.evalDir` 的回落逻辑若要保留，注释写明「仅在 cjpm test 工作目录不一致时需要」。

### [轻微][存量] #15 `RetrievalEval.linesOf` 全量 `readToEnd` 且 `file.close()` 不在 `finally`：读异常即泄漏句柄

- **位置**：`f_llm/src/loom/RetrievalEval.cj:416-429`（`:418` `File(path, OpenMode.Read)`、`:419` `StringReader(file).readToEnd()`、`:420` `file.close()`）
- **来源**：存量（`git blame`：`7dbccf3e1d 2026-11-05`；快照无基线可比）
- **判据**：review-checklist §11「资源不对称：异常跳过释放」、§5「一次性物化」（`mem §5.1` 流式优先）
- **证据**：静态确定 —— `close()` 与 `readToEnd()` 之间没有 `try/finally`；`readToEnd` 在路径是目录 / 编码非法 / 文件被截断时抛异常，此时 `file` 已打开且不会关闭。
- **描述**：评测是手动 / nightly 入口，进程退出会回收，但「循环跑多个目录」就会累积；`readToEnd` 生成整串后再 `split('\n')` + `ArrayList`，是对同一份数据的第二次全量副本。50 条语料无压力，`fllm_evalDir` 指向大文件时就是典型的按输入长度物化。
- **建议**：`try { … } finally { file.close() }`，或改成 `std.io` 逐行读（边读边 `add`），顺带消掉二次副本。

### [轻微][存量] #16 `LoomWiring.cj` 的 KDoc 挂错对象：`LoomWiring` 类注释落在 `LoomGatewayHolder` 上，`installSupervisor` 的注释落在 `reload` 上

- **位置**：`f_llm/src/loom/LoomWiring.cj:25-36`（「loom 的启动装配…需要宿主在 `StoreWiring.wire()` 之后调一次」）紧接 `:37` 的 `/** 懒建一次的网关持有者… */` 与 `:38` 的 `class LoomGatewayHolder`；`:143-148`（「装配 Supervisor…」）紧接 `:149` 的 `/** 最近一次装配的恢复结果… */` 与 `:150` 的 `private static var reload`；`:60-64`（`@param chat … @return 已安装的 LoomService`）紧接 `:65` 的 `/** 零配置… */` 与 `:66` 的 `wire(plannerModel!)`
- **来源**：存量（`git blame`：`8fa6e394aa 2026-11-06` / `d3ced38130 2026-11-01`；快照无基线可比）
- **判据**：review-checklist §10「可读性 / 必要注释」、§11「语义与注释不符」
- **证据**：静态确定 —— 连续两段 KDoc 时只有最后一段属于被修饰声明：`public class LoomWiring`（`:56`）因此**没有类文档**，`LoomGatewayHolder` 拿到的是「启动装配」的说明；`installSupervisor`（`:176`）与 `lastReload`（`:152`）同理互换/缺失；`wire(chat, …)`（`:75`）的 20 个命名参数失去了 `:60-64` 的 `@param` 说明（该段落在 `wire(plannerModel!)` 前面）。
- **描述**：doc 生成与 IDE 悬浮会读错：查 `reload` 看到「装配 Supervisor」，查 `installSupervisor` 什么都没有，查 `LoomWiring` 类没有任何说明。`LoomWiring.wire` 是 README 列的对外入口，参数文档丢失影响最大。
- **建议**：`:25-36` 移到 `:56` 前（`LoomGatewayHolder` 只留 `:37`）；`:143-148` 移到 `:176` 前；`:60-64` 移到 `:75` 前，`wire(plannerModel!)` 保留 `:65` 一句。

### [轻微][存量] #17 未使用的 import：`LoomTimeout.cj` 的 `std.sync.*` / `std.time.*`，`LoomWiringGateway_test.cj` 的 `fountain::f_data.JsonString`

- **位置**：`f_llm/src/loom/LoomTimeout.cj:18`、`:19`；`f_llm/src/loom/LoomWiringGateway_test.cj:22`
- **来源**：存量（`git blame`：`75396dc966 2026-11-03` / `8fa6e394aa 2026-11-06`；快照无基线可比）
- **判据**：review-checklist §1「未使用的 import」（机械动作第 7 条）
- **证据**：静态确定 —— `LoomTimeout.cj` 只用 `TimeoutBox` / `String` / `Bool` / `sleep` / `Duration` / `spawn`，`std.sync` 的 `Mutex`/`Atomic`/`synchronized` 与 `std.time` 的 `DateTime` 一个都没出现（`grep` 该文件无这些符号）；`LoomWiringGateway_test.cj` 的 `JsonString` 只在 `:22` 出现，文件内 `match(out as DataEvent)` 之类都不涉及（`as JsonString` 的用法在 `ScheduleFunctions_test.cj:57`，不在本文件）。
- **描述**：无害，但 `std.sync.*` 的通配 import 会让人误以为 `LoomTimeout` 用了同步原语——而 #2 的问题恰恰是**没有**同步。删掉后读者不会误判。
- **建议**：删除三处 import；若按 #2 改用 `Future.get` 的超时重载，只需 `std.core` 的异常类型（无需新增 import）。

### [轻微][存量] #18 测试注释与数据集实际规模不符（「语料只有 20 条」，实际 50 条）

- **位置**：`f_llm/src/loom/RetrievalEval_test.cj:263`（`// 选择排序取前 topK（语料只有 20 条）`），对照同文件 `:132`（`@Expect(docs.size, 50)`）与 `eval/retrieval_corpus.tsv`（实测 50 条有效行）
- **来源**：存量（`git blame`：`7dbccf3e1d 2026-11-05`；快照无基线可比）
- **判据**：review-checklist §10 可读性 / §13「文档与代码一致性（注释过期）」
- **证据**：静态确定 —— 注释写 20、断言写 50；同文件类注释 `:122` 写的是「50 条语料 + 612 条正样本」，说明 `:263` 是扩语料时漏改的残留（另核对数据集：50 条语料 / 622 条 query = 612 正样本 + 10 负样本 / 12 个主题，与 `:162-174` 断言一致）。
- **描述**：不影响执行；但这条注释是「为什么可以对语料用 O(n²) 选择排序」的唯一理由，数字错了会让人误判复杂度前提。
- **建议**：改成「语料 50 条」或去掉具体数字。

### [轻微][存量] #19 报表格式化不严谨：`percent` 截断且小数位随值变化，`padRight` 按字节对齐（中文主题列不齐）

- **位置**：`f_llm/src/loom/RetrievalEval.cj:225-227`（`percent`）、`:229-235`（`padRight`，用 `Int64(padded.size) < width`）
- **来源**：存量（`git blame`：`7dbccf3e1d 2026-11-05`；快照无基线可比）
- **判据**：review-checklist §11「语义与命名 / 注释不符」、§10 可读性
- **证据**：静态确定（`percent`）/ 待确认（`padRight`）—— `percent(0.6309)` → `6309/100=63`、`6309%100=9` → `63.9%`（第三位直接截断、不四舍五入）；`percent(0.05)` → `5.0%`；`percent(1.0)` → `100.0%`，小数位随值变化，人工比对主题时列对不齐。`padRight` 的宽度若按 UTF-8 字节算（`String.size` 的字节语义需按 std 文档核对，本机无文档副本，标 `待确认`），`padRight('代码评审', 10)` 会提前「填满」，中文主题名整体左移。
- **描述**：只影响人工阅读的报表（`doc/retrieval-eval.md:109-120` 的样例输出），不影响指标数值；但主题名多为中文，而「最差主题排最前」正是报表的主要目的（`:178-182` 的注释）。
- **建议**：`percent` 改定点两位（乘法后加 50 再除，实现四舍五入）；`padRight` 按 `Rune` 数或显示宽度补齐。

<!-- 第 17 部分 -->

### [一般][存量] SkillMatcher 在技能循环内重复编码同一条经验，外部 embedding 调用放大为「素材数 × 技能数」

- **位置**：`f_llm/src/loom/SkillMatcher.cj:132-145`（第 137 行 `encodeSafely(embedderValue(embedder), item.content)` 位于第 135 行 `for(skill in usable)` 之内）
- **来源**：存量（快照模式无基线）
- **判据**：review-checklist §6.4（同一输入重复解析 / 重复计算）、§8-2（减少分配与跨边界调用）
- **证据**：静态确定 —— 外层 `for(item in experiences)`（132）× 内层 `for(skill in usable)`（135），内层每次重新调用编码器，`item.content` 被编码 `usable.size` 次；`skillVectors` 已缓存技能侧向量，素材侧没有缓存
- **描述**：`SkillCatalog.embeddingEncoder`（`SkillCatalog.cj:120-122`）走 `Embedding.embed`，是远程模型调用。默认 `limit=500` 条素材 × N 个技能 = 500N 次编码，正确只需 500 次；编码器抛错时同一个失败也要重复 N 次。演进任务在定时线程里跑，调用量随技能数线性放大，直接放大耗时与接口成本
- **建议**：把素材编码提到内层循环外（每条经验编码一次，`match` 后再遍历 `skillVectors`）；顺带把 `embedderValue(embedder)` 也提到循环外（当前每次迭代都重走一次 `match`，`None` 分支还会新建空闭包）

### [一般][存量] 知识「还没沉淀成技能」就被写死为已消费，模型一次失败或开关关闭即永久丢弃

- **位置**：`f_llm/src/loom/SkillEvolutionJob.cj:196-203`（`state.markKnowledge(usedKnowledge.toArray())` 无条件执行）；配合 `96-106`（按 `consumed` 过滤）与 `184-193`（建技能可能失败）
- **来源**：存量（快照模式无基线）
- **判据**：review-checklist §11（失败路径当成功）、§3（失败被吞后状态被写死）
- **证据**：静态确定 —— `usedKnowledge` 由**全部** `freshKnowledge` 构成，与 `created` / `rejected` 无关，写入点在本轮所有分支之后、无任何条件
- **描述**：三种情况会把「未被使用」的素材永久记账：(1) `nameCandidates=false`（`177`）时候选簇只上报不建技能；(2) `SkillNamer.propose` 返回 `None`（`185-191`，模型不可用或输出非法）只记一行 `rejected`；(3) 从下一轮起 `consumed.contains(item.source)`（`103`）把它们挡在 `freshKnowledge` 之外，而知识 `at=0` 不会再由水位线带回来。另一个同源缺口：`source` 为空的知识（`103` 允许通过）永远进不了 `usedKnowledge`（`199`），会**每轮重复参与聚类**，`nameCandidates=true` 时可能反复建同名技能
- **建议**：只把「本轮真正落地」的知识记入 `markKnowledge`——按簇是否成功 `emit`、是否被现有技能吸收来选；`rejected` 与 `nameCandidates=false` 的簇保留 `docId` 待下轮。`source` 为空的知识改用内容哈希生成稳定键

### [一般][存量] 空轮 / 读失败轮把水位线直接推进到 `now`，未处理的素材下一轮被永久跳过

- **位置**：`f_llm/src/loom/SkillEvolutionJob.cj:234-242`（`} else if (now > 0) { state.markRun(now) }`）；失败入口 `279-283`、`320-324`、`337-341`
- **来源**：存量（快照模式无基线）
- **判据**：review-checklist §11（失败路径当成功、数据被永久跳过）、§3（异常吞成空集合）
- **证据**：静态确定 —— `advanced` 只由本轮 `fresh*` 的 `at` 求 max；网关读失败时三个列表都为空 → `advanced == 0` → 走 `else` 分支把 `lastRunAt` 写成 `now`。下一轮 `fresh()` 用 `at > since` 过滤，`at ∈ (since, now]` 的记录全部落在窗口外
- **描述**：这一分支本意是「只有知识文档（`at=0`）的轮次也要推进轮次」，但它无法区分「本轮确实没有新素材」和「本轮没读到素材」。存储抖动/超时一次（异常被 `'[]'` 吞掉），水位线就推进到当前时刻，此前未处理的成功/失败经验从此不会被任何一轮看见；只有手工把水位重置为 0 才能恢复。上面第 215-217 行的注释正是为了防止这类跳过，但 `else` 分支把它绕过去了
- **建议**：`load` 失败时让 `run` 拿到显式的失败信号（返回带 `error` 的报告或抛异常），失败轮**不推进**水位；只有 `materials` 非空或明确读到「空结果」时才走 `markRun(now)`，并把「空结果」与「读失败」分开记账

### [一般][存量] 网关 / 存储异常被吞成空集合，检索静默返回「没有技能」、演进静默空转，无日志无计数

- **位置**：`f_llm/src/loom/SkillCatalog.cj:188-196`（`catch → ArrayList<Skill>()`）；`f_llm/src/loom/SkillEvolutionJob.cj:279-283`、`320-324`、`337-341`（网关异常 → `'[]'` / `''`）、`209-213`（台账写失败 → `()`）、`401-404`（定时任务整体异常 → `()`）
- **来源**：存量（快照模式无基线）
- **判据**：review-checklist §3（`catch → ()` 静默吞异常）、§14.1（失败没有任何可观测出口）
- **证据**：静态确定 —— 六处 `catch` 的返回值与「本来就没有数据」完全同形；同模块 `LoomWiring.cj:96` 已有 `LoggerFactory.getLogger<LoomWiring>().warn(...)` 的惯例，这六处都没有
- **描述**：`SkillCatalog` 专门为「装了编码器却跑关键词」加了失败计数（`52-54`、`85-92`），但**存储不可用**这条更常见的降级路径没有任何计数：`search` 返回空列表，调用方无法区分「技能库为空」和「读失败」，模型会在没有技能的情况下跑完整条流程。演进侧更严重：`memory.list` 失败 → 素材为 0 → 本轮什么都不做，而租约已被消耗（`391-394`）、水位线还会被推进到 `now`（见上一条），当天不会再重试
- **建议**：`skillsOf` 增加与 `queryEmbedFailures` 同级的 store 失败计数；`experiencesOf` / `knowledgeOf` 区分「空结果」与「读取失败」；六处 `catch` 至少补一条 `warn`（`LoomWiring` 已示范）

### [一般][存量] StoreInvoker 用「抛 LoomException」判断网关未安装，注入网关的业务错误会被当成「没装」并回落到默认库

- **位置**：`f_llm/src/loom/StoreFunctions.cj:85-93`（`case None => try { LoomHostApi.callStore(...) } catch (error: LoomException) { LoomStoreGateway().call(...) }`）
- **来源**：存量（快照模式无基线）
- **判据**：review-checklist §11（错误分类错误导致走错分支）、§3（失败路径被当成「未安装」）
- **证据**：静态确定 —— `LoomHostApi.callStore` 只在未安装时抛 `LoomException`（`LoomHostApi.cj:170-179`）；而 `LoomStoreGateway.call` 对未列出的 op（`LoomStoreGateway.cj:358`）、`prompt.put` 缺 name（`298`）、`prompt.remove` 缺 version（`315`）、`evolution.*` 未装配（`342`）也抛同一个类型。`catch` 无法区分两者
- **描述**：模型通过 `loomStoreCall` 传了一个网关不支持的 `op`（或宿主注入的网关对某个 op 有业务校验），`invoke` 会把它当成「没装网关」，转而 `new` 一个按全局配置构造的默认网关再查一次库。后果：错误文案变成默认网关的（排障指向错误方向），更严重的是**读到了另一套存储**——注入的是测试库/隔离库时，会静默命中生产默认库；每次回落还会新建网关（`buildCount++`）
- **建议**：给 `LoomHostApi` 加 `hasStore(): Bool`（或让 `callStore` 返回 `?String`）判定「未安装」；兜底只兜「未安装」，业务异常原样上抛

### [一般][存量] Supervisor 把 status 查询异常当作「流程未编译」，永久摘除一条有效路由

- **位置**：`f_llm/src/loom/Supervisor.cj:184-192`（`let stillCompiled = try { service.status(chosen) == LoomStatus.COMPILED } catch (e: Exception) { false }`，随后 `unregister(chosen)`）
- **来源**：存量（快照模式无基线）
- **判据**：review-checklist §11（把不确定当确定）、§12.1（共享状态在错误路径上被破坏）
- **证据**：静态确定 —— 异常与「status != compiled」共用 `false`，紧接着 `unregister`（`324-340`）直接 `table.remove(at: found)`，没有恢复路径。`LoomService.status`（`LoomService.cj:150-155`）走 `registry.get`，是一次存储读取
- **描述**：数据库抖动/超时一次，就会把一条 `compiled` 的路由从内存表删除；路由表只在 `install` 播种（`105-107`）或流程状态再变化时由 `tap` 补回（`116-124`），本次进程内该流程从此不可派发，直到重启。设计意图是「摘掉真正陈旧的路由」，实现把「读不到」也算成「陈旧」
- **建议**：区分三态——`compiled` / 明确非 `compiled`（摘除）/ 查询失败（保留路由，直接返回 `NO_USABLE` 或带 `warn` 重试一次）；摘除只在明确读到非 `compiled` 时执行

### [一般][存量] SkillCatalog 技能侧编码失败就把该技能从检索结果剔除，与类注释「编码失败退回关键词」不符

- **位置**：`f_llm/src/loom/SkillCatalog.cj:160-167`（`case None => noteSkillFailure()`，技能未进入 `scored`）；类注释承诺见同文件 `42-43`，query 侧降级见 `168-172`
- **来源**：存量（快照模式无基线）
- **判据**：review-checklist §13 / §11（契约与实现不符）、§10（降级路径不对称）
- **证据**：静态确定 —— 类注释写「没装 embedder（**或编码失败**）时，退回词面包含度」，实现只在 **query** 编码失败时整体降级，**技能**侧失败只累加计数；全部技能编码失败时 `scored` 为空，`search` 直接返回空列表，完全不降级
- **描述**：向量模式下某个技能的正文触发编码器报错（超长、限流、非法字符），该技能在本次检索中彻底消失，其它技能正常返回——调用方看到的是「这个技能不相关」而不是「这个技能没被评估」。计数只加一个总数，无法定位是哪个技能
- **建议**：`case None =>` 分支对单技能走一次 `keywordScore` 兜底打分并计入 `scored`（与 query 侧对称）；`noteSkillFailure` 带上技能标识或改成去重集合，避免同一技能每次检索都累加

### [一般][存量] SkillImport.readAll 读取失败时文件句柄不关闭

- **位置**：`f_llm/src/loom/SkillImport.cj:121-126`
- **来源**：存量（快照模式无基线）
- **判据**：review-checklist §11（资源不对称：打开未关、异常跳过释放）
- **证据**：静态确定 —— `File(path, OpenMode.Read)` 之后紧接 `StringReader(file).readToEnd()`，`file.close()` 在正常路径末尾，没有 `try/finally`
- **描述**：`details.md` 读失败（磁盘错误、超大文件、编码非法）时 `readToEnd()` 抛错，句柄泄漏。调用链是 `SkillImportFunction.call`（`169-184`）→ 模型可反复触发的工具，每次失败泄漏一个 fd；`parse` 对 `skill.json` 的 `readAll`（`72`）同理
- **建议**：`try { StringReader(file).readToEnd() } finally { file.close() }`；同仓 `f_util/src/crc32_native_x86.cj:203-207` 是正确写法，可统一收敛成 `readTextFile(path)`

### [一般][存量] SkillGate 把模型调用失败当成「0 分」，旧版调用失败会让任意新版直接过关

- **位置**：`f_llm/src/loom/SkillGate.cj:90-105`（`catch(error: Exception) { '' }`，随后 `contains` 判命中）
- **来源**：存量（快照模式无基线）
- **判据**：review-checklist §11（错误处理缺失：失败被计为有效观测）、§3（异常吞成评分）
- **证据**：静态确定 —— 异常输出 `''` 与「模型真的没命中」在 `scoreOf` 里完全同形，`hits` 不增加，`oldScore` 得 0；`evaluate` 的判据是 `newScore < oldScore` 才拒（`78-81`）
- **描述**：A/B 门禁的意义是「新版不比旧版差」。旧版那一轮如果碰到限流/超时，`oldScore` 被记成 0，新版只要命中一条就通过并落库，`reason` 还会写成 `passed: 0.8 >= 0.0`——把一次基础设施故障当成了「新版更好」的证据。新版侧失败则相反，会把好版本误拒（并触发更长的失败冷却）
- **建议**：`scoreOf` 返回 `(score, failedCount)`；任一侧出现调用失败就本轮判定为 `inconclusive`（不落库、不写 `lastGatePassed=false`，让下一轮重试），不要用 0 分参与比较

### [一般][存量] SkillEvolutionJob.schedule 的 clock 默认返回 0，省略该参数后冷却期永不满足、水位线不推进

- **位置**：`f_llm/src/loom/SkillEvolutionJob.cj:386`（`clock!: () -> Int64 = {=> 0}`）、`389`、`399`；生效点 `SkillEvolutionPolicy.cj:71-78`、`SkillEvolutionJob.cj:234-242`
- **来源**：存量（快照模式无基线）
- **判据**：review-checklist §11（默认值导致功能静默失效）、§14.1（承诺「按水位线只处理新增」但默认参数下不成立）
- **证据**：静态确定 —— `decide` 里 `elapsed = now - lastEvolvedAt`，`now=0` 且 `lastEvolvedAt>0` 时为负，必然 `< required` 返回 `cooldown`；`markRun` 分支要求 `advanced > 0` 或 `now > 0`，两者都不成立时水位原地不动
- **描述**：生产装配显式传了 `clock: {=> DateTime.now()...}`（`LoomWiring.cj:217`），当前不触发；但这是 `public` 编排 API，任何省略该参数的调用方（示例、下游项目、测试桩）都会得到「第一轮之后永不演进」的任务，且没有任何提示。对比 `Supervisor.install` 的同类参数默认回落到 `DateTime.now()`（`Supervisor.cj:94-96`、`234-237`），项目内已有正确范式
- **建议**：默认值改为 `{=> DateTime.now().toUnixTimeStamp().toSeconds()}`；或在 `now <= 0` 时直接抛参数错误，避免静默空转

### [一般][存量] 演进水位线混用「秒级时间戳」与「记录 id」两种量纲

- **位置**：`f_llm/src/loom/SkillEvolutionJob.cj:294-300`（`at: if (saveTime > 0) { saveTime } else { id }`）；消费点 `218-242`（`advanced` 取 max 后 `markRun`）与 `247-257`（`fresh` 用 `at > since`）
- **来源**：存量（快照模式无基线）
- **判据**：review-checklist §11（量纲混用导致数据被永久跳过）
- **证据**：静态确定（量纲混用）；待确认（默认网关确实回 `saveTime`，见 `LoomStoreGateway.cj:442`；只有旧数据或别的网关实现才落到 id）
- **描述**：`lastRunAt` 一旦写成秒级时间戳（默认网关下必然如此），任何 `saveTime` 缺失的记录拿到的 `at` 是自增 id（几十~几千），`fresh()` 里 `at > since` 永远为假——这批经验从此不会被任何一轮处理，而 `advanced` 只前进不后退（`236`），水位也不会回落到能覆盖它们的量级。注释把 id 当「退化排序」用，却与时间戳放进了同一个比较域
- **建议**：`saveTime` 缺失时置 `0`（`fresh` 已有「`at==0` 始终参与」的约定，`253`）；或把 `ExperienceItem` 拆成 `(at, seq)` 两字段，水位只比 `at`

### [一般][存量] 演进台账用 `split(':')[0]` 反解技能名，created 行与含冒号的标题被错键

- **位置**：`f_llm/src/loom/SkillEvolutionLedger.cj:62-73`（第 69 行）；行格式来自 `SkillEvolutionJob.cj:171`（`'${skill.title}: v…'`）与 `189`（`'${draft.title} (id=${nextId})'`）
- **来源**：存量（快照模式无基线）
- **判据**：review-checklist §11（数据派生错误，`history()` 查不到）
- **证据**：静态确定 —— `created` 行没有冒号，`title` 取到整行 `爬虫助手 (id=2)`；`evolved`/`skipped` 行标题自身含 `:` 时只取前半段
- **描述**：`SkillEvolutionLedger.history(store, '爬虫助手')`（`57-60`）依赖 `title` 列精确匹配，新建技能的记录永远查不到；标题含冒号时同一技能的记录会落到两个键上。审计表是演进唯一的留痕，键错等于留痕失效
- **建议**：让 `SkillEvolutionReport` 携带结构化条目（`title` + `action` + `detail`），不要「拼字符串再反解」；至少在 `save` 里用显式分隔符（参考 `StepSourceCodec` 的 `\u0001`）

### [一般][存量] SkillNamer 的 24「字」上限按 UTF-8 字节判定，8 字以上的中文标题被判非法

- **位置**：`f_llm/src/loom/SkillNamer.cj:44`（`MAX_TITLE = 24`）、`90-92`（`if(Int64(title.size) > MAX_TITLE)`）；契约源：同文件 `59-61` 的 prompt「不超过 24 字」、`f_llm/README.md:628`、`f_llm/doc/f_llm.md:519`
- **来源**：存量（快照模式无基线）
- **判据**：review-checklist §11（语义与契约不符）、§13（文档与实现口径不一致）
- **证据**：静态确定 —— `String.size` 的契约是「UTF-8 编码后的字节长度」（`api/std/core/structs/string/prop-size.md`：`public prop size: Int64`，获取字符串 UTF-8 编码后的字节长度）。中文按 3 字节/字，24 字节 ≈ 8 汉字
- **描述**：模型返回「爬虫限速重试助手」（8 字 = 24 字节，边界内）之外，任何 9 字以上的中文标题（27 字节）都会被判为超长并返回 `None`；调用方只看到 `rejected: candidate cluster: model did not return a valid name`（`SkillEvolutionJob.cj:191`），误以为是模型输出非法。结果是中文语境下大量合法标题无法建技能，且没有任何日志能说明真实原因
- **建议**：改成按字符数判定（`title.toRuneArray().size` 或 `title.runes().count()`），或把常量改名为 `MAX_TITLE_BYTES` 并把 prompt/README 的「24 字」改成「24 字节」；拒绝原因区分「超长」与「格式非法」

### [一般][存量] 新技能建库前不查重，而演进全链路以 title 作为技能身份，同名技能会互相污染

- **位置**：`f_llm/src/loom/SkillNamer.cj:49-99`（`propose` 只收 `chat` 与经验，拿不到现有技能）、`f_llm/src/loom/SkillEvolutionJob.cj:184-193`（直接 `emit(Skill(nextId, draft.title, …))`）、`118-121` / `126-129` / `134`（`owner`、`failureCounts`、`state` 全以 `skillTitle` 为键）；存储契约 `f_llm/src/store/StoreContracts.cj:93-99`（`upsert(skill)` 按 id，无 title 唯一约束）
- **来源**：存量（快照模式无基线）
- **判据**：review-checklist §14.1（承诺了但没实现）、§11（契约与实现不符）
- **证据**：静态确定 + 双证 —— 承诺源：`f_llm/doc/f_llm.md:519`「名字不能与已有技能冲突」；缺失证据：`propose` 签名无 `skills` 参数，`SkillEvolutionJob` 建技能处无 title 比对，`FStoreSkillStore.upsert`（`f_llm/src/store/FStoreMetaStore.cj:246-251`）只写 `id` 主体 + title 索引，不拒绝重复 title
- **描述**：一旦出现两个同名技能（模型起名重复、人工导入后又被演进建一个），`owner` / `failureCounts` / `EvolutionStateStore` 三个 title 键容器会把两条技能的素材与成功率合并，`evolved` 只落其中一条 id，另一条从此拿不到自己的经验；`SkillMatcher` 的 `skillVectors[skill.title]`（`SkillMatcher.cj:121`）也会让同名技能共用一份向量。这类错配不报错，只表现为「某技能一直不演进 / 演进内容跑偏」
- **建议**：`SkillMatcher` 与状态存储改用 `skill.id` 作键（`SkillAssignment` 增加 `skillId`）；`SkillEvolutionJob` 在建技能前按 title 查一遍现有技能，冲突则并入既有技能；`SkillStore` 层补「title 唯一」的显式约束

### [轻微][存量] SkillCandidate.score 构造后仓内无人读取，聚类阶段却为它多算一次相似度

- **位置**：`f_llm/src/loom/SkillMatcher.cj:192-198`（第 195-196 行 `SkillCandidate(bucket, similarity(embedder, bucket[0].content, bucket[bucket.size - 1].content))`）；字段定义 `51-58`
- **来源**：存量（快照模式无基线）
- **判据**：review-checklist §1（读了不用：派生值无消费）
- **证据**：静态确定 —— 全仓 `grep` 只有构造点一处引用，`SkillEvolutionJob` 只用 `candidate.experiences`；`score` 由「首元素 vs 末元素」得出，本身也不代表簇质量
- **描述**：每个候选簇多算一次相似度（有 embedder 时是 2 次编码 + 余弦），结果没有任何消费方。字段是对外可达的 `public let`，不按死代码处理，但这份计算是无收益的
- **建议**：删掉该参数（或改为簇内平均相似度并真正用于 `SkillNamer` 的筛选门槛）；只保留 `experiences`

### [轻微][存量] Supervisor.register 返回 `?SupervisorRoute` 但永远返回 `Some`，调用方全部丢弃

- **位置**：`f_llm/src/loom/Supervisor.cj:302-322`（第 321 行 `Some(route)`）；调用方 `106`、`121`、`225` 均为 `let _ = …register(...)`
- **来源**：存量（快照模式无基线）
- **判据**：review-checklist §11（契约与实现不符）、§1（恒真分支）
- **证据**：静态确定 —— 函数体所有出口都是 `Some(route)`，没有 `None` 路径；注释只写 `@throws LoomException 流程名为空`
- **描述**：`Option` 让调用方以为「同名可能返回 None」，实际语义是「同名覆盖」。返回值既没被判断也没被使用，读代码时反而制造疑问
- **建议**：返回类型改 `Unit`，或返回被替换的旧 `SupervisorRoute`（幂等覆盖时才有信息量）

### [轻微][存量] Supervisor.install 先发布单例、后播种路由，启动窗口内 `routable()` 为空

- **位置**：`f_llm/src/loom/Supervisor.cj:102-108`（`installed = Some(supervisor)` 在 `for (flow in flows) { register(...) }` 之前）；读取点 `134-140`、`354-364`
- **来源**：存量（快照模式无基线）
- **判据**：review-checklist §12.1（发布逸出：未初始化完的对象先交给其它线程）
- **证据**：静态确定 —— `current()` 只拿 `staticMutex`，可在播种循环执行期间取到该实例；`routable()` 此时读到空表
- **描述**：并发首请求正好落在 `install` 期间时，`dispatch` 选不到任何流程并返回固定文案「没有可完成此工作的流程」——把「启动未完成」表现成「没有可用流程」。窗口只有几十次 `ArrayList.add`，但重启期的探活/预热请求最容易撞上
- **建议**：先在私有实例上 `register` 完全部 `flows`，最后一步再发布 `installed`

### [轻微][存量] 三个工具类各留一个逐字相同的 `invoke` 转发

- **位置**：`f_llm/src/loom/StoreFunctions.cj:73-76`、`144-147`、`215-218`；共享实现 `StoreInvoker.invoke`（`84-95`）
- **来源**：存量（快照模式无基线）
- **判据**：review-checklist §2（只改类型名的重复实现）
- **证据**：静态确定 —— 三处函数体均为 `StoreInvoker.invoke(injected, kind, op, payload)`，前两处连参数名都相同
- **描述**：注释说「三个工具共用一份，避免能力拷贝」，共享点其实已落在 `StoreInvoker` 上，这三个包装层没有差异点，只多一层栈与一个阅读分叉
- **建议**：`call` 中直接调用 `StoreInvoker.invoke(injected, …)`，删掉三个 `private func invoke`

### [轻微][存量] JSON 字符串字段提取在四处各写一遍

- **位置**：`f_llm/src/loom/SkillEvolutionJob.cj:367-375`（`strField`）、`SkillGate.cj:145-154`（`SkillSamples.strOf`）、`SkillNamer.cj:125-134`（`fieldOf`）、`SkillImport.cj:128-137`（`strOf`）；同族数值版 `SkillEvolutionJob.cj:360-365`（`intField`）
- **来源**：存量（快照模式无基线）
- **判据**：review-checklist §2（字面量复制：同一段「get → as JsonString → 否则空串」）
- **证据**：静态确定 —— 四段实现对「缺键 / 非字符串 / null」都返回 `''`，语义一致，只有函数名不同
- **描述**：「宽容解析」本身是行为契约（当前策略是静默空串）。四处独立演进后，一处加 `trimAscii`、一处改成抛错，同一份 JSON 在不同入口就会解析出不同结果
- **建议**：收敛到模块内一个 `JsonFields` 工具（或 `f_data` 已有的便捷取值），四个调用点统一；把「缺键是否算错误」的决策写在一处

### [轻微][存量] 相似度计算与 samples 解析各存在两套实现

- **位置**：`SkillCatalog.cj:326-343` 与 `SkillMatcher.cj:237-254`（`cosine` 逐行相同）；`SkillCatalog.cj:306-324`（`runeScore`）与 `SkillMatcher.cj:268-289`（`runeCoverage`）；`SkillGate.cj:109-143`（`SkillSamples.of`）与 `SkillNamer.cj:101-123`（`samplesOf`）
- **来源**：存量（快照模式无基线）
- **判据**：review-checklist §2（只改类型名 / 近似重复）
- **证据**：静态确定 —— 两份 `cosine` 连「size 取 min、任一范数为 0 返回 0」都一致；两份 rune 覆盖唯一差异是 `runeCoverage` 跳过空格与换行；两份 samples 解析的校验条件相同（`input`/`expect` 非空才收）
- **描述**：`cosine` 两份拷贝都静默截断到较短维度，要改成「维度不符返回 0」得改两处；rune 口径不一致会让「标题覆盖率」与「正文覆盖率」在同一阈值下不可比（`SkillCatalog.cj:289-296` 同时用两个分数与 0.5 比较）
- **建议**：`cosine` / `runeCoverage` 收敛为模块内 `Similarity` 工具，空格/换行策略参数化并在调用点显式传值；samples 解析保留 `SkillGate` 一份，`SkillNamer` 复用

### [轻微][存量] PostgresLoomStore 与 MySqlLoomStore 的 4 个方法逐行同形

- **位置**：`f_llm/src/loom/SqlLoomStore.cj:124-155`（PG）与 `158-189`（MySQL）
- **来源**：存量（快照模式无基线）
- **判据**：review-checklist §2（只改类型名）
- **证据**：静态确定 —— `save` / `get` / `list` / `remove` 的方法体逐行对齐，唯一差异是 `dao<PostgresLoomDAO>('postgres')` 与 `dao<MySqlLoomDAO>('mysql')`
- **描述**：行映射已由 `LoomRowMapper` 共享，剩下这层纯粹是方言类型的分叉；`dao<T>` 需要具体类型，泛型无法直接消除，所以列为结构性重复而非缺陷。真正的风险是「只改了一边」——例如将来给 `remove` 加审计日志，很容易漏掉另一侧
- **建议**：若 `dao<T>` 支持按名称取 DAO，收敛成一个以 `(dialect, dao)` 为参数的内部实现；否则在两个类各留一行注释指向对侧，并在评审清单里登记「双写」

### [轻微][存量] keywordScore 注释里的中文命中示例在 0.5 阈值下不成立

- **位置**：`f_llm/src/loom/SkillCatalog.cj:292-296`（注释「「帮我写日报」命中「日报助手」靠这条」，随后 `byTitle >= 0.5f64`）
- **来源**：存量（快照模式无基线）
- **判据**：review-checklist §11（语义与注释不符）
- **证据**：静态确定 —— 查询「帮我写日报」去重后 5 个字，标题「日报助手」只覆盖「日」「报」2 个 → `runeScore = 0.4 < 0.5`，该分支不会生效；此时 token 分支也已得 0（无空格分词后整串不包含）
- **描述**：注释给出的口径与实现不一致，读者会以为短中文标题能被长描述命中，实际只有查询与标题重合度 ≥ 50% 才生效。这解释了为什么「日报助手」这类短标题在长句查询下检索不到
- **建议**：把示例换成能通过阈值的真实例子，或按「标题被查询覆盖的字数 / 标题长度」反向计算（对短标题更敏感），并补一条对应单测

### [轻微][存量] ownedBy 只做字符串前缀匹配、不校验分隔符，命名空间 'a' 会命中 'a:b' 的文档

- **位置**：`f_llm/src/loom/SkillEvolutionJob.cj:314-316`（`docId.startsWith('loom:${userId}:${namespace}:')`）
- **来源**：存量（快照模式无基线）
- **判据**：review-checklist §11（边界校验缺失）
- **证据**：静态确定（字符串层面）—— `ownedBy('loom:7:a:b:flow:1', 7, 'a')` 返回 `true`；待确认（`namespace` 是否允许包含 `:`，当前无校验）
- **描述**：同一用户下命名空间互为前缀时（`a` 与 `a:b`），`a` 的演进任务会把 `a:b` 的知识也算进素材池；`userId` 侧因为有冒号边界不受影响。注释里「避免跨租户串味」只覆盖了用户维度
- **建议**：把 docId 解析成 `(userId, namespace, flow, seq)` 段后逐段比对，或在写 docId 时对 namespace 做转义/编码

<!-- 第 18 部分 -->

### [严重][存量] #1 `FaithfulMemoryImpl.summarise` 把"按 session 主序"的键序当成"按时间序"，`break` 让字母序靠后的会话永远不被摘要

- **位置**：`f_llm/src/memory/FaithfulMemory.cj:77-79`（`if(time >= earlierThan){ break }`）、`:68-70`（前缀遍历）、`:72-76`（键解析）、`:100-102`（循环结束，无收尾 flush）；键构造在 `:42-44`
- **来源**：存量（快照模式，无基线可比）
- **判据**：review-checklist §11「逻辑错误 / 边界」、§6.4（已知结构却按错误假设做提前退出）
- **证据**：静态确定 —— 内容键格式是 `'FaithfulMemory:${session}:${time}:${role}'`（`:43`），前缀遍历的底层是 `ConcurrentSkipListMap`（`f_store/src/MemTable.cj:20`）经 `PrefixIterator` 归并（`f_store/src/PrefixIterator.cj:19-45`，比较器 `mergeHeapCmp` 见 `f_store/src/SSTableMerger.cj:30-35`，注释明确"全局有序输出（按 key 字典序升序）"），所以遍历顺序是 **session 主序、session 内时间序**，不是全局时间序。举 4 条键：
  `A:01-01`、`A:01-02`、`B:01-01`、`B:01-02` → 遍历顺序即此。若 `earlierThan = now-8h`，处理到 `A:01-02`（新于阈值）就 `break`，**整个 B 会话一条都读不到**，即使 `B:01-01` 早已超过阈值。结论：一次运行只覆盖到「第一个含新消息的 session」为止，该 session 之后的字母序会话在任何一次运行里都达不到。
- **描述**：`break` 的语义前提（"后面都更新"）只在全局时间序下成立。实际后果有两层：
  1. **功能静默丢失**：每次运行只处理到"字母序最靠前、且其内部出现第一条新消息"的那个 session 为止，它之后的会话一条都读不到（只有当前面若干会话全部是旧消息时，它们才会被依次处理）；读不到就没有任何日志，因为 `fn` 只在 `else if` 分支才被调用。
  2. **末批永不 flush**：循环体内只在"session 变化"时 flush（`:86-99`），循环结束后（`:100-102`）没有对 `messages` 再 flush 一次，因此触发 `break` 的那个 session 已累积的消息既没摘要、也没清理，只能等下一次运行重新读一遍（叠加 #2 的清理失效 ⇒ 每天重复调用 LLM）。
- **建议**：把"时间窗"判断改成"跳过而不终止"（`if(time >= earlierThan){ continue }` 语义上仍不对，因为同一 session 内新旧混排）；正确做法是先按 session 分组（遍历完整个前缀、把 `session → [(time, role, msg)]` 收进内存，或用两级键 `FaithfulMemory:{time}:{session}:...` 让时间成为主序），再对每个"全组都早于阈值"的 session 调 `fn`；循环结束补一次收尾 flush。分组实现要给出 session 数量上限，避免把整库拉进内存（见 §5）。

### [严重][存量] #2 摘要成功后按"当前条目的时间"删内容键 —— 旧内容键永不删除，存储无界增长且每天重复摘要

- **位置**：`f_llm/src/memory/FaithfulMemory.cj:86-92`（关键在 `:90` `store.remove(contentKey(timeStr, session, m.role))`）
- **来源**：存量（快照模式，无基线可比）
- **判据**：review-checklist §11「读了不用 / 用错变量」、§5「无界容器 / 全局集合只增不减」
- **证据**：静态确定 —— `timeStr` 在 `:74` 取自**当前这一条**键（即"下一个 session 的第一条"），而 `messages` 里装的是**上一个 session** 各条消息；`contentKey(time: String, session, role)`（`:42-44`）把三者拼成键。于是 `remove` 拼出的键是"旧 session + 新时间"，这个键从不存在，`Store.remove` 是幂等空操作（`f_store/src/Store.cj:136-146`，写一条 tombstone，不报错）。同一循环里 `duplicateKey` 用的是 `m.content`，是对的（`:89`），只有内容键删错。
- **描述**：会话被"摘要"之后，内容键全部留在 `llm_faithfulMemoryPath` 指向的 LSM 存储里，只有重复键（`DuplicateMemory:*`）被删。后果：
  1. 存储只增不减（`#1` 修好之后就是全量会话累积）；
  2. 这些内容键下次运行仍满足 `time < earlierThan`，会被再次读出来、再次调 LLM、再次 `remember(session, jsonstr)`（`Memory.cj:81`）写一条 `kind=session` 的记忆 —— **重复的记忆数据 + 重复的 token 成本**；
  3. 因为没有正确删除，`add` 的"重复内容"保护只对 `duplicateKey` 生效，对摘要侧完全不起作用。
- **建议**：把每条消息自己的时间一起带进 `messages`（改成 `ArrayList<(String, Role, String)>` 或一个小 struct），flush 时用该条自己的 `time` 删；或者反过来把 `time` 编进 `ChatMessage` 的附属结构。补一条用例：同一 session 写入 3 条消息 → 触发 summarise → 断言 `store.prefix('FaithfulMemory'.unsafeBytes())` 已空（或只剩未到阈值的条目）。

### [严重][存量] #3 内容键只精确到毫秒且包含 role —— 同毫秒同角色的两条消息互相覆盖，记忆永久丢失

- **位置**：`f_llm/src/memory/FaithfulMemory.cj:36-38`（`FULL_DATE_FORMAT = 'yyyyMMddHHmmssSSS'`，`current(now)`）、`:53`（`contentKey(DateTime.now(), ...)`）、`:55-58`（`contains` 后 `add`）
- **来源**：存量（快照模式，无基线可比）
- **判据**：review-checklist §11「边界 / 数据丢失」、§12.1「检查-然后-写入」
- **证据**：静态确定 —— 键 = `session + 毫秒时间戳 + role`，对 `(session, role)` 相同、时间戳落同一毫秒的两条消息，键完全相同；`Store.add` 是覆盖写（`f_store/src/Store.cj:97-107` 返回旧值、`MemTable.add` 直接 `ConcurrentSkipListMap.add` 覆盖），所以后写的一条把前一条的 value 直接替换掉，前一条消息在存储里不存在。触发路径现成：`Memory.add(session, all!)`（`Memory.cj:145-151`）在**一个紧循环**里连续写同一事件的全部消息，`messages` 里连续出现同 role（多个 `tool` 消息、多段 `assistant` 消息）很常见，两次 `store.add` 落在同一毫秒并不需要极端条件。
- **描述**：除了覆盖，`:55-58` 的 `contains(duplicateKey)` → `add` 也是非原子的"检查-然后-写入"：两个事件并发写同一条内容时会各写一条内容键 + 一条重复键（重复键相同，第二次互相覆盖，无害；内容键不同毫秒则产生两条重复记忆）。**碰撞发生率需实测**（把 `add` 的时间戳与内容打点统计同毫秒同 role 的比例），但"键不唯一 ⇒ 必丢一条"是静态成立的。
- **建议**：键里加单调序号或内容哈希（例如 `...:${time}:${role}:${md5(content)[0..8]}`），并在 `Store` 之上不再依赖"毫秒级时间戳唯一"；或直接把消息写成 `add` 返回的 `sequence`（`Store.add` 内部有 `AtomicInt64` 序列号，但未暴露）。同时把接口注释里的"同 session 同 role 同毫秒只保留最后一条"写清楚，或改成 `ArrayList` 值追加。

### [严重][存量] #4 每日摘要跑在 `Timer` 任务里且没有任何异常保护 —— 一次失败就让摘要功能永久失效

- **位置**：`f_llm/src/memory/Memory.cj:26-29`（`timer = Timer.after(nextSummarisingTime()) { faithful.summarise(Memory.summarise); nextSummarisingTime() }`）；异常源：`Memory.cj:70`（`.messages[0]`）、`:78`（`JsonValue.fromStr(jsonstr)`）、`:42-45`（`lookup` 未命中即抛）、`FaithfulMemory.cj:55/89`（`Store` 抛 `StoreClosedException` 等）、`MemoryExtractor.cj:28/38/41`（`asObject`/`asString`/`asArray` 抛 `JsonException`）
- **来源**：存量（快照模式，无基线可比）
- **判据**：review-checklist §12.1「异步语义：`Future` 异常被吞 / 定时任务」、§3「静默失效」，依据标准库文档 `std/sync/sync_package_api/sync_package_classes.md:10750-10792`（`Timer.after`）与 `:10726-10748`（`class Timer` 注意事项）
- **证据**：静态确定 —— 文档原文：「[Timer] 不会主动捕获关联 Task 抛出的异常。只要 Task 有未被捕获的异常，[Timer] 就会失效。」`Memory.summarise` 内部没有任何 `try`，`FaithfulMemoryImpl.summarise` 也没有，异常会直接穿出 lambda，`Timer` 从此不再调度，进程不重启就再也不同步摘要，且**没有任何日志**（`atExit(timer.cancel)` 只是退出时取消，不会重建）。
  可达的抛出点按概率排序：`LLM.chatByName(...)` 网络/鉴权失败抛 `LLMException`；模型返回里没有代码围栏时 `indexOf/lastIndexOf` 走 `None` 分支是安全的，但围栏内不是合法 JSON 时 `JsonValue.fromStr` 抛 `JsonException`；`respmsg` 的 `messages` 为空时 `[0]` 抛越界；`llm_summarisingActionKind` 配成 `experience`/`individuality` 时 `lookup<ExperienceFinder>()` 抛 `BeanException`（见 #9）。
- **描述**：这是"后台功能静默死亡"型缺陷：白天一切正常，第二天发现经验/摘要不再更新，也没有告警可查。
- **建议**：把任务体包成 `try { ... } catch(e: Exception) { LoggerFactory...warn(...) }`，并把"是否继续调度"与"本轮是否成功"解耦（失败也返回下一次延迟）；`Memory.summarise` 内部再按阶段细化：LLM 调用失败只 warn、JSON 解析失败只 warn 并返回 `false`（让 `FaithfulMemoryImpl` 保留消息）。同时把 `.messages[0]` 改成 `match` 取首条，`:78` 的 `JsonValue.fromStr` 包 `try`。

### [一般][存量] #5 用会抛异常的 `asString` / `asArray` / `asObject` 解析模型输出，形状稍偏就整条链路抛错

- **位置**：`f_llm/src/memory/MemoryExtractor.cj:26-29`（`json.asObject()`）、`:38`（`jsonobj.get(key)?.asString().value`）、`:41-47`（`?.asArray().getItems()`）
- **来源**：存量（快照模式，无基线可比）
- **判据**：review-checklist §11「空值 / 类型不符未处理」、§10 正确性（外部输入未校验）
- **证据**：静态确定 —— 语义以 `f_data/src/json/JsonValue.cj:53-67` 为准：`asString` / `asArray` / `asObject` 在类型不符时 **`throw JsonException`**（不是返回 `Option`）。而这里的 `jsonobj` 完全来自 LLM 结构化输出的 `JsonValue.fromStr`（`Memory.cj:78`），字段缺失走 `?? ''` 是安全的，字段类型不符（`"steps": "..."`、`"purpose": 1`、`lessons: [ "字符串" ]`）则直接抛。叠加 #4 就是"模型偶尔不按 schema 输出 ⇒ 当天之后摘要永久停止"。
- **描述**：提示词（`MemoryExtractor.cj:99-123`）已声明"严格按照 JSON 格式返回"，但没有强约束（非 `response_format` 校验），实际模型抖动很常见。
- **建议**：改成 `jsonobj.get(key)` + `match(item){ case Some(x: JsonString) => x.value; case _ => '' }` 的形态（参照 `f_llm/src/loom/ToolCatalog.cj:104-119` 的 match 风格），`extractArray` 用 `match` 判 `JsonArray` 后逐项过滤非字符串。

### [一般][存量] #6 模型回答里找不到代码围栏时 `summarise` 仍返回 `true`，消息被当作"已摘要"丢弃

- **位置**：`f_llm/src/memory/Memory.cj:71-83`（`if (let Some(start) <- ... && let Some(end) <- ...)` 之后无条件 `true`）
- **来源**：存量（快照模式，无基线可比）
- **判据**：review-checklist §3「空实现 / `case None => ()` 把错误吃掉」、§11「失败路径当成功」
- **证据**：静态确定 —— `respmsg` 只有 1 个 ` ``` `（模型没按格式输出）时 `lastIndexOf('```', start+3)` 返回 `None`（文档 `std/core/core_package_api/core_package_structs.md:7448-7463`：从 `fromIndex` 起找不到即 `None`），整个 `if` 不成立，跳过 `extractor.extract` 与 `remember`，函数仍 `return true`。调用侧 `FaithfulMemory.cj:86` `else if(fn(...))` 为真 ⇒ 直接进入"删除内容键"分支（虽然键删错了，见 #2）。
- **描述**：失败被表示为成功，且比 #5 更隐蔽（不抛异常、不打日志）。同类小问题：`sub.startsWith('json')` 后 `sub[4..]`（`:73-77`）在 `sub == 'json'` 时得到空串，`JsonValue.fromStr('')` 抛异常（回到 #4 的链路上）。
- **建议**：解析失败返回 `false` 并 `warn` 一条带 `session` 与回复前 200 字符的日志；`sub[4..]` 加 `sub.size > 4` 判断。

### [一般][存量] #7 `ToolScope` 白名单校验没有任何生产调用点 —— 文档承诺的"只能收窄，不能凭空引入"未接线

- **位置**：`f_llm/src/loom/ToolScope.cj:36-55`（`check`）、`:57-82`（`verifyPlan`）；承诺源 `f_llm/doc/f_llm.md:195-196`、`f_llm/README.md:1063`
- **来源**：存量（快照模式，无基线可比）
- **判据**：review-checklist §14.1「接线缺失」、§14.1「承诺了但没实现」
- **证据**：静态确定 —— 全仓 `grep ToolScope`（排除 `.worktrees`）只命中 3 处：定义文件、`f_llm/src/loom/Plan_test.cj`、以及本文件自身；`LoomRunner`/`LoomService`/`Planner` 里没有任何 `ToolScope.` 调用，也没有等价的 `flow.tools` 白名单过滤（`grep 'flow.tools'` 仅命中 `LoomService.cj:81,95` 的写入与存储层）。文档却写：「流程计划里用 `tools` / `mcps` 声明可用集合，`ToolScope.check(kind, requested, available)` 做白名单校验：**只能收窄，不能凭空引入**——声明了未注册的名字直接抛 `LoomException`」。
- **描述**：`ToolScope` 是 public API（README 已登记），测试也覆盖了三条分支，但运行期没有任何一处调用它，于是"计划里写了未注册工具"不会在编排/执行阶段被拦下，只能等模型真的调用该工具时由 `FunctionMediator` 抛 `FunctionNotFoundException`。这是"安全阀装了但没接管路"。
- **建议**：在 `LoomService.confirmFlow`/`Planner.plan` 的校验段落里接一次 `ToolScope.check('tool', request.tools, FunctionMediator.names())` 与 `ToolScope.check('mcp', request.mcps, <mcp 名单>)`，对已编译计划在 `dispatch` 前跑 `verifyPlan`；若设计上是"由宿主应用自行接线"，则在 README 与 doc 里写明调用时机，避免被当成已生效的保障。

### [一般][存量] #8 `McpToolSource.load()` 中途失败会留下半张工具表，重试又全部撞重名

- **位置**：`f_llm/src/mcp/McpToolSource.cj:65-73`
- **来源**：存量（快照模式，无基线可比）
- **判据**：review-checklist §11「资源/状态不对称」、§14.1「半成品」、fountain-baseline §4（同名注册直接失败，不做隐式优先级）
- **证据**：静态确定 —— 循环里逐个 `FunctionMediator.register(...)`，`register` 对重名直接抛 `FunctionCallingException`（`f_llm/src/tool/FunctionMediator.cj:55-64`）。假设第 3 个工具名超 64 字符（`ToolName.mcp` → `validate` 抛，`ToolName.cj:51-55`），前 2 个已经进了全局表，`load()` 抛出，调用方拿不到任何"已注册了几个"的信息；下一次对同一 alias 重试时第 1 个就撞重名，永远起不来。
- **描述**：同名注册"启动直接失败"是对的（符合 baseline §4），但缺"失败即回滚"，把一次配置错误变成了不可自愈的全局状态污染（同进程内无法补救）。测试 `McpToolSource_test.cj:126-136` 正好只覆盖了"抛异常"，没有断言"表里没有残留"。
- **建议**：先在局部 `ArrayList` 里把全部 `(name, calling)` 准备好（名字冲突在本地判），再逐个 `register` 并记录已注册名字，`catch` 时把它们 `unregister`（需要新增 `FunctionMediator.unregister`）或干脆改成"一次注册一批"的原子接口。至少把已成功的数量写进异常消息。

### [一般][存量] #9 `llm_summarisingActionKind` 的两个取值在仓内没有任何 `MemorySummaryFinder` 实现，配了就抛 `BeanException`（且落在定时任务里）

- **位置**：`f_llm/src/memory/Memory.cj:40-46`；承诺源 `f_llm/README.md:800`、`f_llm/doc/f_llm.md:573`
- **来源**：存量（快照模式，无基线可比）
- **判据**：review-checklist §14.1「配置项被读取却无人实现」、§3「开关打开后走进失败分支」
- **证据**：需实测 / 待确认 —— `grep '< ExperienceFinder|< IndividualityFinder|< MemorySummaryFinder'`（排除 `.worktrees`）在本仓零命中：三个接口（`f_llm/src/finder/MemorySummaryFinder.cj:20-27`）只有声明，没有实现类；而 `lookup<T>()` 未命中即抛 `BeanException`（`f_bean/src/lookup.cj:26-30`）。缺的信息：是否有下游仓库（应用侧）提供这些 bean。若没有，则 `llm_summarisingActionKind=experience|individuality` 一定抛异常，并经 #4 使定时器失效。
- **描述**：README 只写"经验总结模型与动作类型"，既没写合法取值，也没写"需要宿主提供 `MemorySummaryFinder` 实现"，按文档配置无法用起来。
- **建议**：README / doc 补"取值：空（关闭）、`experience`、`individuality`、或任意 bean 前缀；前两者要求宿主注册对应 `*Finder` 实现"；`Memory.extractor()` 改用 `lookupOption` 并在缺失时 `warn` + 返回 `None`（不要让配置错误升格为定时器死亡）。

### [一般][存量] #10 `KnowledgeEntity.queryConf` 对可能为空的数组直接取 `[0]`

- **位置**：`f_llm/src/model/entity/KnowledgeEntity.cj:41`（`conf = finder([LLM_TYPE_SEARCH])[0]`）
- **来源**：存量（快照模式，无基线可比）
- **判据**：review-checklist §11「空集合未处理 / 直接取 `[0]`」
- **证据**：静态确定 —— `finder` 是调用方注入的 `(Array<LLMType>) -> ArrayList<LLMConf>`，返回值没有任何"非空"约束；`[0]` 在空 `ArrayList` 上抛越界。同文件 `:40` 的 `if(list.size < params.maxResults)` 只说明"还需要查配置"，不保证 `finder` 有候选（模型配置缺失/全部熔断时就是空的）。
- **描述**：知识检索路径上，候选模型表为空会让整个 `KnowledgeEntity` 构造链抛越界而不是走"无配置"降级。
- **建议**：先 `let found = finder([LLM_TYPE_SEARCH])`，再 `if(!found.isEmpty()){ conf = found[0] }`（或 `match(found.first())`）；无候选时 `conf` 保持 `None`，由 `save`/调用方按"没有可用模型"处理。

### [一般][存量] #11 `KnowledgeEntity.save` 与 `search` 的完成判据不一致（`==` vs `<`），`list.size > maxResults` 时 `remoteResults.getOrThrow()` 必抛

- **位置**：`f_llm/src/model/entity/KnowledgeEntity.cj:52`（`if(list.size == params.maxResults)`）、`:46-48`（`search` 只在 `list.size < maxResults` 时才赋值）、`:55`（`remoteResults.getOrThrow()`）
- **来源**：存量（快照模式，无基线可比）
- **判据**：review-checklist §11「契约与实现不符 / 空值未处理」、§2「近似重复但一块少了边界判断」
- **证据**：待确认 —— `list` 来自构造时的 `searchExecutor(params, keywordsEmbedding)`（`:32`），类内**没有任何**"截断到 `maxResults`"的代码，所以 `list.size > maxResults` 是可达状态；此时 `search()` 不会设置 `remoteResults`（判据是 `<`），`save()` 也不会早退（判据是 `==`），于是 `None.getOrThrow()` 抛 `NoneValueException`。缺的信息：`searchExecutor` 的实现是否保证 `<= maxResults`（本仓内 `KnowledgeEntity` 无构造点，无法从调用方取证）。
- **描述**：同一"是否还需要外部检索"的语义在两处用了不同比较符，属于典型的近似重复导致的行为漂移。
- **建议**：抽一个 `private prop needMore: Bool { list.size < params.maxResults }`，`search`/`queryConf`/`save` 三处统一用它；`save` 内对 `remoteResults` 用 `match` 处理 `None`（返回 `list` 并 `warn`）。顺带把 `:63` 的 `let params = EmbeddingParam(...)` 改名（它遮蔽了成员 `params`，`:85` 又靠作用域回指成员，读起来极易误判）。

### [一般][存量] #12 `listTools` 不校验 `offset`/`limit`，模型给负偏移直接越界

- **位置**：`f_llm/src/loom/ToolFunctions.cj:54-73`（`:55-56` 解析、`:60-62` 循环条件与 `all[index]`）
- **来源**：存量（快照模式，无基线可比）
- **判据**：review-checklist §11「边界差一 / 越界」、§10 安全性（外部输入未校验）
- **证据**：静态确定 —— `Int64.tryParse(params.offset.trimAscii()) ?? 0` 对 `"-1"` 返回 `-1`；`while(index < Int64(all.size) && taken < limit)` 在 `index = -1` 时成立，`all[-1]`（`ToolFunctions.cj:57` 从 `ToolCatalog.entries()` 取到的 `ArrayList`）抛 `IndexOutOfBoundsException`。`limit` 为负则循环不执行、返回 `'[]'`（静默空结果）；`limit` 为超大值则返回全部（无上限，`ToolFunctions.cj:73` 的字符串随之膨胀）。
- **描述**：参数来自模型生成的 tool-call 实参，属不可信输入。当前后果是"工具抛错 → 由 `LLMToolLoop` 回填错误文本"，不会崩进程，但错误信息是越界栈而不是"参数非法"，模型很可能反复重试同一个负偏移。
- **建议**：`offset = max(0, offset)`、`limit` 夹到 `[1, 200]`，非法值直接返回 `FunctionResult(event: params.nextEvent, result: '...invalid offset/limit...')`，与 `:105-107` 的 `requires query` 风格一致。

### [一般][存量] #13 记忆开关关闭（默认）时仍为每个事件 `spawn` 线程并拼装全部消息文本

- **位置**：`f_llm/src/memory/Memory.cj:145-151`（`spawn { for (m in all) { add(session, m.role, generateContent(m)) } }`）、`:22-34`（关闭时 `faithful = DummyMemory()`）、`:86-114`（`generateContent`）；调用点 `f_llm/src/agents/AgentTask.cj:510`
- **来源**：存量（快照模式，无基线可比）
- **判据**：review-checklist §14.1「开关只在一处判断，另一处仍走旧逻辑」、§5「一次提交全量任务」、§12.1「有界性」
- **证据**：静态确定 —— `llm_makingMemory` 默认 `false`（`f_llm/src/config/LLMConfig.cj:254-256`），此时 `faithful` 是 `DummyMemory`，三个方法都是空体（`FaithfulMemory.cj:23-28`）。但 `Memory.add(session, all!)` 无条件 `spawn`，并在循环里先算 `generateContent(m)`（每个消息一次字符串拼装，`ToolCallMessage` 还要遍历 `tool_calls`）再调用空实现；`AgentTask` 每个事件都调一次（`:510`），即每个事件一个游离线程 + 一次全量文本拼装，成果全部丢弃。
- **描述**：开关关掉只是"不落盘"，没有"不干活"。同一个 `spawn` 还带来两个次生问题：线程无上限（每个事件一个，无 join、无队列、无背压），以及异常被彻底吞掉（`spawn` 内的 `faithful.add` 抛 `StoreException` 时无人感知，因为 `Future` 被丢弃）。
- **建议**：在 `Memory.add` 入口判 `LLMConfig.getMakingMemory()`（或给 `FaithfulMemory` 加 `prop enabled: Bool`，`DummyMemory` 返回 `false`）后直接返回；需要异步时改成有界提交（固定 worker + 队列上限），并保留 `Future` 至少记录失败日志。

### [轻微][存量] #14 `McpToolSource` 的类注释与实现相反（`additionalProperties`、64 字符规则）

- **位置**：`f_llm/src/mcp/McpToolSource.cj:49-53`（注释）vs `:132-155`（`sanitizeSchema` 只剥 `$` 前缀键）vs `:158-174`（`firstTypeOf`）；测试侧 `McpToolSource_test.cj:75-76` 明确断言"必须保留 `additionalProperties`"
- **来源**：存量（快照模式，无基线可比）
- **判据**：review-checklist §11「语义与注释不符」
- **证据**：静态确定 —— 注释说「`$schema` / `$ref` / `$defs` / `additionalProperties` 一律剥掉」，实现只跳过 `key[0] == b'$'`，`additionalProperties` 既不剥也没特判，`sanitizeSchema` 自己的注释（`:128-130`）还写着"**保留**"。长度规则同样：注释说"别名或工具名超 64 字符 ⇒ 注册失败"，实际校验的是拼好的 `mcp__{alias}__{tool}` 总长（`ToolName.mcp` → `validate(name)`，`ToolName.cj:36-38`），alias 40 + tool 30 会失败，而两者各自都 < 64。
- **描述**：注释是维护者判断"该剥什么"的第一手依据，写反了会把后续改动带向错误方向（本次测试用例写的是正确语义，说明注释是旧版遗留）。
- **建议**：注释改为"剥掉所有 `$` 开头的元信息键；`additionalProperties` 保留；总长 `mcp__{alias}__{tool}` ≤ 64"。

### [轻微][存量] #15 `ToolScope.verifyPlan` 注释声称校验"工具/模型"，实现只校验工具

- **位置**：`f_llm/src/loom/ToolScope.cj:57`（`/** 校验计划里 step 引用的工具/模型都在白名单内 */`）、`:69-81`
- **来源**：存量（快照模式，无基线可比）
- **判据**：review-checklist §11「语义与注释不符」
- **证据**：静态确定 —— 函数签名只有 `tools: Array<String>` 与 `availableTools`，循环里只对 `step.kind == 'tool' || 'mcp'` 判 `step.tool`，`step.model` 从未被读取。
- **建议**：要么改注释为"只校验工具/MCP"，要么补 `models`/`availableModels` 参数并按 `step.model` 判（`llm` 步骤也需要模型白名单时，这是当前唯一缺失的一环）。

### [轻微][存量] #16 `MemoryExtractor` 用"去掉 key 末尾一个字节"派生 kind，`individualities` 变成 `individualitie`

- **位置**：`f_llm/src/memory/MemoryExtractor.cj:31`（`let kind = key[0 .. key.size - 1]`）、`:53-54`/`:136`（传入 `'lessons'`/`'experiences'`/`'individualities'`）
- **来源**：存量（快照模式，无基线可比）
- **判据**：review-checklist §1「读了不用/派生逻辑脆弱」、§2「字面量复制」、§11「语义与命名不符」
- **证据**：静态确定 —— `'individualities'` 去尾是 `'individualitie'`（漏了 `y`），而 `MemoryKinds`（`f_llm/src/store/MemoryKinds.cj:43-53`）里根本没有 `lesson`/`individualitie` 这些值；`'lessons' → 'lesson'`、`'experiences' → 'experience'` 也是另一套命名，与 `MemoryKinds.EXPERIENCE` 只是"碰巧同字"。
- **描述**：`kind` 会随 `overwrite(kind, content)`（`f_llm/src/finder/MemorySummaryFinder.cj:21`）落到记忆记录里，下游 `listByKind('individuality')` 永远查不到；同时"去尾一个字节"对任何新增的合法 JSON key 都会静默产出错误 kind。
- **建议**：把 kind 显式写死成常量（如 `MemoryKinds.LESSON` / `INDIVIDUALITY`），不要靠字符串截断；`extract(key, jsonobj, overwriter)` 改成收 `(key, kind)` 两个参数。

### [轻微][存量] #17 `Memory.remember` 把命名空间与 kind 的默认值写成字面量，与 `MemoryKinds` 常量脱钩

- **位置**：`f_llm/src/memory/Memory.cj:121`（`namespace!: String = 'loom', kind!: String = 'session'`）
- **来源**：存量（快照模式，无基线可比）
- **判据**：review-checklist §2「字面量复制」
- **证据**：静态确定 —— `MemoryKinds.SESSION = 'session'`（`f_llm/src/store/MemoryKinds.cj:49`）已存在，`'loom'` 在 `loom` 包内多处出现，这里两处都是裸字面量；常量改名后签名默认值不会跟着变。
- **建议**：默认值改用 `MemoryKinds.SESSION`，命名空间常量提到 `loom` 包的公共常量（`LoomNamespaces.DEFAULT`）。

### [轻微][存量] #18 §2 重复逻辑（5 组，均为"同语义不同写法"）

- **位置与形态**：
  1. **`textOf(FunctionResult)` 同形多处（本部分 3 处）**：`f_llm/src/loom/ToolFunctions_test.cj:73-78`、`f_llm/src/mcp/McpToolSource_test.cj:104-107` 与 `:118-121`（同一文件内两段一模一样的 `match(result.result){ case json: JsonString => json.value; case _ => '' }`）；范围外另有两份（`loom/SkillImport_test.cj:57`、`loom/StoreFunctions_test.cj:47`）。
  2. **JSON 数组手工拼装两处**：`f_llm/src/loom/ToolFunctions.cj:58-72` 与 `:110-121`——`var text = '['` + `first` 标志 + `text += '{...}'` + `text + ']'` 的骨架逐行对齐，差异只有"是否带 `score` 字段"和"是否分页"。
  3. **空白校验跨层重复**：`ToolFunctions.cj:105-107`（`params.query.trimAscii().isEmpty()` → 返回 `requires query`）与 `ToolCatalog.cj:57-61`（`query.trimAscii().toAsciiLower()` 后再判 `isEmpty` → 返回空表）。同一份输入被两层各 trim 一次，错误语义不同（一个是文本提示、一个是空数组）。
  4. **"集合转 HashMap 做成员判定"两处**：`ToolScope.cj:38-41`（`available`）与 `:61-68`（`tools` + `availableTools`），且都用了 `HashMap<String, Bool>` 而不是 `HashSet<String>`。
  5. **MD5 → hex 两处**：`model/entity/KnowledgeEntity.cj:71-75`（`content.unsafeBytes() |> md5.write; md5.finish() |> toHexString`）与 `memory/FaithfulMemory.cj:46-48`（`md5.write(...); md5.finish() |> toHexString`）。
- **来源**：存量（快照模式，无基线可比）
- **判据**：review-checklist §2（换控制流 / 只改类型名 / 字面量复制）
- **证据**：静态确定 —— 逐行比对函数体骨架与字面量。
- **描述**：第 1 组是纯测试样板（抽取落点建议放测试公共文件而不是产品代码）；第 2、3 组有真实的"行为漂移"风险（分页版与检索版的字段、空值语义已经不同）；第 5 组建议抽 `f_util` 的 `md5Hex(String): String`，现有 `f_util/src/uuid.cj:318` 已有第三份 `MD5()` 用法。
- **建议**：2 → `ToolCatalog.toJson(entries)`；3 → 只在上层校验，`ToolCatalog.search` 收到空串直接返回空（保留但加注释说明这是防御）；4 → `private func toSet(items: Collection<String>): HashSet<String>`；5 → `f_util` 公共函数。合并时必须保留的语义差异：`searchTools` 的空查询回文本、`ToolCatalog` 的回空数组。

### [轻微][存量] #19 `Knowledge.cj` 尾部粘着的 psql 表结构注释与类字段已不一致，且混用数据库方言类型名

- **位置**：`f_llm/src/model/Knowledge.cj:30-49`
- **来源**：存量（快照模式，无基线可比）
- **判据**：review-checklist §11「注释与实现不符」、fountain-baseline §2（代码里不出现方言名）；review-checklist §13 的同类判据（注释即文档）
- **证据**：静态确定 —— 注释列出 13 列（`id` / `code_lang` / `kind` / `md5` / `source` / `entire` / `title` / `content` / `used_count` / `save_time` / `update_time` / `embedding` / `search_vector`），`Knowledge`（`:18-29`）只有 8 个字段，`used_count`/`save_time`/`update_time`/`search_vector` 完全没有对应成员；注释右侧被截断（`>` 结尾），已不可读；类型名 `bigint` / `character varying` / `tsvector` 正是 baseline §2 明令不要出现在代码里的方言名。
- **建议**：注释改成"表结构以 `f_llm/src/store/**/KnowledgeStore.cj` 的建表语句为准"，或补齐缺失字段并改成仓颉类型名；无用的 `\d` 输出直接删掉。

### [轻微][存量] #20 `MemoryRemember_test.cj` 的 `Config` 导入未使用

- **位置**：`f_llm/src/memory/MemoryRemember_test.cj:22`
- **来源**：存量（快照模式，无基线可比）
- **判据**：review-checklist §1「未使用的 `import`」
- **证据**：静态确定 —— 该文件内 `Config` 只出现在第 22 行的 import 上（`grep -n "Config"` 仅命中该行）。
- **建议**：删除该 import。

### [轻微][存量] #21 `sanitizeSchema` 对 MCP 提供的 schema 做无深度上限的递归

- **位置**：`f_llm/src/mcp/McpToolSource.cj:132-155`（`$` 前缀剔除时对每个 value 递归）、`:158-174`（`firstTypeOf` 不递归）
- **来源**：存量（快照模式，无基线可比）
- **判据**：review-checklist §4「无界递归：深度由输入决定」
- **证据**：待确认 —— 递归深度完全由 `tool.inputSchema` 的 JSON 嵌套层数决定，代码无深度计数；实际可达到的上界取决于 `f_data` 的 JSON 解析器是否对嵌套深度设限（未在本次范围内取到该常量），因此按"与解析器等深"估计而不是断言具体层数。MCP server 由外部配置引入，属可信度较低的一方。
- **建议**：加 `depth` 参数并在超过（如 32 层）时直接返回原值 + `warn`，避免"清洗 schema 时爆栈"这种难定位的崩溃。

### [轻微][存量] #22 测试大量共享进程级单例，用例之间互相污染且无法并行

- **位置**：`f_llm/src/loom/Supervisor_test.cj:159-178`（`boot()` 每次 `Supervisor.reset()` + `LoomServices.reset()` + `LoomHostApi.unbind()`，`:244-246`、`:283-286`、`:363-365`、`:434-436` 又各写一遍）、`f_llm/src/mcp/McpToolSource_test.cj:81-87`（`catch(error: Exception){ () }` 吞掉注册失败）、`:139-150`（注册 `dup` 后不清理）、`f_llm/src/memory/MemoryRemember_test.cj:55-57`（`finally` 里把手写假网关装回全局）、`f_llm/src/loom/ToolFunctions_test.cj:81-87`（`ensureFake` 吞异常）
- **来源**：存量（快照模式，无基线可比）
- **判据**：review-checklist §3「`catch {}` 静默吞异常」、§12.1「共享可变状态」、§2「测试准备代码重复」
- **证据**：待确认 —— `Supervisor.current()` / `LoomServices` / `LoomHostApi` / `FunctionMediator` / `LoomHostApi.storeGateway` 都是进程级 static；`std.unittest` 提供 `KeyParallel`（`std/unittest/unittest_package_api/unittest_package_structs.md:1239-1261`），默认是否并行需按 `cjpm test` 的实际配置确认。若并行，这些用例必然互相覆盖状态；若串行，`catch{ }` 仍会把"重名注册"这类真实失败吞掉。
- **建议**：`ensureFake` 改成先 `try` 注册、失败时校验已注册的是不是同类工具（而不是无条件忽略）；`McpToolSource_test` 结束清理 alias；`MemoryRemember_test` 的 `finally` 恢复成"无网关"（`unbind` 语义）而不是装一个永真假网关；`boot()` 的 reset 样板抽成 `@BeforeEach`。

<!-- 第 19 部分 -->

### [严重][存量] 搜索/抓取把 TLS 校验设为 `TrustAll`，同时携带 `Bearer <API key>`——出站流量可被中间人读取与篡改

- **位置**：`f_llm/src/search/DeepSeekSearchProvider.cj:43-45`（`var tls = TlsClientConfig(); tls.verifyMode = CertificateVerifyMode.TrustAll; client.tlsConfig(tls)`）；凭据在 `:120-127`（`headers['Authorization'] = 'Bearer ${conf.auth}'`）；发送在 `:46-49`
- **来源**：存量（快照模式无 diff）
- **判据**：review-checklist §10 安全性 / §11「契约与实现不符」
- **证据**：静态确定 —— `TlsClientConfig.verifyMode` 文档默认值为 `CertificateVerifyMode.Default`（“认证系统证书”，`cangjie_runtime/stdlib/doc/libs_stdx/net/tls/tls_package_api/tls_package_classes.md:664-671`），`TrustAll` 在同文件 `:699` 明确写着“信任所有证书”；`f_httpclient` 没有在 `HttpClient.tlsConfig` 上做任何兜底（`f_httpclient/src/httpclient.cj:110-113` 只是透传 `builder.tlsConfig`）
- **描述**：能劫持 DNS/网络的中间人可用自签证书冒充 `api.deepseek.com`：(1) 直接拿到 `Authorization: Bearer sk-...`（长期计费凭据）；(2) 把 `search`/`fetch` 的返回正文替换成带指令的文本，而这段文本会被 `WebSearchFunction.call`（`f_llm/src/tool/WebSearchFunction.cj:64-69`）原样交回模型当作工具结果，构成提示注入。搜索与抓取是模型主动调用的公网能力，触发面比聊天主链路更宽
- **建议**：删除 `:43-45` 走默认 `Default` 校验；确需关闭校验的场景做成显式配置（如 `llm_tlsVerify=false`，默认 `true`），开启时 `log.warn`。同一模式在 `src/util/http.cj:26`、`src/llm/LLMTransport.cj:47`、`src/llm/LLMStreamTransport.cj:49`、`src/embedding/BgeM3Transport.cj:91`、`src/balance/BalanceQueriers.cj:42`、`src/store/hydra/HttpTransport.cj:203` 还有 6 处（属其他分轮范围），修复应统一收敛到 `f_httpclient` 一处

### [一般][存量] 搜索/抓取没有自己的超时，继承的是被 embedding 反复改写的**进程级** HTTP 默认超时

- **位置**：`f_llm/src/search/DeepSeekSearchProvider.cj:36-50`（`defaultSearchPost` 只设 `autoRedirect` / `tlsConfig`，无 `readTimeout` / `writeTimeout`）
- **来源**：存量（快照模式无 diff）
- **判据**：review-checklist §11「契约与实现不符」/ §12.1「共享可变状态」
- **证据**：静态确定 —— `HttpClient` 在构造函数里读两个**静态**变量并应用（`f_httpclient/src/httpclient.cj:29-48`：`private static var readTimeout_`/`writeTimeout_`，`globalReadTimeout`/`globalWriteTimeout` 直接赋值，无同步）；生产代码里唯一的写入点是 `BgeM3Transport.embed`（`f_llm/src/embedding/BgeM3Transport.cj:62-64`，默认 `timeoutMs = 3000`），每次向量化都改写这两个全局值
- **描述**：两条后果都成立：(1) 只要进程跑过一次向量化，搜索/抓取的 `HttpClient` 就继承 3s 读写超时，DeepSeek 搜索接口正常时延可能超过 3s，表现为“偶发搜索失败”，且失败点随 embedding 调用时机漂移；(2) 若 embedding 从未被调用，`readTimeout_` 为 `None`，请求使用 stdx 默认值（没有业务上限），一次挂起的连接会一直占住调用线程。另：`global*` 写的是无同步静态 `var`，与并发创建 client 之间存在数据竞争（该文件属其他分轮）
- **建议**：`defaultSearchPost` 里显式 `client.readTimeout(...)` / `client.writeTimeout(...)`，取值从 `LLMConfig` 读（搜索建议 10~30s，抓取单独定），不要依赖 `global*`；同时给 `f_httpclient` 的全局设置加锁或废弃

### [一般][存量] `readEntire()` 全量物化响应体、按 `Content-Length` 预分配，抓取大小上限只在读完之后才生效

- **位置**：`f_llm/src/search/DeepSeekSearchProvider.cj:48`（`response.readEntire()`）→ `f_httpclient/src/ExtendHttpResponse.cj:50-77`（`:55` `Array<Byte>(size, repeat: 0)`，或 `ArrayList<Byte>` 1KB 步进累积）→ `:93-95`（`String.unsafeUtf8` 再整份复制）
- **来源**：存量（快照模式无 diff）
- **判据**：review-checklist §5「一次性物化」「按不可信长度预分配」
- **证据**：静态确定 —— 读取阶段没有任何字节上限；`llm_fetchMaxBytes` 只在 `WebFetchFunction.renderPage`（`f_llm/src/tool/WebFetchFunction.cj:59,64-74`）里截断，此时整页正文已经在堆上；`bodySize` 直接来自响应的 `Content-Length`（`ExtendHttpResponse.cj:51-55`），是上游可控值
- **描述**：`fetch` 抓的是任意公网页面，`search(need_content=true)` 返回的 `summary` 实测也可能是整页正文（`DeepSeekSearchProvider.cj:70-71` 注释自述）。一个 500MB 的页面（或恶意站点/被劫持的上游，见 #1）会让进程在“截断到 20KB”之前先分配 500MB 的 `Array<Byte>` + 500MB 的 `String`，峰值约为响应体的 2~3 倍；`needContent=true` 时同一响应还要再建一遍 JSON 树。`count` 同样没有上限：`WebSearchParams` 的 schema 只写了“1~50”（`f_llm/src/tool/WebSearchFunction.cj:35-36`），代码不校验，`DeepSeekSearchProvider.cj:103` 原样下发
- **建议**：把字节预算下沉到读取层——`SearchPoster` 增加 `maxBytes`，`readToEnd` 改为有界循环读（超过上限即停并返回 `truncated`）；`search` 侧对 `count` 做硬校验（`1..50` 夹紧，在 provider 里做，防所有调用方漏校验）

### [一般][存量] `SearchProviderRegistry.ensureLoaded` 把“扫描/构造失败”整体吞掉并永久 `loaded = true`，与自身注释相反且无日志

- **位置**：`f_llm/src/search/SearchProvider.cj:118-133`（`:124-130` 的 `try/catch(_: Exception){}`、`:131` 的 `loaded = true`）
- **来源**：存量（快照模式无 diff）
- **判据**：review-checklist §3「静默吞异常」/ §11「契约与实现不符」/ §6.2「锁内执行外部逻辑」
- **证据**：静态确定 —— 注释写“单个 provider 构造失败只跳过，不影响其他平台”，实现是把整个 `lookupList<SearchProvider>()`（`f_bean/src/lookup.cj:44-46` → `BeanFactory.getList` → `f_bean/src/BeanFactory.cj:274-283`，循环内 `m.bean` 逐个实例化）包在一个 `catch` 里：任一 provider 构造抛异常，本次扫描已构造与未构造的 provider 全部不注册，而 `loaded` 已置真，进程生命周期内不再重试
- **描述**：一次构造失败就永久关闭 `@Bean` 发现且无日志；下游 `WebSearchFunction.pickConf` 只看到 `registered: []`（`WebSearchFunction.cj:88-91` 的 `SearchUnavailableException`），真正原因被掩盖。另：扫描在 `synchronized(mutex)` 内执行（`:120-132`），期间会运行任意 provider 的构造函数。`Mutex` 是可重入的（`cangjie-doc/.../docs/dev-guide/source_zh_cn/concurrency/sync.md:350`：“在某个线程已经持有一个 `Mutex` 锁的情况下，再次尝试获取同一个 `Mutex` 锁，永远可以立即获得”），所以同线程不会自锁；但若某个 provider 的 `init` 反过来调 `get()`/`register()`，重入的 `ensureLoaded` 看到 `loaded` 仍为 `false`，会再次 `lookupList` 构造同一批 provider ⇒ 递归重入（栈溢出面，见 §4）
- **建议**：逐个 `try` 包裹（`for(p in list){ try{...}catch(e){ log.warn(...) } }`），失败时**不**置 `loaded`（或只对“容器不存在”置位）；把扫描移到锁外，先拿到列表再加锁合并；至少用 `f_log` 记一条 warn（本包已 `internal import fountain::f_llm.f_log.*`，见 #11，说明日志被删过）

### [一般][存量] `LLMConf.auth` 注释承诺支持 `secretRef:env:NAME`，全仓没有任何解析实现，auth 原样进 `Bearer`

- **位置**：`f_llm/src/model/po/LLMConf.cj:52-54`（`/** 鉴权 KEY，或 secretRef:env:NAME */`）；使用点 `f_llm/src/search/DeepSeekSearchProvider.cj:120-127`
- **来源**：存量（快照模式无 diff）
- **判据**：review-checklist §14「承诺了但没实现」（双证）
- **证据**：静态确定 —— 承诺源：上述字段注释；缺失证据：全仓 `grep -rn "secretRef"` 只命中这一行注释（另一命中是 `fprobe/README.md:350` 明确写“只认明文 KEY，不解析 `secretRef:`”），`f_llm/src` 内没有任何 `getenv`/Secret 解析器接到 `LLMConf.auth`；消费点都是字符串直用：`search/DeepSeekSearchProvider.cj:123` 与 `embedding/Embedding.cj:131-132` 拼 `Bearer`、`llm/TokenCounter.cj:72` 经 `util/http` 拼 `Bearer`、`balance/BalanceQueriers.cj:246-256` 把同一字段当 `AK:SK` 拆开
- **描述**：运维照注释把 `auth` 配成 `secretRef:env:DEEPSEEK_KEY`，请求会带 `Authorization: Bearer secretRef:env:DEEPSEEK_KEY` 发出去并得到 401，错误现象与真实原因无关；同时会误以为“库里不存明文”，实际明文仍必须写进 `llm_conf.auth`。同一字段还承担“明文 KEY / secretRef / 云厂商 AK:SK”三种语义（`balance/BalanceQueriers.cj:246-256` 把 `:` 前当 AccessKey），任何解析器落地前必须先定互斥规则
- **建议**：二选一——(a) 在配置装载期（`LLMConfSource` 四个来源的统一收口处）解析 `secretRef:env:`，只在内存里保留明文，解析失败启动即报错；(b) 删掉注释里的 `secretRef` 承诺，并在 README 的 `auth` 行写明“仅明文，原样拼 Bearer”（与 `fprobe` 写法对齐）

### [一般][存量] `parseDeepSeekSearch` 对 JSON `null` / 字段类型漂移没有兜底，单条异常让整次搜索失败

- **位置**：`f_llm/src/search/DeepSeekSearchProvider.cj:130-147`（`:133-134` 取 `results`）、`:163-172`（`searchTextOf` 的 `value.asString().value`）
- **来源**：存量（快照模式无 diff）
- **判据**：review-checklist §11「边界 / 空值 / 契约不符」
- **证据**：静态确定（语义）+ 待确认（上游是否真会这么返回）——`JsonValue.asString()` 在非 `JsonString` 时直接 `throw JsonException`（`f_data/src/json/JsonValue.cj:56-62`），`asArray()`/`asObject()` 同理（`:63-75`）
- **描述**：`searchTextOf` 只挡了 `JsonNull`（`:166`），`"results": null` 会在 `:134` 的 `asArray()` 直接抛；`title`/`url`/`date` 若变成数字或对象，会在 `:167` 抛。函数注释写的是“字段一律走 textOf，避免 JSON null 直接 asString 抛异常”，实际只覆盖 null 一种。一旦抛出，整次搜索（含已解析好的前 N 条）全丢，模型看到的是工具异常而不是“无结果/部分结果”
- **建议**：`results` 支持 `null`→空表；`searchTextOf` 按 kind 分支（`JsonNull`→`''`、`JsonString`→`value`、数字/布尔→`toString()`、对象/数组→`''`），并给单条结果加 `try/catch` 跳过坏条目（记 warn 计数）

### [一般][存量] `EnvConfSource` / `FileConfSource` / `StaticConfSource` 不保证 `id` 唯一，快照按 id 建索引后 `all()` 丢配置，连带 `webSearch`/`webFetch` 选不到平台

- **位置**：`f_llm/src/service/LLMConfSource.cj:99-114`（`parseConfJson` 不补 id）、`:67-71`（`StaticConfSource.load` 直接复制）、`:92-95`（`FileConfSource.load`）；消费侧 `f_llm/src/llm/LLMConfsHolder.cj:242`（`byId[conf.id] = conf`）、`:129-132` / `:59-67`（`all()` 只遍历 `byId`）
- **来源**：存量（快照模式无 diff）
- **判据**：review-checklist §11「契约与实现不符」；对照实现 `StoreMetaConfSource.cj:47-49` 用 `seq++` 显式赋 id，说明“id 必须唯一”是已知前提
- **证据**：静态确定 —— `LLMConf.id` 默认 `0`（`model/po/LLMConf.cj:33-34`）；JSON 来源不写 `id` 时每条都是 0（本部分测试样例 `LLMConfSource_test.cj:24-50` 就没有 `id` 字段）；`refresh` 用 `byId[conf.id] = conf` 覆盖，`all()` 只读 `byId`；工具侧的候选来自 `LLMCandidateProvider.defaultSupplier` → `holder().all()`（`f_llm/src/llm/LLMCandidateProvider.cj:37-43`）
- **描述**：`llm_confSource=env` 或 `file:` 配 3 个模型（deepseek / zhipu / ark，不写 id，符合样例格式）时 `byId` 只剩最后一条：`all()` 返回 1 条，`pickConf` 筛不到支持 `search` 的平台就报“no llm conf available for search”；`Embedding` 的兜底遍历（`src/embedding/Embedding.cj:109-113`）同样只看到一个模型。熔断器按 id 记账（`LLMConfsHolder.cj:149-159`），id 全 0 意味着所有配置共用一个熔断状态。注意 `byName` 路径（`candidates(llmName)`）保留了全部条目，所以普通对话不受影响，只有走 `all()` 的工具与兜底路径丢配置——症状更隐蔽
- **建议**：三个来源的 `load()` 统一补 id（`id <= 0` 时 `seq++`，与 `StoreMetaConfSource` 一致），或 `refresh` 改用 `(id, provider, llmName)` 复合键并显式拒绝重复 id（`log.error` 后丢后一条，不静默覆盖）；补一条“env 源 3 条配置 → `holder.all().size == 3`”的用例

### [一般][存量] `StaticConfSource.load()` 返回浅拷贝，违反接口“整体返回快照、不要返回内部可变结构”的约定

- **位置**：`f_llm/src/service/LLMConfSource.cj:67-71`（`let copy = ArrayList<LLMConf>(); copy.add(all: confs)`）；接口约定在 `:30-34`
- **来源**：存量（快照模式无 diff）
- **判据**：review-checklist §11「契约与实现不符」；`LLMConf` 是可变的（`setConf`、`weight` 等）
- **证据**：静态确定 —— `copy.add(all: confs)` 只复制引用；`LLMConf` 的 `confJson`/`weight`/`enabled` 均可写（`model/po/LLMConf.cj:80-83` 等）
- **描述**：当前 `LLMConfsHolder.refresh` 只读不写，还没有实际串数据；但接口把“快照”写成实现契约并专门强调“不要返回内部可变结构”，实现只做了列表拷贝。任何调用方（含未来的配置归一化、测试替身）一旦修改 `load()` 返回的 `LLMConf`，源对象被永久改掉，第二次 `load()` 带出的就是被污染的数据
- **建议**：要么在注释里把语义降级为“列表不可变、元素共享”，要么 `load()` 逐条复制（PO 可加 `copy()`）；更彻底的是把 `LLMConf` 拆成不可变 view（`setConf` 只在装载期用）

### [一般][存量] DB 用例直接 `service.clear()` 清空 `llm_conf`，只由 `llm_db` 布尔开关保护；`clear()` 本身还是公开 API

- **位置**：`f_llm/src/service/LLMConfService_test.cj:63`、`:103`、`:114`、`:140`（`service.clear()`）；被调 API `f_llm/src/service/LLMConfService.cj:39-40,61-63`（`deleteAll`）
- **来源**：存量（快照模式无 diff）
- **判据**：review-checklist §11「资源/数据安全」/ §10 安全性
- **证据**：静态确定 —— 门槛只有 `LLMConfig.isDatabaseEnabled()`（`src/config/LLMConfig.cj:51-54`，读 `llm_db`），没有“测试库”二次校验；用例在开头和结尾都执行 `DELETE FROM llm_conf`（`src/dao/LLMConfDAO.cj:61-63`）
- **描述**：开发者为验证 DB 功能把 `llm_db=true` 指向共享开发库后跑 `cjpm test`，第一个用例就把所有平台模型配置（含 `auth`）清空；若中途断言失败，结尾的 `clear()` 不执行，库里留着测试用的 `sk-test-1234567890`
- **建议**：用例改用独立 schema/表名或临时库，绝不碰 `llm_conf`；`clear()` 从公共接口移除（测试需要就直接调 DAO），或改 `clearForTest()` 并加运行期环境断言

### [一般][存量] `skills` 表有 `version` 列，PO `Skill` 没有该字段；同一实体两套模型字段集互补，ORM 侧永远读不到版本

- **位置**：`f_llm/src/model/po/Skill.cj:25-50`；DDL `f_llm/tables-pg.sql:52-62`（`version INT NOT NULL DEFAULT 1, -- 技能自演进版本（§10.4）`）；对照模型 `f_llm/src/store/StoreModels.cj:109-122`
- **来源**：存量（快照模式无 diff）
- **判据**：review-checklist §2「只改类型名 / 字段漂移」/ §11「契约与实现不符」
- **证据**：静态确定 —— PO 字段是 `id/agentId/acceptedEvent/returnedEvent/title/metadata/details/functions/skillType`（`:26-43`）；store 侧 `Skill` 是 `id/title/details/functions/version`；DDL 两边的列都在
- **描述**：`@QueryMappersGenerator[table: skills]` 生成的映射以 PO 字段为准，`SELECT *` 读出的 `version` 无处可放，PO 侧也永远写不进 `version`；`MetaDAO.upsertSkill(... version ...)`（`src/dao/postgres/MetaDAO.cj:97-103`）走的是 store 模型。结果是“技能演进版本”只对 store 路径可见，任何走 PO 的工具（`SkillsFinder.querySkills` → `AgentTask` 的技能注入）拿不到版本号，无法判断技能是否更新。两套模型各缺对方 4~5 个字段，新增列只会落在一侧
- **建议**：给 PO 补 `@ORMField['version'] private var version: Int64 = 1`（读路径即可用），并在 store→PO 的适配处显式透传；或在 `doc/f_llm.md` 的模型表里写清两套模型的字段映射与“新增列必须同时加”的约定

### [轻微][存量] 包级 `imports.cj` 里残留 9 条包内零引用导入（旧 Searcher 链路的痕迹）

- **位置**：`f_llm/src/search/imports.cj:19-29`（`std.collection.concurrent.ConcurrentHashMap`、`std.time.MonoTime`、`fountain::f_log.*`、`fountain::f_util.*`、`fountain::f_llm.constant.*`、`fountain::f_llm.finder.*`、`fountain::f_llm.model.*`）；`f_llm/src/model/entity/imports.cj:23-24`（`f_base.*`、`f_data.*`）
- **来源**：存量（快照模式无 diff）
- **判据**：review-checklist §1「未使用的 import」
- **证据**：静态确定 —— `internal import` 的作用域是“当前包及其子包”（`docs/dev-guide/source_zh_cn/package/import.md:291-296`：“`internal import` 表示导入的内容在当前包及其子包（包括子包的子包）均可访问”），所以判定范围是整个 `src/search` 包：包内 4 个 `.cj` 全文检索 `MonoTime`/`ConcurrentHashMap`/`LoggerFactory`/`Logger`/`TextClip`/`Knowledge`/`Specification`/`LLM_TYPE_*`/`MODEL_NAME_*`/`*Finder` 全部零命中（`SearchResult.cj:21-25` 只在注释里提到 `KnowledgeEntity`）；`entity` 包唯一实现 `KnowledgeEntity.cj` 不引用 `f_base`/`f_data`。包内仍需保留的只有 `std.collection.*`（`ArrayList`/`HashMap`）、`f_base.*`（`resource`，`f_base/src/resource.cj:18`，`DeepSeekSearchProvider.cj:46` 在用）、`f_data.*`、`f_httpclient.*`、`model.po.*`
- **描述**：这些导入是搜索旧链路（`SearchMediartor`/`GLMSearcher`）删除后的残留；`f_log` 的残留尤其说明“注册表失败要记日志”那段被删掉了（见 #4）。不影响运行，但会误导读者以为包内还有日志/并发容器依赖
- **建议**：删除零引用导入，并顺带补回 #4 需要的日志

### [轻微][存量] `LLMConf.conf` 注释写“用 conf 属性读写 Map”，实际只有 getter，写入会被静默丢弃

- **位置**：`f_llm/src/model/po/LLMConf.cj:64-69`（注释“对外用下面的 conf 属性读写 Map”）、`:73-78`（只有 `get()`，写入口是 `setConf` `:80-83`）
- **来源**：存量（快照模式无 diff）
- **判据**：review-checklist §11「语义与注释不符」
- **证据**：静态确定 —— `public prop conf: HashMap<String, String>` 无 `mut`/`set`；`HashMap` 是引用类型，`conf.conf['k'] = 'v'` 能编译通过，但改的是 getter 每次新建的临时表，`confJson` 不变
- **描述**：读路径没问题（每次 `fromColumn(confJson)` 新建表，调用方改不到内部状态，这一点是对的）；问题在文档：注释与 README 的“`prop conf` + `setConf`”并列，容易被读成“prop 可写”。真按注释写 `conf.conf['thinking']='none'` 会静默失效且无任何报错
- **建议**：注释改成“conf 只读视图，写请用 `setConf`”，或在 `doc/f_llm.md` 的 option 表里加同样的约束

### [轻微][存量] 两个“逗号分隔列”的解析方式不一致：`Agent` 不 trim/不去空，`Skill` 去空且 trim

- **位置**：`f_llm/src/model/po/Agent.cj:47-56`（`acceptable.split(',')` / `producings.split(',')`）vs `f_llm/src/model/po/Skill.cj:45-50`（`functions.lazySplit(',', removeEmpty: true).map{f => f.trimAscii()}`）
- **来源**：存量（快照模式无 diff）
- **判据**：review-checklist §2「实现漂移」/ §11「边界」
- **证据**：静态确定（差异）+ 待确认（线上数据格式）——`String.split` 默认 `removeEmpty: false`，原串为空时返回长度 0，但 `"a,"` / `"a,,b"` 会保留空元素，`"a, b"` 会保留前导空格（`cangjie_runtime/stdlib/doc/libs/std/core/core_package_api/core_package_structs.md:8027-8042`）
- **描述**：`agents.acceptable/producings` 与 `skills.functions` 是同一种列格式（`tables-pg.sql:36-40`、`:55`），却只有后者做了归一化。手工维护的数据出现 `"created, planned"` 时 `Agent.acceptableEvents` 会产出 `" planned"`，与事件名 `"planned"` 永不相等；尾逗号会产出空事件名，被当成“接受空事件”的任务注册。当前数据严格无空格则无影响
- **建议**：抽一个 `splitCsv(text): Array<String>`（`split(',', removeEmpty: true)` + `trimAscii`）放 `model/po` 公共处，两个 PO 共用

### [轻微][存量] `defaultSearchPost` 与 `f_llm.util.http` 是同一套 HTTP 客户端构造的两次实现（含同一处 `TrustAll`）

- **位置**：`f_llm/src/search/DeepSeekSearchProvider.cj:36-50` vs `f_llm/src/util/http.cj:18-29`
- **来源**：存量（快照模式无 diff）
- **判据**：review-checklist §2「换控制流 / 跨文件复制」；`f_llm.util.http` 是现成 `public` 能力
- **证据**：静态确定 —— 步骤逐条对齐：`HttpClient(url)` → 设 header → `Accept-Encoding: identity` → `TlsClientConfig().verifyMode = TrustAll` → `client.tlsConfig(tls)` → `resource(client){...}`；差异只有 `util.http` 额外固定 `Authorization: Bearer <auth>` 与 `Accept`，`defaultSearchPost` 收任意 header 表
- **描述**：同一段“关证书校验 + 关 gzip + 用完即关”的逻辑存两份，导致 #1 的修法必须改两处，也让“为什么搜索要 TrustAll”这类决策没有唯一落点（`util.http` 的注释解释了 gzip，搜索侧解释了重定向，TLS 谁都没解释）
- **建议**：`defaultSearchPost` 改成基于 `util.http` 的变体（补一个收 header 表的重载），或把 TLS/解压/超时策略统一收进 `f_httpclient` 的一个 `newJsonClient(url, headers)` 工厂

### [轻微][存量] 三处“把坏数据/异常变成默认值”且不打日志：`searchScoreOf`、`LLMConfCodec.fromColumn`、`optionBool`

- **位置**：`f_llm/src/search/DeepSeekSearchProvider.cj:174-184`（`catch(_: Exception){ 0.0f64 }`）；`f_llm/src/model/po/LLMConfCodec.cj:35-45`（非法/空内容返回空表）；`f_llm/src/model/po/LLMConf.cj:109-115`（`v == 'true' || v == '1'`，其余一律 false，不回退 `defaultValue`）
- **来源**：存量（快照模式无 diff）
- **判据**：review-checklist §3「静默吞异常 / `case None => ()` 兜底」
- **证据**：静态确定 —— 三处都没有日志，返回值直接参与打分/配置判断
- **描述**：后果同源：坏数据被当成“合法默认”。(1) `rerank_score` 若是字符串或缺失，得分静默变 0，排序看起来正常但顺序已错；(2) `llm_conf.conf` 列被手工写成非 JSON 时整份配置静默退化成默认值（`tokenThreshold=0` 即不限长、`stream=true`），排障看不到痕迹；`parseConfJson`（`LLMConfSource.cj:106-110`）把 `conf` 当对象解析失败时同样静默丢全部选项（例如值写成数字）。(3) `stream: "TRUE"` / `"yes"` 被判成 false，与配置意图相反
- **建议**：(1)(3) 加 warn（按 key 限频），解析失败回退 `defaultValue` 而不是恒 false；(2) 保留降级行为但在 `LLMConfCodec`/`parseConfJson` 带 conf id/provider 记 warn，便于发现“库里/文件里存了坏 JSON”

### [轻微][存量] `LLMConf` 是可变的 PO，却被当作“不可变配置快照”跨线程共享（当前无写者，属设计隐患）

- **位置**：`f_llm/src/model/po/LLMConf.cj:80-83`（`setConf` 写 `confJson`）、`:56-62`（`temperature`/`alwaysThinking` 可变）；快照声明 `f_llm/src/llm/LLMConfsHolder.cj:29`（“一份不可变配置快照：刷新时整体替换，读路径无锁”）
- **来源**：存量（快照模式无 diff）
- **判据**：review-checklist §12.1「发布逸出 / 可见性」
- **证据**：待确认 —— 共享路径确定（`snapshot.byName`/`byId` 的 `LLMConf` 被多个请求线程读取，`LLMConfsHolder.cj:124-132`），缺的是“写者”：`refresh` 只读（`:233-255`），仓内也没有对快照里的 `LLMConf` 调 `setConf` 的代码
- **描述**：`LLMConfsSnapshot` 靠约定而不是类型系统保证不可变：字段全 `mut`，`setConf` 是 `public`。未来任何“运行期改一个 conf 的 stream/权重”的需求，写者会直接改到在途请求正在读的对象，既无锁也无 `volatile` 语义，编译器不会提醒
- **建议**：短期在 `LLMConfsSnapshot` 注释写明“元素只读、禁止修改”；中期给 `LLMConf` 提供只读 view（`LLMConfView` 已有先例），把 `setConf`/`weight` 的写入口收到装载器

### [轻微][存量] 测试有效性：`testStaticSourceReturnsCopy` 只断言 size，DB 用例不满足条件时静默 `return` 而不是正式 skip

- **位置**：`f_llm/src/service/LLMConfSource_test.cj:71-82`（两次 `source.load().size`）；`f_llm/src/service/LLMConfService_test.cj:57-59`、`:108-110`
- **来源**：存量（快照模式无 diff）
- **判据**：review-checklist §11（测试无法证明其声称的契约）
- **证据**：静态确定 —— 用例名声称 “ReturnsCopy”，实际只调两次 `load()` 比长度，任何实现（包括直接返回 `confs` 本体）都能通过；DB 用例在不满足条件时 `return`，框架只记为通过
- **描述**：前者让 #8 的浅拷贝问题在测试里“看起来被覆盖了”；后者让 service 层在 CI 中永远绿——`LLMConfService` 的 5 个方法（含 `clear`）没有任何自动化验证，而它正是“唯一读取入口”（`LLMConfService.cj:25-28`）
- **建议**：copy 用例改成“`load()` 后修改返回列表/元素，再 `load()` 断言源未变”；DB 用例用 `@Configure[skip: ...]`（unittest 的 `KeySkip`）显式跳过，并在 CI 另配测试库把 `llm_db=true` 跑起来

### [轻微][存量] 注册表两条注册路径对“同名”策略不一致：`@Bean` 扫描静默覆盖，`register` 抛异常，且都没有日志

- **位置**：`f_llm/src/search/SearchProvider.cj:126`（`providers[provider.provider] = provider`，扫描路径无条件覆盖）vs `:90-98`（`register` 内 `if(providers.contains(...)) throw IllegalArgumentException`）
- **来源**：存量（快照模式无 diff）
- **判据**：`skills/fountain-review/references/fountain-baseline.md` §4「同名注册（扩展 / 路由 / 插件）：**启动直接失败**，不做隐式优先级」；review-checklist §14「版本与依赖漂移 / 接线」
- **证据**：静态确定 —— 扫描路径对同名 key 直接赋值，后写覆盖先写；显式路径对同名直接抛。两条路径同时生效时（先 `register` 后首次 `get` 触发扫描）表现为“显式注册的 provider 被 bean 版覆盖”，反向顺序则表现为启动抛异常，行为取决于首次调用顺序
- **描述**：当前仓内只有一个 `@Bean` provider（`DeepSeekSearchProvider`），所以还不会触发；但下游项目按 README 增加第二个 provider 时，若同名（例如两个平台都叫 `deepseek`），实际生效的是哪一个取决于 bean 扫描顺序，且没有日志。同一能力的两条注册路径语义不一致本身也会误导扩展者
- **建议**：扫描路径复用 `register` 的重名检查（或先收集再判断，重名时 `log.error` 并按基线“启动即失败”抛 `IllegalArgumentException`），让两条路径对同名给出同一结论

> 范围外提示（不计入本部分统计）：`f_llm/src/service/StoreMetaConfSource.cj:42-63` 由 `LLMConfView` 构造 `LLMConf` 时从不调用 `setConf`，而 `LLMConfView`（`src/store/StoreModels.cj:170-195`）也没有 `conf` 字段——一旦启用 store 源，`tokenThreshold`/`stream`/`chatPath`/`searchUrl` 全部丢失（`tokenThreshold=0` 即不限长）。该文件属其他分轮，请对应分报告复核。

<!-- 第 20 部分 -->

### [严重][存量] #1 同一个 `llm_metaStorePath` 被 4 个 store 类各自 `Store(path)` 打开，而 f_store 每次构造都会删掉目录下全部 WAL —— 未 flush 的写入静默丢失

- **位置**：
  - `f_llm/src/store/FStoreMetaStore.cj:41`、`:51`（`Store(path)`）
  - `f_llm/src/store/EvolutionStateStore.cj:193`、`:198`
  - `f_llm/src/store/EvolutionStore.cj:171`、`:176`
  - `f_llm/src/store/EvolutionLease.cj:180`、`:185`
- **来源**：存量（快照模式，无基线可比）
- **判据**：review-checklist §11「资源不对称 / 数据丢失」、§12.1「跨线程资源」「共享可变状态无保护」
- **证据**：静态确定 —— 三处事实叠加：
  1. 四个类的两个 `init` 都执行 `Store(DeployPaths.resolve(StoreSettings.load().metaStorePath))`（或同路径的 `Store(path)`），即**同一个目录被 4 个独立 Store 实例打开**；`f_store` 的 `Store` 没有任何按路径的单例注册（`f_store/src/Store.cj:36-94` 全是实例字段，无 `static`）。
  2. `Store.init` 在恢复完 MemTable 后调用 `cleanupOldWALFiles(walDir)`（`f_store/src/Store.cj:76-77`），该函数把目录下**所有** `.wal` 文件 `remove` 掉（`f_store/src/store_func.cj:216-229`，`catch (_: Exception) {}` 连失败都吞掉）。于是**每构造一个 Store，就把同目录里其他存活实例正在写的 WAL 文件删掉**；被删实例的后续 `add` 只落在自己的 MemTable 与已 unlink 的文件里。
  3. 构造频率不是"一次"：`Stores.meta(name)` / `Stores.content(name)` 每次都 `factory()`（`f_llm/src/store/Stores.cj:76`、`:92`，无缓存），而 `LoomWiring.cj:128` 把它包成 `{=> Stores.meta().skills}` 交给 `SkillCatalog.install`，`SkillCatalog` 每次检索都 `make().list()`（`f_llm/src/loom/SkillCatalog.cj:188-199`）；`EvolutionStores.current()` / `EvolutionLeases.current()` / `EvolutionStateStores.current()`（`EvolutionStores.cj:41-43`）同样是"每次新建"。
- **描述**：持有路径（长期强引用 → 目标对象）：`BeanFactory` 单例（`@Bean` 默认 `BeanScope.singleton`，见 `f_bean/src/BeanMeta.cj:26`）→ `LoomStoreGateway.meta`（`LoomStoreGateway.cj:70-71`）→ `FStoreMetaStore` → `Store` → `Compactor` 的 `spawn` 线程（`f_store/src/Compaction.cj:42`）+ WAL/SSTable 文件句柄。这些 `FStore*` 类都没有实现 `Resource`/`close()`，即使 `Store` 本身是 `Resource`（`f_store/src/Store.cj:23`）。
  后果分两层：①**数据丢失**——A 实例写 prompt/skill/character（走 `LoomStoreGateway` 的工具调用），期间任意一次 `SkillCatalog` 检索构造出 B 实例，B 构造时删掉 A 的 WAL；A 之后写入的记录只在 A 的 MemTable 里，A 一重启就消失。②**资源泄漏**——每次构造新增一个 compactor 线程 + 一个 `atExit` 钩子 + 1~2 个 WAL 文件，`SkillCatalog` 在主链路上按请求创建，线程与句柄随请求数线性增长。
- **建议**：`llm_metaStorePath` 只允许一个 `Store` 实例：在 `f_llm` 内加"路径 → Store"的引用计数缓存（例如 `FStoreHandle`：`static` map + `Mutex` + 引用计数，全模块共用），四个 `FStore*` 改为注入该共享实例；或者把 `FStoreMetaStore` / `EvolutionStore` / `EvolutionStateStore` / `EvolutionLease` 统一挂在同一个 `FStoreFamily` 门面下（一次 `Store(path)`，四个子 store 共用）。同时把 `Stores.meta()` / `Stores.content()` 的工厂改成长缓存（构造一次），并在 `FStore*` 上实现 `Resource.close()`。f_store 侧建议把 `cleanupOldWALFiles` 改成"只清理已成功回放的 WAL 且加目录锁"，避免多实例互相删文件。

### [严重][存量] #2 `InMemoryMemoryStore` 是 `@Bean` 单例，`HashMap` + `seq` 完全无同步

- **位置**：`f_llm/src/store/InMemoryStores.cj:83-95`（`@Bean` 与字段：`86-87`；`add` 的 `seq++` 与 `records[record.id] = record`：`90-93`）、`109-120`（`remove` 的检查-然后-删除）、`122-169`（`list` / `search` 遍历 `records`）
- **来源**：存量（快照模式，无基线可比）
- **判据**：review-checklist §12.1「共享可变状态无保护」「检查-然后-写入」「迭代与修改并发」
- **证据**：静态确定 —— 该类带 `@Bean` + `@BeanMeta[condition: ConfCond.Value('llm_memoryStore', StringCond.Exactly('inMemory'))]`（`83-84`），`f_bean` 默认 `scope = BeanScope.singleton`（`f_bean/src/BeanMeta.cj:26`），即**全进程一个实例**；`MemoryStoreAdapter` 在匹配到该 bean 时直接把它当 `MemoryStore` 用（`f_llm/src/store/MemoryStoreAdapter.cj:33-40`），HTTP / 工具调用是多线程并发。类内没有任何 `Mutex` / `synchronized` / 原子量：`seq++` 是非原子的读-改-写，`records` 是非线程安全 `HashMap`，`list` / `search` 一边 `for ((_, record) in records)` 遍历，另一线程可以 `records[...] = ...` / `records.remove(id)`。
- **描述**：在 `llm_memoryStore=inMemory` 下（`StoreWiring.cj:60` 注册了 `inMemory` 内容族；bean 路径由 `MemoryStoreAdapter` 直接取本类，非 bean 路径下 `InMemoryContentStore.memory` 也是本类，见 `InMemoryStores.cj:29-35`），两个并发 `add` 可能拿到同一个 `seq` → 后者覆盖前者（丢一条记忆）；并发 `add` 与 `list` 可能让遍历看到半更新的 map（仓颉 `HashMap` 无并发保证）。类注释（`23-27`）只声明"只用于单测与本地演示"，没有声明"非线程安全"，而它确实被注册成了可选后端。
- **建议**：与同模块 `InMemoryEvolutionStore` / `InMemoryEvolutionStateStore` 的写法对齐（`private let mutex = Mutex()` + 用 `Box` 把返回值带出 `synchronized`，见 `EvolutionStore.cj:74-116`）；`search` 里先 `synchronized` 拷出快照再算分，避免锁内做 `contains`。若确定只做单线程演示，则从 `StoreWiring` 摘掉 `inMemory` 或在类注释与 README 明写"非线程安全、仅供单线程演示"。

### [严重][存量] #3 `ColbertCodec.decode` 用数据里的 `count` 决定循环次数与分配，无上限 —— 损坏/恶意 blob 可让进程 OOM

- **位置**：`f_llm/src/store/ColbertCodec.cj:47-71`（`count` 取自前 4 字节：`51`；本应做校验的分支是空块：`52-54`；`dims` 由除法反推：`55`；循环：`58-69`）
- **来源**：存量（快照模式，无基线可比）
- **判据**：review-checklist §5「按不可信长度预分配」「无界容器」、§11「错误处理缺失 / 边界」
- **证据**：静态确定 —— `count = Int64(readInt32(bytes, 0))` 是 `Int32` 范围（最大 2 147 483 647），`dims = (bytes.size - 4) / count / 4`。当 blob 只有几字节而 `count` 很大时 `dims == 0`，于是 `for (_ in 0..count)` 执行 2^31 次，每次 `Array<Float64>(0)` + `vectors.add(...)`：`ArrayList` 至少要存 2^31 个引用（约 17 GB），必然 `OutOfMemoryError` 或长时间占满一个线程；字节数够大时则按 `count × dims` 真实分配，同样没有上限。`encode` 侧也没有校验"所有向量等长"，`bytes` 按 `vectors[0].size` 开（`30-31`），ragged 输入在写入时越界抛 `IndexOutOfBoundsException`，错误信息不指向真实原因。
- **描述**：`decode` 的唯一输入是 `MemoryRepository` 从库里读出的 `title/content` 向量列（`f_llm/src/store/postgres/MemoryRepository.cj:91`、`mysql/MemoryRepository.cj:95`）。只要这条路径上出现一个被截断或被改写的 blob（迁移、手工修数、别的写入方），读库请求就变成进程级 OOM/挂死，而不是一条可定位的解析错误。`52-54` 的空 `if` 说明作者本来打算做维度校验，但分支体是空的（见 #14）。
- **建议**：解码前做三段校验，失败抛明确异常（或在契约里返回 `?`）：`count in 0..MAX_CHUNKS`、`bytes.size >= 4 + count * 4`、`(bytes.size - 4) % (count * 4) == 0` 且 `dims in 1..MAX_DIM`（维度上限用常量，例如 4096）；`encode` 校验所有向量等长并给带下标的错误消息。上限常量写进类注释与 README，避免"到 OOM 才知道"。

### [一般][存量] #4 租约的时间戳被截断到 65.5 s 粒度，每天前 66 秒内"当天已领取"可能判成"昨天"

- **位置**：`f_llm/src/store/EvolutionLease.cj:65-72`（`high48` 与 `millis = high48 << 16`）、`:88-95`（`dayOf`）、`:152-164` 与 `:211-225`（两处 `acquire` 用 `dayOf(...) == now / 86400` 判同日）
- **来源**：存量（快照模式，无基线可比）
- **判据**：review-checklist §11「边界差一 / 语义与注释不符」
- **证据**：静态确定 —— `TimeUuid.create()` 走 `UUID.unixTimeBased()`（`f_util/src/uuid.cj:392-409`），该函数把毫秒时间戳写成 `UInt8((millis >> (7 - i) * 8) & 0xff)`（`i = 0..5`），即写入的是 `millis >> 16` 的 48 位；`timestampOf` 的 `high48 << 16` 正好补回，**低 16 位（65 536 ms）永久丢失**。于是解码值 = `floor(millis / 65536) × 65536`，最多比真实时间早 65.535 s。`86400000 % 65536 = 23552`，即每天零点相对 65536 ms 网格的整体偏移量；UTC 零点后的前 ~66 s 内，"真实属于今天"的租约值有约一半概率解成**昨天**（取决于截断余数与当天偏移）：`dayOf(value) != now / 86400` → `acquire` 认为"今天还没人领"，再写一个新值并返回 → 当天第二轮演进被放行。
- **描述**：类注释（`99-106`）承诺"多进程环境下保证同一天只有一个进程真正跑演进任务"，`69-70` 更明确写"≤66s 误差——对「按天判重」足够，取整后不会跨天漂移"，但取整恰好发生在天界，**在 0:00:00–0:01:06 UTC 这个窗口内互斥失效**：多进程（或同一进程的两次 `acquire`）都会拿到租约，`SkillEvolutionJob.schedule` 的 `allowed` 分支（`f_llm/src/loom/SkillEvolutionJob.cj:391-400`）就会各跑一遍。同一 `dayOf` 还被 `store/hydra`、`postgres`、`mysql` 三个租约实现共用（`f_llm/src/store/hydra/EvolutionLease.cj:84`、`it/EvolutionStoreIT_test.cj:103`），影响面不限于 f_store。
- **建议**：租约值不要依赖"截断精度刚好够用"，改为把"天序号"直接编码进值（例如 `value = '${now / 86400}:${uuid}'`，读侧只比第一个字段），或改用 `UUID.timestampNanos` 之外的整秒编码（`now.toString() + ':' + uuid`）。若坚持复用 UUID，至少把 `dayOf` 改成"用 `timestampOf` 的半天边界做 ±120 s 容差后取整"，并补用例覆盖"跨天前后 66 s"这个窗口。

### [一般][存量] #5 `EvolutionLease` 契约写"按旧值 CAS 覆盖"，实现只有进程内 `Mutex` + 无条件覆盖写

- **位置**：接口与注释 `f_llm/src/store/EvolutionLease.cj:98-123`（`:101` "读当前值 → …按旧值做 CAS 覆盖"、`:99` "多进程环境下保证"）；实现 `:211-225`（`FStoreEvolutionLease.acquire`）、`:152-164`（`InMemoryEvolutionLease.acquire`）
- **来源**：存量（快照模式，无基线可比）
- **判据**：review-checklist §11「契约与实现不符」、§12.1「检查-然后-写入」
- **证据**：静态确定 —— `acquire` 的实现是 `synchronized(mutex) { let previous = read(); if (同日) { () } else { store.add(KEY, created) } }`：`Mutex` 是**实例字段**（`:177`），只串行化同一实例内的线程；写入是 `store.add`（覆盖写，`f_store/src/Store.cj:97-107`），没有 compare-and-set，也没有任何跨进程锁（`f_store` 本身没有 CAS 原语）。同一文件的注释 `167-172` 自己也承认"单进程场景……跨进程共用一个 f_store 目录的情况不在支持范围内"，与接口 `99` 行"多进程环境下保证"直接矛盾。
- **描述**：`SkillEvolutionJob` 只拿到 `?EvolutionLease` 并调 `acquire(now)`（`SkillEvolutionJob.cj:391-394`），调用方无法从类型上看出"跨进程不互斥"。容器多副本部署（两个进程挂同一 `llm_metaStorePath`）时，两边都会抢到租约、各跑一轮演进，与注释承诺相反；而 #1 说明这个目录本来就可能被多个实例打开。
- **建议**：二选一并写进文档：①真做跨进程（f_store 增加 `addIfAbsent` / `replaceIfEquals` 语义，`acquire` 用它实现 CAS，失败即返回空串）；②把接口注释改成"仅进程内互斥，跨进程需外部锁"，并把 `acquire` 的返回值语义（空串 = 未领到）写进 README。不要在 `99` 行保留"多进程保证"这种无法兑现的措辞。

### [一般][存量] #6 `FStoreMetaStore` 家族完全无同步，而实例被 `LoomStoreGateway` 跨线程共享：`prompts.remove` 的 latest 重算、`conf.put` 的 `nextId` 都是检查-然后-写入

- **位置**：`f_llm/src/store/FStoreMetaStore.cj:92-99`（`put`：`nextId()` + 两次 `store.add`）、`:163-170`（`nextId`：读 `SEQ` → +1 → 写回）、`:327-351`（`remove`：删主体后扫前缀重算 `latest`）、`:246-251`（`upsert`：主体 + title 索引两次写）
- **来源**：存量（快照模式，无基线可比）
- **判据**：review-checklist §12.1「检查-然后-写入」「共享可变状态无保护」
- **证据**：静态确定 —— 这四个类（`FStoreLLMConfStore` / `FStoreCharacterStore` / `FStoreSkillStore` / `FStorePromptStore`）没有任何 `Mutex`/`synchronized`，而同模块 `FStoreEvolutionStore`（`EvolutionStore.cj:167`）、`FStoreEvolutionStateStore`（`EvolutionStateStore.cj:190`）、`FStoreEvolutionLease`（`EvolutionLease.cj:177`）都加了锁 —— 同一份存储三种同步策略。共享路径明确：`LoomStoreGateway` 在构造时把 `meta` 存成字段（`f_llm/src/loom/LoomStoreGateway.cj:70-71`），随后 `skills.upsert` / `prompts.put` / `prompts.remove` / `characters.set` 都在工具调用里执行（`LoomStoreGateway.cj:216`、`:308`、`:317`、`:330`、`:334`），工具调用来自并发的对话请求。
- **描述**：`prompts.remove` 是典型检查-然后-写入：先删版本键，再 `prefix` 扫剩余版本重算 `latest` 指针；两个并发 `remove`（或 `remove` 与 `put`）交错时，`latest` 可能指向已被删除的版本，或把刚 `put` 的新版本指针覆盖回旧值 → `latest(name)` 返回 `None`／旧版本。`conf.put` 的 `nextId` 并发时两边读到同一个 `SEQ` → 同一个 id → 后写覆盖前写（配置丢失）。虽然 `confs.put` 目前没有生产调用点（只有 `FStoreMetaStore_test.cj:147`），`prompts` / `skills` / `characters` 的写路径是活的。
- **建议**：给 `FStoreMetaStore` 加一把实例级 `Mutex`（与 Evolution 系列一致），把 `nextId`、`latest` 重算、`upsert` 的双写包进同一个临界区；更好的做法是把"id 分配"下沉到 `f_store` 的原子自增（`Store` 已有 `AtomicInt64 sequence`）而不是读-改-写一个普通键。`prompts.remove` 建议改成"先算新 latest、再删主体"（与接口注释 `StoreContracts.cj:106` 的说法一致），把两次写放在同一临界区。

### [一般][存量] #7 `LLMConfStore.put` 契约写"新增/覆盖"，两个实现都只追加 —— 重复 `put` 同一条配置会产出重复候选

- **位置**：接口 `f_llm/src/store/StoreContracts.cj:115-116`（"新增/覆盖一条配置"）；实现 `FStoreMetaStore.cj:92-99`（`nextId()` 永远 +1，不查已有 provider/llmName）、`InMemoryStores.cj:415-418`（`views.add(view); Int64(views.size)`）
- **来源**：存量（快照模式，无基线可比）
- **判据**：review-checklist §11「契约与实现不符」、§2「近似重复导致的行为漂移」（两个实现同错）
- **证据**：静态确定 —— `put` 的 id 来源分别是"`SEQ` 键 + 1"和"`views.size`"，两者都不做"按 (provider, llmName, actualLlmName) 查找既有记录并覆盖"。`candidates(llmName)` 只按 `BYNAME` 前缀返回（`FStoreMetaStore.cj:121-140`），不做去重；`names()` 用 `has()` 去重（`112`），所以表现是"名字只出现一次、候选却有多条"。
- **描述**：`StoreMetaConfSource.load()`（`service/StoreMetaConfSource.cj:42-63`）按 `names()` × `candidates()` 展开，重复 `put` 会让同一模型出现多行 `LLMConf`（id 递增、weight 相同），权重选择/熔断会把同一个端点当成多条候选。运营侧"改一条配置的权重"这种最自然的操作在当前实现下只能新增一条，旧记录永远留在候选池里。
- **建议**：`put` 改为按 (provider, llmName, actualLlmName) 唯一：先扫 `BYNAME{llmName}:` 找到同名记录，命中则用同一 id 覆盖主体（并清掉改名后的旧索引），未命中才 `nextId()`；`candidates` 里按 id 去重。若"覆盖"不是本意，就把接口注释改成"新增（同一条重复 put 会产生多个候选）"，并把这条写进 README。

### [一般][存量] #8 `InMemoryEvolutionStore.bySkill` 只扫最新 1000 条，老记录静默查不到（与 FStore 实现语义不一致）

- **位置**：`f_llm/src/store/EvolutionStore.cj:118-129`（`for (entry in list(0, 1000))`）
- **来源**：存量（快照模式，无基线可比）
- **判据**：review-checklist §11「边界 / 静默丢数据」、§2「两实现语义漂移」
- **证据**：静态确定 —— `list(0, 1000)` 先按 `at` 倒序取前 1000 条，再在其中按 `skillTitle` 过滤并截断到 `limit`。条目总数 > 1000 时，某技能的历史记录只要不在最新 1000 条内就完全不出现；而 `FStoreEvolutionStore.bySkill`（`:223-238`）走 `IDX` 前缀索引，扫的是该技能的全部记录，语义是"这个技能最近的 N 条"。
- **描述**：`1000` 是硬编码且未写进注释。`SkillEvolutionLedger.history(store, skillTitle, ...)`（`f_llm/src/loom/SkillEvolutionLedger.cj:57`）在内存后端下对"老技能"会返回空或残缺，测试（`EvolutionStore_test.cj:48`，只有 3 条）覆盖不到。
- **建议**：内存实现也维护 `HashMap<String, ArrayList<EvolutionEntry>>` 的按技能索引（或至少在 `bySkill` 里遍历全部 `entries` 而不是 `list(0,1000)`）；若确实要上限，把常量提成参数并在接口注释写明"只回看最近 N 条"。

### [一般][存量] #9 持久化字段用 `Int64.parse` / `Float64.parse` 直读，一条脏记录就会让整表读取抛异常

- **位置**：`f_llm/src/store/FStoreMetaStore.cj:180`（`Float64.parse(parts[7])`）、`:182`（`Int64.parse(parts[3])`）、`:271`（`Int64.parse(segments[3])`）、`:293`（`Int64.parse(parts[3])`）、`:321`（`Int64.parse` 读 latest 指针）、`:340`（`Int64.parse(segments[4])`）
- **来源**：存量（快照模式，无基线可比）
- **判据**：review-checklist §11「错误处理缺失 / 失败路径当成功」、§3「静默吞异常」的反面（这里是从"静默"跳到"整表不可用"）
- **证据**：静态确定（不一致性）—— 同一模块的 `FStoreEvolutionStateStore.readState` / `readRun`（`EvolutionStateStore.cj:282`、`:290`）对同类文本用 `Int64.tryParse(...) ?? 0` 兜底，而 `FStoreLLMConfStore.parse` / `FStoreSkillStore.list` / `FStorePromptStore.latest` 全部用会失败的 `parse`。`parse` 对非法文本的确切失败语义（抛 `IllegalArgumentException` 还是别的）未在仓内文档核对，属 `待确认`；但无论哪种，它与同文件另一处的兜底策略不一致这一点是确定的。
- **描述**：`parse` 的调用者是 `names()` / `candidates()` / `list()` / `latest()` 的循环体 —— 一条 `weight` 或 `version` 字段损坏的记录会让**整次** `names()`/`list()` 中断，`LLMConfs.createHolder` 的 `try { StoreMetaConfSource(...) } catch { 走旧来源 }`（`f_llm/src/llm/LLMConfs.cj:52-57`）会把整个模型配置降级到旧来源，现场表现是"配置明明在库里，服务却用了另一套"。
- **建议**：统一改成 `tryParse` + 默认值 + `LoggerFactory.getLogger<...>().warn('skip corrupt record ${key}')`；对可确定是结构损坏的记录（段数不足）沿用现在的"返回默认视图"不如直接跳过并告警。补一条用例：写入一条 `weight` 非数字的记录，断言 `candidates` 跳过它而不是抛异常。

### [一般][存量] #10 `DeployPaths.root()` 依赖 `getCommand()` 的 argv[0]：裸命令名启动时退化成 CWD，`canonicalize` 失败也没有兜底

- **位置**：`f_llm/src/store/DeployPaths.cj:30-42`（`canonicalize(Path(getCommand()).parent)`、`path.fileName == 'bin'`）、`:45-60`（`resolve`）
- **来源**：存量（快照模式，无基线可比）
- **判据**：review-checklist §11「契约与实现不符」、§12.1「惰性初始化」（`cached` 无同步，见覆盖自检）
- **证据**：静态确定 + 待确认 —— 静态：`root()` 只有一条推导路径，没有失败分支；`canonicalize` 对不存在/不可规范化的路径抛 `FSException`（同仓 `docs/review/2026-11-28/f_cmd.md:31-38` 已就同一 API 记录过这一点），`root()` 不捕获，异常直接冒到 `resolve()` 的调用者（`FStoreMetaStore.cj:50`、`FStoreEvolutionStateStore.cj:198` 等构造期）。待确认：`env.getCommand()` 在"以裸命令名（经 PATH 解析）启动"时返回绝对路径还是 argv[0] 原样；若返回 `argv[0]`，`Path('app').parent` 是 `'.'`，`canonicalize('.')` 就是**进程 CWD**，与类注释 `24-25` "存储路径一律相对部署目录，而不是进程 CWD"相反。
- **描述**：该类的全部价值就是这个推导；一旦落到"argv[0] 是裸名"或"二进制不在 `bin/` 下"，`llm_metaStorePath = './data/f_llm-meta'`（`StoreSettings.cj:41` 默认值）就会写到 CWD 下，systemd/容器里通常是 `/` 或只读目录，表现为启动时 f_store 建目录失败或数据写到意外位置 —— 正是注释里说要避免的场景。`resolve` 另外只识别 `'/'` 前缀，Windows 盘符路径（`C:\...`）会被当相对路径拼接。
- **建议**：优先用 `env.getCommandLine()[0]`（`f_config/README.md:49` 明确这是"程序自身路径"）并做一次 `canonicalize`；失败时回退到 `Path(getCommand()).parent` 的绝对化结果，再失败才退回 CWD，并把回退原因 `warn` 出来。`resolve` 增加 `Path.isAbsolute()` 判定而不是只比 `'/'`。

### [一般][存量] #11 `InMemoryKnowledgeStore` 删除/覆盖文档时不清 `vectors` —— 块向量永久残留

- **位置**：`f_llm/src/store/InMemoryStores.cj:197-210`（`upsert` 只写 `vectors[chunkKey(docId, seq)]`）、`:216-224`（`remove` 只删 `chunks` / `docs`）
- **来源**：存量（快照模式，无基线可比）
- **判据**：review-checklist §11「资源不对称」、§7「缩短生命周期 / 注册表不注销」
- **证据**：静态确定 —— `vectors` 的键是 `'${docId}#${seq}'`（`:291-293`），`remove(docId)` 没有任何 `vectors` 相关语句；`upsert` 在块数变少时也不会删掉 `seq >= 新块数` 的旧键。而 `KnowledgeStore.remove` 的契约是"删除正文与全部块"（`StoreContracts.cj:73`）。
- **描述**：装了 `Embedder` 时每条块向量是 `Array<Float64>`（1024 维 ≈ 8 KB + 头），`remove` 后这些向量仍被 `vectors` 强引用 → 泄漏；`upsert` 缩短文档时同样留下"孤儿向量"。因为 `search` 只遍历 `chunks` 里的块，孤儿向量不会被读到，所以表现为"删了文档但内存不降"，而非错误结果 —— 这正是 `mem §1` 那类"GC 后 RSS 不回落"的现场。
- **建议**：`remove` 里按 `chunks.get(docId)` 的块数逐个 `vectors.remove(chunkKey(docId, i))`；`upsert` 覆盖前先清该 docId 的旧向量（或改为 `HashMap<String, ArrayList<Array<Float64>>>` 与 `chunks` 同生命周期）。类注释里补一句"向量与块同生共死"。

### [一般][存量] #12 `InMemoryCharacterStore.set` 不校验 `characterKey`，与 `FStoreCharacterStore.set` 行为相反

- **位置**：`f_llm/src/store/InMemoryStores.cj:303-305`（直接写 map）对照 `f_llm/src/store/FStoreMetaStore.cj:219-225`（`PredefinedCharacters.isKnown` 不通过就抛 `IllegalArgumentException`）
- **来源**：存量（快照模式，无基线可比）
- **判据**：review-checklist §2「近似重复 / 行为漂移」、§11「契约与实现不符」
- **证据**：静态确定 —— `CharacterStore.set` 的接口注释（`StoreContracts.cj:85-90`）没有写"校验预定义 key"，但两个实现对同一输入给出不同结果：FStore 抛异常、内存实现接受任意串。测试也只覆盖了 FStore 侧（`FStoreMetaStore_test.cj:91-100`）。
- **描述**：内存后端（`InMemoryMetaStore`，单测与本地演示用）会接受 `characterKey = 'not-exist'`，随后 `LoomRunner` 取 `PredefinedCharacters.bodyOf(key)` 拿不到人格体，落到默认分支（`f_llm/src/loom/LoomRunner.cj:410-415`）—— 表现是"人格静默不生效"，而在生产后端同样输入会直接报错。跨后端一致性测试（`store/it/MetaConformance_test.cj`）没有覆盖这条分支。
- **建议**：把校验上移到 `CharacterStore` 的公共入口（或 `Character` 的构造/`set` 前置检查），两个实现共用；内存实现也抛 `IllegalArgumentException`，并给 `MetaConformance_test` 补一条"未知 key 在两个后端都拒绝"的用例。

### [轻微][存量] #13 §2 重复逻辑：两处手写插入排序、三处线性 `contains`、四处 4 字节小端拼装

- **位置**：
  - 插入排序：`f_llm/src/store/EvolutionStore.cj:98-106`（按 `at`/`id` 倒序）与 `f_llm/src/store/InMemoryStores.cj:273-281`（按 `docId` 字典序）
  - 线性包含：`f_llm/src/store/FStoreMetaStore.cj:186-193`（`has`）、`f_llm/src/store/InMemoryStores.cj:420-427`（`InMemoryLLMConfStore.contains`）、`f_llm/src/store/InMemoryStores.cj:430-437`（`containsText`）
  - 4 字节小端：`f_llm/src/store/ColbertCodec.cj:36-40`（写 float 内联）、`:61-64`（读 float 内联）、`:73-79`（`writeInt32`）、`:81-87`（`readInt32`）
- **来源**：存量（快照模式，无基线可比）
- **判据**：review-checklist §2「只改类型名 / 字面量复制」
- **证据**：静态确定 —— 三组代码逐行对齐，差异只有元素类型与比较函数。
- **描述**：插入排序那份还同时是低效算法与锁内长临界区：`InMemoryEvolutionStore.list` 在 `synchronized(mutex)` 内对**全量**条目做 O(n²) 排序（`EvolutionStore.cj:92-114`），条目上千后每次 `list` 都持锁做平方级工作，`bySkill`（`:120`）还会再调一次。三份 `contains` 语义完全相同（线性查找字符串），任何一处改成 `HashSet` 都不会同步到另两处。`ColbertCodec` 的四个 4 字节小端片段里，`encode`/`decode` 的向量循环没有复用 `writeInt32`/`readInt32`，字节序一旦要改（例如加 magic 或改成大端）必须改四处。
- **建议**：排序抽成模块内 `internal func sortBy<T>(items: ArrayList<T>, less: (T, T) -> Bool)`（或直接用 `std.sort`），并让 `InMemoryEvolutionStore` 在锁内只做"拷贝 + 粗排索引"，排序移到锁外；三份 `contains` 合并为 `InMemoryStores.cj:430` 的 `containsText(Array<String>, String)` 一个实现（`ArrayList<String>` 传 `toArray()` 的代价大于收益时，改成泛型 `Iterable<String>`）；`ColbertCodec` 加 `writeFloat32`/`readFloat32` 两个私有函数，让 encode/decode 循环只调它们。

### [轻微][存量] #14 §1 死代码：`ColbertCodec.decode` 的空 `if` 分支（无语句、无副作用）

- **位置**：`f_llm/src/store/ColbertCodec.cj:52-54`
- **来源**：存量（快照模式，无基线可比）
- **判据**：review-checklist §1「恒真恒假分支 / 无作用语句」
- **证据**：静态确定 —— 分支体只有注释（"维度不是 1024 也允许，按剩余字节推断"），没有任何语句；条件表达式本身也没有赋值或调用，整个 `if` 可删而对行为零影响。
- **描述**：它标记的是"本该在这里做维度/长度校验"的位置（见 #3），留着会让人以为校验已经存在。
- **建议**：按 #3 的建议把校验补上；若决定不做校验，直接删掉这个 `if` 并把"维度由字节数反推"写进函数注释。

### [轻微][存量] #15 §1 未使用的 `import`（5 处）

- **位置**：`f_llm/src/store/EvolutionLease.cj:19`（`import std.convert.*`）、`f_llm/src/store/FStoreMetaStore.cj:21-22`（`import fountain::f_bean.*` + `fountain::f_bean.macros.*`）、`f_llm/src/store/EvolutionLease_test.cj:18`、`EvolutionStateStore_test.cj:18`、`EvolutionStore_test.cj:18`（三处 `import std.collection.*`）
- **来源**：存量（快照模式，无基线可比）
- **判据**：review-checklist §1「未使用的 import」
- **证据**：静态确定 —— `EvolutionLease.cj` 全文无 `parse` / `tryParse` / 任何 `std.convert` 符号（`String.fromUtf8` 属核心库，同仓 `f_llm/src/loom/Plan.cj` 未 import `std.convert` 也在用）；`FStoreMetaStore.cj` 无 `@Bean` / `lookupOption` / `ConfCond`；三个测试文件里没有 `ArrayList` / `HashMap` / `StringBuilder` 等集合类型（`Array` 是核心类型）。
- **描述**：`std.convert` 在多处是"顺手带上"，容易掩盖真正的依赖；`FStoreMetaStore` 的 `f_bean` 依赖更会误导读者以为该类是通过 bean 容器装配的（实际由 `StoreWiring` / `MetaStoreAdapter` 直接 `new`）。
- **建议**：删除这 5 行 import（仓颉编译器对未使用 import 的告警在 `cjpm` 默认配置下不阻断，所以一直没被清理）。

### [轻微][存量] #16 注释与实现不符（3 处，均会误导维护者）

- **位置**：
  - `f_llm/src/store/EvolutionLease.cj:34`（"生成时间型 UUID（f_util 的 v6：重排后的 v1）"）→ 实际是 **v7**（`f_util/src/uuid.cj:378-409`，version nibble 写 `7 << 4`）
  - `f_llm/src/store/EvolutionLease.cj:42-43`（"v7 的高 48 位就是毫秒时间戳，直接按十六进制解析前 12 个字符"）与 `:69-70`（"右移了 16 位……解码时补回来"）**互相矛盾**，实现取的是后者
  - `f_llm/src/store/InMemoryStores.cj:24`（"不注册进 `Stores`（§5.3）"）→ `StoreWiring.cj:60` 明确 `ensure('inMemory', { => InMemoryContentStore() })`
- **来源**：存量（快照模式，无基线可比）
- **判据**：review-checklist §13「文档过期 / 规格与实现漂移」（本条针对 `.cj` 内的契约性注释）
- **证据**：静态确定 —— 上述三处均可用"注释描述的版本号/位移/注册关系"与对应代码行直接对照。
- **描述**：第一条和第二条共同掩盖了 #4 的精度问题（读者会以为"直接解析毫秒"所以很准）；第三条会让人误判内存后端在生产不可达（进而低估 #2 的影响）。
- **建议**：把 `create()` 的注释改成 "v7（RFC 9562 时间型 UUID）"，删掉 `42-43` 的"直接解析"表述、统一到 `69-70` 的位移说明并补上"低 16 位被截断 ⇒ 精度 65.5 s"；`InMemoryStores` 的头注释改成"只用于单测与本地演示；`inMemory` 内容族已在 `StoreWiring` 注册，非线程安全"。

### [轻微][存量] #17 `FStoreEvolutionStore` 的显式 id 路径：`nextId` 不与库内最大 id 对齐，后续自增 id 可能覆盖既有记录

- **位置**：`f_llm/src/store/EvolutionStore.cj:179-202`（`if (id <= 0) { if (nextId <= 0) nextId = maxId(); … } else if (id > nextId) { nextId = id }`）
- **来源**：存量（快照模式，无基线可比）
- **判据**：review-checklist §11「边界 / 数据覆盖」
- **证据**：静态确定 —— 新实例 `nextId == 0`；若第一次 `save` 带显式正 id（例如 `id = 3`），走 `else if (id > nextId)` 分支只把 `nextId` 置为 3，**不会**调用 `maxId()`；随后自增写入得到 `id = 4`，而库里可能已经存在 id 4（上一次进程写入），`store.add(DATA4, …)` 直接覆盖（同时新增一条指向同一 data key 的索引）。仓内所有调用点都传 `id = 0`（`SkillEvolutionLedger.cj:70`、各测试），所以这条路径目前无人走。
- **描述**：接口注释（`StoreContracts` 之外的 `EvolutionStore.cj:59`）写"`entry.id <= 0` 时自动分配"，隐含"显式 id 由调用方保证唯一"，但没有校验，也没有测例覆盖混用场景。
- **建议**：`save` 开头统一 `if (nextId <= 0) { nextId = maxId() }`（不看 `id` 正负），并且显式 id 大于零时也用它参与 `nextId` 推进；补一条用例"显式 id 3 之后自增得到 4"。

### [轻微][存量] #18 本部分测试的隔离性：固定 `/tmp` 目录 + 非原子全局计数 + 秒级路径

- **位置**：`f_llm/src/store/FStoreMetaStore_test.cj:25`（`private var confDirSeq`）、`:27`（`META_PATH = '/tmp/fllm-meta-test'`）、`:35-42`（`metaPath()` 每次先 `remove(..., recursive: true)`）、`:123`/`:132`（用"当前秒"做目录名）
- **来源**：存量（快照模式，无基线可比）
- **判据**：review-checklist §11「并发正确性（测试自身）」
- **证据**：静态确定 —— `metaPath()` 在**每个用例**开头删同一个固定目录：`testCharacterSurvivesRestart`、`testResetRemovesCharacter`、`testPredefinedKeysAccepted`、`testUnknownKeyRejected`、`testCustomPromptsPreserved` 共用 `/tmp/fllm-meta-test`，并行执行时互相清库；`confDirSeq++`（`:112`、`:142`）是无锁全局自增；`testSkillVersionAndList` / `testPromptLatestAndMissing` 用 `DateTime.now().toUnixTimeStamp().toSeconds()` 命名，同一秒内重跑会读到上轮残留（`list().size` 断言随之波动）。
- **描述**：这些用例本身在注释里承认"跨运行、跨 worktree 都不自动清理"，说明已经被残留坑过一次；改用固定目录+前置删除只能解决串行场景。若 `cjpm test` 默认并行跑用例（仓颉 `unittest` 支持并行执行），这套测试会出现随机失败。
- **建议**：所有用例统一用 `UUID.random().toHexString()` 生成独立临时目录（同文件里 `EvolutionLease_test.cj:33-35` 已经是这种写法），并删掉 `metaPath()` 的"先删固定目录"逻辑；需要"同路径重开"语义的用例自己建目录再传同一个路径。

### [轻微][存量] #19 键编码不转义：`':'` / `'|'` / `'\n'` 作分隔符，名字里出现分隔符时静默丢配置或错解析

- **位置**：`f_llm/src/store/FStoreMetaStore.cj:97`（`byname:{llmName}:{id}`）、`:104-108` 与 `:125-129`（按 `split(':')` 的第 6 段取 id）、`:248`（skill 主体 `title|details|functions|version`）、`:289-293`、`:307-308`（prompt `{name}:{version}`）、`:336-340`（`split(':')[4]`）
- **来源**：存量（快照模式，无基线可比）
- **判据**：review-checklist §11「边界 / 语义与注释不符」
- **证据**：静态确定（触发条件待确认）—— 解析侧一律按 `:`（或 `|`）切分并按下标取值，写入侧不校验、不转义。`llmName = 'openai:gpt-4o'` 时键变成 `…:byname:openai:gpt-4o:7`，`segments.size == 7`，`id = segments[5] == 'gpt-4o'` → `store.get('…:conf:gpt-4o')` 为 `None` → 该模型**静默不出现在候选里**。`FStoreEvolutionStore` 的索引键已经采用"标题长度 + 标题"的防污染方案（`EvolutionStore.cj:154-160`），说明作者知道这个坑。
- **描述**：待确认的是"仓内是否会出现含 `:` 的 llmName / prompt 名 / skill 标题"。`f_llm/doc/f_llm.md:255-256` 只写了键格式，没写字符约束；`PromptEntry.name` 现有取值是 `memory.extract` 这类点分名，暂未踩到。
- **建议**：与 `EvolutionStore` 统一，把不定长字段改成"长度前缀"（`${name.size}:${name}`）或对 `:`/`|`/`\n` 做百分号转义；至少在 `LLMConfView` / `PromptEntry` / `Skill` 的字段注释里写明"不得包含分隔符"，并在 `put`/`upsert` 入口校验后抛 `IllegalArgumentException`。

### [一般][存量] #20 `StoreMetaConfSource.load()` 丢掉 `LLMConf.conf` 扩展项，provider 方言路径 / tokenizer / thinking 全部退回默认

- **位置**：`f_llm/src/service/StoreMetaConfSource.cj:48-59`（只逐字段搬 9 个属性，没有 `conf.setConf`）；`f_llm/src/store/StoreModels.cj:168-192`（`LLMConfView` 无 `conf` 字段）；`f_llm/src/model/po/LLMConf.cj:70-77`（`confJson` 默认 `'{}'`）
- **来源**：存量（快照模式，无基线可比）
- **判据**：review-checklist §14.1「能力未接入 / 只做了一半的分支」、§13「契约与实现不符」
- **证据**：静态确定 —— `LLMConfView` 的字段只有 provider/llmName/actualLlmName/weight/enabled/llmUrl/auth/temperature/alwaysThinking，`load()` 逐个赋值后返回；`LLMConf.conf` 读的是 `confJson`，未 `setConf` 时为空表。而 `conf.option(...)` 承载了大量行为：`openai/ProviderDialect.cj:61-62` 的 `chatPath`/`responsesPath`、`embedding/Embedding.cj:123` 的 `embeddingPath`、`llm/ModelCapabilities.cj:32` 的 `thinking`、`llm/TokenCounter.cj:62` 的 `tokenizerUrl`、`balance/BalanceQueriers.cj:248-249` 的 `accessKeyId`/`secretKey`。
- **描述**：`llm_metaStore=f_store|postgres|mysql` 时 `LLMConfs.createHolder()` 优先走 `StoreMetaConfSource`（`f_llm/src/llm/LLMConfs.cj:51-53`），凡是从 store 读到的配置都不带扩展项：非默认端点的 provider 会打到 `/chat/completions` 默认路径、`thinking=toggle` 的模型不再按需开启思考、余额查询拿不到 AK/SK，且没有任何日志提示。与 JSON / 数据库来源的行为不一致，属于"配置看着生效、实际参数被悄悄丢弃"。
- **建议**：`LLMConfView` 增加 `conf: HashMap<String, String>`（或 `confJson: String`），`FStoreLLMConfStore.put/parse` 用 `SEP` 追加第 10 段并向后兼容旧 9 段格式，`load()` 里 `conf.setConf(view.conf)`；若短期不打算支持，则在 `LLMConfSource` 接口注释与 README 明写「store 来源不支持 conf 扩展项」。

### [一般][存量] #21 配置 id 由遍历序号生成，配置增删后熔断状态与 `usage.llmId` 会串到别的模型

- **位置**：`f_llm/src/service/StoreMetaConfSource.cj:44`（`var seq: Int64 = 0`）、`:49`（`conf.id = seq`）；消费侧 `f_llm/src/llm/LLMConfsHolder.cj:242`（`byId[conf.id] = conf`）、`:257`（`breaker.cleanup(HashSet(byId.keys()))`）、`f_llm/src/llm/LLM.cj:169`（`result.usage.llmId = conf.id`）
- **来源**：存量（快照模式，无基线可比）
- **判据**：review-checklist §11「语义与命名不符 / 契约与实现不符」
- **证据**：静态确定 —— id 是 `names()` × `candidates()` 的遍历序号（1..n），与 `FStoreLLMConfStore` 里真实的 `f_llm:meta:conf:{id}` 无关；`LLMConfsHolder.refresh` 以 `conf.id` 建 `byId` 并只清理"本次不存在的 id"，即熔断器按 id 长期持有状态。
- **描述**：插入一条排在扫描序前面的配置、或改掉某个 llmName 后，同一 id 会指向另一个模型：对 A 打开的熔断会继续拦 B，B 的成功又会重置 A 的失败计数；`usage.llmId` 统计同样错位。因为序号每次 `load()` 重新生成，这不是一次性错位，而是每次配置变更整体平移。
- **建议**：`LLMConfView` 带上真实 id（`LLMConf` 已有 `id` 字段）并用它，而不是遍历序号；在改动前，至少把熔断键从 `conf.id` 换成 `provider + llmName + url`，并在类注释写明「id 仅在单次快照内有效」。

### [一般][存量] #22 inMemory 模式存在两份 `MemoryStore`，且 `Stores.content()` 每次调用新建实例 —— 两个入口互相看不到对方写入的记忆

- **位置**：`f_llm/src/store/InMemoryStores.cj:29`（`private let memoryStore = InMemoryMemoryStore()`）、`:83-85`（另一个 `@Bean` 单例）、`f_llm/src/store/Stores.cj:74-81`（`content()` 每次 `factory()`）、`f_llm/src/store/MemoryStoreAdapter.cj:38-41`、`f_llm/src/loom/LoomStoreGateway.cj:70`
- **来源**：存量（快照模式，无基线可比）
- **判据**：review-checklist §14.1「接线缺失 / 只做了一半的分支」、§11「契约与实现不符」
- **证据**：静态确定 —— `Stores.content()` 每次 `factory()` 新建，因此每次拿到新的 `InMemoryContentStore`，其内部 `memoryStore` 字段也是新对象；`MemoryStoreAdapter` 走的是 `lookupOption<MemoryStore>()` 的 bean 单例。两条路径指向两个不同实例（`f_llm/README.md:135` 把 `Stores.content().memory` 写成读写记忆的标准入口，`Memory.cj:134` 走适配器）。
- **描述**：`llm_memoryStore=inMemory` 下，`Memory.remember` 写入的记忆落在 bean 实例；`LoomStoreGateway` 持有 `Stores.content()` 写入/检索的是另一个实例，loom 侧永远搜不到这些摘要，反向亦然。表现为"刚记住的事下一轮就忘了"，且只在内存后端出现，SQL 后端因为落同一张表而看不到这个问题。
- **建议**：`InMemoryContentStore` 复用 `lookupOption<MemoryStore>()` 的 bean（测试场景保留注入构造），或让 `Stores` 对 `inMemory` 返回单例；同时修正 `InMemoryStores.cj:24`「不注册进 `Stores`」的注释（实际 `StoreWiring.cj:60` 已注册）。

<!-- 第 21 部分 -->

> 交叉引用编号 #N 按下列标题出现顺序编号（#1–#26；#1–#21 来自首轮通读，#22–#26 来自第二轮独立复核），用于「文件覆盖」与「覆盖自检」中的指代。

### [严重][存量] `MemoryRepositoryAdapter` 未转发 `listByKind`，生产路径的 kind 过滤退化为「先分页后过滤」，静默丢记录

- **位置**：`f_llm/src/store/MemoryRepositories.cj:28-74`（适配器只转发 9 个方法，**无 `listByKind`**）；近似实现 `f_llm/src/store/MemoryRepository.cj:72-82`；上抛链 `f_llm/src/store/PostgresMemoryStore.cj:83-85` → `f_llm/src/store/StoreContracts.cj:54-64`；真实消费方 `f_llm/src/loom/LoomStoreGateway.cj:155-162`
- **来源**：存量（`git blame`：`MemoryRepositories.cj:28-33` = `ff71f4bb97`/`945d571899`，2026-10-30；接口默认实现在 `MemoryRepository.cj` 同批提交）
- **判据**：review-checklist §11「契约与实现不符」、§2「近似重复：一块少了边界判断，往往同时是缺陷」、§14.1「接线缺失」
- **证据**：静态确定 —— ① `MemoryRepository`/`MemoryStore` 两处接口的默认 `listByKind` 都是 `list(offset, limit)` 取一页再按 `kind` 过滤，注释自认「近似的…否则 `limit` 很小时会漏掉目标记录」（`MemoryRepository.cj:66-82`）；② `PostgresMemoryRepository` 与 `MySqlMemoryRepository` 都已把条件下推 SQL（`f_llm/src/store/postgres/MemoryRepository.cj:112-119`，注释「kind 条件下推到 SQL：先过滤再分页」）；③ `MemoryRepositoryAdapter` 未覆写 `listByKind`，因此在**生产装配路径**（`SqlMemoryStore()` → `MemoryRepositoryAdapter` → `lookupOption<MemoryRepository>()`，见 `PostgresMemoryStore.cj:35-38`）调用落到接口默认实现，精确覆写被绕过
- **描述**：`PostgresContentStore.memory` 就是 `SqlMemoryStore()`（`f_llm/src/store/postgres/ContentStore.cj:31-41`，`SqlMemoryStore()` 在 `:36`），所以 Loom 的 `memory list` + `kind` 过滤（`LoomStoreGateway.cj:155-162`，注释写「交给 Store 过滤：先过滤再分页，**不会出现「本页没有就判空」**」）走的是近似版：先按 `pageOf` 取一页（默认 50 条）再过滤，若这 50 条里恰好没有目标 kind，**返回空数组**，调用方（流程/模型）会认为"该用户没有这条记忆"。数据没坏，但读结果系统性偏少，且随 kind 分布稀疏程度放大
- **同一根因的第二条路径（`search`，不是 `list`）**：`SqlMemoryStore.search` 把 `topK * 2` 交给仓储后，才在内存里按 `query.kinds` 过滤（`PostgresMemoryStore.cj:90-93`、`:109-113`、`:195-206`），而 DAO 的两条召回 SQL 都没有 kind 条件（`f_llm/src/dao/postgres/MemoryDAO.cj:66-74` 与 `:114-124` 的 `WHERE` 只有 `user_id` 与 `namespace IN`）。因此「只要 `kind='experience'`、topK=5」时，若截断窗口里的 10 条大多是 `session`，最终只返回 2 条甚至 0 条——即使库里还有上千条 `experience`（`LoomStoreGateway.cj:86-90,181-191` 会给 experience 工具传默认 kind，不是边缘用法）。`MemoryStoreAdapter.listByKind`（`MemoryStoreAdapter.cj:60-63`）本身转发正确，这里的漏读来自它委托到的 `SqlMemoryStore` → `MemoryRepositoryAdapter` 默认实现，不是适配器少写了一层
- **建议**：`MemoryRepositoryAdapter` 补 `public func listByKind(...) { delegate.listByKind(...) }`（与其余 9 个方法同形）；`SqlMemoryStore` 同样显式转发而不是依赖接口默认实现；把 `kind` 条件也下推进 `searchDense`/`searchSparse` 的 DAO（与 `namespace` 同一写法），或改成有界翻页直到凑满 topK；把接口默认实现改为 `throw UnsupportedException` 或明确标注「仅测试用」，避免"看起来能跑"的近似路径继续被继承；补两条用例：「kind 记录分散在 2 页之后仍能取到 limit 条」「按 kind 检索时截断窗口被其它 kind 占满仍能返回 topK」

### [严重][存量] 启动索引重建根本没接线：`llm_rebuildIndexOnStart` 全链路无运行时调用者，文档承诺的「启动时重建」不成立

- **位置**：`f_llm/src/store/MemoryIndexRebuilder.cj:46-56`（`rebuildIfConfigured` 是唯一读配置的入口，**零调用者**）；配置读取 `f_llm/src/store/MemoryIndexRebuilder.cj:48-52`；承诺源 `f_llm/README.md:305`、`f_llm/README_en.md:303`、`f_llm/README.md:771`、`f_llm/doc/f_llm.md:320-321`、`f_llm/doc/f_llm-memory-design.md:114-115`
- **来源**：存量（`git blame`：类与入口来源 2026-10 批次；工作区无改动）
- **判据**：review-checklist §14.1「承诺了但没实现 / 接线缺失：配置项被读取却从未使用」、§3「开关打开后走进空分支（功能未接完）」、§11「与规格 / README 冲突」
- **证据**：静态确定 —— ① 全仓（排除 `.worktrees`）搜 `rebuildIfConfigured` / `MemoryIndexRebuilder.` / `Rebuilder` 只命中定义与 `*_test.cj`，无任何装配点；② 装配类 `f_llm/src/wiring/StoreWiring.cj:60-92` 只注册 Store bean 与 `seedKinds()`，不含重建调用；③ `LLMConfig.isIndexRebuildEnabled()` / `getIndexRebuildUserId()` / `getIndexRebuildNamespace()` 的唯一调用点就是 `rebuildIfConfigured` 自身（`f_llm/src/config/LLMConfig.cj:137-150`），即整条配置链在运行期不可达；④ 承诺写法明确是自动触发：「`KnowledgeIndexRebuilder` / `MemoryIndexRebuilder`：**启动时**按 `llm_rebuildIndexOnStart` 重建索引」（README.md:305）、「两者都不会自动触发，需要显式调用**或开 `llm_rebuildIndexOnStart`**」（doc/f_llm-memory-design.md:115）
- **描述**：使用者按文档置 `llm_rebuildIndexOnStart=true` 后不会发生任何重建：日志无 `memory index rebuilt`，索引照旧缺失，检索长期停在 `degraded` 的 dense-only 状态；同时 `KnowledgeIndexRebuilder` 连配置入口都没有（`f_llm/src/store/KnowledgeIndexRebuilder.cj:33-63` 只有 `rebuild`/`rebuildAll`），文档承诺的两条重建里有一条完全无从触发。这类"配置静默无效"最难排查——配置读到的值与行为无关联，且不会报错
- **建议**：在 `StoreWiring`（启动期、Store 装配之后）调用 `MemoryIndexRebuilder.rebuildIfConfigured(...)`，并把 `KnowledgeIndexRebuilder` 的配置入口补齐（复用同一组 key，或另开 `llm_rebuildKnowledge*`）；若决定不做自动触发，则改文档为"需显式调用"，并删掉 `rebuildIfConfigured` 与三个配置 getter 的死链

### [一般][存量] 稀疏/多头向量为空时无条件覆盖写：重建或重复 `add` 会把已有倒排与 colbert 索引清空，并计入"成功重建"

- **位置**：`f_llm/src/store/MemoryIndexRebuilder.cj:79-86`（`upsertSparse` / `upsertColbert` 不看空值）；`f_llm/src/store/PostgresMemoryStore.cj:52-62`（`add` 同源）；被调契约 `f_llm/src/store/MemoryRepository.cj:50-55`
- **来源**：存量（`git blame`：`PostgresMemoryStore.cj:60-68` = `8b70c78ce4`，2026-10-29）
- **判据**：review-checklist §11「错误处理缺失 / 边界」、§14.1「半成品：只处理部分输入」、§3「静默失效」
- **证据**：静态确定（契约 + 实现两侧）——`upsertSparse` 契约是「先删旧 token，再写新 token」，PG 实现第一步就是无条件 `DELETE FROM llm_memory_token WHERE memory_id = ?`（`f_llm/src/store/postgres/MemoryRepository.cj:53-62`），空 map 等于**清空**；`upsertColbert` 契约「空数组表示没有」，PG 实现直接覆盖列（`MemoryRepository.cj:64-68`），而 `ColbertCodec.encode([])` 产出的是「count=0 的 4 字节 blob」（`f_llm/src/store/ColbertCodec.cj:28-45`），旧向量被这一小段字节顶掉、`decode` 回来就是空数组。而 `HttpEmbedder.tokenize/embedColbert` 直接透传传输层结果，`EmbeddingResponse` 的 `sparse`/`colbert` 默认就是空（`f_llm/src/embedding/HttpEmbedder.cj:28-39`，透传见 `:85-91`），`LlmEmbeddingTransport` 更是只回 dense（`f_llm/src/embedding/LlmEmbeddingTransport.cj:23-26` 注释自认）
- **描述**：触发条件两条：① 换过嵌入端点（BGE-M3 → OpenAI 兼容）后开重建：`rebuild` 逐条 `upsertSparse(空)` / `upsertColbert(空, 空)`，把**旧模型下仍然可用的** sparse/colbert 索引整片删掉，`rebuilt++` 照常计数，日志报"成功重建 N 条"；② 同 `(user, namespace, title)` 覆盖写时嵌入器某一路返回空，同样会清空该记录原有的一路索引。结果不可回滚（旧向量没备份），只能再换回原模型重跑，而重跑又要求三路都非空
- **建议**：重建与 `add` 都加"本路非空才写"的守卫（`if (!tokens.isEmpty())` / `if (!titleVectors.isEmpty() || !contentVectors.isEmpty())`），跳过的记录单独计数并在日志区分 `rebuilt` / `skipped(noVector)`；`upsertSparse` 的空覆盖语义在接口注释里点明"空 map = 删除全部"，让调用方不敢直传

### [一般][存量] `MemoryHit.degraded` 语义不可靠（"查询无命中"被当成"缺一路"），且全仓无消费点

- **位置**：`f_llm/src/store/PostgresMemoryStore.cj:95`、`:115`；字段契约 `f_llm/src/store/StoreModels.cj:85-92`；承诺源 `f_llm/doc/f_llm.md:241,309`、`f_llm/doc/f_llm-memory-design.md:81-83,309`
- **来源**：存量（`git blame`：`PostgresMemoryStore.cj:95` 同 `8b70c78ce4` 批次，2026-10-29）
- **判据**：review-checklist §13「文档承诺与实现不符」、§14.1「降级标记未接线」、§11「语义与注释不符」
- **证据**：静态确定 —— `degraded = sparse.isEmpty()`；而 `searchSparse` 在两种完全不同的情况下都返回空：`tokens.isEmpty()`（查询文本切不出 token、或嵌入器只回 dense，见 `f_llm/src/store/postgres/MemoryRepository.cj:71-78`）与"有倒排但无命中"。文档把该字段定义为「某一路向量**缺失**」并明确「调用方据此判断结果可信度」（doc/f_llm.md:309），实现无法区分这两种语义；同时全模块搜 `degraded` 只命中 store 内构造与 `PostgresMemoryStore_test.cj:223` 一处断言，网关的检索响应序列化里没有该字段（`f_llm/src/loom/LoomStoreGateway.cj:194-207` 只有 `id/title/content/kind/score`）
- **描述**：两个后果叠加——① 误报：健康的 sparse 索引遇到"查询词全部未命中文档"时，整批结果被打上 `degraded`，运维据此排障会走向错误方向；② 断链：文档承诺的"可观测降级标记"没有任何仓内消费者，Loom 的 `memory search` 结果不携带它，流程侧拿不到可信度信号，等于承诺的观测点不存在
- **建议**：把"索引缺失"与"本次无命中"分开表达——`MemoryRepository` 增加能力探测（如 `hasSparseIndex(userId): Bool`）或让 `searchSparse` 返回 `(hits, available)`；`degraded` 只在一路**不可用**时置位。若保留现语义，则在字段注释与 doc 里改成"本次检索未产生 sparse 命中"，并在 `LoomStoreGateway` 的 JSON 里输出 `degraded`，否则该字段建议直接删掉

### [一般][存量] `add` 的三段写入非原子：`upsertSparse` 失败会留下"有记录无倒排"的脏数据；colbert 异常被空 catch 吞掉且零日志

- **位置**：`f_llm/src/store/PostgresMemoryStore.cj:46-69`（`upsert` → `upsertSparse` → `try/catch` colbert）
- **来源**：存量（`git blame`：`8b70c78ce4` 2026-10-29；`try{...}catch{}` 外壳 `be0999c476` 2026-11-07）
- **判据**：review-checklist §11「资源/状态不对称」、§3「`catch (_: Exception) {}` 静默吞掉异常」、§5「契约：失败拒绝写入」
- **证据**：静态确定 —— 注释声明「任何一次**向量化**失败都拒绝写入（不能存无向量记忆）」，但只有 `embed()` 在 `upsert` 之前执行；`repo.upsert` 已提交主表后，`repo.upsertSparse` 抛异常会直接冒出，**主表行留在库里**，重试又走唯一键覆盖，调用方看到"添加失败"却实际已写入；colbert 段是 `try { ... } catch (_: Exception) { }`，异常体为空，既不记日志也无计数，`MemoryHit.degraded` 也不会因它置位
- **描述**：嵌入服务抖动或 DB 连接中途断开时，写入语义变成"半成功"：主表有行、dense 有向量、sparse 没有 → 该条记忆永久只能被 dense 召回（且每次检索把它算进 `degraded` 的少数派）；colbert 失败则完全静默，排障时没有任何线索（`f_log` 无 warn，无指标）。注释与实现相反，属契约不符
- **建议**：把三步放进同一事务（`f_orm` 的 executor 级事务）或改为"先算全部产物、再一次性落库"；确实无法事务化时，`upsertSparse` 失败要补偿删除主表行或写"待补索引"标记供重建扫描；colbert 的 `catch` 至少 `log.warn('colbert upsert skipped: id=${id}, ${e.message}')` 并计数

### [一般][存量] `MemoryKinds` 用进程级可变静态 `HashMap`/`ArrayList` 做 kind 注册表，写入口无任何同步

- **位置**：`f_llm/src/store/MemoryKinds.cj:55-56`（`static let CUSTOM` / `static var persistence`）、`:63-78`（`attach` 清空并重填）、`:109-127`（`register` 检查-然后-写入）、`:153-173`（`remove` 重建列表）
- **来源**：存量（`git blame`：`MemoryKinds.cj:55` = `a94533515d` 2026-10-29、`:56-57` = `7398ed095a` 2026-10-31）
- **判据**：review-checklist §12.1「共享可变状态无保护」「检查-然后-写入」「迭代与修改并发」、§11「并发正确性」
- **证据**：静态确定（缺同步）；触发面 待确认 —— ① 共享路径明确：`CUSTOM` 是 `static let` 的 `HashMap<Int64, ArrayList<String>>`，`register` 先 `CUSTOM.get(userId)` 取到内部 `ArrayList` 再 `custom.add(kind)`，`all` 遍历同一个 `ArrayList`；② 容器本身不是并发容器：std 另设 `std.collection.concurrent.ConcurrentHashMap` 并注明「此类用于实现并发场景下线程安全的哈希表」（文档 `1.3.0/libs/std/collection_concurrent/collection_concurrent_package_api/collection_concurrent_class.html`），普通 `HashMap` 无此承诺；③ 同一 `user` 上两个线程各自 `register` 不同 kind 时，`contains` 判重与 `add` 之间有窗口，且 `ArrayList` 扩容与 `all()` 的遍历可并发；④ `attach` 在启动线程 `CUSTOM.clear()` 后逐用户重填，与任何并发读同时发生即为可见性问题
- **描述**：`register` / `remove` 是对外 `public` 写入口（`MemoryKinds` 是 `public class`），一旦接到 HTTP 处理线程（kind 管理接口）就立刻具备两个并发访问者，届时轻则丢一次注册（内存丢了但 DB 已写，`attach` 重启才恢复），重则 `ArrayList` 结构性破坏导致读出错乱；目前仓内 `register`/`remove`/`all`/`validate` 只被 `*_test.cj` 与 `store/it/KindPersistence_test.cj` 调用，所以是**潜伏**而非已触发的竞争——这也是它没有定为严重的原因
- **建议**：`CUSTOM` 换 `ConcurrentHashMap`（或 `HashMap` + 一把 `synchronized`/`ReentrantMutex`，注册是低频写、纯读多，读写锁更合适）；`register` 的"判重 + 插入"整体进临界区，且插入时用**新列表替换**而不是原地 `add`（避免遍历中修改）；`attach` 先构好新 map 再整块替换引用，保持"要么全旧要么全新"

### [一般][存量] `search` 对 `topK` 无校验无上界：`topK*2` 直接下推仓库，请求可拉全表；`topK<=0` 时向 SQL 传负 `limit`

- **位置**：`f_llm/src/store/PostgresMemoryStore.cj:87-93`（`let limit = query.topK * 2` → `searchDense` / `searchSparse`）；模型无校验 `f_llm/src/store/StoreModels.cj:70-78`；调用方 `f_llm/src/loom/LoomStoreGateway.cj:182-191`
- **来源**：存量
- **判据**：review-checklist §5「按不可信长度取数 / 无拒绝路径」、§11「缺少边界校验」
- **证据**：静态确定（无上限）＋ 规模 需实测 —— `MemoryQuery` 构造只做赋值，`topK` 无下限也无上限；`LoomStoreGateway` 只兜了 `topK > 0`（否则取 5），**没有上限**，`intOf(args,'topK')` 直接来自请求 payload；`MemoryRepository.searchDense` 把 `limit` 透传给 DAO 的 SQL `LIMIT`（`f_llm/src/store/postgres/MemoryRepository.cj:49-51` → `f_llm/src/dao/postgres/MemoryDAO.cj:54-73`）
- **描述**：一次 `loomStore("memory","search", {topK: 100000000})` 会让仓库返回该用户全部记忆（向量 + 正文），`collect`/`normalize`/选择排序全部按这个规模物化：既无拒绝路径也无分页，单请求即可把 RSS 顶到容器上限；反向的 `topK<=0`（直接构造 `MemoryQuery`，绕过网关）会把 `0`/负数传进 `LIMIT`，SQL 侧行为随驱动不同（报错或全量）
- **建议**：`MemoryQuery` 构造或 `search` 入口统一夹紧：`topK = min(max(topK, 1), MAX_TOPK)`，`MAX_TOPK` 取常量（如 50）并在 README 配置表写明；`limit` 下推前再断言 `> 0`

### [一般][存量] `KnowledgeSearch.terms` 文档称「按空白切词」，实现只按空格 `split(' ')`，换行/制表符分隔的查询召回为 0

- **位置**：`f_llm/src/store/KnowledgeSearch.cj:30-41`（注释在 `:30`，实现 `text.split(' ')` 在 `:33`）；对照契约 `f_llm/src/store/StoreModels.cj:207`（`KnowledgeQuery` 注释「`text` 按空白切词」）
- **来源**：存量
- **判据**：review-checklist §11「语义与注释不符」、§13「文档承诺与实现不一致」
- **证据**：静态确定 —— `trimAscii()` 只去首尾 ASCII 空白（含 `\t\n\v\f\r`，文档 `core_package_structs.html`「去除原字符串开头结尾以 ASCII 空白字符组成的子字符串」），`split(' ')` 只以空格 0x20 分割，因此 `"记忆\n检索"` 得到的**一个** term 是 `"记忆\n检索"`；knowledge 检索的首词召回与 `occurrences` 都用这个 term，倒排与子串匹配都必然 0 命中
- **描述**：多行文本（模型生成的多行 query、从文件/日志粘贴的段落）作为检索输入时静默返回空结果；调用方无从区分"没有相关文档"与"切词失败"。三个后端（PG/MySQL/内存）共用该函数，所以问题一致，不会互相掩盖
- **建议**：按空白字符集合切分（先 `split('\n')`/`\t` 归一，或用正则/`String.split` 逐分隔符），或先把所有 ASCII 空白替换为空格再 `split(' ')`；补一条 `"记忆\n检索"` 的用例锁定行为

### [一般][存量] MySQL 连通性用例与其注释相反：连不上时 catch 全部异常并 SKIP，CI 无库即永久绿

- **位置**：`f_llm/src/store/MySqlConnectivity_test.cj:25-44`（`available()`）、`:46-52`、`:63-69`
- **来源**：存量
- **判据**：review-checklist §11「语义与注释不符」、§3「静默吞异常」、§14.1「半成品」
- **证据**：静态确定 —— 类注释写「连不上就让用例失败，而不是静默跳过——否则后面的 MySQL 实现无法验证」（`:25-28`），实现是 `try { ... } catch (e: Exception) { println("SKIP ..."); false }`，两个 `@TestCase` 拿到 `false` 直接 `return`（`:48-50`、`:65-67`），用例名与最终状态都是通过
- **描述**：MySQL 后端（4.3 及 `MySqlMemoryRepository`、`MySqlKnowledgeStore` 等）的验证前提正是这个探测；探测失败只打印一行 SKIP，CI 报告全绿，MySQL 相关回归长期无人发现。注释与实现方向完全相反，读代码的人会以为它在守门
- **建议**：二选一并写进 README：① 需要库的用例走 `@Configure`/环境变量开关，未配置时**跳过整个测试类**并在 CI 汇总里显式列出 skipped（而不是在用例内 `return`）；② 保持"必须有库"，失败即 `@Expect(false, true)` 抛出。同时把 `available()` 里 `ORM.register(..., default: true)` 的全局副作用挪到 `@BeforeAll`，只在真正执行时注册一次

### [一般][存量] kind 校验入口 `MemoryKinds.validate` 全仓仅测试引用，写入路径不校验：任意 kind 字符串都能落库并按 0.8 计权

- **位置**：`f_llm/src/store/MemoryKinds.cj:197-205`（`validate`）、`:178-195`（`weightOf` 的兜底 `0.8`）；写入路径无校验 `f_llm/src/store/PostgresMemoryStore.cj:46-50`；消费方 `f_llm/src/loom/LoomStoreGateway.cj:182-191`
- **来源**：存量
- **判据**：review-checklist §14.1「接线缺失」、§11「缺少边界校验」
- **证据**：静态确定 —— 全模块搜 `MemoryKinds.validate` 只命中 `MemoryKinds_test.cj`（6 处）与 `store/it/KindPersistence_test.cj`（4 处），无生产调用；`add` 只把 `write.kind` 原样透传给 `repo.upsert`；`weightOf` 对未知 kind 落到 `else { 0.8 }`（`:192-194`），与 `doc`/`knowledge` 同权
- **描述**：`loomStore("memory","add")` 的 `kind` 来自流程/模型输出，拼错（`facts`、`Fact`）不会报错，而是以 0.8 权正常入库，直到检索排序才发现"权重不对"；`MemoryKinds.register` 的字符集校验（`:224-236`）也只作用于注册，不管写入。公开的校验能力与真正的写路径脱节
- **建议**：`add` 入口调用 `MemoryKinds.validate(userId, kind)`，失败抛 `IllegalArgumentException`（或在 `StoreSettings` 里加 `llm_allowUnknownKind` 开关，默认关）；若确实要允许未知 kind，则把 `weightOf` 的兜底权重显式化并写进 doc，而不是复用 0.8

### [轻微][存量] 实现名清单以字面量在 4 处各写一遍（`mysql`/`postgres`/`f_store`/`f_hydra`），新增后端要改多处且已出现措辞漂移

- **位置**：`f_llm/src/store/PostgresMemoryStore.cj:28-29`（`@BeanMeta` 条件）、`f_llm/src/store/MetaStoreAdapter.cj:38-50`（三分支 + 错误消息）、`f_llm/src/store/MemoryRepositories.cj:80-86`（错误消息 `postgres|mysql`）、`f_llm/src/store/StoreSettings.cj:39-41`（默认值 `f_hydra`/`f_store`）
- **来源**：存量
- **判据**：review-checklist §2「字面量复制：同一张状态码表 / 同一组字段名散落多处」
- **证据**：静态确定 —— 错误消息一处写 `available: f_store, mysql, postgres`（MetaStoreAdapter.cj:49），另一处写 `配置 llm_memoryStore=postgres|mysql`（MemoryRepositories.cj:85），`@BeanMeta` 又是一份 `mysql`/`postgres` 的枚举
- **描述**：加一个后端（如 `sqlite`）需要同时改 bean 条件、适配器分支、错误消息、默认值判断，漏一处即"配了却落到默认路径"或错误提示与实际可选值不符；已有两处提示文案不一致
- **建议**：在 `StoreSettings` 定义 `CONTENT_IMPLS` / `META_IMPLS` 常量数组，`@BeanMeta` 之外的判断与错误消息统一由常量拼装；适配器分支改为查表（`match` 只剩 `f_store` 特例）

### [轻微][存量] 线性 `contains` 助手 4 份；`persistInsert`/`persistDelete` 两个私有函数逐行同构

- **位置**：`f_llm/src/store/KnowledgeSearch.cj:106-113`、`f_llm/src/store/MemoryKinds.cj:238-245`、`f_llm/src/store/PostgresMemoryStore.cj:208-215`、`f_llm/src/store/MemoryKinds_test.cj:164-171`；`f_llm/src/store/MemoryKinds.cj:130-150`
- **来源**：存量
- **判据**：review-checklist §2「只改类型名 / 换控制流」
- **证据**：静态确定 —— 四处实现都是同语义 `for + ==` 早返回（签名 `ArrayList<String>` 与 `Array<String>` 各两处）；`persistInsert` 与 `persistDelete` 除 `store.insertCustom`/`store.deleteCustom` 与告警文案外完全一致
- **描述**：同类判重散落 4 份，后续若要改判定（大小写不敏感、trim 后再比）必须同步 4 处，漏一处即行为分叉；`persist*` 两份的告警文案已不同（`persist failed` vs `delete failed`，这个差异是合理的），但 `match(persistence)` + `try/catch` 外壳重复
- **建议**：模块内抽一个 `util/Collections.cj`（`containsString(Array<String>|ArrayList<String>, String)`）供 store 三处引用；`persist*` 合成 `persist(userId, kind, action: (KindPersistence, Int64, String) -> Unit)`，文案作为参数传入

### [轻微][存量] token 合并逻辑两处实现且语义有漂移（`?? 0.0` 会丢 0 权重 token、非正权重取不到最大值）

- **位置**：`f_llm/src/store/PostgresMemoryStore.cj:52-61`（`add` 内联）vs `f_llm/src/store/MemoryIndexRebuilder.cj:92-109`（`tokensOf`）；后者注释自称「与写入路径一致：标题 + 正文合并，同 token 取较大权重」
- **来源**：存量
- **判据**：review-checklist §2「近似重复：一块少了边界判断」
- **证据**：静态确定 —— `add` 用 `tokens.get(token) ?? 0.0f64` 后比大小，缺省值被当成 0：正文侧权重为 0 的 token 不会写入，标题侧已有权重为负时 `weight > 0.0` 恒假、无法取到较大值；`tokensOf` 用 `match` 区分 `Some/None`，`None` 分支无条件写入、`Some` 分支才比大小
- **描述**：同一记录走"写入"与走"重建"得到的 token 集合可能不同（0 权重 token 见/不见），sparse 候选集因此在重建前后不一致；BGE-M3 的权重通常为正值，所以影响面有限，属于行为漂移而非数据损坏
- **建议**：`SqlMemoryStore.add` 直接复用 `MemoryIndexRebuilder.tokensOf`（把它提到 `store` 包内的公共 util 或用 `Embedder` 上的默认方法），保证"写入 = 重建"；顺手把 `?? 0.0` 的缺省比较去掉

### [轻微][存量] `weightOf` 的 `experience` 分支与 `else` 返回同一个 0.8，是等价冗余分支

- **位置**：`f_llm/src/store/MemoryKinds.cj:189-194`
- **来源**：存量
- **判据**：review-checklist §1「恒真恒假分支 / 兼容残留」
- **证据**：静态确定 —— `else if (kind == EXPERIENCE || kind == EXPERIENCE_FAILED) { 0.8 }` 与末尾 `else { 0.8 }` 完全等价，`MemoryKinds_test.cj:157-161` 断言的也正是"两者都是 0.8"
- **描述**：注释说明了意图（"与纳入预定义前一致"），但代码上这支 `if` 不影响任何取值，读者会以为 `experience` 有特殊权重；未来若把兜底权重改成 0.5，这支分支会意外保留 0.8，形成"改了默认值却对某两类不生效"的陷阱
- **建议**：删掉该分支，把注释移到 `else` 上（"未登记 kind 与 experience 同权 0.8"）；若确实需要 experience 独立权重，则改成显式常量 `EXPERIENCE_WEIGHT` 并被测试引用。**注意（v1.1 复核）**：`f_llm/doc/spec/fix-memory-write-consistency/tasks.md:5` 明确要求「`weightOf` 显式返回 0.8」，所以这支分支是有规格依据的有意写法；本条只作「等价冗余」记录，删除前需先改规格，不宜直接当死代码清理

### [轻微][存量] 三处注释与实现漂移：预定义 kind 数量、废弃键数量、"回退 fhydra"

- **位置**：`f_llm/src/store/MemoryKinds.cj:22-25`（称「预定义 7 值」，实际 9 个，见 `:43-53`）；`f_llm/src/store/StoreSettings.cj:27-28`（注释列 3 个废弃键，`DEPRECATED_KEYS` 有 4 个，见 `:45`）；`f_llm/src/store/MemoryRepositories.cj:26`（「没有匹配时回退到 fhydra（尚未实现）」，实现是直接抛 `IllegalStateException`，见 `:82-86`）
- **来源**：存量
- **判据**：review-checklist §11「语义与命名 / 注释不符」、§13「文档过期」
- **证据**：静态确定 —— `predefined()` 返回 9 项（`note/fact/preference/task/doc/knowledge/session/experience/experience_failed`），`MemoryKinds_test.cj:78-82` 也断言 9；`DEPRECATED_KEYS` 字面量 4 项含 `llm_contentStore`；`defaultRepository()` 唯一语句是 `throw`
- **描述**：三处都是"读注释建立的心智模型与代码不一致"：以为 7 种 kind 时新增 kind 会漏改权重；以为废弃键只有 3 个时漏配 `llm_contentStore` 的迁移提示；以为有 fhydra 兜底时会配默认值然后撞上启动异常
- **建议**：注释改为「预定义 9 值」；废弃键清单改为与常量同源（`DEPRECATED_KEYS.size`），或在注释里逐个列全；`MemoryRepositories` 的类注释改成"无匹配直接抛错并提示可选项"

### [轻微][存量] 测试隔离不足：`StoreSettings_test.clearAll` 漏清 `llm_contentStore`；重建用例只复位 `onStart`，`userId`/`namespace` 残留

- **位置**：`f_llm/src/store/StoreSettings_test.cj:26-34`（clearAll 三项）与 `:77`（断言 `deprecated.size == 3`）；`f_llm/src/store/MemoryIndexRebuilder_test.cj:157-169`（只复位 `llm_rebuildIndexOnStart`）
- **来源**：存量
- **判据**：review-checklist §11「错误处理 / 边界」、§2「测试里的准备代码」误报边界之外的真实缺陷（用例顺序依赖）
- **证据**：静态确定 —— `Config` 是进程级全局（`f_config`），`DEPRECATED_KEYS` 有 4 项而 `clearAll` 只 remove 3 项；重建用例设置了 `llm_rebuildIndexUserId=42` / `llm_rebuildIndexNamespace=global` 后不复位
- **描述**：任何前置用例（或并行用例）一旦设置 `llm_contentStore`，`testOldKeysAreDeprecatedNotApplied` 的 `size == 3` 会变成 4 而失败；反之本用例设置的 `llm_contentStore` 也会污染后续用例。重建用例残留的 userId/namespace 目前无害（其它用例不读），但同样是顺序依赖隐患
- **建议**：`clearAll` 改成遍历 `StoreSettings.DEPRECATED_KEYS` + 四个新键；重建用例用 `try/finally` 或 `@BeforeEach/@AfterEach` 恢复三项配置；顺手把 `DEPRECATED_KEYS` 提升为 `public`（测试需要）或提供 `StoreSettings.deprecatedKeys()` 访问器

### [轻微][存量] 可见性建议：`emptySkills()` 与 `resetForTest()` 是仓内零引用 / 仅测试用的对外 `public`

- **位置**：`f_llm/src/store/StoreModels.cj:162-165`（`public func emptySkills()`，注释「空实现辅助：让接口先能编译」）；`f_llm/src/store/MemoryKinds.cj:219-222`（`public static func resetForTest()`，注释「仅测试用」）
- **来源**：存量
- **判据**：review-checklist §1「仅测试使用 → 可提可见性建议，但不是死代码」；硬原则一（对外可达的 `public` 不判死代码）
- **证据**：静态确定 —— 全仓搜 `emptySkills` 仅定义处命中（含 `f_llm` 以外目录）；`resetForTest` 仅在 `MemoryKinds_test.cj:76-137` 与 `store/it/KindPersistence_test.cj:128,150` 命中
- **描述**：两者对外可见但仓内无使用：`emptySkills` 从名字与注释看是接口落地前的脚手架残留，`resetForTest` 是测试钩子却进了库的公开面。**按硬原则均不计死代码**，仅作为可见性建议记录，删除与否需用户确认下游无依赖
- **建议**：`emptySkills` 直接删（或降为 `internal`）；`resetForTest` 收窄为 `internal`，测试同包可直接访问（`MemoryKinds_test.cj` 与 `store/it` 都在 `fountain::f_llm.store` 包内）

### [轻微][存量] 文件命名与实现漂移：`PostgresMemoryStore.cj` 内是 PG/MySQL 共用的 `SqlMemoryStore`，仓内无同名类

- **位置**：`f_llm/src/store/PostgresMemoryStore.cj:23-30`（文件头注释与类声明）
- **来源**：存量
- **判据**：review-checklist §10「可读性 / 可维护性」、§11「语义与命名不符」
- **证据**：静态确定 —— 全仓搜 `class PostgresMemoryStore` 零命中；按名查找实现的人会找不到类，`@BeanMeta` 却同时匹配 `mysql` 与 `postgres`（`:28-29`）
- **描述**：文件与测试（`PostgresMemoryStore_test.cj` 内类名却是 `SqlMemoryStoreTest`）都留着重构前的名字，检索与导航成本高
- **建议**：文件重命名为 `SqlMemoryStore.cj`、测试重命名为 `SqlMemoryStore_test.cj`（纯改名，无逻辑变更）

### [轻微][存量] 测试文件硬编码数据库账号口令

- **位置**：`f_llm/src/store/MySqlConnectivity_test.cj:31`（`mysql://fllm_test:fllm_test@127.0.0.1:3306/fllm_test`）
- **来源**：存量
- **判据**：review-checklist §10「安全性：硬编码凭据」
- **证据**：静态确定 —— URI 明文含用户名与口令，直接在源码中；仅测试用、仅本机库
- **描述**：口令进版本库后无法轮换（改口令要改代码），且会被密扫工具报出；对生产无直接影响，故定轻微
- **建议**：改读环境变量（`LLM_TEST_MYSQL_URL`）并提供 `.env.example`；缺变量时按上一条 SKIP 策略处理

### [轻微][存量] 两条用例断言打在测试替身而非生产实现上（`lastLimit`、`FakeEmbedder.tokenize`）

- **位置**：`f_llm/src/store/PostgresMemoryStore_test.cj:179-186`（断言 `repo.lastLimit == 4`）、`:304-308`（`FakeEmbedder().tokenize('ab cd')`）
- **来源**：存量
- **判据**：review-checklist §2「测试里的准备代码」之外的覆盖度问题、§14.1「半成品 / 只做了一半」
- **证据**：静态确定 —— `lastLimit` 只在 `FakeMemoryRepository.searchDense` 内赋值（`:87-90`），断言验证的是替身收到的参数，不是 `SqlMemoryStore` 的产出；`tokenize` 用例验证的是 `FakeEmbedder` 自己的实现，与生产 `HttpEmbedder`/`DefaultEmbedder` 无关
- **描述**："先取 2 倍候选"这条契约确实被这两条用例间接锁定（参数即契约），但 `tokenize` 一条纯属自测替身，零信息量，给覆盖率虚增
- **建议**：`lastLimit` 用例保留但注明"验证下推参数契约"；`tokenize` 用例删除或改为对真实嵌入器（可注入固定 `EmbeddingTransport`）的用例

### [轻微][存量] 结果排序在并列分时没有确定 tie-break，与"跨后端排序口径一致"的目标不一致

- **位置**：`f_llm/src/store/PostgresMemoryStore.cj:159-191`（选择排序，比较只用 `score` / `rerankScores`）；对照 `f_llm/src/store/KnowledgeSearch.cj:95-104`（`before` 明确用 `score → docId → seq` 兜底）
- **来源**：存量
- **判据**：review-checklist §11「语义与命名 / 注释不符」、§2「同一件事两种口径」
- **证据**：静态确定（无 tie-break）＋ 后端返回序 待确认 —— 知识侧有三级排序键并注释「保证跨后端一致」；记忆侧 `better = scored[index].score > scored[best].score`，同分保留先出现者，而候选先后来自 `collect(dense, …)` / `collect(sparse, …)` 的仓库返回顺序
- **描述**：同分候选的最终顺序取决于 PG / MySQL / 内存各自的行序，`topK` 截断点落在同分组内时，不同后端返回的集合可能不同；知识侧刻意避免的问题在记忆侧仍存在
- **建议**：比较函数补 `id` 升序兜底（`if (score == other.score) { id < other.id }`），与 `KnowledgeSearch.before` 统一；补一条"全同分时按 id 升序"的用例

### [一般][存量] 开启 rerank 但候选都没有 colbert 向量时，最终 topK 退化为候选插入序，融合分与 kind 权重全部失效

- **位置**：`f_llm/src/store/PostgresMemoryStore.cj:121-124`（`rerankScores` 全置 0.0）、`:151-155`（`case None => 0.0`）、`:166-191`（pick 循环只比较 `rerankScores`）
- **来源**：存量（`git log -1 -- f_llm/src/store/PostgresMemoryStore.cj` → `2c8f1bbf8`，2026-11-07；工作区无 diff）
- **判据**：review-checklist §11「逻辑错误：排序不按分数」、§3「用 0 当哨兵吃掉缺失语义」
- **证据**：静态确定 —— pick 循环首次迭代 `best < 0` 必取 `scored[0]`，此后只有 `rerankScores[...] > rerankScores[best]` 才替换；当所有候选的 rerank 分都是 0.0 时没有任何候选能替换 `best`，输出顺序等于 `scored` 的插入顺序（= `ids` 顺序 = `collect(dense, …)` 的仓库返回序 + 仅 sparse 命中的 id，`:100-104`）
- **描述**：`repo.colbert()` 全部返回 `None` 是**常态而非例外**——`LlmEmbeddingTransport` 只回 dense（`f_llm/src/embedding/LlmEmbeddingTransport.cj:23-26` 自认「rerank 失效」），`add` 的 colbert 写入又允许失败（#5），`MemoryIndexRebuilder` 修的正是这个场景。此时把 `rerank` 打开，`topK` 结果按 dense 原始顺序给出：稀疏通路的 `0.3 × sparseScore`、`MemoryKinds.weightOf` 的 kind 权重、以及 #21 讨论的分差都不再影响排名；同一批数据 `rerank=false` 能正确排序，两个开关互相矛盾。`PostgresMemoryStore_test.cj:238-253` 只覆盖「向量存在」的路径，`testRerankOnlyQueriesTopCandidates`（`:258-270`）也没断言顺序
- **建议**：把「缺失」与「真实 0 分」分开（`HashMap<Int64, ?Float64>` 或额外的 `reranked: HashSet<Int64>`），pick 的比较键改成两级：`reranked ? rerankScore : 0.0`，且 `reranked` 为假时回退 `scored[i].score`；补一条「colbert 全缺失 + rerank=true 时结果与 rerank=false 同序」的用例

### [一般][存量] `maxSim` 把负相似度截成 0，`dot` 对维度不一致静默截断，重排分数「错而不报」

- **位置**：`f_llm/src/store/PostgresMemoryStore.cj:218-234`（`var best = 0.0f64`）、`:236-247`（`let size = if (left.size < right.size) left.size else right.size`）；维度放宽来源 `f_llm/src/store/ColbertCodec.cj:49-58`
- **来源**：存量（`2c8f1bbf8`）
- **判据**：review-checklist §11「边界 / 契约与实现不符」、§5「不可信输入的维度未校验」
- **证据**：静态确定（初值与截断机制）＋ 待确认（负点积是否真的出现，取决于 BGE-M3 colbert 向量是否归一化/含负分量）
- **描述**：`maxSim` 每行 `best` 从 `0.0` 起、仅 `score > best` 时更新，所有负点积被当成 0：对「query token 与 doc token 全为负相关」的候选，max-sim 被抬到 0，与「完全不相关」不可区分，`total / query.size` 整体偏大。`dot` 取两边较短长度，维度不一致时（换过向量模型、库里残留旧维度——`ColbertCodec.decode` 明确「维度不是 1024 也允许，按剩余字节推断」，`ColbertCodec.cj:49-58`）静默只算前 min(dim) 维，不报错也不记日志，只表现为重排顺序莫名变化
- **建议**：`best` 初始化成第一个 `dot` 结果（或 `-Float64.inf`）；`dot` 在 `left.size != right.size` 时抛 `IllegalArgumentException`（或返回 `None` 让 `maxSim` 跳过并 `warn` 一次）；`upsertColbert` 写入前校验维度与模型一致

### [轻微][存量] `rebuild` 单条失败即中断整批、无进度与失败计数；offset 分页窗口在并发写入下会漏记录

- **位置**：`f_llm/src/store/MemoryIndexRebuilder.cj:72-89`；分页实现 `f_llm/src/dao/postgres/MemoryDAO.cj:156-161`（`ORDER BY save_time DESC LIMIT/OFFSET`）
- **来源**：存量（`git log -1` → `112790669`，2026-10-31）
- **判据**：review-checklist §11「错误处理、进度可观测」、§5「分页稳定性」
- **证据**：静态确定（中断与分页机制）＋ 待确认（重建是否与在线写入并发，取决于部署窗口）
- **描述**：页内任一 `embedColbert`/`upsertSparse` 抛错（向量服务超时最常见）会让整个重建抛出：已重建的部分保留、`rebuilt` 计数丢失，日志里只有成功时的一条 `info`（`:54`），失败时没有「处理到第几条」的痕迹，重启只能从 `offset=0` 重来（幂等但成本翻倍）。分页按 `save_time DESC` 偏移：重建期间若有新记忆写入（`save_time` 更新、排在最前），offset 窗口整体后移会跳过一批旧记录；`save_time` 相同的记录之间没有二级排序键，跨页边界可能重复或遗漏
- **建议**：页内改逐条 `try/catch` 累计 `failed`，结束时 `warn('... rebuilt=${rebuilt}, failed=${failed}')`；分页改用 `id > lastId ORDER BY id` 的游标（仓储补一个 `listAfter`），最小改动是 `ORDER BY save_time DESC, id DESC` 消除同时间戳歧义

### [轻微][存量] `KnowledgeSearch.rank` 选择插入排序的依据写着「候选通常 ≤ 200」，调用方实际上限是 1000（合并后可达 2000）

- **位置**：`f_llm/src/store/KnowledgeSearch.cj:70-93`（注释在 `:74`）；规模来源 `f_llm/src/store/postgres/KnowledgeStore.cj:34-58`（`maxCandidates` 默认 1000、`pageSize` 200）、`:170-178`（`denseK` 与 lexical 两路合并）
- **来源**：存量（`git log -1` → `16ee79ddb`，2026-10-31）
- **判据**：review-checklist §6.4「低效算法：O(n²) 的规模前提不成立」、§13「注释与调用方不一致」
- **证据**：静态确定（复杂度与上限）；实际耗时未测，只在「待验证假设」给测量方案，不当热点
- **描述**：`hits` 来自 dense 与 lexical 的并集，两路上限各 1000，最坏约 2000 条；插入排序 `O(n²)` 约 2×10⁶ 次 `before()` 比较，仍在毫秒级，所以不改也不算缺陷——但注释给出的「≤ 200」与实际差一个数量级，会让后续维护者误判成本，也会误导「候选会被截到 200」的判断（`§6.4` 自检、`§5` 的规模估算都引用过这个数字）
- **建议**：注释改成真实上限（n ≤ 2 × `maxCandidates`）；若要消平方项，改成「一次 `sort`（`score desc, docId asc, seq asc`）+ 取前 limit」，等价性用 `KnowledgeChunker_test.cj:100-115` 的排序断言覆盖

### [轻微][存量] `PredefinedCharacters` 的 key 名单与正文 `match` 是两份需手工同步的字面量

- **位置**：`f_llm/src/store/PredefinedCharacters.cj:54-83`（12 个 `case` + `_ => ''`）与 `:85-91`（13 个 key，含 `default`）
- **来源**：存量
- **判据**：review-checklist §2「字面量复制：同一张表的两个副本」、§14.1「只做了一半的分支」
- **证据**：静态确定 —— `keyList()` 第 1 个 `'default'`（正文约定为空）与其余 12 个 key 和 `bodyOf` 的 12 个 `case` 一一对应；`keys()` / `isKnown()` / `bodyOf()` 分别遍历/匹配这两份列表
- **描述**：当前 13/12 是一致的，不是缺陷；风险在演进：新增人格只加 `keyList` 不加 `case` 时，`isKnown()` 返回 `true`（能写入）而 `bodyOf()` 返回空串，按 `:50-52` 的约定静默回落成「没有系统提示词」，不报错；只加 `case` 不加 `keyList` 则无法写入。现有用例（`FStoreMetaStore_test.cj:84-85`）只查数量与 `isKnown()`，穷举不到这个空档。另外 `keys()` 目前只有测试引用（`FStoreMetaStore_test.cj:84-85`），属测试驱动的公开入口，不算死代码
- **建议**：把正文表做成常量 `HashMap<String, String>`，`keys()`/`isKnown()`/`bodyOf()` 查同一张表（`default` 显式映射空串）；或保留双列表并加用例 `for (key in keys()) { if (key != 'default') @Expect(bodyOf(key).isEmpty(), false) }`

<!-- 第 22 部分 -->

### [严重][存量] `HydraMemoryRepository.nextId()` 读-改-写无同步，并发写入会拿到重复 id

- **位置**：`f_llm/src/store/hydra/MemoryRepository.cj:254-263`（`nextId`），调用点 `:63`（`upsert` 第一行）
- **来源**：存量（快照模式无基线；整文件为 2026-10 后的 hydra 方案）
- **判据**：review-checklist §12.1（检查-然后-写入 / 共享可变状态无保护）、§6.2（复合操作不原子）
- **证据**：静态确定 —— `nextId` 是「`transport.get(MAP,'seq')` → `current + 1` → `transport.upsert(...)`」三步复合操作，全程没有锁、没有 CAS；`HydraTransport` 接口（`Transport.cj:31-43`）也没有条件写/自增原语。`HydraMemoryRepository` 由 `HydraContentStore.memory`（`ContentStore.cj:50`）构造，而 `SqlMemoryStore`（`PostgresMemoryStore.cj:50`）直接在 `add()` 里调用 `repo.upsert`，无上游同步。
- **描述**：两个请求并发写记忆时都读到 `seq=N`，都写 `N+1`，返回同一个 id。后写者的 `VectorRecord` 覆盖前者的 payload/向量，`map:{id}` 也指向同一 collection —— 前一条记忆静默丢失。因为记忆 id 是全局自增（`MAP` 为全局集合），该冲突跨用户、跨 namespace 发生，不是单用户局部问题。
- **建议**：给 id 分配加一条进程内互斥（`Mutex`，与 `HydraEvolutionLease` 的写法一致），并注明「单进程保证」；跨进程（`fhydra` 远程部署）必须由服务端提供 `hydra.nextId` 之类的原子自增，或在 `upsert` 里带 `expectedSeq` 做 CAS。短期至少要把「并发写不安全」写进 `MemoryRepository` 的契约注释，避免被当成幂等。

### [严重][存量] `HttpTransport.upsert` 只投影部分字段：`filters`（kind）与 `colbert` 在远程部署下静默丢失

- **位置**：`f_llm/src/store/hydra/HttpTransport.cj:82-86`（param 拼装）、`:94-118`（`get` 不回填 `filters`）
- **来源**：存量
- **判据**：review-checklist §11（契约与实现不符）、§3（开关打开后走进空分支）、§14.1（能力未接线）
- **证据**：静态确定 —— 写入 param 只有 `collection/id/payload/denseB64/saveTime/titleDense/contentDense/tokenIds/weights`，`record.filters` 与 `record.colbert` 从未出现；对照 `fhydra/src/HydraParams.cj:25-47`，`UpsertParam` 有 `kind/saveDay/tags` 三个过滤字段，但**没有** `colbert` 字段，`recordOf()` 也不会带。`fhydra/src/HydraRpc.cj:143-151` 的 `ids` 在有 `filters` 时走 `store.idsFiltered`（倒排），而写入侧从未写 `kind` ⇒ 倒排里没有该维度条目。
- **描述**：`llm_memoryStore=fhydra` 时：① `MemoryRepository.listByKind`（`MemoryRepository.cj:174-187`）下推的 `filters['kind']` 服务端永远查不到 → 返回空列表，`memory` 工具的 kind 过滤在远程部署下失效（`doc/f_llm.md:341` 只承诺了 `f_hydra` 本机部署下推，但 `doc/content-store.md:10` 把 `fhydra` 与 `f_hydra` 并列在同一实现矩阵里，等于承诺同语义）；② `upsertColbert`（`MemoryRepository.cj:117-128`）经 `rewrite` → `transport.upsert` 后 colbert 向量未被持久化，`colbert()` 永远拿不到 → `rerank=true` 的检索在远程部署下静默退化为按融合分排序，且没有任何日志。
- **建议**：`HttpTransport.upsert` 增加 `"kind":"${esc(record.filters.get('kind') ?? '')}"`；`get` 回填 `filters`（远端 `RecordDto` 需要新增 kind 字段）。colbert 需要在 `fhydra` 的 `UpsertParam`/`RecordDto` 两侧一起补，补齐前应在 `HttpTransport.upsert` 里对非空 `record.colbert` 显式 `warn` 或抛错，不能静默丢弃。

### [一般][存量] `HydraMemoryRepository.upsert` 不按 `(user_id, namespace, title)` 覆盖写，违背 `MemoryRepository` 契约

- **位置**：`f_llm/src/store/hydra/MemoryRepository.cj:61-80`
- **来源**：存量
- **判据**：review-checklist §11（契约与实现不符）
- **证据**：静态确定 —— 接口注释 `f_llm/src/store/MemoryRepository.cj:36` 写「唯一键是 `(user_id, namespace, title)`：同键写入覆盖，返回既有 id」，`doc/content-store.md` §2 也写「同一 `(user_id, namespace, title)` 覆盖写，返回既有 id」；实现是 `nextId()` + 无条件 `transport.upsert`，没有任何按 title 查旧记录的步骤，`PostgresMemoryRepository`/`MySqlMemoryRepository` 靠 DB 唯一键达到该语义，hydra 侧缺这一层。
- **描述**：同一用户重复写同标题记忆（`loom` 的会话摘要、`kind=session` 覆盖很常见）时，hydra/fhydra 部署会不断新增记录而不是覆盖：`list` 出现重复项、`memory.search` 召回同一内容多份、`MemoryKinds.weightOf` 重复计分。与 `[严重] nextId` 叠加时还会放大重复 id 概率。
- **建议**：`upsert` 前按 `collection + title` 查一次（`transport.idsFiltered` 已支持 filters，可把 `title` 也写进 filters），命中则复用既有 id 做覆盖写；或在文档中明确「hydra 族不支持同标题覆盖」并把接口注释改成后端相关。

### [一般][存量] `colbert()` 的 title 分支恒为空数组，重排少一路信号且与 SQL 实现不一致

- **位置**：`f_llm/src/store/hydra/MemoryRepository.cj:137-141`
- **来源**：存量
- **判据**：review-checklist §1（恒真恒假分支 / 读了不用）、§11（语义与注释不符）
- **证据**：静态确定 —— `case Some(vector) => Array<Array<Float64>>()` 与 `case None => Array<Array<Float64>>()` 完全一致，`record.vectors.get('title')` 的取值被丢弃；对比 `postgres/MemoryRepository.cj:91`、`mysql/MemoryRepository.cj:95` 都是 `ColbertVectors(ColbertCodec.decode(title), ColbertCodec.decode(content))`。
- **描述**：`SqlMemoryStore` 的重排（`PostgresMemoryStore.cj:151-153`）用 `maxSim(query, vectors.title)` 与 `maxSim(query, vectors.content)` 合并；hydra 后端 `title` 恒空 ⇒ `maxSim` 短路返回 0（`PostgresMemoryStore.cj:218-221`），标题相似度这一路在所有 hydra 部署（含默认配置）下都不参与排序。`upsertColbert` 把标题向量和正文向量合并进同一条 `record.colbert`（`:117-128`），语义上已不可分，因此当前写法是「知道分不开，于是把 title 留空」，但用了一个恒等 `match` 掩盖，读者无法判断是刻意还是漏写。
- **建议**：两分支合一，直接 `let title = Array<Array<Float64>>()`，并把「colbert 在 hydra 族只保留合并序列，title 恒空、重排只用 content」写进注释；若要恢复两路信号，需要在 `VectorRecord` 上拆 `titleColbert`/`contentColbert` 两个字段（涉及 f_hydra 存储布局，属设计变更）。

### [一般][存量] `decode()` 丢弃 payload 中的 `saveTime`，记忆时间退化为读取时刻

- **位置**：`f_llm/src/store/hydra/MemoryRepository.cj:281-288`（`decode`），写入侧 `:276-279`（`encode`）
- **来源**：存量
- **判据**：review-checklist §1（读了不用 / 死写）、§11（数据错误）
- **证据**：静态确定 —— `encode` 按 `title␁content␁kind␁saveTime␁namespace` 写 5 段，`decode` 只取 `parts[0..2]` 与 `parts[4]`，`parts[3]`（epoch 秒）从未被解析，第 7 个构造参数写死为 `DateTime.now()`。
- **描述**：任何 `repo.get`/`list`/`listByKind`/`search*` 返回的 `MemoryRecord.saveTime` 都是「读的这一刻」，而不是写入时刻。该字段经 `LoomStoreGateway.cj:442` 输出到 `memory.search` 的 JSON，调用方按时间排序/判新旧会全部错乱；payload 里那一段成为永不被读取的冗余数据。另有次要问题：`parts.size < 5` 时返回一条 `content=''` 的空记录而不是 `None`（`:284-286`），调用方看到的是「存在但内容为空」的记忆。
- **建议**：`decode` 解析 `parts[3]` 并构造 `DateTime`（`std.time` 有从 epoch 秒构造的 API，实现前用 `cangjie-doc-lookup` 核对签名），解析失败回落 `DateTime.now()` 并打一次 warn；`parts.size < 5` 返回 `None`，由调用方按「记录损坏」处理。

### [一般][存量] RPC 错误判定依赖 `text.contains('"error"')`，payload 里出现 `"error"` 会被误判为失败

- **位置**：`f_llm/src/store/hydra/HttpTransport.cj:212-216`
- **来源**：存量
- **判据**：review-checklist §11（错误处理缺失/误判）、§3（错误路径）
- **证据**：静态确定 —— 响应体里的业务字段 `payload` 由 `esc()` 转义，正文中的 `"error"` 会变成 `\"error\"`，其字节序列中仍然包含子串 `"error"`（反斜杠 + 引号 + error + 引号），`contains` 命中后走 `parse<ErrorEnvelope>`；此时真实响应没有 `error` 键，`DataAssist` 会给出默认 `ErrorDto(code=0, message='')`，于是抛出 `hydra rpc error 0: `（空消息）。
- **描述**：只要被存/被读的记忆正文或标题里出现带引号的 `error` 字样（「日志里写了 `"error"` 字段」这类内容很常见），该记录的 `get`/`list` 就永久抛异常，且异常信息只有 code 0 与空消息，排障成本极高。`list`/`search` 里的 `case None => ()` 不会兜住异常，整页读取直接失败。
- **建议**：按 JSON 结构判断而不是子串判断——顶层解出 `ObjectData` 后检查是否存在 `error` 键（`DataObject` 的缺失字段语义），或解析成含可选 `error` 的 envelope（`?ErrorDto`）再判 `isSome()`；异常消息附上 `method` 与 `id`，不要附响应体。

### [一般][存量] 惰性初始化与注册表读写无同步：`HydraContentStore` 缓存与 `Stores` 静态表

- **位置**：`f_llm/src/store/hydra/ContentStore.cj:31-32`（`cachedMemory`/`cachedKnowledge`）、`:47-53`、`:59-65`；`f_llm/src/store/Stores.cj:34-35`（两张静态 `HashMap`）、`:47-59`（写入）、`:74-97`（读取）
- **来源**：存量
- **判据**：review-checklist §12.1（惰性初始化 / 发布逸出 / 共享可变状态无保护）
- **证据**：静态确定 —— ①`memory`/`knowledge` 是「`match` 判 `None` → 新建 → 赋值」的检查-然后-写入，两个线程同时首次访问会各建一份 `SqlMemoryStore`/`HydraKnowledgeStore`，`private var` 也没有内存屏障；②`Stores.contentFactories`/`metaFactories` 在 `registerContent`（`:51`）/`registerMeta`（`:58`）里写，在 `content(name)`（`:75`）/`meta(name)`（`:91`）里读，两侧都没有锁；写入方不只在模块加载期——`StoreWiring.wire()`（`wiring/StoreWiring.cj:52-70`）在 `Memory.remember`（`memory/Memory.cj:124`）里被**每次调用**触发，而 `LoomStoreGateway()`（`loom/LoomStoreGateway.cj:70-71`）会在别的线程读这两个表。
- **描述**：进程首次并发使用时存在「一次 `HashMap` 读与一次 `put` 并发」的窗口，可能读到半初始化状态（`contains` 返回 false 后抛 `unknown llm_memoryStore`），也可能产生两份 store 实例（各自持有一份 `FStoreVectorStore` 句柄，见下一条）。启动后稳态不再写入，因此影响集中在首请求窗口，但后果是「首次请求随机失败」这类难复现问题。
- **建议**：`Stores` 的两张表加一把 `Mutex`（注册与读取都进临界区，读取只做 `get` 引用，代价可接受），或在 `StoreWiring.wire()` 之外禁止注册并要求启动期单线程完成后再对外服务；`HydraContentStore` 的两个缓存改为 `private let` + 构造时初始化，或沿用 `Mutex` + 双重检查（不得只加 `if`）。

### [一般][存量] `Stores.content()` / `meta()` 每次都走工厂 `new`，同进程会出现多个 `FStoreVectorStore` 指向同一目录

- **位置**：`f_llm/src/store/Stores.cj:68-81`（`content()`/`content(name)`，`Some(factory) => factory()`）、`:84-97`
- **来源**：存量
- **判据**：review-checklist §5（长期持有 / 句柄增长）、§12.1（跨线程资源）、§11（契约与实现不符）
- **证据**：静态确定 —— 工厂返回的是**新实例**，没有任何实例缓存；调用点：`loom/LoomStoreGateway.cj:70-71`（每个网关一次）、`store/MemoryStoreAdapter.cj:40`（每个适配器一次，`Memory.remember` 的回退路径每次新建适配器）、`loom/LoomWiring.cj:213`（定时任务每次触发 `Stores.meta()`）。`HydraContentStore.init`（`ContentStore.cj:34-38`）会 `FStoreVectorStore(DeployPaths.resolve(...))`，即每次 `new` 一个 `f_store` 句柄。
- **描述**：①`HydraContentStore` 内部的 `cachedMemory`/`cachedKnowledge` 缓存只对「同一个实例」有效，跨调用完全失效，`requireEmbedder()`（`ContentStore.cj:69-75`）也每次重新 `lookupOption`；②同一进程内可能有 N 个 `Store` 句柄指向同一目录，f_hydra 的「两阶段写 + ready 标记」是否跨实例互斥、是否会因多句柄并发写损坏数据，需要读 `f_store` 实现确认（本部分未展开，见待验证假设 #5）。风险随 `Memory.remember` 调用次数线性增长。
- **建议**：`Stores` 内按名字缓存单例（`HashMap<String, ContentStore>`，与上一条的锁一并加），或把「一个进程一个 ContentStore」写成硬约定并在 `bootstrap()` 里实例化一次；`Stores.resetForTest()` 同时清实例缓存。

### [一般][存量] `HttpTransport` 全局关闭 TLS 证书校验（`CertificateVerifyMode.TrustAll`）

- **位置**：`f_llm/src/store/hydra/HttpTransport.cj:202-204`
- **来源**：存量
- **判据**：review-checklist §10（安全性：敏感数据、外部输入未校验）、§11（契约与实现不符：`llm_hydraSecret` 走明文信任链）
- **证据**：静态确定 —— `let tls = TlsClientConfig(); tls.verifyMode = CertificateVerifyMode.TrustAll`，无条件生效，没有配置开关；`client.header('X-Hydra-Key', secret)`（`:201`）把共享密钥放在这条连接上，请求体里是整个记忆库的 payload 与向量。
- **描述**：`https://` 的 `llm_hydraUrl` 部署下，任何能中间人的攻击者都可以冒充 fhydra 读取全部记忆内容与 `llm_hydraSecret`，或篡改检索结果（`searchDense` 命中集）。同一写法在 `llm/LLMTransport.cj:48`、`llm/LLMStreamTransport.cj:50`、`embedding/BgeM3Transport.cj:92`、`balance/BalanceQueriers.cj:43`、`search/DeepSeekSearchProvider.cj:45` 重复出现，属模块级约定，因此不是本文件独有缺陷，但本文件承担的是持久化数据面。
- **建议**：`TrustAll` 改为按配置项开启（如 `llm_hydraInsecureTls`，默认 false），默认走标准信任链；需要自签证书的内网部署应支持指定 CA 文件而不是关闭校验。跨传输统一收口到一个 `httpOptions()` 帮助函数，避免 6 处各写一遍。

### [一般][存量] 自定义分隔符（`0x01`）与 `#` 拼接无转义，正文/`docId` 含分隔符时静默串段

- **位置**：`f_llm/src/store/hydra/MemoryRepository.cj:43`（`SEP`）、`:276-288`（`encode`/`decode`）；`f_llm/src/store/hydra/ContentStore.cj:104`（`SEP`）、`:116-118`（`doc:` payload）、`:135-139`（`get` 拆分）、`:124` 与 `:210-214`（`'${docId}#${seq}'` 与 `id.split('#')`）
- **来源**：存量
- **判据**：review-checklist §11（边界 / 语义与注释不符）、§13 相邻（编码格式未在注释中声明约束）
- **证据**：静态确定 —— 两处都用不可见控制字符做字段分隔，且都不做转义或长度前缀。记忆 payload：正文若含 `0x01`（二进制/多模态摘录、从其它系统搬运的文本都可能带），`split(SEP)` 的段数 >5，`parts[0..2]`/`parts[4]` 全部错位 → `title`/`content`/`kind`/`namespace` 被错误还原（`decode` 只判 `<5`，不判 `>5`）。知识库：`docId` 含 `#` 时 `id.split('#')` 得到的 `docId` 被截断（`:210-214`），`wanted()` 的 `docIds` 过滤随之失效、`KnowledgeHit.docId` 指向不存在的文档；`doc:` 记录的 `title+SEP+content` 同理会被切错（`:135-139`）。
- **描述**：错误不抛异常、不记日志，表现为「某条记忆的正文丢失一半」「按 docId 过滤查不到但不过滤能查到」。`0x01` 与 `#` 都是外部输入可携带的字符，不是理论边角。
- **建议**：`doc:` 记录与 chunk id 改成两段定长编码（`docId` 用长度前缀，或 `doc:` 记录里单独存 `titleLen`），记忆 payload 改为 `saveTime` 等定长字段前置 + 仅 `content` 放末段（只 `split` 前 4 段），或直接改用 `JsonValue`/`DataObject` 编解码；最少要在 `encode` 处对 `SEP` 做替换或断言。

### [一般][存量] `HydraKnowledgeStore.upsert` 先 purge 后写，非原子：并发或中断会留下缺块文档

- **位置**：`f_llm/src/store/hydra/ContentStore.cj:114-130`（`upsert` → `purgeChunks` `:230-239`）
- **来源**：存量
- **判据**：review-checklist §12.1（检查-然后-写入 / 复合操作不原子）、§11（资源对称性、崩溃路径）
- **证据**：静态确定 —— `upsert` 第一步 `purgeChunks` 按 `DOCS` 里记录的旧块数逐条删除，再逐块写入新块，最后才写 `DOCS` 计数；全程无锁、无版本号、无事务。`upsert` 与 `remove`（`:144-148`）同为「多次独立 RPC」，`f_hydra` 侧每条都是独立两阶段写。
- **描述**：①同一文档并发 upsert：A purge 后 B purge（此时 `DOCS` 仍是旧值）→ A 写块 → B 写块覆盖，最终 `DOCS=seq_B`，但块是交错的，可能出现 0..max(seq) 空洞或残留旧块；②写块过程中进程退出/网络中断：`doc:` 记录已更新而块只写了一半，`DOCS` 未更新 → 该文档检索永久缺块，且下次 upsert 会按**旧** `DOCS` 计数清理，漏删的块长期残留。远程部署下这个窗口是「N 次 HTTP 往返」的量级。
- **建议**：改为「写新块到带版本后缀的 key → 写 `DOCS{version,count}` → 异步删旧版本」，让 `search` 只读当前版本，做到「先写后切」；或至少把 `DOCS` 计数先清零再写块（宁可短期查不到，也不要留残块），并在 purge 失败时抛出而不是继续。

### [一般][存量] kind 过滤对每个候选做两次 `transport.get`（结构重复读取 + 两次读之间的状态不一致）

- **位置**：`f_llm/src/store/hydra/MemoryRepository.cj:203-212`（`collect` 第 208 行 `transport.get`）与 `:215-230`（`kindWanted` 第 219 行 `transport.get`）
- **来源**：存量
- **判据**：review-checklist §2（同语义重复执行）、§6.4（同一输入重复解析/重复取数），并发面见 §12.1
- **证据**：静态确定 —— `collect` 先调 `kindWanted(query, collection, hit.id)`，后者内部 `transport.get(collection, id)` 并 `decode` 出 `kind`；返回后 `collect` 立刻对**同一个 key** 再 `get` 一次并 `decode` 一次。两次调用之间没有任何写操作，结果必然相同（除非另一线程刚好删除）。远程传输下每次 `get` 是一次 HTTP JSON-RPC（`HttpTransport.cj:94-118`）。
- **描述**：`searchDense`/`searchSparse` 的每个候选（`namespaces × limit` 条，默认可达数十条）都要 2 次往返 + 2 次 payload 解码，检索延迟随候选数翻倍；同时 `kindWanted` 用 `decode(0, record)`（`:221`）构造一条 `userId=0` 的临时 `MemoryRecord` 只为读一个 `kind` 字段。未提供 profile 数据，按铁律不写成性能缺陷，只报「确定存在的重复读取」。
- **建议**：`kindWanted` 改为接收已取到的 `record`（或直接返回 `?MemoryRecord`），`collect` 只 `get` 一次；顺带把 `decode` 拆成 `kindOf(record)` 之类的轻量读取，避免为取一个字段构造整条记录。

### [轻微][存量] `ensure(now)` 的 `now` 未使用，且写后不做校验（与 `acquire` 不一致）

- **位置**：`f_llm/src/store/hydra/EvolutionLease.cj:57-70`（`ensure`），对照 `:80-94`（`acquire` 有写后读校验）
- **来源**：存量
- **判据**：review-checklist §1（读了不用）、§12.1（发布未校验）
- **证据**：静态确定 —— `ensure(now)` 方法体没有引用 `now`；`read()` 为空时直接 `write(created)` 并把自己写的值返回，没有 `acquire` 里的 `if(read() == created)` 校验。
- **描述**：两个节点同时启动时各自写入、各自返回不同的租约值；返回值只用于 `EvolutionLeases.bootstrap()` 的返回与日志（`loom/EvolutionLeases.cj:64`），实际互斥仍由 `acquire` 的写后读校验承担，因此不构成双跑，但「bootstrap 报告的租约值与库里的值不一致」会误导排障，`now` 这个未用参数也让人误以为 `ensure` 与日期有关。
- **建议**：删掉参数或真正用它判日；`ensure` 也加一次写后读校验（写输的一方返回 `read()` 的结果），与 `acquire` 口径统一。

### [轻微][存量] `llm_hydraPath` 的读取与默认值在三个文件各写一遍，且绕过 `StoreSettings`

- **位置**：`f_llm/src/store/hydra/ContentStore.cj:35`、`f_llm/src/store/hydra/MemoryRepository.cj:49`、`f_llm/src/store/hydra/EvolutionLease.cj:41`
- **来源**：存量
- **判据**：review-checklist §2（字面量复制 / 换算复制）
- **证据**：静态确定 —— 三处都是 `DeployPaths.resolve(getVariable('llm_hydraPath') ?? './data/f_hydra')`，逐字符相同；模块其余配置项统一走 `StoreSettings.load()`（`store/StoreSettings.cj:72-74`），只有 hydra 这三处直读环境变量。
- **描述**：改默认目录或加新的解析规则时要同步改三处，漏一处就出现「记忆写在一个目录、租约写在另一个目录」；也让 `StoreSettings` 不再是配置的唯一入口。
- **建议**：在 `StoreSettings` 里加 `hydraPath` 字段（默认值单点定义），三处改为读它；或至少在 `hydra` 包内提供一个 `defaultLocation()` 帮助函数。

### [轻微][存量] 若干同语义实现可合并（数字串、稀疏 CSV、id 列表拷贝、名字列表、分页过滤、自写 `sqrt`）

- **位置**：`f_llm/src/store/hydra/HttpTransport.cj:229-238`（`numbers`）vs `f_llm/src/store/VectorMath.cj:29-38`（`literal`）；`HttpTransport.cj:72-81` vs `:135-144`（tokenIds/weights CSV）；`HttpTransport.cj:153-157` vs `:175-179`（id 列表拷贝）；`f_llm/src/store/Stores.cj:118-132`（`contentNames`/`metaNames`）；`f_llm/src/store/hydra/MemoryRepository.cj:157-168` vs `:174-187`（`list`/`listByKind`）；`f_llm/src/store/VectorMath.cj:62-72`（自写 `sqrt`）
- **来源**：存量
- **判据**：review-checklist §2（只改类型名 / 换控制流 / 字面量复制）
- **证据**：静态确定 —— ①`numbers` 与 `literal` 对 `Array<Float64>` 都输出 `[a,b,c]`，逐行对齐，唯一差异是 `literal` 为 `public` 供 SQL 侧复用；②`upsert` 与 `searchSparse` 各写一遍「首元素不加逗号」的 CSV 拼接（`:74-81`、`:137-144`）；③`ids`/`idsFiltered` 尾部都是 `for(id in response.result.ids){ result.add(id) }`（`ArrayList` → `ArrayList` 的纯拷贝）；④`contentNames`/`metaNames` 只差遍历哪张表；⑤`list`/`listByKind` 只差 id 来源；⑥`VectorMath.sqrt` 是 30 次牛顿迭代，而 `std.math.sqrt` 在 `f_chart`（`BlandAltmanChart.cj:242`）等模块已在用。
- **描述**：以上均未发现行为差异（错误文案、边界、日志级别、可空性已逐项核对），但让「改一处忘另一处」成为常态，尤其 ②③ 属序列化格式：稀疏向量的 CSV 规则一旦要改（如支持负权重编码），漏改一处就是静默错数据。
- **建议**：②③ 合并为 `HttpTransport` 内两个私有帮助函数（`sparseCsv`、`toList`）；①让 `HttpTransport.numbers` 直接调 `VectorMath.literal`（同模块，无分层问题）；④⑤ 抽成带参数的单一实现；⑥删除自写 `sqrt`，用 `std.math.sqrt`。

### [轻微][存量] `parse<T>` 的异常消息把整个响应体拼进去，敏感内容会进日志

- **位置**：`f_llm/src/store/hydra/HttpTransport.cj:221-227`
- **来源**：存量
- **判据**：review-checklist §10（安全性：敏感数据进日志/异常）、§11（错误处理）
- **证据**：静态确定 —— `throw IllegalStateException('hydra rpc response is not a valid ${text}')`，`text` 是完整响应体（含 `payload`：记忆标题与正文）。
- **描述**：一次协议不匹配就能把整条记忆（可能是隐私数据）写进日志，且消息长度无上限；排障真正需要的只是「哪个 method、响应前 N 字节」。
- **建议**：消息改为 `'hydra rpc response is not a valid ${method} response'`，需要时附 `text.size` 与前 128 字节的截断预览（截断处加 `…`），`method` 由 `call` 传入 `parse`。

### [轻微][存量] `CrossBackendConformance_test` 重复 import 同一批包

- **位置**：`f_llm/src/store/it/CrossBackendConformance_test.cj:19-20` 与 `:29-30`
- **来源**：存量
- **判据**：review-checklist §1（未使用的 import / 冗余声明）
- **证据**：静态确定 —— `import fountain::f_llm.store.postgres.*` 与 `import fountain::f_llm.store.mysql.*` 在文件内出现两次，内容完全一致。
- **描述**：可能触发重复 import 告警，也让读者以为两段 import 有区别。
- **建议**：删除第二处两行。

### [轻微][存量] `Stores.DEFAULT_CONTENT` / `DEFAULT_META` 与 `StoreSettings` 的同名常量值冲突

- **位置**：`f_llm/src/store/Stores.cj:29-32`（`'postgres'`/`'postgres'`）vs `f_llm/src/store/StoreSettings.cj:39-40`（`'f_hydra'`/`'f_store'`）
- **来源**：存量
- **判据**：review-checklist §11（与规格/文档冲突：默认值两处定义不一致）
- **证据**：静态确定 —— 这两个常量全仓零引用（`StoreSettings.cj:72-74` 与 `doc/f_llm.md`、`README.md:768` 用的是 `StoreSettings` 那一组）；`Stores` 是 `public class`，成员对外可达，**不判死代码**。
- **描述**：下游若照 `Stores.DEFAULT_CONTENT` 写死默认值，会得到与 README 相反的结果（`postgres` 需要真库，无库部署直接启动失败）。与文档部分（part1 对 `README.md:764-765` 的核对）同源，合并时请去重保留一条。
- **建议**：删除这两个常量，或改成 `public static const DEFAULT_CONTENT = StoreSettings.DEFAULT_CONTENT`，让默认值只有一处定义。

<!-- 第 23 部分 -->

### [严重][存量] `MemoryRepository.remove` 先按 `id` 删子表、后按 `(userId, id)` 删主表，可越权删掉他人记忆的索引

- **位置**：
  - `f_llm/src/store/mysql/MemoryRepository.cj:126-131`（先 `DELETE FROM llm_memory_token WHERE memory_id = ?`，再 `myRemoveMemory(userId, id)`）
  - `f_llm/src/store/postgres/MemoryRepository.cj:122-125`（先 `deleteVectors(id)`，再 `removeMemory(userId, id)`）
  - 同类未限定 `user_id` 的子表删除：`f_llm/src/store/mysql/MemoryRepository.cj:57-66`、`f_llm/src/store/postgres/MemoryRepository.cj:53-62`（`upsertSparse`）
- **来源**：存量（`git blame -L 123,124` → `05ba66d08d` / `cdea037a40`，2026-10-30）
- **判据**：review-checklist §11（越权 / 资源不对称）、§10（安全性：外部输入未校验）、§12.1
- **证据**：静态确定 —— 子表删除语句只带 `memory_id`，主表删除带 `user_id AND id`；两者不是同一条件。`id` 由调用方传入，调用链 `LoomStoreGateway.cj:209-210` 直接把流程参数 `args['id']` 交给 `content.memory.remove(userId, id)`，`userId` 只来自流程上下文，代码里没有任何「先按 `(userId, id)` 校验归属」的前置查询。
- **描述**：传入他人的 `id`（或模型编造的 `id`）时，主表删除影响 0 行、`remove` 返回 `false`，但子表已经被删干净：
  - MySQL：被删 `llm_memory_token` → 受害者该条记忆的稀疏倒排消失，`searchSparse` 再也召不回它（正文仍在，dense 仍可召回）；
  - PostgreSQL：被删 `llm_memory_vector` → `searchDense` 的 `JOIN llm_memory_vector` 直接丢行，该记忆对语义检索**完全不可见**（需 `MemoryIndexRebuilder` 重建才恢复）。
  两个方向都是静默的跨租户数据破坏，且返回值 `false` 会让调用方以为是「id 不存在」。
- **建议**：把归属校验放进同一条语句：MySQL `DELETE FROM llm_memory_token WHERE memory_id = ? AND user_id = ?`（并保留 `myRemoveMemory(userId, id)` 返回行数作为唯一成功判据）；PG 改为 `deleteVectors(id, userId)`，SQL 写成 `DELETE FROM llm_memory_vector WHERE memory_id = ? AND EXISTS (SELECT 1 FROM llm_memory WHERE id = ? AND user_id = ?)`。规范做法是主表 `DELETE ... RETURNING id` 成功后再删子表，或在同一事务内先校验归属。

### [一般][存量] `MemoryRecord.saveTime` 恒为查询时刻，演进水位线因此永远「有新材料」

- **位置**：`f_llm/src/store/mysql/MemoryRepository.cj:176-186`（`recordOf` 第 184 行 `DateTime.now()`）、`f_llm/src/store/postgres/MemoryRepository.cj:150-160`（第 158 行同）
- **来源**：存量（`git blame -L 184,184` → `7d173af446`，2026-10-29）
- **判据**：review-checklist §11（语义与命名不符 / 契约与实现不符）、§10
- **证据**：静态确定 —— `MemoryRecord.saveTime` 是对外字段（`StoreModels.cj:29`，README `f_llm/README.md:264`、`doc/loom.md:396` 都写了「按真实时间比较」），但两处方言 DAO 的 `SELECT` 都不含 `save_time`（`dao/mysql/MemoryDAO.cj:125,139,151`；`dao/postgres/MemoryDAO.cj:143,157,169`），映射时直接填 `DateTime.now()`。
- **描述**：`list/get` 返回的 `saveTime` 是「读的时刻」，不是写入时刻。`LoomStoreGateway.cj:442` 把它序列化给流程侧，`SkillEvolutionJob.cj:295-300` 用它做 `ExperienceItem.at`，`fresh()`（同文件 247-255）以 `at > since` 判定新素材。由于 `at` 恒为当轮查询时间，**每一条经验每轮都被判为「全新」**，同时第 218-238 行把水位线推进到该时刻 ⇒ 每轮重复聚类最多 500 条经验（`load` 的 `limit` 默认 500），白跑 LLM 调用并可能重复提案技能；`doc/loom.md:396` 承诺的「按真实时间比较」实际不成立。
- **建议**：两处方言 DAO 的 `get/list/listByKind` 补 `save_time` 列，`recordOf` 用 `save_time` 解析成 `DateTime`；解析失败再退化为 `now()`（并保留注释说明退化条件）。

### [一般][存量] PostgreSQL `remove` 漏删 `llm_memory_token`，孤儿行只增不减

- **位置**：`f_llm/src/store/postgres/MemoryRepository.cj:122-125`（对比 `f_llm/src/store/mysql/MemoryRepository.cj:126-131` 有删 token）
- **来源**：存量（`git blame -L 123,123` → `05ba66d08d`）
- **判据**：review-checklist §11（资源不对称 / 长期持有）、§5（无界容器）
- **证据**：静态确定 —— PG 的 `remove` 只调 `deleteVectors` + `removeMemory`，全仓没有第二处按 `memory_id` 删 token 的调用（`grep llm_memory_token` 仅命中 `clearTokens`（`dao/postgres/MemoryDAO.cj:78`，无调用者）、`insertToken`、`searchSparse` 与两处 `upsertSparse` 的裸 DELETE）。
- **描述**：`llm_memory` 删掉后 `llm_memory_token` 里对应 `memory_id` 的行永久留存。`searchSparse` 用 `JOIN llm_memory` 过滤，所以结果正确，但表按「每次记忆写入的 token 数」无界增长（bge-m3 词表命中通常几十到上百行/条记忆），且 `llm_memory_token` 没有 TTL/清理任务。
- **建议**：`remove` 内补 `clearTokens(id)`（正好已有该 DAO 方法且当前零引用），顺序与 MySQL 对齐：先删 token → 删 vector → 删主表。

### [一般][存量] MySQL / PostgreSQL 存储层是逐行复制的两套代码，已出现 4 处行为漂移

- **位置**（成对文件，包内同名）：
  - `f_llm/src/store/{mysql,postgres}/ContentStore.cj:23-57`
  - `f_llm/src/store/{mysql,postgres}/KindPersistence.cj:24-86`
  - `f_llm/src/store/{mysql,postgres}/MetaStore.cj:30-203`
  - `f_llm/src/store/{mysql,postgres}/TokenUsageSaver.cj:29-37`
  - `f_llm/src/store/{mysql,postgres}/EvolutionLease.cj:32-109`
  - `f_llm/src/store/{mysql,postgres}/EvolutionStateStore.cj:33-133`
  - `f_llm/src/store/{mysql,postgres}/EvolutionStore.cj:33-113`
  - `f_llm/src/store/{mysql,postgres}/KnowledgeStore.cj:31-237`
  - `f_llm/src/store/{mysql,postgres}/MemoryRepository.cj:37-226`
- **来源**：存量（两套文件同批引入，`git blame` 命中 2026-10-29/30 同两三个提交）
- **判据**：review-checklist §2（只改类型名 / 跨层复制）
- **证据**：静态确定 —— 9 对文件合计 ≈2,627 行，结构逐一对应；`diff`（去掉版权头）只有 ≈417 行不同（≈84% 重复），其中 7 个文件差异 ≤68 行、几乎全是 `DRIVER` 字面量与 DAO 类型名替换（如 `KindPersistence` 16 行、`TokenUsageSaver` 10 行、`ContentStore` 11 行）。
- **描述**：真正的语义差异只有 4 处，且都已出现漂移：
  1. `remove` 删哪张子表不一致（见上两条：MySQL 删 token，PG 删 vector）；
  2. `EvolutionStore.ensure`：PG 额外 `dao.ensureSkillIndex()`（`postgres/EvolutionStore.cj:98-105`），MySQL 只在 DDL 里建（`mysql/EvolutionStore.cj:95-101`，靠 `dao/mysql/EvolutionDAO.cj:34` 的 `KEY idx_evo_skill`）——同名字段行为不同；
  3. `MetaStore` 属性：PG 缓存四个子 store（`postgres/MetaStore.cj:33-36`），MySQL 每次访问 `new`（`mysql/MetaStore.cj:34-45`）；
  4. `KnowledgeStore.upsert`：PG 用 `vectorOf` 单条 SQL 写入 NULL 降级（`postgres/KnowledgeStore.cj:74,188-193`），MySQL 分两条 SQL 二选一（`mysql/KnowledgeStore.cj:71-75`）。
  这四条里任何一条再度演化（例如加「删除时同时清 colbert 标记」）都只能靠人肉同步两份文件，上面的越权删除与漏删就是这么产生的。
- **建议**：抽一层与方言无关的 `SqlContentStoreBase` / `SqlEvolutionStateBase` 等包内抽象（`internal abstract class`），把「读-映射-组装、锁与建表时机、子表清理顺序」放基类，方言只提供 `DRIVER` 常量与 3~5 个 DAO 方法（SQL 本来就已经在 `dao/{mysql,postgres}` 里，属于天然分层落点）；差异点必须显式参数化（如 `func removeChildren(id, userId)`），不允许两边各写一份。合并前先把上面 4 处漂移定成同一语义。

### [一般][存量] 临界区包住全部数据库 I/O，而共享状态只有一个 `ready` 布尔

- **位置**：`f_llm/src/store/mysql/EvolutionStateStore.cj:41-119`（`ensureSchema/get/save/processedKnowledge/markKnowledge/processedAmong` 六个方法都 `synchronized(mutex){ … 全部 SQL … }`）、`f_llm/src/store/postgres/EvolutionStateStore.cj:46-124`；同类：`mysql/EvolutionLease.cj:37-83`、`postgres/EvolutionLease.cj:42-90`、`mysql/EvolutionStore.cj:41-93`、`postgres/EvolutionStore.cj:43-96`
- **来源**：存量
- **判据**：review-checklist §12.2（大粒度锁：锁内 I/O）、§6.2
- **证据**：静态确定 —— 临界区内是 `daoOf().xxx(...)` 一类的行往返（`markKnowledge` 还是 N 次 insert 的循环，`mysql/EvolutionStateStore.cj:99-103`），而 `mutex` 保护的唯一可变状态是 `tableReady`/`ready`（`mysql/EvolutionStateStore.cj:121-128`、`mysql/EvolutionLease.cj:85-90`）。`Mutual` 是实例字段，单例 bean 下所有调用者共享。
- **描述**：这是「一次建表标记」用了「串行化整类」的锁：同一实例上的 `get/save/processedAmong` 全部互相排队，`processedAmong` 的 `IN` 查询与 `markKnowledge` 的 N 次写入也会互斥。演进是低频批处理，所以目前未必形成热点（无测量数据），但锁的范围与它保护的不变量严重不匹配，一旦有并发读（例如网关查水位线）就退化成串行。
- **建议**：把 `ready` 改成一次性的原子初始化（`AtomicBool` 或 `Mutex` 只包住 `ensureReady` 本身），`ensureSchema` 之外的方法调完 `ensureReady()` 立刻出锁再执行 SQL；若确实需要「同一事务语义」，用显式事务而不是实例锁（`postgres/EvolutionStateStore.cj:30-31` 的注释已经承认当前没有事务）。

### [一般][存量] MySQL 稠密召回把「用户全部记忆 id」做成 JSON 数组，空集合时为 NULL

- **位置**：`f_llm/src/dao/mysql/MemoryDAO.cj:49-66`（`filter = 'SELECT JSON_ARRAYAGG(id) FROM llm_memory WHERE user_id = …'`，再作为 `MYVECTOR_IS_ANN` 第 5 参）
- **来源**：存量（`git blame -L 49,66` 同批 2026-10-29/30）
- **判据**：review-checklist §5（按不可信规模构造中间结构 / DB 侧无界）、§6.4、§11
- **证据**：待确认 —— MySQL 官方语义中 `JSON_ARRAYAGG` 对空结果集返回 `NULL`（不是 `[]`），`MYVECTOR_IS_ANN(..., (NULL))` 的行为取决于 MyVector 组件实现：可能报错，也可能返回空集。缺的是「空 filter 调用 MyVector 的实际返回」，需要一次实测（对一个没有任何记忆的 `user_id` 调 `searchDense`）。
- **描述**：两个问题同源：① 无论 `limit` 多小，过滤条件都要把该用户所有 `id` 聚合一遍，成本随用户记忆总量线性增长（PG 侧用 `WHERE` 子句直接过滤，没有这一步）；② 新用户/空库的首次语义检索可能以 SQL 异常告终，而调用方 `MySqlMemoryRepository.searchDense`（`mysql/MemoryRepository.cj:52-55`）没有捕获，异常会一路抛到检索链路。
- **建议**：空集合走短路（先 `SELECT COUNT(*)` 或让调用方在 `searchDense` 前判断），或用 `COALESCE(JSON_ARRAYAGG(id), JSON_ARRAY())`；过滤条件尽量下推到 `MYVECTOR_IS_ANN` 能接受的列上（`namespace`/`kind`），避免全量 id 数组，并补一条「空用户检索返回空列表」的用例。

### [轻微][存量] 死代码：`minOf`（两处方言）与 `PostgresMetaStore.DRIVER` 无任何引用

- **位置**：`f_llm/src/store/mysql/KnowledgeStore.cj:230-236`、`f_llm/src/store/postgres/KnowledgeStore.cj:219-225`（`private static func minOf`）；`f_llm/src/store/postgres/MetaStore.cj:31`（`private static let DRIVER`，全类 4 处 `dao<PostgresMetaDAO>` 都直接写 `'postgres'`）
- **来源**：存量
- **判据**：review-checklist §1（`private` 符号全仓无调用者）
- **证据**：静态确定 —— `grep -rn "\bminOf\b" f_llm` 只命中定义（`KnowledgeChunker.cj:162` 是另一个同名的 `Int64` 版本），`grep DRIVER f_llm/src/store/postgres/MetaStore.cj` 只命中定义行。两处 `minOf` 是复制 `KnowledgeChunker` 时带过来的残留（真正的 min 逻辑已收进 `RetrievalScoring`）。
- **建议**：删除两处 `minOf`；`PostgresMetaStore.DRIVER` 要么删，要么把 4 处 `'postgres'` 字面量替换成它（与 MySQL 侧保持同一写法）。顺带：`mysql/EvolutionLease.cj:18`、`postgres/EvolutionLease.cj:18` 的 `import std.collection.*` 在本文件未直接命名任何集合类型，可一并清掉（编译器未报错说明 `f_orm.*` 重导出覆盖了推断需求，属可删项，删除时以编译通过为准）。

### [轻微][存量] `ContentStore` 的记忆/知识实现是未同步的惰性初始化

- **位置**：`f_llm/src/store/mysql/ContentStore.cj:30-56`、`f_llm/src/store/postgres/ContentStore.cj:31-57`；同类：`mysql/KnowledgeStore.cj:35,189-204`（`cachedDatabase` 写后无同步）
- **来源**：存量
- **判据**：review-checklist §12.1（惰性初始化：`if (x == None) { x = ... }` 首次赋值竞态）、§10
- **证据**：静态确定 —— `cachedMemory` / `cachedKnowledge` 是普通 `var`，`get()` 里「读-判 None-写」没有任何锁或原子；`MySqlContentStore` 是 `Stores` 工厂返回的单例，两个请求线程可同时进入。
- **描述**：并发首访问会各构造一个 store，后写者覆盖前者（丢一个实例），并可能出现「线程 A 用无 Embedder 的 store、线程 B 用有 Embedder 的 store」这种同一进程内两种语义并存；`cachedDatabase` 的重复写值相同，属良性。后果有限（不产生脏数据），但确实是共享可变状态无保护。
- **建议**：用 `Mutex` 包住首次构造（与 `EvolutionStore.ensure` 同一写法），或改为构造期一次性解析（`ContentStore` 的实现由 `Stores` 工厂在启动阶段创建，把 `lookupOption<Embedder>()` 挪进 `init()` 即可彻底去掉懒加载）。

### [轻微][存量] MySQL `MetaStore` 每次访问属性都新建子 store，与 PG 的缓存写法不一致

- **位置**：`f_llm/src/store/mysql/MetaStore.cj:34-45`（4 个 `get(){ MySqlXxxStore() }`）对比 `f_llm/src/store/postgres/MetaStore.cj:33-52`（4 个 `private let` 字段 + `get(){ xxxStore }`）
- **来源**：存量
- **判据**：review-checklist §2（表现形式不同的重复逻辑 / 实现漂移）、§8（减少分配）
- **证据**：静态确定 —— 子 store 无状态，行为等价；差异只是每次 `meta.characters.get(...)` 多一次对象分配，并让两方言的对象身份语义不同（PG 可做 `is` 比较，MySQL 不行）。
- **建议**：与 PG 对齐（字段持有），或干脆把「按需 new」定为规范并同步改 PG；不要一边缓存一边新建。

### [轻微][存量] 演进报告 `id` 依赖进程内 `nextId` 缓存，多写者会撞主键

- **位置**：`f_llm/src/store/mysql/EvolutionStore.cj:41-60`（`nextId` 初始化 `MAX(id)`，之后只 `++`）、`f_llm/src/store/postgres/EvolutionStore.cj:43-62`
- **来源**：存量（类注释 `postgres/EvolutionStore.cj:29-31` 明确写了「单进程写足够」）
- **判据**：review-checklist §11（检查-然后-写入）、§12.1
- **证据**：待确认 —— 缺部署形态信息：`EvolutionLease` 只保证「同一天只有一个进程跑演进」，但 `EvolutionStore.save` 是公开接口，没有租约保护；若同库存在第二个实例（蓝绿发布、多副本），两边各自 `MAX(id)+1` 会算出同一个 `id`，`INSERT` 直接主键冲突。冲突异常在 `SkillEvolutionJob.cj:208-213` 被 `catch` 吞掉，表现为报告静默丢失。
- **建议**：改用自增列/序列（MySQL `AUTO_INCREMENT`、PG `GENERATED BY DEFAULT AS IDENTITY`）由数据库分配 id，或 `INSERT ... ` 冲突时重试一次重算 `MAX(id)`；至少把「单进程」写成 `ensureSchema` 的显式前置条件并在启动日志里提示。

### [轻微][存量] 集成测试污染全局配置与共享库

- **位置**：`f_llm/src/store/it/StoresBootstrap_test.cj:31-49`；`f_llm/src/store/mysql/MySqlMemoryRepository_test.cj:40-71,82-90`；`f_llm/src/store/postgres/PostgresMemoryRepository_test.cj:119-178`
- **来源**：存量
- **判据**：review-checklist §10（可测试性）、§14（用例覆盖）
- **证据**：静态确定 —— `StoresBootstrapTest` 用 `Config.set<String>` 改写全局 `llm_memoryStore` 且不还原（第二个用例留下 `sqlite`），同进程后续任何 `Stores.content()` 都会抛「unknown llm_memoryStore」；`MySqlMemoryRepository_test.prepare()` 每用例 `DROP TABLE llm_memory / llm_memory_token`，与 `store/it/CrossBackendConformance_test.cj:161` 共用同一个 `fllm_test` 库；`PostgresMemoryRepository_test.testConfCandidatesFilterDisabledAndZeroWeight` 直接 `DELETE FROM llm_conf` 清表。
- **描述**：`@Test` 默认并行/乱序执行时，这些用例会互相清表或改全局配置，表现为偶发失败（`available()` 只在连不上库时跳过，断言失败仍会暴露，但「表被别的用例删了」会走成 SKIP 分支，把真失败伪装成跳过）。
- **建议**：用例结束用 `Config.set` 还原或提供 `Stores.resetForTest()`（`Stores.cj:62-65` 已有）；表名按用例加后缀（或每用例独占 `schema`/`database`）；`DELETE FROM llm_conf` 改为只删本用例插入的行。

### [轻微][存量] `processedKnowledge` 多一次数组拷贝、`get` 用 `for` 取单行

- **位置**：`f_llm/src/store/mysql/EvolutionStateStore.cj:82-93`（`ArrayList.add` → `toArray()`）、`f_llm/src/store/postgres/EvolutionStateStore.cj:87-98`；`get` 用 `for(row in …)` 赋值后再 `box.value`：`mysql/EvolutionStateStore.cj:49-60`、`postgres/EvolutionStateStore.cj:54-65`、`mysql/EvolutionLease.cj:92-97`、`postgres/EvolutionLease.cj:99-104`
- **来源**：存量
- **判据**：review-checklist §7（删除中间副本）、§10（可读性）
- **证据**：静态确定 —— 5000 条上限下 `ArrayList<String>` + `toArray()` 即两份引用数组同时存活；`for` 循环取单行（主键查询最多 1 行）没有 `break`，读者需要自己确认「不会覆盖」。
- **建议**：直接用 `Array<String>` 或 `ArrayList<String>`（接口本身若返回 `Array`，用 `list.toArray()` 前先 `ArrayList` 预分配容量）；单行查询改 `firstToMap()` 或 `for` 内 `break`。

<!-- 第 24 部分 -->

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

<!-- 第 25 部分 -->

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

> 不是缺陷，是「还能更好」；无基线的方案只作待验证假设，不进 tasks。

<!-- 第 1 部分 -->

### [堆内存] 切块改为流式消费，去掉全文 Rune 缓冲

- **现状**：`KnowledgeChunker.splitImpl`（`src/store/KnowledgeChunker.cj:66-87`）为整篇文档建 `ArrayList<Rune>`（4 B/元素）+ 输出块副本，峰值 ≈ 5×内容大小；生命周期到函数返回（local 档随 region 释放，堆档等 GC）。
- **方案**：用 `content.runes()` 单趟 + 固定窗口（`Array<Rune>(maxChars + overlap)` 环形缓冲）产出块；对 >2 MiB 的输入先按 `maxChars` 的整数倍切片再拼接，保证块边界与现有实现逐字节一致。
- **预期**：峰值从 ≈5×content 降到 ≈`2 × (maxChars + overlap) × 4 B` + 已产出块总量（输出本身仍是 O(n)，但这部分本来就要落库）。量化收益需峰值内存数据。
- **代价**：块边界必须与原实现完全一致（含最后一块不足窗口、`overlap >= maxChars` 的校验时机），需要等价性用例；local 档（README:21 的卖点）可能失去存在意义，需要重新评估是否保留 local mode 编译开关。
- **验证**：同机 `-O2`，10 MB / 100 MB 文档各 10 轮，采 `getUsedHeapSize()` 峰值与 RSS，对比改前改后与块输出哈希。
- **证据状态**：`无基线（待验证，不进 tasks）`

<!-- 第 2 部分 -->

> 本部分无 `.cj` 文件，不提堆内存 / CPU 改造方案。`perf-baseline.md` 已给出 KnowledgeChunker 的 local / 堆对照（同 SDK、`-O2`、3 次采样），可作为 `store/` 子轮的现成证据，本部分不重复评估。

<!-- 第 3 部分 -->

> 本部分清单全部是 `.md`，不存在可改造的堆内存 / CPU 路径，因此本部分不产出优化方案（堆内存 0 条 / CPU 0 条）。涉及 `f_llm` 代码的优化方案请以第 1、2、4–25 部分的结论为准。

<!-- 第 4 部分 -->

本部分为纯文档，未提出堆内存 / CPU 优化方案：文档侧没有可执行的分配或算法改动，且本部分无 `cjprof` / `cjpm bench` 数据，按铁律不虚列方案（实现侧的候选方案见第 1、5 部分）。

> #1 的修复（`since` 下推或升序游标）属于**查询契约变更**，不按「性能优化」立项；若顺带减少扫行数，也必须先有改前改后 `EXPLAIN` + 同数据量耗时对照，当前无基线。

<!-- 第 5 部分 -->

### [堆内存] `experience` 列表合并去副本

- **现状**：`LoomStoreGateway.cj:149-163` 为双 kind 各建一份 `ArrayList<MemoryRecord>`（每个最多 `limit` 条），再逐条 `add` 进 `merged`，同一批记录同时存在两份引用数组；缺省 `limit=50` 时最多 100 条记录 + 3 个列表对象。
- **方案**：给 Store 增加「kind 集合 + 分页」的读取（`listByKinds`），一次取一页，去掉 `merged` 中间容器；`MemoryQuery.kinds` 只服务 `search`，不能直接复用。
- **预期**：每次 `memory.list`（experience）少 2 个 `ArrayList` 与 1 次全量拷贝；对象数从 `3 + 2N` 降到 `1 + N` 量级。
- **代价**：`MemoryStore` 契约变更，`SqlLoomStore` / `FStoreLoomStore` / hydra 实现都要跟进。
- **验证**：`getAllocatedHeapSize()` 前后对照，跑 200 次 `memory.list`（limit=50、两 kind 各 50 条）；同时断言返回条数与顺序不变。
- **证据状态**：`无基线（待验证，不进 tasks）`

### [CPU] 演进素材的 N+1 跨边界读取

- **现状**：`SkillEvolutionJob.cj:318-341` 先取最多 500 个 docId，再对每个「归属匹配」的 id 各发一次 `knowledge.get`，即 1 + K 次 `LoomStoreGateway.call`（每次含 JSON `parse` 与字符串拼装），K 最大 500，全部在演进任务的单线程里串行。
- **方案**：给知识存储加批量读（`docIds` 直接返回 id+content，或 `knowledge.getMany`），把 K+1 次降到 1 次；顺带把租户前缀过滤下推到存储层（同时解决上文「分页先于过滤」）。
- **预期**：跨边界调用次数下降一个量级（K≈500 时约 500→1）；端到端收益取决于单次 `call` 开销。
- **代价**：新增存储侧 API，三个实现都要补；返回体变大，单次物化上限需评估。
- **验证**：`cjprof record` 跑一次演进任务（500 条知识素材），对比 `knowledgeOf` 自耗时；`cjpm bench -O2` 同输入多轮取中位数。
- **证据状态**：`无基线（待验证，不进 tasks）`

<!-- 第 6 部分 -->

> 本部分为规格文档；文档里承诺的内存 / CPU 改造（rune 缓冲 local 化、渲染单遍扫描、检索候选上界、colbert 重排前 N）均已在实现落地，本轮没有新的可执行方案。相关收益是否成立见「待验证假设」。

<!-- 第 7 部分 -->

> 下列不是缺陷。**本部分没有改前基线数据**，全部标 `无基线（待验证）`，不进 `todo.md` / `tasks.md`。

### [CPU] `ChannelInboxFunction.render` 用 `+=` 逐段拼 JSON

- **现状**：`f_llm/src/channel/ChannelFunctions.cj:133-156`，双层循环里对 `text` 连续 `+=`（每条消息 6 次、每个附件 3 次），`String` 不可变 ⇒ 每轮复制已拼内容；输入规模 = `limit` 条 × 附件数
- **方案**：改用 `StringGenerator`（同模块 `AgentTask` 已在用），或直接 `JsonArray`/`JsonObject` 组装后 `toString()`
- **预期**：拼接成本从 O(total²) 降到 O(total)；`limit` 越大收益越明显（默认 10 条时可忽略）
- **代价**：无（输出字节需逐字符比对，转义继续走 `JsonString`）
- **验证**：`cjpm bench -O2` 对 `render` 做 1/10/100 条消息 × 0/5 附件的时间对照，取中位数
- **证据状态**：`无基线（待验证，不进 tasks）`

### [CPU] `populatePromptsParams` 每次调用都重新编译同一段 `TextTemplate`

- **现状**：`f_llm/src/agents/AgentTask.cj:230-236` 在每次事件、每个技能上调用 `TextTemplate.compile(...)`；`skill.details` 是 DB 里的稳定文本，同一技能在多轮对话中被反复编译
- **方案**：按模板串内容做小容量 LRU（上限几十条），或把编译结果挂到技能只读视图
- **预期**：省掉每轮 N 次模板解析（N = 主技能数 + 辅助技能数）；端到端占比未测
- **代价**：多一份缓存；用内容 hash 作键可在技能更新后自然失效
- **验证**：`cjprof record` 跑「5 主技能 + 10 辅助技能」的事件，看 `TextTemplate.compile` self time；改后同场景对照
- **证据状态**：`无基线（待验证，不进 tasks）`

### [堆内存] `BalanceSnapshot.raw` 在多币种/多平台结果里重复持有整段响应

- **现状**：`f_llm/src/balance/BalanceQueriers.cj:110,176,241` 每条快照都保存完整 `body`；DeepSeek 多币种时同一 body 被复制 N 份（N=币种数），`queryAll` 汇总多平台后再叠加；生命周期到快照被丢弃为止
- **方案**：把 `raw` 提到「一次查询的结果」层（一个 body + 多个快照），或改成 `?String` 仅在排障开关打开时保存
- **预期**：单次查询 raw 占用从 N×body 降到 1×body（N=2 时 raw 部分约减半，整体占比很小）
- **代价**：排障需要改调用方式；`BalanceSnapshot` 构造参数变化
- **验证**：同响应跑 100 次查询，比较 `getAllocatedHeapSize()` 与峰值 `getUsedHeapSize()`；确认 raw 字段访问路径只有测试/排障
- **证据状态**：`无基线（待验证，不进 tasks）`

<!-- 第 8 部分 -->

> 本部分没有可用的 bench / profile 数据，以下均为「还能更好」的结构性建议，收益未验证。

### [堆内存] 附件落盘改流式，去掉「整份 `Array<Byte>` + `toArray` 副本」的峰值

- **现状**：`ReceivedAttachment.read: () -> Array<Byte>`（`EmailChannel.cj:26-36`）把整份附件读成数组，`EmailChannel.receive:268-272` 再交给 `AttachmentSink.save(directory, filename, bytes)`（`:148`）。`f_email` 侧 `MailAttachment.read()` 是「64 KiB 缓冲逐块 `add` 进 `ArrayList<Byte>` 再 `toArray()`」（`f_email/src/EmailFacade.cj:141-155`），峰值 ≈ 2 × 附件字节 + 扩容余量。
- **方案**：把 `ReceivedAttachment` 的读取入口换成 `open(): InputStream` 或 `saveTo(path: Path)`，`AttachmentSink` 边读边写、单块 64 KiB，直接复用 `EmailFacade.cj:158-180` 的 `saveTo`。
- **预期**：单附件峰值从 ≈2n 降到 ≈64 KiB + 落盘缓冲；峰值只与「并发落盘的附件数」相关，不再随单个附件大小线性增长。
- **代价**：`AttachmentSink.save` 签名变更（`Array<Byte>` → 流/回调），测试里的假 `read` 闭包要改；写失败需删半截文件（见「轻微/失败不清理」）。
- **验证**：20 MiB / 100 MiB 附件各 1 次，`-O2`，记录 `getAllocatedHeapSize()` 峰值与 RSS 峰值，改前改后对照。
- **证据状态**：`无基线（待验证，不进 tasks）`

### [CPU] 发送侧白名单每次重新解析 + 每个附件重新 `canonicalize` 全部根目录

- **现状**：`EmailChannel.send:205` 每次调用 `LLMConfig.channelSendRoots()`（`LLMConfig.cj:227-244`：读配置 + `split(',')` + `trimAscii` + 新建 `ArrayList`），随后对**每个附件**在 `checkAttachment:230-236` 里对**每个根目录**做一次 `canonicalize`（真实系统调用，含 `realpath` 解析）。
- **方案**：`channelSendRoots()` 结果按 `Channel` 生命周期缓存（`EmailChannel` 构造时解析一次，配置按 `fountain-baseline.md` §5「启动只读一次」本就不热更新）；`canonicalize(root)` 的结果与 roots 一起缓存。
- **预期**：把「附件数 × 根目录数」次 `realpath` 降到「根目录数」次；单封 5 附件、3 根目录时省 12 次系统调用（数量级推断，未计时）。
- **代价**：配置改后需重启（与现有语义一致）；缓存要在重装配时重建。
- **验证**：`cjpm bench -O2` 跑「单封 5 附件 × 1000 次 send」（FakeTransport 打桩，只测校验段），对比 p50/p99。
- **证据状态**：`无基线（待验证，不进 tasks）`

### [CPU] `freeName` 的线性探测：同名文件多时逐个 `exists`

- **现状**：`AttachmentSink.freeName:134-141` 从 `-2` 起逐个 `exists(Path(...))` 直到找到空位；同名附件长期累积时探测次数线性增长，且整段在 `sinkMutex` 内（`:160-164`）。
- **方案**：用「独占创建 + 失败换名」把探测与创建合并为一次系统调用，或先 `list` 一次目录建 `HashSet` 再选名。
- **预期**：k 次探测降为 1 次创建尝试；目录内已有 100 个同名文件时省 100 次 `stat`（量级推断，未计时）。
- **代价**：错误分类要区分「已存在」与「无权限/磁盘满」，避免把权限错误当成重名继续换名。
- **验证**：同一目录预置 10/100/1000 个 `a-N.txt`，对 `save` 分段计时，`-O2`，各 1000 次取中位数。
- **证据状态**：`无基线（待验证，不进 tasks）`

<!-- 第 9 部分 -->

> 不是缺陷，是「还能更好」。本部分没有性能基线（未跑 `cjpm bench -O2` / `cjprof`），下列收益一律为**待验证**，不进 `tasks.md`。

### [CPU] 稠密召回把「该用户全部 id」用 `JSON_ARRAYAGG` 物化成过滤数组

- **现状**：`mySearchDense` 的 ANN 过滤参数是 `SELECT JSON_ARRAYAGG(id) FROM llm_memory WHERE user_id = ? [AND namespace IN (…)]`（`f_llm/src/dao/mysql/MemoryDAO.cj:49-59`），每次检索都由 MySQL 把该用户**全部**记忆 id 聚合成一个 JSON 数组再交给 `MYVECTOR_IS_ANN`。规模随单用户记忆条数线性增长（`llm_memory` 无上限约束，`tables-mysql.sql:110-122` 无明显淘汰机制）
- **方案**：先把候选集收窄再聚合 —— (a) 在 filter 子查询里加 `namespace` / 时间窗 / `LIMIT`（例如只取最近 N 天或 `ORDER BY save_time DESC LIMIT 20000`）；(b) 若 MyVector 支持多列过滤，把 `kind` 也下推（与 #3 一起做）；(c) 单用户记忆量超阈值时改用两级检索（先稀疏/时间窗取候选 → 再 ANN）
- **预期**：单次检索的聚合行数从「全量」降到「窗口量」，语句耗时与临时内存同比例下降；具体幅度需实测
- **代价**：候选集被截断 → 极旧记忆可能不再被语义召回（需要产品确认可接受性）；filter 文本更长
- **验证**：`cjprof record` / 慢查询日志对比同一账号 1k / 10k / 100k 条记忆下 `KnowledgeStore`/`MemoryRepository.searchDense` 的 P50/P95 与 `Handler_read_*`
- **证据状态**：`无基线（待验证，不进 tasks）`

### [堆内存] 标量查询仍走 `mapList()` / `ArrayList<HashMap>`，每行至少一次 Map 分配

- **现状**：`maxEntryId()`（`mysql/EvolutionDAO.cj:68-71`、`postgres/EvolutionDAO.cj:76-79`）、`knowledgeList()`（`mysql/EvolutionStateDAO.cj:67-73`）都只取单列/单值，却返回 `ArrayList<HashMap<String, Any>>`；`kindHas()`（`mysql/KindDAO.cj:26-36`）只用于 `isSome()` 却构造整行 Map；调用方再手写 `for(row in rows){ return … }` 或 `.isSome()`
- **方案**：这几处改成 `firstToMap()` + 标量 getter（`func maxEntryId(): Int64`、`func kindExists(kind): Bool`、`func knowledgeList(limit): ArrayList<String>`），与 `llm_conf` 的 `findById(): ?LLMConf` 保持同一风格
- **预期**：每轮演进省下 N 个 `HashMap` + N 个 `Any` 装箱（N = 表行数 / 候选文档数），并去掉调用方的 match 兜底；量化需 heap 采样
- **代价**：DAO 签名变更，调用方（`store/{mysql,postgres}/EvolutionStore.cj`、`EvolutionStateStore.cj`、`KindPersistence.cj`）同步改；`knowledgeList` 返回 `ArrayList<String>` 后 call site 少一层取列
- **验证**：`getAllocatedHeapSize()` 在一轮「演进状态读取 + 知识去重」中的分配量对比；RSS 稳态对比
- **证据状态**：`无基线（待验证，不进 tasks）`

### [CPU] `llm_skill_evolution_knowledge` 按 `processed_at` 排序但该列无索引

- **现状**：`knowledgeList` 是 `ORDER BY processed_at DESC LIMIT n`（`mysql/EvolutionStateDAO.cj:67-73`、`postgres/EvolutionStateDAO.cj:76-82`），而建表只有 `doc_id` 主键（`mysql/EvolutionStateDAO.cj:57-65`、`postgres/EvolutionStateDAO.cj:66-74`），无 `processed_at` 索引 ⇒ 每轮演进都对整表全扫 + filesort，代价随「已消费知识量」单调增长（该表只增不减，注释明确写了「只增不减」）
- **方案**：建表语句补 `KEY idx_evo_knowledge_time (processed_at)` / `CREATE INDEX IF NOT EXISTS`，与 #10 的索引补建入口一并做
- **预期**：`knowledgeList` 从「全表扫」降为「索引倒序取 n 行」；具体耗时需实测
- **代价**：写入侧多维护一个索引（`knowledgeInsert` 频率 = 每轮新知识条数，很低）
- **验证**：`EXPLAIN` 前后对比 + `cjprof` 中 `knowledgeList` 调用点耗时；表行数 10k / 100k 两档
- **证据状态**：`无基线（待验证，不进 tasks）`

<!-- 第 10 部分 -->

> 不是缺陷，是"还能更好"。本部分没有任何 `cjprof` / `cjpm bench` 数据，三条一律 `无基线（待验证）`，不进 `tasks.md`。

### [堆内存] 去掉 `HttpEmbedder` 的跨调用缓存，改为「一次写入一次解析」

- **现状**：`HttpEmbedder.cachedResponse` 持有一整份 `EmbeddingResponse`：`dense` 1024×8B ≈ 8KB；`colbert` 为 N×1024×8B（8192 token 时约 64MB）；`sparse` N 项。生命周期 = 从最后一次调用到下一次不同文本进来（进程级单例，可能长期常驻）。
- **方案**：让写入方在一次写入内调一次 `resolve(text): EmbeddingResponse`，再从同一对象取 dense / colbert / sparse；`Embedder` 三方法保留兼容，默认实现不再跨调用缓存。退一步：缓存只留 `dense` + `sparse`，`colbert` 用完即弃。
- **预期**：常驻堆从「最坏 64MB + JSON 原文」降到 0（无缓存），同时消除严重 #1 的共享可变状态。
- **代价**：调用方需改成一次取值（可在 `Embedder` 加默认方法保持兼容）；若上游确实分三次、每次不同文本，会重新变成 3 次 HTTP（当前缓存在这种情况下也不命中）。
- **验证**：记忆写入压测（8k token 长文本 × 并发 8），改前/改后 `getUsedHeapSize()` 与 RSS 峰值 + HTTP 调用计数，`-O2` 同环境取中位数。
- **证据状态**：`无基线（待验证，不进 tasks）`

### [CPU] JSON 分量转换从 `toString() + Float64.parse` 改为数值直取

- **现状**：`BgeM3Codec.floatsOf`（`BgeM3Transport.cj:144-147`）对每个分量做 `toString()`（分配一个临时 `String`）再 `Float64.parse`；一次请求 = 1024（dense）+ N×1024（colbert）个临时串，8k token 约 840 万个。`Embedding.parse`（`Embedding.cj:144-151`）同型，1024 次 `parse` 外还叠了 `try/catch`。
- **方案**：改用 `f_data` 的数值直取（`JsonValue` 的 decimal/int 取值接口，落地前用 `cangjie-doc-lookup` 核对签名），避免字符串往返；`Embedding.parse` 同时用 `ArrayList` 预容量或直接 `Array` 避免 `toArray()` 的第二次分配。
- **预期**：单次请求临时分配减少约 2 个对象/分量，GC 压力与 CPU 同步下降；幅度取决于数值转换本身开销。
- **代价**：`Decimal → Float64` 不是零成本，极端情况下可能持平；需覆盖 `1e-3`、`0.1` 等格式的精度一致性用例。
- **验证**：`cjpm bench -O2` 对照 `BgeM3Codec.parse`（固定 fixture 1024 + 32×1024），取中位数与 P95；`cjprof` 看 `toStr`/`parseFloat` 自耗时占比。
- **证据状态**：`无基线（待验证，不进 tasks）`

### [CPU / 延迟] 每次 `postOnce` 新建 `HttpClient`，连接与 TLS 握手无法复用

- **现状**：`postOnce` 每次 `HttpClient(url)`（`BgeM3Transport.cj:87`），`resource` 结束即关闭（`:93-99`）；`f_httpclient` 的 `send` 每次 `builder.build()`（`httpclient.cj:133-137`）。不同文本、不同线程之间不共享连接。
- **方案**：`BgeM3Transport` 持有一个长生命周期 `HttpClient`（连接池，`poolSize` 可配），请求间复用，关闭交给容器 / `close()`。
- **预期**：省掉每请求 TCP 建连（回环开销小）与 TLS 握手（https 时通常毫秒级），对 3s 超时下的 P99 可能有改善；占比需分段计时。
- **代价**：`HttpClient` 当前实现把 `request` / `client` 当实例可变字段（`httpclient.cj:37-39/133-137`），**看起来不可并发共享**——采用前要么先给 `f_httpclient` 加线程安全契约，要么改成每线程一份（ThreadLocal 需清理，见 `mem §8.2`），属跨模块改动。
- **验证**：分段计时（构造 / `send` / `readEntire`）在单线程与并发 8 两组下跑 1000 次，取 P50/P95。
- **证据状态**：`无基线（待验证，不进 tasks）`

<!-- 第 11 部分 -->

> 不是缺陷，是「还能更好」。以下两条均**无改前基线**，只能作为下一轮补数据的候选，不进 `tasks.md`。

### [堆内存] 请求体三级物化：`toData()` → `JsonValue.from` → `toString()`

- **现状**：`ChatCompletionsMapper.build:37` 用 `JsonValue.from(params.toData())` 先把整份会话物化成 `DataObject` 树，再整棵转成 `JsonObject`；`LLM.cj:146` / `LLM.cj:235` 又 `body.toString()` 产出字符串。同一份会话在内存里同时存在 **3 份表示**（Data 树 / Json 树 / 字符串），大小与会话长度及内联 base64 图片（`addImage` 的 `data:` URI，单张常见 1-4 MB）线性相关。
- **方案**：照 `ResponsesMapper.messageToJson`（`ResponsesMapper.cj:183-205`）的做法逐条消息直接构造 `JsonObject`，跳过 `DataObject` 中间层；`tools` 同样直接产出 `JsonObject`（`ChatCompletionsMapper.cj:67-70` 现在是 `JsonValue.from(function.toData())`）。`rewriteMultimodal` 随之退化为「构造时直接产出 content parts」，不再需要「先序列化再改字段」——这也顺带解决 #6 的 content/parts 二选一（在构造点就能决定）。
- **预期**：峰值表示从 3 份降到 2 份（Json 树 + 字符串），base64 图片场景最明显；若 5 张 4 MB 图，粗略量级可从 ~60 MB 降到 ~40 MB（估算，非实测）。
- **代价**：`build` 要手工覆盖 `LLMParams` 的全部字段（`model` / `messages` / `temperature` / `max_tokens` / `response_format` / `thinking`），漏字段会静默丢参数；必须配「报文字段快照」用例（现有 8 个 build 用例只断言了部分字段）。`DataAssist` 的 `@FieldAlias`（如 `finish_reason`）也要手工对齐。
- **验证**：会话 200 条 + 2 张 2 MB `data:` 图，`getAllocatedHeapSize()` 与进程 RSS 峰值前后对照；`-O2`，10 轮取中位数与离散程度。
- **证据状态**：`无基线（待验证，不进 tasks）`

### [CPU] `build` 在候选循环内重复序列化同一份会话

- **现状**：`LLM.cj:133-140` 与 `LLM.cj:217-223` 都是「每个候选调一次 `build`」。报文里与候选相关的只有 `model`（`ChatCompletionsMapper.cj:38`）和 `temperature`（`:40-49`），`messages` 占报文体积的绝大部分；N 个候选全失败时同一份会话被序列化 N 次，每次都带 `toString()`。成功命中首个候选时无额外开销。
- **方案**：把「与会话相关、与候选无关」的部分（`messages` + `tools` + `thinking` + `response_format`）先序列化成不可变模板，循环内只浅拷贝顶层 `JsonObject` 再覆写 `model` / `temperature`；或先 `build` 一次，循环内改 `model` 字段。
- **预期**：多候选失败转移路径上序列化次数从 N 降到 1；只影响失败转移，属长尾改善。
- **代价**：`dialect.decorate`（`LLM.cj:140`）与 `ThinkingPolicy.apply`（`:142`）会**就地改写** `body`，共享同一 `JsonObject` 会被前一候选的方言字段污染 ⇒ 必须保证每次拿到独立副本；浅拷贝不成立时收益会被拷贝成本抵消，需实测判断。
- **验证**：3 个候选全返 500 的场景，在 `build` 前后与 `toString` 前后分段计时，10 轮中位数；`cjprof record` 看 `build` / `toData` 自耗时占比。
- **证据状态**：`无基线（待验证，不进 tasks）`

<!-- 第 12 部分 -->

### [CPU] 把 `balancers` 与版本判断前移到快照发布时

- **现状**：每次 `peekNext`（即每次 `chatByName/respondByName`）都要进 `balancerFor`（`LLMConfsHolder.cj:189-222`）拿 `balancerMutex`，做一次 `balancersVersion != snapshot.version` 判断和一次 `HashMap<String, …>` 查找；同一次请求里 `LLM.callByName` 还会再遍历一次 `holder.candidates()` 并逐个 `breaker.isOpen`（各自一把锁）。所有 llmName 的所有请求共用这一把 `balancerMutex`。
- **方案**：把 `balancers` 做成快照的一部分——`refresh` 成功时（已在写路径）为每个 llmName 预建 `LoadBalance`，随 `LLMConfsSnapshot` 一起原子发布；`peekNext` 只读快照，读路径零锁。
- **预期**：省掉每请求一次全局锁（临界区含一次 `HashMap` 查 + 一次 `candidates()` 复制的比较），把选择逻辑从「多线程串行点」变成纯读；具体降幅未知。
- **代价**：`RoundRobin` 的游标改为挂在快照上（版本切换即重置游标，需要确认可接受）；刷新时多一次 O(conf 数) 的 balancer 构建。
- **验证**：`cjpm bench -O2` 对比 `peekNext` 在 1/8/32 线程下的吞吐与 p99；`cjprof` 看 `balancerFor` 与 `Mutex` 等待占比。
- **证据状态**：`无基线（待验证，不进 tasks）`

### [堆内存] 候选列表每次调用都整份复制

- **现状**：`LLMConfsSnapshot.candidates(llmName)`（`:49-57`）与 `all()`（`:59-67`）每次都新建 `ArrayList` 并逐条 `add`；单次 `chatByName` 会调用 `holder.candidates()`（`LLM.cj:101`）+ `snapshot.candidates()`（`peekNext` 里为取 `count`，`:171`）两次；`Embedding.embed`、`WebSearchFunction` 等也走同一入口。列表元素是 `LLMConf` 引用，复制成本是 N 个引用 + 两次数组分配。
- **方案**：快照里按 llmName 预先存好「已过滤 `weight>0`」的不可变列表（`Array<LLMConf>` 或只读 `ArrayList`），`candidates()` 直接返回该引用；`peekNext` 用 `list.size` 而不是复制。
- **预期**：每请求少 2 次 O(N) 复制与 2 次容器分配（N = 该 llmName 的 conf 数，通常 1-5），减少的是短命小对象，对 GC 压力的贡献需实测确认。
- **代价**：返回值不再是可以安全 `add/remove` 的副本，调用方若有原地修改会破坏快照（当前 3 个调用点都是只读，需逐个确认）。
- **验证**：稳态负载下 `getAllocatedHeapSize()` 速率与 GC 次数前后对照，`-O2`、同输入同并发。
- **证据状态**：`无基线（待验证，不进 tasks）`

### [堆内存] `result()` 为估算 token 先把两段正文拼成新串

- **现状**：`ChatStreamAccumulator.result()`（`ChatStreamAccumulator.cj:165`）执行 `content.toString() + reasoning.toString()`，在流结束时产生 2 个 `String` + 1 个拼接串，大小约等于本次输出字节数（`max_tokens` 默认 65536，实际几百字节到几十 KB）；这三个临时串只用于取 `.size`
- **方案**：给 `estimateTokens` 增加按字节数的重载（`estimateTokensOfBytes(bytes: Int64)`）；`feed` 里对 `append` 的片段累加字节数，`result()` 直接用累计值，零拷贝
- **预期**：每次流式请求少 2～3 份 N 字节临时对象（按 4KB 输出约 12KB 瞬时分配）
- **代价**：`ChatStreamAccumulator` 多一个 `Int64` 计数；`estimateTokens` 保留原签名供 `TokenCounter` 复用
- **验证**：同一 SSE 回放脚本跑 1000 次，`getAllocatedHeapSize()` 差值与峰值 RSS 对照（`mem §1.2`）
- **证据状态**：`无基线（待验证）`

### [CPU] 每次请求两次取全局锁拿 transport

- **现状**：`LLM.getTransport()` / `getStreamTransport()`（`LLM.cj:49-66`）每次调用 `synchronized(mutex)`，`nextRequestId()`（`LLM.cj:295-300`）共用同一把锁；单次持有极短（读字段 / 自增），高 QPS 下是纯竞争点
- **方案**：transport 改为 `AtomicReference`（仅测试注入时替换，读路径无锁）；`counter` 改 `AtomicInt64`
- **预期**：每请求少 2～3 次互斥进入；消除唯一跨请求的共享锁
- **代价**：依赖 `std.sync` 原子类型；`setTransport` 语义从「锁内替换」变成「原子替换」（对本场景等价）
- **验证**：200 并发 × 60s 压测，线程状态采样看 BLOCKED 次数与 P99（锁竞争在 CPU profile 里看不到，需线程状态证据）
- **证据状态**：`无基线（待验证）`

<!-- 第 13 部分 -->

### [CPU] 复用 HTTP 客户端（连接池）替代"每请求一次 TCP+TLS 握手"

- **现状**：`DefaultHttpTransport.post`（`f_llm/src/llm/LLMTransport.cj:41`）与 `DefaultStreamTransport.stream`（`LLMStreamTransport.cj:43`）每次调用都 `new HttpClient(url)`，且 `HttpClient.send` 内部每次都 `builder.build()`（`f_httpclient/src/httpclient.cj:133-137`），`close()` 后不可再用 —— 结构上无法复用连接。对 https 端点即"每次 LLM 调用 = 一次 TCP 三次握手 + 一次 TLS 握手"；`LLM.call` 在候选间 failover 时还会再来一次
- **方案**：以 `baseUrl + 鉴权头` 为 key 缓存 `Client`（stdx `Client` 自带连接池），或用 `ClientBuilder.poolSize` 建长驻实例；`LLMHttpResponse` 只保留状态码+body，客户端生命周期上移到 `LLM` 或 transport 的单例
- **预期**：未实测。按"每次省一次 RTT+TLS 握手"估算，单次 chat 调用的固定开销可下降一个握手量级；对短请求（余额查询、`/models`）收益占比更大
- **代价**：需要处理连接失效重试、dns 变更、`close()` 生命周期；`TlsClientConfig` 变成共享对象后不能再按请求改（与严重第 1 条的可配置化要一起设计）
- **验证**：`cjprof record`（看 TLS/socket 相关栈占比）+ 分段计时（connect 完成 / 首字节 / 结束）在 1/10/50 并发下前后对照，`-O2`，中位数与 P95
- **证据状态**：`无基线（待验证，不进 tasks）`

### [堆内存] `RemoteTokenCounter` 为一次计数把整段会话拼成两份全量字符串

- **现状**：`TokenCounter.cj:66-75`：先把全部 `message.content` 追加进一个 `StringBuilder`，再 `prompt.toString()`（第 1 份完整副本），随后作为 `body.add('prompt', …)` 的值进入 `JsonObject` 序列化（第 2 份，`body.toString()`），最后 `response.readEntire()` 再物化响应体。生命周期只有一次 HTTP 往返，但峰值是"prompt × 2 + 响应"
- **方案**：①按 `llm_toolResultMaxBytes` 同口径给 remote 计数输入设上限（超限直接返回 -1，让调用方退回 heuristic）；②或改为"只对有阈值的头部/尾部消息计数"，不必拼全量
- **预期**：未实测。上限落地后单次峰值从 O(全部消息) 降到 O(上限常量)，具体字节量取决于真实会话长度
- **代价**：估算语义变化（截断后计数偏小），需要与 `saturated` 的 0.9 裕度一起调；`RemoteTokenCounter` 目前只有测试调用，收益仅在未来接入时体现
- **验证**：`getAllocatedHeapSize()` + RSS 在 100 条/400 条工具结果的会话下前后对照，同时断言 `count` 返回值不变（未超限时）
- **证据状态**：`无基线（待验证，不进 tasks）`

<!-- 第 14 部分 -->

### [CPU] `FStoreLoomStore.list` 每页重扫全量索引 + 逐条 6 次 `get`，`restore()` 因此是 O(页数 × N)

- **现状**：`list(offset, limit)`（`FStoreLoomStore.cj:93-113`）每次调用都 `store.prefix(INDEX)` 遍历**全部**流程名 → `sortNames`（插入排序，O(N²) 最坏）→ 再对页内每条 `get()`（`get` 内部 6 次 `store.get`：header + description + planJson + flowSource + questionsJson + stepSources）。`LoomRegistry.restore()`（`LoomRegistry.cj:241-266`）以 100 条一页循环调用，N 条流程共 N/100 页，每页一次全量前缀扫描 → 启动期约 N²/100 次键比较 + N 次 6 键读
- **方案**：`list` 改为接受迭代器续读（把 `store.prefix` 的迭代状态提到调用方），或在 `restore` 里一次性 `prefix` 遍历并流式 `get`，去掉 `offset` 重复扫描；`sortNames` 换 `ArrayList.sort`（若 std 提供稳定排序）或改为按索引键的字典序天然有序（f_store 前缀迭代是否有序需先验证）
- **预期**：启动恢复从 O(N²) 降到 O(N) 次键比较 + O(N) 次 `get`；N=1000 时只省启动期，稳态无影响
- **代价**：`LoomStore` 接口变更（`list` 语义）会波及 `MemoryLoomStore` / `SqlLoomStore` / `PostgresLoomStore` / `MySqlLoomStore` 四个实现；SQL 侧本来有 `LIMIT/OFFSET`，需要保留分页形态
- **验证**：`cjpm bench -O2`，构造 N=100/1000/5000 条 loom 流程的 f_store 目录，测 `LoomBootstrap.startup` 端到端耗时（中位数 + P95，各 10 轮）
- **证据状态**：`无基线（待验证，不进 tasks）`

### [CPU] `CodeGen.flowSource` 在循环里对整串 `+=`，源码生成是 O(步数²) 的字节拷贝

- **现状**：`CodeGen.cj:100-131` 与 `:102-104`、`:111-126` 两组循环都用 `text += '…'` 累积；每步约 200~400 字节源码，第 i 步要复制前 i 步的全部内容。步数 n 时累计拷贝 ≈ n²·len/2。`plan.validate()`（`Plan.cj:94-141`）没有任何步数上限，n 只受模型输出长度约束
- **方案**：改 `StringBuilder`（同仓 `LoomHostApi.render` 已是这个写法，`:89-141`）一次性 `toString()`；或在 `generate` 里预分配 `StringBuilder(capacity: steps.size * 256)`
- **预期**：生成期从 O(n²) 降到 O(n) 字节拷贝；n=200 时拷贝量降两个数量级（按上式估算，未实测）
- **代价**：无（输出字符串完全一致，可用现有 `CodeGen_test` 做等价性回归）
- **验证**：`cjpm bench -O2` 构造 n=20/100/500 步的计划，测 `CodeGen.generate` 耗时；同时断言 `flowSource` 字节级不变
- **证据状态**：`无基线（待验证，不进 tasks）`

<!-- 第 15 部分 -->

> 都不是缺陷，是"还能更好"。全部缺改前基线，故一律 `无基线（待验证）`，不进 `tasks.md`。

### [CPU] 复用 `confirmFlow` 编译出的步骤闭包，避免 `executeNow` 二次 parse + 二次 JIT

- **现状**：`confirmFlow`（`f_llm/src/loom/LoomService.cj:106-119`）调 `compiler.compileSteps(target)` 后**丢弃返回值**，只把状态标成 `compiled`；`executeNow`（`:122-141`）重新 `Planner.parse(flow.planJson)` + `LoomRunner.run`（`LoomRunner.cj:126` 再 `compileSteps`）。"确认 + 立即执行"这条主链路（`LoomFunctions.cj:123-133`）每次执行都要重新解析计划并重新编译全部步骤。
- **方案**：`LoomService` 持有 `HashMap<String, (planJsonHash, HashMap<String, (Event)->Event>)>` 缓存（键 = `flow.name` + `planJson` 的内容哈希），`confirmFlow` 填入、`executeNow` 命中则走 `runCompiled`（`LoomRunner.cj:131` 已支持），`delete` 时清除；缓存容量与 `LoomRegistry` 同步有界。
- **预期**：省掉每次执行的一次 JSON 解析 + N 次 JIT 编译；收益取决于编译耗时占端到端比例（未测，不给百分比）。
- **代价**：缓存与源码一致性风险（`LoomRegistry` 的 KDoc 明确说"不缓存编译产物——`JitFunction` 与源码可能不一致"，因此必须按内容校验而不是只按 name）；内存随流程数增长，必须与 #12 的上限一起做。
- **验证**：`cjprof record` 跑 5 步流程 × 100 次（host 用 `RunnerHost`，不调真实模型），对比 `run` 与 `runCompiled` 的 self time；`cjpm bench -O2` 给中位数与离散度。
- **证据状态**：`无基线（待验证）`

### [CPU] 拓扑排序与注册表列举的 O(n²) 结构

- **现状**：`LoomRunner.topologicalOrder`（`LoomRunner.cj:526-563`）用 `ready.remove(at: 0)` 当队列，每步 O(n) 搬移；`MemoryLoomStore.list`（`LoomRegistry.cj:116-134`）与 `LoomRegistry.compiledFlows`（`:219-238`）每次调用都先全量收集名字再插入排序（`sortNames`，`:147-157`，O(n²)）。
- **方案**：`ready` 换成索引游标（`var head = 0`，`while (head < ready.size)`）或双端队列；列举改为维护有序结构（若 std 提供 `TreeMap`）或只在 `restore` 时排序、运行期保持插入序。
- **预期**：排序从 O(n²) 降到 O(n log n)（或 O(n)）；只在流程/步骤规模大时有意义（10 步以下可忽略）。
- **代价**：`MemoryLoomStore` 是测试 / `llm_loomPersist=false` 用的内存实现，收益仅限该路径；换有序结构需确认当前 SDK 的 std 支持与迭代语义。
- **验证**：`cjpm bench -O2` 对 `topologicalOrder` 造 10 / 100 / 1000 步计划，取中位数；`list` 造 10 / 1000 / 10000 条。
- **证据状态**：`无基线（待验证）`

### [堆内存] 把 `values` 快照从"每次 render 全量拷贝"改成写时复制的不可变快照

- **现状**：`LoomHostApi.render`（`LoomHostApi.cj:73-145`）每次调用都在 `synchronized(mutex)` 里新建 `HashMap` 并逐条拷贝 `values`（步骤数 n 条），再在锁外替换。一个流程里 m 个模板步骤 ⇒ O(m×n) 次条目拷贝 + m 次 `HashMap` 分配。
- **方案**：`taskEvent` 写入时构造新的不可变快照（写入次数 = 步骤数），`render` 只做一次引用读取（整块原子替换），去掉锁内逐条拷贝；或用 `std.sync` 的原子引用（对引用类型的支持需按文档核对）。
- **预期**：`render` 的分配从 O(n) 降到 O(1)（引用），锁内只读一次引用；n 大时收益明显。
- **代价**：写入路径变成 O(n) 拷贝（步骤多时写放大），需要权衡读写比；快照生命周期仍受 #1 的静态量问题约束（必须先解决归属）。
- **验证**：`cjprof heap` 看 `render` 的分配量；50 步流程 × 100 轮对比 `getAllocatedHeapSize()` 与 RSS，同时测 `render` 的 P95。
- **证据状态**：`无基线（待验证）`

<!-- 第 16 部分 -->

> 不是缺陷，是「还能更好」。无基线数据，收益只能作为待验证假设。

### [CPU] `FlowPlan.jsonQuote` 每次转义做两次全量字节拷贝

- **现状**：`jsonQuote`（`Plan.cj:186-214`）先 `text.toArray()` 把整串复制成一份 `Array<Byte>`，逐字节判断后用 `ArrayList<Byte>` 累积（多次扩容复制），最后 `out.toArray()` + `String.fromUtf8(...)` 再复制一份。调用密度高：`FlowPlan.toJson` / `StepPlan.toJson`（每步骤 5-8 个字段）以及仓内 30+ 处手工拼 JSON（`LoomStoreGateway.cj`、`LoomService.cj`、`LoomMemoryPolicy.cj`、`LoomRunner.cj` 等）。
- **方案**：改成按索引扫描（`for (index in 0..text.size) { let ch = text[index] }`，`LoomHostApi.cj:92-101` 的 `render` 已用同一手法做单遍字节扫描），`out` 预分配 `text.size + 2`，省掉 `toArray()`。
- **预期**：单次转义少一份 `size` 字节临时数组（典型字段 20-200 字节），一个 5 步计划约 40 次转义 ⇒ 少约 40 次小分配；具体降幅未测。
- **代价**：无 API 变化；需确认 `String[index]` 的越界语义与 `toArray` 长度一致（`待确认`）。
- **验证**：`cjpm bench -O2`，对 `FlowPlan.toJson()` 跑 10 万次，同机对照改前 / 改后中位数与 P95，并记 `getAllocatedHeapSize()` 差值。
- **证据状态**：`无基线（待验证，不进 tasks）`

<!-- 第 17 部分 -->

### [堆内存] 方案 1：SkillCatalog 技能向量缓存按「标题#版本」只增不减

- **现状**：`private static var vectors: HashMap<String, Array<Float64>>`（`SkillCatalog.cj:51`），键 `'${skill.title}#${skill.version}'`（`233`），`writeVector`（`256-260`）只写不删。BGE-M3 1024 维 `Float64` 约 8KB/条；键数量随「技能数 × 历史版本数」增长，旧版本条目留到进程重启
- **方案**：写入前按 title 删旧版本键（同 title 只留最新 version），或改成 `HashMap<String, (Int64, Array<Float64>)>` 以 title 为键、版本做值内比较；再加条目上限做整体重建
- **预期**：稳态条目数从「技能数 × 历史版本数」降到「技能数」
- **代价**：需要一次 `keys()` 扫描或额外维护 title→key 索引；`install/reset`（`62-77`）已整体清空，语义不变
- **验证**：20 个技能各演进 50 次（桩 `chat`），对比 `getUsedHeapSize()` 稳态与 `vectors` 条目数
- **证据状态**：`无基线（待验证，不进 tasks）`

### [堆内存] 方案 2：每轮演进把最多 500 篇知识正文一次性物化，并二次复制进 materials

- **现状**：`knowledgeOf`（`SkillEvolutionJob.cj:318-358`）先取 `docIds`（默认 `limit=500`），再逐条 `knowledge.get` 取全文，全部正文组成 `ArrayList<ExperienceItem>`；`run` 又把 `freshKnowledge` 复制进 `materials`（`109-115`）。单篇长度无上限（写入方控制），峰值 = 500 × 平均长度
- **方案**：取素材改成按需流式（先取 docId + 长度，聚类时按需 `get`），或把 `limit` 降到簇上限并分页推进；至少去掉 `materials` 对 `freshKnowledge` 的整表复制（直接在 `freshSuccess` 上追加）
- **预期**：峰值与文档长度解耦为 O(簇大小)；单轮峰值从「全量正文」降到「单篇 + 簇内副本」
- **代价**：`SkillMatcher` 需要接受惰性素材（接口变更）；分页会让单轮样本变少
- **验证**：500 篇 × 4KB 与 500 篇 × 40KB 两组，测 `getAllocatedHeapSize()` 峰值、RSS 峰值、单轮耗时
- **证据状态**：`无基线（待验证，不进 tasks）`

### [CPU] 方案 3：聚类阶段对每对（经验, 簇首）各编码两次，簇首被反复重编码

- **现状**：`SkillMatcher.cj:176-191` 对 `leftovers` 逐条与每个 `leaders[index]` 比一次，`similarity`（`223-235`）每次把左右两侧都重新 `encodeSafely`；`SkillCandidate` 的分数（`195-196`）再算一次「首元素 vs 末元素」相似度
- **方案**：进入聚类前给每条 leftover 编码一次并缓存（与 `leftovers` 同下标的向量数组，或用一个可选值持有类型），簇首复用同一份向量；`SkillCandidate.score` 若无消费方则直接不算
- **预期**：编码调用从 O(Σ leaders × 2) 降到 O(n)（n = leftovers 条数），远程嵌入场景收益与 n 成正比
- **代价**：多一份与 `leftovers` 同长的向量数组（n × 8KB，n 有上限）；编码失败时的降级路径要保持现状
- **验证**：`encodeSafely` 加计数埋点，500 条未匹配经验 + 20 个技能，对比改动前后调用次数；`cjprof` 看 `SkillMatcher.assign` 自耗时
- **证据状态**：`无基线（待验证，不进 tasks）`

<!-- 第 18 部分 -->

> 不是缺陷，是"还能更好"。以下三条都没有改前基线，**均为待验证假设**，不进 `tasks.md`。

### [CPU] 关掉 `llm_makingMemory` 时跳过整个 `add` 路径

- **现状**：`Memory.add(session, all!)`（`f_llm/src/memory/Memory.cj:145-151`）每个事件 `spawn` 一次，循环内对每条消息调 `generateContent`（字符串模板 + `StringBuilder`，`ToolCallMessage` 还要遍历 `tool_calls`），默认配置下结果全部丢弃（`DummyMemory` 空实现）。
- **方案**：入口判 `LLMConfig.getMakingMemory()`（或 `FaithfulMemory` 暴露 `enabled`）后直接返回；同时把"每事件一个 `spawn`"改成有界 worker + 队列。
- **预期**：省掉每事件 1 次线程创建 + O(消息数) 次字符串拼装；具体降幅需 profile，无法先验给出。
- **代价**：`Memory.add` 从"永远异步"变成"配置关闭时同步返回"，语义无变化；worker 化引入队列上限与丢弃策略。
- **验证**：`cjprof record` 跑一段典型 agent 会话（N 事件 × M 消息），对照 `generateContent` 自耗时占比与线程创建次数（`/proc/<pid>/status` 的 `Threads` 峰值）；`cjpm bench -O2` 对照 `Memory.add` 单次耗时中位数。
- **证据状态**：`无基线（待验证，不进 tasks）`

### [CPU] `ToolCatalog` 每次检索重复小写化与 JSON 解析

- **现状**：`entries()`（`ToolCatalog.cj:47-53`）每次调用都对每个工具跑一遍 `descriptionOf`（4 层 `match` + `toData`/`asObject` 解析，`FunctionMediator.definition` 每次新建 `JsonObject`）；`search()`（`:62-67`）再对每条 `name`/`description` 各做一次 `toAsciiLower()`。`listTools`/`searchTools` 由模型调用触发，`topK` 只需 5 条却要全量解析。
- **方案**：在 `FunctionMediator` 注册时缓存 `(name, descriptionLower)`，`ToolCatalog` 只读缓存；`search` 先按缓存匹配再构造 `ToolEntry`。
- **预期**：单次检索的分配量与 CPU 从 O(工具数 × JSON) 降到 O(工具数) 字符串比较；工具数几十时绝对收益不大。
- **代价**：多一份常驻缓存（工具名 + 小写描述，量级 KB），注册路径要同步失效。
- **验证**：`cjpm bench -O2` 对 `ToolCatalog.search` 做 1k 次调用的中位数对照；同时确认 `FunctionMediator` 注册后不再变更（当前无 `unregister`，缓存不会失效，但 #8 的修复会引入）。
- **证据状态**：`无基线（待验证，不进 tasks）`

### [堆内存] 摘要输入按会话上限截断，避免整段会话一次拼进 prompt

- **现状**：`Memory.summarise`（`Memory.cj:56-65`）把 `messages` 全量拼成一个 `content` 字符串（每条消息 + `'---'` 分隔），再交给 `LLM.chatByName`；`messages` 由 `FaithfulMemoryImpl.summarise` 按 session 累积（`FaithfulMemory.cj:67,85`），无条数/字节上限。
- **方案**：给单次摘要设消息条数与字节上限（如末尾 N 条 / 64KB），超限时先分段摘要再合并；`FaithfulMemoryImpl` 侧改为按批 flush 而不是整段累积。
- **预期**：峰值内存与 LLM 请求体从"会话长度线性"变为常数上界；具体收益依赖真实会话长度分布。
- **代价**：分段摘要会损失跨段上下文，摘要质量需评估；实现复杂度上升。
- **验证**：构造 1k/10k 条消息的会话跑 `summarise`，对照 `getAllocatedHeapSize()` 峰值与 RSS，并人工比对摘要质量（分段 vs 全量）。
- **证据状态**：`无基线（待验证，不进 tasks）`

<!-- 第 19 部分 -->

> 不是缺陷，是“还能更好”。三条均无性能基线，只作为下一轮取数候选，**不进 `tasks.md`**。

### [堆内存] 搜索/抓取响应改为有界读取（与 #3 同源，这里量化“能省多少”）

- **现状**：`readEntire()` 一次物化整个响应体：命中 `Content-Length` 时 `Array<Byte>(size)` + `String.unsafeUtf8` 各一份；未命中时 `ArrayList<Byte>` 以 1KB 步进扩容（`f_httpclient/src/ExtendHttpResponse.cj:50-77`）。抓取单页时峰值 ≈ 2 × 响应体 + 解析后的 `content`；`needContent=true` 的搜索再多一份 JSON 树。生命周期：单次工具调用（秒级），但并发 8 个抓取即 8 份峰值叠加
- **方案**：`SearchPoster` 增加 `maxBytes` 参数，`readToEnd` 改为“读满上限即停并返回 `truncated`”；上限取 `LLMConfig.getFetchMaxBytes()`（已有配置项，`WebFetchFunction.cj:59`）+ 少量 JSON 余量
- **预期**：单次抓取峰值从 O(响应体) 降到 O(上限)（默认上限 20KB 量级）；具体降幅需实测
- **代价**：`SearchPoster` 是 `public type`（`:34`），签名属对外契约，需同步测试与调用方；截断后 JSON 可能不完整，解析前须判 `truncated`
- **验证**：同一组页面（1MB / 50MB / 500MB）改前改后对比 `getUsedHeapSize()` 峰值、RSS、单次耗时，各 30 轮取中位数
- **证据状态**：`无基线（待验证，不进 tasks）`

### [CPU] 复用 `HttpClient` / 连接，避免每次搜索都重新 TCP+TLS 握手

- **现状**：`defaultSearchPost` 每次调用 `HttpClient(url)` + `resource` 立即 `close()`（`DeepSeekSearchProvider.cj:37-49`），没有连接复用；一次 `webSearch` = 一次完整 TLS 握手（1~2 RTT）
- **方案**：provider 持有长生命周期 client（按 endpoint 缓存），或由 `f_httpclient` 提供按 baseUrl 的池；header 每次请求覆盖
- **预期**：省掉每次握手的 RTT 与 CPU（ECDHE/RSA 运算），P50 下降量待测
- **代价**：连接/池的生命周期与关闭责任转移；`HttpClient` 是否可被多线程并发复用需先查 stdx 文档（它持可变 `request` 字段，`f_httpclient/src/httpclient.cj:38`，直接共享可能不安全）——未确认前不要落地
- **验证**：同机同 endpoint 连续 200 次 search，改前/改后 P50/P95 与 `cjprof` 中 TLS 相关占比
- **证据状态**：`无基线（待验证，不进 tasks）`

### [CPU] `LLMConf.conf` 解析结果缓存（减少每请求的重复 JSON 解析与 HashMap 分配）

- **现状**：`conf` getter 每次 `LLMConfCodec.fromColumn(confJson)`：`trimAscii` + `JsonValue` 解析 + 新建 `HashMap`（`LLMConf.cj:73-78`、`LLMConfCodec.cj:35-45`）；`option/optionInt/optionBool/tokenThreshold/streamable` 每次调用各触发一次（`:93-130`）。一次请求链路上 `tokenThreshold`（`LLMConfsHolder.cj:135-146`）、`stream`（`LLMConf.cj:125-130`）、`chatPath` 等会被多处读取
- **方案**：装载完成后预解析一次并缓存（`private var cached: ?HashMap`，`setConf` 时置 `None`）；或直接把 `confJson` 换成 `HashMap` 字段、只在写库时序列化
- **预期**：每请求省 N 次小 JSON 解析（N = option 读取次数，静态可见 ≥3），分配量同降；绝对耗时待测
- **代价**：引入可变缓存字段，与 #16 的“快照只读”假设冲突，需保证只在装载期写；缓存后 `conf` 仍须返回副本或只读视图
- **验证**：`cjpm bench -O2` 跑“1 万次 candidates()+option 读取”改前改后中位数；`cjprof` 看 `fromColumn/JsonValue.fromStr` 自耗时占比
- **证据状态**：`无基线（待验证，不进 tasks）`

<!-- 第 20 部分 -->

### [CPU] 把 `FStoreLLMConfStore.repair()` 从构造函数里移出去

- **现状**：两个 `init`（`FStoreMetaStore.cj:40-46`、`:49-56`）都会 `repair()`（`:89`），而 `repair` 是"`store.prefix('f_llm:meta:conf:')` 全量扫 + 每条一次 `store.get(indexKey)` + 缺失时 `store.add"（`:143-161`）。构造点不唯一：`MetaStoreAdapter.cj:39`、`StoreWiring.cj:67`，以及 `Stores.meta()` 每次工厂调用（`Stores.cj:92`）——`SkillCatalog` 每次检索就新建一个（`SkillCatalog.cj:193`）。
- **方案**：`repair` 改为显式的一次性维护入口（`MetaStores.bootstrap()`），构造只做"打开 + 读配置"；若必须兜底，改成"只在 `SEQ` 键缺失时扫一次"。
- **预期**：把每次构造的 O(配置数) 次 IO 降为 0；构造次数按 `SkillCatalog` 调用频次线性下降。定量收益需要 profile。
- **代价**：启动流程多一个"必须显式调用"的约定（需要在 `StoreWiring.wire()` 里接上，`doc/known-limitations.md` 补一句）。
- **验证**：`cjprof record` 跑"N 次 `SkillCatalog` 检索 + M 次工具调用"，对比 `repair` 的 self time 与 `store.prefix` 调用次数；同时用 `strace -c` 看 `get` 系统调用数。
- **证据状态**：`无基线（待验证，不进 tasks）`

### [CPU] `InMemoryEvolutionStore.list` 的锁内 O(n²) 排序

- **现状**：每次 `list` 全量拷贝 + 手写插入排序（`EvolutionStore.cj:94-106`），全程持 `mutex`；`bySkill` 还会再触发一次（`:120`）；条目数 N 增长后单次调用是 O(N²)，且阻塞同实例的其他读写。
- **方案**：`save` 时维护按 `(at, id)` 的有序结构（或在 `list` 里用 `std.sort` 的 O(N log N)），锁内只做"取窗口 + 拷贝"，排序在锁外。
- **预期**：单次 `list` 从 O(N²) 降到 O(N log N)，锁持有时间同阶下降。N=10⁴ 时理论差两个数量级，但缺实测。
- **代价**：`save` 多一次有序插入（O(N) 或 O(log N)），只影响内存实现。
- **验证**：`cjpm bench -O2` 对 `list` / `bySkill` 各跑 N = 10²/10³/10⁴ 三档，给中位数与 P95；同进程 `Mutex` 等待时间用分段计时。
- **证据状态**：`无基线（待验证，不进 tasks）`

### [堆内存] `KnowledgeChunker.split` 的全量 rune 展开

- **现状**：`splitImpl` 先 `countRunes` 再 `ArrayList<Rune>(total)` 逐 rune 展开（`KnowledgeChunker.cj:72-85`），峰值 ≈ `4 × 内容字节数`（`ArrayList<Rune>` 元素 4 字节 + 扩容余量），**与内容长度线性、无上限**；local 档只在 `content.size <= 2 MiB` 时生效（`:25-31`），更大文档全走堆。调用方 `InMemoryKnowledgeStore.upsert`（`InMemoryStores.cj:201`）与各 SQL 仓储都不限制正文长度。
- **方案**：不预展开全文 —— 用 `content.runes()` 的迭代器 + 环形窗口（`overlap` 个 rune）逐块产出，峰值降到 `O(maxChars)`；需要保留 local 档时把环形缓冲放进 local region。
- **预期**：峰值从 `4 × size` 降到 `4 × (maxChars + overlap)`（默认 1 800 B）；对 100 MiB 文档是 400 MB → 常数级。缺实测。
- **代价**：`runes()` 迭代器只能顺序走，切块逻辑要从"按下标取"改成"滑动缓冲"，`appendChunksLocal`/`appendChunksHeap` 两档都要改；`-O0` 下 local region 的临时对象行为已在注释 `89-99` 里踩过坑，需重新验证。
- **验证**：`getAllocatedHeapSize()` 前后差 + `getUsedHeapSize()` 峰值，输入 1/10/100 MiB 各 20 轮取中位数；与现实现同输入比对块内容逐字节相等。
- **证据状态**：`无基线（待验证，不进 tasks）`

### [堆内存] evolution 表的 f_store 索引键没有保留策略

- **现状**：每条 `EvolutionEntry` 写 3 个键（`DATA` / `IDX` / `TIME`，`EvolutionStore.cj:192-198`），永不删除；`pad(at, 20) + pad(id, 20)` 让键长约 60+ 字节。一天一条/技能的写入速率下增长很慢，但 `list` / `bySkill` 每次都要 `store.prefix` 扫全量键再逐个 `get`（`:205-238`），读放大随历史线性增长。
- **方案**：加保留策略（按 `TIME` 键滚动删除超过 N 天/ N 条的记录，三个键同步删），或把 `list` 改成"从最大键往前取 limit 个"的有界反向游标（`prefix` 迭代器是否支持反向需先查 API）。
- **预期**：读放大从 O(全表) 降到 O(limit)。
- **代价**：删除逻辑要保证 `DATA` / `IDX` / `TIME` 三键一致（当前没有事务），需要"先删索引再删主体"的顺序约定 + 崩溃恢复思路。
- **验证**：写入 10⁵ 条后测 `list(0,20)` / `bySkill(x,20)` 的耗时与 `prefix` 扫描条数（加计数埋点）。
- **证据状态**：`无基线（待验证，不进 tasks）`

<!-- 第 21 部分 -->

> 本部分**没有** bench / profile / 分配量基线数据（`scope.md` 的「已有性能资料」只有 `docs/LocalMode*.md`，不含本模块实测），因此按取证要求不列具体方案与收益，候选全部落到「待验证假设」。堆内存 / CPU 方案数记 0 / 0。
> v1.1 复核又识别出两个候选（`search` 的两轮选择排序合并、重建的批量大小取舍），同样无改前基线，写入假设 6 / 7，不在此处列收益（容器合并的候选已由假设 1 覆盖）。

<!-- 第 22 部分 -->

> 不是缺陷，是「还能更好」。以下全部**无改前基线**，因此只作方案登记，不进修复清单。

### [堆内存] `HttpTransport.esc()` 的三次字符串/字节复制

- **现状**：每次拼 param 都对每个字符串做 `text.toArray()`（1 份 `Array<Byte>`）→ `ArrayList<Byte>`（扩容多次）→ `out.toArray()`（再 1 份）→ `String.fromUtf8`（再 1 份）；一条记忆的 payload 含标题+正文+时间+namespace，`upsert` 里还会对 `collection`/`id` 各做一次，单次写请求产生 4 份以上等价字节。
- **方案**：改用 `StringBuilder` 逐字符/逐字节追加（`std` 的 `StringBuilder` 语义先用 `cangjie-doc-lookup` 核对），只对 `<0x20` 与 `"`/`\` 分支处理，避免 `toArray()`。
- **预期**：单次请求的临时字节对象从 3~4 份降到 1 份；峰值内存收益与 payload 长度成正比。
- **代价**：需逐字节比较 UTF-8 序列，代码比现在长；正确性风险集中在多字节字符边界（现有注释已说明这个坑）。
- **验证**：`getAllocatedHeapSize()` 前后对照 + 10k 次 upsert（payload 1KB/10KB 两档）+ RSS。
- **证据状态**：`无基线（待验证，不进 tasks）`

### [CPU] 复用 `HttpClient` 而不是每次 RPC 新建

- **现状**：`call()`（`HttpTransport.cj:193-219`）每次调用 `HttpClient(url)` + 三个 `header` + `tlsConfig`，用完 `resource(client)` 关闭；`upsert`/`get`/`search*`/`ids*` 每个都是一次 `call`，检索路径是 N+1 次 `call`。
- **方案**：把 client 提升为 `HttpTransport` 的 `private let`（构造期建一次，随 transport 生命周期），或按 URL 做进程级缓存；`HttpTransport` 已是长生命周期对象（`HydraContentStore` 持有）。
- **预期**：省掉每次 RPC 的建连/TLS 握手与对象构造；对 20 次往返的检索收益明显。
- **代价**：`HttpClient` 是否线程安全、是否能跨请求复用需先查 `f_httpclient` 文档；单例 client 需要处理连接失效重连。
- **验证**：`cjprof record` 对 `hydra.search` 场景（候选 20、10k 次循环）取 self time 占比，改前/改后同机同输入。
- **证据状态**：`无基线（待验证，不进 tasks）`

### [CPU] `HydraKnowledgeStore.search` 的选择排序与逐候选 `get`

- **现状**：`ContentStore.cj:176-195` 对 `ranked`（dense 200 + sparse 200，去重后 ≤400）做完整选择排序 O(n²)（160k 次 `HashMap.get`），只为取前 `limit*4`；`:204-226` 再对候选逐条 `transport.get` 取正文。
- **方案**：改为「一次遍历维护大小为 `bound` 的最小堆」；正文读取按 `bound` 批量（若 fhydra 提供 `hydra.getBatch` 则一次往返，否则至少把 `bound` 收紧到 `limit*2` 并记录命中率）。
- **预期**：排序比较次数从 ~160k 降到 ~400·log(20)；远程往返从 `limit*4` 降到可配。
- **代价**：堆实现代码量增加，需要等价性用例（分数相同时候选顺序、`docIds` 过滤后的填充率）。
- **验证**：`cjpm bench` 同输入（400 候选、limit=5），中位数 + P95 对照。
- **证据状态**：`无基线（待验证，不进 tasks）`

### [CPU] `nextId()` 的双 RPC → 本地区间缓存

- **现状**：每次 `upsert` 至少 3 次 `transport` 调用：`get(seq)` + `upsert(seq)` + 记录写 + `map` 写（远程 4 次往返）。id 只是单调计数，业务不要求连续。
- **方案**：一次 `get` 后本地预取 `[N+1, N+K]`（把 `seq+K` 写回），进程内用 `Atomic` 分配区间；`K` 可配（默认 64），进程重启浪费至多 K 个 id。
- **预期**：写路径远程往返从 4 次降到 3 次（摊薄后接近 2 次）。
- **代价**：id 不连续、进程崩溃浪费区间；跨进程仍不唯一（不能替代上文的互斥/CAS 修复）。
- **验证**：写路径分段计时（`seq` 读取 / 记录写 / map 写 三段），1k 次 upsert。
- **证据状态**：`无基线（待验证，不进 tasks）`

<!-- 第 23 部分 -->

### [CPU] `vectorLiteral` 在循环里做字符串拼接，1024 维是 O(n²)

- **现状**：`f_llm/src/store/mysql/MemoryRepository.cj:215-225`、`f_llm/src/store/postgres/MemoryRepository.cj:188-198`，`text += '${vector[index]}'` 逐元素拼接；每次 `upsert` 调 2 次、每次 `searchDense` 调 1 次，向量维度 1024（`Fixed1024Embedder`、`llm_memory_vector vector(1024)`）⇒ 每次约 1024 次 string realloc，累计复制量约 O(1024²/2) 字符。
- **方案**：`StringBuilder` + `append` 序列化（`StringBuilder.append(Float64)` 仍会转串，但避免每步整体复制）；或两方言共用 `VectorMath.literal`（已存在同功能实现，`f_llm/src/store/VectorMath.cj`）。
- **预期**：单次字面量构造从 O(n²) 降到 O(n)，减少约 1000 次中间串分配；对 `upsert` 端到端的影响取决于嵌入耗时占比（大概率 <5%）。
- **代价**：无语义变化；需回归「浮点格式与 `myvector_construct` / `::vector` 可解析」的用例（现有集成测试已覆盖）。
- **验证**：`cjpm bench` 或用例级分段计时，同 1024 维输入各跑 200 次取中位数；对照 `cjprof record` 中 `vectorLiteral` 的自耗时占比。
- **证据状态**：`无基线（待验证，不进 tasks）`

### [CPU] `markKnowledge` 在持锁状态下逐条 `INSERT`

- **现状**：`f_llm/src/store/mysql/EvolutionStateStore.cj:95-105`、`f_llm/src/store/postgres/EvolutionStateStore.cj:100-110` —— 对 `docIds` 每个元素一次 `knowledgeInsert`（MySQL `INSERT IGNORE`、PG 见 `dao/postgres/EvolutionStateDAO.cj`），全部在 `synchronized(mutex)` 内；单轮 `usedKnowledge` 量级等于本轮新消费的知识数（`SkillEvolutionJob.cj:203`）。
- **方案**：改成单条多值 `INSERT ... VALUES (...),(...)` 或 JDBC batch；`insert` 前先按 `docId` 去重并在应用侧截断空串（现在每条都判 `isEmpty`）。
- **预期**：N 次网络往返 → 1 次，持锁时间同比缩短；N=50 时约省 49 次往返。
- **代价**：多值 INSERT 的 SQL 长度上限（MySQL `max_allowed_packet`）——按 500 条 × ~80 字节分片，例如每批 200 条。
- **验证**：`cjpm bench`（或 `EvolutionStoreIT_test` 场景）同 N 下中位数对比；同时记录 `synchronized` 临界区耗时。
- **证据状态**：`无基线（待验证，不进 tasks）`

### [CPU] 分页循环内反复 `dao<>('mysql')` 查找

- **现状**：`f_llm/src/store/mysql/KnowledgeStore.cj:123` 与 `f_llm/src/store/postgres/KnowledgeStore.cj:122` —— `while` 每翻一页都重新 `dao<…DAO>('driver')`（宏生成方法内部再取 `executor`，而 `executor` 走 `ThreadLocal` 查表，见 `f_orm/src/base/SqlExecutor.cj:44-45`）；`upsert` 只取一次（`mysql/KnowledgeStore.cj:66`），说明写法本可以统一。
- **方案**：循环外取一次 DAO 存局部变量（与 `upsert` 一致）。
- **预期**：每页省 1 次注册表 + 1 次 ThreadLocal 查找；页数 = `maxCandidates/pageSize`（默认 ≤5 页），收益很小，属顺手清理。
- **代价**：无。
- **验证**：`cjprof record` 里 `dao<>` / `ORM.executor` 的自耗时占比是否可测；占比低于噪声则不做。
- **证据状态**：`无基线（待验证，不进 tasks）`

### [CPU] MySQL 稠密召回的过滤条件是「全量 id 的 JSON 数组」

- **现状**：`f_llm/src/dao/mysql/MemoryDAO.cj:49-59` —— 每次 ANN 检索先 `SELECT JSON_ARRAYAGG(id) FROM llm_memory WHERE user_id = …` 聚合该用户所有记忆 id；成本随用户记忆总量线性增长，与 `limit`（默认 `topK*2`）无关。
- **方案**：能下推的条件（`namespace`、`kind`）直接写进 `llm_memory` 的 `WHERE`；无法下推时改成「ANN 取 `limit*K` 后在应用侧按 `user_id` 过滤」或依赖 MyVector 支持的标量过滤语法（需实测组件能力）。
- **预期**：过滤集合从 O(用户记忆数) 降到 O(候选数)；用户记忆 10k 时省一次万级聚合。
- **代价**：若改为后置过滤，`limit` 需放大以补偿被过滤掉的行，召回质量需回归（`KnowledgeSearch`/`RetrievalScoring` 用例）。
- **验证**：造 1k / 10k / 100k 条记忆的单用户数据，`cjprof` + 数据库慢日志对比 `mySearchDense` 端到端耗时。
- **证据状态**：`无基线（待验证，不进 tasks）`

### [堆内存] `processedKnowledge` 的双份引用数组

- **现状**：`f_llm/src/store/mysql/EvolutionStateStore.cj:82-93`、`f_llm/src/store/postgres/EvolutionStateStore.cj:87-98` —— 先 `ArrayList<String>` 累积（≤5000 条，约 5000×(24B 头 + 内容)），再 `toArray()` 复制一份引用数组；峰值 = 两份同时存活。接口注释已说明它「只用于运维/调试查看」（`f_llm/src/store/EvolutionStateStore.cj:64`）。
- **方案**：运维路径不需要数组语义时返回 `ArrayList<String>`，或在 `ArrayList` 上 `reserve(KNOWLEDGE_LIMIT)` 后直接返回；`toArray()` 只在测试断言处调用。
- **预期**：省一份 ≤5000 元素的引用数组（≈40KB 量级），并把扩容次数从 log2(5000) 次降到 1 次。
- **代价**：接口返回类型变化（`EvolutionStateStore` 是对外接口，属破坏性变更，需用户确认）。
- **验证**：`getAllocatedHeapSize()` 在循环调用 100 次后对比（口径见 `mem §1.2`），并确认 GC 后回落。
- **证据状态**：`无基线（待验证，不进 tasks）`

### [堆内存] 每个方法一个 `*Box` 临时对象（本部分 12 个 box 类）

- **现状**：为了把 `synchronized(mutex){ … }` 里的结果带出来，每个方法都 `let box = XxxBox()` 再 `box.value = …`：`mysql/EvolutionLease.cj:44,57,66`、`postgres/EvolutionLease.cj:49,62,71`、`mysql/EvolutionStateStore.cj:50,83,109`、`postgres/EvolutionStateStore.cj:55,88,114`、`mysql/EvolutionStore.cj:42,63,73`、`postgres/EvolutionStore.cj:44,65,75`；对应 12 个 `class *Box`（`mysql/EvolutionStateStore.cj:152-162`、`postgres/EvolutionStateStore.cj:157-167`、`mysql/EvolutionStore.cj:142-148`、`postgres/EvolutionStore.cj:146-152`、`mysql/EvolutionLease.cj:111-113`、`postgres/EvolutionLease.cj:118-120`、`f_llm/src/store/EvolutionLease.cj:235-237`）。
- **方案**：若 `std.sync.synchronized` 的签名支持返回值（返回值即 lambda 的返回值），整体删掉 box 与「锁外再读 box」的写法；否则保留，但把 `class` 换成 `struct` 降低分配成本。**该 API 语义本轮无法查证**（`~/.autocode/cj/doc` 在本机不存在），必须先查文档再动手。
- **预期**：每方法 1 次小对象分配（≤48B）× 每次演进调用；演进低频，绝对收益很小，主要收益是可读性（去掉 6 个类、17 处样板）。
- **代价**：若 `synchronized` 确实返回值，改动面覆盖 6 个文件；语义不变。
- **验证**：改后跑 `EvolutionStoreIT_test` / `EvolutionStateStore_test` 全绿；分配量用 `getAllocatedHeapSize()` 前后对比（预期差异在噪声内，那就只做可读性改造）。
- **证据状态**：`无基线（待验证，不进 tasks）`

<!-- 第 24 部分 -->

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

<!-- 第 25 部分 -->

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

<!-- 第 1 部分 -->

| # | 假设 | 位置 | 缺什么数据 | 怎么采 |
| --- | --- | --- | --- | --- |
| 1 | 切块峰值内存占比高（≈5×内容），大文档是 RSS 主因 | `src/store/KnowledgeChunker.cj:66-87` | 峰值 / 稳态 RSS、块输出量 | 10 MB、100 MB 文档各跑 10 轮 `-O2`，采样 `getUsedHeapSize()` 与 RSS |
| 2 | 记忆检索的 colbert 重排每候选一次 DB 往返，是 `search` 的主要延迟 | `src/store/PostgresMemoryStore.cj:120-160`（`bound = max(topK*4, 20)`） | 单次 search 的分段耗时与 SQL 次数 | 分段计时 + `cjprof`，topK=10/50、候选 2000 条，记录 SQL 往返次数 |
| 3 | 流式 `onDelta` 每 delta 一次 JSON 解析 + 字符串拼接，GC 压力显著 | `src/llm/ChatStreamAccumulator.cj`、`src/llm/LLM.cj:236-247` | 单次会话分配量、GC 次数 | 单会话 10 万 delta，采分配量与 GC 计数 |
| 4 | `LLMConfsHolder.ensureFresh()` 每次 `candidates()` 都比一次 `MonoTime.now()`，在高 QPS 下不可忽略 | `src/llm/LLMConfsHolder.cj:111-117` | 该路径 CPU 占比 | 微基准：100 万次 `candidates()`，与去掉 `ensureFresh` 的版本对照 |
| 5 | 并发切块叠加 local region（N×8 MiB）会触发 `LocalRegionOutOfMemoryError` | `src/store/KnowledgeChunker.cj:20-36` | 并发阈值与 `cjLocalRegionMaxSize` 实际值 | 32 线程各切 2 MiB 文档，逐步加压，观察异常与 `getAllocatedLocalObjectSize()` |
| 6 | `llm_confRefreshSeconds=0` 会导致每次模型调用都 reload 配置 | `src/llm/LLMConfsHolder.cj:111-117` | 实际 reload 次数 | 设 0 后打 100 次 `chatByName`，数 `llm conf refreshed` 日志条数 |

<!-- 第 2 部分 -->

| # | 假设 | 位置 | 缺什么数据 | 怎么采 |
| --- | --- | --- | --- | --- |
| 1 | ohos 目标是否真的「不构建」（文档说本模块在 ohos 上不构建，`cjpm.toml` 却给了两个 ohos target 段） | `f_llm/doc/perf-baseline.md:45` vs `f_llm/cjpm.toml:79-87`；`docs/LocalMode.md:850` 只说「ohos 需条件编译排除」 | 构建是否成功、失败点是否为 local-mode 语法 | 在有 ohos SDK 的环境执行 `cd f_llm && cjpm build --target aarch64-linux-ohos`，记录首条错误；同时确认 CI 是否排除该目标 |
| 2 | `perf-baseline` 的 local 峰值公式对 1,000 rune 不成立，是否探针漏计 | `f_llm/doc/perf-baseline.md:16-17` | 1,000 / 10,000 rune 的同口径复测值 | 用文档描述的独立探针（`ArrayList<Rune>(total) @ local!` + 精确容量 `add`）重跑 1k/10k/100k，记录 `getAllocatedLocalObjectSize()` 与头开销 |
| 3 | 配置刷新是否真的覆盖 `LLMConf.weight` 与 `LLMConf.url`（而非只有部分字段） | `src/llm/LLMConfsHolder.cj:224-260`；`f_llm/doc/f_llm.md:87-91` | 改库后 60 s 内的一次真实调用观测 | 用可注入的 `LLMConfSource` 改一份 conf 的 weight/url，`sleep 61s` 后 `holder.candidates(name)`，断言返回新对象；再改 `llm_failureThreshold` 验证仍不生效 |

<!-- 第 3 部分 -->

> 没有性能测试数据支撑，**不进 `todo.md` / `tasks.md`**，仅用于下一轮补数据。

| # | 假设 | 位置 | 缺什么数据 | 怎么采 |
| --- | --- | --- | --- | --- |
| 1 | 配置来源故障期间每个请求都同步重试装载（无失败退避），DB 抖动时延迟被按请求数放大 | `src/llm/LLMConfsHolder.cj:111-121`、`:259-261` | `load()` 调用次数、P50/P95 延迟 | 注入必失败的 `LLMConfSource`，10 QPS 跑 10 分钟，统计 `load()` 次数与端到端延迟分布（改前/改后对照，`-O2`） |
| 2 | `candidates()` 每次调用都新建 `ArrayList` 并按 `llmName` 过滤，高 QPS 下有可测的分配与 GC 压力 | `src/llm/LLMConfsHolder.cj:48-64`、`:124-132` | 每秒分配字节、GC 次数与停顿 | `cjprof heap` + 1k QPS 压测，对照「缓存按 llmName 的不可变候选列表」版本 |
| 3 | 「读路径无锁」若成立，快照发布需要原子引用；补原子后的读侧开销是否可忽略，尚未测 | `src/llm/LLMConfsHolder.cj:82`、`:255` | 原子读 vs 普通读的单次开销、`candidates()` 调用频次 | 查仓颉内存模型文档后，用 `cjpm bench -O2` 对照 1e7 次引用读；并发场景再跑 8 线程压测 |

<!-- 第 4 部分 -->

| # | 假设 | 位置 | 缺什么数据 | 怎么采 |
| --- | --- | --- | --- | --- |
| 1 | #1 的实际触发频率：真实负载下单轮新增素材是否经常超过 `limit=500` | `f_llm/src/loom/SkillEvolutionJob.cj:266` | 每轮 `memory.list` 返回条数、`at` 分布、水位线推进值 | 在 `run` 里打一条结构化日志（返回条数 / max `at` / 新水位），跑一周稳态统计「返回条数 == 500」的轮次占比 |
| 2 | `AttachmentSink` 用**单个静态** `Mutex` 串行全部目录的落盘，批量收信（多账号并行 `channelInbox`）时落盘段可能成为串行段 | `f_llm/src/channel/EmailChannel.cj:77,160-164` | 临界区单次持有时长、并发收信路数、`save` 端到端 p50/p99 | 20 路并发对同一目录各存 500 个附件，`-O2` 下记录 `save` 的 p50/p99 与吞吐；对照「按目录分片锁」版本 |
| 3 | 部署侧允许根目录里是否真有软链 / 特殊文件（决定 #3 的实际可利用面） | `f_llm/src/channel/EmailChannel.cj:220` | `llm_channelSendRoots` 指向目录的实际内容与权限 | 目标环境对每个根跑 `find <root> -type l -o -type p` |

<!-- 第 5 部分 -->

| # | 假设 | 位置 | 缺什么数据 | 怎么采 |
| --- | --- | --- | --- | --- |
| 1 | 装配期单网关复用确实降低了 store 步骤端到端延迟（proposal 声称「每步 3 次配置读 + 2~3 次开库」） | `fix-loom-store-gateway-reuse/proposal.md:12`；`LoomWiring.cj:103-106` | 改前/改后单步延迟绝对值与分布 | 10 步流程含 5 个 store 步骤，`cjpm bench -O2` 各跑 50 轮取中位数与 P95 |
| 2 | `knowledgeOf` 的 1+K 次网关调用是演进任务的主要自耗时 | `SkillEvolutionJob.cj:318-341` | 自耗时占比、单次 `call` 开销 | `cjprof record` 跑演进任务，知识库 500 条、跨 3 个租户 |
| 3 | `memory.list(experience)` 的双份物化对 GC 有可测影响 | `LoomStoreGateway.cj:149-163` | 分配量、GC 次数、单次返回条数 | `cjprof heap` + 200 次调用，对比单次查询实现 |
| 4 | 并发调用 `executeNow` 在生产并发度下会实际发生人格/轮次串味 | `LoomHostApi.cj:183-205,212,235`、`LoomContextLog.cj:51-53` | 峰值并发流程数、注入前缀命中率 | 起 8 线程各跑 100 次带不同 persona 的流程，断言每个流程的 `fullSystem` 只含自身 persona |

<!-- 第 6 部分 -->

> 无性能测试数据，仅用于下一轮补数据；不进 `todo.md` / `tasks.md`。

| # | 假设 | 位置 | 缺什么数据 | 怎么采 |
| --- | --- | --- | --- | --- |
| 1 | 单遍扫描把 `render` 从 `O(步数 × 模板长度)` 降到 `O(模板长度)` 后，端到端有可测收益 | `f_llm/src/loom/LoomHostApi.cj:73-145`；`f_llm/doc/spec/perf-loom-render-context/proposal.md:7-8` | `render` 自耗时占比、步数分布 | `cjprof record` 跑 50 步流程（每步 system 2 KB、含 10 个占位符），对比改前实现 |
| 2 | 知识候选 1000→400 降低了单次检索的驻留内存，且对 topK 内侧召回无损 | `f_llm/src/store/postgres/KnowledgeStore.cj:58`、`mysql/KnowledgeStore.cj:55` | 每请求驻留字节、topK 命中率 | 同一语料 5 万 chunk，测 `getAllocatedHeapSize()` 增量与 20 条查询的 recall@5 |
| 3 | colbert 只重排前 `max(topK*4,20)` 不改变最终排序质量 | `f_llm/src/store/PostgresMemoryStore.cj:118-155` | 全量重排 vs 前 N 重排的排序差异率 | 1000 候选、topK=5，比对两种做法的 P@5 与 DB 往返次数 |
| 4 | local mode 的 rune 缓冲收益是 `4n+4112` 字节级、且峰值下降可观测 | `f_llm/src/store/KnowledgeChunker.cj:66-88`；`f_llm/doc/perf-baseline.md`（参考值，单次运行含噪声） | 多轮中位数与 RSS 对照 | `-O2` 下 2 MiB ASCII 跑 20 轮，记录 peak RSS / `getAllocatedHeapSize()` 中位数与离散度 |

<!-- 第 7 部分 -->

> 没有性能测试数据支撑的猜测，不进 `todo.md` / `tasks.md`，只用于下一轮补数据。

| # | 假设 | 位置 | 缺什么数据 | 怎么采 |
| --- | --- | --- | --- | --- |
| 1 | `render` 的 `+=` 拼接在 `limit` 较大时成为工具调用耗时主项 | `f_llm/src/channel/ChannelFunctions.cj:133-156` | 单次 render 耗时随条数的曲线 | `cjpm bench -O2` 跑 10/100/1000 条消息，记录中位数与离散度 |
| 2 | `TextTemplate.compile` 在每事件重复编译上占可观 CPU | `f_llm/src/agents/AgentTask.cj:230-236` | 自耗时占比、每事件编译次数 | `cjprof record` 跑「15 技能 × 10 轮对话」 |
| 3 | `ensureLoaded` 锁内 bean 实例化的单次持有时长偏大 | `f_llm/src/balance/BalanceQuerier.cj:148-155` | 首次查询延迟、锁等待时长 | 计时 `lookupList` + 线程状态采样（BLOCKED） |
| 4 | 提示词组装（`genPromptsTemplate` + `genSkillDetails`）是每事件峰值内存的主要来源，local mode 可降峰值 | `f_llm/src/agents/AgentTask.cj:139-337` | 峰值 `getUsedHeapSize()` / RSS 对照 | 同输入跑改前改后，取峰值与 `getAllocatedHeapSize()`；注意 local region 不计入前者 |

<!-- 第 8 部分 -->

| # | 假设 | 位置 | 缺什么数据 | 怎么采 |
| --- | --- | --- | --- | --- |
| 1 | `ChannelMediator.channel/platforms/accounts` 锁内对每个实例做 `normalize()`（`trimAscii + toAsciiLower`），账号多时锁内耗时上升 | `f_llm/src/channel/ChannelMediator.cj:118-145,157-167` | 实例数上限、锁内单次耗时、并发查询频率 | 造 10/100/1000 个实例，多线程并发 `channel()`，记录临界区 p99 与吞吐 |
| 2 | `FEmailTransport.receive` 每封信调一次 `email().body(summary)`，是否每次都触发完整 IMAP `FETCH` 往返，使 `channelInbox` 延迟随 `limit` 线性增长；元数据模式下是否白拉整封附件 | `f_llm/src/channel/EmailChannel.cj:351-374` | `body()` 的实现路径与单封往返耗时、字节量 | 对真 IMAP 邮箱取 1/10/50 封，分段计时（`list` / 逐封 `body` / 附件读），并记录服务端传输字节 |
| 3 | `ChannelMediator.register` 是否会在运行期被再次调用（重装配/配置刷新），从而与在途 `send`/`receive` 竞争 | `f_llm/src/channel/ChannelMediator.cj:96-115`、`ChannelBootstrap.cj:74,85-93` | `installFromConfig` 的完整调用链（本次只追到 `ChannelBootstrap`，未找到定时器/刷新入口） | 追调用方或观察重装配窗口内的 send 失败日志 |
| 4 | `AttachmentSink.freeName` 线性探测在「同名附件长期累积」目录里成为串行段（与第 4 部分登记的「单锁串行」同源） | `f_llm/src/channel/EmailChannel.cj:134-141,160-164` | 目录内同名文件数分布、`exists` 单次耗时 | 预置 1/100/1000 个同名文件，20 路并发 `save`，记录 p50/p99 与 CPU |
| 5 | `checkAttachment` 的「逐附件 × 逐根目录」`canonicalize` 在 send 主路径上的自耗时占比 | `f_llm/src/channel/EmailChannel.cj:220-246` | 该函数在 `send` 端到端里的占比 | `cjprof record` 跑 1000 次带 5 附件的 `send`（FakeTransport），看 `canonicalize` 自耗时 |
| 6 | `LLMConfig.getFileSandboxPath()` 每次文件工具调用都做 `exists`（可能建目录），属可省的启动期工作 | `f_llm/src/config/LLMConfig.cj:205-221` | 单次调用耗时与文件工具 QPS | `cjprof` 跑文件工具压测，或埋点统计 `exists` 调用次数 |

<!-- 第 9 部分 -->

| # | 假设 | 位置 | 缺什么数据 | 怎么采 |
| --- | --- | --- | --- | --- |
| 1 | `JSON_ARRAYAGG` 全量 id 的聚合成单次 ANN 检索的主要开销 | `f_llm/src/dao/mysql/MemoryDAO.cj:49-59` | 语句级耗时占比、聚合行数 | 对同一账号构造 1k/10k/100k 条记忆，开 MySQL 慢查询日志 + `cjprof record` 跑 `searchDense` 100 次，看该语句占比 |
| 2 | `mySearchSparse` 的 `GROUP BY` 含 `content`（LONGTEXT）导致临时表 + filesort | `f_llm/src/dao/mysql/MemoryDAO.cj:98-108`、`f_llm/src/dao/postgres/MemoryDAO.cj:112-125` | `EXPLAIN` 的 `Using temporary; Using filesort`、扫描行数 | `EXPLAIN ANALYZE` 同一 SQL（tokens 10/100/1000 三档），与「先按 id 聚合再 JOIN 正文」的改写版对照 |
| 3 | `knowledgeList` 全表扫成为每轮演进的固定成本 | `f_llm/src/dao/mysql/EvolutionStateDAO.cj:67-73`、`postgres/EvolutionStateDAO.cj:76-82` | 表行数、单次耗时 | 灌 10k/100k 行后计时 + `EXPLAIN`；再做「加索引」前后对照（同机器、`-O2`、取中位数） |
| 4 | `LIKE '%term%'` 分页扫描在 `pageSize=200` / `maxCandidates=1000` 下的实际代价 | `f_llm/src/dao/mysql/KnowledgeDAO.cj:123-131`、`postgres/KnowledgeDAO.cj:97-105` | 每页耗时、命中分布 | 造 1k/10k chunk，跑含 `%` 与不含 `%` 的两组 query，比 `Handler_read_next` 与端到端耗时的中位数 |

<!-- 第 10 部分 -->

> 没有性能测试数据支撑的猜测。**不进 `todo.md` / `tasks.md`**，只用于下一轮补数据。

| # | 假设 | 位置 | 缺什么数据 | 怎么采 |
| --- | --- | --- | --- | --- |
| 1 | 每请求新建 `HttpClient` 使建连/握手占 `embed` 端到端延迟的可观比例（https 更甚） | `BgeM3Transport.cj:87-99` | 建连 vs 读响应的分段耗时占比 | 在 `postOnce` 内打 3 段计时，本地 BGE-M3，1000 次取 P50/P95 |
| 2 | `toString()+Float64.parse` 是 `BgeM3Codec.parse` 的主要自耗时 | `BgeM3Transport.cj:144-147` | self time 占比 | `cjprof record` 跑 `BgeM3Codec.parse`，fixture 1024+32×1024，重复 1000 次 |
| 3 | 单槽缓存命中率在并发下远低于设计的 2/3 | `HttpEmbedder.cj:66-74` | 命中率与 HTTP 调用次数 | 加 `calls`/`hits` 计数，8 线程各写 1000 条记忆 |
| 4 | 长文本（接近 8192 token）时 `colbert` 单次响应峰值达数十 MB，是记忆写入路径的峰值内存主项 | `BgeM3Transport.cj:128-135`；`HttpEmbedder.cj:59` | 峰值 RSS / 单次分配量 | 8k token 文本连续 100 次，采 `getAllocatedHeapSize()` 与 RSS 峰值，对照 `8192×1024×8B ≈ 64MB` |
| 5 | `ORDER BY save_time` 在批量写入后确实产生翻页重复/漏行 | `MemoryDAO.cj:154-175` | 同 `save_time` 行数与翻页重叠行数 | 单事务插 5 行、`limit=2` 翻页，统计并集/交集（功能验证，非性能） |
| 6 | `meet().IN()` 在 `namespaces` / `tokens` 规模较大（>100）时 SQL 生成开销显着 | `MemoryDAO.cj:59-63`、`:112` | SQL 生成耗时 | `cjprof` 跑 `searchDense` 1000 次，`namespaces` 1/10/100 三档 |

> local mode：模块已开 `--experimental --enable-local-mode`（`f_llm/cjpm.toml`）。`BgeM3Codec.parse` / `Embedding.parse` 的中间对象（`JsonValue` 树、`ArrayList<Float64>`、`Array<Array<Float64>>`）除返回的 `EmbeddingResponse` 需 `exclave` 外基本不逃逸，是候选改造点；但收益只能靠峰值内存对照证明，当前无数据 → 只作待验证，不进方案。

<!-- 第 11 部分 -->

| # | 假设 | 位置 | 缺什么数据 | 怎么采 |
| --- | --- | --- | --- | --- |
| 1 | `build` + `toData` + `toString` 在失败转移路径上占端到端耗时的可观比例 | `ChatCompletionsMapper.cj:36-79`、`LLM.cj:133-146` | 自耗时占比、单次耗时绝对值 | `cjprof record` 跑「3 候选全 500、会话 200 条」场景，看 `toData` / `JsonValue.from` / `toString` 的 self time |
| 2 | `tools` 数组顺序（`HashSet<FunctionCall>` 迭代序，`LLMParams.cj:42` + `ChatCompletionsMapper.cj:66-76`）稳定，不影响上游 prompt cache 命中 | `ChatCompletionsMapper.cj:66-76` | 同进程/跨进程顺序一致性、上游 cache 命中率 | 用同一 `params` 连续 `build` 1000 次比对 `tools` 序列化文本；再压 10 分钟稳态看 cache 命中率波动 |
| 3 | `CallLog.summary` 在 INFO 关闭时仍拼完整字符串（1 次/调用，量级可忽略） | `CallLogger.cj:35-43` | logger 级别过滤行为、单次构建耗时 | 关 INFO 后循环 1e4 次 `CallLog.info` 分段计时；确认 `log.info{}` 的 lambda 是否延迟求值 |
| 4 | `build` 内的 `JsonObject` / `JsonArray` 中间件（不逃逸出 `build` 之外的子树）适合 local region，可降峰值内存 | `ChatCompletionsMapper.cj:88-123` | 峰值内存对照（`getUsedHeapSize()` / RSS） | `f_llm/cjpm.toml:9` 已开 `--enable-local-mode`；对 `rewriteMultimodal` / `toWirePart` 加 local 标注后跑同输入，对照峰值与 `getAllocatedLocalObjectSize()` |
| 5 | 流式用量估算与实际账单偏差幅度（prompt 侧恒 0） | `ChatStreamAccumulator.cj:163-170`（估算）/ `ChatCompletionsMapper.cj:51-55`（未请求 usage） | 同一 prompt 的估算值 vs 上游真实 usage | 同一 prompt 分别走 `chatStream` 与 `chat`（非流式），比对 usage；样本覆盖中文/英文/代码各 10 条 |

<!-- 第 12 部分 -->

> 没有性能测试数据支撑，只用于下一轮补数据；**不进 `todo.md` / `tasks.md`**。

| # | 假设 | 位置 | 缺什么数据 | 怎么采 |
| --- | --- | --- | --- | --- |
| 1 | 流式每帧一次 `JsonValue.fromStr` + 两次 `StringBuilder` 追加 + `argumentsChunk +=`，是流式会话的主要分配源 | `ChatStreamAccumulator.cj:58-133` | 单会话分配字节、GC 次数、`feed` 自耗时占比 | 单会话灌 10 万 delta（含 5% tool_calls），`cjprof record` + `getAllocatedHeapSize()` 前后差 |
| 2 | `balancerMutex` 在高并发下成为选择路径的串行段 | `LLMConfsHolder.cj:189-222` | 锁等待时长、BLOCKED 线程数、`peekNext` p99 | 32 线程压 `chatByName`（桩 transport），线程状态采样 + `cjprof` |
| 3 | 每请求 2 次 `candidates()` 复制对分配速率有可测贡献 | `LLMConfsHolder.cj:49-67`、`LLM.cj:101` | 每请求分配字节占比 | 同上压测，对比「返回缓存列表」补丁前后的分配量与 RSS |
| 4 | 无同步发布 `snapshot` 在实测中是否真的读到旧版本 / 中间态 | `LLMConfsHolder.cj:112`、`:255` | 交错频率、旧版本持续时长 | 加版本号埋点（读到 vX、当前 vY），在 60s 刷新周期下跑 10 分钟高并发，统计 vX<vY 的样本比例 |
| 5 | 3s 全局读超时实际打断 chat 的频率（首 token / 长停顿） | `LLMStreamTransport.cj:43-50`、`BgeM3Transport.cj:62-65` | 超时次数 / 请求总数、首 token 分布 | 在 transport 捕获读超时并计数，连续 24h 真实流量；同时记录 TTFT P50/P99 |
| 6 | `stream()` 内累加器与 body 不逃逸，可用 local mode 降峰值 | `LLM.cj:208-247` | 逃逸分析结论、峰值内存 | 先 `cjprof heap` 记录峰值，再按 `--enable-local-mode`（模块已开，`f_llm/cjpm.toml:9`）给 `ChatStreamAccumulator` 加 `@local` 对照峰值与 RSS |

<!-- 第 13 部分 -->

| # | 假设 | 位置 | 缺什么数据 | 怎么采 |
| --- | --- | --- | --- | --- |
| 1 | 每请求新建 `HttpClient` 导致 TLS 握手占单次 LLM 调用延迟的可观比例 | `f_llm/src/llm/LLMTransport.cj:41` | connect/TLS 阶段耗时与总耗时占比 | 分段计时（DNS/connect/TLS 完成/首字节/读完）跑 100 次 `chat`，与复用 `Client` 的实现对照 |
| 2 | `DialectRegistry.get` 的全局 `Mutex` 在并发调用下成为串行点 | `f_llm/src/llm/openai/ProviderDialect.cj:103-107` | 锁等待时长、BLOCKED 线程数 | `cjprof` 看不到锁，需线程状态采样 + 把 `resolve` 预热成不可变快照后对照吞吐 |
| 3 | `ResponsesMapper.build/parse` 的 `JsonObject` 图（每条消息 2-4 个对象）是短生命周期分配热点 | `f_llm/src/llm/ResponsesMapper.cj:36-128` | 单位调用分配字节数、GC 次数 | `cjprof heap` 对比 1k 条历史消息的 `respond` 调用，配合 `getAllocatedHeapSize()` |
| 4 | `HeuristicTokenCounter` 的 字节/3 估值与真实 `usage.prompt` 偏差导致裁剪阈值失效 | `f_llm/src/llm/TokenCounter.cj:44-50` | 估算值与上游 `prompt_tokens` 的比值分布（含工具/多图样本） | 在 `CallLogger` 里同时记录估算值与真实 usage，跑 1 周真实会话后看 P50/P95 比值 |
| 5 | Responses 流式缺 `response.completed` 的截断率 | `f_llm/src/llm/ResponsesStreamAccumulator.cj:79-93` | 线上 `finish` 为空/`response.completed` 缺失的请求占比 | 加计数埋点（`finishReason.isEmpty()` 且 `kind=Responses`），跑 24h |

<!-- 第 14 部分 -->

| # | 假设 | 位置 | 缺什么数据 | 怎么采 |
| --- | --- | --- | --- | --- |
| 1 | `LoomBootstrap.startup` 串行重编译是启动耗时主项（每条流程一次 `Planner.parse` + `compileSteps`） | `f_llm/src/loom/LoomBootstrap.cj:80-90` | 单条编译耗时、流程数、占启动总时长比例 | 装配期分段计时（`wire` 前后 + 每条 `compileSteps` 前后），N=10/100/1000 条流程各跑 5 次取中位数 |
| 2 | `LoomContextLog` 保留 200 轮完整 `input/output` 是单次执行峰值内存的主要来源之一 | `f_llm/src/loom/LoomContextLog.cj:61,74-90` | 单轮平均字节数、峰值 heapUsed 占比 | 长流程（≥200 轮、单轮输出 ~10KB）跑 `cjprof heap`，对比 `begin()` 前后与 `clear()` 后的 `getUsedHeapSize()` |
| 3 | `CodeGen.flowSource` 的 O(n²) 拼接在真实计划规模（n≤30）下可忽略 | `f_llm/src/loom/CodeGen.cj:100-131` | n=20/100 的实测耗时曲线 | `cjpm bench -O2`，与 `StringBuilder` 版本对照 |
| 4 | f_store 的 `prefix` 迭代顺序是否天然按 key 有序（决定 `list` 能否省掉 `sortNames`） | `f_llm/src/loom/FStoreLoomStore.cj:95-101` | `PrefixIterator` 的顺序保证 | 读 `f_store/src/Store.cj:199` 实现并写用例：乱序写入 1000 个 `f_llm:loom:index:*` 后断言迭代顺序 |

<!-- 第 15 部分 -->

| # | 假设 | 位置 | 缺什么数据 | 怎么采 |
| --- | --- | --- | --- | --- |
| 1 | `render` 每次全量拷贝 `values` 是模板步骤的主要开销（分配 + 锁等待） | `f_llm/src/loom/LoomHostApi.cj:80-88` | 单次 `render` 耗时、锁等待时长、`values` 平均条目数 | 50 步流程跑 100 轮，`cjprof record -O2` 看 `render` self time；锁前后打点统计持有时间 |
| 2 | `confirmFlow` 丢弃编译产物导致 `executeNow` 重复编译，占单次执行的可感比例 | `f_llm/src/loom/LoomService.cj:113/131-140`、`LoomRunner.cj:126` | 编译段耗时 / 执行总耗时 | 分段计时（编译段 vs 派发段），或 `cjprof` 看 `LoomCompiler.compile*` self time；5 步流程 × 100 次 |
| 3 | `memory.list` 多 kind 时每页两次 Store 查询，使翻页延迟翻倍 | `f_llm/src/loom/LoomStoreGateway.cj:147-163` | 每 kind 的 `listByKind` 延迟、页大小 | 造 2 种 kind 各 1 万条，`cjpm bench -O2` 对比单 kind 与双 kind 的 `limit=50` 单页耗时 |
| 4 | `skill.load` / `upsert` 的全表扫描在技能数百条后成为流程启动段热点 | `f_llm/src/loom/LoomStoreGateway.cj:239-248/249-260`、`LoomRunner.cj:469-490` | 技能表规模、每次流程的标题数、单次 `list()` 耗时 | 造 10 / 100 / 1000 条技能，bench `resolveSkills(['a','b','c'])`；生产侧加计数埋点看标题数分布 |
| 5 | `topologicalOrder` 的 `remove(at: 0)` 在 100+ 步计划上成为可观开销 | `f_llm/src/loom/LoomRunner.cj:545-546` | 不同 n 下的排序耗时 | bench 10 / 100 / 1000 步，取中位数；与索引游标实现对照 |
| 6 | `LoomRegistry.flows` 的实际增长速度与单条内存（决定 #12 的上限该设多少） | `f_llm/src/loom/LoomRegistry.cj:167-183` | 每日 `loomExecute` 次数、`pending`/`clarifying` 残留比例、单条 `LoomFlow` 字节数 | 生产埋点统计 `registry.size()` 与 `usedHeap`（每小时），跑一周；离线用 1 万条 `put` 测单条均值 |

<!-- 第 16 部分 -->

> 没有性能测试数据支撑的猜测（热点、瓶颈、优化收益）。**不进 `todo.md` / `tasks.md`**，只用于下一轮补数据。

| # | 假设 | 位置 | 缺什么数据 | 怎么采 |
| --- | --- | --- | --- | --- |
| 1 | `LoomTimeout` 的 10ms 轮询带来可观线程唤醒与超时精度损失（每次调用最多 `timeoutMs/10` 次 `sleep` + 唤醒） | `LoomTimeout.cj:48-52` | 单次调用唤醒次数、CPU 占比、超时误差分布 | `cjprof record` 跑「1000 次 3s 超时的工具调用」，统计 `sleep` 相关采样与「墙钟 − 期望超时」的 P50/P99 |
| 2 | `jsonQuote` 的两次 `toArray()` 拷贝在计划落库路径上占比可测 | `Plan.cj:188-213` | self time 占比、分配量 | `cjpm bench -O2` 对 `toJson()` 做改前 / 改后对照 + `cjprof` 看 `String.fromUtf8` 与数组拷贝占比 |
| 3 | 评测路径（50 文档 × 622 query × `SkillCatalog.search`）的耗时大头在编码而非打分 | `RetrievalEvalRunner.cj:91-100`、`RetrievalEval.cj:319-365` | 编码 / 余弦 / 排序的分段耗时 | 在 search 闭包里加分段计时，跑一次 `fllm_runEval=1`，对比三段中位数 |
| 4 | `EvalReport.render` 的 O(12²) 选择排序与 `padRight` 字符串拼接在报告生成里可忽略 | `RetrievalEval.cj:193-235` | 单次 `render` 耗时 | 对 `render` 跑 1 万次取中位数（预期微秒级；若成立则不必优化） |

<!-- 第 17 部分 -->

| # | 假设 | 位置 | 缺什么数据 | 怎么采 |
| --- | --- | --- | --- | --- |
| 1 | `knowledgeOf` 是 1 + N 次网关调用（N 最多 500），单轮演进耗时以网络 RTT 为主 | `f_llm/src/loom/SkillEvolutionJob.cj:318-358` | 单次 `gateway.call` P50/P95、单轮耗时分解 | 分段计时统计 `docIds` 与逐条 `get` 的耗时，跑 50/200/500 三档看是否线性 |
| 2 | `keywordScore` 对每个技能做一次全文 `toAsciiLower` + 分词 + 两次 rune 扫描，开销随「技能数 × 正文长度」增长 | `f_llm/src/loom/SkillCatalog.cj:262-303` | 自耗时占比、技能数与正文长度分布 | `cjpm bench` 或分段计时：50 技能 × 2KB 正文、查询 20 字，重复 1000 次取中位数 |
| 3 | `SkillCatalog.vectors` 在长跑进程中条目数持续增长（版本键不淘汰），GC 后不回落 | `f_llm/src/loom/SkillCatalog.cj:51`、`230-260` | 条目数随时间曲线、RSS 曲线 | 按 24h 冷却节奏模拟 1 年演进（桩 chat），每小时采样 `vectors.size` 与 `getUsedHeapSize()` |

<!-- 第 18 部分 -->

| # | 假设 | 位置 | 缺什么数据 | 怎么采 |
| --- | --- | --- | --- | --- |
| 1 | 每事件 `spawn` 的线程创建 + `Store` WAL 写放大是记忆路径的主要开销 | `f_llm/src/memory/Memory.cj:145-151`、`FaithfulMemory.cj:50-59` | 单次 `add` 耗时分布、WAL 每秒写入条数 | `cjprof record` 跑 10 分钟稳态会话负载；统计 `Store.add` 调用次数与 `wal.append` 自耗时 |
| 2 | 同一毫秒同 role 的消息碰撞（#3）实际发生频率 | `f_llm/src/memory/FaithfulMemory.cj:36-38,53` | 碰撞次数 / 总写入次数 | 在 `add` 里对 `contentKey` 做命中计数埋点，跑真实会话 1 天 |
| 3 | `StoreWiring.wire()` 的全局 `Mutex` + `StoreSettings.load()` 在每次 `remember` 上成为串行点 | `f_llm/src/memory/Memory.cj:124`、`f_llm/src/wiring/StoreWiring.cj:52-73` | 单次 `wire()` 耗时、并发写记忆时的等待时长 | 分段计时包一层 `wire()`，多线程并发 `remember` 压测，看 P99 |
| 4 | `ToolCatalog` 的 `toAsciiLower` + 逐条 JSON 解析在工具数上百时成为检索热点 | `f_llm/src/loom/ToolCatalog.cj:47-88` | 工具数 → 单次 `search` 耗时曲线 | `cjpm bench -O2` 对 10/100/1000 个注册工具各跑 10k 次，取中位数 |
| 5 | `sortDesc` 的插入排序与 `check` 的 `result.contains` 在规模放大后成为 O(n²) 瓶颈 | `ToolCatalog.cj:90-100`、`ToolScope.cj:50-52` | n 到多大开始显著 | 同上 bench，n = 10/100/1000 |

<!-- 第 19 部分 -->

| # | 假设 | 位置 | 缺什么数据 | 怎么采 |
| --- | --- | --- | --- | --- |
| 1 | 搜索/抓取端到端延迟中 TLS 握手占比可观（每请求新建 client） | `f_llm/src/search/DeepSeekSearchProvider.cj:36-50` | 握手耗时占比、P50/P95 | 同机连续 200 次 search，分段计时（建连/握手/首字节/读完）+ `cjprof record` |
| 2 | 每请求 3~5 次 `LLMConf.conf` 解析的自耗时进入前 10 | `f_llm/src/model/po/LLMConf.cj:73-78`、`:93-130` | `fromColumn` 自耗时占比 | `cjprof` 跑 10 分钟稳态对话负载（≥1k 请求），按函数聚合 |
| 3 | `need_content=true` + count=50 时单次搜索的峰值堆由响应体主导 | `f_llm/src/search/DeepSeekSearchProvider.cj:105-107` | 峰值堆、单条 summary 字节分布 | 构造 50 条全正文响应，记录 `getUsedHeapSize()` 峰值与 `cjprof heap` |

<!-- 第 20 部分 -->

| # | 假设 | 位置 | 缺什么数据 | 怎么采 |
| --- | --- | --- | --- | --- |
| 1 | 构造期 `repair()` 是模型配置读取路径的主要固定开销 | `FStoreMetaStore.cj:89,143` | 单次 `repair` 自耗时、配置条数 | `cjprof record` 跑 1000 次 `LLMConfs.holder()` + 1000 次 `SkillCatalog` 检索，看 `prefix`/`get` 占比 |
| 2 | 每次 `Stores.meta()` 新建 `Store` 导致线程数随请求增长 | `FStoreMetaStore.cj:41,51`；`Stores.cj:92` | 进程线程数随请求数的曲线 | 压测 10 分钟（QPS 固定），每 30 s 采 `/proc/self/status` 的 `Threads` 与 `lsof` 句柄数 |
| 3 | `InMemoryEvolutionStore.list` 的排序成为内存后端瓶颈 | `EvolutionStore.cj:90-116` | N = 10²/10³/10⁴ 的单次耗时与锁等待 | `cjpm bench -O2` 三档 + 分段计时（锁内/锁外） |
| 4 | `KnowledgeChunker` 峰值内存 ≈ 4×内容字节 | `KnowledgeChunker.cj:72-85` | `getUsedHeapSize()` 峰值 vs 内容大小 | 1/10/100 MiB 各 20 轮，`getAllocatedHeapSize()` 差 + `VmHWM`（可复用 `KnowledgeChunkerLocalModeBench_test.cj:67-80` 的 `peakRssKb`） |
| 5 | `FStoreEvolutionStore` 三键写入使读路径放大到全表扫描 | `EvolutionStore.cj:205-238` | 写入条数 vs `list` 耗时/扫描条数 | 写入 10³/10⁴/10⁵ 条后测 `list(0,20)`，并在 `prefix` 循环里加计数 |
| 6 | 锁内 `store.prefix`（`FStoreEvolutionStateStore.processedKnowledge`）在天量知识下成为串行段 | `EvolutionStateStore.cj:231-244` | 临界区持有时长、调用频次 | 线程状态采样（BLOCKED/WAITING）+ 分段计时；CPU profile 看不到锁等待 |

<!-- 第 21 部分 -->

| # | 假设 | 位置 | 缺什么数据 | 怎么采 |
| --- | --- | --- | --- | --- |
| 1 | 单次 `search` 的临时容器（`denseScores`/`sparseScores`/`records`/`ids`/`rerankScores`/`used` 共 6 个 Map/List）在 `topK=5`、候选 10~20 时占自耗时与分配量可观比例 | `f_llm/src/store/PostgresMemoryStore.cj:97-164` | 每次检索的分配字节数、GC 次数占比 | `cjprof heap` 跑 10k 次同参数检索；对照"复用外部传入 buffer"版本 |
| 2 | `MemoryKinds.predefined()` 每次调用新建 9 元素 `ArrayList`，被 `validate`/`all` 在写路径调用时放大 | `f_llm/src/store/MemoryKinds.cj:80-92`、`:95-106`、`:197-205` | 调用频次与单次分配 | 埋点统计 `validate` 每秒调用数；`cjprof` 看 `ArrayList` 分配栈 |
| 3 | `add` 每条记忆 4 次远程向量化（title/content 各一次 embed + 各一次 embedColbert），HTTP 场景下写延迟主要由这 4 次往返决定 | `f_llm/src/store/PostgresMemoryStore.cj:47-49`、`:64-65` | 端到端写延迟分布、4 次调用各自耗时 | 分段计时打点，跑 1k 次写入，取 P50/P95；对照批量接口（一次传 title+content） |
| 4 | 重建为逐条 upsert（每条 2 次向量化 + 2 次 DB 写），百万级记忆的全量扫描耗时与 DB 压力构成运维风险 | `f_llm/src/store/MemoryIndexRebuilder.cj:74-89` | 每页耗时、总时长、连接占用 | 在 10 万条数据集上跑 `rebuild(batchSize=100)`，记录每页耗时中位数与 DB 侧 QPS |
| 5 | `KnowledgeSearch.occurrences` 对每个 term 做一次 `indexOf` 扫描，长文档 × 多 term 时是知识检索的 CPU 主项 | `f_llm/src/store/KnowledgeSearch.cj:43-68` | 单文档长度分布、每查询扫描字节数、自耗时占比 | `cjprof record` 跑 1k 次 `knowledge.search`，输入 20 篇 × 4KB；对照"单趟多词匹配"实现 |
| 6 | `SqlMemoryStore.search` 的两轮选择排序（rerank 取前 bound + 最终取 topK）在 topK=50/100 时约 `O(topK²)` 次比较，可能成为单次检索的 CPU 主项 | `f_llm/src/store/PostgresMemoryStore.cj:134-191` | `topK` 分布、自耗时占比、与 DB 往返的比值 | `cjprof record` 跑 1k 次 `search`（候选 2×topK，topK=5/20/100 三档），对比「一次 sort + 截断」实现，`-O2` 中位数与 P95 |
| 7 | `rebuild` 的 `batchSize=100` 与「每条 2 次 `embedColbert` + 2 次 DB 写」的串行模式决定全量重建耗时，分批大小可能有最优区间 | `f_llm/src/store/MemoryIndexRebuilder.cj:74-89` | 每页耗时中位数、向量服务 QPS 上限、峰值 RSS | 对 1 万条记忆跑 `batchSize` = 50/100/500 三组，记录总耗时、每页耗时分布、进程峰值 RSS |

<!-- 第 22 部分 -->

| # | 假设 | 位置 | 缺什么数据 | 怎么采 |
| --- | --- | --- | --- | --- |
| 1 | 每次 RPC 新建 `HttpClient` 的建连开销是远程检索的主要成本 | `f_llm/src/store/hydra/HttpTransport.cj:198` | 建连+握手在单次调用中的耗时占比 | 分段计时（client 构造 / post / readEntire），`hydra.search` 20 候选，跑 1000 次取中位数 |
| 2 | `HydraKnowledgeStore.search` 的选择排序 + 逐候选 `get` 占检索自耗时较高比例 | `f_llm/src/store/hydra/ContentStore.cj:176-226` | self time 占比、候选实际分布 | `cjprof record` 跑 400 候选 / limit=5 场景 |
| 3 | `nextId()` 的两次往返在写路径中占比可观 | `f_llm/src/store/hydra/MemoryRepository.cj:254-263` | 两段耗时占比 | 写路径分段计时，1k 次 upsert（远程 transport） |
| 4 | `esc()`/`numbers()` 的拼接分配是长 payload 写路径的主要分配来源 | `f_llm/src/store/hydra/HttpTransport.cj:229-275` | 单次写分配字节数、GC 次数 | `getAllocatedHeapSize()` + GC 计数，payload 1KB/10KB 对照 |
| 5 | 同进程多个 `FStoreVectorStore` 指向同一目录是否安全（是否加锁/是否会写坏） | `f_llm/src/store/Stores.cj:68-97` → `ContentStore.cj:35` | `f_store.Store` 的并发/多实例语义 | 读 `f_store` 的 `Store.open` 实现 + 多线程压测同一目录（20 线程 × 100 写）后校验 `recover()` 结果 |

<!-- 第 23 部分 -->

| # | 假设 | 位置 | 缺什么数据 | 怎么采 |
| --- | --- | --- | --- | --- |
| 1 | `vectorLiteral` 的 O(n²) 拼接在 `upsert` 端到端里占比很低（嵌入与网络占主导），单独改造收益 <5% | `f_llm/src/store/mysql/MemoryRepository.cj:215`；`postgres/MemoryRepository.cj:188` | 自耗时占比 | `cjprof record` 跑 200 次 `upsert`（1024 维），看 `vectorLiteral` self time 与 `String` 分配的占比 |
| 2 | 6 个演进/租约类的实例 `Mutex` 在真实并发下会成为串行点 | `mysql/EvolutionStateStore.cj:41-119`；`postgres/EvolutionStateStore.cj:46-124` 等 | 锁等待时长、并发线程数 | 多线程压 `get/save/processedAmong`（例如 8 线程 × 1k 次），线程状态看 BLOCKED/WAITING 时长（`cjprof` 的 CPU profile 看不出锁竞争） |
| 3 | MySQL `MYVECTOR_IS_ANN` 的过滤数组规模是召回延迟主因子 | `f_llm/src/dao/mysql/MemoryDAO.cj:49-66` | 用户记忆条数 vs 查询延迟曲线 | 造 1k/10k/100k 条记忆，逐档记录 `searchDense` P50/P95 与慢日志 |
| 4 | 空 `JSON_ARRAYAGG`（NULL filter）会让 MyVector 报错而不是返回空集 | `f_llm/src/dao/mysql/MemoryDAO.cj:49,65` | MyVector 组件对 NULL filter 的实际行为 | 对一个零记忆的 `user_id` 调 `searchDense`，记录返回/异常 |
| 5 | `Box` 写法可以整体消除（取决于 `synchronized` 是否返回值） | 见「优化可行性方案 · 堆内存」 | `std.sync.synchronized` 的签名 | 查 `std.sync` 文档或看 `sdk` 里 `synchronized` 的声明；再决定是删 box 还是换 `struct` |

<!-- 第 24 部分 -->

| # | 假设 | 位置 | 缺什么数据 | 怎么采 |
| --- | --- | --- | --- | --- |
| 1 | 首次 `FunctionMediator` 调用在 `mutex` 内构造全部工具 bean，N 个 bean 的构造 + schema 生成可能达数十毫秒到秒级，且并发首调用全部串行 | `f_llm/src/tool/FunctionMediator.cj:94-122` | 单个 bean 构造耗时、N、并发首调用排队时长 | 在 `:99` 前后打分段计时，跑「冷启动 + 8 线程同时 `FunctionMediator.call`」，记录 P50/P99 |
| 2 | `CommandFunction` 的子进程启动（`Inherit` 重定向下无输出捕获）在工具体感延迟中占比高，尤其短命令 | `f_llm/src/tool/CommandFunction.cj:54-56` | 单次 `executeWithOutput` 耗时分布、命令长度分布 | `cjprof` 跑 100 条真实命令；同时作为「命令输出恒空」那条改 `Pipe` 之前的基线 |
| 3 | `PostgresTokenUsageSaver.saveTokenUsage` 每次聊天都 `dao<PostgresTokenUsageDAO>('postgres')` 现取 DAO，属每请求固定开销 | `f_llm/src/store/postgres/TokenUsageSaver.cj:33-37` | `dao<>()` 单次耗时、每会话调用次数 | 在 `saveTokenUsage` 内计时，跑 10 分钟稳态负载取 P95；对照「构造期缓存 DAO 字段」的改后数据 |
| 4 | `readFile` 的 `read()` 每行 `String` + `StringGenerator` 分配是 GC 抖动来源 | `f_llm/src/tool/FileReadingFunction.cj:146-161` | 每轮分配量、GC 次数、单次调用 CPU 占比 | `cjprof heap` 跑 100MB / 100 万行文件，对比 `heat` 前后的 `getAllocatedHeapSize()` |
| 5 | local mode 用在 `read()` 的临时行串上可降峰值（对象不逃逸出 `read`） | `f_llm/src/tool/FileReadingFunction.cj:152-160` | 峰值内存与 local region 占用 | 按 `--experimental --enable-local-mode` 改前后各 10 轮，比 `getUsedHeapSize()` 峰值与 `getAllocatedLocalObjectSize()`；注意 `String` 需 local 构造重载 |

<!-- 第 25 部分 -->

| # | 假设 | 位置 | 缺什么数据 | 怎么采 |
| --- | --- | --- | --- | --- |
| 1 | `truncateBytes` 的逐 `rune.toString()` + `StringBuilder` 扩容是 `webFetch` 的主要 CPU/分配来源 | `f_llm/src/tool/WebFetchFunction.cj:76-94` | self time 占比、每次调用分配字节数 | `cjprof record` 跑 200 次 256KB 中文正文抓取；`cjprof heap` 看 `String` 分配占比 |
| 2 | `renderPage` 双份拼接的峰值内存与并发度线性相关，是 RSS 尖峰来源之一 | `f_llm/src/tool/WebFetchFunction.cj:69-73` | 峰值 RSS / heapUsed、并发 8 下的曲线 | 8 线程各跑 100 次 256KB 抓取，记录 `getUsedHeapSize()` 峰值（改前 / 改后同输入） |
| 3 | `pickConf` 的候选重建与逐条加锁在工具密集场景可测 | `f_llm/src/tool/WebSearchFunction.cj:73-94` | 单次 `pickConf` 耗时、每轮对话调用次数 | 在 `pickConf` 内分段计时，20 条 conf、10 万次循环取 P95；`cjprof` 对照 `SearchProviderRegistry.get` 占比 |
| 4 | `LLMCandidateProvider.candidates()` 的 supplier 是否每次真查库（决定假设 3 的上限） | `f_llm/src/llm/LLMCandidateProvider.cj:52-57` | supplier 默认实现与缓存策略 | 读 `LLMConfsHolder` 的 supplier 注入处并加计数埋点，跑 10 分钟稳态 |

## 文件覆盖

> 与 `files/f_llm.txt` 一一对应；分部分报告逐文件确认已读。

| # | 文件 | 类型 | 已读 | 说明 |
| --- | --- | --- | --- | --- |
| 1 | `f_llm/README.md` | .md | ✅ | — |
| 2 | `f_llm/README_en.md` | .md | ✅ | — |
| 3 | `f_llm/doc/content-store.md` | .md | ✅ | — |
| 4 | `f_llm/doc/dev-env.md` | .md | ✅ | — |
| 5 | `f_llm/doc/f_llm-memory-design.md` | .md | ✅ | — |
| 6 | `f_llm/doc/f_llm.md` | .md | ✅ | — |
| 7 | `f_llm/doc/known-limitations.md` | .md | ✅ | — |
| 8 | `f_llm/doc/loom.md` | .md | ✅ | — |
| 9 | `f_llm/doc/perf-baseline.md` | .md | ✅ | — |
| 10 | `f_llm/doc/retrieval-eval.md` | .md | ✅ | — |
| 11 | `f_llm/doc/spec/add-channel-mediator/design.md` | .md | ✅ | — |
| 12 | `f_llm/doc/spec/add-channel-mediator/proposal.md` | .md | ✅ | — |
| 13 | `f_llm/doc/spec/add-channel-mediator/specs/platform-channel/spec.md` | .md | ✅ | — |
| 14 | `f_llm/doc/spec/add-channel-mediator/tasks.md` | .md | ✅ | — |
| 15 | `f_llm/doc/spec/add-loom-a2a/design.md` | .md | ✅ | — |
| 16 | `f_llm/doc/spec/add-loom-a2a/proposal.md` | .md | ✅ | — |
| 17 | `f_llm/doc/spec/add-loom-a2a/specs/loom-a2a/spec.md` | .md | ✅ | — |
| 18 | `f_llm/doc/spec/add-loom-a2a/tasks.md` | .md | ✅ | — |
| 19 | `f_llm/doc/spec/add-loom-supervisor/design.md` | .md | ✅ | — |
| 20 | `f_llm/doc/spec/add-loom-supervisor/proposal.md` | .md | ✅ | — |
| 21 | `f_llm/doc/spec/add-loom-supervisor/specs/loom-supervisor/spec.md` | .md | ✅ | — |
| 22 | `f_llm/doc/spec/add-loom-supervisor/tasks.md` | .md | ✅ | — |
| 23 | `f_llm/doc/spec/archive/2026-10-30-f-llm-memory-storage/design.md` | .md | ✅ | — |
| 24 | `f_llm/doc/spec/archive/2026-10-30-f-llm-memory-storage/proposal.md` | .md | ✅ | — |
| 25 | `f_llm/doc/spec/archive/2026-10-30-f-llm-memory-storage/specs/llm-content-store/spec.md` | .md | ✅ | — |
| 26 | `f_llm/doc/spec/archive/2026-10-30-f-llm-memory-storage/specs/llm-meta-store/spec.md` | .md | ✅ | — |
| 27 | `f_llm/doc/spec/archive/2026-10-30-f-llm-memory-storage/tasks.md` | .md | ✅ | — |
| 28 | `f_llm/doc/spec/archive/2026-10-31-f-llm-store-wiring/design.md` | .md | ✅ | — |
| 29 | `f_llm/doc/spec/archive/2026-10-31-f-llm-store-wiring/proposal.md` | .md | ✅ | — |
| 30 | `f_llm/doc/spec/archive/2026-10-31-f-llm-store-wiring/specs/llm-store-wiring/spec.md` | .md | ✅ | — |
| 31 | `f_llm/doc/spec/archive/2026-10-31-f-llm-store-wiring/tasks.md` | .md | ✅ | — |
| 32 | `f_llm/doc/spec/cover-loom-test-gaps/design.md` | .md | ✅ | — |
| 33 | `f_llm/doc/spec/cover-loom-test-gaps/proposal.md` | .md | ✅ | — |
| 34 | `f_llm/doc/spec/cover-loom-test-gaps/specs/loom-flow/spec.md` | .md | ✅ | — |
| 35 | `f_llm/doc/spec/cover-loom-test-gaps/tasks.md` | .md | ✅ | — |
| 36 | `f_llm/doc/spec/f-llm-openai-compat/design.md` | .md | ✅ | — |
| 37 | `f_llm/doc/spec/f-llm-openai-compat/proposal.md` | .md | ✅ | — |
| 38 | `f_llm/doc/spec/f-llm-openai-compat/specs/http-sse-client/spec.md` | .md | ✅ | — |
| 39 | `f_llm/doc/spec/f-llm-openai-compat/specs/llm-balance-query/spec.md` | .md | ✅ | — |
| 40 | `f_llm/doc/spec/f-llm-openai-compat/specs/llm-conf-routing/spec.md` | .md | ✅ | — |
| 41 | `f_llm/doc/spec/f-llm-openai-compat/specs/llm-context-pruning/spec.md` | .md | ✅ | — |
| 42 | `f_llm/doc/spec/f-llm-openai-compat/specs/llm-protocol-compat/spec.md` | .md | ✅ | — |
| 43 | `f_llm/doc/spec/f-llm-openai-compat/specs/llm-tool-calling/spec.md` | .md | ✅ | — |
| 44 | `f_llm/doc/spec/f-llm-openai-compat/tasks.md` | .md | ✅ | — |
| 45 | `f_llm/doc/spec/fix-channel-attachment-safety/design.md` | .md | ✅ | — |
| 46 | `f_llm/doc/spec/fix-channel-attachment-safety/proposal.md` | .md | ✅ | — |
| 47 | `f_llm/doc/spec/fix-channel-attachment-safety/specs/platform-channel/spec.md` | .md | ✅ | — |
| 48 | `f_llm/doc/spec/fix-channel-attachment-safety/tasks.md` | .md | ✅ | — |
| 49 | `f_llm/doc/spec/fix-channel-robustness/design.md` | .md | ✅ | — |
| 50 | `f_llm/doc/spec/fix-channel-robustness/proposal.md` | .md | ✅ | — |
| 51 | `f_llm/doc/spec/fix-channel-robustness/specs/platform-channel/spec.md` | .md | ✅ | — |
| 52 | `f_llm/doc/spec/fix-channel-robustness/tasks.md` | .md | ✅ | — |
| 53 | `f_llm/doc/spec/fix-evolution-watermark/design.md` | .md | ✅ | — |
| 54 | `f_llm/doc/spec/fix-evolution-watermark/proposal.md` | .md | ✅ | — |
| 55 | `f_llm/doc/spec/fix-evolution-watermark/specs/loom-flow/spec.md` | .md | ✅ | — |
| 56 | `f_llm/doc/spec/fix-evolution-watermark/tasks.md` | .md | ✅ | — |
| 57 | `f_llm/doc/spec/fix-loom-experience-persona/design.md` | .md | ✅ | — |
| 58 | `f_llm/doc/spec/fix-loom-experience-persona/proposal.md` | .md | ✅ | — |
| 59 | `f_llm/doc/spec/fix-loom-experience-persona/specs/loom-flow/spec.md` | .md | ✅ | — |
| 60 | `f_llm/doc/spec/fix-loom-experience-persona/tasks.md` | .md | ✅ | — |
| 61 | `f_llm/doc/spec/fix-loom-extract-data-loss/design.md` | .md | ✅ | — |
| 62 | `f_llm/doc/spec/fix-loom-extract-data-loss/proposal.md` | .md | ✅ | — |
| 63 | `f_llm/doc/spec/fix-loom-extract-data-loss/specs/loom-flow/spec.md` | .md | ✅ | — |
| 64 | `f_llm/doc/spec/fix-loom-extract-data-loss/tasks.md` | .md | ✅ | — |
| 65 | `f_llm/doc/spec/fix-loom-memory-owner/design.md` | .md | ✅ | — |
| 66 | `f_llm/doc/spec/fix-loom-memory-owner/proposal.md` | .md | ✅ | — |
| 67 | `f_llm/doc/spec/fix-loom-memory-owner/specs/loom-flow/spec.md` | .md | ✅ | — |
| 68 | `f_llm/doc/spec/fix-loom-memory-owner/tasks.md` | .md | ✅ | — |
| 69 | `f_llm/doc/spec/fix-loom-persona-prompt/design.md` | .md | ✅ | — |
| 70 | `f_llm/doc/spec/fix-loom-persona-prompt/proposal.md` | .md | ✅ | — |
| 71 | `f_llm/doc/spec/fix-loom-persona-prompt/specs/loom-flow/spec.md` | .md | ✅ | — |
| 72 | `f_llm/doc/spec/fix-loom-persona-prompt/tasks.md` | .md | ✅ | — |
| 73 | `f_llm/doc/spec/fix-loom-read-path/design.md` | .md | ✅ | — |
| 74 | `f_llm/doc/spec/fix-loom-read-path/proposal.md` | .md | ✅ | — |
| 75 | `f_llm/doc/spec/fix-loom-read-path/specs/loom-flow/spec.md` | .md | ✅ | — |
| 76 | `f_llm/doc/spec/fix-loom-read-path/tasks.md` | .md | ✅ | — |
| 77 | `f_llm/doc/spec/fix-loom-store-gateway-reuse/design.md` | .md | ✅ | — |
| 78 | `f_llm/doc/spec/fix-loom-store-gateway-reuse/proposal.md` | .md | ✅ | — |
| 79 | `f_llm/doc/spec/fix-loom-store-gateway-reuse/specs/loom-flow/spec.md` | .md | ✅ | — |
| 80 | `f_llm/doc/spec/fix-loom-store-gateway-reuse/tasks.md` | .md | ✅ | — |
| 81 | `f_llm/doc/spec/fix-loom-supervisor-lifecycle/design.md` | .md | ✅ | — |
| 82 | `f_llm/doc/spec/fix-loom-supervisor-lifecycle/proposal.md` | .md | ✅ | — |
| 83 | `f_llm/doc/spec/fix-loom-supervisor-lifecycle/specs/loom-supervisor/spec.md` | .md | ✅ | — |
| 84 | `f_llm/doc/spec/fix-loom-supervisor-lifecycle/tasks.md` | .md | ✅ | — |
| 85 | `f_llm/doc/spec/fix-loom-tool-coverage/design.md` | .md | ✅ | — |
| 86 | `f_llm/doc/spec/fix-loom-tool-coverage/proposal.md` | .md | ✅ | — |
| 87 | `f_llm/doc/spec/fix-loom-tool-coverage/specs/loom-flow/spec.md` | .md | ✅ | — |
| 88 | `f_llm/doc/spec/fix-loom-tool-coverage/tasks.md` | .md | ✅ | — |
| 89 | `f_llm/doc/spec/fix-memory-write-consistency/design.md` | .md | ✅ | — |
| 90 | `f_llm/doc/spec/fix-memory-write-consistency/proposal.md` | .md | ✅ | — |
| 91 | `f_llm/doc/spec/fix-memory-write-consistency/specs/loom-flow/spec.md` | .md | ✅ | — |
| 92 | `f_llm/doc/spec/fix-memory-write-consistency/tasks.md` | .md | ✅ | — |
| 93 | `f_llm/doc/spec/llm-content-store/spec.md` | .md | ✅ | — |
| 94 | `f_llm/doc/spec/llm-meta-store/spec.md` | .md | ✅ | — |
| 95 | `f_llm/doc/spec/llm-store-wiring/spec.md` | .md | ✅ | — |
| 96 | `f_llm/doc/spec/local-mode-f-llm-knowledge-chunker/design.md` | .md | ✅ | — |
| 97 | `f_llm/doc/spec/local-mode-f-llm-knowledge-chunker/proposal.md` | .md | ✅ | — |
| 98 | `f_llm/doc/spec/local-mode-f-llm-knowledge-chunker/specs/llm-knowledge-chunking/spec.md` | .md | ✅ | — |
| 99 | `f_llm/doc/spec/local-mode-f-llm-knowledge-chunker/tasks.md` | .md | ✅ | — |
| 100 | `f_llm/doc/spec/perf-loom-render-context/design.md` | .md | ✅ | — |
| 101 | `f_llm/doc/spec/perf-loom-render-context/proposal.md` | .md | ✅ | — |
| 102 | `f_llm/doc/spec/perf-loom-render-context/specs/loom-flow/spec.md` | .md | ✅ | — |
| 103 | `f_llm/doc/spec/perf-loom-render-context/tasks.md` | .md | ✅ | — |
| 104 | `f_llm/doc/spec/perf-retrieval-candidates/design.md` | .md | ✅ | — |
| 105 | `f_llm/doc/spec/perf-retrieval-candidates/proposal.md` | .md | ✅ | — |
| 106 | `f_llm/doc/spec/perf-retrieval-candidates/specs/loom-flow/spec.md` | .md | ✅ | — |
| 107 | `f_llm/doc/spec/perf-retrieval-candidates/tasks.md` | .md | ✅ | — |
| 108 | `f_llm/doc/spec/refactor-retrieval-scoring/design.md` | .md | ✅ | — |
| 109 | `f_llm/doc/spec/refactor-retrieval-scoring/proposal.md` | .md | ✅ | — |
| 110 | `f_llm/doc/spec/refactor-retrieval-scoring/specs/loom-flow/spec.md` | .md | ✅ | — |
| 111 | `f_llm/doc/spec/refactor-retrieval-scoring/tasks.md` | .md | ✅ | — |
| 112 | `f_llm/doc/todo.md` | .md | ✅ | — |
| 113 | `f_llm/src/agents/AgentEvent.cj` | .cj | ✅ | — |
| 114 | `f_llm/src/agents/AgentEventData.cj` | .cj | ✅ | — |
| 115 | `f_llm/src/agents/AgentTask.cj` | .cj | ✅ | — |
| 116 | `f_llm/src/agents/imports.cj` | .cj | ✅ | — |
| 117 | `f_llm/src/balance/BalanceQuerier.cj` | .cj | ✅ | — |
| 118 | `f_llm/src/balance/BalanceQueriers.cj` | .cj | ✅ | — |
| 119 | `f_llm/src/balance/BalanceUnits.cj` | .cj | ✅ | — |
| 120 | `f_llm/src/balance/Balance_test.cj` | .cj | ✅ | — |
| 121 | `f_llm/src/balance/sign/Signers.cj` | .cj | ✅ | — |
| 122 | `f_llm/src/channel/ChannelBootstrap.cj` | .cj | ✅ | — |
| 123 | `f_llm/src/channel/ChannelBootstrap_test.cj` | .cj | ✅ | — |
| 124 | `f_llm/src/channel/ChannelContract.cj` | .cj | ✅ | — |
| 125 | `f_llm/src/channel/ChannelFunctions.cj` | .cj | ✅ | — |
| 126 | `f_llm/src/channel/ChannelFunctions_test.cj` | .cj | ✅ | — |
| 127 | `f_llm/src/channel/ChannelMediator.cj` | .cj | ✅ | — |
| 128 | `f_llm/src/channel/ChannelMediator_test.cj` | .cj | ✅ | — |
| 129 | `f_llm/src/channel/EmailChannel.cj` | .cj | ✅ | — |
| 130 | `f_llm/src/channel/EmailChannel_test.cj` | .cj | ✅ | — |
| 131 | `f_llm/src/config/LLMConfig.cj` | .cj | ✅ | — |
| 132 | `f_llm/src/config/LLMConfig_test.cj` | .cj | ✅ | — |
| 133 | `f_llm/src/constant/ConstantSize.cj` | .cj | ✅ | — |
| 134 | `f_llm/src/constant/ContextPrunerName.cj` | .cj | ✅ | — |
| 135 | `f_llm/src/constant/KnowledgeKind.cj` | .cj | ✅ | — |
| 136 | `f_llm/src/constant/LLMAgent.cj` | .cj | ✅ | — |
| 137 | `f_llm/src/constant/LLMType.cj` | .cj | ✅ | — |
| 138 | `f_llm/src/constant/ModelName.cj` | .cj | ✅ | — |
| 139 | `f_llm/src/constant/ModelNames.cj` | .cj | ✅ | — |
| 140 | `f_llm/src/constant/ModelNames_test.cj` | .cj | ✅ | — |
| 141 | `f_llm/src/constant/Role.cj` | .cj | ✅ | — |
| 142 | `f_llm/src/constant/SkillType.cj` | .cj | ✅ | — |
| 143 | `f_llm/src/constant/SpecKind.cj` | .cj | ✅ | — |
| 144 | `f_llm/src/constant/SpecialAgentId.cj` | .cj | ✅ | — |
| 145 | `f_llm/src/constant/SummaryActionKind.cj` | .cj | ✅ | — |
| 146 | `f_llm/src/constant/ThinkingSwitch.cj` | .cj | ✅ | — |
| 147 | `f_llm/src/constant/TodoStatus.cj` | .cj | ✅ | — |
| 148 | `f_llm/src/constant/ToolType.cj` | .cj | ✅ | — |
| 149 | `f_llm/src/constant/imports.cj` | .cj | ✅ | — |
| 150 | `f_llm/src/dao/LLMConfDAO.cj` | .cj | ✅ | — |
| 151 | `f_llm/src/dao/mysql/EvolutionDAO.cj` | .cj | ✅ | — |
| 152 | `f_llm/src/dao/mysql/EvolutionLeaseDAO.cj` | .cj | ✅ | — |
| 153 | `f_llm/src/dao/mysql/EvolutionStateDAO.cj` | .cj | ✅ | — |
| 154 | `f_llm/src/dao/mysql/KindDAO.cj` | .cj | ✅ | — |
| 155 | `f_llm/src/dao/mysql/KnowledgeDAO.cj` | .cj | ✅ | — |
| 156 | `f_llm/src/dao/mysql/LoomDAO.cj` | .cj | ✅ | — |
| 157 | `f_llm/src/dao/mysql/MemoryDAO.cj` | .cj | ✅ | — |
| 158 | `f_llm/src/dao/mysql/MetaDAO.cj` | .cj | ✅ | — |
| 159 | `f_llm/src/dao/mysql/TokenUsageDAO.cj` | .cj | ✅ | — |
| 160 | `f_llm/src/dao/postgres/EvolutionDAO.cj` | .cj | ✅ | — |
| 161 | `f_llm/src/dao/postgres/EvolutionLeaseDAO.cj` | .cj | ✅ | — |
| 162 | `f_llm/src/dao/postgres/EvolutionStateDAO.cj` | .cj | ✅ | — |
| 163 | `f_llm/src/dao/postgres/KindDAO.cj` | .cj | ✅ | — |
| 164 | `f_llm/src/dao/postgres/KnowledgeDAO.cj` | .cj | ✅ | — |
| 165 | `f_llm/src/dao/postgres/LoomDAO.cj` | .cj | ✅ | — |
| 166 | `f_llm/src/dao/postgres/MemoryDAO.cj` | .cj | ✅ | — |
| 167 | `f_llm/src/dao/postgres/MetaDAO.cj` | .cj | ✅ | — |
| 168 | `f_llm/src/dao/postgres/TokenUsageDAO.cj` | .cj | ✅ | — |
| 169 | `f_llm/src/embedding/BgeM3Codec_test.cj` | .cj | ✅ | — |
| 170 | `f_llm/src/embedding/BgeM3Transport.cj` | .cj | ✅ | — |
| 171 | `f_llm/src/embedding/BgeM3Transport_test.cj` | .cj | ✅ | — |
| 172 | `f_llm/src/embedding/DefaultEmbedder.cj` | .cj | ✅ | — |
| 173 | `f_llm/src/embedding/Embedding.cj` | .cj | ✅ | — |
| 174 | `f_llm/src/embedding/EmbeddingParam.cj` | .cj | ✅ | — |
| 175 | `f_llm/src/embedding/EmbeddingResp.cj` | .cj | ✅ | — |
| 176 | `f_llm/src/embedding/Embedding_test.cj` | .cj | ✅ | — |
| 177 | `f_llm/src/embedding/HttpEmbedder.cj` | .cj | ✅ | — |
| 178 | `f_llm/src/embedding/HttpEmbedder_test.cj` | .cj | ✅ | — |
| 179 | `f_llm/src/embedding/LlmEmbeddingTransport.cj` | .cj | ✅ | — |
| 180 | `f_llm/src/embedding/exception/LLMException.cj` | .cj | ✅ | — |
| 181 | `f_llm/src/embedding/exception/RoleException.cj` | .cj | ✅ | — |
| 182 | `f_llm/src/embedding/imports.cj` | .cj | ✅ | — |
| 183 | `f_llm/src/exception/FunctionCallingException.cj` | .cj | ✅ | — |
| 184 | `f_llm/src/exception/FunctionNotFoundException.cj` | .cj | ✅ | — |
| 185 | `f_llm/src/exception/IllegalPathException.cj` | .cj | ✅ | — |
| 186 | `f_llm/src/exception/LLMException.cj` | .cj | ✅ | — |
| 187 | `f_llm/src/exception/RoleException.cj` | .cj | ✅ | — |
| 188 | `f_llm/src/exception/SkillNotFoundException.cj` | .cj | ✅ | — |
| 189 | `f_llm/src/finder/AgentsFinder.cj` | .cj | ✅ | — |
| 190 | `f_llm/src/finder/CodeFinder.cj` | .cj | ✅ | — |
| 191 | `f_llm/src/finder/EventFinder.cj` | .cj | ✅ | — |
| 192 | `f_llm/src/finder/KnowledgeFinder.cj` | .cj | ✅ | — |
| 193 | `f_llm/src/finder/MemorySummaryFinder.cj` | .cj | ✅ | — |
| 194 | `f_llm/src/finder/OrganizationFinder.cj` | .cj | ✅ | — |
| 195 | `f_llm/src/finder/SkillsFinder.cj` | .cj | ✅ | — |
| 196 | `f_llm/src/finder/SpecificationFinder.cj` | .cj | ✅ | — |
| 197 | `f_llm/src/finder/TodoFinder.cj` | .cj | ✅ | — |
| 198 | `f_llm/src/finder/TokenUsageSaver.cj` | .cj | ✅ | — |
| 199 | `f_llm/src/finder/imports.cj` | .cj | ✅ | — |
| 200 | `f_llm/src/llm.cj` | .cj | ✅ | — |
| 201 | `f_llm/src/llm/CallLogger.cj` | .cj | ✅ | — |
| 202 | `f_llm/src/llm/ChatCompletionsMapper.cj` | .cj | ✅ | — |
| 203 | `f_llm/src/llm/ChatCompletionsMapper_test.cj` | .cj | ✅ | — |
| 204 | `f_llm/src/llm/ChatCompletionsResponse_test.cj` | .cj | ✅ | — |
| 205 | `f_llm/src/llm/ChatMessage.cj` | .cj | ✅ | — |
| 206 | `f_llm/src/llm/ChatStreamAccumulator.cj` | .cj | ✅ | — |
| 207 | `f_llm/src/llm/CircuitBreaker.cj` | .cj | ✅ | — |
| 208 | `f_llm/src/llm/CircuitBreaker_test.cj` | .cj | ✅ | — |
| 209 | `f_llm/src/llm/ContentPart.cj` | .cj | ✅ | — |
| 210 | `f_llm/src/llm/ContextPruner.cj` | .cj | ✅ | — |
| 211 | `f_llm/src/llm/ContextPrunerMediator.cj` | .cj | ✅ | — |
| 212 | `f_llm/src/llm/ContextPruner_test.cj` | .cj | ✅ | — |
| 213 | `f_llm/src/llm/LLM.cj` | .cj | ✅ | — |
| 214 | `f_llm/src/llm/LLMByName_test.cj` | .cj | ✅ | — |
| 215 | `f_llm/src/llm/LLMCandidateProvider.cj` | .cj | ✅ | — |
| 216 | `f_llm/src/llm/LLMConfs.cj` | .cj | ✅ | — |
| 217 | `f_llm/src/llm/LLMConfsHolder.cj` | .cj | ✅ | — |
| 218 | `f_llm/src/llm/LLMConfsHolder_test.cj` | .cj | ✅ | — |
| 219 | `f_llm/src/llm/LLMDelta.cj` | .cj | ✅ | — |
| 220 | `f_llm/src/llm/LLMErrorClassifier.cj` | .cj | ✅ | — |
| 221 | `f_llm/src/llm/LLMHooks.cj` | .cj | ✅ | — |
| 222 | `f_llm/src/llm/LLMParams.cj` | .cj | ✅ | — |
| 223 | `f_llm/src/llm/LLMResp.cj` | .cj | ✅ | — |
| 224 | `f_llm/src/llm/LLMSelection_test.cj` | .cj | ✅ | — |
| 225 | `f_llm/src/llm/LLMStreamTransport.cj` | .cj | ✅ | — |
| 226 | `f_llm/src/llm/LLMStream_test.cj` | .cj | ✅ | — |
| 227 | `f_llm/src/llm/LLMTransport.cj` | .cj | ✅ | — |
| 228 | `f_llm/src/llm/LLM_test.cj` | .cj | ✅ | — |
| 229 | `f_llm/src/llm/ModelCapabilities.cj` | .cj | ✅ | — |
| 230 | `f_llm/src/llm/ModelCapabilities_test.cj` | .cj | ✅ | — |
| 231 | `f_llm/src/llm/ResponsesMapper.cj` | .cj | ✅ | — |
| 232 | `f_llm/src/llm/ResponsesStreamAccumulator.cj` | .cj | ✅ | — |
| 233 | `f_llm/src/llm/TokenCounter.cj` | .cj | ✅ | — |
| 234 | `f_llm/src/llm/TokenizerParams.cj` | .cj | ✅ | — |
| 235 | `f_llm/src/llm/advanced_params.cj` | .cj | ✅ | — |
| 236 | `f_llm/src/llm/imports.cj` | .cj | ✅ | — |
| 237 | `f_llm/src/llm/openai/DeepSeekDialect.cj` | .cj | ✅ | — |
| 238 | `f_llm/src/llm/openai/DeepSeekDialect_test.cj` | .cj | ✅ | — |
| 239 | `f_llm/src/llm/openai/ProviderDialect.cj` | .cj | ✅ | — |
| 240 | `f_llm/src/llm/openai/ProviderDialect_test.cj` | .cj | ✅ | — |
| 241 | `f_llm/src/llm/openai/ProviderDialects.cj` | .cj | ✅ | — |
| 242 | `f_llm/src/llm/openai/ProviderDialects_test.cj` | .cj | ✅ | — |
| 243 | `f_llm/src/loom/A2aBridge.cj` | .cj | ✅ | — |
| 244 | `f_llm/src/loom/A2aBridge_test.cj` | .cj | ✅ | — |
| 245 | `f_llm/src/loom/A2aCallFunction.cj` | .cj | ✅ | — |
| 246 | `f_llm/src/loom/BackgroundTasks.cj` | .cj | ✅ | — |
| 247 | `f_llm/src/loom/BackgroundTasks_test.cj` | .cj | ✅ | — |
| 248 | `f_llm/src/loom/CodeGen.cj` | .cj | ✅ | — |
| 249 | `f_llm/src/loom/CodeGen_test.cj` | .cj | ✅ | — |
| 250 | `f_llm/src/loom/DefaultLoomHost.cj` | .cj | ✅ | — |
| 251 | `f_llm/src/loom/DefaultLoomHost_test.cj` | .cj | ✅ | — |
| 252 | `f_llm/src/loom/EvolutionLeases.cj` | .cj | ✅ | — |
| 253 | `f_llm/src/loom/EvolutionStateStores.cj` | .cj | ✅ | — |
| 254 | `f_llm/src/loom/EvolutionStores.cj` | .cj | ✅ | — |
| 255 | `f_llm/src/loom/FStoreLoomStore.cj` | .cj | ✅ | — |
| 256 | `f_llm/src/loom/FStoreLoomStore_test.cj` | .cj | ✅ | — |
| 257 | `f_llm/src/loom/JitTicktockTask.cj` | .cj | ✅ | — |
| 258 | `f_llm/src/loom/JitTicktockTask_test.cj` | .cj | ✅ | — |
| 259 | `f_llm/src/loom/LoomAgent.cj` | .cj | ✅ | — |
| 260 | `f_llm/src/loom/LoomBootstrap.cj` | .cj | ✅ | — |
| 261 | `f_llm/src/loom/LoomBootstrap_test.cj` | .cj | ✅ | — |
| 262 | `f_llm/src/loom/LoomCharacterScope.cj` | .cj | ✅ | — |
| 263 | `f_llm/src/loom/LoomCompiler.cj` | .cj | ✅ | — |
| 264 | `f_llm/src/loom/LoomCompiler_test.cj` | .cj | ✅ | — |
| 265 | `f_llm/src/loom/LoomContextLog.cj` | .cj | ✅ | — |
| 266 | `f_llm/src/loom/LoomContextMemory_test.cj` | .cj | ✅ | — |
| 267 | `f_llm/src/loom/LoomDefaults.cj` | .cj | ✅ | — |
| 268 | `f_llm/src/loom/LoomFunctions.cj` | .cj | ✅ | — |
| 269 | `f_llm/src/loom/LoomFunctions_test.cj` | .cj | ✅ | — |
| 270 | `f_llm/src/loom/LoomHostApi.cj` | .cj | ✅ | — |
| 271 | `f_llm/src/loom/LoomJitBridge.cj` | .cj | ✅ | — |
| 272 | `f_llm/src/loom/LoomMemoryE2E_test.cj` | .cj | ✅ | — |
| 273 | `f_llm/src/loom/LoomMemoryPolicy.cj` | .cj | ✅ | — |
| 274 | `f_llm/src/loom/LoomPersona_test.cj` | .cj | ✅ | — |
| 275 | `f_llm/src/loom/LoomPromptDesign_test.cj` | .cj | ✅ | — |
| 276 | `f_llm/src/loom/LoomRegistry.cj` | .cj | ✅ | — |
| 277 | `f_llm/src/loom/LoomRegistry_test.cj` | .cj | ✅ | — |
| 278 | `f_llm/src/loom/LoomRenderPerf_test.cj` | .cj | ✅ | — |
| 279 | `f_llm/src/loom/LoomRunner.cj` | .cj | ✅ | — |
| 280 | `f_llm/src/loom/LoomRunner_test.cj` | .cj | ✅ | — |
| 281 | `f_llm/src/loom/LoomScheduler.cj` | .cj | ✅ | — |
| 282 | `f_llm/src/loom/LoomService.cj` | .cj | ✅ | — |
| 283 | `f_llm/src/loom/LoomServiceSkills_test.cj` | .cj | ✅ | — |
| 284 | `f_llm/src/loom/LoomService_test.cj` | .cj | ✅ | — |
| 285 | `f_llm/src/loom/LoomStoreGateway.cj` | .cj | ✅ | — |
| 286 | `f_llm/src/loom/LoomStoreGateway_test.cj` | .cj | ✅ | — |
| 287 | `f_llm/src/loom/LoomTimeout.cj` | .cj | ✅ | — |
| 288 | `f_llm/src/loom/LoomWiring.cj` | .cj | ✅ | — |
| 289 | `f_llm/src/loom/LoomWiringChannel_test.cj` | .cj | ✅ | — |
| 290 | `f_llm/src/loom/LoomWiringGateway_test.cj` | .cj | ✅ | — |
| 291 | `f_llm/src/loom/LoomWiringSupervisor_test.cj` | .cj | ✅ | — |
| 292 | `f_llm/src/loom/LoomWiring_test.cj` | .cj | ✅ | — |
| 293 | `f_llm/src/loom/Plan.cj` | .cj | ✅ | — |
| 294 | `f_llm/src/loom/Plan_test.cj` | .cj | ✅ | — |
| 295 | `f_llm/src/loom/Planner.cj` | .cj | ✅ | — |
| 296 | `f_llm/src/loom/Planner_test.cj` | .cj | ✅ | — |
| 297 | `f_llm/src/loom/PromptCapabilities.cj` | .cj | ✅ | — |
| 298 | `f_llm/src/loom/Prompts.cj` | .cj | ✅ | — |
| 299 | `f_llm/src/loom/RetrievalEval.cj` | .cj | ✅ | — |
| 300 | `f_llm/src/loom/RetrievalEvalManual_test.cj` | .cj | ✅ | — |
| 301 | `f_llm/src/loom/RetrievalEvalRunner.cj` | .cj | ✅ | — |
| 302 | `f_llm/src/loom/RetrievalEval_test.cj` | .cj | ✅ | — |
| 303 | `f_llm/src/loom/RetrievalQuality_test.cj` | .cj | ✅ | — |
| 304 | `f_llm/src/loom/ScheduleFunctions.cj` | .cj | ✅ | — |
| 305 | `f_llm/src/loom/ScheduleFunctions_test.cj` | .cj | ✅ | — |
| 306 | `f_llm/src/loom/SkillCatalog.cj` | .cj | ✅ | — |
| 307 | `f_llm/src/loom/SkillCatalog_test.cj` | .cj | ✅ | — |
| 308 | `f_llm/src/loom/SkillEvolutionJob.cj` | .cj | ✅ | — |
| 309 | `f_llm/src/loom/SkillEvolutionJob_test.cj` | .cj | ✅ | — |
| 310 | `f_llm/src/loom/SkillEvolutionLedger.cj` | .cj | ✅ | — |
| 311 | `f_llm/src/loom/SkillEvolutionLedger_test.cj` | .cj | ✅ | — |
| 312 | `f_llm/src/loom/SkillEvolutionPolicy.cj` | .cj | ✅ | — |
| 313 | `f_llm/src/loom/SkillEvolutionPolicy_test.cj` | .cj | ✅ | — |
| 314 | `f_llm/src/loom/SkillGate.cj` | .cj | ✅ | — |
| 315 | `f_llm/src/loom/SkillGate_test.cj` | .cj | ✅ | — |
| 316 | `f_llm/src/loom/SkillImport.cj` | .cj | ✅ | — |
| 317 | `f_llm/src/loom/SkillImport_test.cj` | .cj | ✅ | — |
| 318 | `f_llm/src/loom/SkillMatcher.cj` | .cj | ✅ | — |
| 319 | `f_llm/src/loom/SkillMatcher_test.cj` | .cj | ✅ | — |
| 320 | `f_llm/src/loom/SkillNamer.cj` | .cj | ✅ | — |
| 321 | `f_llm/src/loom/SqlLoomStore.cj` | .cj | ✅ | — |
| 322 | `f_llm/src/loom/StepSourceCodec_test.cj` | .cj | ✅ | — |
| 323 | `f_llm/src/loom/StoreFunctions.cj` | .cj | ✅ | — |
| 324 | `f_llm/src/loom/StoreFunctions_test.cj` | .cj | ✅ | — |
| 325 | `f_llm/src/loom/Supervisor.cj` | .cj | ✅ | — |
| 326 | `f_llm/src/loom/Supervisor_test.cj` | .cj | ✅ | — |
| 327 | `f_llm/src/loom/ToolCatalog.cj` | .cj | ✅ | — |
| 328 | `f_llm/src/loom/ToolFunctions.cj` | .cj | ✅ | — |
| 329 | `f_llm/src/loom/ToolFunctions_test.cj` | .cj | ✅ | — |
| 330 | `f_llm/src/loom/ToolScope.cj` | .cj | ✅ | — |
| 331 | `f_llm/src/macros/ToolCall.cj` | .cj | ✅ | — |
| 332 | `f_llm/src/mcp/McpToolSource.cj` | .cj | ✅ | — |
| 333 | `f_llm/src/mcp/McpToolSource_test.cj` | .cj | ✅ | — |
| 334 | `f_llm/src/memory/FaithfulMemory.cj` | .cj | ✅ | — |
| 335 | `f_llm/src/memory/Memory.cj` | .cj | ✅ | — |
| 336 | `f_llm/src/memory/MemoryExtractor.cj` | .cj | ✅ | — |
| 337 | `f_llm/src/memory/MemoryRemember_test.cj` | .cj | ✅ | — |
| 338 | `f_llm/src/memory/imports.cj` | .cj | ✅ | — |
| 339 | `f_llm/src/model/Code.cj` | .cj | ✅ | — |
| 340 | `f_llm/src/model/CodeParam.cj` | .cj | ✅ | — |
| 341 | `f_llm/src/model/Knowledge.cj` | .cj | ✅ | — |
| 342 | `f_llm/src/model/KnowledgeParam.cj` | .cj | ✅ | — |
| 343 | `f_llm/src/model/SkillReferenceParam.cj` | .cj | ✅ | — |
| 344 | `f_llm/src/model/Specification.cj` | .cj | ✅ | — |
| 345 | `f_llm/src/model/entity/KnowledgeEntity.cj` | .cj | ✅ | — |
| 346 | `f_llm/src/model/entity/imports.cj` | .cj | ✅ | — |
| 347 | `f_llm/src/model/model.cj` | .cj | ✅ | — |
| 348 | `f_llm/src/model/po/Agent.cj` | .cj | ✅ | — |
| 349 | `f_llm/src/model/po/LLMConf.cj` | .cj | ✅ | — |
| 350 | `f_llm/src/model/po/LLMConfCodec.cj` | .cj | ✅ | — |
| 351 | `f_llm/src/model/po/LLMConf_test.cj` | .cj | ✅ | — |
| 352 | `f_llm/src/model/po/MemorySummary.cj` | .cj | ✅ | — |
| 353 | `f_llm/src/model/po/Skill.cj` | .cj | ✅ | — |
| 354 | `f_llm/src/model/po/SkillReference.cj` | .cj | ✅ | — |
| 355 | `f_llm/src/model/po/Todo.cj` | .cj | ✅ | — |
| 356 | `f_llm/src/model/po/TokenUsage.cj` | .cj | ✅ | — |
| 357 | `f_llm/src/search/DeepSeekSearchProvider.cj` | .cj | ✅ | — |
| 358 | `f_llm/src/search/DeepSeekSearchProvider_test.cj` | .cj | ✅ | — |
| 359 | `f_llm/src/search/SearchProvider.cj` | .cj | ✅ | — |
| 360 | `f_llm/src/search/SearchResult.cj` | .cj | ✅ | — |
| 361 | `f_llm/src/search/imports.cj` | .cj | ✅ | — |
| 362 | `f_llm/src/service/LLMConfService.cj` | .cj | ✅ | — |
| 363 | `f_llm/src/service/LLMConfService_test.cj` | .cj | ✅ | — |
| 364 | `f_llm/src/service/LLMConfSource.cj` | .cj | ✅ | — |
| 365 | `f_llm/src/service/LLMConfSource_test.cj` | .cj | ✅ | — |
| 366 | `f_llm/src/service/StoreMetaConfSource.cj` | .cj | ✅ | — |
| 367 | `f_llm/src/service/StoreMetaConfSource_test.cj` | .cj | ✅ | — |
| 368 | `f_llm/src/store/ColbertCodec.cj` | .cj | ✅ | — |
| 369 | `f_llm/src/store/ColbertCodec_test.cj` | .cj | ✅ | — |
| 370 | `f_llm/src/store/DeployPaths.cj` | .cj | ✅ | — |
| 371 | `f_llm/src/store/EvolutionLease.cj` | .cj | ✅ | — |
| 372 | `f_llm/src/store/EvolutionLease_test.cj` | .cj | ✅ | — |
| 373 | `f_llm/src/store/EvolutionStateStore.cj` | .cj | ✅ | — |
| 374 | `f_llm/src/store/EvolutionStateStore_test.cj` | .cj | ✅ | — |
| 375 | `f_llm/src/store/EvolutionStore.cj` | .cj | ✅ | — |
| 376 | `f_llm/src/store/EvolutionStore_test.cj` | .cj | ✅ | — |
| 377 | `f_llm/src/store/FStoreMetaStore.cj` | .cj | ✅ | — |
| 378 | `f_llm/src/store/FStoreMetaStore_test.cj` | .cj | ✅ | — |
| 379 | `f_llm/src/store/InMemoryStores.cj` | .cj | ✅ | — |
| 380 | `f_llm/src/store/KnowledgeChunker.cj` | .cj | ✅ | — |
| 381 | `f_llm/src/store/KnowledgeChunkerLocalModeBench_test.cj` | .cj | ✅ | — |
| 382 | `f_llm/src/store/KnowledgeChunkerLocalMode_test.cj` | .cj | ✅ | — |
| 383 | `f_llm/src/store/KnowledgeChunker_test.cj` | .cj | ✅ | — |
| 384 | `f_llm/src/store/KnowledgeIndexRebuilder.cj` | .cj | ✅ | — |
| 385 | `f_llm/src/store/KnowledgeIndexRebuilder_test.cj` | .cj | ✅ | — |
| 386 | `f_llm/src/store/KnowledgeSearch.cj` | .cj | ✅ | — |
| 387 | `f_llm/src/store/MemoryIndexRebuilder.cj` | .cj | ✅ | — |
| 388 | `f_llm/src/store/MemoryIndexRebuilder_test.cj` | .cj | ✅ | — |
| 389 | `f_llm/src/store/MemoryKinds.cj` | .cj | ✅ | — |
| 390 | `f_llm/src/store/MemoryKinds_test.cj` | .cj | ✅ | — |
| 391 | `f_llm/src/store/MemoryRepositories.cj` | .cj | ✅ | — |
| 392 | `f_llm/src/store/MemoryRepository.cj` | .cj | ✅ | — |
| 393 | `f_llm/src/store/MemoryStoreAdapter.cj` | .cj | ✅ | — |
| 394 | `f_llm/src/store/MetaStoreAdapter.cj` | .cj | ✅ | — |
| 395 | `f_llm/src/store/MySqlConnectivity_test.cj` | .cj | ✅ | — |
| 396 | `f_llm/src/store/PostgresMemoryStore.cj` | .cj | ✅ | — |
| 397 | `f_llm/src/store/PostgresMemoryStore_test.cj` | .cj | ✅ | — |
| 398 | `f_llm/src/store/PredefinedCharacters.cj` | .cj | ✅ | — |
| 399 | `f_llm/src/store/RetrievalScoring.cj` | .cj | ✅ | — |
| 400 | `f_llm/src/store/RetrievalScoring_test.cj` | .cj | ✅ | — |
| 401 | `f_llm/src/store/StoreConformance_test.cj` | .cj | ✅ | — |
| 402 | `f_llm/src/store/StoreContracts.cj` | .cj | ✅ | — |
| 403 | `f_llm/src/store/StoreModels.cj` | .cj | ✅ | — |
| 404 | `f_llm/src/store/StoreSettings.cj` | .cj | ✅ | — |
| 405 | `f_llm/src/store/StoreSettings_test.cj` | .cj | ✅ | — |
| 406 | `f_llm/src/store/Stores.cj` | .cj | ✅ | — |
| 407 | `f_llm/src/store/Stores_test.cj` | .cj | ✅ | — |
| 408 | `f_llm/src/store/VectorMath.cj` | .cj | ✅ | — |
| 409 | `f_llm/src/store/hydra/ContentStore.cj` | .cj | ✅ | — |
| 410 | `f_llm/src/store/hydra/EvolutionLease.cj` | .cj | ✅ | — |
| 411 | `f_llm/src/store/hydra/HttpTransport.cj` | .cj | ✅ | — |
| 412 | `f_llm/src/store/hydra/HydraRemote_test.cj` | .cj | ✅ | — |
| 413 | `f_llm/src/store/hydra/MemoryRepository.cj` | .cj | ✅ | — |
| 414 | `f_llm/src/store/hydra/MemoryRepository_test.cj` | .cj | ✅ | — |
| 415 | `f_llm/src/store/hydra/Transport.cj` | .cj | ✅ | — |
| 416 | `f_llm/src/store/it/BeanCondition_test.cj` | .cj | ✅ | — |
| 417 | `f_llm/src/store/it/ContentStoreAdapter_test.cj` | .cj | ✅ | — |
| 418 | `f_llm/src/store/it/CrossBackendConformance_test.cj` | .cj | ✅ | — |
| 419 | `f_llm/src/store/it/EvolutionStoreIT_test.cj` | .cj | ✅ | — |
| 420 | `f_llm/src/store/it/KindPersistence_test.cj` | .cj | ✅ | — |
| 421 | `f_llm/src/store/it/KnowledgeConformance_test.cj` | .cj | ✅ | — |
| 422 | `f_llm/src/store/it/LoomStore_test.cj` | .cj | ✅ | — |
| 423 | `f_llm/src/store/it/MetaConformance_test.cj` | .cj | ✅ | — |
| 424 | `f_llm/src/store/it/MetaStoreAdapter_test.cj` | .cj | ✅ | — |
| 425 | `f_llm/src/store/it/StoreWiring_test.cj` | .cj | ✅ | — |
| 426 | `f_llm/src/store/it/StoresBootstrap_test.cj` | .cj | ✅ | — |
| 427 | `f_llm/src/store/it/TokenUsageSaver_test.cj` | .cj | ✅ | — |
| 428 | `f_llm/src/store/mysql/ContentStore.cj` | .cj | ✅ | — |
| 429 | `f_llm/src/store/mysql/EvolutionLease.cj` | .cj | ✅ | — |
| 430 | `f_llm/src/store/mysql/EvolutionStateStore.cj` | .cj | ✅ | — |
| 431 | `f_llm/src/store/mysql/EvolutionStore.cj` | .cj | ✅ | — |
| 432 | `f_llm/src/store/mysql/KindPersistence.cj` | .cj | ✅ | — |
| 433 | `f_llm/src/store/mysql/KnowledgeStore.cj` | .cj | ✅ | — |
| 434 | `f_llm/src/store/mysql/MemoryRepository.cj` | .cj | ✅ | — |
| 435 | `f_llm/src/store/mysql/MetaStore.cj` | .cj | ✅ | — |
| 436 | `f_llm/src/store/mysql/MySqlMemoryRepository_test.cj` | .cj | ✅ | — |
| 437 | `f_llm/src/store/mysql/TokenUsageSaver.cj` | .cj | ✅ | — |
| 438 | `f_llm/src/store/postgres/ContentStore.cj` | .cj | ✅ | — |
| 439 | `f_llm/src/store/postgres/EvolutionLease.cj` | .cj | ✅ | — |
| 440 | `f_llm/src/store/postgres/EvolutionStateStore.cj` | .cj | ✅ | — |
| 441 | `f_llm/src/store/postgres/EvolutionStore.cj` | .cj | ✅ | — |
| 442 | `f_llm/src/store/postgres/KindPersistence.cj` | .cj | ✅ | — |
| 443 | `f_llm/src/store/postgres/KnowledgeStore.cj` | .cj | ✅ | — |
| 444 | `f_llm/src/store/postgres/MemoryRepository.cj` | .cj | ✅ | — |
| 445 | `f_llm/src/store/postgres/MetaStore.cj` | .cj | ✅ | — |
| 446 | `f_llm/src/store/postgres/PostgresMemoryRepository_test.cj` | .cj | ✅ | — |
| 447 | `f_llm/src/store/postgres/TokenUsageSaver.cj` | .cj | ✅ | — |
| 448 | `f_llm/src/tool/AbstractFileFunction.cj` | .cj | ✅ | — |
| 449 | `f_llm/src/tool/AnswerFunction.cj` | .cj | ✅ | — |
| 450 | `f_llm/src/tool/CommandFunction.cj` | .cj | ✅ | — |
| 451 | `f_llm/src/tool/ConsoleFunction.cj` | .cj | ✅ | — |
| 452 | `f_llm/src/tool/CurrentTimeFunction.cj` | .cj | ✅ | — |
| 453 | `f_llm/src/tool/FileReadingFunction.cj` | .cj | ✅ | — |
| 454 | `f_llm/src/tool/FileReplacingFunction.cj` | .cj | ✅ | — |
| 455 | `f_llm/src/tool/FileWritingFunction.cj` | .cj | ✅ | — |
| 456 | `f_llm/src/tool/FunctionCalling.cj` | .cj | ✅ | — |
| 457 | `f_llm/src/tool/FunctionDefinition.cj` | .cj | ✅ | — |
| 458 | `f_llm/src/tool/FunctionMediator.cj` | .cj | ✅ | — |
| 459 | `f_llm/src/tool/FunctionResult.cj` | .cj | ✅ | — |
| 460 | `f_llm/src/tool/LLMToolLoop.cj` | .cj | ✅ | — |
| 461 | `f_llm/src/tool/LLMToolLoop_test.cj` | .cj | ✅ | — |
| 462 | `f_llm/src/tool/MemoriesLoadingFunction.cj` | .cj | ✅ | — |
| 463 | `f_llm/src/tool/SkillLoadingFunction.cj` | .cj | ✅ | — |
| 464 | `f_llm/src/tool/SkillReferenceLoadingFunction.cj` | .cj | ✅ | — |
| 465 | `f_llm/src/tool/SsrfGuard.cj` | .cj | ✅ | — |
| 466 | `f_llm/src/tool/TodoFunction.cj` | .cj | ✅ | — |
| 467 | `f_llm/src/tool/ToolFunctions_test.cj` | .cj | ✅ | — |
| 468 | `f_llm/src/tool/ToolName.cj` | .cj | ✅ | — |
| 469 | `f_llm/src/tool/WebFetchFunction.cj` | .cj | ✅ | — |
| 470 | `f_llm/src/tool/WebFetch_test.cj` | .cj | ✅ | — |
| 471 | `f_llm/src/tool/WebSearchFunction.cj` | .cj | ✅ | — |
| 472 | `f_llm/src/tool/WrappedFunctionCalling.cj` | .cj | ✅ | — |
| 473 | `f_llm/src/tool/imports.cj` | .cj | ✅ | — |
| 474 | `f_llm/src/util/Redactor.cj` | .cj | ✅ | — |
| 475 | `f_llm/src/util/Redactor_test.cj` | .cj | ✅ | — |
| 476 | `f_llm/src/util/TextClip.cj` | .cj | ✅ | — |
| 477 | `f_llm/src/util/TextClip_test.cj` | .cj | ✅ | — |
| 478 | `f_llm/src/util/http.cj` | .cj | ✅ | — |
| 479 | `f_llm/src/util/imports.cj` | .cj | ✅ | — |
| 480 | `f_llm/src/wiring/StoreWiring.cj` | .cj | ✅ | — |

合计：`.cj` 368 个 / `.md` 112 个 / 共 480 个，全部读完。

## 覆盖自检

### 第 1 部分

| 维度 | 命中 | 未命中时的说明 |
| --- | --- | --- |
| 正确性 / 设计 / 语言特性 / 可读性 / 安全性 | 12 | 正确性/契约：#1、#2、#4、#5、#6、#7、#8、#15、#16；设计（接线与边界）：#3、#9、#19。可读性：#12、#13、#18、#20、#21 归入轻微。安全性：#17（`command` 工具无隔离且文档未标注）；文档承诺的安全边界逐条对照后，附件根目录与 `Redactor` 成立，**`SsrfGuard` 只覆盖 `WebFetch`**（见 #18）；**真正的 TLS 问题在 .cj 里**，见「范围外提示」第 1 条 |
| §1 死代码 | 0 | 本部分无符号定义。对文档点名的每个 public 符号做了存在性检索（`LLMConfService`、`SqlMemoryStore`、`HydraKnowledgeStore`、`PredefinedCharacters.bodyOf`、`RetrievalScoring` 常量、`MemoryKinds.register/remove/seed` 等）全部存在；唯一"文档指向但不存在"的是 `ToolName` 里的工具名常量（记 #12），归 §13 不归 §1。`Stores.DEFAULT_*` 虽零引用但对外可达，按硬原则一不判死代码（记 #14 为重复常量） |
| §2 重复逻辑 | 1 | 文档层两两比对：同一张"20 表清单 / 权重表 / 默认值表"在 README、README_en、DDL、代码各写一份，已发生漂移（#10 的 7 vs 9、#14 的默认存储、#3 的默认值）——合并为 #14 加 #10；其余"中英对照"是翻译而非重复实现，不判。`.cj` 侧只抽查了与文档公式对应的 `RetrievalScoring`，与文档一致 |
| §3 空实现 | 0 | `doc/` 里没有空契约；文档承诺的降级路径都有实现（编码失败退关键词、提炼失败回落规则、人格 key 非法抛错）。唯一空实现是 `src/store/ColbertCodec.cj:57-60` 的空 `if` 分支，属范围外，见「范围外提示」第 3 条 |
| §4 栈溢出 | 0 | 本部分没有描述任何递归结构（切块是 while 滑窗、检索是双层循环、人格解析是三级 match）；`content-store.md` 的 colbert 解码是定长循环。无"递归遍历用户可控结构"的承诺 |
| §5 OOM | 1 | #9（全文 Rune 物化 + 无输入上限 + local region 并发叠加）。另核对了文档写出的其它物化点：`llm_streamMaxLineBytes`（1 MiB 单行上限）、`llm_toolResultMaxBytes`（64 KiB）、`llm_fetchMaxBytes`（256 KiB）都实现为截断而非全量读，不构成 OOM 面；问题在于这些默认值没写进文档（#3） |
| §6.1 热点瓶颈 | 0 | 未提供本部分的 `cjprof` / `cjpm bench` 数据，任何"热点"结论都不成立；切块、检索重排、流式 delta 解析三条线索全部降级为「待验证假设」1–3 |
| §6.2 大粒度锁 | 0 | 文档描述的临界区只有 `LLMConfsHolder.refresh` 的单飞标记（`synchronized(mutex)` 只包 `refreshing` 标志，`source.load()` 在锁外，`LLMConfsHolder.cj:224-266`）与 `Stores` 启动期注册，没有"锁内 I/O / 日志 / 解析" |
| §6.3 并发串行 | 0 | 未发现"spawn 后立刻 get"或并发度=1 的路径；`ensureFresh` 的刷新是"首个线程干活、其余用旧快照"（`:226-228`），不是串行热点 |
| §6.4 低效算法 | 0 | 文档写出的算法（min-max 归一化、colbert max-sim、按 id 去重、top-k 选择）都是 O(n) / O(bound×n)，`bound = max(topK*4,20)` 与输入规模无关；没有循环内字符串拼接的承诺（摘要用 `+=` 但轮次受 maxTurns 限制） |
| §7 降堆内存方案 | 1 | 优化方案 1（切块流式化），标 `无基线（待验证）` |
| §8 降 CPU 方案 | 0 | 没有 profile 数据，不给 CPU 方案；相关线索见「待验证假设」2、4 |
| §9 local mode 可行性 | 0 | 本部分没有新增 local 候选：`KnowledgeChunker` 已经启用 local 档（README:19-25 与代码一致），剩余可行空间是"取消它"而不是"加上它"；其风险（全局 `cjLocalRegionMaxSize`、并发叠加）已并入 #9，收益需要改前改后峰值数据（假设 1、5） |
| §11 现有代码的 BUG（存量） | 15 | #1、#2、#4、#5、#6、#7、#8、#9、#10、#11、#14、#15、#16、#17、#19 都以"文档承诺"为入口追到了实现缺陷；另核对了 `README` 的 quickstart 示例（`UserMessage(content:)`、`LLMParams(model:messages:)`、`LoomWiring.wire` 两个重载、`service.execute/confirmFlow/executeNow`、`ChannelMediator` 附件命名 `-2` 顺延）签名均一致，无编译不过的示例——但示例缺"模型配置从哪来"这一环，见 #19 |
| §12 并发安全与锁粒度 | 0 | 文档没有承诺线程安全的具体对象；实际核对了三处共享点：`LLM.transport/streamTransport/counter`（`synchronized(mutex)` 读写，`LLM.cj:43-66`、`:295-300`）、`LLMConfs.current`（`synchronized`，`LLMConfs.cj:61-71`）、`LLMConfsHolder.snapshot`（无锁读写、整份替换，`ensureFresh` 未加锁读 `snapshot`——可见性问题属 .cj 面，见「范围外提示」第 5 条）；配置默认值全走 `Config` 静态映射，启动后只读 |
| §14 功能完备性与 README 覆盖 | 6 | #1（`llm_confSource`/`llm_confs` 接线缺失）、#12（`ToolName` 指向不存在的能力）、#13（`channel/` 未登记、能力计数与表不符）、#19（快速开始缺模型配置来源、`llmName` 语义未说明）、#20（API 附录 69 个 `public const` 缺失）、#21（`MemoryHit.degraded` / `llm_a2aEnabled` / `characterUserId` 未覆盖）。逐项对照 `StoreContracts` / `StoreSettings` / `LLMConfig` 的公开符号与 README 表，`MemoryStore`/`KnowledgeStore`/`CharacterStore`/`SkillStore`/`PromptStore`/`LLMConfStore` 的方法清单、三族实现名、20 张表名与两版 README 完全一致；`public` 顶层声明已全量抽取比对（537 个），覆盖率缺口已收在上述 3 条 |
| 文件覆盖（§13 等） | 5/5 | 无缺文件；5 个 `.md` 均逐段读完，`.md` 的 API/默认值/示例/链接均按 §13 双向核对（文档行号 + 代码行号） |

### 第 2 部分

| 维度 | 命中 | 未命中时的说明 |
| --- | --- | --- |
| 正确性 / 设计 / 语言特性 / 可读性 / 安全性 | 3 | G1（错误处理契约）、G5（配置刷新）、G7（超时语义）为「文档承诺 vs 实现」的正确性命中；流式响应侧的「重放/已输出内容作废/熔断/截断」在 S4 列出文档位置（代码侧第 1/12 部分已报），本部分不重复计数。安全性方面本部分文档未新增错误承诺，TLS `TrustAll` 已由第 1/12/13 部分按代码侧报出，本部分只记「known-limitations 未收录」 |
| §1 死代码 | 3 | 逐项核对了文档点名的「零引用/保留」符号：`PlanDto` 实际被 `Planner.cj:152/164/260/278` 使用（M5）；`ChannelProviders` / `EmailChannel.fromConf` 全仓不存在（M8）；`llm_auto` / `LLMConfig.isAuto()` 全仓零调用且无文档（M1）。`MemoryIndexRebuilder`/`KnowledgeIndexRebuilder` 的「生产零调用」结论成立，属 S2（跨部分） |
| §2 重复逻辑 | 3 | 同一事实多文档重复且结论冲突：G5（配置只读 vs 60 s 刷新）、M3（memory/knowledge 返回字段）、S2（启动重建 vs 手工重建）；其余重叠段落（存储选型、网关 op 表、附件语义、Supervisor 路由、技能演进）已两两比对，差异属「设计总览 vs 使用说明」的分工，不算重复 |
| §3 空实现 | 1 | G6：演进任务的 `catch { () }` 静默吞异常，且文档声称有日志。另：`llm_rebuildIndexOnStart` 打开后走空分支，属 S2（跨部分，代码侧已计） |
| §4 栈溢出 | 0 | 文档描述的切块是滑窗迭代（`KnowledgeChunker.splitImpl`），编排是拓扑序 + 事件派发，未承诺任何按输入深度递归的遍历 |
| §5 OOM | 0 | 文档写出的上限与实现一致：`llm_streamMaxLineBytes`=1 MiB、`llm_toolResultMaxBytes`=64 KiB、`llm_fetchMaxBytes`=256 KiB、`LoomContextLog.MAX_TURNS`=200、KnowledgeChunker local 预算 8 MiB / 2 MiB 内容门限；未发现无上限承诺 |
| §6.1 热点瓶颈 | 0 | 本部分唯一性能材料是 `perf-baseline.md`，口径是单次运行的堆增量 / `VmHWM`，没有 `cjprof` 自耗时与调用路径，不构成热点结论；缺什么见假设 2 |
| §6.2 大粒度锁 | 0 | 文档只承诺「`LoomContextLog`/`Supervisor`/`LoomRegistry` 用 `Mutex`」；抽查实现临界区均为内存操作，无 I/O / 日志 / 回调 |
| §6.3 并发串行 | 0 | 文档对并发的承诺只有「`parallel=true` 换 `AsyncFlow`」「`JoinBarrier` 汇聚」，未出现「spawn 后立刻 get」这类描述；实际 `waiter.get()` 无超时属第 15 部分范围 |
| §6.4 低效算法 | 0 | 文档提到的复杂度只有 `listByKind` 近似分页与索引重建 O(记录数)，均已标为已知限制；与实现的偏差见 S7（代码侧） |
| §7 降堆内存方案 | 0 | 本部分无源码；`perf-baseline.md` 的方案已落地并有改前/改后对照，不重复提方案 |
| §8 降 CPU 方案 | 0 | 同上，且文档明确「不以吞吐量验收」，没有 CPU 基数 |
| §9 local mode 可行性 | 0 | 已核对试点结论与实现一致：门限 8 MiB / 4 B = 2 MiB（`KnowledgeChunker.cj:21-26`）、local/堆窗口循环拆成两个 helper、`maxChars=400`/`overlap=50` 默认值一致；未发现新的改造面 |
| §11 现有代码的 BUG（存量） | 3 | G1、G6、G7 是文档侧可静态确定的行为/契约错误；另核对文档给出的默认值（`maxTurns=20`、`skillTopK=3`、`minSamples=3`、`0.8`、`86400/172800`、`DEFAULT_MAX_ROUNDS=8`、`MAX_TURNS=200`、`idleTimeout=120s`）全部与实现一致 |
| §12 并发安全与锁粒度 | 1 | 命中 G4 的启动窗口（A2A 已注册、Supervisor 未安装）；执行期上下文的「严格绑在一次执行上」承诺不成立属 S1（严重，已由第 15/14 部分按代码侧定级，本部分不重复计），网关懒建竞态属 S6（第 16 部分已计） |
| §14 功能完备性与 README 覆盖 | 3 | G2（`platforms()` MUST 场景不成立）、G3（`LoomA2aClient` 三方法未实现）、M8（规格引用的 `ChannelProviders` / `fromConf` 根本不存在） |
| 文件覆盖（§13 等） | 20/20 | 无缺文件 |

### 第 3 部分

| 维度 | 命中 | 未命中时的说明 |
| --- | --- | --- |
| 正确性 / 设计 / 语言特性 / 可读性 / 安全性 | 10 | 错误处理 F2 F8 F15；安全/输入校验 F3 F4；并发与契约 F6 F7；接线缺失 F5 F9；可读性 F13 |
| §1 死代码 | 0 | 本部分无 `.cj`，无符号可见性可判；改查「文档点名的符号/路径是否仍存在」：20 个文件里点名的符号（`ModelCapabilities`、`StaticConfSource`、`AttachmentSink.isRegular` 等）逐个在 `src/` 检索，命中项按 §13/§14 归类（F3 F7 F9 F10 F13），文档间无「写了但永不触发」的残留条目 |
| §2 重复逻辑 | 0 | 已把 20 个文件的 requirement / decision 段落两两比对：饱和阈值规则在 `llm-conf-routing/spec.md:101-111` 与 `llm-context-pruning/spec.md:29-39` 各表述一次、`weight<=0` 过滤在 `llm-conf-routing` 与 `llm-meta-store`（归档）各一次——均为能力边界复述（checklist §2 误报边界），措辞差异属不同视角，未判重复；同一结论在两份文档给出不同数字/签名的情形归 §13（F7 F11 F12），不重复计为重复逻辑 |
| §3 空实现 | 0 | 检查了全部 TODO/FIXME/占位表述：`fix-channel-attachment-safety/design.md:78-80` 的「附件大小上限本期不做」与 `tasks.md:113` 的「仍未做」都是显式范围声明，不是默认主路径上的空实现；5 项 deferred 平台联调有实现与单测，缺的只是真实联调 |
| §4 栈溢出 | 0 | 文档层无递归结构；文档点名的 `McpToolSource.sanitizeSchema` 递归深度由 MCP server 的 schema 决定，属代码面，记入「范围外提示」 |
| §5 OOM | 0 | 文档给出的容量约束齐全：`webFetch` 256 KiB（`LLMConfig.cj:196`）、SSE 单行上限、`llm_embeddingBatch`；未发现「按不可信长度预分配」的文档承诺缺口 |
| §6.1 热点瓶颈 | 0 | 本部分无 profile / bench 数据，任何热点结论都不成立；三条疑似点已写入「待验证假设」 |
| §6.2 大粒度锁 | 0 | 文档描述的是无锁快照 + 单飞刷新（`design.md:140-142`），不涉及锁内 I/O；其并发正确性另见 F6 |
| §6.3 并发串行 | 0 | 设计明确「流式采用同步回调，模块不 spawn、不建线程池」（`design.md:200`），无并发串行段可判 |
| §6.4 低效算法 | 0 | 文档层无算法描述可判复杂度；`TokenBudget` 裁剪、权重调度均为 O(n) 遍历 |
| §7 降堆内存方案 | 0 | 本部分为 `.md`，无堆对象可改；无基线数据，按要求不产出方案 |
| §8 降 CPU 方案 | 0 | 同上；无 `cjpm bench` / `cjprof` 数据 |
| §9 local mode 可行性 | 0 | 文档未承诺 local mode 改造；本部分无函数级临时对象可评估 |
| §11 现有代码的 BUG（存量） | 5 | 顺文档链路核到的存量代码缺陷：F2（错误码丢失）、F5（首载失败只记日志）、F8（阶段信息缺失）、F15（解析失败回落 0.00），以及 F3 的特殊文件放行 |
| §12 并发安全与锁粒度 | 1 | F6 快照引用发布无同步（待确认语言内存模型）；其余文档描述的并发点（单飞刷新、按 llmName 缓存调度器、熔断表）均有明确同步手段 |
| §13 文档一致性 | 10 | F1 F4 F7 F10 F11 F12 F13 F14 F16 F17（F3、F15 同时计入 §11，不重复计） |
| §14 功能完备性与 README 覆盖 | 1 | F9（`static` 来源无配置入口）；5 项 deferred 平台联调已在 `tasks.md` 显式标注，不算隐藏缺口；README / README_en 覆盖属第 1–2 部分范围，本部分不重复统计 |
| 文件覆盖（§13 等） | 20/20 | 无缺项 |

### 第 4 部分

| 维度 | 命中 | 未命中时的说明 |
| --- | --- | --- |
| 正确性 / 设计 / 语言特性 / 可读性 / 安全性 | 8 | 正确性 #1 #2（水位线取数方向与零素材分支）；安全 #3（特殊文件/软链未校验，代码侧归第 3 部分）；契约口径 #4 #5 #9；设计前提 #6；可读性/计数 #7；规格互斥 #8。语言特性 0：本部分无代码 |
| §1 死代码 | 0 | 本部分无 `.cj`，无符号可见性可判。改查「文档点名的符号是否仍存在并被调用」：`bareName`/`freeName`/`save`（`EmailChannel.cj:86,119,148`）、`closeAll`（`ChannelMediator.cj:208`）、`strOf`/`portOf`/`validate`、`kindOf`/`kindsOf`（`LoomStoreGateway.cj:136,149,412` 均有调用方）、`ownedBy`、`TextClip.clip`、`PredefinedCharacters.isKnown` 逐个在 `src/` 检索，全部命中；文档内无「写了但永不触发」的残留条目 |
| §2 重复逻辑 | 0 | 已把 20 个文件的 Decision / What Changes / Requirement 段落两两比对：`proposal` 与 `design` 的复述是 openspec 结构要求（checklist §2 误报边界）；唯一的语义分叉是 spec/design 与 `doc/loom.md` 对同一规则的两套口径（#4 #5）以及两份 spec 对分页方案的相反结论（#8），按「文档漂移」归类而非重复逻辑；实现侧 `KnowledgeChunker` 的 local/heap 双循环体已有注释说明为 local mode 必须拆开，不判重复 |
| §3 空实现 | 0 | 逐条核对文档声称的行为是否有实体：无 `TODO`/`FIXME` 占位；`fix-loom-extract-data-loss` 的 `catch` 无日志一项属其 Non-Goals 显式排除，且已由第 5 部分覆盖 |
| §4 栈溢出 | 0 | 文档层无递归结构；被引用的 `resolvePersona` / `ownedBy` / `split` 均为单层循环或固定层级回落（三级），无输入决定深度的递归 |
| §5 OOM | 0 | 文档给出的容量约束齐全：`docId` 128 列宽见 #6；附件落盘为单文件字节数组（`item.read()`），无整目录物化承诺；切块全文 Rune 展开的峰值问题已在第 1 部分报过。#1 是「取数窗口取错方向」而非无界增长，未按 OOM 计 |
| §6.1 热点瓶颈 | 0 | 本部分无 profile / bench 数据，热点结论不成立；唯一疑似点写入「待验证假设」#2 |
| §6.2 大粒度锁 | 0 | 文档唯一涉及的锁是 `AttachmentSink` 的进程内 `Mutex`，临界区只含「选名 + `File.create`」（`EmailChannel.cj:160-164`），无 I/O 写入、无回调；粒度问题降为待验证假设 |
| §6.3 并发串行 | 0 | 文档未描述「spawn 后立刻 get」类结构；`ChannelMediator.closeAll` 串行关闭是关闭路径，单一入口的低频操作，不构成热点 |
| §6.4 低效算法 | 0 | 文档层无算法描述可判复杂度；`freeName` 的 `while(true)` 线性探测文件名冲突是 O(冲突数)，冲突数由目录内容决定，无数据不判 |
| §7 降堆内存方案 | 0 | 本部分为 `.md`，无对象可改；无基线数据，按要求不产出方案 |
| §8 降 CPU 方案 | 0 | 同上；无 `cjpm bench` / `cjprof` 数据 |
| §9 local mode 可行性 | 0 | 本部分文档未主张 local mode；`KnowledgeChunker` 的 local 改造是既有实现（`local-mode-f-llm-knowledge-chunker`），不在本部分清单 |
| §11 现有代码的 BUG（存量） | 9 | #1 水位线超量场景不可达（静默丢样本）；#2 零素材推进到 `now`；#3 特殊文件/软链通过附件校验（附带的取证实测缺口）；#4 必填口径分叉；#5 单值/双 kind 口径滞后；#6 docId 无长度与字符集校验、upsert 失败静默；#7 用例数自相矛盾；#8 两份规格互斥；#9 根目录绝对路径无校验 |
| §12 并发安全与锁粒度 | 0 | 文档关于并发的三处主张均自洽：`AttachmentSink` 进程内串行（`known-limitations.md:126-129` 明确只做进程内）、`ChannelMediator` 全部状态在 `mutex` 内、`LoomMemoryPolicy` 的 `PolicyBox` 带出锁内值（`LoomMemoryPolicy.cj:89-95`）；跨进程落盘竞态已列为已知限制，文档与实现一致 |
| §14 功能完备性与 README 覆盖 | 2 | #3（spec/tasks 承诺的符号链接校验与用例缺失）、#4（`from` 必填承诺未实现）；README 配置表本身已含 `llm_channelSendRoots`（`README.md:791`、`README_en.md:782`），中英同步 |
| 文件覆盖（§13 等） | 20/20 | 无缺项；`doc/spec` 其余 40+ 个变更目录与 `archive/` 不在本部分清单，由第 2、3、5 部分覆盖 |

### 第 5 部分

| 维度 | 命中 | 未命中时的说明 |
| --- | --- | --- |
| 正确性 / 设计 / 语言特性 / 可读性 / 安全性 | 9 | 正确性 #1 #4 #5 #6 #7、错误分类 #8、安全性 #9、关键限制未记录 #12、装配设计 #16；语言特性按文档所述实现抽查（`synchronized` Unit 语义、`Option` 取值）无额外命中 |
| §1 死代码 | 1 | 20 份文档引用的符号逐一搜实现：`kindsOf` / `pageOf` / `ownedBy` / `evolutionOwner` / `lastReload` / `buildCount` / `LoomCharacterScope` / `loomStoreCall` / `StoreInvoker` / `FlowPlan.skills` / `executeNow(skills:)` 均存在且被调用；唯一落点错误是 `LoomCompiler`（并入 #3）。命中 `LoomRunner.cj:241` 的恒真条件（#14） |
| §2 重复逻辑 | 1 | 5 份 spec delta 的 18 条 Requirement 两两比对：memory-owner（演进跟随记忆策略）与 persona（人格解耦记忆策略）方向相反、语义不同，不算重复；同一错误文案 `jit step does not support {…}` 仅一处定义。命中 25 个同形 Box 类（#13） |
| §3 空实现 | 1 | 文档无空实现；实现侧命中两处 `catch { () }` / `catch { false }`（#4） |
| §4 栈溢出 | 0 | 本部分文档不涉及递归；被核对的 `validate` / `kindsOf` / `ownedBy` 均为单层循环 |
| §5 OOM | 0 | 唯一无界项 `docIds limit=500` 已被 proposal:31 声明且为常量上限；`knowledgeOf` 结果受其约束，不构成无界增长 |
| §6.1 热点瓶颈 | 0 | 无 profile / bench 数据；网关复用收益与 N+1 调用列入「待验证假设」#1 #2 |
| §6.2 大粒度锁 | 0 | 文档未引入锁内 I/O；`LoomMemoryPolicy` / `LoomCharacterScope` 的 `synchronized` 只包字段读写，`LoomHostApi.render` 已把替换移出锁外 |
| §6.3 并发串行 | 0 | 演进任务是 cron 驱动的单线程串行设计，无「spawn 后立刻 get」形态 |
| §6.4 低效算法 | 0 | `knowledgeOf` 的 1+K 次调用属调用次数放大，无耗时数据，按规则降为待验证假设 #2 |
| §7 降堆内存方案 | 1 | experience 列表合并去副本（见优化方案） |
| §8 降 CPU 方案 | 1 | 演进素材 N+1 批量化（见优化方案） |
| §9 local mode 可行性 | 0 | 本部分为文档，未引入函数内临时大对象；被引用的实现无峰值内存基线，收益不可证 |
| §11 现有代码的 BUG（存量） | 8 | #1 #2 #3 #4 #5 #6 #7 #8，均为「文档所述行为的实现缺陷」，可能与代码分部分重复，合并时去重 |
| §12 并发安全与锁粒度 | 2 | `LoomGatewayHolder` 惰性初始化（#2）、进程级注入态与单线程约束（#12）；其余静态态均有 `Mutex` 保护 |
| §13 文档一致性 | 7 | #1 #3 #4 #5 #6 #10 #11 为文档与实现漂移或文档间矛盾；另核对 20 份文档的用例基线（600→621→625→634）单调，无矛盾 |
| §14 功能完备性与 README 覆盖 | 2 | `wire(host:)` / 演进归属 / `prompt.get`（#11）、并发限制未记录（#12）；`loomStoreCall`、`characterUserId`、网关懒建在 `doc/loom.md` 均有对应段落 |
| 文件覆盖（§13 等） | 20/20 | 无缺文件 |

### 第 6 部分

| 维度 | 命中 | 未命中时的说明 |
| --- | --- | --- |
| 正确性 / 设计 / 语言特性 / 可读性 / 安全性 | 3 | #3（检索降级路径缺失：旧版本抛错 / 无库名时静默丢 dense）、#7（空值语义自相矛盾）、#9（设计依据待确认）；无安全类问题（文档不含凭据、外部输入处理） |
| §1 死代码 | 0 | 文档无可见性概念；改为机械核对「文档引用的符号是否仍存在」：`StoreInvoker` / `loomStoreCall` / `StoreCallParam` / `FlowPlan.skills` / `PlanDto.skills` / `Planner.planOf` / `executeNow` / `splitImpl` / `knowledgeChunkerUsesLocal*` / `countRunes` / `LoomContextLog.MAX_TURNS` / `Stores.registerContent` / `registerMeta` / `content` / `meta` / `bootstrap` / `Memory.remember` / `MemoryKinds.predefined` / `weightOf` / `MemoryKinds.remove` / `annPath` / `maxCandidates` 共 22 组全部命中；唯一「引用但仍存在却不生效」的是 `llm_contentStore`（并入 #1）；反向检查「文档引用了已删除的符号」0 处 |
| §2 重复逻辑 | 1 | 「按配置选实现、未知值启动失败并列出可选值」这条契约在 `llm-content-store/spec.md:10` 与 `llm-store-wiring/spec.md:31` 各写一遍，键名同时漂移（#1）；另 `llm-store-wiring/spec.md:19-22` 与归档副本逐行相同（#5）。四段式 proposal/design/tasks/spec 骨架属 OpenSpec 格式要求，不算重复 |
| §3 空实现 | 1 | `llm-store-wiring/spec.md:4` Purpose 是归档工具留下的 TBD 占位（#6） |
| §4 栈溢出 | 0 | 本部分文档不涉及递归结构；被引用的实现（`render` 单遍扫描、`split` 线性滑窗、`countRunes` 单次遍历）均无递归 |
| §5 OOM | 0 | 文档描述的容器都有常量上限（`MAX_TURNS=200`、候选 400 / `max(k*4,20)`、local region 2 MiB 门限）；#8 是「上界未覆盖全部构造路径」，不是无界增长 |
| §6.1 热点瓶颈 | 0 | 本部分无任何 profile / bench 输出（`perf-baseline.md` 为单次参考值），三条收益论证降为待验证假设 #1 #2 #3 |
| §6.2 大粒度锁 | 0 | `render` 已按 spec 改成「锁内只拷快照、替换在锁外」（`LoomHostApi.cj:79-88`），临界区内无 I/O / 解析 / 回调 |
| §6.3 并发串行 | 0 | 文档未引入并发调度；Hydra「先紧后松」是串行远程调用但有明确上界（`bound` 后放宽），无数据不判热点 |
| §6.4 低效算法 | 0 | N+1（Hydra 正文、colbert 每候选一次）与全串 `replace` 都已在文档描述并落地收敛；无耗时数据，收益见待验证假设 #1 #2 #3 |
| §7 降堆内存方案 | 0 | rune 缓冲 local 化、知识候选 400、colbert 只取前 N 均已落地；本部分无新增可执行项，#8 是完成度问题 |
| §8 降 CPU 方案 | 0 | 同 §7：单遍渲染、候选上界、重排上界都已实现，无新方案 |
| §9 local mode 可行性 | 0 | 该试点已落地（`KnowledgeChunker.cj`）；design 明确把 `chunks` / `StringBuilder` 列为 Non-Goal，本轮无新增候选，也无改前改后峰值对照可证收益（待验证假设 #4） |
| §11 现有代码的 BUG（存量） | 3 | #2（`inMemory` 可选 → 重启丢记忆，与规格 MUST 相反）、#3（MySQL 无 ANN 降级缺失：9.0/9.1 检索抛错、无库名时 dense 静默跳过）、#5（Repository 直写 DELETE）属既有代码与契约不符；#1 / #4 是文档侧失真，不计入本行 |
| §12 并发安全与锁粒度 | 0 | 本部分唯一共享态是 `LoomHostApi.values`（`LoomHostApi.cj:55-88`），全部读写都在 `mutex` 内，快照拷贝与替换顺序符合 spec；`LoomContextLog.turns` 亦在 `mutex` 内且已加上限 |
| §13 文档一致性 | 7 | #1 #2 #3 #4 #5 #7 #8 |
| §14 功能完备性与 README 覆盖 | 2 | #3（承诺的降级 + warn 未实现）、#6（Purpose 关键段落缺失）；`loomStoreCall`、计划 skills、local mode 编译期要求都已进 README（`README.md:500`、`:19-25`） |
| 文件覆盖（§13 等） | 20/20 | 无缺文件 |

### 第 7 部分

| 维度 | 命中 | 未命中时的说明 |
| --- | --- | --- |
| 正确性 / 设计 / 语言特性 / 可读性 / 安全性 | 27 | 本部分全部发现（严重 2 / 一般 12 / 轻微 13），逐条判据见上；安全性 1 条、设计 3 条、可读性 3 条，其余以正确性为主 |
| §1 死代码 | 1 | 逐个检查了本部分全部非 public 符号（`private`/默认 `internal` 顶层与成员），并对 `public` 成员按对外可达性判定；3 个符号全仓零引用，合并为 1 条；`internal import` 属包级可见，不算死文件 |
| §2 重复逻辑 | 4 | 同文件函数体两两比对（AgentEvent 4 构造、genSkillDetails 2 分支、3 个 parse*、URL/签名常量）并对相同错误文案/字面量跨文件搜索；其余函数输入-输出-副作用不同，未合并 |
| §3 空实现 | 0 | 无空函数体/空 `catch`；三平台 `query()` 抛 `BalanceUnsupportedException` 属已登记占位（`doc/todo.md` §1、`known-limitations.md` §7），有明确异常与注释，不计缺陷；`catch` 均为记日志或转报告 |
| §4 栈溢出 | 0 | 本部分无递归函数（`SignUtil`/`parse*`/`AgentTask` 均为迭代）；`JsonValue.fromStr` 的递归属标准库/其它模块，不在本部分范围 |
| §5 OOM | 1 | `channelInbox` 的 `limit` 无上限（按不可信长度物化）；`llm_channels` JSON 由管理员配置且体量小，未计 |
| §6.1 热点瓶颈 | 0 | 未提供本部分任何 profile / bench 数据，热点不成立，已全部放入「待验证假设」 |
| §6.2 大粒度锁 | 1 | `ensureLoaded` 锁内做 bean 实例化；已核对 `Mutex` 可重入，不按死锁计 |
| §6.3 并发串行 | 0 | 本部分没有 `spawn`/`Future.get`，`queryAll` 是设计上的串行聚合，非并发串行 |
| §6.4 低效算法 | 0 | `render` 的 `+=` 与 `msgs × skills` 双层扫描规模受 `limit`/技能数约束，作为优化项而非缺陷；无证据表明已成瓶颈 |
| §7 降堆内存方案 | 1 | `BalanceSnapshot.raw` 重复持有整段响应；无基线，标待验证 |
| §8 降 CPU 方案 | 2 | `render` 拼接、`TextTemplate.compile` 重复编译；均无基线 |
| §9 local mode 可行性 | 0 | 提示词组装的临时对象会作为 `messages` 逃逸到 `LLMResp`/事件数据，收益只能用峰值内存证明；无数据，仅列入待验证假设 #4 |
| §11 现有代码的 BUG（存量） | 27 | 本部分全部发现均为存量（快照模式无 diff）；边界、空值、错误处理、资源、并发、契约逐类核对 |
| §12 并发安全与锁粒度 | 3 | `names()` 无锁遍历、`ensureLoaded` 锁粒度、`AgentTask` 惰性字段发布；`BalanceMediator` 的 `loaded` 仅在锁内读写，无问题 |
| §14 功能完备性与 README 覆盖 | 1 | `llm_channels` 承诺 warn 但实现无 warn（同时是 §13）；README 的逐符号成员表不在本部分文件清单，未重复统计 |
| 文件覆盖（§13 等） | 20/20 | 无缺失；§13 命中 3 条（README 阈值默认值、channels warn、400/1000 候选口径） |

### 第 8 部分

| 维度 | 命中 | 未命中时的说明 |
| --- | --- | --- |
| 正确性 / 设计 / 语言特性 / 可读性 / 安全性 | 12 | 安全性 1（downloadDir 沙箱）、正确性 4（html 正文、receivedAt、发送丢 text、normalize 大小写）、错误处理 2（canonicalize 吞原因、getPath 副作用）、并发 2（transport 无同步、锁内 close）、可读性/可维护性 3（重复消息、注释不符、默认值复制）。`Option` 均显式处理（`?? ''`、`match`），`EmailChannel.cj:165` 的 `getOrThrow` 前置已保证 `File.create` 成功 |
| §1 死代码 | 2 | 逐个 `private`/`internal` 全仓搜过：`ChannelMediator.normalize/keyOf/mutex/providers/instances`、`EmailChannel.checkAttachment/isDirectory`、`AttachmentSink.sinkMutex/FALLBACK_NAME/MAX_NAME_CHARS`、`FEmailTransport.email/conf/client`、`LLMConfig.getPath`、`ModelNames` 私有构造均有调用者；命中 2 处：`freeName` 不可达 `base`、`FakeEmailTransport.closed` 只写不读。`isAuto`/`resetAll`/`closeAll` 与 15 个 public 常量为对外可达 `public`，按硬原则一只记「仓内零引用」；`protected` 本部分为 0；未发现未使用 import（`EmailChannel_test.cj:20` 的 `std.sync.*` 供 `spawn`/`Future` 使用，未计入） |
| §2 重复逻辑 | 3 | 两两比对 34 个函数体（含测试类方法组）：`channel()` 两段 + `create()` 的「平台未知」三处（1）、`'chat-pro'` 默认值两处 + `_a2aEnabled` 内联键（2）、两个测试 Fake 的 `limit` 截断循环逐行相同（3）。`platforms()/accounts()/providerPlatforms()` 形态相近但去重规则不同，**不判**重复 |
| §3 空实现 | 1 | 无空函数体、无 `TODO`/`FIXME`/`throw UnsupportedException`（`grep` 本部分目录无命中）；命中 4 处静默 `catch`（合并为 1 条）。`case None => ()` 均为「可选值缺失」的正常分支 |
| §4 栈溢出 | 0 | 本部分无递归（`bareName`/`freeName`/`checkAttachment`/`render` 均为单层或「实例数」驱动）；`freeName` 的 `while(true)` 有 `return` 出口，不构成栈风险 |
| §5 OOM | 1 | 收信全量物化 + `limit` 无上界（`limit<=0` 被 f_email 解释为全部），峰值 ≈ Σ(正文 + 2×附件字节)；`instances`/`providers` 规模由配置条数约束，`bareName` 无按 `size` 预分配 |
| §6.1 热点瓶颈 | 0 | 未提供 `cjprof`/bench 数据，热点不成立；锁内 `normalize`、逐封 `body()`、`canonicalize` 逐附件逐根目录、`getPath` 的 `exists` 四项写入待验证假设 1/2/5/6 |
| §6.2 大粒度锁 | 1 | `synchronized(mutex)` 里调 `Channel.close()`（网络 QUIT/LOGOUT）。`AttachmentSink.sinkMutex` 临界区只含「选名 + `File.create`」，无写入 I/O、无回调；单锁串行由第 4 部分登记 |
| §6.3 并发串行 | 0 | 本部分无 `spawn` + `get()`、无批大小配置；`AttachmentSink` 的写盘本就在锁外并行；收信逐封 `body()` 是协议层串行，缺数据，见待验证假设 2 |
| §6.4 低效算法 | 1 | `freeName` 的线性探测（k 次 `exists`）；`platforms()` 的 `contains` 去重为 O(平台数²)，量级个位数，未报 |
| §7 降堆内存方案 | 1 | 附件流式落盘（无基线，待验证） |
| §8 降 CPU 方案 | 2 | 白名单解析 + `canonicalize` 缓存、`freeName` 探测（均无基线） |
| §9 local mode 可行性 | 0 | 本部分临时对象只有 `bareName` 的 `StringBuilder`（每次附件一次，KB 级）与 `channel()` 的 `ArrayList<Channel>`；`Array<Byte>` 由参数传入（逃逸），无「函数内创建、函数内用完的大对象」，收益无法用峰值内存证明。模块已启用 `--enable-local-mode`（`f_llm/cjpm.toml` 的 `compile-option`），无需额外改造 |
| §11 现有代码的 BUG（存量） | 14 | 20 个文件、约 60 个函数/属性逐一对过边界与空值：2 严重 + 8 一般 + 4 轻微（`bareName` 截断、失败残留文件、`register` 注释不符、Windows 分隔符）属存量缺陷/错误处理缺口。`getLLMAccessTryingElapsed` 的 `Int64.Max` 秒乘法按 `Duration` 文档核对后**不溢出**，不报；`bareName` 对空串/`.`/`..`/纯分隔符的处理已核对，正确 |
| §12 并发安全与锁粒度 | 3 | transport 无同步（共享路径 `ChannelMediator.instances`(static) → `channel()` → `EmailChannel.transport.client` → `Email` 可变会话状态）、锁内 I/O 与临界区过大、`closeAll`/`reset` 的生命周期接线。`ChannelMediator` 两表本身有 mutex 保护，`found`/`matches` 均为锁内取快照、锁外使用 |
| §14 功能完备性与 README 覆盖 | 3 | `receivedAt` 未接线、接收侧沙箱缺失（README:558 只承诺发送侧）、`closeAll` 无生产调用。其余 `public` 类型（`ChannelMediator`/`AttachmentSink`/`EmailChannel`/`EmailTransport`/`FEmailTransport`/`ReceivedMail`/`ReceivedAttachment`/`ModelNames`）在 README:879/934/1013 均有条目；`isAuto` 未文档化（已由第 2 部分登记，不重复计数） |
| 文件覆盖（§13 等） | 20/20 | 本部分 `files/f_llm.part8.txt` 共 20 行且全部为 `.cj`，`.md` 为 0，§13 文档一致性在本部分无取证对象（只引用了 README 作为承诺源）；20 个文件全部读完，无跳过 |

### 第 9 部分

| 维度 | 命中 | 未命中时的说明 |
| --- | --- | --- |
| 正确性 / 设计 / 语言特性 / 可读性 / 安全性 | 4 | 安全性 1（#1）、正确性/契约 3（#2 #3 #4）；设计上 DAO 只依赖 `RootDAO.executor`、SQL 全在 DAO、无 `ORM.executor()` 越层，分层合规；语言特性无值/引用语义误用（DAO 无状态，无 `mut` 共享） |
| §1 死代码 | 1 | 逐个核对：3 个 `private` 顶层函数都有调用（`daoIntOf` → `MemoryDAO.cj:44`、`daoEscape` → `:56`、`meta/text` → `MetaDAO.cj:62`）；本部分无 `internal` / `protected` 声明；16 个 DAO 接口的约 70 个方法逐个 grep 调用点（`grep -rn "\.methodName\b"`，排除定义行），全部有 `store/**` 调用者；`public` 顶层类型（3 个 `type` 别名、1 个 `enum`）与 11 个 `public` 常量按硬原则一不判（`TOOL_TYPE_WEB_SEARCH` / `TOOL_TYPE_RETRIEVAL` / 5 个 `TODO_STATUS_*` 仓内零引用，仅记信息）。命中仅 `imports.cj` 的未使用 import（#9）。各文件 `return` 后无同层语句，无恒真恒假分支 |
| §2 重复逻辑 | 4 | 已按「输入-输出-副作用」两两比对：`MemoryDAO` 14 个函数、`MetaDAO` 14 个、`KnowledgeDAO` 11 个、`KindDAO` 6 个、`LoomDAO` 4 个、各 Evolution*DAO 5-6 个；跨文件按相同 SQL 片段/字面量/正则搜 `firstToMap`、`LAST_INSERT_ID`、`COALESCE(MAX(id)`、`enabled … weight > 0`、`ON DUPLICATE KEY`、`ON CONFLICT`、`replace("'", "''")`。命中 4 组（#12 ①②③④）。方言必需差异（`LIMIT a,b` vs `LIMIT ? OFFSET ?`、`CAST(… AS SIGNED)`、`true` vs `1`、`ON DUPLICATE KEY` vs `ON CONFLICT`、`myvector_construct` vs `::vector`）按误报边界不计；`CREATE TABLE` 文本虽在演进表两方言间同字，但索引/upsert 语句不同、且各方言独立演进，按 §2 误报边界保留两份 |
| §3 空实现 | 0 | 20 个文件无空函数体、无 `TODO` / `FIXME`、无 `catch {}`；`case None => ()` 只出现在 store 层（本部分无）；DAO 默认方法体全部执行 SQL |
| §4 栈溢出 | 0 | 本部分无递归、无自引用结构、无深度遍历；SQL 拼接都是单层循环（`for(index in 0..docIds.size)`），深度由常量界定 |
| §5 OOM | 0 | 逐个核对结果集物化：`listEntries` / `docIds` / `myList` / `myListByKind` / `chunkSearch` / `knowledgeList` 都由调用方传 `limit`（`pageOf` 默认 20/200）；`knowledgeAmong` 的 `IN` 元素数 = 本次候选数；`maxEntryId` 单行。无按不可信长度预分配、无全局只增容器。唯一的规模随数据增长点是 `JSON_ARRAYAGG`（服务端聚合，进优化方案 1 与假设 1，未定为缺陷） |
| §6.1 热点瓶颈 | 0 | 未提供 `cjprof` / `cjpm bench` / 分段计时数据，任何「热点」结论都不成立；三条性能线索（`JSON_ARRAYAGG`、`GROUP BY LONGTEXT`、无索引排序）已分别落到优化方案与假设表 |
| §6.2 大粒度锁 | 0 | DAO 层无锁、无临界区；`Mutex` 在 store 层（`EvolutionStore` / `EvolutionLease`），且临界区内只有 DAO 调用（DB I/O），属「串行化 DB 写」的必要设计，本部分不判 |
| §6.3 并发串行 | 0 | 本部分无 `spawn` / `Future` / 线程池；无批处理配置 |
| §6.4 低效算法 | 0 | 无嵌套循环匹配、无 `remove(at: 0)`、无循环内字符串 `+` 拼接（`quoted +=` 是单条拼接构造，元素数 ≤ 候选数，未测到热点，见假设表）；`LIKE '%…%'` 的前导通配符属设计选择，代价见假设 4 |
| §7 降堆内存方案 | 1 | 优化方案「标量查询走 `mapList`」（无基线） |
| §8 降 CPU 方案 | 2 | 优化方案「`JSON_ARRAYAGG` 收窄候选」「补 `processed_at` 索引」（均无基线） |
| §9 local mode 可行性 | 0 | DAO 层不产生函数内大临时对象（最大的是 `ArrayList<HashMap>` 结果集，且必须返回给调用方 ⇒ 逃逸），无 `Split` / 大数组中间结构；改造成本（实验开关 + 需 mode 重载的 std API）与收益不成比例，判定不可行 |
| §11 现有代码的 BUG（存量） | 6 | 本轮读到的 20 个文件、约 60 个函数逐个过了边界/空值/错误处理/资源/并发/契约：#1 注入、#2 跨语句会话状态、#3 过滤器丢弃、#4 列与 DDL 不符、#5 `INSERT IGNORE` 语义、#6 主键分配；其余（空集合入参、`LIMIT` 参数、`firstToMap` 空结果、CAS 条件更新）均已核对无缺陷 |
| §12 并发安全与锁粒度 | 1 | 已列出共享点：`SqlExecutor.getCurrent()` 为**线程级**（`f_orm/src/base/SqlExecutor.cj:113-144`），DAO 接口本身无字段 ⇒ 线程封闭成立，多线程并发调用安全；唯一的跨语句依赖是 `LAST_INSERT_ID()`（#2，判在 §11 的会话状态上）。锁粒度无问题（本层无锁） |
| §14 功能完备性与 README 覆盖 | 0 | 本部分无 `.md`；按 `src/` 公开声明对照 DAO 能力：`llm_conf` / 记忆 / 知识 / 种类 / loom / prompt / skill / token 用量 / 演进 9 组表都有对应 DAO 方法且都被 store 调用，无「注册了没接线」的方法；`TODO_STATUS_DELETED` 的缺失已在 #8 记（承诺源在代码注释而非 README，故不计入本行） |
| 文件覆盖（§13 等） | 20/20 | `files/f_llm.part9.txt` 共 20 行、全为 `.cj`，`.md` 为 0，故 §13「文档与代码一致性」在本部分没有独立 `.md` 取证对象；只按 `.cj` 内注释核对了 `ThinkingSwitch.cj:22-26`（与实现一致）、`TodoStatus.cj:18-26`（不一致，见 #8）、`postgres/EvolutionStateDAO.cj:23-28`（`__run__` 保留行，`store/*/EvolutionStateStore.cj:30/36` 确有使用）。20 个文件全部读完，无跳过 |

### 第 10 部分

| 维度 | 命中 | 未命中时的说明 |
| --- | --- | --- |
| 正确性 / 设计 / 语言特性 / 可读性 / 安全性 | 10 | 正确性 4（缓存竞态、零填充、失败转移退化、分页）、设计 2（异常层级、权重语义）、契约 1（usage 不落库）、安全性 2（TrustAll、转义不全）、可读性 1（注释错挂）；语言特性上 `resource`、`Option` 惯用法、`@DataAssist`、`Mutex` 用法均核对无问题；本部分无流式代码 |
| §1 死代码 | 3 | 逐个 `private` 符号全仓搜：`daoIntOf`、`text`、`responseOf`、`candidatesOf`、`isEmbedding`、`endpointOf`、`headersOf`、`embeddingIntOf`、`escape`、`postOnce`、`floatsOf` 均有调用者；`internal` 符号在本包及子包内核对；`public` 顶层声明（三个 DAO 接口、`BgeM3Transport`、`BgeM3Codec`、`HttpEmbedder`、`Embedding` 等）对外可达按硬原则一不判（`clearTokens`、`LlmEmbeddingTransport` 记「对外 API，仓内零引用」的信息，不计问题）；无 `return/throw` 后同层语句、无恒真恒假分支。命中 3 条：未使用 import（`imports.cj` 7 处 + `EmbeddingParam.cj:18`）、`EmbeddingParam.dimension` 与 `agentId/session` 读了不用、三处冗余中转变量与空语句 |
| §2 重复逻辑 | 3 | 本部分 20 个文件两两比对函数体「输入-输出-副作用」，并按错误消息 / 字面量跨文件搜：命中 `row.isEmpty()→None/Some` 6 处 + id 转换 2 处（1 条）、5 个异常类 + 2 个同名副本（1 条）、`escape` 与 `f_data` JSON 序列化重复（并入一般 #1）；另记：`Embedding.embed` 的候选循环与 `LLM.chat` 的失败转移循环同构（后者不在本部分，只作线索未计数）；`mysql/MetaDAO` 与 `postgres/MetaDAO` 的 SQL 差异是方言要求，不判重复 |
| §3 空实现 | 1 | 无空函数体 / `TODO` / `FIXME` / `UnsupportedException`；`EmbeddingResp.init()` 空体是 `@DataAssist` 数据类需要，非占位；命中 1 条：逐分量 `catch` 后补 `0.0`（静默吞异常）；另有 1 条同类（测试里的 `catch → SKIP`）计入轻微 #8 |
| §4 栈溢出 | 0 | 本部分无递归：`BgeM3Codec.parse` / `Embedding.parse` 只做单层 `data[0]` 取值，不递归 JSON 树；无自引用结构、无深拷贝；`JsonValue.fromStr` 的递归深度由 `f_data` 承担，不在本部分 |
| §5 OOM | 1 | 命中 1 条（并入优化方案/假设）：`postOnce` 用 `readEntire()` 全量读入，`colbert` 按 token×1024 预分配，`HttpEmbedder` 单槽缓存长期持有；8192 token 时 `colbert` 约 64MB，叠加 JSON 原文与 `JsonValue` 树峰值更高；未见文本长度或响应大小上限。无实测峰值数据，故不作缺陷 |
| §6.1 热点瓶颈 | 0 | 无 `cjprof` / `cjpm bench` 数据，任何热点结论都不成立；三个候选（HttpClient 重建、JSON 分量转换、缓存命中率）已进「待验证假设」#1/#2/#3 |
| §6.2 大粒度锁 | 0 | 本部分唯一的锁是 `Embedding` 的静态 `mutex`（`Embedding.cj:42-57`），只包一次引用读写、无 I/O，粒度已最小；DAO 层无线程级锁 |
| §6.3 并发串行 | 0 | 无 `spawn` / `Future` / 批处理；重试是同步 `sleep` 退避，属延迟问题（一般 #2），不是串行热点 |
| §6.4 低效算法 | 1 | 命中 1 条并入一般 #5：`ORDER BY 非唯一键 + OFFSET` 在深分页下随表增长线性扫描且结果不稳定；其余无嵌套循环、无 `contains` 热点、无循环拼串（`BgeM3Codec` 的 `ArrayList` → `toArray()` 是一次性复制，计入优化方案） |
| §7 降堆内存方案 | 1 | 1 条（去掉跨调用缓存），`无基线（待验证）` |
| §8 降 CPU 方案 | 2 | 2 条（JSON 数值直取、连接复用），均 `无基线（待验证）` |
| §9 local mode 可行性 | 0 | 已确认模块开启 `--experimental --enable-local-mode`；`parse` 路径的中间对象多数不逃逸，但收益只能用峰值内存证明，缺改前/改后对照 → 只作待验证（见「待验证假设」后的说明），不进方案 |
| §11 现有代码的 BUG（存量） | 18 | 逐函数核对 20 个文件的边界 / 空值 / 错误处理 / 资源 / 契约：严重 3、一般 7（其中 2 条为契约不符）、轻微 8（含 2 条纯可维护性）；`TokenUsageDAO` 与 `DefaultEmbedder` 未发现缺陷；DAO 的 `arg()` 绑定顺序与占位符顺序逐条对得上（`MemoryDAO.cj:55-74`、`:105-124`） |
| §12 并发安全与锁粒度 | 2 | 共享点逐条列出：①`DefaultEmbedder`(singleton)→`HttpEmbedder.cachedText/cachedResponse`（无同步，严重 #1）；②`BgeM3Transport.embed`→`HttpClient` 静态 `readTimeout_/writeTimeout_`（无同步，严重 #2）。`Embedding.transport` 已用 `Mutex` 保护；`BgeM3Transport` 自身字段全 `let`，无实例状态；DAO 无实例状态（`@DAO` 方法每次取当前 executor） |
| §14 功能完备性与 README 覆盖 | 1 | 本部分 0 个 `.md`，README / `doc/**` 的覆盖与一致性在含 `README.md` 的分部分核算。本部分的「承诺源」是代码注释与字段：命中 1 条「传了但不用」的接线缺失（一般 #7，`agentId/session` + `EmbeddingResp.usage`）；`@Bean DefaultEmbedder` 有消费方（`ContentStore.cj:69-75`），未见「注册未触发 / 开关走进空分支」 |
| 文件覆盖（§13 等） | 20/20 | 20 个文件全部读完，无跳过；本部分无 `.md`，§13 的文档一致性只覆盖注释层（轻微 #4 / #5） |

### 第 11 部分

| 维度 | 命中 | 未命中时的说明 |
| --- | --- | --- |
| 正确性 / 设计 / 语言特性 / 可读性 / 安全性 | 8 | 正确性 5（#1 空 choices、#2 usageEstimated、#3 畸形字段、#6 content 丢弃、#7 temperature 语义）；设计 2（#13 重名异常类型、#14 用例归属）；语言特性 1（#8 有 `asInt` 不用）。安全性 0：`CallLog.summary` 的 `auth` 走 `Redactor.mask`（`util/Redactor.cj:31-36`，≤8 字符整段掩码），日志无报文正文；本部分无 SQL / 路径拼接 / 外部输入直接进缓冲区 |
| §1 死代码 | 2 | 逐个非 public 符号搜引用：`rewriteMultimodal` / `toWirePart` / `contentTextOf` / `appendMessage` / `fillUsage`（均在 `ChatCompletionsMapper` 内被调）、`CallLog.log`、`DummyTokenUsageSaver.log` / `instance` / `init`（`AgentTask.cj:126/133`）、`textOf` / `stringOf`×2 / `intOf`（包内跨文件使用，`ChatStreamAccumulator` / `ResponsesMapper`）均有调用者。命中：两个 `private init(){}`（#9，编译器 `unused` warning 佐证）、`finder/imports.cj:21` 的 `f_orm` import（#10）。`public` 按硬原则一不判：`RoleException` / `SkillNotFoundException` / `AgentsFinder` / `CodeFinder` / `KnowledgeFinder` / `SpecificationFinder` 仓内零引用只记信息（并见 #13 的可见性建议） |
| §2 重复逻辑 | 3 | 把本部分 8 个函数体压成「输入→输出→副作用」两两比对：`fillUsage` / `fillStreamUsage` / `contentTextOf` / `textOf` / 两版 `stringOf` 判 #11；`build` 三段与 `ResponsesMapper.build` 判 #12（差异点已列：tool 条目形状属业务要求，`response_format` 属缺失）；6 个异常类 + 两包同名 `RoleException` 判 #13。`SystemMessage` / `UserMessage` / `AssistantMessage` 仅 role 常量不同，属业务语义要求不合并；测试脚手架（`mapperConf` / `mapperParams` vs `facadeConf`）按误报边界不判 |
| §3 空实现 | 0 | `ExperienceFinder` / `IndividualityFinder` 是继承 `MemorySummaryFinder` 的标记接口，非默认空实现；`DummyTokenUsageSaver.saveTokenUsage` 是 `lookupOption` 失败时的日志兜底（`AgentTask.cj:126/133`），命名与调用点已表明语义；无 `TODO` / `UnsupportedException`，本部分无 `catch {}`（`parse` 的 `else` 缺失按「只做了一半的分支」记 #1 / #2，不重复计 §3） |
| §4 栈溢出 | 0 | 全部函数为单层循环或嵌套 `match`（`contentTextOf` 的 match 深度 2），无自递归、无 A→B→A；`build` / `rewriteMultimodal` 的遍历深度由消息条数决定但为迭代而非递归 |
| §5 OOM | 0 | 无全局集合、无按报文长度预分配、无「一次提交全量任务」。`build` 的整份会话物化是有界内存（上限 = 会话大小），已作为优化方案（堆内存）而非缺陷；最坏量级见该方案「现状」 |
| §6.1 热点瓶颈 | 0 | 无 profile / bench 数据（`docs/` 下只有 `LocalMode*.md`，不含本部分函数），不满足「函数级自耗时占比 + 输入规模 + 对照」三项，热点结论不成立，已列入待验证假设 #1 / #2 |
| §6.2 大粒度锁 | 0 | 本部分无锁、无 `synchronized`、无临界区；`CallLogger` / `DummyTokenUsageSaver` 的 `static let log` 是日志门面，不在锁内做 I/O |
| §6.3 并发串行 | 0 | 无 `spawn`、无 `Future.get`、无线程池与批处理（`finder` 的 `lookup` 是启动期注入，不在循环里） |
| §6.4 低效算法 | 0 | 已核 `rewriteMultimodal`（O(消息数×片段数)，单遍）、`toWirePart`（O(1)）、`parse`（只取 `choices[0]`）。`intOf` 的 `toString+tryParse` 是常数级放大，按轻微缺陷处理（#8），不构成算法级问题 |
| §7 降堆内存方案 | 1 | 见优化方案「请求体三级物化」（`无基线`） |
| §8 降 CPU 方案 | 1 | 见优化方案「候选循环内重复序列化」（`无基线`） |
| §9 local mode 可行性 | 0 | `f_llm/cjpm.toml:9` 已开 `--enable-local-mode`；`build` 的返回值 `JsonObject` 逃逸（返回给 `LLM.call` 并 `toString`），可 local 化的只有 `rewriteMultimodal` / `toWirePart` 内部临时件，收益只能用峰值内存证明，当前无对照数据 → 待验证假设 #4 |
| §11 现有代码的 BUG（存量） | 6 | 已核对 `parse`（`choices` / `message` / `usage` / `content` / `tool_calls` 五个可选字段的空值与类型）、`fillUsage`、`contentTextOf`、`intOf`、`build` 的温度 / stream / response_format / tools 四分支、`rewriteMultimodal`（parts 空 / content 共存两种边界）→ 命中 #1 / #2 / #3 / #6 / #7 / #8；其余边界（`detail` 缺省、`tool_calls` 无 `function` 时回退 `JsonObject()`）已确认有兜底 |
| §12 并发安全与锁粒度 | 0 | 本部分唯一被多线程共享的是 `DummyTokenUsageSaver.instance`（不可变 struct，只持有 `static let` logger）与 `ChatMessage` / `LLMResp` 这类**按请求构造**的模型对象；未发现全局 `var` / 单例可变字段 / 惰性初始化 / 发布逸出。`ChatMessage` 可变异（`addText` / `addImage` / `addToolCall`）但生命周期限于单次请求组装；范围外提示：若上层把同一 `LLMParams` 跨线程复用并并发追加消息，本部分不提供任何保护，也未声明线程安全 |
| §14 功能完备性与 README 覆盖 | 2 | #5（`CallLog` 未接线，双证：`doc/f_llm.md:157/581` + `README.md:875` 为承诺源，`grep` 零生产调用为缺失证据）、#13（同名 `RoleException` 两处定义）。README 的 API 索引已覆盖本部分全部 public 符号（`:864` / `:875` / `:881-882` / `:901`），无「public API 未文档化」；但多模态 `content` 丢弃语义（#6）在 README 中完全没有说明，只能从类型注释与测试反推 |
| 文件覆盖（§13 等） | 20/20 | 清单 20 个文件全部读完，无未读项；本部分清单不含 `.md`，§13 的「文档一致性」只做跨文件交叉核对（命中 `doc/f_llm.md:157/581` 一处，已并入 #5） |

### 第 12 部分

| 维度 | 命中 | 未命中时的说明 |
| --- | --- | --- |
| 正确性 / 设计 / 语言特性 / 可读性 / 安全性 | 15 | 正确性 9（截断当成功、坏帧丢工具调用、就地改入参、越界、空 choices、200 非 JSON、token 估算口径、conf 选择、enabled 失效）；设计 3（熔断只挂 byName、饱和判定两处、balancer 版本）；安全性 2（TrustAll、无界超时）；可读性 1（`phase: read` 恒标、tried 丢弃）。语言特性上 `Option`/`synchronized`/`resource` 用法均正确，`String` 字节切片是唯一踩坑点（严重 #5） |
| §1 死代码 | 1 | 逐个核对了本部分全部 `private`/包级符号：`ToolCallFragment`、`fillStreamUsage`、`estimateTokens`、`defaultConfSelector`、`callByName`、`call`、`stream`、`previewOf`、`nextRequestId`、`balancerFor`、`refresh`、`createHolder`、`defaultSupplier` 均有调用者。命中：`LLMCandidateProvider.cj:21` 未使用的 `import fountain::f_bean.*`；`LLMParams.cj:123` `Property` 全仓零引用（对外 `public`，只记信息，不算死代码）。对外可达的 `public`（`CircuitBreaker.size`、`LLMErrorClassifier.isFatal`、`LLMConfs.isConfigured`、`LLMConfsHolder.getTokenThreshold`、`LLM.getStreamTransport`、`LLM.respondStream`、`ChatStreamAccumulator.finished`、`ContentPart.init()`）仓内零引用或仅测试引用，按硬原则一**不判**死代码，仅作可见性信息 |
| §2 重复逻辑 | 3 | 同文件两两比对：`LLM.call` 与 `LLM.stream` 的「遍历候选 + 建 body + decorate + ThinkingPolicy + 错误分类」同构，但可操作部分是钩子漂移（已计入一般 #3），不重复计数；`RetainLastUserPruner` 与 `RetainLastNRoundPruner` 的「倒序遍历 + 追加」结构相似但语义不同（一条 vs 一段），不合并。命中：饱和阈值两处（一般 #12）、Summary/Keywords 近似重复（轻微 #6）、`LLMParams` 三处近重复（轻微 #7）。`estimateTokens(content)+4` 在 `ContextPruner.cj:229` 与 `TokenCounter.cj:47` 各写一遍（后者属第 13 部分，只记一句范围外提示） |
| §3 空实现 | 1 | 全部分支体均已实现；`LLMHooks` 的 no-op 默认值有注释说明（Null Object，不算问题）。命中：`LLMCandidateProvider.cj:41` / `LLMConfs.cj:54` 的 `catch → 空列表/回退`（静默吞异常，一般 #13） |
| §4 栈溢出 | 0 | 本部分无递归：裁剪是线性遍历，`ChatStreamAccumulator` 归并按帧循环，`CircuitBreaker`/holder 无自调用。`JsonValue.fromStr` 的递归深度由上游报文决定，不在本部分实现内 |
| §5 OOM | 0 | 未发现无界容器：`fragments` 按 `tool_calls.index` 有界，`content/reasoning` 由模型输出（`max_tokens`/`streamMaxLineBytes` 1MB 限定），`states`/`balancers` 由配置条数决定且刷新时清理；`LLMConfsHolder` 每次刷新新建快照（旧快照随在途请求释放）。一般 #7 放大的是「装载次数」而非内存 |
| §6.1 热点瓶颈 | 0 | 未提供 `cjprof`/`bench` 数据，任何「热点」结论都不成立；四个可疑点（流式每帧 JSON 解析、balancer 全局锁、候选列表复制、transport 短锁）全部降级进「待验证假设」#1-#3 |
| §6.2 大粒度锁 | 1 | `LLMConfs.holder()`（`LLMConfs.cj:61-71`）在 `synchronized(mutex)` 内调用 `createHolder()` → `StoreSettings.load()` + `MetaStoreAdapter()` 构造（可能是文件/DB I/O）；只影响首次初始化，属低频但确实「锁内 I/O」。`LLMConfsHolder.balancerFor` 的锁内只做内存操作，未达大粒度锁判据（竞争影响进优化 1） |
| §6.3 并发串行 | 0 | 本部分无 `spawn`/`Future.get`；单飞标志（`refreshing`）是有意的合并策略，不构成串行热点证据 |
| §6.4 低效算法 | 0 | 无嵌套循环、无 `remove(at: 0)`、无循环拼串；`LLM.callByName` 失败分支的 `names.contains`（`LLM.cj:117`）是 O(n²) 但只在抛异常前执行一次，规模=配置条数，不成立为缺陷 |
| §7 降堆内存方案 | 2 | 候选列表每请求复制（优化 2）、`result()` 拼接临时串（优化 3）；其余候选缺少分配量基线，只进待验证假设 #1 |
| §8 降 CPU 方案 | 2 | balancer 全局锁与版本判断前移（优化 1）、transport 全局锁（优化 4） |
| §9 local mode 可行性 | 0（1 条待验证） | `ChatStreamAccumulator` / `ResponsesStreamAccumulator` 确在 `stream()` 内创建，但被 transport 回调闭包捕获、且缺逃逸分析与峰值数据 → 只列假设 6，不写成方案 |
| §11 现有代码的 BUG（存量） | 26 | 逐函数核对了 20 个文件的边界/空值/错误处理/资源/并发/契约：严重 5、一般 14、轻微 7（含 1 条测试质量）。另核对了 `CircuitBreaker` 冷却/清理的算术、`LastNContextPruner`/`TokenBudgetContextPruner` 的边界（均有保护）、`DRCContextPruner` 的分组顺序、`ContextPrunerMediator` 的并发注册（check-then-act 在锁内，正确），未发现其它缺陷 |
| §12 并发安全与锁粒度 | 3 | 逐点给出共享路径与同步手段：`LLM.transport/streamTransport/counter`（`Mutex` 保护，读路径也是短锁，正确）、`CircuitBreaker.states`（`Mutex`，正确）、`ContextPrunerMediator.pruners`（`ConcurrentHashMap` + `Mutex`，重复保护但安全）、`LLMCandidateProvider.supplier`（`Mutex`，正确）、`LLMConfsHolder.snapshot`（**无同步**，一般 #1/#2）、`HttpClient` 的进程级 static 超时被跨模块改写（严重 #2）。`ChatStreamAccumulator` 为单线程栈对象（transport 回调同线程），线程封闭 |
| §14 功能完备性与 README 覆盖 | 2 | `enabled` 开关未接线到 file/env 来源（一般 #6）、流式无 by-name/熔断接线（一般 #3）。README/`doc/**` 的覆盖问题属第 1/2 部分，本部分只记录实现侧缺失；`LLMConfs.isConfigured` 这类公开但仓内无调用的入口不算缺失 |
| 文件覆盖（§13 等） | 20/20 | 本部分清单 20 个文件全部读完；无 `.md` 文件，§13 唯一命中是轻微 #8（README 属其他部分，跨部分去重） |

### 第 13 部分

| 维度 | 命中 | 未命中时的说明 |
| --- | --- | --- |
| 正确性 / 设计 / 语言特性 / 可读性 / 安全性 | 8 | 安全性 1（严重第 1 条）、正确性 3（一般第 2、3、7 条）、契约/设计 2（一般第 1、5 条）、边界 1（轻微第 12 条）、语言特性 1（一般第 6 条 `mut prop` 默认实现语义）、归一/大小写 1（轻微第 16 条）。语言特性另核对：`return` 位于 `match` 分支内确实从函数返回（`ResponsesStreamAccumulator.feed:55`、`ChatStreamAccumulator.mergeDelta:88`），故两处 `feed` 的尾 `None` 不是死语句；`JsonValue.asObject/asArray` 类型不符会抛 `JsonException`（`f_data/src/json/JsonValue.cj:56-80`），故"缺守卫"类判断按抛异常而非静默处理 |
| §1 死代码 | 2 | 逐个符号核对：本部分只有 8 个包级/`private` 函数（`ResponsesMapper.textOfReasoning/textOfMessage/contentOf/messageToJson`、`ProviderDialect.trimTrailingSlash`、`ProviderDialects.bearerHeaders/applyThinkingObject/setThinkingType`），全部有调用者（含 `trimTrailingSlash` 被 5 个方言调用）；`DialectRegistry.ensureBuiltins` 被 `resolve` 调用；无 `internal`、无 `protected` 声明；`public` 顶层类型（`LLMHttpResponse`/`LLMTransport`/`DefaultHttpTransport`/`ModelCapabilities`/`ThinkingPolicy`/`ResponsesMapper`/`ResponsesStreamAccumulator`/`TokenizerParams`/`TokenCounter` 家族/`ProviderDialect` 家族/`LoomA2a` 家族/`A2aCallFunction`/`A2aCallParam`/`SupervisorAgent`）按硬原则一不判——`TokenizerParams`、`FrequencyPenalty`、`ThinkingBudget`、`DoSample`、`DialectRegistry.providers`、`ModelCapabilities.blocksTemperature`、`LoomA2a.server/reset` 仓内零引用（或仅测试引用），已在文件覆盖表记为信息、不计问题。命中 2 处：未使用 import（第 5 条）、`build` 里 3 个 no-op `remove`（第 6 条）。各文件 `return`/`throw` 后无同层语句 |
| §2 重复逻辑 | 5 | 同文件内两两比对（`ResponsesMapper` 6 个函数、`ProviderDialects` 5 个 `endpoint` + `bearerHeaders`/`applyThinkingObject`/`setThinkingType`、`TokenCounter` 2 个实现、`A2aBridge` 3 个类）：命中 `textOfReasoning`/`textOfMessage`（第 3 条）。跨文件按相同语句/字面量搜 `trimTrailingSlash(conf.url)`、`'Bearer ${conf.auth}'`、`'application/json'`、`Accept-Encoding`、`effective < 0.0f64`、`body.remove('thinking')`：命中方言 `endpoint`/`headers`（第 1 条）、两个 mapper 的 temperature/stream/tools（第 2 条）、`util.http` 与 `DefaultHttpTransport`（第 4 条）、`usage.cached` 缺失（第 10 条）。判定为非重复：`AliyunDialect.decorate` 与 `applyThinkingObject`（字段形态完全不同）、`Chat`/`Responses` 的工具定义（线上形状不同，属协议要求）、`DeepSeekDialect.decorate` 与 `SiliconFlowDialect.decorate`（函数体恰好相同，但分属两个独立演进的平台方言，合并会把"某平台多剥一个字段"变成改共享函数，按误报边界保留——它们的模板重复已由第 1 条覆盖） |
| §3 空实现 | 1 | `DoSample.set(value){}`（一般第 6 条）。`StandardDialect.decorate` 空函数体有注释声明"默认什么都不做"，属有意的 Null Object，不判；`RemoteTokenCounter` 的 `catch(_: Exception) → -1` 与类注释「没配、失败、无 usage 都返回 -1」一致，是显式契约不是吞异常；无 `TODO`/`FIXME`/`UnsupportedException` |
| §4 栈溢出 | 0 | 本部分无递归（无函数自调用、无树/图遍历）；`trimTrailingSlash` 是单层 `while`，`ResponsesMapper` 的嵌套只有 `for output[] → for content[]` 两层，深度由单条报文固定 |
| §5 OOM | 0 | 没有按不可信长度预分配（`Array(n)` 只出现在 `SseReader`，范围外）；`LLMHttpResponse.body` 是单个响应体（上界由模型输出决定）；`RemoteTokenCounter` 的全量拼接是"两份会话副本"，量级受上下文窗口约束，未量化前只写进优化方案 2 与待验证假设，不作缺陷 |
| §6.1 热点瓶颈 | 0 | 未提供 `cjprof` / `cjpm bench` 数据；"每请求 TLS 握手""全局锁"已列入待验证假设 1-2 与优化方案 1，不作缺陷、不计严重度 |
| §6.2 大粒度锁 | 0 | 本部分唯一的锁是 `DialectRegistry.mutex`（`ProviderDialect.cj:89`），临界区内只有 `HashMap.contains/get/赋值` 与 5 次 `new Dialect()`（`ensureBuiltins` 内、一次性），无 I/O、无解析、无回调；不在 §6.2 的可报形态内，竞争比例见待验证假设 2 |
| §6.3 并发串行 | 0 | 无 `spawn`、无批处理、无单消费者队列；`LoomA2a` 是启动期一次性注册 |
| §6.4 低效算法 | 0 | 无嵌套循环匹配、无 `remove(at: 0)`、无循环内字符串 `+`（`StringBuilder` 用得正确）；`trimTrailingSlash` 对多斜杠是 O(n²) 但输入是配置常量，不构成可报项 |
| §7 降堆内存方案 | 1 | `RemoteTokenCounter` 双份全量 prompt（无基线，待验证） |
| §8 降 CPU 方案 | 1 | HTTP 客户端复用（无基线，待验证） |
| §9 local mode 可行性 | 0 | 本部分"函数内创建的大对象"只有 `ResponsesMapper.build` 的 `JsonObject` 图与 `textOfMessage` 的 `StringBuilder`，两者都作为返回值/成员逃逸（`build` 返回 `JsonObject` 交给 `body.toString()`，`textOf*` 返回 `String` 存进消息），`@ local!` 无法生效；`estimateTokens` 只有 1 个 `String` 参数读取，无临时大对象，收益无法用峰值内存证明 |
| §11 现有代码的 BUG（存量） | 24 | 本轮 20 个文件逐函数核对边界/空值/错误处理/资源/契约，24 条全部为存量缺陷（严重 1 + 一般 7 + 轻微 16），其中 18 条以 §11 为主要判据、6 条以 §1/§2/§3/§12/§14 为主要判据但同时是存量问题。另核对了 4 处"疑似但非缺陷"：`ensureBuiltins` 快路径裸读 `builtinsLoaded`（`dialects` 的读写全在锁内，最坏只是多拿一次锁，不构成可见性缺陷）、`StandardDialect.decorate` 空实现（有注释的 Null Object）、`RemoteTokenCounter` 吞异常（注释声明的 -1 契约）、`ResponsesMapper.parse` 用 `status` 当 `finishReason`（下游只用于日志，`CallLogger.cj:37`，非契约破坏） |
| §12 并发安全与锁粒度 | 1 | 轻微第 8 条（`started` 与 `lastServer` 分处两个临界区、注册在锁外）。其余：`DialectRegistry` 的 `dialects` 所有读写都在 `mutex` 内（`register`/`get`/`ensureBuiltins`/`providers`），无共享可变状态逃逸；`LLMTransport`/`ResponsesMapper` 都是无状态 struct/新建对象，可并发调用；`LoomA2aClient.send` 是闭包里的局部对象，线程封闭 |
| §14 功能完备性与 README 覆盖 | 2 | 一般第 1 条（Responses 映射缺 `max_tokens`/`response_format`，属"承诺同一 `LLMParams` 契约但只做一半"）、一般第 5 条（A2A 卡片未按 spec 从配置拼出）。README 覆盖：本部分全部公开类型都已进 `f_llm/README.md:864` 的模块清单，`DialectRegistry`/`LoomA2a`/`ModelCapabilities`/`ResponsesMapper` 在 `:900/:956/:986/:1017` 有成员级清单；唯一遗漏是 `ResponsesStreamAccumulator` 的 `public func result()` 未登记（`:1018` 只有 `feed/finished/isDone`），已并入轻微第 9 条、不单列计数 |
| 文件覆盖（§13 等） | 20/20 | `files/f_llm.part13.txt` 共 20 行、全部为 `.cj`，`.md` 为 0，故 §13「文档与代码一致性」在本部分没有独立 `.md` 取证对象；只按 `.cj` 注释核对（`ResponsesMapper` 顶部三条结构差异、`ProviderDialects` 各平台思考规则、`A2aCallFunction` 的"不抛异常"契约）均与实现一致。承诺源取自范围外的 `doc/spec/add-loom-a2a/proposal.md`、`f_llm/README.md`，仅作判据引用 |

### 第 14 部分

| 维度 | 命中 | 未命中时的说明 |
| --- | --- | --- |
| 正确性 / 设计 / 语言特性 / 可读性 / 安全性 | 11 | 正确性 7（S1、S2、G2、G3、G4、G7、G8）、设计 1（G6 配置分发缺统一工厂）、安全性 1（S1，与正确性同一根因，跨用户对话串台）、可读性 2（M1、M6）；语言特性 0：本部分只用了 `synchronized` + Box 带值这一惯用法，已逐个核对（`LeaseTextBox`/`ScopeBox`/`AgentSeqBox`/`TurnsBox`/`BoolValue` 都是同一原因的产物，无捕获可变局部变量问题） |
| §1 死代码 | 3 | 已逐个检查 20 个文件的 `private` / `internal` / `protected` 符号与 `import`：`private` 全部有引用（`CodeGen.firstStep/jsonQuote`、`FStoreLoomStore.put/text/INDEX/DATA/SEP`、`LoomAgent.nextSeq/seq/seqMutex`、`LoomContextLog` 私有三项均被本文件使用）；`internal` 的 `LoomBootstrap.requestOf` 被 `LoomService.cj:111,131` 使用，`StepSourceCodec`（在 `SqlLoomStore.cj`）被本文件使用。命中 3 条：M3（`EvolutionLeases.bootstrap` 返回值被唯一调用点 `let _ =` 丢弃）、M7（`CodeGen` 的 http 分支经 `validate` 后恒不可达）、M8（`BackgroundTasks.cj:18` 未使用 import）。对外可达的 `public`（`MemoryRecorderTask`/`SkillEvolutionTask`/`JitTicktockTask`/`LoomAgent`/`CodeGen`/`FStoreLoomStore` 等）按硬原则一不判死代码，只记「仓内引用面」；`LoomHost.render` 是接口方法且存在实现，属接口契约不判死代码（其「零生产调用」记在 M2 的可见性建议里） |
| §2 重复逻辑 | 2 | 已把 20 个文件里的函数体压成「输入→输出→副作用」摘要两两比对：命中 G1（三份源码模板）与 M6（`BoolValue` vs 同包 `BoolBox`，以及 5 个同构 Box）。已核对差异后**不报**的两组：三个 `EvolutionXxx.byName` 结构相同但返回类型不同（已并入 G6 的「抽统一工厂」建议，不重复计数）；`SkillEvolutionTask.evolve` 与 `SkillEvolutionJob.cj:426` 只共享一句 `Skill(... version+1)` 构造，其余是完整的策略/门禁/留档差异，属业务差异不判重复（漂移风险已在 G7 说明） |
| §3 空实现 | 2 | 无 `TODO`/`FIXME`/`UnsupportedException`/空函数体（`grep` 全 20 文件 0 命中）。命中：4 处 `catch → ()` 静默吞异常（M1，其中 `JitTicktockTask` 有注释与 `doc/loom.md:195` 说明「异常全吞」，故 M1 不按严重计）；S2 的失效机制正是「异常被吞 + 宿主未绑定」，单独按承诺落空记为严重 |
| §4 栈溢出 | 0 | 20 个文件无递归、无自引用结构、无深度遍历；`CodeGen`/`LoomBootstrap`/`FStoreLoomStore` 全为单层或双层 `for`/`while`，深度与输入规模无关 |
| §5 OOM | 0 | 逐个核对无界容器：`LoomContextLog` 有 `MAX_TURNS=200` 上限（`:79-87`）；`FStoreLoomStore.list` 一次只物化页内结果，但 `names` 全量持有全部流程名（与流程数同阶，非请求可控）；`LoomAgent`/`LoomProgram` 持有计划与源码，生命周期与编译产物一致。未发现按不可信长度预分配或全局集合只增不减 |
| §6.1 热点瓶颈 | 0 | 未提供 `cjprof` / `cjpm bench` 数据（`doc/perf-baseline.md` 属模块其他部分，本部分未取到针对这些文件的测量），不构成热点结论；相关线索已写入「待验证假设」1-3 |
| §6.2 大粒度锁 | 0 | 本部分唯一锁是 `LoomContextLog.mutex`、`LoomCharacterScope.mutex`、`LoomAgent.seqMutex`：临界区内只有内存赋值/克隆，无 I/O、无日志、无序列化、无回调；`LoomHostApi`（范围外）已把渲染移到锁外 |
| §6.3 并发串行 | 0 | `LoomBootstrap.startup` 串行编译、`FStoreLoomStore.list` 逐条 `get` 都是串行段，但没有并发度/耗时数据，不足以判「并发上不去」；已拆到优化方案 1 与待验证假设 1 |
| §6.4 低效算法 | 0 | 结构性 O(n²) 位置有两处（`CodeGen.flowSource` 循环 `+=`、`FStoreLoomStore.list` 每页重扫 + 插入排序），已按「无基线不得写成结论」放进优化方案，不计入发现 |
| §7 降堆内存方案 | 0 | 本部分没有「无界持有多份副本」的形态：7 字段拆键写入是为了避转义（`FStoreLoomStore.cj:40-41` 有说明），`LoomProgram` 的三份源码是审计必需。可降的只有 `LoomContextLog` 的单轮字符串体积，缺峰值数据（待验证假设 2） |
| §8 降 CPU 方案 | 2 | 优化方案 1（`list`/`restore` 分页重扫）、方案 2（`flowSource` 拼接）；均 `无基线`，不进 tasks |
| §9 local mode 可行性 | 0 | 本部分函数内的临时对象都会逃逸（`CodeGen.generate` 返回 `GeneratedFlow`、`FStoreLoomStore.get` 返回 `LoomFlow`、`snapshot()` 返回 `ArrayList`），加 local 标注需先 `exclave`，且收益只能用峰值内存证明——无数据，不成立 |
| §11 现有代码的 BUG（存量） | 11 | S1（生命周期错配）、S2（宿主未绑定 + 吞异常导致承诺落空）、G2（`async` 与派发不符）、G3（写序导致状态/内容不一致）、G4（工具结果静默降级）、G5（失败路径二次抛错）、G6（配置静默降级）、G7（演进绕过门禁）、G8（文档值 `inMemory` 选错租约实现）、M4（status/offset 未校验）、M5（README 机制描述与接线不符）；每条都给了位置与判据，边界/空值/资源/并发四类均已覆盖（S1 另计入 §12、G6/G8 另计入 §14，故本行 11 项 > 报告 10 条存量缺陷） |
| §12 并发安全与锁粒度 | 1 | 已列出全部共享点：`LoomContextLog.turns/active`（S1，缺执行级隔离）、`LoomCharacterScope.installed`（锁内读写，安全）、`LoomAgent.seq`（锁内自增，安全）、`LoomHostApi.*`（范围外，`LoomHostApi.cj:28` 已声明「单线程使用」但无运行时约束——见范围外提示）；`FStoreLoomStore` 无自身可变状态，跨键一致性属 §11（G3）；无锁内 I/O、无锁顺序问题、无 `spawn().get()` |
| §13 文档一致性 | 3 | 本部分无 `.md`；按承诺源交叉核对了 `doc/loom.md` 与 `README.md` 中涉及本部分符号的段落，命中 M5（定时任务机制描述）、G6（「未知取值直接抛错」只对 `storeFor` 成立）、G8（`README.md:764` 的租约取值清单与 `byName` 实现不符）、M7（`doc/loom.md:509` 声明 http 被拒绝，`CodeGen` 注释仍写 http 内联）；`doc/loom.md:231-244` 的 `LoomContextLog` 生命周期描述与实现「单例」不符，已并入 S1 的 §11 判据 |
| §14 功能完备性与 README 覆盖 | 3 | 本部分 public 符号在 `README.md:920-1034` 的 API 清单里均能检索到（`FStoreLoomStore`/`LoomAgent`/`LoomContextLog`/`MemoryRecorderTask`/`SkillEvolutionTask` 等），无「公开 API 未进 README」；命中：S2（`README.md:533` 承诺单步任务由 `JitTicktockTask` 承接，但它没有宿主可绑）、G8（`README.md:764` 承诺租约跟随 `inMemory`，实现落到 f_store）、G7（`SkillEvolutionTask` 与生产演进链路双入口且行为不同）。`recordWithTimeout` 仓内零调用但有文档（`doc/loom.md:202`、`README.md:984`），记为「对外 API，仓内无引用」信息项 |
| 文件覆盖（§13 等） | 20/20 | 本部分文件清单 20 行（全 `.cj`）逐行读完，无跳过；`.md` 清单项为 0 |

### 第 15 部分

| 维度 | 命中 | 未命中时的说明 |
| --- | --- | --- |
| 正确性 / 设计 / 语言特性 / 可读性 / 安全性 | 11 | 正确性 #2/#3/#5/#7/#8；设计 #9/#10（状态所有权与覆盖语义）；语言特性 #14（`Int64`/`String` 取值漂移）、#17（字符串当枚举）；可读性 #13/#17；安全性 #1（跨租户人格/记忆串写）、#7（`userId` 静默归零写公共桶） |
| §1 死代码 | 3 | 逐个核对 20 个文件的 `private` / `internal` / `protected` 符号：`release(Flow<EndExecutorGetter>)` 零调用（#13）、`LoomMemoryPolicy` 的 `f_log` 导入未使用（#13）、`LoomExecuteParam.dryRun` 写了不读（#4）。`buildCount`/`resetBuildCount` 与 `LoomHostApi.valueOf` 只被测试用，按「可见性建议」处理（#13），不判死代码；`public` 且对外可达的声明（`LoomHostApi` / `LoomRegistry` / `LoomService` / `LoomRunner` / `LoomScheduler` 等顶层 `public` 类成员、`LoomStore` 接口）按硬原则一不判 |
| §2 重复逻辑 | 1 | 已两两比对本部分 20 个文件里所有具名函数体摘要：3 份 `fieldOf/strOf`、3 份 `textOf`、2 份逐行相同的 `release`、`execute` 两分支装配、7 处手写 JSON 数组（#14）。其余同形函数（`LoomStoreGateway` 的 6 个 `xxxJson`、`LoomRegistry_test` 的 `flow()`）字段各不同，属业务差异，不合并 |
| §3 空实现 | 2 | `release(Flow<EndExecutorGetter>)` 空 body（#13）；`LoomDefaults.chat` 无助手消息返回空串（#15）。`LoomRegistry.put/remove` 的 `case None => ()`、`LoomRunner.resolvePersona` 的 `catch { () }` 都是有注释的"未装配即降级"分支，不算；`LoomMemoryExtractor` 知识分支的静默 `catch` 单列在 #16 |
| §4 栈溢出 | 0 | 本部分无递归：`topologicalOrder` 为迭代 Kahn，`LoomStoreGateway.call` 是扁平 `if` 链，`LoomRunner.bodyOf` 只有一层闭包。`JsonValue.fromStr` 的递归在 std 内部，不属本部分 |
| §5 OOM | 1 | `LoomRegistry.flows` 只增不删（#12，已给 3~8 KB/条 × 10 万条的估算，增速需实测）。其余容器有界：`LoomContextLog` 上限 200 轮（`MAX_TURNS`）、`values` 按步骤数、`digestOf` 按 `maxTurns`、`LoomMemoryE2E_test` 的 `inputs` 仅测试 |
| §6.1 热点瓶颈 | 0 | 无 `cjprof` / bench 数据；`LoomRenderPerf_test` 只是功能用例（#19）。6 项疑似热点全部进「待验证假设」，不作结论 |
| §6.2 大粒度锁 | 0 | `LoomHostApi.render` 临界区只有一次 `values` 拷贝（注释与实现一致）；`LoomRegistry` / `MemoryLoomStore` / `LoomMemoryPolicy` 临界区内无 I/O、无日志、无回调；`callStore` 已做到"锁内取引用、锁外调网关"。持锁时长问题见假设 #1 |
| §6.3 并发串行 | 1 | #1 的本质是"进程级状态被迫串行"，并发流程只能互相踩踏；`runAsync` 的 `waiter.get()` 只等一次，`QueuedClosureTask` 的批内串行属 `f_egraph` 设计，不计入本部分缺陷 |
| §6.4 低效算法 | 2 | `skill.load/upsert/count` 全表扫描（#6 的复杂度面，收益进假设 #4）；`topologicalOrder` 的 `remove(at: 0)` 与列举时插入排序（进「优化方案」，无基线） |
| §7 降堆内存方案 | 1 | `render` 的快照拷贝（写时复制方案，`无基线`）。其余对象随流程结束释放，长期持有只有 `LoomRegistry.flows`（已按 #12 报缺陷） |
| §8 降 CPU 方案 | 2 | 复用编译产物、拓扑排序/列举结构，均 `无基线（待验证）` |
| §9 local mode 可行性 | 0 | 被约束卡住：热点对象（`LoomFlow`、步骤闭包、`HashMap` 快照、JSON 串）全部逃逸到注册表 / 全局 `values` / 返回值，`@ local!` 下不成立；且收益需峰值内存对照，而峰值由 #12 的注册表决定，不是 local region |
| §11 现有代码的 BUG（存量） | 9 | #2/#3/#5/#6/#7/#8/#9/#10/#11 按 §11 记（#4 归 §1/§14、#12 归 §5）；已核对 `runCompiled` 的 `try/catch/finally`（同步路径异常→`outcome=failed`→rethrow 正确）、`render` 的字节扫描边界、`topologicalOrder` 环检测、`LoomStoreGateway` 全部 25 个 op 分支、`restore` 的分页终止条件、`parse` 的字段回落 |
| §12 并发安全与锁粒度 | 4 | #1（共享静态量 + 无锁读）、#6（check-then-write 分配主键）、#9（内部可变实例逸出）、#18（单例 install/reset 无同步）。`LoomMemoryPolicy` / `LoomHostApi` 的锁本身用法正确（锁内拷贝、锁外回调）；`LoomRunner` 的 `tagSeq` / `docSeq` / `asyncReady` 均有锁，未发现问题 |
| §14 功能完备性与 README 覆盖 | 2 | #4（`dryRun` 承诺未接线）、#11（网关 op 表漏 5 类能力）。本部分无 `.md`，README 覆盖核对留给对应子轮；本部分只把 README / KDoc 当判据引用 |
| 文件覆盖（§13 等） | 20/20 | 20 个文件全部读完，无 `.md`，故 §13「README/文档与实现」命中 0（KDoc 类问题按 §11/§14 记） |

### 第 16 部分

| 维度 | 命中 | 未命中时的说明 |
| --- | --- | --- |
| 正确性 / 设计 / 语言特性 / 可读性 / 安全性 | 10 | 正确性 #1/#3/#5/#9；设计 #10（注入点覆盖不全）；语言特性 #2（把其他线程写的普通字段当同步通道）；可读性 #16/#17/#18/#19；安全性 #3（误传生产 store 即清库，属破坏性操作，与正确性同一根因只计一次） |
| §1 死代码 | 1 | 已逐个核对本部分全部 `private` / `internal` / 非 public 顶层声明里的 `public` 成员：`FlowPlan.hexOf`（`Plan.cj:216`，被同文件 `jsonQuote` 调用）、`StepPlan.jsonQuote`（`Plan.cj:248`，被 `extend StepPlan.toJson` 的无限定 `jsonQuote(...)` 调用）、`Planner.stripFence`/`argsJson`/`planOf`/`questionsOf`/`assumptionsOf`/`userPrompt`、`RetrievalEval.percent`/`padRight`/`ndcgOf`/`discount`/`linesOf`、`ScheduleCreateFunction.runFlow`、`LoomGatewayHolder.get`、`LoomWiring.installSupervisor`/`registerEvolution`/`reload`、`TimeoutBox` 三个 `public var`（同文件读写）**均有调用者**；另查 `return`/`throw`/`break`/`continue` 后无同层语句、无恒真恒假分支、无只被测试引用的非 public 符号。命中仅 #17 的 3 处未使用 import。`LoomRequest.onUnresolved`/`dryRun` 是**对外可达 public 字段**，按硬原则一不判死代码，改按「读了不用」记 #4（`dryRun` 已在 part15 计数，本部分不重复） |
| §2 重复逻辑 | 2 | 同文件两两比对 20 个文件的函数体：`TopicStat` 与 `EvalReport` 的 4 对指标方法逐行相同（#13）；jit 占位符两段同文案 `throw`（并入 #12）。跨文件比对相同字面量 / 环境变量：`fllm_evalDir` 读取逻辑两处逐字相同（#14）；`ScheduleFunctions_test` 的 `createParam`/`deleteParam` 只改类型名（并入 #14 记录）。已排除的近似项：`CodeGen.jsonQuote` 只是委托 `FlowPlan.jsonQuote`；`RetrievalQuality_test` 假编码器与 `RetrievalEval_test` 字符重合检索器用途不同（一个测排序、一个测数据集）；`percent`/`padRight` 各仅一处 |
| §3 空实现 | 1 | #7 的 `catch (error: Exception) { () }`。其余逐个核对：`FailingLoomStore`（`LoomWiringSupervisor_test.cj:26-41`）是显式「存储不可用」桩、`CountingStore`（`LoomWiringGateway_test.cj:26-33`）是计数桩、`ChatRecorder`/`PromptRecorder`/`FakeScheduler` 是记录桩，均属测试替身不判；`LoomTimeout`/`PromptCapabilities`/`Prompts`/`RetrievalEval`/`RetrievalEvalRunner`/`LoomWiring` 的 `private init() {}` 是「静态工具类」惯用法（配 `public static func`），不是空实现 |
| §4 栈溢出 | 0 | 本部分无递归：`Plan.validate`/`toJson`、`Planner.parse`/`stripFence`/`userPrompt`、`RetrievalEval.evaluate`/`ndcgOf`、`RetrievalEvalRunner.run` 全是单层循环（`ndcgOf` 内层上界是 `expected.size`，量级 ≤ topK）；无自引用结构的深度遍历。JSON 递归解析在 `f_data`（不属本部分） |
| §5 OOM | 0 | 唯一「全量物化」是 `RetrievalEval.linesOf` 的 `readToEnd()`（按 §11 资源问题记 #15；规模受本地语料约束：50 条 / 53 行）；`evaluate` 的 `statMap`/`reciprocalMap`/`ndcgMap` 键数=主题数、`misses` 上限=正样本数，均有界；评测与定时任务不接请求主路径，无「按不可信长度预分配」 |
| §6.1 热点瓶颈 | 0 | 无 `cjprof` / `cjpm bench` 数据（`RetrievalQuality_test`/`RetrievalEval_test` 是功能用例，且 `cjpm test` 默认 `-O0`）。4 条疑似热点全部进「待验证假设」，不以缺陷计 |
| §6.2 大粒度锁 | 0 | 本部分 20 个文件无 `synchronized` / `Mutex`（`grep` 核实），不存在锁内 I/O、锁内回调或锁顺序问题；`LoomWiring` 只在装配期写全局对象 |
| §6.3 并发串行 | 1 | #6：惰性初始化的重复构造（并发首次调用各建一份）。`LoomTimeout` 的 `spawn` + 轮询不是「形式并发实际串行」（确实并发执行，问题在同步通道，记 #2） |
| §6.4 低效算法 | 0 | 静态可判的低效点规模都极小且无数据：`Plan.validate` 每条边一次线性 `step()`（O(E·S)，S ≤ 数十）、`EvalReport.render` 主题选择排序 O(12²)、`evaluate` 的 `expected` 内层扫描 O(topK·|expected|)。按 checklist 要求不足以成发现，已并入「待验证假设」#4 |
| §7 降堆内存方案 | 0 | 本部分对象都随调用结束释放：`TimeoutBox`（每调用一个）、`PlannerResult`/`FlowPlan`/`StepPlan`（随请求）、`EvalReport`/`TopicStat`（每轮评测）、`titleToId`/`statMap`（随 `run` 结束），无长期持有容器；`readToEnd` 的峰值问题并入 #15 的修法（改流式），不单列方案 |
| §8 降 CPU 方案 | 1 | `jsonQuote` 的两次全量字节拷贝（`无基线（待验证）`）。其余候选（nDCG 双重循环、选择排序、报表字符串拼接）规模太小，不进方案 |
| §9 local mode 可行性 | 0 | 不可行 / 无收益证据：本部分热点对象（`FlowPlan`/`StepPlan`/`PlannerResult`、拼接中的 JSON 串、`EvalReport`）全部**逃逸**（作为返回值、写入 `LoomRegistry`/`LoomResult`、进 `HashMap`），`@ local!` 约束下不成立；`jsonQuote` 的临时数组虽不逃逸，但收益是分配量而非峰值内存，且缺 `getAllocatedLocalObjectSize()` 前后对照，只能作假设 |
| §11 现有代码的 BUG（存量） | 10 | #1-#3、#5、#7-#11、#15 按 §11 记（#13/#14 归 §2，#16/#19 归可读性，#17 归 §1，#18 归注释一致性）。已核对的关键边界：`planOf` 的 `args`/`async`/`edges.size != 2` 三处回落、`stripFence` 的空体与无闭合围栏、`readCases` 的「既非负样本又无期望」跳过、`evaluate` 的 `rank`/`positiveTotal` 分母、`ndcgOf` 的 `ideal<=0` 保护、`percent` 的除零、`ScheduleFunctions` 的空 name / 空 cron、`evolutionOwner` 的三级回落、`RetrievalEval.defaultDir` 的 `None` 回落 |
| §12 并发安全与锁粒度 | 3 | #2（`TimeoutBox` 跨线程无同步，数据竞争）、#6（`LoomGatewayHolder` check-then-write）、#3（评测覆盖进程级 `SkillCatalog`，异常不还原）。已核对的「看似共享但安全」点：`LoomHostApi` 的存储注册有锁（`LoomHostApi.cj:157-179`，回调在锁外执行——这正是 #6 的可达路径）；`LoomSchedules`/`LoomServices`/`LoomWiring.reload` 只在装配期写、运行期读，按「装配期写」约定不单列（可见性无保证与 part15 同类，不重复报）；`RetrievalQuality_test` 的 `SkillCatalog.install/reset` 在 `finally` 成对出现 |
| §14 功能完备性与 README 覆盖 | 3 | #4（`onUnresolved` 承诺未接线）、#5（提示词放出 `http` 而校验器拒绝）、#9（空步骤 / 未知 status 当合法计划）。README 覆盖已对照：本部分对外符号 `StepPlan`/`FlowPlan`/`EdgePlan`/`LoomException`/`Planner`/`PlannerResult`/`LoomRequest`/`ClarifyQuestion`/`Prompts`/`PromptCapabilities`/`LoomTimeout`/`LoomWiring.lastReload`/`evolutionOwner`/`RetrievalEval*`/`EvalReport`/`TopicStat`/`EvalCase`/`EvalDoc`/`ScheduleCreateFunction`/`ScheduleDeleteFunction` 在 `f_llm/README.md` 均可检索到（`Prompts.PLANNER_SYSTEM` 作常量未单列，属可接受的信息层级） |
| 文件覆盖（§13 等） | 20/20 | 本部分 20 个文件全部读完；**无 `.md`**，故 §13 文档一致性命中 0 条——但已用 `doc/f_llm.md:375-376`、`doc/loom.md:105/204`、`doc/retrieval-eval.md:101-105/122-133`、`README.md:14/143/969/1020` 交叉核对承诺（漂移分别归 #4 / #5 / #3 / #8，KDoc 类问题归 #16） |

### 第 17 部分

| 维度 | 命中 | 未命中时的说明 |
| --- | --- | --- |
| 正确性 / 设计 / 语言特性 / 可读性 / 安全性 | 14 | 即上面 14 条一般级发现：正确性与契约类 12 条、错误处理类 3 条（有交叠）、注释与实现相符 1 条（「keywordScore 注释示例不成立」计入轻微）。安全性：外部字符串进 JSON 均走 `FlowPlan.jsonQuote`（`SkillEvolutionJob.cj:275-278`、`StoreFunctions.cj:134-136`），无硬编码凭据、无日志打印正文；`synchronized` 块为 Unit 语义，统一用 `*Box` 带出返回值（`SkillCatalog.cj:358-377`、`SinkBox`），与 `LoomRegistry.cj:77` 的约定一致，未发现误用 |
| §1 死代码 | 1 | 逐文件核对：8 个 `private init()` 是禁止实例化的显式手段；`SkillCatalog` 13 个 `private` 函数、`SkillEvolutionJob` 9 个、`SkillMatcher` 6 个、`Supervisor` 4 个、其余各 1-3 个，全部在文件内有调用点；`internal` 顶层类 9 个（`FactoryBox`/`EmbedderBox`/`FailureBox`/`VectorBox`/`SkillFlagBox`/`SinkBox`/`StoreInvoker`/`StepSourceCodec`/`LoomRowMapper`）均被同包使用，其 `public` 成员也在文件内有读写；无 `return`/`throw` 之后的同层语句、无 `if (false)`、无未使用 `import`（`std.convert` 供 `Int64.tryParse`，`std.math` 供 `sqrt`）。唯一命中：`SkillCandidate.score` 计算后仓内无任何读取点（字段本身对外可达故不判死代码，只记「计算无消费」） |
| §2 重复逻辑 | 4 | ① `cosine` 两份逐行相同（`SkillCatalog.cj:326-343` / `SkillMatcher.cj:237-254`）、`runeScore` 与 `runeCoverage` 仅差空格/换行跳过（`306-324` / `268-289`）、samples 解析两份（`SkillGate.cj:113-143` / `SkillNamer.cj:101-123`）；② JSON 字符串取值四处（`SkillEvolutionJob.cj:367-375`、`SkillGate.cj:145-154`、`SkillNamer.cj:125-134`、`SkillImport.cj:128-137`）；③ PG/MySQL `LoomStore` 4 个方法同形，仅 `dao<T>` 类型与方言名不同；④ `StoreFunctions.cj:73-76`、`144-147`、`215-218` 三个逐字相同的转发。已两两比对但未计入：`Supervisor.register` / `unregister` 的线性查找（3 行、无行为差异）、`SkillImport.strOf` 与 `SkillImportFunction` 的参数校验（职责不同） |
| §3 空实现 | 1 | 「网关/存储异常被吞成空集合」一条的六处 `catch → 空集合 / ()`；`SkillGate.scoreOf` 的 `catch → ''` 单列为「调用失败计 0 分」。无 `TODO`/`FIXME`/空函数体；`private init()` 是有意禁止实例化 |
| §4 栈溢出 | 0 | 无自递归、无间接递归：聚类、rune 扫描、水位线推进、`StepSourceCodec.decode` 全部迭代实现；不遍历用户可控深度的树/链表 |
| §5 OOM | 0 | 素材量受 `limit`（默认 500）与 `topK` 约束；无 `Array(n, repeat:)` 按报文长度预分配；`materials` / `scored` 作用域限于单轮。`SkillCatalog.vectors` 与知识正文物化属「可以更省」而非无界增长，列入优化方案 #1 #2 |
| §6.1 热点瓶颈 | 0 | 无 `cjprof` / `cjpm bench` 数据，热点结论不成立；三个可疑点降为「待验证假设」1-3 |
| §6.2 大粒度锁 | 0 | 逐个临界区核对：`SkillCatalog` 锁内只有 `HashMap` 读写与计数自增（`85-114`、`248-260`），编码与打分在锁外；`Supervisor` 锁内只有 `ArrayList` 扫描/替换（`307-320`），模型调用与 `executeNow` 在锁外；`SkillEvolutionJob.emit` 锁内只拷 `sink` 引用（`429-438`） |
| §6.3 并发串行 | 0 | 本部分无 `spawn` / `Future` / 线程池；`schedule` 为单定时任务串行执行，属设计意图 |
| §6.4 低效算法 | 1 | 「SkillMatcher 在技能循环内重复编码」一条。`sortDesc` 是插入排序（`345-355`），n = 技能数（几十）；`StepSourceCodec.encode` 的循环字符串拼接，n = 步骤数，均未构成问题 |
| §7 降堆内存方案 | 2 | 优化方案 #1 #2，均标 `无基线（待验证）` |
| §8 降 CPU 方案 | 1 | 优化方案 #3（聚类阶段重复编码，无基线） |
| §9 local mode 可行性 | 0 | 本部分临时对象（`SkillEntry`、向量、`materials`）虽在函数内产生，但向量要逃逸到 `SkillCatalog` 静态缓存，不满足 local 约束；其余收益只能靠峰值内存证明，当前无数据 |
| §11 现有代码的 BUG（存量） | 14 | 本部分 14 条一般级全部为存量（快照无 diff）。已核对未成立的边界：`SkillEvolutionPolicy` 的 `elapsed == required` 按 `<` 放行（与测试一致）；`StepSourceCodec.decode` 对空串/坏记录有守卫；`search` 的 `topK<=0` 返回空；`Float64` 除法前均有 `total/size == 0` 判断；`EvolutionLease.acquire` 返回空串表示未抢到（`EvolutionLease.cj:119-122`），`schedule` 的 `!acquire().isEmpty()` 用法正确 |
| §12 并发安全与锁粒度 | 2 | 共享路径逐点核对：`SkillCatalog` 5 个静态字段 + `SkillEvolutionJob.sink` + `Supervisor.installed` 各有专属 `Mutex`，均为「锁内取引用、锁外计算」。命中「Supervisor 把 status 查询异常当作未编译」与「install 先发布后播种」。范围外提示：`LoomStoreGateway.buildCount++`（`LoomStoreGateway.cj:47/61/69`）是无锁静态计数，「StoreInvoker 误判未安装」的每次回落都会命中 |
| §14 功能完备性与 README 覆盖 | 1 | 「新技能建库前不查重」一条（`doc/f_llm.md:519` 承诺「名字不能与已有技能冲突」）。本部分无 `.md`，公开 API 未文档化问题留待含 README/doc 的部分；`SkillCatalog.embeddingEncoder`、`SkillMatchResult.assignedCount`、`SkillEvolutionLedger.list/history`、`Supervisor.routes` 均属对外可达 API（硬原则一，不判死代码），仅记「仓内无生产引用」 |
| 文件覆盖（§13 等） | 20/20 | 20 个文件全部读完；`files/f_llm.part17.txt` 不含 `.md`，§13 文档一致性留给含 README/doc 的部分 |

### 第 18 部分

| 维度 | 命中 | 未命中时的说明 |
| --- | --- | --- |
| 正确性 / 设计 / 语言特性 / 可读性 / 安全性 | 3 | 设计：`KnowledgeEntity` 构造函数里直接发 embedding 请求并记 token（`KnowledgeEntity.cj:25-33`），对象一构造就有网络副作用、无法单测；可读性：`ToolCatalog.descriptionOf`（`:102-120`）四层 `match` 嵌套；安全性：`listTools` 的 `offset`/`limit` 直接来自模型实参且未校验（并入 #12）。其余逻辑/边界类问题统一记在 §11 行 |
| §1 死代码 | 1 | 已逐个核对本部分 20 个文件的 `private`/`internal`/`protected` 符号与 `import`：`ToolCatalog` 的 `scoreOf`/`sortDesc`/`descriptionOf` 均被同文件调用，`McpToolSource.textOf`（`:176`）被 `:115` 调用，`firstTypeOf` 被 `:141` 调用，`ToolCall.expand` 被两个宏调用，`SpyHost` 被 `loom/LoomWiringSupervisor_test.cj:143` 使用，`Memory.add` 两个重载分别被 `AgentTask.cj:510` 与内部调用 ⇒ 唯一命中是未使用的 `import Config`（#20）。信息项（不算问题）：`Memory.timer` 字段只在 `static init` 里被 `atExit` 捕获，之后不再读取（生命周期锚点，保留合理）；`@WeavedToolCall`、`ToolEntry.score` 等对外 public 声明仓内零引用但 README 已登记，按硬原则一不判 |
| §2 重复逻辑 | 2 | 已把 20 个文件的函数体压成「输入→输出→副作用」两两比对，并跨文件搜了相同错误文案/字面量：命中 #18（5 组）与 #17（kind/namespace 字面量复制）。`Code`/`CodeParam`/`Knowledge`/`Specification` 字段重叠属不同职责，不判；`Supervisor_test` 里重复的 `reset` 样板归入 #22 |
| §3 空实现 | 1 | `DummyMemory` 三个空方法是"有意 Null Object"且有 `makingMemory` 开关控制，不算问题；命中是测试里的 `catch(error: Exception){ () }`（`ToolFunctions_test.cj:82-86`、`McpToolSource_test.cj:99-101`/`:114-116`）——静默吞异常，仅测试代码，按轻微并入 #22。另 `Memory.summarise` 的"失败返回成功"已单列为 #6 |
| §4 栈溢出 | 1 | `sanitizeSchema` 的递归深度由外部 schema 决定（#21）；`ToolCall.expand` 的 `while(let MacroExpandDecl <- ...)` 有单调收敛、`ToolCatalog`/`MemoryExtractor` 无递归 ⇒ 其余不命中 |
| §5 OOM | 2 | #2（内容键永不删除）+ #13（每事件 `spawn`、无上限）。`Memory.summarise` 全量拼会话串另有优化方案 3；`ToolCatalog.entries` 的物化受注册工具数限制，未达 OOM 量级 |
| §6.1 热点瓶颈 | 0 | 本部分未提供 profile / bench 数据，"`spawn` 多"、"JSON 解析多"只是线索；已全部落到「待验证假设」1/3/4/5，不进 `todo.md` |
| §6.2 大粒度锁 | 0 | 本部分 20 个文件自身不含任何锁；调用路径上唯一相关的是 `StoreWiring.wire()` 的全局 `Mutex`（`StoreWiring.cj:52`），被 `Memory.remember` 每次调用一次，但记忆写入频率低（每会话每天一次），看不出热点；已列入待验证假设 3 补数据 |
| §6.3 并发串行 | 0 | 无 `spawn(...).get()`、无"批大小=1"的循环；`Memory.add` 的 `spawn` 是 fire-and-forget（问题在无界与静默失败，见 #13） |
| §6.4 低效算法 | 0 | `sortDesc` 是插入排序 O(n²)（`ToolCatalog.cj:90-100`）、`ToolScope.check` 的 `result.contains` 也是 O(n²)，但 n = 工具数（几十），未证明是热点 ⇒ 待验证假设 5 |
| §7 降堆内存方案 | 1 | 输出 1 条方案（摘要输入截断），证据状态均为「无基线（待验证）」 |
| §8 降 CPU 方案 | 2 | 输出 2 条（关闭开关时跳过 `add` 路径；`ToolCatalog` 缓存），均无基线 |
| §9 local mode 可行性 | 0 | 逐函数做过逃逸检查：`ToolCatalog.entries/search` 返回的 `ArrayList<ToolEntry>`、`sanitizeSchema` 返回的新 `JsonObject`、`Memory.summarise` 拼出的 `content` 全部逃逸出函数（返回值/请求体），`ToolFunctions.call` 的 `text` 作为 `FunctionResult` 返回 ⇒ 没有"函数内创建、函数内释放"的大对象，改造不成立 |
| §11 现有代码的 BUG（存量） | 15 | 计数口径列出：#1 #2 #3 #4 #5 #6 #8 #10 #11 #12 #13 #14 #15 #16 #19 = 15 条（边界、空集合、错误处理、资源、契约与注释不符各一组）。其余 7 条按主维度归到 §1(#20)、§2(#17/#18)、§3(#22)、§4(#21)、§14(#7/#9)。均已核对调用链（`AgentTask.cj:510`、`FunctionMediator.call`、`Store.add`、`Timer.after`） |
| §12 并发安全与锁粒度 | 1 | 共享路径只有两条：① `Memory` 的 static `faithful`/`timer`（初始化后只读，无线程共享写）；② `FaithfulMemoryImpl.add` 的 `contains`→`add` 非原子（并入 #3 描述）与 `Memory.add` 的 `spawn` 无 join/无界（#13）。`Store` 本身是并发安全实现（`ConcurrentSkipListMap` + `AtomicInt64` 序列号），未发现"无保护共享可变状态" |
| §14 功能完备性与 README 覆盖 | 2 | #7（`ToolScope` 未接线）、#9（`llm_summarisingActionKind` 取值无实现/无文档）。另 README 对 `Memory` 只写"是否保存记忆（保存才有经验）"，未说明 `llm_summarisingActionKind` 的合法取值与前置 bean，属 #9 的一部分 |
| 文件覆盖（§13 等） | 20/20 | 本部分无 `.md`（§13 文档一致性 0 命中），`.cj` 20 个全部逐行读完；`imports.cj` 的 `internal import` 可见性已按语言文档核对 |

### 第 19 部分

| 维度 | 命中 | 未命中时的说明 |
| --- | --- | --- |
| 正确性 / 设计 / 语言特性 / 可读性 / 安全性 | 18 | 安全性：#1（TrustAll）、#5（凭据假承诺）、#9（测试清库）；正确性/契约：#2 #3 #4 #6 #7 #8 #10 #12 #13 #15 #18；设计：#10（双模型）、#14（重复客户端）、#16（可变快照）；语言特性：#12（prop 只读与 `mut` 语义）、#5（字符串拼 header）、#7（HashMap 覆盖语义）；可读性：#11；测试有效性归 #17。逐文件核对未命中项：`Todo.predecessor` 空串路径、`TokenUsage.usageTime` 定长编码、`SkillReference` 无 id 映射、`LLMConfService` 每语句重新取 `executor()`（符合基线 §2）均成立 |
| §1 死代码 | 2 | 两个 `imports.cj` 的零引用导入（#11）。其余机械检查：7 个 `private` 成员（`mutex`/`providers`/`loaded`/`poster`/`confs`/`path`/`text`）全仓搜均有使用；`internal`（缺省）顶层函数 `defaultSearchPost`/`ensureOk`/`headersOf`/`searchSummaryOf`/`searchTextOf`/`searchScoreOf` 全部被本包调用；`protected` 0 个；`public` 所属顶层类型均为 `public`（对外可达），按硬原则一不判，`Todo.predecessor` 两个重载与 `LLMConfService.save/update/findById/clear` 仓内仅测试调用，记为对外 API 信息；`return`/`throw` 之后同层语句、恒真恒假分支：无；局部变量与形参：`defaultSearchPost` 的 `tls`、`parseDeepSeekSearch` 的 `summary/obj`、`parseConfJson` 的 `obj/conf` 均被读取 |
| §2 重复逻辑 | 3 | #10（同表两套模型字段漂移）、#13（逗号列解析漂移）、#14（`defaultSearchPost` vs `util.http`）。另做的两两比对：`search()`/`fetch()` 结构同形但 body 字段、错误动作名、解析器都不同，合并只加参数层，按误报边界不单列；`LLMConfService` 5 个方法是一层委托（基线要求）；四个 `LLMConfSource.load()` 数据源各自独立；`Agent` 两个事件 prop 同形但对应不同列，属可读性展开，不单列 |
| §3 空实现 | 2 | #4（`ensureLoaded` 的 `catch(_: Exception){ }` + 永久置位）、#15（三处异常→默认值）。无 `TODO`/`FIXME`、无空函数体；`LLMConfCodec.fromColumn` 的空表降级有注释说明是有意设计，只按可观测性并入 #15 |
| §4 栈溢出 | 1 | 并入 #4（待确认）：`ensureLoaded` 持锁调用 `lookupList`，若 provider 构造函数回调 `get()`/`register()`，重入的 `ensureLoaded` 因 `loaded` 仍为 `false` 会再次构造同一批 provider ⇒ 递归重入。本部分文件自身无递归函数（`parseConfJson`/`parseDeepSeekSearch` 均为迭代），无自引用结构、无递归 `clone`；`JsonValue.fromJson` 的递归在 `f_data`，深度由配置/响应 JSON 嵌套层数决定 |
| §5 OOM | 1 | #3（`readEntire` 全量物化 + `Content-Length` 预分配 + `count` 无上限）。其余：`parseConfJson` 读整个配置文件（运维可控、量小）；注册表 `providers` 只随显式注册增长（有界） |
| §6.1 热点瓶颈 | 0 | 未提供 `cjprof`/`cjpm bench` 数据，热点结论不成立；可疑点全部降为「待验证假设」1-3，不参与严重度统计 |
| §6.2 大粒度锁 | 1 | 并入 #4：`ensureLoaded` 在 `synchronized(mutex)` 内执行 `lookupList`（会跑任意 provider 构造函数），锁持有时长取决于 bean 构造；只在首次扫描发生一次，未构成热点，按“锁内执行外部逻辑”记为设计风险。`names()`/`get()` 锁内只做一次 HashMap 遍历/查找，可接受 |
| §6.3 并发串行 | 0 | 本部分无 `spawn`/`Future`/线程池；`search`/`fetch` 各是一次同步 HTTP 调用，不存在“并发度配成 1” |
| §6.4 低效算法 | 0 | 未见随输入规模增长的复杂度问题：`parseDeepSeekSearch` 单趟 O(结果数)、`parseConfJson` 单趟；`conf` 每次重解析是常数级开销，已列入优化方案 3 与待验证 2 |
| §7 降堆内存方案 | 1 | 优化方案 1（有界读取），`无基线（待验证）`；`conf` 缓存同时降分配，但主要收益在 CPU，归入方案 3 |
| §8 降 CPU 方案 | 2 | 优化方案 2（client/连接复用）、方案 3（conf 解析缓存），均 `无基线（待验证）` |
| §9 local mode 可行性 | 0 | 本部分没有“函数内创建、函数内销毁且不逃逸”的大对象：`parseDeepSeekSearch` 的 `ArrayList<SearchResultItem>` 作为返回值逃逸，`readEntire` 的字节数组转成 `String` 后进入 JSON 树；且收益只能靠峰值内存证明，当前无数据 |
| §11 现有代码的 BUG（存量） | 18 | 本部分 18 条全部为存量（快照模式无 diff）。已核对但未成立的边界：`Todo.predecessor` 空串（`fromStr("")` → `JsonNull`，`convert` 失败回落空表）、`TokenUsage.usageTime` 12 位定长拼接、`ensureOk` 的 3xx/4xx 分支、`createConfSource('file:')` 空路径、`parseDeepSeekSearch` 缺 `results` 键返回空表、`DataObject.populate` 返回值被忽略（`f_data/src/base/DataObject.cj:194-206`，Iterable 分支不会返回 `None`）、DDL 允许 NULL 而 PO 非 `Option`（`f_orm` 对非 `Option` 字段走 `FieldQueryMapper.populate` 的 `if(let Some(id) <- ...)` 跳过分支，NULL 落到字段默认值，不抛） |
| §12 并发安全与锁粒度 | 2 | #4（锁内 bean 扫描 + 重入递归，待确认）、#16（可变 PO 作为“不可变快照”共享，待确认）。已证明安全的部分：注册表三个静态字段（`mutex`/`providers`/`loaded`）读写全部在 `synchronized(mutex)` 内，`loaded` 的双重检查在锁内完成，无检查-然后-写入竞态；`DeepSeekSearchProvider` 只持有不可变 `poster`，可并发调用（`defaultSearchPost` 每次新建 client） |
| §14 功能完备性与 README 覆盖 | 2 | #5（`secretRef` 注释承诺、无实现）、#18（同名注册策略与基线 §4 不符）。另核对：`SearchProvider.search/fetch` 的“失败必须抛异常”契约，实现确实抛 `SearchHttpException`（`ensureOk`）与 `JsonException`（解析），未用空列表冒充失败；`searchEndpoint/fetchEndpoint` 的 conf 覆盖均已接线（`searchUrl`/`fetchUrl`）；本部分无 `.md`，README 覆盖面留待含 README 的分轮 |
| 文件覆盖（§13 等） | 20/20 | `files/f_llm.part19.txt` 共 20 行，20 个 `.cj` 全部读完，无 `.md`；§13 文档一致性本部分无对象 |

### 第 20 部分

| 维度 | 命中 | 未命中时的说明 |
| --- | --- | --- |
| 正确性 / 设计 / 语言特性 / 可读性 / 安全性 | 14 | 正确性 #1 / #4 / #7 / #8 / #9 / #11 / #12 / #17 / #20 / #21；设计 #1（Store 生命周期）、#6（同族三种同步策略）、#22（同一后端的两个实例）；可读性 #16 / #19。语言特性：`synchronized` 不能带返回值 → 全模块用 `XxxBox` 带出（`LeaseBox` / `StateBox` / `IdBox` …，用法一致无缺陷）；`Option` 均被 `match` 消费，无静默丢弃。安全性：本部分无 SQL 拼接、无 HTML、无凭据进日志（`auth` 只做字段搬运 `StoreMetaConfSource.cj:54`），未命中；`ColbertCodec` 的长度信任问题已归 #3（§5） |
| §1 死代码 | 2 | 逐个 `private` / `internal` 符号全仓搜引用：`writeInt32` / `readInt32`（#13 同址，有调用者）、`knowledgeChunkerUsesLocalBytes`（测试 + `knowledgeChunkerUsesLocal`）、`splitImpl`（`split` + 2 个测试）、`countRunes` / `minOf` / `hexDigitOf` / `indexPrefix` / `indexKey` / `pad` / `readState` / `readRun` / `maxId` / `readByKey` / `read` / `before` / `has` / `contains` 均有调用者；`LeaseBox` / `StateBox` / `StampBox` / `KnowledgeBox` / `KnowledgeSetBox` / `IdBox` / `EntryListBox` 均为"`synchronized` 带出返回值"的载体，全部在用（属非公共顶级声明里的 `public var`，但全项目有使用 ⇒ 不是死代码）。命中：`ColbertCodec.cj:52-54` 空 `if`（#14）、5 处未用 import（#15）。对外可达的 `public`（`ColbertCodec` / `DeployPaths` / `EvolutionLease` / `InMemory*` / `KnowledgeChunker` / `KnowledgeIndexRebuilder` / `StoreMetaConfSource`）不判；`public open` 类不存在 ⇒ `protected` 豁免无适用对象。`private init()`（`TimeUuid`、`KnowledgeChunker`、`KnowledgeIndexRebuilder`）是"禁止实例化"的有意声明，不判（`DeployPaths` 无 `init`，全静态） |
| §2 重复逻辑 | 3 | 同文件两两比对 40+ 个函数体 + 跨文件搜相同字面量/分隔符：命中的三组见 #13（插入排序 ×2、线性 `contains` ×3、4 字节小端 ×4）。**判为"不重复"**：`appendChunksLocal` / `appendChunksHeap`（循环体逐行相同，但注释 `KnowledgeChunker.cj:89-99` 给出 `-O0` 下 local region 会为大文档消耗数百 MB 的实测理由，合并会引入 OOM 面）；`FStoreMetaStore` 的两个 `init`（仓颉无构造函数委托）；`ColbertCodec.writeInt32` 与 `Int32` 的 count 字段（语义不同：一个是定长字段、一个是向量元素）；三份 `ensureSchema` 默认空实现（接口扩展点，语义各自独立） |
| §3 空实现 | 0 | 逐条核对：`EvolutionLease.ensureSchema` / `EvolutionStateStore.ensureSchema` / `EvolutionStore.ensureSchema` 的默认 `()` 都有注释说明"f_store 与内存实现无需建表"（Null Object，且四个后端实现里 mysql/postgres 均已覆盖，`mysql/EvolutionStateStore.cj:41` 等）；`processedKnowledge` / `markKnowledge` 默认实现有"运维/调试用"的注释；`case None => ()` 出现在 `markKnowledge` 跳过空串（`EvolutionStateStore.cj:267`）、索引读失效（`EvolutionStore.cj:215`、`:233`、`:299`）等**有明确语义**的位置，不是吞异常。真正的"承诺有行为却空实现"只有 #14 的空分支，已按 §1 计 |
| §4 栈溢出 | 0 | 本部分无递归：`TimeUuid.timestampOf` 是单层循环，`KnowledgeChunker` 的滑窗是 `while (start < total)`，`KnowledgeIndexRebuilder.rebuildAll` 是 `while(true)` + 分页退出，`ColbertCodec` 双层定长循环。`EvolutionStateStore.processedAmong` 默认实现无自引用 |
| §5 OOM | 2 | #3（`decode` 按数据里的 `count` 循环与分配）；`KnowledgeChunker` 的全量 rune 展开（4×内容字节，无内容长度上限）量化后作为优化方案 3 + 待验证假设 4（无实测，不定为缺陷）。另核对：`InMemoryEvolutionStateStore.knowledge` / `InMemoryKnowledgeStore.docs` 只增不减，但规模由业务实体数决定（非"每次请求新增键"），未计；`FStoreEvolutionStore` 三键/条属磁盘增长，列入优化方案 4 |
| §6.1 热点瓶颈 | 0 | 未提供 `cjprof` / `cjpm bench` 数据，本部分所有"看起来贵"的位置（构造期 `repair`、锁内排序、`prefix` 全扫）一律降为优化方案 1-2 与待验证假设 1-6，不作缺陷 |
| §6.2 大粒度锁 | 1 | `InMemoryEvolutionStore.list` 在 `synchronized` 内做全量拷贝 + O(n²) 排序（`EvolutionStore.cj:92-114`），临界区含纯 CPU 的排序逻辑；已并入 #13 的描述（内存实现、影响面小，定级轻微）。`FStoreEvolutionStateStore.processedKnowledge` 在锁内做 `store.prefix` 磁盘扫描（`EvolutionStateStore.cj:233-242`）列入待验证假设 6（是否成热点缺数据）。其余 `synchronized` 块只包裹单次 map/Store 操作 |
| §6.3 并发串行 | 0 | 本部分没有 `spawn`，也没有"提交后立刻 `get()`"；唯一的并行面是 `Store` 内部 compactor 线程（`f_store`，范围外） |
| §6.4 低效算法 | 1 | 手写插入排序代替 `std.sort`（`EvolutionStore.cj:98-106`、`InMemoryStores.cj:273-281`），另 `names()` 的 `has()` 去重是 O(n²)（`FStoreMetaStore.cj:112`，n = 配置条数，量级小）。`FStoreEvolutionStore.list` 的 `keys[index]` 反向遍历本身是 O(limit)，但前置 `prefix` 全扫属读放大（优化方案 4）。`KnowledgeChunker` 的 `countRunes` 为精确容量服务，属"多走一遍 O(n) 换掉扩容"，有意取舍 |
| §7 降堆内存方案 | 2 | 优化方案 3（`KnowledgeChunker` 全量 rune）、优化方案 4（evolution 索引键无保留策略）；另 #11 是"泄漏"（缺陷）而非"可省"，不重复计 |
| §8 降 CPU 方案 | 2 | 优化方案 1（构造期 `repair`）、优化方案 2（锁内 O(n²) 排序）；均标 `无基线（待验证）` |
| §9 local mode 可行性 | 0 | 本部分唯一的 local mode 改造已经在 `KnowledgeChunker` 落地（`@ local!` + `exclave` + 8 MiB 预算 + 门限单测），并有 `perf-baseline.md` 口径的参考 bench；其余候选（`ColbertCodec.decode` 的向量数组、`EvolutionLease.timestampOf` 的 nibble 缓冲、`FStore*` 的 `ArrayList`) 要么作为返回值逃逸（违反 `@ ~local` 约束），要么量级只有几十字节（收益无法用峰值内存证明），不满足"峰值内存前后对照"的取证要求 |
| §11 现有代码的 BUG（存量） | 22 | 本部分是工作区快照，**全部 22 条发现都是存量**；其中按 §11 形态判定的：#1（数据丢失）、#4（边界 / 注释不符）、#5 / #7 / #12（契约与实现不符）、#8（静默丢数据）、#9（错误处理）、#10（契约不符）、#11（资源不对称）、#17（数据覆盖）、#18（检查-然后-写入）、#19（边界未校验）、#21（语义与契约不符）；#2 / #3 / #6 / #13-#16 / #20 / #22 分别按并发、OOM、重复、死代码、功能完备性维度归类，不重复计数。逐函数核对过边界与空值：`ColbertCodec.decode` 的空 blob（`bytes.size < 4` 返回 `[]`）、`count == 0`、`TimeUuid.timestampOf` 的空串/非十六进制（返回 0）、`DeployPaths.resolve` 的空配置/纯 `./`、`KnowledgeChunker.split` 的空内容与 `overlap >= maxChars`、`FStoreLLMConfStore.parse` 的段数不足（返回默认视图）、`FStoreCharacterStore.get` 的"无换行"分支、`FStoreEvolutionStore.read` 的 detail 含分隔符（第 4 段起拼回）、`KnowledgeIndexRebuilder.rebuildAll` 的分页退出，均已核对，无额外缺陷 |
| §12 并发安全与锁粒度 | 4 | #1（多 Store 实例共用目录 + WAL 被删）、#2（`InMemoryMemoryStore` / `KnowledgeStore` / `cachedKnowledge` 无同步）、#6（`FStoreMetaStore` 家族无同步的检查-然后-写入）、#5（租约的跨进程互斥缺失）。已明确线程封闭/无害的：`DeployPaths.cached`（幂等，重复计算同值，仅可能多做一次 `canonicalize`）、`TimeUuid.hexDigitOf`（纯函数）、`ColbertCodec` / `KnowledgeChunker`（无状态静态方法）、`CountingEmbedder`（仅测试单线程用）。锁粒度：Evolution 三个 f_store 实现都用"实例级 `Mutex` + `Box` 带出"，临界区内是单次 Store 读写，无嵌套取锁，无死锁路径；`InMemoryKnowledgeStore` 走的是"完全无锁"而不是"锁太大" |
| §14 功能完备性与 README 覆盖 | 3 | 本部分 0 个 `.md`（`f_llm/README.md` 与 `doc/**` 由其他子轮覆盖），无法做完整 README 对照；能做的代码内契约核对已做：#5（接口承诺 CAS）、#7（`put` 承诺覆盖）、#12（`CharacterStore` 两实现不一致）、#21（id 语义）均以"承诺源（接口/类注释 `文件:行号`）+ 缺失证据"的形式给出；#20（`LLMConf.conf` 扩展项未接线）、#22（inMemory 双实例 + `Stores.content()` 每次新建导致记忆不可见）是按 §14.1「能力未接入 / 接线缺失」判定的功能缺口 |
| 文件覆盖（§13 等） | 20/20 | 无缺文件；`files/f_llm.part20.txt` 的 20 行逐行对应上表。§13 文档一致性：本部分无 `.md`，只核了 `.cj` 内的契约性注释（#16） |

### 第 21 部分

| 维度 | 命中 | 未命中时的说明 |
| --- | --- | --- |
| 正确性 / 设计 / 语言特性 / 可读性 / 安全性 | 8 | 正确性 #1/#3/#4/#5/#7/#10/#22/#23；设计 #1（默认实现被继承）、#5（三段写入无事务）；语言特性 #4（`degraded` 用单 bool 表达两态）、`String.size` 按字节用法已核（`core_package_structs.html`「UTF-8 编码后的字节长度」），`MemoryKinds.check` 的字节遍历与 `occurrences` 的字节偏移均正确；可读性 #15/#18/#25/#26；安全性 #19 |
| §1 死代码 | 1 | 逐个 private 符号（`KnowledgeSearch.before/contains`、`MemoryKinds.check/contains/persistInsert/persistDelete`、`MemoryIndexRebuilder.tokensOf`、`PostgresMemoryStore.permitted/containsName/maxSim/dot/collect/normalize`、`MemoryRepositories.defaultRepository`、`PredefinedCharacters.keyList`、`MetaStoreAdapter` 成员）全仓搜均有调用者；`protected` 本部分 0 个；`public` 全部对外可达（顶层 `public class` / `public func`），按硬原则一不判，但 #17/#26 记了 3 个无引用/仅测试的可见性建议（`emptySkills`、`resetForTest`、`PredefinedCharacters.keys`）；`internal` 0 个；无 `return/throw` 后死语句、无未用 import。唯一计入的是 #14（等价冗余分支，且已注明规格依据） |
| §2 重复逻辑 | 4 | #11（实现名字面量 4 处）、#12（contains 4 份 + persist* 同构）、#13（token 合并 2 处且已漂移）、#26（人格 key 与正文双表）；另核对 `MemoryStore.listByKind` 与 `MemoryRepository.listByKind` 两份默认实现逐行相同（已并入 #1，不重复计数）；`PostgresMemoryStore` 的两处选择排序（rerank 取前 bound、最终取 topK）语义不同（键不同、目标不同），不判重复；`normalize`/权重常量已收口成 `RetrievalScoring` 单份（`grep "func normalize"` 仅一处） |
| §3 空实现 | 1 | #5（`catch (_: Exception) {}` 完全静默）；`StoreModels.emptySkills` 是返回空列表的脚手架，计入 #17（可见性建议）；无 `TODO`/`FIXME`/`UnsupportedException`（13 个生产文件搜零命中；`MemoryIndexRebuilder_test.cj:81-83` 的 `UnsupportedException` 是测试替身里"不该被调用"的守卫，属正常写法）；`case None => ()` 出现在可选分支（`attach`/`register`/`all`）语义正确 |
| §4 栈溢出 | 0 | 本部分 0 个递归函数（`contains`/`maxSim`/`dot`/`normalize`/选择排序全为循环）；无自引用结构遍历；`PredefinedCharacters.bodyOf` 是平铺 `match` |
| §5 OOM | 1 | #7（用户可控 `topK` 无上界 → 全量候选物化，无拒绝路径）；`rebuild` 分页取数、`search` 候选有 2×topK 关系，均无"按报文头预分配"；`KnowledgeSearch.rank` 复制一份候选，上限是 `maxCandidates`（规模前提见 #25） |
| §6.1 热点瓶颈 | 0 | 无本模块 profile / bench 数据；所有性能猜测进「待验证假设」表的 7 条，未作为发现 |
| §6.2 大粒度锁 | 0 | 本部分无锁（0 个 `synchronized`/`Mutex`/原子类型），并发问题只有 #6 的"无锁" |
| §6.3 并发串行 | 0 | 本部分无 `spawn`/`Future`/线程池；`add` 的 4 次串行远程调用是延迟问题，进假设 3 |
| §6.4 低效算法 | 1 | #25（`rank` 插入排序的规模前提写着 ≤200，实际可达 2000——按复杂度与上限判为「注释依据不成立」，耗时仍未测）；`PostgresMemoryStore` 选择排序（n ≤ 2×topK）与 `occurrences` 的 `indexOf` 扫描有规模上界或属于假设 5/6，无占比数据不定为低效 |
| §7 降堆内存方案 | 0 | 无 `getAllocatedHeapSize`/RSS 基线，按取证要求不列方案（候选见假设 1） |
| §8 降 CPU 方案 | 0 | 无 `cjpm bench -O2` 对照，不列方案（候选见假设 1/2/5/6） |
| §9 local mode 可行性 | 0 | 本部分函数内无"函数内创建、函数内用完"的大临时对象：`terms`/`rank`/`normalize` 的产物都作为返回值逃逸，`maxSim`/`dot` 只做标量累加；`search` 的 `records`/`scores` 也跨方法返回（`ArrayList<MemoryHit>`）——无逃逸候选即无收益可证 |
| §11 现有代码的 BUG（存量） | 11 | #1、#3、#4、#5、#7、#8、#9、#10、#22、#23、#24 均为本轮读到的既有逻辑/边界/契约缺陷；`StoreSettings.load()` 的 `??` 默认值、`MetaStoreAdapter` 三分支、`PredefinedCharacters` 空串回落、`RetrievalScoring` 数学、`normalize` 除零保护、`rank` 边界（`limit<=0` → 空）逐条核对无缺陷 |
| §12 并发安全与锁粒度 | 1 | #6（静态可变注册表无同步）；`SqlMemoryStore` 成员全为 `let`（线程安全前提取决于 repo/embedder）、适配器无状态、`StoreSettings` 不可变、重建工具纯静态无共享写；锁粒度无对象可评（0 锁） |
| §13 文档一致性 | 2 | 本部分 0 个 `.md`；以模块 README/doc 作承诺源核对出 #2（启动重建）与 #4（degraded 语义）；另 #15 是代码注释漂移、#25 是注释里的规模前提错误。`RetrievalScoring` 常量与 `StoreContracts.cj:74-80`、`doc/f_llm.md:309` 三处口径一致；`PredefinedCharacters` 当前 13 key 与 12 正文一致（双表风险记 #26） |
| §14 功能完备性与 README 覆盖 | 2 | #2（重建未接线）、#10（kind 校验未接线）；`StoreSettings` 四个新键与默认值均在 README 配置表中可查（README.md:760-772） |
| 文件覆盖（§13 等） | 20/20 | 清单 20 个 `.cj` 全部逐行读完，无未读文件；本部分无 `.md` |

### 第 22 部分

| 维度 | 命中 | 未命中时的说明 |
| --- | --- | --- |
| 正确性 / 设计 / 语言特性 / 可读性 / 安全性 | 18 | 全部 18 条发现都落在这五个维度内：正确性/契约 8 条（#1–#6、#10、#11）、设计 2 条（#7、#8）、安全性 2 条（#9、#16）、可读性/可维护性 6 条（#12–#15、#17、#18）；语言特性方面核对了 `Option` 的 `match` 穷尽性、`var`/`let` 语义、`Mutex`+`synchronized` 用法、`ArrayList` 与 `Array` 的拷贝语义 |
| §1 死代码 | 3 | 逐符号搜过：`private` 成员 25 个（`Stores` 3、`VectorMath` 2 含 `private init`、`ContentStore` 3、`MemoryRepository` 9、`HttpTransport` 6、`EvolutionLease` 2）全有调用者；`protected` 0 个；非 public 顶层类型（`HydraTransport`/`InProcessTransport`/`HydraKnowledgeStore`/`VectorCodecLike`/`HydraLeaseBox`/DTO 10 个/`SeqBox`/`FixedEmbedder`）的 `public` 成员均为包内使用或接口实现，无死代码；`return` 后无同层语句；命中 3 条弱形态：`colbert()` 恒等 `match`（#4）、`decode` 不读 `parts[3]`（#5）、`ensure(now)` 的 `now` 未使用（#13） |
| §2 重复逻辑 | 7 | 函数体两两比对后命中：`HttpTransport.numbers` ≡ `VectorMath.literal`、`upsert` 与 `searchSparse` 的 tokenIds/weights CSV 拼接、`ids`/`idsFiltered` 尾部列表拷贝、`Stores.contentNames` ≡ `metaNames`、`list` ≡ `listByKind`、自定义 `sqrt` ≡ `std.math.sqrt`（均见 #15），以及 `kindWanted`+`collect` 对同一记录两次 `get`（#12） |
| §3 空实现 | 1 | 无 `TODO`/空函数体/`throw UnsupportedException`；`catch {}` 仅出现在测试替身（`FakeContentStore` 等按契约抛错，非空实现）；远程 `colbert`/`filters` 的静默丢弃计入 #2（契约承诺但实现为空） |
| §4 栈溢出 | 0 | 全部函数无递归（`VectorMath.sqrt` 是定长 30 次循环）；`KnowledgeChunker`/`FlowPlan` 等递归候选不在本部分 |
| §5 OOM | 1 | 搜索候选被 200+200 上限约束，无全局无界容器；命中一条：`Stores` 无实例缓存导致同目录句柄随调用增长（#8），并在待验证假设 #5 记 f_store 多实例风险 |
| §6.1 热点瓶颈 | 0 | 无 profile/bench 数据；`esc`/选择排序/`nextId` 三项只进「优化方案」与「待验证假设」 |
| §6.2 大粒度锁 | 0 | `HydraEvolutionLease` 的 `Mutex` 内只有 1 次 `get` + 条件 `upsert`（远程下是 I/O，`EvolutionLease.cj:59-68`、`:82-92`），已单独记为「锁内 I/O」候选 → 见 §12 行说明；本部分其余路径无锁 |
| §6.3 并发串行 | 0 | 无 `spawn(...).get()`；`EvolutionLease` 是单值串行更新，无批处理语义 |
| §6.4 低效算法 | 1 | `HydraKnowledgeStore.search` 选择排序 O(n²) + 逐候选 `get`（候选 ≤400，未测占比 → 只进优化方案）；`rank` 的插入排序有界（≤ namespaces×limit）不计 |
| §7 降堆内存方案 | 1 | `esc` 三次复制（无基线）；local mode 收益无法用峰值内存证明，未展开 |
| §8 降 CPU 方案 | 3 | client 复用、选择排序→堆、`nextId` 区间缓存（全部无基线） |
| §9 local mode 可行性 | 0 | 本部分唯一候选是 `esc` 的临时 `ArrayList<Byte>`（函数内创建、不逃逸），但它是逐请求短生命周期小对象且缺少峰值内存对照；按 §9 约束只能记「待验证假设」（#4），不成方案 |
| §11 现有代码的 BUG（存量） | 11 | 本轮读到的 20 个文件全部按边界/空值/错误处理/资源/并发/契约过了一遍，命中 #1–#6、#10–#13、#18；测试侧另记 `StoreWiring_test` 用例不回滚 `llm_memoryStore`、`KindPersistence_test` 遗留 `MemoryKinds.resetForTest()` 的全局状态（只记录，不单列） |
| §12 并发安全与锁粒度 | 5 | 共享路径：`Stores` 静态表（#7）、`HydraContentStore` 缓存（#7）、`nextId` 复合写（#1）、`HydraKnowledgeStore.upsert` 非原子（#11）、`kindWanted` 双读（#12）；`HydraEvolutionLease` 的单实例 `Mutex` 内包含远程 I/O（`acquire` 3 次往返），因 `EvolutionLeases.byName` 每次新建实例、互斥只对单实例有效，跨实例靠写后读校验（已能收敛，不判缺陷），故本行不计入命中 |
| §14 功能完备性与 README 覆盖 | 1 | `doc/content-store.md:9-10` 把 `fhydra` 与 `f_hydra` 并列承诺同一套 `MemoryStore`/`KnowledgeStore` 语义，但远程实现丢 `filters`/`colbert` → 计入 #2；本部分无 `.md`，README 覆盖核对留给文档部分 |
| 文件覆盖（§13 等） | 20/20 | 20 个 `.cj` 全部读完；本部分无 `.md`，故 §13 文档一致性不适用 |

### 第 23 部分

| 维度 | 命中 | 未命中时的说明 |
| --- | --- | --- |
| 正确性 / 设计 / 语言特性 / 可读性 / 安全性 | 5 | 正确性 2（越权删除、`saveTime`）、设计 2（方言重复、锁粒度）、安全性 1（越权删除同条）；语言特性无问题（`match` 解包、`?Any` 映射均正确），可读性并入「轻微」两条 |
| §1 死代码 | 2 | 逐个 `private` 符号全仓搜过：`minOf`×2、`PostgresMetaStore.DRIVER` 无引用（已报）；`myLeaseTextOf`/`pgLeaseTextOf`/`myStateIntOf`/`myStateTextOf`/`myEvoEntriesOf`/`myEvoIntOf`/`myEvoTextOf`/`kindTextOf`/`kindIntOf`/`chunkIntOf`/`chunkFloatOf`/`textOf`/`intOf`/`floatOf`/`boolOf`/`bytesOf`/`recordOf`/`parseDatabase`/`vectorLiteral`/`denseK`/`annPath`/`scoreKey`/`maxOf` 均有调用者；`*Box`/`ChunkScore*` 均为本文件内使用；`public` 且对外可达的 store 类（`MySql*Store`/`Postgres*Store`）按硬原则一不判，`Internal` 类（`MySqlCharacterStore` 等）经 `MetaStore` 属性被使用 |
| §2 重复逻辑 | 1 | 9 对同名文件逐行 `diff`（≈84% 相同）+ 逐文件函数体摘要比对；另比对 3 个 `LeaseBox`、3 个 `*StateBox`、2 个 `*KnowledgeBox`、2 个 `*EvoListBox` 为同形样板（并入 box 优化方案）；`minOf`/`maxOf` 与 `VectorMath` 功能重叠已记在死代码条目 |
| §3 空实现 | 0 | 本部分无 `TODO`/`FIXME`；空 `init()`（`ContentStore`/`EvolutionLease`/`EvolutionStore`/`TokenUsageSaver`/`KindPersistence`）无字段需初始化，非空契约；`case None => ()`（`KnowledgeStore.search` 无 Embedder 时跳过 dense）是文档写明的降级路径，`catch(e: Exception){ println("SKIP…") }` 仅出现在测试且带注释说明「断言失败仍会暴露」 |
| §4 栈溢出 | 0 | 20 个文件内无自递归/间接递归；`KnowledgeSearch.rank`、`KnowledgeChunker.split` 为循环实现（不在本部分，只作调用关系确认） |
| §5 OOM | 1 | MySQL 稠密召回的 `JSON_ARRAYAGG(id)` 随用户记忆总量线性增长（已报，DB 侧）；应用侧容器均已有上界：`KNOWLEDGE_LIMIT=5000`、`maxCandidates`（默认 400/1000）、`denseK` 有 cap、分页 `while (collected < maxCandidates)` 有出口 |
| §6.1 热点瓶颈 | 0 | 本部分无 profile / bench 数据（`f_llm/doc/perf-baseline.md` 未覆盖 store 层），故不立热点结论；5 条猜测已进「待验证假设」 |
| §6.2 大粒度锁 | 1 | 6 个类的临界区含全部 SQL（已报为「一般 · 锁内 DB I/O」）；`markKnowledge` 的 N 次 insert 同条 + 优化方案 |
| §6.3 并发串行 | 0 | 本部分无 `spawn`；串行点只有实例 `Mutex`（并入 §6.2/§12.2 条目） |
| §6.4 低效算法 | 2 | `vectorLiteral` 循环拼接 O(n²)（优化方案）；`annPath`/DAO 每页重复查找（优化方案）。`wanted()` 的线性 `docIds` 比较规模 ≤ 请求 docIds 数，暂不构成 |
| §7 降堆内存方案 | 2 | `processedKnowledge` 双份引用数组、`*Box` 每方法分配（均无基线） |
| §8 降 CPU 方案 | 4 | `vectorLiteral`、批量 `markKnowledge`、循环内 `dao<>`、ANN 过滤集合收缩 |
| §9 local mode 可行性 | 0 | 无函数内大临时结构：`vectorLiteral` 产出的是要返回/绑定的字符串（逃逸），`merged`/`hits` 要作为返回值逃逸，`processedKnowledge` 结果返回给调用方；local region 无适用对象，收益无法用峰值内存证明 |
| §11 现有代码的 BUG（存量） | 6 | 越权删除、`saveTime`、PG 漏删 token、`JSON_ARRAYAGG` 空集、`nextId` 撞主键、测试互相清表；边界/空值另核对了 `parseDatabase`（无 `/` 时返回空串，下游 `annPath` 为空 → dense 跳过，符合「SQL 构造不合法时不发查询」的降级意图）、`chunkFloatOf`/`intOf` 的 `?Any` 分支、`processedAmong` 空数组（DAO 内 `docIds.size == 0` 短路）、`upsertSparse` 空 tokens（`isEmpty` 短路） |
| §12 并发安全与锁粒度 | 4 | 越权删除（跨请求共享库，同条计入）、未同步惰性初始化、实例锁粒度（同条）、`nextId` 非原子（同条）；其余方法状态为栈上局部或 `let` 常量，DAO 走 `ThreadLocal` executor（`f_orm/src/base/SqlExecutor.cj:44-45`），未发现共享可变状态 |
| §14 功能完备性与 README 覆盖 | 0 | 本部分无 `.md`；按 `src/` 公开声明对照模块 README 的能力项（记忆/知识/元数据/演进/token 用量）均有实现入口，无「承诺未实现」；`POSTGRES/MYSQL` 两方言能力对齐差异已并入 §2 漂移条目 |
| 文件覆盖（§13 等） | 20/20 | 无缺失；本部分不含 `.md`，§13 无适用对象 |

> 范围外提示（不占统计）：`f_llm/tables-mysql.sql:110-122` 的 `llm_memory` 没有 `title_vec`/`content_vec`/`*_colbert` 列（向量在 `llm_memory_vector`，第 156-168 行），而本部分 `mysql/MemoryRepository.cj:48-49` 与 `dao/mysql/MemoryDAO.cj:30,38,62,82` 直接读写这些列 ⇒ 照仓库自带 DDL 部署 MySQL 会 `Unknown column`。该漂移已在 `docs/fountain实现思想与应用/…第16弹.md:403` 记为已知限制，修复涉及 DDL 与 DAO（均不在本部分），故只记一句。

### 第 24 部分

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

### 第 25 部分

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
| 严重 | 43 |
| 一般 | 211 |
| 轻微 | 208 |
| 其中存量 | 445 |
| 优化方案 | 见「优化可行性方案」各条 |

## 总评

**第 1 部分**：本部分只有文档，但它是 `f_llm` 的对外契约层，质量整体**中上**：结构清晰、中英两版基本同步、配置表 / 失败矩阵 / 数据布局 / 权重公式都写到了可核对的粒度，且多数承诺（20 张表、13 个人格、契约方法、f_store 键布局、融合权重 0.7/0.3 与 0.4/0.6、colbert 二进制格式、附件 `-2` 顺延、SKIP 约定、`textClip` 截断语义）都与实现一致——这类"逐条能落地"的文档在本仓里是加分项。

真正需要先处理的是两处**阻塞项**（都属"按文档走会直接起不来"）：

- **#1 配置来源接线**：README 主推的 `llm_confSource` / `llm_confs` 在默认 `llm_metaStore=f_store` 下被 `LLMConfs.createHolder` 短路，配了等于没配，且回退路径 `catch` 静默。静态部署（容器里只给几个模型）是文档明确支持的场景，现在会直接落到"no available llm conf"。
- **#5 建表交付**：`wire()` 并不建表（跳过 SQL 文件就报 relation 不存在）；而 MySQL 的 `tables-mysql.sql` 又缺 `title_vec` / `content_vec`，代码写这两列，按脚本建完库第一次写记忆就 `Unknown column`。"20 张表、两个 SQL 同步、与代码一致"这套说法在 MySQL 侧不成立。

其次按文档操作会踩坑的三条（建议排同一批修）：**#6 裁剪器名不可用且会丢 system**（人格/技能静默失效）、**#3 超时与上限默认值全写成「无」**（排障时找不到 120 s / 1 MiB / 64 KiB 这些真实约束）、**#2 配置只读 vs 60 s 刷新**（密钥轮换与权重调整的生效时机没有权威说法，改文档即可）。

需要产品决策的两条契约缺口：**#4 重试上限默认无限**（`Int64.Max` + 无封顶退避，失败任务可能永远占线程）与 **#8 流式失败转移会重放已输出内容、且不计熔断**。两者都不是"改文案"能解决的，要在 README 里给出明确语义并让实现对齐。

其余为文档精度问题（#7 token 孤儿行、#9 切块无上限、#10–#14、#15 docId 旧格式、#16 JIT 占位符、#18 SsrfGuard 覆盖面、#20 附录残留与常量缺失、#21 三处覆盖遗漏），单条成本都很低；其中 #15 与 #16 会让按文档写出的知识/流程**静默失效或直接抛错**，建议与 #6 同批处理。**#17（`command` 工具无隔离且文档未标注）与 #19（快速开始缺模型配置来源）** 属安全与可用性提示，改文档即可。性能与内存方面本部分**没有任何测量数据**，1 条优化方案与 6 条假设都不进修复清单，下一轮建议先补切块峰值内存（假设 1）与检索重排 SQL 往返（假设 2）。

### 范围外提示（不计入本部分统计）

1. `src/llm/LLMTransport.cj:47`、`src/llm/LLMStreamTransport.cj:49`、`src/embedding/BgeM3Transport.cj:91`、`src/balance/BalanceQueriers.cj:42`、`src/search/DeepSeekSearchProvider.cj:44`、`src/store/hydra/HttpTransport.cj:203`、`src/util/http.cj:26` 共 7 处 `tls.verifyMode = CertificateVerifyMode.TrustAll`：所有出站 HTTPS（含模型 API key、hydra 共享密钥）都不校验证书，README 的安全承诺里没有这一条；建议 `.cj` 部分按严重项复核。
2. `src/llm/ContextPruner.cj:290` `messages[messages.size - 2 * n ..]` 无下界检查（`size < 2n` 越界），且 `:295` 会把 `last` 再追加一次（可能重复）。
3. `src/store/ColbertCodec.cj:57-60` 的 `decode` 有一段空 `if`（不校验 `count` 与字节数），损坏 payload 会越界读。
4. `src/store/PostgresMemoryStore.cj:80-93`：`repo.upsert` 在 sparse 编码之前执行，sparse 失败会留下"有主记录、无倒排"的半写状态（`content-store.md:42-47` 的失败矩阵没覆盖这一格）。
5. `src/llm/LLMConfsHolder.cj:112` 无锁读 `snapshot`、`:255` 无锁写，跨线程可见性依赖运行时实现（无 `Atomic` / 无锁保护）；`ensureFresh` 与 `refresh` 的并发语义建议在 `.cj` 部分确认。

存量缺陷共 21 条（严重 2 / 一般 11 / 轻微 8，#1–#21 全部能在"文档承诺"与"实现"之间双向定位），是否纳入修复待用户决定；本报告只读代码与文档，未做任何修改。

**第 2 部分**：这 20 份文档的分工清楚、可读性好：`f_llm.md` 是当前实现总览，`loom.md` 是使用与边界，`known-limitations.md` 是不可解限制，`perf-baseline.md` / `retrieval-eval.md` 是可复核的数据材料，三份 spec 四件套的决策记录也基本能对上代码。真正的问题集中在两类：

1. **契约口径没有跟着实现收口**：§2.8 把「4xx 立即失败」写成「换候选 + 记熔断」；§6.6 / `loom.md` 把「记忆写入超时」写成「步骤超时」；`known-limitations` 把「模型配置 60 s 刷新」写成「全部启动读一次」。这三条都会让运维/调用方按错误的前提排障，是本次建议优先修的文档项（G1、G5、G7）。
2. **规格里的 MUST 比实现大**：`platforms()` 的「加载即含 email」、`LoomA2aClient` 的 `send/get/cancel`、A2A 与 Supervisor 的开关前置条件，都是规格先写好、实现收窄后没有回改（G2、G3、G4）。它们不一定影响主链路，但会让按规格写代码的下游直接编译失败或拿到空能力清单。

本部分没有新增严重缺陷：文档最坏后果是误导与排障成本。但必须提醒合并方，**执行期上下文全局态（S1）** 在文档里被明确承诺为「绑在一次执行上」，这是本模块最危险的一处「文档说安全、代码不安全」，合并报告时应把它放在最高优先级，并把 `loom.md:231-245/434/510` 列进位置清单。

未做：未运行任何构建或测试（任务约束只读）；`perf-baseline.md` 的数值未复测；ohos 目标是否可构建记为待确认（假设 1）。

**第 3 部分**：本部分 20 个文件全部是 `f_llm/doc/spec/**` 下的变更规格与设计文档，文档本身结构完整、理由写得很足（每条决策都带「替代方案 + 否决原因」，实测数据也回填了），主要问题不是「缺文档」，而是**文档与代码、文档与文档之间的口径已经分叉**：

- 阻塞级问题没有（0 条严重）。7 条一般项里，四条有实际后果：`response.failed` 丢了上游错误码（排障时只剩一句 `response.failed`）、`Redactor` 的掩码阈值比设计承诺更松（9–11 位密文几乎全露）、配置装载失败只记日志且无退避（配置源故障期间每个请求都要付一次失败查询，真实原因又不出现在调用方异常里）、`design.md` §5 的对外 API 与 `LLMContextMediator` 仍写着已不存在的类型（照文档写代码直接编译失败）。附件校验缺 `isRegular`/符号链接判定属安全加固的收尾缺口；MCP schema 清洗口径是规格没跟上 10-28 的设计修正。
- 文档侧最值得优先处理的是 `f-llm-openai-compat/design.md`：它同时保留「正文」与「附录（实现偏差）」两套事实源，而正文没回填——§5 签名、`LLMContextMediator` 去留、Redactor 阈值三处与实现相反，附录又因 10 处标题粘连而无法按条引用。改文字成本极低，但它是全文档被下游引用最多的一份。
- 快照发布无同步（F6）需要先确认仓颉内存模型再定性，若与 Java 普通引用一致，则设计「读路径无锁」的承诺不成立，应按并发缺陷处理（当前按「待确认」定为一般，不定严重）。
- 归档规格里那条「SQL 只出现在 DAO 层」的例外应在归档目录留痕，否则下一轮 DAO 迁移会再次踩到纯 DELETE 的宏缺陷；归档 tasks 的 5.3/5.4 位置（F17）顺手一起修。
- 轻微项集中在文档卫生（标题粘连、进度数字、用例计数、失效脚本路径、D4 标题），一次批量整理即可，不影响使用。

本部分问题共 17 条（一般 7 / 轻微 10），来源全部为「存量」（工作区快照无基线），是否纳入修复待用户决定。

**范围外提示**（不计入本部分统计）：
1. `src/mcp/McpToolSource.cj:126-152` 的 `sanitizeSchema` 对 MCP server 返回的 schema 做无深度上限的递归，schema 由外部 server 控制，存在栈溢出面（§4）。
2. `src/llm/LLMConfs.cj:52-56` 的 `catch(_: Exception){}` 静默吞掉 MetaStore 装配异常，回退到旧来源时没有任何日志（§3）。
3. `src/balance/BalanceQuerier.cj:164` 的 `LLMConfig_balanceLowThreshold()` 全仓无调用者（§1 死代码）。
4. `src/llm/LLMConfsHolder.cj:104-108` 的 `version` 属性读的也是未同步快照，若 F6 成立，该属性同样需要一并处理。
5. `src/embedding/HttpEmbedder.cj:58-74` 用 `cachedText` / `cachedResponse` 做单槽缓存，无同步；该实例经 `Stores` 共享时，两个线程用不同文本调用可能读到对方文本的向量（§12.1）。
6. `src/llm/ContextPruner.cj:291` 的 `RetainLastNRoundPruner.prune` 直接取 `messages[messages.size - 2 * n ..]`，消息数 < 2n 时起点为负会抛越界（§11）。
7. `src/store/MetaStoreAdapter.cj:23-24` 类注释写「没有匹配时回退到 f_store」，而同文件 `:30-33` 与 `init` 明确「不做无条件兜底」（注释与实现相反，§11）。

**第 4 部分**：这 20 份文档的整体质量高于模块平均：`fix-channel-robustness`、`fix-loom-extract-data-loss` 的设计与实现几乎逐条对得上（`strOf` 的 `JsonNull`、端口区间、`receive` 两分语义、按字符截断、按字段独立回落、rune 滑窗都能在代码里找到精确落点与用例），`fix-loom-memory-owner` 的 `PolicyBox` / 默认值 / warn 文案也都落地了。本部分的问题集中在两类：

1. **一条真实的数据完整性残留（#1）**：水位线变更把「推进到 now」改成「推进到已处理的最大 `at`」，但取数仍是 `ORDER BY save_time DESC LIMIT 500`，拿到的是**最新**一批；单轮新增超过 `limit` 时，窗口之下那部分素材会被 `fresh()` 永久过滤。这正是该变更宣称消灭的「静默丢样本」，只是换了个位置，而它的验收场景（「取到 500 条、最大 `at = 200`」）在当前存储契约下不可达——用例只覆盖了「单轮装得下」，恰好绕过要修的那类负载。次一级的 #2（零素材推进到 `now`）是同一处状态记账的另一半缺口。
2. **文档与实现的细粒度漂移（#3–#9）**：符号链接用例被登记为已验证但不存在、`from` 必填口径三处不一、`kindOf` 已被 `kindsOf` 取代、docId 的 128 列宽前提没有约束兜底、用例数 6 vs 9、两份归档 spec 对「分页取数」结论相反、`channelSendRoots` 的「绝对路径」无人校验。这些都是「按文档验收会误判」的类型，改动成本低（改文案 + 补一条用例 + 加一处校验）。

阻塞项：#1 应阻塞 `fix-evolution-watermark` 的「已修复」结论——它是该变更的原始目标，且后果是静默丢素材。可排期项：#2 随下次演进变更一起改；#3 与第 3 部分的 `isRegular` 修复合并做；#4–#9 可并入同一次文档整理提交（#8 建议与 #1 的 `since` 下推决策一起定稿，避免再次互相矛盾）。

### 范围外提示（不计入本部分统计）

- `AttachmentSink.freeName` 在 `while (true)` 之后还有 `base`（`f_llm/src/channel/EmailChannel.cj:142`），不可达语句，属 channel 代码分部分。
- `LoomMemoryPolicy.cj:25-26` 两条 doc 注释都挂在 `PolicyBox` 上，第一条（「序号用持有者带出」）是 `DocSeqBox` 的残留，且 `DocSeqBox` 反而没有注释。
- `LoomWiring.cj:119` 用 `let _ = ChannelBootstrap.installFromConfig()` 丢掉装配报告，而 `README.md:790` / `README_en.md:781` 承诺「单条非法只跳过并 warn」——通道包内 `LoggerFactory` 零命中，`ChannelInstallReport.errors` / `summary()` 全仓无人消费，非法条目实际是静默的（建议在 channel / README 分部分复核）。

**第 5 部分**：本部分 20 份文档对应 5 个 loom 变更（记忆归属、人格/提示词、读路径、网关复用、Supervisor 生命周期）+ 1 份工具设计。主体实现是到位的：记忆策略与人格作用域确实加了锁，docId 带上了租户前缀且演进侧按前缀过滤，prompt 版本语义、宿主不被覆盖、陈旧路由摘除、`lastReload` 可观测、`loomStoreCall` 与 `StoreInvoker` 的复用链路都能在代码里逐条对上。没有「承诺但完全没实现」的功能，这是本模块文档质量较好的部分。

问题集中在四处：

1. **自己写的 MUST 被打折**。`experience` 分页上限（#1）、网关「最多创建一个」（#2）、jit「含 `{…}` 即抛错」（#3）、提炼「不得完全静默」（#4）、`docId`「不得覆盖」（#5）都是 spec 原文的无条件要求，实现各让了一步。其中 #2 #3 #4 改动小、收益直接，可优先排期。
2. **错误分类太粗**：`status()` 异常被当成状态漂移而摘除正常路由（#7）、`StoreInvoker` 用异常类型区分「未装配」并在失败路径重建网关重放（#8）、`loomStoreCall` 没有 design 声称的 op 白名单（#9）。三者都是「不崩但给错结果 / 放大开销」。
3. **文档之间口径不一**：网关创建时机 proposal/tasks 与 design/实现相反（#10），若干已实现行为与两条硬约束没进对外文档（#11 #12）。`executeNow` 的「单进程单流程」限制只写在 `LoomHostApi` 的 KDoc 里，最容易被宿主误用。
4. **文档治理**：六个已完成变更未归档（#15），装配静态态无统一重置入口（#16），25 个同形 Box 类（#13）。

没有阻塞项：不存在会导致崩溃、越界、无界增长的缺陷；性能面唯一值得测的是演进素材的 1+K 次 `knowledge.get`，已按铁律放进「优化可行性方案（无基线）」与「待验证假设」，不进修复清单。

**第 6 部分**：本部分 20 份文档覆盖 5 个已完成的变更（工具层读能力、记忆写入一致性、知识切块 local mode、渲染与快照、检索候选上界）与 3 份合并主规格。**变更文档（proposal / design / tasks / spec delta）质量偏高**：几乎每条 Requirement 都能指到具体函数与行号，`fix-loom-tool-coverage`、`fix-memory-write-consistency`、`local-mode-…-knowledge-chunker`、`perf-loom-render-context`、`perf-retrieval-candidates` 的核心承诺都已落地，`[x]` 与代码基本对得上（唯一例外 #4）。

风险集中在**三份「合并主规格」**：它们由归档工具一次性生成（`1df859449` / `03cd91532`，2026-10-30、10-31），此后从未随实现更新，于是同时保留着「旧配置键」「7 种记忆种类」「内存实现不可选」这些已被推翻的结论（#1 #2 #5 #6）。这类文档最容易被当成当前契约去配环境或照做迁移，其中 #1 的后果是**配了键不生效、静默用了另一个存储后端**，#2 的后果是**选了 `inMemory` 重启即丢全部记忆**——两条都属于「不报错但结果不对」。

另一类是**承诺与实际能力不符**：#3 的 MySQL 无 ANN 分支既没有规格要求的「应用层兜底 + `warn` + `degraded`」，也没有版本探测 —— 9.0/9.1 上整次检索抛错，库名不可得时又静默只剩词面召回，两种形态都不可观测，建议优先补一条 warn 作为最小修复。

无阻塞项：本部分没有会导致崩溃、越界或并发错误的文档承诺。存量 9 条（一般 4 + 轻微 5），是否纳入修复待用户决定；其中 #1、#3、#4 改动小、收益直接（改文档 / 补 warn / 换常量引用），可优先排期。

**第 7 部分**：本部分代码整体结构清晰：余额查询把「单位换算」「签名」「HTTP 注入点」分开，通道层用中介者隔离平台，`imports.cj` 的包级导入也符合仓颉语义。阻塞项有两处：`AgentTask` 构造器的列错位会在装配期直接崩溃且把 `nextEvent` 枚举指错，属于必须先修的正确性问题；余额查询的 `TrustAll` 把 API Key/AK-SK 暴露在 MitM 面前，属于安全问题而非风格问题。

其余风险集中在「异常输入的处理纪律」：余额解析把不可读金额静默成 0、工具参数 JSON 在 `try` 之外解析、技能函数名缺失直接抛、用量落库失败拖垮整轮事件——都是「次要步骤失败被当成主流程失败」或反之。并发面上 `BalanceMediator` 的懒加载与 `names()` 读路径不均衡，`Mutex` 虽可重入不锁死，但锁内做 bean 扫描仍会放大首查延迟并带来重入扫描。

文档方面，两个已完成变更的 spec 与实现基本一致，只有「400 条候选」在无 embedder 路径仍是 1000 这一处口径差需要确认；README 的 `llm_channels` warn 承诺与 `llm_balanceLowThreshold` 默认值都与实现不符。性能类结论本部分没有任何基线数据，全部只作为待验证假设与无基线优化项，未写成缺陷。

**第 8 部分**：本部分的骨架是干净的：中介者的「provider 表 + 实例表」两段式设计与 `fountain-baseline.md` §4 的中介者模式一致，`registerProvider` 同名不覆盖、空账号不猜、错误消息区分「不支持」与「找不到」，都是有意识的正确取舍；`AttachmentSink` 的路径穿越防护（`bareName` 只取最后一段）、同名顺延、选名与写盘分离也做得比一般实现扎实；13 个常量文件只是薄封装，无风险。

**阻塞项（严重 2 条）**：一是接收侧 `downloadDir` 完全没有沙箱约束，而这个值是模型可控的工具参数，绕开了本仓对模型可见文件操作的统一沙箱约定（可向任意可写目录新建文件）；二是收信路径把「邮件数 × 正文 × 2×附件字节」全量物化，`limit` 无上限且 `<=0` 被下游解释成「整箱全部」。两条都在 email 通道主路径上，建议最先修。

**可排期（一般 8 条）**：收发两侧的正文语义各自缺一块（发送丢纯文本、接收丢 HTML 正文）、`receivedAt` 恒空、`ModelNames.normalize` 大小写不对称会让 thinking 判断静默走错分支、`FEmailTransport` 的共享连接无同步、全局锁内关闭连接、根目录不可解析被误报为附件越界、`getPath` 在 getter 里建目录。都属于「功能看着正常、边界上不对」的类型。

**轻微 12 条**：重复判定与重复字面量、静默 catch、不可达兜底、复刻的 `isDirectory`、字节/字符截断、失败残留文件、注释与接线不符、测试隔离与弱断言，属维护性范畴。

**证据缺口**：本部分没有任何 bench/profile 数据，三条优化方案与六条待验证假设都未进入修复清单；最该补的是「元数据模式收信是否白拉整封附件」与「运行期是否会发生重装配」这两个决定了修复优先级的量。若后续能证明多会话并发调用通道是常态，`FEmailTransport` 的无同步问题应立刻上调为严重。

**第 9 部分**：这一部分是「常量 + DAO」两层，结构上是干净的：SQL 全部收在 `@DAO` 接口里、只用 `RootDAO.executor`、参数基本走 `arg()` / `meet().IN()`，DAO 无字段因此天然线程封闭，方言差异（upsert 语法、分页语法、向量类型）也基本收在各自包里，没有出现「业务代码里 `match` 方言」的坏味道。合并后没有发现空实现、递归、无界容器或锁粒度问题。

真正的阻塞项只有一个，但性质最重：MySQL 稠密召回为了给 `MYVECTOR_IS_ANN` 传 filter 子查询，把 `namespace` / `docId` 手工拼进 SQL，而自研转义只处理单引号 —— 反斜杠可越出字面量，且 `namespace` 就来自模型工具入参，属生产可达的注入面（#1）。这一处必须与「两处引号列表合并 + 白名单/补全转义」一起改，不能只改一行。

其次三件「契约与实现不符」需要在合并前定调，因为它们决定 MySQL 后端到底能不能用：#4（`llm_memory` 的向量列在随仓 DDL 里不存在，若 DDL 为准则是后端起不来）、#2（`LAST_INSERT_ID()` 跨语句依赖会话，非事务路径下连接已归还池）、#3（`kinds` 过滤在 MySQL 检索被静默丢弃，与内存后端行为不一致）。三条都不是新代码引入，但都会表现为「线上行为与本地/内存实现不同」，建议优先于其余项排期。#5、#6 属健壮性（`INSERT IGNORE` 吞错误、`MAX(id)+1` 多实例冲突），可排在其后。

6 条轻微项（公开常量拼写、TodoStatus 词表、空置的 `imports.cj`、索引补建不对称、LIKE 通配符、四组重复逻辑）都是低成本、可批量处理的技术债，其中 #12 的重复逻辑建议与 #1 同批做（同一处转义、同一处引号列表）。

存量 12 条（严重 1 / 一般 5 / 轻微 6），是否纳入修复待用户决定；本部分不涉及本次改动引入的回归。

**第 10 部分**：三个 DAO 是本部分质量最好的代码：SQL 全部走 `${arg(...)}` / `meet().IN(...)`，没有拼串，`searchDense` / `searchSparse` 里 `arg()` 的绑定顺序与占位符出现顺序逐条对得上（`MemoryDAO.cj:55-74`、`:105-124`），`TokenUsageDAO` 只追加不更新，语义干净。风险集中在 **embedding 客户端这一层**，而且三条严重问题同源——都是**共享状态**：

1. `HttpEmbedder` 的单槽缓存把「避免三次 HTTP」的局部优化做成了跨线程共享可变状态，两个字段分开写、判据跨字段读，最坏会返回**别的文本的向量**并静默入库。这不是性能问题而是数据正确性问题，且现有测试（`BgeM3Codec_test.cj:55-66`）只覆盖单线程。
2. `BgeM3Transport.embed` 用 `HttpClient.globalReadTimeout` 设超时，等于每次向量化都改**全进程**默认 HTTP 超时；`f_httpclient` 已提供实例级 API（`httpclient.cj:106-117`），属用错接口，修法是行级改动。
3. `TrustAll` 无条件生效：默认回环 http 下无害，一旦端点是 https 就是证书校验整体关闭，失败方式完全静默。

**阻塞项**：第 1、2 条建议下一版前修掉（数据错误 + 数据竞争 / 跨组件副作用 + 无同步静态写）；第 3 条至少收敛到「回环才 TrustAll」。**可排期**：分页排序键（一般 #5，管理端可见）、4xx 重试与失败转移（一般 #2/#4，影响 SLO 与可运维性）、零填充与 usage 不落库（一般 #3/#7，影响检索质量与成本核算，且难观测）。**可后置**：重复样板、注释漂移、错挂注释、未读字段、冗余语句（轻微 #1–#7）——维护成本，不是当前故障源。

值得肯定的是：`BgeM3Codec` 与 `HttpEmbedder` 的拆分让解析逻辑可脱网单测（`BgeM3Codec_test.cj` 全部离线），`LlmEmbeddingTransport` 作为 OpenAI 兼容备选在类注释里写清了降级后果（`LlmEmbeddingTransport.cj:22-27`），这种「把可测性与降级说明做进设计」的做法值得在模块其余部分保持。

存量缺陷共 18 条（严重 3 / 一般 7 / 轻微 8），是否纳入修复待用户决定。

**第 11 部分**：请求构造层的骨架是对的：`ChatCompletionsMapper.build` 是纯函数、无共享状态，`testTemperature*` / `testStreamFlag` / `testResponseFormat*` / 多模态三例把主要分支钉住；`finder` 的 10 个接口职责单一、工具层统一走 `lookup`，分层没有违规；消息模型用 `DataAssist` 保证 `ToolCallMessage.tool_calls` 能进报文（`ResponsesMapper.cj:187-200` 另有手工构造）。并发面与资源面干净：无锁、无阻塞 I/O、无 `spawn`，不存在死锁、线程饥饿或资源泄漏风险；本部分也没有栈溢出候选与无界容器。

主要风险是**响应侧的「失败被当成功」**，这一族共 5 条（1 严重 + 4 一般）：`parse` 对空 `choices` 静默返回空响应（#1，唯一严重项：`LLM.call` 记成功 + 下游 `messages[0]` 越界）、非流式不标 `usageEstimated`（#2，计费落 0 且看不出没数据）、畸形字段抛 `JsonException` 绕过候选切换（#3）、流式不索要 usage（#4，prompt 恒 0）、`CallLog` 完全没接线（#5，文档承诺的调用汇总与失败观测点不存在）。五条叠起来的后果是「计费与可观测性同时失真」，而 #1 还会把上游故障伪装成模型空回复。建议修复顺序 #1 → #2 → #3 → #5 → #4：#1 是几行防御 + 一个 `LLMException`，#2 / #3 集中在 `parse` 入口，#5 若短期不接就改文档措辞（`doc/f_llm.md:157/581`），#4 需要配合 `ChatStreamAccumulator` 的 `null` 块处理一起改。

第二条线是**多模态的 `content` / `parts` 双表示**（#6）：`UserMessage('描述这张图').addImage(url)` 会把问题本身丢掉，而仓内唯一的使用形态（两个测试）已经把这种行为写成期望，说明这不是「偶发漏写」而是语义没定清。修法要连测试一起改，建议与本轮文档补齐放在一起。

8 条轻微里，`temperature` 语义与 `LLMConf` 注释相反（#7）是用户最容易踩的（配置填 -1 实际发 1.0）；`intOf` 静默归零（#8）会放大 #2 的症状；两处 `private init` 死代码（#9，编译器 warning 佐证）与一条未使用 import（#10）属清理项；三组重复逻辑里 #12（Chat / Responses 的 `build` 三段，且 Responses 漏了 `response_format`）已经造成实际行为漂移，值得排一次小重构，#13 的同名 `RoleException` 建议直接删掉 `embedding/exception` 那份（需确认无下游 import）。#14 是用例归属问题，修 #1 / #2 时顺手拆分最省事。

两条优化方案与五条待验证假设都需要先有 profile / 峰值内存数据才能立项，本轮不作为结论、不进 `tasks.md`。

存量缺陷共 14 条（严重 1 / 一般 5 / 轻微 8），是否纳入修复待用户决定；本部分无「本次改动」问题（工作区快照无 diff 可比）。本报告只读代码，未运行构建、未修改任何源码。

**第 12 部分**：本部分代码整体结构清晰：门面（`LLM`）与传输（`LLMTransport`/`LLMStreamTransport`）、配置快照（`LLMConfsHolder`）、熔断（`CircuitBreaker`）、裁剪策略（`ContextPruner` 家族）职责划分合理，`Option`/`synchronized`/`resource` 的用法基本正确，`CircuitBreaker`、`LLMConfsHolder`、`ContextPruner` 都有针对性用例。

阻塞项五个：① `TrustAll` 让所有模型请求裸奔，属安全底线问题，修复只需几行；② 客户端没有自己的超时，且会被 embedding 的 3s 全局读超时接管，流式长回答会被误判为传输失败；③ `RetainLastNRoundPruner` 的负下标会让首轮会话必然崩溃；④ 流式中途失败的重放会向用户输出重复内容，属对外契约级错误；⑤ `previewOf` 的字节切片会在中文错误体上抛异常，恰好让「本该重试」的 429/5xx 变成硬失败。这五条都在主路径或公开 API 上，建议优先处理。

其余问题集中在两处设计缝隙：一是「读写共享状态的同步策略不统一」——快照无锁发布、失败不退避、版本号按旧快照递增，三者叠加会让「配置刷新」在高压下表现不稳定；二是「同一判据多处实现」——饱和阈值、候选过滤（`weight > 0` / `enabled`）、熔断记录都各有两个入口，已经出现 `enabled` 失效与默认 conf 选错这种可观测的分叉。这两类建议在合并报告里按根因一起排期，而不是逐条改。

性能方面本轮没有任何 `cjprof` / `cjpm bench` 数据，所有可疑点（流式每帧解析、balancer 全局锁、每请求候选复制、transport 短锁）都只写进「待验证假设」与「优化可行性方案」，未计入缺陷，也未给出收益百分比。

**第 13 部分**：本部分是"LLM 客户端契约层"：传输抽象、思考能力/策略、两套协议的报文与流式归并、token 计数、平台方言表、A2A 桥。整体结构是清楚的——`LLMTransport` / `LLMStreamTransport` 把网络隔离出来（测试确实能脱离网络跑），方言表把"报文长什么样"和"模型支不支持思考"分开了（`ThinkingPolicy` 在 `decorate` 之后执行，顺序正确），Responses 的两处协议差异（`instructions`、扁平工具、`output[].type` 分派）也都在 mapper 里消化掉了，没有散到调用方。

真正需要先处理的是**安全问题而不是性能问题**：唯一阻塞项是严重第 1 条——传输层把 TLS 证书校验无条件关成 `TrustAll`，而报文头就是明文 API Key + 完整模型应答，且这段代码有三份拷贝、没有任何配置开关。它不是"内网自签证书的兼容手段"（没有 host 判断），也不是文档化的已知限制；建议与"超时显式化"（一般第 4 条）一起做，因为两者都要改同一个客户端构造点，顺手就能把三处重复（轻微第 4 条）收敛掉。

第二类是 **Responses 路径的契约漂移**：一般第 1、2、3、7 条加上轻微第 9、10、15 条，全部集中在"Chat 有、Responses 没有或者读错位置或错挂"。`respond`/`respondByName` 目前在仓内没有生产调用方（只有测试），所以这些不会立刻炸线上；但一旦下游按 README 的"Responses 风格接口"接入，表现会是"不报错、结果不对"：参数不生效、失败当成功、半截图当完整答案、token 账单口径不一致、reasoning 串到下一条消息。这类问题建议一次性补齐，并加一组"同一 `LLMParams` 双协议字段对照"的用例，而不是逐条修。

第三类是复制粘贴带来的维护成本（轻微第 1-4、6、10 条）：6 份 `endpoint`、3 份 `headers`、两个 mapper 的三段同构逻辑、两处 HTTP 客户端构造。它们现在只有 `Accept-Encoding` 一处真实漂移，但正是这些拷贝让"改一处安全策略"变成"改三处、漏一处"。按收益排序，先收敛 HTTP 客户端构造（同时修严重第 1 条），再收敛方言 `endpoint`/`headers`。

其余轻微项（`providers()` 顺序敏感、A2A 卡片硬编码、`DoSample` 空 setter、模型名归一漏大小写、token 估算盲区、流式 JSON 守卫、测试全局状态）都是"小改动、低风险、可排期"的清理项，不影响主链路正确性。两条优化方案（HTTP 客户端复用、remote 计数去全量拼接）都没有基线数据，按要求只作为下一轮补测清单，不进修复任务。

**结论**：严重第 1 条必须修（凭据暴露面）；一般第 1/2/3 条建议同批修（Responses 契约与静默失败）；一般第 4 条需先补 stdx 默认超时的确认再定改法；其余可排期。

**第 14 部分**：本部分代码整体结构清晰：职责切分（`CodeGen` 只产源码、`LoomCompiler` 只编译、`LoomRunner` 原生组装流程、`FStoreLoomStore` 只做键布局）与 `doc/loom.md` 的设计叙述基本一致，出错路径大多有兜底与注释说明，没有 TODO 残留、没有递归、没有无界容器。

阻塞项有两条。第一条是 **`LoomContextLog` 的进程级单例**：它把「一次执行的临时上下文」做成了全局状态，而执行入口（工具调用线程、ticktock 线程、`loomExecute` 嵌套）都没有串行化，后果是记忆提炼丢轮次与跨流程/跨用户内容串台——后者是数据正确性与隐私问题，建议在合并模块报告时列为该模块最高优先级。同一根因在 `LoomHostApi`（范围外）还有一份「单线程使用」的口头约束没有运行时保障，两者应一起改成执行级上下文对象。

另一条是 **`JitTicktockTask` 没有宿主可绑**：`README.md:533` 承诺「JIT 步骤在任务里执行时由 `JitTicktockTask` 承接」，但定时触发时刻 `LoomHostApi` 一定未绑定（只有 `LoomRunner.runCompiled` 会绑），凡是 tool/mcp/llm 步骤或 jit 片段里调用 `loomCallTool`/`loomStore` 的写法都会抛错并被 `catch → ()` 吞掉；更糟的是若有别的流程正在跑，它会借用那条流程的 host。当前生产调度走 `executeNow`（跑整条流程），本类只被测试引用，所以是「照 README 用就会静默空跑」的缺陷，建议要么补绑定+日志，要么删掉入口并改 README。

其次是四条「落库/文档与执行不一致」的问题：`CodeGen` 与 `LoomCompiler` 三份同形模板且 `flowSource` 与 f_egraph 签名不符、`StepPlan.async` 只影响预览（G2）、`FStoreLoomStore.save` 先写状态（G3）、`llm_memoryStore=inMemory` 时租约选错实现（G8）。它们的共同风险是**审计与预览失真**——排查线上 loom 问题时，看到的源码/状态不等于真正跑的东西，这类偏差比崩溃更难定位，建议排期修复。

其余为一致性收敛项（G4、G5-G7、M1-M8），可随演进链路的下一轮重构一起处理；两条 CPU 优化方案没有基线数据，只作为下一轮补测量的入口，不进修复清单。

### 范围外提示（不计入本部分统计）

- `LoomHostApi.cj:28` 用注释声明「约束：单线程使用……（当前 loom 的执行模型是单流程串行）」，但 `LoomService.executeNow` 无任何串行化，`loomExecute` 工具与 ticktock 任务都能并发进入；该文件属同模块其他部分，请与 S1 合并看。
- `LoomRunner.cj:313-315` 有一个空实现的 `release(flow: Flow<EndExecutorGetter>)` 重载，两处调用点（`:275`、`:309`）的静态类型分别是 `ImmediateFlow` / `AsyncFlow`，不会选中这个重载——疑似死代码 + 空实现，建议由覆盖 `LoomRunner.cj` 的部分确认。
- `LoomJitBridge.cj:38` 注释写「幂等：重复安装会覆盖同名函数」，但 `f_jit` 的 `Compiler.registerFunction` 对同名是抛 `DuplicateRegistration`（`f_jit/src/Compiler.cj:70-73`）；当前每次 `LoomCompiler()` 都新建 `Compiler` 实例所以不触发，注释与实际语义不符。
- `Plan.cj:133-140` 只拒绝自环，不拒绝环；配合 `CodeGen.firstStep`（`CodeGen.cj:148-162`）在「所有步骤都有入边」时回落到 `steps[0]`，环计划会让 `registerStart` 指到一个有入边的步骤、`JoinBarrier` 永远等不齐。属 `Plan.cj` / `LoomRunner.cj` 的覆盖范围。
- `LoomTimeout.cj:38-59` 用普通字段 `done/value/error` 做跨线程信号（`spawn` 写、调用方轮询读），无原子/锁；`MemoryRecorderTask.recordWithTimeout`（本部分 `BackgroundTasks.cj:41-45`）是它在本部分唯一相关调用点。可见性问题建议由覆盖 `LoomTimeout.cj` 的部分定级。

**第 15 部分**：这 20 个文件的局部质量不错：模板渲染是单遍扫描且保留"未命中不替换"的可排错语义（还有专门的边界用例）；记忆提炼对模型返回做了按字段回落、临时上下文有 200 轮上限；注册表与网关的锁基本遵循"锁内拷贝、锁外干活"的写法（`callStore`、`currentPersonaText`、`render` 都如此），并解释了为什么不用普通局部变量带返回值；测试覆盖面扎实（同步/并行菱形、失败流程写经验、人格三级解析、跨租户 `docId` 唯一性都有断言）。

真正的风险集中在**执行模型的全局性**：#1 把 host、步骤输出、人格、技能、临时上下文全部放在进程级静态量里，而 `LoomRunner` 每次执行都 `bind`/`unbind` 一遍，四条入口（工具调用、定时任务、Supervisor 派发、`LoomAgent`）都没有串行化——并发时不仅丢步骤输出，还会把 A 的人格/技能/记忆串到 B 上（跨租户）。#2 让并行模式下的任何步骤异常变成永久挂起，且异常无日志、`finally` 不执行。#3 是"计划形状不合规就静默跑半个流程或直接挂住"，与项目已有的"`http` kind 直接拒绝"原则不一致。这三条是阻塞项，修法方向清晰：执行上下文变成执行期对象 + 等待加超时/错误回传 + 校验计划根与可达性。

其余按严重度排期即可：#4/#5/#7 属于"模型产出或参数略不合规就静默错"（`dryRun` 无效、分页超量、`userId` 归零）；#6/#8/#9/#10 是注册表与网关的并发/一致性/覆盖语义；#11/#12 是契约文档与容量治理；#13-#19 是死代码、重复逻辑、注释与测试卫生。性能方面只有三条候选（复用编译产物、排序/列举结构、`render` 快照），全部缺基线，先按「待验证假设」采数据再决定，不进入本轮修复清单。

**第 16 部分**：这 20 个文件的骨架是清楚的：`Plan`/`Planner` 把 LLM 产出的 JSON 收敛成受校验的 `FlowPlan`，`LoomWiring` 用一句 `wire` 把服务、宿主、网关、调度、演进接上，评测侧把「算指标」（`RetrievalEval`）与「接真实编码器」（`RetrievalEvalRunner`）拆成两层，测试覆盖了主路径与主要错误分支，`validate` 的报错文案都带步骤 id，可排错性不错。分层与命名没有明显问题。

**阻塞项三个**：#1 `Planner.parse` 剥了围栏却仍解析原始串——「模型输出被代码块包住」是最常见的真实情况，当前实现把它变成一次裸 `JsonException`，`stripFence` 在这个入口等于白写；#2 `LoomTimeout` 用无同步的普通字段跨线程传结果，数据竞争可能把空串当成功、也可能对已完成的调用误报超时；#3 评测入口会清空整库技能并覆盖进程级 `SkillCatalog`，误传生产 store 即不可回滚地丢数据。三者修法都很短（换 `trimmed` + `try/catch`；换 `Future.get(Duration)` 或原子发布；清库改成按标题命中删除 + `finally` 还原）。

其余按严重度排期即可：#4/#5/#9 是「契约写了、实现没跟上」（`onUnresolved` 无消费点、提示词放出 `http` 而校验器拒绝、空计划被当合法计划落库），#6/#10 是并发与全局状态（网关可能建两份、注入的 store 并不隔离演进族存储），#7/#8 是「失败被静默」（cron 异常无日志、标题映射丢命中），#11-#19 属校验完整度、重复逻辑与文档卫生，可以合并到同一次清理里做。

性能方面只有一条候选（`jsonQuote` 的两次字节拷贝）与四条待补数据的假设，本轮不产出性能结论、不进入修复清单。

**第 17 部分**：本部分（技能检索、演进流水线、Supervisor 路由、工具层存储入口）结构清晰，分层与命名一致，锁的用法是「锁内只碰容器、锁外做计算与回调」的正确姿势；`StepSourceCodec`、`SkillEvolutionPolicy`、`Supervisor` 路由表的边界处理与小样本用例较扎实，没有栈溢出、无界任务提交或明显的数据竞争。

主要风险集中在三处：

1. **失败语义**——多条降级路径把「失败」表达成「没有数据」：存储异常被吞成空集合、status 查询异常被当成「未编译」并永久摘路由、技能编码失败就静默退出检索、A/B 门禁把调用失败记成 0 分。这些都不报错，只表现为「技能不生效 / 流程选不到 / 演进选错版本」，是最难排查的一类。
2. **演进流水线的状态记账**——知识在未落地前就被标记消费、空轮（含读失败轮）把水位推进到 `now`、水位混用时间戳与 id、以 title 而非 id 作为技能身份、台账用 `split(':')` 反解标题。五条叠加会让「谁被演进过、为什么没演进、哪些素材没进来」在长跑后与事实不符，且部分跳过不可逆（只能手工重置水位）。
3. **确定性成本放大**——`SkillMatcher` 把 encode 放进技能循环（素材数 × 技能数 次远程编码）、聚类阶段每对重新编码两侧、`knowledgeOf` 的 1+N 取数、`SkillCandidate.score` 算了没人用。这几处不需要 profile 就能确认工作量放大，但收益比例仍需基线，故只列入优化方案与待验证假设。

没有阻塞级（严重）问题；建议优先排期第 1、2 组——它们影响「能力是否悄悄失效」与「审计是否可信」，而非性能。性能类结论（热点、收益百分比）本轮一律未成立，需下一轮补 profile 数据。

**第 18 部分**：`model` 包与 `ToolCatalog`/`ToolFunctions` 这类"纯数据 + 纯转换"的代码质量良好，`ToolScope` 的实现本身也正确（校验语义清晰、错误消息带上下文）。真正的问题集中在 `memory` 包：`FaithfulMemoryImpl.summarise` 一个循环里同时踩了三个独立错误——把 session 主序当时间序（#1）、删除时复用当前条目的 `timeStr`（#2）、内容键只精确到毫秒（#3），而整条链路又跑在没有异常保护的 `Timer` 任务里（#4），任一环节出错都会以"功能静默消失、需要重启"的形式呈现。这四条建议作为阻塞项一起修，并配一条"写入 N 条 → 触发摘要 → 断言存储已清空、记忆只写一次"的端到端用例；否则单修其中任一条，其余两条会让验证结论失真。

`ToolScope` 未接线（#7）与 `KnowledgeEntity` 的两处未校验（#10/#11）属于"API 存在但路径不通"的半成品特征，建议排期处理；`McpToolSource.load` 的半途状态（#8）在 MCP 真正接入前修掉即可。其余重复逻辑与注释不一致项按轻微排期，可随下一次重构一并清理。

**第 19 部分**：这一部分的代码形态是“PO + 薄 Service + 搜索适配器”，分层和命名干净：`LLMConf` 把 `conf` 列收敛到唯一 codec，`LLMConfSource` 把四种配置来源抽象掉，`DeepSeekSearchProvider` 把 3xx 拒绝与字段归一化写清楚，可读性在模块内属于较好的一档。

阻塞项集中在出站 HTTP 这一层：`TrustAll`（#1）让携带 API key 的搜索/抓取可被中间人劫持并注入模型上下文，上线前必须处理；#2（无自身超时、继承被 embedding 改写的全局值）与 #3（响应无上限物化）是同一个“HTTP 客户端没有业务边界”的两面，表现为偶发失败或一次大页面把进程顶到 OOM。三者修法互相独立、都不大，建议一起排。

其次是配置正确性：#7 让 `env`/`file` 这两种文档化来源在多模型场景下经 `all()` 丢配置（直接影响 `webSearch`/`webFetch` 选平台），#4 让一次 provider 构造失败永久静默关闭搜索能力，#5 让运维按注释写 `secretRef` 必然 401 —— 都不会崩，但都属于“功能在特定配置下静默不可用”，排期紧跟安全项。#8/#9/#10/#17/#18 属于契约与测试的欠账，可合并成一次“配置装载与测试夹具”清理。轻微项（死导入、注释与实现不符、逗号列归一化、重复的 client 构造）建议随手带上，不必单独排期。

**第 20 部分**：本部分是 `f_llm` 的存储底座：`store/` 下的 f_store 元数据族、演进状态/报告表/租约、内存实现、切块与索引重建。功能实现完整、注释密度高（键布局、精度取舍、local mode 的 `-O0` 坑都写清了），单测覆盖也算扎实；**风险不在单个函数，而在"同一个路径 / 同一个实例被多处独立构造"这条主线**：

- 阻塞项一（**#1**）：`llm_metaStorePath` 被 4 个类各自 `Store(path)`，而 f_store 的 `Store` 构造会删掉目录下全部 WAL（`store_func.cj:216`）。配上 `Stores.meta()` 每次新建实例、`SkillCatalog` 每次检索新建实例的现实，这是"改动/重启后 skill、prompt、character 写入消失"的直接解释，也是线程与句柄随请求增长的来源。修法应落在"一个路径一个 Store + 工厂缓存"，而不是逐个类打补丁。
- 阻塞项二（**#2**、**#6**）：两个 `@Bean`/共享实例（`InMemoryMemoryStore`、`LoomStoreGateway.meta`）都假设单线程：一个连 `Mutex` 都没有，一个的 `prompts.remove` 是检查-然后-写入。同一模块里 Evolution 系列已经给出了正确范式（`Mutex` + `Box` 带出 + 布尔标志），照抄即可。
- 边界上的静默错误（**#4**、**#7**、**#8**、**#9**、**#11**）：租约在每天前 66 秒可能失效（注释还写着"不会跨天漂移"）、`put` 承诺覆盖却只追加、内存版 `bySkill` 只看最新 1000 条、一条脏记录能让整表读取抛异常、删文档不删向量。这些都不会报错，只会让"配置/历史/内存"慢慢对不上，靠日志很难定位。
- 配置来源的静默降级（**#20**、**#21**、**#22**）：`StoreMetaConfSource` 只搬 9 个字段，`LLMConf.conf` 里的 `chatPath`/`thinking`/`tokenizerUrl`/余额凭据全部丢失，同一份配置走 store 来源与走 JSON 来源行为不同；配置 id 用遍历序号，配置一变熔断状态就串到别的模型；inMemory 模式还存在两份 `MemoryStore`，经 `Memory` 写入的记忆在 loom 网关侧不可见。这一类是"功能看着齐全、实际少一半"的形态，建议与 #7 的 `put` 语义一起收口。
- 工程化欠账（**#3**、**#17**、**#18**、**#19**）：`decode` 信任 blob 里的长度（OOM 面）、显式 id 路径无人走也没对齐 `maxId`、测试用固定 `/tmp` 目录 + 全局自增计数、键编码不转义。都是低成本可修的项，建议与 1.3.x 的存储收口一起做。
- 性能与内存：本部分没有任何改前/改后数据，四条优化与六条假设**不进修复清单**；其中"构造期 `repair` + 每次新建 Store"与 #1 同源，修 #1 时顺带就能缓解，值得下一轮补 `cjprof` 与前后的线程/句柄曲线。
- 已确认**没有**的问题：栈溢出（无递归）、死锁（无嵌套取锁、无锁内回调）、`Option` 被静默丢弃（全部 `match` 消费）、local mode 误用（`KnowledgeChunker` 的分档有注释与单测支撑）、接口默认空实现被漏覆盖（mysql/postgres 全部覆盖）。

存量缺陷共 22 条（严重 3 / 一般 12 / 轻微 7），是否纳入修复待用户决定；本报告只读代码，未做任何修改。

**第 21 部分**：本部分是两个"装配层"文件的组合：`store/` 的契约与模型（`StoreContracts` / `StoreModels` / `RetrievalScoring` / `PredefinedCharacters`）质量不错——打分公式收口成唯一来源且有测试锁定，接口注释把"谁负责打分、谁负责过滤"写得很清楚；问题集中在**装配是否把契约落实**这一层，且都是存量：

- 两个阻塞项都属"承诺了但没接线"：#1 适配器漏转发 `listByKind`，让 `kind` 过滤在生产路径退化成近似实现（静默少读）；#2 启动重建入口零调用者，`llm_rebuildIndexOnStart` 是彻底无效配置。两者都不会报错，只表现为"结果不对/功能没生效"，排查成本高，建议优先修。
- 次一级是写入侧的一致性：#3（空索引覆盖）与 #5（三段写入非原子 + 静默 catch）会留下"有记录无索引"的永久脏数据；#4 的 `degraded` 既是误报源又没有消费点，观测价值接近于零。
- 检索结果的可解释性是第二组风险：#22（rerank 全缺失时退化成插入序）与 #23（`maxSim` 负值截断 / 维度静默截断）都会让"同一批数据、同一份配置"给出难以复现的顺序差异，且都不抛错；配合 #1 的 kind 后过滤与 #21 的并列分无 tie-break，"检索质量"目前无法从代码或日志上自证。
- 并发面很窄：整部分只有 `MemoryKinds` 一个进程级可变注册表（#6），当前无生产并发调用者，属潜伏问题；`SqlMemoryStore` 无状态、适配器与重建工具纯静态，不存在锁粒度问题。
- 14 条轻微项主要是字面量复制（实现名、`contains`、token 合并、人格双表）与注释/命名漂移，可排期清理；`weightOf` 的等价分支（有规格依据）、`emptySkills`/`resetForTest`/`keys()` 的可见性建议适合顺手处理；#24 指出了重建工具的「不可断点续跑 + offset 窗口漂移」，运维前建议先补日志再跑大库。
- 性能面本轮**没有任何测量数据**，7 条候选全部只在「待验证假设」里，未写成结论、也不应进 `tasks.md`。

存量缺陷共 26 条（严重 2 / 一般 10 / 轻微 14），是否纳入修复待用户决定。

**第 22 部分**：本部分（`store` 层 hydra 客户端 + 集成测试）的主要风险集中在**远程/并发两条路径**：

1. **阻塞项**：`nextId()` 的读-改-写没有互斥（#1），并发写入会重复 id 并静默覆盖已存记忆 —— 这是数据正确性问题，默认配置（`f_hydra`）就命中，应先修。`HttpTransport.upsert` 的字段投影缺失（#2）让 `fhydra` 远程部署下的 `listByKind` 恒空、colbert 重排静默失效，属于「文档承诺了、实现丢了」的契约缺口，同样建议在本次门禁内处理（fhydra 侧 `UpsertParam` 缺 colbert 字段，需两侧一起改）。
2. **可排期**：`upsert` 不按唯一键覆盖（#3）、`saveTime` 丢读（#5）、`"error"` 子串误判（#6）、TLS `TrustAll`（#9）、分隔符无转义（#10）、知识库 upsert 非原子（#11）都是确定性缺陷但触发条件较窄（特定配置、特定输入字符、特定部署形态）；`colbert()` 恒空 title（#4）只影响重排精度。
3. **测试质量**：集成用例的「只把连不上当 SKIP」写法（`LoomStore_test.cj:49-52` 的注释与实现）是正确的，值得在其余 IT 中推广；但 `HydraEvolutionLease` 完全没有 IT 覆盖（`EvolutionStoreIT_test.cj` 只跑 PG/MySQL 两个实现），`HydraRemote_test` 也没覆盖 `listByKind` 与 colbert —— 正好是 #2 这类缺陷的盲区，补两个用例的成本很低。
4. 代码整体风格统一（注册表 + 工厂 + 接口 + 契约注释齐全，注释里写明「为什么」的比例高于模块平均），重复逻辑不多且都是可合并的小块（#15），死代码只有 3 条弱形态。

**存量 18 条（严重 2 / 一般 10 / 轻微 6），是否纳入修复待用户决定；本次未改动任何源码。**

**第 23 部分**：本部分（MySQL / PostgreSQL 两套 SQL 存储实现 + 3 个集成测试文件）的代码本身写得规整：SQL 全部下沉到 `dao/{mysql,postgres}`，方言差异集中在 DAO 的 `ON DUPLICATE KEY` / `ON CONFLICT` 与 MyVector/PGVector 表达式上；`?Any` 行映射对 Int64/Int32/Int16/Float32/字符串都做了分支，位图/colbert 的 `Array<Byte>` 也有空值兜底；演进租约用「单行 + 条件更新」实现跨进程互斥，比锁服务轻且语义清楚。**唯一阻塞项是 `MemoryRepository.remove` 的子表删除未带 `user_id`**——它把「删别人的记忆」从不可能变成了副作用，且 PostgreSQL 侧直接丢 dense 向量（需重建索引才恢复）。这条必须在 MySQL/PG 上任何生产使用前修掉；它之所以存在，正是两套实现逐行复制、子表结构又不同（PG 是独立 vector 表 + token 表，MySQL 是宽表 + token 表）的结果，所以「抽一层方言无关基类、把清理顺序写死一处」应作为随后的排期项，而不是可选项。

其余各项按危害排序：`saveTime` 恒为 `now()` 会让技能演进每轮重跑全部经验（白烧 LLM 调用，且 `doc/loom.md` 承诺的「按真实时间比较」不成立），PG 漏删 token 是慢性表膨胀，`JSON_ARRAYAGG` 空集与 `nextId` 撞主键属「需要一次实测/一次部署形态确认」的边界问题，可按上面的验证清单补齐数据后再决定是否修。死代码只有 `minOf`×2 与一个未用的 `DRIVER` 常量，重复逻辑的主要形态就是方言双份代码（≈84% 相同）而非散落的字面量复制；性能侧没有 profile 数据，因此 `vectorLiteral`、批量写入、锁粒度都只写进「优化可行性方案 / 待验证假设」，未计入缺陷。

存量问题共 12 条，是否纳入修复请用户按「严重 1（越权删除）→ 一般 5」的顺序拍板；本报告未改动任何源码，也未运行构建。

**第 24 部分**：本部分（`src/tool/` 内置工具 + Postgres 用量落库 + 两个测试）的整体结构是清楚的：工具注册与调用有单一入口（`FunctionMediator`），原型 bean 会关闭，`definition`/`call` 分层干净，`SsrfGuard`、`ToolName`、`LLMToolLoop` 都带「为什么这样写」的注释，代码质量在「可读」这一档之上。

但**工具的实际行为与它给模型的承诺之间有系统性落差**，这是本部分的主要风险，建议按阻塞项处理：

1. 沙箱不成立（`genPath` 只挡 `../` 前缀，`Path.join` 不规范化）——模型可控路径即可读写沙箱外文件，`writeFile(truncate)` 还能清空任意文件。三个文件工具共用同一处，改一处即可，且仓库内已有正确写法（`EmailChannel` 的 `canonicalize` + 前缀比较）可对齐。
2. `command` 工具的输出永远是空的（`Inherit` 不捕获），且无超时、继承 stdin，长命令会把工具循环挂死。这两条让 `command` 目前处于「看起来能用、实际不可用或会卡住」的状态。
3. `replaceFile` 先 `setLength(0)` 再编译正则，非法正则直接毁文件——数据丢失不可逆，修法很小（把正则编译提前 + 临时文件原子替换）。
4. `SsrfGuard` 的四种字面量绕过（尾点、`?`、`127.1`、IPv4-mapped IPv6）让 SSRF 防护在最外层就失效。

其余为可排期项：读文件无大小上限与 `head` 按模型整数预分配（OOM 面）、工具名约束在两条注册路径上不一致、`ensureLoaded` 锁内构造全部 bean、`LLMToolLoop` 就地改写入参、`Australia/Sydney` 的 DST 错报、以及两处重复的 epoch→日期换算。性能方面本部分没有任何可复核的测量数据，5 条与锁/分配/DAO 取值相关的怀疑全部放在「待验证假设」，未计入缺陷，也未写成收益结论。

存量共 23 条（4 严重 / 9 一般 / 10 轻微），是否纳入本轮修复由用户在门禁决定；本报告只报不修。

**第 25 部分**：本部分是「工具出口 + 脱敏/裁剪工具函数 + 启动接线」，整体结构清晰：`redactJson`/`truncateBytes`/`TextClip.clip` 都写了为什么这样做（UTF-8 边界、gzip、不截断工具名），`StoreWiring` 的幂等与失败降级也与文档口径一致，**没有死代码和空实现**，`public` 面收得比较干净。

主要风险集中在三处：

1. **工具结果预算不统一**。`llm_toolResultMaxBytes` 名义上是全局工具预算，实际只有 `webSearch` 一个工具在用（`WebSearchFunction.cj:68`），`LLMToolLoop` 出口也不兜底 → `todoList` 可以把整张待办表灌进上下文，`webFetch` 的 `llm_fetchMaxBytes` 又能被超长标题绕过、且正文在截断前已整段物化。这是最容易在真实流量下变成「上下文爆掉/费用飙升」的一条，建议优先处理（一条 `LLMToolLoop` 出口兜底 + 各工具显式预算）。
2. **脱敏原语在边界输入上会抛异常或漏脱敏**。`mask` 用字节下标切片（多字节凭据 → `IllegalArgumentException`），`redactJson` 只归一数据侧大小写（`ApiKey` 漏脱敏）。两者都是对外 public 的脱敏 API，出错方向恰好是「日志中断」或「密钥入日志」，都属于不能容忍的失败方向。
3. **`TodoFunction` 一整组工具在当前仓库里不可用**：`TodoFinder` 无实现（调用必抛 `BeanException`）、`predecessor` 字段因命名不一致被静默丢弃、列表不渲染状态、也没有任何用例覆盖。这一组要么补齐实现与文档前置条件，要么从内置工具里摘掉，不适合维持「注册得上但用不了」的中间状态。

TLS 全量 `TrustAll`（本部分 1 处，模块内共 7 处）属于模块级设计取舍，安全影响明确（Bearer 密钥可被中间人截获），建议单独立项由用户决定是加配置开关还是保留现状并记入 `known-limitations`。

存量缺陷共 17 条（9 一般 + 8 轻微），是否纳入修复待用户决定；本轮未发现阻塞级的严重缺陷。性能相关的 4 条方案与 4 条假设均无基线数据，不进 `tasks.md`，下一轮补 `cjprof`/`cjpm bench` 后再判。

## 范围外提示（不计入统计）

- `README_en.md:496` 的 skills 说明缺 `executeNow(skills:)` 与计划 JSON `"skills"`（`README.md:500` 有），属中英不同步，归 README 所在部分。
- `f_llm/src/store/MemoryKinds.cj:21-32` 的类注释仍写「预定义 7 值 / 预定义 7 种补种」，实际已是 9 个；源码注释漂移，归 src 部分。
- `f_llm/src/store/Stores.cj:31-32` 的 `DEFAULT_CONTENT='postgres'` / `DEFAULT_META='postgres'` 与 `StoreSettings.cj:39-40` 的 `f_hydra` / `f_store` 冲突，且全仓无引用（对外可达 `public`，不算死代码）；两份默认值并存容易误导读者，归 src 部分。
