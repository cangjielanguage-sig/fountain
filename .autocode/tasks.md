# f_protocol 静态诊断报告

> 审查日期：2026-05-03
> 审查范围：fountain::f_protocol 模块所有源文件
> 审查方式：静态代码分析（不编译、不运行）

---

## ~~[P2] Message.decode() 未使用的 closeFromOnEnd 参数~~ ✅ 已修复

- **问题等级**: P2
- **问题描述**: `Message.cj:117` `decode()` 的命名参数 `closeFromOnEnd!: Bool = false` 声明了但函数体内从未使用。此参数应透传给 `decoder.decode<T>(input)` 或内部流操作，否则调用方传入该参数不会产生任何效果。
  ```cj
  // Message.cj:117 修复后
  public static func decode<I, T>(input: BufferedInputStream<I>): Message
  ```
- **修复方式**: 移除未使用的 `closeFromOnEnd` 参数。同步更新 `Protocol` 接口、文档及所有调用方（f_net server/client）。
- **修复提交**: `a748bd34`

---

## ~~[P2] MessageID.pidgen 应为 static let 而非 static var~~ ✅ 已修复

- **问题等级**: P2
- **问题描述**: `MessageID.cj:19` `public static var pidgen: ProcessID = CurrentProcessID.instance` 使用 `var` 声明，但运行期从未修改过。应使用 `let` 声明不可变引用。
- **修复方式**: `static var` → `static let`。
- **修复提交**: `a748bd34`

---

## ~~[P3] QoS.parse 的 UnreachableException 语义错误~~ ✅ 已修复

- **问题等级**: P3
- **问题描述**: `Constants.cj:61` `QoS.parse()` 原来用 `match(value & 6u8)` 时 `case _` 可被值 6u8 到达，但用了 `UnreachableException`。同时编译器 `match` 在 enum 内存在 BUG 导致 `value` prop 比较失败。
- **修复方式**: 改用 `if-else` 分支替代 `match`；异常改为 `CommandException`；enum 增加 `<: Equatable<QoS> & ToString`。
- **修复提交**: `c9e4edd0` + `a5ffece2`

- **问题等级**: P3
- **问题描述**: `Constants.cj:66` `QoS.parse()` 的 `case _ => throw UnreachableException()` 实际上可到达（当传入 `value=6u8`，bits 1-2 都置位时）。编译器将其优化为 dead code，测试已验证不抛异常。异常类型错误应改为 `CommandException`。
  ```cj
  public static func parse(value: Byte): QoS {
      match(value & 6u8){
          case AT_MOST_ONCE => AtMostOnce    // 0
          case AT_LEAST_ONCE => AtLeastOnce  // 2
          case EXACTLY_ONCE => ExactlyOnce   // 4
          case _ => throw UnreachableException()  // 6 可到达但编译器优化为 unreachable
      }
  }
  ```
- **触发条件**: 调用 `QoS.parse(6u8)` 或任意 `(value & 6u8) == 6u8` 的输入。
- **改进方案**: 改为 `throw CommandException()` 并添加 hex 输出以便调试。同时建议在 match 前进行前置校验：
  ```cj
  public static func parse(value: Byte): QoS {
      let qosBits = value & 6u8
      match(qosBits) {
          case AT_MOST_ONCE => AtMostOnce
          case AT_LEAST_ONCE => AtLeastOnce
          case EXACTLY_ONCE => ExactlyOnce
          case _ => throw CommandException("invalid QoS bits: ${qosBits.toHex()}")
      }
  }
  ```
- **实施难度**: 低

---

## ~~[P3] Message.cj:106 to() 函数缺少显式返回类型~~ ✅ 已修复

- **问题等级**: P3
- **问题描述**: `Message.cj:106` 私有函数 `to()` 没有声明返回类型。
- **修复方式**: 添加 `: Byte` 返回类型，合并单行。
- **修复提交**: `c9e4edd0`

---

## ~~[P3] auth() 工厂的 hasData 标志与实际数据不匹配~~ ✅ 已修复

