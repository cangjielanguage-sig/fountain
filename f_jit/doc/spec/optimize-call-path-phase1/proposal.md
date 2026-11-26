# Proposal

## Why

并行执行（`2026-11-26-feat-f-jit-parallel-call`）已经删掉了调用级的全局锁，但**每一次调用**仍要穿过若干
进程级短临界区，且这些临界区的成本在短调用/字段访问密集场景下占比很高：

- `HostFault` 是全局 `Mutex` + 两张 `HashMap`（`runtime/HostCall.cj:217-269`），而 `JitContext.free`
  **每次调用**都调 `clear(ctx)`（`runtime/JitContext.cj:178-182`）——即使一次宿主异常都没发生，也要抢一次全局锁；
- `HostFieldTable.find` 每次 H64/H65 字段访问都在全局锁内把 bucket 拷进一个新的 `ArrayList`，再锁外匹配
  （`runtime/HostField.cj:94-111`）——一次字段读 = 一次锁 + 一次分配；
- `JitFunction.enterUnit/exitUnit` 每次调用各进一次单元 `mtx`（`JitFunction.cj:183-197`），包装实例还要在
  同一把锁里改 `EscapedClosure.state/active`（`JitFunction.cj:321-341`）——这是执行路径上最后一把
  「整调用级」的锁。

更大的问题不是这三处本身，而是**没有数据**：`Q1/Q4/F1/F4/A4/C1` 六个指标目前一个都没有基线
（`f_jit/doc/optimize-call-path.md` §3 明确记为「无数据」）。没有基线与噪声门槛，任何「优化有效」的
结论都不成立，也无法判断某处改动是不是纯粹的自我安慰。

本变更按该文档的硬规则执行：**先建测量工具（T0）→ 逐项改 → 用数据决定 keep/revert**。

## What Changes

- **T0 测量基础设施（不改产品代码）**：新增非门槛测试类 `CallPathBench_test`，提供四个场景并只打印
  `CP-BENCH …`：B1 短调用吞吐、B2 宿主字段读循环、B3 分配型单元、B4 `JitContext.create + free`；
  `ParallelThroughput_test` 增加 `isJitBacked()` 观测（打印恒有，断言视探测结果再固化）。
- **P1.1 `HostFault` 改线程本地**：`ThreadLocal` 表按 ctx 地址记账，`record/causeOf/exceptionOf/takeCause/clear`
  全走本线程；健康路径**不取锁、不分配**。
- **P1.2 `HostFieldTable` 改不可变快照**：注册期在写锁内构造新快照并发布，`find` 只做一次快照读取 + 数组
  遍历，不再拷贝、不再进锁；`accepts` 仍在锁外求值（保持可重入注册）；`resetForTest` 发布空快照。
- **P1.3 `JitFunction` / `EscapedClosure` 的 `state/active` 原子化**：`enter` 用「读 state → `active+1`
  → 复读 state」双检，`close` 用 CAS 0→1 决出唯一卸载者、轮询 `active==0`、超时 CAS 回退；
  `escaped` 清单、`cacheKey`、`release` 回调等冷路径仍留在 `mtx` 内。

**不改**：公开 API、错误码、计数口径（`NativeMem`）、窗口/句柄语义、迁移与提升语义、编译管线。

## Capabilities

### Modified Capabilities

- `f-jit-runtime`：`宿主异常专用码与异常栈`（cause 旁路收窄为调用线程私有）、`H64 / H65 字段读写`
  （字段表为不可变快照、查找无锁无分配）、新增 `调用路径的并发争用`（执行路径不得竞争进程级互斥量）。
- `f-jit-facade-bridge`：`并发调用与执行状态隔离`（生命周期记账改为原子量 + 双检，`close` 幂等由 CAS 保证）。

## Impact

- **语义**：结果、错误码、site 逐位不变；`close(timeoutMs)` 的返回值语义不变（并发重复 `close` 由
  「各自都去排空」收紧为「一个胜者排空、其余等待终态」，与规格的「重复卸载 SHALL 幂等」一致）。
  唯一收窄：宿主异常 cause 只对**调用线程**可见（现有代码没有任何跨线程读 cause 的路径，见 design D2 的证据）。
- **性能**：三项各自的收益待测，门槛写在 `tasks.md`（P1.1 达 MOV，P1.2 的 `F1/F4` ≥ 10%，P1.3 达 MOV）。
- **失败面**：任一项未达门槛即 `git revert` 该提交，并在文档 §7 记录「无效 + 数据」，不保留「看起来更优雅」的代码。
- **风险**：原子生命周期的漏计数（挂死或早释放）、快照发布的内存可见性、TLS 条目的生命周期。
  缓解与变异验证要求见 design「风险」表与 `tasks.md` P1.3。
- **不在本次范围**：`JitContext` 池化（依赖 P1.1，且需先改 `NativeMem` 口径）、`HandleTable` 分片空闲表、
  `SignatureTable`/`AdapterRegistry` COW、编译管线与缓存锁。
