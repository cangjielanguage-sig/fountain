# fountain实现思想与应用第十七弹

##### ——事件驱动流程引擎

项目链接：https://gitcode.com/Cangjie-TPC/fountain

先澄清一个容易被名字带偏的前提：**`f_egraph` 里的 `egraph` 是 event graph（事件图），不是编译原理里的 e-graph**。模块里没有等价类、没有重写规则，也没有节点/边数据结构；那些属于 `f_rule` 的 Rete 网络。这里是「把业务流程拆成一串事件，由执行器接力处理」的执行器。

它要解决的问题是：

> 一段业务逻辑，能不能不写成一坨 `if/else` 和一个大函数，而是拆成可注册、可替换、可异步执行的「任务」，由统一的事件循环串起来？

f_egraph 给出的模型只有五个角色：

| 角色 | 职责 |
| --- | --- |
| `Event` | 在流程里流动的数据信封：类型 + `category` + `tag` + `name` + 载荷 |
| `Executor` | 认领**一种**事件并处理它 |
| `Dispatcher` | 维护「事件 → 执行器」注册表，跑事件循环 |
| `Task` | 真正的业务逻辑：吃一个事件，产出一个事件 |
| `Flow` | 注册任务的容器，对上暴露 `start()`，对下暴露 `emit()` |

```
start(data)
   │
   ▼
StartEvent ──▶ StartExecutor ──▶ TaskEvent(同名) ──▶ TaskExecutor
                                                        │
                                              task.exec(event) 产出结果事件
                                                        │
                                                        ▼
                                             … 若干任务接力 … ──▶ EndEvent
                                                                     │
                                                              EndExecutor 保存
                                                                     │
                                                              start() 取回结果
```

---

## 一、事件：身份只有四个字段

```cj
public open class Event {
    public let eventType: EventType
    public let category: String
    public let tag: String
    public let name: String
    public let session: String = UUID.random().toHexString()
    public let priority: Int64 = 2
    public let birth: DateTime = DateTime.now()
    public let cancelPrev: Int64 = 0
}
```

事件的相等性**只看 `eventType + category + tag + name`**，`session`、`data`、`priority`、`birth`、`cancelPrev` 都不参与。这不是偷懒，而是让注册表的 `HashMap<Event, ArrayList<Executor>>` 能用「带优先级的实事件」查到「注册时的模板事件」——如果 `priority` 参与相等，注册永远命中不了。

`priority` / `cancelPrev` 会被校验为非负；`session` 默认随机，用来区分同一条流程的多次执行。

### 事件家族

| 类型 | 用途 |
| --- | --- |
| `StartEvent` | 流程入口，带 `data` |
| `TaskEvent` | 任务输入/输出，`data` 是任务载荷 |
| `EndEvent` | 流程结束，携带最终结果，`name` 固定为 `"End"` |
| `ErrorEvent` | 错误出口，`name` 固定为 `"Error"` |
| `MultiEvent` | 一次携带多个事件的扇出容器 |
| `DummyEvent` | 单例「什么都不做」，调度器直接跳过 |
| `EmptyEvent` | **取消指令**，不是数据事件 |

`EmptyEvent` 值得单独说：当它的 `cancelPrev > 0` 时，调度器会删掉队列里前面 N 条**同名同优先级**的事件（构造时把 `name` 设成目标事件名），自己也不执行。它存在的意义是「撤销还没跑的旧请求」——比如用户连续改了三次配置，前两次的更新任务还没执行，就可以用一条 `EmptyEvent` 把它们抹掉。

`DataEvent` 在 `Event` 之上加了 `data: Any` 和 `tryGet<T>()`，所有带载荷的事件都继承它。

---

## 二、执行器：各认一种事件

```cj
public interface Executor <: Accepter {
    prop acceptable: Event
    func execute(event: Event)
    func accept(event: Event) { execute(event) }
}
```

`ImmediateExecutor.accept` 会先做一次相等性校验：收到的事件与 `acceptable` 不完全一致就抛 `GraphException`。这条校验把「注册错了」变成启动/首跑就暴露的错误，而不是运行到一半发现某个任务永远不被触发。

五种内置执行器的分工很窄：

| 执行器 | 做什么 |
| --- | --- |
| `StartExecutor` | 把 `StartEvent` 转成**同名** `TaskEvent`，交给下游 |
| `TaskExecutor` | 调 `task.exec(event)`，把结果事件交回 `accepter`（也就是 dispatcher） |
| `AsyncTaskExecutor` | 同上，但用 `spawn` 异步执行 |
| `EndExecutor` | 保存结束事件，供 `start()` 取回 |
| `ErrorExecutor` | 把错误载荷原样抛成 `GraphException`，不吞、不重试 |

