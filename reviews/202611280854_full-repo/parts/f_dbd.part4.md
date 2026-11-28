# f_dbd 模块审查报告

> **模块第 4/5 部分**（本报告只覆盖 `files/f_dbd.part4.txt` 列出的 20 个文件，全部是 `src/driver`（`DbdStatement` → `testkit_test`）、`src/exception`、`src/multid`（`Config` → `MultiD_test`）下的 `.cj`。模块共 49 `.cj` + 20 `.md`，`README*.md` / `doc/**` 及其余 29 个 `.cj` 由第 1、2、3、5 部分产出；本部分编号独立，合并时以主 Agent 为准。`.md` 只作为取证判据被引用，不计入本部分覆盖。）

- **审查日期**：2026-11-28
- **模块路径**：`f_dbd`（本部分 20 个 `.cj`，0 个 `.md`；模块共 49 `.cj` + 20 `.md`）
- **基线**：工作区快照（`HEAD 97507061b`，`git status f_dbd` 干净、无源码 diff ⇒ 全部问题记「存量」）
- **审查重点**：数据库驱动协议正确性（`CONSUME`/`UNSUBSCRIBE` 的载荷判别与 `qid` 匹配）、类型映射（`SqlDbType` → `SqlTypes.encodeParameter`）、资源与连接生命周期（`Statement` / `Transaction` / `Transport` / 多节点池）、死代码、重复逻辑、存量 BUG
- **报告版本**：v1（第 4/5 部分）

## 发现

### [一般][存量] #1 参数 index 没有上界，`sqlPayloadOf` 按最大 index 全量物化 —— 一个错误下标就挂死 + 吃光内存

- **位置**：`f_dbd/src/driver/DbdStatement.cj:64-73`（`set` / `setNull` 只调 `checkIndex`）、`DbdStatement.cj:168-172`（`checkIndex` 只挡 `index < 0`）、`DbdStatement.cj:249-265`（`sqlPayloadOf` 的 `while (i <= max)`）
- **来源**：存量（`git blame`：`29f2d7e88e 2026-11-22`，`DbdStatement.cj:249` 起整段）
- **判据**：review-checklist §5「按不可信长度预分配 / 一次性物化」、§6.4「已知规模却全量扫描」、§11「边界校验缺失」
- **证据**：静态确定 —— `checkIndex` 只判负数；`sqlPayloadOf` 先遍历参数表求 `max`，再 `while (i <= max) { parameters.get(i) ?? addNull() }`，循环次数与 payload 参数个数都等于 `max + 1`。`set(1_000_000_000, x)` 一次就会追加 10^9 个 `DataNone`，`set(Int64.MaxValue, x)` 则直接跑不完。
- **描述**：`set` 的 index 是调用方给的普通 `Int64`（f_orm 位置绑定、或业务代码里 `statement.set(i, v)` 的 `i` 累加）。把「行号 / 计数」错当参数下标（例如循环里忘了重置 `i`）不会报错，而是在执行时先卡在 `while` 里，再随 `SqlPayload.params` 的增长吃满堆；整条路径没有上限校验、没有拒绝分支、也没有日志。参数表本身也随 `max` 无界增长（`HashMap` 每条 entry 一个装箱 `Int64` 键 + 一个 `Data` 引用）。
- **建议**：在 `set` / `setNull` 里加显式上限（例如 `MAX_PARAMETERS = 65535`，与常见物理库的参数上限同量级），超限抛 `DbdException(DbdErrorCode.CONVERSION, 'parameter index ${index} exceeds ...')`；`sqlPayloadOf` 组装前再用同一上限兜一次（防止绕过 `set` 的路径）。用例补 `set(MAX_PARAMETERS + 1, x)` → `CONVERSION` 且不发包。

### [一般][存量] #2 `MultiDatasource.init` 逐个建池没有失败回滚：任一节点建池失败，先前池（连接 + 后台检查线程）没有关闭入口

- **位置**：`f_dbd/src/multid/Datasource.cj:74-90`（`for (datasource in datasources) { builtPools.add(DatabasePool(...)) }`），对照 `Datasource.cj:54-73` 的"先校验权重与算法再建池"注释
- **来源**：存量（`git blame`：`29f2d7e88e 2026-11-22`）
- **判据**：review-checklist §11「资源不对称：异常跳过释放」、§5「无界容器 / 长期持有」；fountain-baseline §5（资源生命周期）
- **证据**：待确认 —— 代码结构上确定：建池循环没有 `try/catch`，也没有"失败时把已建池 `close()`"的分支；`this.pools` 只在循环结束后才赋值（`:90`），因此中途抛异常时，已建池对象连一个可达引用都不会留下。缺的信息：`DatabasePool`（→ `f_pool.Pool` → `KeyPool`，`initSize` 默认 1）构造时是否同步建连、`creator`（`DbdDatasource.connect`）失败是抛出还是被后台线程吞掉。
- **描述**：第 2 个节点建池失败时，第 1 个池已经带着自己的 `PooledConnection`（每条一个 `f_net.Client`：1 条 TCP + 读写线程 + 30s 心跳）与池的检查线程存活，而 `MultiDatasource` 实例不会被返回给调用方 —— 这些连接与线程没有任何关闭入口。若构造阶段同步建连，则 `MultiDriver.open()` 会因单个节点不可达而整体失败（与 `DbdDatasource`「`open()` 不产生 IO、`connect()` 才建链」的口径也不一致）。
- **建议**：`let built = ArrayList<DatabasePool>(); try { ... } catch (e) { for (p in built) { try { p.close() } catch (_: Exception) { () } }; throw e }`；或把建池整体延后到首次 `connect()`（懒建池），让 `open()` 保持纯配置解析。

