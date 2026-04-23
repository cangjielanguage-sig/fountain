# IOUringStream 第二轮优化方案

## 当前性能基线（双ring架构 + write零分配）

| 操作 | IOUringStream | std.fs.File | 对比 |
|------|--------------|-------------|------|
| Write 1MB (256×4KB) | 290us | 391us | IOUring快26% |
| Read 1MB | 447us | 101us | IOUring慢4.4× |

## Read 微基准拆解（256次×4KB，tmpfs）

| 操作 | 耗时/次 | 占比 |
|------|--------|------|
| getSQE | 60ns | 7% |
| acquireBuf | 49ns | 6% |
| prepRead+setData64 | 85ns | 10% |
| **submit (syscall)** | **467ns** | **58%** |
| waitCQE | 64ns | 8% |
| cqeSeen | 83ns | 10% |
| Mutex | 23ns | 可忽略 |

---

## 优化方案（按收益从高到低排序）

### 1. SQE/CQE 结构体指针偏移直写 — 消除全量 read-modify-write

**问题**：所有 `ioUringPrep*` 函数执行 `sqe.read()`（64B全量拷贝）→ 修改字段 → `sqe.write()`（64B全量写回）。之后 `ioUringSQESetData64` 又做一次 64B read-modify-write。read 路径上 `ioUringCQEGetRes`/`ioUringCQEGetData64` 各做一次 16B CQE 全量拷贝只为读 1 个字段。

read 路径单次 SQE 准备：`ioUringPrepRW`(128B) + `ioUringSQESetData64`(128B) = **256B 内存拷贝**，只为设置 12 个字段。

**优化方案**：
- 用 `CPointer<Byte>(sqe) + offset` 指针偏移直接写 SQE 各字段，避免全量 struct 拷贝
- CQE 读取同理：`(CPointer<Byte>(cqe) + 8).read<Int32>()` 读取 res 字段
- 需要写 C 辅助程序用 `offsetof` 验证各字段偏移量，或沿用 `ioUringSetSQETail` 的硬编码偏移量方式
- 对 IOUringSQE 的字段偏移：opcode=0, flags=1, ioprio=2, fd=4, off=8, addr=16, len=24, rwFlags=28, userData=32, bufIndex=40, personality=42, spliceFdIn=44, addr3=48
- 对 IOUringCQE 的字段偏移：userData=0, res=8, flags=12

**优化收益**：
- read 路径 SQE 准备：从 256B 拷贝降至 ~0B（指针偏移直写），预估节省 ~65ns/次（prepRead+setData64 从 85ns 降至 ~20ns）
- read 路径 CQE 读取：从 32B 拷贝（2次 `cqe.read()`）降至 ~0B，预估节省 ~15ns/次
- write 路径、reap 路径同样受益
- **综合预估**：read 路径总耗时从 447us 降至 ~410us（节省 ~37ns/次 × 256次 ≈ 9.5us）

**实施难度**：中（需验证偏移量、对齐规则，修改所有 prep* 和 CQE get* 函数）

**涉及文件**：
- `f_io/src/uring/uring_sqe.cj`：所有 `ioUringPrep*` 函数、`ioUringSQESetData64`、`ioUringSQESetFlags`
- `f_io/src/uring/uring_cqe.cj`：`ioUringCQEGetData64`、`ioUringCQEGetRes`、`ioUringCQEGetFlags`

---

### 2. ringPtr.read() 冗余调用消除

**问题**：`IoUring.peekCQE()` 和 `LockFreeCQEReaper.reapAll()`/`reapN()`/`peekCQE()` 中 `ringPtr.read()` 被调用两次——第一次获取 `.cq`，第二次获取 `.flags`。`IOUring` 结构体约 200+ 字节，每次 `read()` 全量拷贝。

当前代码：
```cj
let cq = ringPtr.read().cq              // 全量拷贝 ~200B
let shift = if ((ringPtr.read().flags & IORING_SETUP_CQE32) != 0)  // 冗余全量拷贝
```

**优化方案**：缓存第一次 `read()` 的结果，复用 `.flags` 字段：
```cj
let ringVal = ringPtr.read()            // 全量拷贝 1 次
let cq = ringVal.cq
let shift = if ((ringVal.flags & IORING_SETUP_CQE32) != 0)  // 复用 ringVal
```

**优化收益**：
- 每次调用节省一次 ~200B 全量 struct 拷贝
- 影响 peekCQE（IoUring + LockFreeCQEReaper）、reapAll、reapN 共 5 处
- write 路径 reap 频率最高，但 reaper 已有 waitCQE 阻塞间隔，单次收益约 ~30ns
- **综合预估**：write reap 路径每 CQE 节省 ~30ns，256次 write 的收割阶段节省 ~7.7us

**实施难度**：低（简单变量缓存）

**涉及文件**：
- `f_io/src/uring/uring_ring.cj`：`peekCQE()`
- `f_io/src/uring/lockfree/cqe_reaper.cj`：`peekCQE()`、`reapAll()`、`reapN()`

---

### 3. read 路径跳过无用的 ioUringCQEGetData64 调用

