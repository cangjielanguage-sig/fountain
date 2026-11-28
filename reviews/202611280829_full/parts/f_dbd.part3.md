# f_dbd 模块审查报告（第 3/4 部分）

- **审查日期**：2026-11-28
- **模块路径**：`f_dbd`（模块共 49 个源文件；本部分 15 个）
- **基线**：工作区快照（`sts/1.3.x`，HEAD `8c0ce64`；`git status` 仅有无视的审查产物目录，无源码改动 ⇒ 全部记「存量（快照模式无基线）」）
- **审查重点**：传输层 / URL / 占位符 / 多数据源路由的正确性、资源释放、并发安全、死代码、重复逻辑、空实现、OOM、存量 BUG
- **报告版本**：v1（第 3/4 部分；本部分只覆盖下方 15 个文件，结论需与 part1 / part2 / part4 合并成模块报告）

## 发现

### [一般][存量] `DbdTransport` 只处理 `transfer` 返回 `None`，f_net 直接抛出的异常会穿透成非 `DbdException`，且传输不拆链

- **位置**：`f_dbd/src/driver/DbdTransport.cj:63`（`request`）、`:73`（`unsubscribe`）、`:88`（`ping`）
- **来源**：存量（快照模式无基线；三处均为当前 HEAD 内容）
- **判据**：review-checklist §11（错误处理缺失）/ §3（契约与实现不符）；契约源 `f_dbd/README.md:142`「对外只抛 `DbdException`」、`DbdTransport.cj:38-43` 类注释「失败路径统一抛 `DbdException`」
- **证据**：静态确定 —— `f_net` 的 `Client.transfer(message, timeout)` 只有在「连接已显式 close」时才返回 `None`（`f_net/src/client/client.cj:324-327`）；其余失败通过 `MessageFuture` 存 `failure` 并在 `tryGet` 里 `throw error`（`f_net/src/MessageFuture.cj:46-48,63-72`）。这些路径包括：读线程解码失败/`pending.close`（`client.cj:100-133`）、写 socket 失败（`client.cj:334-343`）、`DbdTransport.close()` 时有在途请求（`client.cj:240-252` 用 `ClientException` 关闭 pending）。
- **描述**：`DbdTransport.request/unsubscribe/ping` 只 `match (client.transfer(...))` 的 `Some/None`，没有 `catch`。于是上述任一失败都会把 `ClientException` / `IllegalArgumentException`（解码失败）原样抛给 `DbdConnection` → `DbdStatement` → 应用，违反「对外只抛 `SqlException`」的公开契约（只 `catch (e: SqlException)` 的业务代码会直接漏出 500/线程崩溃）。同时这条路径**不调用 `close()`**：`isClosed()` 只看 `Client.closed` 标志（`client.cj:254-256`），socket 已被 reader 关闭时仍为 `false`，后续请求会走 f_net 的自动重连，把「已断链」当作正常连接继续用，与类注释 §7.4「可能已错位必须立即关闭」相矛盾。`DbdTransport_test.cj` 只覆盖了超时（`None`）分支，未覆盖抛异常分支。
- **建议**：把 `client.transfer` 包在 `try { ... } catch (e: Exception) { throw onBroken(e) }` 中，`onBroken` 内先 `close()` 再抛 `DbdException(IO, ..., cause: e)`；三处（`request` / `unsubscribe` / `ping`）抽同一个私有 `transfer()` 帮助函数，顺带消除 #8 的重复。

### [一般][存量] `DbdUrl` 的解析异常消息直接拼入带明文口令的整串 URL 与凭据片段

- **位置**：`f_dbd/src/driver/DbdUrl.cj:58,60,65,69,98,109,155,158`（`${url}`）与 `:214,221,232`（`${value}`，即 user / password / database 片段）
- **来源**：存量（快照模式无基线）
- **判据**：review-checklist §10 安全性 / fountain-baseline §6「日志中不得出现凭据、令牌」
- **证据**：静态确定 —— 消息模板为 `'illegal fdbm url \'${url}\': ...'`，`url` 是调用方原样传入的连接串；`percentDecode` 的错误里 `${value}` 是 `authority[0..colon]` / `authority[colon+1..at]` 等凭据切片。异常一旦被上层 `catch` 后打日志（f_orm / fboot 的启动失败日志、`SqlException.message` 上报）即泄露明文密码。
- **描述**：同文件 `toUrlMasked()`（`:143`）专门为「避免明文密码外泄」而存在，但解析失败路径绕过了它：最需要排障的配置写错场景恰好把密码打进日志。`%` 转义写错（`p%4`）、非 UTF-8（`%FF`）、端口非数字都会命中。
- **建议**：错误消息改用脱敏串（`DbdUrl.toUrlMasked()` 需要先解析成功，可在解析早期用「scheme + host 段 + `:***@`」的轻量脱敏），或只报 `scheme/host/database` 与出错位置；`percentDecode` 的细节消息去掉 `${value}`，改为「credentials 段第 N 个字节」。同根因在 `f_dbd/src/multid/Url.cj:49-70,95-98`（第 4 部分文件）也存在，合并修复。

### [一般][存量] `multidbm_databasePoolMaxWaiting` 在 multid 路径完全不生效（读了不用），池耗尽 50ms 即 `TIMEOUT`

