# 设计：`CallMarshal` 携带 `rs` + 惰性容器

## D1 `rs` 的传递路径

```
JitFunction.call → callLocked(rs) → CallMarshal(rs) → marshalArg → HandleTable.pinXxxWith(rs, …)
```

- `rs` 在 `callLocked` 开头已经取到（`optimize-runtime-tls`），`CallMarshal` 只是一次调用内的
  局部对象，生命周期与 `rs` 同线程、同调用；
- `CallMarshal` 不缓存 `RuntimeState` 到跨调用结构，不存在「线程迁移」问题。

## D2 `HandleTable` 的 rs 重载清单

| 旧入口 | 新入口 | 内部替换 |
| --- | --- | --- |
| `pin(obj)` | `pinWith(rs, obj)` | `currentWinOf(rs)`、`popFree(rs)`、`newSlot(rs, …)` |
| `pinAnyBox(v)` | `pinAnyBoxWith(rs, v)` | 同上 |
| `pinHostObject(o)` | `pinHostObjectWith(rs, o)` | 同上 |
| `pinHostClosure(v, sig)` | `pinHostClosureWith(rs, v, sig)` | 同上 |
| `appendHostObject(ctx, o)` | `appendHostObjectWith(ctx, rs, o)` | `currentWinOf(rs)` + `append` 内的 rs 版 |

旧入口保留为「`RuntimeEnv.current()` + 新入口」的薄包装，测试与其它调用点不受影响。

`newSlot` / `popFree` 加 `rs` 参数；`growSlot` 仍是全局 `mtx`（每 1024 槽一次，冷路径）。

## D3 惰性容器

```cangjie
private var pinned: ?ArrayList<Int64> = None
private var escaped: ?ArrayList<Int64> = None

private func pinnedList(): ArrayList<Int64> {
    match (this.pinned) {
        case Some(x) => x
        case None =>
            let x = ArrayList<Int64>()
            this.pinned = Some(x)
            x
    }
}
```

- `add` 走 `pinnedList().add`；
- `cleanup`：`match (this.pinned) { case Some(x) => 遍历并释放; case None => () }`；
- `moveTo(from, to, id)`：`from` 为 `None` 时直接把 id 加到 `to`（保持原语义：未 pin 的返回句柄也要登记）；
- `escapedIds()`：`None` → 空数组。
- `closureGroup` 已是 `?PromotionGroup`，不变。

## D4 语义等价

- 句柄去重顺序：`winPinSize(w)` 仍是 `appendIds + pins`；只是 `pins` 的写入改走 `pinnedList()`；
- 清理时机：`cleanup()` 仍在 `finally`，`pinned` 为空时直接返回（原来遍历空 ArrayList，等价）；
- 窗口记账：`newSlot` 的 8 个数组写、`makeId`、`freeOrRetire` 一行不改。

## D5 护栏与变异

新增 `MarshalRs_test`：

1. **值型调用不建容器**：`call<Int64>` 后 `CallMarshal` 不可见（局部对象），改为断言
   「连续 1000 次值型调用无异常、结果正确」+ 性能 A/B；
2. **句柄实参仍去重**：同一 String 实参连续两次调用，窗口内不重复 pin（`call<String>` 结果正确）；
3. **注册类实参 + 返回**：`{ u: ProbeUser => u }` 交替 100 次，返回同一对象、无失效句柄；
4. **异常路径清理**：`call<Object>` 抛 19 后，下一次正常调用不受影响（`pinned` 已清）。

变异：

- `popFree` 忽略 `rs`（改回 `RuntimeEnv.current()`）⇒ 功能仍绿、只是慢（用 A/B 证明，不用断言）；
- `cleanup` 在 `Some` 时不释放 ⇒ 第 4 条 / `liveCount` 类用例变红；
- `moveTo` 在 `from=None` 时不登记 ⇒ `retType=14` 的返回句柄泄漏（`liveCount` 增长）。
