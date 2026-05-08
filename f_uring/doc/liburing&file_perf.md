# IOUringStream vs std.fs.File 性能对比

## 测试环境

- **平台**: WSL2 Linux (tmpfs)
- **数据量**: 1MB (256 × 4KB)
- **仓颉版本**: 1.1.0-alpha
- **IOUringStream架构**: 双ring + 后台收割线程 + write零分配

## 性能总览

| 操作 | IOUringStream | std.fs.File | 对比 |
|------|-------------|------------|------|
| Write 1MB | **290us** | 391us | IOUring快 26% |
| Read 1MB | 447us | **101us** | File快 4.4× |
| FixedBuf Write 1MB | 552us | 391us | File快 41% |
| FixedBuf Read 1MB | 680us | 101us | File快 6.7× |

## Write 性能分析

IOUringStream Write 比File快26%，原因：

- **异步提交**: write() 提交SQE后立即返回，不等待完成
- **后台收割**: 独立线程收割CQE，不阻塞调用线程
- **零分配**: write路径不创建LambdaCompletionCallback，使用CompletionCallback.None

## Read 性能差距根因分析

### 微基准拆解（256次 × 4KB read，tmpfs）

| 操作 | 耗时/次 | 占比 |
|------|--------|------|
| getSQE | 60ns | 7% |
| acquireBuf | 49ns | 6% |
| prepRead + setData64 | 85ns | 10% |
| **submit (syscall)** | **467ns** | **58%** |
| waitCQE | 64ns | 8% |
| cqeSeen | 83ns | 10% |
| Mutex | 23ns | 可忽略 |

### 根因

**submit syscall 占 read 路径 58% 耗时。** tmpfs 上 read 延迟极低（CQE 在 submit 返回后几乎立即可用），io_uring 的两次内核交互（submit + waitCQE = 531ns）反而成为瓶颈。File.read 只需 1 次 syscall（365ns）。

### 已排除的优化方案

| 方案 | 结果 | 原因 |
|------|------|------|
| submitAndWait 合并 syscall | 更慢（934ns vs 811ns/iter） | 内核路径更长 |
| SQPOLL | 无效 | tmpfs 上 submit 开销已很小 |
| 移除 readMutex | 可忽略 | Mutex 开销仅 23ns/iter |
| 注册缓冲区 (Registered Buffers) | 更慢 | 额外 memcpy 开销 > 地址验证节省 |
| LockFreePromise (自旋等待) | 无效 | tmpfs CQE 延迟超过自旋窗口 |
| 双 ring 架构 | Read 从 12ms 降至 447us | 消除跨线程 Condition 通知 |

### 结论

io_uring 在**同步 read + 低延迟存储**场景下天然比直接 syscall 慢，这是架构设计权衡。io_uring 的优势在于**异步 + 批量化 I/O**场景。

## 优化历程

| 版本 | Write | Read | 关键改动 |
|------|-------|------|---------|
| 初始 (submitAsync + sleep) | 2589ms | - | 每1ms轮询CQE |
| waitAndReap 替代 sleep | 8ms | - | 323× Write 提升 |
| 后台收割线程 + IoUringPromise | 0ms | 12ms | 异步write + Condition通知 |
| 双 ring 架构 | 381us | 439us | 消除跨线程通知 |
| write 零分配 | 278us | 447us | 修复双重释放bug |
| 当前 (ns精度) | 290us | 447us | - |

## 注册缓冲区 (Registered Buffers) 测试

注册缓冲区通过 `io_uring_register_buffers` 预注册缓冲区到内核，I/O 请求使用 READ_FIXED/WRITE_FIXED 操作码，内核跳过地址验证。

### 测试结果

| 操作 | 普通模式 | 注册缓冲区模式 | 变化 |
|------|---------|-------------|------|
| Write | 290us | 552us | +90% |
| Read | 447us | 680us | +52% |

### 分析

tmpfs 上内核地址验证开销极小（<0.1us/次），额外 memcpy（4KB/次 × 256次）反而拖后腿。注册缓冲区更适合真实块设备（NVMe SSD）+ 高频小 I/O 场景。
