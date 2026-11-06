# Design

## 1. 目标与边界

**目标**：在同一台机器、同一构建口径下，把 C（单缓冲，p50 6.26 µs）的成本拆成三块可见的数：

1. **floor**：4KB `copyTo` + `crc32` + 写空 sink 的不可约成本；
2. **no-CRC**：同一条生产编码路径去掉 CRC 尾部后的成本，两者相减即 CRC 的真实占比；
3. **multi-thread**：1/4/8/16 线程的吞吐与扩展比，暴露 `ArrayPool` 借还的竞争。

**边界**：只改 `f_protocol/src/default/FrameEncodeBench_test.cj` 与报告文档；**不动生产代码、公开 API、线协议、构建配置**。P0/P1/P2 的改造不在本变更内。

## 2. 复用现有 harness

- 沿用 `F_PROTOCOL_BENCH=1` 门控与 `CountingNullOutputStream`、`benchMessage(4000)`、`frameOf`、`bigEndianInt32`、`MonoTime` 采样方式。
- 新增可调参数：`F_PROTOCOL_BENCH_MT_N`（每线程帧数，默认 20_000）、`F_PROTOCOL_BENCH_THREADS`（默认 0 = 依次跑 `1,4,8,16`；给正整数则只跑该档）。
- 三个测量用例都只打印指标、不做时间断言（WSL 抖动）；正确性由不门控的守卫用例保证。

## 3. floor 基准

```cangjie
// 预分配，循环内不计分配
let payload = Array<Byte>(frameBytes - BENCH_FRAME_HEAD - BENCH_FRAME_CRC, repeat: 0x5A)
let frame = Array<Byte>(frameBytes, repeat: 0)
// 每轮：
payload.copyTo(frame, 0, BENCH_FRAME_HEAD, payload.size)
frame[1] = Byte(i)                       // 让 CRC 输入每轮不同，防止编译器把 CRC 提出循环
checksum ^= crc32(frame[0 .. BENCH_FRAME_HEAD + payload.size])
sink.write(frame)
```

- 输出 `FLOOR frameBytes=... n=... nsPerFrame=... p50=... p99=...`（10 批 × n/10，批均值排序取 p50/p99）。
- 页面错误/冷缓存用 `warmup`（默认 5_000）挡掉。
- 该值就是「任何实现都不可能低于」的下界（不含调度与协议逻辑）。

## 4. no-CRC 基准

测试内复刻生产成帧路径，只去掉 CRC 尾部（不改生产代码）：

```cangjie
private func encodeNoCrcInto(msg: Message, sink: OutputStream): Unit {
    let bytes = DefaultCodec(headroom: BENCH_FRAME_HEAD)
        .encode(msg.id.time).encode(msg.id.pid).encode(msg.id.tid).encode(msg.id.hostId)
        .encode(msg.data).finish()
    try {
        let n = bytes.byteSize().getOrThrow()
        if (let Some(frame) <- bytes.frameBytes(BENCH_FRAME_HEAD, 0)) {
            frame[0] = BENCH_FRAME_VERSION
            frame[1] = msg.command.value
            putInt32BE(frame, 2, n)
            sink.write(frame)
        } else {
            throw IllegalStateException('no-CRC bench expects a single-buffer frame')
        }
    } finally {
        if (let r: Releasable <- bytes) { r.release() }
    }
}
```

- 输出 `NOCRC nsPerFrame=... p50=... p99=... allocBytesPerFrame=...`。
- `CRC 成本 ≈ C 的 ns/帧 - NOCRC 的 ns/帧`（同口径取 p50 与均值各算一次）。

## 5. 多线程基准

```cangjie
for (t in threadCounts) {
    let barrier = Barrier(t + 1)
    // 每线程独立 sink（避免 sink 竞争），消息在闭包外构造一次
    // 每线程：barrier.wait(); for (_ in 0..n) { msg.encode().copy(to: ownSink) }
    // 主线程：barrier.wait(); 记 start；逐个 f.get()；记 end
    // 断言：sum(sink.total) == frameBytes * n * t
    // 吞吐 = t*n / elapsed；nsPerFramePerThread = elapsed / n；scaling = 吞吐 / 1 线程吞吐
}
```

