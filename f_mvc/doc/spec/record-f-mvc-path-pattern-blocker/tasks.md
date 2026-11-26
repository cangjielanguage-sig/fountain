# 任务：记录 f_mvc 路径提取阻断

> 纯文档变更：不改生产代码、不加测试。目标是把两条阻断写进 `docs/LocalMode.md`。

## 1. 阻断确认

- [x] 1.1 探针：`HashMap<Int64, Any>() @ local!` 下标赋值报 `cannot assign to this subscript expression`（验证：独立探针编译失败，错误文本已记录）
- [x] 1.2 探针：`Map<Int64, Any> @ local?` 与具体 `HashMap<Int64, Any> @ local?` 上的 `add`/`remove`/`size` 均报 `no matching function declaration`（验证：两次探针编译失败）
- [x] 1.3 代码确认：`extractVariablesInPath` 每变量一次 `split("/")` + 完整 `HashMap<String, String>`；`HttpRequestPathPatterns.extract` 为抽象成员（验证：`HttpRequestDistributorImpl.cj:18-21`）
- [x] 1.4 确认既有 `PathPattern_test` 已覆盖提取路径（验证：3 条 `extractVariablesInPath` 用例，共 22 条）

## 2. 文档

- [x] 2.1 `docs/LocalMode.md` 2.5 表 f_mvc 行改为阻断结论（验证：行内含 `Any` 与 `no matching function declaration`）
- [x] 2.2 同文档「需前置设施的下游模块」说明补充「每变量全量解析 + 抽象接口锁死」（验证：行内含 `每变量` 与 `抽象成员`）

## 3. 回归与提交

- [x] 3.1 `cd f_util && cjpm test` 全绿（验证：Summary FAILED 0）
- [x] 3.2 生产代码零改动（验证：`git diff -- f_util f_mvc` 为空）
- [x] 3.3 提交到 `feature/local-mode-f-mvc-path-pattern`（验证：`git log -1 --stat` 只含文档与变更目录）

## Workflow follow-up

- 推送 `feature/local-mode-f-mvc-path-pattern`，合并回 `sts/1.3.x-LocalMode`。
- 执行 `opsx:verify`，通过后 `opsx:archive`。
