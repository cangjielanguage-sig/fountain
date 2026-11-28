# f_dbpool 模块审查报告

- **审查日期**：2026-11-28
- **模块路径**：`f_dbpool`（5 个 `.cj`，共 537 行；2 个 `.md`）
- **基线**：工作区快照（sts/1.3.x 工作区，未对照远端目标分支；`git status --porcelain f_dbpool` 为空，本报告全部问题来源记为「存量」）
- **审查重点**：连接池生命周期与泄漏、大粒度锁与并发串行、OOM、死代码、存量 BUG、README 覆盖率（通用维度 + 全部专项扫）
- **报告版本**：v1

## 发现

### [一般][存量] `checkSql` 太短时抛的 `ConnectionException` 被两层 `catch` 吞掉，README 承诺的错误路径不存在，实测会变成 30 秒借连接失败 + 建连/销毁风暴

- **位置**：`f_dbpool/src/DatabasePool.cj:124-135`（`throw` 在 `:128`）、`:73-84`（吞异常的 `catch` 在 `:80-83`）；对照 `f_dbpool/README.md:52`、`f_dbpool/README_en.md:52`
- **来源**：存量（`git blame -L 73,84` → `35294a9b6c` 2026-10-09；`:128` → `f55def5449` 2026-10-09「改为显式抛 ConnectionException」；此后仅版本号提交）
- **判据**：review-checklist §11（契约与实现不符 / 错误被静默）、§13（文档承诺与实现相反）、§3（异常被降级成"连接无效"）
- **证据**：静态确定 —— 三层代码串起来即可定论：
  1. `:128` 在 `checkSql.size < 6` 时抛 `ConnectionException('checkSql is too short ...')`，注释明写这是 bug-orm.md §3.1 `ORM-C4` 的修法；
  2. 该闭包由构造器 2（`:96-144`）作为 `checker:` 传给构造器 1（`:44-95`），构造器 1 在 `:74-83` 用 `try { ... !c.isDestroied() && checker(c) } catch (e: Exception) { logger.error("database check failed", e); false }` 包住 → 异常在**本模块内**就变成 `false`；
  3. 即便漏过这一层，`f_pool` 的 `KeyPool.doCheck`（`f_pool/src/KeyPool.cj:366-373`）同样 `catch (e: Exception) { logger.warn(...); false }`。
  无任何路径把这条异常送回 `getConnection` / `connect`。
- **描述**：后果是一条完整的失败链，而不是一条清晰的异常。`checker` 恒返回 `false` 时：`KeyPool.get` 每轮把池项取出→判定无效→`BaseKeyPool.keyedChecker` 记账减一（`f_pool/src/BaseKeyPool.cj:70-79`）→销毁；接着 `pool.size < totalSize` 成立，`tryAddTask` 再建一个（`f_pool/src/KeyPool.cj:766-780`）→新连接再被判无效……循环直到 `maxWaiting`（默认 30s，`f_pool/src/KeyPool.cj:764`）才 WARN 并返回 `None`。于是每一次 `getConnection` 都会：占住调用线程 30 秒、反复执行 `ds.connect()` 与销毁、并为每轮打一条 `logger.error("database check failed")`；`connect()` 最终只抛一个空消息的 `ConnectionException()`（`:242`）。若把 `maxWaiting` 配成 `Duration.Max`（该参数文档明说"真无限等待"，`:56`），循环不再有出口，等于对数据库发起持续建连风暴。这条路径的触发条件全部来自配置：`fdbm` 从 `fdbm_databasePoolCheckSql` 取值（`fdbm/src/config/FdbmConfig.cj:110`）、`f_orm` 从 `ORMConfig.getPoolCheckSql` 取值（`f_orm/src/wrap/NamedDatasource.cj:102`）、`f_dbd` 从 `MultiDConfig.getCheckSql()` 取值（`f_dbd/src/multid/Datasource.cj:73`）——写成空串、`"1"`、`"ping"` 都会命中。README 与源码注释都声称"短于 6 个字符时抛 `ConnectionException`"，实际调用方永远拿不到这条异常。
- **建议**：把校验前移到构造期 —— 构造器 2 开头 `if (checkSql.size < 6) { throw ConnectionException(...) }`，让非法值表现为"建池失败"而不是"运行时连接全部无效"；`checker` 里不再抛业务异常。同时收窄 `:74-83` 的 `catch`（只接驱动异常，`ConnectionException` 直接透传上游），否则任何"校验语句写错/权限不足"都会退化成上面这条 30 秒风暴。两版 README 的 `:52` 不用改，实现向文档靠齐即可。

