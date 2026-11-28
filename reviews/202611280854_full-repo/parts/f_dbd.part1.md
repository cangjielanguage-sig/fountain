# f_dbd 模块审查报告（模块第 1/5 部分）

- **审查日期**：2026-11-28
- **模块路径**：`f_dbd`（模块共 49 个 `.cj` + 20 个 `.md`；**本部分 18 个 `.md`、0 个 `.cj`**：`README.md` / `README_en.md` + `doc/spec/**` 全部 16 份变更文档）
- **基线**：工作区快照（sts/1.3.x，无 diff 基线）；本部分问题全部记为「存量」
- **审查重点**：数据库驱动协议正确性、类型映射（`Sql*` 抽象名与仓颉类型名）、资源与连接生命周期、死代码、重复逻辑、存量 BUG。本部分文件均为文档，故以「文档承诺 ↔ 实现」为主线，`.cj` 只作为取证对象（其缺陷归属第 2–5 部分）
- **报告版本**：v1

## 发现

### [一般] README 的连接选项键名写成 camelCase，实现只认 `SqlOption` 的 snake_case，四项设置按文档写会静默失效

- **位置**：`f_dbd/README.md:81-83`（`connectionTimeout` / `queryTimeout` / `updateTimeout` / `fetchRows`）、`f_dbd/README_en.md:88-90`；实现 `f_dbd/src/driver/DbdOptions.cj:47-71`
- **来源**：存量（快照模式无基线）
- **判据**：review-checklist §13「API / 配置 / 默认值与源码不符」、§14.2「关键配置项写错导致按文档用不起来」
- **证据**：静态确定 —— `DbdOptions.apply` 用 `SqlOption.ConnectionTimeout` / `QueryTimeout` / `UpdateTimeout` / `FetchRows` 做字符串精确比较；std 文档 `cangjie-doc/.../std/database_sql/database_sql_package_api/database_sql_package_classes.md:4589-4592` 明确这四个常量为 `connection_timeout` / `update_timeout` / `query_timeout` / `fetch_rows`
- **描述**：照 README 传 `opts = [("queryTimeout", "30000")]` 会落进 `else` 分支，只打一条 DEBUG（`DbdOptions.cj:72-74`）就被丢弃：查询超时退化为 6 小时上限（`DbdTransport.cj:32`），`fetch_rows` 退化为 64 KiB，且**没有 WARN**，用户无法从日志发现配置没生效。`username` / `password` 是单词、无下划线，恰好不受影响，因此问题只暴露在超时与分块上。同一模块的变更文档用的是正确拼写（`doc/spec/harden-fdbm-stack-defects/spec.md:272-273` 写的是 `query_timeout`），只有 README 两份是 camelCase
- **建议**：README 两处表格改为 `connection_timeout` / `query_timeout` / `update_timeout` / `fetch_rows`；若希望保留 camelCase，则须在 `DbdOptions.apply` 里同时识别两种拼写，不能只改文档一半。`README_en.md` 同步

### [一般] README「其他公开 API」把 `protected struct MultiDConfig` 的 14 个静态方法当成模块级公开 API（外部不可达），同时漏列 4 个 public 常量与 3 个 public 成员

