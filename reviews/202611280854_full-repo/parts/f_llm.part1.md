# f_llm 模块审查报告（模块第 1/25 部分）

> **本报告只覆盖 `files/f_llm.part1.txt` 的 5 个文件**：`README.md`、`README_en.md`、`doc/content-store.md`、`doc/dev-env.md`、`doc/f_llm-memory-design.md`（本部分 **0 个 `.cj`**）。`f_llm` 共 368 个 `.cj` + 112 个 `.md`，其余 `.cj` 与 `doc/f_llm.md`、`doc/known-limitations.md`、`doc/loom.md`、`doc/retrieval-eval.md`、`doc/todo.md`、`doc/spec/**` 由第 2–25 部分产出；本报告只把 `.cj` 当作"被文档声明的实现"取证，不把这些文件的缺陷计入本部分统计（见文末「范围外提示」）。

- **审查日期**：2026-11-28
- **模块路径**：`f_llm`（本部分 0 个 `.cj` + 5 个 `.md`）
- **基线**：工作区快照（`sts/1.3.x`，无 diff 可比 ⇒ 全部问题记「存量」）
- **审查重点**：LLM 客户端契约与配置（配置只在启动读一次）、流式响应与错误处理、资源与超时、死代码、重复逻辑、并发安全、存量 BUG；本部分的落点是「文档承诺的契约 vs 源码实际行为」
- **报告版本**：v1（第 1/25 部分）

## 发现

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

## 优化可行性方案

### [堆内存] 切块改为流式消费，去掉全文 Rune 缓冲

- **现状**：`KnowledgeChunker.splitImpl`（`src/store/KnowledgeChunker.cj:66-87`）为整篇文档建 `ArrayList<Rune>`（4 B/元素）+ 输出块副本，峰值 ≈ 5×内容大小；生命周期到函数返回（local 档随 region 释放，堆档等 GC）。
- **方案**：用 `content.runes()` 单趟 + 固定窗口（`Array<Rune>(maxChars + overlap)` 环形缓冲）产出块；对 >2 MiB 的输入先按 `maxChars` 的整数倍切片再拼接，保证块边界与现有实现逐字节一致。
- **预期**：峰值从 ≈5×content 降到 ≈`2 × (maxChars + overlap) × 4 B` + 已产出块总量（输出本身仍是 O(n)，但这部分本来就要落库）。量化收益需峰值内存数据。
- **代价**：块边界必须与原实现完全一致（含最后一块不足窗口、`overlap >= maxChars` 的校验时机），需要等价性用例；local 档（README:21 的卖点）可能失去存在意义，需要重新评估是否保留 local mode 编译开关。
- **验证**：同机 `-O2`，10 MB / 100 MB 文档各 10 轮，采 `getUsedHeapSize()` 峰值与 RSS，对比改前改后与块输出哈希。
- **证据状态**：`无基线（待验证，不进 tasks）`

## 待验证假设

| # | 假设 | 位置 | 缺什么数据 | 怎么采 |
| --- | --- | --- | --- | --- |
| 1 | 切块峰值内存占比高（≈5×内容），大文档是 RSS 主因 | `src/store/KnowledgeChunker.cj:66-87` | 峰值 / 稳态 RSS、块输出量 | 10 MB、100 MB 文档各跑 10 轮 `-O2`，采样 `getUsedHeapSize()` 与 RSS |
| 2 | 记忆检索的 colbert 重排每候选一次 DB 往返，是 `search` 的主要延迟 | `src/store/PostgresMemoryStore.cj:120-160`（`bound = max(topK*4, 20)`） | 单次 search 的分段耗时与 SQL 次数 | 分段计时 + `cjprof`，topK=10/50、候选 2000 条，记录 SQL 往返次数 |
| 3 | 流式 `onDelta` 每 delta 一次 JSON 解析 + 字符串拼接，GC 压力显著 | `src/llm/ChatStreamAccumulator.cj`、`src/llm/LLM.cj:236-247` | 单次会话分配量、GC 次数 | 单会话 10 万 delta，采分配量与 GC 计数 |
| 4 | `LLMConfsHolder.ensureFresh()` 每次 `candidates()` 都比一次 `MonoTime.now()`，在高 QPS 下不可忽略 | `src/llm/LLMConfsHolder.cj:111-117` | 该路径 CPU 占比 | 微基准：100 万次 `candidates()`，与去掉 `ensureFresh` 的版本对照 |
| 5 | 并发切块叠加 local region（N×8 MiB）会触发 `LocalRegionOutOfMemoryError` | `src/store/KnowledgeChunker.cj:20-36` | 并发阈值与 `cjLocalRegionMaxSize` 实际值 | 32 线程各切 2 MiB 文档，逐步加压，观察异常与 `getAllocatedLocalObjectSize()` |
| 6 | `llm_confRefreshSeconds=0` 会导致每次模型调用都 reload 配置 | `src/llm/LLMConfsHolder.cj:111-117` | 实际 reload 次数 | 设 0 后打 100 次 `chatByName`，数 `llm conf refreshed` 日志条数 |

## 文件覆盖

| # | 文件 | 类型 | 已读 | 说明 |
| --- | --- | --- | --- | --- |
| 1 | `f_llm/README.md` | .md | ✅ | 1070 行逐段读；#1–#9、#12、#13、#15–#21 的主体证据 |
| 2 | `f_llm/README_en.md` | .md | ✅ | 1061 行逐段读；与中文版逐节对照，章节与结论一致；仅 Tests 一节被压缩（丢了「断言失败照常报错」一句，见 #13）；#1–#4、#12、#13、#15–#21 的英文行号已单列 |
| 3 | `f_llm/doc/content-store.md` | .md | ✅ | 125 行；实现矩阵 / 失败矩阵 / 融合公式 / 权重 / colbert 布局逐项对照代码，命中 #7、#9、#10、#21（`degraded`） |
| 4 | `f_llm/doc/dev-env.md` | .md | ✅ | 163 行；`postgresReady()` / `mySqlReady()` 探测约定、`cjHeapSize`、`/tmp/mysql97.sock` 与仓内用例写法一致，未命中问题；本机 MySQL 版本 / socket 路径类信息无法在仓内验证，未作为缺陷（不单列假设） |
| 5 | `f_llm/doc/f_llm-memory-design.md` | .md | ✅ | 337 行；kind 体系、写入/检索、人格 13 键、提示词位置逐项对照，命中 #6、#10、#11、#21 |

合计：`.cj` 0 个 / `.md` 5 个 / 共 5 个，全部读完。

## 覆盖自检

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

## 模块统计

| 严重程度 | 数量 |
| --- | --- |
| 严重 | 2 |
| 一般 | 11 |
| 轻微 | 8 |
| 优化方案（堆内存 / CPU） | 1 / 0 |

## 总评

本部分只有文档，但它是 `f_llm` 的对外契约层，质量整体**中上**：结构清晰、中英两版基本同步、配置表 / 失败矩阵 / 数据布局 / 权重公式都写到了可核对的粒度，且多数承诺（20 张表、13 个人格、契约方法、f_store 键布局、融合权重 0.7/0.3 与 0.4/0.6、colbert 二进制格式、附件 `-2` 顺延、SKIP 约定、`textClip` 截断语义）都与实现一致——这类"逐条能落地"的文档在本仓里是加分项。

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
