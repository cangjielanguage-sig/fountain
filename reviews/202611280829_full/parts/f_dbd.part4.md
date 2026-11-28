# f_dbd 模块审查报告（第 4/4 部分）

- **审查日期**：2026-11-28
- **模块路径**：`f_dbd`（模块共 49 个源文件；本部分 4 个）
- **基线**：工作区快照（`sts/1.3.x`，HEAD `8c0ce643a`；`git status` 仅未跟踪的审查产物目录，无源码改动 ⇒ 本部分全部记「存量（快照模式无基线）」）
- **审查重点**：多数据源测试 / URL / 占位符的正确性、死代码、重复逻辑、空实现、存量 BUG
- **报告版本**：v1（第 4/4 部分；本部分只覆盖下方 4 个文件，结论需与 part1 / part2 / part3 合并成模块报告）

## 发现

### [轻微][存量] `MultiDUrl.database` 与 `DbdUrl.database` 口径不一致（`?` 未截断、`%XX` 未解码）

- **位置**：`f_dbd/src/multid/Url.cj:58`（原始路径段直接作为 database）、`:114-119`（`firstSegment` 只按 `/` 截断）、`:93-99`（原样拼回节点 URL）；对照 `f_dbd/src/driver/DbdUrl.cj:67`（先 `firstSegmentOf` 再 `percentDecode`）、`:165-177`
- **来源**：存量（`git blame` 全部为 `ef7b9b06`，2026-10-18；快照模式无基线）
- **判据**：review-checklist §2（近似重复、边界不同导致语义漂移）/ §11（同一 URL 的两个 public 类型给出不同库名）
- **证据**：静态确定 —— `MultiDUrl.parse('multidbm://h/db?charset=utf8')` 的 `database` 为 `'db?charset=utf8'`，而 `nodes[0].database` 为 `'db'`；`.../db%20x` 时 `MultiDUrl.database == 'db%20x'`、`nodes[0].database == 'db x'`。`MultiDatasource` 只用 `parsed.nodes`（`Datasource.cj:45-51`），所以不影响建连；但 `MultiDUrl.database` 是公开字段（README.md:28 明确列出 `database`），调用方拿它做诊断、日志或二次拼连接串时会得到错误库名，且 `MultiDUrl` 自己的用例只覆盖了 `/db0/extra`（`MultiD_test.cj:151-156`）。
- **描述**：同一份「首个路径段」规则在 `DbdUrl` 与 `MultiDUrl` 各写一份，`DbdUrl` 会截断 `?`、`/` 并做 `%XX` 解码，`MultiDUrl` 只截断 `/`、不解码。part3 #11 已记录 `?` 分支；本条补充 `%XX` 分支，二者同根因，合并时只计一次即可。
- **建议**：把「路径首段 + 解码」抽成 `f_dbd.common` 的包内函数（`?` / `/` / `#` 统一截断并 `percentDecode`），`DbdUrl` 与 `MultiDUrl` 共用；或 `MultiDUrl.parse` 直接取 `nodes[0].database`（同一次解析的结果）；补 `?` 与 `%20` 两个用例。

### [轻微][存量] `MultiDUrl.parse` 的 `nodes.isEmpty()` 分支不可达（死代码）

- **位置**：`f_dbd/src/multid/Url.cj:74-76`
- **来源**：存量（快照模式无基线）
- **判据**：review-checklist §1（恒假分支 / 不可达语句）
- **证据**：静态确定 —— `nodesPart` 已在 `:62-64` 判非空；`nodesPart.split(',')` 对非空串至少产生一段，每段经 `trimAscii()` 后为空会在 `:68-71` 抛 `CONFIG`，非空段必然 `nodes.add(...)`。循环结束时 `nodes.size >= 1` 恒成立，`:74` 的条件永远为假。
- **描述**：该检查是「节点数 0」契约的重复兜底，但实际不可达，会让人误以为存在「非空 nodesPart 却解析出 0 个节点」的路径。
- **建议**：删除 `:74-76`；若想保留防御，用 `assert(!nodes.isEmpty())`（不进入运行期分支），并在 `:62` 处注释「nodesPart 非空 ⇒ 至少一个节点」即可。

