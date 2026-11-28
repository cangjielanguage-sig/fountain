# f_egraph 模块审查报告

> **模块第 3/4 部分**（本报告只覆盖 `files/f_egraph.part3.txt` 列出的 20 个文件：`f_egraph/src/base/` 下 `EndExecutorGetter` → `JitHostRegistry` 的 16 个 `.cj` 与 4 个 `*_test.cj`。`README.md` / `README_en.md` / `doc/spec/**`、`QueuedClosureTask`、`AsyncDispatcher`、`AsyncFlow`、`TaskExecutor`、`FlowScriptRunner`、`egraph.cj` 等其余 38 个文件由第 1/2/4 部分产出；合并时以主 Agent 为准。）

- **审查日期**：2026-11-28
- **模块路径**：`f_egraph`（本部分 20 个 `.cj`，0 个 `.md`）
- **基线**：工作区快照（`sts/1.3.x`，无 diff 可比 ⇒ 全部问题记「存量」；`git blame` 抽样：`ImmediateDispatcher.cj:70-90` 全为 `4be871f2fd`（2026-10-02））
- **审查重点**：图算法正确性、递归深度与栈溢出、OOM、死代码、重复逻辑、并发安全、存量 BUG
- **报告版本**：v1（第 3/4 部分）
- **验证口径**：本轮只读代码，不跑构建、不跑测试；涉及语言 / 标准库语义的结论均现场查文档（引用路径写在各条判据里）；凡涉及频次、占比、耗时的只进「待验证假设」

## 发现

### [严重][存量] #1 `dispatch()` 只在遇到 `EndExecutor` 时返回，队列耗尽后永久阻塞在 `LinkedBlockingQueue.remove()` ⇒ 未注册 End 的流程 `start()` 挂死

- **位置**：`f_egraph/src/base/ImmediateDispatcher.cj:70-88`（`71` 空队列抛异常的守卫、`74` `while(let event <- getEvent())`、`81` `return this.end = end`）、`106-108`（`getEvent()` → `eventQueue.remove()`）、`20`（队列构造）；调用方 `f_egraph/src/base/ImmediateFlow.cj:118-125` → `ImmediateDispatcher.start` `92-96`
- **来源**：存量（`git blame -L 70,90 -- f_egraph/src/base/ImmediateDispatcher.cj` 全为 `4be871f2fd`，2026-10-02）
- **判据**：review-checklist §11「错误处理缺失 / 契约与实现不符」、§12.1「异步语义、有界性」
- **证据**：静态确定 —— 三条独立事实叠加：
  1. `getEvent()` 的返回类型是**非 `Option`** 的 `Event`（`ImmediateDispatcher.cj:106`），`while(let event <- getEvent())` 的绑定模式不可失败 ⇒ 循环条件恒真，唯一出口是 `81` 的 `return` 和 `85` 的 `throw`（语言文档 `cangjie_docs/docs/dev-guide/source_zh_cn/class_and_interface/typecast.md:92-133` 的 while-let 示例说明 `let pattern <- expr` 是「匹配成功即进入循环体」的条件糖）。
  2. `LinkedBlockingQueue.remove(): E` 是**阻塞**出队：「阻塞的出队操作，获得队首元素并删除」（`stdlib/doc/libs/std/collection_concurrent/collection_concurrent_package_api/collection_concurrent_class.md:561-567` 与 `3320-3326`）——队列为空时不会抛异常、不会返回，而是等待。
  3. 同一模式的异步版本把这条行为写成了注释：「`LinkedBlockingQueue.remove()` 在队列为空时会一直阻塞，而 dispatch 线程取空队列后正是长期停在这里」（`AsyncDispatcher.cj:154-164`）；`Flow_test.cj:126` 同样自认「`ImmediateDispatcher.dispatch` 只在遇到 `EndExecutor` 时返回」。
- **描述**：一个流程若不调用 `registerEnd()`（`BaseFlow.registerEnd()` 是可选的，`Flow.cj:24`），或末态任务返回 `DummyEvent`（`74-76` 的 `continue` 之后队列就空了），或末态任务返回的事件恰好没有对应执行器之外的任何出口，`dispatch()` 就会在 `remove()` 上永久阻塞。对 `ImmediateFlow.start()` 而言这意味着**调用线程挂死**（不是超时、不是异常），且该线程持有的业务锁 / 请求上下文一并冻结；`get()` 永远拿不到结果。触发条件全部由公开 API 的合法用法构成（不注册 End、任务返回 `DummyEvent`），不需要任何错误用法。另附两点：`71` 的 `eventQueue.size == 0` 守卫与 `74` 的阻塞出队之间存在 TOCTOU（`size()` 文档明确「不保证并发场景下的原子性」，`collection_concurrent_class.md:2752-2756`）；`85` 的 `throw` 退出后队列里剩余的事件既不清空也不上报，下一次 `start` 会把它们当作本次事件消费（见 #2）。
- **建议**：把消费循环改成有界、可退出的形式——`tryRemove()`（`collection_concurrent_class.md:778-790`，非阻塞、空队列返回 `None`）驱动循环，或 `remove(timeout:)` + 「连续空转 N 次且无在途任务」退出；「没有 End」应显式失败：`start()` 返回一个 `tryGet()` 为 `None` 的 getter 或抛 `GraphException('flow ${category}-${tag} has no EndExecutor registered')`。若确认「必须 registerEnd」是契约，则把它写进 `BaseFlow.registerEnd` 的注释与 README，并让 `start` 前置校验（`dispatch` 里已在 `92-96` 拿到 dispatcher，可直接查 `executors` 是否有 End 键）。

### [严重][存量] #2 「一次 start」的会话状态（`eventQueue` / `end` / `executors`）全部落在共享 dispatcher 实例上，既无会话隔离也无同步

