# Verify 报告 — add-f-jsonrpc

> 校验方式：`opsx:verify` 通道不可用——融合侧默认 SDK 为 `1.3.0-alpha.20261023001052`，
> 该版本的 `std.core.Exception` 已移除 `causedBy` 与 cause 构造，仓库 `f_base` 无法编译；
> 本次全部构建/测试在 `1.3.0-alpha.20261016001051`（兼容 SDK）下完成。
> 因此按 `openspec-workflow.md` 步骤 5 的回退执行：`openspec validate --strict` + 人工三对齐。

## Completeness

| 项 | 结果 | 证据 |
|---|---|---|
| tasks 全部完成 | ✅（12.3 / 12.4 在交付时勾选） | `tasks.md` |
| delta 规格每条需求有落点 | ✅ | 见下表 |
| 未实现项是否已声明 | ✅ | design 风险表、tasks 11.4 说明 |

需求 → 落点：

| 需求 | 实现 | 用例 |
|---|---|---|
| 单请求处理 | `JsonRpcServer.processOne` / `resolve` | `testSingleRequest`、`testMethodNotFound` |
| 批量与通知 | `JsonRpcServer.handleBatch` | `testBatchMixedNotifications`、`testAllNotificationsBatchReturnsNone`、`testEmptyBatch`、`testBatchTooLarge`、`testNotificationReturnsNone` |
| id 保真 | `processOne` 原样搬运 id；`respondOk` | `testBigIntegerIdPreserved`、`testStringIdPreserved`、`testNullIdIsNotNotification` |
| 方法表与元数据 | `JsonRpcServer.addMethod/methods`、`JsonRpcMethodMeta` | `testDuplicateMethodThrows`、`testMethodsSorted`、`testMethodMetaFields` |
| topic 命名空间 | `resolve` | `testTopicNamespaceMatch`、`testTopicNamespaceCross`、`testUnknownTopic`、`testTopicRejectsMethodsWithoutDot` |
| 错误码与错误对象 | `JsonRpcProtocol`、`JsonRpcError`、`respondError` | `testBusinessErrorKeepsData`、`testInternalErrorIsGeneric` |
| 请求形态校验 | `processOne` | `testMissingVersion`、`testMethodNotString`、`testBatchPartialInvalid` |
| 编码与大限 | `handle` 解析/大小检查 | `testParseError`、`testEmptyBodyIsParseError`、`testInvalidUtf8IsParseError`、`testBodyTooLarge` |
| 参数校验接线 | `checkParamsEx` + `f_data.JsonSchemaValidator` | `testSchemaValidation`、`testSchemaValidationMissingParams`、`testNoSchemaSkipsValidation` |
| 单方法超时 | `invokeHandler`（`spawn` + `Future.get(timeout)`） | `testTimeout`、`testNoTimeoutWaitsForHandler` |
| 响应头写回 | `JsonRpcContext.setResponseHeader` | `testSetResponseHeaderWithoutHttpIsNoop` |
| HTTP 接入注解 | `JsonRpcMapping`、`JsonRpcController` | `testAnnotationFixesProtocolFields`、`testControllerMethodIsRegisteredAsPostRoute`、`testTopicMethodIsRegistered` |
| 客户端 | `JsonRpcClient` / `HttpJsonRpcTransport` | `testCallBuildsRequestAndReturnsResult`、`testCallSendsParams`、`testServerErrorThrows`、`testNotifyHasNoId`、`testBatchKeepsInputOrder`、`testCloseClosesTransport` |
| 紧凑序列化 | 全部响应/请求走 `toString()` | 上述用例解析响应字节 |

## Correctness

实测（兼容 SDK，融合侧 Linux aarch64）：

| 模块 | 用例数 | 结果 |
|---|---|---|
| `f_data` | 156 | 156 passed / 0 failed / 0 error |
| `f_mvc` | 32 | 32 passed |
| `f_log` | 3 | 3 passed |
| `f_jsonrpc` | 44 | 44 passed |

`f_mvc` 源码零改动（`git diff sts/1.3.x -- f_mvc` 为空）。

## Coherence

| 设计决定 | 代码落点 |
|---|---|
| D1 `@JsonRpcMapping` + `@Controller` | `JsonRpcMapping.cj`、`JsonRpcController.cj` |
| D2 一端点一 RequestMeta | `JsonRpcController.handleRoot/handleTopic` |
| D3 包布局 | `f_jsonrpc/src/*.cj`（9 个生产文件，与 design 一致；`Builder` 拆为顶层 `JsonRpcServerBuilder`，因仓颉不支持嵌套类） |
| D4 协议错误 HTTP 200 | `handle` 只对超限设置 413，其余返回错误对象 |
| D5 通知返回 `Unit` | `JsonRpcController.dispatch` 的 `case None => ()` |
| D6 方法表线程安全 | `ConcurrentHashMap` + 插入排序 |
| D7 topic 过滤 | `resolve` |
| D8 `JsonSchema.validate` | `f_data/src/json/JsonSchemaValidator.cj`；静态重载因语言限制退化为 `JsonSchemaValidator.validate`（规格已同步） |
| D9 客户端 | `JsonRpcClient` + 包内 `JsonRpcTransport` 接缝 |
| D10 `.modules` | `[include]` 增加 `f_jsonrpc` / `f_mcp`，根 `src/` 未改 |

## 结论

| 级别 | 数量 | 内容 |
|---|---|---|
| CRITICAL | 0 | — |
| WARNING | 2 | ① HTTP 端到端（415 / 406 / `Unit` 分支 200 或 204）未实测，本机无 fboot；② `opsx:verify` 未走通道，按文档 fallback 执行 |
| SUGGESTION | 1 | 有 fboot 环境后补一条 `/rpc` 的 curl 冒烟（含漏 `Content-Type` 的 415、通知的空 body） |

CRITICAL 已清零，可以进入 archive。