- **位置**：`f_dbd/src/multid/Datasource.cj:72`（读取）、`:87`（传给池）；`f_dbd/src/multid/Config.cj:126-134`
- **来源**：存量（快照模式无基线）
- **判据**：review-checklist §1「读了不用 / 死配置字段」、§14.1「配置项被读取却从未使用」
- **证据**：静态确定 —— `MultiDatasource` 把 `maxWaiting` 传给 `DatabasePool`，同时把 `connectTimeout`（默认 50ms，`Config.cj:122-124`）也传进去；`DatabasePool.getConnection(timeout!: Duration = connectTimeout)`（`f_dbpool/src/DatabasePool.cj:224`）与无参 `connect()`（同文件 `:242`）都只用 `connectTimeout` 作为等待上限；`KeyPool.get` 明确写 `let limit = if (timeout == Duration.Max) { maxWaiting } else { timeout }`（`f_pool/src/KeyPool.cj:764`）。multid 路径永远不会传 `Duration.Max`，故 `maxWaiting` 永远不参与计算。
- **描述**：README（`f_dbd/README.md:104`）与设计（`doc/详细设计.md:773`）都承诺该项是「池耗尽等待上限（`0`=无限等待）」。实际行为：默认 `maxSize=1`/节点、`ConnectTimeout=50ms`，并发借连接超过 50ms 就返回 `TIMEOUT`；用户把 `MaxWaiting` 调到 30s 也无效，只能改 `ConnectTimeout`。这会把正常的排队等待误报成超时，且配置语义与文档相反。
- **建议**：二选一 —— ①`MultiDatasource` 不再把 `connectTimeout` 当借用等待，改传 `Duration.Max` 让 `maxWaiting` 生效（建链超时另走 `connection_timeout` 选项）；②删掉 `getMaxWaiting()` 与 README/设计里的该项，只保留 `ConnectTimeout` 作为借用等待，并改文档说明。无论哪种，都要在 `Datasource.cj` 的注释里写明「哪个配置决定借用等待」。

### [一般][存量] `MultiDatasource.connect()` 只映射 `ConnectionException`，其余异常（含负载均衡器自身抛出的）原样逃逸

- **位置**：`f_dbd/src/multid/Datasource.cj:113-122`
- **来源**：存量（快照模式无基线）
- **判据**：review-checklist §11（错误处理缺失 / 契约不符）、§12.1（并发路径）
- **证据**：静态确定（catch 覆盖范围）＋需实测（触发概率）—— `catch (e: ConnectionException)` 之外的异常全部不包装。`loadbalance.call(())` 的实现是 `tree.forward(algo.next(), inclusive: true).next().getOrThrow()[1](data)`（`f_concurrent/src/LoadBalance.cj:88-90`），`getOrThrow()` 在「找不到桶」时抛通用异常；而 `RoundRobin.next()` 的自增在锁内、回绕判断在锁外（`f_concurrent/src/LoadBalance.cj:35-49`）：线程 A 把 `current` 推到 `Σw+1` 后让出，线程 B 读到 `Σw+1` 并返回，`forward(Σw+1)` 为空 ⇒ 抛非 `DbdException`。
- **描述**：`roundrobin` 是本模块默认可选算法之一，`MultiDatasource.connect()` 在多线程借用时会偶发抛出 f_concurrent 的通用异常（不是 `SqlException`），破坏 README:142 的异常契约；调用方也无法按错误码区分「池耗尽」「节点不可达」「算法越界」。`LoadBalance.call` 里若节点闭包抛 `DbdException(IO)` 则会原样透传（可接受），但没有任何统一出口。
- **建议**：`connect()` 用 `catch (e: DbdException) { rethrow }` + `catch (e: Exception) { throw DbdException(INTERNAL, ..., cause: e) }` 兜底；同时给 `f_concurrent.RoundRobin.next()` 加锁内回绕（属于 f_concurrent 的存量问题，另单独立项）。若无法改 f_concurrent，至少在 `MultiDatasource` 侧把越界异常归一成 `INTERNAL` 并记录算法名与 `Σw`。

### [一般][存量] README 把 `MultiDConfig` 的 `protected` 静态方法列为「模块级 public API」

- **位置**：`f_dbd/src/multid/Config.cj:29`（`protected struct MultiDConfig`）+ `:50,70,85,...`（`public static func get*`）
- **来源**：存量（快照模式无基线）
- **判据**：review-checklist §13（文档与实现不符）/ §14.2（公开 API 清单错误）
- **证据**：静态确定 —— 顶层声明是 `protected struct`，其 `public` 成员对外不可达（只在模块内可见）；仓内除 `f_dbd.multid` 包与测试外无引用。README `f_dbd/README.md:165` 却把 `getCheckInterval` / `getCheckOnBorrowing` / `getCheckOnCreation` / `getCheckOnReturning` / `getCheckSql` / `getConnectTimeout` / `getConnectionLife` / `getIdleTimeout` / `getInitSize` / `getLoadBalance` / `getMaxSize` / `getMaxWaiting` / `getMinSize` / `getWeights` 全部列为「模块级」公开函数；全仓搜索确认没有同名模块级 `func`（只有 `Config.cj` 内的 `MultiDConfig` 静态方法）。
- **描述**：外部使用者按 README 调用 `f_dbd.multid.getCheckSql()` 之类会编译失败（`MultiDConfig` 不可见、方法也不是模块级）。这是「写了但写错」的契约错误，会把使用者带沟里。
- **建议**：改 README：这 14 个函数标注为「内部配置读取（`MultiDConfig`，`protected`）」，或若确实需要对外开放，则在 `Config.cj` 增加模块级 `public func` 转发（并明确语义）。推荐前者，避免把配置实现细节固化成公开 API。

