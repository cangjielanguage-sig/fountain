# fmq 模块审查报告（第 4/7 部分）

- **审查日期**：2026-11-28
- **模块路径**：`fmq`（本部分 19 个源文件：`src/cluster/{MetaSyncer_test,NodeRegistry,NodeRegistry_test}.cj`、`src/config/{MQConfig,MQConfig_test}.cj`、`src/main.cj`、`src/manager/*.cj`、`src/meta/{AtomicFile,AtomicFile_test,LogCapture_test,MQAssignment,MQAssignment_test,MQFileNames,MQFileNames_test,MetaStore}.cj`）
- **基线**：工作区快照（master 与 sts/1.3.x 同一提交 `120fd2542`，`git diff` 为空）⇒ 本部分所有发现来源均为**存量**
- **审查重点**：投递/确认语义与重复丢失、无界队列 OOM、大粒度锁与并发串行、死代码、重复逻辑（另按通用维度全扫）
- **报告版本**：v1（分部分报告，由主 Agent 合并入 `docs/review/2026-11-28/fmq.md` / `fmq_v2.md`）

## 发现

### [严重][存量] 远端 REGISTER 的 `queueNum` 无上限，直接决定数组长度与队列目录数，可被单个请求打成 OOM

- **位置**：`fmq/src/meta/MQAssignment.cj:37`（`Array<Int64>(queueNum) ...`）；缺少上限校验的位置：`fmq/src/meta/MetaStore.cj:225-233`、调用链上游 `fmq/src/cluster/MetaSyncer.cj:117-119`、`fmq/src/server/MQCommandExecutor.cj:106-114`
- **来源**：存量（快照基线无 diff）
- **判据**：review-checklist §5（按不可信长度预分配 / 无界容器）、§11（缺少边界校验）
- **证据**：静态确定 —— 全链只有 `queueNum < 1` 的下界判断：
  - `MetaStore.cj:225` `if (meta.queueNum < 1 || nodeCount < 1) { return (Conflict, None) }`
  - `MetaSyncer.cj:117` `if (meta.queueNum < 1) { throw MQServiceException(INVALID_TOPIC, ...) }`
  - `MQCommandExecutor.cj:106-114` 只校验 `MQTopic.isValid(meta.topic)`，随后 `syncer.registerTopic(meta)`（`meta` 直接来自请求载荷）
  - `MQAssignment.cj:30-37` 只校验 `queueNum < 1`，然后 `Array<Int64>(queueNum)`
  - 规范侧也只有下界：`fmq/doc/spec/add-fmq-message-queue/specs/fmq/metadata-cluster/spec.md:28` 只写 `queueNum <= 0` 的拒绝场景
  - 全仓搜索 `maxQueue|queueNumLimit|MAX_QUEUE` 零命中
- **描述**：`fmq` 服务端没有任何鉴权（`fmq/src/server/*.cj` 搜 `auth|token|ACL` 零命中），任何能连上端口的客户端发一条 `REGISTER + MQTopicMeta(queueNum = N)` 即可：① `MQAssignment.allocate` 立刻按 N 分配 `Array<Int64>`（8N 字节，N=2^31 即 16 GB）；② 该分配发生在 `MetaStore.registerTopic` 的 `synchronized(lock)` 临界区内（`MetaStore.cj:228-242`），OOM 会连带打死整条元数据写入路径；③ 若 N 小到能分配成功（例如 1e6），分配结果会落盘并进入 `queues.openTopic(assignment, ...)`，按队列数建段日志/游标目录，磁盘与句柄被按请求放大。分配后 `MQAssignment.validate/validateStructure` 只做 `owners.size == queueNum` 的一致性检查，不设上限，因此磁盘与快照载荷同样能把超大 `queueNum` 带进索引。
- **建议**：在 `MetaStore.registerTopic`（或 `MQAssignment.allocate` 入口）加显式上限常量/配置项（如 `MAX_QUEUES_PER_TOPIC`），超限返回 `MetaApplyResult.Invalid` 并由 `MetaSyncer` 映射为 `INVALID_TOPIC`；同时在 `MQAssignment.validateStructure` 里加上限，挡住来自磁盘与 peer 快照的超大 `queueNum`（否则「能校验通过 = 能落盘 = 能扩散」）。

### [一般][存量] 墓碑键格式在 6 处手写重复，`MQMetaTombstone.key()` 已经存在却未复用

- **位置**：`fmq/src/meta/MetaStore.cj:480`、`fmq/src/meta/MetaStore.cj:616`、`:618`、`:644`、`:646`；`fmq/src/cluster/MetaSyncer.cj:426`、`:437`
- **来源**：存量
- **判据**：review-checklist §2（字面量复制 / 跨文件重复；判据是语义相同而非语法相同）
- **证据**：静态确定 —— 权威实现在 `f_mq/src/base/payload/MQMetaTombstone.cj:61-67`（`"${KIND_TOPIC}\u{0}${topic}"` / `"${KIND_GROUP}\u{0}${topic}\u{0}${subscribeGroup}"`）。`MetaStore.tombstoneOfLocked`（616/618）与 `dropTombstoneLocked`（644/646）各自重新拼一遍同样的 `\0` 分隔格式；`topicTombstone`（480）甚至绕过 `tombstoneOfLocked` 直接拼 key；`MetaSyncer` 在缺失扫描里用同一个格式去和 `tombstone.key()` 生成集合比对（426/437）。
- **描述**：语义完全一致（同一 kind 前缀、同一 `\0` 分隔、同一字段顺序），差异只有「谁拼的」。当前实现一致，但格式分散在 2 个包 6 处、且其中一处与 `key()` 生成集合做字符串匹配：任何一次格式调整（换分隔符、加转义）只要漏改一处，就是**静默的墓碑查不中**——`applyTopic`/`applyGroup` 会认为「无墓碑」而复活已删条目，属于最难排查的一类数据错误。`MetaStore.cj:480` 尤其危险，它连 `tombstoneOfLocked` 都绕开了。
- **建议**：`MetaStore` 内统一走 `tombstoneOfLocked(kind, topic, group)`（480 处改为 `tombstoneOfLocked(MQMetaTombstone.KIND_TOPIC, topic, "")`）；`MetaSyncer.cj:426/437` 改为构造对应用例的 `MQMetaTombstone` 后再调 `key()`，或在 `f_mq` 里补一个 `static func keyOf(kind, topic, group)` 供两处共用一个入口。

