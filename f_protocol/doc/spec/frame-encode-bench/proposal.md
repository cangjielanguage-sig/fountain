# Proposal

## Why

`f_protocol` 的小帧路径（payload ≤ 4KB，正是 RPC / MQ / DB 中间件的典型报文尺寸）在组装一帧时要做 3 次全量分配和 3 次逐字节拷贝：

- `BytesListOutputStream.asBytes()`：分配整段缓冲，逐字节拷贝所有段；
- `ChainedBytesCopyTo.asBytes()`：再分配、再逐字节拷贝上一步结果；
- `EncodedMessage.asOneSmallFrame()`：第三次分配整帧，逐字节拷贝 payload。

这三次拷贝都是 Cangjie 侧带边界检查的下标循环，不是 memcpy。在 4KB 报文、高并发场景下，它是编码路径的主要 CPU 与 GC 来源，而真正写 socket 只有一次 `copy_from_user`（`std.net` 已把 Array 裸指针直接交给 send，用户态没有额外拷贝）。

在未拿到可信数据前直接改生产代码风险过高。本变更先建立可复现的 4KB 帧对照基准（当前实现 vs 两级改造），用 ns/帧、分配字节/帧、GC 次数三组数据决定是否值得改、改到哪一级。

## What Changes

- 新增一个受环境变量门控的编码基准（默认 SKIP，不进入常规测试耗时），固定 4KB 级 payload，测量：
  - ns/帧（均值 + 分批量 p50/p99）；
  - 分配字节/帧（`std.runtime.getAllocatedHeapSize()` 差值）；
  - GC 次数与 GC 耗时（`std.runtime.getGCCount()` / `getGCTime()`）。
- 新增帧字节特征测试：同一消息在三个阶段必须产出**逐字节相同**的帧（长度、CRC32、解码往返三方对齐），作为改造的安全网。
- 阶段 B（微改造，语义不变）：
  - `ChainedBytesCopyTo.asBytes()` 单元素直返，去掉一层分配+拷贝；
  - 三处逐字节循环改为 `Array.copyTo`（memcpy 级批量拷贝）。
- 阶段 C（单缓冲，内部结构改造、公开 API 不变）：
  - `BytesListOutputStream` 从"数组列表"改为单个可增长缓冲（保留大块引用策略）；
  - 顶层编码缓冲预留帧头 headroom，`EncodedMessage.asOneSmallFrame()` 原地补帧头与 CRC，不再为整帧再分配、再拷贝。
- 产出对照报告：`f_protocol/doc/perf/frame-encode-4k.md`，含 A/B/C 三阶段数据与采纳建议。
- 本变更**不改公开 API**、不改线协议、不改帧格式；阶段 B/C 是否保留由报告数据与评审决定。

## Capabilities

### New Capabilities

无（本变更是纯内部性能实验与工具，不改变任何系统行为；按 `skip_specs: true` 处理）。

### Modified Capabilities

无。

## Impact

- 代码：`f_pool`（`BytesListOutputStream`、`BytesCopier`）、`f_protocol`（`EncodedMessage.asOneSmallFrame`、`DefaultCodec` 内部缓冲参数）、`f_protocol/src` 新增基准与特征测试。
- 调用方：`f_codec` / `f_rpc` / `f_mq` 等使用 `DefaultCodec` 与 `BytesListOutputStream` 的模块；公开签名不变，内部缓冲布局变化需全量回归。
- 运行时：基准需在 WSL Ubuntu-24.04 的 release 构建下跑，固定 CPU 核、三次取中位数。
- 不做：不改 socket 层、不引入 `CPointer`/native 缓冲、不改 io_uring、不动帧协议与 CRC 口径。