### [轻微][存量] 测试把 `ConnectTimeout` 与 `MaxWaiting` 设成同一个值，掩盖了 `MaxWaiting` 不生效的存量 BUG；负权重契约也未钉死

- **位置**：`f_dbd/src/multid/MultiDatasource_test.cj:149-161`（`useConfig` 同时写 `multidbm_databasePoolConnectTimeout` 与 `multidbm_databasePoolMaxWaiting`）、`:105`、`:130`（用例调用点）
- **来源**：存量（快照模式无基线）
- **判据**：review-checklist §11（测试未覆盖宣称的契约）/ §14.1（配置项读了却没用）
- **证据**：静态确定（代码路径）＋需实测（当前是否已掩盖可观测失败）—— 借用等待实际只取 `connectTimeout`：`f_dbpool/src/DatabasePool.cj:224` 的默认参数是 `connectTimeout`，`:242` 的 `connect()` 不传超时；`f_pool/src/KeyPool.cj:764` 只在 `timeout == Duration.Max` 时才用 `maxWaiting`。`useConfig` 把两者写成同值，`poolExhaustionAndClose` 只断言 `TIMEOUT`、不断言耗时归属，因此无论 `MaxWaiting` 是否接线都会通过。part3 #3 已报该 BUG；这条测试正是它未被早期发现的原因之一。
- **描述**：`useConfig` 的形参名为 `maxWaiting`，实际起决定作用的是 `connectTimeout`，名实不符；同时 `effectiveWeights` 对负权重有明确拒绝分支（`Datasource.cj:179-182`），但本文件没有用例覆盖（只测了个数不符 / 全 0 / 未知算法）。
- **建议**：拆成两条用例钉死契约 —— ①`ConnectTimeout` 小、`MaxWaiting` 大，断言仍在 `ConnectTimeout` 内失败（记录现状）；或按修复后的语义改成 `ConnectTimeout` 大、`MaxWaiting` 小，断言 `TIMEOUT` 且耗时接近 `MaxWaiting`（修复 part3 #3 后启用）；②补 `useConfig('roundrobin,-1,2')` → `CONFIG` 的用例。形参改名 `borrowWait` 或在注释里写明它写的是哪两项。

### [轻微][存量] 测试共享全局 `Config`，用例间残留 `loadbalance='bogus'` 等状态，存在顺序依赖

- **位置**：`f_dbd/src/multid/MultiDatasource_test.cj:85-100`（`finally` 只关桩，不还原配置）、`:149-161`（只覆盖 9/13 个 `multidbm_*` 键）；受影响方 `f_dbd/src/multid/MultiD_test.cj:194-205`（`openAcceptsBothSchemes` 未设置 `loadbalance`）
- **来源**：存量（快照模式无基线）
- **判据**：review-checklist §11（测试隔离）/ §12.1（共享可变状态；若用例并行执行则构成竞争）
- **证据**：静态确定（状态残留）＋需实测（`cjpm test` 的实际执行顺序与是否并行）—— `Config.set` 按 key 覆盖写入、不清理其它 key（`f_config/src/Config.cj:107-129`）；`invalidWeightsOrAlgorithmAreConfigErrors` 的最后一次写入是 `('multidbm_loadbalance', 'bogus')`，且 `finally` 未恢复。若 `MultiDatasourceTest` 先于 `MultiDTest` 执行，`MultiDTest.openAcceptsBothSchemes` 的 `open()` 会在 `algorithmOf` 处抛 `CONFIG`，而不是返回 `MultiDatasource`。另有 `IdleTimeout=5s` / `ConnectionLife=3600s` / `CheckInterval=120s` / `CheckSql='select 2'` 来自 `MultiD_test.cj:33-47`，`useConfig` 未覆盖这 4 个键。
- **描述**：注释「写一组确定的池/负载均衡配置（避免用例间顺序影响）」只对 `useConfig` 列出的键成立；它既受其它用例残留影响，也把非法 `loadbalance` 留给后续用例。`Config` 是进程级 `ConcurrentHashMap`，即使内存安全，逻辑上也会互相踩。
- **建议**：`useConfig` 补齐 13 个 `multidbm_*` 键；`invalidWeightsOrAlgorithmAreConfigErrors` 在 `finally` 里恢复一个合法 `loadbalance`（或 `Config.remove('multidbm_loadbalance')`）；更彻底的做法是在每个用例的 `finally` 用 `Config.remove` 逐个还原本次写入的键，避免依赖执行顺序。