- **位置**：`f_egraph/src/base/ImmediateDispatcher.cj:19-22`（`executors` 普通 `HashMap<Event, ArrayList<Executor>>`、`eventQueue`、`startEventNames` 普通嵌套 `HashMap`）、`69`（`private var end = None<EndExecutor>`）、`74-88`、`89-91`（`accept` 只 `add`）、`97-102`（`get`/`tryGet` 直读 `end`）、`103-105`（`removeIf` 直接改 `executors`）；`f_egraph/src/base/ImmediateFlow.cj:19`（`private static let dispatchers`，同一 `(category, tag)` 全进程共用一个 dispatcher）、`118-125`（`start` 把 dispatcher 自己当 `EndExecutorGetter` 返回）、`126-128`（`emit` 直接 `accept`）
- **来源**：存量（`git blame -L 19,111` 全为 `4be871f2fd`）
- **判据**：review-checklist §12.1「共享可变状态无保护 / 迭代与修改并发 / 可见性 / 发布逸出」、§11「并发正确性」、§10「正确性」
- **证据**：静态确定 —— 共享路径可逐段点出：
  1. **结果是单槽**：`ImmediateDispatcher.start()` 返回 `this`（`92-96`），`end` 是该实例上的**唯一字段**（`69`），`81` 写入、`98` 读取。因此「上一次 start 拿到的 getter」和「这一次 start 拿到的 getter」是同一个对象：顺序调用 `let g1 = flow.start(a); flow.start(b); g1.get()` 得到的是 b 的 `EndExecutor`；并发调用时两个线程都往 `end` 写，谁后跑完谁覆盖，两个调用方都可能拿到对方的结束事件。
  2. **队列是单槽**：`eventQueue` 是全流程共享的 FIFO（`20`、`90`），`dispatch` 无锁地 `remove()` 并就地执行。两个线程各自 `start` 时，双方的 `dispatch` 循环会**抢同一个队列**——A 的消费者可能取走 B 的 `StartEvent` 并用 B 的数据跑 A 的逻辑（执行器按 `(eventType, category, tag, name)` 路由，与 session 无关），结束后把 B 的 End 写进同一个 `end`。
  3. **End 提前返回会留残留**：`81` 一遇到 `EndExecutor` 就 `return`，队列里剩下的事件不清理。`Flow_test.cj:231-241`（`emitEnqueuesEvent`）就是这种用法：先 `emit` 一条 End、再 `start`，队列为 `[End, Start]`，`dispatch` 处理完 End 即返回，`StartEvent` 留在队列里；下一次 `start` 会先消费这条**上一次会话**的 Start 并可能提前返回它的 End。
  4. **容器与字段无同步**：`executors` 是普通 `HashMap<K, ArrayList<E>>`，`removeIf`（`103-105`）与 `doRegister`（`54-58` 的 `add`）会结构性修改它，而 `dispatch` 在 `77-83` 无锁遍历同一个 `ArrayList`；`end` 是普通 `var`，`startEventNames` 是普通嵌套 `HashMap` 且被 `41-47`（读）与 `34-40`（写）跨线程访问。按语言并发模型（`cangjie_docs/docs/dev-guide/source_zh_cn/concurrency/sync.md` 第 1 节：共享可变状态必须用原子 / 锁 / 通道保护），这些都是数据竞争。`ImmediateDispatcher` 没有任何 `Mutex`，也没有「仅单线程」的文档约束（`README.md:483-499` 只列签名）。
  与第 2 部分已报的 `AsyncDispatcher`「结束事件按线程 id 单槽、消费者不退出」（`parts/f_egraph.part2.md` #1/#2）是**同一设计缺陷的同步侧版本**：那边靠 `spawn` 把并发掩盖成「线程各干各的」，这边直接把并发暴露在调用线程上。
- **描述**：`ImmediateFlow` 是服务端每请求启动一次的对象，`(category, tag)` 相同的请求天然并发命中同一个 dispatcher。后果有三类：事件跨请求串流（A 的数据进 B 的流程）、结果错投（拿到别人的 End）、以及 `removeIf` 与 `dispatch` 并发时 `ArrayList` / `HashMap` 的迭代-修改竞态（漏删、`ConcurrentModification` 类异常、结构损坏）。这些都不是「可能慢」，而是结果错误。
- **建议**：把「一次启动」显式建模成一个对象——`start()` 返回 per-start 句柄（含自己的 `eventQueue` 或 session 过滤、自己的 `end` 槽、`Future`/`Condition`），dispatcher 只持有不可变的「执行器表」；或最小改动：`start` 全程 `Mutex` 串行化 + `end` 改为 per-`Event.session` 的 `ConcurrentHashMap`、消费循环按 `event.session` 过滤掉非本次会话的事件（`Event.session` 已存在且默认每事件一个 UUID，`Event.cj:32`）。无论哪种，`executors` 至少要换成并发容器，并把 `removeIf` 与 `dispatch` 的关系写清楚（现注释只在 `AsyncDispatcher` 侧说明 `mutex` 保护）。

### [一般][存量] #3 `Event` 文档承诺的 `priority` / `cancelPrev` / `EmptyEvent` 取消语义只在 `QueuedClosureTask` 内成立，`ImmediateDispatcher` 完全忽略

- **位置**：承诺源 `f_egraph/src/base/Event.cj:23-26`（「`priority`：0 抢占并合并执行；1 等当前结束后合并执行；>=2（默认）逐条执行」「`cancelPrev > 0`：撤销前面 N 条同优先级事件」）、`117-122`（「空事件：执行时什么也不做，只作为『取消指令』」）；实现缺口 `f_egraph/src/base/ImmediateDispatcher.cj:89-91`（只 `add`，不看 `priority` / `cancelPrev`）、`74-86`（只跳过 `is DummyEvent`，`EmptyEvent` 不是 `DummyEvent` 子类，直接落 `85` 的 `No executor found`）；唯一实现 `f_egraph/src/base/QueuedClosureTask.cj:68-100`、`263-295`
- **来源**：存量（`git blame -L 74,91`、`-L 23,26` 均为 `4be871f2fd`）
- **判据**：review-checklist §11「契约与实现不符 / 语义与注释不符」、§14.1「只做了一半的分支」
- **证据**：静态确定 —— `Event` 构造函数接受并校验 `priority` / `cancelPrev`（`37-42`），把语义写进了公开 API 的注释；但 `ImmediateDispatcher` 的队列是 `LinkedBlockingQueue`（FIFO，无优先级概念），`accept` 只入队、`dispatch` 只按到达序执行。真正兑现这段注释的只有 `QueuedClosureTask.submit`（`76-100`：`cancelPrev` 删同优先级尾部、`EmptyEvent` 删同名同优先级尾部、`priority == 0` 立即执行）。而 `priority` / `cancelPrev` 是 `Event` 层面的字段，任何 `Task` 实现（`TaskExecutor` 直接 `accepter.accept(task(event))`，`TaskExecutor.cj:39-41`）返回的事件都会带着它们进入 dispatcher，此时语义静默失效。
- **描述**：两种可观察后果：① 用 `ImmediateFlow` + 普通 `ClosureTask`（非 `Queued`）组成的流程里，`priority = 0` 的「抢占」不发生，事件仍按 FIFO 逐条跑——调用方按注释设计出的「最新配置覆盖旧配置」会变成「旧配置先执行完、新配置后执行」，业务结果取决于时序；② 任务返回 `EmptyEvent(cancelPrev: 1)` 想撤销前一条事件时，dispatcher 既不撤也不忽略，而是抛 `GraphException("No executor found for event: Event(eventType: Dummy, category: , tag: , name: ...)")`，把一次「取消」升级成流程失败。与第 1 部分 `parts/f_egraph.part1.md` §「事件字段与 Dummy 语义的描述与实现不符」重叠（那条讲文档描述，本条讲实现面缺失与错误路径），合并时取一条即可。
- **建议**：二选一并落到注释：要么让 `ImmediateDispatcher` 也按 `priority` 排序（队列换 `SyncPriorityQueue`，`QueuedClosureTask` 已在用）并在 `74` 之前先处理 `EmptyEvent` 的撤销；要么把 `Event.cj:23-26`、`117-122` 的注释改成「优先级与撤销仅对 `QueuedClosureTask` 生效，其它 `Task` 实现忽略」，同时让 `EmptyEvent` 在任何 dispatcher 下都被静默跳过（`74` 的判定从 `is DummyEvent` 改为 `event.eventType == EventType.Dummy`）。