### [轻微][存量] `MultiDConfig` 数值项没有范围校验：负值静默生效，超大值在 `Duration *` / 权重求和处溢出并抛非 `DbdException`

- **位置**：`f_dbd/src/multid/Config.cj:110-134`（`Duration.second * intOf(...)` / `Duration.millisecond * intOf(...)`）、`f_dbd/src/multid/Datasource.cj:56-59`（`total += weight`）
- **来源**：存量（快照模式无基线）
- **判据**：review-checklist §11（缺少边界校验）
- **证据**：静态确定（代码路径）＋待确认（`Duration` 乘法溢出后的具体异常类型）—— `intOf` 只做 `tryParse`，不校验正负与上界；`Int64` 运算溢出按仓颉默认策略抛异常（开发指南 `basic_data_type/integer.md:137`）。例如 `multidbm_databasePoolConnectionLife=9223372036854775807` 会让 `Duration.second * n` 溢出，在 `MultiDatasource` 构造期抛出非 `DbdException`；`multidbm_loadbalance` 写两个接近 `Int64.Max` 的权重会让 `total` 溢出成负数，`Int64Weight(1, total)` / `RoundRobin(1,1,total)` 以非法区间构造。负值则被静默接受：`IdleTimeout` 为负等价于「不过期」（与 0 同义），`ConnectionLife` 为负同样绕过寿命检查。
- **描述**：配置错误属于部署期高频问题，当前表现是「启动时抛一个与数据库无关的算术异常」或「策略静默失效」，都不满足「非法配置 → `DbdException(CONFIG)`」的既有风格（`DbdUrl` 与 `effectiveWeights` 都做了这一点）。
- **建议**：在 `intOf` 外增加 `positiveIntOf(key, fallback, max)`：拒绝负数、拒绝超过 `Duration` 可表示范围的毫秒/秒数，超限时回落 fallback 并 WARN（与 `DbdOptions.timeoutOf` 的口径一致）；`effectiveWeights` 求和前用 `Int64.Max - total` 做上界检查，溢出 → `DbdException(CONFIG)`。

### [轻微][存量] 零权重节点仍会建池、建连接（`initSize`>0 时白占 TCP 与线程）

- **位置**：`f_dbd/src/multid/Datasource.cj:75-89`（对所有节点建池）与 `:94-99`（只注册 `weight > 0` 的节点）
- **来源**：存量（快照模式无基线）
- **判据**：review-checklist §7（缩短生命周期）/ §11（资源使用不对称）
- **证据**：静态确定 —— `builtPools` 循环遍历全部 `datasources`，零权重节点照样 `DatabasePool(datasource, initSize: 1, ...)`；随后注册时 `if (weights[i] > 0)` 跳过该节点，池从此无人借用。
- **描述**：默认 `initSize=1` 时，每个 `weight=0` 的节点都会常驻 1 条 TCP、f_net 读写线程与心跳，且它不在任何负载均衡桶里。运维用「权重 0」做摘流时，连接并不会停（与「摘流」的直觉相反），反而多一条永不使用的连接。
- **建议**：`weights[i] == 0` 时跳过建池（或建池但 `initSize: 0`），并在文档里写明「权重 0 = 不建连」。若要保持池结构，至少把 `initSize` 传 `if (weights[i] > 0) initSize else 0`。

### [轻微][存量] 同一「命令校验」逻辑写了三份，且 `ping` 的 `ERROR` 分支与另两处不一致（丢了错误码）

- **位置**：`f_dbd/src/driver/DbdTransport.cj:74-80`（`unsubscribe`）、`:89-93`（`ping`）、`:118-124`（`checked`）
- **来源**：存量（快照模式无基线）
- **判据**：review-checklist §2（表现形式不同的重复逻辑，含「近似重复但少一处边界」）
- **证据**：静态确定 —— 三处都是「`ACK`/`RESP` → 通过；`ERROR` → 抛；其它 → `PROTOCOL`」的同一判定，只有通过用的命令名不同。`request` 走 `checked`（`ERROR` → `errorOf` 保留 `DbdErrorCode`），`unsubscribe` 也走 `errorOf`，而 `ping`（`:90-93`）把 `ERROR` 落进 `other` 分支，报成 `PROTOCOL` 并丢掉服务端错误码与 `sqlState`。
- **描述**：这是重复逻辑已经造成行为漂移的实例：同一个「服务端回 ERROR」在 `request`/`unsubscribe` 里是可诊断的业务错误，在 `ping` 里变成协议错误，排障时会被误导（心跳失败的真实原因被掩盖成 PROTOCOL）。
- **建议**：抽 `private func expect(resp: Message, ok: (Command) -> Bool, request: String): Message`（或两个薄封装 `expectAck` / `expectResp`），统一 `ERROR → errorOf`；`ping` 对 `ACK` 通过、`ERROR` 还原错误码、其它 `PROTOCOL`。

