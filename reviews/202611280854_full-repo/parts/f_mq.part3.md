# f_mq 模块审查报告 —— 模块第 3/6 部分

- **审查日期**：2026-11-28
- **模块路径**：`f_mq`（本部分 10 个 `.cj` + 10 个 `.md`，共 20 个文件）
- **基线**：工作区快照（sts/1.3.x 工作区，未对照远端目标分支；本部分全部问题均为 `存量`）
- **审查重点**：消息队列投递/确认语义、重复与丢失、无界队列 OOM、大粒度锁与并发串行、死代码、重复逻辑、存量 BUG
- **报告版本**：v1（分子轮报告；模块报告由主 Agent 合并，本文件不写 `docs/review/`）
- **本部分范围**：`f_mq/src/base/{MQChars,MQConstants,MQFilter,MQGroup,MQHost}.cj` + 同目录 5 个 `_test.cj`；`f_mq/doc/详细设计.md`、`f_mq/doc/开发计划.md`、`f_mq/doc/spec/**` 8 份变更文档

## 发现

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

## 优化可行性方案

本部分（基础校验 / 过滤器 / 常量 / 文档）**没有**具备改前基线的优化项：唯一与运行期成本相关的 `MQFilter.matches` 迭代器分配缺少 profile 数据，按铁律只进「待验证假设」，不计入本节。

## 待验证假设

> 无性能数据支撑，不进 `todo.md` / `tasks.md`。

| # | 假设 | 位置 | 缺什么数据 | 怎么采 |
| --- | --- | --- | --- | --- |
| 1 | 带 filter 的消费路径每条记录都要新建一条 `DataPath.get` 迭代器链（`SingleIterable`/`OptionIterator`/`flatMap` 闭包），GC 压力随消费速率线性增长 | `f_mq/src/base/MQFilter.cj:58-73`；调用点 `fmq/src/queue/MQMatcher.cj:106-115` | 分配字节/条、self time 占比 | `cjprof record` 跑 1w 条、单订阅、filter 非空 vs 空两组；同机 `-O2`，看 `MQFilter.matches` 与 `DataPath.get` 的自耗时占比 |
| 2 | 同一记录在 filter 判定中被解析三次（`topic` / `tags` / `body` 各从头解一次，`body` 需解满 4 段） | `f_mq/src/queue/MQMatcher.cj:90-110` + `f_mq/src/base/MQMessageRecord.cj:153-185` | 单条记录解析耗时占比、每条记录的重复解码次数 | 分段计时或 `cjpm bench` 对比「一次解四段」与「三次前缀解码」 |

## 文件覆盖

