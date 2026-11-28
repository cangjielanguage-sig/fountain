# f_a2a 模块审查报告

> **模块第 2/2 部分**（分报告）。本部分只覆盖 `A2aTaskStore.cj` / `A2aStream_test.cj` 两个文件；
> 同模块其余 20 个文件见 `parts/f_a2a.part1.md`，最终模块报告由主 Agent 合并。

- **审查日期**：2026-11-28
- **模块路径**：`f_a2a`（本部分 2 个源文件；全模块 15 个 `.cj` + 7 个 `.md`）
- **基线**：工作区快照（无 diff）；两文件最后提交 `7c593d47b` / `dfb31f384b`（2026-11-10），工作区干净，全部按「存量」计
- **审查重点**：协议实现正确性、空实现、死代码、重复逻辑、并发安全、存量 BUG、README/文档一致性
- **报告版本**：v1

## 发现

### [严重][存量] 任务存储只增不减：接口无删除/淘汰，每次 `send`/`stream` 的新任务永久驻留

- **位置**：`f_a2a/src/server/A2aTaskStore.cj:24-28`（接口无 remove/clear/淘汰）、`:43-47`（`save` 只写不删）、`:71-75`（只能计数）；放大路径 `f_a2a/src/server/A2aServer.cj:118`、`:217`
- **来源**：存量 —— `git blame` 显示 `A2aTaskStore.cj:20-76` 全部来自 `7c593d47b`（2026-11-10），工作区无改动
- **判据**：review-checklist §5「无界容器 / 缓存键无界：用户 ID / 请求 ID 做 key，没有容量、TTL、淘汰」；严重度表「无界增长导致 OOM」
- **证据**：静态确定 —— `A2aTaskStore` 只有 `save` / `get` / `list` 三个方法，文件内搜 `remove|delete|clear|evict|expire|ttl` 零命中；`A2aServer` 每次 `send` / `stream` 都用 `nextId()`（`A2aServer.cj:340-342`：`now()` 秒 + 单调 `seq`，进程内必然唯一）新建任务并 `save`，而 `f_a2a` 内对 `A2aTaskStore` 的调用只有 `store.save` / `store.get`，没有任何删除调用（`f_llm` 里的 `store.remove` 属于 Loom / 元数据存储，与 `A2aTaskStore` 无关）；同包 `A2aPushConfig.cj:56` 有 `remove`，说明「可删除」并非本模块的全局约定，而是任务存储单独缺失
- **描述**：每个任务连同 `history`（用户消息 + agent 回复）与 `artifacts` 永久留在 `HashMap` 里，进程生命周期内没有任何回收路径，外部也无法删除（接口没给方法）。按每任务约 1KB（2 条消息 + 1 个产物）估算，百万次请求 ≈ 1GB 常驻（量级估算，精确值需压测），长跑服务必然 OOM 且无拒绝路径：既没有容量上限、TTL，也没有分页之外的保护
- **建议**：接口补 `remove(id: String): Bool` 与按时间范围查询；`InMemoryA2aTaskStore` 增加构造参数 `maxTasks` / `ttl`，超出时按 `createdAt` 淘汰（或 LRU）；被淘汰的 id 再次 `get` 继续走 `-32020`，契约不变；同时在接口注释与 README 写明「默认无上限，生产需自行设限或换持久化实现」

### [一般][存量] 锁内做整棵对象的 JSON 序列化/重建：`save`/`get`/`list` 全部串行在 O(history) 工作上

- **位置**：`f_a2a/src/server/A2aTaskStore.cj:43-47`、`:49-56`、`:58-69`
- **来源**：存量（`7c593d47b`）
- **判据**：review-checklist §6.2「锁内做 I/O / DB / 序列化 / 正则 / 日志」、§12.2「缩小临界区：只保护不变量本身」
- **证据**：静态确定（临界区内容）—— `save` 在 `synchronized(mutex)` 内调用 `A2aJson.copyOf`，而 `copyOf` 是 `toJson()` + `taskOf()` 的整棵对象重建（`f_a2a/src/model/A2aJson.cj:33-38`）；`list` 在锁内逐条 `copyOf`。锁等待占比：需实测
- **描述**：一把 `Mutex` 保护整个 `HashMap`，而每次持锁期间都在做与任务体积成正比的 CPU 工作（序列化 + 重新分配 ArrayList/JsonObject）。并发 `send` + `get` 越多，锁队列越长，吞吐上限被这把锁压住；`list` 更是一次持锁做 N 次重建，长时间阻塞所有读写
- **建议**：锁内只做 map 读写与引用交换，`copyOf` 移到锁外——存入的是私有副本且之后不再原地修改，因此"锁内取引用、锁外复制"是安全的；配合 part1 建议的显式 `A2aTask.copy()` 后收益更大（见「优化可行性方案」）