### [轻微][存量] 死代码：`StubFdbm.consumes()` / `StubFdbm.clear()` 全仓零引用，`getGCCount` 导入未使用

- **位置**：`f_dbd/src/driver/stub_fdbm_test.cj:80-88`（`consumes`）、`:91-94`（`clear`）；`f_dbd/src/driver/PayloadWrapping_test.cj:21`（`getGCCount`）
- **来源**：存量（快照模式无基线）
- **判据**：review-checklist §1（非 public 符号无调用者 / 未使用的 `import`）
- **证据**：静态确定 —— `class StubFdbm` 默认 `internal`、成员默认 `internal`；全仓（排除 `.worktrees/`）`grep -rn "\.consumes()"` 与 `".clear()"` 只有定义行，无调用点（其余 `.clear()` 命中都是 `parameters.clear()` / `MOCKDB.clear()` 等其它对象）。`getGCCount` 在文件中只出现在 import 行。
- **描述**：注释说 `consumes()` 是「Node 站位用得到」，但对应的站位用例并不存在；`clear()` 注释说「多阶段用例分段断言」，实际没有用例使用。测试替身的死方法会随实现漂移（`QueryScript` 已替代它的用途），留着只会误导下一位读者。
- **建议**：删掉这两个方法与未使用的导入；若确实需要「按命令过滤」的能力，让 `QueryScript`/`allReceived` 承担，不要保留两套。

### [轻微][存量] 重复逻辑：`codeOf` 三份、`legacySqlPayloadOf` 复制生产实现、`toUrl`/`toUrlMasked` 近似重复、测试 setup 行逐字复制

- **位置**：`f_dbd/src/driver/testkit_test.cj:27` / `f_dbd/src/multid/MultiD_test.cj:209` / `f_dbd/src/common/result_test.cj:627`（`codeOf` 三份）；`f_dbd/src/driver/PayloadWrapping_test.cj:30-47` vs `f_dbd/src/driver/DbdStatement.cj:249-266`；`f_dbd/src/driver/DbdUrl.cj:124-131` vs `:143-150`；`f_dbd/src/multid/MultiDTestSetup_test.cj:22` vs `f_dbd/src/driver/DbdTestSetup_test.cj:22`
- **来源**：存量（快照模式无基线）
- **判据**：review-checklist §2（语义相同的实现散落多处）
- **证据**：静态确定 —— `codeOf` 三份逐行相同（只差 `DbdErrorCode` 前缀）；`legacySqlPayloadOf` 与 `sqlPayloadOf` 除 `add<DataAny>(DataAny(data))` / `add<Data>(data)` 外逐行相同；`toUrl` 与 `toUrlMasked` 只有 `userInfo` 一行不同；两个 `testProtocolHostIdSetup` 是同一 `Config.set` 字面量在两个包各写一遍。
- **描述**：`codeOf` / setup 是跨包测试辅助，跨包复制有一定合理性（测试构建才可见），但三份会各自漂移；`legacySqlPayloadOf` 作为「旧写法基准」没有版本来源注释，生产实现一改它就跟着「一起对」，等价性断言会失效（当前只验证了 `Data`/`DataAny` 包装的编码等价）；`toUrl*` 的 mask 差异适合参数化。
- **建议**：①`codeOf`/`messageOf` 收敛到各包一个 `testkit_test.cj`，或放到 `f_dbd` 的 `*_test` 共享文件（同包才可见时至少加注释指明另外两份的位置）；②`legacySqlPayloadOf` 注释里补「来自 commit/版本」，或改成「手工期望字节」的黄金样本，避免复制实现；③`toUrl` 内部调 `render(maskPassword: Bool)`；④setup 行保留但注释交叉引用。

### [轻微][存量] `database` 首段口径不一致：`DbdUrl` 去掉 `?`，`MultiDUrl` 不去

- **位置**：`f_dbd/src/driver/DbdUrl.cj:165-177`（`firstSegmentOf` 同时按 `?` 与 `/` 截断）vs `f_dbd/src/multid/Url.cj:114-119`（`firstSegment` 只按 `/`）
- **来源**：存量（快照模式无基线）
- **判据**：review-checklist §2（近似重复但边界不同）/ §11（语义漂移）
- **证据**：静态确定 —— `DbdUrl.parse('fdbm://h/db?charset=utf8').database == 'db'`（`DbdUrl_test.cj:72` 已钉死）；`MultiDUrl.parse('multidbm://h/db?charset=utf8')` 的 `database` 为 `'db?charset=utf8'`，而各节点 `DbdUrl.database` 为 `'db'`。两个公开类型对同一个 URL 给出不同的库名。
- **描述**：`MultiDUrl` 是公开 API（`public let database`），调用方若用它与 `nodes[0].database` 比对会不一致；`MultiDUrl` 自己的单测只覆盖了 `/db0/extra`（`MultiD_test.cj:151-156`），没覆盖 `?`。`Url.cj` 属第 4 部分，但根因是 `DbdUrl` 的 `firstSegmentOf` 没有复用/没有对齐，故在此记录并合并。
- **建议**：把「首段截断」抽成 `f_dbd.common` 的一个包内函数（`?`/`/`/`#` 都截断），`DbdUrl` 与 `MultiDUrl` 共用；补 `MultiDUrl` 的 `?` 用例。

