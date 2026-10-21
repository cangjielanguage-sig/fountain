# Proposal

## Why

让字节码能构造与访问宿主仓颉 class：反射自动注册 + 手工覆盖，成员访问降为预定义函数调用。

## What Changes

- `registerType<T>()` 反射自动注册（字段/方法/prop/静态/构造器）
- `@JitBind` 手工绑定覆盖反射实现（同一槽位替换）
- 构造器物化：`C(args…)` 走注册期合成的构造 helper
- 成员访问语法糖 `u.f` / `u.f = v` / `u.m(a)`

## 范围

- 权威文档：design-m2.md §12（成员访问增量）、jit-bytecode-m2.md §12/§15、plan-m2.md Q 系列
- 验收场景：见同目录 `specs/*/spec.md`（本目录的 spec delta 为该里程碑归档时的最终口径）。

## 归档说明

本文件按既有权威文档与代码**反写**（M2.1（宿主类注册与成员访问） 已归档），不补造过程记录；逐条实施顺序见
`tasks.md`，验收证据见同级 `verify.md`（若存在）与 `scenario-map.tsv`。