### [一般][存量] 存储只提供「整对象 save + 副本 get」，读-改-写跨两次加锁，缺少条件更新

- **位置**：`f_a2a/src/server/A2aTaskStore.cj:24-28`、`:43-47`；触发方 `f_a2a/src/server/A2aServer.cj:234-246`
- **来源**：存量（`7c593d47b`）
- **判据**：review-checklist §12.1「检查-然后-写入」、§11「并发正确性」
- **证据**：静态确定 —— 接口没有 `update` / `compareAndSet` / version / ETag 任何一个原语；`get` 返回副本，调用方改完后整体 `save`
- **描述**：`cancelTask` 的 `get → 改 → save` 与 `send` 末尾的 `save` 是两次独立加锁，谁后写谁赢，中间没有任何版本校验。第 1 部分发现 #1 的「取消被终态整体覆盖」在存储侧的表现就是这里：接口层面无法表达"仅在仍是 working 时写入 canceled"，自定义 `A2aTaskStore`（持久化实现）也补不上这个能力。这是把「丢失更新」固化成 API 形状的问题，不只是服务端少写一行判断
- **建议**：接口增加原子更新，例如 `compareAndSet(id: String, expectedStatus: String, task: A2aTask): Bool` 或 `update(id: String, f: (A2aTask) -> A2aTask): ?A2aTask`；`InMemoryA2aTaskStore` 在同一个 `synchronized` 内完成读-判-写。与 part1 #1 同根，合并报告时并入该条

### [一般][存量] 接口注释未声明「实现必须线程安全」「返回值必须是副本」两条契约

- **位置**：`f_a2a/src/server/A2aTaskStore.cj:23-28`；对照 `f_a2a/doc/a2a-protocol.md:180-184`
- **来源**：存量（`7c593d47b`）
- **判据**：review-checklist §12.1「契约与实现不符 / 缺失同步手段」、§14.1「接线 / 契约缺失」
- **证据**：静态确定 —— 接口注释只有一句「默认内存实现，需要跨重启保留时换成自己的实现」；副本语义只写在实现类注释（`:30-35`），接口本身没有。`doc/a2a-protocol.md:184` 明确写「并发安全由 store 的实现负责（内存版用 Mutex）」，责任被推给实现方却没写进接口
- **描述**：第三方照着接口注释实现一个裸 `HashMap` 版本即可编译通过，随后在多线程 JSON-RPC 处理下直接数据竞争；同理，实现若返回内部引用，`A2aServer.cj:243-246` 的原地修改会污染库里的对象（`statusMessage`、`artifacts` 都会被外部改到）。两条契约都只存在于某个实现类的注释里，属于契约缺失而非风格问题
- **建议**：接口注释补两段：`save/get/list` 必须线程安全（或明确声明由调用方串行化，但当前 `A2aServer` 不串行化）；`get/list` 返回的对象由调用方独占，实现不得再持有同一实例。README 的「实现 `A2aTaskStore` 注入」段落同步这两条

### [轻微][存量] `list(limit)` 契约未定义：迭代序任意、`limit<=0` 全量物化、无协议入口、无用例

- **位置**：`f_a2a/src/server/A2aTaskStore.cj:58-69`
- **来源**：存量（`7c593d47b`）
- **判据**：review-checklist §11「语义与命名 / 注释不符」、§5「一次性物化」、§14.1「半成品」
- **证据**：静态确定 —— 遍历 `HashMap`（迭代序未定义），没有按 `createdAt`/`updatedAt` 排序；`limit > 0` 才截断，`limit <= 0` 会复制全部任务；`A2aServer.register()` 注册的 9 个方法（`A2aServer.cj:76-93`）里没有 `tasks/list`，全仓搜 `store.list` 零命中
- **描述**：方法名暗示"列出最近任务"，实际返回任意子集，调用方无法据此做分页；`limit=0` 会一次性把全部任务复制成新对象（叠加每条的 `copyOf`），在大存量下是峰值内存尖峰。目前既无调用方也无协议入口，属于未接线的半成品 API
- **建议**：要么明确契约（按 `createdAt` 倒序、`limit` 必须 > 0、上限截断到常量），要么删掉该接口方法；若保留给宿主直接调用，README 注明"服务端未注册 `tasks/list`，仅库内可用"