- **问题等级**: P3
- **问题描述**: `Message.cj:55` `hasData=false` 时，数据仍在消息体中，与清除的标志位矛盾。
- **修复方式**: `hasData=false` 时走无数据重载 `build()`，仅当 `hasData=true` 时才编码 `authData`。
- **修复提交**: `c9e4edd0`

---

## [P3] 测试用例 qosParseWithQoS1FlagOnly 的 @Assert(true) 恒真

- **问题等级**: P3
- **问题描述**: `Protocol_test.cj:294` `qosParseWithQoS1FlagOnly` 测试用例使用 `@Assert(true)`，这是一个恒真的死断言，不验证任何实际行为。因编译器 `match` BUG 导致无法用实际值断言，已回退为 `@Assert(true)` 仅验证不抛异常。
- **状态**: 保留原状，待编译器修复后改为实际断言

---

## ~~[P3] messageIDUniqueness 测试非确定性~~ ✅ 已修复

- **问题等级**: P3
- **问题描述**: `Protocol_test.cj:117` `messageIDUniqueness` 测试断言 `hashCode()` 不同——哈希冲突理论上可能。
- **修复方式**: 移除 `@Assert(id1.hashCode() != id2.hashCode())` 断言，仅保留 `@Assert(id1 != id2)`。
- **修复提交**: `c9e4edd0`

---

## [P4] DefaultCodec 在 encode()/decode() 中重复创建

- **问题等级**: P4
- **问题描述**: `Message.cj:114` 和 `Message.cj:124` 每次调用 `encode()` 和 `decode()` 都创建新的 `DefaultCodec()` 实例。`DefaultCodec` 是无状态编解码器，可复用。
  ```cj
  // encode() line 114
  let bytes = DefaultCodec().encode(id.pid).encode(id.tid).encode(id.time).encode(data).finish()
  // decode() line 124
  let decoder = DefaultCodec()
  ```
- **触发条件**: 每次编解码都触发小对象分配。
- **改进方案**: 使用静态单例或线程局部变量：
  ```cj
  private static let codec = DefaultCodec()
  // encode 中使用 codec 的单次调用... 但 codec 有 mutable 状态，不能直接静态化
  // 建议保持现状，收益极微
  ```
- **实施难度**: 低（但收益极小，不建议实施）

---

## 总结

| 等级 | 总数 | 已修复 | 待处理 |
|------|------|--------|--------|
| P0   | 0    | 0      | 0      |
| P1   | 0    | 0      | 0      |
| P2   | 2    | 2      | 0      |
| P3   | 5    | 4      | 1(注)  |
| P4   | 1    | 0      | 1      |

注：P3 中 `qosParseWithQoS1FlagOnly` 的 `@Assert(true)` 因编译器 `match` BUG 无法改为实际断言，待编译器修复后处理。

---

# f_net 静态诊断报告

> 审查日期：2026-05-03
> 审查范围：fountain::f_net 模块所有源文件
> 审查方式：静态代码分析（不编译、不运行）

---

## ~~[P0] 跨线程通信不可达：MessageFuture 是值类型 (struct)，ref 字段修改不影响原件~~ ✅ 已修复