### [一般][存量] `closeAndAwait` 的"总期限"实际可达 `2 × timeout`，调用方按配置的超时停机时耗时翻倍

- **位置**：`f_dbpool/src/DatabasePool.cj:199-204`（租约等待 `:200-203`、`awaitTermination(timeout: timeout)` 在 `:204`）；对照 `f_dbpool/README.md:50`「在一个总期限内等待后台任务实际结束」
- **来源**：存量（`:199-203` → `6e9a934a3` 2026-10-21「池租约等待」；`:204` → `acb845409d` 2026-10-13。租约等待是后加的，加的时候没有从总预算里扣掉已用时间）
- **判据**：review-checklist §11（契约与实现不符）、§13（README 描述与实现不符）、§12.1（等待超时后状态处理）
- **证据**：静态确定 —— `let deadline = MonoTime.now() + timeout` 的循环最多吃满 `timeout` 才 `return false`，随后 `pool.awaitTermination(timeout: timeout)` 又拿到一整份 `timeout`，两段串行无扣减，最坏合计 `2 × timeout`。另外 `:202` 用 `sleep(Duration.millisecond)` 轮询租约，不是事件等待。
- **描述**：单池最坏 2 倍；而池的实际调用方是逐池串行等待的 —— `fdbm/src/resources/DatabaseResources.cj:271-283` 对每个池调用 `closeAndAwait(timeout: timeout)`，超时值来自 `fdbm/src/server/FdbmServer.cj:199` 的 `settings.shutdownTimeout`，于是 N 个池最坏 `2N × shutdownTimeout` 才完成停机。运维侧看到的是"配置了 10s 优雅停机，进程 40s 还没退"，而配置本身没有写错。README 的"一个总期限"也因此在实现上不成立。
- **建议**：把剩余预算算出来再传下去 —— 租约等待结束后 `let remain = timeout - (MonoTime.now() - start)`，`remain <= Duration.Zero` 直接 `false`，否则 `awaitTermination(timeout: remain)`；租约等待本身改用条件变量/`CountDownLatch` 语义替代 1ms 轮询（同时消掉空转唤醒）。

### [一般][存量] 租约账本与借还窗口不闭合：`leased` 归零不等于"没有在途借还"，`closeAndAwait` 可能提前关掉数据源

- **位置**：`f_dbpool/src/DatabasePool.cj:228-234`（`fetchAdd` 在 `:230`、`fetchSub` 在 `:232`）
- **来源**：存量（`6e9a934a3` 2026-10-21 引入租约计数，计数点放在 `pool.get` 之后、`giveBack` 之前）
- **判据**：review-checklist §12.1（检查-然后-写入 / 同步窗口缺失）、§11（资源释放不对称）
- **证据**：静态确定（窗口可从代码直接构造；实际命中率需实测）—— 两个方向都不闭合：
  - **借出侧**：`pool.get(timeout:)` 已在 `:228` 返回 `Some`，`activeLeases.fetchAdd(1)` 才在 `:230`。两者之间 `closeAndAwait` 读到的租约数是 0，可以判定"全部归还"并继续 `awaitTermination` → `closeDatasource()`，期间这笔借出仍在进行；
  - **归还侧**：`returnFn` 里先 `activeLeases.fetchSub(1)`（`:232`）再 `pool.giveBack(pooled)`（`:233`），而 `checkOnReturning` 默认 `true`（`:51`）、默认 checker 会在这条路径上真正执行一次 SQL（`:129-138`）。也就是说账已经归零时，归还动作（含一次数据库往返）还在跑。
- **描述**：`activeLeases` 的用途是 `closeAndAwait` 的安全网（`:41` 注释「T05：`closeAndAwait` 必须等它们回来」）。上述两个窗口使这张网在最需要它的时刻失效：`closeAndAwait` 返回 `true` 之后，`ds.close()` 可能与一笔正在发放或正在归还的连接并发，借用方随后拿到的是一条底层已被关闭的连接。README `:50` 已把"调用者须先结束借用中的连接"写成调用方责任，因此不按崩溃定级；但既然实现了计数，就应该对得起"等它们回来"这个语义。
- **建议**：用一个 shutdown gate 替代"计数 + 轮询"——借出前先取共享许可（并在 `pool.get` **之前**取），`giveBack` **之后**再释放；`closeAndAwait` 先翻关闭标志、再等全部许可归还。若不想改结构，最小修法是把 `fetchAdd` 提到 `:228` 之前（`try/finally` 回滚）、把 `fetchSub` 挪到 `giveBack` 之后。