### [轻微][存量] `count()` 不在接口内、全仓零调用零用例，README 却把它当作存储 API 列出

- **位置**：`f_a2a/src/server/A2aTaskStore.cj:71-75`；`f_a2a/README.md:152`、`f_a2a/README_en.md:155`
- **来源**：存量（`7c593d47b`）
- **判据**：review-checklist §14.2「公开 API 未文档化 / 文档与契约不一致」
- **证据**：静态确定 —— `count` 只定义在 `InMemoryA2aTaskStore` 上，`A2aTaskStore` 接口（`:24-28`）没有；`f_a2a` 内搜 `count(` 只命中定义处这一行，`src/` 与测试零调用，只有两份 README 把它列为 API
- **描述**：README 把 `count` 列为 `InMemoryA2aTaskStore` 的公开方法，但注入自定义 store 后宿主/服务端拿不到计数；也没有任何用例覆盖。按死代码判据它属于「对外可达的 public 成员」，不计死代码，但当前既无消费方也无回归基线——将来按 S1 加淘汰策略时，没有用例能证明计数正确（同 id 覆盖不应 +1）
- **建议**：要么上移到 `A2aTaskStore` 接口并在监控/淘汰里真正用起来，要么从 README 移除；补一条用例：`save` 3 条 → `count()==3` → 覆盖同 id → 仍为 3

### [轻微][存量] 流测试先断言 `size >= 2` 再索引 `[1]`，缺事件时以越界异常失败

- **位置**：`f_a2a/src/server/A2aStream_test.cj:91-94`
- **来源**：存量（`dfb31f384b`）
- **判据**：review-checklist §11「边界差一 / 断言不严」
- **证据**：静态确定
- **描述**：`@Expect(recorder.events.size >= 2, true)` 允许 size 恰为 2，也允许 3、4；后续直接取 `[0]`/`[1]`，一旦只发出 1 条（例如终态事件丢失），用例抛 `IndexOutOfBounds`，报错信息里看不到"少了一条事件"，定位成本高于断言失败
- **建议**：改为 `@Expect(recorder.events.size, 2)`，再逐条断言 method/state

### [轻微][存量] 产物事件用例未校验「在状态事件之后」，与 `A2aServer` 的顺序契约脱钩

- **位置**：`f_a2a/src/server/A2aStream_test.cj:99-113`（注释在 `:98`）；契约在 `f_a2a/src/server/A2aServer.cj:119`
- **来源**：存量（`dfb31f384b`）
- **判据**：review-checklist §11「注释承诺 A，实现校验 B」
- **证据**：静态确定 —— 用例只统计包含 `METHOD_ARTIFACT` 的事件条数，不比较下标
- **描述**：用例名与注释写的是「产物事件在状态事件之后单独发一条」，但断言等价于"恰好一条产物事件"。把 `publish` 的两段顺序对调（先产物后终态）后该用例仍通过，而 `A2aServer.cj:119` 的注释明确承诺"先状态后产物，客户端不会先看到产物"——这条顺序契约目前没有用例保护
- **建议**：断言产物事件的下标大于终态 status 事件的下标，或断言 `events.last()` 为 artifact

### [轻微][存量] 回调失败用例未断言回调实际发生过，`notifyTerminal` 提前返回时用例仍通过

- **位置**：`f_a2a/src/server/A2aStream_test.cj:192-202`
- **来源**：存量（`dfb31f384b`）
- **判据**：review-checklist §11「测试空断言 / 错误处理未覆盖」
- **证据**：静态确定 —— `notifier.ok = false`，用例只断言任务 `status == completed`
- **描述**：若 `notifyTerminal` 因任何原因没有调用回调（例如 `pushConfig.get` 未命中、提前 return），`calls` 为空，用例照样通过。用例声称覆盖"回调失败不影响任务状态"，实际只验证了"发送成功"，失败分支（`A2aServer.cj:291-294` 的 warn 且不回滚状态）没有被真正执行
- **建议**：补 `@Expect(notifier.calls.size, 1)`；如需覆盖 warn 分支，可断言返回值/false 之后 `status` 仍为 `completed`

> 本部分存量缺陷 9 条（严重 1 / 一般 3 / 轻微 5），是否纳入修复待用户决定。

## 优化可行性方案

