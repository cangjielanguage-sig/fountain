# Tasks

## 1. 定位

- [x] 1.1 复现：WSL 下 `f_data` `cjpm test` 编译失败，报 `interface function '!=(this @local!, other: Generics-T): Bool' must be implemented in 'DataTest'`，来源为 `DataAssist` 宏。
- [x] 1.2 探针确认（SDK 1.3.0-alpha.20261112001016）：`Comparable<X> & Equatable<X>` 同时出现即报错（即便 `!=` 已实现）；同一接口重复列出报 `duplicate interface`；只列其一均通过。

## 2. Red：钉住需求

- [x] 2.1 新增 `f_data/src/test/DataAssist_test.cj`：`OrderedItem` 显式 `Comparable & Equatable`、`DupDeclared` 显式 `Hashable & ToString & Equatable`。
- [x] 2.2 跑 `cjpm test`，确认修复前编译失败：`OrderedItem` 报 `duplicate interface 'Equatable'`、`DupDeclared` 报 `duplicate interface 'Hashable'`、`DataTest` 报 `!=` 模态错误（3 errors）。

## 3. Green：宏归一化

- [x] 3.1 `DataAssist.cj` 新增 `normalizeSuperTypes(decl)` + `superTypeText(t)`：完全重复项去重；有 `Comparable<X>` 时删 `Equatable<X>`。
- [x] 3.2 `assist()` 的 `ClassDecl` 分支在生成完成员后调用归一化。
- [x] 3.3 编译通过后新用例报 `compare` 断言失败（`GT` 期望、实际 `EQ`），定位到 `generateCompare` 只求值不赋值。
- [x] 3.4 修正 `generateCompare`：`result = f_data_cmp(...)`，`compare` 恢复按字段顺序返回真实顺序。
- [x] 3.5 `cjpm test` 全绿：165/165（含 `DataTest` 与新用例）。

## 4. 回归

- [x] 4.1 `f_data` 全量 `cjpm test` 165/165 PASSED。
- [x] 4.2 `f_data` / `f_codec` / `f_rpc` `cjpm build` 全部 `cjpm build success`。
- [x] 4.3 `f_codec` 全量 `cjpm test` 16/16 PASSED（其 `TestObject_test.cj` 同样用 `@DataAssist[props fields equal tostring]`）。

## 5. 文档与归档

- [x] 5.1 `f_data/README.md` / `README_en.md` 补充父接口归一化与 `compare` 语义说明；`DataAssist` 宏头注释同步。
- [x] 5.2 `openspec archive` + 产物落盘 `f_data/doc/spec/fix-dataassist-local-mode/`。