### [轻微][存量] 节点不可达与池耗尽都映射成 `TIMEOUT`，原始原因被上游丢弃

- **位置**：`f_dbd/src/multid/Datasource.cj:115-121`
- **来源**：存量（快照模式无基线）
- **判据**：review-checklist §11（错误处理不精确 / 契约与注释不符）
- **证据**：静态确定 —— `DatabasePool.connect()` 是 `getConnection().getOrThrow{ConnectionException()}`（`f_dbpool/src/DatabasePool.cj:242`），空工厂丢掉 creator 的原始异常；`MultiDatasource` 只按「池是否关闭」二分，其余一律 `TIMEOUT`（注释也这么写）。节点 TCP 建链失败、握手失败最终都以「cannot borrow ... :」+空消息的 `TIMEOUT` 呈现。
- **描述**：这与 `DbdDatasource` 的对外承诺（建链失败 → `IO`）不一致：同一个节点故障，走单节点数据源得到 `IO`，走 multid 得到 `TIMEOUT`。排障时无法区分「节点挂了」和「池太小/排队久」。
- **建议**：`DatabasePool` 侧把 creator 的异常保留为 cause（上游改动）；在 multid 侧至少区分「`anyPoolClosed` → CONFIG」「cause 是 `DbdException(IO)` → IO」「否则 TIMEOUT」，并在消息里带节点索引。

### [轻微][存量] 文档漂移：`placeholder.cj` 仍称「阶段 0 仅建骨架」；设计 §5.9 的 `DbdTransport.init` 多一个 `options` 参数；`getMaxWaiting` 注释只说 `0` 而实现是 `<= 0`

- **位置**：`f_dbd/src/driver/placeholder.cj:19`；`f_dbd/doc/详细设计.md:740`（`init(host, port, options: DbdOptions)`）vs `f_dbd/src/driver/DbdTransport.cj:49`；`f_dbd/src/multid/Config.cj:126-134`（doc 说「`0` → `Duration.Max`」，代码是 `ms <= 0`）
- **来源**：存量（快照模式无基线）
- **判据**：review-checklist §13（文档过期 / 与实现不一致）
- **证据**：静态确定 —— 三处均可在源码比对；`DbdTransport.cj:39` 还有一处明显拼写错误（`idyllically with code` 应为 `ideally`）。
- **描述**：`placeholder.cj` 是包级说明文件，读者会据此以为 driver 包只有骨架，而实际已完整实现传输/连接/语句；设计文档的签名与实现不符会让按设计写代码的人多传一个参数；`getMaxWaiting` 注释漏了负值分支（负数同样变无限等待，属于未声明行为）。
- **建议**：把 `placeholder.cj` 改成「包职责 + 入口清单」，删除「阶段 0」；设计文档同步去掉 `options` 参数（或在实现里接收并断言未使用）；`getMaxWaiting` 注释改为「`<= 0` → `Duration.Max`」，并在 `intOf` 层按上一条拒绝负值。

### [轻微][存量] `freePort()` 先 bind 再 close 再交给 `Server`，存在 TOCTOU，测试偶发「端口被占」

- **位置**：`f_dbd/src/driver/stub_fdbm_test.cj:102-112`（`freePort`）与 `:45-46`（`Server(bindAt: port, ...)`）
- **来源**：存量（快照模式无基线）
- **判据**：review-checklist §11（边界 / 资源时序）
- **证据**：静态确定（时序）＋需实测（出现频率）—— 探测 socket 关闭到 `Server` 重新 bind 之间，端口可被同机其它进程/并行用例抢走；并行跑 `cjpm test` 时窗口更大。
- **描述**：失败表现为 `Server` 构造抛绑定异常或客户端连到别人的端口，用例随机失败，且失败信息与真实原因无关。
- **建议**：让 `Server` 直接支持 `bindAt: 0` 并回读实际端口（若已支持，则去掉探测）；否则在 `freePort` 外层加重试（最多 3 次，捕获绑定异常后重新探测），并在失败时打印「port race」提示。

### [轻微][存量] `Reexport_test.typeIdentity` 的 `throw/catch` 是空动作，「跨包同一性」断言并未真正验证

- **位置**：`f_dbd/src/exception/Reexport_test.cj:58-68`
- **来源**：存量（快照模式无基线）
- **判据**：review-checklist §3（`catch { () }` 静默吞掉）/ §11（测试未覆盖宣称的契约）
- **证据**：静态确定 —— `typeIdentity` 先 `throw e` 再 `catch (_: Exception) { () }`，既不改变 `e` 也不产生断言；随后的 `match (e) { case x: DbdException => ... }` 只证明传入值本身是 `DbdException`。测试注释声称「从 `exception` 包构造、按 `SqlException` 捕获」证明两包类型身份相同，但 `usableFromExceptionPackage` 里的 `DbdException(...)` 解析到的就是 `public import` 进来的同一个符号，没有第二个类型可对比。
- **描述**：该用例实际验证的是「重导出可编译」，这是有价值的；但静默吞异常与无意义 throw 会让读者误以为在验证运行时身份，且未来若出现真正的双份定义也测不出来。
- **建议**：删掉 `throw/catch`，把断言改成「`DbdException` 实例可赋给 `SqlException` 并被 `catch (e: SqlException)` 接住、且 `e is DbdException`」；在注释里说明「同一性由 `public import` 保证，编译期即可证明」。

