# 设计：记录阻断，不改 batch

## Context

`batch` 的四个临时集合：

| 集合 | 用途 | local 可行性 |
| --- | --- | --- |
| `ids: ArrayList<JsonValue>` | 记录 id，最后按序回填响应 | 可（仅函数内使用） |
| `requests: ArrayList<JsonValue>` | 传给 `JsonArray(list:)` | 不可：本地集合不能传给普通参数 |
| `byId: HashMap<String, JsonRpcResponse>` | 响应按 id 索引 | 可（仅函数内使用） |
| `responses: ArrayList<JsonRpcResponse>` | `toArray()` 返回 | 不可：本地 `toArray()` 返回 `@local` 数组 |

## Goals / Non-Goals

**Goals：**
- 把两条阻断与「只省两个小集合、相对 I/O 可忽略」的结论写进审计表。

**Non-Goals：**
- 不改 `JsonArray` 的构造签名使其接收 `@ local?` 列表。
- 不改 `batch` 的返回类型（`Array<JsonRpcResponse>`）。
- 不为本行新增测试。

## Decisions

### D1 只记录

**替代方案（否决）**：

1. *把 `requests` 改为直接拼 JSON 文本*：需要绕过 `JsonArray`/`JsonValue`，重复序列化逻辑，且请求体 String 仍要分配。
2. *`responses` 改用预分配 `Array` 按 `ids.size` 填充*：可消除 `toArray` 拷贝（类似 f_mq），但 `batch` 的分配主体是请求/响应 JSON 与网络，收益与改动面不匹配；且 `byId`/`ids` 仍无法避免。
3. *给 `JsonArray` 增加 `@ local?` 构造*：跨模块改 f_data 的公开类型，影响面过大。

### D2 文档落点

`docs/LocalMode.md` 2.5 的 `JsonRpcClient.batch` 行。

## Risks / Trade-offs

| 风险 | 处理 |
| --- | --- |
| 后续重复评估 | 错误文本与集合用途写入文档 |
| 结论随实现漂移 | 行号指向 `JsonRpcClient.cj:107-152` |

## Migration Plan

- 纯文档。回退：`git revert`。

## Open Questions

无。
