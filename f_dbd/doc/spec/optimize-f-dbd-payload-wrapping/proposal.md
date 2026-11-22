# 去掉 sqlPayload 的冗余 DataAny 装箱

## Why

`docs/LocalMode.md` 2.5 把 `DbdStatement.sqlPayload`（158-175）的 `DataAny` 两层临时包装列为优化点。探针澄清了机制：

`DataAny` 是 **struct**，本身不在堆上；但 `SqlPayload.add<T>(param: T)` 是泛型方法，调用处传入 `DataAny` 结构体会把它装箱，`add` 内部再 `param.toData()` 拆回 `Data` 并重新 `DataAny(...)`。这一装一拆是纯冗余。

实测（8 参数 payload，2000 次）：

| 写法 | 总分配 | 每次 |
| --- | --- | --- |
| `add<DataAny>(DataAny(data))` | 4,643,656 B | 2,321 B |
| `add<Data>(data)` | 3,488,448 B | **1,744 B（-25%）** |

两者最终存入 `params` 的内容完全一致：`DataAny(data)`。

## What Changes

- **`sqlPayload()` 改为 `payload.add<Data>(data)`**：`Data` 的 `toData()` 默认返回自身，`add` 只做一次 `DataAny(data)`，不再装箱结构体。`addNull()` 不变。
- **新增等价测试**：同一组参数分别用两种写法构造 `SqlPayload`，经 `DefaultCodec` 编码后字节完全一致；NULL 空洞保持 `DataNone`。
- **新增分配基准（只记录）**：8 参数 payload 打印两条路径的 `allocPerCall`；稳定差值由隔离探针给出（2,321 → 1,744 B/次），完整窗口受 GC 噪声影响不设硬断言。
- **不启用 local mode**：`DataAny` 是值类型，与 local 区域无关。

**公开 API 不变**：只改私有方法的调用写法；`SqlPayload.add<T>` 签名不变。

## Capabilities

无（纯性能重构，载荷字节与公开行为不变；`.openspec.yaml` 设置 `skip_specs: true`）。

## Impact

- 代码：`f_dbd/src/driver/DbdStatement.cj`（1 行）。
- 测试：新增 `f_dbd/src/common/PayloadWrapping_test.cj`；既有 `PayloadTest` 全量回归。
- 行为：SQL 载荷字节不变，参数个数与 NULL 空洞不变。