### [一般][存量] #4 `JitHostRegistry.configure` 每次调用都往进程级 `HostFieldTable` 追加 4 个等价访问器，无去重 ⇒ 全局表只增不减，且字段查找退化为线性扫描

- **位置**：`f_egraph/src/base/JitHostRegistry.cj:37-49`（`38` 无条件 `registerEventFields()`）、`54-91`（4 次 `HostFieldTable.register`）、`24-25`（注释「重复 `configure` 只会追加等价访问器」）；被调方 `f_jit/src/runtime/HostField.cj:91-114`（`register` 每次 `list.add(acc)`，无查重）、`121-133`（`find` 在桶内逐个 `accepts` 线性扫描）
- **来源**：存量（`git blame -L 37,91` 为 `4be871f2fd`；`HostField.cj` 为 f_jit 范围，仅作被调方证据）
- **判据**：review-checklist §5「长期持有 / 全局集合只增不减」、§6.4「热点里对 `Array` 反复线性查找」、§11「注释与实现不符」
- **证据**：静态确定 —— `HostFieldTable.register` 的写入路径没有任何键判重：`synchronized` 内取出旧桶、`ArrayList` 复制、`list.add(acc)`、整表原子替换（`HostField.cj:96-113`）。因此每次 `configure` 净增 4 个 `HostFieldAccessor`（每个含 2 个闭包 + `type`/`mutable`），永不释放；同一 index 的桶长度随 `configure` 次数线性增长，`find` 每次字段读都要按注册序逐个 `accepts(obj)`（`121-133`）。调用点：`f_egraph/src/egraph.cj:39`（模块初始化 1 次）、`f_egraph/src/base/ClosureTask.cj:76`（惰性编译器 1 次）、`f_llm/src/loom/LoomCompiler.cj:40`（**每个 `LoomCompiler` 实例 1 次**，范围外提示）。
- **描述**：注释把「追加等价访问器」当成了无害事实，实际是两个后果：进程 RSS 随 `configure` 次数单调上升（每次 4 个访问器 + 2 个闭包捕获），脚本字段读的耗时随桶长度线性上升（命中越晚越慢，而 `Event` 的 4 个字段都在同一个对象上反复读）。若 `LoomCompiler` 按会话 / 按脚本创建，这就是一条无上限的慢性泄漏，且没有清理 API（`resetForTest` 仅测试用）。
- **建议**：`registerEventFields` 做成幂等——按「index + 目标类型」在 `HostFieldTable` 内部查重（`register` 增加 `if (list.any{it.accepts(sample)}) return` 之类）或把访问器表改成 `static let` 只注册一次、`configure` 只做 `registerClass`；同时把 `JitHostRegistry.cj:24-25` 的注释改成与实现一致（「等价访问器会被重复追加，故需幂等」）。

### [一般][存量] #5 `ImmediateFlow` 与 `AsyncFlow` 是两份逐行同形的实现，且已经出现行为漂移

- **位置**：`f_egraph/src/base/ImmediateFlow.cj:28-43`（`canBeRemoved`）↔ `AsyncFlow.cj:28-43`；`93-107`（`registerTask` 校验 + `registerTask(Task)`）↔ `AsyncFlow.cj:117-131`；`111-113`（`registerMultiEventTask`）↔ `AsyncFlow.cj:135-137`；`118-128`（`start` / `emit`）↔ `AsyncFlow.cj:142-155`；`58-69`（`hashCode` / 两个 `==` / `toString`）↔ `AsyncFlow.cj:83-94`；`70-74`（`dependencied`）↔ `AsyncFlow.cj:99-103`
- **来源**：存量（`git blame -L 28,128 -- f_egraph/src/base/ImmediateFlow.cj` 为 `4be871f2fd`；`AsyncFlow.cj` 属第 2 部分，此处只作对照）
- **判据**：review-checklist §2「只改类型名 / 换控制流，语义相同」+「近似重复里少一处边界判断往往同时是缺陷」
- **证据**：静态确定 —— 两段代码压成「输入 → 输出 → 副作用」后逐条相同：`canBeRemoved`（拼依赖串 → 抛 `GraphException`，文案一字不差）、`registerTask`（三态校验 + 同样两句错误消息）、`hashCode`（`HashBuilder().append(category).append(tag)`）、`toString`（`'${category}-${tag}'`）、`start`（本地 `startName` 为空则回退 `startEventName`）、`emit`（`dispatcher.accept(DataEvent(...))`）。差异只应在「dispatcher 类型」，实际已经扩散到行为：
  1. **判重机制不同**：`AsyncFlow` 用独立的 `flows: ConcurrentHashSet` 判重（`AsyncFlow.cj:73-80`），`ImmediateFlow` 用「`dispatchers` 里有没有这个键」判重（`ImmediateFlow.cj:24-26`）；
  2. **remove 路径不同**：`ImmediateFlow.removeExceptCurrentTag` 在 `removeIf` 谓词里构造实例并判依赖（`48-56`），`AsyncFlow` 改成「谓词只标记、循环后删集合」（`57-72`）；
  3. **start 校验不同**：`AsyncFlow.start` 用 `match` 校验返回值并抛 `GraphException`（`148-151`），`ImmediateFlow.start` 直接 `dispatchers[this].start(...)`（`124`），移除后抛的是 map 索引异常（见 #8）。
- **描述**：约 60 行同形代码，改一处必须记得改另一处；已经出现的三处漂移说明维护同步失败，同一份业务脚本在同步 / 异步流程上会表现不一致（这正是 #2/#8 与第 2 部分 #7/#10 的温床）。注意 `AsyncFlow` 的 5 个 `register*` 包装那种「形状相同但目标不同」不算重复（第 2 部分已判），本条的判据是函数体语义等价。
- **建议**：抽 `abstract class FlowBase<D> <: Flow<...>` 承载 `canBeRemoved` / `registerTask` 校验 / `start` 回退 / `emit` / `hashCode` / `==` / `toString`，两个子类只提供 `dispatcher()`、`ensureRegistered()`、`doRemove(except:)`；落点放在 `f_egraph/src/base`（同模块内，不新建共享包）。抽之前先把 #8 的错误语义定下来，否则会把错误语义一起复制。