### [轻微][存量] `MultiStub` 统计所有非 PING 请求却自称「CONSUME 条数」，且对 `UNSUBSCRIBE` 回 `RESP`

- **位置**：`f_dbd/src/multid/stub_test.cj:41-49`（无命令判断即 `hits.fetchAdd(1)` 并统一 `Message.resp`）、`:56-59`（`received()` 注释）
- **来源**：存量（快照模式无基线）
- **判据**：review-checklist §11（测试替身语义与命名 / 注释不符）
- **证据**：静态确定 —— `Server.start` 在调用 handler 之前就拦截了 `PING`（`f_net/src/server/server.cj:165-168`），因此 handler 会收到 `CONSUME` 与 `UNSUBSCRIBE` 两类；当前用例只发 `CONSUME`，所以 67/33 成立。但一旦新增游标用例：`UNSUBSCRIBE` 会被计入 `hits`（污染权重断言），且回 `RESP` 会让 `DbdTransport.unsubscribe` 抛 `PROTOCOL`（它期望 `ACK`，`DbdTransport.cj:74-80`）。
- **描述**：测试替身的契约比它声称的宽：名字是「收到的 CONSUME 条数」，行为是「收到的所有非 PING 报文数」；对关闭游标的响应命令也不对。
- **建议**：按 `request.command` 分支——只对 `Command.CONSUME` 计数；`UNSUBSCRIBE` 回 `Message.ack(request.id)`，其它命令回 `ERROR`（或 `None`）。若短期不打算支持游标，把 `received()` 改名为 `requests()` 并在注释里写明「不支持 UNSUBSCRIBE」。

### [轻微][存量] `freePortOf` 与 `driver/stub_fdbm_test.cj` 的 `freePort` 逐字重复（并继承同一个 TOCTOU）

- **位置**：`f_dbd/src/multid/stub_test.cj:66-77` vs `f_dbd/src/driver/stub_fdbm_test.cj:101-112`
- **来源**：存量（快照模式无基线）
- **判据**：review-checklist §2（只改函数名 / 注释的重复逻辑）
- **证据**：静态确定 —— 两段实现逐行一致（`bindAt: 0` → `bind()` → `localAddress` 取端口 → `close()`），连 `case _ => port = 0` 的静默兜底都相同。TOCTOU 已由 part3 #14 记录（探测 socket 关闭到 `Server` 重新 bind 之间端口可被抢），本条只记重复与兜底问题。
- **描述**：`driver` 与 `multid` 属于不同包，测试构建中无法互相引用 `internal` 函数，重复有一定客观原因；但两份会各自漂移（本次已出现命名不一致 `freePort` / `freePortOf`）。另外 `localAddress` 不是 `IPSocketAddress` 时返回 `0`，会让 `MultiStub.port = 0`：`Server` 实际绑定随机端口，客户端却连 0 端口，失败信息与真实原因完全无关。
- **建议**：抽到测试专用共享包（若 `cjpm` 测试构建支持跨包可见），否则在两处加交叉注释并统一命名；`case _ =>` 改为抛异常（或 `panic`），不要静默返回 0。

### [轻微][存量] `placeholder.cj` 仍是「阶段 0 仅建骨架」的过期说明，文件无任何声明

