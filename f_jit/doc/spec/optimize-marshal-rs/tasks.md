# 任务：`CallMarshal` 携带 `rs` + 惰性容器（`optimize-marshal-rs`）

> 纯内部优化（`skip_specs: true`）。编号 M = Marshal。
> 环境：`ssh running@172.16.105.2`，`cd .../.worktrees/f_jit/f_jit`，`unset CJPM_CONFIG`。

## M1 基线

- [x] M1.1 注册类透传 **6845 / 7019（快峰）、13023（慢峰）**；值型 `L1` **3502–3758（快峰）、5967（慢峰）**。
- [x] M1.2 `窗口 + pinHostObject + release` = **3127 ns**（其中 3 次 TLS ≈ 1.2 µs）。

## M2 护栏（实现前后都绿）

- [x] M2.1 `MarshalRs_test` 5 条：值型 1000 次、String 去重 200 次、注册类透传 100 次
      （含 `liveCount` 回基线）、异常后恢复、**实参丢弃后由 cleanup 释放**（变异补的）。
- [x] M2.2 `CallMarshal_test` / `CallMarshalM2_test` / `Q6Acceptance_test` 在全量中绿。

## M3a `rs` 传递

- [x] M3a.1 `CallMarshal(rs)` + `private let rs: RuntimeState`（保留无参构造兼容）。
- [x] M3a.2 `HandleTable` 增 `pinWith` / `pinAnyBoxWith` / `pinHostObjectWith` /
      `pinHostClosureWith` / `appendWith` / `appendHostObjectWith` / `popFreeWith` / `newSlotWith`。
- [x] M3a.3 `JitFunction.callLocked` 传 `rs`；`marshalArg` 改 rs 重载。
- [x] M3a.4 M2.1 + M2.2 全绿。

## M3b 惰性容器

- [x] M3b.1 `pinned` / `escaped` 改 `?ArrayList<Int64>` + `pinnedList()` / `escapedList()`。
- [x] M3b.2 `cleanup` / `escapedIds` / `moveTo` / `removeFrom` 处理 `None`。
- [x] M3b.3 M2.1 + M2.2 全绿。

## M4 A/B 与判定

- [x] M4.1 M3a：注册类快峰 6845/7019 → **6377**（−7~9%）、慢峰 13023 → **12195**（−6%）；**keep**。
- [x] M4.2 M3b：值型 `L1` 3502–3758 → **2870–3050**（**−13~18%**）、`Q1 +22%`；**keep**。
- [x] M4.3 两项均达 MOV，无回滚。

## M5 变异

- [x] M5.1 `cleanup` 跳过 `Some(xs)` 的释放 ⇒ `droppedArgIsReleasedByCleanup` **红**（其余 4 条绿）。
- [x] M5.2 `moveTo` 的 `None` 分支已由「透传用例 + liveCount」覆盖；无独立变异。
- [x] M5.3 恢复后 5 条全绿。

## M6 收口

- [x] M6.1 全量 **1236/1236 / 0 失败**。
- [x] M6.2 `verify.md`；镜像 `f_jit/doc/spec/optimize-marshal-rs/`；`openspec validate --strict`。
- [ ] M6.3 归档 `2026-11-27-optimize-marshal-rs`；提交并推送。
