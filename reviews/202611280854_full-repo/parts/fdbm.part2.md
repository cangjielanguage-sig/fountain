# fdbm 模块审查报告（模块第 2/6 部分）

- **审查日期**：2026-11-28
- **模块路径**：`fdbm`（本部分 0 个 `.cj` + 3 个 `.md`，共 3 个文件）
- **基线**：工作区快照（`master` 与 `sts/1.3.x` 同一提交 `120fd2542`，`git diff` 为空）⇒ 全部问题来源为「存量」
- **审查重点**：fdbm 专项（多数据源与连接生命周期、启动期装配、并发安全、死代码、重复逻辑）在**文档侧**的落点——`详细设计.md` / `开发计划.md` / 归档变更 `spec.md` 与当前 `src/` 的一致性（清单 §13 / §14），并对文档承诺的协议语义（无预读、UNSUBSCRIBE、流列、会话键、启动装配）逐条取证到源码
- **报告版本**：v1（分部分报告，未合并；按要求不写 `docs/review/` 下的模块报告）

> 本部分清单只有文档，没有源码，因此「发现」以**文档 ↔ 实现不一致**为主；其中必然要用到源码取证（行号两侧都给）。`doc/spec/implement-f-dbd-driver-and-fdbm-server/specs/fdbm/spec.md` 属清单 §13 误报边界中的「已归档变更」，按「当时结论是否自洽」核对，不与当前实现强求一致（下面涉及它的地方都已标注）。

## 发现

### [一般][存量] §10.6 的 `boot.sh` 示例与 `normalize()` 的值解析不兼容，按示例部署二次启动会失效

- **位置**：`fdbm/doc/详细设计.md:1037`、`:1039`、`:1041`、`:1114`（示例把 `fdbm_bootScript` / `fdbm_driverDir` / `fdbm_customDir` / `fdbm_cachePath` 写成 `"$(cd "$(dirname "$0")" && pwd)/…"`）；实现 `fdbm/src/config/BootScriptWriter.cj:343-355`（`parseExport` → `shellUnquote`）、`:510-515`（只剥单引号）、`:497-507`（`shellQuote` 无条件包单引号）、`:169-188`（重渲染整块）
- **来源**：存量（快照模式无基线）
- **判据**：review-checklist §13「示例代码不能用」「规格与实现漂移」；文档自身 §3.5 第 5/7 条（`详细设计.md:286-289`，要求「值按 shell 单引号转义」「两次 flush 字节一致」）
- **证据**：静态确定 —— `shellUnquote` 只在「首尾都是单引号」时剥一层，双引号值**原样返回**（含 `"` 与 `$`）；`renderBlock` 再用 `shellQuote` 整体包单引号。因此示例行会被重写成 `export fdbm_bootScript='"$(cd "$(dirname "$0")" && pwd)/boot.sh"'`，shell 不再做命令替换
- **描述**：`normalize()` 在 `FdbmServer` 构造期无条件执行（`fdbm/src/server/FdbmServer.cj:136`、`:226-235`）。按 §10.6 落地的脚本**第一次启动就被改写**：当前进程不受影响（环境变量已展开），**下一次启动** `fdbm_bootScript` 是含字面 `"`/`$` 的路径（`bootScriptOf` 拿不到可读文件 → `export` 落盘不可用），`fdbm_driverDir` 同理失效 → `DriverLoader` 找不到驱动目录 → `NO_DRIVER` → 进程以 1 退出。与文档「规范脚本不产生写回 / 幂等」的承诺相反
- **建议**：`parseExport` 对双引号 / `$(...)` / 反引号值**整行保留、不参与重渲染**（或记 WARN 后跳过该键）；§10.6 示例改成生成器真实输出（`'./boot.sh'` 这类相对路径，见 `fdbm/boot.sh:12-20`）。用例：取 §10.6 脚本连续 `normalize()` 两次，断言第二次返回 `false` 且 `export fdbm_bootScript=` 行语义不变

### [一般][存量] `bufSize` 三档语义：§9.1 与 §14.4 自相矛盾，且 §9.1 / 开发计划与实现相反