### [一般][存量] #3 连接级"结果集独占"闸门是检查-后-写入：两次 `query()` 可在同一临界区之间交叉，两个游标只登记一个

- **位置**：`f_dbd/src/driver/DbdStatement.cj:83-98`（`ensureExecutable()` 在 `:154` 过闸 → `connection.request(...)`（一次 TCP 往返）→ `openResult = result` → `connection.registerResult(result)`）；对照 `f_dbd/src/driver/DbdConnection.cj:124-135`（闸门）与 `DbdConnection.cj:137-142`（登记）
- **来源**：存量（`git blame`：`29f2d7e88e 2026-11-22`）
- **判据**：review-checklist §12.1「检查-然后-写入 / 并发正确性」、§6.2「用并发容器就当复合操作原子」的同类形态、§11「并发正确性」
- **证据**：静态确定（竞态窗口存在）+ 待确认（是否有多线程共用同一 `DbdConnection` 的调用方）—— `ensureNoOpenResult` 在 `Mutex` 内看不到 `activeResult` 就返回，锁随即释放；发包与写回登记发生在锁外。两个线程可以都通过闸门：服务端对每条 `CONSUME(SqlPayload)` 都会装一个新游标（`fdbm/src/server/handler.cj:104-107`），而客户端 `activeResult` 只留后者。
- **描述**：`DbdConnection.cj:28-35` 自己写明"`QueryResultColumnPayload` 不带结果标识，放任并发会让旧结果集的 `next/get` 静默作用到新游标上"，闸门就是为这条不变量设的；但闸门的判定与登记不在同一临界区，"至多一个未关闭结果集"这条不变量实际上没有被原子地维持。后果是两个结果集都拿到"可用"句柄，先建的那个后续 `next()/get()` 读到的是后建游标的数据（静默错行），且前者的 `close()` 会带自己的 `qid`，服务端按 `qid` 不匹配直接幂等 ACK（`handler.cj:154-155`），前一个游标既不关闭也不报错。与第 3 部分 #3（`close()` 与 `registerResult()` 的交错）根因相邻但交错不同：那条是"关闭期间被登记"，这条是"两次查询同时过闸"。
- **建议**：闸门改成"占位式"——`ensureNoOpenResult` 在同一临界区内写入一个 `pending` 标志（或直接把 `activeResult` 置成占位），`query()` 在 `finally` 里清占位/换真实结果；`update()`/事务 SQL 同样在 `finally` 清占位，保证异常路径不把连接永久锁死。用例：一个线程反复 `next()`、另一个线程反复 `prepareStatement().query()`，断言任一时刻只有一个结果集能 `get`，且两者最终都 `isClosed()`。

### [一般][存量] #4 `DbdTransaction` 的隔离级别 / 访问模式 / 可延迟性只记录不下发，设置后静默无效

- **位置**：`f_dbd/src/driver/DbdTransaction.cj:34-69`（三个 `private var` + 三个 `mut prop`）、`DbdTransaction.cj:72-78`（`begin()` 只发 `'begin'`）
- **来源**：存量（`git blame`：`29f2d7e88e 2026-11-22`）
- **判据**：review-checklist §11「契约与实现不符」、§3「接口承诺有行为、实现无下行效果」；std `Transaction.isoLevel` 的语义
- **证据**：静态确定 —— `accessModeValue` / `deferrableModeValue` / `isoLevelValue` 只在各自的 get/set 中出现（全文件搜索），`execute('begin')` 的 SQL 文本是常量 `'begin'`；`DbdTransaction_test.cj:29-51` 的用例名就叫 `propertiesAreRecordedNotTranslated`，正好把这个行为钉成了"预期"。
- **描述**：调用方写 `tx.isoLevel = Serializable` 再 `begin()`，实际下发的是不带任何级别修饰的 `'begin'`，物理库按默认级别开启事务；可重复读/串行化的假设全部落空，且没有任何 WARN 或异常。类注释与设计 §9 把它登记为"偏离"，但对只依赖 std API 的使用者仍是静默无效——事务语义错配是"数据看起来对、并发下不对"的典型来源。
- **建议**：至少在 `set` 到非 `Unspecified` 时打一条 WARN（"isolation level is not translated; put it in the SQL text"）；或在 fdbm 侧支持后按方言拼 `begin isolation level ...` / `set transaction ...`。README 的"事务三属性只记录不下发"一条已由第 1 部分报过（文档面），这里补的是代码面的建议。

### [轻微][存量] #5 未使用的 import（3 处）

- **位置**：`f_dbd/src/driver/DbdStatement.cj:23`（`DataAny`）、`DbdStatement.cj:25`（`QueryResultClosePayload`）、`f_dbd/src/driver/PayloadWrapping_test.cj:21`（`getGCCount`）
- **来源**：存量（`29f2d7e88e 2026-11-22`）
- **判据**：review-checklist §1「未使用的 import」
- **证据**：静态确定 —— 三个符号在全文件内只出现在 import 行（grep 逐符号确认）。`DataAny` / `QueryResultClosePayload` 是 payload 包装改造前的残留（旧写法是 `payload.add<DataAny>(DataAny(data))`，见 `PayloadWrapping_test.cj:30-47` 的 legacy 实现）；`getGCCount` 在 bench 辅助里没被调用。
- **描述**：残留 import 会让人误以为语句层仍在用 `DataAny` 包装参数，读代码时要多追一层。
- **建议**：删掉这三个被导入项。