## 优化可行性方案

### [CPU] `DbdUrl.percentEncode` 逐字节构造临时数组与十六进制字符串

- **现状**：`toUrl()` / `toUrlMasked()` 每次调用对 user、database 逐 `Rune` 处理：ASCII 分支每个字符新建 `[UInt8]` 数组（`DbdUrl.cj:244-248`），非 ASCII 分支每个 `Rune` 新建 `String` 再取字节；每个「非 unreserved」字节还要 `toHex(byte).toAsciiUpper()` 生成两个临时 `String`（`:255-258`）。输入规模 = 凭据/库名长度（典型 < 100 字节）；`getMetaData()` 每次调用都会触发（`DbdConnection.cj:85,88`）。
- **方案**：改为单遍写 `ArrayList<Byte>`：ASCII 直接 `out.add(UInt8(UInt32(b)))`，非 ASCII 用 `String([b]).unsafeBytes()` 只在该分支执行；十六进制用 `const HEX: Array<UInt8>` 直接写两位（`out.add(HEX[byte >> 4]); out.add(HEX[byte & 0xf])`），彻底去掉 `toHex`/`toAsciiUpper` 与逐字符数组。
- **预期**：单次 `toUrl` 的临时对象从 O(字节数) 个降到 1 个 `ArrayList` + 1 个结果数组；凭据 40 字节时约省 40~80 次小对象分配（具体字节量待测，不作结论）。
- **代价**：无语义变化；需要保证 `HEX` 表大写、`isUnreserved` 判定不变（现有 `DbdUrl_test` 的往返用例可回归）。
- **验证**：`cjpm bench -O2`（同 SDK/机器，`toUrl` 1e6 次，取中位数与离散度）＋ `getAllocatedHeapSize()` 前后对照。
- **证据状态**：`无基线（待验证）`

### [CPU] `MultiDatasource.connect()` 每次借连接都走 `TreeMap.forward` + 闭包 + 轮询锁

- **现状**：每次 `connect()` → `LoadBalance.call` → `RoundRobin.next()` 取 `Mutex` 两次（`f_concurrent/src/LoadBalance.cj:35-49`）→ `TreeMap.forward` 分配迭代器 → 取闭包调 `pool.connect()`。桶数量 = 节点数（通常 2~8），单次成本很小，但这是每请求主路径。
- **方案**：在 `init` 后把「累计权重 → 池」展开成定长数组（大小 = `Σw`，或按最大公约数缩放），用 `AtomicInt64` 自增取模选下标；`roundrobin` 与 `random` 分别对应「自增取模」与「随机下标」，都不需要锁与树查找。只有在权重和很大（如 1e6）时才需要按节点数压缩成前缀和 + 二分。
- **预期**：借连接路径去掉 2 次 mutex 与 1 次迭代器分配；端到端收益取决于 `connect` 在请求中的占比（未知），因此只作为待验证项。
- **代价**：需保持「权重 0 不选中」「`Σw` 区间与现有语义一致」；必须保留 `LoadBalance` 的现有测试口径（`MultiDatasource_test.cj` 的 67/33、100/0 用例）。
- **验证**：`cjpm bench -O2` 对 `borrowAndCount` 场景 1e5 次借还，对照中位数；并用 `cjprof` 看 `RoundRobin.next`/`TreeMap.forward` 自耗时占比是否值得改。
- **证据状态**：`无基线（待验证）`

### [堆内存] `MultiDatasource` 长期持有 `nodes: Array<DbdUrl>`（含明文口令），初始化后不再使用

- **现状**：`private let nodes`（`Datasource.cj:34`）在 `init` 中只用于建 `datasources`（`:47-51`）与权重校验（`:55`），之后无任何读取；它让 N 个 `DbdUrl`（每节点 user/password/host/database 字符串）随 datasource 生命周期常驻。`DbdDatasource` 已各自持有 `DbdUrl`，属重复引用，不增加字符串本体，只增加 1 个数组 + 指针。
- **方案**：把 `nodes` 改成 `init` 内局部变量（或用 `parsed.nodes` 直接遍历），不落字段；若诊断需要，另存脱敏后的 `Array<String>`（`toUrlMasked()`）。
- **预期**：每 datasource 省 1 个 `Array` 头 + N 个指针（N 通常 < 10，收益为字节级），主要收益是减少明文口令的常驻副本（安全面）。
- **代价**：无行为变化；若后续要做「节点热替换/诊断输出」需要重新引入，届时用脱敏串。
- **验证**：`getAllocatedHeapSize()` 前后对照；代码审查确认无其它读取点。
- **证据状态**：`无基线（待验证）`

## 待验证假设