- **位置**：`fdbm/doc/详细设计.md:738`（§9.1 注释「`readChunk(stream, bufSize)` 读下一块（`bufSize<=0` → `DEFAULT_STREAM_CHUNK`）」）、`fdbm/doc/详细设计.md:1249`（§14.4「首次打开流列发送 `CELL(index, bufSize = -1)` 探测 NULL」）、`fdbm/doc/开发计划.md:222`（阶段 7 Step 7.1 验收项 ⑤ 同 §9.1 口径）；实现 `fdbm/src/execute/cursor.cj:170-186`
- **来源**：存量（快照模式无基线）
- **判据**：review-checklist §13「API / 默认值与源码不符」「文档内部不一致」；§11「语义与文档不符」
- **证据**：静态确定 —— 实现 `<0` 走 NULL 探测（`getOrNull<InputStream>`，NULL 回 `DataNone`，否则回**首块**），`==0` 才用 `DEFAULT_STREAM_CHUNK`（`cursor.cj:170-178`、`:186`）
- **描述**：同一份详细设计对 `bufSize` 给了两种口径。按 §9.1 写客户端：对 NULL 列发 `-1` 会得到 `DataNone`（被当成「空块」或直接判 EOF），对非 NULL 列发 `-1` 得到的是首块而非后续块；按 §14.4 写才对。这是线上列读协议，不是措辞问题
- **建议**：§9.1 注释改成三档（`<0` = NULL 探测，回 `DataNone` 或首块；`=0` = `DEFAULT_STREAM_CHUNK`；`>0` = 指定字节数），`开发计划.md:222` ⑤ 同步；归档 `spec.md:100-104` 的 `<=0` 保留原文，只在 §9.1 加一句「已被 §14.4 取代」

### [一般][存量] 流列 `-1` 分支绕过句柄缓存：重复探测会重复打开并重放首块（违反 §9.1 规则 5 与 spec MUST）

- **位置**：`fdbm/src/execute/cursor.cj:170-178`；文档 `fdbm/doc/详细设计.md:769`（规则 5「绝不重复打开」）、`:752`、`:739`；`fdbm/doc/spec/.../spec.md:82-86`（「`get<InputStream>` 只被调用 1 次」）
- **来源**：存量（快照模式无基线）
- **判据**：review-checklist §11「契约与实现不符」、§13；spec 的 MUST 项
- **证据**：静态确定 —— `if (bufSize < 0)` 分支直接 `currentResult().getOrNull<InputStream>(index)` 并覆盖 `streams[index]`，**不查** `streams`；只有 `>=0` 路径先查缓存（`:179-185`）
- **描述**：`bufSize` 由客户端控制。同一行同一列发第二次 `-1`：物理 `get<InputStream>` 再次执行（对真流式驱动等于重取列值，旧句柄被覆盖且未关闭），返回的又是**第一块**，块序错乱。文档把「每行每列只打开一次」当服务端契约（§9.1 规则 5），实现只在 `>=0` 路径上成立；§14.4 仅约定「客户端只发一次」，服务端没有防御
- **建议**：`<0` 分支先查 `streams`，已存在则按 `DEFAULT_STREAM_CHUNK` 读下一块（或回 `CURSOR_STATE` 拒绝重复探测）；首次打开后缓存。用例：连续两次 `cell(i, -1)`，断言打开计数为 1 且第二次不是首块重放

### [一般][存量] §2 包结构表把自定义扩展写成 `fountain::fdbm.custom` / `src/custom/`，仓库无此目录

- **位置**：`fdbm/doc/详细设计.md:76`；实现 `fdbm/src/server/CustomLoader.cj:16`（`package fountain::fdbm.server`）、`:29`（`CustomExtensions`）、`:65`（`CustomLoader`）
- **来源**：存量（快照模式无基线）
- **判据**：review-checklist §13「链接 / 路径失效」「文档过期（已改名）」；§14.1「接线缺失」的文档侧对应
- **证据**：静态确定 —— `fdbm/src/custom` 不存在，`CustomExtensions`/`CustomLoader` 都在 `server` 包；同一文档 §10.5 也把它们放在 server 章节
- **描述**：§2 与 §10.5 互相矛盾。按 §2 找扩展入口（`custom` 包的职责、依赖 f_app/f_dbm/f_log）会落空，判断「`execute` 能否依赖自定义扩展」会得出错误结论
- **建议**：删除该行或改为 `fountain::fdbm.server`（`CustomLoader.cj`），依赖列写 `f_app / f_dbm / f_log / exception`

### [一般][存量] §10.3 声称会话键是连接对象，实现用 `remoteAddress` 文本

