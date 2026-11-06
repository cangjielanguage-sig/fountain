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

## 范围扩展（2026-11-06，用户确认）

归因数据出来后，按用户指示**不单开变更**，在本变更内继续两项优化（硬件 CRC 暂不做）：

- **per-thread / 小工作集池**：`BytesListOutputStream` 的缓冲借还增加线程本地缓存（默认 2~4 个），
  借出方线程复用同一批缓冲，避免共享 `ArrayPool` 的锁竞争与 1024 × 8KB 轮转造成的 L3 抖动；
  公开 API 只增可选参数，不改线格式。
- **P0 编码器**：给 `BytesListOutputStream` 加标量写入口，`DefaultCodec` 的整数/长度字段不再每次
  `write([...])` 新建小数组；评估 `Message.encode()` 的编码器复用与接口去虚调用。

验收：单线程 C 的 p50 目标 ≤ 5.5 µs（当前 6.43 µs），MT 4 线程扩展比 ≥ 3.0×（当前 2.27×）；
两项都不改线格式，帧字节与回归必须保持一致。

## Impact

- 代码：仅 `f_protocol/src/default/FrameEncodeBench_test.cj`（测试）与 `f_protocol/doc/perf/frame-encode-4k.md`（文档）。
- 生产代码、公开 API、线协议、构建配置：**不改**。
- P0（写标量 / 复用编码器 / 去虚调用）、P1（CRC 与拷贝合并）、P2（per-thread pool / writev / send_zc）不在本变更范围；本变更产出数据后再单独提变更。
