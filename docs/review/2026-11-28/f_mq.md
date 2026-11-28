# f_mq 模块审查报告

- **审查日期**：2026-11-28
- **模块路径**：`f_mq`（97 个文件：61 个 .cj + 36 个 .md）
- **基线**：工作区快照（sts/1.3.x 工作区，master 同提交 120fd2542，无分支差异）
- **审查重点**：见 scope.md（正确性、死代码、重复逻辑、空实现、栈溢出、OOM、热点、并发与锁、存量 BUG、内存/CPU 优化空间、local mode 可行性、README 覆盖）
- **报告版本**：v1（由 6 个分部分报告合并：`parts/f_mq.part1..6.md`）

## 发现

<!-- 第 1 部分 -->

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

<!-- 第 2 部分 -->

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

<!-- 第 3 部分 -->

### [严重][存量] （#1）BODY 的大字节形态（>4096 的 `Array<Byte>`）在 MQ 侧未归一化：临时文件与句柄无人释放，filter 还会把它判成「不匹配」并越过

- **位置**：`f_mq/src/base/MQFilter.cj:58`（`matches` 对任意 `Data` 直接求值）；`f_mq/src/base/MQMessageRecord.cj:141`（`body()` 原样返回 `DataAny`，不做形态归一化）；文档承诺见 `f_mq/doc/详细设计.md:107`（「BODY 支持 … `Array`」）与 `:117-124`（4096 阈值只对「记录字节」说明）
- **影响路径**：`fmq/src/queue/MQMatcher.cj:106-115`（`body()` → `filter.matches(body.data)`）；`fmq/src/queue/GroupCursor.cj:327-336`（`NoMatch` 只记 DEBUG 并 `advance()`）；`f_mq/src/client/MQClient.cj:244`（客户端 `consume` 同样解出该形态）
- **来源**：存量（快照模式无基线）
- **判据**：review-checklist §11（资源不对称 / 契约与实现不符）、§5（无界增长）、§3（错误被静默折成「不匹配」）
- **证据**：静态确定 ——
  1. `f_codec/src/default/DefaultCodec.cj:994-1072`：`DataType.INPUTSTREAM` 且 `size > fileThreshold` 时写入 `/tmp/tmpFile<UUID>/` 并返回 `file.toData()`，即 `DataInputStream(File)`（`f_data/src/base/DataInputStream.cj:33-40`）；
  2. `Array<Byte>` 的 BODY 正好编码为该分支（`详细设计.md:112-116` 已说明记录层走原始字节分支），因此 BODY 长度 > 4096 时 `MQMessageRecord.decode/body` 必然产出文件形态；
  3. 全仓唯一的清理实现是 `f_mq/src/base/payload/MQBlob.cj:97-144`（`readWholeFile` 内 `close` + `removeIfExists` 文件与父目录），只用于 `MQConsumeResult.record` / `MQInternalMessage.payload` / `MQBackupPayload.records` / `MQDeadLetterMessage.record` 这些**字节字段**；`MQFilter`、`MQMatcher`、`MQConsumeResult → MQMessage` 路径上没有对应的 `close`/`removeIfExists`（`grep tmpFile|removeIfExists` 在 `f_mq/src`、`fmq/src` 非测试代码中只命中 `MQBlob.cj`）；
  4. `std.fs.File` 官方文档明示「创建的 `File` 对象会默认打开对应的文件，当使用结束后需要及时调用 `close` 函数关闭文件，否则会造成资源泄露」（`cangjie-doc/1.3.0/libs/std/fs/fs_package_api/fs_package_classes.html`，`class File` 一节）；
  5. `SubPathNode.get` 对非 `NamedData` 返回空迭代器（`f_data/src/path/SubPathNode.cj:23-29`），所以 `$.x` / `$[0]` 一类路径作用在 `DataInputStream` 上恒为空 → `MQFilter.matches` 返回 `false` → `MQMatcher` 归一为 `NoMatch` → `GroupCursor` 越过该记录。
- **描述**：BODY 为 `Array<Byte>` 且超过 4096 字节（`DefaultCodec.fileThreshold` 默认值）时，解码结果是「文件支撑的 `DataInputStream`」，而 MQ 只在记录/载荷字节字段上做了形态归一化，BODY 没做。三个后果同时成立：
  1. **句柄与磁盘泄漏**：每解一次 BODY 就新建一个 `/tmp/tmpFile<UUID>/` 与一个打开的 fd，服务端在 filter 求值后、客户端在 `consume` 后都不关闭也不删除，`/tmp` 与 fd 随消息条数无界增长（触发条件：发布 `Array<Byte>` BODY > 4096 字节，无需其它配置）；
  2. **静默丢消息**：带非空 filter 的订阅对该记录求值恒为 `false`，`GroupCursor` 直接越过，只有 DEBUG 日志与 `skippedNoMatch` 计数（`GroupCursor.cj:333`），订阅方永远看不到这条消息；
  3. **契约不符**：`MQMessage.get<Array<Byte>>()` 先取 `convert<Array<Byte>>(DataInputStream)`（`f_mq/src/base/model/MQMessage.cj:50-79`），`Array<T>.tryFromData` 无 `DataInputStream` 分支（`f_data/src/base/CollectionData.cj:78-98`），结果为空数组或 `None` —— 与文档「BODY 支持 `Array`」矛盾。已有用例只覆盖了「字节字段」（`MQBlob_test.cj:132-147`），没有覆盖「BODY 是大字节」。
- **建议**：在 BODY 边界统一形态，而不是在每个使用点各自处理：
  1. `MQMessageRecord.body()`（或新增 `MQBody` 包装，与 `MQBlob` 同构）在返回前把 `DataInputStream(File)` 读成 `Array<Byte>` 并 `close` + 删除临时文件与父目录，失败返回 `None`；
  2. `MQFilter.matches` 的返回从 `Bool` 改为三态（复用 `MQMatchResult` 的 `Match/NoMatch/Unsupported`），无法求值必须走 `Unsupported`，由 `GroupCursor` 走既有的「跳过并留痕 / 整组暂停」策略，而不是当成 `NoMatch` 越过；
  3. 补用例：`Array<Byte>` BODY 取 4096 / 4097 / 16KB 三档，断言 `get<Array<Byte>>()` 可读回、filter 求值正确、`/tmp` 无残留（复用 `MQBlob_test.countTempEntries` 的思路）。

### [一般][存量] （#2）组名长度上限（255 字节）与持久化文件名上限（255 字节）冲突：校验通过的名字写盘 `ENAMETOOLONG`

- **位置**：`f_mq/src/base/MQGroup.cj:28`（`MAX_LENGTH = 255`）、`:34`（按原始字节数比较）；文件名拼接 `fmq/src/meta/MQFileNames.cj:98-105`（`<escaped>.meta` / `<escaped>.cursor`）；写盘点 `fmq/src/meta/MetaStore.cj:260`（`writeAtomically(groupPath(...))`，位于 `synchronized(lock)` 内）
- **来源**：存量（快照模式无基线）
- **判据**：review-checklist §11（边界 / 契约与实现不符）；`详细设计.md:420` 把 255 字节写成了公开契约；`MQGroup_test.cj:64` 把「255 字节合法」固化成用例
- **证据**：静态确定（字节数推导，可按下面两种输入复算）——
  1. 纯 ASCII 且全为 `[A-Za-z0-9._-]`（`MQFileNames.isPlain` 不转义）：名字 251..255 字节 + `.meta`（5）或 `.cursor`（7）即 256..262 字节，超过 ext4/overlayfs 的 `NAME_MAX = 255`；
  2. 含多字节字符：`MQFileNames.escape` 按 **UTF-8 字节**逐个编码成 `%XX`（`MQFileNames.cj:52-67`），一个汉字 3 字节 → 9 个字符。28 个汉字（84 字节，远低于 255）转义后 252 字符 + `.meta` = 257 > 255。
  文件系统上限本身需在目标 FS 复核（WSL ext4 / 容器 overlayfs），越界后的失败形式（`File.create` 抛 `FileException` 并冒泡出 `MetaStore.registerGroup`）待实测。
- **描述**：`MQGroup.isValid` 只按原始名字的字节数判定，而真正落盘的标识是「百分号转义后的名字 + `.meta`/`.cursor` 后缀」，两者上限相同（255）却没有为转义放大与后缀预留空间。因此一批「校验合法」的组名（长 ASCII 名、约 27 个汉字以上的中文名）会在 `registerGroup` 与游标落盘（`CursorStore`/`BackupStore` 复用同一命名）时失败：注册失败、消费位点写不下去。主题名侧同源问题更宽（`详细设计.md:419` 明写「无显式长度上限」，`MQTopic.cj:25-35` 也不限长，但同样要变成目录/文件名），只是本部分未包含 `MQTopic.cj`，此处仅作同源提示。
- **建议**：把上限定义在「转义后 + 后缀」的口径上：`MAX_LENGTH` 收到 200（留 3× 放大余量）或在 `MQFileNames` 对超长名改哈希短名（保留 `unescape` 反查元数据）；`MQGroup.isValid` 改为按转义后长度判定，或提供 `MQGroup.escapedLengthOf` 供校验复用；`MQGroup_test` 的 255 字节用例改为「转义后不超限」的边界用例，并补 27/28 个汉字、251/252 字节 ASCII 两组。

### [轻微][存量] （#3）`INVALID_TAGS(12)` 未同步到设计文档错误码表与稳定性用例

- **位置**：`f_mq/doc/详细设计.md:166-181`（§3.5 表只到 `11 | INTERNAL`）；`f_mq/src/base/MQErrorCode_test.cj:25-38`（`constantsAreStable` 未断言 12）、`:43`（`for (code in 0..12)` 少一个）
- **来源**：存量
- **判据**：review-checklist §13（文档与实现不一致）、§14（公开契约覆盖）
- **证据**：静态确定 —— `MQConstants.cj:37` 已定义 `INVALID_TAGS = 12` 且 `:63` 有对应文案，`详细设计.md:415`（§5.8a）自己也引用了 `INVALID_TAGS`，但 §3.5 的错误码表缺该行；用例的 `0..12` 恰好把 12 排除在外，「文案非空且唯一」这一条对 12 从未验证。
- **描述**：错误码注释声明「数值是对外契约，不得漂移」，§3.5 是下游实现该契约的唯一表；缺 12 意味着按文档实现的第三方无法识别 `INVALID_TAGS`。测试侧同一根因导致新增码不会被发现。
- **建议**：§3.5 补 `12 | INVALID_TAGS | 订阅 tags 非法（服务端权威校验）`；用例加 `@Assert(MQErrorCode.INVALID_TAGS == 12)`，把 `0..12` 改成 `0..13`（或新增 `MQErrorCode.COUNT` 常量供用例与文档遍历）。

### [轻微][存量] （#4）`MQFilter` 非法表达式用例用 catch-all 断言，未校验异常类型

- **位置**：`f_mq/src/base/MQFilter_test.cj:109-117`
- **来源**：存量
- **判据**：review-checklist §3（静默吞异常 / 断言过宽）、§11
- **证据**：静态确定 —— `catch (_: Exception) { threw = true }` 对任何异常都算通过；而 `MQFilter.cj:31` 的契约是「非法表达式在 `compile` 抛 `DataException`」，`MQClient.subscribe` 也依赖该异常做本地快速失败（`详细设计.md:634`）。异常类型一旦退化成 `IllegalArgumentException` / 空指针，用例仍然绿。
- **建议**：`catch (e: DataException)`，并断言 `e.message` 含 `data path must be` 前缀（`f_data/src/path/DataPath.cj:77-79`）。

### [轻微][存量] （#5）`MQBlob_test` 用 `/tmp` 全目录计数做「无残留」断言，共享环境下会抖动

- **位置**：`f_mq/src/base/MQBlob_test.cj:68-80`（`countTempEntries` 遍历 `/tmp`、按 `tmpFile` 前缀计数）、`:116-122`（断言前后计数相等）
- **来源**：存量
- **判据**：review-checklist §11（测试脆弱 / 与实现无关的全局状态）
- **证据**：待确认 —— 需确认 `cjpm test` 是否并行执行用例、以及同机是否有其它进程（含其它模块的用例）在同一窗口内创建 `tmpFile*`；代码上该断言确实依赖进程外状态。
- **描述**：`DefaultCodec` 的临时目录名为 `/tmp/tmpFile<UUID>`，与本用例的计数口径完全重合；任何并发写入都会让「解 16KB 记录不产生临时文件」变成假失败。另外 `/tmp` 不存在时（Windows 侧）恒返回 0，断言退化为空断言。
- **建议**：把断言收窄到本进程创建的目录（例如记录解码前后的 `Directory.list("/tmp")` 差集里只检查 `tmpFile*` 且要求为空），或先断言 `/tmp` 存在再执行；若目标是验证「临时文件被清理」，更稳的做法是对 `MQBlob.tryFromData` 传入一个已知路径的构造样例直接验删除。

### [轻微][存量] （#6）设计文档 §4.1「顶级声明总表」漏登记 5 个 `public` 类型

- **位置**：`f_mq/doc/详细设计.md:196-229`（缺 `MQGroup`、`MQHost`、`MQTags`、`MQBackupCursor`、`MQMetaTombstone`）
- **来源**：存量
- **判据**：review-checklist §13（文档过期 / 关键段落缺失）、§14（公开 API 未文档化）
- **证据**：静态确定 —— `f_mq/src/base/MQGroup.cj:27`、`MQHost.cj:25`、`MQTags.cj:25`、`f_mq/src/base/payload/MQBackupCursor.cj:28`、`payload/MQMetaTombstone.cj:28` 均为 `public class`，且经 `f_mq/src/f_mq.cj:23-27` 的 `public import` 对外可达；§4.1 表中无对应行（`MQHost` 只在 §5.12 的代码块里出现过一次，`MQBackupCursor`/`MQMetaTombstone` 仅在 §3.3/§5.10 被按名引用）。
- **描述**：§4.1 是「顶级声明总表」，是使用者查「这个模块有什么」的入口；漏登记会让新增的公开类型只存在于正文，`f_mq` 对外能力清单与实现不同步（`MQHost` 还是 verify-followups 变更新增的公开 API）。
- **建议**：补 5 行（类别 / 意义 / 依赖）：`MQGroup`、`MQTags`、`MQHost` 归 `fountain::f_mq.base`，`MQBackupCursor`、`MQMetaTombstone` 归 `fountain::f_mq.base.payload`。

<!-- 第 4 部分 -->

### [严重][存量] 大 BODY 的临时文件清理只覆盖「字节字段」路径：`MQMessageRecord.decode` / `body()` 把文件形态原样交给上层（与第 3 部分 #1 同源，合并为一条）