- **位置**：`fdbm/doc/详细设计.md:939`（「键即连接对象，不需要断连回调」）、`:925-929`；实现 `fdbm/src/server/SessionRegistry.cj:46-58`、`:152-159`（`keyOf` = `buffer.remoteAddress.toString()`）
- **来源**：存量（快照模式无基线）
- **判据**：review-checklist §13；§12.1「跨线程资源 / 会话隔离」
- **证据**：漂移静态确定；后果待确认 —— 「同一 4 元组在旧会话被巡检移除前被复用」需要 `f_net` 侧地址复用与 TCP 复用路径的证据
- **描述**：`of()` 只按地址文本查表。若旧会话仍在表里（巡检周期 30s 内）而新连接复用了同一地址，`of()` 直接返回旧 `DbdSession`，它带着上一条连接的游标与事务 pin，而 `session.buffer` 指向旧连接——文档「键即连接对象」的隔离承诺不成立。`size()` 与巡检也按文本键聚合
- **建议**：用连接身份（或 `f_net` 暴露的连接 id）做键；坚持文本键时在 `of()` 校验 `session.buffer` 与入参为同一对象，不同则关闭旧会话再新建。用例：同地址字符串的两个不同 buffer，断言 `of()` 返回不同会话

### [一般][存量] 详细设计的类型声明与签名已落后于实现（多处悬空引用）

- **位置**（文档 → 实现）：
  - `fdbm/doc/详细设计.md:396-398`：三个独立类 `Crc16Partition` / `Crc32Partition` / `Crc64Partition`。实现是单个 `protected class CrcPartition`（`fdbm/src/route/algorithms.cj:172`），三个类名在 `src/` 中不存在；`开发计划.md:162` 同
  - `fdbm/doc/详细设计.md:339-344`：`protected struct DatabaseResources` + 字段 `readNodes`/`writeNodes`/`pools`/`names`。实现为 `protected class`（`fdbm/src/resources/DatabaseResources.cj:46`），字段是 `readNodes_`/`writeNodes_`（`:48-49`），另有 `writePools`/`readPoolNames`/`poolLabels`/`driverNames`/`closed`
  - `fdbm/doc/详细设计.md:707`：`installCursor(cursor: QueryCursor): Unit`。实现返回 `Bool`（`fdbm/src/execute/session.cj:100`，`false` 表示会话已关闭且新游标已被关闭）
  - `fdbm/doc/详细设计.md:783-789`：`ExecutorDispatcher.init(router, globals, resources, idMakers, bootScript, config: FdbmConfig)`。实现 8 参（`idmaker`、`sequenceDatabase`、`customIdGenerators`、`catalog!`，`fdbm/src/execute/dispatcher.cj:44-47`），`FdbmConfig` 不再是入参
  - `fdbm/doc/详细设计.md:886`：要求 `Server<DataAny>(bufferQueueSize!: …)` 显式传。实现未传（`fdbm/src/server/FdbmServer.cj:155-160`）
  - `fdbm/doc/详细设计.md:127-147`（§3.2）：成员全写 `public static func`，实现是包内 `static func`（`fdbm/src/config/FdbmConfig.cj:40`）；清单缺 `getPartitionStep`（`:140`）、`getLogicalDatabases`（`:149`）、`getCheckDuration`（`:317`）、`getUnavailableChecked`（`:325`）、`getSequenceDatabase`（`:337`）；`validate` 实际多 `source!` 参数（`:376-377`）
  - `fdbm/doc/详细设计.md:44-60`（§1.2 依赖表）：漏 `fountain::f_data`（`fdbm/cjpm.toml:7`）
- **来源**：存量（快照模式无基线）
- **判据**：review-checklist §13「API 与源码不符」「文档过期」；§14.1「接线缺失」
- **证据**：静态确定 —— 上述符号在全仓搜索要么不存在（`Crc16Partition` 等），要么签名不同（`installCursor`、`ExecutorDispatcher.init`）
- **描述**：详细设计是唯一的实现说明（README 只讲用法），但它记录的是编码期草案：算法类被合并、`struct` 变 `class`、两个关键签名改了没回填、config 成员表不完整。按文档找代码会落空，按文档写扩展会编译不过（`installCursor` 的返回值、`ExecutorDispatcher` 的参数个数）
- **建议**：以 `src/` 为准回填 §1.2 / §3.2 / §5 / §6.1 / §9.1 / §9.2 / §10.1；或在这些片段前统一标注「示意，签名以源码为准」