### [轻微][存量] #6 测试桩里两个成员没有任何调用者（`StubFdbm.consumes()` / `StubFdbm.clear()`）

- **位置**：`f_dbd/src/driver/stub_fdbm_test.cj:80-88`（`consumes()`）、`stub_fdbm_test.cj:91-94`（`clear()`）
- **来源**：存量（`29f2d7e88e 2026-11-22`）
- **判据**：review-checklist §1「非 public 类型里的成员，全项目无使用即死代码」
- **证据**：静态确定 —— `StubFdbm` 是非 public `class`，两个成员默认 internal（包内可见）；在 `f_dbd` / `fdbm` / `fdbmdemo` 全仓 grep `consumes` / `.clear()`，`consumes()` 只有定义处一行，`clear()` 在 `f_dbd` 内无任何调用（命中的 `.clear()` 都在 `f_dbd/src/common/*` 与 `fdbm` 的其它类型上）。用例靠"每个用例新建一个 `StubFdbm`"实现隔离，没有走 `clear()`。
- **描述**：`consumes()` 的注释写着"Node站位用得到"，但没有任何用例用它；`clear()`（清空记录队列）也没被用上。两者都是"写了备用、最后没用"的残留。
- **建议**：删除；若想保留 `clear()`，就补一个"同一连接上分两阶段断言请求序列"的用例真正用它（比新建桩更贴近真实复用场景）。

### [轻微][存量] #7 重复逻辑：超时取值 / `codeOf` / 空闲端口探测 / URL 重建

- **位置**：
  - `f_dbd/src/driver/DbdStatement.cj:161-166`（`timeoutOf(configured: ?Duration)`）与 `f_dbd/src/driver/DbdTransaction.cj:113-116`（内联 `match (options.queryTimeout)`）——同一语义"未配置 → `NO_TIMEOUT`"两处实现；
  - `f_dbd/src/driver/testkit_test.cj:27-36` 与 `f_dbd/src/multid/MultiD_test.cj:209-218` —— `codeOf` 逐行同构（只差所在包）；
  - `f_dbd/src/driver/stub_fdbm_test.cj:102-112`（`freePort`）与 `f_dbd/src/multid/stub_test.cj:67-77`（`freePortOf`）——"bind 0 → 取端口 → close"，只差变量名；
  - `f_dbd/src/driver/DbdUrl.cj:124-131`（`toUrl`）与 `DbdUrl.cj:143-150`（`toUrlMasked`）——同一段拼串，只差密码那一段。
- **来源**：存量（`29f2d7e88e 2026-11-22`）
- **判据**：review-checklist §2（换控制流 / 只改名字 / 字面量复制）
- **证据**：静态确定（四组都逐行比对过）。差异点：`codeOf` 与端口探测分属两个包（`driver` / `multid`），跨包不能直接共享；`toUrl` 与 `toUrlMasked` 的输出差异是业务要求（脱敏）；超时取值两处差异仅在"是否包一层函数"。
- **描述**：`timeoutOf` 这类"未配置→6 小时哨兵"的换算散在两类调用点，将来改 `NO_TIMEOUT` 语义（例如改成 `Duration.Max`）很容易漏一处；`codeOf` / `freePort` 两份实现已经各自演进（`MultiD_test` 那份没有 `message` 版本），改一处不会同步另一处。
- **建议**：`?Duration → Duration` 提到 driver 包一个顶层 `func timeoutOrForever(?Duration): Duration`，两处共用；`codeOf` / 端口探测若要合并，需要建一个 internal 的 test-util 包（否则保留两份并在注释里互相指向）；`toUrl` / `toUrlMasked` 收成一个 `private func render(password: String): String`，两个 public 方法各传实参。

### [轻微][存量] #8 `driver/placeholder.cj` 是空文件残留（只有版权头 + 一句"阶段 0 仅建骨架"）

- **位置**：`f_dbd/src/driver/placeholder.cj:1-20`
- **来源**：存量（`29f2d7e88e 2026-11-22`）
- **判据**：review-checklist §1「兼容残留 / 无任何声明」
- **证据**：静态确定 —— 文件只有版权注释、`package fountain::f_dbd.driver` 与一段文档注释，零声明。
- **描述**：骨架阶段的占位文件，`driver` 包现在有 8 个实现文件，这个占位已无意义；它唯一的作用是让"包内文件清单"多一项，容易被误认为还有未实现的骨架。
- **建议**：删除（`f_dbd/src/multid/placeholder.cj` 同类，属第 5 部分）。

### [轻微][存量] #9 `MultiDConfig` 权重解析静默"纠正"配置：非数字段/空段被丢弃，权重悄悄漂移

