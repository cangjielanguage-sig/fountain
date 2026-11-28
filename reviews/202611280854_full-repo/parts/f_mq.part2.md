# f_mq 模块审查报告（模块第 2/6 部分）

- **审查日期**：2026-11-28
- **模块路径**：`f_mq`（本部分 11 个文件：`.cj` 0 个 / `.md` 11 个）
- **本部分范围**：`f_mq/doc/spec/fix-fmq-full-audit/**`（client/protocol delta、tasks、tracking、verify-report）与 `f_mq/doc/spec/fix-fmq-postfix-audit/**`（design、proposal、client/protocol delta、tasks、verify-report）
- **基线**：工作区快照（`sts/1.3.x`，未对照远端目标分支）；本部分文件均已在 `db241d0ee9` / `70f734b2e1` 提交，`git status` 干净，blame 即当前内容
- **审查重点**：消息队列投递/确认语义、重复与丢失、无界队列 OOM、大粒度锁与并发串行、死代码、重复逻辑、存量 BUG（本部分全部为规格/台账文档，因此以「规格承诺 ↔ 实现」与「规格/台账自洽」为取证主线）
- **报告版本**：v1（子轮分报告，仅统计本部分）

## 发现

### [一般][存量] 客户端配置缺失的异常类型写成 `MQConfigException`，该类型在本模块不存在

- **位置**：`f_mq/doc/spec/fix-fmq-postfix-audit/specs/f-mq/client/spec.md:186`、`:199`
- **来源**：存量（`git blame -L 185,190` → `70f734b2e1` 2026-10-22「归档 fix-fmq-postfix-audit 规格」，文档随归档一并引入）
- **判据**：review-checklist §13（API / 错误类型与源码不符）；§11（契约与实现不符）
- **证据**：静态确定 —— ① 实现抛的是 `MQConnectionException`：`f_mq/src/client/MQClientConfig.cj:34`、`:38`；② `f_mq` 只有三种异常：`MQException` / `MQConnectionException` / `MQServiceException`（`f_mq/src/exception/MQException.cj:25,42,63`），全模块无 `MQConfigException`；③ 全仓 `MQConfigException` 只存在于服务端模块 `fmq/src/config/MQConfig.cj:26`（`f_mq` 是被依赖的下层库，不能反向依赖 `fmq`）；④ 用例断言的就是 `MQConnectionException`（`f_mq/src/client/MQClientConfig_test.cj:56,70,79`）；⑤ 同一 capability 的上一份 delta 写的是 `MQConnectionException`（`f_mq/doc/spec/fix-fmq-full-audit/specs/f-mq/client/spec.md:8-9`、`:19`）
- **描述**：后一份 delta 的 MODIFIED「客户端配置与节点表」把「配置缺失 / 非法地址」的异常类型改成 `MQConfigException`，并给出独立 Scenario（`:196-199`）。按此规格写 `catch (e: MQConfigException)` 的客户端代码直接编译失败；按 `:185-186` 理解「可能是任一异常」则会把连接期异常与配置期异常混为一类。规格与实现、与上一份 delta 三方不一致。
- **建议**：把 `:186` 改为 `MQConnectionException`（沿用 full-audit delta 的收敛结论），或明确写「服务端模块的 `MQConfigException` 与客户端无关」；`:199` 的 THEN 同步改为 `MQConnectionException`，并保留「文案含配置键名」这一已被用例保护的断言（`MQClientConfig_test.cj:59`）。

### [一般][存量] 协议错误码表停在 11，实现已有 12（`INVALID_TAGS`），且「每个码可达」场景写死 0–11

- **位置**：`f_mq/doc/spec/fix-fmq-full-audit/specs/f-mq/protocol/spec.md:116-129`（表）、`:141-144`（可达性场景）
- **来源**：存量（`git blame -L 141,144` → `db241d0ee9` 2026-10-21）
- **判据**：review-checklist §14.1（承诺表与实现不一致，缺项）；§13（对外契约数值表与源码不符）
- **证据**：静态确定 —— 源码有 13 个码值 0–12（`f_mq/src/base/MQConstants.cj:24-37`，`INVALID_TAGS = 12`，`:63` 有对应文案），生产路径在 `fmq/src/server/MQCommandExecutor.cj:317` 产生该码；规格表只列到 `INTERNAL = 11`（`:129`），场景断言「遍历 0–11 … 均能找到构造该码的非测试代码路径」（`:143-144`）——即使照场景逐条执行，也无法发现第 13 个码。
- **描述**：这是一条对外协议契约表（规格自称「数值是对外契约，不得漂移」，`MQConstants.cj:21`）。下游按表实现错误分支时，收到 `code == 12` 会落到「未知错误码」兜底，tags 非法这一可判定原因失去可区分性。注意与第 1 部分的 README 错误码表缺项同源（`f_mq/README.md:83`），本条针对规格表本身。
- **建议**：表内补 `| 12 | INVALID_TAGS | 发布/订阅 tags 非法（服务端权威校验） |`；可达性场景改为「遍历 `MQErrorCode` 的全部常量，而不是字面量 0–11」，避免下次新增码再次漏检。