### [CPU] 把副本构造移出临界区，并把任务表按 id 分片

- **现状**：`save`/`get`/`list` 每次在唯一一把 `Mutex` 内做一次 O(history) 的 JSON 往返（`A2aTaskStore.cj:43-69` → `A2aJson.cj:33-38`）；一次 `send` 落库 1 次，客户端随后 `get` 再 1 次，`list` 按条各 1 次。所有并发请求共用这把锁
- **方案**：①锁内只做 `tasks[id] = task` / 取引用，`copyOf` 移到 `synchronized` 外；②任务量增大后把 `HashMap` 拆成 N 个分片（按 `hash(id) % N`），每片一把锁，`count` 改为跨片求和
- **预期**：锁持有时间从 O(history) 降到 O(1)，`get`/`save` 混合负载下吞吐随线程数近线性；具体降幅需实测，不做数字承诺
- **代价**：①依赖"存进去的对象之后不再原地修改"这一不变量（当前成立：`save` 存的是副本，`get` 返回副本）；②分片后 `list`/`count` 需要跨片遍历，语义不变但实现变复杂；③分片数与容量上限（见 S1）要一起定
- **验证**：8 / 16 线程混合 `save`+`get` 压测，记录锁等待时长与 p99；`cjpm bench -O2` 同机对照，取中位数与离散度
- **证据状态**：`无基线（待验证，不进 tasks）`

## 待验证假设

| # | 假设 | 位置 | 缺什么数据 | 怎么采 |
| --- | --- | --- | --- | --- |
| 1 | 存储锁内 `copyOf` 已成为 `send`/`get` 的串行段 | `f_a2a/src/server/A2aTaskStore.cj:43-56` | 临界区时长、锁等待占比 | 8 线程混合 `save`/`get` 压测 10 分钟，分段计时 + 线程状态（BLOCKED 占比），history 10 条 vs 100 条各跑一轮 |
| 2 | 任务表长期增长速率决定 OOM 触顶时间 | `f_a2a/src/server/A2aTaskStore.cj:38,45` | 单任务实际占用字节、QPS | 连续 10k 次 `send`，每 1k 记录 `getUsedHeapSize()` 与 RSS 差值，除以任务数得单任务占用 |
| 3 | `list(0)` 全量物化在大存量下造成内存尖峰 | `f_a2a/src/server/A2aTaskStore.cj:58-69` | 1k/10k 任务时的分配量与峰值 | 预置 1k、10k 任务后调用 `list(0)`，对比调用前后 `getAllocatedHeapSize()` |

## 文件覆盖

> 与 `{workdir}/files/f_a2a.part2.txt` 一一对应（本部分清单共 2 个文件，均为 `.cj`）。

| # | 文件 | 类型 | 已读 | 说明 |
| --- | --- | --- | --- | --- |
| 1 | `f_a2a/src/server/A2aTaskStore.cj` | .cj | ✅ | 无删除/淘汰（#1）、锁内 `copyOf`（#2）、无原子更新（#3）、契约缺失（#4）、`list`（#5）、`count`（#6） |
| 2 | `f_a2a/src/server/A2aStream_test.cj` | .cj | ✅ | 顺序断言不严（#7/#8）、回调失败用例弱断言（#9）；`FixedExecutor` 复用自 `A2aServer_test.cj:27-37`（同包测试基建），3 个 private helper 均有调用 |

合计：`.cj` 2 个 / `.md` 0 个 / 共 2 个，全部读完（`.md` 与其余 13 个 `.cj` 见第 1 部分）。

## 覆盖自检

