# `JitContext` 线程私有池化（唯一可测量的调用路径优化）

## Why

每次 JIT 调用都会 `LibC.malloc<Int64>(count: 8)`（64 B）再 `LibC.free`。实测
（`CallPathBench_test` B4）：

```
C1 = 405 ns/op     （create + free）
L1 = 2952 ns/call  （短调用端到端）
```

即**一次 malloc/free 占单次调用成本的 13.7%**。这是当前调用路径上唯一「占比大、
可独立归因、可测量」的剩余成本——其余项（实参数组、`CallMarshal` 分配）都在
20–30 ns 量级，低于构建机分辨率（`optimize-emit-audit` / `optimize-decode-alloc` /
`optimize-call-alloc2` 三次尝试均未测得收益）。

ctx 的生命周期严格嵌套（`create` 在桥入口、`free` 在 `finally`），天然适合栈式池化。

## What Changes

1. **`JitContext` 线程私有池**：`ThreadLocal<ArrayList<CPointer<Int64>>>`，上限 4 块。
   - `create`：池非空则复用栈顶块（随后**全量重写 8 个字**），否则 malloc；
   - `free`：先 `HostFault.clearWith(ctx, rs)`（按地址清异常旁路，**顺序不变**），
     再把块归还池（池满则真正 free）。
2. **`NativeMem` 计数口径调整**（关键决策）：
   - `mallocCount` / `freeCount` / `outstanding()` 的语义从「真实 malloc 次数」改为
     **「借出次数」**——`create` +1、`free` −1，无论块是否进池。
     这样 `outstanding()` 仍然是「当前借出未还的 ctx 数」，所有既有泄漏断言
     （调用结束回基线）**语义不变、无需修改**。
   - 新增 `realMallocCount` / `realFreeCount` / `residentBlocks()`：真实 malloc/free
     的累计数与存活块数（含池中常驻），用于「池确实在复用」的直接断言与诊断。

**为什么不用「池中块计入 outstanding」**：那会让每次调用结束后基线抬高 1–4 块，
现有 `ParallelCall_test` / `T40Account_test` 等十余处「`outstanding() == base`」断言
全部失效，需要逐一改写并重新定义「泄漏」——收益为零、风险极大。
「借出」口径反而更贴近泄漏检测的语义：借出未还才是泄漏，池常驻是有界常量。

## Impact

- 影响文件：`src/runtime/JitContext.cj`、`src/runtime/JitContext_test.cj`（新增用例）、
  `src/runtime/NativeMem*` 相关断言（不需要改，口径兼容）；
- 预期收益：C1 从 405 ns 降到 ~50–80 ns（一次 TLS get + 两次 ArrayList 操作），
  端到端 **L1 −7~10%**；并发路径同比例受益；
- 常驻成本：每线程最多 4 × 64 B = **256 B**，线程退出时不回收（TLS 无析构）——
  这是池化的已知代价，写入文档；
- 正确性关键点：复用前必须清 `HostFault`（按 ctx 地址索引），且 `create` 必须重写
  全部 8 个字（含 `dbgBase = 0`），否则上一次调用的错误槽/转储指针会污染下一次。
