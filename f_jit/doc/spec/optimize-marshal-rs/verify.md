# 验证记录：`optimize-marshal-rs`

> 环境：共享 7 核 A53 VM，`taskset -c 0-4`，`cjpm test --parallel 1`。
> 本轮 load 5.1–7.4，呈双峰，按峰比较。

## 1. 基线（M1）

| 指标 | 数据 |
| --- | --- |
| 注册类透传 `{ u: ProbeUser => u }` | 6845 / 7019（快峰）、13023（慢峰） |
| 值型 `L1`（CallPathBench B1） | 3502 / 3758（快峰）、5967（慢峰） |
| `窗口 + pinHostObject + release` | 3127 ns（其中 3 次 TLS ≈ 1.2 µs） |

## 2. M3a：`CallMarshal` 携带 `rs`

注册类透传（50k 次，best-of-3）：

| 臂 | 数据 |
| --- | --- |
| 改前 | 6845 / 7019（快峰）、13023（慢峰） |
| M3a 后 | **6377**（快峰）、**12195**（慢峰） |

Δ：快峰 **−7~9%**、慢峰 **−6%**。判定 **keep**（≥MOV）。

## 3. M3b：惰性容器

值型 `L1` / `Q1`（3 次）：

| 运行 | L1 | Q1 | Q4 |
| --- | --- | --- | --- |
| 1 | **2995** | 333848 | 739818 |
| 2 | **2870** | 348364 | 723299 |
| 3 | **3050** | 327796 | 740400 |

对照改前快峰 `L1 3502–3758`、`Q1 266–285k`：

- `L1` **−13~18%**，`Q1` **+22%**，`Q4` 从 678–729k 升到 723–740k；
- 注册类路径持平（12188–12703 ns），符合预期：其 `pinned` 非空，惰性容器不省。

判定 **keep**。

## 4. 正确性

- 新增 `MarshalRs_test` 4 条：值型连续 1000 次、String 去重 200 次、注册类透传 100 次
  （含 `liveCount` 回基线）、异常后恢复；
- 全量 **1235/1235 / 0 失败**；
- `CallMarshal_test` / `CallMarshalM2_test` / `Q6Acceptance_test` 全绿。

## 5. 变异

| 变异 | 预期 | 实测 |
| --- | --- | --- |
| `cleanup` 的 `Some(xs)` 不遍历释放 | `liveCount` 增长 ⇒ 丢弃实参用例红 | **`droppedArgIsReleasedByCleanup` 红**（其余 4 条绿），已恢复 |

> 首版透传用例（`{ u => u }`）覆盖不到 `cleanup`：实参槽与返回值是**同一槽**，
> 由返回路径 `releaseEscaped` 释放。补了 `{ u => 1 }`（实参不进返回值）后才真正变红。

## 6. 影响文件

- `src/CallMarshal.cj`：`rs` 字段 + 两个惰性容器（`pinned` / `escaped`）；
- `src/runtime/HandleTable.cj`：`pinWith` / `pinAnyBoxWith` / `pinHostObjectWith` /
  `pinHostClosureWith` / `appendWith` / `appendHostObjectWith` / `popFreeWith` / `newSlotWith`；
- `src/JitFunction.cj`：`CallMarshal(rs)`；
- 新增 `src/MarshalRs_test.cj`。

## 7. 残留

- `escape + getAs + releaseEscaped`（约 0.5 µs）仍是返回值路径的固定成本，语义必需；
- `append`（路径 C，JIT 世界内分配）仍需 `currentWinOf(rs)` + `syncTo(ctx, rs)`，已 0 TLS；
- 编译 25–48 ms 未动（需分段 profile）。
