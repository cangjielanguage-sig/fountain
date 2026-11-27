# 调用路径：`CallMarshal` 携带 `rs` + 惰性容器

## Why

2026-11-27 探针（load 4.62，探针已删）把注册类实参路径拆开后发现：

| 测量 | 数据 |
| --- | --- |
| `窗口 + pinHostObject + release` | **3127 ns** |
| 再叠加 `escape + getAs + releaseEscaped` | **3624 ns** |
| 其中 3 次 `RuntimeEnv.current()`（`currentWin` ×2 + `popFree` ×1） | **~1.2 µs** |
| `isInstanceOfHost` | 182 / 170 ns（不是瓶颈） |
| `emptyAllocs`（2 个空对象） | 336 ns |

`pinHostObject` 每次要走 `currentWin()`（取窗口）+ `newSlot` → `popFree()`（取空闲分片），
三处各自做一次 `RuntimeEnv.current()`。而 `JitFunction.callLocked` **已经持有 `rs`**，
`CallMarshal` 却没有把它带下去。

另外 `CallMarshal` 每次构造都建 `pinned` / `escaped` 两个 `ArrayList`，值型参数调用根本不用它们。

## What Changes

1. **`CallMarshal` 持 `rs`**：构造改为 `CallMarshal(rs)`；`JitFunction.callLocked` 传入已有的 `rs`。
2. **`HandleTable` 增 rs 重载**：`pinWith` / `pinAnyBoxWith` / `pinHostObjectWith` /
   `pinHostClosureWith` / `appendHostObjectWith`；内部 `currentWinOf(rs)`、`popFree(rs)`、
   `newSlot(rs, …)`，**0 次 TLS**。
3. **惰性容器**：`CallMarshal.pinned` / `escaped` 改为 `?ArrayList<Int64>`，首次 `add` 时创建；
   `cleanup` / `escapedIds` / `moveTo` 对 `None` 直接跳过。

**语义不变**：窗口记账、句柄 ID、去重顺序、清理时机全部逐位一致；只是把「从哪里取线程状态」
和「容器何时分配」改掉。

## Impact

- 收益目标：注册类实参路径 **−0.9 µs（约 −13%）**；值型短调用 **−340 ns（约 −10%）**；
- 影响文件：`src/CallMarshal.cj`、`src/runtime/HandleTable.cj`、`src/JitFunction.cj`（+ 护栏用例）；
- 风险：`CallMarshal` 的生命周期必须与 `rs` 同线程（它本来就在一次调用内使用，成立）；
  `pinned` 惰性化后 `cleanup` 的遍历顺序不变（只是空表跳过）。