### [一般][存量] 退订契约的正文与场景互斥：正文要求「本地不存在的 id 抛异常」，场景要求「第二次退订不抛」

- **位置**：`f_mq/doc/spec/fix-fmq-full-audit/specs/f-mq/client/spec.md:202`（正文）与 `:207-210`（Scenario 退订幂等）
- **来源**：存量（`git blame -L 200,210` → `db241d0ee9` 2026-10-21，两段由同一提交写入，属当时的自相矛盾，不是后续漂移）
- **判据**：review-checklist §11（契约与实现不符）、§13（规格内部不一致）
- **证据**：静态确定 —— 实现把「已退订」与「从未订阅」分开：`retired` 命中返回成功空操作，未命中抛 `MQServiceException(SUBSCRIBE_NOT_EXIST)`（`f_mq/src/client/MQClient.cj:381-392`，`retired` 定义见 `MQRetiredSubscriptions.cj:38-60`）。因此 `:207-210` 的场景成立（第二次退订时本地已无该订阅 → 走 `retired` → 不抛），而 `:202` 的「对本地不存在的 id SHALL 抛」在第二次退订这一情形下不成立。后一份 delta 已按实现重写（`fix-fmq-postfix-audit/specs/f-mq/client/spec.md:120-139`），但该归档 delta 未改，读者仍会读到两个相反结论。
- **描述**：这是本轮「重复与丢失 / 确认语义」在文档侧的典型表现：退订是 at-least-once 重试的常见动作，规格给出相反答案会让调用方在「重试是否安全」上做错判断——按正文实现会在超时重试时抛异常并触发上层误告警，按场景实现又不满足正文。
- **建议**：`:202` 改为「从未订阅过的 id SHALL 抛 `MQServiceException(SUBSCRIBE_NOT_EXIST)` 且不发请求；已成功退订过的 id 再退订 SHALL 成功返回且不发请求（有界 `retired` 集合，见 postfix delta）」。或直接在该行加「已被 postfix delta 取代」的指向说明，避免两套契约并存。

### [轻微][存量] tags 长度上限在两份 delta 里一个写「字符」一个写「字节」，实现按字节

- **位置**：`f_mq/doc/spec/fix-fmq-full-audit/specs/f-mq/client/spec.md:67`（「单个超过 128 字符」）与 `f_mq/doc/spec/fix-fmq-postfix-audit/specs/f-mq/protocol/spec.md:59`（「单条 tag ≤ 128 字节」）
- **来源**：存量（`fix-fmq-full-audit/.../client/spec.md` 属 `db241d0ee9`；postfix delta 属 `70f734b2e1`）
- **判据**：review-checklist §13（文档参数与源码不一致）、§2（只改口径的重复陈述造成漂移）
- **证据**：静态确定 —— `MQTags.isValid` 用 `tag.size > MAX_LENGTH` 判长度（`f_mq/src/base/MQTags.cj:34`），`String.size` 是 UTF-8 字节数；常量语义在源码注释里写的是「每个 1..128 字节」（`MQTags.cj:21`）、`MAX_LENGTH = 128`（`:27`）。
- **描述**：对纯 ASCII tags 两者等价，对中文 tags 差异显著：42 个汉字（126 字节）合法，43 个汉字（129 字节）被拒；而按「128 字符」理解，100 个汉字也应通过。使用者按旧 delta 设计 tag 会在运行期拿到 `MQException("invalid tags …")`。
- **建议**：把 full-audit delta 的 `:67` 统一为「单个超过 128 字节（UTF-8）」，并在两份 delta 都注明 `MQTags.MAX_LENGTH` 以字节计。

### [轻微][存量] 同一 Requirement 内「两种 kind」与「三种 kind」两个场景并存