### [一般][存量] 元数据「写盘」与「改内存」顺序不一致：写失败后内存已前进，重启后状态回退

- **位置**：`fmq/src/meta/MetaStore.cj:337-356`（`applyGroup` 先改 `list` 再 `writeAtomically`）、`fmq/src/meta/MetaStore.cj:236-241`（`registerTopic` 先 `topicIndex.add` 再写 `assign.meta`）
- **来源**：存量
- **判据**：review-checklist §11（资源/状态不对称、错误路径当成功）、§3（半提交）
- **证据**：静态确定 —— 同一文件中三种写入的顺序互相矛盾：
  - `registerGroup`（260-269）：`writeAtomically` → `list.add`（先盘后内存）
  - `applyTopic`（301-302）：`writeAtomically` → `topicIndex.add`（先盘后内存）
  - `applyGroup`（346-354）：`list[i] = meta` / `list.add(meta)` → `writeAtomically`（**先内存后盘**）
  - `registerTopic`（236-241）：`writeAtomically(topic)` → `topicIndex.add` → `dropTombstoneLocked` → `writeAtomically(assign.meta)`；第二处写盘失败时，内存索引、`nextStart`、已删除的墓碑文件都已生效
- **描述**：磁盘满 / fsync 失败 / 目录不可写时，`applyGroup` 抛异常给 `MetaSyncer`（对端收到 INTERNAL），但本地内存里该订阅组已存在——此进程内 `groupExists` 为真、快照会把这条组下发给 peer；重启后组文件不存在，组凭空消失。`registerTopic` 的第二处写盘（`assign.meta`）失败同理：主题已在内存与磁盘，客户端却收到失败，重试得到 `TOPIC_ALREADY_EXIST`；同时 `nextStart` 只改了内存，重启后轮转起点回退，两个主题可能拿到相同起点（分配不均衡，不破坏正确性）。现有用例 `AtomicFile_test.cj:139-163` 只覆盖了「第一处写盘就失败」，覆盖不到这两种半提交。
- **建议**：统一成「先在锁内算出新状态（不可变值）→ 写盘 → 成功后一次性替换索引」；`applyGroup` 与 `registerTopic` 的索引更新挪到所有 `writeAtomically` 之后。若维持「内存先行」，至少补一条失败回滚（catch 里恢复 `list`/`nextStart`/墓碑文件），并补一个「第二处写盘失败」的用例。

### [轻微][存量] `dispatchWith` 里的 `--help` 分支恒不成立

- **位置**：`fmq/src/main.cj:69-73`（判据来自 `:52-59` 的选取循环）
- **来源**：存量
- **判据**：review-checklist §1（恒假分支 / 不可达语句）
- **证据**：静态确定 —— `commandIndex` 只会在 `!args[i].startsWith("-")` 的位置被赋值，因此 `let command = args[commandIndex]` 必然不以 `-` 开头，`command == "--help" || command == "-h"` 永远为假；真正的 help 判定已由 `commandIndex < 0` 分支里的 `wantsHelp(args)`（`:62`）覆盖
- **描述**：死分支不影响行为，但会误导后来者以为「第一个参数是 `--help`」走这条路径，实际它落在 `:60-68`。同文件 `:74-87` 的 `server`/`manager` 分支里再查 `wantsHelp` 是有效逻辑（`--help` 出现在子命令之后）
- **建议**：删除 `:70-73`，或在 `:60` 分支注释里写明「所有以 `-` 开头的参数都在这里被吸收」

### [轻微][存量] `runServerWith` 两个 `catch` 体完全相同，其中一个不可区分

- **位置**：`fmq/src/main.cj:121-129`
- **来源**：存量
- **判据**：review-checklist §2（重复逻辑）/ §1（兼容残留）
- **证据**：静态确定 —— `catch (e: MQConfigException) { eprintln(...); return 2 }` 与 `catch (e: Exception) { eprintln(...); return 2 }` 逐行一致；`MQConfigException <: Exception`（`MQConfig.cj:26`），单靠第一个 catch 无法产生任何不同行为
- **描述**：两段并行 catch 只增加阅读成本；若将来要给配置错误换成专属退出码或前缀，两处必须同步改，容易漂移
- **建议**：保留一个 `catch (e: Exception)`；确需区分时再按类型分支并在文案/退出码上体现差异

### [轻微][存量] `MQAssignment.cj` 导入了未使用的 `HashMap` / `Map`

- **位置**：`fmq/src/meta/MQAssignment.cj:18`
- **来源**：存量
- **判据**：review-checklist §1（未使用的 import）
- **证据**：静态确定 —— 该文件只用到 `Array`、`MQTopic.isValid`、`MQTopicAssignment`，全文搜 `HashMap`/`Map` 只在第 18 行出现
- **描述**：纯冗余导入，`cjlint` 应能报出
- **建议**：删除该 import

