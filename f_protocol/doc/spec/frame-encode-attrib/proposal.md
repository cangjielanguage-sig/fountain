# Proposal

## Why

上一轮 4KB 帧基准把单帧编码从 14714 ns 降到 8214 ns，但剩余成本没有归因：CRC32、4KB 拷贝、编码器小对象、池借还各占多少，单线程数据也看不出多核下的池竞争。没有这三组数，P0（去小对象 / 复用编码器 / 去虚调用）与 P1（CRC 与拷贝合并）的投入顺序只能靠猜。

本变更只加**归因基准**，不改生产代码，用数据回答三个问题：

1. 这台机器上「4KB 拷贝 + CRC32 + 写空 sink」的不可约成本是多少？
2. 同一消息去掉 CRC 后能快多少（CRC 的真实占比）？
3. 4/8/16 线程跑同一路径，吞吐是否线性扩展、池是否成为竞争点？

## What Changes

- 在 `f_protocol/src/default/FrameEncodeBench_test.cj` 增加三组受 `F_PROTOCOL_BENCH=1` 门控的基准：
  - **floor**：预分配 payload/整帧，循环只做 `copyTo` + `crc32` + 写空 sink；输出 ns/帧、p50/p99。
  - **no-CRC**：复用生产编码路径（`DefaultCodec(headroom)` + `frameBytes`），只跳过 CRC 尾部；输出 ns/帧、p50/p99、分配字节/帧。
  - **multi-thread**：1/4/8/16 线程各跑同一生产路径，输出吞吐、每线程 ns/帧、相对 1 线程的扩展比。
- 增加三个**不门控**的正确性守卫（保证基准测的是生产同一条路径）：
  - no-CRC 帧 == 生产帧去掉最后 4 字节；
  - floor 帧 == 生产帧（逐字节相同）；
  - 多线程各 sink 的字节数 == 帧数 × 帧长。
- 在 `f_protocol/doc/perf/frame-encode-4k.md` 追加「归因」章节：floor / no-CRC / MT 原始值、CRC 占比、扩展比、对 P0/P1 的建议。

## Capabilities

### New Capabilities

无（纯基准与文档，`skip_specs: true`）。

### Modified Capabilities

无。

## Impact

- 代码：仅 `f_protocol/src/default/FrameEncodeBench_test.cj`（测试）与 `f_protocol/doc/perf/frame-encode-4k.md`（文档）。
- 生产代码、公开 API、线协议、构建配置：**不改**。
- P0（写标量 / 复用编码器 / 去虚调用）、P1（CRC 与拷贝合并）、P2（per-thread pool / writev / send_zc）不在本变更范围；本变更产出数据后再单独提变更。
