# Tasks

> 全程 TDD：每组先写失败用例（Red）→ 最小实现（Green）→ 重构。

## 1. 模块骨架

- [x] 1.1 `f_a2a/src/model` 建包 + `imports.cj` 门面；验证：`cd f_a2a && cjpm build` 通过。
- [ ] 1.2 `.modules` 已登记 `f_a2a`（已完成）；验证：`grep -x f_a2a .modules` 命中。

## 2. 数据模型

- [x] 2.1 `A2aPart` / `A2aMessage` / `A2aArtifact` 定义与 JSON 往返；验证：往返用例（含空 `parts` 的错误分支）。
- [x] 2.2 `A2aTask` + `A2aTaskState` + `isTerminal()`；验证：`input-required` 非终态、其余终态（表驱动）。
- [x] 2.3 `A2aAgentCard` / `A2aCapabilities` / `A2aSkill` 序列化；验证：`capabilities.streaming=false`、`defaultInputModes=["text/plain"]`。

## 3. 服务端

- [x] 3.1 `A2aTaskStore` 接口 + `InMemoryA2aTaskStore`（`Mutex`、返回副本）；验证：save→get 相等但非同一对象（改副本不影响存储）。
- [x] 3.2 `A2aExecutionResult` 三态 + `A2aExecutor` 接口。
- [x] 3.3 `A2aServer.register()` 幂等注册三个方法；验证：连续两次注册后方法名集合不变。
- [x] 3.4 `message.send` 三条终态路径（completed / input-required / failed）；验证：3 条用例。
- [x] 3.5 非文本 `Part` → `-32023`；验证：抛 `JsonRpcException` 且码匹配。
- [x] 3.6 `tasks.get` / `tasks.cancel`：未知 id → `-32020`，终态取消 → `-32021`，working 取消 → `canceled`；验证：3 条用例。
- [x] 3.7 执行器抛异常 → `failed` + `statusMessage` 带原因、日志 warn；验证：1 条用例。

## 4. 客户端

- [x] 4.1 `A2aClient.send/get/cancel/close`；验证：对着进程内 `A2aServer` 走一轮真 HTTP（或 `JsonRpcClient` 桩）完成 send→get→cancel。
- [x] 4.2 错误透传：服务端 `-32020` → 客户端同码；验证：1 条用例。

## 5. 文档

- [ ] 5.1 `f_a2a/README.md` / `README_en.md` 与最终 API 同步（签名、错误码表）。
- [ ] 5.2 `f_a2a/doc/a2a-protocol.md` 与实现核对：任何偏差回写文档。

## 6. 集成

- [ ] 6.1 `cd f_a2a && cjpm test` 全绿（覆盖设计文档 §8 的 12 条矩阵）。
- [ ] 6.2 回归：`cd f_jsonrpc && cjpm test` 不受影响（新增模块不改既有 API）。
- [ ] 6.3 `openspec validate add-f-a2a --strict` 通过。

## Workflow follow-up

- 归档 `add-f-a2a` → 覆盖 `f_a2a/doc/spec/add-f-a2a/` 四件套。

## 7. 流式与扩展能力（依赖 `add-jsonrpc-sse`）

- [x] 7.1 `message/stream`：建任务 + 执行 + 通过 `SseHub.publish` 推 `a2a.task.status` / `a2a.task.artifact`；验证：`working` → `completed` 两条事件、id 递增。
- [x] 7.2 `tasks/resubscribe`：按 `taskId` 重订阅、透传 `Last-Event-ID`；已终结任务立即补终态后结束；验证：1 条用例。
- [x] 7.3 push notification：`pushConfig.set/get/delete` + 终态回调（`f_httpclient` POST，失败只 warn）；验证：3 条用例。
- [x] 7.4 非文本 `Part`：`file`（url + mimeType）/ `data`（JSON 字符串）/ 未知 kind → `-32023`；验证：3 条用例。
- [x] 7.5 扩展卡片 `a2a.agent.extendedCard`：基础卡片 + `x-a2a-extensions`；验证：2 条用例。
