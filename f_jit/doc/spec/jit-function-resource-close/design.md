# Design

## 1. 接口落点

`JitFunction` 声明改为 `public class JitFunction <: Resource`（`std.core.Resource` 由 core 包隐式可见，仓内 `Store` / `HttpClient` 同用法，无需 import）。

| 成员 | 签名 | 语义 |
|---|---|---|
| `close()` | `Unit` | `Resource` 契约：不等待（`let _ = this.close(0)`） |
| `close(timeoutMs)` | `Bool` | 原 `unload(timeoutMs)`：排空 + 超时回退 |
| `isClosed()` | `Bool` | 入口：`state==2`；包装：条目 `state==2`（含级联） |
| `closeClosure(timeoutMs)` | `Bool`（private） | 原 `unloadFn` 内核，`close` 分派调用 |

删除：`unload`、`unload()`、`isUnloaded()`、`prop isClosed`。行为（级联、排空、超时回退、弱语义、缓存逐出）一律不变。

## 2. 为什么 `isClosed` 必须是方法

`Resource` 要求 `func isClosed(): Bool`；同一类型上不能同时存在同名属性与方法。改为方法后语义统一：**入口 = 单元已卸载，包装 = 本闭包已释放**（原来 `prop isClosed` 只描述包装，入口恒 false、`isUnloaded()` 另说一套）。

## 3. 迁移面

- 定义：`JitFunction.cj`（类声明、三处方法改名/合并、删除 `isUnloaded`）。
- 调用点：`f_jit/src` 下 13 个文件（47 处 `unload(`、23 处 `isClosed`/`isUnloaded`），统一改 `close(...)` / `isClosed()`；断言需要布尔结果的用 `close(0)`，纯语句用 `close()`。
- `Range.isClosed` 等标准库属性读取**不得**改写（批量替换已回滚 4 个 runtime 文件）。

## 4. 测试

新增 `resourceContractOnUnitAndWrapper`：入口与包装都能以 `Resource` 接口使用 `close()` / `isClosed()`；`entryCloseIsUnitLevel` 固定入口 `isClosed()` 随单元状态。全量回归 `f_jit`（1153 条）。

## 5. 已知边界

- `close()` 丢弃排空结果：需要「现在能不能关」判定的调用方必须用 `close(timeoutMs)`。
- B5（闭包内部重入关闭自己）不变：`active≥1` → 超时/立即回退 `false`。
