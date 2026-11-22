# 任务：UPDATE Column 键等价回归

> 结论先行：local 化被 `Any` 的 local 限定阻断，本变更只补回归网与审计记录，不改生产代码。
> `SqlPartial.cj` / `f_orm/cjpm.toml` 保持原样；公开 API 0 变化。

## 1. 现状与阻断确认

- [x] 1.1 探针：3 键 `HashMap<String, Any>` 普通构造 1,542 B/次、`@ local!` 120 B/次（验证：独立探针打印 `n=3 heapPerCall=1542 localPerCall=120`，运行后删除）
- [x] 1.2 探针：真实代码中 `HashMap<String, Any>() @ local!` 下标赋值被拒（`cannot assign to this subscript expression`，4 处）
- [x] 1.3 探针：local 映射读出的 `Any` 不能传给 `arg(Any)`（`mismatched types`，3 处）；`arg(values[idColumn])` 报 `unable to infer generic argument`
- [x] 1.4 测量：mock 下每次 UPDATE 总分配 16,763 B，中间映射 1,542 B（9%）（验证：基准打印 `allocPerCall=16763`）
- [x] 1.5 生产代码与 `cjpm.toml` 已还原（验证：`git status` 无这两处改动）

## 2. 等价回归网

- [x] 2.1 新增 `f_orm/src/base/SqlPartialColumnKey_test.cj`：实体 `OrmUpdateProbe`（`id`/`name`/`age`/`nick`→`nick_name`）与 `MOCKDB` 捕获辅助（验证：可编译，`cjpm test` 能发现用例）
- [x] 2.2 用例：`Array<(Column, Any)>` 与 `Map<String, Any>` 的 SQL 文本、参数序列逐项一致（验证：`arrayOverloadMatchesMapOverload` 通过）
- [x] 2.3 用例：带 id 的数组重载使用显式 id，与映射版本一致（验证：`arrayOverloadWithIdUsesExplicitId` 通过）
- [x] 2.4 用例：`Map<Column, Any>` 两个重载与映射版本一致（验证：`columnMapOverloadMatchesStringMap`、`columnMapOverloadWithIdMatches` 通过）
- [x] 2.5 用例：字段名键 `nick` 与列名键 `nick_name` 产生相同 SQL（验证：`fieldNameAndColumnNameBothResolve` 通过）
- [x] 2.6 `cd f_orm && cjpm test --filter "*SqlPartialColumnKey*"` 全绿（验证：5 条用例全 PASSED）

## 3. 回归与契约

- [x] 3.1 `cd f_orm && cjpm test` 连续两次全绿（验证：两次 Summary FAILED 0）
- [x] 3.2 生产代码无改动：`SqlPartial` 接口与四个重载签名不变（验证：`git diff -- f_orm/src f_orm/cjpm.toml` 只含新增测试文件）
- [x] 3.3 既有 SQL 文本与参数绑定用例全通过（验证：`SqlExecutorArgBranchesTest`、`ArgBindCountTest`、`ArgSqlTextTest` 等）

## 4. 产物与提交

- [x] 4.1 `docs/LocalMode.md` 的 f_orm 行回写阻断原因与 9% 上限（验证：行内含 `local 化被 Any 的 local 限定阻断`）
- [x] 4.2 镜像 `openspec/changes/test-f-orm-update-column-keys/` 到 `f_orm/doc/spec/test-f-orm-update-column-keys/`，两份逐文件一致（验证：`diff -r` 仅差 `.openspec.yaml`）
- [x] 4.3 `openspec validate test-f-orm-update-column-keys --strict` 通过（验证：输出 `is valid`）
- [x] 4.4 提交到 `feature/local-mode-f-orm-sql-partial`（验证：`git log -1 --stat` 只含预期文件）

## Workflow follow-up

- 推送 `feature/local-mode-f-orm-sql-partial`，合并回 `sts/1.3.x-LocalMode`，合并后再跑 `f_orm` 全量。
- 执行 `opsx:verify`，通过后 `opsx:archive` 并同步主规格。