| 维度 | 命中 | 未命中时的说明 |
| --- | --- | --- |
| 正确性 / 设计 / 语言特性 / 可读性 / 安全性 | 4 | 正确性：整对象覆盖写丢更新（#3）；设计：接口契约缺失（#4）；语言特性：`copyOf` 走 JSON 往返而非显式 copy（#2）；安全性：无外部输入拼接，`copyOf` 的静默降级在当前数据上不可达 |
| §1 死代码 | 0 | 机械过完：`private mutex`/`tasks` 同文件使用；`A2aTaskStore` 三个方法为对外接口契约；`count()` 属「对外可达 public」，按硬原则不判死代码（仓内零引用记入 #6）；测试文件 `EventRecorder`/`RecordingNotifier` 及其 `public var` 在同文件使用，`streamCard`/`paramsOf`/`idOf` 三个 private 函数均有调用；两文件 import 均实际使用 |
| §2 重复逻辑 | 0 | 存储 4 个函数输出/副作用各不相同；测试 helper（`paramsOf`/`idOf`/`streamCard`）与 `A2aServer_test.cj:46-69` 的 `sendParams`/`idParams`/`card` 近似重复，属 checklist §2「测试准备代码」误报边界，不报；`copyOf` 的三处调用是同一函数的复用，不是重复实现 |
| §3 空实现 | 0 | `init()` 空体是无状态构造；`save`/`get`/`list`/`count` 均有实现；无 `TODO`/`FIXME`/`catch {}` |
| §4 栈溢出 | 0 | 唯一的递归面是 `copyOf`→`toJson`/`taskOf`，深度固定为 task→message→part 三层，不随输入增长（parts 是平铺数组） |
| §5 OOM | 1 | 任务表无界增长（#1）；`list` 全量物化（#5 附带说明） |
| §6.1 热点瓶颈 | 0 | 未提供 profile / bench 数据，锁内 `copyOf` 只按临界区内容判定（#2），耗时占比列入待验证假设 #1 |
| §6.2 大粒度锁 | 1 | 单锁保护整表且锁内做序列化（#2） |
| §6.3 并发串行 | 0 | 本部分无 `spawn` / `Future.get`；串行化来源是锁，已归 §6.2 |
| §6.4 低效算法 | 0 | 遍历为单层 O(n)；`copyOf` 是每条约定的深拷贝，不是重复计算 |
| §7 降堆内存方案 | 0 | 本部分可降的是"总量无界"，属缺陷 #1 的修法，不作为优化方案重复统计 |
| §8 降 CPU 方案 | 1 | 锁外复制 + 分片（证据状态：无基线） |
| §9 local mode 可行性 | 0 | `copyOf` 产物必然逃逸（返回给调用方），不满足 local region 逃逸检查；无收益证明路径 |
| §11 现有代码的 BUG（存量） | 9 | 本部分 9 条发现全部为存量，已逐条给 `git blame` 依据；重点核对过 `save`/`get`/`list`/`count` 的边界（空 id、`limit<=0`、空表）与并发路径 |
| §12 并发安全与锁粒度 | 3 | #2（锁粒度）、#3（读改写非原子）、#4（契约未声明线程安全）；共享路径已指明：`A2aServer` 单实例持有 `store`，由 JSON-RPC 线程池并发调用 |
| §14 功能完备性与 README 覆盖 | 2 | #5（`list` 无协议入口、半成品）、#6（`count` 不在接口却被 README 列出） |
| 文件覆盖（§13 等） | 2/2 | 本部分清单 2 个文件全部读完；`.md` 一致性结论见第 1 部分（本部分无 `.md`） |

## 模块统计

| 严重程度 | 数量 |
| --- | --- |
| 严重 | 1 |
| 一般 | 3 |
| 轻微 | 5 |
| 优化方案（堆内存 / CPU） | 0 / 1 |

## 总评

存储层代码很短（76 行），形态也干净：单锁 + 副本返回 + 接口与内存实现分离，`copyOf` 的字段覆盖经核对是完整的（`A2aTask` 7 个字段在 `toJson`/`taskOf` 里都有往返），`get` 的副本语义确有用例证明。真正的问题不在实现细节，而在**契约形状**：接口只提供"整对象写 + 副本读"，既没有删除/淘汰（#1，长跑必然 OOM），也没有条件更新（#3，让第 1 部分的"取消被覆盖"在存储层无解），而并发与副本这两条最关键的约定只写在实现类注释和 `doc/a2a-protocol.md` 里，没有落到接口上（#4）。次一级是锁内做整棵对象的序列化（#2），单请求看不出，但它是 `send`/`get` 并发度的上限，且改法明确、风险低。

`A2aStream_test.cj` 覆盖了流式主链路（working→completed、产物事件、重订阅、扩展卡片、推送生命周期、回调失败、非文本 part），方向正确但三处断言偏弱（#7/#8/#9），其中"产物在状态之后"和"回调失败"两条恰好是 `A2aServer` 注释里明确承诺的顺序/错误契约，却没有被真正锁住。

建议排期：优先 #1（容量上限 + 淘汰，或明确文档化"生产必须换持久化实现"）与 #3（接口加条件更新，与 part1 #1 一起改），#2/#4 可同批；#5-#9 随测试补强一起做。本部分存量缺陷 9 条，是否纳入修复待用户决定。