### [一般][存量] `close()` 在租约未归还时直接关数据源，而 README 只写"不等后台回调"，两条关闭路径的差别没有交代

- **位置**：`f_dbpool/src/DatabasePool.cj:188-191`（`close`）、`:215-222`（`closeDatasource`，`:218` `ds.close()`）；对照 `f_dbpool/README.md:49-50`
- **来源**：存量（`35294a9b6c` 2026-10-09；`closeAndAwait` 的租约等待 `6e9a934a3` 之后两条路径开始不对称）
- **判据**：review-checklist §11（资源释放不对称 / 语义与文档不符）、§13
- **证据**：静态确定（顺序与不对称可从代码直接读出；借用方随后遇到的报错形态取决于驱动，属待确认）—— `close()` = `pool.close()` + `ds.close()`，全程不看 `activeLeases`；`pool.close()` 只销毁池内空闲项（`f_pool/src/KeyPool.cj:600-632`），被借出的连接不在池里，随后 `:218` 立刻关掉整个 `Datasource`。对比 `closeAndAwait`：等租约、等后台线程、再关数据源。README 对 `close()` 只写"不等待仍在运行的后台创建／校验回调"，没有一句提到在途租约会被连带失效、`leased` 会停在非零值。
- **描述**：这是优雅停机最容易踩的一格：调用方看到 `close()` 是"幂等关闭、更简单"，就在停机时用了它，在途请求手里的连接随即变成废连接（错误类型由驱动决定，可能是 `SQLException` 也可能是 `ConnectionException`），而日志里没有任何提示说"还有 N 条租约没归还"。仓库里已经有使用方踩过这个点并在代码里留了说明：`f_dbd/src/multid/Datasource.cj:142-147` 明确写"不等待池内部任务（借用中的连接由应用持有）…这里刻意不用 `closeAndAwait`，否则只会白等到超时"——这句说明本该出现在 f_dbpool 的 README 里。
- **建议**：README `:49` 补一句"`close()` 不保护在途租约：调用后借用中的连接即失效，`leased` 不会归零"；实现上在 `close()` 入口读一次 `activeLeases`，`> 0` 时打一条 WARN（不阻塞，成本可忽略），让误用有可观测信号。

### [轻微][存量] `checkSql` 分类只看前 6 个字符，前导空白/注释语句会被判成 `update` 分支并永久判无效

- **位置**：`f_dbpool/src/DatabasePool.cj:129`
- **来源**：存量（`35294a9b6c`）
- **判据**：review-checklist §11（边界 / 启发式误判）
- **证据**：静态确定 —— 判据是 `checkSql[0..6].toLower() == "select"`，`' select 1'`、`'/* ping */ select 1'`、`'WITH t AS (...) SELECT 1'` 都不匹配，落到 `:136-141` 的 `stmt.update()`，`rowCount > 0` 对查询语句基本恒为 `false`（或直接抛驱动异常），于是每次校验都判"连接无效"，落进上一条的 30 秒循环。从配置里复制粘贴带缩进的语句是很常见的形态。
- **建议**：先 `trimStart()` 再判前缀（或按驱动能力/语句类型探测决定走 `query` 还是 `update`）；并在构造期用一条已知语句探测一次，把"校验语句不可用"提前暴露成建池失败。

### [轻微][存量] 三个构造器重复整套默认值表（同一组参数与默认值出现 3 次），默认值容易漂移

- **位置**：`f_dbpool/src/DatabasePool.cj:44-95`、`:96-144`、`:151-181`；另在 `f_dbpool/README.md:20-42` / `README_en.md:20-42` 再复制一份
- **来源**：存量（`35294a9b6c`）
- **判据**：review-checklist §2（字面量复制）
- **证据**：静态确定 —— 13 个参数名 + 默认值在构造器 1、2 逐行重复，构造器 3 再重复 12 个；`maxSize = 10`、`checkInterval = minute * 5`、`maxWaiting = second * 30`、`connectionLife = hour` 各出现 3 次。差异点（构造器 2/3 末尾的 `checkSql` vs 构造器 1 的 `checker`）是实质差异，不能整体合并。
- **建议**：抽一个 `PoolOptions`（`f_pool.PoolBuilder` 已是 setter 风格，可直接复用）承载公共参数，三个构造器各自只保留差异参数；README 的签名块同步收敛成一处 + 一句说明。

### [轻微][存量] `connectTimeout` 名不副实：只当"借连接等待上限"，完全不约束 `ds.connect()`

