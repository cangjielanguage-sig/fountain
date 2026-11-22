# 任务：记录 f_jsonrpc.batch 阻断

> 纯文档变更：不改生产代码、不加测试。

## 1. 阻断确认

- [x] 1.1 探针：本地 `ArrayList<String> @ local!` 传给普通参数报 `expected 'Class-ArrayList<String>', found 'Class-ArrayList<String> @local!'`
- [x] 1.2 探针：本地 `ArrayList<String>` 的 `toArray()` 返回 `Array<String> @local!`，不能作为堆返回值；local 实例上无 `toArray` 匹配重载
- [x] 1.3 代码确认：`batch` 中 `requests` 传给 `JsonArray(list:)`、`responses.toArray()` 作为返回值（验证：`JsonRpcClient.cj:107-152`）
- [x] 1.4 收益判断：`ids`/`byId` 可 local，但主体是一次 HTTP 往返与 JSON 解析（验证：`sendWithRetry` / `parseValue` 为热点）

## 2. 文档

- [x] 2.1 `docs/LocalMode.md` 的 `JsonRpcClient.batch` 行改为阻断结论（验证：行内含 `JsonArray` 与 `toArray`）

## 3. 回归与提交

- [x] 3.1 `cd f_jsonrpc && cjpm test` 全绿（验证：Summary FAILED 0）
- [x] 3.2 生产代码零改动（验证：`git diff -- f_jsonrpc` 为空）
- [x] 3.3 提交到 `feature/f-jsonrpc-batch-assessment`（验证：`git log -1 --stat` 只含文档与变更目录）

## Workflow follow-up

- 推送 `feature/f-jsonrpc-batch-assessment`，合并回 `sts/1.3.x-LocalMode`。
- 执行 `opsx:verify`，通过后 `opsx:archive`。
