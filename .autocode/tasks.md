# fsync 模块静态诊断报告

审查范围：`fsync/src/` 全部 17 个源文件
审查日期：2026-05-04
审查方式：静态代码分析（不编译、不运行）

---

## [P0] asyncPublish 为空桩，节点间数据永不同步

- **问题等级**: P0
- **问题描述**: `SyncHandler.cj:199-201` — `asyncPublish` 只调用了 `nodeManager.allOthers()` 但不发送任何 PUBLISH 消息给其他节点。每次 REGISTER/DEREGISTER 产生的数据变更仅在本地生效，不会传播到集群中其他节点。
- **触发条件**: 任何 REGISTER/DEREGISTER 操作
- **改进方案**: 实现发布逻辑：遍历 `allOthers()`，对每个节点创建 SyncClient（或直接使用 f_net.Client 连接）发送 `Message(Command.PUBLISH, SyncData(key, version, value).toData())`。
- **实施难度**: 高（需要跨节点连接管理、重试、容错机制）

## [P0] NodeManager 健康检查为空桩，无实际心跳

- **问题等级**: P0
- **问题描述**: `NodeManager.cj:33-41` — spawn 线程每 5 秒无条件设置 `alive.store(nodeCount)`，不做任何实际的 PING/PONG 检测。`canServeWrites()` 永远返回 true（假设全部节点存活），`getReadNode()` 不做存活检查直接返回哈希环的映射节点。
- **触发条件**: 任意节点宕机后，本地节点不会察觉，继续认为集群完整
- **改进方案**: 在线程中遍历 `allOthers()`，用 f_net.Client 发送 PING 并等待响应；超时或失败则 `alive.decrement()`，恢复则 `alive.increment()`。参考 `SyncCommand.validateClusterConfig` 中的 SyncClient 模式。
- **实施难度**: 高

## [P0] WatchManager 后台线程无法停止，资源泄漏

- **问题等级**: P0
- **问题描述**: `WatchManager.cj:88-94` — init 中 spawn 的 `while(true)` 清理线程无停止信号。WatchManager 被弃置时线程仍在运行，阻止 GC 且无法重新创建（重复 init 会产生多个线程）。
- **触发条件**: WatchManager 生命周期结束（如 Store 关闭、Server 关闭）
- **改进方案**: WatchManager 实现 `Resource` 接口，添加 `private let running = AtomicBool(true)`，`while(running.load())` 替代 `while(true)`，`close()` 中设置 `running.store(false)` 并等待线程结束。清理线程应捕获异常避免崩溃后无声退出。
- **实施难度**: 中

---

## [P1] SyncClient.getInstance 非线程安全

- **问题等级**: P1
- **问题描述**: `SyncClient.cj:41-43` — `if (let Some(inst) <- instance) { return inst }` 后接构造逻辑。两个线程首次并发调用 `getInstance()` 时可能都进入构造分支，创建两个 Client 实例并连接到不同端口。后赋值的实例会覆盖先赋值的，导致先赋值的连接泄漏。
- **触发条件**: 多线程首次同时调用 `getInstance()`
- **改进方案**: 在 `Mutex` 保护下执行检查+构造。或者（更简单）在静态 init 块中预先构造，避免运行时竞态。
- **实施难度**: 低

## [P1] SyncServer.start 的 spawn 不捕获异常

- **问题等级**: P1
- **问题描述**: `SyncServer.cj:37-41` — `spawn { server.start({ msg => handler.handle(msg) }) }`。如果 `server.start()` 抛出异常（如端口绑定失败），异常在线程中丢失，调用方无法知悉。后续 `server.isClosed()` 也不反映该状态。
- **触发条件**: 端口被占用、网络初始化失败
- **改进方案**: 返回 `Future<Unit>`，调用方可以通过 `future.get()` 捕获异常。或在 spawn 内 try-catch 并通过回调通知。
- **实施难度**: 低

## [P1] HashRing.getNextNode 在空环时抛出异常

- **问题等级**: P1
- **问题描述**: `HashRing.cj:59` — `ring.first.getOrThrow()` 在 ring 为空的 TreeMap 时抛出 NoSuchElementException。虽然正常初始化时 nodes 非空则 ring 不可能为空，但 `getNextNode` 可能在节点全移除后被调用。
- **触发条件**: nodes 列表为空（配置错误或运行时全部节点移除）
- **改进方案**: 在 `getNextNode` 入口处检查 `ring.first.isNone()` 提前返回 None，或 `ring.size == 0` 检查。
- **实施难度**: 低

## [P1] SyncCommand 配置校验失败 exit(1) 不释放资源

- **问题等级**: P1
- **问题描述**: `SyncCommand.cj:97` — `exit(1)` 直接终止进程，不关闭已打开的 Store（mmap 文件映射可能未回写）、Server（TCP 连接未优雅关闭）、WatchManager 后台线程（无法停止）。
- **触发条件**: 多节点集群 sync_hosts 配置不一致
- **改进方案**: `exit(1)` 前依次调用 `store.close()`、`server.close()`，并通过标志通知 WatchManager 线程退出。或抛异常回到 main 函数统一清理。
- **实施难度**: 中