- **位置**：`f_dbd/src/multid/Config.cj:70-83`（`getWeights` 的 `case None => ()`）、`Config.cj:168-177`（`segmentsOf` 丢掉空段）
- **来源**：存量（`29f2d7e88e 2026-11-22`）
- **判据**：review-checklist §11「错误处理缺失 / 静默」、§14.1「配置项写错不报」
- **证据**：静态确定 —— `multidbm_loadbalance=roundrobin,1,,3`（多打一个逗号）经 `segmentsOf` 得到 `['roundrobin','1','3']`；`roundrobin,1,x,3` 得到 `[1,3]`。两者在 2 节点时正好通过 `effectiveWeights`（`Datasource.cj:173-176`）的"个数相符"校验，路由权重与配置意图不符且无 WARN。只有"个数不符"与"全为 0"会报 `CONFIG`。
- **描述**：权重是影响流量分布的配置，写错时应该启动失败（与 fountain-baseline §4「同名注册启动直接失败，不做隐式优先级」同一取向），而不是按"能解析几段算几段"。
- **建议**：除首段（算法名）外，出现空段或非数字段即记 WARN 并抛 `DbdException(CONFIG)`；`segmentsOf` 保留空段交给 `getWeights` 判定，或让 `getWeights` 按原始 `split(',')` 校验。

### [轻微][存量] #10 `ping()` 把 ERROR 响应归为 `PROTOCOL`，服务端错误码与消息被丢掉

- **位置**：`f_dbd/src/driver/DbdTransport.cj:86-96`（`case Command.ACK => ()` / `case other => PROTOCOL`）
- **来源**：存量（`29f2d7e88e 2026-11-22`）
- **判据**：review-checklist §11「错误映射不一致」、§10 错误处理
- **证据**：静态确定 —— 同文件 `request`（`:118-124`）与 `unsubscribe`（`:74-80`）都是 `case Command.ERROR => throw errorOf(resp)`，只有 `ping` 把 `ERROR` 归进 `other`。`DbdDatasource.connect`（`DbdDatasource.cj:66-76`）再把这条异常原样抛出，调用方拿到的是 `PROTOCOL 'unexpected command ERROR in response to PING'`。
- **描述**：服务端若对 PING 回 ERROR（会话被摘除、服务端升级中的拒绝等），排查时会指向"协议不符"，而真正的 `DbdErrorCode` / `sqlState` / message 在构造 `DbdException(PROTOCOL, ...)` 时已经丢掉。
- **建议**：`ping` 的三分支补齐 `case Command.ERROR => throw errorOf(resp)`，与另两条路径一致。

### [轻微][存量] #11 IPv6 分支忽略 `]` 之后的非 `:` 残留，拼错的 URL 被当成合法

- **位置**：`f_dbd/src/driver/DbdUrl.cj:89-99`（`tail.startsWith(':')` 为假时既不报错也不使用 `tail`）
- **来源**：存量（`29f2d7e88e 2026-11-22`）
- **判据**：review-checklist §11「边界校验缺失」
- **证据**：静态确定 —— `fdbm://[::1]junk:9000/db` 会被解析成 `host = '[::1]'`、`port = DEFAULT_PORT(8112)`，`:9000` 与 `junk` 全部静默丢弃；用例只覆盖了合法形态 `[::1]:9000`（`DbdUrl_test.cj:63-67`）。
- **描述**：URL 拼错（少一个冒号、多一段路径）不会在解析期暴露，错误延后到建链阶段，并且连到的是默认端口——排查成本比直接报 `CONFIG` 高得多。
- **建议**：`tail` 非空且不以 `:` 开头 → `DbdException(CONFIG, 'illegal fdbm url ...: unexpected \'...\' after IPv6 host')`；用例补 `[::1]junk:9000`、`[::1]:` 两条。

### [轻微][存量] #12 deprecated `query(params)` / `update(params)` 只覆盖 0..n-1，不重置既有参数表

- **位置**：`f_dbd/src/driver/DbdStatement.cj:139-148`（两个 deprecated 重载）、`DbdStatement.cj:174-180`（`bind`）
- **来源**：存量（`29f2d7e88e 2026-11-22`）
- **判据**：review-checklist §11「契约与实现不符」、§2「近似重复但少一处边界处理」的同类
- **证据**：静态确定（`bind` 只写 `0..n-1`，没有 `parameters.clear()`）+ 待确认（std 未写明 deprecated 重载是否覆盖旧绑定）—— `statement.set(5, x)` 之后调 `update([a])`，`sqlPayloadOf` 会按 `max = 5` 发出 6 个参数（1 个实参 + 5 个空洞）。
- **描述**：数组形式看起来"参数完全由这个数组决定"，实际会带上上一次 `set` 留下的高位参数；参数个数与 `?` 数量不符时由服务端报 SQL 错误，调用方看到的是 SQL 报错而不是"残留参数"，排查方向被带偏。若 std 语义是"参数在语句生命周期内持久"，那无参 `query()/update()` 的当前行为是对的，唯独数组重载需要显式重绑。
- **建议**：`bind` 开头 `parameters.clear()`（数组形式按数组重绑；无参版本保持持久语义），并补一条"先 `set(1,...)` 再 `update([a])` 只发 1 个参数"的用例。

### [轻微][存量] #13 用例写进程级全局配置且不还原，用例之间隐式耦合

