# f_dbd 模块审查报告

> **模块第 5/5 部分**（本报告只覆盖 `files/f_dbd.part5.txt` 列出的 4 个文件，全部在 `src/multid`：`MultiDatasource_test.cj` / `Url.cj` / `placeholder.cj` / `stub_test.cj`。模块共 49 `.cj` + 20 `.md`，`README*.md` / `doc/**` 及其余 45 个 `.cj` 由第 1–4 部分产出；本部分编号独立，合并时以主 Agent 为准。`.md` 只作为取证判据被引用，不计入本部分覆盖。）

- **审查日期**：2026-11-28
- **模块路径**：`f_dbd`（本部分 4 个 `.cj`，0 个 `.md`；模块共 49 `.cj` + 20 `.md`）
- **基线**：工作区快照（`HEAD 97507061b`，`git status f_dbd` 干净、无源码 diff ⇒ 全部问题记「存量」，blame 落在 `ef7b9b06ee 2026-10-18`）
- **审查重点**：数据库驱动协议正确性（多节点 URL 解析口径）、类型映射（`DbdUrl` 复用）、资源与连接生命周期（测试桩的线程/端口资源）、死代码、重复逻辑、存量 BUG
- **报告版本**：v1（第 5/5 部分）

## 发现

### [一般][存量] #1 `MultiDUrl` 自造一套 `firstSegment`，与 `DbdUrl` 的 database 口径漂移（不解码、不切 query）

- **位置**：`f_dbd/src/multid/Url.cj:58`（`let database = firstSegment(rest[slash + 1..rest.size])`）、`Url.cj:113-119`（`firstSegment`）；对照 `f_dbd/src/driver/DbdUrl.cj:67`（`percentDecode(firstSegmentOf(...))`）、`DbdUrl.cj:165-177`（按 `?` 与 `/` 切）
- **来源**：存量（`git blame`：`ef7b9b06ee 2026-10-18`）
- **判据**：review-checklist §2（近似重复：复制了切分逻辑但少两步处理，属"近似重复 + 行为漂移"）、§11（契约与注释不符）
- **证据**：静态确定 —— `firstSegment` 只找 `/`，`DbdUrl.firstSegmentOf` 同时找 `?` 与 `/` 之后才 `percentDecode`；两条路径逐行比对过。
- **描述**：同一个 URL 会在两个 public 类型上得到两个不同的 `database`：
  - `multidbm://h1:1/db?x=1` → `MultiDUrl.database == 'db?x=1'`，`nodes[0].database == 'db'`；
  - `multidbm://h1:1/db%40x` → `MultiDUrl.database == 'db%40x'`，`nodes[0].database == 'db@x'`。

  `Url.cj:113` 的注释明确写"与 `DbdUrl` 的 database 口径一致：忽略后续 `/` 之后的部分"，`Url.cj:37` 写"逻辑库名（第一个路径段）"——实现两条都不满足（query 没切、也没解码）。仓内生产代码只用 `parsed.nodes`（`src/multid/Datasource.cj:45-52`，`database` 仅被 `MultiD_test.cj:132/155` 的用例断言读取），所以当前无连接层影响；但 `MultiDUrl.database` 是公开字段（`README.md:28` 明确列为对外能力），下游拿它做租户 / 路由判定会得到未解码且夹带 query 的值。附带一个错误归因问题：`multidbm://h/db%zz` 会报 `bad node 'h'`（`Url.cj:97-99`），真正非法的是库名，排查方向被带偏。
- **建议**：不要复制切分逻辑——把 `DbdUrl` 的 `firstSegmentOf` + `percentDecode` 提成 driver 包的内部工具（或给 `DbdUrl` 加一个 `fromParts` / `parseDatabase(text, url)` 入口）供 `multid` 复用；`'fdbm://'` 字面量（`Url.cj:95`）也一并收敛到 `DbdUrl` 的 scheme 常量/工厂，避免 scheme 改名时两处不同步。用例补 `db?x=1` 与 `db%40x`，断言 `url.database == nodes[0].database`。