- **位置**：`f_dbpool/src/DatabasePool.cj:55`、`:72`（`creator: {=> PooledConnection(ds.connect())}`）、`:224`
- **来源**：存量（`35294a9b6c`）
- **判据**：review-checklist §11（语义与命名不符）、§10（可维护性）
- **证据**：静态确定 —— `connectTimeout` 的唯一用途是 `getConnection(timeout! = connectTimeout)` 的默认值；建连走 `creator`，没有任何超时包裹。对比 `f_orm` 自己在 `SqlExecutor` 里是显式加超时的（`f_orm/src/base/SqlExecutor.cj:397-405`：驱动停在 `Connecting` 就抛 `ConnectionException`）。后果：`ds.connect()` 卡死时 creation 线程被永久占住，`f_pool` 的取消是协作式（`f_pool/src/KeyPool.cj:633-658` 的 `awaitTermination` 只等线程退出），`closeAndAwait` 必然超时返回 `false`；同时每次借连接都会白等满 `maxWaiting`。
- **建议**：改名为 `borrowTimeout`，或真给建连加超时；无论哪种，都在这两个参数上补一行文档注释说明"不约束底层建连"。

### [轻微][存量] `DatabasePoolTermination_test.cj` 缺 Apache 2.0 版权头（仅 SPDX 单行）

- **位置**：`f_dbpool/src/DatabasePoolTermination_test.cj:1`
- **来源**：存量（`git blame -L 1,2` → `acb845409d` 2026-10-13）
- **判据**：`fountain-baseline.md` §3（每个 `.cj` 须有 Apache 2.0 版权注释，位于 `package` 之前）
- **证据**：静态确定 —— 首行只有 `// SPDX-License-Identifier: Apache-2.0`，没有版权人声明与 License 全文；同模块另两个测试文件（`DatabasePool_test.cj:1-16`、`PooledConnection_test.cj:1-16`）都是完整头。全仓同型只有 3 个文件（另有 `f_pool/src/PoolLifecycle_test.cj`、`f_orm/src/orm_test/AnnotatedQueryMappers_test.cj`），属零星约定缺口，故按轻微记。
- **建议**：补成与其他文件一致的完整头。

### [轻微][存量] `PooledConnection_test.cj` 的设计说明注释已过期：仍在说"建池会读一批全局 ORM 配置"

- **位置**：`f_dbpool/src/PooledConnection_test.cj:30-32`
- **来源**：存量（注释随迁移原样搬入）
- **判据**：review-checklist §13（注释与实现漂移）
- **证据**：静态确定 —— 注释写"建池会连带读一批全局 ORM 配置（其它用例会写这些键）"，但迁移后 `DatabasePool` 不读任何配置（`README.md:5`、`:60-65` 的构造器变更说明），`src/` 里也没有 `f_config` / `ORMConfig` 依赖（`cjpm.toml` 只有 `f_base` / `f_log` / `f_pool`）。
- **建议**：改成迁移后仍然成立的理由（例如"直接压 `activate`/`close` 可以不建池、不起后台线程，用例更快更稳"）。

## 优化可行性方案

> 不是缺陷，是"还能更好"。本轮无任何基准数据，三条均为待验证假设，不进 `todo.md` / `tasks.md`。

### [堆内存] 每笔借用都新建一个归还闭包，闭包随池项常驻

- **现状**：`getConnection` 每次借出执行 `connection.activate({ pooled => activeLeases.fetchSub(1); pool.giveBack(pooled) })`（`:231-234`），新建一个捕获 `this` 的闭包并写进 `PooledConnection.returnFn`（`:279`）；该字段属于池内常驻对象，闭包一直活到下次借出。每笔借用 = 1 个闭包对象，稳态下数量等于借用次数。
- **方案**：构造 `PooledConnection` 时一次性注入所属 `DatabasePool`（或一个 `release: (PooledConnection) -> Unit` 方法值），`activate()` 不再接收闭包；归还路径由 `PooledConnection.close()` 直接调用注入的引用。
- **预期**：每笔借用少 1 个闭包分配；具体字节量与 GC 次数降幅无基线，不作数字承诺。
- **代价**：`PooledConnection` 与 `DatabasePool` 由"闭包隐式持有"变成"字段显式持有"，引用关系本身不变；需把租约递减搬进 `PooledConnection`。
- **验证**：同负载（borrow/return 循环 1e6 次）下 `getAllocatedHeapSize()` 与 GC 次数对照，`cjpm bench -O2` 前后各 10 轮取中位数。
- **证据状态**：`无基线（待验证，不进 tasks）`

