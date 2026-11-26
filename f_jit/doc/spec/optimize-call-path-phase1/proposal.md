# Proposal

## Why

并行执行（`2026-11-26-feat-f-jit-parallel-call`）已经删掉了调用级的全局锁，但**每一次调用**仍要穿过若干
进程级短临界区。基线（`f_jit/doc/optimize-call-path.md` §3.1）显示：

- 4 线程短调用 `Q4/Q1 = 1.08×`——调用路径上的锁把 4 线程压成 1 线程；
- 4 线程字段查找单次成本 `F4/F1 = 2.0`——每次 `find` 的全局锁 + bucket 拷贝在并发下互相排队；
- 长调用 `S4 = 2.22×`——执行本身无锁，瓶颈在**每次调用的簿记**。

本变更按该文档的硬规则执行：**先建测量工具（T0）→ 逐项改 → 用数据决定 keep/revert**。

## What Changes

- **T0 测量基础设施（不改产品代码）**：新增非门槛测试类 `CallPathBench_test`，提供 B1 短调用吞吐、
  B2 宿主字段查找、B3 分配型单元、B4 `JitContext.create + free` 四个场景，只打印 `CP-BENCH …`；
  `ParallelThroughput_test` 增加 `jitBacked` 观测。
- **P1.1 `HostFault` 改线程本地**（**keep**）：`ThreadLocal` 表按 ctx 地址记账，
  `record/causeOf/exceptionOf/takeCause/clear` 全走本线程；健康路径不取锁、不分配。
- **P1.2 `HostFieldTable` 改不可变快照**（**keep**）：注册期在写锁内构造新快照并原子发布，
  `find` 只读快照 + 数组遍历，不再拷贝、不再进锁；`accepts` 仍在锁外求值。
- **P1.3 生命周期原子化**（**评估后否决，未保留**）：实现、变异验证与 5 次复测均完成，
  但 Q4 +1.2%、L1 −0.1%、S4 −9.9%，无指标达 MOV；按硬规则回滚，代码与测试已删除，
  设计与数据仅作为「此路不通」的记录。

**不改**：公开 API、错误码、计数口径（`NativeMem`）、窗口/句柄语义、迁移与提升语义、编译管线。

## Capabilities

### Modified Capabilities

- `f-jit-runtime`：`宿主异常专用码与异常栈`（cause 旁路收窄为调用线程私有）、
  `H64 / H65 字段读写`（字段表为不可变快照、查找无锁无分配）。

## Impact

- **语义**：结果、错误码、site 逐位不变；唯一收窄是宿主异常 cause 只对**调用线程**可见
  （全仓 15 处调用点无跨线程读，见 design D1 证据）。
- **性能（5 次中位数）**：
  - P1.1：Q4 `195595 → 444715 calls/s`（**+127.4%**），Q4/Q1 `1.08× → 2.30×`，C1 `615 → 280ns`；
  - P1.2：F1 `848 → 507ns`（**−40.2%**），F4 `1710 → 219ns`（**−87.2%**）；
  - P1.3：无收益，已回滚。
- **失败面**：任一项未达门槛即回滚，并在 `optimize-call-path.md` §7 记录「无效 + 数据」。
- **不在本次范围**：`JitContext` 池化（需先改 `NativeMem` 口径）、`HandleTable` 分片空闲表、
  `SignatureTable`/`AdapterRegistry` COW、编译管线与缓存锁。

## 实施中发现（独立问题）

`HandleTable` 的 16 位 gen 放在 Int64 最高位：`gen = 0x8000` 起 ID 为负，而判空用 `id <= 0`。
单线程第 32768 次复用同一槽即失败（code 99，与并发无关）。该缺陷阻断分配型长跑基准，
已记录在 `optimize-call-path.md` §10，需单独立项修复。