### [一般][存量] #2 `MultiStub` 每个桩构造 200 个工作线程的 `Server`，`close()` 一个都不回收

- **位置**：`f_dbd/src/multid/stub_test.cj:38`（`Server<DataAny>(bindAt: p, checkDuration: Duration.second * 30, checker: {=> Message.ping()})`，未传 `executors`）
- **来源**：存量（`ef7b9b06ee 2026-10-18`）
- **判据**：review-checklist §11「资源不对称：构造申请、关闭不释放」、§5「长期持有」、§12.1「跨线程资源」
- **证据**：静态确定（机制链路完整）+ 需实测（线程数 / RSS / 用例耗时的影响量级）——
  - `f_net` 的 `Server` 默认 `executors!: Int64 = 200`（`f_net/src/server/server.cj:46`、`:110-118`）→ `Executors` 构造 `Array<Executor<T>>(200){_ => Executor<T>(q)}`（`f_concurrent/src/Executor.cj:26`），每个 `Executor` 的私有构造直接 `spawn { while (running.load()) { q.remove()() } }`（`Executor.cj:56-62`），即**构造即起 200 条线程**；
  - `Server.close()` → `doClose` 只做 `server.close()` + `checkTimer.cancel()` + 排空 `buffers`（`server.cj:191-211`），全仓搜 `executors.shutdown` 无 `f_net` 调用点；即使调用，`Executor.shutdown()` 也只置 `running` 标志，阻塞在 `q.remove()` 的线程仍不退出（`f_concurrent` 部分已单列此缺陷）。
- **描述**：桩只需要串行处理（`Server` 分发只走 `executors[0]`，`server.cj:169`），却继承了"生产 200 并发 handler"的默认值。本文件 6 个用例共建 10 个桩（`MultiDatasource_test.cj:33-34/51-52/69-70/86-87/106/131`）⇒ 单测试进程 2,000 条常驻线程；`src/driver/stub_fdbm_test.cj:46` 同形未传 `executors`，整个 `f_dbd` 测试进程会更大。这些线程不随 `close()` 退出，线程栈地址空间与调度器元数据随桩数线性增长；CI 线程上限低时可能在 `pthread_create` 上失败，或表现为进程 RSS 与调度开销抬升（具体量级见「待验证假设」1）。
- **建议**：桩构造改为 `Server<DataAny>(bindAt: p, checkDuration: ..., executors: 1, checker: ...)`（`executors` 是公开命名参数，一行改完）；`Server.close()` 里补 `executors.shutdown()` 属 `f_net` 范围，只记依赖不在此处展开。

### [轻微][存量] #3 `MultiDUrl.tryParse` 捕获 `Exception`，与 `DbdUrl.tryParse` 口径不一致

- **位置**：`f_dbd/src/multid/Url.cj:81-87`；对照 `src/driver/DbdUrl.cj:115-121`
- **来源**：存量（`ef7b9b06ee 2026-10-18`）
- **判据**：review-checklist §2（同语义两实现只改一个细节）、§11（错误处理：静默吞掉）
- **证据**：静态确定 —— `MultiDUrl.tryParse` 是 `catch (_: Exception) { None }`；`DbdUrl.tryParse` 是 `catch (_: DbdException) { None }`。
- **描述**：两个 `tryParse` 是同一套 API 形状（非法 URL → `None`），但一个只吞契约异常、一个吞掉全部 `Exception`（含切片越界之类解析器自身缺陷）。`MultiDUrl.parse` 内部还会调 `DbdUrl.parse`（`Url.cj:93-100`），后者已经保证非法输入只抛 `DbdException`，所以宽捕获没有收益，只会把"解析器写错了"伪装成"输入非法"。
- **建议**：改为 `catch (_: DbdException)`，与 `DbdUrl` 对齐；若确要兜底，至少 `logger.warn` 记一条再返回 `None`。

### [轻微][存量] #4 `MultiDUrl.parse` 的 `nodes.isEmpty()` 分支不可达