- **位置**：`f_mq/doc/spec/fix-fmq-full-audit/specs/f-mq/protocol/spec.md:87-91`（两种）与 `:93-98`（三种）
- **来源**：存量（同一提交 `db241d0ee9`）
- **判据**：review-checklist §1（被实现抛弃的不可达描述，属文档层死文本）、§13（规格自相矛盾）
- **证据**：静态确定 —— `MQInternalKind` 只有 `META_SYNC` / `BACKUP` / `STATS` 三个常量（`f_mq/src/base/MQConstants.cj:79-83`），用例亦只断言三值（`MQErrorCode_test.cj:56-58`）；后一份 delta 已删除「两种 kind」并明文要求「规格 MUST NOT 保留『两种 kind』表述」（`fix-fmq-postfix-audit/specs/f-mq/protocol/spec.md:122`）。
- **描述**：两个场景紧邻、覆盖同一 Requirement，一个说两种一个说三种，实现只支持三种。归档目录保留原文有明确允许（`postfix-audit/tasks.md:332`「历史 change 归档目录可保留原文」），但同一需求块内并列两个互斥场景不属「保留原文」，而是当时就没收敛。
- **建议**：删除 `:87-91`；若需保留历史痕迹，移到文件末尾的「历史片段」小节并标注失效原因，不与现行场景并列。

### [轻微][存量] 「未知 internal kind 归为 `Unknown`」与实现不符，实际是 `Internal` + 服务端 `ERROR(INTERNAL)`

- **位置**：`f_mq/doc/spec/fix-fmq-postfix-audit/specs/f-mq/protocol/spec.md:129-132`
- **来源**：存量（`70f734b2e1`）
- **判据**：review-checklist §13（文档描述的行为与实现相反）、§11（契约与实现不符）
- **证据**：静态确定 —— `MQProtocol.kindOf` 对任何 `MQInternalMessage` 一律返回 `MQPayloadKind.Internal`，不检查 `kind` 字段（`f_mq/src/base/MQProtocol.cj:129-139`）；`asInternal` 同样只做类型判定（`:214-224`）。未知 kind 由服务端在命令层拒绝：`envelope.kind != META_SYNC` → `ERROR(INTERNAL, "unsupported internal kind …")`（`fmq/src/server/MQCommandExecutor.cj:150-151`）。
- **描述**：场景断言「未知 kind 归为 `Unknown`」，若服务端按此思路只处理 `Unknown` 分支，真实流量下未知 kind 会带着 `Internal` 分类进入正常分支，靠命令层的兜底才能挡住。此处「分类层」与「命令层」的职责在规格里被合并描述。
- **建议**：把该句改为「未知 kind 仍分类为 `Internal`，由命令层回 `ERROR(INTERNAL)`」，或让 `kindOf` 对未知 kind 真的返回 `Unknown` 并补用例（二者选一，需同步 `MQCommandExecutor` 的拒绝路径）。

### [轻微][存量] `verify-report` 的 C1 证据与本文件同提交的台账互斥：称 `tasks.md:303` 未勾选，实际已勾选

- **位置**：`f_mq/doc/spec/fix-fmq-full-audit/verify-report.md:52-57`（C1）
- **来源**：存量（`git blame` 显示 `verify-report.md:52-55` 与 `tasks.md:303` 同为 `db241d0ee9`，即写入时即已矛盾）
- **判据**：review-checklist §13（文档陈述与事实不符）、§14（台账不真实）
- **证据**：静态确定 —— `tasks.md:303` 当前为 `- [x] 31.4 按类型分组提交；按用户确认合回 sts/1.3.x（--no-ff，合并不进 master），提交 789f1349`；同一文件 `:339`（V11）又写「仍未做：31.4 合并回 `master`」。也就是说「已合回 `sts/1.3.x`」与「未合并」两种说法在台账内并存，而 C1 引用的「未勾选」在两者中都不成立（git blame 证明该行自写入起就是 `[x]`）。
- **描述**：C1 是这份 verify 报告唯一的 CRITICAL（「不可归档」的唯一依据）。依据本身不成立或至少表述错误，归档门禁的结论缺少可复核证据；后续读者无法判断到底合没合、合到哪个分支。
- **建议**：把 C1 的证据改为「31.4 已合回 `sts/1.3.x`（`789f1349`），未合 `master` 属既定约定」并重判；同时把 V11 的「合并回 master」改为「合并回 `sts/1.3.x`」，或明确写「不合 master 为策略而非未完成」。

### [轻微][存量] 两份 verify 报告引用已迁出 `openspec/changes` 的路径，读者按路径取不到文件

