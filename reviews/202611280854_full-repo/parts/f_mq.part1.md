# f_mq 模块审查报告（模块第 1/6 部分）

- **审查日期**：2026-11-28
- **模块路径**：`f_mq`（本部分 15 个 `.md`；模块整体 61 个 `.cj` + 36 个 `.md`）
- **基线**：工作区快照（sts/1.3.x 工作区，未对照远端目标分支，无 diff 基线）
- **审查重点**：本部分文件全部为文档（README / README_en / `doc/spec/**`），因此专项落在 §13 文档一致性、§14 功能完备性与 README 覆盖、§2 重复描述；投递/确认语义、重复与丢失、OOM、锁粒度、并发串行等代码专项在本部分无源文件可审，只作为「文档承诺是否与实现一致」的核对基准，代码侧结论归第 3–6 部分
- **报告版本**：v1（模块第 1/6 部分，仅覆盖 `files/f_mq.part1.txt` 的 15 个文件，供主 Agent 合并）

## 发现

### [一般][存量] 错误码契约在 README 中不完整：缺 `INVALID_TAGS=12`，且本地校验失败并不携带错误码

- **位置**：`f_mq/README.md:83`（错误码表 0–11）、`f_mq/README.md:117`（tags 行写 `INVALID_TAGS`）、`f_mq/README_en.md:97`、`f_mq/README_en.md:134`
- **来源**：存量（快照模式无基线；`git log -S "INVALID_TAGS"` 显示该常量与 README 表格是不同轮次加入）
- **判据**：review-checklist §13「API / 配置 / 默认值与源码不符」、§14.2「公开 API 未文档化」；README 自述「`MQErrorCode` 的数值是对外契约」（`README.md:81`）
- **证据**：静态确定 —— 源码有 13 个码值（`f_mq/src/base/MQConstants.cj:24-37`，其中 `INVALID_TAGS = 12`），README 表格只列到 11（`README.md:96` 是 `INTERNAL=11`）；同一份 README 的长度限制表却已经在用 `INVALID_TAGS`（`README.md:117`）。另外本地校验的实际抛法是 `MQException("invalid topic …")` / `MQException("invalid tags …")`，不带 `code`（`f_mq/src/client/MQClient.cj:73-78`、`:130-138`），而长度表把本地失败也标注成 `INVALID_TOPIC` / `INVALID_GROUP` / `INVALID_TAGS`（`README.md:115-117`），只有 `MQServiceException` 才有 `code`（`f_mq/src/exception/MQException.cj:63-69`）
- **描述**：调用方按 README 写的「数值即契约」去分支 `MQServiceException.code` 时，会漏掉 12；去接 `INVALID_TOPIC` 时拿到的是无码 `MQException`，分支永远不命中。tags 非法是**服务端**权威校验才回 12（`fmq/src/server/MQCommandExecutor.cj:317`），发布/订阅的本地校验只抛无码异常，两处语义在文档里被混成同一个码。
- **建议**：错误码表补 `12 | INVALID_TAGS | 订阅/发布 tags 非法`；长度限制表把本地项改成「本地抛 `MQException`（文案含 `invalid topic` 等），服务端权威校验回 `INVALID_TOPIC` / `INVALID_GROUP` / `INVALID_TAGS`」，或在源码给本地失败也构造 `MQServiceException(code)`（需评估与「服务端错误才带码」的既有约定冲突）。

### [一般][存量] README 未记录 `consume` / `publish` 的「服务端确定拒绝」出口