- **位置**：`f_dbd/README.md:165`（`getCheckInterval` … `getWeights` 被列在「模块级」）、`f_dbd/README_en.md:184`；实现 `f_dbd/src/multid/Config.cj:29`、`f_dbd/src/dbd.cj:25-27`
- **来源**：存量
- **判据**：review-checklist §14.2「公开 API 未文档化 / 索引失准」、§1 硬原则二（非公共顶级声明里的 `public` 成员对外不可达）；语言可见性依据 `cangjie-doc/md/doc/cj_syntax.md:66`「`protected` — 当前模块及当前类的子类可见」
- **证据**：静态确定 —— `MultiDConfig` 是顶层 `protected struct`，`struct` 无子类，故这 14 个 `public static func` 只在 `f_dbd` 模块内可见；根包 `dbd.cj:25-27` 只重导出 `common.*`、`driver.{DbdDriver,DbdUrl,dbdDriver}`、`multid.{MultiD,MultiDUrl,MultiDatasource}`，没有也不该有 `MultiDConfig`。反向核对公开声明全集（`grep '^public '`）：`NEXT_ROW`、`DEFAULT_PORT`、`DEFAULT_STREAM_CHUNK`、`CELL_READ_FLAG` 四个 public 常量、`DbdStatement.setOption`、`DbdDriver.init(name:)`、`DbdErrorCode.parse` 在 README 中均检索不到
- **描述**：下游照 README 调 `getCheckInterval()` 会直接解析不到符号（README 却把它标成「模块级」，与 `fdBDVersion` 同级）；反过来，真正对外可达的四个协议常量（`NEXT_ROW = -1` 等，`types.cj:28-40`）没有任何文档，使用者若自己拼 `QueryResultColumnPayload` 只能读源码。这份清单是按「`public` 修饰符」机械导出的，没有按「对外可达性」过滤
- **建议**：14 个 `get*` 从「模块级」移出，改为一句「内部配置读取（`protected struct MultiDConfig`，不对外）」；补齐 4 个 public 常量（至少要说明 `NEXT_ROW` 与 `bufSize` 的保留值语义）与 `DbdStatement.setOption`、`DbdDriver.init(name:)`、`DbdErrorCode.parse`。若这 14 个方法本就不打算对外，也可顺手把 `MultiDConfig` 收成 `internal`，让清单导出规则不再误伤

### [一般] README 未记载两项用户可见的硬限制：连接级结果集独占（`CURSOR_STATE`）与事务三属性「只记录、不下发」

- **位置**：`f_dbd/README.md` 全文（缺「限制与注意事项」段落；`CURSOR_STATE` 只在 `:143` 的错误码枚举里出现，`:163-182`「其他公开 API」只列方法名）、`f_dbd/README_en.md:159-201`；承诺源 `doc/spec/implement-f-dbd-driver-and-fdbm-server/specs/f-dbd/spec.md:257-261`（MUST）；实现 `src/driver/DbdConnection.cj:124-135`、`src/driver/DbdStatement.cj:150-155`、`src/driver/DbdTransaction.cj:24-29,44-69`
- **来源**：存量
- **判据**：review-checklist §14.2「缺关键段落：限制与注意事项」、§13「文档承诺与实现口径」
- **证据**：静态确定 —— 全仓检索 README 无「独占」（`grep -n "独占" README.md` 无命中）；`DbdConnection.ensureNoOpenResult` 在结果集未 `close()`（含已 `next()==false` 但未关）时对任何新 SQL 抛 `CURSOR_STATE` 且不发包；`DbdTransaction` 的 `accessMode` / `deferrableMode` / `isoLevel` 只写成员字段，`begin`/`commit` 透传固定文本 `'begin'` / `'commit'`（`:76,82`），属性值不进任何报文
- **描述**：两种最常见的误用都会在无提示的情况下失败或失效：① 遍历结果集时顺手复用同一 `Connection` 执行另一条 SQL → 直接 `CURSOR_STATE`，README 只把该码列进枚举，用户无从知道要先 `close()`；② `tx.isoLevel = Serializable` 之后以为隔离级别已生效，实际报文只有 `begin`，服务端按默认隔离级别跑。README 是唯一面向接入方的入口文档，这两条目前只写在 `详细设计.md` / 变更 spec 里
- **建议**：README 增「限制与注意事项」小节，至少三条：① 一条连接同一时刻只允许一个未 `close()` 的结果集，否则 `CURSOR_STATE`（含「已耗尽未关闭」）；② 事务三属性只记录不下发，需要方言级隔离级别请直接写 SQL；③ savepoint 名必须匹配 `[A-Za-z_][A-Za-z0-9_]*`，否则 `PROTOCOL`。`README_en.md` 同步

### [轻微] README 的 `DbdDatasource` 构造签名写成 `url: String`，实现是 `url: DbdUrl`