- 输出每个线程数一行：`MT threads=... framesPerThread=... totalFrames=... elapsedMs=... throughputFps=... nsPerFramePerThread=... scaling=...`。
- 1 线程作为基线；4/8/16 与它比。
- MT 不绑核（要测扩展性）；单线程 floor/no-CRC 仍 `taskset -c 2`。
- 池是 `DefaultCodec` 的静态 builder（全线程共享），这正是要测的竞争点。

## 6. 正确性守卫（不门控，进常规回归）

| 用例 | 断言 |
| --- | --- |
| `noCrcFrameMatchesProductionMinusCrc` | no-CRC 输出 == 生产帧去掉最后 4 字节（逐字节） |
| `floorFrameMatchesProductionFrame` | 以生产 payload 为输入，floor 组装的整帧 == 生产帧（含 CRC，逐字节） |
| `multiThreadHarnessCountsBytes` | 2 线程 × 100 帧，各 sink 字节数 == 帧长 × 帧数 |

TDD：先加一个返回空数组的 stub，让三个守卫失败（Red），再实现 helper 转绿。

## 7. 测量与报告

- 构建口径与上一轮一致：临时给依赖链加 `-O2`，清 `target` 重建，测完 `git checkout -- 'f_*/cjpm.toml'` 回退（不提交）。
- 单线程三组各跑 3 轮取中位；MT 每组 3 轮取中位。
- 在 `f_protocol/doc/perf/frame-encode-4k.md` 追加「归因」章节：
  - floor / no-CRC / C 三者对比表（ns、p50、p99、分配）；
  - `CRC 占比 = (C - noCRC) / C`；
  - MT 表：线程数、吞吐、每线程 ns、扩展比；
  - 结论：P0 与 P1 的预期收益哪个更大、MT 是否需要 per-thread pool。

## 8. 风险

| 风险 | 缓解 |
| --- | --- |
| CRC 结果被编译器优化掉 / 提出循环 | 每轮改 `frame[1]`，`checksum` 累计并在末尾打印 |
| MT 计时受 WSL 调度影响 | 3 轮取中位、报告原始三值、不用时间断言 |
| `Barrier` 计数不匹配导致挂起 | `Barrier(t+1)` 与 t 个 worker + 主线程严格对应；用例超时由测试框架兜底 |
| no-CRC 路径与生产路径分叉 | 守卫用例逐字节对比；路径只删 CRC 尾部 |
| 池竞争导致 MT 用例很慢 | `F_PROTOCOL_BENCH_MT_N` 可调，默认 2 万/线程 |

## 8.1 实施记录

- `F_PROTOCOL_BENCH_THREADS` 实现为单档（正整数）而不是逗号列表：避免依赖 `String.split` 的版本差异，需要多档时默认值已覆盖 1/4/8/16。
- 取数期间宿主有另一会话在构建（load 19~33 与 2.4 两批样本）；报告只采用 load ≈ 2.4 的 3 轮，且明确标注“未绑核、未 profile”。
- 实测结论（见 `f_protocol/doc/perf/frame-encode-4k.md` §9）：CRC ≈ 42%，编码器 ≈ 36%，拷贝 ≈ 6%，封装/池/冷缓存 ≈ 16%；MT 在 4 线程见顶（2.27×）后回退到 1.90×。

## 9. per-thread / 小工作集池

**问题**：`DefaultCodec` 的静态 builder 共享一个 `ArrayPool<Byte>`（1024 × 8KB）。每次 `build`/`release`
都要走池的多个互斥量（`admission` / `waitMutex` 等），且借出的缓冲在 8MB 工作集上轮转，CRC 读取时大概率
不在 L1/L2。归因数据显示：C 比 no-CRC 多出的 3764 ns 里，约 1 µs 落在这部分。

**设计**：

- 新增 `LocalBufferCache`（f_pool 内部类）：
  - `borrow(timeout)`：线程本地 `ArrayList<Array<Byte>>` 非空则弹栈顶，否则回落到共享 `ArrayPool`；
  - `giveBack(buf)`：本地未满（`localCacheSize`，默认 4）则入栈，否则还共享池；
  - 内部一个 `Mutex`；`localCacheSize = 0` 时等价于直连共享池（用于 A/B）。
- `BytesListOutputStreamBuilder` 持有 `ThreadLocal<LocalBufferCache>`；`build()` 取当前线程的 cache，
  并把 cache 引用交给 `BytesListOutputStream`；