- **位置**：`f_dbd/src/multid/placeholder.cj:18-21`
- **来源**：存量（快照模式无基线）
- **判据**：review-checklist §13（文档过期）/ §1（无声明文件）
- **证据**：静态确定 —— 该文件只有 `package` 与一段包级文档注释，没有任何声明；`multid` 包已完整实现 `Config` / `Datasource` / `MultiD` / `Url` 及 4 个测试文件，「阶段 0 仅建骨架」与现状相反。该注释与 `driver/placeholder.cj`（part3 #13）是同一模板复制。
- **描述**：读者打开该文件会以为多节点驱动只有骨架；作为「包说明」它又缺少真正的入口清单。
- **建议**：删除该文件（包说明并入 `MultiD.cj` / `Datasource.cj` 的类注释），或改写成「包职责 + 入口（`MultiD` / `MultiDatasource` / `MultiDUrl`）+ 与 `driver` 包的区别」；与 part3 #13 一起处理。

## 跨部分合并项（不重复计分）

- `Url.cj:49-70,93-99`：解析异常消息把带明文口令的整串 URL 与节点串写进 `DbdException.message`，与 `DbdUrl` 的同类问题同根因 → 已由 **part3 #2** 记录（part3 明确写了「同根因在 `multid/Url.cj` 也存在」），合并修复、只计一次。
- `stub_test.cj:66-77` 的 `freePortOf` TOCTOU → 与 **part3 #14**（`driver/stub_fdbm_test.cj:102-112` 的 `freePort`）同根因，本条只计「重复逻辑」，TOCTOU 归 part3 #14。
- `Url.cj:114-119` 与 `DbdUrl.firstSegmentOf` 的口径漂移 → **part3 #11** 已记录 `?` 分支；本部分 #1 补充 `%XX` 未解码分支，建议合并为一条（按本条位置与建议修复）。

## 优化可行性方案

本部分无优化方案。理由：3 个文件是测试代码（不进生产路径），`Url.cj` 的解析只在创建数据源时执行一次，输入为连接串长度（典型 < 200 字节）、单遍 O(n)，无 profile / bench 数据可支撑任何 CPU 或堆内存收益结论；按规则不产出「预计降 X%」类方案。

## 待验证假设

| # | 假设 | 位置 | 缺什么数据 | 怎么采 |
| --- | --- | --- | --- | --- |
| 1 | 每个 `MultiStub` 的 `Server` 会创建 200 个 `Executor` 工作线程，且 `Server.close()` 不 `shutdown()`，测试进程的线程数 / 常驻内存随桩数量线性增长 | `f_dbd/src/multid/stub_test.cj:38`；`f_net/src/server/server.cj:46,188-211` | 测试进程线程数、`getAllocatedHeapSize()` / RSS 随桩数量的曲线 | 在 `cjpm test` 前后读 `/proc/self/status` 的 `Threads` 与 `VmRSS`；或写一个只建/关 100 个 `MultiStub` 的用例，记录两轮数据 |

## 范围外提示

- `f_net.Server` 的 `Executors`（200 个工作线程）在 `close()` 中未 `shutdown()`（`server.cj:46,209-211`）；本模块每个 `MultiStub` 建一个 `Server`，属 f_net 存量，建议在 f_net 报告中确认，不在本部分展开。
- `MultiDatasource` 在 `QueryTimeout` 超时后，`DbdTransport` 已自行断链，但应用 `connection.close()` 会把这条已断的连接归还池（`PooledConnection.close()`），默认 `checkOnReturning=false` 时不剔除，后续借用可能拿到死连接；根因在 `f_dbpool` / `DbdConnection`，非本部分文件，未展开（本部分 `setOptionReachesNodeDatasources` 只验证了超时映射）。
- 借用等待由 `ConnectTimeout` 而非 `MaxWaiting` 决定（part3 #3），本部分 #3 只记录「测试未钉死该契约」。

## 文件覆盖

| # | 文件 | 类型 | 已读 | 说明 |
| --- | --- | --- | --- | --- |
| 1 | `src/multid/MultiDatasource_test.cj` | .cj | ✅ | 6 个用例：67/33、100/0、随机容差、非法权重/算法、池耗尽与关闭、setOption 转发；见 #3、#4 |
| 2 | `src/multid/Url.cj` | .cj | ✅ | `MultiDUrl` 解析 / 双 scheme / 节点解析；见 #1、#2，凭据泄漏合并至 part3 #2 |
| 3 | `src/multid/placeholder.cj` | .cj | ✅ | 仅包级注释，内容过期；见 #7 |
| 4 | `src/multid/stub_test.cj` | .cj | ✅ | `MultiStub` 测试桩 + `freePortOf`；见 #5、#6 |