- **位置**：`f_dbd/src/multid/MultiD_test.cj:33-47`（`MultiDConfigTest.readsExplicitValues`）、`:195-199`（`MultiDTest.openAcceptsBothSchemes` 设 `InitSize=0/MaxSize=1`）、`f_dbd/src/multid/MultiDTestSetup_test.cj:22` / `f_dbd/src/driver/DbdTestSetup_test.cj:22`（包级 `let` 写 `protocol_hostId`）
- **来源**：存量（`29f2d7e88e 2026-11-22`）
- **判据**：review-checklist §11「测试间隐式耦合 → flaky」、§10 可测试性
- **证据**：待确认 —— `Config.set` 是进程级全局写，本文件三个 `@Test` 类写的是同一组 `multidbm_databasePool*` 键且都不还原；缺的信息是 `cjpm test` 默认是否并行执行测试类（若串行，影响只是执行顺序敏感）。
- **描述**：并行执行时，`MultiDTest` 设的 `InitSize=0/MaxSize=1` 会漏进 `MultiDConfigTest`（反之亦然），表现为随机的池参数断言失败或池行为异常；第 5 部分的 `MultiDatasource_test` 用的是同一批键，跨文件也会受影响。包级 `let` 写 `protocol_hostId` 是刻意的一次性 setup（有注释），不在此列。
- **建议**：每个写配置的用例 `finally { Config.set(原值) }`，或集中到一个 setup 里给全量键赋值并让用例只读；至少让 `MultiDTest` 只改自己需要的两个键并在 `finally` 复原。

## 优化可行性方案

### [堆内存] `DbdStatement` 参数表从 `HashMap<Int64, Data>` 换成稠密数组

- **现状**：每条 `Statement` 一个 `HashMap<Int64, Data>`（`DbdStatement.cj:41`）：每个参数一个装箱 `Int64` 键 + 一个 `Data` 引用 + 桶数组开销；每次执行 `sqlPayloadOf`（`:249-265`）先整表遍历求 `max`（O(k) 哈希迭代），再 `0..max` 逐位 `get`（每次一次哈希 + 键比较），最后往 `SqlPayload` 追加。参数表活到 `close()`，payload 活到请求发完。
- **方案**：改成 `ArrayList<?Data>`（或 `Array<?Data>` + `maxUsed`）：`set(index)` 时按 index 扩容（同时落地 #1 的上限），`sqlPayloadOf` 直接按下标顺序 append、缺失位 `addNull()`；`sqlPayloadOf` 的入参类型同步从 `Map<Int64, Data>` 换成 `Array<?Data>`。
- **预期**：每次执行省掉一次全表遍历与 k 次哈希查找；参数表从"HashMap 桶数组 + k 个 entry"压成一个指针数组。具体字节数与耗时收益需实测（本部分无基线）。
- **代价**：`set` 大 index 时按 index 扩容（必须有上限，与 #1 合并处理）；`PayloadWrapping_test` 的三条字节等价用例与 bench 的输入类型要改（可用一个 `Map → Array` 的测试内辅助保持对照）。
- **验证**：`F_DBD_BENCH=1` 跑 `PayloadWrapping_test.testBenchPayloadAllocation`（现有隔离探针值 1,744 B/次可作"改前"参考，见 `doc/spec/optimize-f-dbd-payload-wrapping/design.md`），再对 8 / 32 参数两种规模各跑改前改后的 `getAllocatedHeapSize()` 差值与 `cjpm bench -O2` 吞吐。
- **证据状态**：无基线（待验证，不进 tasks）—— 只有"改前"参考值，没有本方案的改后对照。

## 待验证假设

> 本部分没有提供 `cjprof` / `cjpm bench` 数据（`scope.md` 的「已有性能资料」是 `docs/LocalMode*.md`，与本部分无关）。下面四条只是线索，不构成热点或收益结论。

| # | 假设 | 位置 | 缺什么数据 | 怎么采 |
| --- | --- | --- | --- | --- |
| 1 | `sqlPayloadOf` 的"遍历求 max + 逐位 `get`"占单条语句执行耗时的比例 | `f_dbd/src/driver/DbdStatement.cj:249-265` | 自耗时占比（含 8 / 32 参数两档） | `cjprof record` 跑 10 万次 `update`（参数 8 与 32 各一轮），看 `sqlPayloadOf` self time 与调用路径 |
| 2 | 每次 `query()` 新建两个闭包（`ColumnRequestSender` / `ResultCloser`）+ `QueryResultImpl` 的列信息数组拷贝，对短查询的分配占比 | `f_dbd/src/driver/DbdStatement.cj:91-94`；`f_dbd/src/common/result.cj:68-75` | 每次查询的分配字节数 | 前后 `getAllocatedHeapSize()` 差 / 1 万次短查询；同环境 `-O2` |
| 3 | 多节点下每次借连接都走 `RoundRobin.next()`（内部 `Mutex`）+ `TreeMap.forward`，高并发借用是否形成锁竞争 | `f_dbd/src/multid/Datasource.cj:92-99`、`:114`；`f_concurrent/src/LoadBalance.cj:32-49` | 锁等待时长、BLOCKED 线程数 | 200 并发借还压测 + 线程状态采样（CPU profile 看不到锁竞争）；同时记录借用 QPS |
| 4 | 默认 `initSize=1 / maxSize=1`（`Config.cj:85-95`）下每节点并发上限 = 1，是否成为吞吐上限 | `f_dbd/src/multid/Datasource.cj:62-64`、`:76-88` | 池等待时间 P95/P99 | 按 1/4/16 节点各压一轮，采池诊断计数与借用等待分布 |

