# IOUringStream 性能优化方案

## 当前性能基线（双ring架构，ns精度）

| 操作 | IOUringStream | std.fs.File | 差距 |
|------|--------------|-------------|------|
| Write 1MB (256×4KB) | 381383ns | 398331ns | 持平（IOUring略快） |
| Read 1MB | 439237ns | 96580ns | IOUring慢~340us |
| Read 单次4KB | ~1.7us | ~0.4us | ~1.3us差距 |

**架构**：双ring（writeRing后台线程收割 + readRing同线程submit+waitCQE）
- Write：已与File持平，甚至略快
- Read：双ring消除了12ms跨线程通知开销，但io_uring的submit+waitCQE两次内核交互仍比File的直接read多~1.3us/次

---

## 性能瓶颈关键要点（已验证）

### 瓶颈1：read 路径的 Promise 线程同步开销（真正的瓶颈，已验证）
256次read × ~47us = 12ms。每次read的~47us主要来自：
1. 后台线程收割CQE后调用 `promise.onComplete()` → `cond.notifyAll()`
2. 调用线程从 `Condition.waitUntil()` 被唤醒
3. 两次线程调度切换（调用线程sleep → 后台线程wakeup → 调用线程wakeup）

LockFreePromise的自旋优化在tmpfs上无效——CQE未在自旋窗口内完成，
因为每次read都要等submit→内核处理→CQE返回，这个延迟远超100次自旋。

### ~~瓶颈2：submit系统调用开销（已排除）~~
SQPOLL模式下Read 13ms（反而更慢），证明submit不是主要瓶颈。
`io_uring_submit` 在tmpfs上开销极低（~2us），12ms差距主要来自线程同步。
io_uring 的 read 路径是 submit + waitCQE 两次内核交互，比直接 read 多一次。
对于小数据块（如4KB），这个额外系统调用的固定开销占比很大。

### ~~瓶颈2：submitMutex 锁竞争（已排除）~~
单线程无竞争，Mutex lock/unlock 只需一次原子CAS（~0.1us），不是主要开销。

### ~~瓶颈3：IoUringPromise 的 Mutex + Condition 开销（已优化为LockFreePromise）~~
已用LockFreePromise替代（AtomicBool+AtomicInt32+自旋+Condition fallback）。
但自旋在tmpfs上无效——CQE延迟超过自旋窗口，仍走Condition wait路径。
真正的问题不是Promise实现，而是**跨线程通知机制本身的开销**。

### 瓶颈2：read路径跨线程通知的开销（核心瓶颈）
后台收割线程收割CQE后通知调用线程，涉及：
- Condition.notifyAll() → 内核futex唤醒
- 调用线程从futex_wait返回 → 重新调度
- 两次线程上下文切换 ≈ 20-50us/次

**根本解决方案**：让read在同一线程内完成CQE收割，避免跨线程通知。

### 瓶颈3：对象分配开销
每次read创建LockFreePromise，每次write创建LambdaCompletionCallback。
可优化为对象池或内联回调。

---

## 优化方案（已验证后更新）

### ~~方案A：SQPOLL 模式（已实现，效果有限）~~
已实现，SQPOLL Read 13ms vs 普通 Read 12ms，无提升。
submit系统调用在tmpfs上开销极低（~2us），不是瓶颈。

### ~~方案B：submitMutex → CAS（已排除）~~
单线程无竞争，Mutex开销可忽略。跳过。

### ~~方案D：LockFreePromise（已实现，效果有限）~~
已实现（AtomicBool+AtomicInt32+自旋+Condition fallback）。
自旋在tmpfs上无效——CQE延迟远超自旋窗口，仍走Condition wait路径。
真正瓶颈是跨线程通知（Condition notifyAll + futex唤醒），不是Promise内部锁。

### 方案F：read在同一线程内收割CQE（✅已实现，消除12ms差距）

**思路**：read 不再依赖后台线程收割+跨线程通知，而是在调用线程内直接收割CQE。
这是 io_uring 的标准同步用法：submit → waitCQE → cqeSeen，全在同一线程完成。