- **位置**：`f_mq/README.md:62`（「`consume` 阻塞直到取到消息」）、`f_mq/README.md:60`（publish 只写「全部节点不可达时抛 `MQConnectionException`」）、`f_mq/README_en.md:64`、`f_mq/README_en.md:62`
- **来源**：存量（快照模式无基线）
- **判据**：review-checklist §13「文档承诺与实现相反 / 示例跑不通」、§14.1「承诺了但没实现」的反向——实现有出口但文档未承诺
- **证据**：静态确定 —— ① 服务端在游标越过不可评估 BODY 的记录时抛 `MQServiceException(FILTER_UNSUPPORTED_BODY)`（`fmq/src/server/ConsumeService.cj:88-98`），executor 把它转成 `ERROR(10)`（`fmq/src/server/MQCommandExecutor.cj:90-94`），客户端对任意 `ERROR` 一律抛 `MQServiceException`（`f_mq/src/client/MQClient.cj:234-237`）；② 全部候选节点都回 `NOT_OWNER` 时客户端抛 `MQServiceException(8)` 而不是连接异常（`f_mq/src/client/MQClient.cj:109-112`），该分支在 README 的客户端 API 段落没有出现；③ `consume` 遇 `SUBSCRIBE_NOT_EXIST` 也直接抛（同 `:234-237`），README 只在 `unsubscribe` 段落提了这个码
- **描述**：按 README 写的 `while` 消费循环不捕 `MQServiceException` 时，一条不可评估 BODY 的记录会让消费线程直接崩出循环；按 README「全部不可达 → `MQConnectionException`」做重试分类的调用方会把 `NOT_OWNER`（配置/路由错误，重试无用）当成网络抖动无限重试。这与本轮重点「投递语义、重复与丢失」直接相关：文档没有告诉使用者该位置已被跳过、不会再投递。
- **建议**：客户端 API 段落补两条明确契约：`consume` 在 `FILTER_UNSUPPORTED_BODY` 时抛 `MQServiceException(10)` 且该位置已越过（不重复投递）；`publish` 在全部节点 `NOT_OWNER` 时抛 `MQServiceException(8)`。README_en 同步。

### [一般][存量] README「其他公开 API」自述是未展开声明的清单，实际漏 6 个 public 类型与 17 个 public 成员

- **位置**：`f_mq/README.md:157-174`、`f_mq/README_en.md:183-200`
- **来源**：存量（快照模式无基线）
- **判据**：review-checklist §14.2「公开 API 未文档化」；README 该节导语自述「以下声明未在上文展开，按模块级 / 类型分组列出」（`README.md:159`）
- **证据**：静态确定 —— 逐个对照 `src/` 的 public 顶层声明：清单外的 public 类型有 `MQConfigKey`（`src/base/MQConstants.cj:74`）、`MQBytes`（`src/base/MQMessageRecord.cj:195`）、`MQMessage`（`src/base/model/MQMessage.cj:28`，只在 `consume` 返回类型处出现，`get<T>()` 与 `queueIndex/segmentedIndex/segmentedOffset` 无说明）、`MQTopicMeta`（`src/base/model/MQTopicMeta.cj:23`）、`MQSubscribeGroupMeta`（`src/base/model/MQSubscribeGroupMeta.cj:23`）、`MQClientConfig`（`src/client/MQClientConfig.cj:27`）；清单外的 public 成员至少有 `MQProtocol.publish/subscribe/unsubscribe/consume/ack/asRecord/asPayload/asInternal/asResult/asConsumeResult`（`src/base/MQProtocol.cj:34-106`、`:145`、`:210-240`）、`MQMessageRecord.topic/tags/body/publishTime`（`src/base/MQMessageRecord.cj:77-141`）、`MQFilter.path`（`src/base/MQFilter.cj:52`）、`MQBlob.size/toData`（`src/base/payload/MQBlob.cj:48`、`:62`）
- **描述**：这是一份「兜底清单」，读者会把它当完整索引。`MQClientConfig.hosts` 是客户端唯一的配置入口，`MQMessage.get<T>()` 是消费端唯一取 BODY 的手段，两者都不在清单里，按文档只能靠读源码。
- **建议**：补齐上述类型与成员（`MQMessage`、`MQClientConfig`、`MQConfigKey` 建议各给一小段语义说明，而不是只列名字）；或在导语里改成「仅列常用项，完整 API 见 `src/`」，避免「完整清单」的暗示。README_en 同步。

### [一般][存量] 归档 delta spec 自相矛盾：consume 的位置仍写成两字段，与同一变更的 C1 修复（queueIndex）冲突