- **位置**：`f_mq/src/base/MQMessageRecord.cj:69`（`decode` 把第 4 段直接包成 `DataAny(v[3])`）、`f_mq/src/base/MQMessageRecord.cj:141-146`（`body()` 同样原样返回）；唯二的清理实现 `f_mq/src/base/payload/MQBlob.cj:97-144`
- **影响路径**：`f_mq/src/client/MQClient.cj:244`（`MQMessageRecord.decode(result.record.copyBytes())`）→ `:255` `content.toMessage(...)`，之后既没有 `close()` 也没有 `removeIfExists`；服务端 `fmq/src/queue/MQMatcher.cj:110`（同源路径，已由第 3 部分登记）
- **来源**：存量 —— `git blame`：`MQMessageRecord.decode` 出自 6303d88（2026-10-18「feat(f_mq): 新增消息队列客户端与共用协议库」）；唯一清理实现 `MQBlob.readWholeFile` 出自 ed9f73c（2026-10-21「fix(f_mq): 字节字段改用 MQBlob，修复 >4096 字节记录被降级为空（A01/A07）」）——清理只加在字节字段上，记录 BODY 路径没跟着改
- **判据**：review-checklist §11（资源不对称）、§5（无界增长）、§3（错误/形态被静默折掉）
- **证据**：静态确定 ——
  1. `f_codec/src/default/DefaultCodec.cj:1000-1036`：`INPUTSTREAM` 值 `size > fileThreshold`（默认 4096）时创建 `/tmp/tmpFile<UUID>/` 并 `File.createTemp(dir)`，解码结果是 `DataInputStream(File)`（`f_data/src/base/DataInputStream.cj:20-32`）；
  2. 字节块正好编码成该形态（`f_codec/src/default/DefaultCodec.cj:542-549`：`encode(Array<Byte>)` 写 `INPUTSTREAM` 头 + 长度），所以 BODY 里任何 > 4096 字节的字节序列（直接 BODY 或对象字段）解码后都是文件形态；
  3. `DefaultCodec.release()` 只归还编码侧 `inputs`（`DefaultCodec.cj:720-726`），不删除解码产生的文件；
  4. 全仓唯一的清理在 `MQBlob.readWholeFile`（`close` + `removeIfExists(path)` + 删父目录，`MQBlob.cj:115-135`），它只被 `MQBytes.fromData`（`MQMessageRecord.cj:200-214`，作用于**整条记录字节**）与 `MQBlob.tryFromData`（作用于**声明为 `MQBlob` 的字段**）调用；`decode`/`body` 返回的 BODY 不经过这两条路径；
  5. 无兜底清理器：`grep -rn "tmpFile" f_mq/src f_codec/src f_data/src` 只命中 `DefaultCodec.cj:1022`、`:1032`（创建处）与一条测试，没有任何删除/启动扫描逻辑。
- **描述**：BODY 为大字节（> 4096）时，每解码一次记录就新建一个 `/tmp/tmpFile<UUID>/<filename>` 并保持打开，客户端 `consume` 后不关闭、不删除；按 `MQClient.cj:244` 的调用频率，`/tmp` 文件与 fd 随消费条数线性增长，直到磁盘/inode 耗尽（默认无需任何配置，发一条 5KB 字节 BODY 即触发）。同源后果「filter 判成不匹配并越过」「`MQMessage.get<Array<Byte>>()` 读成空数组/None」已由第 3 部分 #1 详述，本条只补充「记录 BODY 解码主路径」的位置与清理边界，合并时按一条计。
- **建议**：在 BODY 边界统一形态，而不是各使用点各自处理——把 `MQMessageContent.body` / `MQMessage.body` 的类型从 `DataAny` 改为 `MQBlob`（或新增同构的 `MQBody`），`decode`/`body()` 返回前就地 `MQBlob.tryFromData` 归一化（读回 + close + 删文件与父目录），失败返回 `None`；`MQMessage.get<T>` 相应支持 `MQBlob` → 字节。补用例：4096 / 4097 / 16KB 三档 BODY，断言 `get<Array<Byte>>()` 可读回且 `/tmp` 无残留。

### [一般][存量] 同一段 BODY 有两套类型闸门且结论不同：`MQMessage.get` 走 `SILENCE`（字符串可读成数字、结构漂移折成默认对象），`MQProtocol.asPayload` 走严格闸门

- **位置**：`f_mq/src/base/model/MQMessage.cj:62-88`（闸门 `:69-80`、转换 `:82` 的 `convert<T>(data)` 未传 `flag`）vs `f_mq/src/base/MQProtocol.cj:158-207`（`readPayload` 用 `flag = 0` 做对象转换，`scalarTypeMatches` 做标量闸门）
- **来源**：存量 —— `git blame`：`MQMessage.get` 主体出自 6303d88（2026-10-18），闸门所在行出自 5da7fe5（2026-10-21「fix(fmq): 内部载荷严格类型校验与 BODY 契约（A03/A04）」）——同一次严格化只改到 `MQProtocol.readPayload`，`MQMessage.get` 的 `convert<T>(data)` 没同步
- **判据**：review-checklist §2（近似重复导致行为漂移）、§11（契约与实现不符：`MQMessage.cj:54-61` 注释写「这里用严格转换把不匹配变成异常再折回 `None`（A04）」）
- **证据**：静态确定 ——
  1. `convert<T>(data)` 的默认 `flag` 是 `DEFAULT_DATA_FLAG = SILENCE`（`f_data/src/base/DataFields.cj:46`、`f_data/src/base/global_objects.cj:42-51`），因此 `convert` 在失败时走 `case _ => None`，**根本不抛异常**，注释里的「异常再折回」不成立；
  2. `SILENCE` 含 `IGNORE_FIELD_NOT_CONVERTABLE`，数值类型对 `DataString` 有正则兜底分支（`f_data/src/base/NumberData.cj:254-257` 的 `Int64` 分支：`DataString` 匹配整数正则且 `ignoreNotConvertable(flag)` → `DataReal(...).tryToInt64()`，各数值类型同构；同文件 `NumberData_test.cj:64-66` 用浮点固化了这条），于是 `MQMessage(body: DataString("42")).get<Int64>()` 返回 `Some(42)`，而 `MQProtocol.asPayload<Int64>(Message(..., DataString("42")))` 返回 `None`（`MQProtocol.cj:203-205`：`case _: DataString => stringTarget` → false）；
  3. 对象侧：同名异结构对象在严格路径返回 `None`（`MQProtocol_test.cj:287-294` 用 `DriftedMetaSyncRequest` 固化），在 `SILENCE` 路径 `DataObject.populate` 走 `case _ => target` 返回「字段全默认」实例（`f_data/src/base/DataObject.cj:194-206`）。
- **描述**：客户端取 BODY 的唯一入口（`MQMessage.get`）与服务端/内部载荷入口（`MQProtocol.asPayload`）对同一段字节给出不同结论：客户端把 `"42"` 读成 `42`、把结构漂移的对象读成字段全默认值，两端对「同一条消息的 BODY 是什么」不一致。A03/A04 的严格化只落到 `MQProtocol` 一处，`MQMessage.get` 的注释声称同样严格但实现没有走到。
- **建议**：把 `readPayload` 提升为 `fountain::f_mq.base` 内的 `internal` 共享实现，`MQMessage.get` 直接复用它（含 `scalarTypeMatches` 闸门与 `flag: 0`），删除 `MQMessage` 里的第二套闸门；补用例：`DataString("42")` 的 BODY 在两个 API 上同为 `None`，漂移对象在两个 API 上同为 `None`。

### [一般][存量] `MQTopic.isValid` 没有长度上限，而主题名 escape 后直接成为文件名（3× 放大）→ 注册时 `ENAMETOOLONG`

- **位置**：`f_mq/src/base/MQTopic.cj:25-35`（只校验非空 / `/` 前后缀 / 空段 / 空白与控制字符，无长度判定）
- **来源**：存量 —— `git blame`：`MQTopic.isValid` 整体出自 6303d88（2026-10-18「feat(f_mq): 新增消息队列客户端与共用协议库」），自引入起就没有长度判定
- **判据**：review-checklist §11（边界 / 契约与实现不符）；承诺源 `f_mq/doc/详细设计.md:419`「主题 `MQTopic` —（无显式长度上限）」、`f_mq/README.md:115`（长度限制表主题行也没有长度项）
- **证据**：静态确定（字节数可按输入复算，落盘失败形式待实测）——
  1. 主题名直接构成文件名：`fmq/src/meta/MQFileNames.cj:92-94`（`topics/${escape(topic)}.meta`），落盘点 `fmq/src/meta/MetaStore.cj:236`、`:301`；
  2. `escape` 按 UTF-8 **字节**逐字节转 `%XX`（`MQFileNames.cj:52-67`），放大 3 倍：28 个汉字 = 84 字节 → 252 字符 + `.meta`（5）= 257 > ext4/overlayfs 的 `NAME_MAX = 255`；纯 ASCII 下 250 字节主题 + 后缀即越界；
  3. 设计文档 `详细设计.md:425` 只对**组名**写了「会直接成为文件名，因此路径与转义字符必须在入口挡下」，主题同构却没写、也没校验。
- **描述**：`MQTopic.isValid` 与客户端的本地快速失败都放行任意长度的主题，服务端注册（`MetaStore` 写 `topics/<escaped>.meta`）或建目录时才失败，且失败点在深层 IO 而不是 `INVALID_TOPIC`；运维用 `fmq manager` 注册一个长中文主题即可复现。与第 3 部分 #2（组名 255 与文件名 255 冲突）同根因，本条只覆盖主题侧。
- **建议**：给 `MQTopic` 增加与 `MQFileNames` 同口径的上限（按「escape 后 + 后缀 ≤ 224」反推原始字节上限，约 70 字节），在 `isValid` 与 `MQCommandExecutor` 的权威校验里共用；或让 `MQFileNames` 对超长名改哈希短名并保留反查。补边界用例：70/71 字节 ASCII、23/24 个汉字。

### [轻微][存量] `MQProtocol.decodePayload(bytes)` 不校验「恰好用尽字节」，与同包 `MQMessageRecord.decode` 的 exact 语义相反

- **位置**：`f_mq/src/base/MQProtocol.cj:272-286`（`decodeData(ByteBuffer(bytes))` 后直接 `readPayload`）
- **来源**：存量（快照模式无基线）
- **判据**：review-checklist §1（恒真/恒假判定的对称性缺失）、§11（契约与实现不符）
- **证据**：静态确定 —— `MQMessageRecord.cj:34-35` 的类注释明确「完整性判定必须同时满足四段都解出与恰好消费完所有字节」，并在 `:176` 用 `buffer.readOffset != record.size` 落地；`MQProtocol.decodePayload` 的同一属性 `readOffset` 完全没用，尾部多余字节被静默忽略。`MQProtocol_test.cj` 也没有「多余字节」用例（对比 `MQMessageRecord_test.cj:222-226`）。
- **描述**：内部子载荷（`MQInternalMessage.payload`、`MQBackupPayload` 子载荷）在损坏/被拼接时会被当成合法载荷解码成功，坏数据进入备份与元数据路径；两套解码器对「什么算完整」口径不一。
- **建议**：`decodePayload` 内保留 `buffer` 引用并在解码后比较 `readOffset == bytes.size`，不相等返回 `None`；补一条「尾部追加 1 字节 → `None`」用例。

### [轻微][存量] 两个不可达的 `case ...: MQBlob` 分支（`tryFromData` 的每个返回都是 `?MQBlob`）

- **位置**：`f_mq/src/base/payload/MQBlob.cj:92`（`MQBlob.fromData` 的 `case x: MQBlob => x`）、`f_mq/src/base/MQMessageRecord.cj:211`（`MQBytes.fromData` 的 `case b: MQBlob => ...`）
- **来源**：存量（快照模式无基线；`MQBlob.cj:67-68` 的注释正是这两个分支的由来）
- **判据**：review-checklist §1（恒假分支）
- **证据**：静态确定 —— `MQBlob.tryFromData` 的每个 `return` 都是 `Some(...)` / `None<MQBlob>`（`MQBlob.cj:69-85`），而 `match` 的对象是 `Any`（`:88`、`MQMessageRecord.cj:205`）；`Some(x)` 装箱后不可能匹配非 `Option` 的 `case x: MQBlob`，因此两个分支恒不可达。
- **描述**：注释说明作者曾因 `Option` 推断踩坑，于是「两种形态都匹配」保平安；现在这两条分支只剩噪音，读代码时容易误以为 `tryFromData` 可能返回裸 `MQBlob`（进而影响判空逻辑的理解）。
- **建议**：把 `tryFromData` 的返回类型从 `Any` 收窄为 `?MQBlob`（接口 `FromData` 的约束允许具体化，参考 `DataFields` 里 `fromData` 的写法），然后删掉两个不可达分支；若必须保留 `Any`（接口约束），至少在分支上加注释说明不可达。

### [轻微][存量] `MQMessageRecord.cj` 有两个未使用的 import（`std.fs.*`、`std.io.SeekPosition`）

- **位置**：`f_mq/src/base/MQMessageRecord.cj:19`、`:20`
- **来源**：存量（快照模式无基线）
- **判据**：review-checklist §1（未使用的 import）
- **证据**：静态确定 —— 该文件对 `File` / `Directory` / `exists` / `SeekPosition` 零引用（`grep -n "File\|Directory\|SeekPosition\|exists(" MQMessageRecord.cj` 只命中 `:20` 这条 import 自身）；同样的 import 在 `MQBlob.cj:18-19` 才是真正被 `readWholeFile` 使用的。
- **描述**：临时文件读写逻辑搬到 `MQBlob` 后，这两个 import 没跟着删；`cjpm` 会报 unused import 警告，干扰「编译零警告」的基线。
- **建议**：删除两行 import，并在 CI 里把 unused import 当错误。

### [轻微][存量] `encode` 模板重复：`MQMessageRecord.encode` 与 `MQProtocol.encodePayload` 是同一段「取池 → 编码 → 拷贝 → 释放」的复制

- **位置**：`f_mq/src/base/MQMessageRecord.cj:39-52` 与 `f_mq/src/base/MQProtocol.cj:245-257`
- **来源**：存量（快照模式无基线）
- **判据**：review-checklist §2（表现形式不同的重复逻辑：只改了类型参数与错误文案前缀）
- **证据**：静态确定 —— 两者逐行同构：`let codec = DefaultCodec()` → `codec.encode(...)`（前者 4 段链式、后者 1 段）→ `match (codec.finish().asBytes())` → `Some(bytes) => bytes.clone()` → `None => throw IllegalArgumentException("<前缀>: codec produced no bytes")` → `finally { codec.release() }`；连「必须在 release 前拷出」的注释都是同一句（`MQMessageRecord.cj:45` / `MQProtocol.cj:250`）。差异只有文案前缀与编码段数。
- **描述**：池缓冲的「拷贝后释放」这条易错约束现在有两份拷贝，任何一侧改动（例如改成 `finish()` 之后先取长度、或错误类型换成 `CodecException`）都会漂移。二者都在同一个包内、都是 public 静态方法，抽取不违反分层。
- **建议**：抽一个包内 `internal func encodeOnce(build: (DefaultCodec) -> Unit): Array<Byte>`（或用 `Data` 参数），两处改为调用它；`MQMessageRecord.encode` 的 4 段链式调用作为 `build` 闭包传入。测试侧无需改动。

### [轻微][存量] `MQBlob.readWholeFile` 错误路径的 `close` 失败被空 `catch` 吞掉（fd 泄漏不可见）

- **位置**：`f_mq/src/base/payload/MQBlob.cj:136-143`
- **来源**：存量（快照模式无基线）
- **判据**：review-checklist §3（`catch (_: Exception) {}` 静默吞异常）、§11（资源不对称）
- **证据**：静态确定 —— 外层 `catch (_: Exception)` 已经在处理读失败，内层 `try { if (!file.isClosed()) file.close() } catch (_: Exception) {}` 把关闭失败的异常完全丢弃；同一文件在删文件/删目录失败时是有 `log.warn` 的（`:119-130`），只有关闭这条没有。
- **描述**：`close` 失败（fd 已被回收、FS 报错）时既不记录也不重试，句柄真正的泄漏点变成不可观测；排障时只能看到「消息 BODY 读不出来」，看不到 fd 状态。
- **建议**：内层 catch 补 `log.warn("cannot close decoded temp file ...: ${e.message}")`，与同函数其余清理失败的处置保持一致。

<!-- 第 5 部分 -->

### [严重] [存量] 未 ack 的投递位置永久占位：服务端重投被客户端静默跳过，`deliveries` 无上界