合计：`.cj` 4 个 / `.md` 0 个 / 共 4 个，全部读完（本部分范围；模块其余 45 个文件由 part1 / part2 / part3 覆盖）。

## 覆盖自检

| 维度 | 命中 | 未命中时的说明 |
| --- | --- | --- |
| 正确性 / 设计 / 语言特性 / 可读性 / 安全性 | 3 | 正确性/契约 #1、#4；安全性 1 条为 `Url.cj` 凭据进异常消息（与 part3 #2 同根因，见「跨部分合并项」，不重复计分）。逐行核对了 `Option`（`schemeRest` / `indexOf` / `tryParse` 均被 `match` 或 `catch` 消费）、`Array` 别名（`MultiDatasource` 只读 `parsed.nodes`）、`AtomicInt64` 用法与测试断言类型，未发现语言特性误用 |
| §1 死代码 | 2 | 逐个符号搜引用：`MultiDUrl.SCHEME_BM/SCHEME_BD`、`parseNode`、`schemeRest`、`firstSegment`、`MultiDUrl.parse/tryParse`、`MultiStub.port/received/close/hits`、`freePortOf`、`useConfig/twoNodeUrl/borrowAndCount` 均有引用（`MultiDUrl.tryParse` 被 `MultiD_test.cj:171` 使用；`freePortOf` 被 `MultiD_test.cj:200` 使用）；`nodes.isEmpty()` 恒假（#2）；`placeholder.cj` 无任何声明（#7）。对外可达的 `public`（`MultiDUrl` / `MultiDUrl.parse` / `tryParse` / `nodes` / `database`）不判死代码 |
| §2 重复逻辑 | 2 | 同文件内函数体两两比对：`parse` / `parseNode` / `schemeRest` / `firstSegment` / `tryParse` 摘要互不相同；跨文件比对命中 `firstSegment` 与 `DbdUrl.firstSegmentOf` 的边界漂移（#1）、`freePortOf` 与 `freePort` 逐字重复（#6）；`useConfig` 与 `MultiD_test` 的 `Config.set` 块键集不同（不算重复）；`MultiStub` 与 `StubFdbm` 能力不同（计数量 vs 报文记录），不判重复 |
| §3 空实现 | 0 | 全文件搜 `TODO` / `FIXME` / `Unsupported` / 空函数体均为 0；`MultiStub` 在 `respond=false` 时返回 `None<Message>` 是「服务端静默」用例的刻意行为并有注释；`catch (_: Exception)` 出现在 `MultiStub.init` 的 spawn 收尾，注释说明是 `close()` 带出 `accept()` 的正常路径，不吞业务错误 |
| §4 栈溢出 | 0 | 4 个文件均无递归 / 自引用结构；`MultiDUrl.parse` 是单层循环，`borrowAndCount` 是 while + 固定次数 |
| §5 OOM | 0 | 无全量物化：`MultiDUrl.parse` 的 `ArrayList` 上限 = 节点数（由 URL 长度决定，典型 < 10）；`MultiStub` 只保留 `AtomicInt64`，不保存报文；`Server` 队列有界（1024）；测试循环固定 100 次 |
| §6.1 热点瓶颈 | 0 | 未提供 profile / bench 数据；测试代码与一次性 URL 解析不构成热点结论，按规则不写入发现，仅将「每桩 200 线程」列入待验证假设 #1 |
| §6.2 大粒度锁 | 0 | 本部分无锁：`MultiStub` 用 `AtomicInt64`，`Url.cj` 无共享状态；测试串行借还 |
| §6.3 并发串行 | 0 | 无 `spawn` + 立即 `get`；`MultiStub` 的 `spawn` 只跑 `server.start` 循环，不等待结果 |
| §6.4 低效算法 | 0 | `MultiDUrl.parse` 为 O(URL 长度) 单遍；`borrowAndCount` 的 `ArrayList` 只按节点数增长；无嵌套扫描 / 热路径 `contains` |
| §7 降堆内存方案 | 0 | 测试辅助对象生命周期 = 用例；`MultiDUrl` 的节点数组是数据源存活的必要状态，规模与节点数同阶，无可证收益 |
| §8 降 CPU 方案 | 0 | `MultiDUrl.parse` 只在 `MultiDatasource` 构造时执行一次；无基线，不产出方案 |
| §9 local mode 可行性 | 0 | 本部分函数内临时对象为 URL 长度级（< 200 字节）的字符串 / 数组，且 `MultiDUrl` 结果要逃逸给 `MultiDatasource`，无峰值内存证据，不做改造评估 |
| §11 现有代码的 BUG（存量） | 6 | 本部分 7 条发现除 #2（属 §1）外均为存量；其中 #1（public API 口径漂移）、#3（测试掩盖配置 BUG）、#4（Config 残留）、#5（测试桩语义）、#6（重复 + 端口兜底）、#7（过期文件）归本维 |
| §12 并发安全与锁粒度 | 1 | `Config` 是进程级共享可变状态，测试无隔离（#4）；若 `cjpm test` 并行执行用例，`Config.set` 与 `MultiDatasource` 构造之间存在逻辑竞争。`MultiStub` 的 `hits` 用 `AtomicInt64`、`port` 不可变、`server` 在构造后只读，未发现共享可变状态无保护 |
| §14 功能完备性与 README 覆盖 | 1 | `multidbm_databasePoolMaxWaiting` 的契约在测试中未被钉死（#3）；README 已覆盖 `MultiDUrl.parse`（README.md:28）、`tryParse`（:176）、`MultiDatasource`（:26）、多节点 URL 形态（:59/:115），4 个文件的 public 声明无遗漏；`placeholder.cj` 的说明与实现相反（#7，归 §13） |
| 文件覆盖（§13 等） | 4/4 | 本部分 4 个文件全部读完；README / `doc/**` 的模块级核对归 part1~3 与合并报告，本部分只做与所辖文件相关的交叉核对（README:28、:59、:115、:176；设计 §6.2 在 `doc/详细设计.md:785-795`） |