### [CPU] 默认 `checkOnBorrowing = true` 让每次借连接多一次 `prepare` + `query` 往返

- **现状**：`checkOnBorrowing` 默认 `true`（`:50`），默认 checker 走 `c.prepareStatement("select 1")` → `stmt.query()` → `r.next()`（`:129-135`）。取连接在主路径上（每个请求一次），因此每次借连接都多一次网络往返 + 一次 prepare（多数驱动不缓存 prepared statement）。`checkOnReturning` 默认也为 `true`，归还路径同样有一次。
- **方案**：允许并文档化"零成本借出"组合（`checkOnBorrowing = false` + `checkInterval` 巡检兜底），或按借出计数每 N 次采样校验一次；把默认值的取舍写进 README。
- **预期**：单次取连接少 1 次 RTT（量级估计：本机 <0.1ms、跨机 0.5-1ms，未测）。
- **代价**：借到失效连接的概率上升，需要应用层重试；改默认值属行为变更。
- **验证**：分段计时 borrow 的 P50/P99（开关 `checkOnBorrowing` 各 10k 次，`-O2`），同时统计"借到失效连接"的次数。
- **证据状态**：`无基线（待验证，不进 tasks）`

### [堆内存] 租约泄漏没有任何上限或观测点，泄漏一笔即永久占用一个池名额

- **现状**：借出的连接由调用方持有，`activeLeases` 只计数（`:42`、`:230`），没有开始时间、没有上限。泄漏一笔 → 底层连接句柄 + 池名额永久占用（`f_pool` 的全局计数把借出项也算在内，`f_pool/src/BaseKeyPool.cj:109`）；`maxSize` 用满后所有借用都要等满 `maxWaiting` 再拿 `None`，现象与"数据库慢"无法区分。
- **方案**：在 `PooledConnection` 上记录借出时刻（`birth` 已有，再加一个 `leasedAt`），提供 `leasedLongerThan(Duration): Int64` 诊断，并在 `closeAndAwait` 的租约等待里对"超过 X 仍未归还"打 WARN（带 `serial`）。不做强制回收 —— 强制关连接会破坏使用者。
- **预期**：泄漏从"只能靠 30s 超时倒推"变成日志可定位；不改内存上限，只加可观测。
- **代价**：每笔借用多一次 `MonoTime.now()`（可忽略）；新增 public 诊断 API 需要 README 一行说明。
- **验证**：复用 `DatabasePoolTermination_test.cj` 的屏障型假数据源，注入"借出不还"用例，断言 `leased` 与 WARN 出现。
- **证据状态**：`无基线（待验证，不进 tasks）`

## 待验证假设

| # | 假设 | 位置 | 缺什么数据 | 怎么采 |
| --- | --- | --- | --- | --- |
| 1 | 默认 `checkOnBorrowing` 的 `select 1` 往返占单次 `getConnection` 延迟的主要部分 | `f_dbpool/src/DatabasePool.cj:124-142`、`:228` | 三段（prepare/query/next）耗时占比 | mockdb 与真实库各跑 10k 次 borrow，分段计时取中位数与 P99 |
| 2 | 每生命周期 6 条 `logger.debug`（borrow/return/prepare/transaction）在 DEBUG 打开时有可测开销 | `:270-272`、`:280`、`:302-304`、`:314-316` | 分配量与 self time | `cjpm bench -O2` 对照 DEBUG 开关，同输入同并发 |
| 3 | 单 key 池在 100+ 并发下成为吞吐上限（所有借用抢同一队列 + `waitMutex`/`creationMutex`） | `:62-94`（`Pool` 单 key 构造）、`:228` | 线程状态（BLOCKED/WAITING 比例）与锁等待时长 | 100 线程 borrow/return 循环 + 周期性线程 dump；注意 CPU profile 看不到锁竞争 |
| 4 | `closeAndAwait` 的 1ms 租约轮询在长租约场景下产生可测 CPU 占用 | `:200-203` | CPU 占比 | 注入一笔 30s 不归还的租约，测空转 CPU 与唤醒次数 |

## 文件覆盖

> 与 `reviews/202611280854_full-repo/files/f_dbpool.txt` 一一对应。