### [轻微][存量] §3.5 的写回细节与实现不符：END 标记、临时文件名、权限位三项

- **位置**：`fdbm/doc/详细设计.md:282-289`（只描述新旧两个标记、`boot.sh.tmp`、「复制原文件权限位」）；实现 `fdbm/src/config/BootScriptWriter.cj:35-37`（三个标记，含 `END_MARKER`）、`:188`（总会写 END 标记）、`:463`（临时文件是 `<target>.tmp.<serial>`）、`:454-458`（注释自认权限位与设计不符并称「已在详细设计登记」）
- **来源**：存量（快照模式无基线）
- **判据**：review-checklist §13「规格与实现漂移」
- **证据**：静态确定 —— 设计全文没有 `fdbm managed exports end`、没有 `.tmp.<serial>`、也没有权限位偏差的登记（「权限」只出现在 §3.5「复制权限位」与 §13 测试策略）
- **描述**：实现写出的区块比文档多一行 END 标记（`fdbm/boot.sh:93` 有，§10.6 示例 `:1030-1116` 没有）；代码注释指向的「已登记」不存在，读者会以为完整 mode 位被保留（实际只保留可执行位）。缺 END 标记时 `parseBlock` 靠首个非 export/注释行截断（`BootScriptWriter.cj:317-339`），所以不致命，但两处描述都对不上实现
- **建议**：§3.5 补 END 标记的作用与缺省兼容行为、改成 `.tmp.<serial>`、写明「只保留可执行位」；或删掉代码注释里的「已登记」

### [轻微][存量] §10.1 把装配步骤写成 `start()` 的流程，且 `ServerContext` 多一个 `inFlight` 成员

- **位置**：`fdbm/doc/详细设计.md:878-888`（步骤 1-9）、`:294`（`normalize()` 在「§10.1 第 6 步」）、`:897-903`（`ServerContext.inFlight`）；实现 `fdbm/src/server/FdbmServer.cj:56-143`（装配全在构造函数）、`:150-180`（`start()` 只建 `Server` + 注册退出回调 + `server.start`）、`fdbm/src/server/context.cj:22-33`（无 `inFlight`）
- **来源**：存量（快照模式无基线）
- **判据**：review-checklist §13、§14.1「接线缺失」
- **证据**：静态确定 —— `CustomLoader`/`validate`/`DriverLoader`/`DatabaseResources`/`Router`/`normalize`/`SessionRegistry` 都在构造函数里；`InFlight` 是静态 `struct`（`fdbm/src/server/InFlight.cj:28`），不是注入依赖
- **描述**：行为上仍满足「接受连接前完成自检」，但按文档排查启动顺序（`normalize()` 时机、巡检定时器何时启动）会定位错位置；`ServerContext` 的 `inFlight` 让读者以为在途计数可按实例替换。另：§10.1 第 4/5 步顺序与实现相反——实现先 `PartitionRouter`（`FdbmServer.cj:99`）后 `DatabaseResources`（`:108`）
- **建议**：§10.1 改成「构造期：1-7；`start()`：8-9」，§3.5 的时机改成「构造期（监听之前）」；删掉 `ServerContext.inFlight` 或注明是全局静态；调整第 4/5 步顺序

### [轻微][存量] §6.1 写「Murmur 取低 64 位」，实现用 `UInt128.hashCode()`

- **位置**：`fdbm/doc/详细设计.md:399`、`fdbm/doc/开发计划.md:162`；实现 `fdbm/src/route/algorithms.cj:224-226`、`:284-286`
- **来源**：存量（快照模式无基线）
- **判据**：review-checklist §13「规格与实现漂移」
- **证据**：静态确定 —— `murmurHash` 返回 `UInt128`，实现直接 `.hashCode()` 取模，没有显式低 64 位截取
- **描述**：同一键在当前 SDK 内稳定，但与文档承诺不一致；`hashCode` 不属于跨版本稳定契约，若 SDK 调整实现，murmur 分片会整体漂移（存量数据读不到）。影响面待确认
- **建议**：显式 `UInt64(hash & 0xFFFF_FFFF_FFFF_FFFF)` 再取模并固定下来，或把文档改成「按 SDK 的 `hashCode` 取模」

