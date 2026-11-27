# 调用路径：窗口对象复用（减少每次调用 2 个 `Win` 分配）

## Why

`optimize-runtime-tls` 之后，窗口开合已无 TLS，但每次调用仍新建 **2 个 `Win`**：

- `openWindowWith` 压入一个新 `Win`；
- `resetWindow` 弹出后，若栈空则**再 new 一个环境窗口**。

2026-11-27 探针（慢峰，探针已删）：

| 测量 | 数据 |
| --- | --- |
| `openWindowWith + resetWindow(rs)` | **601 ns/次** |
| `ArrayList + Array` 两个空分配 | 336 ns（≈168 ns/对象） |
| GC 分配合计（6–8 个对象） | ~1.0–1.4 µs（慢峰 17–24%） |

窗口路径的两个 `Win` 约占 340 ns（5–6%），且是纯 GC 压力。

## What Changes

在 `RuntimeState` 里加一个**线程私有**的空闲 `Win` 池（≤8 个）：

- `openWindowWith`：优先从池取，清空后入栈；池空才 new；
- `resetWindow`：弹出的 `Win` 清空后放回池（超过上限才丢弃）；
- 环境窗口重建同样走池。

`Win` 的字段与语义不变（`base` / `cap` / `used` / `appendIds` / `pins`），只是**对象复用**。

**语义不变**：窗口栈的内容、容量、释放行为逐位一致；池只影响「对象从哪来」。

## Impact

- 收益目标：`windowRs` 601 → ≤300 ns；`L1` ≥3%（≈180 ns）；
- 影响文件：`src/runtime/RuntimeState.cj`、`src/runtime/HandleTable.cj`（+ 1 条护栏用例）；
- 风险：复用前必须清空 5 个字段（尤其 `appendIds` / `pins`），否则上一次调用的槽会被误释放；
  以「交替容量 + 连续 1000 次开合」用例锁住；池上限 8 防止无界增长。
