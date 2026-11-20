# Tasks

## 1. 修正既有宽用例的契约外输入

- [x] 1.1 在 `f_orm/src/wrap/QueryResultWrap_test.cj` 的 `testEveryReaderBranchAndAlias` 里把 6 处 typeName 换成契约写法（c1 `text`→`String`、c5 `bytea`→`Array<UInt8>`、c7 `money`→`Decimal`、c14 `int4`→`UInt32`、c18 `float8`→`Float64`、c20 空串→`std.time.DateTime`），同步注释（空串口径、别名措辞）；验证：该用例转绿（RED 证据为当前 `bytea` 列的 `ORMException`）

## 2. 新增用例钉住「SQL 拼写按未识别类型处理」（RED）

- [x] 2.1 新增 `testSqlSpellingTypeNamesAreTreatedAsUnknown`：`numeric` + `Decimal`、`bool` + `Bool` 取值抛 `ORMException`；`text` + `String` 走兜底读出；在 WSL 跑 `cjpm test` 确认该用例失败（当前 `numeric`/`bool` 仍命中分支返回值，断言不成立），把失败输出记入本文件

## 3. 清理 `makeReader` 的方言 / 小写拼写（GREEN）

- [x] 3.1 在 `f_orm/src/wrap/QueryResultWrap.cj` 的 `makeReader` 删除 `string`、`char`、`text`、`varchar`（`String` 分支）、`numeric`（`Decimal` 分支）、`bool`（`Bool` 分支）；验证：任务 2.1 的用例转绿
- [x] 3.2 核对改动面：`git diff` 只含上述 6 个字面量的删除与测试文件改动，`makeReader` 的分支与读取类型、`QueryResultWrap` 公开签名、`toMap()`、`String` 兜底与异常文案均未变（逐项比对 diff；实测 `QueryResultWrap.cj` 仅 3 行改动）

## 4. 全量回归

- [x] 4.1 在 `f_orm` 目录跑全量 `cjpm test`，验证 TOTAL 中 ERROR / FAILED 均为 0（实测 TOTAL 65 / PASSED 65 / ERROR 0 / FAILED 0）
- [x] 4.2 在 `f_orm` 目录跑 `cjpm build`，验证构建 exit=0（实测 `cjpm build success`，仅 5 条既有 unused 警告）

## 5. 执行记录（RED / GREEN 证据）

- RED-1（任务 1.1 之前）：`testEveryReaderBranchAndAlias` ERROR，`ORMException:colum index: 5, column type: bytea, column name: c5, requires: Array<UInt8>`（`QueryResultWrap.cj:982`）。
- GREEN-1（任务 1.1 之后）：`QueryResultWrapTest` 5/5 PASSED（`EXIT=0`）。
- RED-2（任务 2.1 之后、3.1 之前）：`testSqlSpellingTypeNamesAreTreatedAsUnknown` FAILED，`Assert Failed: (true == caught)` —— `numeric` 仍命中 Decimal 分支，未抛异常。
- GREEN-2（任务 3.1 之后）：`QueryResultWrapTest` 6/6 PASSED。
- 全量：TOTAL 65 / PASSED 65 / ERROR 0 / FAILED 0；`cjpm build success`。

## Workflow follow-up

- 将四件套落盘到 `f_orm/doc/spec/fix-orm-queryresultwrap-type-alias/`（propose 后建副本，archive 后用最终版覆盖）。
- 用户评审 `design.md` / `tasks.md` 通过后再进入 apply。
- apply 完成、全量回归全绿后执行 `opsx:verify`，CRITICAL 清零再提交。
- 提交到 `sts/1.3.x` 并归档变更。
