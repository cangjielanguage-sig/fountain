# 设计：实参暂存区（判定记录）

## D1 拆解 394 ns/参

`optimize-call-path.md` §12.1 的「1 参比 0 参多 394 ns」包含四段：

| 段 | 归属 | 估算 |
| --- | --- | --- |
| `[Int64(i)]` 构造 `Array<Any>`（调用点） | **测试代码**，不是产品路径 | ~170 ns |
| `CallMarshal.marshalArg` + `pinned.add` | 产品（桥） | ~50–100 ns |
| `Array<Int64>(1)` cells 分配 | 产品（桥） | ~170 ns |
| `invokeOff` 的 malloc + 反向拷贝 + free | 产品（执行器） | **21–49 ns** |

只有最后一段能被「暂存区」消除，而它 **<1.5%**。

## D2 为什么不能顺手用 `RuntimeEnv.current()`

`invokeOff` 在 `backend` 包，拿 `RuntimeState` 要 `RuntimeEnv.current()`（1 次 TLS ≈ 300 ns）。
暂存区省下的是 21–49 ns，**净负 250 ns**。要避免这次 TLS，必须把 `rs` 从 `JitFunction.call`
一路传到 `JitExecutor.invoke`，即改 `body: (JitContext, Array<Int64>) -> Int64` 的签名
（影响 `CompilePipeline`、闭包包装器与全部测试）——成本远大于收益。

## D3 什么时候值得重做

- `ThreadLocal` 单次访问降到 <30 ns；或
- `body` 签名因其它原因（例如 GC 暂存）需要携带 `rs`；
- 或 `cells` 分配与 ctx 一起池化时，顺带把 native 参数块也池化。

届时应重新测量 `invokeOff` 单次成本，再按 MOV 判定。

## D4 结论

**不做。** 本变更只留下测量与判定记录，不改任何产品代码。
