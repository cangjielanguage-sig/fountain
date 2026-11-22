# 记录 f_jsonrpc.batch 的 local 阻断

## Why

`docs/LocalMode.md` 2.5 的 `JsonRpcClient.batch`（107-152）一行仍标为待评估。探针确认 `batch` 的四个临时集合中，两个受 local 的逃逸/返回规则限制，剩下两个的收益相对一次 HTTP 往返可忽略。

**阻断 1：`requests` 逃逸**
`requests: ArrayList<JsonValue>` 被传给 `JsonArray(list: requests)`（普通参数）。探针：本地集合传给普通参数报

```text
expected 'Class-ArrayList<String>', found 'Class-ArrayList<String> @local!'
```

**阻断 2：`responses` 不能返回**
`responses` 以 `responses.toArray()` 作为返回值。探针：本地集合的 `toArray()` 返回 `Array<String> @local!`，与堆返回类型不匹配，且 `toArray` 在 local 实例上无匹配重载。

**收益判断**
`ids` 与 `byId` 只在本函数内使用，理论上可 local。但 `batch` 的主体是一次 HTTP 往返（`sendWithRetry`）加 JSON 解析/序列化；两个小集合的分配与之相比可忽略。

## What Changes

- **只更新 `docs/LocalMode.md`**：f_jsonrpc 的 `batch` 行记录两条阻断与收益判断。
- **不改生产代码与测试**：`batch` 的行为与现有测试保持不变。

## Capabilities

无（纯文档，`.openspec.yaml` 设置 `skip_specs: true`）。

## Impact

- 文档：`docs/LocalMode.md` 一行。
- 代码/测试：无变化。
