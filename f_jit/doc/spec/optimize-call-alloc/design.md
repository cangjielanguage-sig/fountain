# 设计：窗口对象复用

## D1 只复用 `Win`，不动 `CallMarshal`

`CallMarshal` 的 2 个 `ArrayList` 也能省约 340 ns，但它是根包（`fountain::f_jit`）的类，
不能放进 runtime 包的 `RuntimeState`（子包不能反向依赖根包）；若用 `ThreadLocal` 池，
每次 acquire 又要 1 次 TLS（300 ns），抵消收益。**留待单独评估**（可改为惰性 `Option<ArrayList>`）。

本变更只做 `Win`：同包、无 TLS、改动局部。

## D2 池的语义

```cangjie
// RuntimeState
internal let freeWins: ArrayList<Win> = ArrayList<Win>()   // ≤8
```

`HandleTable` 内部：

```cangjie
private static func acquireWin(rs: RuntimeState, base: Int64, cap: Int64): Win {
    if (rs.freeWins.size > 0) {
        let w = rs.freeWins.remove(at: rs.freeWins.size - 1)
        w.base = base
        w.cap = cap
        w.used = 0
        w.appendIds.clear()
        w.pins.clear()
        w
    } else {
        Win(base, cap)
    }
}

private static func recycleWin(rs: RuntimeState, w: Win): Unit {
    if (rs.freeWins.size < 8) {
        w.used = 0
        w.appendIds.clear()
        w.pins.clear()
        rs.freeWins.add(w)
    }
}
```

- **清空全部 5 个字段**：`pins` 是跨调用资产清单，残留会导致 `resetWindow` 误释放别的调用 pin 的槽；
- `base` / `cap` 在 acquire 时必写，无需预清；
- 池上限 8：窗口嵌套深度通常 ≤3，8 足够；超出丢弃，行为退回 `new`。

## D3 重入与隔离

- `wins`（栈）与 `freeWins`（池）都是 `RuntimeState` 的字段 ⇒ **线程私有**，跨线程不共享；
- 同一线程重入时，外层 `Win` 在栈里、内层 `Win` 在栈顶，池只在 `resetWindow` 弹出后接收对象，
  不存在「同一个 `Win` 同时在栈和池」的状态；
- `WindowIsolation_test`（4 线程各自开合）继续作为隔离护栏。

## D4 护栏与变异

新增 `WindowPool_test`：

1. **连续 1000 次 `openWindowWith`/`resetWindow`**：每次 `windowCapOf` 等于请求容量，`windowUsed` 归零；
2. **残留不串**：先开一个窗口并 `append` 若干句柄（制造 `appendIds` 非空），reset 后再开新窗口，
   断言新窗口的 `windowUsed == 0` 且旧句柄不被二次释放（`HandleTable.liveCount` 回基线）。

变异：

- `recycleWin` 不清 `appendIds` ⇒ 第 2 条必须变红（旧槽被误释放 / 计数不回基线）；
- 池上限改成无界 ⇒ 功能仍绿（只是内存），由静态审查保证。