- **位置**：`f_mq/src/client/MQClient.cj:246-254`（认领）、`f_mq/src/client/MQClient.cj:326`（唯一移除点）、`f_mq/src/client/MQSubscription.cj:37`（容器本体）
- **来源**：存量（`git blame -L 246,254` → 89c6fd44c2 / 2026-10-21；`-L 315,326` → 89c6fd44c2 / 2026-10-21）
- **判据**：review-checklist §11（错误处理缺失 / 边界）、§5（无界容器）、§12.1（共享状态无生命周期）；契约源 `f_mq/README.md:122`「投递语义为 **at-least-once**：未确认消息在超时或服务重启后会重复投递」
- **证据**：静态确定 —— 全仓 `deliveries` 只有 5 处出现（1 行声明 `MQSubscription.cj:37`、1 行文档注释、`MQClient.cj:250/315/326` 三处代码），其中 `remove` 仅有一处，位于 ack 收到成功响应的分支（`:319-326`）；`addIfAbsent` 命中已有键时直接 `continue`（`:251`），没有任何过期、替换或容量判断。
- **描述**：`consume` 在把消息交给业务**之前**就用 `(queueIndex, segmentedIndex, segmentedOffset)` 认领（`:250`），业务侧一旦没有 ack（处理逻辑抛异常、消息被有意丢弃、ack 被放到下一轮批处理、消费者线程崩溃），该键就永久留在 map 中。服务端按 `ackTimeout` 重投同一位置后（`fmq/src/server/ConsumeService.cj:67-126`，`GroupCursor` 负责超时退回），客户端在 `:250` 命中 `Some(_)` 直接 `continue`，业务永远看不到这条消息，也就永远不会 ack —— 该位置对该订阅**永久卡死**，README:122 承诺的 at-least-once 在客户端层退化成「不投递」。同时每个被放弃的位置会永久占用一个 String 键 + 哈希节点，长时间运行（消费侧持续失败）下无界增长（§5）。注意：阻塞本身是有意的（`f_mq/src/client/test/MQClient_test.cj:530-566` 断言「另一线程必须一直被认领失败挡住」），缺的是**时间上界**——去重窗口没有边界，等价于永久去重。
- **建议**：认领时同时记时间戳（Value 改为 `(node, claimAtMs)` 或独立并行数组），为键设 TTL = 服务端 `ackTimeout` + 余量；命中已过期项时用 `add`（覆盖语义，见 `std.collection.concurrent` 文档 `collection_concurrent_class.md:1082-1097`）接管并计数 redelivery；对 `deliveries` 加容量上限（超限拒绝或告警）；命中跳过时打 DEBUG/计数器，否则线上无法区分「正常去重」与「永久丢投递」。

### [一般] [存量] 订阅的 owner 集合订阅后不再刷新：主题重分配后 `consume` 静默空转

- **位置**：`f_mq/src/client/MQClient.cj:146-181`（owners 只在订阅时算一次）、`f_mq/src/client/MQClient.cj:223-231`（只轮询 `sub.owners`）、`f_mq/src/client/MQSubscription.cj:36`（`let owners: Array<Int64>`）
- **来源**：存量（`git blame -L 178,181` → 6303d88db0 / 2026-10-18；`MQSubscription.cj:36` → 同上）
- **判据**：review-checklist §11（契约与实现不符 / 静默失效）、§12.1（有界性、可见性）
- **证据**：静态确定 —— `MQSubscription` 的 `owners` 是不可变字段且无任何 setter/替换路径（全仓搜 `owners =` 只出现在构造）；服务端 `ConsumeService.consume` 在本地没有该主题队列时返回 `None`（`fmq/src/server/ConsumeService.cj:68-71`），最终回的是**空 `MQConsumeResult`** 而不是 `NOT_OWNER`，客户端无从发现 owner 已迁移。
- **描述**：节点数变化时元数据会重算队列归属（`fmq/src/meta/MetaStore.cj:225-235` → `MQAssignment.allocate`），主题队列被分配到新节点。已有订阅仍只向老 owner 请求，收到空响应后走 `:241 continue` → `:298 sleep(200ms)`，既无异常也无日志；消息在新 owner 上持续积压，直到客户端重新 `subscribe`（换新 `subscribedId`）。对比之下 `publish` 有 `NOT_OWNER` 重试 + `ownership.invalidate`（`:96-101`）能自愈，`consume` 没有对等机制。「是否会在生产触发」取决于是否会扩缩容，触发频率待确认。
- **建议**：三条任选或组合——(1) `consume` 侧统计连续「全部 owner 空」轮数，超过阈值（或 `ownership` 条目过期）时重新解析 owner 并向新 owner 补发一次 `SUBSCRIBE`；(2) 服务端在本地无该主题队列时回 `NOT_OWNER`，客户端据此重算 owner（与 publish 对称）；(3) 至少给一条 WARN + 指标（`consumeEmptyRounds`），让「订阅空转」可观测。

### [一般] [存量] 所有权缓存过期条目只在被读到时清理，无清扫与容量上限

- **位置**：`f_mq/src/client/MQOwnershipCache.cj:37-48`（仅 `ownersOf` 命中过期项才 `remove`）、`:50-52`（`put` 无容量判断）
- **来源**：存量（`git blame -L 37,52` → 6303d88db0 / 2026-10-18）
- **判据**：review-checklist §5（缓存键无界、TTL 无淘汰）
- **证据**：静态确定 —— 过期删除只发生在「恰好又读了同一个 topic」；`invalidate` 只在 `NOT_OWNER` 与 `close` 时调用；无迭代清扫、无容量上限、无 LRU。
- **描述**：客户端每发布一个新 topic 就留一条 `(String key, Array<Int64>, DateTime)`。topic 名由调用方传入（只校验格式与长度，`MQTopic.isValid`），若命名带租户/业务维度，条目在 TTL 到期后仍常驻到该 topic 下次被读为止，内存随历史 topic 基数单调增长。影响规模取决于 topic 基数（待确认），不影响正确性。
- **建议**：加容量上限 + LRU 淘汰，或 `put` 时按计数器每 N 次做一次采样清扫（遍历 key 快照 → `ownersOf` 触发过期删除）；或改为「整表快照原子替换」（定期重建一个只含未过期条目的新 map）。

### [轻微] [存量] 多点请求逐条串行、ack 广播无提前退出

- **位置**：`f_mq/src/client/MQClient.cj:146-162`（subscribe 广播）、`:191-203`（rollback）、`:340-358`（ack 广播）、`:395-408`（unsubscribe）
- **来源**：存量（`git blame -L 146,162`、`-L 340,358` → 6303d88db0 / 89c6fd44c2，2026-10-18~21）
- **判据**：review-checklist §6.3（并发串行）、§6.4（已知成立即可提前返回）
- **证据**：静态确定（结构层面）—— 四处都是 `for (node) { transferOf(...) }` 串行，单节点超时分别为 5s（subscribe/ack/unsubscribe）与 5s（rollback 用 `ACK_TIMEOUT`），最坏耗时为 N × 超时；`:342-352` 在 `accepted = true` 之后没有 `break`，仍会向其余 owner 各发一次必然回 `ACK_UNKNOWN` 的请求。
- **描述**：N=3 且有一个节点 hung 时，`subscribe` 最坏 15s（首个请求即被一个慢节点拖住，而订阅是启动/扩缩容路径上的同步调用）；ack 广播路径在「未知来源」场景（autoAck 或重启后重投）会多发 N-1 个无意义 RTT，且每次 5s 超时时同样线性叠加。**未做任何测量，不主张端到端收益占比**。
- **建议**：fan-out 改为「先提交全部 `transfer`，再统一汇合」（`f_net` 的 `Client.transfer` 内部有 pending 表，可并发使用），保留每节点独立结果与现有错误文案；ack 广播在 `accepted` 后 `break`（语义仍是「任一节点接受即成功」）。

### [轻微] [存量] `close()` 与在途 `subscribe` 的检查-然后-写入竞态：关闭后仍可能留下本地订阅与缓存条目

- **位置**：`f_mq/src/client/MQClient.cj:129`（`ensureOpen`）→ `:179`（`subscriptions.add`）、`:422-437`（`close`）
- **来源**：存量（`git blame -L 129,129`、`-L 179,179`、`-L 422,437` → 6303d88db0 / 2026-10-18）
- **判据**：review-checklist §11（并发正确性）、§12.1（检查-然后-写入）
- **证据**：静态确定 —— `ensureOpen` 与 `subscriptions.add` 之间隔着 N 次网络往返（最长 5s/节点），`close()` 的 CAS 只保证「唯一执行一次」，不阻止已经通过 `ensureOpen` 的调用在 `close()` 返回后再写 map 与 ownership 缓存。
- **描述**：后果限于本进程：多出一条永不使用的 `MQSubscription` 与一条 ownership 条目（服务端订阅随连接关闭被释放，`ConsumeService.releaseSubscription`），不崩溃、不泄漏句柄。但它让 `close()` 之后 `subscriptions` 可能非空，与「关闭并清空订阅」的契约在时序上不一致，也让后续排障误判为「关闭后还在订阅」。
- **建议**：`subscriptions.add` 之前再检查一次 `isClosed()`，是则先 `rollback`/`unsubscribe` 已接受的节点再抛 `MQConnectionException`；或在 `close()` 内置位后做二次清空（CAS 成功线程再清一遍 map）。

### [轻微] [存量] 配置错误与服务错误统一折进 `MQConnectionException`

- **位置**：`f_mq/src/client/MQClientConfig.cj:34`、`:38`（配置缺失 / 非法 host）；`f_mq/src/client/MQClient.cj:409-415`（`failed` 里既可能是服务端 code 也可能是 timeout，统一抛 `MQConnectionException`）
- **来源**：存量（`git blame -L 32,40` → 6303d88db0 / 3856fcebda，2026-10-18）
- **判据**：review-checklist §11（语义与命名不符 / 错误分类）
- **证据**：静态确定 —— 异常层次只有 `MQException` / `MQConnectionException` / `MQServiceException`（`f_mq/src/exception/MQException.cj:25-75`），没有配置类异常。
- **描述**：永久性错误（配置缺失、`host:port` 非法、服务端返回非 `SUBSCRIBE_NOT_EXIST` 的 code）与可重试的链路错误共用同一类型，调用方无法只按类型决定「快速失败」还是「重试」，只能解析 message 文本。注：README:34 与客户端 spec 也这样写，故这是分类学问题、不是文档冲突，不阻塞。
- **建议**：新增 `MQConfigException <: MQException`（spec 里本来就用这个名字）；`unsubscribe` 的部分失败保留 `MQConnectionException`，但把纯服务端 code 的情况拆成 `MQServiceException`（调用方已有 `code` 可分支）。

### [轻微] [存量] 已退订 id 集合的 FIFO 淘汰用 `ArrayList.remove(at: 0)`

- **位置**：`f_mq/src/client/MQRetiredSubscriptions.cj:46-49`
- **来源**：存量（`git blame -L 40,53` → 6303d88db0 / 2026-10-18）
- **判据**：review-checklist §6.4（`remove(at: 0)` 当队列头 → 每次 O(n)）
- **证据**：静态确定（复杂度）；触发频率低——只有容量打满（默认 4096）后每次 `add` 才淘汰一个。
- **描述**：每次淘汰搬移 4096 个 `String` 引用；单次开销在微秒级（未实测），不影响正确性与淘汰顺序语义。属低效实现 + 轻微 CPU 浪费。
- **建议**：环形缓冲（定长数组 + head/tail 索引，满时覆盖最旧），或一次性淘汰 1/8 把搬移摊薄；两者都保持「先进先出、不刷新重复项位置」的现有语义（`:42-45`）。

### [轻微] [存量] `MQNodePool.slots` 声明为 `var` 却从不重赋值；`close()` 的 `closeLock` 与 CAS 重复互斥

- **位置**：`f_mq/src/client/MQNodePool.cj:40`、`f_mq/src/client/MQClient.cj:50` 与 `:426`
- **来源**：存量（`git blame -L 39,44` → 6303d88db0；`MQClient.cj:426` → 6303d88db0，2026-10-18）
- **判据**：review-checklist §10（语言特性 / 可读性）、§12.2（锁的必要性）
- **证据**：静态确定 —— `slots` 只做 `slots[i] = ...` 元素写入，从未整体替换；`close()` 的 `closed.compareAndSwap(false, true)` 已保证函数体只执行一次，`synchronized(closeLock)` 内没有额外的跨字段不变量需要保护。
- **描述**：`var` 让读者怀疑「数组会被整体替换」，进而怀疑元素写入与锁的对应关系（实际所有写入都在 `nodeLocks[i]` 内）；`closeLock` 给人「close 会被并发执行」的错觉，实际上永远只有一个线程进入该块。两者都是可维护性负担，无正确性影响。
- **建议**：`slots` 改 `let`；`close()` 去掉 `closeLock`（或保留但用一行注释说明「保留仅为防御未来改动」）。

### [轻微] [存量] `MQClientConfig_test` 在未保存原值的情况下先 `Config.remove`，跑完不恢复原值

- **位置**：`f_mq/src/client/MQClientConfig_test.cj:89`
- **来源**：存量（`git blame -L 86,94` → 6303d88db0 / 2026-10-18）
- **判据**：review-checklist §11（测试污染进程级状态；与「用例隔离」的约定冲突）
- **证据**：静态确定 —— `withHosts` 在 `:28` 捕获 `previous`，而 `:89` 的 `Config.remove` 发生在调用 `withHosts` **之前**，因此 `previous` 恒为 `None`，`finally` 恢复的是「不存在」。若同进程内其它用例/夹具原本设置了 `mqClient_hosts`，会被本用例永久删除。
- **描述**：该用例的目的是验证「修改前键不存在 → 结束后仍不存在」，但为了造这个前提，它在捕获原值之前就删了键，于是「恢复原值」退化成「恢复为缺失」。同文件其它四个用例（`:42`、`:51`、`:65`、`:98`）都通过 `withHosts` 正确保存并恢复了原值，只有这一个绕过了保护，属于同文件内的不一致；`Config` 是进程级共享状态，一旦有用例依赖真实配置就会莫名失败。
- **建议**：先捕获 `previous` 再 `remove`，`finally` 恢复 `previous`；或给 `withHosts` 增加一个「断言以缺失为前提」的变体，把删除与恢复放在同一作用域。

### [轻微] [存量] `rollback` / `unsubscribe` 与三处 all-unreachable 异常构造是同构样板

- **位置**：`f_mq/src/client/MQClient.cj:185-209` 与 `:393-416`（近乎逐行同构）；`:109-117`、`:281-297`、`:359-368`（三处同构的「汇总 `lastConnectionError` → 有则带 caused、无则裸抛」）
- **来源**：存量（`git blame -L 185,209` → 6303d88db0 / 2026-10-18；`:393-416` → 89c6fd44c2 / 2026-10-21）
- **判据**：review-checklist §2（表现形式不同的重复逻辑：换控制流 / 字面量复制）
- **证据**：静态确定 —— 两段 `unsubscribe` 循环的差集只有三处：遍历源（`accepted` vs `sub.owners`）、失败后的动作（返回 `Array<String>` 供拼文案 vs 直接抛）、日志措辞；其余「构造载荷 → 逐节点 transfer → `ERROR` 且非 `SUBSCRIBE_NOT_EXIST` 记失败 → timeout/rejected 记失败」完全一致。
- **描述**：同构代码的风险是漂移：例如 `:196` 对 `SUBSCRIBE_NOT_EXIST` 的豁免、`:401` 的同名豁免、`failed` 文案格式（`"${node}(timeout)"` / `"${node}(${e.message})"`）三份副本必须同步修改；改一处漏一处会直接改变回滚/退订的判定结果。三处异常构造同理，文案差异（是否带 tried nodes、是否带 caused）已出现不一致。
- **建议**：抽 `private func unsubscribeOn(nodes: Array<Int64>, id: String, action: String): Array<String>`（内部统一日志），`rollback` 与 `unsubscribe` 复用；异常构造抽 `private static func unreachable(action: String, nodes: Array<Int64>, last: ?Exception): MQConnectionException`，把现有文案差异作为参数传入（保持 A15/A16 要求的定位信息）。