## 模块统计

| 严重程度 | 数量 |
| --- | --- |
| 严重 | 0 |
| 一般 | 0 |
| 轻微 | 7 |
| 优化方案（堆内存 / CPU） | 0 / 0 |

## 总评

本部分代码整体质量良好：`MultiDatasource_test` 用真实 `Server<DataAny>` 桩断言「请求落在哪个节点」，把 `roundrobin,2,1` 的 67/33 与 `1,0` 的 100/0 钉成确定性用例，随机算法用宽容差只防「永远命中一个节点」，方向正确；`Url.cj` 的双 scheme、空节点、空库名、坏节点都统一映射成 `CONFIG`，异常契约清晰；`MultiStub` 的 `respond=false` 静默模式也让超时路径可测。没有发现栈溢出、OOM、空实现、并发不安全或对外契约缺失。

需要排期的集中在三处：①`MultiDUrl.database` 与 `DbdUrl.database` 的口径漂移（`?` 与 `%XX`），属公开 API 的静默错误（#1）；②测试自身共享全局 `Config` 且不还原，存在用例顺序依赖（#4），并用同值配置掩盖了 `MaxWaiting` 不生效的存量 BUG（#3）——这两条会让测试给出虚假信心；③测试桩 `MultiStub` 的统计/响应命令与注释不符（#5），新增游标用例时会立刻踩到。其余为死分支、重复的 `freePort`、过期 `placeholder.cj` 等可维护性问题。

存量缺陷共 7 条（轻微 7），是否纳入修复待用户决定；建议优先把 #1 与 #3 / #4 纳入本轮（改动小、直接提升契约可信度），并与 part3 #2 / #11 / #14 去重合并。