| # | 文件 | 类型 | 已读 | 说明 |
| --- | --- | --- | --- | --- |
| 1 | `f_dbpool/README.md` | .md | ✅ | 77 行全读；API 清单与 `src/` 逐项一致（3 个构造器 + 6 个方法 + `leased`），`checkSql` 短串承诺与实现不符（#1）、`closeAndAwait`"总期限"不成立（#2）、`close()` 与 `closeAndAwait` 的差别未交代（#4） |
| 2 | `f_dbpool/README_en.md` | .md | ✅ | 77 行全读；与中文版逐节对应（含「Other public API」段），无整节缺失，同样的三处问题 |
| 3 | `f_dbpool/src/ConnectionException.cj` | .cj | ✅ | 32 行全读；4 个构造器与 `f_base.BaseException`（`f_base/src/BaseException.cj:47-57`）一一对应，无缺陷 |
| 4 | `f_dbpool/src/DatabasePool.cj` | .cj | ✅ | 327 行全读；3 个构造器 + `closeAndAwait` 期限（#2）+ 租约窗口（#3）+ `close` 不对称（#4）+ `checkSql` 吞异常（#1）/分类（#5）+ 默认值重复（#6）+ `connectTimeout`（#7）；`PooledConnection` 借还/销毁路径逐条推导无缺陷 |
| 5 | `f_dbpool/src/DatabasePoolTermination_test.cj` | .cj | ✅ | 68 行全读；屏障型假数据源设计合理（`setOption` 空体是测试桩），覆盖"超时返回 false → 释放 → 再等待成立 → 数据源只关一次"，逻辑与实现一致；缺版权头（#8） |
| 6 | `f_dbpool/src/DatabasePool_test.cj` | .cj | ✅ | 50 行全读；`DatabasePool(ds)` 解析到构造器 2（`checker!` 无默认值、不歧义），因此确实走到了 SQL 校验分支；仅冒烟借还一次，未断言归还后 `leased` 归零；用例改写了全局 `MOCKDB.execution` 且未还原（同模块其它用例不读它，暂无害） |
| 7 | `f_dbpool/src/PooledConnection_test.cj` | .cj | ✅ | 60 行全读；重复归还 CAS 用例覆盖到"再次借出可复用"，与实现一致；介绍注释过期（#9） |

合计：`.cj` 5 个 / `.md` 2 个 / 共 7 个，全部读完。

## 覆盖自检