- `BytesListOutputStream.release()` 把缓冲还给**借出方线程的 cache**（不是释放方线程）。这样生产路径上
  “编码线程借、写线程还”仍然把缓冲还回编码线程，下一次编码复用同一批缓冲；跨线程归还只锁该线程自己的
  cache，不同线程之间不竞争。
- 新增可选参数 `BytesListOutputStream.builder(localCacheSize!: Int64 = 4)` 与
  `DefaultCodec.setBufferPool(..., localCacheSize!: Int64 = 4)`；默认值保持行为改进但不需要调用方改代码。
- 线程退出时 `ThreadLocal` 中的 cache 随线程回收；每个线程最多 `localCacheSize × 8KB`（默认 16KB）。
- **受限池保护**：`maxSize < 64` 时自动关闭本地缓存。否则每线程扣住缓冲会把小池锁死，
  `f_pool` 的 `concurrentBorrowNeverSharesBuffer`（8 线程 × 池 4）会超时；生产 `maxSize = 1024` 不受影响。

**风险**：跨线程归还时的可见性由 cache 的 `Mutex` 保证；grown buffer（尺寸不等于池项）不归还，沿用现有规则；
`ThreadLocal` 在长生命周期线程池上是稳定的，若应用为每个请求 `spawn` 新线程则缓存收益有限（但不会错）。

## 10. P0 编码器

**标量写入口**：给 `BytesListOutputStream` 增加 `writeByte(UInt8)`、`writeUInt32BE(UInt32)`、
`writeUInt64BE(UInt64)`（必要时再加 LE/Int 版本）。实现为：容量检查 + 直接下标写入，不再构造临时数组。

**DefaultCodec 改造**：把整数/长度/类型头等“小数组写入”改为标量写。范围以 4KB 消息的热路径为准：
`encode(Int64)` / `encode(UInt64)` / `encode(Int32)` / `encode(DateTime)` 的长度前缀等；字符串与
`Array<Byte>` 仍走 `write(Array)`（需要 memcpy）。改造后用现有 round-trip + 帧 CRC 守卫逐字节比对。

**复用编码器**：`Message.encode()` 每帧 `new DefaultCodec()` + `ArrayList<BytesCopyTo>`。先测量该对象的
实际占比，再决定是否引入线程本地 codec；`finish()` 会把 `inputs` 的所有权交出去，复用需要把“交出后重置”
做成不破坏返回链的语义，风险高于标量写，放到最后评估。

**去虚调用**：检查 `DefaultCodec.encode` 的返回类型；若返回 `Encoder` 接口，评估改为具体类型（协变返回）
或给热路径加具体类型的分支，减少接口分派。公开 API 只做兼容性扩展。

### 实施结果（2026-11-06，-O2，2 轮中位）

- 本地缓存 A/B（P0 前）：`localCache=0` C p50 6116 ns、16T 2.39×；`2` **3643 ns / 8.42×**；`4` 3894 ns / 8.01×；`8` 3727 ns / 8.84×。
  选默认 **2**（单线程最好、每线程 16KB）。
- P0（LC=2）：no-CRC p50 903 → **643 ns**（-29%），分配 512 → **384 B/帧**；C p50 3615 → 3566 ns（噪声内）。
- 最终（LC=2 + P0）：C p50 **3566 ns**，16T **8.46×**；CRC 占 **70~80%**，编码器+拷贝约 0.6 µs。
- 编码器复用/去虚调用**未做**：no-CRC 只剩 0.6 µs，收益不抵 `finish()` 所有权交接复杂度；硬件 CRC 用户另行规划。
- 回归暴露的既有问题：`f_mq` / `fmq` 共 8 处把 `finish().asBytes()` 的池缓冲视图在 `release()` 之后继续使用；
  旧池 1024 项时靠“下次大概率换缓冲”侥幸通过，本地缓存收紧到 2 项后立刻踩坏。已改为 `clone()` 后再 release。
- 受限池保护：`maxSize < 64` 自动关闭本地缓存（`f_pool.concurrentBorrowNeverSharesBuffer`：8 线程 × 池 4）。

## 11. 验收

- 三个测量用例打印 `FLOOR` / `NOCRC` / `MT` 行；
- 三个守卫用例在默认构建下通过；
- 报告追加归因数据与 P0/P1 建议；
- `f_protocol` 全量回归通过，`openspec validate --strict` 通过。