### [一般][存量] #6 `ImmediateDispatcher.eventQueue` 无容量上限、只有 `dispatch` 消费，`emit` 只入队不派发 ⇒ 无背压的堆积

- **位置**：`f_egraph/src/base/ImmediateDispatcher.cj:20`（`LinkedBlockingQueue<Event>()` 无参构造）、`89-91`（`accept` 只 `add`）、`70-88`（唯一消费者）；生产者入口 `f_egraph/src/base/ImmediateFlow.cj:126-128`（`emit` 只 `accept`）
- **来源**：存量（`4be871f2fd`）
- **判据**：review-checklist §5「无界容器 / 没有拒绝路径」、§12.1「有界性」
- **证据**：静态确定（容量默认值有文档）——`LinkedBlockingQueue()` 无参构造的容量是 `Int64.Max`（`collection_concurrent_class.md:2789`「构造一个具有默认初始容量（`Int64.Max`）的 `LinkedBlockingQueue`」），`add` 永不失败；而 `emit` 不触发 `dispatch`，队列只在下一次 `start()` 里被消费（`Flow_test.cj:229-241` 的 `emitEnqueuesEvent` 就是靠这个语义）。`Event` 的载荷是 `Any`（`Event.cj:67`），下游可放任意大对象。
- **描述**：两条堆积路径：① 外部线程周期性 `emit`、但流程长时间不 `start`（或 `start` 在 End 处提前返回，见 #2-③），队列只增；② 单个任务里 `emit` N 条而下游处理慢，`dispatch` 在跑完之前队列已按 N 增长。最坏规模 = `emit` 速率 × 单事件载荷大小，无上限、无拒绝、无打点，只能到 OOM 才发现。第 2 部分已把该容器作为 `AsyncDispatcher` #1 的「背压缺失」附带提及，本部分给出容器本身的容量与消费语义证据。
- **建议**：构造时给显式容量（配置项，默认值可查询 `f_config`），满时对生产者施加背压（阻塞或抛带上下文的 `GraphException`）；`dispatch` 正常退出（End）与异常退出时都要处理残留：要么清空并打点计数，要么按 `session` 留在队列里但保证不会被下一次 `start` 误消费（依赖 #2 的会话隔离）。

### [一般][存量] #7 `registerTaskByFlow` 的子流程嵌套同步派发没有环检测 ⇒ 自引用 / 互引用流程无限递归（栈溢出）

- **位置**：`f_egraph/src/base/Flow.cj:74-77`（默认实现：`registerTask(eventName) {e => flow.start(((e as DataEvent).getOrThrow()).data).get().get()}`）、`83-93`（两个便捷入口）；每层递归的落点 `f_egraph/src/base/ImmediateFlow.cj:118-125`；等价路径 `TaskExecutor.cj:30-31`（`newByFlow`，同模块其它部分）
- **来源**：存量（`git blame -L 74,93 -- f_egraph/src/base/Flow.cj` 为 `4be871f2fd`）
- **判据**：review-checklist §4「间接递归 / 自引用结构」、§11「边界」
- **证据**：静态确定（递归存在、无深度上限、无环检测）——`registerTaskByFlow` 让「任务体」变成「同步启动另一个流程并等它结束」，子流程的 `start` 又调 `dispatch`（`ImmediateDispatcher.cj:92-96`），于是调用栈深度 = 子流程嵌套层数；`dependencied`（`Flow.cj:76`）只用来阻止删除（`ImmediateFlow.cj:28-43`），**不参与任何环检测**。`flow.registerTaskByFlow(eventName: "x", flow: flow)`（把流程挂到自己的事件上）在语法与类型上都合法（`F <: Flow<G>`，`G` 可等于自身的 `G`），一旦该事件被触发就是无限递归：每层都新增一个 `dispatch` 栈帧、一个 `StartEvent`、一条队列。可达性：该 API 未暴露给脚本（`JitHostRegistry.flowMethods` `199-218` 只注册 7 个方法），只有宿主代码能写出环 → 证据等级「静态确定（机制）/ 待确认（真实调用图是否成环）」。
- **描述**：崩溃形态是 `StackOverflow`（不可捕获、整进程退出），而不是可处理的 `GraphException`；同时每层递归都在分配事件对象，先爆栈再爆堆。深度上界不是输入规模，而是**流程定义的图深度**——由宿主（或生成脚本的代码）决定，没有常量上限。
- **建议**：注册时做一次可达性检查（把 `dependencied` 升级成有向图，`registerTaskByFlow` 时 DFS 判环，命中直接抛 `GraphException` 并打印环路径）；运行期再加一道保险：`ImmediateFlow` 维护 `start` 的线程内深度计数（`ThreadLocal<Int64>`），超过常量上限（例如 64）抛明确异常。修好 #2 的会话隔离后，这一步可以顺带用 per-start 句柄上的 `depth` 字段实现。

### [轻微][存量] #8 `ImmediateFlow.start` / `emit` 在流程未登记或被移除后抛非契约异常；本地 `startName` 缺失时静默回退到空串

- **位置**：`f_egraph/src/base/ImmediateFlow.cj:124`（`dispatchers[this].start(...)`）、`127`（`dispatchers.get(this).getOrThrow()`）、`119-123`（`startEventName(...) ?? ""`）
- **来源**：存量（`4be871f2fd`）
- **判据**：review-checklist §11「空集合 / `None` 未处理」「契约与实现不符」
- **证据**：静态确定（行为）/ 待确认（具体异常类型）——`ConcurrentHashMap` 的索引运算符文档：「如果键存在，返回键对应的值；如果不存在，抛出异常」（`collection_concurrent_class.md:1835-1846`），因此 `remove()`（`44-47`）之后再 `start()` 抛的是容器异常而不是本模块统一的 `GraphException`；`emit` 同理（`getOrThrow()` 抛 `NoneValueException`）。另一处是 `119-123`：本地 `startName` 为空且 dispatcher 侧也没记录时，`?? ""` 生成 `name = ""` 的 `StartEvent`，最终在 `ImmediateDispatcher.cj:85` 表现为 `No executor found for event: Event(eventType: Start, ..., name: )`——错误信息里看不出「忘了 `registerStart`」。
- **描述**：调用方按 `GraphException` 统一处理流程错误（模块内其它所有失败路径都用它）时，这两条路径会漏网；空名回退把「配置缺失」伪装成「执行器缺失」，排查成本高。
- **建议**：`dispatchers.get(this) ?? throw GraphException('flow ${category}-${tag} is not registered or already removed')`；`startName` 与 dispatcher 记录都为空时抛 `GraphException('start event name is not registered for ${category}-${tag}')`，不要用空串兜底。

### [轻微][存量] #9 `registerEventFields` 四段只差索引与取值字段，属字面量复制