| 维度 | 命中 | 未命中时的说明 |
| --- | --- | --- |
| 正确性 / 设计 / 语言特性 / 可读性 / 安全性 | 9 | 一般 4（`checkSql` 异常被吞 #1、`closeAndAwait` 期限翻倍 #2、租约窗口不闭合 #3、`close()` 与 `closeAndAwait` 不对称 #4）+ 轻微 5（`checkSql` 前缀启发式 #5、默认值表重复 #6、`connectTimeout` 语义 #7、版权头 #8、过期注释 #9）。安全性无命中：无外部输入拼 SQL（`checkSql` 来自配置但只作 `prepareStatement` 参数，未拼串）、日志里只有连接序号与异常，无凭据 |
| §1 死代码 | 0 | 已逐个过：`DatabasePool` 的 3 个 `init`、`isClosed`/`close`/`closeAndAwait`/`leased`/`getConnection`/`setOption`/`connect` 均为顶层 `public class` 的对外可达成员，不判；`private` 的 `logger`(:34)/`ds`(:36)/`pool`(:37)/`connectTimeout`(:38)/`datasourceCloseLock`(:39)/`datasourceClosed`(:40)/`activeLeases`(:42)/`closeDatasource`(:216) 全仓均有引用，`open`(:182) 只被 `:168` 调用一次（单次转发，属可读性、非死代码）。`PooledConnection`（顶层无修饰＝包内）的 `serialGen`(:248)/`serial`(:249)/`birth`(:250，被 `:75` 读)/`returnFn`(:253)/`assigned`(:255)/`returned`(:259)/`activate`(:274)/`isDestroied`(:283)/`destroy`(:286) 均有引用；其 `isClosed`/`close`/`prepareStatement`/`createTransaction`/`state`/`getMetaData` 是 std `Connection` 接口实现，按硬原则豁免。`ConnectionException` 4 个构造为 public 类的 public 成员（对外可达，不判），其中无参构造被 `:242`、单参构造被 `:128`/`:226`/`:267` 使用。无 `return`/`throw`/`break` 之后的同层语句，无恒真恒假分支；7 个 import 全部有用（`std.unicode.UnicodeStringExtension` 提供 `:129` 的 `toLower()`，`std.collection.Map` 是 `getMetaData` 返回类型） |
| §2 重复逻辑 | 1 | 已两两比对 `DatabasePool` 的全部函数体（3 个构造器 + 8 个成员 + `open`/`closeDatasource` 两个 private 辅助）与 `PooledConnection` 的 9 个成员摘要：命中 1 条（#6，三个构造器重复同一份参数与默认值，属"字面量复制"）。`PooledConnection` 的 4 个委托方法（`prepareStatement`/`createTransaction`/`state`/`getMetaData`）形状相同但返回类型与日志文案各异、且是接口实现，合并只能靠宏，不判重复；`checkSql` 的 query / update 两个分支语义不同，不判；`f_dbpool.ConnectionException` 与 `f_orm.exception.ConnectionException` 是 README `:59` 明示的刻意独立声明，属误报边界。`open`(:182) 只转发一次，属可读性而非重复逻辑 |
| §3 空实现 | 0 | 无空函数体、无 `TODO`/`FIXME`、无 `catch {}`。`BlockingTestDatasource.setOption` 空体是测试桩（Null Object），测试语境自明；`:80-83` 与 `f_pool` 的 `doCheck` 是"有日志的降级"而不是吞掉，其**效果**上的静默已按 #1 记 |
| §4 栈溢出 | 0 | 全模块无递归调用、无自引用结构与深度拷贝；`checker` 闭包只做一次 `prepareStatement`/`query`，不递归；借连接的重试是 `while` 循环（`f_pool/src/KeyPool.cj:766`），不是递归 |
| §5 OOM | 0 | 无容器累积：`activeLeases` 是单值原子；`options` 由调用方传入；池项数量受 `maxSize` 约束（`f_pool` 侧记账）。最坏情况是 #1 的无界重试循环，但它增长的是连接数与日志量、不增长本进程堆，按 CPU/资源问题记而非 OOM |
| §6.1 热点瓶颈 | 0 | 未提供任何 profile / bench 数据（`docs/LocalMode.md`、`docs/LocalMode-O2-Plan.md` 不含 f_dbpool 的测量），因此不把"每次借连接一次 SQL 校验""debug 日志"写成热点，四条猜测进「待验证假设」#1-#4 |
| §6.2 大粒度锁 | 0 | 模块内唯一互斥是 `datasourceCloseLock`(:39)，临界区只有 `ds.close()` 与一个 Bool 赋值（`:216-221`）——持锁做 I/O，但目的是"关闭恰好一次"，且位于冷路径（停机），改成无锁会丢幂等性；判定为合理粗锁，不报 |
| §6.3 并发串行 | 0 | 无 `spawn`/`Future`；所有借用共用单 key 池（`Pool<PooledConnection>` 一个键），并发上限就是 `maxSize`，这是连接池的固有语义而非串行热点；实际争用程度见「待验证假设」#3 |
| §6.4 低效算法 | 0 | 无嵌套循环、无 `contains`/`indexOf` 扫描、无 `remove(at: 0)`、无循环字符串拼接；`checkSql[0..6]` 是 O(1)（其误判按 #5 记）；借连接的重试循环属错误路径放大，已按 #1 记 |
| §7 降堆内存方案 | 2 | 见「优化可行性方案」前两条（借用闭包、租约泄漏观测）；均无基线，标 `无基线（待验证）` |
| §8 降 CPU 方案 | 1 | 见「优化可行性方案」第 2 条（借出/归还校验的额外往返）；无基线 |
| §9 local mode 可行性 | 0 | 不可行：池化连接必然跨调用存活（`PooledConnection` 被池持有、`returnFn`/`checker`/`creator` 闭包被 `KeyPool` 字段长期持有），全部逃逸；`docs/LocalMode.md:475` 已把 f_dbpool 标为"池化连接必然跨调用存活；不做" |
| §11 现有代码的 BUG（存量） | 5 | 已逐条推导本模块全部可执行路径：`getConnection`/`connect`（#1、#3）、`closeAndAwait`（#2）、`close`/`closeDatasource`（#4）、`checkSql` 分类（#5）、`PooledConnection.close`/`activate`/`destroy`（CAS 幂等、`assigned` 复位、`destroy` 跳过借出项均有明确依据，无缺陷）、`leased`、`setOption` 直转发。边界/空值：`timeout <= 0 || == Max` 已显式拒绝（`:194-196`），`getConnection` 的 `None` 分支处理正确 |
| §12 并发安全与锁粒度 | 1 | 共享可变状态三处：`activeLeases`（`AtomicInt64`，正确使用但窗口不闭合 → #3）、`datasourceClosed` + `datasourceCloseLock`（synchronized 保护，正确）、`PooledConnection.assigned`/`returned`（`assigned` 是普通 Bool，只在借用方线程与池后台线程之间经池的队列/锁传递，未发现缺同步的路径；`returned` 是 CAS 幂等，正确）。命中项为 #3 |
| §14 功能完备性与 README 覆盖 | 0 | 以 `src/` 公开声明为基准逐项对照：3 个构造器、`getConnection`、`connect`、`isClosed`、`close`、`closeAndAwait`、`setOption`、`leased`、`ConnectionException` 与 4 个构造在 README 中均有对应段落或条目；`PooledConnection` 是包内类型、已说明"不导出"；根 `README.md:213-217` 已登记本模块；承诺的能力（借还、双重归还拦截、优雅等待、`checkSql` 校验）都有实现，无"承诺但未实现"。README 承诺与实现**不符**的两处按 §13 记在 #1/#2 |
| 文件覆盖（§13 等） | 7/7 | 无缺失文件。§13 命中 2 条（`README.md:52` 的 `checkSql` 承诺、`:49-50` 的关闭语义缺口），另 1 条注释漂移（#9）；中英两版之间无整节缺失，示例代码（签名块）与 `src/` 一致 |

