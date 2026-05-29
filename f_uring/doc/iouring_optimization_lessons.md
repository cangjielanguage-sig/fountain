# IOUringStream 性能优化经验总结

> 基于 IOUringStream 在 WSL2 Linux (tmpfs) 上的完整优化历程，记录成功经验和失败教训。

## 成功经验

### 1. 双 ring 架构消除跨线程通知开销（方案 F1）

**问题**：单 ring 架构下，write 由后台收割线程处理 CQE，read 用 `promise.awaitResult()` 阻塞等待。`awaitResult` 内部通过 `Condition.notifyAll()` 唤醒调用线程，每次涉及 futex 内核调用 + 线程上下文切换，开销约 47us。256 次迭代累积约 12ms。

**方案**：拆为独立 writeRing + readRing。writeRing 保持后台收割线程架构；readRing 在调用线程内同步完成 `getSQE → submit → waitCQE → cqeSeen`，无跨线程通知。

**效果**：Read 从 12ms 降至 447us。

**适用场景**：当跨线程通知（Condition/信号量/futex）成为累积瓶颈时，考虑拆分资源让消费者在同线程完成操作。

### 2. write 零分配用 CompletionCallback.None（方案 C）

**问题**：每次 write 创建 `LambdaCompletionCallback` 对象（堆分配），且回调中手动调用 `allocator.releaseSlot()` 与收割器 `invokeAndRelease` 中的自动 `allocator.release()` 构成 **slot 双重释放 bug**。

**方案**：write 回调不需要执行实质逻辑（收割器已自动释放 slot），改用 `CompletionCallback.None`（哨兵空回调），避免对象分配，同时修复双重释放。

**效果**：Write 从 381us 降至 278us（-27%）。

**适用场景**：回调不需要实质逻辑时，用哨兵值替代 lambda。同时检查是否已有自动释放机制，避免双重操作。

### 3. 微基准拆解定位瓶颈

**方法**：对 read 路径逐步计时每个函数调用：

| 操作 | 耗时/次 | 占比 |
|------|--------|------|
| getSQE | 60ns | 7% |
| acquireBuf | 49ns | 6% |
| prepRead + setData64 | 85ns | 10% |
| **submit (syscall)** | **467ns** | **58%** |
| waitCQE | 64ns | 8% |
| cqeSeen | 83ns | 10% |
| Mutex | 23ns | 可忽略 |

**结论**：submit syscall 是绝对瓶颈，占 58%。直觉可能指向 Mutex 或 waitCQE，但数据证明并非如此。

**适用场景**：性能优化前先做微基准拆解，用数据驱动而非直觉驱动。计时粒度要细到每个函数调用。

### 4. 实测验证而非理论推测

每个优化方案都实际构建运行 benchmark 验证，多个"理论上应该更快"的方案实测反而更慢：

- SQPOLL 理论上消除 submit syscall → 实测 Read 暴涨至 13ms
- submitAndWait 理论上合并 syscall 更快 → 实测 934ns vs 811ns（慢 15%）
- 注册缓冲区理论上减少内核开销 → 实测 Write/Read 分别慢 90%/52%

**适用场景**：所有涉及内核/硬件交互的优化假设必须实测验证，理论推测不可靠。

---

## 失败教训

### 1. 注册缓冲区在 tmpfs 适得其反（方案 E）

**期望**：通过 `io_uring_register_buffers` 预注册缓冲区，使用 READ_FIXED/WRITE_FIXED 跳过内核地址验证。

**现实**：tmpfs 上地址验证开销极小（<0.1us/次），而额外 memcpy（用户 buffer ↔ 注册 buffer，4KB/次 × 256 次）引入的开销远大于节省。

| 操作 | 普通模式 | 注册缓冲区模式 | 变化 |
|------|---------|-------------|------|
| Write | 290us | 552us | +90% |
| Read | 447us | 680us | +52% |

