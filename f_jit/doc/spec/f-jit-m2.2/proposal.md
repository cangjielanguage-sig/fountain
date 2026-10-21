# Proposal

## Why

让字节码接收并调用宿主仓颉闭包（13 型），并支持闭包捕获与提升组协作。

## What Changes

- HostClosure 形参（LocalType 13）与签名描述符
- `CALL_HOST` 四步（验签 → 调用 → 装箱 → 转码）
- H63 `host_call_trampoline` 与 per-signature 特化
- 闭包捕获描述符与提升组（`moveOutGroup`）

## 范围

- 权威文档：design-m2.md §4/§13、jit-bytecode-m2.md §1–§10/§13、plan-m2.md Q 系列
- 验收场景：见同目录 `specs/*/spec.md`（本目录的 spec delta 为该里程碑归档时的最终口径）。

## 归档说明

本文件按既有权威文档与代码**反写**（M2.2（宿主闭包通道） 已归档），不补造过程记录；逐条实施顺序见
`tasks.md`，验收证据见同级 `verify.md`（若存在）与 `scenario-map.tsv`。