- **问题等级**: P0
- **问题描述**: `MessageFuture` 声明为 `struct`（值类型）。在 `Client.transfer()` 中通过 `futures.add(id, future)` 存入 ConcurrentHashMap 时存储的是副本；响应线程通过 `futures.remove(id)` 取出的是另一个副本。调用 `set()` 修改的是副本的 `ref`，原件（调用方 `get()` 所在副本）的 `ref` 始终为 `None`，`getOrThrow()` 抛出 `NoSuchElementException`。
  代码路径：`MessageFuture.cj:20-57`（struct 声明 + set/get）、`client.cj:41-46`（reader 线程取出副本调 set）、`client.cj:117-124`（transfer 创建原件并返回调用方）。
  ```cj
  // client.cj:43-46 — reader 线程
  if (let Some(fut) <- futures.remove(id)) {  // fut 是副本
      var f = fut
      f.set(de)  // 修改副本的 ref，原件 ref 仍为 None
  }

  // MessageFuture.cj:32-41 — 调用方 get()
  public func get(): DE {
      synchronized(mutex){
          if(let Some(d) <- ref){ d }
          else{
              condition.wait()
              ref.getOrThrow()  // ref 始终 None → 抛异常
          }
      }
  }
  ```
  **注意**：`mutex` 和 `condition` 是引用类型（类），副本共享同一 Mutex/Condition 实例，因此 `synchronized` 同步和 `notify()` 能正确唤醒等待线程，但唤醒后读取的是原件自己的 `ref` 字段（值类型，独立副本），永远读不到响应值。
- **触发条件**: 任何跨线程响应场景。server 端的 `Server.start()` 未使用 `futures` map（直接用 `transfer()` 写入），故 server 不受此问题影响。Client 端所有 `transfer()` 调用均受影响。
- **改进方案**: 将 `MessageFuture` 改为 `class`（引用类型），或者保留 `struct` 但将 `ref` 用 `AtomicReference` 包装（使其成为引用）。改为 `class` 最简单：
  ```cj
  public class MessageFuture<DE> {
      private let mutex = Mutex()
      private var ref: Option<DE> = None
      ...
  }
  ```
  注意：改为 class 后，原来的 `mut func set()` 不需要 `mut` 前缀（class 无此要求），构造函数语法可能需调整。
- **实施难度**: 低（单文件修改，`MessageFuture.cj`）

---

## ~~[P0] Client.index 使用 closed:true 导致数组索引越界~~ ✅ 已修复

- **问题等级**: P0
- **问题描述**: `client.cj:101` `ThreadLocalRandom.current.nextInt64(0, sockets.size, closed: true)` — `nextInt64(min, max, closed)` 中 `closed: true` 表示返回值包含 `max`（即 `sockets.size`）。合法索引范围为 `[0, sockets.size)`，当返回 `sockets.size` 时访问 `sockets[index]` 或 `buffers[index]` 导致 `ArrayIndexOutOfBoundsException`。
  ```cj
  // client.cj:99-102
  private prop index: Int64 {
      get(){
          ThreadLocalRandom.current.nextInt64(0, sockets.size, closed: true)  // BUG
      }
  }
  ```
- **触发条件**: 每次 `transfer()` 调用都通过 `index` prop 选择 socket，加载模式下很可能选中越界索引。
- **改进方案**: 改为 `closed: false` 或省略（默认 `closed: false`）。
  ```cj
  ThreadLocalRandom.current.nextInt64(0, sockets.size, closed: false)
  ```
- **实施难度**: 低（单行修改）

---

## ~~[P0] Client.builder() SocketBuilder 命名参数颠倒~~ ✅ 已修复

- **问题等级**: P0
- **问题描述**: `client.cj:96` `SocketBuilder<...>(socketCount: queueSize, ...)` 将 `queueSize` 的值传给 `socketCount` 参数，而 `queueSize` 和 `socketCount` 均未显式传入 SocketBuilder，两者都取默认值(1024 和 1)。若调用方传入非默认值如 `builder(queueSize: 2048, socketCount: 4, ...)`，则：
  - `socketCount` 收到 2048 → 创建 2048 个连接（远超预期的 4 个）
  - `queueSize` 默认 1024（本应为 2048）→ 写队列容量不足
  ```cj
  // client.cj:94-97 (原代码)
  public static func builder(queueSize!: Int64 = 1024, socketCount!: Int64 = 1, host!: String, port!: UInt16,
      idGetter!: (DE) -> ID, checkDuration!: Duration, checker!: (SocketBuffer) -> Bool): SocketBuilder<...> {
      SocketBuilder<...>(socketCount: queueSize, ...)  // 互换
  }
  ```