## 文件覆盖

| # | 文件 | 类型 | 已读 | 说明 |
| --- | --- | --- | --- | --- |
| 1 | `src/driver/DbdStatement.cj` | .cj | ✅ | 参数收集 / 执行 / deprecated 重载；见 #1、#5、#7、#12；`sqlPayloadOf` 见优化方案 |
| 2 | `src/driver/DbdStatement_test.cj` | .cj | ✅ | 参数顺序 / 空洞 / 超时覆盖 / 请求序列；与实现一致（断言 5 条报文的用例与 §7.1 对齐） |
| 3 | `src/driver/DbdTestSetup_test.cj` | .cj | ✅ | 包级 `let` 写 `protocol_hostId`，初始化副作用有意为之；见 #13 的说明 |
| 4 | `src/driver/DbdTransaction.cj` | .cj | ✅ | 状态机 / savepoint 透传 / 注入拦截；见 #4、#7；`isIdentifier` 先判空再取 `runes[0]`，无越界 |
| 5 | `src/driver/DbdTransaction_test.cj` | .cj | ✅ | 六个用例覆盖状态机、注入、结果集互斥；与实现一致（`propertiesAreRecordedNotTranslated` 正好固化了 #4） |
| 6 | `src/driver/DbdTransport.cj` | .cj | ✅ | `CONSUME` / `UNSUBSCRIBE` / `PING` 与 `None → 关传输` 语义；见 #10；`NO_TIMEOUT` 被 Statement / Transaction 复用 |
| 7 | `src/driver/DbdTransport_test.cj` | .cj | ✅ | 12 个用例含超时关链与幂等关闭；`ping` 的 ERROR 分支无用例（见 #10） |
| 8 | `src/driver/DbdUrl.cj` | .cj | ✅ | 解析 / %编解码 / 脱敏重建；见 #7、#11；`percentDecode` 的 `i + 2 >= size` 边界正确 |
| 9 | `src/driver/DbdUrl_test.cj` | .cj | ✅ | 15 个用例含非 ASCII 往返与字节级解码；与实现一致，IPv6 只覆盖合法形态（见 #11） |
| 10 | `src/driver/PayloadWrapping_test.cj` | .cj | ✅ | legacy 对照 + 字节等价 + 门控 bench；见 #5（`getGCCount` 未用） |
| 11 | `src/driver/placeholder.cj` | .cj | ✅ | 空文件（仅注释），零声明；见 #8 |
| 12 | `src/driver/stub_fdbm_test.cj` | .cj | ✅ | 进程内 fdbm 桩 / `QueryScript` / 载荷解码助手；见 #6、#7 |
| 13 | `src/driver/testkit_test.cj` | .cj | ✅ | `codeOf` / `messageOf` / `waitUntil` 三个断言工具，均被引用；见 #7（`codeOf` 另一份在 `multid`） |
| 14 | `src/exception/DbdException.cj` | .cj | ✅ | 只有一行 `public import`，与注释所述的包循环规避一致；无声明可判死代码 |
| 15 | `src/exception/Reexport_test.cj` | .cj | ✅ | 重导出身份 / `SqlException` 可捕获；`typeIdentity` 为私有方法且被本类使用 |
| 16 | `src/multid/Config.cj` | .cj | ✅ | 14 个 getter 的取值与单位与设计 §6.1 一致；见 #9 |
| 17 | `src/multid/Datasource.cj` | .cj | ✅ | 权重/算法校验在建池前、`LoadBalance` 口径与设计 §6.4 一致；见 #2、#3 的对照、待验证假设 3/4 |
| 18 | `src/multid/MultiD.cj` | .cj | ✅ | `static init` 注册 + `open` 转 `MultiDatasource`；与设计 §6.3 一致，`multiDDriver()` 有 `fdbmdemo` 消费 |
| 19 | `src/multid/MultiDTestSetup_test.cj` | .cj | ✅ | 与 #3 同形的包级 setup（不同包，不冲突） |
| 20 | `src/multid/MultiD_test.cj` | .cj | ✅ | `MultiDConfig` / `MultiDUrl` / `MultiD` 三组用例；见 #7（`codeOf` 重复）、#13（全局配置不回滚） |

合计：`.cj` 20 个 / `.md` 0 个 / 共 20 个，全部读完。

## 覆盖自检