- **位置**：`f_egraph/src/base/JitHostRegistry.cj:54-91`（4 × 10 行，仅 `index:` 与 `e.category`/`e.tag`/`e.name`/`e.session` 不同）
- **来源**：存量（`4be871f2fd`）
- **判据**：review-checklist §2「只改字段名 / 字面量复制」
- **证据**：静态确定 —— 四段的 `type` / `mutable` / `accepts` / `setter` 完全相同，`getter` 的 `match` 与默认值完全相同；`eventFields()`（`93-104`）已经是「数组 + 逐项字段」的写法，两处结构不一致。
- **描述**：加第 5 个字段时要改两处（`eventFields` 与 `registerEventFields`），漏一处会出现「描述符里有、运行期访问器没有」的半接线状态（`HostFieldTable.find` 返回 `None` → 运行期 99 号错误）。
- **建议**：改成 `[(0u16, {e: Event => e.category}), (1u16, {e: Event => e.tag}), ...]` 的数组驱动，`eventFields()` 与 `registerEventFields()` 共用同一张表（字段名 + index + getter），从源头保证两边一致。

### [轻微][存量] #10 `Flow.emit` 与 `BaseFlow.emit` 同签名重复声明

- **位置**：`f_egraph/src/base/Flow.cj:41`（`BaseFlow` 内）与 `f_egraph/src/base/Flow.cj:95`（`Flow` 内，签名逐字相同）
- **来源**：存量（`4be871f2fd`）
- **判据**：review-checklist §2「重复声明」、§10「可读性」
- **证据**：静态确定 —— `Flow <: BaseFlow`（`61`），`emit(eventType:name:data:)` 在 `41` 已声明，`95` 再声明一次完全相同的签名，没有新增默认实现或收窄类型。
- **描述**：读者会以为子接口有额外约束；实现类（`ImmediateFlow.cj:126-128`、`AsyncFlow.cj:153-155`）只需实现一次。属可读性噪音，无行为影响。
- **建议**：删掉 `Flow.cj:95`。

### [轻微][存量] #11 `testPriorityZeroRunsBeforeQueuedBacklog` 名不副实：没有制造 backlog，断言恒真

- **位置**：`f_egraph/src/base/FlowQueueIntegration_test.cj:53-70`（`67` 注释「先塞一条 p2 到队列，再让流程触发」、`69` `@Expect(counter.executed >= 1, true)`）
- **来源**：存量（`4be871f2fd`）
- **判据**：review-checklist §11「语义与注释不符」、§10「可测试性」
- **证据**：静态确定 —— 用例体只有 `flow.registerStart` / `registerTask` / `registerEnd` / `flow.start('go')`，注释里说的「p2 事件」**从未提交**（没有 `submit`、没有 `priority: 0` 的事件构造）；`counter.executed >= 1` 在流程跑通时恒为真，无法区分「p0 抢在 p2 之前」与「只是跑了一次」。本模块唯一实现抢占语义的地方（`QueuedClosureTask.submitImmediate`，`QueuedClosureTask.cj:108-142`）因此没有端到端顺序断言。
- **描述**：给维护者「已被覆盖」的错觉；`QueuedClosureTask` 的 p0 顶替、`cancelPrev` 撤销、同名合并这三条语义目前只有 `QueuedClosureTask_test`（同模块第 4 部分）的单元层覆盖，缺一条「提交 backlog → 触发 p0 → 断言执行顺序」的集成用例。
- **建议**：真的先 `task.submit(p2Event)` 造出 backlog，再让流程触发 p0，用有序 `ArrayList<String>` 记录执行序列并断言 `["p0", "p2-merged"]`；或把用例改名为 `flowRunsQueuedTaskOnce` 并把断言收紧到 `== 1`。

## 优化可行性方案

> 以下不是缺陷，是「还能更好」；两条都**没有改前基线**，只作待验证方向，不进 `todo.md` / `tasks.md`。

### [堆内存] 事件 `session` 默认值（每事件一次 UUID + 36 字符）在同步流程里完全用不到

- **现状**：`Event` 及其 7 个子类的构造器都把 `session` 默认成 `UUID.random().toHexString()`（`Event.cj:32,63,78,84,90,96,101,106,125`），即每个事件固定付一次 UUID 生成 + 两次 36 字符 `String` 分配；而唯一消费 `session` 的是 `BarrierTask` 的会话聚合（`BarrierTask.cj:18-27`，同模块其它部分）。`ImmediateDispatcher` 的路由键只看 `(eventType, category, tag, name)`（`Event.cj:43-48`），完全不读 `session`。
- **方案**：把 `session` 改成惰性 / 可选：默认空串，由需要会话维度的调用方（`BarrierTask` 路径）显式传入；或提供 `Event.withNewSession()` 在需要时补。改动点集中在 `Event.cj` 的默认参数，语义上「session 为空」= 不参与聚合。
- **预期**：每次事件构造少一次 UUID + 2 个 36 字符串；按 `perf` 层面的收益取决于事件吞吐（未测）。峰值内存下降量 ≈ 事件峰值数 × 约 100 B。
- **代价**：`session` 为空时 `BarrierTask` 的 key 需要明确处理（拒绝或退化为按 category/tag 聚合），属语义变化，需要业务确认；事件相等性不受影响（`==` 不含 session）。
- **验证**：同机同 SDK `-O2`，固定 10k 事件 × 4 阶段流程，对比 `getAllocatedHeapSize()` 增量与 `cjprof record` 中 `UUID`/`String` 分配占比、P50/P99 端到端耗时。
- **证据状态**：无基线（待验证，不进 tasks）

### [CPU] `EventType.hashCode` 每次调用都插值一个包名限定串

- **现状**：`EventType.hashCode()` 实现为 `'fountain::f_egraph.base.EventType.${this}'.hashCode()`（`EventType.cj:36-38`），每次调用一次 `StringBuilder` + `toString` + 字符串哈希；而每个 `Event` 构造都会经 `HashBuilder().append(eventType)`（`Event.cj:43`）触发它一次，`Event` 又是流程每一步的必建对象。
- **方案**：6 个枚举值的哈希是常量，改成 `static let` 预计算表（或 `match(this)` 返回 6 个字面量常量），`hashCode()` 只做一次数组 / 分支查找；包名限定串只在确需稳定跨版本哈希时保留，并在注释里写明理由。
- **预期**：每次事件构造少一次字符串分配与哈希；端到端收益取决于事件吞吐与 GC 压力（未测）。
- **代价**：哈希值变成代码内常量，若历史上已有持久化依赖这些哈希值（本模块未见），需要迁移说明；改动面仅 `EventType.cj`。
- **验证**：`cjpm bench -O2` 对「构造 N 个 `Event` + 插入 `HashMap<Event, _>`」做前后对照（N = 1e6，重复 5 轮取中位数），并用 `cjprof` 看 `EventType.hashCode` 的自耗时占比是否可测。
- **证据状态**：无基线（待验证，不进 tasks）