| # | 假设 | 位置 | 缺什么数据 | 怎么采 |
| --- | --- | --- | --- | --- |
| 1 | 传输层每请求的 `Message` 编解码与 `PendingRequests` 锁是 CPU 热点 | `f_dbd/src/driver/DbdTransport.cj:60-67` | 自耗时占比、调用次数 | `cjprof record` 跑 10k 次 `request`（桩回 RESP），看 `Message.decode` / `encode` / `PendingRequests` self time |
| 2 | `roundrobin` 下 `RoundRobin.next` 的 mutex 在高并发借用时成为串行段 | `f_dbd/src/multid/Datasource.cj:114` → `f_concurrent/src/LoadBalance.cj:35-49` | 锁等待时长、BLOCKED 线程数 | 8 线程 × 1e5 次 `connect/close`，采线程状态（jstack 等价物）＋ `cjprof` 无法覆盖锁竞争，需另采 |
| 3 | `DbdUrl.percentEncode` 的分配在 `getMetaData()` 频繁调用场景下占比可观 | `f_dbd/src/driver/DbdUrl.cj:241-266` | 分配量 / 调用频次 | 在 `getMetaData` 外层加计数埋点，跑 10 分钟稳态，`getAllocatedHeapSize()` 差值 |

## 范围外提示

- 本部分未展开：`DbdConnection` 的结果集闸门 check-then-act（已在 part2 报为严重）、`DbdDatasource.setOption` 与 `connect` 的选项竞态（part2 已报）、`f_concurrent.RoundRobin.next()` 回绕竞态（模块 f_concurrent 自身的问题，仅作为本部分 `connect()` 异常逃逸的触发路径引用）、`MultiDUrl`（`multid/Url.cj`，第 4 部分）。
- 存量缺陷共 15 条（一般 5 / 轻微 10），是否纳入修复待用户决定。

## 文件覆盖

| # | 文件 | 类型 | 已读 | 说明 |
| --- | --- | --- | --- | --- |
| 1 | `src/driver/DbdTransport.cj` | .cj | ✅ | 传输层；见发现 #1、#8 |
| 2 | `src/driver/DbdTransport_test.cj` | .cj | ✅ | 9 个用例覆盖 RESP/ERROR/PROTOCOL/TIMEOUT/ACK；未覆盖「transfer 抛异常」分支 |
| 3 | `src/driver/DbdUrl.cj` | .cj | ✅ | URL 解析/往返；见发现 #2、#10、#11 |
| 4 | `src/driver/DbdUrl_test.cj` | .cj | ✅ | 覆盖 IPv6、非 ASCII、% 往返、脱敏；`?` 查询参数丢失未测 |
| 5 | `src/driver/PayloadWrapping_test.cj` | .cj | ✅ | 等价性 + 可选分配基准；见发现 #9、#10 |
| 6 | `src/driver/placeholder.cj` | .cj | ✅ | 仅包级注释；内容过期（发现 #13） |
| 7 | `src/driver/stub_fdbm_test.cj` | .cj | ✅ | f_net Server 桩；死方法 + freePort TOCTOU（发现 #9、#14） |
| 8 | `src/driver/testkit_test.cj` | .cj | ✅ | codeOf/messageOf/waitUntil；跨包重复（发现 #10） |
| 9 | `src/exception/DbdException.cj` | .cj | ✅ | 单行 `public import` 重导出，与注释一致；无问题 |
| 10 | `src/exception/Reexport_test.cj` | .cj | ✅ | 重导出验收；无用例价值问题（发现 #15） |
| 11 | `src/multid/Config.cj` | .cj | ✅ | 14 个配置 getter；见发现 #3、#5、#6、#13 |
| 12 | `src/multid/Datasource.cj` | .cj | ✅ | 多节点路由/池；见发现 #3、#4、#7、#12 |
| 13 | `src/multid/MultiD.cj` | .cj | ✅ | 驱动注册与 open；无独立问题（静态 init 依赖见总评） |
| 14 | `src/multid/MultiDTestSetup_test.cj` | .cj | ✅ | 协议 hostId 测试前置；与 driver 同名文件逐字重复（发现 #10） |
| 15 | `src/multid/MultiD_test.cj` | .cj | ✅ | 配置/URL/驱动用例；`codeOf` 重复（发现 #10） |

合计：`.cj` 15 个 / `.md` 0 个 / 共 15 个，全部读完（本部分范围；模块其余 34 个文件由 part1/2/4 覆盖）。

## 覆盖自检