| # | 文件 | 类型 | 已读 | 说明 |
| --- | --- | --- | --- | --- |
| 1 | `f_mq/doc/spec/fix-fmq-verify-followups/design.md` | .md | ✅ | 归档变更设计；§2.4 端口 1..65535 与 `MQHost` 一致，§3 段格式与 `QueueLog.PREFIX_SIZE=4` 一致 |
| 2 | `f_mq/doc/spec/fix-fmq-verify-followups/proposal.md` | .md | ✅ | 与 design/tasks 结论一致，无漂移 |
| 3 | `f_mq/doc/spec/fix-fmq-verify-followups/specs/f-mq/protocol/spec.md` | .md | ✅ | 归档 delta；「非零值取真」的括注与 D2「存在即真」（0 也取真）措辞不符，属归档文案，未计入统计 |
| 4 | `f_mq/doc/spec/fix-fmq-verify-followups/tasks.md` | .md | ✅ | 40/40 勾选；2.4 记录的「f_mq 82 项」与 verify-report 一致 |
| 5 | `f_mq/doc/spec/fix-fmq-verify-followups/verify-report.md` | .md | ✅ | 声称「`f_mq/doc/详细设计.md` §3.2 有指针」已核实（`:104-106` 存在） |
| 6 | `f_mq/doc/spec/optimize-f-mq-candidate-nodes/design.md` | .md | ✅ | D1 预分配数组语义（owner 优先、前缀去重、切片返回）与 `MQGroup` 无关；未改公开 API 的说法与 `MQClient` 现状一致 |
| 7 | `f_mq/doc/spec/optimize-f-mq-candidate-nodes/proposal.md` | .md | ✅ | 三方探针数据在归档内自洽 |
| 8 | `f_mq/doc/spec/optimize-f-mq-candidate-nodes/tasks.md` | .md | ✅ | 与 design/proposal 一致 |
| 9 | `f_mq/doc/开发计划.md` | .md | ✅ | 历史 TDD 计划；前置里的 `.worktrees/feature-mq` 工作区已不存在（过期，未计为问题）；A2/B1 的成员名与现值一致（`MQHost.parseHost` 归位已反映在 B1） |
| 10 | `f_mq/doc/详细设计.md` | .md | ✅ | 与实现多处交叉核对（§3.2/§3.5/§4.1/§5.5/§5.6/§5.8a/§5.12/§5.14/§6.7）；问题见 #3、#6、#2 |
| 11 | `f_mq/src/base/MQBlob_test.cj` | .cj | ✅ | 阈值 4096/4097 往返用例扎实；问题见 #5（`/tmp` 全局计数） |
| 12 | `f_mq/src/base/MQChars.cj` | .cj | ✅ | `internal`，仅被 `MQTopic`/`MQTags`/`MQGroup` 调用；码点判定正确 |
| 13 | `f_mq/src/base/MQConstants.cj` | .cj | ✅ | 错误码/kind/枚举；问题见 #3（12 未进文档与用例） |
| 14 | `f_mq/src/base/MQErrorCode_test.cj` | .cj | ✅ | 见 #3 |
| 15 | `f_mq/src/base/MQFilter.cj` | .cj | ✅ | 问题见 #1（大字节 BODY）、#4（异常类型） |
| 16 | `f_mq/src/base/MQFilter_test.cj` | .cj | ✅ | 容器矩阵（HashMap/Array/TreeSet）与空容器用例齐全；见 #4 |
| 17 | `f_mq/src/base/MQGroup.cj` | .cj | ✅ | 问题见 #2；`:45` 注释「这三个」实列四个分隔符（笔误，未单列） |
| 18 | `f_mq/src/base/MQGroup_test.cj` | .cj | ✅ | `:64` 的 255 字节断言固化了 #2 的边界 |
| 19 | `f_mq/src/base/MQHost.cj` | .cj | ✅ | 单冒号切分、端口 0/越界拒绝与文档一致；IPv6 字面量不支持（文档已声明「按单个冒号切分」，不算缺陷） |
| 20 | `f_mq/src/base/MQHost_test.cj` | .cj | ✅ | 覆盖空串/缺端口/端口 0/越界/多冒号；未覆盖 65535 上界（缺口很小，未单列） |

合计：`.cj` 10 个 / `.md` 10 个 / 共 20 个，全部读完。

## 覆盖自检

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

## 模块统计（本部分）

| 严重程度 | 数量 |
| --- | --- |
| 严重 | 1 |
| 一般 | 1 |
| 轻微 | 4 |
| 优化方案（堆内存 / CPU） | 0 / 0 |

存量缺陷 6 条（1 严重 / 1 一般 / 4 轻微），是否纳入修复待用户决定；本报告不含 `本次改动` 来源的问题（快照模式无基线）。

## 总评

本部分是 `f_mq` 的「纯函数地基」：字符集判定、三类名字校验、host 解析、过滤器封装、错误码常量。代码风格统一、职责单一、无锁无共享可变状态，校验规则集中在一处（`MQChars`）而不是散落，文档 §5.8a 也把四类名字的合法集对齐了实现 —— 这部分质量是好的，`MQGroup`/`MQHost`/`MQFilter` 没有发现死代码与重复逻辑。

主要风险集中在**边界与形态归一化**两处：

1. **阻塞项（严重）**：BODY 的大字节形态（`Array<Byte>` > 4096）没有像记录字节那样归一化。它在三个面上同时破：#1 的临时文件与 fd 无界泄漏、filter 误判 `NoMatch` 后 `GroupCursor` 静默越过（消息对该订阅永久丢失，只有 DEBUG 日志）、`get<Array<Byte>>()` 取不回。这一处必须先在 `MQMessageRecord.body`（或新增 `MQBody`）收口，再把 filter 的布尔返回改成三态，否则任何「大二进制消息 + filter」的组合都是静默丢数据 + 磁盘/句柄增长。
2. **可排期（一般）**：组名的「255 字节」上限与「转义后 + `.meta`/`.cursor` 后缀」的文件名上限冲突，27 个汉字左右就会在注册/游标落盘时 `ENAMETOOLONG`；修复要把上限定义在转义后的口径上，并同步 §5.8a 与 `MQGroup_test` 的边界用例。
3. **文档同步（轻微）**：`INVALID_TAGS(12)` 未进 §3.5 错误码表与稳定性用例、§4.1 总表漏 5 个 public 类型 —— 属于契约文档漂移，改文档即可，不阻塞。

范围外提示（不占本部分统计）：`MQClient.deliveries` 在「`autoAck=false` 且业务不 ack」时按投递条数单调增长（`详细设计.md:564-565`、`MQClient.cj:250`），属无界容器风险，归 `f_mq/src/client/MQClient.cj` 所属子轮判定。