- **位置**：`f_dbd/src/multid/Url.cj:74-76`
- **来源**：存量（`ef7b9b06ee 2026-10-18`）
- **判据**：review-checklist §1（不可达语句）
- **证据**：静态确定 —— 走到 `:74` 时 `nodesPart` 已非空（`:62-64` 抛过）；std 文档 `core_package_structs.md` §`func split(String, Bool)` 写明"原字符串为空时返回长度 0；分隔符未出现（原串非空）时返回长度 1"，故 `split` 至少产出一段；空段在 `:67-71` 已抛 `CONFIG`，因此循环体至少 `nodes.add(...)` 一次。
- **描述**：死分支，且错误文案与 `:62-64` 的 "node list is empty" 重复；读代码时要多推一遍"节点数 0"到底由谁负责。
- **建议**：删除该 `if`，节点数为 0 由 `nodesPart.isEmpty()` 一条判定承担。

### [轻微][存量] #5 `freePortOf` 的"探测-关闭-再绑定"窗口，以及非 IP 地址时静默返回 0

- **位置**：`f_dbd/src/multid/stub_test.cj:67-77`
- **来源**：存量（`ef7b9b06ee 2026-10-18`）
- **判据**：review-checklist §11（边界 / 资源）、§2（与 `src/driver/stub_fdbm_test.cj:102-112` 的 `freePort` 逐行同构；该重复已在第 4 部分 #7 记录，合并时保留一条，本部分补位置与差异）
- **证据**：静态确定（窗口存在、`case _ => port = 0` 的兜底路径存在）+ 待确认（并行测试下的实际冲突率）
- **描述**：`bind(0)` → 读端口 → `close()`，之后 `Server` 才 bind 同一端口，中间任何进程（包括并行的另一个测试类）都能占走它，`Server` 构造直接抛 `SocketException`，用例报"连接失败"而不是"端口冲突"。`match (probe.localAddress)` 的 `case _ => port = 0` 会把不可用地址静默变成端口 0，URL 成 `127.0.0.1:0`，错误再延后到 `connect()`，排查更远。
- **建议**：非 `IPSocketAddress` 直接 `throw`（或 `@Fail`），不要回 0；消除窗口的办法是让 `Server` 接受 `bindAt: 0` 并对外暴露实际监听端口，或在 `MultiStub` 构造失败时重试 1–2 次。两份 `freePort` 若要合并，需要先有 `driver` / `multid` 共用的 internal test-util（跨包不能直接复用 `private`）。

### [轻微][存量] #6 `useConfig` 只覆盖 9 个 `multidbm_*` 键，且与 `MultiD_test.cj` 各写一份字面量

- **位置**：`f_dbd/src/multid/MultiDatasource_test.cj:149-161`；对照 `src/multid/MultiD_test.cj:33-47`、`src/multid/Config.cj:30-42`
- **来源**：存量（`ef7b9b06ee 2026-10-18`）
- **判据**：review-checklist §2（字面量复制：同一批配置键散落两处）、§11（注释与实现不符）
- **证据**：静态确定 —— `useConfig` 写 9 个键（loadbalance / InitSize / MinSize / MaxSize / 三个 CheckOn* / ConnectTimeout / MaxWaiting），`MultiDConfig` 共 13 个键，漏 `IdleTimeout` / `ConnectionLife` / `CheckInterval` / `CheckSql`；`MultiDConfigTest.readsExplicitValues` 恰好把这四个写成 5s / 3600s / 120s / `select 2`。
- **描述**：注释写"写一组确定的池/负载均衡配置（避免用例间顺序影响）"，实际只确定 9 个：本文件用例随后建池时会继承前一个测试类留下的 4 个键（与第 4 部分 #13「全局配置不回滚」同根因，这里补"集合不全"这一面）。其中 `IdleTimeout=5s` 会直接影响"归还后连接是否被后台清理"，属于会改变被测行为、却不被本文件声明的输入。另一个后果是 13 个键名在两份测试里各写一遍，改键名时必漏一处。
- **建议**：把 13 个键收成一份测试常量表 / 一个 `multidConfigOf(loadBalance, maxWaiting)` 构造器，两个测试文件共用并全量赋值；键集合与 `MultiDConfig` 的常量同名引用（`MultiDConfig` 的常量是 `static const`，测试侧需要时提成可读的 public 常量）。