- **位置**：`f_mq/doc/spec/fix-fmq-full-audit/verify-report.md:82`、`:86`（`openspec/changes/fix-fmq-full-audit/design.md:255-265`）；`f_mq/doc/spec/fix-fmq-postfix-audit/verify-report.md:14-16`（以 `openspec status/validate/instructions --change …` 作为验证手段）
- **来源**：存量（`db241d0ee9` / `70f734b2e1`）
- **判据**：review-checklist §13（链接 / 路径失效）
- **证据**：静态确定 —— `openspec/changes/` 现存只有 `add-f-a2a/` 与 `archive/`（其中 5 个 11-20 的变更），`fix-fmq-full-audit` / `fix-fmq-postfix-audit` 已迁到 `f_mq/doc/spec/`（`find f_mq/doc -type f` 可见 `doc/spec/fix-fmq-full-audit/design.md` 等）；因此 `:82`/`:86` 指的文件存在但路径错，postfix 报告里的 `openspec …` 命令对这两个变更已不可复现。
- **描述**：不影响运行行为，但让这两份 verify 报告的「证据可复核」属性失效——这正是 reviewer 要求「报告写完再自查」的对象类型。
- **建议**：路径改为 `f_mq/doc/spec/fix-fmq-full-audit/design.md:255-265`；postfix 报告注明「验证时变更位于 `openspec/changes/`，归档后迁至 `f_mq/doc/spec/`，CLI 命令不再适用」。
- **附**：`tasks.md:12`、`tracking.md:3` 引用的 `reviews/202610210648_fmq-f_mq-full-audit/todo.md` 与 `reviews/202610211902_fmq-postfix-audit/todo.md` 均已核对存在，不属此项。

### [轻微][存量] 用例总数在验收清单与收尾记录之间不一致（375 / 376）

- **位置**：`f_mq/doc/spec/fix-fmq-postfix-audit/tasks.md:352`（376）与 `:380`（V56 记 `149/375/21`）；`:394`（V68）又记 376
- **来源**：存量（均为 `70f734b2e1`）
- **判据**：review-checklist §13（文档过期 / 数值不一致）
- **证据**：静态确定 —— 同一文件的验收清单说 `fmq` 376 例，V56 行说 375，V68 行说 376。前一份 verify 报告已把「375」作为 SUGGESTION 提出（`fix-fmq-postfix-audit/verify-report.md:88`），实际只改了一处。
- **描述**：用例数是这批变更「先红后绿」的唯一量化证据，三个数字并存会让回归基线不可用（后续轮次引用哪个都对不上）。
- **建议**：统一为 376（或按最后一次实跑结果统一），并说明 V56 那次 375 是同一提交内的一次中途计数。

> 存量缺陷合计 9 条（一般 3 / 轻微 6），是否纳入修复待用户决定。
>
> **范围外提示**：`f_mq/doc/spec/fix-fmq-full-audit/design.md:277`（§3.7 第 2 步）仍写「`length == 0` → 立即停止」，而实现已按后一轮规格改为「零长度即损坏」（`fmq/src/queue/QueueLog.cj:384-386`）；该文件不在本部分清单，仅记一句。

## 优化可行性方案

本部分 11 个文件全部是规格 / 台账 / 校验报告，不含运行时代码，没有可测量的 CPU、堆内存或 local mode 改造对象，故本部分 0 条方案。

文档层面的可维护性改进（已在上面按缺陷记录，不重复计入优化）：

- 两份 delta 各自完整复述同一 Requirement，已经产生 2 处实质漂移（异常类型、tags 长度单位）。若后续还有第 3、4 份 delta，建议后一份只写 `ADDED` 与差异化的 `MODIFIED` 段落，被取代的正文用 `REMOVED` 显式撤下，避免同一契约出现 3 个版本。

## 待验证假设

本部分无运行时代码，不存在「热点 / 瓶颈 / 收益」类待测假设，故 0 条。规格中出现的定时与退避常量（`CONSUME_POLL_INTERVAL = 200ms`、`200ms × 2^(n-1)` 上限 5s）与实现一致（`f_mq/src/client/MQClient.cj:43`、`MQNodePool.cj:36-37,137-147`），不构成性能结论。

## 文件覆盖