| 维度 | 命中 | 未命中时的说明 |
| --- | --- | --- |
| 正确性 / 设计 / 语言特性 / 可读性 / 安全性 | 8 | 正确性 #1/#10/#11/#12、设计 #5/#7、安全性 #2、可读性 #13；其余函数逐行核对边界与 `Option` 处理，未发现语言特性误用（`Option` 均被 `match` 消费） |
| §1 死代码 | 1 | 逐个 `private` / `internal` / 默认可见性符号全仓搜引用：`SCHEME`、`SCHEME_PREFIX`、`CHECK_DURATION`、`NO_TIMEOUT`、`firstSegmentOf`、`hexByte`、`nibbleOf`、`percentDecode/Encode`、`isUnreserved`、`parsePort`、`commandName`、`resp/error/ack/sqlOf/columnOf/isClose/twoColumnInfos`、`QueryScript.addCell/addBlock` 均有引用；`StubFdbm.consumes/clear` 零引用（#9）；`DbdUrl`/`MultiD`/`MultiDUrl`/`MultiDatasource`/`MultiDConfig` 的 public 成员对外可达或包内全被使用，不判 |
| §2 重复逻辑 | 2 | 同文件内函数体两两比对：`toUrl`/`toUrlMasked` 近似重复、`unsubscribe`/`ping`/`checked` 同判定（#8）；跨文件搜同字面量/同实现：`codeOf`×3、`legacySqlPayloadOf`、setup 行、`firstSegment` 口径差异（#10、#11）；`percentEncode/Decode` 全仓无现成工具，不构成重复 |
| §3 空实现 | 1 | 无空函数体、无 `TODO/FIXME`（全文件搜索为空）、无 `throw Unsupported`；`MultiD.init() {}` 是 `Driver` 实例化所需的合法空构造；`Reexport_test` 的 `catch { () }` 记一条（#15） |
| §4 栈溢出 | 0 | 全部函数无递归（`DbdUrl`/`MultiDatasource`/`DbdTransport` 均为单层循环），无自引用结构、无深拷贝 |
| §5 OOM | 0 | 无全量物化：`percentDecode/Encode` 按输入长度线性分配、`DbdTransport` 队列固定 1024、`MultiDatasource` 池有 `maxSize`；`StubFdbm.records` 只增不减但仅测试进程生命周期内存在 |
| §6.1 热点瓶颈 | 0 | 未提供 profile / bench 数据，按规则不成立；已列入「待验证假设」1~3 |
| §6.2 大粒度锁 | 0 | 本部分无 I/O/解析/日志在锁内：`RoundRobin` 的 mutex 只包自增（见 #4 的竞态，但不是粒度问题）；`MultiDatasource` 无锁 |
| §6.3 并发串行 | 0 | 无 `spawn` + 立即 `get`；`MultiDatasource` 借连接是直接调用，不存在任务窗口 |
| §6.4 低效算法 | 0 | 无嵌套扫描/重复 `contains`；`DbdUrl` 解析与 `percent*` 均为 O(n) 单遍；`MultiDatasource.connect` 的 `anyPoolClosed` 只在异常路径 O(节点数) |
| §7 降堆内存方案 | 1 | `nodes` 常驻凭据副本（方案 3）；其余对象生命周期短、规模小，无可证收益 |
| §8 降 CPU 方案 | 2 | `percentEncode`（方案 1）、借连接路径（方案 2）；均无基线 |
| §9 local mode 可行性 | 0 | 本部分函数内临时对象规模与 URL/节点数同阶（字节~百字节级），无峰值内存证据；且 `String.withRawData` 结果要逃逸，未做改造评估 |
| §11 现有代码的 BUG（存量） | 10 | 15 条发现全部为存量；其中错误处理/边界/契约类 #1~#4、#6、#7、#10~#12、#14 共 10 条归本维 |
| §12 并发安全与锁粒度 | 1 | `MultiDatasource.connect` 的异常映射在并发借用下可被 `RoundRobin` 竞态触发（#4）；`MultiDatasource` 其余字段不可变 + `AtomicBool`，`DbdTransport` 依赖 f_net 的线程安全 `transfer`（已核对 `PendingRequests` 按 id 分发）；单线程测试桩无共享路径 |
| §14 功能完备性与 README 覆盖 | 2 | `MaxWaiting` 接线缺失（#3）、README 把内部 getter 当公开 API（#5）；本部分其它 public 声明（`DbdUrl`/`MultiDUrl`/`MultiDatasource`/`DbdException`）在 README 均有对应段落 |
| 文件覆盖（§13 等） | 15/15 | 本部分 15 个文件全部读完；模块级 README/`doc/**` 归 part1/2/4，本部分只做与所辖文件相关的交叉核对（#5、#12） |

## 模块统计

| 严重程度 | 数量 |
| --- | --- |
| 严重 | 0 |
| 一般 | 5 |
| 轻微 | 10 |
| 优化方案（堆内存 / CPU） | 1 / 2 |

## 总评

本部分代码整体质量良好：`DbdUrl` 的解析边界（IPv6、`%` 字节级往返、非 ASCII、端口范围）覆盖得很完整，测试用真实 `Server<DataAny>` 桩断言「发了什么」而不只是「收到什么」，`DbdTransport` 的失败路径也有清晰的书面设计（§7.4 拆链、`ERROR` 还原错误码）。没有发现栈溢出、OOM、空实现或公共 API 未接线的问题。

需要优先处理的是三条「契约不闭合」的问题：①`DbdTransport` 只处理 `None`，f_net 直接抛出的异常会以非 `DbdException` 穿透并可能留下半死连接（#1）；②`DbdUrl` 的解析异常把明文口令写进消息，和 `toUrlMasked()` 的脱敏初衷相反（#2）；③`multidbm_databasePoolMaxWaiting` 在 multid 路径完全无效，默认 50ms 的借用等待会把正常排队误报成 `TIMEOUT`（#3）。这三条都在启动/失败主路径上，建议本轮修复。

其余为可维护性与一致性改进（重复逻辑、死测试方法、文档漂移、`database` 口径），可排期。存量缺陷共 15 条（一般 5 / 轻微 10），是否纳入修复待用户决定；其中 #1、#2、#3 建议纳入。
