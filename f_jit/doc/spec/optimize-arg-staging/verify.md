# 验证记录：`optimize-arg-staging`（判定：不做）

## 1. 测量

| 项 | 数据 | 来源 |
| --- | --- | --- |
| `LibC.malloc(8) + free` | 21–39 ns/次 | 2026-11-27 探针 |
| 反向拷贝（n=1） | ~5–10 ns | 同上 |
| `JitContext.create + free`（8 写 + 2 原子 + malloc） | 132–133 ns | TLS 合并后探针 |
| 端到端 1 参 − 0 参 | 394 ns | `optimize-call-path.md` §12.1 |

## 2. 拆解

| 段 | 是否产品路径 | 估算 |
| --- | --- | --- |
| 调用点 `[Int64(i)]`（`Array<Any>`） | 否（测试代码） | ~170 ns |
| `marshalArg` + `pinned.add` | 是 | ~50–100 ns |
| `Array<Int64>(1)` cells | 是 | ~170 ns |
| **`invokeOff` malloc + 反向拷贝 + free** | 是（可优化目标） | **21–49 ns** |

## 3. 判定

`invokeOff` 自身的原生分配与拷贝合计 **21–49 ns**，占单参调用（约 3.5–6 µs）的 **<1.5%**，
低于 MOV（8.4%，约 300 ns）。按硬规则 **不做**。

若要引入暂存区，`backend` 包取 `RuntimeState` 需 `RuntimeEnv.current()`（≈300 ns/次），
**净负收益**；避免它必须改 `body` 闭包签名（影响 `CompilePipeline` 与全部测试），成本远超收益。

## 4. 影响

- 无代码改动、无新增测试；全量基线保持 **1230/1230**。
- 重做条件：`ThreadLocal` 降到 <30 ns，或 `body` 已因其它原因携带 `rs`。
