# 设计：记录阻断，不改代码

## Context

两条阻断的证据见 `proposal.md`。补充代码位置：

- `f_util/src/PathPattern.cj:248-252`：`EXTRACTION` 模式创建 `HashMap<Int64, Any>`；
- `f_util/src/PathPattern.cj:274/287/309/341-343`：向该映射 `add` 变量名或 `ComplexPathNode`；
- `f_util/src/PathPattern.cj:366/380/394`：回溯时按索引 `remove`；
- `f_mvc/src/HttpRequestDistributorImpl.cj:21`：`extract(path, name)` 每次转发到 `extractVariableInPath`；
- `f_mvc/src/HttpRequestDistributorImpl.cj:18`：`HttpRequestPathPatterns` 为 `abstract sealed class`。

## Goals / Non-Goals

**Goals：**
- 把「local 化被 `Any` 阻断」与「每变量全量解析被抽象接口锁死」写进审计表。

**Non-Goals：**
- 不改 `PathPattern` 的提取算法（含 `**` 回溯）。
- 不改 `HttpRequestPathPatterns` / `HttpRequestDistributor` 的公开接口。
- 不为本模块新增测试（既有 22 条已覆盖提取路径）。

## Decisions

### D1 只记录，不实现

**替代方案（否决）**：

1. *把 `HashMap<Int64, Any>` 拆成 `HashMap<Int64, String>` + `HashMap<Int64, ComplexPathNode>`*：`Any` 阻断来自 std 集合方法在 local 语境下的签名，拆类型仍要把映射传进 `get` 的 `@ local?` 参数，实测同样 `no matching function declaration`。
2. *重写 `get` 的 EXTRACTION 分支，直接写入结果 `HashMap<String, String>`*：回溯逻辑按**索引** `remove`，改成按变量名删除需要额外的「索引→变量名」状态；`get` 是 190 行的回溯匹配器，风险远高于每请求几 KB 的分配。
3. *给 `extract` 增加已解析容器参数*：`HttpRequestPathPatterns` 是公开抽象成员，改动会波及所有实现与调用方。

### D2 文档落点

- `docs/LocalMode.md` 2.5 表 f_mvc 行：改为阻断结论；
- 同文档「需前置设施的下游模块」说明：补充每变量全量解析与抽象接口限制。

## Risks / Trade-offs

| 风险 | 处理 |
| --- | --- |
| 后续有人再次尝试 | 阻断原因、错误文本与代码行号都写入文档 |
| 文档与代码漂移 | 行号引用集中在 `PathPattern.cj` 的 248-394 与 `HttpRequestDistributorImpl.cj:18-21` |

## Migration Plan

- 纯文档，无迁移。回退：`git revert`。

## Open Questions

无。