### [轻微][存量] §7 写「默认逻辑库的第一个物理库」，§14.1 与实现是「物理库排序首项」

- **位置**：`fdbm/doc/详细设计.md:534` vs `:1227`、`:119`；实现 `fdbm/src/config/FdbmConfig.cj:337-368`（`smallest()` 取字典序最小）
- **来源**：存量（快照模式无基线）
- **判据**：review-checklist §13（文档内部不一致）
- **证据**：静态确定 —— `smallest()` 逐项比较取名序最小，不是配置书写顺序首项
- **描述**：同一参数两种口径。`fdbm_db_logicalDatabase_order='db2,db1'` 时读者预期 `db2`、实现取 `db1`；`fountain_sequence` 建错库会在启动自检报 `ID_GENERATOR`
- **建议**：统一为「物理库名排序首项」，§7 与 §14.1 同步

### [轻微][存量] `开发计划.md` 的文件清单、测试替身名与两处签名已过期

- **位置**：`fdbm/doc/开发计划.md:9`（`src/resources/fake_accessor_test.cj` + `FakeNodeAccessor`）、`:34`（阶段 1 漏 `catalog.cj` / `models.cj` / `source.cj`）、`:129`（`accessor.cj`、`fake_accessor_test.cj`）、`:141`（`init(nodes, pools, weights)`）、`:155`（`algorithm.cj` / `PartitionRule.cj` / `PartitionRouter.cj` / `PartitionCache.cj` / `GlobalTableRouter.cj`）、`:204`（`IdMakers.forTable(config, resources, logical, table)`）、`:222` ⑦（越界 index → `CURSOR_STATE`）
- **来源**：存量（快照模式无基线）
- **判据**：review-checklist §13「路径失效」「示例引用了不存在的 API」
- **证据**：静态确定 —— 实际文件是 `src/resources/DatabaseResources.cj`、`src/route/{algorithms,router,cache,global}.cj`；`FakeNodeAccessor` 全仓只在 `DatabaseResources.cj:28` 的注释里出现，测试用 `RecordingAccessor`/`FailingAccessor`（`src/execute/Dispatcher_test.cj:1002`、`:1045`）；`forTable` 实为 6 参（`src/idmaker/IdMakers.cj:229-231`）；越界 index 实际抛 `CONVERSION`（`src/execute/cursor.cj:151-153`）；`DatabaseResources.init` 第二参是 `PoolConfig`（`src/resources/DatabaseResources.cj:68-69`）
- **描述**：计划书是 TDD 执行入口，按图索骥找不到文件、找不到夹具、断言错错误码。计划文档存在本身就是给后来者照着做的
- **建议**：补一句「文件名为计划期命名，实际见 `src/`」，并回填上述 5 处；或整体标注「历史计划，验收记录见文末 2026-10-21 一节」

### [轻微][存量] §6.3 / §10.4 的缓存实现细节与代码不符（`unsafeBytes`、`syncWAL`）

- **位置**：`fdbm/doc/详细设计.md:490`（`'…'.unsafeBytes()` / `<physical>.unsafeBytes()`）、`:948`（「`syncWAL` 后关闭」）；实现 `fdbm/src/route/cache.cj:83-84`、`:126-128`（`toArray()`）、`:109-120`（只调 `store.close()`）
- **来源**：存量（快照模式无基线）
- **判据**：review-checklist §13
- **证据**：静态确定 —— `fdbm` 全仓无 `syncWAL` 调用；键值字节内容等价，所以不是数据错误
- **描述**：文档描述的 API 与落盘步骤不存在，按文档做容量 / 性能评估会建立在错误假设上（`unsafeBytes` 免拷贝、`syncWAL` 显式刷盘）
- **建议**：文档改成 `toArray()` 与「依赖 `Store.close()` 内部 flush」，或实现补 `syncWAL()`

存量缺陷共 12 条（一般 6 / 轻微 6），是否纳入修复待用户决定；其中 `boot.sh` 示例改写（#1）、`bufSize` 三档口径（#2）、流列重复探测（#3）建议优先。

## 优化可行性方案

无。本部分只有文档；文档描述的 DELETE 键物化（`详细设计.md:797` + `src/execute/executors.cj`）等代码侧内存/CPU 议题留给对应源码部分，避免同一模块重复统计（按 §7 要求也缺改前基线）。

## 待验证假设

