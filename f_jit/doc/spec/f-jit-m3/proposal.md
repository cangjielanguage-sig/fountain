# Proposal

## Why

补齐异构搬运（Any 15）与 JSON 内建句柄码 16–19：装箱/问答/强制转型 + 世界内可变 JSON API。

## What Changes

- H78 `any_box` / H79 `any_is` / H80 `any_as`（typecode + aux 描述符）
- JSON 内建码 16–19 与反引号字面量（kind 11 常量）
- H81 `json_get` / H82 `json_set` / H83 `json_new`
- frozen 标记与经读/拆箱的传播

## 范围

- 权威文档：design-m3.md（§5 helper 表 / §11 JSON）、jit-bytecode-m3.md（§0–§11）、plan-m3.md R0–R6
- 验收场景：见同目录 `specs/*/spec.md`（本目录的 spec delta 为该里程碑归档时的最终口径）。

## 归档说明

本文件按既有权威文档与代码**反写**（M3（Any 通道与 JSON 内建类型） 已归档），不补造过程记录；逐条实施顺序见
`tasks.md`，验收证据见同级 `verify.md`（若存在）与 `scenario-map.tsv`。