### [轻微][存量] #7 `MultiDatasourceTest` 未按 Step 4.4 用例矩阵覆盖，`setOption` 失效时表现为挂起而非断言失败

- **位置**：`f_dbd/src/multid/MultiDatasource_test.cj:127-145`（`setOptionReachesNodeDatasources`，单节点）、`:102-125`（`poolExhaustionAndClose`）、`:29-63`（分布用例）
- **来源**：存量（`ef7b9b06ee 2026-10-18`）
- **判据**：review-checklist §14（承诺源 + 缺失证据）、§11（测试有效性：用例不能在功能失效时给出失败信号）
- **证据**：静态确定 —— 承诺源 `doc/开发计划.md:295-299`（Step 4.4 用例矩阵）与实际用例逐条对照：
  - "两节点 → 两个 `DatabasePool`（`initSize=1` 时桩收到 2 条连接）"：无用例（所有用例 `InitSize=0`）；
  - "重复归还抛 `ConnectionException`"：无用例；
  - "`setOption` 转发到每节点（桩断言两次到达）"与"池建立后再调用不生效"：用例只有单节点（`:132` 的 URL 只有 `stub.port`），既证明不了"每节点"，也没有"建池后不生效"的对照；
  - 失败模式：若 `setOption` 不再转发，`query_timeout` 保持 `None` → `DbdStatement.cj:161-166` 取 `NO_TIMEOUT`（`DbdTransport.cj:32` = 6 小时），桩静默 → 用例卡 6 小时等框架超时，而不是给出断言失败（框架是否给单用例超时：待确认）。
- **描述**：该文件是 `MultiDatasource` 唯一的用例来源，缺口直接等于"多节点路由 / 池生命周期"没有回归网。另外 `@Assert(counts[0], 67)` 把"步长 1、累计权重桶 [1,3]"的实现细节钉成契约，而计划只要求"分布比例接近 2:1（统计断言，容差）"——把 `RoundRobin` 的 `min=1` 桶语义（`Datasource.cj:196-199`）一改，等价实现也会红。
- **建议**：给 `MultiStub` 暴露"每个节点收到的选项"（或对两个桩分别做"有超时/无超时"对照）补两节点 `setOption` 用例；补 `initSize=1` 的双连接计数、重复归还抛 `ConnectionException`、建池后 `setOption` 不生效三条；分布断言放宽成区间（例如 60–75 / 25–40）并保留"总数 = 100"，把"桶语义"钉点改成单独一条针对 `RoundRobin` 的用例。

### [轻微][存量] #8 `multid/placeholder.cj` 是空文件残留（只有版权头 + 一句"阶段 0 仅建骨架"）

- **位置**：`f_dbd/src/multid/placeholder.cj:1-20`
- **来源**：存量（`ef7b9b06ee 2026-10-18`）
- **判据**：review-checklist §1（零声明 / 兼容残留）
- **证据**：静态确定 —— 文件只有版权注释、`package fountain::f_dbd.multid` 与一段文档注释，零声明（与 `src/common/placeholder.cj`、`src/driver/placeholder.cj` 同形；后者已在第 4 部分 #8 记录）。
- **描述**：阶段 0 骨架占位，`multid` 包现在有 `Config` / `Datasource` / `MultiD` / `Url` 四个实现文件，占位已无意义；它唯一的作用是让包内文件清单多一项，容易被误认为"多节点还有未实现骨架"。
- **建议**：删除（三个 `placeholder.cj` 一起删，合并时与第 4 部分 #8 合并为一条）。

## 优化可行性方案

> 本部分没有改前/改后数据（`scope.md` 的「已有性能资料」是 `docs/LocalMode*.md`，与本部分的 URL 解析、测试桩无关），按铁律不出带收益数字的方案。唯一可执行的资源类改进已并入 #2（`executors: 1`），不单列。

## 待验证假设

> 没有 `cjprof` / `cjpm bench` 数据；下面两条只是线索，不构成热点或收益结论，不进 `todo.md` / `tasks.md`。

