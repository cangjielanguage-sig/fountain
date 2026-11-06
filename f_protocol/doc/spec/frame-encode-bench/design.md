# Design

## 1. 现状与问题定位

小帧（payload ≤ `SMALL_MESSAGE_LIMIT` = 4096）走 `EncodedMessage.asOneSmallFrame()`。一次编码的真实开销：

| 步骤 | 代码位置 | 行为 |
| --- | --- | --- |
| ① 段内拼接 | `f_pool/src/BytesListOutputStream.cj` `asBytes()` | 分配 `Array<Byte>(n)`，逐字节拷所有段 |
| ② 链式拼接 | `f_pool/src/BytesCopier.cj` `ChainedBytesCopyTo.asBytes()` | 再分配 `Array<Byte>(n)`，逐字节拷 ① 的结果 |
| ③ 整帧组装 | `f_protocol/src/default/Message.cj` `asOneSmallFrame()` | 第三次分配，逐字节把 payload 拷进帧 |
| ④ CRC | 同上 | `crc32(out[0..8+n])` 是 Array 视图，**零拷贝**（`Array` 是 `{rawptr,start,len}` struct） |
| ⑤ 写 socket | `std.net` `DopraTcpSocketImpl.write` | `acquireArrayRawData` 后直接 `send`，用户态**零额外拷贝**，只有内核 `copy_from_user` |

结论：可优化的是 ①②③ 的**三次分配 + 三次逐字节循环**；切片与 socket 写不是优化对象。

## 2. 目标与非目标

**目标**

- 建立可复现的 4KB 帧对照基准，输出 ns/帧、分配字节/帧、GC 次数三组数据。
- 用数据判断两级改造（B 微改造 / C 单缓冲）是否值得进生产。
- 改造全过程保持帧字节语义不变，并有测试兜底。

**非目标**

- 不改线协议、帧格式、CRC 口径。
- 不改 socket 层，不引入 `CPointer`/native 缓冲/`writev`/io_uring。
- 不追求 0 拷贝；本设计接受"源数据 → 编码缓冲"这 1 次必要拷贝。

## 3. 基准设计

### 3.1 位置与门控

- 文件：`f_protocol/src/default/FrameEncodeBench_test.cj`（同包，可直接用 `Message` / `EncodedMessage` / `DefaultCodec`）。
- 门控：`F_PROTOCOL_BENCH=1`；未设置时打印 `SKIP: ...` 并 `return`（与 `f_util` 的 `F_UTIL_PERF`、`f_zip` 的 `F_ZIP_*` 口径一致）。
- 可调参数：`F_PROTOCOL_BENCH_N`（默认 50_000）、`F_PROTOCOL_BENCH_WARMUP`（默认 5_000）、`F_PROTOCOL_BENCH_ALLOC_N`（默认 2_000）。

### 3.2 被测消息

- `Message(Command.PUBLISH(AT_MOST_ONCE), DataString(<4000 个 ASCII 字符>))`。
- 编码后 payload 落在 4KB 量级；基准必须从帧头读出真实 `len` 并打印 `payloadBytes` / `frameBytes`，不以"4000"代替实测值。
- sink 用 `CountingNullOutputStream <: OutputStream`：`write` 只累加字节数、`flush` 空实现，**不产生 syscall**，把编码路径与网络路径隔开。

### 3.3 指标与算法

| 指标 | 采集方式 | 说明 |
| --- | --- | --- |
| ns/帧 | `MonoTime.now()`；预热后跑 N 帧；同时按 5_000 帧分批，输出批均值的 p50/p99 | 三次运行取中位数 |
| 分配字节/帧 | 先 `gc(true)`，记录 `getAllocatedHeapSize()`，跑 `ALLOC_N` 帧后再记录；差值 / N | 若窗口内 `getGCCount()` 增加，标记 `allocLowerBound=1` |
| GC 次数 | 跑 N 帧前后 `getGCCount()` 差值，换算每 10k 帧 | 同窗口记录 `getGCTime()` 差值 |
| 帧特征 | `frameBytes`、帧 CRC32、`Message.decode` 往返字段一致 | 三阶段必须一致 |