| # | 假设 | 位置 | 缺什么数据 | 怎么采 |
| --- | --- | --- | --- | --- |
| 1 | 同源端口复用时 `SessionRegistry.of` 命中旧会话，导致游标/事务串台 | `fdbm/src/server/SessionRegistry.cj:152-158` | `f_net` 的 `remoteAddress` 复用条件与复现路径 | 同源端口重连压测 + 断言会话 id 变化 |
| 2 | `UInt128.hashCode()` 跨 SDK 版本变化会让 murmur 分片整体漂移 | `fdbm/src/route/algorithms.cj:225` | 两版 SDK 对同一组键的输出 | 1 万个键在两版 SDK 下比对库下标 |
| 3 | `normalize()` 的改写不只影响 §10.6 示例，也影响真实部署脚本 | `fdbm/src/config/BootScriptWriter.cj:343-355` | 真实 `boot.sh` 样本与两次启动的 diff | 用真实脚本连续启动两次，逐行 diff |
| 4 | 详细设计其余「声明片段」仍有未比对的漂移（§8.2 AST 字段、§6.3 缓存成员） | `fdbm/doc/详细设计.md` §8.2 / §6.3 | 声明片段与 `src/` 的完整差异清单 | 脚本把文档 ```cangjie 代码块的 `protected class/struct/interface` 与 `grep -rn "^protected \(class\|struct\|interface\)" fdbm/src` 做集合差 |

## 文件覆盖

| # | 文件 | 类型 | 已读 | 说明 |
| --- | --- | --- | --- | --- |
| 1 | `fdbm/doc/spec/implement-f-dbd-driver-and-fdbm-server/specs/fdbm/spec.md` | .md | ✅ | 464 行全读。MUST 项逐条对照实现：请求判别/必有回包、无预读、当前行缓冲、UNSUBSCRIBE 幂等、多段游标、列类型归一、分库算法与范围路由、自定义扩展、巡检与优雅停止、启动自检均成立；流列「句柄只打开一次」与 `cursor.cj:170-178` 不符（见发现 3）；`bufSize<=0` 场景属归档期口径，按 §13 误报边界不计缺陷 |
| 2 | `fdbm/doc/开发计划.md` | .md | ✅ | 317 行全读。文件清单/替身名/两处签名过期（发现 11）；其余 Step 与现有测试基本对应（抽查 `FdbmConfig_test.cj` 的 §11 负例较完整） |
| 3 | `fdbm/doc/详细设计.md` | .md | ✅ | 1267 行全读（分三页）。主体与实现一致（路由五态、多段游标、DELETE 三步、优雅停止六步顺序、SHOW 方言、自检清单）；漂移见发现 1、2、4-10、12 |

合计：`.cj` 0 个 / `.md` 3 个 / 共 3 个，全部读完。

## 覆盖自检

| 维度 | 命中 | 未命中时的说明 |
| --- | --- | --- |
| 正确性 / 设计 / 语言特性 / 可读性 / 安全性 | 2 | 文档侧的「正确性」= 文档与实现是否一致：命中 `bufSize` 三档矛盾（发现 2）与流列句柄契约落空（发现 3）。安全性：§3.5 要求日志不含密码值，`commentOf` 只输出键名（`BootScriptWriter.cj:269-271`），未见敏感值进日志的文档缺陷；设计/可读性见发现 6、8、11、12 |
| §1 死代码 | 0 | 3 个文件无函数/声明可判。等价机械动作=「文档引用的每个路径/类型/成员在 `src/` 是否存在」：逐条 grep 后命中 3 处悬空引用（`src/custom/`、`fake_accessor_test.cj`+`FakeNodeAccessor`、`Crc16/32/64Partition`），已并入发现 4、11、6，不重复计数；`src/` 内非 public 符号的死代码判定留给源码部分 |
| §2 重复逻辑 | 0 | spec / 详细设计 / 开发计划 之间确有整段复述（§3.1/§3.5/§11/§12 与各 Step），按 §2 误报边界属「规格-设计-计划分层」的刻意重复，不判重复；只有 §7 与 §14.1 的 sequence 默认库口径已漂移，按 §13 记发现 10 |
| §3 空实现 | 0 | `normalize()` 的 `catch` 记 ERROR 后返回 `false`（`BootScriptWriter.cj:151-159`）是文档明确要求的「失败不阻塞启动」，不算静默吞异常；§11 自检项与 `FdbmConfig.validate` 逐项对应（抽查 driver 唯一性 / weight 后缀 / substr / snowflake / sequence / 时长类），无「承诺了但代码空」 |
| §4 栈溢出 | 0 | 文档未承诺递归结构；派生表递归展开（§8.2 `TableRef.collectTables`）的深度风险属代码侧，留给源码部分 |
| §5 OOM | 0 | 文档已自带限制登记（缓存只增不减、`size=0` 不限、f_store 无淘汰，§6.3/§12）；DELETE 键物化的规模评估需运行期数据，属代码侧 |
| §6.1 热点瓶颈 | 0 | 本部分无代码、无 profile / bench；`scope.md` 给的 `docs/LocalMode*.md` 不覆盖 fdbm 文档，热点结论不成立 |
| §6.2 大粒度锁 | 0 | 文档未描述锁内 I/O；`BootScriptWriter` 的 `set/flush/normalize` 共用一把 `Mutex`（`BootScriptWriter.cj:78-79`）是脚本不被交错写坏的必需设计，临界区只含内存与一次原子写，不构成大粒度锁缺陷 |
| §6.3 并发串行 | 0 | f_net 每条连接串行执行请求（`f_net/src/server/Server.cj:169` 的 `call(...).get`），fdbm 侧无「spawn 后立刻 get」 |
| §6.4 低效算法 | 0 | 无规模数据；`sortInPlace` 只用于配置项/物理库/缓存键等小集合 |
| §7 降堆内存方案 | 0 | 无源码与改前基线；文档侧唯一相关项（缓存无淘汰）已由文档自己登记为限制，不重复出方案 |
| §8 降 CPU 方案 | 0 | 同上，无可量化热点 |
| §9 local mode 可行性 | 0 | 本部分无函数级临时对象，也无峰值内存数据 |
| §11 现有代码的 BUG（存量） | 1 | 流列 `-1` 重复打开句柄（发现 3，静态确定）；其余文档承诺的边界（UNSUBSCRIBE 幂等、Empty 不借连接、多段行序、无预读）已对照实现确认成立 |
| §12 并发安全与锁粒度 | 1 | 会话键用 `remoteAddress` 文本（发现 5：漂移静态确定、后果待确认）。另核实：`QueryCursor` 无锁但同连接请求由 f_net 串行化；巡检关闭与在途请求的竞态缺证据，列入待验证假设 1 |
| §14 功能完备性与 README 覆盖 | 1 | 文档承诺的 `custom` 包与 CRC 三个实现类在代码中不存在（发现 4、6）；README 覆盖属 part1，不在本部分 |
| 文件覆盖（§13 等） | 3/3 | 3 个 `.md` 全部读完，无缺失；§13 命中 11 条（发现 1、2、4-12） |

## 模块统计

| 严重程度 | 数量 |
| --- | --- |
| 严重 | 0 |
| 一般 | 6 |
| 轻微 | 6 |
| 优化方案（堆内存 / CPU） | 0 / 0 |

## 总评

这批文档质量整体偏高：路由五态、多段游标、UNSUBSCRIBE 幂等、DELETE 三步、优雅停止顺序、启动自检清单都能在实现里逐条对上，MUST 级协议语义基本没有落空，限制（无 2PC、多库 `order by`/`limit` 不严格、缓存只增不减、Windows 无优雅停止）也登记得比较诚实。

问题集中在两处根因：**① 文档没随 2026-10-21 那轮 `harden-fdbm-stack-defects` 回填**（类型被合并、包被并入 server、签名与装配顺序变了），发现 4、6-12 都是这一类，纯文档改动、风险为零，建议一次性回填；**② 协议细节的口径分裂**，即发现 1-3：`bufSize` 三档语义在详细设计内部就矛盾，流列 `-1` 分支又真的与「句柄只打开一次」的契约冲突，`boot.sh` 示例与 `normalize()` 的解析规则互斥。

按后果排序，建议优先：#3（重复 NULL 探测会重放首块，属实现缺陷，需改 `cursor.cj`）、#2（协议口径，决定客户端怎么写）、#1（按示例部署二次启动起不来，运维可见）。其余为文档漂移，排期回填即可。严重度按 §13 的文档类定级规则给出（示例跑不通 → 一般），若按「二次启动失败」的运维后果衡量，#1 应视为阻塞项并随实现修复同批处理。