- **位置**：`f_mq/doc/spec/add-fmq-message-queue/specs/f-mq/client/spec.md:94-102`（要求「填入 `segmentedIndex` / `segmentedOffset`」，场景写 `MQConsumeResult{7, 128, record}` → 位置 `(7, 128)`）
- **来源**：存量（快照模式无基线）
- **判据**：review-checklist §13「规格与实现漂移」、§2「字面量复制导致的实现漂移」；同一变更内的 §13.1 C1（`doc/spec/add-fmq-message-queue/design.md:543-551`）与 `verify-report.md:58` 明确要求 client spec 的「deliveries 键与 ack 路由带 queueIndex」
- **证据**：静态确定 —— 同一变更的 protocol delta 已把响应改成四字段（`specs/f-mq/protocol/spec.md:120-124`「`MQConsumeResult{queueIndex, segmentedIndex, segmentedOffset, record}`」），任务 10.1/10.2 也按四字段勾选（`tasks.md:116-117`），但 client delta 的消费 Requirement 与场景没跟着改；三处对同一结构的描述不一致，client delta 的示例在当前实现下根本构造不出来（`MQConsumeResult` 构造函数首参已是 `queueIndex`，见 `src/base/payload/MQConsumeResult.cj`）
- **描述**：这条 delta 是被 C1 判定为「误确认 / 丢消息」的那个缺陷的原始规格。后来的人只要照 client delta 实现或补测试，就会重新引入「位置不含队列身份」的写法；而按归档文档「自洽性」标准，同一变更内部已经不自洽。
- **建议**：把 client delta 的消费 Requirement 与场景改成四字段（位置 = `(queueIndex, segmentedIndex, segmentedOffset)`），场景示例补 `queueIndex`；顺带核对 `specs/f-mq/client/spec.md` 里 `ack` 场景（`:121-133`）已带 `queueIndex`，保持同一口径。

### [一般][存量] `mqClient_hosts` 的空项被静默丢弃，与「存在非法项即构造失败」的规格相反