- **位置**：`f_dbd/README.md:25`、`f_dbd/README_en.md:26`；实现 `f_dbd/src/driver/DbdDatasource.cj:34`
- **来源**：存量
- **判据**：review-checklist §13「API 签名与源码不符」
- **证据**：静态确定 —— `public init(url: DbdUrl, opts!: Array<(String, String)> = [])`；与同表下一行 `MultiDatasource(url: String, …)`（`src/multid/Datasource.cj:44`）对照可知是把两者抄混了
- **描述**：照 README 写 `DbdDatasource("fdbm://…")` 编译失败；且 `DbdUrl` 的构造器是 `init`（包内），外部只能经 `DbdUrl.parse` / `Driver.open` 拿到，README 没有交代这条路径
- **建议**：改为 `DbdDatasource(url: DbdUrl, opts!…)`，并补一句「常规用法是 `dbdDriver().open(url, opts)` 或 `DbdUrl.parse` 后构造」

### [轻微] harden 变更文档的 P1 条数自相矛盾：29 / 33 两种口径并存，`29 + 8 + 9 = 46 ≠ 51`

- **位置**：`f_dbd/doc/spec/harden-fdbm-stack-defects/proposal.md:6`、`design.md:41`、`tasks.md:13`（均写「29 个 P1」）；`design.md:227-232`、`design.md:438`（写 33）
- **来源**：存量
- **判据**：review-checklist §13「规格与实现漂移 / 前后不自洽」
- **证据**：静态确定 —— `design.md:41`「51 条 → P1 29 项 + 并入 P0 8 条 + P2 9 条（无遗漏、无重复）」三项相加为 46；同文 §5 表给出「修复 33 / 并入 8 / 补测试 9 / 记录不修 1」= 51，附录 A 统计也写「P1 族 33 条次」
- **描述**：这条变更的全部价值在于「51 条逐条可追溯」，而 29/33 的差异正好落在 4 条一般项上，会让人怀疑附录 A 有遗漏或重复；`tasks.md:13` 的「12 P0 + 29 P1 + 12 P2」同样沿用了错值
- **建议**：统一为 33（P1 修复族）+ 8（并入 P0）+ 9（P2）+ 1（记录不修，G25）= 51，并回改 `proposal.md:6`、`design.md:41`、`tasks.md:13`

### [轻微] `harden-fdbm-stack-defects` 的 `spec.md` 与 `specs/f-dbd/spec.md` 完全相同，同一规格存在两份副本

- **位置**：`f_dbd/doc/spec/harden-fdbm-stack-defects/spec.md` 与 `f_dbd/doc/spec/harden-fdbm-stack-defects/specs/f-dbd/spec.md`
- **来源**：存量
- **判据**：review-checklist §2「重复内容」、§13「规格可追溯性」
- **证据**：静态确定 —— `diff -q` 无差异，两份均为 12,611 字节（280 行）
- **描述**：OpenSpec 变更目录的规范位置是 `specs/<capability>/spec.md`，顶层 `spec.md` 是拆分前的旧形态残留。两份内容一致时无害，但只要后续只改一份（下次 MODIFIED 极易发生），就会出现「以哪份为准」的歧义，而这两份又正好是 `f_dbd` 协议口径（流列、B 口径、URL）的规范来源
- **建议**：保留 `specs/f-dbd/spec.md` 作为唯一规格，删除顶层 `spec.md`；或把顶层文件改成一行「见 `specs/f-dbd/spec.md`」的指针

## 范围外提示（代码文件归本模块第 2–5 部分，不计入本部分统计）

- `f_dbd/src/multid/Url.cj:58`：`MultiDUrl.database` 取 `firstSegment(rest[...])`，**未**走 `percentDecode`，而 `nodes[i].database` 经 `DbdUrl.parse` 已解码；同一 URL 里两个 `database` 字段口径不一致（`MultiDatasource` 未使用 `parsed.database`，当前无可观测影响）。
- `f_dbd/src/driver/DbdStatement.cj:150-155` → `DbdConnection.cj:145-147` → `:138-142`：结果集独占闸门是「检查（`ensureNoOpenResult`）→ 发包 → 登记（`registerResult`）」三段分别加锁，两条线程可同时通过闸门再各自登记，`QueryResultColumnPayload` 不带 `qid`，后登记的结果集会让先前的 `next/get` 作用到新游标。是否算缺陷取决于 `DbdConnection` 是否声明线程安全（std 未承诺），留给第 2–5 部分定级。