### [轻微] [存量] 三个载荷类的 `Array<Byte>` 重载整体复制字段赋值

- **位置**：`f_mq/src/base/payload/MQConsumeResult.cj:36-48`、`f_mq/src/base/payload/MQDeadLetterMessage.cj:39-61`、`f_mq/src/base/payload/MQInternalMessage.cj:33-41`
- **来源**：存量（`git blame` 这三个文件均为 6303d88db0 / 2026-10-18）
- **判据**：review-checklist §2（只改一行的重复）
- **证据**：静态确定 —— 每个类的两个构造函数只差最后一个字段（`this.record = MQBlob(x)` vs `this.record = x` / `payload`），其余 5~7 行字段赋值逐行相同。
- **描述**：仓颉的 `class` 不支持构造函数互相委托（语言文档 `class_and_interface/class.md:116-135` 只定义「多个普通构造函数必须构成重载」与主构造函数，无 `this(...)` 链式调用），因此**无法**靠委托消除。真实风险是字段增删时两处不同步：漏改一处 → 某条构造路径的字段静默为默认值（这类 bug 在编解码往返时才暴露）。
- **建议**：保留一个公共构造函数 + `static func of(record: Array<Byte>): X` 工厂（调用方改为工厂），或在用例里断言两条构造路径产出的 `toData()` 逐字节一致，把「两处必须同步」变成可测约束。

<!-- 第 6 部分 -->

### [严重][存量] `deliveries` 认领永不过期：未确认的重复投递被静默丢弃，at-least-once 退化为「丢弃 + 进死信」

- **位置**：`f_mq/src/client/MQSubscription.cj:37`（`deliveries` 认领表无 TTL、无上限）、`f_mq/src/client/MQSubscription.cj:48-50`（键构造）；配合 `f_mq/src/client/MQClient.cj:246-253`（`addIfAbsent` 命中即 `continue`）、`f_mq/src/client/MQClient.cj:326`（唯一删除点）
- **来源**：存量（快照模式无基线；`git blame` 6303d88db0，2026-10-18）
- **判据**：review-checklist §11「契约与实现不符」、§12.1「异步语义（超时但任务继续跑 / 失败被静默吞掉）」、§5「无界容器」
- **证据**：静态确定 —— ①`deliveries` 的删除只有 `ack` 成功一条路径（`MQClient.cj:326`），`MQClient.cj:250` 命中已存在键时只做 `continue`，没有任何时间、次数或容量约束；②`ConcurrentHashMap.addIfAbsent` 在键已存在时不赋值并返回旧值（std `collection_concurrent_class.md:1132`「如果赋值之前 key 存在，则返回当前 key 对应的值 Some(V)，且不执行赋值操作」）；③服务端确实会重投同一位置：`fmq/src/queue/GroupCursor.cj:143` 的 `ready = !entry.delivered || current - entry.lastDeliverTime >= ackTimeout`，重投返回的仍是同一 `(seq, offset)`
- **描述**：正常路径是 `consume` 认领 → 业务处理 → `ack` 删除认领。业务处理失败（抛异常、超时放弃、主动跳过）而不 `ack` 时：服务端在 `ackTimeout` 后重投同一位置，客户端 `addIfAbsent` 再次命中 → `continue` 静默丢弃，认领永不释放。后果有三层：①`README.md:122` 承诺的「投递语义为 at-least-once：未确认消息在超时或服务重启后会重复投递」对**同一客户端实例**不成立，重投一次都到不了业务；②服务端仍按 `deliverCount` 反复重投，每次都被客户端吞掉，累计到 `deadMsgThreshold` 后由 `fmq/src/queue/GroupCursor.cj:184` 写入死信队列——本应重试成功的消息被静默推进死信，且客户端全程没有一行日志；③每条进死信的记录都永久留在 `deliveries` 里（`ack` 永远不会发生），随后端运行时间无界增长，单条约 10² B（`"q:s:o"` 字符串 + 哈希表槽），百万级死信即百 MB 量级
- **建议**：①认领带生命周期——条目改为 `(node, claimedAt)`，超过服务端 `ackTimeout`（作为客户端配置暴露）即失效并允许重新认领，或「已返回给调用方」后转为可重投状态；②加容量上限与淘汰（超过上限时按最早认领淘汰并 `warn`），避免死信记录常驻；③命中已认领位置时至少 `debug/warn` 一次计数，不要全静默；④现有用例 `MQClient_test.cj:530-566`（`sameDeliveryPositionIsClaimedOnce`）把「永久挡住」写成期望行为，需与新语义一起修改，并补一条「不 ack 的重投必须重新交付」的用例

### [轻微][存量] `MQSubscription.subscribedId` 字段从未被读取

- **位置**：`f_mq/src/client/MQSubscription.cj:32`（声明）、`41`（唯一赋值）
- **来源**：存量（`git blame` 6303d88db0）
- **判据**：review-checklist §1「无调用者 / 读了不用」——所属顶层声明是 `internal class`，对外不可达，成员在全仓无读取即死代码
- **证据**：静态确定 —— `grep -rn "\.subscribedId" f_mq/src` 只命中 `base/payload/*` 自身字段与测试、以及本文件 `41` 行的赋值；`MQClient.cj` 打印订阅 id 时用的是方法参数 `subscribedId`（`260/285/328` 等行），不是 `sub.subscribedId`
- **描述**：每个订阅多持有一个 `String` 引用且永不使用；字段存在会让人误以为 `MQSubscription` 能自描述身份，排障时容易踩空
- **建议**：删除该字段与构造参数；若确实要保留用于日志，则把 `MQClient` 的日志改用 `sub.subscribedId`，让字段真正被使用

### [轻微][存量] 测试辅助的清理入口全部未接线：日志捕获器的静态缓冲跨用例只增不减

- **位置**：`f_mq/src/client/test/LogCapture_test.cj:31-33`（`static let lines` / `pending`）、`50-54`（`take()` 只做快照，不清空）、`56-61`（`CapturingStream.clear()`）、`90-92`（`CapturingAppender.clear()` 无调用者）；`f_mq/src/client/test/MQStubServer_test.cj:110-114`（`MQStubServer.clear()` 无调用者）
- **来源**：存量（`git blame` 196824caa5 / 6303d88db0，2026-10-21 / 2026-10-18；快照模式无基线）
- **判据**：review-checklist §1「非 public 符号无调用者」、§11（测试隔离缺失导致断言可能误命中）
- **证据**：静态确定 —— `grep -rn "CapturingAppender\.\|CapturingStream\." f_mq/src` 只有 `install()` / `waitFor()` / `take()` 的调用，`clear()` 零调用；`MQStubServer.clear()` 同样零调用（`isClosed()` 是 `Resource` 接口实现，不计）
- **描述**：`lines` 是进程级静态容器，`take()` 返回副本而不消费，`clear()` 又没人调用，于是整个测试进程的日志行持续累积。`clientFailsWithPerNodeLogs`（`MQClient_test.cj:981`）与 `allNodesUnreachableThrowsConnectionException`（`213`）、`deadNodeThrows` 共用 `127.0.0.1:1`，`waitFor(["node 0", "127.0.0.1:1"])` 可能匹配到前一个用例残留的行，形成假通过
- **建议**：在 `@BeforeAll` / 每个日志断言用例开头调用 `CapturingAppender.clear()`；更稳的做法是 `waitFor` 记住起始下标，只在「本轮新增行」里匹配；`MQStubServer.clear()` 若无用途直接删除

### [轻微][存量] `MQClient_test` 硬编码 tags 边界 65 / 129，复制 `MQTags.MAX_COUNT` / `MAX_LENGTH`

- **位置**：`f_mq/src/client/test/MQClient_test.cj:96`（`Array<String>(65, repeat: "t")`）、`101`（`longText(129)`）
- **来源**：存量（`git blame` d587122f6d，2026-10-21）
- **判据**：review-checklist §2「字面量复制：同一组边界值散落多处」
- **证据**：静态确定 —— 边界定义在 `f_mq/src/base/MQTags.cj:24-25`（`MAX_COUNT = 64`、`MAX_LENGTH = 128`），`README.md:112` 也按常量名描述；测试另写一份 +1 的数值
- **描述**：常量上调时（例如 `MAX_COUNT` 改 128），`65` 变成合法值，用例从「预期 6 次本地失败」变成 5 次，失败原因指向测试而不是实现，排查成本高
- **建议**：改为 `MQTags.MAX_COUNT + 1` / `MQTags.MAX_LENGTH + 1`

### [轻微][存量] 用例用墙钟做时序断言，未使用已注入的假时钟

- **位置**：`f_mq/src/client/test/MQNodePool_test.cj:124`（`@Assert(elapsed < 300)`）、`169-184`（`failedBuildBacksOff` 依赖 200ms 退避窗口，三次调用间不得超时）
- **来源**：存量（`git blame` bc7b8eeac0，2026-10-21）
- **判据**：review-checklist §11「非确定断言」、§10 可维护性
- **证据**：需实测 —— 需在负载机上重复运行确认抖动幅度；代码层面可确定 `MQNodePool` 已支持 `nowMs` 注入（`f_mq/src/client/MQNodePool.cj:51-53`），但两个用例都没传
- **描述**：`elapsed < 300`（建连耗时含 TCP 握手）与「200ms 内不重撞」都随机器负载漂移，CI 并行跑用例时容易偶发失败，且失败信息无法区分「实现退化」与「机器慢」
- **建议**：`slowNodeDoesNotBlockOtherNodes` 改为断言「取节点 1 的调用未等待节点 0 的 build 完成」（用 `AtomicBool` 时序标记）而不是绝对耗时；`failedBuildBacksOff` 传入固定 `nowMs` 序列，把退避窗口变成确定逻辑

### [轻微][存量] 桩服务端吞掉绑定/启动异常，真实原因被覆盖成「cannot bind a free port」

- **位置**：`f_mq/src/client/test/MQStubServer_test.cj:46-56`（`catch (_: Exception) { attempt++ }` 丢弃原因）、`66-73`（`spawn { server.start {...} }` 的异常无人接收）、`77-89`（探针失败后统一抛 `did not start`）
- **来源**：存量（`git blame` 6303d88db0）
- **判据**：review-checklist §3「`catch {}` 静默吞掉异常」、§11「错误处理缺失或静默」
- **证据**：静态确定 —— 循环里捕获所有异常只做计数，`getOrThrow` 的兜底异常不带任何原始 cause；`spawn` 的 `Future` 被丢弃，`server.start` 抛错时用例只会看到 2 秒超时后的通用文案
- **描述**：端口被占以外的失败（`Server` 构造参数错误、监听权限不足）都会被重试 100 次并报成端口问题，测试排障时会往错误方向查；这是测试桩，影响面限于本模块用例
- **建议**：保存最后一次异常并作为 `MQStubException` 的 `causedBy`；只对「端口占用」类错误重试，其余立即上抛；`spawn` 的返回值保留并在 `start()` 里检查一次

## 优化可行性方案

> 不是缺陷，是「还能更好」；无基线的方案只作待验证假设，不进 tasks。

<!-- 第 1 部分 -->

本部分文件全部是文档，没有可执行的堆内存 / CPU 改造对象，故本节为空（0 条堆内存 / 0 条 CPU）。文档里出现的性能表述已在「待验证假设」中登记，未作为方案。

<!-- 第 2 部分 -->

本部分 11 个文件全部是规格 / 台账 / 校验报告，不含运行时代码，没有可测量的 CPU、堆内存或 local mode 改造对象，故本部分 0 条方案。

文档层面的可维护性改进（已在上面按缺陷记录，不重复计入优化）：

- 两份 delta 各自完整复述同一 Requirement，已经产生 2 处实质漂移（异常类型、tags 长度单位）。若后续还有第 3、4 份 delta，建议后一份只写 `ADDED` 与差异化的 `MODIFIED` 段落，被取代的正文用 `REMOVED` 显式撤下，避免同一契约出现 3 个版本。

<!-- 第 3 部分 -->

本部分（基础校验 / 过滤器 / 常量 / 文档）**没有**具备改前基线的优化项：唯一与运行期成本相关的 `MQFilter.matches` 迭代器分配缺少 profile 数据，按铁律只进「待验证假设」，不计入本节。

<!-- 第 4 部分 -->

> 不是缺陷，是「还能更好」。本部分没有任何 bench / profile 数据，下面四条全部是 `无基线（待验证）`，不进 `todo.md` / `tasks.md`。

### [堆内存] 记录解码少一次整记录拷贝：`ByteBuffer(record)` 构造即整份拷贝

- **现状**：`MQMessageRecord.decodeValues` 每次都 `ByteBuffer(record)`（`MQMessageRecord.cj:171`），而 `f_io.ByteBuffer` 的数组构造会 `Array<Byte>(array.size)` 再 `write(array)` 整份拷贝（`f_io/src/ByteBuffer.cj:34-40`）。单条记录上限 64MB（`fmq/src/queue/QueueLog.cj:48`，`MAX_RECORD_SIZE = 64 * 1024 * 1024`），因此每次解码多一份整记录副本；`decode` 1 次 + 前缀解码各 1 次（见下一条）→ 一条消息最坏 4 份。
- **方案**：给 `f_io.ByteBuffer` 增加「不拷贝的只读视图」构造（或在 `MQMessageRecord` 内按偏移顺序解析，不建 `ByteBuffer`）；更省事的一步是先让调用方改用一次 `decode()` 拿 4 段。
- **预期**：单条 64MB 记录少 64–192MB 瞬时分配；常规 1KB 记录少 3KB/条（按调用次数线性）。
- **代价**：要么新增 codec 的「零拷贝输入」入口（改 `f_codec`），要么在 MQ 侧重写解析器（与线格式耦合，风险高）；只读视图需要文档约束调用方不得写。
- **验证**：`cjprof heap` + `getAllocatedHeapSize()` 前后对照，`-O2`，固定 1KB 与 64MB 两档，各 10 万条，给中位数与离散度。
- **证据状态**：`无基线（待验证，不进 tasks）`

### [堆内存] `MQProtocol.decodePayload(MQBlob)` 的全量副本：先 `copyBytes()` 再 `ByteBuffer(bytes)` 又拷一次

- **现状**：`MQProtocol.cj:267-269` → `:272` 的 `ByteBuffer(bytes)`，一条备份批次（N 条记录，单条 ≤ 64MB）在解码期至少存在「`MQBlob` 内部数组 + `copyBytes` 副本 + `ByteBuffer` 副本」三份，解码产物（`Array<MQBlob>`）再算一份。
- **方案**：`MQBlob` 增加只读的 `func borrowBytes(): Array<Byte>`（文档声明调用方不得修改），`decodePayload(blob)` 直接传入它；进一步配合上一条的「不拷贝 `ByteBuffer`」可只剩一份。
- **预期**：备份解码峰值降约 1/2（批次维度）。
- **代价**：`borrowBytes` 暴露内部数组，任何写入都会污染 `MQBlob`（需文档 + 只用 `internal`）；若 `MQBlob` 后续要支持流式，borrow 语义要重定。
- **验证**：100 条 × 64MB 的备份批次解码，`heapUsed` 峰值 + RSS 对照。
- **证据状态**：`无基线（待验证，不进 tasks）`

### [CPU] `MQMessageRecord.publishTime` 的逐条解析开销：split + toRuneArray + 7 次 String 切片与 `Int64.parse`

