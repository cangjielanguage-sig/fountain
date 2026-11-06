# Tasks

## 1. 基准与安全网（不改生产逻辑）

- [x] 1.1 新建 `f_protocol/src/default/FrameEncodeBench_test.cj`：`F_PROTOCOL_BENCH=1` 门控、`CountingNullOutputStream`、4KB 消息构造、指标输出（ns/帧、分配字节/帧、GC 次数/耗时、帧特征）。
- [x] 1.2 先写门控用例：未设置 `F_PROTOCOL_BENCH` 时必须走 `SKIP` 分支且不失败。
- [x] 1.3 写 4KB 帧的 round-trip 与帧结构特征用例（version / cmd / len / CRC 自校验 + decode 字段一致），作为 B/C 的安全网。
- [x] 1.4 在 WSL release（`-O2`）构建、绑核下跑阶段 A 三轮，记录原始数据（含 `frameBytes` 与整帧 CRC32）。

## 2. 阶段 B：微改造

- [x] 2.1 写预算用例（Red）：`allocBytesPerFrame ≤ 2.5 × frameBytes`；A 上实测 14043 > 10070，确认失败。
- [x] 2.2 `ChainedBytesCopyTo.asBytes()` 单元素直返。
- [x] 2.3 三处逐字节循环改 `Array.copyTo`（`BytesListOutputStream.asBytes`、`ChainedBytesCopyTo.asBytes` 多段分支、`asOneSmallFrame` 的 payload 拷贝）。
- [x] 2.4 特征用例 + 预算用例（Green，9591 ≤ 10070）+ `f_pool` / `f_codec` / `f_protocol` 回归。
- [x] 2.5 阶段 B 三轮基准：ns/帧 10773、分配 9591、GC 2；帧 CRC 与 A 完全一致。

## 3. 阶段 C：单缓冲

- [x] 3.1 写预算用例（Red）：`allocBytesPerFrame ≤ 1.5 × frameBytes`；B 上实测 9591 > 6042，确认失败。
- [x] 3.2 `BytesListOutputStream` 内部改单可增长缓冲（`buf/start/len`），`asBytes` 返回视图，`copy` 一次写出；`write` 用 `copyTo` 内联。
- [x] 3.3 `BytesListOutputStreamBuilder` 增加 `headroom`，内部池改 `ArrayPool<Byte>`；公开签名保持兼容（`capacity` 语义改为缓冲字节数）。
- [x] 3.4 `DefaultCodec` 增加 `init(headroom!: Int64)`；`Message.encode()` 传 `FRAME_HEAD_SIZE`。
- [x] 3.5 `BytesListOutputStream.frameBytes(headroom, tail)` + `asOneSmallFrame()` 原地补头/CRC；拿不到视图时回退旧路径。
- [x] 3.6 池纪律用例：连续 2000 帧 encode→copy，池项可复用、字节数正确（`singleBufferPoolReuse2k`）。
- [x] 3.7 特征用例 + 预算用例（Green，5461 ≤ 6042）+ 受影响模块全量回归（`f_pool` / `f_codec` / `f_protocol` / `f_rpc` / `f_mq`）。
- [x] 3.8 阶段 C 三轮基准：ns/帧 8214、分配 1376、GC 1；帧 CRC 与 A/B 完全一致。

## 4. 结论与收尾

- [x] 4.1 写 `f_protocol/doc/perf/frame-encode-4k.md`：A/B/C 三轮原始值、中位数、分配/GC 对比、`-O0` vs `-O2` 说明。
- [x] 4.2 按 design §7 判定：B（-26.8% ns / -31.7% 分配）与 C（-44.2% ns / -90.2% 分配，且相对 B 再 -23.8%）均达标，**全部采纳**。
- [x] 4.3 公开 API 新增 `frameBytes`、`BytesListOutputStream` 单缓冲语义：`f_pool` README 中英已同步。
- [x] 4.4 `openspec validate --strict` + 受影响模块全量回归；提交待用户确认。