**问题**：当前架构中后台线程循环 `waitAndReap()`，如果read也在同一线程 `waitCQE`，
两个线程会竞争CQE。解决方案：

**方案F1：双ring架构**
- write 用一个ring（后台线程收割，write立即返回）
- read 用一个ring（同线程 submit+waitCQE，无跨线程通知）
- 两个ring共享同一fd，offset需要分别管理

**方案F2：read切换为直接IoUring API**
- read 不用 IoUringLockFree，直接用 `ring.getSQE() + ring.submit() + ring.waitCQE()`
- 后台线程只收割write的CQE（通过userData区分）
- read的SQE userData设为0（waitAndReap跳过userData==0的CQE）
- 但waitCQE和waitAndReap会竞争同一个CQ ring

**方案F3：去掉后台线程，read/write都用同线程收割**
- write: submit → reap已完成的CQE（不阻塞等自己的CQE）
- read: submit → waitCQE（阻塞等自己的CQE）
- write的回调在下次read/write的reap中执行
- 问题：如果长时间不read，write的回调（释放slot）不会被及时执行

**推荐F1**：双ring架构最干净，读写完全独立，无竞争。

**预期效果**：read消除跨线程通知开销，12ms → ~0-2ms（与File持平）

### 方案C：write 回调零分配（✅已实现，Write性能提升27%）

**思路**：write 的回调仅释放slot，但收割器 `invokeAndRelease` 后已自动 `allocator.release`，
回调中再释放是**双重释放bug**。直接设置 `CompletionCallback.None` 即可——收割器自动释放slot。

**已修复**：移除write路径的 `LambdaCompletionCallback` + `allocator.releaseSlot(slotId)`，
改用 `CompletionCallback.None`。消除了一次对象分配+一次双重释放bug。

**效果**：Write从381us降至278us（-27%），比File(366us)更快

### 方案E：注册缓冲区（✅已实现，效果为负——tmpfs场景memcpy开销大于地址验证节省）

**思路**：通过 `io_uring_register_buffers` 预注册缓冲区，内核跳过地址验证。

**已实现**：
- 新增 `ioUringPrepReadFixed` / `ioUringPrepWriteFixed` 函数（需传入buf地址+bufIndex）
- IOUringStream 新增 `fixedBufCount` / `fixedBufSize` 参数
- 注册缓冲区由 LibC.malloc 分配（避免GC移动），AtomicSlotAllocator 管理索引
- read: READ_FIXED → memcpy到用户buffer；write: memcpy用户数据到注册缓冲区 → WRITE_FIXED
- 无可用注册缓冲区时自动降级为普通模式

**实测效果**（tmpfs）：
| 操作 | 普通模式 | 注册缓冲区模式 | File |
|------|---------|-------------|------|
| Write | 290us | 552us (+90%) | 391us |
| Read | 447us | 680us (+52%) | 101us |

**结论**：tmpfs上内核地址验证开销极小（<0.1us/次），额外memcpy（4KB/次×256次）反而拖后腿。
注册缓冲区更适合真实块设备（NVMe SSD）+ 高频小I/O场景。

---

## 优化优先级排序（更新）

| 优先级 | 方案 | 预期提升 | 实现难度 | 状态 |
|--------|------|---------|---------|------|
| P0 | F1: 双ring架构 | read 12ms→439us | 中 | ✅已实现 |
| P1 | C: write回调零分配 | write -27% | 低 | ✅已实现 |
| P2 | E: 注册缓冲区 | tmpfs无效(反而更慢) | 高 | ✅已实现，效果为负 |
| ~~P0~~ | ~~A: SQPOLL~~ | ~~无效~~ | 低 | 已实现，无效果 |
| ~~P1~~ | ~~B: CAS替代Mutex~~ | ~~可忽略~~ | 中 | 已排除 |
| ~~P2~~ | ~~D: LockFreePromise~~ | ~~自旋无效~~ | 中 | 已实现，效果有限 |

**推荐实施顺序**：F1 → C → E
