# Proposal

## Why

补齐 `as T` / `as T ?? V`、`$as$<C>` 运行期判定与闭包签名适配，使 M2 的宿主互操作闭合。

## What Changes

- `as T` / `as T ?? V` 的静态与运行期两层语义
- 注册期合成 `$as$<C>`（`(14) -> Bool`）
- H77 `cast_fail`（失败 = 7，与 22 严格区分）
- `@JitSignatures` 生成的闭包 adapter

## 范围

- 权威文档：design-m2.md §12.4/§16、jit-bytecode-m2.md §12/§16、plan-m2.md Q 系列
- 验收场景：见同目录 `specs/*/spec.md`（本目录的 spec delta 为该里程碑归档时的最终口径）。

## 归档说明

本文件按既有权威文档与代码**反写**（M2.3（类型化转型与签名适配） 已归档），不补造过程记录；逐条实施顺序见
`tasks.md`，验收证据见同级 `verify.md`（若存在）与 `scenario-map.tsv`。
