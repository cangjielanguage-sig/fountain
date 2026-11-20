# 审查范围（f_mq + fmq 全量审计）

## 审查目标

对 `f_mq` 与 `fmq` 两个模块的**全部代码与文档**做完整审计，回答三个问题：

1. **功能完备性**：模块对外承诺的能力（spec/README/详细设计）是否都有实现，是否存在缺失、半成品、占位实现。
2. **测试覆盖**：每条需求/关键分支是否有对应用例；是否存在只测 happy path、断言缺失、覆盖盲区。
3. **空实现**：空测试用例（`@TestCase` 函数体为空、无断言、仅 `@Assert(true)`）、空函数（空体、仅 `return`/`throw NotImplemented`）、被注释/跳过的测试、TODO/FIXME/占位代码。

## 审查模式

- **全树审计，不是 diff 审查**：审查对象是 `f_mq/**` 与 `fmq/**` 的当前内容（HEAD 5a133474）。
- 因此跳过 Code Review Harness 的「阶段零：squash merge」：`feature/mq` 已全部合入 `sts/1.3.x`，两者没有待审查差异；创建 squash 分支会产生空变更。
- 源分支（信息性）：`feature/mq`；目标分支（信息性）：`sts/1.3.x`。
- 项目根目录：`/storage/Users/currentUser/Documents/cangjie/projects/fountain/.worktrees/mq`

## 范围清单

- 代码：`f_mq/src/**`（46 个 `.cj`）、`fmq/src/**`（54 个 `.cj`），合计 100 个源文件，其中 39 个 `*_test.cj`。
- 文档：`f_mq/README.md`、`f_mq/README_en.md`、`f_mq/doc/**`（开发计划、详细设计、历史变更 spec）、`fmq/README.md`、`fmq/README_en.md`、`fmq/doc/**`（backlog、开发计划、详细设计、历史变更 spec）。
- 构建/测试配置：`f_mq/cjpm.toml`、`fmq/cjpm.toml`、`scripts/mq_e2e.sh`、`scripts/mq_e2e_client/**`（仅作为测试覆盖证据，不审实现质量）。

## 轮次规划

| 轮次 | 范围 | 重点 |
|---|---|---|
| R1 | `f_mq/src/base/**`（协议、常量、载荷、消息记录、错误码、模型）+ `f_mq` 协议类 spec/详细设计 | 协议编解码完备性、错误码覆盖、`publishTime` 等边界 |
| R2 | `f_mq/src/client/**`、`f_mq/src/exception/**`、`f_mq/src/f_mq.cj` + `specs/f-mq/client` + README | 客户端连接/发现/重连/路由、失败路径、用例覆盖 |
| R3 | `fmq/src/meta/**`、`fmq/src/cluster/**` + `specs/fmq/metadata-cluster` + 详细设计对应章节 | 元数据持久化、同步、节点注册、故障恢复、一致性 |
| R4 | `fmq/src/queue/**` + `specs/fmq/queue-storage`、`consume-semantics` + 详细设计对应章节 | 分段日志、游标、ack/重投/死信/延迟、并发与恢复 |
| R5 | `fmq/src/server/**`、`fmq/src/manager/**`、`fmq/src/metrics/**`、`fmq/src/config/**`、`fmq/src/main.cj`、`fmq/src/MQUsage.cj` + `specs/fmq/server-runtime`、`manager-cli`、`metrics` + README | 服务端生命周期、命令分发、CLI、统计口径、关闭清理 |
| R6 | 跨模块测试质量与文档-实现追踪（全部 `*_test.cj` + 全部 spec/README/详细设计） | 空测试/空函数/TODO 全局扫描；需求→实现→用例矩阵；文档与代码不一致 |

## 判定口径

- **严重**：功能缺失或与 spec 矛盾；数据正确性/持久化/一致性问题；空实现冒充完成；测试无法发现该缺陷。
- **一般**：边界条件缺失、错误处理不足、用例覆盖明显不全、文档与实现不一致。
- **建议**：命名、结构、可读性、重复代码等不影响正确性的改进。
- 每条问题必须给出 `文件:行号`、现象、影响；不得只给结论。
- reviewer 为只读角色：不得修改任何被审查文件，不得运行会改变仓库状态的命令。

## 输出

- `review_v1.md` … `review_v6.md`：各轮详细报告。
- `todo.md`：汇总所有「严重 + 一般」问题（按 R1…R6 分组）。