| # | 假设 | 位置 | 缺什么数据 | 怎么采 |
| --- | --- | --- | --- | --- |
| 1 | 每个桩 200 条常驻线程会抬升 `f_dbd` 测试进程的线程数与 RSS，并放大用例总耗时 | `f_dbd/src/multid/stub_test.cj:38`（`executors` 未传）；同类 `src/driver/stub_fdbm_test.cj:46` | 进程线程数峰值、RSS 峰值、`cjpm test` 总耗时 | 同机 `-O2` 下跑 `cjpm test`，改前记录 `/proc/self/status` 的 `Threads` / `VmRSS` 与总耗时；把两个桩改成 `executors: 1` 后同条件复跑，取 3 轮中位数 |
| 2 | 桩的每报文分发（`executors[0].call` + `ExecutorFuture` 的 `Mutex`/`Condition` 唤醒）在 100 次借还的分布用例里占比不可忽略 | `f_dbd/src/multid/MultiDatasource_test.cj:169-185`；`f_concurrent/src/Executor.cj:66-72` | 单条 `update` 的分段耗时（客户端发送 / 服务端 handler / 等待唤醒） | 在 `MultiStub` handler 与 `borrowAndCount` 两侧加计时埋点，跑 1 万次 update，输出 P50/P95；或 `cjprof record` 观察 `ExecutorFuture.complete` / 条件变量等待的占比 |

## 文件覆盖

> 与 `{workdir}/files/f_dbd.part5.txt` 一一对应（4 行）。

| # | 文件 | 类型 | 已读 | 说明 |
| --- | --- | --- | --- | --- |
| 1 | `src/multid/MultiDatasource_test.cj` | .cj | ✅ | 6 个用例（分布 / 零权重 / 随机 / 非法权重 / 池耗尽与幂等关闭 / setOption 超时）；用例矩阵缺口见 #7，配置键不全见 #6；断言与 `Datasource.cj` 的桶语义一致 |
| 2 | `src/multid/Url.cj` | .cj | ✅ | 双 scheme / 节点顺序 / 空库名 / 空节点的错误映射正确；database 口径见 #1、`tryParse` 捕获范围见 #3、不可达分支见 #4 |
| 3 | `src/multid/placeholder.cj` | .cj | ✅ | 零声明骨架残留；见 #8 |
| 4 | `src/multid/stub_test.cj` | .cj | ✅ | 回环桩（`Server<DataAny>`）+ 端口探测；线程资源见 #2、端口窗口见 #5；`PING` 由 `Server` 内置应答（`f_net/src/server/server.cj:165-168`），故 `hits` 只统计 `CONSUME`，67/33 计数口径成立 |

合计：`.cj` 4 个 / `.md` 0 个 / 共 4 个，全部读完。

## 覆盖自检