| # | 文件 | 类型 | 已读 | 说明 |
| --- | --- | --- | --- | --- |
| 1 | `f_mq/doc/spec/fix-fmq-full-audit/specs/f-mq/client/spec.md` | .md | ✅ | 6 条 MODIFIED/ADDED 需求逐条对源码核对；见 §11 退订矛盾、tags 字符/字节 |
| 2 | `f_mq/doc/spec/fix-fmq-full-audit/specs/f-mq/protocol/spec.md` | .md | ✅ | 错误码表缺 12；「两种/三种 kind」并存 |
| 3 | `f_mq/doc/spec/fix-fmq-full-audit/tasks.md` | .md | ✅ | 31.4 勾选与 V11 表述冲突（见 C1 条目） |
| 4 | `f_mq/doc/spec/fix-fmq-full-audit/tracking.md` | .md | ✅ | 75 项状态与 11 个严重项用例锚点逐条抽查，锚点均存在（`Protocol_test.messageIdFormatsTimestampInUtc` 在 `f_protocol`） |
| 5 | `f_mq/doc/spec/fix-fmq-full-audit/verify-report.md` | .md | ✅ | C1 证据失效；`openspec/changes/**` 路径已迁移 |
| 6 | `f_mq/doc/spec/fix-fmq-postfix-audit/design.md` | .md | ✅ | §3.1–§3.6 方案逐条对实现抽查（`readPayload`、`startPositionOf`、`effectiveMaxRecord`、`sink`/`Failure`）均已在位；W2/W 建议项已收敛 |
| 7 | `f_mq/doc/spec/fix-fmq-postfix-audit/proposal.md` | .md | ✅ | R1–R5 映射表与 `tasks.md` 编号对齐，无悬空落点 |
| 8 | `f_mq/doc/spec/fix-fmq-postfix-audit/specs/f-mq/client/spec.md` | .md | ✅ | 见 `MQConfigException` 条；退订 `retired` 语义与实现一致 |
| 9 | `f_mq/doc/spec/fix-fmq-postfix-audit/specs/f-mq/protocol/spec.md` | .md | ✅ | 见「未知 kind 归为 Unknown」条；tags 字节口径与实现一致 |
| 10 | `f_mq/doc/spec/fix-fmq-postfix-audit/tasks.md` | .md | ✅ | 218 项勾选抽查；用例数 375/376 不一致 |
| 11 | `f_mq/doc/spec/fix-fmq-postfix-audit/verify-report.md` | .md | ✅ | 3 WARNING + 4 SUGGESTION 逐条回查：W2（`design.md` 可达性表述）与 S2/S3/S4 已修，W1/W3 涉及文件不在本部分 |

合计：`.cj` 0 个 / `.md` 11 个 / 共 11 个，全部读完。

## 覆盖自检