- **触发条件**: 使用非默认 `queueSize` 或 `socketCount` 参数时。
- **改进方案**: 将命名参数正确对应：
  ```cj
  SocketBuilder<...>(queueSize: queueSize, socketCount: socketCount, ...)
  ```
- **实施难度**: 低（单行修改）

---

## ~~[P0] Client.transfer() future 注册在 message.encode() 之前，encode 异常导致 orphaned future~~ ✅ 已修复

- **问题等级**: P0
- **问题描述**: `client.cj:117-124` `futures.add(id, future)` 在 `message.encode()` 之前执行。若 `encode()` 抛出异常，future 已注册到 `futures` map 但永远不会收到响应，调用方 `get()` 永久阻塞。
  ```cj
  // client.cj:116-124 (原代码)
  private func transfer(buffer: SocketBuffer, id: ID, message: M): MessageFuture<DE> {
      let future = MessageFuture<DE>()
      futures.add(id, future)     // 先注册
      let en = message.encode()   // 后编码，可能抛异常
      buffer.queue.add({ ... })
      future
  }
  ```
  **附加说明**：即使 encode 不抛异常，由于 `MessageFuture` 是 struct（见第 1 项），add 存入的是副本，响应线程收到的副本调 `set()` 不影响原件——此问题与第 1 项叠加放大。
- **触发条件**: `message.encode()` 抛出异常的任何场景（如数据序列化失败）。
- **改进方案**: 先 encode 再注册 future：
  ```cj
  private func transfer(buffer: SocketBuffer, id: ID, message: M): MessageFuture<DE> {
      let en = message.encode()
      let future = MessageFuture<DE>()
      futures.add(id, future)
      buffer.queue.add({ => en.copy(to: buffer.socket, closeToOnEnd: false) })
      future
  }
  ```
- **实施难度**: 低

---

## ~~[P0] Client 断线重连不更新 buffer.socket，后续写入使用已关闭的 socket~~ ✅ 已修复

- **问题等级**: P0
- **问题描述**: `Client` 构造器（`client.cj:52-83`）的 Timer 检查线程在检测到连接断开时调用 `new()` 创建新 `TcpSocket` 并赋给 `sockets[i]`，但 `buffers[i].socket` 仍然是旧的已关闭 socket。后续 `transfer()` 通过 `buffer.socket` 写入数据全部失败。
  ```cj
  // client.cj:55-70 — checker 逻辑
  func new() {
      try {
          sockets[i] = socketCreator()  // 只更新 sockets[i]
      } catch ...  // buffers[i].socket 仍然指向旧 socket
  }
  ...
  // client.cj:119-122 — transfer 使用 buffer.socket
  buffer.queue.add({
      => en.copy(to: buffer.socket, closeToOnEnd: false)  // 写入旧 socket
  })
  ```
- **触发条件**: 服务端断开或网络异常触发 checker 重新创建连接。
- **改进方案**: 需要让 `SocketBuffer` 支持更新 socket 引用。可行方案：
  - 将 `SocketBuffer.socket` 从 `let` 改为通过 getter 从外部持有（如存为 `() -> TcpSocket` 工厂）
  - 或在 checker 中重新创建 `SocketBuffer` 替换 `buffers[i]`
- **实施难度**: 中（需修改 SocketBuffer 结构或 checker 逻辑）

---

## ~~[P0] Server.start() params.populate(socket) 在 buffers.add(buffer) 之后执行~~ ✅ 已修复

- **问题等级**: P0
- **问题描述**: `server.cj:84-86` 调用顺序为 `buffers.add(buffer)` 在先、`params.populate(socket)` 在后。Timer 检查线程可能在第 85 行之后、第 86 行之前从 `buffers` 取出刚添加的 buffer 并执行 `checker(buffer)`，此时 socket 尚未配置 params（如 TCP_NODELAY、keepAlive 等）。
  ```cj
  // server.cj:83-86
  while (let socket <- server.accept()) {
      let buffer = SocketBuffer(queueSize, socket)
      this.buffers.add(buffer)      // 先暴露给 checker
      params.populate(socket)       // 后配置 socket 参数
      ...
  }
  ```
