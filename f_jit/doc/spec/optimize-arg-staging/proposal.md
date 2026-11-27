# 调用路径：实参暂存区（先测后判）

## Why

`JitExecutor.invokeOff` 每次调用把 `cells` 反向拷贝进一块 `LibC.malloc` 的 native 内存，
调用结束后 `free`。`optimize-call-path.md` §12.1 曾把「实参路径」记为约 **350–400 ns/参**
（1 参比 0 参多 394 ns、4 参多 1407 ns），并据此建议「改线程私有暂存区」。

但该 394 ns 是**端到端差值**，包含调用点的 `[Int64(i)]`（`Array<Any>` 构造）、`CallMarshal.marshalArg`、
`pin`/窗口记账，以及 `invokeOff` 的 `malloc + 反向拷贝 + free`。本变更先把这个差值拆开，
**只有当 `invokeOff` 自身的原生分配确实占 ≥MOV 时才改**。

## What Changes

**测量项（不改产品代码）**：

| 测量 | 参考值（历史探针） |
| --- | --- |
| `LibC.malloc(8) + free` | 21–39 ns/次 |
| 反向拷贝（n=1） | ~5–10 ns |
| `JitContext.create + free`（含 8 次写 + 2 原子 + malloc） | 132–133 ns（TLS 合并后） |

**判定规则**：若 `invokeOff` 的 malloc + 拷贝合计 ≥ 单次调用的 MOV（≥8.4%，约 300 ns），
则实施线程私有暂存缓冲；否则**不做**，并在 `verify.md` 记录数据。

**若达标才实施的方案**（备选，不在本次落地）：

- 把 `rs` 传入 `JitExecutor.invoke`（需改 `body` 闭包签名）或新增 `invokeWith(rs, ctx, cells)`；
- 暂存缓冲放 `RuntimeState`（`ArrayList<Array<Int64>>` 按深度复用）；
- 每次调用只写 `n` 个 cell、不 `malloc/free`。

## Impact

- 预期：`invokeOff` 自身成本 **21–49 ns**（malloc 21–39 + 拷贝 5–10），占单参调用 **<1.5%**；
  低于 MOV，**按硬规则不做**；
- 影响文件：无（仅测量与判定）；
- 风险：若强行引入 `RuntimeEnv.current()` 取暂存区，每次多 1 次 TLS（≈300 ns），**净负收益**。