---

## [P2] notify 的过期检查与 cleanupExpired 存在竞态

- **问题等级**: P2
- **问题描述**: `WatchManager.cj:183-187` — notify 在锁外调用 `entry.future.set(newValue)` 前检查 `entry.expiry`。但 cleanupExpired 在另一个线程中也可能同时移除过期的 WatchEntry。虽然两个操作都在锁内收集/修改，但 notify 在锁外使用 expiry 时可能会有失效窗口。
- **触发条件**: 恰好在 cleanupExpired 执行的同时 notify 被触发
- **影响**: 极低，竞争窗口极短，最多导致已过期的 watch 多触发一次通知
- **改进方案**: 将 entry 复制到 matched 列表时一并拷贝 expiry，在锁外使用拷贝值判断
- **实施难度**: 低

## [P2] SyncCommand 主线程用忙等保持存活

- **问题等级**: P2
- **问题描述**: `SyncCommand.cj:71-73` — `while (true) { sleep(Duration.second * 60) }` 使用 60 秒 sleep 的任务循环。虽然没有性能问题，但无法响应关闭信号。
- **触发条件**: 需要优雅关闭
- **改进方案**: 使用 `Condition.wait(timeout)` 或监听关闭信号实现优雅关闭
- **实施难度**: 低

---

## [P3] WatchFuture.get() 与 tryGet() 返回类型不一致

- **问题等级**: P3
- **问题描述**: `WatchManager.cj:43-48` — `get()` 返回 `Array<Byte>`（非 Option），但 `tryGet()` 返回 `?Array<Byte>`（Option）。如果 `get()` 在未 `set` 的情况下被调用（理论上不会，因为 `done` 检查），会抛出异常。
- **触发条件**: 无（有 done 守卫），仅类型设计不一致
- **改进方案**: `handleSubscribe` 中 `future.get()` 的返回值不直接作为数据进行传递，需注意 `get()` 返回的是已确认有值的 `Array<Byte>`。
- **实施难度**: 低

## [P3] VERSION_SUFFIX 可移至 SyncHandler 内部

- **问题等级**: P3
- **问题描述**: `SyncHandler.cj:28` — `VERSION_SUFFIX` 定义为 package-private `let`（文件级声明）。它仅在 `SyncHandler` 内部使用，可以改为 `private static let` 成员。
- **改进方案**: 移入 `SyncHandler` 类内部作为 `private static let VERSION_SUFFIX = '_version'.unsafeBytes()`
- **实施难度**: 低

## [P3] handleRegister 和 handleDeregister 的仲裁 + Owner 检查重复

- **问题等级**: P3
- **问题描述**: `SyncHandler.cj:58-69` 和 `82-93` — 两个方法有相同的 `canServeWrites()` + `isOwner()` 检查模板代码。如果后续新增写入类命令需要重复此模式。
- **改进方案**: 提取辅助方法 `checkWriteAccess(key): ?String`，返回 None 表示通过，Some(msg) 表示拒绝原因。减少重复代码。
- **实施难度**: 低

## [P3] 死代码：`ScanEntry` 类未在任何地方使用

- **问题等级**: P3
- **问题描述**: `SyncDataFormat.cj:117-128` — `ScanEntry` 类定义了 `key` + `value` 字段，但代码中没有任何地方创建或引用过这个类。它被 `ScanResult` 替代（后者直接使用 `keys` + `values` 两个 ArrayList）。
- **触发条件**: 编译时会产生未使用警告
- **改进方案**: 删除 `ScanEntry` 类，或保留但标注说明意图
- **实施难度**: 低

## [P3] HashRing_test 使用硬编码 `@Assert(!...)` 而非 `@Assert(not)`

- **问题等级**: P3
- **问题描述**: `HashRing_test.cj:76` — `@Assert(!ring.isOwner(key, otherIdx))` 使用 `!` 运算符取反。这虽然正确且可读，但若 `@Assert` 宏对 `!` 表达式展开方式有特殊行为时可能出错。
- **触发条件**: 无（测试当前通过）
- **改进方案**: 使用临时变量 `let notOwner = !ring.isOwner(key, otherIdx)` 再 `@Assert(notOwner)`
- **实施难度**: 低

---

## 汇总

| 等级 | 数量 | 关键问题 |
|------|------|---------|
| P0 | 3 | asyncPublish 空桩、健康检查空桩、WatchManager 线程泄漏 |
| P1 | 4 | getInstance 线程安全、spawn 异常丢失、空环异常、exit 不释放资源 |
| P2 | 2 | notify竞态、主线程忙等 |
| P3 | 5 | 类型不一致、死代码、重复模板等 |
| **总计** | **14** | |