## 待验证假设

| # | 假设 | 位置 | 缺什么数据 | 怎么采 |
| --- | --- | --- | --- | --- |
| 1 | 事件路由（`HashBuilder` 构造 + `HashMap<Event>` 查找 + `Event.==` 的 4 次字符串比较）占单步流程耗时的主要部分 | `Event.cj:43-48`、`ImmediateDispatcher.cj:109-111` | 该路径自耗时占比、每步平均耗时 | `cjprof record` 跑 4 阶段流程 × 10k 事件、并发 1/8，看 `hashCode`/`equals`/`HashMap.get` 占比 |
| 2 | 每事件一次 UUID `session` 的分配占 GC 时间的主要部分 | `Event.cj:32` 等 9 处 | 分配量占比、GC 次数 | `cjprof heap` 对比「保留默认 session」与「session 传空串」两种构建的分配量与 GC 停顿 |
| 3 | 重复 `configure` 后 `HostFieldTable.find` 的桶内线性扫描已成为脚本字段读的瓶颈 | `JitHostRegistry.cj:54-91`、`HostField.cj:121-133` | 桶长度、`find` 自耗时 | 在 `f_llm` 侧统计 `configure` 调用次数与桶长度，`cjprof` 看 `find` 占比（输入：1 个 Loom 编译 1k 个任务的脚本） |
| 4 | 长跑服务里 `ImmediateFlow.dispatchers` 随 `(category, tag)` 数量单调增长（脚本动态生成 tag 时无回收） | `ImmediateFlow.cj:19`、`44-56` | 运行 24h 后的 key 数、`remove` 调用次数 | 给 `dispatchers.size` 加周期性打点，跑 24h 真实流量（含滚动发布换 tag） |

## 文件覆盖

| # | 文件 | 类型 | 已读 | 说明 |
| --- | --- | --- | --- | --- |
| 1 | `f_egraph/src/base/EndExecutorGetter.cj` | .cj | ✅ | 两个方法均为公开接口契约，`ImmediateDispatcher`/`AsyncDispatcher` 实现、`Flow<G>` 上界引用；对外可达，不判死代码 |
| 2 | `f_egraph/src/base/ErrorExecutor.cj` | .cj | ✅ | 被 `ImmediateDispatcher.cj:49` 注册；`execute` 三分支（`String`/`Exception`/其它类型名）与 `Executor_test.cj:113-148` 一致，无缺陷 |
| 3 | `f_egraph/src/base/Event.cj` | .cj | ✅ | 见 #3（`priority`/`cancelPrev`/`EmptyEvent` 承诺）、#8（`session` 默认值）；`==`/`hashCode` 只含 4 字段，与 `executors` 键一致，正确；`priority`/`cancelPrev` 的负数校验在 `37-42` |
| 4 | `f_egraph/src/base/EventType.cj` | .cj | ✅ | 6 值 + `toString`/`hashCode`/`==`；`hashCode` 的字符串分配见优化方案「[CPU]」 |
| 5 | `f_egraph/src/base/EventType_test.cj` | .cj | ✅ | 3 个用例覆盖 `toString` 契约、哈希稳定性、相等性全组合；断言与实现一致 |
| 6 | `f_egraph/src/base/Event_test.cj` | .cj | ✅ | 8 个用例覆盖 8 个事件类；`equalityIgnoresSessionAndData` 与 `Event.cj:45-48` 一致 |
| 7 | `f_egraph/src/base/Executor.cj` | .cj | ✅ | 公开接口 + `accept` 默认实现（转发 `execute`）；`ImmediateExecutor`/`TaskExecutor`/`AsyncTaskExecutor` 实现 |
| 8 | `f_egraph/src/base/Executor_test.cj` | .cj | ✅ | 13 个用例；`startExecutorRequiresDataEvent`/`errorExecutorThrowsByPayloadType` 的空值分支覆盖到位；未覆盖并发 accept |
| 9 | `f_egraph/src/base/Flow.cj` | .cj | ✅ | 见 #7（`registerTaskByFlow` 无环检测）、#10（`emit` 重复声明）；`multiEventTaskBody`（`48-60`）为 `internal` 且被 `Flow.cj:68`、`ImmediateFlow.cj:112`、`AsyncFlow.cj:136` 使用，非死代码 |
| 10 | `f_egraph/src/base/FlowEventFactory.cj` | .cj | ✅ | 5 个 `@JitBind` 静态函数 + `flowDataOf`；与 `FlowEventFactory_test.cj` 6 个用例一致；`flowDataOf` 对非 `String`/非 `DataEvent` 返回空串是文档化行为 |
| 11 | `f_egraph/src/base/FlowEventFactory_test.cj` | .cj | ✅ | 6 个用例全部对应 `FlowEventFactory` 的 5 个函数与 2 个分支 |
| 12 | `f_egraph/src/base/FlowQueueIntegration_test.cj` | .cj | ✅ | 见 #11（`:53-70` 断言恒真）；`:34-51` 的端到端链路断言有效 |
| 13 | `f_egraph/src/base/Flow_test.cj` | .cj | ✅ | 13 个用例；`:126` 注释自认 `dispatch` 只在 End 处返回（#1 证据）；`emitEnqueuesEvent`（`231-241`）是 #2-③ 残留事件的直接场景；测试清理（`remove()`）基本到位 |
| 14 | `f_egraph/src/base/ImmediateDispatcher.cj` | .cj | ✅ | 见 #1、#2、#3、#6；`doRegister` 两版（`24-33` 查重 / `54-58` 追加）职责不同，不算重复 |
| 15 | `f_egraph/src/base/ImmediateDispatcher_test.cj` | .cj | ✅ | 7 个用例覆盖注册查重、无执行器、错误事件、`removeIf`、Multi 路由、`startEventName`；**无并发用例**，也无「队列耗尽后返回」的用例（#1/#2 长期存活的直接原因） |
| 16 | `f_egraph/src/base/ImmediateExecutor.cj` | .cj | ✅ | `accept` 先校验 `acceptable` 再 `execute`，与 `Executor_test.cj:60-70` 一致；无可变状态 |
| 17 | `f_egraph/src/base/ImmediateFlow.cj` | .cj | ✅ | 见 #2、#5、#8；`startName`/`hasFirstTask` 状态机（`93-102`）与 `ImmediateDispatcher` 的键一致 |
| 18 | `f_egraph/src/base/JitBinding_test.cj` | .cj | ✅ | 6 个用例覆盖宏登记面正反向；`newCompiler` 每次 `HostFieldTable.resetForTest()`，掩盖了 #4 的累积问题（可理解） |
| 19 | `f_egraph/src/base/JitHostRegistry.cj` | .cj | ✅ | 见 #4、#9；描述符与 `JitHostRegistry_test.cj` 的金线断言逐条对应；`private init()` + 全静态，无实例状态 |
| 20 | `f_egraph/src/base/JitHostRegistry_test.cj` | .cj | ✅ | 10 个用例覆盖 8 个事件类、父链、方法面、绑定名唯一性、字段表索引 0-3、`registeredNames`；`descriptorNamed` 用 `throw GraphException` 兜底合理 |