`EndExecutor` 只负责「存」：`get()` 在还没收到结束事件时抛异常。框架**不强制**注册 End——代价是没注册 End 的流程，`start()` 会一直阻塞在队列上（见下一节）。

---

## 三、调度：单线程队列，还是每派发一线程

### ImmediateDispatcher：同步、单线程、无界

```cj
private let executors = HashMap<Event, ArrayList<Executor>>()
private let eventQueue = LinkedBlockingQueue<Event>()

protected func dispatch(): Unit {
    if (eventQueue.size == 0) { throw GraphException(...) }
    while (let event <- getEvent()) {          // getEvent() = eventQueue.remove()，空队列阻塞
        if (event is DummyEvent) { continue }
        else if (let Some(executors) <- getExecutors(event)) { /* 依次 accept */ }
        else { throw GraphException("No executor found for event: ${event}") }
    }
}
```

三个行为必须记住：

1. **命中 `EndExecutor` 时 `dispatch()` 立即 return**，但**不清空队列**。上一个流程残留的事件会被下一次 `start()` 消费——这是「一次性消费」模型的已知代价。
2. **队列没有容量上限**。`accept` 直接 `add`，没有背压；生产速度快于消费速度时，内存会替你做决定。
3. **没有执行器就抛错**。同步路径不做「没注册就跳过」的宽容处理。

### AsyncDispatcher：每个派发一线程

`AsyncDispatcher` 内部包一个 `ImmediateDispatcher`，但线程模型完全不同：

- 每次 `dispatch()` 调用 `spawn` 一个循环线程；
- `asyncExecute` 再为每个执行器 `spawn` 一个线程；
- 结束事件按**线程 id** 关联（`ConcurrentHashMap<Int64, WeakRef<EndExecutor>>`），`tryGet(timeout)` 通过条件变量等待；
- 构造函数还会 `spawn` 一个清理失效 `WeakRef` 的线程，`sleep(clearTimerDuration)` 循环，**没有终止条件**。

这些循环都没有 `break`，只有抛异常才退出。所以「每次 `AsyncFlow.start()` 都会新增一个长期阻塞在队列上的线程」——不是线程池，也不是协程调度器。

`AsyncDispatcher` 还有一个刻意的顺序问题：`asyncExecute` **先** `notifyEnd(tid, executor)` **再** `executor.accept(event)`。被唤醒的一方拿到的 `EndExecutor` 可能还没写入事件，`get()` 会抛。这是「先通知、后完成」的窗口，文档里不能把它说成严格同步。

---

## 四、Flow：注册校验比执行更严格

`Flow<G>` 的注册入口集中在 `registerStart`、`registerEnd`、`registerError`、`registerTask`（另有 `registerTaskByFlow` 用于挂子流程）。注册期有三条硬校验：

1. 还没有 Start 就注册 Task → `'There must be with StartExecutor before registering first TaskExecutor'`；
2. 首个 Task 的事件名与 Start 名不同 → `'First TaskExecutor name must be same as StartExecutor name'`；
3. 同一事件重复注册 → `'... has already been registered'`。

第三条保证了 `HashMap` 查找的确定性，也意味着**事件身份就是流程里的唯一地址**。

`Flow` 还有一组生命周期 API：`canBeRemoved()`、`remove()`、`removeExceptCurrentTag()`。删除不是无条件的：被依赖的流程会抛 `... is dependencied by ...`，依赖关系在 `registerTaskByFlow` 时登记。

### 同步与异步的语义不对称

```cj
// ImmediateFlow：按需创建 dispatcher
public func getDispatcher(): ImmediateDispatcher { /* 不存在则创建 */ }

// AsyncFlow：未初始化直接抛
public func getDispatcher(): AsyncDispatcher { return dispatcher.getOrThrow() }
```

`ImmediateFlow.start(data)` 会**同步阻塞到结束事件**，返回 `EndExecutorGetter`；`AsyncFlow.start(data)` 立即返回 `AsyncEndExecutorGetter`，调用方通常用 `tryGet(timeout!)` 自己兜底，避免无限等待。两个类的 `getDispatcher` 只是名字相同，行为并不对称。

`AsyncFlow` 的 dispatcher 是**静态单例**（`private static var dispatcher`），同进程内所有异步流程共享一个派发器；`ImmediateFlow` 则是静态表 `ConcurrentHashMap<ImmediateFlow, ImmediateDispatcher>`，每个流程一个派发器。