### [轻微][存量] `MetaStore.close()` 只置位不生效，`isClosed()` 无人读取

- **位置**：`fmq/src/meta/MetaStore.cj:84`、`:560-564`、`:566-570`
- **来源**：存量
- **判据**：review-checklist §3（空实现 / 契约与实现不符）
- **证据**：静态确定 —— `closed` 字段全文件只有三处出现（声明 84、`isClosed` 读 562、`close` 写 568），且 `registerTopic`/`applyTopic`/`applyGroup`/`writeAtomically` 等写路径都不检查它；仓内搜 `meta.isClosed` 零命中（`MQServer.cj:229` 只调 `meta.close()`）
- **描述**：作为 `Resource` 实现，`close()` 语义上应让对象不再可用，实际关闭后仍可继续写盘、继续被快照。当前只在进程退出时调用，后果有限，但「关了还能写」与 `Resource` 契约相反，也让「关闭顺序」在代码上无从验证
- **建议**：要么在写路径入口 `if (closed) { throw ... }`（明确关闭语义），要么把 `close()` 注释成「无外部资源需要释放，仅置标记供用例断言」，并删掉未被读取的 `isClosed`（`Resource` 要求实现，则保留但在注释里说明用途）

### [轻微][存量] `readAll` 短读后静默返回零填充缓冲区

- **位置**：`fmq/src/meta/MetaStore.cj:910-929`
- **来源**：存量
- **判据**：review-checklist §11（错误处理缺失 / 静默）；§5（按文件大小预分配）
- **证据**：静态确定 —— `while (got < size)` 里 `n <= 0` 时直接 `break`，随后 `bytes`（初值全 0）原样返回，`got` 不再参与任何判断；调用方（`loadTopics`/`loadGroups`/`loadTombstones`/`loadRevision`/`loadNextStart`）只按「能否 decode」区分，无法知道读短了
- **描述**：文件在 `file.info.size` 与 `read` 之间被截断（并发写者、半写、外部操作）时，返回的是「真实前缀 + 零填充」，decode 可能成功并产出一个字段被清零的条目（例如 `Int64` 位点读出 0）。正常路径下 rename 是原子的，触发面窄，故按轻微处理；同时 `Array<Byte>(size, repeat: 0)` 完全信任本地文件大小，畸形/超大文件会直接按该尺寸分配
- **建议**：`got != size` 时返回 `None` 或抛异常（调用方已有「skip corrupted」分支），并把 `size` 与一个上限常量比较后再分配

### [轻微][存量] `NodeRegistry.close()` 置位后 `clientOf` 仍会新建连接，慢速关闭会泄漏句柄

- **位置**：`fmq/src/cluster/NodeRegistry.cj:106-128`（`clientOf`）与 `:218-234`（`close`）
- **来源**：存量
- **判据**：review-checklist §12.1（检查-然后-写入 / 生命周期不对称）、§11（资源释放不对称）
- **证据**：静态确定 —— `send()` 在 `:139` 读 `closed`，通过后进入 `clientOf`；`clientOf` 全程不检查 `closed`，在 `lock` 内遇到空槽就 `createClient`。`close()` 先把 `closed` 置真（`:219`），再取 `lock` 逐个关闭并清槽（`:222-233`）；若 `send` 在 `close` 清槽之后才拿到锁，它会为已关闭的注册表新建一个连接，而 `close()` 的幂等短路（`:219-221`）使得这个新连接永远不会被关闭
- **描述**：只在「关闭期间仍有线程在广播」时触发，后果是进程退出前多一个未关闭的 TCP 连接。不影响稳态正确性，但 `isClosed()` 为真而仍持有活连接，属生命周期语义不一致
- **建议**：`clientOf` 在 `lock` 内先判 `closed`（是则返回 `None` 或抛），`send` 据此直接返回 `None`；或把 `createClient` 的建连放到锁外并在建连后复查 `closed`（复查命中则立即关闭新连接）

### [轻微][存量] `markSeen` 的「检查-然后-触发回调」非原子，复活同步可能重复执行

- **位置**：`fmq/src/cluster/NodeRegistry.cj:171-189`（`:173-175` 为判定点）
- **来源**：存量
- **判据**：review-checklist §12.1（检查-然后-写入）
- **证据**：静态确定 —— `let previous = alive[index].load(); alive[index].store(STATE_ALIVE); if (previous != STATE_ALIVE) { callback() }` 三步之间没有锁也没有 CAS；两个线程同时 `send` 到同一节点且都成功时，都会读到 `previous != ALIVE` 并各自执行一次 `revivedCallback`
- **描述**：`AtomicInt64` 已经提供 `compareAndSwap`（同文件 `close()` 就用了 `AtomicBool` 的 CAS），这里却用 load/store 组合。后果是并发的两次全量反熵同步（`syncFromPeers`），数据有元数据锁保护、不会错乱，但会放大启动/恢复瞬间的同步风暴与日志
- **建议**：改为 `if (alive[index].compareAndSwap(previous, STATE_ALIVE))` 成功者才触发回调（`STATE_UNKNOWN/STATE_DEAD` 都需触发，可用一次 CAS 失败后重读重试）

### [轻微][存量] `MQConfig` 严格解析三份同形状实现，两个字符串项走非严格路径，字节量换算未查溢出