**问题**：`readNormal` 中 `ioUringSQESetData64(sqe, UInt64(1))` 写死 userData=1，read 路径只有一个请求，不需要从 CQE 读回 userData 来路由回调。但当前代码流程中 `readRing.waitCQE()` 返回 CQE 后直接读 `ioUringCQEGetRes(cqe)`，并没有调用 `ioUringCQEGetData64`——所以这条实际上已经是跳过的。

**重新审视**：read 路径实际已跳过了 userData 读取，直接读 res。此条无额外收益。

**优化收益**：无（已经是优化的状态）

**状态**：跳过

---

### 4. writeFixed 路径零分配回调

**问题**：`writeNormal` 已用 `CompletionCallback.None`（零分配），但 `writeFixed` 每次创建 `LambdaCompletionCallback({ _ => allocator.release(bufIdx) })`，每次堆分配一个对象。

**优化方案**：
- 方案 A：为每个 bufIdx 预创建一个固定回调实例数组（`Array<CompletionCallback>`），每次 writeFixed 直接用 `fixedCallbacks[bufIdx]`，避免堆分配
- 方案 B：让收割器在 `invokeAndRelease` 后自动释放 bufIdx，类似 writeNormal 用 `CompletionCallback.None`。但需要在 `invokeAndRelease` 中额外记录 bufIdx，增加耦合
- 推荐 A：实现简单，无侵入性

```cj
// 构造函数中预创建
this.fixedBufCallbacks = Array<CompletionCallback>(Int64(fixedBufCount)) { i =>
    let alloc = fixedBufAllocator
    LambdaCompletionCallback({ _ => alloc.release(UInt32(i)) })
}
// writeFixed 中使用
let callback = fixedBufCallbacks[Int64(bufIdx)]  // 无堆分配
```

**优化收益**：
- 每次 writeFixed 省去一次堆分配 + GC 压力
- 在高频 writeFixed 场景（如 NVMe SSD）下收益明显
- **综合预估**：writeFixed 路径每次节省 ~50-100ns（对象分配+初始化），但 tmpfs 上 writeFixed 整体比 writeNormal 慢 90%，此优化意义有限

**实施难度**：低（预创建回调数组）

**涉及文件**：
- `f_io/src/IOUringStream.cj`：`writeFixed()` 方法

---

### 5. CQE ktail 读取缺少 acquire 语义 — ARM 正确性修复 （已完成）

**问题**：`cqe_reaper.cj:114` 中 `cq.ktail.read()` 使用普通读，而 `uring_cqe.cj:194` 的 `ioUringCQReady` 正确使用了 `ioUringSmpLoadAcquire(cq.ktail)`。在 ARM 等弱内存序架构上，普通读可能观察到内核写入 ktail 的旧值，导致漏收割 CQE。

```cj
// 当前代码（错误）
let tail = cq.ktail.read()

// 修正
let tail = ioUringSmpLoadAcquire(cq.ktail)
```

**优化收益**：
- 非 ARM 平台（x86_64）：无性能差异（x86 TSO 保证 acquire 语义）
- ARM 平台：修复正确性 bug，避免 CQE 漏收割
- **综合预估**：0 性能收益，但修复潜在正确性问题

**实施难度**：低（单行替换）

**涉及文件**：
- `f_io/src/uring/lockfree/cqe_reaper.cj`：`peekCQE()`、`reapAll()`、`reapN()` 中所有 `cq.ktail.read()`

---

### 6. readMutex 可选移除

**问题**：readMutex 保护 `getSQE + submit + waitCQE`，但 readRing 只在调用线程使用。如果用户保证单线程 read（IOStream 的常见模式），mutex 是纯开销（微基准 23ns/iter）。

**优化方案**：
- 方案 A：新增构造参数 `singleThreadRead!: Bool = true`，默认跳过 readMutex
- 方案 B：文档说明 read 非线程安全，移除 readMutex
- 推荐 A：保持向后兼容，默认优化

```cj
if (singleThreadRead) {
    // 无锁路径
    let sqeOpt = readRing.getSQE()
    ...
} else {
    synchronized(readMutex) {
        ...
    }
}
```

**优化收益**：
- 单线程 read 场景节省 ~23ns/iter
- 256次 read 节省 ~5.9us
- **综合预估**：read 从 447us 降至 ~441us（-1.3%）

**实施难度**：低（增加条件分支）

**涉及文件**：
- `f_io/src/IOUringStream.cj`：`readNormal()`、`readFixed()` 方法、构造函数

---

## 总结

| 优先级 | 优化项 | 预估收益(256次) | 类型 | 难度 |
|--------|--------|----------------|------|------|
| 1 | SQE/CQE 指针偏移直写 | read -37ns/次 ≈ -9.5us | 性能 | 中 |
| 2 | ringPtr.read() 冗余消除 | reap -30ns/次 ≈ -7.7us | 性能 | 低 |
| 3 | read 路径跳过 userData | 0（已跳过） | — | 跳过 |
| 4 | writeFixed 零分配回调 | writeFixed -50~100ns/次 | 性能 | 低 |
| 5 | readMutex 可选移除 | read -23ns/次 ≈ -5.9us | 性能 | 低 |

**注意**：submit syscall 占 read 路径 58%（467ns/次），是绝对瓶颈且无法通过代码优化消除。以上优化针对的是剩余 42% 中的冗余开销，综合收益有限（read 路径最多再降 ~15us）。