- **现状**：`MQMessageRecord.cj:106-138`：1 次 `split("_")`（分配 `Array<String>` + N 个 String）、1 次 `toRuneArray()`（分配 `Array<Rune>`）、7 次 `stamp[a..b]` 切片 + `Int64.parse`——单次约 9 次分配。调用点在服务端延迟投递判定与段扫描主路径（`fmq/src/queue/QueueLog.cj:260`、`fmq/src/server/ConsumeService.cj:247`、`fmq/src/queue/GroupCursor.cj:564`）。
- **方案**：`stamp` 已逐字符校验为 23 位 ASCII 数字，直接按下标取 `stamp[i]`（或先转一次 `Array<Byte>`）累加成 `year/month/day/h/m/s/nanos`，去掉 `split`、`toRuneArray` 与 `Int64.parse`。
- **预期**：单次分配从 ~9 降到 1–2（仅 `DateTime`）；耗时降幅待测（无 profile 数据）。
- **代价**：手写字段拆分，需保留现有非法值用例（月/日越界仍由 `ofUTC` 抛错兜底，`MQMessageRecord_test.cj:177-180`）。
- **验证**：`cjpm bench -O2`，10M 次 `publishTime`，改前/改后中位数与离散度；再回服务端做一次端到端延迟对照。
- **证据状态**：`无基线（待验证，不进 tasks）`

### [CPU] 前缀解码合并：一条记录最多被顺序解码 3 次（topic / tags / body）