- **位置**：`fmq/src/config/MQConfig.cj:149-158`（`strictPort`）、`:160-169`（`strictInt64`）、`:171-180`（`strictDuration`）；`:92-102`（`segmentedLogDir`/`deadMsgDir`）；`:233`（`n * (1024 ** UInt64(shift))`）
- **来源**：存量
- **判据**：review-checklist §2（只改类型名的重复）、§11（缺少边界校验）
- **证据**：静态确定 —— 三个 `strict*` 函数体逐行同构：`Config.getString(key)` → `None` 返回 fallback → `Some(text)` 解析 → `Some` 取值、`None` 抛 `MQConfigException("${key} '${text}' is not X")`，差异只有解析函数与文案；`segmentedLogDir`/`deadMsgDir` 用 `Config.getString(...) ?? DEFAULT`，与文件头注释「显式配置项非法时启动失败（A63）」以及 `validate()`（`:277-352`）的严格姿态不一致，且 `validate()` 不校验这两个目录；`parseByteSize` 的乘法在 Int64 上无溢出检查，`mqServer_segmentedLogMaxSize=9999999999999999999P` 之类会回绕成任意值（`validate` 只挡 `<= 0`，回绕成正数即静默生效）
- **描述**：三份同构函数本身可维护性一般；真正的行为缺口是「空串目录被接受」（`Config.getString` 原样返回值、不做空值归一，见 `f_config/src/Config.cj:186-198`，因此 `--mqServer_segmentedLogDir=` 这类写法会拿到 `Some("")` 而不是 `None`，`??` 不生效，最终得到空路径；空串是否真的被写入参数表取决于 `f_config` 的解析，属 `待确认`）与「字节量回绕」。两者都属启动期配置健壮性，后果是数据写到意外位置或段上限变成非预期值
- **建议**：抽一个 `private static func strict<T>(key: String, fallback: T, parse: (String) -> ?T, kind: String): T`（错误文案按 `kind` 参数化，保留现有三处文案的差异）；目录项改为 `strictString`（空串视为非法）并纳入 `validate()`；`parseByteSize` 用 `Int64` 上界检查或改为 `checked` 乘法后再返回

### [轻微][存量] `MetaStore.registerTopic` 用 `Conflict` 表达「参数非法」，与枚举注释冲突

- **位置**：`fmq/src/meta/MetaStore.cj:225-227`
- **来源**：存量
- **判据**：review-checklist §11（语义与命名/注释不符）
- **证据**：静态确定 —— `Conflict` 的注释是「同 revision 同 origin 但内容不同的冲突」（`:31`、`:290-294` 的真实用法），而 `:225-227` 在 `queueNum < 1 || nodeCount < 1` 时也返回 `Conflict`；`MetaStore` 已有专表「载荷结构非法」的 `Invalid`（`:35`）
- **描述**：调用方 `MetaSyncer.registerTopic`（`:136-137`）对 `_` 统一映射成 `INTERNAL`，因此「`queueNum=0`」这条本应是 `INVALID_TOPIC` 的请求会被报成服务端内部错误。当前上游已在下界处先拦（`MetaSyncer.cj:117`），实际不暴露，但语义分层已经错位
- **建议**：改成 `MetaApplyResult.Invalid`，并在 `MetaSyncer` 的 `Invalid` 分支映射为 `INVALID_TOPIC`

### [轻微][存量] `AtomicFile.isUnsupportedFsync` 靠错误消息子串判定平台能力

- **位置**：`fmq/src/meta/AtomicFile.cj:99-103`（使用点 `:88-95`）
- **来源**：存量
- **判据**：review-checklist §11（错误分类依赖文案）
- **证据**：静态确定 —— 判定逻辑是 `e.message.toAsciiLower()` 是否包含 `not support` / `unsupported` / `operation not permitted` / `invalid argument`；异常类型、errno 均未参与
- **描述**：把 `EPERM`（真实权限问题）归为「平台不支持」会只记 DEBUG 并继续，掩盖权限故障；反之，若某平台/语言环境给出不同措辞（例如 `Is a directory`），目录 fsync 会被当成致命错误，让全部元数据写入失败。当前在已测平台上行为正确（`AtomicFile_test.cj:130-135` 固定了四条文案），跨平台/本地化下属 `待确认`
- **建议**：优先按异常类型或 `errno` 判定；确无结构化错误可用时，把「平台不支持」的判定收窄到 `not support`/`unsupported`，`operation not permitted` 单独按 WARN 记录而不是静默跳过

### [轻微][存量] `send` 把「下标越界」记成「节点不可达」

- **位置**：`fmq/src/cluster/NodeRegistry.cj:142-150`
- **来源**：存量
- **判据**：review-checklist §11（错误信息误导）
- **证据**：静态确定 —— `try` 块内的 `clientOf(index)` 对 `index` 越界抛 `IllegalArgumentException`（`:110-112`），被同一个 `catch (e: Exception)` 捕获后 `markFailed(index)`（内部有边界保护，不会越界）+ `log.warn("send to node ${index} failed")`
- **描述**：调用方传错下标时，日志表现为网络故障，排查方向被带偏；`isKnownDead` 对越界下标返回 `true`（`:206-211`），进一步把编码错误伪装成「节点已死」
- **建议**：把越界检查移到 `try` 之外（或先做 `index` 范围校验再进 `try`），越界直接抛 `IllegalArgumentException` 给调用方

### [轻微][存量] 测试代码的可读性：蛇形命名与拼写错误、`ConfigSandbox` 的未使用命名参数