合计：`.cj` 20 个 / `.md` 0 个 / 共 20 个，全部读完。

## 覆盖自检

| 维度 | 命中 | 未命中时的说明 |
| --- | --- | --- |
| 正确性 / 设计 / 语言特性 / 可读性 / 安全性 | 9 | 正确性见 #1-#3、#6-#8；设计见 #2（把 per-start 状态放到共享实例）、#5（两个流程类分叉）、#7（用 `dependencied` 只做删除保护）；语言特性见 #3（`while-let` 在非 `Option` 上恒真，`typecast.md:92-133`）、#8（`ConcurrentHashMap` 索引运算符抛异常，`collection_concurrent_class.md:1835-1846`）、#1（`LinkedBlockingQueue.remove` 阻塞，`collection_concurrent_class.md:561-567`）；可读性见 #9、#10、#11；安全性 0 条——本部分不处理外部输入、无 SQL/命令/路径拼接、无凭据与敏感数据 |
| §1 死代码 | 0 | 已逐符号机械检查：`private` 的 `ImmediateDispatcher.doRegister(name:executor:)`（4 处调用）、`doRegister(executor:)`（2 处）、`end`、`executors`、`eventQueue`、`startEventNames`、`ImmediateFlow.h`/`startName`/`hasFirstTask`、`JitHostRegistry.EVENT/EMITTER/BASE_FLOW/IMMEDIATE_FLOW/ASYNC_FLOW`/`eventDescriptor`/`eventToStringMethod`/`flowMethods`/`flowMethod`/`flowArg`/`stringArg`/`taskArg`、`FlowEventFactory.init` 全部有引用；`internal` 的 `multiEventTaskBody`（`Flow.cj:68`、`ImmediateFlow.cj:112`、`AsyncFlow.cj:136`）、`JitHostRegistry.registerEventFields`/`eventFields`/`eventDescriptors`/`emitterDescriptor`/`baseFlowDescriptor`/`immediateFlowDescriptor`/`asyncFlowDescriptor`（`configure` + `JitHostRegistry_test`）、`ImmediateDispatcher.getEvent`/`getExecutors`（`AsyncDispatcher.cj:149-164`）均有引用；`protected` 的 `doStartEventName`/`doRegisterMulti` 是 `Dispatcher` 抽象成员的实现（调用方是 `Dispatcher` 的 `internal` 转发），非死代码；`public` 声明经 `egraph.cj:23` 的 `public import` 对外可达，按硬原则一不判（`EndExecutorGetter`、`Executor.accept` 默认实现属接口契约），`EmptyEvent` 仓内只在 `QueuedClosureTask` 的 `is` 判断与测试中出现，记「对外 API，仓内无构造点」不作死代码；逐个检查 `return`/`throw`/`continue` 之后无同层语句（`dispatch` 的 `continue` 与 `return` 均为分支末句），无 `if(false)`，`import` 全部用到（`ImmediateDispatcher` 无 import，`Event.cj` 的 `std.time.DateTime` 用于 `birth`，`FlowQueueIntegration_test` 的 `std.unittest.*` 用于 `@Test`） |
| §2 重复逻辑 | 3 | 已把本部分 15 个非测试 `.cj` 的函数体压成「输入→输出→副作用」两两比对：命中 #5（`ImmediateFlow` ↔ `AsyncFlow` 六组同形函数，附三处已发生的漂移）、#9（`registerEventFields` 四段）、#10（`emit` 重复声明）；判为**不**重复的：`ImmediateDispatcher.doRegister` 两版（一版查重一版追加）、`ErrorEvent` 两个构造器（载荷类型不同）、8 个事件子类构造器（各自固定 `eventType`/`name`，差异是业务要求）、`JitHostRegistry.flowMethods` 7 项（目标方法不同，已用 `flowMethod` 共因子消除）、测试里的 `TestCounter`/`RecordingAccepter`/`StepCounter`（测试准备代码，误报边界） |
| §3 空实现 | 0 | 本部分无空函数体、无 `TODO`/`FIXME`、无 `catch {}`：`ImmediateExecutor.execute` 是抽象成员（`26`），`ErrorExecutor.execute` 必抛异常，`JitHostRegistry` 描述符里的 `setter: { _, _ => () }`（`63,72,81,90`）是只读字段的 Null-Object 写法且与 `mutable: false`（`55` 等）及 `HostFieldTable` 的 `mutable` 校验呼应，属有意为空的正确用法；`FlowEventFactory.flowDataOf` 的「非 `String` 返回空串」有注释（`48`）说明 |
| §4 栈溢出 | 1 | #7：`registerTaskByFlow` 的子流程同步嵌套无环检测、无深度上限，深度上界 = 流程图深度（宿主可控），自引用/互引用即 `StackOverflow`。其余无递归：`multiEventTaskBody`（`Flow.cj:48-60`）是迭代，`dispatch` 的循环是迭代，`ImmediateFlow.canBeRemoved` 只遍历 `String` 集合 |
| §5 OOM | 2 | #6（`eventQueue` 容量 `Int64.Max`、`emit` 只入队、End 提前返回留残留）、#4（进程级 `HostFieldTable` 每次 `configure` 净增 4 个访问器，永不回收）；另核对过 `ImmediateFlow.dispatchers` / `dependencied_` / `startEventNames`：键都是 `(category, tag)`，有界于流程注册数，且 `remove()` 会清 `dispatchers`（`44-47`），**不构成无界泄漏**，只列待验证假设 #4 观察是否随滚动发布换 tag 增长 |
| §6.1 热点瓶颈 | 0 | 未提供 profile / bench 数据（`scope.md` 的「已有性能资料」只给了 `docs/LocalMode*.md`，与本部分无关），任何「热点」结论都不成立；事件路由、UUID session、`HostFieldTable.find` 的自耗时已列入「待验证假设」#1-#3，不进发现 |
| §6.2 大粒度锁 | 0 | 本部分**没有锁**：`ImmediateDispatcher` 无 `Mutex`（问题在「完全没有同步」而非「锁太大」，已作 #2 报严重）；`ImmediateFlow` 只用 `ConcurrentHashMap`/`ConcurrentHashSet`，无临界区、无锁内 I/O。`removeIf` 谓词里构造对象（`ImmediateFlow.cj:52`）不持锁，不构成大粒度锁 |
| §6.3 并发串行 | 0 | 本部分无 `spawn`、无 `Future.get()`、无批大小配置，不存在「形式并发实际串行」形态。相关的反向问题（无界并发 / 无会话隔离）已在 #2 按正确性报 |
| §6.4 低效算法 | 1 | #4 的 `HostFieldTable.find` 桶内线性扫描（随 `configure` 次数增长）+ #4 的 `register` 整表复制（每次 `configure` 复制全部桶，O(表大小)）；`ImmediateFlow.canBeRemoved` 的字符串拼接只在异常路径（排除）；`dispatch` 的 `HashMap<Event>` 查找是 O(1)，不报 |
| §7 降堆内存方案 | 1 | 「事件 `session` 默认 UUID」（证据状态：无基线，待验证） |
| §8 降 CPU 方案 | 1 | 「`EventType.hashCode` 预计算」（证据状态：无基线，待验证） |
| §9 local mode 可行性 | 0 | 本部分的临时对象全部逃逸：`Event`（含 `DataEvent.data`）被放进 `eventQueue`、交给执行器、作为 `dispatch` 返回值传出；`MultiEvent` 的 `Iterable<Event>` 被下游流程持有；`HostFieldAccessor` 的闭包进进程级静态表。没有「函数内创建、函数内销毁且不逃逸」的大对象，故判不可行；另需 `--experimental --enable-local-mode`、`String`/`Array` 需 mode 重载版本，且收益只能靠峰值内存对照证明（本模块无任何峰值基线） |
| §11 现有代码的 BUG（存量） | 11 | 本轮读到的 15 个非测试文件、5 个测试文件的边界与空值已逐个核对（`Event` 的 4 字段相等性、`priority`/`cancelPrev` 负数、`doRegister` 重复注册、`dispatch` 的空队列守卫、`ImmediateFlow.startName` 空串、`remove` 后 start/emit、`JitHostRegistry` 的描述符索引、`FlowEventFactory.flowDataOf` 的 3 个分支）；命中的 11 条即 #1-#11，全部标「存量（快照模式无基线）」 |
| §12 并发安全与锁粒度 | 1 | 逐条列出共享点与同步手段：`ImmediateFlow.dispatchers`（`ConcurrentHashMap`，安全）→ 其 value `ImmediateDispatcher`（**内部全部无同步**：`executors` 普通 `HashMap`+`ArrayList`、`end` 普通 `var`、`startEventNames` 普通嵌套 `HashMap`）→ 这是 #2 的共享路径；`ImmediateFlow.dependencied_`/`AsyncFlow` 侧属第 2 部分；`ImmediateExecutor.acceptingEvent` 不可变（安全）；`DummyEvent.instance` 静态单例只读（安全）。锁粒度结论：不是「锁太大」，而是「该有的同步完全没有」，修法见 #2 |
| §14 功能完备性与 README 覆盖 | 2 | #3（`Event` 承诺的优先级/撤销语义只在 `QueuedClosureTask` 实现，`ImmediateDispatcher` 忽略）、#7（子流程环检测缺失，属「能力接了一半」）；README 覆盖归第 1 部分（本部分无 `.md`），本部分只核对接口注释，另记一句范围外提示：`README.md:441-472` 手抄的 `Dispatcher` 声明用 `name:`，实现是 `eventName:`，该漂移已由第 1 部分首条覆盖，此处不重复计 |
| 文件覆盖（§13 等） | 20/20 | 无缺失文件；`files/f_egraph.part3.txt` 的 20 行全部在「文件覆盖」表中出现且已读。本部分无 `.md`，§13 文档一致性不适用（模块文档由第 1/2 部分覆盖） |