## 优化可行性方案

本部分为纯 `.md`，未提出新方案。文档内既有的两条分配优化（`sqlPayload` 单层包装、`readChunk` 复用读缓冲）已落地且实现与设计一致，但测量口径为探针 / `-O0`，复核要求见「待验证假设」1–2；在补齐 `-O2` 对照前不作为收益结论。

## 待验证假设

| # | 假设 | 位置 | 缺什么数据 | 怎么采 |
| --- | --- | --- | --- | --- |
| 1 | 8 参数 payload 由 `add<DataAny>(DataAny(x))` 改 `add<Data>(x)` 省 577 B/次（-25%）在 `-O2` 下依然成立 | `f_dbd/doc/spec/optimize-f-dbd-payload-wrapping/design.md:13`、`src/driver/DbdStatement.cj:257-263` | `-O2` 下的分配量与耗时中位数 | 同机 `cjpm bench -O2`，8 参数 payload × 2000 次 × 5 轮，`getAllocatedHeapSize()` 前后差 + 中位数/离散度 |
| 2 | `readChunk` 复用一块 64 KiB 缓冲后，1 MiB「读至 EOF」的总分配 5,436,040 B 仍主要由输出数组主导 | `f_dbd/doc/spec/reuse-read-buffers/design.md:86-90`、`src/common/types.cj:405-422` | 该函数在流参数编码路径的分配占比与自耗时 | `cjprof record` 跑 1 MiB `InputStream` 参数 `set` + `update`，采样分配与自耗时，对照 `ArrayList` 增长次数 |

## 文件覆盖

| # | 文件 | 类型 | 已读 | 说明 |
| --- | --- | --- | --- | --- |
| 1 | `f_dbd/README.md` | .md | ✅ | 与 `src/` 逐项核对：协议口径、类型口径、默认值表基本一致；选项键名（#1）、公开 API 清单（#2）、缺限制段落（#3）、构造签名（#4）见发现 |
| 2 | `f_dbd/README_en.md` | .md | ✅ | 与中文版章节一一对应、同样问题同源（#1/#2/#3/#4），无单独新增偏差 |
| 3 | `f_dbd/doc/spec/harden-fdbm-stack-defects/proposal.md` | .md | ✅ | 已完成变更；P1 计数 29 见 #5；D01–D12 与 design/tasks 对齐 |
| 4 | `f_dbd/doc/spec/harden-fdbm-stack-defects/design.md` | .md | ✅ | 客户端侧设计（D01/D02/D12、G01–G07）与当前实现一致；§2.2 与 §5/附录 A 计数冲突（#5） |
| 5 | `f_dbd/doc/spec/harden-fdbm-stack-defects/spec.md` | .md | ✅ | 与 `specs/f-dbd/spec.md` 逐字节相同（#6）；内容本身与实现一致 |
| 6 | `f_dbd/doc/spec/harden-fdbm-stack-defects/specs/f-dbd/spec.md` | .md | ✅ | 协议/类型/URL/选项/重导出要求与 `result.cj`、`types.cj`、`DbdUrl.cj`、`dbd.cj` 一致 |
| 7 | `f_dbd/doc/spec/harden-fdbm-stack-defects/tasks.md` | .md | ✅ | 12/29/12 与 #5 同源；4.6 验收记录（f_dbd 208/208）无对应代码可核，按历史记录对待 |
| 8 | `f_dbd/doc/spec/implement-f-dbd-driver-and-fdbm-server/proposal.md` | .md | ✅ | 历史提案；「注册名 `fdbm`」已被 harden G03 取代，属当时结论，不判冲突 |
| 9 | `f_dbd/doc/spec/implement-f-dbd-driver-and-fdbm-server/design.md` | .md | ✅ | D1/D3/D9 与当前实现一致；D5 性能门禁结论已回写 `详细设计.md` §10.1.1（章节存在） |
| 10 | `f_dbd/doc/spec/implement-f-dbd-driver-and-fdbm-server/specs/f-dbd/spec.md` | .md | ✅ | 结果集独占 / 游标 fail-fast / 传输超时 MUST 的来源，README 未覆盖 → #3；其余已被 harden 同期 MODIFIED |
| 11 | `f_dbd/doc/spec/implement-f-dbd-driver-and-fdbm-server/specs/f-protocol/spec.md` | .md | ✅ | 目标模块是 `f_protocol`（`Message.unsubscribe(data:)`），本模块只消费；无本模块可判项 |
| 12 | `f_dbd/doc/spec/implement-f-dbd-driver-and-fdbm-server/tasks.md` | .md | ✅ | 历史任务与落地注记；17.5 延后、17.7 断言数与 harden 4.6 不同期，不矛盾 |
| 13 | `f_dbd/doc/spec/optimize-f-dbd-payload-wrapping/proposal.md` | .md | ✅ | 引用 `docs/LocalMode.md` 2.5 与行号 158-175：文档存在（`docs/LocalMode.md:327`），行号已漂到 `DbdStatement.cj:157-159` / `sqlPayloadOf:249-266`，仅位置陈述，不单列 |
| 14 | `f_dbd/doc/spec/optimize-f-dbd-payload-wrapping/design.md` | .md | ✅ | D1 `add<Data>` 与 `DbdStatement.cj:260` 一致；收益口径为探针数据 → 待验证假设 1 |
| 15 | `f_dbd/doc/spec/optimize-f-dbd-payload-wrapping/tasks.md` | .md | ✅ | 全部勾选；4.2 的「公开 API 0 变化」与现状一致（`SqlPayload.add<T>` 签名未变） |
| 16 | `f_dbd/doc/spec/reuse-read-buffers/proposal.md` | .md | ✅ | 现状描述（每轮新建临时数组 + 逐字节 `add`）与改前实现相符 |
| 17 | `f_dbd/doc/spec/reuse-read-buffers/design.md` | .md | ✅ | D1 与 `types.cj:405-422` 逐行一致；「`buf[0..want]` 是切片视图、可写穿」已按 `std/core/.../core_package_structs.md:1561-1577` 的例子核实成立；实测口径 `-O0` → 待验证假设 2 |
| 18 | `f_dbd/doc/spec/reuse-read-buffers/tasks.md` | .md | ✅ | 全部勾选；1.2 / 4.1 与实现、测试文件（`ReadChunkReuse_test.cj`）对应 |