- **位置**：`fmq/src/cluster/MetaSyncer_test.cj:856`（`syncer_setup`）、`fmq/src/cluster/MetaSyncer_test.cj:504`（`concurrentRegisterThemeThrowsAlreadyExist`）、`fmq/src/config/MQConfig_test.cj:344`（`init(keys!: Array<String> = ALL_KEYS)`）
- **来源**：存量
- **判据**：review-checklist §1（读了不用：命名参数从未被传入）、通用维度「可读性/命名」
- **证据**：静态确定 —— 全仓搜 `syncer_setup` 只有定义与 `:848` 一处调用，是唯一非驼峰的方法名；`Theme` 应为 `Topic`（用例内注册的是 `MQTopicMeta`）；`ConfigSandbox` 的两处构造（`:32`、`:43`）都不传 `keys`，该参数无任何调用方
- **描述**：不影响正确性；`:856` 的辅助函数只是「新建 syncer 并 `syncFromPeers()`」，与其它用例内联写法并存，属可合并的小工具
- **建议**：改名为 `syncOnce`/`runSync` 并改为 `private static`；修正 `Theme → Topic`；删除 `keys!` 参数（或让「只保存部分键」的用例真的用上它）

## 优化可行性方案

### [CPU] MetaStore 单锁内做 fsync + 目录遍历，写盘时长直接落在临界区里

- **现状**：`MetaStore` 只有一把 `mutex`（`MetaStore.cj:77`），`registerTopic`/`applyTopic`/`applyGroup`/`applyTombstone`/`removeTopic`/`removeGroup`/`gcTombstones`/`advanceNextStart` 全部在 `synchronized(lock)` 内调用 `writeAtomically`（`895-897` → `AtomicFile.write`：写临时文件 + `flush`/fsync + `rename` + 父目录 fsync，`AtomicFile.cj:38-70`）；`removeTopic` 还在锁内做 `remove(groupDir, recursive: true)`（`696-707`），`gcTombstones` 在锁内 `exists`+`remove`（`518-527`）。同一把锁同时服务反熵/管理端的 `snapshot()`（`539-558`）与所有元数据变更。
- **方案**：把「序列化 + 写盘 + rename」移出临界区：锁内只做「判定 + 生成不可变目标状态 + 取版本号」，释放锁后写盘，再进锁做「版本仍是当前值则替换索引，否则丢弃」的比较替换；或按 topic 哈希分片成 N 把锁（`tombstones` 仍用全局锁）。
- **预期**：注册/广播路径的持锁时长从「ms 级 fsync」降到「map 操作」量级；`snapshot()` 不再排在 fsync 后面。
- **代价**：需要引入「版本校验 + 重试」，写盘失败要能回滚（与「写盘/改内存顺序」那条的修法同源）；`AtomicFile` 的「同路径临时文件」需要按写者区分（当前固定 `${path}.tmp`，并发写同一路径会互删临时文件）。
- **验证**：`cjpm bench -O2` 跑「N 个主题并发注册 + 30s 反熵」；同时用 `cjprof` 看 `synchronized` 的等待占比与 `AtomicFile.write` 自耗时；另采线程状态（BLOCKED 时长）——锁等待在 CPU profile 里看不到。
- **证据状态**：`无基线（待验证，不进 tasks）`

### [CPU] 每次版本分配都全表扫一遍 `maxRevisionLocked()`，N 个主题注册是 O(N²)

- **现状**：`nextRevisionLocked()`（`MetaStore.cj:779-784`）每次调用都执行 `maxRevisionLocked()`（`757-777`），后者遍历 `topicIndex`、`groups`（双层）、`tombstones` 三张表求最大值；`registerTopic`/`registerGroup`/`newTombstoneLocked` 每次变更都走一次，且都在锁内。
- **方案**：维护 `revision` 单调量即可——`load()` 时算一次初值，之后 `nextRevisionLocked` 直接 `revision + 1`（`applyTopic`/`applyTombstone` 收到远端更高版本时顺手 `revision = max(revision, remote)`）。
- **预期**：注册路径从 O(主题数+组数+墓碑数) 降到 O(1)；N 个主题批量注册的整体从 O(N²) 降到 O(N)。
- **代价**：需要一个「远端版本更高时更新本地位标」的集中点，漏一处会让墓碑 TTL/GC 的版本比较退化。
- **验证**：`cjpm bench -O2`，注册 1k / 10k 主题，比较总耗时中位数与 `maxRevisionLocked` 的自耗时占比。
- **证据状态**：`无基线（待验证，不进 tasks）`

### [CPU] `MQManagerOutput.table` 每个单元格算两遍显示宽度，且每次 `toRuneArray()`

- **现状**：`table()`（`MQManagerOutput.cj:145-170`）先为每个单元格调 `width()` 求列宽，`renderRow → pad()`（`131-142`）又对同一单元格再调一次 `width()`；`width()`（`119-129`）走 `text.toRuneArray()`，即每格两次 rune 数组分配。
- **方案**：`table()` 在求列宽的那一趟把 `(cell, width)` 缓存（或直接在此处构造已补齐的单元），`renderRow` 只做拼接，不再复算宽度。
- **预期**：渲染阶段 `width()` 调用量减半、rune 数组分配量减半。
- **代价**：多一份 `Array<Int64>` 级缓存，代码路径略增。
- **验证**：`fmq manager stats` 打 1000 主题 × 10 组的服务端输出，`cjprof` 看 `width`/`toRuneArray` 自耗时占比；`cjpm bench` 同输入对照。
- **证据状态**：`无基线（待验证，不进 tasks）`

### [CPU / 延迟] 复活回调在发送线程内同步跑完整反熵同步