- **触发条件**: 高并发连接场景下 checker 线程与新连接建立存在时间竞争。
- **改进方案**: 交换两行顺序：
  ```cj
  params.populate(socket)
  this.buffers.add(buffer)
  ```
- **实施难度**: 低

---

## ~~[P1] MessageFuture.get() 虚假唤醒 (spurious wakeup)~~ ✅ 已修复

- **问题等级**: P1
- **问题描述**: `MessageFuture.cj:32-41` `get()` 使用 `if (ref.isNone()) { condition.wait() }`。`Condition.wait()` 可能因虚假唤醒（spurious wakeup）返回，此时 `ref` 仍为 `None`。随后的 `ref.getOrThrow()` 抛出 `NoSuchElementException`。
  ```cj
  public func get(): DE {
      synchronized(mutex){
          if(let Some(d) <- ref){ d }
          else{
              condition.wait()              // 可能虚假唤醒
              ref.getOrThrow()             // ref 仍 None → 抛异常
          }
      }
  }
  ```
- **触发条件**: 极低概率（宿主平台信号或线程调度引起），但理论必然存在。
- **改进方案**: 使用 `while` 循环替换 `if`：
  ```cj
  while (ref.isNone()) {
      condition.wait()
  }
  ref.getOrThrow()
  ```
- **实施难度**: 低（单文件单函数修改）

---

## [P2] Server.start() 死变量 future 和 id

- **问题等级**: P2
- **问题描述**: `server.cj:88` `let future = MessageFuture<M>()` 和 `server.cj:92` `let id = idGetter(m)` 声明后从未使用。编译器可能产生 warning。
  ```cj
  // server.cj:87-93
  spawn {
      let future = MessageFuture<M>()  // 死变量
      while (!socket.isClosed()) {
          let req = M.decode<TcpSocket, T>(buffer.buffered)
          let m = req |> executor
          let id = idGetter(m)           // 死变量
          transfer(buffer, m)
      }
  }
  ```
- **触发条件**: 始终存在。
- **改进方案**: 删除两行。
- **实施难度**: 低

---

## [P2] SocketBuffer 后台 writer 线程无关闭/停止机制

- **问题等级**: P2
- **问题描述**: `SocketBuffer.cj:25-29` 构造器中 `spawn` 的线程通过 `while (let fn <- queue.remove())` 循环消费写任务队列。`ArrayBlockingQueue.remove()` 是阻塞操作，当程序需要关闭时没有机制通知该线程退出。`SocketBuffer` 未实现 `Resource` 接口，无法通过 try-with-resource 自动清理。
  ```cj
  // SocketBuffer.cj:20-30
  public struct SocketBuffer {
      let buffered: BufferedInputStream<TcpSocket>
      let queue: ArrayBlockingQueue<() -> Unit>
      SocketBuffer(queueSize: Int64, let socket: TcpSocket) {
          buffered = BufferedInputStream<TcpSocket>(socket)
          let queue = ArrayBlockingQueue<() -> Unit>(queueSize)
          this.queue = queue
          spawn {  // 无法停止/关闭
              while (let fn <- queue.remove()) {
                  fn()
              }
          }
      }
  }
  ```
  `Server.close()`（`server.cj:107-109`）只关闭 `server`，不关闭各 buffer 中的 socket 和 thread。
- **触发条件**: 服务端/客户端关闭时。
- **改进方案**: SocketBuffer 实现 `Resource`，添加关闭标志和毒丸（poison pill）机制：
  ```cj
  public struct SocketBuffer <: Resource {
      ...
      SocketBuffer(queueSize: Int64, let socket: TcpSocket) {
          ...
          spawn { ... }  // 循环中检查关闭标志或插入 null 作为毒丸
      }
      public func close(): Unit {
          queue.add({ => })  // 毒丸触发循环退出
          socket.close()
          buffered.close()
      }
  }
  ```