| 维度 | 命中 | 未命中时的说明 |
| --- | --- | --- |
| 正确性 / 设计 / 语言特性 / 可读性 / 安全性 | 3 | 正确性：#1（同一 URL 两个 database 值）、#7（用例失效时挂起）；可维护性：#6；设计：#2（测试桩继承生产并发度）；语言特性：`String.split` 的空段语义、`startsWith` / 字节切片均按 std 文档核对（`core_package_structs.md` §`func split(String, Bool)`），`?T` 与 `match` 用法符合惯用法；安全性：`parseNode` 只重建 URL 不拼 SQL，进程内无凭据进日志，本部分无外部输入落盘；`MultiDUrl` 的错误消息会回显整条 URL（含明文密码），与 `DbdUrl` 的既有做法一致（`DbdUrl.cj:58` 同形），不单列 |
| §1 死代码 | 2 | #4（`nodes.isEmpty()` 不可达，已用 std 文档证明 `split` 对非空串至少一段）、#8（`placeholder.cj` 零声明）。机械核对：`private` 符号 `firstSegment` / `schemeRest` / `parseNode` 均有文件内调用；`MultiStub`（非 public 类）的 `port` 被 `MultiDatasource_test.cj:107/132/165` 使用、`received` 被 `:182` 使用、`close` 被 6 个用例的 `finally` 使用、`hits` 在类内 handler 与 `received` 中使用；`freePortOf` 被 `MultiD_test.cj:200` 使用；`useConfig` / `twoNodeUrl` / `borrowAndCount` 均被本文件用例调用；4 个文件的 import 逐项核对，无未使用项；`MultiDUrl` 是对外可达的 public 类型，按硬原则一不判死代码 |
| §2 重复逻辑 | 4 | #1（`firstSegment` vs `DbdUrl.firstSegmentOf`）、#3（两个 `tryParse`）、#6（13 个配置键字面量跨测试文件各写一份）、#5 中的 `freePortOf` vs `driver/stub_fdbm_test.cj` 的 `freePort`（该条已计入第 4 部分 #7，合并时保留一条）。另核对：`MultiStub` 与 `StubFdbm` 都是 `Server<DataAny>` 桩，但职责不同（计数 vs 记录/脚本化应答），不合并；`MultiDatasource_test` 的三个 helper 与 `MultiD_test.cj` 的 `codeOf` 不是同一语义，不合并 |
| §3 空实现 | 0 | 4 个文件无 `TODO` / `FIXME` / `UnsupportedException`；`stub_test.cj:50-52` 的 `catch (_: Exception)` 有注释说明（`close()` 把 `accept()` 带出，属正常收尾），且随后无状态需清理；`tryParse` 返回 `None` 是契约本身（#3 判的是捕获范围，不是空实现）；`placeholder.cj` 是零声明文件，按 §1 计，不重复计入本节 |
| §4 栈溢出 | 0 | 无递归：`MultiDUrl.parse` 是直线扫描 + 单层循环；`parseNode` 只调一次 `DbdUrl.parse`（后者也无递归）；深度由 URL 段数决定且无自调用 |
| §5 OOM | 1 | #2（每桩 200 条常驻线程，10 个桩 = 2,000 条；有界但每实例放大 200 倍，且 `close()` 不回收）。其余容器有界：`nodes` / `nodesPart.split` 上界是 URL 字节数，`ArrayList<DbdUrl>` 一条节点一个元素；测试侧 `borrowAndCount` 固定 100 次 |
| §6.1 热点瓶颈 | 0 | 无 `cjprof` / `cjpm bench` 数据（本部分只有解析代码与用例）；两条线索（桩线程数、每报文分发开销）已进「待验证假设」，未当缺陷 |
| §6.2 大粒度锁 | 0 | 本部分代码无锁：`MultiDUrl` 纯函数；`MultiStub` 只有 `AtomicInt64`；`Server` / `Executors` 内部的队列与条件变量属 `f_net` / `f_concurrent` 范围 |
| §6.3 并发串行 | 0 | 每个桩只有一条 `spawn`（accept 循环），是按需起服务的必要形态，不是 `spawn` 后立刻 `get()`；用例串行借还连接，无批内并发 |
| §6.4 低效算法 | 0 | `parse` 对 URL 一次线性扫描；`firstSegment`/`schemeRest` 为 `indexOf` + 切片；`borrowAndCount` 线性 100 次；无嵌套循环匹配、无热点 `contains`、无 `remove(at: 0)` |
| §7 降堆内存方案 | 0 | 本部分没有可量化的对象生命周期问题（解析产物随 `MultiDUrl` 存活，属预期）；按铁律无基线不出方案 |
| §8 降 CPU 方案 | 0 | 同上，无基线数据；解析只在启动/建池前调用一次，不在请求主路径 |
| §9 local mode 可行性 | 0 | 逃逸检查不通过：`MultiDUrl` 的 `nodes` / `database` 要作为字段返回给调用方；剩余临时对象（`ArrayList`、`split` 结果）只在一次解析内存活但无峰值内存证据，收益无法证明，故不出方案 |
| §11 现有代码的 BUG（存量） | 8 | #1–#8 全部「存量」。本部分读到的其余边界已核对：`multidbm://h1:9001`（缺库名）、`multidbm://h1:9001/`（空库名）、`multidbm:///db0`（空节点列表）、`multidbm://h1:9001,,h2:9002/db0`（空节点）、`multidbm://:9001/db0`（缺 host）均按 `CONFIG` 抛出，与 `MultiD_test.cj:160-173` 的用例一致；端口越界 / 非数字由 `DbdUrl.parsePort` 兜住（`DbdUrl.cj:152-161`）；`parseNode` 已把 `DbdException` 包成带 cause 的 `CONFIG` |
| §12 并发安全与锁粒度 | 0 | 逐点核对：`MultiStub.hits` 用 `AtomicInt64`（`:32`，handler 线程写、测试线程读）；`server` / `port` 在 `init` 内先赋值（`:37-38`）再 `spawn`（`:39`），`this` 虽然在 `init` 返回前逸出到 accept 线程，但所有字段已就绪，无"构造未完成即发布"；`respond` 是不可变参数；`MultiDatasource_test.useConfig` 写的是进程级 `Config`（第 4 部分 #13 已记，是否并行执行待确认）；`MultiDatasource` 的共享状态不属本部分文件 |
| §14 功能完备性与 README 覆盖 | 1 | #7（Step 4.4 用例矩阵的 4 处缺口，承诺源 `doc/开发计划.md:295-299`）。产品侧接线无缺口：`MultiDUrl.parse/tryParse` 已在 `MultiD.open` → `MultiDatasource` 链路上生效（`Datasource.cj:45`），`MultiStub` 的 `PING` 依赖由 `Server` 内置满足（`server.cj:165-168`）；本部分无 `README` / `doc/**` 文件，README 覆盖归第 1 部分 |
| 文件覆盖（§13 等） | 4/4 | 无缺文件；本部分无 `.md`，§13 不适用。`doc/详细设计.md` §6.2（`MultiDUrl` 字段与形状）、`doc/开发计划.md` Step 4.2 / 4.4 仅作为判据引用 |