- **现状**：`NodeRegistry.markSeen`（`NodeRegistry.cj:171-189`）在 `send()` 的调用线程里直接执行 `revivedCallback()`；生产装配是 `MQServer.cj:126` 的 `this.registry.onRevived = {=> this.syncer.syncFromPeers()}`，而 `syncFromPeers` 会对每个 peer 发一次带超时的请求（`MetaSyncer` 侧 `transport.send` → `transfer(..., pingTimeout * 5)`，`NodeRegistry.cj:143`）。也就是说一次「节点恢复」会把全量同步的耗时叠加到当前的广播/发布线程上。
- **方案**：回调改为投递到后台任务（专用单线程或多个 `spawn` + 去重标记），`markSeen` 只做状态翻转与置位；或者把 `onRevived` 语义改成「置脏标记，由反熵定时器下一轮消费」。
- **预期**：广播路径 P99 不再被同步等待拖长；重复复活不产生并发的全量同步。
- **代价**：补齐延迟（最长一个反熵周期）；需要去重，避免 flapping 节点刷爆同步。
- **验证**：两节点场景下 kill/restart peer，采 `send()` 的 P50/P99 与同步完成时间；线程状态确认发送线程不处于 WAITING。
- **证据状态**：`无基线（待验证，不进 tasks）`；回调重入导致的递归深度当前只在「同一次同步内失败后又成功」时成立，属 `待确认`，未计入缺陷。

### [堆内存] 全量快照每次都复制三张表

- **现状**：`snapshot()`（`MetaStore.cj:539-558`）在锁内把 `topicIndex`、`groups`（双层）、`tombstones` 全量复制进 3 个 `ArrayList` 再转 `Array`，随后 `MQMetaSnapshot` 持有；`topics()`（164-172）、`allGroups()`（175-185）、`allTombstones()`（463-471）同样全量复制。反熵每 `antiEntropyInterval`（默认 30s）走一次，管理端 `metaSync` 也走一次。
- **方案**：让 `snapshot()` 复用「写时复制」的不可变索引（每次变更生成新数组引用、原子替换），快照直接取当前引用而不复制；或按 revision 做增量快照（只带 `revision > peerRevision` 的条目）。
- **预期**：单次快照的临时对象从 O(条目数) 降到 O(1)（增量路径为 O(变更数)）。
- **代价**：写路径要维护不可变索引，内存占用略升（旧快照存活期间两份索引）；增量快照需要 peer 侧支持 `sinceRevision`，涉及协议变更。
- **验证**：`getAllocatedHeapSize()` + RSS 在 10k 主题稳态下跑 10 分钟，看每次反熵周期的分配尖峰是否消失；同时确认 `snapshot()` 耗时未退化。
- **证据状态**：`无基线（待验证，不进 tasks）`

## 待验证假设

> 无性能测试数据支撑，不进 `todo.md` / `tasks.md`。

| # | 假设 | 位置 | 缺什么数据 | 怎么采 |
| --- | --- | --- | --- | --- |
| 1 | 元数据单锁 + 锁内 fsync 是注册/同步的吞吐上限 | `fmq/src/meta/MetaStore.cj:228-242`、`895-897` | 单次持锁时长、BLOCKED 线程占比 | 20 线程并发 `registerTopic`，采线程状态 + `cjprof record`，对比 N=1/8/32 |
| 2 | `maxRevisionLocked` 全表扫描在主题数上千时成为注册热点 | `fmq/src/meta/MetaStore.cj:779-784` | 自耗时占比（N=1k/10k） | `cjpm bench -O2` 批量注册，分段计时 + `cjprof report` |
| 3 | `MQManagerOutput.table` 的重复宽度计算占 `stats` 渲染的主要耗时 | `fmq/src/manager/MQManagerOutput.cj:145-186` | 渲染耗时占比 | 1000 主题 × 10 组的 TSV 输入跑 100 次，`cjprof` 看 `width`/`toRuneArray` |
| 4 | 复活回调同步执行把广播 P99 拖长一个同步周期 | `fmq/src/cluster/NodeRegistry.cj:178-184` | `send()` P50/P99 与同步耗时 | 两节点，peer kill/restart 各 20 次，记录 `send` 延迟分布 |
| 5 | 反熵快照的全量副本造成周期性分配尖峰 | `fmq/src/meta/MetaStore.cj:539-558` | 每周期分配量 / GC 次数 | 加 `getAllocatedHeapSize()` 埋点，10k 主题稳态跑 10 分钟 |

## 文件覆盖

| # | 文件 | 类型 | 已读 | 说明 |
| --- | --- | --- | --- | --- |
| 1 | `src/cluster/MetaSyncer_test.cj` | .cj | ✅ | 28 个用例覆盖同步/墓碑/待应用队列；命名见「发现」最后一条 |
| 2 | `src/cluster/NodeRegistry.cj` | .cj | ✅ | 见 G-close、markSeen、复活回调三处 |
| 3 | `src/cluster/NodeRegistry_test.cj` | .cj | ✅ | 覆盖 successors/clientOf 重建/存活三态；`listeningSocket` 自建监听端口 |
| 4 | `src/config/MQConfig.cj` | .cj | ✅ | 严格解析三件套重复、字符串项非严格、字节量溢出（见发现） |
| 5 | `src/config/MQConfig_test.cj` | .cj | ✅ | 单用例串行覆盖全部配置语义；`ConfigSandbox.keys!` 未使用 |
| 6 | `src/main.cj` | .cj | ✅ | 恒假 `--help` 分支、双 catch 重复 |
| 7 | `src/manager/MQManager.cj` | .cj | ✅ | 响应分类四份近似逻辑（见 §2 说明）；连接生命周期 `try/finally` 正确 |
| 8 | `src/manager/MQManagerArgs.cj` | .cj | ✅ | 参数解析与子命令表一致，未发现缺陷 |
| 9 | `src/manager/MQManagerArgs_test.cj` | .cj | ✅ | 覆盖前后置 `--server`、操作数个数、帮助文本一致性 |
| 10 | `src/manager/MQManagerOutput.cj` | .cj | ✅ | 表格渲染重复算宽度（优化方案）；`columnOf` 兼容旧 11 列 |
| 11 | `src/manager/MQManagerOutput_test.cj` | .cj | ✅ | 覆盖 CJK 宽度、旧列数兼容、协议错误路径 |
| 12 | `src/meta/AtomicFile.cj` | .cj | ✅ | 写→fsync→rename→fsync(parent) 顺序正确；错误分类依赖文案（见发现） |
| 13 | `src/meta/AtomicFile_test.cj` | .cj | ✅ | 顺序/失败传播/无 tmp 残留；未覆盖「第二处写盘失败」 |
| 14 | `src/meta/LogCapture_test.cj` | .cj | ✅ | 测试日志捕捉器；`flush()` 空实现属合理 no-op |
| 15 | `src/meta/MQAssignment.cj` | .cj | ✅ | 无上限 `Array<Int64>(queueNum)`（严重）；未使用 import |
| 16 | `src/meta/MQAssignment_test.cj` | .cj | ✅ | 轮转分配用例覆盖单节点/回绕 |
| 17 | `src/meta/MQFileNames.cj` | .cj | ✅ | 百分号编码可逆、无碰撞；`unescape` 尾部残缺转义原样透传 |
| 18 | `src/meta/MQFileNames_test.cj` | .cj | ✅ | 可逆性与路径布局均有用例 |
| 19 | `src/meta/MetaStore.cj` | .cj | ✅ | 本部分主要风险集中地：锁内 I/O、半提交、墓碑键重复、close 无效果 |

