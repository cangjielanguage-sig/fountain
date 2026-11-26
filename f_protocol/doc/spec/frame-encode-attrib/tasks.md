# Tasks

## 1. 守卫用例（先 Red）

- [x] 1.1 加 `noCrcFrameMatchesProductionMinusCrc`：stub 返回空数组，实测失败（got.size != production.size - 4）。
- [x] 1.2 加 `floorFrameMatchesProductionFrame`：stub 返回空数组，实测失败（frame.size != production.size）。
- [x] 1.3 加 `multiThreadHarnessCountsBytes`（2 线程 × 100 帧）：stub 返回 (0,0)，实测失败。

## 2. floor 基准

- [x] 2.1 实现 `floorFrame` 与 `measureFloor`（copyTo + crc32 + 空 sink，10 批；每轮改 `frame[1]` 防优化）。
- [x] 2.2 守卫 1.2 转绿。
- [x] 2.3 跑 3 轮：中位 mean 3125 ns、p50 3135、p99 3383。

## 3. no-CRC 基准

- [x] 3.1 实现 `encodeNoCrcInto`（`DefaultCodec(headroom: 6)` + `frameBytes(6, 0)`，try/finally release）。
- [x] 3.2 守卫 1.1 转绿。
- [x] 3.3 跑 3 轮：中位 mean 2665 ns、p50 2666、p99 2854、分配 1376 B/帧；`C − noCRC = 3764 ns`。

## 4. 多线程基准

- [x] 4.1 实现 `runThreaded` / `benchMultiThread`（`Barrier(t+1)`、每线程独立 sink、`Future.get()` 汇合）。
- [x] 4.2 守卫 1.3 转绿。
- [x] 4.3 跑 1/4/8/16 各 3 轮：1T 145,234 fps；4T 330,157（2.27×）；8T 296,290（2.04×）；16T 276,635（1.90×）。

## 5. 报告与收尾

- [x] 5.1 在 `f_protocol/doc/perf/frame-encode-4k.md` 追加 §9「归因基准」：三组对比、拆解占比、MT 表、P0/P1/P2 建议。
- [x] 5.2 回退临时 `-O2` 配置，默认构建跑 `f_protocol` 全量回归（85/85）。
- [x] 5.3 `openspec validate --strict` 通过；归因基准已提交（`d1f37871`）。

## 6. per-thread / 小工作集池

- [x] 6.1 写 `LocalBufferCache` 测试（Red）：同线程借出→归还→再借，第二次必须命中本地缓存（`hits=1`）；stub 直连共享池时失败。
- [x] 6.2 实现 `LocalBufferCache` + `BytesListOutputStreamBuilder` 的 `ThreadLocal` 缓存 + `release` 还回借出方 cache。
- [x] 6.3 `builder(..., localCacheSize!)` 与 `DefaultCodec.setBufferPool(..., localCacheSize!)` 可选参数；默认 **2**，0 = 关闭本地缓存。
- [x] 6.4 守卫：跨线程归还后同线程再借仍能命中；`localCacheSize=0` 不缓存；池项尺寸不符不归还。
- [x] 6.5 基准：`F_PROTOCOL_BENCH_LOCAL_CACHE=0/2/4/8`（P0 前）：C p50 6116/3643/3894/3727 ns；16T 2.39×/8.42×/8.01×/8.84×；选 2。

## 7. P0 编码器

- [x] 7.1 给 `BytesListOutputStream` 加 `writeByte` / `writeUInt32BE` / `writeUInt64BE`。
- [x] 7.2 `DefaultCodec` 的整数/长度/类型头小数组写入改为标量写；帧 CRC 守卫逐字节不变（`frameCrc32=3762771613`）。
- [x] 7.3 评估编码器复用/去虚调用：no-CRC 只剩 0.64 µs，收益不抵 `finish()` 所有权交接复杂度，**不做**。
- [x] 7.4 基准：C p50 3566 ns、no-CRC 643 ns、floor 2847 ns、16T 8.46×；已更新 `frame-encode-4k.md` §10。
- [x] 7.5 默认构建全量回归：`f_pool` 72/72、`f_codec` 16/16、`f_protocol` 85/85、`f_rpc` 2/2、`f_mq` 149/149；`openspec validate --strict`。
- [x] 7.6 回归暴露的既有生命周期问题：`f_mq` / `fmq` 共 8 处「`finish().asBytes()` 视图在 `release()` 后继续使用」；
  收紧本地缓存后立即复用缓冲会踩坏，改为 `clone()` 后再 `release`。`f_mq` 149/149 通过。