- **现状**：`MQMessageRecord.cj:153-158` 的注释已说明「每次调用都会从记录头顺序解码」；服务端匹配对同一 record 依次调 `topic()`（`fmq/src/queue/MQMatcher.cj:77`、`:93`）、`tags()`（`:100`）、`body()`（`:110`），因此一条记录最多 3 次全量顺序解码 + 3 次整记录拷贝。
- **方案**：匹配阶段改为一次 `decode(record)`（已有）取 4 段后传给 matcher；或新增 `decodePrefix(record, count)` 让「只要 tags」时只解 2 段。
- **预期**：匹配阶段解码次数 3 → 1（按调用次数估，端到端收益待测）。
- **代价**：改 `fmq` 侧调用方（跨模块），且要保留「topic 解不出 → 走 `MQMatcher.cj:93` 失败分支」的语义；`decode` 要求恰好用尽字节（更严格），对损坏记录的行为会从「前缀可解」变成「整体 `None」。
- **验证**：consume 稳态压测 + `cjprof record`（`MQMatcher` 自耗时占比），对比改前后吞吐与 P95。
- **证据状态**：`无基线（待验证，不进 tasks）`

<!-- 第 5 部分 -->

> 不是缺陷，是"还能更好"。四条均无改前/改后基线，仅作下一轮补数据的候选。

### [堆内存] `consume` 对每条记录先 `copyBytes()` 再解码，峰值多一份记录字节

- **现状**：`MQClient.cj:244` 调 `MQMessageRecord.decode(result.record.copyBytes())`；`MQBlob.copyBytes()`（`MQBlob.cj:58-60`）是整段 `clone()`。单条记录大小受 `QueueLog.effectiveMaxRecord` 限制（README:118），大于 4096 字节的记录在解码侧可能落临时文件（README:129-130）。每条消息在解码期间同时持有「MQBlob 内部数组」+「副本数组」+「解码出的 `Data` 树」。
- **方案**：给 `MQMessageRecord` 增加基于 `MQBlob` 的 `decode(blob: MQBlob)`，直接对内部数组构造 `ByteBuffer` 视图（`ByteBuffer(record)` 只持引用，见 `MQMessageRecord.cj:171`），或让 `decode` 接收 `Array<Byte>` 并在解码结束后立刻放弃中间数组。
- **预期**：每条消息峰值 −S 字节（S = 记录字节数），大消息场景最明显；常驻不变。
- **代价**：需把 `MQBlob` 的内部数组以包内可见方式暴露（或加 `withBytes` 回调），存在「调用方长期持有内部数组」的误用风险；`MQMessageRecord` 属第 4 部分范围，改动跨文件。
- **验证**：固定 1 MB 记录、单线程消费 N 条，对照 `getAllocatedHeapSize()` 增量与 RSS 峰值（多轮取中位数）。
- **证据状态**：`无基线（待验证，不进 tasks）`

### [堆内存] `deliveries` 用拼接字符串做键

- **现状**：`MQSubscription.keyOf`（`MQSubscription.cj:48-50`）每次投递拼一个 `"${q}:${s}:${o}"`；`MQClient.cj:247-248` 与 `:314` 各拼一次。在途条目数 = 未 ack 数（见「发现」第 1 条的无界问题）。
- **方案**：改为 `struct DeliveryKey(queueIndex, segmentedIndex, segmentedOffset) <: Hashable & Equatable`（或把三个 Int64 打包进两个 Int64 做键），`ConcurrentHashMap<DeliveryKey, Int64>`。
- **预期**：每条在途消息少一次字符串分配（约 50~60 字节 + 哈希表节点中的引用），`ack` 路径少一次拼接；命中比较由字符串比较降为整数比较。
- **代价**：新增类型与 `hashCode` 实现；日志里需要 `toString()` 还原可读位置（`"${q}:${s}:${o}"` 的文案要保留）。
- **验证**：未 ack 积压 10k 条时对比堆占用与 `ack` 单次耗时中位数。
- **证据状态**：`无基线（待验证，不进 tasks）`

### [CPU] `candidateNodesOf` 每次调用分配两个数组

- **现状**：`MQClient.cj:524-541` 先 `Array(preferred.size + all.size)` 再做前缀去重，最后 `buf[0..len]` 又复制一份（Array 切片是拷贝）；每次 `publish`（`:86`）都走一次，`candidateNodes` 还把 `aliveNodes()` 的全量下标数组也新建一遍（`MQNodePool.cj:172-177`）。
- **方案**：返回「数组 + 有效长度」二元组（或用包内 `struct NodeCandidates`），调用方按长度遍历；`aliveNodes` 在节点表不可变的前提下返回缓存的只读数组（`hosts` 构造后不变）。
- **预期**：每次 publish 少 1~2 次分配（大小 ≈ 节点数）。本部分已有的 `MQCandidateNodes_test.cj:121-152` 只对照了旧实现（`legacyAlloc > producedAlloc * 2`），没有绝对基线，无法据此给百分比。
- **代价**：调用方循环写法改动（`for (i in 0..len)`），越界风险需靠用例守住；可读性略降。
- **验证**：`F_MQ_BENCH=1` 下扩展现有 `MQ_CANDIDATE_BENCH` 埋点，另加 `cjpm bench -O2` 的 publish 吞吐对照（同机、同输入、中位数）。
- **证据状态**：`无基线（待验证，不进 tasks）`

### [CPU] `consume` 空轮询固定 200ms + 每轮 N 次请求

- **现状**：`MQClient.cj:298` 固定 `sleep(200ms)`；每轮先向 `owners` 逐个请求（`:229-231`），空队列时一轮 = N 次 RTT（`responded` 计数在 `:233`）。
- **方案**：空轮询改为有界指数退避（200ms → 1s 封顶）+ 有消息时立即复位；节点较多时先问上轮命中的 owner，命中即跳过其余节点。
- **预期**：低流量订阅的空转请求数下降（N 倍 → 1 倍量级）。属请求数减少，不等价于吞吐提升。
- **代价**：退避会拉长新消息的首次可见延迟（最坏 1s），需要按业务延迟要求定上限；语义从「固定间隔」变为「自适应」，要同步改 README:62 的描述。
- **验证**：单消费者、空队列 10 分钟，统计 CONSUME 请求数/秒与「发布→消费到」的 P95 延迟。
- **证据状态**：`无基线（待验证，不进 tasks）`

<!-- 第 6 部分 -->

> 不是缺陷，是"还能更好"。本部分只有一条候选，且无任何测量数据。

### [CPU] 位置键改为值类型，去掉每消息的字符串拼接与字符串哈希

- **现状**：`MQSubscription.keyOf`（`MQSubscription.cj:48-50`）用 `"${queueIndex}:${segmentedIndex}:${segmentedOffset}"` 生成键；非 `autoAck` 订阅每投递一条消息在 `consume` 拼一次（`MQClient.cj:247`）、`ack` 再拼一次（`MQClient.cj:314`），即每条消息 1–2 次 String 分配 + 字符数组 + 逐字符哈希，键对象在 `ack` 前一直存活
- **方案**：定义 `struct LogKey <: Hashable & Equatable { let queueIndex: Int64; let segmentedIndex: Int64; let segmentedOffset: Int64 }`，`deliveries` 改为 `ConcurrentHashMap<LogKey, Int64>`，`ack` 复用调用方已有的三个 `Int64` 直接构造（栈上值类型）
- **预期**：每条消息省 1–2 次 String 分配与字符串哈希；`deliveries` 条目由「String 头 + 字符数组 + 表槽」变为「24B 值 + 表槽」。具体降幅未测
- **代价**：`deliveries` 的泛型参数与 `keyOf` 签名变更（内部类型，无兼容负担）；日志里拼可读位置时仍需 `toString`
- **验证**：`cjpm bench -O2`，同机同 SDK，10 万条 consume+ack 各跑 5 轮取中位数；`cjprof record` 看 `String` 构造与 `hashCode` 的自耗时占比是否从热点表消失
- **证据状态**：`无基线（待验证，不进 tasks）`

## 待验证假设

<!-- 第 1 部分 -->

| # | 假设 | 位置 | 缺什么数据 | 怎么采 |
| --- | --- | --- | --- | --- |
| 1 | `stats` 的 `backlog/lag` 在超大积压时会明显变慢（文档自述「超大积压时 stats 会变慢，属已知取舍」，未给量级） | `f_mq/doc/spec/add-fmq-metrics-and-delay/design.md:56-57`；实现入口 `fmq/src/server/ConsumeService.cj` 的 stats 组装 | backlog 条数 → 查询耗时的曲线；是否阻塞同组消费 | 造 10 万 / 100 万条积压，`cjpm bench -O2` 或分段计时跑 `fmq manager stats`，同时观察 `GroupCursor` 锁等待；按 §6.1 要求给函数自耗时占比 |

<!-- 第 2 部分 -->

本部分无运行时代码，不存在「热点 / 瓶颈 / 收益」类待测假设，故 0 条。规格中出现的定时与退避常量（`CONSUME_POLL_INTERVAL = 200ms`、`200ms × 2^(n-1)` 上限 5s）与实现一致（`f_mq/src/client/MQClient.cj:43`、`MQNodePool.cj:36-37,137-147`），不构成性能结论。

<!-- 第 3 部分 -->

> 无性能数据支撑，不进 `todo.md` / `tasks.md`。

| # | 假设 | 位置 | 缺什么数据 | 怎么采 |
| --- | --- | --- | --- | --- |
| 1 | 带 filter 的消费路径每条记录都要新建一条 `DataPath.get` 迭代器链（`SingleIterable`/`OptionIterator`/`flatMap` 闭包），GC 压力随消费速率线性增长 | `f_mq/src/base/MQFilter.cj:58-73`；调用点 `fmq/src/queue/MQMatcher.cj:106-115` | 分配字节/条、self time 占比 | `cjprof record` 跑 1w 条、单订阅、filter 非空 vs 空两组；同机 `-O2`，看 `MQFilter.matches` 与 `DataPath.get` 的自耗时占比 |
| 2 | 同一记录在 filter 判定中被解析三次（`topic` / `tags` / `body` 各从头解一次，`body` 需解满 4 段） | `f_mq/src/queue/MQMatcher.cj:90-110` + `f_mq/src/base/MQMessageRecord.cj:153-185` | 单条记录解析耗时占比、每条记录的重复解码次数 | 分段计时或 `cjpm bench` 对比「一次解四段」与「三次前缀解码」 |

<!-- 第 4 部分 -->

| # | 假设 | 位置 | 缺什么数据 | 怎么采 |
| --- | --- | --- | --- | --- |
| 1 | `DefaultCodec` 的编码/解码缓冲是全局池，MQ 每次编解码都要借还，高并发下池锁成为串行段 | `f_mq/src/base/MQMessageRecord.cj:41`、`:169`；`f_mq/src/base/MQProtocol.cj:246`、`:276`；池定义 `f_codec/src/default/DefaultCodec.cj:49-53`、借池超时 `:128` | 池等待时长、BLOCKED/WAITING 线程占比、池耗尽的 `getOrThrow` 触发次数 | 32 线程持续编解码 10 分钟；线程状态采样 + 池等待计时埋点（CPU profile 看不出锁等待） |
| 2 | 每条消息 3 次全量顺序解码是 consume 路径的主要 CPU 段 | `f_mq/src/base/MQMessageRecord.cj:153-158`；调用 `fmq/src/queue/MQMatcher.cj:77/100/110` | `MQMatcher` / `decodeValues` 自耗时占比 | `cjprof record` 跑服务端 consume 稳态（1 主题 1 组 10 万条 1KB 记录） |
| 3 | `publishTime` 的 9 次分配在延迟投递判定里占比可观 | `f_mq/src/base/MQMessageRecord.cj:119-134` | 自耗时占比、GC 次数 | `cjpm bench -O2` 10M 次 + 服务端 `cjprof heap` 对照 |
| 4 | `consume` 一次只取 1 条（`once: true`），订阅吞吐上限 ≈ 1/RTT | `f_mq/src/base/MQProtocol.cj:55-57`；客户端轮询 `f_mq/src/client/MQClient.cj:229-256` | 每 RTT 消息数、P95 延迟、单订阅极限 QPS | 客户端压测：1 订阅 / 1 组 / 1 owner，记录 RTT 与 QPS 曲线；再试多 owner 分摊 |
| 5 | 大 BODY 解码峰值 ≈ 2×（64MB 记录 → ≥128MB），且随并发线性叠加 | `f_mq/src/base/MQMessageRecord.cj:171`；`f_mq/src/base/payload/MQBlob.cj:106` | `heapUsed` 峰值随并发 N 的变化 | 8 并发消费 64MB 记录，采样 `getAllocatedHeapSize()` + RSS |

<!-- 第 5 部分 -->

| # | 假设 | 位置 | 缺什么数据 | 怎么采 |
| --- | --- | --- | --- | --- |
| 1 | `candidateNodesOf` 的两次分配在 publish 总分配中占比可观 | `f_mq/src/client/MQClient.cj:524-541` | 每次 publish 的分配字节数与占比 | `cjprof record` 跑 10 万次 publish（8 节点、1KB 消息），看 `getAllocatedHeapSize()` 增量与 `candidateNodesOf` 采样 |
| 2 | `copyBytes()` 让大消息消费路径峰值翻倍 | `f_mq/src/client/MQClient.cj:244` | 峰值堆/RSS 与单条记录大小的关系 | 1MB 记录 × 1 万条，抓 `getUsedHeapSize()` 峰值与 RSS，对照去掉副本后的版本 |
| 3 | `MQNodePool` 锁内 `build()` 造成同节点请求排队 | `f_mq/src/client/MQNodePool.cj:122-133` | 锁等待时长与并发线程数（CPU profile 看不到） | 注入慢建连（`build` 钩子延迟 1s），20 线程并发 `clientOf`，抓线程状态（BLOCKED）与等待时长分布 |
| 4 | subscribe 串行 fan-out 在单节点 hung 时 P95 明显劣化 | `f_mq/src/client/MQClient.cj:146-162` | 订阅耗时 P95/P99 | 3 节点、1 节点挂起不响应，测 100 次 subscribe 的耗时分布（当前实现 vs 有界并行版本） |
| 5 | `retired` 的 `remove(at:0)` 与 `deliveries` 字符串键在实际退订/ack 频率下可忽略 | `MQRetiredSubscriptions.cj:46-49`、`MQSubscription.cj:48-50` | 单次耗时与调用频率 | 微基准：容量 4096 下连续 add 10 万次；以及 ack 10 万次的单次耗时中位数 |

<!-- 第 6 部分 -->

> 没有性能测试数据支撑的猜测。**不进 `todo.md` / `tasks.md`**，只用于下一轮补数据。

| # | 假设 | 位置 | 缺什么数据 | 怎么采 |
| --- | --- | --- | --- | --- |
| 1 | 位置键的字符串拼接 + 哈希在 consume/ack 热路径占有可观自耗时 | `f_mq/src/client/MQSubscription.cj:48`、`f_mq/src/client/MQClient.cj:247`、`314` | 自耗时占比、每条分配字节数 | `cjprof record` 跑 10 万条 consume+ack，看 `String`/`hashCode` 占比与分配量 |
| 2 | `nextStart` 的 `AtomicInt64.fetchAdd` 在 4+ 并发消费者下形成缓存行争用 | `f_mq/src/client/MQSubscription.cj:53-55` | 线程状态（BLOCKED/自旋）与单次延迟 | 4/8/16 线程各跑 10 万次 consume，采线程状态与 P99；CPU profile 看不出这类争用 |
| 3 | 若位置键改为栈上值类型（不逃逸的临时键），consume 路径可用 local mode 降峰值内存 | `f_mq/src/client/MQSubscription.cj:48` | 峰值内存对照、`getAllocatedLocalObjectSize()` | 按 `docs/LocalMode-O2-Plan.md` 的口径跑改前/改后峰值内存；当前 `keyOf` 的返回值进 `deliveries` 已逃逸，需先按优化方案 #1 改值类型键 |

## 文件覆盖

> 与 `files/f_mq.txt` 一一对应；分部分报告逐文件确认已读。

| # | 文件 | 类型 | 已读 | 说明 |
| --- | --- | --- | --- | --- |
| 1 | `f_mq/README.md` | .md | ✅ | — |
| 2 | `f_mq/README_en.md` | .md | ✅ | — |
| 3 | `f_mq/doc/spec/add-fmq-message-queue/design.md` | .md | ✅ | — |
| 4 | `f_mq/doc/spec/add-fmq-message-queue/proposal.md` | .md | ✅ | — |
| 5 | `f_mq/doc/spec/add-fmq-message-queue/specs/f-mq/client/spec.md` | .md | ✅ | — |
| 6 | `f_mq/doc/spec/add-fmq-message-queue/specs/f-mq/protocol/spec.md` | .md | ✅ | — |
| 7 | `f_mq/doc/spec/add-fmq-message-queue/tasks.md` | .md | ✅ | — |
| 8 | `f_mq/doc/spec/add-fmq-message-queue/verify-report.md` | .md | ✅ | — |
| 9 | `f_mq/doc/spec/add-fmq-metrics-and-delay/design.md` | .md | ✅ | — |
| 10 | `f_mq/doc/spec/add-fmq-metrics-and-delay/proposal.md` | .md | ✅ | — |
| 11 | `f_mq/doc/spec/add-fmq-metrics-and-delay/specs/f-mq/protocol/spec.md` | .md | ✅ | — |
| 12 | `f_mq/doc/spec/add-fmq-metrics-and-delay/tasks.md` | .md | ✅ | — |
| 13 | `f_mq/doc/spec/add-fmq-metrics-and-delay/verify-report.md` | .md | ✅ | — |
| 14 | `f_mq/doc/spec/fix-fmq-full-audit/design.md` | .md | ✅ | — |
| 15 | `f_mq/doc/spec/fix-fmq-full-audit/proposal.md` | .md | ✅ | — |
| 16 | `f_mq/doc/spec/fix-fmq-full-audit/specs/f-mq/client/spec.md` | .md | ✅ | — |
| 17 | `f_mq/doc/spec/fix-fmq-full-audit/specs/f-mq/protocol/spec.md` | .md | ✅ | — |
| 18 | `f_mq/doc/spec/fix-fmq-full-audit/tasks.md` | .md | ✅ | — |
| 19 | `f_mq/doc/spec/fix-fmq-full-audit/tracking.md` | .md | ✅ | — |
| 20 | `f_mq/doc/spec/fix-fmq-full-audit/verify-report.md` | .md | ✅ | — |
| 21 | `f_mq/doc/spec/fix-fmq-postfix-audit/design.md` | .md | ✅ | — |
| 22 | `f_mq/doc/spec/fix-fmq-postfix-audit/proposal.md` | .md | ✅ | — |
| 23 | `f_mq/doc/spec/fix-fmq-postfix-audit/specs/f-mq/client/spec.md` | .md | ✅ | — |
| 24 | `f_mq/doc/spec/fix-fmq-postfix-audit/specs/f-mq/protocol/spec.md` | .md | ✅ | — |
| 25 | `f_mq/doc/spec/fix-fmq-postfix-audit/tasks.md` | .md | ✅ | — |
| 26 | `f_mq/doc/spec/fix-fmq-postfix-audit/verify-report.md` | .md | ✅ | — |
| 27 | `f_mq/doc/spec/fix-fmq-verify-followups/design.md` | .md | ✅ | — |
| 28 | `f_mq/doc/spec/fix-fmq-verify-followups/proposal.md` | .md | ✅ | — |
| 29 | `f_mq/doc/spec/fix-fmq-verify-followups/specs/f-mq/protocol/spec.md` | .md | ✅ | — |
| 30 | `f_mq/doc/spec/fix-fmq-verify-followups/tasks.md` | .md | ✅ | — |
| 31 | `f_mq/doc/spec/fix-fmq-verify-followups/verify-report.md` | .md | ✅ | — |
| 32 | `f_mq/doc/spec/optimize-f-mq-candidate-nodes/design.md` | .md | ✅ | — |
| 33 | `f_mq/doc/spec/optimize-f-mq-candidate-nodes/proposal.md` | .md | ✅ | — |
| 34 | `f_mq/doc/spec/optimize-f-mq-candidate-nodes/tasks.md` | .md | ✅ | — |
| 35 | `f_mq/doc/开发计划.md` | .md | ✅ | — |
| 36 | `f_mq/doc/详细设计.md` | .md | ✅ | — |
| 37 | `f_mq/src/base/MQBlob_test.cj` | .cj | ✅ | — |
| 38 | `f_mq/src/base/MQChars.cj` | .cj | ✅ | — |
| 39 | `f_mq/src/base/MQConstants.cj` | .cj | ✅ | — |
| 40 | `f_mq/src/base/MQErrorCode_test.cj` | .cj | ✅ | — |
| 41 | `f_mq/src/base/MQFilter.cj` | .cj | ✅ | — |
| 42 | `f_mq/src/base/MQFilter_test.cj` | .cj | ✅ | — |
| 43 | `f_mq/src/base/MQGroup.cj` | .cj | ✅ | — |
| 44 | `f_mq/src/base/MQGroup_test.cj` | .cj | ✅ | — |
| 45 | `f_mq/src/base/MQHost.cj` | .cj | ✅ | — |
| 46 | `f_mq/src/base/MQHost_test.cj` | .cj | ✅ | — |
| 47 | `f_mq/src/base/MQMessageRecord.cj` | .cj | ✅ | — |
| 48 | `f_mq/src/base/MQMessageRecord_test.cj` | .cj | ✅ | — |
| 49 | `f_mq/src/base/MQModel_test.cj` | .cj | ✅ | — |
| 50 | `f_mq/src/base/MQPayload_test.cj` | .cj | ✅ | — |
| 51 | `f_mq/src/base/MQProtocol.cj` | .cj | ✅ | — |
| 52 | `f_mq/src/base/MQProtocol_test.cj` | .cj | ✅ | — |
| 53 | `f_mq/src/base/MQTags.cj` | .cj | ✅ | — |
| 54 | `f_mq/src/base/MQTags_test.cj` | .cj | ✅ | — |
| 55 | `f_mq/src/base/MQTestSetup_test.cj` | .cj | ✅ | — |
| 56 | `f_mq/src/base/MQTopic.cj` | .cj | ✅ | — |
| 57 | `f_mq/src/base/MQTopic_test.cj` | .cj | ✅ | — |
| 58 | `f_mq/src/base/model/MQMessage.cj` | .cj | ✅ | — |
| 59 | `f_mq/src/base/model/MQMessageContent.cj` | .cj | ✅ | — |
| 60 | `f_mq/src/base/model/MQSubscribeGroupMeta.cj` | .cj | ✅ | — |
| 61 | `f_mq/src/base/model/MQTopicMeta.cj` | .cj | ✅ | — |
| 62 | `f_mq/src/base/payload/MQAckPayload.cj` | .cj | ✅ | — |
| 63 | `f_mq/src/base/payload/MQBackupCursor.cj` | .cj | ✅ | — |
| 64 | `f_mq/src/base/payload/MQBackupPayload.cj` | .cj | ✅ | — |
| 65 | `f_mq/src/base/payload/MQBackupState.cj` | .cj | ✅ | — |
| 66 | `f_mq/src/base/payload/MQBlob.cj` | .cj | ✅ | — |
| 67 | `f_mq/src/base/payload/MQConsumePayload.cj` | .cj | ✅ | — |
| 68 | `f_mq/src/base/payload/MQConsumeResult.cj` | .cj | ✅ | — |
| 69 | `f_mq/src/base/payload/MQDeadLetterMessage.cj` | .cj | ✅ | — |
| 70 | `f_mq/src/base/payload/MQDeregisterPayload.cj` | .cj | ✅ | — |
| 71 | `f_mq/src/base/payload/MQInternalMessage.cj` | .cj | ✅ | — |
| 72 | `f_mq/src/base/payload/MQMetaSnapshot.cj` | .cj | ✅ | — |
| 73 | `f_mq/src/base/payload/MQMetaSyncRequest.cj` | .cj | ✅ | — |
| 74 | `f_mq/src/base/payload/MQMetaTombstone.cj` | .cj | ✅ | — |
| 75 | `f_mq/src/base/payload/MQResult.cj` | .cj | ✅ | — |
| 76 | `f_mq/src/base/payload/MQSubscribePayload.cj` | .cj | ✅ | — |
| 77 | `f_mq/src/base/payload/MQTopicAssignment.cj` | .cj | ✅ | — |
| 78 | `f_mq/src/base/payload/MQUnsubscribePayload.cj` | .cj | ✅ | — |
| 79 | `f_mq/src/client/MQCandidateNodes_test.cj` | .cj | ✅ | — |
| 80 | `f_mq/src/client/MQClient.cj` | .cj | ✅ | — |
| 81 | `f_mq/src/client/MQClientConfig.cj` | .cj | ✅ | — |
| 82 | `f_mq/src/client/MQClientConfig_test.cj` | .cj | ✅ | — |
| 83 | `f_mq/src/client/MQNodePool.cj` | .cj | ✅ | — |
| 84 | `f_mq/src/client/MQOwnershipCache.cj` | .cj | ✅ | — |
| 85 | `f_mq/src/client/MQOwnershipCache_test.cj` | .cj | ✅ | — |
| 86 | `f_mq/src/client/MQRetiredSubscriptions.cj` | .cj | ✅ | — |
| 87 | `f_mq/src/client/MQSubscription.cj` | .cj | ✅ | — |
| 88 | `f_mq/src/client/MQTestSetup_test.cj` | .cj | ✅ | — |
| 89 | `f_mq/src/client/test/LogCapture_test.cj` | .cj | ✅ | — |
| 90 | `f_mq/src/client/test/MQClient_test.cj` | .cj | ✅ | — |
| 91 | `f_mq/src/client/test/MQNodePool_test.cj` | .cj | ✅ | — |
| 92 | `f_mq/src/client/test/MQStubServer_test.cj` | .cj | ✅ | — |
| 93 | `f_mq/src/client/test/MQTestSetup_test.cj` | .cj | ✅ | — |
| 94 | `f_mq/src/exception/MQException.cj` | .cj | ✅ | — |
| 95 | `f_mq/src/exception/MQException_test.cj` | .cj | ✅ | — |
| 96 | `f_mq/src/f_mq.cj` | .cj | ✅ | — |
| 97 | `f_mq/src/test/Facade_test.cj` | .cj | ✅ | — |

合计：`.cj` 61 个 / `.md` 36 个 / 共 97 个，全部读完。

## 覆盖自检

### 第 1 部分

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

### 第 2 部分

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

### 第 3 部分

| 维度 | 命中 | 未命中时的说明 |
| --- | --- | --- |
| 正确性 / 设计 / 语言特性 / 可读性 / 安全性 | 2 | 正确性：BODY 大字节形态（#1）、组名长度边界（#2）。分层无违规（`base` 只依赖 `f_data`/`f_codec`，未反向依赖 `client`）；语言特性上 `?DataPath`/`Option` 匹配用得正确，`MQGroup` 用字节趟判定 4 个 ASCII 分隔符、`MQChars` 用 `runes()` 判定 Unicode 空白，两处覆盖的字符集互补且都有注释说明原因；无外部输入拼接、无凭据、无敏感日志 |
| §1 死代码 | 0 | 已逐个符号搜引用：`MQChars`（`internal`）两个静态函数均被 `MQTopic/MQTags/MQGroup` 调用；`MQFilter.path_/compiled`、`MQGroup.MAX_LENGTH`、`MQHost.parseHost` 均在用；`MQGroup`/`MQHost`/`MQFilter`/`MQErrorCode`/`MQConfigKey`/`MQInternalKind`/`MQPayloadKind` 顶层为 `public` 且经 `f_mq.cj:23-27 public import` 对外可达，不判死代码；测试内 `bytesOf`/`encodeToBytes`/`decodeFromBytes`/`blobOf`/`countTempEntries`/`fill` 均有调用；`MQBlob_test.cj:61-66` 的 `case b: MQBlob` 不是死分支（`DataFields.tryFromData` 返回 `Any`，`MQBlob.cj:66`）；无未使用 import |
| §2 重复逻辑 | 0 | 已两两比对 10 个函数体（`isBlankOrControl`/`containsBlankOrControl`/`isValid×3`/`compile`/`matches`/`messageOf`/`parseHost`/`==`/`toString`）：三个 `isValid` 的差异是业务规则（topic 要求绝对路径、group 额外禁 `/\:%` 与首尾点、tags 是数组且限条数），已把共性（空白/控制判定）抽到 `MQChars`；`parseHost` 全仓唯一实现（原 `MQClientConfig.parseHost` 已删，`MQClientConfig.cj:37` 改调 `MQHost`）；客户端与服务端各校验一次是 `详细设计.md:409-415` 明确的「本地快速失败 + 服务端权威」，不算重复 |
| §3 空实现 | 1 | `MQFilter_test.cj:109-117` 的 catch-all 断言（#4）；本部分无空函数体、无 TODO/FIXME、无 `return None` 占位 |
| §4 栈溢出 | 0 | 本部分无递归：`MQChars`/`isValid`/`parseHost`/`matches` 均为单层遍历；`DataPath` 的递归下降在 `f_data`，不在本部分 |
| §5 OOM | 1 | #1 的 `/tmp` 临时文件与 fd 随消息条数无界增长；本部分其余代码无容器累积（`MQFilter` 只持不可变的 `?DataPath` 与原始串，`DataPath.cache` 有 `maxSize: 10000`） |
| §6.1 热点瓶颈 | 0 | 未提供 profile / bench 数据，热点不成立；`MQFilter.matches` 的分配与 `MQMatcher` 的重复解码已列入待验证假设 #1/#2 |
| §6.2 大粒度锁 | 0 | 本部分无锁；`MetaStore` 的锁不在本部分文件内（仅作 #2 的写盘位置引用） |
| §6.3 并发串行 | 0 | 本部分无 `spawn`/线程池/批处理 |
| §6.4 低效算法 | 0 | 均为 O(名字长度) 的单/双趟扫描（`MQGroup` 两趟：码点趟 + 字节趟），无嵌套循环、无热点 `contains`、无 `remove(at: 0)` |
| §7 降堆内存方案 | 0 | 本部分常驻对象只有「原始 filter 串 + 编译后的 `DataPath` 引用」，无集合、无副本；`copyBytes`/`clone` 均在被调用方语义要求处（`MQBlob_test` 校验用） |
| §8 降 CPU 方案 | 0 | 无基线数据，候选全部降级为待验证假设 |
| §9 local mode 可行性 | 0 | `MQFilter.matches` 的临时迭代器不逃逸，是理论上唯一的 local 候选，但它由 `f_data` 的 `DataPath.get` 返回泛型 `Iterator<Data>`（无 `@ local!` 重载），改造要跨模块改 `f_data`，且收益只能用峰值内存证明 —— 当前无数据，不成立 |
| §11 现有代码的 BUG（存量） | 4 | #1、#2、#4、#5；其余边界已核对：`MQGroup` 空串/首尾点/超长、`MQHost` 空串/缺端口/端口 0/65536/多冒号、`MQFilter` 空串/缺失路径/`DataNone`/空容器、`MQErrorCode.messageOf` 未知码兜底，均与文档一致 |
| §12 并发安全与锁粒度 | 0 | `MQFilter` 是跨线程共享的（服务端每个订阅持一个，`MQSubscriptionView.filter`），但 `compiled`/`path_` 为 `let` 且 `DataPath` 编译后只读、`get()` 每次新建迭代器（`f_data/src/path/DataPath.cj:1002-1008`），无共享可变状态；`MQChars`/`MQGroup`/`MQHost`/`MQErrorCode` 为无状态静态函数。故本部分无线程共享可变点，无锁可谈粒度 |
| §14 功能完备性与 README 覆盖 | 1 | #6（§4.1 总表漏 5 个 public 类型）；`README.md`/`README_en.md` 不在本部分文件清单内，README 覆盖留给含 README 的子轮。本部分核对到的「承诺-实现」对：`MQHost.parseHost`、`MQFilter.compile/matches/path`、`MQMessageRecord.publishTime`、`MQProtocol.stats`、`MQGroup.MAX_LENGTH`、`MQConfigKey.CLIENT_HOSTS` 全部有实现与用例，无承诺未实现项 |
| 文件覆盖（§13 等） | 10/10 `.md` + 10/10 `.cj` | 无缺文件；本部分全部 20 个文件均逐行读完 |

### 第 4 部分

| 维度 | 命中 | 未命中时的说明 |
| --- | --- | --- |
| 正确性 / 设计 / 语言特性 / 可读性 / 安全性 | 5 | 正确性：#1 #2 #4；设计：`MQMessage` 与 `MQProtocol` 两套闸门（#2）；语言特性：`match` 的 `Option` 推断残留（#5）、`convert` 默认 `SILENCE` 的语义（#2）；可读性：#7；安全性：本部分无外部输入直接拼 SQL / 路径，`MQTopic`/`MQTags` 只做字符校验（#3 是边界而非注入） |
| §1 死代码 | 2 | 逐个符号搜引用：`MQMessageRecord.valueAt` / `decodeValues`、`MQProtocol.readPayload` / `scalarTypeMatches`、`MQBlob.readWholeFile` 均有调用者；`internal`/`protected` 符号本部分为 0；`public` 均为对外可达（`f_mq` 是库，`fmq` 服务端与下游都在用），不判。命中：`MQBlob.cj:92` + `MQMessageRecord.cj:211` 不可达分支、`MQMessageRecord.cj:19-20` 未使用 import |
| §2 重复逻辑 | 2 | 已把 20 个文件的函数体压成「输入→输出→副作用」两两比对：命中 `encode` 模板（#7）与两套类型闸门（#2）。已比对并排除：`MQModel_test.cj:43-60` 与 `MQPayload_test.cj:30-47` 的同名 `roundtrip` 辅助（测试准备代码）；`MQBackupPayload` 两个构造函数（元素类型不同，无法合并）；`MQMessageRecord.topic/tags/messageId/body` 四个前缀解码器（共用 `valueAt`，仅类型参数不同，属必要展开） |
| §3 空实现 | 1 | 无空函数体、无 `TODO`/`FIXME`、无「接口默认空实现未覆盖」；`MQProtocol_test.cj:352` 的 `set(...) {}` 是测试替身的有意 no-op。命中：`MQBlob.cj:136-143` 的空 `catch`（#8） |
| §4 栈溢出 | 0 | 唯一递归是 `MQProtocol.readPayload` 对 `DataAny` 的解包（`MQProtocol.cj:165`）与 `MQBlob.tryFromData` 对 `DataAny` 的解包（`MQBlob.cj:70`）：`DataAny` 只由进程内代码构造，编解码不会产出嵌套 `DataAny`（`DefaultCodec.cj:152` 编码时即拆包），可达深度为 1；其余全为循环 |
| §5 OOM | 1 | 全量物化路径都受硬上限约束：单条记录 ≤ 64MB（`fmq/src/queue/QueueLog.cj:48`）、单帧载荷默认 1GB（`f_protocol/src/default/ProtocolConfig.cj:32`），本部分无「随请求增长且 GC 后仍在」的容器、无按报文头 `Array(n)` 预分配（`MQBlob.cj:106` 的 `size` 来自已落盘的临时文件长度，仍受上述上限约束）；命中只为 #1 的「磁盘/inode 无界增长」（同一根因，合并计一条） |
| §6.1 热点瓶颈 | 0 | 本部分未提供 `cjprof` / `cjpm bench` 数据，热点结论不成立；相关线索（`publishTime` 分配、3 次全量解码）已写进「待验证假设」#2 #3 与优化 #3 #4 |
| §6.2 大粒度锁 | 0 | 本部分代码无 `synchronized` / `Mutex` / `Atomic`，全部是无状态静态方法；唯一的共享点是外部 `DefaultCodec` 全局缓冲池，写成「待验证假设」#1（CPU profile 看不出锁等待，需线程状态证据） |
| §6.3 并发串行 | 0 | 本部分无 `spawn` / `Future.get` / 批量提交；`consume` 一次一条的串行上限属调用方设计，写成「待验证假设」#4 |
| §6.4 低效算法 | 0 | 无嵌套循环、无 `remove(at: 0)` 当队列、无循环内字符串拼接、无热点 `contains`；`publishTime` 的 9 次分配与重复解码按「线索不是证据」处理，进「待验证假设」 |
| §7 降堆内存方案 | 2 | 见优化 #1（整记录拷贝）、#2（`copyBytes` 全量副本）；两条都无基线，已标「待验证，不进 tasks」 |
| §8 降 CPU 方案 | 2 | 见优化 #3（`publishTime` 分配）、#4（前缀解码合并）；同样无基线 |
| §9 local mode 可行性 | 0 | **不可行**：`encode` 返回 `Array<Byte>`、`decode`/`decodeValues` 返回 `Array<Data>`/`MQMessageContent`（均逃逸出函数），违反「`@ local!` 不能作为返回值」；`DefaultCodec` / `f_io.ByteBuffer` 也没有 local mode 重载（需逐个核对 std/f_* 签名，本部分未提供任何峰值内存数据），三条约束同时卡住 |
| §11 现有代码的 BUG（存量） | 8 | 本轮读到的 8 条发现全部为存量（快照无基线），集中在「BODY 形态未归一化」（#1）、「两套闸门结论不一」（#2）、「主题长度无上限」（#3）与 5 条工程卫生问题（#4–#8）；本部分 13 个非测试文件的分支与空值路径逐个核过 |
| §12 并发安全与锁粒度 | 0 | 结论：无线程共享的可变状态——本部分 13 个非测试文件里没有 `static var`、没有单例字段、没有可变容器成员（`MQBlob.bytes` 是每实例私有且无 setter，`MQBlob.log` 是 `static let`）；`MQMessage` 的字段由 `@DataAssist` 生成 setter，实例按消息构造后不再跨线程共享（`MQClient` 每条消息新建）。锁粒度无可谈对象，未命中也无「锁太大」可报 |
| §14 功能完备性与 README 覆盖 | 0 | 与本部分相关的 README 段落（`README.md:106`、`:129`、`:157-174`）已逐项对照：`MQMessageRecord` 的 `topic`/`tags`/`body` 漏登记在「其他公开 API」清单里，但该问题已由第 1 部分（`f_mq.part1.md` 第 3 条）登记，本条不重复计；`MQBlob`/`MQBytes` 的临时文件说明（`README.md:129`）只承诺「记录级」形态，BODY 级的缺口归 #1 |
| 文件覆盖（§13 等） | 20/20 | 本部分清单内 20 个文件全部读完（13 个 `.cj` + 7 个 `_test.cj`）；本部分不含 `.md`，文档一致性核对以「代码侧对照 README / `doc/详细设计.md` 的具体行」的形式落在 #3 与 §14 行 |

### 第 5 部分

| 维度 | 命中 | 未命中时的说明 |
| --- | --- | --- |
| 正确性 / 设计 / 语言特性 / 可读性 / 安全性 | 6 | 正确性 2（#1 认领无过期、#2 owner 不刷新）、设计 1（#6 异常分类学）、语言特性 1（#8 无用 `var` + 冗余锁）、可读性 2（#9 测试污染全局配置、#10 四处同构样板须同步改）；安全性 0：本部分无 SQL/命令拼接，topic/tags/group 在客户端与服务端双向校验（`MQTopic`/`MQTags`/`MQGroup`），日志不含凭据与完整报文 |
| §1 死代码 | 0 | 已逐个符号搜引用：`MQClient` 的 `subscriptionOf`/`ensureOpen`/`transferOf`/`groupOf`/`nodeList`/`candidateNodes`/`rollback`、`candidateContains` 均有调用者；`candidateNodesOf` 被生产与用例共用；`MQOwnershipCache`/`MQRetiredSubscriptions` 全部成员有引用；`MQNodePool.isClosed` 只被 `MQNodePool_test.cj` 引用（internal 类成员、仅测试使用 → 属可见性建议，不算死代码）；12 个载荷类均为 `public` 顶层且被 `fmq` 跨模块使用（`MQDeadLetterMessage`/`MQMetaTombstone`/`MQTopicAssignment` 等），对外可达不判；`MQClient.cj:300-301` 的 `throw "unreachable"` 位于 `while(true)` 之后，是编译器返回类型检查需要，非缺陷。未发现 `return`/`throw` 后同层语句、恒真恒假分支或未使用 import |
| §2 重复逻辑 | 2 | 逐函数体比对后命中 2 条（#10 四份样板、#11 三个载荷构造函数）。**刻意不判**的两组：`MQConsumePayload` 与 `MQUnsubscribePayload` 形态相同但协议按 `typeInfo.qualifiedName` 分派（`MQProtocol.cj:158-190`），合并会破坏自描述；`MQCandidateNodes_test.legacyCandidateNodes` 是基准对照的旧实现，注释已说明用途 |
| §3 空实现 | 0 | 20 个文件无 `TODO`/`FIXME`/空函数体；`catch` 块均有日志（`MQNodePool.cj:110-113` DEBUG、`:190-192` DEBUG）；`case None => ()` 出现在 `MQClient.cj:252`（`addIfAbsent` 成功）与 `MQNodePool.cj:115/194`（槽位本就为空），都不是吞错误 |
| §4 栈溢出 | 0 | 无递归：`candidateContains`/`candidateNodesOf`/`nodeList`/`backoffOf` 均为循环；无自引用结构的深度遍历 |
| §5 OOM | 2 | #1（`deliveries` 无上界，随未 ack 数增长）、#3（ownership 缓存无清扫）。其余容器已核对为有界：`subscriptions`（用户订阅数）、`retired`（4096 FIFO）、`slots`/`retryAt`/`failures`（节点数定长）；无「按报文长度预分配」路径（`Array` 大小均来自配置/节点数） |
| §6.1 热点瓶颈 | 0 | 未提供 bench/profile 数据（`MQCandidateNodes_test` 的分配基准默认跳过且无绝对值记录），热点结论不成立，已转「待验证假设」#1~#5 |
| §6.2 大粒度锁 | 0 | 唯一的「锁内重活」是 `MQNodePool.cj:122-133` 在 `nodeLocks[i]` 内建连：这是「并发首次建连只建一条」（客户端 spec 的 Scenario）所必需，且锁按节点分片，一个节点建连慢不阻塞其它节点；其余临界区只有 map/数组读写（`MQRetiredSubscriptions.cj:41-52`、`MQOwnershipCache` 无锁）。`MQClient.close` 的 `closeLock` 无实际保护对象，已记 #8（轻微，非性能） |
| §6.3 并发串行 | 1 | #4：subscribe/rollback/ack/unsubscribe 四处逐节点串行，最坏耗时 N × 超时；未测量，不给端到端收益 |
| §6.4 低效算法 | 1 | #7（`retired` FIFO 用 `remove(at: 0)`）；另 #4 的 ack 广播无提前退出同源。`candidateContains` 是 O(节点数) 线性扫描，节点数为集群规模，属合理取舍，不判 |
| §7 降堆内存方案 | 2 | `copyBytes` 多一份记录、`deliveries` 字符串键；均无基线 |
| §8 降 CPU 方案 | 2 | `candidateNodesOf` 双分配、空轮询固定 200ms；均无基线 |
| §9 local mode 可行性 | 0 | 不可行：热路径对象全部逃逸——`MQMessageRecord.encode` 的字节进入 `Message` 并交给网络栈（`MQClient.cj:83-88`），`MQConsumeResult.record` 与解码出的 `Data` 树经 `MQMessage` 返回给调用方（`:255`）；没有「函数内创建、函数内释放」的临时大对象，`@ local!` 会在逃逸检查处失败。且本模块未开启 `--enable-local-mode`，混链会产生 SDK 锁版约束 |
| §11 现有代码的 BUG（存量） | 11 | #1~#11 全部为存量（blame 均为 2026-10-18/21）。已核对未成缺陷的边界：`MQTopicAssignment.owner` 负下标/越界；`DeregisterKind` 空串与大小写变体落 `Unknown`；`MQBlob` 空 vs `None` 的区分（客户端 `:241` 先判空再解码）；`backoffOf` 指数封顶 5s 不溢出；`MQNodePool.clientOf` 越界与关闭后复核 |
| §12 并发安全与锁粒度 | 2 | 并发安全：`subscriptions`/`deliveries`/`ownership.entries` 用 `ConcurrentHashMap`，`cursor` 用 `AtomicInt64`，`retired` 用 `Mutex`，`pool` 用逐节点 `Mutex`，`closed` 用 `AtomicBool`——共享点已列全；命中 #1（认领状态无生命周期，跨线程可见但永不过期）与 #5（`close` 与 `subscribe` 的检查-然后-写入）。`ack` 的 `get`+`remove` 非原子，但服务端 ack 幂等（重复 ack 回 `ACK_UNKNOWN` 被忽略），不构成缺陷。`nextStart` 的 `fetchAdd` 需 9.2e18 次调用才可能溢出成负下标，不构成现实风险 |
| §14 功能完备性与 README 覆盖 | 0 | 本部分 12 个载荷类在 `README.md:161` 全部登记；`MQTopicAssignment.owner`（README:174）、`MQMetaTombstone.key/isTopic`（README:170）、`MQDeregisterPayload.kindOf/isTopic`（README:163）、`MQClient`/`MQClientConfig`（README:39-52、144）均已覆盖。缺口仅符号级：`MQClientConfig.hosts` 属性与载荷的 `static const`（`MQDeregisterPayload.TOPIC/GROUP`、`MQMetaTombstone.KIND_TOPIC/KIND_GROUP`）未在 README 点名——README 属第 1 部分范围，此处只作提示，不计入本部分统计 |
| §13 文档一致性 / 文件覆盖 | 20/20 | 本部分清单不含 `.md`，故 §13 无对照对象；20 个 `.cj` 全部逐行读完，无「未读」项 |

### 第 6 部分

| 维度 | 命中 | 未命中时的说明 |
| --- | --- | --- |
| 正确性 / 设计 / 语言特性 / 可读性 / 安全性 | 2 | 命中：发现 #1（投递语义）、#4（测试边界值漂移）；`MQException` 体系与门面导入逐项核对无问题；本部分无外部输入拼接、无凭据、无 SQL |
| §1 死代码 | 2 | 命中 #2（1 个字段）、#3（2 个无调用者的测试辅助函数）；已逐个符号搜引用：`MQSubscription`（internal）的 `subscribedId` 零读取、`nextStart`/`keyOf`/`deliveries`/`owners`/`autoAck`/`topic`/`subscribeGroup` 均有调用；`CapturingAppender.clear`、`MQStubServer.clear` 零调用；`MQStubServer.isClosed` 是 `Resource` 接口实现，豁免；`MQException*` 为 `public open` 顶级类，对外可达不判 |
| §2 重复逻辑 | 1 | 命中 #4（tags 边界字面量）；另逐行比对 `MQClient_test` 的 5 个 `stubMessage`/`okBut` 调用形态、`MQNodePool_test` 的 3 个 `MQStubServer(ok)` 建桩段，差异在响应码与断言目标，属业务差异；`client/MQTestSetup_test.cj` 与 `client/test/MQTestSetup_test.cj` 逐字相同，但属 §2 误报边界「测试里的准备代码」，不判 |
| §3 空实现 | 1 | 命中 #6（桩服务端吞异常）；`CapturingStream.flush() {}` 是 `OutputStream` 的有意 no-op（内存流无需 flush）；`MQException` 各构造器均有实体；无 `TODO`/`FIXME`（`grep -rn "TODO\|FIXME" f_mq/src` 无命中） |
| §4 栈溢出 | 0 | 本部分无递归、无自引用结构遍历；`MQClient.consume` 的 `while (true)` 是轮询循环不是递归，每次迭代不增栈 |
| §5 OOM | 1 | 命中 #1 的第三个后果（`deliveries` 无界增长）；`MQStubServer.received` 的 `ArrayList` 仅测试进程内增长，用例量有限，不单列 |
| §6.1 热点瓶颈 | 0 | 本部分无 profile / bench 数据；疑似热点已全部降级到「待验证假设」#1/#2 |
| §6.2 大粒度锁 | 0 | 本部分唯一的锁是 `CapturingStream.lock`（测试日志捕获），临界区内是 `String.fromUtf8` 与数组追加，持有时长与日志条数成正比但只在测试进程；`MQSubscription` 用 `ConcurrentHashMap` + `AtomicInt64`，无锁临界区 |
| §6.3 并发串行 | 0 | 无 `spawn(...).get()`；`MQNodePool_test` 与 `MQClient_test` 的 `spawn` 用于制造并发，不在生产路径；`ack` 广播路径的串行 RTT 在 `MQClient.cj`（本部分外），未计入 |
| §6.4 低效算法 | 0 | `keyOf` 的字符串拼接计入优化方案 #1；`MQClient_test.countOf` 为 O(请求数) 的测试辅助，单用例请求数 ≤ 数十，不构成 O(n²) 风险；本部分无 `remove(at: 0)`、无嵌套匹配 |
| §7 降堆内存方案 | 0 | 唯一可量化项（`deliveries` 条目膨胀）与发现 #1 同根因，已并入该条的建议，不重复计数 |
| §8 降 CPU 方案 | 1 | 优化方案 #1（值类型位置键），证据状态为无基线 |
| §9 local mode 可行性 | 0 | `keyOf` 的临时 String 会经 `deliveries` 逃逸，不满足线程内释放前提；其余函数无函数内大对象；已转为待验证假设 #3 |
| §11 现有代码的 BUG（存量） | 3 | 命中 #1（契约不符）、#5（非确定断言）、#6（吞异常）；另核对：`nextStart` 的 `% owners.size` 在 `owners` 为空时会除零，但唯一调用点 `MQClient.cj:223` 已先拦截空集合；`cursor` 的 Int64 溢出需 9.2×10¹⁸ 次调用，不构成可达缺陷 |
| §12 并发安全与锁粒度 | 1 | 命中 #1（跨线程共享的 `deliveries` 语义问题）；`deliveries`/`owners`/`cursor` 的并发访问手段齐备（`ConcurrentHashMap`、`AtomicInt64`、不可变数组），无检查-然后-写入缺陷；`MQSubscription` 无发布逸出 |
| §14 功能完备性与 README 覆盖 | 0 | `f_mq.cj` 的 5 个 `public import` 覆盖模块全部 public 包（base、base.model、base.payload、exception、client），无「注册了但没导出」；本部分不含 README，`MQException`/`MQSubscription`（internal）不涉及文档承诺 |
| 文件覆盖（§13 等） | 11/11 | 11 个文件全部读完；本部分无 `.md`，§13 无对象 |

## 模块统计

| 严重程度 | 数量 |
| --- | --- |
| 严重 | 4 |
| 一般 | 13 |
| 轻微 | 30 |
| 其中存量 | 36 |
| 优化方案 | 见「优化可行性方案」各条 |

## 总评

**第 1 部分**：本部分 15 份文档的质量高于一般仓库：`doc/spec/**` 把「为什么这么定」「失败语义表」「边界清单」都写进了设计，且每条严重问题都有对应的 verify 记录与任务编号，可回溯性很好；README 中英文内容等价，没有整节缺失。

主要风险集中在**文档与代码的接缝处**，且都在对外契约面：错误码表少一个码、本地校验与「带码异常」的语义被混写、`consume`/`publish` 的失败出口只写了一半、公开 API 兜底清单实际漏了 6 个类型。这些不会让服务崩溃，但会让调用方按文档写出错误的错误分支与重试策略——尤其 `consume` 抛 `FILTER_UNSUPPORTED_BODY` 这一步直接关系到「消息是不是被静默丢掉」的认知，是本部分最该先修的一条。

第二条风险是归档 delta spec 的内部矛盾（consume 位置缺 `queueIndex`）：它记录的正是 C1 那个「多队列 ACK 串台」缺陷，规格没跟着修复走，后续照文档补测试会重新引入同样的位置口径错误。

没有阻塞项：README 与实现的核心语义（at-least-once、三元组位置、`ack` 路由、`unsubscribe` 幂等、`delaying` 队首阻塞、有界退订集合）全部与源码一致。建议按「错误码表 → 客户端失败出口 → 公开 API 清单 → client delta 补 `queueIndex`」的顺序修复，其余（`MQBlob` 契约描述、内部符号引用、任务编号跳号）可随手带上。

**第 2 部分**：本部分 11 个文件是 `f_mq` 两轮审计（full-audit、postfix-audit）的规格、台账与校验记录，不含运行时代码，因此没有投递/确认语义、无界队列、锁粒度这一层的实现缺陷可判——这些需要 `.cj` 子轮。就文档而言，质量明显好于一般规格集：五份 delta 的需求几乎都能一一落到具体函数（`readPayload`、`startPositionOf`、`effectiveMaxRecord`、`Failure` 四分类、13 步 `closeSteps`），宣称「已删除」的符号（`isGroup`、`SegmentMissingException`、`openFrom`、`countAll`、`tombstoneFloor`、`hasLocalQueues`）逐个 grep 均为 0 命中，用例锚点抽查也真实存在。

风险集中在三处，均非阻塞：

1. **同一契约出现两个版本**：postfix delta 把客户端配置异常写成不存在的 `MQConfigException`，与实现和上一份 delta 三方相反；tags 上限在「字符 / 字节」之间摇摆。这两处都是「复述式 MODIFIED」的副作用，后续若再加 delta，建议只写差异。
2. **对外错误码表停在 11**：实现已有 12（`INVALID_TAGS`），规格的「每个码可达」场景又写死 0–11，新增码永远不会被这条场景发现。这是对外契约面唯一实质缺项，应最先补。
3. **台账自证不可复核**：full-audit 的 C1 引用了与自己同提交、却与实际内容相反的证据（`tasks.md:303` 已勾选），加上用例数 375/376 并存、verify 报告指向已迁出的 `openspec/changes/**`，会让归档门禁的判断失去依据。

以上 9 条全部为存量文档缺陷，建议按「错误码表 → 异常类型 → 退订契约」顺序排期修复；`INVALID_TAGS` 一条与第 1 部分的 README 缺项同源，合并修一次即可。

**第 3 部分**：本部分是 `f_mq` 的「纯函数地基」：字符集判定、三类名字校验、host 解析、过滤器封装、错误码常量。代码风格统一、职责单一、无锁无共享可变状态，校验规则集中在一处（`MQChars`）而不是散落，文档 §5.8a 也把四类名字的合法集对齐了实现 —— 这部分质量是好的，`MQGroup`/`MQHost`/`MQFilter` 没有发现死代码与重复逻辑。

主要风险集中在**边界与形态归一化**两处：

1. **阻塞项（严重）**：BODY 的大字节形态（`Array<Byte>` > 4096）没有像记录字节那样归一化。它在三个面上同时破：#1 的临时文件与 fd 无界泄漏、filter 误判 `NoMatch` 后 `GroupCursor` 静默越过（消息对该订阅永久丢失，只有 DEBUG 日志）、`get<Array<Byte>>()` 取不回。这一处必须先在 `MQMessageRecord.body`（或新增 `MQBody`）收口，再把 filter 的布尔返回改成三态，否则任何「大二进制消息 + filter」的组合都是静默丢数据 + 磁盘/句柄增长。
2. **可排期（一般）**：组名的「255 字节」上限与「转义后 + `.meta`/`.cursor` 后缀」的文件名上限冲突，27 个汉字左右就会在注册/游标落盘时 `ENAMETOOLONG`；修复要把上限定义在转义后的口径上，并同步 §5.8a 与 `MQGroup_test` 的边界用例。
3. **文档同步（轻微）**：`INVALID_TAGS(12)` 未进 §3.5 错误码表与稳定性用例、§4.1 总表漏 5 个 public 类型 —— 属于契约文档漂移，改文档即可，不阻塞。

范围外提示（不占本部分统计）：`MQClient.deliveries` 在「`autoAck=false` 且业务不 ack」时按投递条数单调增长（`详细设计.md:564-565`、`MQClient.cj:250`），属无界容器风险，归 `f_mq/src/client/MQClient.cj` 所属子轮判定。

**第 4 部分**：本部分是 MQ 的线格式与载荷定义层：`MQMessageRecord`（四段记录编解码）、`MQProtocol`（命令/响应工厂 + 载荷类型闸门）、`MQTags`/`MQTopic`（入口校验）、`model`/`payload`（纯数据 + `MQBlob` 大载荷包装）。整体质量偏上——严格类型闸门、池缓冲「先拷贝再 release」的约束、截断/多余字节/类型不符的失败语义都有注释与用例兜底，`MQMessageRecord_test` 的边界覆盖（每个截断长度、多余字节、16KB 临时文件清理）在水准之上。

真正需要排期的是两件事：

1. **BODY 形态未归一化（#1，与第 3 部分 #1 同一条）**：解码出的文件形态只在「字节字段」上被 `MQBlob` 清理，BODY 走 `decode`/`body()` 时既泄漏 `/tmp` 文件与 fd，又让客户端读不出大字节 BODY。这是唯一会拖垮宿主（inode/磁盘耗尽）的问题，属阻塞项。
2. **同一段字节两套闸门（#2）**：`MQMessage.get` 与服务端 `asPayload` 对「字符串 BODY 读成数字」「结构漂移」给出相反结论，A03/A04 的严格化只落在一侧；客户端与服务端对「同一条消息的 BODY」认知不一致，是潜在的静默错值来源。

其余为工程卫生（不可达分支、未使用 import、重复编码模板、空 catch、`decodePayload` 缺少 exact 校验）与一个边界（主题长度），可按批次清理，风险低。性能与内存方面本部分没有任何实测数据，四条优化方案与五条假设都只是下一轮补数据的清单，不构成结论。

**第 5 部分**：客户端主链路的**失败分类与可观测性做得比较扎实**：`TransferOutcome` 把「服务端回包 / 超时 / 连不上」区分开（`MQClient.cj:517-521`），publish 能区分「全 `NOT_OWNER`」与「连不上」（`:109-112`），consume 不再把服务端错误当空轮询（`:234-238`），订阅回滚失败会把节点拼进异常文案（`:163-171`），连接池「锁内复核 closed」也正确落地（`MQNodePool.cj:97-101`）。载荷类都是 `@DataAssist` 纯数据 + 双构造函数，没有隐藏状态。

主要风险集中在**投递状态的生命周期**，而不是并发原语：

1. **阻塞项**：#1 认领状态无过期。业务侧只要有一次「拿到消息却没有 ack」，该位置对本订阅永久卡死，且 `deliveries` 无界增长——直接违反 README:122 的 at-least-once 承诺。这一点必须修（加 TTL + 容量上限），否则任何消费异常的累积都会把一部分消息静默吞掉。
2. **排期修复**：#2 owner 集合不刷新（扩缩容后订阅空转、无告警），这是集群能力与客户端状态模型之间的结构性缺口；#3 缓存无清扫，属于慢泄漏。
3. 其余为工程卫生：四处同构样板（改一处漏一处的风险）、构造函数双写、异常分类学、`remove(at: 0)`、无用 `var`/冗余锁、用例提前删除全局配置。

性能方面本轮**没有拿到任何测量数据**（本部分的分配基准用例默认跳过、也没有记录绝对值），因此全部性能判断都停在「待验证假设」：「优化可行性方案」里的 `copyBytes` 副本与 `deliveries` 字符串键是最值得先补数据的两个点，但按现有证据不能声称收益比例。

本报告为第 5/6 部分，仅统计本部分 20 个文件；`MQSubscription.cj`、`MQClient_test.cj` 等仅作调用链与旁证引用，未计入覆盖与统计。

**第 6 部分**：本部分的生产代码只有 3 个文件、158 行（`MQSubscription.cj` 56 行、`exception/MQException.cj` 75 行、门面 `f_mq.cj` 27 行），其余是测试。代码质量整体良好：异常层次与 `BaseException` 严格对齐、门面导出完整、测试覆盖了投递/确认的绝大多数分支（NOT_OWNER 回退、ACK_UNKNOWN 容忍、部分退订保留本地订阅、并发认领唯一性），注释密度与「为什么这么写」的说明都到位。

阻塞项只有一个，但性质严重：`deliveries` 把「并发去重认领」实现成了无生命周期的永久表。它让 README 承诺的 at-least-once 在同一客户端实例内失效——未 ack 的消息在被丢弃若干次后直接进死信，业务与日志都看不到；同时该表对进死信的消息永久驻留，长时间运行会缓慢增长。修法不复杂（认领加 TTL/上限 + 跳过时计数告警），但需要同步改掉把该行为写成期望的用例 `sameDeliveryPositionIsClaimedOnce`，属于语义决策，建议优先排期。

其余 5 条轻微项集中在测试设施：清理入口未接线导致静态日志缓冲跨用例累积（可能造成假通过）、边界值硬编码、墙钟时序断言、桩服务端吞异常。这些不影响生产行为，可随下次测试维护一起处理。

范围外提示（不计入统计）：`MQClient.ack` 命中投递映射后只打那一个节点，超时/拒绝时保留映射并抛错、不回退广播（`f_mq/src/client/MQClient.cj:315-335`），投递节点长期不可达时该位置将永远无法确认；该文件属其他子轮，此处仅记录。