**教训**：注册缓冲区只在真实块设备（NVMe SSD）+ 高频小 I/O 场景考虑。低延迟存储（tmpfs/ramfs）上不要启用。

### 2. submitAndWait 比分步 submit + waitCQE 更慢

**期望**：`io_uring_submit_and_wait(ring, 1)` 合并了 submit + wait 为一次 syscall，应更快。

**现实**：934ns/iter vs submit+waitCQE 的 811ns/iter。原因：`io_uring_submit_and_wait` 在内核中代码路径更长，且 tmpfs 上 CQE 在 submit 返回后几乎立即可用（waitCQE 仅 64ns），分步执行无额外等待。

**教训**：合并 syscall 不一定更快，内核实现复杂度可能抵消减少 syscall 的收益。当低延迟存储使 CQE 立即可用时，分步执行反而更优。

### 3. SQPOLL 在 tmpfs 无效

**期望**：SQPOLL 用内核线程轮询 SQE，消除 submit syscall 开销。

**现实**：tmpfs 上 submit 开销本就极低（~2us），不是瓶颈。SQPOLL 引入了内核线程唤醒开销，Read 从 447us 暴涨至 13ms。

**教训**：SQPOLL 仅在有实测数据证明 submit syscall 是真正瓶颈时启用。低延迟存储场景 submit 本身很快，SQPOLL 只增加开销。

### 4. io_uring 同步单次 I/O 天然慢于 File.read

**根因**：io_uring 的两次内核交互（submit 467ns + waitCQE 64ns = 531ns）对比 File.read 的一次 syscall（365ns）。这是 io_uring 的架构设计权衡，不是实现问题。

**教训**：io_uring 的优势在于异步 + 批量 I/O 场景。同步低延迟存储场景应优先使用 File.read，不要在劣势场景强行优化。要改变性能格局需改变使用模式（异步批量提交），而非代码层面优化。

---

## 优化方案总览

| 方案 | 状态 | 效果 | 适用场景 |
|------|------|------|---------|
| F1 双 ring 架构 | ✅ 生效 | Read 12ms→447us | 跨线程通知成为瓶颈时 |
| C write 零分配 | ✅ 生效 | Write 381us→278us | 回调无实质逻辑时 |
| E 注册缓冲区 | ❌ 反效果 | Write/Read 慢 50-90% | 仅真实块设备+高频小I/O |
| A SQPOLL | ❌ 无效 | Read 暴涨至 13ms | 仅 submit 是真瓶颈时 |
| D LockFreePromise 自旋 | ❌ 无效 | CQE 延迟超过自旋窗口 | 仅超低延迟设备 |
| submitAndWait 合并 | ❌ 更慢 | 比分步慢 15% | 不适用于低延迟存储 |
| 移除 readMutex | ❌ 可忽略 | 仅 23ns/iter | Mutex 无竞争时开销极低 |

## 性能迭代历程

| 版本 | Write | Read | 关键改动 |
|------|-------|------|---------|
| 初始 (submitAsync + sleep) | 2589ms | - | 每 1ms 轮询 CQE |
| waitAndReap 替代 sleep | 8ms | - | 323× Write 提升 |
| 后台收割线程 + IoUringPromise | 0ms | 12ms | 异步 write + Condition 通知 |
| 双 ring 架构 | 381us | 439us | 消除跨线程通知 |
| write 零分配 | 278us | 447us | 修复双重释放 bug |
| 当前（ns 精度） | 290us | 447us | - |

## 通用方法论

1. **先拆解再优化**：微基准拆解找到真正瓶颈，避免优化无关路径
2. **实测大于理论**：内核/硬件行为复杂，理论推测常常错误
3. **匹配场景选方案**：同一优化在不同存储介质上效果可能天壤之别
4. **理解自动机制**：使用框架/库的自动资源管理时，必须确认完整语义（尤其是释放时机）
5. **架构决定天花板**：io_uring 同步模式 vs File.read 的差距是架构决定的，代码优化无法突破