## 模块统计

| 严重程度 | 数量 |
| --- | --- |
| 严重 | 2 |
| 一般 | 5 |
| 轻微 | 4 |
| 优化方案（堆内存 / CPU） | 1 / 1 |

## 总评

本部分是「事件原语 + 同步派发器 + JIT 手工注册面」，代码量不大（15 个非测试文件约 900 行），图算法本身没有复杂度问题（路由就是一次 `HashMap<Event>` 查表，`Event` 的哈希在构造期预计算），真正的风险集中在**同步派发器的生命周期契约**：

- `ImmediateDispatcher` 把「一次 `start` 的上下文」实现成了实例上的三个字段（`eventQueue` / `end` / `executors`），而实例又被 `ImmediateFlow` 的静态表按 `(category, tag)` 全局共享。于是同一个流程的并发启动必然互相串流，`start()` 返回的 getter 也不是 per-start 句柄。这是 #2，也是本部分最该先修的一条。
- `dispatch()` 的终止条件只有 `EndExecutor`，而队列耗尽时 `remove()` 是阻塞调用，于是「合法地不注册 End」直接变成调用线程挂死（#1）。#1 与 #2 是同一条循环的两个方向：出口太窄、状态太共享。
- 事件层的 `priority` / `cancelPrev` / `EmptyEvent` 承诺（`Event.cj` 自己的公开注释）只有 `QueuedClosureTask` 兑现，普通 `Task` 路径下静默失效甚至抛异常（#3）；这是「注释比实现跑得快」的典型，和本模块第 1/2 部分报出的文档漂移是同一个根。

阻塞项：#1（`start` 挂死）与 #2（会话串流 / 数据竞争）——两者都会在真实服务端流量下表现为「请求永不返回」或「拿到别人的结果」，建议一并修复后再评估同步流程的可用性。#3、#6 属契约与容量问题，应和 #1/#2 同批处理（`eventQueue` 的背压与残留清理依赖会话隔离的设计）。#4、#5、#7 可以排期：#5 的重复实现是维护成本（且已经漂移出三处差异），#7 是宿主写错流程图的兜底，#4 的收益取决于 `f_llm` 侧 `configure` 的调用频次（范围外）。4 条轻微问题修起来很便宜，其中 #11 的无效断言会掩盖 `QueuedClosureTask` 抢占语义的覆盖缺口。

正面之处：`Event`/`EventType` 的值语义与相等性实现得很干净（哈希预计算、`==` 与 `hashCode` 字段集一致、`DataEvent.tryGet` 用 `as` 返回 `Option` 而不是抛异常）；`ErrorExecutor` 的三分支 + `Executor_test` 的空值用例覆盖到位；`JitHostRegistry` 用「描述符工厂 + 统一 `match` 解包 + 绑定名全局唯一」把手工注册面组织得很好，并有 `JitHostRegistry_test` 的金线断言（父链、字段索引、方法集合、`registeredNames`）兜住回归。测试的主要缺口是**并发与终止条件**：`ImmediateDispatcher_test` 7 个用例里没有一条并发启动、也没有一条「队列耗尽」的用例，`FlowQueueIntegration_test` 的优先级用例断言恒真——这正是 #1/#2 能长期存活的原因。

存量缺陷共 11 条（严重 2 / 一般 5 / 轻微 4），是否纳入修复清单待用户决定；本部分不替用户拍板，也未改动任何源码。