| 维度 | 命中 | 未命中时的说明 |
| --- | --- | --- |
| 正确性 / 设计 / 语言特性 / 可读性 / 安全性 | 7 | 正确性：#1、#3、#4、#12；设计：`MultiDatasource` 把"池 + 负载均衡"收在自己的 `init`（见 #2 的回滚问题），`driver` 层依赖方向为 `driver → common`、`multid → driver`，无反向依赖；语言特性：`Data`/`SqlDbType` 的 `match` 分派用具体类匹配（`setSqlDbType` 38 个分支，`case _` 收口），`?T` 用 `setNullable` 统一收敛，惯用法正确；可读性：#5（残留 import 误导）；安全性：savepoint 名走白名单校验（`DbdTransaction.cj:130-157`，用例 `savepointNameInjectionIsRejected` 钉住 6 种注入串），`getMetaData` 走 `toUrlMasked()`、密码不进 metadata，`DbdUrl` 的 `%XX` 解码对非法 UTF-8/残缺转义报 `CONFIG`，本部分无硬编码凭据、无 SQL 拼接（除已挡的 savepoint 名） |
| §1 死代码 | 3 | #5（3 个未用 import）、#6（`StubFdbm.consumes` / `clear` 无调用者，全仓 grep 确认）、#8（`driver/placeholder.cj` 零声明）。其余已逐个搜：`private`（`ensureExecutable` / `sqlPayloadOf` 私有成员 / `timeoutOf` / `checkIndex` / `bind` / `encode` / `setSqlDbType` / `setNullable` / `ensureBegun` / `check` / `isIdentifier` / `isStart` / `isPart` / `ensureOpen` / `checked` / `errorOf` / `onNoResponse` / `firstSegmentOf` / `hexByte` / `nibbleOf` / `percentDecode` / `percentEncode` / `isUnreserved` / `intOf` / `boolOf` / `segmentsOf` / `anyPoolClosed` / `effectiveWeights` / `algorithmOf` / `legacySqlPayloadOf` / `encoded` / `expectBytes` / `dbdBenchEnabled` / `dbdSettle` / `dbdMeasure`）在包内均有调用；`internal`（`sqlPayloadOf`、`NO_TIMEOUT`、`withCredentials`、`StubFdbm` 的成员、`QueryScript`、`FailingUpdateScript` / `NotEncodable`、`freePort`、`commandName`、`codeOf` / `messageOf` / `waitUntil`）在包内均有引用，唯 #6 两处例外；`protected`：只有 `MultiDConfig`（`protected struct`），其 14 个 `public static` 方法全部被 `Datasource.cj:60-73` 消费，按"非公共顶级声明里的 public 成员"口径逐一核对过，无死代码；`public`：`DbdStatement` / `DbdTransaction` / `DbdTransport`（非 public 类，成员均为包内放宽，已逐个核对使用）/ `DbdUrl` / `MultiD` / `MultiDatasource` 均为对外可达，按硬原则一不判，仅记录信息：`DbdUrl.toUrl()` 仓内只有用例引用（生产走 `toUrlMasked()`），`DbdStatement.query(params)` / `update(params)`、`DbdTransaction.save/release` 仓内也只有用例调用，都是对外 API；包级 `let testProtocolHostIdSetup`（两个 setup 文件）名字零引用但初始化器有副作用（写 `protocol_hostId`），不算死代码 |
| §2 重复逻辑 | 1 | #7 合并了四组同语义实现（超时取值、`codeOf`、空闲端口探测、`toUrl`/`toUrlMasked`）。另外核对过：`PayloadWrapping_test` 的 `legacySqlPayloadOf` 与生产 `sqlPayloadOf` 结构相同但**是有意的等价基准**（用例名 `payloadBytesMatchLegacy` 就是它的目的），不算重复；`QueryScript.handler` 与 fdbm 真实分发不是同一职责；两个 `placeholder.cj` 与两个 setup 文件是"每包一份"的必然重复，不合并 |
| §3 空实现 | 0 | 全部分文件搜 `TODO` / `FIXME` / `UnsupportedException` 无命中；两处 `catch (_: Exception) { () }`（`DbdStatement.close`、`DbdTransport.close`）都是"幂等关闭、对端失败不要求应用重试"的有意策略且有注释，随后一定释放本地状态（`openResult = None` / `closed = true`）；`DbdStatement.parameterColumnInfos` 返回空数组是契约本身（设计 §5.5「恒为空、不提供服务端参数元数据」），不是空实现。#4 的"设置后无下行效果"按契约不符归 §11，不重复计入本节 |
| §4 栈溢出 | 0 | 本部分无递归：`isPart → isStart` 是单层调用，`DbdUrl` 的解析全是直线扫描，`sqlPayloadOf` 是 `while` 累加；递归深度不由 URL / 参数 / 节点数驱动，无可达深度上界问题 |
| §5 OOM | 1 | #1（按 max index 全量物化 payload + 参数表无界）。其余容器有界：`MultiDatasource` 的池按 `maxSize` 限流，`nodes` / `weights` / `pools` 由 URL 与配置长度决定，`DbdUrl.percentDecode` 的 `ArrayList<Byte>` 上界是 URL 字节数 |
| §6.1 热点瓶颈 | 0 | 本部分无 `cjprof` / `cjpm bench` 数据；`PayloadWrapping_test` 的 bench 默认 `F_DBD_BENCH!=1` 直接 `println("SKIP")` 返回，不产生可复核数据。四条线索已进「待验证假设」，未当作缺陷 |
| §6.2 大粒度锁 | 0 | 本部分临界区只有字段读写：`DbdConnection` 的 `Mutex`（属第 3 部分，此处只作对照）与 `RoundRobin` 内部 `Mutex`（`f_concurrent`）。`DbdTransport` 本身无锁，`MultiDatasource.connect` 不持锁发包，`begin/commit` 也不在锁内做 I/O |
| §6.3 并发串行 | 0 | 本部分无 `spawn` / `Future.get` / 线程池；一条连接上一问一答是协议约定（`QueryResultColumnPayload` 不带结果标识），不是"形式并发"。`MultiDatasource` 借连接是单次调用，不存在批内逐个 `get()` |
| §6.4 低效算法 | 1 | #1 的 `while (i <= max)` + 每轮一次 `HashMap.get`（复杂度随最大 index 线性，与参数个数无关）；#7 的"求 max 再逐位取"也在优化方案里一并处理。其余无嵌套循环匹配 / 热路径 `contains` / `remove(at: 0)` |
| §7 降堆内存方案 | 1 | 参数表 `HashMap → 稠密数组`（无基线，已标「待验证，不进 tasks」） |
| §8 降 CPU 方案 | 0 | 没有基线数据，故不出方案；三条 CPU 线索（参数组装自耗时、每查询闭包分配、`RoundRobin.next()` 的锁）已进「待验证假设」1–3 |
| §9 local mode 可行性 | 0 | 逃逸检查全部不通过：`sqlPayloadOf` 的 `SqlPayload` 要上线（逃逸到 `DbdTransport`）、`percentDecode` 的字节缓冲要变成 `DbdUrl` 的成员、`DbdStatement.query` 的 `QueryResultImpl` 返回给应用；`DbdUrl.isIdentifier` 的 `toRuneArray()` 虽不逃逸，但只在 savepoint 上调用（非热点、长度极小），收益无法用峰值内存证明，故不出方案 |
| §11 现有代码的 BUG（存量） | 13 | #1–#13 全部标「存量」（4 一般 + 9 轻微）。本部分读到的其余边界与空值已逐条核对：`DbdUrl` 的 `%` 截断判断（`i + 2 >= size`）、缺 host/空库名/端口越界、`DbdTransaction.isIdentifier` 先判空再取 `runes[0]`、`DbdStatement.close` 的幂等、`DbdTransport.onNoResponse` 的"先关链再判 IO/TIMEOUT"、`MultiDConfig` 的负数/零边界（`MaxWaiting<=0 → Duration.Max`）均无额外缺陷 |
| §12 并发安全与锁粒度 | 1 | #3（闸门检查-后-写入）。共享点与同步手段：`MultiDatasource.closed`（`AtomicBool.swap`）、`LoadBalance`（`TreeMap` 只在 init 写、读侧 `forward`，`RoundRobin` 自带锁）、`DbdTransport.client`（`f_net.Client.transfer` 内部按 `MessageID` 复用）、`DbdStatement.parameters` / `openResult`（无同步，仅在持有连接的单条执行链上使用，属线程封闭）。锁粒度见 §6.2 行 |
| §14 功能完备性与 README 覆盖 | 0 | 本部分不含 `.md`（README / `doc/**` 的对照归第 1、2 部分）。代码侧核对：`DbdStatement.setOption` 的 `fetch_rows` 已接到 `QueryResultImpl` 的 `chunkSize`（`DbdStatement.cj:94`）、`query_timeout`/`update_timeout` 分别接到 query/update、`DbdTransaction` 的六个方法都在 `Transaction` 上接线、`MultiD.open` 已接到 `MultiDatasource`、`multiDDriver()` 有 `fdbmdemo` 消费，无"注册了没人用"的缺口；唯一"能力存在但不下发"的是 #4（已计入 §11） |
| 文件覆盖（§13 等） | 20/20 | 无缺文件；本部分无 `.md`，§13 的文档一致性不适用（`.md` 只用于取证：`doc/详细设计.md` §5.1/§5.5/§5.8/§5.9/§6.1/§6.4 逐条对照过实现） |