合计：`.cj` 19 个 / `.md` 0 个 / 共 19 个，全部读完（本部分清单不含 `.md`，README 与 `doc/**` 的一致性由负责这些文件的部分覆盖）。

## 覆盖自检

| 维度 | 命中 | 未命中时的说明 |
| --- | --- | --- |
| 正确性 / 设计 / 语言特性 / 可读性 / 安全性 | 6 | 正确性：`MetaStore` 半提交（一般）、`readAll` 短读零填充、`NodeRegistry` 关闭竞态；设计：`MetaStore.close` 无效果、`send` 失败原因混同；安全性：`queueNum` OOM（严重）。可读性 2 条（双 catch、测试命名）与 §1/§2 行重叠，不在此重复计数；本部分无线程本地/值语义误用 |
| §1 死代码 | 2 | 逐个核对本部分全部非 public 符号并全仓搜引用：`MetaStore` 的 `dropTopicLocally`/`dropGroupLocally`/`allGroups`/`advanceNextStart`（`MetaSyncer.cj:429/440/433/448`）、`topicTombstone`、`gcTombstones`、`nextRevision`、`snapshot`、`allTombstones` 均有调用者；`NodeRegistry` 的 `onRevived`（`MQServer.cj:126`）、`markSeen`（`NodeRegistry.cj:144`）、`markFailed`（`:147`，另测试引用）、`clientOf`（`:143`）均有调用者；`MQConfig` 11 个配置属性全部被子 `MQServerOptions.cj:66-79` 消费，`helpText()` 被 `MQUsage.cj:42` 消费；`MQManager`/`MQManagerOutput`/`MQAssignment`/`MQFileNames`/`AtomicFile` 的每个 `private`/`protected` 成员均有用例或生产调用。命中 2 条：`main.cj:70-73` 恒假分支（`commandIndex` 由 `!startsWith("-")` 选出）、`MQAssignment.cj:18` 未使用的 `HashMap`/`Map` import。`public` 且对外可达的 `MetaApplyResult`、`MQManagerOutput.*`、`MQManagerArgs.*` 按硬原则一不判死代码（仓内均有引用） |
| §2 重复逻辑 | 2 | 函数体两两比对结果：`MQMetaTombstone` 键格式 6 处手写（已列）；`MQConfig` 的 `strictPort`/`strictInt64`/`strictDuration`（149-180）为同形状三份（差异仅在解析函数与错误文案，已合并列出）。另有一处**不判为缺陷**：`MQManager` 的 `registerTopic`(111-122)/`stats`(211-223)/`finish`(258-269)/`requestSnapshot`(277-290) 都做「None→连接失败、ERROR→printError」分类，但载荷类型与返回码路径不同（前两者需要取具体 payload），合并收益低于抽象成本，记为「实现漂移」而非重复。`MQAssignment.validate/validateStructure` 为包含关系，不是重复 |
| §3 空实现 | 1 | `CapturingStream.flush()`（`LogCapture_test.cj:48`）与 `ConfigSandbox.isClosed()` 返回 `false` 属测试替身合理 no-op，不判；命中 `MetaStore.close()`（560-570）：只置 `closed`，而 `closed` 在本文件之外零读取（全仓搜 `meta.isClosed` 零命中），关闭后仍可继续写盘 |
| §4 栈溢出 | 0 | 唯一的递归是 `MetaStore.walkFiles`（899-908），递归深度由 `metas/` 下的目录层数决定，而该布局固定为 `topics/`、`groups/<topicEsc>/`、`tombstones/`（`MQFileNames.cj:93-105`），目录名经百分号转义不含 `/`，故深度为常量 2；其余文件无递归、无自引用结构。`MetaSyncer_test` 的 `listeningSocket` 是 `while(true)` 循环不是递归 |
| §5 OOM | 1 | 命中 `queueNum` 无上限预分配（严重）；另核对：`readAll`（910-929）按 `file.info.size` 预分配本地元数据文件，属本机磁盘输入且无上限常量，仅作 §11 轻微记录；`MQManagerOutput.stats` 对服务端 TSV 全量 `split`，规模受元数据条目数约束，未定性 |
| §6.1 热点瓶颈 | 0 | 本部分无 `cjprof`/`cjpm bench` 数据，未提供任何自耗时占比与输入规模，「锁内 fsync」「全表扫版本号」「表格渲染」全部降级为「优化可行性方案（无基线）」+「待验证假设」 |
| §6.2 大粒度锁 | 0 | 定性证据齐全（临界区含 fsync/目录删除、竞争线程为广播+反熵+管理端），但缺「单次持有时长量级」，按铁律不作缺陷，写入优化方案第 1 条 |
| §6.3 并发串行 | 0 | `MetaStore` 单锁本身使元数据写入全序执行；`NodeRegistry` 每次 `send` 都要取全局 `lock` 做槽位查表（`NodeRegistry.cj:113`，锁外做 `transfer`），属「一把锁保护多个无关资源」形态，但无并行度/等待数据，未定缺陷 |
| §6.4 低效算法 | 0 | 已定位两处复杂度问题：`nextRevisionLocked`→`maxRevisionLocked` 每次 O(主题+组+墓碑)（N 次注册 O(N²)）、`dropGroupLocked` 每次删除重建整个组列表（`MetaStore.cj:709-729`，O(组数)）。无改前基线，未定为缺陷，前者写入优化方案；后者规模为单主题下组数（通常个位数），未单列 |
| §7 降堆内存方案 | 1 | `snapshot()/topics()/allGroups()/allTombstones()` 全量复制（优化方案，无基线），其余对象生命周期均为请求内局部量 |
| §8 降 CPU 方案 | 4 | 锁内 fsync、版本号全表扫、表格宽度重复计算、复活回调同步执行，均已标 `无基线（待验证）` |
| §9 local mode 可行性 | 0 | 本部分没有「函数内创建、函数内用完的大对象」：`MetaStore` 的临时 `ArrayList` 规模随元数据条目数增长且作为返回值逃逸（`snapshot()`/`topics()`），`MQAssignment.allocate` 的数组写入索引与磁盘，均不满足逃逸约束；无峰值内存对照数据，不提出改造建议 |
| §11 现有代码的 BUG（存量） | 4 | 逐函数核对了边界与空值：`MetaStore.removeTopic/removeGroup` 的「不存在返回空」、`gcTombstones` 的 TTL 边界（`<=` 保留、`>` 才回收）、`applyGroup` 的 `revision` 同值比较、`MQFileNames.unescape` 的 `i + 2 < size` 均正确。命中：半提交（一般）、`registerTopic` 用 `Conflict` 表达非法参数、`send` 把下标越界记成网络失败、`readAll` 短读零填充 |
| §12 并发安全与锁粒度 | 2 | 已列共享点与同步手段：`MetaStore.*` 全部走 `synchronized(lock)`（安全，但锁过大）；`NodeRegistry.alive` 用 `AtomicInt64`、`closed` 用 `AtomicBool`（安全）；`clients` 数组全部在 `lock` 内读写（安全）。命中：`markSeen` 的「检查-然后-回调」非原子（可直接换 `compareAndSwap`）、`close()` 置位后 `clientOf` 仍会新建连接（`NodeRegistry.cj:106-128` 无 `closed` 判断） |
| §14 功能完备性与 README 覆盖 | 0 | 本部分无 `.md`，README 覆盖与文档一致性归入负责 `fmq/README*.md`、`fmq/doc/**` 的部分；本部分未发现「承诺了但没实现」的接线缺失（`MQConfig` 11 个配置项均有消费方，`MQManager` 7 个子命令均已接线） |
| 文件覆盖（§13 等） | 19/19 | 无缺失、无未读；`.md` 数量为 0，§13 在本部分无适用对象 |