- **位置**：`f_mq/doc/spec/add-fmq-message-queue/specs/f-mq/client/spec.md:21-24`（场景：端口缺失/为 0/越界/**或为空串** → 解析为 `None`，构造失败）；`f_mq/README.md:33-34`、`f_mq/README_en.md:36-38`（缺失、为空或存在非法项即抛 `MQConnectionException`）
- **来源**：存量（快照模式无基线）
- **判据**：review-checklist §13「文档承诺与实现不一致」、§11「契约与实现不符」
- **证据**：静态确定 —— `MQClientConfig.hosts` 用 `Config.getStringArray`（`src/client/MQClientConfig.cj:32`），后者以 `x.split(delim, removeEmpty: true)` 切分（`f_config/src/Config.cj:210-217`），因此 `"h1:1,,h2:2"` 或 `"h1:1,"` 的空项在进入 `MQHost.parseHost` 前就被删掉；`parseHost` 对空串返回 `None` 的分支（`src/base/MQHost.cj:27-30`）在配置路径上永远走不到
- **描述**：配置里多写一个逗号、或节点下线后把某一项清空，客户端都会**静默**少一个节点，只在后续 `MQConnectionException`/`NOT_OWNER` 里间接暴露，与规格承诺的「构造期快速失败」相反。影响面：配置错误定位成本，不涉及数据正确性。
- **建议**：`MQClientConfig.hosts` 改为按 `,` 手工切分（保留空项）或在 `getStringArray` 后校验原始串（例如比较 `split` 前后段数），空项按非法项抛 `MQConnectionException`；若确认「允许空项」是期望行为，则改规格与 README 文案。

### [轻微][存量] `fix-fmq-full-audit/design.md` 的 `MQBlob` 契约与实现不一致（`DataNone`、`fromData` 签名、转换标志）

- **位置**：`f_mq/doc/spec/fix-fmq-full-audit/design.md:66-76`（支持矩阵：`DataNone` → 空 `MQBlob`）、`:59`（`fromData(data: Data): ?Array<Byte>`）、`:393-394`（「转换从 `SILENCE` 改为 `DEFAULT_DATA_FLAG`」）
- **来源**：存量（快照模式无基线）
- **判据**：review-checklist §13「规格与实现漂移」
- **证据**：静态确定 —— 实现里 `DataNone` 返回 `None<MQBlob>`，并明确注释「缺字段不是『没有消息』」（`src/base/payload/MQBlob.cj:82-83`）；`fromData` 的签名是 `fromData(data: Data, flag: DataConversionFlag): Any`（`:88`）；对象目标的转换标志用 `0`（不忽略任何字段问题）而不是 `DEFAULT_DATA_FLAG`（`src/base/MQProtocol.cj:174-180`）
- **描述**：「`DataNone` → 空 blob」与实现的「`DataNone` → `None`」是两种相反的语义：前者会把「载荷缺失」当成「空记录」，正是本变更要消灭的「大消息被误判为空」同类问题。文档写反了，会让后续维护者按文档改回缺陷行为。
- **建议**：把支持矩阵改成 `DataNone → None<MQBlob>` 并注明理由；`fromData` 签名与 `flag` 参数按实际补全；§4.1 的转换标志描述改成「对象目标用 `0`，标量沿用默认标志」。

### [轻微][存量] README 把 internal / 不可见符号当作对外可用的规则与上限依据

- **位置**：`f_mq/README.md:115`（`MQChars.isBlankOrControl`）、`f_mq/README.md:118`（`QueueLog.MAX_RECORD_SIZE`、`QueueLog.effectiveMaxRecord`）；`f_mq/README_en.md:132`、`f_mq/README_en.md:135`
- **来源**：存量（快照模式无基线）
- **判据**：review-checklist §13「文档 / 示例引用了不存在的 API」、§14.2「公开 API 与内部实现的边界」
- **证据**：静态确定 —— `MQChars` 是 `internal class`（`src/base/MQChars.cj:26`）；`QueueLog.MAX_RECORD_SIZE` 是包内 `static let`（`fmq/src/queue/QueueLog.cj:48`），`effectiveMaxRecord` 是 `private let` 实例字段（同文件 `:55`）。三者在模块外都不可引用
- **描述**：README 用「即 `QueueLog.effectiveMaxRecord`」这种写法给出上限口径，读者无法据此在代码里断言或计算上限，只能反推「段容量 - 4 字节」。规则本身没错，错在把内部符号当契约。
- **建议**：改成文字口径（「段容量减 4 字节长度头，再与 64 MiB 取小」）并说明上限由服务端在写入前拒绝、客户端无法本地预判；字符规则直接描述「控制字符与 Unicode 空白」而不点名 `MQChars`。

## 优化可行性方案

本部分文件全部是文档，没有可执行的堆内存 / CPU 改造对象，故本节为空（0 条堆内存 / 0 条 CPU）。文档里出现的性能表述已在「待验证假设」中登记，未作为方案。

## 待验证假设

| # | 假设 | 位置 | 缺什么数据 | 怎么采 |
| --- | --- | --- | --- | --- |
| 1 | `stats` 的 `backlog/lag` 在超大积压时会明显变慢（文档自述「超大积压时 stats 会变慢，属已知取舍」，未给量级） | `f_mq/doc/spec/add-fmq-metrics-and-delay/design.md:56-57`；实现入口 `fmq/src/server/ConsumeService.cj` 的 stats 组装 | backlog 条数 → 查询耗时的曲线；是否阻塞同组消费 | 造 10 万 / 100 万条积压，`cjpm bench -O2` 或分段计时跑 `fmq manager stats`，同时观察 `GroupCursor` 锁等待；按 §6.1 要求给函数自耗时占比 |

## 文件覆盖

| # | 文件 | 类型 | 已读 | 说明 |
| --- | --- | --- | --- | --- |
| 1 | `f_mq/README.md` | .md | ✅ | 与实现基本一致；错误码表与 API 清单见发现 1/2/3，内部符号见发现 7 |
| 2 | `f_mq/README_en.md` | .md | ✅ | 与中文版逐节对照：章节、示例、错误码表、限制表一一对应，仅条目顺序不同（en 把 unsubscribe 放在 publish 之后）；上述问题同样存在 |
| 3 | `f_mq/doc/spec/add-fmq-message-queue/design.md` | .md | ✅ | 归档实现级设计；§13 记录了 C1–C3/W1–W3 修复，与源码一致（`deliveries` 键含 `queueIndex`、三态 filter、段失效恢复） |
| 4 | `f_mq/doc/spec/add-fmq-message-queue/proposal.md` | .md | ✅ | 变更范围与 `cjpm.toml` 依赖、`f_io` 可见性前置事实均与当前仓库相符 |
| 5 | `f_mq/doc/spec/add-fmq-message-queue/specs/f-mq/client/spec.md` | .md | ✅ | 见发现 4（consume 位置缺 `queueIndex`）、发现 5（空项校验） |
| 6 | `f_mq/doc/spec/add-fmq-message-queue/specs/f-mq/protocol/spec.md` | .md | ✅ | 错误码表 0–11 为当时快照；`respondEmpty` 已被后续 `fix-fmq-postfix-audit` 移除（`git log -S` 确认），按归档变更的自洽性标准不计缺陷 |
| 7 | `f_mq/doc/spec/add-fmq-message-queue/tasks.md` | .md | ✅ | 96 项全勾选；11.x / 12.x 台账与 `fix-fmq-full-audit` 对应关系可核对 |
| 8 | `f_mq/doc/spec/add-fmq-message-queue/verify-report.md` | .md | ✅ | C1–C3 / W1–W3 与 design、tasks 一致 |
| 9 | `f_mq/doc/spec/add-fmq-metrics-and-delay/design.md` | .md | ✅ | 指标口径、TSV 行格式（10 字段）、延迟判定与实现一致；`publishTime` 的 UTC 化在后续 A02 改为字段重建，属后续变更，不计漂移 |
| 10 | `f_mq/doc/spec/add-fmq-metrics-and-delay/proposal.md` | .md | ✅ | 影响面清单与 `src/` 实际改动对应 |
| 11 | `f_mq/doc/spec/add-fmq-metrics-and-delay/specs/f-mq/protocol/spec.md` | .md | ✅ | `delayingMs`、`publishTime`、`stats` 三条 Requirement 与实现一致 |
| 12 | `f_mq/doc/spec/add-fmq-metrics-and-delay/tasks.md` | .md | ✅ | 50 项（与 verify-report「50/50」一致）；编号从 1.3 跳到 1.5，属笔误级 |
| 13 | `f_mq/doc/spec/add-fmq-metrics-and-delay/verify-report.md` | .md | ✅ | 实跑基线与 tasks 一致；7 条 warning 的处置可回溯 |
| 14 | `f_mq/doc/spec/fix-fmq-full-audit/design.md` | .md | ✅ | A01–A75 的技术方案；`MQBlob` 契约见发现 6，其余（连接退避、UTC、墓碑、段长度上界）与实现一致 |
| 15 | `f_mq/doc/spec/fix-fmq-full-audit/proposal.md` | .md | ✅ | 75 项映射表完整；兼容性口径（`MQBlob` 不改线格式、`MessageID` UTC 为 BREAKING）与实现一致 |

合计：`.cj` 0 个 / `.md` 15 个 / 共 15 个，全部读完。

## 覆盖自检

| 维度 | 命中 | 未命中时的说明 |
| --- | --- | --- |
| 正确性 / 设计 / 语言特性 / 可读性 / 安全性 | 5 | 本部分无 `.cj`，无运行时正确性与语言特性可判；按「文档承诺 ↔ 实现」核对，命中 5 条契约类问题（发现 1–5）。安全性：文档未泄漏凭据、未出现完整报文示例 |
| §1 死代码 | 0 | 本部分全为 `.md`，不含声明，`private`/`internal`/`protected`/`public` 的引用搜索不适用；为取证阅读的 `src/` 文件归属第 3–6 部分，本部分不计。已确认文档未引用「已删除的 public 符号」以外的不可达描述（`respondEmpty` 属后续变更删除，已核对 `git log -S`） |
| §2 重复逻辑 | 1 | 已把 15 份文档里同一语义的多处描述两两比对（错误码表 3 处、记录四段布局 3 处、consume 位置 5 处、`delaying` 定义 3 处）。命中 1 处：consume 位置的三元组在 README、design、两份 spec 各写一遍，其中 client spec 漏 `queueIndex`，即发现 4；其余重复描述结论一致，不另计 |
| §3 空实现 | 0 | 文档无函数体；已核对「承诺但没实现」的入口（`respondEmpty` 已由后续变更显式删除并记录在 `fix-fmq-postfix-audit`），无失踪能力 |
| §4 栈溢出 | 0 | 无递归代码；文档未描述递归结构。`MQMessageRecord.decode` 是顺序解码、`DataPath` 求值深度不在本部分范围 |
| §5 OOM | 0 | 文档中与内存相关的承诺（`MQBlob` 大载荷、`MAX_RECORD_SIZE=64 MiB`、退订 id 集合 4096 上限）与实现一致，无「无界容器被写成有界」的情况。客户端投递映射 `deliveries` 无界属源码问题，已记入「范围外提示」 |
| §6.1 热点瓶颈 | 0 | 无 profile / bench 数据；文档自述的 `stats` 扫描开销已进「待验证假设」#1，不构成发现 |
| §6.2 大粒度锁 | 0 | 本部分无锁代码；设计文档记载的锁结构（`MetaStore` Mutex、每 `GroupCursor` 一把锁、节点池每节点一把锁）与实现一致，锁粒度判定归第 3–6 部分 |
| §6.3 并发串行 | 0 | 同上；`MQClient.consume` 单线程阻塞轮询是设计选择（`design.md` R4），文档已写明，不属文档缺陷 |
| §6.4 低效算法 | 0 | 文档未承诺复杂度；唯一相关表述（`stats` 单趟扫描替代 `O(G×N)`）与实现一致 |
| §7 降堆内存方案 | 0 | 文档类文件无持有对象，不产出堆内存方案 |
| §8 降 CPU 方案 | 0 | 同上；无基线，不产出 CPU 方案 |
| §9 local mode 可行性 | 0 | 本部分无函数内临时对象；模块也未见 local mode 编译开关（`cjpm.toml` 无 `--enable-local-mode`），改造无对象 |
| §11 现有代码的 BUG（存量） | 5 | 本部分无源码，§11 以「文档声称的行为 vs 源码实际行为」取证：发现 1–5 全部为存量契约类偏差（本地校验无码、错误出口未文档化、空项被静默丢弃等），位置均给到源码行 |
| §12 并发安全与锁粒度 | 0 | 文档未对 `MQClient` 声明超出实现的线程安全承诺：client spec「并发安全」Requirement 与 `ConcurrentHashMap` + `addIfAbsent` 认领（`src/client/MQClient.cj:246-254`）一致；`MQRetiredSubscriptions` 的 Mutex 与文档「有界 FIFO」一致 |
| §14 功能完备性与 README 覆盖 | 3 | 发现 3（public 类型/成员未覆盖，6 个类型 + 17 个成员）、发现 1（错误码未覆盖）、发现 2（错误出口未覆盖）。承诺源均为 `README.md` 自身章节，缺失证据为 `src/` 符号搜索；模块未进根 `README.md` 模块表的问题不存在（`README.md:476-480` 已登记） |
| 文件覆盖（§13 等） | 15/15 | 与 `files/f_mq.part1.txt` 逐行一致，无缺读 |

## 模块统计

| 严重程度 | 数量 |
| --- | --- |
| 严重 | 0 |
| 一般 | 5 |
| 轻微 | 2 |
| 优化方案（堆内存 / CPU） | 0 / 0 |

存量 7 条（全部为存量，本部分无「本次改动」），是否纳入修复待用户决定；本报告不替用户拍板。

## 总评

本部分 15 份文档的质量高于一般仓库：`doc/spec/**` 把「为什么这么定」「失败语义表」「边界清单」都写进了设计，且每条严重问题都有对应的 verify 记录与任务编号，可回溯性很好；README 中英文内容等价，没有整节缺失。

主要风险集中在**文档与代码的接缝处**，且都在对外契约面：错误码表少一个码、本地校验与「带码异常」的语义被混写、`consume`/`publish` 的失败出口只写了一半、公开 API 兜底清单实际漏了 6 个类型。这些不会让服务崩溃，但会让调用方按文档写出错误的错误分支与重试策略——尤其 `consume` 抛 `FILTER_UNSUPPORTED_BODY` 这一步直接关系到「消息是不是被静默丢掉」的认知，是本部分最该先修的一条。

第二条风险是归档 delta spec 的内部矛盾（consume 位置缺 `queueIndex`）：它记录的正是 C1 那个「多队列 ACK 串台」缺陷，规格没跟着修复走，后续照文档补测试会重新引入同样的位置口径错误。

没有阻塞项：README 与实现的核心语义（at-least-once、三元组位置、`ack` 路由、`unsubscribe` 幂等、`delaying` 队首阻塞、有界退订集合）全部与源码一致。建议按「错误码表 → 客户端失败出口 → 公开 API 清单 → client delta 补 `queueIndex`」的顺序修复，其余（`MQBlob` 契约描述、内部符号引用、任务编号跳号）可随手带上。

## 范围外提示

以下均在 `src/`、属第 3–6 部分，本部分不计入统计，仅提示：

- `MQSubscription.deliveries` 只在 `ack` 成功时删除（`src/client/MQClient.cj:326`），调用方「只消费不 ack」时按消息条数无界增长，属无界容器候选（README 只声明退订集合有界，未提这张表）。
- `MQProtocol.publish(record, id!)` 未校验 `id` 与记录内 `MESSAGE_ID` 一致（`src/base/MQProtocol.cj:34-39`），注释里已承认「不保证一致」，与 `fix-fmq-full-audit/proposal.md:79`「`publish(record, id!)` 校验」的措辞有落差。