## 模块统计

| 严重程度 | 数量 |
| --- | --- |
| 严重 | 0 |
| 一般 | 4 |
| 轻微 | 9 |
| 优化方案（堆内存 / CPU） | 1 / 0 |

## 总评

本部分（`Statement` / `Transaction` / `Transport` / `DbdUrl` / 多节点配置与数据源）的协议实现质量偏好：载荷判别一律 `decodeStrict` + 明确错误码（不宽容降级）、`transfer` 返回 `None` 一律关传输以避免错位、`qid` 用请求 `MessageID` 且与服务端 `handler.cj` 的 `cursor.qid` 口径一致、savepoint 名白名单挡住注入、`SqlDbType` 的 38 个分支与 `SqlTypes.encodeParameter` 支持类型逐一对齐（`SqlByte → Int8`、`SqlChar → String`、`SqlInterval → Duration` 与 `f_orm` 读侧的 `Sql*` 名称映射不矛盾）。死代码与重复逻辑都在少量残留层面，没有空实现、没有递归、没有不可达语句。

主要风险按优先级：

1. **#1 参数 index 无上界**——唯一能一次把进程打挂的点（错一个下标 → 十亿次循环 + 十亿个占位参数）。修法很小（一个上限常量 + 一条用例），建议优先排期。
2. **#3 结果集闸门非原子**——设计上把"同一连接至多一个未关闭结果集"当成不变量，实现却不是原子的；一旦有调用方跨线程共用连接，会静默错行（`QueryResultColumnPayload` 不带结果标识）。与第 3 部分 #3 是同一不变量上的两个交错，合并报告时建议并成一条"连接级独占不变量未原子维持"。
3. **#2 建池无回滚 / #4 事务属性静默无效**——前者是多节点场景的资源与启动耦合问题，后者是对 std 契约的静默偏离；都属于"平时不发作、故障时难查"的类型，可排期处理，其中 #4 最省的修法是先加一条 WARN。

存量共 13 条（4 一般 + 9 轻微），是否纳入修复待用户决定。本部分无阻塞级（严重）缺陷。