输出单行、可 grep：

```
BENCH stage=A payloadBytes=... frameBytes=... n=... warmup=... nsPerFrame=... batchP50=... batchP99=... allocBytesPerFrame=... allocLowerBound=0 gcCount=... gcPer10k=... gcTimeUs=...
```

### 3.4 运行规范

- WSL Ubuntu-24.04，`source cangjie.sh`，**release 构建**（`cjpm test` 的 release 开关以实际 CLI 为准，实施时先 `cjpm test --help` 确认）。
- `taskset -c <固定核>` 绑定 CPU，关闭其他压测；每阶段跑 3 轮取中位数。
- 若 3 轮 max/min > 1.3，判为噪声，重新绑定核后再跑。

## 4. 阶段 B：微改造（语义不变）

1. `ChainedBytesCopyTo.asBytes()`：`bytes.size == 1` 时直接返回 `bytes[0].asBytes()`，去掉一层分配+拷贝。
2. `BytesListOutputStream.asBytes()`：逐字节循环改 `b.copyTo(out, 0, off, b.size)`。
3. `ChainedBytesCopyTo.asBytes()` 多段分支：`part.copyTo(out, 0, off, part.size)`。
4. `EncodedMessage.asOneSmallFrame()`：`payload.copyTo(out, 0, FRAME_HEAD_SIZE, n)`。

预期：常见单段 payload 由 3 分配 + 3 拷贝降为 **2 分配 + 2 拷贝**，且三次逐字节循环全部变成 `intrinsicBuiltInCopyTo` 的批量拷贝。公开 API 无变化。

## 5. 阶段 C：单缓冲（内部结构改造，公开 API 不变）

### 5.1 结构

- `BytesListOutputStream` 内部由 `ArrayList<Array<Byte>>` 改为**单个可增长缓冲**：
  - 字段：`buf: Array<Byte>`、`start: Int64`（headroom 起点）、`len: Int64`；
  - `write(bytes)`：容量够时 `bytes.copyTo(buf, 0, start + len, bytes.size)`；不够时按 `max(2 * cap, need)` 扩容（上限 `maxSize`），旧缓冲归还池；
  - `asBytes()`：返回 `buf[start .. start + len]` 视图，零拷贝；
  - `copy(to)`：整段一次 `to.write(asBytes())`，同时把"每字段一次 write"收敛为**一次 write**。
- `BytesListOutputStreamBuilder` 增加 `headroom: Int64 = 0` 参数，内部池改用现有 `ArrayPool<Byte>`；原 `initSize/minSize/maxSize/capacity` 参数保留，映射为池大小与单缓冲容量上下限。
- `DefaultCodec` 增加内部 `init(headroom: Int64)`（默认 0）；`Message.encode()` 用 `DefaultCodec(headroom: FRAME_HEAD_SIZE)`。
- `BytesCopyTo` 增加默认方法 `frameBytes(headroom, tail): ?Array<Byte>`（默认返回 `None`）；
  `BytesListOutputStream` 覆写为返回 `buf[start - headroom .. start + len + tail]` 视图；`ChainedBytesCopyTo`
  在单元素时透传子项，多段/流式返回 `None`（由调用方回退旧路径）。

### 5.2 小帧组装

`EncodedMessage.asOneSmallFrame()`：

1. `byteSize() ≤ 4096` 且 `bytes.frameBytes(8, 4)` 有值；
2. 直接在该视图上写 `version` / `cmd` / `len`；
3. `crc32(frame[0 .. 8+n])`（视图，零拷贝）写入尾部；
4. 返回该视图，`to.write(frame)` 一次写出；
5. `release()` 在 `copy()` 的 `finally` 里归还池项（写出是同步阻塞调用，返回后复用安全）。

拿不到视图（大帧、流式载荷、多段链、非单缓冲实现）时走原有组装路径，行为不变。

### 5.3 预期

4KB 帧从 **3 分配 + 3 拷贝** 降到 **1 次池化分配 + 1 次必要拷贝**（源字符串 → 编码缓冲），组装拷贝为 0。