## 模块统计

| 严重程度 | 数量 |
| --- | --- |
| 严重 | 1 |
| 一般 | 2 |
| 轻微 | 12 |
| 优化方案（堆内存 / CPU） | 1 / 4 |

## 总评

本部分是 fmq 的「元数据 + 集群节点表 + 配置 + 管理端」底座，工程化程度明显高于平均水平：写入路径统一 `.tmp + fsync + rename`、墓碑用 `(revision, origin)` 做 LWW 且双向收敛、坏文件只记 ERROR 不阻断启动、加载期还有 `convergeTombstonesLocked` 兜住崩溃窗口，`MetaStore`/`MetaSyncer` 两个用例文件合计 50+ 个场景（含并发注册、崩溃残留、乱序快照）。

阻塞项只有一个，但很实际：**`queueNum` 从请求载荷直达数组长度与队列目录数，没有任何上限**（`MQAssignment.cj:37`）。服务端无鉴权，一条 REGISTER 就能把进程打到 OOM，且分配发生在元数据锁内，会连带打死同步路径。建议作为本模块唯一的必修项排期。

其余风险集中在「一致性顺序」而非逻辑错误：`applyGroup` 与 `registerTopic` 的「内存先行」会让写盘失败留下幻影状态（重启后回退），与同文件另外两条「先盘后内存」的路径自相矛盾；墓碑键格式 6 处手写、`MQMetaTombstone.key()` 闲在一旁，是典型的「今天一致、改一次就静默复活已删条目」的隐患。

性能面没有可用的基线，因此 `MetaStore` 的单锁 + 锁内 fsync、`maxRevisionLocked` 的全表扫、复活回调的同步执行都只写成优化方案与待验证假设，未计入缺陷——这几条如果要推进，第一件事是补 `cjprof` + 线程状态数据，而不是先改代码。

轻微项（死分支、未使用 import、双 catch、`close()` 无效果、错误文案分类、测试命名等）可以随下一次顺手清理。存量发现 15 条（1 严重 / 2 一般 / 12 轻微），是否纳入修复待用户决定。