| 维度 | 命中 | 未命中时的说明 |
| --- | --- | --- |
| 正确性 / 设计 / 语言特性 / 可读性 / 安全性 | 0 | 本部分无 `.cj`；这五个维度以「规格承诺是否成立」的形式折算到 §11/§13/§14 行，不重复计数 |
| §1 死代码 | 1 | 文档无 `private`/`internal` 符号可搜，改按「被实现抛弃的描述」判定：逐条比对 `MQInternalKind` 三常量、五个 `metaSync` 重载、错误码常量后，命中「两种 kind」场景（见对应条目）；其余 9 处需求块无失效描述 |
| §2 重复逻辑 | 0 | 已两两比对 4 份 delta 的 Requirement 清单（client 6 条、protocol 8 条），两份 delta 复述同一 Requirement 属 delta 机制本身；其产生的 2 处实质漂移（异常类型、tags 单位）已按缺陷单列，不另计 |
| §3 空实现 | 0 | 逐个核对规格承诺的实现落点：`readPayload`（`MQProtocol.cj:158`）、`rollback`（`MQClient.cj:185`）、`retired`（`MQRetiredSubscriptions.cj:30`）、`effectiveMaxRecord`（`QueueLog.cj:55`）、13 步 `closeSteps`（`MQServer.cj:206-232`）均在位，无「承诺但为空」 |
| §4 栈溢出 | 0 | 文档不承载递归；`readPayload` 的 `DataAny` 单层解包（`MQProtocol.cj:165`）是唯一的自我调用，深度由 `DataAny` 嵌套层数决定，无文档级风险 |
| §5 OOM | 0 | 规格对无界结构有明确上界并与实现一致：`retired` 4096 FIFO（`MQRetiredSubscriptions.cj:29`、postfix delta `:121-124`）、记录 64 MiB 与 `effectiveMaxRecord`（`QueueLog.cj:48,66-71`）、`aliveNodes` 不预判（`MQNodePool.cj:172-177`） |
| §6.1 热点瓶颈 | 0 | 无 profile / bench 数据；本部分文件不含可测函数，相关信号已转入上一行 §5 与 .cj 子轮 |
| §6.2 大粒度锁 | 0 | 规格要求「建连 MUST NOT 长时间持有全局锁」与实现一致（每节点锁 `MQNodePool.cj:97-134`，入口/锁内双检 `:90,99`）；无文档级缺陷 |
| §6.3 并发串行 | 0 | 规格的 200ms 轮询与逐节点轮转（`MQClient.cj:226-231,298`）为设计选择，无证据表明串行段占比异常；不构成结论 |
| §6.4 低效算法 | 0 | 文档层无可判定对象（`retired` 的 `remove(at: 0)` 在 `.cj` 子轮，本部分不计） |
| §7 降堆内存方案 | 0 | 本部分无运行时对象；`MQBlob`/`retired` 等堆占用属 `.cj` 文件范围 |
| §8 降 CPU 方案 | 0 | 同上，且无前后对照数据 |
| §9 local mode 可行性 | 0 | 本部分无函数内临时大对象；规格未涉及 local mode |
| §11 现有代码的 BUG（存量） | 2 | 命中「退订正文与场景互斥」「未知 kind 归类与实现不符」；另核对了 publish/consume/ack 的失败分类、`NOT_OWNER` 契约、`ACK_UNKNOWN` 视为成功、退避常量，均与实现一致 |
| §12 并发安全与锁粒度 | 0 | 已核对客户端的 4 条并发承诺：按位置原子认领（`addIfAbsent`，`MQClient.cj:250-253`）、close 幂等且清空订阅（`:422-437`）、`clientOf` 锁内复核（`MQNodePool.cj:97-101`）、投递映射键含 `queueIndex`（`MQSubscription.cj:48-50`），无文档级缺失 |
| §14 功能完备性与 README 覆盖 | 1 | 命中错误码表缺 `INVALID_TAGS=12`（对外契约表不完备）；五个 `metaSync` 重载、`delayingMs` 具名参数、`MQMetaSnapshot` 字段删除等承诺均有实现落点（`MQProtocol.cj:76-103`、`MQTopicMeta.cj:33`、`MQTopicAssignment.cj:43`） |
| 文件覆盖（§13 等） | 5/11 | §13 命中 5 处（异常类型、tags 单位、C1 证据、失效路径、用例数）；11 个文件全部读完，无未读项 |

## 模块统计

| 严重程度 | 数量 |
| --- | --- |
| 严重 | 0 |
| 一般 | 3 |
| 轻微 | 6 |
| 优化方案（堆内存 / CPU） | 0 / 0 |

## 总评

本部分 11 个文件是 `f_mq` 两轮审计（full-audit、postfix-audit）的规格、台账与校验记录，不含运行时代码，因此没有投递/确认语义、无界队列、锁粒度这一层的实现缺陷可判——这些需要 `.cj` 子轮。就文档而言，质量明显好于一般规格集：五份 delta 的需求几乎都能一一落到具体函数（`readPayload`、`startPositionOf`、`effectiveMaxRecord`、`Failure` 四分类、13 步 `closeSteps`），宣称「已删除」的符号（`isGroup`、`SegmentMissingException`、`openFrom`、`countAll`、`tombstoneFloor`、`hasLocalQueues`）逐个 grep 均为 0 命中，用例锚点抽查也真实存在。

风险集中在三处，均非阻塞：

1. **同一契约出现两个版本**：postfix delta 把客户端配置异常写成不存在的 `MQConfigException`，与实现和上一份 delta 三方相反；tags 上限在「字符 / 字节」之间摇摆。这两处都是「复述式 MODIFIED」的副作用，后续若再加 delta，建议只写差异。
2. **对外错误码表停在 11**：实现已有 12（`INVALID_TAGS`），规格的「每个码可达」场景又写死 0–11，新增码永远不会被这条场景发现。这是对外契约面唯一实质缺项，应最先补。
3. **台账自证不可复核**：full-audit 的 C1 引用了与自己同提交、却与实际内容相反的证据（`tasks.md:303` 已勾选），加上用例数 375/376 并存、verify 报告指向已迁出的 `openspec/changes/**`，会让归档门禁的判断失去依据。

以上 9 条全部为存量文档缺陷，建议按「错误码表 → 异常类型 → 退订契约」顺序排期修复；`INVALID_TAGS` 一条与第 1 部分的 README 缺项同源，合并修一次即可。
