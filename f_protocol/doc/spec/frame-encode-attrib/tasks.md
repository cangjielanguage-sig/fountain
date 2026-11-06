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
- [x] 5.2 回退临时 `-O2` 配置，默认构建跑 `f_protocol` 全量回归。
- [x] 5.3 `openspec validate --strict` 通过；提交（仅测试与文档）待用户确认。