## 6. 正确性保障（先于任何优化）

- **Round-trip 特征测试**：`decode(encode(msg))` 的 command / id / data 必须与源消息一致（现有用例已覆盖，新增 4KB 载荷用例）。
- **帧结构测试**：`version`、`cmd`、`len`、尾部 CRC 自校验通过；`len` 等于实际 payload 字节数。
- **三阶段一致性**：基准输出 `frameBytes` 与整帧 CRC32，A/B/C 三次结果必须完全相同；不一致即回退该阶段。
- **池纪律**：`release()` 幂等、写出失败也必须归还（现有 `try/finally` 保持）；新增"C 路径下连续 encode→copy 10k 次不泄漏池项"的用例（以池可再次借出为判据）。
- **预算阈值**：初值取 `2.5 × frameBytes`（B）/ `1.5 × frameBytes`（C）；A 阶段实测后按"实测值 × 0.75 / 0.35"校准一次，并把校准依据写进测试注释，避免阈值变成拍脑袋常量。
- **回归**：`f_pool` / `f_codec` / `f_protocol` 全量 + 受影响调用方（`f_rpc`、`f_mq`）的测试。

## 7. 决策规则（先定门槛，避免事后找理由）

| 阶段 | 采纳条件 |
| --- | --- |
| B | 中位 ns/帧下降 ≥ 10%，分配字节/帧下降 ≥ 25%，全部测试绿 |
| C | 中位 ns/帧相对 A 下降 ≥ 20%，分配字节/帧 ≤ 1.5 × frameBytes，且相对 B 再降 ≥ 10% |
| 否则 | 保留更优的一级，回退其余改动；若都不达标，整体回退，只保留基准与报告 |

C 若达标但相对 B 的优势 < 10%，按"收益不抵风险"处理，停在 B。

## 8. 风险与回退

| 风险 | 缓解 |
| --- | --- |
| `BytesListOutputStream` 被 f_codec / f_rpc / f_mq 共用，内部布局变化影响面大 | 公开 API 不变；三模块全量回归；B/C 分两个独立提交，可单独 revert |
| 池项在写出前被归还 → 脏数据 | 写出保持同步；`copy()` 的 `finally` 顺序不变；新增池复用用例 |
| 扩容策略导致内存放大 | 初始容量 4KB（与 `SMALL_MESSAGE_LIMIT` 对齐）；上限 `maxSize`；4KB 帧不触发扩容 |
| 基准噪声（WSL / 频率调节） | 绑核、3 轮取中位数、max/min 阈值 1.3、报告附原始三次数值 |
| C 的视图与 `release` 生命周期耦合 | 视图只在 `copy()` 内部存活；`release` 后禁止再用（保持现有 `checkNotReleased` 纪律） |

## 8.1 实施期偏差（已记录）

- `frameBytes(headroom, tail)` 必须是 `public`（f_protocol 与 f_pool 不同包，`internal` 无法跨包访问），
  实现为 `BytesCopyTo` 的**默认方法**（默认 `None`）+ `BytesListOutputStream` 覆写 + `ChainedBytesCopyTo`
  单元素透传，避免 f_protocol 依赖具体实现类；已同步 `f_pool` README（中英）。
- `BytesListOutputStream` 的池复用语义变化：新借用方从 `len = 0` 开始（旧实现复用 ArrayList，会看到上次长度）。
  `f_pool` 的 `writeAfterReleaseMustThrow` 按新契约改为断言 `byteSize() == Some(0)`；「释放后再写必抛」保持不变。
- 池项缓冲尺寸默认 8192 B、`clearOnReturning` 默认 `false`（避免每次归还清 8KB）；`capacity` 语义变为缓冲字节数。

## 9. 交付物

- 基准与特征测试：`f_protocol/src/default/FrameEncodeBench_test.cj`。
- 阶段 B / C 的代码提交（各自独立，可单独回退）。
- 报告：`f_protocol/doc/perf/frame-encode-4k.md`（A/B/C 原始数据、中位数、结论、是否采纳）。