## 模块统计

| 严重程度 | 数量 |
| --- | --- |
| 严重 | 0 |
| 一般 | 4 |
| 轻微 | 5 |
| 优化方案（堆内存 / CPU） | 2 / 1 |

存量缺陷合计 9 条（严重 0 / 一般 4 / 轻微 5），全部为存量；是否纳入修复待用户决定。

## 总评

模块很小（5 个 `.cj`、537 行），职责也干净：`DatabasePool` 只做"把 `Datasource` 接到 `f_pool.Pool` 上"，参数全部由调用方显式给出、不读任何配置；`PooledConnection` 是一层薄包装，把 `close()` 变成归还、用 `AtomicBool` CAS 挡住重复归还（bug-orm.md `ORM-L8`）；`ConnectionException` 直接挂 `f_base.BaseException` 并与 f_orm 的那份刻意区分。没有死代码，没有递归，没有无界容器，README 的 API 覆盖是完整的（连 `leased` 都单列了），中英两版同步。`f_pool` 侧已经承担了真正的池化复杂度（建连线程、巡检、账本自愈、关停顺序），本模块没有重复实现这些。

风险集中在"错误路径与收尾路径"，共四条一般项，都不属于崩溃类，但都会在真实运维里放大：

- **配置驱动的失败风暴**（#1）：`checkSql` 写短或写成前缀不匹配的形态，不会得到一句清晰的异常，而是每次借连接卡 30 秒、反复建连/断连、每轮一条 ERROR 日志，`maxWaiting` 配成 `Duration.Max` 时没有出口。这一条建议优先修，因为修法很轻（把校验提到构造期 + 收窄 `:80-83` 的 catch），而现状与 README 承诺正好相反。
- **停机期限不成立**（#2）：`closeAndAwait` 最坏吃 2 倍超时，`fdbm` 逐池串行后放大成 `2N` 倍。同理修法很小（把剩余预算传下去）。
- **租约安全网有缝**（#3）：计数点放在 `pool.get` 之后、`giveBack` 之前，`leased == 0` 不等于没有在途借还；要么改成许可式 gate，要么至少把两个计数点挪到窗口外侧。
- **两条关闭路径的语义差没有写进文档**（#4）：`close()` 会让在途租约失效，`f_dbd` 已经在代码注释里承认这一点，README 里却只有"不等后台回调"。

轻微项（`checkSql` 前缀启发式、三份默认值表、`connectTimeout` 名不副实、一个测试文件缺版权头、一条过期注释）都可以排期，不影响正确性。

需要点名的一处设计取舍：`PooledConnection.close()` 在重复归还时**抛异常**而不是幂等忽略。这是 README 与测试钉住的契约（`ORM-L8`），但 `Connection` 在很多框架里被当作可重复关闭的资源，双层 `try`/错误清理路径上重复 `close()` 会拿到 `ConnectionException`，可能盖住原始异常。这是刻意选择，不作为缺陷，但值得在 README 的"注意事项"里提醒一句。

本轮不提出带数字的性能结论：模块内每笔借用的固定成本（一次 SQL 校验、几个 debug 日志、一个闭包）都没有 `cjprof`/`cjpm bench` 基线，全部按「待验证假设」和「无基线（待验证）」记录，不进 `todo.md` / `tasks.md`。

范围外提示（不计入统计）：`fdbm/src/resources/DatabaseResources.cj:271-283` 逐池串行调用 `closeAndAwait`，会把 #2 的 2 倍超时放大成 `2N` 倍，停机耗时与 `shutdownTimeout` 的偏差在 fdbm 侧看更明显。