合计：`.cj` 0 个 / `.md` 18 个 / 共 18 个，全部读完。

## 覆盖自检

| 维度 | 命中 | 未命中时的说明 |
| --- | --- | --- |
| 正确性 / 设计 / 语言特性 / 可读性 / 安全性 | 0 | 本部分无源码，无逻辑/并发/注入可判；文档层面的「口径不一致」按 §13/§14 归类，未在此重复计数 |
| §1 死代码 | 0 | `.md` 无声明可判。做了等价机械检查：文档引用的每个符号与路径都做了存在性核对（`fdBDVersion`/`DbdUrl.tryParse`/`dispatch_perf_test.cj`/`reviews/202610210649_fdbm_stack_review`/`docs/LocalMode.md`/`fdbm/test/e2e/README.md` 均存在）；唯一「声明了但外部不可达」的是 README 列的 14 个 `MultiDConfig` getter，按文档缺陷记入 #2，不按死代码计（它们在 `multid/Datasource.cj:60-73` 与 `:167` 有调用） |
| §2 重复逻辑 | 1 | 文档级：`harden.../spec.md` 与 `specs/f-dbd/spec.md` 同内容双份（#6）。跨文档的「同义要求」属 OpenSpec ADDED→MODIFIED 演进，不判重复 |
| §3 空实现 | 0 | 文档中无「承诺了但留空」的条目：`tasks.md` 全部勾选且 4.6/17.7 有验收记录；唯一「记录不修」的 G25 有明确理由与用例，不算空实现 |
| §4 栈溢出 | 0 | 本部分无递归相关文档段落 |
| §5 OOM | 0 | 文档中的内存上界表述（`readChunk` 单块 64 KiB）与实现一致，无「按报文长度预分配」承诺 |
| §6.1 热点瓶颈 | 0 | 未提供 `cjprof` / `cjpm bench` 数据；文档内的两条分配结论只能进「待验证假设」1–2 |
| §6.2 大粒度锁 | 0 | 本部分无锁相关文档；`DbdTransport`/`DbdConnection` 的锁粒度留第 2–5 部分 |
| §6.3 并发串行 | 0 | 同上；README「每次 get 都发请求」是显式设计（1+N 往返）而非隐藏串行，已有 Non-Goal 记录 |
| §6.4 低效算法 | 0 | 文档未承诺任何算法实现；`readChunk` 的 O(n) 行为在 `types.cj` 已近线性，未发现文档与实现冲突 |
| §7 降堆内存方案 | 0 | 无改前/改后峰值数据，未写成方案；仅保留待验证假设 |
| §8 降 CPU 方案 | 0 | 同上；文档中的分配收益未在 `-O2` 复核，不进方案 |
| §9 local mode 可行性 | 0 | `optimize-f-dbd-payload-wrapping` 已论证 `DataAny` 是 struct、与 local region 无关；`reuse-read-buffers` 已论证作为 `read` 实参的缓冲无法 local 化，两处结论与 `-O0` 记录一致，无需重开 |
| §11 现有代码的 BUG（存量） | 0 | 本部分无运行时代码。读文档时撞见的两处代码疑点（`MultiDUrl.database` 未解码、结果集闸门三段分离）见「范围外提示」，不占本部分统计 |
| §12 并发安全与锁粒度 | 0 | 本部分无并发实现；README 亦未声明线程安全，按「未声明即不承诺」处理，具体共享点留给代码部分 |
| §14 功能完备性与 README 覆盖 | 2 | #2 公开 API 清单失准（列了不可达的 14 个，漏了 4 常量 + 3 成员）、#3 缺关键限制段落（结果集独占、事务属性只记录） |
| 文件覆盖（§13 等） | 18/18 | 本部分清单 18 个文件全部读完，逐个做了「文档承诺 → 代码位置」核对（见文件覆盖表） |