生命周期上，两者都只有 `start` 与移除，**没有 `stop` / `await` / `close`**。`AsyncFlow` 启动的线程与清理线程不会因为流程移除而回收。

---

## 五、任务：闭包、优先级队列、弱同步栅栏

### Task 与 ClosureTask

```cj
@JitBind
public interface Task {
    prop name: String
    prop acceptableEvents: ArrayList<String>
    prop producingEvents: ArrayList<String>
    func exec(event: Event): Event
}
```

`Task` 是无状态接口。`ClosureTask` 是它的通用实现：既可以包一个宿主闭包，也可以用 `compile(script)` 把 f_jit 脚本编译成任务体。构造器会校验 `name` 非空、两个事件列表非空且元素为 `String`、`exec` 非空；`compile` 还会再校验一次事件列表。

`ClosureTask` 是 `public open class`——这是 `QueuedClosureTask` 能继承它的前提。

### QueuedClosureTask：三级优先级 + 协作式取消

它把「任务」变成了「队列 + 版本号 + 取消令牌」，排序键是 `(priority, birth, 入队 sequence)`：

| `priority` | 语义 |
| --- | --- |
| `0` | 提交线程立即执行；同名事件正在跑时打 `cancelled` 标记，外层结果丢弃 |
| `1` | 同优先级 + 同名事件合并成一批；单条直接执行，多条包成 `MultiEvent` |
| `>= 2` | 逐条执行 |

`cancelPrev > 0` 会丢掉队列尾部 N 条同优先级事件；`EmptyEvent` 则丢同名 + 同优先级的 N 条，自身不执行。

这里的「取消」是**协作式**的：仓颉没法强杀一个正在跑的闭包，`priority=0` 只能打标并丢弃结果；任务体要提前退出，得自己轮询 `generation`。队列基于 `SyncPriorityQueue`，容量未指定（0 视为无限）——同样没有背压。可观测属性有 `pending`、`cancelledCount`、`generation`、`owner`。

### BarrierTask：名字像栅栏，实际是聚合器

```cj
public func exec(e: Event): Event {
    let key = BarrierKey(e.category, e.tag, e.name, e.session)
    let list = datas.computeIfAbsent(key) { ArrayList<Any>() }
    list.add((e as DataEvent).data)
    if (let (emitEvent, count) <- events_[e.name] && list.size >= count) {
        flow?.emit(eventType: EventType.Task, name: emitEvent, data: list)
        datas.remove(key)
    }
    DummyEvent.instance
}
```

它**不阻塞等待**：凑够阈值就 `emit` 并清空，没凑够就返回 `DummyEvent`。所以它是「N 条聚合成 1 条」的聚合器，不是让 N 个线程互相等待的栅栏。

两个实现细节需要知道：计数容器是 `ConcurrentHashMap`，但 `list.add` 与 `size >= count` 判断**没有加锁**，高并发下可能多发或漏发；`flow` 只有在 `Flow.registerTask(task: BarrierTask<G>)` 时才会被注入，直接 `new` 出来的实例 `flow?.emit` 会静默不发射。

---

## 六、脚本：启动时把流程编译进进程

`FlowInitializer` 是模块的 `Initializer`：

```cj
public func initialize(): Unit {
    let compiler = Compiler(CompileOptions(DummyDiagnosticsSink()))
    JitHostRegistry.configure(compiler)
    ClosureTask.initCompiler(compiler)
    for (script in lookup<FlowLoader>().load()) {
        FlowScriptRunner.run(compiler, script)
    }
}
```

它依赖 `fountain::f_bean`，名称固定 `fountain::f_egraph`。`FlowLoader.load()` 返回的是「每个元素一段流程语句」，读文件、读配置、读数据库都由宿主实现——模块本身**不做任何文件 IO 与格式校验**。

`FlowScriptRunner.run` 的规则只有两条：

- 空白脚本 → `GraphException("flow script must not be blank")`，不静默跳过；
- 脚本外面包一层 `{ => ... }` 编译执行，**不追加 `()` 哨兵**，所以最后一条表达式必须能赋给 `Unit`。

脚本语言就是 f_jit 的表达式语言，没有自定义操作符。宿主暴露的能力是白名单：

| 脚本可用 | 说明 |
| --- | --- |
| `ImmediateFlow(category, tag)` / `AsyncFlow(...)` | 构造流程 |
| 7 个流程方法 | `canBeRemoved` / `remove` / `removeExceptCurrentTag` / `registerStart` / `registerEnd` / `registerError` / `registerTask` |
| 5 个事件工厂 | `flowTaskEvent` / `flowEndEvent` / `flowErrorEvent` / `flowDummyEvent` / `flowDataOf` |
| 静态名 `compile(script)` | 生成 `ClosureTask` |