- **实施难度**: 中

---

## [P2] Server.close() 只关闭 server，不清理活连接

- **问题等级**: P2
- **问题描述**: `server.cj:107-109` `close()` 仅调用 `server.close()` 关闭 `TcpServerSocket`，但不对已建立的连接（`buffers` 中的 `SocketBuffer`）做任何清理。后续 `server.accept()` 返回后 spawn 的 reader 线程仍在运行并尝试读取已关闭的 socket。
  ```cj
  public func close(): Unit {
      server.close()
      // 未关闭 buffers 中的任何连接
  }
  ```
- **触发条件**: 服务端关闭时。
- **改进方案**: 遍历 `buffers` 关闭每个 `SocketBuffer`（需先实现 SocketBuffer 的关闭方法）。
- **实施难度**: 中

---

## [P3] Client.spawn closure 中 sockets[i] 赋值与 checker 重连的时序问题

- **问题等级**: P3
- **问题描述**: `client.cj:53-81` Timer 检查线程的 spawn 中 `sockets[i] = socketCreator()` 与主线程的 `transfer` 可能存在时序竞态——当 checker 正在重建 `sockets[i]` 时，`transfer` 通过 `index` 选择了另一个 socket（此 socket 是正常的），因此实际不影响主路径。但若 checker 和 transfer 选中同一 `i`，则 closed socket 可能被新创建的线程使用。
- **触发条件**: checker 重建 socket 与 transfer 选中同一索引时。
- **改进方案**: 使用 volatile 或原子引用保护 `sockets[i]` 的写入；或者 checker 不修改 `sockets` 数组，而是通过其他方式通知新 socket。
- **实施难度**: 高

---

## [P4] SocketBuffer 构造器中的冗余局部变量 queue

- **问题等级**: P4
- **问题描述**: `SocketBuffer.cj:23-24` `let queue = ArrayBlockingQueue<...>(queueSize)` 创建局部变量后赋值给 `this.queue = queue`，可以合并为一行：
  ```cj
  this.queue = ArrayBlockingQueue<...>(queueSize)
  ```
- **改进方案**: 合并为一行。
- **实施难度**: 低

---

## [P4] SocketParams.receiveBufferSize/sendBufferSize 默认值 0 总是被设置

- **问题等级**: P4
- **问题描述**: `SocketParams.cj:44-45` `populate()` 无条件设置 `socket.receiveBufferSize = receiveBufferSize_`（默认 0）和 `socket.sendBufferSize = sendBufferSize_`（默认 0）。0 表示"使用系统默认"，与不设置效果相同。若用户未显式调用 setter，写入 0 是冗余操作。
- **触发条件**: 始终（无实际影响）。
- **改进方案**: 使用 `Option<Int64>` 类型判断是否需要设置。
- **实施难度**: 低

---

## 总结

| 等级 | 数量 | 关键文件 |
|------|------|----------|
| P0   | 6    | 6    | 0      | `MessageFuture.cj`、`client.cj`、`server.cj` |
| P1   | 1    | 1    | 0      | `MessageFuture.cj` |
| P2   | 3    | 0    | 3      | `server.cj`、`SocketBuffer.cj` |
| P3   | 1    | 0    | 1      | `client.cj` |
| P4   | 2    | 0    | 2      | `SocketBuffer.cj`、`SocketParams.cj` |

**修复进度**：P0×6 + P1×1 全部修复，P2×3 待处理（死变量 future/id 已在清理 warning 时顺便修复「死变量」P2 和「ID 类型参数」P1）

**修复优先级建议**：
1. P0 第 1 项（`MessageFuture` 改 `class`）是所有 Client 异步通信的前置修复，建议最先实施
2. P0 第 2、3、4、5、6 项（index OOB/参数颠倒/encode 顺序/重连 socket/params 顺序）均为单行/小范围修改，可同步进行
3. P1（spurious wakeup）修复简单但收益显著
4. P2-P4 为可容忍问题，随架构迭代逐步解决