## 模块统计

| 严重程度 | 数量 |
| --- | --- |
| 严重 | 0 |
| 一般 | 3 |
| 轻微 | 3 |
| 优化方案（堆内存 / CPU） | 0 / 0 |

## 总评

本部分全是文档，但文档质量直接决定接入成本，结论是「主体准确、边角失准」。经逐条核对，README 的协议口径（查询不预读、每次 `next()` 发 `NEXT_ROW`、关闭走 `UNSUBSCRIBE(qid)`→`ACK`、流列按 `bufSize` 分块、NULL 用 `CELL(index,-1)` 探测、类型口径 B）与 `src/common/result.cj`、`src/driver/DbdStatement.cj`、`src/driver/DbdTransport.cj` 完全对得上；类型映射也站得住：`SqlTypes.resolveSqlName`（`types.cj:259-275`）覆盖了 std 全部 19 个非空 `Sql*` 类型（`SqlBigInt`…`SqlVarchar`，逐一比对 `database_sql_package_classes.md`），`SqlNullable*` 由 `replace('nullable','')` 统一归一，方言/`unsigned`/`(n)` 后缀/包名前缀各分支与 `详细设计.md` §8 的登记一致；多节点 13 个 `multidbm_*` 默认值与单位也和 `multid/Config.cj` 逐项相同；两份 README 中英同步、无单向缺失。

风险集中在文档的「可操作性」而非协议本身：**选项键名 camelCase 是最该先修的一条**——它不会报错，只会让超时与分块设置悄无声息地退回默认值，排障成本远高于改四个字符串；其次是把 `protected` 类型的静态方法当成对外 API 列出，以及 ResultSet 独占、事务属性只记录这两条硬限制完全没写进 README，接入方很可能在第一次复用连接时就被 `CURSOR_STATE` 拦住却找不到解释。变更文档侧只有两处卫生问题（P1 计数 29/33、规格文件双份），不影响当时的实现结论。

本部分存量缺陷 6 条（一般 3、轻微 3），默认只报不修，是否纳入修复待用户决定。`.cj` 侧的协议、类型与生命周期结论需第 2–5 部分合并后才有完整口径；「范围外提示」中的两条请由对应部分复核定级。