事件字段只登记了 `category`、`tag`、`name`、`session` 四个访问器，**`data` 不登记**。所以脚本里读 `e.data` 会在编译期报「未注册字段」。

### 脚本的不可用清单

这些不是运行期才发现的坑，而是编译期就报错：

- `flow.emit()`：未注册方法；
- `flow.registerTask("created", t)` 闭包重载：只保留了 `Task` 重载；
- `e.data`：未注册字段；
- `e as TaskEvent` / `e is TaskEvent`：缺少转型判定函数；
- `DummyEvent.instance`、`initCompiler`、`initDispatcher`：不在脚本静态名空间；
- `EmptyEvent`：**没有注册**，脚本无法构造取消指令。

手工注册的类型也不应再标 `@JitBind`：两边都登记会造成同一类型重复绑定，测试里对这一点有逐类型断言。

---

## 七、与其它模块的边界

- `f_app`：`FlowInitializer` 接在 `InitializerCollection` 的拓扑排序里，`start()` 用默认空实现。
- `f_jit`：脚本编译与宿主绑定都靠它；`Task`/`ClosureTask`/`FlowEventFactory` 标了 `@JitBind`，且必须文件级 import `fountain::f_jit.macros.*`。
- `f_rule`：`RuleInitializer.dependencies` 里写着 `fountain::f_egraph`，即规则引擎依赖本模块先初始化。
- `f_ticktock` / `f_rx`：**不是依赖**。定时与响应式都不在这个模块里，别在 `cjpm.toml` 之外的地方找它们。
- `f_data`：声明了依赖但源码未使用（`base/imports.cj` 里没有 `f_data`）。

根包 `fountain::f_egraph` 只重导出 `base.*` 与 `loader.*`；`GraphException` 在 `fountain::f_egraph.exception`，需要单独 import。

---

## 八、参数与默认值

模块没有环境变量，也没有配置项。可调参数都在构造函数上：

| 参数 | 默认 | 说明 |
| --- | --- | --- |
| `Event.priority` | 2 | 负数抛 `GraphException` |
| `Event.birth` | `DateTime.now()` | 排序用 |
| `Event.cancelPrev` | 0 | 负数抛错 |
| `Event.session` | 随机 UUID hex | 区分同一流程的不同执行 |
| `EmptyEvent.name` / `priority` / `cancelPrev` | `"EmptyEvent"` / 2 / 0 | 取消指令 |
| `AsyncDispatcher(clearTimerDuration, toThrowIfNoExecutor)` | 1s / true | 清理周期、无执行器时抛还是 warn |
| `BarrierTask` 阈值 | 构造时给定 | 按事件名映射到聚合阈值 |

---

## 九、设计取舍与已知限制

1. **不是 e-graph**。没有等价类与重写；`egraph` 指 event graph。找图算法请去 `f_rule`。
2. **事件身份只有四字段**。`data`/`priority`/`session` 不参与相等，这是注册表能命中的前提，也意味着「同名事件」在流程里只能有一个执行器。
3. **同步派发无背压**。`LinkedBlockingQueue` 未设容量，生产快于消费时内存兜底。
4. **残留事件会串场**。`dispatch()` 命中 End 就返回且不清队列，下一次 `start()` 可能先消费上一次的残留。
5. **异步派发不是线程池**。每次 `start()` 新增常驻线程，清理线程也没有终止条件；高频创建流程会持续吃线程。
6. **先通知后完成**。`AsyncDispatcher` 的 `notifyEnd` 早于 `accept`，`tryGet` 拿到 `EndExecutor` 后仍可能读不到事件。
7. **取消是协作式的**。`priority=0` 只能打标丢结果，闭包内部不轮询 `generation` 就停不下来。
8. **BarrierTask 是弱同步**。计数判断无锁，高并发可能多发/漏发；不注入 `flow` 时静默不发射。
9. **没有 stop/close**。流程移除不回收线程与队列资源；长生命周期进程需要自己控制流程数量。
10. **脚本能力是白名单**。`emit`、`data`、`is/as`、`EmptyEvent` 都不可用——这不是 bug，是 JIT 绑定面刻意收窄的结果。
11. **FlowLoader 不做 IO**。读文件、校验格式是宿主的事；模块只接受「一段能编译的流程源码」。
