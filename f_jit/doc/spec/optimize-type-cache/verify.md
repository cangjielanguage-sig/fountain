# 验证记录：`optimize-type-cache`

> 环境：共享 7 核 A53 VM（load 4.2–6.3），`taskset -c 0-4`，`cjpm test --parallel 1`。
> 本轮呈双峰（整机状态），按峰比较。

## 1. 基线（改动前）

`localTypeOf` 分项（同轮探针，已删）：

| 测量 | 数据 |
| --- | --- |
| `TypeInfo.of<T>()` + `.name.size` | 103 ns |
| `TypeInfo` 引用稳定性（1000 次 `refEq`） | 1000/1000 相同 |
| `localTypeOf<注册类>` | 1650 ns（占慢峰 `L1` 27%） |
| `localTypeOf<Int64>` | 381 ns |

端到端（透传注册类实参 `{ u: PerfCacheUser => u }`，50k 次，best-of-3）：

| 臂 | 3 次原始值（ns/call） |
| --- | --- |
| 无缓存（`typeCodeOf` 恒不命中，等价旧实现） | **16654 / 9748 / 8716** |
| 有缓存 | **13023 / 6845 / 7019** |

## 2. 判定

| 峰 | 无缓存 → 有缓存 | Δ |
| --- | --- | --- |
| 慢峰 | 16654 → 13023 ns | **−21.8%** |
| 快峰 | 8716–9748 → 6845–7019 ns | **−22% ~ −28%** |

节省 **1.7–2.7 µs/调用**，与分项预测（1.5 µs）同量级；**keep**（远超 MOV）。

说明：端到端绝对值高于 `call<Int64>`（透传注册类还要走 `isInstanceOfHost`、`pinHostObject`、
`escapeAndGetTyped`），本项只归因于 `localTypeOf` 的差值。

## 3. 正确性

- 全量 **1227/1227 / 0 失败**（新增 3 条 `TypeCodeCache_test`）。
- 新增护栏：
  1. `alternatingTypesDoNotCross`：`Int64` 与 `Bool` 交替 100 次，结果逐个正确；
  2. `repeatedSameTypeIsStable`：同 T 连续 1000 次结果一致；
  3. `contractErrorUnchanged`：`call<Object>` 仍抛 19，之后 `call<Int64>` 正常（缓存未被污染）。

## 4. 变异

| 变异 | 预期 | 实测 |
| --- | --- | --- |
| `refEq(ti, info)` → 恒 false（等价无缓存） | 功能仍绿、仅变慢 | 用于 A/B 臂；3 条护栏全绿 |
| `refEq(ti, info)` → 恒 true（串味） | 交替用例变红 | 待补（见下） |

## 5. 影响文件

- `src/runtime/RuntimeState.cj`：`typeCodes`（≤32 条）+ `typeCodeOf` / `rememberTypeCode`；
- `src/JitFunction.cj`：`localTypeOf<T>(rs)`，未命中走 `computeTypeCode` 并登记；
- 新增 `src/TypeCodeCache_test.cj`。

## 6. 残留

- `TypeInfo.of<T>()` 本身（103 ns）仍无法避免；4 线程下 std 反射缓存仍会争用（0.38×）。
  要彻底消除需宏/API 层在编译期拿码。
- 缓存表上限 32；超出后回落到现算路径（行为不变）。