## 模块统计

| 严重程度 | 数量 |
| --- | --- |
| 严重 | 0 |
| 一般 | 2 |
| 轻微 | 6 |
| 优化方案（堆内存 / CPU） | 0 / 0 |

## 总评

本部分代码量小，质量基线不错：`MultiDUrl` 的双 scheme、节点顺序、空库名 / 空节点 / 缺 host 的错误映射都统一到 `CONFIG`，`parseNode` 用 `DbdException` 包 cause 保留了底层定位信息；`MultiStub` 用回环随机端口 + `AtomicInt64` 计数，避开了跨线程可见性问题，且正确利用了 `Server` 内置的 `PING` 应答（计数只含 `CONSUME`，67/33 的分布断言口径成立）；`MultiDatasource_test` 把"零权重节点不得覆盖前一桶"这条历史坑钉成了用例。

主要风险按优先级：

1. **#1 database 口径漂移**——`MultiDUrl` 复制了一份切分逻辑，少做"切 `?`"和"`percentDecode`"两步，同一个 URL 在 `MultiDUrl.database` 与 `nodes[i].database` 上得到两个值，且与自己的注释（"与 `DbdUrl` 口径一致"）矛盾。当前无仓内消费者，但它是对外 public 字段（README 明列），属"看起来对、下游判定会偏"的类型；修法是复用 `DbdUrl` 的同一份实现，改动很小。
2. **#2 测试桩 200 线程/桩**——测试进程资源随桩数线性放大、`close()` 不回收，是 CI 上最容易被忽略的成本项；`executors: 1` 一行可解，建议与 `driver` 的桩一起改。
3. **#6 / #7 用例与配置**——`MultiDatasource` 是模块里唯一"池 + 路由"的组装点，现有用例没覆盖双池、重复归还、建池后 `setOption`，`setOption` 失效还会表现成 6 小时挂起；补齐成本不高，收益是这条链路真正有回归网。

无严重项、无阻塞级缺陷。存量共 8 条（2 一般 + 6 轻微，含与第 4 部分 #7 / #8 同源的两条重复记录），是否纳入修复待用户决定。
